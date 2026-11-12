use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use rayon::prelude::*;

use crate::crawl;
use crate::engine::{self, Shared};
use crate::fsevents::{
    EVENT_IDS_WRAPPED, Event, HISTORY_DONE, KERNEL_DROPPED, MOUNT, MUST_SCAN_SUBDIRS, UNMOUNT,
    USER_DROPPED,
};
use crate::index::Index;
use crate::live::{self, Live};
use crate::unit::{self, Unit};
use crate::{EngineError, EngineKind, EnginePhase};

const COMPACT_PENDING: usize = 50_000;
const COMPACT_HARD: usize = 100_000;
const COMPACT_QUIET: Duration = Duration::from_secs(30);
const COMPACT_AGE: Duration = Duration::from_secs(5 * 60);
const COMPACT_RETRY: Duration = Duration::from_secs(60);
pub(crate) const COMPACT_EVERY: Duration = Duration::from_secs(12 * 60 * 60);
const SYNC_MARGIN: u64 = 120;
const REPLAY_QUIET: Duration = Duration::from_secs(2);
const REPLAYS: u32 = 3;
const RECOVERY_BATCH: usize = 16;
const REPLAY_REPORT: Duration = Duration::from_millis(100);

struct Recovery {
    dirs: std::vec::IntoIter<Vec<u8>>,
    started: u64,
}

pub struct Apply {
    gap: Option<(u64, Instant)>,
    replays: u32,
    relist: bool,
    checked: bool,
    phase: EnginePhase,
    recovery: Option<Recovery>,
    last_edit: Instant,
    over_soft: Option<Instant>,
    last_try: Option<Instant>,
    reported: Option<Instant>,
    mounted: fn(&Path) -> bool,
    #[cfg(test)]
    fetched: Option<Box<dyn FnOnce() + Send>>,
}

impl Apply {
    pub fn new() -> Apply {
        Apply {
            gap: None,
            replays: 0,
            relist: false,
            checked: false,
            phase: EnginePhase::Ready,
            recovery: None,
            last_edit: Instant::now(),
            over_soft: None,
            last_try: None,
            reported: None,
            mounted: crawl::is_mount,
            #[cfg(test)]
            fetched: None,
        }
    }

    fn compact_due(&mut self, pending: usize, now: Instant) -> bool {
        if pending <= COMPACT_PENDING {
            self.over_soft = None;
            self.last_try = None;
            return false;
        }
        self.over_soft.get_or_insert(now);
        self.recovery.is_none() && self.compact_wait(pending, now).is_zero()
    }

    fn compact_wait(&self, pending: usize, now: Instant) -> Duration {
        let idle = Duration::from_secs(60);
        if pending <= COMPACT_PENDING {
            return idle;
        }
        let due = if pending > COMPACT_HARD {
            now
        } else {
            (self.last_edit + COMPACT_QUIET).min(self.over_soft.unwrap_or(now) + COMPACT_AGE)
        };
        let due = self.last_try.map_or(due, |at| due.max(at + COMPACT_RETRY));
        due.saturating_duration_since(now).min(idle)
    }

    fn compact_tried(&mut self, pending: usize, now: Instant) {
        self.last_try = (pending > COMPACT_PENDING).then_some(now);
        if pending <= COMPACT_PENDING {
            self.over_soft = None;
        }
    }
}

pub fn run(shared: &Shared, unit: &Unit, batches: &Receiver<Vec<Event>>) {
    let mut a = Apply::new();
    a.relist = unit.relist.load(std::sync::atomic::Ordering::Relaxed);
    let mut saved = Instant::now();
    let Some(mut pending) = unit.read(Live::pending) else {
        return;
    };
    loop {
        let wait = a.compact_wait(pending, Instant::now());
        let paused = shared
            .settings
            .paused
            .load(std::sync::atomic::Ordering::Relaxed);
        let wait = if (a.relist || a.recovery.is_some()) && !paused {
            Duration::ZERO
        } else if a.gap.is_some() {
            wait.min(Duration::from_millis(250))
        } else {
            wait
        };
        let mut events = match batches.recv_timeout(wait) {
            Ok(events) => events,
            Err(RecvTimeoutError::Timeout) => Vec::new(),
            Err(RecvTimeoutError::Disconnected) => return,
        };
        if unit.stopped() {
            return;
        }
        #[cfg(test)]
        if shared
            .fail_apply
            .swap(false, std::sync::atomic::Ordering::Relaxed)
        {
            panic!("injected apply panic");
        }
        events.extend(batches.try_iter().flatten());
        let restart = step(shared, unit, &mut a, events, Instant::now());
        if let Some(from) = restart.or_else(|| unit.resume_from()) {
            rewatch(shared, unit, &mut a, from);
        }
        let Some((updated, stale)) = unit.read(|l| (l.pending(), l.event_id != l.base.event_id()))
        else {
            return;
        };
        pending = updated;
        let due = a.compact_due(pending, Instant::now());
        let checked = std::mem::take(&mut a.checked);
        if a.recovery.is_none() && (due || checked || (stale && saved.elapsed() > COMPACT_EVERY)) {
            compact(shared, unit);
            saved = Instant::now();
            let Some(updated) = unit.read(Live::pending) else {
                return;
            };
            pending = updated;
            a.compact_tried(pending, saved);
        }
        if a.recovery.is_none()
            && !a.relist
            && !unit.relist.load(std::sync::atomic::Ordering::Relaxed)
            && unit
                .rereading
                .swap(false, std::sync::atomic::Ordering::Relaxed)
        {
            shared.report();
        }
    }
}

fn rewatch(shared: &Shared, unit: &Unit, a: &mut Apply, from: u64) {
    let Err(e) = unit.watch(from) else {
        return;
    };
    if unit.stopped() {
        return;
    }
    shared.fault(format!(
        "live updates could not replay lost events: {e}; relisting the changed folders"
    ));
    unit.write(|l| l.event_id = l.event_id.min(from));
    a.relist = true;
    step(shared, unit, a, Vec::new(), Instant::now());
}

pub fn step(
    shared: &Shared,
    unit: &Unit,
    a: &mut Apply,
    events: Vec<Event>,
    now: Instant,
) -> Option<u64> {
    let root = &unit.root;
    let paused = shared
        .settings
        .paused
        .load(std::sync::atomic::Ordering::Relaxed);
    let (current, replaying, since, device) = {
        let w = unit.watcher();
        (w.current(), w.replaying, w.since, w.device != 0)
    };
    let events = if current == 0 { Vec::new() } else { events };
    let had_events = !events.is_empty();
    let (event_id, edits, opened_edits, entries) =
        unit.read(|l| (l.event_id, l.edits(), l.opened_edits(), l.entries()))?;
    let (was, mut done) = (a.phase, false);
    let (mut last_good, mut max_id) = (event_id, 0);
    let (mut relist, mut wrapped) = (!paused && std::mem::take(&mut a.relist), false);
    let mut dirs: HashMap<Vec<u8>, bool> = HashMap::new();
    let nested = shared.nested(root);
    let is_mount = a.mounted;
    let mut mounts: HashMap<PathBuf, bool> = HashMap::new();
    let mut mounted = |p: &Path| *mounts.entry(p.to_path_buf()).or_insert_with(|| is_mount(p));
    let replay = unit.owed().is_some();
    for e in events {
        let path = live::normalize(&e.path);
        let p = live::as_path(&path);
        let scan = e.flags & MUST_SCAN_SUBDIRS != 0;
        let lost = scan && root.starts_with(p);
        if device
            && e.stream == current
            && replaying
            && !done
            && e.id <= since
            && e.flags & HISTORY_DONE == 0
            && !(replay && lost)
        {
            continue;
        }
        if lost {
            if e.flags & (USER_DROPPED | KERNEL_DROPPED) == USER_DROPPED {
                if e.stream == current {
                    let from = if replaying && !done { since } else { last_good };
                    a.gap = Some((a.gap.map_or(from, |(g, _)| g.min(from)), now));
                }
                continue;
            }
            relist = true;
        }
        if e.stream == current && e.flags & EVENT_IDS_WRAPPED != 0 {
            (relist, wrapped) = (true, !device);
        }
        let marker = lost
            || e.flags
                & (HISTORY_DONE
                    | USER_DROPPED
                    | KERNEL_DROPPED
                    | MOUNT
                    | UNMOUNT
                    | EVENT_IDS_WRAPPED)
                != 0;
        if e.stream == current && !(device && marker) {
            max_id = max_id.max(e.id);
            if a.gap.is_none() {
                last_good = last_good.max(e.id);
            }
        }
        if e.flags & HISTORY_DONE != 0 {
            if e.stream == current {
                done = true;
            }
            if a.gap.is_none() {
                a.replays = 0;
            }
            continue;
        }
        if lost
            || e.flags & (MOUNT | UNMOUNT) != 0
            || crawl::blocked(&unit.skip, p)
            || !unit::owns(root, &nested, p, &mut mounted)
        {
            continue;
        }
        *dirs.entry(path).or_default() |= scan;
    }
    if done {
        unit.watcher().replaying = false;
    }
    let skip = [unit.skip.as_slice(), &nested].concat();
    let disk = unit.disk(&skip);
    if !dirs.is_empty() {
        let fetched: Vec<_> = unit
            .read(|l| dirs.iter().map(|(p, &r)| l.fetch(p, r, &disk)).collect())
            .unwrap_or_default();
        #[cfg(test)]
        if let Some(hold) = a.fetched.take() {
            hold();
        }
        unit.update(shared, |l, disk| {
            for f in fetched {
                l.apply(f, disk);
            }
        });
    }
    let replay = a
        .gap
        .filter(|&(_, at)| now.duration_since(at) >= REPLAY_QUIET)
        .map(|(from, _)| from);
    let recover = relist || (!paused && replay.is_some() && a.replays >= REPLAYS);
    if had_events || recover {
        unit.write(|l| {
            if recover {
                let from = if wrapped { 0 } else { event_id };
                l.recovery_from = Some(l.recovery_from.map_or(from, |old| old.min(from)));
            }
            l.event_id = match a.gap {
                Some((from, _)) => l.event_id.min(from),
                None if wrapped => max_id,
                None => l.event_id.max(max_id),
            };
        });
    }
    let mut restart = None;
    if recover {
        unit.rereading
            .store(true, std::sync::atomic::Ordering::Relaxed);
        #[cfg(test)]
        unit.relists
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        a.recovery = relist_changed(shared, unit, &disk, &mut |d| {
            unit::owns(root, &nested, live::as_path(d), &mut mounted)
        });
        (a.gap, a.replays) = (None, 0);
    } else if let Some(from) = replay {
        restart = Some(from);
        (a.gap, a.replays) = (None, a.replays + 1);
    } else if had_events && a.recovery.is_none() && a.gap.is_none() && !(replaying && !done) {
        let synced_at = engine::now_secs();
        unit.write(|l| l.synced_at = synced_at);
    }
    if !had_events
        && !paused
        && let Some(recovery) = &mut a.recovery
        && recover_batch(shared, unit, &disk, recovery, &mut |d| {
            unit::owns(root, &nested, live::as_path(d), &mut mounted)
        })
    {
        a.recovery = None;
    }
    if a.recovery.is_none()
        && !unit.stopped()
        && unit.read(|l| l.recovery_from.is_none()).unwrap_or(false)
        && unit
            .relist
            .swap(false, std::sync::atomic::Ordering::Relaxed)
    {
        a.checked = true;
    }
    if done {
        a.phase = EnginePhase::Live;
    }
    let (edits_now, opened_now, entries_now) =
        unit.read(|l| (l.edits(), l.opened_edits(), l.entries()))?;
    if edits_now != edits {
        a.last_edit = now;
        let _ = shared
            .listener
            .results_changed(edits_now - edits == opened_now - opened_edits);
    }
    show_count(
        shared,
        unit,
        a,
        entries != entries_now || a.phase != was,
        (done && replaying) || a.phase != was,
        entries_now,
        now,
    );
    if a.gap.is_none() && a.recovery.is_none() && unit.owed().is_some() && !unit.watcher().replaying
    {
        a.checked = check(shared, unit, &disk, &mut |d| {
            unit::owns(root, &nested, live::as_path(d), &mut mounted)
        });
        let (edits_checked, entries_checked) = unit.read(|l| (l.edits(), l.entries()))?;
        if edits_checked != edits_now {
            a.last_edit = now;
            let _ = shared.listener.results_changed(false);
        }
        show_count(
            shared,
            unit,
            a,
            entries_checked != entries_now,
            false,
            entries_checked,
            now,
        );
    }
    restart
}

fn show_count(
    shared: &Shared,
    unit: &Unit,
    a: &mut Apply,
    moved: bool,
    turned: bool,
    entries: u64,
    now: Instant,
) {
    if moved {
        unit.set(a.phase, entries);
    }
    let due = a.phase == EnginePhase::Live
        || a.reported
            .is_none_or(|at| now.duration_since(at) >= REPLAY_REPORT);
    if turned || (moved && due) {
        a.reported = Some(now);
        shared.report();
    }
}

fn relist_changed(
    shared: &Shared,
    unit: &Unit,
    disk: &live::Disk,
    owned: &mut impl FnMut(&[u8]) -> bool,
) -> Option<Recovery> {
    let started = engine::now_secs();
    let dirs =
        unit.read(|l| l.changed_dirs(l.synced_at.saturating_sub(SYNC_MARGIN) as i64, disk))?;
    for d in dirs.iter().filter(|d| owned(d)) {
        if unit.stopped() {
            return None;
        }
        let f = unit.read(|l| l.fetch(d, false, disk))?;
        unit.update(shared, |l, disk| l.apply(f, disk));
    }
    let listed: HashSet<_> = dirs.into_iter().collect();
    let remaining = unit.read(|l| l.recovery_dirs(&listed))?;
    if remaining.is_empty() {
        unit.write(|l| {
            l.synced_at = started;
            l.recovery_from = None;
        });
        None
    } else {
        Some(Recovery {
            dirs: remaining.into_iter(),
            started,
        })
    }
}

fn recover_batch(
    shared: &Shared,
    unit: &Unit,
    disk: &live::Disk,
    recovery: &mut Recovery,
    owned: &mut impl FnMut(&[u8]) -> bool,
) -> bool {
    if unit.stopped() || disk.stop.load(std::sync::atomic::Ordering::Relaxed) {
        return false;
    }
    let dirs: Vec<_> = recovery
        .dirs
        .by_ref()
        .take(RECOVERY_BATCH)
        .filter(|d| owned(d))
        .collect();
    let Some(fetched) = unit.read(|l| {
        disk.pool.install(|| {
            dirs.par_iter()
                .filter_map(|d| l.fetch_changed(d, disk))
                .collect::<Vec<_>>()
        })
    }) else {
        return false;
    };
    if unit.stopped() || disk.stop.load(std::sync::atomic::Ordering::Relaxed) {
        return false;
    }
    let done = recovery.dirs.len() == 0;
    if !fetched.is_empty() || done {
        unit.update(shared, |l, disk| {
            for f in fetched {
                l.apply(f, disk);
            }
            if done {
                l.synced_at = recovery.started;
                l.recovery_from = None;
            }
        });
    }
    done
}

fn check(
    shared: &Shared,
    unit: &Unit,
    disk: &live::Disk,
    owned: &mut impl FnMut(&[u8]) -> bool,
) -> bool {
    let Some((_, synced)) = unit.owed() else {
        return false;
    };
    let started = engine::now_secs();
    let Some(changed) =
        unit.read(|l| l.changed_dirs(synced.saturating_sub(SYNC_MARGIN) as i64, disk))
    else {
        return false;
    };
    let mut dirs: Vec<(Vec<u8>, bool)> = changed.into_iter().map(|d| (d, false)).collect();
    let root = unit.root.as_os_str().as_bytes();
    if !dirs.iter().any(|(d, _)| d == root) {
        dirs.push((root.to_vec(), false));
    }
    if let Ok(listing) = crawl::list_one(&unit.root) {
        for e in &listing.ents {
            let name = listing.name(e);
            if name.starts_with(b".") && e.kind == EngineKind::Folder && !e.attrs().mount {
                let path = unit.root.join(OsStr::from_bytes(name));
                dirs.push((path.into_os_string().into_vec(), true));
            }
        }
    }
    for (d, recursive) in dirs.iter().filter(|(d, _)| owned(d)) {
        if unit.stopped() || disk.stop.load(std::sync::atomic::Ordering::Relaxed) {
            return false;
        }
        let Some(f) = unit.read(|l| l.fetch(d, *recursive, disk)) else {
            return false;
        };
        unit.update(shared, |l, disk| l.apply(f, disk));
    }
    if unit.stopped() || disk.stop.load(std::sync::atomic::Ordering::Relaxed) {
        return false;
    }
    unit.write(|l| l.synced_at = started);
    unit.rereading
        .store(true, std::sync::atomic::Ordering::Relaxed);
    unit.set_owed(None);
    true
}

pub fn compact(shared: &Shared, unit: &Unit) {
    if let Some(index) = fold(shared, unit, unit) {
        unit.put(shared, Live::new(Arc::new(index)));
    }
}

fn built(from: &Unit, to: &Unit) -> Result<Option<Index>, EngineError> {
    if from.stopped() {
        return Ok(None);
    }
    let Some((crawl, (event_id, synced_at), skips)) =
        from.read(|l| (l.to_crawl(), from.kept(l), l.base.skipped().to_vec()))
    else {
        return Ok(None);
    };
    let mut index = match Index::build_until(
        crawl,
        to.root.clone(),
        &to.print,
        event_id,
        synced_at,
        &|| from.stopped() || to.stopped(),
    ) {
        Ok(index) => index,
        Err(EngineError::Stopped) => return Ok(None),
        Err(e) => return Err(e),
    };
    index.set_skips(skips);
    to.stamp(&mut index);
    Ok((!from.stopped() && !to.stopped()).then_some(index))
}

pub fn fold(shared: &Shared, from: &Unit, to: &Unit) -> Option<Index> {
    let index = match built(from, to) {
        Ok(index) => index?,
        Err(e) => {
            shared.fault(e.to_string());
            return None;
        }
    };
    if let Err(e) = index.save(&to.file) {
        shared.fault(format!("{e}; the next launch replays from the last save"));
    }
    Some(index)
}

fn save_owed(stale: bool, paused: bool, age: Option<Duration>, pending: usize) -> bool {
    stale && (paused || pending > COMPACT_PENDING || age.is_none_or(|age| age > COMPACT_EVERY))
}

fn saved_age(file: &Path) -> Option<Duration> {
    let modified = std::fs::metadata(file).and_then(|m| m.modified()).ok()?;
    Some(modified.elapsed().unwrap_or_default())
}

pub fn flush(shared: &Shared, unit: &Unit) {
    let paused = shared
        .settings
        .paused
        .load(std::sync::atomic::Ordering::Relaxed);
    let owed = unit.read(|l| {
        l.recovery_from.is_none()
            && !unit.relist.load(std::sync::atomic::Ordering::Relaxed)
            && matches!(
                unit.status().0,
                EnginePhase::Ready | EnginePhase::Live | EnginePhase::Failed
            )
            && save_owed(
                unit.kept(l).0 != l.base.event_id(),
                paused,
                saved_age(&unit.file),
                l.pending(),
            )
    });
    if owed == Some(true)
        && let Ok(Some(index)) = built(unit, unit)
    {
        let _ = index.save(&unit.file);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{Locked, TempTree};
    use crate::engine::tests::{Event as Heard, bench, config};
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::Path;
    use std::sync::atomic::Ordering;

    const DROP: u32 = MUST_SCAN_SUBDIRS | USER_DROPPED;

    fn ev(path: &str, flags: u32, id: u64, stream: u32) -> Event {
        Event {
            path: path.as_bytes().to_vec(),
            flags,
            id,
            stream,
        }
    }

    fn names(unit: &Unit, query: &str) -> Vec<(String, String)> {
        let found = unit.read(|l| l.find(query, || false)).flatten().unwrap();
        let mut v: Vec<_> = found
            .rows(0, usize::MAX)
            .into_iter()
            .map(|h| (h.name, h.folder))
            .collect();
        v.sort();
        v
    }

    fn heard(rx: &Receiver<Heard>) -> Vec<Option<(EnginePhase, u64)>> {
        rx.try_iter()
            .filter_map(|e| match e {
                Heard::Changed(_) => Some(None),
                Heard::State(s) => Some(Some((s.phase, s.indexed))),
                Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                Heard::Ready(..) | Heard::Progress(..) | Heard::Failed(_) => None,
            })
            .collect()
    }

    fn restarted(unit: &Unit, stream: u32, since: u64) {
        let mut w = unit.watcher();
        (w.count, w.since, w.replaying) = (stream, since, true);
    }

    fn live() -> Apply {
        Apply {
            phase: EnginePhase::Live,
            ..Apply::new()
        }
    }

    fn live_only(heard: &[Option<(EnginePhase, u64)>]) -> bool {
        heard
            .iter()
            .all(|h| h.is_none_or(|(phase, _)| phase == EnginePhase::Live))
    }

    fn old_folder(path: &Path) {
        fs::File::open(path)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - Duration::from_secs(1000))
            .unwrap();
    }

    fn finish_recovery(shared: &Shared, unit: &Unit, a: &mut Apply) {
        let turns = a
            .recovery
            .as_ref()
            .map_or(0, |r| r.dirs.len().div_ceil(RECOVERY_BATCH));
        for _ in 0..turns {
            step(shared, unit, a, vec![], Instant::now());
        }
        assert!(a.recovery.is_none());
    }

    fn nested_disk(shared: &Shared, parent: &Unit, root: PathBuf) -> Arc<Unit> {
        let disk = Arc::new(Unit::new(
            root,
            Some("dupearly".to_owned()),
            parent.file.with_file_name("volume-dupearly.index"),
            (Vec::new(), Vec::new()),
            crawl::Pool::new(2).unwrap(),
            std::sync::mpsc::channel().0,
            Arc::default(),
        ));
        shared.units.write().unwrap().push(disk.clone());
        unit::purge(parent, &disk.root, &disk.stop);
        let crawl = crawl::scan_path(&disk.pool, &disk.root, &disk.skip, &disk.stop);
        let index = Index::build(crawl, disk.root.clone(), &[], 1000, engine::now_secs()).unwrap();
        disk.install(shared, index, EnginePhase::Ready);
        disk
    }

    #[test]
    fn a_change_during_the_launch_replay_moves_the_count() {
        let tree = TempTree::new("apply-replaycount");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = Apply::new();
        restarted(&unit, 1, 1000);
        let shown = unit.status().1;
        heard(&rx);
        fs::write(tree.0.join("Sub/zyqreplay.txt"), b"").unwrap();
        let sub = format!("{}/Sub", tree.real());
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&sub, 0, 2000, 1)],
            Instant::now(),
        );
        assert_eq!(
            names(&unit, "zyqreplay"),
            [("zyqreplay.txt".to_owned(), sub)]
        );
        assert_eq!(
            unit.status().1,
            shown + 1,
            "Files: N stayed still during the launch replay"
        );
        assert!(
            heard(&rx).contains(&Some((EnginePhase::Ready, shown + 1))),
            "no new count was reported during the launch replay"
        );
    }

    #[test]
    fn the_replay_after_a_resume_moves_the_count_at_most_every_100_ms() {
        let tree = TempTree::new("apply-resumecount");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = Apply::new();
        let (root, sub) = (tree.real(), format!("{}/Sub", tree.real()));
        shared.settings.paused.store(true, Ordering::Relaxed);
        unit.watch(1000).unwrap();
        let shown = unit.status().1;
        heard(&rx);
        let t = Instant::now();
        fs::write(tree.0.join("Sub/zyqheld.txt"), b"").unwrap();
        step(&shared, &unit, &mut a, vec![ev(&sub, 0, 2000, 1)], t);
        assert_eq!(unit.status().1, shown, "the count moved during the pause");
        assert!(heard(&rx).is_empty(), "a report went out during the pause");
        shared.settings.paused.store(false, Ordering::Relaxed);
        let from = unit.resume_from().unwrap();
        restarted(&unit, 1, from);
        step(&shared, &unit, &mut a, vec![ev(&sub, 0, 2000, 1)], t);
        assert_eq!(
            heard(&rx),
            [None, Some((EnginePhase::Ready, shown + 1))],
            "Files: N stayed still during the replay after Resume"
        );
        fs::write(tree.0.join("Sub/zyqsoon.txt"), b"").unwrap();
        let soon = t + REPLAY_REPORT / 2;
        step(&shared, &unit, &mut a, vec![ev(&sub, 0, 2001, 1)], soon);
        assert_eq!(unit.status().1, shown + 2);
        assert_eq!(
            heard(&rx),
            [None],
            "two count reports went out within 100 ms of the replay"
        );
        fs::write(tree.0.join("Sub/zyqlater.txt"), b"").unwrap();
        let later = t + REPLAY_REPORT;
        step(&shared, &unit, &mut a, vec![ev(&sub, 0, 2002, 1)], later);
        assert_eq!(heard(&rx), [None, Some((EnginePhase::Ready, shown + 3))]);
        let done = vec![ev(&root, HISTORY_DONE, 2003, 1)];
        step(&shared, &unit, &mut a, done, later);
        assert_eq!(
            heard(&rx),
            [Some((EnginePhase::Live, shown + 3))],
            "the end of the replay did not report the last count"
        );
    }

    #[test]
    fn a_replay_keeps_the_engine_settling_until_its_history_ends() {
        let tree = TempTree::new("apply-replaysettles");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        assert!(!shared.settling(), "a bench unit is Ready");
        restarted(&unit, 1, 1000);
        let shown = unit.status().1;
        heard(&rx);
        fs::write(tree.0.join("zyqreplayed.txt"), b"").unwrap();
        step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now);
        assert!(heard(&rx).contains(&Some((EnginePhase::Ready, shown + 1))));
        assert!(
            shared.settling(),
            "a count report during the replay let an idle Wherever quit"
        );
        shared.settings.paused.store(true, Ordering::Relaxed);
        assert!(!shared.settling(), "a paused replay kept Wherever running");
        shared.settings.paused.store(false, Ordering::Relaxed);
        unit.set_phase(EnginePhase::Failed);
        assert!(
            !shared.settling(),
            "a failed unit's replay kept Wherever running"
        );
        unit.set_phase(EnginePhase::Ready);
        let done = vec![ev(&root, HISTORY_DONE, 1002, 1)];
        step(&shared, &unit, &mut a, done, now);
        assert_eq!(heard(&rx), [Some((EnginePhase::Live, shown + 1))]);
        assert!(
            !shared.settling(),
            "Wherever kept running after the replay ended"
        );
    }

    #[test]
    fn a_fetched_event_cannot_restore_a_new_disks_files() {
        for recursive in [false, true] {
            let tree = TempTree::new("apply-disk-handoff");
            let ancestor = PathBuf::from(tree.real()).join("Container");
            let root = ancestor.join("Drive");
            fs::create_dir_all(&root).unwrap();
            fs::write(root.join("early.txt"), b"").unwrap();
            let (shared, parent, _rx) = bench(config(&tree));
            let (reached, waiting) = std::sync::mpsc::channel();
            let (release, held) = std::sync::mpsc::channel();
            std::thread::scope(|scope| {
                let updater = scope.spawn(|| {
                    let mut a = live();
                    a.fetched = Some(Box::new(move || {
                        reached.send(()).unwrap();
                        held.recv_timeout(Duration::from_secs(10)).unwrap();
                    }));
                    let path = if recursive { &ancestor } else { &root };
                    step(
                        &shared,
                        &parent,
                        &mut a,
                        vec![ev(
                            path.to_str().unwrap(),
                            if recursive { MUST_SCAN_SUBDIRS } else { 0 },
                            1001,
                            1,
                        )],
                        Instant::now(),
                    );
                });
                waiting.recv_timeout(Duration::from_secs(10)).unwrap();
                let disk = nested_disk(&shared, &parent, root.clone());
                assert!(names(&parent, "early").is_empty());
                release.send(()).unwrap();
                updater.join().unwrap();
                let mut rows = names(&parent, "early");
                rows.extend(names(&disk, "early"));
                assert_eq!(
                    rows,
                    [("early.txt".to_owned(), root.to_str().unwrap().to_owned())],
                    "recursive: {recursive}"
                );
            });
        }
    }

    #[test]
    fn installing_a_crawl_cannot_restore_a_new_disks_files() {
        let tree = TempTree::new("install-disk-handoff");
        let root = PathBuf::from(tree.real()).join("Drive");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("early.txt"), b"").unwrap();
        let (shared, parent, _rx) = bench(config(&tree));
        let index = Index::build(
            parent.read(Live::to_crawl).unwrap(),
            parent.root.clone(),
            &[],
            1000,
            engine::now_secs(),
        )
        .unwrap();
        let disk = nested_disk(&shared, &parent, root.clone());
        parent.install(&shared, index, EnginePhase::Ready);
        let mut rows = names(&parent, "early");
        rows.extend(names(&disk, "early"));
        assert_eq!(
            rows,
            [("early.txt".to_owned(), root.to_str().unwrap().to_owned())]
        );
        assert_eq!(parent.status().1, parent.read(Live::entries).unwrap());
    }

    #[test]
    fn a_disk_publishes_only_after_pre_purge_searches_finish() {
        let tree = TempTree::new("publish-disk-handoff");
        let root = PathBuf::from(tree.real()).join("Drive");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("early.txt"), b"").unwrap();
        let (shared, parent, rx) = bench(config(&tree));
        let (events, batches) = std::sync::mpsc::channel();
        let disk = Arc::new(Unit::new(
            root.clone(),
            Some("dupearly".to_owned()),
            parent.file.with_file_name("volume-dupearly.index"),
            (Vec::new(), Vec::new()),
            crawl::Pool::new(2).unwrap(),
            events.clone(),
            Arc::default(),
        ));
        shared.units.write().unwrap().push(disk.clone());
        let units = shared.units();
        let mut rows = names(&parent, "early");
        std::thread::scope(|scope| {
            let mounting = scope.spawn({
                let (shared, disk) = (&shared, &disk);
                move || {
                    unit::mount(shared, disk, &batches);
                }
            });
            loop {
                if let Heard::Changed(_) = rx.recv_timeout(Duration::from_secs(10)).unwrap() {
                    break;
                }
            }
            let deadline = Instant::now() + Duration::from_secs(1);
            let mut premature = false;
            while let Ok(event) =
                rx.recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                match event {
                    Heard::State(s) if s.phase == EnginePhase::Ready => {
                        premature = true;
                        break;
                    }
                    Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                    _ => {}
                }
            }
            if premature {
                rows.extend(names(&disk, "early"));
            }
            drop(units);
            if !premature {
                loop {
                    match rx.recv_timeout(Duration::from_secs(10)).unwrap() {
                        Heard::State(s) if s.phase == EnginePhase::Ready => break,
                        Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                        _ => {}
                    }
                }
            }
            disk.stop.store(true, Ordering::Relaxed);
            disk.watcher().close();
            let _ = events.send(Vec::new());
            mounting.join().unwrap();
            assert_eq!(
                rows,
                [("early.txt".to_owned(), root.to_str().unwrap().to_owned())]
            );
            assert!(!premature, "the disk published during a pre-purge search");
            assert_eq!(names(&disk, "early"), rows);
        });
    }

    #[test]
    fn lost_history_refreshes_a_file_in_an_old_folder() {
        let tree = TempTree::new("recover-size");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        fs::write(tree.0.join("Sub/DELTA.Txt"), b"grown").unwrap();
        fs::File::open(tree.0.join("Sub/DELTA.Txt"))
            .unwrap()
            .set_modified(std::time::SystemTime::now() - Duration::from_secs(500))
            .unwrap();
        old_folder(&tree.0.join("Sub"));
        old_folder(&tree.0);
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(
                &tree.real(),
                MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
                1001,
                1,
            )],
            Instant::now(),
        );
        finish_recovery(&shared, &unit, &mut a);
        let row = unit
            .read(|l| l.find("delta", || false).unwrap().row(0).unwrap())
            .unwrap();
        assert_eq!(row.size, 5);
        assert_eq!(
            row.modified,
            fs::metadata(tree.0.join("Sub/DELTA.Txt")).unwrap().mtime()
        );
        assert!(live_only(&heard(&rx)));
    }

    #[test]
    fn lost_history_refreshes_a_files_hidden_flag() {
        use std::os::unix::ffi::OsStrExt;
        let tree = TempTree::new("recover-hidden");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = live();
        let file =
            std::ffi::CString::new(tree.0.join("Sub/DELTA.Txt").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::chflags(file.as_ptr(), libc::UF_HIDDEN) }, 0);
        old_folder(&tree.0.join("Sub"));
        old_folder(&tree.0);
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(
                &tree.real(),
                MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
                1001,
                1,
            )],
            Instant::now(),
        );
        finish_recovery(&shared, &unit, &mut a);
        assert_eq!(names(&unit, "delta").len(), 1);
        assert!(names(&unit, "delta hidden:no").is_empty());
    }

    #[test]
    fn live_events_apply_before_recovery_finishes() {
        let tree = TempTree::new("recover-events");
        for i in 0..RECOVERY_BATCH * 2 {
            fs::create_dir(tree.0.join(format!("Folder{i}"))).unwrap();
        }
        let (shared, unit, _rx) = bench(config(&tree));
        for i in 0..RECOVERY_BATCH * 2 {
            old_folder(&tree.0.join(format!("Folder{i}")));
        }
        old_folder(&tree.0.join("Sub"));
        old_folder(&tree.0);
        let synced = engine::now_secs() - 10;
        unit.write(|l| l.synced_at = synced);
        let mut a = live();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(
                &tree.real(),
                MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
                1001,
                1,
            )],
            Instant::now(),
        );
        let started = a.recovery.as_ref().unwrap().started;
        let total = a.recovery.as_ref().unwrap().dirs.len();
        step(&shared, &unit, &mut a, vec![], Instant::now());
        let remaining = a.recovery.as_ref().unwrap().dirs.len();
        assert_eq!(total - remaining, RECOVERY_BATCH);
        fs::write(tree.0.join("Sub/during.txt"), b"fresh").unwrap();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&format!("{}/Sub", tree.real()), 0, 1002, 1)],
            Instant::now(),
        );
        assert_eq!(a.recovery.as_ref().unwrap().dirs.len(), remaining);
        assert_eq!(
            names(&unit, "during"),
            [("during.txt".to_owned(), format!("{}/Sub", tree.real()))]
        );
        assert_eq!(unit.read(|l| l.synced_at), Some(synced));
        finish_recovery(&shared, &unit, &mut a);
        assert_eq!(unit.read(|l| l.synced_at), Some(started));
    }

    #[test]
    fn replaced_stream_events_do_not_advance_the_saved_id() {
        let tree = TempTree::new("recover-oldstream");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = live();
        let t = Instant::now();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&tree.real(), DROP, 1001, 1)],
            t,
        );
        assert_eq!(
            step(&shared, &unit, &mut a, vec![], t + REPLAY_QUIET),
            Some(1000)
        );
        restarted(&unit, 2, 1000);
        fs::write(tree.0.join("Sub/late.txt"), b"").unwrap();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&format!("{}/Sub", tree.real()), 0, 2000, 1)],
            t + Duration::from_secs(3),
        );
        assert_eq!(unit.read(|l| l.event_id), Some(1000));
        assert_eq!(
            names(&unit, "late"),
            [("late.txt".to_owned(), format!("{}/Sub", tree.real()))]
        );
        assert_eq!(fold(&shared, &unit, &unit).unwrap().event_id(), 1000);
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&tree.real(), EVENT_IDS_WRAPPED, 5, 1)],
            t + Duration::from_secs(4),
        );
        assert_eq!(unit.read(|l| l.event_id), Some(1000));
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&tree.real(), HISTORY_DONE, 2001, 2)],
            t + Duration::from_secs(5),
        );
        assert_eq!(unit.read(|l| l.event_id), Some(2001));
    }

    #[test]
    fn recovery_checks_the_root_and_overlay_folders() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("recover-overlay");
        let mut a = live();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&shut, 0, 1001, 1)],
            Instant::now(),
        );
        let disk = unit.disk(&unit.skip);
        assert_eq!(
            unit.read(|l| l.fetch_changed(tree.real().as_bytes(), &disk).is_none()),
            Some(true)
        );
        fs::write(tree.0.join("Shut/inside.txt"), b"changed").unwrap();
        old_folder(&tree.0.join("Shut"));
        fs::create_dir(tree.0.join("Added")).unwrap();
        fs::write(tree.0.join("Added/overlay.txt"), b"").unwrap();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&tree.real(), 0, 1001, 1)],
            Instant::now(),
        );
        fs::write(tree.0.join("Added/overlay.txt"), b"grown").unwrap();
        fs::write(tree.0.join("Alpha.TXT"), b"larger").unwrap();
        old_folder(&tree.0.join("Added"));
        old_folder(&tree.0.join("Sub"));
        old_folder(&tree.0);
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(
                &tree.real(),
                MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
                1002,
                1,
            )],
            Instant::now(),
        );
        finish_recovery(&shared, &unit, &mut a);
        for (query, size) in [("overlay", 5), ("alpha", 6), ("inside", 7)] {
            assert_eq!(
                unit.read(|l| l.find(query, || false).unwrap().row(0).unwrap().size),
                Some(size)
            );
        }
    }

    #[test]
    fn an_interrupted_recovery_keeps_its_saved_checkpoint() {
        let tree = TempTree::new("recover-stop");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = live();
        unit.relist.store(true, Ordering::Relaxed);
        fs::write(tree.0.join("Sub/DELTA.Txt"), b"grown").unwrap();
        old_folder(&tree.0.join("Sub"));
        old_folder(&tree.0);
        let synced = engine::now_secs() - 10;
        unit.write(|l| l.synced_at = synced);
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(
                &tree.real(),
                MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
                1001,
                1,
            )],
            Instant::now(),
        );
        let saved = fold(&shared, &unit, &unit).unwrap();
        assert_eq!(saved.os_build(), [0; crate::index::OS_BUILD_BYTES]);
        assert!(unit.relist.load(Ordering::Relaxed));
        assert_eq!(saved.event_id(), 1000);
        assert_eq!(saved.synced_at(), synced);
        let remaining = a.recovery.as_ref().unwrap().dirs.len();
        unit.stop.store(true, Ordering::Relaxed);
        step(&shared, &unit, &mut a, vec![], Instant::now());
        assert_eq!(a.recovery.as_ref().unwrap().dirs.len(), remaining);
        assert_eq!(unit.read(|l| l.synced_at), Some(synced));
        assert_eq!(
            unit.read(|l| l.find("delta", || false).unwrap().row(0).unwrap().size),
            Some(0)
        );
        unit.stop.store(false, Ordering::Relaxed);
        finish_recovery(&shared, &unit, &mut a);
        assert!(a.checked);
        assert!(!unit.relist.load(Ordering::Relaxed));
        let saved = fold(&shared, &unit, &unit).unwrap();
        assert_eq!(saved.event_id(), 1001);
        assert_ne!(saved.os_build()[0], 0);
    }

    #[test]
    fn unchanged_recovery_listings_need_no_diff() {
        let tree = TempTree::new("recover-unchanged");
        let (_shared, unit, _rx) = bench(config(&tree));
        let disk = unit.disk(&unit.skip);
        for path in [tree.real(), format!("{}/Sub", tree.real())] {
            assert_eq!(
                unit.read(|l| l.fetch_changed(path.as_bytes(), &disk).is_none()),
                Some(true)
            );
        }
        fs::remove_file(tree.0.join("Sub/DELTA.Txt")).unwrap();
        let sub = format!("{}/Sub", tree.real());
        let fetched = unit
            .read(|l| l.fetch_changed(sub.as_bytes(), &disk))
            .flatten()
            .unwrap();
        unit.write(|l| l.apply(fetched, &disk));
        assert!(names(&unit, "delta").is_empty());
        assert_eq!(
            unit.read(|l| l.fetch_changed(sub.as_bytes(), &disk).is_none()),
            Some(true)
        );
    }

    #[test]
    fn must_scan_subdirs_rescans_the_subtree() {
        let tree = TempTree::new("apply-scan");
        fs::create_dir(tree.0.join("Sub/Inner")).unwrap();
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        let sub = format!("{root}/Sub");
        fs::create_dir(tree.0.join("Sub/Inner/Deep")).unwrap();
        fs::write(tree.0.join("Sub/Inner/Deep/deep.txt"), b"").unwrap();
        let before = unit.read(Live::entries).unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&sub, 0, 1001, 1)], now),
            None
        );
        assert!(names(&unit, "deep").is_empty());
        assert!(heard(&rx).is_empty());
        let scan = vec![ev(&sub, MUST_SCAN_SUBDIRS, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, scan, now), None);
        assert_eq!(
            names(&unit, "deep"),
            [
                ("Deep".to_owned(), format!("{sub}/Inner")),
                ("deep.txt".to_owned(), format!("{sub}/Inner/Deep")),
            ]
        );
        assert_eq!(names(&unit, "delta"), [("DELTA.Txt".to_owned(), sub)]);
        assert_eq!(heard(&rx), [None, Some((EnginePhase::Live, before + 2))]);
        assert_eq!(unit.read(|l| l.event_id), Some(1002));
    }

    #[test]
    fn a_user_drop_replays_three_times_then_relists() {
        let tree = TempTree::new("apply-userdrop");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let (root, t) = (tree.real(), Instant::now());
        let sub = format!("{root}/Sub");
        let at = |s| t + Duration::from_secs(s);
        assert_eq!(
            step(
                &shared,
                &unit,
                &mut a,
                vec![ev(&root, DROP, 1001, 1)],
                at(0)
            ),
            None
        );
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(1)), None);
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(2)), Some(1000));
        restarted(&unit, 2, 900);
        assert_eq!(
            step(
                &shared,
                &unit,
                &mut a,
                vec![ev(&root, DROP, 1002, 1)],
                at(3)
            ),
            None
        );
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(6)), None);
        let batch = vec![ev(&sub, 0, 1005, 2), ev(&root, DROP, 1006, 2)];
        assert_eq!(step(&shared, &unit, &mut a, batch, at(6)), None);
        assert_eq!(unit.read(|l| l.event_id), Some(900));
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(8)), Some(900));
        restarted(&unit, 3, 900);
        assert_eq!(
            step(
                &shared,
                &unit,
                &mut a,
                vec![ev(&root, DROP, 1007, 3)],
                at(9)
            ),
            None
        );
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(11)), Some(900));
        restarted(&unit, 4, 900);
        fs::write(tree.0.join("Sub/relisted.txt"), b"").unwrap();
        assert_eq!(
            step(
                &shared,
                &unit,
                &mut a,
                vec![ev(&root, DROP, 1008, 4)],
                at(12)
            ),
            None
        );
        assert!(names(&unit, "relisted").is_empty());
        assert_eq!(step(&shared, &unit, &mut a, vec![], at(14)), None);
        assert_eq!(names(&unit, "relisted"), [("relisted.txt".to_owned(), sub)]);
        assert!(live_only(&heard(&rx)));
    }

    #[test]
    fn a_quit_owes_a_save_only_for_a_stale_index_that_is_old_or_far_behind() {
        let (fresh, old) = (
            Some(COMPACT_EVERY - Duration::from_secs(1)),
            Some(COMPACT_EVERY + Duration::from_secs(1)),
        );
        assert_eq!(COMPACT_EVERY, Duration::from_secs(12 * 60 * 60));
        assert!(save_owed(true, false, old, 0));
        assert!(save_owed(true, false, None, 0));
        assert!(save_owed(true, false, fresh, COMPACT_PENDING + 1));
        assert!(!save_owed(true, false, fresh, COMPACT_PENDING));
        assert!(!save_owed(false, false, old, COMPACT_PENDING + 1));
        assert!(!save_owed(false, false, None, 0));
        assert!(save_owed(true, true, fresh, 0));
        assert!(!save_owed(false, true, fresh, 0));
    }

    #[test]
    fn a_quit_saves_a_fresh_file_when_too_many_changes_wait() {
        let tree = TempTree::new("flush-pending");
        let (shared, unit, _rx) = bench(config(&tree));
        compact(&shared, &unit);
        let before = fs::metadata(&unit.file).unwrap().ino();
        let sub = format!("{}/Sub", tree.real());
        unit.write(|l| {
            l.event_id += 1;
            let attrs = (0..)
                .map(|i| l.attrs(i))
                .find(|a| a.kind != EngineKind::Folder)
                .unwrap();
            for i in 0..COMPACT_PENDING {
                l.over.insert(format!("{sub}/zyq{i}").into_bytes(), attrs);
            }
        });
        assert!(unit.read(Live::pending).unwrap() <= COMPACT_PENDING);
        flush(&shared, &unit);
        assert_eq!(
            fs::metadata(&unit.file).unwrap().ino(),
            before,
            "a quit saved at the limit, not over it"
        );
        unit.write(|l| {
            let attrs = (0..)
                .map(|i| l.attrs(i))
                .find(|a| a.kind != EngineKind::Folder)
                .unwrap();
            l.over.insert(format!("{sub}/zyqlast").into_bytes(), attrs);
        });
        assert!(unit.read(Live::pending).unwrap() > COMPACT_PENDING);
        unit.set_phase(EnginePhase::Crawling);
        flush(&shared, &unit);
        assert_eq!(
            fs::metadata(&unit.file).unwrap().ino(),
            before,
            "a quit during a rebuild saved the index the rebuild replaces"
        );
        unit.set_phase(EnginePhase::Ready);
        flush(&shared, &unit);
        assert_ne!(fs::metadata(&unit.file).unwrap().ino(), before);
    }

    #[test]
    fn the_engine_settles_only_when_no_phase_or_re_read_is_running() {
        let tree = TempTree::new("settling");
        let (shared, unit, _rx) = bench(config(&tree));
        assert!(!shared.settling(), "a bench unit is Ready");
        for phase in [
            EnginePhase::Loading,
            EnginePhase::Crawling,
            EnginePhase::Finishing,
        ] {
            unit.set_phase(phase);
            assert!(shared.settling(), "{phase:?}");
        }
        for phase in [EnginePhase::Ready, EnginePhase::Live, EnginePhase::Failed] {
            unit.set_phase(phase);
            assert!(!shared.settling(), "{phase:?}");
        }
        unit.set_phase(EnginePhase::Ready);
        for flag in [&unit.relist, &unit.rereading] {
            flag.store(true, Ordering::Relaxed);
            assert!(shared.settling());
            flag.store(false, Ordering::Relaxed);
            assert!(!shared.settling());
        }
        shared.settings.paused.store(true, Ordering::Relaxed);
        for flag in [&unit.relist, &unit.rereading] {
            flag.store(true, Ordering::Relaxed);
            assert!(
                !shared.settling(),
                "a re-read the pause holds kept Wherever running"
            );
            flag.store(false, Ordering::Relaxed);
        }
        shared.settings.paused.store(false, Ordering::Relaxed);
        unit.set_owed(Some((900, 1)));
        assert!(shared.settling(), "a replay owes its check");
        shared.settings.paused.store(true, Ordering::Relaxed);
        assert!(!shared.settling(), "a pause holds that check for ever");
        shared.settings.paused.store(false, Ordering::Relaxed);
        unit.live_off(&shared, "test");
        assert!(!shared.settling(), "no thread will finish that check");
    }

    fn until_settled_is_reported(shared: &Shared, unit: &Unit, rx: &Receiver<Heard>) {
        loop {
            match rx.recv_timeout(Duration::from_secs(10)).unwrap() {
                Heard::State(_) => break,
                Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        assert!(
            !shared.settling(),
            "the report came before the re-read ended"
        );
        unit.stop.store(true, Ordering::Relaxed);
    }

    #[test]
    fn a_boot_re_read_settles_after_its_save_and_reports_it() {
        let tree = TempTree::new("settle-boot");
        let (shared, unit, rx) = bench(config(&tree));
        unit.relist.store(true, Ordering::Relaxed);
        assert!(!unit.file.exists());
        assert!(shared.settling());
        let (events, batches) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let running = scope.spawn({
                let (shared, unit) = (&shared, &unit);
                move || run(shared, unit, &batches)
            });
            until_settled_is_reported(&shared, &unit, &rx);
            assert!(
                unit.file.exists(),
                "Wherever could quit with the new build unsaved, so every start re-reads"
            );
            let _ = events.send(Vec::new());
            running.join().unwrap();
        });
    }

    #[test]
    fn lost_history_settles_when_its_recovery_ends_and_reports_it() {
        let tree = TempTree::new("settle-lost");
        let (shared, unit, rx) = bench(config(&tree));
        let (events, batches) = std::sync::mpsc::channel();
        let lost = ev(&tree.real(), MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1001, 1);
        events.send(vec![lost]).unwrap();
        std::thread::scope(|scope| {
            let running = scope.spawn({
                let (shared, unit) = (&shared, &unit);
                move || run(shared, unit, &batches)
            });
            until_settled_is_reported(&shared, &unit, &rx);
            assert_eq!(unit.read(|l| l.recovery_from), Some(None));
            assert!(!unit.rereading.load(Ordering::Relaxed));
            let _ = events.send(Vec::new());
            running.join().unwrap();
        });
        assert_eq!(unit.relists.load(Ordering::Relaxed), 1);
    }

    fn streams(unit: &Unit) -> (u32, bool) {
        let w = unit.watcher();
        (w.count, w.running())
    }

    #[test]
    fn a_gap_restart_during_a_pause_starts_no_stream_and_resume_uses_its_id() {
        let tree = TempTree::new("apply-pausedgap");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let (root, t) = (tree.real(), Instant::now());
        step(&shared, &unit, &mut a, vec![ev(&root, DROP, 1001, 1)], t);
        shared.settings.paused.store(true, Ordering::Relaxed);
        let from = step(&shared, &unit, &mut a, vec![], t + REPLAY_QUIET).unwrap();
        assert_eq!(from, 1000);
        rewatch(&shared, &unit, &mut a, from);
        assert_eq!(
            streams(&unit),
            (1, false),
            "a gap restart started a stream during the pause"
        );
        assert_eq!(unit.resume_from(), None, "a resume ran during the pause");
        shared.settings.paused.store(false, Ordering::Relaxed);
        assert_eq!(
            unit.resume_from(),
            Some(from),
            "resume forgot the id the gap restart remembered"
        );
        assert_eq!(unit.resume_from(), None, "one pause resumed twice");
        let now = unit.watcher().current_id().unwrap();
        unit.watch(now).unwrap();
        assert_eq!(streams(&unit), (2, true), "resume did not start one stream");
        assert_eq!(unit.relists.load(Ordering::Relaxed), 0);
        heard(&rx);
    }

    #[test]
    fn a_batch_from_the_stopped_stream_waits_for_resume() {
        let tree = TempTree::new("apply-pausedbatch");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let root = tree.real();
        let now = unit.watcher().current_id().unwrap();
        unit.watch(now).unwrap();
        shared.settings.paused.store(true, Ordering::Relaxed);
        unit.watcher().follow_switch();
        assert_eq!(
            streams(&unit),
            (2, false),
            "the pause left the stream running"
        );
        fs::write(tree.0.join("Sub/queued.txt"), b"").unwrap();
        let sub = format!("{root}/Sub");
        heard(&rx);
        let shown = unit.status().1;
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&sub, 0, 5000, 2)],
            Instant::now(),
        );
        assert!(
            names(&unit, "queued").is_empty(),
            "a batch delivered before the park reached the index during the pause"
        );
        assert_eq!(unit.status().1, shown, "the count moved during the pause");
        assert!(
            heard(&rx).iter().all(Option::is_none),
            "a new count was reported during the pause"
        );
        assert_eq!(
            unit.read(|l| l.event_id),
            Some(1000),
            "a dropped batch moved the id, so the replay would skip it"
        );
        shared.settings.paused.store(false, Ordering::Relaxed);
        let from = unit.resume_from().unwrap();
        unit.watch(from).unwrap();
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&sub, 0, 5000, 3)],
            Instant::now(),
        );
        assert_eq!(names(&unit, "queued"), [("queued.txt".to_owned(), sub)]);
        heard(&rx);
    }

    #[test]
    fn a_batch_before_the_park_still_applies_and_moves_the_id() {
        let tree = TempTree::new("apply-prepark");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let root = tree.real();
        let now = unit.watcher().current_id().unwrap();
        unit.watch(now).unwrap();
        shared.settings.paused.store(true, Ordering::Relaxed);
        fs::write(tree.0.join("Sub/early.txt"), b"").unwrap();
        let sub = format!("{root}/Sub");
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&sub, 0, 5000, 2)],
            Instant::now(),
        );
        assert_eq!(names(&unit, "early"), [("early.txt".to_owned(), sub)]);
        assert_eq!(
            unit.read(|l| l.event_id),
            Some(5000),
            "a batch from the running stream was lost in the gap before the park"
        );
        heard(&rx);
    }

    #[test]
    fn a_re_read_during_a_pause_waits_for_resume() {
        let tree = TempTree::new("apply-pausedreread");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        fs::write(tree.0.join("Sub/reread.txt"), b"").unwrap();
        let shown = unit.status().1;
        heard(&rx);
        shared.settings.paused.store(true, Ordering::Relaxed);
        a.relist = true;
        for _ in 0..3 {
            step(&shared, &unit, &mut a, vec![], Instant::now());
        }
        assert!(
            names(&unit, "reread").is_empty(),
            "a re-read ran during the pause"
        );
        assert!(a.relist, "the pause dropped the re-read it holds");
        assert!(a.recovery.is_none());
        assert_eq!(unit.status().1, shown, "the count moved during the pause");
        assert!(
            heard(&rx).iter().all(Option::is_none),
            "a new count was reported during the pause"
        );
        assert_eq!(unit.relists.load(Ordering::Relaxed), 0);
        shared.settings.paused.store(false, Ordering::Relaxed);
        for _ in 0..100 {
            step(&shared, &unit, &mut a, vec![], Instant::now());
            if a.recovery.is_none() && !a.relist {
                break;
            }
        }
        assert!(
            a.recovery.is_none() && !a.relist,
            "resume never finished the re-read"
        );
        assert_eq!(unit.relists.load(Ordering::Relaxed), 1);
        assert_eq!(
            names(&unit, "reread"),
            [("reread.txt".to_owned(), format!("{}/Sub", tree.real()))]
        );
        assert_eq!(
            unit.status().1,
            shown + 1,
            "resume did not catch the count up"
        );
        heard(&rx);
    }

    #[test]
    fn a_replay_held_by_a_pause_stays_owed_until_its_history_ends() {
        let tree = TempTree::new("apply-pausedowed");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        unit.set_owed(Some((900, 1)));
        shared.settings.paused.store(true, Ordering::Relaxed);
        unit.watch(900).unwrap();
        step(&shared, &unit, &mut a, vec![], Instant::now());
        assert_eq!(
            unit.owed(),
            Some((900, 1)),
            "the check pass ran before the replay it owes"
        );
        assert_eq!(unit.read(|l| unit.kept(l).0), Some(900));
        shared.settings.paused.store(false, Ordering::Relaxed);
        assert_eq!(unit.resume_from(), Some(900));
        heard(&rx);
    }

    #[test]
    fn a_failed_restart_keeps_the_gap_and_relists() {
        let tree = TempTree::new("apply-failedrestart");
        for i in 0..RECOVERY_BATCH * 2 {
            fs::create_dir(tree.0.join(format!("Folder{i}"))).unwrap();
        }
        let (shared, unit, rx) = bench(config(&tree));
        for i in 0..RECOVERY_BATCH * 2 {
            old_folder(&tree.0.join(format!("Folder{i}")));
        }
        old_folder(&tree.0);
        let mut a = live();
        let (root, t) = (tree.real(), Instant::now());
        step(&shared, &unit, &mut a, vec![ev(&root, DROP, 1001, 1)], t);
        assert_eq!(
            step(&shared, &unit, &mut a, vec![], t + REPLAY_QUIET),
            Some(1000)
        );
        fs::write(tree.0.join("Sub/lost.txt"), b"").unwrap();
        unit.watcher().close();
        rewatch(&shared, &unit, &mut a, 1000);
        assert_eq!(
            names(&unit, "lost"),
            [("lost.txt".to_owned(), format!("{root}/Sub"))]
        );
        assert!(a.recovery.is_some());
        assert_eq!(
            unit.read(|l| (l.event_id, l.recovery_from)),
            Some((1000, Some(1000)))
        );
        step(
            &shared,
            &unit,
            &mut a,
            vec![ev(&root, 0, 2000, 1)],
            t + Duration::from_secs(3),
        );
        assert_eq!(fold(&shared, &unit, &unit).unwrap().event_id(), 1000);
        finish_recovery(&shared, &unit, &mut a);
        assert_eq!(fold(&shared, &unit, &unit).unwrap().event_id(), 2000);
        let faults: Vec<_> = rx
            .try_iter()
            .filter_map(|e| match e {
                Heard::Fault(message) => Some(message),
                _ => None,
            })
            .collect();
        assert_eq!(faults.len(), 1, "{faults:?}");
        assert!(faults[0].contains("relisting"), "{faults:?}");
    }

    #[test]
    fn a_kernel_drop_lost_history_or_wrapped_ids_relist() {
        let tree = TempTree::new("apply-kerneldrop");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        let sub = format!("{root}/Sub");
        let above = Path::new(&root).parent().unwrap().to_str().unwrap();
        let cases = [
            (
                "kernel",
                ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1001, 1),
            ),
            ("history", ev(&root, MUST_SCAN_SUBDIRS, 1002, 1)),
            (
                "above",
                ev(above, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1003, 1),
            ),
            ("wrapped", ev(&root, EVENT_IDS_WRAPPED, 5, 1)),
        ];
        for (name, e) in cases {
            let file = format!("{name}.txt");
            fs::write(tree.0.join("Sub").join(&file), b"").unwrap();
            assert_eq!(step(&shared, &unit, &mut a, vec![e], now), None);
            assert_eq!(names(&unit, name), [(file, sub.clone())], "{name}");
        }
        assert_eq!(unit.read(|l| l.event_id), Some(5));
        assert!(live_only(&heard(&rx)));
    }

    #[test]
    fn a_relist_never_lists_a_folder_mounted_after_it_was_listed() {
        let tree = TempTree::new("apply-mounted");
        let (shared, unit, _rx) = bench(config(&tree));
        let (root, now) = (tree.real(), Instant::now());
        fs::create_dir(tree.0.join("Mnt")).unwrap();
        let mut a = Apply {
            mounted: |p| p.ends_with("Mnt"),
            ..live()
        };
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now),
            None
        );
        assert_eq!(names(&unit, "mnt"), [("Mnt".to_owned(), root.clone())]);
        fs::write(tree.0.join("Mnt/inside.txt"), b"").unwrap();
        let kernel = vec![ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, kernel, now), None);
        assert!(names(&unit, "inside").is_empty());
        a.mounted = |_| false;
        let kernel = vec![ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1003, 1)];
        assert_eq!(step(&shared, &unit, &mut a, kernel, now), None);
        assert_eq!(
            names(&unit, "inside"),
            [("inside.txt".to_owned(), format!("{root}/Mnt"))]
        );
    }

    #[test]
    fn history_done_makes_the_engine_live_once() {
        let tree = TempTree::new("apply-historydone");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        restarted(&unit, 1, 1000);
        let entries = unit.read(Live::entries).unwrap();
        fs::write(tree.0.join("early.txt"), b"").unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now),
            None
        );
        assert_eq!(heard(&rx), [None, Some((EnginePhase::Ready, entries + 1))]);
        assert!(unit.watcher().replaying);
        let done = vec![ev(&root, HISTORY_DONE, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, done, now), None);
        assert_eq!(heard(&rx), [Some((EnginePhase::Live, entries + 1))]);
        assert!(!unit.watcher().replaying);
        let again = vec![ev(&root, HISTORY_DONE, 1003, 1)];
        assert_eq!(step(&shared, &unit, &mut a, again, now), None);
        assert!(heard(&rx).is_empty());
    }

    fn dev_of(tree: &TempTree) -> libc::dev_t {
        fs::metadata(&tree.0).unwrap().dev() as libc::dev_t
    }

    fn replaying_since(unit: &Unit, synced: u64) {
        restarted(unit, 1, 1000);
        unit.set_owed(Some((1000, synced)));
    }

    #[test]
    fn the_check_pass_finds_a_file_added_without_events() {
        let tree = TempTree::new("check-pass");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = Apply::new();
        let root = tree.real();
        replaying_since(&unit, engine::now_secs() - 2000);
        fs::write(tree.0.join("Sub/unheard.txt"), b"").unwrap();
        old_folder(&tree.0.join("Sub"));
        let done = vec![ev(&root, HISTORY_DONE, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, done, Instant::now()), None);
        assert_eq!(
            names(&unit, "unheard"),
            [("unheard.txt".to_owned(), format!("{root}/Sub"))]
        );
        assert!(a.checked);
        assert_eq!(unit.owed(), None);
    }

    #[test]
    fn the_check_pass_relists_every_top_level_dot_folder() {
        let tree = TempTree::new("check-dot");
        fs::create_dir_all(tree.0.join(".Spotlight-V100/Store")).unwrap();
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = Apply::new();
        let root = tree.real();
        replaying_since(&unit, engine::now_secs() - 500);
        fs::write(tree.0.join(".Spotlight-V100/Store/dotstore.db"), b"").unwrap();
        for folder in [".Spotlight-V100/Store", ".Spotlight-V100", ""] {
            old_folder(&tree.0.join(folder));
        }
        let done = vec![ev(&root, HISTORY_DONE, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, done, Instant::now()), None);
        assert_eq!(
            names(&unit, "dotstore"),
            [(
                "dotstore.db".to_owned(),
                format!("{root}/.Spotlight-V100/Store")
            )]
        );
    }

    #[test]
    fn a_replay_saves_once_history_is_done() {
        let tree = TempTree::new("replay-save");
        let (shared, unit, _rx) = bench(config(&tree));
        unit.watcher().device = dev_of(&tree);
        compact(&shared, &unit);
        let synced = unit.read(|l| l.synced_at).unwrap();
        replaying_since(&unit, synced);
        let stamp = || {
            let m = fs::metadata(&unit.file).unwrap();
            (m.ino(), m.mtime(), m.mtime_nsec())
        };
        let before = stamp();
        let root = tree.real();
        fs::write(tree.0.join("Sub/replayed.txt"), b"").unwrap();
        let (tx, batches) = std::sync::mpsc::channel();
        let (shared, unit) = (&shared, &unit);
        std::thread::scope(|s| {
            s.spawn(move || run(shared, unit, &batches));
            tx.send(vec![ev(&format!("{root}/Sub"), 0, 1500, 1)])
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            while names(unit, "replayed").is_empty() {
                assert!(
                    Instant::now() < deadline,
                    "the replayed event was never applied"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            assert_eq!(stamp(), before, "saved before the history was done");
            assert!(unit.owed().is_some());
            tx.send(vec![ev(&root, HISTORY_DONE, 9000, 1)]).unwrap();
            drop(tx);
        });
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert_eq!(saved.event_id(), 1500);
        assert!(saved.synced_at() >= synced);
        assert_ne!(stamp(), before);
        assert_eq!(unit.owed(), None);
    }

    #[test]
    fn a_marker_id_never_becomes_the_saved_id() {
        let tree = TempTree::new("apply-marker");
        let (shared, unit, _rx) = bench(config(&tree));
        unit.watcher().device = dev_of(&tree);
        restarted(&unit, 1, 1000);
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        let sub = format!("{root}/Sub");
        fs::write(tree.0.join("Sub/change.txt"), b"").unwrap();
        let change = vec![ev(&sub, 0, 1500, 1)];
        assert_eq!(step(&shared, &unit, &mut a, change, now), None);
        let markers = [
            ev(&root, HISTORY_DONE, 9000, 1),
            ev(&root, MOUNT, 9100, 1),
            ev(&root, UNMOUNT, 9200, 1),
            ev(&root, MUST_SCAN_SUBDIRS, 9300, 1),
            ev(&sub, MUST_SCAN_SUBDIRS | USER_DROPPED, 9400, 1),
            ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 9500, 1),
            ev(&root, EVENT_IDS_WRAPPED, 5, 1),
        ];
        for e in markers {
            let flags = e.flags;
            assert_eq!(step(&shared, &unit, &mut a, vec![e], now), None);
            finish_recovery(&shared, &unit, &mut a);
            assert_eq!(unit.read(|l| l.event_id), Some(1500), "flags {flags:#x}");
        }
        fs::write(tree.0.join("Sub/after.txt"), b"").unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&sub, 0, 6, 1)], now),
            None
        );
        assert_eq!(names(&unit, "after"), [("after.txt".to_owned(), sub)]);
        assert_eq!(fold(&shared, &unit, &unit).unwrap().event_id(), 1500);
    }

    #[test]
    fn history_below_a_device_streams_start_is_skipped() {
        let tree = TempTree::new("apply-below");
        let (shared, unit, _rx) = bench(config(&tree));
        unit.watcher().device = dev_of(&tree);
        restarted(&unit, 1, 5000);
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        fs::write(tree.0.join("Sub/older.txt"), b"").unwrap();
        let old = vec![
            ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 4000, 1),
            ev(&root, EVENT_IDS_WRAPPED, 4100, 1),
            ev(&format!("{root}/Sub"), 0, 5000, 1),
        ];
        assert_eq!(step(&shared, &unit, &mut a, old, now), None);
        assert!(a.recovery.is_none());
        assert!(names(&unit, "older").is_empty());
        assert_eq!(
            unit.read(|l| (l.event_id, l.recovery_from)),
            Some((1000, None))
        );
        unit.set_owed(Some((5000, engine::now_secs())));
        let purged = vec![ev(&root, MUST_SCAN_SUBDIRS, 4300, 1)];
        assert_eq!(step(&shared, &unit, &mut a, purged, now), None);
        finish_recovery(&shared, &unit, &mut a);
        assert_eq!(
            names(&unit, "older"),
            [("older.txt".to_owned(), format!("{root}/Sub"))]
        );
    }

    #[test]
    fn a_save_during_a_replay_keeps_the_saved_id_and_sync_time() {
        let tree = TempTree::new("replay-saves");
        let (shared, unit, _rx) = bench(config(&tree));
        unit.watcher().device = dev_of(&tree);
        let synced = engine::now_secs() - 300;
        replaying_since(&unit, synced);
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        let sub = format!("{root}/Sub");
        let saved = || {
            let index = Index::load(&unit.file, unit.root.clone()).unwrap();
            (index.event_id(), index.synced_at())
        };
        fs::write(tree.0.join("Sub/first.txt"), b"").unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&sub, 0, 1500, 1)], now),
            None
        );
        let kernel = vec![ev(&root, MUST_SCAN_SUBDIRS | KERNEL_DROPPED, 1600, 1)];
        assert_eq!(step(&shared, &unit, &mut a, kernel, now), None);
        finish_recovery(&shared, &unit, &mut a);
        assert_eq!(
            unit.read(|l| (l.event_id, l.recovery_from)),
            Some((1500, None))
        );
        assert!(unit.read(|l| l.synced_at).unwrap() > synced);
        compact(&shared, &unit);
        assert_eq!(saved(), (1000, synced));
        fs::write(tree.0.join("Sub/second.txt"), b"").unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&sub, 0, 1700, 1)], now),
            None
        );
        let folded = fold(&shared, &unit, &unit).unwrap();
        assert_eq!((folded.event_id(), folded.synced_at()), (1000, synced));
        assert_eq!(saved(), (1000, synced));
        let started = engine::now_secs();
        let done = vec![ev(&root, HISTORY_DONE, 9000, 1)];
        assert_eq!(step(&shared, &unit, &mut a, done, now), None);
        assert!(a.checked);
        compact(&shared, &unit);
        let (id, at) = saved();
        assert_eq!(id, 1700);
        assert!(at >= started);
    }

    #[test]
    fn the_same_event_twice_changes_nothing() {
        let tree = TempTree::new("apply-twice");
        let (shared, unit, rx) = bench(config(&tree));
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now),
            None
        );
        assert_eq!(heard(&rx), [None, Some((EnginePhase::Live, 7))]);
        assert_eq!(names(&unit, "new"), [("new.txt".to_owned(), root.clone())]);
        let again = vec![ev(&root, 0, 1001, 1), ev(&format!("{root}/"), 0, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, again, now), None);
        assert!(heard(&rx).is_empty());
        assert_eq!(unit.read(|l| l.event_id), Some(1002));
    }

    fn inside_data(name: &str) -> (TempTree, Shared, Arc<Unit>, Receiver<Heard>) {
        let tree = TempTree::new(name);
        fs::create_dir(tree.0.join("Data")).unwrap();
        let mut config = config(&tree);
        config.data_folder = tree.0.join("Data").to_str().unwrap().to_owned();
        let (shared, unit, rx) = bench(config);
        (tree, shared, unit, rx)
    }

    #[test]
    fn the_data_folder_follows_live_events() {
        let (tree, shared, unit, _rx) = inside_data("apply-data");
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        fs::write(tree.0.join("Data/fresh.bin"), b"").unwrap();
        let data = format!("{root}/Data");
        let batch = vec![ev(&data, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, now), None);
        assert_eq!(names(&unit, "fresh"), [("fresh.bin".to_owned(), data)]);
    }

    #[test]
    fn a_save_while_live_relists_once_and_saves_nothing_more() {
        let (tree, shared, unit, _rx) = inside_data("apply-data-save");
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        let data = format!("{root}/Data");
        let stamp = |name: &str| {
            let m = fs::metadata(tree.0.join("Data").join(name)).unwrap();
            (m.ino(), m.len(), m.mtime(), m.mtime_nsec())
        };
        compact(&shared, &unit);
        shared.opens.record(b"/opened.txt", engine::now_secs());
        shared.opens.save(engine::now_secs()).unwrap();
        let saved = [stamp(crate::index::FILE), stamp(crate::opens::FILE)];
        let pending = unit.read(|l| l.pending()).unwrap();
        for (id, word, name) in [
            (1001, "index", crate::index::FILE),
            (1002, "opens", crate::opens::FILE),
        ] {
            let batch = vec![ev(&data, 0, id, 1)];
            assert_eq!(step(&shared, &unit, &mut a, batch, now), None);
            assert_eq!(names(&unit, word), [(name.to_owned(), data.clone())]);
        }
        assert_eq!(
            [stamp(crate::index::FILE), stamp(crate::opens::FILE)],
            saved
        );
        assert!(unit.read(|l| l.pending()).unwrap() <= pending + 4);
        assert!(pending + 4 < COMPACT_PENDING);
    }

    #[test]
    fn compaction_waits_for_thirty_quiet_seconds() {
        let t = Instant::now();
        let mut a = Apply {
            last_edit: t,
            over_soft: Some(t),
            ..Apply::new()
        };
        let pending = COMPACT_PENDING + 1;
        assert!(!a.compact_due(pending, t));
        assert!(!a.compact_due(pending, t + Duration::from_secs(29)));
        assert!(a.compact_due(pending, t + Duration::from_secs(30)));
        assert!(!a.compact_due(COMPACT_PENDING, t + Duration::from_secs(30)));
    }

    #[test]
    fn compaction_runs_at_the_hard_bound_while_changes_go_on() {
        let t = Instant::now();
        let now = t + Duration::from_secs(1);
        let mut a = Apply {
            last_edit: now,
            over_soft: Some(t),
            ..Apply::new()
        };
        assert_eq!(COMPACT_PENDING, 50_000);
        assert_eq!(COMPACT_HARD, 100_000);
        assert!(!a.compact_due(COMPACT_HARD, now));
        assert!(a.compact_due(COMPACT_HARD + 1, now));
        a.recovery = Some(Recovery {
            dirs: Vec::new().into_iter(),
            started: 0,
        });
        assert!(!a.compact_due(COMPACT_HARD + 1, now));
        a.recovery = None;
        assert!(a.compact_due(COMPACT_HARD + 1, now));
    }

    #[test]
    fn the_idle_wait_ends_at_the_quiet_deadline() {
        let t = Instant::now();
        let pending = COMPACT_PENDING + 1;
        let mut a = Apply {
            last_edit: t,
            over_soft: Some(t),
            ..Apply::new()
        };
        assert_eq!(
            a.compact_wait(pending, t + Duration::from_secs(10)),
            Duration::from_secs(20)
        );
        let due = t + Duration::from_secs(30);
        assert_eq!(a.compact_wait(pending, due), Duration::ZERO);
        assert!(a.compact_due(pending, due));
        a.compact_tried(pending, due);
        assert_eq!(
            a.compact_wait(pending, t + Duration::from_secs(31)),
            Duration::from_secs(59)
        );
        assert!(!a.compact_due(pending, t + Duration::from_secs(31)));
        a.last_edit = t + Duration::from_secs(290);
        assert_eq!(
            a.compact_wait(pending, t + Duration::from_secs(299)),
            Duration::from_secs(1)
        );
        assert!(a.compact_due(pending, t + Duration::from_secs(300)));
    }

    #[test]
    fn a_failed_compaction_waits_before_its_next_try() {
        let t = Instant::now();
        for pending in [COMPACT_PENDING + 1, COMPACT_HARD + 1] {
            let mut a = Apply {
                last_edit: t - Duration::from_secs(30),
                over_soft: Some(t - Duration::from_secs(30)),
                ..Apply::new()
            };
            assert!(a.compact_due(pending, t));
            a.compact_tried(pending, t);
            assert!(!a.compact_due(pending, t + Duration::from_secs(59)));
            let retry = t + Duration::from_secs(60);
            assert_eq!(a.compact_wait(pending, retry), Duration::ZERO);
            assert!(a.compact_due(pending, retry));
            a.compact_tried(0, retry);
            assert_eq!(a.over_soft, None);
            assert_eq!(a.last_try, None);
            a.last_edit = retry;
            assert!(!a.compact_due(COMPACT_PENDING + 1, retry));
            assert_eq!(a.over_soft, Some(retry));
            assert!(a.compact_due(COMPACT_HARD + 1, retry));
        }
    }

    #[test]
    fn only_applied_edits_break_the_quiet() {
        let tree = TempTree::new("apply-quiet-edits");
        fs::create_dir(tree.0.join("Excluded")).unwrap();
        let mut config = config(&tree);
        config.excluded = vec![tree.0.join("Excluded").to_str().unwrap().to_owned()];
        let (shared, unit, rx) = bench(config);
        let mut a = live();
        let t = a.last_edit;
        let root = tree.real();
        fs::write(tree.0.join("Excluded/ignored.txt"), b"").unwrap();
        for (secs, path) in [(1, format!("{root}/Excluded")), (2, format!("{root}/Sub"))] {
            assert_eq!(
                step(
                    &shared,
                    &unit,
                    &mut a,
                    vec![ev(&path, 0, 1000 + secs, 1)],
                    t + Duration::from_secs(secs),
                ),
                None
            );
            assert_eq!(a.last_edit, t);
            assert!(heard(&rx).is_empty());
        }
        assert!(names(&unit, "ignored").is_empty());
        fs::write(tree.0.join("Sub/new.txt"), b"").unwrap();
        let t3 = t + Duration::from_secs(3);
        let sub = format!("{root}/Sub");
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&sub, 0, 1003, 1)], t3),
            None
        );
        assert_eq!(a.last_edit, t3);
        assert_eq!(names(&unit, "new"), [("new.txt".to_owned(), sub)]);
        assert!(heard(&rx).contains(&None));
        assert_eq!(a.over_soft, None);
    }

    #[test]
    fn the_soft_bound_compacts_after_its_age_cap_without_quiet() {
        let t = Instant::now();
        let pending = COMPACT_PENDING + 1;
        let mut a = Apply {
            last_edit: t,
            over_soft: Some(t),
            ..Apply::new()
        };
        let before = t + Duration::from_secs(299);
        a.last_edit = before - Duration::from_secs(1);
        assert!(!a.compact_due(pending, before));
        let due = t + Duration::from_secs(300);
        a.last_edit = due - Duration::from_secs(1);
        assert!(a.compact_due(pending, due));

        let mut reset = Apply {
            last_edit: t,
            over_soft: Some(t),
            ..Apply::new()
        };
        assert!(!reset.compact_due(COMPACT_PENDING, t + Duration::from_secs(60)));
        assert_eq!(reset.over_soft, None);
        reset.last_edit = t + Duration::from_secs(119);
        assert!(!reset.compact_due(pending, t + Duration::from_secs(120)));
        assert_eq!(reset.over_soft, Some(t + Duration::from_secs(120)));
        reset.last_edit = due - Duration::from_secs(1);
        assert!(!reset.compact_due(pending, due));
        let due = t + Duration::from_secs(420);
        reset.last_edit = due - Duration::from_secs(1);
        assert!(reset.compact_due(pending, due));
    }

    #[test]
    fn events_never_open_an_excluded_folder() {
        let tree = TempTree::new("apply-excluded");
        let home = tree.0.join("home");
        for dir in ["Desktop", "Documents", "Other"] {
            fs::create_dir_all(home.join(dir)).unwrap();
        }
        let mut config = config(&tree);
        config.excluded = ["Desktop", "Documents"]
            .map(|d| home.join(d).to_str().unwrap().to_owned())
            .to_vec();
        let (shared, unit, rx) = bench(config);
        let mut a = Apply::new();
        let now = Instant::now();
        let real = format!("{}/home", tree.real());
        fs::write(home.join("Desktop/new.txt"), b"").unwrap();
        fs::write(home.join("Documents/new.txt"), b"").unwrap();
        fs::write(home.join("Other/marker.txt"), b"").unwrap();
        let _locked = Locked::new(vec![home.join("Documents")]);
        let rescan = vec![ev(&format!("{real}/Documents"), MUST_SCAN_SUBDIRS, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, rescan, now), None);
        assert!(heard(&rx).is_empty());
        let mut batch = Vec::new();
        for dir in ["Desktop", "Documents"] {
            batch.push(ev(&format!("{real}/{dir}"), 0, 1001, 1));
            batch.push(ev(&format!("{real}/{dir}"), MUST_SCAN_SUBDIRS, 1002, 1));
        }
        batch.push(ev(&real, MUST_SCAN_SUBDIRS, 1003, 1));
        batch.push(ev(&format!("{real}/Other"), 0, 1004, 1));
        assert_eq!(step(&shared, &unit, &mut a, batch, now), None);
        assert_eq!(
            names(&unit, "marker"),
            [("marker.txt".to_owned(), format!("{real}/Other"))]
        );
        assert!(names(&unit, "new.txt").is_empty());
        let kernel = vec![ev(
            &tree.real(),
            MUST_SCAN_SUBDIRS | KERNEL_DROPPED,
            1005,
            1,
        )];
        assert_eq!(step(&shared, &unit, &mut a, kernel, now), None);
        assert!(names(&unit, "new.txt").is_empty());
    }

    #[test]
    fn a_compaction_saves_the_event_id_and_keeps_held_rows() {
        let tree = TempTree::new("apply-compact");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = Apply::new();
        let (root, now) = (tree.real(), Instant::now());
        let find = || unit.read(|l| l.find("txt", || false)).flatten().unwrap();
        let first = find();
        let first_rows = first.rows(0, usize::MAX);
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        fs::remove_file(tree.0.join("beta.txt")).unwrap();
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now),
            None
        );
        let held = find();
        let rows = held.rows(0, usize::MAX);
        let synced_at = unit.read(|l| l.synced_at).unwrap();
        compact(&shared, &unit);
        let saved =
            Index::load(&tree.data().join(crate::index::FILE), PathBuf::from(&root)).unwrap();
        assert_eq!(
            (saved.event_id(), saved.synced_at(), saved.entries()),
            (1001, synced_at, 6)
        );
        let now = unit.read(|l| (l.pending(), l.event_id, l.base.entries()));
        assert_eq!(now, Some((0, 1001, 6)));
        assert_eq!(first.rows(0, usize::MAX), first_rows);
        assert!(first_rows.iter().any(|h| h.name == "beta.txt"));
        assert_eq!(held.rows(0, usize::MAX), rows);
        assert!(rows.iter().any(|h| h.name == "new.txt"));
        let sub = format!("{root}/Sub");
        assert_eq!(
            names(&unit, "txt"),
            [
                ("Alpha.TXT".to_owned(), root.clone()),
                ("DELTA.Txt".to_owned(), sub),
                ("new.txt".to_owned(), root),
            ]
        );
    }

    #[test]
    fn a_compaction_after_stop_saves_nothing() {
        let tree = TempTree::new("apply-compact-stop");
        let (shared, unit, _rx) = bench(config(&tree));
        let mut a = live();
        let (root, now) = (tree.real(), Instant::now());
        fs::create_dir_all(tree.0.join("New/Deep")).unwrap();
        fs::write(tree.0.join("New/Deep/f.txt"), b"").unwrap();
        unit.stop.store(true, Ordering::Relaxed);
        assert_eq!(
            step(&shared, &unit, &mut a, vec![ev(&root, 0, 1001, 1)], now),
            None
        );
        assert_eq!(unit.read(|l| l.event_id), Some(1001));
        compact(&shared, &unit);
        assert!(!tree.data().join(crate::index::FILE).exists());
    }

    fn shut_at_the_crawl(name: &str) -> (TempTree, Shared, Arc<Unit>, Receiver<Heard>, String) {
        let tree = TempTree::new(name);
        fs::create_dir(tree.0.join("Shut")).unwrap();
        let locked = Locked::new(vec![tree.0.join("Shut")]);
        let (shared, unit, rx) = bench(config(&tree));
        drop(locked);
        fs::write(tree.0.join("Shut/inside.txt"), b"").unwrap();
        let shut = format!("{}/Shut", tree.real());
        (tree, shared, unit, rx, shut)
    }

    #[test]
    fn a_folder_shut_at_the_crawl_keeps_its_files_through_a_compaction() {
        let (_tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-unlisted");
        let mut a = live();
        let batch = vec![ev(&shut, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        let found = [("inside.txt".to_owned(), shut)];
        assert_eq!(names(&unit, "inside"), found);
        compact(&shared, &unit);
        assert_eq!(unit.read(|l| l.pending()), Some(0));
        assert_eq!(names(&unit, "inside"), found);
    }

    #[test]
    fn a_parent_event_lists_a_folder_shut_at_the_crawl_once() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-unlisted-parent");
        let mut a = live();
        let root = tree.real();
        let batch = vec![ev(&root, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(names(&unit, "inside"), [("inside.txt".to_owned(), shut)]);
        let disk = unit.disk(&unit.skip);
        let scans = unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans());
        assert_eq!(scans, Some(0));
    }

    #[test]
    fn a_deep_event_in_a_shut_folder_survives_compaction() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-deep");
        fs::remove_file(tree.0.join("Shut/inside.txt")).unwrap();
        fs::create_dir_all(tree.0.join("Shut/Deep")).unwrap();
        fs::write(tree.0.join("Shut/Deep/x.txt"), b"x").unwrap();
        assert_eq!(
            unit.read(|l| l.base_dir(shut.as_bytes()).is_none()),
            Some(true)
        );
        let deep = format!("{shut}/Deep");
        let mut a = live();
        let batch = vec![ev(&deep, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        let found = [("x.txt".to_owned(), deep)];
        assert_eq!(names(&unit, "x.txt"), found);
        let entries = unit.read(Live::entries);
        compact(&shared, &unit);
        assert_eq!(names(&unit, "x.txt"), found);
        assert_eq!(unit.read(Live::entries), entries);
        assert_eq!(unit.read(|l| l.pending()), Some(0));
    }

    #[test]
    fn a_parent_event_repairs_a_shut_folder_with_only_deep_events() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-repair");
        fs::create_dir(tree.0.join("Shut/Deep")).unwrap();
        fs::write(tree.0.join("Shut/Deep/x.txt"), b"x").unwrap();
        let locked = Locked::new(vec![tree.0.join("Shut")]);
        fs::set_permissions(tree.0.join("Shut"), fs::Permissions::from_mode(0o111)).unwrap();
        let mut a = live();
        let deep = format!("{shut}/Deep");
        let batch = vec![ev(&deep, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert!(names(&unit, "inside").is_empty());
        assert_eq!(names(&unit, "x.txt"), [("x.txt".to_owned(), deep.clone())]);
        drop(locked);
        let disk = unit.disk(&unit.skip);
        let root = tree.real();
        assert_eq!(
            unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
            Some(1)
        );
        let batch = vec![ev(&root, 0, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(names(&unit, "inside"), [("inside.txt".to_owned(), shut)]);
        assert_eq!(names(&unit, "x.txt"), [("x.txt".to_owned(), deep)]);
        assert_eq!(
            unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
            Some(0)
        );
    }

    #[test]
    fn a_parent_event_repairs_a_shut_folder_after_compaction() {
        for reload in [false, true] {
            let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-mark");
            fs::create_dir(tree.0.join("Shut/Deep")).unwrap();
            fs::write(tree.0.join("Shut/Deep/x.txt"), b"x").unwrap();
            let locked = Locked::new(vec![tree.0.join("Shut")]);
            fs::set_permissions(tree.0.join("Shut"), fs::Permissions::from_mode(0o111)).unwrap();
            assert!(crawl::list_one(&tree.0.join("Shut")).is_err());
            let mut a = live();
            let deep = format!("{shut}/Deep");
            let batch = vec![ev(&deep, 0, 1001, 1)];
            assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
            let known = [("x.txt".to_owned(), deep)];
            assert_eq!(names(&unit, "x.txt"), known);
            assert!(names(&unit, "inside").is_empty());
            let entries = unit.read(Live::entries).unwrap();
            let root = tree.real();
            let disk = unit.disk(&unit.skip);
            for id in [1002, 1003] {
                compact(&shared, &unit);
                if reload {
                    let index = Index::load(&unit.file, unit.root.clone()).unwrap();
                    unit.put(&shared, Live::new(Arc::new(index)));
                }
                assert_eq!(unit.read(Live::pending), Some(0));
                let batch = vec![ev(&root, 0, id, 1)];
                assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
                assert_eq!(names(&unit, "x.txt"), known);
                assert!(names(&unit, "inside").is_empty());
            }
            drop(locked);
            let batch = vec![ev(&root, 0, 1004, 1)];
            assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
            assert_eq!(names(&unit, "inside"), [("inside.txt".to_owned(), shut)]);
            assert_eq!(names(&unit, "x.txt"), known);
            assert_eq!(unit.read(Live::entries), Some(entries + 1));
            assert_eq!(
                unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
                Some(0)
            );
            compact(&shared, &unit);
            assert_eq!(
                unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
                Some(0)
            );
        }
    }

    #[test]
    fn completing_an_unchanged_partial_listing_is_a_pending_edit() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-complete");
        fs::remove_file(tree.0.join("Shut/inside.txt")).unwrap();
        fs::create_dir(tree.0.join("Shut/Deep")).unwrap();
        let locked = Locked::new(vec![tree.0.join("Shut")]);
        fs::set_permissions(tree.0.join("Shut"), fs::Permissions::from_mode(0o111)).unwrap();
        let mut a = live();
        let batch = vec![ev(&format!("{shut}/Deep"), 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        compact(&shared, &unit);
        assert_eq!(unit.read(Live::pending), Some(0));
        drop(locked);
        let disk = unit.disk(&unit.skip);
        let before = names(&unit, "");
        let fetched = unit
            .read(|l| l.fetch_changed(shut.as_bytes(), &disk))
            .flatten()
            .expect("an equal listing must still complete the partial block");
        unit.write(|l| l.apply(fetched, &disk));
        assert_eq!(names(&unit, ""), before);
        assert_eq!(unit.read(Live::pending), Some(1));
        assert_eq!(
            unit.read(|l| l.fetch_changed(shut.as_bytes(), &disk).is_none()),
            Some(true)
        );
        compact(&shared, &unit);
        assert_eq!(unit.read(Live::pending), Some(0));
        assert_eq!(
            unit.read(|l| l.fetch(tree.real().as_bytes(), false, &disk).scans()),
            Some(0)
        );
    }

    #[test]
    fn a_deep_event_repairs_readable_ancestors_before_compaction() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-ancestors");
        fs::create_dir_all(tree.0.join("Shut/Deep/Inner")).unwrap();
        fs::write(tree.0.join("Shut/Deep/Inner/x.txt"), b"x").unwrap();
        let locked = Locked::new(vec![tree.0.join("Shut")]);
        fs::set_permissions(tree.0.join("Shut"), fs::Permissions::from_mode(0o111)).unwrap();
        let mut a = live();
        let deep = format!("{shut}/Deep/Inner");
        let batch = vec![ev(&deep, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert!(names(&unit, "inside").is_empty());
        drop(locked);
        let batch = vec![ev(&deep, 0, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        compact(&shared, &unit);
        let batch = vec![ev(&tree.real(), 0, 1003, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(names(&unit, "inside"), [("inside.txt".to_owned(), shut)]);
        assert_eq!(names(&unit, "x.txt"), [("x.txt".to_owned(), deep)]);
    }

    #[test]
    fn a_deep_event_survives_an_unreadable_intermediate_folder() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-partial");
        fs::create_dir_all(tree.0.join("Shut/Deep/Inner")).unwrap();
        fs::write(tree.0.join("Shut/Deep/Inner/x.txt"), b"x").unwrap();
        let _locked = Locked::new(vec![tree.0.join("Shut/Deep")]);
        fs::set_permissions(tree.0.join("Shut/Deep"), fs::Permissions::from_mode(0o111)).unwrap();
        let mut a = live();
        let inner = format!("{shut}/Deep/Inner");
        let batch = vec![ev(&inner, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        let found = [("x.txt".to_owned(), inner)];
        assert_eq!(names(&unit, "x.txt"), found);
        compact(&shared, &unit);
        assert_eq!(names(&unit, "x.txt"), found);
        assert_eq!(names(&unit, "inside"), [("inside.txt".to_owned(), shut)]);
    }

    #[test]
    fn an_ancestor_scan_keeps_known_files_in_an_unreadable_sibling() {
        for parent in [false, true] {
            let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-sibling");
            fs::create_dir(tree.0.join("Shut/A")).unwrap();
            fs::write(tree.0.join("Shut/A/known.txt"), b"known").unwrap();
            let locked = Locked::new(vec![tree.0.join("Shut")]);
            fs::set_permissions(tree.0.join("Shut"), fs::Permissions::from_mode(0o111)).unwrap();
            let mut a = live();
            let folder = format!("{shut}/A");
            let batch = vec![ev(&folder, 0, 1001, 1)];
            assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
            let found = [("known.txt".to_owned(), folder)];
            assert_eq!(names(&unit, "known"), found);
            drop(locked);
            let _locked = Locked::new(vec![tree.0.join("Shut/A")]);
            fs::create_dir(tree.0.join("Shut/B")).unwrap();
            fs::write(tree.0.join("Shut/B/new.txt"), b"new").unwrap();
            let other = format!("{shut}/B");
            let event = if parent { tree.real() } else { other.clone() };
            let batch = vec![ev(&event, 0, 1002, 1)];
            assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
            assert_eq!(names(&unit, "known"), found);
            compact(&shared, &unit);
            assert_eq!(names(&unit, "known"), found);
            assert_eq!(names(&unit, "new.txt"), [("new.txt".to_owned(), other)]);
        }
    }

    #[test]
    fn a_parent_event_lists_an_empty_shut_folder_once() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-shut-empty");
        fs::remove_file(tree.0.join("Shut/inside.txt")).unwrap();
        let mut a = live();
        let root = tree.real();
        let disk = unit.disk(&unit.skip);
        let locked = Locked::new(vec![tree.0.join("Shut")]);
        let batch = vec![ev(&root, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(
            unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
            Some(1)
        );
        drop(locked);
        let batch = vec![ev(&root, 0, 1002, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(
            unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
            Some(0)
        );
        compact(&shared, &unit);
        assert_eq!(
            unit.read(|l| l.fetch(root.as_bytes(), false, &disk).scans()),
            Some(0)
        );
        fs::write(tree.0.join("Shut/later.txt"), b"later").unwrap();
        let batch = vec![ev(&shut, 0, 1003, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        assert_eq!(names(&unit, "later"), [("later.txt".to_owned(), shut)]);
    }

    #[test]
    fn a_removed_child_event_keeps_its_new_ancestor_through_compaction() {
        let tree = TempTree::new("apply-new-ancestor");
        let (shared, unit, _rx) = bench(config(&tree));
        fs::create_dir(tree.0.join("New")).unwrap();
        fs::write(tree.0.join("New/keep.txt"), b"keep").unwrap();
        let folder = format!("{}/New", tree.real());
        let mut a = live();
        let batch = vec![ev(&format!("{folder}/Gone"), 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        let found = [("keep.txt".to_owned(), folder)];
        assert_eq!(names(&unit, "keep"), found);
        compact(&shared, &unit);
        assert_eq!(names(&unit, "keep"), found);
    }

    #[test]
    fn a_fold_into_a_new_unit_keeps_a_folder_shut_at_the_crawl() {
        let (tree, shared, unit, _rx, shut) = shut_at_the_crawl("apply-unlisted-fold");
        let mut a = live();
        let batch = vec![ev(&shut, 0, 1001, 1)];
        assert_eq!(step(&shared, &unit, &mut a, batch, Instant::now()), None);
        let to = Unit::new(
            unit.root.clone(),
            None,
            tree.data().join("refolded.index"),
            (unit.skip.clone(), b"another print".to_vec()),
            crawl::Pool::new(1).unwrap(),
            std::sync::mpsc::channel().0,
            Arc::default(),
        );
        let index = fold(&shared, &unit, &to).unwrap();
        let held = Live::new(Arc::new(index));
        let found = held.find("inside", || false).unwrap();
        let rows: Vec<_> = found
            .rows(0, usize::MAX)
            .into_iter()
            .map(|h| (h.name, h.folder))
            .collect();
        assert_eq!(rows, [("inside.txt".to_owned(), shut)]);
        assert_eq!(held.pending(), 0);
    }
}
