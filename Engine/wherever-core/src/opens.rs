use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::EngineError;
use crate::engine::now_secs;
use crate::error::io_error;
use crate::index;

pub(crate) const FILE: &str = "wherever.opens";
const HALF_LIFE: f64 = 14.0 * 86_400.0;
const FLOOR: f64 = 0.06;
const MAX_ENTRIES: usize = 4096;
const DEBOUNCE: u64 = 30;
pub(crate) const SAVE_DELAY: Duration = Duration::from_secs(2);
pub(crate) const LIFTED: usize = 256;

pub(crate) fn decay(age: u64) -> f64 {
    (-(age as f64) / HALF_LIFE).exp2()
}

pub(crate) fn boost(s: f64) -> i32 {
    if s > 0.0 {
        (12.0 * s.ln_1p()).min(40.0) as i32
    } else {
        0
    }
}

fn decayed((score, last): (f64, u64), now: u64) -> f64 {
    score * decay(now.saturating_sub(last))
}

#[derive(Default)]
struct History {
    entries: HashMap<Vec<u8>, (f64, u64)>,
    dirty: bool,
    due: Option<Instant>,
}

pub(crate) struct Opens {
    file: PathBuf,
    disk: Mutex<()>,
    history: Mutex<History>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn remove(path: &Path) -> Result<(), EngineError> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(io_error(path, e)),
        _ => Ok(()),
    }
}

impl Opens {
    pub(crate) fn new(file: PathBuf) -> Opens {
        Opens {
            file,
            disk: Mutex::new(()),
            history: Mutex::new(History::default()),
        }
    }

    pub(crate) fn load(&self) -> Result<(), EngineError> {
        let _disk = lock(&self.disk);
        let text = match fs::read(&self.file) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(io_error(&self.file, e)),
        };
        let mut history = lock(&self.history);
        let now = now_secs();
        for line in text.split(|&b| b == b'\n') {
            let mut f = line.splitn(3, |&b| b == b'\t');
            let (Some(s), Some(t), Some(p)) = (f.next(), f.next(), f.next()) else {
                continue;
            };
            let s = std::str::from_utf8(s)
                .ok()
                .and_then(|s| s.parse::<f64>().ok());
            let t = std::str::from_utf8(t)
                .ok()
                .and_then(|t| t.parse::<u64>().ok());
            if let (Some(s), Some(t)) = (s, t)
                && s.is_finite()
                && s > 0.0
                && p.first() == Some(&b'/')
            {
                history.entries.entry(p.to_vec()).or_insert((s, t.min(now)));
            }
        }
        Ok(())
    }

    pub(crate) fn record(&self, path: &[u8], now: u64) {
        if path.contains(&b'\n') {
            return;
        }
        let mut history = lock(&self.history);
        history.due = Some(Instant::now() + SAVE_DELAY);
        let e = history.entries.entry(path.to_vec()).or_insert((0.0, now));
        e.1 = e.1.min(now);
        if e.0 > 0.0 && now.saturating_sub(e.1) < DEBOUNCE {
            return;
        }
        *e = (decayed(*e, now) + 1.0, now);
        history.dirty = true;
        if history.entries.len() > MAX_ENTRIES {
            let mut v: Vec<(Vec<u8>, (f64, u64))> = history.entries.drain().collect();
            v.sort_by(|a, b| decayed(b.1, now).total_cmp(&decayed(a.1, now)));
            v.truncate(MAX_ENTRIES * 3 / 4);
            history.entries.extend(v);
        }
    }

    pub(crate) fn score(&self, path: &[u8], now: u64) -> f64 {
        lock(&self.history)
            .entries
            .get(path)
            .map_or(0.0, |&e| decayed(e, now))
    }

    pub(crate) fn due(&self) -> Option<Instant> {
        lock(&self.history).due
    }

    pub(crate) fn save(&self, now: u64) -> Result<(), EngineError> {
        let _disk = lock(&self.disk);
        let text = {
            let mut history = lock(&self.history);
            history.due = None;
            if !history.dirty {
                return Ok(());
            }
            history.dirty = false;
            history.entries.retain(|_, e| decayed(*e, now) >= FLOOR);
            let mut out = Vec::new();
            for (p, &(s, t)) in &history.entries {
                out.extend_from_slice(format!("{s:.3}\t{t}\t").as_bytes());
                out.extend_from_slice(p);
                out.push(b'\n');
            }
            out
        };
        let saved = if text.is_empty() {
            remove(&self.file)
        } else {
            index::write_whole(&self.file, &text)
        };
        if saved.is_err() {
            lock(&self.history).dirty = true;
        }
        saved
    }

    pub(crate) fn clear(&self) -> Result<(), EngineError> {
        let _disk = lock(&self.disk);
        *lock(&self.history) = History::default();
        remove(&self.file)?;
        index::temps(&self.file).iter().try_for_each(|t| remove(t))
    }

    pub(crate) fn is_empty(&self) -> bool {
        lock(&self.history).entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{Locked, TempTree};
    use crate::engine::tests::{Event, next, phases, seek, shared, start};
    use crate::engine::{BEST_MATCH, Engine};
    use crate::{EngineHit, EngineVolume};
    use std::fs::File;
    use std::sync::Arc;
    use std::sync::mpsc::Receiver;
    use std::time::SystemTime;

    const T: u64 = 1_000_000_000;
    const DAY: u64 = 86_400;

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 0.01
    }

    fn history(tree: &TempTree) -> Opens {
        Opens::new(tree.data().join(FILE))
    }

    #[test]
    fn an_open_decays_and_a_quick_reopen_counts_once() {
        let o = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        o.record(b"/p/a.txt", T);
        assert_eq!(o.score(b"/p/a.txt", T), 1.0);
        o.record(b"/p/a.txt", T + 10);
        assert_eq!(
            o.score(b"/p/a.txt", T + 10),
            decay(10),
            "within 30 s is the same open: one open, still dated T"
        );
        o.record(b"/p/a.txt", T + 1000);
        assert!(near(o.score(b"/p/a.txt", T + 1000), 2.0));
        assert!(
            near(o.score(b"/p/a.txt", T + 1000 + 14 * DAY), 1.0),
            "two weeks halve it"
        );
        assert_eq!(
            o.score(b"/p/a.txt", T),
            o.score(b"/p/a.txt", T + 1000),
            "a clock moved back gives no decay"
        );
        assert_eq!(o.score(b"/p/never.txt", T), 0.0);
    }

    #[test]
    fn a_clock_moved_back_does_not_freeze_the_history() {
        let o = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        o.record(b"/p/a.txt", T + DAY);
        o.record(b"/p/a.txt", T);
        o.record(b"/p/a.txt", T + 1000);
        assert!(
            o.score(b"/p/a.txt", T + 1000) > 1.5,
            "an open after the clock came back counts"
        );
    }

    #[test]
    fn a_line_dated_ahead_of_the_clock_decays_from_now() {
        let tree = TempTree::new("opens-future");
        fs::create_dir_all(tree.data()).unwrap();
        let now = now_secs();
        fs::write(
            tree.data().join(FILE),
            format!(
                "1.000\t{}\t/t/ahead.txt\n1.000\t{now}\t/t/now.txt\n",
                now + 365 * DAY
            ),
        )
        .unwrap();
        let o = history(&tree);
        o.load().unwrap();
        let later = now + 30 * DAY;
        assert!(near(o.score(b"/t/ahead.txt", later), decay(30 * DAY)));
        assert!(near(
            o.score(b"/t/ahead.txt", later),
            o.score(b"/t/now.txt", later)
        ));
    }

    #[test]
    fn the_boost_grows_slowly_up_to_its_cap() {
        assert_eq!(
            (boost(0.0), boost(1.0), boost(5.0), boost(100.0)),
            (0, 8, 21, 40)
        );
    }

    #[test]
    fn past_4096_entries_the_best_3072_stay() {
        let o = Opens::new(PathBuf::from("/nowhere/wherever.opens"));
        for i in 0..=MAX_ENTRIES as u64 {
            o.record(format!("/p/{i}").as_bytes(), T + i * 10);
        }
        let entries = lock(&o.history).entries.len();
        assert_eq!(entries, 3072);
        let first_kept = MAX_ENTRIES as u64 + 1 - 3072;
        let now = T + MAX_ENTRIES as u64 * 10;
        assert!(o.score(format!("/p/{first_kept}").as_bytes(), now) > 0.0);
        assert_eq!(
            o.score(format!("/p/{}", first_kept - 1).as_bytes(), now),
            0.0
        );
        assert_eq!(o.score(format!("/p/{MAX_ENTRIES}").as_bytes(), now), 1.0);
    }

    #[test]
    fn a_save_loads_back_and_drops_what_decayed_away() {
        let tree = TempTree::new("opens-round");
        let o = history(&tree);
        let (tab, accent, old) = (
            "/t/a\tb.txt".as_bytes(),
            "/t/çay ünü.txt".as_bytes(),
            b"/t/old.txt",
        );
        o.record(tab, T);
        o.record(tab, T + 1000);
        o.record(accent, T + 1000);
        o.record(old, T + 1000 - 60 * DAY);
        o.record(b"/t/a\nb.txt", T + 1000);
        assert_eq!(
            o.score(b"/t/a\nb.txt", T + 1000),
            0.0,
            "a newline path is not recorded"
        );
        o.save(T + 1000).unwrap();
        assert!(index::temps(&o.file).is_empty());
        let back = history(&tree);
        back.load().unwrap();
        assert!(near(back.score(tab, T + 1000), 2.0));
        assert!(near(back.score(accent, T + 1000), 1.0));
        assert_eq!(back.score(old, T + 1000), 0.0);
        assert_eq!(lock(&back.history).entries.len(), 2);
    }

    #[test]
    fn bad_lines_are_skipped_and_the_good_ones_load() {
        let tree = TempTree::new("opens-bad");
        fs::create_dir_all(tree.data()).unwrap();
        let lines = "garbage\n1.000\tsoon\t/t/a.txt\nNaN\t5\t/t/b.txt\n2.000\t5\trelative.txt\n\n\t\t\n2.000\t5\t/t/good.txt\n-1\t5\t/t/c.txt\n3.5\t5";
        fs::write(tree.data().join(FILE), lines).unwrap();
        let o = history(&tree);
        o.load().unwrap();
        assert_eq!(o.score(b"/t/good.txt", 5), 2.0);
        assert_eq!(lock(&o.history).entries.len(), 1);
    }

    #[test]
    fn a_load_keeps_an_open_made_before_it() {
        let tree = TempTree::new("opens-merge");
        fs::create_dir_all(tree.data()).unwrap();
        fs::write(
            tree.data().join(FILE),
            format!("5.000\t{T}\t/t/a.txt\n5.000\t{T}\t/t/b.txt\n"),
        )
        .unwrap();
        let o = history(&tree);
        o.record(b"/t/a.txt", T);
        o.load().unwrap();
        assert_eq!(o.score(b"/t/a.txt", T), 1.0);
        assert_eq!(o.score(b"/t/b.txt", T), 5.0);
    }

    #[test]
    fn a_clear_deletes_both_files_and_a_later_save_writes_nothing() {
        let tree = TempTree::new("opens-clear");
        let o = history(&tree);
        o.record(b"/t/a.txt", T);
        o.save(T).unwrap();
        assert!(tree.data().join(FILE).exists());
        fs::write(
            tree.data().join(format!("{FILE}.1.0.tmp")),
            b"left by a cut save",
        )
        .unwrap();
        o.clear().unwrap();
        assert!(!tree.data().join(FILE).exists());
        assert!(index::temps(&o.file).is_empty());
        assert_eq!(o.score(b"/t/a.txt", T), 0.0);
        o.save(T).unwrap();
        assert!(!tree.data().join(FILE).exists());
    }

    fn order(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        query: &str,
        strict: bool,
    ) -> Vec<EngineHit> {
        let session = engine.clone().session().unwrap();
        let g = session.search(query.to_owned(), BEST_MATCH).unwrap();
        loop {
            match next(rx) {
                Event::Ready(got, count) if got == g => return session.rows(g, 0, count).unwrap(),
                Event::Changed(_) if strict => panic!("{query}: unexpected results_changed"),
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn path(h: &EngineHit) -> String {
        Path::new(&h.folder)
            .join(&h.name)
            .to_str()
            .unwrap()
            .to_owned()
    }

    fn names(hits: &[EngineHit]) -> Vec<&str> {
        hits.iter().map(|h| h.name.as_str()).collect()
    }

    fn pair(name: &str) -> TempTree {
        let tree = TempTree::new(name);
        fs::write(tree.0.join("pair-1.txt"), b"").unwrap();
        fs::write(tree.0.join("pair-2.txt"), b"").unwrap();
        tree
    }

    #[test]
    fn an_open_lifts_the_second_of_a_tie_to_first() {
        let tree = pair("opens-tie");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let before = order(&engine, &rx, "pair-", true);
        assert_eq!(before.len(), 2);
        engine.record_open(path(&before[1])).unwrap();
        let after = order(&engine, &rx, "pair-", true);
        assert_eq!(
            names(&after),
            [before[1].name.as_str(), before[0].name.as_str()]
        );
    }

    #[test]
    fn a_boost_never_lifts_a_hit_across_a_tier() {
        let tree = TempTree::new("opens-tiers");
        fs::create_dir(tree.0.join("node_modules")).unwrap();
        File::create(tree.0.join("node_modules/report.txt"))
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(730 * DAY))
            .unwrap();
        fs::write(tree.0.join("reports-2024.txt"), b"").unwrap();
        fs::write(tree.0.join("rpeort.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let before = order(&engine, &rx, "report", true);
        assert_eq!(names(&before), ["report.txt", "reports-2024.txt"]);
        drop(engine);
        let now = now_secs();
        let seeded = format!("100.000\t{now}\t{}\n", path(&before[1]));
        fs::write(tree.data().join(FILE), seeded).unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        assert_eq!(order(&engine, &rx, "report", true), before);
    }

    #[test]
    fn a_hundred_quick_opens_through_the_real_clock_are_one_open() {
        let tree = pair("opens-debounce");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        for _ in 0..100 {
            engine.record_open(path(&hits[1])).unwrap();
        }
        let score = shared(&engine)
            .opens
            .score(path(&hits[1]).as_bytes(), now_secs());
        assert!(near(score, 1.0));
        assert_eq!(boost(score), 8);
    }

    #[test]
    fn a_relative_path_is_an_error() {
        let tree = pair("opens-relative");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        assert!(matches!(
            engine.record_open("pair-1.txt".to_owned()),
            Err(EngineError::Io { .. })
        ));
    }

    #[test]
    fn only_the_best_256_rows_are_lifted() {
        let tree = TempTree::new("opens-window");
        for i in 0..300 {
            fs::write(tree.0.join(format!("many-{i:03}.txt")), b"").unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let before = order(&engine, &rx, "many-", true);
        assert_eq!(before.len(), 300);
        drop(engine);
        let now = now_secs();
        let seeded = format!(
            "100.000\t{now}\t{}\n100.000\t{now}\t{}\n",
            path(&before[255]),
            path(&before[299])
        );
        fs::write(tree.data().join(FILE), seeded).unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let after = order(&engine, &rx, "many-", true);
        assert_eq!(after[0], before[255]);
        assert_eq!(after[1..256], before[..255]);
        assert_eq!(after[256..], before[256..], "the 300th stays where it was");
    }

    #[test]
    fn the_lift_survives_a_restart() {
        let tree = pair("opens-restart");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let before = order(&engine, &rx, "pair-", true);
        engine.record_open(path(&before[1])).unwrap();
        drop(engine);
        let saved = fs::read_to_string(tree.data().join(FILE)).unwrap();
        assert!(saved.ends_with(&format!("\t{}\n", path(&before[1]))));
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let after = order(&engine, &rx, "pair-", true);
        assert_eq!(
            names(&after),
            [before[1].name.as_str(), before[0].name.as_str()]
        );
    }

    #[test]
    fn a_file_on_a_second_disk_is_lifted_above_the_boot_volume() {
        let boot = TempTree::new("opens-disk");
        let disk = TempTree::new("opens-disk-d");
        fs::write(boot.0.join("pair-1.txt"), b"").unwrap();
        fs::write(disk.0.join("pair-2.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine
            .set_volumes(vec![EngineVolume {
                root: disk.real(),
                id: "0D0D0D0D-0000-4000-8000-00000000000D".to_owned(),
            }])
            .unwrap();
        let (b, d) = (boot.real(), disk.real());
        seek(
            &engine,
            &rx,
            "pair-",
            &[("pair-1.txt", &b), ("pair-2.txt", &d)],
            false,
        );
        let before = order(&engine, &rx, "pair-", false);
        assert_eq!(
            names(&before),
            ["pair-1.txt", "pair-2.txt"],
            "the boot volume answers first"
        );
        engine.record_open(format!("{d}/pair-2.txt")).unwrap();
        let after = order(&engine, &rx, "pair-", false);
        assert_eq!(names(&after), ["pair-2.txt", "pair-1.txt"]);
        assert_eq!(after[0].folder, d);
    }

    #[test]
    fn a_clear_sends_one_results_changed_and_a_record_none() {
        let tree = pair("opens-signal");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let before = order(&engine, &rx, "pair-", true);
        engine.record_open(path(&before[1])).unwrap();
        let lifted = order(&engine, &rx, "pair-", true);
        assert_eq!(lifted[0], before[1]);
        engine.clear_opens().unwrap();
        let changed = rx
            .try_iter()
            .filter(|e| matches!(e, Event::Changed(_)))
            .count();
        assert_eq!(changed, 1);
        assert_eq!(order(&engine, &rx, "pair-", true), before);
    }

    #[test]
    fn record_clear_drop_leaves_no_file() {
        let tree = pair("opens-cleared");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        engine.record_open(path(&hits[0])).unwrap();
        engine.clear_opens().unwrap();
        drop(engine);
        assert!(!tree.data().join(FILE).exists());
        assert!(index::temps(&tree.data().join(FILE)).is_empty());
    }

    #[test]
    fn record_clear_record_drop_saves_only_the_second_path() {
        let tree = pair("opens-second");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        engine.record_open(path(&hits[0])).unwrap();
        engine.clear_opens().unwrap();
        engine.record_open(path(&hits[1])).unwrap();
        drop(engine);
        let saved = fs::read_to_string(tree.data().join(FILE)).unwrap();
        assert_eq!(saved.lines().count(), 1);
        assert!(saved.ends_with(&format!("\t{}\n", path(&hits[1]))));
    }

    #[test]
    fn a_flush_saves_an_open_at_once_with_the_engine_alive() {
        let tree = pair("opens-flush");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        let file = tree.data().join(FILE);
        engine.record_open(path(&hits[1])).unwrap();
        assert!(!file.exists());
        engine.flush_opens().unwrap();
        let saved = fs::read_to_string(&file).unwrap();
        assert_eq!(saved.lines().count(), 1);
        assert!(saved.ends_with(&format!("\t{}\n", path(&hits[1]))));
    }

    #[test]
    fn a_flush_with_nothing_new_writes_no_file() {
        let tree = pair("opens-flush-empty");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        engine.flush_opens().unwrap();
        assert!(!tree.data().join(FILE).exists());
    }

    #[test]
    fn a_failed_flush_returns_the_error_and_keeps_the_open_for_the_next_save() {
        let tree = pair("opens-flush-readonly");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        {
            let _locked = Locked::new(vec![tree.data()]);
            engine.record_open(path(&hits[1])).unwrap();
            assert!(engine.flush_opens().is_err());
        }
        engine.flush_opens().unwrap();
        let saved = fs::read_to_string(tree.data().join(FILE)).unwrap();
        assert!(saved.ends_with(&format!("\t{}\n", path(&hits[1]))));
    }

    #[test]
    fn a_failed_save_is_one_fault_and_keeps_the_history() {
        let tree = pair("opens-readonly");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let hits = order(&engine, &rx, "pair-", true);
        let _locked = Locked::new(vec![tree.data()]);
        engine.record_open(path(&hits[1])).unwrap();
        let mut faults = 0;
        while let Ok(event) = rx.recv_timeout(Duration::from_secs(10)) {
            if let Event::Fault(message) = event {
                assert!(message.contains("saving the open history"), "{message}");
                faults += 1;
                break;
            }
        }
        assert_eq!(faults, 1);
        let after = order(&engine, &rx, "pair-", true);
        assert_eq!(after[0], hits[1]);
    }
}
