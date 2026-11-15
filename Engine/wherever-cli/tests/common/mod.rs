use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

use wherever_cli::{Env, System, run};
use wherever_core::{
    Engine, EngineConfig, EngineError, EngineHit, EngineListener, EnginePhase, EngineSort,
    EngineState,
};

enum Event {
    Phase(EnginePhase),
    Ready(u64, u32),
    Failed(u64),
    Fault(String),
}

struct Channel(Sender<Event>);

impl EngineListener for Channel {
    fn state_changed(&self, state: EngineState) -> Result<(), EngineError> {
        let _ = self.0.send(Event::Phase(state.phase));
        Ok(())
    }

    fn results_changed(&self, _opened_only: bool) -> Result<(), EngineError> {
        Ok(())
    }

    fn results_ready(&self, generation: u64, count: u32) -> Result<(), EngineError> {
        let _ = self.0.send(Event::Ready(generation, count));
        Ok(())
    }

    fn search_failed(&self, generation: u64) -> Result<(), EngineError> {
        let _ = self.0.send(Event::Failed(generation));
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

    fn fault(&self, message: String) -> Result<(), EngineError> {
        let _ = self.0.send(Event::Fault(message));
        Ok(())
    }
}

pub struct Dirs {
    pub tree: PathBuf,
    data: PathBuf,
}

impl Drop for Dirs {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.tree);
        let _ = fs::remove_dir_all(&self.data);
    }
}

pub struct Fixture {
    pub engine: Arc<Engine>,
    events: Receiver<Event>,
    pub dirs: Dirs,
}

static NEXT: AtomicU32 = AtomicU32::new(0);

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

pub fn start<S: AsRef<Path>>(excluded: &[&str], files: &[(S, usize)]) -> Fixture {
    let n = NEXT.fetch_add(1, Ordering::SeqCst);
    let data = PathBuf::from(format!(
        "/private/tmp/whv-{:08x}",
        (std::process::id() << 12) | n
    ));
    let tree = PathBuf::from(format!("{}-tree", data.display()));
    let dirs = Dirs { tree, data };
    let _ = fs::remove_dir_all(&dirs.tree);
    let _ = fs::remove_dir_all(&dirs.data);
    for (path, size) in files {
        let path = dirs.tree.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, vec![b'x'; *size]).unwrap();
    }
    let config = EngineConfig {
        root: text(&dirs.tree),
        home: text(&dirs.tree.join("home")),
        data_folder: text(&dirs.data),
        socket_folder: Some(text(&dirs.data)),
        excluded: excluded.iter().map(|e| text(&dirs.tree.join(e))).collect(),
        indexed_volumes: Vec::new(),
        live_updates_paused: false,
    };
    let (send, events) = mpsc::channel();
    let engine = Engine::new(config, Arc::new(Channel(send))).unwrap();
    let fixture = Fixture {
        engine,
        events,
        dirs,
    };
    loop {
        match fixture.next() {
            Event::Phase(EnginePhase::Ready | EnginePhase::Live) => return fixture,
            Event::Phase(EnginePhase::Failed) => panic!("the engine failed to index"),
            Event::Fault(message) => panic!("unexpected engine fault: {message}"),
            _ => {}
        }
    }
}

impl Fixture {
    fn next(&self) -> Event {
        self.events.recv_timeout(Duration::from_secs(30)).unwrap()
    }

    pub fn socket(&self) -> PathBuf {
        self.dirs.data.join("wherever.sock")
    }

    pub fn session_rows(&self, query: &str, sort: EngineSort) -> Vec<EngineHit> {
        let session = self.engine.clone().session().unwrap();
        let generation = session.search(query.to_owned(), sort).unwrap();
        loop {
            match self.next() {
                Event::Ready(g, count) if g == generation => {
                    return session.rows(generation, 0, count).unwrap();
                }
                Event::Failed(g) if g == generation => panic!("the session search failed"),
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    pub fn cli(&self, args: &[&str]) -> (i32, String, String) {
        let args: Vec<String> = args.iter().map(|&a| a.to_owned()).collect();
        let env = Env {
            uid: 501,
            no_color: None,
            term: None,
            host: Box::new(System),
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = run(&args, &mut out, &mut err, &self.socket(), false, &env);
        let text = |b: Vec<u8>| String::from_utf8(b).unwrap();
        (code, text(out), text(err))
    }
}
