use std::borrow::Cow;
use std::cell::LazyCell;
use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString, c_char, c_void};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use rayon::prelude::*;

use crate::EngineKind;
use crate::crawl::Attrs;
use crate::engine::{Settings, now_secs};
use crate::fsevents::{open, sym};
use crate::index::Index;
use crate::live::{Added, Folder, Found, Live, Seen, as_path};
use crate::rank::{
    Name, PLAIN_COST, Place, Places, TYPO_LAST, dotless, is_delim, path_fit, pattern_reading,
    reading, tweaks,
};
use crate::unit::{self, Unit};

const MAX_WORDS: usize = 8;
const TYPO_MIN_LEN: usize = 5;
const TYPO2_MIN_LEN: usize = 8;
const WELL_TOP: usize = 8;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Mode {
    Together,
    Fuzzy,
    Exact,
    Prefix,
    Suffix,
    Whole,
}

#[derive(Clone, PartialEq, Debug)]
pub(crate) struct Word {
    pub chars: Vec<char>,
    pub ascii: Option<Vec<u8>>,
}

#[derive(Clone, PartialEq, Debug)]
pub(crate) struct Token {
    pub word: Word,
    pub other: Option<Word>,
    pub plain: Option<Word>,
    pub mode: Mode,
    pub negate: bool,
    pub edits: u32,
    pub deep: bool,
    pub under: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct NameRe {
    pub re: regex::bytes::Regex,
    pub plain: Option<regex::bytes::Regex>,
    pub exact: bool,
    pub negate: bool,
    pub glob: bool,
}

impl PartialEq for NameRe {
    fn eq(&self, o: &NameRe) -> bool {
        self.re.as_str() == o.re.as_str() && self.negate == o.negate
    }
}

#[derive(Clone, PartialEq, Debug)]
pub(crate) struct Query {
    pub tokens: Vec<Token>,
    pub kind: Option<EngineKind>,
    pub apps: bool,
    pub exts: Vec<Vec<u8>>,
    pub plain_exts: Vec<Vec<u8>>,
    pub type_exts: Vec<Vec<u8>>,
    pub not_exts: Vec<Vec<u8>>,
    pub name_re: Vec<NameRe>,
    pub scope: Option<PathBuf>,
    pub press_files: bool,
    pub size: (u64, u64),
    pub mtime: (i64, i64),
    pub hide: bool,
    pub never: bool,
    pub unnormalized: bool,
}

pub(crate) type Term = (String, Option<String>);

const ARCHIVES: &[&str] = &[
    "7z", "bz2", "dmg", "gz", "iso", "lz4", "pkg", "rar", "tar", "tgz", "xip", "xz", "zip", "zst",
];
const SOUNDS: &[&str] = &[
    "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4r", "mid", "midi", "mp3", "ogg", "opus",
    "wav",
];
const SOURCES: &[&str] = &[
    "bash", "c", "cc", "cjs", "clj", "cpp", "cs", "css", "dart", "erl", "ex", "exs", "fish",
    "glsl", "go", "graphql", "h", "hpp", "hs", "html", "java", "jl", "js", "json", "jsx", "kt",
    "lua", "m", "metal", "mjs", "ml", "mm", "nim", "nix", "php", "proto", "py", "r", "rb", "rs",
    "scss", "sh", "sql", "svelte", "swift", "toml", "ts", "tsx", "vue", "wgsl", "xml", "yaml",
    "yml", "zig", "zsh",
];
const DOCUMENTS: &[&str] = &[
    "csv", "doc", "docx", "epub", "key", "md", "numbers", "odt", "pages", "pdf", "ppt", "pptx",
    "rtf", "tex", "txt", "xls", "xlsx",
];
const FONTS: &[&str] = &["dfont", "otf", "ttc", "ttf", "woff", "woff2"];
const IMAGES: &[&str] = &[
    "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg",
    "jxl", "nef", "png", "psd", "raw", "svg", "tif", "tiff", "webp",
];
const VIDEOS: &[&str] = &[
    "3gp", "avi", "flv", "hevc", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv",
];

fn type_extensions(name: &str) -> Option<&'static [&'static str]> {
    Some(match name {
        "archive" => ARCHIVES,
        "audio" => SOUNDS,
        "code" => SOURCES,
        "doc" => DOCUMENTS,
        "font" => FONTS,
        "image" => IMAGES,
        "video" => VIDEOS,
        _ => return None,
    })
}

impl Query {
    fn filtered(&self) -> bool {
        self.kind.is_some()
            || !self.exts.is_empty()
            || !self.type_exts.is_empty()
            || !self.not_exts.is_empty()
            || !self.name_re.is_empty()
            || self.size != (0, u64::MAX)
            || self.mtime != (i64::MIN, i64::MAX)
            || self.hide
    }

    pub(crate) fn parse(text: &str, home: &str) -> Query {
        let mut q = Query::parse_form(text, home);
        if text.is_ascii() {
            return q;
        }
        for t in &mut q.tokens {
            let w: String = t.word.chars.iter().collect();
            let w = normalize_api()
                .and_then(|f| normalized(f, &w, NFC))
                .unwrap_or(w);
            t.plain = reading(w.as_bytes())
                .filter(|p| !p.is_empty())
                .map(|p| Word::new(&p));
        }
        match other_form(text) {
            Some(Some(o)) => {
                let oq = Query::parse_form(&o, home);
                if oq.tokens.len() == q.tokens.len() {
                    for (t, o) in q.tokens.iter_mut().zip(oq.tokens) {
                        t.other = (o.word != t.word).then_some(o.word);
                    }
                }
            }
            Some(None) => {}
            None => q.unnormalized = !CF_FAULTED.swap(true, Ordering::Relaxed),
        }
        q
    }

    pub(crate) fn only_files(&mut self) {
        if self.kind.is_none() {
            self.kind = Some(EngineKind::File);
            self.press_files = true;
        }
    }

    pub(crate) fn loosened(&self) -> Query {
        let mut q = self.clone();
        for t in q.tokens.iter_mut().filter(|t| t.mode == Mode::Together) {
            let len = t.word.chars.len();
            t.mode = Mode::Fuzzy;
            t.edits = u32::from(len >= TYPO_MIN_LEN) + u32::from(len >= TYPO2_MIN_LEN);
        }
        q
    }

    pub(crate) fn deepen(&self) -> Query {
        let mut q = self.clone();
        for t in q.tokens.iter_mut().filter(|t| t.edits > 0) {
            t.deep = true;
        }
        q
    }

    fn parse_form(text: &str, home: &str) -> Query {
        let mut q = Query {
            tokens: Vec::new(),
            kind: None,
            apps: false,
            exts: Vec::new(),
            plain_exts: Vec::new(),
            type_exts: Vec::new(),
            not_exts: Vec::new(),
            name_re: Vec::new(),
            scope: None,
            press_files: false,
            size: (0, u64::MAX),
            mtime: (i64::MIN, i64::MAX),
            hide: false,
            never: false,
            unnormalized: false,
        };
        for (word, quoted) in split_quoted(text) {
            let word = if let Some(r) = word.strip_prefix("~/") {
                format!("{home}/{r}")
            } else {
                word
            };
            if let Some((k, v)) = word.split_once(':')
                && q.filter(k, v, home)
            {
                continue;
            }
            let (negate, w) = word
                .strip_prefix('!')
                .map_or((false, word.as_str()), |w| (true, w));
            if let Some(exts) = glob_exts(w) {
                q.push_exts(exts, negate);
                continue;
            }
            let mut under = false;
            let mut pieces = word.split('/').filter(|p| !p.is_empty()).peekable();
            while let Some(piece) = pieces.next() {
                let (negate, p) = piece
                    .strip_prefix('!')
                    .map_or((false, piece), |p| (true, p));
                if pieces.peek().is_none()
                    && !quoted
                    && !p.starts_with('\'')
                    && p.contains(['*', '?'])
                {
                    let p = p.strip_prefix('^').unwrap_or(p);
                    let p = p.strip_suffix('$').unwrap_or(p);
                    if let Some(exts) = glob_exts(p) {
                        q.push_exts(exts, negate);
                    } else {
                        q.push_name_re(p, negate, true, |v| glob_regex(v, false));
                    }
                    under = false;
                    continue;
                }
                let pushed = q.push_token(piece);
                if let Some(t) = q.tokens.last_mut().filter(|t| under && pushed && !t.negate) {
                    t.under = true;
                }
                under = true;
            }
        }
        q
    }

    fn push_exts(&mut self, mut exts: Vec<Vec<u8>>, negate: bool) {
        let other: Vec<Vec<u8>> = (exts.iter())
            .filter(|e| !e.is_ascii())
            .filter_map(|e| other_form(std::str::from_utf8(e).ok()?).flatten())
            .map(|o| fold(&o).into_bytes())
            .collect();
        exts.extend(other);
        let plain: Vec<Vec<u8>> = (exts.iter())
            .filter_map(|e| reading(e).map(|r| fold(&r).into_bytes()))
            .collect();
        if negate {
            self.not_exts.extend(exts.into_iter().chain(plain));
        } else {
            self.exts.extend(exts);
            self.plain_exts.extend(plain);
        }
    }

    fn push_token(&mut self, w: &str) -> bool {
        let negate = w.starts_with('!');
        let t = w.strip_prefix('!').unwrap_or(w);
        let (word, mode) = if let Some(r) = t.strip_prefix('\'') {
            (r, Mode::Exact)
        } else if let Some(r) = t.strip_prefix('^') {
            match r.strip_suffix('$') {
                Some(whole) => (whole, Mode::Whole),
                None => (r, Mode::Prefix),
            }
        } else if let Some(r) = t.strip_suffix('$') {
            (r, Mode::Suffix)
        } else if negate {
            (t, Mode::Exact)
        } else {
            (t, Mode::Together)
        };
        self.push_word(word, mode, negate)
    }

    fn push_word(&mut self, text: &str, mode: Mode, negate: bool) -> bool {
        if text.is_empty() {
            return false;
        }
        if !negate
            && self.tokens.iter().filter(|t| !t.negate).count() >= MAX_WORDS
            && let Some(first) = self.tokens.iter().position(|t| !t.negate)
        {
            self.tokens.remove(first);
            if let Some(next) = self.tokens[first..].iter_mut().find(|t| !t.negate) {
                next.under = false;
            }
        }
        self.tokens.push(Token {
            word: Word::new(text),
            other: None,
            plain: None,
            mode,
            negate,
            edits: 0,
            deep: false,
            under: false,
        });
        true
    }

    fn filter(&mut self, k: &str, v: &str, home: &str) -> bool {
        let pattern = matches!(k, "re" | "glob" | "begins" | "ends" | "whole");
        let known = pattern
            || matches!(
                k,
                "ext" | "type" | "kind" | "in" | "size" | "mtime" | "modified" | "hidden"
            );
        let empty = if pattern || k == "in" {
            v.is_empty()
        } else {
            v.trim_matches(|c| "<>=.,;".contains(c)).is_empty()
        };
        if !known || empty {
            return known;
        }
        match k {
            "begins" | "ends" | "whole" => {
                let mode = match k {
                    "begins" => Mode::Prefix,
                    "ends" => Mode::Suffix,
                    _ => Mode::Whole,
                };
                self.push_word(v, mode, false);
            }
            "ext" => self.push_exts(
                v.split([',', ';'])
                    .map(|e| fold(e.trim_start_matches('.')).into_bytes())
                    .filter(|e| !e.is_empty())
                    .collect(),
                false,
            ),
            "type" => {
                for t in v.split([',', ';']).filter(|t| !t.is_empty()) {
                    if t == "app" {
                        self.kind = Some(EngineKind::Folder);
                        self.apps = true;
                        self.type_exts.push(b"app".to_vec());
                    } else if let Some(exts) = type_extensions(t) {
                        self.type_exts
                            .extend(exts.iter().map(|e| e.as_bytes().to_vec()));
                    } else {
                        self.never = true;
                    }
                }
            }
            "kind" => match v {
                "file" | "files" | "f" => self.kind = Some(EngineKind::File),
                "dir" | "folder" | "folders" | "d" => self.kind = Some(EngineKind::Folder),
                "link" | "links" | "symlink" | "l" => self.kind = Some(EngineKind::Link),
                _ => self.never = true,
            },
            "in" => {
                let p = v
                    .strip_prefix('~')
                    .map_or_else(|| v.to_owned(), |r| format!("{home}{r}"));
                self.scope = Some(PathBuf::from(p));
            }
            "size" => {
                let sizes = match bare(v) {
                    Some(unit) => parse_size(v).map(|x| (x, if unit { u64::MAX } else { x })),
                    None => range(v, parse_size),
                };
                match sizes {
                    Some(r) => self.size = r,
                    None => self.never = true,
                }
            }
            "mtime" | "modified" => {
                let ages = if bare(v).is_some() {
                    parse_age(v).map(|x| (0, x))
                } else {
                    range(v, parse_age)
                };
                match ages {
                    Some((lo, hi)) => {
                        let now = now_secs() as i64;
                        let ago = |a: u64| now.saturating_sub(i64::try_from(a).unwrap_or(i64::MAX));
                        let oldest = if hi == u64::MAX { i64::MIN } else { ago(hi) };
                        self.mtime = (oldest, ago(lo));
                    }
                    None => self.never = true,
                }
            }
            "re" => self.push_name_re(v, false, false, |v| format!("(?i){v}")),
            "glob" => self.push_name_re(v, false, true, |v| glob_regex(v, true)),
            "hidden" => match v {
                "no" => self.hide = true,
                _ => self.never = true,
            },
            _ => {}
        }
        true
    }

    fn push_name_re(
        &mut self,
        v: &str,
        negate: bool,
        glob: bool,
        pattern: impl FnOnce(&str) -> String,
    ) {
        let v = (!v.is_ascii())
            .then(|| normalize_api().and_then(|f| normalized(f, v, NFC)))
            .flatten()
            .unwrap_or_else(|| v.to_owned());
        let re = pattern(&v);
        let (plain, exact) = plain_pattern(&re);
        match regex::bytes::Regex::new(&re) {
            Ok(re) => self.name_re.push(NameRe {
                re,
                plain: plain.and_then(|p| regex::bytes::Regex::new(&p).ok()),
                exact,
                negate,
                glob,
            }),
            Err(_) => self.never = true,
        }
    }
}

impl Word {
    pub(crate) fn new(text: &str) -> Word {
        let chars: Vec<char> = text.chars().flat_map(fold_char).collect();
        let ascii = chars
            .iter()
            .all(char::is_ascii)
            .then(|| chars.iter().map(|&c| c as u8).collect());
        Word { chars, ascii }
    }
}

pub(crate) fn fold_char(c: char) -> std::char::ToLowercase {
    match c {
        '\u{130}' | '\u{131}' => 'i',
        '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap(),
        '\u{3000}' => ' ',
        _ => c,
    }
    .to_lowercase()
}

pub(crate) fn fold(s: &str) -> String {
    if s.is_ascii() {
        s.to_ascii_lowercase()
    } else {
        s.chars().flat_map(fold_char).collect()
    }
}

pub(crate) fn term(v: &str) -> Term {
    let other = if v.is_ascii() {
        None
    } else {
        other_form(v).flatten().map(|o| fold(&o))
    };
    (fold(v), other)
}

fn glob_exts(w: &str) -> Option<Vec<Vec<u8>>> {
    let rest = w.strip_prefix("*.")?;
    let list = rest
        .strip_prefix('{')
        .and_then(|r| r.strip_suffix('}'))
        .unwrap_or(rest);
    list.split(',')
        .map(|e| {
            (!e.is_empty() && !e.contains(['*', '?', '[', ']', '/', '.', '{', '}']))
                .then(|| fold(e).into_bytes())
        })
        .collect()
}

fn glob_regex(s: &str, classes: bool) -> String {
    let mut re = String::from("(?is)^");
    let mut open = false;
    let mut cs = s.char_indices();
    while let Some((i, c)) = cs.next() {
        let close = (classes && c == '[')
            .then(|| s[i + 1..].find(']'))
            .flatten();
        let literal = !matches!(c, '*' | '?');
        if literal != open {
            re.push(if literal { '(' } else { ')' });
            open = literal;
        }
        match (c, close) {
            ('*', _) => re.push_str(".*"),
            ('?', _) => re.push('.'),
            (_, Some(j)) => {
                let class = s[i + 1..i + 1 + j].replace(['\\', '[', '&', '~'], "");
                re.push('[');
                if let Some(c) = class.strip_prefix('!') {
                    re.push('^');
                    re.push_str(c);
                } else {
                    re.push_str(&class);
                }
                re.push(']');
                cs.by_ref()
                    .take_while(|&(k, _)| k < i + 1 + j)
                    .for_each(drop);
            }
            _ => re.push_str(&regex::escape(c.encode_utf8(&mut [0; 4]))),
        }
    }
    if open {
        re.push(')');
    }
    re.push('$');
    re
}

fn plain_pattern(re: &str) -> (Option<String>, bool) {
    let free = |p: &str| regex::bytes::Regex::new(p).is_ok_and(|r| r.is_match(b"\0"));
    let keep = |out: &mut String, typed: &str, folded: usize| {
        if out[folded..] != *typed && free(&out[folded..]) && !free(typed) {
            out.truncate(folded);
            out.push_str(typed);
        }
    };
    let mut out = String::with_capacity(re.len());
    let (mut escaped, mut depth, mut typed, mut folded) = (false, 0, 0, 0);
    for (i, c) in re.char_indices() {
        if escaped {
            if matches!(c, 'p' | 'P') {
                return (None, true);
            }
            escaped = false;
        } else if c == '[' {
            return (None, true);
        } else if c == '\\' {
            escaped = true;
        } else if c == '(' {
            depth += 1;
        } else if c == ')' {
            depth -= 1;
        } else if c == '|' && depth == 0 {
            keep(&mut out, &re[typed..i], folded);
            (typed, folded) = (i + 1, out.len() + 1);
        } else if let Some(p) = (!c.is_ascii())
            .then(|| pattern_reading(c.encode_utf8(&mut [0; 4]).as_bytes()))
            .flatten()
        {
            match p.chars().count() {
                1 => out.push_str(&regex::escape(&p)),
                _ => out.push_str(&format!("(?:{})", regex::escape(&p))),
            }
            continue;
        }
        out.push(c);
    }
    keep(&mut out, &re[typed..], folded);
    ((out != re).then_some(out), false)
}

#[cfg(test)]
pub(crate) fn split_words(s: &str) -> Vec<String> {
    split_quoted(s).into_iter().map(|(w, _)| w).collect()
}

fn split_quoted(s: &str) -> Vec<(String, bool)> {
    let (mut out, mut cur, mut quoted, mut had) = (Vec::new(), String::new(), false, false);
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.next_if_eq(&'"').is_some() => cur.push('"'),
            '"' => (quoted, had) = (!quoted, true),
            c if c.is_whitespace() && !quoted => {
                if !cur.is_empty() {
                    out.push((std::mem::take(&mut cur), had));
                }
                had = false;
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push((cur, had));
    }
    out
}

fn bare(v: &str) -> Option<bool> {
    (!v.starts_with(['<', '>']) && !v.contains(".."))
        .then(|| v.contains(|c: char| !(c.is_ascii_digit() || c == '.')))
}

fn range(v: &str, parse: fn(&str) -> Option<u64>) -> Option<(u64, u64)> {
    if let Some(r) = v.strip_prefix(">=").or(v.strip_prefix('>')) {
        return Some((parse(r)?, u64::MAX));
    }
    if let Some(r) = v.strip_prefix("<=").or(v.strip_prefix('<')) {
        return Some((0, parse(r)?));
    }
    let (a, b) = v.split_once("..")?;
    let end = |s: &str, open| if s.is_empty() { Some(open) } else { parse(s) };
    let r = (end(a, 0)?, end(b, u64::MAX)?);
    (r.0 <= r.1).then_some(r)
}

fn split_unit(s: &str) -> Option<(f64, String)> {
    let i = s
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(s.len());
    Some((s[..i].parse().ok()?, s[i..].to_ascii_lowercase()))
}

fn parse_size(s: &str) -> Option<u64> {
    let (n, u) = split_unit(s)?;
    let m = match u.as_str() {
        "" | "b" => 1.0,
        "k" | "kb" => 1e3,
        "m" | "mb" => 1e6,
        "g" | "gb" => 1e9,
        "t" | "tb" => 1e12,
        _ => return None,
    };
    Some((n * m) as u64)
}

fn parse_age(s: &str) -> Option<u64> {
    let (n, u) = split_unit(s)?;
    let m = match u.as_str() {
        "s" => 1.0,
        "m" | "min" => 60.0,
        "h" => 3600.0,
        "" | "d" => 86400.0,
        "w" => 604_800.0,
        "mo" => 2_592_000.0,
        "y" => 31_536_000.0,
        _ => return None,
    };
    Some((n * m) as u64)
}

static CF_FAULTED: AtomicBool = AtomicBool::new(false);

type Normalize = (
    unsafe extern "C" fn(*const c_void, isize) -> *mut c_void,
    unsafe extern "C" fn(*mut c_void, *const c_char, u32),
    unsafe extern "C" fn(*mut c_void, isize),
    unsafe extern "C" fn(*const c_void, *mut c_char, isize, u32) -> u8,
    unsafe extern "C" fn(*const c_void),
);

fn normalize_api() -> Option<&'static Normalize> {
    static API: OnceLock<Option<Normalize>> = OnceLock::new();
    API.get_or_init(|| {
        let cf =
            open(c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation").ok()?;
        unsafe {
            Some((
                sym(cf, c"CFStringCreateMutable").ok()?,
                sym(cf, c"CFStringAppendCString").ok()?,
                sym(cf, c"CFStringNormalize").ok()?,
                sym(cf, c"CFStringGetCString").ok()?,
                sym(cf, c"CFRelease").ok()?,
            ))
        }
    })
    .as_ref()
}

fn other_form(s: &str) -> Option<Option<String>> {
    let f = normalize_api()?;
    let composed = normalized(f, s, NFC);
    let o = match composed {
        Some(c) if c != s => Some(c),
        _ => normalized(f, s, NFD),
    };
    Some(o.filter(|o| o != s))
}

fn composed(name: &[u8]) -> Option<String> {
    if name.is_ascii() {
        return None;
    }
    let s = std::str::from_utf8(name).ok()?;
    s.chars()
        .any(|c| {
            matches!(c, '\u{300}'..='\u{36f}' | '\u{653}'..='\u{655}' | '\u{1100}'..='\u{11ff}'
                | '\u{3099}'..='\u{309a}')
        })
        .then(|| normalized(normalize_api()?, s, NFC))
        .flatten()
}

pub(crate) fn nfd(s: &str) -> Option<String> {
    normalized(normalize_api()?, s, NFD)
}

const NFD: isize = 0;
const NFC: isize = 2;

fn normalized(f: &Normalize, s: &str, form: isize) -> Option<String> {
    const UTF8: u32 = 0x0800_0100;
    let c = CString::new(s).ok()?;
    let mut out = vec![0u8; 4 * s.len() + 16];
    unsafe {
        let m = (f.0)(std::ptr::null(), 0);
        if m.is_null() {
            return None;
        }
        (f.1)(m, c.as_ptr(), UTF8);
        (f.2)(m, form);
        let ok = (f.3)(m, out.as_mut_ptr().cast(), out.len() as isize, UTF8) != 0;
        (f.4)(m);
        let n = out.iter().position(|&b| b == 0)?;
        ok.then(|| String::from_utf8(out[..n].to_vec()).ok())
            .flatten()
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) struct Hit {
    pub score: i32,
    pub file: bool,
}

pub(crate) type Scanned = Vec<(Found, Vec<Hit>)>;

pub(crate) fn search(
    q: &mut Query,
    settings: &Settings,
    units: &[Arc<Unit>],
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Scanned> {
    let typos = settings.typos.load(Ordering::Relaxed);
    retry(q, typos, |q| scan_units(q, settings, units, cancelled))
}

fn retry(
    q: &mut Query,
    typos: bool,
    mut pass: impl FnMut(&Query) -> Option<Scanned>,
) -> Option<Scanned> {
    let nothing = |scanned: &Scanned| scanned.iter().all(|(_, hits)| hits.is_empty());
    let mut first = pass(q)?;
    if typos && nothing(&first) && q.tokens.iter().any(|t| t.mode == Mode::Together) {
        let listed = q.press_files && {
            let mut names = q.clone();
            names.kind = None;
            !nothing(&pass(&names)?)
        };
        if !listed {
            *q = q.loosened();
            first = pass(q)?;
        }
    }
    if q.tokens.iter().any(|t| t.edits > 0 && !t.deep) && !well_found(q, &first) {
        return pass(&q.deepen());
    }
    Some(first)
}

fn well_found(q: &Query, scanned: &Scanned) -> bool {
    let words: Vec<&Token> = q.tokens.iter().filter(|t| t.edits > 0).collect();
    let mut top: Vec<(Reverse<i32>, bool, usize, usize)> = Vec::with_capacity(WELL_TOP + 1);
    for (u, (_, hits)) in scanned.iter().enumerate() {
        for (k, h) in hits.iter().enumerate() {
            let key = (Reverse(h.score), !h.file, u, k);
            if top.len() == WELL_TOP && top[WELL_TOP - 1] <= key {
                continue;
            }
            top.insert(top.partition_point(|t| *t < key), key);
            top.truncate(WELL_TOP);
        }
    }
    let mut found = vec![false; words.len()];
    for (_, _, u, k) in top {
        let Some(hit) = scanned[u].0.row(k) else {
            continue;
        };
        let parts: Vec<Name> = hit
            .folder
            .split('/')
            .chain([hit.name.as_str()])
            .filter(|c| !c.is_empty())
            .map(|c| Name::new(c.as_bytes()))
            .collect();
        for (f, t) in found.iter_mut().zip(&words) {
            *f = *f || parts.iter().any(|c| c.well(t));
        }
    }
    found.iter().all(|&f| f)
}

pub(crate) enum Shown<'a> {
    Live(&'a Live),
    Partial(crate::unit::partial::Snapshot),
}

pub(crate) fn each_unit(
    q: &Query,
    settings: &Settings,
    units: &[Arc<Unit>],
    mut each: impl FnMut(&Unit, Option<&Path>, Shown<'_>) -> Option<()>,
) -> Option<bool> {
    let skip = settings.exclusions().joined(units);
    let Some(within) = within(q, &skip) else {
        return Some(false);
    };
    let roots: Vec<&Path> = units.iter().map(|u| u.root.as_path()).collect();
    let reach = reach(within.as_deref(), &roots);
    let shown: Vec<_> = units
        .iter()
        .enumerate()
        .map(|(i, u)| {
            let scope = reach[i]?;
            let partial = u.partial();
            (partial.is_some() || u.read(|_| ()).is_some()).then_some((scope, partial))
        })
        .collect();
    for (u, shown) in units.iter().zip(shown) {
        let Some((scope, partial)) = shown else {
            continue;
        };
        if u.stopped() || u.discarded.load(Ordering::Relaxed) {
            continue;
        }
        let live = u
            .live
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(live) = live.as_ref() {
            each(u, scope, Shown::Live(live))?;
        } else if let Some(mut partial) = partial {
            drop(live);
            partial.excluded = units
                .iter()
                .filter(|nested| nested.root != u.root && nested.root.starts_with(&u.root))
                .map(|nested| nested.root.clone())
                .collect();
            each(u, scope, Shown::Partial(partial))?;
        }
    }
    Some(true)
}

fn scan_units(
    q: &Query,
    settings: &Settings,
    units: &[Arc<Unit>],
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Scanned> {
    let mut out = Vec::new();
    let words = Words::new(q);
    let places = Places::new(&settings.home);
    let reached = each_unit(q, settings, units, |u, scope, shown| {
        let unit = Scan {
            q,
            words: &words,
            places: &places,
            boot: u.id.is_none(),
            within: scope,
            members: None,
        };
        out.push(match shown {
            Shown::Live(live) => {
                let (mut found, hits) = unit.scan(live, cancelled)?;
                found.seen = Some(Seen {
                    live: live.id(),
                    at: live.touched_at(),
                });
                (found, hits)
            }
            Shown::Partial(partial) => unit.partial(partial, cancelled)?,
        });
        Some(())
    })?;
    (!reached || !cancelled()).then_some(out)
}

pub(crate) struct Held {
    pub(crate) root: PathBuf,
    pub(crate) boot: bool,
    pub(crate) live: Live,
    pub(crate) partial: Option<crate::unit::partial::Snapshot>,
}

#[derive(Default)]
pub(crate) struct Members {
    pub(crate) base: Vec<u64>,
    pub(crate) over: HashSet<Vec<u8>>,
}

impl Members {
    pub(crate) fn add(&mut self, entry: u32) {
        let i = entry as usize;
        if self.base.len() <= i >> 6 {
            self.base.resize((i >> 6) + 1, 0);
        }
        self.base[i >> 6] |= 1 << (i & 63);
    }

    fn has(&self, entry: usize) -> bool {
        self.base
            .get(entry >> 6)
            .is_some_and(|w| w & (1 << (entry & 63)) != 0)
    }
}

pub(crate) fn walked(
    q: &mut Query,
    settings: &Settings,
    live: &Live,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Scanned> {
    walked_lives(q, settings, &[live], cancelled)
}

pub(crate) fn walked_lives(
    q: &mut Query,
    settings: &Settings,
    lives: &[&Live],
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Scanned> {
    retry(q, settings.typos.load(Ordering::Relaxed), |q| {
        let words = Words::new(q);
        let places = Places::new(&settings.home);
        let mut out = Vec::with_capacity(lives.len());
        for live in lives {
            let unit = Scan {
                q,
                words: &words,
                places: &places,
                boot: live.base.root() == settings.root,
                within: Some(live.base.root()),
                members: None,
            };
            out.push(unit.scan(live, cancelled)?);
        }
        (!cancelled()).then_some(out)
    })
}

pub(crate) struct Walk {
    pub(crate) folders: Vec<(PathBuf, Vec<PathBuf>)>,
    pub(crate) owners: Vec<(PathBuf, PathBuf)>,
    pub(crate) everything: bool,
    pub(crate) indexed: Vec<Arc<Unit>>,
}

pub(crate) fn walk(
    q: &Query,
    skip: &[PathBuf],
    units: &[Arc<Unit>],
    mounted: &mut impl FnMut(&Path) -> bool,
) -> Option<Walk> {
    let roots: Vec<PathBuf> = units.iter().map(|u| u.root.clone()).collect();
    if let Some(folder) = unindexed(q, skip, &roots, mounted) {
        return Some(Walk {
            folders: vec![(folder, Vec::new())],
            owners: Vec::new(),
            everything: true,
            indexed: Vec::new(),
        });
    }
    let within = within(q, skip)?;
    let paths: Vec<&Path> = roots.iter().map(PathBuf::as_path).collect();
    let (mut folders, mut owners, mut indexed) = (Vec::new(), Vec::new(), Vec::new());
    for (u, scope) in units.iter().zip(reach(within.as_deref(), &paths)) {
        let Some(scope) = scope else {
            continue;
        };
        if u.stopped() || u.discarded.load(Ordering::Relaxed) {
            continue;
        }
        if u.read(|_| ()).is_some() {
            indexed.push(u.clone());
            continue;
        }
        if u.status().0 == crate::EnginePhase::Failed {
            continue;
        }
        let nested = (units.iter())
            .filter(|n| n.root != u.root && n.root.starts_with(&u.root))
            .map(|n| n.root.clone());
        let skip = skip.iter().cloned().chain(nested).collect();
        let folder = scope.unwrap_or(&u.root).to_path_buf();
        owners.push((folder.clone(), u.root.clone()));
        folders.push((folder, skip));
    }
    (!folders.is_empty()).then_some(Walk {
        folders,
        owners,
        everything: false,
        indexed,
    })
}

pub(crate) fn unindexed(
    q: &Query,
    skip: &[PathBuf],
    roots: &[PathBuf],
    mounted: &mut impl FnMut(&Path) -> bool,
) -> Option<PathBuf> {
    let real = within(q, &[])??;
    let excluded = within(q, skip).is_none();
    let held = local(&real)
        && owner(Some(&real), roots.iter().map(PathBuf::as_path))
            .is_some_and(|i| unit::owns(&roots[i], &[], &real, mounted));
    (excluded || !held).then_some(real)
}

pub(crate) fn narrow(
    q: &mut Query,
    settings: &Settings,
    held: &[Held],
    members: &[Members],
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<Scanned> {
    retry(q, settings.typos.load(Ordering::Relaxed), |q| {
        let mut out = Vec::new();
        let Some(within) = within(q, &[]) else {
            return Some(out);
        };
        let roots: Vec<&Path> = held.iter().map(|h| h.root.as_path()).collect();
        let reach = reach(within.as_deref(), &roots);
        let words = Words::new(q);
        let places = Places::new(&settings.home);
        for ((h, m), scope) in held.iter().zip(members).zip(reach) {
            let Some(scope) = scope else {
                continue;
            };
            let unit = Scan {
                q,
                words: &words,
                places: &places,
                boot: h.boot,
                within: scope,
                members: Some(m),
            };
            out.push(match &h.partial {
                Some(partial) => unit.partial(partial.clone(), cancelled)?,
                None => unit.scan(&h.live, cancelled)?,
            });
        }
        (!cancelled()).then_some(out)
    })
}

fn within(q: &Query, skip: &[PathBuf]) -> Option<Option<PathBuf>> {
    let within = match &q.scope {
        None => None,
        Some(p) => Some(resolve(p, skip)?),
    };
    (!q.never).then_some(within)
}

fn reach<'a>(within: Option<&'a Path>, roots: &[&Path]) -> Vec<Option<Option<&'a Path>>> {
    let Some(real) = within else {
        return vec![Some(None); roots.len()];
    };
    let owner = owner(within, roots.iter().copied());
    let named = roots.contains(&real);
    (0..roots.len())
        .map(|i| {
            if owner == Some(i) {
                Some(Some(real))
            } else {
                (!named && roots[i].starts_with(real)).then_some(None)
            }
        })
        .collect()
}

fn owner<'a>(within: Option<&Path>, roots: impl Iterator<Item = &'a Path>) -> Option<usize> {
    let real = within?;
    roots
        .enumerate()
        .filter(|(_, root)| real.starts_with(root))
        .max_by_key(|(_, root)| root.components().count())
        .map(|(i, _)| i)
}

fn resolve(p: &Path, skip: &[PathBuf]) -> Option<PathBuf> {
    if !p.is_absolute() {
        return None;
    }
    let mut lexical = PathBuf::from("/");
    for c in p.components() {
        match c {
            Component::Normal(n) => lexical.push(n),
            Component::ParentDir => {
                lexical.pop();
            }
            _ => {}
        }
    }
    let closed = |q: &Path| skip.iter().any(|g| q.starts_with(g));
    if closed(&lexical) {
        return None;
    }
    if !local(&lexical) {
        return Some(lexical);
    }
    let real = fs::canonicalize(&lexical).ok()?;
    (!closed(&real)).then_some(real)
}

#[cfg(test)]
thread_local! {
    static WALKED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn entries_walked() -> usize {
    WALKED.with(|w| w.get())
}

#[cfg(test)]
thread_local! {
    static REMOTE: std::cell::RefCell<Vec<PathBuf>> = const { std::cell::RefCell::new(Vec::new()) };
}

fn local(p: &Path) -> bool {
    #[cfg(test)]
    if REMOTE.with_borrow(|r| r.iter().any(|m| p.starts_with(m))) {
        return false;
    }
    let count = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    let mut mounts = vec![unsafe { std::mem::zeroed::<libc::statfs>() }; count.max(0) as usize + 4];
    let size = std::mem::size_of_val(mounts.as_slice()) as libc::c_int;
    let filled = unsafe { libc::getfsstat(mounts.as_mut_ptr(), size, libc::MNT_NOWAIT) };
    mounts.truncate(filled.max(0) as usize);
    let fold = |s: &str| PathBuf::from(s.to_lowercase());
    let folded = fold(&p.to_string_lossy());
    mounts
        .iter()
        .map(|m| (unsafe { CStr::from_ptr(m.f_mntonname.as_ptr()) }, m.f_flags))
        .filter(|(on, _)| folded.starts_with(fold(&on.to_string_lossy())))
        .max_by_key(|(on, _)| on.to_bytes().len())
        .is_none_or(|(_, flags)| flags & libc::MNT_LOCAL as u32 != 0)
}

struct Words<'q> {
    pos: Vec<&'q Token>,
    neg: Vec<&'q Token>,
    all: u8,
    under: u8,
    leaf: u8,
    joined: Vec<char>,
    plain_joined: Vec<char>,
    now: i64,
}

impl<'q> Words<'q> {
    fn folder(&self, path: &Path) -> (Dirs, u8) {
        let (mut dirs, mut bits) = (Dirs::default(), 0);
        if !self.pos.is_empty() || !self.neg.is_empty() {
            for c in path.components() {
                if let Component::Normal(c) = c {
                    let mut scores = vec![0; self.pos.len()];
                    let row = self.row(&Name::new(c.as_bytes()), &mut scores);
                    dirs = dirs.with(row, &scores);
                    bits = row.bits;
                }
            }
        }
        (dirs, bits)
    }

    fn new(q: &'q Query) -> Words<'q> {
        let pos: Vec<&Token> = q.tokens.iter().filter(|t| !t.negate).collect();
        let under = pos
            .iter()
            .enumerate()
            .fold(0u8, |m, (i, t)| m | u8::from(t.under) << i);
        let run = |plain: bool| -> Vec<char> {
            pos.iter()
                .map(|t| if plain { t.plain.as_ref() } else { None }.unwrap_or(&t.word))
                .flat_map(|w| w.chars.iter().copied().filter(|&c| !is_delim(c)))
                .collect()
        };
        let several = pos.len() > 1 && under == 0;
        let joined = if several { run(false) } else { Vec::new() };
        let plain_joined = if several && pos.iter().any(|t| t.plain.is_some()) {
            run(true)
        } else {
            Vec::new()
        };
        Words {
            all: ((1u16 << pos.len()) - 1) as u8,
            leaf: under.checked_ilog2().map_or(0, |b| 1 << b),
            under,
            neg: q.tokens.iter().filter(|t| t.negate).collect(),
            pos,
            joined,
            plain_joined,
            now: now_secs() as i64,
        }
    }

    fn row(&self, name: &Name, scores: &mut [i16]) -> Row {
        let mut r = Row::default();
        for (t, tok) in self.pos.iter().enumerate() {
            if let Some((s, typo)) = name.token(tok) {
                r.bits |= 1 << t;
                r.typo |= u8::from(typo) << t;
                scores[t] = s.clamp(i16::MIN.into(), i16::MAX.into()) as i16;
            }
        }
        r.neg = self.neg.iter().any(|t| name.token(t).is_some());
        r
    }

    fn needs_folders(&self, row: Row) -> bool {
        !self.neg.is_empty() || row.bits != self.all
    }

    fn rank(
        &self,
        row: Row,
        scores: &[i16],
        dirs: Option<&Dirs>,
        parent: u8,
        name: &Name,
    ) -> Option<(i32, bool)> {
        if dirs.is_some_and(|d| d.neg) {
            return None;
        }
        let (mut score, mut typo) = (0i32, row.typo != 0);
        for (t, &s) in scores.iter().enumerate() {
            let bit = 1u8 << t;
            if row.bits & bit != 0 {
                score += i32::from(s);
            } else {
                let d = dirs.filter(|d| d.got & bit != 0)?;
                score += i32::from(d.best[t]) * 3 / 4;
                typo |= d.typo & bit != 0;
            }
        }
        if self.pos.len() > 1 && row.bits == self.all && self.under == 0 {
            score += name.spelled(&self.joined, &self.plain_joined);
        }
        if self.under != 0 {
            score += path_fit(row.bits, parent, self.under, self.leaf);
        }
        Some((score, typo))
    }
}

#[derive(Clone, Copy, Default)]
struct Row {
    bits: u8,
    typo: u8,
    neg: bool,
}

#[derive(Clone, Copy, Default)]
struct Dirs {
    best: [i16; 8],
    got: u8,
    typo: u8,
    neg: bool,
}

impl Dirs {
    fn with(mut self, row: Row, scores: &[i16]) -> Dirs {
        self.neg |= row.neg;
        for (t, &s) in scores.iter().enumerate() {
            let bit = 1u8 << t;
            if row.bits & bit != 0 && (self.got & bit == 0 || s > self.best[t]) {
                self.best[t] = s;
                self.typo = (self.typo & !bit) | (row.typo & bit);
            }
        }
        self.got |= row.bits;
        self
    }
}

struct Scan<'a> {
    q: &'a Query,
    words: &'a Words<'a>,
    places: &'a Places,
    boot: bool,
    within: Option<&'a Path>,
    members: Option<&'a Members>,
}

impl Scan<'_> {
    fn partial(
        &self,
        partial: crate::unit::partial::Snapshot,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Option<(Found, Vec<Hit>)> {
        let mut hit_dirs: Vec<[u32; 2]> = Vec::new();
        let mut starts = Vec::new();
        let mut rows: Vec<(u32, Hit)> = Vec::new();
        let mut seen = 0usize;
        let mut names = HashMap::new();
        let empty = (Row::default(), [0; MAX_WORDS]);
        for (b, batch) in partial.batches.iter().enumerate() {
            for (at, folder) in batch.iter().enumerate() {
                if partial.excluded.iter().any(|p| folder.path.starts_with(p)) {
                    continue;
                }
                if self.within.is_some_and(|p| !folder.path.starts_with(p)) {
                    continue;
                }
                let (dirs, parent) = self.words.folder(&folder.path);
                let mut first = true;
                for (e, entry) in folder.listing.ents.iter().enumerate() {
                    seen += 1;
                    if seen.is_multiple_of(4096) && cancelled() {
                        return None;
                    }
                    let raw = folder.listing.name(entry);
                    if self.members.is_some_and(|m| {
                        !m.over.contains(
                            folder
                                .path
                                .join(std::ffi::OsStr::from_bytes(raw))
                                .as_os_str()
                                .as_bytes(),
                        )
                    }) {
                        continue;
                    }
                    let (row, scores) = if self.q.tokens.is_empty() {
                        &empty
                    } else {
                        names.entry(raw).or_insert_with(|| {
                            let mut scores = [0; MAX_WORDS];
                            let row = self
                                .words
                                .row(&Name::new(raw), &mut scores[..self.words.pos.len()]);
                            (row, scores)
                        })
                    };
                    if (!self.words.pos.is_empty() && row.bits == 0) || row.neg {
                        continue;
                    }
                    let attrs = entry.attrs();
                    let Some(cost) =
                        self.passes(raw, || pattern_reading(raw), &attrs, &folder.place)
                    else {
                        continue;
                    };
                    let Some(found) = self.words.rank(
                        *row,
                        &scores[..self.words.pos.len()],
                        Some(&dirs),
                        parent,
                        &Name::new(raw),
                    ) else {
                        continue;
                    };
                    if std::mem::take(&mut first) {
                        hit_dirs.push([b as u32, at as u32]);
                        starts.push(rows.len());
                    }
                    rows.push((e as u32, self.hit(found, cost, folder.place, raw, &attrs)));
                }
            }
        }
        let folder = |[b, at]: [u32; 2]| &partial.batches[b as usize][at as usize];
        let mut by_path: Vec<usize> = (0..hit_dirs.len()).collect();
        by_path.sort_unstable_by_key(|&d| folder(hit_dirs[d]).path.as_os_str().as_bytes());
        let mut listed = Vec::with_capacity(rows.len());
        let mut scored = Vec::with_capacity(rows.len());
        let mut listed_dirs = Vec::with_capacity(hit_dirs.len());
        for d in by_path {
            let f = folder(hit_dirs[d]);
            let end = starts.get(d + 1).copied().unwrap_or(rows.len());
            let own = &mut rows[starts[d]..end];
            own.sort_unstable_by_key(|&(e, _)| f.listing.name(&f.listing.ents[e as usize]));
            let place = listed_dirs.len() as u32;
            listed_dirs.push(hit_dirs[d]);
            for &(e, hit) in &*own {
                listed.push([place, e]);
                scored.push(hit);
            }
        }
        Some((
            Found {
                index: partial.base.clone(),
                updated: Arc::default(),
                hits: Vec::new(),
                added: Vec::new(),
                new_dirs: Vec::new(),
                listed,
                listed_dirs,
                partial: Some(partial),
                seen: None,
            },
            scored,
        ))
    }

    fn scan(
        &self,
        live: &Live,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Option<(Found, Vec<Hit>)> {
        let (q, w) = (self.q, self.words);
        let index = &live.base;
        let npos = w.pos.len();
        let filtered = q.filtered();
        let table = if q.tokens.is_empty() {
            Table {
                rows: Vec::new(),
                scores: vec![0; index.names() * npos],
                npos,
            }
        } else {
            score_names(w, index, pieces(index.names()), cancelled)?.0
        };
        let root = index.root();
        let folders = match self.within {
            None => 0..index.folders(),
            Some(real) if real == root => 0..index.folders(),
            Some(real) => live
                .base_dir(real.as_os_str().as_bytes())
                .map_or(0..0, |f| index.subtree_folders(f)),
        };
        let folders = if npos > 0 && table.rows.iter().all(|r| r.bits == 0) {
            0..0
        } else {
            folders
        };
        let places = index.places(self.places, self.boot);
        let base = |folders: std::ops::Range<usize>| {
            if cancelled() {
                return None;
            }
            let mut memo = Memo::new(index, &table, w, root);
            let (mut hits, mut scored) = (Vec::new(), Vec::new());
            let mut seen = 0usize;
            for f in folders {
                let place = places[f];
                for i in index.block(f) {
                    seen += 1;
                    if seen.is_multiple_of(4096) && cancelled() {
                        return None;
                    }
                    if let Some(hit) = self.base_hit(live, &mut memo, filtered, npos, f, place, i) {
                        hits.push(i as u32);
                        scored.push(hit);
                    }
                }
            }
            #[cfg(test)]
            WALKED.with(|w| w.set(w.get() + seen));
            Some((hits, scored))
        };
        let (hits, mut scored) = if q.tokens.is_empty() && folders.len() > INLINE_NAMES {
            let step = folders.len().div_ceil(pieces(folders.len()));
            let parts = (0..folders.len().div_ceil(step))
                .into_par_iter()
                .map(|p| {
                    base(
                        folders.start + p * step..(folders.start + (p + 1) * step).min(folders.end),
                    )
                })
                .collect::<Option<Vec<_>>>()?;
            let count = parts.iter().map(|(hits, _)| hits.len()).sum();
            let (mut hits, mut scored) = (Vec::with_capacity(count), Vec::with_capacity(count));
            for (h, s) in parts {
                hits.extend(h);
                scored.extend(s);
            }
            (hits, scored)
        } else {
            base(folders)?
        };
        let overlay = |over: &[(&Vec<u8>, &Attrs)]| {
            if cancelled() {
                return None;
            }
            let mut memo = Memo::new(index, &table, w, root);
            let mut scored = Vec::new();
            let mut seen = 0usize;
            let mut added = Vec::new();
            let mut new_dirs = Vec::new();
            let mut last_folder = None;
            let mut folders = Vec::new();
            for &(path, a) in over {
                seen += 1;
                if seen.is_multiple_of(4096) && cancelled() {
                    return None;
                }
                let Some((folder, raw, dir, hit)) =
                    self.over_hit(live, &mut memo, filtered, npos, path, a, &mut folders)
                else {
                    continue;
                };
                added.push(Added {
                    name: String::from_utf8_lossy(raw).into_owned(),
                    attrs: *a,
                    folder: listed_folder(dir, folder, &mut last_folder, &mut new_dirs),
                });
                scored.push(hit);
            }
            Some((added, new_dirs, scored))
        };
        let over: Vec<_> = live.over.iter().collect();
        let step = over.len().div_ceil(pieces(over.len())).max(1);
        let parts = over
            .par_chunks(step)
            .map(overlay)
            .collect::<Option<Vec<_>>>()?;
        let mut added = Vec::with_capacity(parts.iter().map(|(a, _, _)| a.len()).sum());
        let mut new_dirs = Vec::with_capacity(parts.iter().map(|(_, d, _)| d.len()).sum());
        for (mut a, d, s) in parts {
            let first = new_dirs.len() as u32;
            for h in &mut a {
                if let Folder::New(k) = &mut h.folder {
                    *k += first;
                }
            }
            added.extend(a);
            new_dirs.extend(d);
            scored.extend(s);
        }
        let found = Found {
            index: index.clone(),
            updated: live.updated.clone(),
            hits,
            added,
            new_dirs,
            listed: Vec::new(),
            listed_dirs: Vec::new(),
            partial: None,
            seen: None,
        };
        Some((found, scored))
    }

    #[inline(always)]
    #[allow(clippy::too_many_arguments)]
    fn base_hit(
        &self,
        live: &Live,
        memo: &mut Memo,
        filtered: bool,
        npos: usize,
        f: usize,
        place: Place,
        i: usize,
    ) -> Option<Hit> {
        let (q, w, index) = (self.q, self.words, &live.base);
        if self.members.is_some_and(|m| !m.has(i)) {
            return None;
        }
        let id = index.name_id(i);
        let (row, scores) = memo.table.get(id);
        if (npos > 0 && row.bits == 0) || row.neg || live.is_dead(i as u32) {
            return None;
        }
        let raw = index.name(id);
        let a = live.attrs(i);
        let cost = if filtered {
            let plain = || {
                let j = index.plain_from(id);
                if index.plain_name(j) == Some(id) {
                    Some(Cow::Borrowed(index.plain(j)))
                } else {
                    dotless(raw).map(|d| Cow::Owned(d.into_bytes()))
                }
            };
            self.passes(raw, plain, &a, &place)?
        } else {
            0
        };
        let found = if q.tokens.is_empty() {
            (0, false)
        } else {
            let dirs = w.needs_folders(row).then(|| memo.dirs(f));
            let parent = if w.under != 0 { memo.own_bits(f) } else { 0 };
            let name = Name::new(raw);
            w.rank(row, scores, dirs.as_ref(), parent, &name)?
        };
        Some(self.hit(found, cost, place, raw, &a))
    }

    #[inline(always)]
    #[allow(clippy::too_many_arguments)]
    fn over_hit<'p>(
        &self,
        live: &Live,
        memo: &mut Memo,
        filtered: bool,
        npos: usize,
        path: &'p [u8],
        a: &Attrs,
        folders: &mut Vec<(&'p [u8], Option<usize>)>,
    ) -> Option<(&'p Path, &'p [u8], Option<u32>, Hit)> {
        let (q, w) = (self.q, self.words);
        if self.members.is_some_and(|m| !m.over.contains(path)) {
            return None;
        }
        let p = as_path(path);
        if self.within.is_some_and(|s| p == s || !p.starts_with(s)) {
            return None;
        }
        let (Some(raw), Some(folder)) = (p.file_name(), p.parent()) else {
            return None;
        };
        let raw = raw.as_bytes();
        let name = Name::new(raw);
        let mut scores = vec![0; npos];
        let row = if q.tokens.is_empty() {
            Row::default()
        } else {
            w.row(&name, &mut scores)
        };
        if (npos > 0 && row.bits == 0) || row.neg {
            return None;
        }
        let (place, dirs, parent, dir) = self.overlay_folder(live, memo, folder, row, folders)?;
        let cost = if filtered {
            self.passes(raw, || pattern_reading(raw), a, &place)?
        } else {
            0
        };
        let found = w.rank(row, &scores, dirs.as_ref(), parent, &name)?;
        Some((folder, raw, dir, self.hit(found, cost, place, raw, a)))
    }

    fn passes<P: AsRef<[u8]>>(
        &self,
        name: &[u8],
        plain: impl FnOnce() -> Option<P>,
        a: &Attrs,
        place: &Place,
    ) -> Option<i32> {
        let q = self.q;
        let kind_ok = q.kind.is_none_or(|k| {
            a.kind == k || (q.apps && k == EngineKind::Folder && a.kind == EngineKind::Link)
        });
        let exts = !q.exts.is_empty() || !q.type_exts.is_empty() || !q.not_exts.is_empty();
        let ext = exts
            .then(|| name.iter().rposition(|&b| b == b'.'))
            .flatten()
            .map(|dot| &name[dot + 1..]);
        let plain_ext = LazyCell::new(|| {
            let e = ext.filter(|e| !e.is_ascii())?;
            #[cfg(test)]
            crate::rank::folded_once();
            reading(e)
        });
        let has = |list: &[Vec<u8>]| ext.is_some_and(|e| ext_in(e, list));
        let has_plain = |list: &[Vec<u8>]| {
            plain_ext
                .as_ref()
                .is_some_and(|e| ext_in(e.as_bytes(), list))
        };
        let ok = kind_ok
            && (q.type_exts.is_empty() || has(&q.type_exts))
            && (q.not_exts.is_empty() || !(has(&q.not_exts) || has_plain(&q.not_exts)))
            && (q.size == (0, u64::MAX)
                || (a.kind == EngineKind::File && (q.size.0..=q.size.1).contains(&a.size)))
            && (q.mtime.0..=q.mtime.1).contains(&a.mtime);
        if !ok {
            return None;
        }
        let mut cost = 0;
        if !q.exts.is_empty() && !has(&q.exts) {
            if !(has(&q.plain_exts) || has_plain(&q.exts) || has_plain(&q.plain_exts)) {
                return None;
            }
            cost = PLAIN_COST;
        }
        let composed = LazyCell::new(|| composed(name));
        let read = LazyCell::new(|| if name.is_ascii() { None } else { plain() });
        for r in &q.name_re {
            let hit = if r.re.is_match(name)
                || composed
                    .as_ref()
                    .is_some_and(|n| r.re.is_match(n.as_bytes()))
            {
                Some(false)
            } else if r.exact || (read.is_none() && r.plain.is_none()) {
                None
            } else {
                #[cfg(test)]
                crate::rank::folded_once();
                let plain = r.plain.as_ref().unwrap_or(&r.re);
                plain
                    .find_iter(read.as_ref().map_or(name, AsRef::as_ref))
                    .any(|m| !m.is_empty())
                    .then_some(true)
            };
            match hit {
                Some(_) if r.negate => return None,
                None if !r.negate => return None,
                Some(true) => cost = PLAIN_COST,
                _ => {}
            }
        }
        (!(q.hide && self.places.step(place, name, a.hidden).hidden())).then_some(cost)
    }

    fn hit(
        &self,
        (score, typo): (i32, bool),
        cost: i32,
        place: Place,
        name: &[u8],
        a: &Attrs,
    ) -> Hit {
        let score = score - cost
            + i32::from(place.prior)
            + tweaks(name, a.kind, a.hidden, a.mtime, self.words.now);
        Hit {
            score: if typo { score - TYPO_LAST } else { score },
            file: a.kind == EngineKind::File,
        }
    }

    fn overlay_folder<'p>(
        &self,
        live: &Live,
        memo: &mut Memo,
        folder: &'p Path,
        row: Row,
        folders: &mut Vec<(&'p [u8], Option<usize>)>,
    ) -> Option<(Place, Option<Dirs>, u8, Option<u32>)> {
        let (f, top) = folder
            .ancestors()
            .find_map(|a| live.cached_dir(a, folders).map(|f| (f, a)))?;
        let dir = (top.as_os_str() == folder.as_os_str()).then_some(f as u32);
        let need = self.words.needs_folders(row);
        let mut place = live.base.places(self.places, self.boot)[f];
        let mut dirs = need.then(|| memo.dirs(f));
        let mut parent = if self.words.under != 0 {
            memo.own_bits(f)
        } else {
            0
        };
        if dir.is_some() {
            return Some((place, dirs, parent, dir));
        }
        let mut path = top.to_path_buf();
        for c in folder.strip_prefix(top).ok()?.components() {
            path.push(c);
            let c = c.as_os_str().as_bytes();
            let flagged = live
                .over
                .get(path.as_os_str().as_bytes())
                .is_some_and(|a| a.hidden);
            place = self.places.step(&place, c, flagged);
            if need || self.words.under != 0 {
                let mut scores = vec![0; self.words.pos.len()];
                let own = self.words.row(&Name::new(c), &mut scores);
                dirs = dirs.map(|d| d.with(own, &scores));
                parent = own.bits;
            }
        }
        Some((place, dirs, parent, dir))
    }
}

#[inline]
fn listed_folder<'p>(
    dir: Option<u32>,
    folder: &'p Path,
    last: &mut Option<&'p Path>,
    new_dirs: &mut Vec<String>,
) -> Folder {
    let dir = match dir {
        Some(d) => Folder::Base(d),
        None => {
            if *last != Some(folder) {
                new_dirs.push(folder.to_string_lossy().into_owned());
            }
            Folder::New(new_dirs.len() as u32 - 1)
        }
    };
    *last = Some(folder);
    dir
}

pub(crate) fn judge(
    q: &Query,
    places: &Places,
    boot: bool,
    live: &Live,
    ids: &[u32],
    paths: &[Vec<u8>],
) -> Option<(Found, Vec<Hit>)> {
    if !q.tokens.is_empty() || q.scope.is_some() || q.never {
        return None;
    }
    let words = Words::new(q);
    let scan = Scan {
        q,
        words: &words,
        places,
        boot,
        within: None,
        members: None,
    };
    let index = &live.base;
    let npos = words.pos.len();
    let table = Table {
        rows: Vec::new(),
        scores: Vec::new(),
        npos,
    };
    let filtered = q.filtered();
    let mut memo = Memo::new(index, &table, &words, index.root());
    let placed = index.places(places, boot);
    let (mut hits, mut scored) = (Vec::new(), Vec::new());
    for &i in ids {
        let f = index.parent(i as usize);
        if let Some(hit) = scan.base_hit(live, &mut memo, filtered, npos, f, placed[f], i as usize)
        {
            hits.push(i);
            scored.push(hit);
        }
    }
    let (mut added, mut new_dirs, mut folders, mut last_folder) =
        (Vec::new(), Vec::new(), Vec::new(), None);
    for path in paths {
        let Some((path, a)) = live.over.get_key_value(path) else {
            continue;
        };
        let Some((folder, raw, dir, hit)) =
            scan.over_hit(live, &mut memo, filtered, npos, path, a, &mut folders)
        else {
            continue;
        };
        added.push(Added {
            name: String::from_utf8_lossy(raw).into_owned(),
            attrs: *a,
            folder: listed_folder(dir, folder, &mut last_folder, &mut new_dirs),
        });
        scored.push(hit);
    }
    let found = Found {
        index: index.clone(),
        updated: live.updated.clone(),
        hits,
        added,
        new_dirs,
        listed: Vec::new(),
        listed_dirs: Vec::new(),
        partial: None,
        seen: None,
    };
    Some((found, scored))
}

const INLINE_NAMES: usize = 4096;

pub(crate) fn pieces(names: usize) -> usize {
    if names <= INLINE_NAMES {
        1
    } else {
        (rayon::current_num_threads() * 4).min(names)
    }
}

fn score_names(
    w: &Words,
    index: &Index,
    pieces: usize,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Option<(Table, usize)> {
    let (n, npos) = (index.names(), w.pos.len());
    let step = n.div_ceil(pieces).max(1);
    let piece = |p: usize| {
        if cancelled() {
            return None;
        }
        let (lo, hi) = ((p * step).min(n), ((p + 1) * step).min(n));
        let mut scores = vec![0; (hi - lo) * npos];
        let mut j = index.plain_from(lo);
        let rows: Vec<Row> = (lo..hi)
            .map(|k| {
                let i = k - lo;
                let plain = (index.plain_name(j) == Some(k)).then(|| {
                    j += 1;
                    index.plain(j - 1)
                });
                w.row(
                    &Name::stored(index.name(k), plain),
                    &mut scores[i * npos..(i + 1) * npos],
                )
            })
            .collect();
        Some((rows, scores))
    };
    let parts: Vec<(Vec<Row>, Vec<i16>)> = if pieces == 1 {
        vec![piece(0)?]
    } else {
        (0..pieces)
            .into_par_iter()
            .map(piece)
            .collect::<Option<_>>()?
    };
    let count = parts.len();
    let mut table = Table {
        rows: Vec::with_capacity(n),
        scores: Vec::with_capacity(n * npos),
        npos,
    };
    for (rows, scores) in parts {
        table.rows.extend(rows);
        table.scores.extend(scores);
    }
    Some((table, count))
}

struct Table {
    rows: Vec<Row>,
    scores: Vec<i16>,
    npos: usize,
}

impl Table {
    fn get(&self, id: usize) -> (Row, &[i16]) {
        match self.rows.get(id) {
            Some(&r) => (r, &self.scores[id * self.npos..(id + 1) * self.npos]),
            None => (Row::default(), &[]),
        }
    }
}

struct Memo<'a> {
    index: &'a Index,
    table: &'a Table,
    seen: HashMap<usize, Dirs>,
    root: Dirs,
    root_bits: u8,
}

impl<'a> Memo<'a> {
    fn new(index: &'a Index, table: &'a Table, w: &Words, root: &Path) -> Memo<'a> {
        let (dirs, bits) = w.folder(root);
        Memo {
            index,
            table,
            seen: HashMap::new(),
            root: dirs,
            root_bits: bits,
        }
    }

    fn dirs(&mut self, f: usize) -> Dirs {
        let mut chain = Vec::new();
        let mut k = f;
        let mut d = loop {
            if let Some(&d) = self.seen.get(&k) {
                break d;
            }
            if k == 0 {
                break self.root;
            }
            chain.push(k);
            k = self.index.parent(self.index.dir_entry(k) as usize);
        };
        for &k in chain.iter().rev() {
            let (row, scores) = self
                .table
                .get(self.index.name_id(self.index.dir_entry(k) as usize));
            d = d.with(row, scores);
            self.seen.insert(k, d);
        }
        d
    }

    fn own_bits(&self, f: usize) -> u8 {
        if f == 0 {
            self.root_bits
        } else {
            self.table
                .get(self.index.name_id(self.index.dir_entry(f) as usize))
                .0
                .bits
        }
    }
}

fn ext_in(e: &[u8], exts: &[Vec<u8>]) -> bool {
    if e.is_ascii() {
        return exts.iter().any(|x| x.eq_ignore_ascii_case(e));
    }
    let Ok(e) = std::str::from_utf8(e) else {
        return false;
    };
    let e = fold(e);
    exts.iter().any(|x| *x == e.as_bytes())
}

#[cfg(test)]
impl Live {
    pub(crate) fn scan_one(
        &self,
        q: &Query,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Option<(Found, Vec<Hit>)> {
        self.scan_at(q, now_secs() as i64, cancelled)
    }

    pub(crate) fn scan_at(
        &self,
        q: &Query,
        now: i64,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Option<(Found, Vec<Hit>)> {
        self.scan_as(q, true, now, cancelled)
    }

    fn scan_as(
        &self,
        q: &Query,
        boot: bool,
        now: i64,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Option<(Found, Vec<Hit>)> {
        if q.never {
            let empty = Found {
                partial: None,
                index: self.base.clone(),
                updated: self.updated.clone(),
                hits: Vec::new(),
                added: Vec::new(),
                new_dirs: Vec::new(),
                listed: Vec::new(),
                listed_dirs: Vec::new(),
                seen: None,
            };
            return Some((empty, Vec::new()));
        }
        let mut words = Words::new(q);
        words.now = now;
        let places = Places::new(Path::new("/nonexistent"));
        let scan = Scan {
            q,
            words: &words,
            places: &places,
            boot,
            within: None,
            members: None,
        };
        let (mut found, hits) = scan.scan(self, cancelled)?;
        found.seen = Some(Seen {
            live: self.id(),
            at: self.touched_at(),
        });
        Some((found, hits))
    }

    pub(crate) fn find_units(
        text: &str,
        typos: bool,
        units: &[&Live],
        cancelled: impl Fn() -> bool + Sync,
    ) -> Option<(Scanned, usize)> {
        let mut q = Query::parse(text, "/nonexistent");
        let mut passes = 0;
        let scanned = retry(&mut q, typos, |q| {
            passes += 1;
            let now = now_secs() as i64;
            units
                .iter()
                .enumerate()
                .map(|(i, live)| live.scan_as(q, i == 0, now, &cancelled))
                .collect()
        })?;
        Some((scanned, passes))
    }

    pub(crate) fn find_passes(
        &self,
        text: &str,
        typos: bool,
        cancelled: impl Fn() -> bool + Sync,
    ) -> Option<(Found, Vec<Hit>, usize)> {
        let (mut one, passes) = Live::find_units(text, typos, &[self], cancelled)?;
        let (found, hits) = one.remove(0);
        Some((found, hits, passes))
    }

    pub(crate) fn find(&self, text: &str, cancelled: impl Fn() -> bool + Sync) -> Option<Found> {
        self.find_passes(text, false, cancelled)
            .map(|(found, ..)| found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/someone";

    fn q(text: &str) -> Query {
        Query::parse(text, HOME)
    }

    fn texts(q: &Query) -> Vec<(String, Mode, bool, bool)> {
        q.tokens
            .iter()
            .map(|t| {
                let text: String = t.word.chars.iter().collect();
                (text, t.mode, t.negate, t.under)
            })
            .collect()
    }

    fn token(text: &str, mode: Mode, negate: bool, under: bool) -> (String, Mode, bool, bool) {
        (text.to_owned(), mode, negate, under)
    }

    #[test]
    fn each_operator_sets_its_mode() {
        let cases = [
            ("Report", token("report", Mode::Together, false, false)),
            ("'Rep", token("rep", Mode::Exact, false, false)),
            ("^rep", token("rep", Mode::Prefix, false, false)),
            ("rep$", token("rep", Mode::Suffix, false, false)),
            ("!rep", token("rep", Mode::Exact, true, false)),
            ("!^rep", token("rep", Mode::Prefix, true, false)),
            ("!rep$", token("rep", Mode::Suffix, true, false)),
            ("^rep$", token("rep", Mode::Whole, false, false)),
            ("!^rep$", token("rep", Mode::Whole, true, false)),
        ];
        for (text, want) in cases {
            assert_eq!(texts(&q(text)), [want], "{text}");
        }
        assert!(q("^").tokens.is_empty());
    }

    #[test]
    fn literal_name_modes_keep_operators_as_letters() {
        for (key, mode) in [
            ("begins", Mode::Prefix),
            ("ends", Mode::Suffix),
            ("whole", Mode::Whole),
        ] {
            for value in [
                "!draft", "'s notes", "re:x", "*.pdf", "v1$", "'x", "<>=.,", "a/b",
            ] {
                let mut parsed = q(&format!("{key}:\"{value}\""));
                assert_eq!(texts(&parsed), [token(value, mode, false, false)]);
                assert_eq!(parsed.tokens[0].edits, 0);
                parsed.tokens.clear();
                assert_eq!(parsed, q(""));
            }
            assert_eq!(q(&format!("{key}:\"\"")), q(""));
            let capped = q(&format!("a b c d e f g h {key}:x"));
            assert_eq!(capped.tokens.len(), MAX_WORDS);
            assert_eq!(texts(&capped)[0].0, "b");
            assert_eq!(texts(&capped)[7], token("x", mode, false, false));
            let unicode = q(&format!("{key}:É"));
            assert_eq!(unicode.tokens[0].word, Word::new("é"));
            assert_eq!(unicode.tokens[0].other, Some(Word::new("e\u{301}")));
        }
        assert_eq!(
            texts(&q("ends:x")),
            [token("x", Mode::Suffix, false, false)]
        );
        assert_eq!(
            texts(&q("foo:bar")),
            [token("foo:bar", Mode::Together, false, false)]
        );
    }

    #[test]
    fn a_star_word_parses_to_a_name_pattern_and_other_words_stay_as_today() {
        let star = q("cardinal*.dmg");
        assert!(star.tokens.is_empty());
        assert_eq!(star.name_re.len(), 1);
        assert!(!star.name_re[0].negate);
        assert!(star.name_re[0].re.is_match(b"Cardinal_0.1.23_aarch64.dmg"));
        assert!(q("file[1]*").name_re[0].re.is_match(b"file[1].txt"));
        assert!(!q("file[1]*").name_re[0].re.is_match(b"file1.txt"));
        assert!(q("!draft*").name_re[0].negate);
        assert_eq!(texts(&q("'a*b")), [token("a*b", Mode::Exact, false, false)]);
        assert!(q("'a*b").name_re.is_empty());
        assert_eq!(
            texts(&q("\"a*b\"")),
            [token("a*b", Mode::Together, false, false)]
        );
        let ext = q("*.dmg");
        assert_eq!(ext.exts, [b"dmg".to_vec()]);
        assert!(ext.name_re.is_empty() && ext.tokens.is_empty());
        let under = q("Downloads/*.dmg");
        assert_eq!(under.exts, [b"dmg".to_vec()]);
        assert_eq!(
            texts(&under),
            [token("downloads", Mode::Together, false, false)]
        );
        let folder = q("Down*/cardinal");
        assert!(folder.name_re.is_empty());
        assert_eq!(
            texts(&folder),
            [
                token("down*", Mode::Together, false, false),
                token("cardinal", Mode::Together, false, true)
            ]
        );
        let piece = q("Downloads/cardinal*.dmg");
        assert_eq!(
            texts(&piece),
            [token("downloads", Mode::Together, false, false)]
        );
        assert_eq!(piece.name_re.len(), 1);
        assert_eq!(
            texts(&q("docs/report")),
            [
                token("docs", Mode::Together, false, false),
                token("report", Mode::Together, false, true)
            ]
        );
        assert_eq!(
            texts(&q("cardinal")),
            [token("cardinal", Mode::Together, false, false)]
        );
        assert!(q("cardinal").name_re.is_empty());
        let unknown = q("nosuch:a*");
        assert!(unknown.tokens.is_empty());
        assert!(unknown.name_re[0].re.is_match(b"nosuch:abc"));
    }

    #[test]
    fn capped_path_words_keep_their_folder_relationship() {
        for text in [
            "a b c d e f g h docs/report",
            "/Users/me/Code/Wherever/Project/Engine/wherever-core/src/query.rs",
        ] {
            let parsed = q(text);
            assert_eq!(parsed.tokens.len(), MAX_WORDS);
            assert!(!parsed.tokens[0].under);
            assert!(texts(&parsed).last().unwrap().3, "{text}");
        }
        assert!(!q("a b c d e f g h/^").tokens.last().unwrap().under);
        assert!(!q("a b c d e f g h/!report").tokens.last().unwrap().under);
    }

    #[test]
    fn quotes_keep_a_space_and_slashes_make_path_words() {
        assert_eq!(
            texts(&q("\"annual report\" x")),
            [
                token("annual report", Mode::Together, false, false),
                token("x", Mode::Together, false, false)
            ]
        );
        assert_eq!(
            texts(&q("docs/report")),
            [
                token("docs", Mode::Together, false, false),
                token("report", Mode::Together, false, true)
            ]
        );
        assert_eq!(
            texts(&q("!a/b")),
            [
                token("a", Mode::Exact, true, false),
                token("b", Mode::Together, false, true)
            ]
        );
    }

    #[test]
    fn a_full_width_space_splits_words() {
        for gap in ["\u{3000}", "\u{a0}", "\t", "\n", " \u{3000} "] {
            assert_eq!(
                split_words(&format!("\u{4f1a}\u{8b70}{gap}\u{8cc7}\u{6599}")),
                ["\u{4f1a}\u{8b70}", "\u{8cc7}\u{6599}"],
                "{gap:?}"
            );
        }
        assert_eq!(texts(&q("report\u{3000}draft")).len(), 2);
        assert_eq!(split_words("\"a\u{3000}b\""), ["a\u{3000}b"]);
        assert!(split_words(" \u{3000}\t").is_empty());
    }

    #[test]
    fn a_doubled_quote_is_a_literal_quote() {
        assert_eq!(split_words("\"say \"\"hi\"\"\" x"), ["say \"hi\"", "x"]);
        assert_eq!(
            split_words("in:\"/tmp/Notes \"\"draft\"\"\""),
            ["in:/tmp/Notes \"draft\""]
        );
        assert_eq!(split_words("\"\"\"\""), ["\""]);
        assert!(split_words("\"\"").is_empty());
        assert_eq!(split_words("a \"\" b"), ["a", "b"]);
        assert_eq!(
            texts(&q("begins:\"say \"\"hi\"\"\"")),
            [token("say \"hi\"", Mode::Prefix, false, false)]
        );
        assert_eq!(
            q("in:\"/tmp/Notes \"\"draft\"\"\"").scope,
            Some(PathBuf::from("/tmp/Notes \"draft\""))
        );
        assert_eq!(q("re:\"a\\b\"").name_re[0].re.as_str(), "(?i)a\\b");
    }

    #[test]
    fn a_semicolon_separates_extensions() {
        assert_eq!(q("ext:jpg;png").exts, [b"jpg".to_vec(), b"png".to_vec()]);
        assert_eq!(q("ext:jpg;.PNG,gif").exts.len(), 3);
        let media = q("type:image;video");
        assert!(!media.never);
        assert!(
            media.type_exts.contains(&b"png".to_vec())
                && media.type_exts.contains(&b"mov".to_vec())
        );
        assert!(q("type:image;x").never);
        assert_eq!(q("report ext:;"), q("report"));
        assert_eq!(q("report type:;"), q("report"));
    }

    #[test]
    fn a_leading_tilde_path_finds_the_home_folder() {
        assert_eq!(
            texts(&q("~/Documents/report")),
            [
                token("users", Mode::Together, false, false),
                token("someone", Mode::Together, false, true),
                token("documents", Mode::Together, false, true),
                token("report", Mode::Together, false, true)
            ]
        );
        assert_eq!(q("\"~/My Files/a\"").tokens.len(), 4);
        assert_eq!(texts(&q("~report"))[0].0, "~report");
        assert_eq!(texts(&q("a/~/b")).len(), 3);
        assert_eq!(
            q("in:~/Documents").scope,
            Some(PathBuf::from("/Users/someone/Documents"))
        );
    }

    #[test]
    fn kind_accepts_plural_forms() {
        for (text, kind) in [
            ("kind:files", EngineKind::File),
            ("kind:folders", EngineKind::Folder),
            ("kind:links", EngineKind::Link),
        ] {
            let p = q(text);
            assert_eq!((p.kind, p.never), (Some(kind), false), "{text}");
        }
    }

    #[test]
    fn globs_of_an_extension_are_extensions() {
        assert_eq!(q("*.PDF").exts, [b"pdf".to_vec()]);
        assert_eq!(q("*.{jpg,png}").exts, [b"jpg".to_vec(), b"png".to_vec()]);
        assert_eq!(q("!*.md").not_exts, [b"md".to_vec()]);
        assert!(q("*.pdf").tokens.is_empty());
        let tar = q("*.tar.gz");
        assert!(tar.tokens.is_empty());
        assert_eq!(tar.name_re.len(), 1);
        assert!(tar.name_re[0].re.is_match(b"a.tar.gz"));
        assert!(!tar.name_re[0].re.is_match(b"a.tar.gz.bak"));
    }

    #[test]
    fn at_most_eight_positive_words() {
        let many = q("a b c d e f g h i !x");
        let words: Vec<String> = texts(&many).into_iter().map(|t| t.0).collect();
        assert_eq!(words, ["b", "c", "d", "e", "f", "g", "h", "i", "x"]);
    }

    #[test]
    fn a_fuzzy_word_of_five_characters_takes_a_typo() {
        let loose = |text: &str| q(text).loosened();
        assert_eq!(loose("rpeort").tokens[0].edits, 1);
        assert_eq!(loose("ünalé").tokens[0].edits, 1);
        assert_eq!(loose("document").tokens[0].edits, 2);
        assert_eq!(loose("picture").tokens[0].edits, 1);
        assert!(!loose("document").tokens[0].deep);
        assert!(loose("document").deepen().tokens[0].deep);
        assert!(!loose("repo").deepen().tokens[0].deep);
        assert_eq!(loose("repo").tokens[0].edits, 0);
        assert_eq!(loose("'report").tokens[0].edits, 0);
        assert_eq!(loose("!report").tokens[0].edits, 0);
        assert_eq!(q("document").tokens[0].edits, 0);
        assert!(!q("document").deepen().tokens[0].deep);
    }

    #[test]
    fn plain_words_parse_side_by_side_and_loosen_to_today() {
        let t = &q("report").tokens[0];
        assert_eq!((t.mode, t.edits), (Mode::Together, 0));
        let loose = |text: &str| {
            let t = &q(text).loosened().tokens[0];
            (t.mode, t.edits, t.deep)
        };
        assert_eq!(loose("report"), (Mode::Fuzzy, 1, false));
        assert_eq!(loose("document"), (Mode::Fuzzy, 2, false));
        assert_eq!(loose("repo"), (Mode::Fuzzy, 0, false));
        for text in ["'r", "^r", "r$", "!r", "begins:r", "^r$"] {
            assert_eq!(q(text).loosened(), q(text), "{text}");
        }
        let both = q("report 'r").loosened();
        assert_eq!(
            (both.tokens[0].mode, both.tokens[1].mode),
            (Mode::Fuzzy, Mode::Exact)
        );
    }

    #[test]
    fn every_contract_token_parses() {
        let mb = 1_000_000;
        let sizes = [
            ("size:<=1mb", (0, mb)),
            ("size:1mb..100mb", (mb, 100 * mb)),
            ("size:100mb..1gb", (100 * mb, 1000 * mb)),
            ("size:>=1gb", (1000 * mb, u64::MAX)),
            ("size:>=10mb", (10 * mb, u64::MAX)),
            ("size:10mb..1gb", (10 * mb, 1000 * mb)),
        ];
        for (text, want) in sizes {
            let p = q(text);
            assert_eq!((p.size, p.never), (want, false), "{text}");
        }
        for (text, days) in [
            ("mtime:<1d", 1),
            ("mtime:<7d", 7),
            ("mtime:<30d", 30),
            ("mtime:<365d", 365),
        ] {
            let p = q(text);
            assert!(!p.never, "{text}");
            assert_eq!(p.mtime.1 - p.mtime.0, days * 86_400, "{text}");
            assert!((now_secs() as i64 - p.mtime.1).abs() <= 1, "{text}");
        }
        for (text, kind) in [
            ("kind:file", EngineKind::File),
            ("kind:folder", EngineKind::Folder),
            ("kind:link", EngineKind::Link),
        ] {
            assert_eq!(q(text).kind, Some(kind), "{text}");
        }
        for (name, ext) in [
            ("image", "png"),
            ("video", "mov"),
            ("audio", "mp3"),
            ("doc", "pdf"),
            ("code", "rs"),
            ("archive", "zip"),
            ("font", "ttf"),
        ] {
            let p = q(&format!("type:{name}"));
            assert!(
                !p.never && p.type_exts.contains(&ext.as_bytes().to_vec()),
                "{name}"
            );
        }
        let app = q("type:app");
        assert_eq!(
            (app.kind, app.apps, app.type_exts),
            (Some(EngineKind::Folder), true, vec![b"app".to_vec()])
        );
        assert_eq!(q("ext:pdf,docx").exts, [b"pdf".to_vec(), b"docx".to_vec()]);
        assert_eq!(
            q("in:\"/Volumes/Disk 1/Photos\" x").scope,
            Some(PathBuf::from("/Volumes/Disk 1/Photos"))
        );
        assert_eq!(
            q("in:~/Documents").scope,
            Some(PathBuf::from("/Users/someone/Documents"))
        );
        assert!(q("hidden:no").hide);
        let both = q("kind:file kind:folder ext:a ext:b");
        assert_eq!((both.kind, both.exts.len()), (Some(EngineKind::Folder), 2));
    }

    #[test]
    fn bare_values_and_open_ends() {
        let week = q("mtime:7d");
        assert_eq!(week.mtime.1 - week.mtime.0, 7 * 86_400);
        assert_eq!(q("mtime:7").mtime.1 - q("mtime:7").mtime.0, 7 * 86_400);
        assert_eq!(q("modified:2h").mtime.1 - q("modified:2h").mtime.0, 7200);
        assert_eq!(q("mtime:>30d").mtime.0, i64::MIN);
        assert_eq!(q("size:10mb").size, (10_000_000, u64::MAX));
        assert_eq!(q("size:0").size, (0, 0));
        assert_eq!(q("size:1500").size, (1500, 1500));
        assert_eq!(q("size:10mb..").size, (10_000_000, u64::MAX));
        assert_eq!(q("size:..1gb").size, (0, 1_000_000_000));
    }

    #[test]
    fn an_empty_value_is_ignored() {
        let plain = q("report");
        for empty in [
            "size:",
            "size:>",
            "size:..",
            "kind:",
            "type:",
            "type:,",
            "mtime:",
            "modified:<",
            "hidden:",
            "in:",
            "ext:",
            "ext:,",
        ] {
            assert_eq!(q(&format!("report {empty}")), plain, "{empty}");
        }
    }

    #[test]
    fn a_folder_of_only_punctuation_is_a_relative_path() {
        for scope in [".", "..", ",", ";", "=", "<", ">"] {
            let want = Some(PathBuf::from(scope));
            assert_eq!(q(&format!("in:{scope}")).scope, want, "{scope}");
            assert_eq!(q(&format!("in:\"{scope}\"")).scope, want, "{scope}");
        }
    }

    #[test]
    fn a_bad_value_matches_nothing() {
        for bad in [
            "size:-5",
            "size:5mb..1mb",
            "size:10xb",
            "kind:x",
            "type:x",
            "type:image,x",
            "mtime:7q",
            "hidden:yes",
        ] {
            assert!(q(bad).never, "{bad}");
        }
        assert_eq!(texts(&q("c:foo")).len(), 1);
    }

    #[test]
    fn text_and_anytext_are_name_words() {
        for typed in ["text:zyq", "anytext:zyq"] {
            assert_eq!(texts(&q(typed)).len(), 1, "{typed}");
            assert_eq!(texts(&q(&format!("report {typed}"))).len(), 2, "{typed}");
        }
    }

    #[test]
    fn a_content_term_is_folded_and_carries_its_other_form() {
        assert_eq!(term("Full Disk"), ("full disk".to_owned(), None));
        assert_eq!(term("=="), ("==".to_owned(), None));
        assert_eq!(
            term("Caf\u{e9}"),
            ("caf\u{e9}".to_owned(), Some("cafe\u{301}".to_owned()))
        );
    }

    #[test]
    fn a_composed_word_also_carries_its_decomposed_form() {
        let composed = q("caf\u{e9}");
        let other: String = composed.tokens[0]
            .other
            .as_ref()
            .unwrap()
            .chars
            .iter()
            .collect();
        assert_eq!(other, "cafe\u{301}");
        let decomposed = q("cafe\u{301}");
        let other: String = decomposed.tokens[0]
            .other
            .as_ref()
            .unwrap()
            .chars
            .iter()
            .collect();
        assert_eq!(other, "caf\u{e9}");
        assert_eq!(q("cafe").tokens[0].other, None);
        assert_eq!(
            q("\u{130}stanbul").tokens[0].word.ascii,
            Some(b"istanbul".to_vec())
        );
    }

    #[test]
    fn a_folder_past_a_mount_point_or_under_an_excluded_path_is_walked() {
        use crate::crawl::tests::TempTree;
        let tree = TempTree::new("query-unindexed");
        fs::create_dir_all(tree.0.join("Disk/Docs")).unwrap();
        fs::create_dir_all(tree.0.join("Skip/In")).unwrap();
        let root = PathBuf::from(tree.real());
        let (disk, skip) = (root.join("Disk"), [root.join("Skip")]);
        let walked = |text: String, roots: &[PathBuf]| {
            unindexed(&q(&text), &skip, roots, &mut |p: &Path| p == disk)
        };
        let boot = [root.clone()];
        let r = root.display();
        for indexed in [format!("in:{r}"), format!("in:{r}/Sub"), "zyq".to_owned()] {
            assert_eq!(walked(indexed.clone(), &boot), None, "{indexed}");
        }
        for (text, folder) in [
            (format!("in:{r}/Disk"), disk.clone()),
            (format!("in:{r}/Disk/Docs"), disk.join("Docs")),
            (format!("in:{r}/Skip/In"), root.join("Skip/In")),
            (format!("in:{r}/Skip/../Skip"), root.join("Skip")),
            (format!("in:{r}/.."), root.parent().unwrap().to_path_buf()),
        ] {
            assert_eq!(walked(text.clone(), &boot), Some(folder), "{text}");
        }
        assert_eq!(walked(format!("in:{r}/missing"), &boot), None);
        assert_eq!(walked(format!("in:{r}/Disk size:-5"), &boot), None);
        let both = [root.clone(), disk.clone()];
        assert_eq!(walked(format!("in:{r}/Disk/Docs"), &both), None);
    }

    #[test]
    fn a_scope_on_a_network_mount_is_not_canonicalized() {
        use crate::crawl::tests::TempTree;
        let tree = TempTree::new("query-network");
        let real = PathBuf::from(tree.real());
        let share = real.join("Share");
        std::os::unix::fs::symlink(real.join("Sub"), &share).unwrap();
        REMOTE.with_borrow_mut(|r| r.push(share.clone()));
        assert_eq!(resolve(&share.join("Docs/.."), &[]), Some(share.clone()));
        let mut probed = |p: &Path| -> bool { panic!("asked the share whether {p:?} is a mount") };
        let text = format!("in:{}", share.display());
        assert_eq!(
            unindexed(&q(&text), &[], &[PathBuf::from("/")], &mut probed),
            Some(share.clone())
        );
        REMOTE.with_borrow_mut(Vec::clear);
        assert_eq!(resolve(&share, &[]), Some(real.join("Sub")));
    }

    #[test]
    fn a_disk_published_during_a_pass_stays_out_of_it() {
        use crate::crawl::tests::TempTree;
        use crate::engine::tests::{bench, config};
        let tree = TempTree::new("query-pass-start");
        let root = PathBuf::from(tree.real()).join("Drive");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("early.txt"), b"").unwrap();
        let (shared, parent, _rx) = bench(config(&tree));
        let disk = Arc::new(Unit::new(
            root.clone(),
            Some("passdisk".to_owned()),
            parent.file.with_file_name("volume-passdisk.index"),
            (Vec::new(), Vec::new()),
            crate::crawl::Pool::new(2).unwrap(),
            std::sync::mpsc::channel().0,
            Arc::default(),
        ));
        let crawl = crate::crawl::scan_path(&disk.pool, &disk.root, &disk.skip, &disk.stop);
        let index = Index::build(crawl, root.clone(), &[], 1000, now_secs()).unwrap();
        let index = std::sync::Mutex::new(Some(index));
        let publish = || {
            if let Some(index) = index.lock().unwrap().take() {
                disk.install(&shared, index, crate::EnginePhase::Ready);
            }
            false
        };
        let units = [parent.clone(), disk.clone()];
        let scanned = scan_units(&q("^early"), &shared.settings, &units, &publish).unwrap();
        assert!(disk.read(|_| ()).is_some(), "the disk never published");
        let folders: Vec<String> = scanned
            .iter()
            .flat_map(|(found, _)| found.rows(0, usize::MAX))
            .map(|h| h.folder)
            .collect();
        assert_eq!(folders, [root.to_str().unwrap()]);
    }

    #[test]
    fn a_scan_notes_its_index_and_journal_point() {
        use crate::crawl::tests::{TempTree, crawl};
        use crate::engine::tests::{bench, config};
        use crate::unit::partial::Partial;
        let tree = TempTree::new("query-seen");
        let (shared, boot, _rx) = bench(config(&tree));
        let units = [boot.clone()];
        let scanned = || {
            let scanned = scan_units(&q(""), &shared.settings, &units, &|| false).unwrap();
            assert_eq!(scanned.len(), 1);
            scanned[0].0.seen
        };
        let now = || {
            boot.read(|l| Seen {
                live: l.id(),
                at: l.touched_at(),
            })
        };
        let first = scanned().expect("an installed unit's scan notes its index");
        assert_eq!(Some(first), now());
        let attrs = Attrs {
            kind: EngineKind::File,
            size: 1,
            mtime: 1,
            created: 1,
            opened: 1,
            mount: false,
            hidden: false,
        };
        let added = boot.root.join("added.txt").as_os_str().as_bytes().to_vec();
        (boot.live.write().unwrap().as_mut().unwrap()).journaled_put(added, attrs);
        let second = scanned().unwrap();
        assert_eq!(Some(second), now());
        assert_eq!(
            (second.live, second.at),
            (first.live, first.at + 1),
            "the same index, one touch on"
        );

        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        let live = Live::new(Arc::new(base));
        assert_ne!(live.id(), first.live, "every index has its own id");
        let (oracle, _) = live.scan_one(&q(""), &|| false).unwrap();
        assert_eq!(
            oracle.seen,
            Some(Seen {
                live: live.id(),
                at: live.touched_at(),
            })
        );

        let walk = walked(&mut q(""), &shared.settings, &live, &|| false).unwrap();
        assert!(
            walk[0].0.count() > 0 && walk[0].0.seen.is_none(),
            "a press's walk"
        );

        let held = [Held {
            root: PathBuf::from(tree.real()),
            boot: true,
            live,
            partial: None,
        }];
        let mut members = Members::default();
        members.add(1);
        let narrowed = narrow(&mut q(""), &shared.settings, &held, &[members], &|| false).unwrap();
        assert!(
            narrowed[0].0.count() > 0 && narrowed[0].0.seen.is_none(),
            "a narrow"
        );

        let mut partial = Partial::new(tree.0.clone(), &tree.0, false).unwrap();
        let mut listings = crawl(&tree, &[], false).listings;
        listings.sort_by_key(|l| l.id != 0);
        partial.push(&listings);
        let query = q("");
        let words = Words::new(&query);
        let places = Places::new(Path::new(HOME));
        let scan = Scan {
            q: &query,
            words: &words,
            places: &places,
            boot: false,
            within: None,
            members: None,
        };
        let (first_crawl, _) = scan.partial(partial.snapshot(), &|| false).unwrap();
        assert!(
            first_crawl.count() > 0 && first_crawl.seen.is_none(),
            "a first crawl"
        );
    }

    #[test]
    fn judging_every_entry_equals_a_full_scan() {
        use crate::crawl::Pool;
        use crate::crawl::tests::{TempTree, crawl};
        use crate::live::Disk;
        let tree = TempTree::new("query-judge");
        let hide = |rel: &str| {
            let c = CString::new(tree.0.join(rel).as_os_str().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
        };
        for dir in ["Docs", "Old", "Secret"] {
            fs::create_dir(tree.0.join(dir)).unwrap();
        }
        for (file, size) in [
            ("Docs/a.txt", 200),
            ("Docs/b.md", 10),
            ("Old/x.txt", 300),
            ("Secret/in.txt", 300),
            (".dot.txt", 300),
            ("file01.txt", 1),
            ("file1.txt", 1),
            ("big.bin", 300),
            ("gone.txt", 300),
        ] {
            fs::write(tree.0.join(file), vec![b'x'; size]).unwrap();
        }
        hide("Secret");
        let root = tree.real();
        let base = Index::build(crawl(&tree, &[], false), PathBuf::from(&root), b"", 1, 1).unwrap();
        let mut live = Live::new(Arc::new(base));
        fs::create_dir_all(tree.0.join("New/Deep")).unwrap();
        fs::create_dir(tree.0.join("Hid")).unwrap();
        for (file, size) in [
            ("New/inner.txt", 300),
            ("New/Deep/d.txt", 5),
            ("New/Deep/e.md", 400),
            ("Hid/h.txt", 300),
            ("Docs/c.txt", 150),
            ("beta.txt", 500),
        ] {
            fs::write(tree.0.join(file), vec![b'x'; size]).unwrap();
        }
        hide("Hid");
        fs::remove_file(tree.0.join("gone.txt")).unwrap();
        fs::remove_dir_all(tree.0.join("Old")).unwrap();
        let pool = Pool::new(2).unwrap();
        let stop = AtomicBool::new(false);
        let disk = Disk {
            pool: &pool,
            skip: &[],
            stop: &stop,
        };
        for folder in [root.clone(), format!("{root}/Docs")] {
            let f = live.fetch(folder.as_bytes(), false, &disk);
            live.apply(f, &disk);
        }
        assert!(
            live.over
                .values()
                .any(|a| a.kind == EngineKind::Folder && a.hidden),
            "a hidden overlay folder"
        );
        let entries = live.base.entries() as u32;
        assert!(
            (0..entries).filter(|&i| live.is_dead(i)).count() >= 3,
            "dead base entries"
        );

        let places = Places::new(Path::new("/nonexistent"));
        let ids: Vec<u32> = (0..entries).collect();
        let paths: Vec<Vec<u8>> = live.over.keys().cloned().collect();
        let some_ids: Vec<u32> = ids.iter().copied().step_by(3).collect();
        let some_paths: Vec<Vec<u8>> = paths.iter().step_by(2).cloned().collect();
        type Rows = (Vec<(u32, Hit)>, Vec<(Vec<u8>, Attrs, Hit)>);
        let rows = |found: &Found, scored: &[Hit]| -> Rows {
            assert!(found.hits.windows(2).all(|w| w[0] < w[1]), "hits ascend");
            let (base, over) = scored.split_at(found.hits.len());
            (
                found
                    .hits
                    .iter()
                    .copied()
                    .zip(base.iter().copied())
                    .collect(),
                (found.added.iter().zip(over))
                    .map(|(h, s)| (found.added_path(h, &mut None), h.attrs, *s))
                    .collect(),
            )
        };
        let mut counts = Vec::new();
        for text in ["", "kind:file", "ext:txt", "hidden:no", "size:>100"] {
            let query = Query::parse(text, "/nonexistent");
            let (full, scored) = live.scan_one(&query, &|| false).unwrap();
            let want = rows(&full, &scored);
            let (judged, scored) = judge(&query, &places, true, &live, &ids, &paths).unwrap();
            assert_eq!(rows(&judged, &scored), want, "{text}");
            let (part, scored) =
                judge(&query, &places, true, &live, &some_ids, &some_paths).unwrap();
            let (base, over) = want.clone();
            let sample = (
                base.into_iter()
                    .filter(|(i, _)| some_ids.contains(i))
                    .collect(),
                over.into_iter()
                    .filter(|(p, ..)| some_paths.contains(p))
                    .collect(),
            );
            assert_eq!(
                rows(&part, &scored),
                sample,
                "{text}, every third id and second path"
            );
            counts.push((text, want.0.len(), want.1.len()));
        }
        let (_, all_base, all_over) = counts[0];
        assert!(all_base > 0 && all_over >= 6, "{counts:?}");
        for &(text, base, over) in &counts[1..] {
            assert!(
                base + over > 0 && base + over < all_base + all_over,
                "{text} filters: {counts:?}"
            );
        }
        let hidden = counts[3];
        assert!(
            hidden.1 < all_base && hidden.2 < all_over,
            "hidden:no drops base and overlay rows"
        );
        for text in [
            "alpha",
            &format!("in:{root}/Docs"),
            "kind:file alpha",
            "size:x",
        ] {
            let query = Query::parse(text, "/nonexistent");
            assert!(
                judge(&query, &places, true, &live, &ids, &paths).is_none(),
                "{text}"
            );
        }
    }

    #[test]
    fn partial_hits_hold_no_names() {
        use crate::crawl::tests::{TempTree, crawl};
        use crate::unit::partial::Partial;
        let tree = TempTree::new("partial-hits");
        fs::create_dir(tree.0.join("Zed")).unwrap();
        for i in 1..=12 {
            fs::write(tree.0.join("Sub").join(i.to_string()), b"").unwrap();
            fs::write(tree.0.join("Zed").join(i.to_string()), b"").unwrap();
        }
        let mut crawled = crawl(&tree, &[], false);
        for listing in &mut crawled.listings {
            listing.ents.reverse();
        }
        let root = crawled.listings.iter().find(|l| l.id == 0).unwrap();
        let named: HashMap<u32, Vec<u8>> = (root.ents.iter())
            .filter(|e| e.child != crate::crawl::NONE)
            .map(|e| (e.child, root.name(e).to_vec()))
            .collect();
        crawled
            .listings
            .sort_by_key(|l| (l.id != 0, Reverse(named.get(&l.id))));
        let entries: usize = crawled.listings.iter().map(|l| l.ents.len()).sum();
        let mut partial = Partial::new(tree.0.clone(), &tree.0, false).unwrap();
        for listing in &crawled.listings {
            partial.push(std::slice::from_ref(listing));
        }
        let q = Query::parse("", HOME);
        let words = Words::new(&q);
        let places = Places::new(Path::new(HOME));
        let scan = Scan {
            q: &q,
            words: &words,
            places: &places,
            boot: false,
            within: None,
            members: None,
        };
        let (found, hits) = scan.partial(partial.snapshot(), &|| false).unwrap();
        assert_eq!(hits.len(), entries);
        assert!(
            found.added.is_empty() && found.new_dirs.is_empty(),
            "a partial hit holds a name or a folder path: {} names, {} folders",
            found.added.len(),
            found.new_dirs.len()
        );
        let rows = found.rows(0, hits.len());
        assert_eq!(rows.len(), entries);
        let mut want = rows.clone();
        want.sort_by(|a, b| {
            (a.folder.as_bytes(), a.name.as_bytes()).cmp(&(b.folder.as_bytes(), b.name.as_bytes()))
        });
        assert_eq!(rows, want);
        let numbered = [
            "1", "10", "11", "12", "2", "3", "4", "5", "6", "7", "8", "9",
        ];
        for (folder, last) in [("Sub", Some("DELTA.Txt")), ("Zed", None)] {
            let path = tree.0.join(folder);
            let names: Vec<&str> = rows
                .iter()
                .filter(|h| Path::new(&h.folder) == path)
                .map(|h| h.name.as_str())
                .collect();
            let expected: Vec<&str> = numbered.iter().copied().chain(last).collect();
            assert_eq!(names, expected, "{folder}");
        }
    }

    #[test]
    fn partial_answers_ignore_accents_both_ways() {
        use crate::crawl::tests::{TempTree, crawl};
        use crate::unit::partial::Partial;
        let tree = TempTree::new("partial-accents");
        for name in ["özet.pdf", "ozet.txt", "Unal.md", "Mu\u{308}ller.txt"] {
            fs::write(tree.0.join("Sub").join(name), b"").unwrap();
        }
        let crawled = crawl(&tree, &[], false);
        let mut partial = Partial::new(tree.0.clone(), &tree.0, false).unwrap();
        for listing in &crawled.listings {
            partial.push(std::slice::from_ref(listing));
        }
        let places = Places::new(Path::new(HOME));
        let found = |text: &str| {
            let q = Query::parse(text, HOME);
            let words = Words::new(&q);
            let scan = Scan {
                q: &q,
                words: &words,
                places: &places,
                boot: false,
                within: None,
                members: None,
            };
            let (found, hits) = scan.partial(partial.snapshot(), &|| false).unwrap();
            let mut rows: Vec<(Reverse<i32>, String)> = (found.rows(0, hits.len()).into_iter())
                .zip(&hits)
                .map(|(h, s)| (Reverse(s.score), h.name))
                .collect();
            rows.sort();
            rows.into_iter().map(|(_, n)| n).collect::<Vec<_>>()
        };
        assert_eq!(found("ozet"), ["ozet.txt", "özet.pdf"]);
        assert_eq!(found("özet"), ["özet.pdf", "ozet.txt"]);
        assert_eq!(found("ünal"), ["Unal.md"]);
        assert_eq!(found("muller"), ["Mu\u{308}ller.txt"]);
        assert_eq!(found("glob:ozet*"), ["ozet.txt", "özet.pdf"]);
        assert_eq!(found("glob:özet*"), ["özet.pdf", "ozet.txt"]);
        assert_eq!(found("ext:pdf re:^ozet"), ["özet.pdf"]);
    }
}

#[cfg(test)]
mod tree_tests {
    use crate::crawl::tests::TempTree;
    use crate::engine::tests::{Event, config, next, phases, seek, shared, start, start_with};
    use crate::engine::{BEST_MATCH, Engine};
    use crate::{EngineHit, EngineKind, EnginePhase, EngineVolume};
    use std::ffi::CString;
    use std::fs::{self, File};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc::{self, Receiver};
    use std::time::{Duration, SystemTime};

    const DAY: u64 = 86_400;

    fn put(path: &Path, len: u64, days: u64) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let f = File::create(path).unwrap();
        f.set_len(len).unwrap();
        let at = SystemTime::now() - Duration::from_secs(days * DAY);
        f.set_modified(at).unwrap();
    }

    fn flag(path: &Path) {
        let c = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
    }

    fn ask(engine: &Arc<Engine>, rx: &Receiver<Event>, query: &str) -> Vec<EngineHit> {
        let session = engine.clone().session().unwrap();
        let g = session.search(query.to_owned(), BEST_MATCH).unwrap();
        loop {
            match next(rx) {
                Event::Ready(n, count) if n == g => return session.rows(g, 0, count).unwrap(),
                Event::Fault(message) => panic!("{query}: unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn hits(engine: &Arc<Engine>, rx: &Receiver<Event>, query: &str) -> Vec<(String, String)> {
        let mut v: Vec<_> = ask(engine, rx, query)
            .into_iter()
            .map(|h| (h.name, h.folder))
            .collect();
        v.sort();
        v
    }

    fn names(engine: &Arc<Engine>, rx: &Receiver<Event>, query: &str) -> Vec<String> {
        ask(engine, rx, query).into_iter().map(|h| h.name).collect()
    }

    fn pairs(want: &[(&str, &str)]) -> Vec<(String, String)> {
        let mut v: Vec<_> = want
            .iter()
            .map(|&(n, f)| (n.to_owned(), f.to_owned()))
            .collect();
        v.sort();
        v
    }

    #[test]
    fn filters_keep_what_they_say_on_both_units() {
        let boot = TempTree::new("query-filters");
        let disk = TempTree::new("query-filters-disk");
        let work = boot.0.join("Work Files");
        put(&work.join("report.pdf"), 2000, 2);
        put(&work.join("photo.jpg"), 5_000_000, 40);
        put(&work.join("notes.md"), 10, 400);
        put(&disk.0.join("Media/clip.mov"), 0, 0);
        put(&disk.0.join("Media/song.mp3"), 3000, 0);
        let (boot_real, disk_real) = (boot.real(), disk.real());
        let (br, dr) = (boot_real.as_str(), disk_real.as_str());
        let (work_real, media_real) = (format!("{br}/Work Files"), format!("{dr}/Media"));
        let (w, m) = (work_real.as_str(), media_real.as_str());
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let volume = EngineVolume {
            root: disk.real(),
            id: "0D0D0D0D-0000-4000-8000-00000000000D".to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        let media = [("clip.mov", m), ("song.mp3", m)];
        seek(&engine, &rx, &format!("in:{dr}/Media"), &media, false);

        let given = format!("in:\"{}\"", work.display());
        let (pdf, jpg, md) = (("report.pdf", w), ("photo.jpg", w), ("notes.md", w));
        let (mov, mp3) = (("clip.mov", m), ("song.mp3", m));
        let cases: Vec<(String, Vec<(&str, &str)>)> = vec![
            ("ext:pdf".into(), vec![pdf]),
            ("ext:jpg,.MOV".into(), vec![jpg, mov]),
            ("*.{jpg,mp3}".into(), vec![jpg, mp3]),
            ("type:image".into(), vec![jpg]),
            ("type:video".into(), vec![mov]),
            ("type:audio".into(), vec![mp3]),
            (
                format!("kind:folder in:{}", boot.root()),
                vec![("Sub", br), ("Work Files", br)],
            ),
            (format!("kind:link in:{dr}"), vec![("link", dr)]),
            ("size:1mb".into(), vec![jpg]),
            ("size:2000".into(), vec![pdf]),
            ("size:1kb..3kb".into(), vec![pdf, mp3]),
            (format!("size:..2000 {given}"), vec![pdf, md]),
            (format!("size:>3kb {given}"), vec![jpg]),
            (format!("mtime:7d {given}"), vec![pdf]),
            (format!("modified:<3d {given}"), vec![pdf]),
            ("mtime:30d..60d".into(), vec![jpg]),
            ("mtime:1y..".into(), vec![md]),
            (given.clone(), vec![pdf, jpg, md]),
            (format!("in:\"{w}\""), vec![pdf, jpg, md]),
        ];
        for (query, want) in &cases {
            assert_eq!(hits(&engine, &rx, query), pairs(want), "{query}");
        }
        let (bs, ds) = (format!("{br}/Sub"), format!("{dr}/Sub"));
        let both = [("DELTA.Txt", bs.as_str()), ("DELTA.Txt", ds.as_str())];
        assert_eq!(hits(&engine, &rx, "^delta"), pairs(&both));
        let on_boot = format!("^delta in:{}", boot.root());
        assert_eq!(hits(&engine, &rx, &on_boot), pairs(&both[..1]));
        let on_disk = format!("^delta in:{}", disk.root());
        assert_eq!(hits(&engine, &rx, &on_disk), pairs(&both[1..]));
        assert!(hits(&engine, &rx, &format!("in:{br}/missing")).is_empty());
        assert!(hits(&engine, &rx, "in:Work").is_empty());
    }

    #[test]
    fn size_never_keeps_folders_or_links() {
        let boot = TempTree::new("query-size-files");
        let br = boot.real();
        let sub = format!("{br}/Sub");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let (alpha, beta, gamma) = (
            ("Alpha.TXT", br.as_str()),
            ("beta.txt", br.as_str()),
            ("Gamma.md", br.as_str()),
        );
        let delta = ("DELTA.Txt", sub.as_str());
        let cases = [
            ("size:<=1mb".to_owned(), vec![alpha, beta, gamma, delta]),
            (
                format!("size:<=1mb in:{br}"),
                vec![alpha, beta, gamma, delta],
            ),
            ("size:0".to_owned(), vec![beta, gamma, delta]),
            (format!("size:0 in:{br}"), vec![beta, gamma, delta]),
        ];
        for (query, want) in &cases {
            assert_eq!(hits(&engine, &rx, query), pairs(want), "{query}");
        }
        assert_eq!(
            hits(&engine, &rx, "^sub").len(),
            1,
            "no size filter still lists the folder"
        );
    }

    #[test]
    fn in_volumes_finds_files_on_an_indexed_disk_below_it() {
        let boot = TempTree::new("query-volumes");
        put(&boot.0.join("Volumes/note.txt"), 0, 0);
        put(&boot.0.join("Volumes/Disk 1/Docs/plan.txt"), 0, 0);
        let br = boot.real();
        let (v, d) = (format!("{br}/Volumes"), format!("{br}/Volumes/Disk 1"));
        let docs = format!("{d}/Docs");
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let volume = EngineVolume {
            root: d.clone(),
            id: "0E0E0E0E-0000-4000-8000-00000000000E".to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        seek(&engine, &rx, &format!("^plan in:\"{br}\""), &[], false);
        seek(
            &engine,
            &rx,
            &format!("^plan in:\"{d}\""),
            &[("plan.txt", &docs)],
            false,
        );
        let both = [("note.txt", v.as_str()), ("plan.txt", docs.as_str())];
        seek(&engine, &rx, &format!("ext:txt in:\"{v}\""), &both, false);
        assert!(hits(&engine, &rx, &format!("^plan in:\"{br}\"")).is_empty());
    }

    #[test]
    fn in_an_excluded_folder_finds_nothing_and_opens_nothing() {
        let tree = TempTree::new("query-excluded");
        let target = tree.0.join("Indexed/target");
        put(&target.join("t1.txt"), 0, 0);
        put(&target.join("t2.txt"), 0, 0);
        let desktop = tree.0.join("home/Desktop");
        fs::create_dir_all(&desktop).unwrap();
        std::os::unix::fs::symlink(&target, desktop.join("link")).unwrap();
        let mut config = config(&tree);
        config.excluded = vec![desktop.to_str().unwrap().to_owned()];
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) = start_with(config, Some((EnginePhase::Crawling, 0, hold)));
        assert!(matches!(next(&rx), Event::State(s) if s.phase == EnginePhase::Crawling));
        let opens = Arc::new(AtomicUsize::new(0));
        let counted = opens.clone();
        *shared(&engine).opened.lock().unwrap() = Some(Arc::new(move |_: &AtomicBool| {
            counted.fetch_add(1, Ordering::Relaxed);
        }));
        release.send(None).unwrap();
        phases(&rx);
        assert_eq!(opens.load(Ordering::Relaxed), 4);
        let t = format!("{}/Indexed/target", tree.real());
        let both = pairs(&[("t1.txt", t.as_str()), ("t2.txt", t.as_str())]);
        let scope = format!("in:{}", target.display());
        assert_eq!(hits(&engine, &rx, &scope), both);
        let query = format!("in:{}/home/Desktop/link", tree.real());
        let got = hits(&engine, &rx, &query);
        assert!(got.is_empty(), "{query}: {got:?}");
    }

    #[test]
    fn hidden_no_drops_flagged_dot_and_system_entries() {
        let tree = TempTree::new("query-hidden");
        let root = &tree.0;
        for p in [
            "hidflag.txt",
            ".hiddot.txt",
            ".hidfolder/hidinner.txt",
            "System/hidsys.txt",
            "hidplain.txt",
        ] {
            put(&root.join(p), 0, 0);
        }
        flag(&root.join("hidflag.txt"));
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let mut all = names(&engine, &rx, "'hid ext:txt");
        all.sort();
        let want = [
            ".hiddot.txt",
            "hidflag.txt",
            "hidinner.txt",
            "hidplain.txt",
            "hidsys.txt",
        ];
        assert_eq!(all, want);
        let shown = names(&engine, &rx, "'hid ext:txt hidden:no");
        assert_eq!(shown, ["hidplain.txt"]);
    }

    #[test]
    fn hidden_no_keeps_system_apps_but_not_hidden_children_or_libraries() {
        let tree = TempTree::new("query-system-apps");
        let visible = [
            "System/Applications/Calculator.app",
            "System/Applications/Utilities/Terminal.app",
        ];
        let hidden = [
            "System/Library/x.app",
            "Library/y.app",
            "home/Library/Mobile Documents/z.app",
            "System/Applications/.secret.app",
            "System/Applications/flagged.app",
            "System/Applications/.folder/inside.app",
            "System/Applications/flagged/child.app",
            "Library/System/Applications/nested.app",
            ".dot/System/Applications/dot.app",
        ];
        for path in visible.iter().chain(&hidden) {
            fs::create_dir_all(tree.0.join(path)).unwrap();
        }
        flag(&tree.0.join("System/Applications/flagged.app"));
        flag(&tree.0.join("System/Applications/flagged"));
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let mut all: Vec<_> = visible
            .iter()
            .chain(&hidden)
            .map(|p| {
                Path::new(p)
                    .file_name()
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        all.sort();
        let mut unfiltered = names(&engine, &rx, "type:app");
        unfiltered.sort();
        assert_eq!(unfiltered, all);
        let mut shown = names(&engine, &rx, "type:app hidden:no");
        shown.sort();
        assert_eq!(shown, ["Calculator.app", "Terminal.app"]);
        let mut again = names(&engine, &rx, "type:app");
        again.sort();
        assert_eq!(again, all);
    }

    #[test]
    fn the_hidden_flag_survives_a_save_and_a_load() {
        let tree = TempTree::new("query-hidden-saved");
        put(&tree.0.join("zqfile.txt"), 0, 0);
        put(&tree.0.join("zqdir/zqinner.txt"), 0, 0);
        flag(&tree.0.join("zqfile.txt"));
        flag(&tree.0.join("zqdir"));
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        assert_eq!(names(&engine, &rx, "'zq").len(), 3);
        drop(engine);

        let (engine, _listener, rx) = start(&tree);
        let seen = phases(&rx);
        assert_eq!(seen[0].0, EnginePhase::Loading, "{seen:?}");
        let crawled = seen.iter().any(|s| s.0 == EnginePhase::Crawling);
        assert!(!crawled, "{seen:?}");
        let dir = ask(&engine, &rx, "'zqdir");
        assert_eq!(dir.len(), 1);
        assert_eq!(dir[0].kind, EngineKind::Folder);
        let mut all = names(&engine, &rx, "'zq");
        all.sort();
        assert_eq!(all, ["zqdir", "zqfile.txt", "zqinner.txt"]);
        assert!(names(&engine, &rx, "'zq hidden:no").is_empty());
    }

    #[test]
    fn the_best_match_comes_first() {
        let tree = TempTree::new("query-order");
        let names_in = [
            "rpeort.txt",
            "annual report.txt",
            "reports-2024.txt",
            "report.pdf",
            "report",
        ];
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        for n in names_in {
            let p = tree.0.join("Same").join(n);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            File::create(&p).unwrap().set_modified(at).unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let got = names(&engine, &rx, "report");
        let mut top = got[..2.min(got.len())].to_vec();
        top.sort();
        assert_eq!(top, ["report", "report.pdf"], "{got:?}");
        assert_eq!(
            got[2..],
            ["reports-2024.txt", "annual report.txt"],
            "{got:?}"
        );
    }

    #[test]
    fn typos_rank_below_every_clean_hit() {
        let tree = TempTree::new("query-typos");
        fs::create_dir_all(tree.0.join("Applications/Rpeort.app")).unwrap();
        let deep = tree.0.join("home/Library/Caches/node_modules");
        put(&deep.join("re-port.txt"), 0, 400);
        put(&deep.join("repo art.txt"), 0, 400);
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        assert!(names(&engine, &rx, "report").is_empty());
        engine.set_typos(true).unwrap();
        assert_eq!(
            names(&engine, &rx, "report"),
            ["re-port.txt", "repo art.txt", "Rpeort.app"]
        );
    }
}

#[cfg(test)]
mod deep_tests {
    use super::*;
    use crate::crawl::tests::{TempTree, crawl};
    use crate::index::Index;
    use std::fs::File;
    use std::time::{Duration, SystemTime};

    fn live(name: &str, files: &[&str]) -> (TempTree, Live) {
        let tree = TempTree::new(name);
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        for f in files {
            File::create(tree.0.join(f))
                .unwrap()
                .set_modified(at)
                .unwrap();
        }
        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        (tree, Live::new(Arc::new(base)))
    }

    fn ask(live: &Live, text: &str) -> (Vec<String>, usize) {
        asked(live, text, false)
    }

    fn rescue(live: &Live, text: &str) -> (Vec<String>, usize) {
        asked(live, text, true)
    }

    fn asked(live: &Live, text: &str, typos: bool) -> (Vec<String>, usize) {
        let (found, hits, passes) = live.find_passes(text, typos, || false).unwrap();
        (ranked(&found, &hits), passes)
    }

    fn ranked(found: &Found, hits: &[Hit]) -> Vec<String> {
        let mut rows: Vec<_> = found
            .rows(0, usize::MAX)
            .into_iter()
            .zip(hits)
            .map(|(h, s)| (Reverse(s.score), h.name))
            .collect();
        rows.sort();
        rows.into_iter().map(|(_, n)| n).collect()
    }

    fn named(live: &Live, text: &str) -> Vec<String> {
        let mut names = ask(live, text).0;
        names.sort();
        names
    }

    fn rescued(live: &Live, text: &str) -> Vec<String> {
        let mut names = rescue(live, text).0;
        names.sort();
        names
    }

    const MADE: [&str; 6] = [
        "Alpha.TXT",
        "beta.txt",
        "Gamma.md",
        "Sub",
        "DELTA.Txt",
        "link",
    ];

    #[test]
    fn documents_and_extension_must_both_match() {
        let (_tree, live) = live(
            "pills-doc-pdf",
            &["report.pdf", "report.docx", "notes.md", "photo.jpg"],
        );
        assert_eq!(named(&live, "ext:pdf type:doc"), ["report.pdf"]);
        for text in [
            "type:doc ext:pdf",
            "report ext:pdf type:doc",
            "*.PDF type:doc",
        ] {
            assert_eq!(named(&live, text), ["report.pdf"], "{text}");
        }
        assert!(named(&live, "xeport ext:pdf type:doc").is_empty());
        assert_eq!(rescued(&live, "xeport ext:pdf type:doc"), ["report.pdf"]);
        assert!(named(&live, "ext:pdf type:doc !*.pdf").is_empty());
    }

    #[test]
    fn images_and_pdf_have_no_matches() {
        let (_tree, live) = live(
            "pills-image-pdf",
            &["report.pdf", "report.docx", "notes.md", "photo.jpg"],
        );
        assert!(named(&live, "ext:pdf type:image").is_empty());
        assert!(named(&live, "type:image *.PDF").is_empty());
    }

    #[test]
    fn dotless_i_reads_as_i_in_wildcard_and_regex() {
        let (_tree, live) = live(
            "turkish-i-patterns",
            &["kırmızı.md", "kirmizi.txt", "KIRMIZI.csv", "mavi.md"],
        );
        let both = ["KIRMIZI.csv", "kirmizi.txt", "kırmızı.md"];
        for text in [
            "glob:kirmizi*",
            "glob:kırmızı*",
            "kirmizi*",
            "kırmızı*",
            "*mızı.*",
            "re:^kirmizi",
            "re:^kırmızı",
            "re:mızı",
        ] {
            assert_eq!(named(&live, text), both, "{text}");
        }
        let kept = named(&live, "!kirmizi*");
        assert!(kept.contains(&"mavi.md".to_owned()), "{kept:?}");
        assert!(!kept.iter().any(|n| both.contains(&n.as_str())), "{kept:?}");
        assert_eq!(
            plain_pattern("^kırmızı"),
            (Some("^kirmizi".to_owned()), false)
        );
        assert_eq!(
            crate::rank::pattern_reading("kırmızı".as_bytes()).as_deref(),
            Some("kirmizi")
        );
        assert_eq!(crate::rank::reading("kırmızı".as_bytes()), None);
    }

    #[test]
    fn dotless_i_reads_as_i_in_a_walk_and_in_the_middle_of_a_name() {
        let (tree, live) = live(
            "turkish-i-walk",
            &[
                "kırmızı.md",
                "kirmizi.txt",
                "KIRMIZI.csv",
                "mavi.md",
                "dosya-ıd.txt",
                "dosya-id.txt",
                "dosya.txt",
            ],
        );
        let settings = Settings {
            root: PathBuf::from(tree.real()),
            data: PathBuf::from("/nowhere"),
            socket_folder: None,
            home: PathBuf::from("/Users/someone"),
            exclusions: Default::default(),
            typos: AtomicBool::new(false),
            paused: Arc::default(),
        };
        let walk = |text: &str| {
            let scanned = walked(
                &mut Query::parse(text, "/Users/someone"),
                &settings,
                &live,
                &|| false,
            )
            .unwrap();
            let mut names: Vec<String> = scanned
                .iter()
                .flat_map(|(found, hits)| ranked(found, hits))
                .collect();
            names.sort();
            names
        };
        let both = ["KIRMIZI.csv", "kirmizi.txt", "kırmızı.md"];
        for text in ["glob:kirmizi*", "kirmizi*", "re:^kirmizi"] {
            assert_eq!(walk(text), both, "{text}");
        }
        assert_eq!(named(&live, "glob:*id.*"), ["dosya-id.txt", "dosya-ıd.txt"]);
        assert_eq!(walk("glob:*id.*"), ["dosya-id.txt", "dosya-ıd.txt"]);
        assert_eq!(named(&live, "re:a-id"), ["dosya-id.txt", "dosya-ıd.txt"]);
        assert_eq!(
            walk("!*id.* *.txt"),
            [
                "Alpha.TXT",
                "DELTA.Txt",
                "beta.txt",
                "dosya.txt",
                "kirmizi.txt"
            ]
        );
    }

    #[test]
    fn dotless_i_matches_both_cases_in_names_and_content() {
        let (_tree, live) = live(
            "turkish-i",
            &["KIRMIZI.txt", "kırmızı.md", "x.ı", "y.I", "rapor.özet"],
        );
        for text in ["kırmızı", "KIRMIZI", "kirmizi", "KİRMİZİ"] {
            assert_eq!(named(&live, text), ["KIRMIZI.txt", "kırmızı.md"], "{text}");
        }
        for text in ["ext:i", "ext:ı", "ext:İ", "*.ı", "*.I"] {
            assert_eq!(named(&live, text), ["x.ı", "y.I"], "{text}");
        }
        assert_eq!(named(&live, "ext:ÖZET"), ["rapor.özet"]);
        assert_eq!(named(&live, "*.Özet"), ["rapor.özet"]);
        for (word, text) in [
            ("kırmızı", "KIRMIZI ELMA"),
            ("KIRMIZI", "kırmızı elma"),
            ("KİRMİZİ", "kırmızı elma"),
            ("kirmizi", "Kırmızı elma"),
        ] {
            let terms = crate::text::Terms {
                terms: vec![term(word)],
                all: true,
            };
            assert!(terms.seen().feed(text), "{word} in {text}");
        }
    }

    #[test]
    fn an_ascii_query_finds_accented_names_by_their_reading() {
        let (tree, live) = live(
            "accent-free",
            &[
                "Ünal.txt",
                "özet.pdf",
                "Mu\u{308}ller.txt",
                "Łódź.jpg",
                "özetler.md",
            ],
        );
        assert_eq!(named(&live, "unal"), ["Ünal.txt"]);
        assert_eq!(named(&live, "ozet"), ["özet.pdf", "özetler.md"]);
        assert_eq!(named(&live, "muller"), ["Mu\u{308}ller.txt"]);
        assert_eq!(named(&live, "lodz"), ["Łódź.jpg"]);
        assert!(named(&live, "ozetlwr").is_empty());
        assert_eq!(rescued(&live, "ozetlwr"), ["özetler.md"]);
        assert_eq!(named(&live, "^ozet$"), Vec::<String>::new());
        assert_eq!(named(&live, "^unal.txt$"), ["Ünal.txt"]);
        assert_eq!(named(&live, "begins:ozet"), ["özet.pdf", "özetler.md"]);
        assert_eq!(named(&live, "'dz.jp"), ["Łódź.jpg"]);
        assert!(named(&live, "!ozet").iter().all(|n| !n.contains("zet")));
        drop(live);
        fs::create_dir(tree.0.join("Sub/Ürün")).unwrap();
        File::create(tree.0.join("Sub/Ürün/fiyat.txt")).unwrap();
        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        let live = Live::new(Arc::new(base));
        assert_eq!(named(&live, "urun/fiyat"), ["fiyat.txt"]);
        assert_eq!(named(&live, "urun fiyat"), ["fiyat.txt"]);
    }

    #[test]
    fn an_accented_query_still_ranks_the_exact_accented_name_first() {
        let (_tree, live) = live("accent-first", &["özet.pdf", "ozet.pdf", "özet-eski.pdf"]);
        assert_eq!(
            ask(&live, "özet").0,
            ["özet.pdf", "ozet.pdf", "özet-eski.pdf"]
        );
        assert_eq!(
            ask(&live, "ozet").0,
            ["ozet.pdf", "özet.pdf", "özet-eski.pdf"]
        );
    }

    #[test]
    fn a_name_read_without_accents_is_found_and_a_scattered_match_is_not() {
        let (_tree, live) = live("accent-scattered", &["Ünal CV.pdf", "Journal.txt"]);
        assert_eq!(ask(&live, "unal"), (vec!["Ünal CV.pdf".to_owned()], 1));
        assert_eq!(rescue(&live, "unal"), (vec!["Ünal CV.pdf".to_owned()], 1));
    }

    #[test]
    fn an_accented_query_finds_plain_names_in_every_mode() {
        let (tree, live) = live(
            "accent-plain",
            &["ozet.pdf", "Unal.txt", "rapor-ozet.md", "ozetler.md"],
        );
        assert_eq!(
            named(&live, "özet"),
            ["ozet.pdf", "ozetler.md", "rapor-ozet.md"]
        );
        assert_eq!(named(&live, "Ünal"), ["Unal.txt"]);
        assert_eq!(named(&live, "u\u{308}nal"), ["Unal.txt"]);
        assert_eq!(named(&live, "begins:ÖZET"), ["ozet.pdf", "ozetler.md"]);
        assert_eq!(named(&live, "^özet"), ["ozet.pdf", "ozetler.md"]);
        assert_eq!(named(&live, "ends:özet.md"), ["rapor-ozet.md"]);
        assert_eq!(named(&live, "özet.md$"), ["rapor-ozet.md"]);
        assert_eq!(named(&live, "whole:özet.pdf"), ["ozet.pdf"]);
        assert_eq!(named(&live, "^özet.pdf$"), ["ozet.pdf"]);
        assert_eq!(
            named(&live, "'zét"),
            ["ozet.pdf", "ozetler.md", "rapor-ozet.md"]
        );
        assert!(named(&live, "özetlwr").is_empty());
        assert_eq!(rescued(&live, "özetlwr"), ["ozetler.md"]);
        assert!(named(&live, "!özet").iter().all(|n| !n.contains("zet")));
        drop(live);
        fs::create_dir(tree.0.join("Sub/Urun")).unwrap();
        File::create(tree.0.join("Sub/Urun/fiyat.txt")).unwrap();
        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        let live = Live::new(Arc::new(base));
        assert_eq!(named(&live, "ürün/fiyat"), ["fiyat.txt"]);
        assert_eq!(named(&live, "ürün fiyat"), ["fiyat.txt"]);
    }

    #[test]
    fn the_accented_twin_ranks_above_the_plain_one_through_every_tweak() {
        for (typed, query) in [
            ("Ünal.txt", "Ünal"),
            ("U\u{308}nal.txt", "Ünal"),
            ("özet.pdf", "o\u{308}zet"),
        ] {
            let tree = TempTree::new("accent-twin-back");
            let plain = reading(typed.as_bytes()).unwrap();
            let (old, new) = (tree.0.join(typed), tree.0.join(&plain));
            File::create(&old)
                .unwrap()
                .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000))
                .unwrap();
            File::create(&new)
                .unwrap()
                .set_modified(SystemTime::now())
                .unwrap();
            let c = CString::new(old.as_os_str().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
            let base = Index::build(
                crawl(&tree, &[], false),
                PathBuf::from(tree.real()),
                b"",
                1,
                1,
            )
            .unwrap();
            let live = Live::new(Arc::new(base));
            assert_eq!(ask(&live, query).0, [typed.to_owned(), plain], "{query}");
        }
    }

    #[test]
    fn an_accented_word_found_in_a_plain_name_takes_one_pass() {
        let (_tree, live) = live("accent-well-back", &["ozetler.pdf"]);
        assert_eq!(ask(&live, "özetler"), (vec!["ozetler.pdf".to_owned()], 1));
    }

    #[test]
    fn a_plain_query_on_plain_names_runs_no_accent_free_pass() {
        use crate::rank::FOLDS;
        let (_tree, live) = live("accent-none", &["report.pdf", "notes.md"]);
        FOLDS.with(|f| f.set(0));
        for text in [
            "report",
            "reprot",
            "re:report",
            "glob:rep*",
            "ext:pdf",
            "!*.pdf",
            "report ext:md",
        ] {
            ask(&live, text);
        }
        assert_eq!(FOLDS.with(|f| f.get()), 0);
        for text in ["rêport", "re:^rêport", "glob:rêp*"] {
            FOLDS.with(|f| f.set(0));
            ask(&live, text);
            assert!(FOLDS.with(|f| f.get()) > 0, "{text}");
        }
    }

    #[test]
    fn the_typed_twin_ranks_above_its_reading_through_every_tweak() {
        let tree = TempTree::new("accent-twin");
        let (old, new) = (tree.0.join("Unal.txt"), tree.0.join("Ünal.txt"));
        File::create(&old)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000))
            .unwrap();
        File::create(&new)
            .unwrap()
            .set_modified(SystemTime::now())
            .unwrap();
        let c = CString::new(old.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        let live = Live::new(Arc::new(base));
        assert_eq!(ask(&live, "unal").0, ["Unal.txt", "Ünal.txt"]);
        assert_eq!(ask(&live, "ünal").0, ["Ünal.txt", "Unal.txt"]);
    }

    #[test]
    fn a_word_found_through_the_reading_takes_one_pass() {
        let (_tree, live) = live("accent-well", &["özetler.pdf"]);
        assert_eq!(ask(&live, "ozetler"), (vec!["özetler.pdf".to_owned()], 1));
    }

    #[test]
    fn arabic_and_full_width_names_are_found_in_the_index() {
        for (name, queries) in [
            ("مُدَرِّس.txt", ["مدرس", "glob:مدرس*", "re:^مدرس"]),
            ("أحمد.txt", ["احمد", "glob:احمد*", "re:^احمد"]),
            ("كـتـاب.txt", ["كتاب", "glob:كتاب*", "re:^كتاب"]),
            ("احمد.txt", ["أحمد", "glob:أحمد*", "re:^أحمد"]),
            (
                "ＲＥＰＯＲＴ２０２６.pdf",
                ["report2026", "glob:report2026*", "re:^report2026"],
            ),
            (
                "report2026.pdf",
                [
                    "ＲＥＰＯＲＴ２０２６",
                    "glob:ＲＥＰＯＲＴ２０２６*",
                    "re:^ＲＥＰＯＲＴ２０２６",
                ],
            ),
            ("report.ＰＤＦ", ["ext:pdf", "ext:ＰＤＦ", "*.ＰＤＦ"]),
            ("report.أ", ["ext:ا", "ext:أ", "*.ا"]),
        ] {
            let (_tree, live) = live("arabic-width", &[name, "unrelated.txt"]);
            for query in queries {
                assert_eq!(named(&live, query), [name], "{query}");
            }
        }
        let (_tree, live) = live("width-literal", &["a．b", "a［b", "axb"]);
        assert_eq!(named(&live, "glob:a．b"), ["a．b"]);
        assert_eq!(named(&live, "re:^a．b$"), ["a．b"]);
        assert_eq!(named(&live, "glob:a［b"), ["a［b"]);
    }

    #[test]
    fn arabic_pattern_marks_fold_without_losing_the_typed_spelling() {
        let (_tree, live) = live("arabic-pattern", &["مدرس.txt", "مُدَرِّس.txt", "other.txt"]);
        for query in ["glob:مُدَرِّس*", "re:^مُدَرِّس"] {
            assert_eq!(ask(&live, query).0, ["مُدَرِّس.txt", "مدرس.txt"], "{query}");
        }
        for query in [
            "ُ",
            "re:ُ",
            "re:^ُ",
            "glob:ُ",
            "glob:*ُ*",
            "re:م*ُ",
            "re:م?ُ",
            "re:.*ُ",
            "re:.ُ",
            "re:ُ|zz",
            "re:(ُ)",
            "re:\\bُ",
            "re:zُ?",
        ] {
            assert!(
                !named(&live, query).contains(&"other.txt".to_owned()),
                "{query}"
            );
        }
    }

    #[test]
    fn folded_regex_repetitions_keep_nonempty_matches() {
        let (_tree, live) = live("arabic-pattern-repeat", &["مم", "other"]);
        assert_eq!(named(&live, "re:^م*ُ$"), ["مم"]);
        assert_eq!(named(&live, "re:^ُ|مُ+"), ["مم"]);
        assert!(named(&live, "re:^مُ+$").is_empty());
    }

    #[test]
    fn full_width_punctuation_queries_find_ascii_names() {
        for (wide, ascii) in [("％", "%"), ("＃", "#")] {
            let (_tree, live) = live("width-punctuation", &[ascii, wide, "unrelated"]);
            let mut want = vec![ascii.to_owned(), wide.to_owned()];
            want.sort();
            assert_eq!(named(&live, wide), want);
            assert_eq!(named(&live, ascii), want);
        }
    }

    #[test]
    fn folded_pattern_punctuation_stays_literal() {
        for (wide, ascii) in [
            ("．", "."),
            ("＊", "*"),
            ("？", "?"),
            ("［", "["),
            ("］", "]"),
            ("（", "("),
            ("）", ")"),
            ("｛", "{"),
            ("｝", "}"),
            ("＋", "+"),
            ("＾", "^"),
            ("＄", "$"),
            ("｜", "|"),
            ("＼", "\\"),
            ("＃", "#"),
        ] {
            let wide = format!("a{wide}b");
            let ascii = format!("a{ascii}b");
            let (_tree, live) = live("width-pattern", &[&wide, &ascii, "axb", "ab", "aaab"]);
            let mut want = vec![ascii, wide.clone()];
            want.sort();
            for query in [
                format!("glob:{wide}"),
                format!("re:^{wide}$"),
                format!("re:(?x)^{wide}$"),
            ] {
                assert_eq!(named(&live, &query), want, "{query}");
            }
        }
    }

    #[test]
    fn full_width_alphanumeric_queries_fold_to_ascii() {
        for c in ('\u{ff10}'..='\u{ff19}')
            .chain('\u{ff21}'..='\u{ff3a}')
            .chain('\u{ff41}'..='\u{ff5a}')
        {
            let want = char::from_u32(c as u32 - 0xfee0)
                .unwrap()
                .to_ascii_lowercase();
            assert_eq!(fold_char(c).collect::<String>(), want.to_string());
        }
        assert_eq!(fold("Ａ　２０２６"), "a 2026");
    }

    #[test]
    fn wildcard_regex_and_extension_ignore_accents_both_ways() {
        let (_tree, live) = live(
            "accent-filters",
            &[
                "özet.pdf",
                "Unal.txt",
                "rapor.özet",
                "notlar.ozet",
                "Mu\u{308}ller.txt",
            ],
        );
        for text in ["glob:ozet*", "re:^ozet", "glob:OZET.PDF"] {
            assert_eq!(named(&live, text), ["özet.pdf"], "{text}");
        }
        for text in ["glob:ünal*", "re:^ÜNAL", "glob:u\u{308}nal.txt"] {
            assert_eq!(named(&live, text), ["Unal.txt"], "{text}");
        }
        for text in ["glob:muller*", "re:^MULLER", "glob:müller.txt"] {
            assert_eq!(named(&live, text), ["Mu\u{308}ller.txt"], "{text}");
        }
        for text in ["ext:ozet", "ext:özet", "*.OZET", "*.özet", "ext:.Özet"] {
            assert_eq!(named(&live, text), ["notlar.ozet", "rapor.özet"], "{text}");
        }
        for text in ["!*.ozet", "!*.özet"] {
            let kept = named(&live, text);
            assert!(kept.contains(&"özet.pdf".to_owned()), "{text}");
            assert!(
                !kept
                    .iter()
                    .any(|n| n.ends_with(".ozet") || n.ends_with(".özet")),
                "{text}: {kept:?}"
            );
        }
        assert_eq!(
            named(&live, "re:z.t"),
            ["notlar.ozet", "rapor.özet", "özet.pdf"]
        );
    }

    #[test]
    fn a_pattern_class_keeps_its_accented_letters() {
        let (_tree, live) = live(
            "accent-class",
            &[
                "özet.pdf",
                "ozet.pdf",
                "ayva.txt",
                "résumé.pdf",
                "[draft ozet.txt",
            ],
        );
        assert_eq!(named(&live, "re:[à-ÿ]"), ["résumé.pdf", "özet.pdf"]);
        assert_eq!(named(&live, "glob:[ö]zet*"), ["özet.pdf"]);
        let has = |text: &str, name: &str| named(&live, text).contains(&name.to_owned());
        assert!(has("re:^[^ö]+$", "ozet.pdf") && !has("re:^[^ö]+$", "özet.pdf"));
        assert!(has("re:^[a-z.]+$", "ayva.txt") && !has("re:^[a-z.]+$", "résumé.pdf"));
        assert!(!has("re:^\\p{ASCII}+$", "résumé.pdf"));
        assert!(named(&live, "re:\u{301}").is_empty());
        assert_eq!(named(&live, "re:[à-ÿ] re:^resume"), ["résumé.pdf"]);
        assert_eq!(named(&live, "glob:\"[draft özet*\""), ["[draft ozet.txt"]);
        assert_eq!(plain_pattern("^özet"), (Some("^ozet".to_owned()), false));
        assert_eq!(
            plain_pattern("(?is)^\\[draft özet.*$"),
            (Some("(?is)^\\[draft ozet.*$".to_owned()), false)
        );
        assert_eq!(plain_pattern("^Ünal[0-9]"), (None, true));
        assert_eq!(plain_pattern("^özet[à-ÿ]"), (None, true));
        assert_eq!(plain_pattern("\\p{Lu}é"), (None, true));
        assert_eq!(plain_pattern("\u{301}"), (None, false));
        assert_eq!(plain_pattern("^report.*"), (None, false));
        assert_eq!(plain_pattern("^東京"), (None, false));
    }

    #[test]
    fn the_typed_twin_ranks_first_through_every_name_filter() {
        for (typed, folded, texts) in [
            (
                ["ozet.pdf", "notlar.ozet"],
                ["özet.pdf", "notlar.özet"],
                ["glob:ozet*", "re:^ozet", "ext:ozet"],
            ),
            (
                ["özet.pdf", "notlar.özet"],
                ["ozet.pdf", "notlar.ozet"],
                ["glob:özet*", "re:^özet", "ext:özet"],
            ),
            (
                ["o\u{308}zet.pdf", "notlar.o\u{308}zet"],
                ["ozet.pdf", "notlar.ozet"],
                ["glob:özet*", "re:^özet", "ext:özet"],
            ),
        ] {
            let tree = TempTree::new("accent-filter-twin");
            for (name, secs) in typed
                .iter()
                .map(|n| (n, 1_000_000_000))
                .chain(folded.iter().map(|n| (n, 0)))
            {
                let path = tree.0.join(name);
                let at = if secs == 0 {
                    SystemTime::now()
                } else {
                    SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
                };
                File::create(&path).unwrap().set_modified(at).unwrap();
                if secs != 0 {
                    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
                    assert_eq!(unsafe { libc::chflags(c.as_ptr(), libc::UF_HIDDEN) }, 0);
                }
            }
            let base = Index::build(
                crawl(&tree, &[], false),
                PathBuf::from(tree.real()),
                b"",
                1,
                1,
            )
            .unwrap();
            let live = Live::new(Arc::new(base));
            for (text, (t, f)) in texts.iter().zip([
                (typed[0], folded[0]),
                (typed[0], folded[0]),
                (typed[1], folded[1]),
            ]) {
                assert_eq!(ask(&live, text).0, [t, f], "{text}");
            }
        }
    }

    #[test]
    fn clearing_either_filter_keeps_the_other() {
        let (_tree, live) = live(
            "pills-one",
            &["report.pdf", "report.docx", "notes.md", "photo.jpg"],
        );
        assert_eq!(named(&live, "ext:pdf"), ["report.pdf"]);
        assert_eq!(
            named(&live, "type:doc"),
            [
                "Alpha.TXT",
                "DELTA.Txt",
                "Gamma.md",
                "beta.txt",
                "notes.md",
                "report.docx",
                "report.pdf",
            ]
        );
        assert_eq!(named(&live, "type:image"), ["photo.jpg"]);
    }

    #[test]
    fn extension_filters_still_add_up() {
        let (_tree, live) = live(
            "pills-extensions",
            &["report.pdf", "report.docx", "notes.md", "photo.jpg"],
        );
        for text in ["ext:pdf ext:docx", "*.pdf ext:docx", "ext:PDF,.DOCX"] {
            assert_eq!(named(&live, text), ["report.docx", "report.pdf"], "{text}");
        }
    }

    #[test]
    fn applications_keep_folders_and_app_links() {
        let tree = TempTree::new("pills-apps");
        fs::create_dir(tree.0.join("Editor.app")).unwrap();
        std::os::unix::fs::symlink("Editor.app", tree.0.join("Alias.app")).unwrap();
        File::create(tree.0.join("pretend.app")).unwrap();
        let base = Index::build(
            crawl(&tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap();
        let live = Live::new(Arc::new(base));
        assert_eq!(named(&live, "type:app"), ["Alias.app", "Editor.app"]);
        assert_eq!(
            named(&live, "type:app ext:app"),
            ["Alias.app", "Editor.app"]
        );
        assert!(named(&live, "type:app ext:pdf").is_empty());
    }

    #[test]
    fn several_kinds_still_add_up() {
        let (_tree, live) = live(
            "pills-kinds",
            &[
                "report.pdf",
                "report.docx",
                "notes.md",
                "photo.jpg",
                "code.rs",
            ],
        );
        for text in ["type:doc type:image", "type:doc,image"] {
            assert_eq!(
                named(&live, text),
                [
                    "Alpha.TXT",
                    "DELTA.Txt",
                    "Gamma.md",
                    "beta.txt",
                    "notes.md",
                    "photo.jpg",
                    "report.docx",
                    "report.pdf",
                ],
                "{text}"
            );
        }
        assert_eq!(
            named(&live, "type:doc type:image ext:pdf,jpg"),
            ["photo.jpg", "report.pdf"]
        );
    }

    #[test]
    fn literal_name_modes_find_only_the_typed_names() {
        let (_tree, live) = live(
            "literal-names",
            &[
                "Mom's notes",
                "a!draft",
                "x.draft",
                "are:x",
                "x",
                "a*.pdf",
                "a.pdf",
                "v1$notes",
                "v1",
                "'x",
                "'xy",
                "annual report.pdf",
                "my annual report.pdf",
                "abc-start",
                "end-abc",
            ],
        );
        for (text, want) in [
            (r#"ends:"'s notes""#, "Mom's notes"),
            (r#"ends:"!draft""#, "a!draft"),
            (r#"ends:"re:x""#, "are:x"),
            (r#"ends:"*.pdf""#, "a*.pdf"),
            (r#"begins:"v1$""#, "v1$notes"),
            (r#"whole:"'x""#, "'x"),
            (r#"begins:"annual report""#, "annual report.pdf"),
            ("^abc", "abc-start"),
            ("abc$", "end-abc"),
        ] {
            assert_eq!(named(&live, text), [want], "{text}");
        }
        assert_eq!(
            named(&live, r#"begins:"annual report""#),
            named(&live, r#"^"annual report""#)
        );
        let excluded = named(&live, "!draft");
        assert!(!excluded.iter().any(|n| n.contains("draft")));
        assert!(excluded.contains(&"Mom's notes".to_owned()));
    }

    #[test]
    fn re_matches_the_whole_name_as_a_regular_expression() {
        let (_tree, live) = live("re-names", &["Report.pdf", "report.pdf.zip"]);
        assert_eq!(named(&live, r#"re:"^rep.*\.pdf$""#), ["Report.pdf"]);
        assert!(named(&live, r#"re:"(""#).is_empty());
        let mut all: Vec<String> = MADE
            .iter()
            .chain(&["Report.pdf", "report.pdf.zip"])
            .map(|n| n.to_string())
            .collect();
        all.sort();
        assert_eq!(named(&live, "re:."), all);
        assert_eq!(named(&live, "re:^RE re:zip$"), ["report.pdf.zip"]);
    }

    #[test]
    fn a_word_with_a_star_or_question_mark_matches_the_whole_name() {
        let owner = "Cardinal_0.1.23_aarch64.dmg";
        let files = [
            owner,
            "cardinal notes.txt",
            "my cardinal.dmg",
            "file[1].txt",
            "file1.txt",
            "a*b",
            "aXb",
            "draft-one.txt",
            "report-1.pdf",
            "report-12.pdf",
            "\u{d6}zet.pdf",
        ];
        let (_tree, live) = live("star-words", &files);
        assert_eq!(named(&live, "cardinal*.dmg"), [owner]);
        assert_eq!(named(&live, "CARDINAL*.DMG"), [owner]);
        assert_eq!(named(&live, "^cardinal*"), [owner, "cardinal notes.txt"]);
        assert_eq!(named(&live, "aarch cardinal*.dmg"), [owner]);
        assert_eq!(named(&live, "report-?.pdf"), ["report-1.pdf"]);
        assert_eq!(named(&live, "file[1]*"), ["file[1].txt"]);
        assert_eq!(named(&live, "ozet*"), ["\u{d6}zet.pdf"]);
        assert_eq!(named(&live, "a*b"), ["a*b", "aXb"]);
        assert_eq!(named(&live, "'a*b"), ["a*b"]);
        assert_eq!(named(&live, "\"a*b\""), ["a*b"]);
        let kept = named(&live, "!draft*");
        assert!(!kept.iter().any(|n| n == "draft-one.txt"), "{kept:?}");
        assert!(kept.iter().any(|n| n == owner), "{kept:?}");
        assert_eq!(
            named(&live, "cardinal"),
            [owner, "cardinal notes.txt", "my cardinal.dmg"]
        );
        assert_eq!(ask(&live, "*card*"), ask(&live, "glob:*card*"));
    }

    #[test]
    fn glob_matches_the_whole_name_against_star_question_and_classes() {
        let files = [
            "Report.pdf",
            "REPORT.txt",
            "my report.pdf",
            "a.txt",
            "b.txt",
            "\u{fc}ber.txt",
        ];
        let (_tree, live) = live("glob-names", &files);
        assert_eq!(
            named(&live, r#"glob:"rep?rt.*""#),
            ["REPORT.txt", "Report.pdf"]
        );
        assert_eq!(
            named(&live, r#"glob:"[!a]*.txt""#),
            [
                "DELTA.Txt",
                "REPORT.txt",
                "b.txt",
                "beta.txt",
                "\u{fc}ber.txt"
            ]
        );
        assert_eq!(named(&live, r#"glob:"[ab].txt""#), ["a.txt", "b.txt"]);
        assert_eq!(named(&live, "glob:\u{dc}ber*"), ["\u{fc}ber.txt"]);
        assert_eq!(named(&live, "glob:\"[\u{fc}a]ber.txt\""), ["\u{fc}ber.txt"]);
        assert_eq!(named(&live, "glob:a.t"), Vec::<String>::new());
    }

    #[test]
    fn glob_and_re_match_an_nfd_name_typed_in_nfc() {
        let (nfd, nfc) = (
            "Pra\u{308}sentation Mu\u{308}ller.key",
            "\u{c9}t\u{e9} Caf\u{e9}.txt",
        );
        let (_tree, live) = live("nfc-names", &[nfd, nfc]);
        let found = |text: &str| named(&live, text);
        assert_eq!(found("re:Pr\u{e4}s"), [nfd]);
        assert_eq!(found("re:\"m\u{fc}ller\\.key$\""), [nfd]);
        assert_eq!(found("glob:\"Pr\u{e4}*\""), [nfd]);
        assert_eq!(found("glob:\"Pr?sentation*\""), [nfd]);
        assert_eq!(found("begins:Pr\u{e4}s"), [nfd]);
        assert_eq!(found("ends:M\u{fc}ller.key"), [nfd]);
        assert_eq!(found("re:^E\u{301}te\u{301}"), [nfc]);
        assert_eq!(found("glob:\"*Cafe\u{301}.txt\""), [nfc]);
        assert_eq!(found("glob:\"?te\u{301} *\""), [nfc]);
        assert_eq!(found("begins:E\u{301}te\u{301}"), [nfc]);
        assert_eq!(found("ends:Cafe\u{301}.txt"), [nfc]);
        assert_eq!(found("glob:\"Pr\u{e1}*\""), [nfd]);
        assert_eq!(found("glob:\"Pr\u{f6}*\""), Vec::<String>::new());
        assert_eq!(found("re:Pr\u{f6}s"), Vec::<String>::new());
    }

    #[test]
    fn the_switch_off_never_rescues() {
        let (_tree, live) = live(
            "rescue-off",
            &["explorer.txt", "hell.txt", "hell", "hallo.md"],
        );
        assert_eq!(ask(&live, "epxlorer"), (Vec::<String>::new(), 1));
        assert_eq!(ask(&live, "hello"), (Vec::<String>::new(), 1));
    }

    #[test]
    fn the_switch_on_rescues_only_when_nothing_is_side_by_side() {
        let (_tree, live) = live(
            "rescue-on",
            &["hello.txt", "hell.txt", "hallo.md", "explorer.txt"],
        );
        assert_eq!(rescue(&live, "hello"), (vec!["hello.txt".to_owned()], 1));
        assert_eq!(
            rescue(&live, "epxlorer"),
            (vec!["explorer.txt".to_owned()], 2)
        );
    }

    #[test]
    fn a_signed_word_never_rescues() {
        let (_tree, live) = live("rescue-signed", &["explorer.txt"]);
        for text in ["'epxlorer", "^epxlorer", "epxlorer$", "begins:epxlorer"] {
            assert_eq!(rescue(&live, text), (Vec::<String>::new(), 1), "{text}");
        }
    }

    #[test]
    fn a_typo_inside_another_name_hides_the_rescue() {
        let (_tree, live) = live("rescue-hidden", &["Phelonius.txt", "hello.txt"]);
        assert_eq!(rescue(&live, "helo"), (vec!["Phelonius.txt".to_owned()], 1));
    }

    #[test]
    fn a_swap_after_the_right_first_letter_takes_no_deep_pass() {
        let (_tree, live) = live("deep-swap", &["explorer.txt"]);
        assert_eq!(
            rescue(&live, "epxlorer"),
            (vec!["explorer.txt".to_owned()], 2)
        );
    }

    #[test]
    fn a_wrong_first_letter_is_found_only_by_the_deep_pass() {
        let (_tree, live) = live("deep-first", &["report.txt", "keyboard.txt"]);
        assert_eq!(rescue(&live, "xeport"), (vec!["report.txt".to_owned()], 3));
        assert_eq!(
            rescue(&live, "jeyboard"),
            (vec!["keyboard.txt".to_owned()], 3)
        );
        let q = Query::parse("xeport", "/nonexistent").loosened();
        assert!(live.scan_one(&q, &|| false).unwrap().1.is_empty());
    }

    #[test]
    fn two_swaps_need_eight_letters_and_the_deep_pass() {
        let (_tree, live) = live("deep-two", &["document.pdf", "picture.png"]);
        assert_eq!(
            rescue(&live, "docmunet"),
            (vec!["document.pdf".to_owned()], 3)
        );
        assert_eq!(rescue(&live, "pcitrue"), (Vec::<String>::new(), 3));
    }

    #[test]
    fn a_digit_is_never_edited_by_the_deep_pass() {
        let (_tree, live) = live("deep-digit", &["report.txt"]);
        assert_eq!(rescue(&live, "rep0rt"), (Vec::<String>::new(), 3));
    }

    #[test]
    fn a_well_found_word_takes_one_pass() {
        let (_tree, live) = live("deep-well", &["report.txt"]);
        assert_eq!(rescue(&live, "report"), (vec!["report.txt".to_owned()], 1));
    }

    #[test]
    fn a_word_nobody_has_well_takes_the_deep_pass_and_its_answer_stands() {
        let (_tree, live) = live("deep-stands", &["reports.txt", "rpeort.txt"]);
        assert_eq!(rescue(&live, "report").1, 1);
        assert_eq!(rescue(&live, "xeport"), (vec!["reports.txt".to_owned()], 3));
    }

    #[test]
    fn only_the_pass_that_finds_rows_walks_the_index() {
        let (_tree, live) = live("walk-rescue", &["report.txt"]);
        let walked = |run: &dyn Fn() -> (Vec<String>, usize)| {
            let before = entries_walked();
            let got = run();
            (got, entries_walked() - before)
        };
        let report = vec!["report.txt".to_owned()];
        let ((rows, passes), all) = walked(&|| ask(&live, "report"));
        assert_eq!((rows, passes), (report.clone(), 1));
        assert!(all > 0);
        assert_eq!(
            walked(&|| ask(&live, "xeport")),
            ((Vec::new(), 1), 0),
            "xeport, switch off"
        );
        assert_eq!(
            walked(&|| rescue(&live, "reprot")),
            ((report.clone(), 2), all),
            "reprot, switch on"
        );
        assert_eq!(
            walked(&|| rescue(&live, "xeport")),
            ((report, 3), all),
            "xeport, switch on"
        );
    }

    #[test]
    fn a_word_only_in_a_new_file_is_found_without_the_walk() {
        let (tree, mut live) = live("walk-overlay", &["report.txt"]);
        let attrs = Attrs {
            kind: EngineKind::File,
            size: 1,
            mtime: 1_700_000_000,
            created: 0,
            opened: 0,
            mount: false,
            hidden: false,
        };
        let path = Path::new(&tree.real()).join("zzq-new.txt");
        live.over
            .insert(path.as_os_str().as_bytes().to_vec(), attrs);
        let before = entries_walked();
        assert_eq!(ask(&live, "zzq"), (vec!["zzq-new.txt".to_owned()], 1));
        assert_eq!(entries_walked() - before, 0);
    }

    #[test]
    fn a_clean_match_ranks_above_one_edit_above_two() {
        let (_tree, live) = live(
            "deep-order",
            &["docmunet.pdf", "documnet.pdf", "document.pdf"],
        );
        let (found, hits) = live
            .scan_one(
                &Query::parse("document", "/nonexistent").loosened().deepen(),
                &|| false,
            )
            .unwrap();
        assert_eq!(
            ranked(&found, &hits),
            ["document.pdf", "documnet.pdf", "docmunet.pdf"]
        );
        let tier = |n: &str| {
            let i = found.rows(0, usize::MAX).iter().position(|h| h.name == n);
            hits[i.unwrap()].score < -TYPO_LAST / 2
        };
        assert!(!tier("document.pdf") && tier("documnet.pdf") && tier("docmunet.pdf"));
    }

    #[test]
    fn a_cancelled_first_pass_ends_the_search() {
        let (_tree, live) = live("deep-cancel", &["report.txt"]);
        assert!(live.find_passes("xeport", false, || true).is_none());
    }

    #[test]
    fn a_cancel_during_the_deep_pass_ends_the_search() {
        let (_tree, live) = live("deep-cancel-2", &["report.txt"]);
        let calls = std::cell::Cell::new(0);
        let mut q = Query::parse("xeport", "/nonexistent");
        let got = retry(&mut q, true, |q| {
            calls.set(calls.get() + 1);
            let cancel = calls.get() == 3;
            live.scan_one(q, &|| cancel).map(|one| vec![one])
        });
        assert!(got.is_none());
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn the_name_table_is_scored_in_pieces_and_equals_the_serial_table() {
        use crate::engine::timing::{BOOT, unit};

        let threads = rayon::current_num_threads();
        for (names, want) in [
            (0, 1),
            (1, 1),
            (INLINE_NAMES, 1),
            (INLINE_NAMES + 1, (threads * 4).min(INLINE_NAMES + 1)),
            (1_000_000, threads * 4),
        ] {
            assert_eq!(pieces(names), want, "{names} names");
        }
        let small = Index::build(
            unit(6_252, BOOT).crawl,
            PathBuf::from("/Volumes/Disk2"),
            b"print",
            1,
            1,
        )
        .unwrap();
        assert!(small.names() <= INLINE_NAMES, "{} names", small.names());
        let q = Query::parse("report", "/nonexistent");
        let w = Words::new(&q);
        assert_eq!(
            score_names(&w, &small, pieces(small.names()), &|| false)
                .unwrap()
                .1,
            1
        );
        for (text, loose) in [("report", false), ("rep doc !tmp", false), ("reprot", true)] {
            let query = Query::parse(text, "/nonexistent");
            let query = if loose { query.loosened() } else { query };
            let w = Words::new(&query);
            let npos = w.pos.len();
            for (root, n) in [
                ("/timing", 59_775),
                ("/Volumes/Disk1", 33_973),
                ("/Volumes/Disk2", 20_000),
            ] {
                let index =
                    Index::build(unit(n, BOOT).crawl, PathBuf::from(root), b"print", 1, 1).unwrap();
                let names = index.names();
                assert!(names > INLINE_NAMES, "{root}: {names} names");
                let (table, count) = score_names(&w, &index, pieces(names), &|| false).unwrap();
                assert_eq!(count, threads * 4, "{root}: pieces");
                assert_eq!(score_names(&w, &index, 1, &|| false).unwrap().1, 1);
                assert_eq!(
                    (table.rows.len(), table.scores.len()),
                    (names, names * npos)
                );
                let mut matched = 0;
                for k in 0..names {
                    let mut scores = vec![0; npos];
                    let row = w.row(&Name::new(index.name(k)), &mut scores);
                    let (got, got_scores) = table.get(k);
                    assert_eq!(
                        (got.bits, got.typo, got.neg),
                        (row.bits, row.typo, row.neg),
                        "{root} name {k}"
                    );
                    assert_eq!(got_scores, &scores[..], "{root} name {k}");
                    matched += usize::from(row.bits != 0);
                }
                println!("{root}, {text:?}: {names} names, {count} pieces, {matched} matched");
                assert!(matched > 0, "{root}: nothing matched {text:?}");
            }
        }
    }

    #[test]
    fn a_cancel_inside_the_name_table_stops_the_remaining_pieces() {
        use crate::engine::timing::{BOOT, unit};
        use std::sync::atomic::{AtomicUsize, Ordering};

        let index = Index::build(
            unit(20_000, BOOT).crawl,
            PathBuf::from("/timing"),
            b"print",
            1,
            1,
        )
        .unwrap();
        assert!(index.names() > INLINE_NAMES, "{} names", index.names());
        let total = pieces(index.names());
        assert!(total > 1);
        let query = Query::parse("report", "/nonexistent");
        let w = Words::new(&query);

        let (reads, scored) = (AtomicUsize::new(0), AtomicUsize::new(0));
        let cancel = || {
            let stop = reads.fetch_add(1, Ordering::SeqCst) > 0;
            if !stop {
                scored.fetch_add(1, Ordering::SeqCst);
            }
            stop
        };
        assert!(score_names(&w, &index, total, &cancel).is_none());
        let scored = scored.into_inner();
        println!(
            "{scored} of {total} pieces scored, {} reads",
            reads.into_inner()
        );
        assert_eq!(scored, 1);

        let live = Live::new(Arc::new(index));
        let reads = AtomicUsize::new(0);
        let got = live.scan_one(&query, &|| reads.fetch_add(1, Ordering::SeqCst) > 0);
        assert!(got.is_none());
        assert!(reads.into_inner() >= 2);
    }
}
