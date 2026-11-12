use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{ChildStdout, Command, ExitStatus, Stdio};
use std::thread::JoinHandle;
use std::time::Duration;

use super::detect::{Stamp, reopen};
use super::{ArchiveProblem, Failure};

pub(super) const TAR: &str = "/usr/bin/tar";
pub(super) const PLACEHOLDER: &str = "wherever-no-password";
pub(super) const KEPT: usize = 64 * 1024;
const CHUNK: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Line {
    Encrypted,
    EncryptedMember,
    Skipped,
    Damaged,
}

pub(super) const LINES: [(&str, Line); 8] = [
    ("Incorrect passphrase", Line::Encrypted),
    ("Enter passphrase:", Line::Encrypted),
    ("Encryption is not supported", Line::Encrypted),
    ("RAR encryption support unavailable.", Line::Encrypted),
    ("Invalid PPMd sequence", Line::EncryptedMember),
    ("Unsupported block header size (was", Line::EncryptedMember),
    ("Cannot extract through symlink", Line::Skipped),
    ("Failed to restore metadata", Line::Skipped),
];

pub(super) fn line(text: &[u8]) -> Line {
    LINES
        .iter()
        .find(|(needle, _)| {
            text.windows(needle.len())
                .any(|window| window == needle.as_bytes())
        })
        .map_or(Line::Damaged, |&(_, line)| line)
}

pub(super) fn problem(stderr: &[u8], encrypted: bool) -> ArchiveProblem {
    let locked = stderr.split(|&b| b == b'\n').any(|text| match line(text) {
        Line::Encrypted => true,
        Line::EncryptedMember => encrypted,
        Line::Skipped | Line::Damaged => false,
    });
    if locked {
        ArchiveProblem::Encrypted
    } else {
        ArchiveProblem::Damaged
    }
}

pub(super) fn command(program: &str) -> Command {
    let mut command = Command::new(program);
    command.env_clear();
    command.env("PATH", "/usr/bin:/bin").stdin(Stdio::null());
    command
}

pub(super) struct Child {
    child: std::process::Child,
    pub stdout: ChildStdout,
    stderr: Option<JoinHandle<Vec<u8>>>,
}

pub(super) fn spawn(mut command: Command, archive: Option<File>) -> Result<Child, Failure> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(fd) = archive.as_ref().map(AsRawFd::as_raw_fd) {
        unsafe {
            command.pre_exec(move || {
                if fd == 3 {
                    let flags = libc::fcntl(3, libc::F_GETFD);
                    if flags < 0 || libc::fcntl(3, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                        return Err(io::Error::last_os_error());
                    }
                } else if libc::dup2(fd, 3) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let mut child = command.spawn()?;
    drop(archive);
    let stdout = child.stdout.take().ok_or(ArchiveProblem::Damaged)?;
    let stderr = child.stderr.take().map(|mut pipe| {
        std::thread::Builder::new()
            .name("wherever-archive-stderr".into())
            .spawn(move || {
                let mut kept = Vec::new();
                let mut buffer = [0; 8192];
                while let Ok(n @ 1..) = pipe.read(&mut buffer) {
                    let room = KEPT - kept.len();
                    kept.extend_from_slice(&buffer[..n.min(room)]);
                }
                kept
            })
    });
    let stderr = match stderr {
        Some(Ok(handle)) => Some(handle),
        Some(Err(e)) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(e.into());
        }
        None => None,
    };
    Ok(Child {
        child,
        stdout,
        stderr,
    })
}

impl Child {
    #[cfg(test)]
    pub fn id(&self) -> u32 {
        self.child.id()
    }

    pub fn wait(&mut self, cancelled: &impl Fn() -> bool) -> Result<ExitStatus, Failure> {
        self.watch(cancelled, || {})
    }

    pub fn output(
        &mut self,
        limit: usize,
        cancelled: &impl Fn() -> bool,
    ) -> Result<(ExitStatus, Vec<u8>), Failure> {
        let fd = self.stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut out = Vec::new();
        let mut buffer = vec![0; CHUNK];
        loop {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            match self.stdout.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) if out.len() + n > limit => return Err(ArchiveProblem::Damaged.into()),
                Ok(n) => out.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(2));
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok((self.wait(cancelled)?, out))
    }

    pub fn watch(
        &mut self,
        cancelled: &impl Fn() -> bool,
        mut tick: impl FnMut(),
    ) -> Result<ExitStatus, Failure> {
        loop {
            if let Some(status) = self.child.try_wait()? {
                return Ok(status);
            }
            if cancelled() {
                return Err(Failure::Stopped);
            }
            tick();
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    pub fn stderr(&mut self) -> Vec<u8> {
        self.stderr
            .take()
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default()
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
pub(super) static SPAWNED: std::sync::Mutex<Vec<(std::path::PathBuf, u32)>> =
    std::sync::Mutex::new(Vec::new());

fn tar(path: &Path, stamp: Stamp, args: &[&OsStr]) -> Result<Child, Failure> {
    let archive = reopen(path, stamp)?;
    let mut command = command(TAR);
    command
        .args(["-f", "/dev/fd/3", "--passphrase", PLACEHOLDER])
        .args(args);
    let child = spawn(command, Some(archive))?;
    #[cfg(test)]
    SPAWNED
        .lock()
        .unwrap()
        .push((path.to_path_buf(), child.id()));
    Ok(child)
}

pub(super) fn unescape(line: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(line.len());
    let mut i = 0;
    while i < line.len() {
        if line[i] == b'\\' {
            let simple = match line.get(i + 1) {
                Some(b'a') => Some(7),
                Some(b'b') => Some(8),
                Some(b'f') => Some(12),
                Some(b'n') => Some(b'\n'),
                Some(b'r') => Some(b'\r'),
                Some(b't') => Some(b'\t'),
                Some(b'v') => Some(11),
                Some(b'\\') => Some(b'\\'),
                _ => None,
            };
            if let Some(b) = simple {
                out.push(b);
                i += 2;
                continue;
            }
            if let Some(digits) = line
                .get(i + 1..i + 4)
                .filter(|d| d.iter().all(|d| (b'0'..=b'7').contains(d)))
            {
                out.push(
                    digits
                        .iter()
                        .fold(0u8, |n, d| n.wrapping_mul(8) | (d - b'0')),
                );
                i += 4;
                continue;
            }
        }
        out.push(line[i]);
        i += 1;
    }
    out
}

pub(super) fn pattern(spelling: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(spelling.len() + 4);
    for &b in spelling {
        if matches!(b, b'\\' | b'*' | b'?' | b'[') {
            out.push(b'\\');
        }
        out.push(b);
    }
    out
}

pub(super) fn normal(spelling: &[u8]) -> Vec<&[u8]> {
    spelling
        .split(|&b| b == b'/')
        .filter(|part| !part.is_empty() && *part != b".")
        .collect()
}

pub(super) fn spelling(
    path: &Path,
    stamp: Stamp,
    count: usize,
    cancelled: &impl Fn() -> bool,
) -> Result<Vec<Vec<u8>>, Failure> {
    let mut child = tar(path, stamp, &[OsStr::new("-t")])?;
    let mut out = Vec::new();
    let mut buffer = vec![0; CHUNK];
    loop {
        if cancelled() {
            return Err(Failure::Stopped);
        }
        match child.stdout.read(&mut buffer)? {
            0 => break,
            n => out.extend_from_slice(&buffer[..n]),
        }
    }
    child.wait(cancelled)?;
    if out.pop().is_some_and(|last| last != b'\n') {
        return Err(ArchiveProblem::Damaged.into());
    }
    let lines: Vec<Vec<u8>> = if out.is_empty() {
        Vec::new()
    } else {
        out.split(|&b| b == b'\n').map(unescape).collect()
    };
    if lines.len() != count {
        return Err(ArchiveProblem::Damaged.into());
    }
    Ok(lines)
}

pub(super) struct Output<'a, C> {
    pub child: Child,
    skip: u64,
    take: Option<u64>,
    rest: u64,
    encrypted: bool,
    cancelled: &'a C,
    done: bool,
}

fn broken(problem: ArchiveProblem) -> io::Error {
    io::Error::other(problem)
}

pub(super) fn read<'a, C: Fn() -> bool>(
    path: &Path,
    stamp: Stamp,
    spelling: &[u8],
    (skip, take, rest): (u64, Option<u64>, u64),
    encrypted: bool,
    cancelled: &'a C,
) -> Result<Output<'a, C>, Failure> {
    let name = OsStr::from_bytes(&pattern(spelling)).to_owned();
    let child = tar(
        path,
        stamp,
        &[
            OsStr::new("-x"),
            OsStr::new("-O"),
            OsStr::new("-n"),
            OsStr::new("--"),
            &name,
        ],
    )?;
    Ok(Output {
        child,
        skip,
        take,
        rest,
        encrypted,
        cancelled,
        done: false,
    })
}

impl<C: Fn() -> bool> Output<'_, C> {
    fn pull(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if (self.cancelled)() {
            return Err(io::Error::other("archive read stopped"));
        }
        self.child.stdout.read(buf)
    }

    fn drain(&mut self, mut left: u64) -> io::Result<()> {
        let mut buffer = vec![0; CHUNK];
        while left > 0 {
            let want = left.min(CHUNK as u64) as usize;
            match self.pull(&mut buffer[..want])? {
                0 => return Err(broken(ArchiveProblem::Damaged)),
                n => left -= n as u64,
            }
        }
        Ok(())
    }

    fn finish(&mut self) -> io::Result<usize> {
        let rest = std::mem::take(&mut self.rest);
        self.drain(rest)?;
        if self.pull(&mut [0])? != 0 {
            return Err(broken(ArchiveProblem::Damaged));
        }
        let status = self
            .child
            .wait(self.cancelled)
            .map_err(|failure| match failure {
                Failure::Problem(problem) => broken(problem),
                Failure::Io(e) => e,
                Failure::Stopped => io::Error::other("archive read stopped"),
            })?;
        if !status.success() {
            let stderr = self.child.stderr();
            return Err(broken(problem(&stderr, self.encrypted)));
        }
        self.done = true;
        Ok(0)
    }
}

impl<C: Fn() -> bool> Read for Output<'_, C> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        if self.skip > 0 {
            let skip = std::mem::take(&mut self.skip);
            self.drain(skip)?;
        }
        match self.take {
            Some(0) => self.finish(),
            Some(left) => {
                let want = left.min(buf.len() as u64) as usize;
                match self.pull(&mut buf[..want])? {
                    0 => Err(broken(ArchiveProblem::Damaged)),
                    n => {
                        self.take = Some(left - n as u64);
                        Ok(n)
                    }
                }
            }
            None => match self.pull(buf)? {
                0 => self.finish(),
                n => Ok(n),
            },
        }
    }
}
