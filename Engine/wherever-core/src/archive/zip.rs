use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;

use ::zip::result::ZipError;
use ::zip::write::SimpleFileOptions;
use ::zip::{AesMode, DateTime, HasZipMetadata, ZIP64_BYTES_THR, ZipArchive, ZipWriter};

use super::detect::Reader;
use super::write::{CHUNK, Task};
use super::{ArchiveProblem, ArchiveSummary, Entry, Failure, guard};
use crate::EngineKind;
use crate::crawl::Attrs;

pub(super) fn problem(error: ZipError) -> ArchiveProblem {
    match error {
        ZipError::UnsupportedArchive(ZipError::PASSWORD_REQUIRED) => ArchiveProblem::PasswordNeeded,
        ZipError::InvalidPassword => ArchiveProblem::WrongPassword,
        ZipError::UnsupportedArchive(_) | ZipError::CompressionMethodNotSupported(_) => {
            ArchiveProblem::Unsupported
        }
        _ => ArchiveProblem::Damaged,
    }
}

pub(super) fn open(
    reader: &Reader,
    summary: &mut ArchiveSummary,
    cancelled: &impl Fn() -> bool,
) -> Result<(ZipArchive<Reader>, Vec<Entry>), Failure> {
    if !reader.is_zip()? {
        return Err(ArchiveProblem::Unsupported.into());
    }
    summary.format = "zip".into();
    let mut zip = ZipArchive::new(reader.clone()).map_err(problem)?;
    if let Err(error) = zip.validate_header_consistency() {
        summary.problem = Some(problem(error));
    }
    let mut entries = Vec::with_capacity(zip.len());
    for index in 0..zip.len() {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let data = zip.by_index_data(index).map_err(problem)?;
        let raw = data.name().map_err(problem)?;
        let Some(path) = guard::name(&raw) else {
            summary.skipped += 1;
            continue;
        };
        let mode = data
            .unix_mode()
            .unwrap_or(if data.is_dir() { 0o40755 } else { 0o100644 });
        let kind = match mode as u16 & libc::S_IFMT {
            libc::S_IFDIR => EngineKind::Folder,
            libc::S_IFLNK => EngineKind::Link,
            libc::S_IFREG | 0 => {
                if data.is_dir() {
                    EngineKind::Folder
                } else {
                    EngineKind::File
                }
            }
            _ => {
                summary.skipped += 1;
                continue;
            }
        };
        let modified = data.last_modified().map_or(0, |d| {
            let mut tm: libc::tm = unsafe { std::mem::zeroed() };
            tm.tm_year = i32::from(d.year()) - 1900;
            tm.tm_mon = i32::from(d.month()) - 1;
            tm.tm_mday = i32::from(d.day());
            tm.tm_hour = i32::from(d.hour());
            tm.tm_min = i32::from(d.minute());
            tm.tm_sec = i32::from(d.second());
            tm.tm_isdst = -1;
            unsafe { libc::mktime(&mut tm) }
        });
        let mut entry = Entry {
            path,
            index: Some(index),
            attrs: Attrs {
                kind,
                size: if kind == EngineKind::Folder {
                    0
                } else {
                    data.size()
                },
                mtime: modified,
                created: 0,
                opened: 0,
                mount: false,
                hidden: false,
            },
            mode: mode & 0o777,
            target: None,
            encrypted: data.encrypted(),
            sized: true,
            disk: None,
        };
        summary.encrypted |= entry.encrypted;
        entry.attrs.hidden = super::hidden(&entry.path);
        if kind == EngineKind::Link && !entry.encrypted {
            let file = zip
                .by_index_with_options(
                    index,
                    ::zip::read::ZipReadOptions::new().enforce_header_consistency(true),
                )
                .map_err(problem)?;
            let mut bytes = Vec::new();
            file.take(libc::PATH_MAX as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| ArchiveProblem::Damaged)?;
            let target = String::from_utf8(bytes)
                .ok()
                .filter(|s| s.len() <= libc::PATH_MAX as usize);
            let Some(target) = target else {
                summary.skipped += 1;
                summary.problem = Some(ArchiveProblem::PointsOutside { name: entry.path });
                continue;
            };
            entry.target = Some(target);
        }
        entries.push(entry);
    }
    Ok((zip, entries))
}

pub(super) fn old_encryption(zip: &ZipArchive<Reader>) -> bool {
    (0..zip.len()).any(|index| {
        zip.by_index_data(index)
            .is_ok_and(|data| data.encrypted() && data.get_metadata().aes_settings().is_none())
    })
}

fn dos(mtime: i64) -> DateTime {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let local = !unsafe { libc::localtime_r(&mtime, &mut tm) }.is_null();
    let year = tm.tm_year + 1900;
    let (year, month, day, hour, minute, second) = if !local || year < 1980 {
        (1980, 1, 1, 0, 0, 0)
    } else if year > 2107 {
        (2107, 12, 31, 23, 59, 58)
    } else {
        (
            year as u16,
            (tm.tm_mon + 1) as u8,
            tm.tm_mday as u8,
            tm.tm_hour as u8,
            tm.tm_min as u8,
            tm.tm_sec as u8,
        )
    };
    DateTime::from_date_and_time(year, month, day, hour, minute, second).unwrap_or_default()
}

pub(super) fn options(size: u64, mode: u32, mtime: i64) -> SimpleFileOptions {
    SimpleFileOptions::default()
        .unix_permissions(mode & 0o7777)
        .last_modified_time(dos(mtime))
        .large_file(size >= ZIP64_BYTES_THR)
}

fn named(zip: &ZipArchive<impl Read + std::io::Seek>, index: usize) -> Result<String, Failure> {
    let data = zip.by_index_data(index).map_err(problem)?;
    let raw = data.name().map_err(problem)?;
    Ok(guard::name(&raw).unwrap_or_else(|| raw.into_owned()))
}

pub(super) fn kept(
    zip: &ZipArchive<Reader>,
    deleted: &[&str],
) -> Result<Vec<(usize, String)>, Failure> {
    let mut kept = Vec::new();
    for index in 0..zip.len() {
        let path = named(zip, index)?;
        if !deleted.iter().any(|top| super::expand::inside(&path, top)) {
            kept.push((index, path));
        }
    }
    Ok(kept)
}

pub(super) fn names(out: &Path) -> Result<Vec<String>, Failure> {
    let zip = ZipArchive::new(File::open(out)?).map_err(problem)?;
    (0..zip.len()).map(|index| named(&zip, index)).collect()
}

pub(super) fn rewrite(
    zip: &ZipArchive<Reader>,
    kept: &[(usize, String)],
    added: &[&Entry],
    out: &File,
    password: Option<&[u8]>,
    task: &Task,
    cancelled: &impl Fn() -> bool,
) -> Result<(), Failure> {
    let mut source = zip.clone();
    let mut writer = ZipWriter::new(out);
    writer
        .set_raw_comment(source.comment().into())
        .map_err(problem)?;
    for &(index, _) in kept {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let file = source.by_index_raw(index).map_err(problem)?;
        let size = file.compressed_size();
        let date = file.last_modified().unwrap_or_default();
        writer
            .raw_copy_file_touch(file, date, None)
            .map_err(problem)?;
        task.advance(size);
    }
    let mut buffer = vec![0; CHUNK];
    for entry in added {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        let plain = options(entry.attrs.size, entry.mode, entry.attrs.mtime);
        let name = entry.path.as_str();
        match entry.attrs.kind {
            EngineKind::Folder => writer.add_directory(name, plain).map_err(problem)?,
            EngineKind::Link => {
                let target = entry.target.as_deref().ok_or(ArchiveProblem::Damaged)?;
                writer.add_symlink(name, target, plain).map_err(problem)?;
            }
            EngineKind::File => {
                let disk = entry.disk.as_deref().ok_or(ArchiveProblem::Damaged)?;
                let mut input = super::detect::file(disk)?;
                match password {
                    Some(password) => writer.start_file(
                        name,
                        plain.with_aes_encryption_bytes(AesMode::Aes256, password),
                    ),
                    None => writer.start_file(name, plain),
                }
                .map_err(problem)?;
                loop {
                    if cancelled() {
                        return Err(Failure::Stopped);
                    }
                    let n = input.read(&mut buffer).map_err(|_| ArchiveProblem::Gone {
                        name: disk.to_string_lossy().into_owned(),
                    })?;
                    if n == 0 {
                        break;
                    }
                    writer.write_all(&buffer[..n])?;
                    task.advance(n as u64);
                }
            }
        }
    }
    writer.finish().map_err(problem)?;
    Ok(())
}
