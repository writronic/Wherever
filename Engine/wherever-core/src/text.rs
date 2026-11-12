mod language;
mod mail;
mod pptx;
mod rich;
mod rtf;
pub(crate) mod scope;
pub(crate) mod search;

use std::sync::{Condvar, Mutex, PoisonError};

use crate::query::{Term, fold};
use crate::rank::reading;

pub(crate) const READERS: usize = 4;
const RICH_BUDGET: u64 = 16 << 20;
static RICH: Budget = Budget::new(RICH_BUDGET);

pub(crate) struct Terms {
    pub(crate) terms: Vec<Term>,
    pub(crate) all: bool,
}

impl Terms {
    pub(crate) fn seen(&self) -> Seen {
        let needle = |t: &str| {
            let p = Some(plain(t))
                .filter(|p| !p.trim().is_empty())
                .unwrap_or_else(|| t.to_owned());
            let mut one = String::with_capacity(p.len());
            spaced(&p, &mut false, &mut one);
            one
        };
        let needles: Vec<Term> = (self.terms.iter())
            .map(|(term, other)| {
                let (term, other) = match other {
                    Some(o) if marked(term) && !marked(o) => (o, None),
                    Some(o) if marked(o) => (term, None),
                    _ => (term, other.as_ref()),
                };
                let term = needle(term);
                let other = other.map(|o| needle(o)).filter(|o| *o != term);
                (term, other)
            })
            .collect();
        let longest = (needles.iter())
            .flat_map(|(term, other)| [Some(term), other.as_ref()])
            .flatten()
            .map(String::len)
            .max()
            .unwrap_or(0);
        Seen {
            all: self.all,
            found: vec![false; needles.len()],
            needles,
            window: String::new(),
            space: false,
            keep: longest.saturating_sub(1),
        }
    }
}

fn plain(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    #[cfg(test)]
    tests::PLAIN_FOLDS.with(|n| n.set(n.get() + 1));
    let folded = fold(s);
    reading(folded.as_bytes()).unwrap_or(folded)
}

const LANE: usize = 32;

fn calm(lane: &[u8; LANE + 1]) -> bool {
    let mut odd = false;
    for (&a, &b) in lane[..LANE].iter().zip(&lane[1..]) {
        odd |= (a.wrapping_sub(b'\t') < 5) | (a >= 0x80) | ((a == b' ') & (b == b' '));
    }
    !odd
}

fn spaced(text: &str, space: &mut bool, out: &mut String) {
    let bytes = text.as_bytes();
    let white = |i: usize| match bytes[i] {
        b'\t'..=b'\r' | b' ' => (true, 1),
        b if b.is_ascii() => (false, 1),
        _ => {
            let c = text[i..].chars().next().unwrap_or_default();
            (c.is_whitespace(), c.len_utf8())
        }
    };
    let copy = |slice: &str, out: &mut String| {
        if !slice.is_empty() {
            #[cfg(test)]
            tests::SPACED_COPIES.with(|n| n.set(n.get() + 1));
            out.push_str(slice);
        }
    };
    let (mut from, mut i) = (0, 0);
    while i < bytes.len() {
        if let Some(lane) = bytes[i..].first_chunk::<{ LANE + 1 }>()
            && !(*space && lane[0] == b' ')
            && calm(lane)
        {
            *space = lane[LANE - 1] == b' ';
            i += LANE;
            continue;
        }
        let end = (i + LANE).min(bytes.len());
        while i < end {
            let (w, len) = white(i);
            if !w {
                *space = false;
                i += len;
                continue;
            }
            let start = i;
            i += len;
            while i < bytes.len() {
                let (w, len) = white(i);
                if !w {
                    break;
                }
                i += len;
            }
            if *space || i - start > 1 || bytes[start] != b' ' {
                copy(&text[from..start], out);
                if !*space {
                    out.push(' ');
                }
                from = i;
            }
            *space = true;
        }
    }
    copy(&text[from..], out);
}

fn marked(s: &str) -> bool {
    s.chars().any(|c| {
        matches!(c, '\u{300}'..='\u{36f}' | '\u{622}'..='\u{626}'
            | '\u{640}' | '\u{64b}'..='\u{65f}' | '\u{670}'..='\u{673}'
            | '\u{3000}' | '\u{ff10}'..='\u{ff19}' | '\u{ff21}'..='\u{ff3a}'
            | '\u{ff41}'..='\u{ff5a}')
    })
}

pub(crate) struct Seen {
    all: bool,
    needles: Vec<Term>,
    found: Vec<bool>,
    window: String,
    space: bool,
    keep: usize,
}

impl Seen {
    pub(crate) fn feed(&mut self, piece: &str) -> bool {
        if piece.is_ascii() {
            let from = self.window.len();
            spaced(piece, &mut self.space, &mut self.window);
            self.window[from..].make_ascii_lowercase();
        } else {
            spaced(&plain(piece), &mut self.space, &mut self.window);
        }
        for (found, (term, other)) in self.found.iter_mut().zip(&self.needles) {
            *found = *found
                || self.window.contains(term.as_str())
                || other
                    .as_ref()
                    .is_some_and(|o| self.window.contains(o.as_str()));
        }
        let tail = (self.window).floor_char_boundary(self.window.len().saturating_sub(self.keep));
        self.window.drain(..tail);
        self.held()
    }

    pub(crate) fn held(&self) -> bool {
        if self.all {
            self.found.iter().all(|&f| f)
        } else {
            self.found.iter().any(|&f| f)
        }
    }
}

struct Budget {
    limit: u64,
    flight: Mutex<(u64, usize)>,
    freed: Condvar,
}

impl Budget {
    const fn new(limit: u64) -> Budget {
        Budget {
            limit,
            flight: Mutex::new((0, 0)),
            freed: Condvar::new(),
        }
    }

    fn take(&self, size: u64) -> Taken<'_> {
        let flight = self.flight.lock().unwrap_or_else(PoisonError::into_inner);
        let mut flight = (self.freed)
            .wait_while(flight, |&mut (bytes, docs)| {
                docs > 0 && bytes.saturating_add(size) > self.limit
            })
            .unwrap_or_else(PoisonError::into_inner);
        flight.0 += size;
        flight.1 += 1;
        Taken(self, size)
    }
}

struct Taken<'a>(&'a Budget, u64);

impl Drop for Taken<'_> {
    fn drop(&mut self) {
        let mut flight = (self.0.flight.lock()).unwrap_or_else(PoisonError::into_inner);
        flight.0 -= self.1;
        flight.1 -= 1;
        self.0.freed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::search::Verdict;
    use super::*;
    use crate::crawl::Pool;
    use crate::crawl::tests::TempTree;
    use crate::engine::tests::{phases, shared, start, start_with, text_config, texts, until_live};
    use rayon::prelude::*;
    use std::cell::Cell;
    use std::fs;
    use std::os::unix::fs::MetadataExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::thread;
    use std::time::Duration;

    thread_local! {
        pub(crate) static PLAIN_FOLDS: Cell<usize> = const { Cell::new(0) };
        pub(crate) static SPACED_COPIES: Cell<usize> = const { Cell::new(0) };
    }

    static IN_FLIGHT: Mutex<(u64, usize)> = Mutex::new((0, 0));
    static MOST_IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);
    static OVER_BUDGET: AtomicBool = AtomicBool::new(false);
    static HOLD_MS: AtomicU64 = AtomicU64::new(0);
    static SERIAL: Mutex<()> = Mutex::new(());

    pub(crate) struct InFlight(u64);

    impl InFlight {
        pub(crate) fn enter(size: u64) -> InFlight {
            {
                let mut f = IN_FLIGHT.lock().unwrap_or_else(PoisonError::into_inner);
                (f.0, f.1) = (f.0 + size, f.1 + 1);
                MOST_IN_FLIGHT.fetch_max(f.1, Ordering::SeqCst);
                if f.1 > 1 && f.0 > RICH_BUDGET {
                    OVER_BUDGET.store(true, Ordering::SeqCst);
                }
            }
            thread::sleep(Duration::from_millis(HOLD_MS.load(Ordering::Relaxed)));
            InFlight(size)
        }
    }

    impl Drop for InFlight {
        fn drop(&mut self) {
            let mut f = IN_FLIGHT.lock().unwrap_or_else(PoisonError::into_inner);
            (f.0, f.1) = (f.0 - self.0, f.1 - 1);
        }
    }

    fn terms(words: &[&str], all: bool) -> Terms {
        let terms = words.iter().map(|w| crate::query::term(w)).collect();
        Terms { terms, all }
    }

    fn read_documents(name: &str, n: usize, size: u64) -> Vec<bool> {
        use crate::text::rich::tests::docx;
        let tree = TempTree::new(name);
        let root = PathBuf::from(tree.real());
        let paths: Vec<PathBuf> = (0..n).map(|i| root.join(format!("d{i}.docx"))).collect();
        for p in &paths {
            fs::write(p, docx("zyqbudget")).unwrap();
        }
        let pool = Pool::text(READERS).unwrap();
        HOLD_MS.store(50, Ordering::Relaxed);
        let terms = terms(&["zyqbudget"], true);
        let read = pool.install(|| {
            (paths.par_iter())
                .map(|p| {
                    search::holds(p, size, &terms, &mut || true, || Some(())) == Ok(Verdict::Holds)
                })
                .collect()
        });
        HOLD_MS.store(0, Ordering::Relaxed);
        read
    }

    #[test]
    fn a_press_reads_small_documents_side_by_side() {
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        MOST_IN_FLIGHT.store(0, Ordering::SeqCst);
        assert_eq!(read_documents("text-docs-side", 8, 1 << 10), [true; 8]);
        assert!(MOST_IN_FLIGHT.load(Ordering::SeqCst) > 1);
        assert!(!OVER_BUDGET.load(Ordering::SeqCst));
    }

    #[test]
    fn a_document_over_the_budget_reads_alone() {
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        assert_eq!(
            read_documents("text-doc-alone", 4, RICH_BUDGET + 1),
            [true; 4]
        );
        assert!(!OVER_BUDGET.load(Ordering::SeqCst));
    }

    #[test]
    fn the_budget_lets_documents_in_by_their_bytes() {
        fn waits(t: &thread::ScopedJoinHandle<'_, ()>) -> bool {
            thread::sleep(Duration::from_millis(50));
            !t.is_finished()
        }
        let b = Budget::new(10);
        let lone = b.take(20);
        thread::scope(|s| {
            let small = s.spawn(|| drop(b.take(1)));
            assert!(waits(&small));
            drop(lone);
            small.join().unwrap();
        });
        let (x, y) = (b.take(4), b.take(4));
        thread::scope(|s| {
            let third = s.spawn(|| drop(b.take(4)));
            let big = s.spawn(|| drop(b.take(20)));
            assert!(waits(&third) && waits(&big));
            drop(x);
            third.join().unwrap();
            assert!(waits(&big));
            drop(y);
            big.join().unwrap();
        });
        assert_eq!(*b.flight.lock().unwrap(), (0, 0));
    }

    fn listing(dirs: &[&Path]) -> Vec<(PathBuf, u64, i64, i64)> {
        let mut out = Vec::new();
        let mut todo: Vec<PathBuf> = dirs.iter().map(|d| d.to_path_buf()).collect();
        while let Some(d) = todo.pop() {
            for e in fs::read_dir(&d).unwrap() {
                let path = e.unwrap().path();
                let m = fs::symlink_metadata(&path).unwrap();
                if m.is_dir() {
                    todo.push(path.clone());
                }
                out.push((path, m.size(), m.mtime(), m.mtime_nsec()));
            }
        }
        out.sort();
        out
    }

    #[test]
    fn a_press_reads_its_files_and_writes_none() {
        let tree = TempTree::new("text-read-nowrite");
        for i in 0..20 {
            let path = tree.0.join(format!("home/r{i}.md"));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "read not built").unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let data = tree.data();
        let before = listing(&[&tree.0, &data]);
        assert!(before.iter().any(|(p, ..)| p.starts_with(&data)));
        assert_eq!(texts(&engine, &rx, "text:built").len(), 20);
        assert_eq!(shared(&engine).reads.lock().unwrap().len(), 24);
        assert!(!data.join("Text").exists());
        assert_eq!(listing(&[&tree.0, &data]), before);
    }

    fn file(tree: &TempTree, name: &str, bytes: &[u8]) -> PathBuf {
        let path = PathBuf::from(tree.real()).join(name);
        fs::write(&path, bytes).unwrap();
        path
    }

    fn holds(path: &Path, words: &[&str]) -> bool {
        let size = fs::metadata(path).unwrap().len();
        search::holds(path, size, &terms(words, true), &mut || true, || Some(())).unwrap()
            == Verdict::Holds
    }

    fn filler(len: usize) -> Vec<u8> {
        b"lorem\n".iter().copied().cycle().take(len).collect()
    }

    fn utf16(pad: usize, text: &str) -> Vec<u8> {
        let mut b = vec![0xFF, 0xFE];
        let units = "a".repeat(pad) + text;
        b.extend(units.encode_utf16().flat_map(u16::to_le_bytes));
        b
    }

    #[test]
    fn a_text_file_of_any_name_is_read() {
        let tree = TempTree::new("text-any-name");
        let mut readme = filler(300 << 10);
        readme.extend_from_slice(b"zyqany\n");
        let mut minified = vec![b'x'; 200 << 10];
        minified.extend_from_slice(b";zyqany;");
        file(&tree, "notes.weird", b"zyqany");
        file(&tree, "README", &readme);
        file(&tree, "Cargo.lock", b"name = \"zyqany\"");
        file(&tree, "app.min.js", &minified);
        file(&tree, "photo.raw", b"\x89RAW\0\0zyqany");
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(
            texts(&engine, &rx, "text:zyqany"),
            ["Cargo.lock", "README", "app.min.js", "notes.weird"]
        );
    }

    #[test]
    fn a_term_past_one_mebibyte_is_found() {
        let tree = TempTree::new("text-past-chunk");
        let mut big = filler(3 << 20);
        big.extend_from_slice(b"zyqend\n");
        let path = file(&tree, "big.log", &big);
        assert!(holds(&path, &["zyqend"]));
        assert!(!holds(&path, &["zyqnowhere"]));
    }

    #[test]
    fn a_term_across_a_chunk_boundary_is_found() {
        let tree = TempTree::new("text-boundary");
        let mut utf8 = vec![b'a'; scope::CHUNK - 3];
        utf8.extend_from_slice(b"zyqsplit");
        assert!(holds(&file(&tree, "utf8.txt", &utf8), &["zyqsplit"]));
        let le = utf16((scope::CHUNK - 6) / 2, "zyqsplit");
        assert!(holds(&file(&tree, "utf16.txt", &le), &["zyqsplit"]));
    }

    #[test]
    fn a_character_split_across_a_boundary_folds_once() {
        let tree = TempTree::new("text-split-char");
        let mut dotted = vec![b'a'; scope::CHUNK - 2];
        dotted.extend_from_slice("z\u{130}q".as_bytes());
        let mut emoji = vec![b'a'; scope::CHUNK - 3];
        emoji.extend_from_slice("z\u{1F600}q".as_bytes());
        let pair = utf16((scope::CHUNK - 6) / 2, "z\u{1F600}q");
        for (name, bytes, term) in [
            ("dotted.txt", dotted, "Z\u{130}Q"),
            ("emoji.txt", emoji, "z\u{1F600}q"),
            ("pair.txt", pair, "z\u{1F600}q"),
        ] {
            let path = file(&tree, name, &bytes);
            assert!(holds(&path, &[term]), "{name}");
            assert!(
                !holds(&path, &["\u{FFFD}"]),
                "{name} decoded a split character as two"
            );
        }
    }

    #[test]
    fn a_stop_mid_stream_returns_before_the_file_ends() {
        let tree = TempTree::new("text-stop-stream");
        let mut big = filler(3 << 20);
        big.extend_from_slice(b"zyqend\n");
        let path = file(&tree, "big.log", &big);
        let mut asked = 0;
        let mut go = || {
            asked += 1;
            false
        };
        let terms = terms(&["zyqend"], true);
        let size = big.len() as u64;
        assert_eq!(
            search::holds(&path, size, &terms, &mut go, || Some(())),
            Err(scope::Stopped)
        );
        assert_eq!(asked, 1);
    }

    #[test]
    fn a_word_in_a_base64_mail_part_is_found() {
        let tree = TempTree::new("text-mail-base64");
        let mail =
            b"Subject: hi\r\nContent-Type: multipart/alternative; boundary=\"zz\"\r\n\r\n--zz\r\n\
            Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\
            TWVyaGFiYSB6eX\r\nFiYXNlNjQgZMO8bnlhCg==\r\n--zz--\r\n";
        let path = file(&tree, "one.eml", mail);
        assert!(holds(&path, &["zyqbase64", "d\u{fc}nya"]));
        assert!(!holds(&path, &["TWVyaGFi"]));
    }

    #[test]
    fn a_word_split_by_a_quoted_printable_soft_break_is_found() {
        let tree = TempTree::new("text-mail-quoted");
        let mail = b"Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n\
            The word zyq=\nsoft is split, and so is zyq=C3=\n=A9t=C3=A9.\n";
        let path = file(&tree, "two.eml", mail);
        assert!(holds(&path, &["zyqsoft", "zyq\u{e9}t\u{e9}"]));
    }

    #[test]
    fn a_word_in_an_encoded_subject_is_found() {
        let tree = TempTree::new("text-mail-subject");
        let utf8 = file(
            &tree,
            "utf8.eml",
            b"Subject: =?UTF-8?B?VG9wbGFudMSxIHp5ccOnacOnZWs=?=\n\nbody\n",
        );
        assert!(holds(&utf8, &["zyq\u{e7}i\u{e7}ek"]));
        let turkish = file(
            &tree,
            "turkish.eml",
            b"Subject: =?ISO-8859-9?Q?zyq=FEi=FEe_bir?=\n =?utf-8?q?zyq?=  =?utf-8?q?joined?=\n\nbody\n",
        );
        assert!(holds(&turkish, &["zyq\u{15f}i\u{15f}e bir", "zyqjoined"]));
        assert!(!holds(&turkish, &["zyq\u{fe}i"]));
    }

    #[test]
    fn an_emlx_is_read_to_its_byte_count_and_not_its_plist() {
        let tree = TempTree::new("text-mail-emlx");
        let message = b"Subject: x\nContent-Transfer-Encoding: base64\n\nenlxZW1seCB3b3Jkcwo=\n";
        let mut emlx = format!("{}\n", message.len()).into_bytes();
        emlx.extend_from_slice(message);
        emlx.extend_from_slice(
            b"<?xml version=\"1.0\"?>\n<plist><dict><key>zyqplist</key></dict></plist>\n",
        );
        let path = file(&tree, "1.emlx", &emlx);
        assert!(holds(&path, &["zyqemlx"]));
        assert!(!holds(&path, &["zyqplist"]));
    }

    #[test]
    fn a_word_in_an_image_part_is_not_found() {
        let tree = TempTree::new("text-mail-image");
        let mail = b"Content-Type: multipart/mixed; boundary=b1\n\npreamble zyqpreamble\n--b1\n\nzyqtext\n\
            --b1\nContent-Type: image/png\nContent-Transfer-Encoding: base64\n\nenlxaW1hZ2U=\n\
            --b1\nContent-Type: application/octet-stream\n\nzyqrawimg\n--b1--\nepilogue zyqepilogue\n";
        let path = file(&tree, "three.eml", mail);
        assert!(holds(&path, &["zyqtext"]));
        for word in ["zyqimage", "zyqrawimg", "zyqpreamble", "zyqepilogue"] {
            assert!(!holds(&path, &[word]), "{word}");
        }
    }

    #[test]
    fn a_malformed_mail_reads_what_it_can() {
        let tree = TempTree::new("text-mail-malformed");
        let broken = b"Content-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Transfer-Encoding: base64\n\n\
            enlxYnJv!!a2VuIGJh\nc2U2NCBwYXJ0Cg";
        assert!(holds(&file(&tree, "broken.eml", broken), &["zyqbroken"]));
        let empty = b"Content-Type: multipart/mixed; boundary=\"\"\n\nzyqnobound\n";
        assert!(holds(&file(&tree, "empty.eml", empty), &["zyqnobound"]));
        let mut deep = Vec::new();
        for i in 0..100 {
            deep.extend(
                format!("Content-Type: multipart/mixed; boundary=d{i}\n\n--d{i}\n").bytes(),
            );
        }
        deep.extend_from_slice(b"\nzyqdeep\n");
        assert!(holds(&file(&tree, "deep.eml", &deep), &["zyqdeep"]));
        let mut long = b"Subject: ".to_vec();
        long.extend(std::iter::repeat_n(b'=', 3 << 20));
        long.extend_from_slice(b"\n\nzyqlong\n");
        assert!(holds(&file(&tree, "long.eml", &long), &["zyqlong"]));
        let mut high: Vec<u8> = (1..=255).collect();
        high.extend_from_slice(b"\n\nzyqhigh\n");
        for (name, bytes) in [
            ("open.eml", &b"Subject: =?utf-8?B?enlx\n"[..]),
            ("eq.eml", b"Subject: =?x?Q?=?= =?\n\n=\n"),
            ("dashes.eml", b"--\n--\n\n--\n"),
            ("count.emlx", b"99999999999999999999999\nzyq"),
            ("short.emlx", b"5\n"),
            ("high.eml", &high),
        ] {
            let _ = holds(&file(&tree, name, bytes), &["zyqnone"]);
        }
    }

    #[test]
    fn an_mbox_message_past_one_chunk_is_found() {
        let tree = TempTree::new("text-mail-mbox");
        let mut mbox = b"From a@example.com Mon Oct 19 10:00:00 2026\nSubject: one\n\n".to_vec();
        mbox.extend(filler(scope::CHUNK + 100));
        mbox.extend_from_slice(
            b"\n\nFrom b@example.com Tue Oct 20 10:00:00 2026\nContent-Transfer-Encoding: base64\n\nenlxbWJveAo=\n",
        );
        let path = file(&tree, "Inbox.mbox", &mbox);
        assert!(holds(&path, &["zyqmbox"]));
        assert!(!holds(&path, &["enlxbWJveAo"]));
    }

    #[test]
    fn a_term_without_its_accents_finds_the_accented_text() {
        let tree = TempTree::new("text-accent-plain");
        let txt = file(&tree, "a.txt", "Toplant\u{131} \u{f6}zeti\n".as_bytes());
        let upper = file(&tree, "b.txt", "\u{d6}ZET".as_bytes());
        let nfd = file(&tree, "c.txt", "o\u{308}zet".as_bytes());
        let other = file(&tree, "d.txt", b"oz et ozt");
        for path in [&txt, &upper, &nfd] {
            assert!(holds(path, &["ozet"]), "{path:?}");
            assert!(holds(path, &["OZET"]), "{path:?}");
        }
        assert!(holds(&txt, &["toplanti ozet"]));
        assert!(!holds(&other, &["ozet"]));
    }

    #[test]
    fn an_accented_term_finds_the_text_without_its_accents() {
        let tree = TempTree::new("text-accent-typed");
        let txt = file(&tree, "a.txt", b"Toplanti OZETI\n");
        let other = file(&tree, "b.txt", b"ozt zet");
        for term in [
            "\u{f6}zet",
            "\u{d6}ZET",
            "o\u{308}zet",
            "toplant\u{131} \u{f6}zet",
        ] {
            assert!(holds(&txt, &[term]), "{term:?}");
            assert!(!holds(&other, &[term]), "{term:?}");
        }
    }

    #[test]
    fn arabic_and_full_width_content_terms_match_both_ways() {
        let tree = TempTree::new("text-arabic-width");
        for (i, (marked, plain)) in [
            ("مُدَرِّس", "مدرس"),
            ("أحمد", "احمد"),
            ("كـتـاب", "كتاب"),
            ("آإأٱٲٳؤئ", "ااااااوي"),
            ("هٰذا", "هذا"),
            ("ＲＥＰＯＲＴ２０２６", "report2026"),
            ("ＲＥＰＯＲＴ　２０２６", "report 2026"),
        ]
        .into_iter()
        .enumerate()
        {
            let marked_file = file(&tree, &format!("marked-{i}.txt"), marked.as_bytes());
            let plain_file = file(&tree, &format!("plain-{i}.txt"), plain.as_bytes());
            assert!(holds(&marked_file, &[plain]), "{plain} in {marked}");
            assert!(holds(&plain_file, &[marked]), "{marked} in {plain}");
            assert!(!holds(&marked_file, &["missing"]));
        }
        let words = terms(&["مدرس", "report2026"], true);
        let mut seen = words.seen();
        assert!(!seen.feed("مُدَ"));
        assert!(!seen.feed("رِّس ＲＥＰＯＲＴ２０"));
        assert!(seen.feed("２６"));
        let words = terms(&["\u{64b}", "\u{670}", "ـ"], false);
        assert!(!words.seen().feed("مُدَرِّس anything"));
    }

    #[test]
    fn every_reader_reads_its_text_without_accents() {
        use crate::text::rich::tests::docx;
        let tree = TempTree::new("text-accent-rich");
        let word = file(&tree, "a.docx", &docx("Toplant\u{131} \u{d6}zeti"));
        let rtf = file(
            &tree,
            "b.rtf",
            br"{\rtf1\ansi\ansicpg1252 Toplant\u305? \'d6zeti\par}",
        );
        let mail = file(&tree, "c.eml", b"Subject: =?UTF-8?Q?=C3=96zet?=\n\nbody\n");
        for path in [&word, &rtf, &mail] {
            assert!(holds(path, &["ozet"]), "{path:?}");
            assert!(!holds(path, &["ozt"]), "{path:?}");
        }
        assert!(holds(&word, &["toplanti", "\u{f6}zet"]));
        assert!(holds(&rtf, &["TOPLANTI \u{d6}ZET"]));
    }

    #[test]
    fn find_any_term_ignores_accents_too() {
        let tree = TempTree::new("text-accent-any");
        let path = file(&tree, "a.txt", "caf\u{e9} \u{f6}zet".as_bytes());
        let size = fs::metadata(&path).unwrap().len();
        let verdict = |words: &[&str], all| {
            search::holds(&path, size, &terms(words, all), &mut || true, || Some(()))
        };
        assert_eq!(verdict(&["zyqnone", "ozet"], false), Ok(Verdict::Holds));
        assert_eq!(verdict(&["zyqnone", "ozet"], true), Ok(Verdict::Lacks));
        assert_eq!(verdict(&["cafe", "ozet"], true), Ok(Verdict::Holds));
        assert_eq!(verdict(&["zyqnone", "zyqother"], false), Ok(Verdict::Lacks));
    }

    #[test]
    fn a_term_split_across_pieces_at_a_mark_is_found() {
        for pieces in [
            &["o", "\u{308}zet"][..],
            &["\u{f6}", "zet"][..],
            &["\u{d6}Z", "ET"][..],
            &["o\u{308}", "z", "et"][..],
        ] {
            for word in ["ozet", "\u{f6}zet"] {
                let terms = terms(&[word], true);
                let mut seen = terms.seen();
                let held = pieces.iter().any(|p| seen.feed(p));
                assert!(held, "{word:?} in {pieces:?}");
            }
        }
        let terms = terms(&["ozet"], true);
        let mut seen = terms.seen();
        assert!(!["o\u{308}x", "zet"].iter().any(|p| seen.feed(p)));
    }

    #[test]
    fn a_term_of_marks_alone_holds_nothing() {
        let terms = terms(&["\u{301}", "\u{301} \u{301}"], false);
        let mut seen = terms.seen();
        assert!(!seen.feed("cafe\u{301} caf\u{e9} any thing"));
    }

    #[test]
    fn a_letter_the_fold_keeps_never_reads_as_another() {
        let tree = TempTree::new("text-accent-kept");
        let mine = file(
            &tree,
            "a.txt",
            "\u{43c}\u{43e}\u{439} \u{434}\u{440}\u{443}\u{433}".as_bytes(),
        );
        let plural = file(
            &tree,
            "b.txt",
            "\u{43c}\u{43e}\u{438} \u{434}\u{440}\u{443}\u{437}\u{44c}\u{44f}".as_bytes(),
        );
        for term in [
            "\u{43c}\u{43e}\u{439}",
            "\u{43c}\u{43e}\u{438}\u{306}",
            "\u{41c}\u{41e}\u{419}",
        ] {
            assert!(holds(&mine, &[term]), "{term:?}");
            assert!(!holds(&plural, &[term]), "{term:?}");
        }
        let kana = file(&tree, "c.txt", "\u{304b}\u{3099}".as_bytes());
        assert!(holds(&kana, &["\u{304c}"]));
    }

    #[test]
    fn any_run_of_whitespace_in_the_text_matches_one_space() {
        let tree = TempTree::new("text-phrase-space");
        for (i, text) in [
            "quarterly\nbudget review",
            "quarterly\r\nbudget",
            "quarterly\tbudget",
            "quarterly  budget",
            "quarterly \r\n\t\x0b\x0c budget",
            "quarterly\u{a0}budget",
            "quarterly\u{2007}budget",
            "quarterly\u{202f}budget",
            "quarterly\u{3000}\u{a0}budget",
            "Quarterly\nB\u{fc}dget",
        ]
        .into_iter()
        .enumerate()
        {
            let path = file(&tree, &format!("{i}.txt"), text.as_bytes());
            for term in [
                "quarterly budget",
                "quarterly\tbudget",
                "quarterly  budget",
                "quarterly\u{a0}budget",
                "QUARTERLY \u{202f}B\u{dc}DGET",
            ] {
                assert!(holds(&path, &[term]), "{term:?} in {text:?}");
            }
            assert!(!holds(&path, &["quarterlybudget"]), "{text:?}");
        }
        let glued = file(&tree, "glued.txt", b"quarterlybudget");
        assert!(!holds(&glued, &["quarterly budget"]));
        let article = file(
            &tree,
            "article.txt",
            "article\u{a0}12 and a\t\tb".as_bytes(),
        );
        assert!(holds(&article, &["article 12", "a b"]));
        assert!(!holds(&article, &["article12"]));
    }

    #[test]
    fn a_whitespace_run_split_across_pieces_is_one_space() {
        let words = terms(&["quarterly budget"], true);
        for pieces in [
            &["quarterly\n", " budget"][..],
            &["quarterly", "\n", "\t", "budget"][..],
            &["quarterly \u{a0}", "\u{202f} budget"][..],
            &["quarterly", " budget"][..],
            &["the quarterly", "\r\n", "", "  budget"][..],
        ] {
            let mut seen = words.seen();
            assert!(pieces.iter().any(|p| seen.feed(p)), "{pieces:?}");
        }
        let mut seen = words.seen();
        assert!(!["quarterly", "budget"].iter().any(|p| seen.feed(p)));
        let spaced = terms(&["quarterly \t budget", "q3"], true);
        let seen = spaced.seen();
        assert_eq!(seen.needles[0].0, "quarterly budget");
        assert_eq!(seen.keep, "quarterly budget".len() - 1);
    }

    #[test]
    fn every_reader_matches_a_phrase_across_its_breaks() {
        use crate::text::rich::tests::docx;
        let tree = TempTree::new("text-phrase-readers");
        let word = file(
            &tree,
            "a.docx",
            &docx(
                "quarterly</w:t><w:br/><w:t>budget and article\u{a0}12 and x</w:t><w:tab/><w:t>y",
            ),
        );
        let mail = file(
            &tree,
            "b.eml",
            b"Subject: plan\n\nthe quarterly\nbudget is here\n",
        );
        let rtf = file(
            &tree,
            "c.rtf",
            br"{\rtf1\ansi quarterly\line budget\tab x\par}",
        );
        for path in [&word, &mail, &rtf] {
            assert!(holds(path, &["quarterly budget"]), "{path:?}");
            assert!(!holds(path, &["quarterlybudget"]), "{path:?}");
        }
        assert!(holds(&word, &["article 12", "x y"]));
    }

    #[test]
    fn ascii_text_and_terms_skip_the_accent_fold() {
        let ascii = terms(&["Quarterly Report", "q3"], true);
        PLAIN_FOLDS.set(0);
        let mut seen = ascii.seen();
        assert_eq!(seen.needles, ascii.terms);
        assert_eq!(seen.keep, "quarterly report".len() - 1);
        assert!(!seen.feed("The QUARTERLY "));
        assert!(seen.feed("report for Q3"));
        assert_eq!(PLAIN_FOLDS.get(), 0);
        assert!(!ascii.seen().feed("\u{f6}"));
        assert_eq!(PLAIN_FOLDS.get(), 1);
        let accented = terms(&["\u{d6}zet"], true);
        let seen = accented.seen();
        assert_eq!(seen.needles, [("ozet".to_owned(), None::<String>)]);
        assert_eq!(seen.keep, 3);
    }

    #[test]
    fn a_single_spaced_ascii_piece_is_copied_in_one_piece() {
        let words = terms(&["zyqlast phrase"], true);
        let mut seen = words.seen();
        let piece = "lorem ipsum ".repeat(1 << 16);
        PLAIN_FOLDS.set(0);
        SPACED_COPIES.set(0);
        assert!(!seen.feed(&piece));
        assert_eq!(SPACED_COPIES.get(), 1);
        assert!(seen.feed(" zyqlast\n\tphrase"));
        assert_eq!(SPACED_COPIES.get(), 3);
        assert_eq!(PLAIN_FOLDS.get(), 0);
        let mut one = String::new();
        spaced(" a  b\u{a0}c d\u{3000}", &mut false, &mut one);
        assert_eq!(one, " a b c d ");
        let mut carried = String::new();
        spaced(" a b ", &mut true, &mut carried);
        assert_eq!(carried, "a b ");
    }

    #[test]
    fn a_whitespace_run_at_any_lane_offset_is_one_space() {
        let collapse = |text: &str, space: &mut bool| {
            let mut out = String::new();
            for c in text.chars() {
                if !c.is_whitespace() {
                    out.push(c);
                } else if !*space {
                    out.push(' ');
                }
                *space = c.is_whitespace();
            }
            out
        };
        let base = "Lorem ipsum ".repeat(9);
        for gap in [
            "  ",
            " \t",
            " \u{a0}",
            "\u{a0}",
            "\x0b",
            " ",
            "\u{3000} \n",
            "\u{e9}",
        ] {
            for at in 0..base.len() {
                let text = format!("{}{gap}{}", &base[..at], &base[at..]);
                for carried in [false, true] {
                    let mut want_space = carried;
                    let want = collapse(&text, &mut want_space);
                    for cut in (0..=text.len()).filter(|&c| text.is_char_boundary(c)) {
                        let (mut space, mut got) = (carried, String::new());
                        spaced(&text[..cut], &mut space, &mut got);
                        spaced(&text[cut..], &mut space, &mut got);
                        assert_eq!(got, want, "{text:?} cut at {cut}, carried {carried}");
                        assert_eq!(space, want_space, "{text:?} cut at {cut}");
                    }
                }
            }
        }
    }
}
