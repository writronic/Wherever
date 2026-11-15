use std::cell::{Cell, RefCell};
use std::ffi::{CString, OsStr};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rayon::{Scope, ThreadPool};

use crate::EngineKind;

pub const NONE: u32 = u32::MAX;
pub(crate) const PROGRESS_GAP_MS: u64 = 250;
type Publish<'a> = Option<&'a (dyn Fn(&[Listing]) + Sync)>;

const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const DIR_MNTSTATUS_TRIGGER: u32 = 0x2;
const OPEN_DIR: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY | libc::O_CLOEXEC;

const OPEN_MAX: libc::rlim_t = 10240;
const IOPOL_TYPE_VFS_ATIME_UPDATES: libc::c_int = 2;
const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: libc::c_int = 3;
const IOPOL_SCOPE_THREAD: libc::c_int = 1;
const IOPOL_ATIME_UPDATES_OFF: libc::c_int = 1;
const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: libc::c_int = 1;
pub(crate) const TEXT_STACK: usize = 16 << 20;

unsafe extern "C" {
    fn setiopolicy_np(iotype: libc::c_int, scope: libc::c_int, policy: libc::c_int) -> libc::c_int;
}

pub fn raise_fd_limit() -> io::Result<()> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let target = OPEN_MAX.min(limit.rlim_max);
    if limit.rlim_cur >= target {
        return Ok(());
    }
    limit.rlim_cur = target;
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn no_materialize() {
    unsafe {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
        )
    };
}

fn no_atime() {
    unsafe {
        setiopolicy_np(
            IOPOL_TYPE_VFS_ATIME_UPDATES,
            IOPOL_SCOPE_THREAD,
            IOPOL_ATIME_UPDATES_OFF,
        )
    };
}

thread_local! {
    pub static ENGINE_THREAD: Cell<bool> = const { Cell::new(false) };
}

#[derive(Clone)]
pub struct RawEnt {
    name_off: u32,
    name_len: u16,
    pub kind: EngineKind,
    mount: bool,
    pub hidden: bool,
    pub size: u64,
    pub mtime: i64,
    pub created: i64,
    pub opened: i64,
    pub child: u32,
}

impl RawEnt {
    pub fn attrs(&self) -> Attrs {
        Attrs {
            kind: self.kind,
            size: self.size,
            mtime: self.mtime,
            created: self.created,
            opened: self.opened,
            mount: self.mount,
            hidden: self.hidden,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Attrs {
    pub kind: EngineKind,
    pub size: u64,
    pub mtime: i64,
    pub created: i64,
    pub opened: i64,
    pub mount: bool,
    pub hidden: bool,
}

#[derive(Clone, Default)]
pub struct Listing {
    pub id: u32,
    names: Arc<Vec<u8>>,
    pub ents: Ents,
    pub cut: bool,
}

#[derive(Clone, Default)]
pub struct Ents(Arc<Vec<RawEnt>>);

impl std::ops::Deref for Ents {
    type Target = Vec<RawEnt>;

    fn deref(&self) -> &Vec<RawEnt> {
        &self.0
    }
}

impl std::ops::DerefMut for Ents {
    fn deref_mut(&mut self) -> &mut Vec<RawEnt> {
        Arc::make_mut(&mut self.0)
    }
}

impl<'a> IntoIterator for &'a Ents {
    type Item = &'a RawEnt;
    type IntoIter = std::slice::Iter<'a, RawEnt>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

impl Listing {
    pub fn name(&self, e: &RawEnt) -> &[u8] {
        &self.names[e.name_off as usize..][..e.name_len as usize]
    }

    fn parts(&mut self) -> (&mut Vec<u8>, &mut Vec<RawEnt>) {
        (Arc::make_mut(&mut self.names), &mut self.ents)
    }

    pub fn push(&mut self, name: &[u8], a: Attrs, child: u32) {
        let name = &name[..name.len().min(u16::MAX as usize)];
        let (names, ents) = self.parts();
        ents.push(RawEnt {
            name_off: names.len() as u32,
            name_len: name.len() as u16,
            kind: a.kind,
            mount: a.mount,
            hidden: a.hidden,
            size: a.size,
            mtime: a.mtime,
            created: a.created,
            opened: a.opened,
            child,
        });
        names.extend_from_slice(name);
    }

    pub fn sort(&mut self) {
        let names = &self.names;
        let name = |e: &RawEnt| &names[e.name_off as usize..][..e.name_len as usize];
        if !self.ents.is_sorted_by(|a, b| name(a) <= name(b)) {
            self.ents.sort_unstable_by(|a, b| name(a).cmp(name(b)));
        }
    }
}

pub struct Pool {
    pool: ThreadPool,
    _threads: Joined,
}

struct Joined(Vec<JoinHandle<()>>);

impl Drop for Joined {
    fn drop(&mut self) {
        for t in self.0.drain(..) {
            let _ = t.join();
        }
    }
}

impl Pool {
    pub fn new(threads: usize) -> io::Result<Pool> {
        Pool::build(threads, "crawl", || {}, None)
    }

    pub fn text(threads: usize) -> io::Result<Pool> {
        Pool::build(threads, "text", no_atime, Some(TEXT_STACK))
    }

    pub fn live() -> io::Result<Pool> {
        Pool::build(1, "live", || {}, None)
    }

    fn build(
        threads: usize,
        role: &'static str,
        setup: fn(),
        stack: Option<usize>,
    ) -> io::Result<Pool> {
        let mut handles = Vec::with_capacity(threads);
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(move |i| format!("wherever-{role}-{i}"))
            .spawn_handler(|t| {
                let mut b = thread::Builder::new();
                if let Some(size) = stack {
                    b = b.stack_size(size);
                }
                if let Some(name) = t.name() {
                    b = b.name(name.to_owned());
                }
                handles.push(b.spawn(move || {
                    no_materialize();
                    setup();
                    ENGINE_THREAD.set(true);
                    t.run()
                })?);
                Ok(())
            })
            .build();
        let threads = Joined(handles);
        Ok(Pool {
            pool: pool.map_err(io::Error::other)?,
            _threads: threads,
        })
    }

    pub fn install<R: Send>(&self, f: impl FnOnce() -> R + Send) -> R {
        self.pool.install(f)
    }

    pub fn spawn(&self, f: impl FnOnce() + Send + 'static) {
        self.pool.spawn(f);
    }

    #[cfg(test)]
    pub(crate) fn spawn_broadcast(&self, f: impl Fn() + Send + Sync + 'static) {
        self.pool.spawn_broadcast(move |_| f());
    }
}

#[cfg(test)]
pub(crate) type Hook = Arc<dyn Fn(&AtomicBool) + Send + Sync>;

#[cfg(test)]
thread_local! {
    pub(crate) static OPENED: RefCell<Option<Hook>> = const { RefCell::new(None) };
    pub(crate) static CUT: RefCell<Vec<(u64, u64, i32)>> = const { RefCell::new(Vec::new()) };
}

struct Ctx<'a> {
    next_id: AtomicU32,
    out: Mutex<Vec<Listing>>,
    failed: Mutex<Vec<u32>>,
    listed: AtomicU64,
    began: Instant,
    reported: AtomicU64,
    skip: &'a [PathBuf],
    stop: &'a AtomicBool,
    progress: &'a (dyn Fn(u64) + Sync),
    publishing: bool,
    #[cfg(test)]
    opened: Option<Hook>,
    #[cfg(test)]
    cut: Vec<(u64, u64, i32)>,
}

#[derive(Default)]
pub struct Crawl {
    pub listings: Vec<Listing>,
    pub failed: Vec<u32>,
}

thread_local! {
    static BUF: RefCell<Vec<u8>> = RefCell::new(vec![0u8; 256 * 1024]);
}

pub fn scan(
    pool: &Pool,
    root: OwnedFd,
    path: &Path,
    skip: &[PathBuf],
    stop: &AtomicBool,
    progress: &(dyn Fn(u64) + Sync),
    publish: Publish<'_>,
) -> Crawl {
    if blocked(skip, path) {
        return Crawl::default();
    }
    let ctx = Ctx {
        next_id: AtomicU32::new(1),
        out: Mutex::new(Vec::new()),
        failed: Mutex::new(Vec::new()),
        listed: AtomicU64::new(0),
        began: Instant::now(),
        reported: AtomicU64::new(0),
        skip,
        stop,
        progress,
        publishing: publish.is_some(),
        #[cfg(test)]
        opened: OPENED.take(),
        #[cfg(test)]
        cut: CUT.take(),
    };
    let mut l = Listing::default();
    ctx.list(root.as_raw_fd(), &mut l);
    let path = (!skip.is_empty()).then(|| path.to_path_buf());
    let mut published = thread::scope(|threads| {
        let (done, ended) = mpsc::channel();
        let publisher = publish.map(|publish| {
            let ctx = &ctx;
            threads.spawn(move || {
                no_materialize();
                ENGINE_THREAD.set(true);
                let (mut kept, mut total, mut published) = (Vec::new(), 0, false);
                loop {
                    let end = match ended.recv_timeout(Duration::from_millis(PROGRESS_GAP_MS)) {
                        Ok(()) => true,
                        Err(mpsc::RecvTimeoutError::Timeout) => false,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break kept,
                    };
                    let batch = std::mem::take(
                        &mut *ctx.out.lock().unwrap_or_else(PoisonError::into_inner),
                    );
                    if !batch.is_empty() && !ctx.stop.load(Ordering::Relaxed) && (!end || published)
                    {
                        total += batch.iter().map(|l| l.ents.len() as u64).sum::<u64>();
                        publish(&batch);
                        progress(total);
                        published = true;
                    }
                    kept.extend(batch);
                    if end {
                        break kept;
                    }
                }
            })
        });
        pool.pool.scope(|s| descend(s, root, path, l, &ctx));
        let _ = done.send(());
        publisher.map_or_else(Vec::new, |p| p.join().expect("crawl publisher panicked"))
    });
    published.extend(ctx.out.into_inner().unwrap_or_else(PoisonError::into_inner));
    Crawl {
        listings: published,
        failed: ctx
            .failed
            .into_inner()
            .unwrap_or_else(PoisonError::into_inner),
    }
}

pub fn blocked(skip: &[PathBuf], path: &Path) -> bool {
    skip.iter().any(|s| path.starts_with(s))
}

pub fn scan_path(pool: &Pool, path: &Path, skip: &[PathBuf], stop: &AtomicBool) -> Crawl {
    if blocked(skip, path) || is_mount(path) {
        return Crawl::default();
    }
    match open_dir(path) {
        Ok(fd) => scan(pool, fd, path, skip, stop, &|_| {}, None),
        Err(_) => Crawl::default(),
    }
}

pub fn scan_root(
    pool: &Pool,
    path: &Path,
    skip: &[PathBuf],
    stop: &AtomicBool,
    progress: &(dyn Fn(u64) + Sync),
    publish: Publish<'_>,
) -> io::Result<Crawl> {
    match open_dir(path) {
        Ok(fd) => Ok(scan(pool, fd, path, skip, stop, progress, publish)),
        Err(e) if out_of_files(&e) => Ok(Crawl {
            listings: Vec::new(),
            failed: vec![0],
        }),
        Err(e) => Err(e),
    }
}

fn out_of_files(e: &io::Error) -> bool {
    matches!(e.raw_os_error(), Some(libc::EMFILE | libc::ENFILE))
}

fn open_dir(path: &Path) -> io::Result<OwnedFd> {
    let path = CString::new(path.as_os_str().as_bytes())?;
    let fd = unsafe { libc::open(path.as_ptr(), OPEN_DIR) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

pub fn list_one(path: &Path) -> io::Result<Listing> {
    let fd = open_dir(path)?;
    let mut l = Listing::default();
    list_fd(fd.as_raw_fd(), &mut l)?;
    Ok(l)
}

pub fn is_mount(path: &Path) -> bool {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
    al.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    al.dirattr = libc::ATTR_DIR_MOUNTSTATUS;
    let mut buf = [0u32; 2];
    let r = unsafe {
        libc::getattrlist(
            path.as_ptr(),
            (&raw mut al).cast(),
            buf.as_mut_ptr().cast(),
            std::mem::size_of_val(&buf),
            libc::FSOPT_NOFOLLOW as _,
        )
    };
    r == 0 && buf[1] & (libc::DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
}

pub fn lstat(path: &Path) -> Option<Attrs> {
    let mut ents = Vec::new();
    recover(
        libc::AT_FDCWD,
        path.as_os_str().as_bytes(),
        &mut Vec::new(),
        &mut ents,
    );
    ents.first().map(RawEnt::attrs)
}

impl Ctx<'_> {
    fn list(&self, fd: i32, l: &mut Listing) {
        let listed = list_fd(fd, l);
        #[cfg(test)]
        let listed = self.injected(fd, l).map_or(listed, Err);
        if let Err(e) = listed {
            l.cut = !matches!(e.raw_os_error(), Some(libc::EACCES | libc::EPERM));
            self.fail(l.id, &e);
        }
    }

    #[cfg(test)]
    fn injected(&self, fd: i32, l: &mut Listing) -> Option<io::Error> {
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut st) } != 0 {
            return None;
        }
        let &(_, _, errno) = self
            .cut
            .iter()
            .find(|c| (c.0, c.1) == (st.st_dev as u64, st.st_ino))?;
        l.ents.truncate(1);
        Some(io::Error::from_raw_os_error(errno))
    }

    fn fail(&self, id: u32, e: &io::Error) {
        if out_of_files(e) {
            self.failed
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(id);
        }
    }

    fn count(&self, entries: usize) {
        if self.publishing {
            return;
        }
        let n = entries as u64;
        let total = self.listed.fetch_add(n, Ordering::Relaxed) + n;
        let now = self.began.elapsed().as_millis() as u64;
        let last = self.reported.load(Ordering::Relaxed);
        if now.saturating_sub(last) >= PROGRESS_GAP_MS
            && self
                .reported
                .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        {
            (self.progress)(total);
        }
    }
}

fn descend<'s>(
    s: &Scope<'s>,
    fd: OwnedFd,
    path: Option<PathBuf>,
    mut l: Listing,
    ctx: &'s Ctx<'s>,
) {
    let parent = Arc::new(fd);
    let mut kids = Vec::new();
    l.sort();
    for e in l.ents.iter_mut() {
        if e.kind != EngineKind::Folder || e.mount {
            continue;
        }
        let name = &l.names[e.name_off as usize..][..e.name_len as usize];
        let child_path = path.as_ref().map(|p| p.join(OsStr::from_bytes(name)));
        if child_path.as_deref().is_some_and(|p| blocked(ctx.skip, p)) {
            continue;
        }
        let Ok(name) = CString::new(name) else {
            continue;
        };
        e.child = ctx.next_id.fetch_add(1, Ordering::Relaxed);
        kids.push((name, e.child, child_path));
    }
    let (names, ents) = l.parts();
    names.shrink_to_fit();
    ents.shrink_to_fit();
    ctx.count(l.ents.len());
    ctx.out
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(l);
    for (name, id, child_path) in kids {
        let parent = parent.clone();
        s.spawn(move |s| {
            if ctx.stop.load(Ordering::Relaxed) {
                return;
            }
            let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), OPEN_DIR) };
            let opened = if fd < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(unsafe { OwnedFd::from_raw_fd(fd) })
            };
            drop(parent);
            let fd = match opened {
                Ok(fd) => fd,
                Err(e) => return ctx.fail(id, &e),
            };
            #[cfg(test)]
            if let Some(hook) = &ctx.opened {
                hook(ctx.stop);
            }
            let mut l = Listing {
                id,
                ..Listing::default()
            };
            ctx.list(fd.as_raw_fd(), &mut l);
            descend(s, fd, child_path, l, ctx);
        });
    }
}

fn rd32(b: &[u8], at: usize) -> u32 {
    u32::from_ne_bytes(b[at..at + 4].try_into().unwrap_or_default())
}

fn rd64(b: &[u8], at: usize) -> u64 {
    u64::from_ne_bytes(b[at..at + 8].try_into().unwrap_or_default())
}

fn attr_list() -> libc::attrlist {
    let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
    al.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    al.commonattr = libc::ATTR_CMN_RETURNED_ATTRS
        | libc::ATTR_CMN_NAME
        | libc::ATTR_CMN_OBJTYPE
        | libc::ATTR_CMN_CRTIME
        | libc::ATTR_CMN_ACCTIME
        | libc::ATTR_CMN_MODTIME
        | libc::ATTR_CMN_FLAGS;
    al.dirattr = libc::ATTR_DIR_MOUNTSTATUS;
    al.fileattr = libc::ATTR_FILE_DATALENGTH;
    al
}

fn list_fd(fd: i32, l: &mut Listing) -> io::Result<()> {
    no_atime();
    let (names, ents) = l.parts();
    let mut al = attr_list();
    al.commonattr |= ATTR_CMN_ERROR;
    BUF.with_borrow_mut(|buf| {
        loop {
            let n = unsafe {
                libc::getattrlistbulk(
                    fd,
                    (&raw mut al).cast(),
                    buf.as_mut_ptr().cast(),
                    buf.len(),
                    0,
                )
            };
            if n < 0 {
                return Err(io::Error::last_os_error());
            }
            if n == 0 {
                return Ok(());
            }
            let mut p = 0;
            for _ in 0..n {
                let len = rd32(buf, p) as usize;
                parse_entry(&buf[p..p + len], names, ents, fd);
                p += len;
            }
        }
    })
}

fn parse_entry(b: &[u8], names: &mut Vec<u8>, ents: &mut Vec<RawEnt>, dir: i32) {
    let common = rd32(b, 4);
    let dirattr = rd32(b, 12);
    let fileattr = rd32(b, 16);
    let mut f = 24;
    let mut err = 0;
    if common & ATTR_CMN_ERROR != 0 {
        err = rd32(b, f);
        f += 4;
    }
    if common & libc::ATTR_CMN_NAME == 0 {
        return;
    }
    let off = rd32(b, f) as i32 as isize;
    let nlen = rd32(b, f + 4) as usize;
    let start = (f as isize + off) as usize;
    let name = &b[start..start + nlen.saturating_sub(1)];
    f += 8;
    if err != 0 && common & libc::ATTR_CMN_OBJTYPE == 0 && recover(dir, name, names, ents) {
        return;
    }
    let mut kind = EngineKind::File;
    if common & libc::ATTR_CMN_OBJTYPE != 0 {
        kind = match rd32(b, f) {
            2 => EngineKind::Folder,
            5 => EngineKind::Link,
            _ => EngineKind::File,
        };
        f += 4;
    }
    let mut created = 0;
    if common & libc::ATTR_CMN_CRTIME != 0 {
        created = rd64(b, f) as i64;
        f += 16;
    }
    let mut mtime = 0;
    if common & libc::ATTR_CMN_MODTIME != 0 {
        mtime = rd64(b, f) as i64;
        f += 16;
    }
    let mut opened = 0;
    if common & libc::ATTR_CMN_ACCTIME != 0 {
        opened = rd64(b, f) as i64;
        f += 16;
    }
    let mut hidden = false;
    if common & libc::ATTR_CMN_FLAGS != 0 {
        hidden = rd32(b, f) & libc::UF_HIDDEN != 0;
        f += 4;
    }
    let mut mount = false;
    if dirattr & libc::ATTR_DIR_MOUNTSTATUS != 0 {
        mount = rd32(b, f) & (libc::DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0;
        f += 4;
    }
    let size = if fileattr & libc::ATTR_FILE_DATALENGTH == 0 {
        0
    } else {
        rd64(b, f)
    };
    if name.is_empty() || name.len() > u16::MAX as usize {
        return;
    }
    ents.push(RawEnt {
        name_off: names.len() as u32,
        name_len: name.len() as u16,
        kind,
        mount,
        hidden,
        size,
        mtime,
        created,
        opened,
        child: NONE,
    });
    names.extend_from_slice(name);
}

fn recover(dir: i32, name: &[u8], names: &mut Vec<u8>, ents: &mut Vec<RawEnt>) -> bool {
    let Ok(name) = CString::new(name) else {
        return false;
    };
    let mut al = attr_list();
    let mut buf = vec![0u8; 4096];
    let r = unsafe {
        libc::getattrlistat(
            dir,
            name.as_ptr(),
            (&raw mut al).cast(),
            buf.as_mut_ptr().cast(),
            buf.len(),
            libc::FSOPT_NOFOLLOW.into(),
        )
    };
    if r != 0 {
        return io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT);
    }
    let before = ents.len();
    parse_entry(&buf, names, ents, -1);
    ents.len() > before
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::index::Index;
    use std::collections::HashMap;
    use std::fs::{self, Permissions};
    use std::os::macos::fs::MetadataExt as _;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::time::Duration;

    pub(crate) struct TempTree(pub PathBuf);

    impl TempTree {
        pub(crate) fn new(name: &str) -> TempTree {
            let root =
                std::env::temp_dir().join(format!("wherever-core-{}-{name}", std::process::id()));
            let tree = TempTree(root);
            let _ = fs::remove_dir_all(tree.data());
            let root = &tree.0;
            let _ = fs::remove_dir_all(root);
            fs::create_dir_all(root.join("Sub")).unwrap();
            fs::write(root.join("Alpha.TXT"), b"hello").unwrap();
            fs::write(root.join("beta.txt"), b"").unwrap();
            fs::write(root.join("Gamma.md"), b"").unwrap();
            fs::write(root.join("Sub/DELTA.Txt"), b"").unwrap();
            std::os::unix::fs::symlink("Alpha.TXT", root.join("link")).unwrap();
            tree
        }

        pub(crate) fn root(&self) -> String {
            self.0.to_str().unwrap().to_owned()
        }

        pub(crate) fn real(&self) -> String {
            fs::canonicalize(&self.0)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned()
        }

        pub(crate) fn data(&self) -> PathBuf {
            PathBuf::from(format!("{}-data", self.0.display()))
        }
    }

    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
            let _ = fs::remove_dir_all(self.data());
        }
    }

    pub(crate) struct Locked(Vec<PathBuf>);

    impl Locked {
        pub(crate) fn new(paths: Vec<PathBuf>) -> Locked {
            for p in &paths {
                fs::set_permissions(p, Permissions::from_mode(0o000)).unwrap();
            }
            Locked(paths)
        }
    }

    impl Drop for Locked {
        fn drop(&mut self) {
            for p in &self.0 {
                let _ = fs::set_permissions(p, Permissions::from_mode(0o755));
            }
        }
    }

    pub(crate) fn crawl(tree: &TempTree, skip: &[PathBuf], stop: bool) -> Crawl {
        let pool = Pool::new(2).unwrap();
        let root = OwnedFd::from(fs::File::open(&tree.0).unwrap());
        scan(
            &pool,
            root,
            &tree.0,
            skip,
            &AtomicBool::new(stop),
            &|_| {},
            None,
        )
    }

    fn names(listings: &[Listing]) -> Vec<(String, EngineKind)> {
        let mut v: Vec<_> = listings
            .iter()
            .flat_map(|l| {
                l.ents
                    .iter()
                    .map(|e| (String::from_utf8(l.name(e).to_vec()).unwrap(), e.kind))
            })
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    fn find<'a>(listings: &'a [Listing], name: &str) -> (&'a Listing, &'a RawEnt) {
        listings
            .iter()
            .find_map(|l| {
                l.ents
                    .iter()
                    .find(|e| l.name(e) == name.as_bytes())
                    .map(|e| (l, e))
            })
            .unwrap()
    }

    #[test]
    fn scan_lists_every_name() {
        let tree = TempTree::new("crawl-all");
        let listings = crawl(&tree, &[], false).listings;
        let expected = [
            ("Alpha.TXT", EngineKind::File),
            ("DELTA.Txt", EngineKind::File),
            ("Gamma.md", EngineKind::File),
            ("Sub", EngineKind::Folder),
            ("beta.txt", EngineKind::File),
            ("link", EngineKind::Link),
        ];
        assert_eq!(names(&listings), expected.map(|(n, k)| (n.to_owned(), k)));
        assert_eq!(listings.len(), 2);
        let (root, alpha) = find(&listings, "Alpha.TXT");
        assert_eq!((root.id, alpha.size, alpha.child), (0, 5, NONE));
        assert!(alpha.mtime > 0);
        let (_, sub) = find(&listings, "Sub");
        let (inner, _) = find(&listings, "DELTA.Txt");
        assert_eq!(inner.id, sub.child);
    }

    fn entry(error: Option<u32>, objtype: Option<u32>, name: &str) -> Vec<u8> {
        let mut common = libc::ATTR_CMN_RETURNED_ATTRS | libc::ATTR_CMN_NAME;
        let mut body = Vec::new();
        if let Some(e) = error {
            common |= ATTR_CMN_ERROR;
            body.extend(e.to_ne_bytes());
        }
        let name_at = 24 + body.len() + 8 + 4 * usize::from(objtype.is_some());
        body.extend(((name_at - (24 + body.len())) as u32).to_ne_bytes());
        body.extend((name.len() as u32 + 1).to_ne_bytes());
        if let Some(t) = objtype {
            common |= libc::ATTR_CMN_OBJTYPE;
            body.extend(t.to_ne_bytes());
        }
        body.extend(name.as_bytes());
        body.push(0);
        let mut b = Vec::new();
        for w in [0, common, 0, 0, 0, 0] {
            b.extend(u32::to_ne_bytes(w));
        }
        b.extend(body);
        b.resize(b.len().next_multiple_of(8), 0);
        let len = b.len() as u32;
        b[..4].copy_from_slice(&len.to_ne_bytes());
        b
    }

    #[test]
    fn an_entry_with_an_error_keeps_its_real_kind() {
        let tree = TempTree::new("crawl-error");
        fs::create_dir(tree.0.join("Inner")).unwrap();
        let dir = fs::File::open(&tree.0).unwrap();
        let mut l = Listing::default();
        let (names, ents) = l.parts();
        parse_entry(
            &entry(Some(libc::EIO as u32), None, "Inner"),
            names,
            ents,
            dir.as_raw_fd(),
        );
        parse_entry(
            &entry(Some(libc::EIO as u32), None, "Gone"),
            names,
            ents,
            dir.as_raw_fd(),
        );
        assert_eq!(l.ents.len(), 1);
        let e = &l.ents[0];
        assert_eq!(l.name(e), b"Inner");
        assert_eq!(e.kind, EngineKind::Folder);
        assert_eq!(e.mtime, fs::metadata(tree.0.join("Inner")).unwrap().mtime());
        let mut l = Listing::default();
        let (names, ents) = l.parts();
        parse_entry(
            &entry(Some(libc::EIO as u32), None, "Inner"),
            names,
            ents,
            -1,
        );
        assert_eq!((l.ents[0].kind, l.ents[0].mtime), (EngineKind::File, 0));
    }

    #[test]
    fn an_entry_without_an_error_parses_as_before() {
        let mut l = Listing::default();
        let (names, ents) = l.parts();
        parse_entry(&entry(None, Some(2), "Inner"), names, ents, -1);
        parse_entry(
            &entry(Some(libc::EIO as u32), Some(2), "Kept"),
            names,
            ents,
            -1,
        );
        assert_eq!(l.ents.len(), 2);
        assert!(l.ents.iter().all(|e| e.kind == EngineKind::Folder));
    }

    #[test]
    fn only_running_out_of_files_is_recorded() {
        for (errno, short) in [
            (libc::EMFILE, true),
            (libc::ENFILE, true),
            (libc::EACCES, false),
            (libc::EPERM, false),
            (libc::ENOENT, false),
            (libc::ENOTDIR, false),
        ] {
            assert_eq!(
                out_of_files(&io::Error::from_raw_os_error(errno)),
                short,
                "errno {errno}"
            );
        }
    }

    #[test]
    fn scan_leaves_out_skipped_folders() {
        let tree = TempTree::new("crawl-skip");
        let listings = crawl(&tree, &[tree.0.join("Sub")], false).listings;
        let got: Vec<String> = names(&listings).into_iter().map(|(n, _)| n).collect();
        assert_eq!(got, ["Alpha.TXT", "Gamma.md", "Sub", "beta.txt", "link"]);
        assert_eq!(find(&listings, "Sub").1.child, NONE);
    }

    #[test]
    fn dropping_the_pool_joins_its_threads() {
        thread_local!(static MARK: RefCell<Option<Arc<()>>> = const { RefCell::new(None) });
        let pool = Pool::new(2).unwrap();
        let marker = Arc::new(());
        pool.pool
            .broadcast(|_| MARK.with(|m| *m.borrow_mut() = Some(marker.clone())));
        assert_eq!(Arc::strong_count(&marker), 3);
        drop(pool);
        assert_eq!(Arc::strong_count(&marker), 1);
    }

    unsafe extern "C" {
        fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
    }

    pub(crate) fn policy() -> libc::c_int {
        unsafe {
            getiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                IOPOL_SCOPE_THREAD,
            )
        }
    }

    pub(crate) fn atime_policy() -> libc::c_int {
        unsafe { getiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD) }
    }

    #[test]
    fn crawl_threads_never_download_placeholders() {
        let pool = Pool::new(2).unwrap();
        assert_eq!(
            pool.pool.broadcast(|_| policy()),
            [IOPOL_MATERIALIZE_DATALESS_FILES_OFF; 2]
        );
        assert_eq!(policy(), 0);
    }

    #[test]
    fn a_slow_crawl_reports_before_100k() {
        let tree = TempTree::new("crawl-slow");
        for i in 0..300 {
            fs::create_dir(tree.0.join(format!("d{i}"))).unwrap();
        }
        let pool = Pool::new(1).unwrap();
        OPENED.set(Some(Arc::new(|_| {
            thread::sleep(std::time::Duration::from_millis(2))
        })));
        let reports = AtomicU64::new(0);
        let root = OwnedFd::from(fs::File::open(&tree.0).unwrap());
        scan(
            &pool,
            root,
            &tree.0,
            &[],
            &AtomicBool::new(false),
            &|_| {
                reports.fetch_add(1, Ordering::Relaxed);
            },
            None,
        );
        assert!(reports.load(Ordering::Relaxed) >= 2);
    }

    #[test]
    fn a_crawl_publishes_its_last_folders_when_it_ends() {
        let tree = TempTree::new("crawl-last-batch");
        let first = Arc::new(AtomicBool::new(false));
        let seen = first.clone();
        OPENED.set(Some(Arc::new(move |_| {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !seen.load(Ordering::Relaxed) {
                assert!(Instant::now() < deadline, "nothing was published");
                thread::sleep(Duration::from_millis(1));
            }
        })));
        let published = Mutex::new(Vec::new());
        let publish = |batch: &[Listing]| {
            published.lock().unwrap().extend(batch.iter().map(|l| l.id));
            first.store(true, Ordering::Relaxed);
        };
        let pool = Pool::new(2).unwrap();
        let root = OwnedFd::from(fs::File::open(&tree.0).unwrap());
        let crawl = scan(
            &pool,
            root,
            &tree.0,
            &[],
            &AtomicBool::new(false),
            &|_| {},
            Some(&publish),
        );
        let mut listed: Vec<u32> = crawl.listings.iter().map(|l| l.id).collect();
        listed.sort();
        assert_eq!(listed, [0, 1]);
        let mut published = published.into_inner().unwrap();
        published.sort();
        assert_eq!(published, listed);
    }

    #[test]
    fn stop_lists_only_the_root() {
        let tree = TempTree::new("crawl-stop");
        let listings = crawl(&tree, &[], true).listings;
        assert_eq!(listings.len(), 1);
        assert_eq!(listings[0].id, 0);
        assert_eq!(listings[0].ents.len(), 5);
    }

    #[test]
    fn the_data_volume_has_an_fsevents_uuid() {
        use crate::fsevents::{device_uuid, open, sym};
        use std::ffi::c_void;
        let dev = fs::metadata(std::env::temp_dir()).unwrap().st_dev() as libc::dev_t;
        let uuid = device_uuid(dev).expect("FSEvents has no UUID for the Data volume");
        assert_eq!(uuid.len(), 36);
        let cf =
            open(c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation").unwrap();
        unsafe {
            let string: unsafe extern "C" fn(
                *const c_void,
                *const libc::c_char,
                u32,
            ) -> *const c_void = sym(cf, c"CFStringCreateWithCString").unwrap();
            let parse: unsafe extern "C" fn(*const c_void, *const c_void) -> *const c_void =
                sym(cf, c"CFUUIDCreateFromString").unwrap();
            let print: unsafe extern "C" fn(*const c_void, *const c_void) -> *const c_void =
                sym(cf, c"CFUUIDCreateString").unwrap();
            let equal: unsafe extern "C" fn(*const c_void, *const c_void) -> u8 =
                sym(cf, c"CFEqual").unwrap();
            let release: unsafe extern "C" fn(*const c_void) = sym(cf, c"CFRelease").unwrap();
            let text = CString::new(uuid).unwrap();
            let original = string(std::ptr::null(), text.as_ptr(), 0x0800_0100);
            let parsed = parse(std::ptr::null(), original);
            assert!(!parsed.is_null(), "CFUUIDCreateFromString refused the UUID");
            let again = print(std::ptr::null(), parsed);
            assert_ne!(
                equal(original, again),
                0,
                "the UUID does not parse back to itself"
            );
            for r in [original, parsed, again] {
                release(r);
            }
        }
    }

    fn probe_root() -> PathBuf {
        let root = std::env::var_os("WHEREVER_PROBE_ROOT")
            .expect("set WHEREVER_PROBE_ROOT to the folder to measure");
        PathBuf::from(root)
    }

    fn env_or(name: &str, default: &str) -> String {
        std::env::var(name).unwrap_or_else(|_| default.to_owned())
    }

    fn c_text(chars: &[libc::c_char]) -> String {
        let bytes: Vec<u8> = chars
            .iter()
            .take_while(|&&c| c != 0)
            .map(|&c| c as u8)
            .collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    fn first_folders(root: &Path, limit: usize) -> Vec<PathBuf> {
        let mut found = vec![root.to_path_buf()];
        let mut at = 0;
        while at < found.len() && found.len() < limit {
            let dir = found[at].clone();
            at += 1;
            let Ok(l) = list_one(&dir) else { continue };
            for e in l
                .ents
                .iter()
                .filter(|e| e.kind == EngineKind::Folder && !e.mount)
            {
                if found.len() < limit {
                    found.push(dir.join(OsStr::from_bytes(l.name(e))));
                }
            }
        }
        found
    }

    fn bulk(fd: i32, with_count: bool) -> Option<usize> {
        let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
        al.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
        al.commonattr = libc::ATTR_CMN_RETURNED_ATTRS
            | libc::ATTR_CMN_NAME
            | ATTR_CMN_ERROR
            | libc::ATTR_CMN_OBJTYPE
            | libc::ATTR_CMN_CRTIME
            | libc::ATTR_CMN_ACCTIME
            | libc::ATTR_CMN_MODTIME
            | libc::ATTR_CMN_FLAGS;
        al.dirattr = libc::ATTR_DIR_MOUNTSTATUS;
        if with_count {
            al.dirattr |= libc::ATTR_DIR_ENTRYCOUNT;
        }
        al.fileattr = libc::ATTR_FILE_DATALENGTH;
        let mut buf = vec![0u8; 256 * 1024];
        let mut total = 0;
        loop {
            let n = unsafe {
                libc::getattrlistbulk(
                    fd,
                    (&raw mut al).cast(),
                    buf.as_mut_ptr().cast(),
                    buf.len(),
                    0,
                )
            };
            match n {
                ..0 => return None,
                0 => return Some(total),
                n => total += n as usize,
            }
        }
    }

    fn mean_us(folders: &[PathBuf], f: impl Fn(&Path) -> Option<Duration>) -> (f64, usize) {
        folders.iter().for_each(|p| {
            f(p);
        });
        let times: Vec<Duration> = folders.iter().filter_map(|p| f(p)).collect();
        let total: Duration = times.iter().sum();
        (
            total.as_secs_f64() * 1e6 / times.len().max(1) as f64,
            times.len(),
        )
    }

    #[test]
    #[ignore = "reads the disk WHEREVER_PROBE_ROOT names"]
    fn measure_disk_crawl() {
        let root = probe_root();
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        assert_eq!(
            unsafe { libc::statfs(path.as_ptr(), &mut st) },
            0,
            "statfs failed"
        );
        println!(
            "statfs {}: f_fstypename {}, f_mntfromname {}, f_flags {:#x}",
            root.display(),
            c_text(&st.f_fstypename),
            c_text(&st.f_mntfromname),
            st.f_flags
        );
        let dev = fs::metadata(&root).unwrap().st_dev() as libc::dev_t;
        println!(
            "fsevents uuid: {}",
            crate::fsevents::device_uuid(dev).unwrap_or_else(|| "none".to_owned())
        );
        for n in env_or("WHEREVER_PROBE_THREADS", "16,8,4,2,1,1,2,4,8,16")
            .split(',')
            .map(|n| {
                n.trim()
                    .parse::<usize>()
                    .expect("WHEREVER_PROBE_THREADS is a comma list of counts")
            })
        {
            let pool = Pool::new(n).unwrap();
            let began = Instant::now();
            let crawl =
                scan_root(&pool, &root, &[], &AtomicBool::new(false), &|_| {}, None).unwrap();
            let secs = began.elapsed().as_secs_f64();
            let entries: usize = crawl.listings.iter().map(|l| l.ents.len()).sum();
            let folders = crawl.listings.len();
            let empty = crawl.listings.iter().filter(|l| l.ents.is_empty()).count();
            println!(
                "threads {n}: entries {entries}, folders {folders}, empty {empty} ({:.1}%), {secs:.2} s, {:.0} entries/s",
                empty as f64 * 100.0 / folders.max(1) as f64,
                entries as f64 / secs.max(1e-9)
            );
        }
        let folders = first_folders(&root, 2000);
        println!(
            "over the first {} folders, serial, after one warming pass:",
            folders.len()
        );
        let open_close = |p: &Path| {
            let t = Instant::now();
            let ok = open_dir(p).is_ok();
            ok.then(|| t.elapsed())
        };
        let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
        al.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
        al.dirattr = libc::ATTR_DIR_ENTRYCOUNT;
        let lookup = |p: &Path| {
            let p = CString::new(p.as_os_str().as_bytes()).ok()?;
            let mut buf = [0u32; 2];
            let t = Instant::now();
            let r = unsafe {
                libc::getattrlistat(
                    libc::AT_FDCWD,
                    p.as_ptr(),
                    (&raw const al).cast_mut().cast(),
                    buf.as_mut_ptr().cast(),
                    std::mem::size_of_val(&buf),
                    libc::FSOPT_NOFOLLOW as _,
                )
            };
            (r == 0).then(|| t.elapsed())
        };
        let (us, ok) = mean_us(&folders, open_close);
        println!("mean open+close: {us:.1} us ({ok} folders)");
        let (us, ok) = mean_us(&folders, lookup);
        println!("mean getattrlistat(ATTR_DIR_ENTRYCOUNT): {us:.1} us ({ok} folders)");
        for (label, with_count) in [("without", false), ("with", true)] {
            let (us, ok) = mean_us(&folders, |p| {
                let fd = open_dir(p).ok()?;
                let t = Instant::now();
                bulk(fd.as_raw_fd(), with_count)?;
                Some(t.elapsed())
            });
            println!(
                "mean getattrlistbulk listing {label} ATTR_DIR_ENTRYCOUNT: {us:.1} us ({ok} folders)"
            );
        }
    }

    #[test]
    #[ignore = "listens on the disk WHEREVER_PROBE_ROOT names"]
    fn measure_disk_events() {
        use crate::fsevents::Watcher;
        let root = probe_root();
        let secs: u64 = env_or("WHEREVER_PROBE_LISTEN", "10")
            .parse()
            .expect("WHEREVER_PROBE_LISTEN is seconds");
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher = Watcher::new(tx, Arc::default());
        let since = watcher.current_id().unwrap();
        watcher.watch(&root, since).unwrap();
        println!(
            "listening on {} for {secs} s from event id {since}",
            root.display()
        );
        let (began, mut seen) = (Instant::now(), 0);
        while let Some(left) = Duration::from_secs(secs).checked_sub(began.elapsed()) {
            let Ok(batch) = rx.recv_timeout(left) else {
                break;
            };
            for e in batch {
                seen += 1;
                println!(
                    "event id {}, flags {:#x}, {:.2} s: {}",
                    e.id,
                    e.flags,
                    began.elapsed().as_secs_f64(),
                    String::from_utf8_lossy(&e.path)
                );
            }
        }
        println!("events: {seen}");
    }

    fn probe_entries(c: &Crawl) -> HashMap<Vec<u8>, Attrs> {
        let by_id: HashMap<u32, &Listing> = c.listings.iter().map(|l| (l.id, l)).collect();
        let (mut out, mut stack) = (HashMap::new(), vec![(0, Vec::new())]);
        while let Some((id, dir)) = stack.pop() {
            let Some(l) = by_id.get(&id) else { continue };
            for e in &l.ents {
                let path = [dir.as_slice(), b"/", l.name(e)].concat();
                if e.child != NONE {
                    stack.push((e.child, path.clone()));
                }
                out.insert(path, e.attrs());
            }
        }
        out
    }

    fn probe_diff(replayed: &Crawl, fresh: &Crawl) -> [Vec<Vec<u8>>; 3] {
        let (a, b) = (probe_entries(replayed), probe_entries(fresh));
        let same = |x: &Attrs, y: &Attrs| Attrs { opened: 0, ..*x } == Attrs { opened: 0, ..*y };
        let mut d = [
            b.keys().filter(|k| !a.contains_key(*k)).cloned().collect(),
            a.keys().filter(|k| !b.contains_key(*k)).cloned().collect(),
            a.iter()
                .filter(|(k, x)| b.get(*k).is_some_and(|y| !same(x, y)))
                .map(|(k, _)| k.clone())
                .collect::<Vec<_>>(),
        ];
        d.iter_mut().for_each(|v| v.sort());
        d
    }

    struct ProbeDisk {
        dev: libc::dev_t,
        fs: String,
        flags: u32,
        no_log: Option<i32>,
        history: Option<String>,
        global: u64,
        last: u64,
    }

    fn probe_mount() -> PathBuf {
        fs::canonicalize(probe_root()).expect("WHEREVER_PROBE_ROOT does not exist")
    }

    fn probe_file() -> PathBuf {
        PathBuf::from(
            std::env::var_os("WHEREVER_PROBE_FILE")
                .expect("set WHEREVER_PROBE_FILE to the snapshot's path, outside the repository"),
        )
    }

    fn probe_disk(root: &Path) -> ProbeDisk {
        use std::time::{SystemTime, UNIX_EPOCH};
        let path = CString::new(root.as_os_str().as_bytes()).unwrap();
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { libc::statfs(path.as_ptr(), &mut st) },
            0,
            "statfs failed"
        );
        assert!(
            c_text(&st.f_mntonname).as_bytes() == root.as_os_str().as_bytes(),
            "WHEREVER_PROBE_ROOT must be the disk's mount point"
        );
        let dev = fs::symlink_metadata(root).unwrap().st_dev() as libc::dev_t;
        let unix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        let last = |t: f64| crate::fsevents::last_id_before(dev, t).unwrap();
        let (from_1970, from_2001, future) = (
            last(unix),
            last(unix - 978_307_200.0),
            last(4_102_444_800.0),
        );
        let d = ProbeDisk {
            dev,
            fs: c_text(&st.f_fstypename),
            flags: st.f_flags,
            no_log: fs::symlink_metadata(root.join(".fseventsd/no_log"))
                .err()
                .map(|e| e.raw_os_error().unwrap_or(0)),
            history: crate::fsevents::device_uuid(dev),
            global: crate::fsevents::Api::load().unwrap().current_id(),
            last: from_1970.max(from_2001),
        };
        println!("file system: {}", d.fs);
        println!("mount flags: {:#x}", d.flags);
        println!("local: {}", d.flags & libc::MNT_LOCAL as u32 != 0);
        println!("read-only: {}", d.flags & libc::MNT_RDONLY as u32 != 0);
        match fs::symlink_metadata(root.join(".fseventsd")) {
            Ok(m) => println!(".fseventsd mode: {:o}", m.mode()),
            Err(e) => println!(".fseventsd mode: none ({e})"),
        }
        match d.no_log {
            None => println!(".fseventsd/no_log: present"),
            Some(libc::ENOENT) => println!(".fseventsd/no_log: absent"),
            Some(n) => println!(".fseventsd/no_log: unreadable (errno {n})"),
        }
        println!("history uuid: {}", d.history.as_deref().unwrap_or("none"));
        println!("global id G: {}", d.global);
        println!("last id before now, counted from 1970: {from_1970}");
        println!("last id before now, counted from 2001: {from_2001}");
        println!("last id before 2100: {future}");
        println!("last id L: {}", d.last);
        d
    }

    fn probe_trust(d: &ProbeDisk, saved: &Index, saved_history: &str) -> Result<(), &'static str> {
        if !matches!(d.fs.as_str(), "apfs" | "hfs") {
            return Err("file system");
        }
        if d.flags & libc::MNT_LOCAL as u32 == 0 {
            return Err("not local");
        }
        if d.flags & libc::MNT_RDONLY as u32 != 0 {
            return Err("read-only");
        }
        match d.no_log {
            Some(libc::ENOENT) => {}
            None => return Err("no_log present"),
            Some(_) => return Err(".fseventsd unreadable"),
        }
        if saved.event_id() == 0 || !saved.skipped().is_empty() {
            return Err("saved id 0 or folders skipped");
        }
        let Some(history) = &d.history else {
            return Err("no history uuid");
        };
        if history != saved_history {
            return Err("new history uuid");
        }
        if d.last < saved.event_id() {
            return Err("device id below the saved id");
        }
        Ok(())
    }

    #[test]
    #[ignore = "crawls the disk WHEREVER_PROBE_ROOT names into WHEREVER_PROBE_FILE"]
    fn probe_disk_save() {
        let (root, file) = (probe_mount(), probe_file());
        let d = probe_disk(&root);
        let _ = raise_fd_limit();
        let synced_at = crate::engine::now_secs();
        let pool = Pool::new(crate::engine::CRAWL_THREADS).unwrap();
        let crawl = scan_root(&pool, &root, &[], &AtomicBool::new(false), &|_| {}, None).unwrap();
        println!("crawl folders: {}", crawl.listings.len());
        println!(
            "crawl entries: {}",
            crawl.listings.iter().map(|l| l.ents.len()).sum::<usize>()
        );
        println!("crawl folders out of descriptors: {}", crawl.failed.len());
        let print = format!("{}\0{}", d.history.as_deref().unwrap_or(""), d.global);
        let index = Index::build(crawl, root, print.as_bytes(), d.last, synced_at).unwrap();
        index.save(&file).unwrap();
        println!("saved id S: {}", d.last);
        println!("saved sync time: {synced_at}");
        println!("saved entries: {}", index.entries());
        if d.last == 0 {
            println!("warning: S is 0, so probe_disk_check cannot replay");
        }
    }

    fn device_path(root: &Path, raw: &[u8], absolute: &mut usize) -> Vec<u8> {
        let root = root.as_os_str().as_bytes();
        let raw = crate::live::normalize(raw);
        if raw == root || raw.starts_with(&[root, b"/"].concat()) {
            *absolute += 1;
            return raw;
        }
        let rel = raw.strip_prefix(b"/").unwrap_or(&raw);
        let mut p = root.to_vec();
        if !rel.is_empty() {
            if p.last() != Some(&b'/') {
                p.push(b'/');
            }
            p.extend_from_slice(rel);
        }
        p
    }

    fn print_ids(label: &str, ids: &[u64]) {
        match (ids.iter().min(), ids.iter().max()) {
            (Some(lo), Some(hi)) => println!("{label}: {}, ids {lo} to {hi}", ids.len()),
            _ => println!("{label}: 0"),
        }
    }

    fn print_diff(label: &str, d: &[Vec<Vec<u8>>; 3]) {
        println!(
            "{label}: missing {}, extra {}, changed {}",
            d[0].len(),
            d[1].len(),
            d[2].len()
        );
        let dot = d.iter().flatten().filter(|p| p.starts_with(b"/.")).count();
        println!("{label}, under a top-level dot name: {dot}");
    }

    #[test]
    #[ignore = "replays the disk WHEREVER_PROBE_ROOT names onto WHEREVER_PROBE_FILE"]
    fn probe_disk_check() {
        use crate::fsevents::{
            Api, EVENT_IDS_WRAPPED, HISTORY_DONE, KERNEL_DROPPED, MOUNT, MUST_SCAN_SUBDIRS,
            UNMOUNT, USER_DROPPED,
        };
        use crate::live::{Disk, Live};
        let (root, file) = (probe_mount(), probe_file());
        let d = probe_disk(&root);
        let index = Index::load(&file, root.clone()).expect("WHEREVER_PROBE_FILE does not load");
        let (s, synced_at) = (index.event_id(), index.synced_at());
        let print = String::from_utf8_lossy(index.fingerprint()).into_owned();
        let (saved_history, saved_global) =
            print.split_once('\0').unwrap_or((print.as_str(), "none"));
        println!("saved id S: {s}");
        println!("saved sync time: {synced_at}");
        println!("saved global id: {saved_global}");
        println!(
            "saved history uuid: {}",
            if saved_history.is_empty() {
                "none"
            } else {
                saved_history
            }
        );
        let trust = probe_trust(&d, &index, saved_history);
        match trust {
            Ok(()) => println!("trust rule: replay"),
            Err(why) => println!("trust rule: crawl ({why})"),
        }
        let _ = raise_fd_limit();
        let mut live = Live::new(Arc::new(index));
        let pool = Pool::new(crate::engine::CRAWL_THREADS).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        let markers =
            HISTORY_DONE | USER_DROPPED | KERNEL_DROPPED | MOUNT | UNMOUNT | EVENT_IDS_WRAPPED;
        let (mut done, mut lost, mut reached) = (false, false, false);
        if d.history.is_some() && s != 0 {
            let (tx, rx) = mpsc::channel();
            let stream = Api::load().unwrap().watch_device(d.dev, s, tx).unwrap();
            let (began, mut events) = (Instant::now(), Vec::new());
            while !done
                && let Some(left) = Duration::from_secs(120).checked_sub(began.elapsed())
                && let Ok(batch) = rx.recv_timeout(left)
            {
                done = batch.iter().any(|e| e.flags & HISTORY_DONE != 0);
                events.extend(batch);
            }
            drop(stream);
            println!("history done: {done}");
            println!("replay seconds: {:.2}", began.elapsed().as_secs_f64());
            let (mut seen, mut absolute) = (0, 0);
            let mut ids: HashMap<&str, Vec<u64>> = HashMap::new();
            let mut dirs: HashMap<Vec<u8>, bool> = HashMap::new();
            for e in &events {
                seen |= e.flags;
                let path = device_path(&root, &e.path, &mut absolute);
                let scan = e.flags & MUST_SCAN_SUBDIRS != 0;
                let at_root = scan && path == root.as_os_str().as_bytes();
                lost |= at_root || e.flags & EVENT_IDS_WRAPPED != 0;
                for (label, flag) in [
                    ("history done markers", HISTORY_DONE),
                    ("user drop markers", USER_DROPPED),
                    ("kernel drop markers", KERNEL_DROPPED),
                    ("mount markers", MOUNT),
                    ("unmount markers", UNMOUNT),
                    ("ids wrapped markers", EVENT_IDS_WRAPPED),
                ] {
                    if e.flags & flag != 0 {
                        ids.entry(label).or_default().push(e.id);
                    }
                }
                if at_root {
                    ids.entry("root must-scan markers").or_default().push(e.id);
                }
                if e.flags & markers != 0 || at_root {
                    continue;
                }
                ids.entry("other events").or_default().push(e.id);
                *dirs.entry(path).or_default() |= scan;
            }
            let other = ids.get("other events").map_or(&[][..], Vec::as_slice);
            reached = other.iter().any(|&id| id <= s);
            println!("events: {}", events.len());
            println!("flags seen: {seen:#x}");
            println!("event paths already absolute: {absolute}");
            for label in [
                "other events",
                "history done markers",
                "user drop markers",
                "kernel drop markers",
                "mount markers",
                "unmount markers",
                "ids wrapped markers",
                "root must-scan markers",
            ] {
                print_ids(label, ids.get(label).map_or(&[][..], Vec::as_slice));
            }
            println!("an event id at or below S: {reached}");
            match other.iter().max() {
                Some(hi) => println!("highest event id: {hi}"),
                None => println!("highest event id: none"),
            }
            println!("folders replayed: {}", dirs.len());
            for (path, recursive) in dirs {
                let f = live.fetch(&path, recursive, &disk);
                live.apply(f, &disk);
            }
        } else {
            println!("replay: skipped, no history uuid or S is 0");
        }
        let fresh = scan_root(&pool, &root, &[], &stop, &|_| {}, None).unwrap();
        println!(
            "fresh crawl folders out of descriptors: {}",
            fresh.failed.len()
        );
        print_diff(
            "after the replay",
            &probe_diff(&live.to_crawl().crawl, &fresh),
        );
        let began = Instant::now();
        let changed = live.changed_dirs(synced_at.saturating_sub(120) as i64, &disk);
        for path in &changed {
            let f = live.fetch(path, false, &disk);
            live.apply(f, &disk);
        }
        println!("check pass folders: {}", changed.len());
        println!("check pass seconds: {:.2}", began.elapsed().as_secs_f64());
        print_diff(
            "after the check pass",
            &probe_diff(&live.to_crawl().crawl, &fresh),
        );
        let verdict = match trust {
            Err(why) => format!("crawl ({why})"),
            Ok(()) if lost => "relist (the history lost the root or wrapped)".to_owned(),
            Ok(()) if !done => "unknown (no HistoryDone within 120 s)".to_owned(),
            Ok(()) if !reached => "relist (no event id at or below S)".to_owned(),
            Ok(()) => "replay".to_owned(),
        };
        println!("verdict: {verdict}");
    }

    #[test]
    fn the_probe_diff_counts_missing_extra_and_changed() {
        let tree = TempTree::new("probe-diff");
        let before = crawl(&tree, &[], false);
        assert!(probe_diff(&before, &before).iter().all(Vec::is_empty));
        fs::write(tree.0.join("new.txt"), b"").unwrap();
        fs::remove_file(tree.0.join("beta.txt")).unwrap();
        fs::write(tree.0.join("Sub/DELTA.Txt"), b"longer").unwrap();
        let after = crawl(&tree, &[], false);
        let paths = |p: &str| vec![p.as_bytes().to_vec()];
        assert_eq!(
            probe_diff(&before, &after),
            [
                paths("/new.txt"),
                paths("/beta.txt"),
                paths("/Sub/DELTA.Txt")
            ]
        );
    }
}
