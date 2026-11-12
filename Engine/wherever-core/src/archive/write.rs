use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, TryLockError};

use super::detect::Stamp;
use super::{ArchiveJob, ArchiveProblem, ArchiveSummary, Entry, Failure, Format, Source, guard};
use crate::EngineKind;

pub(super) const RESERVE: u64 = 1 << 30;
pub(super) const CHUNK: usize = 64 * 1024;
type Identity = (u64, u64);
type Owned = HashMap<String, Identity>;
pub(crate) type Destinations = Mutex<HashMap<(Stamp, Identity), Arc<Mutex<Owned>>>>;

fn identity(file: &File) -> io::Result<Identity> {
    let m = file.metadata()?;
    Ok((m.dev(), m.ino()))
}

fn writable(
    file: &File,
    path: &str,
    made: bool,
    owned: &mut Owned,
    visited: &mut Owned,
) -> io::Result<()> {
    let id = identity(file)?;
    if made {
        owned.insert(path.into(), id);
    }
    if owned.get(path) == Some(&id) {
        visited.insert(path.into(), id);
        file.set_permissions(std::fs::Permissions::from_mode(
            file.metadata()?.mode() & 0o777 | 0o700,
        ))?;
    }
    Ok(())
}

pub(super) struct Space {
    pub bytes: u64,
    pub volume: String,
}

pub(super) struct Task {
    pub stop: AtomicBool,
    pub progress: Mutex<Progress>,
    #[cfg(test)]
    pub hold: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
}

pub(super) struct Progress {
    pub job: ArchiveJob,
    pub error: Option<String>,
}

impl Task {
    pub fn new() -> Self {
        Self {
            stop: AtomicBool::new(false),
            progress: Mutex::new(Progress {
                job: ArchiveJob {
                    done_bytes: 0,
                    total_bytes: 0,
                    done_items: 0,
                    total_items: 0,
                    finished: false,
                    problem: None,
                    written: Vec::new(),
                    skipped: 0,
                },
                error: None,
            }),
            #[cfg(test)]
            hold: Mutex::new(None),
        }
    }

    pub fn finish(&self, outcome: Result<(), Failure>) {
        let mut p = self.progress.lock().unwrap_or_else(PoisonError::into_inner);
        match outcome {
            Err(Failure::Problem(problem)) => p.job.problem = Some(problem),
            Err(Failure::Io(e)) => p.error = Some(e.to_string()),
            _ => {}
        }
        p.job.finished = true;
    }

    pub fn advance(&self, bytes: u64) {
        self.progress
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .job
            .done_bytes += bytes;
        #[cfg(test)]
        if let Some((reached, release)) = self.hold.lock().unwrap().take() {
            let _ = reached.send(());
            let _ = release.recv();
        }
    }
}

pub(super) fn space(file: &File) -> io::Result<Space> {
    let mut stat: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatfs(file.as_raw_fd(), &mut stat) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mount = unsafe { CStr::from_ptr(stat.f_mntonname.as_ptr()) }.to_string_lossy();
    let volume = Path::new(mount.as_ref())
        .file_name()
        .map_or_else(|| mount.to_string(), |s| s.to_string_lossy().into_owned());
    Ok(Space {
        bytes: stat.f_bavail.saturating_mul(stat.f_bsize as u64),
        volume,
    })
}

pub(super) fn read_quarantine(file: &File) -> io::Result<Vec<u8>> {
    let name = c"com.apple.quarantine";
    let n = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            name.as_ptr(),
            std::ptr::null_mut(),
            0,
            0,
            0,
        )
    };
    if n < 0 {
        let e = io::Error::last_os_error();
        return if e.raw_os_error() == Some(libc::ENOATTR) {
            Ok(Vec::new())
        } else {
            Err(e)
        };
    }
    let mut bytes = vec![0; n as usize];
    let read = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            name.as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            0,
            0,
        )
    };
    if read < 0 {
        return Err(io::Error::last_os_error());
    }
    bytes.truncate(read as usize);
    Ok(bytes)
}

pub(super) fn quarantine(file: &File, bytes: &[u8]) -> io::Result<()> {
    if !bytes.is_empty()
        && unsafe {
            libc::fsetxattr(
                file.as_raw_fd(),
                c"com.apple.quarantine".as_ptr(),
                bytes.as_ptr().cast(),
                bytes.len(),
                0,
                0,
            )
        } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub(super) fn directory(parent: &File, name: &CStr) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_EVTONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn parent(
    root: &File,
    path: &str,
    owned: &mut Owned,
    visited: &mut Owned,
) -> io::Result<(File, CString)> {
    let mut folder = root.try_clone()?;
    let mut parts = path.split('/').peekable();
    let mut inner = String::new();
    while let Some(part) = parts.next() {
        let name = CString::new(part)?;
        if parts.peek().is_none() {
            return Ok((folder, name));
        }
        if !inner.is_empty() {
            inner.push('/');
        }
        inner.push_str(part);
        let made = unsafe { libc::mkdirat(folder.as_raw_fd(), name.as_ptr(), 0o700) } == 0;
        if !made {
            let e = io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::EEXIST) {
                return Err(e);
            }
        }
        folder = directory(&folder, &name)?;
        writable(&folder, &inner, made, owned, visited)?;
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        "empty archive path",
    ))
}

struct Partial {
    parent: File,
    name: CString,
    keep: bool,
}

impl Drop for Partial {
    fn drop(&mut self) {
        if !self.keep {
            unsafe { libc::unlinkat(self.parent.as_raw_fd(), self.name.as_ptr(), 0) };
        }
    }
}

fn mark<'a>(source: &'a Source, entry: &Entry) -> &'a [u8] {
    if entry.disk.is_some() {
        &[]
    } else {
        &source.quarantine
    }
}

fn stamp(file: &File, entry: &Entry, read_only: bool, quarantine_value: &[u8]) -> io::Result<()> {
    quarantine(file, quarantine_value)?;
    let mode = if read_only && entry.attrs.kind != EngineKind::Folder {
        0o444
    } else {
        entry.mode
    };
    file.set_permissions(std::fs::Permissions::from_mode(mode))?;
    let times = [
        libc::timespec {
            tv_sec: 0,
            tv_nsec: libc::UTIME_OMIT,
        },
        libc::timespec {
            tv_sec: entry.attrs.mtime,
            tv_nsec: 0,
        },
    ];
    if unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub(super) fn link_inside(root: &File, path: &str, target: &str) -> Result<(), Failure> {
    let outside = || ArchiveProblem::PointsOutside { name: path.into() };
    let mut queue: VecDeque<_> = path
        .rsplit_once('/')
        .map_or(String::new(), |(p, _)| format!("{p}/"))
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|s| (s.to_owned(), None))
        .collect();
    queue.extend(target.split('/').map(|s| (s.to_owned(), None)));
    let mut parents = vec![Some(root.try_clone()?)];
    let mut active = HashSet::new();
    while let Some((part, finish)) = queue.pop_front() {
        if let Some(key) = finish {
            active.remove(&key);
            continue;
        }
        match part.as_str() {
            "" | "." => continue,
            ".." => {
                if parents.len() == 1 {
                    return Err(outside().into());
                }
                parents.pop();
                continue;
            }
            _ => {}
        }
        let name = CString::new(part.as_str()).map_err(|_| outside())?;
        let Some(parent) = parents.last().unwrap() else {
            parents.push(None);
            continue;
        };
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                &mut stat,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::NotFound {
                return Err(e.into());
            }
            parents.push(None);
            continue;
        }
        if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
            let key = (stat.st_dev, stat.st_ino);
            if !active.insert(key) {
                return Err(outside().into());
            }
            let mut bytes = vec![0; libc::PATH_MAX as usize];
            let n = unsafe {
                libc::readlinkat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    bytes.as_mut_ptr().cast(),
                    bytes.len(),
                )
            };
            if n < 0 {
                return Err(io::Error::last_os_error().into());
            }
            if n as usize == bytes.len() {
                return Err(outside().into());
            }
            bytes.truncate(n as usize);
            let link = String::from_utf8(bytes).map_err(|_| outside())?;
            if link.starts_with('/') {
                return Err(outside().into());
            }
            queue.push_front((String::new(), Some(key)));
            for part in link.split('/').rev() {
                queue.push_front((part.into(), None));
            }
        } else {
            let more = queue
                .iter()
                .any(|(s, f)| f.is_none() && !s.is_empty() && s != ".");
            parents.push(if more {
                Some(directory(parent, &name)?)
            } else {
                None
            });
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn run(
    source: &Source,
    summary: &ArchiveSummary,
    entries: &[String],
    folder: &Path,
    read_only: bool,
    password: &Mutex<Vec<u8>>,
    task: &Task,
    closed: &AtomicBool,
    free: fn(&File) -> io::Result<Space>,
) -> Result<(), Failure> {
    let cancelled = || task.stop.load(Ordering::Relaxed) || closed.load(Ordering::Relaxed);
    if cancelled() {
        return Err(Failure::Stopped);
    }
    if Stamp::read(&source.reader.file)? != source.stamp {
        return Err(ArchiveProblem::Changed.into());
    }
    let mut picked = Vec::new();
    for name in entries {
        picked.push(
            guard::name(name)
                .ok_or_else(|| ArchiveProblem::PointsOutside { name: name.clone() })?,
        );
    }
    let local;
    let source = if super::expand::unexpanded(source, &picked, false) {
        local = super::payload(source, summary, free, &cancelled)?.0;
        &local
    } else {
        source
    };
    let mut seen = HashSet::new();
    let mut tops = HashSet::new();
    let mut selected = Vec::new();
    for (safe, name) in picked.iter().zip(entries) {
        let entry = source
            .entries
            .iter()
            .find(|e| &e.path == safe)
            .ok_or_else(|| ArchiveProblem::Gone { name: name.clone() })?;
        if entry.attrs.kind == EngineKind::Folder {
            tops.insert(entry.path.as_str());
        }
        if seen.insert(entry.path.as_str()) {
            selected.push(entry);
        }
    }
    if !tops.is_empty() {
        for e in &source.entries {
            if super::edit::struck(&tops, &e.path) && seen.insert(e.path.as_str()) {
                selected.push(e);
            }
        }
    }
    write(
        source,
        &selected,
        folder,
        read_only,
        password,
        task,
        closed,
        free,
        &source.destinations,
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn write(
    source: &Source,
    selected: &[&Entry],
    folder: &Path,
    read_only: bool,
    password: &Mutex<Vec<u8>>,
    task: &Task,
    closed: &AtomicBool,
    free: fn(&File) -> io::Result<Space>,
    destinations: &Destinations,
) -> Result<(), Failure> {
    let cancelled = || task.stop.load(Ordering::Relaxed) || closed.load(Ordering::Relaxed);
    let mut selected = selected.to_vec();
    if let Format::Tar(members) = &*source.format {
        selected.sort_by_key(|e| e.index.and_then(|i| members.get(i)).map(|m| m.offset));
    }
    let total = selected
        .iter()
        .try_fold(0u64, |n, e| n.checked_add(e.attrs.size))
        .ok_or(ArchiveProblem::Damaged)?;
    {
        let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
        p.job.total_bytes = total;
        p.job.total_items = selected.len() as u64;
    }
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
        .open(super::detect::resolved(folder))?;
    let available = free(&root)?;
    let needed = total
        .saturating_add(RESERVE)
        .saturating_sub(available.bytes);
    if needed > 0 {
        return Err(ArchiveProblem::NoSpace {
            needed,
            volume: available.volume,
        }
        .into());
    }
    let destination = destinations
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .entry((source.stamp, identity(&root)?))
        .or_default()
        .clone();
    let mut owned = loop {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        match destination.try_lock() {
            Ok(lock) => break lock,
            Err(TryLockError::Poisoned(e)) => break e.into_inner(),
            Err(TryLockError::WouldBlock) => {
                std::thread::sleep(std::time::Duration::from_millis(5))
            }
        }
    };
    let mut zip = match &*source.format {
        Format::Zip(zip) => Some(zip.clone()),
        _ => None,
    };
    let mut stream = None;
    let mut visited = HashMap::new();
    let outcome = (|| {
        for &entry in &selected {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            if entry.encrypted {
                if let Format::Rar(_) = *source.format {
                    return Err(ArchiveProblem::Encrypted.into());
                }
                if password
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .is_empty()
                {
                    return Err(ArchiveProblem::PasswordNeeded.into());
                }
            }
            let damaged = || {
                if entry.encrypted {
                    ArchiveProblem::WrongPassword
                } else {
                    ArchiveProblem::Damaged
                }
            };
            let (parent, name) = parent(&root, &entry.path, &mut owned, &mut visited)?;
            let mut partial = Partial {
                parent,
                name,
                keep: true,
            };
            match entry.attrs.kind {
                EngineKind::Folder => {
                    let made = unsafe {
                        libc::mkdirat(partial.parent.as_raw_fd(), partial.name.as_ptr(), 0o700)
                    } == 0;
                    if !made {
                        let e = io::Error::last_os_error();
                        if e.raw_os_error() != Some(libc::EEXIST) {
                            return Err(e.into());
                        }
                    }
                    let file = directory(&partial.parent, &partial.name)?;
                    writable(&file, &entry.path, made, &mut owned, &mut visited)?;
                }
                EngineKind::Link => {
                    let unlocked;
                    let target = match &entry.target {
                        Some(target) => target,
                        None if entry.encrypted => {
                            let mut bytes = Vec::new();
                            source
                                .contents(
                                    entry,
                                    &mut zip,
                                    &mut stream,
                                    &password.lock().unwrap_or_else(PoisonError::into_inner),
                                    &cancelled,
                                )?
                                .take(libc::PATH_MAX as u64 + 1)
                                .read_to_end(&mut bytes)
                                .map_err(|_| damaged())?;
                            unlocked = String::from_utf8(bytes)
                                .ok()
                                .filter(|s| s.len() <= libc::PATH_MAX as usize)
                                .ok_or_else(|| ArchiveProblem::PointsOutside {
                                    name: entry.path.clone(),
                                })?;
                            &unlocked
                        }
                        None => return Err(ArchiveProblem::Damaged.into()),
                    };
                    link_inside(&root, &entry.path, target)?;
                    let to = CString::new(target.as_str()).map_err(|_| ArchiveProblem::Damaged)?;
                    if unsafe {
                        libc::symlinkat(
                            to.as_ptr(),
                            partial.parent.as_raw_fd(),
                            partial.name.as_ptr(),
                        )
                    } != 0
                    {
                        partial.keep = true;
                        return Err(io::Error::last_os_error().into());
                    }
                    partial.keep = false;
                    if !mark(source, entry).is_empty() {
                        let fd = unsafe {
                            libc::openat(
                                partial.parent.as_raw_fd(),
                                partial.name.as_ptr(),
                                libc::O_SYMLINK | libc::O_RDONLY | libc::O_CLOEXEC,
                            )
                        };
                        if fd < 0 {
                            return Err(io::Error::last_os_error().into());
                        }
                        quarantine(&unsafe { File::from_raw_fd(fd) }, mark(source, entry))?;
                    }
                    task.advance(entry.attrs.size);
                }
                EngineKind::File => {
                    let mut input = source.contents(
                        entry,
                        &mut zip,
                        &mut stream,
                        &password.lock().unwrap_or_else(PoisonError::into_inner),
                        &cancelled,
                    )?;
                    let fd = unsafe {
                        libc::openat(
                            partial.parent.as_raw_fd(),
                            partial.name.as_ptr(),
                            libc::O_WRONLY
                                | libc::O_CREAT
                                | libc::O_EXCL
                                | libc::O_NOFOLLOW
                                | libc::O_CLOEXEC,
                            0o600,
                        )
                    };
                    if fd < 0 {
                        partial.keep = true;
                        return Err(io::Error::last_os_error().into());
                    }
                    partial.keep = false;
                    let mut output = unsafe { File::from_raw_fd(fd) };
                    let mut buffer = [0; CHUNK];
                    let mut written = 0;
                    loop {
                        if cancelled() {
                            return Err(Failure::Stopped);
                        }
                        let n = input.read(&mut buffer).map_err(|e| {
                            if cancelled() {
                                Failure::Stopped
                            } else {
                                e.get_ref()
                                    .and_then(|e| e.downcast_ref::<ArchiveProblem>())
                                    .cloned()
                                    .unwrap_or_else(damaged)
                                    .into()
                            }
                        })?;
                        if n == 0 {
                            break;
                        }
                        written += n as u64;
                        if entry.sized && written > entry.attrs.size {
                            return Err(damaged().into());
                        }
                        let available = free(&output)?;
                        let needed = (n as u64)
                            .saturating_add(RESERVE)
                            .saturating_sub(available.bytes);
                        if needed > 0 {
                            return Err(ArchiveProblem::NoSpace {
                                needed,
                                volume: available.volume,
                            }
                            .into());
                        }
                        output.write_all(&buffer[..n])?;
                        task.advance(n as u64);
                    }
                    if entry.sized && written != entry.attrs.size {
                        return Err(damaged().into());
                    }
                    stamp(&output, entry, read_only, mark(source, entry))?;
                }
            }
            if cancelled() {
                return Err(Failure::Stopped);
            }
            if Stamp::read(&source.reader.file)? != source.stamp {
                return Err(ArchiveProblem::Changed.into());
            }
            partial.keep = true;
            let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
            p.job.done_items += 1;
            p.job.written.push(
                PathBuf::from(folder)
                    .join(&entry.path)
                    .to_string_lossy()
                    .into_owned(),
            );
        }
        Ok(())
    })();
    let restored = (|| {
        let folders: HashMap<&str, &Entry> = source
            .entries
            .iter()
            .chain(selected.iter().copied())
            .filter(|e| e.attrs.kind == EngineKind::Folder)
            .map(|e| (e.path.as_str(), e))
            .collect();
        let mut visited: Vec<_> = visited.into_iter().collect();
        visited.sort_by_key(|(path, _)| std::cmp::Reverse(path.matches('/').count()));
        for (path, id) in visited {
            let mut folder = root.try_clone()?;
            for part in path.split('/') {
                folder = directory(&folder, &CString::new(part)?)?;
            }
            if identity(&folder)? != id {
                return Err(io::Error::other("archive destination changed"));
            }
            if let Some(entry) = folders.get(path.as_str()) {
                stamp(&folder, entry, false, mark(source, entry))?;
            }
        }
        Ok(())
    })();
    outcome.and(restored.map_err(Failure::Io))
}
