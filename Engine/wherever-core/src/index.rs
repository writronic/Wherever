use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::Write;
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::OnceLock;
use std::sync::atomic::{self, AtomicU64};

use crate::crawl::{Attrs, Crawl, NONE};
use crate::error::io_error;
use crate::rank::{Place, Places, reading};
use crate::sort::{fold, natural};
use crate::{EngineError, EngineHit, EngineKind};

pub const FILE: &str = "wherever.index";
const MAGIC: &[u8; 8] = b"WHVIDX16";
const FIELDS: usize = 12;
pub(crate) const OS_BUILD_BYTES: usize = 256;
const OS_BUILD_AT: usize = 8 + FIELDS * 8;
const HEADER: usize = OS_BUILD_AT + OS_BUILD_BYTES;
const EVENT_FIELD: usize = 4;
const SYNCED_FIELD: usize = 5;
const SKIPS_FIELD: usize = 7;
const PLAINS_FIELD: usize = 8;
const HISTORY_FIELD: usize = 10;
const FOLDER: u8 = EngineKind::Folder as u8;
const LINK: u8 = EngineKind::Link as u8;
const HIDDEN: u8 = 4;
const UNLISTED: u8 = 8;
const KIND_BITS: u8 = 3;

#[derive(Clone, Copy)]
enum Sec {
    Print,
    NameOff,
    Names,
    EntName,
    Kind,
    Size,
    Mtime,
    Created,
    Opened,
    DirStart,
    DirEntry,
    NameRank,
    DirRank,
    PlainId,
    PlainOff,
    Plain,
    Skips,
}
const NSEC: usize = 17;

pub struct Index {
    blob: Vec<u8>,
    root: PathBuf,
    n: usize,
    d: usize,
    u: usize,
    p: usize,
    off: [usize; NSEC],
    skipped: Vec<String>,
    places: OnceLock<Vec<Place>>,
}

pub struct Snapshot {
    pub crawl: Crawl,
    pub unlisted: HashSet<u32>,
}

impl From<Crawl> for Snapshot {
    fn from(crawl: Crawl) -> Self {
        Self {
            crawl,
            unlisted: HashSet::new(),
        }
    }
}

static SAVES: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
thread_local! {
    pub(crate) static BUILD_DELAY: std::cell::RefCell<Option<(std::time::Duration, std::sync::mpsc::Sender<()>)>> = const { std::cell::RefCell::new(None) };
}

pub(crate) fn write_whole(path: &Path, bytes: &[u8]) -> Result<(), EngineError> {
    let mut temp = path.as_os_str().to_owned();
    let n = SAVES.fetch_add(1, atomic::Ordering::Relaxed);
    temp.push(format!(".{}.{n}.tmp", process::id()));
    let temp = PathBuf::from(temp);
    let write = || {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        let mut file = File::create(&temp)?;
        file.write_all(bytes)?;
        file.sync_data()?;
        fs::rename(&temp, path)
    };
    write().map_err(|e| {
        let _ = fs::remove_file(&temp);
        io_error(&temp, e)
    })
}

pub(crate) fn temps(path: &Path) -> Vec<PathBuf> {
    let (Some(folder), Some(name)) = (path.parent(), path.file_name()) else {
        return Vec::new();
    };
    let Ok(dir) = fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut stem = name.as_bytes().to_vec();
    stem.push(b'.');
    dir.flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.as_bytes();
            name.starts_with(&stem) && name.ends_with(b".tmp")
        })
        .map(|e| e.path())
        .collect()
}

impl Index {
    #[cfg(test)]
    pub fn build(
        crawl: impl Into<Snapshot>,
        root: PathBuf,
        print: &[u8],
        event_id: u64,
        synced_at: u64,
    ) -> Result<Index, EngineError> {
        Self::build_until(crawl, root, print, event_id, synced_at, &|| false)
    }

    pub fn build_until(
        crawl: impl Into<Snapshot>,
        root: PathBuf,
        print: &[u8],
        event_id: u64,
        synced_at: u64,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Index, EngineError> {
        if cancelled() {
            return Err(EngineError::Stopped);
        }
        let Snapshot {
            crawl: Crawl {
                mut listings,
                failed,
            },
            unlisted,
        } = crawl.into();
        for l in &mut listings {
            if cancelled() {
                return Err(EngineError::Stopped);
            }
            #[cfg(test)]
            BUILD_DELAY.with_borrow(|delay| {
                if let Some((delay, reached)) = delay {
                    let _ = reached.send(());
                    std::thread::sleep(*delay);
                }
            });
            l.sort();
        }
        let failed: HashSet<u32> = failed.into_iter().collect();
        let by_id: HashMap<u32, usize> = listings
            .iter()
            .enumerate()
            .map(|(i, l)| (l.id, i))
            .collect();
        let mut ids: HashMap<&[u8], u32> = HashMap::new();
        let (mut name_off, mut names) = (vec![0u32], Vec::new());
        let (mut ent_name, mut kind, mut size, mut mtime) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let (mut created, mut opened) = (Vec::new(), Vec::new());
        let (mut dir_start, mut dir_entry, mut dir_parent) = (Vec::new(), Vec::new(), Vec::new());
        let cut = |id: &u32| by_id.get(id).is_some_and(|&i| listings[i].cut);
        let mut short: Vec<u32> = (failed.contains(&0) || cut(&0))
            .then_some(NONE)
            .into_iter()
            .collect();
        let mut stack = vec![(NONE, 0u32, 0u32)];
        while let Some((entry, id, parent)) = stack.pop() {
            if cancelled() {
                return Err(EngineError::Stopped);
            }
            let me = dir_entry.len() as u32;
            dir_start.push(ent_name.len() as u32);
            dir_entry.push(entry);
            dir_parent.push(parent);
            let Some(&li) = by_id.get(&id) else { continue };
            let l = &listings[li];
            let mut kids = Vec::new();
            for e in &l.ents {
                let at = ent_name.len() as u32;
                let raw = l.name(e);
                let next = ids.len() as u32;
                let k = *ids.entry(raw).or_insert_with(|| {
                    names.extend_from_slice(raw);
                    name_off.push(names.len() as u32);
                    next
                });
                if by_id.contains_key(&e.child) {
                    kids.push((at, e.child, me));
                }
                if failed.contains(&e.child) {
                    short.push(at);
                }
                ent_name.push(k);
                let incomplete = e.kind == EngineKind::Folder
                    && (!by_id.contains_key(&e.child)
                        || unlisted.contains(&e.child)
                        || cut(&e.child));
                kind.push(
                    e.kind as u8
                        | if e.hidden { HIDDEN } else { 0 }
                        | if incomplete { UNLISTED } else { 0 },
                );
                size.push(e.size);
                mtime.push(e.mtime);
                created.push(e.created);
                opened.push(e.opened);
            }
            stack.extend(kids.into_iter().rev());
        }
        dir_start.push(ent_name.len() as u32);
        let u = ids.len() as u64;
        drop(ids);
        drop(listings);
        let (mut plain_id, mut plain_off, mut plain) = (Vec::new(), vec![0u32], Vec::new());
        for (k, w) in name_off.windows(2).enumerate() {
            if cancelled() {
                return Err(EngineError::Stopped);
            }
            if let Some(r) = reading(&names[w[0] as usize..w[1] as usize]) {
                plain_id.push(k as u32);
                plain.extend_from_slice(r.as_bytes());
                plain_off.push(plain.len() as u32);
            }
        }
        let folded: Vec<String> = name_off
            .windows(2)
            .map(|w| {
                fold(&String::from_utf8_lossy(
                    &names[w[0] as usize..w[1] as usize],
                ))
            })
            .collect();
        if cancelled() {
            return Err(EngineError::Stopped);
        }
        let name_rank = ranks(&folded, |a, b| natural(a.as_bytes(), b.as_bytes()));
        let mut paths: Vec<String> = Vec::with_capacity(dir_entry.len());
        for (&e, &up) in dir_entry.iter().zip(&dir_parent) {
            paths.push(if e == NONE {
                String::new()
            } else {
                format!(
                    "{}/{}",
                    paths[up as usize], folded[ent_name[e as usize] as usize]
                )
            });
        }
        drop((folded, dir_parent));
        if cancelled() {
            return Err(EngineError::Stopped);
        }
        let dir_rank = ranks(&paths, |a, b| a.cmp(b));
        drop(paths);
        if cancelled() {
            return Err(EngineError::Stopped);
        }

        let fields = [
            ent_name.len() as u64,
            dir_entry.len() as u64,
            u,
            names.len() as u64,
            event_id,
            synced_at,
            print.len() as u64,
            0,
            plain_id.len() as u64,
            plain.len() as u64,
            0,
            0,
        ];
        let mut blob = Vec::with_capacity(
            HEADER
                + print.len()
                + name_off.len() * 4
                + names.len()
                + ent_name.len() * (4 + 1 + 8 + 3 * 8)
                + (dir_start.len() + dir_entry.len()) * 4
                + (name_rank.len() + dir_rank.len()) * 4
                + (plain_id.len() + plain_off.len()) * 4
                + plain.len(),
        );
        blob.extend_from_slice(MAGIC);
        blob.extend(fields.iter().flat_map(|v| v.to_le_bytes()));
        blob.resize(HEADER, 0);
        blob.extend_from_slice(print);
        blob.extend(name_off.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend_from_slice(&names);
        blob.extend(ent_name.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend_from_slice(&kind);
        blob.extend(size.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(mtime.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(created.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(opened.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(dir_start.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(dir_entry.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(name_rank.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(dir_rank.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(plain_id.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend(plain_off.iter().flat_map(|v| v.to_le_bytes()));
        blob.extend_from_slice(&plain);
        let mut root = root;
        root.shrink_to_fit();
        let mut index = Index::parse(blob, root).map_err(|what| EngineError::Io {
            message: format!("built index: {what}"),
        })?;
        let mut met: Vec<String> = short
            .into_iter()
            .map(|at| {
                let mut path = index.path(at).to_string_lossy().into_owned();
                path.shrink_to_fit();
                path
            })
            .collect();
        met.sort();
        index.set_skips(met);
        if cancelled() {
            Err(EngineError::Stopped)
        } else {
            Ok(index)
        }
    }

    pub fn load(path: &Path, root: PathBuf) -> Result<Index, EngineError> {
        let blob = fs::read(path).map_err(|e| io_error(path, e))?;
        Index::parse(blob, root).map_err(|what| io_error(path, what))
    }

    pub fn save(&self, path: &Path) -> Result<(), EngineError> {
        write_whole(path, &self.blob)
    }

    pub fn entries(&self) -> u64 {
        self.n as u64
    }

    pub fn skipped(&self) -> &[String] {
        &self.skipped
    }

    pub fn fingerprint(&self) -> &[u8] {
        &self.blob[self.off[Sec::Print as usize]..self.off[Sec::NameOff as usize]]
    }

    pub fn event_id(&self) -> u64 {
        self.field(EVENT_FIELD)
    }

    pub fn synced_at(&self) -> u64 {
        self.field(SYNCED_FIELD)
    }

    pub fn history(&self) -> u128 {
        u128::from_le_bytes(word(&self.blob, 8 + HISTORY_FIELD * 8))
    }

    pub fn set_history(&mut self, uuid: u128) {
        let at = 8 + HISTORY_FIELD * 8;
        self.blob[at..at + 16].copy_from_slice(&uuid.to_le_bytes());
    }

    pub fn os_build(&self) -> [u8; OS_BUILD_BYTES] {
        word(&self.blob, OS_BUILD_AT)
    }

    pub fn set_os_build(&mut self, build: &[u8; OS_BUILD_BYTES]) {
        self.blob[OS_BUILD_AT..HEADER].copy_from_slice(build);
    }

    fn field(&self, k: usize) -> u64 {
        u64::from_le_bytes(word(&self.blob, 8 + k * 8))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn folders(&self) -> usize {
        self.d
    }

    pub fn dir_entry(&self, k: usize) -> u32 {
        self.u32_at(Sec::DirEntry, k)
    }

    pub fn dir_listed(&self, k: usize) -> bool {
        k == 0 || self.kind_byte(self.dir_entry(k) as usize) & UNLISTED == 0
    }

    pub fn block(&self, k: usize) -> Range<usize> {
        self.u32_at(Sec::DirStart, k) as usize..self.u32_at(Sec::DirStart, k + 1) as usize
    }

    pub fn subtree(&self, k: usize) -> Range<usize> {
        let folders = self.subtree_folders(k);
        self.u32_at(Sec::DirStart, k) as usize..self.u32_at(Sec::DirStart, folders.end) as usize
    }

    pub fn subtree_folders(&self, k: usize) -> Range<usize> {
        let mut end = k + 1;
        while end < self.d && self.parent(self.dir_entry(end) as usize) >= k {
            end += 1;
        }
        k..end
    }

    pub fn child(&self, k: usize, name: &[u8]) -> Option<u32> {
        let Range { mut start, mut end } = self.block(k);
        while start < end {
            let mid = start + (end - start) / 2;
            match self.ent_name(mid).cmp(name) {
                Ordering::Less => start = mid + 1,
                Ordering::Greater => end = mid,
                Ordering::Equal => return Some(mid as u32),
            }
        }
        None
    }

    pub fn attrs(&self, i: usize) -> Attrs {
        Attrs {
            kind: self.kind(i),
            size: u64::from_le_bytes(self.word(Sec::Size, i)),
            mtime: i64::from_le_bytes(self.word(Sec::Mtime, i)),
            created: i64::from_le_bytes(self.word(Sec::Created, i)),
            opened: i64::from_le_bytes(self.word(Sec::Opened, i)),
            mount: false,
            hidden: self.kind_byte(i) & HIDDEN != 0,
        }
    }

    fn kind(&self, i: usize) -> EngineKind {
        match self.kind_byte(i) & KIND_BITS {
            FOLDER => EngineKind::Folder,
            LINK => EngineKind::Link,
            _ => EngineKind::File,
        }
    }

    fn parse(blob: Vec<u8>, root: PathBuf) -> Result<Index, &'static str> {
        if blob.len() < HEADER || blob[..8] != *MAGIC {
            return Err("not a Wherever index of this version");
        }
        let field = |k: usize| u64::from_le_bytes(word(&blob, 8 + k * 8));
        let id_count = |k: usize| {
            usize::try_from(field(k))
                .ok()
                .filter(|&v| v < NONE as usize)
        };
        let (Some(n), Some(d), Some(u), Some(names_len), Some(p), Some(plain_len)) = (
            id_count(0),
            id_count(1),
            id_count(2),
            id_count(3),
            id_count(PLAINS_FIELD),
            id_count(PLAINS_FIELD + 1),
        ) else {
            return Err("a count is out of range");
        };
        let (Ok(print_len), Ok(skips_len)) = (
            usize::try_from(field(6)),
            usize::try_from(field(SKIPS_FIELD)),
        ) else {
            return Err("a section length is out of range");
        };
        if d == 0 {
            return Err("no root folder");
        }
        let lens = [
            Some(print_len),
            (u + 1).checked_mul(4),
            Some(names_len),
            n.checked_mul(4),
            Some(n),
            n.checked_mul(8),
            n.checked_mul(8),
            n.checked_mul(8),
            n.checked_mul(8),
            (d + 1).checked_mul(4),
            d.checked_mul(4),
            u.checked_mul(4),
            d.checked_mul(4),
            p.checked_mul(4),
            (p + 1).checked_mul(4),
            Some(plain_len),
            Some(skips_len),
        ];
        let mut off = [0; NSEC];
        let mut at = HEADER;
        for (k, len) in lens.into_iter().enumerate() {
            off[k] = at;
            at = len
                .and_then(|l| at.checked_add(l))
                .ok_or("the sections overflow")?;
        }
        if at != blob.len() {
            return Err("the file size does not match its header");
        }
        let mut index = Index {
            blob,
            root,
            n,
            d,
            u,
            p,
            off,
            skipped: Vec::new(),
            places: OnceLock::new(),
        };
        index.check(names_len, plain_len)?;
        index.skipped = index.parse_skips()?;
        Ok(index)
    }

    fn check(&self, names_len: usize, plain_len: usize) -> Result<(), &'static str> {
        let name_off = |k| self.u32_at(Sec::NameOff, k) as usize;
        if name_off(0) != 0
            || name_off(self.u) != names_len
            || (0..self.u).any(|k| name_off(k) > name_off(k + 1))
        {
            return Err("name offsets out of order");
        }
        if (0..self.n).any(|i| self.u32_at(Sec::EntName, i) as usize >= self.u) {
            return Err("an entry names no stored name");
        }
        if (0..self.n).any(|i| {
            let byte = self.kind_byte(i);
            byte & !(HIDDEN | UNLISTED) > LINK
                || (byte & UNLISTED != 0 && byte & KIND_BITS != FOLDER)
        }) {
            return Err("an unknown entry kind");
        }
        let start = |k| self.u32_at(Sec::DirStart, k) as usize;
        if start(0) != 0 || start(self.d) != self.n || (0..self.d).any(|k| start(k) > start(k + 1))
        {
            return Err("folder blocks out of order");
        }
        if self.u32_at(Sec::DirEntry, 0) != NONE {
            return Err("the root has an entry");
        }
        for k in 1..self.d {
            let e = self.u32_at(Sec::DirEntry, k) as usize;
            if e >= self.n || self.kind_byte(e) & KIND_BITS != FOLDER || self.parent(e) >= k {
                return Err("a folder points outside the tree");
            }
        }
        if (0..self.u).any(|k| self.u32_at(Sec::NameRank, k) as usize >= self.u)
            || (0..self.d).any(|k| self.u32_at(Sec::DirRank, k) as usize >= self.d)
        {
            return Err("a rank is out of range");
        }
        let plain_off = |j| self.u32_at(Sec::PlainOff, j) as usize;
        if plain_off(0) != 0
            || plain_off(self.p) != plain_len
            || (0..self.p).any(|j| plain_off(j) > plain_off(j + 1))
        {
            return Err("reading offsets out of order");
        }
        let plain_id = |j| self.u32_at(Sec::PlainId, j) as usize;
        if (0..self.p).any(|j| plain_id(j) >= self.u || (j > 0 && plain_id(j - 1) >= plain_id(j))) {
            return Err("a reading names no stored name");
        }
        Ok(())
    }

    fn parse_skips(&self) -> Result<Vec<String>, &'static str> {
        let mut rest = &self.blob[self.off[Sec::Skips as usize]..];
        let mut skips = Vec::new();
        while !rest.is_empty() {
            let (len, after) = rest.split_first_chunk::<4>().ok_or("a cut skip")?;
            let (path, after) = after
                .split_at_checked(u32::from_le_bytes(*len) as usize)
                .ok_or("a cut skip")?;
            let path = String::from_utf8(path.to_vec()).map_err(|_| "a skip path is not UTF-8")?;
            skips.push(path);
            rest = after;
        }
        skips.shrink_to_fit();
        Ok(skips)
    }

    pub fn set_skips(&mut self, skips: Vec<String>) {
        let start = self.off[Sec::Skips as usize];
        self.blob.truncate(start);
        self.blob
            .reserve_exact(skips.iter().map(|s| 4 + s.len()).sum());
        for s in &skips {
            self.blob.extend_from_slice(&(s.len() as u32).to_le_bytes());
            self.blob.extend_from_slice(s.as_bytes());
        }
        let len = (self.blob.len() - start) as u64;
        let at = 8 + SKIPS_FIELD * 8;
        self.blob[at..at + 8].copy_from_slice(&len.to_le_bytes());
        self.blob.shrink_to_fit();
        self.skipped = skips;
        self.skipped.shrink_to_fit();
    }

    pub fn places(&self, places: &Places, boot: bool) -> &[Place] {
        self.places.get_or_init(|| {
            let mut all = Vec::with_capacity(self.d);
            all.push(places.root(&self.root, boot));
            for k in 1..self.d {
                let e = self.dir_entry(k) as usize;
                let up = all[self.parent(e)];
                all.push(places.step(&up, self.ent_name(e), self.attrs(e).hidden));
            }
            all
        })
    }

    pub fn hit(&self, i: u32) -> EngineHit {
        let i = i as usize;
        let a = self.attrs(i);
        EngineHit {
            name: String::from_utf8_lossy(self.ent_name(i)).into_owned(),
            folder: self.folder(self.parent(i)).to_string_lossy().into_owned(),
            size: a.size,
            modified: a.mtime,
            created: a.created,
            opened: a.opened,
            kind: a.kind,
            matches: Vec::new(),
        }
    }

    fn path(&self, entry: u32) -> PathBuf {
        if entry == NONE {
            return self.root.clone();
        }
        let i = entry as usize;
        self.folder(self.parent(i))
            .join(OsStr::from_bytes(self.ent_name(i)))
    }

    pub fn folder(&self, mut k: usize) -> PathBuf {
        #[cfg(test)]
        crate::sort::tally(crate::sort::Count::Folder);
        let mut chain = Vec::new();
        while k != 0 {
            let e = self.u32_at(Sec::DirEntry, k) as usize;
            chain.push(OsStr::from_bytes(self.ent_name(e)));
            k = self.holder(e);
        }
        let mut path = self.root.clone();
        path.extend(chain.iter().rev());
        path
    }

    pub fn parent(&self, i: usize) -> usize {
        #[cfg(test)]
        crate::sort::tally(crate::sort::Count::Parent);
        self.holder(i)
    }

    fn holder(&self, i: usize) -> usize {
        let (mut lo, mut hi) = (0, self.d + 1);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.u32_at(Sec::DirStart, mid) as usize <= i {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo - 1
    }

    pub fn names(&self) -> usize {
        self.u
    }

    pub fn name(&self, k: usize) -> &[u8] {
        let names = self.off[Sec::Names as usize];
        let start = names + self.u32_at(Sec::NameOff, k) as usize;
        let end = names + self.u32_at(Sec::NameOff, k + 1) as usize;
        &self.blob[start..end]
    }

    pub fn name_id(&self, i: usize) -> usize {
        self.u32_at(Sec::EntName, i) as usize
    }

    pub fn ent_name(&self, i: usize) -> &[u8] {
        self.name(self.name_id(i))
    }

    #[cfg(test)]
    pub(crate) fn plains(&self) -> usize {
        self.p
    }

    pub fn plain_from(&self, k: usize) -> usize {
        let (mut lo, mut hi) = (0, self.p);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if (self.u32_at(Sec::PlainId, mid) as usize) < k {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    pub fn plain_name(&self, j: usize) -> Option<usize> {
        (j < self.p).then(|| self.u32_at(Sec::PlainId, j) as usize)
    }

    pub fn plain(&self, j: usize) -> &[u8] {
        let plain = self.off[Sec::Plain as usize];
        let start = plain + self.u32_at(Sec::PlainOff, j) as usize;
        let end = plain + self.u32_at(Sec::PlainOff, j + 1) as usize;
        &self.blob[start..end]
    }

    pub fn name_rank(&self, k: usize) -> u32 {
        self.u32_at(Sec::NameRank, k)
    }

    pub fn dir_rank(&self, k: usize) -> u32 {
        self.u32_at(Sec::DirRank, k)
    }

    fn kind_byte(&self, i: usize) -> u8 {
        self.blob[self.off[Sec::Kind as usize] + i]
    }

    fn u32_at(&self, s: Sec, i: usize) -> u32 {
        u32::from_le_bytes(self.word(s, i))
    }

    fn word<const N: usize>(&self, s: Sec, i: usize) -> [u8; N] {
        word(&self.blob, self.off[s as usize] + i * N)
    }
}

fn ranks(keys: &[String], cmp: impl Fn(&str, &str) -> Ordering) -> Vec<u32> {
    let mut order: Vec<usize> = (0..keys.len()).collect();
    order.sort_unstable_by(|&a, &b| cmp(&keys[a], &keys[b]));
    let mut rank = vec![0; keys.len()];
    for w in order.windows(2) {
        rank[w[1]] = rank[w[0]] + u32::from(cmp(&keys[w[0]], &keys[w[1]]) != Ordering::Equal);
    }
    rank
}

fn word<const N: usize>(blob: &[u8], at: usize) -> [u8; N] {
    blob[at..at + N].try_into().unwrap_or([0; N])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::Listing;
    use crate::crawl::tests::{TempTree, crawl};
    use crate::live::Live;
    use std::sync::{Arc, Barrier};
    use std::thread;

    const QUERIES: [&str; 9] = ["", "a", "TXT", "sub", "link", "zzz", "é", "alpah", "a/b !c"];

    fn built(tree: &TempTree, root: &str) -> Index {
        let mut index =
            Index::build(crawl(tree, &[], false), PathBuf::from(root), b"print", 9, 7).unwrap();
        index.set_skips(vec![
            Path::new(root).join("Gone").to_string_lossy().into_owned(),
        ]);
        index
    }

    fn parse(blob: &[u8]) -> Result<Index, &'static str> {
        Index::parse(blob.to_vec(), PathBuf::from("/"))
    }

    fn heap(index: &Index) -> usize {
        assert!(index.places.get().is_none());
        index.blob.capacity()
            + index.root.capacity()
            + index.skipped.capacity() * size_of::<String>()
            + index.skipped.iter().map(String::capacity).sum::<usize>()
    }

    #[test]
    fn a_million_entries_hold_exactly_the_bytes_the_layout_predicts() {
        let m = crate::engine::timing::million();
        let (root, print) = ("/timing", b"print");
        let listings = &m.crawl.listings;
        let (n, d) = (
            listings.iter().map(|l| l.ents.len()).sum::<usize>(),
            listings.len(),
        );
        assert_eq!(n, crate::engine::timing::ENTRIES);
        let (u, name_bytes, p, plain_bytes) = {
            let distinct: HashSet<&[u8]> = listings
                .iter()
                .flat_map(|l| l.ents.iter().map(|e| l.name(e)))
                .collect();
            let plains: Vec<String> = distinct.iter().filter_map(|s| reading(s)).collect();
            (
                distinct.len(),
                distinct.iter().map(|s| s.len()).sum::<usize>(),
                plains.len(),
                plains.iter().map(String::len).sum::<usize>(),
            )
        };
        assert!(0 < p && p < u / 4, "{p} readings of {u} names");
        let predicted = 8
            + size_of::<[u64; 12]>()
            + OS_BUILD_BYTES
            + print.len()
            + (u + 1) * size_of::<u32>()
            + name_bytes
            + n * (size_of::<u32>() + size_of::<u8>() + size_of::<u64>() + 3 * size_of::<i64>())
            + (d + 1) * size_of::<u32>()
            + d * size_of::<u32>()
            + (u + d) * size_of::<u32>()
            + (2 * p + 1) * size_of::<u32>()
            + plain_bytes
            + root.len();
        let built = Index::build(m.crawl, PathBuf::from(root), print, 1, 1).unwrap();
        assert_eq!(built.blob.capacity(), built.blob.len());
        assert_eq!(heap(&built), predicted);
        let tree = TempTree::new("index-memory");
        let file = tree.data().join(FILE);
        built.save(&file).unwrap();
        println!(
            "columns index: {} bytes on disk",
            fs::metadata(&file).unwrap().len()
        );
        drop(built);
        let index = Index::load(&file, PathBuf::from(root)).unwrap();
        let heap = heap(&index);
        println!(
            "memory: {heap} bytes for {n} entries, {:.2} bytes per entry; accent-free readings {p} of {u} names, {} bytes",
            heap as f64 / n as f64,
            2 * size_of::<u64>() + (2 * p + 1) * size_of::<u32>() + plain_bytes
        );
        assert_eq!(heap, predicted);
    }

    fn folded_name(index: &Index, k: usize) -> String {
        fold(&String::from_utf8_lossy(index.name(k)))
    }

    fn folded_folder(index: &Index, k: usize) -> String {
        fold(&index.folder(k).to_string_lossy())
    }

    fn adjacent(
        count: usize,
        rank: impl Fn(usize) -> u32,
        oracle: impl Fn(usize, usize) -> Ordering,
    ) -> (usize, usize) {
        let mut order: Vec<usize> = (0..count).collect();
        order.sort_by_key(|&k| rank(k));
        assert_eq!(order.first().map(|&k| rank(k)), Some(0));
        let (mut checks, mut ties) = (0, 0);
        for w in order.windows(2) {
            let o = oracle(w[0], w[1]);
            assert_eq!(
                rank(w[1]) - rank(w[0]),
                u32::from(o != Ordering::Equal),
                "{} then {}",
                w[0],
                w[1]
            );
            assert_ne!(o, Ordering::Greater, "{} then {}", w[0], w[1]);
            checks += 1;
            ties += usize::from(o == Ordering::Equal);
        }
        (checks, ties)
    }

    #[test]
    fn every_pair_compares_by_rank_as_the_folded_order() {
        let file = |kind| Attrs {
            kind,
            size: 0,
            mtime: 0,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        let listing = |id: u32, ents: &[(&[u8], u32)]| {
            let mut l = Listing::default();
            l.id = id;
            for &(name, child) in ents {
                let kind = if child == NONE {
                    EngineKind::File
                } else {
                    EngineKind::Folder
                };
                l.push(name, file(kind), child);
            }
            l
        };
        let listings = vec![
            listing(
                0,
                &[
                    (b"Report", NONE),
                    (b"a007", NONE),
                    (b"a7", NONE),
                    (b"a07x", NONE),
                    (b"bad\xffname", NONE),
                    ("É".as_bytes(), NONE),
                    ("é".as_bytes(), NONE),
                    ("İ".as_bytes(), NONE),
                    (b"i", NONE),
                    (b"x", 1),
                    (b"x-y", 2),
                    (b"\xfedir", 3),
                    (b"A", 4),
                    (b"a", 5),
                ],
            ),
            listing(1, &[(b"y", 6), (b"report", NONE)]),
            listing(2, &[(b"Report.txt", NONE)]),
            listing(3, &[("é".as_bytes(), NONE), (b"sub", 7)]),
            listing(4, &[(b"a7", NONE)]),
            listing(5, &[(b"a007", NONE)]),
            listing(6, &[(b"a07x", NONE)]),
            listing(7, &[(b"z", NONE)]),
        ];
        let crawl = Crawl {
            listings,
            failed: Vec::new(),
        };
        let index = Index::build(crawl, PathBuf::from("/"), b"print", 1, 1).unwrap();
        let (u, d) = (index.names(), index.folders());
        assert_eq!((u, d), (19, 8));
        let (mut pairs, mut ties) = ((0, 0), (0, 0));
        for a in 0..u {
            for b in 0..u {
                let o = natural(
                    folded_name(&index, a).as_bytes(),
                    folded_name(&index, b).as_bytes(),
                );
                assert_eq!(
                    index.name_rank(a).cmp(&index.name_rank(b)),
                    o,
                    "names {a} and {b}"
                );
                pairs.0 += 1;
                ties.0 += usize::from(a != b && o == Ordering::Equal);
            }
        }
        for a in 0..d {
            for b in 0..d {
                let o = folded_folder(&index, a).cmp(&folded_folder(&index, b));
                assert_eq!(
                    index.dir_rank(a).cmp(&index.dir_rank(b)),
                    o,
                    "folders {a} and {b}"
                );
                pairs.1 += 1;
                ties.1 += usize::from(a != b && o == Ordering::Equal);
            }
        }
        println!(
            "edge ranks: {} name pairs ({} tied), {} folder pairs ({} tied)",
            pairs.0, ties.0, pairs.1, ties.1
        );
        assert_eq!((pairs, ties), ((u * u, d * d), (10, 2)));
    }

    #[test]
    fn saved_name_ranks_are_pinned() {
        let want: [(&[u8], u32); 17] = [
            (b"a7", 0),
            (b"a007", 0),
            ("a７".as_bytes(), 0),
            (b"a07x", 1),
            (b"a10", 2),
            (b"bad\xffname", 3),
            ("İ".as_bytes(), 4),
            (b"I", 4),
            (b"i", 4),
            ("ı".as_bytes(), 4),
            (b"Report", 5),
            (b"report", 5),
            ("ＲＥＰＯＲＴ".as_bytes(), 5),
            ("É".as_bytes(), 6),
            ("é".as_bytes(), 6),
            ("\u{a7ce}".as_bytes(), 7),
            ("\u{a7cf}".as_bytes(), 7),
        ];
        let file = Attrs {
            kind: EngineKind::File,
            size: 0,
            mtime: 0,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        let mut listing = Listing::default();
        for (name, _) in want {
            listing.push(name, file, NONE);
        }
        let crawl = Crawl {
            listings: vec![listing],
            failed: Vec::new(),
        };
        let built = Index::build(crawl, PathBuf::from("/"), b"print", 1, 1).unwrap();
        let saved = parse(&built.blob).unwrap();
        assert_eq!(saved.names(), want.len());
        let got: Vec<(&[u8], u32)> = want
            .iter()
            .map(|&(name, _)| {
                let k = (0..saved.names()).find(|&k| saved.name(k) == name).unwrap();
                (name, saved.name_rank(k))
            })
            .collect();
        assert_eq!(got, want, "sort order changed: bump WHVIDX");
    }

    #[test]
    fn only_a_name_with_an_accent_stores_a_reading() {
        let file = Attrs {
            kind: EngineKind::File,
            size: 0,
            mtime: 0,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        let build = |names: &[&[u8]]| {
            let mut listing = Listing::default();
            for name in names {
                listing.push(name, file, NONE);
            }
            let crawl = Crawl {
                listings: vec![listing],
                failed: Vec::new(),
            };
            let built = Index::build(crawl, PathBuf::from("/"), b"print", 1, 1).unwrap();
            parse(&built.blob).unwrap()
        };
        let ascii = build(&[b"Alpha.txt", b"report", b".DS_Store", b"a b-c_d"]);
        assert_eq!(ascii.plains(), 0);
        assert_eq!(
            ascii.off[Sec::Skips as usize] - ascii.off[Sec::PlainId as usize],
            size_of::<u32>()
        );
        let names: [&[u8]; 20] = [
            b"Alpha.txt",
            "Ünal.txt".as_bytes(),
            "U\u{308}nal.txt".as_bytes(),
            "ılık.txt".as_bytes(),
            "IŞIK".as_bytes(),
            "Việt".as_bytes(),
            "日本語".as_bytes(),
            "Проект".as_bytes(),
            "Мой файл".as_bytes(),
            "Ёлка".as_bytes(),
            b"bad\xffname",
            "özet.pdf".as_bytes(),
            "Łódź".as_bytes(),
            b"report",
            "مدرس".as_bytes(),
            "مُدَرِّس".as_bytes(),
            "أحمد".as_bytes(),
            "كـتـاب".as_bytes(),
            "ＲＥＰＯＲＴ２０２６.pdf".as_bytes(),
            "a　b".as_bytes(),
        ];
        let index = build(&names);
        let mut stored: Vec<(&[u8], &[u8])> = (0..index.plains())
            .map(|j| (index.name(index.plain_name(j).unwrap()), index.plain(j)))
            .collect();
        stored.sort();
        let mut want: Vec<(&[u8], &[u8])> = [
            ("Ünal.txt", "Unal.txt"),
            ("U\u{308}nal.txt", "Unal.txt"),
            ("IŞIK", "ISIK"),
            ("Việt", "Viet"),
            ("Ёлка", "елка"),
            ("özet.pdf", "ozet.pdf"),
            ("Łódź", "Lodz"),
            ("مُدَرِّس", "مدرس"),
            ("أحمد", "احمد"),
            ("كـتـاب", "كتاب"),
            ("ＲＥＰＯＲＴ２０２６.pdf", "REPORT2026.pdf"),
            ("a　b", "a b"),
        ]
        .map(|(n, r)| (n.as_bytes(), r.as_bytes()))
        .to_vec();
        want.sort();
        assert_eq!(stored, want, "reading changed: bump WHVIDX");
        assert_eq!(index.plains(), 12);
        assert_eq!(index.plain_from(0), 0);
        assert_eq!(index.plain_from(index.names()), index.plains());
        for j in 0..index.plains() {
            assert_eq!(index.plain_from(index.plain_name(j).unwrap()), j);
        }
        assert_eq!(index.plain_name(index.plains()), None);
    }

    #[test]
    fn a_million_entries_rank_in_the_folded_order() {
        let index = Index::build(
            crate::engine::timing::million().crawl,
            PathBuf::from("/timing"),
            b"print",
            1,
            1,
        )
        .unwrap();
        let (u, d) = (index.names(), index.folders());
        let names: Vec<String> = (0..u).map(|k| folded_name(&index, k)).collect();
        let folders: Vec<String> = (0..d).map(|k| folded_folder(&index, k)).collect();
        let (name_checks, name_ties) = adjacent(
            u,
            |k| index.name_rank(k),
            |a, b| natural(names[a].as_bytes(), names[b].as_bytes()),
        );
        let (dir_checks, dir_ties) =
            adjacent(d, |k| index.dir_rank(k), |a, b| folders[a].cmp(&folders[b]));
        println!(
            "million ranks: {name_checks} name checks (u - 1 = {}, {name_ties} tied), {dir_checks} folder checks (d - 1 = {}, {dir_ties} tied)",
            u - 1,
            d - 1
        );
        assert_eq!((name_checks, dir_checks), (u - 1, d - 1));
    }

    #[test]
    fn skips_leave_no_spare_capacity() {
        let tree = TempTree::new("index-skip-slack");
        let mut index = built(&tree, "/");
        let skip = |path: &str| path.to_owned();
        let exact = |index: &Index| {
            assert_eq!(index.blob.capacity(), index.blob.len());
            assert_eq!(index.skipped.capacity(), index.skipped.len());
            assert!(index.skipped.iter().all(|s| s.capacity() == s.len()));
        };
        exact(&index);
        index.set_skips((0..5).map(|k| skip(&format!("/Gone/{k}"))).collect());
        exact(&index);
        let file = tree.data().join(FILE);
        index.save(&file).unwrap();
        exact(&Index::load(&file, PathBuf::from("/")).unwrap());
        index.set_skips(vec![skip("/Gone")]);
        exact(&index);
        index.set_skips(Vec::new());
        exact(&index);
    }

    #[test]
    fn folders_join_below_a_root_of_slash() {
        let tree = TempTree::new("index-slash");
        let live = Live::new(Arc::new(parse(&built(&tree, "/").blob).unwrap()));
        let index = &live.base;
        let folder_of = |name: &str| {
            let rows = live.find(name, || false).unwrap().rows(0, usize::MAX);
            rows.into_iter().find(|h| h.name == name).unwrap().folder
        };
        assert_eq!(folder_of("Alpha.TXT"), "/");
        assert_eq!(folder_of("DELTA.Txt"), "/Sub");
        assert_eq!(index.entries(), 6);
        assert_eq!(index.fingerprint(), b"print");
        assert_eq!((index.event_id(), index.synced_at()), (9, 7));
        let sub = index.child(0, b"Sub").unwrap() as usize;
        assert_eq!(index.ent_name(sub), b"Sub");
        assert_eq!(index.child(0, b"Su"), None);
        assert_eq!(index.child(0, b"Sub2"), None);
        assert_eq!(index.skipped(), ["/Gone"]);
    }

    #[test]
    fn the_history_uuid_survives_a_save_and_a_load() {
        let tree = TempTree::new("index-history");
        let mut index = built(&tree, "/");
        assert_eq!(index.history(), 0);
        let uuid = 0x0011_2233_4455_6677_8899_aabb_ccdd_eeff;
        index.set_history(uuid);
        let mut build = [0; OS_BUILD_BYTES];
        build[..6].copy_from_slice(b"26A123");
        index.set_os_build(&build);
        index.set_skips(vec!["/Gone".to_owned(), "/Gone/Too".to_owned()]);
        let file = tree.data().join(FILE);
        index.save(&file).unwrap();
        let loaded = Index::load(&file, PathBuf::from("/")).unwrap();
        assert_eq!(loaded.history(), uuid);
        assert_eq!(loaded.os_build(), build);
        assert_eq!(loaded.fingerprint(), b"print");
        assert_eq!((loaded.event_id(), loaded.synced_at()), (9, 7));
        assert_eq!(loaded.skipped(), ["/Gone", "/Gone/Too"]);
    }

    #[test]
    fn a_saved_partial_listing_keeps_its_mark_and_known_children() {
        let tree = TempTree::new("index-unlisted");
        let crawl = crawl(&tree, &[], false);
        let root = crawl.listings.iter().find(|l| l.id == 0).unwrap();
        let sub = root
            .ents
            .iter()
            .find(|e| root.name(e) == b"Sub")
            .unwrap()
            .child;
        let index = Index::build(
            Snapshot {
                crawl,
                unlisted: HashSet::from([sub]),
            },
            PathBuf::from(tree.real()),
            b"print",
            9,
            7,
        )
        .unwrap();
        let folder = (1..index.folders())
            .find(|&k| index.ent_name(index.dir_entry(k) as usize) == b"Sub")
            .unwrap();
        assert!(!index.dir_listed(folder));
        assert!(index.dir_listed(0));
        assert!(index.child(folder, b"DELTA.Txt").is_some());
        let expected = heap(&built(&tree, &tree.real()));
        let mut index = index;
        index.set_skips(vec![
            Path::new(&tree.real())
                .join("Gone")
                .to_string_lossy()
                .into_owned(),
        ]);
        assert_eq!(heap(&index), expected);
        let file = tree.data().join(FILE);
        index.save(&file).unwrap();
        let loaded = Index::load(&file, PathBuf::from(tree.real())).unwrap();
        assert!(!loaded.dir_listed(folder));
        assert!(loaded.child(folder, b"DELTA.Txt").is_some());
        assert_eq!(heap(&loaded), expected);
    }

    #[test]
    fn a_listing_cut_by_an_error_is_saved_as_not_listed() {
        use std::os::unix::fs::MetadataExt;
        let tree = TempTree::new("index-cut");
        for name in ["e1.txt", "e2.txt", "e3.txt"] {
            fs::write(tree.0.join("Sub").join(name), b"").unwrap();
        }
        let sub = fs::metadata(tree.0.join("Sub")).unwrap();
        let file = tree.data().join(FILE);
        for (errno, listed) in [
            (libc::EIO, false),
            (libc::EINTR, false),
            (libc::EMFILE, false),
            (libc::EACCES, true),
            (libc::EPERM, true),
        ] {
            crate::crawl::CUT.set(vec![(sub.dev(), sub.ino(), errno)]);
            let crawl = crawl(&tree, &[], false);
            Index::build(crawl, PathBuf::from(tree.real()), b"print", 9, 7)
                .unwrap()
                .save(&file)
                .unwrap();
            let loaded = Index::load(&file, PathBuf::from(tree.real())).unwrap();
            let k = (1..loaded.folders())
                .find(|&k| loaded.ent_name(loaded.dir_entry(k) as usize) == b"Sub")
                .unwrap();
            assert_eq!(loaded.dir_listed(k), listed, "errno {errno}");
            assert_eq!(loaded.block(k).len(), 1, "errno {errno}");
            assert!(loaded.dir_listed(0));
            assert_eq!(loaded.entries(), 6, "errno {errno}");
            assert_eq!(loaded.skipped().is_empty(), errno != libc::EMFILE);
        }
    }

    fn left_temps(tree: &TempTree) -> Vec<String> {
        fs::read_dir(tree.data())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name.ends_with(".tmp"))
            .collect()
    }

    #[test]
    fn two_saves_at_once_leave_one_whole_file() {
        let (small, large) = (TempTree::new("index-race-a"), TempTree::new("index-race-b"));
        for i in 0..200 {
            fs::write(large.0.join(format!("more-{i:03}.txt")), b"").unwrap();
        }
        let (a, b) = (built(&small, "/"), built(&large, "/"));
        assert_ne!(a.blob.len(), b.blob.len());
        let file = small.data().join(FILE);
        let gate = Barrier::new(2);
        let mut failed = Vec::new();
        for round in 0..200 {
            let saves = thread::scope(|s| {
                let saving = [&a, &b].map(|index| {
                    let (gate, file) = (&gate, &file);
                    s.spawn(move || {
                        gate.wait();
                        index.save(file)
                    })
                });
                saving.map(|t| t.join().unwrap())
            });
            let saved = fs::read(&file).unwrap();
            assert!(
                saved == a.blob || saved == b.blob,
                "round {round}: the saved file is neither blob"
            );
            failed.extend(saves.into_iter().filter_map(Result::err));
        }
        assert!(failed.is_empty(), "{failed:?}");
        assert_eq!(left_temps(&small), Vec::<String>::new());
    }

    #[test]
    fn a_failed_save_leaves_no_temp_file() {
        let tree = TempTree::new("index-failed-save");
        let file = tree.data().join(FILE);
        fs::create_dir_all(file.join("in the way")).unwrap();
        assert!(built(&tree, "/").save(&file).is_err());
        assert_eq!(left_temps(&tree), Vec::<String>::new());
        assert!(file.is_dir());
    }

    #[test]
    fn parse_rejects_damaged_files() {
        let tree = TempTree::new("index-damaged");
        let blob = built(&tree, "/").blob;
        assert!(parse(&blob).is_ok());
        assert!(parse(&[]).is_err());
        for len in (0..blob.len()).step_by(7) {
            assert!(parse(&blob[..len]).is_err(), "cut at {len}");
        }
        for magic in [
            b"WHVIDX15",
            b"WHVIDX14",
            b"WHVIDX13",
            b"WHVIDX12",
            b"WHVIDX11",
            b"WHVIDX10",
            b"WHVIDX09",
            b"WHVIDX08",
            b"WHVIDX07",
            b"WHVIDX06",
            b"WHVIDX05",
            b"WHVIDX04",
            b"WHVIDX03",
            b"WHVIDX02",
            b"WHVIDX01",
            b"WHVIDX00",
            b"FSIDX014",
            b"\0\0\0\0\0\0\0\0",
        ] {
            let mut b = blob.clone();
            b[..8].copy_from_slice(magic);
            assert!(parse(&b).is_err());
        }
        for field in [0, 1, 2, 3, 6, SKIPS_FIELD, PLAINS_FIELD, PLAINS_FIELD + 1] {
            for v in [u64::MAX, u64::MAX - 1, u64::MAX / 8, 1 << 32] {
                let mut b = blob.clone();
                b[8 + field * 8..16 + field * 8].copy_from_slice(&v.to_le_bytes());
                assert!(parse(&b).is_err(), "field {field} = {v}");
            }
        }
        let kind = parse(&blob).unwrap().off[Sec::Kind as usize];
        for (byte, ok) in [
            (HIDDEN, true),
            (HIDDEN | LINK, true),
            (7, false),
            (8, false),
            (UNLISTED | LINK, false),
            (UNLISTED | FOLDER, true),
            (UNLISTED | HIDDEN | FOLDER, true),
            (16 | FOLDER, false),
        ] {
            let mut b = blob.clone();
            b[kind] = byte;
            assert_eq!(parse(&b).is_ok(), ok, "kind byte {byte}");
        }
    }

    #[test]
    fn flipped_bytes_never_panic() {
        let tree = TempTree::new("index-flips");
        fs::write(tree.0.join("Ünal.txt"), b"").unwrap();
        let index = built(&tree, "/");
        let mut bounds = vec![(0, HEADER)];
        for k in 0..NSEC {
            let end = index.off.get(k + 1).copied().unwrap_or(index.blob.len());
            assert!(end > index.off[k], "section {k} is empty");
            bounds.push((index.off[k], end));
        }
        let mut seed = 0x2545_f491_4f6c_dd1d_u64;
        for flip in 0..200 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let (start, end) = bounds[flip % bounds.len()];
            let mut b = index.blob.clone();
            b[start + (seed % (end - start) as u64) as usize] ^= (seed >> 56) as u8 | 1;
            if let Ok(flipped) = parse(&b) {
                let live = Live::new(Arc::new(flipped));
                for q in QUERIES {
                    let rows = live.find(q, || false).unwrap().rows(0, usize::MAX);
                    let query = crate::query::Query::parse(q, "/");
                    for h in rows {
                        crate::rank::positions(&query, h.name.as_bytes());
                    }
                }
            }
        }
    }
}
