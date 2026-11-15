use std::collections::BTreeSet;

use crate::query::{Mode, Query};

const TABLE: &str = include_str!("../../../Wherever/Views/Help/KeyboardShortcuts.swift");
const HOME: &str = "/Users/someone";

const CLAIMS: &[&str] = &[
    "word",
    "exact",
    "prefix",
    "suffix",
    "whole-name",
    "exclude",
    "phrase",
    "under",
    "wildcard",
    "glob-ext",
    "exclude-ext",
    "ext",
    "type",
    "kind",
    "in",
    "size",
    "mtime",
    "modified",
    "hidden",
    "re",
    "glob",
    "begins",
    "ends",
    "whole",
];
const FILTER_KEYS: &[&str] = &[
    "ext", "type", "kind", "in", "size", "mtime", "modified", "hidden", "re", "glob", "begins",
    "ends", "whole",
];

fn rows() -> Vec<(String, String)> {
    let line = regex::Regex::new(r##"example\(#"(.*)"#, sets: "([a-z-]+)""##).unwrap();
    let rows: Vec<(String, String)> = line
        .captures_iter(TABLE)
        .map(|c| (c[1].to_owned(), c[2].to_owned()))
        .collect();
    assert_eq!(
        rows.len(),
        TABLE.matches("sets: \"").count(),
        "a row the pattern did not read"
    );
    rows
}

fn no_filters(q: &Query) -> bool {
    q.kind.is_none()
        && !q.apps
        && q.exts.is_empty()
        && q.type_exts.is_empty()
        && q.not_exts.is_empty()
        && q.name_re.is_empty()
        && q.scope.is_none()
        && q.size == (0, u64::MAX)
        && q.mtime == (i64::MIN, i64::MAX)
        && !q.hide
}

fn one_word(q: &Query, mode: Mode, negate: bool) -> bool {
    q.tokens.len() == 1 && q.tokens[0].mode == mode && q.tokens[0].negate == negate
}

#[test]
fn the_window_lists_every_operator_once() {
    let claims: Vec<String> = rows().into_iter().map(|(_, c)| c).collect();
    let unique: BTreeSet<&str> = claims.iter().map(String::as_str).collect();
    assert_eq!(unique.len(), claims.len(), "a claim listed twice");
    assert_eq!(unique, CLAIMS.iter().copied().collect::<BTreeSet<_>>());
}

#[test]
fn every_listed_filter_key_is_one_the_parser_knows() {
    assert_eq!(Query::parse("nosuch:", HOME).tokens.len(), 1);
    for k in FILTER_KEYS {
        assert!(
            Query::parse(&format!("{k}:"), HOME).tokens.is_empty(),
            "{k}: is not a filter"
        );
    }
}

#[test]
fn every_example_sets_the_filter_it_claims() {
    for (example, claim) in rows() {
        let q = Query::parse(&example, HOME);
        assert!(!q.never, "{example} matches nothing");
        if FILTER_KEYS.contains(&claim.as_str()) {
            assert!(
                example.starts_with(&format!("{claim}:")),
                "{example} is not {claim}:"
            );
        }
        let no_words = q.tokens.is_empty();
        let ok = match claim.as_str() {
            "word" => one_word(&q, Mode::Together, false) && no_filters(&q),
            "exact" => one_word(&q, Mode::Exact, false) && no_filters(&q),
            "prefix" | "begins" => one_word(&q, Mode::Prefix, false) && no_filters(&q),
            "suffix" | "ends" => one_word(&q, Mode::Suffix, false) && no_filters(&q),
            "whole-name" | "whole" => one_word(&q, Mode::Whole, false) && no_filters(&q),
            "exclude" => one_word(&q, Mode::Exact, true) && no_filters(&q),
            "phrase" => {
                one_word(&q, Mode::Together, false)
                    && q.tokens[0].word.chars.contains(&' ')
                    && no_filters(&q)
            }
            "under" => {
                q.tokens.len() == 2 && !q.tokens[0].under && q.tokens[1].under && no_filters(&q)
            }
            "wildcard" => {
                let literal = Query::parse(&format!("'{example}"), HOME);
                no_words
                    && !example.contains(':')
                    && q.name_re.len() == 1
                    && !q.name_re[0].negate
                    && one_word(&literal, Mode::Exact, false)
                    && literal.tokens[0].word.chars.contains(&'*')
                    && no_filters(&literal)
            }
            "glob-ext" | "ext" => no_words && !q.exts.is_empty(),
            "exclude-ext" => no_words && q.exts.is_empty() && !q.not_exts.is_empty(),
            "type" => no_words && !q.type_exts.is_empty(),
            "kind" => no_words && q.kind.is_some(),
            "in" => {
                no_words
                    && q.scope
                        .as_ref()
                        .is_some_and(|s| !s.to_string_lossy().contains('~'))
            }
            "size" => no_words && q.size != (0, u64::MAX),
            "mtime" | "modified" => no_words && q.mtime != (i64::MIN, i64::MAX),
            "hidden" => no_words && q.hide,
            "re" | "glob" => no_words && q.name_re.len() == 1,
            other => panic!("no check for the claim {other}"),
        };
        assert!(ok, "{example} does not set {claim}: {q:?}");
    }
}
