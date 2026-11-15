mod bsdtar;
mod detect;
mod edit;
mod expand;
mod guard;
mod image;
mod pkg;
mod rar;
mod tar;
#[cfg(test)]
mod tests;
mod tree;
mod write;
mod zip;
pub(crate) use write::Destinations;

use std::collections::HashMap;
use std::io::{self, Read};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, PoisonError};

use crate::crawl::Attrs;
use crate::engine::{Engine, Results, Shared, spawn};
use crate::query::Query;
use crate::{EngineError, EngineHit, EngineKind, EngineSort};
use detect::{Reader, Stamp};

pub(crate) const EXTENSIONS: [&str; 17] = [
    "zip", "jar", "aar", "apk", "cbz", "tar", "tgz", "tar.gz", "tbz", "tbz2", "tar.bz2", "txz",
    "tar.xz", "rar", "cbr", "pkg", "dmg",
];

const CACHES: &str = "Library/Caches/com.writronic.wherever/Archives";

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ArchiveProblem {
    Damaged,
    Encrypted,
    Unsupported,
    Empty,
    Changed,
    Gone { name: String },
    NoSpace { needed: u64, volume: String },
    PasswordNeeded,
    WrongPassword,
    PointsOutside { name: String },
    LinkedItem { name: String },
    OldEncryption,
    Duplicate { name: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ArchiveEditing {
    All,
    OldEncryption,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ArchiveChange {
    Delete {
        path: String,
    },
    Add {
        source: String,
        folder: String,
        name: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArchiveClash {
    pub name: String,
    pub existing: String,
    pub folder: bool,
    pub free_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArchiveSummary {
    pub path: String,
    pub format: String,
    pub items: u64,
    pub bytes: u64,
    pub encrypted: bool,
    pub skipped: u64,
    pub problem: Option<ArchiveProblem>,
    pub editing: ArchiveEditing,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArchiveJob {
    pub done_bytes: u64,
    pub total_bytes: u64,
    pub done_items: u64,
    pub total_items: u64,
    pub finished: bool,
    pub problem: Option<ArchiveProblem>,
    pub written: Vec<String>,
    pub skipped: u64,
}

impl std::fmt::Display for ArchiveProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for ArchiveProblem {}

enum Failure {
    Problem(ArchiveProblem),
    Io(io::Error),
    Stopped,
}

#[derive(Clone)]
struct Entry {
    pub path: String,
    pub index: Option<usize>,
    pub attrs: Attrs,
    pub mode: u32,
    pub target: Option<String>,
    pub encrypted: bool,
    pub sized: bool,
    pub disk: Option<PathBuf>,
}

impl Entry {
    fn real(&self) -> bool {
        self.index.is_some() || self.disk.is_some()
    }
}

enum Format {
    Zip(::zip::ZipArchive<Reader>),
    Tar(Vec<tar::Member>),
    Rar(rar::Rar),
    Pkg(pkg::Pkg),
    Image(image::Image),
}

struct Source {
    pub format: Arc<Format>,
    pub reader: Reader,
    pub path: PathBuf,
    pub stamp: Stamp,
    pub quarantine: Vec<u8>,
    pub entries: Vec<Entry>,
    pub destinations: Arc<write::Destinations>,
}

impl Source {
    fn contents<'a, C: Fn() -> bool>(
        &'a self,
        entry: &Entry,
        zip: &'a mut Option<::zip::ZipArchive<Reader>>,
        stream: &'a mut Option<tar::Stream>,
        password: &[u8],
        cancelled: &'a C,
    ) -> Result<Box<dyn Read + 'a>, Failure> {
        if let Some(disk) = &entry.disk {
            return Ok(Box::new(detect::file(disk)?));
        }
        let index = entry.index.ok_or(ArchiveProblem::Damaged)?;
        Ok(match (&*self.format, zip) {
            (Format::Zip(_), Some(zip)) => Box::new(
                zip.by_index_with_options(
                    index,
                    ::zip::read::ZipReadOptions::new()
                        .enforce_header_consistency(true)
                        .password(entry.encrypted.then_some(password)),
                )
                .map_err(zip::problem)?,
            ),
            (Format::Tar(members), _) => Box::new(tar::contents(
                &self.reader,
                stream,
                members.get(index).ok_or(ArchiveProblem::Damaged)?,
                cancelled,
            )?),
            (Format::Rar(rar), _) => {
                Box::new(rar.contents(&self.path, self.stamp, index, cancelled)?)
            }
            (Format::Pkg(pkg), _) => pkg.contents(&self.path, self.stamp, index, cancelled)?,
            (Format::Image(image), _) => Box::new(image.contents(index)?),
            (Format::Zip(_), None) => return Err(ArchiveProblem::Damaged.into()),
        })
    }

    fn with_entries(&self, entries: Vec<Entry>) -> Self {
        Self {
            format: self.format.clone(),
            reader: self.reader.clone(),
            path: self.path.clone(),
            stamp: self.stamp,
            quarantine: self.quarantine.clone(),
            entries,
            destinations: self.destinations.clone(),
        }
    }
}

struct Raw<'a> {
    name: &'a [u8],
    kind: tar::Kind,
    size: u64,
    sized: bool,
    mode: u32,
    mtime: i64,
    target: Option<&'a [u8]>,
    encrypted: bool,
}

fn hidden(path: &str) -> bool {
    path.split('/')
        .any(|p| p.starts_with('.') || p == "__MACOSX")
}

fn listed<'a>(
    raws: impl Iterator<Item = Raw<'a>>,
    summary: &mut ArchiveSummary,
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<Entry>, Failure> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut at: HashMap<String, usize> = HashMap::new();
    for (index, raw) in raws.enumerate() {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let name = String::from_utf8_lossy(raw.name);
        let Some(path) = guard::name(&name) else {
            if !Path::new(name.as_ref())
                .components()
                .all(|c| c == Component::CurDir)
            {
                summary.skipped += 1;
            }
            continue;
        };
        let outside = |summary: &mut ArchiveSummary| {
            summary.skipped += 1;
            summary.problem = Some(ArchiveProblem::PointsOutside { name: path.clone() });
        };
        let (kind, data, size, sized, target, encrypted) = match raw.kind {
            tar::Kind::Special => {
                summary.skipped += 1;
                continue;
            }
            tar::Kind::Folder => (EngineKind::Folder, index, 0, true, None, false),
            tar::Kind::File => (
                EngineKind::File,
                index,
                raw.size,
                raw.sized,
                None,
                raw.encrypted,
            ),
            tar::Kind::Symlink => {
                let Some(to) = raw
                    .target
                    .and_then(|t| String::from_utf8(t.to_vec()).ok())
                    .filter(|t| t.len() <= libc::PATH_MAX as usize)
                else {
                    outside(summary);
                    continue;
                };
                (
                    EngineKind::Link,
                    index,
                    to.len() as u64,
                    true,
                    Some(to),
                    false,
                )
            }
            tar::Kind::HardLink => {
                let source = raw
                    .target
                    .and_then(|t| guard::name(&String::from_utf8_lossy(t)))
                    .and_then(|t| at.get(&t))
                    .map(|&i| &entries[i])
                    .filter(|e| e.attrs.kind == EngineKind::File);
                let Some(source) = source else {
                    outside(summary);
                    continue;
                };
                (
                    EngineKind::File,
                    source.index.ok_or(ArchiveProblem::Damaged)?,
                    source.attrs.size,
                    source.sized,
                    None,
                    source.encrypted,
                )
            }
        };
        let entry = Entry {
            attrs: Attrs {
                kind,
                size,
                mtime: raw.mtime,
                created: 0,
                opened: 0,
                mount: false,
                hidden: hidden(&path),
            },
            path,
            index: Some(data),
            mode: if raw.mode & 0o777 == 0 && kind == EngineKind::Folder {
                0o755
            } else {
                raw.mode & 0o777
            },
            target,
            encrypted,
            sized,
            disk: None,
        };
        summary.encrypted |= entry.encrypted;
        match at.get(&entry.path) {
            Some(&i) => entries[i] = entry,
            None => {
                at.insert(entry.path.clone(), entries.len());
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

fn visible((found, hits): &mut (crate::live::Found, Vec<crate::query::Hit>)) {
    let base = found.hits.len();
    let keep: Vec<bool> = found
        .hits
        .iter()
        .map(|&e| !found.index.attrs(e as usize).hidden)
        .chain(found.added.iter().map(|a| !a.attrs.hidden))
        .collect();
    let mut at = keep.iter();
    hits.retain(|_| *at.next().unwrap_or(&true));
    let mut at = keep.iter();
    found.hits.retain(|_| *at.next().unwrap_or(&true));
    let mut at = keep[base..].iter();
    found.added.retain(|_| *at.next().unwrap_or(&true));
}

fn finish(entries: &mut Vec<Entry>, summary: &mut ArchiveSummary) -> Result<(), Failure> {
    let links: HashMap<String, String> = entries
        .iter()
        .filter_map(|e| Some((e.path.clone(), e.target.clone()?)))
        .collect();
    entries.retain(|e| {
        if let Some(to) = &e.target
            && guard::target(&e.path, to, &links).is_none()
        {
            summary.skipped += 1;
            summary.problem = Some(ArchiveProblem::PointsOutside {
                name: e.path.clone(),
            });
            return false;
        }
        true
    });
    for e in entries.iter() {
        if e.attrs.kind == EngineKind::File {
            summary.items += 1;
            summary.bytes = summary
                .bytes
                .checked_add(e.attrs.size)
                .ok_or(ArchiveProblem::Damaged)?;
        }
    }
    if entries.is_empty() && summary.problem.is_none() {
        summary.problem = Some(ArchiveProblem::Empty);
    }
    Ok(())
}

fn pkg_rows(
    members: &[pkg::Member],
    summary: &mut ArchiveSummary,
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<Entry>, Failure> {
    listed(
        members.iter().map(|m| Raw {
            name: &m.name,
            kind: m.kind,
            size: m.size,
            sized: true,
            mode: m.mode,
            mtime: m.mtime,
            target: m.target.as_deref(),
            encrypted: false,
        }),
        summary,
        cancelled,
    )
}

#[allow(clippy::too_many_arguments)]
fn open(
    path: &Path,
    shown_as: &str,
    summary: &mut ArchiveSummary,
    closed: Arc<std::sync::atomic::AtomicBool>,
    destinations: Arc<write::Destinations>,
    caches: &Path,
    session: u64,
    password: &[u8],
    cancelled: &impl Fn() -> bool,
) -> Result<Source, Failure> {
    let reader = Reader::open(path, closed)?;
    let stamp = Stamp::read(&reader.file)?;
    let named = |test: fn(&str) -> bool| {
        [path, Path::new(shown_as)]
            .iter()
            .any(|p| p.file_name().is_some_and(|n| test(&n.to_string_lossy())))
    };
    let quarantine = write::read_quarantine(&reader.file)?;
    let (format, mut entries) = match reader.format(
        named(detect::tarball),
        named(detect::pkg),
        named(detect::image),
    )? {
        Some(detect::Format::Zip) => {
            let (zip, entries) = zip::open(&reader, summary, cancelled)?;
            (Format::Zip(zip), entries)
        }
        Some(detect::Format::Tar) => {
            summary.format = "tar".into();
            let (members, problem) = tar::list(&reader, cancelled)?;
            summary.problem = problem;
            let entries = listed(
                members.iter().map(|m| Raw {
                    name: &m.name,
                    kind: match m.kind {
                        tar::Kind::HardLink if m.size > 0 => tar::Kind::File,
                        kind => kind,
                    },
                    size: m.size,
                    sized: true,
                    mode: m.mode,
                    mtime: m.mtime.0,
                    target: m.target.as_deref(),
                    encrypted: false,
                }),
                summary,
                cancelled,
            )?;
            (Format::Tar(members), entries)
        }
        Some(detect::Format::Rar) => {
            summary.format = "rar".into();
            let (rar, problem) = rar::list(&reader, cancelled).inspect_err(|failure| {
                if matches!(failure, Failure::Problem(ArchiveProblem::Encrypted)) {
                    summary.encrypted = true;
                }
            })?;
            summary.problem = problem;
            let entries = listed(
                rar.members.iter().map(|m| Raw {
                    name: &m.name,
                    kind: m.kind,
                    size: m.size,
                    sized: m.sized,
                    mode: m.mode,
                    mtime: m.mtime,
                    target: m.target.as_deref(),
                    encrypted: m.encrypted,
                }),
                summary,
                cancelled,
            )?;
            (Format::Rar(rar), entries)
        }
        Some(detect::Format::Pkg) => {
            summary.format = "pkg".into();
            let pkg = pkg::list(path, stamp, caches.join(stamp.key()), session, cancelled)?;
            summary.skipped += pkg.skipped;
            let entries = pkg_rows(&pkg.members, summary, cancelled)?;
            (Format::Pkg(pkg), entries)
        }
        Some(detect::Format::Image) => {
            summary.format = "dmg".into();
            let image = image::open(
                path,
                stamp,
                &caches.join("Mounts"),
                password,
                summary,
                cancelled,
            )?;
            summary.skipped += image.skipped;
            let entries = pkg_rows(&image.members, summary, cancelled)?;
            (Format::Image(image), entries)
        }
        None => return Err(ArchiveProblem::Unsupported.into()),
    };
    finish(&mut entries, summary)?;
    summary.editing = match &format {
        Format::Zip(zip) if named(|n| n.to_lowercase().ends_with(".zip")) => {
            if zip::old_encryption(zip) {
                ArchiveEditing::OldEncryption
            } else {
                ArchiveEditing::All
            }
        }
        Format::Tar(_) if named(detect::tarball) => ArchiveEditing::All,
        _ => ArchiveEditing::None,
    };
    if Stamp::read(&reader.file)? != stamp {
        return Err(ArchiveProblem::Changed.into());
    }
    Ok(Source {
        format: Arc::new(format),
        reader,
        path: path.to_path_buf(),
        stamp,
        quarantine,
        entries,
        destinations,
    })
}

fn payload(
    source: &Source,
    summary: &ArchiveSummary,
    free: fn(&std::fs::File) -> io::Result<write::Space>,
    cancelled: &impl Fn() -> bool,
) -> Result<(Source, ArchiveSummary), Failure> {
    let Format::Pkg(pkg) = &*source.format else {
        return Err(ArchiveProblem::Damaged.into());
    };
    let next = pkg.expand(&source.path, source.stamp, free, cancelled)?;
    let mut summary = ArchiveSummary {
        items: 0,
        bytes: 0,
        skipped: next.skipped,
        problem: None,
        ..summary.clone()
    };
    let mut entries = pkg_rows(&next.members, &mut summary, cancelled)?;
    finish(&mut entries, &mut summary)?;
    Ok((
        Source {
            format: Arc::new(Format::Pkg(next)),
            reader: source.reader.clone(),
            path: source.path.clone(),
            stamp: source.stamp,
            quarantine: source.quarantine.clone(),
            entries,
            destinations: source.destinations.clone(),
        },
        summary,
    ))
}

fn expanded(
    state: &Mutex<State>,
    folder: &str,
    shown_as: &str,
    cancelled: &impl Fn() -> bool,
) -> Option<tree::Tree> {
    let (source, free, mut summary) = {
        let s = state.lock().unwrap_or_else(PoisonError::into_inner);
        (s.source.clone()?, s.space, s.summary.clone())
    };
    let Format::Pkg(pkg) = &*source.format else {
        return None;
    };
    if !pkg.enters(folder) {
        return None;
    }
    let built = catch_unwind(AssertUnwindSafe(|| {
        let (mut next, expanded) = payload(&source, &summary, free, cancelled)?;
        let tree = tree::Tree::build(&mut next.entries, shown_as, cancelled)?;
        summary = expanded;
        Ok::<_, Failure>((next, tree))
    }));
    let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
    match built {
        Ok(Ok((next, tree))) => {
            s.source = Some(Arc::new(next));
            s.summary = summary;
            Some(tree)
        }
        Ok(Err(Failure::Stopped)) => None,
        Ok(Err(Failure::Problem(problem))) => {
            s.summary.problem = Some(problem);
            None
        }
        Ok(Err(Failure::Io(_))) | Err(_) => {
            s.summary.problem = Some(ArchiveProblem::Damaged);
            None
        }
    }
}

impl From<ArchiveProblem> for Failure {
    fn from(problem: ArchiveProblem) -> Self {
        Self::Problem(problem)
    }
}

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

struct State {
    summary: ArchiveSummary,
    source: Option<Arc<Source>>,
    base: Option<Arc<Source>>,
    changes: Vec<edit::Change>,
    rebuild: Option<Vec<edit::Change>>,
    folder: String,
    query: String,
    searching: bool,
    sort: EngineSort,
    generation: u64,
    pending: bool,
    held: Option<Arc<Results>>,
    previous: Option<Arc<Results>>,
    jobs: HashMap<u64, Arc<write::Task>>,
    error: Option<String>,
    space: fn(&std::fs::File) -> io::Result<write::Space>,
    #[cfg(test)]
    write_hold: Option<(mpsc::Sender<()>, mpsc::Receiver<()>)>,
}

#[derive(uniffi::Object)]
pub struct ArchiveSession {
    id: u64,
    _engine: Arc<Engine>,
    shared: Arc<Shared>,
    state: Arc<Mutex<State>>,
    closed: Arc<AtomicBool>,
    wake: SyncSender<()>,
    password: Arc<Mutex<Vec<u8>>>,
    shown_as: String,
}

fn wipe(bytes: &mut [u8]) {
    for byte in bytes.iter_mut() {
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(Ordering::SeqCst);
}

impl ArchiveSession {
    pub(crate) fn new(
        engine: Arc<Engine>,
        shared: Arc<Shared>,
        path: String,
        shown_as: String,
    ) -> Result<Arc<Self>, EngineError> {
        let id = shared.sessions.fetch_add(1, Ordering::Relaxed) + 1;
        let state = Arc::new(Mutex::new(State {
            summary: ArchiveSummary {
                path: path.clone(),
                format: String::new(),
                items: 0,
                bytes: 0,
                encrypted: false,
                skipped: 0,
                problem: None,
                editing: ArchiveEditing::None,
            },
            source: None,
            base: None,
            changes: Vec::new(),
            rebuild: None,
            folder: String::new(),
            query: String::new(),
            searching: false,
            sort: EngineSort {
                column: crate::EngineColumn::Name,
                ascending: true,
                folders_first: true,
            },
            generation: 0,
            pending: false,
            held: None,
            previous: None,
            jobs: HashMap::new(),
            error: None,
            space: write::space,
            #[cfg(test)]
            write_hold: None,
        }));
        let closed = Arc::new(AtomicBool::new(false));
        let (wake, pending) = mpsc::sync_channel(1);
        let caches = shared.settings.home.join(CACHES);
        spawn("wherever-archive", {
            let (state, shared, closed) = (state.clone(), shared.clone(), closed.clone());
            let shown_as = shown_as.clone();
            move || {
                let cancelled = || closed.load(Ordering::Relaxed) || shared.stopped();
                let mut summary = state
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .summary
                    .clone();
                let opened = catch_unwind(AssertUnwindSafe(|| {
                    let mut source = open(
                        Path::new(&path),
                        &shown_as,
                        &mut summary,
                        closed.clone(),
                        shared.archive_destinations.clone(),
                        &caches,
                        id,
                        &[],
                        &cancelled,
                    )?;
                    let tree = tree::Tree::build(&mut source.entries, &shown_as, &cancelled)?;
                    Ok::<_, Failure>((source, tree))
                }));
                let mut tree = {
                    let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
                    let tree = match opened {
                        Ok(Ok((source, tree))) => {
                            let source = Arc::new(source);
                            state.base = Some(source.clone());
                            state.source = Some(source);
                            Some(tree)
                        }
                        Ok(Err(Failure::Problem(problem))) => {
                            summary.problem = Some(problem);
                            None
                        }
                        Ok(Err(Failure::Io(e))) => {
                            state.error = Some(e.to_string());
                            None
                        }
                        Ok(Err(Failure::Stopped)) => return,
                        Err(_) => {
                            summary.problem = Some(ArchiveProblem::Damaged);
                            None
                        }
                    };
                    state.summary = summary;
                    tree
                };
                while pending.recv().is_ok() && !cancelled() {
                    let (generation, folder, query, searching, sort, rebuild) = {
                        let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
                        if !std::mem::take(&mut s.pending) {
                            continue;
                        }
                        let rebuild = s.rebuild.take().zip(s.base.clone());
                        (
                            s.generation,
                            s.folder.clone(),
                            s.query.clone(),
                            s.searching,
                            s.sort,
                            rebuild,
                        )
                    };
                    if let Some((changes, base)) = rebuild {
                        let replaced = || {
                            cancelled()
                                || state
                                    .lock()
                                    .unwrap_or_else(PoisonError::into_inner)
                                    .rebuild
                                    .is_some()
                        };
                        let built = catch_unwind(AssertUnwindSafe(|| {
                            let mut entries = edit::view(&base, &changes, &replaced)?;
                            let next = tree::Tree::build(&mut entries, &shown_as, &replaced)?;
                            Ok::<_, Failure>((entries, next))
                        }));
                        match built {
                            Ok(Ok((entries, next))) => {
                                let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
                                if s.rebuild.is_some() {
                                    continue;
                                }
                                s.source = Some(Arc::new(base.with_entries(entries)));
                                tree = Some(next);
                            }
                            Ok(Err(Failure::Stopped)) => continue,
                            _ => {
                                let _ = shared.listener.search_failed(generation);
                                continue;
                            }
                        }
                    }
                    let superseded = || {
                        cancelled()
                            || state
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .generation
                                != generation
                    };
                    if let Some(next) = expanded(&state, &folder, &shown_as, &superseded) {
                        tree = Some(next);
                    }
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        let mut q = Query::parse(&query, &shared.settings.home.to_string_lossy());
                        if !searching {
                            q.tokens.clear();
                        }
                        let scanned = match &tree {
                            None => Vec::new(),
                            Some(tree) if q.tokens.is_empty() => tree.list(&folder, q.hide),
                            Some(tree) => {
                                let hide = std::mem::take(&mut q.hide);
                                let mut scanned = crate::query::walked(
                                    &mut q,
                                    &shared.settings,
                                    &tree.live,
                                    &superseded,
                                )?;
                                q.hide = hide;
                                if hide {
                                    scanned.iter_mut().for_each(visible);
                                }
                                scanned
                            }
                        };
                        Results::new(generation, q, scanned, sort, &shared.opens, &superseded)
                    }));
                    match result {
                        Ok(Some(results)) => {
                            let count = results.count();
                            let old = {
                                let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
                                if s.generation != generation || cancelled() {
                                    continue;
                                }
                                let old = s.previous.take();
                                s.previous = s.held.replace(Arc::new(results));
                                old
                            };
                            drop(old);
                            let _ = shared.listener.results_ready(generation, count);
                        }
                        Err(_) => {
                            let _ = shared.listener.search_failed(generation);
                        }
                        _ => {}
                    }
                }
                let kept = {
                    let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
                    s.held = None;
                    s.previous = None;
                    (s.source.take(), s.base.take())
                };
                drop(kept);
            }
        })?;
        Ok(Arc::new(Self {
            id,
            _engine: engine,
            shared,
            state,
            closed,
            wake,
            password: Arc::new(Mutex::new(Vec::new())),
            shown_as,
        }))
    }

    fn check(&self) -> Result<(), EngineError> {
        if self.closed.load(Ordering::Relaxed) || self.shared.stopped() {
            Err(EngineError::Stopped)
        } else {
            Ok(())
        }
    }

    fn request(
        &self,
        folder: Option<String>,
        query: Option<String>,
        sort: Option<EngineSort>,
    ) -> Result<u64, EngineError> {
        self.check()?;
        let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.check()?;
        if let Some(folder) = folder {
            s.folder = folder;
            s.searching = false;
        }
        if let Some(query) = query {
            s.query = query;
            s.searching = true;
        }
        if let Some(sort) = sort {
            s.sort = sort;
        }
        s.generation = self.shared.generation.fetch_add(1, Ordering::Relaxed) + 1;
        s.pending = true;
        match self.wake.try_send(()) {
            Ok(()) | Err(TrySendError::Full(())) => Ok(s.generation),
            Err(TrySendError::Disconnected(())) => Err(EngineError::Stopped),
        }
    }

    fn extract_with_space(
        &self,
        entries: Vec<String>,
        folder: String,
        read_only: bool,
        free: fn(&std::fs::File) -> io::Result<write::Space>,
    ) -> Result<u64, EngineError> {
        let (closed, password) = (self.closed.clone(), self.password.clone());
        self.start("wherever-archive-write", move |source, task, _, summary| {
            write::run(
                source,
                summary,
                &entries,
                Path::new(&folder),
                read_only,
                &password,
                task,
                &closed,
                free,
            )
        })
    }

    fn expand_with_space(
        &self,
        entries: Vec<String>,
        folder: String,
        whole: bool,
        free: fn(&std::fs::File) -> io::Result<write::Space>,
    ) -> Result<u64, EngineError> {
        let (closed, password) = (self.closed.clone(), self.password.clone());
        let (shown_as, caches) = (
            self.shown_as.clone(),
            self.shared.settings.home.join(CACHES),
        );
        self.start(
            "wherever-archive-expand",
            move |source, task, id, summary| {
                expand::run(
                    source,
                    &expand::Order {
                        names: &entries,
                        folder: Path::new(&folder),
                        whole,
                        shown_as: &shown_as,
                        list: &caches.join(format!("expand-{}-{id}.list", std::process::id())),
                        staging: &format!(".Wherever-{}-{id}", std::process::id()),
                        summary,
                    },
                    &password,
                    task,
                    &closed,
                    free,
                )
            },
        )
    }

    fn start(
        &self,
        thread: &str,
        work: impl FnOnce(&Source, &write::Task, u64, &ArchiveSummary) -> Result<(), Failure>
        + Send
        + 'static,
    ) -> Result<u64, EngineError> {
        self.check()?;
        let (source, summary, task, id) = {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            self.check()?;
            if let Some(error) = &s.error {
                return Err(EngineError::Io {
                    message: error.clone(),
                });
            }
            if s.source.is_none() && s.summary.problem.is_none() {
                return Err(EngineError::Io {
                    message: "Archive listing is not ready".into(),
                });
            }
            let task = Arc::new(write::Task::new());
            #[cfg(test)]
            {
                *task.hold.lock().unwrap() = s.write_hold.take();
            }
            let id = self.shared.generation.fetch_add(1, Ordering::Relaxed) + 1;
            s.jobs.insert(id, task.clone());
            (s.source.clone(), s.summary.clone(), task, id)
        };
        let worker = spawn(thread, {
            let task = task.clone();
            move || {
                let outcome = catch_unwind(AssertUnwindSafe(|| match source {
                    Some(source) => work(&source, &task, id, &summary),
                    None => Err(summary.problem.unwrap_or(ArchiveProblem::Damaged).into()),
                }))
                .unwrap_or_else(|_| Err(ArchiveProblem::Damaged.into()));
                task.finish(outcome);
            }
        });
        if let Err(e) = worker {
            task.finish(Err(Failure::Io(e)));
        }
        Ok(id)
    }

    fn ready(&self) -> Result<Option<Arc<Source>>, EngineError> {
        self.check()?;
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(error) = &s.error {
            return Err(EngineError::Io {
                message: error.clone(),
            });
        }
        if s.source.is_none() && s.summary.problem.is_none() {
            return Err(EngineError::Io {
                message: "Archive listing is not ready".into(),
            });
        }
        Ok(s.source.clone())
    }

    fn verify(&self, password: &[u8]) -> Result<bool, EngineError> {
        let Some(source) = self.ready()? else {
            return Ok(false);
        };
        let Format::Zip(zip) = &*source.format else {
            return Ok(false);
        };
        if password.is_empty() {
            return Ok(false);
        }
        let Some(entry) = source
            .entries
            .iter()
            .filter(|e| e.encrypted && matches!(e.attrs.kind, EngineKind::File | EngineKind::Link))
            .min_by_key(|e| {
                (
                    e.attrs.kind != EngineKind::File,
                    e.attrs.size == 0,
                    e.attrs.size,
                )
            })
        else {
            return Ok(true);
        };
        let Some(index) = entry.index else {
            return Ok(false);
        };
        let mut zip = zip.clone();
        let Ok(mut file) = zip.by_index_with_options(
            index,
            ::zip::read::ZipReadOptions::new()
                .enforce_header_consistency(true)
                .password(Some(password)),
        ) else {
            return Ok(false);
        };
        Ok(io::copy(&mut file, &mut io::sink()).is_ok())
    }

    fn forget_password(&self) {
        wipe(&mut self.password.lock().unwrap_or_else(PoisonError::into_inner));
    }

    fn locked_image(&self) -> bool {
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        s.source.is_none()
            && s.summary.format == "dmg"
            && s.summary.problem == Some(ArchiveProblem::PasswordNeeded)
    }

    fn unlock_image(&self, password: &[u8]) -> Result<bool, EngineError> {
        self.check()?;
        if password.is_empty() {
            return Ok(false);
        }
        let mut summary = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .summary
            .clone();
        summary.problem = None;
        let path = PathBuf::from(&summary.path);
        let cancelled = || self.closed.load(Ordering::Relaxed) || self.shared.stopped();
        let opened = catch_unwind(AssertUnwindSafe(|| {
            open(
                &path,
                &self.shown_as,
                &mut summary,
                self.closed.clone(),
                self.shared.archive_destinations.clone(),
                &self.shared.settings.home.join(CACHES),
                self.id,
                password,
                &cancelled,
            )
        }));
        let source = match opened {
            Ok(Ok(source)) => Arc::new(source),
            Ok(Err(Failure::Problem(ArchiveProblem::WrongPassword))) => return Ok(false),
            Ok(Err(Failure::Stopped)) => return Err(EngineError::Stopped),
            failed => {
                let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
                match failed {
                    Ok(Err(Failure::Problem(problem))) => s.summary.problem = Some(problem),
                    Ok(Err(Failure::Io(e))) => s.error = Some(e.to_string()),
                    _ => s.summary.problem = Some(ArchiveProblem::Damaged),
                }
                return Ok(true);
            }
        };
        let late = {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            if cancelled() || s.source.is_some() {
                Some(source)
            } else {
                s.summary = summary;
                s.base = Some(source.clone());
                s.source = Some(source);
                s.rebuild = Some(Vec::new());
                None
            }
        };
        drop(late);
        self.check()?;
        Ok(true)
    }
}

impl Drop for ArchiveSession {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Relaxed);
        let _ = self.wake.try_send(());
        self.forget_password();
    }
}

#[uniffi::export]
impl ArchiveSession {
    pub fn id(&self) -> Result<u64, EngineError> {
        self.check()?;
        Ok(self.id)
    }

    pub fn browse(&self, folder: String) -> Result<u64, EngineError> {
        let folder = if folder.is_empty() {
            folder
        } else {
            guard::name(&folder).ok_or_else(|| EngineError::Io {
                message: "Invalid archive folder".into(),
            })?
        };
        self.request(Some(folder), None, None)
    }

    pub fn search(&self, query: String, sort: EngineSort) -> Result<u64, EngineError> {
        self.request(None, Some(query), Some(sort))
    }

    pub fn refresh(&self, query: String, sort: EngineSort) -> Result<u64, EngineError> {
        let _ = (query, sort);
        self.check()?;
        Ok(self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .generation)
    }

    pub fn sort(&self, sort: EngineSort) -> Result<u64, EngineError> {
        self.request(None, None, Some(sort))
    }

    pub fn rows(
        &self,
        generation: u64,
        start: u32,
        count: u32,
    ) -> Result<Vec<EngineHit>, EngineError> {
        self.check()?;
        let (results, freed) = {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            self.check()?;
            let newest = s.held.clone().filter(|r| r.generation == generation);
            let freed = if newest.is_some() {
                s.previous.take()
            } else {
                None
            };
            (
                newest.or_else(|| s.previous.clone().filter(|r| r.generation == generation)),
                freed,
            )
        };
        if freed.is_some() {
            rayon::spawn(move || drop(freed));
        }
        let results = results.ok_or(EngineError::Stale { generation })?;
        let rows = results.rows(start as usize, count as usize);
        if let Some(set) = Arc::into_inner(results) {
            rayon::spawn(move || drop(set));
        }
        Ok(rows)
    }

    pub fn summary(&self) -> Result<ArchiveSummary, EngineError> {
        self.check()?;
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(error) = &s.error {
            return Err(EngineError::Io {
                message: error.clone(),
            });
        }
        Ok(s.summary.clone())
    }

    pub fn extract(
        &self,
        entries: Vec<String>,
        folder: String,
        read_only: bool,
    ) -> Result<u64, EngineError> {
        self.extract_with_space(entries, folder, read_only, write::space)
    }

    pub fn expand(
        &self,
        entries: Vec<String>,
        folder: String,
        whole: bool,
    ) -> Result<u64, EngineError> {
        self.expand_with_space(entries, folder, whole, write::space)
    }

    pub fn job(&self, id: u64) -> Result<ArchiveJob, EngineError> {
        let task = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .jobs
            .get(&id)
            .cloned()
            .ok_or(EngineError::Stale { generation: id })?;
        let p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(error) = &p.error {
            return Err(EngineError::Io {
                message: error.clone(),
            });
        }
        Ok(p.job.clone())
    }

    pub fn cancel(&self, id: u64) -> Result<(), EngineError> {
        let task = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .jobs
            .get(&id)
            .cloned()
            .ok_or(EngineError::Stale { generation: id })?;
        task.stop.store(true, Ordering::Relaxed);
        Ok(())
    }

    pub fn unlock(&self, password: String) -> Result<bool, EngineError> {
        let mut candidate = password.into_bytes();
        if self.locked_image() {
            let unlocked = self.unlock_image(&candidate);
            wipe(&mut candidate);
            return unlocked;
        }
        let verified = self.verify(&candidate);
        if !matches!(verified, Ok(true)) {
            wipe(&mut candidate);
            return verified;
        }
        let mut stored = self.password.lock().unwrap_or_else(PoisonError::into_inner);
        if self.closed.load(Ordering::Relaxed) {
            wipe(&mut candidate);
            return Err(EngineError::Stopped);
        }
        wipe(&mut stored);
        *stored = candidate;
        Ok(true)
    }

    pub fn encrypted(&self, entry: String) -> Result<bool, EngineError> {
        let safe = guard::name(&entry).ok_or_else(|| EngineError::Io {
            message: "Invalid archive entry".into(),
        })?;
        Ok(self.ready()?.is_some_and(|source| {
            source.entries.iter().any(|e| {
                e.encrypted
                    && e.path
                        .strip_prefix(&safe)
                        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
            })
        }))
    }

    pub fn set_changes(&self, changes: Vec<ArchiveChange>) -> Result<u64, EngineError> {
        let changes = edit::parsed(&changes).ok_or_else(|| EngineError::Io {
            message: "Invalid archive change".into(),
        })?;
        self.check()?;
        {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(error) = &s.error {
                return Err(EngineError::Io {
                    message: error.clone(),
                });
            }
            if s.base.is_none() {
                return Err(EngineError::Io {
                    message: "Archive listing is not ready".into(),
                });
            }
            if s.summary.editing == ArchiveEditing::None {
                return Err(EngineError::Io {
                    message: "Archive cannot be edited".into(),
                });
            }
            s.changes = changes.clone();
            s.rebuild = Some(changes);
        }
        self.request(None, None, None)
    }

    pub fn clashes(
        &self,
        folder: String,
        names: Vec<String>,
    ) -> Result<Vec<ArchiveClash>, EngineError> {
        let folder = if folder.is_empty() {
            folder
        } else {
            guard::name(&folder).ok_or_else(|| EngineError::Io {
                message: "Invalid archive folder".into(),
            })?
        };
        Ok(self.ready()?.map_or_else(Vec::new, |source| {
            edit::clashes(&source.entries, &folder, &names)
        }))
    }

    pub fn write_edited(&self, out: String) -> Result<u64, EngineError> {
        let refused = |message: &str| EngineError::Io {
            message: message.into(),
        };
        let path = PathBuf::from(&out);
        if !path.is_absolute() || path.file_name().is_none() || out.contains('\0') {
            return Err(refused("Invalid archive output"));
        }
        self.check()?;
        let (base, changes, editing, aes) = {
            let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            (
                s.base.clone(),
                s.changes.clone(),
                s.summary.editing,
                s.summary.encrypted,
            )
        };
        if base
            .as_ref()
            .is_some_and(|b| detect::resolved(&path) == detect::resolved(&b.path))
        {
            return Err(refused("Archive output is the archive"));
        }
        if std::fs::symlink_metadata(&path).is_ok() {
            return Err(refused("Archive output exists"));
        }
        let (closed, password) = (self.closed.clone(), self.password.clone());
        let caches = self.shared.settings.home.join(CACHES);
        self.start("wherever-archive-edit", move |_, task, id, _| {
            let base = base.ok_or(ArchiveProblem::Damaged)?;
            edit::write(
                &edit::Order {
                    base: &base,
                    changes: &changes,
                    editing,
                    aes,
                    out: &path,
                    work: &caches.join(base.stamp.key()).join(format!("edit-{id}")),
                },
                &password,
                task,
                &closed,
                write::space,
            )
        })
    }

    pub fn close(&self) -> Result<(), EngineError> {
        self.closed.store(true, Ordering::Relaxed);
        let _ = self.wake.try_send(());
        self.forget_password();
        Ok(())
    }
}
