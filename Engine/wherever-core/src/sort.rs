use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};

use rayon::prelude::*;

use crate::crawl::NONE;
use crate::index::Index;
use crate::live::{Folder, Found};
use crate::query::{fold_char, pieces};
use crate::{EngineColumn, EngineKind, EngineSort};

#[cfg(test)]
#[derive(Clone, Copy)]
pub(crate) enum Count {
    Fold,
    Natural,
    Names,
    Folders,
    OverlaySorted,
    OverlayCompares,
    Streams,
    Folder,
    Parent,
    Merge,
    Built,
    Caller,
}

#[cfg(test)]
const COUNTS: usize = 12;

#[cfg(test)]
thread_local! {
    static TALLY: std::cell::Cell<[usize; COUNTS]> = const { std::cell::Cell::new([0; COUNTS]) };
}

#[cfg(test)]
pub(crate) fn tally(c: Count) {
    tally_by(c, 1);
}

#[cfg(test)]
fn tally_by(c: Count, n: usize) {
    TALLY.with(|t| {
        let mut v = t.get();
        v[c as usize] += n;
        t.set(v);
    });
}

#[cfg(test)]
pub(crate) fn tallies() -> [usize; COUNTS] {
    TALLY.with(|t| t.replace([0; COUNTS]))
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) struct Ranked {
    pub score: i32,
    pub file: bool,
    pub group: bool,
    pub unit: u32,
    pub k: u32,
}

pub(crate) type Places = Vec<Vec<[u32; 2]>>;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) struct Gap {
    pub at: u32,
    pub unit: u32,
    pub item: u32,
}

#[derive(Default, PartialEq, Debug)]
pub(crate) struct Gaps {
    pub names: Vec<Gap>,
    pub dirs: Vec<Gap>,
}

pub(crate) fn by_column(
    found: &[Found],
    places: &Places,
    ranked: &mut [Ranked],
    column: EngineColumn,
    folders: Option<bool>,
    cancelled: &dyn Fn() -> bool,
) -> Option<bool> {
    let exts = if column == EngineColumn::Kind {
        exts(found, cancelled)?
    } else {
        Vec::new()
    };
    if cancelled() {
        return None;
    }
    if ranked.par_iter().with_min_len(4096).any(|r| {
        #[cfg(test)]
        tally(Count::Caller);
        let (u, k) = (r.unit as usize, r.k as usize);
        places[u].get(k).is_none() || k >= found[u].count()
    }) {
        return Some(false);
    }
    if cancelled() {
        return None;
    }
    let mut keyed = Vec::with_capacity(ranked.len());
    ranked
        .par_iter()
        .with_min_len(4096)
        .map(|r| {
            #[cfg(test)]
            tally(Count::Caller);
            let (u, k) = (r.unit as usize, r.k as usize);
            let [name, folder] = places[u][k];
            let ext = exts.get(u).map_or(0, |e| e[k]);
            let first = first_key(&found[u], r, column, folder, ext).unwrap();
            let group = folders.is_some_and(|ahead| {
                ahead
                    != found[u]
                        .attrs(k)
                        .is_some_and(|a| a.kind == EngineKind::Folder)
            });
            let r = Ranked { group, ..*r };
            ((first, (u64::from(name) << 32) | u64::from(folder)), r)
        })
        .collect_into_vec(&mut keyed);
    if cancelled() {
        return None;
    }
    if folders.is_some() {
        keyed.par_sort_unstable_by_key(|&(key, r)| (r.group, key, r.unit, r.k));
    } else {
        keyed.par_sort_unstable_by_key(|&(key, r)| (key, r.unit, r.k));
    }
    if cancelled() {
        return None;
    }
    ranked
        .par_iter_mut()
        .zip(keyed.into_par_iter())
        .with_min_len(4096)
        .for_each(|(slot, (_, r))| {
            #[cfg(test)]
            tally(Count::Caller);
            *slot = Ranked { group: false, ..r };
        });
    (!cancelled()).then_some(folders.is_some())
}

fn first_key(f: &Found, r: &Ranked, column: EngineColumn, folder: u32, ext: u32) -> Option<u64> {
    let k = r.k as usize;
    Some(match column {
        EngineColumn::Relevance => {
            (u64::from(i32::MAX.abs_diff(r.score)) << 1) | u64::from(!r.file)
        }
        EngineColumn::Name => 0,
        EngineColumn::Folder => u64::from(folder),
        EngineColumn::Size => f.attrs(k)?.size,
        EngineColumn::Modified => (f.attrs(k)?.mtime as u64) ^ (1 << 63),
        EngineColumn::Created => (f.attrs(k)?.created as u64) ^ (1 << 63),
        EngineColumn::Opened => (f.attrs(k)?.opened as u64) ^ (1 << 63),
        EngineColumn::Kind => match f.attrs(k)?.kind {
            EngineKind::Folder => 0,
            EngineKind::Link => 1 << 32,
            EngineKind::File => (2 << 32) | u64::from(ext),
        },
    })
}

pub(crate) type RowKey = (bool, u64, String, u64, u32, u32);

pub(crate) fn row_key(found: &[Found], places: &Places, sort: EngineSort, r: &Ranked) -> RowKey {
    let (u, k) = (r.unit as usize, r.k as usize);
    let f = &found[u];
    let [name, folder] = places[u][k];
    let kind = f.attrs(k).map_or(EngineKind::File, |a| a.kind);
    let group = sort.folders_first && sort.ascending != (kind == EngineKind::Folder);
    let ext = if sort.column == EngineColumn::Kind && kind == EngineKind::File {
        let raw = match f.hits.get(k) {
            Some(&e) => f.index.name(f.index.name_id(e as usize)),
            None => f.added[k - f.hits.len()].name.as_bytes(),
        };
        let name = fold(&String::from_utf8_lossy(raw));
        name[ext_at(&name)..].to_owned()
    } else {
        String::new()
    };
    let first = first_key(f, r, sort.column, folder, 0).unwrap_or(0);
    let places = (u64::from(name) << 32) | u64::from(folder);
    (group, first, ext, places, r.unit, r.k)
}

pub(crate) fn places(found: &[Found], cancelled: &dyn Fn() -> bool) -> Option<(Places, Gaps)> {
    if cancelled() {
        return None;
    }
    let set: Vec<Arc<Index>> = found.iter().map(|f| f.index.clone()).collect();
    let cell = kept(&set);
    let m = cell.get_or_init(|| Merged::build(&set));
    let names: Vec<Cow<str>> = found
        .iter()
        .flat_map(|f| {
            let listed = (0..f.listed.len()).map(|n| {
                let (folder, e) = f.listed_at(n).unwrap();
                String::from_utf8_lossy(folder.listing.name(e))
            });
            f.added
                .iter()
                .map(|h| Cow::from(h.name.as_str()))
                .chain(listed)
        })
        .collect();
    #[cfg(test)]
    tally_by(Count::OverlaySorted, names.len());
    let name = |i: usize| names[i].as_bytes();
    let (name_class, name_reps, name_at) = classes(
        names.len(),
        |a, b| {
            #[cfg(test)]
            tally(Count::OverlayCompares);
            compare_names(name(a), name(b))
        },
        || {
            let mut from = None;
            let m = &m.names;
            move |i| {
                let compare = |&n: &u32| {
                    let (u, id) = m.item(n);
                    compare_names(found[u].index.name(id), name(i))
                };
                let result = match from {
                    None => m.reps.binary_search_by(compare),
                    Some(start) => match m.reps.get(start).map(compare) {
                        None | Some(Ordering::Greater) => Err(start),
                        Some(Ordering::Equal) => Ok(start),
                        Some(Ordering::Less) => 'search: {
                            let (mut lo, mut hi) = (start + 1, m.reps.len());
                            while lo < hi {
                                let mid = lo + (hi - lo) / 2;
                                match compare(&m.reps[mid]) {
                                    Ordering::Less => lo = mid + 1,
                                    Ordering::Greater => hi = mid,
                                    Ordering::Equal => break 'search Ok(mid),
                                }
                            }
                            Err(lo)
                        }
                    },
                };
                from = Some(match result {
                    Ok(n) => n + 1,
                    Err(n) => n,
                });
                result
            }
        },
    );
    if cancelled() {
        return None;
    }
    let folded: Vec<Vec<u8>> = found
        .iter()
        .flat_map(|f| {
            let listed =
                (0..f.listed_dirs.len() as u32).map(|d| f.listed_dir(d).path.to_string_lossy());
            f.new_dirs
                .iter()
                .map(|p| Cow::from(p.as_str()))
                .chain(listed)
        })
        .map(|p| {
            let mut buf = Vec::new();
            fold_into(&mut buf, p.as_bytes());
            buf
        })
        .collect();
    let (new_class, dir_reps, new_at) = classes(
        folded.len(),
        |a, b| folded[a].cmp(&folded[b]),
        || {
            let mut buf = Vec::new();
            let folded = &folded;
            let m = &m.dirs;
            move |i: usize| {
                m.reps.binary_search_by(|&n| {
                    let (u, k) = m.item(n);
                    Dir(&found[u].index, k).path_into(&mut buf);
                    #[cfg(test)]
                    tally(Count::Folders);
                    buf.as_slice().cmp(&folded[i])
                })
            }
        },
    );
    if cancelled() {
        return None;
    }
    let (mut name_starts, mut dir_starts) = (Vec::with_capacity(found.len()), Vec::new());
    let (mut n, mut d) = (0, 0);
    for f in found {
        name_starts.push(n);
        dir_starts.push(d);
        n += f.added.len() + f.listed.len();
        d += f.new_dirs.len() + f.listed_dirs.len();
    }
    let holder = |starts: &[usize], s: usize, row: bool| {
        let u = starts.partition_point(|&f| f <= s) - 1;
        let past = if row { found[u].hits.len() } else { 0 };
        [u as u32, (past + s - starts[u]) as u32]
    };
    let (name_remap, name_place, name_gaps) = insert(m.names.reps.len(), &name_at, |c| {
        holder(&name_starts, name_reps[c], true)
    });
    let (dir_remap, new_place, dir_gaps) = insert(m.dirs.reps.len(), &new_at, |c| {
        holder(&dir_starts, dir_reps[c], false)
    });
    let name_of = |g: u32| name_remap.as_ref().map_or(g, |r| r[g as usize]);
    let dir_of = |g: u32| dir_remap.as_ref().map_or(g, |r| r[g as usize]);
    let mut out = Vec::with_capacity(found.len());
    let (mut first_name, mut first_dir) = (0, 0);
    for (u, f) in found.iter().enumerate() {
        if cancelled() {
            return None;
        }
        let index = &*f.index;
        let (by_name, by_dir) = (&m.names.by_rank[u], &m.dirs.by_rank[u]);
        let mut v = Vec::with_capacity(f.count());
        f.hits
            .par_iter()
            .with_min_len(4096)
            .map_init(
                || None,
                |cursor, &e| {
                    let e = e as usize;
                    let at = cursor.get_or_insert_with(|| {
                        let (mut lo, mut hi) = (0, index.folders());
                        while lo < hi {
                            let mid = lo + (hi - lo) / 2;
                            if index.block(mid).end <= e {
                                lo = mid + 1;
                            } else {
                                hi = mid;
                            }
                        }
                        lo
                    });
                    while *at + 1 < index.folders() && index.block(*at).end <= e {
                        *at += 1;
                    }
                    [
                        name_of(by_name[index.name_rank(index.name_id(e)) as usize]),
                        dir_of(by_dir[index.dir_rank(*at) as usize]),
                    ]
                },
            )
            .collect_into_vec(&mut v);
        if cancelled() {
            return None;
        }
        v.par_extend(
            f.added
                .par_iter()
                .with_min_len(4096)
                .enumerate()
                .map(|(n, h)| {
                    #[cfg(test)]
                    tally(Count::Caller);
                    let folder = match h.folder {
                        Folder::Base(d) => dir_of(by_dir[index.dir_rank(d as usize) as usize]),
                        Folder::New(d) => new_place[new_class[first_dir + d as usize] as usize],
                    };
                    [name_place[name_class[first_name + n] as usize], folder]
                }),
        );
        let (listed_name, listed_dir) = (first_name + f.added.len(), first_dir + f.new_dirs.len());
        v.par_extend(
            f.listed
                .par_iter()
                .with_min_len(4096)
                .enumerate()
                .map(|(n, &[d, _])| {
                    #[cfg(test)]
                    tally(Count::Caller);
                    [
                        name_place[name_class[listed_name + n] as usize],
                        new_place[new_class[listed_dir + d as usize] as usize],
                    ]
                }),
        );
        if cancelled() {
            return None;
        }
        first_name += f.added.len() + f.listed.len();
        first_dir += f.new_dirs.len() + f.listed_dirs.len();
        out.push(v);
    }
    Some((
        out,
        Gaps {
            names: name_gaps,
            dirs: dir_gaps,
        },
    ))
}

#[derive(Clone, Copy)]
enum Spot {
    Merged(usize),
    Gap(usize),
    Novel(usize),
}

#[derive(Clone, Copy)]
struct Novel {
    g: usize,
    ins: usize,
    unit: u32,
    item: u32,
}

pub(crate) fn repatch(
    old: (&[Found], &Places, &Gaps),
    new: &[Found],
    from: &[Vec<u32>],
    cancelled: &dyn Fn() -> bool,
) -> Option<(Places, Gaps)> {
    let (held, held_places, held_gaps) = old;
    assert!(held.len() == new.len() && from.len() == new.len());
    for (u, (h, f)) in held.iter().zip(new).enumerate() {
        assert!(Arc::ptr_eq(&h.index, &f.index) && from[u].len() == f.count());
        assert!(
            h.listed.is_empty() && f.listed.is_empty(),
            "a first-crawl set is never patched"
        );
        debug_assert!(f.new_dirs.starts_with(&h.new_dirs));
    }
    if cancelled() {
        return None;
    }
    let set: Vec<Arc<Index>> = new.iter().map(|f| f.index.clone()).collect();
    let cell = kept(&set);
    let m = cell.get_or_init(|| Merged::build(&set));
    let span = |gaps: &[Gap], g: usize| {
        gaps.partition_point(|x| (x.at as usize) < g)..gaps.partition_point(|x| x.at as usize <= g)
    };
    let held_name = |x: &Gap| {
        let h = &held[x.unit as usize];
        h.added[x.item as usize - h.hits.len()].name.as_bytes()
    };
    let held_dir = |x: &Gap| {
        let mut key = Vec::new();
        fold_into(
            &mut key,
            held[x.unit as usize].new_dirs[x.item as usize].as_bytes(),
        );
        key
    };

    let (mut names, mut dirs) = (Vec::new(), Vec::new());
    let mut dir_spots: HashMap<(usize, u32), Spot> = HashMap::new();
    let mut inserted = Vec::new();
    for (u, f) in new.iter().enumerate() {
        if cancelled() {
            return None;
        }
        let index = &*f.index;
        let (by_name, by_dir) = (&m.names.by_rank[u], &m.dirs.by_rank[u]);
        let base_dir = |d: usize| Spot::Merged(by_dir[index.dir_rank(d) as usize] as usize);
        for (k, _) in from[u].iter().enumerate().filter(|&(_, &o)| o == NONE) {
            let (name, dir) = match f.hits.get(k) {
                Some(&e) => {
                    let e = e as usize;
                    let g = by_name[index.name_rank(index.name_id(e)) as usize] as usize;
                    (Spot::Merged(g), base_dir(index.parent(e)))
                }
                None => {
                    let h = &f.added[k - f.hits.len()];
                    let name = h.name.as_bytes();
                    let at = m.names.reps.binary_search_by(|&n| {
                        let (u, id) = m.names.item(n);
                        compare_names(new[u].index.name(id), name)
                    });
                    let spot = match at {
                        Ok(g) => Spot::Merged(g),
                        Err(g) => {
                            let gaps = &held_gaps.names;
                            match find_gap(gaps, span(gaps, g), |x| {
                                compare_names(held_name(x), name)
                            }) {
                                Ok(i) => Spot::Gap(i),
                                Err(ins) => {
                                    names.push(Novel {
                                        g,
                                        ins,
                                        unit: u as u32,
                                        item: k as u32,
                                    });
                                    Spot::Novel(names.len() - 1)
                                }
                            }
                        }
                    };
                    let dir = match h.folder {
                        Folder::Base(d) => base_dir(d as usize),
                        Folder::New(d) => *dir_spots.entry((u, d)).or_insert_with(|| {
                            let mut key = Vec::new();
                            fold_into(&mut key, f.new_dirs[d as usize].as_bytes());
                            let mut path = Vec::new();
                            let at = m.dirs.reps.binary_search_by(|&n| {
                                let (u, k) = m.dirs.item(n);
                                Dir(&new[u].index, k).path_into(&mut path);
                                path.as_slice().cmp(&key)
                            });
                            match at {
                                Ok(g) => Spot::Merged(g),
                                Err(g) => {
                                    let gaps = &held_gaps.dirs;
                                    match find_gap(gaps, span(gaps, g), |x| held_dir(x).cmp(&key)) {
                                        Ok(i) => Spot::Gap(i),
                                        Err(ins) => {
                                            dirs.push(Novel {
                                                g,
                                                ins,
                                                unit: u as u32,
                                                item: d,
                                            });
                                            Spot::Novel(dirs.len() - 1)
                                        }
                                    }
                                }
                            }
                        }),
                    };
                    (spot, dir)
                }
            };
            inserted.push((u, k, name, dir));
        }
    }
    if cancelled() {
        return None;
    }

    let name_key = |n: &Novel| {
        let f = &new[n.unit as usize];
        f.added[n.item as usize - f.hits.len()].name.as_bytes()
    };
    let (name_classes, name_class) = novel_classes(&names, |a, b| {
        compare_names(name_key(&names[a]), name_key(&names[b]))
    });
    let dir_keys: Vec<Vec<u8>> = dirs
        .iter()
        .map(|n| {
            let mut key = Vec::new();
            fold_into(
                &mut key,
                new[n.unit as usize].new_dirs[n.item as usize].as_bytes(),
            );
            key
        })
        .collect();
    let (dir_classes, dir_class) = novel_classes(&dirs, |a, b| dir_keys[a].cmp(&dir_keys[b]));
    let shift = |gaps: &[Gap], merged: usize, classes: &[Novel]| {
        let at: Vec<_> = classes.iter().map(|c| Err(c.g + c.ins)).collect();
        let (remap, place, _) = insert(merged + gaps.len(), &at, |_| [NONE, NONE]);
        (remap, place)
    };
    let (name_remap, name_novel) = shift(&held_gaps.names, m.names.reps.len(), &name_classes);
    let (dir_remap, dir_novel) = shift(&held_gaps.dirs, m.dirs.reps.len(), &dir_classes);
    if cancelled() {
        return None;
    }

    let mut out = Vec::with_capacity(new.len());
    for (u, from) in from.iter().enumerate() {
        if cancelled() {
            return None;
        }
        let held = &held_places[u];
        let mut v = Vec::with_capacity(from.len());
        from.par_iter()
            .with_min_len(4096)
            .map(|&k| {
                if k == NONE {
                    return [NONE, NONE];
                }
                let [name, dir] = held[k as usize];
                [
                    shifted(&name_remap, name as usize),
                    shifted(&dir_remap, dir as usize),
                ]
            })
            .collect_into_vec(&mut v);
        out.push(v);
    }
    for &(u, k, name, dir) in &inserted {
        out[u][k] = [
            placed(
                name,
                &held_gaps.names,
                &name_remap,
                &name_novel,
                &name_class,
            ),
            placed(dir, &held_gaps.dirs, &dir_remap, &dir_novel, &dir_class),
        ];
    }
    if cancelled() {
        return None;
    }

    let mut moved: Vec<Vec<u32>> = held.iter().map(|h| vec![NONE; h.added.len()]).collect();
    for (u, (h, f)) in held.iter().zip(new).enumerate() {
        for (k, &o) in from[u].iter().enumerate().skip(f.hits.len()) {
            if o != NONE {
                moved[u][o as usize - h.hits.len()] = k as u32;
            }
        }
    }
    let mut kept_names = held_gaps.names.clone();
    let mut lost = HashMap::new();
    for (i, x) in kept_names.iter_mut().enumerate() {
        if x.item != NONE {
            x.item = moved[x.unit as usize][x.item as usize - held[x.unit as usize].hits.len()];
            if x.item == NONE {
                lost.insert(x.at + i as u32, i);
            }
        }
    }
    if !lost.is_empty() {
        for (u, f) in new.iter().enumerate() {
            for (k, &o) in from[u].iter().enumerate().skip(f.hits.len()) {
                if o == NONE {
                    continue;
                }
                if let Some(&i) = lost.get(&held_places[u][o as usize][0])
                    && kept_names[i].item == NONE
                {
                    kept_names[i].unit = u as u32;
                    kept_names[i].item = k as u32;
                }
            }
        }
        for &(u, k, name, _) in &inserted {
            if let Spot::Gap(i) = name
                && kept_names[i].item == NONE
            {
                kept_names[i].unit = u as u32;
                kept_names[i].item = k as u32;
            }
        }
    }
    Some((
        out,
        Gaps {
            names: joined(&kept_names, &name_classes),
            dirs: joined(&held_gaps.dirs, &dir_classes),
        },
    ))
}

fn shifted(remap: &Option<Vec<u32>>, p: usize) -> u32 {
    remap.as_ref().map_or(p as u32, |r| r[p])
}

fn placed(s: Spot, gaps: &[Gap], remap: &Option<Vec<u32>>, novel: &[u32], class: &[usize]) -> u32 {
    match s {
        Spot::Merged(g) => shifted(remap, g + gaps.partition_point(|x| x.at as usize <= g)),
        Spot::Gap(i) => shifted(remap, gaps[i].at as usize + i),
        Spot::Novel(n) => novel[class[n]],
    }
}

fn novel_classes(
    items: &[Novel],
    cmp: impl Fn(usize, usize) -> Ordering,
) -> (Vec<Novel>, Vec<usize>) {
    let spot = |i: usize| (items[i].g, items[i].ins);
    let mut sorted: Vec<usize> = (0..items.len()).collect();
    sorted.sort_by(|&a, &b| spot(a).cmp(&spot(b)).then_with(|| cmp(a, b)));
    let (mut classes, mut class) = (Vec::new(), vec![0; items.len()]);
    for (n, &i) in sorted.iter().enumerate() {
        let same = n > 0 && {
            let p = sorted[n - 1];
            spot(p) == spot(i) && cmp(p, i) == Ordering::Equal
        };
        if !same {
            classes.push(items[i]);
        }
        class[i] = classes.len() - 1;
    }
    (classes, class)
}

fn find_gap(
    gaps: &[Gap],
    range: Range<usize>,
    cmp: impl Fn(&Gap) -> Ordering,
) -> Result<usize, usize> {
    let (mut lo, mut hi) = (range.start, range.end);
    let mut before = Err(range.end);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let Some(j) = (mid..hi).find(|&j| gaps[j].item != NONE) else {
            hi = mid;
            continue;
        };
        match cmp(&gaps[j]) {
            Ordering::Less => lo = j + 1,
            Ordering::Equal => return Ok(j),
            Ordering::Greater => {
                before = Err(j);
                hi = mid;
            }
        }
    }
    before
}

fn joined(gaps: &[Gap], classes: &[Novel]) -> Vec<Gap> {
    let mut out = Vec::with_capacity(gaps.len() + classes.len());
    let mut c = classes.iter().peekable();
    for (i, x) in gaps.iter().enumerate() {
        while let Some(n) = c.next_if(|n| n.ins <= i) {
            out.push(Gap {
                at: n.g as u32,
                unit: n.unit,
                item: n.item,
            });
        }
        out.push(*x);
    }
    out.extend(c.map(|n| Gap {
        at: n.g as u32,
        unit: n.unit,
        item: n.item,
    }));
    out
}

fn exts(found: &[Found], cancelled: &dyn Fn() -> bool) -> Option<Vec<Vec<u32>>> {
    let mut x = Exts::default();
    let mut ids = Vec::with_capacity(found.len());
    for f in found {
        let index = &*f.index;
        let mut by_id = vec![NONE; index.names()];
        let mut by_name: HashMap<&[u8], u32> = HashMap::new();
        let mut v = Vec::with_capacity(f.count());
        for (n, &e) in f.hits.iter().enumerate() {
            if n % 4096 == 0 && cancelled() {
                return None;
            }
            let id = index.name_id(e as usize);
            if by_id[id] == NONE && index.attrs(e as usize).kind == EngineKind::File {
                by_id[id] = x.id(index.name(id));
            }
            v.push(by_id[id]);
        }
        let listed = (0..f.listed.len()).map(|n| {
            let (folder, e) = f.listed_at(n).unwrap();
            (folder.listing.name(e), e.kind)
        });
        let added = f.added.iter().map(|h| (h.name.as_bytes(), h.attrs.kind));
        for (name, kind) in added.chain(listed) {
            v.push(if kind == EngineKind::File {
                *by_name.entry(name).or_insert_with(|| x.id(name))
            } else {
                NONE
            });
        }
        ids.push(v);
    }
    let rank = x.ranks();
    let place = |i: u32| rank.get(i as usize).copied().unwrap_or(0);
    Some(
        ids.into_iter()
            .map(|v| v.into_iter().map(place).collect())
            .collect(),
    )
}

fn classes<S: FnMut(usize) -> Result<usize, usize>>(
    n: usize,
    cmp: impl Fn(usize, usize) -> Ordering + Sync,
    search: impl Fn() -> S + Sync,
) -> (Vec<u32>, Vec<usize>, Vec<Result<usize, usize>>) {
    let mut sorted: Vec<usize> = (0..n).collect();
    sorted.par_sort_unstable_by(|&a, &b| cmp(a, b));
    let starts: Vec<bool> = sorted
        .par_iter()
        .with_min_len(4096)
        .enumerate()
        .map(|(i, &s)| {
            #[cfg(test)]
            tally(Count::Caller);
            i == 0 || cmp(sorted[i - 1], s) != Ordering::Equal
        })
        .collect();
    let (mut class, mut reps) = (vec![0; n], Vec::new());
    for (&s, start) in sorted.iter().zip(starts) {
        if start {
            reps.push(s);
        }
        class[s] = reps.len() as u32 - 1;
    }
    let step = reps.len().div_ceil(pieces(reps.len())).max(1);
    let mut at = vec![Err(0); reps.len()];
    at.par_chunks_mut(step)
        .zip(reps.par_chunks(step))
        .for_each(|(out, reps)| {
            let mut search = search();
            for (slot, &s) in out.iter_mut().zip(reps) {
                *slot = search(s);
            }
        });
    (class, reps, at)
}

fn insert(
    len: usize,
    at: &[Result<usize, usize>],
    item: impl Fn(usize) -> [u32; 2],
) -> (Option<Vec<u32>>, Vec<u32>, Vec<Gap>) {
    let gaps: Vec<Gap> = at
        .iter()
        .enumerate()
        .filter_map(|(c, a)| {
            a.err().map(|g| {
                let [unit, item] = item(c);
                Gap {
                    at: g as u32,
                    unit,
                    item,
                }
            })
        })
        .collect();
    let remap = (!gaps.is_empty()).then(|| {
        let mut c = 0;
        (0..len)
            .map(|g| {
                while gaps.get(c).is_some_and(|p| p.at as usize <= g) {
                    c += 1;
                }
                (g + c) as u32
            })
            .collect::<Vec<u32>>()
    });
    let mut before = 0;
    let place = at
        .iter()
        .map(|&a| match a {
            Ok(g) => remap.as_ref().map_or(g as u32, |r| r[g]),
            Err(g) => {
                before += 1;
                (g + before - 1) as u32
            }
        })
        .collect();
    (remap, place, gaps)
}

struct Merged {
    names: Order,
    dirs: Order,
}

struct Order {
    by_rank: Vec<Vec<u32>>,
    reps: Vec<u32>,
    first: Vec<u32>,
}

impl Order {
    fn new(order: &[u32], owner: &[u32], slots: Vec<Vec<u32>>, first: Vec<u32>) -> Order {
        let at = ranks(order);
        let place = |s: u32| at.get(s as usize).copied().unwrap_or(NONE);
        Order {
            by_rank: slots
                .into_iter()
                .map(|v| v.into_iter().map(place).collect())
                .collect(),
            reps: order.iter().map(|&s| owner[s as usize]).collect(),
            first,
        }
    }

    fn item(&self, n: u32) -> (usize, usize) {
        let u = self.first.partition_point(|&f| f <= n) - 1;
        (u, (n - self.first[u]) as usize)
    }
}

impl Merged {
    fn build(set: &[Arc<Index>]) -> Merged {
        #[cfg(test)]
        tally(Count::Built);
        let (mut names, mut dirs) = (Names::default(), Dirs::default());
        let (mut name_owner, mut dir_owner) = (Vec::new(), Vec::new());
        let (mut name_slots, mut dir_slots) = (Vec::new(), Vec::new());
        let (mut name_first, mut dir_first) = (Vec::new(), Vec::new());
        let (mut n, mut d) = (0, 0);
        for index in set {
            let index = &**index;
            name_first.push(n);
            dir_first.push(d);
            let (by, held) = holders(index.names(), |id| index.name_rank(id));
            let items: Vec<&[u8]> = held.iter().map(|&r| index.name(by[r] as usize)).collect();
            let placed = names.merge(&items);
            name_slots.push(slots(&by, &held, placed, &mut name_owner, n));
            let (by, held) = holders(index.folders(), |k| index.dir_rank(k));
            let run: Vec<Dir> = held.iter().map(|&r| Dir(index, by[r] as usize)).collect();
            let root = usize::from(!dirs.order.is_empty() && held.first() == Some(&0));
            let mut placed = Vec::with_capacity(run.len());
            dirs.place(&run[..root], &mut placed);
            dirs.place(&run[root..], &mut placed);
            dir_slots.push(slots(&by, &held, placed, &mut dir_owner, d));
            n += index.names() as u32;
            d += index.folders() as u32;
        }
        Merged {
            names: Order::new(&names.order, &name_owner, name_slots, name_first),
            dirs: Order::new(&dirs.order, &dir_owner, dir_slots, dir_first),
        }
    }
}

fn holders(n: usize, rank: impl Fn(usize) -> u32) -> (Vec<u32>, Vec<usize>) {
    let mut by = vec![NONE; n];
    for i in 0..n {
        by[rank(i) as usize] = i as u32;
    }
    let held = (0..n).filter(|&r| by[r] != NONE).collect();
    (by, held)
}

fn slots(
    by: &[u32],
    held: &[usize],
    placed: Vec<u32>,
    owner: &mut Vec<u32>,
    first: u32,
) -> Vec<u32> {
    let mut slots = vec![NONE; by.len()];
    for (&r, s) in held.iter().zip(placed) {
        if s as usize == owner.len() {
            owner.push(first + by[r]);
        }
        slots[r] = s;
    }
    slots
}

type Key = Vec<Weak<Index>>;

static MERGED: Mutex<Vec<(Key, Arc<OnceLock<Merged>>)>> = Mutex::new(Vec::new());

fn kept(set: &[Arc<Index>]) -> Arc<OnceLock<Merged>> {
    let same = |key: &Key| {
        key.len() == set.len()
            && key
                .iter()
                .zip(set)
                .all(|(w, i)| std::ptr::eq(w.as_ptr(), Arc::as_ptr(i)))
    };
    let mut all = MERGED.lock().unwrap_or_else(PoisonError::into_inner);
    all.retain(|(key, _)| key.iter().all(|w| w.strong_count() > 0));
    if let Some((_, m)) = all.iter().find(|(key, _)| same(key)) {
        return m.clone();
    }
    let m = Arc::new(OnceLock::new());
    let key = set.iter().map(Arc::downgrade).collect();
    all.push((key, m.clone()));
    m
}

pub(crate) fn premerge(set: &[Arc<Index>]) {
    kept(set).get_or_init(|| Merged::build(set));
}

pub(crate) fn forget(index: &Arc<Index>) {
    MERGED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|(key, _)| {
            !key.iter()
                .any(|w| std::ptr::eq(w.as_ptr(), Arc::as_ptr(index)))
        });
}

#[cfg(test)]
pub(crate) fn held(index: &Arc<Index>) -> usize {
    let all = MERGED.lock().unwrap_or_else(PoisonError::into_inner);
    all.iter()
        .filter(|(key, _)| {
            key.iter()
                .any(|w| std::ptr::eq(w.as_ptr(), Arc::as_ptr(index)))
        })
        .count()
}

fn ranks(order: &[u32]) -> Vec<u32> {
    let mut rank = vec![0; order.len()];
    for (i, &s) in order.iter().enumerate() {
        rank[s as usize] = i as u32;
    }
    rank
}

#[derive(Default)]
struct Names<'a> {
    order: Vec<u32>,
    reps: Vec<&'a [u8]>,
}

impl<'a> Names<'a> {
    fn merge(&mut self, incoming: &[&'a [u8]]) -> Vec<u32> {
        let mut out = Vec::with_capacity(self.order.len() + incoming.len());
        let mut slots = Vec::with_capacity(incoming.len());
        let mut old = 0;
        for &name in incoming {
            let mut slot = None;
            while let Some(&s) = self.order.get(old) {
                #[cfg(test)]
                tally(Count::Merge);
                match compare_names(self.reps[s as usize], name) {
                    Ordering::Less => {}
                    Ordering::Equal => slot = Some(s),
                    Ordering::Greater => break,
                }
                out.push(s);
                old += 1;
                if slot.is_some() {
                    break;
                }
            }
            let s = slot.unwrap_or_else(|| {
                self.reps.push(name);
                let s = self.reps.len() as u32 - 1;
                out.push(s);
                s
            });
            slots.push(s);
        }
        out.extend_from_slice(&self.order[old..]);
        self.order = out;
        slots
    }
}

#[derive(Clone, Copy)]
struct Dir<'a>(&'a Index, usize);

impl Dir<'_> {
    fn path_into(self, buf: &mut Vec<u8>) {
        buf.clear();
        fold_into(buf, self.0.folder(self.1).as_os_str().as_bytes());
    }
}

#[derive(Default)]
struct Dirs<'a> {
    order: Vec<u32>,
    reps: Vec<Dir<'a>>,
    a: Vec<u8>,
    b: Vec<u8>,
}

impl<'a> Dirs<'a> {
    fn place(&mut self, run: &[Dir<'a>], slots: &mut Vec<u32>) {
        let (Some(&first), Some(&last)) = (run.first(), run.last()) else {
            return;
        };
        let (lo, hi) = (self.search(first, false), self.search(last, true));
        if lo == hi {
            let new = self.reps.len() as u32..(self.reps.len() + run.len()) as u32;
            self.reps.extend_from_slice(run);
            slots.extend(new.clone());
            self.order.splice(lo..lo, new);
        } else if run.len() == 1 {
            slots.push(self.order[lo]);
        } else {
            let (x, y) = run.split_at(run.len() / 2);
            self.place(x, slots);
            self.place(y, slots);
        }
    }

    fn search(&mut self, d: Dir<'a>, past: bool) -> usize {
        if self.order.is_empty() {
            return 0;
        }
        d.path_into(&mut self.a);
        let Dirs { order, reps, a, b } = self;
        order.partition_point(|&s| {
            reps[s as usize].path_into(b);
            #[cfg(test)]
            tally(Count::Folders);
            match b.as_slice().cmp(a.as_slice()) {
                Ordering::Less => true,
                Ordering::Equal => past,
                Ordering::Greater => false,
            }
        })
    }
}

#[derive(Default)]
struct Exts(HashMap<String, u32>);

impl Exts {
    fn id(&mut self, raw: &[u8]) -> u32 {
        let name = fold(&String::from_utf8_lossy(raw));
        let at = ext_at(&name);
        if let Some(&id) = self.0.get(&name[at..]) {
            return id;
        }
        let id = self.0.len() as u32;
        self.0.insert(name[at..].to_owned(), id);
        id
    }

    fn ranks(&self) -> Vec<u32> {
        let mut by: Vec<(&String, u32)> = self.0.iter().map(|(e, &id)| (e, id)).collect();
        by.sort_unstable();
        let mut rank = vec![0; by.len()];
        for (i, &(_, id)) in by.iter().enumerate() {
            rank[id as usize] = i as u32;
        }
        rank
    }
}

fn ext_at(name: &str) -> usize {
    name.rfind('.')
        .filter(|&d| d > 0)
        .map_or(name.len(), |d| d + 1)
}

pub(crate) fn fold(s: &str) -> String {
    #[cfg(test)]
    tally(Count::Fold);
    if s.is_ascii() {
        s.to_ascii_lowercase()
    } else {
        s.chars().flat_map(fold_char).collect()
    }
}

pub(crate) fn natural(a: &[u8], b: &[u8]) -> Ordering {
    #[cfg(test)]
    tally(Count::Natural);
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let (si, sj) = (i, j);
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let x = trim_zeros(&a[si..i]);
            let y = trim_zeros(&b[sj..j]);
            let o = x.len().cmp(&y.len()).then_with(|| x.cmp(y));
            if o != Ordering::Equal {
                return o;
            }
        } else if a[i] != b[j] {
            return a[i].cmp(&b[j]);
        } else {
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

fn trim_zeros(digits: &[u8]) -> &[u8] {
    let n = digits.iter().take_while(|&&d| d == b'0').count();
    &digits[n..]
}

pub(crate) fn compare_names(a: &[u8], b: &[u8]) -> Ordering {
    #[cfg(test)]
    tally(Count::Names);
    let starts = |s: &[u8], i: usize| s.get(i).is_none_or(|c| !(0x80..0xC0).contains(c));
    let mut shared = 0;
    while a.len() - shared >= 8
        && b.len() - shared >= 8
        && a[shared..shared + 8] == b[shared..shared + 8]
    {
        shared += 8;
    }
    while a
        .get(shared)
        .zip(b.get(shared))
        .is_some_and(|(x, y)| x == y)
    {
        shared += 1;
    }
    while shared > 0 && (a[shared - 1].is_ascii_digit() || !starts(a, shared) || !starts(b, shared))
    {
        shared -= 1;
    }
    let (mut i, mut j, mut mark) = (shared, shared, (shared, shared));
    loop {
        if starts(a, i) && starts(b, j) {
            mark = (i, j);
        }
        match (a.get(i), b.get(j)) {
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let (si, sj) = (i, j);
                while a.get(i).is_some_and(u8::is_ascii_digit) {
                    i += 1;
                }
                while b.get(j).is_some_and(u8::is_ascii_digit) {
                    j += 1;
                }
                let (x, y) = (trim_zeros(&a[si..i]), trim_zeros(&b[sj..j]));
                let o = x.len().cmp(&y.len()).then_with(|| x.cmp(y));
                if o != Ordering::Equal {
                    return o;
                }
            }
            (Some(x), Some(y)) if x == y || x.eq_ignore_ascii_case(y) => {
                i += 1;
                j += 1;
            }
            (Some(x), Some(y)) if x.is_ascii() && y.is_ascii() => {
                return x.to_ascii_lowercase().cmp(&y.to_ascii_lowercase());
            }
            (None, None) => return Ordering::Equal,
            (None, Some(_)) if mark == (i, j) => return Ordering::Less,
            (Some(_), None) if mark == (i, j) => return Ordering::Greater,
            _ => return natural_by(folded(&a[mark.0..]), folded(&b[mark.1..])),
        }
    }
}

fn fold_into(buf: &mut Vec<u8>, raw: &[u8]) {
    if raw.is_ascii() {
        buf.extend(raw.iter().map(u8::to_ascii_lowercase));
    } else {
        buf.extend(folded(raw));
    }
}

fn folded(raw: &[u8]) -> impl Iterator<Item = u8> + '_ {
    raw.utf8_chunks()
        .flat_map(|c| {
            c.valid()
                .chars()
                .chain((!c.invalid().is_empty()).then_some(char::REPLACEMENT_CHARACTER))
        })
        .flat_map(fold_char)
        .flat_map(|c| {
            let mut b = [0; 4];
            let n = c.encode_utf8(&mut b).len();
            b.into_iter().take(n)
        })
}

fn natural_by(a: impl Iterator<Item = u8>, b: impl Iterator<Item = u8>) -> Ordering {
    #[cfg(test)]
    tally(Count::Streams);
    let (mut a, mut b) = (a.peekable(), b.peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                while a.next_if_eq(&b'0').is_some() {}
                while b.next_if_eq(&b'0').is_some() {}
                let mut first = Ordering::Equal;
                loop {
                    match (a.next_if(u8::is_ascii_digit), b.next_if(u8::is_ascii_digit)) {
                        (Some(x), Some(y)) => first = first.then(x.cmp(&y)),
                        (Some(_), None) => return Ordering::Greater,
                        (None, Some(_)) => return Ordering::Less,
                        (None, None) => break,
                    }
                }
                if first != Ordering::Equal {
                    return first;
                }
            }
            (Some(x), Some(y)) => {
                if x != y {
                    return x.cmp(&y);
                }
                a.next();
                b.next();
            }
            (x, y) => return x.is_some().cmp(&y.is_some()),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crawl::{Attrs, Crawl, Listing};
    use crate::engine::timing::{BOOT, unit};
    use crate::live::{Added, Live};
    use std::cmp::Reverse;
    use std::collections::HashSet;
    use std::os::unix::ffi::OsStringExt;
    use std::path::PathBuf;
    use std::sync::Arc;

    const COLUMNS: [EngineColumn; 6] = [
        EngineColumn::Relevance,
        EngineColumn::Name,
        EngineColumn::Folder,
        EngineColumn::Size,
        EngineColumn::Modified,
        EngineColumn::Kind,
    ];

    const MAC: [(&str, usize); 3] = [
        ("/timing", 59_775),
        ("/Volumes/Disk1", 33_973),
        ("/Volumes/Disk2", 6_252),
    ];
    const ROWS: usize = 2_500;

    fn counted<T: Send>(f: impl FnOnce() -> T + Send) -> T {
        rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .build()
            .unwrap()
            .install(f)
    }

    fn by_column(
        found: &[Found],
        ranked: &mut [Ranked],
        column: EngineColumn,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<bool> {
        super::by_column(
            found,
            &places(found, cancelled)?.0,
            ranked,
            column,
            None,
            cancelled,
        )
    }

    fn attrs(kind: EngineKind, j: usize) -> Attrs {
        Attrs {
            kind,
            size: (j % 5) as u64,
            mtime: 1_600_000_000 + (j % 11) as i64,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        }
    }

    fn units(shape: &[(&str, usize)], rows: usize) -> Vec<Live> {
        let mut units: Vec<Live> = shape
            .iter()
            .map(|&(root, n)| {
                let index = Index::build(unit(n, BOOT).crawl, PathBuf::from(root), b"print", 1, 1);
                Live::new(Arc::new(index.unwrap()))
            })
            .collect();
        let live = &mut units[0];
        let base = live.base.clone();
        let mut seed = 0x00EE_21A7_u64;
        let mut below = |n: usize| {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (seed >> 33) as usize % n
        };
        for j in 0..rows {
            let mut path = base.folder(below(base.folders()));
            let name = match j % 4 {
                0 => {
                    path.push(format!("New {}", j % 3));
                    let folder = path.as_os_str().as_bytes().to_vec();
                    live.over.insert(folder, attrs(EngineKind::Folder, j));
                    format!("report-new{j}.txt")
                }
                1 => String::from_utf8_lossy(base.name(below(base.names()))).into_owned(),
                2 => format!("Report-new{j}.TXT"),
                _ => format!("notes-new{j}.md"),
            };
            path.push(name);
            live.over
                .insert(path.into_os_string().into_vec(), attrs(EngineKind::File, j));
        }
        units
    }

    fn search(units: &[Live], text: &str) -> (Vec<Found>, Vec<Ranked>) {
        let refs: Vec<&Live> = units.iter().collect();
        let (scanned, _) = Live::find_units(text, false, &refs, || false).unwrap();
        let (mut found, mut ranked) = (Vec::new(), Vec::new());
        for (u, (f, hits)) in scanned.into_iter().enumerate() {
            for h in &f.added {
                assert_eq!(
                    units[u].base_dir(f.folder(h.folder).as_bytes()),
                    match h.folder {
                        Folder::Base(d) => Some(d as usize),
                        Folder::New(_) => None,
                    }
                );
            }
            ranked.extend(hits.iter().enumerate().map(|(k, h)| Ranked {
                score: h.score,
                file: h.file,
                group: false,
                unit: u as u32,
                k: k as u32,
            }));
            found.push(f);
        }
        (found, ranked)
    }

    fn oracle(found: &[Found], ranked: &[Ranked], column: EngineColumn) -> Vec<Ranked> {
        let mut keyed: Vec<_> = ranked
            .iter()
            .map(|r| {
                let h = found[r.unit as usize].row(r.k as usize).unwrap();
                let name = fold(&h.name);
                let ext = match h.kind {
                    EngineKind::File => name
                        .rfind('.')
                        .filter(|&d| d > 0)
                        .map_or(String::new(), |d| name[d + 1..].to_owned()),
                    _ => String::new(),
                };
                let kind = match h.kind {
                    EngineKind::Folder => 0,
                    EngineKind::Link => 1,
                    EngineKind::File => 2,
                };
                let key = (
                    name,
                    fold(&h.folder),
                    h.size,
                    h.modified,
                    (kind, ext),
                    h.created,
                    h.opened,
                );
                (key, *r)
            })
            .collect();
        keyed.sort_by(|(a, ra), (b, rb)| {
            match column {
                EngineColumn::Relevance => {
                    (Reverse(ra.score), !ra.file).cmp(&(Reverse(rb.score), !rb.file))
                }
                EngineColumn::Folder => a.1.cmp(&b.1),
                EngineColumn::Size => a.2.cmp(&b.2),
                EngineColumn::Modified => a.3.cmp(&b.3),
                EngineColumn::Created => a.5.cmp(&b.5),
                EngineColumn::Opened => a.6.cmp(&b.6),
                EngineColumn::Kind => a.4.cmp(&b.4),
                EngineColumn::Name => Ordering::Equal,
            }
            .then_with(|| natural(a.0.as_bytes(), b.0.as_bytes()))
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| (ra.unit, ra.k).cmp(&(rb.unit, rb.k)))
        });
        keyed.into_iter().map(|(_, r)| r).collect()
    }

    fn check(found: &[Found], ranked: &[Ranked], column: EngineColumn, label: &str) {
        let want = oracle(found, ranked, column);
        for input in [ranked.to_vec(), ranked.iter().rev().copied().collect()] {
            let mut got = input;
            by_column(found, &mut got, column, &|| false).unwrap();
            assert_eq!(got.len(), want.len(), "{label} by {column:?}");
            if let Some(i) = (0..got.len()).find(|&i| got[i] != want[i]) {
                panic!(
                    "{label} by {column:?}: row {i} of {} is {:?}, the oracle's {:?}",
                    got.len(),
                    got[i],
                    want[i]
                );
            }
        }
    }

    fn classes(mut names: Vec<String>) -> usize {
        names.sort_by(|a, b| natural(a.as_bytes(), b.as_bytes()));
        let apart = names
            .windows(2)
            .filter(|w| natural(w[0].as_bytes(), w[1].as_bytes()) != Ordering::Equal)
            .count();
        apart + usize::from(!names.is_empty())
    }

    fn ceil_log2(n: usize) -> usize {
        n.next_power_of_two().trailing_zeros() as usize
    }

    #[test]
    fn digit_runs_compare_by_value() {
        let mut names = [
            "file10", "file2", "file1", "file", "file02x", "filea", "file2a",
        ];
        names.sort_by(|a, b| natural(a.as_bytes(), b.as_bytes()));
        assert_eq!(
            names,
            [
                "file", "file1", "file2", "file2a", "file02x", "file10", "filea"
            ]
        );
        assert_eq!(natural(b"a007", b"a7"), Ordering::Equal);
        assert_eq!(fold("ÉB İx"), "éb ix");
    }

    pub(crate) fn edge_unit(root: &str, listings: &[&[(&[u8], u32, EngineKind)]]) -> Live {
        let mut j = 0;
        let listings = listings
            .iter()
            .enumerate()
            .map(|(id, ents)| {
                let mut l = Listing::default();
                l.id = id as u32;
                for &(name, child, kind) in *ents {
                    j += 1;
                    l.push(name, attrs(kind, j), child);
                }
                l
            })
            .collect();
        let crawl = Crawl {
            listings,
            failed: Vec::new(),
        };
        let index = Index::build(crawl, PathBuf::from(root), b"print", 1, 1).unwrap();
        Live::new(Arc::new(index))
    }

    #[test]
    fn edge_sets_sort_as_the_oracle() {
        const F: EngineKind = EngineKind::File;
        const D: EngineKind = EngineKind::Folder;
        const L: EngineKind = EngineKind::Link;
        let mut boot = edge_unit(
            "/t/edge",
            &[
                &[
                    (b"Report.txt", NONE, F),
                    (b"a007", NONE, F),
                    (b"a07x", NONE, F),
                    (b"bad\xffname", NONE, F),
                    ("É".as_bytes(), NONE, F),
                    ("İ".as_bytes(), NONE, F),
                    (b"file10", NONE, F),
                    (b"file2", NONE, F),
                    (b"0.5", NONE, F),
                    (b"a.0", NONE, F),
                    (b"a.00", NONE, F),
                    (b".hidden", NONE, F),
                    (b"link", NONE, L),
                    (b"x", 1, D),
                    (b"x-y", 2, D),
                    (b"sub", 3, D),
                    (b"A", 4, D),
                    (b"a", 5, D),
                ],
                &[(b"y", 6, D), (b"report.txt", NONE, F)],
                &[(b"Report.txt", NONE, F)],
                &[(b"deep", 7, D), (b"a7", NONE, F)],
                &[(b"a7", NONE, F), (b"a.00", NONE, L)],
                &[(b"a007", NONE, F)],
                &[(b"a07x", NONE, F), (b"a.0", 8, D)],
                &[(b"z.TXT", NONE, F)],
                &[],
            ],
        );
        let disk = edge_unit(
            "/t/edge-disk",
            &[
                &[
                    (b"report.TXT", NONE, F),
                    (b"REPORT.txt", NONE, F),
                    (b"a7", NONE, F),
                    (b"bad\xfename", NONE, F),
                    ("é".as_bytes(), NONE, F),
                    (b"i", NONE, F),
                    (b"file1", NONE, F),
                    (b"Zeta", 1, D),
                ],
                &[(b"file2", NONE, F)],
            ],
        );
        let inside = edge_unit(
            "/t/edge/sub",
            &[
                &[
                    (b"a", 1, D),
                    (b"z", 2, D),
                    (b"deep", 3, D),
                    (b"A7", NONE, F),
                ],
                &[(b"x.txt", NONE, F)],
                &[(b"y.txt", NONE, F)],
                &[(b"Z.txt", NONE, F)],
            ],
        );
        let over: [(&[u8], EngineKind); 11] = [
            (b"/t/edge/x/Report new.txt", F),
            (b"/t/edge/report.txt", F),
            (b"/t/edge/New Folder", D),
            (b"/t/edge/New Folder/a7", F),
            (b"/t/edge/X", D),
            ("/t/edge/X/É.txt".as_bytes(), F),
            (b"/t/edge/X/inner", D),
            (b"/t/edge/X/inner/file2", F),
            (b"/t/edge/sub/deep/new\xffname", F),
            (b"/t/edge/x/y/A007", F),
            (b"/t/edge/New Folder/Report new.txt", D),
        ];
        for (j, (path, kind)) in over.into_iter().enumerate() {
            boot.over.insert(path.to_vec(), attrs(kind, j));
        }
        let units = [boot, disk, inside];
        let (found, ranked) = search(&units, "");
        let carried = found[0]
            .added
            .iter()
            .filter(|h| matches!(h.folder, Folder::Base(_)))
            .count();
        println!(
            "edge set: {} hits, {} overlay rows, {carried} in base folders",
            ranked.len(),
            found[0].added.len()
        );
        assert_eq!((found[0].added.len(), carried), (11, 6));
        for column in COLUMNS {
            check(&found, &ranked, column, "edge set");
        }
        let (found, ranked) = search(&units[1..], "");
        for column in COLUMNS {
            check(&found, &ranked, column, "edge disks");
        }
    }

    #[test]
    fn three_units_and_an_overlay_sort_as_the_oracle() {
        let units = units(&MAC, ROWS);
        let (found, ranked) = search(&units, "report");
        println!("report: {} hits", ranked.len());
        check(&found, &ranked, EngineColumn::Relevance, "report");
        let (found, ranked) = search(&units, "kind:file");
        println!("kind:file: {} hits", ranked.len());
        for column in COLUMNS {
            check(&found, &ranked, column, "kind:file");
        }
    }

    #[test]
    fn an_overlay_hit_holds_one_string() {
        counted(|| {
            let units = units(&[("/timing", 100_000)], 5_000);
            let live = &units[0];
            let query = crate::query::Query::parse("", "/nonexistent");
            let new_folders = live
                .over
                .keys()
                .filter(|path| {
                    let folder = crate::live::as_path(path).parent().unwrap();
                    live.base_dir(folder.as_os_str().as_bytes()).is_none()
                })
                .count();
            drop(live.scan_one(&query, &|| false).unwrap());
            let before = crate::alloc::count::live();
            let (found, scored) = live.scan_one(&query, &|| false).unwrap();
            let blocks = crate::alloc::count::live().1 - before.1;
            let bound = found.added.len() + new_folders + 16;
            assert!(!found.added.is_empty());
            assert_eq!(scored.len(), found.hits.len() + found.added.len());
            assert!(blocks <= bound as isize, "{blocks} blocks, bound {bound}");
        });
    }

    #[test]
    fn places_and_sorts_match_on_one_and_four_threads() {
        let units = units(&MAC, ROWS * 4);
        let pools: Vec<_> = [1, 4]
            .into_iter()
            .map(|n| {
                rayon::ThreadPoolBuilder::new()
                    .num_threads(n)
                    .build()
                    .unwrap()
            })
            .collect();
        for text in ["", "kind:file"] {
            let (found, ranked) = search(&units, text);
            assert!(found[0].added.len() > 4096);
            assert!(found[0].index.folders() > 4096);
            let (one, one_gaps) = pools[0].install(|| places(&found, &|| false).unwrap());
            let (four, four_gaps) = pools[1].install(|| places(&found, &|| false).unwrap());
            assert_eq!(one, four, "{text}");
            assert_eq!(one_gaps, four_gaps, "{text}");
            for column in [EngineColumn::Name, EngineColumn::Folder, EngineColumn::Size] {
                let sorts = pools
                    .iter()
                    .zip([&one, &four])
                    .map(|(pool, places)| {
                        pool.install(|| {
                            let mut got = ranked.clone();
                            super::by_column(&found, places, &mut got, column, None, &|| false)
                                .unwrap();
                            check(&found, &ranked, column, text);
                            got
                        })
                    })
                    .collect::<Vec<_>>();
                assert_eq!(sorts[0], sorts[1], "{text} by {column:?}");
            }
        }
    }

    #[test]
    fn parallel_scans_keep_rows_and_scores_in_order() {
        let mut units = units(&MAC, ROWS * 2);
        let now = crate::engine::now_secs() as i64;
        units[0].over.insert(
            b"/timing/a day old.txt".to_vec(),
            Attrs {
                mtime: now - 86_400,
                ..attrs(EngineKind::File, 0)
            },
        );
        assert!(units[0].over.len() > 4096);
        assert!(units[0].base.folders() > 4096);
        let pools: Vec<_> = [1, 4]
            .into_iter()
            .map(|n| {
                rayon::ThreadPoolBuilder::new()
                    .num_threads(n)
                    .build()
                    .unwrap()
            })
            .collect();
        for text in ["", "hidden:no", "kind:file ext:txt", "report"] {
            let query = crate::query::Query::parse(text, "/nonexistent");
            let scan = || {
                units
                    .iter()
                    .map(|live| {
                        let (found, scored) = live.scan_at(&query, now, &|| false).unwrap();
                        let rows = (0..scored.len())
                            .map(|k| found.row(k).unwrap())
                            .collect::<Vec<_>>();
                        (found.hits, rows, scored)
                    })
                    .collect::<Vec<_>>()
            };
            let serial = pools[0].install(scan);
            while crate::engine::now_secs() as i64 == now {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            assert_eq!(serial, pools[1].install(scan), "{text:?}");
            if text.is_empty() {
                let hits: usize = serial.iter().map(|(_, rows, _)| rows.len()).sum();
                assert_eq!(hits as u64, units.iter().map(Live::entries).sum::<u64>());
            }
            assert!(units[0].scan_one(&query, &|| true).is_none());
        }
    }

    #[test]
    fn overlay_names_share_their_insertion_gap() {
        let names: Vec<_> = (100..164).map(|n| format!("z{n}")).collect();
        let entries: Vec<_> = names
            .iter()
            .map(|n| (n.as_bytes(), NONE, EngineKind::File))
            .collect();
        let clustered: Vec<_> = (0..32)
            .map(|n| format!("a{n}"))
            .chain(["Z00100".to_owned()])
            .collect();
        for added in [clustered, vec!["z132a".to_owned()]] {
            let mut live = edge_unit("/gap", &[&entries]);
            for (n, name) in added.iter().enumerate() {
                live.over.insert(
                    format!("/gap/{name}").into_bytes(),
                    attrs(EngineKind::File, n),
                );
            }
            premerge(&[live.base.clone()]);
            let (found, ranked) = search(&[live], "");
            let (p, calls) = counted(|| {
                tallies();
                let p = places(&found, &|| false).unwrap().0;
                let t = tallies();
                (
                    p,
                    t[Count::Names as usize] - t[Count::OverlayCompares as usize],
                )
            });
            let bound = added.len() + ceil_log2(names.len()) + 1;
            assert!(
                calls <= bound,
                "{calls} placement comparisons, bound {bound}"
            );
            assert!(calls <= added.len() * (ceil_log2(names.len()) + 1));
            let mut got = ranked.clone();
            super::by_column(&found, &p, &mut got, EngineColumn::Name, None, &|| false).unwrap();
            assert_eq!(got, oracle(&found, &ranked, EngineColumn::Name));
        }
    }

    #[test]
    fn the_empty_query_lists_every_live_entry_in_name_order() {
        use crate::EngineSort;
        use crate::engine::timing::search as sorted;
        use crate::opens::Opens;

        let mut units = units(&MAC, ROWS);
        let before: u64 = units.iter().map(Live::entries).sum();
        let disk = &mut units[2];
        let folder = (0..disk.base.folders())
            .find(|&k| disk.base.subtree(k).len() == 1)
            .unwrap();
        let path = disk.base.folder(folder);
        assert!(disk.drop_below(path.as_os_str().as_bytes()));
        let entries = units.iter().map(Live::entries).sum::<u64>() as usize;
        assert_eq!(entries as u64, before - 1);

        let (found, ranked) = search(&units, "");
        assert_eq!(ranked.len(), entries);
        let want: Vec<_> = oracle(&found, &ranked, EngineColumn::Name)
            .iter()
            .map(|r| found[r.unit as usize].row(r.k as usize).unwrap())
            .collect();
        let opens = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let ascending = sorted(&units, "", by_name, &opens).rows(0, entries + 1);
        assert_eq!(ascending.len(), entries);
        assert_eq!(ascending, want);
        let descending = sorted(
            &units,
            "",
            EngineSort {
                ascending: false,
                folders_first: false,
                ..by_name
            },
            &opens,
        )
        .rows(0, entries + 1);
        assert_eq!(descending, ascending.into_iter().rev().collect::<Vec<_>>());
    }

    #[test]
    fn small_lists_sort_on_the_calling_thread() {
        let opens = crate::opens::Opens::new(PathBuf::from("/nonexistent/caller"));
        let by_size = EngineSort {
            column: EngineColumn::Size,
            ascending: true,
            folders_first: true,
        };
        for (n, want) in [(100, 400), (10_000, 0)] {
            let mut listing = Listing::default();
            for j in 0..n {
                let kind = if j % 4 == 0 {
                    EngineKind::Folder
                } else {
                    EngineKind::File
                };
                listing.push(format!("caller-{j}.txt").as_bytes(), attrs(kind, j), NONE);
            }
            let crawl = Crawl {
                listings: vec![listing],
                failed: Vec::new(),
            };
            let index = Index::build(crawl, PathBuf::from("/caller"), b"", 0, 0).unwrap();
            let units = [Live::new(Arc::new(index))];
            tallies();
            let set = crate::engine::timing::search(&units, "", by_size, &opens);
            let caller = tallies()[Count::Caller as usize];
            println!(
                "{n} hits by size, folders first: closures on the calling thread {caller} (want {want})"
            );
            assert_eq!(set.count() as usize, n);
            assert_eq!(caller, want, "{n} hits");
        }
    }

    #[test]
    fn small_overlay_searches_keep_folders_first_on_the_calling_thread() {
        let opens = crate::opens::Opens::new(PathBuf::from("/nonexistent/caller"));
        let best = EngineSort {
            column: EngineColumn::Relevance,
            ascending: false,
            folders_first: true,
        };
        for (rows, small) in [(20, true), (2 * 4096, false)] {
            let mut units = units(&[("/caller", 100)], 0);
            let live = &mut units[0];
            let root = live.base.folder(0);
            for j in 0..rows {
                let folder = root.join(format!("grain-new-{j}"));
                let file = folder.join(format!("grain-{j}.txt"));
                live.over.insert(
                    folder.into_os_string().into_vec(),
                    attrs(EngineKind::Folder, j),
                );
                live.over
                    .insert(file.into_os_string().into_vec(), attrs(EngineKind::File, j));
            }
            let (found, ranked) = search(&units, "");
            let hits = ranked.len();
            let added: usize = found.iter().map(|f| f.added.len()).sum();
            let listed: usize = found.iter().map(|f| f.listed.len()).sum();
            let dirs: usize = found
                .iter()
                .map(|f| f.new_dirs.len() + f.listed_dirs.len())
                .sum();
            let names = added + listed;
            assert_eq!(
                added,
                2 * rows,
                "a folder row and a file row per overlay pair"
            );
            assert_eq!(dirs, rows, "one new folder per overlay pair");
            let want = 7 * hits + added + listed + names + dirs;
            tallies();
            let set = crate::engine::timing::search(&units, "", best, &opens);
            let caller = tallies()[Count::Caller as usize];
            println!(
                "{hits} hits, {added} added, {listed} listed, {dirs} new folders, best match, folders first: closures on the calling thread {caller} (want {})",
                if small { want } else { 0 }
            );
            assert_eq!(set.count() as usize, hits);
            if small {
                for (len, label) in [
                    (hits, "hits"),
                    (added, "added"),
                    (names, "names"),
                    (dirs, "dirs"),
                ] {
                    assert!(
                        len >= 2,
                        "{label} {len}: one item never splits, grain or not"
                    );
                }
                assert_eq!(caller, want, "{hits} hits, {rows} overlay pairs");
            } else {
                for (len, label) in [
                    (hits, "hits"),
                    (added, "added"),
                    (names, "names"),
                    (dirs, "dirs"),
                ] {
                    assert!(
                        len >= 2 * 4096,
                        "{label} {len}: under 8192 folds on the caller"
                    );
                }
                assert_eq!(caller, 0, "{hits} hits, {rows} overlay pairs");
            }
        }
    }

    #[test]
    fn one_unit_sorts_on_stored_ranks_alone() {
        let units = units(&[("/timing", 100_000)], 0);
        let (found, ranked) = search(&units, "report");
        let names: HashSet<usize> = found[0]
            .hits
            .iter()
            .map(|&e| found[0].index.name_id(e as usize))
            .collect();
        for column in COLUMNS {
            let mut got = ranked.clone();
            let [
                fold,
                natural,
                names_cmp,
                folders,
                sorted,
                overlay,
                _,
                folder,
                parent,
                _,
                _,
                _,
            ] = counted(|| {
                tallies();
                by_column(&found, &mut got, column, &|| false).unwrap();
                tallies()
            });
            let folds = if column == EngineColumn::Kind {
                names.len()
            } else {
                0
            };
            println!(
                "one unit by {column:?}, {} hits: fold {fold} (bound {folds}), natural {natural} (0), compare_names {names_cmp} (0), folder compares {folders} (0), overlay sorted {sorted} (0), overlay compares {overlay} (0), Index::folder {folder} (0), Index::parent {parent} (0)",
                ranked.len()
            );
            assert!(fold <= folds, "fold {fold} by {column:?}");
            assert_eq!(
                [natural, names_cmp, folders, sorted, overlay, folder, parent],
                [0; 7],
                "{column:?}"
            );
            check(&found, &ranked, column, "one unit");
        }
    }

    fn merge_bounds(found: &[Found]) -> (usize, usize, usize) {
        let (mut placed, mut bound, mut folders) = (Vec::new(), 0, HashSet::new());
        for f in found {
            let index = &f.index;
            let names: Vec<String> = (0..index.names())
                .map(|id| fold(&String::from_utf8_lossy(index.name(id))))
                .collect();
            if !placed.is_empty() {
                bound += classes(placed.clone()) + classes(names.clone()) - 1;
            }
            placed.extend(names);
            folders.extend((0..index.folders()).map(|k| fold(&index.folder(k).to_string_lossy())));
        }
        (bound, classes(placed), folders.len())
    }

    fn overlay_counts(found: &[Found]) -> (usize, usize, usize) {
        let names = found
            .iter()
            .flat_map(|f| f.added.iter().map(|h| fold(&h.name)))
            .collect::<Vec<_>>();
        let new: HashSet<_> = found
            .iter()
            .flat_map(|f| f.new_dirs.iter().map(|p| fold(p)))
            .collect();
        (names.len(), classes(names), new.len())
    }

    fn places_overlay_only(found: &[Found], n: usize, f: usize, label: &str) {
        let (m, c, new) = overlay_counts(found);
        let t = counted(|| {
            tallies();
            places(found, &|| false).unwrap();
            tallies()
        });
        let at = |c: Count| t[c as usize];
        let searched = at(Count::Names) - at(Count::OverlayCompares) - at(Count::Merge);
        let (names_bound, dirs_bound) = (c * (ceil_log2(n) + 1), new * (ceil_log2(f) + 1));
        println!(
            "{label}: merge compares {} (0), overlay sorted {} (m = {m}), overlay searches {searched} (bound {names_bound}: C = {c}, N = {n}), folder compares {} (bound {dirs_bound}: {new} new folder classes, F = {f})",
            at(Count::Merge),
            at(Count::OverlaySorted),
            at(Count::Folders)
        );
        assert_eq!(at(Count::Merge), 0, "{label}");
        assert_eq!(at(Count::OverlaySorted), m, "{label}");
        assert!(
            searched <= names_bound,
            "{label}: {searched} overlay searches"
        );
        assert!(at(Count::Folders) <= dirs_bound, "{label}: folder compares");
    }

    #[test]
    fn three_units_merge_within_the_counted_bounds() {
        let units = units(&MAC, ROWS);
        let (found, ranked) = search(&units, "kind:file");
        let (merge_bound, n, f) = merge_bounds(&found);
        let (m, c, new) = overlay_counts(&found);
        let disks = found.len() - 1;
        let per_run = 2 * (ceil_log2(f) + 1);
        let search_bound = c * (ceil_log2(n) + 1);
        let folder_bound = disks * 2 * per_run + new * (ceil_log2(f) + 1);
        assert!(disks == 2 && new > 0 && m > 1);
        let mut got = ranked.clone();
        let [
            fold,
            natural,
            names_cmp,
            folder_cmps,
            sorted,
            overlay,
            _,
            folder,
            parent,
            merge,
            _,
            _,
        ] = counted(|| {
            tallies();
            by_column(&found, &mut got, EngineColumn::Name, &|| false).unwrap();
            tallies()
        });
        let searched = names_cmp - overlay - merge;
        println!(
            "three units by name, {} hits: fold {fold} (0), merge compares {merge} (bound {merge_bound}), overlay sorted {sorted} (m = {m}), overlay searches {searched} (bound {search_bound}: C = {c}, N = {n}), folder compares {folder_cmps} (bound {folder_bound}: {disks} disks, {new} new folder classes, F = {f}), Index::folder {folder} (bound {}), natural {natural} (0), Index::parent {parent} (0)",
            ranked.len(),
            2 * folder_cmps
        );
        assert_eq!(fold, 0);
        assert!(merge > 0 && merge <= merge_bound, "{merge} merge compares");
        assert_eq!(sorted, m);
        assert!(searched <= search_bound, "{searched} overlay searches");
        assert!(folder_cmps <= folder_bound, "{folder_cmps} folder compares");
        assert!(folder <= 2 * folder_cmps, "{folder} Index::folder calls");
        assert_eq!((natural, parent), (0, 0));
        check(&found, &ranked, EngineColumn::Name, "three units");
    }

    #[test]
    fn the_merged_order_is_kept_until_an_index_changes() {
        let mut units = units(&MAC, ROWS);
        let (found, ranked) = search(&units, "kind:file");
        let (merge_bound, n, f) = merge_bounds(&found);
        let (p, t) = counted(|| {
            tallies();
            let p = places(&found, &|| false).unwrap().0;
            (p, tallies())
        });
        let merge = t[Count::Merge as usize];
        println!("first places: merge compares {merge} (bound {merge_bound})");
        assert!(merge > 0 && merge <= merge_bound);
        let folds: usize = found
            .iter()
            .map(|f| {
                let ids: HashSet<usize> = f
                    .hits
                    .iter()
                    .map(|&e| f.index.name_id(e as usize))
                    .collect();
                let over: HashSet<&str> = f.added.iter().map(|h| h.name.as_str()).collect();
                ids.len() + over.len()
            })
            .sum();
        for column in COLUMNS {
            let mut got = ranked.clone();
            let t = counted(|| {
                tallies();
                super::by_column(&found, &p, &mut got, column, None, &|| false).unwrap();
                tallies()
            });
            let bound = if column == EngineColumn::Kind {
                folds
            } else {
                0
            };
            let fold = t[Count::Fold as usize];
            let rest = [
                Count::Natural,
                Count::Names,
                Count::Folders,
                Count::OverlaySorted,
                Count::OverlayCompares,
                Count::Folder,
                Count::Parent,
                Count::Merge,
            ]
            .map(|c| t[c as usize]);
            println!(
                "second sort by {column:?}: fold {fold} (bound {bound}); natural, compare_names, folder compares, overlay sorted, overlay compares, Index::folder, Index::parent, merge compares {rest:?} (all 0)"
            );
            assert!(fold <= bound, "fold {fold} by {column:?}");
            assert_eq!(rest, [0; 8], "{column:?}");
            assert_eq!(got, oracle(&found, &ranked, column), "{column:?}");
        }
        let (again, _) = search(&units, "kind:file");
        places_overlay_only(&again, n, f, "a new search, nothing changed");
        let base = units[0].base.clone();
        for j in 0..40 {
            let mut path = base.folder(j * 7 % base.folders());
            if j % 5 == 0 {
                path.push(format!("Fresh {j}"));
                let folder = path.as_os_str().as_bytes().to_vec();
                units[0].over.insert(folder, attrs(EngineKind::Folder, j));
            }
            path.push(format!("mergecache-{j}.txt"));
            units[0]
                .over
                .insert(path.into_os_string().into_vec(), attrs(EngineKind::File, j));
        }
        let (changed, changed_ranked) = search(&units, "kind:file");
        assert!(overlay_counts(&changed).0 >= overlay_counts(&again).0 + 40);
        places_overlay_only(&changed, n, f, "after the overlay changed");
        check(
            &changed,
            &changed_ranked,
            EngineColumn::Name,
            "changed overlay",
        );
        let (root, entries) = MAC[2];
        let rebuilt = Index::build(
            unit(entries, BOOT).crawl,
            PathBuf::from(root),
            b"print",
            1,
            1,
        );
        units[2] = Live::new(Arc::new(rebuilt.unwrap()));
        let (swapped, swapped_ranked) = search(&units, "kind:file");
        let merge = counted(|| {
            tallies();
            places(&swapped, &|| false).unwrap();
            tallies()[Count::Merge as usize]
        });
        let merge_bound = merge_bounds(&swapped).0;
        println!("after an index swap: merge compares {merge} (bound {merge_bound})");
        assert!(merge > 0 && merge <= merge_bound);
        check(
            &swapped,
            &swapped_ranked,
            EngineColumn::Name,
            "swapped index",
        );
        check(
            &found,
            &ranked,
            EngineColumn::Name,
            "the set before the swap",
        );
    }

    #[test]
    fn a_swapped_index_never_reads_the_old_order() {
        const F: EngineKind = EngineKind::File;
        let other = edge_unit("/t/y", &[&[(b"c", NONE, F)]]);
        let pair = |a: &[u8], b: &[u8]| {
            [
                edge_unit("/t/x", &[&[(a, NONE, F), (b, NONE, F)]]),
                Live::new(other.base.clone()),
            ]
        };
        let merged = |found: &[Found]| {
            counted(|| {
                tallies();
                places(found, &|| false).unwrap();
                tallies()[Count::Merge as usize]
            })
        };
        let old = pair(b"b", b"d");
        let (found, ranked) = search(&old, "");
        assert!(merged(&found) > 0);
        check(&found, &ranked, EngineColumn::Name, "before the swap");
        let new = pair(b"d", b"e");
        let shape = |l: &Live| (l.base.names(), l.base.folders());
        assert_eq!(shape(&new[0]), shape(&old[0]));
        let (swapped, swapped_ranked) = search(&new, "");
        assert!(merged(&swapped) > 0, "the swapped set merges again");
        check(
            &swapped,
            &swapped_ranked,
            EngineColumn::Name,
            "swapped, old set alive",
        );
        check(&found, &ranked, EngineColumn::Name, "the old set");
        drop((found, ranked, old));
        let newer = pair(b"e", b"f");
        let (found, ranked) = search(&newer, "");
        assert!(merged(&found) > 0, "the set after the drop merges again");
        check(
            &found,
            &ranked,
            EngineColumn::Name,
            "swapped after the old set dropped",
        );
    }

    #[test]
    fn a_search_over_the_old_set_never_waits_for_the_swaps_build() {
        use std::sync::mpsc::{self, RecvTimeoutError};
        use std::time::Duration;
        const F: EngineKind = EngineKind::File;
        let other = edge_unit("/t/y", &[&[(b"c", NONE, F)]]);
        let pair = |a: &[u8], b: &[u8]| {
            [
                edge_unit("/t/x", &[&[(a, NONE, F), (b, NONE, F)]]),
                Live::new(other.base.clone()),
            ]
        };
        let old = pair(b"b", b"d");
        let (found, ranked) = search(&old, "");
        let new = pair(b"d", b"e");
        let set: Vec<Arc<Index>> = new.iter().map(|l| l.base.clone()).collect();
        let (reached, at_build) = mpsc::channel();
        let (release, held) = mpsc::channel::<()>();
        let set = &set;
        std::thread::scope(|s| {
            let swap = s.spawn(move || {
                tallies();
                kept(set).get_or_init(|| {
                    reached.send(()).unwrap();
                    held.recv().unwrap();
                    Merged::build(set)
                });
                tallies()[Count::Built as usize]
            });
            at_build.recv().unwrap();
            let (sent, got) = mpsc::channel();
            let (found, ranked) = (&found, &ranked);
            s.spawn(move || {
                check(
                    found,
                    ranked,
                    EngineColumn::Name,
                    "the old set during the build",
                );
                sent.send(()).unwrap();
            });
            let waited = matches!(
                got.recv_timeout(Duration::from_secs(30)),
                Err(RecvTimeoutError::Timeout)
            );
            release.send(()).unwrap();
            assert!(!waited, "the old set's sort waited for the new set's build");
            assert_eq!(swap.join().unwrap(), 1, "orders the swap thread built");
        });
        let (swapped, swapped_ranked) = search(&new, "");
        let t = counted(|| {
            tallies();
            places(&swapped, &|| false).unwrap();
            tallies()
        });
        assert_eq!([t[Count::Built as usize], t[Count::Merge as usize]], [0, 0]);
        check(&swapped, &swapped_ranked, EngineColumn::Name, "the new set");
        check(
            &found,
            &ranked,
            EngineColumn::Name,
            "the old set after the swap",
        );
    }

    #[test]
    fn compare_names_is_the_folded_natural_order() {
        let names: [&[u8]; 54] = [
            b"",
            b"a",
            b"A",
            b"a007",
            b"a7",
            b"a07x",
            b"a7x",
            b"a7b",
            b"file2",
            b"file10",
            b"file02",
            b"FILE2",
            b"0",
            b"00",
            b"0.5",
            b"00.5",
            b".5",
            b"a.0",
            b"a.00",
            b"a1b2",
            b"a01b02",
            b"a1b10",
            b"99999999999999999999999",
            b"100000000000000000000000",
            b"0100000000000000000000000",
            b"Report",
            b"report",
            b"report.txt",
            b"Report.TXT",
            "RÉSUMÉ".as_bytes(),
            "résumé".as_bytes(),
            "É".as_bytes(),
            "é".as_bytes(),
            "İ".as_bytes(),
            "İx".as_bytes(),
            b"i",
            b"ix",
            "ß".as_bytes(),
            "ẞ".as_bytes(),
            "Σ".as_bytes(),
            "σ".as_bytes(),
            "ς".as_bytes(),
            "\u{212A}".as_bytes(),
            b"k",
            "日本語".as_bytes(),
            "😀".as_bytes(),
            b"bad\xffname",
            b"bad\xfename",
            b"bad\xff",
            b"\xff",
            b"\xe2\x82",
            b"\xe2\x82a",
            b"x\xf0\x9f\x98",
            b"\xc0\xaf/x-y",
        ];
        let oracle = |a: &[u8], b: &[u8]| {
            let (a, b) = (
                fold(&String::from_utf8_lossy(a)),
                fold(&String::from_utf8_lossy(b)),
            );
            natural(a.as_bytes(), b.as_bytes())
        };
        let (mut pairs, mut ties) = (0, 0);
        for a in names {
            for b in names {
                let o = oracle(a, b);
                assert_eq!(compare_names(a, b), o, "{a:?} against {b:?}");
                pairs += 1;
                ties += usize::from(o == Ordering::Equal && a != b);
            }
        }
        println!("compare_names: {pairs} pairs, {ties} tied apart from themselves");
        assert_eq!(pairs, names.len() * names.len());
        assert!(ties > 0);
    }

    #[test]
    fn compare_names_fast_path_is_the_folded_natural_order() {
        let fragments: [&[u8]; 26] = [
            b"",
            b"a",
            b"A",
            b"e",
            "é".as_bytes(),
            "É".as_bytes(),
            b"i",
            "İ".as_bytes(),
            b"ss",
            "ß".as_bytes(),
            b"k",
            "\u{212A}".as_bytes(),
            "日本".as_bytes(),
            b"0",
            b"007",
            b"7",
            b"10",
            b"010",
            b"_-",
            b".TXT",
            "Résumé".as_bytes(),
            b"\xc3",
            b"\xe2\x82",
            b"\xa9",
            b"\xac",
            b"\xff",
        ];
        let mut names: Vec<Vec<u8>> = fragments
            .iter()
            .flat_map(|x| fragments.iter().map(move |y| [*x, *y].concat()))
            .collect();
        for extra in [
            "Résumé_-12.txt".as_bytes(),
            "résumé_-012.TXT".as_bytes(),
            "a007é".as_bytes(),
            b"a7e",
            "a7É".as_bytes(),
            b"ab\xc3",
            "abé".as_bytes(),
            b"abcdefgh\xe2\x82",
            b"abcdefgh\xe2\x82\xac",
            b"abcdefgh\xe2\x82a",
            b"abcdefgh\xe2\x82b",
            b"abcdefgh100",
            b"abcdefgh1000",
            b"abcdefgh0001",
            b"abcdefgh001",
            b"abcdefgh\xff\x80a",
            b"abcdefgh\xff\x81a",
        ] {
            names.push(extra.to_vec());
        }
        names.sort();
        names.dedup();
        let folded: Vec<String> = names
            .iter()
            .map(|n| fold(&String::from_utf8_lossy(n)))
            .collect();
        let mut pairs = 0;
        for (a, fa) in names.iter().zip(&folded) {
            for (b, fb) in names.iter().zip(&folded) {
                let o = natural(fa.as_bytes(), fb.as_bytes());
                assert_eq!(compare_names(a, b), o, "{a:?} against {b:?}");
                pairs += 1;
            }
        }
        println!(
            "compare_names fast path: {} names, {pairs} pairs",
            names.len()
        );
        assert_eq!(pairs, names.len() * names.len());
    }

    #[test]
    fn ascii_names_skip_the_folded_streams() {
        let names = |words: &[&str]| -> Vec<String> {
            (0..2_000)
                .map(|i| format!("{}_-{}.txt", words[i % words.len()], i * 7919 % 2_003))
                .collect()
        };
        let streams = |names: &mut Vec<String>| {
            tallies();
            let mut mixed = 0;
            names.sort_by(|a, b| {
                mixed += usize::from(!a.is_ascii() || !b.is_ascii());
                compare_names(a.as_bytes(), b.as_bytes())
            });
            let t = tallies();
            (t[Count::Names as usize], t[Count::Streams as usize], mixed)
        };
        let (compares, walked, _) = streams(&mut names(&["report", "Report", "IMG_", "photo"]));
        println!("all ASCII: {compares} compares, {walked} through the streams");
        assert!(compares > 0);
        assert_eq!(walked, 0);
        let (compares, walked, mixed) = streams(&mut names(&[
            "report",
            "Résumé",
            "日本語のメモ",
            "données",
            "Проект",
        ]));
        println!(
            "mixed: {compares} compares, {mixed} with a non-ASCII name, {walked} through the streams"
        );
        assert!(mixed > 0);
        assert!(walked <= mixed);
    }

    fn folded_key(raw: &[u8]) -> Vec<u8> {
        let mut buf = Vec::new();
        fold_into(&mut buf, raw);
        buf
    }

    fn check_space(
        label: &str,
        list: &[Gap],
        merged: &[Vec<u8>],
        holder: &dyn Fn(&Gap) -> Vec<u8>,
        rows: &[(u32, Vec<u8>)],
        cmp: fn(&[u8], &[u8]) -> Ordering,
        held: bool,
    ) -> (usize, usize) {
        let mut last: Option<(u32, Vec<u8>)> = None;
        for (i, g) in list.iter().enumerate() {
            assert!(
                g.at as usize <= merged.len(),
                "{label}: gap {i} at {}",
                g.at
            );
            assert!(
                i == 0 || list[i - 1].at <= g.at,
                "{label}: gap {i} out of order"
            );
            if g.item == NONE {
                continue;
            }
            let key = holder(g);
            let at = g.at as usize;
            assert!(
                at == 0 || cmp(&merged[at - 1], &key) == Ordering::Less,
                "{label}: gap {i}"
            );
            assert!(
                at == merged.len() || cmp(&merged[at], &key) == Ordering::Greater,
                "{label}: gap {i}"
            );
            if let Some((a, k)) = &last
                && *a == g.at
            {
                assert_eq!(
                    cmp(k, &key),
                    Ordering::Less,
                    "{label}: gap {i} after its neighbour"
                );
            }
            last = Some((g.at, key));
        }
        let place = |i: usize| list[i].at + i as u32;
        let mut used = HashSet::new();
        for (r, (p, key)) in rows.iter().enumerate() {
            let (mut c, mut hi) = (0, list.len());
            while c < hi {
                let mid = c + (hi - c) / 2;
                if place(mid) < *p {
                    c = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if c < list.len() && place(c) == *p {
                let g = &list[c];
                assert_ne!(g.item, NONE, "{label}: row {r} on an emptied gap");
                assert_eq!(
                    cmp(&holder(g), key),
                    Ordering::Equal,
                    "{label}: row {r} on gap {c}"
                );
                used.insert(c);
            } else {
                let g = (*p - c as u32) as usize;
                assert!(g < merged.len(), "{label}: row {r} past the merged order");
                assert_eq!(
                    list.partition_point(|x| x.at as usize <= g),
                    c,
                    "{label}: row {r}"
                );
                assert_eq!(
                    cmp(&merged[g], key),
                    Ordering::Equal,
                    "{label}: row {r} on merged {g}"
                );
            }
        }
        let live = list.iter().filter(|g| g.item != NONE).count();
        if held {
            assert_eq!(used.len(), live, "{label}: held gaps without a row");
        }
        (live, list.len() - live)
    }

    fn check_gaps(found: &[Found], places: &Places, gaps: &Gaps) -> (usize, usize, usize) {
        let set: Vec<Arc<Index>> = found.iter().map(|f| f.index.clone()).collect();
        let cell = kept(&set);
        let m = cell.get_or_init(|| Merged::build(&set));
        let merged_names: Vec<Vec<u8>> = (0..m.names.reps.len())
            .map(|g| {
                let (u, id) = m.names.item(m.names.reps[g]);
                found[u].index.name(id).to_vec()
            })
            .collect();
        let merged_dirs: Vec<Vec<u8>> = (0..m.dirs.reps.len())
            .map(|g| {
                let (u, k) = m.dirs.item(m.dirs.reps[g]);
                let mut buf = Vec::new();
                Dir(&found[u].index, k).path_into(&mut buf);
                buf
            })
            .collect();
        let (mut names, mut dirs) = (Vec::new(), Vec::new());
        for (f, p) in found.iter().zip(places) {
            assert_eq!(p.len(), f.count());
            for (k, &[name, folder]) in p.iter().enumerate() {
                let row = f.row(k).unwrap();
                names.push((name, row.name.into_bytes()));
                dirs.push((folder, folded_key(row.folder.as_bytes())));
            }
        }
        let name_of = |g: &Gap| {
            let f = &found[g.unit as usize];
            f.added[g.item as usize - f.hits.len()]
                .name
                .as_bytes()
                .to_vec()
        };
        let dir_of =
            |g: &Gap| folded_key(found[g.unit as usize].new_dirs[g.item as usize].as_bytes());
        let (held, emptied) = check_space(
            "names",
            &gaps.names,
            &merged_names,
            &name_of,
            &names,
            compare_names,
            true,
        );
        let (folders, none) = check_space(
            "folders",
            &gaps.dirs,
            &merged_dirs,
            &dir_of,
            &dirs,
            |a, b| a.cmp(b),
            false,
        );
        assert_eq!(none, 0, "a folder gap lost its folder");
        (held, emptied, folders)
    }

    #[test]
    fn gaps_hold_every_class_outside_the_merged_order() {
        let mut units = units(&MAC, ROWS);
        let disk = &mut units[1];
        let root = disk.base.root().as_os_str().as_bytes().to_vec();
        for (n, name) in ["zz-twin-01.md", "ZZ-Twin-1.md", "zz-only.md"]
            .into_iter()
            .enumerate()
        {
            let mut path = root.clone();
            path.extend(format!("/{name}").bytes());
            disk.over.insert(path, attrs(EngineKind::File, n));
        }
        let (found, _) = search(&units, "");
        let (p, gaps) = places(&found, &|| false).unwrap();
        let (held, emptied, folders) = check_gaps(&found, &p, &gaps);
        assert_eq!(emptied, 0);
        assert_eq!(held, gaps.names.len());
        assert!(held > ROWS / 4, "{held} name gaps for {ROWS} overlay rows");
        assert!(folders > 0, "no folder gaps");
        let twins: Vec<&Gap> = gaps.names.iter().filter(|g| g.unit == 1).collect();
        assert_eq!(
            twins.len(),
            2,
            "the two fold-equal names share one gap: {twins:?}"
        );
        let mut again = units;
        again[0].over.clear();
        again[1].over.clear();
        let (found, _) = search(&again, "");
        let (p, gaps) = places(&found, &|| false).unwrap();
        assert_eq!(gaps, Gaps::default(), "a set with no overlay has no gaps");
        check_gaps(&found, &p, &gaps);
    }

    fn dense(p: &Places, space: usize) -> Vec<Vec<usize>> {
        let mut held: Vec<u32> = p.iter().flatten().map(|r| r[space]).collect();
        held.sort_unstable();
        held.dedup();
        p.iter()
            .map(|v| {
                v.iter()
                    .map(|r| held.binary_search(&r[space]).unwrap())
                    .collect()
            })
            .collect()
    }

    type Row = (String, Attrs, Folder);
    type Chosen = (Vec<bool>, Vec<bool>, Vec<u32>);

    #[test]
    fn repatched_places_order_like_a_full_build() {
        const F: EngineKind = EngineKind::File;
        const D: EngineKind = EngineKind::Folder;
        let mut units = [
            edge_unit(
                "/pa",
                &[
                    &[
                        (b"file01", NONE, F),
                        (b"Report.txt", NONE, F),
                        (b"a7", NONE, F),
                        (b"dup", NONE, F),
                        (b"x", 1, D),
                        (b"y", 2, D),
                    ],
                    &[(b"dup", NONE, F), (b"Foo", NONE, F), (b"q5", NONE, F)],
                    &[(b"dup", NONE, F), (b"z9", NONE, F)],
                ],
            ),
            edge_unit(
                "/pb",
                &[
                    &[
                        (b"file1", NONE, F),
                        (b"bar", NONE, F),
                        (b"dup", NONE, F),
                        (b"w", 1, D),
                    ],
                    &[(b"dup", NONE, F), (b"foo", NONE, F)],
                ],
            ),
        ];
        let over: [&[(&str, EngineKind)]; 2] = [
            &[
                ("/pa/novel1", F),
                ("/pa/NOVEL1", F),
                ("/pa/novel2", F),
                ("/pa/x/q01", F),
                ("/pa/x/q1", F),
                ("/pa/y/q1", F),
                ("/pa/x/z9", F),
                ("/pa/x/foo", F),
                ("/pa/new0", D),
                ("/pa/new0/q1", F),
                ("/pa/new0/omega", F),
                ("/pa/NEW0", D),
                ("/pa/NEW0/omega", F),
                ("/pa/x/deep", D),
                ("/pa/x/deep/omega2", F),
            ],
            &[
                ("/pb/q1", F),
                ("/pb/novel3", F),
                ("/pb/w/Q01", F),
                ("/pb/newb", D),
                ("/pb/newb/q1", F),
                ("/pb/newb/NOVEL1", F),
            ],
        ];
        for (live, rows) in units.iter_mut().zip(over) {
            for (n, &(path, kind)) in rows.iter().enumerate() {
                live.over.insert(path.as_bytes().to_vec(), attrs(kind, n));
            }
        }
        let (all, _) = search(&units, "");
        let ids: Vec<Vec<u32>> = all.iter().map(|f| f.hits.clone()).collect();
        let rows: Vec<Vec<Row>> = all
            .iter()
            .map(|f| {
                f.added
                    .iter()
                    .map(|h| (h.name.clone(), h.attrs, h.folder))
                    .collect()
            })
            .collect();
        assert_eq!(
            [rows[0].len(), rows[1].len()],
            [over[0].len(), over[1].len()]
        );
        let build = |chosen: &mut [Chosen]| {
            let (mut found, _) = search(&units, "");
            let mut held = Vec::new();
            for (u, (f, (ids_in, rows_in, dirs))) in found.iter_mut().zip(chosen).enumerate() {
                let hits: Vec<u32> = ids[u]
                    .iter()
                    .zip(&*ids_in)
                    .filter_map(|(&e, &on)| on.then_some(e))
                    .collect();
                let picked: Vec<usize> = (0..rows[u].len()).filter(|&a| rows_in[a]).collect();
                f.hits = hits.clone();
                f.added = picked
                    .iter()
                    .map(|&a| {
                        let (name, attrs, folder) = &rows[u][a];
                        let folder = match *folder {
                            Folder::New(d) => {
                                Folder::New(match dirs.iter().position(|&x| x == d) {
                                    Some(p) => p as u32,
                                    None => {
                                        dirs.push(d);
                                        dirs.len() as u32 - 1
                                    }
                                })
                            }
                            base => base,
                        };
                        Added {
                            name: name.clone(),
                            attrs: *attrs,
                            folder,
                        }
                    })
                    .collect();
                f.new_dirs = dirs
                    .iter()
                    .map(|&d| all[u].new_dirs[d as usize].clone())
                    .collect();
                held.push((hits, picked));
            }
            (found, held)
        };
        let mut seed = 0x0DE1_7A9A_u64;
        let mut below = |n: usize| {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (seed >> 33) as usize % n
        };
        let name = |f: &[Found], u: usize, k: usize| f[u].row(k).unwrap().name;
        let mut kinds = [0; 6];
        let mut chosen: Vec<Chosen> = Vec::new();
        let (mut held, mut held_rows) = (Vec::new(), Vec::new());
        let (mut held_places, mut held_gaps) = (Vec::new(), Gaps::default());
        let mut emptied: Vec<String> = Vec::new();
        for round in 0..300 {
            if round % 50 == 0 {
                chosen = (0..2)
                    .map(|u| {
                        let ids_in = ids[u].iter().map(|_| below(2) == 0).collect();
                        let rows_in = rows[u]
                            .iter()
                            .map(|r| !matches!(r.2, Folder::New(_)) && below(2) == 0)
                            .collect();
                        (ids_in, rows_in, Vec::new())
                    })
                    .collect();
                (held, held_rows) = build(&mut chosen);
                (held_places, held_gaps) = places(&held, &|| false).unwrap();
                emptied.clear();
            }
            let overlay = round % 5 != 0;
            for (ids_in, rows_in, _) in &mut chosen {
                for on in ids_in.iter_mut() {
                    if below(if overlay { 8 } else { 4 }) == 0 {
                        *on = !*on;
                    }
                }
                for on in rows_in.iter_mut().filter(|_| overlay) {
                    if below(3) == 0 {
                        *on = !*on;
                    }
                }
            }
            let (new, new_rows) = build(&mut chosen);
            let from: Vec<Vec<u32>> = new_rows
                .iter()
                .zip(&held_rows)
                .map(|((hits, picked), (old_hits, old_picked))| {
                    let base = hits
                        .iter()
                        .map(|e| old_hits.binary_search(e).map_or(NONE, |k| k as u32));
                    let over = picked.iter().map(|a| {
                        old_picked
                            .binary_search(a)
                            .map_or(NONE, |k| (old_hits.len() + k) as u32)
                    });
                    base.chain(over).collect()
                })
                .collect();

            let kept: HashSet<(usize, u32)> = from
                .iter()
                .enumerate()
                .flat_map(|(u, f)| f.iter().filter(|&&k| k != NONE).map(move |&k| (u, k)))
                .collect();
            let new_names: Vec<String> = (0..2)
                .flat_map(|u| (0..new[u].count()).map(move |k| (u, k)))
                .map(|(u, k)| name(&new, u, k))
                .collect();
            let held_names: Vec<String> = (0..2)
                .flat_map(|u| (0..held[u].count()).map(move |k| (u, k)))
                .map(|(u, k)| name(&held, u, k))
                .collect();
            let equal =
                |a: &str, b: &str| compare_names(a.as_bytes(), b.as_bytes()) == Ordering::Equal;
            let (mut member_kept, mut emptied_now) = (false, Vec::new());
            for (i, g) in held_gaps.names.iter().enumerate() {
                if g.item == NONE {
                    continue;
                }
                let holder = name(&held, g.unit as usize, g.item as usize);
                if !new_names.iter().any(|n| equal(n, &holder)) {
                    emptied_now.push(holder);
                } else if !kept.contains(&(g.unit as usize, g.item)) {
                    let place = g.at + i as u32;
                    member_kept |= held_places.iter().enumerate().any(|(u, p)| {
                        (0..p.len()).any(|k| p[k][0] == place && kept.contains(&(u, k as u32)))
                    });
                }
            }
            let back = (0..2).any(|u| {
                (new[u].hits.len()..new[u].count()).any(|k| {
                    let n = name(&new, u, k);
                    from[u][k] == NONE
                        && emptied.iter().any(|e| equal(e, &n))
                        && !held_names.iter().any(|h| equal(h, &n))
                })
            });

            let held_set = (&held[..], &held_places, &held_gaps);
            if round == 0 {
                assert!(repatch(held_set, &new, &from, &|| true).is_none());
            }
            let (p, gaps) = repatch(held_set, &new, &from, &|| false).unwrap();
            let (full, full_gaps) = places(&new, &|| false).unwrap();
            for (space, label) in ["names", "folders"].into_iter().enumerate() {
                assert_eq!(
                    dense(&p, space),
                    dense(&full, space),
                    "round {round}: {label}"
                );
            }
            let (live, holes, folders) = check_gaps(&new, &p, &gaps);
            let (full_live, none, full_folders) = check_gaps(&new, &full, &full_gaps);
            assert_eq!((live, none), (full_live, 0), "round {round}");
            assert!(folders >= full_folders, "round {round}");

            let held_holes = held_gaps.names.iter().filter(|g| g.item == NONE).count();
            let grew = [
                gaps.names.len() > held_gaps.names.len(),
                gaps.dirs.len() > held_gaps.dirs.len(),
            ];
            for (n, ran) in [
                grew == [false, false],
                grew[0],
                grew[1],
                member_kept,
                holes > held_holes,
                back,
            ]
            .into_iter()
            .enumerate()
            {
                kinds[n] += usize::from(ran);
            }
            emptied.extend(emptied_now);
            (held, held_rows, held_places, held_gaps) = (new, new_rows, p, gaps);
        }
        println!("round kinds: {kinds:?}");
        assert!(
            kinds.iter().all(|&n| n > 0),
            "a round kind never ran: {kinds:?}"
        );
    }
}
