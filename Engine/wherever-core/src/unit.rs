use std::any::Any;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock, TryLockError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use crate::crawl::{self, Crawl, Pool};
use crate::engine::{self, Settings, Shared};
use crate::fsevents::{self, Event, Watcher};
use crate::index::{self, Index};
use crate::live::{Disk, Live};
use crate::{EngineError, EnginePhase, EngineTroubleKind, apply, opens, sort};

const KEEP_FILES: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const KEEP_TEMPS: Duration = Duration::from_secs(24 * 60 * 60);

pub(crate) mod partial;

type Rebuild = Option<(EnginePhase, u64)>;

#[cfg(test)]
thread_local! {
    pub(crate) static OS_BUILD: std::cell::Cell<Option<[u8; index::OS_BUILD_BYTES]>> = const { std::cell::Cell::new(None) };
}

fn os_build() -> [u8; index::OS_BUILD_BYTES] {
    #[cfg(test)]
    if let Some(build) = OS_BUILD.get() {
        return build;
    }
    let mut build = [0; index::OS_BUILD_BYTES];
    let mut len = build.len();
    let result = unsafe {
        libc::sysctlbyname(
            c"kern.osversion".as_ptr(),
            build.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        build.fill(0);
    }
    build
}

pub(crate) struct Unit {
    pub(crate) root: PathBuf,
    pub(crate) id: Option<String>,
    pub(crate) file: PathBuf,
    pub(crate) skip: Vec<PathBuf>,
    pub(crate) print: Vec<u8>,
    pub(crate) pool: Pool,
    pub(crate) stop: AtomicBool,
    pub(crate) live: RwLock<Option<Live>>,
    partial: Mutex<Option<partial::Partial>>,
    kept: Mutex<Option<partial::Snapshot>>,
    pub(crate) discarded: AtomicBool,
    published: Mutex<Option<Instant>>,
    pub(crate) watcher: Mutex<Watcher>,
    pub(crate) history: Mutex<u128>,
    os_build: [u8; index::OS_BUILD_BYTES],
    pub(crate) relist: AtomicBool,
    pub(crate) rereading: AtomicBool,
    pub(crate) waiting: AtomicBool,
    #[cfg(test)]
    pub(crate) relists: std::sync::atomic::AtomicUsize,
    pub(crate) owed: Mutex<Option<(u64, u64)>>,
    #[cfg(test)]
    pub(crate) facts: Mutex<Option<Device>>,
    status: Mutex<(EnginePhase, u64, Rebuild)>,
    trouble: Mutex<Option<EngineTroubleKind>>,
    pub(crate) thread: Mutex<Option<JoinHandle<()>>>,
}

impl Unit {
    pub(crate) fn new(
        root: PathBuf,
        id: Option<String>,
        file: PathBuf,
        (skip, print): (Vec<PathBuf>, Vec<u8>),
        pool: Pool,
        events: Sender<Vec<Event>>,
        paused: Arc<AtomicBool>,
    ) -> Unit {
        let os_build = if id.is_none() {
            os_build()
        } else {
            [0; index::OS_BUILD_BYTES]
        };
        Unit {
            root,
            id,
            file,
            skip,
            print,
            pool,
            stop: AtomicBool::new(false),
            live: RwLock::new(None),
            partial: Mutex::new(None),
            kept: Mutex::new(None),
            discarded: AtomicBool::new(false),
            published: Mutex::new(None),
            watcher: Mutex::new(Watcher::new(events, paused)),
            history: Mutex::new(0),
            os_build,
            relist: AtomicBool::new(false),
            rereading: AtomicBool::new(false),
            waiting: AtomicBool::new(false),
            #[cfg(test)]
            relists: std::sync::atomic::AtomicUsize::new(0),
            owed: Mutex::new(None),
            #[cfg(test)]
            facts: Mutex::new(None),
            status: Mutex::new((EnginePhase::Loading, 0, None)),
            trouble: Mutex::new(None),
            thread: Mutex::new(None),
        }
    }

    pub(crate) fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    pub(crate) fn partial(&self) -> Option<partial::Snapshot> {
        let kept = self
            .kept
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        kept.or_else(|| {
            self.partial
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .as_ref()
                .map(partial::Partial::snapshot)
        })
    }

    pub(crate) fn begin(&self, shared: &Shared) -> bool {
        if self.read(|_| ()).is_some() {
            return false;
        }
        match partial::Partial::new(self.root.clone(), &shared.settings.home, self.id.is_none()) {
            Ok(partial) => {
                *self.partial.lock().unwrap_or_else(PoisonError::into_inner) = Some(partial);
                true
            }
            Err(error) => {
                self.kept
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take();
                shared.fault(error.to_string());
                false
            }
        }
    }

    pub(crate) fn publish(&self, shared: &Shared, listings: &[crawl::Listing]) {
        if self.stopped() {
            return;
        }
        {
            let mut partial = self.partial.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(partial) = partial.as_mut() else {
                return;
            };
            partial.push(listings);
        }
        let kept = self
            .kept
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        drop(kept);
        let _ = shared.listener.results_changed(false);
        *self
            .published
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
    }

    pub(crate) fn refreshed(&self, shared: &Shared, mut dispatch: impl FnMut()) {
        let last = *self
            .published
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(last) = last {
            while last.elapsed() < Duration::from_millis(crawl::PROGRESS_GAP_MS) && !self.stopped()
            {
                dispatch();
                thread::sleep(Duration::from_millis(5));
            }
        }
        if !self.stopped() {
            let _ = shared.listener.results_changed(false);
        }
    }

    pub(crate) fn disk<'a>(&'a self, skip: &'a [PathBuf]) -> Disk<'a> {
        Disk {
            pool: &self.pool,
            skip,
            stop: &self.stop,
        }
    }

    pub(crate) fn read<R>(&self, f: impl FnOnce(&Live) -> R) -> Option<R> {
        self.live
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(f)
    }

    pub(crate) fn write<R>(&self, f: impl FnOnce(&mut Live) -> R) -> Option<R> {
        self.live
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .as_mut()
            .map(f)
    }

    fn with_nested<R>(
        &self,
        shared: &Shared,
        f: impl FnOnce(&mut Option<Live>, Vec<PathBuf>) -> R,
    ) -> R {
        loop {
            let units = shared.units();
            let mut slot = match self.live.try_write() {
                Ok(slot) => slot,
                Err(TryLockError::Poisoned(e)) => e.into_inner(),
                Err(TryLockError::WouldBlock) => {
                    drop(units);
                    thread::sleep(Duration::from_millis(1));
                    continue;
                }
            };
            let nested = units
                .iter()
                .filter(|u| u.root != self.root && u.root.starts_with(&self.root))
                .map(|u| u.root.clone())
                .collect();
            drop(units);
            return f(&mut slot, nested);
        }
    }

    pub(crate) fn update<R>(
        &self,
        shared: &Shared,
        f: impl FnOnce(&mut Live, &Disk) -> R,
    ) -> Option<R> {
        self.with_nested(shared, |slot, nested| {
            let skip = [self.skip.as_slice(), &nested].concat();
            slot.as_mut().map(|live| f(live, &self.disk(&skip)))
        })
    }

    pub(crate) fn watcher(&self) -> MutexGuard<'_, Watcher> {
        self.watcher.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn watch(&self, since: u64) -> Result<(), String> {
        self.watcher().watch(&self.root, since)
    }

    pub(crate) fn resume_from(&self) -> Option<u64> {
        let last_applied = self.read(|l| l.event_id);
        self.watcher().resume_from(last_applied)
    }

    pub(crate) fn watch_saved_boot(&self) -> Result<(), String> {
        let current = self.watcher().current_id()?;
        let history = self.boot_history();
        self.set_history(history);
        let since = self
            .write(|live| {
                let saved = &live.base;
                if self.os_build[0] == 0
                    || saved.os_build() != self.os_build
                    || history == 0
                    || saved.history() != history
                    || saved.event_id() > current
                {
                    self.relist.store(true, Ordering::Relaxed);
                    live.event_id = current;
                    live.recovery_from = Some(current);
                    current
                } else {
                    saved.event_id()
                }
            })
            .ok_or_else(|| "the boot index is not loaded".to_owned())?;
        self.watch(since)
    }

    fn boot_history(&self) -> u128 {
        let data = if self.root == Path::new("/") {
            Path::new("/System/Volumes/Data")
        } else {
            &self.root
        };
        fs::symlink_metadata(data)
            .map(|m| history_of(m.dev() as libc::dev_t))
            .unwrap_or(0)
    }

    pub(crate) fn stamp(&self, index: &mut Index) {
        index.set_history(kept_history(self));
        let build = if self.id.is_none() && !self.relist.load(Ordering::Relaxed) {
            self.os_build
        } else {
            [0; index::OS_BUILD_BYTES]
        };
        index.set_os_build(&build);
    }

    pub(crate) fn owed(&self) -> Option<(u64, u64)> {
        *self.owed.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn set_owed(&self, owed: Option<(u64, u64)>) {
        *self.owed.lock().unwrap_or_else(PoisonError::into_inner) = owed;
    }

    fn set_history(&self, uuid: u128) {
        *self.history.lock().unwrap_or_else(PoisonError::into_inner) = uuid;
    }

    pub(crate) fn kept(&self, l: &Live) -> (u64, u64) {
        let id = l.recovery_from.unwrap_or(l.event_id);
        self.owed()
            .map_or((id, l.synced_at), |(s, synced)| (id.min(s), synced))
    }

    pub(crate) fn status(&self) -> (EnginePhase, u64) {
        let (phase, entries, rebuild) = *self.status.lock().unwrap_or_else(PoisonError::into_inner);
        rebuild.map_or((phase, entries), |(phase, listed)| {
            (phase, entries.max(listed))
        })
    }

    pub(crate) fn settling(&self, paused: bool) -> bool {
        if self.stopped() {
            return false;
        }
        let phase = self.status().0;
        matches!(
            phase,
            EnginePhase::Loading | EnginePhase::Crawling | EnginePhase::Finishing
        ) || (self.trouble().is_none()
            && !paused
            && (self.relist.load(Ordering::Relaxed)
                || self.rereading.load(Ordering::Relaxed)
                || self.owed().is_some()
                || (phase != EnginePhase::Failed && self.watcher().replaying)))
    }

    pub(crate) fn set(&self, phase: EnginePhase, entries: u64) {
        let mut s = self.status.lock().unwrap_or_else(PoisonError::into_inner);
        (s.0, s.1) = (phase, entries);
    }

    fn rebuilding(&self, at: Rebuild) {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).2 = at;
    }

    pub(crate) fn set_phase(&self, phase: EnginePhase) {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).0 = phase;
    }

    pub(crate) fn finish(&self, shared: &Shared) {
        if !self.stopped() {
            self.set_phase(EnginePhase::Finishing);
            shared.report();
        }
    }

    pub(crate) fn trouble(&self) -> Option<EngineTroubleKind> {
        *self.trouble.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_trouble(&self, kind: EngineTroubleKind) {
        *self.trouble.lock().unwrap_or_else(PoisonError::into_inner) = Some(kind);
    }

    pub(crate) fn live_off(&self, shared: &Shared, e: &str) {
        self.set_trouble(EngineTroubleKind::LiveUpdatesOff);
        shared.fault(format!("live updates are off: {e}"));
    }

    pub(crate) fn guard(&self, shared: &Shared, work: impl FnOnce()) {
        if let Err(panic) = panic::catch_unwind(AssertUnwindSafe(work)) {
            self.fell(shared, &*panic);
        }
    }

    pub(crate) fn fell(&self, shared: &Shared, panic: &(dyn Any + Send)) {
        shared.fault(format!("{}: {}", self.root.display(), engine::said(panic)));
        if self.stopped() {
            return;
        }
        self.watcher().close();
        if self.read(|_| ()).is_some() {
            self.set_trouble(EngineTroubleKind::LiveUpdatesOff);
            self.set_phase(EnginePhase::Ready);
        } else {
            if self.id.is_some() {
                self.set_trouble(EngineTroubleKind::Unreadable);
            }
            self.set_phase(EnginePhase::Failed);
        }
        shared.report();
    }

    fn grow(&self, listed: u64) {
        let mut s = self.status.lock().unwrap_or_else(PoisonError::into_inner);
        s.1 = s.1.max(listed);
    }

    pub(crate) fn install(&self, shared: &Shared, index: Index, phase: EnginePhase) {
        let entries = self.put(shared, Live::new(Arc::new(index)));
        self.set(phase, entries);
    }

    pub(crate) fn put(&self, shared: &Shared, mut live: Live) -> u64 {
        shared.premerge(self, &live.base);
        let (old, partial, kept, entries) = self.with_nested(shared, |slot, nested| {
            for root in nested {
                live.drop_below(root.as_os_str().as_bytes());
            }
            let entries = live.entries();
            let old = slot.replace(live);
            let partial = self
                .partial
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            let kept = self
                .kept
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            (old, partial, kept, entries)
        });
        drop((partial, kept));
        if let Some(old) = old {
            sort::forget(&old.base);
        }
        entries
    }
}

pub(crate) fn owns(
    root: &Path,
    nested: &[PathBuf],
    path: &Path,
    mounted: &mut impl FnMut(&Path) -> bool,
) -> bool {
    let Ok(rest) = path.strip_prefix(root) else {
        return false;
    };
    if nested.iter().any(|n| path.starts_with(n)) {
        return false;
    }
    let mut at = root.to_path_buf();
    rest.components().all(|c| {
        at.push(c);
        !mounted(&at)
    })
}

pub(crate) fn purge(around: &Unit, root: &Path, stop: &AtomicBool) -> bool {
    loop {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        let mut live = match around.live.try_write() {
            Ok(live) => live,
            Err(TryLockError::Poisoned(e)) => e.into_inner(),
            Err(TryLockError::WouldBlock) => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
        };
        let Some(l) = live.as_mut() else {
            return false;
        };
        if !l.drop_below(root.as_os_str().as_bytes()) {
            return false;
        }
        let entries = l.entries();
        drop(live);
        around
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .1 = entries;
        return true;
    }
}

pub(crate) fn saved(shared: &Shared, unit: &Unit) -> Option<Index> {
    if fs::symlink_metadata(&unit.file).is_err() {
        return None;
    }
    unit.set_phase(EnginePhase::Loading);
    shared.report();
    match Index::load(&unit.file, unit.root.clone()) {
        Ok(index) => {
            if index.fingerprint() != unit.print
                || index.event_id() == 0
                || !index.skipped().is_empty()
            {
                return None;
            }
            if unit.id.is_none()
                && let Some(root) = shared.settings.volumes_root()
            {
                let mut restore = Vec::new();
                if !crawl::blocked(&unit.skip, &root)
                    && let Ok(listing) = crawl::list_one(&root)
                {
                    for entry in &listing.ents {
                        if entry.kind == crate::EngineKind::Folder && !entry.attrs().mount {
                            restore
                                .push(root.join(std::ffi::OsStr::from_bytes(listing.name(entry))));
                        }
                    }
                }
                return refilter(shared, unit, index, &restore, &unit.stop);
            }
            Some(index)
        }
        Err(e) => {
            shared.fault(format!("{e}; crawling again"));
            None
        }
    }
}

pub(crate) fn watch_from_now(shared: &Shared, unit: &Unit) -> u64 {
    stream(shared, unit, start(unit, None))
}

fn stream(shared: &Shared, unit: &Unit, start: Start) -> u64 {
    begin(unit, start).unwrap_or_else(|e| {
        if !unit.stopped() {
            unit.live_off(shared, &e);
        }
        0
    })
}

fn begin(unit: &Unit, start: Start) -> Result<u64, String> {
    if unit.stopped() {
        return Err("the disk was removed".to_owned());
    }
    let on = match start {
        Start::Path => None,
        Start::Crawl(on) | Start::Replay(on) => Some(on),
    };
    unit.set_history(on.map_or_else(
        || {
            if unit.id.is_none() {
                unit.boot_history()
            } else {
                0
            }
        },
        |on| on.history,
    ));
    let mut w = unit.watcher();
    w.device = on.map_or(0, |on| on.dev);
    on.map_or_else(|| w.current_id(), |on| Ok(on.from))
        .and_then(|id| w.watch(&unit.root, id).map(|()| id))
}

#[derive(Clone, Debug)]
pub(crate) struct Device {
    pub(crate) dev: libc::dev_t,
    pub(crate) fs: String,
    pub(crate) flags: u32,
    pub(crate) mount: bool,
    pub(crate) no_log: i32,
    pub(crate) history: u128,
    pub(crate) last: u64,
}

impl Device {
    pub(crate) fn read(root: &Path) -> Option<Device> {
        let dev = fs::symlink_metadata(root).ok()?.dev() as libc::dev_t;
        let path = std::ffi::CString::new(root.as_os_str().as_bytes()).ok()?;
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statfs(path.as_ptr(), &mut st) } != 0 {
            return None;
        }
        let text = |chars: &[libc::c_char]| unsafe { std::ffi::CStr::from_ptr(chars.as_ptr()) };
        Some(Device {
            dev,
            fs: text(&st.f_fstypename).to_string_lossy().into_owned(),
            flags: st.f_flags,
            mount: text(&st.f_mntonname).to_bytes() == root.as_os_str().as_bytes(),
            no_log: fs::symlink_metadata(root.join(".fseventsd/no_log"))
                .err()
                .map_or(0, |e| e.raw_os_error().unwrap_or(0)),
            history: history_of(dev),
            last: fsevents::last_id_before(dev, engine::now_secs() as f64).unwrap_or(0),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Start {
    Path,
    Crawl(OnDevice),
    Replay(OnDevice),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct OnDevice {
    pub(crate) dev: libc::dev_t,
    pub(crate) from: u64,
    pub(crate) history: u128,
}

pub(crate) fn trust(d: &Device, saved: Option<(u64, u128)>) -> Start {
    let keeps = matches!(d.fs.as_str(), "apfs" | "hfs")
        && d.flags & libc::MNT_LOCAL as u32 != 0
        && d.flags & libc::MNT_RDONLY as u32 == 0
        && d.no_log == libc::ENOENT
        && d.mount;
    if !keeps || d.history == 0 || d.last == 0 {
        return Start::Path;
    }
    let on = |from| OnDevice {
        dev: d.dev,
        from,
        history: d.history,
    };
    match saved {
        Some((s, history)) if s != 0 && history == d.history && d.last >= s => Start::Replay(on(s)),
        _ => Start::Crawl(on(d.last)),
    }
}

fn start(unit: &Unit, saved: Option<&Index>) -> Start {
    let saved = saved.map(|i| (i.event_id(), i.history()));
    #[cfg(test)]
    if let Some(d) = unit
        .facts
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
    {
        return trust(&d, saved);
    }
    unit.id
        .as_ref()
        .and_then(|_| Device::read(&unit.root))
        .map_or(Start::Path, |d| trust(&d, saved))
}

pub(crate) fn progress<'a>(shared: &'a Shared, unit: &'a Unit) -> impl Fn(u64) + Sync + 'a {
    move |listed| {
        unit.grow(listed);
        shared.report();
    }
}

pub(crate) fn build(
    shared: &Shared,
    unit: &Unit,
    crawl: Crawl,
    event_id: u64,
    synced_at: u64,
) -> Option<Index> {
    if unit.stopped() {
        return None;
    }
    let mut index = match Index::build_until(
        crawl,
        unit.root.clone(),
        &unit.print,
        event_id,
        synced_at,
        &|| unit.stopped(),
    ) {
        Ok(index) => index,
        Err(EngineError::Stopped) => return None,
        Err(e) => {
            shared.fault(e.to_string());
            return None;
        }
    };
    unit.stamp(&mut index);
    if unit.stopped() && (unit.id.is_some() || !shared.stopped()) {
        return None;
    }
    #[cfg(test)]
    wait_at(&shared.save_hold);
    if let Err(e) = index.save(&unit.file) {
        shared.fault(format!("{e}; the next launch crawls again"));
    }
    Some(index)
}

fn history_of(dev: libc::dev_t) -> u128 {
    fsevents::device_uuid(dev)
        .and_then(|uuid| u128::from_str_radix(&uuid.replace('-', ""), 16).ok())
        .unwrap_or(0)
}

pub(crate) fn kept_history(unit: &Unit) -> u128 {
    let dev = unit.watcher().device;
    let uuid = *unit.history.lock().unwrap_or_else(PoisonError::into_inner);
    if unit.id.is_none() && dev == 0 {
        return if uuid != 0 && unit.boot_history() == uuid {
            uuid
        } else {
            0
        };
    }
    let same = dev != 0
        && uuid != 0
        && fs::symlink_metadata(&unit.root).is_ok_and(|m| m.dev() as libc::dev_t == dev)
        && history_of(dev) == uuid;
    if same { uuid } else { 0 }
}

pub(crate) fn inputs(settings: &Settings, id: &str, root: &Path) -> (Vec<PathBuf>, Vec<u8>) {
    let exclusions = settings.exclusions();
    let mut inside: Vec<PathBuf> = (exclusions.excluded.iter())
        .filter(|p| p.starts_with(root))
        .cloned()
        .chain(exclusions.inside(id, root))
        .collect();
    inside.sort();
    inside.dedup();
    let mut print = id.as_bytes().to_vec();
    print.push(0);
    for p in &inside {
        print.extend_from_slice(p.strip_prefix(root).unwrap_or(p).as_os_str().as_bytes());
        print.push(0);
    }
    (inside, print)
}

pub(crate) fn uuid_shaped(id: &str) -> bool {
    id.len() == 36
        && id.char_indices().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

pub(crate) fn mount(shared: &Shared, unit: &Unit, batches: &Receiver<Vec<Event>>) {
    if !fs::canonicalize(&unit.root).is_ok_and(|real| real == unit.root && real.is_dir()) {
        shared
            .units
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|u| !std::ptr::eq(Arc::as_ptr(u), unit));
        shared.report();
        shared.fault(format!(
            "{}: not a folder, so it is not indexed",
            unit.root.display()
        ));
        return;
    }
    let around: Vec<Arc<Unit>> = shared
        .units()
        .iter()
        .filter(|u| u.root != unit.root && unit.root.starts_with(&u.root))
        .cloned()
        .collect();
    let mut purged = false;
    for u in &around {
        purged |= purge(u, &unit.root, &unit.stop);
    }
    drop(around);
    if purged {
        shared.report();
        let _ = shared.listener.results_changed(false);
    }
    drop(shared.units.write().unwrap_or_else(PoisonError::into_inner));
    if unit.stopped() {
        return;
    }
    let saved = saved(shared, unit);
    let start = start(unit, saved.as_ref());
    let had_saved = saved.is_some();
    if let Some(index) = saved {
        if unit.id.is_none() {
            unit.install(shared, index, EnginePhase::Loading);
            let started = unit.watch_saved_boot();
            unit.set_phase(EnginePhase::Ready);
            shared.report();
            let _ = shared.listener.results_changed(false);
            match started {
                Ok(()) => apply::run(shared, unit, batches),
                Err(e) if !unit.stopped() => {
                    unit.live_off(shared, &e);
                    shared.report();
                }
                Err(_) => {}
            }
            return;
        }
        unit.install(shared, index, EnginePhase::Loading);
        let _ = shared.listener.results_changed(false);
    }
    if let Start::Replay(on) = start
        && replay(shared, unit, on, batches)
    {
        return;
    }
    let start = if let Start::Replay(_) = start {
        Start::Path
    } else {
        start
    };
    let mut event_id = stream(shared, unit, start);
    if event_id != 0 && had_saved && unit.watcher().current() == 0 {
        unit.waiting.store(true, Ordering::Relaxed);
        unit.set_phase(EnginePhase::Ready);
        shared.report();
        let from = loop {
            if batches.recv().is_err() || unit.stopped() {
                return;
            }
            if let Some(from) = unit.resume_from() {
                break from;
            }
        };
        if let Err(e) = unit.watch(from) {
            unit.live_off(shared, &e);
            event_id = 0;
        }
    }
    unit.set_phase(EnginePhase::Crawling);
    shared.report();
    #[cfg(test)]
    crawl::OPENED.set(
        shared
            .opened
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take(),
    );
    #[cfg(test)]
    shared.crawled(unit);
    let synced_at = engine::now_secs();
    let partial = unit.begin(shared);
    let publish = |listings: &[crawl::Listing]| unit.publish(shared, listings);
    let crawl = match crawl::scan_root(
        &unit.pool,
        &unit.root,
        &unit.skip,
        &unit.stop,
        &progress(shared, unit),
        partial.then_some(&publish),
    ) {
        Ok(crawl) => crawl,
        Err(e) => {
            if !unit.stopped() {
                unit.watcher().close();
                let loaded = unit
                    .live
                    .write()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take();
                unit.set_trouble(EngineTroubleKind::Unreadable);
                unit.set(EnginePhase::Failed, 0);
                shared.fault(format!(
                    "{}: {e}, so it is not indexed",
                    unit.root.display()
                ));
                shared.report();
                if let Some(loaded) = loaded {
                    sort::forget(&loaded.base);
                    let _ = shared.listener.results_changed(false);
                }
            }
            return;
        }
    };
    unit.finish(shared);
    let Some(index) = build(shared, unit, crawl, event_id, synced_at) else {
        if !unit.stopped() {
            unit.set_phase(EnginePhase::Failed);
            shared.report();
        }
        return;
    };
    unit.waiting.store(false, Ordering::Relaxed);
    unit.install(shared, index, EnginePhase::Ready);
    shared.report();
    unit.refreshed(shared, || {});
    if event_id != 0 {
        apply::run(shared, unit, batches);
    }
}

fn replay(shared: &Shared, unit: &Unit, on: OnDevice, batches: &Receiver<Vec<Event>>) -> bool {
    let Some(synced) = unit.read(|l| l.synced_at) else {
        return false;
    };
    unit.set_owed(Some((on.from, synced)));
    if let Err(e) = begin(unit, Start::Replay(on)) {
        unit.set_owed(None);
        if unit.stopped() {
            return true;
        }
        shared.fault(format!(
            "{}: no replay, so a crawl: {e}",
            unit.root.display()
        ));
        return false;
    }
    unit.set_phase(EnginePhase::Ready);
    shared.report();
    apply::run(shared, unit, batches);
    true
}

pub(crate) fn rebuild_inputs(settings: &Settings, old: &Unit) -> Option<(Vec<PathBuf>, Vec<u8>)> {
    let (skip, print) = match &old.id {
        None => settings.boot_inputs(),
        Some(id) => inputs(settings, id, &old.root),
    };
    if old.print == print
        && old
            .skip
            .iter()
            .filter(|p| p.starts_with(&old.root))
            .eq(skip.iter().filter(|p| p.starts_with(&old.root)))
    {
        None
    } else {
        Some((skip, print))
    }
}

pub(crate) fn rebuild(shared: &Arc<Shared>, stop: &AtomicBool) {
    let units = shared.units().to_vec();
    for old in units {
        if let Err(panic) =
            panic::catch_unwind(AssertUnwindSafe(|| rebuild_one(shared, &old, stop)))
        {
            old.rebuilding(None);
            shared.fault(format!(
                "{}: excluded folders not applied: {}",
                old.root.display(),
                engine::said(&*panic)
            ));
            shared.report();
        }
        if stop.load(Ordering::Relaxed) {
            return;
        }
    }
}

fn rebuild_one(shared: &Arc<Shared>, old: &Arc<Unit>, stop: &AtomicBool) {
    let Some((skip, print)) = rebuild_inputs(&shared.settings, old) else {
        return;
    };
    let crawl = recrawls(shared, old, &skip);
    let failed = || old.status().0 == EnginePhase::Failed;
    while !matches!(old.status().0, EnginePhase::Ready | EnginePhase::Live)
        || old.read(|_| ()).is_none()
    {
        if stop.load(Ordering::Relaxed) || old.stopped() || failed() {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    if !stop.load(Ordering::Relaxed) && !old.stopped() && !failed() {
        let crawl = crawl || old.waiting.load(Ordering::Relaxed);
        replace(shared, old, (skip, print), crawl, stop);
    }
}

fn recrawls(shared: &Shared, old: &Unit, skip: &[PathBuf]) -> bool {
    let nested = shared.nested(&old.root);
    let owned = |list: &[PathBuf]| -> Vec<PathBuf> {
        list.iter()
            .filter(|p| {
                p.starts_with(&old.root)
                    && !nested.iter().any(|n| p.starts_with(n))
                    && !(old.id.is_none() && shared.settings.other_volume(p))
            })
            .cloned()
            .collect()
    };
    owned(&old.skip) != owned(skip)
}

fn successor(
    shared: &Shared,
    old: &Unit,
    inputs: (Vec<PathBuf>, Vec<u8>),
) -> Option<(Arc<Unit>, Receiver<Vec<Event>>)> {
    let (events, batches) = mpsc::channel();
    let pool = Pool::new(engine::CRAWL_THREADS)
        .map_err(|e| shared.fault(format!("excluded folders not applied: {e}")))
        .ok()?;
    let mut new = Unit::new(
        old.root.clone(),
        old.id.clone(),
        old.file.clone(),
        inputs,
        pool,
        events,
        shared.settings.paused.clone(),
    );
    let device = old.watcher().device;
    new.watcher().device = device;
    new.set_history(*old.history.lock().unwrap_or_else(PoisonError::into_inner));
    new.set_owed(old.owed());
    new.os_build = old.os_build;
    new.relist
        .store(old.relist.load(Ordering::Relaxed), Ordering::Relaxed);
    Some((Arc::new(new), batches))
}

pub(crate) fn renew(shared: &Arc<Shared>) {
    let units = shared.units().to_vec();
    let mut renewed = false;
    for old in units {
        let Some(inputs) = rebuild_inputs(&shared.settings, &old)
            .filter(|(skip, _)| old.read(|_| ()).is_none() && recrawls(shared, &old, skip))
        else {
            continue;
        };
        let Some((new, batches)) = successor(shared, &old, inputs) else {
            continue;
        };
        let (go, gate) = mpsc::channel::<Option<JoinHandle<()>>>();
        let started = engine::spawn("wherever-unit", {
            let (shared, new) = (shared.clone(), new.clone());
            move || {
                if let Ok(before) = gate.recv() {
                    if let Some(before) = before {
                        let _ = before.join();
                    }
                    new.guard(&shared, || mount(&shared, &new, &batches));
                }
            }
        });
        match started {
            Ok(thread) => *new.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread),
            Err(e) => {
                shared.fault(format!("excluded folders not applied: {e}"));
                continue;
            }
        }
        {
            let mut units = shared.units.write().unwrap_or_else(PoisonError::into_inner);
            let Some(slot) = units
                .iter()
                .position(|u| Arc::ptr_eq(u, &old))
                .filter(|_| old.read(|_| ()).is_none())
            else {
                continue;
            };
            let (phase, entries) = old.status();
            new.set(phase, entries);
            *new.kept.lock().unwrap_or_else(PoisonError::into_inner) = old.partial();
            old.stop.store(true, Ordering::Relaxed);
            units[slot] = new;
        }
        old.watcher().close();
        let before = old
            .thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let _ = go.send(before);
        renewed = true;
    }
    if renewed {
        shared.report();
        let _ = shared.listener.results_changed(false);
    }
}

fn replace(
    shared: &Arc<Shared>,
    old: &Arc<Unit>,
    inputs: (Vec<PathBuf>, Vec<u8>),
    crawl: bool,
    stop: &AtomicBool,
) {
    let Some((new, batches)) = successor(shared, old, inputs) else {
        return;
    };
    let cancelled = || stop.load(Ordering::Relaxed) || old.stopped() || new.stopped();
    let built = if crawl {
        old.rebuilding(Some((EnginePhase::Crawling, 0)));
        shared.report();
        new.set_owed(None);
        new.relist.store(false, Ordering::Relaxed);
        let event_id = watch_from_now(shared, &new);
        #[cfg(test)]
        {
            crawl::OPENED.set(
                shared
                    .opened
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take(),
            );
            shared.crawled(&new);
        }
        let synced_at = engine::now_secs();
        let progress = |listed| {
            old.rebuilding(Some((EnginePhase::Crawling, listed)));
            shared.report();
        };
        crawl::scan_root(&new.pool, &new.root, &new.skip, stop, &progress, None)
            .map_err(|e| shared.fault(format!("{}: {e}", new.root.display())))
            .ok()
            .filter(|_| !stop.load(Ordering::Relaxed))
            .and_then(|crawl| {
                old.rebuilding(Some((EnginePhase::Finishing, old.status().1)));
                shared.report();
                Index::build_until(
                    crawl,
                    new.root.clone(),
                    &new.print,
                    event_id,
                    synced_at,
                    &cancelled,
                )
                .map_err(|e| {
                    if !matches!(e, EngineError::Stopped) {
                        shared.fault(e.to_string());
                    }
                })
                .ok()
            })
            .map(|mut index| {
                new.stamp(&mut index);
                (index, event_id != 0)
            })
    } else {
        let folded = (|| {
            let (crawl, (event_id, synced_at), skips) =
                old.read(|l| (l.to_crawl(), old.kept(l), l.base.skipped().to_vec()))?;
            let index = Index::build_until(
                crawl,
                new.root.clone(),
                &new.print,
                event_id,
                synced_at,
                &cancelled,
            )
            .map_err(|e| {
                if !matches!(e, EngineError::Stopped) {
                    shared.fault(e.to_string());
                }
            })
            .ok()?;
            let mut index = refilter(shared, &new, index, &old.skip, stop)?;
            index.set_skips(skips);
            new.stamp(&mut index);
            (!stop.load(Ordering::Relaxed) && !old.stopped()).then_some(index)
        })();
        folded.map(|index| {
            let started = new.watch(index.event_id());
            if let Err(e) = &started {
                new.live_off(shared, e);
            }
            (index, started.is_ok())
        })
    };
    let swapped = built.and_then(|(index, watching)| {
        new.install(shared, index, EnginePhase::Ready);
        if let Some(base) = new.read(|l| l.base.clone()) {
            shared.premerge(old, &base);
        }
        #[cfg(test)]
        wait_at(&shared.swap_hold);
        let phase = if crawl {
            EnginePhase::Finishing
        } else {
            EnginePhase::Ready
        };
        register_replacement(shared, old, &new, stop, phase).then_some(watching)
    });
    let Some(watching) = swapped else {
        old.rebuilding(None);
        if crawl {
            shared.report();
        }
        return;
    };
    new.watcher().follow_switch();
    old.stop.store(true, Ordering::Relaxed);
    old.watcher().close();
    new.guard(shared, || {
        let thread = old
            .thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(thread) = thread {
            let _ = thread.join();
        }
        if let Some(base) = old.read(|l| l.base.clone()) {
            sort::forget(&base);
        }
        shared.report();
        let _ = shared.listener.results_changed(false);
        #[cfg(test)]
        wait_at(&shared.save_hold);
        if let Some(base) = new.read(|l| l.base.clone())
            && let Err(e) = base.save(&new.file)
        {
            shared.fault(format!("{e}; the next launch crawls again"));
        }
        if crawl {
            new.set_phase(EnginePhase::Ready);
            shared.report();
        }
        if watching {
            let started = engine::spawn("wherever-live", {
                let (shared, new) = (shared.clone(), new.clone());
                move || new.guard(&shared, || apply::run(&shared, &new, &batches))
            });
            match started {
                Ok(thread) => {
                    *new.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread)
                }
                Err(e) => {
                    new.live_off(shared, &e.to_string());
                    shared.report();
                }
            }
        }
    });
}

fn register_replacement(
    shared: &Shared,
    old: &Arc<Unit>,
    new: &Arc<Unit>,
    stop: &AtomicBool,
    phase: EnginePhase,
) -> bool {
    let mut units = shared.units.write().unwrap_or_else(PoisonError::into_inner);
    let Some(slot) = units.iter().position(|u| Arc::ptr_eq(u, old)) else {
        return false;
    };
    if stop.load(Ordering::Relaxed) {
        return false;
    }
    let entries = new
        .write(|live| {
            for unit in units
                .iter()
                .filter(|u| u.root != new.root && u.root.starts_with(&new.root))
            {
                live.drop_below(unit.root.as_os_str().as_bytes());
            }
            live.entries()
        })
        .unwrap();
    new.set(phase, entries);
    units[slot] = new.clone();
    true
}

#[cfg(test)]
fn wait_at(hold: &Mutex<Option<(Sender<()>, Receiver<()>)>>) {
    let held = hold.lock().unwrap_or_else(PoisonError::into_inner).take();
    if let Some((reached, go)) = held {
        let _ = reached.send(());
        let _ = go.recv();
    }
}

fn refilter(
    shared: &Shared,
    unit: &Unit,
    index: Index,
    restore: &[PathBuf],
    stop: &AtomicBool,
) -> Option<Index> {
    let (event_id, synced_at, skips, history, os_build) = (
        index.event_id(),
        index.synced_at(),
        index.skipped().to_vec(),
        index.history(),
        index.os_build(),
    );
    let mut live = Live::new(Arc::new(index));
    for path in &unit.skip {
        live.drop_below(path.as_os_str().as_bytes());
    }
    let nested = shared.nested(&unit.root);
    let skip = [unit.skip.clone(), nested.clone()].concat();
    let disk = Disk {
        pool: &unit.pool,
        skip: &skip,
        stop,
    };
    for path in restore {
        if !crawl::blocked(&skip, path) && owns(&unit.root, &nested, path, &mut crawl::is_mount) {
            let fetched = live.fetch(path.as_os_str().as_bytes(), true, &disk);
            live.apply(fetched, &disk);
        }
        if stop.load(Ordering::Relaxed) {
            return None;
        }
    }
    let mut index = if live.pending() == 0 {
        Arc::into_inner(live.base).expect("the unpublished index has one owner")
    } else {
        Index::build_until(
            live.to_crawl(),
            unit.root.clone(),
            &unit.print,
            event_id,
            synced_at,
            &|| stop.load(Ordering::Relaxed) || unit.stopped(),
        )
        .map_err(|e| {
            if !matches!(e, EngineError::Stopped) {
                shared.fault(e.to_string());
            }
        })
        .ok()?
    };
    index.set_skips(skips);
    index.set_history(history);
    index.set_os_build(&os_build);
    (!stop.load(Ordering::Relaxed)).then_some(index)
}

pub(crate) fn clean(data: &Path, indexed: &[String]) {
    let Ok(dir) = fs::read_dir(data) else {
        return;
    };
    let now = SystemTime::now();
    for e in dir.flatten() {
        let name = e.file_name();
        let name = name.as_bytes();
        let temp = name.ends_with(b".tmp")
            && [index::FILE, opens::FILE, "volume-"]
                .iter()
                .any(|stem| name.starts_with(stem.as_bytes()));
        let keep = if temp {
            KEEP_TEMPS
        } else if let Some(id) = name
            .strip_prefix(b"volume-")
            .and_then(|n| n.strip_suffix(b".index"))
        {
            if indexed.iter().any(|on| on.as_bytes() == id) {
                continue;
            }
            KEEP_FILES
        } else {
            continue;
        };
        if e.metadata()
            .and_then(|m| m.modified())
            .is_ok_and(|t| now.duration_since(t).is_ok_and(|age| age > keep))
        {
            let _ = fs::remove_file(e.path());
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crawl::tests::{Locked, TempTree};
    use crate::engine::tests::{
        Event as Heard, PAST_LATENCY, Recorder, changed, config, count, found, next, phases,
        pressed, ready, rebuilt, seek, shared, start, start_in_volumes, start_with, switched,
        texts, until_live,
    };
    use crate::engine::{BEST_MATCH, CRAWL_THREADS, Engine};
    use crate::fsevents::MUST_SCAN_SUBDIRS;
    use crate::{EngineError, EngineKind, EngineState, EngineTrouble, EngineVolume};
    use std::ffi::{CStr, OsStr};

    #[test]
    fn a_replacement_excludes_disks_registered_after_its_build() {
        let tree = TempTree::new("replace-disk-handoff");
        let (shared, old, _rx) = engine::tests::bench(config(&tree));
        let make = |root: PathBuf, id| {
            Arc::new(Unit::new(
                root,
                id,
                old.file.clone(),
                (Vec::new(), Vec::new()),
                Pool::new(2).unwrap(),
                mpsc::channel().0,
                Arc::default(),
            ))
        };
        let new = make(old.root.clone(), None);
        new.set(
            EnginePhase::Ready,
            new.put(&shared, Live::new(old.read(|l| l.base.clone()).unwrap())),
        );
        let disk = make(old.root.join("Sub"), Some("dupearly".to_owned()));
        shared.units.write().unwrap().push(disk.clone());
        purge(&old, &disk.root, &disk.stop);
        let crawl = crawl::scan_path(&disk.pool, &disk.root, &disk.skip, &disk.stop);
        let index = Index::build(crawl, disk.root.clone(), &[], 1000, engine::now_secs()).unwrap();
        disk.install(&shared, index, EnginePhase::Ready);
        assert!(register_replacement(
            &shared,
            &old,
            &new,
            &new.stop,
            EnginePhase::Ready
        ));
        let rows: Vec<_> = shared
            .units()
            .iter()
            .flat_map(|unit| {
                unit.read(|live| live.find("delta", || false).unwrap().rows(0, usize::MAX))
                    .unwrap()
            })
            .map(|h| (h.name, h.folder))
            .collect();
        assert_eq!(
            rows,
            [(
                "DELTA.Txt".to_owned(),
                disk.root.to_str().unwrap().to_owned()
            )]
        );
        assert_eq!(new.status().1, new.read(Live::entries).unwrap());
    }

    fn streams_its_device(unit: &Unit) -> u128 {
        let dev = fs::metadata(&unit.root).unwrap().dev() as libc::dev_t;
        let uuid = history_of(dev);
        assert_ne!(
            uuid, 0,
            "FSEvents keeps no history for the temp folder's volume"
        );
        unit.watcher().device = dev;
        unit.set_history(uuid);
        uuid
    }

    #[test]
    fn a_fold_and_a_refilter_keep_the_history_uuid() {
        let tree = TempTree::new("history-fold");
        let (shared, unit, _rx) = engine::tests::bench(config(&tree));
        let uuid = streams_its_device(&unit);
        let index = apply::fold(&shared, &unit, &unit).unwrap();
        assert_eq!(index.history(), uuid);
        assert_eq!(index.os_build(), unit.os_build);
        unit.install(&shared, index, EnginePhase::Ready);
        assert_eq!(apply::fold(&shared, &unit, &unit).unwrap().history(), uuid);
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert_eq!(saved.history(), uuid);
        let entries = saved.entries();
        let skipping = Unit::new(
            unit.root.clone(),
            None,
            unit.file.clone(),
            (vec![unit.root.join("Sub")], Vec::new()),
            Pool::new(1).unwrap(),
            mpsc::channel().0,
            Arc::default(),
        );
        let refiltered = refilter(&shared, &skipping, saved, &[], &AtomicBool::new(false)).unwrap();
        assert!(
            refiltered.entries() < entries,
            "the refilter rebuilt nothing"
        );
        assert_eq!(refiltered.history(), uuid);
        assert_eq!(refiltered.os_build(), unit.os_build);
    }

    #[test]
    fn a_boot_rebuild_keeps_an_unfinished_relist_untrusted() {
        let tree = TempTree::new("boot-relist-rebuild");
        let (shared, old, _rx) = engine::tests::bench(config(&tree));
        old.set_history(old.boot_history());
        old.relist.store(true, Ordering::Relaxed);
        let (new, _batches) =
            successor(&shared, &old, (old.skip.clone(), old.print.clone())).unwrap();
        let index = apply::fold(&shared, &old, &new).unwrap();
        assert!(new.relist.load(Ordering::Relaxed));
        assert_eq!(index.os_build(), [0; index::OS_BUILD_BYTES]);
        assert_ne!(index.history(), 0);
        new.install(&shared, index, EnginePhase::Loading);
        new.watch_saved_boot().unwrap();
        assert!(new.relist.load(Ordering::Relaxed));
        assert_eq!(hits(&new, "beta"), 1);
    }

    #[test]
    fn a_rebuilt_disk_on_its_roots_path_saves_no_history() {
        let boot = TempTree::new("history-rebuild");
        let outer = drive("history-rebuild-outer");
        let outer_root = PathBuf::from(outer.real());
        let inner = outer_root.join("Inner");
        fs::create_dir_all(inner.join("Skip")).unwrap();
        fs::write(inner.join("Skip/gone.txt"), b"").unwrap();
        let dev = fs::metadata(&inner).unwrap().dev() as libc::dev_t;
        assert_ne!(
            history_of(dev),
            0,
            "FSEvents keeps no history for the temp folder's volume"
        );
        let want = 0;
        let saved = |id: &str, root: &Path| {
            let index = Index::load(&file(&boot, id), root.to_path_buf()).unwrap();
            index.history()
        };
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine
            .set_volumes(vec![
                vol(&outer, A),
                EngineVolume {
                    root: given(inner.clone()),
                    id: B.to_owned(),
                },
            ])
            .unwrap();
        settle(&engine);
        assert_eq!(saved(A, &outer_root), want);
        assert_eq!(saved(B, &inner), want);
        let boot_file = Index::load(&boot.data().join(index::FILE), PathBuf::from(boot.real()));
        assert_eq!(boot_file.unwrap().history(), history_of(dev));
        let crawls = |root: &Path| {
            let crawls = shared(&engine).crawls.lock().unwrap();
            crawls.iter().filter(|r| *r == root).count()
        };
        assert_eq!((crawls(&outer_root), crawls(&inner)), (1, 1));
        let before = (stamp(&file(&boot, A)), stamp(&file(&boot, B)));
        engine
            .set_excluded(vec![given(inner.join("Skip"))])
            .unwrap();
        rebuilt(&engine);
        assert_eq!((crawls(&outer_root), crawls(&inner)), (1, 2));
        assert_ne!(
            stamp(&file(&boot, A)),
            before.0,
            "the outer disk saved no fold"
        );
        assert_ne!(
            stamp(&file(&boot, B)),
            before.1,
            "the inner disk saved no crawl"
        );
        assert_eq!(saved(A, &outer_root), want);
        assert_eq!(saved(B, &inner), want);
    }

    fn data_disk(tree: &TempTree, events: Sender<Vec<Event>>) -> (Shared, Unit, libc::dev_t) {
        let (shared, _boot, _heard) = engine::tests::bench(config(tree));
        let root = PathBuf::from("/System/Volumes/Data");
        let dev = fs::metadata(&root).unwrap().dev() as libc::dev_t;
        let disk = Unit::new(
            root,
            Some("data".to_owned()),
            tree.data().join("volume-data.index"),
            (Vec::new(), Vec::new()),
            Pool::new(1).unwrap(),
            events,
            Arc::default(),
        );
        (shared, disk, dev)
    }

    fn ignore_ownership(disk: &Unit) {
        let mut d = Device::read(&disk.root).unwrap();
        assert!(d.mount, "{} is not a mount point", disk.root.display());
        d.no_log = libc::ENOENT;
        *disk.facts.lock().unwrap() = Some(d);
    }

    #[test]
    fn a_device_stream_reports_a_new_file_under_the_disk_root() {
        let tree = TempTree::new("device-stream");
        let (events, batches) = mpsc::channel();
        let (shared, disk, dev) = data_disk(&tree, events);
        assert_eq!(
            fs::metadata(&tree.0).unwrap().dev() as libc::dev_t,
            dev,
            "the temp folder is not on the Data volume"
        );
        let last = || fsevents::last_id_before(dev, engine::now_secs() as f64).unwrap();
        let before = last();
        ignore_ownership(&disk);
        let since = watch_from_now(&shared, &disk);
        let after = last();
        assert!(
            before != 0 && (before..=after).contains(&since),
            "the stream started at {since}, not at the device's last id ({before} to {after})"
        );
        assert_eq!(disk.watcher().watched_device(), dev);
        fs::create_dir(tree.0.join("Later")).unwrap();
        fs::write(tree.0.join("Later/fresh.txt"), b"").unwrap();
        let want = format!("{}{}/Later", disk.root.display(), tree.real());
        let stream = disk.watcher().count;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "no event named {want}");
            let Ok(batch) = batches.recv_timeout(left) else {
                panic!("no event named {want}");
            };
            if batch
                .iter()
                .any(|e| e.stream == stream && crate::live::normalize(&e.path) == want.as_bytes())
            {
                break;
            }
        }
    }

    #[test]
    fn a_restart_keeps_the_device_stream() {
        let tree = TempTree::new("device-restart");
        let (shared, disk, dev) = data_disk(&tree, mpsc::channel().0);
        ignore_ownership(&disk);
        let since = watch_from_now(&shared, &disk);
        assert_ne!(since, 0);
        assert_eq!(disk.watcher().watched_device(), dev);
        disk.watch(since).unwrap();
        {
            let w = disk.watcher();
            assert_eq!((w.watched_device(), w.count, w.since), (dev, 2, since));
        }
        let (new, _batches) = successor(&shared, &disk, (Vec::new(), Vec::new())).unwrap();
        new.watch(since).unwrap();
        assert_eq!(new.watcher().watched_device(), dev);
    }
    const HISTORY: u128 = 0x0011_2233_4455_6677_8899_aabb_ccdd_eeff;
    const SAVED: Option<(u64, u128)> = Some((500, HISTORY));

    fn apfs() -> Device {
        Device {
            dev: 7,
            fs: "apfs".to_owned(),
            flags: libc::MNT_LOCAL as u32,
            mount: true,
            no_log: libc::ENOENT,
            history: HISTORY,
            last: 900,
        }
    }

    fn on(from: u64) -> OnDevice {
        OnDevice {
            dev: 7,
            from,
            history: HISTORY,
        }
    }

    #[test]
    fn same_history_replays() {
        assert_eq!(trust(&apfs(), SAVED), Start::Replay(on(500)));
        let still = Device {
            last: 500,
            ..apfs()
        };
        assert_eq!(trust(&still, SAVED), Start::Replay(on(500)));
        let folder = Device {
            mount: false,
            ..apfs()
        };
        assert_eq!(trust(&folder, SAVED), Start::Path);
    }

    #[test]
    fn hfs_replays_like_apfs() {
        let hfs = Device {
            fs: "hfs".to_owned(),
            ..apfs()
        };
        assert_eq!(trust(&hfs, SAVED), Start::Replay(on(500)));
    }

    #[test]
    fn another_volume_uuid_crawls() {
        let tree = TempTree::new("trust-volume");
        let (shared, _boot, _rx) = engine::tests::bench(config(&tree));
        let disk = drive("trust-volume-disk");
        let root = PathBuf::from(disk.real());
        let unit = Unit::new(
            root.clone(),
            Some(A.to_owned()),
            tree.data().join(format!("volume-{A}.index")),
            inputs(&shared.settings, A, &root),
            Pool::new(1).unwrap(),
            mpsc::channel().0,
            Arc::default(),
        );
        *unit.facts.lock().unwrap() = Some(apfs());
        let save = |print: &[u8]| {
            let crawl = crawl::scan_path(&unit.pool, &root, &[], &unit.stop);
            let mut index =
                Index::build(crawl, root.clone(), print, 500, engine::now_secs()).unwrap();
            index.set_history(HISTORY);
            index.save(&unit.file).unwrap();
        };
        save(&inputs(&shared.settings, B, &root).1);
        let other = saved(&shared, &unit);
        assert!(other.is_none(), "another volume's file loaded");
        assert_eq!(super::start(&unit, other.as_ref()), Start::Crawl(on(900)));
        save(&unit.print);
        assert_eq!(
            super::start(&unit, saved(&shared, &unit).as_ref()),
            Start::Replay(on(500))
        );
    }

    #[test]
    fn a_new_history_uuid_crawls() {
        assert_eq!(
            trust(&apfs(), Some((500, HISTORY ^ 1))),
            Start::Crawl(on(900))
        );
        assert_eq!(trust(&apfs(), Some((500, 0))), Start::Crawl(on(900)));
    }

    #[test]
    fn no_history_uuid_keeps_the_host_stream() {
        let none = Device {
            history: 0,
            ..apfs()
        };
        assert_eq!(trust(&none, SAVED), Start::Path);
        assert_eq!(trust(&none, None), Start::Path);
    }

    #[test]
    fn a_device_id_below_the_saved_id_crawls() {
        let restored = Device {
            last: 499,
            ..apfs()
        };
        assert_eq!(trust(&restored, SAVED), Start::Crawl(on(499)));
    }

    #[test]
    fn a_device_last_id_of_zero_keeps_the_host_stream() {
        let fresh = Device { last: 0, ..apfs() };
        assert_eq!(trust(&fresh, None), Start::Path);
        assert_eq!(trust(&fresh, SAVED), Start::Path);
        let tree = TempTree::new("trust-last-zero");
        let (shared, boot, _rx) = engine::tests::bench(config(&tree));
        let unit = Unit::new(
            boot.root.clone(),
            Some(A.to_owned()),
            boot.file.clone(),
            (Vec::new(), Vec::new()),
            Pool::new(1).unwrap(),
            mpsc::channel().0,
            Arc::default(),
        );
        streams_its_device(&unit);
        let since = stream(&shared, &unit, trust(&fresh, None));
        assert_ne!(since, 0, "no stream, so the crawl could not replay");
        assert_eq!(unit.watcher().watched_device(), 0);
        assert_eq!(kept_history(&unit), 0);
        assert_eq!(
            trust(&apfs(), Some((since, kept_history(&unit)))),
            Start::Crawl(on(900))
        );
    }

    #[test]
    fn a_read_only_disk_crawls() {
        let locked = Device {
            flags: (libc::MNT_LOCAL | libc::MNT_RDONLY) as u32,
            ..apfs()
        };
        assert_eq!(trust(&locked, SAVED), Start::Path);
    }

    #[test]
    fn ntfs_exfat_and_fat_crawl() {
        for fs in ["ntfs", "exfat", "msdos"] {
            let d = Device {
                fs: fs.to_owned(),
                ..apfs()
            };
            assert_eq!(trust(&d, SAVED), Start::Path, "{fs}");
        }
    }

    #[test]
    fn a_network_disk_crawls() {
        let smb = Device {
            fs: "smbfs".to_owned(),
            flags: 0,
            ..apfs()
        };
        assert_eq!(trust(&smb, SAVED), Start::Path);
        let remote = Device { flags: 0, ..apfs() };
        assert_eq!(trust(&remote, SAVED), Start::Path);
    }

    #[test]
    fn a_disk_with_no_log_crawls() {
        for errno in [0, libc::EACCES] {
            let d = Device {
                no_log: errno,
                ..apfs()
            };
            assert_eq!(trust(&d, SAVED), Start::Path, "errno {errno}");
        }
        let disk = drive("trust-no-log");
        let root = PathBuf::from(disk.real());
        let read = Device::read(&root).unwrap();
        assert_eq!((read.no_log, read.mount), (libc::ENOENT, false));
        fs::create_dir(root.join(".fseventsd")).unwrap();
        fs::write(root.join(".fseventsd/no_log"), b"").unwrap();
        assert_eq!(Device::read(&root).unwrap().no_log, 0);
    }

    fn dated(path: &Path, ago: u64) {
        fs::File::open(path)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(ago))
            .unwrap();
    }

    fn hits(unit: &Unit, query: &str) -> usize {
        unit.read(|l| l.find(query, || false).unwrap().rows(0, usize::MAX).len())
            .unwrap()
    }

    #[test]
    fn a_moved_root_or_a_new_history_uuid_saves_no_history() {
        let tree = TempTree::new("history-moved");
        let (shared, unit, _rx) = engine::tests::bench(config(&tree));
        let uuid = streams_its_device(&unit);
        let history = || apply::fold(&shared, &unit, &unit).unwrap().history();
        assert_eq!(history(), uuid);
        unit.set_history(uuid ^ 1);
        assert_eq!(history(), 0, "a history UUID the device no longer reports");
        unit.set_history(uuid);
        let moved = PathBuf::from(format!("{}-moved", unit.root.display()));
        fs::rename(&unit.root, &moved).unwrap();
        let after = history();
        fs::rename(&moved, &unit.root).unwrap();
        assert_eq!(after, 0, "a root no longer on the device");
        assert_eq!(history(), uuid);
    }

    #[test]
    fn a_rebuild_during_a_replay_checks_again() {
        let tree = TempTree::new("replay-rebuild");
        let (shared, old, _rx) = engine::tests::bench(config(&tree));
        let uuid = streams_its_device(&old);
        let synced = engine::now_secs() - 1000;
        old.set_owed(Some((1000, synced)));
        old.write(|l| (l.event_id, l.synced_at) = (1500, engine::now_secs()));
        let (new, _batches) =
            successor(&shared, &old, (old.skip.clone(), old.print.clone())).unwrap();
        assert_eq!(new.owed(), Some((1000, synced)));
        let index = apply::fold(&shared, &old, &new).unwrap();
        assert_eq!(
            (index.event_id(), index.synced_at(), index.history()),
            (1000, synced, uuid)
        );
        new.install(&shared, index, EnginePhase::Ready);
        fs::write(tree.0.join("Sub/unheard.txt"), b"").unwrap();
        dated(&tree.0.join("Sub"), 500);
        {
            let mut w = new.watcher();
            (w.count, w.since, w.replaying) = (1, 1000, true);
        }
        let done = Event {
            path: tree.real().into_bytes(),
            flags: fsevents::HISTORY_DONE,
            id: 9000,
            stream: 1,
        };
        apply::step(
            &shared,
            &new,
            &mut apply::Apply::new(),
            vec![done],
            Instant::now(),
        );
        assert_eq!(new.owed(), None);
        assert_eq!(hits(&new, "unheard"), 1);
    }

    #[test]
    fn a_saved_disk_replays_at_mount_without_a_crawl() {
        let tree = TempTree::new("replay-mount");
        let (shared, _boot, _rx) = engine::tests::bench(config(&tree));
        let disk = drive("replay-mount-disk");
        let root = PathBuf::from(disk.real());
        let (events, batches) = mpsc::channel();
        let unit = Arc::new(Unit::new(
            root.clone(),
            Some(A.to_owned()),
            tree.data().join(format!("volume-{A}.index")),
            inputs(&shared.settings, A, &root),
            Pool::new(1).unwrap(),
            events,
            Arc::default(),
        ));
        let mut facts = Device::read(&root).unwrap();
        (facts.mount, facts.no_log) = (true, libc::ENOENT);
        assert!(
            facts.history != 0 && facts.last != 0,
            "the temp folder's volume keeps no history"
        );
        let synced = engine::now_secs() - 1000;
        let crawl = crawl::scan_path(&unit.pool, &root, &[], &unit.stop);
        let mut index = Index::build(crawl, root.clone(), &unit.print, facts.last, synced).unwrap();
        index.set_history(facts.history);
        index.save(&unit.file).unwrap();
        *unit.facts.lock().unwrap() = Some(facts.clone());
        fs::write(root.join("Sub/unheard.txt"), b"").unwrap();
        dated(&root.join("Sub"), 500);
        shared.units.write().unwrap().push(unit.clone());
        let saved = || {
            Index::load(&unit.file, root.clone())
                .ok()
                .map(|i| (i.event_id(), i.synced_at(), i.history()))
        };
        let (shared, unit) = (&shared, &unit);
        thread::scope(|s| {
            s.spawn(move || mount(shared, unit, &batches));
            let deadline = Instant::now() + Duration::from_secs(30);
            while saved().is_none_or(|(_, at, _)| at == synced) {
                assert!(Instant::now() < deadline, "the replay never saved");
                thread::sleep(Duration::from_millis(20));
            }
            unit.stop.store(true, Ordering::Relaxed);
            unit.watcher().close();
        });
        assert!(
            !shared.crawls.lock().unwrap().contains(&root),
            "the disk was crawled"
        );
        let (id, at, history) = saved().unwrap();
        assert!(id > facts.last && at > synced, "saved {id} at {at}");
        assert_eq!(history, facts.history);
        assert_eq!(hits(unit, "unheard"), 1);
    }

    #[test]
    #[ignore = "mounts the disk WHEREVER_PROBE_ROOT names, its file in WHEREVER_PROBE_DATA"]
    fn probe_disk_replay_matches_a_crawl() {
        use std::collections::HashMap;
        let var = |name: &str| {
            PathBuf::from(std::env::var_os(name).unwrap_or_else(|| panic!("set {name}")))
        };
        let root = fs::canonicalize(var("WHEREVER_PROBE_ROOT")).unwrap();
        let tree = TempTree::new("probe-replay");
        let (shared, _boot, _rx) = engine::tests::bench(config(&tree));
        let (events, batches) = mpsc::channel();
        let unit = Arc::new(Unit::new(
            root.clone(),
            Some(A.to_owned()),
            var("WHEREVER_PROBE_DATA").join(format!("volume-{A}.index")),
            inputs(&shared.settings, A, &root),
            Pool::new(CRAWL_THREADS).unwrap(),
            events,
            Arc::default(),
        ));
        let file = Index::load(&unit.file, root.clone()).ok();
        let verdict = trust(
            &Device::read(&root).unwrap(),
            file.map(|i| (i.event_id(), i.history())),
        );
        println!("verdict: {verdict:?}");
        shared.units.write().unwrap().push(unit.clone());
        let (shared, unit) = (&shared, &unit);
        thread::scope(|s| {
            s.spawn(move || mount(shared, unit, &batches));
            let deadline = Instant::now() + Duration::from_secs(3600);
            while unit.status().0 != EnginePhase::Live || unit.owed().is_some() {
                assert!(Instant::now() < deadline, "never live: {:?}", unit.status());
                thread::sleep(Duration::from_millis(100));
            }
            unit.stop.store(true, Ordering::Relaxed);
            unit.watcher().close();
        });
        println!("crawled: {}", shared.crawls.lock().unwrap().contains(&root));
        let pool = Pool::new(CRAWL_THREADS).unwrap();
        let crawl =
            crawl::scan_root(&pool, &root, &[], &AtomicBool::new(false), &|_| {}, None).unwrap();
        let fresh = Live::new(Arc::new(
            Index::build(crawl, root.clone(), &[], 1, 1).unwrap(),
        ));
        let rows = |l: &Live| -> HashMap<PathBuf, (u64, i64, EngineKind)> {
            l.find("", || false)
                .unwrap()
                .rows(0, usize::MAX)
                .into_iter()
                .map(|h| {
                    (
                        Path::new(&h.folder).join(&h.name),
                        (h.size, h.modified, h.kind),
                    )
                })
                .collect()
        };
        let (have, want) = (unit.read(rows).unwrap(), rows(&fresh));
        let missing: Vec<_> = want.keys().filter(|p| !have.contains_key(*p)).collect();
        let extra: Vec<_> = have.keys().filter(|p| !want.contains_key(*p)).collect();
        let changed: Vec<_> = want
            .iter()
            .filter(|(p, v)| have.get(*p).is_some_and(|h| h != *v))
            .map(|(p, _)| p)
            .collect();
        println!(
            "replay diff: missing {}, extra {}, changed {}",
            missing.len(),
            extra.len(),
            changed.len()
        );
        let dot = [missing, extra, changed]
            .concat()
            .into_iter()
            .filter(|p| {
                p.strip_prefix(&root)
                    .ok()
                    .and_then(|r| r.components().next())
                    .is_some_and(|c| c.as_os_str().as_bytes().starts_with(b"."))
            })
            .count();
        println!("replay diff, under a top-level dot name: {dot}");
    }

    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::AtomicUsize;
    use std::sync::{Barrier, mpsc};
    use std::thread;
    use std::time::Instant;

    const A: &str = "0A0A0A0A-0000-4000-8000-00000000000A";
    const B: &str = "0B0B0B0B-0000-4000-8000-00000000000B";
    const C: &str = "0C0C0C0C-0000-4000-8000-00000000000C";
    const D: &str = "0D0D0D0D-0000-4000-8000-00000000000D";
    const BOOT: u64 = 6;
    const DRIVE: u64 = 7;

    fn drive(name: &str) -> TempTree {
        let tree = TempTree::new(name);
        fs::write(tree.0.join(mark(name)), b"").unwrap();
        tree
    }

    fn mark(name: &str) -> String {
        format!("mark-{name}.txt")
    }

    fn vol(tree: &TempTree, id: &str) -> EngineVolume {
        EngineVolume {
            root: tree.real(),
            id: id.to_owned(),
        }
    }

    fn file(boot: &TempTree, id: &str) -> PathBuf {
        boot.data().join(format!("volume-{id}.index"))
    }

    fn volume_files(boot: &TempTree) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(boot.data())
            .map(|dir| {
                dir.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.starts_with("volume-"))
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    fn stamp(path: &Path) -> (u64, i64, i64) {
        let m = fs::metadata(path).unwrap();
        (m.ino(), m.mtime(), m.mtime_nsec())
    }

    fn until_state(rx: &Receiver<Heard>, want: impl Fn(&EngineState) -> bool) -> EngineState {
        loop {
            match next(rx) {
                Heard::State(s) if want(&s) => return s,
                Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn until_count(rx: &Receiver<Heard>, indexed: u64) -> EngineState {
        until_state(rx, |s| s.indexed == indexed)
    }

    fn faults_until(rx: &Receiver<Heard>, indexed: u64) -> Vec<String> {
        let mut faults = Vec::new();
        loop {
            match next(rx) {
                Heard::Fault(message) => faults.push(message),
                Heard::State(s) if s.indexed == indexed => return faults,
                _ => {}
            }
        }
    }

    fn settle(engine: &Engine) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while shared(engine)
            .units()
            .iter()
            .any(|u| !matches!(u.status().0, EnginePhase::Ready | EnginePhase::Live))
        {
            assert!(Instant::now() < deadline, "a unit never finished its crawl");
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn everything(engine: &Arc<Engine>, rx: &Receiver<Heard>) -> Vec<crate::EngineHit> {
        let session = engine.clone().session().unwrap();
        let g = session.search(String::new(), BEST_MATCH).unwrap();
        let n = ready(rx, g);
        session.rows(g, 0, n).unwrap()
    }

    #[test]
    fn a_first_crawl_answers_its_listed_prefix_on_boot_and_a_disk() {
        for boot_crawl in [true, false] {
            let boot = TempTree::new("crawlshow-boot");
            let disk = drive("crawlshow-disk");
            let tree = if boot_crawl { &boot } else { &disk };
            let (release_start, held_start) = mpsc::channel();
            let (engine, _, rx) = start_with(
                config(&boot),
                boot_crawl.then_some((EnginePhase::Crawling, 0, held_start)),
            );
            if boot_crawl {
                assert!(matches!(next(&rx), Heard::State(s) if s.phase == EnginePhase::Crawling));
            } else {
                phases(&rx);
            }
            let release = Arc::new(AtomicBool::new(false));
            *shared(&engine).opened.lock().unwrap() = Some({
                let release = release.clone();
                Arc::new(move |stop| {
                    let until = Instant::now() + Duration::from_secs(10);
                    while !release.load(Ordering::Relaxed) && !stop.load(Ordering::Relaxed) {
                        assert!(Instant::now() < until, "crawl was never released");
                        thread::sleep(Duration::from_millis(1));
                    }
                })
            });
            if boot_crawl {
                release_start.send(None).unwrap();
            } else {
                engine.set_volumes(vec![vol(&disk, A)]).unwrap();
            }
            changed(&rx);
            let query = format!("in:\"{}\"", tree.real());
            let scanned = crate::query::search(
                &mut crate::query::Query::parse(&query, &boot.real()),
                &shared(&engine).settings,
                &shared(&engine).units(),
                &|| false,
            )
            .unwrap();
            let rows: Vec<_> = scanned
                .iter()
                .flat_map(|(f, hits)| f.rows(0, hits.len()))
                .collect();
            let mut actual: Vec<_> = rows.iter().map(|h| h.name.clone()).collect();
            actual.sort();
            let listing = crawl::list_one(Path::new(&tree.real())).unwrap();
            let mut expected: Vec<_> = listing
                .ents
                .iter()
                .map(|e| String::from_utf8_lossy(listing.name(e)).into_owned())
                .collect();
            expected.sort();
            assert_eq!(actual, expected, "boot crawl: {boot_crawl}");
            assert!(rows.iter().all(|h| h.folder == tree.real()));
            let session = engine.clone().session().unwrap();
            let generation = session.search(query, BEST_MATCH).unwrap();
            assert_eq!(ready(&rx, generation), expected.len() as u32);
            release.store(true, Ordering::Relaxed);
            settle(&engine);
        }
    }

    #[test]
    fn crawl_publications_are_paced_and_content_walks_the_whole_disk() {
        let boot = TempTree::new("crawlshow-pace-boot");
        let disk = drive("crawlshow-pace-disk");
        fs::create_dir_all(disk.0.join("Sub/Deep/Last")).unwrap();
        fs::write(disk.0.join("Sub/DELTA.Txt"), b"hello").unwrap();
        fs::write(disk.0.join("Sub/Deep/later.txt"), b"hello").unwrap();
        let (engine, listener, rx) = start(&boot);
        phases(&rx);
        let stage = Arc::new(AtomicUsize::new(0));
        *shared(&engine).opened.lock().unwrap() = Some({
            let stage = stage.clone();
            let calls = AtomicUsize::new(0);
            Arc::new(move |stop| {
                let call = calls.fetch_add(1, Ordering::Relaxed);
                let deadline = Instant::now() + Duration::from_secs(10);
                while stage.load(Ordering::Relaxed) <= call && !stop.load(Ordering::Relaxed) {
                    assert!(Instant::now() < deadline);
                    thread::sleep(Duration::from_millis(1));
                }
            })
        });
        engine.set_volumes(vec![vol(&disk, A)]).unwrap();
        changed(&rx);
        let unit = shared(&engine)
            .units()
            .iter()
            .find(|u| u.id.is_some())
            .unwrap()
            .clone();
        let first = unit.partial().unwrap();
        assert_eq!(first.batches.len(), 1);
        assert_eq!(
            first.batches[0]
                .iter()
                .map(|f| f.listing.ents.len())
                .sum::<usize>(),
            6
        );
        assert!(!file(&boot, A).exists());
        stage.store(1, Ordering::Relaxed);
        changed(&rx);
        let second = unit.partial().unwrap();
        assert_eq!(second.batches.len(), 2);
        assert!(Arc::ptr_eq(&first.batches[0], &second.batches[0]));
        assert_eq!(
            second.batches[1]
                .iter()
                .map(|f| f.listing.ents.len())
                .sum::<usize>(),
            2
        );
        let times = listener.changes.lock().unwrap().clone();
        assert_eq!(times.len(), 2);
        assert!(times[1].duration_since(times[0]) >= Duration::from_millis(250));
        assert_eq!(unit.status().0, EnginePhase::Crawling);
        let session = engine.clone().session().unwrap();
        let query = format!("in:\"{}\"", disk.real());
        let press = session
            .search_content(query.clone(), vec!["hello".to_owned()], true, BEST_MATCH)
            .unwrap();
        let (mut names, read, total) = crate::engine::tests::pressed(&session, &rx, press);
        names.sort();
        assert_eq!(names, ["Alpha.TXT", "DELTA.Txt", "later.txt"]);
        assert_eq!((read, total), (6, 6));
        assert_eq!(unit.status().0, EnginePhase::Crawling);
        let root = PathBuf::from(disk.real());
        let walks = || {
            let crawls = shared(&engine).crawls.lock().unwrap();
            crawls.iter().filter(|c| **c == root).count()
        };
        assert_eq!(walks(), 2);
        stage.store(usize::MAX, Ordering::Relaxed);
        settle(&engine);
        changed(&rx);
        changed(&rx);
        let times = listener.changes.lock().unwrap().clone();
        assert_eq!(times.len(), 4);
        assert!(
            [(0, 1), (2, 3)]
                .iter()
                .all(|&(a, b)| times[b].duration_since(times[a]) >= Duration::from_millis(250))
        );
        let narrow = session.narrow(query.clone(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, narrow), 3);
        assert_eq!(shared(&engine).reads.lock().unwrap().len(), 6);
        assert_eq!(walks(), 2);
        let search = session.search(query, BEST_MATCH).unwrap();
        let n = ready(&rx, search);
        let mut rows = session.rows(search, 0, n).unwrap();
        let uninterrupted = Index::build(
            crawl::scan_path(&unit.pool, &unit.root, &unit.skip, &AtomicBool::new(false)),
            unit.root.clone(),
            &unit.print,
            0,
            0,
        )
        .unwrap();
        let mut expected: Vec<_> = (0..uninterrupted.entries())
            .map(|i| uninterrupted.hit(i as u32))
            .collect();
        let order = |a: &crate::EngineHit, b: &crate::EngineHit| {
            a.folder.cmp(&b.folder).then(a.name.cmp(&b.name))
        };
        rows.sort_by(order);
        expected.sort_by(order);
        assert_eq!(rows, expected);
        let saved = Index::load(&file(&boot, A), unit.root.clone()).unwrap();
        assert_eq!(saved.entries(), uninterrupted.entries());
        assert!(unit.partial().is_none());
    }

    fn sorted_press(
        session: &crate::session::EngineSession,
        rx: &Receiver<Heard>,
        query: String,
    ) -> (Vec<String>, u64, u64) {
        let g =
            (session.search_content(query, vec!["hello".to_owned()], true, BEST_MATCH)).unwrap();
        let (mut names, read, total) = pressed(session, rx, g);
        names.sort();
        (names, read, total)
    }

    fn walks_of(engine: &Engine, root: &Path) -> usize {
        let crawls = shared(engine).crawls.lock().unwrap();
        crawls.iter().filter(|c| *c == root).count()
    }

    fn reads_under(engine: &Engine, folder: &Path) -> usize {
        let reads = shared(engine).reads.lock().unwrap();
        reads.iter().filter(|p| p.starts_with(folder)).count()
    }

    fn crawl_tree(tree: &TempTree) -> PathBuf {
        fs::create_dir_all(tree.0.join("Sub/Deep")).unwrap();
        fs::create_dir_all(tree.0.join("Skip")).unwrap();
        fs::write(tree.0.join("Sub/Deep/later.txt"), b"hello").unwrap();
        fs::write(tree.0.join("Skip/skipped.txt"), b"hello").unwrap();
        PathBuf::from(tree.real())
    }

    #[test]
    fn a_press_on_a_crawling_disk_walks_it_without_its_excluded_paths() {
        let boot = TempTree::new("crawlwalk-boot");
        let disk = drive("crawlwalk-disk");
        let root = crawl_tree(&disk);
        let skip = root.join("Skip");
        let mut cfg = config(&boot);
        cfg.excluded = vec![skip.to_str().unwrap().to_owned()];
        let (engine, _, rx) = start_with(cfg, None);
        phases(&rx);
        let ((reached, at), (go, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_volumes(vec![vol(&disk, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let unit = (shared(&engine).units().iter())
            .find(|u| u.id.is_some())
            .unwrap()
            .clone();
        assert!(unit.read(|_| ()).is_none());
        let session = engine.clone().session().unwrap();
        let on_disk = format!("in:\"{}\"", root.display());
        let on_sub = format!("in:\"{}\"", root.join("Sub").display());
        let both = |n: &[&str]| n.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            sorted_press(&session, &rx, on_disk.clone()),
            (both(&["Alpha.TXT", "later.txt"]), 6, 6)
        );
        assert_eq!(
            sorted_press(&session, &rx, on_sub.clone()),
            (both(&["later.txt"]), 2, 2)
        );
        assert_eq!(
            sorted_press(&session, &rx, String::new()),
            (both(&["Alpha.TXT", "Alpha.TXT", "later.txt"]), 10, 10)
        );
        assert_eq!(unit.status().0, EnginePhase::Crawling);
        assert_eq!(walks_of(&engine, &root), 3);
        assert_eq!(walks_of(&engine, &root.join("Sub")), 1);
        assert_eq!(reads_under(&engine, &skip), 0);
        assert_eq!(reads_under(&engine, &root), 6 + 2 + 6);
        go.send(()).unwrap();
        settle(&engine);
        assert_eq!(
            sorted_press(&session, &rx, on_disk),
            (both(&["Alpha.TXT", "later.txt"]), 6, 6)
        );
        assert_eq!(
            sorted_press(&session, &rx, on_sub),
            (both(&["later.txt"]), 2, 2)
        );
        assert_eq!(walks_of(&engine, &root), 3);
        assert_eq!(walks_of(&engine, &root.join("Sub")), 1);
        assert_eq!(reads_under(&engine, &skip), 0);
    }

    #[test]
    fn removing_a_crawling_disk_stops_the_reads_of_its_walk() {
        use crate::text::READERS;
        let boot = TempTree::new("crawlwalk-remove-boot");
        let disk = drive("crawlwalk-remove-disk");
        let root = crawl_tree(&disk);
        let (engine, _, rx) = start_with(config(&boot), None);
        phases(&rx);
        let ((reached, at), (_go, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_volumes(vec![vol(&disk, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let (tx, reading) = mpsc::sync_channel(READERS);
        *shared(&engine).read_reached.lock().unwrap() = Some(tx);
        let gate = shared(&engine).read_gate.write().unwrap();
        let session = engine.clone().session().unwrap();
        let query = format!("in:\"{}\"", root.display());
        let g =
            (session.search_content(query, vec!["hello".to_owned()], true, BEST_MATCH)).unwrap();
        reading.recv_timeout(Duration::from_secs(10)).unwrap();
        let removing = thread::spawn({
            let engine = engine.clone();
            move || engine.set_volumes(Vec::new()).unwrap()
        });
        let deadline = Instant::now() + Duration::from_secs(10);
        while shared(&engine).units().iter().any(|u| u.id.is_some()) {
            assert!(Instant::now() < deadline, "the disk was never removed");
            thread::sleep(Duration::from_millis(1));
        }
        drop(gate);
        removing.join().unwrap();
        let read = reads_under(&engine, &root);
        assert!((1..=READERS).contains(&read), "{read}");
        pressed(&session, &rx, g);
        assert_eq!(reads_under(&engine, &root), read);
    }

    #[test]
    fn a_press_during_the_first_boot_crawl_walks_the_whole_disk() {
        let boot = TempTree::new("crawlwalk-first-boot");
        let root = crawl_tree(&boot);
        let skip = root.join("Skip");
        let mut cfg = config(&boot);
        cfg.excluded = vec![skip.to_str().unwrap().to_owned()];
        let (release_start, held_start) = mpsc::channel();
        let (engine, _, rx) = start_with(cfg, Some((EnginePhase::Crawling, 0, held_start)));
        assert!(matches!(next(&rx), Heard::State(s) if s.phase == EnginePhase::Crawling));
        let release = Arc::new(AtomicBool::new(false));
        *shared(&engine).opened.lock().unwrap() = Some({
            let release = release.clone();
            Arc::new(move |stop: &AtomicBool| {
                let until = Instant::now() + Duration::from_secs(10);
                while !release.load(Ordering::Relaxed) && !stop.load(Ordering::Relaxed) {
                    assert!(Instant::now() < until, "crawl was never released");
                    thread::sleep(Duration::from_millis(1));
                }
            })
        });
        release_start.send(None).unwrap();
        changed(&rx);
        let unit = shared(&engine).units()[0].clone();
        assert!(unit.read(|_| ()).is_none());
        let session = engine.clone().session().unwrap();
        let on_root = format!("in:\"{}\"", root.display());
        let on_sub = format!("in:\"{}\"", root.join("Sub").display());
        let both = |n: &[&str]| n.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        for query in [String::new(), on_root.clone()] {
            assert_eq!(
                sorted_press(&session, &rx, query.clone()),
                (both(&["Alpha.TXT", "later.txt"]), 5, 5),
                "{query:?}"
            );
        }
        assert_eq!(
            sorted_press(&session, &rx, on_sub),
            (both(&["later.txt"]), 2, 2)
        );
        assert_eq!(unit.status().0, EnginePhase::Crawling);
        assert_eq!(walks_of(&engine, &root), 3);
        assert_eq!(reads_under(&engine, &skip), 0);
        release.store(true, Ordering::Relaxed);
        settle(&engine);
        for query in [String::new(), on_root] {
            assert_eq!(
                sorted_press(&session, &rx, query.clone()),
                (both(&["Alpha.TXT", "later.txt"]), 5, 5),
                "{query:?}"
            );
        }
        assert_eq!(walks_of(&engine, &root), 3);
        assert_eq!(reads_under(&engine, &skip), 0);
    }

    #[test]
    fn an_eject_or_stop_removes_partial_answers() {
        for action in ["eject", "stop"] {
            let boot = TempTree::new(&format!("crawlshow-remove-boot-{action}"));
            let disk = drive(&format!("crawlshow-remove-disk-{action}"));
            let (engine, _, rx) = start(&boot);
            phases(&rx);
            let release = Arc::new(AtomicBool::new(false));
            *shared(&engine).opened.lock().unwrap() = Some({
                let release = release.clone();
                Arc::new(move |stop| {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    while !release.load(Ordering::Relaxed) && !stop.load(Ordering::Relaxed) {
                        assert!(Instant::now() < deadline);
                        thread::sleep(Duration::from_millis(1));
                    }
                })
            });
            engine.set_volumes(vec![vol(&disk, A)]).unwrap();
            changed(&rx);
            let unit = shared(&engine)
                .units()
                .iter()
                .find(|u| u.id.is_some())
                .unwrap()
                .clone();
            let query = format!("in:\"{}\"", disk.real());
            assert_eq!(count(&engine, &rx, &query), 6);
            match action {
                "eject" => engine.set_volumes(Vec::new()).unwrap(),
                _ => unit.stop.store(true, Ordering::Relaxed),
            }
            assert_eq!(count(&engine, &rx, &query), 0, "{action}");
            assert!(!file(&boot, A).exists());
            release.store(true, Ordering::Relaxed);
        }
    }

    #[test]
    fn an_exclusion_during_a_first_crawl_restarts_it_with_the_new_list() {
        for (case, on_boot, reverse) in [
            ("disk", false, false),
            ("boot", true, false),
            ("reverse", false, true),
        ] {
            let boot = TempTree::new(&format!("firstexcl-boot-{case}"));
            let disk = drive(&format!("firstexcl-disk-{case}"));
            let tree = if on_boot { &boot } else { &disk };
            fs::create_dir(tree.0.join("More")).unwrap();
            fs::write(tree.0.join("More/kept.txt"), b"").unwrap();
            let registered = |engine: &Engine| {
                shared(engine)
                    .units()
                    .iter()
                    .find(|u| u.id.is_none() == on_boot)
                    .unwrap()
                    .clone()
            };
            let (release_start, held_start) = mpsc::channel();
            let (engine, _, rx) = start_with(
                config(&boot),
                on_boot.then_some((EnginePhase::Crawling, 0, held_start)),
            );
            if on_boot {
                assert!(matches!(next(&rx), Heard::State(s) if s.phase == EnginePhase::Crawling));
            } else {
                phases(&rx);
            }
            let (reached, at) = mpsc::channel();
            let saw_stop = Arc::new(AtomicBool::new(false));
            *shared(&engine).opened.lock().unwrap() = Some({
                let (reached, saw_stop) = (Mutex::new(reached), saw_stop.clone());
                Arc::new(move |stop: &AtomicBool| {
                    let _ = reached.lock().unwrap().send(());
                    let deadline = Instant::now() + Duration::from_secs(10);
                    while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
                        thread::sleep(Duration::from_millis(1));
                    }
                    saw_stop.store(stop.load(Ordering::Relaxed), Ordering::Relaxed);
                })
            });
            if on_boot {
                release_start.send(None).unwrap();
            } else {
                engine.set_volumes(vec![vol(&disk, A)]).unwrap();
            }
            at.recv_timeout(Duration::from_secs(10)).unwrap();
            changed(&rx);
            let query = format!("in:\"{}\"", tree.real());
            let listed: u64 = if on_boot { 6 } else { 7 };
            assert_eq!(count(&engine, &rx, &query), listed as u32, "{case}");
            let first = registered(&engine);

            let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
            *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
            let sub = format!("{}/Sub", tree.real());
            engine.set_excluded(vec![sub.clone()]).unwrap();
            at.recv_timeout(Duration::from_secs(10)).unwrap();
            assert!(
                saw_stop.load(Ordering::Relaxed),
                "{case}: the first crawl ran on"
            );
            assert_eq!(boot_crawls(&engine, tree), 2, "{case}");
            let unit = registered(&engine);
            assert!(!Arc::ptr_eq(&unit, &first), "{case}");
            assert_eq!(unit.skip, [PathBuf::from(&sub)], "{case}");
            assert_eq!(unit.status(), (EnginePhase::Crawling, listed), "{case}");
            assert_eq!(count(&engine, &rx, &query), listed as u32, "{case}");

            if reverse {
                engine.set_excluded(Vec::new()).unwrap();
            }
            let _ = release.send(());
            settle(&engine);
            let unit = registered(&engine);
            assert!(
                rebuild_inputs(&shared(&engine).settings, &unit).is_none(),
                "{case}"
            );
            let (crawls, found) = if reverse {
                (3, listed + 2)
            } else {
                (2, listed + 1)
            };
            assert_eq!(count(&engine, &rx, &query), found as u32, "{case}");
            assert_eq!(boot_crawls(&engine, tree), crawls, "{case}");
            let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
            assert_eq!(saved.fingerprint(), unit.print, "{case}");
        }
    }

    #[test]
    fn partial_search_keeps_finished_matching_filters_ranking_and_sorting() {
        use crate::{EngineColumn, EngineSort};
        let tree = TempTree::new("crawlshow-parity");
        for name in ["Flagged", ".dot", "home/Library", "Sub/System", "Skip"] {
            fs::create_dir_all(tree.0.join(name)).unwrap();
            fs::write(tree.0.join(name).join("alpha2.txt"), b"hello").unwrap();
        }
        fs::write(tree.0.join("alpha10.pdf"), b"hello hello").unwrap();
        fs::write(tree.0.join("Älpha.txt"), b"hello").unwrap();
        let flagged =
            std::ffi::CString::new(tree.0.join("Flagged").as_os_str().as_bytes()).unwrap();
        assert_eq!(
            unsafe { libc::chflags(flagged.as_ptr(), libc::UF_HIDDEN) },
            0
        );
        let mut cfg = config(&tree);
        cfg.excluded = vec![format!("{}/Skip", tree.real())];
        let (engine, _, rx) = start_with(cfg, None);
        phases(&rx);
        let unit = shared(&engine).units()[0].clone();
        let session = engine.clone().session().unwrap();
        let queries = [
            "",
            "alpha",
            "alhpa",
            "'alpha",
            "begins:alpha",
            "ends:txt",
            "whole:Alpha.TXT",
            "glob:alpha*",
            "re:^alpha",
            "ext:txt",
            "kind:file ext:txt",
            "type:doc ext:pdf",
            "size:>4",
            "mtime:<1d",
            "hidden:no",
            "alpha !Flagged",
            "Sub DELTA",
            "Sub/DELTA",
            "Älpha",
        ];
        let mut cases = Vec::new();
        for text in queries {
            for scope in [tree.real(), format!("{}/Sub", tree.real())] {
                for column in [
                    EngineColumn::Relevance,
                    EngineColumn::Name,
                    EngineColumn::Folder,
                    EngineColumn::Size,
                    EngineColumn::Modified,
                    EngineColumn::Kind,
                ] {
                    for ascending in [true, false] {
                        let query = format!("{text} in:\"{scope}\"");
                        let sort = EngineSort {
                            column,
                            ascending,
                            folders_first: false,
                        };
                        let g = session.search(query.clone(), sort).unwrap();
                        let n = ready(&rx, g);
                        if text == "type:doc ext:pdf" && scope == tree.real() {
                            assert_eq!(
                                session
                                    .rows(g, 0, n)
                                    .unwrap()
                                    .iter()
                                    .map(|h| h.name.as_str())
                                    .collect::<Vec<_>>(),
                                ["alpha10.pdf"]
                            );
                        }
                        cases.push((query, sort, session.rows(g, 0, n).unwrap()));
                    }
                }
            }
        }
        let mut crawl = crawl::scan_path(&unit.pool, &unit.root, &unit.skip, &unit.stop);
        for listing in &mut crawl.listings {
            listing.sort();
            listing.ents.reverse();
        }
        let live = unit.live.write().unwrap().take().unwrap();
        assert!(unit.begin(shared(&engine)));
        for listing in &crawl.listings {
            unit.publish(shared(&engine), std::slice::from_ref(listing));
        }
        for (query, sort, expected) in cases {
            let g = session.search(query.clone(), sort).unwrap();
            let n = ready(&rx, g);
            assert_eq!(session.rows(g, 0, n).unwrap(), expected, "{query} {sort:?}");
        }
        let content_query = format!("in:\"{}\"", tree.real());
        let press = session
            .search_content(
                content_query.clone(),
                vec!["hello".to_owned()],
                true,
                BEST_MATCH,
            )
            .unwrap();
        let (names, _, _) = crate::engine::tests::pressed(&session, &rx, press);
        assert!(names.iter().any(|n| n == "alpha2.txt"));
        assert_eq!(
            reads_under(&engine, &PathBuf::from(tree.real()).join("Skip")),
            0
        );
        let g = session
            .narrow(format!("{content_query} hidden:no"), BEST_MATCH)
            .unwrap();
        let n = ready(&rx, g);
        assert!(
            session
                .rows(g, 0, n)
                .unwrap()
                .iter()
                .all(|h| !h.folder.ends_with("Flagged")
                    && !h.folder.ends_with(".dot")
                    && !h.folder.ends_with("home/Library"))
        );
        engine
            .set_volumes(vec![EngineVolume {
                root: format!("{}/Sub", tree.real()),
                id: A.to_owned(),
            }])
            .unwrap();
        settle(&engine);
        assert_eq!(count(&engine, &rx, "whole:DELTA.Txt"), 1);
        unit.put(shared(&engine), live);
    }

    #[test]
    fn partial_sort_keeps_raw_name_ties_in_finished_order() {
        use crate::{EngineColumn, EngineSort};
        let tree = TempTree::new("crawlshow-raw");
        let (engine, _, rx) = start(&tree);
        phases(&rx);
        let unit = shared(&engine).units()[0].clone();
        let mut listing = crawl::Listing::default();
        for (name, size) in [(b"x\x81", 2), (b"x\x80", 1)] {
            listing.push(
                name,
                crawl::Attrs {
                    kind: EngineKind::File,
                    size,
                    mtime: 0,
                    created: 0,
                    opened: 0,
                    mount: false,
                    hidden: false,
                },
                crawl::NONE,
            );
        }
        unit.live.write().unwrap().take();
        assert!(unit.begin(shared(&engine)));
        unit.publish(shared(&engine), std::slice::from_ref(&listing));
        let session = engine.clone().session().unwrap();
        let sort = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let g = session.search(String::new(), sort).unwrap();
        assert_eq!(ready(&rx, g), 2);
        let partial = session.rows(g, 0, 2).unwrap();
        assert_eq!(partial.iter().map(|h| h.size).collect::<Vec<_>>(), [1, 2]);
        let index = Index::build(
            Crawl {
                listings: vec![listing],
                failed: Vec::new(),
            },
            unit.root.clone(),
            &unit.print,
            0,
            0,
        )
        .unwrap();
        unit.install(shared(&engine), index, EnginePhase::Ready);
        let g = session.search(String::new(), sort).unwrap();
        assert_eq!(ready(&rx, g), 2);
        assert_eq!(session.rows(g, 0, 2).unwrap(), partial);
    }

    pub(crate) fn hold_open(reached: Sender<()>, saw_stop: Arc<AtomicBool>) -> crawl::Hook {
        let reached = Mutex::new(Some(reached));
        Arc::new(move |stop: &AtomicBool| {
            let Some(reached) = reached.lock().unwrap().take() else {
                return;
            };
            let _ = reached.send(());
            let deadline = Instant::now() + Duration::from_secs(10);
            while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            saw_stop.store(stop.load(Ordering::Relaxed), Ordering::Relaxed);
        })
    }

    fn open_under(root: &str) -> bool {
        let mut buf = [0u8; libc::MAXPATHLEN as usize];
        (0..unsafe { libc::getdtablesize() }).any(|fd| {
            let got = unsafe { libc::fcntl(fd, libc::F_GETPATH, buf.as_mut_ptr()) };
            got == 0
                && CStr::from_bytes_until_nul(&buf)
                    .is_ok_and(|p| Path::new(OsStr::from_bytes(p.to_bytes())).starts_with(root))
        })
    }

    #[test]
    fn two_volumes_are_found_under_their_roots() {
        let boot = TempTree::new("vol-two");
        let (a, b) = (drive("vol-two-a"), drive("vol-two-b"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A), vol(&b, B)]).unwrap();
        until_count(&rx, BOOT + 2 * DRIVE);
        changed(&rx);
        let (ra, rb) = (a.real(), b.real());
        let (ma, mb) = (mark("vol-two-a"), mark("vol-two-b"));
        seek(&engine, &rx, "mark-", &[(&ma, &ra), (&mb, &rb)], true);
        let subs = [&boot.real(), &ra, &rb].map(|r| format!("{r}/Sub"));
        let delta = subs.each_ref().map(|s| ("DELTA.Txt", s.as_str()));
        seek(&engine, &rx, "delta", &delta, true);
    }

    #[test]
    fn the_same_list_twice_changes_nothing() {
        let boot = TempTree::new("vol-same");
        let (a, b) = (drive("vol-same-a"), drive("vol-same-b"));
        let (engine, _listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        let list = vec![vol(&a, A), vol(&b, B)];
        engine.set_volumes(list.clone()).unwrap();
        until_count(&rx, BOOT + 2 * DRIVE);
        let before = [stamp(&file(&boot, A)), stamp(&file(&boot, B))];
        let units = shared(&engine).units().to_vec();
        engine.set_volumes(list).unwrap();
        let now = shared(&engine).units().to_vec();
        assert_eq!(now.len(), units.len());
        assert!(units.iter().zip(&now).all(|(a, b)| Arc::ptr_eq(a, b)));
        let g = session.search("mark-".to_owned(), BEST_MATCH).unwrap();
        loop {
            match next(&rx) {
                Heard::State(s) => assert!(
                    !matches!(s.phase, EnginePhase::Crawling | EnginePhase::Loading),
                    "{s:?}"
                ),
                Heard::Ready(r, n) if r == g => {
                    assert_eq!(n, 2);
                    break;
                }
                Heard::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        assert_eq!([stamp(&file(&boot, A)), stamp(&file(&boot, B))], before);
        assert_eq!(shared(&engine).units().len(), 3);
    }

    #[test]
    fn a_removed_volume_leaves_the_results() {
        let boot = TempTree::new("vol-remove");
        let (a, b) = (drive("vol-remove-a"), drive("vol-remove-b"));
        let (engine, _listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A), vol(&b, B)]).unwrap();
        until_count(&rx, BOOT + 2 * DRIVE);
        let g = session.search("mark-".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 2);
        let held = session.rows(g, 0, 2).unwrap();
        let saved = stamp(&file(&boot, B));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let heard: Vec<Heard> = rx.try_iter().collect();
        let at = heard
            .iter()
            .position(|e| matches!(e, Heard::Changed(0)))
            .unwrap_or_else(|| panic!("no results_changed in {heard:?}"));
        assert!(
            heard[at..]
                .iter()
                .any(|e| matches!(e, Heard::State(s) if s.indexed == BOOT + DRIVE)),
            "{heard:?}"
        );
        assert_eq!(session.rows(g, 0, 10).unwrap(), held);
        let rb = b.real();
        let all = everything(&engine, &rx);
        assert_eq!(all.len() as u64, BOOT + DRIVE);
        assert!(!all.iter().any(|h| Path::new(&h.folder).starts_with(&rb)));
        let (ma, ra) = (mark("vol-remove-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], false);
        assert_eq!(stamp(&file(&boot, B)), saved);
    }

    fn nest(name: &str) -> (TempTree, TempTree, Vec<EngineVolume>) {
        let boot = TempTree::new(name);
        fs::write(boot.0.join("boot-nest.txt"), b"nestword").unwrap();
        let parent = TempTree::new(&format!("{name}-vols"));
        let disks = [(A, "a"), (B, "b")].map(|(id, n)| {
            let root = parent.0.join(n);
            fs::create_dir_all(root.join("sub")).unwrap();
            fs::write(root.join(format!("nested-{n}.txt")), b"nestword").unwrap();
            EngineVolume {
                root: given(engine::real(&root)),
                id: id.to_owned(),
            }
        });
        (boot, parent, disks.to_vec())
    }

    fn kept_out(engine: &Arc<Engine>, rx: &Receiver<Heard>, row: &str) {
        settle(engine);
        let shared = shared(engine);
        assert!(
            shared.units().iter().all(|u| u.id.is_none()),
            "a disk under the row has a unit"
        );
        assert!(
            everything(engine, rx)
                .iter()
                .all(|h| !h.folder.starts_with(row))
        );
        assert_eq!(texts(engine, rx, "text:nestword"), ["boot-nest.txt"]);
        assert!(
            !shared
                .reads
                .lock()
                .unwrap()
                .iter()
                .any(|p| p.starts_with(row))
        );
    }

    #[test]
    fn a_row_above_a_disk_root_keeps_the_disk_out() {
        let (boot, parent, disks) = nest("nest-out");
        let row = parent.real();
        let (engine, rx) = rows_engine(&boot, std::slice::from_ref(&row), &[A, B]);
        engine.set_volumes(disks.clone()).unwrap();
        kept_out(&engine, &rx, &row);
        assert!(
            shared(&engine)
                .crawls
                .lock()
                .unwrap()
                .iter()
                .all(|r| !r.starts_with(&row))
        );
        assert_eq!(volume_files(&boot), Vec::<String>::new());
        engine.set_excluded(vec![disks[0].root.clone()]).unwrap();
        settle(&engine);
        assert_eq!(volume_files(&boot), [format!("volume-{B}.index")]);
        let saved = stamp(&file(&boot, B));
        let crawled = shared(&engine).crawls.lock().unwrap().len();
        engine.set_excluded(vec![row.clone()]).unwrap();
        kept_out(&engine, &rx, &row);
        assert_eq!(shared(&engine).crawls.lock().unwrap().len(), crawled);
        assert_eq!(stamp(&file(&boot, B)), saved);
        assert!(!file(&boot, A).exists());
    }

    #[test]
    fn a_row_added_during_a_first_crawl_saves_nothing() {
        let (boot, parent, disks) = nest("nest-crawl");
        let (engine, rx) = rows_engine(&boot, &[], &[A]);
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_volumes(vec![disks[0].clone()]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        engine.set_excluded(vec![parent.real()]).unwrap();
        let _ = release.send(());
        kept_out(&engine, &rx, &parent.real());
        assert_eq!(volume_files(&boot), Vec::<String>::new());
    }

    #[test]
    fn a_removed_row_brings_the_disk_back() {
        let (boot, parent, disks) = nest("nest-back");
        let row = parent.real();
        let (engine, rx) = rows_engine(&boot, std::slice::from_ref(&row), &[A, B]);
        engine.set_volumes(disks.clone()).unwrap();
        kept_out(&engine, &rx, &row);
        engine.set_excluded(Vec::new()).unwrap();
        settle(&engine);
        let (ra, rb) = (disks[0].root.as_str(), disks[1].root.as_str());
        seek(
            &engine,
            &rx,
            "nested-",
            &[("nested-a.txt", ra), ("nested-b.txt", rb)],
            false,
        );
        assert_eq!(
            texts(&engine, &rx, "text:nestword"),
            ["boot-nest.txt", "nested-a.txt", "nested-b.txt"]
        );
        assert_eq!(
            volume_files(&boot),
            [format!("volume-{A}.index"), format!("volume-{B}.index")]
        );
        engine.set_excluded(vec![row.clone()]).unwrap();
        engine.set_volumes(vec![disks[1].clone()]).unwrap();
        engine.set_excluded(Vec::new()).unwrap();
        settle(&engine);
        seek(&engine, &rx, "nested-", &[("nested-b.txt", rb)], false);
        let ids: Vec<_> = (shared(&engine).units().iter())
            .filter_map(|u| u.id.clone())
            .collect();
        assert_eq!(ids, [B]);
    }

    #[test]
    fn a_removal_during_the_crawl_closes_every_file() {
        let boot = TempTree::new("vol-cut");
        let b = drive("vol-cut-b");
        let rb = b.real();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let (reached_tx, reached) = mpsc::channel();
        let saw_stop = Arc::new(AtomicBool::new(false));
        *shared(&engine).opened.lock().unwrap() = Some(hold_open(reached_tx, saw_stop.clone()));
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(
            open_under(&rb),
            "the held crawl has no folder of the disk open"
        );
        engine.set_volumes(Vec::new()).unwrap();
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the crawl ended before the removal"
        );
        assert!(!open_under(&rb));
        assert!(volume_files(&boot).is_empty());
        assert_eq!(count(&engine, &rx, "mark-"), 0);
    }

    fn only_disk(engine: &Engine) -> Arc<Unit> {
        shared(engine)
            .units()
            .iter()
            .find(|u| u.id.is_some())
            .unwrap()
            .clone()
    }

    #[test]
    fn a_disk_added_during_a_pause_starts_its_stream_on_resume() {
        let boot = TempTree::new("vol-paused");
        let a = drive("vol-paused-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        switched(&engine, false);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        until_state(&rx, |s| s.indexing.is_empty());
        let disk = only_disk(&engine);
        assert_eq!(
            disk.watcher().count,
            0,
            "a new disk started a stream during the pause"
        );
        fs::write(a.0.join("zyqwhile.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        assert_eq!(count(&engine, &rx, "zyqwhile"), 0);
        switched(&engine, true);
        seek(
            &engine,
            &rx,
            "zyqwhile",
            &[("zyqwhile.txt", &a.real())],
            false,
        );
        assert_eq!(disk.watcher().count, 1, "resume did not start the new disk");
    }

    fn saved_disks_then_paused(
        name: &str,
        disks: &[(&Path, &str)],
    ) -> (TempTree, Arc<Engine>, Receiver<Heard>, u64) {
        let boot = TempTree::new(name);
        let volumes = || {
            disks
                .iter()
                .map(|&(root, id)| EngineVolume {
                    root: fs::canonicalize(root).unwrap().to_str().unwrap().to_owned(),
                    id: id.to_owned(),
                })
                .collect::<Vec<_>>()
        };
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(volumes()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !disks.iter().all(|&(_, id)| file(&boot, id).exists()) || shared(&engine).settling() {
            assert!(Instant::now() < deadline, "the first crawls never ended");
            thread::sleep(Duration::from_millis(10));
        }
        let first = shared(&engine).units().iter().map(|u| u.status().1).sum();
        drop(engine);
        fs::write(disks[0].0.join("zyqwhile.txt"), b"").unwrap();
        let (engine, _listener, rx) = start_with(
            crate::EngineConfig {
                live_updates_paused: true,
                ..config(&boot)
            },
            None,
        );
        phases(&rx);
        engine.set_volumes(volumes()).unwrap();
        (boot, engine, rx, first)
    }

    fn crawled(engine: &Engine, disk: &Unit) -> bool {
        shared(engine).crawls.lock().unwrap().contains(&disk.root)
    }

    fn disk_of(engine: &Engine, id: &str) -> Arc<Unit> {
        shared(engine)
            .units()
            .iter()
            .find(|u| u.id.as_deref() == Some(id))
            .unwrap()
            .clone()
    }

    #[test]
    fn a_paused_start_keeps_a_saved_disk_until_resume() {
        let a = drive("vol-pausedsaved-a");
        let (_boot, engine, rx, first) = saved_disks_then_paused("vol-pausedsaved", &[(&a.0, A)]);
        let shown = until_state(&rx, |s| s.indexing.is_empty() && s.indexed > BOOT);
        let disk = disk_of(&engine, A);
        assert_eq!(
            shown.indexed, first,
            "a paused start crawled a saved disk and moved the count"
        );
        assert!(
            !crawled(&engine, &disk),
            "a paused start crawled a saved disk"
        );
        assert_eq!(disk.status().0, EnginePhase::Ready);
        assert!(
            !shared(&engine).settling(),
            "a waiting disk kept Wherever running"
        );
        thread::sleep(PAST_LATENCY);
        assert_eq!(count(&engine, &rx, "zyqwhile"), 0);
        assert!(!crawled(&engine, &disk));
        switched(&engine, true);
        seek(
            &engine,
            &rx,
            "zyqwhile",
            &[("zyqwhile.txt", &a.real())],
            false,
        );
        assert!(
            crawled(&engine, &disk),
            "resume skipped the crawl the disk owes"
        );
    }

    #[test]
    fn an_excluded_path_on_a_waiting_disk_crawls_it_in_place_of_the_saved_index() {
        let a = drive("vol-pausedrebuild-a");
        let nest = a.0.join("Nest");
        fs::create_dir(&nest).unwrap();
        fs::write(nest.join("nested.txt"), b"").unwrap();
        let (_boot, engine, rx, _) =
            saved_disks_then_paused("vol-pausedrebuild", &[(&a.0, A), (&nest, B)]);
        let deadline = Instant::now() + Duration::from_secs(10);
        while ![A, B]
            .iter()
            .all(|id| disk_of(&engine, id).waiting.load(Ordering::Relaxed))
        {
            assert!(
                Instant::now() < deadline,
                "a saved disk never waited for Resume"
            );
            thread::sleep(Duration::from_millis(10));
        }
        let waiting = disk_of(&engine, A);
        assert!(
            !crawled(&engine, &waiting),
            "a paused start crawled a saved disk"
        );
        let inside = engine::real(&nest).join("Skip");
        engine
            .set_excluded(vec![inside.to_str().unwrap().to_owned()])
            .unwrap();
        rebuilt(&engine);
        let disk = disk_of(&engine, A);
        assert!(
            !Arc::ptr_eq(&disk, &waiting),
            "the exclusion rebuilt nothing"
        );
        assert!(
            crawled(&engine, &disk),
            "the rebuild folded the saved index of a disk that owes a crawl"
        );
        assert!(waiting.stopped());
        assert_eq!(count(&engine, &rx, "zyqwhile"), 1);
        switched(&engine, true);
        seek(
            &engine,
            &rx,
            "zyqwhile",
            &[("zyqwhile.txt", &a.real())],
            false,
        );
    }

    #[test]
    fn ejecting_a_disk_during_a_pause_still_stops_its_unit() {
        let boot = TempTree::new("vol-pausedeject");
        let a = drive("vol-pausedeject-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        until_state(&rx, |s| s.indexing.is_empty());
        let disk = only_disk(&engine);
        switched(&engine, false);
        engine.set_volumes(Vec::new()).unwrap();
        assert!(disk.stopped());
        assert!(
            disk.thread.lock().unwrap().is_none(),
            "the eject left the disk's thread behind"
        );
        switched(&engine, true);
        assert!(
            !disk.watcher().running(),
            "resume restarted an ejected disk"
        );
    }

    #[test]
    fn a_crawling_disk_leaves_the_boot_phase_live() {
        let boot = TempTree::new("vol-bootlive");
        let a = drive("vol-bootlive-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let s = until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        assert!(matches!(
            s.boot_phase,
            EnginePhase::Ready | EnginePhase::Live
        ));
        assert_eq!(s.indexing, [a.real()]);
        release.send(()).unwrap();
        let s = until_state(&rx, |s| s.indexing.is_empty());
        assert!(matches!(s.phase, EnginePhase::Ready | EnginePhase::Live));
        assert!(matches!(
            s.boot_phase,
            EnginePhase::Ready | EnginePhase::Live
        ));
    }

    #[test]
    fn an_ejected_disk_leaves_the_indexing_list() {
        let boot = TempTree::new("vol-ejectlist");
        let (a, b) = (drive("vol-ejectlist-a"), drive("vol-ejectlist-b"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let ((reached, at), (_release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        until_state(&rx, |s| s.indexing == [a.real()]);
        engine.set_volumes(vec![vol(&a, A), vol(&b, B)]).unwrap();
        until_state(&rx, |s| s.indexing == [a.real(), b.real()]);
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        let s = until_state(&rx, |s| !s.indexing.contains(&a.real()));
        assert!(s.indexing.iter().all(|r| *r == b.real()));
    }

    #[test]
    fn a_volume_crawls_on_its_own_pool() {
        let boot = TempTree::new("vol-pools");
        let a = drive("vol-pools-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let gate = Arc::new(RwLock::new(()));
        let busy = Arc::new(AtomicUsize::new(0));
        let closed = gate.write().unwrap();
        shared(&engine).units()[0].pool.spawn_broadcast({
            let (gate, busy) = (gate.clone(), busy.clone());
            move || {
                busy.fetch_add(1, Ordering::Relaxed);
                drop(gate.read());
            }
        });
        let deadline = Instant::now() + Duration::from_secs(10);
        while busy.load(Ordering::Relaxed) < CRAWL_THREADS {
            assert!(Instant::now() < deadline, "the boot pool never filled");
            thread::sleep(Duration::from_millis(10));
        }
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let (ma, ra) = (mark("vol-pools-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], true);
        engine.set_volumes(Vec::new()).unwrap();
        seek(&engine, &rx, "mark-", &[], false);
        drop(closed);
    }

    #[test]
    fn a_volume_added_again_answers_from_its_file_first() {
        let boot = TempTree::new("vol-readd");
        let b = drive("vol-readd-b");
        let (engine, listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        until_count(&rx, BOOT + DRIVE);
        let first = stamp(&file(&boot, B)).0;
        engine.set_volumes(Vec::new()).unwrap();
        let (release, hold) = mpsc::channel();
        *listener.hold.lock().unwrap() = Some((EnginePhase::Crawling, 1, hold));
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        let held = until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        assert_eq!(held.indexed, BOOT + DRIVE);
        let g = session.search("mark-".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [(mark("vol-readd-b"), b.real(), EngineKind::File)]
        );
        release.send(None).unwrap();
        until_state(&rx, |s| {
            matches!(s.phase, EnginePhase::Ready | EnginePhase::Live) && s.indexed == BOOT + DRIVE
        });
        assert_ne!(stamp(&file(&boot, B)).0, first);
    }

    #[test]
    fn a_renamed_volume_keeps_its_file() {
        let boot = TempTree::new("vol-rename");
        let b = drive("vol-rename-b");
        let moved = TempTree(PathBuf::from(format!("{}-moved", b.0.display())));
        let _ = fs::remove_dir_all(&moved.0);
        let (engine, listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        until_count(&rx, BOOT + DRIVE);
        let old = b.real();
        fs::rename(&b.0, &moved.0).unwrap();
        let (release, hold) = mpsc::channel();
        *listener.hold.lock().unwrap() = Some((EnginePhase::Crawling, 1, hold));
        engine.set_volumes(vec![vol(&moved, B)]).unwrap();
        let held = until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        assert_eq!(held.indexed, BOOT + DRIVE);
        let new = moved.real();
        let g = session.search("mark-".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [(mark("vol-rename-b"), new.clone(), EngineKind::File)]
        );
        release.send(None).unwrap();
        let subs = [boot.real(), new].map(|r| format!("{r}/Sub"));
        let delta = subs.each_ref().map(|s| ("DELTA.Txt", s.as_str()));
        seek(&engine, &rx, "delta", &delta, false);
        let all = everything(&engine, &rx);
        assert!(!all.iter().any(|h| Path::new(&h.folder).starts_with(&old)));
    }

    fn saved_on(engine: &Engine, id: &str, root: &Path, file: &Path) -> Device {
        let mut facts = Device::read(root).unwrap();
        (facts.mount, facts.no_log) = (true, libc::ENOENT);
        assert!(
            facts.history != 0 && facts.last != 0,
            "the temp folder's volume keeps no history"
        );
        let (skip, print) = inputs(&shared(engine).settings, id, root);
        let crawl = crawl::scan_path(&Pool::new(1).unwrap(), root, &skip, &AtomicBool::new(false));
        let synced = engine::now_secs() - 1000;
        let mut index =
            Index::build(crawl, root.to_path_buf(), &print, facts.last, synced).unwrap();
        index.set_history(facts.history);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        index.save(file).unwrap();
        facts
    }

    fn skip_disk(name: &str) -> TempTree {
        let disk = TempTree::new(name);
        fs::create_dir(disk.0.join("Skip")).unwrap();
        fs::write(disk.0.join("Skip/hidden.txt"), b"alpha").unwrap();
        fs::write(disk.0.join("kept.txt"), b"alpha").unwrap();
        disk
    }

    fn rows_engine(
        boot: &TempTree,
        excluded: &[String],
        indexed: &[&str],
    ) -> (Arc<Engine>, Receiver<Heard>) {
        let mut cfg = config(boot);
        cfg.excluded = excluded.to_vec();
        cfg.indexed_volumes = indexed.iter().map(|id| (*id).to_owned()).collect();
        let (engine, _listener, rx) = start_with(cfg, None);
        phases(&rx);
        until_live(&rx);
        (engine, rx)
    }

    fn stays_out(engine: &Arc<Engine>, rx: &Receiver<Heard>, disk: &TempTree, read: &[&str]) {
        settle(engine);
        let root = PathBuf::from(disk.real());
        let shared = shared(engine);
        assert!(
            !shared.crawls.lock().unwrap().contains(&root),
            "the disk was crawled"
        );
        let skip = shared
            .units()
            .iter()
            .find(|u| u.root == root)
            .map(|u| u.skip.clone());
        assert_eq!(skip, Some(vec![root.join("Skip")]));
        assert_eq!(texts(engine, rx, "'hidden"), Vec::<String>::new());
        assert_eq!(texts(engine, rx, "text:alpha"), read);
        let session = engine.clone().session().unwrap();
        let skip = format!("\"in:{}\"", root.join("Skip").display());
        let g = (session.search_content(skip, vec!["alpha".to_owned()], true, BEST_MATCH)).unwrap();
        assert_eq!(pressed(&session, rx, g).0, ["hidden.txt"]);
    }

    #[test]
    fn an_exclusion_on_a_renamed_disk_stays_out() {
        let boot = TempTree::new("excl-renamed");
        let disk = skip_disk("excl-renamed-disk");
        let (engine, rx) = rows_engine(&boot, &[format!("{B}/Skip")], &[B]);
        let facts = saved_on(&engine, B, Path::new(&disk.real()), &file(&boot, B));
        let moved = TempTree(PathBuf::from(format!("{}-renamed", disk.0.display())));
        let _ = fs::remove_dir_all(&moved.0);
        fs::rename(&disk.0, &moved.0).unwrap();
        *shared(&engine).facts.lock().unwrap() = Some((B.to_owned(), facts));
        engine.set_volumes(vec![vol(&moved, B)]).unwrap();
        stays_out(&engine, &rx, &moved, &["kept.txt"]);
    }

    #[test]
    fn an_exclusion_on_a_disk_mounted_as_name_1_stays_out() {
        let boot = TempTree::new("excl-name1");
        let first = skip_disk("excl-name1-disk");
        let (engine, rx) = rows_engine(&boot, &[format!("{A}/Skip")], &[A, B]);
        let facts = saved_on(&engine, A, Path::new(&first.real()), &file(&boot, A));
        let renamed = TempTree(PathBuf::from(format!("{} 1", first.0.display())));
        let _ = fs::remove_dir_all(&renamed.0);
        fs::rename(&first.0, &renamed.0).unwrap();
        let second = TempTree::new("excl-name1-disk");
        fs::create_dir(second.0.join("Skip")).unwrap();
        fs::write(second.0.join("Skip/shown.txt"), b"alpha").unwrap();
        *shared(&engine).facts.lock().unwrap() = Some((A.to_owned(), facts));
        engine
            .set_volumes(vec![vol(&renamed, A), vol(&second, B)])
            .unwrap();
        stays_out(&engine, &rx, &renamed, &["kept.txt", "shown.txt"]);
        let newcomer = (shared(&engine).units().iter())
            .find(|u| u.id.as_deref() == Some(B))
            .map(|u| u.skip.clone());
        assert_eq!(newcomer, Some(Vec::new()));
    }

    #[test]
    fn a_disk_row_holds_before_its_swap() {
        let boot = TempTree::new("excl-window");
        let disk = skip_disk("excl-window-disk");
        let (engine, rx) = rows_engine(&boot, &[], &[C]);
        engine.set_volumes(vec![vol(&disk, C)]).unwrap();
        settle(&engine);
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            ["hidden.txt", "kept.txt"]
        );
        let ((reached, at), (go, gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).swap_hold.lock().unwrap() = Some((reached, gate));
        engine.set_excluded(vec![format!("{C}/Skip")]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(texts(&engine, &rx, "text:alpha"), ["kept.txt"]);
        let skip = format!("in:{}/Skip", disk.real());
        assert_eq!(texts(&engine, &rx, &skip), Vec::<String>::new());
        go.send(()).unwrap();
        rebuilt(&engine);
    }

    #[test]
    fn a_bad_id_is_refused_and_a_cloned_one_indexed_once() {
        let boot = TempTree::new("vol-badid");
        let (a, b) = (drive("vol-badid-a"), drive("vol-badid-b"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let long = "0".repeat(37);
        let slashed = format!("{}/../..", &A[..30]);
        for id in ["../x", "", long.as_str(), slashed.as_str()] {
            let list = vec![
                vol(&a, A),
                EngineVolume {
                    root: b.root(),
                    id: id.to_owned(),
                },
            ];
            assert!(
                matches!(engine.set_volumes(list), Err(EngineError::Io { .. })),
                "{id:?}"
            );
        }
        assert_eq!(shared(&engine).units().len(), 1);
        assert!(volume_files(&boot).is_empty());
        engine.set_volumes(vec![vol(&a, A), vol(&b, A)]).unwrap();
        assert_eq!(faults_until(&rx, BOOT + DRIVE).len(), 1);
        let (ma, ra) = (mark("vol-badid-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], true);
        assert_eq!(volume_files(&boot), [format!("volume-{A}.index")]);
    }

    #[test]
    fn a_missing_root_leaves_the_rest_of_the_list() {
        let boot = TempTree::new("vol-badroot");
        let a = drive("vol-badroot-a");
        let linked = drive("vol-badroot-linked");
        let (engine, listener, rx) = start(&boot);
        phases(&rx);
        let bad = |root: String, id: &str| EngineVolume {
            root,
            id: id.to_owned(),
        };
        let list = vec![
            bad(format!("{}-missing", a.real()), B),
            bad(format!("{}/Alpha.TXT", a.real()), C),
            bad(linked.root(), D),
            vol(&a, A),
        ];
        engine.set_volumes(list).unwrap();
        let (mut faults, mut crawled) = (0, false);
        while faults < 3 || !crawled {
            match next(&rx) {
                Heard::Fault(_) => faults += 1,
                Heard::State(s) if s.indexed == BOOT + DRIVE => crawled = true,
                _ => {}
            }
        }
        let threads = listener.faulted.lock().unwrap().clone();
        assert_eq!(threads.len(), 3);
        assert!(!threads.contains(&thread::current().id()));
        assert!(threads[0] != threads[1] && threads[1] != threads[2] && threads[0] != threads[2]);
        let (ma, ra) = (mark("vol-badroot-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], true);
        assert_eq!(shared(&engine).units().len(), 2);
        assert_eq!(volume_files(&boot), [format!("volume-{A}.index")]);
    }

    #[test]
    fn the_boot_unit_ignores_a_volume_inside_it() {
        let boot = TempTree::new("vol-inside");
        let root = boot.real();
        let inside = format!("{root}/Drive");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        until_live(&rx);
        let drive_root = boot.0.join("Drive");
        fs::create_dir(&drive_root).unwrap();
        seek(&engine, &rx, "drive", &[("Drive", &root)], true);
        engine
            .set_volumes(vec![EngineVolume {
                root: given(engine::real(&drive_root)),
                id: A.to_owned(),
            }])
            .unwrap();
        until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        until_state(&rx, |s| {
            !matches!(s.phase, EnginePhase::Crawling | EnginePhase::Finishing)
        });
        fs::write(drive_root.join("ondrive.txt"), b"").unwrap();
        seek(&engine, &rx, "ondrive", &[("ondrive.txt", &inside)], true);
        let shared = shared(&engine);
        let unit = shared.units()[0].clone();
        let id = unit.read(|l| l.event_id).unwrap();
        let events = [inside.clone(), format!("{inside}/ondrive.txt")]
            .into_iter()
            .flat_map(|p| {
                [0, MUST_SCAN_SUBDIRS].map(|flags| Event {
                    path: p.clone().into_bytes(),
                    flags,
                    id,
                    stream: 0,
                })
            })
            .collect();
        apply::step(
            shared,
            &unit,
            &mut apply::Apply::new(),
            events,
            Instant::now(),
        );
        fs::write(boot.0.join("marker.txt"), b"").unwrap();
        seek(&engine, &rx, "marker", &[("marker.txt", &root)], true);
        seek(&engine, &rx, "ondrive", &[("ondrive.txt", &inside)], true);
        assert_eq!(unit.read(Live::entries), Some(BOOT + 2));
    }

    #[test]
    fn a_registered_root_takes_its_files_from_the_boot_unit() {
        let boot = TempTree::new("vol-purge");
        let root = boot.real();
        let inside = format!("{root}/Drive");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        until_live(&rx);
        let drive_root = boot.0.join("Drive");
        fs::create_dir(&drive_root).unwrap();
        fs::write(drive_root.join("early.txt"), b"").unwrap();
        seek(&engine, &rx, "early", &[("early.txt", &inside)], true);
        engine
            .set_volumes(vec![EngineVolume {
                root: given(engine::real(&drive_root)),
                id: A.to_owned(),
            }])
            .unwrap();
        settle(&engine);
        seek(&engine, &rx, "early", &[("early.txt", &inside)], false);
        let boot_unit = shared(&engine).units()[0].clone();
        assert_eq!(boot_unit.read(Live::entries), Some(BOOT + 1));
        assert_eq!(boot_unit.status().1, BOOT + 1);
    }

    #[test]
    fn a_disk_registered_while_the_boot_index_loads_is_purged_from_it() {
        let boot = TempTree::new("vol-purge-load");
        let inside = format!("{}/Drive", boot.real());
        let drive_root = boot.0.join("Drive");
        fs::create_dir(&drive_root).unwrap();
        fs::write(drive_root.join("early.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        drop(engine);
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&boot), Some((EnginePhase::Loading, 0, hold)));
        until_state(&rx, |s| s.phase == EnginePhase::Loading);
        engine
            .set_volumes(vec![EngineVolume {
                root: given(engine::real(&drive_root)),
                id: A.to_owned(),
            }])
            .unwrap();
        release.send(None).unwrap();
        settle(&engine);
        seek(&engine, &rx, "early", &[("early.txt", &inside)], false);
        let boot_unit = shared(&engine).units()[0].clone();
        assert_eq!(boot_unit.read(Live::entries), Some(BOOT + 1));
    }

    #[test]
    fn adding_a_disk_never_waits_for_the_boot_index() {
        let boot = TempTree::new("vol-nowait");
        let inside = format!("{}/Drive", boot.real());
        let drive_root = boot.0.join("Drive");
        fs::create_dir(&drive_root).unwrap();
        fs::write(drive_root.join("early.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let boot_unit = shared(&engine).units()[0].clone();
        let held = boot_unit.live.read().unwrap();
        let (returned_tx, returned) = mpsc::channel();
        let caller = thread::spawn({
            let engine = engine.clone();
            let root = given(engine::real(&drive_root));
            move || {
                let r = engine.set_volumes(vec![EngineVolume {
                    root,
                    id: A.to_owned(),
                }]);
                let _ = returned_tx.send(());
                r
            }
        });
        let at_once = returned.recv_timeout(Duration::from_secs(5)).is_ok();
        drop(held);
        caller.join().unwrap().unwrap();
        assert!(at_once, "set_volumes waited for the boot unit's index lock");
        settle(&engine);
        seek(&engine, &rx, "early", &[("early.txt", &inside)], false);
        assert_eq!(boot_unit.read(Live::entries), Some(BOOT + 1));
    }

    #[test]
    fn an_event_belongs_to_the_longest_root_on_whole_components() {
        let p = Path::new;
        let none = &mut |_: &Path| false;
        let v = p("/V");
        let nested = [PathBuf::from("/V/a"), PathBuf::from("/V/a/b")];
        assert!(owns(v, &[], v, none));
        assert!(owns(v, &[], p("/V/a/x"), none));
        assert!(!owns(v, &[], p("/W/x"), none));
        assert!(!owns(v, &nested, p("/V/a"), none));
        assert!(!owns(v, &nested, p("/V/a/x"), none));
        assert!(!owns(v, &nested, p("/V/a/b/c"), none));
        assert!(owns(v, &nested, p("/V/ab/x"), none));
        assert!(!owns(p("/V/a"), &[], p("/V/ab"), none));
        assert!(owns(p("/V/a"), &nested[1..], p("/V/a/x"), none));
        assert!(!owns(p("/V/a"), &nested[1..], p("/V/a/b/c"), none));
        assert!(owns(p("/V/a/b"), &[], p("/V/a/b/c"), none));
        let mut mounted = |at: &Path| at == p("/V") || at == p("/V/m");
        assert!(owns(v, &[], v, &mut mounted));
        assert!(owns(v, &[], p("/V/x"), &mut mounted));
        assert!(!owns(v, &[], p("/V/m"), &mut mounted));
        assert!(!owns(v, &[], p("/V/m/x/y"), &mut mounted));
        assert!(owns(v, &[], p("/V/mm/x"), &mut mounted));
    }

    #[test]
    fn a_new_file_on_a_volume_shows_up_from_its_own_thread() {
        let boot = TempTree::new("vol-live");
        let a = drive("vol-live-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_state(&rx, |s| {
            s.phase == EnginePhase::Live && s.indexed == BOOT + DRIVE
        });
        fs::write(a.0.join("new.txt"), b"").unwrap();
        if !seek(&engine, &rx, "new.txt", &[("new.txt", &a.real())], true) {
            changed(&rx);
        }
    }

    #[test]
    fn live_changes_on_a_disk_show_after_a_start_a_resume_and_every_restart() {
        use crate::engine::tests::{files_shown, live_round, replayed, shown};
        let boot = TempTree::new("vol-livepath");
        let a = drive("vol-livepath-a");
        let live = |rx: &Receiver<Heard>, n: u64| {
            until_state(rx, |s| s.phase == EnginePhase::Live && s.indexed == n)
        };
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        live(&rx, BOOT + DRIVE);
        live_round(&engine, &rx, &a, "zyqa");

        switched(&engine, false);
        fs::write(a.0.join("zyqheld.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        assert_eq!(
            files_shown(&engine),
            BOOT + DRIVE,
            "Files moved during the pause"
        );
        switched(&engine, true);
        let held = [("zyqheld.txt", a.real())];
        let held: Vec<(&str, &str)> = held.iter().map(|(n, f)| (*n, f.as_str())).collect();
        shown(
            &engine,
            &rx,
            "disk resume",
            "zyqheld",
            &held,
            BOOT + DRIVE + 1,
        );
        replayed(&engine);
        live_round(&engine, &rx, &a, "zyqb");

        engine.flush_opens().unwrap();
        drop(engine);
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        live(&rx, BOOT + DRIVE + 1);
        live_round(&engine, &rx, &a, "zyqc");

        switched(&engine, false);
        engine.flush_opens().unwrap();
        drop(engine);
        let (engine, _listener, rx) = start_with(
            crate::EngineConfig {
                live_updates_paused: true,
                ..config(&boot)
            },
            None,
        );
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_state(&rx, |s| {
            s.indexing.is_empty() && s.indexed == BOOT + DRIVE + 1
        });
        thread::sleep(PAST_LATENCY);
        switched(&engine, true);
        live(&rx, BOOT + DRIVE + 1);
        live_round(&engine, &rx, &a, "zyqd");
    }

    #[test]
    fn a_search_during_a_volume_crawl_answers_from_the_boot_index() {
        let boot = TempTree::new("vol-search-crawl");
        let a = drive("vol-search-crawl-a");
        let (engine, listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        let (release, hold) = mpsc::channel();
        *listener.hold.lock().unwrap() = Some((EnginePhase::Crawling, 1, hold));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let held = until_state(&rx, |s| s.phase == EnginePhase::Crawling);
        assert_eq!(held.indexed, BOOT);
        let g = session.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [("Alpha.TXT".to_owned(), boot.real(), EngineKind::File)]
        );
        release.send(None).unwrap();
        until_count(&rx, BOOT + DRIVE);
    }

    #[test]
    fn clean_removes_a_left_over_startup_temp_file() {
        let tree = TempTree::new("vol-clean-temps");
        let data = tree.data();
        fs::create_dir_all(&data).unwrap();
        let aged = |name: &str, hours: u64| {
            let path = data.join(name);
            fs::write(&path, b"").unwrap();
            let at = SystemTime::now() - Duration::from_secs(60 * 60 * hours);
            fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(at)
                .unwrap();
            path
        };
        let gone = [
            aged(&format!("{}.4242.0.tmp", crate::index::FILE), 25),
            aged(&format!("{}.4242.1.tmp", crate::opens::FILE), 25),
            aged(&format!("volume-{A}.index.4242.2.tmp"), 25),
        ];
        let kept = [
            aged(&format!("{}.4242.3.tmp", crate::index::FILE), 23),
            aged(crate::index::FILE, 24 * 31),
            aged(crate::opens::FILE, 24 * 31),
            aged("notes.tmp", 24 * 31),
        ];
        clean(&data, &[]);
        for path in gone {
            assert!(!path.exists(), "{} stayed", path.display());
        }
        for path in kept {
            assert!(path.exists(), "{} was removed", path.display());
        }
    }

    #[test]
    fn old_volume_files_are_deleted_at_start() {
        let boot = TempTree::new("vol-clean");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        drop(engine);
        let data = boot.data();
        let aged = |path: &Path, days: u32| {
            if !path.exists() {
                fs::write(path, b"").unwrap();
            }
            let at = SystemTime::now() - Duration::from_secs(24 * 60 * 60) * days;
            fs::File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_modified(at)
                .unwrap();
        };
        let old = data.join(format!("volume-{A}.index"));
        let old_temp = data.join(format!("volume-{B}.index.tmp"));
        let young = data.join(format!("volume-{C}.index"));
        aged(&old, 31);
        aged(&old_temp, 31);
        aged(&young, 29);
        aged(&data.join(crate::index::FILE), 31);
        let (_engine, _listener, rx) = start(&boot);
        assert_eq!(
            phases(&rx),
            [(EnginePhase::Loading, 0), (EnginePhase::Ready, BOOT)]
        );
        assert!(!old.exists() && !old_temp.exists());
        assert!(young.exists());
    }

    fn aged(path: &Path, days: u64) {
        fs::write(path, b"").unwrap();
        fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(24 * 60 * 60 * days))
            .unwrap();
    }

    #[test]
    fn clean_keeps_a_switched_on_disk_past_30_days() {
        let boot = TempTree::new("vol-clean-on");
        let data = boot.data();
        fs::create_dir_all(&data).unwrap();
        let on = data.join(format!("volume-{A}.index"));
        let on_temp = data.join(format!("volume-{A}.index.tmp"));
        let off = data.join(format!("volume-{B}.index"));
        for path in [&on, &on_temp, &off] {
            aged(path, 31);
        }
        let config = crate::EngineConfig {
            indexed_volumes: vec![A.to_owned()],
            ..config(&boot)
        };
        let (_engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        assert!(on.exists(), "the switched-on disk's file was removed");
        assert!(
            !on_temp.exists(),
            "a switched-on disk's left-over temp file stayed"
        );
        assert!(!off.exists(), "a switched-off disk's file stayed");
    }

    #[test]
    fn clean_drops_a_switched_off_disk_after_30_days() {
        let tree = TempTree::new("vol-clean-off");
        let data = tree.data();
        fs::create_dir_all(&data).unwrap();
        let old = data.join(format!("volume-{B}.index"));
        let young = data.join(format!("volume-{C}.index"));
        let near = data.join(format!("volume-{A}x.index"));
        aged(&old, 31);
        aged(&young, 29);
        aged(&near, 31);
        clean(&data, &[A.to_owned(), format!("{B}x")]);
        assert!(!old.exists() && !near.exists());
        assert!(young.exists());
    }

    #[test]
    fn drop_with_a_crawling_volume_joins_every_thread() {
        let boot = TempTree::new("vol-drop");
        let (a, b) = (drive("vol-drop-a"), drive("vol-drop-b"));
        let (engine, listener, rx) = start(&boot);
        phases(&rx);
        let (reached_tx, reached) = mpsc::channel();
        let saw_stop = Arc::new(AtomicBool::new(false));
        *shared(&engine).opened.lock().unwrap() = Some(hold_open(reached_tx, saw_stop.clone()));
        engine.set_volumes(vec![vol(&a, A), vol(&b, B)]).unwrap();
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        until_state(&rx, |s| s.indexing.len() == 1 && s.indexed >= BOOT + DRIVE);
        drop(engine);
        assert!(saw_stop.load(Ordering::Relaxed));
        assert_eq!(Arc::strong_count(&listener), 1);
    }

    #[test]
    fn a_refused_volume_root_stays_out() {
        let boot = TempTree::new("vol-denied");
        let a = drive("vol-denied-a");
        let _locked = Locked::new(vec![a.0.clone()]);
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let mut crawling = false;
        loop {
            match next(&rx) {
                Heard::State(s) if s.phase == EnginePhase::Crawling => crawling = true,
                Heard::State(s) if crawling => {
                    assert_eq!(s.indexed, BOOT);
                    break;
                }
                _ => {}
            }
        }
        assert_eq!(count(&engine, &rx, "mark-"), 0);
    }

    #[test]
    fn a_refused_volume_root_is_reported_and_not_saved() {
        let boot = TempTree::new("vol-refused");
        let a = drive("vol-refused-a");
        let _locked = Locked::new(vec![a.0.clone()]);
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let refused = loop {
            if let Heard::State(s) = next(&rx)
                && s.troubles
                    .iter()
                    .any(|t| t.kind == EngineTroubleKind::Unreadable)
            {
                break s;
            }
        };
        assert_eq!(
            refused.troubles,
            [EngineTrouble {
                root: a.real(),
                kind: EngineTroubleKind::Unreadable,
            }]
        );
        assert_eq!(refused.indexed, BOOT);
        assert!(refused.indexing.is_empty());
        assert!(matches!(
            refused.boot_phase,
            EnginePhase::Ready | EnginePhase::Live
        ));
        assert_eq!(volume_files(&boot), Vec::<String>::new());
        assert_eq!(count(&engine, &rx, "mark-"), 0);
        engine.set_volumes(Vec::new()).unwrap();
        let s = until_state(&rx, |s| s.troubles.is_empty());
        assert_eq!(s.indexed, BOOT);
    }

    #[test]
    fn a_finishing_disk_stays_in_the_indexing_group() {
        let boot = TempTree::new("vol-finishing");
        let a = drive("vol-finishing-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let ((reached, at), (go, gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).save_hold.lock().unwrap() = Some((reached, gate));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let last = rx
            .try_iter()
            .filter_map(|e| match e {
                Heard::State(s) => Some(s),
                _ => None,
            })
            .last()
            .unwrap();
        assert_eq!(
            (last.phase, last.indexing.clone()),
            (EnginePhase::Finishing, vec![a.real()])
        );
        assert!(!file(&boot, A).exists());
        go.send(()).unwrap();
        let s = until_state(&rx, |s| s.indexing.is_empty());
        assert_eq!(s.indexed, BOOT + DRIVE);
    }

    #[test]
    fn a_panicking_volume_thread_lists_the_disk() {
        let boot = TempTree::new("vol-panic");
        let a = drive("vol-panic-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        *shared(&engine).opened.lock().unwrap() =
            Some(Arc::new(|_: &AtomicBool| panic!("injected crawl panic")));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        let mut faulted = false;
        let s = loop {
            match next(&rx) {
                Heard::Fault(m) => faulted |= m.contains("injected crawl panic"),
                Heard::State(s) if !s.troubles.is_empty() => break s,
                _ => {}
            }
        };
        assert!(faulted);
        assert_eq!(
            s.troubles,
            [EngineTrouble {
                root: a.real(),
                kind: EngineTroubleKind::Unreadable,
            }]
        );
        assert!(s.indexing.is_empty());
        assert!(matches!(
            s.boot_phase,
            EnginePhase::Ready | EnginePhase::Live
        ));
        assert_eq!(volume_files(&boot), Vec::<String>::new());
        assert!(count(&engine, &rx, "txt") >= 3);
    }

    #[test]
    fn a_panicking_rebuild_keeps_the_old_index() {
        let boot = TempTree::new("rebuild-panic");
        fs::create_dir(boot.0.join("Nothing")).unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        settle(&engine);
        let before = shared(&engine).units()[0].clone();
        *shared(&engine).opened.lock().unwrap() =
            Some(Arc::new(|_: &AtomicBool| panic!("injected crawl panic")));
        engine
            .set_excluded(vec![format!("{}/Nothing", boot.real())])
            .unwrap();
        let mut faulted = false;
        let s = loop {
            match next(&rx) {
                Heard::Fault(m) => faulted |= m.contains("injected crawl panic"),
                Heard::State(s)
                    if faulted
                        && matches!(s.boot_phase, EnginePhase::Ready | EnginePhase::Live) =>
                {
                    break s;
                }
                _ => {}
            }
        };
        assert!(s.troubles.is_empty());
        rebuilt(&engine);
        assert!(Arc::ptr_eq(&shared(&engine).units()[0], &before));
        assert_eq!(count(&engine, &rx, "txt"), 3);
    }

    #[test]
    fn a_rebuild_crawl_reports_finishing_until_saved() {
        let boot = TempTree::new("rebuild-finishing");
        fs::create_dir(boot.0.join("Nothing")).unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        settle(&engine);
        let ((reached, at_swap), (swap, swap_gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).swap_hold.lock().unwrap() = Some((reached, swap_gate));
        let ((reached, at_save), (save, save_gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).save_hold.lock().unwrap() = Some((reached, save_gate));
        engine
            .set_excluded(vec![format!("{}/Nothing", boot.real())])
            .unwrap();
        let states = |rx: &Receiver<Heard>| -> Vec<EngineState> {
            rx.try_iter()
                .filter_map(|e| match e {
                    Heard::State(s) => Some(s),
                    _ => None,
                })
                .collect()
        };
        at_swap.recv_timeout(Duration::from_secs(10)).unwrap();
        let built = states(&rx).pop().unwrap();
        assert_eq!(
            (built.phase, built.boot_phase),
            (EnginePhase::Finishing, EnginePhase::Finishing)
        );
        swap.send(()).unwrap();
        at_save.recv_timeout(Duration::from_secs(10)).unwrap();
        let swapped = states(&rx);
        assert!(!swapped.is_empty());
        assert!(
            swapped
                .iter()
                .all(|s| s.boot_phase == EnginePhase::Finishing),
            "{swapped:?}"
        );
        save.send(()).unwrap();
        let s = until_state(&rx, |s| s.boot_phase != EnginePhase::Finishing);
        assert_eq!(s.boot_phase, EnginePhase::Ready);
        rebuilt(&engine);
    }

    #[test]
    fn a_backup_folder_on_a_disk_is_indexed() {
        let boot = TempTree::new("vol-backup");
        let a = drive("vol-backup-a");
        let backups = a.0.join("Backups.backupdb");
        fs::create_dir(&backups).unwrap();
        fs::write(backups.join("old.txt"), b"").unwrap();
        let mut config = config(&boot);
        config.excluded = vec![a.0.join("Sub").to_str().unwrap().to_owned()];
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_count(&rx, BOOT + DRIVE + 1);
        assert_eq!(count(&engine, &rx, "old.txt"), 1);
        assert_eq!(count(&engine, &rx, "delta"), 1);
    }

    #[test]
    fn a_mount_during_the_boot_crawl_is_indexed() {
        let boot = TempTree::new("vol-early");
        let a = drive("vol-early-a");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&boot), Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(
            next(&rx),
            Heard::State(s) if s.phase == EnginePhase::Crawling && s.indexed == 0
        ));
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        release.send(None).unwrap();
        until_count(&rx, BOOT + DRIVE);
        let (ma, ra) = (mark("vol-early-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], true);
    }

    #[test]
    fn mount_eject_mount_indexes_the_disk_once() {
        let boot = TempTree::new("vol-again");
        let a = drive("vol-again-a");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        engine.set_volumes(Vec::new()).unwrap();
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        settle(&engine);
        let (ma, ra) = (mark("vol-again-a"), a.real());
        seek(&engine, &rx, "mark-", &[(&ma, &ra)], false);
        assert_eq!(shared(&engine).units().len(), 2);
    }

    #[test]
    fn a_rename_during_the_crawl_moves_the_hits() {
        let boot = TempTree::new("vol-rename-crawl");
        let b = drive("vol-rename-crawl-b");
        let moved = TempTree(PathBuf::from(format!("{}-moved", b.0.display())));
        let _ = fs::remove_dir_all(&moved.0);
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let (reached_tx, reached) = mpsc::channel();
        let saw_stop = Arc::new(AtomicBool::new(false));
        *shared(&engine).opened.lock().unwrap() = Some(hold_open(reached_tx, saw_stop.clone()));
        engine.set_volumes(vec![vol(&b, B)]).unwrap();
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        fs::rename(&b.0, &moved.0).unwrap();
        engine.set_volumes(vec![vol(&moved, B)]).unwrap();
        assert!(saw_stop.load(Ordering::Relaxed));
        settle(&engine);
        let (mb, new) = (mark("vol-rename-crawl-b"), moved.real());
        seek(&engine, &rx, "mark-", &[(&mb, &new)], false);
        assert_eq!(volume_files(&boot), [format!("volume-{B}.index")]);
    }

    #[test]
    fn an_eject_during_a_search_keeps_its_rows() {
        let boot = TempTree::new("vol-eject-search");
        let a = drive("vol-eject-search-a");
        let (engine, _listener, rx) = start(&boot);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        until_count(&rx, BOOT + DRIVE);
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        engine.set_volumes(Vec::new()).unwrap();
        let n = ready(&rx, g);
        assert!(n == 3 || n == 7, "{n}");
        assert_eq!(session.rows(g, 0, n).unwrap().len(), n as usize);
        seek(&engine, &rx, "mark-", &[], false);
    }

    #[test]
    fn two_callers_at_once_add_each_volume_once() {
        let boot = TempTree::new("vol-callers");
        let (a, b) = (drive("vol-callers-a"), drive("vol-callers-b"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let gate = Arc::new(Barrier::new(2));
        let callers: Vec<_> = [vec![vol(&a, A), vol(&b, B)], vec![vol(&b, B), vol(&a, A)]]
            .into_iter()
            .map(|list| {
                let (engine, gate) = (engine.clone(), gate.clone());
                thread::spawn(move || {
                    gate.wait();
                    engine.set_volumes(list)
                })
            })
            .collect();
        for caller in callers {
            caller.join().unwrap().unwrap();
        }
        until_count(&rx, BOOT + 2 * DRIVE);
        let (ra, rb) = (a.real(), b.real());
        let (ma, mb) = (mark("vol-callers-a"), mark("vol-callers-b"));
        seek(&engine, &rx, "mark-", &[(&ma, &ra), (&mb, &rb)], true);
        assert_eq!(shared(&engine).units().len(), 3);
    }

    fn kept_and_dropped(name: &str) -> (TempTree, Arc<Engine>, Arc<Recorder>, Receiver<Heard>) {
        let boot = TempTree::new(name);
        for (dir, file) in [("Keep", "keepme.txt"), ("Drop", "dropme.txt")] {
            fs::create_dir(boot.0.join(dir)).unwrap();
            fs::write(boot.0.join(dir).join(file), b"").unwrap();
        }
        let (engine, listener, rx) = start(&boot);
        phases(&rx);
        let root = boot.real();
        seek(
            &engine,
            &rx,
            "keepme",
            &[("keepme.txt", &format!("{root}/Keep"))],
            true,
        );
        seek(
            &engine,
            &rx,
            "dropme",
            &[("dropme.txt", &format!("{root}/Drop"))],
            true,
        );
        (boot, engine, listener, rx)
    }

    fn given(path: PathBuf) -> String {
        path.to_str().unwrap().to_owned()
    }

    fn boot_crawls(engine: &Engine, boot: &TempTree) -> usize {
        let root = PathBuf::from(boot.real());
        shared(engine)
            .crawls
            .lock()
            .unwrap()
            .iter()
            .filter(|r| **r == root)
            .count()
    }

    fn hold_at(nth: usize, reached: Sender<()>, release: Receiver<()>) -> crawl::Hook {
        let calls = AtomicUsize::new(0);
        let (reached, release) = (Mutex::new(Some(reached)), Mutex::new(release));
        Arc::new(move |stop: &AtomicBool| {
            if calls.fetch_add(1, Ordering::Relaxed) + 1 != nth {
                return;
            }
            if let Some(reached) = reached.lock().unwrap().take() {
                let _ = reached.send(());
            }
            let release = release.lock().unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
                if release.recv_timeout(Duration::from_millis(5)).is_ok() {
                    return;
                }
            }
        })
    }

    #[test]
    fn an_unregistered_volume_exclusion_never_recrawls_boot() {
        let boot = TempTree::new("excl-unregistered");
        let folder = boot.0.join("Vols/Drive/Skip");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("stale.txt"), b"").unwrap();
        let (engine, _listener, rx) = start_in_volumes(config(&boot));
        phases(&rx);
        let real_folder = given(engine::real(&folder));
        seek(&engine, &rx, "stale", &[("stale.txt", &real_folder)], true);
        let before = shared(&engine).settings.exclusions().print.clone();
        engine.set_excluded(vec![real_folder.clone()]).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        assert_eq!(shared(&engine).settings.exclusions().print, before);
        assert_eq!(count(&engine, &rx, "stale"), 0);
        let unit = shared(&engine).units()[0].clone();
        assert_eq!(unit.skip, [PathBuf::from(&real_folder)]);
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert!((0..saved.entries() as usize).all(|i| saved.ent_name(i) != b"stale.txt"));

        engine.set_excluded(Vec::new()).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        seek(&engine, &rx, "stale", &[("stale.txt", &real_folder)], true);
        let unit = shared(&engine).units()[0].clone();
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert!((0..saved.entries() as usize).any(|i| saved.ent_name(i) == b"stale.txt"));
    }

    #[test]
    fn a_missing_volume_exclusion_loads_the_same_boot_fingerprint() {
        let boot = TempTree::new("excl-missing-volume");
        let drive = PathBuf::from(boot.real()).join("Vols/Drive");
        fs::create_dir_all(drive.join("Skip")).unwrap();
        fs::write(drive.join("Skip/stale.txt"), b"").unwrap();
        let list = vec![given(drive.join("Skip"))];
        let (engine, _listener, rx) = start_in_volumes(config(&boot));
        phases(&rx);
        engine.set_excluded(list.clone()).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        drop(engine);
        fs::remove_dir_all(drive).unwrap();
        let mut again = config(&boot);
        again.excluded = list;
        let (engine, _listener, rx) = start_in_volumes(again);
        let seen = phases(&rx);
        assert!(
            seen.iter()
                .all(|(phase, _)| *phase != EnginePhase::Crawling),
            "{seen:?}"
        );
        assert_eq!(boot_crawls(&engine, &boot), 0);
        assert_eq!(count(&engine, &rx, "stale"), 0);
        engine.set_excluded(Vec::new()).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 0);
    }

    #[test]
    fn volume_exclusions_changed_between_launches_apply_without_a_boot_crawl() {
        let boot = TempTree::new("excl-relaunch-volume");
        let folder = PathBuf::from(boot.real()).join("Vols/Drive/Skip");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("stale.txt"), b"").unwrap();
        let (engine, _listener, rx) = start_in_volumes(config(&boot));
        phases(&rx);
        drop(engine);
        let mut again = config(&boot);
        again.excluded = vec![given(folder.clone())];
        let (engine, _listener, rx) = start_in_volumes(again);
        phases(&rx);
        assert_eq!(boot_crawls(&engine, &boot), 0);
        assert_eq!(count(&engine, &rx, "stale"), 0);
        let unit = shared(&engine).units()[0].clone();
        apply::fold(shared(&engine), &unit, &unit).unwrap();
        drop(unit);
        drop(engine);
        let (engine, _listener, rx) = start_in_volumes(config(&boot));
        phases(&rx);
        assert_eq!(boot_crawls(&engine, &boot), 0);
        let folder = given(folder);
        seek(&engine, &rx, "stale", &[("stale.txt", &folder)], true);
    }

    #[test]
    fn a_registered_volume_keeps_its_own_exclusion() {
        let boot = TempTree::new("excl-volume-rule");
        let drive = PathBuf::from(boot.real()).join("Vols/Drive");
        fs::create_dir_all(drive.join("Skip")).unwrap();
        fs::write(drive.join("Skip/indisk.txt"), b"").unwrap();
        let (engine, _listener, rx) = start_in_volumes(config(&boot));
        phases(&rx);
        engine
            .set_volumes(vec![EngineVolume {
                root: given(drive.clone()),
                id: A.to_owned(),
            }])
            .unwrap();
        settle(&engine);
        let folder = given(drive.join("Skip"));
        seek(&engine, &rx, "indisk", &[("indisk.txt", &folder)], false);
        engine.set_excluded(vec![folder.clone()]).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        assert_eq!(count(&engine, &rx, "indisk"), 0);
        engine.set_excluded(Vec::new()).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        seek(&engine, &rx, "indisk", &[("indisk.txt", &folder)], false);
    }

    #[test]
    fn a_failed_volume_add_keeps_the_pending_exclusion_rebuild() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-add-failure");
        let (a, b, c) = (
            drive("excl-add-a"),
            drive("excl-add-b"),
            drive("excl-add-c"),
        );
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        settle(&engine);
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        shared(&engine).fail_add.store(true, Ordering::Relaxed);
        assert!(matches!(
            engine.set_volumes(vec![vol(&b, B), vol(&c, C)]),
            Err(EngineError::Io { .. })
        ));
        let _ = release.send(());
        rebuilt(&engine);
        settle(&engine);
        assert_eq!(count(&engine, &rx, "dropme"), 0);
        let units = shared(&engine).units();
        assert!(units.iter().any(|u| u.id.as_deref() == Some(C)));
        assert!(
            units
                .iter()
                .all(|u| !matches!(u.id.as_deref(), Some(A | B)))
        );
        drop(units);
        engine.set_volumes(vec![vol(&b, B), vol(&c, C)]).unwrap();
        settle(&engine);
        assert_eq!(shared(&engine).units().len(), 3);
    }

    #[test]
    fn a_failed_rebuild_spawn_after_eject_is_retried_by_the_same_volume_list() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-eject-spawn");
        let a = drive("excl-eject-spawn-a");
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        settle(&engine);
        let dropped = engine::real(&boot.0.join("Drop"));
        let (reached, at) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        *shared(&engine).opened.lock().unwrap() = Some(hold_open(reached, stopped.clone()));
        engine.set_excluded(vec![given(dropped.clone())]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        for _ in 0..2 {
            shared(&engine).fail_rebuild.store(true, Ordering::Relaxed);
            assert!(matches!(
                engine.set_volumes(Vec::new()),
                Err(EngineError::Io { .. })
            ));
            assert!(stopped.load(Ordering::Relaxed));
            assert_eq!(shared(&engine).units().len(), 1);
            assert!(!open_under(&a.real()));
            assert_eq!(
                shared(&engine).settings.exclusions().excluded.as_slice(),
                std::slice::from_ref(&dropped)
            );
            assert_eq!(count(&engine, &rx, "dropme"), 1);
        }
        engine.set_volumes(Vec::new()).unwrap();
        rebuilt(&engine);
        assert_eq!(count(&engine, &rx, "dropme"), 0);
        seek(
            &engine,
            &rx,
            "keepme",
            &[("keepme.txt", &format!("{}/Keep", boot.real()))],
            true,
        );
        let unit = shared(&engine).units()[0].clone();
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert!((0..saved.entries() as usize).all(|i| saved.ent_name(i) != b"dropme.txt"));
    }

    #[test]
    fn a_failed_rebuild_spawn_keeps_the_previous_list_and_worker() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-spawn-failure");
        let dropped = engine::real(&boot.0.join("Drop"));
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine.set_excluded(vec![given(dropped.clone())]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let before = shared(&engine).settings.boot_inputs();
        shared(&engine).fail_rebuild.store(true, Ordering::Relaxed);
        assert!(matches!(
            engine.set_excluded(vec![given(boot.0.join("Keep"))]),
            Err(EngineError::Io { .. })
        ));
        assert_eq!(shared(&engine).settings.exclusions().excluded, [dropped]);
        assert_eq!(shared(&engine).settings.boot_inputs(), before);
        release.send(()).unwrap();
        rebuilt(&engine);
        assert_eq!(count(&engine, &rx, "dropme"), 0);
        seek(
            &engine,
            &rx,
            "keepme",
            &[("keepme.txt", &format!("{}/Keep", boot.real()))],
            true,
        );
    }

    #[test]
    fn an_excluded_folder_leaves_and_comes_back() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-leave");
        let root = boot.real();
        let dropped = format!("{root}/Drop");
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        seek(&engine, &rx, "dropme", &[], true);
        seek(
            &engine,
            &rx,
            "keepme",
            &[("keepme.txt", &format!("{root}/Keep"))],
            true,
        );
        engine.set_excluded(Vec::new()).unwrap();
        seek(&engine, &rx, "dropme", &[("dropme.txt", &dropped)], true);
    }

    #[test]
    fn the_replaced_boot_unit_is_released() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-release");
        let old = Arc::downgrade(&shared(&engine).units()[0]);
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        seek(&engine, &rx, "dropme", &[], true);
        rebuilt(&engine);
        let deadline = Instant::now() + Duration::from_secs(10);
        while old.upgrade().is_some() {
            assert!(Instant::now() < deadline, "the old boot unit is still held");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_replaced_unit_never_saves_after_its_successor() {
        let (boot, engine, _listener, _rx) = kept_and_dropped("excl-fence");
        let old = shared(&engine).units()[0].clone();
        let ((reached, at), (go, gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).swap_hold.lock().unwrap() = Some((reached, gate));
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(apply::fold(shared(&engine), &old, &old).is_some());
        go.send(()).unwrap();
        rebuilt(&engine);
        let unit = shared(&engine).units()[0].clone();
        assert!(!Arc::ptr_eq(&unit, &old));
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert_eq!(saved.fingerprint(), unit.print);
        assert!((0..saved.entries() as usize).all(|i| saved.ent_name(i) != b"dropme.txt"));
        assert!(apply::fold(shared(&engine), &old, &old).is_none());

        let disk = drive("excl-fence-disk");
        let ((reached, at), (go, gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).save_hold.lock().unwrap() = Some((reached, gate));
        engine.set_volumes(vec![vol(&disk, A)]).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let on_disk = |engine: &Engine| {
            shared(engine)
                .units()
                .iter()
                .find(|u| u.id.is_some())
                .unwrap()
                .clone()
        };
        let held = on_disk(&engine);
        engine
            .set_excluded(vec![given(boot.0.join("Drop")), given(disk.0.join("Sub"))])
            .unwrap();
        assert!(!Arc::ptr_eq(&on_disk(&engine), &held));
        let until = Instant::now() + Duration::from_millis(300);
        while Instant::now() < until {
            assert_eq!(
                boot_crawls(&engine, &disk),
                1,
                "crawled before the save ended"
            );
            thread::sleep(Duration::from_millis(10));
        }
        go.send(()).unwrap();
        rebuilt(&engine);
        settle(&engine);
        assert_eq!(boot_crawls(&engine, &disk), 2);
        let unit = on_disk(&engine);
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert_eq!(saved.fingerprint(), unit.print);
    }

    #[test]
    fn the_same_exclusions_twice_change_nothing() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-twice");
        let list = vec![given(boot.0.join("Drop"))];
        engine.set_excluded(list.clone()).unwrap();
        seek(&engine, &rx, "dropme", &[], true);
        rebuilt(&engine);
        let saved = boot.data().join(crate::index::FILE);
        let (before, units) = (stamp(&saved), shared(&engine).units().to_vec());
        assert_eq!(boot_crawls(&engine, &boot), 2);
        engine.set_excluded(list).unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 2);
        assert_eq!(stamp(&saved), before);
        let now = shared(&engine).units().to_vec();
        assert!(units.iter().zip(&now).all(|(a, b)| Arc::ptr_eq(a, b)));
        assert!(
            rx.try_iter()
                .all(|e| !matches!(e, Heard::State(s) if s.phase == EnginePhase::Crawling))
        );
    }

    #[test]
    fn the_old_index_answers_during_the_rebuild() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-during");
        let session = engine.clone().session().unwrap();
        let dropped = format!("{}/Drop", boot.real());
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let g = session.search("dropme".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [("dropme.txt".to_owned(), dropped, EngineKind::File)]
        );
        release.send(()).unwrap();
        seek(&engine, &rx, "dropme", &[], true);
    }

    #[test]
    fn the_newest_exclusions_win() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-newest");
        let root = boot.real();
        let ((reached, at), (_release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(1, reached, held));
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        engine
            .set_excluded(vec![given(boot.0.join("Keep"))])
            .unwrap();
        rebuilt(&engine);
        seek(&engine, &rx, "keepme", &[], true);
        seek(
            &engine,
            &rx,
            "dropme",
            &[("dropme.txt", &format!("{root}/Drop"))],
            true,
        );
        let unit = shared(&engine).units()[0].clone();
        assert_eq!(unit.skip, [PathBuf::from(format!("{root}/Keep"))]);
        assert_eq!(unit.print, shared(&engine).settings.exclusions().print);
        let saved = Index::load(&unit.file, unit.root.clone()).unwrap();
        assert_eq!(saved.fingerprint(), unit.print);
    }

    #[test]
    fn the_new_fingerprint_loads_without_a_crawl() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-reload");
        let list = vec![given(boot.0.join("Drop"))];
        engine.set_excluded(list.clone()).unwrap();
        seek(&engine, &rx, "dropme", &[], true);
        rebuilt(&engine);
        drop(engine);
        let mut again = config(&boot);
        again.excluded = list;
        let (engine, _listener, rx) = start_with(again, None);
        let seen = phases(&rx);
        assert!(
            seen.iter().all(|(p, _)| *p != EnginePhase::Crawling),
            "{seen:?}"
        );
        assert_eq!(boot_crawls(&engine, &boot), 0);
        seek(&engine, &rx, "dropme", &[], true);
    }

    #[test]
    fn a_relative_or_empty_exclusion_is_refused() {
        let (boot, engine, _listener, _rx) = kept_and_dropped("excl-bad");
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        rebuilt(&engine);
        let saved = boot.data().join(crate::index::FILE);
        let before = stamp(&saved);
        let print = shared(&engine).settings.exclusions().print.clone();
        for bad in ["Drop", ""] {
            let refused = engine.set_excluded(vec![given(boot.0.join("Keep")), bad.to_owned()]);
            assert!(matches!(refused, Err(EngineError::Io { .. })), "{bad:?}");
        }
        rebuilt(&engine);
        assert_eq!(stamp(&saved), before);
        assert_eq!(shared(&engine).settings.exclusions().print, print);
        assert_eq!(boot_crawls(&engine, &boot), 2);
    }

    #[test]
    fn an_exclusion_rebuilds_only_the_unit_that_holds_it() {
        let boot = TempTree::new("excl-units");
        let a = drive("excl-units-a");
        fs::create_dir(boot.0.join("Out")).unwrap();
        fs::write(boot.0.join("Out/onboot.txt"), b"").unwrap();
        fs::create_dir(a.0.join("Skip")).unwrap();
        fs::write(a.0.join("Skip/ondisk.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(vec![vol(&a, A)]).unwrap();
        settle(&engine);
        let (on_boot, on_disk) = (format!("{}/Out", boot.real()), format!("{}/Skip", a.real()));
        seek(&engine, &rx, "ondisk", &[("ondisk.txt", &on_disk)], false);
        seek(&engine, &rx, "onboot", &[("onboot.txt", &on_boot)], false);
        let (boot_file, disk_file) = (boot.data().join(crate::index::FILE), file(&boot, A));
        let (boot_before, disk_before) = (stamp(&boot_file), stamp(&disk_file));

        let disk_only = vec![given(a.0.join("Skip"))];
        engine.set_excluded(disk_only.clone()).unwrap();
        seek(&engine, &rx, "ondisk", &[], false);
        rebuilt(&engine);
        assert_eq!(stamp(&boot_file), boot_before);
        let disk_after = stamp(&disk_file);
        assert_ne!(disk_after, disk_before);
        assert_eq!(boot_crawls(&engine, &boot), 1);

        engine
            .set_excluded([disk_only, vec![given(boot.0.join("Out"))]].concat())
            .unwrap();
        seek(&engine, &rx, "onboot", &[], false);
        rebuilt(&engine);
        assert_ne!(stamp(&boot_file), boot_before);
        assert_eq!(stamp(&disk_file), disk_after);
        seek(&engine, &rx, "ondisk", &[], false);
    }

    #[test]
    fn a_disk_inside_the_boot_root_never_crawls_the_boot_unit() {
        let boot = TempTree::new("excl-inside");
        let disk = boot.0.join("Drive");
        fs::create_dir_all(disk.join("Skip")).unwrap();
        fs::write(disk.join("Skip/indisk.txt"), b"").unwrap();
        let volumes = vec![EngineVolume {
            root: given(engine::real(&disk)),
            id: A.to_owned(),
        }];
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        engine.set_volumes(volumes.clone()).unwrap();
        settle(&engine);
        let inside = format!("{}/Drive/Skip", boot.real());
        seek(&engine, &rx, "indisk", &[("indisk.txt", &inside)], false);
        let before = stamp(&file(&boot, A));
        let list = vec![given(disk.join("Skip"))];
        engine.set_excluded(list.clone()).unwrap();
        seek(&engine, &rx, "indisk", &[], false);
        rebuilt(&engine);
        settle(&engine);
        assert_ne!(stamp(&file(&boot, A)), before);
        assert_eq!(boot_crawls(&engine, &boot), 1);
        drop(engine);

        let mut again = config(&boot);
        again.excluded = list;
        let (engine, _listener, rx) = start_with(again, None);
        phases(&rx);
        engine.set_volumes(volumes).unwrap();
        settle(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 0);
        seek(&engine, &rx, "indisk", &[], false);
    }

    #[test]
    fn a_file_created_during_the_rebuild_reaches_the_new_index() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-created");
        let kept = format!("{}/Keep", boot.real());
        fs::create_dir(boot.0.join("Keep/Inner")).unwrap();
        seek(&engine, &rx, "inner", &[("Inner", &kept)], true);
        let ((reached, at), (release, held)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).opened.lock().unwrap() = Some(hold_at(3, reached, held));
        let old = shared(&engine).units()[0].clone();
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        fs::write(boot.0.join("Keep/during.txt"), b"").unwrap();
        seek(&engine, &rx, "during", &[("during.txt", &kept)], true);
        release.send(()).unwrap();
        rebuilt(&engine);
        assert!(!Arc::ptr_eq(&shared(&engine).units()[0], &old));
        seek(&engine, &rx, "during", &[("during.txt", &kept)], true);
        seek(&engine, &rx, "dropme", &[], true);
    }

    #[test]
    fn an_excluded_folder_stays_shut_when_the_exclusions_change() {
        let boot = TempTree::new("excl-shut");
        let home = boot.0.join("home");
        fs::create_dir_all(home.join("Documents/Inner")).unwrap();
        fs::create_dir(boot.0.join("Drop")).unwrap();
        let mut config = config(&boot);
        config.excluded = vec![given(home.join("Documents"))];
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        let opens = Arc::new(AtomicUsize::new(0));
        let counted = opens.clone();
        *shared(&engine).opened.lock().unwrap() = Some(Arc::new(move |_: &AtomicBool| {
            counted.fetch_add(1, Ordering::Relaxed);
        }));
        engine
            .set_excluded(vec![
                given(home.join("Documents")),
                given(boot.0.join("Drop")),
            ])
            .unwrap();
        rebuilt(&engine);
        assert_eq!(boot_crawls(&engine, &boot), 2);
        assert_eq!(opens.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn events_after_the_swap_follow_the_new_list() {
        let (boot, engine, _listener, rx) = kept_and_dropped("excl-after");
        engine
            .set_excluded(vec![given(boot.0.join("Drop"))])
            .unwrap();
        seek(&engine, &rx, "dropme", &[], true);
        rebuilt(&engine);
        fs::write(boot.0.join("Drop/dropnew.txt"), b"").unwrap();
        fs::write(boot.0.join("Keep/keepnew.txt"), b"").unwrap();
        let kept = format!("{}/Keep", boot.real());
        seek(&engine, &rx, "keepnew", &[("keepnew.txt", &kept)], true);
        assert_eq!(count(&engine, &rx, "dropnew"), 0);
    }
}
