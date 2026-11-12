use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock, PoisonError};

use bzip2::read::MultiBzDecoder;
use flate2::read::MultiGzDecoder;
use lzma_rust2::XzReader;

use super::detect::{Reader, Stamp, reopen};
use super::expand::{inside, trimmed};
use super::write::Task;
use super::{ArchiveProblem, Entry, Failure, bsdtar, guard};

const BLOCK: u64 = 512;
const SKIP: u64 = 64 * 1024;
const RECORD_LIMIT: u64 = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    File,
    Folder,
    Symlink,
    HardLink,
    Special,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Member {
    pub name: Vec<u8>,
    pub kind: Kind,
    pub size: u64,
    pub mode: u32,
    pub uid: u64,
    pub gid: u64,
    pub mtime: (i64, u32),
    pub target: Option<Vec<u8>>,
    pub offset: u64,
    pub sparse: Vec<(u64, u64)>,
    pub companion: Option<Box<Member>>,
}

enum Inner {
    Plain(Reader),
    Decoded(Box<dyn Read + Send>),
}

pub(super) struct Stream {
    inner: Inner,
    at: u64,
}

fn damaged() -> Failure {
    ArchiveProblem::Damaged.into()
}

fn eof() -> io::Error {
    io::ErrorKind::UnexpectedEof.into()
}

impl Stream {
    fn open(reader: &Reader) -> io::Result<Self> {
        let mut magic = [0; 6];
        let n = reader.file.read_at(&mut magic, 0)?;
        let mut reader = reader.clone();
        reader.seek(SeekFrom::Start(0))?;
        let inner = match &magic[..n] {
            [0x1f, 0x8b, ..] => Inner::Decoded(Box::new(MultiGzDecoder::new(reader))),
            [b'B', b'Z', b'h', ..] => Inner::Decoded(Box::new(MultiBzDecoder::new(reader))),
            [0xfd, b'7', b'z', b'X', b'Z', 0] => {
                Inner::Decoded(Box::new(XzReader::new(reader, true)))
            }
            _ => Inner::Plain(reader),
        };
        Ok(Self { inner, at: 0 })
    }

    fn skip(&mut self, n: u64, cancelled: &impl Fn() -> bool) -> Result<(), Failure> {
        let to = self.at.checked_add(n).ok_or_else(damaged)?;
        match &mut self.inner {
            Inner::Plain(reader) => {
                if to > reader.file.metadata()?.len() {
                    return Err(eof().into());
                }
                reader.seek(SeekFrom::Start(to))?;
            }
            Inner::Decoded(decoder) => {
                let mut left = n;
                while left > 0 {
                    if cancelled() {
                        return Err(Failure::Stopped);
                    }
                    let step = left.min(SKIP);
                    if io::copy(&mut decoder.by_ref().take(step), &mut io::sink())? < step {
                        return Err(eof().into());
                    }
                    left -= step;
                }
            }
        }
        self.at = to;
        Ok(())
    }

    fn block(&mut self) -> io::Result<Option<[u8; BLOCK as usize]>> {
        let mut block = [0; BLOCK as usize];
        let mut got = 0;
        while got < block.len() {
            match self.read(&mut block[got..]) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        match got {
            0 => Ok(None),
            n if n == block.len() => Ok(Some(block)),
            _ => Err(eof()),
        }
    }

    fn record(&mut self, size: u64, cancelled: &impl Fn() -> bool) -> Result<Vec<u8>, Failure> {
        if size > RECORD_LIMIT {
            return Err(damaged());
        }
        let mut data = vec![0; size as usize];
        self.read_exact(&mut data)?;
        self.skip(padding(size), cancelled)?;
        Ok(data)
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = match &mut self.inner {
            Inner::Plain(reader) => reader.read(buf)?,
            Inner::Decoded(decoder) => decoder.read(buf)?,
        };
        self.at += n as u64;
        Ok(n)
    }
}

fn padding(size: u64) -> u64 {
    (BLOCK - size % BLOCK) % BLOCK
}

fn text(field: &[u8]) -> &[u8] {
    field.split(|&b| b == 0).next().unwrap_or_default()
}

fn number(field: &[u8]) -> Option<i64> {
    match field.first() {
        Some(&lead @ (0x80 | 0xff)) => field[1..]
            .iter()
            .try_fold(if lead == 0xff { -1i64 } else { 0 }, |n, &b| {
                n.checked_mul(256)?.checked_add(i64::from(b))
            }),
        _ => field
            .iter()
            .skip_while(|&&b| b == b' ')
            .take_while(|&&b| b != 0 && b != b' ')
            .try_fold(0i64, |n, &b| {
                if (b'0'..=b'7').contains(&b) {
                    n.checked_mul(8)?.checked_add(i64::from(b - b'0'))
                } else {
                    None
                }
            }),
    }
}

fn unsigned(field: &[u8]) -> Option<u64> {
    number(field).and_then(|n| u64::try_from(n).ok())
}

fn decimal(value: &[u8]) -> Option<u64> {
    std::str::from_utf8(value).ok()?.parse().ok()
}

fn time(value: &[u8]) -> Option<(i64, u32)> {
    let value = std::str::from_utf8(value).ok()?;
    let (negative, value) = match value.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, value),
    };
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    if whole.is_empty() || !(whole.bytes().chain(fraction.bytes())).all(|b| b.is_ascii_digit()) {
        return None;
    }
    let seconds: i64 = whole.parse().ok()?;
    let nanos: u32 = format!("{:0<9}", &fraction[..fraction.len().min(9)])
        .parse()
        .ok()?;
    Some(match (negative, nanos) {
        (false, _) => (seconds, nanos),
        (true, 0) => (-seconds, 0),
        (true, _) => (-seconds - 1, 1_000_000_000 - nanos),
    })
}

fn sealed(header: &[u8; BLOCK as usize]) -> bool {
    let sum: i64 = header
        .iter()
        .enumerate()
        .map(|(i, &b)| {
            if (148..156).contains(&i) {
                i64::from(b' ')
            } else {
                i64::from(b)
            }
        })
        .sum();
    number(&header[148..156]) == Some(sum)
}

fn records(mut data: &[u8]) -> Option<Vec<(Vec<u8>, Vec<u8>)>> {
    let mut out = Vec::new();
    while !data.is_empty() {
        let space = data.iter().position(|&b| b == b' ')?;
        let length: usize = std::str::from_utf8(&data[..space]).ok()?.parse().ok()?;
        if length <= space + 1 || length > data.len() || data[length - 1] != b'\n' {
            return None;
        }
        let record = &data[space + 1..length - 1];
        let equals = record.iter().position(|&b| b == b'=')?;
        out.push((record[..equals].to_vec(), record[equals + 1..].to_vec()));
        data = &data[length..];
    }
    Some(out)
}

fn companion(name: &[u8]) -> bool {
    let name = name.strip_suffix(b"/").unwrap_or(name);
    name.rsplit(|&b| b == b'/')
        .next()
        .is_some_and(|last| last.starts_with(b"._"))
}

fn chunks(field: &[u8]) -> Option<Vec<(u64, u64)>> {
    field
        .as_chunks::<24>()
        .0
        .iter()
        .filter(|entry| entry[0] != 0)
        .map(|entry| Some((unsigned(&entry[..12])?, unsigned(&entry[12..])?)))
        .collect()
}

struct Walker {
    stream: Stream,
    globals: HashMap<Vec<u8>, Vec<u8>>,
    local: Vec<(Vec<u8>, Vec<u8>)>,
    long_name: Option<Vec<u8>>,
    long_link: Option<Vec<u8>>,
}

impl Walker {
    fn next(&mut self, cancelled: &impl Fn() -> bool) -> Result<Option<Member>, Failure> {
        loop {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            let first = self.stream.at == 0;
            let header = match self.stream.block() {
                Ok(Some(header)) => header,
                Ok(None) if !first => return Ok(None),
                Ok(None) => return Err(ArchiveProblem::Unsupported.into()),
                Err(e) if first && e.kind() == io::ErrorKind::UnexpectedEof => {
                    return Err(ArchiveProblem::Unsupported.into());
                }
                Err(e) => return Err(e.into()),
            };
            if header.iter().all(|&b| b == 0) {
                return Ok(None);
            }
            if !sealed(&header) {
                return Err(if first {
                    ArchiveProblem::Unsupported
                } else {
                    ArchiveProblem::Damaged
                }
                .into());
            }
            let size = unsigned(&header[124..136]).ok_or_else(damaged)?;
            match header[156] {
                b'x' => {
                    let parsed = records(&self.stream.record(size, cancelled)?);
                    self.local.extend(parsed.ok_or_else(damaged)?);
                }
                b'g' => {
                    let parsed = records(&self.stream.record(size, cancelled)?);
                    for (key, value) in parsed.ok_or_else(damaged)? {
                        if value.is_empty() {
                            self.globals.remove(&key);
                        } else {
                            self.globals.insert(key, value);
                        }
                    }
                }
                b'L' => self.long_name = Some(text(&self.stream.record(size, cancelled)?).to_vec()),
                b'K' => self.long_link = Some(text(&self.stream.record(size, cancelled)?).to_vec()),
                b'V' => {
                    let blocks = size.checked_add(padding(size)).ok_or_else(damaged)?;
                    self.stream.skip(blocks, cancelled)?;
                }
                b'M' => return Err(ArchiveProblem::Unsupported.into()),
                _ => return self.member(&header, size, cancelled).map(Some),
            }
        }
    }

    fn member(
        &mut self,
        header: &[u8; BLOCK as usize],
        size: u64,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Member, Failure> {
        let local = std::mem::take(&mut self.local);
        let long_name = self.long_name.take();
        let long_link = self.long_link.take();
        let globals = &self.globals;
        let field = |key: &str| {
            local
                .iter()
                .rev()
                .find(|(k, _)| k == key.as_bytes())
                .map(|(_, v)| v.as_slice())
                .or_else(|| globals.get(key.as_bytes()).map(Vec::as_slice))
                .filter(|v| !v.is_empty())
        };
        let flag = header[156];
        let name = match field("GNU.sparse.name").or_else(|| field("path")) {
            Some(path) => path.to_vec(),
            None => long_name.unwrap_or_else(|| {
                let base = text(&header[..100]);
                let prefix = text(&header[345..500]);
                if &header[257..263] == b"ustar\0" && !prefix.is_empty() {
                    [prefix, b"/", base].concat()
                } else {
                    base.to_vec()
                }
            }),
        };
        let kind = match flag {
            b'1' => Kind::HardLink,
            b'2' => Kind::Symlink,
            b'3' | b'4' | b'6' => Kind::Special,
            b'5' | b'D' => Kind::Folder,
            b'0' | 0 if name.ends_with(b"/") => Kind::Folder,
            _ => Kind::File,
        };
        let target = matches!(kind, Kind::HardLink | Kind::Symlink).then(|| {
            field("linkpath")
                .map(<[u8]>::to_vec)
                .or(long_link)
                .unwrap_or_else(|| text(&header[157..257]).to_vec())
        });
        let mut stored = match (flag, field("size")) {
            (b'2'..=b'6', _) => 0,
            (_, Some(value)) => decimal(value).ok_or_else(damaged)?,
            (_, None) => size,
        };
        let mode = unsigned(&header[100..108]).ok_or_else(damaged)? & 0o7777;
        let uid = field("uid")
            .map_or_else(|| unsigned(&header[108..116]), decimal)
            .ok_or_else(damaged)?;
        let gid = field("gid")
            .map_or_else(|| unsigned(&header[116..124]), decimal)
            .ok_or_else(damaged)?;
        let mtime = field("mtime")
            .map_or_else(|| number(&header[136..148]).map(|s| (s, 0)), time)
            .ok_or_else(damaged)?;
        let mut real = None;
        let mut map_in_data = false;
        let mut sparse = Vec::new();
        if flag == b'S' {
            real = Some(unsigned(&header[483..495]).ok_or_else(damaged)?);
            sparse = chunks(&header[386..482]).ok_or_else(damaged)?;
        } else if let Some(value) =
            field("GNU.sparse.realsize").or_else(|| field("GNU.sparse.size"))
        {
            real = Some(decimal(value).ok_or_else(damaged)?);
            if field("GNU.sparse.major") == Some(b"1") {
                map_in_data = true;
            } else if let Some(map) = field("GNU.sparse.map") {
                let numbers = map
                    .split(|&b| b == b',')
                    .map(decimal)
                    .collect::<Option<Vec<_>>>()
                    .filter(|n| n.len() % 2 == 0)
                    .ok_or_else(damaged)?;
                sparse = numbers
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|&[o, l]| (o, l))
                    .collect();
            } else {
                let values = |key: &[u8]| {
                    local
                        .iter()
                        .filter(|(k, _)| k == key)
                        .map(|(_, v)| decimal(v))
                        .collect::<Option<Vec<_>>>()
                };
                let offsets = values(b"GNU.sparse.offset").ok_or_else(damaged)?;
                let lengths = values(b"GNU.sparse.numbytes").ok_or_else(damaged)?;
                if offsets.len() != lengths.len() {
                    return Err(damaged());
                }
                sparse = offsets.into_iter().zip(lengths).collect();
            }
        }
        let mut extended = flag == b'S' && header[482] != 0;
        while extended {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            let block = self.stream.block()?.ok_or_else(eof)?;
            sparse.extend(chunks(&block[..504]).ok_or_else(damaged)?);
            extended = block[504] != 0;
        }
        if map_in_data {
            let done = |numbers: &[u64]| {
                numbers.first().is_some_and(|&count| {
                    count.checked_mul(2).and_then(|n| n.checked_add(1))
                        == Some(numbers.len() as u64)
                })
            };
            let mut numbers = Vec::new();
            let mut digits = Vec::new();
            let mut used = 0;
            while !done(&numbers) {
                used += BLOCK;
                if used > stored || used > RECORD_LIMIT {
                    return Err(damaged());
                }
                let block = self.stream.block()?.ok_or_else(eof)?;
                for &b in &block {
                    if b != b'\n' {
                        digits.push(b);
                        continue;
                    }
                    numbers.push(decimal(&digits).ok_or_else(damaged)?);
                    digits.clear();
                    if done(&numbers) {
                        break;
                    }
                }
            }
            stored -= used;
            sparse = numbers[1..]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|&[o, l]| (o, l))
                .collect();
        }
        let size = real.unwrap_or(stored);
        if real.is_some() && sparse.is_empty() {
            sparse.push((size, 0));
        }
        let mut end = 0u64;
        let mut total = 0u64;
        for &(start, length) in &sparse {
            let stop = start.checked_add(length).ok_or_else(damaged)?;
            if start < end || stop > size {
                return Err(damaged());
            }
            end = stop;
            total = total.checked_add(length).ok_or_else(damaged)?;
        }
        if total > stored {
            return Err(damaged());
        }
        let offset = self.stream.at;
        let blocks = stored.checked_add(padding(stored)).ok_or_else(damaged)?;
        self.stream.skip(blocks, cancelled)?;
        Ok(Member {
            name,
            kind,
            size,
            mode: mode as u32,
            uid,
            gid,
            mtime,
            target,
            offset,
            sparse,
            companion: None,
        })
    }
}

pub(super) fn list(
    reader: &Reader,
    cancelled: &impl Fn() -> bool,
) -> Result<(Vec<Member>, Option<ArchiveProblem>), Failure> {
    let mut walker = Walker {
        stream: Stream::open(reader)?,
        globals: HashMap::new(),
        local: Vec::new(),
        long_name: None,
        long_link: None,
    };
    let mut members = Vec::new();
    let mut pending: Option<Member> = None;
    let problem = loop {
        match walker.next(cancelled) {
            Ok(Some(mut member)) => {
                member.companion = pending.take().map(Box::new);
                if companion(&member.name) {
                    pending = Some(member);
                } else {
                    members.push(member);
                }
            }
            Ok(None) => break None,
            Err(Failure::Problem(ArchiveProblem::Damaged)) => break Some(ArchiveProblem::Damaged),
            Err(Failure::Io(_)) if cancelled() => return Err(Failure::Stopped),
            Err(Failure::Io(_)) => break Some(ArchiveProblem::Damaged),
            Err(failure) => return Err(failure),
        }
    };
    members.extend(pending);
    Ok((members, problem))
}

#[cfg(test)]
pub(super) static DECODERS: std::sync::Mutex<Vec<Stamp>> = std::sync::Mutex::new(Vec::new());

pub(super) struct Contents<'a> {
    data: io::Take<&'a mut Stream>,
    map: Vec<(u64, u64)>,
    chunk: usize,
    at: u64,
    size: u64,
}

pub(super) fn contents<'a>(
    reader: &Reader,
    kept: &'a mut Option<Stream>,
    member: &Member,
    cancelled: &impl Fn() -> bool,
) -> Result<Contents<'a>, Failure> {
    let stream = match kept.take() {
        Some(stream) if stream.at <= member.offset => kept.insert(stream),
        _ => {
            #[cfg(test)]
            DECODERS
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Stamp::read(&reader.file)?);
            kept.insert(Stream::open(reader)?)
        }
    };
    let gap = member.offset - stream.at;
    stream.skip(gap, cancelled)?;
    let map = if member.sparse.is_empty() {
        vec![(0, member.size)]
    } else {
        member.sparse.clone()
    };
    let stored = map.iter().map(|&(_, length)| length).sum();
    Ok(Contents {
        data: stream.take(stored),
        map,
        chunk: 0,
        at: 0,
        size: member.size,
    })
}

impl Read for Contents<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        while let Some(&(start, length)) = self.map.get(self.chunk)
            && self.at >= start + length
        {
            self.chunk += 1;
        }
        let (start, length) = self.map.get(self.chunk).copied().unwrap_or((self.size, 0));
        let room = buf.len() as u64;
        if self.at < start {
            let n = (start - self.at).min(room) as usize;
            buf[..n].fill(0);
            self.at += n as u64;
            return Ok(n);
        }
        let want = (start + length - self.at).min(room) as usize;
        if want == 0 {
            return Ok(0);
        }
        let n = self.data.read(&mut buf[..want])?;
        if n == 0 {
            return Err(eof());
        }
        self.at += n as u64;
        Ok(n)
    }
}

const GZIP: &str = "/usr/bin/gzip";

pub(super) struct Edit<'a> {
    pub members: &'a [Member],
    pub deleted: &'a [&'a str],
    pub adds: &'a [(&'a Path, &'a str)],
    pub added: &'a [&'a Entry],
    pub hidden: &'a [Vec<u8>],
    pub work: &'a Path,
}

#[cfg(test)]
pub(super) static SPOILED: std::sync::Mutex<Vec<std::path::PathBuf>> =
    std::sync::Mutex::new(Vec::new());

struct Work<'a>(&'a Path);

impl Drop for Work<'_> {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(self.0);
    }
}

fn path_of(name: &[u8]) -> Option<String> {
    guard::name(&String::from_utf8_lossy(name))
}

fn key(name: &[u8]) -> String {
    let name = String::from_utf8_lossy(trimmed(name));
    crate::query::nfd(&name).unwrap_or_else(|| name.into_owned())
}

fn escaped(name: &[u8]) -> Vec<u8> {
    let mut out = vec![b'^'];
    for &b in name {
        if matches!(b, b'\\' | b'*' | b'?' | b'[' | b']' | b'$' | b'^') {
            out.push(b'\\');
        }
        out.push(b);
    }
    out
}

fn sparse() -> bool {
    static ACCEPTED: OnceLock<bool> = OnceLock::new();
    *ACCEPTED.get_or_init(|| {
        let mut command = bsdtar::command(bsdtar::TAR);
        command
            .args([
                "-c",
                "-f",
                "/dev/null",
                "--no-read-sparse",
                "-T",
                "/dev/null",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command.status().is_ok_and(|status| status.success())
    })
}

fn opened(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

fn passes(
    program: &str,
    flag: &str,
    file: File,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut command = bsdtar::command(program);
    command.args([flag, "/dev/fd/3"]);
    let mut child = bsdtar::spawn(command, Some(file))?;
    let mut buffer = vec![0; 64 * 1024];
    loop {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        if child.stdout.read(&mut buffer)? == 0 {
            break;
        }
    }
    if child.wait(cancelled)?.success() {
        Ok(())
    } else {
        Err(damaged())
    }
}

fn tag() -> String {
    let mut bytes = [0u8; 16];
    unsafe { libc::arc4random_buf(bytes.as_mut_ptr().cast(), bytes.len()) };
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("WH-{hex}")
}

#[allow(clippy::too_many_arguments)]
pub(super) fn rewrite(
    reader: &Reader,
    path: &Path,
    stamp: Stamp,
    edit: &Edit,
    out: &Path,
    file: &File,
    task: &Task,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut magic = [0; 6];
    let n = reader.file.read_at(&mut magic, 0)?;
    let (z, gzip) = match &magic[..n] {
        [0x1f, 0x8b, ..] => ("z", true),
        [b'B', b'Z', b'h', ..] => ("j", false),
        [0xfd, b'7', b'z', b'X', b'Z', 0] => ("J", false),
        _ => ("", false),
    };
    let gone =
        |name: &[u8]| path_of(name).is_some_and(|p| edit.deleted.iter().any(|top| inside(&p, top)));
    for m in edit
        .members
        .iter()
        .filter(|m| m.kind == Kind::HardLink && !gone(&m.name))
    {
        if let Some(target) = m.target.as_deref().and_then(path_of)
            && edit.deleted.iter().any(|top| inside(&target, top))
        {
            return Err(ArchiveProblem::LinkedItem { name: target }.into());
        }
    }
    if gzip {
        passes(GZIP, "-t", reopen(path, stamp)?, cancelled)?;
    }
    let spelling = bsdtar::spelling(path, stamp, edit.members.len(), cancelled)?;
    let tag = tag();
    let mut seen = HashSet::new();
    let mut lines = Vec::new();
    let mut excludes = Vec::new();
    let skipped = edit
        .hidden
        .iter()
        .map(|p| escaped(&[tag.as_bytes(), b"/", p].concat()));
    let deleted = edit
        .members
        .iter()
        .zip(&spelling)
        .filter(|(m, _)| gone(&m.name))
        .map(|(_, spelled)| escaped(trimmed(spelled)));
    for pattern in deleted.chain(skipped) {
        if !seen.insert(pattern.clone()) {
            continue;
        }
        if pattern.contains(&b'\n') || pattern.contains(&b'\r') {
            excludes.push(OsString::from_vec(pattern));
        } else {
            lines.extend_from_slice(&pattern);
            lines.push(b'\n');
        }
    }
    fs::create_dir_all(edit.work)?;
    let _work = Work(edit.work);
    let patterns = edit.work.join("patterns");
    fs::write(&patterns, &lines)?;
    let stage = edit.work.join(&tag);
    let mut operands = Vec::new();
    for (disk, inner) in edit.adds {
        let link = stage.join(inner);
        fs::create_dir_all(link.parent().ok_or_else(damaged)?)?;
        std::os::unix::fs::symlink(disk, &link)?;
        operands.push(format!("{tag}/{inner}"));
    }
    let mut command = bsdtar::command(bsdtar::TAR);
    command.arg(format!("-c{z}")).arg("-f").arg(out).args([
        "--no-mac-metadata",
        "--no-xattrs",
        "--format",
        "pax",
    ]);
    if sparse() {
        command.arg("--no-read-sparse");
    }
    command
        .args(["--numeric-owner", "-H", "-s"])
        .arg(format!("|^{tag}/||HS"))
        .arg("-X")
        .arg(&patterns);
    for pattern in &excludes {
        command.arg("--exclude").arg(pattern);
    }
    command.arg("@/dev/fd/3");
    if !operands.is_empty() {
        command.arg("-C").arg(edit.work).args(&operands);
    }
    let mut child = bsdtar::spawn(command, Some(reopen(path, stamp)?))?;
    #[cfg(test)]
    bsdtar::SPAWNED
        .lock()
        .unwrap()
        .push((out.to_path_buf(), child.id()));
    let total = task
        .progress
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .job
        .total_bytes;
    let status = child.watch(cancelled, || {
        let size = file.metadata().map_or(0, |m| m.len());
        if size > 0 {
            {
                let mut p = task.progress.lock().unwrap_or_else(PoisonError::into_inner);
                p.job.done_bytes = p.job.done_bytes.max(size.min(total.saturating_sub(1)));
            }
            task.advance(0);
        }
    })?;
    child.stderr();
    if cancelled() {
        return Err(Failure::Stopped);
    }
    if !status.success() {
        return Err(edit
            .added
            .iter()
            .filter(|e| e.attrs.kind == crate::EngineKind::File)
            .find_map(|e| super::detect::file(e.disk.as_deref()?).err())
            .map_or_else(damaged, Failure::from));
    }
    #[cfg(test)]
    if SPOILED.lock().unwrap().iter().any(|p| p == out) {
        file.set_len(BLOCK)?;
    }
    passes(bsdtar::TAR, "-tf", opened(out)?, cancelled)?;
    if gzip {
        passes(GZIP, "-t", opened(out)?, cancelled)?;
    }
    let (written, problem) = list(
        &Reader::open(out, Arc::new(AtomicBool::new(false)))?,
        cancelled,
    )?;
    if problem.is_some() {
        return Err(damaged());
    }
    let mut counts: HashMap<String, i64> = HashMap::new();
    for m in edit.members.iter().filter(|m| !gone(&m.name)) {
        *counts.entry(key(&m.name)).or_default() += 1;
    }
    for e in edit.added {
        *counts.entry(key(e.path.as_bytes())).or_default() += 1;
    }
    for m in &written {
        *counts.entry(key(&m.name)).or_default() -= 1;
    }
    let names: HashSet<String> = written.iter().map(|m| key(&m.name)).collect();
    let linked = written
        .iter()
        .filter(|m| m.kind == Kind::HardLink)
        .all(|m| m.target.as_deref().is_some_and(|t| names.contains(&key(t))));
    if counts.values().any(|&n| n != 0) || !linked {
        return Err(damaged());
    }
    task.progress
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .job
        .done_bytes = total;
    Ok(())
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::crawl::tests::TempTree;
    use std::cell::Cell;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;
    use std::time::{Duration, SystemTime};

    fn reader(path: &Path) -> Reader {
        Reader::open(path, Arc::new(AtomicBool::new(false))).unwrap()
    }

    fn listed(path: &Path) -> (Vec<Member>, Option<ArchiveProblem>) {
        match list(&reader(path), &|| false) {
            Ok(listing) => listing,
            Err(_) => panic!("listing {} failed", path.display()),
        }
    }

    fn read(path: &Path, member: &Member) -> Vec<u8> {
        let mut stream = None;
        let Ok(mut data) = contents(&reader(path), &mut stream, member, &|| false) else {
            panic!("opening {:?} failed", member.name);
        };
        let mut out = Vec::new();
        data.read_to_end(&mut out).unwrap();
        out
    }

    fn names(members: &[Member]) -> Vec<String> {
        members
            .iter()
            .map(|m| String::from_utf8_lossy(&m.name).into_owned())
            .collect()
    }

    fn find<'a>(members: &'a [Member], name: &str) -> &'a Member {
        members
            .iter()
            .find(|m| m.name == name.as_bytes())
            .unwrap_or_else(|| panic!("{name} missing from {:?}", names(members)))
    }

    fn tar(args: &[&str]) {
        let status = Command::new("/usr/bin/tar").args(args).status().unwrap();
        assert!(status.success(), "tar {args:?}");
    }

    fn create(format: &str, out: &Path, src: &Path, members: &[&str]) {
        let format = format!("--format={format}");
        let mut args = vec![
            "-c",
            format.as_str(),
            "--no-mac-metadata",
            "--no-xattrs",
            "-f",
            out.to_str().unwrap(),
            "-C",
            src.to_str().unwrap(),
        ];
        args.extend(members);
        tar(&args);
    }

    fn folder(tree: &TempTree, name: &str) -> PathBuf {
        let path = PathBuf::from(tree.real()).join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn octal(field: &mut [u8], value: u64) {
        let digits = format!("{value:0width$o}", width = field.len() - 1);
        field[..digits.len()].copy_from_slice(digits.as_bytes());
    }

    pub(in crate::archive) fn header(name: &[u8], flag: u8, size: u64) -> [u8; 512] {
        let mut h = [0; 512];
        h[..name.len()].copy_from_slice(name);
        octal(&mut h[100..108], 0o644);
        octal(&mut h[108..116], 3);
        octal(&mut h[116..124], 4);
        octal(&mut h[124..136], size);
        octal(&mut h[136..148], 50);
        h[156] = flag;
        h[257..263].copy_from_slice(b"ustar\0");
        h[263..265].copy_from_slice(b"00");
        h
    }

    fn seal(mut h: [u8; 512]) -> [u8; 512] {
        h[148..156].fill(b' ');
        let sum: u32 = h.iter().map(|&b| u32::from(b)).sum();
        h[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
        h
    }

    fn padded(mut bytes: Vec<u8>) -> Vec<u8> {
        bytes.resize(bytes.len().next_multiple_of(512), 0);
        bytes
    }

    pub(in crate::archive) fn entry(h: [u8; 512], data: &[u8]) -> Vec<u8> {
        padded([seal(h).as_slice(), data].concat())
    }

    pub(in crate::archive) fn pax(flag: u8, records: &[(&str, &str)]) -> Vec<u8> {
        let mut data = Vec::new();
        for (key, value) in records {
            let base = key.len() + value.len() + 3;
            let length = (1..)
                .map(|digits| base + digits)
                .find(|n| n.to_string().len() + base == *n)
                .unwrap();
            data.extend_from_slice(format!("{length} {key}={value}\n").as_bytes());
        }
        entry(header(b"PaxHeader", flag, data.len() as u64), &data)
    }

    fn archive(tree: &TempTree, name: &str, parts: &[Vec<u8>]) -> PathBuf {
        let path = PathBuf::from(tree.real()).join(name);
        fs::write(&path, [parts.concat(), vec![0; 1024]].concat()).unwrap();
        path
    }

    fn noise(n: usize) -> Vec<u8> {
        let mut x = 0x9e37_79b9_7f4a_7c15u64;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect()
    }

    #[test]
    fn ustar_gnu_and_pax_headers_give_names_sizes_modes_and_times() {
        let tree = TempTree::new("tar-headers");
        let src = folder(&tree, "src/dir").parent().unwrap().to_path_buf();
        fs::set_permissions(src.join("dir"), fs::Permissions::from_mode(0o755)).unwrap();
        let file = src.join("dir/f.txt");
        fs::write(&file, b"abc").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
        fs::hard_link(&file, src.join("hard.txt")).unwrap();
        std::os::unix::fs::symlink("dir/f.txt", src.join("sym.txt")).unwrap();
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::new(1_700_000_000, 123_456_789))
            .unwrap();
        for format in ["ustar", "gnutar", "pax"] {
            let path = src.with_file_name(format!("{format}.tar"));
            let format_flag = format!("--format={format}");
            tar(&[
                "-c",
                &format_flag,
                "--no-mac-metadata",
                "--no-xattrs",
                "--uid",
                "1234",
                "--gid",
                "5678",
                "-f",
                path.to_str().unwrap(),
                "-C",
                src.to_str().unwrap(),
                "dir",
                "hard.txt",
                "sym.txt",
            ]);
            let (members, problem) = listed(&path);
            assert_eq!(problem, None, "{format}");
            assert_eq!(
                names(&members),
                ["dir/", "dir/f.txt", "hard.txt", "sym.txt"],
                "{format}"
            );
            let f = find(&members, "dir/f.txt");
            assert_eq!(
                (f.kind, f.size, f.mode, f.uid, f.gid),
                (Kind::File, 3, 0o640, 1234, 5678),
                "{format}"
            );
            let nanos = if format == "pax" { 123_456_789 } else { 0 };
            assert_eq!(f.mtime, (1_700_000_000, nanos), "{format}");
            assert_eq!(read(&path, f), b"abc", "{format}");
            let hard = find(&members, "hard.txt");
            assert_eq!(hard.kind, Kind::HardLink, "{format}");
            assert_eq!(hard.target.as_deref(), Some(b"dir/f.txt".as_slice()));
            let sym = find(&members, "sym.txt");
            assert_eq!(sym.kind, Kind::Symlink, "{format}");
            assert_eq!(sym.target.as_deref(), Some(b"dir/f.txt".as_slice()));
            let dir = find(&members, "dir/");
            assert_eq!(
                (dir.kind, dir.mode, dir.target.clone()),
                (Kind::Folder, 0o755, None)
            );
            assert!(
                members
                    .iter()
                    .all(|m| m.sparse.is_empty() && m.companion.is_none())
            );
        }
    }

    #[test]
    fn long_names_and_link_targets_through_prefix_gnu_records_and_pax_path() {
        let tree = TempTree::new("tar-long");
        let deep = format!("{}/{}/c.txt", "a".repeat(60), "b".repeat(60));
        let long = format!(
            "{}/{}/{}.txt",
            "x".repeat(120),
            "y".repeat(120),
            "z".repeat(100)
        );
        let target = format!("{}/t.txt", "t".repeat(150));
        let src = folder(&tree, "src");
        for (name, bytes) in [(&deep, b"deep"), (&long, b"long")] {
            fs::create_dir_all(src.join(name).parent().unwrap()).unwrap();
            fs::write(src.join(name), bytes).unwrap();
        }
        std::os::unix::fs::symlink(&target, src.join("link")).unwrap();
        let ustar = src.with_file_name("ustar.tar");
        create("ustar", &ustar, &src, &[&deep]);
        let (members, problem) = listed(&ustar);
        assert_eq!((names(&members), problem), (vec![deep.clone()], None));
        assert!(deep.len() > 100);
        assert_eq!(read(&ustar, &members[0]), b"deep");
        for format in ["gnutar", "pax"] {
            let path = src.with_file_name(format!("{format}.tar"));
            create(format, &path, &src, &[&long, "link"]);
            let (members, problem) = listed(&path);
            assert_eq!(problem, None, "{format}");
            assert_eq!(names(&members), [long.as_str(), "link"], "{format}");
            assert_eq!(read(&path, &members[0]), b"long", "{format}");
            assert_eq!(
                members[1].target.as_deref(),
                Some(target.as_bytes()),
                "{format}"
            );
        }
        let gnu = fs::read(src.with_file_name("gnutar.tar")).unwrap();
        assert_eq!(gnu[156], b'L');
    }

    #[test]
    fn gzip_bzip2_and_xz_streams_decode_in_process() {
        let tree = TempTree::new("tar-decode");
        let src = folder(&tree, "src");
        let bytes = noise(3000);
        fs::write(src.join("a.txt"), b"hello world\n").unwrap();
        fs::write(src.join("b.bin"), &bytes).unwrap();
        fs::write(src.join("c.txt"), b"third").unwrap();
        let members = ["a.txt", "b.bin", "c.txt"];
        let plain = src.with_file_name("plain.tar");
        create("ustar", &plain, &src, &members);
        let (expected, problem) = listed(&plain);
        assert_eq!(
            (names(&expected), problem),
            (members.map(String::from).to_vec(), None)
        );
        let mut paths = Vec::new();
        for (flag, name) in [("-z", "t.tgz"), ("-j", "t.tbz2"), ("-J", "t.txz")] {
            let path = src.with_file_name(name);
            tar(&[
                "-c",
                flag,
                "--format=ustar",
                "--no-mac-metadata",
                "--no-xattrs",
                "-f",
                path.to_str().unwrap(),
                "-C",
                src.to_str().unwrap(),
                "a.txt",
                "b.bin",
                "c.txt",
            ]);
            paths.push(path);
        }
        let whole = fs::read(&plain).unwrap();
        let parts = src.with_file_name("parts");
        fs::create_dir_all(&parts).unwrap();
        let (first, second) = whole.split_at(1024);
        fs::write(parts.join("one"), first).unwrap();
        fs::write(parts.join("two"), second).unwrap();
        let mut gz = Vec::new();
        let mut xz = Vec::new();
        for part in ["one", "two"] {
            let out = Command::new("/usr/bin/gzip")
                .arg("-c")
                .arg(parts.join(part))
                .output()
                .unwrap();
            assert!(out.status.success());
            gz.extend(out.stdout);
            let stream = parts.join(format!("{part}.xz"));
            tar(&[
                "-c",
                "-J",
                "--format",
                "raw",
                "-f",
                stream.to_str().unwrap(),
                "-C",
                parts.to_str().unwrap(),
                part,
            ]);
            xz.extend(fs::read(&stream).unwrap());
        }
        for (name, joined) in [("joined.tgz", gz), ("joined.txz", xz)] {
            let path = src.with_file_name(name);
            fs::write(&path, joined).unwrap();
            paths.push(path);
        }
        for path in &paths {
            let (members, problem) = listed(path);
            assert_eq!(problem, None, "{}", path.display());
            assert_eq!(members, expected, "{}", path.display());
            assert_eq!(read(path, &members[1]), bytes, "{}", path.display());
            assert_eq!(read(path, &members[2]), b"third", "{}", path.display());
        }
    }

    #[test]
    fn base256_size_and_negative_mtime_read() {
        let tree = TempTree::new("tar-base256");
        let mut big = header(b"big.bin", b'0', 0);
        big[124..136].fill(0);
        big[124] = 0x80;
        big[135] = 5;
        big[136..148].fill(0xff);
        big[146..148].copy_from_slice(&(-1000i16).to_be_bytes());
        let mut owner = header(b"owner.txt", b'0', 2);
        owner[108..116].fill(0);
        owner[108] = 0x80;
        owner[111] = 1;
        let path = archive(
            &tree,
            "base256.tar",
            &[
                entry(big, b"hello"),
                entry(owner, b"ok"),
                entry(header(b"next.txt", b'0', 4), b"next"),
            ],
        );
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(names(&members), ["big.bin", "owner.txt", "next.txt"]);
        assert_eq!((members[0].size, members[0].mtime), (5, (-1000, 0)));
        assert_eq!(read(&path, &members[0]), b"hello");
        assert_eq!((members[1].uid, members[1].gid), (1 << 32, 4));
        assert_eq!(read(&path, &members[2]), b"next");
        assert_eq!(members[2].mtime, (50, 0));
    }

    #[test]
    fn pax_global_header_applies_until_overridden_and_an_empty_value_deletes() {
        let tree = TempTree::new("tar-global");
        let file = |name: &[u8]| entry(header(name, b'0', 1), b"x");
        let path = archive(
            &tree,
            "global.tar",
            &[
                pax(b'g', &[("mtime", "100"), ("uid", "7")]),
                file(b"a.txt"),
                pax(b'x', &[("mtime", "200.5")]),
                file(b"b.txt"),
                pax(b'x', &[("uid", "")]),
                file(b"c.txt"),
                pax(b'g', &[("mtime", "")]),
                file(b"d.txt"),
                pax(b'x', &[("path", "renamed/e.txt"), ("mtime", "-1.25")]),
                file(b"e.txt"),
                file(b"f.txt"),
            ],
        );
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(
            names(&members),
            ["a.txt", "b.txt", "c.txt", "d.txt", "renamed/e.txt", "f.txt"]
        );
        let seen: Vec<_> = members.iter().map(|m| (m.mtime, m.uid)).collect();
        assert_eq!(
            seen,
            [
                ((100, 0), 7),
                ((200, 500_000_000), 7),
                ((100, 0), 3),
                ((50, 0), 7),
                ((-2, 750_000_000), 7),
                ((50, 0), 7),
            ]
        );
    }

    #[test]
    fn hard_link_data_blocks_are_skipped_or_read_by_their_size() {
        let tree = TempTree::new("tar-hardlink");
        let link = |name: &[u8], size: u64| {
            let mut h = header(name, b'1', size);
            h[157..162].copy_from_slice(b"a.txt");
            h
        };
        let path = archive(
            &tree,
            "links.tar",
            &[
                entry(header(b"a.txt", b'0', 5), b"hello"),
                entry(link(b"b.txt", 5), b"HELLO"),
                entry(link(b"c.txt", 0), b""),
                entry(header(b"d.txt", b'0', 5), b"after"),
            ],
        );
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(names(&members), ["a.txt", "b.txt", "c.txt", "d.txt"]);
        for m in &members[1..3] {
            assert_eq!(
                (m.kind, m.target.as_deref()),
                (Kind::HardLink, Some(b"a.txt".as_slice()))
            );
        }
        assert_eq!(
            (members[1].size, read(&path, &members[1])),
            (5, b"HELLO".to_vec())
        );
        assert_eq!((members[2].size, read(&path, &members[2])), (0, Vec::new()));
        assert_eq!(read(&path, &members[3]), b"after");
    }

    #[test]
    fn sparse_members_read_with_their_holes() {
        let tree = TempTree::new("tar-sparse");
        let holes = |size: usize, chunks: &[(usize, &[u8])]| {
            let mut out = vec![0; size];
            for (at, bytes) in chunks {
                out[*at..*at + bytes.len()].copy_from_slice(bytes);
            }
            out
        };
        let mut old = header(b"oldgnu.bin", b'S', 6);
        old[257..265].copy_from_slice(b"ustar  \0");
        let mut extension = [0u8; 512];
        for i in 0..6u64 {
            let slot = if i < 4 {
                &mut old[386 + 24 * i as usize..410 + 24 * i as usize]
            } else {
                &mut extension[24 * (i as usize - 4)..24 * (i as usize - 3)]
            };
            octal(&mut slot[..12], 100 * (i + 1));
            octal(&mut slot[12..], 1);
        }
        old[482] = 1;
        octal(&mut old[483..495], 700);
        let old = padded([seal(old).as_slice(), &extension, b"abcdef"].concat());
        let after = entry(header(b"after.txt", b'0', 5), b"after");
        let map = padded(b"2\n1024\n5\n2500\n3\n".to_vec());
        let path = archive(
            &tree,
            "sparse.tar",
            &[
                old,
                after.clone(),
                pax(
                    b'x',
                    &[
                        ("GNU.sparse.size", "3000"),
                        ("GNU.sparse.numblocks", "2"),
                        ("GNU.sparse.offset", "1024"),
                        ("GNU.sparse.numbytes", "5"),
                        ("GNU.sparse.offset", "2500"),
                        ("GNU.sparse.numbytes", "3"),
                    ],
                ),
                entry(header(b"sparse00.bin", b'0', 8), b"helloxyz"),
                after.clone(),
                pax(
                    b'x',
                    &[
                        ("GNU.sparse.size", "3000"),
                        ("GNU.sparse.numblocks", "2"),
                        ("GNU.sparse.name", "real/sparse01.bin"),
                        ("GNU.sparse.map", "1024,5,2500,3"),
                    ],
                ),
                entry(
                    header(b"./GNUSparseFile.0/sparse01.bin", b'0', 8),
                    b"helloxyz",
                ),
                after.clone(),
                pax(
                    b'x',
                    &[
                        ("GNU.sparse.major", "1"),
                        ("GNU.sparse.minor", "0"),
                        ("GNU.sparse.name", "real/sparse10.bin"),
                        ("GNU.sparse.realsize", "3000"),
                    ],
                ),
                entry(
                    header(b"./GNUSparseFile.0/sparse10.bin", b'0', 520),
                    &[map.as_slice(), b"helloxyz"].concat(),
                ),
                after,
            ],
        );
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(
            names(&members),
            [
                "oldgnu.bin",
                "after.txt",
                "sparse00.bin",
                "after.txt",
                "real/sparse01.bin",
                "after.txt",
                "real/sparse10.bin",
                "after.txt",
            ]
        );
        let old: Vec<(usize, &[u8])> = (0..6).map(|i| (100 * (i + 1), &b"abcdef"[i..=i])).collect();
        assert_eq!((members[0].size, members[0].sparse.len()), (700, 6));
        assert_eq!(read(&path, &members[0]), holes(700, &old));
        let pax = holes(3000, &[(1024, b"hello"), (2500, b"xyz")]);
        for m in [&members[2], &members[4], &members[6]] {
            assert_eq!(
                (m.size, m.sparse.as_slice()),
                (3000, [(1024, 5), (2500, 3)].as_slice())
            );
            assert_eq!(read(&path, m), pax, "{:?}", m.name);
        }
        for m in members.iter().filter(|m| m.name == b"after.txt") {
            assert_eq!(read(&path, m), b"after");
        }
    }

    #[test]
    fn unknown_typeflag_reads_as_a_file_and_a_volume_header_is_skipped() {
        let tree = TempTree::new("tar-typeflag");
        let mut volume = header(b"Backup volume 1", b'V', 0);
        volume[257..265].copy_from_slice(b"ustar  \0");
        let path = archive(
            &tree,
            "typeflag.tar",
            &[
                entry(volume, b""),
                entry(header(b"odd.bin", b'Z', 2), b"zz"),
                entry(header(b"fifo", b'6', 0), b""),
                entry(header(b"after.txt", b'0', 5), b"after"),
            ],
        );
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(names(&members), ["odd.bin", "fifo", "after.txt"]);
        assert_eq!(
            (members[0].kind, read(&path, &members[0])),
            (Kind::File, b"zz".to_vec())
        );
        assert_eq!(members[1].kind, Kind::Special);
        assert_eq!(read(&path, &members[2]), b"after");
        let split = archive(
            &tree,
            "continued.tar",
            &[entry(header(b"part.bin", b'M', 1), b"p")],
        );
        assert!(matches!(
            list(&reader(&split), &|| false),
            Err(Failure::Problem(ArchiveProblem::Unsupported))
        ));
    }

    #[test]
    fn bad_checksum_after_good_members_is_damaged_and_keeps_them() {
        let tree = TempTree::new("tar-checksum");
        let src = folder(&tree, "src");
        let files: [(&str, &[u8]); 3] =
            [("one.txt", b"1"), ("two.txt", b"22"), ("three.txt", b"333")];
        for (name, bytes) in files {
            fs::write(src.join(name), bytes).unwrap();
        }
        let good = src.with_file_name("good.tar");
        create("ustar", &good, &src, &files.map(|(name, _)| name));
        let (members, problem) = listed(&good);
        assert_eq!(problem, None);
        assert_eq!(names(&members), files.map(|(name, _)| name));
        for (m, (_, bytes)) in members.iter().zip(files) {
            assert_eq!(
                (m.size, read(&good, m)),
                (bytes.len() as u64, bytes.to_vec())
            );
        }
        let whole = fs::read(&good).unwrap();
        let third = members[2].offset as usize - 512;
        let mut bad = whole.clone();
        bad[third] ^= 1;
        let damaged = src.with_file_name("bad.tar");
        fs::write(&damaged, &bad).unwrap();
        let (kept, problem) = listed(&damaged);
        assert_eq!(problem, Some(ArchiveProblem::Damaged));
        assert_eq!(kept, members[..2]);
        let truncated = src.with_file_name("short.tar");
        fs::write(&truncated, &whole[..third + 513]).unwrap();
        let (kept, problem) = listed(&truncated);
        assert_eq!(
            (kept.as_slice(), problem),
            (&members[..2], Some(ArchiveProblem::Damaged))
        );
        let mut first = whole;
        first[0] ^= 1;
        let none = src.with_file_name("none.tar");
        fs::write(&none, &first).unwrap();
        assert!(matches!(
            list(&reader(&none), &|| false),
            Err(Failure::Problem(ArchiveProblem::Unsupported))
        ));
    }

    #[test]
    fn dot_underscore_member_before_another_is_its_companion() {
        let tree = TempTree::new("tar-companion");
        let src = folder(&tree, "src");
        let files: [(&str, &[u8]); 4] = [
            ("foo.txt", b"foo"),
            ("._foo.txt", b"not apple double meta\n"),
            ("after.txt", b"after"),
            ("._trail.txt", b"trail"),
        ];
        for (name, bytes) in files {
            fs::write(src.join(name), bytes).unwrap();
        }
        let path = src.with_file_name("dot.tar");
        create("ustar", &path, &src, &files.map(|(name, _)| name));
        let (members, problem) = listed(&path);
        assert_eq!(problem, None);
        assert_eq!(names(&members), ["foo.txt", "after.txt", "._trail.txt"]);
        assert_eq!(members[0].companion, None);
        let meta = members[1].companion.as_deref().unwrap();
        assert_eq!(meta.name, b"._foo.txt");
        assert_eq!(read(&path, meta), files[1].1);
        assert_eq!(read(&path, &members[1]), b"after");
        assert_eq!(
            (members[2].companion.clone(), read(&path, &members[2])),
            (None, b"trail".to_vec())
        );
    }

    #[test]
    fn decoder_stops_when_cancelled() {
        let tree = TempTree::new("tar-cancel");
        let src = folder(&tree, "src");
        fs::write(src.join("big.bin"), noise(4 << 20)).unwrap();
        fs::write(src.join("small.txt"), b"small").unwrap();
        let path = src.with_file_name("big.tgz");
        tar(&[
            "-c",
            "-z",
            "--format=ustar",
            "--no-mac-metadata",
            "--no-xattrs",
            "-f",
            path.to_str().unwrap(),
            "-C",
            src.to_str().unwrap(),
            "big.bin",
            "small.txt",
        ]);
        let (members, problem) = listed(&path);
        assert_eq!(
            (names(&members), problem),
            (vec!["big.bin".into(), "small.txt".into()], None)
        );
        let polls = Cell::new(0);
        let cancelled = || {
            polls.set(polls.get() + 1);
            polls.get() > 3
        };
        assert!(matches!(
            list(&reader(&path), &cancelled),
            Err(Failure::Stopped)
        ));
        assert_eq!(polls.get(), 4);
        polls.set(0);
        assert!(matches!(
            contents(&reader(&path), &mut None, &members[1], &cancelled),
            Err(Failure::Stopped)
        ));
        assert_eq!(polls.get(), 4);
        assert_eq!(read(&path, &members[1]), b"small");
    }
}
