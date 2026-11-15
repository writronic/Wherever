use std::path::Path;

use encoding_rs::{Decoder, Encoding, UTF_8};

use super::scope::ext;

const LINE: usize = 64 << 10;
const HEADER: usize = 16 << 10;
const DEPTH: usize = 32;
const BOUNDARY: usize = 70;
const FLUSH: usize = 64 << 10;
const READ_HEADERS: &[&[u8]] = &[b"subject", b"from", b"to", b"cc", b"bcc", b"reply-to"];

#[derive(Clone, Copy, PartialEq)]
enum Format {
    Eml,
    Emlx,
    Mbox,
}

#[derive(Clone, Copy, PartialEq)]
enum At {
    Count,
    Head,
    Body,
    Skip,
}

#[derive(Clone, Copy, PartialEq)]
enum Transfer {
    Plain,
    Base64,
    Quoted,
}

struct Part {
    kind: Vec<u8>,
    boundary: Option<Vec<u8>>,
    charset: &'static Encoding,
    transfer: Transfer,
}

impl Part {
    fn new() -> Part {
        Part {
            kind: Vec::new(),
            boundary: None,
            charset: UTF_8,
            transfer: Transfer::Plain,
        }
    }
}

pub(crate) struct Mail {
    format: Format,
    at: At,
    line: Vec<u8>,
    header: Vec<u8>,
    part: Part,
    boundaries: Vec<Vec<u8>>,
    decoder: Option<Decoder>,
    bits: (u32, u8),
    left: u64,
    blank: bool,
    out: String,
}

impl Mail {
    pub(crate) fn new(path: &Path) -> Option<Mail> {
        let (e, name) = (ext(path), path.file_name().map(|n| n.as_encoded_bytes()));
        let format = if e.eq_ignore_ascii_case(b"eml") {
            Format::Eml
        } else if e.eq_ignore_ascii_case(b"emlx") {
            Format::Emlx
        } else if e.eq_ignore_ascii_case(b"mbox") || name == Some(&b"mbox"[..]) {
            Format::Mbox
        } else {
            return None;
        };
        Some(Mail {
            format,
            at: if format == Format::Emlx {
                At::Count
            } else {
                At::Head
            },
            line: Vec::new(),
            header: Vec::new(),
            part: Part::new(),
            boundaries: Vec::new(),
            decoder: None,
            bits: (0, 0),
            left: u64::MAX,
            blank: true,
            out: String::new(),
        })
    }

    pub(crate) fn feed(
        &mut self,
        mut bytes: &[u8],
        last: bool,
        seen: &mut dyn FnMut(&str) -> bool,
    ) -> bool {
        let mut end = last;
        while !bytes.is_empty() {
            let seg = bytes
                .iter()
                .position(|&b| b == b'\n')
                .map_or(bytes.len(), |n| n + 1);
            let (mut piece, rest) = bytes.split_at(seg);
            bytes = rest;
            if self.at != At::Count {
                if piece.len() as u64 >= self.left {
                    piece = &piece[..self.left as usize];
                    bytes = &[];
                    end = true;
                }
                self.left -= piece.len() as u64;
            }
            let ended = piece.last() == Some(&b'\n');
            if self.push(piece.strip_suffix(b"\n").unwrap_or(piece), ended, seen) {
                return true;
            }
        }
        if !end {
            return false;
        }
        if !self.line.is_empty() {
            let line = std::mem::take(&mut self.line);
            if self.read_line(&line, seen) {
                return true;
            }
        }
        self.header_done();
        self.end_part();
        self.flush(seen, true);
        true
    }

    fn push(&mut self, mut piece: &[u8], ended: bool, seen: &mut dyn FnMut(&str) -> bool) -> bool {
        loop {
            let (now, rest) = piece.split_at((LINE - self.line.len()).min(piece.len()));
            self.line.extend_from_slice(now);
            piece = rest;
            if self.line.len() < LINE && !(ended && piece.is_empty()) {
                return false;
            }
            let mut line = std::mem::take(&mut self.line);
            let stop = self.read_line(&line, seen);
            line.clear();
            self.line = line;
            if stop {
                return true;
            }
            if piece.is_empty() {
                return false;
            }
        }
    }

    fn read_line(&mut self, line: &[u8], seen: &mut dyn FnMut(&str) -> bool) -> bool {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let blank = std::mem::replace(&mut self.blank, line.is_empty());
        if self.at == At::Count {
            self.at = At::Head;
            match std::str::from_utf8(line)
                .ok()
                .and_then(|n| n.trim().parse().ok())
            {
                Some(n) => {
                    self.left = n;
                    return false;
                }
                None => self.left = u64::MAX,
            }
        }
        if self.format == Format::Mbox && blank && line.starts_with(b"From ") {
            self.header_done();
            self.end_part();
            self.boundaries.clear();
            self.new_part();
            self.out.push('\n');
            return self.flush(seen, false);
        }
        if let Some(rest) = line.strip_prefix(b"--")
            && let Some(i) = self.boundaries.iter().rposition(|b| at_boundary(rest, b))
        {
            self.header_done();
            self.end_part();
            let close = rest[self.boundaries[i].len()..].starts_with(b"--");
            self.boundaries.truncate(i + usize::from(!close));
            if close {
                self.at = At::Skip;
            } else {
                self.new_part();
            }
            self.out.push('\n');
            return self.flush(seen, false);
        }
        match self.at {
            At::Count | At::Skip => {}
            At::Head if line.is_empty() => {
                self.header_done();
                self.start_body();
            }
            At::Head => {
                if !line.starts_with(b" ") && !line.starts_with(b"\t") {
                    self.header_done();
                }
                let room = HEADER.saturating_sub(self.header.len());
                self.header.extend_from_slice(&line[..room.min(line.len())]);
            }
            At::Body => self.body(line),
        }
        self.flush(seen, false)
    }

    fn new_part(&mut self) {
        self.at = At::Head;
        self.part = Part::new();
        self.header.clear();
    }

    fn header_done(&mut self) {
        let header = std::mem::take(&mut self.header);
        if let Some(colon) = header.iter().position(|&b| b == b':') {
            let (name, value) = (
                header[..colon].trim_ascii(),
                header[colon + 1..].trim_ascii(),
            );
            if name.eq_ignore_ascii_case(b"content-type") {
                let kind = value.split(|&b| b == b';').next().unwrap_or(value);
                self.part.kind = kind.trim_ascii().to_ascii_lowercase();
                self.part.boundary = param(value, b"boundary")
                    .filter(|b| (1..=BOUNDARY).contains(&b.len()))
                    .map(<[u8]>::to_vec);
                self.part.charset = param(value, b"charset")
                    .and_then(Encoding::for_label)
                    .unwrap_or(UTF_8);
            } else if name.eq_ignore_ascii_case(b"content-transfer-encoding") {
                self.part.transfer = if value.eq_ignore_ascii_case(b"base64") {
                    Transfer::Base64
                } else if value.eq_ignore_ascii_case(b"quoted-printable") {
                    Transfer::Quoted
                } else {
                    Transfer::Plain
                };
            } else if READ_HEADERS.iter().any(|h| name.eq_ignore_ascii_case(h)) {
                words(value, &mut self.out);
                self.out.push('\n');
            }
        }
        self.header = header;
        self.header.clear();
    }

    fn start_body(&mut self) {
        let kind = self.part.kind.as_slice();
        if kind.starts_with(b"multipart/")
            && self.boundaries.len() < DEPTH
            && let Some(b) = self.part.boundary.take()
        {
            self.boundaries.push(b);
            self.at = At::Skip;
        } else if kind == b"message/rfc822" || kind == b"message/global" {
            self.new_part();
        } else if kind.is_empty() || kind.starts_with(b"text/") || kind.starts_with(b"multipart/") {
            self.at = At::Body;
            self.decoder = Some(self.part.charset.new_decoder());
            self.bits = (0, 0);
        } else {
            self.at = At::Skip;
        }
    }

    fn body(&mut self, line: &[u8]) {
        let mut raw = Vec::with_capacity(line.len() + 1);
        match self.part.transfer {
            Transfer::Plain => {
                raw.extend_from_slice(line);
                raw.push(b'\n');
            }
            Transfer::Base64 => unbase64(line, &mut self.bits, &mut raw),
            Transfer::Quoted => {
                let line = line.trim_ascii_end();
                let (line, soft) = line.strip_suffix(b"=").map_or((line, false), |l| (l, true));
                unquote(line, false, &mut raw);
                if !soft {
                    raw.push(b'\n');
                }
            }
        }
        self.decode(&raw, false);
    }

    fn decode(&mut self, raw: &[u8], last: bool) {
        let Some(d) = &mut self.decoder else {
            return;
        };
        self.out
            .reserve(d.max_utf8_buffer_length(raw.len()).unwrap_or(0));
        let _ = d.decode_to_string(raw, &mut self.out, last);
    }

    fn end_part(&mut self) {
        self.decode(&[], true);
        self.decoder = None;
    }

    fn flush(&mut self, seen: &mut dyn FnMut(&str) -> bool, all: bool) -> bool {
        if self.out.is_empty() || (!all && self.out.len() < FLUSH) {
            return false;
        }
        let stop = seen(&self.out);
        self.out.clear();
        stop
    }
}

fn at_boundary(rest: &[u8], boundary: &[u8]) -> bool {
    rest.strip_prefix(boundary).is_some_and(|tail| {
        let tail = tail.strip_prefix(b"--").unwrap_or(tail);
        tail.iter().all(u8::is_ascii_whitespace)
    })
}

fn param<'a>(value: &'a [u8], name: &[u8]) -> Option<&'a [u8]> {
    value.split(|&b| b == b';').skip(1).find_map(|p| {
        let eq = p.iter().position(|&b| b == b'=')?;
        let (key, v) = (p[..eq].trim_ascii(), p[eq + 1..].trim_ascii());
        let v = v
            .strip_prefix(b"\"")
            .and_then(|v| v.strip_suffix(b"\""))
            .unwrap_or(v);
        key.eq_ignore_ascii_case(name).then_some(v)
    })
}

fn unbase64(src: &[u8], bits: &mut (u32, u8), out: &mut Vec<u8>) {
    let (acc, n) = bits;
    for &c in src {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                (*acc, *n) = (0, 0);
                continue;
            }
            _ => continue,
        };
        *acc = (*acc << 6) | u32::from(v);
        *n += 6;
        if *n >= 8 {
            *n -= 8;
            out.push((*acc >> *n) as u8);
            *acc &= (1 << *n) - 1;
        }
    }
}

fn unquote(src: &[u8], underscore: bool, out: &mut Vec<u8>) {
    let hex = |i: usize| src.get(i).and_then(|&h| char::from(h).to_digit(16));
    let mut i = 0;
    while let Some(&c) = src.get(i) {
        match (c, hex(i + 1), hex(i + 2)) {
            (b'=', Some(h), Some(l)) => {
                out.push((h * 16 + l) as u8);
                i += 3;
            }
            _ => {
                out.push(if underscore && c == b'_' { b' ' } else { c });
                i += 1;
            }
        }
    }
}

fn words(mut v: &[u8], out: &mut String) {
    let mut joined = false;
    loop {
        let at = find(v, b"=?").unwrap_or(v.len());
        let (plain, rest) = v.split_at(at);
        if !(joined && plain.iter().all(u8::is_ascii_whitespace)) {
            out.push_str(&String::from_utf8_lossy(plain));
        }
        if rest.is_empty() {
            return;
        }
        match word(rest, out) {
            Some(len) => (v, joined) = (&rest[len..], true),
            None => {
                out.push_str("=?");
                (v, joined) = (&rest[2..], false);
            }
        }
    }
}

fn word(v: &[u8], out: &mut String) -> Option<usize> {
    let body = v.strip_prefix(b"=?")?;
    let q = body.iter().position(|&b| b == b'?')?;
    let (charset, after) = (&body[..q], &body[q + 1..]);
    let (&mode, after) = after.split_first()?;
    let text = after.strip_prefix(b"?")?;
    let len = find(text, b"?=")?;
    let label = charset.split(|&b| b == b'*').next().unwrap_or(charset);
    let mut raw = Vec::with_capacity(len);
    match mode.to_ascii_lowercase() {
        b'b' => unbase64(&text[..len], &mut (0, 0), &mut raw),
        b'q' => unquote(&text[..len], true, &mut raw),
        _ => return None,
    }
    let encoding = Encoding::for_label(label).unwrap_or(UTF_8);
    out.push_str(&encoding.decode_without_bom_handling(&raw).0);
    Some(2 + q + 3 + len + 2)
}

fn find(v: &[u8], pat: &[u8]) -> Option<usize> {
    v.windows(pat.len()).position(|w| w == pat)
}
