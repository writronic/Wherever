use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

use flate2::Crc;

use super::detect::{Reader, Stamp};
use super::tar::Kind;
use super::{ArchiveProblem, Failure, bsdtar};

const RAR5: &[u8] = b"Rar!\x1a\x07\x01\x00";
const HEADER_LIMIT: u64 = 2 * 1024 * 1024;
const FILETIME_EPOCH: i64 = 11_644_473_600;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Member {
    pub name: Vec<u8>,
    pub kind: Kind,
    pub size: u64,
    pub sized: bool,
    pub mode: u32,
    pub mtime: i64,
    pub target: Option<Vec<u8>>,
    pub encrypted: bool,
}

pub(super) struct Rar {
    pub members: Vec<Member>,
    spelling: Mutex<Option<Arc<Vec<Vec<u8>>>>>,
}

fn damaged() -> Failure {
    ArchiveProblem::Damaged.into()
}

fn crc(parts: &[&[u8]]) -> u32 {
    let mut crc = Crc::new();
    for part in parts {
        crc.update(part);
    }
    crc.sum()
}

fn vint(data: &[u8], at: &mut usize) -> Result<u64, Failure> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let b = *data.get(*at).ok_or_else(damaged)?;
        *at += 1;
        value |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(damaged())
}

fn take<'a>(data: &'a [u8], at: &mut usize, n: u64) -> Result<&'a [u8], Failure> {
    let end = usize::try_from(n)
        .ok()
        .and_then(|n| at.checked_add(n))
        .filter(|&end| end <= data.len())
        .ok_or_else(damaged)?;
    let out = &data[*at..end];
    *at = end;
    Ok(out)
}

fn u16_at(data: &[u8], at: usize) -> Result<u16, Failure> {
    let b = data.get(at..at + 2).ok_or_else(damaged)?;
    Ok(u16::from_le_bytes([b[0], b[1]]))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, Failure> {
    let b = data.get(at..at + 4).ok_or_else(damaged)?;
    Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn u64_at(data: &[u8], at: usize) -> Result<u64, Failure> {
    Ok(u64::from(u32_at(data, at)?) | u64::from(u32_at(data, at + 4)?) << 32)
}

struct Bytes {
    reader: Reader,
    size: u64,
}

impl Bytes {
    fn at(&mut self, at: u64, n: u64) -> Result<Vec<u8>, Failure> {
        if at.checked_add(n).is_none_or(|end| end > self.size) {
            return Err(damaged());
        }
        self.reader.seek(SeekFrom::Start(at))?;
        let mut out = vec![0; usize::try_from(n).map_err(|_| damaged())?];
        self.reader.read_exact(&mut out)?;
        Ok(out)
    }
}

fn mode(host_unix: bool, attributes: u64, folder: bool) -> u32 {
    if host_unix {
        attributes as u32
    } else if folder || attributes & 0x10 != 0 {
        libc::S_IFDIR as u32 | 0o755
    } else if attributes & 0x01 != 0 {
        libc::S_IFREG as u32 | 0o444
    } else {
        libc::S_IFREG as u32 | 0o644
    }
}

fn kind_of(mode: u32) -> Kind {
    match mode as u16 & libc::S_IFMT {
        libc::S_IFDIR => Kind::Folder,
        libc::S_IFREG | 0 => Kind::File,
        _ => Kind::Special,
    }
}

fn dos(stamp: u32) -> i64 {
    let (month, day) = ((stamp >> 21) & 0x0f, (stamp >> 16) & 0x1f);
    if month == 0 || day == 0 {
        return 0;
    }
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = (stamp >> 25) as i32 + 80;
    tm.tm_mon = month as i32 - 1;
    tm.tm_mday = day as i32;
    tm.tm_hour = ((stamp >> 11) & 0x1f) as i32;
    tm.tm_min = ((stamp >> 5) & 0x3f) as i32;
    tm.tm_sec = ((stamp & 0x1f) * 2) as i32;
    tm.tm_isdst = -1;
    unsafe { libc::mktime(&mut tm) }
}

fn file5(body: &[u8], mut at: usize, extra: &[u8]) -> Result<Member, Failure> {
    let flags = vint(body, &mut at)?;
    let size = vint(body, &mut at)?;
    let attributes = vint(body, &mut at)?;
    let mut mtime = if flags & 0x0002 != 0 {
        let seconds = u32_at(body, at)?;
        at += 4;
        i64::from(seconds)
    } else {
        0
    };
    if flags & 0x0004 != 0 {
        at += 4;
    }
    vint(body, &mut at)?;
    let host = vint(body, &mut at)?;
    let length = vint(body, &mut at)?;
    let name = take(body, &mut at, length)?.to_vec();
    let folder = flags & 0x0001 != 0;
    let mode = mode(host == 1, attributes, folder);
    let mut redirect = None;
    let mut target = None;
    let mut encrypted = false;
    let mut at = 0;
    while at < extra.len() {
        let length = vint(extra, &mut at)?;
        let record = take(extra, &mut at, length)?;
        let mut i = 0;
        match vint(record, &mut i)? {
            0x01 => encrypted = true,
            0x03 => {
                let time = vint(record, &mut i)?;
                if time & 0x0002 != 0 {
                    mtime = if time & 0x0001 != 0 {
                        i64::from(u32_at(record, i)?)
                    } else {
                        (u64_at(record, i)? / 10_000_000) as i64 - FILETIME_EPOCH
                    };
                }
            }
            0x05 => {
                let redirect_type = vint(record, &mut i)?;
                vint(record, &mut i)?;
                let length = vint(record, &mut i)?;
                target = Some(take(record, &mut i, length)?.to_vec());
                redirect = Some(redirect_type);
            }
            _ => {}
        }
    }
    let kind = match (folder, redirect) {
        (true, _) => Kind::Folder,
        (_, Some(1)) => Kind::Symlink,
        (_, Some(4 | 5)) => Kind::HardLink,
        (_, Some(_)) => Kind::Special,
        (_, None) => kind_of(mode),
    };
    Ok(Member {
        name,
        kind,
        size,
        sized: flags & 0x0008 == 0,
        mode: mode & 0o7777,
        mtime,
        target,
        encrypted,
    })
}

fn rar5(
    archive: &mut Bytes,
    members: &mut Vec<Member>,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut pos = RAR5.len() as u64;
    while pos < archive.size {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let head = archive.at(pos, (archive.size - pos).min(7))?;
        let mut at = 4;
        let size = vint(&head, &mut at)?;
        if at > 7 || size == 0 || size > HEADER_LIMIT {
            return Err(damaged());
        }
        let body = archive.at(pos + at as u64, size)?;
        if crc(&[&head[4..at], &body]) != u32_at(&head, 0)? {
            return Err(damaged());
        }
        let mut i = 0;
        let kind = vint(&body, &mut i)?;
        let flags = vint(&body, &mut i)?;
        let extra = if flags & 0x0001 != 0 {
            vint(&body, &mut i)?
        } else {
            0
        };
        let data = if flags & 0x0002 != 0 {
            vint(&body, &mut i)?
        } else {
            0
        };
        let extra_at = usize::try_from(extra)
            .ok()
            .and_then(|extra| body.len().checked_sub(extra))
            .filter(|&start| start >= i)
            .ok_or_else(damaged)?;
        let next = (pos + at as u64 + size)
            .checked_add(data)
            .filter(|&next| next <= archive.size)
            .ok_or_else(damaged)?;
        match kind {
            1 => {
                if vint(&body, &mut i)? & 0x0001 != 0 {
                    return Err(ArchiveProblem::Unsupported.into());
                }
            }
            2 => {
                if flags & 0x0018 != 0 {
                    return Err(ArchiveProblem::Unsupported.into());
                }
                members.push(file5(&body[..extra_at], i, &body[extra_at..])?);
            }
            4 => return Err(ArchiveProblem::Encrypted.into()),
            5 => return Ok(()),
            _ => {}
        }
        pos = next;
    }
    Ok(())
}

fn unicode(plain: &[u8], encoded: &[u8]) -> String {
    let high = u16::from(encoded.first().copied().unwrap_or(0));
    let mut out: Vec<u16> = Vec::with_capacity(plain.len());
    let (mut at, mut flags, mut bits) = (1, 0u8, 0);
    let next = |at: &mut usize| {
        let b = encoded.get(*at).copied();
        *at += 1;
        b.map(u16::from)
    };
    while at < encoded.len() {
        if bits == 0 {
            let Some(b) = next(&mut at) else { break };
            flags = b as u8;
            bits = 8;
        }
        let unit = match flags >> 6 {
            0 => next(&mut at),
            1 => next(&mut at).map(|b| b | high << 8),
            2 => next(&mut at)
                .zip(next(&mut at))
                .map(|(lo, hi)| lo | hi << 8),
            _ => {
                let Some(length) = next(&mut at) else { break };
                let correction = if length & 0x80 != 0 {
                    next(&mut at)
                } else {
                    None
                };
                for _ in 0..(length & 0x7f) + 2 {
                    let Some(&b) = plain.get(out.len()) else {
                        break;
                    };
                    out.push(match correction {
                        Some(c) => (u16::from(b) + c) & 0xff | high << 8,
                        None => u16::from(b),
                    });
                }
                None
            }
        };
        if let Some(unit) = unit {
            out.push(unit);
        } else if flags >> 6 != 3 {
            break;
        }
        flags <<= 2;
        bits -= 2;
    }
    String::from_utf16_lossy(&out)
}

fn file4(archive: &mut Bytes, header: &[u8], data_at: u64) -> Result<(Member, u64), Failure> {
    let flags = u16_at(header, 3)?;
    if flags & 0x0003 != 0 {
        return Err(ArchiveProblem::Unsupported.into());
    }
    let wide = flags & 0x0100 != 0;
    let high = |at| {
        if wide {
            u32_at(header, at).map(u64::from)
        } else {
            Ok(0)
        }
    };
    let packed = u64::from(u32_at(header, 7)?) | high(32)? << 32;
    let size = u64::from(u32_at(header, 11)?) | high(36)? << 32;
    let host = *header.get(15).ok_or_else(damaged)?;
    let stamp = u32_at(header, 20)?;
    let method = *header.get(25).ok_or_else(damaged)?;
    let length = u64::from(u16_at(header, 26)?);
    let attributes = u64::from(u32_at(header, 28)?);
    let mut at = if wide { 40 } else { 32 };
    let raw = take(header, &mut at, length)?;
    let mut name = match (flags & 0x0200 != 0, raw.iter().position(|&b| b == 0)) {
        (true, Some(zero)) => unicode(&raw[..zero], &raw[zero + 1..]).into_bytes(),
        _ => raw.to_vec(),
    };
    for b in &mut name {
        if *b == b'\\' {
            *b = b'/';
        }
    }
    if flags & 0x0400 != 0 {
        at += 8;
    }
    let mut mtime = dos(stamp);
    if flags & 0x1000 != 0 && mtime != 0 && (u16_at(header, at)? >> 12) & 0x0c == 0x0c {
        mtime += 1;
    }
    let folder = flags & 0x00e0 == 0x00e0;
    let mode = mode(host == 3, attributes, folder);
    let mut kind = if folder { Kind::Folder } else { kind_of(mode) };
    let mut target = None;
    if !folder && mode as u16 & libc::S_IFMT == libc::S_IFLNK {
        kind = Kind::Special;
        if method == 0x30 && packed <= libc::PATH_MAX as u64 && flags & 0x0004 == 0 {
            target = Some(archive.at(data_at, packed)?);
            kind = Kind::Symlink;
        }
    }
    Ok((
        Member {
            name,
            kind,
            size,
            sized: true,
            mode: mode & 0o7777,
            mtime,
            target,
            encrypted: flags & 0x0004 != 0,
        },
        packed,
    ))
}

fn rar4(
    archive: &mut Bytes,
    members: &mut Vec<Member>,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut pos = 7;
    while pos < archive.size {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let head = archive.at(pos, 7)?;
        let kind = head[2];
        let flags = u16_at(&head, 3)?;
        let size = u64::from(u16_at(&head, 5)?);
        if size < 7 {
            return Err(damaged());
        }
        let header = archive.at(pos, size)?;
        let sealed = || crc(&[&header[2..]]) & 0xffff == u32::from(u16_at(&header, 0).unwrap_or(0));
        let mut added = if flags & 0x8000 != 0 {
            u64::from(u32_at(&header, 7)?)
        } else {
            0
        };
        match kind {
            0x73 => {
                if !sealed() {
                    return Err(damaged());
                }
                if flags & 0x0001 != 0 {
                    return Err(ArchiveProblem::Unsupported.into());
                }
                if flags & 0x0080 != 0 {
                    return Err(ArchiveProblem::Encrypted.into());
                }
            }
            0x74 => {
                if !sealed() {
                    return Err(damaged());
                }
                let (member, packed) = file4(archive, &header, pos + size)?;
                if (pos + size)
                    .checked_add(packed)
                    .is_none_or(|end| end > archive.size)
                {
                    return Err(damaged());
                }
                added = packed;
                members.push(member);
            }
            0x7b => return Ok(()),
            _ => {}
        }
        pos = pos
            .checked_add(size)
            .and_then(|pos| pos.checked_add(added))
            .filter(|&next| next <= archive.size)
            .ok_or_else(damaged)?;
    }
    Ok(())
}

pub(super) fn list(
    reader: &Reader,
    cancelled: &impl Fn() -> bool,
) -> Result<(Rar, Option<ArchiveProblem>), Failure> {
    let mut archive = Bytes {
        reader: reader.clone(),
        size: reader.file.metadata()?.len(),
    };
    let fifth = archive.at(0, archive.size.min(RAR5.len() as u64))? == RAR5;
    let mut members = Vec::new();
    let walked = if fifth {
        rar5(&mut archive, &mut members, cancelled)
    } else {
        rar4(&mut archive, &mut members, cancelled)
    };
    let problem = match walked {
        Ok(()) => None,
        Err(Failure::Problem(ArchiveProblem::Damaged)) => Some(ArchiveProblem::Damaged),
        Err(Failure::Io(_)) if cancelled() => return Err(Failure::Stopped),
        Err(Failure::Io(_)) => Some(ArchiveProblem::Damaged),
        Err(failure) => return Err(failure),
    };
    Ok((
        Rar {
            members,
            spelling: Mutex::new(None),
        },
        problem,
    ))
}

impl Rar {
    #[cfg(test)]
    pub fn spelled(&self) -> bool {
        self.spelling.lock().unwrap().is_some()
    }

    pub fn spelling(
        &self,
        path: &Path,
        stamp: Stamp,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Arc<Vec<Vec<u8>>>, Failure> {
        let kept = self
            .spelling
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(lines) = kept {
            return Ok(lines);
        }
        let lines = Arc::new(bsdtar::spelling(
            path,
            stamp,
            self.members.len(),
            cancelled,
        )?);
        *self.spelling.lock().unwrap_or_else(PoisonError::into_inner) = Some(lines.clone());
        Ok(lines)
    }

    pub fn contents<'a, C: Fn() -> bool>(
        &self,
        path: &Path,
        stamp: Stamp,
        index: usize,
        cancelled: &'a C,
    ) -> Result<bsdtar::Output<'a, C>, Failure> {
        let spelling = self.spelling(path, stamp, cancelled)?;
        let member = self.members.get(index).ok_or_else(damaged)?;
        let wanted = bsdtar::normal(&spelling[index]);
        let (mut skip, mut rest) = (0u64, 0u64);
        for (j, other) in self.members.iter().enumerate() {
            if j == index || other.kind != Kind::File || bsdtar::normal(&spelling[j]) != wanted {
                continue;
            }
            if !other.sized {
                return Err(damaged());
            }
            let sum = if j < index { &mut skip } else { &mut rest };
            *sum = sum.checked_add(other.size).ok_or_else(damaged)?;
        }
        if !member.sized && (skip > 0 || rest > 0) {
            return Err(damaged());
        }
        bsdtar::read(
            path,
            stamp,
            &spelling[index],
            (skip, member.sized.then_some(member.size), rest),
            member.encrypted,
            cancelled,
        )
    }
}
