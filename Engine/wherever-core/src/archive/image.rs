use std::ffi::{CStr, CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::{Duration, Instant};

use quick_xml::Reader;
use quick_xml::events::Event;

use super::detect::{Stamp, reopen, resolved};
use super::pkg::{self, Member, Origin};
use super::tar::Kind;
use super::{ArchiveProblem, ArchiveSummary, Failure, bsdtar};

const HDIUTIL: &str = "/usr/bin/hdiutil";
pub(super) const ATTACH: [&str; 8] = [
    "attach",
    "-readonly",
    "-nobrowse",
    "-noautoopen",
    "-noverify",
    "-stdinpass",
    "-plist",
    "-mountrandom",
];
const OUTPUT_LIMIT: usize = 1024 * 1024;
const PASSPHRASE_LIMIT: usize = 16 * 1024;
const ENCRYPTED_CAP: Duration = Duration::from_secs(30);
const ATTACH_CAP: Duration = Duration::from_secs(60);
const DETACH_CAP: Duration = Duration::from_secs(30);

#[cfg(test)]
pub(super) static SPAWNED: std::sync::Mutex<Vec<(Vec<String>, usize)>> =
    std::sync::Mutex::new(Vec::new());

fn damaged() -> Failure {
    ArchiveProblem::Damaged.into()
}

#[derive(Debug, PartialEq)]
pub(super) enum Plist {
    Dict(Vec<(String, Plist)>),
    Array(Vec<Plist>),
    Text(String),
    Bool(bool),
}

impl Plist {
    fn get(&self, key: &str) -> Option<&Plist> {
        match self {
            Plist::Dict(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

pub(super) fn plist(xml: &[u8]) -> Option<Plist> {
    let mut reader = Reader::from_reader(xml);
    let mut open: Vec<(Option<String>, Plist)> = Vec::new();
    let mut key = None;
    let mut text = String::new();
    let mut root = None;
    loop {
        let value = match reader.read_event().ok()? {
            Event::Start(e) => {
                match e.name().as_ref() {
                    "dict" => open.push((key.take(), Plist::Dict(Vec::new()))),
                    "array" => open.push((key.take(), Plist::Array(Vec::new()))),
                    _ => text.clear(),
                }
                continue;
            }
            Event::Text(t) => {
                text.push_str(&t);
                continue;
            }
            Event::CData(c) => {
                text.push_str(&c);
                continue;
            }
            Event::GeneralRef(g) => {
                text.push(match &*g {
                    "amp" => '&',
                    "lt" => '<',
                    "gt" => '>',
                    "quot" => '"',
                    "apos" => '\'',
                    _ => g.resolve_char_ref().ok().flatten()?,
                });
                continue;
            }
            Event::Empty(e) => match e.name().as_ref() {
                "true" => Plist::Bool(true),
                "false" => Plist::Bool(false),
                "dict" => Plist::Dict(Vec::new()),
                "array" => Plist::Array(Vec::new()),
                _ => Plist::Text(String::new()),
            },
            Event::End(e) => match e.name().as_ref() {
                "dict" | "array" => {
                    let (k, v) = open.pop()?;
                    key = k;
                    v
                }
                "key" => {
                    key = Some(std::mem::take(&mut text));
                    continue;
                }
                "plist" => continue,
                _ => Plist::Text(std::mem::take(&mut text)),
            },
            Event::Eof => return open.is_empty().then_some(root).flatten(),
            _ => continue,
        };
        match open.last_mut() {
            Some((_, Plist::Dict(items))) => items.push((key.take()?, value)),
            Some((_, Plist::Array(items))) => items.push(value),
            Some(_) => return None,
            None => root = Some(value),
        }
    }
}

pub(super) fn encrypted(xml: &[u8]) -> Option<bool> {
    match plist(xml)?.get("encrypted")? {
        Plist::Bool(locked) => Some(*locked),
        _ => None,
    }
}

pub(super) fn mount_points(xml: &[u8]) -> Option<Vec<PathBuf>> {
    let root = plist(xml)?;
    let Plist::Array(entities) = root.get("system-entities")? else {
        return None;
    };
    Some(
        entities
            .iter()
            .filter_map(|entity| match entity.get("mount-point") {
                Some(Plist::Text(point)) => Some(PathBuf::from(point)),
                _ => None,
            })
            .collect(),
    )
}

pub(super) fn hdiutil(
    args: &[&OsStr],
    input: &[u8],
    cap: Duration,
    cancelled: &impl Fn() -> bool,
) -> Result<(ExitStatus, Vec<u8>, Vec<u8>), Failure> {
    let mut command = bsdtar::command(HDIUTIL);
    command.args(args);
    if !input.is_empty() {
        let (reader, mut writer) = io::pipe()?;
        writer.write_all(input)?;
        command.stdin(reader);
    }
    #[cfg(test)]
    SPAWNED.lock().unwrap().push((
        args.iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect(),
        input.len(),
    ));
    let mut child = bsdtar::spawn(command, None)?;
    let deadline = Instant::now() + cap;
    match child.output(OUTPUT_LIMIT, &|| cancelled() || Instant::now() >= deadline) {
        Ok((status, out)) => Ok((status, out, child.stderr())),
        Err(Failure::Stopped) if !cancelled() => Err(damaged()),
        Err(failure) => Err(failure),
    }
}

pub(super) fn detach(point: &Path) {
    for force in [false, true] {
        if !crate::crawl::is_mount(point) {
            return;
        }
        let args: Vec<&OsStr> = [OsStr::new("detach")]
            .into_iter()
            .chain(force.then_some(OsStr::new("-force")))
            .chain([point.as_os_str()])
            .collect();
        let _ = hdiutil(&args, b"", DETACH_CAP, &|| false);
    }
}

struct Mount(Vec<PathBuf>);

impl Drop for Mount {
    fn drop(&mut self) {
        for point in &self.0 {
            detach(point);
        }
    }
}

pub(super) struct Image {
    pub members: Vec<Member>,
    pub skipped: u64,
    roots: Vec<(usize, PathBuf, usize)>,
    mount: Mount,
}

impl Image {
    pub fn contents(&self, index: usize) -> Result<File, Failure> {
        let member = self.members.get(index).ok_or_else(damaged)?;
        let (_, root, cut) = self
            .roots
            .iter()
            .rev()
            .find(|(from, _, _)| *from <= index)
            .ok_or_else(damaged)?;
        let name = member.name.get(*cut..).ok_or_else(damaged)?;
        pkg::inside(root, name)
    }
}

fn label(point: &Path) -> Option<String> {
    let path = CString::new(point.as_os_str().as_bytes()).ok()?;
    let mut list: libc::attrlist = unsafe { std::mem::zeroed() };
    list.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    list.volattr = libc::ATTR_VOL_INFO | libc::ATTR_VOL_NAME;
    let mut buf = [0u32; 256];
    if unsafe {
        libc::getattrlist(
            path.as_ptr(),
            (&raw mut list).cast(),
            buf.as_mut_ptr().cast(),
            std::mem::size_of_val(&buf),
            libc::FSOPT_NOFOLLOW as _,
        )
    } != 0
    {
        return None;
    }
    let bytes: &[u8] =
        unsafe { std::slice::from_raw_parts(buf.as_ptr().cast(), std::mem::size_of_val(&buf)) };
    let start = 4usize.checked_add(usize::try_from(buf[1] as i32).ok()?)?;
    let name = bytes.get(start..start.checked_add(buf[2] as usize)?)?;
    CStr::from_bytes_until_nul(name)
        .ok()?
        .to_str()
        .ok()
        .filter(|name| !name.is_empty())
        .map(|name| name.replace('/', ":"))
}

pub(super) fn open(
    path: &Path,
    stamp: Stamp,
    mounts: &Path,
    password: &[u8],
    summary: &mut ArchiveSummary,
    cancelled: &impl Fn() -> bool,
) -> Result<Image, Failure> {
    let file = resolved(path);
    reopen(path, stamp)?;
    let (status, out, _) = hdiutil(
        &[
            OsStr::new("isencrypted"),
            OsStr::new("-plist"),
            file.as_os_str(),
        ],
        b"",
        ENCRYPTED_CAP,
        cancelled,
    )?;
    let locked = status
        .success()
        .then(|| encrypted(&out))
        .flatten()
        .ok_or_else(damaged)?;
    summary.encrypted = locked;
    if locked && password.is_empty() {
        return Err(ArchiveProblem::PasswordNeeded.into());
    }
    if password.len() >= PASSPHRASE_LIMIT {
        return Err(ArchiveProblem::WrongPassword.into());
    }
    fs::create_dir_all(mounts)?;
    let mounts = fs::canonicalize(mounts)?;
    reopen(path, stamp)?;
    let args: Vec<&OsStr> = ATTACH
        .iter()
        .map(OsStr::new)
        .chain([mounts.as_os_str(), file.as_os_str()])
        .collect();
    let (status, out, err) = hdiutil(&args, password, ATTACH_CAP, &|| false)?;
    if !status.success() {
        let refused = err
            .windows(b"Authentication error".len())
            .any(|w| w == b"Authentication error");
        return Err(if locked && refused {
            ArchiveProblem::WrongPassword.into()
        } else {
            damaged()
        });
    }
    let mount = Mount(mount_points(&out).unwrap_or_default());
    if mount.0.is_empty() || mount.0.iter().any(|p| p.parent() != Some(mounts.as_path())) {
        return Err(damaged());
    }
    if cancelled() {
        return Err(Failure::Stopped);
    }
    reopen(path, stamp)?;
    let mut image = Image {
        members: Vec::new(),
        skipped: 0,
        roots: Vec::new(),
        mount,
    };
    if let [root] = image.mount.0.as_slice() {
        let root = root.clone();
        image.roots.push((0, root.clone(), 0));
        walk(&root, b"", &mut image, cancelled)?;
        return Ok(image);
    }
    let mut volumes: Vec<(String, PathBuf)> = image
        .mount
        .0
        .iter()
        .map(|point| {
            let name = label(point).unwrap_or_else(|| {
                point
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into()
            });
            (name, point.clone())
        })
        .collect();
    volumes.sort();
    let mut taken = std::collections::HashSet::new();
    for (name, point) in volumes {
        let unique = (1..)
            .map(|n| super::expand::numbered(&name, true, n))
            .find(|candidate| taken.insert(candidate.clone()))
            .ok_or_else(damaged)?;
        let meta = fs::metadata(&point).map_err(|_| damaged())?;
        image
            .roots
            .push((image.members.len(), point.clone(), unique.len() + 1));
        image.members.push(Member {
            name: unique.clone().into_bytes(),
            kind: Kind::Folder,
            size: 0,
            mode: meta.mode(),
            mtime: meta.mtime(),
            target: None,
            origin: Origin::Disk,
        });
        walk(&point, unique.as_bytes(), &mut image, cancelled)?;
    }
    Ok(image)
}

fn walk(
    folder: &Path,
    name: &[u8],
    image: &mut Image,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let items = match fs::read_dir(folder) {
        Ok(items) => items,
        Err(e) if !name.is_empty() && e.kind() == io::ErrorKind::PermissionDenied => {
            image.skipped += 1;
            return Ok(());
        }
        Err(_) => return Err(damaged()),
    };
    for item in items {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let item = item.map_err(|_| damaged())?;
        let meta = item.metadata().map_err(|_| damaged())?;
        let kind = match meta.file_type() {
            t if t.is_dir() => Kind::Folder,
            t if t.is_file() => Kind::File,
            t if t.is_symlink() => Kind::Symlink,
            _ => Kind::Special,
        };
        let mut child = name.to_vec();
        if !child.is_empty() {
            child.push(b'/');
        }
        child.extend_from_slice(item.file_name().as_bytes());
        let target = match kind {
            Kind::Symlink => Some(
                fs::read_link(item.path())
                    .map_err(|_| damaged())?
                    .into_os_string()
                    .into_vec(),
            ),
            _ => None,
        };
        image.members.push(Member {
            name: child.clone(),
            kind,
            size: if kind == Kind::File { meta.len() } else { 0 },
            mode: meta.mode(),
            mtime: meta.mtime(),
            target,
            origin: Origin::Disk,
        });
        if kind == Kind::Folder {
            walk(&item.path(), &child, image, cancelled)?;
        }
    }
    Ok(())
}
