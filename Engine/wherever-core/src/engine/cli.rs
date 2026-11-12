use std::ffi::OsStr;
use std::fs::{self, DirBuilder, Permissions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::{BEST_MATCH, Shared, parse, said, scan, spawn};
use crate::{EngineColumn, EngineHit, EngineKind, EnginePhase, EngineSort};
use crate::{crawl, query};

pub(super) const SOCKET: &str = "wherever.sock";
const MAGIC: &[u8] = b"WHV1";
const MAX_REQUEST: usize = 64 * 1024;
const MAX_CONNECTIONS: usize = 8;
const READ_WAIT: Duration = Duration::from_secs(5);
const WRITE_WAIT: Duration = Duration::from_secs(10);
const PAGE_ROWS: usize = 4096;
const SUN_PATH: usize = 104;

fn socket_folder() -> io::Result<PathBuf> {
    let mut cache = [0u8; libc::PATH_MAX as usize];
    let len = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_CACHE_DIR,
            cache.as_mut_ptr().cast(),
            cache.len(),
        )
    };
    if len <= 1 || len > cache.len() {
        return Err(io::Error::other("cannot find your per-user cache folder"));
    }
    Ok(Path::new(OsStr::from_bytes(&cache[..len - 1])).join("com.writronic.wherever"))
}

pub(super) struct Server {
    path: PathBuf,
    port: Arc<Port>,
    wake: Option<io::PipeWriter>,
    thread: Option<JoinHandle<()>>,
}

struct Port {
    stop: AtomicBool,
    open: AtomicUsize,
    #[cfg(test)]
    nosigpipe: std::sync::Mutex<Vec<libc::c_int>>,
}

struct Slot(Arc<Port>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.open.fetch_sub(1, Ordering::SeqCst);
    }
}

struct Request {
    query: String,
    sort: EngineSort,
    limit: usize,
    marks: bool,
}

impl Server {
    pub(super) fn start(shared: &Arc<Shared>) -> io::Result<Server> {
        let folder = match &shared.settings.socket_folder {
            Some(folder) => folder.clone(),
            None => socket_folder()?,
        };
        let path = folder.join(SOCKET);
        if path.as_os_str().len() >= SUN_PATH {
            return Err(io::Error::other(format!(
                "{} is longer than the {} bytes a socket path can hold",
                path.display(),
                SUN_PATH - 1
            )));
        }
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&folder)?;
        fs::set_permissions(&folder, Permissions::from_mode(0o700))?;
        if fs::symlink_metadata(&path).is_ok() {
            if UnixStream::connect(&path).is_ok() {
                return Err(io::Error::other(format!(
                    "another copy of Wherever already listens at {}",
                    path.display()
                )));
            }
            fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        let ready = fs::set_permissions(&path, Permissions::from_mode(0o600))
            .and_then(|()| listener.set_nonblocking(true))
            .and_then(|()| io::pipe());
        let (asleep, wake) = match ready {
            Ok(pipe) => pipe,
            Err(e) => {
                let _ = fs::remove_file(&path);
                return Err(e);
            }
        };
        let port = Arc::new(Port {
            stop: AtomicBool::new(false),
            open: AtomicUsize::new(0),
            #[cfg(test)]
            nosigpipe: std::sync::Mutex::new(Vec::new()),
        });
        let started = spawn("wherever-cli", {
            let (shared, port) = (shared.clone(), port.clone());
            move || accept(&shared, &port, &listener, &asleep)
        });
        match started {
            Ok(thread) => Ok(Server {
                path,
                port,
                wake: Some(wake),
                thread: Some(thread),
            }),
            Err(e) => {
                let _ = fs::remove_file(&path);
                Err(e)
            }
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.port.stop.store(true, Ordering::SeqCst);
        if let Some(mut wake) = self.wake.take() {
            let _ = wake.write_all(&[0]);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let _ = fs::remove_file(&self.path);
    }
}

fn accept(
    shared: &Arc<Shared>,
    port: &Arc<Port>,
    listener: &UnixListener,
    asleep: &io::PipeReader,
) {
    let mut fds = [listener.as_raw_fd(), asleep.as_raw_fd()].map(|fd| libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    });
    while !port.stop.load(Ordering::SeqCst) {
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) } < 0 {
            if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                thread::sleep(Duration::from_millis(100));
            }
            continue;
        }
        if fds[1].revents != 0 {
            return;
        }
        match listener.accept() {
            Ok((stream, _)) => admit(shared, port, stream),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(_) => thread::sleep(Duration::from_millis(100)),
        }
    }
}

fn admit(shared: &Arc<Shared>, port: &Arc<Port>, stream: UnixStream) {
    if prepare(&stream).is_err() || !same_user(&stream, unsafe { libc::geteuid() }) {
        return;
    }
    #[cfg(test)]
    port.nosigpipe
        .lock()
        .unwrap()
        .push(option(&stream, libc::SO_NOSIGPIPE));
    let taken = port
        .open
        .try_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
            (n < MAX_CONNECTIONS).then_some(n + 1)
        });
    if taken.is_err() {
        let message = format!("Wherever is answering {MAX_CONNECTIONS} other requests. Try again.");
        let _ = (&stream).write_all(&failure("busy", &message));
        return;
    }
    let slot = Slot(port.clone());
    let started = spawn("wherever-cli-request", {
        let shared = shared.clone();
        move || {
            let _slot = slot;
            handle(&shared, &stream);
        }
    });
    if let Err(e) = started {
        shared.fault(format!("a command-line request did not start: {e}"));
    }
}

fn prepare(stream: &UnixStream) -> io::Result<()> {
    let on: libc::c_int = 1;
    let set = unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&raw const on).cast(),
            size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    if set != 0 {
        return Err(io::Error::last_os_error());
    }
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(READ_WAIT))?;
    stream.set_write_timeout(Some(WRITE_WAIT))
}

fn same_user(stream: &UnixStream, uid: libc::uid_t) -> bool {
    let (mut euid, mut egid) = (0, 0);
    (unsafe { libc::getpeereid(stream.as_raw_fd(), &mut euid, &mut egid) }) == 0 && euid == uid
}

#[cfg(test)]
fn option(stream: &UnixStream, name: libc::c_int) -> libc::c_int {
    let (mut value, mut size): (libc::c_int, libc::socklen_t) =
        (0, size_of::<libc::c_int>() as libc::socklen_t);
    unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            name,
            (&raw mut value).cast(),
            &mut size,
        )
    };
    value
}

fn handle(shared: &Shared, stream: &UnixStream) {
    let mut asked = Vec::new();
    if stream
        .take(MAX_REQUEST as u64 + 1)
        .read_to_end(&mut asked)
        .is_err()
    {
        return;
    }
    let _ = match request(&asked) {
        Ok(asked) => respond(shared, stream, &asked),
        Err((code, message)) => (&*stream).write_all(&failure(code, &message)),
    };
}

fn request(asked: &[u8]) -> Result<Request, (&'static str, String)> {
    let bad = |why: &str| ("request", format!("the request {why}"));
    if asked.len() > MAX_REQUEST {
        return Err(bad("is over 64 KiB"));
    }
    if asked.split(|&b| b == 0).next() != Some(MAGIC) {
        return Err((
            "version",
            "the command-line tool does not match this version of Wherever".to_owned(),
        ));
    }
    let Some(body) = asked.strip_suffix(b"\0") else {
        return Err(bad("is cut short"));
    };
    let fields: Vec<&[u8]> = body.split(|&b| b == 0).collect();
    let [_, query, sort, reverse, limit, marks] = fields[..] else {
        return Err(bad("has the wrong number of fields"));
    };
    let flag = |f: &[u8]| match f {
        b"0" => Some(false),
        b"1" => Some(true),
        _ => None,
    };
    let query = String::from_utf8(query.to_vec()).map_err(|_| bad("is not UTF-8"))?;
    let (column, ascending) = match sort {
        b"best" => (BEST_MATCH.column, BEST_MATCH.ascending),
        b"name" => (EngineColumn::Name, true),
        b"folder" => (EngineColumn::Folder, true),
        b"size" => (EngineColumn::Size, false),
        b"modified" => (EngineColumn::Modified, false),
        b"created" => (EngineColumn::Created, false),
        b"opened" => (EngineColumn::Opened, false),
        b"kind" => (EngineColumn::Kind, true),
        _ => return Err(bad("names an unknown sort")),
    };
    let reverse = flag(reverse).ok_or_else(|| bad("has a bad reverse flag"))?;
    let marks = flag(marks).ok_or_else(|| bad("has a bad marks flag"))?;
    let limit = (std::str::from_utf8(limit).ok())
        .filter(|l| !l.is_empty() && l.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|l| l.parse().ok())
        .ok_or_else(|| bad("has a bad limit"))?;
    Ok(Request {
        query,
        sort: EngineSort {
            column,
            ascending: ascending != reverse,
            folders_first: false,
        },
        limit,
        marks,
    })
}

fn indexed(shared: &Shared) -> Result<String, String> {
    let mut warnings = Vec::new();
    for u in shared.units().iter() {
        let (phase, count) = u.status();
        let busy = matches!(
            phase,
            EnginePhase::Loading | EnginePhase::Crawling | EnginePhase::Finishing
        );
        match (&u.id, busy) {
            (None, true) if u.read(|_| ()).is_none() => {
                return Err(format!(
                    "Wherever is still indexing this Mac, {count} items so far. Try again in a moment."
                ));
            }
            (None, true) => warnings.push(
                "Wherever is updating the startup disk index, so results may still change"
                    .to_owned(),
            ),
            (None, false) if phase == EnginePhase::Failed => warnings
                .push("the startup disk could not be indexed, so its files are missing".to_owned()),
            (Some(_), true) => warnings.push(format!(
                "{} is still being indexed, so some of its files may be missing",
                u.root.display()
            )),
            _ => {}
        }
    }
    Ok(warnings.join("; "))
}

fn respond(shared: &Shared, stream: &UnixStream, asked: &Request) -> io::Result<()> {
    let mut out = stream;
    let mut warning = match indexed(shared) {
        Ok(warning) => warning,
        Err(message) => return out.write_all(&failure("indexing", &message)),
    };
    let q = parse(shared, &asked.query);
    let units = shared.units().to_vec();
    let roots: Vec<PathBuf> = units.iter().map(|u| u.root.clone()).collect();
    let skip = shared.settings.exclusions().joined(&units);
    if let Some(folder) = query::unindexed(&q, &skip, &roots, &mut crawl::is_mount) {
        if !warning.is_empty() {
            warning.push_str("; ");
        }
        warning.push_str(&format!(
            "{} is not indexed or is in Excluded Paths, so nothing under it was searched; switch it on in Settings > Locations.",
            folder.display()
        ));
    }
    let generation = shared.generation.fetch_add(1, Ordering::Relaxed) + 1;
    let cancelled = || shared.stopped();
    let scanned = panic::catch_unwind(AssertUnwindSafe(|| {
        scan(shared, generation, &asked.query, asked.sort, &cancelled)
    }));
    let set = match scanned {
        Ok(Some(set)) => set,
        Ok(None) => return out.write_all(&failure("failed", "Wherever is quitting")),
        Err(panic) => {
            shared.fault(format!("a command-line search failed: {}", said(&*panic)));
            return out.write_all(&failure("failed", "the search failed"));
        }
    };
    let total = set.ranked.len();
    let shown = match asked.limit {
        0 => total,
        limit => limit.min(total),
    };
    let mut page = Vec::new();
    write!(page, "WHV1\0ok\0{total}\0{warning}\0")?;
    for start in (0..shown).step_by(PAGE_ROWS) {
        for hit in set.hits(start, PAGE_ROWS.min(shown - start), asked.marks) {
            row(&mut page, &hit)?;
        }
        out.write_all(&page)?;
        page.clear();
    }
    page.push(0);
    out.write_all(&page)
}

fn row(page: &mut Vec<u8>, h: &EngineHit) -> io::Result<()> {
    let kind = match h.kind {
        EngineKind::File => 'f',
        EngineKind::Folder => 'd',
        EngineKind::Link => 'l',
    };
    let marks: Vec<String> = (h.matches.iter())
        .map(|m| format!("{}:{}", m.start, m.length))
        .collect();
    write!(
        page,
        "{}\0{}\0{kind}\0{}\0{}\0{}\0{}\0{}\0",
        h.folder,
        h.name,
        h.size,
        h.modified,
        h.created,
        h.opened,
        marks.join(",")
    )
}

fn failure(code: &str, message: &str) -> Vec<u8> {
    format!("WHV1\0error\0{code}\0{message}\0\0").into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EngineError;
    use crate::crawl::tests::TempTree;
    use crate::engine::Engine;
    use crate::engine::tests::{Event, config, next, phases, ready, shared, start, start_with};
    use std::net::Shutdown;
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    use std::path::Path;
    use std::sync::mpsc::{self, Receiver};
    use std::time::Instant;

    fn socket(tree: &TempTree) -> PathBuf {
        tree.data().join(SOCKET)
    }

    fn request(fields: &[&str]) -> Vec<u8> {
        let mut asked = fields.join("\0").into_bytes();
        asked.push(0);
        asked
    }

    fn asking(query: &str, sort: &str, reverse: bool, limit: usize) -> Vec<u8> {
        let reverse = if reverse { "1" } else { "0" };
        request(&["WHV1", query, sort, reverse, &limit.to_string(), "1"])
    }

    fn send(path: &Path, asked: &[u8]) -> UnixStream {
        let stream = UnixStream::connect(path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        let _ = (&stream).write_all(asked);
        let _ = stream.shutdown(Shutdown::Write);
        stream
    }

    fn ask(path: &Path, asked: &[u8]) -> Vec<String> {
        let mut got = Vec::new();
        send(path, asked).read_to_end(&mut got).unwrap();
        (got.split(|&b| b == 0))
            .map(|f| String::from_utf8(f.to_vec()).unwrap())
            .collect()
    }

    fn rows(answer: &[String]) -> Vec<&[String]> {
        assert_eq!(answer[..2], ["WHV1", "ok"], "{answer:?}");
        let n = answer.len();
        assert_eq!(answer[n - 2..], ["", ""], "{answer:?}");
        assert_eq!((n - 6) % 8, 0, "{answer:?}");
        answer[4..n - 2].chunks(8).collect()
    }

    fn paths(answer: &[String]) -> Vec<PathBuf> {
        (rows(answer).iter())
            .map(|r| Path::new(&r[0]).join(&r[1]))
            .collect()
    }

    fn error(answer: &[String]) -> &str {
        assert_eq!(answer[..2], ["WHV1", "error"], "{answer:?}");
        assert_eq!(answer[4..], ["", ""], "{answer:?}");
        &answer[2]
    }

    fn txt(tree: &TempTree) -> usize {
        rows(&ask(&socket(tree), &asking("txt", "best", false, 0))).len()
    }

    fn serving(tree: &TempTree) -> (Arc<Engine>, Receiver<Event>) {
        let (engine, _listener, rx) = start(tree);
        phases(&rx);
        engine.serve_command_line(true).unwrap();
        (engine, rx)
    }

    fn port(engine: &Engine) -> Arc<Port> {
        let server = engine.command_line.lock().unwrap();
        server.as_ref().unwrap().port.clone()
    }

    fn open_within(port: &Port, want: usize, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        while port.open.load(Ordering::SeqCst) != want {
            if Instant::now() > deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(10));
        }
        true
    }

    fn session_paths(
        engine: &Arc<Engine>,
        rx: &Receiver<Event>,
        query: &str,
        sort: EngineSort,
    ) -> Vec<PathBuf> {
        let session = engine.clone().session().unwrap();
        let g = session.search(query.to_owned(), sort).unwrap();
        let n = ready(rx, g);
        (session.rows(g, 0, n).unwrap().into_iter())
            .map(|h| Path::new(&h.folder).join(h.name))
            .collect()
    }

    #[test]
    fn the_socket_uses_the_darwin_cache_folder() {
        let mut cache = [0u8; libc::PATH_MAX as usize];
        let len = unsafe {
            libc::confstr(
                libc::_CS_DARWIN_USER_CACHE_DIR,
                cache.as_mut_ptr().cast(),
                cache.len(),
            )
        };
        assert!(len > 1 && len <= cache.len());
        let cache = Path::new(OsStr::from_bytes(&cache[..len - 1]));
        let path = socket_folder().unwrap().join(SOCKET);
        assert_eq!(path, cache.join("com.writronic.wherever/wherever.sock"));
        assert!(path.is_absolute());
        assert!(path.as_os_str().len() < SUN_PATH);
    }

    #[test]
    fn a_long_home_keeps_the_socket_short_and_the_old_file_untouched() {
        let tree = TempTree::new("cli-long-home");
        let home = tree.0.join("u".repeat(200 - tree.0.as_os_str().len() - 1));
        assert_eq!(home.as_os_str().len(), 200);
        let data = home.join("Library/Application Support/com.writronic.wherever");
        fs::create_dir_all(&data).unwrap();
        let old = data.join(SOCKET);
        fs::write(&old, b"leftover").unwrap();
        let mut config = config(&tree);
        config.home = home.to_str().unwrap().to_owned();
        config.data_folder = data.to_str().unwrap().to_owned();
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        let path = socket(&tree);
        assert!(path.as_os_str().len() < SUN_PATH);
        engine.serve_command_line(true).unwrap();
        assert_eq!(txt(&tree), 3);
        assert_eq!(
            fs::metadata(tree.data()).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        engine.serve_command_line(false).unwrap();
        assert!(fs::symlink_metadata(&path).is_err());
        assert_eq!(fs::read(old).unwrap(), b"leftover");
    }

    #[test]
    fn the_socket_exists_only_while_serving() {
        let tree = TempTree::new("cli-on-off");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let path = socket(&tree);
        fs::set_permissions(tree.data(), Permissions::from_mode(0o755)).unwrap();
        assert!(fs::symlink_metadata(&path).is_err());
        engine.serve_command_line(true).unwrap();
        let made = fs::symlink_metadata(&path).unwrap();
        assert!(made.file_type().is_socket());
        assert_eq!(made.permissions().mode() & 0o777, 0o600);
        assert_eq!(
            fs::metadata(tree.data()).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let first = port(&engine);
        engine.serve_command_line(true).unwrap();
        assert!(Arc::ptr_eq(&first, &port(&engine)));
        assert_eq!(fs::symlink_metadata(&path).unwrap().ino(), made.ino());
        assert_eq!(txt(&tree), 3);
        engine.serve_command_line(false).unwrap();
        assert!(fs::symlink_metadata(&path).is_err());
        assert!(UnixStream::connect(&path).is_err());
        engine.serve_command_line(false).unwrap();
    }

    #[test]
    fn rows_equal_a_sessions_and_skip_excluded_paths() {
        let tree = TempTree::new("cli-rows");
        fs::create_dir_all(tree.0.join("Out")).unwrap();
        fs::write(tree.0.join("Out/kept-out.txt"), b"").unwrap();
        let mut config = config(&tree);
        config.excluded = vec![format!("{}/Out", tree.real())];
        let (engine, _listener, rx) = start_with(config, None);
        phases(&rx);
        engine.serve_command_line(true).unwrap();
        let excluded = Path::new(&tree.real()).join("Out/kept-out.txt");
        let by_name = |ascending| EngineSort {
            column: EngineColumn::Name,
            ascending,
            folders_first: false,
        };
        for (key, reverse, sort) in [
            ("best", false, BEST_MATCH),
            ("name", false, by_name(true)),
            ("name", true, by_name(false)),
        ] {
            let served = paths(&ask(&socket(&tree), &asking("txt", key, reverse, 0)));
            assert_eq!(served, session_paths(&engine, &rx, "txt", sort), "{key}");
            assert_eq!(served.len(), 3, "{served:?}");
            assert!(!served.contains(&excluded), "{served:?}");
        }
    }

    #[test]
    fn the_typo_switch_reaches_the_command_line() {
        let tree = TempTree::new("cli-typos");
        fs::write(tree.0.join("explorer.txt"), b"").unwrap();
        let (engine, _rx) = serving(&tree);
        let found = || {
            let answer = ask(&socket(&tree), &asking("epxlorer", "best", false, 0));
            (rows(&answer).iter())
                .map(|r| (r[1].clone(), r[7].is_empty()))
                .collect::<Vec<_>>()
        };
        assert!(found().is_empty());
        engine.set_typos(true).unwrap();
        assert_eq!(found(), [("explorer.txt".to_owned(), false)]);
    }

    #[test]
    fn a_limit_cuts_the_rows_and_keeps_the_total() {
        let tree = TempTree::new("cli-limit");
        let (_engine, _rx) = serving(&tree);
        let answer = ask(&socket(&tree), &asking("txt", "name", false, 2));
        assert_eq!(answer[2], "3");
        assert_eq!(rows(&answer).len(), 2);
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn a_held_boot_crawl_answers_indexing() {
        let tree = TempTree::new("cli-indexing");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        engine.serve_command_line(true).unwrap();
        let answer = ask(&socket(&tree), &asking("txt", "best", false, 0));
        release.send(None).unwrap();
        assert_eq!(error(&answer), "indexing");
        phases(&rx);
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn a_held_rebuild_answers_from_the_installed_index_with_a_warning() {
        let tree = TempTree::new("cli-rebuild");
        fs::create_dir(tree.0.join("Kept")).unwrap();
        let (engine, rx) = serving(&tree);
        let (reached, at) = mpsc::channel();
        let (release, held) = mpsc::channel();
        let held = std::sync::Mutex::new(held);
        let waited = AtomicBool::new(false);
        *shared(&engine).opened.lock().unwrap() = Some(Arc::new(move |_| {
            if waited.swap(true, Ordering::Relaxed) {
                return;
            }
            let _ = reached.send(());
            let _ = held.lock().unwrap().recv_timeout(Duration::from_secs(10));
        }));
        engine
            .set_excluded(vec![format!("{}/Sub", tree.real())])
            .unwrap();
        at.recv_timeout(Duration::from_secs(10)).unwrap();
        let answer = ask(&socket(&tree), &asking("txt", "best", false, 0));
        let expected = session_paths(&engine, &rx, "txt", BEST_MATCH);
        release.send(()).unwrap();
        assert!(!expected.is_empty());
        assert_eq!(paths(&answer), expected);
        assert_eq!(
            answer[3],
            "Wherever is updating the startup disk index, so results may still change"
        );
    }

    #[test]
    fn an_excluded_scope_explains_that_nothing_was_searched() {
        let tree = TempTree::new("cli-scope");
        let folder = format!("{}/Sub", tree.real());
        let mut settings = config(&tree);
        settings.excluded = vec![folder.clone()];
        let (engine, _listener, rx) = start_with(settings, None);
        phases(&rx);
        engine.serve_command_line(true).unwrap();
        let answer = ask(
            &socket(&tree),
            &asking(&format!("txt in:\"{folder}\""), "best", false, 0),
        );
        assert!(rows(&answer).is_empty());
        assert_eq!(
            answer[3],
            format!(
                "{folder} is not indexed or is in Excluded Paths, so nothing under it was searched; switch it on in Settings > Locations."
            )
        );
        let answer = ask(&socket(&tree), &asking("txt", "best", false, 0));
        assert!(!rows(&answer).is_empty());
        assert!(answer[3].is_empty());
    }

    #[test]
    fn a_bad_request_answers_an_error_and_scans_nothing() {
        let tree = TempTree::new("cli-errors");
        let (engine, _rx) = serving(&tree);
        let path = socket(&tree);
        let scans = || shared(&engine).scans.load(Ordering::Relaxed);
        let before = scans();
        let wrong = request(&["WHV2", "txt", "best", "0", "0", "0"]);
        assert_eq!(error(&ask(&path, &wrong)), "version");
        let long = asking(&"a".repeat(MAX_REQUEST), "best", false, 0);
        assert_eq!(error(&ask(&path, &long)), "request");
        let mut cut = asking("txt", "best", false, 0);
        cut.pop();
        assert_eq!(error(&ask(&path, &cut)), "request");
        assert_eq!(
            error(&ask(&path, &asking("txt", "size?", false, 0))),
            "request"
        );
        assert_eq!(scans(), before);
        shared(&engine).fail_scan.store(true, Ordering::Relaxed);
        assert_eq!(
            error(&ask(&path, &asking("txt", "best", false, 0))),
            "failed"
        );
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn every_accepted_stream_ignores_sigpipe() {
        let tree = TempTree::new("cli-nosigpipe");
        let (engine, _rx) = serving(&tree);
        assert_eq!(txt(&tree), 3);
        assert_eq!(*port(&engine).nosigpipe.lock().unwrap(), [1]);
    }

    #[test]
    fn a_client_that_hangs_up_or_stalls_frees_its_slot() {
        let tree = TempTree::new("cli-hangups");
        for i in 0..5000 {
            fs::write(tree.0.join(format!("many-{i:04}.log")), b"").unwrap();
        }
        let (engine, _rx) = serving(&tree);
        let (path, open) = (socket(&tree), port(&engine));
        let everything = asking("many", "name", false, 0);
        let mut quitter = send(&path, &everything);
        let mut head = [0; 8];
        quitter.read_exact(&mut head).unwrap();
        assert_eq!(&head, b"WHV1\0ok\0");
        drop(quitter);
        assert!(open_within(&open, 0, Duration::from_secs(5)));
        assert_eq!(txt(&tree), 3);
        let silent = UnixStream::connect(&path).unwrap();
        silent
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        let stalled = send(&path, &everything);
        let began = Instant::now();
        let mut got = Vec::new();
        (&silent).read_to_end(&mut got).unwrap();
        let cut = began.elapsed();
        assert!(got.is_empty(), "{got:?}");
        assert!(cut >= Duration::from_millis(4500), "{cut:?}");
        assert!(cut < Duration::from_secs(9), "{cut:?}");
        assert!(open_within(&open, 0, Duration::from_secs(30)));
        let stall = began.elapsed();
        assert!(stall >= Duration::from_secs(9), "{stall:?}");
        drop(stalled);
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn a_live_socket_is_kept_and_a_dead_one_replaced() {
        let tree = TempTree::new("cli-two");
        let (first, _rx) = serving(&tree);
        let path = socket(&tree);
        let (second, _listener, rx) = start(&tree);
        while !matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Ready) {}
        let refused = second.serve_command_line(true);
        assert!(
            matches!(refused, Err(EngineError::Io { .. })),
            "{refused:?}"
        );
        assert!(
            rx.try_iter()
                .any(|e| matches!(&e, Event::Fault(m) if m.contains("another copy")))
        );
        assert_eq!(txt(&tree), 3);
        drop(first);
        assert!(fs::symlink_metadata(&path).is_err());
        drop(UnixListener::bind(&path).unwrap());
        assert!(UnixStream::connect(&path).is_err());
        second.serve_command_line(true).unwrap();
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn dropping_the_engine_removes_the_socket_with_a_client_still_connected() {
        let tree = TempTree::new("cli-drop");
        let (engine, _rx) = serving(&tree);
        let (path, open) = (socket(&tree), port(&engine));
        let held = UnixStream::connect(&path).unwrap();
        assert!(open_within(&open, 1, Duration::from_secs(5)));
        let (done, dropped) = mpsc::channel();
        thread::spawn(move || {
            drop(engine);
            let _ = done.send(());
        });
        dropped.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(Arc::strong_count(&open), 2);
        assert!(fs::symlink_metadata(&path).is_err());
        assert!(UnixStream::connect(&path).is_err());
        drop(held);
        assert!(open_within(&open, 0, Duration::from_secs(5)));
    }

    #[test]
    fn stopping_frees_the_listening_thread_when_the_socket_file_is_gone() {
        let tree = TempTree::new("cli-gone");
        let (engine, _rx) = serving(&tree);
        let (path, open) = (socket(&tree), port(&engine));
        assert_eq!(Arc::strong_count(&open), 3);
        fs::remove_file(&path).unwrap();
        engine.serve_command_line(false).unwrap();
        assert_eq!(
            Arc::strong_count(&open),
            1,
            "the listening thread outlived the stop"
        );
        engine.serve_command_line(true).unwrap();
        assert_eq!(txt(&tree), 3);
        let again = port(&engine);
        engine.serve_command_line(false).unwrap();
        assert_eq!(Arc::strong_count(&again), 1);
        assert!(fs::symlink_metadata(&path).is_err());
    }

    #[test]
    fn a_ninth_connection_at_once_is_busy() {
        let tree = TempTree::new("cli-busy");
        let (engine, _rx) = serving(&tree);
        let (path, open) = (socket(&tree), port(&engine));
        let held: Vec<UnixStream> = (0..MAX_CONNECTIONS)
            .map(|_| UnixStream::connect(&path).unwrap())
            .collect();
        assert!(open_within(&open, MAX_CONNECTIONS, Duration::from_secs(5)));
        assert_eq!(error(&ask(&path, &asking("txt", "best", false, 0))), "busy");
        drop(held);
        assert!(open_within(&open, 0, Duration::from_secs(5)));
        assert_eq!(txt(&tree), 3);
    }

    #[test]
    fn another_user_is_refused() {
        let (a, _b) = UnixStream::pair().unwrap();
        let me = unsafe { libc::geteuid() };
        assert!(same_user(&a, me));
        assert!(!same_user(&a, me.wrapping_add(1)));
    }
}
