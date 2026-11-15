use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};

use super::expand::{inside, numbered};
use super::write::{CHUNK, RESERVE, Space, Task};
use super::{
    ArchiveChange, ArchiveClash, ArchiveEditing, ArchiveProblem, Entry, Failure, Format, Source,
    detect, guard, tar, zip,
};
use crate::EngineKind;
use crate::crawl::Attrs;

#[derive(Clone)]
pub(super) enum Change {
    Delete(String),
    Add { disk: PathBuf, path: String },
}

pub(super) fn parsed(changes: &[ArchiveChange]) -> Option<Vec<Change>> {
    changes
        .iter()
        .map(|change| match change {
            ArchiveChange::Delete { path } => guard::name(path).map(Change::Delete),
            ArchiveChange::Add {
                source,
                folder,
                name,
            } => {
                let folder = if folder.is_empty() {
                    String::new()
                } else {
                    guard::name(folder)?
                };
                let single =
                    !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\0']);
                (single && source.starts_with('/') && !source.contains('\0')).then(|| Change::Add {
                    disk: PathBuf::from(source),
                    path: if folder.is_empty() {
                        name.clone()
                    } else {
                        format!("{folder}/{name}")
                    },
                })
            }
        })
        .collect()
}

fn deleted(changes: &[Change]) -> Vec<&str> {
    changes
        .iter()
        .filter_map(|change| match change {
            Change::Delete(path) => Some(path.as_str()),
            Change::Add { .. } => None,
        })
        .collect()
}

#[cfg(test)]
pub(super) static STALL: Mutex<Vec<(PathBuf, bool)>> = Mutex::new(Vec::new());

fn walked(
    disk: &Path,
    path: &str,
    out: &mut Vec<Entry>,
    skipped: &mut Vec<Vec<u8>>,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut stack = vec![(disk.to_path_buf(), path.to_owned())];
    while let Some((disk, path)) = stack.pop() {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        #[cfg(test)]
        loop {
            let mut stall = STALL.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(at) = stall.iter().position(|(p, _)| *p == disk) else {
                break;
            };
            stall[at].1 = true;
            drop(stall);
            if cancelled() {
                return Err(Failure::Stopped);
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let gone = |_| ArchiveProblem::Gone {
            name: disk.to_string_lossy().into_owned(),
        };
        let meta = fs::symlink_metadata(&disk).map_err(gone)?;
        let shape = meta.file_type();
        let (kind, target) = if shape.is_dir() {
            (EngineKind::Folder, None)
        } else if shape.is_file() {
            (EngineKind::File, None)
        } else if shape.is_symlink() {
            match fs::read_link(&disk)
                .map_err(gone)?
                .into_os_string()
                .into_string()
            {
                Ok(target) => (EngineKind::Link, Some(target)),
                Err(_) => {
                    skipped.push(path.into_bytes());
                    continue;
                }
            }
        } else {
            skipped.push(path.into_bytes());
            continue;
        };
        if kind == EngineKind::Folder {
            let mut children = Vec::new();
            for item in fs::read_dir(&disk).map_err(gone)? {
                let item = item.map_err(gone)?;
                match item.file_name().into_string() {
                    Ok(name) => children.push((item.path(), format!("{path}/{name}"))),
                    Err(name) => skipped.push([path.as_bytes(), b"/", name.as_bytes()].concat()),
                }
            }
            children.sort_by(|a, b| b.1.cmp(&a.1));
            stack.extend(children);
        }
        out.push(Entry {
            attrs: Attrs {
                kind,
                size: match kind {
                    EngineKind::File => meta.len(),
                    EngineKind::Link => target.as_ref().map_or(0, |t| t.len() as u64),
                    _ => 0,
                },
                mtime: meta.mtime(),
                created: 0,
                opened: 0,
                mount: false,
                hidden: super::hidden(&path),
            },
            path,
            index: None,
            mode: meta.mode() & 0o777,
            target,
            encrypted: false,
            sized: true,
            disk: Some(disk),
        });
    }
    Ok(())
}

pub(super) fn struck(gone: &HashSet<&str>, path: &str) -> bool {
    gone.contains(path)
        || path
            .match_indices('/')
            .any(|(at, _)| gone.contains(&path[..at]))
}

pub(super) fn view(
    base: &Source,
    changes: &[Change],
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<Entry>, Failure> {
    let deleted: HashSet<&str> = deleted(changes).into_iter().collect();
    let mut entries: Vec<Entry> = base
        .entries
        .iter()
        .filter(|e| e.index.is_some() && !struck(&deleted, &e.path))
        .cloned()
        .collect();
    let kept = entries.len();
    let tar = matches!(*base.format, Format::Tar(_));
    for change in changes {
        if let Change::Add { disk, path } = change {
            let from = entries.len();
            walked(disk, path, &mut entries, &mut Vec::new(), cancelled)?;
            let floor = path.rfind('/').map_or(0, |at| at + 1);
            let walked = entries.split_off(from);
            entries.extend(
                walked
                    .into_iter()
                    .filter(|e| !tar || !e.path[floor..].split('/').any(|c| c.starts_with("._"))),
            );
        }
    }
    let links: HashMap<String, String> = entries
        .iter()
        .filter_map(|e| Some((e.path.clone(), e.target.clone()?)))
        .collect();
    let mut at = 0;
    entries.retain(|e| {
        at += 1;
        at <= kept
            || e.target
                .as_ref()
                .is_none_or(|to| guard::target(&e.path, to, &links).is_some())
    });
    Ok(entries)
}

fn folded(name: &str) -> String {
    crate::query::fold(&crate::query::nfd(name).unwrap_or_else(|| name.to_owned()))
}

pub(super) fn clashes(entries: &[Entry], folder: &str, names: &[String]) -> Vec<ArchiveClash> {
    let children: HashMap<String, &Entry> = entries
        .iter()
        .filter_map(|e| {
            let (parent, leaf) = e.path.rsplit_once('/').unwrap_or(("", &e.path));
            (parent == folder).then(|| (folded(leaf), e))
        })
        .collect();
    let mut taken: HashSet<String> = children
        .keys()
        .cloned()
        .chain(names.iter().map(|n| folded(n)))
        .collect();
    let mut dropped: HashMap<String, String> = HashMap::new();
    names
        .iter()
        .filter_map(|name| {
            let key = folded(name);
            let (existing, folder) = match (children.get(&key), dropped.get(&key)) {
                (Some(child), _) => (child.path.clone(), child.attrs.kind == EngineKind::Folder),
                (None, Some(earlier)) => (earlier.clone(), false),
                (None, None) => {
                    let path = if folder.is_empty() {
                        name.clone()
                    } else {
                        format!("{folder}/{name}")
                    };
                    dropped.insert(key, path);
                    return None;
                }
            };
            let free_name = (2..)
                .map(|n| numbered(name, folder, n))
                .find(|candidate| taken.insert(folded(candidate)))?;
            Some(ArchiveClash {
                name: name.clone(),
                existing,
                folder,
                free_name,
            })
        })
        .collect()
}

struct Secret(Vec<u8>);

impl Drop for Secret {
    fn drop(&mut self) {
        super::wipe(&mut self.0);
    }
}

struct Written<'a> {
    path: &'a Path,
    keep: bool,
}

impl Drop for Written<'_> {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_file(self.path);
        }
    }
}

pub(super) struct Order<'a> {
    pub base: &'a Source,
    pub changes: &'a [Change],
    pub editing: ArchiveEditing,
    pub aes: bool,
    pub out: &'a Path,
    pub work: &'a Path,
}

fn copied(
    base: &Source,
    mut out: &File,
    size: u64,
    task: &Task,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut buffer = vec![0; CHUNK];
    let mut at = 0;
    while at < size {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let want = buffer.len().min((size - at) as usize);
        let n = base.reader.file.read_at(&mut buffer[..want], at)?;
        if n == 0 {
            return Err(ArchiveProblem::Changed.into());
        }
        out.write_all(&buffer[..n])?;
        at += n as u64;
        task.advance(n as u64);
    }
    Ok(())
}

pub(super) fn write(
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
    let base = order.base;
    detect::reopen(&base.path, base.stamp)?;
    let edited = !order.changes.is_empty();
    if edited {
        match order.editing {
            ArchiveEditing::OldEncryption => return Err(ArchiveProblem::OldEncryption.into()),
            ArchiveEditing::None => return Err(ArchiveProblem::Unsupported.into()),
            ArchiveEditing::All => {}
        }
    }
    let (zip, members) = match &*base.format {
        Format::Zip(zip) => (Some(zip), None),
        Format::Tar(members) => (None, Some(members)),
        _ if edited => return Err(ArchiveProblem::Unsupported.into()),
        _ => (None, None),
    };
    let entries = if edited {
        view(base, order.changes, &cancelled)?
    } else {
        Vec::new()
    };
    let added: Vec<&Entry> = entries.iter().filter(|e| e.disk.is_some()).collect();
    let files = added.iter().any(|e| e.attrs.kind == EngineKind::File);
    let secret = Secret(if order.aes && files {
        password
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    } else {
        Vec::new()
    });
    if order.aes && files && secret.0.is_empty() {
        return Err(ArchiveProblem::PasswordNeeded.into());
    }
    let gone = deleted(order.changes);
    let kept = match (zip, members) {
        (Some(zip), _) if edited => zip::kept(zip, &gone)?,
        (_, Some(members)) if edited => {
            let mut kept: Vec<(usize, String)> = members
                .iter()
                .enumerate()
                .filter_map(|(at, m)| {
                    guard::name(&String::from_utf8_lossy(&m.name))
                        .filter(|path| !gone.iter().any(|top| inside(path, top)))
                        .map(|path| (at, path))
                })
                .collect();
            kept.sort_by(|a, b| a.1.cmp(&b.1));
            kept.dedup_by(|a, b| a.1 == b.1);
            kept
        }
        _ => Vec::new(),
    };
    let mut expected: Vec<&str> = kept
        .iter()
        .map(|(_, path)| path.as_str())
        .chain(added.iter().map(|e| e.path.as_str()))
        .collect();
    expected.sort_unstable();
    if let Some(pair) = expected.windows(2).find(|pair| pair[0] == pair[1]) {
        return Err(ArchiveProblem::Duplicate {
            name: pair[0].to_owned(),
        }
        .into());
    }
    let size = base.reader.file.metadata()?.len();
    let adding = added
        .iter()
        .filter(|e| e.attrs.kind == EngineKind::File)
        .try_fold(0u64, |n, e| n.checked_add(e.attrs.size))
        .ok_or(ArchiveProblem::Damaged)?;
    let parent = order.out.parent().ok_or(ArchiveProblem::Damaged)?;
    let available = free(&File::open(parent)?)?;
    let needed = size
        .saturating_add(adding)
        .saturating_add(RESERVE)
        .saturating_sub(available.bytes);
    if needed > 0 {
        return Err(ArchiveProblem::NoSpace {
            needed,
            volume: available.volume,
        }
        .into());
    }
    {
        let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
        p.job.total_bytes = if edited {
            size.saturating_add(adding)
        } else {
            size
        };
        p.job.total_items = if edited { expected.len() as u64 } else { 1 };
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(order.out)?;
    let mut written = Written {
        path: order.out,
        keep: false,
    };
    match (zip, members) {
        (Some(zip), _) if edited => zip::rewrite(
            zip,
            &kept,
            &added,
            &file,
            (!secret.0.is_empty()).then_some(secret.0.as_slice()),
            task,
            &cancelled,
        )?,
        (_, Some(members)) if edited => {
            let adds: Vec<(&Path, &str)> = order
                .changes
                .iter()
                .filter_map(|change| match change {
                    Change::Add { disk, path } => Some((disk.as_path(), path.as_str())),
                    Change::Delete(_) => None,
                })
                .collect();
            let mut every = Vec::new();
            let mut hidden = Vec::new();
            for (disk, path) in &adds {
                walked(disk, path, &mut every, &mut hidden, &cancelled)?;
            }
            let shown: HashSet<&str> = added.iter().map(|e| e.path.as_str()).collect();
            hidden.extend(
                every
                    .into_iter()
                    .filter(|e| !shown.contains(e.path.as_str()))
                    .map(|e| e.path.into_bytes()),
            );
            tar::rewrite(
                &base.reader,
                &base.path,
                base.stamp,
                &tar::Edit {
                    members,
                    deleted: &gone,
                    adds: &adds,
                    added: &added,
                    hidden: &hidden,
                    work: order.work,
                },
                order.out,
                &file,
                task,
                &cancelled,
            )?
        }
        _ => copied(base, &file, size, task, &cancelled)?,
    }
    file.sync_all()?;
    if edited && zip.is_some() {
        let mut names = zip::names(order.out)?;
        names.sort_unstable();
        let got: Vec<&str> = names.iter().map(String::as_str).collect();
        if got != expected {
            let at = got
                .iter()
                .zip(&expected)
                .take_while(|(a, b)| a == b)
                .count();
            let name = expected
                .get(at)
                .or(got.get(at))
                .copied()
                .unwrap_or_default();
            return Err(ArchiveProblem::Duplicate { name: name.into() }.into());
        }
    }
    detect::reopen(&base.path, base.stamp)?;
    if cancelled() {
        return Err(Failure::Stopped);
    }
    written.keep = true;
    let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
    p.job.done_items = p.job.total_items;
    p.job.written.push(order.out.to_string_lossy().into_owned());
    Ok(())
}
