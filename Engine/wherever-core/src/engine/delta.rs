use std::collections::HashMap;
use std::sync::Arc;

use super::{Results, Shared, parse};
use crate::crawl::NONE;
use crate::live::{Added, Folder, Found, Live, Seen, Touched};
use crate::query::{self, Hit, Query, Shown};
use crate::rank::Places;
use crate::sort::{self, Ranked, RowKey};
use crate::{EngineColumn, EngineSort};

const DELTA_MAX: usize = 2_000;

pub(crate) enum Patch {
    Done(Results),
    Cancelled,
    Full(#[cfg_attr(not(test), expect(dead_code))] Why),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Why {
    Unseen,
    Subset,
    Relevance,
    Sort,
    Words,
    Scope,
    Query,
    Units,
    Replaced,
    Cut,
    NotUtf8,
    Many,
}

pub(crate) struct Changes {
    seen: Seen,
    judged: Found,
    hits: Vec<Hit>,
    base: Vec<Edit>,
    over: Vec<Edit>,
}

#[derive(Clone, Copy)]
struct Edit {
    at: u32,
    old: bool,
    new: u32,
}

pub(super) fn patch(
    shared: &Shared,
    held: &Results,
    generation: u64,
    text: &str,
    sort: EngineSort,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Patch {
    #[cfg(test)]
    {
        let hold = shared.patch_hold.lock().unwrap().take();
        if let Some((reached, release)) = hold {
            let _ = reached.send(generation);
            let _ = release.recv_timeout(std::time::Duration::from_secs(10));
        }
    }
    let q = parse(shared, text);
    if let Err(why) = eligible(held, &q, sort) {
        return Patch::Full(why);
    }
    let units = shared.units().to_vec();
    let places = Places::new(&shared.settings.home);
    let (mut changes, mut why) = (Vec::with_capacity(held.found.len()), None);
    let reached = query::each_unit(&q, &shared.settings, &units, |u, _, shown| {
        if cancelled() {
            return None;
        }
        let got = match (shown, held.found.get(changes.len())) {
            (Shown::Live(live), Some(h)) => changes_of(&q, &places, u.id.is_none(), live, h),
            _ => Err(Why::Units),
        };
        match got {
            Ok(c) => changes.push(c),
            Err(w) => why = Some(w),
        }
        why.is_none().then_some(())
    });
    if cancelled() {
        return Patch::Cancelled;
    }
    if let Some(why) = why {
        return Patch::Full(why);
    }
    if reached != Some(true) || changes.len() != held.found.len() {
        return Patch::Full(Why::Units);
    }
    let done = patched(held, changes, generation, sort, cancelled);
    #[cfg(test)]
    if matches!(done, Patch::Done(_)) {
        shared
            .patches
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
    done
}

fn eligible(held: &Results, q: &Query, sort: EngineSort) -> Result<(), Why> {
    if held.found.is_empty() || held.found.iter().any(|f| f.seen.is_none()) {
        return Err(Why::Unseen);
    }
    if held.ranked.len() != held.found.iter().map(Found::count).sum::<usize>() {
        return Err(Why::Subset);
    }
    if sort.column == EngineColumn::Relevance {
        return Err(Why::Relevance);
    }
    if held.sort != sort {
        return Err(Why::Sort);
    }
    if !q.tokens.is_empty() {
        return Err(Why::Words);
    }
    if q.scope.is_some() {
        return Err(Why::Scope);
    }
    if *held.query != *q {
        return Err(Why::Query);
    }
    Ok(())
}

fn changes_of(
    q: &Query,
    places: &Places,
    boot: bool,
    live: &Live,
    held: &Found,
) -> Result<Changes, Why> {
    let seen = held.seen.ok_or(Why::Unseen)?;
    if seen.live != live.id() {
        return Err(Why::Replaced);
    }
    let touched = live.touched_since(seen.at).ok_or(Why::Cut)?;
    let (mut ids, mut paths): (Vec<u32>, Vec<&[u8]>) = (Vec::new(), Vec::new());
    for t in touched {
        match t {
            Touched::Base(i) => ids.push(*i),
            Touched::Over(p) => paths.push(p),
            Touched::Subtree(p) => {
                let mut lo = p.clone();
                if lo != b"/" {
                    lo.push(b'/');
                }
                let below = live.over.range(lo.clone()..).map(|(k, _)| k);
                paths.extend(below.take_while(|k| k.starts_with(&lo)).map(Vec::as_slice));
            }
        }
    }
    ids.sort_unstable();
    ids.dedup();
    paths.sort_unstable();
    paths.dedup();
    if ids.len() + paths.len() > DELTA_MAX {
        return Err(Why::Many);
    }
    if paths.iter().any(|p| std::str::from_utf8(p).is_err()) {
        return Err(Why::NotUtf8);
    }
    let paths: Vec<Vec<u8>> = paths.into_iter().map(<[u8]>::to_vec).collect();
    let (judged, hits) = query::judge(q, places, boot, live, &ids, &paths).ok_or(Why::Words)?;

    let mut next = judged.hits.iter().enumerate().peekable();
    let base = ids
        .iter()
        .map(|&id| {
            let (at, old) = match held.hits.binary_search(&id) {
                Ok(k) => (k, true),
                Err(k) => (k, false),
            };
            let new = next
                .next_if(|&(_, &j)| j == id)
                .map_or(NONE, |(n, _)| n as u32);
            Edit {
                at: at as u32,
                old,
                new,
            }
        })
        .collect();

    let (mut held_dir, mut judged_dir, mut lossy) = (None, None, false);
    let mut over = Vec::with_capacity(paths.len());
    let mut n = 0;
    for p in &paths {
        let at = held.added.binary_search_by(|a| {
            let path = held.added_path(a, &mut held_dir);
            lossy |= String::from_utf8_lossy(&path).contains(char::REPLACEMENT_CHARACTER);
            path.as_slice().cmp(p)
        });
        if lossy {
            return Err(Why::NotUtf8);
        }
        let new = if judged
            .added
            .get(n)
            .is_some_and(|a| judged.added_path(a, &mut judged_dir) == *p)
        {
            n += 1;
            n as u32 - 1
        } else {
            NONE
        };
        let (at, old) = match at {
            Ok(k) => (k, true),
            Err(k) => (k, false),
        };
        over.push(Edit {
            at: at as u32,
            old,
            new,
        });
    }
    Ok(Changes {
        seen: Seen {
            live: live.id(),
            at: live.touched_at(),
        },
        judged,
        hits,
        base,
        over,
    })
}

fn patched(
    held: &Results,
    changes: Vec<Changes>,
    generation: u64,
    sort: EngineSort,
    cancelled: &dyn Fn() -> bool,
) -> Patch {
    if changes
        .iter()
        .map(|c| c.base.len() + c.over.len())
        .sum::<usize>()
        > DELTA_MAX
    {
        return Patch::Full(Why::Many);
    }
    let (mut found, mut from, mut inserted) = (Vec::new(), Vec::new(), Vec::new());
    for (u, (h, c)) in held.found.iter().zip(changes).enumerate() {
        if cancelled() {
            return Patch::Cancelled;
        }
        let (f, k) = merged(h, c, u as u32, &mut inserted);
        found.push(f);
        from.push(k);
    }
    let old = (&held.found[..], &*held.places, &*held.gaps);
    let Some((places, gaps)) = sort::repatch(old, &found, &from, cancelled) else {
        return Patch::Cancelled;
    };
    if cancelled() {
        return Patch::Cancelled;
    }
    let to: Vec<Vec<u32>> = held
        .found
        .iter()
        .zip(&from)
        .map(|(h, from)| {
            let mut to = vec![NONE; h.count()];
            for (k, &o) in from.iter().enumerate().filter(|&(_, &o)| o != NONE) {
                to[o as usize] = k as u32;
            }
            to
        })
        .collect();
    let mut ranked: Vec<Ranked> = held
        .ranked
        .iter()
        .filter_map(|r| {
            let k = to[r.unit as usize][r.k as usize];
            (k != NONE).then_some(Ranked { k, ..*r })
        })
        .collect();
    drop(to);
    if cancelled() {
        return Patch::Cancelled;
    }
    let key = |r: &Ranked| sort::row_key(&found, &places, sort, r);
    let before = |a: &RowKey, b: &RowKey| if sort.ascending { a < b } else { a > b };
    let mut keyed: Vec<(RowKey, Ranked)> = inserted.into_iter().map(|r| (key(&r), r)).collect();
    keyed.sort_unstable_by(
        |(a, _), (b, _)| {
            if sort.ascending { a.cmp(b) } else { b.cmp(a) }
        },
    );
    let kept = ranked.len();
    let mut at = Vec::with_capacity(keyed.len());
    let mut lo = 0;
    for (x, _) in &keyed {
        lo += ranked[lo..].partition_point(|r| before(&key(r), x));
        at.push(lo);
    }
    ranked.extend(keyed.iter().map(|&(_, r)| r));
    let (mut end, mut write) = (kept, ranked.len());
    for (&at, (_, r)) in at.iter().zip(&keyed).rev() {
        ranked.copy_within(at..end, write - (end - at));
        write -= end - at + 1;
        ranked[write] = *r;
        end = at;
    }
    if cancelled() {
        return Patch::Cancelled;
    }
    Patch::Done(Results {
        generation,
        searched: generation,
        query: held.query.clone(),
        found: Arc::new(found),
        places: Arc::new(places),
        gaps: Arc::new(gaps),
        ranked,
        sort,
        patched: true,
    })
}

fn merged(h: &Found, c: Changes, unit: u32, inserted: &mut Vec<Ranked>) -> (Found, Vec<u32>) {
    let Changes {
        seen,
        judged,
        hits,
        base,
        over,
    } = c;
    let mut from = Vec::with_capacity(h.count() + base.len() + over.len());
    let new_row = |inserted: &mut Vec<Ranked>, n: usize, k: usize| {
        let hit = hits[n];
        inserted.push(Ranked {
            score: hit.score,
            file: hit.file,
            group: false,
            unit,
            k: k as u32,
        });
    };

    let mut rows = Vec::with_capacity(h.hits.len() + base.len());
    let mut i = 0;
    for e in &base {
        let at = e.at as usize;
        rows.extend_from_slice(&h.hits[i..at]);
        from.extend(i as u32..at as u32);
        i = at + usize::from(e.old);
        if e.new != NONE {
            new_row(inserted, e.new as usize, rows.len());
            rows.push(judged.hits[e.new as usize]);
            from.push(NONE);
        }
    }
    rows.extend_from_slice(&h.hits[i..]);
    from.extend(i as u32..h.hits.len() as u32);

    let (past, held_past) = (rows.len(), h.hits.len() as u32);
    let mut new_dirs = h.new_dirs.clone();
    let mut dirs: Option<HashMap<String, u32>> = None;
    let copy = |a: &Added| Added {
        name: a.name.clone(),
        attrs: a.attrs,
        folder: a.folder,
    };
    let mut added = Vec::with_capacity(h.added.len() + over.len());
    let mut i = 0;
    for e in &over {
        let at = e.at as usize;
        added.extend(h.added[i..at].iter().map(copy));
        from.extend(held_past + i as u32..held_past + at as u32);
        i = at + usize::from(e.old);
        if e.new != NONE {
            let a = &judged.added[e.new as usize];
            let folder = match a.folder {
                Folder::Base(d) => Folder::Base(d),
                Folder::New(d) => {
                    let dirs = dirs.get_or_insert_with(|| {
                        let mut by = HashMap::with_capacity(new_dirs.len());
                        for (d, p) in new_dirs.iter().enumerate() {
                            by.entry(p.clone()).or_insert(d as u32);
                        }
                        by
                    });
                    let path = &judged.new_dirs[d as usize];
                    Folder::New(*dirs.entry(path.clone()).or_insert_with(|| {
                        new_dirs.push(path.clone());
                        new_dirs.len() as u32 - 1
                    }))
                }
            };
            new_row(
                inserted,
                judged.hits.len() + e.new as usize,
                past + added.len(),
            );
            added.push(Added {
                name: a.name.clone(),
                attrs: a.attrs,
                folder,
            });
            from.push(NONE);
        }
    }
    added.extend(h.added[i..].iter().map(copy));
    from.extend(held_past + i as u32..held_past + h.added.len() as u32);

    let found = Found {
        index: h.index.clone(),
        hits: rows,
        updated: judged.updated.clone(),
        added,
        new_dirs,
        listed: Vec::new(),
        listed_dirs: Vec::new(),
        partial: None,
        seen: Some(seen),
    };
    (found, from)
}

#[cfg(test)]
pub(crate) fn patch_units(held: &Results, units: &[Live], text: &str, sort: EngineSort) -> Patch {
    let q = Query::parse(text, "/nonexistent");
    if let Err(why) = eligible(held, &q, sort) {
        return Patch::Full(why);
    }
    if units.len() != held.found.len() {
        return Patch::Full(Why::Units);
    }
    let places = Places::new(std::path::Path::new("/nonexistent"));
    let changes = units
        .iter()
        .zip(held.found.iter())
        .enumerate()
        .map(|(u, (live, h))| changes_of(&q, &places, u == 0, live, h))
        .collect::<Result<Vec<_>, _>>();
    match changes {
        Ok(changes) => patched(held, changes, held.generation + 1, sort, &|| false),
        Err(why) => Patch::Full(why),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{TempTree, crawl};
    use crate::crawl::{Attrs, Pool};
    use crate::engine::timing::{Rng, search};
    use crate::index::Index;
    use crate::live::{Disk, normalize};
    use crate::opens::Opens;
    use crate::sort::tests::edge_unit;
    use crate::{EngineHit, EngineKind};
    use std::fs;
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicBool;

    const QUERIES: [&str; 5] = ["", "kind:file", "ext:txt", "hidden:no", "size:>100"];

    fn sorts() -> Vec<EngineSort> {
        let columns = [
            EngineColumn::Name,
            EngineColumn::Folder,
            EngineColumn::Size,
            EngineColumn::Modified,
            EngineColumn::Created,
            EngineColumn::Opened,
            EngineColumn::Kind,
        ];
        let mut all = Vec::new();
        for column in columns {
            for ascending in [true, false] {
                for folders_first in [false, true] {
                    all.push(EngineSort {
                        column,
                        ascending,
                        folders_first,
                    });
                }
            }
        }
        all
    }

    fn done(p: Patch) -> Results {
        match p {
            Patch::Done(set) => set,
            Patch::Cancelled => panic!("the patch was cancelled"),
            Patch::Full(why) => panic!("a full refresh instead: {why:?}"),
        }
    }

    fn full(p: Patch) -> Why {
        match p {
            Patch::Full(why) => why,
            Patch::Done(_) => panic!("patched where a full refresh was due"),
            Patch::Cancelled => panic!("the patch was cancelled"),
        }
    }

    fn rows(set: &Results) -> Vec<EngineHit> {
        set.rows(0, set.ranked.len())
    }

    fn same(
        patched: &Results,
        units: &[Live],
        text: &str,
        sort: EngineSort,
        opens: &Opens,
        label: &str,
    ) {
        let fresh = search(units, text, sort, opens);
        assert_eq!(patched.count(), fresh.count(), "{label}: count");
        assert_eq!(rows(patched), rows(&fresh), "{label}: rows");
        for s in sorts() {
            let a = patched.sorted(2, s, opens, &|| false).unwrap();
            let b = fresh.sorted(2, s, opens, &|| false).unwrap();
            assert_eq!(rows(&a), rows(&b), "{label}: then sorted {s:?}");
        }
    }

    fn pick(rng: &mut Rng) -> (&'static str, EngineSort) {
        let all = sorts();
        (QUERIES[rng.below(QUERIES.len())], all[rng.below(all.len())])
    }

    const CHANGES: [&str; 11] = [
        "create a file",
        "delete a file",
        "rename a file",
        "rename a folder",
        "grow a file",
        "date a file",
        "open a file",
        "flip a new folder's hidden flag",
        "turn a file into a folder",
        "make a folder",
        "delete a folder",
    ];

    const NAMES: [&str; 20] = [
        "file1",
        "file01",
        "file001.txt",
        "File1.TXT",
        "Foo",
        "foo.md",
        ".hidden",
        ".env.txt",
        "a.tar.gz",
        "Résumé.pdf",
        "resume.PDF",
        "notes.md",
        "x.rs",
        "photo.JPG",
        "photo.jpg",
        "data.json",
        "README",
        "z10.txt",
        "z9.txt",
        "日本.txt",
    ];

    fn walk(root: &Path) -> (Vec<PathBuf>, Vec<PathBuf>) {
        let (mut files, mut dirs) = (Vec::new(), Vec::new());
        let mut todo = vec![root.to_path_buf()];
        while let Some(d) = todo.pop() {
            for e in fs::read_dir(&d).unwrap() {
                let p = e.unwrap().path();
                if fs::symlink_metadata(&p).unwrap().is_dir() {
                    todo.push(p.clone());
                    dirs.push(p);
                } else {
                    files.push(p);
                }
            }
        }
        files.sort();
        dirs.sort();
        (files, dirs)
    }

    fn hide(path: &Path, on: bool) -> bool {
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        let flags = if on { libc::UF_HIDDEN } else { 0 };
        unsafe { libc::chflags(c.as_ptr(), flags) == 0 }
    }

    fn change(
        root: &Path,
        rng: &mut Rng,
        made: &mut Vec<PathBuf>,
        n: usize,
    ) -> Option<(usize, Vec<PathBuf>)> {
        use std::io::Write;
        use std::os::macos::fs::MetadataExt;
        use std::time::{Duration, UNIX_EPOCH};

        let (files, dirs) = walk(root);
        let mut folders = dirs.clone();
        folders.push(root.to_path_buf());
        let any =
            |rng: &mut Rng, v: &[PathBuf]| (!v.is_empty()).then(|| v[rng.below(v.len())].clone());
        let name = |rng: &mut Rng| {
            let name = NAMES[rng.below(NAMES.len())];
            if rng.below(2) == 0 {
                name.to_owned()
            } else {
                format!("{n}{name}")
            }
        };
        let up = |p: &Path| p.parent().unwrap().to_path_buf();
        let kind = rng.below(CHANGES.len());
        let relist = match kind {
            0 => {
                let d = any(rng, &folders)?;
                fs::write(d.join(name(rng)), vec![b'x'; rng.below(300)]).ok()?;
                vec![d]
            }
            1 => {
                let f = any(rng, &files)?;
                fs::remove_file(&f).ok()?;
                vec![up(&f)]
            }
            2 => {
                let (f, d) = (any(rng, &files)?, any(rng, &folders)?);
                fs::rename(&f, d.join(name(rng))).ok()?;
                vec![up(&f), d]
            }
            3 => {
                let d = any(rng, &dirs)?;
                fs::rename(&d, up(&d).join(format!("Moved{n}"))).ok()?;
                vec![up(&d)]
            }
            4 => {
                let f = any(rng, &files)?;
                let mut file = fs::OpenOptions::new().append(true).open(&f).ok()?;
                file.write_all(&vec![b'y'; 1 + rng.below(200)]).ok()?;
                vec![up(&f)]
            }
            5 | 6 => {
                let f = any(rng, &files)?;
                let at = UNIX_EPOCH + Duration::from_secs(1_000_000 + rng.next() % 1_000_000_000);
                let times = if kind == 5 {
                    fs::FileTimes::new().set_modified(at)
                } else {
                    fs::FileTimes::new().set_accessed(at)
                };
                let file = fs::File::options().write(true).open(&f).ok()?;
                file.set_times(times).ok()?;
                vec![up(&f)]
            }
            7 => {
                made.retain(|d| d.is_dir());
                let d = any(rng, made)?;
                let hidden = fs::symlink_metadata(&d).ok()?.st_flags() & libc::UF_HIDDEN != 0;
                hide(&d, !hidden).then_some(())?;
                vec![up(&d)]
            }
            8 => {
                let f = any(rng, &files)?;
                fs::remove_file(&f).ok()?;
                fs::create_dir(&f).ok()?;
                fs::write(f.join(name(rng)), b"").ok()?;
                vec![up(&f)]
            }
            9 => {
                let d = any(rng, &folders)?;
                let p = d.join(format!("Made{n}"));
                fs::create_dir(&p).ok()?;
                fs::write(p.join(name(rng)), b"made").ok()?;
                made.push(p);
                vec![d]
            }
            _ => {
                let d = any(rng, &dirs)?;
                fs::remove_dir_all(&d).ok()?;
                vec![up(&d)]
            }
        };
        Some((kind, relist))
    }

    #[test]
    fn patches_equal_a_full_refresh_on_disk() {
        let tree = TempTree::new("delta-disk");
        let root = PathBuf::from(tree.real());
        let mut rng = Rng(0x0DE1_7A00);
        for d in ["A/B/C", ".dot/inner", "Docs/2024", "Media", "Hidden"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        let (_, dirs) = walk(&root);
        let folders = dirs.iter().chain(std::iter::once(&root)).cycle();
        for (j, d) in folders.take(240).enumerate() {
            let name = NAMES[j % NAMES.len()];
            let name = if j < 2 * NAMES.len() {
                name.to_owned()
            } else {
                format!("{j}{name}")
            };
            fs::write(d.join(name), vec![b'x'; rng.below(300)]).unwrap();
        }
        fs::write(root.join("Media/flagged.txt"), b"flagged").unwrap();
        assert!(hide(&root.join("Hidden"), true) && hide(&root.join("Media/flagged.txt"), true));
        let index = |crawl: crate::index::Snapshot| {
            Arc::new(Index::build(crawl, root.clone(), b"", 1, 1).unwrap())
        };
        let mut units = vec![Live::new(index(crawl(&tree, &[], false).into()))];
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let opens = Opens::new(tree.data().join("opens"));
        let (mut text, mut sort) = ("", sorts()[0]);
        let mut held = search(&units, text, sort, &opens);
        let (mut ran, mut made, mut serial) = ([0; CHANGES.len()], Vec::new(), 0);
        for batch in 0..400 {
            if batch % 10 == 0 {
                (text, sort) = pick(&mut rng);
                held = search(&units, text, sort, &opens);
            }
            if batch % 50 == 49 {
                units[0] = Live::new(index(units[0].to_crawl()));
                let why = full(patch_units(&held, &units, text, sort));
                assert_eq!(why, Why::Replaced, "a compaction");
                held = search(&units, text, sort, &opens);
                continue;
            }
            let mut relist = Vec::new();
            for _ in 0..1 + rng.below(3) {
                serial += 1;
                if let Some((kind, folders)) = change(&root, &mut rng, &mut made, serial) {
                    ran[kind] += 1;
                    relist.extend(folders);
                }
            }
            relist.sort();
            relist.dedup();
            let live = &mut units[0];
            if batch % 7 == 3 {
                let f = live.fetch(root.as_os_str().as_bytes(), true, &disk);
                live.apply(f, &disk);
            } else {
                for d in &relist {
                    let f = live.fetch(&normalize(d.as_os_str().as_bytes()), false, &disk);
                    live.apply(f, &disk);
                }
            }
            let set = done(patch_units(&held, &units, text, sort));
            same(
                &set,
                &units,
                text,
                sort,
                &opens,
                &format!("batch {batch}, {text:?}, {sort:?}"),
            );
            held = set;
        }
        for (change, n) in CHANGES.iter().zip(ran) {
            assert!(n > 0, "no batch could {change}");
        }
        assert_eq!(full(patch_units(&held, &units, "file", sort)), Why::Words);
        let scope = format!("in:{}", root.display());
        assert_eq!(full(patch_units(&held, &units, &scope, sort)), Why::Scope);
        let best = EngineSort {
            column: EngineColumn::Relevance,
            ascending: false,
            folders_first: false,
        };
        assert_eq!(full(patch_units(&held, &units, text, best)), Why::Relevance);
    }

    const TIES: [&str; 12] = [
        "Foo",
        "foo",
        "FOO",
        "file1",
        "file01",
        "File001",
        "report.txt",
        "Report.TXT",
        "novel",
        "Novel",
        "zz.md",
        "a",
    ];

    fn tie_units() -> Vec<Live> {
        const F: EngineKind = EngineKind::File;
        const D: EngineKind = EngineKind::Folder;
        let boot = edge_unit(
            "/t/ties",
            &[
                &[
                    (b"Foo", NONE, F),
                    (b"foo", NONE, F),
                    (b"file01", NONE, F),
                    (b"file1", NONE, F),
                    (b"file001.txt", NONE, F),
                    (b"Report.txt", NONE, F),
                    (b"a", 1, D),
                    (b"b", 2, D),
                    (b"A", 3, D),
                ],
                &[
                    (b"Report.txt", NONE, F),
                    (b"report.TXT", NONE, F),
                    (b"x", 4, D),
                ],
                &[
                    (b"Report.txt", NONE, F),
                    (b"file1", NONE, F),
                    (b"FILE01", NONE, F),
                ],
                &[(b"foo", NONE, F)],
                &[(b"deep.md", NONE, F)],
            ],
        );
        let disk = edge_unit(
            "/t/ties-disk",
            &[
                &[
                    (b"foo", NONE, F),
                    (b"FILE1", NONE, F),
                    (b"report.txt", NONE, F),
                    (b"z", 1, D),
                ],
                &[(b"Foo", NONE, F), (b"file1", NONE, F)],
            ],
        );
        vec![boot, disk]
    }

    #[test]
    fn patches_keep_ties_like_a_full_refresh() {
        let opens = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        let mut rng = Rng(0x7135_0000);
        let attrs = |rng: &mut Rng, kind| Attrs {
            kind,
            size: rng.next() % 300,
            mtime: 1_600_000_000 + (rng.next() % 1000) as i64,
            created: 1_500_000_000 + (rng.next() % 1000) as i64,
            opened: 1_700_000_000 + (rng.next() % 1000) as i64,
            mount: false,
            hidden: rng.below(5) == 0,
        };
        let join = |folder: &Path, name: &str| folder.join(name).into_os_string().into_vec();
        let mut units = tie_units();
        let (mut text, mut sort) = ("", sorts()[0]);
        let mut held = search(&units, text, sort, &opens);
        let mut ran = [0; 7];
        for round in 0..300 {
            if round % 60 == 0 {
                units = tie_units();
            }
            if round % 10 == 0 {
                (text, sort) = pick(&mut rng);
                held = search(&units, text, sort, &opens);
            }
            for _ in 0..1 + rng.below(4) {
                let live = &mut units[rng.below(2)];
                let base = live.base.clone();
                let k = rng.below(base.folders());
                let folder = base.folder(k);
                let news: Vec<Vec<u8>> = (live.over.iter())
                    .filter(|(_, a)| a.kind == EngineKind::Folder)
                    .map(|(p, _)| p.clone())
                    .collect();
                let new = (!news.is_empty()).then(|| news[rng.below(news.len())].clone());
                let i = rng.below(base.entries() as usize) as u32;
                let op = rng.below(ran.len());
                let did = match op {
                    0 => {
                        let a = attrs(&mut rng, EngineKind::File);
                        live.journaled_put(join(&folder, TIES[rng.below(TIES.len())]), a);
                        true
                    }
                    1 => {
                        let made = folder.join(["New", "new", "NEW"][rng.below(3)]);
                        let key = made.as_os_str().as_bytes().to_vec();
                        live.journaled_put(key, attrs(&mut rng, EngineKind::Folder));
                        let a = attrs(&mut rng, EngineKind::File);
                        live.journaled_put(join(&made, TIES[rng.below(TIES.len())]), a);
                        true
                    }
                    2 => new.is_some_and(|p| {
                        let a = live.over[&p];
                        live.journaled_put(
                            p,
                            Attrs {
                                hidden: !a.hidden,
                                ..a
                            },
                        );
                        true
                    }),
                    3 => {
                        let file = base.attrs(i as usize).kind != EngineKind::Folder;
                        let alive = file && !live.is_dead(i);
                        if alive {
                            live.journaled_kill(i);
                        }
                        alive
                    }
                    4 => {
                        let alive = k > 0 && rng.below(4) == 0 && !live.is_dead(base.dir_entry(k));
                        if alive {
                            live.journaled_kill(base.dir_entry(k));
                            live.drop_below(folder.as_os_str().as_bytes());
                        }
                        alive
                    }
                    5 => {
                        let alive = !live.is_dead(i);
                        if alive {
                            let a = live.attrs(i as usize);
                            live.journaled_update(
                                i,
                                Attrs {
                                    size: a.size + 1 + rng.next() % 50,
                                    ..a
                                },
                            );
                        }
                        alive
                    }
                    _ => new.is_some_and(|p| live.drop_below(&p)),
                };
                ran[op] += usize::from(did);
            }
            let set = done(patch_units(&held, &units, text, sort));
            same(
                &set,
                &units,
                text,
                sort,
                &opens,
                &format!("round {round}, {text:?}, {sort:?}"),
            );
            held = set;
        }
        assert!(ran.iter().all(|&n| n > 0), "every change ran: {ran:?}");
        let a = attrs(&mut rng, EngineKind::File);
        units[0].journaled_put(b"/t/ties/bad\xffname".to_vec(), a);
        assert_eq!(full(patch_units(&held, &units, text, sort)), Why::NotUtf8);
    }

    #[test]
    fn each_guard_answers_with_a_full_refresh() {
        let opens = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        let by_name = sorts()[0];
        let file = |size| Attrs {
            kind: EngineKind::File,
            size,
            mtime: 1_600_000_000,
            created: 1_500_000_000,
            opened: 0,
            mount: false,
            hidden: false,
        };
        let units = tie_units();
        let held = search(&units, "", by_name, &opens);
        same(
            &done(patch_units(&held, &units, "", by_name)),
            &units,
            "",
            by_name,
            &opens,
            "no change",
        );
        let mut subset = search(&units, "", by_name, &opens);
        subset.ranked.pop();
        assert_eq!(full(patch_units(&subset, &units, "", by_name)), Why::Subset);
        assert_ne!(sorts()[1], by_name);
        assert_eq!(full(patch_units(&held, &units, "", sorts()[1])), Why::Sort);
        let typed = search(&units, "ext:txt", by_name, &opens);
        assert_eq!(
            full(patch_units(&typed, &units, "kind:file", by_name)),
            Why::Query
        );
        assert_eq!(
            full(patch_units(&held, &units[..1], "", by_name)),
            Why::Units
        );
        let mut more = tie_units();
        more.push(tie_units().remove(1));
        assert_eq!(full(patch_units(&held, &more, "", by_name)), Why::Units);

        let mut units = tie_units();
        let held = search(&units, "", by_name, &opens);
        for n in 0..DELTA_MAX {
            units[0].journaled_put(format!("/t/ties/many{n}").into_bytes(), file(1));
        }
        same(
            &done(patch_units(&held, &units, "", by_name)),
            &units,
            "",
            by_name,
            &opens,
            "DELTA_MAX changes",
        );
        units[0].journaled_put(b"/t/ties/one-more".to_vec(), file(1));
        assert_eq!(full(patch_units(&held, &units, "", by_name)), Why::Many);

        let mut units = tie_units();
        let held = search(&units, "", by_name, &opens);
        for n in 0..crate::live::TOUCHED_MAX {
            units[0].journaled_update(1, file(n as u64 + 7));
        }
        let seen = held.found[0].seen.unwrap();
        assert!(units[0].touched_since(seen.at).is_some());
        units[0].journaled_update(1, file(3));
        assert!(units[0].touched_since(seen.at).is_none());
        assert_eq!(full(patch_units(&held, &units, "", by_name)), Why::Cut);
    }
}
