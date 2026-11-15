use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use super::detect::{Stamp, reopen, resolved};
use super::pkg::Origin;
use super::tar::Kind;
use super::write::{self, Destinations, RESERVE, Space, Task};
use super::{
    ArchiveProblem, ArchiveSummary, EXTENSIONS, Entry, Failure, Format, Source, bsdtar, guard,
};
use crate::EngineKind;
use crate::crawl::Attrs;

pub(super) struct Order<'a> {
    pub names: &'a [String],
    pub folder: &'a Path,
    pub whole: bool,
    pub shown_as: &'a str,
    pub list: &'a Path,
    pub staging: &'a str,
    pub summary: &'a ArchiveSummary,
}

struct Member<'a> {
    name: &'a [u8],
    kind: Kind,
    target: Option<&'a [u8]>,
}

type Kept = Vec<(String, u64, u32, (i64, i64))>;

#[cfg(test)]
pub(super) type Staged = (std::path::PathBuf, Vec<u8>, Vec<String>);

#[cfg(test)]
pub(super) static STAGED: Mutex<Vec<Staged>> = Mutex::new(Vec::new());

#[cfg(test)]
fn staged(dir: &Path, rel: &str, out: &mut Vec<String>) {
    for item in fs::read_dir(dir).into_iter().flatten().flatten() {
        let rel = joined(rel, &item.file_name()).unwrap();
        out.push(rel.clone());
        if item.file_type().is_ok_and(|t| t.is_dir()) {
            staged(&item.path(), &rel, out);
        }
    }
}

fn suffix(name: &str) -> usize {
    let bytes = name.as_bytes();
    EXTENSIONS
        .iter()
        .filter(|ext| {
            let at = bytes.len().wrapping_sub(ext.len() + 1);
            bytes.len() > ext.len() + 1
                && bytes[at] == b'.'
                && bytes[at + 1..].eq_ignore_ascii_case(ext.as_bytes())
        })
        .map(|ext| ext.len() + 1)
        .max()
        .or_else(|| {
            name.rfind('.')
                .filter(|&at| at > 0)
                .map(|at| name.len() - at)
        })
        .unwrap_or(0)
}

pub(super) fn container(name: &str) -> &str {
    &name[..name.len() - suffix(name)]
}

pub(super) fn numbered(name: &str, folder: bool, n: u32) -> String {
    if n == 1 {
        return name.to_owned();
    }
    let (stem, ext) = name.split_at(name.len() - if folder { 0 } else { suffix(name) });
    format!("{stem} {n}{ext}")
}

pub(super) fn inside(path: &str, top: &str) -> bool {
    path.strip_prefix(top)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

pub(super) fn unexpanded(source: &Source, picked: &[String], whole: bool) -> bool {
    let Format::Pkg(pkg) = &*source.format else {
        return false;
    };
    pkg.expanded.is_none()
        && pkg.members.iter().any(|m| {
            m.origin == Origin::Expands
                && guard::name(&String::from_utf8_lossy(&m.name)).is_some_and(|path| {
                    whole
                        || picked
                            .iter()
                            .any(|top| inside(&path, top) || inside(top, &path))
                })
        })
}

pub(super) fn trimmed(spelling: &[u8]) -> &[u8] {
    let mut end = spelling.len();
    while end > 1 && spelling[end - 1] == b'/' {
        end -= 1;
    }
    &spelling[..end]
}

fn joined(rel: &str, name: &OsStr) -> io::Result<String> {
    let name = name
        .to_str()
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
    Ok(if rel.is_empty() {
        name.to_owned()
    } else {
        format!("{rel}/{name}")
    })
}

fn c(path: &Path) -> io::Result<CString> {
    Ok(CString::new(path.as_os_str().as_bytes())?)
}

fn checked(result: libc::c_int) -> io::Result<()> {
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn chmod(path: &CStr, mode: u32) -> io::Result<()> {
    checked(unsafe {
        libc::fchmodat(
            libc::AT_FDCWD,
            path.as_ptr(),
            mode as libc::mode_t,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    })
}

fn mark(path: &CStr, value: &[u8]) -> io::Result<()> {
    if value.is_empty() {
        return Ok(());
    }
    checked(unsafe {
        libc::setxattr(
            path.as_ptr(),
            c"com.apple.quarantine".as_ptr(),
            value.as_ptr().cast(),
            value.len(),
            0,
            libc::XATTR_NOFOLLOW,
        )
    })
}

fn dated(path: &CStr, (seconds, nanos): (i64, i64)) -> io::Result<()> {
    let times = [
        libc::timespec {
            tv_sec: 0,
            tv_nsec: libc::UTIME_OMIT,
        },
        libc::timespec {
            tv_sec: seconds,
            tv_nsec: nanos,
        },
    ];
    checked(unsafe {
        libc::utimensat(
            libc::AT_FDCWD,
            path.as_ptr(),
            times.as_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    })
}

fn folder(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
        .open(path)
}

fn taken(dir: &File, name: &CStr) -> io::Result<bool> {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe {
        libc::fstatat(
            dir.as_raw_fd(),
            name.as_ptr(),
            &mut stat,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0
    {
        return Ok(true);
    }
    let e = io::Error::last_os_error();
    if e.kind() == io::ErrorKind::NotFound {
        Ok(false)
    } else {
        Err(e)
    }
}

fn remove(path: &Path) -> io::Result<()> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    if !meta.is_dir() {
        return fs::remove_file(path);
    }
    chmod(&c(path)?, 0o700)?;
    for item in fs::read_dir(path)? {
        remove(&item?.path())?;
    }
    fs::remove_dir(path)
}

fn place(from: &File, name: &str, to: &File, wanted: &str, is_folder: bool) -> io::Result<String> {
    let source = CString::new(name)?;
    let mut n = 1;
    loop {
        let candidate = numbered(wanted, is_folder, n);
        let target = CString::new(candidate.as_str())?;
        let moved = unsafe {
            libc::renameatx_np(
                from.as_raw_fd(),
                source.as_ptr(),
                to.as_raw_fd(),
                target.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        if moved == 0 {
            return Ok(candidate);
        }
        let e = io::Error::last_os_error();
        match e.raw_os_error() {
            Some(libc::EEXIST) => {}
            Some(libc::ENOTSUP) if !taken(to, &target)? => {
                checked(unsafe {
                    libc::renameat(
                        from.as_raw_fd(),
                        source.as_ptr(),
                        to.as_raw_fd(),
                        target.as_ptr(),
                    )
                })?;
                return Ok(candidate);
            }
            Some(libc::ENOTSUP) => {}
            _ => return Err(e),
        }
        n += 1;
    }
}

fn opened(path: &Path, rel: &str, kept: &mut Kept) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        return Ok(());
    }
    chmod(&c(path)?, meta.mode() & 0o777 | 0o700)?;
    kept.push((
        rel.to_owned(),
        meta.ino(),
        meta.mode() & 0o777,
        (meta.mtime(), meta.mtime_nsec()),
    ));
    for item in fs::read_dir(path)? {
        let item = item?;
        if item.file_type()?.is_dir() {
            opened(&item.path(), &joined(rel, &item.file_name())?, kept)?;
        }
    }
    Ok(())
}

fn guarded(
    root: &File,
    base: &Path,
    rel: &str,
    value: &[u8],
    skipped: &mut u64,
) -> Result<(), Failure> {
    let path = base.join(rel);
    let name = c(&path)?;
    let meta = fs::symlink_metadata(&path)?;
    let kind = meta.file_type();
    if kind.is_dir() {
        for item in fs::read_dir(&path)? {
            guarded(
                root,
                base,
                &joined(rel, &item?.file_name())?,
                value,
                skipped,
            )?;
        }
        mark(&name, value)?;
    } else if kind.is_symlink() {
        let target = fs::read_link(&path)?;
        let stays = match target.to_str() {
            Some(target) => match write::link_inside(root, rel, target) {
                Ok(()) => true,
                Err(Failure::Problem(_)) => false,
                Err(failure) => return Err(failure),
            },
            None => false,
        };
        if stays {
            mark(&name, value)?;
        } else {
            fs::remove_file(&path)?;
            *skipped += 1;
        }
    } else if kind.is_file() {
        let mode = meta.mode() & 0o7777;
        if !value.is_empty() || mode & 0o7000 != 0 {
            chmod(&name, mode & 0o777 | 0o200)?;
            mark(&name, value)?;
            chmod(&name, mode & 0o777)?;
        }
    } else {
        fs::remove_file(&path)?;
        *skipped += 1;
    }
    Ok(())
}

fn dropped(staging: &Path, path: &str) -> io::Result<()> {
    let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
    let dir = match folder(&staging.join(parent)) {
        Ok(dir) => dir,
        Err(e)
            if matches!(
                e.raw_os_error(),
                Some(libc::ENOENT | libc::ELOOP | libc::ENOTDIR)
            ) =>
        {
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    let name = CString::new(name)?;
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe {
        libc::fstatat(
            dir.as_raw_fd(),
            name.as_ptr(),
            &mut stat,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        let e = io::Error::last_os_error();
        return if e.kind() == io::ErrorKind::NotFound {
            Ok(())
        } else {
            Err(e)
        };
    }
    if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
        return Ok(());
    }
    checked(unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) })
}

fn judged(stderr: &[u8], listed: &HashMap<Vec<u8>, String>) -> Result<Vec<String>, ArchiveProblem> {
    if stderr.len() >= bsdtar::KEPT {
        return Err(ArchiveProblem::Damaged);
    }
    let mut failed = Vec::new();
    for line in stderr.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
        if line == b"tar: Error exit delayed from previous errors." {
            continue;
        }
        let named = if line.starts_with(b"tar: ") {
            None
        } else {
            (0..line.len().saturating_sub(1))
                .rev()
                .filter(|&at| &line[at..at + 2] == b": ")
                .find_map(|at| listed.get(trimmed(&bsdtar::unescape(&line[..at]))))
        };
        match named {
            Some(path) => failed.push(path.clone()),
            None => return Err(bsdtar::problem(stderr, false)),
        }
    }
    failed.sort();
    failed.dedup();
    Ok(failed)
}

#[allow(clippy::too_many_arguments)]
fn untar(
    source: &Source,
    members: &[Member],
    spelling: &[Vec<u8>],
    wanted: &[&Entry],
    staging: &Path,
    list: &Path,
    task: &Task,
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<String>, Failure> {
    let safe = |name: &[u8]| guard::name(&String::from_utf8_lossy(name));
    let mut paths: HashSet<String> = wanted.iter().map(|e| e.path.clone()).collect();
    let targets: Vec<String> = members
        .iter()
        .filter(|m| m.kind == Kind::HardLink && safe(m.name).is_some_and(|p| paths.contains(&p)))
        .filter_map(|m| m.target.and_then(safe))
        .collect();
    paths.extend(targets);
    let mut listed: HashMap<Vec<u8>, String> = HashMap::new();
    let mut patterns = Vec::new();
    for (member, spelled) in members.iter().zip(spelling) {
        let Some(path) = safe(member.name).filter(|p| paths.contains(p)) else {
            continue;
        };
        let spelled = trimmed(spelled);
        if member.kind != Kind::Special && listed.insert(spelled.to_vec(), path).is_none() {
            patterns.extend(bsdtar::pattern(spelled));
            patterns.push(0);
        }
    }
    if listed.is_empty() {
        return Ok(Vec::new());
    }
    if let Some(parent) = list.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(list, &patterns)?;
    let outcome = (|| -> Result<Vec<String>, Failure> {
        let archive = reopen(&source.path, source.stamp)?;
        let watch = archive.try_clone()?;
        let size = watch.metadata()?.len().max(1);
        let mut command = bsdtar::command(bsdtar::TAR);
        command
            .args(["-x", "-f", "/dev/fd/3", "-C"])
            .arg(staging)
            .args(["--passphrase", bsdtar::PLACEHOLDER, "--null", "-n", "-T"])
            .arg(list);
        let mut child = bsdtar::spawn(command, Some(archive))?;
        task.advance(0);
        let status = child.watch(cancelled, || {
            let at = unsafe { libc::lseek(watch.as_raw_fd(), 0, libc::SEEK_CUR) };
            let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
            let total = p.job.total_bytes;
            let done = (u128::from(total) * u128::from(at.max(0) as u64) / u128::from(size))
                .min(u128::from(total)) as u64;
            p.job.done_bytes = p.job.done_bytes.max(done);
        })?;
        #[cfg(test)]
        {
            let mut found = Vec::new();
            staged(staging, "", &mut found);
            found.sort();
            STAGED
                .lock()
                .unwrap()
                .push((source.path.clone(), patterns.clone(), found));
        }
        if Stamp::read(&watch)? != source.stamp {
            return Err(ArchiveProblem::Changed.into());
        }
        if status.success() {
            return Ok(Vec::new());
        }
        judged(&child.stderr(), &listed).map_err(Failure::from)
    })();
    let _ = fs::remove_file(list);
    outcome
}

fn fresh(path: &str, mtime: i64) -> Entry {
    Entry {
        path: path.to_owned(),
        index: None,
        attrs: Attrs {
            kind: EngineKind::Folder,
            size: 0,
            mtime,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        },
        mode: 0o755,
        target: None,
        encrypted: false,
        sized: true,
        disk: None,
    }
}

#[allow(clippy::too_many_arguments)]
fn copied(
    source: &Source,
    wanted: &[(&Entry, usize)],
    from_disk: bool,
    staging: &Path,
    password: &Mutex<Vec<u8>>,
    task: &Task,
    closed: &AtomicBool,
    free: fn(&File) -> io::Result<Space>,
) -> Result<(), Failure> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let have: HashSet<&str> = wanted
        .iter()
        .filter(|(e, _)| e.real())
        .map(|(e, _)| e.path.as_str())
        .collect();
    let picked: Vec<&(&Entry, usize)> = wanted
        .iter()
        .filter(|(e, _)| !from_disk || e.disk.is_some())
        .collect();
    let mut made = HashSet::new();
    let mut folders = Vec::new();
    for (e, floor) in &picked {
        let path = e.path.as_str();
        for (at, _) in path.match_indices('/').filter(|(at, _)| at >= floor) {
            if !have.contains(&path[..at]) && made.insert(&path[..at]) {
                folders.push(fresh(&path[..at], now));
            }
        }
        if !e.real() && made.insert(path) {
            folders.push(fresh(path, now));
        }
    }
    let list: Vec<&Entry> = picked
        .iter()
        .map(|(e, _)| *e)
        .filter(|e| e.real())
        .chain(folders.iter())
        .collect();
    write::write(
        source,
        &list,
        staging,
        false,
        password,
        task,
        closed,
        free,
        &Destinations::default(),
    )
}

pub(super) fn run(
    source: &Source,
    order: &Order,
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
    for name in order.names.iter().filter(|_| !order.whole) {
        picked.push(
            guard::name(name)
                .ok_or_else(|| ArchiveProblem::PointsOutside { name: name.clone() })?,
        );
    }
    let mut summary = order.summary.clone();
    let local;
    let source = if unexpanded(source, &picked, order.whole) {
        let (next, expanded) = super::payload(source, &summary, free, &cancelled)?;
        summary = expanded;
        local = next;
        &local
    } else {
        source
    };
    for (top, name) in picked.iter().zip(order.names) {
        if !source.entries.iter().any(|e| inside(&e.path, top)) {
            return Err(ArchiveProblem::Gone { name: name.clone() }.into());
        }
    }
    if source.entries.is_empty() {
        return Err(ArchiveProblem::Empty.into());
    }
    let mut tops = picked;
    tops.sort();
    tops.dedup();
    tops = tops
        .iter()
        .filter(|t| !tops.iter().any(|o| o != *t && inside(t, o)))
        .cloned()
        .collect();
    let rar = matches!(*source.format, Format::Rar(_));
    let mut skipped = if order.whole { summary.skipped } else { 0 };
    let mut wanted = Vec::new();
    for e in &source.entries {
        let floor = if order.whole {
            0
        } else {
            match tops.iter().find(|t| inside(&e.path, t)) {
                Some(top) => top.len(),
                None => continue,
            }
        };
        if rar && e.encrypted {
            skipped += 1;
            continue;
        }
        wanted.push((e, floor));
    }
    if let Format::Tar(members) = &*source.format {
        let safe = |name: &[u8]| guard::name(&String::from_utf8_lossy(name));
        let kept: HashSet<&str> = source
            .entries
            .iter()
            .filter(|e| e.index.is_some())
            .map(|e| e.path.as_str())
            .collect();
        let archived: HashSet<&str> = wanted
            .iter()
            .filter(|(e, _)| e.index.is_some())
            .map(|(e, _)| e.path.as_str())
            .collect();
        for m in members.iter().filter(|m| {
            m.kind == Kind::HardLink && safe(&m.name).is_some_and(|p| archived.contains(p.as_str()))
        }) {
            if let Some(target) = m.target.as_deref().and_then(safe)
                && !kept.contains(target.as_str())
            {
                return Err(ArchiveProblem::LinkedItem { name: target }.into());
            }
        }
    }
    if order.whole {
        tops = wanted
            .iter()
            .map(|(e, _)| e.path.split('/').next().unwrap_or_default().to_owned())
            .collect();
        tops.sort();
        tops.dedup();
    }
    let total = wanted
        .iter()
        .filter(|(e, _)| e.attrs.kind == EngineKind::File)
        .try_fold(0u64, |n, (e, _)| n.checked_add(e.attrs.size))
        .ok_or(ArchiveProblem::Damaged)?;
    {
        let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
        p.job.total_bytes = total;
        p.job.total_items = wanted.len() as u64;
    }
    let base = resolved(order.folder);
    let destination = folder(&base)?;
    let available = free(&destination)?;
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
    let listed = match &*source.format {
        Format::Tar(members) => Some((
            members
                .iter()
                .map(|m| Member {
                    name: &m.name,
                    kind: m.kind,
                    target: m.target.as_deref(),
                })
                .collect::<Vec<_>>(),
            Arc::new(bsdtar::spelling(
                &source.path,
                source.stamp,
                members.len(),
                &cancelled,
            )?),
        )),
        Format::Rar(archive) => Some((
            archive
                .members
                .iter()
                .map(|m| Member {
                    name: &m.name,
                    kind: m.kind,
                    target: m.target.as_deref(),
                })
                .collect(),
            archive.spelling(&source.path, source.stamp, &cancelled)?,
        )),
        Format::Zip(_) | Format::Pkg(_) | Format::Image(_) => None,
    };
    let staging_name = CString::new(order.staging).map_err(io::Error::from)?;
    checked(unsafe { libc::mkdirat(destination.as_raw_fd(), staging_name.as_ptr(), 0o700) })?;
    let staging = base.join(order.staging);
    let outcome = (|| -> Result<(Vec<String>, u64), Failure> {
        let failed = match &listed {
            Some((rows, spelling)) => {
                let archived: Vec<&Entry> = wanted
                    .iter()
                    .map(|(e, _)| *e)
                    .filter(|e| e.index.is_some())
                    .collect();
                let failed = untar(
                    source, rows, spelling, &archived, &staging, order.list, task, &cancelled,
                )?;
                if wanted.iter().any(|(e, _)| e.disk.is_some()) {
                    let totals = {
                        let p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
                        (p.job.total_bytes, p.job.total_items)
                    };
                    let copied = copied(
                        source, &wanted, true, &staging, password, task, closed, free,
                    );
                    let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
                    (p.job.total_bytes, p.job.total_items) = totals;
                    drop(p);
                    copied?;
                }
                failed
            }
            None => {
                copied(
                    source, &wanted, false, &staging, password, task, closed, free,
                )?;
                Vec::new()
            }
        };
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let mut kept = Kept::new();
        opened(&staging, "", &mut kept)?;
        for path in &failed {
            dropped(&staging, path)?;
        }
        skipped += failed.len() as u64;
        let boxed = order.whole && tops.len() > 1;
        let mut units = Vec::new();
        if boxed {
            for item in fs::read_dir(&staging)? {
                units.push((String::new(), joined("", &item?.file_name())?));
            }
        } else {
            for top in &tops {
                if fs::symlink_metadata(staging.join(top)).is_ok() {
                    let (parent, name) = top.rsplit_once('/').unwrap_or(("", top));
                    units.push((parent.to_owned(), name.to_owned()));
                }
            }
        }
        for (parent, name) in &units {
            let at = staging.join(parent);
            guarded(&folder(&at)?, &at, name, &source.quarantine, &mut skipped)?;
        }
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let mut stamps = Vec::new();
        let mut written = Vec::new();
        if boxed {
            let shown = Path::new(order.shown_as)
                .file_name()
                .or_else(|| source.path.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let name = place(
                &destination,
                order.staging,
                &destination,
                container(&shown),
                true,
            )?;
            let landed = base.join(&name);
            for (rel, _, mode, time) in kept.iter().filter(|(rel, ..)| !rel.is_empty()) {
                stamps.push((landed.join(rel), *mode, *time));
            }
            let path = c(&landed)?;
            mark(&path, &source.quarantine)?;
            chmod(&path, 0o755)?;
            written.push(order.folder.join(&name).to_string_lossy().into_owned());
        } else {
            for (parent, name) in &units {
                let unit = if parent.is_empty() {
                    name.clone()
                } else {
                    format!("{parent}/{name}")
                };
                let meta = match fs::symlink_metadata(staging.join(&unit)) {
                    Ok(meta) => meta,
                    Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                    Err(e) => return Err(e.into()),
                };
                let is_folder = meta.is_dir();
                let on_disk = kept
                    .iter()
                    .find(|k| k.1 == meta.ino())
                    .map_or(unit.as_str(), |k| k.0.as_str());
                let landed_name = place(
                    &folder(&staging.join(parent))?,
                    name,
                    &destination,
                    name,
                    is_folder,
                )?;
                let landed = base.join(&landed_name);
                for (rel, _, mode, time) in &kept {
                    if let Some(rest) = rel.strip_prefix(on_disk) {
                        if rest.is_empty() {
                            stamps.push((landed.clone(), *mode, *time));
                        } else if let Some(rest) = rest.strip_prefix('/') {
                            stamps.push((landed.join(rest), *mode, *time));
                        }
                    }
                }
                written.push(
                    order
                        .folder
                        .join(&landed_name)
                        .to_string_lossy()
                        .into_owned(),
                );
            }
            remove(&staging)?;
        }
        stamps.sort_by_key(|(path, ..)| std::cmp::Reverse(path.components().count()));
        for (path, mode, time) in stamps {
            let path = c(&path)?;
            chmod(&path, mode)?;
            dated(&path, time)?;
        }
        Ok((written, failed.len() as u64))
    })();
    let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
    p.job.skipped = skipped;
    match outcome {
        Ok((written, failures)) => {
            if rar || matches!(*source.format, Format::Tar(_)) {
                p.job.done_bytes = p.job.total_bytes;
                p.job.done_items = p.job.total_items.saturating_sub(failures);
            }
            p.job.written = written;
            Ok(())
        }
        Err(failure) => {
            p.job.written.clear();
            drop(p);
            let _ = remove(&staging);
            Err(failure)
        }
    }
}
