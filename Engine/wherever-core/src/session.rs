use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Sender, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use crate::engine::{Content, Engine, Job, Results};
use crate::query;
use crate::text::Terms;
use crate::{EngineError, EngineHit, EngineSort};

pub(crate) struct Lane {
    pub(crate) id: u64,
    latest: AtomicU64,
    pressed: AtomicU64,
    wanted: Mutex<Wanted>,
    wake: SyncSender<()>,
    #[cfg(test)]
    freed: Mutex<Option<Sender<std::thread::ThreadId>>>,
}

struct Wanted {
    queued: bool,
    stopped: bool,
    query: String,
    asked: u64,
    sort: EngineSort,
    held: Option<Arc<Results>>,
    previous: Option<Arc<Results>>,
    narrow: bool,
    press: Option<Press>,
    content: Option<Arc<Content>>,
    halted: bool,
    live: bool,
}

pub(crate) type Press = (u64, String, Terms);

pub(crate) enum Ask {
    Search(String),
    Refresh(String),
    Press(String, Terms),
    Narrow(String),
    Sort,
}

pub(crate) struct Work {
    pub query: String,
    pub asked: u64,
    pub sort: EngineSort,
    pub held: Option<Arc<Results>>,
    pub narrow: bool,
    pub press: Option<Press>,
    pub live: bool,
}

impl Lane {
    pub(crate) fn new(id: u64, sort: EngineSort, wake: SyncSender<()>) -> Arc<Lane> {
        Arc::new(Lane {
            id,
            wake,
            latest: AtomicU64::new(0),
            pressed: AtomicU64::new(0),
            wanted: Mutex::new(Wanted {
                queued: false,
                stopped: false,
                query: String::new(),
                asked: 0,
                sort,
                held: None,
                previous: None,
                narrow: false,
                press: None,
                content: None,
                halted: false,
                live: false,
            }),
            #[cfg(test)]
            freed: Mutex::new(None),
        })
    }

    fn wanted(&self) -> MutexGuard<'_, Wanted> {
        self.wanted.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn latest(&self) -> u64 {
        self.latest.load(Ordering::Relaxed)
    }

    pub(crate) fn pressed(&self) -> u64 {
        self.pressed.load(Ordering::Relaxed)
    }

    pub(crate) fn ask(
        self: &Arc<Self>,
        counter: &AtomicU64,
        jobs: &Sender<Job>,
        ask: Ask,
        sort: EngineSort,
    ) -> Result<u64, EngineError> {
        let mut w = self.wanted();
        if w.stopped {
            return Err(EngineError::Stopped);
        }
        let generation = counter.fetch_add(1, Ordering::Relaxed) + 1;
        if matches!(ask, Ask::Search(_) | Ask::Refresh(_) | Ask::Press(..)) {
            if let Some(old) = w.content.take() {
                old.stop.store(true, Ordering::Relaxed);
            }
            w.halted = false;
        }
        w.live = matches!(ask, Ask::Refresh(_));
        let (query, narrow) = match ask {
            Ask::Search(query) | Ask::Refresh(query) => {
                w.press = None;
                self.pressed.store(0, Ordering::Relaxed);
                (Some(query), false)
            }
            Ask::Press(query, terms) => {
                w.press = Some((generation, query.clone(), terms));
                self.pressed.store(generation, Ordering::Relaxed);
                (Some(query), true)
            }
            Ask::Narrow(query) => (Some(query), true),
            Ask::Sort => (None, w.narrow),
        };
        if let Some(query) = query {
            w.query = query;
            w.asked = generation;
            w.narrow = narrow;
        }
        w.sort = sort;
        self.latest.store(generation, Ordering::Relaxed);
        if !w.queued {
            jobs.send(Job {
                generation,
                lane: Arc::downgrade(self),
            })
            .map_err(|_| EngineError::Stopped)?;
            w.queued = true;
        }
        Ok(generation)
    }

    pub(crate) fn wake(lane: &Weak<Self>) -> Result<(), EngineError> {
        let Some(wake) = lane.upgrade().map(|lane| lane.wake.clone()) else {
            return Ok(());
        };
        match wake.try_send(()) {
            Ok(()) | Err(TrySendError::Full(())) => Ok(()),
            Err(TrySendError::Disconnected(())) => {
                let Some(lane) = lane.upgrade() else {
                    return Ok(());
                };
                lane.halt();
                Err(EngineError::Stopped)
            }
        }
    }

    pub(crate) fn halt(&self) {
        self.wanted().stopped = true;
        self.stop_content();
    }

    pub(crate) fn take_job(self: &Arc<Self>) -> Job {
        let mut w = self.wanted();
        w.queued = false;
        Job {
            generation: self.latest(),
            lane: Arc::downgrade(self),
        }
    }

    pub(crate) fn work(&self, generation: u64) -> Option<Work> {
        let mut w = self.wanted();
        (self.latest() == generation && w.asked != 0).then(|| Work {
            query: w.query.clone(),
            asked: w.asked,
            sort: w.sort,
            held: w.held.clone(),
            narrow: w.narrow,
            press: w.press.take(),
            live: w.live,
        })
    }

    pub(crate) fn hold(&self, content: &Arc<Content>) -> bool {
        let mut w = self.wanted();
        let current = self.pressed() == content.press;
        if current {
            if std::mem::take(&mut w.halted) {
                content.stop.store(true, Ordering::Relaxed);
            }
            w.content = Some(content.clone());
        }
        current
    }

    pub(crate) fn content(&self) -> Option<Arc<Content>> {
        self.wanted().content.clone()
    }

    pub(crate) fn view(&self, generation: u64, content: &Content) -> Option<(String, EngineSort)> {
        let w = self.wanted();
        let narrows = w
            .content
            .as_deref()
            .is_some_and(|c| std::ptr::eq(c, content));
        (self.latest() == generation && w.narrow && narrows).then(|| (w.query.clone(), w.sort))
    }

    fn stop_content(&self) {
        let mut w = self.wanted();
        match &w.content {
            Some(c) => c.stop.store(true, Ordering::Relaxed),
            None => w.halted = true,
        }
    }

    pub(crate) fn publish(&self, results: Results) -> bool {
        let mut w = self.wanted();
        let generation = results.generation;
        let current = self.latest() == generation;
        let mut replaced = None;
        if current {
            replaced = w.held.replace(Arc::new(results));
            if replaced
                .as_ref()
                .is_some_and(|old| old.generation != generation)
            {
                replaced = std::mem::replace(&mut w.previous, replaced);
            }
        }
        drop(w);
        drop(replaced);
        current
    }

    pub(crate) fn rows(
        &self,
        generation: u64,
        start: u32,
        count: u32,
    ) -> Result<Vec<EngineHit>, EngineError> {
        let mut w = self.wanted();
        let newest = w.held.clone().filter(|r| r.generation == generation);
        let freed = if newest.is_some() {
            w.previous.take()
        } else {
            None
        };
        let r = newest
            .or_else(|| w.previous.clone().filter(|r| r.generation == generation))
            .ok_or(EngineError::Stale { generation });
        drop(w);
        if let Some(set) = freed {
            self.free(set);
        }
        let r = r?;
        let rows = r.rows(start as usize, count as usize);
        if let Some(set) = Arc::into_inner(r) {
            self.free(set);
        }
        Ok(rows)
    }

    fn free(&self, set: impl Send + 'static) {
        #[cfg(test)]
        let freed = self.freed.lock().unwrap().take();
        rayon::spawn(move || {
            drop(set);
            #[cfg(test)]
            if let Some(freed) = freed {
                let _ = freed.send(std::thread::current().id());
            }
        });
    }
}

#[derive(uniffi::Object)]
pub struct EngineSession {
    pub(crate) lane: Arc<Lane>,
    engine: Arc<Engine>,
}

impl EngineSession {
    pub(crate) fn new(engine: Arc<Engine>, lane: Arc<Lane>) -> EngineSession {
        EngineSession { engine, lane }
    }
}

impl Drop for EngineSession {
    fn drop(&mut self) {
        self.lane.stop_content();
        let mut w = self.lane.wanted();
        let sets = (w.held.take(), w.previous.take(), w.content.take());
        drop(w);
        self.lane.free(sets);
    }
}

#[uniffi::export]
impl EngineSession {
    pub fn id(&self) -> Result<u64, EngineError> {
        Ok(self.lane.id)
    }

    pub fn search(&self, query: String, sort: EngineSort) -> Result<u64, EngineError> {
        self.engine.ask(&self.lane, Ask::Search(query), sort)
    }

    pub fn refresh(&self, query: String, sort: EngineSort) -> Result<u64, EngineError> {
        self.engine.ask(&self.lane, Ask::Refresh(query), sort)
    }

    pub fn sort(&self, sort: EngineSort) -> Result<u64, EngineError> {
        self.engine.ask(&self.lane, Ask::Sort, sort)
    }

    pub fn search_content(
        &self,
        query: String,
        terms: Vec<String>,
        match_all: bool,
        sort: EngineSort,
    ) -> Result<u64, EngineError> {
        let terms: Vec<_> = (terms.iter().map(|t| t.trim()))
            .filter(|t| !t.is_empty())
            .map(query::term)
            .collect();
        if terms.is_empty() {
            return Err(EngineError::Io {
                message: "Search Content has no term to look for".to_owned(),
            });
        }
        let terms = Terms {
            terms,
            all: match_all,
        };
        self.engine.ask(&self.lane, Ask::Press(query, terms), sort)
    }

    pub fn narrow(&self, query: String, sort: EngineSort) -> Result<u64, EngineError> {
        self.engine.ask(&self.lane, Ask::Narrow(query), sort)
    }

    pub fn stop_content(&self) -> Result<(), EngineError> {
        self.lane.stop_content();
        Ok(())
    }

    pub fn rows(
        &self,
        generation: u64,
        start: u32,
        count: u32,
    ) -> Result<Vec<EngineHit>, EngineError> {
        self.lane.rows(generation, start, count)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crawl::tests::TempTree;
    use crate::engine::BEST_MATCH;
    use crate::engine::tests::{
        Event, config, failed, next, phases, ready, seek, shared, start, start_with, until_live,
    };
    use crate::{EngineColumn, EngineMatch, EnginePhase, EngineVolume};
    use std::fs::{self, File};
    use std::path::Path;
    use std::sync::mpsc::{self, Receiver};
    use std::time::{Duration, Instant, UNIX_EPOCH};

    fn names(session: &EngineSession, generation: u64, count: u32) -> Vec<String> {
        session
            .rows(generation, 0, count)
            .unwrap()
            .into_iter()
            .map(|h| h.name)
            .collect()
    }

    fn stale(got: Result<Vec<EngineHit>, EngineError>) -> bool {
        matches!(got, Err(EngineError::Stale { .. }))
    }

    fn scans(engine: &Engine) -> usize {
        shared(engine).scans.load(Ordering::Relaxed)
    }

    pub(crate) fn hold_scan(engine: &Engine) -> (Receiver<u64>, Sender<()>) {
        let (reached_tx, reached) = mpsc::channel();
        let (release, held) = mpsc::channel();
        *shared(engine).scan_hold.lock().unwrap() = Some((reached_tx, held));
        (reached, release)
    }

    fn patches(engine: &Engine) -> usize {
        shared(engine).patches.load(Ordering::Relaxed)
    }

    fn hold_patch(engine: &Engine) -> (Receiver<u64>, Sender<()>) {
        let (reached_tx, reached) = mpsc::channel();
        let (release, held) = mpsc::channel();
        *shared(engine).patch_hold.lock().unwrap() = Some((reached_tx, held));
        (reached, release)
    }

    fn no_ready(rx: &Receiver<Event>, wait: Duration) {
        let deadline = Instant::now() + wait;
        while let Ok(e) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            assert!(!matches!(e, Event::Ready(..) | Event::Fault(_)), "{e:?}");
        }
    }

    fn next_ready(rx: &Receiver<Event>, generation: u64) -> u32 {
        loop {
            match next(rx) {
                Event::Ready(g, count) => {
                    assert_eq!(g, generation, "an older generation answered");
                    return count;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    fn by(column: EngineColumn, ascending: bool) -> EngineSort {
        EngineSort {
            column,
            ascending,
            folders_first: false,
        }
    }

    #[test]
    fn two_sessions_keep_their_own_rows() {
        let tree = TempTree::new("session-two");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let b = engine.clone().session().unwrap();
        assert_ne!(a.id().unwrap(), b.id().unwrap());
        let ga = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, ga), 1);
        let gb = b.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, gb), 1);
        assert_eq!(names(&a, ga, 10), ["Alpha.TXT"]);
        assert_eq!(names(&b, gb, 10), ["Gamma.md"]);
        assert!(stale(b.rows(ga, 0, 10)));
        assert!(stale(a.rows(gb, 0, 10)));
        let gb2 = b.search("beta".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, gb2), 1);
        let c = engine.clone().session().unwrap();
        let g = c.search("delta".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert_eq!(names(&a, ga, 10), ["Alpha.TXT"]);
        assert_eq!(names(&b, gb2, 10), ["beta.txt"]);
        assert!(stale(b.rows(gb, 0, 10)));
        assert_eq!(names(&c, g, 10), ["DELTA.Txt"]);
    }

    #[test]
    fn a_search_in_another_session_never_cancels_a_running_one() {
        let tree = TempTree::new("session-apart");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let b = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let ga = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
        let gb = b.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(next_ready(&rx, gb), 1);
        release.send(()).unwrap();
        assert_eq!(next_ready(&rx, ga), 1);
        assert_eq!(names(&a, ga, 10), ["Alpha.TXT"]);
        assert_eq!(names(&b, gb, 10), ["Gamma.md"]);
    }

    #[test]
    fn a_keystroke_answers_while_another_sessions_full_list_is_held() {
        let tree = TempTree::new("session-full-list");
        fs::write(tree.0.join("report.txt"), b"").unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let b = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let ga = a
            .search(String::new(), by(EngineColumn::Name, true))
            .unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
        let gb = b.search("report".to_owned(), BEST_MATCH).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match rx
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .unwrap()
            {
                Event::Ready(g, count) => {
                    assert_eq!((g, count), (gb, 1));
                    break;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        assert_eq!(names(&b, gb, 10), ["report.txt"]);
        assert!(stale(a.rows(ga, 0, 10)));
        release.send(()).unwrap();
        assert_eq!(next_ready(&rx, ga), 7);
        assert_eq!(
            names(&a, ga, 10),
            [
                "Alpha.TXT",
                "beta.txt",
                "DELTA.Txt",
                "Gamma.md",
                "link",
                "report.txt",
                "Sub"
            ]
        );
        assert_eq!(names(&b, gb, 10), ["report.txt"]);
    }

    #[test]
    fn a_newer_search_drops_the_running_one_of_its_session() {
        let tree = TempTree::new("session-newer");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(
            reached.recv_timeout(Duration::from_secs(10)).unwrap(),
            first
        );
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        release.send(()).unwrap();
        assert_eq!(next_ready(&rx, second), 1);
        no_ready(&rx, Duration::from_millis(300));
        assert!(stale(a.rows(first, 0, 10)));
        assert_eq!(names(&a, second, 10), ["Gamma.md"]);
    }

    fn set_of(session: &EngineSession, generation: u64) -> Weak<Results> {
        let w = session.lane.wanted();
        let set = [&w.held, &w.previous]
            .into_iter()
            .flatten()
            .find(|r| r.generation == generation)
            .expect("the lane holds no set of that generation");
        Arc::downgrade(set)
    }

    #[test]
    fn rows_answer_the_previous_generation_until_the_newer_one_is_asked() {
        let tree = TempTree::new("session-previous");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        assert_eq!(names(&a, first, 10), ["Alpha.TXT"]);
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, second), 1);
        assert_eq!(names(&a, first, 10), ["Alpha.TXT"]);
        let old = set_of(&a, first);
        assert_eq!(names(&a, second, 10), ["Gamma.md"]);
        assert!(stale(a.rows(first, 0, 10)));
        let deadline = Instant::now() + Duration::from_secs(10);
        while old.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            old.strong_count(),
            0,
            "the first set outlived the first ask for the second"
        );
        assert_eq!(names(&a, second, 10), ["Gamma.md"]);
    }

    #[test]
    fn the_replaced_set_is_freed_off_the_thread_that_asks_for_rows() {
        let tree = TempTree::new("session-free-thread");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, second), 1);
        let old = set_of(&a, first);
        let (hook, freed_on) = mpsc::channel();
        *a.lane.freed.lock().unwrap() = Some(hook);
        assert_eq!(names(&a, second, 10), ["Gamma.md"]);
        let thread = freed_on
            .recv_timeout(Duration::from_secs(10))
            .expect("the first set was not handed off to be freed");
        assert_ne!(
            thread,
            std::thread::current().id(),
            "the first set was freed on the thread that asked for rows"
        );
        assert_eq!(old.strong_count(), 0, "the hand-off did not free the set");
    }

    #[test]
    fn the_previous_set_is_freed_on_the_next_publish() {
        let tree = TempTree::new("session-previous-freed");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, second), 1);
        let old = set_of(&a, first);
        let third = a.search("beta".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, third), 1);
        assert_eq!(old.strong_count(), 0, "two sets held besides the newest");
        assert!(stale(a.rows(first, 0, 10)));
        assert_eq!(names(&a, second, 10), ["Gamma.md"]);

        let sets = [set_of(&a, third), set_of(&a, second)];
        drop(a);
        let deadline = Instant::now() + Duration::from_secs(10);
        while sets.iter().any(|s| s.strong_count() > 0) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            sets.iter().all(|s| s.strong_count() == 0),
            "a closed window kept its sets"
        );
    }

    #[test]
    fn a_closed_sessions_sets_are_freed_off_the_thread_that_drops_it() {
        let tree = TempTree::new("session-close-free");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, second), 1);
        let sets = [set_of(&a, first), set_of(&a, second)];
        let (hook, freed_on) = mpsc::channel();
        *a.lane.freed.lock().unwrap() = Some(hook);
        drop(a);
        let thread = freed_on
            .recv_timeout(Duration::from_secs(10))
            .expect("the closed session's sets were not handed off to be freed");
        assert_ne!(
            thread,
            std::thread::current().id(),
            "the closed session's sets were freed on the thread that dropped it"
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        while sets.iter().any(|s| s.strong_count() > 0) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            sets.iter().all(|s| s.strong_count() == 0),
            "the hand-off did not free the sets"
        );
    }

    #[test]
    fn a_closed_sessions_walked_files_are_freed_off_the_thread_that_drops_it() {
        let tree = TempTree::new("session-close-walked");
        let other = TempTree::new("session-close-walked-beside");
        fs::write(other.0.join("o.txt"), "zyq").unwrap();
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let a = engine.clone().session().unwrap();
        let press = a
            .search_content(
                format!("in:{}", other.real()),
                vec!["zyq".to_owned()],
                true,
                BEST_MATCH,
            )
            .unwrap();
        loop {
            match next(&rx) {
                Event::Progress(p, _, _, true) if p == press => break,
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        let content = Arc::downgrade(&a.lane.content().unwrap());
        let lane = a.lane.clone();
        let (hook, freed_on) = mpsc::channel();
        *lane.freed.lock().unwrap() = Some(hook);
        drop(a);
        let thread = freed_on
            .recv_timeout(Duration::from_secs(10))
            .expect("the closed session's walked files were not handed off to be freed");
        assert_ne!(
            thread,
            std::thread::current().id(),
            "the closed session's walked files were freed on the thread that dropped it"
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        while content.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            content.strong_count(),
            0,
            "the lane kept the walked files after its session closed"
        );
    }

    #[test]
    fn a_running_scan_keeps_a_closed_sessions_lane_until_it_ends() {
        let tree = TempTree::new("session-close-scan");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let first = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, first), 1);
        let set = set_of(&a, first);
        let lane = Arc::downgrade(&a.lane);
        let (reached, release) = hold_scan(&engine);
        let second = a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(
            reached.recv_timeout(Duration::from_secs(10)).unwrap(),
            second
        );
        let (hook, freed_on) = mpsc::channel();
        *a.lane.freed.lock().unwrap() = Some(hook);
        drop(a);
        let thread = freed_on
            .recv_timeout(Duration::from_secs(10))
            .expect("the closed session's set was not handed off while its scan ran");
        assert_ne!(thread, std::thread::current().id());
        let deadline = Instant::now() + Duration::from_secs(10);
        while set.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(set.strong_count(), 0, "the old set waited for the scan");
        assert!(
            lane.strong_count() > 0,
            "the lane died while its scan still ran"
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while lane.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            lane.strong_count(),
            0,
            "the scan kept the lane after it ended"
        );
        no_ready(&rx, Duration::from_millis(300));
    }

    #[test]
    fn requests_keep_one_pending_wake_per_session() {
        let (jobs, queued) = mpsc::channel();
        let (wake, pending) = mpsc::sync_channel(1);
        let lane = Lane::new(1, BEST_MATCH, wake);
        let counter = AtomicU64::new(0);
        for batch in 0..2 {
            for i in 1..=1000 {
                let generation = batch * 1000 + i;
                assert_eq!(
                    lane.ask(
                        &counter,
                        &jobs,
                        Ask::Search(format!("report{generation}")),
                        BEST_MATCH
                    )
                    .unwrap(),
                    generation
                );
            }
            let job = queued.try_recv().unwrap();
            assert_eq!(job.generation, batch * 1000 + 1);
            assert!(matches!(queued.try_recv(), Err(mpsc::TryRecvError::Empty)));
            Lane::wake(&job.lane).unwrap();
            pending.try_recv().unwrap();
            assert!(matches!(pending.try_recv(), Err(mpsc::TryRecvError::Empty)));
            let job = lane.take_job();
            assert_eq!(job.generation, (batch + 1) * 1000);
            assert_eq!(
                lane.work(job.generation).unwrap().query,
                format!("report{}", job.generation)
            );
        }
        drop(pending);
        lane.ask(
            &counter,
            &jobs,
            Ask::Search("report".to_owned()),
            BEST_MATCH,
        )
        .unwrap();
        let job = queued.try_recv().unwrap();
        assert!(matches!(Lane::wake(&job.lane), Err(EngineError::Stopped)));
        assert!(matches!(
            lane.ask(&counter, &jobs, Ask::Search("newer".to_owned()), BEST_MATCH),
            Err(EngineError::Stopped)
        ));
        assert!(matches!(queued.try_recv(), Err(mpsc::TryRecvError::Empty)));
    }

    #[test]
    fn a_dropped_session_skips_its_queued_job() {
        let tree = TempTree::new("session-dropped");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let ga = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
        a.search("gamma".to_owned(), BEST_MATCH).unwrap();
        let before = scans(&engine);
        drop(a);
        release.send(()).unwrap();
        no_ready(&rx, Duration::from_millis(500));
        assert_eq!(scans(&engine), before);
    }

    #[test]
    fn a_dropped_session_cancels_its_running_scan() {
        let tree = TempTree::new("session-dropped-running");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let ga = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
        let wake = a.lane.wake.clone();
        drop(a);
        let b = engine.clone().session().unwrap();
        let gb = b.search("gamma".to_owned(), BEST_MATCH).unwrap();
        release.send(()).unwrap();
        assert_eq!(next_ready(&rx, gb), 1);
        assert_eq!(names(&b, gb, 10), ["Gamma.md"]);
        no_ready(&rx, Duration::from_millis(300));
        drop(wake);
    }

    #[test]
    fn a_dropped_session_cancels_its_first_content_scan() {
        let tree = TempTree::new("session-dropped-press");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let ga = a
            .search_content(String::new(), vec!["alpha".to_owned()], true, BEST_MATCH)
            .unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), ga);
        let lane = Arc::downgrade(&a.lane);
        let wake = a.lane.wake.clone();
        drop(a);
        let b = engine.clone().session().unwrap();
        let gb = b.search("gamma".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(next_ready(&rx, gb), 1);
        assert_eq!(names(&b, gb, 10), ["Gamma.md"]);
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while lane.strong_count() != 0 {
            assert!(Instant::now() < deadline, "the closed press kept scanning");
            std::thread::sleep(Duration::from_millis(10));
        }
        for e in rx.try_iter() {
            assert!(
                !matches!(e, Event::Ready(..) | Event::Progress(..) | Event::Fault(_)),
                "{e:?}"
            );
        }
        assert!(shared(&engine).reads.lock().unwrap().is_empty());
        assert_eq!(names(&b, gb, 10), ["Gamma.md"]);
        drop(wake);
    }

    #[test]
    fn a_dropped_sessions_read_stops_while_another_session_searches() {
        use crate::text::READERS;

        let tree = TempTree::new("session-dropped-reading");
        fs::create_dir(tree.0.join("Out")).unwrap();
        for i in 0..READERS * 2 {
            fs::write(tree.0.join(format!("Out/zz{i}.txt")), "needle").unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let (tx, reached) = mpsc::sync_channel(READERS);
        *shared(&engine).read_reached.lock().unwrap() = Some(tx);
        let gate = shared(&engine).read_gate.write().unwrap();
        let a = engine.clone().session().unwrap();
        let ga = a
            .search_content(
                format!("in:{}/Out", tree.real()),
                vec!["needle".to_owned()],
                true,
                BEST_MATCH,
            )
            .unwrap();
        for _ in 0..READERS {
            reached.recv_timeout(Duration::from_secs(10)).unwrap();
        }
        loop {
            match next(&rx) {
                Event::Progress(p, 0, total, false) if p == ga => {
                    assert_eq!(total, (READERS * 2) as u64);
                    break;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
        let content = Arc::downgrade(&a.lane.content().unwrap());
        drop(a);
        let b = engine.clone().session().unwrap();
        let gb = b.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(next_ready(&rx, gb), 1);
        assert_eq!(names(&b, gb, 10), ["Alpha.TXT"]);
        drop(gate);
        let deadline = Instant::now() + Duration::from_secs(10);
        while content.strong_count() != 0 {
            assert!(Instant::now() < deadline, "the closed session kept reading");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(shared(&engine).reads.lock().unwrap().len(), READERS);
        for e in rx.try_iter() {
            assert!(
                !matches!(e, Event::Ready(..) | Event::Progress(..) | Event::Fault(_)),
                "{e:?}"
            );
        }
    }

    #[test]
    fn the_last_session_and_the_engine_join_the_worker() {
        let tree = TempTree::new("session-join");
        let (engine, listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let idle = engine.clone().session().unwrap();
        drop(engine);
        let g = a.search("alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 1);
        assert!(Arc::strong_count(&listener) > 1);
        drop(a);
        assert!(Arc::strong_count(&listener) > 1);
        drop(idle);
        assert_eq!(Arc::strong_count(&listener), 1);
    }

    #[test]
    fn a_sort_during_a_search_finishes_that_search_once_in_the_new_order() {
        let tree = TempTree::new("session-pending");
        let (release, hold) = mpsc::channel();
        let (engine, _listener, rx) =
            start_with(config(&tree), Some((EnginePhase::Ready, 0, hold)));
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let searched = a.search("txt".to_owned(), BEST_MATCH).unwrap();
        let sorted = a.sort(by(EngineColumn::Name, false)).unwrap();
        assert!(sorted > searched);
        release.send(None).unwrap();
        assert_eq!(next_ready(&rx, sorted), 3);
        assert_eq!(
            names(&a, sorted, 10),
            ["DELTA.Txt", "beta.txt", "Alpha.TXT"]
        );
        assert_eq!(scans(&engine), 1);
        assert!(stale(a.rows(searched, 0, 10)));
    }

    #[test]
    fn a_sort_before_any_search_answers_nothing() {
        let tree = TempTree::new("session-early");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        a.sort(by(EngineColumn::Size, true)).unwrap();
        no_ready(&rx, Duration::from_millis(300));
        assert_eq!(scans(&engine), 0);
    }

    fn put(path: &Path, len: u64, mtime: u64) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let f = File::create(path).unwrap();
        f.set_len(len).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs(mtime))
            .unwrap();
    }

    const T: u64 = 1_000_000_000;

    #[test]
    fn each_column_sorts_both_ways_across_two_units() {
        let boot = TempTree::new("session-sort");
        let disk = TempTree::new("session-sort-disk");
        let (b, d) = (&boot.0, &disk.0);
        put(&b.join("file10.txt"), 110, T + 10);
        put(&b.join("Zeta/file2.md"), 300, T + 30);
        put(&b.join("éa-file.txt"), 140, T + 40);
        put(&b.join("Éb-file.TXT"), 150, T + 50);
        put(&d.join("file1.txt"), 120, T + 20);
        put(&d.join("Alpha/file3.pdf"), 1000, T + 60);
        fs::create_dir(b.join("file-a")).unwrap();
        let folder = File::open(b.join("file-a")).unwrap();
        folder
            .set_modified(UNIX_EPOCH + Duration::from_secs(T))
            .unwrap();
        std::os::unix::fs::symlink("file10.txt", b.join("file-link")).unwrap();
        let (br, dr) = (boot.real(), disk.real());
        let (zeta, alpha) = (format!("{br}/Zeta"), format!("{dr}/Alpha"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let volume = EngineVolume {
            root: disk.real(),
            id: "0E0E0E0E-0000-4000-8000-00000000000E".to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        let want = [
            ("file10.txt", br.as_str()),
            ("file2.md", zeta.as_str()),
            ("éa-file.txt", br.as_str()),
            ("Éb-file.TXT", br.as_str()),
            ("file-a", br.as_str()),
            ("file-link", br.as_str()),
            ("file1.txt", dr.as_str()),
            ("file3.pdf", alpha.as_str()),
        ];
        seek(&engine, &rx, "file", &want, false);
        let a = engine.clone().session().unwrap();
        let searched = a.search("file".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, searched), 8);
        let best = names(&a, searched, 8);
        let scanned = scans(&engine);
        let mut worst = best.clone();
        worst.reverse();
        let cases: [(EngineColumn, Vec<String>); 6] = [
            (EngineColumn::Relevance, worst),
            (
                EngineColumn::Name,
                [
                    "file-a",
                    "file-link",
                    "file1.txt",
                    "file2.md",
                    "file3.pdf",
                    "file10.txt",
                    "éa-file.txt",
                    "Éb-file.TXT",
                ]
                .map(str::to_owned)
                .to_vec(),
            ),
            (
                EngineColumn::Folder,
                [
                    "file-a",
                    "file-link",
                    "file10.txt",
                    "éa-file.txt",
                    "Éb-file.TXT",
                    "file1.txt",
                    "file3.pdf",
                    "file2.md",
                ]
                .map(str::to_owned)
                .to_vec(),
            ),
            (
                EngineColumn::Size,
                [
                    "file-a",
                    "file-link",
                    "file10.txt",
                    "file1.txt",
                    "éa-file.txt",
                    "Éb-file.TXT",
                    "file2.md",
                    "file3.pdf",
                ]
                .map(str::to_owned)
                .to_vec(),
            ),
            (
                EngineColumn::Modified,
                [
                    "file-a",
                    "file10.txt",
                    "file1.txt",
                    "file2.md",
                    "éa-file.txt",
                    "Éb-file.TXT",
                    "file3.pdf",
                    "file-link",
                ]
                .map(str::to_owned)
                .to_vec(),
            ),
            (
                EngineColumn::Kind,
                [
                    "file-a",
                    "file-link",
                    "file2.md",
                    "file3.pdf",
                    "file1.txt",
                    "file10.txt",
                    "éa-file.txt",
                    "Éb-file.TXT",
                ]
                .map(str::to_owned)
                .to_vec(),
            ),
        ];
        let mut last = searched;
        for (column, ascending) in cases {
            let mut descending = ascending.clone();
            descending.reverse();
            for (up, order) in [(true, ascending), (false, descending)] {
                let g = a.sort(by(column, up)).unwrap();
                assert!(g > last);
                assert_eq!(ready(&rx, g), 8);
                assert_eq!(names(&a, g, 8), order, "{column:?} ascending {up}");
                assert!(stale(a.rows(last, 0, 8)));
                last = g;
            }
        }
        assert_eq!(scans(&engine), scanned, "a sort scanned again");
        let g = a.sort(BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 8);
        assert_eq!(names(&a, g, 8), best);
    }

    #[test]
    fn match_ranges_are_utf16_offsets_into_the_name() {
        let tree = TempTree::new("session-ranges");
        let (accent, emoji) = ("Ünal Report.TXT", "😀 Cafe\u{301} Report.txt");
        for name in [accent, emoji] {
            fs::write(tree.0.join(name), b"").unwrap();
        }
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let g = a.search("rep".to_owned(), BEST_MATCH).unwrap();
        let rows = a.rows(g, 0, ready(&rx, g)).unwrap();
        for (name, start) in [(accent, 5), (emoji, 9)] {
            let hit = rows.iter().find(|h| h.name == name).expect(name);
            assert_eq!(hit.matches, [EngineMatch { start, length: 3 }], "{name}");
            let units: Vec<u16> = hit.name.encode_utf16().collect();
            let cut = &units[start as usize..][..3];
            assert_eq!(String::from_utf16(cut).unwrap(), "Rep");
        }
    }

    #[test]
    fn rows_outlive_a_removed_disk_and_a_new_file() {
        let boot = TempTree::new("session-eject");
        let disk = TempTree::new("session-eject-disk");
        let (br, dr) = (boot.real(), disk.real());
        let (bs, ds) = (format!("{br}/Sub"), format!("{dr}/Sub"));
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        let volume = EngineVolume {
            root: disk.real(),
            id: "0F0F0F0F-0000-4000-8000-00000000000F".to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        seek(
            &engine,
            &rx,
            "delta",
            &[("DELTA.Txt", &bs), ("DELTA.Txt", &ds)],
            false,
        );
        let a = engine.clone().session().unwrap();
        let g = a.search("delta".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 2);
        let held = a.rows(g, 0, 10).unwrap();
        engine.set_volumes(Vec::new()).unwrap();
        fs::write(boot.0.join("Sub/delta two.txt"), b"").unwrap();
        let now = [("DELTA.Txt", bs.as_str()), ("delta two.txt", bs.as_str())];
        seek(&engine, &rx, "delta", &now, false);
        assert_eq!(a.rows(g, 0, 10).unwrap(), held);
        let sorted = a.sort(by(EngineColumn::Folder, true)).unwrap();
        assert_eq!(ready(&rx, sorted), 2);
        let folders: Vec<String> = a
            .rows(sorted, 0, 10)
            .unwrap()
            .into_iter()
            .map(|h| h.folder)
            .collect();
        assert_eq!(folders, [ds, bs]);
    }

    #[test]
    fn best_match_keeps_a_typo_below_every_clean_hit() {
        let tree = TempTree::new("session-typos");
        fs::create_dir_all(tree.0.join("Applications/Rpeort.app")).unwrap();
        let deep = tree.0.join("home/Library/Caches/node_modules");
        put(&deep.join("re-port.txt"), 0, T);
        put(&deep.join("repo art.txt"), 0, T);
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        engine.set_typos(true).unwrap();
        let a = engine.clone().session().unwrap();
        let g = a.search("report".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let best = ["re-port.txt", "repo art.txt", "Rpeort.app"];
        assert_eq!(names(&a, g, 3), best);
        let g = a.sort(by(EngineColumn::Relevance, true)).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let mut worst = best;
        worst.reverse();
        assert_eq!(names(&a, g, 3), worst);
    }

    fn scanned_on(engine: &Engine) -> Vec<(String, usize)> {
        shared(engine).scanned_on.lock().unwrap().clone()
    }

    fn ready_within(rx: &Receiver<Event>, generation: u64, wait: Duration) -> u32 {
        let deadline = Instant::now() + wait;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match rx.recv_timeout(left).expect("no answer in time") {
                Event::Ready(g, count) => {
                    assert_eq!(g, generation, "another generation answered");
                    return count;
                }
                Event::Fault(message) => panic!("unexpected engine fault: {message}"),
                _ => {}
            }
        }
    }

    #[test]
    fn a_keystroke_answers_while_a_refresh_is_held() {
        let tree = TempTree::new("session-refresh-keystroke");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let (reached, release) = hold_scan(&engine);
        let gr = a
            .refresh(String::new(), by(EngineColumn::Name, true))
            .unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), gr);
        let gs = a.search("Alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready_within(&rx, gs, Duration::from_secs(2)), 1);
        assert_eq!(names(&a, gs, 10), ["Alpha.TXT"]);
        release.send(()).unwrap();
        no_ready(&rx, Duration::from_millis(300));
        assert!(stale(a.rows(gr, 0, 10)));
    }

    #[test]
    fn a_refresh_scans_on_the_live_thread() {
        let tree = TempTree::new("session-refresh-thread");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let by_name = by(EngineColumn::Name, true);
        let gs = a.search("txt".to_owned(), by_name).unwrap();
        assert_eq!(ready(&rx, gs), 3);
        let listed = names(&a, gs, 10);
        let gr = a.refresh("txt".to_owned(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 3);
        assert_eq!(names(&a, gr, 10), listed);
        let on = scanned_on(&engine);
        assert_eq!(on.len(), 2, "{on:?}");
        assert_eq!(on[0].0, "wherever-search");
        assert!(on[0].1 > 1, "the search ran on a pool of {}", on[0].1);
        assert_eq!(on[1], ("wherever-live-0".to_owned(), 1));
    }

    #[test]
    fn a_sort_during_a_refresh_scans_at_full_speed() {
        let tree = TempTree::new("session-refresh-sort");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let gs = a
            .search("txt".to_owned(), by(EngineColumn::Name, true))
            .unwrap();
        let full = ready(&rx, gs);
        let mut backwards = names(&a, gs, 10);
        backwards.reverse();
        let (reached, release) = hold_scan(&engine);
        let gr = a
            .refresh("txt".to_owned(), by(EngineColumn::Name, true))
            .unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), gr);
        let sorted = a.sort(by(EngineColumn::Name, false)).unwrap();
        assert_eq!(ready_within(&rx, sorted, Duration::from_secs(2)), full);
        release.send(()).unwrap();
        no_ready(&rx, Duration::from_millis(300));
        assert_eq!(names(&a, sorted, 10), backwards);
        let on = scanned_on(&engine);
        assert_eq!(on.len(), 3, "{on:?}");
        assert_eq!(on[1], ("wherever-live-0".to_owned(), 1));
        assert_eq!(on[2].0, "wherever-search");
        assert!(on[2].1 > 1, "the sort ran on a pool of {}", on[2].1);
    }

    #[test]
    fn closing_a_window_stops_its_refresh() {
        let tree = TempTree::new("session-refresh-close");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let lane = Arc::downgrade(&a.lane);
        let (reached, release) = hold_scan(&engine);
        let gr = a
            .refresh(String::new(), by(EngineColumn::Name, true))
            .unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), gr);
        drop(a);
        assert!(
            lane.strong_count() > 0,
            "the lane died while its refresh still ran"
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while lane.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            lane.strong_count(),
            0,
            "the refresh kept the lane after it ended"
        );
        no_ready(&rx, Duration::from_millis(300));
    }

    #[test]
    fn a_panicking_refresh_reports_search_failed() {
        let tree = TempTree::new("session-refresh-panic");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        shared(&engine).fail_scan.store(true, Ordering::Relaxed);
        let lost = a.refresh("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(failed(&rx), lost);
        let g = a.search("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, g), 3);
        let again = a.refresh("txt".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, again), 3);
    }

    fn listed_then_changed(
        name: &str,
    ) -> (TempTree, Arc<Engine>, Receiver<Event>, Arc<EngineSession>) {
        let tree = TempTree::new(name);
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let a = engine.clone().session().unwrap();
        let gs = a
            .search(String::new(), by(EngineColumn::Name, true))
            .unwrap();
        assert_eq!(ready(&rx, gs), 6);
        fs::write(tree.0.join("added.txt"), b"").unwrap();
        let real = tree.real();
        seek(&engine, &rx, "added", &[("added.txt", &real)], true);
        (tree, engine, rx, a)
    }

    #[test]
    fn a_refresh_after_a_change_patches_without_a_scan() {
        let (_tree, engine, rx, a) = listed_then_changed("session-refresh-patch");
        let by_name = by(EngineColumn::Name, true);
        let (scanned, patched) = (scans(&engine), patches(&engine));
        let gr = a.refresh(String::new(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 7);
        assert_eq!((scans(&engine), patches(&engine)), (scanned, patched + 1));
        let b = engine.clone().session().unwrap();
        let gf = b.search(String::new(), by_name).unwrap();
        assert_eq!(ready(&rx, gf), 7);
        assert_eq!(a.rows(gr, 0, 10).unwrap(), b.rows(gf, 0, 10).unwrap());
    }

    #[test]
    fn a_refresh_after_compaction_scans() {
        let tree = TempTree::new("session-refresh-compact");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        until_live(&rx);
        let a = engine.clone().session().unwrap();
        let by_name = by(EngineColumn::Name, true);
        let gs = a.search(String::new(), by_name).unwrap();
        assert_eq!(ready(&rx, gs), 6);
        let listed = names(&a, gs, 10);
        let unit = shared(&engine).units()[0].clone();
        crate::apply::compact(shared(&engine), &unit);
        let (scanned, patched) = (scans(&engine), patches(&engine));
        let gr = a.refresh(String::new(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 6);
        assert_eq!((scans(&engine), patches(&engine)), (scanned + 1, patched));
        assert_eq!(names(&a, gr, 10), listed);
    }

    #[test]
    fn a_refresh_after_a_disk_comes_or_goes_scans() {
        let boot = TempTree::new("session-refresh-units");
        let disk = TempTree::new("session-refresh-units-disk");
        put(&disk.0.join("ondisk.txt"), 1, T);
        let (engine, _listener, rx) = start(&boot);
        phases(&rx);
        until_live(&rx);
        let a = engine.clone().session().unwrap();
        let by_name = by(EngineColumn::Name, true);
        let gs = a.search(String::new(), by_name).unwrap();
        assert_eq!(ready(&rx, gs), 6);
        let volume = EngineVolume {
            root: disk.real(),
            id: "0D0D0D0D-0000-4000-8000-00000000000D".to_owned(),
        };
        engine.set_volumes(vec![volume]).unwrap();
        seek(
            &engine,
            &rx,
            "ondisk",
            &[("ondisk.txt", &disk.real())],
            false,
        );
        let subs = [boot.real(), disk.real()].map(|root| format!("{root}/Sub"));
        let deltas = subs.each_ref().map(|sub| ("DELTA.Txt", sub.as_str()));
        seek(&engine, &rx, "DELTA", &deltas, false);
        let fresh = |rx: &Receiver<Event>| {
            let b = engine.clone().session().unwrap();
            let g = b.search(String::new(), by_name).unwrap();
            let count = ready(rx, g);
            b.rows(g, 0, count).unwrap()
        };
        for step in ["the disk came", "the disk went"] {
            let (scanned, patched) = (scans(&engine), patches(&engine));
            let gr = a.refresh(String::new(), by_name).unwrap();
            let count = next_ready(&rx, gr);
            assert_eq!(
                (scans(&engine), patches(&engine)),
                (scanned + 1, patched),
                "{step}"
            );
            let rows = a.rows(gr, 0, count).unwrap();
            assert_eq!(
                rows.iter().any(|h| h.name == "ondisk.txt"),
                step == "the disk came",
                "{step}"
            );
            assert_eq!(rows, fresh(&rx), "{step}");
            engine.set_volumes(Vec::new()).unwrap();
        }
    }

    #[test]
    fn a_relevance_sort_of_a_patched_set_scans() {
        let (_tree, engine, rx, a) = listed_then_changed("session-refresh-relevance");
        let by_name = by(EngineColumn::Name, true);
        let gr = a.refresh(String::new(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 7);
        let scanned = scans(&engine);
        assert_eq!(patches(&engine), 1);
        let gb = a.sort(BEST_MATCH).unwrap();
        assert_eq!(next_ready(&rx, gb), 7);
        assert_eq!(scans(&engine), scanned + 1);
        let best = a.rows(gb, 0, 10).unwrap();
        let gn = a.sort(by_name).unwrap();
        assert_eq!(next_ready(&rx, gn), 7);
        assert_eq!(scans(&engine), scanned + 1, "the next click scanned again");
        let b = engine.clone().session().unwrap();
        let gf = b.search(String::new(), BEST_MATCH).unwrap();
        assert_eq!(ready(&rx, gf), 7);
        assert_eq!(best, b.rows(gf, 0, 10).unwrap());
    }

    #[test]
    fn a_relevance_scan_of_a_patched_set_does_not_hold_it() {
        let (_tree, engine, rx, a) = listed_then_changed("session-refresh-relevance-free");
        let by_name = by(EngineColumn::Name, true);
        let gr = a.refresh(String::new(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 7);
        assert_eq!(patches(&engine), 1);
        let set = set_of(&a, gr);
        let (reached, release) = hold_scan(&engine);
        let gb = a.sort(BEST_MATCH).unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), gb);
        drop(a);
        let deadline = Instant::now() + Duration::from_secs(10);
        while set.strong_count() > 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            set.strong_count(),
            0,
            "the Relevance scan held the patched set"
        );
        release.send(()).unwrap();
        no_ready(&rx, Duration::from_millis(300));
    }

    #[test]
    fn a_typed_refresh_scans() {
        let tree = TempTree::new("session-refresh-typed");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let by_name = by(EngineColumn::Name, true);
        let gs = a.search("txt".to_owned(), by_name).unwrap();
        assert_eq!(ready(&rx, gs), 3);
        let listed = names(&a, gs, 10);
        let (scanned, patched) = (scans(&engine), patches(&engine));
        let gr = a.refresh("txt".to_owned(), by_name).unwrap();
        assert_eq!(next_ready(&rx, gr), 3);
        assert_eq!((scans(&engine), patches(&engine)), (scanned + 1, patched));
        assert_eq!(names(&a, gr, 10), listed);
    }

    #[test]
    fn a_keystroke_during_a_held_patch_wins() {
        let tree = TempTree::new("session-refresh-patch-keystroke");
        let (engine, _listener, rx) = start(&tree);
        phases(&rx);
        let a = engine.clone().session().unwrap();
        let by_name = by(EngineColumn::Name, true);
        let gs = a.search(String::new(), by_name).unwrap();
        assert_eq!(ready(&rx, gs), 6);
        let (reached, release) = hold_patch(&engine);
        let gr = a.refresh(String::new(), by_name).unwrap();
        assert_eq!(reached.recv_timeout(Duration::from_secs(10)).unwrap(), gr);
        let gk = a.search("Alpha".to_owned(), BEST_MATCH).unwrap();
        assert_eq!(ready_within(&rx, gk, Duration::from_secs(2)), 1);
        release.send(()).unwrap();
        no_ready(&rx, Duration::from_millis(300));
        assert!(stale(a.rows(gr, 0, 10)));
        assert_eq!(patches(&engine), 0);
        assert_eq!(names(&a, gk, 10), ["Alpha.TXT"]);
    }
}
