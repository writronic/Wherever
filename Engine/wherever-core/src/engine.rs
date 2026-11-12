use std::any::Any;
use std::fs::{self, OpenOptions};
use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rayon::prelude::*;

use crate::crawl::{self, Attrs, Crawl, Pool};
use crate::error::io_error;
use crate::index::{self, Index};
use crate::live::{Found, Live};
use crate::opens::{self, Opens};
use crate::query::{self, Held, Hit, Members, Query, Scanned};
use crate::rank;
use crate::session::{Ask, EngineSession, Lane, Press, Work};
use crate::sort::{self, Ranked};
use crate::text::scope::Stopped;
use crate::text::search::{self, Verdict};
use crate::text::{READERS, Terms};
use crate::unit::{self, Unit};
use crate::{
    EngineColumn, EngineConfig, EngineError, EngineHit, EngineKind, EngineListener, EngineMatch,
    EnginePhase, EngineSort, EngineState, EngineTrouble, EngineVolume, apply,
};
use delta::{Patch, Why};

pub(crate) const CRAWL_THREADS: usize = 8;

#[derive(uniffi::Object)]
pub struct Engine {
    shared: Arc<Shared>,
    jobs: Option<Sender<Job>>,
    worker: Option<JoinHandle<()>>,
    threads: Mutex<Vec<JoinHandle<()>>>,
    mounting: Mutex<Vec<(String, PathBuf)>>,
    rebuild: Mutex<Option<(Arc<AtomicBool>, JoinHandle<()>)>>,
    command_line: Mutex<Option<cli::Server>>,
}

pub(crate) struct Shared {
    pub(crate) listener: Arc<dyn EngineListener>,
    pub(crate) settings: Settings,
    pub(crate) generation: AtomicU64,
    pub(crate) sessions: AtomicU64,
    pub(crate) archive_destinations: Arc<crate::archive::Destinations>,
    pub(crate) stop: AtomicBool,
    pub(crate) units: RwLock<Vec<Arc<Unit>>>,
    reporting: Mutex<()>,
    pub(crate) opens: Opens,
    reading: Mutex<Vec<(PathBuf, Arc<RwLock<()>>)>>,
    readers: Mutex<Vec<JoinHandle<()>>>,
    #[cfg(test)]
    pub(crate) opened: Mutex<Option<crawl::Hook>>,
    #[cfg(test)]
    pub(crate) crawls: Mutex<Vec<PathBuf>>,
    #[cfg(test)]
    pub(crate) scans: std::sync::atomic::AtomicUsize,
    #[cfg(test)]
    pub(crate) scan_hold: Mutex<Option<(Sender<u64>, Receiver<()>)>>,
    #[cfg(test)]
    pub(crate) patches: std::sync::atomic::AtomicUsize,
    #[cfg(test)]
    pub(crate) patch_hold: Mutex<Option<(Sender<u64>, Receiver<()>)>>,
    #[cfg(test)]
    pub(crate) scanned_on: Mutex<Vec<(String, usize)>>,
    #[cfg(test)]
    pub(crate) reads: Mutex<Vec<PathBuf>>,
    #[cfg(test)]
    pub(crate) read_reached: Mutex<Option<mpsc::SyncSender<PathBuf>>>,
    #[cfg(test)]
    pub(crate) read_gate: RwLock<()>,
    #[cfg(test)]
    pub(crate) read_hold: Mutex<Option<(PathBuf, mpsc::Receiver<()>)>>,
    #[cfg(test)]
    pub(crate) fail_add: AtomicBool,
    #[cfg(test)]
    pub(crate) fail_rebuild: AtomicBool,
    #[cfg(test)]
    pub(crate) fail_scan: AtomicBool,
    #[cfg(test)]
    pub(crate) fail_run: AtomicBool,
    #[cfg(test)]
    pub(crate) fail_apply: AtomicBool,
    #[cfg(test)]
    pub(crate) fail_read: AtomicBool,
    #[cfg(test)]
    pub(crate) swap_hold: Mutex<Option<(Sender<()>, Receiver<()>)>>,
    #[cfg(test)]
    pub(crate) save_hold: Mutex<Option<(Sender<()>, Receiver<()>)>>,
    #[cfg(test)]
    pub(crate) facts: Mutex<Option<(String, unit::Device)>>,
}

pub(crate) struct Settings {
    pub(crate) root: PathBuf,
    pub(crate) data: PathBuf,
    pub(crate) socket_folder: Option<PathBuf>,
    pub(crate) home: PathBuf,
    pub(crate) exclusions: RwLock<Exclusions>,
    pub(crate) typos: AtomicBool,
    pub(crate) paused: Arc<AtomicBool>,
}

#[derive(Default)]
pub(crate) struct Exclusions {
    pub(crate) excluded: Vec<PathBuf>,
    pub(crate) skip: Vec<PathBuf>,
    pub(crate) print: Vec<u8>,
    pub(crate) on_disks: Vec<(String, PathBuf)>,
    #[cfg(test)]
    volumes_root: Option<PathBuf>,
}

impl Exclusions {
    pub(crate) fn inside<'a>(
        &'a self,
        id: &'a str,
        root: &'a Path,
    ) -> impl Iterator<Item = PathBuf> + 'a {
        (self.on_disks.iter())
            .filter(move |(on, _)| on == id)
            .map(move |(_, p)| root.join(p))
    }

    pub(crate) fn joined(&self, units: &[Arc<Unit>]) -> Vec<PathBuf> {
        let mut out = self.skip.clone();
        for u in units {
            if let Some(id) = &u.id {
                out.extend(self.inside(id, &u.root));
            }
        }
        out
    }

    pub(crate) fn holds(&self, path: &Path, units: &[Arc<Unit>]) -> bool {
        self.excluded.iter().any(|p| path.starts_with(p))
            || units.iter().any(|u| {
                (u.id.as_ref())
                    .is_some_and(|id| self.inside(id, &u.root).any(|p| path.starts_with(p)))
            })
    }
}

enum Row<'a> {
    Absolute(&'a Path),
    OnDisk(&'a str, &'a Path),
}

fn row(given: &str) -> Option<Row<'_>> {
    let path = Path::new(given);
    if path.is_absolute() {
        return Some(Row::Absolute(path));
    }
    let (id, inside) = given.split_once('/')?;
    let inside = Path::new(inside);
    let mut parts = inside.components().peekable();
    (unit::uuid_shaped(id)
        && parts.peek().is_some()
        && parts.all(|c| matches!(c, std::path::Component::Normal(_))))
    .then_some(Row::OnDisk(id, inside))
}

fn refused(given: &str) -> String {
    format!("{given:?} is neither an absolute path nor a volume UUID and a path inside that disk")
}

impl Settings {
    pub(crate) fn volumes_root(&self) -> Option<PathBuf> {
        #[cfg(test)]
        if let Some(root) = &self.exclusions().volumes_root {
            return Some(root.clone());
        }
        (self.root == Path::new("/")).then(|| PathBuf::from("/Volumes"))
    }

    pub(crate) fn other_volume(&self, path: &Path) -> bool {
        self.volumes_root()
            .is_some_and(|root| path != root && path.starts_with(root))
    }

    pub(crate) fn boot_inputs(&self) -> (Vec<PathBuf>, Vec<u8>) {
        let e = self.exclusions();
        (e.skip.clone(), e.print.clone())
    }

    pub(crate) fn exclusions(&self) -> RwLockReadGuard<'_, Exclusions> {
        self.exclusions
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn exclude(&self, given: &[String]) -> Exclusions {
        let root = &self.root;
        let (mut excluded, mut on_disks) = (Vec::new(), Vec::new());
        for r in given.iter().filter_map(|g| row(g)) {
            match r {
                Row::Absolute(p) => excluded.push(real(p)),
                Row::OnDisk(id, p) => on_disks.push((id.to_owned(), p.to_path_buf())),
            }
        }
        excluded.sort();
        excluded.dedup();
        on_disks.sort();
        on_disks.dedup();
        let mut print = Vec::new();
        for p in [root, &self.home].into_iter().chain(
            excluded
                .iter()
                .filter(|p| p.starts_with(root) && !self.other_volume(p)),
        ) {
            print.extend_from_slice(p.as_os_str().as_bytes());
            print.push(0);
        }
        let skip: Vec<PathBuf> = excluded
            .iter()
            .filter(|p| !excluded.iter().any(|q| p.starts_with(q) && p != &q))
            .cloned()
            .collect();
        Exclusions {
            excluded,
            skip,
            print,
            on_disks,
            #[cfg(test)]
            volumes_root: self.exclusions().volumes_root.clone(),
        }
    }
}

pub(crate) struct Job {
    pub(crate) generation: u64,
    pub(crate) lane: Weak<Lane>,
}

const WAKE: u64 = 0;

#[cfg(test)]
pub(crate) const PAGE: usize = 128;

pub(crate) const BEST_MATCH: EngineSort = EngineSort {
    column: EngineColumn::Relevance,
    ascending: false,
    folders_first: false,
};

pub(crate) struct Results {
    pub(crate) generation: u64,
    pub(crate) searched: u64,
    query: Arc<Query>,
    found: Arc<Vec<Found>>,
    places: Arc<sort::Places>,
    gaps: Arc<sort::Gaps>,
    ranked: Vec<Ranked>,
    sort: EngineSort,
    patched: bool,
}

impl Results {
    pub(crate) fn new(
        generation: u64,
        query: Query,
        scanned: Vec<(Found, Vec<Hit>)>,
        sort: EngineSort,
        opens: &Opens,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Results> {
        let (found, ranked) = Self::gather(scanned, cancelled)?;
        let (places, gaps) = sort::places(&found, cancelled)?;
        let set = Results {
            generation,
            searched: generation,
            query: Arc::new(query),
            found: Arc::new(found),
            places: Arc::new(places),
            gaps: Arc::new(gaps),
            ranked: Vec::new(),
            sort,
            patched: false,
        };
        set.ordered(generation, ranked, sort, opens, cancelled)
    }

    fn gather(
        scanned: Vec<(Found, Vec<Hit>)>,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<(Vec<Found>, Vec<Ranked>)> {
        let mut found = Vec::with_capacity(scanned.len());
        let mut ranked = Vec::with_capacity(scanned.iter().map(|(_, h)| h.len()).sum());
        for (unit, (f, hits)) in scanned.into_iter().enumerate() {
            if cancelled() {
                return None;
            }
            ranked.par_extend(
                hits.into_par_iter()
                    .with_min_len(4096)
                    .enumerate()
                    .map(|(k, h)| {
                        #[cfg(test)]
                        sort::tally(sort::Count::Caller);
                        Ranked {
                            score: h.score,
                            file: h.file,
                            group: false,
                            unit: unit as u32,
                            k: k as u32,
                        }
                    }),
            );
            if cancelled() {
                return None;
            }
            found.push(f);
        }
        (!cancelled()).then_some((found, ranked))
    }

    fn sorted(
        &self,
        generation: u64,
        sort: EngineSort,
        opens: &Opens,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Results> {
        self.ordered(generation, self.ranked.clone(), sort, opens, cancelled)
    }

    fn ordered(
        &self,
        generation: u64,
        mut ranked: Vec<Ranked>,
        sort: EngineSort,
        opens: &Opens,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Results> {
        let reverse = sort.ascending == (sort.column == EngineColumn::Relevance);
        let ahead =
            (sort.folders_first && sort.column != EngineColumn::Relevance).then_some(!reverse);
        let grouped = sort::by_column(
            &self.found,
            &self.places,
            &mut ranked,
            sort.column,
            ahead,
            cancelled,
        )?;
        if sort.column == EngineColumn::Relevance {
            lift(&mut ranked, &self.query, &self.found, opens, now_secs());
        }
        if reverse {
            ranked.reverse();
        }
        if sort.folders_first && !grouped {
            folders_first(&self.found, &mut ranked, cancelled)?;
        }
        (!cancelled()).then(|| self.with(generation, ranked, sort))
    }

    fn with(&self, generation: u64, ranked: Vec<Ranked>, sort: EngineSort) -> Results {
        Results {
            generation,
            searched: self.searched,
            query: self.query.clone(),
            found: self.found.clone(),
            places: self.places.clone(),
            gaps: self.gaps.clone(),
            ranked,
            sort,
            patched: self.patched,
        }
    }

    pub(crate) fn count(&self) -> u32 {
        u32::try_from(self.ranked.len()).unwrap_or(u32::MAX)
    }

    pub(crate) fn rows(&self, start: usize, count: usize) -> Vec<EngineHit> {
        self.hits(start, count, true)
    }

    fn hits(&self, start: usize, count: usize, marks: bool) -> Vec<EngineHit> {
        let end = start.saturating_add(count).min(self.ranked.len());
        self.ranked[start.min(end)..end]
            .iter()
            .filter_map(|r| self.found[r.unit as usize].row(r.k as usize))
            .map(|mut h| {
                if marks {
                    h.matches = matches(&self.query, &h.name);
                }
                h
            })
            .collect()
    }
}

fn folders_first(
    found: &[Found],
    ranked: &mut [Ranked],
    cancelled: &dyn Fn() -> bool,
) -> Option<()> {
    let folder: Vec<bool> = ranked
        .par_iter()
        .with_min_len(4096)
        .map(|r| {
            #[cfg(test)]
            sort::tally(sort::Count::Caller);
            found[r.unit as usize]
                .attrs(r.k as usize)
                .is_some_and(|a| a.kind == EngineKind::Folder)
        })
        .collect();
    if cancelled() {
        return None;
    }
    let pick = |want: bool| -> Vec<Ranked> {
        ranked
            .par_iter()
            .zip(&folder)
            .with_min_len(4096)
            .filter(|&(_, &f)| {
                #[cfg(test)]
                sort::tally(sort::Count::Caller);
                f == want
            })
            .map(|(r, _)| *r)
            .collect()
    };
    let (mut order, files) = (pick(true), pick(false));
    if cancelled() {
        return None;
    }
    order.extend(files);
    ranked.copy_from_slice(&order);
    (!cancelled()).then_some(())
}

fn matches(q: &Query, name: &str) -> Vec<EngineMatch> {
    if name.contains(char::REPLACEMENT_CHARACTER) {
        return Vec::new();
    }
    let units = |s: &str| u32::try_from(s.encode_utf16().count()).unwrap_or(u32::MAX);
    rank::positions(q, name.as_bytes())
        .into_iter()
        .map(|r| EngineMatch {
            start: units(&name[..r.start]),
            length: units(&name[r]),
        })
        .collect()
}

fn lift(ranked: &mut [Ranked], q: &Query, found: &[Found], opens: &Opens, now: u64) {
    if opens.is_empty() {
        return;
    }
    let n = ranked.len().min(opens::LIFTED);
    rank::lift(&mut ranked[..n], |r| {
        match found[r.unit as usize].row(r.k as usize) {
            Some(h) => {
                let path = Path::new(&h.folder).join(&h.name);
                let s = opens.score(path.as_os_str().as_bytes(), now);
                (rank::tier(q, h.name.as_bytes(), r.score), opens::boost(s))
            }
            None => (u8::MAX, 0),
        }
    });
}

impl Shared {
    fn new(listener: Arc<dyn EngineListener>, settings: Settings) -> Shared {
        Shared {
            listener,
            opens: Opens::new(settings.data.join(opens::FILE)),
            settings,
            generation: AtomicU64::new(0),
            sessions: AtomicU64::new(0),
            archive_destinations: Default::default(),
            stop: AtomicBool::new(false),
            units: RwLock::new(Vec::new()),
            reporting: Mutex::new(()),
            reading: Mutex::new(Vec::new()),
            readers: Mutex::new(Vec::new()),
            #[cfg(test)]
            opened: Mutex::new(None),
            #[cfg(test)]
            crawls: Mutex::new(Vec::new()),
            #[cfg(test)]
            scans: std::sync::atomic::AtomicUsize::new(0),
            #[cfg(test)]
            scan_hold: Mutex::new(None),
            #[cfg(test)]
            patches: std::sync::atomic::AtomicUsize::new(0),
            #[cfg(test)]
            patch_hold: Mutex::new(None),
            #[cfg(test)]
            scanned_on: Mutex::new(Vec::new()),
            #[cfg(test)]
            reads: Mutex::new(Vec::new()),
            #[cfg(test)]
            read_reached: Mutex::new(None),
            #[cfg(test)]
            read_gate: RwLock::new(()),
            #[cfg(test)]
            read_hold: Mutex::new(None),
            #[cfg(test)]
            fail_add: AtomicBool::new(false),
            #[cfg(test)]
            fail_rebuild: AtomicBool::new(false),
            #[cfg(test)]
            fail_scan: AtomicBool::new(false),
            #[cfg(test)]
            fail_run: AtomicBool::new(false),
            #[cfg(test)]
            fail_apply: AtomicBool::new(false),
            #[cfg(test)]
            fail_read: AtomicBool::new(false),
            #[cfg(test)]
            swap_hold: Mutex::new(None),
            #[cfg(test)]
            save_hold: Mutex::new(None),
            #[cfg(test)]
            facts: Mutex::new(None),
        }
    }

    pub(crate) fn report(&self) {
        let _turn = self
            .reporting
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let rank = |p: EnginePhase| match p {
            EnginePhase::Live => 0,
            EnginePhase::Failed => 1,
            EnginePhase::Ready => 2,
            EnginePhase::Loading => 3,
            EnginePhase::Finishing => 4,
            EnginePhase::Crawling => 5,
        };
        let (mut phase, mut indexed) = (EnginePhase::Live, 0);
        let (mut boot_phase, mut indexing, mut troubles) =
            (EnginePhase::Loading, Vec::new(), Vec::new());
        for u in self.units().iter() {
            let (p, n) = u.status();
            indexed += n;
            if rank(p) > rank(phase) {
                phase = p;
            }
            let root = || u.root.to_string_lossy().into_owned();
            if u.id.is_none() {
                boot_phase = p;
            } else if matches!(
                p,
                EnginePhase::Loading | EnginePhase::Crawling | EnginePhase::Finishing
            ) {
                indexing.push(root());
            }
            if let Some(kind) = u.trouble() {
                troubles.push(EngineTrouble { root: root(), kind });
            }
        }
        let _ = self.listener.state_changed(EngineState {
            phase,
            boot_phase,
            indexing,
            troubles,
            indexed,
        });
    }

    #[cfg(test)]
    pub(crate) fn crawled(&self, unit: &Unit) {
        self.crawls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(unit.root.clone());
    }

    pub(crate) fn fault(&self, message: String) {
        let _ = self.listener.fault(message);
    }

    fn reading(&self, root: &Path) -> Arc<RwLock<()>> {
        let mut locks = self.reading.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((_, lock)) = locks.iter().find(|(r, _)| r == root) {
            return lock.clone();
        }
        let lock = Arc::new(RwLock::new(()));
        locks.push((root.to_path_buf(), lock.clone()));
        lock
    }

    pub(crate) fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    pub(crate) fn settling(&self) -> bool {
        let paused = self.settings.paused.load(Ordering::Relaxed);
        !self.stopped() && self.units().iter().any(|u| u.settling(paused))
    }

    pub(crate) fn units(&self) -> RwLockReadGuard<'_, Vec<Arc<Unit>>> {
        self.units.read().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn premerge(&self, at: &Unit, index: &Arc<Index>) {
        let set: Vec<Arc<Index>> = {
            let units = self.units();
            if !units.iter().any(|u| std::ptr::eq(&**u, at)) {
                return;
            }
            units
                .iter()
                .filter_map(|u| {
                    if std::ptr::eq(&**u, at) {
                        Some(index.clone())
                    } else {
                        u.read(|l| l.base.clone())
                    }
                })
                .collect()
        };
        sort::premerge(&set);
    }

    pub(crate) fn nested(&self, root: &Path) -> Vec<PathBuf> {
        self.units()
            .iter()
            .map(|u| &u.root)
            .filter(|r| *r != root && r.starts_with(root))
            .cloned()
            .collect()
    }
}

#[uniffi::export]
impl Engine {
    #[uniffi::constructor]
    pub fn new(
        config: EngineConfig,
        listener: Arc<dyn EngineListener>,
    ) -> Result<Arc<Self>, EngineError> {
        for p in config.excluded.iter().filter(|p| row(p).is_none()) {
            let _ = listener.fault(format!("{}, so it is left out", refused(p)));
        }
        Self::with_settings(settle(&config)?, config.indexed_volumes, listener)
    }

    pub fn archive_extensions(&self) -> Result<Vec<String>, EngineError> {
        Ok(crate::archive::EXTENSIONS.map(str::to_owned).to_vec())
    }

    pub fn open_archive(
        self: Arc<Self>,
        path: String,
        shown_as: String,
    ) -> Result<Arc<crate::ArchiveSession>, EngineError> {
        if self.shared.stopped() {
            return Err(EngineError::Stopped);
        }
        crate::ArchiveSession::new(self.clone(), self.shared.clone(), path, shown_as)
    }

    pub fn session(self: Arc<Self>) -> Result<Arc<EngineSession>, EngineError> {
        let id = self.shared.sessions.fetch_add(1, Ordering::Relaxed) + 1;
        let (wake, pending) = mpsc::sync_channel(1);
        let lane = Lane::new(id, BEST_MATCH, wake);
        let pool = Pool::live()?;
        let thread = spawn("wherever-search", {
            let (shared, lane) = (self.shared.clone(), Arc::downgrade(&lane));
            move || {
                while pending.recv().is_ok() && !shared.stopped() {
                    let Some(job) = lane.upgrade().map(|lane| lane.take_job()) else {
                        break;
                    };
                    if let Err(panic) =
                        panic::catch_unwind(AssertUnwindSafe(|| answer(&shared, &job, &pool)))
                    {
                        shared.fault(format!("a search failed: {}", said(&*panic)));
                        let _ = shared.listener.search_failed(job.generation);
                    }
                }
                if let Some(lane) = lane.upgrade() {
                    lane.halt();
                }
            }
        })?;
        self.keep(thread);
        Ok(Arc::new(EngineSession::new(self, lane)))
    }

    pub fn record_open(&self, path: String) -> Result<(), EngineError> {
        if !Path::new(&path).is_absolute() {
            return Err(EngineError::Io {
                message: format!("{path:?} is not an absolute path"),
            });
        }
        let jobs = self.jobs.as_ref().ok_or(EngineError::Stopped)?;
        self.shared.opens.record(path.as_bytes(), now_secs());
        jobs.send(Job {
            generation: WAKE,
            lane: Weak::new(),
        })
        .map_err(|_| EngineError::Stopped)
    }

    pub fn clear_opens(&self) -> Result<(), EngineError> {
        let cleared = self.shared.opens.clear();
        let _ = self.shared.listener.results_changed(false);
        cleared
    }

    pub fn flush_opens(&self) -> Result<(), EngineError> {
        let opens = self.shared.opens.save(now_secs());
        for unit in self.shared.units().iter() {
            apply::flush(&self.shared, unit);
        }
        opens
    }

    pub fn is_settling(&self) -> Result<bool, EngineError> {
        Ok(self.shared.settling())
    }

    pub fn set_typos(&self, on: bool) -> Result<(), EngineError> {
        if self.shared.settings.typos.swap(on, Ordering::Relaxed) != on {
            let _ = self.shared.listener.results_changed(false);
        }
        Ok(())
    }

    pub fn set_live_updates(&self, on: bool) -> Result<(), EngineError> {
        let paused = &self.shared.settings.paused;
        if paused.swap(!on, Ordering::Relaxed) == !on {
            return Ok(());
        }
        let shared = self.shared.clone();
        let switching = spawn("wherever-live-switch", move || {
            let units = shared.units().to_vec();
            for unit in units {
                unit.watcher().follow_switch();
            }
        });
        self.keep(switching.inspect_err(|_| paused.store(on, Ordering::Relaxed))?);
        Ok(())
    }

    pub fn set_volumes(&self, volumes: Vec<EngineVolume>) -> Result<(), EngineError> {
        let shared = &self.shared;
        if let Some(v) = volumes.iter().find(|v| !unit::uuid_shaped(&v.id)) {
            return Err(EngineError::Io {
                message: format!("{:?} is not a volume UUID", v.id),
            });
        }
        if let Some(v) = volumes.iter().find(|v| !Path::new(&v.root).is_absolute()) {
            return Err(EngineError::Io {
                message: format!("{:?} is not an absolute path", v.root),
            });
        }
        let mut asked = self.mounting.lock().unwrap_or_else(PoisonError::into_inner);
        let mut wanted: Vec<(String, PathBuf)> = Vec::new();
        for v in volumes {
            if wanted.iter().any(|(id, _)| *id == v.id) {
                shared.fault(format!(
                    "{} is mounted twice; only the first is indexed, not {}",
                    v.id, v.root
                ));
                continue;
            }
            wanted.push((v.id, PathBuf::from(v.root)));
        }
        *asked = wanted;
        self.mount(&asked)
    }

    pub fn set_excluded(&self, excluded: Vec<String>) -> Result<(), EngineError> {
        if let Some(p) = excluded.iter().find(|p| row(p).is_none()) {
            return Err(EngineError::Io {
                message: refused(p),
            });
        }
        let shared = &self.shared;
        let asked = self.mounting.lock().unwrap_or_else(PoisonError::into_inner);
        let kept: Vec<(String, PathBuf)> = {
            let units = shared.units();
            let e = shared.settings.exclusions();
            (asked.iter())
                .filter(|(id, root)| {
                    units.iter().any(|u| u.id.as_ref() == Some(id))
                        || e.excluded.iter().any(|p| root.starts_with(p))
                })
                .cloned()
                .collect()
        };
        let exclusions = shared.settings.exclude(&excluded);
        self.restart(Some(exclusions))?;
        if let Err(e) = self.mount(&kept) {
            shared.fault(format!("a disk did not come back: {e}"));
        }
        Ok(())
    }

    pub fn serve_command_line(&self, on: bool) -> Result<(), EngineError> {
        let mut server = (self.command_line.lock()).unwrap_or_else(PoisonError::into_inner);
        if !on {
            drop(server.take());
        } else if server.is_none() {
            match cli::Server::start(&self.shared) {
                Ok(started) => *server = Some(started),
                Err(e) => {
                    let message = format!("the command-line tool cannot listen: {e}");
                    self.shared.fault(message.clone());
                    return Err(EngineError::Io { message });
                }
            }
        }
        Ok(())
    }
}

impl Engine {
    fn with_settings(
        settings: Settings,
        indexed_volumes: Vec<String>,
        listener: Arc<dyn EngineListener>,
    ) -> Result<Arc<Self>, EngineError> {
        let raised = crawl::raise_fd_limit();
        let fd = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY)
            .open(&settings.root)
            .map_err(|e| io_error(&settings.root, e))?;
        let (events, batches) = mpsc::channel();
        let boot = Arc::new(Unit::new(
            settings.root.clone(),
            None,
            settings.data.join(index::FILE),
            settings.boot_inputs(),
            Pool::new(CRAWL_THREADS)?,
            events,
            settings.paused.clone(),
        ));
        let shared = Arc::new(Shared::new(listener, settings));
        shared
            .units
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .push(boot.clone());
        let (jobs, rx) = mpsc::channel();
        let (start, started) = mpsc::channel::<()>();
        let follower = spawn("wherever-live", {
            let (shared, boot) = (shared.clone(), boot.clone());
            move || {
                if started.recv().is_ok() {
                    boot.guard(&shared, || apply::run(&shared, &boot, &batches));
                }
            }
        })?;
        *boot.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(follower);
        let worker = spawn("wherever-engine", {
            let shared = shared.clone();
            move || {
                if let Err(e) = raised {
                    shared.fault(format!("raising the open file limit: {e}"));
                }
                unit::clean(&shared.settings.data, &indexed_volumes);
                if let Err(e) = shared.opens.load() {
                    shared.fault(format!("loading the open history: {e}"));
                }
                let unit = Arc::downgrade(&boot);
                let ran = panic::catch_unwind(AssertUnwindSafe(|| {
                    run(&shared, boot, fd.into(), &rx, start)
                }));
                if let Err(panic) = ran {
                    match unit.upgrade() {
                        Some(boot) => boot.fell(&shared, &*panic),
                        None => {
                            shared.fault(format!("the engine's worker failed: {}", said(&*panic)))
                        }
                    }
                }
                while let Err(panic) = panic::catch_unwind(AssertUnwindSafe(|| serve(&shared, &rx)))
                {
                    shared.fault(format!("the engine's worker failed: {}", said(&*panic)));
                }
                save_opens(&shared);
            }
        })?;
        Ok(Arc::new(Engine {
            shared,
            jobs: Some(jobs),
            worker: Some(worker),
            threads: Mutex::new(Vec::new()),
            mounting: Mutex::new(Vec::new()),
            rebuild: Mutex::new(None),
            command_line: Mutex::new(None),
        }))
    }

    fn keep(&self, thread: JoinHandle<()>) {
        let mut threads = self.threads.lock().unwrap_or_else(PoisonError::into_inner);
        threads.retain(|thread| !thread.is_finished());
        threads.push(thread);
    }

    pub(crate) fn ask(
        &self,
        lane: &Arc<Lane>,
        ask: Ask,
        sort: EngineSort,
    ) -> Result<u64, EngineError> {
        let jobs = self.jobs.as_ref().ok_or(EngineError::Stopped)?;
        lane.ask(&self.shared.generation, jobs, ask, sort)
    }

    fn mount(&self, asked: &[(String, PathBuf)]) -> Result<(), EngineError> {
        let shared = &self.shared;
        let wanted: Vec<(String, PathBuf)> = {
            let e = shared.settings.exclusions();
            (asked.iter())
                .filter(|(_, root)| !e.excluded.iter().any(|p| root.starts_with(p)))
                .cloned()
                .collect()
        };
        let gone: Vec<Arc<Unit>> = {
            let mut units = shared.units.write().unwrap_or_else(PoisonError::into_inner);
            let (kept, gone) = units.drain(..).partition(|u| {
                u.id.as_ref()
                    .is_none_or(|id| wanted.iter().any(|(i, r)| i == id && *r == u.root))
            });
            *units = kept;
            gone
        };
        let halted = !gone.is_empty() && self.halt().map(JoinHandle::join).is_some();
        for u in &gone {
            u.stop.store(true, Ordering::Relaxed);
            u.watcher().close();
        }
        for u in &gone {
            let thread = u
                .thread
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            if let Some(thread) = thread {
                let _ = thread.join();
            }
        }
        for u in &gone {
            drop(
                shared
                    .reading(&u.root)
                    .write()
                    .unwrap_or_else(PoisonError::into_inner),
            );
        }
        if !gone.is_empty() {
            drop(gone);
            let _ = shared.listener.results_changed(false);
            shared.report();
        }
        let mut error = None;
        for (id, root) in wanted {
            if !shared.units().iter().any(|u| u.id.as_ref() == Some(&id))
                && let Err(e) = self.add(id, root)
            {
                error.get_or_insert(e);
            }
        }
        let pending = halted
            || (self
                .rebuild
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_none()
                && shared
                    .units()
                    .iter()
                    .any(|u| unit::rebuild_inputs(&shared.settings, u).is_some()));
        if pending && let Err(e) = self.restart(None) {
            error.get_or_insert(e);
        }
        error.map_or(Ok(()), Err)
    }

    fn halt(&self) -> Option<JoinHandle<()>> {
        let (stop, thread) = self
            .rebuild
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()?;
        stop.store(true, Ordering::Relaxed);
        Some(thread)
    }

    fn restart(&self, exclusions: Option<Exclusions>) -> Result<(), EngineError> {
        let (start, started) = mpsc::channel::<Option<JoinHandle<()>>>();
        #[cfg(test)]
        if self.shared.fail_rebuild.swap(false, Ordering::Relaxed) {
            return Err(io::Error::other("injected rebuild start failure").into());
        }
        let stop = Arc::new(AtomicBool::new(false));
        let thread = spawn("wherever-rebuild", {
            let (shared, stop) = (self.shared.clone(), stop.clone());
            move || {
                if let Ok(before) = started.recv() {
                    if let Some(before) = before {
                        let _ = before.join();
                    }
                    unit::rebuild(&shared, &stop);
                }
            }
        })?;
        let before = self.halt();
        if let Some(exclusions) = exclusions {
            *self
                .shared
                .settings
                .exclusions
                .write()
                .unwrap_or_else(PoisonError::into_inner) = exclusions;
            unit::renew(&self.shared);
        }
        *self.rebuild.lock().unwrap_or_else(PoisonError::into_inner) = Some((stop, thread));
        start.send(before).map_err(|_| EngineError::Stopped)
    }

    fn add(&self, id: String, root: PathBuf) -> Result<(), EngineError> {
        let shared = &self.shared;
        #[cfg(test)]
        if shared.fail_add.swap(false, Ordering::Relaxed) {
            return Err(io::Error::other("injected volume start failure").into());
        }
        let (events, batches) = mpsc::channel();
        let file = shared.settings.data.join(format!("volume-{id}.index"));
        let inputs = unit::inputs(&shared.settings, &id, &root);
        let pool = Pool::new(CRAWL_THREADS)?;
        #[cfg(test)]
        let facts = {
            let mut facts = shared.facts.lock().unwrap();
            facts.take_if(|(on, _)| *on == id).map(|(_, d)| d)
        };
        let paused = shared.settings.paused.clone();
        let unit = Arc::new(Unit::new(
            root,
            Some(id),
            file,
            inputs,
            pool,
            events,
            paused,
        ));
        #[cfg(test)]
        {
            *unit.facts.lock().unwrap() = facts;
        }
        shared
            .units
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .push(unit.clone());
        let started = spawn("wherever-volume", {
            let (shared, unit) = (shared.clone(), unit.clone());
            move || unit.guard(&shared, || unit::mount(&shared, &unit, &batches))
        });
        match started {
            Ok(thread) => {
                *unit.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread)
            }
            Err(e) => {
                shared
                    .units
                    .write()
                    .unwrap_or_else(PoisonError::into_inner)
                    .retain(|u| !Arc::ptr_eq(u, &unit));
                return Err(e.into());
            }
        }
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        drop(
            (self.command_line.get_mut())
                .unwrap_or_else(PoisonError::into_inner)
                .take(),
        );
        self.shared.stop.store(true, Ordering::Relaxed);
        let rebuild = self.halt();
        let units = self.shared.units().to_vec();
        for u in &units {
            u.stop.store(true, Ordering::Relaxed);
            u.watcher().close();
        }
        drop(self.jobs.take());
        if crawl::ENGINE_THREAD.get() {
            return;
        }
        for thread in [self.worker.take(), rebuild].into_iter().flatten() {
            let _ = thread.join();
        }
        for thread in self
            .threads
            .get_mut()
            .unwrap_or_else(PoisonError::into_inner)
            .drain(..)
        {
            let _ = thread.join();
        }
        let readers = std::mem::take(
            &mut *self
                .shared
                .readers
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
        );
        for thread in readers {
            let _ = thread.join();
        }
        for u in &units {
            let thread = u
                .thread
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            if let Some(thread) = thread {
                let _ = thread.join();
            }
        }
    }
}

pub(crate) fn spawn(name: &str, f: impl FnOnce() + Send + 'static) -> io::Result<JoinHandle<()>> {
    thread::Builder::new().name(name.to_owned()).spawn(move || {
        crawl::no_materialize();
        crawl::ENGINE_THREAD.set(true);
        f()
    })
}

fn settle(config: &EngineConfig) -> Result<Settings, EngineError> {
    let root = fs::canonicalize(&config.root).map_err(|e| io_error(Path::new(&config.root), e))?;
    let home = real(Path::new(&config.home));
    let mut settings = Settings {
        root,
        data: PathBuf::from(&config.data_folder),
        socket_folder: config.socket_folder.as_ref().map(PathBuf::from),
        home,
        exclusions: RwLock::default(),
        typos: AtomicBool::new(false),
        paused: Arc::new(AtomicBool::new(config.live_updates_paused)),
    };
    let exclusions = settings.exclude(&config.excluded);
    *settings
        .exclusions
        .get_mut()
        .unwrap_or_else(PoisonError::into_inner) = exclusions;
    Ok(settings)
}

pub(crate) fn real(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

pub(crate) fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn run(
    shared: &Arc<Shared>,
    boot: Arc<Unit>,
    fd: OwnedFd,
    jobs: &Receiver<Job>,
    start: Sender<()>,
) {
    let initial = thread::scope(|threads| {
        let (finished, result) = mpsc::channel();
        let boot = &boot;
        let indexer = threads.spawn(move || {
            crawl::no_materialize();
            crawl::ENGINE_THREAD.set(true);
            let _ = finished.send(index(shared, boot, fd));
        });
        let mut searchable = false;
        let initial = loop {
            match result.recv_timeout(Duration::from_millis(10)) {
                Ok(index) => break index,
                Err(RecvTimeoutError::Disconnected) => break None,
                Err(RecvTimeoutError::Timeout) => {}
            }
            if !searchable {
                searchable = boot.partial().is_some_and(|p| !p.batches.is_empty());
            }
            if searchable {
                while let Some(job) = next(shared, jobs, false) {
                    dispatch(shared, &job);
                }
            }
        };
        if let Err(panic) = indexer.join() {
            shared.fault(format!("the first index failed: {}", said(&*panic)));
        }
        initial
    });
    #[cfg(test)]
    if shared.fail_run.swap(false, Ordering::Relaxed) {
        panic!("injected worker panic");
    }
    if let Some((index, loaded)) = initial.filter(|_| !boot.stopped()) {
        let event_id = index.event_id();
        let refreshed = boot.partial().is_some_and(|p| !p.batches.is_empty());
        boot.install(shared, index, EnginePhase::Loading);
        let watching = if loaded {
            let started = boot.watch_saved_boot();
            if let Err(e) = &started
                && !boot.stopped()
            {
                boot.live_off(shared, e);
            }
            started.is_ok()
        } else {
            event_id != 0
        };
        boot.set_phase(EnginePhase::Ready);
        shared.report();
        if refreshed {
            boot.refreshed(shared, || {
                while let Some(job) = next(shared, jobs, false) {
                    dispatch(shared, &job);
                }
            });
        }
        while let Some(job) = next(shared, jobs, false) {
            dispatch(shared, &job);
        }
        if watching {
            let _ = start.send(());
        }
    } else if !boot.stopped() {
        boot.watcher().close();
        boot.set_phase(EnginePhase::Failed);
        shared.report();
    }
}

fn serve(shared: &Shared, jobs: &Receiver<Job>) {
    while let Some(job) = next(shared, jobs, true) {
        dispatch(shared, &job);
    }
}

fn dispatch(shared: &Shared, job: &Job) {
    if Lane::wake(&job.lane).is_err() {
        shared.fault("the session's search worker stopped".to_owned());
    }
}

pub(crate) fn said(panic: &(dyn Any + Send)) -> &str {
    panic
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("no message")
}

fn save_opens(shared: &Shared) {
    if let Err(e) = shared.opens.save(now_secs()) {
        shared.fault(format!("saving the open history: {e}"));
    }
}

fn next(shared: &Shared, jobs: &Receiver<Job>, wait: bool) -> Option<Job> {
    loop {
        let due = shared.opens.due();
        let got = match (wait, due) {
            (false, _) => jobs.try_recv().ok()?,
            (true, None) => jobs.recv().ok()?,
            (true, Some(at)) => {
                match jobs.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(job) => job,
                    Err(RecvTimeoutError::Timeout) => {
                        save_opens(shared);
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => return None,
                }
            }
        };
        if got.generation != WAKE {
            return Some(got);
        }
    }
}

fn answer(shared: &Arc<Shared>, job: &Job, pool: &Pool) {
    let generation = job.generation;
    let Some(lane) = job.lane.upgrade() else {
        return;
    };
    let Some(Work {
        query,
        asked,
        sort,
        held,
        narrow,
        press,
        live,
    }) = lane.work(generation)
    else {
        return;
    };
    let cancelled = || superseded(shared, &lane, generation);
    if narrow {
        if let Some(press) = press {
            let pressed = press.0;
            if let Err(panic) =
                panic::catch_unwind(AssertUnwindSafe(|| start_press(shared, &lane, press, sort)))
            {
                shared.fault(format!("a search failed: {}", said(&*panic)));
                let _ = shared.listener.search_failed(pressed);
                if generation != pressed {
                    let _ = shared.listener.search_failed(generation);
                }
                return;
            }
        }
        show(
            shared,
            &lane,
            lane.content().as_deref(),
            generation,
            &query,
            sort,
            &cancelled,
        );
        return;
    }
    let results = match held {
        Some(h) if h.searched == asked => {
            if h.patched && sort.column == EngineColumn::Relevance {
                drop(h);
                scan(shared, generation, &query, sort, &cancelled).map(|set| Results {
                    searched: asked,
                    ..set
                })
            } else {
                h.sorted(generation, sort, &shared.opens, &cancelled)
            }
        }
        held if live => {
            let shared = shared.clone();
            pool.spawn(move || answer_refresh(&shared, &lane, generation, &query, sort, held));
            return;
        }
        held => {
            drop(held);
            scan(shared, generation, &query, sort, &cancelled)
        }
    };
    deliver(shared, &lane, generation, results);
}

fn superseded(shared: &Shared, lane: &Arc<Lane>, generation: u64) -> bool {
    shared.stopped() || lane.latest() != generation || Arc::strong_count(lane) == 1
}

fn deliver(shared: &Shared, lane: &Lane, generation: u64, results: Option<Results>) {
    if let Some(results) = results {
        let count = results.count();
        if lane.publish(results) {
            let _ = shared.listener.results_ready(generation, count);
        }
    }
}

fn answer_refresh(
    shared: &Arc<Shared>,
    lane: &Arc<Lane>,
    generation: u64,
    query: &str,
    sort: EngineSort,
    held: Option<Arc<Results>>,
) {
    let cancelled = || superseded(shared, lane, generation);
    let answered = panic::catch_unwind(AssertUnwindSafe(|| {
        if cancelled() {
            return;
        }
        let patch = match held {
            Some(h) => delta::patch(shared, &h, generation, query, sort, &cancelled),
            None => Patch::Full(Why::Unseen),
        };
        let results = match patch {
            Patch::Done(set) => Some(set),
            Patch::Cancelled => None,
            Patch::Full(_) => scan(shared, generation, query, sort, &cancelled),
        };
        deliver(shared, lane, generation, results);
    }));
    if let Err(panic) = answered {
        shared.fault(format!("a search failed: {}", said(&*panic)));
        let _ = shared.listener.search_failed(generation);
    }
}

fn parse(shared: &Shared, text: &str) -> Query {
    let q = Query::parse(text, &shared.settings.home.to_string_lossy());
    if q.unnormalized {
        shared.fault(
            "CoreFoundation did not load, so an accented word is searched in the form typed only"
                .to_owned(),
        );
    }
    q
}

fn scan(
    shared: &Shared,
    generation: u64,
    text: &str,
    sort: EngineSort,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Results> {
    #[cfg(test)]
    {
        shared.scans.fetch_add(1, Ordering::Relaxed);
        let on = thread::current().name().unwrap_or_default().to_owned();
        (shared.scanned_on.lock().unwrap()).push((on, rayon::current_num_threads()));
        let hold = shared.scan_hold.lock().unwrap().take();
        if let Some((reached, release)) = hold {
            let _ = reached.send(generation);
            let _ = release.recv_timeout(std::time::Duration::from_secs(10));
        }
    }
    #[cfg(test)]
    if shared.fail_scan.swap(false, Ordering::Relaxed) {
        panic!("injected search panic");
    }
    let mut q = parse(shared, text);
    let units = shared.units().to_vec();
    let scanned = query::search(&mut q, &shared.settings, &units, cancelled)?;
    Results::new(generation, q, scanned, sort, &shared.opens, cancelled)
}

const UNREAD: u8 = 0;
const HOLDS: u8 = 1;
const LACKS: u8 = 2;
const NOT_DOWNLOADED: u8 = 3;
const UNREADABLE: u8 = 4;
const REFRESH: Duration = Duration::from_millis(100);
const ROUND_WAIT: Duration = Duration::from_millis(10);
const STALL: Duration = Duration::from_secs(1);
const IDLE: usize = usize::MAX;

pub(crate) struct Content {
    pub(crate) press: u64,
    query: String,
    sort: EngineSort,
    walked: bool,
    everything: bool,
    owners: Vec<(PathBuf, PathBuf)>,
    files: RwLock<Arc<Files>>,
    walking: AtomicBool,
    pub(crate) stop: AtomicBool,
    ended: AtomicBool,
    told: AtomicBool,
    shown: AtomicU64,
    showing: Mutex<usize>,
}

pub(crate) struct Files {
    set: Results,
    held: Vec<Held>,
    verdicts: Vec<AtomicU8>,
    counts: [AtomicU64; 5],
    next: AtomicUsize,
    started: Instant,
    reading: [(AtomicU64, AtomicUsize); READERS],
}

impl Files {
    fn new(
        shared: &Shared,
        press: u64,
        q: Query,
        scanned: Vec<(Found, Vec<Hit>)>,
        sort: EngineSort,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Files> {
        let mut set = Results::new(press, q, scanned, sort, &shared.opens, cancelled)?;
        let found = set.found.clone();
        set.ranked.retain(|r| {
            found[r.unit as usize]
                .attrs(r.k as usize)
                .is_some_and(|a| a.kind == EngineKind::File)
        });
        Some(Files {
            verdicts: (0..set.ranked.len())
                .map(|_| AtomicU8::new(UNREAD))
                .collect(),
            held: found.iter().map(|f| held(shared, f)).collect(),
            set,
            counts: Default::default(),
            next: AtomicUsize::new(0),
            started: Instant::now(),
            reading: std::array::from_fn(|_| (AtomicU64::new(0), AtomicUsize::new(IDLE))),
        })
    }

    fn since(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn stalled(&self) -> Vec<usize> {
        let now = self.since();
        let stall = STALL.as_millis() as u64;
        (self.reading.iter())
            .filter_map(|(at, file)| {
                let file = file.load(Ordering::Acquire);
                (file != IDLE && now >= at.load(Ordering::Relaxed).saturating_add(stall))
                    .then_some(file)
            })
            .collect()
    }

    fn count(&self, verdict: u8) -> u64 {
        self.counts[verdict as usize].load(Ordering::SeqCst)
    }

    fn finished(&self) -> u64 {
        self.count(HOLDS) + self.count(LACKS) + self.count(NOT_DOWNLOADED) + self.count(UNREADABLE)
    }
}

impl Content {
    fn files(&self) -> Arc<Files> {
        self.files
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn replace(&self, new: Files) {
        let mut files = self.files.write().unwrap_or_else(PoisonError::into_inner);
        carry(&files, &new);
        *files = Arc::new(new);
    }
}

fn carry(old: &Files, new: &Files) {
    let mut at = vec![Vec::new(); new.set.found.len()];
    for (i, r) in new.set.ranked.iter().enumerate() {
        let at: &mut Vec<usize> = &mut at[r.unit as usize];
        let k = r.k as usize;
        if at.len() <= k {
            at.resize(k + 1, usize::MAX);
        }
        at[k] = i;
    }
    let same: Vec<bool> = (old.set.found.iter().zip(new.set.found.iter()))
        .map(|(a, b)| {
            Arc::ptr_eq(&a.index, &b.index) && a.hits == b.hits && a.added.len() == b.added.len()
        })
        .collect();
    let mut carried = [0; 5];
    for (v, r) in old.verdicts.iter().zip(&old.set.ranked) {
        let known = v.load(Ordering::Acquire);
        if known == UNREAD {
            continue;
        }
        let u = r.unit as usize;
        let k = if same.get(u) == Some(&true) {
            Some(r.k as usize)
        } else {
            let (Some(h), Some(found), Some(held)) = (
                old.set.found[u].row(r.k as usize),
                new.set.found.get(u),
                new.held.get(u),
            ) else {
                continue;
            };
            (held.live.base_dir(h.folder.as_bytes()))
                .and_then(|k| found.index.child(k, h.name.as_bytes()))
                .and_then(|e| found.hits.binary_search(&e).ok())
        };
        let to = (k.and_then(|k| at.get(u)?.get(k))).and_then(|&i| new.verdicts.get(i));
        if let Some(to) = to {
            to.store(known, Ordering::Release);
            carried[known as usize] += 1;
        }
    }
    for (count, carried) in new.counts.iter().zip(carried) {
        count.store(carried, Ordering::SeqCst);
    }
}

fn start_press(shared: &Arc<Shared>, lane: &Arc<Lane>, press: Press, sort: EngineSort) {
    let (press, text, terms) = press;
    let cancelled = || shared.stopped() || lane.pressed() != press || Arc::strong_count(lane) == 1;
    #[cfg(test)]
    {
        let hold = shared.scan_hold.lock().unwrap().take();
        if let Some((reached, release)) = hold {
            let _ = reached.send(press);
            let _ = release.recv_timeout(Duration::from_secs(10));
        }
        if shared.fail_scan.swap(false, Ordering::Relaxed) {
            panic!("injected search panic");
        }
    }
    let mut q = parse(shared, &text);
    q.only_files();
    let units = shared.units().to_vec();
    let skip = shared.settings.exclusions().joined(&units);
    let mut plan = query::walk(&q, &skip, &units, &mut crawl::is_mount);
    let indexed = plan.as_ref().map_or(&units[..], |p| &p.indexed[..]);
    let scanned = if plan.is_some() && indexed.is_empty() {
        Vec::new()
    } else {
        match query::search(&mut q, &shared.settings, indexed, &cancelled) {
            Some(scanned) => scanned,
            None => return,
        }
    };
    let fixed = plan.as_ref().map(|_| scanned.clone());
    let Some(files) = Files::new(shared, press, q.clone(), scanned, sort, &cancelled) else {
        return;
    };
    let content = Arc::new(Content {
        press,
        files: RwLock::new(Arc::new(files)),
        walked: plan.is_some(),
        everything: plan.as_ref().is_some_and(|p| p.everything),
        owners: plan
            .as_mut()
            .map(|p| std::mem::take(&mut p.owners))
            .unwrap_or_default(),
        walking: AtomicBool::new(plan.is_some()),
        query: text,
        sort,
        stop: AtomicBool::new(false),
        ended: AtomicBool::new(false),
        told: AtomicBool::new(false),
        shown: AtomicU64::new(0),
        showing: Mutex::new(0),
    });
    if !lane.hold(&content) {
        return;
    }
    let started = spawn("wherever-content", {
        let (shared, lane, content) = (shared.clone(), Arc::downgrade(lane), content.clone());
        move || {
            let walked = plan.zip(fixed).map(|(p, fixed)| (p.folders, fixed, q));
            read(&shared, &lane, &content, &terms, walked)
        }
    });
    match started {
        Ok(thread) => {
            let mut readers = shared
                .readers
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            readers.retain(|t| !t.is_finished());
            readers.push(thread);
        }
        Err(e) => {
            shared.fault(format!("starting the text readers: {e}"));
            content.ended.store(true, Ordering::SeqCst);
        }
    }
}

type Folders = Vec<(PathBuf, Vec<PathBuf>)>;

fn walk(
    shared: &Shared,
    lane: &Weak<Lane>,
    content: &Content,
    folders: Folders,
    fixed: &Scanned,
    q: &Query,
) {
    let mut done: Vec<Live> = Vec::new();
    for (folder, skip) in folders {
        let pool = match Pool::new(CRAWL_THREADS) {
            Ok(pool) => pool,
            Err(e) => return shared.fault(format!("walking {}: {e}", folder.display())),
        };
        let listed = Mutex::new((Vec::new(), Instant::now(), Duration::ZERO, 0, None));
        let crawl = {
            let publish = |batch: &[crawl::Listing]| {
                let mut listed = listed.lock().unwrap_or_else(PoisonError::into_inner);
                listed.0.extend_from_slice(batch);
                if listed.1.elapsed() < listed.2 * 4 {
                    return;
                }
                let began = Instant::now();
                let crawl = Crawl {
                    listings: listed.0.clone(),
                    failed: Vec::new(),
                };
                listed.4 = round(shared, lane, content, (fixed, &done), crawl, &folder, q);
                listed.1 = Instant::now();
                listed.2 = began.elapsed();
                listed.3 = listed.0.len();
            };
            #[cfg(test)]
            {
                crawl::OPENED.set(shared.opened.lock().unwrap().take());
                shared.crawls.lock().unwrap().push(folder.clone());
            }
            crawl::scan_root(
                &pool,
                &folder,
                &skip,
                &content.stop,
                &|_| {},
                Some(&publish),
            )
            .unwrap_or_default()
        };
        let (.., took, last) = listed.into_inner().unwrap_or_else(PoisonError::into_inner);
        if content.stop.load(Ordering::Relaxed) {
            return;
        }
        let whole = took > 0 && took == crawl.listings.len() && crawl.failed.is_empty();
        let live = if whole {
            last
        } else {
            round(shared, lane, content, (fixed, &done), crawl, &folder, q)
        };
        done.extend(live);
    }
}

fn round(
    shared: &Shared,
    lane: &Weak<Lane>,
    content: &Content,
    (fixed, done): (&Scanned, &[Live]),
    crawl: Crawl,
    folder: &Path,
    q: &Query,
) -> Option<Live> {
    let cancelled = || content.stop.load(Ordering::Relaxed) || shared.stopped();
    let index =
        match Index::build_until(crawl, folder.to_path_buf(), &[], 0, now_secs(), &cancelled) {
            Ok(index) => index,
            Err(EngineError::Stopped) => return None,
            Err(e) => {
                shared.fault(e.to_string());
                return None;
            }
        };
    let live = Live::new(Arc::new(index));
    let mut q = q.clone();
    let lives: Vec<&Live> = done.iter().chain([&live]).collect();
    let files =
        query::walked_lives(&mut q, &shared.settings, &lives, &cancelled).and_then(|walked| {
            let mut scanned = fixed.clone();
            scanned.extend(walked);
            Files::new(shared, content.press, q, scanned, content.sort, &cancelled)
        });
    if let Some(files) = files {
        content.replace(files);
        refresh(shared, lane, content);
    }
    Some(live)
}

fn held(shared: &Shared, f: &Found) -> Held {
    let mut live = Live::new(f.index.clone());
    live.updated = f.updated.clone();
    let mut folder = None;
    for h in &f.added {
        let attrs = Attrs {
            mount: false,
            hidden: false,
            ..h.attrs
        };
        live.over.insert(f.added_path(h, &mut folder), attrs);
    }
    let root = f.index.root().to_path_buf();
    Held {
        boot: root == shared.settings.root,
        root,
        live,
        partial: f.partial.clone(),
    }
}

fn read(
    shared: &Shared,
    lane: &Weak<Lane>,
    content: &Content,
    terms: &Terms,
    walked: Option<(Folders, Scanned, Query)>,
) {
    match Pool::text(READERS) {
        Ok(pool) => {
            let (running, ended) = mpsc::channel::<()>();
            let read = panic::catch_unwind(AssertUnwindSafe(|| {
                thread::scope(|s| {
                    if let Some((folders, fixed, q)) = walked {
                        s.spawn(move || {
                            crawl::no_materialize();
                            crawl::ENGINE_THREAD.set(true);
                            let walked = panic::catch_unwind(AssertUnwindSafe(|| {
                                walk(shared, lane, content, folders, &fixed, &q)
                            }));
                            if let Err(panic) = walked {
                                shared.fault(format!("walking a folder failed: {}", said(&*panic)));
                            }
                            content.walking.store(false, Ordering::SeqCst);
                        });
                    }
                    s.spawn(|| {
                        let _running = running;
                        let readers = panic::catch_unwind(AssertUnwindSafe(|| {
                            pool.install(|| {
                                rayon::broadcast(|b| take(shared, content, terms, b.index()))
                            })
                        }));
                        if let Err(panic) = readers {
                            shared.fault(format!("reading the files failed: {}", said(&*panic)));
                        }
                    });
                    while ended.recv_timeout(REFRESH) == Err(RecvTimeoutError::Timeout) {
                        let files = content.files();
                        let seen = files.finished() | (files.stalled().len() as u64) << 56;
                        if content.shown.swap(seen, Ordering::Relaxed) != seen {
                            refresh(shared, lane, content);
                        }
                    }
                })
            }));
            if let Err(panic) = read {
                shared.fault(format!("reading the files failed: {}", said(&*panic)));
            }
        }
        Err(e) => shared.fault(format!("starting the text readers: {e}")),
    }
    content.ended.store(true, Ordering::SeqCst);
    if let Err(panic) = panic::catch_unwind(AssertUnwindSafe(|| refresh(shared, lane, content))) {
        shared.fault(format!("a search failed: {}", said(&*panic)));
        let _ = shared.listener.search_failed(content.press);
    }
}

fn take(shared: &Shared, content: &Content, terms: &Terms, slot: usize) {
    while !content.stop.load(Ordering::Relaxed) && !shared.stopped() {
        #[cfg(test)]
        if shared.fail_read.swap(false, Ordering::Relaxed) {
            panic!("injected read panic");
        }
        let walking = content.walking.load(Ordering::SeqCst);
        let files = content.files();
        let i = files.next.fetch_add(1, Ordering::Relaxed);
        let Some(v) = files.verdicts.get(i) else {
            if !walking {
                break;
            }
            thread::sleep(ROUND_WAIT);
            continue;
        };
        if v.load(Ordering::Acquire) != UNREAD {
            continue;
        }
        let reading = files.reading.get(slot);
        if let Some((at, file)) = reading {
            at.store(files.since(), Ordering::Relaxed);
            file.store(i, Ordering::Release);
        }
        let known = verdict(shared, content, &files, i, terms);
        v.store(known, Ordering::Release);
        if let Some((_, file)) = reading {
            file.store(IDLE, Ordering::Release);
        }
        if known != UNREAD {
            files.counts[known as usize].fetch_add(1, Ordering::SeqCst);
        }
    }
}

fn verdict(shared: &Shared, c: &Content, f: &Files, i: usize, terms: &Terms) -> u8 {
    let r = f.set.ranked[i];
    let Some(h) = f.set.found[r.unit as usize].row(r.k as usize) else {
        return LACKS;
    };
    let path = Path::new(&h.folder).join(&h.name);
    let units = shared.units();
    let excluded = !c.everything && shared.settings.exclusions().holds(&path, &units);
    drop(units);
    if excluded {
        return LACKS;
    }
    let held = &f.held[r.unit as usize].root;
    let owner = (c.owners.iter()).find_map(|(folder, unit)| (folder == held).then_some(unit));
    let root = owner.unwrap_or(held);
    let installed = || c.everything || shared.units().iter().any(|u| u.root == *root);
    let lock = shared.reading(root);
    let open = || {
        let open = lock.read().unwrap_or_else(PoisonError::into_inner);
        if !installed() {
            return None;
        }
        #[cfg(test)]
        {
            let reached = shared.read_reached.lock().unwrap().clone();
            if let Some(reached) = reached {
                let _ = reached.send(path.clone());
            }
            drop(shared.read_gate.read().unwrap());
            let hold = shared
                .read_hold
                .lock()
                .unwrap()
                .take_if(|(p, _)| *p == path);
            if let Some((_, release)) = hold {
                let _ = release.recv_timeout(Duration::from_secs(30));
            }
            shared.reads.lock().unwrap().push(path.clone());
        }
        Some(open)
    };
    let mut go = || !c.stop.load(Ordering::Relaxed) && !shared.stopped() && installed();
    match search::holds(&path, h.size, terms, &mut go, open) {
        Ok(Verdict::Holds) => HOLDS,
        Ok(Verdict::Lacks) => LACKS,
        Ok(Verdict::NotDownloaded) => NOT_DOWNLOADED,
        Ok(Verdict::Unreadable) => UNREADABLE,
        Err(Stopped) => UNREAD,
    }
}

fn refresh(shared: &Shared, lane: &Weak<Lane>, content: &Content) {
    let Some(lane) = lane.upgrade() else {
        return;
    };
    let generation = lane.latest();
    let Some((text, sort)) = lane.view(generation, content) else {
        return;
    };
    let cancelled = || shared.stopped() || lane.latest() != generation;
    show(
        shared,
        &lane,
        Some(content),
        generation,
        &text,
        sort,
        &cancelled,
    );
}

fn show(
    shared: &Shared,
    lane: &Lane,
    content: Option<&Content>,
    generation: u64,
    text: &str,
    sort: EngineSort,
    cancelled: &(dyn Fn() -> bool + Sync),
) {
    let Some(c) = content else {
        let q = parse(shared, text);
        if let Some(none) = Results::new(generation, q, Vec::new(), sort, &shared.opens, cancelled)
            && lane.publish(none)
        {
            let _ = shared.listener.results_ready(generation, 0);
        }
        return;
    };
    let mut frontier = c.showing.lock().unwrap_or_else(PoisonError::into_inner);
    let ended = c.ended.load(Ordering::SeqCst);
    let files = c.files();
    let counts = [HOLDS, LACKS, NOT_DOWNLOADED, UNREADABLE].map(|v| files.count(v));
    let holds = |i: usize| files.verdicts[i].load(Ordering::Acquire) == HOLDS;
    let results =
        if text == c.query && sort == c.sort {
            let stalled = files.stalled();
            while files.verdicts.get(*frontier).is_some_and(|v| {
                v.load(Ordering::Acquire) != UNREAD || stalled.contains(&*frontier)
            }) {
                *frontier += 1;
            }
            let end = if ended || c.walked {
                files.verdicts.len()
            } else {
                *frontier
            };
            let ranked = (0..end).filter(|&i| holds(i)).map(|i| files.set.ranked[i]);
            Some(files.set.with(generation, ranked.collect(), sort))
        } else {
            let mut members: Vec<Members> = files.held.iter().map(|_| Members::default()).collect();
            for (i, r) in files.set.ranked.iter().enumerate() {
                if !holds(i) {
                    continue;
                }
                let (f, m) = (
                    &files.set.found[r.unit as usize],
                    &mut members[r.unit as usize],
                );
                match f.hits.get(r.k as usize) {
                    Some(&e) => m.add(e),
                    None => {
                        let n = r.k as usize - f.hits.len();
                        if let Some(h) = f.added.get(n) {
                            m.over.insert(f.added_path(h, &mut None));
                        } else if let Some(path) = f.listed_path(n - f.added.len()) {
                            m.over.insert(path);
                        }
                    }
                }
            }
            let mut q = parse(shared, text);
            query::narrow(&mut q, &shared.settings, &files.held, &members, cancelled).and_then(
                |scanned| Results::new(generation, q, scanned, sort, &shared.opens, cancelled),
            )
        };
    let Some(results) = results else {
        return;
    };
    let count = results.count();
    if !lane.publish(results) {
        return;
    }
    let _ = shared.listener.results_ready(generation, count);
    if !c.told.load(Ordering::SeqCst) {
        let done = ended && !c.told.swap(true, Ordering::SeqCst);
        let total = files.verdicts.len() as u64;
        let [holding, lacking, not_downloaded, unreadable] = counts;
        let _ = (shared.listener).content_progress(
            c.press,
            holding + lacking,
            total,
            not_downloaded,
            unreadable,
            done,
        );
    }
}

fn index(shared: &Shared, boot: &Unit, fd: OwnedFd) -> Option<(Index, bool)> {
    let (index, loaded) = match unit::saved(shared, boot) {
        Some(index) => (index, true),
        None => {
            let event_id = unit::watch_from_now(shared, boot);
            boot.set_phase(EnginePhase::Crawling);
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
            shared.crawled(boot);
            let synced_at = now_secs();
            let partial = boot.begin(shared);
            let publish = |listings: &[crawl::Listing]| boot.publish(shared, listings);
            let crawl = crawl::scan(
                &boot.pool,
                fd,
                &boot.root,
                &boot.skip,
                &boot.stop,
                &unit::progress(shared, boot),
                partial.then_some(&publish),
            );
            boot.finish(shared);
            (
                unit::build(shared, boot, crawl, event_id, synced_at)?,
                false,
            )
        }
    };
    Some((index, loaded))
}

mod cli;
mod delta;

#[cfg(test)]
pub(crate) mod timing;

#[cfg(test)]
mod probe;

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::EngineKind;
    use crate::crawl::tests::{Locked, TempTree, policy};
    use crate::fsevents::Api;
    use std::os::unix::fs::MetadataExt;
    use std::time::{Duration, Instant};

    #[derive(Debug)]
    pub(crate) enum Event {
        State(EngineState),
        Ready(u64, u32),
        Failed(u64),
        Progress(u64, u64, u64, bool),
        Fault(String),
        Changed(libc::c_int),
    }

    pub(crate) type Hold = (EnginePhase, u64, Receiver<Option<Arc<Engine>>>);

    pub(crate) struct Recorder {
        events: Sender<Event>,
        pub(crate) hold: Mutex<Option<Hold>>,
        on_change: Mutex<Option<Receiver<Option<Arc<Engine>>>>>,
        pub(crate) faulted: Mutex<Vec<thread::ThreadId>>,
        pub(crate) changes: Mutex<Vec<Instant>>,
        pub(crate) opened_changes: Mutex<Vec<bool>>,
        pub(crate) skips: Mutex<Vec<(u64, u64, u64)>>,
    }

    impl Recorder {
        fn new(events: Sender<Event>, hold: Option<Hold>) -> Arc<Recorder> {
            Arc::new(Recorder {
                events,
                hold: Mutex::new(hold),
                on_change: Mutex::new(None),
                faulted: Mutex::new(Vec::new()),
                changes: Mutex::new(Vec::new()),
                opened_changes: Mutex::new(Vec::new()),
                skips: Mutex::new(Vec::new()),
            })
        }
    }

    impl EngineListener for Recorder {
        fn state_changed(&self, state: EngineState) -> Result<(), EngineError> {
            let _ = self.events.send(Event::State(state.clone()));
            let mut hold = self.hold.lock().unwrap();
            if hold
                .as_ref()
                .is_some_and(|(phase, at, _)| *phase == state.phase && state.indexed >= *at)
            {
                let (_, _, handoff) = hold.take().unwrap();
                drop(hold);
                drop(handoff.recv_timeout(Duration::from_secs(10)));
            }
            Ok(())
        }

        fn results_changed(&self, opened_only: bool) -> Result<(), EngineError> {
            self.changes.lock().unwrap().push(Instant::now());
            self.opened_changes.lock().unwrap().push(opened_only);
            let _ = self.events.send(Event::Changed(policy()));
            let handoff = self.on_change.lock().unwrap().take();
            if let Some(handoff) = handoff {
                drop(handoff.recv_timeout(Duration::from_secs(10)));
            }
            Ok(())
        }

        fn results_ready(&self, generation: u64, count: u32) -> Result<(), EngineError> {
            let _ = self.events.send(Event::Ready(generation, count));
            Ok(())
        }

        fn search_failed(&self, generation: u64) -> Result<(), EngineError> {
            let _ = self.events.send(Event::Failed(generation));
            Ok(())
        }

        fn content_progress(
            &self,
            generation: u64,
            read: u64,
            total: u64,
            not_downloaded: u64,
            unreadable: u64,
            done: bool,
        ) -> Result<(), EngineError> {
            (self.skips.lock().unwrap()).push((generation, not_downloaded, unreadable));
            let _ = self
                .events
                .send(Event::Progress(generation, read, total, done));
            Ok(())
        }

        fn fault(&self, message: String) -> Result<(), EngineError> {
            self.faulted.lock().unwrap().push(thread::current().id());
            let _ = self.events.send(Event::Fault(message));
            Ok(())
        }
    }

    pub(crate) fn config(tree: &TempTree) -> EngineConfig {
        EngineConfig {
            root: tree.root(),
            home: tree.0.join("home").to_str().unwrap().to_owned(),
            data_folder: tree.data().to_str().unwrap().to_owned(),
            socket_folder: Some(tree.data().to_str().unwrap().to_owned()),
            excluded: Vec::new(),
            indexed_volumes: Vec::new(),
            live_updates_paused: false,
        }
    }

    pub(crate) fn bench(config: EngineConfig) -> (Shared, Arc<Unit>, Receiver<Event>) {
        let settings = settle(&config).unwrap();
        let (events, rx) = mpsc::channel();
        let boot = Arc::new(Unit::new(
            settings.root.clone(),
            None,
            settings.data.join(index::FILE),
            settings.boot_inputs(),
            Pool::new(2).unwrap(),
            mpsc::channel().0,
            settings.paused.clone(),
        ));
        let shared = Shared::new(Recorder::new(events, None), settings);
        shared.units.write().unwrap().push(boot.clone());
        boot.watcher().count = 1;
        let crawl = crawl::scan_path(&boot.pool, &boot.root, &boot.skip, &boot.stop);
        let index = Index::build(crawl, boot.root.clone(), &boot.print, 1000, now_secs()).unwrap();
        boot.install(&shared, index, EnginePhase::Ready);
        (shared, boot, rx)
    }

    pub(crate) fn rebuilt(engine: &Engine) {
        let running = engine.rebuild.lock().unwrap().take();
        if let Some((_, thread)) = running {
            thread.join().unwrap();
        }
    }

    pub(crate) fn shared(engine: &Engine) -> &Shared {
        &engine.shared
    }

    pub(crate) fn start_with(
        config: EngineConfig,
        hold: Option<Hold>,
    ) -> (Arc<Engine>, Arc<Recorder>, Receiver<Event>) {
        let (events, rx) = mpsc::channel();
        let listener = Recorder::new(events, hold);
        let engine = Engine::new(config, listener.clone()).unwrap();
        (engine, listener, rx)
    }

    #[test]
    fn columns_access_only_relists_are_distinct_from_membership_and_other_metadata() {
        let tree = TempTree::new("columns-access-events");
        fs::write(tree.0.join("opened.txt"), b"one").unwrap();
        fs::write(tree.0.join("other.txt"), b"two").unwrap();
        fs::create_dir(tree.0.join("Folder")).unwrap();
        fs::write(tree.0.join("Folder/child.txt"), b"child").unwrap();
        let (mut shared, unit, _) = bench(config(&tree));
        let (sender, _receiver) = mpsc::channel();
        let recorder = Recorder::new(sender, None);
        shared.listener = recorder.clone();
        let mut state = apply::Apply::new();
        let mut event_id = 1000;
        let mut refresh = |relative: &str, flags| {
            recorder.opened_changes.lock().unwrap().clear();
            event_id += 1;
            apply::step(
                &shared,
                &unit,
                &mut state,
                vec![crate::fsevents::Event {
                    path: unit.root.join(relative).as_os_str().as_bytes().to_vec(),
                    flags,
                    id: event_id,
                    stream: 1,
                }],
                Instant::now(),
            );
            recorder.opened_changes.lock().unwrap().clone()
        };
        let accessed = |relative: &str, seconds: u64| {
            fs::File::open(tree.0.join(relative))
                .unwrap()
                .set_times(
                    fs::FileTimes::new()
                        .set_accessed(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)),
                )
                .unwrap();
        };
        let found = || unit.read(|live| live.find("", || false).unwrap()).unwrap();
        let opened = |name: &str| {
            found()
                .rows(0, 100)
                .into_iter()
                .find(|h| h.name == name)
                .unwrap()
                .opened
        };
        let original = opened("opened.txt");
        let held = found();
        for time in [1_600_000_001, 1_600_000_002, original as u64] {
            accessed("opened.txt", time);
            assert_eq!(refresh("", 0), [true], "base file access only");
            assert_eq!(opened("opened.txt"), time as i64);
        }
        assert_eq!(
            held.rows(0, 100)
                .into_iter()
                .find(|h| h.name == "opened.txt")
                .unwrap()
                .opened,
            original
        );
        for (event, time) in [("", 1_600_000_003), ("Folder", 1_600_000_004)] {
            accessed("Folder", time);
            assert_eq!(
                refresh(event, 0),
                [true],
                "base folder through parent and own event"
            );
            assert_eq!(opened("Folder"), time as i64);
            assert!(found().rows(0, 100).iter().any(|h| h.name == "child.txt"));
        }
        fs::write(tree.0.join("overlay.txt"), b"new").unwrap();
        fs::create_dir(tree.0.join("OverlayFolder")).unwrap();
        fs::write(tree.0.join("OverlayFolder/kept.txt"), b"new child").unwrap();
        assert_eq!(refresh("", 0), [false]);
        for (path, event, time) in [
            ("overlay.txt", "", 1_600_000_005),
            ("OverlayFolder", "OverlayFolder", 1_600_000_006),
        ] {
            accessed(path, time);
            assert_eq!(refresh(event, 0), [true], "overlay access only: {path}");
            assert_eq!(opened(path), time as i64);
        }
        accessed("Folder/child.txt", 1_600_000_007);
        assert_eq!(
            refresh("Folder", crate::fsevents::MUST_SCAN_SUBDIRS),
            [true],
            "recursive access only"
        );
        assert_eq!(opened("child.txt"), 1_600_000_007);
        assert!(refresh("Folder", crate::fsevents::MUST_SCAN_SUBDIRS).is_empty());
        accessed("opened.txt", 1_600_000_008);
        fs::write(tree.0.join("other.txt"), b"a different size").unwrap();
        assert_eq!(
            refresh("", 0),
            [false],
            "a mixed batch must refresh every window"
        );
        assert!(
            refresh("", 0).is_empty(),
            "an unchanged listing must notify nobody"
        );
        fs::remove_file(tree.0.join("overlay.txt")).unwrap();
        assert_eq!(
            refresh("", 0),
            [false],
            "membership changes must refresh every window"
        );
    }

    #[test]
    fn the_typo_switch_holds_and_asks_windows_once() {
        let tree = TempTree::new("typo-switch");
        fs::write(tree.0.join("hello.txt"), b"one").unwrap();
        let (engine, _listener, rx) = start_with(config(&tree), None);
        phases(&rx);
        assert!(!engine.shared.settings.typos.load(Ordering::Relaxed));
        let changes = |on: bool| {
            rx.try_iter().for_each(drop);
            engine.set_typos(on).unwrap();
            assert_eq!(engine.shared.settings.typos.load(Ordering::Relaxed), on);
            (rx.try_iter())
                .filter(|e| matches!(e, Event::Changed(_)))
                .count()
        };
        assert_eq!(changes(true), 1);
        assert_eq!(changes(true), 0);
        assert_eq!(changes(false), 1);
    }

    #[test]
    fn the_typo_switch_rescues_with_bold_letters() {
        let tree = TempTree::new("typo-rescue");
        for name in ["explorer.txt", "hello.txt", "hell.txt"] {
            fs::write(tree.0.join(name), b"").unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let session = engine.clone().session().unwrap();
        let rows = |query: &str| {
            let g = session.search(query.to_owned(), BEST_MATCH).unwrap();
            let n = ready(&rx, g);
            session.rows(g, 0, n).unwrap()
        };
        let names = |query: &str| rows(query).into_iter().map(|h| h.name).collect::<Vec<_>>();
        assert!(rows("epxlorer").is_empty());
        assert_eq!(names("hello"), ["hello.txt"]);
        rx.try_iter().for_each(drop);
        engine.set_typos(true).unwrap();
        assert!(rx.try_iter().any(|e| matches!(e, Event::Changed(_))));
        let rescued = rows("epxlorer");
        assert_eq!(rescued.len(), 1);
        assert_eq!(rescued[0].name, "explorer.txt");
        assert!(!rescued[0].matches.is_empty());
        assert_eq!(names("hello"), ["hello.txt"]);
        engine.set_typos(false).unwrap();
        assert!(rows("epxlorer").is_empty());
    }

    #[test]
    fn only_paths_below_volumes_leave_the_boot_fingerprint_unchanged() {
        let settings = settle(&EngineConfig {
            root: "/".to_owned(),
            home: "/Users".to_owned(),
            data_folder: String::new(),
            socket_folder: Some(String::new()),
            excluded: Vec::new(),
            indexed_volumes: Vec::new(),
            live_updates_paused: false,
        })
        .unwrap();
        let empty = settings.exclude(&[]);
        let excluded = settings.exclude(&["/Volumes/Wherever-unmounted/Skip".to_owned()]);
        assert_eq!(excluded.print, empty.print);
        assert_eq!(
            excluded.skip,
            [PathBuf::from("/Volumes/Wherever-unmounted/Skip")]
        );
        for path in ["/Volumes", "/Volumes-other/Skip", "/Users/Wherever/Skip"] {
            assert_ne!(
                settings.exclude(&[path.to_owned()]).print,
                empty.print,
                "{path}"
            );
        }
        let tree = TempTree::new("excl-volumes-root");
        let mut settings = settle(&config(&tree)).unwrap();
        settings.exclusions.get_mut().unwrap().volumes_root = Some(settings.root.join("Vols"));
        let path = settings.root.join("Vols/Drive/Skip");
        let empty = settings.exclude(&[]);
        assert_eq!(
            settings.exclude(&[path.to_str().unwrap().to_owned()]).print,
            empty.print
        );
    }

    #[test]
    fn settle_refuses_a_relative_or_empty_row() {
        let tree = TempTree::new("excl-settle");
        let id = "0A0A0A0A-0000-4000-8000-00000000000A";
        let bad = [
            "Sub".to_owned(),
            String::new(),
            format!("{id}/"),
            format!("{id}//Sub"),
            format!("{id}/../Sub"),
            "not-a-uuid/Sub".to_owned(),
        ];
        let keep = tree.0.join("Sub");
        let mut config = config(&tree);
        config.excluded = [&bad[..], &[given(&keep), format!("{id}/In/Side")]].concat();
        let settings = settle(&config).unwrap();
        assert_eq!(settings.exclusions().excluded, [real(&keep)]);
        assert_eq!(
            settings.exclusions().on_disks,
            [(id.to_owned(), PathBuf::from("In/Side"))]
        );
        let (engine, _listener, rx) = start_with(config, None);
        let faults: Vec<String> = (0..bad.len())
            .map(|_| match next(&rx) {
                Event::Fault(message) => message,
                _ => panic!("an event came before the refused rows' faults"),
            })
            .collect();
        phases(&rx);
        until_live(&rx);
        assert_eq!(
            count(&engine, &rx, "'delta"),
            0,
            "Sub/DELTA.Txt is excluded"
        );
        assert_eq!(count(&engine, &rx, "'beta"), 1);
        for b in &bad {
            assert!(
                faults.iter().any(|f| f.starts_with(&format!("{b:?} "))),
                "{b:?}: {faults:?}"
            );
            let refused = engine.set_excluded(vec![given(&keep), b.clone()]);
            assert!(matches!(refused, Err(EngineError::Io { .. })), "{b:?}");
        }
    }

    fn given(path: &Path) -> String {
        path.to_str().unwrap().to_owned()
    }

    pub(crate) fn start_in_volumes(
        config: EngineConfig,
    ) -> (Arc<Engine>, Arc<Recorder>, Receiver<Event>) {
        let mut settings = settle(&config).unwrap();
        settings.exclusions.get_mut().unwrap().volumes_root = Some(settings.root.join("Vols"));
        *settings.exclusions.get_mut().unwrap() = settings.exclude(&config.excluded);
        let (events, rx) = mpsc::channel();
        let listener = Recorder::new(events, None);
        let engine =
            Engine::with_settings(settings, config.indexed_volumes, listener.clone()).unwrap();
        (engine, listener, rx)
    }

    pub(crate) fn start(tree: &TempTree) -> (Arc<Engine>, Arc<Recorder>, Receiver<Event>) {
        start_with(config(tree), None)
    }

    pub(crate) fn next(rx: &Receiver<Event>) -> Event {
        rx.recv_timeout(Duration::from_secs(10)).unwrap()
    }

    pub(crate) fn ready(rx: &Receiver<Event>, generation: u64) -> u32 {
        loop {
            if let Event::Ready(g, count) = next(rx)
                && g == generation
            {
                return count;
            }
        }
    }

    pub(crate) fn next_result(rx: &Receiver<Event>) -> (u64, u32) {
        loop {
            match next(rx) {
                Event::Ready(generation, count) => return (generation, count),
                Event::State(_) | Event::Changed(_) => {}
                event => panic!("unexpected engine event: {event:?}"),
            }
        }
    }

    pub(crate) fn phases(rx: &Receiver<Event>) -> Vec<(EnginePhase, u64)> {
        let mut seen = Vec::new();
        loop {
            match next(rx) {
                Event::State(s) => {
                    seen.push((s.phase, s.indexed));
                    if s.phase == EnginePhase::Ready {
                        return seen;
                    }
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                Event::Ready(..) | Event::Progress(..) | Event::Failed(_) | Event::Changed(_) => {}
            }
        }
    }

    pub(crate) fn until_live(rx: &Receiver<Event>) {
        loop {
            match next(rx) {
                Event::State(s) if s.phase == EnginePhase::Live => return,
                Event::State(s) => assert_ne!(s.phase, EnginePhase::Crawling),
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                Event::Changed(p) => assert_eq!(p, 1, "the apply thread can download placeholders"),
                Event::Ready(..) | Event::Progress(..) | Event::Failed(_) => {}
            }
        }
    }

    pub(crate) fn changed(rx: &Receiver<Event>) {
        loop {
            match next(rx) {
                Event::Changed(p) => {
                    return assert_eq!(p, 1, "the apply thread can download placeholders");
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn until_found(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        query: &str,
        want: &[(&str, &str)],
    ) -> bool {
        seek(engine, rx, query, want, true)
    }

    pub(crate) fn seek(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        query: &str,
        want: &[(&str, &str)],
        strict: bool,
    ) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut want: Vec<(String, String)> = want
            .iter()
            .map(|&(n, f)| (n.to_owned(), f.to_owned()))
            .collect();
        want.sort();
        let session = engine.clone().session().unwrap();
        let mut pending = Some(session.search(query.to_owned(), BEST_MATCH).unwrap());
        let (mut dirty, mut changed) = (false, false);
        let mut got = Vec::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let Ok(event) = rx.recv_timeout(left) else {
                panic!("{query}: found {got:?}, not {want:?}, after 10 s");
            };
            match event {
                Event::Changed(p) => {
                    if strict {
                        assert_eq!(p, 1, "the apply thread can download placeholders");
                    }
                    (dirty, changed) = (true, true);
                }
                Event::Ready(g, count) if Some(g) == pending => {
                    got = session
                        .rows(g, 0, count)
                        .unwrap()
                        .into_iter()
                        .map(|h| (h.name, h.folder))
                        .collect();
                    got.sort();
                    if got == want {
                        return changed;
                    }
                    pending = None;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
            if pending.is_none() && dirty {
                pending = Some(session.search(query.to_owned(), BEST_MATCH).unwrap());
                dirty = false;
            }
        }
    }

    fn saved_file(tree: &TempTree) -> PathBuf {
        tree.data().join(index::FILE)
    }

    fn rows_for(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        queries: &[&str],
    ) -> Vec<Vec<EngineHit>> {
        let session = engine.clone().session().unwrap();
        queries
            .iter()
            .map(|q| {
                let g = session.search((*q).to_owned(), BEST_MATCH).unwrap();
                let count = ready(rx, g);
                session.rows(g, 0, count).unwrap()
            })
            .collect()
    }

    const CRAWLED: [(EnginePhase, u64); 3] = [
        (EnginePhase::Crawling, 0),
        (EnginePhase::Finishing, 0),
        (EnginePhase::Ready, 6),
    ];
    const LOADED: [(EnginePhase, u64); 2] = [(EnginePhase::Loading, 0), (EnginePhase::Ready, 6)];

    pub(crate) fn found(
        session: &EngineSession,
        generation: u64,
    ) -> Vec<(String, String, EngineKind)> {
        let rows = session.rows(generation, 0, 100).unwrap();
        let mut v: Vec<_> = rows
            .into_iter()
            .map(|h| (h.name, h.folder, h.kind))
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    pub(crate) fn count(engine: &Arc<Engine>, rx: &Receiver<Event>, query: &str) -> u32 {
        let session = engine.clone().session().unwrap();
        let g = session.search(query.to_owned(), BEST_MATCH).unwrap();
        ready(rx, g)
    }

    #[test]
    fn reports_crawling_then_ready_then_results() {
        let tree = TempTree::new("engine-states");
        let (engine, _listener, rx) = start(&tree);
        let session = engine.clone().session().unwrap();
        let generation = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        let crawling = EngineState {
            phase: EnginePhase::Crawling,
            boot_phase: EnginePhase::Crawling,
            indexing: Vec::new(),
            troubles: Vec::new(),
            indexed: 0,
        };
        assert!(matches!(next(&rx), Event::State(s) if s == crawling));
        assert!(matches!(
            next(&rx),
            Event::State(EngineState {
                phase: EnginePhase::Finishing,
                indexed: 0,
                ..
            })
        ));
        assert!(matches!(
            next(&rx),
            Event::State(EngineState {
                phase: EnginePhase::Ready,
                indexed: 6,
                ..
            })
        ));
        assert_eq!(next_result(&rx), (generation, 3));
    }

    #[test]
    fn the_build_after_a_crawl_reports_finishing() {
        let tree = TempTree::new("engine-finishing");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        let ((reached, at), (go, gate)) = (mpsc::channel(), mpsc::channel());
        *shared(&engine).save_hold.lock().unwrap() = Some((reached, gate));
        release.send(None).unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let seen: Vec<(EnginePhase, EnginePhase)> = rx
            .try_iter()
            .filter_map(|e| match e {
                Event::State(s) => Some((s.phase, s.boot_phase)),
                _ => None,
            })
            .collect();
        assert_eq!(
            seen.last(),
            Some(&(EnginePhase::Finishing, EnginePhase::Finishing)),
            "{seen:?}"
        );
        assert!(!saved_file(&tree).exists());
        go.send(()).unwrap();
        assert_eq!(phases(&rx).last(), Some(&(EnginePhase::Ready, 6)));
        assert!(saved_file(&tree).exists());
    }

    #[test]
    fn a_failed_boot_index_reports_failed() {
        let tree = TempTree::new("engine-failed");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        *shared(&engine).opened.lock().unwrap() =
            Some(Arc::new(|_: &AtomicBool| panic!("injected crawl panic")));
        release.send(None).unwrap();
        let mut faults = Vec::new();
        let failed = loop {
            match next(&rx) {
                Event::Fault(m) => faults.push(m),
                Event::State(s) if s.boot_phase != EnginePhase::Crawling => break s,
                _ => {}
            }
        };
        assert_eq!(
            (failed.phase, failed.boot_phase),
            (EnginePhase::Failed, EnginePhase::Failed)
        );
        assert!(
            faults.iter().any(|m| m.contains("injected crawl panic")),
            "{faults:?}"
        );
        assert!(!saved_file(&tree).exists());
        let session = engine.clone().session().unwrap();
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        ready(&rx, g);
    }

    #[test]
    fn a_panicking_search_keeps_the_lane_answering() {
        let tree = TempTree::new("engine-panic");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        let session = engine.clone().session().unwrap();
        shared(&engine).fail_scan.store(true, Ordering::Relaxed);
        let lost = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(failed(&rx), lost);
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
    }

    #[test]
    fn a_panicking_press_is_failed_and_the_next_search_answers() {
        let tree = TempTree::new("engine-press-panic");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        let session = engine.clone().session().unwrap();
        shared(&engine).fail_scan.store(true, Ordering::Relaxed);
        let press = session
            .search_content("txt".to_owned(), vec!["alpha".to_owned()], true, BEST_MATCH)
            .unwrap();
        assert_eq!(failed(&rx), press);
        quiet(&rx, press, press, Duration::from_millis(300));
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
    }

    #[test]
    fn a_press_that_panics_in_a_narrows_job_fails_both() {
        let tree = TempTree::new("engine-press-narrow-panic");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        let (wake, _woken) = mpsc::sync_channel(1);
        let lane = Lane::new(0, BEST_MATCH, wake);
        let (jobs, _queued) = mpsc::channel();
        let counter = AtomicU64::new(1_000_000);
        let terms = Terms {
            terms: vec![query::term("hello")],
            all: true,
        };
        let press = lane
            .ask(
                &counter,
                &jobs,
                Ask::Press(String::new(), terms),
                BEST_MATCH,
            )
            .unwrap();
        let narrow =
            (lane.ask(&counter, &jobs, Ask::Narrow("Alpha".to_owned()), BEST_MATCH)).unwrap();
        shared(&engine).fail_scan.store(true, Ordering::Relaxed);
        answer(&engine.shared, &lane.take_job(), &Pool::live().unwrap());
        let mut heard = Vec::new();
        while heard.len() < 2 {
            match next(&rx) {
                Event::Failed(g) => heard.push(g),
                Event::Ready(g, _) => panic!("generation {g} answered"),
                _ => {}
            }
        }
        assert_eq!(heard, [press, narrow]);
        quiet(&rx, press, narrow, Duration::from_millis(300));
    }

    #[test]
    fn a_panicking_worker_reports_failed_and_answers_on() {
        let tree = TempTree::new("engine-worker-panic");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        shared(&engine).fail_run.store(true, Ordering::Relaxed);
        release.send(None).unwrap();
        let (failed, faults) = faulted_until(&rx, |s| s.boot_phase == EnginePhase::Failed);
        assert_eq!(failed.phase, EnginePhase::Failed);
        assert!(
            faults.iter().any(|m| m.contains("injected worker panic")),
            "{faults:?}"
        );
        let session = engine.clone().session().unwrap();
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        ready(&rx, g);
    }

    #[test]
    fn a_panicking_apply_thread_turns_live_updates_off() {
        let tree = TempTree::new("engine-apply-panic");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        shared(&engine).fail_apply.store(true, Ordering::Relaxed);
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        let (off, faults) = faulted_until(&rx, |s| !s.troubles.is_empty());
        assert_eq!(
            off.troubles,
            [EngineTrouble {
                root: tree.real(),
                kind: crate::EngineTroubleKind::LiveUpdatesOff,
            }]
        );
        assert_eq!(
            (off.phase, off.boot_phase),
            (EnginePhase::Ready, EnginePhase::Ready)
        );
        assert!(
            faults.iter().any(|m| m.contains("injected apply panic")),
            "{faults:?}"
        );
        let session = engine.clone().session().unwrap();
        let g = session.search("Alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
    }

    #[test]
    fn a_panicking_reader_ends_the_press() {
        let tree = TempTree::new("engine-read-panic");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        let session = engine.clone().session().unwrap();
        shared(&engine).fail_read.store(true, Ordering::Relaxed);
        let g = press(&session, "", "hello");
        assert!(done_after(&rx, g, "injected read panic"));
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
    }

    #[test]
    fn a_panicking_walk_ends_the_press() {
        let (_tree, other, engine, rx) = beside("engine-walk-panic");
        *engine.shared.opened.lock().unwrap() =
            Some(Arc::new(|_: &AtomicBool| panic!("injected walk panic")));
        let session = engine.clone().session().unwrap();
        let g = press(&session, &format!("in:{}", other.real()), "zyq");
        assert!(done_after(&rx, g, "injected walk panic"));
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        ready(&rx, g);
    }

    fn faulted_until(
        rx: &Receiver<Event>,
        want: impl Fn(&EngineState) -> bool,
    ) -> (EngineState, Vec<String>) {
        let mut faults = Vec::new();
        loop {
            match next(rx) {
                Event::Fault(m) => faults.push(m),
                Event::State(s) if want(&s) => return (s, faults),
                _ => {}
            }
        }
    }

    fn done_after(rx: &Receiver<Event>, press: u64, said: &str) -> bool {
        let mut faulted = false;
        loop {
            match next(rx) {
                Event::Fault(m) => faulted |= m.contains(said),
                Event::Progress(p, _, _, true) if p == press => return faulted,
                _ => {}
            }
        }
    }

    pub(crate) fn failed(rx: &Receiver<Event>) -> u64 {
        let mut faulted = false;
        loop {
            match next(rx) {
                Event::Fault(m) => {
                    assert!(m.contains("injected search panic"), "{m}");
                    faulted = true;
                }
                Event::Failed(g) => {
                    assert!(faulted, "search_failed came before its fault");
                    return g;
                }
                Event::Ready(g, _) => panic!("generation {g} answered before the failure"),
                _ => {}
            }
        }
    }

    #[test]
    fn matches_case_insensitive_substrings() {
        let tree = TempTree::new("engine-match");
        let root = tree.real();
        let (engine, _listener, rx) = start(&tree);
        let session = engine.clone().session().unwrap();
        let g = session.search("TXT".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let expected = [
            ("Alpha.TXT", root.clone(), EngineKind::File),
            ("DELTA.Txt", format!("{root}/Sub"), EngineKind::File),
            ("beta.txt", root.clone(), EngineKind::File),
        ];
        assert_eq!(
            found(&session, g),
            expected.map(|(n, f, k)| (n.to_owned(), f, k))
        );
        let g = session.search("LiNk".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [("link".to_owned(), root.clone(), EngineKind::Link)]
        );
        let g = session.search("sub".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(
            found(&session, g),
            [("Sub".to_owned(), root.clone(), EngineKind::Folder)]
        );
        let g = session.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        let alpha = &session.rows(g, 0, 1).unwrap()[0];
        assert_eq!(alpha.size, 5);
        assert!(alpha.modified > 0);
    }

    #[test]
    fn old_generation_is_stale() {
        let tree = TempTree::new("engine-stale");
        let (engine, _listener, rx) = start(&tree);
        let session = engine.clone().session().unwrap();
        let first = session.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        assert_eq!(session.rows(first, 0, 10).unwrap()[0].name, "Alpha.TXT");
        let second = session.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert!(second > first);
        assert_eq!(ready(&rx, second), 1);
        assert_eq!(
            session.rows(second, 0, u32::MAX).unwrap()[0].name,
            "Gamma.md"
        );
        assert!(
            matches!(session.rows(first, 0, 10), Err(EngineError::Stale { generation }) if generation == first)
        );
        assert!(session.rows(second, 1, 10).unwrap().is_empty());
        assert!(session.rows(second, u32::MAX, u32::MAX).unwrap().is_empty());
    }

    #[test]
    fn newer_search_drops_older_ones() {
        let tree = TempTree::new("engine-newest");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Ready, 0, hold)));
        let session = engine.clone().session().unwrap();
        assert_eq!(phases(&rx).last(), Some(&(EnginePhase::Ready, 6)));
        let older = [
            session.search("alpha".to_owned(), BEST_MATCH).unwrap(),
            session.search("beta".to_owned(), BEST_MATCH).unwrap(),
        ];
        let newest = session.search("gamma".to_owned(), BEST_MATCH).unwrap();
        release.send(None).unwrap();
        assert_eq!(next_result(&rx), (newest, 1));
        assert_eq!(found(&session, newest)[0].0, "Gamma.md");
        for g in older {
            assert!(matches!(
                session.rows(g, 0, 10),
                Err(EngineError::Stale { .. })
            ));
        }
    }

    #[test]
    fn late_old_job_on_empty_root_publishes_nothing() {
        let tree = TempTree::new("engine-empty");
        let empty = tree.0.join("Empty");
        fs::create_dir(&empty).unwrap();
        let mut config = config(&tree);
        config.root = empty.to_str().unwrap().to_owned();
        let (engine, _listener, rx) = start_with(config, None);
        let session = engine.clone().session().unwrap();
        assert_eq!(
            phases(&rx),
            [
                (EnginePhase::Crawling, 0),
                (EnginePhase::Finishing, 0),
                (EnginePhase::Ready, 0)
            ]
        );
        let older = session.search("a".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, older), 0);
        let newer = session.search("b".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, newer), 0);
        answer(
            &engine.shared,
            &Job {
                generation: older,
                lane: Arc::downgrade(&session.lane),
            },
            &Pool::live().unwrap(),
        );
        let deadline = Instant::now() + Duration::from_millis(500);
        while let Ok(e) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            assert!(!matches!(e, Event::Ready(..)), "{e:?}");
        }
        assert!(session.rows(newer, 0, 1).unwrap().is_empty());
    }

    #[test]
    fn drop_joins_threads() {
        let tree = TempTree::new("engine-drop");
        let (engine, listener, rx) = start(&tree);
        assert_eq!(phases(&rx).last(), Some(&(EnginePhase::Ready, 6)));
        drop(engine);
        assert_eq!(Arc::strong_count(&listener), 1);
        let mut fresh = config(&tree);
        fresh.data_folder = tree.data().join("second").to_str().unwrap().to_owned();
        let (engine, listener, _rx) = start_with(fresh, None);
        drop(engine);
        assert_eq!(Arc::strong_count(&listener), 1);
    }

    #[test]
    fn bad_root_is_an_io_error() {
        let tree = TempTree::new("engine-badroot");
        let (events, _rx) = mpsc::channel();
        let listener = Recorder::new(events, None);
        for root in [tree.0.join("missing"), tree.0.join("Alpha.TXT")] {
            let mut config = config(&tree);
            config.root = root.to_str().unwrap().to_owned();
            let started = Engine::new(config, listener.clone());
            assert!(matches!(started, Err(EngineError::Io { .. })));
        }
    }

    #[test]
    fn every_config_crawls_the_gated_folders() {
        let tree = TempTree::new("engine-access");
        let home = tree.0.join("home");
        for dir in ["Desktop", "Documents", "Library/Mobile Documents", "Other"] {
            fs::create_dir_all(home.join(dir)).unwrap();
        }
        fs::write(home.join("Desktop/secret.txt"), b"").unwrap();
        fs::write(home.join("Library/Mobile Documents/b.txt"), b"").unwrap();
        fs::write(home.join("Documents/zyqlocked.txt"), b"").unwrap();
        fs::write(home.join("Other/c.txt"), b"").unwrap();
        let _locked = Locked::new(vec![home.join("Documents")]);
        let mut config = config(&tree);
        config.excluded = [home.join("Other"), tree.0.join("missing")]
            .map(|p| p.to_str().unwrap().to_owned())
            .to_vec();

        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) = start_with(config, Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        release.send(None).unwrap();
        phases(&rx);
        assert_eq!(count(&engine, &rx, "'secret"), 1);
        assert_eq!(count(&engine, &rx, "'b.txt"), 1);
        assert_eq!(count(&engine, &rx, "'c.txt"), 0);
        assert_eq!(count(&engine, &rx, "'zyqlocked"), 0);
    }

    #[test]
    fn a_saved_index_loads_without_a_crawl() {
        let tree = TempTree::new("engine-reload");
        let size = (3 << 30) + 1;
        fs::File::create(tree.0.join("Sub/big.bin"))
            .unwrap()
            .set_len(size)
            .unwrap();
        let queries = ["", "a", "TXT", "sub", "big", "link", "zzz", "é"];
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(
            phases(&rx),
            [
                (EnginePhase::Crawling, 0),
                (EnginePhase::Finishing, 0),
                (EnginePhase::Ready, 7)
            ]
        );
        let crawled = rows_for(&engine, &rx, &queries);
        drop(engine);
        let before = fs::metadata(saved_file(&tree)).unwrap();

        let (engine, _listener, rx) = start(&tree);
        assert_eq!(
            phases(&rx),
            [(EnginePhase::Loading, 0), (EnginePhase::Ready, 7)]
        );
        let after = fs::metadata(saved_file(&tree)).unwrap();
        assert_eq!(
            (after.ino(), after.mtime(), after.mtime_nsec()),
            (before.ino(), before.mtime(), before.mtime_nsec())
        );
        assert_eq!(rows_for(&engine, &rx, &queries), crawled);
        assert_eq!(crawled[0].len(), 7);
        let big = crawled[4].iter().find(|h| h.name == "big.bin").unwrap();
        assert_eq!(
            (big.size, big.folder.clone()),
            (size, format!("{}/Sub", tree.real()))
        );
    }

    #[test]
    fn a_damaged_file_is_crawled_again_and_rewritten() {
        let tree = TempTree::new("engine-damaged");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        drop(engine);
        let file = OpenOptions::new()
            .write(true)
            .open(saved_file(&tree))
            .unwrap();
        file.set_len(file.metadata().unwrap().len() / 2).unwrap();
        drop(file);

        let (engine, _listener, rx) = start(&tree);
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Loading));
        assert!(matches!(next(&rx), Event::Fault(m) if m.ends_with("crawling again")));
        assert_eq!(phases(&rx), CRAWLED);
        let session = engine.clone().session().unwrap();
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let names: Vec<String> = found(&session, g).into_iter().map(|r| r.0).collect();
        assert_eq!(names, ["Alpha.TXT", "DELTA.Txt", "beta.txt"]);
        drop(session);
        drop(engine);

        let (_engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), LOADED);
    }

    #[test]
    fn a_saved_out_of_files_skip_crawls_again() {
        let tree = TempTree::new("engine-outoffiles");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        drop(engine);
        let sub = format!("{}/Sub", tree.real());
        let resave = |skips: Vec<String>| {
            let mut index = Index::load(&saved_file(&tree), PathBuf::from(tree.real())).unwrap();
            index.set_skips(skips);
            index.save(&saved_file(&tree)).unwrap();
        };

        resave(Vec::new());
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), LOADED);
        drop(engine);

        resave(vec![sub]);
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(
            phases(&rx),
            [
                (EnginePhase::Loading, 0),
                CRAWLED[0],
                CRAWLED[1],
                CRAWLED[2]
            ]
        );
        let saved = Index::load(&saved_file(&tree), PathBuf::from(tree.real())).unwrap();
        assert!(saved.skipped().is_empty());
        drop(engine);
    }

    #[test]
    fn a_crawl_cut_short_saves_nothing() {
        let tree = TempTree::new("engine-cut");
        let (handoff, hold) = mpsc::channel();
        let (engine, listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, hold)));
        handoff.send(Some(engine)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while Arc::strong_count(&listener) > 1 {
            assert!(Instant::now() < deadline, "the worker never ended");
            thread::sleep(Duration::from_millis(10));
        }
        let seen: Vec<Event> = rx.try_iter().collect();
        assert!(
            matches!(
                seen.as_slice(),
                [Event::State(EngineState {
                    phase: EnginePhase::Crawling,
                    indexed: 0,
                    ..
                })]
            ),
            "{seen:?}"
        );
        assert!(!saved_file(&tree).exists());

        let (_engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
    }

    #[test]
    fn a_release_on_a_crawl_thread_never_waits_for_the_worker() {
        let tree = TempTree::new("engine-crawl-release");
        fs::create_dir(tree.0.join("Slow")).unwrap();
        fs::write(tree.0.join("Slow/one"), b"").unwrap();
        let (open, opened) = mpsc::channel();
        let (handoff, hold) = mpsc::channel();
        let (go, first) = mpsc::channel();
        let (engine, listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, first)));
        let taken = Instant::now() + Duration::from_secs(10);
        while listener.hold.lock().unwrap().is_some() {
            assert!(Instant::now() < taken, "the crawl never reported");
            thread::sleep(Duration::from_millis(1));
        }
        let slept = AtomicBool::new(false);
        *shared(&engine).opened.lock().unwrap() = Some(Arc::new(move |_: &AtomicBool| {
            if !slept.swap(true, Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(400));
                let _ = open.send(());
            }
        }));
        *listener.hold.lock().unwrap() = Some((EnginePhase::Crawling, 1, hold));
        handoff.send(Some(engine)).unwrap();
        go.send(None).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while Arc::strong_count(&listener) > 1 {
            assert!(Instant::now() < deadline, "the worker never ended");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(opened.try_recv().is_ok(), "no folder open slept");
        let seen: Vec<(EnginePhase, u64)> = rx
            .try_iter()
            .filter_map(|e| match e {
                Event::State(s) => Some((s.phase, s.indexed)),
                _ => None,
            })
            .collect();
        assert!(
            matches!(
                seen.as_slice(),
                [(EnginePhase::Crawling, 0), (EnginePhase::Crawling, n)] if *n > 0
            ),
            "{seen:?}"
        );
        assert!(!saved_file(&tree).exists());
    }

    #[test]
    fn created_renamed_and_deleted_files_show_up() {
        let tree = TempTree::new("engine-live");
        let root = tree.real();
        let made = format!("{root}/Made");
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        if !until_found(&engine, &rx, "new.txt", &[("new.txt", &root)]) {
            changed(&rx);
        }
        fs::rename(tree.0.join("new.txt"), tree.0.join("moved.txt")).unwrap();
        until_found(&engine, &rx, "moved.txt", &[("moved.txt", &root)]);
        until_found(&engine, &rx, "new.txt", &[]);
        fs::remove_file(tree.0.join("moved.txt")).unwrap();
        until_found(&engine, &rx, "moved.txt", &[]);
        fs::create_dir(tree.0.join("Made")).unwrap();
        fs::write(tree.0.join("Made/one.md"), b"").unwrap();
        fs::write(tree.0.join("Made/two.md"), b"").unwrap();
        let md = [
            ("Gamma.md", root.as_str()),
            ("one.md", &made),
            ("two.md", &made),
        ];
        until_found(&engine, &rx, ".md", &md);
        until_found(&engine, &rx, "made", &[("Made", &root)]);
        fs::remove_dir_all(tree.0.join("Made")).unwrap();
        until_found(&engine, &rx, ".md", &[("Gamma.md", &root)]);
        until_found(&engine, &rx, "made", &[]);
    }

    pub(crate) fn files_shown(engine: &Engine) -> u64 {
        engine.shared.units().iter().map(|u| u.status().1).sum()
    }

    pub(crate) fn shown(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        step: &str,
        query: &str,
        want: &[(&str, &str)],
        files: u64,
    ) {
        let started = Instant::now();
        until_found(engine, rx, query, want);
        let found = started.elapsed();
        let deadline = started + Duration::from_secs(10);
        while files_shown(engine) != files {
            assert!(
                Instant::now() < deadline,
                "{step}: Files showed {}, not {files}, after 10 s",
                files_shown(engine)
            );
            thread::sleep(Duration::from_millis(5));
        }
        eprintln!("{step}: results {found:?}, Files {:?}", started.elapsed());
    }

    pub(crate) fn live_round(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        tree: &TempTree,
        tag: &str,
    ) {
        let root = tree.real();
        let base = files_shown(engine);
        let name = |n: &str| format!("{tag}{n}");
        let folder = format!("{root}/{}", name("dir"));
        let step = |what: &str| format!("{tag} {what}");
        fs::write(tree.0.join(name("one.txt")), b"").unwrap();
        let one = [(name("one.txt"), root.clone())];
        let one: Vec<(&str, &str)> = one.iter().map(|(n, f)| (n.as_str(), f.as_str())).collect();
        shown(engine, rx, &step("new file"), &name("one"), &one, base + 1);
        fs::create_dir(tree.0.join(name("dir"))).unwrap();
        fs::write(tree.0.join(name("dir")).join(name("two.txt")), b"").unwrap();
        let (dir, two) = (name("dir"), name("two.txt"));
        shown(
            engine,
            rx,
            &step("new folder"),
            &dir,
            &[(&dir, &root)],
            base + 3,
        );
        shown(
            engine,
            rx,
            &step("file in it"),
            &name("two"),
            &[(&two, &folder)],
            base + 3,
        );
        fs::rename(tree.0.join(name("one.txt")), tree.0.join(name("moved.txt"))).unwrap();
        let moved = name("moved.txt");
        shown(
            engine,
            rx,
            &step("rename"),
            &name("moved"),
            &[(&moved, &root)],
            base + 3,
        );
        shown(engine, rx, &step("old name"), &name("one"), &[], base + 3);
        fs::remove_file(tree.0.join(&moved)).unwrap();
        shown(
            engine,
            rx,
            &step("delete file"),
            &name("moved"),
            &[],
            base + 2,
        );
        fs::remove_dir_all(tree.0.join(&dir)).unwrap();
        shown(engine, rx, &step("delete folder"), &dir, &[], base);
        shown(engine, rx, &step("its file"), &name("two"), &[], base);
    }

    pub(crate) fn replayed(engine: &Engine) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.shared.units().iter().any(|u| u.watcher().replaying) {
            assert!(Instant::now() < deadline, "a replay never ended");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn live_changes_show_after_a_start_a_resume_and_every_restart() {
        let tree = TempTree::new("live-path");
        let root = tree.real();
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        live_round(&engine, &rx, &tree, "zyqa");

        switched(&engine, false);
        let held = files_shown(&engine);
        fs::write(tree.0.join("zyqheld.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        assert_eq!(files_shown(&engine), held, "Files moved during the pause");
        switched(&engine, true);
        let heldfile = [("zyqheld.txt", root.as_str())];
        shown(&engine, &rx, "resume", "zyqheld", &heldfile, held + 1);
        replayed(&engine);
        live_round(&engine, &rx, &tree, "zyqb");

        engine.flush_opens().unwrap();
        drop(engine);
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        live_round(&engine, &rx, &tree, "zyqc");

        switched(&engine, false);
        let before = files_shown(&engine);
        fs::write(tree.0.join("zyqquit.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        engine.flush_opens().unwrap();
        drop(engine);
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let quitfile = [("zyqquit.txt", root.as_str())];
        shown(
            &engine,
            &rx,
            "start after a paused quit",
            "zyqquit",
            &quitfile,
            before + 1,
        );
        live_round(&engine, &rx, &tree, "zyqd");

        switched(&engine, false);
        engine.flush_opens().unwrap();
        drop(engine);
        let (engine, _listener, rx) = start_with(paused_config(&tree), None);
        phases(&rx);
        switched(&engine, true);
        until_live(&rx);
        live_round(&engine, &rx, &tree, "zyqe");
    }

    #[test]
    fn a_restart_replays_from_the_saved_event_id() {
        let tree = TempTree::new("engine-replay");
        let root = tree.real();
        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        drop(engine);
        let saved = Index::load(&saved_file(&tree), PathBuf::from(&root))
            .unwrap()
            .event_id();
        fs::write(tree.0.join("later.txt"), b"").unwrap();
        fs::remove_file(tree.0.join("beta.txt")).unwrap();

        let (engine, _listener, rx) = start(&tree);
        assert_eq!(phases(&rx), LOADED);
        until_live(&rx);
        until_found(&engine, &rx, "later", &[("later.txt", &root)]);
        until_found(&engine, &rx, "beta", &[]);
        let boot = engine.shared.units()[0].clone();
        let w = boot.watcher();
        assert_eq!((w.count, w.since), (1, saved));
        assert!(saved != 0 && saved < Api::load().unwrap().current_id());
    }

    fn start_on_build(tree: &TempTree, build: u8) -> (Arc<Engine>, Receiver<Event>) {
        start_config_on_build(config(tree), build)
    }

    fn start_config_on_build(config: EngineConfig, build: u8) -> (Arc<Engine>, Receiver<Event>) {
        let mut marker = [0; index::OS_BUILD_BYTES];
        marker[0] = build;
        unit::OS_BUILD.set(Some(marker));
        let (engine, _listener, rx) = start_with(config, None);
        unit::OS_BUILD.set(None);
        (engine, rx)
    }

    fn paused_config(tree: &TempTree) -> EngineConfig {
        EngineConfig {
            live_updates_paused: true,
            ..config(tree)
        }
    }

    fn assert_parked_at_ready(engine: &Engine) {
        for unit in engine.shared.units().iter() {
            assert_eq!(unit.status().0, EnginePhase::Ready);
            assert!(!unit.watcher().running(), "a paused start ran a stream");
        }
    }

    fn boot_relist_case(name: &str, build: u8, future: bool, foreign: bool) {
        let tree = TempTree::new(name);
        fs::create_dir(tree.0.join("sys")).unwrap();
        let (engine, rx) = start_on_build(&tree, b'A');
        phases(&rx);
        until_live(&rx);
        fs::write(tree.0.join("sys/zyqnew.txt"), b"").unwrap();
        fs::File::open(tree.0.join("sys"))
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(1))
            .unwrap();
        until_found(
            &engine,
            &rx,
            "zyqnew",
            &[("zyqnew.txt", &format!("{}/sys", tree.real()))],
        );
        drop(engine);
        let file = saved_file(&tree);
        assert_eq!(
            Index::load(&file, PathBuf::from(tree.real()))
                .unwrap()
                .entries(),
            7
        );
        let mut bytes = fs::read(&file).unwrap();
        let current = Api::load().unwrap().current_id();
        let saved_id = if future { u64::MAX - 1 } else { current };
        bytes[40..48].copy_from_slice(&saved_id.to_le_bytes());
        fs::write(&file, bytes).unwrap();
        if foreign {
            let mut index = Index::load(&file, PathBuf::from(tree.real())).unwrap();
            index.set_history(index.history() ^ 1);
            index.save(&file).unwrap();
        }
        let before = fs::metadata(&file).unwrap().ino();
        let (engine, rx) = start_on_build(&tree, build);
        assert_eq!(
            phases(&rx),
            [(EnginePhase::Loading, 0), (EnginePhase::Ready, 7)]
        );
        until_live(&rx);
        until_found(
            &engine,
            &rx,
            "zyqnew",
            &[("zyqnew.txt", &format!("{}/sys", tree.real()))],
        );
        let boot = engine.shared.units()[0].clone();
        assert!(engine.shared.crawls.lock().unwrap().is_empty());
        assert_eq!(boot.relists.load(Ordering::Relaxed), 1);
        let deadline = Instant::now() + Duration::from_secs(10);
        while fs::metadata(&file).unwrap().ino() == before {
            assert!(Instant::now() < deadline, "the relist never saved");
            thread::sleep(Duration::from_millis(10));
        }
        let saved = Index::load(&file, PathBuf::from(tree.real())).unwrap();
        assert_eq!(saved.os_build()[0], build);
        assert_ne!(saved.history(), 0);
        assert!(saved.event_id() <= Api::load().unwrap().current_id());
        assert!((0..saved.entries()).any(|i| saved.hit(i as u32).name == "zyqnew.txt"));
        drop(engine);
        let (engine, rx) = start_on_build(&tree, build);
        phases(&rx);
        until_live(&rx);
        assert_eq!(engine.shared.units()[0].relists.load(Ordering::Relaxed), 0);
        assert_eq!(count(&engine, &rx, "zyqnew"), 1);
    }

    #[test]
    fn a_new_os_build_relists_the_saved_boot_index() {
        boot_relist_case("boot-os-build", b'B', false, false);
    }

    #[test]
    fn a_foreign_or_reset_history_relists_the_saved_boot_index() {
        boot_relist_case("boot-future-id", b'A', true, false);
        boot_relist_case("boot-foreign-history", b'A', false, true);
    }

    #[test]
    fn an_unchanged_boot_build_and_history_replays_without_relisting() {
        let tree = TempTree::new("boot-unchanged");
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        drop(engine);
        let file = saved_file(&tree);
        let saved = Index::load(&file, PathBuf::from(tree.real())).unwrap();
        let before = fs::metadata(&file).unwrap().ino();
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), LOADED);
        until_live(&rx);
        let boot = engine.shared.units()[0].clone();
        assert_eq!(boot.relists.load(Ordering::Relaxed), 0);
        assert_eq!(boot.watcher().since, saved.event_id());
        assert_eq!(count(&engine, &rx, "beta"), 1);
        assert_eq!(fs::metadata(file).unwrap().ino(), before);
    }

    pub(crate) const PAST_LATENCY: Duration = Duration::from_millis(700);

    #[test]
    fn a_paused_start_holds_a_new_file_back_and_resume_replays_it_without_a_relist() {
        let tree = TempTree::new("paused-start");
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        drop(engine);
        let saved = Index::load(&saved_file(&tree), PathBuf::from(tree.real())).unwrap();
        fs::write(tree.0.join("zyqmissed.txt"), b"").unwrap();

        let (engine, rx) = start_config_on_build(paused_config(&tree), b'A');
        assert_eq!(phases(&rx), LOADED);
        thread::sleep(PAST_LATENCY);
        assert_eq!(count(&engine, &rx, "zyqmissed"), 0);
        assert_parked_at_ready(&engine);
        let boot = engine.shared.units()[0].clone();
        assert_eq!(boot.watcher().since, saved.event_id());

        switched(&engine, true);
        until_found(
            &engine,
            &rx,
            "zyqmissed",
            &[("zyqmissed.txt", &tree.real())],
        );
        assert_eq!(boot.relists.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_paused_start_on_a_new_os_build_relists_once_on_resume() {
        let tree = TempTree::new("paused-os-build");
        let (engine, rx) = start_on_build(&tree, b'A');
        phases(&rx);
        until_live(&rx);
        drop(engine);

        let (engine, rx) = start_config_on_build(paused_config(&tree), b'B');
        phases(&rx);
        let boot = engine.shared.units()[0].clone();
        thread::sleep(PAST_LATENCY);
        assert_eq!(
            boot.relists.load(Ordering::Relaxed),
            0,
            "a paused start relisted before Resume"
        );
        assert!(
            !engine.shared.settling(),
            "a held relist kept Wherever running"
        );
        assert_parked_at_ready(&engine);
        switched(&engine, true);
        let deadline = Instant::now() + Duration::from_secs(10);
        while boot.relists.load(Ordering::Relaxed) == 0 {
            assert!(Instant::now() < deadline, "resume never relisted");
            thread::sleep(Duration::from_millis(10));
        }
        thread::sleep(PAST_LATENCY);
        assert_eq!(boot.relists.load(Ordering::Relaxed), 1);
    }

    pub(crate) fn switched(engine: &Engine, on: bool) {
        engine.set_live_updates(on).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine
            .shared
            .units()
            .iter()
            .any(|u| u.watcher().running() != on)
        {
            assert!(
                Instant::now() < deadline,
                "set_live_updates({on}) left a stream in the wrong state after 10 s"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_pause_holds_a_new_file_back_and_resume_replays_it_without_a_relist() {
        let tree = TempTree::new("pause-new-file");
        let (engine, rx) = outside(&tree);
        let boot = engine.shared.units()[0].clone();
        let streams = boot.watcher().count;
        switched(&engine, false);
        fs::write(tree.0.join("zyqpaused.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        assert_eq!(
            count(&engine, &rx, "zyqpaused"),
            0,
            "a change reached the index during the pause"
        );
        assert_eq!(
            boot.watcher().count,
            streams,
            "a stream started during the pause"
        );
        switched(&engine, true);
        until_found(
            &engine,
            &rx,
            "zyqpaused",
            &[("zyqpaused.txt", &tree.real())],
        );
        assert_eq!(
            boot.watcher().count,
            streams + 1,
            "resume did not start exactly one stream"
        );
        assert_eq!(
            boot.relists.load(Ordering::Relaxed),
            0,
            "resume relisted instead of replaying"
        );
        assert_eq!(
            boot.status().0,
            EnginePhase::Live,
            "a pause and a resume changed the boot phase"
        );
    }

    #[test]
    fn files_changed_during_a_pause_come_out_right_after_resume() {
        let tree = TempTree::new("pause-churn");
        write_all(&tree, &[("zyqdoomed.txt", ""), ("Sub/zyqold.txt", "")]);
        let (engine, rx) = outside(&tree);
        let (root, sub) = (tree.real(), format!("{}/Sub", tree.real()));
        until_found(
            &engine,
            &rx,
            "zyq",
            &[("zyqdoomed.txt", &root), ("zyqold.txt", &sub)],
        );
        switched(&engine, false);
        fs::write(tree.0.join("zyqbrief.txt"), b"").unwrap();
        fs::remove_file(tree.0.join("zyqbrief.txt")).unwrap();
        fs::remove_file(tree.0.join("zyqdoomed.txt")).unwrap();
        fs::rename(tree.0.join("Sub/zyqold.txt"), tree.0.join("Sub/zyqnew.txt")).unwrap();
        switched(&engine, true);
        until_found(&engine, &rx, "zyq", &[("zyqnew.txt", &sub)]);
        assert_eq!(engine.shared.units()[0].relists.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn pausing_twice_and_resuming_twice_start_one_stream_each() {
        let tree = TempTree::new("pause-twice");
        let (engine, _rx) = outside(&tree);
        let boot = engine.shared.units()[0].clone();
        let streams = boot.watcher().count;
        switched(&engine, false);
        switched(&engine, false);
        assert_eq!(boot.watcher().count, streams);
        switched(&engine, true);
        switched(&engine, true);
        thread::sleep(PAST_LATENCY);
        assert_eq!(
            boot.watcher().count,
            streams + 1,
            "a second resume started a second stream"
        );
        for on in [false, true, false, true, false] {
            engine.set_live_updates(on).unwrap();
        }
        switched(&engine, false);
        thread::sleep(PAST_LATENCY);
        assert!(
            !boot.watcher().running(),
            "quick toggles did not settle on the last one"
        );
    }

    #[test]
    fn the_switch_returns_while_the_locks_it_needs_are_held() {
        let tree = TempTree::new("pause-locks");
        let (engine, _rx) = outside(&tree);
        let boot = engine.shared.units()[0].clone();
        let (done, returned) = mpsc::channel();
        let units = engine.shared.units.write().unwrap();
        let held = boot.watcher();
        thread::spawn({
            let engine = engine.clone();
            move || {
                let _ = done.send(engine.set_live_updates(false));
            }
        });
        returned
            .recv_timeout(Duration::from_secs(1))
            .expect("the switch waited on a lock the caller's click cannot wait for")
            .unwrap();
        drop(held);
        drop(units);
        switched(&engine, false);
    }

    #[test]
    fn dropping_a_paused_engine_returns_promptly() {
        let tree = TempTree::new("pause-drop");
        let (engine, _rx) = outside(&tree);
        switched(&engine, false);
        let (done, dropped) = mpsc::channel();
        thread::spawn(move || {
            drop(engine);
            let _ = done.send(());
        });
        dropped
            .recv_timeout(Duration::from_secs(10))
            .expect("dropping a paused engine hung");
    }

    fn saved_long_ago(file: &Path) {
        fs::File::open(file)
            .unwrap()
            .set_modified(SystemTime::now() - apply::COMPACT_EVERY - Duration::from_secs(60))
            .unwrap();
    }

    fn file_mark(file: &Path) -> (u64, SystemTime) {
        let meta = fs::metadata(file).unwrap();
        (meta.ino(), meta.modified().unwrap())
    }

    fn live_with_a_change(
        tree: &TempTree,
        name: &str,
    ) -> (Arc<Engine>, Receiver<Event>, Arc<Unit>) {
        let (engine, rx) = start_on_build(tree, b'A');
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        fs::write(tree.0.join(name), b"").unwrap();
        until_found(&engine, &rx, "zyqflush", &[(name, &tree.real())]);
        let boot = engine.shared.units()[0].clone();
        let deadline = Instant::now() + Duration::from_secs(10);
        while boot.read(|l| l.event_id == l.base.event_id()).unwrap() {
            assert!(Instant::now() < deadline, "the change never moved the id");
            thread::sleep(Duration::from_millis(10));
        }
        (engine, rx, boot)
    }

    #[test]
    fn a_quit_saves_an_old_index_with_a_replayed_change_and_the_restart_replays_nothing_older() {
        let tree = TempTree::new("flush-old");
        let (engine, _rx, boot) = live_with_a_change(&tree, "zyqflush.txt");
        let file = saved_file(&tree);
        let root = PathBuf::from(tree.real());
        let applied = boot.read(|l| l.event_id).unwrap();
        assert!(Index::load(&file, root.clone()).unwrap().event_id() < applied);
        saved_long_ago(&file);
        engine.flush_opens().unwrap();
        let saved = Index::load(&file, root).unwrap();
        assert!(saved.event_id() >= applied, "the save kept the old id");
        assert!(
            saved.event_id() <= boot.read(|l| l.event_id).unwrap(),
            "a saved id moved past what was applied"
        );
        assert!((0..saved.entries()).any(|i| saved.hit(i as u32).name == "zyqflush.txt"));
        drop(boot);
        drop(engine);
        let (engine, rx) = start_on_build(&tree, b'A');
        phases(&rx);
        let boot = engine.shared.units()[0].clone();
        assert!(
            boot.watcher().since >= applied,
            "the restart replayed from before the quit's save"
        );
        assert!(engine.shared.crawls.lock().unwrap().is_empty());
        assert_eq!(count(&engine, &rx, "zyqflush"), 1);
    }

    #[test]
    fn a_quit_leaves_a_fresh_saved_index_untouched() {
        let tree = TempTree::new("flush-fresh");
        let (engine, _rx, _boot) = live_with_a_change(&tree, "zyqflush.txt");
        let file = saved_file(&tree);
        let mark = file_mark(&file);
        engine.flush_opens().unwrap();
        assert_eq!(
            file_mark(&file),
            mark,
            "a quit spent a save on a fresh file"
        );
    }

    #[test]
    fn a_quit_during_a_recovery_saves_nothing_until_it_ends() {
        let tree = TempTree::new("flush-recovery");
        let (engine, _rx, boot) = live_with_a_change(&tree, "zyqflush.txt");
        let file = saved_file(&tree);
        saved_long_ago(&file);
        let mark = file_mark(&file);
        boot.write(|l| l.recovery_from = Some(l.event_id));
        engine.flush_opens().unwrap();
        assert_eq!(file_mark(&file), mark, "a unit in recovery saved");
        boot.write(|l| l.recovery_from = None);
        engine.flush_opens().unwrap();
        assert_ne!(file_mark(&file), mark, "the check above proved nothing");
    }

    #[test]
    fn a_quit_during_a_pause_never_moves_the_saved_id_past_what_was_applied() {
        let tree = TempTree::new("flush-pause");
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        let boot = engine.shared.units()[0].clone();
        switched(&engine, false);
        let before = boot.read(|l| l.event_id).unwrap();
        fs::write(tree.0.join("zyqmissed.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        let file = saved_file(&tree);
        saved_long_ago(&file);
        engine.flush_opens().unwrap();
        let saved = Index::load(&file, PathBuf::from(tree.real())).unwrap();
        assert_eq!(saved.event_id(), before);
        drop(boot);
        drop(engine);
        let (engine, rx) = start_on_build(&tree, b'A');
        phases(&rx);
        until_found(
            &engine,
            &rx,
            "zyqmissed",
            &[("zyqmissed.txt", &tree.real())],
        );
    }

    #[test]
    fn a_quit_during_a_pause_keeps_the_count_the_screen_showed() {
        let tree = TempTree::new("flush-pause-count");
        let (engine, _rx, boot) = live_with_a_change(&tree, "zyqflush.txt");
        switched(&engine, false);
        let shown = boot.read(|l| l.entries()).unwrap();
        assert_eq!(shown, 7, "the change never reached the count");
        engine.flush_opens().unwrap();
        drop(boot);
        drop(engine);
        let (engine, rx) = start_config_on_build(paused_config(&tree), b'A');
        assert_eq!(
            phases(&rx),
            [(EnginePhase::Loading, 0), (EnginePhase::Ready, shown)],
            "the next paused start showed an older count than the quit"
        );
        assert_eq!(count(&engine, &rx, "zyqflush"), 1);
        assert!(engine.shared.crawls.lock().unwrap().is_empty());
    }

    #[test]
    fn a_failed_save_at_a_quit_raises_no_fault_and_returns() {
        let tree = TempTree::new("flush-readonly");
        let (engine, rx, _boot) = live_with_a_change(&tree, "zyqflush.txt");
        let file = saved_file(&tree);
        saved_long_ago(&file);
        let mark = file_mark(&file);
        {
            let _locked = Locked::new(vec![tree.data()]);
            engine.flush_opens().unwrap();
        }
        assert_eq!(file_mark(&file), mark);
        for event in rx.try_iter() {
            if let Event::Fault(message) = event {
                panic!("a quit's failed save raised a fault: {message}");
            }
        }
    }

    #[test]
    fn a_save_during_a_pause_keeps_the_old_id_and_the_next_start_replays_the_rest() {
        let tree = TempTree::new("pause-save");
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), CRAWLED);
        until_live(&rx);
        let boot = engine.shared.units()[0].clone();
        switched(&engine, false);
        let before = boot.read(|l| l.event_id).unwrap();
        fs::write(tree.0.join("zyqmissed.txt"), b"").unwrap();
        thread::sleep(PAST_LATENCY);
        apply::compact(&engine.shared, &boot);
        let saved = Index::load(&saved_file(&tree), PathBuf::from(tree.real())).unwrap();
        assert_eq!(
            saved.event_id(),
            before,
            "a save during the pause moved the id past what was applied"
        );
        drop(engine);
        let (engine, rx) = start_on_build(&tree, b'A');
        assert_eq!(phases(&rx), LOADED);
        until_found(
            &engine,
            &rx,
            "zyqmissed",
            &[("zyqmissed.txt", &tree.real())],
        );
        assert!(engine.shared.crawls.lock().unwrap().is_empty());
        assert_eq!(
            engine.shared.units()[0].relists.load(Ordering::Relaxed),
            0,
            "the next start relisted instead of replaying what the pause missed"
        );
    }

    #[test]
    fn a_new_excluded_path_during_a_pause_starts_no_stream_and_holds_after_resume() {
        let tree = TempTree::new("pause-excluded");
        write_all(&tree, &[("Late/zyqearly.txt", "")]);
        let (engine, rx) = outside(&tree);
        let root = tree.real();
        switched(&engine, false);
        engine.set_excluded(vec![format!("{root}/Late")]).unwrap();
        rebuilt(&engine);
        let boot = engine.shared.units()[0].clone();
        assert_eq!(
            boot.watcher().count,
            0,
            "the successor started a stream during the pause"
        );
        assert_eq!(
            boot.status().0,
            EnginePhase::Ready,
            "a successor reports Ready until resume brings its history to an end"
        );
        assert_eq!(count(&engine, &rx, "zyqearly"), 0);
        write_all(
            &tree,
            &[("Late/zyqskipped.txt", ""), ("Open/zyqkept.txt", "")],
        );
        switched(&engine, true);
        let open = format!("{root}/Open");
        seek(&engine, &rx, "zyqkept", &[("zyqkept.txt", &open)], false);
        assert_eq!(
            boot.watcher().count,
            1,
            "resume did not start the successor"
        );
        assert_eq!(
            count(&engine, &rx, "zyqskipped"),
            0,
            "the Excluded Paths row lost to a change made during the pause"
        );
    }

    #[test]
    fn a_removed_excluded_path_during_a_pause_crawls_with_no_stream_until_resume() {
        let tree = TempTree::new("pause-included");
        write_all(&tree, &[("Late/zyqback.txt", "")]);
        let root = tree.real();
        let late = format!("{root}/Late");
        let (engine, _listener, rx) = start_with(
            EngineConfig {
                excluded: vec![late.clone()],
                ..config(&tree)
            },
            None,
        );
        phases(&rx);
        until_live(&rx);
        assert_eq!(count(&engine, &rx, "zyqback"), 0);
        switched(&engine, false);
        engine.set_excluded(Vec::new()).unwrap();
        rebuilt(&engine);
        let boot = engine.shared.units()[0].clone();
        assert_eq!(
            boot.watcher().count,
            0,
            "the crawling successor started a stream during the pause"
        );
        assert_eq!(count(&engine, &rx, "zyqback"), 1);
        write_all(&tree, &[("Late/zyqafter.txt", "")]);
        thread::sleep(PAST_LATENCY);
        assert_eq!(count(&engine, &rx, "zyqafter"), 0);
        switched(&engine, true);
        seek(&engine, &rx, "zyqafter", &[("zyqafter.txt", &late)], false);
        assert_eq!(
            boot.watcher().count,
            1,
            "resume did not start the successor"
        );
    }

    #[test]
    fn a_nested_excluded_path_during_a_pause_folds_with_no_stream_until_resume() {
        let tree = TempTree::new("pause-fold");
        write_all(&tree, &[("Late/Inner/hidden.txt", "")]);
        let root = tree.real();
        let late = format!("{root}/Late");
        let (engine, _listener, rx) = start_with(
            EngineConfig {
                excluded: vec![late.clone()],
                ..config(&tree)
            },
            None,
        );
        phases(&rx);
        until_live(&rx);
        switched(&engine, false);
        engine
            .set_excluded(vec![late.clone(), format!("{late}/Inner")])
            .unwrap();
        rebuilt(&engine);
        let boot = engine.shared.units()[0].clone();
        assert_eq!(
            boot.watcher().count,
            0,
            "the folded successor started a stream during the pause"
        );
        write_all(&tree, &[("zyqfold.txt", "")]);
        thread::sleep(PAST_LATENCY);
        assert_eq!(count(&engine, &rx, "zyqfold"), 0);
        switched(&engine, true);
        seek(&engine, &rx, "zyqfold", &[("zyqfold.txt", &root)], false);
        assert_eq!(
            boot.watcher().count,
            1,
            "resume did not start the successor"
        );
    }

    #[test]
    fn an_excluded_folder_ignores_its_real_events() {
        let tree = TempTree::new("engine-live-excluded");
        let home = tree.0.join("home");
        for dir in ["Desktop", "Documents", "Other"] {
            fs::create_dir_all(home.join(dir)).unwrap();
        }
        let _locked = Locked::new(vec![home.join("Documents")]);
        let other = format!("{}/home/Other", tree.real());
        let mut config = config(&tree);
        config.excluded = ["Desktop", "Documents"]
            .map(|d| home.join(d).to_str().unwrap().to_owned())
            .to_vec();
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        until_live(&rx);
        fs::write(home.join("Desktop/new.txt"), b"").unwrap();
        fs::write(home.join("Other/marker.txt"), b"").unwrap();
        until_found(&engine, &rx, "marker", &[("marker.txt", &other)]);
        assert_eq!(count(&engine, &rx, "new.txt"), 0);
    }

    #[test]
    fn rows_of_a_held_generation_survive_a_change() {
        let tree = TempTree::new("engine-live-held");
        let root = tree.real();
        let (engine, _listener, rx) = start(&tree);
        let session = engine.clone().session().unwrap();
        phases(&rx);
        until_live(&rx);
        let g = session.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let rows = session.rows(g, 0, 3).unwrap();
        fs::remove_file(tree.0.join("beta.txt")).unwrap();
        changed(&rx);
        assert_eq!(session.rows(g, 0, 3).unwrap(), rows);
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        changed(&rx);
        assert_eq!(session.rows(g, 0, 100).unwrap(), rows);
        let sub = format!("{root}/Sub");
        let now = [
            ("Alpha.TXT", root.as_str()),
            ("DELTA.Txt", &sub),
            ("new.txt", &root),
        ];
        until_found(&engine, &rx, "txt", &now);
    }

    #[test]
    fn drop_while_events_arrive_joins_every_thread() {
        let tree = TempTree::new("engine-live-drop");
        let churn = tree.0.join("Churn");
        fs::create_dir(&churn).unwrap();
        let (engine, listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let busy = Arc::new(AtomicBool::new(true));
        let writer = thread::spawn({
            let busy = busy.clone();
            move || {
                for i in 0..100_000 {
                    if !busy.load(Ordering::Relaxed) {
                        return;
                    }
                    fs::write(churn.join(i.to_string()), b"").unwrap();
                }
            }
        });
        changed(&rx);
        drop(engine);
        assert_eq!(Arc::strong_count(&listener), 1);
        busy.store(false, Ordering::Relaxed);
        writer.join().unwrap();
    }

    #[test]
    fn a_release_on_the_apply_thread_never_waits_for_itself() {
        let tree = TempTree::new("engine-live-release");
        let (events, rx) = mpsc::channel();
        let (handoff, on_change) = mpsc::channel();
        let listener = Recorder::new(events, None);
        *listener.on_change.lock().unwrap() = Some(on_change);
        let engine = Engine::new(config(&tree), listener.clone()).unwrap();
        assert_eq!(phases(&rx), CRAWLED);
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        handoff.send(Some(engine)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while Arc::strong_count(&listener) > 1 {
            assert!(Instant::now() < deadline, "an engine thread never ended");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(rx.try_iter().any(|e| matches!(e, Event::Changed(1))));
    }

    #[test]
    fn a_compaction_merges_the_new_set_before_any_search() {
        use crate::sort::{Count, tallies};
        let tree = TempTree::new("engine-premerge");
        let disk_tree = TempTree::new("engine-premerge-disk");
        fs::write(disk_tree.0.join("carrot.txt"), b"").unwrap();
        let (shared, boot, _rx) = bench(config(&tree));
        let disk = Arc::new(Unit::new(
            PathBuf::from(disk_tree.real()),
            Some("premerge".to_owned()),
            disk_tree.data().join("volume-premerge.index"),
            (Vec::new(), b"print".to_vec()),
            Pool::new(2).unwrap(),
            mpsc::channel().0,
            Arc::default(),
        ));
        shared.units.write().unwrap().push(disk.clone());
        let crawl = crawl::scan_path(&disk.pool, &disk.root, &disk.skip, &disk.stop);
        let index = Index::build(crawl, disk.root.clone(), &disk.print, 1000, now_secs()).unwrap();
        disk.install(&shared, index, EnginePhase::Ready);
        let before = boot.read(|l| l.base.clone()).unwrap();
        let swap = thread::scope(|s| {
            s.spawn(|| {
                tallies();
                apply::compact(&shared, &boot);
                tallies()
            })
            .join()
            .unwrap()
        });
        let after = boot.read(|l| l.base.clone()).unwrap();
        assert!(
            !Arc::ptr_eq(&before, &after),
            "the compaction swapped the index"
        );
        assert_eq!(
            sort::held(&before),
            0,
            "orders kept over the replaced index"
        );
        drop(before);
        println!(
            "swap thread: orders built {}, merge compares {}",
            swap[Count::Built as usize],
            swap[Count::Merge as usize]
        );
        assert_eq!(swap[Count::Built as usize], 1, "orders the swap built");
        assert!(
            swap[Count::Merge as usize] > 0,
            "the swap merged both disks"
        );
        tallies();
        let results = scan(&shared, 1, "txt", BEST_MATCH, &|| false).unwrap();
        let searched = tallies();
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let sorted = results
            .sorted(2, by_name, &shared.opens, &|| false)
            .unwrap();
        let resorted = tallies();
        for (label, t) in [("first search", searched), ("first sort", resorted)] {
            let got = [t[Count::Built as usize], t[Count::Merge as usize]];
            println!("{label}: orders built, merge compares {got:?} (both 0)");
            assert_eq!(got, [0, 0], "{label}");
        }
        assert!(Arc::ptr_eq(&results.found[0].index, &after));
        assert_eq!(results.found.len(), 2);
        let names: Vec<String> = sorted
            .rows(0, usize::MAX)
            .into_iter()
            .map(|h| h.name)
            .collect();
        assert_eq!(
            names,
            [
                "Alpha.TXT",
                "Alpha.TXT",
                "beta.txt",
                "beta.txt",
                "carrot.txt",
                "DELTA.Txt",
                "DELTA.Txt"
            ]
        );
    }

    pub(crate) fn text_config(tree: &TempTree) -> EngineConfig {
        EngineConfig {
            home: tree.root(),
            ..config(tree)
        }
    }

    fn names_of(session: &EngineSession, generation: u64, count: u32) -> Vec<String> {
        let rows = session.rows(generation, 0, count).unwrap();
        let mut names: Vec<String> = rows.into_iter().map(|h| h.name).collect();
        names.sort();
        names
    }

    pub(crate) fn pressed(
        session: &EngineSession,
        rx: &Receiver<Event>,
        press: u64,
    ) -> (Vec<String>, u64, u64) {
        let mut last = None;
        loop {
            match next(rx) {
                Event::Ready(g, count) => last = Some((g, count)),
                Event::Progress(p, read, total, true) if p == press => {
                    let (g, count) = last.expect("done came before any results_ready");
                    return (names_of(session, g, count), read, total);
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    pub(crate) fn texts(engine: &Arc<Engine>, rx: &Receiver<Event>, query: &str) -> Vec<String> {
        let (mut terms, mut all, mut rest) = (Vec::new(), true, Vec::new());
        for word in query::split_words(query) {
            match word.split_once(':') {
                Some(("text", term)) => terms.push(term.to_owned()),
                Some(("anytext", term)) => {
                    all = false;
                    terms.push(term.to_owned());
                }
                _ => rest.push(word),
            }
        }
        let session = engine.clone().session().unwrap();
        let rest = rest.join(" ");
        if terms.is_empty() {
            let g = session.search(rest, BEST_MATCH).unwrap();
            let count = ready(rx, g);
            return names_of(&session, g, count);
        }
        let g = session
            .search_content(rest, terms, all, BEST_MATCH)
            .unwrap();
        pressed(&session, rx, g).0
    }

    fn write_all(tree: &TempTree, files: &[(&str, &str)]) {
        for (name, text) in files {
            let path = tree.0.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
    }

    const NONE: [&str; 0] = [];

    #[test]
    fn text_terms_find_files_by_what_they_hold() {
        let tree = TempTree::new("engine-text");
        write_all(
            &tree,
            &[
                ("a.txt", "Alpha beta"),
                ("b.txt", "alpha"),
                ("c.md", "BETA gamma"),
                ("d.txt", "gamma"),
                ("e.txt", "x == y"),
            ],
        );
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:alpha text:beta"), ["a.txt"]);
        assert_eq!(
            texts(&engine, &rx, "anytext:alpha anytext:beta"),
            ["a.txt", "b.txt", "c.md"]
        );
        assert_eq!(texts(&engine, &rx, "b"), ["Sub", "b.txt", "beta.txt"]);
        assert_eq!(texts(&engine, &rx, "b anytext:gamma"), NONE);
        assert_eq!(texts(&engine, &rx, "text:\"==\""), ["e.txt"]);
    }

    #[test]
    fn case_and_accents_fold() {
        let tree = TempTree::new("engine-text-case");
        write_all(
            &tree,
            &[
                ("f1.txt", "R\u{e9}sum\u{e9} \u{c9}COLE"),
                ("f2.txt", "resume ecole"),
            ],
        );
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(
            texts(&engine, &rx, "text:R\u{c9}SUM\u{c9}"),
            ["f1.txt", "f2.txt"]
        );
        assert_eq!(texts(&engine, &rx, "text:\u{e9}cole"), ["f1.txt", "f2.txt"]);
        assert_eq!(texts(&engine, &rx, "text:RESUME"), ["f1.txt", "f2.txt"]);
        assert_eq!(
            texts(&engine, &rx, "anytext:resume anytext:\u{e9}cole"),
            ["f1.txt", "f2.txt"]
        );
    }

    #[test]
    fn nfc_and_nfd_terms_both_match() {
        let tree = TempTree::new("engine-text-forms");
        write_all(
            &tree,
            &[
                ("n1.txt", "caf\u{e9} au lait"),
                ("n2.txt", "cafe\u{301} au lait"),
            ],
        );
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:caf\u{e9}"), ["n1.txt", "n2.txt"]);
        assert_eq!(
            texts(&engine, &rx, "text:cafe\u{301}"),
            ["n1.txt", "n2.txt"]
        );
        assert_eq!(
            texts(&engine, &rx, "text:\"caf\u{c9} au\""),
            ["n1.txt", "n2.txt"]
        );
    }

    fn outside(tree: &TempTree) -> (Arc<Engine>, Receiver<Event>) {
        let (engine, _listener, rx) = start(tree);
        phases(&rx);
        until_live(&rx);
        (engine, rx)
    }

    fn opened(engine: &Engine) -> Vec<PathBuf> {
        engine.shared.reads.lock().unwrap().clone()
    }

    fn skipped(
        tree: &TempTree,
        dataless: &[&str],
    ) -> (Vec<String>, u64, u64, (u64, u64), Vec<PathBuf>) {
        let real = PathBuf::from(tree.real());
        (crate::text::scope::tests::DATALESS.lock().unwrap())
            .extend(dataless.iter().map(|n| real.join(n)));
        let (engine, listener, rx) = start(tree);
        phases(&rx);
        until_live(&rx);
        let session = engine.clone().session().unwrap();
        let g = press(&session, &format!("in:{}/t", tree.real()), "zyq");
        let (names, read, total) = pressed(&session, &rx, g);
        let skips = listener.skips.lock().unwrap();
        let &(_, not_downloaded, unreadable) = skips.iter().rev().find(|s| s.0 == g).unwrap();
        (
            names,
            read,
            total,
            (not_downloaded, unreadable),
            opened(&engine),
        )
    }

    #[test]
    fn a_dataless_file_is_skipped_not_lacking() {
        let tree = TempTree::new("engine-dataless");
        write_all(
            &tree,
            &[
                ("t/a.txt", "zyq"),
                ("t/cloud.txt", "zyq"),
                ("t/cloud.rtf", "{\\rtf1 zyq}"),
            ],
        );
        let (names, read, total, skips, opened) = skipped(&tree, &["t/cloud.txt", "t/cloud.rtf"]);
        assert_eq!(names, ["a.txt"]);
        assert_eq!((read, total, skips), (1, 3, (2, 0)));
        assert!(
            !opened
                .iter()
                .any(|p| p.file_stem() == Some(std::ffi::OsStr::new("cloud"))),
            "a placeholder was opened: {opened:?}"
        );
    }

    #[test]
    fn an_epub_is_counted_as_unreadable() {
        let tree = TempTree::new("engine-unreadable");
        write_all(
            &tree,
            &[
                ("t/a.txt", "zyq"),
                ("t/server.key", "-----BEGIN PRIVATE KEY-----\nzyq\n"),
            ],
        );
        for name in ["book.epub", "Plan.PAGES", "blob.bin"] {
            fs::write(tree.0.join("t").join(name), b"PK\x03\x04\x14\0\0\0zyq").unwrap();
        }
        let (names, read, total, skips, _) = skipped(&tree, &[]);
        assert_eq!(names, ["a.txt", "server.key"]);
        assert_eq!((read, total, skips), (3, 5, (0, 2)));
    }

    #[test]
    fn a_press_with_skips_ends_done() {
        let tree = TempTree::new("engine-skips-done");
        write_all(&tree, &[("t/a.txt", "zyq"), ("t/cloud.txt", "zyq")]);
        fs::write(tree.0.join("t/book.epub"), b"PK\x03\x04\0zyq").unwrap();
        let (names, read, total, (not_downloaded, unreadable), _) =
            skipped(&tree, &["t/cloud.txt"]);
        assert_eq!(names, ["a.txt"]);
        assert_eq!((read, not_downloaded, unreadable), (1, 1, 1));
        assert_eq!(read + not_downloaded + unreadable, total);
    }

    #[test]
    fn a_relative_folder_reads_nothing() {
        let tree = TempTree::new("engine-text-relative");
        write_all(&tree, &[("docs/a.txt", "alpha"), ("b.txt", "alpha")]);
        let (engine, rx) = outside(&tree);
        let before = opened(&engine).len();
        for scope in [
            ".", "..", ",", ";", "=", "<", ">", "docs", "docs/", "../docs", "./docs",
        ] {
            assert_eq!(
                texts(&engine, &rx, &format!("text:alpha in:{scope}")),
                Vec::<String>::new(),
                "{scope}"
            );
        }
        assert_eq!(
            opened(&engine).len(),
            before,
            "a relative folder opened a file"
        );
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            ["a.txt", "b.txt"],
            "with no folder the press still reads every file"
        );
    }

    #[test]
    fn the_file_name_limits_the_read_inside_its_folder() {
        let tree = TempTree::new("engine-text-name-in");
        write_all(
            &tree,
            &[
                ("in/report-a.txt", "alpha"),
                ("in/report-b.txt", "beta"),
                ("in/other.txt", "alpha"),
                ("out/report-c.txt", "alpha"),
            ],
        );
        let root = tree.real();
        let (engine, rx) = outside(&tree);
        let before = opened(&engine).len();
        assert_eq!(
            texts(&engine, &rx, &format!("'report text:alpha in:{root}/in")),
            ["report-a.txt"]
        );
        let mut names: Vec<String> = opened(&engine)[before..]
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["report-a.txt", "report-b.txt"]);
    }

    #[test]
    fn a_folder_reads_as_the_box_writes_it() {
        let tree = TempTree::new("engine-text-forms");
        write_all(&tree, &[("Sub/s.txt", "alpha"), ("Other/o.txt", "alpha")]);
        let root = tree.real();
        let (engine, rx) = outside(&tree);
        for scope in [format!("{root}/Sub/"), format!("{root}/Other/../Sub")] {
            assert_eq!(
                texts(&engine, &rx, &format!("text:alpha in:{scope}")),
                ["s.txt"],
                "{scope}"
            );
        }
        for scope in [
            "Sub".to_owned(),
            "Sub/".to_owned(),
            format!("{root}/missing"),
            format!("{root}/Sub/s.txt"),
        ] {
            assert_eq!(
                texts(&engine, &rx, &format!("text:alpha in:{scope}")),
                Vec::<String>::new(),
                "{scope}"
            );
        }
    }

    #[test]
    fn a_press_loosens_only_when_the_name_list_would() {
        let tree = TempTree::new("engine-text-typo");
        write_all(
            &tree,
            &[
                ("Clean/report/inner.txt", "alpha"),
                ("Clean/reprot.txt", "alpha"),
                ("Typo/reprot.txt", "alpha"),
            ],
        );
        let root = tree.real();
        let (engine, rx) = outside(&tree);
        engine.set_typos(true).unwrap();

        let listed = texts(&engine, &rx, &format!("report in:{root}/Clean"));
        assert!(listed.contains(&"report".to_owned()), "{listed:?}");
        assert!(!listed.contains(&"reprot.txt".to_owned()), "{listed:?}");
        let before = opened(&engine).len();
        assert_eq!(
            texts(&engine, &rx, &format!("report text:alpha in:{root}/Clean")),
            Vec::<String>::new(),
            "the press read a typo the name list never showed"
        );
        assert_eq!(opened(&engine).len(), before);

        assert_eq!(
            texts(&engine, &rx, &format!("report in:{root}/Typo")),
            ["reprot.txt"]
        );
        assert_eq!(
            texts(&engine, &rx, &format!("report text:alpha in:{root}/Typo")),
            ["reprot.txt"],
            "where the name list loosens the press loosens with it"
        );

        engine.set_typos(false).unwrap();
        assert_eq!(
            texts(&engine, &rx, &format!("report text:alpha in:{root}/Typo")),
            Vec::<String>::new()
        );
    }

    #[test]
    fn in_limits_a_press_to_its_folder() {
        let tree = TempTree::new("engine-text-in");
        let root = tree.real();
        write_all(
            &tree,
            &[
                ("home/h.txt", "alpha"),
                ("top.txt", "alpha"),
                ("Sub/s.txt", "alpha"),
            ],
        );
        let (engine, rx) = outside(&tree);
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{root}")),
            ["h.txt", "s.txt", "top.txt"]
        );
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{root}/home")),
            ["h.txt"]
        );
        let before = opened(&engine).len();
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{root}/Sub")),
            ["s.txt"]
        );
        assert_eq!(opened(&engine).len() - before, 2);
    }

    const DISK: &str = "0A0A0A0A-0000-4000-8000-0000000000D1";

    fn with_disk(name: &str) -> (TempTree, TempTree, Arc<Engine>, Receiver<Event>) {
        let tree = TempTree::new(name);
        write_all(&tree, &[("home/h.txt", "alpha"), ("top.txt", "alpha")]);
        let disk = TempTree::new(&format!("{name}-disk"));
        write_all(&disk, &[("d.txt", "alpha"), ("Sub/e.txt", "alpha")]);
        let (engine, rx) = outside(&tree);
        let volume = EngineVolume {
            root: disk.real(),
            id: DISK.to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.shared.units().len() < 2
            || engine
                .shared
                .units()
                .iter()
                .any(|u| !matches!(u.status().0, EnginePhase::Ready | EnginePhase::Live))
        {
            assert!(
                Instant::now() < deadline,
                "the disk never finished its crawl"
            );
            thread::sleep(Duration::from_millis(10));
        }
        (tree, disk, engine, rx)
    }

    #[test]
    fn set_volumes_reads_no_disk() {
        let tree = TempTree::new("vol-nodisk");
        let (engine, listener, rx) = start(&tree);
        phases(&rx);
        let relative = EngineVolume {
            root: "Volumes/Disk".to_owned(),
            id: DISK.to_owned(),
        };
        assert!(matches!(
            engine.set_volumes(vec![relative]),
            Err(EngineError::Io { .. })
        ));
        let missing = format!("{}-missing", tree.real());
        engine
            .set_volumes(vec![EngineVolume {
                root: missing.clone(),
                id: DISK.to_owned(),
            }])
            .unwrap();
        let message = loop {
            if let Event::Fault(message) = next(&rx) {
                break message;
            }
        };
        assert_eq!(
            message,
            format!("{missing}: not a folder, so it is not indexed")
        );
        let faulted = listener.faulted.lock().unwrap().clone();
        assert_eq!(faulted.len(), 1);
        assert_ne!(faulted[0], thread::current().id());
        assert_eq!(engine.shared.units().len(), 1);
    }

    #[test]
    fn ejecting_a_disk_cancels_its_index_build_before_joining() {
        let delay = Duration::from_millis(25);
        let budget = 8;
        for compact in [false, true] {
            let tree = TempTree::new("engine-build-eject");
            let disk_tree = TempTree::new("engine-build-eject-disk");
            for i in 0..64 {
                fs::create_dir(disk_tree.0.join(format!("Folder{i}"))).unwrap();
            }
            let (engine, listener, rx) = start(&tree);
            phases(&rx);
            until_live(&rx);
            let root = PathBuf::from(disk_tree.real());
            let disk = Arc::new(Unit::new(
                root.clone(),
                Some(DISK.to_owned()),
                tree.data().join(format!("volume-{DISK}.index")),
                unit::inputs(&engine.shared.settings, DISK, &root),
                Pool::new(2).unwrap(),
                mpsc::channel().0,
                Arc::default(),
            ));
            let crawl = crawl::scan_path(&disk.pool, &disk.root, &disk.skip, &disk.stop);
            let listings = crawl.listings.len();
            assert!(listings > budget * 4);
            let base = if compact {
                let index = Index::build(
                    Crawl {
                        listings: crawl.listings.clone(),
                        failed: crawl.failed.clone(),
                    },
                    root,
                    &disk.print,
                    1000,
                    now_secs(),
                )
                .unwrap();
                disk.install(&engine.shared, index, EnginePhase::Ready);
                disk.read(|l| l.base.clone())
            } else {
                None
            };
            engine.shared.units.write().unwrap().push(disk.clone());
            let (reached, listing) = mpsc::channel();
            let worker = thread::spawn({
                let (shared, disk) = (engine.shared.clone(), disk.clone());
                move || {
                    index::BUILD_DELAY.set(Some((delay, reached)));
                    if compact {
                        apply::compact(&shared, &disk);
                    } else if let Some(index) = unit::build(&shared, &disk, crawl, 1000, now_secs())
                    {
                        disk.install(&shared, index, EnginePhase::Ready);
                    }
                }
            });
            *disk.thread.lock().unwrap() = Some(worker);
            listing.recv_timeout(Duration::from_secs(10)).unwrap();
            let elapsed = thread::spawn({
                let engine = engine.clone();
                move || {
                    let began = Instant::now();
                    engine.set_volumes(Vec::new()).unwrap();
                    began.elapsed()
                }
            })
            .join()
            .unwrap();
            let processed = 1 + listing.try_iter().count();
            assert!(
                elapsed < delay * budget as u32,
                "compact={compact}: {elapsed:?}"
            );
            assert!(
                processed <= budget,
                "processed {processed} of {listings} listings"
            );
            assert!(disk.stopped());
            assert!(disk.thread.lock().unwrap().is_none());
            assert!(engine.shared.units().iter().all(|u| u.id.is_none()));
            match base {
                Some(base) => assert!(disk.read(|l| Arc::ptr_eq(&base, &l.base)).unwrap()),
                None => assert!(disk.read(|_| ()).is_none()),
            }
            assert!(!disk.file.exists());
            assert!(index::temps(&disk.file).is_empty());
            assert!(listener.faulted.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn set_volumes_finishes_while_a_search_is_scanning() {
        let tree = TempTree::new("engine-units-unlocked");
        let (engine, _rx) = outside(&tree);
        let finished = Mutex::new(None);
        let cancelled = || {
            let mut finished = finished.lock().unwrap();
            if finished.is_none() {
                let (done, ended) = mpsc::channel();
                let engine = engine.clone();
                thread::spawn(move || {
                    let _ = done.send(engine.set_volumes(Vec::new()));
                });
                let waited = ended.recv_timeout(Duration::from_secs(5));
                *finished = Some(matches!(waited, Ok(Ok(()))));
            }
            false
        };
        assert!(scan(&engine.shared, 1, "txt", BEST_MATCH, &cancelled).is_some());
        assert_eq!(
            *finished.lock().unwrap(),
            Some(true),
            "set_volumes waited on the search"
        );
    }

    #[test]
    fn a_disk_folder_reads_text() {
        let (_tree, disk, engine, rx) = with_disk("engine-text-disk");
        let d = disk.real();
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{d}")),
            ["d.txt", "e.txt"]
        );
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{d}/Sub")),
            ["e.txt"]
        );
    }

    #[test]
    fn an_empty_search_folder_reads_every_disk() {
        let (_tree, _disk, engine, rx) = with_disk("engine-text-alldisks");
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            ["d.txt", "e.txt", "h.txt", "top.txt"]
        );
    }

    #[test]
    fn formerly_skipped_folders_are_read() {
        use std::ffi::CString;
        let tree = TempTree::new("engine-text-skipped");
        write_all(
            &tree,
            &[
                ("node_modules/pkg/x.txt", "alpha"),
                (".git/y.txt", "alpha"),
                ("Library/l.txt", "alpha"),
                ("Foo.app/Contents/z.txt", "alpha"),
                (".dot/d.txt", "alpha"),
                ("home/go/pkg/g.go", "alpha"),
                ("Work/target/CACHEDIR.TAG", "alpha"),
                ("Work/target/t.rs", "alpha"),
                ("flagged/f.txt", "alpha"),
            ],
        );
        let flagged = CString::new(tree.0.join("flagged").as_os_str().as_bytes()).unwrap();
        assert_eq!(
            unsafe { libc::chflags(flagged.as_ptr(), libc::UF_HIDDEN) },
            0
        );
        let (engine, rx) = outside(&tree);
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            [
                "CACHEDIR.TAG",
                "d.txt",
                "f.txt",
                "g.go",
                "l.txt",
                "t.rs",
                "x.txt",
                "y.txt",
                "z.txt"
            ]
        );
    }

    #[test]
    fn an_overlay_file_is_read() {
        let tree = TempTree::new("engine-text-overlay");
        let root = tree.real();
        write_all(&tree, &[("home/h.txt", "alpha")]);
        let (engine, rx) = outside(&tree);
        write_all(
            &tree,
            &[
                ("Out/new.txt", "alpha"),
                ("Out/node_modules/dep.txt", "alpha"),
            ],
        );
        let out = format!("{root}/Out");
        seek(&engine, &rx, "new.txt", &[("new.txt", &out)], true);
        let deps = format!("{out}/node_modules");
        seek(&engine, &rx, "dep.txt", &[("dep.txt", &deps)], true);
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{out}")),
            ["dep.txt", "new.txt"]
        );
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            ["dep.txt", "h.txt", "new.txt"]
        );
    }

    #[test]
    fn the_file_name_limits_the_read() {
        let tree = TempTree::new("engine-text-name");
        write_all(
            &tree,
            &[
                ("report-a.txt", "alpha"),
                ("report-b.txt", "beta"),
                ("other.txt", "alpha"),
            ],
        );
        let (engine, rx) = outside(&tree);
        let before = opened(&engine).len();
        assert_eq!(texts(&engine, &rx, "'report text:alpha"), ["report-a.txt"]);
        let names: Vec<String> = opened(&engine)[before..]
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        let mut names = names;
        names.sort();
        assert_eq!(names, ["report-a.txt", "report-b.txt"]);
    }

    #[test]
    fn an_empty_name_query_reads_every_file_in_scope() {
        let tree = TempTree::new("engine-text-empty");
        write_all(&tree, &[("home/a.txt", "zyq"), ("home/b.md", "zyq")]);
        let (engine, rx) = outside(&tree);
        let session = engine.clone().session().unwrap();
        let g = session
            .search_content(String::new(), vec!["zyq".to_owned()], true, BEST_MATCH)
            .unwrap();
        assert_eq!(
            pressed(&session, &rx, g),
            (vec!["a.txt".to_owned(), "b.md".to_owned()], 6, 6)
        );
        assert_eq!(opened(&engine).len(), 6);
    }

    #[test]
    fn a_text_word_reads_no_file() {
        let tree = TempTree::new("engine-text-word");
        write_all(&tree, &[("z.txt", "zyq")]);
        let (engine, rx) = outside(&tree);
        let session = engine.clone().session().unwrap();
        let g = session.search("text:zyq".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 0);
        assert!(opened(&engine).is_empty());
    }

    #[test]
    fn a_press_with_no_term_fails_and_reads_nothing() {
        let tree = TempTree::new("engine-text-noterm");
        let (engine, rx) = outside(&tree);
        let session = engine.clone().session().unwrap();
        let got = session.search_content(String::new(), vec![" ".to_owned()], true, BEST_MATCH);
        assert!(matches!(got, Err(EngineError::Io { .. })));
        let g = session.narrow(String::new(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 0);
        assert!(opened(&engine).is_empty());
    }

    fn press_on(
        name: &str,
        query: &str,
    ) -> (
        TempTree,
        Arc<Engine>,
        Receiver<Event>,
        Arc<EngineSession>,
        u64,
    ) {
        let tree = TempTree::new(name);
        write_all(
            &tree,
            &[("a.txt", "zyq"), ("b.txt", "zyq"), ("c.txt", "other")],
        );
        let (engine, rx) = outside(&tree);
        let session = engine.clone().session().unwrap();
        let g = session
            .search_content(query.to_owned(), vec!["zyq".to_owned()], true, BEST_MATCH)
            .unwrap();
        (tree, engine, rx, session, g)
    }

    fn narrowed(session: &EngineSession, rx: &Receiver<Event>, query: &str) -> Vec<String> {
        let g = session.narrow(query.to_owned(), BEST_MATCH).unwrap();
        let count = ready(rx, g);
        names_of(session, g, count)
    }

    #[test]
    fn a_narrow_after_a_press_reads_no_file() {
        let (_tree, engine, rx, session, g) = press_on("engine-narrow", "");
        assert_eq!(pressed(&session, &rx, g).0, ["a.txt", "b.txt"]);
        let read = opened(&engine).len();
        assert_eq!(narrowed(&session, &rx, "a"), ["a.txt"]);
        assert_eq!(narrowed(&session, &rx, "kind:file"), ["a.txt", "b.txt"]);
        assert_eq!(opened(&engine).len(), read);
    }

    #[test]
    fn an_empty_narrow_answers_the_whole_set() {
        let (_tree, engine, rx, session, g) = press_on("engine-narrow-empty", "");
        pressed(&session, &rx, g);
        let read = opened(&engine).len();
        assert_eq!(narrowed(&session, &rx, "a"), ["a.txt"]);
        assert_eq!(narrowed(&session, &rx, ""), ["a.txt", "b.txt"]);
        assert_eq!(opened(&engine).len(), read);
    }

    #[test]
    fn clearing_the_name_shows_the_whole_press_set() {
        let (_tree, engine, rx, session, g) = press_on("engine-narrow-clear", "^a.");
        assert_eq!(pressed(&session, &rx, g), (vec!["a.txt".to_owned()], 1, 1));
        assert_eq!(narrowed(&session, &rx, ""), ["a.txt"]);
        assert_eq!(opened(&engine).len(), 1);
    }

    #[test]
    fn a_sort_after_a_press_reads_no_file() {
        let (_tree, engine, rx, session, g) = press_on("engine-narrow-sort", "");
        pressed(&session, &rx, g);
        let read = opened(&engine).len();
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: false,
            folders_first: false,
        };
        let sorted = session.sort(by_name).unwrap();
        let count = ready(&rx, sorted);
        let rows: Vec<String> = (session.rows(sorted, 0, count).unwrap())
            .into_iter()
            .map(|h| h.name)
            .collect();
        assert_eq!(rows, ["b.txt", "a.txt"]);
        assert_eq!(opened(&engine).len(), read);
    }

    #[test]
    fn a_file_change_after_a_press_reads_nothing_and_keeps_the_rows() {
        let (tree, engine, rx, session, g) = press_on("engine-narrow-change", "");
        pressed(&session, &rx, g);
        let read = opened(&engine).len();
        fs::remove_file(tree.0.join("a.txt")).unwrap();
        fs::write(tree.0.join("d.txt"), "zyq").unwrap();
        changed(&rx);
        assert_eq!(narrowed(&session, &rx, ""), ["a.txt", "b.txt"]);
        assert_eq!(opened(&engine).len(), read);
    }

    #[test]
    fn a_narrow_with_no_press_answers_no_rows() {
        let tree = TempTree::new("engine-narrow-none");
        let (engine, rx) = outside(&tree);
        let session = engine.clone().session().unwrap();
        assert_eq!(narrowed(&session, &rx, "alpha"), NONE);
        let g = session.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(narrowed(&session, &rx, "alpha"), NONE);
    }

    fn needles(name: &str, n: usize) -> (TempTree, String, Arc<Engine>, Receiver<Event>) {
        let tree = TempTree::new(name);
        fs::create_dir_all(tree.0.join("Out")).unwrap();
        for i in 0..n {
            fs::write(tree.0.join(format!("Out/zz{i:03}.txt")), "needle").unwrap();
        }
        let out = format!("{}/Out", tree.real());
        let (engine, rx) = outside(&tree);
        (tree, out, engine, rx)
    }

    fn hold_reads(shared: &Shared) -> (Receiver<PathBuf>, std::sync::RwLockWriteGuard<'_, ()>) {
        let (tx, reached) = mpsc::sync_channel(1024);
        *shared.read_reached.lock().unwrap() = Some(tx);
        (reached, shared.read_gate.write().unwrap())
    }

    fn inside(reached: &Receiver<PathBuf>, n: usize) -> Vec<PathBuf> {
        (0..n)
            .map(|_| reached.recv_timeout(Duration::from_secs(10)).unwrap())
            .collect()
    }

    fn press(session: &EngineSession, query: &str, term: &str) -> u64 {
        let terms = vec![term.to_owned()];
        (session.search_content(query.to_owned(), terms, true, BEST_MATCH)).unwrap()
    }

    fn begun(rx: &Receiver<Event>, press: u64) {
        loop {
            match next(rx) {
                Event::Progress(p, 0, _, false) if p == press => return,
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn quiet(rx: &Receiver<Event>, press: u64, generation: u64, wait: Duration) {
        let deadline = Instant::now() + wait;
        while let Ok(e) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            match e {
                Event::Progress(p, ..) if p == press => panic!("{e:?}"),
                Event::Ready(g, _) if g == generation => panic!("{e:?}"),
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    #[test]
    fn another_session_searches_while_a_read_runs() {
        let (_tree, out, engine, rx) = needles("engine-read-apart", 20);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        inside(&reached, 1);
        let b = engine.clone().session().unwrap();
        let other = b.search("'zz000".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, other), 1);
        drop(gate);
        let (names, read, total) = pressed(&a, &rx, g);
        assert_eq!((names.len(), read, total), (20, 20, 20));
    }

    #[test]
    fn a_narrow_during_a_held_read_answers_and_the_read_goes_on() {
        let (_tree, out, engine, rx) = needles("engine-read-narrow", 20);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        inside(&reached, READERS);
        let n = a.narrow("^zz00".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, n), 0);
        drop(gate);
        let (names, read, total) = pressed(&a, &rx, g);
        let want: Vec<String> = (0..10).map(|i| format!("zz{i:03}.txt")).collect();
        assert_eq!((names, read, total), (want, 20, 20));
    }

    #[test]
    fn stop_content_ends_the_read_and_keeps_its_verdicts() {
        let (_tree, out, engine, rx) = needles("engine-read-stop", 20);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        let held = inside(&reached, READERS);
        a.stop_content().unwrap();
        drop(gate);
        let (names, read, total) = pressed(&a, &rx, g);
        assert_eq!((read, total), (READERS as u64, 20));
        let mut want: Vec<String> = (held.iter())
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        want.sort();
        assert_eq!(names, want);
        assert_eq!(opened(&engine).len(), READERS);
    }

    #[test]
    fn a_stop_mid_file_leaves_it_unread() {
        let tree = TempTree::new("engine-read-midfile");
        let mut big = b"lorem\n".repeat((3 << 20) / 6);
        big.extend_from_slice(b"needle\n");
        fs::create_dir_all(tree.0.join("Out")).unwrap();
        fs::write(tree.0.join("Out/big.log"), &big).unwrap();
        let out = format!("{}/Out", tree.real());
        let (engine, rx) = outside(&tree);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        inside(&reached, 1);
        a.stop_content().unwrap();
        drop(gate);
        assert_eq!(pressed(&a, &rx, g), (Vec::<String>::new(), 0, 1));
        assert_eq!(opened(&engine).len(), 1);
    }

    #[test]
    fn a_name_search_drops_the_content_set_and_stops_its_read() {
        let (_tree, out, engine, rx) = needles("engine-read-search", 20);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        inside(&reached, READERS);
        let s = a.search("'zz000".to_owned(), BEST_MATCH).unwrap();
        drop(gate);
        assert_eq!(ready(&rx, s), 1);
        quiet(&rx, g, g, Duration::from_millis(300));
        assert_eq!(opened(&engine).len(), READERS);
        assert_eq!(narrowed(&a, &rx, ""), NONE);
    }

    #[test]
    fn dropping_the_session_stops_its_read() {
        let (_tree, out, engine, rx) = needles("engine-read-close", 20);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        inside(&reached, READERS);
        begun(&rx, g);
        drop(a);
        drop(gate);
        quiet(&rx, g, g, Duration::from_millis(500));
        assert_eq!(opened(&engine).len(), READERS);
    }

    #[test]
    fn dropping_the_engine_mid_read_joins_its_reader() {
        let tree = TempTree::new("engine-read-quit");
        fs::create_dir_all(tree.0.join("Out")).unwrap();
        for i in 0..20 {
            fs::write(tree.0.join(format!("Out/zz{i:03}.txt")), "needle").unwrap();
        }
        let (engine, listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let shared = engine.shared.clone();
        let (reached, gate) = hold_reads(&shared);
        let a = engine.clone().session().unwrap();
        press(&a, "", "needle");
        inside(&reached, READERS);
        drop(a);
        let quit = thread::spawn(move || drop(engine));
        thread::sleep(Duration::from_millis(200));
        assert!(!quit.is_finished(), "Drop returned with a reader in a file");
        drop(gate);
        quit.join().unwrap();
        drop(shared);
        assert_eq!(Arc::strong_count(&listener), 1);
    }

    #[test]
    fn a_path_excluded_mid_read_is_not_opened() {
        let tree = TempTree::new("engine-read-exclude");
        let root = tree.real();
        for i in 0..6 {
            write_all(&tree, &[(&format!("Out/a{i}.txt"), "needle")]);
            write_all(&tree, &[(&format!("Late/z{i}.txt"), "needle")]);
        }
        let (engine, rx) = outside(&tree);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let terms = vec!["needle".to_owned()];
        let g = a
            .search_content(String::new(), terms, true, by_name)
            .unwrap();
        inside(&reached, READERS);
        let late = format!("{root}/Late");
        engine.set_excluded(vec![late.clone()]).unwrap();
        drop(gate);
        let (names, ..) = pressed(&a, &rx, g);
        let want: Vec<String> = (0..6).map(|i| format!("a{i}.txt")).collect();
        assert_eq!(names, want);
        assert!(!opened(&engine).iter().any(|p| p.starts_with(&late)));
    }

    #[test]
    fn a_missing_excluded_path_is_kept_and_skips_a_later_folder() {
        let tree = TempTree::new("engine-missing-excluded");
        let root = tree.real();
        let (engine, rx) = outside(&tree);
        let later = format!("{root}/Later");
        engine.set_excluded(vec![later.clone()]).unwrap();
        rebuilt(&engine);
        assert_eq!(
            engine.shared.settings.exclusions().excluded,
            [PathBuf::from(&later)]
        );
        write_all(
            &tree,
            &[("Later/zyqskipped.txt", "zyq"), ("Open/zyqkept.txt", "zyq")],
        );
        let open = format!("{root}/Open");
        seek(&engine, &rx, "zyqkept", &[("zyqkept.txt", &open)], false);
        assert_eq!(count(&engine, &rx, "zyqskipped"), 0);
        assert_eq!(texts(&engine, &rx, "text:zyq"), ["zyqkept.txt"]);
    }

    #[test]
    fn ejecting_a_disk_mid_read_closes_its_files() {
        let (_tree, disk, engine, rx) = with_disk("engine-read-eject");
        let d = disk.real();
        let mut want = Vec::new();
        for i in 0..12 {
            write_all(&disk, &[(&format!("dz{i:02}.txt"), "alpha")]);
            want.push((format!("dz{i:02}.txt"), d.clone()));
        }
        let want: Vec<(&str, &str)> = want.iter().map(|(n, f)| (n.as_str(), f.as_str())).collect();
        seek(&engine, &rx, "^dz", &want, false);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{d}"), "alpha");
        let held = inside(&reached, READERS);
        let eject = thread::spawn({
            let engine = engine.clone();
            move || engine.set_volumes(Vec::new()).unwrap()
        });
        thread::sleep(Duration::from_millis(200));
        assert!(
            !eject.is_finished(),
            "set_volumes returned with a file open"
        );
        drop(gate);
        eject.join().unwrap();
        pressed(&a, &rx, g);
        for p in opened(&engine).iter().filter(|p| p.starts_with(&d)) {
            assert!(held.contains(p), "{p:?} opened after its disk went");
        }
    }

    #[test]
    fn ejecting_a_disk_never_waits_on_another_disks_file() {
        let (tree, _disk, engine, rx) = with_disk("engine-read-eject-other");
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}/home", tree.real()), "alpha");
        inside(&reached, 1);
        let eject = thread::spawn({
            let engine = engine.clone();
            move || engine.set_volumes(Vec::new()).unwrap()
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !eject.is_finished() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            eject.is_finished(),
            "set_volumes waited on a file of another disk"
        );
        drop(gate);
        eject.join().unwrap();
        assert_eq!(pressed(&a, &rx, g), (vec!["h.txt".to_owned()], 1, 1));
    }

    #[test]
    fn an_untouched_read_only_appends_rows() {
        let (_tree, out, engine, rx) = needles("engine-read-append", 40);
        let (tx, reached) = mpsc::sync_channel(0);
        *engine.shared.read_reached.lock().unwrap() = Some(tx);
        let feeder = thread::spawn(move || {
            while reached.recv_timeout(Duration::from_secs(2)).is_ok() {
                thread::sleep(Duration::from_millis(10));
            }
        });
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        let (mut last, mut counts) = (Vec::new(), Vec::new());
        loop {
            match next(&rx) {
                Event::Ready(r, count) if r == g => {
                    let rows: Vec<String> = (a.rows(g, 0, 100).unwrap())
                        .into_iter()
                        .map(|h| h.name)
                        .collect();
                    assert!(rows.starts_with(&last), "{last:?} then {rows:?}");
                    last = rows;
                    counts.push(count);
                }
                Event::Progress(p, _, _, true) if p == g => break,
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        counts.dedup();
        assert!(counts.len() >= 3, "{counts:?}");
        assert_eq!(last.len(), 40);
        drop(engine.shared.read_reached.lock().unwrap().take());
        feeder.join().unwrap();
    }

    #[test]
    fn a_slow_file_holds_back_later_rows_for_a_moment_only() {
        let (_tree, out, engine, rx) = needles("engine-read-slow", 40);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        let (once, read, total) = pressed(&a, &rx, g);
        assert_eq!((once.len(), read, total), (40, 40, 40));
        let slow = once[3].clone();
        let (release, held) = mpsc::channel();
        *engine.shared.read_hold.lock().unwrap() = Some((PathBuf::from(&out).join(&slow), held));
        let g = press(&a, &format!("in:{out}"), "needle");
        let streamed = loop {
            match next(&rx) {
                Event::Ready(r, 39) if r == g => {
                    break names_of(&a, g, 39);
                }
                Event::Progress(p, _, _, true) if p == g => {
                    panic!("the press ended before the slow file was let go")
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        };
        let others: Vec<String> = once.iter().filter(|n| **n != slow).cloned().collect();
        assert_eq!(streamed, others);
        release.send(()).unwrap();
        assert_eq!(pressed(&a, &rx, g), (once, 40, 40));
    }

    fn beside(name: &str) -> (TempTree, TempTree, Arc<Engine>, Receiver<Event>) {
        let tree = TempTree::new(name);
        let other = TempTree::new(&format!("{name}-beside"));
        write_all(
            &other,
            &[("o.txt", "zyq"), ("Deep/p.txt", "zyq"), ("q.txt", "other")],
        );
        let (engine, rx) = outside(&tree);
        (tree, other, engine, rx)
    }

    fn crawls(engine: &Engine) -> Vec<PathBuf> {
        engine.shared.crawls.lock().unwrap().clone()
    }

    #[test]
    fn a_folder_no_index_holds_is_walked_and_read() {
        let (_tree, other, engine, rx) = beside("engine-walk");
        let o = other.real();
        let before = crawls(&engine).len();
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{o}"), "zyq");
        let found = vec!["o.txt".to_owned(), "p.txt".to_owned()];
        assert_eq!(pressed(&a, &rx, g), (found, 7, 7));
        assert_eq!(crawls(&engine)[before..], [PathBuf::from(&o)]);
        let read = opened(&engine).len();
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: false,
            folders_first: false,
        };
        let sorted = a.sort(by_name).unwrap();
        let count = ready(&rx, sorted);
        let rows: Vec<(String, String)> = (a.rows(sorted, 0, count).unwrap())
            .into_iter()
            .map(|h| (h.name, h.folder))
            .collect();
        let want = [("p.txt", format!("{o}/Deep")), ("o.txt", o.clone())];
        assert_eq!(rows, want.map(|(n, f)| (n.to_owned(), f)));
        assert_eq!(narrowed(&a, &rx, &format!("'p in:{o}")), ["p.txt"]);
        assert_eq!(opened(&engine).len(), read);
        assert_eq!(crawls(&engine).len(), before + 1);
    }

    #[test]
    fn a_walk_reads_excluded_paths_in_and_around_its_folder() {
        let tree = TempTree::new("engine-walk-excluded");
        write_all(
            &tree,
            &[
                ("Out/w.txt", "zyq"),
                ("Out/Skip/s.txt", "zyq"),
                ("home/h.txt", "zyq"),
            ],
        );
        let root = tree.real();
        let config = EngineConfig {
            excluded: vec![format!("{root}/Out"), format!("{root}/Out/Skip")],
            ..config(&tree)
        };
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        until_live(&rx);
        assert_eq!(texts(&engine, &rx, "text:zyq"), ["h.txt"]);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{root}/Out"), "zyq");
        assert_eq!(pressed(&a, &rx, g).0, ["s.txt", "w.txt"]);
        let skipped = PathBuf::from(format!("{root}/Out/Skip/s.txt"));
        assert!(opened(&engine).contains(&skipped));
        assert_eq!(narrowed(&a, &rx, &format!("'s in:{root}/Out")), ["s.txt"]);
    }

    #[test]
    fn the_file_name_and_the_filters_limit_a_walk_read() {
        let (_tree, other, engine, rx) = beside("engine-walk-name");
        write_all(
            &other,
            &[
                ("report-a.txt", "zyq"),
                ("report-b.txt", "other"),
                ("n.md", "zyq"),
                (".dot.txt", "zyq"),
            ],
        );
        let o = other.real();
        let before = opened(&engine).len();
        let query = format!("'report text:zyq in:{o}");
        assert_eq!(texts(&engine, &rx, &query), ["report-a.txt"]);
        let mut names: Vec<String> = opened(&engine)[before..]
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["report-a.txt", "report-b.txt"]);
        let before = opened(&engine).len();
        assert_eq!(
            texts(&engine, &rx, &format!("ext:md text:zyq in:{o}")),
            ["n.md"]
        );
        assert_eq!(opened(&engine).len() - before, 2);
        let every = ["o.txt", "p.txt", "report-a.txt", "n.md", ".dot.txt"];
        let all = texts(&engine, &rx, &format!("text:zyq in:{o}"));
        assert!(
            every.iter().all(|n| all.contains(&(*n).to_owned())),
            "{all:?}"
        );
        let shown = texts(&engine, &rx, &format!("hidden:no text:zyq in:{o}"));
        assert_eq!(shown.len(), every.len() - 1, "{shown:?}");
        assert!(!shown.contains(&".dot.txt".to_owned()));
    }

    #[test]
    fn the_typo_switch_rescues_a_walked_press_and_its_narrow() {
        let (_tree, other, engine, rx) = beside("engine-walk-typo");
        write_all(&other, &[("explorer.txt", "zyq")]);
        let o = other.real();
        let walked = format!("epxlorer text:zyq in:{o}");
        assert_eq!(texts(&engine, &rx, &walked), NONE);
        engine.set_typos(true).unwrap();
        assert_eq!(texts(&engine, &rx, &walked), ["explorer.txt"]);
        let session = engine.clone().session().unwrap();
        let g = session
            .search_content(format!("in:{o}"), vec!["zyq".to_owned()], true, BEST_MATCH)
            .unwrap();
        assert!(
            pressed(&session, &rx, g)
                .0
                .contains(&"explorer.txt".to_owned())
        );
        let typed = format!("epxlorer in:{o}");
        assert_eq!(narrowed(&session, &rx, &typed), ["explorer.txt"]);
        engine.set_typos(false).unwrap();
        assert_eq!(narrowed(&session, &rx, &typed), NONE);
        assert_eq!(texts(&engine, &rx, &walked), NONE);
    }

    fn hold_walk(engine: &Engine) -> (Receiver<()>, Arc<AtomicBool>) {
        let (reached_tx, reached) = mpsc::channel();
        let saw_stop = Arc::new(AtomicBool::new(false));
        let hook = crate::unit::tests::hold_open(reached_tx, saw_stop.clone());
        *engine.shared.opened.lock().unwrap() = Some(hook);
        (reached, saw_stop)
    }

    #[test]
    fn stop_during_a_walk_ends_the_press_with_done_progress() {
        let (_tree, other, engine, rx) = beside("engine-walk-stop");
        let (reached, saw_stop) = hold_walk(&engine);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        a.stop_content().unwrap();
        let (names, read, _) = pressed(&a, &rx, g);
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after Stop"
        );
        assert_eq!((names, read), (Vec::<String>::new(), 0));
        assert!(opened(&engine).is_empty());
    }

    #[test]
    fn a_name_search_during_a_walk_stops_it() {
        let (_tree, other, engine, rx) = beside("engine-walk-search");
        let (reached, saw_stop) = hold_walk(&engine);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        let s = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, s), 1);
        quiet(&rx, g, g, Duration::from_millis(300));
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after a search"
        );
        assert!(opened(&engine).is_empty());
    }

    #[test]
    fn an_indexed_or_empty_search_folder_walks_nothing() {
        let (tree, disk, engine, rx) = with_disk("engine-walk-none");
        let before = crawls(&engine).len();
        let (root, d) = (tree.real(), disk.real());
        assert_eq!(
            texts(&engine, &rx, "text:alpha"),
            ["d.txt", "e.txt", "h.txt", "top.txt"]
        );
        let home = format!("text:alpha in:{root}/home");
        assert_eq!(texts(&engine, &rx, &home), ["h.txt"]);
        assert_eq!(
            texts(&engine, &rx, &format!("text:alpha in:{d}/Sub")),
            ["e.txt"]
        );
        assert_eq!(crawls(&engine).len(), before);
    }

    #[test]
    fn a_walked_index_goes_with_the_next_search() {
        let (_tree, other, engine, rx) = beside("engine-walk-free");
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        assert_eq!(pressed(&a, &rx, g).0, ["o.txt", "p.txt"]);
        let index = Arc::downgrade(&a.lane.content().unwrap().files().set.found[0].index);
        let s = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, s), 1);
        assert_eq!(a.rows(s, 0, 10).unwrap().len(), 1);
        let deadline = Instant::now() + Duration::from_secs(10);
        while index.strong_count() != 0 {
            assert!(
                Instant::now() < deadline,
                "the walked index outlived its press"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn first_rows(session: &EngineSession, rx: &Receiver<Event>, press: u64) -> Vec<String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let wait = deadline.saturating_duration_since(Instant::now());
            match rx
                .recv_timeout(wait)
                .expect("no file showed while the walk was held")
            {
                Event::Ready(g, count) if g == press && count > 0 => {
                    return names_of(session, g, count);
                }
                Event::Progress(p, _, _, true) if p == press => panic!("the press ended early"),
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn first_round(rx: &Receiver<Event>, press: u64) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let wait = deadline.saturating_duration_since(Instant::now());
            match rx
                .recv_timeout(wait)
                .expect("no round came while the walk was held")
            {
                Event::Progress(p, 0, total, false) if p == press && total > 0 => return,
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn read_while_held(reached: &Receiver<PathBuf>) -> PathBuf {
        reached
            .recv_timeout(Duration::from_secs(5))
            .expect("no file was read while the walk was held")
    }

    #[test]
    fn a_walked_press_shows_a_file_before_its_walk_ends() {
        let (_tree, other, engine, rx) = beside("engine-walk-early");
        let (reached, saw_stop) = hold_walk(&engine);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        let rows = first_rows(&a, &rx, g);
        assert!(
            rows.iter().all(|n| n == "o.txt" || n == "p.txt"),
            "{rows:?}"
        );
        assert!(a.lane.content().unwrap().walking.load(Ordering::SeqCst));
        a.stop_content().unwrap();
        pressed(&a, &rx, g);
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after Stop"
        );
    }

    #[test]
    fn stop_while_a_walk_and_its_reads_run_ends_with_done_progress() {
        let (_tree, other, engine, rx) = beside("engine-walk-overlap-stop");
        let (walked, saw_stop) = hold_walk(&engine);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        walked.recv_timeout(Duration::from_secs(10)).unwrap();
        read_while_held(&reached);
        a.stop_content().unwrap();
        drop(gate);
        let (names, read, total) = pressed(&a, &rx, g);
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after Stop"
        );
        let opened = opened(&engine);
        assert_eq!(read, opened.len() as u64, "{opened:?}");
        assert!(
            read >= 1 && read <= READERS as u64 && read < total,
            "{read} of {total}"
        );
        assert!(
            names.iter().all(|n| n == "o.txt" || n == "p.txt"),
            "{names:?}"
        );
    }

    #[test]
    fn a_name_search_while_a_walk_and_its_reads_run_stops_both() {
        let (_tree, other, engine, rx) = beside("engine-walk-overlap-search");
        let (walked, saw_stop) = hold_walk(&engine);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        walked.recv_timeout(Duration::from_secs(10)).unwrap();
        read_while_held(&reached);
        first_round(&rx, g);
        let content = a.lane.content().unwrap();
        let s = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, s), 1);
        drop(gate);
        let deadline = Instant::now() + Duration::from_secs(10);
        while !content.ended.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "the press ran on after a search");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after a search"
        );
        let entered = 1 + reached.try_iter().count();
        assert_eq!(opened(&engine).len(), entered);
        assert!(entered <= READERS, "{entered}");
        quiet(&rx, g, g, Duration::from_millis(300));
    }

    #[test]
    fn closing_the_window_while_a_walk_and_its_reads_run_stops_both() {
        let (_tree, other, engine, rx) = beside("engine-walk-overlap-close");
        let (walked, saw_stop) = hold_walk(&engine);
        let (reached, gate) = hold_reads(&engine.shared);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{}", other.real()), "zyq");
        walked.recv_timeout(Duration::from_secs(10)).unwrap();
        read_while_held(&reached);
        first_round(&rx, g);
        let content = Arc::downgrade(&a.lane.content().unwrap());
        drop(a);
        drop(gate);
        let deadline = Instant::now() + Duration::from_secs(10);
        while content.strong_count() != 0 {
            assert!(
                Instant::now() < deadline,
                "the closed window kept its press"
            );
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            saw_stop.load(Ordering::Relaxed),
            "the walk ran on after the window closed"
        );
        let entered = 1 + reached.try_iter().count();
        assert_eq!(opened(&engine).len(), entered);
        quiet(&rx, g, g, Duration::from_millis(300));
    }

    fn hold_walk_until(engine: &Engine) -> (Receiver<()>, Sender<()>) {
        let (reached_tx, reached) = mpsc::channel();
        let (release, held) = mpsc::channel::<()>();
        let once = Mutex::new(Some((reached_tx, held)));
        let hook: crawl::Hook = Arc::new(move |stop: &AtomicBool| {
            let Some((reached, held)) = once.lock().unwrap().take() else {
                return;
            };
            let _ = reached.send(());
            let deadline = Instant::now() + Duration::from_secs(10);
            while !stop.load(Ordering::Relaxed)
                && Instant::now() < deadline
                && held.recv_timeout(Duration::from_millis(1)) == Err(RecvTimeoutError::Timeout)
            {
            }
        });
        *engine.shared.opened.lock().unwrap() = Some(hook);
        (reached, release)
    }

    #[test]
    fn a_walk_read_while_it_lists_finds_what_reading_after_it_found() {
        let (_tree, other, engine, rx) = beside("engine-walk-equal");
        let o = other.real();
        let after = engine.clone().session().unwrap();
        let g = press(&after, &format!("in:{o}"), "zyq");
        let want = pressed(&after, &rx, g);
        assert_eq!(want, (vec!["o.txt".to_owned(), "p.txt".to_owned()], 7, 7));
        let before = opened(&engine).len();
        let (walked, release) = hold_walk_until(&engine);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{o}"), "zyq");
        walked.recv_timeout(Duration::from_secs(10)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let wait = deadline.saturating_duration_since(Instant::now());
            match rx
                .recv_timeout(wait)
                .expect("no round was read while the walk was held")
            {
                Event::Progress(p, read, total, false) if p == g && read == total && total > 0 => {
                    break;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        release.send(()).unwrap();
        assert_eq!(pressed(&a, &rx, g), want);
        let mut read = opened(&engine)[before..].to_vec();
        read.sort();
        read.dedup();
        assert_eq!(read.len() as u64, want.1, "a file was read twice");
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: false,
            folders_first: false,
        };
        let sorted = a.sort(by_name).unwrap();
        let count = ready(&rx, sorted);
        let rows: Vec<String> = (a.rows(sorted, 0, count).unwrap())
            .into_iter()
            .map(|h| h.name)
            .collect();
        assert_eq!(rows, ["p.txt", "o.txt"]);
        assert_eq!(
            narrowed(&a, &rx, &format!("'txt in:{o}")),
            ["o.txt", "p.txt"]
        );
        assert_eq!(opened(&engine).len() - before, 7);
    }

    #[test]
    fn a_walk_of_a_folder_it_cannot_open_ends_with_done_progress() {
        let (_tree, other, engine, rx) = beside("engine-walk-locked");
        let o = other.real();
        let _locked = Locked::new(vec![other.0.clone()]);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{o}"), "zyq");
        assert_eq!(pressed(&a, &rx, g), (Vec::<String>::new(), 0, 0));
        assert_eq!(crawls(&engine).last(), Some(&PathBuf::from(&o)));
        assert!(opened(&engine).is_empty());
    }

    #[test]
    fn stop_during_a_presss_name_search_reads_nothing() {
        let (_tree, out, engine, rx) = needles("engine-read-halt", 4);
        let (reached, release) = crate::session::tests::hold_scan(&engine);
        let a = engine.clone().session().unwrap();
        let g = press(&a, &format!("in:{out}"), "needle");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        a.stop_content().unwrap();
        release.send(()).unwrap();
        assert_eq!(pressed(&a, &rx, g), (Vec::<String>::new(), 0, 4));
        assert!(opened(&engine).is_empty());
    }

    #[test]
    fn folders_first_checks_cancel_inside_the_step() {
        use crate::crawl::{Attrs, Listing, NONE};
        let mut listing = Listing::default();
        for i in 0..4000 {
            let attrs = Attrs {
                kind: if i % 3 == 0 {
                    EngineKind::Folder
                } else {
                    EngineKind::File
                },
                size: i,
                mtime: 0,
                created: 0,
                opened: 0,
                mount: false,
                hidden: false,
            };
            listing.push(format!("n{i:05}").as_bytes(), attrs, NONE);
        }
        let index = Index::build(
            crawl::Crawl {
                listings: vec![listing],
                failed: vec![],
            },
            PathBuf::from("/folders-first"),
            b"",
            0,
            0,
        )
        .unwrap();
        let live = Live::new(Arc::new(index));
        let (scanned, _) = Live::find_units("", false, &[&live], || false).unwrap();
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: false,
            folders_first: false,
        };
        let set = Results::new(
            1,
            Query::parse("", "/"),
            scanned,
            by_name,
            &Opens::new(PathBuf::from("/nonexistent/folders-first")),
            &|| false,
        )
        .unwrap();
        let is_file = |r: &Ranked| {
            set.found[r.unit as usize]
                .attrs(r.k as usize)
                .is_none_or(|a| a.kind != EngineKind::Folder)
        };
        let mut old = set.ranked.clone();
        old.sort_by_key(is_file);
        assert_ne!(old, set.ranked);
        let calls = AtomicUsize::new(0);
        let mut got = set.ranked.clone();
        assert!(
            folders_first(&set.found, &mut got, &|| {
                calls.fetch_add(1, Ordering::SeqCst);
                false
            })
            .is_some()
        );
        assert_eq!(got, old);
        let passes = calls.load(Ordering::SeqCst);
        assert!(passes >= 3, "{passes} cancel checks");
        for stop in 1..=passes {
            let calls = AtomicUsize::new(0);
            let mut got = set.ranked.clone();
            assert!(
                folders_first(&set.found, &mut got, &|| {
                    calls.fetch_add(1, Ordering::SeqCst) + 1 >= stop
                })
                .is_none(),
                "a cancel at check {stop} was missed"
            );
        }
    }
}

#[cfg(test)]
mod columns;
