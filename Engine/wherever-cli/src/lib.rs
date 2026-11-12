use std::ffi::{CStr, OsStr, OsString};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;
use std::{env, fs};

mod launch;

pub use launch::{COMMAND_DONE, Host, System};

const MAGIC: &str = "WHV1";
const TERMINAL_ROWS: usize = 100;
const SUN_PATH: usize = 104;
const INDEXING: &str = "Wherever is still indexing this Mac";
const STEP: Duration = Duration::from_millis(100);
const CONNECT_STEPS: u32 = 100;
const INDEXING_STEPS: u32 = 150;
const SORTS: [&str; 8] = [
    "best", "name", "folder", "size", "modified", "created", "opened", "kind",
];
pub const UNREACHABLE: &str = "cannot reach Wherever. Open Wherever, and install the command-line tool in Settings > General if it is off.";
const USAGE: &str = "usage: wherever [options] <query...>

Finds files and folders by name through the running Wherever app.
The query uses Wherever's search syntax, for example: wherever ext:pdf report

options:
  -n, --limit N    show at most N rows; 0 shows all (default: 100 on a terminal, all when piped)
  -s, --sort KEY   best (default), name, folder, size, modified, created, opened or kind
  -r, --reverse    reverse the order
      --in DIR     only under the folder DIR
  -0, --null       end each path with a NUL byte instead of a new line
  -j, --json       print one JSON object per line
  -h, --help       show this help
  -V, --version    show the version

exit status: 0 when something matches, 1 when nothing matches, 2 on an error
";

pub struct Env {
    pub uid: u32,
    pub no_color: Option<OsString>,
    pub term: Option<OsString>,
    pub host: Box<dyn Host>,
}

impl Env {
    pub fn current() -> Env {
        Env {
            uid: unsafe { libc::getuid() },
            no_color: env::var_os("NO_COLOR"),
            term: env::var_os("TERM"),
            host: Box::new(System),
        }
    }

    fn color(&self) -> bool {
        self.no_color.as_ref().is_none_or(|v| v.is_empty())
            && self.term.as_deref() != Some(OsStr::new("dumb"))
    }
}

fn home() -> Option<PathBuf> {
    let user = unsafe { libc::getpwuid(libc::getuid()) };
    if user.is_null() || unsafe { (*user).pw_dir }.is_null() {
        return None;
    }
    let home = unsafe { CStr::from_ptr((*user).pw_dir) };
    let home = Path::new(OsStr::from_bytes(home.to_bytes()));
    Some(home.to_path_buf())
}

pub fn socket() -> Option<PathBuf> {
    let mut cache = [0u8; libc::PATH_MAX as usize];
    let len = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_CACHE_DIR,
            cache.as_mut_ptr().cast(),
            cache.len(),
        )
    };
    if len <= 1 || len > cache.len() {
        return None;
    }
    Some(
        Path::new(OsStr::from_bytes(&cache[..len - 1]))
            .join("com.writronic.wherever/wherever.sock"),
    )
}

#[derive(Clone, Copy, PartialEq)]
enum Format {
    Lines,
    Null,
    Json,
}

struct Options {
    limit: Option<usize>,
    sort: String,
    reverse: bool,
    folder: Option<String>,
    format: Format,
    words: Vec<String>,
}

enum Parsed {
    Run(Options),
    Help,
    Version,
}

fn parse(args: &[String]) -> Result<Parsed, String> {
    let mut o = Options {
        limit: None,
        sort: "best".to_owned(),
        reverse: false,
        folder: None,
        format: Format::Lines,
        words: Vec::new(),
    };
    let mut rest = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if rest {
            o.words.push(arg.clone());
            continue;
        }
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value)),
            _ => (arg.as_str(), None),
        };
        let mut value = || {
            (inline.map(str::to_owned).or_else(|| it.next().cloned()))
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        let switch = |on: &mut bool| match inline {
            Some(_) => Err(format!("{flag} takes no value")),
            None => {
                *on = true;
                Ok(())
            }
        };
        match flag {
            "--" if inline.is_none() => rest = true,
            "-h" | "--help" => return Ok(Parsed::Help),
            "-V" | "--version" => return Ok(Parsed::Version),
            "-n" | "--limit" => {
                let v = value()?;
                o.limit = Some(
                    (v.bytes().all(|b| b.is_ascii_digit()))
                        .then(|| v.parse().ok())
                        .flatten()
                        .ok_or_else(|| format!("{flag} takes a whole number, not {v:?}"))?,
                );
            }
            "-s" | "--sort" => {
                let v = value()?;
                if !SORTS.contains(&v.as_str()) {
                    return Err(format!(
                        "{flag} takes one of {}, not {v:?}",
                        SORTS.join(", ")
                    ));
                }
                o.sort = v;
            }
            "-r" | "--reverse" => switch(&mut o.reverse)?,
            "--in" => o.folder = Some(value()?),
            "-0" | "--null" | "-j" | "--json" => {
                let mut on = false;
                switch(&mut on)?;
                let format = if matches!(flag, "-0" | "--null") {
                    Format::Null
                } else {
                    Format::Json
                };
                if o.format != Format::Lines && o.format != format {
                    return Err("--null and --json cannot be used together".to_owned());
                }
                o.format = format;
            }
            _ if flag.len() > 1 && flag.starts_with('-') => {
                return Err(format!("unknown option {arg}"));
            }
            _ => o.words.push(arg.clone()),
        }
    }
    o.words.retain(|w| !w.is_empty());
    if o.words.is_empty() {
        return Err("give a name to look for, for example: wherever report.pdf".to_owned());
    }
    Ok(Parsed::Run(o))
}

fn quoted(text: &str) -> String {
    format!("\"{}\"", text.replace('"', "\"\""))
}

fn word(text: &str) -> String {
    let quotes = text.bytes().filter(|&b| b == b'"').count();
    if quotes > 0 && quotes % 2 == 0 {
        text.to_owned()
    } else if text.contains(|c: char| c.is_whitespace() || c == '"') {
        quoted(text)
    } else {
        text.to_owned()
    }
}

fn query(o: &Options, err: &mut dyn Write) -> Result<String, String> {
    let mut words: Vec<String> = o.words.iter().map(|w| word(w)).collect();
    if let Some(dir) = &o.folder {
        let path = if dir == "~" || dir.starts_with("~/") {
            home()
                .ok_or_else(|| "cannot find your home folder".to_owned())?
                .join(dir.strip_prefix("~/").unwrap_or("").trim_start_matches('/'))
        } else {
            PathBuf::from(dir)
        };
        let dir = fs::canonicalize(&path)
            .or_else(|e| {
                if e.kind() == io::ErrorKind::NotFound {
                    let _ = writeln!(err, "wherever: there is no folder {}.", path.display());
                }
                env::current_dir().map(|cwd| cwd.join(&path))
            })
            .map_err(|e| format!("cannot find the folder {dir}: {e}"))?;
        let dir = dir
            .to_str()
            .ok_or_else(|| format!("the folder {} is not UTF-8", dir.display()))?;
        words.push(format!("in:{}", quoted(dir)));
    }
    Ok(words.join(" "))
}

struct Row {
    folder: String,
    name: String,
    kind: &'static str,
    size: u64,
    modified: i64,
    created: i64,
    opened: i64,
    marks: Vec<(u32, u32)>,
}

enum Answer {
    Found {
        total: usize,
        warning: String,
        rows: Vec<Row>,
    },
    Refused(String),
}

fn cut() -> String {
    "the answer from Wherever was cut short. Try again.".to_owned()
}

fn unreadable() -> String {
    "Wherever sent an answer this tool cannot read. Update Wherever and try again.".to_owned()
}

fn number<T: std::str::FromStr>(field: &str) -> Result<T, String> {
    field.parse().map_err(|_| unreadable())
}

fn answer(got: &[u8], limit: usize) -> Result<Answer, String> {
    let body = got.strip_suffix(b"\0").ok_or_else(cut)?;
    let fields = (body.split(|&b| b == 0))
        .map(|f| String::from_utf8(f.to_vec()).map_err(|_| unreadable()))
        .collect::<Result<Vec<_>, _>>()?;
    if fields[0] != MAGIC {
        return Err(unreadable());
    }
    let n = fields.len();
    match fields.get(1).map(String::as_str) {
        Some("error") => match fields.get(2..) {
            Some([_, message, end]) if end.is_empty() => Ok(Answer::Refused(message.clone())),
            _ => Err(cut()),
        },
        Some("ok") if n >= 5 && (n - 5) % 8 == 0 && fields[n - 1].is_empty() => {
            let total: usize = number(&fields[2])?;
            let rows = (fields[4..n - 1].chunks(8))
                .map(row)
                .collect::<Result<Vec<_>, _>>()?;
            let shown = if limit == 0 { total } else { limit.min(total) };
            if rows.len() != shown {
                return Err(cut());
            }
            Ok(Answer::Found {
                total,
                warning: fields[3].clone(),
                rows,
            })
        }
        Some("ok") => Err(cut()),
        _ => Err(unreadable()),
    }
}

fn row(f: &[String]) -> Result<Row, String> {
    let kind = match f[2].as_str() {
        "f" => "file",
        "d" => "folder",
        "l" => "link",
        _ => return Err(unreadable()),
    };
    let marks = (f[7].split(',').filter(|m| !m.is_empty()))
        .map(|m| {
            let (start, length) = m.split_once(':').ok_or_else(unreadable)?;
            Ok((number(start)?, number(length)?))
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(Row {
        folder: f[0].clone(),
        name: f[1].clone(),
        kind,
        size: number(&f[3])?,
        modified: number(&f[4])?,
        created: number(&f[5])?,
        opened: number(&f[6])?,
        marks,
    })
}

fn printable(c: char) -> char {
    if c.is_control() { '?' } else { c }
}

fn bold(text: &mut String, name: &str, marks: &[(u32, u32)]) {
    let (mut unit, mut on) = (0u32, false);
    for c in name.chars() {
        let hit = (marks.iter())
            .any(|&(start, length)| unit >= start && unit < start.saturating_add(length));
        if hit != on {
            text.push_str(if hit { "\x1b[1m" } else { "\x1b[22m" });
            on = hit;
        }
        text.push(printable(c));
        unit += c.len_utf16() as u32;
    }
    if on {
        text.push_str("\x1b[22m");
    }
}

fn string(s: &str) -> String {
    let mut out = String::from('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn line(text: &mut String, r: &Row, format: Format, terminal: bool, marks: &[(u32, u32)]) {
    let path = Path::new(&r.folder).join(&r.name);
    let path = path.to_string_lossy();
    match format {
        Format::Null => {
            text.push_str(&path);
            text.push('\0');
        }
        Format::Json => {
            text.push_str(&format!(
                "{{\"path\":{},\"name\":{},\"folder\":{},\"kind\":\"{}\",\"size\":{},\"modified\":{},\"created\":{},\"opened\":{}}}\n",
                string(&path),
                string(&r.name),
                string(&r.folder),
                r.kind,
                r.size,
                r.modified,
                r.created,
                r.opened
            ));
        }
        Format::Lines if terminal => {
            let folder = path.strip_suffix(r.name.as_str()).unwrap_or(&path);
            text.extend(folder.chars().map(printable));
            if folder.len() < path.len() {
                bold(text, &r.name, marks);
            }
            text.push('\n');
        }
        Format::Lines => {
            text.push_str(&path);
            text.push('\n');
        }
    }
}

fn exchange(socket: &Path, asked: &[u8]) -> Result<Vec<u8>, String> {
    if socket.as_os_str().len() >= SUN_PATH {
        return Err(format!(
            "cannot reach Wherever, because its socket path {} is longer than the {} bytes macOS allows. Report this path to Wherever's developers.",
            socket.display(),
            SUN_PATH - 1
        ));
    }
    let mut stream = UnixStream::connect(socket).map_err(|_| UNREACHABLE.to_owned())?;
    let _ = stream.write_all(asked);
    let _ = stream.shutdown(Shutdown::Write);
    let mut got = Vec::new();
    let _ = stream.read_to_end(&mut got);
    Ok(got)
}

fn ask(socket: &Path, asked: &[u8], limit: usize, host: &dyn Host) -> Result<Answer, String> {
    let app = host.app();
    for steps in 0.. {
        match exchange(socket, asked) {
            Err(e) if e == UNREACHABLE => {
                let Some(app) = &app else { return Err(e) };
                if steps == 0 && !host.running(app) {
                    host.open(app).map_err(|_| e.clone())?;
                }
                if steps >= CONNECT_STEPS {
                    return Err(e);
                }
            }
            got => {
                let answer = answer(&got?, limit)?;
                let Some(app) = &app else { return Ok(answer) };
                let indexing = matches!(&answer, Answer::Refused(m) if m.starts_with(INDEXING));
                if !indexing || steps >= INDEXING_STEPS {
                    host.done(app);
                    return Ok(answer);
                }
            }
        }
        host.wait(STEP);
    }
    unreachable!()
}

fn emit(out: &mut dyn Write, text: &[u8]) -> Result<(), String> {
    match out.write_all(text).and_then(|()| out.flush()) {
        Err(e) if e.kind() != io::ErrorKind::BrokenPipe => {
            Err(format!("cannot write the results: {e}"))
        }
        _ => Ok(()),
    }
}

fn search(
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
    socket: &Path,
    terminal: bool,
    env: &Env,
) -> Result<i32, String> {
    let o =
        match parse(args).map_err(|e| format!("{e}. Run wherever --help to see the options."))? {
            Parsed::Help => return emit(out, USAGE.as_bytes()).map(|()| 0),
            Parsed::Version => {
                let version = format!("wherever {}\n", env!("CARGO_PKG_VERSION"));
                return emit(out, version.as_bytes()).map(|()| 0);
            }
            Parsed::Run(o) => o,
        };
    if env.uid == 0 {
        return Err("run wherever as yourself, not as root.".to_owned());
    }
    let limit = o.limit.unwrap_or(if terminal { TERMINAL_ROWS } else { 0 });
    let marks = terminal && o.format == Format::Lines && env.color();
    let flag = |on: bool| if on { '1' } else { '0' };
    let asked = format!(
        "{MAGIC}\0{}\0{}\0{}\0{limit}\0{}\0",
        query(&o, err)?,
        o.sort,
        flag(o.reverse),
        flag(marks)
    );
    let (total, warning, rows) = match ask(socket, asked.as_bytes(), limit, &*env.host)? {
        Answer::Found {
            total,
            warning,
            rows,
        } => (total, warning, rows),
        Answer::Refused(message) => return Err(message),
    };
    let mut text = String::new();
    for r in &rows {
        line(
            &mut text,
            r,
            o.format,
            terminal,
            if marks { &r.marks } else { &[] },
        );
    }
    if !warning.is_empty() {
        let _ = writeln!(err, "wherever: {warning}");
    }
    emit(out, text.as_bytes())?;
    if rows.len() < total {
        let more = total - rows.len();
        let _ = writeln!(err, "\u{2026} and {more} more. Use --limit 0 to see all.");
    }
    Ok(if rows.is_empty() { 1 } else { 0 })
}

pub fn run(
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
    socket: &Path,
    terminal: bool,
    env: &Env,
) -> i32 {
    search(args, out, err, socket, terminal, env).unwrap_or_else(|message| {
        let _ = writeln!(err, "wherever: {message}");
        2
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::os::unix::net::UnixListener;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::thread::{self, JoinHandle};

    static NEXT: AtomicU32 = AtomicU32::new(0);

    struct Folder(PathBuf);

    impl Folder {
        fn new() -> Folder {
            let n = NEXT.fetch_add(1, Ordering::SeqCst);
            let dir = PathBuf::from(format!(
                "/private/tmp/whv-{:08x}",
                (std::process::id() << 12) | n
            ));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Folder(dir)
        }

        fn socket(&self) -> PathBuf {
            self.0.join("wherever.sock")
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct Canned {
        folder: Folder,
        thread: Option<JoinHandle<Vec<u8>>>,
    }

    impl Canned {
        fn new(answer: Vec<u8>) -> Canned {
            let folder = Folder::new();
            let listener = UnixListener::bind(folder.socket()).unwrap();
            let thread = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut asked = Vec::new();
                stream.read_to_end(&mut asked).unwrap();
                let _ = stream.write_all(&answer);
                asked
            });
            Canned {
                folder,
                thread: Some(thread),
            }
        }

        fn socket(&self) -> PathBuf {
            self.folder.socket()
        }

        fn asked(&mut self) -> Vec<String> {
            let asked = self.thread.take().unwrap().join().unwrap();
            (asked.split(|&b| b == 0))
                .map(|f| String::from_utf8(f.to_vec()).unwrap())
                .collect()
        }
    }

    fn env() -> Env {
        Env {
            uid: 501,
            no_color: None,
            term: Some("xterm-256color".into()),
            host: Box::new(System),
        }
    }

    fn call(args: &[&str], socket: &Path, terminal: bool, env: &Env) -> (i32, String, String) {
        let args: Vec<String> = args.iter().map(|&a| a.to_owned()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = run(&args, &mut out, &mut err, socket, terminal, env);
        let text = |b: Vec<u8>| String::from_utf8(b).unwrap();
        (code, text(out), text(err))
    }

    fn piped(args: &[&str], socket: &Path) -> (i32, String, String) {
        call(args, socket, false, &env())
    }

    fn found(total: usize, warning: &str, rows: &[[&str; 8]]) -> Vec<u8> {
        let mut answer = format!("WHV1\0ok\0{total}\0{warning}\0");
        for r in rows {
            for f in r {
                answer.push_str(f);
                answer.push('\0');
            }
        }
        answer.push('\0');
        answer.into_bytes()
    }

    fn refused(code: &str, message: &str) -> Vec<u8> {
        format!("WHV1\0error\0{code}\0{message}\0\0").into_bytes()
    }

    fn file<'a>(folder: &'a str, name: &'a str, marks: &'a str) -> [&'a str; 8] {
        [
            folder,
            name,
            "f",
            "12",
            "1700000000",
            "1600000000",
            "0",
            marks,
        ]
    }

    fn files(n: usize) -> Vec<[String; 8]> {
        (0..n)
            .map(|i| file("/a", &format!("f{i}.txt"), "1:1").map(str::to_owned))
            .collect()
    }

    fn found_owned(total: usize, rows: &[[String; 8]]) -> Vec<u8> {
        let rows: Vec<[&str; 8]> = rows
            .iter()
            .map(|r| r.each_ref().map(String::as_str))
            .collect();
        found(total, "", &rows)
    }

    fn missing() -> PathBuf {
        PathBuf::from("/private/tmp/whv-none/wherever.sock")
    }

    #[test]
    fn options_reach_the_request() {
        let mut canned = Canned::new(found(1, "", &[file("/a", "b.txt", "")]));
        let (code, out, err) = piped(&["--limit=5", "-s", "size", "-r", "b"], &canned.socket());
        assert_eq!((code, out.as_str(), err.as_str()), (0, "/a/b.txt\n", ""));
        assert_eq!(canned.asked(), ["WHV1", "b", "size", "1", "5", "0", ""]);
        let mut canned = Canned::new(found(1, "", &[file("/a", "b.txt", "")]));
        piped(
            &["--sort=kind", "--limit", "0", "--", "-r", "--json"],
            &canned.socket(),
        );
        assert_eq!(
            canned.asked(),
            ["WHV1", "-r --json", "kind", "0", "0", "0", ""]
        );
    }

    #[test]
    fn a_bad_option_exits_2_with_one_line() {
        for args in [
            &["--bogus", "a"][..],
            &["-x", "a"],
            &["-n", "abc", "a"],
            &["-n", "-1", "a"],
            &["--limit"],
            &["a", "-s"],
            &["--sort", "nope", "a"],
            &["--json=1", "a"],
            &["--reverse=no", "a"],
            &["-0", "-j", "a"],
            &["--=a", "a"],
            &[],
            &[""],
            &["-r"],
            &["--in", "/private/tmp"],
        ] {
            let (code, out, err) = piped(args, &missing());
            assert_eq!(code, 2, "{args:?}");
            assert!(out.is_empty(), "{args:?}");
            assert!(err.starts_with("wherever: "), "{args:?} {err}");
            assert!(
                err.ends_with("Run wherever --help to see the options.\n"),
                "{args:?} {err}"
            );
            assert_eq!(err.lines().count(), 1, "{args:?} {err}");
        }
    }

    #[test]
    fn help_and_version_print_on_stdout_and_exit_0() {
        let (code, out, err) = piped(&["a", "-h", "--bogus"], &missing());
        assert_eq!((code, err.as_str()), (0, ""));
        assert!(out.starts_with("usage: wherever"), "{out}");
        let (code, out, _) = piped(&["--version"], &missing());
        assert_eq!((code, out.as_str()), (0, "wherever 0.1.0\n"));
    }

    #[test]
    fn words_with_spaces_or_quotes_stay_one_word() {
        let mut canned = Canned::new(found(0, "", &[]));
        piped(
            &["my file", "a\"b", "in:/a b", "plain", "*.pdf"],
            &canned.socket(),
        );
        let asked = canned.asked();
        assert_eq!(asked[1], "\"my file\" \"a\"\"b\" \"in:/a b\" plain *.pdf");
    }

    #[test]
    fn balanced_query_quotes_reach_the_server_unchanged() {
        for query in [
            r#"in:"~/My Folder""#,
            r#"glob:"report ??.pdf""#,
            r#""annual report" ext:pdf"#,
        ] {
            let mut canned = Canned::new(found(0, "", &[]));
            piped(&[query], &canned.socket());
            assert_eq!(canned.asked()[1], query);
        }
    }

    #[test]
    fn in_expands_only_home_tildes() {
        let home = home().unwrap();
        for (args, path) in [
            (vec!["--in=~/x", "x"], home.join("x")),
            (vec!["--in=~//x", "x"], home.join("x")),
            (vec!["--in", "~/My Files", "x"], home.join("My Files")),
            (vec!["--in=~", "x"], home.clone()),
            (
                vec!["--in=~someone/x", "x"],
                env::current_dir().unwrap().join("~someone/x"),
            ),
        ] {
            let expected = fs::canonicalize(&path).unwrap_or(path);
            let mut canned = Canned::new(found(0, "", &[]));
            piped(&args, &canned.socket());
            assert_eq!(
                canned.asked()[1],
                format!("x in:{}", quoted(expected.to_str().unwrap()))
            );
        }
    }

    #[test]
    fn a_missing_folder_exits_one_with_a_sentence_and_still_asks() {
        let folder = Folder::new();
        let missing = folder.0.join("missing");
        let mut canned = Canned::new(found(0, "", &[]));
        let (code, out, err) = piped(&["--in", missing.to_str().unwrap(), "x"], &canned.socket());
        assert_eq!(code, 1);
        assert!(out.is_empty());
        assert_eq!(
            err,
            format!("wherever: there is no folder {}.\n", missing.display())
        );
        assert_eq!(
            canned.asked()[1],
            format!("x in:{}", quoted(missing.to_str().unwrap()))
        );
    }

    #[test]
    fn an_unindexed_folder_warning_exits_one_on_stderr() {
        let warning = "/Volumes/Backup is not indexed or is in Excluded Paths, so nothing under it was searched; switch it on in Settings > Locations.";
        let canned = Canned::new(found(0, warning, &[]));
        let (code, out, err) = piped(&["invoice", "in:/Volumes/Backup"], &canned.socket());
        assert_eq!(
            (code, out.as_str(), err),
            (1, "", format!("wherever: {warning}\n"))
        );
    }

    #[test]
    fn in_takes_a_relative_or_a_missing_folder() {
        let cwd = env::current_dir().unwrap();
        let src = fs::canonicalize("src").unwrap();
        let mut canned = Canned::new(found(0, "", &[]));
        piped(&["--in", "src", "x"], &canned.socket());
        assert_eq!(canned.asked()[1], format!("x in:\"{}\"", src.display()));
        let mut canned = Canned::new(found(0, "", &[]));
        piped(&["--in=no such \"folder", "x"], &canned.socket());
        let wanted = cwd.join("no such \"folder");
        let wanted = wanted.to_str().unwrap().replace('"', "\"\"");
        assert_eq!(canned.asked()[1], format!("x in:\"{wanted}\""));
        let mut canned = Canned::new(found(0, "", &[]));
        piped(&["--in", "/private/tmp/whv-missing", "x"], &canned.socket());
        assert_eq!(canned.asked()[1], "x in:\"/private/tmp/whv-missing\"");
    }

    #[test]
    fn marks_bold_utf16_units() {
        let mut text = String::new();
        bold(
            &mut text,
            "a\u{e9}\u{1f44d}b\u{4e2d}\u{6587}",
            &[(1, 1), (2, 2), (5, 1)],
        );
        assert_eq!(
            text,
            "a\x1b[1m\u{e9}\u{1f44d}\x1b[22mb\x1b[1m\u{4e2d}\x1b[22m\u{6587}"
        );
        let mut text = String::new();
        bold(&mut text, "\u{1f44d}x", &[(2, 1)]);
        assert_eq!(text, "\u{1f44d}\x1b[1mx\x1b[22m");
        let mut text = String::new();
        bold(&mut text, "e\u{301}", &[(0, 2)]);
        assert_eq!(text, "\x1b[1me\u{301}\x1b[22m");
    }

    #[test]
    fn a_terminal_bolds_the_name_only() {
        let row = file("/caf\u{e9}", "\u{e9}\u{1f44d}.txt", "0:1,1:2");
        let mut canned = Canned::new(found(1, "", &[row]));
        let (code, out, _) = call(&["x"], &canned.socket(), true, &env());
        assert_eq!(code, 0);
        assert_eq!(out, "/caf\u{e9}/\x1b[1m\u{e9}\u{1f44d}\x1b[22m.txt\n");
        assert_eq!(canned.asked()[5], "1");
    }

    #[test]
    fn a_terminal_prints_control_characters_as_question_marks() {
        let row = file("/a\x1b", "b\nc\x1b[31m", "");
        let canned = Canned::new(found(1, "", &[row]));
        let (_, out, _) = call(&["x"], &canned.socket(), true, &env());
        assert_eq!(out, "/a?/b?c?[31m\n");
        let canned = Canned::new(found(1, "", &[row]));
        let (_, out, _) = piped(&["x"], &canned.socket());
        assert_eq!(out, "/a\x1b/b\nc\x1b[31m\n");
    }

    #[test]
    fn no_color_and_a_dumb_terminal_skip_bold() {
        let row = file("/a", "bc", "0:1");
        for (no_color, term, bolded) in [
            (Some("1"), Some("xterm"), false),
            (Some(""), Some("xterm"), true),
            (None, Some("dumb"), false),
            (None, None, true),
        ] {
            let env = Env {
                uid: 501,
                no_color: no_color.map(Into::into),
                term: term.map(Into::into),
                host: Box::new(System),
            };
            let mut canned = Canned::new(found(1, "", &[row]));
            let (_, out, _) = call(&["x"], &canned.socket(), true, &env);
            assert_eq!(out.contains('\x1b'), bolded, "{no_color:?} {term:?}");
            assert_eq!(canned.asked()[5], if bolded { "1" } else { "0" });
        }
    }

    #[test]
    fn null_is_never_bold() {
        let rows = [file("/a", "bc", "0:1"), file("/", "d e", "0:1")];
        let mut canned = Canned::new(found(2, "", &rows));
        let (code, out, _) = call(&["-0", "x"], &canned.socket(), true, &env());
        assert_eq!((code, out.as_str()), (0, "/a/bc\0/d e\0"));
        assert_eq!(canned.asked()[5], "0");
    }

    #[test]
    fn json_escapes_quotes_backslashes_and_controls() {
        let name = "a\"b\\c\nd\u{1}e\u{e9}";
        let row = ["/x", name, "d", "4096", "-5", "7", "9", ""];
        let mut canned = Canned::new(found(1, "", &[row]));
        let (code, out, _) = call(&["--json", "x"], &canned.socket(), true, &env());
        assert_eq!(code, 0);
        let name = "a\\\"b\\\\c\\nd\\u0001e\u{e9}";
        assert_eq!(
            out,
            format!(
                "{{\"path\":\"/x/{name}\",\"name\":\"{name}\",\"folder\":\"/x\",\"kind\":\"folder\",\"size\":4096,\"modified\":-5,\"created\":7,\"opened\":9}}\n"
            )
        );
        assert_eq!(canned.asked()[5], "0");
    }

    #[test]
    fn a_terminal_shows_100_rows_and_a_note_and_a_pipe_shows_all() {
        let mut canned = Canned::new(found_owned(150, &files(100)));
        let (code, out, err) = call(&["x"], &canned.socket(), true, &env());
        assert_eq!(code, 0);
        assert_eq!(out.lines().count(), 100);
        assert_eq!(err, "\u{2026} and 50 more. Use --limit 0 to see all.\n");
        assert_eq!(canned.asked()[4], "100");
        let mut canned = Canned::new(found_owned(150, &files(150)));
        let (code, out, err) = piped(&["x"], &canned.socket());
        assert_eq!((code, out.lines().count(), err.as_str()), (0, 150, ""));
        assert_eq!(canned.asked()[4], "0");
        let mut canned = Canned::new(found_owned(3, &files(3)));
        let (_, out, err) = call(&["-n", "0", "x"], &canned.socket(), true, &env());
        assert_eq!((out.lines().count(), err.as_str()), (3, ""));
        assert_eq!(canned.asked()[4], "0");
    }

    #[test]
    fn exit_codes_follow_grep() {
        let canned = Canned::new(found(1, "", &[file("/a", "b", "")]));
        assert_eq!(piped(&["b"], &canned.socket()).0, 0);
        let canned = Canned::new(found(0, "", &[]));
        assert_eq!(
            piped(&["b"], &canned.socket()),
            (1, String::new(), String::new())
        );
        let canned = Canned::new(refused("failed", "the search failed"));
        assert_eq!(piped(&["b"], &canned.socket()).0, 2);
    }

    #[test]
    fn a_warning_goes_to_stderr() {
        let canned = Canned::new(found(
            1,
            "Disk 1 is still being indexed",
            &[file("/a", "b", "")],
        ));
        let (code, out, err) = piped(&["b"], &canned.socket());
        assert_eq!((code, out.as_str()), (0, "/a/b\n"));
        assert_eq!(err, "wherever: Disk 1 is still being indexed\n");
    }

    #[test]
    fn a_cut_stream_prints_no_row_and_exits_2() {
        let whole = found(2, "", &[file("/a", "b", ""), file("/a", "c", "")]);
        let cuts = [whole.len() - 1, whole.len() - 2, whole.len() - 3, 10, 4, 0];
        for at in cuts {
            let canned = Canned::new(whole[..at].to_vec());
            let (code, out, err) = piped(&["b"], &canned.socket());
            assert_eq!((code, out.as_str()), (2, ""), "{at}");
            assert_eq!(err, format!("wherever: {}\n", cut()), "{at}");
        }
        let short = found(3, "", &[file("/a", "b", ""), file("/a", "c", "")]);
        let canned = Canned::new(short);
        assert_eq!(
            piped(&["b"], &canned.socket()),
            (2, String::new(), format!("wherever: {}\n", cut()))
        );
        let canned = Canned::new(refused("busy", "x")[..14].to_vec());
        assert_eq!(piped(&["b"], &canned.socket()).0, 2);
    }

    #[test]
    fn an_unknown_answer_exits_2() {
        for answer in [
            &b"WHV2\0ok\x000\0\0\0"[..],
            b"WHV1\0maybe\0\0",
            b"WHV1\0ok\0many\0\0\0",
            b"WHV1\0ok\x001\0\0/a\0b\0q\x001\x001\x001\x001\0\0\0",
            b"WHV1\0ok\x001\0\0/a\0b\0f\0big\x001\x001\x001\0\0\0",
            b"WHV1\0ok\x001\0\0/a\0b\0f\x001\x001\x001\x001\x001\0\0",
        ] {
            let canned = Canned::new(answer.to_vec());
            let (code, out, err) = piped(&["b"], &canned.socket());
            assert_eq!((code, out.as_str()), (2, ""), "{answer:?}");
            assert_eq!(err, format!("wherever: {}\n", unreadable()), "{answer:?}");
        }
    }

    #[test]
    fn a_dead_or_missing_socket_cannot_be_reached() {
        let folder = Folder::new();
        drop(UnixListener::bind(folder.socket()).unwrap());
        assert!(fs::symlink_metadata(folder.socket()).is_ok());
        let unreachable = (2, String::new(), format!("wherever: {UNREACHABLE}\n"));
        assert_eq!(piped(&["b"], &folder.socket()), unreachable);
        assert_eq!(piped(&["b"], &missing()), unreachable);
    }

    #[test]
    fn each_error_code_prints_its_message() {
        for (code, message) in [
            (
                "version",
                "the command-line tool does not match this version of Wherever",
            ),
            ("request", "the request is over 64 KiB"),
            (
                "indexing",
                "Wherever is still indexing this Mac, 12 items so far. Try again in a moment.",
            ),
            ("busy", "Wherever is answering 8 other requests. Try again."),
            ("failed", "the search failed"),
        ] {
            let canned = Canned::new(refused(code, message));
            let answer = piped(&["b"], &canned.socket());
            assert_eq!(
                answer,
                (2, String::new(), format!("wherever: {message}\n")),
                "{code}"
            );
        }
    }

    #[test]
    fn root_is_refused_before_connecting() {
        let folder = Folder::new();
        let listener = UnixListener::bind(folder.socket()).unwrap();
        listener.set_nonblocking(true).unwrap();
        let root = Env { uid: 0, ..env() };
        let (code, out, err) = call(&["b"], &folder.socket(), false, &root);
        assert_eq!((code, out.as_str()), (2, ""));
        assert_eq!(err, "wherever: run wherever as yourself, not as root.\n");
        assert!(listener.accept().is_err());
    }

    #[test]
    fn a_long_socket_path_names_the_reason() {
        let long = PathBuf::from(format!("/private/tmp/{}/wherever.sock", "u".repeat(77)));
        assert_eq!(long.as_os_str().len(), 104);
        let (code, out, err) = piped(&["b"], &long);
        assert_eq!((code, out.as_str()), (2, ""));
        assert!(err.contains("longer than the 103 bytes"), "{err}");
        assert!(!err.contains("shorter user name"), "{err}");
        let fits = PathBuf::from(format!("/private/tmp/{}/wherever.sock", "u".repeat(76)));
        let (_, _, err) = piped(&["b"], &fits);
        assert_eq!(err, format!("wherever: {UNREACHABLE}\n"));
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
        let path = socket().unwrap();
        assert_eq!(path, cache.join("com.writronic.wherever/wherever.sock"));
        assert!(path.is_absolute(), "{path:?}");
        assert!(path.as_os_str().len() < SUN_PATH, "{path:?}");
    }

    #[derive(Default)]
    struct State {
        opened: RefCell<Vec<PathBuf>>,
        done: RefCell<Vec<PathBuf>>,
        waits: Cell<u32>,
    }

    struct Fake {
        app: Option<PathBuf>,
        running: bool,
        socket: PathBuf,
        serve_at: Option<u32>,
        answers: RefCell<Vec<Vec<u8>>>,
        state: Rc<State>,
    }

    impl Fake {
        fn new(folder: &Folder, answers: Vec<Vec<u8>>) -> (Fake, Rc<State>) {
            let state = Rc::new(State::default());
            let fake = Fake {
                app: Some(PathBuf::from("/Applications/Wherever.app")),
                running: false,
                socket: folder.socket(),
                serve_at: Some(0),
                answers: RefCell::new(answers),
                state: state.clone(),
            };
            (fake, state)
        }

        fn tick(&self) {
            if self.serve_at != Some(self.state.waits.get()) {
                return;
            }
            let listener = UnixListener::bind(&self.socket).unwrap();
            let answers = self.answers.take();
            thread::spawn(move || {
                for answer in answers {
                    let Ok((mut stream, _)) = listener.accept() else {
                        return;
                    };
                    let mut asked = Vec::new();
                    let _ = stream.read_to_end(&mut asked);
                    let _ = stream.write_all(&answer);
                }
            });
        }
    }

    impl Host for Fake {
        fn app(&self) -> Option<PathBuf> {
            self.app.clone()
        }

        fn running(&self, _: &Path) -> bool {
            self.running
        }

        fn open(&self, app: &Path) -> io::Result<()> {
            self.state.opened.borrow_mut().push(app.to_path_buf());
            self.tick();
            Ok(())
        }

        fn wait(&self, _: Duration) {
            self.state.waits.set(self.state.waits.get() + 1);
            self.tick();
        }

        fn done(&self, app: &Path) {
            self.state.done.borrow_mut().push(app.to_path_buf());
        }
    }

    fn launched(fake: Fake, folder: &Folder) -> (i32, String, String) {
        let env = Env {
            host: Box::new(fake),
            ..env()
        };
        call(&["b"], &folder.socket(), false, &env)
    }

    fn app() -> Vec<PathBuf> {
        vec![PathBuf::from("/Applications/Wherever.app")]
    }

    fn indexing() -> Vec<u8> {
        refused(
            "indexing",
            "Wherever is still indexing this Mac, 12 items so far. Try again in a moment.",
        )
    }

    #[test]
    fn a_closed_app_is_opened_once_and_answers_after_its_start() {
        let folder = Folder::new();
        let (mut fake, state) = Fake::new(&folder, vec![found(1, "", &[file("/a", "b.txt", "")])]);
        fake.serve_at = Some(3);
        let (code, out, err) = launched(fake, &folder);
        assert_eq!((code, out.as_str(), err.as_str()), (0, "/a/b.txt\n", ""));
        assert_eq!(*state.opened.borrow(), app());
        assert_eq!(state.waits.get(), 3);
        assert_eq!(*state.done.borrow(), app());
    }

    #[test]
    fn an_app_that_never_starts_gives_up_after_ten_seconds() {
        let folder = Folder::new();
        let (mut fake, state) = Fake::new(&folder, Vec::new());
        fake.serve_at = None;
        let unreachable = (2, String::new(), format!("wherever: {UNREACHABLE}\n"));
        assert_eq!(launched(fake, &folder), unreachable);
        assert_eq!(*state.opened.borrow(), app());
        assert_eq!(state.waits.get(), 100);
        assert!(state.done.borrow().is_empty());
    }

    #[test]
    fn an_indexing_answer_is_retried_until_the_index_is_ready() {
        let folder = Folder::new();
        let ok = found(1, "", &[file("/a", "b.txt", "")]);
        let (fake, state) = Fake::new(&folder, vec![indexing(), indexing(), ok]);
        let (code, out, _) = launched(fake, &folder);
        assert_eq!((code, out.as_str()), (0, "/a/b.txt\n"));
        assert_eq!(state.waits.get(), 3);
        assert_eq!(state.done.borrow().len(), 1);
    }

    #[test]
    fn an_indexing_answer_gives_up_at_fifteen_seconds() {
        let folder = Folder::new();
        let (fake, state) = Fake::new(&folder, vec![indexing(); 200]);
        let (code, out, err) = launched(fake, &folder);
        assert_eq!((code, out.as_str()), (2, ""));
        assert!(err.contains("still indexing this Mac, 12 items"), "{err}");
        assert_eq!(state.waits.get(), 150);
        assert_eq!(state.done.borrow().len(), 1);
    }

    #[test]
    fn every_answer_posts_command_done() {
        for answer in [
            found(1, "", &[file("/a", "b.txt", "")]),
            found(0, "", &[]),
            refused("failed", "the search failed"),
        ] {
            let folder = Folder::new();
            let (fake, state) = Fake::new(&folder, vec![answer]);
            launched(fake, &folder);
            assert_eq!(*state.done.borrow(), app());
        }
        let folder = Folder::new();
        let (fake, state) = Fake::new(&folder, vec![b"WHV1\0ok\0".to_vec()]);
        let (code, _, _) = launched(fake, &folder);
        assert_eq!(code, 2);
        assert!(state.done.borrow().is_empty());
    }

    #[test]
    fn a_running_copy_gets_no_open_only_retries() {
        let folder = Folder::new();
        let (mut fake, state) = Fake::new(&folder, vec![found(1, "", &[file("/a", "b.txt", "")])]);
        fake.running = true;
        fake.serve_at = Some(4);
        let (code, out, _) = launched(fake, &folder);
        assert_eq!((code, out.as_str()), (0, "/a/b.txt\n"));
        assert!(state.opened.borrow().is_empty());
        assert_eq!(state.waits.get(), 4);
    }

    #[test]
    fn a_tool_outside_an_app_prints_unreachable_at_once() {
        let folder = Folder::new();
        let (mut fake, state) = Fake::new(&folder, Vec::new());
        fake.app = None;
        let unreachable = (2, String::new(), format!("wherever: {UNREACHABLE}\n"));
        assert_eq!(launched(fake, &folder), unreachable);
        assert!(state.opened.borrow().is_empty());
        assert_eq!(state.waits.get(), 0);
    }

    #[test]
    fn an_app_is_found_from_the_tool_inside_it() {
        let tool = Path::new("/Applications/Wherever.app/Contents/Helpers/wherever");
        assert_eq!(
            launch::holding(tool),
            Some(PathBuf::from("/Applications/Wherever.app"))
        );
        for outside in [
            "/usr/local/bin/wherever",
            "/Users/a/target/debug/wherever",
            "/Applications/Wherever/Contents/Helpers/wherever",
            "/Applications/Wherever.app/Contents/MacOS/wherever",
            "/Applications/Wherever.app/Helpers/wherever",
        ] {
            assert_eq!(launch::holding(Path::new(outside)), None, "{outside}");
        }
        assert_eq!(System.app(), None);
    }

    #[test]
    fn only_the_apps_own_executable_counts_as_running() {
        let app = Path::new("/Applications/Wherever.app");
        let own = Path::new("/Applications/Wherever.app/Contents/MacOS/Wherever");
        let helper = Path::new(
            "/Applications/Wherever.app/Contents/Library/LoginItems/WhereverHelper.app/Contents/MacOS/WhereverHelper",
        );
        let other = Path::new("/Applications/Wherever.app2/Contents/MacOS/Wherever");
        assert!(launch::inside(own, app));
        assert!(!launch::inside(helper, app));
        assert!(!launch::inside(other, app));
    }

    #[test]
    fn the_process_list_holds_this_process() {
        let exe = env::current_exe().unwrap().canonicalize().unwrap();
        assert!(launch::paths().contains(&exe));
        assert!(!System.running(Path::new("/private/tmp/whv-none.app")));
    }
}
