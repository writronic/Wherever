use std::collections::HashMap;

use encoding_rs::{
    BIG5, EUC_KR, Encoding, GBK, MACINTOSH, SHIFT_JIS, UTF_8, WINDOWS_874, WINDOWS_1250,
    WINDOWS_1251, WINDOWS_1252, WINDOWS_1253, WINDOWS_1254, WINDOWS_1255, WINDOWS_1256,
    WINDOWS_1257, WINDOWS_1258,
};

const MAX_DEPTH: usize = 256;
const MAX_FONTS: usize = 1024;
const MAX_UC: i64 = 16;

#[rustfmt::skip]
const SKIPPED: &[&[u8]] = &[
    b"colortbl", b"stylesheet", b"info", b"pict", b"header", b"footer", b"object", b"themedata", b"colorschememapping",
    b"latentstyles", b"datastore", b"generator", b"listtable", b"listoverridetable", b"rsidtbl", b"xmlnstbl", b"fldinst",
];

#[derive(Clone, Copy)]
struct Group {
    skip: bool,
    fonttbl: bool,
    uc: usize,
    font: Option<i64>,
}

struct Reader {
    out: String,
    raw: Vec<u8>,
    code_page: &'static Encoding,
    fonts: HashMap<i64, &'static Encoding>,
    deff: i64,
    defining: i64,
    high: Option<u16>,
    drop: usize,
}

pub(crate) fn text(b: &[u8]) -> Option<String> {
    if !b.starts_with(b"{\\rtf") {
        return None;
    }
    let mut r = Reader {
        out: String::new(),
        raw: Vec::new(),
        code_page: WINDOWS_1252,
        fonts: HashMap::new(),
        deff: 0,
        defining: 0,
        high: None,
        drop: 0,
    };
    let mut g = Group {
        skip: false,
        fonttbl: false,
        uc: 1,
        font: None,
    };
    let mut stack: Vec<Group> = Vec::new();
    let mut over = 0usize;
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        i += 1;
        if !matches!(c, b'\r' | b'\n' | 0x80..) && !(c == b'\\' && b.get(i) == Some(&b'\'')) {
            r.flush(&g);
        }
        match c {
            b'{' => {
                if stack.len() < MAX_DEPTH {
                    stack.push(g);
                } else {
                    over += 1;
                }
            }
            b'}' => {
                if over > 0 {
                    over -= 1;
                } else if let Some(p) = stack.pop() {
                    g = p;
                }
            }
            b'\r' | b'\n' => {}
            b'\\' => {
                let Some(&n) = b.get(i) else { break };
                i += 1;
                match n {
                    b'\\' | b'{' | b'}' => {
                        if r.take(&g) {
                            r.out.push(n as char);
                        }
                    }
                    b'\'' => {
                        let hex = |k: usize| b.get(i + k).and_then(|&d| (d as char).to_digit(16));
                        if let (Some(h), Some(l)) = (hex(0), hex(1)) {
                            i += 2;
                            if r.take(&g) {
                                r.raw.push((h * 16 + l) as u8);
                            }
                        }
                    }
                    b'*' => g.skip = true,
                    b'~' if !g.skip => r.out.push(' '),
                    b'_' if !g.skip => r.out.push('-'),
                    b'\n' | b'\r' if !g.skip => r.out.push('\n'),
                    b'a'..=b'z' | b'A'..=b'Z' => {
                        let start = i - 1;
                        while b.get(i).is_some_and(u8::is_ascii_alphabetic) {
                            i += 1;
                        }
                        let word = &b[start..i];
                        let negative = b.get(i) == Some(&b'-');
                        i += usize::from(negative);
                        let mut num: Option<i64> = None;
                        while let Some(d) = b.get(i).filter(|d| d.is_ascii_digit()) {
                            let n = num
                                .unwrap_or(0)
                                .saturating_mul(10)
                                .saturating_add(i64::from(d - b'0'));
                            num = Some(n);
                            i += 1;
                        }
                        if negative {
                            num = num.map(|n| -n);
                        }
                        i += usize::from(b.get(i) == Some(&b' '));
                        r.word(&mut g, word, num, &mut i, b.len());
                    }
                    _ => {}
                }
            }
            _ => {
                if r.take(&g) {
                    if c >= 0x80 {
                        r.raw.push(c);
                    } else {
                        r.out.push(c as char);
                    }
                }
            }
        }
    }
    r.flush(&g);
    Some(r.out)
}

impl Reader {
    fn take(&mut self, g: &Group) -> bool {
        if self.drop > 0 {
            self.drop -= 1;
            return false;
        }
        !g.skip
    }

    fn flush(&mut self, g: &Group) {
        if self.raw.is_empty() {
            return;
        }
        let font = g.font.unwrap_or(self.deff);
        let enc = self.fonts.get(&font).copied().unwrap_or(self.code_page);
        self.out
            .push_str(&enc.decode_without_bom_handling(&self.raw).0);
        self.raw.clear();
    }

    fn word(&mut self, g: &mut Group, word: &[u8], num: Option<i64>, i: &mut usize, len: usize) {
        match word {
            b"fonttbl" => {
                g.skip = true;
                g.fonttbl = true;
            }
            w if SKIPPED.contains(&w) => g.skip = true,
            b"ansicpg" => self.code_page = code_page(num.unwrap_or(1252)),
            b"deff" => self.deff = num.unwrap_or(0),
            b"f" if g.fonttbl => self.defining = num.unwrap_or(0),
            b"f" => g.font = num,
            b"fcharset" if g.fonttbl => {
                if let Some(enc) = num
                    .and_then(charset)
                    .filter(|_| self.fonts.len() < MAX_FONTS)
                {
                    self.fonts.insert(self.defining, enc);
                }
            }
            b"uc" => g.uc = num.unwrap_or(1).clamp(0, MAX_UC) as usize,
            b"u" if !g.skip => self.unicode(num.unwrap_or(0), g.uc),
            b"bin" => *i = i.saturating_add(num.unwrap_or(0).max(0) as usize).min(len),
            _ => {
                if !g.skip {
                    self.out.extend(symbol(word));
                }
            }
        }
    }

    fn unicode(&mut self, n: i64, uc: usize) {
        let unit = n as u16;
        match (self.high.take(), unit) {
            (Some(h), 0xDC00..=0xDFFF) => self.out.extend(char::decode_utf16([h, unit]).flatten()),
            (_, 0xD800..=0xDBFF) => self.high = Some(unit),
            _ => self.out.extend(char::from_u32(unit.into())),
        }
        self.drop = uc;
    }
}

fn symbol(word: &[u8]) -> Option<char> {
    Some(match word {
        b"par" | b"line" | b"sect" | b"page" => '\n',
        b"tab" => '\t',
        b"emspace" | b"enspace" | b"qmspace" => ' ',
        b"bullet" => '\u{2022}',
        b"endash" => '\u{2013}',
        b"emdash" => '\u{2014}',
        b"lquote" => '\u{2018}',
        b"rquote" => '\u{2019}',
        b"ldblquote" => '\u{201C}',
        b"rdblquote" => '\u{201D}',
        _ => return None,
    })
}

fn code_page(n: i64) -> &'static Encoding {
    match n {
        874 => WINDOWS_874,
        932 => SHIFT_JIS,
        936 => GBK,
        949 => EUC_KR,
        950 => BIG5,
        1250 => WINDOWS_1250,
        1251 => WINDOWS_1251,
        1253 => WINDOWS_1253,
        1254 => WINDOWS_1254,
        1255 => WINDOWS_1255,
        1256 => WINDOWS_1256,
        1257 => WINDOWS_1257,
        1258 => WINDOWS_1258,
        10000 => MACINTOSH,
        65001 => UTF_8,
        _ => WINDOWS_1252,
    }
}

fn charset(n: i64) -> Option<&'static Encoding> {
    Some(match n {
        128 => SHIFT_JIS,
        129 => EUC_KR,
        134 => GBK,
        136 => BIG5,
        161 => WINDOWS_1253,
        162 => WINDOWS_1254,
        163 => WINDOWS_1258,
        177 => WINDOWS_1255,
        178..=180 => WINDOWS_1256,
        186 => WINDOWS_1257,
        204 => WINDOWS_1251,
        222 => WINDOWS_874,
        238 => WINDOWS_1250,
        _ => return None,
    })
}
