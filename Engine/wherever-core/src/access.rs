use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use crate::EngineError;

#[uniffi::export]
pub fn has_full_disk_access(home: String) -> Result<bool, EngineError> {
    let home = Path::new(&home);
    Ok(probe(&[
        PathBuf::from("/Library/Application Support/com.apple.TCC/TCC.db"),
        home.join("Library/Application Support/com.apple.TCC/TCC.db"),
        PathBuf::from("/Library/Preferences/com.apple.TimeMachine.plist"),
        home.join("Library/Safari"),
        home.join("Library/Mail"),
        home.join("Library/Messages"),
    ]))
}

fn probe(paths: &[PathBuf]) -> bool {
    let mut opened = false;
    for path in paths {
        match readable(path) {
            Ok(()) => opened = true,
            Err(e) if refuses(&e) => return false,
            Err(_) => {}
        }
    }
    opened
}

fn refuses(e: &io::Error) -> bool {
    e.raw_os_error() == Some(libc::EPERM)
}

fn readable(path: &Path) -> io::Result<()> {
    if fs::metadata(path)?.is_dir() {
        fs::read_dir(path)?.next().transpose()?;
    } else {
        File::open(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{Locked, TempTree};

    #[test]
    fn a_mode_000_folder_says_nothing() {
        let tree = TempTree::new("probe");
        fs::create_dir(tree.0.join("Shut")).unwrap();
        fs::write(tree.0.join("shut.db"), b"").unwrap();
        let _locked = Locked::new(vec![tree.0.join("Shut"), tree.0.join("shut.db")]);
        let probe_of =
            |names: &[&str]| probe(&names.iter().map(|n| tree.0.join(n)).collect::<Vec<_>>());
        assert!(!probe_of(&[]));
        assert!(!probe_of(&["missing", "gone.db"]));
        assert!(probe_of(&["missing", "Alpha.TXT"]));
        assert!(probe_of(&["Sub"]));
        assert!(!probe_of(&["shut.db", "Shut"]));
        assert!(probe_of(&["Alpha.TXT", "shut.db"]));
        assert!(probe_of(&["shut.db", "Alpha.TXT"]));
        assert!(probe_of(&["Sub", "Shut"]));
    }

    #[test]
    fn an_eperm_means_no() {
        assert!(refuses(&io::Error::from_raw_os_error(libc::EPERM)));
        assert!(!refuses(&io::Error::from_raw_os_error(libc::EACCES)));
        assert!(!refuses(&io::Error::from_raw_os_error(libc::ENOENT)));
        assert!(!refuses(&io::Error::other("no errno")));
    }
}
