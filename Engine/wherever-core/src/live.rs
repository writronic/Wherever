use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use rayon::prelude::*;

use crate::crawl::{self, Attrs, Crawl, Listing, NONE, Pool, RawEnt};
use crate::index::{Index, Snapshot};
use crate::{EngineHit, EngineKind};

const FOLDER: EngineKind = EngineKind::Folder;

#[cfg(test)]
thread_local! {
    static DIR_LOOKUPS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

pub struct Disk<'a> {
    pub pool: &'a Pool,
    pub skip: &'a [PathBuf],
    pub stop: &'a AtomicBool,
}

impl Disk<'_> {
    pub fn blocked(&self, path: &[u8]) -> bool {
        crawl::blocked(self.skip, as_path(path))
    }

    fn scan(&self, path: &[u8]) -> Crawl {
        crawl::scan_path(self.pool, as_path(path), self.skip, self.stop)
    }
}

pub struct Fetched {
    path: Vec<u8>,
    recursive: bool,
    skipped: bool,
    attrs: Option<Attrs>,
    listing: Option<Listing>,
    ancestors: Vec<(Vec<u8>, Attrs)>,
    ancestor_scan: Option<(Vec<u8>, Attrs, Crawl)>,
    scans: HashMap<Vec<u8>, Crawl>,
}

#[cfg(test)]
impl Fetched {
    pub(crate) fn scans(&self) -> usize {
        self.scans.len()
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Folder {
    Base(u32),
    New(u32),
}

#[derive(Clone)]
pub struct Added {
    pub name: String,
    pub attrs: Attrs,
    pub folder: Folder,
}

#[derive(Clone)]
pub struct Found {
    pub index: Arc<Index>,
    pub hits: Vec<u32>,
    pub updated: Arc<HashMap<u32, Attrs>>,
    pub added: Vec<Added>,
    pub new_dirs: Vec<String>,
    pub(crate) listed: Vec<[u32; 2]>,
    pub(crate) listed_dirs: Vec<[u32; 2]>,
    pub(crate) partial: Option<crate::unit::partial::Snapshot>,
    pub(crate) seen: Option<Seen>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Seen {
    pub(crate) live: u64,
    pub(crate) at: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Touched {
    Base(u32),
    Over(Vec<u8>),
    Subtree(Vec<u8>),
}

pub(crate) const TOUCHED_MAX: usize = 100_000;

static NEXT_LIVE: AtomicU64 = AtomicU64::new(1);

impl Found {
    pub fn row(&self, k: usize) -> Option<EngineHit> {
        match self.hits.get(k) {
            Some(&e) => {
                let mut hit = self.index.hit(e);
                if let Some(a) = self.updated.get(&e) {
                    hit.size = a.size;
                    hit.modified = a.mtime;
                    hit.created = a.created;
                    hit.opened = a.opened;
                }
                Some(hit)
            }
            None => {
                let n = k - self.hits.len();
                if let Some(h) = self.added.get(n) {
                    return Some(EngineHit {
                        name: h.name.clone(),
                        folder: self.folder(h.folder).into_owned(),
                        size: h.attrs.size,
                        modified: h.attrs.mtime,
                        created: h.attrs.created,
                        opened: h.attrs.opened,
                        kind: h.attrs.kind,
                        matches: Vec::new(),
                    });
                }
                let (folder, e) = self.listed_at(n - self.added.len())?;
                Some(EngineHit {
                    name: String::from_utf8_lossy(folder.listing.name(e)).into_owned(),
                    folder: folder.path.to_string_lossy().into_owned(),
                    size: e.size,
                    modified: e.mtime,
                    created: e.created,
                    opened: e.opened,
                    kind: e.kind,
                    matches: Vec::new(),
                })
            }
        }
    }

    pub fn count(&self) -> usize {
        self.hits.len() + self.added.len() + self.listed.len()
    }

    pub(crate) fn listed_dir(&self, d: u32) -> &crate::unit::partial::Folder {
        let [batch, at] = self.listed_dirs[d as usize];
        let partial = self
            .partial
            .as_ref()
            .expect("listed hits come with their snapshot");
        &partial.batches[batch as usize][at as usize]
    }

    pub(crate) fn listed_at(&self, n: usize) -> Option<(&crate::unit::partial::Folder, &RawEnt)> {
        let [d, e] = *self.listed.get(n)?;
        let folder = self.listed_dir(d);
        Some((folder, &folder.listing.ents[e as usize]))
    }

    pub(crate) fn listed_path(&self, n: usize) -> Option<Vec<u8>> {
        let (folder, e) = self.listed_at(n)?;
        Some(
            folder
                .path
                .join(OsStr::from_bytes(folder.listing.name(e)))
                .into_os_string()
                .into_vec(),
        )
    }

    pub fn attrs(&self, k: usize) -> Option<Attrs> {
        match self.hits.get(k) {
            Some(&e) => Some(
                self.updated
                    .get(&e)
                    .copied()
                    .unwrap_or_else(|| self.index.attrs(e as usize)),
            ),
            None => {
                let n = k - self.hits.len();
                let attrs = match self.added.get(n) {
                    Some(h) => h.attrs,
                    None => self.listed_at(n - self.added.len())?.1.attrs(),
                };
                Some(Attrs {
                    mount: false,
                    hidden: false,
                    ..attrs
                })
            }
        }
    }

    pub fn folder(&self, folder: Folder) -> Cow<'_, str> {
        match folder {
            Folder::Base(d) => self
                .index
                .folder(d as usize)
                .to_string_lossy()
                .into_owned()
                .into(),
            Folder::New(d) => Cow::Borrowed(&self.new_dirs[d as usize]),
        }
    }

    pub fn added_path(&self, h: &Added, base: &mut Option<(u32, String)>) -> Vec<u8> {
        let folder = match h.folder {
            Folder::Base(d) => {
                if base.as_ref().is_none_or(|(last, _)| *last != d) {
                    *base = Some((d, self.folder(h.folder).into_owned()));
                }
                base.as_ref().unwrap().1.as_str()
            }
            Folder::New(d) => &self.new_dirs[d as usize],
        };
        Path::new(folder).join(&h.name).into_os_string().into_vec()
    }

    #[cfg(test)]
    pub fn rows(&self, start: usize, count: usize) -> Vec<EngineHit> {
        let end = start.saturating_add(count).min(self.count());
        (start.min(end)..end).filter_map(|k| self.row(k)).collect()
    }
}

pub struct Live {
    pub base: Arc<Index>,
    dead: Vec<u64>,
    dead_count: usize,
    pub over: BTreeMap<Vec<u8>, Attrs>,
    pub updated: Arc<HashMap<u32, Attrs>>,
    unlisted: HashSet<Vec<u8>>,
    listed_dirs: HashSet<usize>,
    by_entry: Vec<u32>,
    pub event_id: u64,
    pub synced_at: u64,
    pub recovery_from: Option<u64>,
    edits: u64,
    opened_edits: u64,
    id: u64,
    touched: Vec<Touched>,
    touched_from: u64,
}

impl Live {
    pub fn new(base: Arc<Index>) -> Live {
        let mut by_entry: Vec<u32> = (1..base.folders() as u32).collect();
        by_entry.sort_unstable_by_key(|&k| base.dir_entry(k as usize));
        Live {
            dead: vec![0; (base.entries() as usize).div_ceil(64)],
            dead_count: 0,
            over: BTreeMap::new(),
            updated: Arc::default(),
            unlisted: HashSet::new(),
            listed_dirs: HashSet::new(),
            by_entry,
            event_id: base.event_id(),
            synced_at: base.synced_at(),
            recovery_from: None,
            edits: 0,
            opened_edits: 0,
            id: NEXT_LIVE.fetch_add(1, Ordering::Relaxed),
            touched: Vec::new(),
            touched_from: 0,
            base,
        }
    }

    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    pub(crate) fn touched_at(&self) -> u64 {
        self.touched_from + self.touched.len() as u64
    }

    pub(crate) fn touched_since(&self, at: u64) -> Option<&[Touched]> {
        let from = at.checked_sub(self.touched_from)? as usize;
        self.touched.get(from..)
    }

    fn touch(&mut self, t: Touched) {
        if self.touched.len() == TOUCHED_MAX {
            self.touched_from += TOUCHED_MAX as u64;
            self.touched.clear();
        }
        self.touched.push(t);
    }

    pub fn entries(&self) -> u64 {
        self.base.entries() - self.dead_count as u64 + self.over.len() as u64
    }

    pub fn pending(&self) -> usize {
        self.over.len() + self.updated.len() + self.dead_count + self.listed_dirs.len()
    }

    pub fn attrs(&self, entry: usize) -> Attrs {
        self.updated
            .get(&(entry as u32))
            .copied()
            .unwrap_or_else(|| self.base.attrs(entry))
    }

    fn update_attrs(&mut self, entry: u32, attrs: Attrs) {
        let old = self.attrs(entry as usize);
        if old == attrs {
            return;
        }
        if (Attrs {
            opened: attrs.opened,
            ..old
        }) == attrs
        {
            self.opened_edits += 1;
        }
        let updated = Arc::make_mut(&mut self.updated);
        if self.base.attrs(entry as usize) == attrs {
            updated.remove(&entry);
        } else {
            updated.insert(entry, attrs);
        }
        self.edits += 1;
        self.touch(Touched::Base(entry));
    }

    pub fn edits(&self) -> u64 {
        self.edits
    }

    pub fn opened_edits(&self) -> u64 {
        self.opened_edits
    }

    fn root(&self) -> &[u8] {
        self.base.root().as_os_str().as_bytes()
    }

    pub fn is_dead(&self, i: u32) -> bool {
        let (word, bit) = (i as usize / 64, i % 64);
        self.dead[word] >> bit & 1 == 1
    }

    fn kill(&mut self, i: u32) {
        if self.updated.contains_key(&i) {
            Arc::make_mut(&mut self.updated).remove(&i);
        }
        let bit = 1u64 << (i & 63);
        let word = &mut self.dead[i as usize >> 6];
        if *word & bit == 0 {
            *word |= bit;
            self.dead_count += 1;
            self.edits += 1;
            self.touch(Touched::Base(i));
        }
    }

    fn kill_subtree(&mut self, e: u32) {
        self.kill(e);
        if let Some(k) = self.dir_of(e) {
            for i in self.base.subtree(k) {
                self.kill(i as u32);
            }
        }
    }

    fn dir_of(&self, e: u32) -> Option<usize> {
        #[cfg(test)]
        DIR_LOOKUPS.with(|n| n.set(n.get() + 1));
        let at = self
            .by_entry
            .binary_search_by_key(&e, |&k| self.base.dir_entry(k as usize))
            .ok()?;
        Some(self.by_entry[at] as usize)
    }

    fn lookup(&self, path: &[u8]) -> Option<u32> {
        let mut entry = None;
        for name in below(self.root(), path)?
            .split(|&b| b == b'/')
            .filter(|n| !n.is_empty())
        {
            let folder = match entry {
                None => 0,
                Some(e) => self.dir_of(e)?,
            };
            entry = Some(self.base.child(folder, name)?);
        }
        entry.filter(|&e| !self.is_dead(e))
    }

    pub fn base_dir(&self, path: &[u8]) -> Option<usize> {
        if path == self.root() {
            return Some(0);
        }
        self.lookup(path).and_then(|e| self.dir_of(e))
    }

    pub(crate) fn cached_dir<'p>(
        &self,
        path: &'p Path,
        cache: &mut Vec<(&'p [u8], Option<usize>)>,
    ) -> Option<usize> {
        let raw = path.as_os_str().as_bytes();
        below(self.root(), raw)?;
        while cache.last().is_some_and(|(p, _)| below(p, raw).is_none()) {
            cache.pop();
        }
        let (prefix, mut dir) = cache.last().copied().unwrap_or((self.root(), Some(0)));
        let mut rest = below(prefix, raw)?;
        while !rest.is_empty() {
            let len = rest.iter().position(|&b| b == b'/').unwrap_or(rest.len());
            let end = raw.len() - rest.len() + len;
            if len != 0 {
                dir = dir.and_then(|up| {
                    let entry = self.base.child(up, &rest[..len])?;
                    if self.is_dead(entry) {
                        None
                    } else {
                        self.dir_of(entry)
                    }
                });
                cache.push((&raw[..end], dir));
            }
            rest = &rest[(len + 1).min(rest.len())..];
        }
        dir
    }

    fn base_listed(&self, k: usize) -> bool {
        self.base.dir_listed(k) || self.listed_dirs.contains(&k)
    }

    fn is_listed(&self, path: &[u8]) -> bool {
        if let Some(k) = self.base_dir(path) {
            self.base_listed(k)
        } else {
            self.over.get(path).is_some_and(|a| a.kind == FOLDER) && !self.unlisted.contains(path)
        }
    }

    fn put(&mut self, path: Vec<u8>, a: Attrs) {
        if a.kind == FOLDER && !self.over.contains_key(&path) {
            self.unlisted.insert(path.clone());
        }
        let old = self.over.insert(path.clone(), a);
        if old != Some(a) {
            self.edits += 1;
            if old.is_some_and(|old| {
                Attrs {
                    opened: a.opened,
                    ..old
                } == a
            }) {
                self.opened_edits += 1;
            }
            if old.is_some_and(|old| old.hidden) != a.hidden {
                self.touch(Touched::Subtree(path.clone()));
            }
            self.touch(Touched::Over(path));
        }
    }

    fn drop_over_subtree(&mut self, path: &[u8]) {
        let (lo, hi) = subtree_bounds(path);
        let mut gone: Vec<Vec<u8>> = self.over.range(lo..hi).map(|(k, _)| k.clone()).collect();
        gone.push(path.to_vec());
        for k in gone {
            self.unlisted.remove(&k);
            if self.over.remove(&k).is_some() {
                self.edits += 1;
                self.touch(Touched::Over(k));
            }
        }
    }

    pub fn drop_below(&mut self, path: &[u8]) -> bool {
        let edits = self.edits;
        if let Some(k) = self.base_dir(path) {
            for i in self.base.subtree(k) {
                self.kill(i as u32);
            }
        }
        let (lo, hi) = subtree_bounds(path);
        let gone: Vec<Vec<u8>> = self.over.range(lo..hi).map(|(k, _)| k.clone()).collect();
        for k in gone {
            self.unlisted.remove(&k);
            self.over.remove(&k);
            self.edits += 1;
            self.touch(Touched::Over(k));
        }
        self.edits != edits
    }

    fn remove_path(&mut self, path: &[u8]) {
        if let Some(e) = self.lookup(path) {
            self.kill_subtree(e);
        }
        self.drop_over_subtree(path);
    }

    fn current_children(&self, p: &[u8]) -> HashMap<Vec<u8>, Option<u32>> {
        let mut cur = HashMap::new();
        if let Some(k) = self.base_dir(p) {
            for c in self.base.block(k) {
                if !self.is_dead(c as u32) {
                    cur.insert(self.base.ent_name(c).to_vec(), Some(c as u32));
                }
            }
        }
        let (lo, hi) = subtree_bounds(p);
        let skip = lo.len();
        for k in self.over.range(lo..hi).map(|(k, _)| k) {
            if !k[skip..].contains(&b'/') {
                cur.insert(k[skip..].to_vec(), None);
            }
        }
        cur
    }

    pub fn fetch(&self, path: &[u8], recursive: bool, disk: &Disk) -> Fetched {
        let mut f = Fetched {
            path: path.to_vec(),
            recursive,
            skipped: false,
            attrs: None,
            listing: None,
            ancestors: Vec::new(),
            ancestor_scan: None,
            scans: HashMap::new(),
        };
        if disk.blocked(path) {
            f.skipped = true;
            return f;
        }
        if let Some(rest) = below(self.root(), path).filter(|r| !r.is_empty())
            && let Ok(real) = std::fs::canonicalize(as_path(path))
            && !real.ends_with(as_path(rest))
        {
            let real = real.into_os_string().into_vec();
            if below(self.root(), &real).is_none() || disk.blocked(&real) {
                f.skipped = true;
                return f;
            }
            f.path = real;
        }
        let path = f.path.clone();
        let path = &path[..];
        let p = as_path(path);
        let ancestor = p
            .ancestors()
            .skip(1)
            .take_while(|p| {
                p.starts_with(self.base.root()) && !self.is_listed(p.as_os_str().as_bytes())
            })
            .last();
        if let Some(ancestor) = ancestor
            && let Some(mut attrs) = crawl::lstat(ancestor).filter(|a| a.kind == FOLDER)
        {
            attrs.mount = crawl::is_mount(ancestor);
            let scan = disk.scan(ancestor.as_os_str().as_bytes());
            if scan.listings.iter().any(|l| l.id == 0) {
                f.ancestor_scan = Some((ancestor.as_os_str().as_bytes().to_vec(), attrs, scan));
            }
        }
        if recursive {
            f.attrs = crawl::lstat(p);
            if let Some(a) = f.attrs.as_mut().filter(|a| a.kind == FOLDER) {
                a.mount = crawl::is_mount(p);
            }
            if f.attrs.is_some_and(|a| a.kind == FOLDER && !a.mount) {
                f.ancestors = self.missing_ancestors(path);
                f.scans.insert(path.to_vec(), disk.scan(path));
            }
            return f;
        }
        let Ok(listing) = crawl::list_one(p) else {
            f.attrs = crawl::lstat(p);
            return f;
        };
        self.fetched_listing(f, listing, disk)
    }

    fn fetched_listing(&self, mut f: Fetched, listing: Listing, disk: &Disk) -> Fetched {
        let path = &f.path;
        f.ancestors = self.missing_ancestors(path);
        f.attrs = crawl::lstat(as_path(path));
        if let Some(a) = f.attrs.as_mut().filter(|a| a.kind == FOLDER) {
            a.mount = crawl::is_mount(as_path(path));
        }
        let cur = self.current_children(path);
        for e in &listing.ents {
            if e.kind != FOLDER || e.attrs().mount {
                continue;
            }
            let name = listing.name(e);
            let child = join(path, name);
            let was_folder = match cur.get(name) {
                Some(&Some(c)) => self.dir_of(c).is_some_and(|k| self.base_listed(k)),
                Some(None) => self.is_listed(&child),
                None => false,
            };
            if !was_folder {
                let scan = disk.scan(&child);
                f.scans.insert(child, scan);
            }
        }
        f.listing = Some(listing);
        f
    }

    fn missing_ancestors(&self, path: &[u8]) -> Vec<(Vec<u8>, Attrs)> {
        let mut ancestors = Vec::new();
        let mut p = as_path(path);
        while p != self.base.root()
            && p.starts_with(self.base.root())
            && self.lookup(p.as_os_str().as_bytes()).is_none()
            && !self.over.contains_key(p.as_os_str().as_bytes())
        {
            let Some(a) = crawl::lstat(p).filter(|a| a.kind == FOLDER) else {
                break;
            };
            ancestors.push((p.as_os_str().as_bytes().to_vec(), a));
            let Some(parent) = p.parent() else { break };
            p = parent;
        }
        ancestors
    }

    pub fn fetch_changed(&self, path: &[u8], disk: &Disk) -> Option<Fetched> {
        if disk.blocked(path) || disk.stop.load(Ordering::Relaxed) {
            return None;
        }
        let listing = match crawl::list_one(as_path(path)) {
            Ok(mut listing) => {
                listing.sort();
                if self.listing_matches(path, &listing) {
                    return None;
                }
                Some(listing)
            }
            Err(_) => {
                if crawl::lstat(as_path(path)).is_some()
                    || (self.lookup(path).is_none() && !self.over.contains_key(path))
                {
                    return None;
                }
                None
            }
        };
        let f = Fetched {
            path: path.to_vec(),
            recursive: false,
            skipped: false,
            attrs: None,
            listing: None,
            ancestors: Vec::new(),
            ancestor_scan: None,
            scans: HashMap::new(),
        };
        Some(match listing {
            Some(listing) => self.fetched_listing(f, listing, disk),
            None => f,
        })
    }

    fn listing_matches(&self, path: &[u8], listing: &Listing) -> bool {
        if !self.is_listed(path) {
            return false;
        }
        if let Some(was) = self
            .lookup(path)
            .map(|c| self.attrs(c as usize))
            .or_else(|| self.over.get(path).copied())
        {
            let now = crawl::lstat(as_path(path)).map(|mut a| {
                a.mount = was.mount;
                a
            });
            if now != Some(was) {
                return false;
            }
        }
        let attrs = |name: &[u8]| {
            listing
                .ents
                .binary_search_by(|e| listing.name(e).cmp(name))
                .ok()
                .map(|k| listing.ents[k].attrs())
        };
        let mut count = 0;
        if let Some(k) = self.base_dir(path) {
            for c in self.base.block(k).filter(|&c| !self.is_dead(c as u32)) {
                count += 1;
                let was = self.attrs(c);
                let now = attrs(self.base.ent_name(c));
                if now != Some(was) {
                    return false;
                }
            }
        }
        for (p, &was) in self
            .over
            .range::<[u8], _>((std::ops::Bound::Excluded(path), std::ops::Bound::Unbounded))
            .take_while(|(p, _)| p.starts_with(path))
        {
            let Some(name) = below(path, p).filter(|p| !p.contains(&b'/')) else {
                continue;
            };
            count += 1;
            if attrs(name) != Some(was) {
                return false;
            }
        }
        count == listing.ents.len()
    }

    pub fn recovery_dirs(&self, listed: &HashSet<Vec<u8>>) -> Vec<Vec<u8>> {
        let mut dirs: Vec<_> = (0..self.base.entries() as usize)
            .filter(|&c| !self.is_dead(c as u32) && self.attrs(c).kind == FOLDER)
            .map(|c| {
                self.base
                    .folder(self.base.parent(c))
                    .join(OsStr::from_bytes(self.base.ent_name(c)))
                    .into_os_string()
                    .into_vec()
            })
            .chain(
                self.over
                    .iter()
                    .filter(|(_, a)| a.kind == FOLDER && !a.mount)
                    .map(|(p, _)| p.clone()),
            )
            .filter(|p| !listed.contains(p))
            .collect();
        if !listed.contains(self.root()) {
            dirs.push(self.root().to_vec());
        }
        dirs
    }

    fn scan_opened_change(&self, path: &[u8], attrs: Attrs, scan: &Crawl) -> Option<bool> {
        let listings: HashMap<_, _> = scan.listings.iter().map(|l| (l.id, l)).collect();
        let mut stack = vec![(0, path.to_vec(), attrs)];
        let mut changed = false;
        while let Some((id, path, attrs)) = stack.pop() {
            let old = self
                .lookup(&path)
                .map(|c| self.attrs(c as usize))
                .or_else(|| self.over.get(&path).copied())?;
            if (Attrs {
                opened: attrs.opened,
                ..old
            }) != attrs
            {
                return None;
            }
            changed |= old != attrs;
            let listing = listings.get(&id);
            if listing.is_some() != self.is_listed(&path) {
                return None;
            }
            let mut children = self.current_children(&path);
            if let Some(listing) = listing {
                for entry in &listing.ents {
                    let name = listing.name(entry);
                    let child = join(&path, name);
                    let old = match children.remove(name)? {
                        Some(c) => self.attrs(c as usize),
                        None => *self.over.get(&child)?,
                    };
                    let attrs = entry.attrs();
                    if (Attrs {
                        opened: attrs.opened,
                        ..old
                    }) != attrs
                    {
                        return None;
                    }
                    changed |= old != attrs;
                    if attrs.kind == FOLDER {
                        stack.push((entry.child, child, attrs));
                    }
                }
            }
            if !children.is_empty() {
                return None;
            }
        }
        Some(changed)
    }

    pub fn apply(&mut self, mut f: Fetched, disk: &Disk) {
        if f.skipped || disk.blocked(&f.path) {
            return;
        }
        let p = std::mem::take(&mut f.path);
        if let Some((path, attrs, scan)) = f.ancestor_scan {
            self.apply_scan(path, attrs, scan, disk);
        }
        for (path, attrs) in f.ancestors {
            if self.lookup(&path).is_none() && !self.over.contains_key(&path) {
                self.put(path, attrs);
            }
        }
        if f.recursive {
            let opened = f.attrs.and_then(|attrs| {
                f.scans
                    .get(&p)
                    .and_then(|scan| self.scan_opened_change(&p, attrs, scan))
            });
            if opened == Some(false) {
                return;
            }
            let (before, before_opened) = (self.edits, self.opened_edits);
            self.remove_path(&p);
            if let Some(a) = f.attrs {
                let scan = f.scans.remove(&p);
                self.add_new(p, a, scan, disk);
            }
            if opened == Some(true) {
                self.opened_edits = before_opened + self.edits - before;
            }
            return;
        }
        let Some(listing) = f.listing else {
            if f.attrs.is_none() {
                self.remove_path(&p);
            }
            return;
        };
        if let Some(attrs) = f.attrs {
            if let Some(c) = self.lookup(&p) {
                if self.dir_of(c).is_none() {
                    self.kill(c);
                    self.put(p.clone(), attrs);
                } else {
                    self.update_attrs(c, attrs);
                }
            } else if self.over.get(&p).is_some_and(|a| *a != attrs) {
                self.put(p.clone(), attrs);
            }
        }
        let mut cur = self.current_children(&p);
        for e in &listing.ents {
            let name = listing.name(e);
            let child = join(&p, name);
            let now = e.attrs();
            match cur.remove(name) {
                None => {
                    let scan = f.scans.remove(&child);
                    self.add_new(child, now, scan, disk);
                }
                Some(Some(c)) => {
                    let was = self.attrs(c as usize);
                    if was.kind != now.kind {
                        if was.kind == FOLDER {
                            self.drop_over_subtree(&child);
                        }
                        self.kill_subtree(c);
                        let scan = f.scans.remove(&child);
                        self.add_new(child, now, scan, disk);
                    } else if now.kind != FOLDER && was != now {
                        if (Attrs {
                            opened: now.opened,
                            ..was
                        }) == now
                        {
                            self.update_attrs(c, now);
                        } else {
                            self.kill(c);
                            self.put(child, now);
                        }
                    } else if now.kind == FOLDER {
                        self.update_attrs(c, now);
                        if !self.dir_of(c).is_some_and(|k| self.base_listed(k))
                            && let Some(scan) =
                                f.scans.remove(&child).filter(|s| !s.listings.is_empty())
                        {
                            self.apply_scan(child, now, scan, disk);
                        }
                    }
                }
                Some(None) => {
                    let Some(&old) = self.over.get(&child) else {
                        continue;
                    };
                    if old.kind != now.kind {
                        self.drop_over_subtree(&child);
                        let scan = f.scans.remove(&child);
                        self.add_new(child, now, scan, disk);
                    } else {
                        if old != now {
                            self.put(child.clone(), now);
                        }
                        if now.kind == FOLDER
                            && let Some(scan) =
                                f.scans.remove(&child).filter(|s| !s.listings.is_empty())
                        {
                            self.apply_scan(child, now, scan, disk);
                        }
                    }
                }
            }
        }
        if listing.cut {
            let marked = match self.base_dir(&p) {
                Some(k) => self.listed_dirs.remove(&k),
                None => self.over.contains_key(&p) && self.unlisted.insert(p),
            };
            if marked {
                self.edits += 1;
            }
            return;
        }
        for (name, c) in cur {
            let child = join(&p, &name);
            if let Some(c) = c {
                if self.attrs(c as usize).kind == FOLDER {
                    self.drop_over_subtree(&child);
                }
                self.kill_subtree(c);
            } else {
                self.drop_over_subtree(&child);
            }
        }
        if let Some(k) = self.base_dir(&p)
            && !self.base.dir_listed(k)
            && self.listed_dirs.insert(k)
        {
            self.edits += 1;
        }
        if self.unlisted.remove(&p) {
            self.edits += 1;
        }
    }

    fn apply_scan(&mut self, path: Vec<u8>, attrs: Attrs, scan: Crawl, disk: &Disk) {
        if self.lookup(&path).is_none() && !self.over.contains_key(&path) {
            self.put(path.clone(), attrs);
        }
        let mut listings: HashMap<_, _> = scan.listings.into_iter().map(|l| (l.id, l)).collect();
        let mut stack = vec![(0, path, attrs)];
        while let Some((id, path, attrs)) = stack.pop() {
            let Some(listing) = listings.remove(&id) else {
                continue;
            };
            let mut scans = HashMap::new();
            for e in &listing.ents {
                if e.kind == FOLDER {
                    let child = join(&path, listing.name(e));
                    if e.child != NONE {
                        stack.push((e.child, child.clone(), e.attrs()));
                    }
                    scans.insert(child, Crawl::default());
                }
            }
            self.apply(
                Fetched {
                    path,
                    recursive: false,
                    skipped: false,
                    attrs: Some(attrs),
                    listing: Some(listing),
                    ancestors: Vec::new(),
                    ancestor_scan: None,
                    scans,
                },
                disk,
            );
        }
    }

    fn add_new(&mut self, path: Vec<u8>, a: Attrs, scan: Option<Crawl>, disk: &Disk) {
        let descend = a.kind == FOLDER && !a.mount;
        self.put(path.clone(), a);
        if descend {
            let crawl = scan.unwrap_or_else(|| disk.scan(&path));
            self.apply_scan(path, a, crawl, disk);
        }
    }

    pub fn changed_dirs(&self, since: i64, disk: &Disk) -> Vec<Vec<u8>> {
        let changed = |p: &[u8]| {
            !disk.stop.load(Ordering::Relaxed)
                && !disk.blocked(p)
                && crawl::lstat(as_path(p)).is_some_and(|a| a.mtime >= since)
        };
        let base = &self.base;
        let mut out: Vec<Vec<u8>> = disk.pool.install(|| {
            (1..base.folders())
                .into_par_iter()
                .filter(|&k| !self.is_dead(base.dir_entry(k)))
                .map(|k| base.folder(k).into_os_string().into_vec())
                .filter(|p| changed(p))
                .collect()
        });
        out.extend(
            self.over
                .iter()
                .filter(|(p, a)| a.kind == FOLDER && !a.mount && changed(p))
                .map(|(p, _)| p.clone()),
        );
        if changed(self.root()) {
            out.push(self.root().to_vec());
        }
        out
    }

    pub fn to_crawl(&self) -> Snapshot {
        let mut by_parent: HashMap<&[u8], Vec<(&[u8], Attrs)>> = HashMap::new();
        for (k, a) in &self.over {
            let cut = k.iter().rposition(|&b| b == b'/').unwrap_or(0);
            let parent: &[u8] = if cut == 0 { b"/" } else { &k[..cut] };
            by_parent
                .entry(parent)
                .or_default()
                .push((&k[cut + 1..], *a));
        }
        let mut listings = Vec::new();
        let mut unlisted = HashSet::new();
        let mut stack: Vec<(Option<usize>, Vec<u8>, u32)> =
            vec![(Some(0), self.root().to_vec(), 0)];
        let mut next = 1u32;
        while let Some((k, path, id)) = stack.pop() {
            if !k.map_or_else(|| self.is_listed(&path), |k| self.base_listed(k)) {
                unlisted.insert(id);
            }
            let mut l = Listing::default();
            l.id = id;
            let mut child = |sub: Option<usize>, name: &[u8]| {
                stack.push((sub, join(&path, name), next));
                next += 1;
                next - 1
            };
            if let Some(k) = k {
                for c in self.base.block(k) {
                    if self.is_dead(c as u32) {
                        continue;
                    }
                    let name = self.base.ent_name(c);
                    let a = self.attrs(c);
                    let id = match self.dir_of(c as u32) {
                        Some(sub) => child(Some(sub), name),
                        None if a.kind == FOLDER
                            && by_parent.contains_key(join(&path, name).as_slice()) =>
                        {
                            child(None, name)
                        }
                        None => NONE,
                    };
                    l.push(name, a, id);
                }
            }
            for &(name, a) in by_parent.get(path.as_slice()).into_iter().flatten() {
                let id = if a.kind == FOLDER && !a.mount {
                    child(None, name)
                } else {
                    NONE
                };
                l.push(name, a, id);
            }
            listings.push(l);
        }
        Snapshot {
            crawl: Crawl {
                listings,
                failed: Vec::new(),
            },
            unlisted,
        }
    }
}

#[cfg(test)]
impl Live {
    pub(crate) fn journaled_put(&mut self, path: Vec<u8>, a: Attrs) {
        self.put(path, a);
    }

    pub(crate) fn journaled_kill(&mut self, i: u32) {
        self.kill_subtree(i);
    }

    pub(crate) fn journaled_update(&mut self, i: u32, a: Attrs) {
        self.update_attrs(i, a);
    }
}

pub fn as_path(p: &[u8]) -> &Path {
    Path::new(OsStr::from_bytes(p))
}

pub fn normalize(path: &[u8]) -> Vec<u8> {
    let mut p = path.to_vec();
    while p.len() > 1 && p.last() == Some(&b'/') {
        p.pop();
    }
    p
}

fn join(dir: &[u8], name: &[u8]) -> Vec<u8> {
    let slash: &[u8] = if dir == b"/" { b"" } else { b"/" };
    [dir, slash, name].concat()
}

fn below<'p>(root: &[u8], path: &'p [u8]) -> Option<&'p [u8]> {
    let rest = path.strip_prefix(root)?;
    if rest.is_empty() || root == b"/" {
        Some(rest)
    } else {
        rest.strip_prefix(b"/")
    }
}

fn subtree_bounds(path: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let lo = join(path, b"");
    let mut hi = lo.clone();
    if let Some(last) = hi.last_mut() {
        *last += 1;
    }
    (lo, hi)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{TempTree, crawl};
    use std::fs;

    fn names(live: &Live, query: &str) -> Vec<(String, String)> {
        let found = live.find(query, || false).unwrap();
        let mut v: Vec<_> = found
            .rows(0, usize::MAX)
            .into_iter()
            .map(|h| (h.name, h.folder))
            .collect();
        v.sort();
        v
    }

    #[test]
    fn every_edit_shows_in_the_next_empty_list() {
        use crate::engine::{Results, timing::search};
        use crate::opens::Opens;
        use crate::sort::{fold, natural};
        use crate::{EngineColumn, EngineSort};

        fn disk_rows(folder: &Path) -> Vec<(String, String, u64, EngineKind)> {
            let mut rows = Vec::new();
            for entry in fs::read_dir(folder).unwrap() {
                let entry = entry.unwrap();
                let metadata = fs::symlink_metadata(entry.path()).unwrap();
                let kind = if metadata.is_dir() {
                    FOLDER
                } else {
                    EngineKind::File
                };
                rows.push((
                    entry.file_name().to_string_lossy().into_owned(),
                    folder.to_string_lossy().into_owned(),
                    if metadata.is_dir() { 0 } else { metadata.len() },
                    kind,
                ));
                if metadata.is_dir() {
                    rows.extend(disk_rows(&entry.path()));
                }
            }
            rows
        }

        let tree = TempTree::new("empty-list-edits");
        fs::remove_file(tree.0.join("link")).unwrap();
        fs::create_dir_all(tree.0.join("Sub/Inner/Leaf")).unwrap();
        fs::create_dir_all(tree.0.join("Rename/Inner")).unwrap();
        for path in [
            "Sub/Inner/Leaf/grow.txt",
            "Sub/Inner/remove.txt",
            "Rename/Inner/keep.txt",
        ] {
            fs::write(tree.0.join(path), b"base").unwrap();
        }
        let root = PathBuf::from(tree.real());
        let base = Index::build(crawl(&tree, &[], false), root.clone(), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let event = |live: &mut Live, folder: &str| {
            let path = normalize(root.join(folder).as_os_str().as_bytes());
            let fetched = live.fetch(&path, false, &disk);
            live.apply(fetched, &disk);
        };
        let opens = Opens::new(tree.data().join("opens"));
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let mut held = Vec::new();
        let check = |live: &Live, held: &mut Vec<(Results, Vec<EngineHit>)>| {
            let mut want = disk_rows(&root);
            let name_order = |a: &(String, String, u64, EngineKind),
                              b: &(String, String, u64, EngineKind)| {
                natural(fold(&a.0).as_bytes(), fold(&b.0).as_bytes())
                    .then_with(|| fold(&a.1).cmp(&fold(&b.1)))
            };
            want.sort_by(name_order);
            let result = search(std::slice::from_ref(live), "", by_name, &opens);
            let rows = result.rows(0, usize::MAX);
            let fields = |rows: &[EngineHit]| {
                rows.iter()
                    .map(|h| (h.name.clone(), h.folder.clone(), h.size, h.kind))
                    .collect::<Vec<_>>()
            };
            assert_eq!(fields(&rows), want);
            let sizes = search(
                std::slice::from_ref(live),
                "",
                EngineSort {
                    column: EngineColumn::Size,
                    ..by_name
                },
                &opens,
            )
            .rows(0, usize::MAX);
            want.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| name_order(a, b)));
            assert_eq!(fields(&sizes), want);
            for (old, rows) in held.iter() {
                assert_eq!(old.rows(0, usize::MAX), *rows);
            }
            held.push((result, rows));
        };

        check(&live, &mut held);
        fs::write(root.join("Sub/Inner/new.txt"), b"overlay").unwrap();
        event(&mut live, "Sub/Inner");
        check(&live, &mut held);

        fs::create_dir_all(root.join("Sub/Inner/New/deep")).unwrap();
        for path in ["deep/z.txt", "x.txt", "y.txt"] {
            fs::write(root.join("Sub/Inner/New").join(path), b"new").unwrap();
        }
        event(&mut live, "Sub/Inner");
        let found = live.find("", || false).unwrap();
        assert!(
            found
                .new_dirs
                .iter()
                .filter(|p| p.ends_with("/Sub/Inner/New"))
                .count()
                >= 2
        );
        check(&live, &mut held);

        fs::remove_file(root.join("Sub/Inner/remove.txt")).unwrap();
        fs::remove_file(root.join("Sub/Inner/New/y.txt")).unwrap();
        event(&mut live, "Sub/Inner");
        event(&mut live, "Sub/Inner/New");
        check(&live, &mut held);

        fs::rename(root.join("beta.txt"), root.join("file2.txt")).unwrap();
        fs::rename(root.join("Rename"), root.join("Renamed")).unwrap();
        event(&mut live, "");
        check(&live, &mut held);

        fs::write(root.join("Sub/Inner/Leaf/grow.txt"), b"a longer saved file").unwrap();
        fs::write(
            root.join("Sub/Inner/new.txt"),
            b"an even longer overlay file",
        )
        .unwrap();
        event(&mut live, "Sub/Inner/Leaf");
        event(&mut live, "Sub/Inner");
        check(&live, &mut held);

        let saved = Index::build(live.to_crawl(), root.clone(), b"", 2, 2).unwrap();
        live = Live::new(Arc::new(saved));
        check(&live, &mut held);
    }

    #[test]
    fn overlay_search_resolves_each_base_folder_once() {
        let tree = TempTree::new("overlay-folders");
        fs::create_dir_all(tree.0.join("Shared/Inner/Leaf")).unwrap();
        let root = tree.real();
        let index =
            Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(index));
        let attrs = Attrs {
            kind: EngineKind::File,
            size: 7,
            mtime: 1,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        for parent in ["Shared", "Shared/Inner", "Shared/Inner/Leaf"] {
            for i in 0..8 {
                live.over
                    .insert(format!("{root}/{parent}/new{i}.txt").into_bytes(), attrs);
            }
        }
        DIR_LOOKUPS.with(|n| n.set(0));
        let found = live.find("", || false).unwrap();
        let lookups = DIR_LOOKUPS.with(|n| n.get());
        assert_eq!(found.added.len(), 24);
        assert!(
            found
                .added
                .iter()
                .all(|h| matches!(h.folder, Folder::Base(_)))
        );
        assert_eq!(lookups, 3, "each shared base folder is resolved only once");
        let mut paths: Vec<_> = (0..live.base.folders())
            .map(|k| live.base.folder(k))
            .collect();
        paths.extend([
            PathBuf::from(format!("{root}/Shared/Inner/New/Deep")),
            PathBuf::from(format!("{root}/Shared/Inner")),
            PathBuf::from(format!("{root}/Shared-other")),
            PathBuf::from("/outside"),
            PathBuf::from(&root),
        ]);
        for removed in [false, true] {
            if removed {
                live.drop_below(format!("{root}/Shared").as_bytes());
            }
            let mut cache = Vec::new();
            for path in paths.iter().chain(paths.iter().rev()) {
                assert_eq!(
                    live.cached_dir(path, &mut cache),
                    live.base_dir(path.as_os_str().as_bytes()),
                    "{} after removal: {removed}",
                    path.display()
                );
            }
        }
    }

    #[test]
    fn a_folder_gone_takes_what_was_added_inside_it() {
        let tree = TempTree::new("live-gone");
        fs::create_dir_all(tree.0.join("Sub/Inner")).unwrap();
        fs::write(tree.0.join("Sub/Inner/old.txt"), b"").unwrap();
        fs::create_dir(tree.0.join("Swap")).unwrap();
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let event = |live: &mut Live, path: &str| {
            let f = live.fetch(path.as_bytes(), false, &disk);
            live.apply(f, &disk);
        };
        fs::write(tree.0.join("Sub/Inner/new.txt"), b"").unwrap();
        fs::create_dir(tree.0.join("Swap/Deep")).unwrap();
        fs::write(tree.0.join("Swap/Deep/kept.md"), b"").unwrap();
        event(&mut live, &format!("{root}/Sub/Inner"));
        event(&mut live, &format!("{root}/Swap"));
        assert_eq!(
            names(&live, "new"),
            [("new.txt".to_owned(), format!("{root}/Sub/Inner"))]
        );
        assert_eq!(
            names(&live, "kept"),
            [("kept.md".to_owned(), format!("{root}/Swap/Deep"))]
        );
        let before = live.entries();

        fs::remove_dir_all(tree.0.join("Sub")).unwrap();
        fs::remove_dir_all(tree.0.join("Swap")).unwrap();
        fs::write(tree.0.join("Swap"), b"").unwrap();
        event(&mut live, &root);
        for gone in [
            "Sub", "Inner", "old.txt", "new.txt", "DELTA", "Deep", "kept",
        ] {
            assert!(names(&live, gone).is_empty(), "{gone}");
        }
        assert_eq!(names(&live, "swap"), [("Swap".to_owned(), root.clone())]);
        let swap = live.find("swap", || false).unwrap().rows(0, 1).remove(0);
        assert_eq!(swap.kind, EngineKind::File);
        assert_eq!(live.entries(), before - 7);

        let edits = live.edits();
        event(&mut live, &root);
        assert_eq!(live.edits(), edits);
    }

    #[test]
    fn a_live_added_accented_name_is_found_by_its_accent_free_reading() {
        let tree = TempTree::new("live-accent");
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        fs::write(tree.0.join("Sub/Ünal özet.txt"), b"").unwrap();
        let f = live.fetch(format!("{root}/Sub").as_bytes(), false, &disk);
        live.apply(f, &disk);
        assert!(
            live.over
                .contains_key(format!("{root}/Sub/Ünal özet.txt").as_bytes())
        );
        let want = [("Ünal özet.txt".to_owned(), format!("{root}/Sub"))];
        for query in ["unal", "ozet", "unal ozet", "sub/ozet"] {
            assert_eq!(names(&live, query), want, "{query}");
        }
        let compacted = Live::new(Arc::new(
            Index::build(live.to_crawl(), PathBuf::from(&root), b"", 1, 1).unwrap(),
        ));
        assert!(compacted.over.is_empty());
        assert_eq!(compacted.base.plains(), 1);
        for query in ["unal", "ozet", "unal ozet", "sub/ozet"] {
            assert_eq!(names(&compacted, query), want, "{query}");
        }
    }

    #[test]
    fn a_live_added_name_ignores_accents_both_ways() {
        let tree = TempTree::new("live-accent-back");
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        fs::write(tree.0.join("Sub/Unal ozet.txt"), b"").unwrap();
        fs::write(tree.0.join("Sub/rapor.özet"), b"").unwrap();
        let f = live.fetch(format!("{root}/Sub").as_bytes(), false, &disk);
        live.apply(f, &disk);
        let sub = format!("{root}/Sub");
        for name in ["Unal ozet.txt", "rapor.özet"] {
            assert!(live.over.contains_key(format!("{sub}/{name}").as_bytes()));
        }
        let plain = [("Unal ozet.txt".to_owned(), sub.clone())];
        let accented = [("rapor.özet".to_owned(), sub.clone())];
        let check = |live: &Live| {
            for query in ["ünal", "ünal özet", "sub/ünal", "glob:ünal*", "re:^ünal"] {
                assert_eq!(names(live, query), plain, "{query}");
            }
            let mut both = [plain[0].clone(), accented[0].clone()];
            both.sort();
            assert_eq!(names(live, "ÖZET"), both);
            for query in ["glob:rapor.ozet", "re:\\.ozet$", "ext:ozet", "*.OZET"] {
                assert_eq!(names(live, query), accented, "{query}");
            }
        };
        check(&live);
        let compacted = Live::new(Arc::new(
            Index::build(live.to_crawl(), PathBuf::from(&root), b"", 1, 1).unwrap(),
        ));
        assert!(compacted.over.is_empty());
        check(&compacted);
    }

    #[test]
    fn a_case_only_rename_with_an_old_spelling_event_adds_no_duplicate() {
        let tree = TempTree::new("live-case");
        fs::create_dir_all(tree.0.join("Projects/Inner")).unwrap();
        fs::write(tree.0.join("Projects/Inner/caseonly.md"), b"").unwrap();
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let before = live.entries();
        fs::rename(tree.0.join("Projects"), tree.0.join("projects")).unwrap();
        assert!(
            tree.0.join("Projects/Inner").is_dir(),
            "the test needs a case-insensitive temp folder"
        );
        let stale = [format!("{root}/Projects"), format!("{root}/Projects/Inner")];
        let batch: Vec<_> = std::iter::once(&root)
            .chain(&stale)
            .map(|p| live.fetch(p.as_bytes(), false, &disk))
            .collect();
        for f in batch {
            live.apply(f, &disk);
        }
        let check = |live: &Live| {
            assert_eq!(
                names(live, "caseonly"),
                [("caseonly.md".to_owned(), format!("{root}/projects/Inner"))]
            );
            assert_eq!(
                names(live, "projects"),
                [("projects".to_owned(), root.clone())]
            );
            assert_eq!(
                names(live, "inner"),
                [("Inner".to_owned(), format!("{root}/projects"))]
            );
            assert_eq!(live.entries(), before);
        };
        check(&live);

        let edits = live.edits();
        for p in &stale {
            let f = live.fetch(p.as_bytes(), false, &disk);
            live.apply(f, &disk);
        }
        check(&live);
        assert_eq!(live.edits(), edits);
    }

    #[test]
    fn a_change_named_in_an_unstored_spelling_lands_under_the_stored_path() {
        let tree = TempTree::new("live-spelling");
        fs::create_dir_all(tree.0.join("Projects/Inner")).unwrap();
        fs::write(tree.0.join("Projects/Inner/old.md"), b"").unwrap();
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let before = live.entries();
        assert!(
            tree.0.join("projects/Inner").is_dir(),
            "the test needs a case-insensitive temp folder"
        );
        fs::write(tree.0.join("Projects/Inner/spelled.md"), b"").unwrap();
        let f = live.fetch(format!("{root}/projects/Inner").as_bytes(), false, &disk);
        live.apply(f, &disk);
        assert_eq!(
            names(&live, "spelled"),
            [("spelled.md".to_owned(), format!("{root}/Projects/Inner"))]
        );
        assert_eq!(
            names(&live, "inner"),
            [("Inner".to_owned(), format!("{root}/Projects"))]
        );
        assert_eq!(live.entries(), before + 1);
    }

    #[test]
    fn a_live_scan_out_of_descriptors_is_not_saved_as_finished() {
        use std::os::unix::fs::MetadataExt;
        let tree = TempTree::new("live-cut");
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        fs::create_dir(tree.0.join("New")).unwrap();
        for name in ["n1.txt", "n2.txt", "n3.txt"] {
            fs::write(tree.0.join("New").join(name), b"").unwrap();
        }
        let new = fs::metadata(tree.0.join("New")).unwrap();
        crawl::CUT.set(vec![(new.dev(), new.ino(), libc::EMFILE)]);
        let f = live.fetch(root.as_bytes(), false, &disk);
        live.apply(f, &disk);
        assert!(crawl::CUT.with_borrow(Vec::is_empty), "the scan never ran");
        let file = tree.data().join(crate::index::FILE);
        Index::build(live.to_crawl(), PathBuf::from(&root), b"", 1, 1)
            .unwrap()
            .save(&file)
            .unwrap();
        let saved = Index::load(&file, PathBuf::from(&root)).unwrap();
        let folder = |name: &[u8]| {
            (1..saved.folders())
                .find(|&k| saved.ent_name(saved.dir_entry(k) as usize) == name)
                .unwrap()
        };
        assert!(!saved.dir_listed(folder(b"New")));
        assert_eq!(saved.block(folder(b"New")).len(), 1);
        assert!(saved.dir_listed(folder(b"Sub")));
        assert!(saved.child(folder(b"Sub"), b"DELTA.Txt").is_some());
        assert_eq!(saved.entries(), 8);
    }

    type State = (Vec<(bool, Attrs)>, BTreeMap<Vec<u8>, (Attrs, Vec<bool>)>);

    fn state(live: &Live) -> State {
        let base = (0..live.base.entries() as u32)
            .map(|i| (live.is_dead(i), live.attrs(i as usize)))
            .collect();
        let over = live
            .over
            .iter()
            .map(|(k, a)| {
                let flags = as_path(k)
                    .ancestors()
                    .skip(1)
                    .filter_map(|up| live.over.get(up.as_os_str().as_bytes()).map(|a| a.hidden))
                    .collect();
                (k.clone(), (*a, flags))
            })
            .collect();
        (base, over)
    }

    fn covered(live: &Live, before: &State, at: u64) -> Vec<Touched> {
        let after = state(live);
        let touched = live.touched_since(at).unwrap().to_vec();
        let based: HashSet<u32> = touched
            .iter()
            .filter_map(|t| match t {
                Touched::Base(i) => Some(*i),
                _ => None,
            })
            .collect();
        let has = |want: &Touched| touched.contains(want);
        for (i, (was, now)) in before.0.iter().zip(&after.0).enumerate() {
            assert!(
                was == now || based.contains(&(i as u32)),
                "base {i} changed untouched"
            );
        }
        for k in before.1.keys().chain(after.1.keys()) {
            let (was, now) = (before.1.get(k), after.1.get(k));
            if was.map(|w| w.0) != now.map(|n| n.0) {
                assert!(
                    has(&Touched::Over(k.clone())),
                    "{:?} changed untouched",
                    as_path(k)
                );
            } else if was != now {
                let under = |p: &Vec<u8>| k.starts_with(p) && k.get(p.len()) == Some(&b'/');
                assert!(
                    touched
                        .iter()
                        .any(|t| matches!(t, Touched::Subtree(p) if under(p))),
                    "{:?}'s folder flags changed untouched",
                    as_path(k)
                );
            }
        }
        touched
    }

    #[test]
    fn every_change_notes_what_it_touched() {
        let tree = TempTree::new("live-touched");
        fs::create_dir_all(tree.0.join("Sub/Inner")).unwrap();
        fs::create_dir(tree.0.join("Mount")).unwrap();
        for f in [
            "Sub/Inner/a.txt",
            "Sub/Inner/b.txt",
            "Mount/m.txt",
            "Shape",
            "size.txt",
            "opened.txt",
            "gone.txt",
        ] {
            fs::write(tree.0.join(f), b"base").unwrap();
        }
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        assert_eq!(live.touched_at(), 0);
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let path = |rel: &str| match rel {
            "" => root.clone().into_bytes(),
            rel => format!("{root}/{rel}").into_bytes(),
        };
        let step = |live: &mut Live, change: &dyn Fn(), folders: &[&str]| {
            change();
            let (before, at) = (state(live), live.touched_at());
            for folder in folders {
                let f = live.fetch(&path(folder), false, &disk);
                live.apply(f, &disk);
            }
            let touched = covered(live, &before, at);
            assert!(!touched.is_empty(), "{folders:?} noted nothing");
            touched
        };
        let id = |live: &Live, rel: &str| live.lookup(&path(rel)).unwrap();
        let root_rel = "";

        let t = step(
            &mut live,
            &|| fs::write(tree.0.join("new.txt"), b"").unwrap(),
            &[root_rel],
        );
        assert!(t.contains(&Touched::Over(path("new.txt"))));

        let gone = id(&live, "gone.txt");
        let t = step(
            &mut live,
            &|| fs::remove_file(tree.0.join("gone.txt")).unwrap(),
            &[root_rel],
        );
        assert!(t.contains(&Touched::Base(gone)));

        let size = id(&live, "size.txt");
        let t = step(
            &mut live,
            &|| fs::write(tree.0.join("size.txt"), b"longer").unwrap(),
            &[root_rel],
        );
        assert!(t.contains(&Touched::Base(size)) && t.contains(&Touched::Over(path("size.txt"))));

        let opened = id(&live, "opened.txt");
        let t = step(
            &mut live,
            &|| {
                let file = fs::File::options()
                    .write(true)
                    .open(tree.0.join("opened.txt"))
                    .unwrap();
                let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000);
                file.set_times(fs::FileTimes::new().set_accessed(at))
                    .unwrap();
            },
            &[root_rel],
        );
        assert!(t.contains(&Touched::Base(opened)));
        assert!(
            t.iter().all(|t| matches!(t, Touched::Base(_))),
            "an opened-only change stays in the base: {t:?}"
        );

        step(
            &mut live,
            &|| {
                fs::create_dir(tree.0.join("Hid")).unwrap();
                fs::write(tree.0.join("Hid/inner.txt"), b"").unwrap();
            },
            &[root_rel],
        );
        let t = step(
            &mut live,
            &|| {
                let c = std::ffi::CString::new(tree.0.join("Hid").as_os_str().as_bytes()).unwrap();
                assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
            },
            &[root_rel],
        );
        assert!(t.contains(&Touched::Subtree(path("Hid"))));

        let shape = id(&live, "Shape");
        let t = step(
            &mut live,
            &|| {
                fs::remove_file(tree.0.join("Shape")).unwrap();
                fs::create_dir(tree.0.join("Shape")).unwrap();
                fs::write(tree.0.join("Shape/x.txt"), b"").unwrap();
            },
            &[root_rel],
        );
        for want in [
            Touched::Base(shape),
            Touched::Over(path("Shape")),
            Touched::Over(path("Shape/x.txt")),
        ] {
            assert!(t.contains(&want), "file becomes folder: {want:?}");
        }

        let sub = id(&live, "Sub");
        let below = live.base.subtree(live.dir_of(sub).unwrap());
        assert!(below.len() >= 4);
        let t = step(
            &mut live,
            &|| fs::remove_dir_all(tree.0.join("Sub")).unwrap(),
            &[root_rel],
        );
        for i in std::iter::once(sub).chain(below.map(|i| i as u32)) {
            assert!(t.contains(&Touched::Base(i)), "base entry {i} below Sub");
        }

        let t = step(
            &mut live,
            &|| fs::remove_dir_all(tree.0.join("Hid")).unwrap(),
            &[root_rel],
        );
        for want in [
            Touched::Over(path("Hid")),
            Touched::Over(path("Hid/inner.txt")),
        ] {
            assert!(t.contains(&want), "overlay folder deleted: {want:?}");
        }

        step(
            &mut live,
            &|| fs::write(tree.0.join("Mount/n.txt"), b"").unwrap(),
            &["Mount"],
        );
        let m = id(&live, "Mount/m.txt");
        let (before, at) = (state(&live), live.touched_at());
        assert!(live.drop_below(&path("Mount")));
        let t = covered(&live, &before, at);
        for want in [Touched::Base(m), Touched::Over(path("Mount/n.txt"))] {
            assert!(t.contains(&want), "drop_below: {want:?}");
        }
    }

    #[test]
    fn the_journal_starts_again_past_its_cap() {
        let tree = TempTree::new("live-cap");
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let base = Arc::new(base);
        let mut live = Live::new(base.clone());
        let key = format!("{root}/new.txt").into_bytes();
        let attrs = |size| Attrs {
            kind: EngineKind::File,
            size,
            mtime: 1,
            created: 1,
            opened: 1,
            mount: false,
            hidden: false,
        };
        for n in 0..TOUCHED_MAX as u64 {
            live.journaled_put(key.clone(), attrs(n % 2));
        }
        assert_eq!(live.touched_at(), TOUCHED_MAX as u64);
        assert_eq!(live.touched_since(0).map(<[_]>::len), Some(TOUCHED_MAX));
        assert_eq!(live.touched_since(TOUCHED_MAX as u64), Some(&[][..]));
        live.journaled_put(key.clone(), attrs(2));
        assert_eq!(live.touched_at(), TOUCHED_MAX as u64 + 1);
        assert_eq!(live.touched_since(0), None, "touches were dropped after 0");
        assert_eq!(live.touched_since(TOUCHED_MAX as u64 - 1), None);
        assert_eq!(
            live.touched_since(TOUCHED_MAX as u64),
            Some(&[Touched::Over(key.clone())][..])
        );
        assert_eq!(live.touched_since(TOUCHED_MAX as u64 + 1), Some(&[][..]));
        assert_eq!(live.touched_since(TOUCHED_MAX as u64 + 2), None);
        live.journaled_put(key, attrs(2));
        assert_eq!(live.touched_at(), TOUCHED_MAX as u64 + 1);
        let beta = live.lookup(format!("{root}/beta.txt").as_bytes()).unwrap();
        let a = live.attrs(beta as usize);
        let at = live.touched_at();
        live.journaled_update(
            beta,
            Attrs {
                size: a.size + 1,
                ..a
            },
        );
        live.journaled_kill(beta);
        assert_eq!(
            live.touched_since(at),
            Some(&[Touched::Base(beta), Touched::Base(beta)][..])
        );
        let again = Live::new(base);
        assert_ne!(again.id(), live.id());
        assert_eq!(again.touched_at(), 0);
    }
}
