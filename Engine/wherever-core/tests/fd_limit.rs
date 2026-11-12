use std::fs;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};
use std::time::Duration;

use wherever_core::{Engine, EngineConfig, EngineError, EngineListener, EnginePhase, EngineState};

const OPEN_MAX: libc::rlim_t = 10240;

struct Listener(Sender<EngineState>);

impl EngineListener for Listener {
    fn state_changed(&self, state: EngineState) -> Result<(), EngineError> {
        let _ = self.0.send(state);
        Ok(())
    }

    fn results_changed(&self, _opened_only: bool) -> Result<(), EngineError> {
        Ok(())
    }

    fn results_ready(&self, _generation: u64, _count: u32) -> Result<(), EngineError> {
        Ok(())
    }

    fn search_failed(&self, _generation: u64) -> Result<(), EngineError> {
        Ok(())
    }

    fn content_progress(
        &self,
        _generation: u64,
        _read: u64,
        _total: u64,
        _not_downloaded: u64,
        _unreadable: u64,
        _done: bool,
    ) -> Result<(), EngineError> {
        Ok(())
    }

    fn fault(&self, _message: String) -> Result<(), EngineError> {
        Ok(())
    }
}

struct Tree {
    root: PathBuf,
    data: PathBuf,
}

const FILES: [&str; 4] = ["Alpha.TXT", "beta.txt", "Gamma.md", "Sub/DELTA.Txt"];
const STEPS: [&str; 3] = ["above", "raised", "short"];

impl Tree {
    fn new() -> Tree {
        let root =
            std::env::temp_dir().join(format!("wherever-core-{}-fdlimit", std::process::id()));
        let tree = Tree {
            data: PathBuf::from(format!("{}-data", root.display())),
            root,
        };
        tree.remove();
        fs::create_dir_all(tree.root.join("Sub")).unwrap();
        for name in FILES {
            fs::write(tree.root.join(name), b"").unwrap();
        }
        std::os::unix::fs::symlink("Alpha.TXT", tree.root.join("link")).unwrap();
        tree
    }

    fn data(&self, step: &str) -> PathBuf {
        self.data.join(step)
    }

    fn remove(&self) {
        for name in FILES.iter().chain(&["link"]) {
            let _ = fs::remove_file(self.root.join(name));
        }
        for dir in [self.root.join("Sub"), self.root.clone()] {
            let _ = fs::remove_dir(dir);
        }
        for step in STEPS {
            for file in ["wherever.index", "wherever.index.tmp"] {
                let _ = fs::remove_file(self.data(step).join(file));
            }
            let _ = fs::remove_dir(self.data(step));
        }
        let _ = fs::remove_dir(&self.data);
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        self.remove();
    }
}

fn limit() -> libc::rlimit {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    assert_eq!(
        unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) },
        0
    );
    limit
}

fn set_limit(soft: libc::rlim_t, hard: libc::rlim_t) {
    let limit = libc::rlimit {
        rlim_cur: soft,
        rlim_max: hard,
    };
    assert_eq!(
        unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) },
        0,
        "setrlimit({soft}, {hard}): {}",
        std::io::Error::last_os_error()
    );
}

fn index(tree: &Tree, step: &str) -> u64 {
    let (events, rx) = mpsc::channel();
    let config = EngineConfig {
        root: tree.root.to_str().unwrap().to_owned(),
        home: tree.root.join("home").to_str().unwrap().to_owned(),
        data_folder: tree.data(step).to_str().unwrap().to_owned(),
        socket_folder: Some(tree.data(step).to_str().unwrap().to_owned()),
        excluded: Vec::new(),
        indexed_volumes: Vec::new(),
        live_updates_paused: false,
    };
    let engine = Engine::new(config, Arc::new(Listener(events))).unwrap();
    let mut phases = Vec::new();
    let indexed = loop {
        let state = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        phases.push(state.phase);
        if state.phase == EnginePhase::Ready {
            break state.indexed;
        }
    };
    assert_eq!(
        phases,
        [
            EnginePhase::Crawling,
            EnginePhase::Finishing,
            EnginePhase::Ready
        ],
        "{step}"
    );
    drop(engine);
    indexed
}

#[test]
fn the_engine_raises_the_open_file_limit_and_a_short_one_leaves_a_folder_out() {
    let tree = Tree::new();
    let start = limit();
    let target = OPEN_MAX.min(start.rlim_max);

    let high = start.rlim_cur.max((target + 1).min(start.rlim_max));
    if high != start.rlim_cur {
        set_limit(high, start.rlim_max);
    }
    assert_eq!(index(&tree, STEPS[0]), 6);
    assert_eq!(limit().rlim_cur, high);
    if high != start.rlim_cur {
        set_limit(start.rlim_cur, start.rlim_max);
    }

    let n = fs::File::open("/dev/null").unwrap().as_raw_fd() as libc::rlim_t;
    set_limit(n + 1, start.rlim_max);
    assert_eq!(index(&tree, STEPS[1]), 6);
    assert_eq!(limit().rlim_cur, target);

    set_limit(n + 1, n + 1);
    assert_eq!(index(&tree, STEPS[2]), 5);
    assert_eq!(limit().rlim_cur, n + 1);
}
