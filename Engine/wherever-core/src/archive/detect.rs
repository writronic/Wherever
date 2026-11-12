use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use super::{ArchiveProblem, Failure};

#[derive(Clone)]
pub(super) struct Reader {
    pub file: Arc<File>,
    at: u64,
    closed: Arc<AtomicBool>,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
}

impl Stamp {
    pub fn read(file: &File) -> io::Result<Self> {
        let m = file.metadata()?;
        Ok(Self {
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
        })
    }

    pub fn key(&self) -> String {
        format!(
            "{}-{}-{}-{}.{}",
            self.device as i32, self.inode, self.size, self.modified.0, self.modified.1
        )
    }
}

pub(super) fn resolved(path: &Path) -> PathBuf {
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => crate::engine::real(parent).join(name),
        _ => path.to_path_buf(),
    }
}

pub(super) fn file(path: &Path) -> Result<File, ArchiveProblem> {
    let gone = || ArchiveProblem::Gone {
        name: path.to_string_lossy().into_owned(),
    };
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
        .open(resolved(path))
        .map_err(|_| gone())?;
    if !file.metadata().map_err(|_| gone())?.is_file() {
        return Err(gone());
    }
    Ok(file)
}

pub(super) fn reopen(path: &Path, stamp: Stamp) -> Result<File, Failure> {
    let file = file(path)?;
    if Stamp::read(&file)? != stamp {
        return Err(ArchiveProblem::Changed.into());
    }
    Ok(file)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Format {
    Zip,
    Tar,
    Rar,
    Pkg,
    Image,
}

const TARBALLS: [&str; 8] = [
    ".tar", ".tgz", ".tar.gz", ".tbz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz",
];

pub(super) fn tarball(name: &str) -> bool {
    let name = name.to_lowercase();
    TARBALLS.iter().any(|suffix| name.ends_with(suffix))
}

pub(super) fn pkg(name: &str) -> bool {
    name.to_lowercase().ends_with(".pkg")
}

pub(super) fn image(name: &str) -> bool {
    name.to_lowercase().ends_with(".dmg")
}

impl Reader {
    pub fn open(path: &Path, closed: Arc<AtomicBool>) -> Result<Self, ArchiveProblem> {
        Ok(Self {
            file: Arc::new(file(path)?),
            at: 0,
            closed,
        })
    }

    pub fn format(&self, tarball: bool, pkg: bool, image: bool) -> io::Result<Option<Format>> {
        let mut head = [0; 262];
        let n = self.file.read_at(&mut head, 0)?;
        let head = &head[..n];
        Ok(if image {
            Some(Format::Image)
        } else if pkg && head.starts_with(b"xar!") {
            Some(Format::Pkg)
        } else if head.starts_with(b"Rar!\x1a\x07\x00") || head.starts_with(b"Rar!\x1a\x07\x01\x00")
        {
            Some(Format::Rar)
        } else if head.get(257..262) == Some(b"ustar".as_slice())
            || tarball
                && (head.starts_with(&[0x1f, 0x8b])
                    || head.starts_with(b"BZh")
                    || head.starts_with(&[0xfd, b'7', b'z', b'X', b'Z', 0]))
        {
            Some(Format::Tar)
        } else if self.is_zip()? {
            Some(Format::Zip)
        } else {
            None
        })
    }

    pub fn is_zip(&self) -> io::Result<bool> {
        let size = self.file.metadata()?.len();
        let mut first = vec![0; size.min(64 * 1024) as usize];
        let mut last = vec![0; size.min(512) as usize];
        self.file.read_exact_at(&mut first, 0)?;
        self.file
            .read_exact_at(&mut last, size.saturating_sub(512))?;
        Ok(first
            .windows(4)
            .chain(last.windows(4))
            .any(|s| matches!(s, b"PK\x03\x04" | b"PK\x05\x06" | b"PK\x06\x06")))
    }
}

impl Read for Reader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.closed.load(Ordering::Relaxed) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "archive closed"));
        }
        let n = self.file.read_at(buf, self.at)?;
        self.at += n as u64;
        Ok(n)
    }
}

impl Seek for Reader {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let at = match from {
            SeekFrom::Start(n) => Some(n),
            SeekFrom::Current(n) => self.at.checked_add_signed(n),
            SeekFrom::End(n) => self.file.metadata()?.len().checked_add_signed(n),
        }
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "archive seek outside file"))?;
        self.at = at;
        Ok(at)
    }
}
