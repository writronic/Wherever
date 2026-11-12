use std::ffi::{CStr, CString, c_void};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr::null;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;

pub const MUST_SCAN_SUBDIRS: u32 = 0x1;
pub const USER_DROPPED: u32 = 0x2;
pub const KERNEL_DROPPED: u32 = 0x4;
pub const EVENT_IDS_WRAPPED: u32 = 0x8;
pub const HISTORY_DONE: u32 = 0x10;
pub const MOUNT: u32 = 0x40;
pub const UNMOUNT: u32 = 0x80;
const CREATE_FLAG_NO_DEFER: u32 = 0x2;
const CREATE_FLAG_FULL_HISTORY: u32 = 0x80;
const UTF8: u32 = 0x0800_0100;
const LATENCY: f64 = 0.3;

pub struct Event {
    pub path: Vec<u8>,
    pub flags: u32,
    pub id: u64,
    pub stream: u32,
}

struct Info {
    tx: Sender<Vec<Event>>,
    stream: u32,
    root: Option<Vec<u8>>,
}

#[repr(C)]
struct Context {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: extern "C" fn(*const c_void),
    copy_description: *const c_void,
}

type StreamCall = unsafe extern "C" fn(*mut c_void);

type Callback =
    extern "C" fn(*const c_void, *mut c_void, usize, *mut c_void, *const u32, *const u64);

#[derive(Clone, Copy)]
pub struct Api {
    create: unsafe extern "C" fn(
        *const c_void,
        Callback,
        *const Context,
        *const c_void,
        u64,
        f64,
        u32,
    ) -> *mut c_void,
    create_device: unsafe extern "C" fn(
        *const c_void,
        Callback,
        *const Context,
        libc::dev_t,
        *const c_void,
        u64,
        f64,
        u32,
    ) -> *mut c_void,
    set_queue: unsafe extern "C" fn(*mut c_void, *mut c_void),
    start: unsafe extern "C" fn(*mut c_void) -> u8,
    stop: StreamCall,
    invalidate: StreamCall,
    release: StreamCall,
    current_id: unsafe extern "C" fn() -> u64,
    cf_release: unsafe extern "C" fn(*const c_void),
    string: unsafe extern "C" fn(*const c_void, *const libc::c_char, u32) -> *const c_void,
    array: unsafe extern "C" fn(
        *const c_void,
        *const *const c_void,
        isize,
        *const c_void,
    ) -> *const c_void,
    array_callbacks: *const c_void,
}

unsafe impl Send for Api {}
unsafe impl Sync for Api {}

unsafe extern "C" {
    fn dispatch_queue_create(label: *const libc::c_char, attr: *const c_void) -> *mut c_void;
    fn dispatch_queue_attr_make_with_qos_class(
        attr: *const c_void,
        qos: u32,
        relative_priority: i32,
    ) -> *const c_void;
    fn dispatch_release(object: *mut c_void);
}

impl Api {
    pub fn load() -> Result<Api, String> {
        Api::from(
            c"/System/Library/Frameworks/CoreServices.framework/CoreServices",
            c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        )
    }

    fn from(services: &CStr, foundation: &CStr) -> Result<Api, String> {
        let (cs, cf) = (open(services)?, open(foundation)?);
        unsafe {
            Ok(Api {
                create: sym(cs, c"FSEventStreamCreate")?,
                create_device: sym(cs, c"FSEventStreamCreateRelativeToDevice")?,
                set_queue: sym(cs, c"FSEventStreamSetDispatchQueue")?,
                start: sym(cs, c"FSEventStreamStart")?,
                stop: sym(cs, c"FSEventStreamStop")?,
                invalidate: sym(cs, c"FSEventStreamInvalidate")?,
                release: sym(cs, c"FSEventStreamRelease")?,
                current_id: sym(cs, c"FSEventsGetCurrentEventId")?,
                cf_release: sym(cf, c"CFRelease")?,
                string: sym(cf, c"CFStringCreateWithCString")?,
                array: sym(cf, c"CFArrayCreate")?,
                array_callbacks: sym(cf, c"kCFTypeArrayCallBacks")?,
            })
        }
    }

    pub fn current_id(&self) -> u64 {
        unsafe { (self.current_id)() }
    }

    fn watch(
        &self,
        root: &Path,
        device: libc::dev_t,
        since: u64,
        tx: Sender<Vec<Event>>,
        stream: u32,
    ) -> Result<Stream, String> {
        let root = root.as_os_str().as_bytes();
        let path = CString::new(if device == 0 { root } else { &b""[..] })
            .map_err(|_| "the root path holds a NUL".to_owned())?;
        unsafe {
            let cf_path = (self.string)(null(), path.as_ptr(), UTF8);
            if cf_path.is_null() {
                return Err("the root path is not UTF-8".to_owned());
            }
            let paths = (self.array)(null(), &cf_path, 1, self.array_callbacks);
            (self.cf_release)(cf_path);
            if paths.is_null() {
                return Err("CFArrayCreate failed".to_owned());
            }
            let info = Info {
                tx,
                stream,
                root: (device != 0).then(|| root.to_vec()),
            };
            let ctx = Context {
                version: 0,
                info: Box::into_raw(Box::new(info)).cast(),
                retain: null(),
                release: release_info,
                copy_description: null(),
            };
            let s = if device == 0 {
                (self.create)(
                    null(),
                    on_events,
                    &ctx,
                    paths,
                    since,
                    LATENCY,
                    CREATE_FLAG_NO_DEFER,
                )
            } else {
                (self.create_device)(
                    null(),
                    on_events,
                    &ctx,
                    device,
                    paths,
                    since,
                    LATENCY,
                    CREATE_FLAG_NO_DEFER | CREATE_FLAG_FULL_HISTORY,
                )
            };
            (self.cf_release)(paths);
            if s.is_null() {
                let call = if device == 0 {
                    "FSEventStreamCreate"
                } else {
                    "FSEventStreamCreateRelativeToDevice"
                };
                return Err(format!("{call} failed"));
            }
            let qos = libc::qos_class_t::QOS_CLASS_USER_INITIATED as u32;
            let queue = dispatch_queue_create(
                c"com.writronic.wherever.fsevents".as_ptr(),
                dispatch_queue_attr_make_with_qos_class(null(), qos, 0),
            );
            (self.set_queue)(s, queue);
            if (self.start)(s) == 0 {
                (self.invalidate)(s);
                (self.release)(s);
                dispatch_release(queue);
                return Err("FSEventStreamStart failed".to_owned());
            }
            Ok(Stream {
                api: *self,
                stream: s,
                queue,
            })
        }
    }
}

pub(crate) fn open(path: &CStr) -> Result<*mut c_void, String> {
    let h = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_LAZY | libc::RTLD_LOCAL) };
    if h.is_null() {
        return Err(format!("cannot load {}", path.to_string_lossy()));
    }
    Ok(h)
}

pub(crate) unsafe fn sym<T>(h: *mut c_void, name: &CStr) -> Result<T, String> {
    let p = unsafe { libc::dlsym(h, name.as_ptr()) };
    if p.is_null() {
        return Err(format!("{} is missing", name.to_string_lossy()));
    }
    Ok(unsafe { std::mem::transmute_copy(&p) })
}

pub(crate) fn device_uuid(dev: libc::dev_t) -> Option<String> {
    let cs = open(c"/System/Library/Frameworks/CoreServices.framework/CoreServices").ok()?;
    let cf = open(c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation").ok()?;
    unsafe {
        let copy: unsafe extern "C" fn(libc::dev_t) -> *const c_void =
            sym(cs, c"FSEventsCopyUUIDForDevice").ok()?;
        let to_string: unsafe extern "C" fn(*const c_void, *const c_void) -> *const c_void =
            sym(cf, c"CFUUIDCreateString").ok()?;
        let get: unsafe extern "C" fn(*const c_void, *mut libc::c_char, isize, u32) -> u8 =
            sym(cf, c"CFStringGetCString").ok()?;
        let release: unsafe extern "C" fn(*const c_void) = sym(cf, c"CFRelease").ok()?;
        let uuid = copy(dev);
        if uuid.is_null() {
            return None;
        }
        let text = to_string(null(), uuid);
        release(uuid);
        if text.is_null() {
            return None;
        }
        let mut buf = [0 as libc::c_char; 64];
        let ok = get(text, buf.as_mut_ptr(), buf.len() as isize, UTF8) != 0;
        release(text);
        ok.then(|| CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned())
    }
}

pub(crate) fn last_id_before(dev: libc::dev_t, time: f64) -> Result<u64, String> {
    let cs = open(c"/System/Library/Frameworks/CoreServices.framework/CoreServices")?;
    unsafe {
        let last: unsafe extern "C" fn(libc::dev_t, f64) -> u64 =
            sym(cs, c"FSEventsGetLastEventIdForDeviceBeforeTime")?;
        Ok(last(dev, time))
    }
}

#[cfg(test)]
impl Api {
    pub(crate) fn watch_device(
        &self,
        dev: libc::dev_t,
        since: u64,
        tx: Sender<Vec<Event>>,
    ) -> Result<Stream, String> {
        self.watch(Path::new(""), dev, since, tx, 0)
    }
}

fn device_path(root: &[u8], raw: &[u8]) -> Vec<u8> {
    let rel = raw.strip_prefix(b"/").unwrap_or(raw);
    let mut path = root.to_vec();
    if !rel.is_empty() {
        if path.last() != Some(&b'/') {
            path.push(b'/');
        }
        path.extend_from_slice(rel);
    }
    path
}

extern "C" fn on_events(
    _stream: *const c_void,
    info: *mut c_void,
    n: usize,
    paths: *mut c_void,
    flags: *const u32,
    ids: *const u64,
) {
    let info = unsafe { &*(info as *const Info) };
    let paths = paths as *const *const libc::c_char;
    let batch = (0..n)
        .map(|i| unsafe {
            let raw = CStr::from_ptr(*paths.add(i)).to_bytes();
            Event {
                path: info
                    .root
                    .as_ref()
                    .map_or_else(|| raw.to_vec(), |root| device_path(root, raw)),
                flags: *flags.add(i),
                id: *ids.add(i),
                stream: info.stream,
            }
        })
        .collect();
    let _ = info.tx.send(batch);
}

extern "C" fn release_info(info: *const c_void) {
    let boxed = info.cast_mut().cast::<Info>();
    if !boxed.is_null() {
        drop(unsafe { Box::from_raw(boxed) });
    }
}

pub struct Stream {
    api: Api,
    stream: *mut c_void,
    queue: *mut c_void,
}

unsafe impl Send for Stream {}

impl Drop for Stream {
    fn drop(&mut self) {
        unsafe {
            (self.api.stop)(self.stream);
            (self.api.invalidate)(self.stream);
            (self.api.release)(self.stream);
            dispatch_release(self.queue);
        }
    }
}

pub struct Watcher {
    api: Option<Api>,
    events: Option<Sender<Vec<Event>>>,
    stream: Option<Stream>,
    paused: Arc<AtomicBool>,
    parked: bool,
    pub count: u32,
    pub since: u64,
    pub replaying: bool,
    pub device: libc::dev_t,
}

impl Watcher {
    pub fn new(events: Sender<Vec<Event>>, paused: Arc<AtomicBool>) -> Watcher {
        Watcher {
            api: None,
            events: Some(events),
            stream: None,
            paused,
            parked: false,
            count: 0,
            since: 0,
            replaying: false,
            device: 0,
        }
    }

    fn api(&mut self) -> Result<Api, String> {
        if let Some(api) = self.api {
            return Ok(api);
        }
        let api = Api::load()?;
        self.api = Some(api);
        Ok(api)
    }

    pub fn current_id(&mut self) -> Result<u64, String> {
        Ok(self.api()?.current_id())
    }

    pub fn watch(&mut self, root: &Path, since: u64) -> Result<(), String> {
        let tx = self
            .events
            .clone()
            .ok_or_else(|| "the engine stopped".to_owned())?;
        if self.paused.load(Ordering::Relaxed) {
            self.stream = None;
            (self.parked, self.since, self.replaying) = (true, since, true);
            return Ok(());
        }
        let n = self.count + 1;
        let stream = self.api()?.watch(root, self.device, since, tx, n)?;
        (self.count, self.since, self.replaying, self.parked) = (n, since, true, false);
        self.stream = Some(stream);
        Ok(())
    }

    pub fn current(&self) -> u32 {
        if self.parked { 0 } else { self.count }
    }

    pub fn follow_switch(&mut self) {
        if self.paused.load(Ordering::Relaxed) {
            self.parked |= self.stream.take().is_some();
        } else if self.parked
            && let Some(tx) = &self.events
        {
            let _ = tx.send(Vec::new());
        }
    }

    pub fn resume_from(&mut self, last_applied: Option<u64>) -> Option<u64> {
        if !self.parked || self.paused.load(Ordering::Relaxed) {
            return None;
        }
        self.parked = false;
        Some(
            last_applied
                .filter(|_| !self.replaying)
                .unwrap_or(self.since),
        )
    }

    pub fn close(&mut self) {
        if let Some(tx) = self.events.take() {
            let _ = tx.send(Vec::new());
        }
        self.stream = None;
    }

    #[cfg(test)]
    pub(crate) fn running(&self) -> bool {
        self.stream.is_some()
    }

    #[cfg(test)]
    pub(crate) fn watched_device(&self) -> libc::dev_t {
        let Some(running) = &self.stream else {
            return 0;
        };
        let cs = open(c"/System/Library/Frameworks/CoreServices.framework/CoreServices").unwrap();
        unsafe {
            let get: unsafe extern "C" fn(*mut c_void) -> libc::dev_t =
                sym(cs, c"FSEventStreamGetDeviceBeingWatched").unwrap();
            get(running.stream)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_framework_or_symbol_is_an_error_not_a_crash() {
        let services = c"/System/Library/Frameworks/CoreServices.framework/CoreServices";
        let missing = c"/System/Library/Frameworks/NoSuch.framework/NoSuch";
        assert!(Api::from(missing, services).is_err_and(|e| e.contains("NoSuch")));
        let h = open(services).unwrap();
        let none = unsafe { sym::<*const c_void>(h, c"WhereverNoSuchSymbol") };
        assert!(none.is_err_and(|e| e.contains("WhereverNoSuchSymbol")));
        assert!(Api::load().unwrap().current_id() > 0);
    }

    #[test]
    #[ignore = "timing: run by the measuring pass"]
    fn timing_history_uuid_read() {
        use std::os::unix::fs::MetadataExt;
        let dev = std::fs::metadata(std::env::temp_dir()).unwrap().dev() as libc::dev_t;
        device_uuid(dev);
        let mut ms: Vec<f64> = (0..10)
            .map(|_| {
                let t = std::time::Instant::now();
                device_uuid(dev);
                t.elapsed().as_secs_f64() * 1000.0
            })
            .collect();
        ms.sort_by(f64::total_cmp);
        println!(
            "history uuid read: median {:.3} ms, slowest {:.3} ms",
            (ms[4] + ms[5]) / 2.0,
            ms[9]
        );
    }

    #[test]
    fn device_event_paths_join_the_disk_root() {
        let (tx, rx) = std::sync::mpsc::channel();
        let info = Box::into_raw(Box::new(Info {
            tx,
            stream: 7,
            root: Some(b"/Volumes/Disk".to_vec()),
        }));
        let raw = [c"/", c"", c"Alpha", c"Alpha/Beta/"];
        let paths: Vec<*const libc::c_char> = raw.iter().map(|p| p.as_ptr()).collect();
        let flags = [MUST_SCAN_SUBDIRS | USER_DROPPED, 0, 0, 0];
        let ids = [1u64, 2, 3, 4];
        on_events(
            null(),
            info.cast(),
            raw.len(),
            paths.as_ptr().cast_mut().cast(),
            flags.as_ptr(),
            ids.as_ptr(),
        );
        release_info(info.cast::<c_void>());
        let got: Vec<_> = rx
            .try_recv()
            .unwrap()
            .into_iter()
            .map(|e| (String::from_utf8(e.path).unwrap(), e.flags, e.id, e.stream))
            .collect();
        let at = |path: &str, flags, id| (path.to_owned(), flags, id, 7);
        assert_eq!(
            got,
            [
                at("/Volumes/Disk", MUST_SCAN_SUBDIRS | USER_DROPPED, 1),
                at("/Volumes/Disk", 0, 2),
                at("/Volumes/Disk/Alpha", 0, 3),
                at("/Volumes/Disk/Alpha/Beta/", 0, 4),
            ]
        );
    }
}
