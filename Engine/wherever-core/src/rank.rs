use std::borrow::Cow;
use std::cell::LazyCell;
use std::collections::HashMap;
use std::ops::Range;
use std::path::Path;
use std::sync::OnceLock;

use crate::EngineKind;
use crate::query::{Mode, Query, Token, Word, fold_char, nfd};

const HIT: i32 = 16;
const WORD_START: i32 = 8;
const CASE_TURN: i32 = 7;
const RUN_FLOOR: i32 = 4;
const GAP_OPEN: i32 = -3;
const GAP_STEP: i32 = -1;
const DOTFILE: i32 = 16;
const TOP_PLACE: i32 = 100 + DOTFILE;
const MISSPELL: i32 = 60;
pub(crate) const TYPO_LAST: i32 = 1 << 20;
const PATH_MISS: i32 = 40;
const PATH_HIT: i32 = 30;

#[derive(Clone, Copy, PartialEq)]
enum Class {
    Lower,
    Upper,
    Digit,
    Delim,
    Other,
}

trait Unit: Copy + Eq {
    const DOT: Self;
    const SPACE: Self;
    fn fold(self) -> Self;
    fn class(self) -> Class;
    fn is_digit(self) -> bool;
}

impl Unit for u8 {
    const DOT: u8 = b'.';
    const SPACE: u8 = b' ';
    fn fold(self) -> u8 {
        self.to_ascii_lowercase()
    }
    fn class(self) -> Class {
        match self {
            b'a'..=b'z' => Class::Lower,
            b'A'..=b'Z' => Class::Upper,
            b'0'..=b'9' => Class::Digit,
            b' ' | b'_' | b'-' | b'.' | b'/' | b'(' | b')' | b'[' | b']' | b',' | b'+' | b'@' => {
                Class::Delim
            }
            _ => Class::Other,
        }
    }
    fn is_digit(self) -> bool {
        self.is_ascii_digit()
    }
}

impl Unit for char {
    const DOT: char = '.';
    const SPACE: char = ' ';
    fn fold(self) -> char {
        self.to_ascii_lowercase()
    }
    fn class(self) -> Class {
        if self.is_ascii() {
            (self as u8).class()
        } else {
            Class::Other
        }
    }
    fn is_digit(self) -> bool {
        self.is_ascii_digit()
    }
}

fn edge(prev: Class, cur: Class) -> i32 {
    match (prev, cur) {
        (Class::Delim, Class::Delim) => 0,
        (Class::Delim, _) => WORD_START,
        (Class::Lower, Class::Upper | Class::Digit) | (Class::Upper, Class::Digit) => CASE_TURN,
        _ => 0,
    }
}

fn edge_at<T: Unit>(name: &[T], i: usize) -> i32 {
    let prev = i.checked_sub(1).map_or(Class::Delim, |p| name[p].class());
    edge(prev, name[i].class())
}

fn carried(edge: i32, lead: &mut i32) -> i32 {
    if edge >= WORD_START {
        *lead = (*lead).max(edge);
    }
    edge.max(*lead).max(RUN_FLOOR)
}

fn placement<T: Unit>(name: &[T], off: usize, end: usize) -> (i32, usize) {
    let stem = name
        .iter()
        .rposition(|&b| b == T::DOT)
        .filter(|&p| p > off)
        .unwrap_or(name.len());
    if end == name.len() {
        (100 + DOTFILE * off as i32, end)
    } else if end == stem {
        (100, end)
    } else {
        (30, name.len())
    }
}

fn find<T: Unit>(s: &[T], c: T) -> Option<usize> {
    s.iter().position(|&b| b.fold() == c)
}

fn rfind<T: Unit>(s: &[T], c: T) -> Option<usize> {
    s.iter().rposition(|&b| b.fold() == c)
}

fn dot_off<T: Unit>(name: &[T]) -> usize {
    usize::from(name.len() > 1 && name[0] == T::DOT)
}

fn len_cost(len: usize) -> i32 {
    len.min(80) as i32 / 3
}

fn fuzzy<T: Unit>(
    name: &[T],
    q: &[T],
    cap: i32,
    mut pos: Option<&mut Vec<usize>>,
    together: bool,
) -> Option<i32> {
    if let Some(s) = prefix_score(name, q, cap, pos.as_deref_mut()) {
        return Some(s);
    }
    let end = if together {
        find_at(name, q)? + q.len() - 1
    } else {
        let (mut end, mut from) = (0, 0);
        for &c in q {
            end = from + find(&name[from..], c)?;
            from = end + 1;
        }
        end
    };
    if q.len() == 1 {
        if let Some(p) = pos {
            p.push(end);
        }
        return Some(single_score(name, end, cap));
    }
    let mut start = end + 1;
    for k in (0..q.len()).rev() {
        start = rfind(&name[..start], q[k])?;
    }
    let (mut score, mut at, mut lead) = (0, start, 0);
    for (k, &c) in q.iter().enumerate() {
        let joined = k > 0 && {
            let next = at + 1 + find(&name[at + 1..=end], c)?;
            let gap = next - at - 1;
            at = next;
            if gap > 0 {
                score += GAP_OPEN + GAP_STEP * (gap - 1) as i32;
            }
            gap == 0
        };
        if let Some(p) = pos.as_deref_mut() {
            p.push(at);
        }
        let here = edge_at(name, at);
        let weight = if joined {
            carried(here, &mut lead)
        } else {
            lead = here;
            here
        };
        score += HIT + weight * if k == 0 { 2 } else { 1 };
    }
    let off = dot_off(name);
    let (placed, len) = if start == off && end + 1 - start == q.len() {
        placement(name, off, end + 1)
    } else {
        (0, name.len())
    };
    Some(score + placed.min(cap) - len_cost(len))
}

fn prefix_score<T: Unit>(
    name: &[T],
    q: &[T],
    cap: i32,
    pos: Option<&mut Vec<usize>>,
) -> Option<i32> {
    let off = dot_off(name);
    let end = off + q.len();
    if (off == 1 && q[0] == T::DOT)
        || name.len() < end
        || !name[off..end].iter().zip(q).all(|(&a, &b)| a.fold() == b)
    {
        return None;
    }
    if let Some(p) = pos {
        p.extend(off..end);
    }
    let mut lead = edge(Class::Delim, name[off].class());
    let mut score = HIT + 2 * lead;
    for i in off + 1..end {
        score += HIT + carried(edge_at(name, i), &mut lead);
    }
    let (placed, len) = placement(name, off, end);
    Some(score + placed.min(cap) - len_cost(len))
}

fn single_score<T: Unit>(name: &[T], i: usize, cap: i32) -> i32 {
    let base = HIT + 2 * edge_at(name, i);
    let off = dot_off(name);
    if i != off {
        return base - len_cost(name.len());
    }
    let (placed, len) = placement(name, off, i + 1);
    base + cap.min(placed) - len_cost(len)
}

fn typo<T: Unit>(name: &[T], q: &[T]) -> Option<(i32, usize, usize)> {
    let starts = std::iter::once(dot_off(name)).chain(
        name.iter()
            .enumerate()
            .filter(|&(_, &b)| b == T::SPACE)
            .map(|(i, _)| i + 1),
    );
    starts
        .filter_map(|s| {
            if name.get(s).is_none_or(|&b| b.fold() != q[0]) {
                return None;
            }
            let len = one_edit_prefix(&name[s..], q)?;
            let fixed: Vec<T> = name.get(s..s + len)?.iter().map(|b| b.fold()).collect();
            Some((fuzzy(name, &fixed, 30, None, false)? - MISSPELL, s, len))
        })
        .max_by_key(|&(score, s, _)| (score, std::cmp::Reverse(s)))
}

fn one_edit_prefix<T: Unit>(w: &[T], q: &[T]) -> Option<usize> {
    let starts =
        |w: &[T], q: &[T]| w.len() >= q.len() && w.iter().zip(q).all(|(&a, &b)| a.fold() == b);
    let i = (0..q.len()).find(|&i| i >= w.len() || w[i].fold() != q[i])?;
    if q[i].is_digit() || w.get(i).is_some_and(|b| b.is_digit()) {
        return None;
    }
    let rest = &q[i + 1..];
    let after = w.get(i + 1..).unwrap_or_default();
    let swapped = i + 1 < q.len().min(w.len())
        && (w[i].fold(), w[i + 1].fold()) == (q[i + 1], q[i])
        && starts(&w[i + 2..], &q[i + 2..]);
    let changed = i < w.len() && starts(after, rest);
    if swapped || changed {
        Some(q.len())
    } else if starts(&w[i..], rest) {
        Some(q.len() - 1)
    } else {
        (i < w.len() && starts(after, &q[i..])).then_some(q.len() + 1)
    }
}

fn deep_typo<T: Unit>(name: &[T], q: &[T], k: u32) -> Option<(i32, usize, usize)> {
    if q.len() > 64 {
        return None;
    }
    let w = &name[..name.len().min(63)];
    let n = w.len();
    let mask = |f: &dyn Fn(T) -> bool| {
        w.iter()
            .enumerate()
            .fold(0u64, |m, (i, &b)| m | u64::from(f(b)) << i)
    };
    let mut here = Vec::with_capacity(q.len());
    let mut absent = 0;
    for &c in q {
        let m = mask(&|b| b.fold() == c);
        absent += u32::from(m == 0);
        if absent > k {
            return None;
        }
        here.push(m);
    }
    let valid = mask(&|_| true);
    let starts = (1u64 << dot_off(name)) | (mask(&|b| b == T::SPACE) << 1);
    let best = |editable: u64| {
        let mut b = starts;
        let words = std::iter::from_fn(|| {
            let s = b.trailing_zeros() as usize;
            b &= b.wrapping_sub(1);
            (s < 64).then_some(s)
        });
        words
            .filter_map(|s| Some((edits(&here, q, 1 << s, editable, n, k)?, s)))
            .min_by_key(|&((d, _), s)| (d, s))
    };
    let mut found = best(valid)?;
    let digits = mask(&|b| b.is_digit());
    if digits != 0 {
        found = best(valid & !digits)?;
    }
    let ((d, e), s) = found;
    let fixed: Vec<T> = name
        .get(s..e)
        .filter(|f| !f.is_empty())?
        .iter()
        .map(|b| b.fold())
        .collect();
    Some((
        fuzzy(name, &fixed, 30, None, false)? - MISSPELL * d as i32,
        s,
        e - s,
    ))
}

fn edits<T: Unit>(
    here: &[u64],
    q: &[T],
    start: u64,
    editable: u64,
    n: usize,
    k: u32,
) -> Option<(u32, usize)> {
    let k = k as usize;
    let ends = u64::MAX >> (63 - n);
    let (mut cur, mut prev) = ([0u64; 3], [0u64; 3]);
    cur[0] = start;
    for d in 1..=k {
        cur[d] = cur[d - 1] | (cur[d - 1] & editable) << 1;
    }
    let mut last = 0;
    for (i, &c) in q.iter().enumerate() {
        let (mut next, h) = ([0u64; 3], here[i]);
        let swap = i > 0 && q[i - 1] != c && !q[i - 1].is_digit();
        let before = if swap { last } else { 0 };
        last = h;
        for d in 0..=k {
            let mut x = (cur[d] & h) << 1;
            if d > 0 {
                if !c.is_digit() {
                    x |= (cur[d - 1] & editable) << 1 | cur[d - 1];
                    x |= ((prev[d - 1] & h) << 1 & before) << 1;
                }
                x |= (next[d - 1] & editable) << 1;
            }
            next[d] = x & ends;
        }
        (prev, cur) = (cur, next);
        if cur[k] == 0 {
            return None;
        }
    }
    match cur[..=k].iter().position(|&m| m != 0)? {
        0 => None,
        d => Some((d as u32, cur[d].trailing_zeros() as usize)),
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Source {
    Clean,
    Typo(usize, usize),
}

fn word_score<T: Unit>(
    name: &[T],
    q: &[T],
    mode: Mode,
    edits: u32,
    deep: bool,
) -> Option<(i32, Source)> {
    let cost = len_cost(name.len());
    let clean = match mode {
        Mode::Together | Mode::Fuzzy => fuzzy(name, q, TOP_PLACE, None, mode == Mode::Together),
        Mode::Exact => find_at(name, q).map(|p| 40 + if p == 0 { 30 } else { 0 } - cost),
        Mode::Prefix => starts_with(name, q).then(|| 60 - cost),
        Mode::Suffix => (name.len() >= q.len() && starts_with(&name[name.len() - q.len()..], q))
            .then(|| 50 - cost),
        Mode::Whole => (name.len() == q.len() && starts_with(name, q)).then(|| 70 - cost),
    };
    let clean = clean.map(|s| (s, Source::Clean));
    let best_typo = 24 * q.len() as i32 + 2 - cost;
    if edits == 0 || clean.is_some_and(|(c, _)| c >= best_typo) {
        return clean;
    }
    clean.or_else(|| {
        let found = if deep {
            deep_typo(name, q, edits)
        } else {
            typo(name, q)
        };
        found.map(|(s, at, len)| (s, Source::Typo(at, len)))
    })
}

fn word_units<T: Unit>(name: &[T], q: &[T], mode: Mode, source: Source) -> Vec<usize> {
    let mut pos = Vec::new();
    match (mode, source) {
        (_, Source::Typo(at, len)) => {
            let fixed: Vec<T> = name[at..at + len].iter().map(|b| b.fold()).collect();
            fuzzy(name, &fixed, 30, Some(&mut pos), false);
        }
        (Mode::Together | Mode::Fuzzy, _) => {
            fuzzy(name, q, TOP_PLACE, Some(&mut pos), mode == Mode::Together);
        }
        (Mode::Exact, _) => pos.extend(find_at(name, q).map_or(0..0, |p| p..p + q.len())),
        (Mode::Prefix, _) => pos.extend(0..q.len()),
        (Mode::Whole, _) => pos.extend(0..q.len()),
        (Mode::Suffix, _) => pos.extend(name.len() - q.len()..name.len()),
    }
    pos
}

fn well_word<T: Unit>(c: &[T], q: &[T]) -> bool {
    fuzzy(c, q, TOP_PLACE, None, false)
        .is_some_and(|s| s + len_cost(c.len()) >= 23 * q.len() as i32 + 7)
        || typo(c, q).is_some()
        || abbreviates(c, q)
        || at_word(c, q)
}

fn abbreviates<T: Unit>(name: &[T], q: &[T]) -> bool {
    if q.iter().any(|b| b.class() == Class::Delim) {
        return false;
    }
    let starts = |i: usize| i == 0 || edge_at(name, i) > 0;
    let (mut at, mut runs, mut run) = (0, 0, 0);
    for &c in q {
        if run > 0 && name.get(at).is_some_and(|&b| b.fold() == c) {
            (at, run) = (at + 1, run + 1);
            continue;
        }
        let Some(i) = (at..name.len()).find(|&i| starts(i) && name[i].fold() == c) else {
            return false;
        };
        if run == 1 {
            return false;
        }
        (at, run, runs) = (i + 1, 1, runs + 1);
    }
    run > 1 && runs > 1
}

fn at_word<T: Unit>(name: &[T], q: &[T]) -> bool {
    !q.is_empty()
        && name.windows(q.len()).enumerate().any(|(i, w)| {
            (i == 0 || name[i - 1].class() == Class::Delim)
                && w.iter().zip(q).all(|(&a, &b)| a.fold() == b)
        })
}

fn starts_with<T: Unit>(name: &[T], q: &[T]) -> bool {
    name.len() >= q.len() && name.iter().zip(q).all(|(&a, &b)| a.fold() == b)
}

fn find_at<T: Unit>(name: &[T], q: &[T]) -> Option<usize> {
    (q.len() <= name.len())
        .then(|| (0..=name.len() - q.len()).find(|&i| starts_with(&name[i..], q)))
        .flatten()
}

struct Text<'a> {
    raw: Cow<'a, [u8]>,
    chars: OnceLock<Vec<char>>,
}

pub(crate) struct Name<'a> {
    text: Text<'a>,
    plain: OnceLock<Option<Text<'a>>>,
}

pub(crate) const PLAIN_COST: i32 = 50;

#[cfg(test)]
thread_local! {
    pub(crate) static FOLDS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn folded_once() {
    FOLDS.with(|f| f.set(f.get() + 1));
}

impl<'a> Text<'a> {
    fn new(raw: Cow<'a, [u8]>) -> Text<'a> {
        Text {
            raw,
            chars: OnceLock::new(),
        }
    }

    fn bytes(&self) -> Option<&[u8]> {
        (self.raw.is_ascii() || std::str::from_utf8(&self.raw).is_err()).then_some(&self.raw)
    }

    fn chars(&self) -> &[char] {
        self.chars
            .get_or_init(|| match std::str::from_utf8(&self.raw) {
                Ok(s) => s.chars().flat_map(name_char).collect(),
                Err(_) => self.raw.iter().map(|&b| b as char).collect(),
            })
    }

    fn spans(&self) -> Option<Vec<Range<usize>>> {
        let s = std::str::from_utf8(&self.raw).ok()?;
        Some(
            s.char_indices()
                .flat_map(|(i, c)| std::iter::repeat_n(i..i + c.len_utf8(), name_char(c).count()))
                .collect(),
        )
    }

    fn score(&self, w: &Word, mode: Mode, edits: u32, deep: bool) -> Option<(i32, Source)> {
        match (self.bytes(), &w.ascii) {
            (Some(b), Some(q)) => word_score(b, q, mode, edits, deep),
            _ => word_score(self.chars(), &w.chars, mode, edits, deep),
        }
    }

    fn units(&self, w: &Word, mode: Mode, source: Source) -> Vec<usize> {
        match (self.bytes(), &w.ascii) {
            (Some(b), Some(q)) => word_units(b, q, mode, source),
            _ => word_units(self.chars(), &w.chars, mode, source),
        }
    }

    fn well(&self, w: &Word) -> bool {
        match (self.bytes(), &w.ascii) {
            (Some(b), Some(q)) => well_word(b, q),
            _ => well_word(self.chars(), &w.chars),
        }
    }

    fn spelled(&self, joined: &[char]) -> i32 {
        let name = self.chars();
        let off = dot_off(name);
        let stem = name
            .iter()
            .rposition(|&b| b == '.')
            .filter(|&p| p > off)
            .unwrap_or(name.len());
        let squash = |s: &[char]| {
            s.iter()
                .filter(|&&c| !is_delim(c))
                .map(|c| c.fold())
                .eq(joined.iter().copied())
        };
        if squash(&name[off..]) || squash(&name[off..stem]) {
            100
        } else {
            0
        }
    }
}

impl<'a> Name<'a> {
    pub(crate) fn new(raw: &'a [u8]) -> Name<'a> {
        Name {
            text: Text::new(Cow::Borrowed(raw)),
            plain: OnceLock::new(),
        }
    }

    pub(crate) fn stored(raw: &'a [u8], plain: Option<&'a [u8]>) -> Name<'a> {
        Name {
            text: Text::new(Cow::Borrowed(raw)),
            plain: OnceLock::from(plain.map(|p| Text::new(Cow::Borrowed(p)))),
        }
    }

    fn plain(&self) -> Option<&Text<'a>> {
        self.plain
            .get_or_init(|| reading(&self.text.raw).map(|p| Text::new(Cow::Owned(p.into_bytes()))))
            .as_ref()
    }

    pub(crate) fn token(&self, t: &Token) -> Option<(i32, bool)> {
        let best = self.best(t, false)?;
        Some((best.2, best.3 != Source::Clean))
    }

    fn folded<'t>(&self, t: &'t Token) -> Option<(bool, &Text<'a>, &'t Word)> {
        let plain = self.plain();
        if plain.is_none() && t.plain.is_none() {
            return None;
        }
        #[cfg(test)]
        folded_once();
        Some((
            plain.is_some(),
            plain.unwrap_or(&self.text),
            t.plain.as_ref().unwrap_or(&t.word),
        ))
    }

    fn best<'t>(&self, t: &'t Token, deepen: bool) -> Option<(bool, &'t Word, i32, Source)> {
        let deep = t.deep || deepen;
        let pass = self.folded(t);
        let folded = || {
            pass.and_then(|(read, text, w)| {
                (text.score(w, t.mode, t.edits, deep))
                    .map(|(s, src)| (read, w, s - PLAIN_COST, src))
            })
        };
        let early = (t.edits == 0
            && pass.is_some_and(|(read, text, w)| {
                w.ascii.is_some() && (read || std::str::from_utf8(&text.raw).is_ok())
            }))
        .then(folded);
        if early == Some(None) {
            return None;
        }
        let typed = std::iter::once((&t.word, deep))
            .chain(t.other.iter().map(|w| (w, false)))
            .filter_map(|(w, deep)| {
                self.text
                    .score(w, t.mode, t.edits, deep)
                    .map(|(s, src)| (false, w, s, src))
            })
            .max_by_key(|&(_, _, s, src)| (s, src == Source::Clean));
        let plain = early.unwrap_or_else(folded);
        let clean =
            |b: &Option<(bool, &Word, i32, Source)>| b.is_some_and(|b| b.3 == Source::Clean);
        match (typed, plain) {
            (Some(b), Some(p)) if clean(&typed) && clean(&plain) => {
                Some(if p.2 > b.2 { p } else { b })
            }
            (b, _) if clean(&b) => b,
            (_, p) if clean(&p) => p,
            (Some(b), _) => Some(b),
            (None, p) => p,
        }
    }

    pub(crate) fn well(&self, t: &Token) -> bool {
        self.text.well(&t.word) || self.folded(t).is_some_and(|(_, text, w)| text.well(w))
    }

    pub(crate) fn spelled(&self, joined: &[char], plain: &[char]) -> i32 {
        let read = self.plain();
        let folded = if plain.is_empty() {
            0
        } else {
            read.unwrap_or(&self.text).spelled(plain)
        };
        (self.text.spelled(joined))
            .max(read.map_or(0, |p| p.spelled(joined)))
            .max(folded)
    }
}

fn name_char(c: char) -> impl Iterator<Item = char> {
    let keep = c.is_ascii();
    std::iter::once(c)
        .filter(move |_| keep)
        .chain(fold_char(c).filter(move |_| !keep))
}

pub(crate) fn reading(raw: &[u8]) -> Option<String> {
    if raw.is_ascii() {
        return None;
    }
    let s = std::str::from_utf8(raw).ok()?;
    let (mut out, mut changed) = (String::with_capacity(s.len()), false);
    for c in s.chars() {
        if is_mark(c) {
            changed = true;
            continue;
        }
        let b = base(c);
        changed |= b != c;
        out.extend(name_char(b));
    }
    changed.then_some(out)
}

pub(crate) fn pattern_reading(raw: &[u8]) -> Option<String> {
    reading(raw).or_else(|| dotless(raw))
}

pub(crate) fn dotless(raw: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(raw).ok()?;
    s.contains('\u{131}').then(|| s.replace('\u{131}', "i"))
}

fn plain_spans(s: &str) -> Vec<Range<usize>> {
    let mut spans: Vec<Range<usize>> = Vec::new();
    for (i, c) in s.char_indices() {
        let end = i + c.len_utf8();
        if is_mark(c) {
            if let Some(last) = spans.last_mut() {
                last.end = end;
            }
        } else {
            spans.extend(std::iter::repeat_n(i..end, name_char(base(c)).count()));
        }
    }
    spans
}

fn is_mark(c: char) -> bool {
    matches!(c, '\u{300}'..='\u{36f}' | '\u{64b}'..='\u{65f}' | '\u{670}' | '\u{640}')
}

fn base(c: char) -> char {
    static BASES: OnceLock<HashMap<char, char>> = OnceLock::new();
    match c {
        '\u{671}'..='\u{673}' => 'ا',
        '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap(),
        '\u{3000}' => ' ',
        'ł' => 'l',
        'Ł' => 'L',
        'ø' => 'o',
        'Ø' => 'O',
        'đ' => 'd',
        'Đ' => 'D',
        'ħ' => 'h',
        'Ħ' => 'H',
        'ё' => 'е',
        'Ё' => 'Е',
        _ => *BASES
            .get_or_init(|| {
                [
                    '\u{c0}'..='\u{24f}',
                    '\u{370}'..='\u{3ff}',
                    '\u{622}'..='\u{626}',
                    '\u{1e00}'..='\u{1fff}',
                ]
                .into_iter()
                .flatten()
                .filter_map(|c| {
                    let d = nfd(c.encode_utf8(&mut [0; 4]))?;
                    let mut rest = d.chars();
                    let b = rest.next()?;
                    (b != c && !is_mark(b) && rest.all(is_mark)).then_some((c, b))
                })
                .collect()
            })
            .get(&c)
            .unwrap_or(&c),
    }
}

pub(crate) fn is_delim(c: char) -> bool {
    matches!(c, '_' | '-' | '.' | ' ')
}

pub(crate) fn path_fit(own: u8, parent: u8, under: u8, leaf: u8) -> i32 {
    (if own & leaf == 0 { -PATH_MISS } else { 0 })
        + if own & under & (parent << 1) != 0 {
            PATH_HIT
        } else {
            0
        }
}

pub(crate) fn positions(q: &Query, raw: &[u8]) -> Vec<Range<usize>> {
    let name = Name::new(raw);
    let Some(spans) = name.text.spans() else {
        return Vec::new();
    };
    let mut ranges: Vec<Range<usize>> = Vec::new();
    for t in q.tokens.iter().filter(|t| !t.negate) {
        match name.best(t, false).or_else(|| name.best(t, true)) {
            Some((true, w, _, source)) => {
                let (Some(p), Ok(s)) = (name.plain(), std::str::from_utf8(raw)) else {
                    continue;
                };
                let plain = plain_spans(s);
                ranges.extend(
                    p.units(w, t.mode, source)
                        .into_iter()
                        .map(|u| plain[u].clone()),
                );
            }
            Some((false, w, _, source)) => {
                ranges.extend(name.text.units(w, t.mode, source).into_iter().map(|u| {
                    if name.text.bytes().is_some() {
                        u..u + 1
                    } else {
                        spans[u].clone()
                    }
                }));
            }
            None => {}
        }
    }
    if let Ok(text) = std::str::from_utf8(raw) {
        ranges.extend(pattern_positions(q, text));
    }
    ranges.sort_by_key(|r| r.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for r in ranges {
        match merged.last_mut() {
            Some(last) if r.start <= last.end => last.end = last.end.max(r.end),
            _ => merged.push(r),
        }
    }
    merged
}

fn pattern_positions(q: &Query, raw: &str) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    if !q.exts.is_empty()
        && let Some(dot) = raw.rfind('.').filter(|&dot| dot + 1 < raw.len())
    {
        ranges.push(dot + 1..raw.len());
    }
    let read = LazyCell::new(|| pattern_reading(raw.as_bytes()));
    for r in q.name_re.iter().filter(|r| !r.negate) {
        let (text, re, plain) = if r.re.is_match(raw.as_bytes()) {
            (raw, &r.re, false)
        } else if r.exact {
            continue;
        } else {
            match (read.as_deref(), &r.plain) {
                (Some(read), plain) => (read, plain.as_ref().unwrap_or(&r.re), true),
                (None, Some(plain)) => (raw, plain, false),
                (None, None) => continue,
            }
        };
        let found: Vec<Range<usize>> = if r.glob {
            re.captures(text.as_bytes())
                .into_iter()
                .flat_map(|c| {
                    c.iter()
                        .skip(1)
                        .flatten()
                        .map(|m| m.range())
                        .collect::<Vec<_>>()
                })
                .collect()
        } else {
            re.find_iter(text.as_bytes()).map(|m| m.range()).collect()
        };
        let spans = LazyCell::new(|| plain_spans(raw));
        for f in found.into_iter().filter(|f| !f.is_empty()) {
            if !plain {
                if raw.is_char_boundary(f.start) && raw.is_char_boundary(f.end) {
                    ranges.push(f);
                }
                continue;
            }
            let (Some(a), Some(b)) = (text.get(..f.start), text.get(..f.end)) else {
                continue;
            };
            let (a, b) = (a.chars().count(), b.chars().count());
            if let (Some(first), Some(last)) = (spans.get(a), spans.get(b - 1)) {
                ranges.push(first.start..last.end);
            }
        }
    }
    ranges
}

const PLACE_HIDDEN: u8 = 1;
const PLACE_HOME: u8 = 2;
const PLACE_BOOT_ROOT: u8 = 4;
const PLACE_BOOT: u8 = 8;
const PLACE_SYSTEM: u8 = 16;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) struct Place {
    pub prior: i8,
    depth: u8,
    home: u8,
    flags: u8,
}

impl Place {
    pub(crate) fn hidden(&self) -> bool {
        self.flags & PLACE_HIDDEN != 0
    }
}

pub(crate) struct Places {
    home: Vec<Vec<u8>>,
}

impl Places {
    pub(crate) fn new(home: &Path) -> Places {
        Places {
            home: components(home),
        }
    }

    pub(crate) fn root(&self, root: &Path, boot: bool) -> Place {
        let top = Place {
            prior: 0,
            depth: 0,
            home: 0,
            flags: if boot { PLACE_BOOT } else { 0 },
        };
        let mut place = components(root)
            .iter()
            .fold(top, |up, name| self.step(&up, name, false));
        if boot {
            place.flags |= PLACE_BOOT_ROOT;
        }
        place
    }

    pub(crate) fn step(&self, up: &Place, name: &[u8], flagged: bool) -> Place {
        let depth = up.depth.saturating_add(1);
        let n = self.home.len();
        let home = match up.home as usize {
            h if h >= n => up.home,
            h if self.home[h] == name => up.home + 1,
            _ => u8::MAX,
        };
        let entered = home as usize == n && (up.home as usize) < n;
        let prior = i32::from(up.prior) + folder_weight(name, depth) + if entered { 15 } else { 0 };
        let system = (up.flags & PLACE_BOOT_ROOT != 0 && (name == b"System" || name == b"Library"))
            || (up.flags & PLACE_BOOT != 0 && up.flags & PLACE_HOME != 0 && name == b"Library");
        let applications = up.flags & PLACE_SYSTEM != 0 && name == b"Applications";
        let hidden =
            (up.hidden() && !applications) || flagged || name.first() == Some(&b'.') || system;
        Place {
            prior: prior.clamp(-100, 60) as i8,
            depth,
            home,
            flags: (up.flags & PLACE_BOOT)
                | if hidden { PLACE_HIDDEN } else { 0 }
                | if up.flags & PLACE_BOOT_ROOT != 0 && name == b"System" {
                    PLACE_SYSTEM
                } else {
                    0
                }
                | if entered { PLACE_HOME } else { 0 },
        }
    }
}

fn components(path: &Path) -> Vec<Vec<u8>> {
    use std::os::unix::ffi::OsStrExt;
    path.components()
        .filter_map(|c| match c {
            std::path::Component::Normal(n) => Some(n.as_bytes().to_vec()),
            _ => None,
        })
        .collect()
}

pub(crate) fn tier(q: &Query, raw: &[u8], score: i32) -> u8 {
    if score < -TYPO_LAST / 2 {
        return 3;
    }
    let name = Name::new(raw);
    q.tokens
        .iter()
        .filter(|t| !t.negate)
        .flat_map(|t| std::iter::once(&t.word).chain(&t.other))
        .map(|w| match (name.text.bytes(), &w.ascii) {
            (Some(b), Some(a)) => word_tier(b, a),
            _ => word_tier(name.text.chars(), &w.chars),
        })
        .min()
        .unwrap_or(2)
}

fn word_tier<T: Unit>(name: &[T], q: &[T]) -> u8 {
    let off = dot_off(name);
    let end = off + q.len();
    if q.is_empty() || (off == 1 && q[0] == T::DOT) || !starts_with(&name[off..], q) {
        2
    } else if end == name.len() || (name[end] == T::DOT && !name[end + 1..].contains(&T::DOT)) {
        0
    } else {
        1
    }
}

pub(crate) fn lift<H: Copy>(rows: &mut [H], key: impl Fn(&H) -> (u8, i32)) {
    let mut keyed: Vec<((u8, i32), H)> = rows.iter().map(|h| (key(h), *h)).collect();
    for run in keyed.chunk_by_mut(|a, b| a.0.0 == b.0.0) {
        run.sort_by_key(|&((_, boost), _)| std::cmp::Reverse(boost));
    }
    for (row, (_, h)) in rows.iter_mut().zip(keyed) {
        *row = h;
    }
}

const PACKAGE_SUFFIXES: &[&[u8]] = &[
    b".appex",
    b".bundle",
    b".dSYM",
    b".framework",
    b".imovielibrary",
    b".kext",
    b".lproj",
    b".musiclibrary",
    b".photoslibrary",
    b".platform",
    b".plugin",
    b".sdk",
    b".tvlibrary",
    b".xcarchive",
    b".xcassets",
    b".xpc",
];

fn is_package(name: &[u8]) -> bool {
    PACKAGE_SUFFIXES.iter().any(|suffix| {
        name.len() > suffix.len() && name[name.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
    })
}

fn folder_weight(name: &[u8], depth: u8) -> i32 {
    if depth == 1 {
        return match name {
            b"Applications" => 10,
            b"Users" => 0,
            b"Volumes" => -10,
            b"Library" | b"opt" => -25,
            b"System" => -40,
            _ => -35,
        };
    }
    match name {
        b"Applications" => 30,
        _ if name.ends_with(b".app") => -25,
        _ if is_package(name) => -20,
        [b'.', ..] => -25,
        b"Application Support" => -5,
        b"Containers" | b"Group Containers" | b"folders" => -10,
        b"build" | b"deps" | b"dist" | b"out" | b"target" | b"temp" | b"tmp" | b"vendor" => -12,
        b"Cache" | b"Caches" | b"CoreSimulator" | b"DerivedData" | b"Library" | b"Logs"
        | b"cache" | b"caches" => -20,
        b"Pods" | b"__pycache__" | b"bower_components" | b"node_modules" | b"site-packages"
        | b"venv" => -30,
        _ => 0,
    }
}

pub(crate) fn tweaks(name: &[u8], kind: EngineKind, hidden: bool, mtime: i64, now: i64) -> i32 {
    const DAY: i64 = 86_400;
    let age = now.saturating_sub(mtime);
    let recent = [(DAY, 10), (7 * DAY, 7), (30 * DAY, 4), (365 * DAY, 1)]
        .into_iter()
        .find(|&(limit, _)| age <= limit)
        .map_or(0, |(_, weight)| weight);
    let unseen = -8 * (i32::from(name.first() == Some(&b'.')) + i32::from(hidden));
    let app = if kind != EngineKind::File && name.ends_with(b".app") {
        25
    } else {
        0
    };
    recent + unseen + app
}

#[cfg(test)]
mod tests {
    use super::*;

    fn score(query: &str, name: &str) -> Option<(i32, bool)> {
        let q = Query::parse(query, "/").loosened();
        Name::new(name.as_bytes()).token(&q.tokens[0])
    }

    fn spans(query: &str, name: &str) -> Vec<Range<usize>> {
        positions(&Query::parse(query, "/").loosened(), name.as_bytes())
    }

    fn strict(query: &str, name: &str) -> Option<(i32, bool)> {
        Name::new(name.as_bytes()).token(&Query::parse(query, "/").tokens[0])
    }

    fn strict_spans(query: &str, name: &str) -> Vec<Range<usize>> {
        positions(&Query::parse(query, "/"), name.as_bytes())
    }

    #[test]
    fn whole_name_then_prefix_then_word_then_typo() {
        assert_eq!(score("report", "report"), Some((250, false)));
        assert_eq!(score("report", "report.pdf"), Some((250, false)));
        assert_eq!(score("report", "reports-2024.txt"), Some((177, false)));
        assert_eq!(score("report", "annual report.txt"), Some((147, false)));
        assert_eq!(score("report", "rpeort.txt"), Some((120, true)));
        assert_eq!(score("report", "Rpeort.app"), Some((120, true)));
    }

    #[test]
    fn a_word_matches_only_its_letters_side_by_side() {
        for name in ["hello.txt", "say-hello.md", "hello", "HELLO.TXT"] {
            assert!(strict("hello", name).is_some(), "{name}");
        }
        for name in [
            "hell",
            "hell.txt",
            "he",
            "hallo",
            "helper_tool.log",
            "shell",
        ] {
            assert_eq!(strict("hello", name), None, "{name}");
        }
    }

    #[test]
    fn a_side_by_side_word_keeps_todays_scores() {
        for (name, want) in [
            ("report", 250),
            ("report.pdf", 250),
            ("reports-2024.txt", 177),
            ("annual report.txt", 147),
        ] {
            assert_eq!(strict("report", name), Some((want, false)), "{name}");
            assert_eq!(strict("report", name), score("report", name), "{name}");
        }
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn side_by_side_letters_are_bold() {
        assert_eq!(strict_spans("hello", "h-e-l-l-o hello.txt"), [10..15]);
        assert_eq!(strict_spans("hello", "say-hello.md"), [4..9]);
    }

    #[test]
    fn a_side_by_side_word_ignores_accents_both_ways() {
        assert!(strict("ozet", "özet.pdf").is_some());
        assert!(strict("ozet", "o\u{308}zet.pdf").is_some());
        assert!(strict("özet", "ozet.pdf").is_some());
        assert_eq!(strict("ozet", "o_z_e_t.pdf"), None);
        assert_eq!(strict("özet", "o_z_e_t.pdf"), None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn arabic_names_fold_marks_tatweel_and_alef_variants_both_ways() {
        for (marked, plain) in [
            ("مُدَرِّس", "مدرس"),
            ("أحمد", "احمد"),
            ("كـتـاب", "كتاب"),
            ("آإأٱٲٳؤئ", "ااااااوي"),
            ("هٰذا", "هذا"),
        ] {
            assert_eq!(reading(marked.as_bytes()).as_deref(), Some(plain));
            assert_eq!(reading(plain.as_bytes()), None);
            assert!(strict(plain, &format!("{marked}.txt")).is_some());
            assert!(strict(marked, &format!("{plain}.txt")).is_some());
            assert_eq!(
                strict_spans(plain, &format!("{marked}.txt")),
                [0..marked.len()]
            );
            assert!(strict(marked, marked).unwrap().0 > strict(plain, marked).unwrap().0);
        }
        for mark in ('\u{64b}'..='\u{65f}').chain(['\u{670}', '\u{640}']) {
            assert_eq!(
                reading(format!("م{mark}د").as_bytes()).as_deref(),
                Some("مد")
            );
        }
        assert!(strict("مدرس", "مدرسة").is_some());
        assert_eq!(strict("مدرس", "م د ر س"), None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn full_width_letters_and_digits_match_and_mark_the_original_bytes() {
        assert!(strict("report2026", "ＲＥＰＯＲＴ２０２６.pdf").is_some());
        assert!(strict("ＲＥＰＯＲＴ２０２６", "report2026.pdf").is_some());
        assert!(strict("Ａ", "a").is_some());
        assert!(strict("a", "Ａ").is_some());
        assert_eq!(
            strict_spans("port2026", "東ＲＥＰＯＲＴ２０２６.pdf"),
            [9..33]
        );
        assert_eq!(strict_spans("ＲＥＰＯＲＴ", "report2026.pdf"), [0..6]);
        assert_eq!(
            reading("ＲＥＰＯＲＴ　２０２６.pdf".as_bytes()).as_deref(),
            Some("REPORT 2026.pdf")
        );
        assert_eq!(reading("日本語".as_bytes()), None);
        assert_eq!(strict("report2026", "ＲＥＰＯＲＴ２０２５.pdf"), None);
    }

    #[test]
    fn a_typo_keeps_the_first_letter_and_every_digit() {
        assert_eq!(score("rpeort", "report.txt").map(|s| s.1), Some(true));
        assert_eq!(score("rpeort", "my report.txt").map(|s| s.1), Some(true));
        assert_eq!(score("xeport", "report.txt"), None);
        assert_eq!(score("rep0rt", "report.txt"), None);
        assert_eq!(score("report", "rep0rt.txt"), None);
        assert_eq!(Query::parse("rpeo", "/").tokens[0].edits, 0);
        assert_eq!(score("rpeo", "repo.txt"), None);
        assert_eq!(score("raport", "report.txt").map(|s| s.1), Some(true));
        assert_eq!(score("reporrt", "report.txt").map(|s| s.1), Some(true));
        assert_eq!(score("reprt", "report.txt"), Some((110, false)));
    }

    fn deep(query: &str, name: &str) -> Option<(i32, bool)> {
        let q = Query::parse(query, "/").loosened().deepen();
        Name::new(name.as_bytes()).token(&q.tokens[0])
    }

    #[test]
    fn a_deep_typo_edits_the_first_letter_and_takes_two_edits_from_eight_letters() {
        assert_eq!(deep("xeport", "report.txt"), Some((120, true)));
        assert_eq!(deep("jeyboard", "keyboard.txt"), Some((168, true)));
        assert_eq!(deep("docmunet", "document.pdf"), Some((108, true)));
        assert_eq!(deep("rreport", "report.txt").map(|s| s.1), Some(true));
        assert_eq!(deep("erport", "report.txt").map(|s| s.1), Some(true));
        assert_eq!(deep("xeport", "my report.txt").map(|s| s.1), Some(true));
        assert_eq!(deep("pcitrue", "picture.png"), None);
        assert_eq!(deep("picture", "picture.png").map(|s| s.1), Some(false));
    }

    #[test]
    fn a_deep_typo_never_edits_a_digit() {
        assert_eq!(deep("rep0rt", "report.txt"), None);
        assert_eq!(deep("report", "rep0rt.txt"), None);
        assert_eq!(deep("hat_18x", "hat_98x.txt"), None);
    }

    #[test]
    fn a_deep_typo_reads_the_first_63_units() {
        let pad = |n: usize| format!("{} report.txt", "a".repeat(n));
        assert!(deep("xeport", &pad(20)).is_some());
        assert_eq!(deep("xeport", &pad(70)), None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_deep_typo_reads_characters_of_a_name_that_is_not_ascii() {
        assert_eq!(deep("xésumé", "résumé.pdf"), Some((120, true)));
        assert_eq!(spans("xésumé", "résumé.pdf"), [0..8]);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn positions_of_a_deep_match_cut_out_the_matched_letters() {
        assert_eq!(spans("xeport", "my report.txt"), [3..9]);
        assert_eq!(spans("xeport", "report.txt"), [0..6]);
        assert!(spans("xeport", "unrelated.txt").is_empty());
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn patterns_and_extensions_bold_the_letters_they_matched() {
        assert_eq!(
            strict_spans("cardinal*.dmg", "Cardinal-1.2.dmg"),
            [0..8, 12..16]
        );
        assert_eq!(strict_spans("glob:a?c", "abc"), [0..1, 2..3]);
        assert_eq!(strict_spans("glob:*report*", "my report.txt"), [3..9]);
        assert_eq!(strict_spans("re:^card", "Cardinal.dmg"), [0..4]);
        assert_eq!(strict_spans("re:an", "banana"), [1..5]);
        assert_eq!(strict_spans("ext:pdf", "a.report.pdf"), [9..12]);
        assert_eq!(strict_spans("*.PDF", "a.report.pdf"), [9..12]);
        assert_eq!(strict_spans("report ext:pdf", "report.pdf"), [0..6, 7..10]);
        assert_eq!(strict_spans("report !*.tmp", "report.txt"), [0..6]);
        assert_eq!(strict_spans("type:doc report", "report.pdf"), [0..6]);
        assert_eq!(strict_spans("glob:ozet*", "özet.pdf"), [0..5]);
        assert_eq!(strict_spans("glob:özet*", "ozet.pdf"), [0..4]);
        assert_eq!(strict_spans("kirmizi*", "kırmızı.md"), [0..10]);
        assert!(strict_spans("!x*", "abc").is_empty());
    }

    #[test]
    fn the_other_form_of_a_word_never_goes_deep() {
        let mut q = Query::parse("xeport", "/").loosened().deepen();
        q.tokens[0].other = Some(q.tokens[0].word.clone());
        q.tokens[0].word = Word::new("zzzzzz");
        assert_eq!(Name::new(b"report.txt").token(&q.tokens[0]), None);
    }

    #[test]
    fn a_name_is_well_found_when_typed_abbreviated_or_a_typo_with_the_first_letter() {
        let well =
            |name: &str, q: &str| Name::new(name.as_bytes()).well(&Query::parse(q, "/").tokens[0]);
        assert!(well("report.txt", "report"));
        assert!(well("annual report.txt", "report"));
        assert!(well("rpeort.txt", "report"));
        assert!(well(".gitkeep", "gitkeep"));
        assert!(well("RegionalCapabilitiesServiceFactory", "regcapserfac"));
        assert!(!well("xeport.txt", "report"));
        assert!(!well("unrelated.txt", "report"));
    }

    #[test]
    fn exact_prefix_and_suffix_words() {
        assert_eq!(score("'port", "report.txt"), Some((40 - 3, false)));
        assert_eq!(score("'rep", "report.txt"), Some((70 - 3, false)));
        assert_eq!(score("^rep", "Report.txt"), Some((60 - 3, false)));
        assert_eq!(score("^port", "report.txt"), None);
        assert_eq!(score("txt$", "report.TXT"), Some((50 - 3, false)));
        assert_eq!(score("rep$", "report.txt"), None);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_whole_name_word_matches_the_name_and_nothing_longer() {
        let at_start = |name| score("'report", name).map(|s| s.0);
        assert_eq!(score("^report$", "Report").map(|s| s.0), at_start("Report"));
        assert!(score("^report$", "Report").is_some());
        assert_eq!(score("^report$", "report.pdf"), None);
        assert_eq!(score("^report$", "my report"), None);
        assert_eq!(score("^report$", "rep"), None);
        assert_eq!(spans("^report$", "Report"), [0..6]);
    }

    #[test]
    fn letters_fold_per_character() {
        assert!(score("é", "É.txt").is_some());
        assert!(score("i", "\u{130}stanbul.txt").is_some());
        assert!(score("\u{130}", "istanbul.txt").is_some());
        assert!(score("ünal", "ÜNAL.txt").is_some());
        assert!(score("caf\u{e9}", "cafe\u{301}.txt").is_some());
        assert!(score("cafe\u{301}", "caf\u{e9}.txt").is_some());
        assert!(score("\u{e9}", "\u{c3}\u{a9}.txt").is_none());
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn positions_fall_on_character_boundaries() {
        let name = "Ünal Report.TXT";
        assert_eq!(spans("rep", name), [6..9]);
        assert_eq!(spans("ünal rep", name), [0..5, 6..9]);
        assert_eq!(spans("caf\u{e9}", "Le cafe\u{301}.txt"), [3..9]);
        assert_eq!(spans("report", "rpeort.txt"), [0..6]);
        assert_eq!(spans("'txt", "a.txt"), [2..5]);
        assert!(spans("zzz", name).is_empty());
        assert!(spans("!rep", name).is_empty());
        assert!(positions(&Query::parse("a", "/"), b"a\xff").is_empty());
        for (query, name) in [("rep", name), ("ünal rep", name), ("é", "aÉé.txt")] {
            for r in spans(query, name) {
                assert!(name.is_char_boundary(r.start) && name.is_char_boundary(r.end));
            }
        }
    }

    #[test]
    fn priors_come_from_the_absolute_path() {
        let places = Places::new(Path::new("/Users/me"));
        let boot = places.root(Path::new("/"), true);
        let step = |up: Place, name: &str| places.step(&up, name.as_bytes(), false);
        let users = step(boot, "Users");
        let home = step(users, "me");
        assert_eq!((users.prior, home.prior), (0, 15));
        let caches = step(step(home, "Library"), "Caches");
        assert_eq!(caches.prior, -25);
        assert_eq!(step(caches, "node_modules").prior, -55);
        assert_eq!(step(step(boot, "Applications"), "Safari.app").prior, -15);
        assert_eq!(places.root(Path::new("/Volumes/Disk"), false).prior, -10);
        let temp = places.root(Path::new("/private/var/folders/x/T/t"), true);
        assert_eq!(temp.prior, -45);
    }

    #[test]
    fn system_folders_hide_only_on_the_boot_unit() {
        let places = Places::new(Path::new("/Users/me"));
        let boot = places.root(Path::new("/"), true);
        let disk = places.root(Path::new("/Volumes/Disk"), false);
        let hidden = |up: &Place, name: &str| places.step(up, name.as_bytes(), false).hidden();
        assert!(hidden(&boot, "System") && hidden(&boot, "Library"));
        assert!(!hidden(&boot, "Users") && !hidden(&disk, "Library") && !hidden(&disk, "System"));
        let home = places.step(&places.step(&boot, b"Users", false), b"me", false);
        assert!(hidden(&home, "Library") && !hidden(&home, "Documents"));
        assert!(hidden(&disk, ".git") && places.step(&disk, b"Photos", true).hidden());
        let dot = places.step(&disk, b".cache", false);
        assert!(hidden(&dot, "plain"));
    }

    #[test]
    fn tweaks_weigh_kind_hidden_and_age() {
        let now = 1_000_000_000;
        let ago = |days: i64| now - days * 86_400;
        assert_eq!(tweaks(b"a.txt", EngineKind::File, false, now, now), 10);
        assert_eq!(tweaks(b".a", EngineKind::File, true, ago(400), now), -16);
        assert_eq!(tweaks(b"X.app", EngineKind::Folder, false, ago(8), now), 29);
        assert_eq!(tweaks(b"X.app", EngineKind::File, false, ago(100), now), 1);
    }

    #[test]
    fn tiers_follow_the_placement() {
        let t = |query: &str, name: &str| {
            let q = Query::parse(query, "/").loosened();
            let score = Name::new(name.as_bytes()).token(&q.tokens[0]).unwrap();
            tier(
                &q,
                name.as_bytes(),
                if score.1 {
                    score.0 - TYPO_LAST
                } else {
                    score.0
                },
            )
        };
        assert_eq!(t("report", "Report.PDF"), 0);
        assert_eq!(t("report", "report"), 0);
        assert_eq!(t("zshrc", ".zshrc"), 0);
        assert_eq!(t("report", "reports-2024.txt"), 1);
        assert_eq!(t("report", "report.tar.gz"), 1);
        assert_eq!(t("report", "annual report.txt"), 2);
        assert_eq!(t("rpt", "report.txt"), 2);
        assert_eq!(t("report", "rpeort.txt"), 3);
        assert_eq!(t("'report", "report.txt"), 0);
        assert_eq!(t("annual report", "annual report.txt"), 1);
        assert_eq!(t("ozet", "ozet.pdf"), 0);
        assert_eq!(t("ozet", "özet.pdf"), 2);
        assert_eq!(t("özet", "özet.pdf"), 0);
        assert_eq!(t("özet", "ozet.pdf"), 2);
        assert_eq!(t("Ünal", "UNAL"), 2);
    }

    #[test]
    fn an_accented_word_finds_a_plain_name() {
        let less = |s: Option<(i32, bool)>| s.map(|(s, typo)| (s - PLAIN_COST, typo));
        for (word, plain, name) in [
            ("özet", "ozet", "ozet.pdf"),
            ("Ünal", "unal", "Unal.txt"),
            ("ünal", "unal", "UNAL.txt"),
            ("o\u{308}zet", "ozet", "ozet.pdf"),
            ("'zét", "'zet", "ozet.pdf"),
            ("^özet", "^ozet", "ozet.pdf"),
            ("zét.pdf$", "zet.pdf$", "ozet.pdf"),
            ("^özet.pdf$", "^ozet.pdf$", "ozet.pdf"),
            ("łódź", "lodz", "Lodz.jpg"),
            ("ışık", "isik", "ISIK.txt"),
        ] {
            assert!(score(plain, name).is_some(), "{plain} in {name}");
            assert_eq!(
                score(word, name),
                less(score(plain, name)),
                "{word} in {name}"
            );
        }
        assert_eq!(
            score("özetlwr", "ozetler.pdf"),
            less(score("ozetlwr", "ozetler.pdf"))
        );
        assert!(score("özetlwr", "ozetler.pdf").is_some_and(|(_, typo)| typo));
        assert!(score("özet", "Özet.pdf").unwrap().0 > score("özet", "ozet.pdf").unwrap().0);
        assert!(score("özet", "rapor.txt").is_none());
        assert!(score("東京", "東京.txt").is_some());
        for word in ["мой", "мои\u{306}"] {
            assert_eq!(Query::parse(word, "/").tokens[0].plain, None, "{word}");
            assert!(score(word, "мои.txt").is_none(), "{word}");
        }
    }

    #[test]
    fn a_plain_word_on_a_plain_name_runs_no_accent_free_pass() {
        FOLDS.with(|f| f.set(0));
        assert!(score("report", "report.txt").is_some());
        assert!(score("rep", "annual report.txt").is_some());
        assert!(score("reprot", "report.txt").is_some());
        assert!(score("xyz", "report.txt").is_none());
        let q = Query::parse("report", "/");
        assert!(Name::new(b"annual report.txt").well(&q.tokens[0]));
        assert!(!spans("report", "report.txt").is_empty());
        assert!(score("東京", "東京.txt").is_some());
        assert_eq!(FOLDS.with(|f| f.get()), 0);
        assert!(score("rêport", "report.txt").is_some());
        assert!(FOLDS.with(|f| f.get()) > 0);
        FOLDS.with(|f| f.set(0));
        assert!(score("report", "rêport.txt").is_some());
        assert!(FOLDS.with(|f| f.get()) > 0);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn an_accented_word_marks_the_letters_of_a_plain_name() {
        assert_eq!(spans("özet", "ozet.pdf"), [0..4]);
        assert_eq!(spans("ünal rep", "Unal Report.txt"), [0..4, 5..8]);
        assert_eq!(spans("ünal", "东Unal.txt"), [3..7]);
    }

    #[test]
    fn an_ascii_word_finds_a_name_without_its_accents() {
        let less = |s: Option<(i32, bool)>| s.map(|(s, typo)| (s - PLAIN_COST, typo));
        assert_eq!(score("unal", "Ünal.txt"), less(score("unal", "Unal.txt")));
        assert_eq!(
            score("unal", "U\u{308}nal.txt"),
            less(score("unal", "Unal.txt"))
        );
        assert_eq!(score("ozet", "özet.pdf"), less(score("ozet", "ozet.pdf")));
        assert_eq!(score("isik", "IŞIK.txt"), less(score("isik", "ISIK.txt")));
        assert_eq!(score("lodz", "Łódź.jpg"), less(score("lodz", "Lodz.jpg")));
        assert!(score("unal", "Ünal.txt").is_some_and(|(s, typo)| s > 0 && !typo));
        assert_eq!(
            score("ozetlwr", "özetler.pdf"),
            less(score("ozetlwr", "ozetler.pdf"))
        );
        assert!(score("ozetlwr", "özetler.pdf").is_some_and(|(_, typo)| typo));
        assert!(score("xyz", "Ünal.txt").is_none());
        assert!(score("ünal", "Ünal.txt").unwrap().0 > score("unal", "Ünal.txt").unwrap().0);
    }

    #[test]
    fn the_accent_free_reading_drops_marks_and_strokes_only() {
        for (name, want) in [
            ("Ünal.txt", Some("Unal.txt")),
            ("U\u{308}nal.txt", Some("Unal.txt")),
            ("özet.pdf", Some("ozet.pdf")),
            ("Işık.txt", Some("Isik.txt")),
            ("İstanbul", Some("Istanbul")),
            ("Việt Nam", Some("Viet Nam")),
            ("Łódź Ørsted đ", Some("Lodz Orsted d")),
            ("Ёлка", Some("елка")),
            ("Ἀθῆναι", Some("αθηναι")),
            ("Ünal ЖУК", Some("Unal жук")),
            ("ılık", None),
            ("Проект", None),
            ("Мой файл", None),
            ("日本語のメモ", None),
            ("がっこう", None),
            ("한국어", None),
            ("report.txt", None),
        ] {
            assert_eq!(reading(name.as_bytes()).as_deref(), want, "{name}");
        }
        assert_eq!(reading(b"bad\xffname"), None);
    }

    #[test]
    fn the_reading_spells_the_name_for_several_words() {
        let joined = |s: &str| s.chars().collect::<Vec<char>>();
        let name = Name::new("Ünal özet.txt".as_bytes());
        assert_eq!(name.spelled(&joined("unalozet"), &[]), 100);
        assert_eq!(name.spelled(&joined("ünalözet"), &[]), 100);
        assert_eq!(name.spelled(&joined("unalrapor"), &[]), 0);
        let plain = Name::new("Unal ozet.txt".as_bytes());
        assert_eq!(plain.spelled(&joined("ünalözet"), &[]), 0);
        assert_eq!(plain.spelled(&joined("ünalözet"), &joined("unalozet")), 100);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_match_through_the_reading_marks_whole_letters_of_the_name() {
        assert_eq!(spans("unal", "Ünal.txt"), [0..5]);
        assert_eq!(spans("unal", "U\u{308}nal.txt"), [0..6]);
        assert_eq!(spans("nal", "Ünal.txt"), [2..5]);
        assert_eq!(spans("ozet pdf", "özet.pdf"), [0..5, 6..9]);
        for name in ["Ünal.txt", "U\u{308}nal.txt", "Łódź.jpg"] {
            for r in spans("unal lodz", name) {
                assert!(name.is_char_boundary(r.start) && name.is_char_boundary(r.end));
            }
        }
    }

    #[test]
    fn the_lift_reorders_each_tier_by_boost_and_crosses_none() {
        let mut rows = [
            (0, 0, 'a'),
            (0, 8, 'b'),
            (1, 0, 'c'),
            (1, 40, 'd'),
            (1, 21, 'e'),
            (2, 0, 'f'),
        ];
        rank_lift(&mut rows);
        assert_eq!(rows.map(|r| r.2), ['b', 'a', 'd', 'e', 'c', 'f']);
        let mut rows = [(0, 0, 'a'), (1, 40, 'b'), (3, 40, 'c')];
        rank_lift(&mut rows);
        assert_eq!(rows.map(|r| r.2), ['a', 'b', 'c']);
        let mut rows = [(1, 0, 'a'), (0, 0, 'b'), (1, 0, 'c'), (1, 8, 'd')];
        rank_lift(&mut rows);
        assert_eq!(rows.map(|r| r.2), ['a', 'b', 'd', 'c']);
    }

    fn rank_lift(rows: &mut [(u8, i32, char)]) {
        lift(rows, |&(t, b, _)| (t, b));
    }
}
