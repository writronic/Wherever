use std::path::Path;

use super::scope::{self, Stopped};
use super::{RICH, Terms, rich};

#[derive(Debug, PartialEq)]
pub(crate) enum Verdict {
    Holds,
    Lacks,
    NotDownloaded,
    Unreadable,
}

pub(crate) fn holds<G>(
    path: &Path,
    size: u64,
    terms: &Terms,
    go: &mut dyn FnMut() -> bool,
    open: impl FnOnce() -> Option<G>,
) -> Result<Verdict, Stopped> {
    if scope::dataless(path) {
        return Ok(Verdict::NotDownloaded);
    }
    let mut seen = terms.seen();
    let found = |held: bool| if held { Verdict::Holds } else { Verdict::Lacks };
    if !scope::is_rich(path) {
        let Some(_open) = open() else {
            return Ok(Verdict::Lacks);
        };
        let mut alternate = None;
        let read = scope::stream(path, go, &mut |text| seen.feed(text), &mut |text| {
            alternate.get_or_insert_with(|| terms.seen()).feed(text)
        })?;
        if read.is_none() && scope::no_reader(path) {
            return Ok(Verdict::Unreadable);
        }
        return Ok(found(
            seen.held() || alternate.is_some_and(|seen| seen.held()),
        ));
    }
    let _taken = RICH.take(size);
    #[cfg(test)]
    let _held = super::tests::InFlight::enter(size);
    let bytes = {
        let Some(_open) = open() else {
            return Ok(Verdict::Lacks);
        };
        scope::bytes(path, go)?
    };
    let Some(bytes) = bytes else {
        return Ok(Verdict::Lacks);
    };
    Ok(found(
        rich::read(scope::ext(path), bytes, &mut |text| seen.feed(text)) && seen.held(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::TempTree;
    use crate::text::language::tests::with_language;
    use std::fs;
    use std::path::PathBuf;

    fn find(path: &Path, words: &[&str], all: bool) -> Result<Verdict, Stopped> {
        holds(
            path,
            fs::metadata(path).unwrap().len(),
            &Terms {
                terms: words.iter().map(|s| (s.to_string(), None)).collect(),
                all,
            },
            &mut || true,
            || Some(()),
        )
    }

    #[test]
    fn plain_text_uses_the_first_languages_code_page() {
        let tree = TempTree::new("text-code-pages");
        for (language, name, bytes, word) in [
            ("tr", "company.txt", &b"\xfeirket"[..], "şirket"),
            ("en", "coffee.csv", &b"caf\xe9"[..], "café"),
        ] {
            let path = PathBuf::from(tree.real()).join(name);
            fs::write(&path, bytes).unwrap();
            with_language(language, || {
                assert_eq!(find(&path, &[word], true), Ok(Verdict::Holds));
                assert_eq!(find(&path, &["zyqabsent"], true), Ok(Verdict::Lacks));
            });
        }
    }

    #[test]
    fn alternate_decodings_never_share_terms() {
        let tree = TempTree::new("text-code-page-matchers");
        let path = PathBuf::from(tree.real()).join("mixed.txt");
        fs::write(&path, b"\xff caf\xc3\xa9").unwrap();
        with_language("en", || {
            assert_eq!(find(&path, &["café"], true), Ok(Verdict::Holds));
            assert_eq!(find(&path, &["ÿ"], true), Ok(Verdict::Holds));
            assert_eq!(find(&path, &["café", "ÿ"], false), Ok(Verdict::Holds));
            assert_eq!(find(&path, &["café", "ÿ"], true), Ok(Verdict::Lacks));
        });
    }

    #[test]
    fn a_legacy_multibyte_character_across_chunks_is_found() {
        let tree = TempTree::new("text-code-page-chunks");
        let path = PathBuf::from(tree.real()).join("japanese.txt");
        let (encoded, _, errors) = encoding_rs::SHIFT_JIS.encode("日本");
        assert!(!errors);
        let mut bytes = encoded.to_vec();
        bytes.resize(scope::CHUNK - 1, b' ');
        bytes.extend_from_slice(&encoded);
        bytes.extend_from_slice(b"zyqend");
        fs::write(&path, bytes).unwrap();
        with_language("ja", || {
            assert_eq!(find(&path, &["日本zyqend"], true), Ok(Verdict::Holds));
        });
    }

    #[test]
    fn legacy_reads_keep_cancellation_and_skip_verdicts() {
        let tree = TempTree::new("text-code-page-verdicts");
        let path = PathBuf::from(tree.real()).join("legacy.txt");
        let mut bytes = vec![b' '; scope::CHUNK];
        bytes[0] = 0xe9;
        fs::write(&path, &bytes).unwrap();
        let terms = Terms {
            terms: vec![("zyqabsent".to_owned(), None)],
            all: true,
        };
        with_language("en", || {
            assert_eq!(
                holds(
                    &path,
                    bytes.len() as u64,
                    &terms,
                    &mut || false,
                    || Some(())
                ),
                Err(Stopped)
            );
            assert_eq!(find(&path, &["zyqabsent"], true), Ok(Verdict::Lacks));
            let unsupported = path.with_extension("pages");
            fs::write(&unsupported, b"binary\0data").unwrap();
            assert_eq!(
                find(&unsupported, &["zyqabsent"], true),
                Ok(Verdict::Unreadable)
            );
            scope::tests::DATALESS.lock().unwrap().push(path.clone());
            let verdict = find(&path, &["zyqabsent"], true);
            scope::tests::DATALESS
                .lock()
                .unwrap()
                .retain(|p| p != &path);
            assert_eq!(verdict, Ok(Verdict::NotDownloaded));
        });
    }
}
