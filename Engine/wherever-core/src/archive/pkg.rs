use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Cursor, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use quick_xml::Reader;
use quick_xml::events::Event;

use super::detect::{Stamp, reopen, resolved};
use super::tar::Kind;
use super::write::{RESERVE, Space};
use super::{ArchiveProblem, Failure, bsdtar, guard};

const XAR: &str = "/usr/bin/xar";
const PKGUTIL: &str = "/usr/sbin/pkgutil";
const TOC: &[u8] = b"[TOC].xml";
const OUTPUT_LIMIT: usize = 16 * 1024 * 1024;

static JOBS: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Origin {
    Toc,
    Xar,
    Expands,
    Disk,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Member {
    pub name: Vec<u8>,
    pub kind: Kind,
    pub size: u64,
    pub mode: u32,
    pub mtime: i64,
    pub target: Option<Vec<u8>>,
    pub origin: Origin,
}

#[derive(Clone)]
pub(super) struct Pkg {
    pub members: Vec<Member>,
    pub skipped: u64,
    toc: Arc<[u8]>,
    folder: PathBuf,
    session: u64,
    pub expanded: Option<PathBuf>,
}

#[derive(Default)]
struct Frame {
    at: usize,
    depth: usize,
    name: Option<String>,
    kind: String,
    mode: Option<u32>,
    size: u64,
    mtime: i64,
    link: Option<String>,
    broken: bool,
}

fn damaged() -> Failure {
    ArchiveProblem::Damaged.into()
}

fn epoch(text: &str) -> i64 {
    let field = |at: usize, len: usize| text.get(at..at + len)?.parse::<i32>().ok();
    let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) = (
        field(0, 4),
        field(5, 2),
        field(8, 2),
        field(11, 2),
        field(14, 2),
        field(17, 2),
    ) else {
        return 0;
    };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_hour = hour;
    tm.tm_min = minute;
    tm.tm_sec = second;
    unsafe { libc::timegm(&mut tm) }
}

pub(super) fn parse(xml: &[u8]) -> Result<(Vec<Member>, u64), Failure> {
    let mut reader = Reader::from_reader(xml);
    let mut stack: Vec<String> = Vec::new();
    let mut frames: Vec<Frame> = Vec::new();
    let mut members = Vec::new();
    let mut skipped = 0;
    let mut text = String::new();
    loop {
        match reader.read_event().map_err(|_| damaged())? {
            Event::Start(e) => {
                let name = e.name().as_ref().to_owned();
                if name == "file" {
                    let broken = frames
                        .last()
                        .is_some_and(|f| f.broken || f.kind != "directory");
                    frames.push(Frame {
                        at: members.len(),
                        depth: stack.len(),
                        broken,
                        ..Frame::default()
                    });
                }
                stack.push(name);
                text.clear();
            }
            Event::Text(t) => text.push_str(&t),
            Event::CData(c) => text.push_str(&c),
            Event::GeneralRef(g) => match &*g {
                "amp" => text.push('&'),
                "lt" => text.push('<'),
                "gt" => text.push('>'),
                "quot" => text.push('"'),
                "apos" => text.push('\''),
                _ => text.push(g.resolve_char_ref().ok().flatten().ok_or_else(damaged)?),
            },
            Event::End(_) => {
                let closed = stack.pop().ok_or_else(damaged)?;
                if let Some(frame) = frames.last_mut() {
                    let own = stack.len() == frame.depth + 1;
                    match closed.as_str() {
                        "name" if own && frame.name.is_none() => frame.name = Some(text.clone()),
                        "type" if own => frame.kind = text.clone(),
                        "mode" if own => frame.mode = u32::from_str_radix(&text, 8).ok(),
                        "mtime" if own => frame.mtime = epoch(&text),
                        "link" if own => frame.link = Some(text.clone()),
                        "size"
                            if stack.len() == frame.depth + 2
                                && stack.last().is_some_and(|s| s == "data") =>
                        {
                            frame.size = text.parse().unwrap_or(0)
                        }
                        _ => {}
                    }
                }
                if closed == "file" {
                    let frame = frames.pop().ok_or_else(damaged)?;
                    let parents: Option<Vec<&str>> =
                        frames.iter().map(|f| f.name.as_deref()).collect();
                    let (Some(parents), Some(name), false) = (parents, frame.name, frame.broken)
                    else {
                        skipped += 1;
                        text.clear();
                        continue;
                    };
                    let mut path = parents.join("/");
                    if !path.is_empty() {
                        path.push('/');
                    }
                    path.push_str(&name);
                    let kind = match frame.kind.as_str() {
                        "file" => Kind::File,
                        "directory" => Kind::Folder,
                        "symlink" => Kind::Symlink,
                        _ => Kind::Special,
                    };
                    members.insert(
                        frame.at,
                        Member {
                            name: path.into_bytes(),
                            kind,
                            size: if kind == Kind::File { frame.size } else { 0 },
                            mode: frame.mode.unwrap_or(if kind == Kind::Folder {
                                0o755
                            } else {
                                0o644
                            }),
                            mtime: frame.mtime,
                            target: frame
                                .link
                                .filter(|_| kind == Kind::Symlink)
                                .map(String::into_bytes),
                            origin: Origin::Xar,
                        },
                    );
                }
                text.clear();
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !stack.is_empty() {
        return Err(damaged());
    }
    Ok((members, skipped))
}

fn component(name: &[u8], leaves: &[&[u8]]) -> bool {
    let (folder, leaf) = match name.iter().rposition(|&b| b == b'/') {
        Some(at) => (Some(&name[..at]), &name[at + 1..]),
        None => (None, name),
    };
    leaves.contains(&leaf) && folder.is_none_or(|f| !f.contains(&b'/') && f.ends_with(b".pkg"))
}

pub(super) fn exact(name: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(name.len() + 8);
    out.push(b'^');
    for &b in name {
        if matches!(b, b'\\' | b'.' | b'[' | b'*' | b'^' | b'$') {
            out.push(b'\\');
        }
        out.push(b);
    }
    out.push(b'$');
    out
}

#[cfg(test)]
pub(super) type Held = Box<dyn FnOnce() + Send>;

#[cfg(test)]
pub(super) static HOLD: std::sync::Mutex<Vec<(PathBuf, Held)>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
pub(super) static SPAWNED: std::sync::Mutex<Vec<(PathBuf, String)>> =
    std::sync::Mutex::new(Vec::new());

pub(super) fn run(
    path: &Path,
    stamp: Stamp,
    program: &str,
    args: &[&OsStr],
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<u8>, Failure> {
    reopen(path, stamp)?;
    let mut command = bsdtar::command(program);
    command.args(args);
    let mut child = bsdtar::spawn(command, None)?;
    #[cfg(test)]
    {
        SPAWNED
            .lock()
            .unwrap()
            .push((path.to_path_buf(), program.to_owned()));
        let mut held = HOLD.lock().unwrap();
        if let Some(at) = held.iter().position(|(p, _)| p == path) {
            let (_, hold) = held.remove(at);
            drop(held);
            hold();
        }
    }
    let (status, out) = child.output(OUTPUT_LIMIT, cancelled)?;
    reopen(path, stamp)?;
    if !status.success() {
        return Err(damaged());
    }
    Ok(out)
}

pub(super) fn inside(folder: &Path, name: &[u8]) -> Result<File, Failure> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
        .open(folder.join(OsStr::from_bytes(name)))
        .map_err(|_| damaged())?;
    if !file.metadata()?.is_file() {
        return Err(damaged());
    }
    Ok(file)
}

fn kilobytes(xml: &[u8]) -> u64 {
    let mut reader = Reader::from_reader(xml);
    loop {
        match reader.read_event() {
            Ok(Event::Start(e) | Event::Empty(e)) if e.name().as_ref() == "payload" => {
                return e
                    .try_get_attribute("installKBytes")
                    .ok()
                    .flatten()
                    .and_then(|a| a.value.parse().ok())
                    .unwrap_or(0);
            }
            Ok(Event::Eof) | Err(_) => return 0,
            _ => {}
        }
    }
}

fn walk(
    root: &Path,
    name: &[u8],
    out: &mut Vec<Member>,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let folder = root.join(OsStr::from_bytes(name));
    if !fs::symlink_metadata(&folder).is_ok_and(|m| m.is_dir()) {
        return Ok(());
    }
    for item in fs::read_dir(&folder)? {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let item = item?;
        let meta = item.metadata()?;
        let kind = match meta.file_type() {
            t if t.is_dir() => Kind::Folder,
            t if t.is_file() => Kind::File,
            t if t.is_symlink() => Kind::Symlink,
            _ => Kind::Special,
        };
        let mut child = name.to_vec();
        child.push(b'/');
        child.extend_from_slice(item.file_name().as_bytes());
        let target = match kind {
            Kind::Symlink => Some(fs::read_link(item.path())?.into_os_string().into_vec()),
            _ => None,
        };
        out.push(Member {
            name: child.clone(),
            kind,
            size: if kind == Kind::File { meta.len() } else { 0 },
            mode: meta.mode(),
            mtime: meta.mtime(),
            target,
            origin: Origin::Disk,
        });
        if kind == Kind::Folder {
            walk(root, &child, out, cancelled)?;
        }
    }
    Ok(())
}

pub(super) fn list(
    path: &Path,
    stamp: Stamp,
    folder: PathBuf,
    session: u64,
    cancelled: &impl Fn() -> bool,
) -> Result<Pkg, Failure> {
    let real = resolved(path);
    let toc = run(
        path,
        stamp,
        XAR,
        &[
            OsStr::new("--dump-toc=-"),
            OsStr::new("-f"),
            real.as_os_str(),
        ],
        cancelled,
    )?;
    let (mut members, skipped) = parse(&toc)?;
    for m in &mut members {
        if m.kind == Kind::File && component(&m.name, &[b"Payload", b"Scripts"]) {
            m.kind = Kind::Folder;
            m.origin = Origin::Expands;
            m.size = 0;
            m.mode = 0o755;
        }
    }
    members.insert(
        0,
        Member {
            name: TOC.to_vec(),
            kind: Kind::File,
            size: toc.len() as u64,
            mode: 0o644,
            mtime: 0,
            target: None,
            origin: Origin::Toc,
        },
    );
    Ok(Pkg {
        members,
        skipped,
        toc: toc.into(),
        folder,
        session,
        expanded: None,
    })
}

impl Pkg {
    fn place(&self, kind: &str) -> io::Result<PathBuf> {
        fs::create_dir_all(&self.folder)?;
        let job = JOBS.fetch_add(1, Ordering::Relaxed) + 1;
        Ok(fs::canonicalize(&self.folder)?.join(format!("{kind}-{}-{job}", self.session)))
    }

    fn staged(
        &self,
        path: &Path,
        stamp: Stamp,
        name: &[u8],
        cancelled: &impl Fn() -> bool,
    ) -> Result<File, Failure> {
        let staging = self.place("xar")?;
        fs::create_dir(&staging)?;
        let pattern = exact(name);
        let read = run(
            path,
            stamp,
            XAR,
            &[
                OsStr::new("-x"),
                OsStr::new("-f"),
                resolved(path).as_os_str(),
                OsStr::new("-C"),
                staging.as_os_str(),
                OsStr::from_bytes(&pattern),
            ],
            cancelled,
        )
        .and_then(|_| inside(&staging, name));
        let _ = fs::remove_dir_all(&staging);
        read
    }

    pub fn contents(
        &self,
        path: &Path,
        stamp: Stamp,
        index: usize,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Box<dyn Read>, Failure> {
        let member = self.members.get(index).ok_or_else(damaged)?;
        Ok(match member.origin {
            Origin::Toc => Box::new(Cursor::new(self.toc.clone())),
            Origin::Xar => Box::new(self.staged(path, stamp, &member.name, cancelled)?),
            Origin::Disk => Box::new(inside(
                self.expanded.as_deref().ok_or_else(damaged)?,
                &member.name,
            )?),
            Origin::Expands => return Err(damaged()),
        })
    }

    pub fn enters(&self, folder: &str) -> bool {
        self.expanded.is_none()
            && self.members.iter().any(|m| {
                m.origin == Origin::Expands
                    && guard::name(&String::from_utf8_lossy(&m.name)).is_some_and(|name| {
                        folder == name
                            || folder
                                .strip_prefix(name.as_str())
                                .is_some_and(|rest| rest.starts_with('/'))
                    })
            })
    }

    pub fn expand(
        &self,
        path: &Path,
        stamp: Stamp,
        free: fn(&File) -> io::Result<Space>,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Pkg, Failure> {
        let mut needed = 0u64;
        for (index, m) in self.members.iter().enumerate() {
            if m.origin == Origin::Xar
                && m.kind == Kind::File
                && component(&m.name, &[b"PackageInfo"])
            {
                let mut xml = Vec::new();
                self.contents(path, stamp, index, cancelled)?
                    .take(OUTPUT_LIMIT as u64)
                    .read_to_end(&mut xml)?;
                needed = needed.saturating_add(kilobytes(&xml).saturating_mul(1024));
            }
        }
        let target = self.place("pkg")?;
        let available = free(&File::open(target.parent().ok_or_else(damaged)?)?)?;
        let short = needed
            .saturating_add(RESERVE)
            .saturating_sub(available.bytes);
        if short > 0 {
            return Err(ArchiveProblem::NoSpace {
                needed: short,
                volume: available.volume,
            }
            .into());
        }
        let filled = run(
            path,
            stamp,
            PKGUTIL,
            &[
                OsStr::new("--expand-full"),
                resolved(path).as_os_str(),
                target.as_os_str(),
            ],
            cancelled,
        )
        .and_then(|_| {
            let mut members = self.members.clone();
            for m in self.members.iter().filter(|m| m.origin == Origin::Expands) {
                walk(&target, &m.name, &mut members, cancelled)?;
            }
            Ok(members)
        });
        match filled {
            Ok(members) => Ok(Pkg {
                members,
                expanded: Some(target),
                ..self.clone()
            }),
            Err(failure) => {
                let _ = fs::remove_dir_all(&target);
                Err(failure)
            }
        }
    }
}
