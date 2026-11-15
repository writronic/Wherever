use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::macos::fs::MetadataExt;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use encoding_rs::{Decoder, UTF_8};

use super::mail::Mail;
use super::{language, rich};

pub(crate) const CHUNK: usize = 1 << 20;
const PEEK: usize = 8 << 10;
const SF_DATALESS: u32 = 0x4000_0000;

#[derive(Debug, PartialEq)]
pub(crate) struct Stopped;

pub(crate) fn ext(path: &Path) -> &[u8] {
    let name = path.file_name().map_or(&b""[..], OsStrExt::as_bytes);
    name.iter()
        .rposition(|&b| b == b'.')
        .filter(|&p| p > 0)
        .map_or(&b""[..], |p| &name[p + 1..])
}

pub(crate) fn is_rich(path: &Path) -> bool {
    rich::is(ext(path))
}

pub(crate) fn dataless(path: &Path) -> bool {
    #[cfg(test)]
    if tests::DATALESS.lock().unwrap().iter().any(|p| p == path) {
        return true;
    }
    fs::symlink_metadata(path).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0)
}

pub(crate) fn no_reader(path: &Path) -> bool {
    let ext = ext(path);
    ["epub", "pages", "key", "numbers"]
        .iter()
        .any(|e| ext.eq_ignore_ascii_case(e.as_bytes()))
}

fn open(path: &Path) -> Option<(File, u64)> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let meta = f.metadata().ok()?;
    meta.is_file().then_some((f, meta.len()))
}

fn more(f: &mut File, buf: &mut Vec<u8>, n: usize) -> bool {
    f.take(n as u64).read_to_end(buf).is_ok()
}

pub(crate) fn bytes(path: &Path, go: &mut dyn FnMut() -> bool) -> Result<Option<Vec<u8>>, Stopped> {
    let Some((mut f, size)) = open(path) else {
        return Ok(None);
    };
    let mut buf = Vec::new();
    if buf.try_reserve_exact(size as usize).is_err() {
        return Ok(None);
    }
    loop {
        let before = buf.len();
        if !more(&mut f, &mut buf, CHUNK) {
            return Ok(None);
        }
        if buf.len() - before < CHUNK {
            return Ok(Some(buf));
        }
        if !go() {
            return Err(Stopped);
        }
    }
}

fn text_start(head: &[u8]) -> bool {
    head.starts_with(&[0xFF, 0xFE]) || head.starts_with(&[0xFE, 0xFF]) || !head.contains(&0)
}

pub(crate) fn stream(
    path: &Path,
    go: &mut dyn FnMut() -> bool,
    seen: &mut dyn FnMut(&str) -> bool,
    alternate: &mut dyn FnMut(&str) -> bool,
) -> Result<Option<bool>, Stopped> {
    let Some((mut f, _)) = open(path) else {
        return Ok(Some(false));
    };
    let mut buf = Vec::with_capacity(CHUNK);
    if !more(&mut f, &mut buf, PEEK) {
        return Ok(Some(false));
    }
    if !text_start(&buf) {
        return Ok(None);
    }
    if buf.len() == PEEK && !more(&mut f, &mut buf, CHUNK - PEEK) {
        return Ok(Some(false));
    }
    let mut mail = Mail::new(path);
    let (mut decoder, mut text) = (UTF_8.new_decoder(), String::new());
    let mut fallback: Option<Decoder> = None;
    let mut first = true;
    loop {
        let last = buf.len() < CHUNK;
        let done = if let Some(mail) = &mut mail {
            mail.feed(&buf, last, seen)
        } else {
            text.clear();
            text.reserve(decoder.max_utf8_buffer_length(buf.len()).unwrap_or(0));
            let (_, _, replacements) = decoder.decode_to_string(&buf, &mut text, last);
            if seen(&text) {
                return Ok(Some(true));
            }
            if first && replacements && decoder.encoding() == UTF_8 {
                fallback = Some(language::fallback().new_decoder_without_bom_handling());
            }
            if let Some(decoder) = &mut fallback {
                text.clear();
                text.reserve(decoder.max_utf8_buffer_length(buf.len()).unwrap_or(0));
                let _ = decoder.decode_to_string(&buf, &mut text, last);
                alternate(&text)
            } else {
                false
            }
        };
        if done || last {
            return Ok(Some(true));
        }
        if !go() {
            return Err(Stopped);
        }
        first = false;
        buf.clear();
        if !more(&mut f, &mut buf, CHUNK) {
            return Ok(Some(false));
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crawl::Pool;
    use crate::crawl::tests::{TempTree, atime_policy};
    use std::ffi::CString;
    use std::fs;
    use std::os::unix::fs::MetadataExt;
    use std::path::PathBuf;
    use std::sync::Mutex;

    pub(crate) static DATALESS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

    fn needles(len: usize) -> Vec<u8> {
        b"needle\n"
            .iter()
            .copied()
            .cycle()
            .take(len.max(7))
            .collect()
    }

    pub(crate) fn read(path: &Path) -> Option<String> {
        let go = &mut || true;
        if is_rich(path) {
            return rich::text(ext(path), bytes(path, go).ok()??);
        }
        let mut text = String::new();
        let mut keep = |t: &str| {
            text.push_str(t);
            false
        };
        stream(path, go, &mut keep, &mut |_| false)
            .ok()??
            .then_some(text)
    }

    #[test]
    fn reading_decodes_utf16_reads_any_length_and_refuses_nul_and_links() {
        let tree = TempTree::new("text-read");
        let dir = PathBuf::from(tree.real());
        let at = |name: &str, bytes: &[u8]| {
            let path = dir.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, bytes).unwrap();
            path
        };
        let utf16 = |bom: [u8; 2], unit: fn(u16) -> [u8; 2]| {
            let mut b = bom.to_vec();
            b.extend("h\u{e9}llo".encode_utf16().flat_map(unit));
            b
        };
        let le = at("le.txt", &utf16([0xFF, 0xFE], u16::to_le_bytes));
        let be = at("be.txt", &utf16([0xFE, 0xFF], u16::to_be_bytes));
        assert_eq!(read(&le).as_deref(), Some("h\u{e9}llo"));
        assert_eq!(read(&be).as_deref(), Some("h\u{e9}llo"));
        assert_eq!(
            read(&at("bom.txt", b"\xEF\xBB\xBFword")).as_deref(),
            Some("word")
        );
        assert_eq!(read(&at("nul.txt", b"a\0b")), None);
        let mut head = vec![b'a'; PEEK - 1];
        head.push(0);
        assert_eq!(read(&at("head.txt", &head)), None);
        let mut late = vec![b'a'; PEEK];
        late.extend_from_slice(b"\0zyqlate");
        assert!(read(&at("late.txt", &late)).is_some_and(|t| t.ends_with("\0zyqlate")));
        let long = vec![b'a'; 5000];
        assert_eq!(read(&at("long.txt", &long)).map(|t| t.len()), Some(5000));
        let big = needles(CHUNK + 1);
        assert_eq!(
            read(&at("big.txt", &big)).map(String::into_bytes),
            Some(big)
        );
        assert!(read(&at("max.txt", &needles(CHUNK))).is_some());
        assert_eq!(read(&at("empty.txt", b"")).as_deref(), Some(""));
        let plain = at("real/plain.txt", b"words");
        std::os::unix::fs::symlink(&plain, dir.join("link.txt")).unwrap();
        std::os::unix::fs::symlink(dir.join("real"), dir.join("linked")).unwrap();
        assert_eq!(read(&plain).as_deref(), Some("words"));
        assert_eq!(read(&dir.join("link.txt")), None);
        assert_eq!(read(&dir.join("linked/plain.txt")), None);
        assert_eq!(read(&tree.0.join("real/plain.txt")), None);
        let fifo = CString::new(dir.join("pipe.txt").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0);
        assert_eq!(read(&dir.join("pipe.txt")), None);
    }

    #[test]
    fn search_content_reads_a_search_folder_spelled_through_links() {
        use crate::engine::tests::{phases, start, texts, until_live};
        use std::os::unix::fs::symlink;
        let tree = TempTree::new("text-scope-held");
        fs::write(tree.0.join("Sub/held.txt"), b"zyq").unwrap();
        let other = TempTree::new("text-scope-walked");
        fs::create_dir_all(other.0.join("Deep")).unwrap();
        fs::write(other.0.join("Deep/walked.txt"), b"zyq").unwrap();
        let links = TempTree::new("text-scope-links");
        let up = links.0.join("up");
        symlink(Path::new(&tree.real()).parent().unwrap(), &up).unwrap();
        let last = links.0.join("last");
        symlink(Path::new(&other.real()).join("Deep"), &last).unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let via = |t: &TempTree, sub: &str| {
            let name = t.0.file_name().unwrap().to_str().unwrap();
            format!("{}/{name}/{sub}", up.display())
        };
        for (folder, file) in [
            (format!("{}/Sub", tree.real()), "held.txt"),
            (format!("{}/Sub", tree.root()), "held.txt"),
            (via(&tree, "Sub"), "held.txt"),
            (format!("{}/Deep", other.real()), "walked.txt"),
            (format!("{}/Deep", other.root()), "walked.txt"),
            (via(&other, "Deep"), "walked.txt"),
            (last.display().to_string(), "walked.txt"),
        ] {
            let found = texts(&engine, &rx, &format!("text:zyq in:{folder}"));
            assert_eq!(found, [file], "Search Content in {folder}");
        }
    }

    #[test]
    fn unicode_and_mail_never_use_the_legacy_decoder() {
        let tree = TempTree::new("text-no-legacy");
        let mut utf16 = vec![0xff, 0xfe];
        utf16.extend("şirket".encode_utf16().flat_map(u16::to_le_bytes));
        for (name, bytes) in [
            ("utf8.txt", "şirket café".as_bytes()),
            ("utf16.txt", utf16.as_slice()),
            ("damaged-utf16.txt", &b"\xff\xfe\x00\xd8"[..]),
            ("mail.eml", &b"Subject: caf\xe9\n\nbody\n"[..]),
        ] {
            let path = PathBuf::from(tree.real()).join(name);
            fs::write(&path, bytes).unwrap();
            let mut text = String::new();
            assert_eq!(
                stream(
                    &path,
                    &mut || true,
                    &mut |part| {
                        text.push_str(part);
                        false
                    },
                    &mut |_| panic!("unexpected legacy decode: {name}")
                ),
                Ok(Some(true))
            );
            if name == "utf8.txt" || name == "utf16.txt" {
                assert!(text.starts_with("şirket"));
            }
        }
    }

    #[test]
    fn a_read_leaves_the_access_time_alone() {
        atime_kept("text-atime", "old.txt", b"words");
    }

    #[test]
    fn a_rich_read_leaves_the_access_time_alone() {
        atime_kept(
            "text-atime-rich",
            "old.docx",
            &crate::text::rich::tests::docx("words"),
        );
    }

    fn atime_kept(name: &str, file: &str, bytes: &[u8]) {
        let tree = TempTree::new(name);
        let path = PathBuf::from(tree.real()).join(file);
        fs::write(&path, bytes).unwrap();
        let c = CString::new(path.as_os_str().as_bytes()).unwrap();
        let age = || {
            let m = fs::metadata(&path).unwrap().mtime();
            let times = [
                libc::timeval {
                    tv_sec: m - 100,
                    tv_usec: 0,
                },
                libc::timeval {
                    tv_sec: m,
                    tv_usec: 0,
                },
            ];
            assert_eq!(unsafe { libc::utimes(c.as_ptr(), times.as_ptr()) }, 0);
            m - 100
        };
        let atime = || fs::metadata(&path).unwrap().atime();
        let old = age();
        assert!(read(&path).is_some());
        assert_ne!(
            atime(),
            old,
            "a plain read keeps the access time, so this test proves nothing"
        );
        let old = age();
        let pool = Pool::text(1).unwrap();
        assert_eq!(
            pool.install(|| (atime_policy(), read(&path).is_some())),
            (1, true)
        );
        assert_eq!(atime(), old);
    }
}
