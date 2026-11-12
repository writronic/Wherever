use std::ffi::{CStr, c_char, c_void};
use std::sync::OnceLock;

use encoding_rs::{
    EUC_KR, Encoding, GBK, SHIFT_JIS, WINDOWS_1250, WINDOWS_1251, WINDOWS_1252, WINDOWS_1253,
    WINDOWS_1254, WINDOWS_1255, WINDOWS_1256,
};

pub(super) fn fallback() -> &'static Encoding {
    #[cfg(test)]
    if let Some(language) = tests::LANGUAGE.get() {
        return encoding(language);
    }
    static ENCODING: OnceLock<&'static Encoding> = OnceLock::new();
    ENCODING.get_or_init(|| encoding(&preferred().unwrap_or_default()))
}

fn encoding(language: &str) -> &'static Encoding {
    let language = language.to_ascii_lowercase();
    let mut parts = language.split(['-', '_']);
    match parts.next().unwrap_or_default() {
        "tr" => WINDOWS_1254,
        "ru" | "uk" | "bg" => WINDOWS_1251,
        "pl" | "cs" | "hu" | "sk" => WINDOWS_1250,
        "ar" => WINDOWS_1256,
        "el" => WINDOWS_1253,
        "he" => WINDOWS_1255,
        "ja" => SHIFT_JIS,
        "zh" if parts.next() == Some("hans") => GBK,
        "ko" => EUC_KR,
        _ => WINDOWS_1252,
    }
}

fn preferred() -> Option<String> {
    use crate::fsevents::{open, sym};

    let cf = open(c"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation").ok()?;
    let language = (|| unsafe {
        let copy: unsafe extern "C" fn() -> *const c_void =
            sym(cf, c"CFLocaleCopyPreferredLanguages").ok()?;
        let count: unsafe extern "C" fn(*const c_void) -> isize =
            sym(cf, c"CFArrayGetCount").ok()?;
        let value: unsafe extern "C" fn(*const c_void, isize) -> *const c_void =
            sym(cf, c"CFArrayGetValueAtIndex").ok()?;
        let get: unsafe extern "C" fn(*const c_void, *mut c_char, isize, u32) -> u8 =
            sym(cf, c"CFStringGetCString").ok()?;
        let release: unsafe extern "C" fn(*const c_void) = sym(cf, c"CFRelease").ok()?;
        let languages = copy();
        if languages.is_null() {
            return None;
        }
        let mut buf = [0 as c_char; 128];
        let ok = count(languages) > 0
            && get(
                value(languages, 0),
                buf.as_mut_ptr(),
                buf.len() as isize,
                0x0800_0100,
            ) != 0;
        release(languages);
        ok.then(|| CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned())
    })();
    unsafe { libc::dlclose(cf) };
    language
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use std::cell::Cell;

    thread_local! {
        pub(super) static LANGUAGE: Cell<Option<&'static str>> = const { Cell::new(None) };
    }

    pub(crate) fn with_language(language: &'static str, action: impl FnOnce()) {
        struct Restore(Option<&'static str>);
        impl Drop for Restore {
            fn drop(&mut self) {
                LANGUAGE.set(self.0);
            }
        }
        let _restore = Restore(LANGUAGE.replace(Some(language)));
        action();
    }

    #[test]
    fn preferred_language_selects_its_code_page() {
        for (languages, expected) in [
            (&["tr", "tr-TR"][..], WINDOWS_1254),
            (&["ru", "uk", "bg"][..], WINDOWS_1251),
            (&["pl", "cs", "hu", "sk"][..], WINDOWS_1250),
            (&["ar", "ar-SA"][..], WINDOWS_1256),
            (&["el"][..], WINDOWS_1253),
            (&["he"][..], WINDOWS_1255),
            (&["ja", "ja-JP"][..], SHIFT_JIS),
            (&["zh-Hans", "zh-Hans-CN"][..], GBK),
            (&["ko"][..], EUC_KR),
            (&["", "en", "de", "zh-Hant", "unknown"][..], WINDOWS_1252),
        ] {
            for language in languages {
                with_language(language, || assert_eq!(fallback(), expected, "{language}"));
            }
        }
    }
}
