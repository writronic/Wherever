use std::ffi::{CString, OsStr, c_char, c_void};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr;
use std::time::Duration;

pub const COMMAND_DONE: &str = "com.writronic.wherever.commandDone";

pub trait Host {
    fn app(&self) -> Option<PathBuf>;
    fn running(&self, app: &Path) -> bool;
    fn open(&self, app: &Path) -> io::Result<()>;
    fn wait(&self, step: Duration);
    fn done(&self, app: &Path);
}

pub struct System;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFNotificationCenterGetDistributedCenter() -> *mut c_void;
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        text: *const c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFNotificationCenterPostNotification(
        center: *mut c_void,
        name: *const c_void,
        object: *const c_void,
        user_info: *const c_void,
        deliver_immediately: u8,
    );
    fn CFRelease(object: *const c_void);
}

const UTF8: u32 = 0x0800_0100;

fn string(text: &CString) -> *const c_void {
    unsafe { CFStringCreateWithCString(ptr::null(), text.as_ptr(), UTF8) }
}

pub fn holding(tool: &Path) -> Option<PathBuf> {
    let contents = tool.parent()?.parent()?;
    let app = contents.parent()?;
    (tool.parent()?.file_name()? == "Helpers"
        && contents.file_name()? == "Contents"
        && app.extension()? == "app")
        .then(|| app.to_path_buf())
}

pub fn inside(exe: &Path, app: &Path) -> bool {
    exe.starts_with(app.join("Contents/MacOS"))
}

pub fn paths() -> Vec<PathBuf> {
    let count = unsafe { libc::proc_listallpids(ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    let mut pids = vec![0 as libc::pid_t; count as usize + 64];
    let bytes = (pids.len() * size_of::<libc::pid_t>()) as libc::c_int;
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    let mut buffer = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    pids.iter()
        .take(filled.max(0) as usize)
        .filter_map(|&pid| {
            let len =
                unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
            (len > 0).then(|| PathBuf::from(OsStr::from_bytes(&buffer[..len as usize])))
        })
        .collect()
}

impl Host for System {
    fn app(&self) -> Option<PathBuf> {
        holding(&std::env::current_exe().ok()?.canonicalize().ok()?)
    }

    fn running(&self, app: &Path) -> bool {
        paths().iter().any(|exe| inside(exe, app))
    }

    fn open(&self, app: &Path) -> io::Result<()> {
        let status = Command::new("/usr/bin/open")
            .args(["-g", "-a"])
            .arg(app)
            .args(["--args", "--command", "serve"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        status
            .success()
            .then_some(())
            .ok_or_else(|| io::Error::other("open failed"))
    }

    fn wait(&self, step: Duration) {
        std::thread::sleep(step);
    }

    fn done(&self, app: &Path) {
        let (Ok(name), Ok(object)) = (
            CString::new(COMMAND_DONE),
            CString::new(app.as_os_str().as_bytes()),
        ) else {
            return;
        };
        let (name, object) = (string(&name), string(&object));
        unsafe {
            if !name.is_null() {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDistributedCenter(),
                    name,
                    object,
                    ptr::null(),
                    1,
                );
            }
            for s in [name, object] {
                if !s.is_null() {
                    CFRelease(s);
                }
            }
        }
    }
}
