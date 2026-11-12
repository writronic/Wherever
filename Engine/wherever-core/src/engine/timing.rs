use std::hint::black_box;
use std::os::unix::ffi::OsStringExt;
use std::time::Duration;

use super::tests::{Event, Recorder, config, next_result, phases, start_with};
use super::*;
use crate::EngineKind;
use crate::crawl::tests::TempTree;
use crate::crawl::{Attrs, Crawl, Listing, NONE};
use crate::live::Live;

pub(crate) const ENTRIES: usize = 1_000_000;
const HOME: &str = "/nonexistent";
const FRAME_MS: f64 = 1000.0 / 120.0;
const RELOAD_MS: f64 = 35.0;
const SEARCH_MS: f64 = 32.3;
const SORT_MS: f64 = 29.4;
const EMPTY_MS: f64 = 30.2;

const WORDS: &[&str] = &[
    "report",
    "Quarterly Report",
    "invoice",
    "photo",
    "IMG_",
    "notes",
    "build",
    "Résumé",
    "日本語のメモ",
    "données",
    "Проект",
    "backup",
    "index",
    "Screenshot 2026-10-17 at 11.14.38",
    ".DS_Store",
    "main",
];
const EXTS: &[&str] = &[
    ".txt", ".pdf", ".jpg", ".swift", ".rs", ".md", ".png", ".json", ".heic", ".zip", "",
];

pub(crate) struct Rng(pub(crate) u64);

impl Rng {
    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    pub(crate) fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

pub(crate) struct Million {
    pub(crate) crawl: Crawl,
    pub(crate) files: usize,
    pub(crate) report: usize,
}

#[derive(Clone, Copy)]
pub(crate) struct Shares {
    n: u64,
    d: u64,
    u: u64,
    bytes: u64,
}

pub(crate) const BOOT: Shares = Shares {
    n: 1_564_039,
    d: 347_252,
    u: 445_383,
    bytes: 11_635_302,
};
const DISK1: Shares = Shares {
    n: 888_915,
    d: 128_744,
    u: 306_762,
    bytes: 8_167_552,
};
const DISK2: Shares = Shares {
    n: 163_594,
    d: 21_547,
    u: 70_009,
    bytes: 1_864_637,
};
const UNITS: [(&str, usize, Shares); 3] = [
    ("/timing", 597_749, BOOT),
    ("/Volumes/Disk1", 339_728, DISK1),
    ("/Volumes/Disk2", 62_523, DISK2),
];
const OVERLAY: usize = 25_000;

impl Shares {
    fn at(self, entries: usize) -> (usize, usize, usize) {
        let r = |a: u64, b: u64, c: u64| ((2 * a * b + c) / (2 * c)) as usize;
        let (d, u) = (
            r(entries as u64, self.d, self.n),
            r(entries as u64, self.u, self.n),
        );
        (d, u, r(u as u64, self.bytes, self.u))
    }
}

fn pool(u: usize, bytes: usize) -> Vec<String> {
    let name = |i: usize, pad: usize| {
        let (word, ext) = (WORDS[i % WORDS.len()], EXTS[i / WORDS.len() % EXTS.len()]);
        format!("{word}{}-{i}{ext}", "_".repeat(pad))
    };
    let have: usize = (0..u).map(|i| name(i, 0).len()).sum();
    assert!(
        have <= bytes,
        "{u} names are {have} bytes before any pad, over {bytes}"
    );
    let (each, extra) = ((bytes - have) / u, (bytes - have) % u);
    (0..u)
        .map(|i| name(i, each + usize::from(i < extra)))
        .collect()
}

pub(crate) fn unit(entries: usize, shares: Shares) -> Million {
    let mut rng = Rng(0x5EED_2026_1017 ^ shares.n);
    let (d, u, bytes) = shares.at(entries);
    let pool = pool(u, bytes);
    let mut subfolders = Vec::with_capacity(d);
    let mut handed = 1;
    for k in 0..d {
        let lo = (k + 2).min(d).saturating_sub(handed);
        let want = if rng.below(2) == 0 {
            0
        } else {
            1 + rng.below(8)
        };
        let f = want.clamp(lo, d - handed);
        handed += f;
        subfolders.push(f);
    }
    assert_eq!(handed, d, "the tree left folders unlisted");
    let files = entries - (d - 1);
    let mut files_in = vec![0usize; d];
    for _ in 0..files {
        files_in[rng.below(d)] += 1;
    }
    let mut order: Vec<usize> = (0..u).collect();
    for i in (1..u).rev() {
        order.swap(i, rng.below(i + 1));
    }
    let (mut listings, mut report) = (Vec::with_capacity(d), 0);
    let (mut next_id, mut active, mut left) = (1u32, 0, entries);
    for k in 0..d {
        let mut l = Listing::default();
        l.id = k as u32;
        let mut used = Vec::new();
        for j in 0..subfolders[k] + files_in[k] {
            let pending = u - active;
            let fresh = pending > 0
                && (active <= used.len() || pending == left || rng.below(left) < pending);
            let id = if fresh {
                active += 1;
                order[active - 1]
            } else {
                loop {
                    let c = order[rng.below(active)];
                    if !used.contains(&c) {
                        break c;
                    }
                }
            };
            used.push(id);
            left -= 1;
            let folder = j < subfolders[k];
            let name = &pool[id];
            let child = if folder {
                next_id += 1;
                next_id - 1
            } else {
                NONE
            };
            report += usize::from(name.to_lowercase().contains("report"));
            let attrs = Attrs {
                kind: if folder {
                    EngineKind::Folder
                } else {
                    EngineKind::File
                },
                size: rng.next() % (1 << 30),
                mtime: 1_600_000_000 + (rng.next() % 200_000_000) as i64,
                created: 0,
                opened: 0,
                mount: false,
                hidden: rng.below(50) == 0,
            };
            l.push(name.as_bytes(), attrs, child);
        }
        listings.push(l);
    }
    Million {
        crawl: Crawl {
            listings,
            failed: Vec::new(),
        },
        files,
        report,
    }
}

pub(crate) fn million() -> Million {
    unit(ENTRIES, BOOT)
}

fn mode() -> (&'static str, usize, usize) {
    match std::env::var("WHEREVER_MEASURE").as_deref() {
        Ok("1") => ("measure", 20, 3),
        Ok("selftest") => ("selftest", 20, 3),
        _ => ("gate", 1, 0),
    }
}

fn timing(label: &str, limit: Option<f64>, mut work: impl FnMut()) {
    measured(label, limit, || {
        let start = Instant::now();
        work();
        start.elapsed()
    });
}

fn measured(label: &str, limit: Option<f64>, mut run: impl FnMut() -> Duration) {
    let (mode, runs, warmup) = mode();
    for _ in 0..warmup {
        run();
    }
    let mut ms: Vec<f64> = (0..runs).map(|_| run().as_secs_f64() * 1000.0).collect();
    ms.sort_by(f64::total_cmp);
    let (p50, p95) = (ms[ms.len() / 2], ms[(ms.len() * 95).div_ceil(100) - 1]);
    let limit = if mode == "selftest" { Some(0.0) } else { limit };
    let (shown, verdict) = match limit {
        None => ("none".to_owned(), "report"),
        Some(l) => (format!("{l:.2}"), if p95 > l { "LIMIT OVER" } else { "ok" }),
    };
    let config = if cfg!(debug_assertions) {
        "Debug"
    } else {
        "Release"
    };
    let mut load = [0f64; 3];
    unsafe { libc::getloadavg(load.as_mut_ptr(), 3) };
    println!(
        "timing: {label} p50 {p50:.3} p95 {p95:.3} limit {shown} {verdict} | {config} | {mode} {runs} runs, {warmup} warmup | load {:.2}/{:.2}/{:.2}",
        load[0], load[1], load[2]
    );
}
struct Set {
    units: Vec<Live>,
    opens: Opens,
    files: usize,
    report: usize,
}

fn overlay(live: &mut Live, count: usize) -> usize {
    let mut rng = Rng(0x00EE_21A7);
    let mut report = 0;
    let start = live.over.len();
    for j in start..start + count {
        let name = format!("{}-new{j}.txt", WORDS[j % WORDS.len()]);
        report += usize::from(name.to_lowercase().contains("report"));
        let path = live.base.folder(rng.below(live.base.folders())).join(name);
        let attrs = Attrs {
            kind: EngineKind::File,
            size: rng.next() % (1 << 30),
            mtime: 1_600_000_000 + (rng.next() % 200_000_000) as i64,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        live.over.insert(path.into_os_string().into_vec(), attrs);
    }
    report
}

fn set(count: usize) -> Set {
    let (mut units, mut files, mut report) = (Vec::new(), count, 0);
    for (root, entries, shares) in UNITS {
        let m = unit(entries, shares);
        let index = Index::build(m.crawl, PathBuf::from(root), b"print", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(index));
        report += m.report;
        files += m.files;
        if units.is_empty() {
            report += overlay(&mut live, count);
        }
        units.push(live);
    }
    Set {
        units,
        opens: Opens::new(PathBuf::from("/nowhere/wherever.opens")),
        files,
        report,
    }
}

const BEST: EngineSort = EngineSort {
    column: EngineColumn::Relevance,
    ascending: false,
    folders_first: false,
};

impl Set {
    fn grow_overlay(&mut self, count: usize) {
        let added = count - self.units[0].over.len();
        self.report += overlay(&mut self.units[0], added);
        self.files += added;
    }

    fn swap(&mut self) {
        let (root, entries, shares) = UNITS[2];
        let m = unit(entries, shares);
        let index = Index::build(m.crawl, PathBuf::from(root), b"print", 1, 1).unwrap();
        self.units[2] = Live::new(Arc::new(index));
        let set: Vec<Arc<Index>> = self.units.iter().map(|l| l.base.clone()).collect();
        sort::premerge(&set);
    }

    fn search(&self, text: &str, sort: EngineSort) -> Results {
        search(&self.units, text, sort, &self.opens)
    }
}

pub(crate) fn search(units: &[Live], text: &str, sort: EngineSort, opens: &Opens) -> Results {
    let q = Query::parse(text, HOME);
    let units: Vec<&Live> = units.iter().collect();
    let (scanned, _) = Live::find_units(text, false, &units, || false).unwrap();
    Results::new(1, q, scanned, sort, opens, &|| false).unwrap()
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_empty_search_by_name() {
    let s = set(OVERLAY);
    let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
    assert_eq!(entries, ENTRIES + OVERLAY);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    timing(
        "engine empty search by name, 1000000 entries + 25000 overlay",
        Some(EMPTY_MS),
        || {
            let all = black_box(s.search("", by_name));
            assert_eq!(all.count() as usize, entries);
            let first = all.rows(0, 1).remove(0);
            let last = all.rows(entries - 1, 1).remove(0);
            assert!(
                !sort::natural(
                    sort::fold(&first.name).as_bytes(),
                    sort::fold(&last.name).as_bytes()
                )
                .is_gt()
            );
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_empty_search_by_name_folders_first() {
    let s = set(OVERLAY);
    let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: true,
    };
    timing(
        "engine empty search by name, folders first, 1000000 entries + 25000 overlay",
        Some(EMPTY_MS),
        || {
            let all = black_box(s.search("", by_name));
            assert_eq!(all.count() as usize, entries);
            assert_eq!(all.rows(0, 1).remove(0).kind, EngineKind::Folder);
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_keystroke_behind_an_empty_search() {
    let s = set(OVERLAY);
    let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
    assert_eq!(entries, ENTRIES + OVERLAY);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    timing(
        "engine empty search by name then \"report\", 1000000 entries + 25000 overlay",
        None,
        || {
            assert_eq!(black_box(s.search("", by_name)).count() as usize, entries);
            let found = black_box(s.search("report", BEST)).count() as usize;
            assert!(
                found >= s.report,
                "{found} hits, {} names hold report",
                s.report
            );
        },
    );
}

fn engine_over_set(tree: &TempTree) -> (Arc<Engine>, Arc<Recorder>, Receiver<Event>, u32, u32) {
    let s = set(OVERLAY);
    let want = s.search("report", BEST).count();
    assert!(want as usize >= s.report);
    let (start, held) = mpsc::channel();
    let (engine, listener, rx) = start_with(config(tree), Some((EnginePhase::Ready, 0, held)));
    phases(&rx);
    let boot = engine.shared.units()[0].clone();
    boot.stop.store(true, Ordering::Relaxed);
    boot.watcher().close();
    let units: Vec<_> = s
        .units
        .into_iter()
        .enumerate()
        .map(|(i, live)| {
            let unit = Arc::new(Unit::new(
                live.base.root().to_path_buf(),
                (i != 0).then(|| format!("timing-{i}")),
                tree.data().join(format!("timing-{i}.index")),
                (Vec::new(), Vec::new()),
                Pool::new(1).unwrap(),
                mpsc::channel().0,
                Arc::default(),
            ));
            *unit.live.write().unwrap() = Some(live);
            unit
        })
        .collect();
    *engine.shared.units.write().unwrap() = units;
    let indexes: Vec<_> = engine
        .shared
        .units()
        .iter()
        .map(|u| u.read(|l| l.base.clone()).unwrap())
        .collect();
    assert_eq!(
        indexes.iter().map(|i| i.entries() as usize).sum::<usize>(),
        ENTRIES
    );
    sort::premerge(&indexes);
    let entries: u64 = engine
        .shared
        .units()
        .iter()
        .map(|u| u.read(Live::entries).unwrap())
        .sum();
    assert_eq!(entries as usize, ENTRIES + OVERLAY);
    start.send(None).unwrap();
    (engine, listener, rx, entries as u32, want)
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_keystroke_while_a_full_list_runs() {
    use crate::session::tests::hold_scan;

    let tree = TempTree::new("timing-two-sessions");
    let (engine, _listener, rx, entries, want) = engine_over_set(&tree);
    let a = engine.clone().session().unwrap();
    let b = engine.clone().session().unwrap();
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    measured(
        "engine keystroke while a full list runs, 1000000 entries + 25000 overlay",
        Some(SEARCH_MS),
        || {
            let (reached, release) = hold_scan(&engine);
            let ga = a.search(String::new(), by_name).unwrap();
            assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
            let start = Instant::now();
            let gb = b.search("report".to_owned(), BEST).unwrap();
            release.send(()).unwrap();
            let (mut full, mut took) = (false, None);
            while !full || took.is_none() {
                let (generation, count) = next_result(&rx);
                if generation == gb {
                    assert!(took.replace(start.elapsed()).is_none());
                    assert_eq!(count, want);
                } else {
                    assert_eq!((generation, count), (ga, entries));
                    assert!(!full);
                    full = true;
                }
            }
            took.unwrap()
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_keystroke_while_a_refresh_runs_in_the_same_window() {
    let tree = TempTree::new("timing-refresh-same");
    let (engine, _listener, rx, _, want) = engine_over_set(&tree);
    let a = engine.clone().session().unwrap();
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    measured(
        "engine keystroke while a refresh runs in the same window, 1000000 entries + 25000 overlay",
        Some(SEARCH_MS),
        || {
            a.refresh(String::new(), by_name).unwrap();
            thread::sleep(Duration::from_millis(20));
            let start = Instant::now();
            let g = a.search("report".to_owned(), BEST).unwrap();
            let took = loop {
                let (generation, count) = next_result(&rx);
                if generation == g {
                    assert_eq!(count, want);
                    break start.elapsed();
                }
            };
            thread::sleep(Duration::from_millis(200));
            took
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_keystroke_in_another_window_while_a_refresh_runs() {
    use crate::session::tests::hold_scan;

    let tree = TempTree::new("timing-refresh-other");
    let (engine, _listener, rx, entries, want) = engine_over_set(&tree);
    let b = engine.clone().session().unwrap();
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    measured(
        "engine keystroke in another window while a refresh runs, 1000000 entries + 25000 overlay",
        Some(SEARCH_MS),
        || {
            let a = engine.clone().session().unwrap();
            let (reached, release) = hold_scan(&engine);
            let ga = a.refresh(String::new(), by_name).unwrap();
            assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
            let start = Instant::now();
            let gb = b.search("report".to_owned(), BEST).unwrap();
            release.send(()).unwrap();
            let (mut full, mut took) = (false, None);
            while !full || took.is_none() {
                let (generation, count) = next_result(&rx);
                if generation == gb {
                    assert!(took.replace(start.elapsed()).is_none());
                    assert_eq!(count, want);
                } else {
                    assert_eq!((generation, count), (ga, entries));
                    assert!(!full);
                    full = true;
                }
            }
            took.unwrap()
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_refresh_every_file_by_name() {
    let tree = TempTree::new("timing-refresh");
    let (engine, _listener, rx, entries, _) = engine_over_set(&tree);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    measured(
        "engine refresh every file by name, 1000000 entries + 25000 overlay",
        None,
        || {
            let a = engine.clone().session().unwrap();
            let start = Instant::now();
            let g = a.refresh(String::new(), by_name).unwrap();
            assert_eq!(next_result(&rx), (g, entries));
            start.elapsed()
        },
    );
}

fn journaled(live: &mut Live, rng: &mut Rng, n: usize) {
    let base = live.base.clone();
    let file = |live: &Live, rng: &mut Rng| loop {
        let i = rng.below(base.entries() as usize) as u32;
        if base.attrs(i as usize).kind == EngineKind::File && !live.is_dead(i) {
            break i;
        }
    };
    let quarter = n / 4;
    for j in 0..n - 2 * quarter {
        let path = base
            .folder(rng.below(base.folders()))
            .join(format!("delta-new{j}.txt"));
        let attrs = Attrs {
            kind: EngineKind::File,
            size: rng.next() % (1 << 30),
            mtime: 1_600_000_000 + (rng.next() % 200_000_000) as i64,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        live.journaled_put(path.into_os_string().into_vec(), attrs);
    }
    for _ in 0..quarter {
        let i = file(live, rng);
        let a = live.attrs(i as usize);
        live.journaled_update(
            i,
            Attrs {
                mtime: a.mtime + 1,
                ..a
            },
        );
    }
    for _ in 0..quarter {
        let i = file(live, rng);
        live.journaled_kill(i);
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_refresh_patch() {
    let mut s = set(OVERLAY);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    let by_kind = EngineSort {
        column: EngineColumn::Kind,
        ascending: false,
        folders_first: true,
    };
    let runs = [
        (1, by_name, "by name"),
        (100, by_name, "by name"),
        (1_000, by_name, "by name"),
        (2_000, by_name, "by name"),
        (2_000, by_kind, "by kind descending folders first"),
    ];
    let mut rng = Rng(0x00DE_17A5);
    for (n, sort, order) in runs {
        measured(
            &format!(
                "engine refresh patch {order}, {n} changes, {ENTRIES} entries + {OVERLAY} overlay"
            ),
            None,
            || {
                s.units[0] = Live::new(s.units[0].base.clone());
                overlay(&mut s.units[0], OVERLAY);
                let held = s.search("", sort);
                journaled(&mut s.units[0], &mut rng, n);
                let start = Instant::now();
                let patch = super::delta::patch_units(&held, &s.units, "", sort);
                let took = start.elapsed();
                let super::delta::Patch::Done(set) = patch else {
                    panic!("a full refresh where a patch was due");
                };
                assert_eq!(set.count(), s.search("", sort).count());
                took
            },
        );
    }
    let pool = Pool::live().unwrap();
    measured(
        &format!(
            "engine refresh full fallback by name, 10000 changes, {ENTRIES} entries + {OVERLAY} overlay"
        ),
        None,
        || {
            s.units[0] = Live::new(s.units[0].base.clone());
            overlay(&mut s.units[0], OVERLAY);
            let held = s.search("", by_name);
            journaled(&mut s.units[0], &mut rng, 10_000);
            let start = Instant::now();
            let full = pool.install(|| {
                let patch = super::delta::patch_units(&held, &s.units, "", by_name);
                let super::delta::Patch::Full(super::delta::Why::Many) = patch else {
                    panic!("a patch where the full refresh was due");
                };
                s.search("", by_name)
            });
            let took = start.elapsed();
            assert_eq!(full.count(), held.count() + 2_500);
            took
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_search_one_keystroke() {
    let s = set(OVERLAY);
    assert_eq!(s.search("'report", BEST).count() as usize, s.report);
    timing(
        "engine search \"report\", 1000000 entries",
        Some(SEARCH_MS),
        || {
            let found = black_box(s.search("report", BEST)).count() as usize;
            assert_eq!(
                found, s.report,
                "{found} hits, {} names hold report",
                s.report
            );
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_search_with_typos_when_nothing_is_side_by_side() {
    use crate::query::entries_walked;
    let s = set(OVERLAY);
    let units: Vec<&Live> = s.units.iter().collect();
    let before = entries_walked();
    assert!(s.search("report", BEST).count() > 0);
    let one = entries_walked() - before;
    assert!(one > 0);
    let before = entries_walked();
    assert_eq!(s.search("xeport", BEST).count(), 0);
    assert_eq!(entries_walked() - before, 0);
    timing(
        &format!("engine search \"xeport\" with no match, {ENTRIES} entries"),
        Some(SEARCH_MS),
        || {
            assert_eq!(black_box(s.search("xeport", BEST)).count(), 0);
        },
    );
    let loose = Query::parse("qtrpt", HOME).loosened();
    assert!(!s.units[0].scan_one(&loose, &|| false).unwrap().1.is_empty());
    for (text, passes, walks, limit) in [
        ("reprot", 2, 1, Some(SEARCH_MS)),
        ("xeport", 3, 1, Some(SEARCH_MS)),
        ("qtrpt", 3, 2, None),
    ] {
        let rescue = || {
            let (scanned, took) = Live::find_units(text, true, &units, || false).unwrap();
            let q = Query::parse(text, HOME).loosened();
            let set = Results::new(1, q, scanned, BEST, &s.opens, &|| false).unwrap();
            (set, took)
        };
        let before = entries_walked();
        let (found, took) = rescue();
        assert_eq!(took, passes, "{text}");
        assert!(found.count() > 0, "{text}");
        assert_eq!(
            entries_walked() - before,
            walks * one,
            "{text}: only the passes that find rows walk"
        );
        timing(
            &format!("engine search \"{text}\", typo search on, {ENTRIES} entries"),
            limit,
            || {
                black_box(rescue());
            },
        );
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_narrow_one_keystroke() {
    let s = set(OVERLAY);
    let held: Vec<Held> = (s.units.iter().enumerate())
        .map(|(i, l)| {
            let mut live = Live::new(l.base.clone());
            live.over = l.over.clone();
            Held {
                partial: None,
                root: l.base.root().to_path_buf(),
                boot: i == 0,
                live,
            }
        })
        .collect();
    let mut n = 0usize;
    let mut eighth = || {
        n += 1;
        n % 8 == 1
    };
    let members: Vec<Members> = (held.iter())
        .map(|h| {
            let (index, mut m) = (&h.live.base, Members::default());
            for e in 0..index.entries() as usize {
                if index.attrs(e).kind == EngineKind::File && eighth() {
                    m.add(e as u32);
                }
            }
            for (path, a) in &h.live.over {
                if a.kind == EngineKind::File && eighth() {
                    m.over.insert(path.clone());
                }
            }
            m
        })
        .collect();
    let settings = Settings {
        root: PathBuf::from(UNITS[0].0),
        data: PathBuf::from("/nowhere"),
        socket_folder: Some(PathBuf::from("/nowhere")),
        home: PathBuf::from(HOME),
        exclusions: RwLock::default(),
        typos: AtomicBool::new(false),
        paused: Arc::default(),
    };
    let narrow = || {
        let mut q = Query::parse("report", HOME);
        let scanned = query::narrow(&mut q, &settings, &held, &members, &|| false).unwrap();
        Results::new(1, q, scanned, BEST, &s.opens, &|| false).unwrap()
    };
    let found = narrow().count() as usize;
    assert!(
        found > 0 && found < s.report,
        "{found} of {} hits",
        s.report
    );
    timing(
        "engine narrow \"report\", 1000000 entries, 1 file in 8",
        Some(SEARCH_MS),
        || {
            assert_eq!(black_box(narrow()).count() as usize, found);
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_sort_every_file_by_name() {
    let s = set(OVERLAY);
    let all = s.search("kind:file", BEST);
    assert_eq!(all.count() as usize, s.files);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    timing(
        "engine sort by name, every file of 1000000 entries",
        Some(SORT_MS),
        || {
            let sorted = black_box(all.sorted(2, by_name, &s.opens, &|| false).unwrap());
            assert_eq!(sorted.count() as usize, s.files);
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_first_search_after_an_index_swap() {
    let mut s = set(OVERLAY);
    measured(
        "engine first search \"report\" after an index swap, 1000000 entries",
        Some(SEARCH_MS),
        || {
            s.swap();
            let start = Instant::now();
            let found = black_box(s.search("report", BEST)).count() as usize;
            let took = start.elapsed();
            assert!(
                found >= s.report,
                "{found} hits, {} names hold report",
                s.report
            );
            took
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_first_sort_after_an_index_swap() {
    let mut s = set(OVERLAY);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    measured(
        "engine first sort by name after an index swap, every file of 1000000 entries",
        Some(SORT_MS),
        || {
            s.swap();
            let all = s.search("kind:file", BEST);
            let start = Instant::now();
            let sorted = black_box(all.sorted(2, by_name, &s.opens, &|| false).unwrap());
            let took = start.elapsed();
            assert_eq!(sorted.count() as usize, s.files);
            took
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_rows_one_page() {
    let s = set(OVERLAY);
    let all = s.search("kind:file", BEST);
    let mut rng = Rng(7);
    timing(
        "engine rows, one page of 128 from every file of 1000000 entries",
        Some(FRAME_MS),
        || {
            let start = rng.below(s.files - PAGE);
            assert_eq!(black_box(all.rows(start, PAGE)).len(), PAGE);
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_accent_free_readings_bytes() {
    let s = set(0);
    for (live, (root, ..)) in s.units.iter().zip(UNITS) {
        let b = &live.base;
        let p = b.plains();
        let text: usize = (0..p).map(|j| b.plain(j).len()).sum();
        let extra = 2 * size_of::<u64>() + (2 * p + 1) * size_of::<u32>() + text;
        let names: usize = (0..b.names()).map(|k| b.name(k).len()).sum();
        println!(
            "timing: accent-free readings {root}: {p} of {} names, {extra} bytes, {:.3} per entry (name bytes {names}) | report",
            b.names(),
            extra as f64 / b.entries() as f64
        );
        assert!(p > 0);
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_reload_saved_index() {
    let tree = TempTree::new("timing-reload");
    let file = tree.data().join(index::FILE);
    let m = million();
    Index::build(m.crawl, PathBuf::from("/timing"), b"print", 1, 1)
        .unwrap()
        .save(&file)
        .unwrap();
    timing(
        "engine reload of a saved 1000000-entry index",
        Some(RELOAD_MS),
        || {
            let index = black_box(Index::load(&file, PathBuf::from("/timing")).unwrap());
            assert_eq!(index.entries() as usize, ENTRIES);
        },
    );
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_empty_search_by_name_with_large_overlays() {
    let mut s = set(50_000);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    for count in [50_000, 100_000] {
        s.grow_overlay(count);
        assert_eq!(s.units[0].over.len(), count);
        let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
        assert_eq!(entries, ENTRIES + count);
        timing(
            &format!("engine empty search by name, {ENTRIES} entries + {count} overlay"),
            Some(EMPTY_MS),
            || {
                let all = black_box(s.search("", by_name));
                assert_eq!(all.count() as usize, entries);
                let first = all.rows(0, 1).remove(0);
                let last = all.rows(entries - 1, 1).remove(0);
                assert!(
                    !sort::natural(
                        sort::fold(&first.name).as_bytes(),
                        sort::fold(&last.name).as_bytes()
                    )
                    .is_gt()
                );
            },
        );
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_empty_search_by_name_with_large_overlays_folders_first() {
    let mut s = set(50_000);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: true,
    };
    for count in [50_000, 100_000] {
        s.grow_overlay(count);
        let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
        assert_eq!(entries, ENTRIES + count);
        timing(
            &format!(
                "engine empty search by name, folders first, {ENTRIES} entries + {count} overlay"
            ),
            Some(EMPTY_MS),
            || {
                let all = black_box(s.search("", by_name));
                assert_eq!(all.count() as usize, entries);
                assert_eq!(all.rows(0, 1).remove(0).kind, EngineKind::Folder);
            },
        );
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_empty_search_stages_with_large_overlays() {
    let s = set(100_000);
    assert_eq!(s.units[0].over.len(), 100_000);
    let entries = s.units.iter().map(Live::entries).sum::<u64>() as usize;
    assert_eq!(entries, ENTRIES + 100_000);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    let units: Vec<&Live> = s.units.iter().collect();
    for (stage, label) in ["scan", "places", "order", "drop"].into_iter().enumerate() {
        measured(
            &format!("engine empty search {label}, {ENTRIES} entries + 100000 overlay"),
            None,
            || {
                let q = Query::parse("", HOME);
                let start = Instant::now();
                let (scanned, _) = Live::find_units("", false, &units, || false).unwrap();
                let (found, ranked) = Results::gather(scanned, &|| false).unwrap();
                let scan = start.elapsed();
                let start = Instant::now();
                let (places, gaps) = sort::places(&found, &|| false).unwrap();
                let places_time = start.elapsed();
                let set = Results {
                    generation: 1,
                    searched: 1,
                    query: Arc::new(q),
                    found: Arc::new(found),
                    places: Arc::new(places),
                    gaps: Arc::new(gaps),
                    ranked: Vec::new(),
                    sort: by_name,
                    patched: false,
                };
                let start = Instant::now();
                let all = black_box(
                    set.ordered(1, ranked, by_name, &s.opens, &|| false)
                        .unwrap(),
                );
                drop(set);
                let order = start.elapsed();
                assert_eq!(all.count() as usize, entries);
                assert_eq!(all.rows(0, 1).len(), 1);
                assert_eq!(all.rows(entries - 1, 1).len(), 1);
                let start = Instant::now();
                drop(all);
                let drop_time = start.elapsed();
                [scan, places_time, order, drop_time][stage]
            },
        );
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_search_one_keystroke_with_large_overlays() {
    let mut s = set(50_000);
    for count in [50_000, 100_000] {
        s.grow_overlay(count);
        assert_eq!(s.units[0].over.len(), count);
        assert_eq!(s.search("'report", BEST).count() as usize, s.report);
        timing(
            &format!("engine search \"report\", {ENTRIES} entries + {count} overlay"),
            Some(SEARCH_MS),
            || {
                let found = black_box(s.search("report", BEST)).count() as usize;
                assert!(
                    found >= s.report,
                    "{found} hits, {} names hold report",
                    s.report
                );
            },
        );
    }
}

#[test]
#[ignore = "measuring mode only: WHEREVER_MEASURE=1 cargo test --release -- --ignored --test-threads=1 timing_"]
fn timing_sort_every_file_by_name_with_large_overlays() {
    let mut s = set(50_000);
    let by_name = EngineSort {
        column: EngineColumn::Name,
        ascending: true,
        folders_first: false,
    };
    for count in [50_000, 100_000] {
        s.grow_overlay(count);
        assert_eq!(s.units[0].over.len(), count);
        let all = s.search("kind:file", BEST);
        assert_eq!(all.count() as usize, s.files);
        timing(
            &format!("engine sort by name, every file of {ENTRIES} entries + {count} overlay"),
            Some(SORT_MS),
            || {
                let sorted = black_box(all.sorted(2, by_name, &s.opens, &|| false).unwrap());
                assert_eq!(sorted.count() as usize, s.files);
            },
        );
    }
}

#[test]
fn the_timing_set_has_the_shape_of_this_macs_three_indexes() {
    let table = [
        (597_749, 132_714, 170_218, 4_446_820),
        (339_728, 49_204, 117_239, 3_121_494),
        (62_523, 8_235, 26_756, 712_626),
    ];
    let s = set(OVERLAY);
    assert_eq!(s.units.len(), table.len());
    for (i, (live, want)) in s.units.iter().zip(table).enumerate() {
        let b = &live.base;
        let got = (
            b.entries() as usize,
            b.folders(),
            b.names(),
            (0..b.names()).map(|k| b.name(k).len()).sum::<usize>(),
        );
        println!(
            "unit {i}: entries, folders, names, name bytes {got:?}, overlay {}",
            live.over.len()
        );
        assert_eq!(got, want, "unit {i}");
        assert_eq!(
            live.over.len(),
            if i == 0 { OVERLAY } else { 0 },
            "unit {i}"
        );
    }
    let entries: usize = s.units.iter().map(|l| l.base.entries() as usize).sum();
    assert_eq!(entries, ENTRIES);
    let found = s.search("'report", BEST).count() as usize;
    println!("report: {found} of {} entries", ENTRIES + OVERLAY);
    assert_eq!(found, s.report);
    assert!(
        (ENTRIES + OVERLAY) / 10 < found && found < (ENTRIES + OVERLAY) / 7,
        "{found} hits is not about 1 entry in 8"
    );
}
