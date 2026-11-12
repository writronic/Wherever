use std::env;

use super::tests::{Event, shared, start_with};
use super::*;
use crate::text::READERS;

fn ms(since: Instant) -> u128 {
    since.elapsed().as_millis()
}

const MIB: f64 = (1 << 20) as f64;

fn memory() -> (u64, u64) {
    unsafe {
        let mut info: libc::rusage_info_v2 = std::mem::zeroed();
        let buffer = (&raw mut info).cast::<libc::rusage_info_t>();
        let status = libc::proc_pid_rusage(libc::getpid(), libc::RUSAGE_INFO_V2, buffer);
        assert_eq!(status, 0, "proc_pid_rusage failed");
        (info.ri_phys_footprint, info.ri_resident_size)
    }
}

#[test]
#[ignore = "presses Search Content on the disk WHEREVER_PROBE_ROOT names"]
fn content_press_probe() {
    let root = env::var("WHEREVER_PROBE_ROOT").expect("WHEREVER_PROBE_ROOT is unset");
    let root = fs::canonicalize(&root).expect("WHEREVER_PROBE_ROOT is not a folder");
    let term = env::var("WHEREVER_PROBE_TERM").expect("WHEREVER_PROBE_TERM is unset");
    let walk = env::var("WHEREVER_PROBE_WALK").is_ok_and(|v| v == "1");
    let cap = Duration::from_secs(
        env::var("WHEREVER_PROBE_SECONDS").map_or(1800, |s| s.parse().expect("seconds")),
    );
    let scratch = env::temp_dir().join(format!("wherever-probe-{}", std::process::id()));
    let (data, empty) = (scratch.join("data"), scratch.join("empty"));
    fs::create_dir_all(&empty).unwrap();
    let config = EngineConfig {
        root: if walk { &empty } else { &root }
            .to_str()
            .unwrap()
            .to_owned(),
        home: env::var("HOME").unwrap(),
        data_folder: data.to_str().unwrap().to_owned(),
        socket_folder: Some(data.to_str().unwrap().to_owned()),
        excluded: Vec::new(),
        indexed_volumes: Vec::new(),
        live_updates_paused: false,
    };

    let began = Instant::now();
    let (engine, listener, rx) = start_with(config, None);
    loop {
        match rx.recv().unwrap() {
            Event::State(s) if matches!(s.phase, EnginePhase::Ready | EnginePhase::Live) => {
                if !walk {
                    println!("probe crawl: {} entries in {} ms", s.indexed, ms(began));
                }
                break;
            }
            Event::State(s) => assert_ne!(s.phase, EnginePhase::Failed, "the index failed"),
            Event::Fault(message) => println!("probe fault: {message}"),
            _ => {}
        }
    }

    let mode = if walk { "walk" } else { "index" };
    println!(
        "probe press: root {}, mode {mode}, term {term}",
        root.display()
    );
    let (press, names) = (
        engine.clone().session().unwrap(),
        engine.clone().session().unwrap(),
    );
    let query = if walk {
        format!("in:\"{}\"", root.display())
    } else {
        String::new()
    };
    let (footprint, resident) = memory();
    println!(
        "probe memory before the press: {:.0} MiB footprint, {:.0} MiB resident",
        footprint as f64 / MIB,
        resident as f64 / MIB
    );
    let pressed = Instant::now();
    let files = Arc::new(AtomicU64::new(0));
    let (stop, stopped_rx) = mpsc::channel::<()>();
    let sampler = {
        let files = files.clone();
        std::thread::spawn(move || {
            let (mut peak, mut second) = (0, 0u64);
            while let Err(mpsc::RecvTimeoutError::Timeout) =
                stopped_rx.recv_timeout(Duration::from_secs(1))
            {
                let (footprint, resident) = memory();
                peak = peak.max(footprint);
                second += 1;
                if second.is_multiple_of(10) {
                    println!(
                        "probe memory: {second} s, {:.0} MiB footprint, {:.0} MiB resident, {} files read",
                        footprint as f64 / MIB,
                        resident as f64 / MIB,
                        files.load(Ordering::Relaxed)
                    );
                }
            }
            peak
        })
    };
    let g = (press.search_content(query, vec![term.clone()], true, BEST_MATCH)).unwrap();
    let (mut first, mut found, mut read, mut done) = (None, 0, 0, false);
    let mut done_at = None;
    let (mut asked, mut answered): (Option<(u64, Instant)>, Option<u128>) = (None, None);
    let mut stopped = false;
    let deadline = cap + Duration::from_secs(60);
    while (!done || asked.is_some_and(|_| answered.is_none())) && pressed.elapsed() < deadline {
        shared(&engine).reads.lock().unwrap().clear();
        if !done && asked.is_none() && pressed.elapsed() >= Duration::from_secs(1) {
            asked = Some((
                names.search(term.clone(), BEST_MATCH).unwrap(),
                Instant::now(),
            ));
        }
        if !stopped && pressed.elapsed() >= cap {
            press.stop_content().unwrap();
            stopped = true;
            println!("probe stopped at {} s", cap.as_secs());
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Event::Ready(r, count)) if r == g => {
                found = count;
                if count > 0 && first.is_none() {
                    first = Some(ms(pressed));
                }
            }
            Ok(Event::Ready(r, _)) if asked.is_some_and(|(n, _)| n == r) => {
                answered = asked.map(|(_, at)| ms(at));
            }
            Ok(Event::Progress(p, r, _, end)) if p == g => {
                (read, done) = (r, end);
                files.store(r, Ordering::Relaxed);
                if end && done_at.is_none() {
                    done_at = Some(ms(pressed));
                }
            }
            Ok(Event::Failed(f)) if f == g => panic!("the press failed"),
            Ok(Event::Fault(message)) => println!("probe fault: {message}"),
            _ => {}
        }
    }
    let skipped = (listener.skips.lock().unwrap().iter().rev())
        .find(|s| s.0 == g)
        .map_or(0, |s| s.1 + s.2);
    match first {
        Some(at) => println!("probe first rows: {at} ms after the press"),
        None => println!("probe first rows: none"),
    }
    println!(
        "probe done: {} ms, {read} files read, {skipped} skipped, {found} found",
        done_at.unwrap_or_else(|| ms(pressed))
    );
    match answered {
        Some(at) => println!("probe name search during the press: {at} ms"),
        None => println!("probe name search during the press: none, the press ended within 1 s"),
    }
    drop(stop);
    let press_peak = sampler.join().unwrap();
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    println!(
        "probe memory: peak {:.0} MiB resident, press peak {:.0} MiB footprint, readers {READERS}",
        usage.ru_maxrss as f64 / MIB,
        press_peak as f64 / MIB
    );

    drop((press, names, engine));
    let _ = fs::remove_dir_all(&scratch);
    assert!(done, "the press never sent its done progress");
}

fn cpu() -> Duration {
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        assert_eq!(libc::getrusage(libc::RUSAGE_SELF, &mut usage), 0);
        usage
    };
    let time = |t: libc::timeval| {
        Duration::new(
            u64::try_from(t.tv_sec).unwrap(),
            u32::try_from(t.tv_usec).unwrap() * 1000,
        )
    };
    time(usage.ru_utime) + time(usage.ru_stime)
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

#[test]
#[ignore = "runs the empty-field search on the folder WHEREVER_PROBE_ROOT names"]
fn list_all_cpu_probe() {
    let root = env::var("WHEREVER_PROBE_ROOT").expect("WHEREVER_PROBE_ROOT is unset");
    let refresh = env::var("WHEREVER_PROBE_REFRESH").is_ok_and(|v| v == "1");
    let root = fs::canonicalize(&root).expect("WHEREVER_PROBE_ROOT is not a folder");
    let runs: usize = env::var("WHEREVER_PROBE_RUNS").map_or(20, |s| s.parse().expect("runs"));
    let cap = Duration::from_secs(
        env::var("WHEREVER_PROBE_SECONDS").map_or(1800, |s| s.parse().expect("seconds")),
    );
    let scratch = env::temp_dir().join(format!("wherever-probe-{}", std::process::id()));
    let config = EngineConfig {
        root: root.to_str().unwrap().to_owned(),
        home: env::var("HOME").unwrap(),
        data_folder: scratch.join("data").to_str().unwrap().to_owned(),
        socket_folder: Some(scratch.join("data").to_str().unwrap().to_owned()),
        excluded: Vec::new(),
        indexed_volumes: Vec::new(),
        live_updates_paused: false,
    };

    let began = Instant::now();
    let (engine, _listener, rx) = start_with(config, None);
    let booted = loop {
        let Some(left) = (began + cap).checked_duration_since(Instant::now()) else {
            break false;
        };
        match rx.recv_timeout(left) {
            Ok(Event::State(s)) if matches!(s.phase, EnginePhase::Ready | EnginePhase::Live) => {
                println!(
                    "probe list-all: crawl {} entries in {} ms",
                    s.indexed,
                    ms(began)
                );
                break true;
            }
            Ok(Event::State(s)) => assert_ne!(s.phase, EnginePhase::Failed, "the index failed"),
            Ok(Event::Fault(message)) => println!("probe fault: {message}"),
            Ok(_) => {}
            Err(_) => break false,
        }
    };

    if booted {
        let by_name = EngineSort {
            column: EngineColumn::Name,
            ascending: true,
            folders_first: false,
        };
        let session = engine.clone().session().unwrap();
        let (mut walls, mut cpus) = (Vec::new(), Vec::new());
        for run in 1..=runs {
            let (asked, before) = (Instant::now(), cpu());
            let g = if refresh {
                session.refresh(String::new(), by_name).unwrap()
            } else {
                session.search(String::new(), by_name).unwrap()
            };
            let hits = loop {
                let Some(left) =
                    (asked + Duration::from_secs(60)).checked_duration_since(Instant::now())
                else {
                    break None;
                };
                match rx.recv_timeout(left) {
                    Ok(Event::Ready(r, count)) if r == g => break Some(count),
                    Ok(Event::Failed(f)) if f == g => break None,
                    Ok(_) => {}
                    Err(_) => break None,
                }
            };
            let (wall, used) = (asked.elapsed(), cpu() - before);
            let Some(hits) = hits else {
                println!(
                    "probe list-all: run {run}, no answer in 60 s or the search failed, stopping"
                );
                break;
            };
            let idle = cpu();
            std::thread::sleep(Duration::from_millis(1000));
            let after = cpu() - idle;
            println!(
                "probe list-all: run {run}, {hits} hits, {:.1} ms wall, {:.1} ms cpu, {:.1} ms cpu in the next 1000 ms",
                wall.as_secs_f64() * 1000.0,
                used.as_secs_f64() * 1000.0,
                after.as_secs_f64() * 1000.0
            );
            walls.push(wall.as_secs_f64() * 1000.0);
            cpus.push(used.as_secs_f64() * 1000.0);
        }
        println!(
            "probe list-all: rayon threads {}",
            rayon::current_num_threads()
        );
        if !walls.is_empty() {
            println!(
                "probe list-all: median {:.1} ms wall, {:.1} ms cpu",
                median(walls),
                median(cpus)
            );
        }
    } else {
        println!(
            "probe list-all: the crawl missed its {} s deadline",
            cap.as_secs()
        );
    }

    drop(engine);
    let _ = fs::remove_dir_all(&scratch);
}
