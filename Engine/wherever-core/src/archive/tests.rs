use super::*;
use crate::EngineKind;
use crate::crawl::tests::TempTree;
use crate::engine::tests::{Event, phases, start};
use ::zip::write::{FileOptions, FullFileOptions, SimpleFileOptions};
use ::zip::{AesMode, CompressionMethod, ZipWriter};
use std::fs::{self, File};
use std::io::{Cursor, Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

const NAME: EngineSort = EngineSort {
    column: crate::EngineColumn::Name,
    ascending: true,
    folders_first: true,
};

fn fixture(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, bytes) in entries {
        zip.start_file(
            *name,
            SimpleFileOptions::default()
                .compression_method(CompressionMethod::Stored)
                .unix_permissions(0o755),
        )
        .unwrap();
        zip.write_all(bytes).unwrap();
    }
    zip.finish().unwrap().into_inner()
}

struct Opened {
    session: Arc<ArchiveSession>,
    engine: Arc<Engine>,
    rx: Receiver<Event>,
    path: PathBuf,
    tree: TempTree,
}

impl Opened {
    fn new(label: &str, bytes: &[u8]) -> Self {
        Self::named(label, "archive.zip", bytes)
    }

    fn named(label: &str, name: &str, bytes: &[u8]) -> Self {
        let tree = TempTree::new(label);
        let path = PathBuf::from(tree.real()).join(name);
        fs::write(&path, bytes).unwrap();
        let (engine, _, rx) = start(&tree);
        phases(&rx);
        let session = engine
            .clone()
            .open_archive(
                path.to_string_lossy().into_owned(),
                format!("/shown/{name}"),
            )
            .unwrap();
        Self {
            session,
            engine,
            rx,
            path,
            tree,
        }
    }

    fn rows(&self, folder: &str) -> Vec<EngineHit> {
        let generation = self.session.browse(folder.into()).unwrap();
        self.wait(generation, Duration::from_secs(10));
        self.session.rows(generation, 0, u32::MAX).unwrap()
    }

    fn wait(&self, generation: u64, timeout: Duration) {
        let end = Instant::now() + timeout;
        loop {
            match self
                .rx
                .recv_timeout(end.saturating_duration_since(Instant::now()))
                .unwrap()
            {
                Event::Ready(g, _) if g == generation => return,
                Event::Failed(g) if g == generation => panic!("archive search failed"),
                _ => {}
            }
        }
    }

    fn output(&self) -> PathBuf {
        let path = PathBuf::from(self.tree.real()).join("output");
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn extract(&self, names: &[&str], read_only: bool) -> ArchiveJob {
        self.rows("");
        let id = self
            .session
            .extract(
                names.iter().map(|s| (*s).into()).collect(),
                self.output().to_string_lossy().into_owned(),
                read_only,
            )
            .unwrap();
        finished(&self.session, id)
    }
}

impl Opened {
    fn linked(&self, name: &str) -> PathBuf {
        let linked = PathBuf::from(self.tree.real()).join("linked");
        if !linked.exists() {
            std::os::unix::fs::symlink(self.tree.real(), &linked).unwrap();
        }
        linked.join(name)
    }

    fn open(&self, path: &std::path::Path) -> Arc<ArchiveSession> {
        self.engine
            .clone()
            .open_archive(
                path.to_string_lossy().into_owned(),
                "/shown/archive.zip".into(),
            )
            .unwrap()
    }
}

fn finished(session: &ArchiveSession, id: u64) -> ArchiveJob {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        let job = session.job(id).unwrap();
        if job.finished {
            return job;
        }
        assert!(Instant::now() < end, "job did not finish");
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn names(rows: Vec<EngineHit>) -> Vec<String> {
    rows.into_iter().map(|r| r.name).collect()
}

fn headers(bytes: &[u8], magic: &[u8; 4]) -> Vec<usize> {
    bytes
        .windows(4)
        .enumerate()
        .filter_map(|(i, b)| (b == magic).then_some(i))
        .collect()
}

#[test]
fn lists_three_levels_with_virtual_folders() {
    let o = Opened::new("archive-levels", &fixture(&[("one/two/file.txt", b"abc")]));
    assert_eq!(names(o.rows("")), ["one"]);
    assert_eq!(names(o.rows("one")), ["two"]);
    assert_eq!(names(o.rows("one/two")), ["file.txt"]);
}

#[test]
fn browse_lists_one_folder_sorted_folders_first() {
    let o = Opened::new(
        "archive-browse",
        &fixture(&[("z/child", b""), ("a.txt", b""), ("b.txt", b"")]),
    );
    o.rows("");
    let g = o.session.sort(NAME).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(g, 0, 10).unwrap()),
        ["z", "a.txt", "b.txt"]
    );
    let descending = EngineSort {
        ascending: false,
        ..NAME
    };
    let g = o.session.sort(descending).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(g, 0, 10).unwrap()),
        ["z", "b.txt", "a.txt"]
    );
    assert_eq!(o.session.refresh("anything".into(), NAME).unwrap(), g);
}

#[test]
fn totals_count_files_only() {
    let o = Opened::new(
        "archive-totals",
        &fixture(&[("one/two/a", b"abc"), ("one/b", b"12345")]),
    );
    o.rows("");
    let s = o.session.summary().unwrap();
    assert_eq!((s.items, s.bytes, s.skipped), (2, 8, 0));
}

#[test]
fn skips_and_counts_hostile_names() {
    let mut o = Opened::new("archive-hostile", &[]);
    let outside = PathBuf::from(o.tree.real()).join("escaped");
    let absolute = outside.to_string_lossy().into_owned();
    fs::write(
        &o.path,
        fixture(&[
            ("../a", b"bad"),
            (&absolute, b"bad"),
            ("a/../../b", b"bad"),
            ("ok", b"good"),
        ]),
    )
    .unwrap();
    o.session = o
        .engine
        .clone()
        .open_archive(
            o.path.to_string_lossy().into_owned(),
            "/shown/archive.zip".into(),
        )
        .unwrap();
    assert_eq!(names(o.rows("")), ["ok"]);
    assert_eq!(o.session.summary().unwrap().skipped, 3);
    assert_eq!(o.extract(&["ok"], false).done_items, 1);
    assert_eq!(fs::read(o.output().join("ok")).unwrap(), b"good");
    assert!(!outside.exists());
    assert!(!PathBuf::from(o.tree.real()).join("a").exists());
    assert!(!PathBuf::from(o.tree.real()).join("b").exists());
}

#[test]
fn link_entry_inside_lists_as_link_outside_reports_points_outside() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_symlink("inside", "target", SimpleFileOptions::default())
        .unwrap();
    w.add_symlink("outside", "../escaped", SimpleFileOptions::default())
        .unwrap();
    let o = Opened::new("archive-links", &w.finish().unwrap().into_inner());
    let rows = o.rows("");
    assert_eq!(rows.len(), 1);
    assert_eq!(
        (rows[0].name.as_str(), rows[0].kind),
        ("inside", EngineKind::Link)
    );
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::PointsOutside {
            name: "outside".into()
        })
    );
    assert_eq!(o.extract(&["inside"], false).done_items, 1);
    assert_eq!(
        fs::read_link(o.output().join("inside")).unwrap(),
        PathBuf::from("target")
    );
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for b in bytes {
        crc ^= u32::from(*b);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320 & (0u32.wrapping_sub(crc & 1)));
        }
    }
    !crc
}

#[test]
fn cp437_and_utf8_and_unicode_path_names() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.start_file("ü.txt", SimpleFileOptions::default()).unwrap();
    let mut extra = vec![1];
    extra.extend_from_slice(&crc32(b"alias.txt").to_le_bytes());
    extra.extend_from_slice("日本語.txt".as_bytes());
    let mut options = FullFileOptions::default();
    options.add_extra_field(0x7075, extra, false).unwrap();
    w.start_file("alias.txt", options).unwrap();
    w.start_file("x.txt", SimpleFileOptions::default()).unwrap();
    let mut bytes = w.finish().unwrap().into_inner();
    for magic in [b"PK\x03\x04", b"PK\x01\x02"] {
        for at in headers(&bytes, magic) {
            let name = at + if magic == b"PK\x03\x04" { 30 } else { 46 };
            if bytes[name..].starts_with(b"x.txt") {
                bytes[name] = 0x82;
            }
        }
    }
    let o = Opened::new("archive-encoding", &bytes);
    let got = names(o.rows(""));
    for name in ["ü.txt", "é.txt", "日本語.txt"] {
        assert!(got.contains(&name.into()), "{got:?}");
    }
}

#[test]
fn case_twin_names_both_list() {
    let o = Opened::new(
        "archive-case",
        &fixture(&[("a.txt", b"one"), ("A.txt", b"two")]),
    );
    let got = names(o.rows(""));
    assert_eq!(got.len(), 2);
    assert!(got.contains(&"a.txt".into()) && got.contains(&"A.txt".into()));
}

#[test]
fn duplicate_names_are_rejected_by_the_pinned_reader() {
    let mut bytes = fixture(&[("a.txt", b"one"), ("b.txt", b"two")]);
    for magic in [b"PK\x03\x04", b"PK\x01\x02"] {
        for at in headers(&bytes, magic) {
            let name = at + if magic == b"PK\x03\x04" { 30 } else { 46 };
            if bytes[name..].starts_with(b"b.txt") {
                bytes[name] = b'a';
            }
        }
    }
    let o = Opened::new("archive-duplicate", &bytes);
    o.rows("");
    assert_eq!(
        o.extract(&["a.txt"], false).problem,
        Some(ArchiveProblem::Damaged)
    );
    assert!(!o.output().join("a.txt").exists());
}

#[test]
fn zip64_placeholder_disk_number_opens() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.set_raw_zip64_extensible_data_sector(Vec::new().into_boxed_slice());
    w.start_file("large.txt", SimpleFileOptions::default().large_file(true))
        .unwrap();
    w.write_all(b"zip64").unwrap();
    let mut bytes = w.finish().unwrap().into_inner();
    assert_eq!(headers(&bytes, b"PK\x06\x06").len(), 1);
    assert_eq!(headers(&bytes, b"PK\x06\x07").len(), 1);
    let end = headers(&bytes, b"PK\x05\x06")[0];
    bytes[end + 4..end + 8].copy_from_slice(&[0xff; 4]);
    let o = Opened::new("archive-zip64", &bytes);
    assert_eq!(names(o.rows("")), ["large.txt"]);
    assert_eq!(o.extract(&["large.txt"], false).problem, None);
    assert_eq!(fs::read(o.output().join("large.txt")).unwrap(), b"zip64");
}

#[test]
fn inner_7z_bytes_stay_one_entry() {
    let bytes = b"7z\xbc\xaf\x27\x1c\x00\x04opaque";
    let o = Opened::new("archive-inner", &fixture(&[("inner.7z", bytes)]));
    assert_eq!(names(o.rows("")), ["inner.7z"]);
    assert_eq!(
        o.extract(&["inner.7z"], false).done_bytes,
        bytes.len() as u64
    );
    assert_eq!(fs::read(o.output().join("inner.7z")).unwrap(), bytes);
}

#[test]
fn empty_zip_reports_empty() {
    let o = Opened::new("archive-empty", &fixture(&[]));
    assert!(o.rows("").is_empty());
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::Empty)
    );
}

#[test]
fn truncated_central_directory_is_damaged_within_one_second() {
    let mut bytes = fixture(&[("hello.txt", b"hello")]);
    bytes.truncate(headers(&bytes, b"PK\x01\x02")[0] + 10);
    let o = Opened::new("archive-truncated", &bytes);
    let now = Instant::now();
    let g = o.session.search(String::new(), NAME).unwrap();
    o.wait(g, Duration::from_secs(1));
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::Damaged)
    );
    assert!(now.elapsed() < Duration::from_secs(1));
}

#[test]
fn extract_writes_bytes_mode_and_quarantine() {
    let mut bytes = fixture(&[("sub/file", b"exact bytes")]);
    let at = headers(&bytes, b"PK\x01\x02")[0];
    bytes[at + 38..at + 42].copy_from_slice(&(0o107755u32 << 16).to_le_bytes());
    let o = Opened::new("archive-quarantine", &bytes);
    o.session.close().unwrap();
    let value = b"0081;00000000;Wherever;test";
    write::quarantine(&File::open(&o.path).unwrap(), value).unwrap();
    let session = o
        .engine
        .clone()
        .open_archive(
            o.path.to_string_lossy().into_owned(),
            "/shown/archive.zip".into(),
        )
        .unwrap();
    let o = Opened { session, ..o };
    o.rows("");
    let job = o.extract(&["sub/file"], false);
    assert_eq!((job.done_bytes, job.done_items, job.problem), (11, 1, None));
    let path = o.output().join("sub/file");
    assert_eq!(fs::read(&path).unwrap(), b"exact bytes");
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o7777, 0o755);
    assert_eq!(
        write::read_quarantine(&File::open(path).unwrap()).unwrap(),
        value
    );
}

#[test]
fn extract_read_only_copy_is_0444() {
    let o = Opened::new("archive-readonly", &fixture(&[("file", b"readonly")]));
    o.rows("");
    assert_eq!(o.extract(&["file"], true).done_items, 1);
    assert_eq!(
        fs::metadata(o.output().join("file"))
            .unwrap()
            .permissions()
            .mode()
            & 0o7777,
        0o444
    );
}

#[test]
fn extract_stops_at_declared_size() {
    let mut bytes = fixture(&[("file", b"too many bytes")]);
    let central = headers(&bytes, b"PK\x01\x02")[0];
    bytes[central + 24..central + 28].copy_from_slice(&3u32.to_le_bytes());
    let o = Opened::new("archive-size", &bytes);
    o.rows("");
    let job = o.extract(&["file"], false);
    assert_eq!(job.problem, Some(ArchiveProblem::Damaged));
    assert!(job.done_bytes <= 3);
    assert!(!o.output().join("file").exists());
}

#[test]
fn extract_refuses_when_free_space_is_short() {
    let o = Opened::new("archive-space", &fixture(&[("file", b"12345")]));
    o.rows("");
    let id = o
        .session
        .extract_with_space(
            vec!["file".into()],
            o.output().to_string_lossy().into_owned(),
            false,
            |_| {
                Ok(write::Space {
                    bytes: write::RESERVE + 2,
                    volume: "test disk".into(),
                })
            },
        )
        .unwrap();
    assert_eq!(
        finished(&o.session, id).problem,
        Some(ArchiveProblem::NoSpace {
            needed: 3,
            volume: "test disk".into()
        })
    );
    assert!(!o.output().join("file").exists());
}

#[test]
fn changed_archive_refuses_extract() {
    let o = Opened::new("archive-changed", &fixture(&[("file", b"old")]));
    o.rows("");
    fs::write(&o.path, fixture(&[("file", b"new longer bytes")])).unwrap();
    assert_eq!(
        o.extract(&["file"], false).problem,
        Some(ArchiveProblem::Changed)
    );
    assert!(!o.output().join("file").exists());
    let replacement = o
        .engine
        .clone()
        .open_archive(
            o.path.to_string_lossy().into_owned(),
            "/shown/new.zip".into(),
        )
        .unwrap();
    let g = replacement.search(String::new(), NAME).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert_eq!(replacement.rows(g, 0, 1).unwrap()[0].size, 16);
}

#[test]
fn moved_archive_still_reads() {
    let o = Opened::new("archive-moved", &fixture(&[("file", b"original")]));
    o.rows("");
    fs::rename(&o.path, o.path.with_extension("moved")).unwrap();
    fs::write(&o.path, fixture(&[("file", b"replacement")])).unwrap();
    assert_eq!(o.extract(&["file"], false).problem, None);
    assert_eq!(fs::read(o.output().join("file")).unwrap(), b"original");
}

#[test]
fn cancel_stops_job_and_removes_partial_file() {
    let o = Opened::new(
        "archive-cancel",
        &fixture(&[("file", &vec![42; 256 * 1024])]),
    );
    o.rows("");
    let (reached, wait) = mpsc::channel();
    let (release, held) = mpsc::channel();
    o.session.state.lock().unwrap().write_hold = Some((reached, held));
    let id = o
        .session
        .extract(
            vec!["file".into()],
            o.output().to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    wait.recv_timeout(Duration::from_secs(10)).unwrap();
    o.session.cancel(id).unwrap();
    release.send(()).unwrap();
    let job = finished(&o.session, id);
    assert!(job.done_bytes > 0 && job.done_bytes < job.total_bytes);
    assert!(job.written.is_empty());
    assert!(!o.output().join("file").exists());
}

#[test]
fn archive_and_search_sessions_never_share_a_generation() {
    let o = Opened::new("archive-generations", &fixture(&[("file", b"")]));
    let archive = o.session.search(String::new(), NAME).unwrap();
    let search = o.engine.clone().session().unwrap();
    let normal = search.search(String::new(), NAME).unwrap();
    assert_ne!(archive, normal);
    assert_ne!(o.session.id().unwrap(), search.id().unwrap());
    o.wait(archive, Duration::from_secs(10));
    assert_eq!(o.session.rows(archive, 0, 1).unwrap()[0].name, "file");
}

#[test]
fn shown_as_prefixes_the_folder_column() {
    let o = Opened::new("archive-shown", &fixture(&[("sub/file", b"")]));
    assert_eq!(o.rows("sub")[0].folder, "/shown/archive.zip/sub");
}

#[test]
fn encrypted_entry_reports_password_needed() {
    let mut bytes = fixture(&[("file", b"not a password")]);
    for (magic, offset) in [(b"PK\x03\x04", 6), (b"PK\x01\x02", 8)] {
        for at in headers(&bytes, magic) {
            bytes[at + offset] |= 1;
        }
    }
    let o = Opened::new("archive-encrypted", &bytes);
    assert_eq!(names(o.rows("")), ["file"]);
    assert!(o.session.summary().unwrap().encrypted);
    assert_eq!(
        o.extract(&["file"], false).problem,
        Some(ArchiveProblem::PasswordNeeded)
    );
}

const METHOD_BYTES: &[u8] = b"Archive payload\0with repeated bytes: archive archive archive\n";

fn method_fixture(options: FileOptions<'_, '_, ()>) -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer.start_file("file", options).unwrap();
    writer.write_all(METHOD_BYTES).unwrap();
    writer.finish().unwrap().into_inner()
}

#[test]
fn aes128_and_aes256_entries_list_and_need_a_password() {
    let password = std::process::id().to_string();
    for mode in [AesMode::Aes128, AesMode::Aes256] {
        let bytes = method_fixture(FileOptions::default().with_aes_encryption(mode, &password));
        let o = Opened::new("archive-aes-list", &bytes);
        assert_eq!(names(o.rows("")), ["file"]);
        let summary = o.session.summary().unwrap();
        assert_eq!(summary.problem, None);
        assert!(summary.encrypted);
        assert_eq!(
            (summary.items, summary.bytes),
            (1, METHOD_BYTES.len() as u64)
        );
        let job = o.extract(&["file"], false);
        assert_eq!(job.problem, Some(ArchiveProblem::PasswordNeeded));
        assert_eq!(job.done_items, 0);
        assert!(!o.output().join("file").exists());
    }
}

#[test]
fn aes_entry_reads_with_the_right_password_through_the_reader() {
    let password = std::process::id().to_string();
    for mode in [AesMode::Aes128, AesMode::Aes256] {
        let bytes = method_fixture(FileOptions::default().with_aes_encryption(mode, &password));
        let o = Opened::new("archive-aes-read", &bytes);
        assert_eq!(names(o.rows("")), ["file"]);
        let source = o.session.state.lock().unwrap().source.clone().unwrap();
        let Format::Zip(zip) = &*source.format else {
            panic!("not a zip");
        };
        let mut reader = zip.clone();
        let mut file = reader
            .by_index_with_options(
                source.entries[0].index.unwrap(),
                ::zip::read::ZipReadOptions::new()
                    .enforce_header_consistency(true)
                    .password(Some(password.as_bytes())),
            )
            .unwrap();
        let mut actual = Vec::new();
        file.read_to_end(&mut actual).unwrap();
        assert_eq!(actual, METHOD_BYTES);
    }
}

#[test]
fn encrypted_flag_follows_each_zip_entry() {
    let password = std::process::id().to_string();
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, locked) in [
        ("top.txt", false),
        ("plain/a.txt", false),
        ("plain/deeper/b.txt", false),
        ("locked/c.txt", true),
        ("lockedness/d.txt", false),
        ("mixed/e.txt", false),
        ("mixed/inner/f.txt", true),
    ] {
        let options: FileOptions<'_, '_, ()> = if locked {
            FileOptions::default().with_aes_encryption(AesMode::Aes256, &password)
        } else {
            FileOptions::default()
        };
        writer.start_file(name, options).unwrap();
        writer.write_all(METHOD_BYTES).unwrap();
    }
    let o = Opened::new(
        "archive-encrypted-flag",
        &writer.finish().unwrap().into_inner(),
    );
    assert_eq!(
        names(o.rows("")),
        ["locked", "lockedness", "mixed", "plain", "top.txt"]
    );
    assert!(o.session.summary().unwrap().encrypted);
    let encrypted = |name: &str| o.session.encrypted(name.into()).unwrap();
    for plain in [
        "top.txt",
        "plain",
        "plain/a.txt",
        "plain/deeper",
        "plain/deeper/b.txt",
        "lockedness",
        "lockedness/d.txt",
        "mixed/e.txt",
        "missing.txt",
    ] {
        assert!(!encrypted(plain), "{plain} should be plain");
    }
    for locked in [
        "locked",
        "locked/c.txt",
        "mixed",
        "mixed/inner",
        "mixed/inner/f.txt",
    ] {
        assert!(encrypted(locked), "{locked} should be encrypted");
    }
    assert!(o.session.encrypted("../top.txt".into()).is_err());
    assert_eq!(
        o.extract(&["plain", "plain/a.txt", "top.txt"], false)
            .problem,
        None
    );
    assert_eq!(
        o.extract(&["mixed/inner/f.txt"], false).problem,
        Some(ArchiveProblem::PasswordNeeded)
    );
    o.session.close().unwrap();
    assert!(matches!(
        o.session.encrypted("top.txt".into()),
        Err(EngineError::Stopped)
    ));
}

#[test]
fn each_new_method_reads() {
    for method in [
        CompressionMethod::Stored,
        CompressionMethod::Deflated,
        CompressionMethod::Bzip2,
        CompressionMethod::Xz,
        CompressionMethod::Ppmd,
    ] {
        let bytes = method_fixture(SimpleFileOptions::default().compression_method(method));
        let o = Opened::new("archive-method", &bytes);
        assert_eq!(names(o.rows("")), ["file"], "{method:?}");
        assert_eq!(o.session.summary().unwrap().problem, None, "{method:?}");
        let job = o.extract(&["file"], false);
        assert_eq!(job.problem, None, "{method:?}");
        assert_eq!(job.done_items, 1, "{method:?}");
        assert_eq!(
            fs::read(o.output().join("file")).unwrap(),
            METHOD_BYTES,
            "{method:?}"
        );
    }
}

#[test]
fn zstd_entry_is_unsupported() {
    let mut bytes =
        method_fixture(SimpleFileOptions::default().compression_method(CompressionMethod::Bzip2));
    let o = Opened::new("archive-bzip2-before-zstd", &bytes);
    assert_eq!(names(o.rows("")), ["file"]);
    let job = o.extract(&["file"], false);
    assert_eq!((job.done_items, job.problem), (1, None));
    assert_eq!(fs::read(o.output().join("file")).unwrap(), METHOD_BYTES);

    for (magic, offset) in [(b"PK\x03\x04", 8), (b"PK\x01\x02", 10)] {
        let positions = headers(&bytes, magic);
        assert_eq!(positions.len(), 1);
        let at = positions[0] + offset;
        bytes[at..at + 2].copy_from_slice(&93u16.to_le_bytes());
    }
    let o = Opened::new("archive-zstd", &bytes);
    assert_eq!(names(o.rows("")), ["file"]);
    assert_eq!(o.session.summary().unwrap().problem, None);
    let job = o.extract(&["file"], false);
    assert_eq!(job.problem, Some(ArchiveProblem::Unsupported));
    assert_eq!(job.done_items, 0);
    assert!(!o.output().join("file").exists());
}

#[test]
fn close_then_rows_is_stopped() {
    let o = Opened::new("archive-close", &fixture(&[("file", b"")]));
    o.rows("");
    let g = o.session.refresh(String::new(), NAME).unwrap();
    o.session.close().unwrap();
    assert!(matches!(o.session.rows(g, 0, 1), Err(EngineError::Stopped)));
    assert!(matches!(
        o.session.search(String::new(), NAME),
        Err(EngineError::Stopped)
    ));
}

#[test]
fn path_with_a_symlink_is_gone() {
    let o = Opened::new("archive-source-link", &fixture(&[("file", b"")]));
    let link = o.path.with_extension("link");
    std::os::unix::fs::symlink(&o.path, &link).unwrap();
    let session = o
        .engine
        .clone()
        .open_archive(
            link.to_string_lossy().into_owned(),
            "/shown/link.zip".into(),
        )
        .unwrap();
    let g = session.search(String::new(), NAME).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert!(matches!(
        session.summary().unwrap().problem,
        Some(ArchiveProblem::Gone { .. })
    ));
}

#[test]
fn extraction_never_follows_destination_links_or_removes_existing_files() {
    let o = Opened::new(
        "archive-destination",
        &fixture(&[("sub/file", b"new"), ("file", b"new")]),
    );
    o.rows("");
    let outside = PathBuf::from(o.tree.real()).join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("file"), b"keep").unwrap();
    std::os::unix::fs::symlink(&outside, o.output().join("sub")).unwrap();
    let id = o
        .session
        .extract(
            vec!["sub/file".into()],
            o.output().to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while o.session.job(id).is_ok_and(|j| !j.finished) {
        assert!(Instant::now() < end);
        std::thread::yield_now();
    }
    assert!(o.session.job(id).is_err());
    assert_eq!(fs::read(outside.join("file")).unwrap(), b"keep");
    fs::write(o.output().join("file"), b"existing").unwrap();
    let id = o
        .session
        .extract(
            vec!["file".into()],
            o.output().to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    while o.session.job(id).is_ok_and(|j| !j.finished) {
        assert!(Instant::now() < end);
        std::thread::yield_now();
    }
    assert!(o.session.job(id).is_err());
    assert_eq!(fs::read(o.output().join("file")).unwrap(), b"existing");
}

#[test]
fn a_damaged_entry_never_removes_an_existing_destination() {
    let mut bytes = fixture(&[("file", b"payload")]);
    let at = headers(&bytes, b"PK\x01\x02")[0];
    bytes[at + 10..at + 12].copy_from_slice(&99u16.to_le_bytes());
    let o = Opened::new("archive-damaged-existing", &bytes);
    o.rows("");
    fs::write(o.output().join("file"), b"keep").unwrap();
    assert!(o.extract(&["file"], false).problem.is_some());
    assert_eq!(fs::read(o.output().join("file")).unwrap(), b"keep");
}

#[test]
fn archive_link_names_cannot_mask_existing_destination_links() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_symlink("alias", "safe", SimpleFileOptions::default())
        .unwrap();
    w.add_symlink("pick", "alias/file", SimpleFileOptions::default())
        .unwrap();
    let o = Opened::new("archive-link-mask", &w.finish().unwrap().into_inner());
    o.rows("");
    std::os::unix::fs::symlink(o.tree.real(), o.output().join("alias")).unwrap();
    assert_eq!(
        o.extract(&["pick"], false).problem,
        Some(ArchiveProblem::PointsOutside {
            name: "pick".into()
        })
    );
    assert!(fs::symlink_metadata(o.output().join("pick")).is_err());
}

#[test]
fn safe_link_chains_stay_inside_and_cycles_are_skipped() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, to) in [
        ("one", "target"),
        ("two", "one"),
        ("loop1", "loop2"),
        ("loop2", "loop1"),
    ] {
        w.add_symlink(name, to, SimpleFileOptions::default())
            .unwrap();
    }
    let o = Opened::new("archive-link-chains", &w.finish().unwrap().into_inner());
    assert_eq!(names(o.rows("")), ["one", "two"]);
    assert_eq!(o.session.summary().unwrap().skipped, 2);
    assert_eq!(o.extract(&["one", "two"], false).done_items, 2);
    assert_eq!(
        fs::read_link(o.output().join("two")).unwrap(),
        PathBuf::from("one")
    );
}

#[test]
fn mac_metadata_and_dot_entries_are_marked_hidden() {
    let o = Opened::new(
        "archive-hidden",
        &fixture(&[
            ("__MACOSX/._file", b""),
            ("._root", b""),
            (".secret/file", b""),
        ]),
    );
    o.rows("");
    let source = o.session.state.lock().unwrap().source.clone().unwrap();
    assert!(source.entries.iter().all(|e| e.attrs.hidden));
}

#[test]
fn repeated_safe_link_traversal_is_not_a_cycle() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_symlink("a", ".", SimpleFileOptions::default())
        .unwrap();
    w.add_symlink("b", "a/a/file", SimpleFileOptions::default())
        .unwrap();
    let o = Opened::new("archive-repeat-link", &w.finish().unwrap().into_inner());
    assert_eq!(names(o.rows("")), ["a", "b"]);
    assert_eq!(o.session.summary().unwrap().skipped, 0);
    assert_eq!(o.extract(&["a", "b"], false).done_items, 2);
}

#[test]
fn selected_folders_are_stamped_after_children_in_either_order() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_directory("dir", SimpleFileOptions::default().unix_permissions(0o555))
        .unwrap();
    w.start_file("dir/file", SimpleFileOptions::default())
        .unwrap();
    w.write_all(b"child").unwrap();
    let o = Opened::new("archive-folder-order", &w.finish().unwrap().into_inner());
    o.rows("");
    for (i, entries) in [["dir/file", "dir"], ["dir", "dir/file"]]
        .into_iter()
        .enumerate()
    {
        let folder = o.output().join(i.to_string());
        fs::create_dir(&folder).unwrap();
        let id = o
            .session
            .extract(
                entries.map(str::to_owned).to_vec(),
                folder.to_string_lossy().into_owned(),
                false,
            )
            .unwrap();
        let job = finished(&o.session, id);
        assert_eq!((job.done_items, job.problem), (2, None));
        assert_eq!(fs::read(folder.join("dir/file")).unwrap(), b"child");
        assert_eq!(
            fs::metadata(folder.join("dir")).unwrap().mode() & 0o777,
            0o555
        );
        fs::set_permissions(folder.join("dir"), fs::Permissions::from_mode(0o755)).unwrap();
    }
}

#[test]
fn closing_interrupts_archive_reads_without_sharing_offsets() {
    use std::io::{Read, Seek, SeekFrom};
    let o = Opened::new("archive-read-offset", &fixture(&[("file", b"payload")]));
    let closed = Arc::new(AtomicBool::new(false));
    let mut a = detect::Reader::open(&o.path, closed.clone()).unwrap();
    let mut b = a.clone();
    a.seek(SeekFrom::Start(4)).unwrap();
    let mut bytes = [0; 4];
    b.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"PK\x03\x04");
    closed.store(true, Ordering::Relaxed);
    assert!(a.read(&mut bytes).is_err());
}

#[test]
fn a_read_only_folder_can_receive_its_child_in_a_later_job() {
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_directory("dir", SimpleFileOptions::default().unix_permissions(0o555))
        .unwrap();
    w.start_file("dir/file", SimpleFileOptions::default())
        .unwrap();
    w.write_all(b"first").unwrap();
    let o = Opened::new("archive-later-child", &w.finish().unwrap().into_inner());
    let src = Src::new("archive-later-child");
    let later = src.put("later.txt", b"later");
    let reopened = src.put("another.txt", b"reopened");
    o.rows("");
    assert_eq!(o.extract(&["dir"], false).done_items, 2);
    assert_eq!(fs::read(o.output().join("dir/file")).unwrap(), b"first");
    assert_eq!(
        fs::metadata(o.output().join("dir")).unwrap().mode() & 0o777,
        0o555
    );
    o.changed(vec![add(&later, "dir", "later.txt")]);
    assert_eq!(o.extract(&["dir/later.txt"], false).done_items, 1);
    assert_eq!(
        fs::read(o.output().join("dir/later.txt")).unwrap(),
        b"later"
    );
    assert_eq!(
        fs::metadata(o.output().join("dir")).unwrap().mode() & 0o777,
        0o555
    );
    o.session.close().unwrap();
    let session = o
        .engine
        .clone()
        .open_archive(
            o.path.to_string_lossy().into_owned(),
            "/shown/archive.zip".into(),
        )
        .unwrap();
    let o = Opened { session, ..o };
    o.changed(vec![add(&reopened, "dir", "another.txt")]);
    assert_eq!(o.extract(&["dir/another.txt"], false).done_items, 1);
    assert_eq!(
        fs::read(o.output().join("dir/another.txt")).unwrap(),
        b"reopened"
    );
    assert_eq!(
        fs::metadata(o.output().join("dir")).unwrap().mode() & 0o777,
        0o555
    );
    fs::set_permissions(o.output().join("dir"), fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn extraction_does_not_hold_one_descriptor_per_folder() {
    use std::os::fd::AsRawFd;
    fn bounded_space(file: &File) -> std::io::Result<write::Space> {
        let mut raw = [0u8; libc::PATH_MAX as usize];
        assert_eq!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, raw.as_mut_ptr()) },
            0
        );
        let path = std::ffi::CStr::from_bytes_until_nul(&raw)
            .unwrap()
            .to_str()
            .unwrap();
        let root = path.split("/output").next().unwrap().to_owned() + "/output/";
        let mut count = 0;
        for entry in fs::read_dir("/dev/fd")? {
            let Some(fd) = entry
                .ok()
                .and_then(|e| e.file_name().to_str()?.parse::<i32>().ok())
            else {
                continue;
            };
            raw.fill(0);
            if unsafe { libc::fcntl(fd, libc::F_GETPATH, raw.as_mut_ptr()) } == 0
                && std::ffi::CStr::from_bytes_until_nul(&raw)
                    .unwrap()
                    .to_bytes()
                    .starts_with(root.as_bytes())
            {
                count += 1;
            }
        }
        if count > 8 {
            return Err(std::io::Error::other(
                "too many retained output descriptors",
            ));
        }
        Ok(write::Space {
            bytes: u64::MAX,
            volume: "test disk".into(),
        })
    }
    let paths: Vec<_> = (0..64).map(|n| format!("dir{n}/file")).collect();
    let entries: Vec<_> = paths.iter().map(|p| (p.as_str(), &b"data"[..])).collect();
    let o = Opened::new("archive-descriptor-count", &fixture(&entries));
    o.rows("");
    let id = o
        .session
        .extract_with_space(
            paths.clone(),
            o.output().to_string_lossy().into_owned(),
            false,
            bounded_space,
        )
        .unwrap();
    assert_eq!(finished(&o.session, id).done_items, 64);
    for path in paths {
        assert_eq!(fs::read(o.output().join(path)).unwrap(), b"data");
    }
}

#[test]
fn a_linked_parent_folder_lists_browses_and_extracts() {
    let o = Opened::new(
        "archive-linked-parent",
        &fixture(&[("a/one", b"1"), ("two", b"22")]),
    );
    let session = o.open(&o.linked("archive.zip"));
    let root = session.search(String::new(), NAME).unwrap();
    o.wait(root, Duration::from_secs(10));
    assert_eq!(
        names(session.rows(root, 0, u32::MAX).unwrap()),
        ["a", "two"]
    );
    let browsed = session.browse("a".into()).unwrap();
    o.wait(browsed, Duration::from_secs(10));
    assert_eq!(names(session.rows(browsed, 0, u32::MAX).unwrap()), ["one"]);
    let summary = session.summary().unwrap();
    assert_eq!(summary.problem, None);
    assert_eq!((summary.items, summary.bytes), (2, 3));
    let output = o.linked("output");
    fs::create_dir_all(&output).unwrap();
    let id = session
        .extract(
            vec!["two".into()],
            output.to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    let job = finished(&session, id);
    assert_eq!(job.problem, None);
    assert_eq!(fs::read(o.output().join("two")).unwrap(), b"22");
}

#[test]
fn an_empty_archive_behind_a_linked_folder_reports_empty() {
    let o = Opened::new("archive-linked-empty", &fixture(&[]));
    let session = o.open(&o.linked("archive.zip"));
    let g = session.browse(String::new()).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert!(session.rows(g, 0, u32::MAX).unwrap().is_empty());
    assert_eq!(
        session.summary().unwrap().problem,
        Some(ArchiveProblem::Empty)
    );
}

#[test]
fn a_missing_archive_behind_a_linked_folder_is_gone_by_its_given_name() {
    let o = Opened::new("archive-linked-missing", &fixture(&[("file", b"")]));
    let path = o.linked("missing.zip");
    let session = o.open(&path);
    let g = session.browse(String::new()).unwrap();
    o.wait(g, Duration::from_secs(10));
    assert_eq!(
        session.summary().unwrap().problem,
        Some(ArchiveProblem::Gone {
            name: path.to_string_lossy().into_owned()
        })
    );
}

struct Src {
    tree: TempTree,
}

impl Src {
    fn new(label: &str) -> Self {
        let tree = TempTree::new(&format!("{label}-src"));
        fs::create_dir_all(PathBuf::from(tree.real()).join("src")).unwrap();
        Self { tree }
    }

    fn dir(&self) -> PathBuf {
        PathBuf::from(self.tree.real()).join("src")
    }

    fn put(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.dir().join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        path
    }

    fn tar<S: AsRef<std::ffi::OsStr>>(&self, out: &str, args: &[S]) -> Vec<u8> {
        let path = PathBuf::from(self.tree.real()).join(out);
        let status = std::process::Command::new("/usr/bin/tar")
            .arg("-f")
            .arg(&path)
            .args(args)
            .current_dir(self.dir())
            .status()
            .unwrap();
        assert!(status.success(), "tar into {out}");
        fs::read(&path).unwrap()
    }
}

fn gzipped(bytes: &[u8]) -> Vec<u8> {
    let mut child = std::process::Command::new("/usr/bin/gzip")
        .arg("-c")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let bytes = bytes.to_vec();
    let feeder = std::thread::spawn(move || input.write_all(&bytes).unwrap());
    let out = child.wait_with_output().unwrap();
    feeder.join().unwrap();
    assert!(out.status.success());
    out.stdout
}

fn noise(n: usize) -> Vec<u8> {
    let mut x = 0x2545_f491_4f6c_dd1du64;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

impl Opened {
    fn read(&self, name: &str) -> Vec<u8> {
        let job = self.extract(&[name], false);
        assert_eq!(job.problem, None, "reading {name}");
        let path = self.output().join(name);
        let bytes = fs::read(&path).unwrap();
        fs::remove_file(path).unwrap();
        bytes
    }

    fn refused(&self, name: &str) -> Option<ArchiveProblem> {
        let job = self.extract(&[name], false);
        assert!(!self.output().join(name).exists(), "{name} was written");
        job.problem
    }

    fn summary(&self) -> ArchiveSummary {
        self.rows("");
        self.session.summary().unwrap()
    }

    fn source(&self) -> Arc<Source> {
        self.rows("");
        self.session.state.lock().unwrap().source.clone().unwrap()
    }

    fn hold(&self) -> (Receiver<()>, mpsc::Sender<()>) {
        let (reached, wait) = mpsc::channel();
        let (release, held) = mpsc::channel();
        self.session.state.lock().unwrap().write_hold = Some((reached, held));
        (wait, release)
    }

    fn start(&self, name: &str, folder: &str) -> (u64, PathBuf) {
        let folder = PathBuf::from(self.tree.real()).join(folder);
        fs::create_dir_all(&folder).unwrap();
        let id = self
            .session
            .extract(
                vec![name.into()],
                folder.to_string_lossy().into_owned(),
                false,
            )
            .unwrap();
        (id, folder)
    }
}

fn row<'a>(rows: &'a [EngineHit], name: &str) -> &'a EngineHit {
    rows.iter().find(|r| r.name == name).unwrap_or_else(|| {
        panic!(
            "{name} missing from {:?}",
            rows.iter().map(|r| &r.name).collect::<Vec<_>>()
        )
    })
}

fn vint(mut n: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            return out;
        }
        out.push(b | 0x80);
    }
}

fn block5(kind: u64, flags: u64, body: &[u8], extra: &[u8], data: Option<&[u8]>) -> Vec<u8> {
    let mut fields = vint(kind);
    fields.extend(vint(
        flags | u64::from(!extra.is_empty()) | if data.is_some() { 2 } else { 0 },
    ));
    if !extra.is_empty() {
        fields.extend(vint(extra.len() as u64));
    }
    if let Some(data) = data {
        fields.extend(vint(data.len() as u64));
    }
    fields.extend_from_slice(body);
    fields.extend_from_slice(extra);
    let header = [vint(fields.len() as u64), fields].concat();
    [
        crc32(&header).to_le_bytes().to_vec(),
        header,
        data.unwrap_or_default().to_vec(),
    ]
    .concat()
}

const RAR_TIME: u32 = 1_700_000_000;

fn packed5(
    name: &[u8],
    data: &[u8],
    size: u64,
    mode: u64,
    compression: u64,
    extra: &[u8],
) -> Vec<u8> {
    let folder = mode & 0o170000 == 0o040000;
    let body = [
        vint(u64::from(folder) | 2 | 4),
        vint(size),
        vint(mode),
        RAR_TIME.to_le_bytes().to_vec(),
        crc32(data).to_le_bytes().to_vec(),
        vint(compression),
        vint(1),
        vint(name.len() as u64),
        name.to_vec(),
    ]
    .concat();
    block5(2, 0, &body, extra, Some(data))
}

fn file5(name: &[u8], data: &[u8]) -> Vec<u8> {
    packed5(name, data, data.len() as u64, 0o100644, 0, &[])
}

fn record5(kind: u64, payload: &[u8]) -> Vec<u8> {
    let inner = [vint(kind), payload.to_vec()].concat();
    [vint(inner.len() as u64), inner].concat()
}

fn redirect5(kind: u64, target: &[u8]) -> Vec<u8> {
    record5(
        5,
        &[
            vint(kind),
            vint(0),
            vint(target.len() as u64),
            target.to_vec(),
        ]
        .concat(),
    )
}

fn rar5(members: &[Vec<u8>]) -> Vec<u8> {
    [
        b"Rar!\x1a\x07\x01\x00".to_vec(),
        block5(1, 0, &vint(0), &[], None),
        members.concat(),
        block5(5, 0, &vint(0), &[], None),
    ]
    .concat()
}

fn block4(kind: u8, flags: u16, body: &[u8]) -> Vec<u8> {
    let header = [
        vec![kind],
        flags.to_le_bytes().to_vec(),
        ((7 + body.len()) as u16).to_le_bytes().to_vec(),
        body.to_vec(),
    ]
    .concat();
    [
        ((crc32(&header) & 0xffff) as u16).to_le_bytes().to_vec(),
        header,
    ]
    .concat()
}

fn dos4(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> u32 {
    (year - 1980) << 25 | month << 21 | day << 16 | hour << 11 | minute << 5 | (second / 2)
}

fn file4(name: &[u8], data: &[u8], flags: u16, mode: u32, ext: &[u8]) -> Vec<u8> {
    let flags = flags | 0x8000 | if ext.is_empty() { 0 } else { 0x1000 };
    let body = [
        (data.len() as u32).to_le_bytes().to_vec(),
        (data.len() as u32).to_le_bytes().to_vec(),
        vec![3],
        crc32(data).to_le_bytes().to_vec(),
        dos4(2021, 3, 4, 5, 6, 8).to_le_bytes().to_vec(),
        vec![29, 0x30],
        (name.len() as u16).to_le_bytes().to_vec(),
        mode.to_le_bytes().to_vec(),
        name.to_vec(),
        ext.to_vec(),
    ]
    .concat();
    [block4(0x74, flags, &body), data.to_vec()].concat()
}

fn rar4(members: &[Vec<u8>], flags: u16) -> Vec<u8> {
    [
        b"Rar!\x1a\x07\x00".to_vec(),
        block4(0x73, flags, &[0; 6]),
        members.concat(),
        block4(0x7b, 0x4000, &[]),
    ]
    .concat()
}

fn local(seconds: i64) -> (i32, i32, i32, i32, i32, i32) {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&seconds, &mut tm) };
    (
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
    )
}

fn reaped(path: &std::path::Path) -> bool {
    let pids: Vec<u32> = bsdtar::SPAWNED
        .lock()
        .unwrap()
        .iter()
        .filter(|(p, _)| p == path)
        .map(|&(_, pid)| pid)
        .collect();
    !pids.is_empty()
        && pids.iter().all(|&pid| {
            let alive = unsafe { libc::kill(pid as i32, 0) };
            alive != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        })
}

const MARCH: i64 = 1_614_834_367;
const NEW_YEAR: i64 = 1_262_304_001;
const PLAIN: [&str; 3] = ["--no-mac-metadata", "--no-xattrs", "--format=ustar"];

fn dated(path: &std::path::Path, seconds: i64) {
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(seconds as u64))
        .unwrap();
}

fn sorted(rows: Vec<EngineHit>) -> Vec<String> {
    let mut names = names(rows);
    names.sort();
    names
}

#[test]
fn lists_tar_family_with_modes_links_and_times() {
    let src = Src::new("tar-family");
    let a = src.put("dir/a.txt", b"alpha");
    fs::set_permissions(&a, fs::Permissions::from_mode(0o640)).unwrap();
    dated(&a, MARCH);
    dated(&src.put("b.txt", b"beta"), NEW_YEAR);
    std::os::unix::fs::symlink("b.txt", src.dir().join("lnk")).unwrap();
    fs::set_permissions(src.dir().join("dir"), fs::Permissions::from_mode(0o750)).unwrap();
    for (name, mode) in [
        ("a.tar", "-c"),
        ("a.tar.gz", "-cz"),
        ("a.tar.bz2", "-cj"),
        ("a.tar.xz", "-cJ"),
    ] {
        let bytes = src.tar(name, &[mode, "--no-mac-metadata", "--no-xattrs", "."]);
        let o = Opened::named(&format!("tar-family-{name}"), name, &bytes);
        let top = o.rows("");
        assert_eq!(names(top.clone()), ["dir", "b.txt", "lnk"], "{name}");
        let b = row(&top, "b.txt");
        assert_eq!(
            (b.size, b.modified, b.kind),
            (4, NEW_YEAR, EngineKind::File)
        );
        assert_eq!(row(&top, "lnk").kind, EngineKind::Link);
        let a = o.rows("dir");
        assert_eq!(
            (row(&a, "a.txt").size, row(&a, "a.txt").modified),
            (5, MARCH),
            "{name}"
        );
        assert_eq!(local(MARCH).0, 2021);
        let s = o.summary();
        assert_eq!(
            (s.format.as_str(), s.items, s.bytes, s.skipped),
            ("tar", 2, 9, 0)
        );
        let job = o.extract(&["dir/a.txt", "dir", "lnk"], false);
        assert_eq!(job.problem, None, "{name}");
        let out = o.output();
        assert_eq!(fs::read(out.join("dir/a.txt")).unwrap(), b"alpha");
        assert_eq!(
            fs::metadata(out.join("dir/a.txt")).unwrap().mode() & 0o7777,
            0o640
        );
        assert_eq!(
            fs::metadata(out.join("dir")).unwrap().mode() & 0o7777,
            0o750
        );
        assert_eq!(fs::metadata(out.join("dir/a.txt")).unwrap().mtime(), MARCH);
        assert_eq!(
            fs::read_link(out.join("lnk")).unwrap(),
            PathBuf::from("b.txt")
        );
    }
}

#[test]
fn newline_and_utf8_byte_names_round_trip() {
    use std::os::unix::ffi::OsStrExt;
    let src = Src::new("tar-names");
    src.put("nl\nname.txt", b"newline");
    src.put("caf\u{e9}.txt", b"nfc");
    src.put("plain.txt", b"raw byte");
    let rename = std::ffi::OsStr::from_bytes(b"|^plain|pl\xffain|").to_owned();
    let args: Vec<std::ffi::OsString> = ["-c", "--no-mac-metadata", "--no-xattrs", "-s"]
        .iter()
        .map(Into::into)
        .chain([rename])
        .chain(
            ["nl\nname.txt", "caf\u{e9}.txt", "plain.txt"]
                .iter()
                .map(Into::into),
        )
        .collect();
    let bytes = src.tar("n.tar", &args);
    assert!(bytes.windows(4).any(|w| w == b"pl\xffa"));
    for (name, bytes) in [("n.tar", bytes.clone()), ("n.tar.gz", gzipped(&bytes))] {
        let o = Opened::named(&format!("tar-names-{name}"), name, &bytes);
        assert_eq!(
            sorted(o.rows("")),
            ["caf\u{e9}.txt", "nl\nname.txt", "pl\u{fffd}ain.txt"]
        );
        assert_eq!(o.read("nl\nname.txt"), b"newline");
        assert_eq!(o.read("caf\u{e9}.txt"), b"nfc");
        assert_eq!(o.read("pl\u{fffd}ain.txt"), b"raw byte");
    }
}

#[test]
fn hard_link_previews_its_target() {
    let src = Src::new("tar-hard");
    src.put("dir/orig.txt", b"hello hard link");
    fs::hard_link(src.dir().join("dir/orig.txt"), src.dir().join("hard.txt")).unwrap();
    let bytes = src.tar("h.tar", &["-c", "--no-mac-metadata", "--no-xattrs", "."]);
    for (name, bytes) in [("h.tar", bytes.clone()), ("h.tar.gz", gzipped(&bytes))] {
        let o = Opened::named(&format!("tar-hard-{name}"), name, &bytes);
        let source = o.source();
        let Format::Tar(members) = &*source.format else {
            panic!("not a tar");
        };
        assert_eq!(
            members
                .iter()
                .filter(|m| m.kind == tar::Kind::HardLink)
                .count(),
            1
        );
        assert_eq!(row(&o.rows(""), "hard.txt").size, 15);
        assert_eq!(row(&o.rows("dir"), "orig.txt").size, 15);
        assert_eq!(o.read("hard.txt"), b"hello hard link");
        assert_eq!(o.read("dir/orig.txt"), b"hello hard link");
    }
}

#[test]
fn tar_dotdot_and_absolute_names_skipped_and_counted() {
    let src = Src::new("tar-hostile");
    let outside = format!("{}/abs-out.txt", src.tree.real());
    let hostile = [
        "../up.txt",
        "a/../b.txt",
        "./../c.txt",
        "a/b/../c.txt",
        "x/..",
        "/../x.txt",
        outside.as_str(),
    ];
    src.put("ok.txt", b"good");
    let mut args: Vec<String> = ["-c", "-P", "--no-mac-metadata", "--no-xattrs"]
        .map(String::from)
        .to_vec();
    for (i, name) in hostile.iter().enumerate() {
        src.put(&format!("h{i}"), b"bad");
        args.push("-s".into());
        args.push(format!("|^h{i}$|{name}|"));
    }
    args.push("ok.txt".into());
    args.extend((0..hostile.len()).map(|i| format!("h{i}")));
    let plain = src.tar("t.tar", &args);
    for (name, bytes) in [("t.tar", plain.clone()), ("t.tar.gz", gzipped(&plain))] {
        let o = Opened::named(&format!("tar-hostile-{name}"), name, &bytes);
        assert_eq!(o.read("ok.txt"), b"good");
        let source = o.source();
        let Format::Tar(members) = &*source.format else {
            panic!("not a tar");
        };
        let stored: Vec<_> = members.iter().map(|m| m.name.clone()).collect();
        for name in hostile {
            assert!(
                stored.contains(&name.as_bytes().to_vec()),
                "{name} not stored"
            );
        }
        assert_eq!(names(o.rows("")), ["ok.txt"]);
        assert_eq!(o.summary().skipped, hostile.len() as u64);
        assert_eq!(
            o.refused("../up.txt"),
            Some(ArchiveProblem::PointsOutside {
                name: "../up.txt".into()
            })
        );
        assert!(!std::path::Path::new(&outside).exists());
    }
}

#[test]
fn tar_member_stored_twice_lists_and_reads_the_last_copy() {
    let src = Src::new("tar-twice");
    src.put("dup.txt", b"first");
    src.put("other.txt", b"x");
    src.tar(
        "d.tar",
        &[
            "-c",
            "--no-mac-metadata",
            "--no-xattrs",
            "dup.txt",
            "other.txt",
        ],
    );
    src.put("dup.txt", b"second!");
    let bytes = src.tar(
        "d.tar",
        &["-r", "--no-mac-metadata", "--no-xattrs", "dup.txt"],
    );
    let o = Opened::named("tar-twice", "d.tar", &bytes);
    let rows = o.rows("");
    assert_eq!(sorted(rows.clone()), ["dup.txt", "other.txt"]);
    assert_eq!(row(&rows, "dup.txt").size, 7);
    assert_eq!(o.read("dup.txt"), b"second!");
    assert_eq!(o.summary().items, 2);
}

#[test]
fn apple_double_companion_is_no_row_and_a_trailing_dot_underscore_file_lists() {
    let src = Src::new("tar-appledouble");
    let tagged = src.put("tagged.txt", b"data");
    let path = std::ffi::CString::new(tagged.to_str().unwrap()).unwrap();
    assert_eq!(
        unsafe {
            libc::setxattr(
                path.as_ptr(),
                c"com.example.probe".as_ptr(),
                b"hello".as_ptr().cast(),
                5,
                0,
                0,
            )
        },
        0
    );
    src.put("plain.txt", b"raw");
    let bytes = src.tar("ad.tar", &["-c", "--format=pax", "tagged.txt", "plain.txt"]);
    assert!(bytes.windows(12).any(|w| w == b"._tagged.txt"));
    let o = Opened::named("tar-appledouble", "ad.tar", &bytes);
    assert_eq!(sorted(o.rows("")), ["plain.txt", "tagged.txt"]);
    assert_eq!(o.read("tagged.txt"), b"data");
    let src = Src::new("tar-trailing");
    src.put("foo.txt", b"body");
    src.put("._foo.txt", b"not really appledouble");
    let args = [["-c"].as_slice(), &PLAIN, &["foo.txt", "._foo.txt"]].concat();
    let o = Opened::named("tar-trailing", "f.tar", &src.tar("f.tar", &args));
    assert_eq!(sorted(o.rows("")), ["._foo.txt", "foo.txt"]);
    assert!(
        o.source()
            .entries
            .iter()
            .any(|e| e.path == "._foo.txt" && e.attrs.hidden)
    );
    assert_eq!(o.read("._foo.txt"), b"not really appledouble");
    assert_eq!(o.read("foo.txt"), b"body");
}

fn rar5_stored() -> Vec<u8> {
    let time = record5(
        3,
        &[vint(0x1 | 0x2), (RAR_TIME + 7).to_le_bytes().to_vec()].concat(),
    );
    rar5(&[
        packed5(b"dir", b"", 0, 0o40750, 0, &[]),
        packed5(b"dir/a.txt", b"alpha body", 10, 0o100640, 0, &time),
        file5(b"b.txt", b"beta"),
        packed5(b"lnk", b"", 0, 0o120777, 0, &redirect5(1, b"b.txt")),
        packed5(b"hard", b"", 0, 0o100644, 0, &redirect5(4, b"dir/a.txt")),
    ])
}

fn rar5_reads(o: &Opened) {
    let top = o.rows("");
    assert_eq!(names(top.clone()), ["dir", "b.txt", "hard", "lnk"]);
    let b = row(&top, "b.txt");
    assert_eq!((b.size, b.modified), (4, i64::from(RAR_TIME)));
    assert_eq!(row(&top, "lnk").kind, EngineKind::Link);
    assert_eq!(
        (row(&top, "hard").kind, row(&top, "hard").size),
        (EngineKind::File, 10)
    );
    let inner = o.rows("dir");
    let a = row(&inner, "a.txt");
    assert_eq!((a.size, a.modified), (10, i64::from(RAR_TIME) + 7));
    let s = o.summary();
    assert_eq!(
        (s.format.as_str(), s.items, s.bytes, s.skipped, s.problem),
        ("rar", 3, 24, 0, None)
    );
    let job = o.extract(&["dir/a.txt", "dir", "lnk"], false);
    assert_eq!(job.problem, None);
    let out = o.output();
    assert_eq!(fs::read(out.join("dir/a.txt")).unwrap(), b"alpha body");
    assert_eq!(
        fs::metadata(out.join("dir/a.txt")).unwrap().mode() & 0o7777,
        0o640
    );
    assert_eq!(
        fs::metadata(out.join("dir")).unwrap().mode() & 0o7777,
        0o750
    );
    assert_eq!(
        fs::read_link(out.join("lnk")).unwrap(),
        PathBuf::from("b.txt")
    );
    assert_eq!(o.read("hard"), b"alpha body");
    assert_eq!(o.read("b.txt"), b"beta");
}

#[test]
fn rar5_stored_lists_and_reads() {
    rar5_reads(&Opened::named("rar5-stored", "s.rar", &rar5_stored()));
}

#[test]
fn rar4_stored_lists_and_reads() {
    let encoded = [
        0x00, 0xaa, 0xe5, 0x65, 0x2c, 0x67, 0x2e, 0x00, 0x74, 0x00, 0xa0, 0x78, 0x00, 0x74, 0x00,
    ];
    let bytes = rar4(
        &[
            file4(
                b"plain4.txt",
                b"rar4 body",
                0,
                0o100644,
                &0xc000u16.to_le_bytes(),
            ),
            file4(
                &[b"??.txt\0".as_slice(), &encoded].concat(),
                b"uni body",
                0x0200,
                0o100644,
                &[],
            ),
            file4("\u{fc}.txt".as_bytes(), b"utf8 body", 0x0200, 0o100644, &[]),
            file4(b"lnk4", b"plain4.txt", 0, 0o120777, &[]),
        ],
        0,
    );
    let o = Opened::named("rar4-stored", "s4.rar", &bytes);
    let top = o.rows("");
    assert_eq!(
        sorted(top.clone()),
        ["lnk4", "plain4.txt", "\u{fc}.txt", "\u{65e5}\u{672c}.txt"]
    );
    assert_eq!(
        local(row(&top, "plain4.txt").modified),
        (2021, 3, 4, 5, 6, 9)
    );
    assert_eq!(
        local(row(&top, "\u{fc}.txt").modified),
        (2021, 3, 4, 5, 6, 8)
    );
    assert_eq!(row(&top, "lnk4").kind, EngineKind::Link);
    assert_eq!(o.read("plain4.txt"), b"rar4 body");
    assert_eq!(o.read("\u{65e5}\u{672c}.txt"), b"uni body");
    assert_eq!(o.read("\u{fc}.txt"), b"utf8 body");
    assert_eq!(o.extract(&["lnk4"], false).problem, None);
    assert_eq!(
        fs::read_link(o.output().join("lnk4")).unwrap(),
        PathBuf::from("plain4.txt")
    );
}

#[test]
fn cbr_reads_as_rar() {
    rar5_reads(&Opened::named("rar-cbr", "comic.cbr", &rar5_stored()));
}

#[test]
fn rar5_encrypted_names_report_encrypted_and_list_nothing() {
    let encryption = block5(
        4,
        0,
        &[vint(0), vint(0), vec![15], vec![0; 16]].concat(),
        &[],
        None,
    );
    let bytes = [b"Rar!\x1a\x07\x01\x00".to_vec(), encryption, noise(96)].concat();
    let o = Opened::named("rar5-locked-names", "locked.rar", &bytes);
    assert!(o.rows("").is_empty());
    let s = o.session.summary().unwrap();
    assert_eq!(
        (s.problem, s.encrypted, s.items),
        (Some(ArchiveProblem::Encrypted), true, 0)
    );
}

#[test]
fn rar5_encrypted_entry_lists_and_reading_it_reports_encrypted_without_a_child() {
    let record = record5(1, &[vint(0), vint(0), vec![15], vec![7; 32]].concat());
    let bytes = rar5(&[
        file5(b"plain.txt", b"open body"),
        packed5(b"secret.txt", &[0x55; 16], 16, 0o100644, 0, &record),
    ]);
    let o = Opened::named("rar5-locked-entry", "e.rar", &bytes);
    assert_eq!(o.read("plain.txt"), b"open body");
    assert_eq!(sorted(o.rows("")), ["plain.txt", "secret.txt"]);
    assert!(o.summary().encrypted);
    let second = o.open(&o.path);
    let g = second.browse(String::new()).unwrap();
    o.wait(g, Duration::from_secs(10));
    let id = second
        .extract(
            vec!["secret.txt".into()],
            o.output().to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    assert_eq!(
        finished(&second, id).problem,
        Some(ArchiveProblem::Encrypted)
    );
    assert!(!o.output().join("secret.txt").exists());
    let source = second.state.lock().unwrap().source.clone().unwrap();
    let Format::Rar(rar) = &*source.format else {
        panic!("not a rar");
    };
    assert!(!rar.spelled());
}

#[test]
fn rar4_encrypted_flags_report_encrypted() {
    let plain = file4(b"plain4.txt", b"rar4 body", 0, 0o100644, &[]);
    let o = Opened::named(
        "rar4-locked-names",
        "n4.rar",
        &rar4(std::slice::from_ref(&plain), 0x0080),
    );
    assert!(o.rows("").is_empty());
    let s = o.session.summary().unwrap();
    assert_eq!(
        (s.problem, s.encrypted),
        (Some(ArchiveProblem::Encrypted), true)
    );
    let bytes = rar4(
        &[
            plain,
            file4(b"secret4.txt", b"0123456789abcdef", 0x0004, 0o100644, &[]),
        ],
        0,
    );
    let o = Opened::named("rar4-locked-entry", "e4.rar", &bytes);
    assert_eq!(o.read("plain4.txt"), b"rar4 body");
    assert_eq!(sorted(o.rows("")), ["plain4.txt", "secret4.txt"]);
    assert!(o.summary().encrypted);
    assert_eq!(o.refused("secret4.txt"), Some(ArchiveProblem::Encrypted));
}

#[test]
fn rar_member_that_fails_leaves_no_zero_filled_file() {
    let junk: Vec<u8> = (0..300u32).map(|i| (i * 37 + 11) as u8).collect();
    let bytes = rar5(&[
        file5(b"good.txt", b"good body"),
        packed5(b"junk.bin", &junk, 4000, 0o100644, 1 << 7, &[]),
    ]);
    let o = Opened::named("rar-fails-junk", "j.rar", &bytes);
    assert_eq!(o.read("good.txt"), b"good body");
    assert_eq!(row(&o.rows(""), "junk.bin").size, 4000);
    assert_eq!(o.refused("junk.bin"), Some(ArchiveProblem::Damaged));
    let mut broken = file5(b"after.txt", b"after");
    broken[0] ^= 0xff;
    let bytes = [
        b"Rar!\x1a\x07\x01\x00".to_vec(),
        block5(1, 0, &vint(0), &[], None),
        file5(b"good.txt", b"good body"),
        broken,
        block5(5, 0, &vint(0), &[], None),
    ]
    .concat();
    let o = Opened::named("rar-fails-after", "a.rar", &bytes);
    assert_eq!(names(o.rows("")), ["good.txt"]);
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::Damaged)
    );
    assert_eq!(o.refused("good.txt"), Some(ArchiveProblem::Damaged));
}

#[test]
fn rar_glob_characters_in_names_read_the_right_member() {
    let pairs: [(&str, &[u8]); 8] = [
        ("x[1].txt", b"BODY-x[1]"),
        ("x1.txt", b"BODY-x1"),
        ("star*.txt", b"BODY-star"),
        ("starX.txt", b"BODY-starX"),
        ("q?.txt", b"BODY-q?"),
        ("qa.txt", b"BODY-qa"),
        ("b\\ack.txt", b"BODY-back"),
        ("back.txt", b"BODY-bck"),
    ];
    let members: Vec<_> = pairs
        .iter()
        .map(|(name, body)| file5(name.as_bytes(), body))
        .collect();
    let o = Opened::named("rar-globs", "g.rar", &rar5(&members));
    for (name, body) in pairs {
        assert_eq!(o.read(name), body, "{name}");
    }
}

#[test]
fn rar_name_stored_twice_reads_the_last_copy() {
    let bytes = rar5(&[
        file5(b"dup.txt", b"first"),
        file5(b"other.txt", b"x"),
        file5(b"dup.txt", b"second!"),
    ]);
    let o = Opened::named("rar-twice", "d.rar", &bytes);
    let rows = o.rows("");
    assert_eq!(sorted(rows.clone()), ["dup.txt", "other.txt"]);
    assert_eq!(row(&rows, "dup.txt").size, 7);
    assert_eq!(o.read("dup.txt"), b"second!");
    assert_eq!(o.read("other.txt"), b"x");
}

#[test]
fn rar_dotdot_and_absolute_names_skipped_and_never_read() {
    let bytes = rar5(&[
        file5(b"ok.txt", b"OK"),
        file5(b"../up.txt", b"UP"),
        file5(b"a/../b.txt", b"B"),
        file5(b"/abs.txt", b"ABS"),
        file5(b"x/..", b"X"),
    ]);
    let o = Opened::named("rar-hostile", "h.rar", &bytes);
    assert_eq!(o.read("ok.txt"), b"OK");
    assert_eq!(names(o.rows("")), ["ok.txt"]);
    assert_eq!(o.summary().skipped, 4);
    assert_eq!(
        o.refused("../up.txt"),
        Some(ArchiveProblem::PointsOutside {
            name: "../up.txt".into()
        })
    );
    assert_eq!(
        o.refused("up.txt"),
        Some(ArchiveProblem::Gone {
            name: "up.txt".into()
        })
    );
    assert!(!PathBuf::from(o.tree.real()).join("up.txt").exists());
    assert!(!PathBuf::from(o.tree.real()).join("b.txt").exists());
}

fn spelled(source: &Source, count: usize) -> Result<Vec<Vec<u8>>, Option<ArchiveProblem>> {
    bsdtar::spelling(&source.path, source.stamp, count, &|| false).map_err(
        |failure| match failure {
            Failure::Problem(problem) => Some(problem),
            _ => None,
        },
    )
}

#[test]
fn bsdtar_spelling_pairs_by_position() {
    let src = Src::new("spelling");
    fs::create_dir_all(src.dir().join("dir")).unwrap();
    let tagged = src.put("tagged.txt", b"data");
    let path = std::ffi::CString::new(tagged.to_str().unwrap()).unwrap();
    let value = b"hello";
    let set = unsafe {
        libc::setxattr(
            path.as_ptr(),
            c"com.example.probe".as_ptr(),
            value.as_ptr().cast(),
            value.len(),
            0,
            0,
        )
    };
    assert_eq!(set, 0);
    src.put("._foo.txt", b"not ad");
    src.put("foo2.txt", b"foo2");
    src.put("caf\u{e9}.txt", b"nfc");
    src.put("dup.txt", b"first");
    src.put("._last.txt", b"last");
    src.put("after.txt", b"after");
    src.tar("s.tar", &["-c", "--format=pax", "dir", "tagged.txt"]);
    src.tar(
        "s.tar",
        &[
            "-r",
            "--no-mac-metadata",
            "._foo.txt",
            "foo2.txt",
            "caf\u{e9}.txt",
            "dup.txt",
        ],
    );
    src.put("dup.txt", b"second!");
    src.tar("s.tar", &["-r", "--no-mac-metadata", "dup.txt"]);
    src.tar(
        "s.tar",
        &[
            "-r",
            "--no-mac-metadata",
            "-P",
            "-s",
            "|^after.txt$|a/../b.txt|",
            "after.txt",
        ],
    );
    let bytes = src.tar(
        "s.tar",
        &["-r", "--no-mac-metadata", "after.txt", "._last.txt"],
    );
    let o = Opened::named("spelling-tar", "s.tar", &bytes);
    assert_eq!(o.read("foo2.txt"), b"foo2");
    let source = o.source();
    let Format::Tar(members) = &*source.format else {
        panic!("not a tar");
    };
    assert_eq!(members.len(), 9);
    let lines = spelled(&source, members.len()).unwrap();
    assert!(lines.contains(&b"a/../b.txt".to_vec()));
    let at = |path: &str| {
        source
            .entries
            .iter()
            .find(|e| e.path == path)
            .and_then(|e| e.index)
            .unwrap_or_else(|| panic!("{path} not listed"))
    };
    for (path, spelling) in [
        ("dir", b"dir/".as_slice()),
        ("tagged.txt", b"tagged.txt"),
        ("foo2.txt", b"foo2.txt"),
        ("caf\u{e9}.txt", "cafe\u{301}.txt".as_bytes()),
        ("dup.txt", b"dup.txt"),
        ("after.txt", b"after.txt"),
        ("._last.txt", b"._last.txt"),
    ] {
        assert_eq!(lines[at(path)], spelling, "{path}");
    }
    assert_eq!(lines[at("dup.txt") - 1], b"dup.txt");
    assert_eq!(
        spelled(&source, members.len() + 1),
        Err(Some(ArchiveProblem::Damaged))
    );
    let o = Opened::named(
        "spelling-rar-nfc",
        "c.rar",
        &rar5(&[file5("caf\u{e9}.txt".as_bytes(), b"nfc body")]),
    );
    assert_eq!(o.read("caf\u{e9}.txt"), b"nfc body");
    let source = o.source();
    assert_eq!(spelled(&source, 1).unwrap(), ["cafe\u{301}.txt".as_bytes()]);
    let o = Opened::named(
        "spelling-rar-short",
        "u.rar",
        &rar5(&[file5(b"\xe9x", b"e"), file5(b"ok.txt", b"ok")]),
    );
    assert_eq!(sorted(o.rows("")), ["ok.txt", "\u{fffd}x"]);
    assert_eq!(o.refused("ok.txt"), Some(ArchiveProblem::Damaged));
}

#[test]
fn tar_gz_holding_no_tar_is_unsupported() {
    let src = Src::new("tar-not-inside");
    src.put("notes.txt", b"real notes");
    let real = src.tar(
        "real.tar.gz",
        &["-cz", "--no-mac-metadata", "--no-xattrs", "notes.txt"],
    );
    let o = Opened::named("tar-not-inside-real", "notes.tar.gz", &real);
    assert_eq!(o.read("notes.txt"), b"real notes");
    let text = gzipped(&b"just some notes\n".repeat(100));
    for (label, name, bytes) in [
        ("tar-not-inside-text", "notes.tar.gz", &text),
        ("tar-not-inside-lone", "notes.gz", &text),
        ("tar-not-inside-named", "notes.gz", &real),
    ] {
        let o = Opened::named(label, name, bytes);
        assert!(o.rows("").is_empty(), "{label}");
        assert_eq!(
            o.session.summary().unwrap().problem,
            Some(ArchiveProblem::Unsupported),
            "{label}"
        );
    }
}

#[test]
fn archive_extensions_are_the_supported_set() {
    let o = Opened::new("archive-extensions", &fixture(&[("a", b"")]));
    assert_eq!(
        o.engine.archive_extensions().unwrap(),
        [
            "zip", "jar", "aar", "apk", "cbz", "tar", "tgz", "tar.gz", "tbz", "tbz2", "tar.bz2",
            "txz", "tar.xz", "rar", "cbr", "pkg", "dmg"
        ]
    );
}

#[test]
fn stderr_lines_from_p1_map_to_problems() {
    use bsdtar::{Line, line, problem};
    for text in [
        "tar: Incorrect passphrase",
        "Enter passphrase:",
        "tar: Encryption is not supported",
        "tar: RAR encryption support unavailable.",
    ] {
        assert_eq!(line(text.as_bytes()), Line::Encrypted, "{text}");
        assert_eq!(
            problem(text.as_bytes(), false),
            ArchiveProblem::Encrypted,
            "{text}"
        );
    }
    for text in [
        "big.bin: Invalid PPMd sequence: Inappropriate file type or format",
        "a.bin: Unsupported block header size (was 7, max is 2): Inappropriate file type or format",
        "a.bin: Unsupported block header size (was 3, max is 2): Inappropriate file type or format",
    ] {
        assert_eq!(line(text.as_bytes()), Line::EncryptedMember, "{text}");
        assert_eq!(
            problem(text.as_bytes(), true),
            ArchiveProblem::Encrypted,
            "{text}"
        );
        assert_eq!(
            problem(text.as_bytes(), false),
            ArchiveProblem::Damaged,
            "{text}"
        );
    }
    for text in [
        "lnk/evil.txt: Cannot extract through symlink lnk/evil.txt: Undefined error: 0",
        "after.txt: Failed to restore metadata: File exists",
    ] {
        assert_eq!(line(text.as_bytes()), Line::Skipped, "{text}");
        assert_eq!(
            problem(text.as_bytes(), true),
            ArchiveProblem::Damaged,
            "{text}"
        );
    }
    for text in [
        "tar: ./nope.txt: Not found in archive",
        "tar: Truncated input file (needed 512 bytes, only 0 available)",
        "._foo.txt: Truncated tar archive: Unknown error: -1",
        "tar: Header CRC error",
        "tar: Archive entry has empty or unreadable filename ... skipping.",
        "junk.bin: Block checksum error: got 0x30, expected 0x7e: Inappropriate file type or format",
        "tar: Error exit delayed from previous errors.",
    ] {
        assert_eq!(line(text.as_bytes()), Line::Damaged, "{text}");
        assert_eq!(
            problem(text.as_bytes(), true),
            ArchiveProblem::Damaged,
            "{text}"
        );
    }
    assert_eq!(
        problem(
            b"tar: Error exit delayed from previous errors.\ntar: Incorrect passphrase\n",
            false
        ),
        ArchiveProblem::Encrypted
    );
}

#[test]
fn truncated_tar_gz_is_damaged_within_two_seconds() {
    let src = Src::new("tar-truncated");
    src.put("first.txt", b"first");
    src.put("second.bin", &noise(512 * 1024));
    let bytes = src.tar(
        "t.tar.gz",
        &[
            "-cz",
            "--no-mac-metadata",
            "--no-xattrs",
            "first.txt",
            "second.bin",
        ],
    );
    let o = Opened::named("tar-truncated", "t.tar.gz", &bytes[..bytes.len() * 3 / 4]);
    let now = Instant::now();
    let rows = o.rows("");
    assert!(now.elapsed() < Duration::from_secs(2));
    assert_eq!(names(rows), ["first.txt"]);
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::Damaged)
    );
    assert_eq!(o.read("first.txt"), b"first");
}

#[test]
fn changed_or_swapped_archive_refuses_before_reading() {
    let src = Src::new("changed-tar");
    src.put("ok.txt", b"good");
    let bytes = src.tar(
        "c.tar",
        &["-c", "--no-mac-metadata", "--no-xattrs", "ok.txt"],
    );
    let o = Opened::named("changed-tar", "c.tar", &bytes);
    assert_eq!(o.read("ok.txt"), b"good");
    src.put("ok.txt", b"rewritten in place");
    let other = src.tar(
        "d.tar",
        &["-c", "--no-mac-metadata", "--no-xattrs", "ok.txt"],
    );
    fs::write(&o.path, other).unwrap();
    assert_eq!(o.refused("ok.txt"), Some(ArchiveProblem::Changed));
    let o = Opened::named("swapped-rar", "c.rar", &rar5(&[file5(b"ok.txt", b"good")]));
    assert_eq!(o.read("ok.txt"), b"good");
    let swap = o.path.with_extension("swap");
    fs::write(&swap, rar5(&[file5(b"ok.txt", b"other body")])).unwrap();
    fs::rename(&swap, &o.path).unwrap();
    assert_eq!(o.refused("ok.txt"), Some(ArchiveProblem::Changed));
}

fn big_tar_gz(label: &str) -> Vec<u8> {
    let src = Src::new(label);
    src.put("big.bin", &noise(256 * 1024));
    src.put("small.txt", b"small");
    src.tar(
        "b.tar.gz",
        &[
            "-cz",
            "--no-mac-metadata",
            "--no-xattrs",
            "big.bin",
            "small.txt",
        ],
    )
}

fn big_rar() -> Vec<u8> {
    rar5(&[
        file5(b"big.bin", &noise(256 * 1024)),
        file5(b"small.txt", b"small"),
    ])
}

#[test]
fn two_reads_of_different_entries_run_at_once() {
    for o in [
        Opened::named("at-once-tar", "b.tar.gz", &big_tar_gz("at-once-tar-src")),
        Opened::named("at-once-rar", "b.rar", &big_rar()),
    ] {
        o.rows("");
        let (reached, release) = o.hold();
        let (first, big) = o.start("big.bin", "first");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        let (second, small) = o.start("small.txt", "second");
        assert_eq!(finished(&o.session, second).problem, None);
        assert_eq!(fs::read(small.join("small.txt")).unwrap(), b"small");
        release.send(()).unwrap();
        assert_eq!(finished(&o.session, first).problem, None);
        assert_eq!(fs::read(big.join("big.bin")).unwrap(), noise(256 * 1024));
    }
}

#[test]
fn child_runs_with_only_usr_bin_on_its_path() {
    let command = bsdtar::command("/usr/bin/env");
    let Ok(mut child) = bsdtar::spawn(command, None) else {
        panic!("env did not start");
    };
    let mut out = Vec::new();
    child.stdout.read_to_end(&mut out).unwrap();
    assert_eq!(String::from_utf8(out).unwrap(), "PATH=/usr/bin:/bin\n");
}

#[test]
fn cancel_stops_the_tar_decoder_and_kills_the_rar_child() {
    for o in [
        Opened::named("cancel-tar", "b.tar.gz", &big_tar_gz("cancel-tar-src")),
        Opened::named("cancel-rar", "b.rar", &big_rar()),
    ] {
        o.rows("");
        let (reached, release) = o.hold();
        let (id, folder) = o.start("big.bin", "cancelled");
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        o.session.cancel(id).unwrap();
        release.send(()).unwrap();
        let job = finished(&o.session, id);
        assert!(job.done_bytes > 0 && job.done_bytes < job.total_bytes);
        assert!(job.written.is_empty());
        assert!(!folder.join("big.bin").exists());
        if o.path.extension().is_some_and(|e| e == "rar") {
            assert!(reaped(&o.path));
        }
        assert_eq!(o.read("small.txt"), b"small");
    }
}

fn decoders(o: &Opened) -> usize {
    let stamp = o.source().stamp;
    tar::DECODERS
        .lock()
        .unwrap()
        .iter()
        .filter(|s| **s == stamp)
        .count()
}

fn bodies(o: &Opened, names: &[String]) {
    for name in names {
        let n = name.trim_start_matches("dir/f").trim_end_matches(".txt");
        assert_eq!(
            fs::read(o.output().join(name)).unwrap(),
            format!("body {}", n.parse::<u32>().unwrap()).as_bytes(),
            "{name}"
        );
    }
}

#[test]
fn many_entries_from_one_tarball_read_it_in_one_forward_pass() {
    let src = Src::new("tar-once");
    for n in 0..200 {
        src.put(&format!("dir/f{n:03}.txt"), format!("body {n}").as_bytes());
    }
    for (name, mode) in [
        ("a.tar.gz", "-cz"),
        ("a.tar.bz2", "-cj"),
        ("a.tar.xz", "-cJ"),
        ("a.tar", "-c"),
    ] {
        let bytes = src.tar(name, &[mode, "--no-mac-metadata", "--no-xattrs", "dir"]);
        let o = Opened::named(&format!("tar-once-{name}"), name, &bytes);
        let wanted: Vec<String> = (0..200).rev().map(|n| format!("dir/f{n:03}.txt")).collect();
        let picked: Vec<&str> = wanted.iter().map(String::as_str).collect();
        let before = decoders(&o);
        let job = o.extract(&picked, false);
        assert_eq!((job.problem, job.done_items), (None, 200), "{name}");
        assert_eq!(decoders(&o) - before, 1, "{name}");
        bodies(&o, &wanted);
    }
}

#[test]
fn a_tarball_folder_extracts_its_subtree_in_one_forward_pass() {
    let src = Src::new("tar-folder");
    for n in 0..50 {
        src.put(&format!("dir/f{n:03}.txt"), format!("body {n}").as_bytes());
    }
    src.put("other/x.txt", b"x");
    let bytes = src.tar(
        "a.tar.gz",
        &["-cz", "--no-mac-metadata", "--no-xattrs", "dir", "other"],
    );
    let o = Opened::named("tar-folder", "a.tar.gz", &bytes);
    let before = decoders(&o);
    let job = o.extract(&["dir"], false);
    assert_eq!((job.problem, job.done_items), (None, 51));
    assert_eq!(decoders(&o) - before, 1);
    bodies(
        &o,
        &(0..50)
            .map(|n| format!("dir/f{n:03}.txt"))
            .collect::<Vec<_>>(),
    );
    assert!(!o.output().join("other").exists());
}

#[test]
fn single_reads_of_a_tarball_each_open_their_own_decoder() {
    let src = Src::new("tar-single");
    for n in 0..20 {
        src.put(&format!("dir/f{n:03}.txt"), format!("body {n}").as_bytes());
    }
    let bytes = src.tar(
        "a.tar.gz",
        &["-cz", "--no-mac-metadata", "--no-xattrs", "dir"],
    );
    let o = Opened::named("tar-single", "a.tar.gz", &bytes);
    let before = decoders(&o);
    assert_eq!(o.read("dir/f010.txt"), b"body 10");
    assert_eq!(o.read("dir/f005.txt"), b"body 5");
    assert_eq!(o.read("dir/f015.txt"), b"body 15");
    assert_eq!(decoders(&o) - before, 3);
}

#[test]
fn a_hard_link_and_its_target_read_together_in_one_job() {
    let src = Src::new("tar-hard-both");
    src.put("dir/orig.txt", b"hello hard link");
    src.put("dir/zz.txt", b"after");
    fs::hard_link(src.dir().join("dir/orig.txt"), src.dir().join("hard.txt")).unwrap();
    let bytes = src.tar("h.tar", &["-c", "--no-mac-metadata", "--no-xattrs", "."]);
    for (name, bytes) in [("h.tar", bytes.clone()), ("h.tar.gz", gzipped(&bytes))] {
        let o = Opened::named(&format!("tar-hard-both-{name}"), name, &bytes);
        let job = o.extract(&["hard.txt", "dir/zz.txt", "dir/orig.txt"], false);
        assert_eq!((job.problem, job.done_items), (None, 3), "{name}");
        let out = o.output();
        assert_eq!(fs::read(out.join("hard.txt")).unwrap(), b"hello hard link");
        assert_eq!(
            fs::read(out.join("dir/orig.txt")).unwrap(),
            b"hello hard link"
        );
        assert_eq!(fs::read(out.join("dir/zz.txt")).unwrap(), b"after");
    }
}

#[test]
fn a_name_stored_twice_reads_its_last_copy_beside_other_entries() {
    let src = Src::new("tar-twice-many");
    src.put("dup.txt", b"first");
    src.put("other.txt", b"x");
    src.tar(
        "d.tar",
        &[
            "-c",
            "--no-mac-metadata",
            "--no-xattrs",
            "dup.txt",
            "other.txt",
        ],
    );
    src.put("dup.txt", b"second!");
    let bytes = src.tar(
        "d.tar",
        &["-r", "--no-mac-metadata", "--no-xattrs", "dup.txt"],
    );
    let o = Opened::named("tar-twice-many", "d.tar.gz", &gzipped(&bytes));
    let job = o.extract(&["other.txt", "dup.txt"], false);
    assert_eq!((job.problem, job.done_items), (None, 2));
    assert_eq!(fs::read(o.output().join("dup.txt")).unwrap(), b"second!");
    assert_eq!(fs::read(o.output().join("other.txt")).unwrap(), b"x");
}

fn sealed(entries: &[(&str, &[u8], FileOptions<'_, '_, ()>)]) -> Vec<u8> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    for &(name, bytes, options) in entries {
        zip.start_file(name, options).unwrap();
        zip.write_all(bytes).unwrap();
    }
    zip.finish().unwrap().into_inner()
}

fn stored<'k>() -> FileOptions<'k, 'static, ()> {
    FileOptions::default().compression_method(CompressionMethod::Stored)
}

fn crypto(password: &str) -> FileOptions<'_, 'static, ()> {
    ::zip::unstable::write::FileOptionsExt::with_deprecated_encryption(
        stored(),
        password.as_bytes(),
    )
    .unwrap()
}

#[test]
fn right_password_extracts_the_bytes() {
    let body: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let deflated = ::zip::unstable::write::FileOptionsExt::with_deprecated_encryption(
        FileOptions::default().compression_method(CompressionMethod::Deflated),
        b"right",
    )
    .unwrap();
    let o = Opened::new(
        "unlock-right",
        &sealed(&[
            ("dir/body.bin", &body, deflated),
            ("note.txt", b"stored note", crypto("right")),
        ]),
    );
    assert_eq!(names(o.rows("")), ["dir", "note.txt"]);
    assert!(o.summary().encrypted);
    assert!(!o.session.unlock("wrong".into()).unwrap());
    assert!(o.session.unlock("right".into()).unwrap());
    assert_eq!(o.read("dir/body.bin"), body);
    assert_eq!(o.read("note.txt"), b"stored note");
    let only = sealed(&[("only.txt", b"only body", crypto("right"))]);
    let near = (0..20_000)
        .map(|i| format!("w{i}"))
        .find(|w| {
            ::zip::ZipArchive::new(Cursor::new(&only))
                .unwrap()
                .by_index_decrypt(0, w.as_bytes())
                .is_ok()
        })
        .unwrap();
    let c = Opened::new("unlock-crc", &only);
    c.rows("");
    assert!(!c.session.unlock(near).unwrap());
    assert!(c.session.password.lock().unwrap().is_empty());
    assert!(c.session.unlock("right".into()).unwrap());
}

#[test]
fn aes_right_password_extracts_and_wrong_one_returns_false() {
    for mode in [AesMode::Aes128, AesMode::Aes256] {
        let o = Opened::new(
            "unlock-aes",
            &sealed(&[(
                "file",
                METHOD_BYTES,
                stored().with_aes_encryption(mode, "right"),
            )]),
        );
        o.rows("");
        assert!(!o.session.unlock("wrong".into()).unwrap());
        assert!(o.session.password.lock().unwrap().is_empty());
        let job = o.extract(&["file"], false);
        assert_eq!(job.problem, Some(ArchiveProblem::PasswordNeeded));
        assert!(!o.output().join("file").exists());
        assert!(o.session.unlock("right".into()).unwrap());
        assert_eq!(o.read("file"), METHOD_BYTES);
        let mut tampered = sealed(&[(
            "file",
            METHOD_BYTES,
            stored().with_aes_encryption(mode, "right"),
        )]);
        assert_eq!(tampered[headers(&tampered, b"PK\x03\x04")[0] + 6] & 0x08, 0);
        let last = headers(&tampered, b"PK\x01\x02")[0] - 1;
        tampered[last] ^= 0xff;
        let t = Opened::new("unlock-aes-code", &tampered);
        t.rows("");
        assert!(!t.session.unlock("right".into()).unwrap());
        assert!(t.session.password.lock().unwrap().is_empty());
    }
}

#[test]
fn wrong_password_leaves_no_file() {
    let body = vec![7u8; 70_000];
    let mut found: (Option<Vec<u8>>, Option<Vec<u8>>) = (None, None);
    for i in 0..20_000 {
        let other = format!("other{i}");
        let bytes = sealed(&[
            ("a.txt", b"small", crypto("right")),
            ("b.bin", &body, crypto(&other)),
        ]);
        let passes = ::zip::ZipArchive::new(Cursor::new(&bytes))
            .unwrap()
            .by_index_decrypt(1, b"right")
            .is_ok();
        let slot = if passes { &mut found.0 } else { &mut found.1 };
        slot.get_or_insert(bytes);
        if found.0.is_some() && found.1.is_some() {
            break;
        }
    }
    let (Some(passes_check), Some(fails_check)) = found else {
        panic!("no wrong password passed the check byte");
    };
    for (bytes, wrote) in [(passes_check, true), (fails_check, false)] {
        let o = Opened::new("unlock-wrong", &bytes);
        o.rows("");
        assert!(o.session.unlock("right".into()).unwrap());
        let job = o.extract(&["b.bin"], false);
        assert_eq!(job.problem, Some(ArchiveProblem::WrongPassword));
        assert_eq!(job.done_bytes > 0, wrote);
        assert!(job.written.is_empty());
        assert!(!o.output().join("b.bin").exists());
        assert_eq!(o.read("a.txt"), b"small");
    }
}

#[test]
fn password_needed_before_unlock() {
    for options in [
        crypto("right"),
        stored().with_aes_encryption(AesMode::Aes256, "right"),
    ] {
        let o = Opened::new(
            "unlock-needed",
            &sealed(&[("dir/secret.txt", b"secret", options)]),
        );
        let job = o.extract(&["dir/secret.txt"], false);
        assert_eq!(job.problem, Some(ArchiveProblem::PasswordNeeded));
        assert_eq!((job.done_bytes, job.done_items), (0, 0));
        assert!(!o.output().join("dir").exists());
        assert!(o.session.unlock("right".into()).unwrap());
        assert_eq!(o.read("dir/secret.txt"), b"secret");
    }
}

fn locked_link(options: FileOptions<'_, '_, ()>) -> Vec<u8> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    zip.start_file("dir/file.txt", options).unwrap();
    zip.write_all(b"linked body").unwrap();
    zip.add_symlink("dir/alias", "file.txt", options).unwrap();
    zip.start_file("gone.txt", options).unwrap();
    zip.write_all(b"gone").unwrap();
    zip.finish().unwrap().into_inner()
}

#[test]
fn encrypted_links_extract_expand_and_save_after_unlock() {
    for (options, editing) in [
        (crypto("right"), ArchiveEditing::OldEncryption),
        (
            stored().with_aes_encryption(AesMode::Aes256, "right"),
            ArchiveEditing::All,
        ),
    ] {
        let o = Opened::new("unlock-link", &locked_link(options));
        assert_eq!(
            o.extract(&["dir/alias"], false).problem,
            Some(ArchiveProblem::PasswordNeeded)
        );
        assert!(o.session.unlock("right".into()).unwrap());
        let job = o.extract(&["dir/alias"], false);
        assert_eq!(job.problem, None);
        assert_eq!(
            fs::read_link(o.output().join("dir/alias")).unwrap(),
            PathBuf::from("file.txt")
        );
        let dest = o.place("dest");
        assert_eq!(o.expand(&["dir"], false, &dest).problem, None);
        assert_eq!(
            fs::read_link(dest.join("dir/alias")).unwrap(),
            PathBuf::from("file.txt")
        );
        assert_eq!(fs::read(dest.join("dir/alias")).unwrap(), b"linked body");
        let whole = o.place("whole");
        assert_eq!(o.expand(&[], true, &whole).problem, None);
        assert_eq!(
            fs::read_link(whole.join("archive/dir/alias")).unwrap(),
            PathBuf::from("file.txt")
        );
        assert_eq!(o.summary().editing, editing);
        o.changed(vec![delete("gone.txt")]);
        let (job, out) = o.saved("twin.zip");
        if editing == ArchiveEditing::OldEncryption {
            assert_eq!(job.problem, Some(ArchiveProblem::OldEncryption));
            continue;
        }
        assert_eq!(job.problem, None);
        assert_eq!(zip_names(&out), ["dir/file.txt", "dir/alias"]);
        assert!(zip_at(&out).by_index_data(1).unwrap().encrypted());
        assert_eq!(
            zip_read(&out, "dir/alias", Some(b"right".as_slice())),
            b"file.txt"
        );
    }
}

#[test]
fn a_link_only_password_zip_refuses_the_wrong_password() {
    for options in [
        crypto("right"),
        stored().with_aes_encryption(AesMode::Aes256, "right"),
    ] {
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        zip.add_symlink("alias", "elsewhere", options).unwrap();
        let o = Opened::new("unlock-link-only", &zip.finish().unwrap().into_inner());
        o.rows("");
        assert!(!o.session.unlock("wrong".into()).unwrap());
        assert!(o.session.password.lock().unwrap().is_empty());
        assert!(o.session.unlock("right".into()).unwrap());
        assert_eq!(o.extract(&["alias"], false).problem, None);
        assert_eq!(
            fs::read_link(o.output().join("alias")).unwrap(),
            PathBuf::from("elsewhere")
        );
    }
}

#[test]
fn plain_entry_in_a_mixed_zip_needs_no_password() {
    for options in [
        crypto("right"),
        stored().with_aes_encryption(AesMode::Aes128, "right"),
    ] {
        let o = Opened::new(
            "unlock-mixed",
            &sealed(&[
                ("plain.txt", b"open", stored()),
                ("secret.txt", b"closed", options),
            ]),
        );
        assert!(o.summary().encrypted);
        assert_eq!(o.read("plain.txt"), b"open");
        assert_eq!(
            o.extract(&["secret.txt"], false).problem,
            Some(ArchiveProblem::PasswordNeeded)
        );
        assert!(o.session.unlock("right".into()).unwrap());
        assert_eq!(o.read("plain.txt"), b"open");
        assert_eq!(o.read("secret.txt"), b"closed");
    }
}

#[test]
fn unicode_and_200_character_passwords() {
    let long: String = "ğüşİ🔑".chars().cycle().take(200).collect();
    assert_eq!(long.chars().count(), 200);
    for password in ["pässwörd 日本語 🔑", long.as_str()] {
        let short: String = password
            .chars()
            .take(password.chars().count() - 1)
            .collect();
        for options in [
            crypto(password),
            stored().with_aes_encryption(AesMode::Aes256, password),
        ] {
            let o = Opened::new(
                "unlock-unicode",
                &sealed(&[("file", b"unicode body", options)]),
            );
            o.rows("");
            assert!(!o.session.unlock(short.clone()).unwrap());
            assert!(o.session.unlock(password.into()).unwrap());
            assert_eq!(*o.session.password.lock().unwrap(), password.as_bytes());
            assert_eq!(o.read("file"), b"unicode body");
        }
    }
}

#[test]
fn nested_sessions_keep_separate_passwords() {
    let inner = sealed(&[(
        "secret.txt",
        b"inner body",
        stored().with_aes_encryption(AesMode::Aes256, "inner"),
    )]);
    let o = Opened::new(
        "unlock-nested",
        &sealed(&[
            ("inner.zip", &inner, crypto("outer")),
            ("note.txt", b"outer note", crypto("outer")),
        ]),
    );
    o.rows("");
    assert!(o.session.unlock("outer".into()).unwrap());
    assert_eq!(o.extract(&["inner.zip"], false).problem, None);
    let nested = o
        .engine
        .clone()
        .open_archive(
            o.output().join("inner.zip").to_string_lossy().into_owned(),
            "/shown/archive.zip/inner.zip".into(),
        )
        .unwrap();
    let g = nested.browse(String::new()).unwrap();
    o.wait(g, Duration::from_secs(10));
    let folder = o.output().join("nested");
    fs::create_dir_all(&folder).unwrap();
    let pull = |name: &str| {
        let id = nested
            .extract(
                vec![name.into()],
                folder.to_string_lossy().into_owned(),
                false,
            )
            .unwrap();
        finished(&nested, id).problem
    };
    assert_eq!(pull("secret.txt"), Some(ArchiveProblem::PasswordNeeded));
    assert!(!nested.unlock("outer".into()).unwrap());
    assert!(nested.unlock("inner".into()).unwrap());
    assert_eq!(pull("secret.txt"), None);
    assert_eq!(fs::read(folder.join("secret.txt")).unwrap(), b"inner body");
    assert_eq!(*o.session.password.lock().unwrap(), b"outer");
    assert_eq!(*nested.password.lock().unwrap(), b"inner");
    nested.close().unwrap();
    assert!(nested.password.lock().unwrap().iter().all(|b| *b == 0));
    assert_eq!(*o.session.password.lock().unwrap(), b"outer");
    assert_eq!(o.read("note.txt"), b"outer note");
}

#[test]
fn error_text_never_holds_the_password() {
    let password = format!("Zz-secret-ğ-{}", std::process::id());
    let o = Opened::new(
        "unlock-errors",
        &sealed(&[("secret.txt", b"secret", crypto(&password))]),
    );
    o.rows("");
    let mut texts = Vec::new();
    assert!(!o.session.unlock(format!("{password}!")).unwrap());
    texts.push(format!("{:?}", o.extract(&["secret.txt"], false)));
    assert!(o.session.unlock(password.clone()).unwrap());
    let missing = o
        .session
        .extract(
            vec!["secret.txt".into()],
            o.output().join("missing").to_string_lossy().into_owned(),
            false,
        )
        .unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    let error = loop {
        match o.session.job(missing) {
            Err(error) => break error,
            Ok(job) => assert!(!job.finished && Instant::now() < end, "{job:?}"),
        }
        std::thread::sleep(Duration::from_millis(1));
    };
    texts.push(format!("{error:?}"));
    texts.push(error.to_string());
    texts.push(format!("{:?}", o.session.summary().unwrap()));
    o.session.close().unwrap();
    for error in [
        o.session.unlock(password.clone()).unwrap_err(),
        o.session.summary().unwrap_err(),
    ] {
        assert!(matches!(error, EngineError::Stopped));
        texts.push(format!("{error:?}"));
        texts.push(error.to_string());
    }
    assert_eq!(texts.len(), 8);
    for text in &texts {
        assert!(
            !text.contains(&password) && !text.contains("Zz-secret"),
            "{text}"
        );
    }
}

#[test]
fn close_zeroes_the_password() {
    let password = "zero me after close";
    let o = Opened::new(
        "unlock-close",
        &sealed(&[("secret.txt", b"secret", crypto(password))]),
    );
    o.rows("");
    assert!(o.session.unlock(password.into()).unwrap());
    let (at, len) = {
        let stored = o.session.password.lock().unwrap();
        assert_eq!(*stored, password.as_bytes());
        (stored.as_ptr(), stored.len())
    };
    o.session.close().unwrap();
    {
        let stored = o.session.password.lock().unwrap();
        assert_eq!((stored.as_ptr(), stored.len()), (at, len));
        assert!(stored.iter().all(|b| *b == 0));
    }
    assert!(matches!(
        o.session.unlock(password.into()),
        Err(EngineError::Stopped)
    ));
    assert!(o.session.password.lock().unwrap().iter().all(|b| *b == 0));
}

#[test]
fn rar_unlock_returns_false_and_stays_encrypted() {
    let record = record5(1, &[vint(0), vint(0), vec![15], vec![7; 32]].concat());
    let bytes = rar5(&[packed5(
        b"secret.txt",
        &[0x55; 16],
        16,
        0o100644,
        0,
        &record,
    )]);
    let o = Opened::named("rar-unlock", "e.rar", &bytes);
    assert_eq!(names(o.rows("")), ["secret.txt"]);
    assert!(!o.session.unlock("rar password".into()).unwrap());
    assert!(o.session.password.lock().unwrap().is_empty());
    assert_eq!(
        o.extract(&["secret.txt"], false).problem,
        Some(ArchiveProblem::Encrypted)
    );
    assert!(!o.output().join("secret.txt").exists());
    let source = o.source();
    let Format::Rar(rar) = &*source.format else {
        panic!("not a rar");
    };
    assert!(!rar.spelled());
}

const POSTINSTALL: &[u8] = b"#!/bin/sh\nexit 0\n";

fn tool(dir: &std::path::Path, program: &str, args: &[&str]) {
    let out = std::process::Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{program} {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn built_pkgs(label: &str) -> (Vec<u8>, Vec<u8>, Src) {
    let src = Src::new(label);
    let probe = src.dir().join("root/usr/local/probe");
    fs::create_dir_all(probe.join("sub")).unwrap();
    fs::write(probe.join("file.txt"), b"file body\n").unwrap();
    fs::write(probe.join("sub/inner.txt"), b"inner\n").unwrap();
    std::os::unix::fs::symlink("/etc", probe.join("etclink")).unwrap();
    let scripts = src.dir().join("scripts");
    fs::create_dir_all(&scripts).unwrap();
    fs::write(scripts.join("postinstall"), POSTINSTALL).unwrap();
    fs::set_permissions(
        scripts.join("postinstall"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    tool(
        &src.dir(),
        "/usr/bin/pkgbuild",
        &[
            "--root",
            "root",
            "--scripts",
            "scripts",
            "--identifier",
            "com.example.archpkg",
            "--version",
            "1.0",
            "--install-location",
            "/",
            "comp.pkg",
        ],
    );
    tool(
        &src.dir(),
        "/usr/bin/productbuild",
        &["--package", "comp.pkg", "prod.pkg"],
    );
    (
        fs::read(src.dir().join("comp.pkg")).unwrap(),
        fs::read(src.dir().join("prod.pkg")).unwrap(),
        src,
    )
}

fn pkgutil_runs(path: &std::path::Path) -> usize {
    pkg::SPAWNED
        .lock()
        .unwrap()
        .iter()
        .filter(|(p, program)| p == path && program == "/usr/sbin/pkgutil")
        .count()
}

impl Opened {
    fn cache(&self) -> PathBuf {
        let m = fs::metadata(&self.path).unwrap();
        self.tree.0.join("home").join(CACHES).join(format!(
            "{}-{}-{}-{}.{}",
            m.dev() as i32,
            m.ino(),
            m.size(),
            m.mtime(),
            m.mtime_nsec()
        ))
    }

    fn expansions(&self) -> Vec<String> {
        let mut found: Vec<String> = fs::read_dir(self.cache())
            .map(|dir| {
                dir.map(|e| e.unwrap().file_name().into_string().unwrap())
                    .filter(|n| n.starts_with("pkg-"))
                    .collect()
            })
            .unwrap_or_default();
        found.sort();
        found
    }

    fn in_session(&self, session: &ArchiveSession, folder: &str) -> Vec<EngineHit> {
        let generation = session.browse(folder.into()).unwrap();
        self.wait(generation, Duration::from_secs(60));
        session.rows(generation, 0, u32::MAX).unwrap()
    }
}

#[test]
fn flat_pkg_lists_bom_payload_packageinfo_and_toc() {
    let (comp, _, _src) = built_pkgs("pkg-flat");
    let o = Opened::named("pkg-flat", "comp.pkg", &comp);
    let rows = o.rows("");
    assert_eq!(
        sorted(rows.clone()),
        ["Bom", "PackageInfo", "Payload", "Scripts", "[TOC].xml"]
    );
    assert_eq!(row(&rows, "Payload").kind, EngineKind::Folder);
    assert_eq!(row(&rows, "Scripts").kind, EngineKind::Folder);
    for name in ["Bom", "PackageInfo", "[TOC].xml"] {
        let hit = row(&rows, name);
        assert_eq!(hit.kind, EngineKind::File, "{name}");
        assert_eq!(hit.size, o.read(name).len() as u64, "{name}");
    }
    let dump = std::process::Command::new("/usr/bin/xar")
        .args(["--dump-toc=-", "-f"])
        .arg(&o.path)
        .output()
        .unwrap();
    assert!(dump.status.success());
    assert_eq!(o.read("[TOC].xml"), dump.stdout);
    assert!(!rows.iter().any(|r| r.name.contains("provenance")));
    assert_eq!(o.summary().skipped, 0);
}

#[test]
fn product_pkg_lists_components_with_their_real_names() {
    let (_, prod, src) = built_pkgs("pkg-product");
    let o = Opened::named("pkg-product", "prod.pkg", &prod);
    let rows = o.rows("");
    assert_eq!(
        sorted(rows.clone()),
        ["Distribution", "[TOC].xml", "comp.pkg"]
    );
    assert_eq!(row(&rows, "comp.pkg").kind, EngineKind::Folder);
    let inner = o.rows("comp.pkg");
    assert_eq!(
        sorted(inner.clone()),
        ["Bom", "PackageInfo", "Payload", "Scripts"]
    );
    let listed = std::process::Command::new("/usr/bin/xar")
        .args(["-tf", "prod.pkg"])
        .current_dir(src.dir())
        .output()
        .unwrap();
    let mut expected: Vec<String> = String::from_utf8(listed.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    expected.sort();
    let mut paths: Vec<String> = o
        .source()
        .entries
        .iter()
        .map(|e| e.path.clone())
        .filter(|p| p != "[TOC].xml")
        .collect();
    paths.sort();
    assert_eq!(paths, expected);
    assert!(
        rows.iter()
            .chain(&inner)
            .all(|r| !r.name.contains('/') && !r.name.contains("Payloadcomp"))
    );
}

#[test]
fn member_reads_through_xar_with_its_bytes() {
    let (_, prod, src) = built_pkgs("pkg-member");
    let o = Opened::named("pkg-member", "prod.pkg", &prod);
    fs::create_dir_all(src.dir().join("staged")).unwrap();
    tool(
        &src.dir(),
        "/usr/bin/xar",
        &["-x", "-f", "prod.pkg", "-C", "staged"],
    );
    for name in ["Distribution", "comp.pkg/Bom", "comp.pkg/PackageInfo"] {
        assert_eq!(
            o.read(name),
            fs::read(src.dir().join("staged").join(name)).unwrap(),
            "{name}"
        );
    }
    let weird = [
        "a.b", "axb", "x[1].txt", "x1.txt", "s*t", "sst", "b\\ack", "c^d$e",
    ];
    let folder = src.dir().join("weird");
    fs::create_dir_all(&folder).unwrap();
    for name in weird {
        fs::write(folder.join(name), format!("body-{name}")).unwrap();
    }
    let mut args = vec!["-c", "-f", "../weird.pkg"];
    args.extend(weird);
    tool(&folder, "/usr/bin/xar", &args);
    let w = Opened::named(
        "pkg-member-weird",
        "weird.pkg",
        &fs::read(src.dir().join("weird.pkg")).unwrap(),
    );
    for name in weird {
        assert_eq!(w.read(name), format!("body-{name}").into_bytes(), "{name}");
    }
}

#[test]
fn members_without_a_toc_mode_extract_readable() {
    let (_, prod, _src) = built_pkgs("pkg-mode");
    let o = Opened::named("pkg-mode", "prod.pkg", &prod);
    for name in ["Distribution", "comp.pkg/PackageInfo"] {
        let job = o.extract(&[name], false);
        assert_eq!(job.problem, None, "{name}");
        let path = o.output().join(name);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o644, "{name}");
        assert!(!fs::read(&path).unwrap().is_empty(), "{name}");
    }
}

#[test]
fn entering_payload_expands_once_and_shows_the_installed_files() {
    let (comp, _, _src) = built_pkgs("pkg-enter");
    let o = Opened::named("pkg-enter", "comp.pkg", &comp);
    o.rows("");
    assert!(o.expansions().is_empty());
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
    assert_eq!(
        sorted(o.in_session(&o.session, "Payload/usr/local/probe")),
        ["file.txt", "sub"]
    );
    assert_eq!(
        names(o.in_session(&o.session, "Payload/usr/local/probe/sub")),
        ["inner.txt"]
    );
    assert_eq!(o.read("Payload/usr/local/probe/file.txt"), b"file body\n");
    assert_eq!(o.read("Payload/usr/local/probe/sub/inner.txt"), b"inner\n");
    let expansions = o.expansions();
    assert_eq!(expansions.len(), 1);
    assert!(expansions[0].starts_with(&format!("pkg-{}-", o.session.id().unwrap())));
    assert_eq!(pkgutil_runs(&o.path), 1);
}

#[test]
fn a_folder_inside_an_entered_payload_extracts_without_expanding_again() {
    let (comp, _, _src) = built_pkgs("pkg-folder-entered");
    let o = Opened::named("pkg-folder-entered", "comp.pkg", &comp);
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
    assert_eq!(pkgutil_runs(&o.path), 1);
    let job = o.extract(&["Payload/usr/local/probe"], false);
    assert_eq!(job.problem, None);
    let out = o.output();
    assert_eq!(
        fs::read(out.join("Payload/usr/local/probe/file.txt")).unwrap(),
        b"file body\n"
    );
    assert_eq!(
        fs::read(out.join("Payload/usr/local/probe/sub/inner.txt")).unwrap(),
        b"inner\n"
    );
    assert_eq!(pkgutil_runs(&o.path), 1);
    assert_eq!(o.expansions().len(), 1);
}

#[test]
fn a_payload_never_entered_extracts_with_its_installed_files() {
    let (comp, _, _src) = built_pkgs("pkg-folder-cold");
    let o = Opened::named("pkg-folder-cold", "comp.pkg", &comp);
    o.rows("");
    assert_eq!(pkgutil_runs(&o.path), 0);
    let job = o.extract(&["Payload"], false);
    assert_eq!(job.problem, None);
    assert_eq!(
        fs::read(o.output().join("Payload/usr/local/probe/sub/inner.txt")).unwrap(),
        b"inner\n"
    );
    assert_eq!(pkgutil_runs(&o.path), 1);
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
}

#[test]
fn scripts_lists_its_scripts_after_expansion() {
    let (comp, _, _src) = built_pkgs("pkg-scripts");
    let o = Opened::named("pkg-scripts", "comp.pkg", &comp);
    assert_eq!(names(o.in_session(&o.session, "Scripts")), ["postinstall"]);
    let job = o.extract(&["Scripts/postinstall"], false);
    assert_eq!(job.problem, None);
    let out = o.output().join("Scripts/postinstall");
    assert_eq!(fs::read(&out).unwrap(), POSTINSTALL);
    assert_eq!(fs::metadata(&out).unwrap().mode() & 0o777, 0o755);
}

#[test]
fn pbzx_payload_follows_p1() {
    let (_, _, src) = built_pkgs("pkg-pbzx");
    let hello = src.dir().join("pbzx-root/opt/pbzx");
    fs::create_dir_all(&hello).unwrap();
    fs::write(hello.join("hello.txt"), b"pbzx body\n").unwrap();
    let cpio = src.tar(
        "payload.cpio",
        &["-c", "--format=odc", "-C", "pbzx-root", "."],
    );
    let mut pbzx = b"pbzx".to_vec();
    pbzx.extend_from_slice(&(1u64 << 24).to_be_bytes());
    pbzx.extend_from_slice(&(cpio.len() as u64).to_be_bytes());
    pbzx.extend_from_slice(&(cpio.len() as u64).to_be_bytes());
    pbzx.extend_from_slice(&cpio);
    tool(
        &src.dir(),
        "/usr/sbin/pkgutil",
        &["--expand", "comp.pkg", "flat"],
    );
    fs::write(src.dir().join("flat/Payload"), &pbzx).unwrap();
    tool(
        &src.dir(),
        "/usr/sbin/pkgutil",
        &["--flatten", "flat", "pbzx.pkg"],
    );
    fs::create_dir_all(src.dir().join("check")).unwrap();
    tool(
        &src.dir(),
        "/usr/bin/xar",
        &["-x", "-f", "pbzx.pkg", "-C", "check", "^Payload$"],
    );
    assert!(
        fs::read(src.dir().join("check/Payload"))
            .unwrap()
            .starts_with(b"pbzx")
    );
    let o = Opened::named(
        "pkg-pbzx",
        "pbzx.pkg",
        &fs::read(src.dir().join("pbzx.pkg")).unwrap(),
    );
    assert_eq!(row(&o.rows(""), "Payload").kind, EngineKind::Folder);
    assert_eq!(
        names(o.in_session(&o.session, "Payload/opt/pbzx")),
        ["hello.txt"]
    );
    assert_eq!(o.read("Payload/opt/pbzx/hello.txt"), b"pbzx body\n");
}

const HOSTILE_TOC: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<xar>
 <toc>
  <file id="1"><name>../a</name><name>../a</name><type>file</type><data><size>1</size></data></file>
  <file id="2"><name>/abs</name><type>file</type></file>
  <file id="3">
   <name>R&amp;D.txt</name>
   <name>R&amp;D.txt</name>
   <type>file</type>
   <mode>0644</mode>
   <mtime>2026-10-27T00:03:59Z</mtime>
   <ea id="0"><name>com.apple.provenance</name><size>11</size></ea>
   <data><length>9</length><size>5</size></data>
  </file>
  <file id="4">
   <name>ok</name>
   <type>directory</type>
   <mode>0755</mode>
   <file id="5"><name>fine.txt</name><type>file</type><data><size>3</size></data></file>
  </file>
  <file id="6">
   <name>plain</name>
   <type>file</type>
   <file id="7"><name>under</name><type>file</type></file>
  </file>
 </toc>
</xar>"#;

#[test]
fn toc_parser_skips_and_counts_hostile_names() {
    let Ok((members, skipped)) = pkg::parse(HOSTILE_TOC.as_bytes()) else {
        panic!("the table of contents did not parse");
    };
    assert_eq!(skipped, 1);
    let mut summary = ArchiveSummary {
        path: String::new(),
        format: "pkg".into(),
        items: 0,
        bytes: 0,
        encrypted: false,
        skipped,
        problem: None,
        editing: ArchiveEditing::None,
    };
    let Ok(mut entries) = pkg_rows(&members, &mut summary, &|| false) else {
        panic!("the rows did not list");
    };
    assert!(finish(&mut entries, &mut summary).is_ok());
    let rows: Vec<_> = entries
        .iter()
        .map(|e| {
            (
                e.path.as_str(),
                e.attrs.kind,
                e.attrs.size,
                e.attrs.mtime,
                e.mode,
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            ("R&D.txt", EngineKind::File, 5, 1_793_059_439, 0o644),
            ("ok", EngineKind::Folder, 0, 0, 0o755),
            ("ok/fine.txt", EngineKind::File, 3, 0, 0o644),
            ("plain", EngineKind::File, 0, 0, 0o644),
        ]
    );
    assert_eq!(summary.skipped, 3);
    assert_eq!((summary.items, summary.bytes), (3, 8));
}

#[test]
fn payload_link_outside_is_skipped_and_counted() {
    let (comp, _, _src) = built_pkgs("pkg-link");
    let o = Opened::named("pkg-link", "comp.pkg", &comp);
    assert_eq!(o.summary().skipped, 0);
    assert_eq!(
        sorted(o.in_session(&o.session, "Payload/usr/local/probe")),
        ["file.txt", "sub"]
    );
    let summary = o.session.summary().unwrap();
    assert_eq!(summary.skipped, 1);
    assert_eq!(
        summary.problem,
        Some(ArchiveProblem::PointsOutside {
            name: "Payload/usr/local/probe/etclink".into()
        })
    );
    let kept = o
        .cache()
        .join(&o.expansions()[0])
        .join("Payload/usr/local/probe/etclink");
    assert_eq!(fs::read_link(kept).unwrap(), PathBuf::from("/etc"));
}

#[test]
fn a_pkg_swapped_while_xar_runs_ends_changed() {
    let (comp, prod, _src) = built_pkgs("pkg-swap");
    let o = Opened::named("pkg-swap", "comp.pkg", &comp);
    assert_eq!(o.read("Bom").len() as u64, row(&o.rows(""), "Bom").size);
    let swap = o.path.with_extension("swap");
    fs::write(&swap, &prod).unwrap();
    let path = o.path.clone();
    pkg::HOLD.lock().unwrap().push((
        o.path.clone(),
        Box::new(move || fs::rename(&swap, &path).unwrap()),
    ));
    assert_eq!(o.refused("Bom"), Some(ArchiveProblem::Changed));
    assert!(pkg::HOLD.lock().unwrap().iter().all(|(p, _)| p != &o.path));
    assert_eq!(fs::read(&o.path).unwrap(), prod);
}

#[test]
fn expand_refuses_when_free_space_is_short() {
    let (comp, _, _src) = built_pkgs("pkg-space");
    let o = Opened::named("pkg-space", "comp.pkg", &comp);
    o.session.state.lock().unwrap().space = |_| {
        Ok(write::Space {
            bytes: u64::MAX,
            volume: "Roomy".into(),
        })
    };
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
    assert_eq!(o.expansions().len(), 1);
    let info = String::from_utf8(o.read("PackageInfo")).unwrap();
    let kilobytes: u64 = info
        .split("installKBytes=\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .unwrap()
        .parse()
        .unwrap();
    assert!(kilobytes > 0);
    let short = o.open(&o.path);
    short.state.lock().unwrap().space = |_| {
        Ok(write::Space {
            bytes: 0,
            volume: "Tiny".into(),
        })
    };
    assert!(o.in_session(&short, "Payload").is_empty());
    assert_eq!(
        short.summary().unwrap().problem,
        Some(ArchiveProblem::NoSpace {
            needed: kilobytes * 1024 + write::RESERVE,
            volume: "Tiny".into()
        })
    );
    assert_eq!(o.expansions().len(), 1);
    assert_eq!(pkgutil_runs(&o.path), 1);
}

#[test]
fn bom_and_packageinfo_are_never_entered() {
    let (comp, _, _src) = built_pkgs("pkg-never");
    let o = Opened::named("pkg-never", "comp.pkg", &comp);
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
    assert_eq!(o.expansions().len(), 1);
    let other = o.open(&o.path);
    for name in ["Bom", "PackageInfo"] {
        assert!(o.in_session(&other, name).is_empty(), "{name}");
    }
    let rows = o.in_session(&other, "");
    assert_eq!(row(&rows, "Bom").kind, EngineKind::File);
    assert_eq!(row(&rows, "PackageInfo").kind, EngineKind::File);
    assert_eq!(o.expansions().len(), 1);
    assert_eq!(pkgutil_runs(&o.path), 1);
}

#[test]
fn pkg_reports_no_editing() {
    let (comp, _, _src) = built_pkgs("pkg-editing");
    let o = Opened::named("pkg-editing", "comp.pkg", &comp);
    let summary = o.summary();
    assert_eq!(summary.format, "pkg");
    assert_eq!(summary.problem, None);
    assert!(!summary.encrypted);
    let lone = Opened::named("pkg-editing-xar", "comp.xar", &comp);
    assert_eq!(lone.summary().problem, Some(ArchiveProblem::Unsupported));
}

#[test]
fn missing_mtime_and_epoch_folder_show_no_date() {
    let (_, prod, src) = built_pkgs("pkg-dates");
    let o = Opened::named("pkg-dates", "prod.pkg", &prod);
    let rows = o.rows("");
    for name in ["Distribution", "comp.pkg", "[TOC].xml"] {
        assert_eq!(row(&rows, name).modified, 0, "{name}");
    }
    let inner = o.rows("comp.pkg");
    assert_eq!(row(&inner, "PackageInfo").modified, 0);
    let built = fs::metadata(src.dir().join("prod.pkg")).unwrap().mtime();
    let bom = row(&inner, "Bom").modified;
    assert!(
        bom > 0 && (bom - built).abs() < 3600,
        "Bom {bom}, built {built}"
    );
}

#[test]
fn payload_expands_again_after_the_pkg_is_reopened() {
    let (comp, _, _src) = built_pkgs("pkg-reopen");
    let o = Opened::named("pkg-reopen", "comp.pkg", &comp);
    assert_eq!(names(o.in_session(&o.session, "Payload")), ["usr"]);
    o.session.close().unwrap();
    let again = o.open(&o.path);
    assert_eq!(names(o.in_session(&again, "Payload")), ["usr"]);
    assert_eq!(o.expansions().len(), 2);
    assert_eq!(pkgutil_runs(&o.path), 2);
}

#[test]
fn a_silent_pkg_child_stops_within_milliseconds_of_the_cancel() {
    let src = Src::new("pkg-silent");
    let path = src.dir().join("any.pkg");
    fs::write(&path, b"x").unwrap();
    let stamp = detect::Stamp::read(&File::open(&path).unwrap()).unwrap();
    let pidfile = src.dir().join("child.pid");
    let seen = std::cell::Cell::new(None::<Instant>);
    let cancelled = || {
        if seen.get().is_none() && pidfile.exists() {
            seen.set(Some(Instant::now()));
        }
        seen.get().is_some()
    };
    let result = pkg::run(
        &path,
        stamp,
        "/bin/sh",
        &[
            std::ffi::OsStr::new("-c"),
            std::ffi::OsStr::new("echo $$ > \"$0\"; exec /bin/sleep 10"),
            pidfile.as_os_str(),
        ],
        &cancelled,
    );
    let stopped = seen.get().unwrap().elapsed();
    assert!(matches!(result, Err(Failure::Stopped)));
    assert!(stopped < Duration::from_millis(200), "{stopped:?}");
    let pid: i32 = fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert_ne!(unsafe { libc::kill(pid, 0) }, 0);
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
}

impl Opened {
    fn place(&self, folder: &str) -> PathBuf {
        let path = PathBuf::from(self.tree.real()).join(folder);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn expand(&self, names: &[&str], whole: bool, folder: &std::path::Path) -> ArchiveJob {
        self.rows("");
        let id = self
            .session
            .expand(
                names.iter().map(|s| (*s).into()).collect(),
                folder.to_string_lossy().into_owned(),
                whole,
            )
            .unwrap();
        expanded_job(&self.session, id)
    }

    fn quarantined(self, value: &[u8]) -> Self {
        self.session.close().unwrap();
        write::quarantine(&File::open(&self.path).unwrap(), value).unwrap();
        let name = self.path.file_name().unwrap().to_string_lossy();
        let session = self
            .engine
            .clone()
            .open_archive(
                self.path.to_string_lossy().into_owned(),
                format!("/shown/{name}"),
            )
            .unwrap();
        Opened { session, ..self }
    }
}

fn expanded_job(session: &ArchiveSession, id: u64) -> ArchiveJob {
    let end = Instant::now() + Duration::from_secs(60);
    loop {
        let job = session.job(id).unwrap();
        if job.finished {
            return job;
        }
        assert!(Instant::now() < end, "expand did not finish");
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn listing(folder: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(folder)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

fn ustar(parts: &[Vec<u8>]) -> Vec<u8> {
    [parts.concat(), vec![0; 1024]].concat()
}

fn xattr(path: &std::path::Path, name: &std::ffi::CStr) -> Option<Vec<u8>> {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    let mut buffer = vec![0u8; 4096];
    let n = unsafe {
        libc::getxattr(
            c.as_ptr(),
            name.as_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            0,
            libc::XATTR_NOFOLLOW,
        )
    };
    (n >= 0).then(|| buffer[..n as usize].to_vec())
}

fn set_xattr(path: &std::path::Path, name: &std::ffi::CStr, value: &[u8]) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    let set = unsafe {
        libc::setxattr(
            c.as_ptr(),
            name.as_ptr(),
            value.as_ptr().cast(),
            value.len(),
            0,
            libc::XATTR_NOFOLLOW,
        )
    };
    assert_eq!(set, 0, "setxattr {}", path.display());
}

fn zipped(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    for &(name, bytes, mode) in entries {
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        if let Some(folder) = name.strip_suffix('/') {
            zip.add_directory(folder, options).unwrap();
        } else {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
    }
    zip.finish().unwrap().into_inner()
}

#[test]
fn smart_folder_rules() {
    let o = Opened::named(
        "expand-smart-one",
        "Only.zip",
        &zipped(&[("only/", b"", 0o755), ("only/a.txt", b"a", 0o644)]),
    );
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&dest), ["only"]);
    assert_eq!(job.written, [dest.join("only").to_string_lossy()]);
    assert_eq!(fs::read(dest.join("only/a.txt")).unwrap(), b"a");
    let o = Opened::named(
        "expand-smart-file",
        "Solo.zip",
        &zipped(&[("solo.txt", b"solo", 0o644)]),
    );
    let dest = o.place("dest");
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    assert_eq!(listing(&dest), ["solo.txt"]);
    let o = Opened::named(
        "expand-smart-several",
        "Several.zip",
        &zipped(&[("a.txt", b"a", 0o644), ("b/c.txt", b"c", 0o644)]),
    );
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&dest), ["Several"]);
    assert_eq!(job.written, [dest.join("Several").to_string_lossy()]);
    assert_eq!(listing(&dest.join("Several")), ["a.txt", "b"]);
    assert_eq!(fs::read(dest.join("Several/b/c.txt")).unwrap(), b"c");
    assert_eq!(
        fs::metadata(dest.join("Several")).unwrap().mode() & 0o777,
        0o755
    );
    let picked = o.place("picked");
    let job = o.expand(&["a.txt", "b"], false, &picked);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&picked), ["a.txt", "b"]);
    assert_eq!(job.written.len(), 2);
}

#[test]
fn container_name_strips_compound_suffixes_ignoring_case() {
    for (name, want) in [
        ("Photos.TAR.GZ", "Photos"),
        ("backup.tbz2", "backup"),
        ("Mixed.Tar.Xz", "Mixed"),
        ("logs.TGZ", "logs"),
        ("app.ZIP", "app"),
        ("v1.2.3.zip", "v1.2.3"),
        ("comic.cbr", "comic"),
        ("Installer.PKG", "Installer"),
        ("data.bin", "data"),
        ("plain", "plain"),
        (".zip", ".zip"),
    ] {
        assert_eq!(expand::container(name), want, "{name}");
    }
    let src = Src::new("expand-compound");
    src.put("one.txt", b"1");
    src.put("two.txt", b"2");
    let plain = src.tar(
        "b.tar",
        &[["-c"].as_slice(), &PLAIN, &["one.txt", "two.txt"]].concat(),
    );
    let o = Opened::named("expand-compound", "Bundle.TAR.GZ", &gzipped(&plain));
    let dest = o.place("dest");
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    assert_eq!(listing(&dest), ["Bundle"]);
    assert_eq!(listing(&dest.join("Bundle")), ["one.txt", "two.txt"]);
}

#[test]
fn never_overwrites_and_numbers_like_archive_utility() {
    for (name, folder, n, want) in [
        ("notes.txt", false, 2, "notes 2.txt"),
        ("notes.txt", false, 3, "notes 3.txt"),
        ("archive.tar.gz", false, 2, "archive 2.tar.gz"),
        ("README", false, 2, "README 2"),
        ("photos.2024", true, 2, "photos.2024 2"),
        ("scatter", true, 2, "scatter 2"),
        ("notes.txt", false, 1, "notes.txt"),
    ] {
        assert_eq!(expand::numbered(name, folder, n), want);
    }
    let o = Opened::named(
        "expand-numbers",
        "scatter.zip",
        &zipped(&[
            ("notes.txt", b"archived", 0o644),
            ("photos.2024/x.jpg", b"x", 0o644),
        ]),
    );
    let dest = o.place("dest");
    fs::write(dest.join("notes.txt"), b"mine").unwrap();
    fs::create_dir(dest.join("photos.2024")).unwrap();
    for _ in 0..2 {
        assert_eq!(
            o.expand(&["notes.txt", "photos.2024"], false, &dest)
                .problem,
            None
        );
    }
    assert_eq!(
        listing(&dest),
        [
            "notes 2.txt",
            "notes 3.txt",
            "notes.txt",
            "photos.2024",
            "photos.2024 2",
            "photos.2024 3"
        ]
    );
    assert_eq!(fs::read(dest.join("notes.txt")).unwrap(), b"mine");
    assert_eq!(fs::read(dest.join("notes 2.txt")).unwrap(), b"archived");
    assert!(listing(&dest.join("photos.2024")).is_empty());
    let whole = o.place("whole");
    for _ in 0..2 {
        assert_eq!(o.expand(&[], true, &whole).problem, None);
    }
    assert_eq!(listing(&whole), ["scatter", "scatter 2"]);
}

#[test]
fn dot_underscore_decoy_arrives_as_a_file() {
    let o = Opened::named(
        "expand-decoy",
        "decoy.zip",
        &zipped(&[
            ("notadouble.txt", b"real", 0o644),
            ("._notadouble.txt", b"not apple double", 0o644),
            ("._orphan.bin", b"orphan", 0o644),
        ]),
    );
    let dest = o.place("dest");
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    let inner = dest.join("decoy");
    assert_eq!(
        listing(&inner),
        ["._notadouble.txt", "._orphan.bin", "notadouble.txt"]
    );
    for (name, bytes) in [
        ("._notadouble.txt", b"not apple double".as_slice()),
        ("._orphan.bin", b"orphan"),
        ("notadouble.txt", b"real"),
    ] {
        assert!(fs::symlink_metadata(inner.join(name)).unwrap().is_file());
        assert_eq!(fs::read(inner.join(name)).unwrap(), bytes, "{name}");
    }
}

#[test]
fn files_and_xattrs_already_there_stay() {
    let o = Opened::named(
        "expand-existing",
        "existing.zip",
        &zipped(&[
            ("notes.txt", b"archived", 0o644),
            ("photos/new.jpg", b"new", 0o644),
        ]),
    );
    let dest = o.place("dest");
    fs::write(dest.join("notes.txt"), b"mine").unwrap();
    fs::create_dir(dest.join("photos")).unwrap();
    fs::write(dest.join("photos/old.jpg"), b"old").unwrap();
    for name in ["notes.txt", "photos", "photos/old.jpg"] {
        set_xattr(&dest.join(name), c"com.example.mine", b"keep");
    }
    for whole in [false, true] {
        let job = o.expand(&["notes.txt", "photos"], whole, &dest);
        assert_eq!(job.problem, None);
    }
    assert_eq!(fs::read(dest.join("notes.txt")).unwrap(), b"mine");
    assert_eq!(listing(&dest.join("photos")), ["old.jpg"]);
    assert_eq!(fs::read(dest.join("photos/old.jpg")).unwrap(), b"old");
    for name in ["notes.txt", "photos", "photos/old.jpg"] {
        assert_eq!(
            xattr(&dest.join(name), c"com.example.mine").as_deref(),
            Some(b"keep".as_slice()),
            "{name}"
        );
    }
    assert_eq!(fs::read(dest.join("notes 2.txt")).unwrap(), b"archived");
    assert_eq!(fs::read(dest.join("photos 2/new.jpg")).unwrap(), b"new");
    assert_eq!(
        listing(&dest),
        ["existing", "notes 2.txt", "notes.txt", "photos", "photos 2"]
    );
}

#[test]
fn exec_bit_kept_setuid_cleared() {
    let modes = [("suid", 0o4755), ("sticky", 0o1777), ("plain", 0o640)];
    let src = Src::new("expand-modes");
    for (name, mode) in modes {
        let path = src.put(name, name.as_bytes());
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o7777, mode, "{name}");
    }
    let tarred = src.tar(
        "m.tar",
        &[["-c"].as_slice(), &PLAIN, &["suid", "sticky", "plain"]].concat(),
    );
    let zip = zipped(&modes.map(|(name, mode)| (name, name.as_bytes(), mode)));
    for (name, bytes) in [("modes.tar", tarred), ("modes.zip", zip)] {
        let o = Opened::named(&format!("expand-modes-{name}"), name, &bytes);
        let dest = o.place("dest");
        assert_eq!(o.expand(&[], true, &dest).problem, None, "{name}");
        let inner = dest.join("modes");
        for (file, _) in modes {
            let mode = fs::metadata(inner.join(file)).unwrap().mode() & 0o7777;
            assert_eq!(mode & 0o7000, 0, "{name} {file} {mode:o}");
            assert_eq!(fs::read(inner.join(file)).unwrap(), file.as_bytes());
        }
        for file in ["suid", "sticky"] {
            let mode = fs::metadata(inner.join(file)).unwrap().mode();
            assert_ne!(mode & 0o100, 0, "{name} {file} lost its exec bit");
        }
        let plain = fs::metadata(inner.join("plain")).unwrap().mode();
        assert_eq!((plain & 0o111, plain & 0o400), (0, 0o400), "{name}");
    }
}

#[test]
fn symlink_inside_written_outside_skipped() {
    let src = Src::new("expand-links");
    src.put("target.txt", b"target");
    fs::create_dir_all(src.dir().join("dir")).unwrap();
    std::os::unix::fs::symlink("../target.txt", src.dir().join("dir/lnk")).unwrap();
    std::os::unix::fs::symlink("target.txt", src.dir().join("in")).unwrap();
    std::os::unix::fs::symlink("/etc/hosts", src.dir().join("out")).unwrap();
    std::os::unix::fs::symlink("../outside.txt", src.dir().join("up")).unwrap();
    let tarred = src.tar(
        "l.tar",
        &[
            ["-c"].as_slice(),
            &PLAIN,
            &["target.txt", "dir", "in", "out", "up"],
        ]
        .concat(),
    );
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.start_file("target.txt", SimpleFileOptions::default())
        .unwrap();
    w.write_all(b"target").unwrap();
    for (name, to) in [
        ("dir/lnk", "../target.txt"),
        ("in", "target.txt"),
        ("out", "/etc/hosts"),
        ("up", "../outside.txt"),
    ] {
        w.add_symlink(name, to, SimpleFileOptions::default())
            .unwrap();
    }
    let zip = w.finish().unwrap().into_inner();
    for (name, bytes) in [("links.tar", tarred), ("links.zip", zip)] {
        let o = Opened::named(&format!("expand-links-{name}"), name, &bytes);
        let dest = o.place("dest");
        let job = o.expand(&[], true, &dest);
        assert_eq!((job.problem, job.skipped), (None, 2), "{name}");
        let inner = dest.join("links");
        assert_eq!(listing(&inner), ["dir", "in", "target.txt"], "{name}");
        assert_eq!(
            fs::read_link(inner.join("in")).unwrap(),
            PathBuf::from("target.txt")
        );
        assert_eq!(fs::read(inner.join("dir/lnk")).unwrap(), b"target");
        let bare = o.place("bare");
        let job = o.expand(&["dir/lnk"], false, &bare);
        assert_eq!((job.problem, job.skipped), (None, 1), "{name}");
        assert!(job.written.is_empty(), "{name}");
        assert!(listing(&bare).is_empty(), "{name}");
        let kept = o.place("kept");
        let job = o.expand(&["dir"], false, &kept);
        assert_eq!((job.problem, job.skipped), (None, 0), "{name}");
        assert_eq!(
            fs::read_link(kept.join("dir/lnk")).unwrap(),
            PathBuf::from("../target.txt")
        );
    }
}

#[test]
fn hard_link_outside_skipped() {
    use tar::tests::{entry, header};
    let linked = |name: &[u8], to: &[u8]| {
        let mut h = header(name, b'1', 0);
        h[157..157 + to.len()].copy_from_slice(to);
        entry(h, b"")
    };
    let bytes = ustar(&[
        entry(header(b"ok.txt", b'0', 4), b"body"),
        linked(b"good", b"ok.txt"),
        linked(b"evil", b"/private/etc/hosts"),
        linked(b"up", b"../outside.txt"),
    ]);
    let o = Opened::named("expand-hard", "hard.tar", &bytes);
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!((job.problem, job.skipped), (None, 2));
    let inner = dest.join("hard");
    assert_eq!(listing(&inner), ["good", "ok.txt"]);
    assert_eq!(
        fs::metadata(inner.join("good")).unwrap().ino(),
        fs::metadata(inner.join("ok.txt")).unwrap().ino()
    );
    let alone = o.place("alone");
    let job = o.expand(&["good"], false, &alone);
    assert_eq!((job.problem, job.skipped), (None, 0));
    assert_eq!(listing(&alone), ["good"]);
    assert_eq!(fs::read(alone.join("good")).unwrap(), b"body");
}

#[test]
fn device_entry_skipped() {
    use tar::tests::{entry, header};
    let bytes = ustar(&[
        entry(header(b"dev0", b'3', 0), b""),
        entry(header(b"fifo0", b'6', 0), b""),
        entry(header(b"ok.txt", b'0', 2), b"ok"),
    ]);
    let o = Opened::named("expand-device", "dev.tar", &bytes);
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!((job.problem, job.skipped), (None, 2));
    assert_eq!(listing(&dest), ["ok.txt"]);
    assert_eq!(fs::read(dest.join("ok.txt")).unwrap(), b"ok");
}

#[test]
fn dates_restored_within_two_seconds_and_existing_folder_keeps_its_date() {
    let when = ::zip::DateTime::from_date_and_time(2020, 3, 4, 10, 20, 30).unwrap();
    let options = SimpleFileOptions::default().last_modified_time(when);
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    w.add_directory("folder", options).unwrap();
    w.start_file("folder/readme.md", options).unwrap();
    w.write_all(b"read me").unwrap();
    let o = Opened::named(
        "expand-dates",
        "dates.zip",
        &w.finish().unwrap().into_inner(),
    );
    let archived = row(&o.rows(""), "folder").modified;
    assert!(archived > 0);
    let dest = o.place("dest");
    fs::create_dir(dest.join("folder")).unwrap();
    let planted = 1_600_000_000;
    File::open(dest.join("folder"))
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(planted))
        .unwrap();
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    for path in ["folder 2", "folder 2/readme.md"] {
        let mtime = fs::metadata(dest.join(path)).unwrap().mtime();
        assert!((mtime - archived).abs() <= 2, "{path} {mtime} {archived}");
    }
    assert_eq!(
        fs::metadata(dest.join("folder")).unwrap().mtime(),
        planted as i64
    );
    assert!((fs::metadata(&dest).unwrap().mtime() - archived).abs() > 2);
    let src = Src::new("expand-dates-tar");
    let file = src.put("dir/file.txt", b"dated");
    dated(&file, MARCH);
    File::open(src.dir().join("dir"))
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(NEW_YEAR as u64))
        .unwrap();
    let bytes = src.tar("d.tar", &[["-c"].as_slice(), &PLAIN, &["dir"]].concat());
    let o = Opened::named("expand-dates-tar", "d.tar", &bytes);
    let dest = o.place("dest");
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    assert_eq!(
        fs::metadata(dest.join("dir/file.txt")).unwrap().mtime(),
        MARCH
    );
    assert_eq!(fs::metadata(dest.join("dir")).unwrap().mtime(), NEW_YEAR);
}

fn walked(top: &std::path::Path) -> Vec<PathBuf> {
    let mut items = vec![top.to_path_buf()];
    let mut at = 0;
    while at < items.len() {
        let item = items[at].clone();
        at += 1;
        if fs::symlink_metadata(&item).unwrap().is_dir() {
            items.extend(fs::read_dir(&item).unwrap().map(|e| e.unwrap().path()));
        }
    }
    items
}

#[test]
fn quarantine_on_every_item() {
    let value = b"0081;00000000;Wherever;expand";
    let src = Src::new("expand-quarantine");
    src.put("dir/a.txt", b"a");
    src.put("dir/sub/b.txt", b"b");
    src.put("top.txt", b"top");
    std::os::unix::fs::symlink("dir/a.txt", src.dir().join("lnk")).unwrap();
    let tarred = src.tar(
        "q.tar",
        &[["-c"].as_slice(), &PLAIN, &["dir", "top.txt", "lnk"]].concat(),
    );
    let mut w = ZipWriter::new(Cursor::new(Vec::new()));
    for (name, bytes) in [
        ("dir/a.txt", b"a".as_slice()),
        ("dir/sub/b.txt", b"b"),
        ("top.txt", b"top"),
    ] {
        w.start_file(name, SimpleFileOptions::default()).unwrap();
        w.write_all(bytes).unwrap();
    }
    w.add_symlink("lnk", "dir/a.txt", SimpleFileOptions::default())
        .unwrap();
    let zip = w.finish().unwrap().into_inner();
    for (name, bytes) in [("q.tar", tarred), ("q.zip", zip)] {
        let o =
            Opened::named(&format!("expand-quarantine-{name}"), name, &bytes).quarantined(value);
        let dest = o.place("dest");
        assert_eq!(o.expand(&[], true, &dest).problem, None, "{name}");
        let items = walked(&dest.join("q"));
        assert_eq!(items.len(), 7, "{name} {items:?}");
        for item in &items {
            assert_eq!(
                xattr(item, c"com.apple.quarantine").as_deref(),
                Some(value.as_slice()),
                "{name} {}",
                item.display()
            );
        }
    }
}

#[test]
fn cancel_leaves_nothing_in_the_destination() {
    let big = noise(256 * 1024);
    let src = Src::new("expand-cancel");
    src.put("big.bin", &big);
    src.put("small.txt", b"s");
    let tarred = src.tar(
        "c.tar",
        &[["-c"].as_slice(), &PLAIN, &["big.bin", "small.txt"]].concat(),
    );
    let zip = zipped(&[("big.bin", &big, 0o644), ("small.txt", b"s", 0o644)]);
    for (name, bytes) in [("c.zip", zip), ("c.tar", tarred)] {
        let o = Opened::named(&format!("expand-cancel-{name}"), name, &bytes);
        o.rows("");
        let dest = o.place("dest");
        let (reached, release) = o.hold();
        let id = o
            .session
            .expand(Vec::new(), dest.to_string_lossy().into_owned(), true)
            .unwrap();
        reached.recv_timeout(Duration::from_secs(10)).unwrap();
        o.session.cancel(id).unwrap();
        release.send(()).unwrap();
        let job = expanded_job(&o.session, id);
        assert_eq!(job.problem, None, "{name}");
        assert!(job.written.is_empty(), "{name}");
        assert!(listing(&dest).is_empty(), "{name}: {:?}", listing(&dest));
    }
}

#[test]
fn wrong_password_leaves_the_users_file_untouched() {
    let body = vec![7u8; 70_000];
    let o = Opened::new(
        "expand-wrong",
        &sealed(&[
            ("a.txt", b"small", crypto("right")),
            ("notes.txt", &body, crypto("other")),
        ]),
    );
    o.rows("");
    assert!(o.session.unlock("right".into()).unwrap());
    let dest = o.place("dest");
    fs::write(dest.join("notes.txt"), b"mine").unwrap();
    for whole in [false, true] {
        let job = o.expand(&["notes.txt"], whole, &dest);
        assert_eq!(job.problem, Some(ArchiveProblem::WrongPassword), "{whole}");
        assert!(job.written.is_empty());
        assert_eq!(listing(&dest), ["notes.txt"]);
        assert_eq!(fs::read(dest.join("notes.txt")).unwrap(), b"mine");
    }
}

#[test]
fn free_space_short_refuses_before_writing() {
    let o = Opened::new("expand-space", &fixture(&[("file", b"12345")]));
    o.rows("");
    let dest = o.place("dest");
    let id = o
        .session
        .expand_with_space(
            Vec::new(),
            dest.to_string_lossy().into_owned(),
            true,
            |_| {
                Ok(write::Space {
                    bytes: write::RESERVE + 2,
                    volume: "test disk".into(),
                })
            },
        )
        .unwrap();
    assert_eq!(
        expanded_job(&o.session, id).problem,
        Some(ArchiveProblem::NoSpace {
            needed: 3,
            volume: "test disk".into()
        })
    );
    assert!(listing(&dest).is_empty());
}

#[test]
fn whole_archive_expand_writes_files() {
    let src = Src::new("expand-whole");
    src.put("a/one.txt", b"one");
    src.put("two.txt", b"two");
    let tarred = src.tar(
        "w.tar",
        &[["-c"].as_slice(), &PLAIN, &["a", "two.txt"]].concat(),
    );
    for (name, bytes) in [
        (
            "whole.zip",
            fixture(&[("a/one.txt", b"one"), ("two.txt", b"two")]),
        ),
        ("whole.tar", tarred.clone()),
        ("whole.tar.gz", gzipped(&tarred)),
    ] {
        let o = Opened::named(&format!("expand-whole-{name}"), name, &bytes);
        let dest = o.place("dest");
        let job = o.expand(&[], true, &dest);
        assert_eq!((job.problem, job.skipped), (None, 0), "{name}");
        assert_eq!(job.written, [dest.join("whole").to_string_lossy()]);
        assert_eq!(fs::read(dest.join("whole/a/one.txt")).unwrap(), b"one");
        assert_eq!(fs::read(dest.join("whole/two.txt")).unwrap(), b"two");
        assert_eq!(listing(&dest.join("whole")), ["a", "two.txt"]);
    }
    let o = Opened::named("expand-whole-rar", "whole.rar", &rar5_stored());
    let dest = o.place("dest");
    assert_eq!(o.expand(&[], true, &dest).problem, None);
    let inner = dest.join("whole");
    assert_eq!(listing(&inner), ["b.txt", "dir", "hard", "lnk"]);
    assert_eq!(fs::read(inner.join("dir/a.txt")).unwrap(), b"alpha body");
    assert_eq!(fs::read(inner.join("hard")).unwrap(), b"alpha body");
    assert_eq!(fs::read(inner.join("b.txt")).unwrap(), b"beta");
    assert_eq!(
        fs::read_link(inner.join("lnk")).unwrap(),
        PathBuf::from("b.txt")
    );
    let (comp, _, _src) = built_pkgs("expand-whole-pkg");
    let o = Opened::named("expand-whole-pkg", "comp.pkg", &comp);
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!(job.problem, None);
    assert_eq!(job.skipped, 1);
    let inner = dest.join("comp");
    assert_eq!(
        listing(&inner),
        ["Bom", "PackageInfo", "Payload", "Scripts", "[TOC].xml"]
    );
    let probe = inner.join("Payload/usr/local/probe");
    assert_eq!(fs::read(probe.join("file.txt")).unwrap(), b"file body\n");
    assert_eq!(fs::read(probe.join("sub/inner.txt")).unwrap(), b"inner\n");
    assert!(!probe.join("etclink").exists());
    assert_eq!(
        fs::read(inner.join("Scripts/postinstall")).unwrap(),
        POSTINSTALL
    );
}

fn staged_for(path: &std::path::Path) -> Vec<expand::Staged> {
    expand::STAGED
        .lock()
        .unwrap()
        .iter()
        .filter(|(p, ..)| p == path)
        .cloned()
        .collect()
}

#[test]
fn selected_folder_keeps_its_subtree_and_selected_file_lands_bare() {
    let files: [(&str, &[u8]); 4] = [
        ("a/b/c.txt", b"c"),
        ("a/b/d/e.txt", b"e"),
        ("a/f.txt", b"f"),
        ("g.txt", b"g"),
    ];
    let src = Src::new("expand-selected");
    for (name, bytes) in files {
        src.put(name, bytes);
    }
    let tarred = src.tar(
        "s.tar",
        &[["-c"].as_slice(), &PLAIN, &["a", "g.txt"]].concat(),
    );
    for (name, bytes) in [("sel.zip", fixture(&files)), ("sel.tar", tarred)] {
        let o = Opened::named(&format!("expand-selected-{name}"), name, &bytes);
        let dest = o.place("dest");
        let job = o.expand(&["a/f.txt", "a/b"], false, &dest);
        assert_eq!(job.problem, None, "{name}");
        assert_eq!(listing(&dest), ["b", "f.txt"], "{name}");
        assert_eq!(listing(&dest.join("b")), ["c.txt", "d"], "{name}");
        assert_eq!(fs::read(dest.join("b/d/e.txt")).unwrap(), b"e");
        assert_eq!(fs::read(dest.join("f.txt")).unwrap(), b"f");
        assert_eq!(
            job.written,
            [
                dest.join("b").to_string_lossy(),
                dest.join("f.txt").to_string_lossy()
            ]
        );
        let again = o.place("again");
        let job = o.expand(&["a/b/c.txt", "a/b"], false, &again);
        assert_eq!(job.problem, None, "{name}");
        assert_eq!(listing(&again), ["b"], "{name}");
    }
}

#[test]
fn tar_route_never_writes_a_stripped_absolute_entry() {
    let src = Src::new("expand-absolute");
    let outside = format!("{}/abs-expand.txt", src.tree.real());
    src.put("ok.txt", b"ok");
    src.put("h0", b"bad");
    let args: Vec<String> = [
        "-c",
        "-P",
        "--no-mac-metadata",
        "--no-xattrs",
        "-s",
        &format!("|^h0$|{outside}|"),
        "ok.txt",
        "h0",
    ]
    .map(String::from)
    .to_vec();
    let o = Opened::named("expand-absolute", "a.tar", &src.tar("a.tar", &args));
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!((job.problem, job.skipped), (None, 1));
    assert_eq!(listing(&dest), ["ok.txt"]);
    assert!(!std::path::Path::new(&outside).exists());
    let staged = staged_for(&o.path);
    assert_eq!(staged.len(), 1);
    assert_eq!(staged[0].1, b"ok.txt\0");
    assert_eq!(staged[0].2, ["ok.txt"]);
}

#[test]
fn rar_expand_skips_encrypted_entries_and_counts_them() {
    let record = record5(1, &[vint(0), vint(0), vec![15], vec![7; 32]].concat());
    let bytes = rar5(&[
        file5(b"plain.txt", b"open body"),
        packed5(b"secret.txt", &[0x55; 16], 16, 0o100644, 0, &record),
    ]);
    let o = Opened::named("expand-rar-locked", "e.rar", &bytes);
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!((job.problem, job.skipped), (None, 1));
    assert_eq!(listing(&dest), ["plain.txt"]);
    assert_eq!(fs::read(dest.join("plain.txt")).unwrap(), b"open body");
    assert_eq!(staged_for(&o.path)[0].1, b"plain.txt\0");
    let picked = o.place("picked");
    let job = o.expand(&["secret.txt"], false, &picked);
    assert_eq!((job.problem, job.skipped), (None, 1));
    assert!(listing(&picked).is_empty());
}

#[test]
fn member_under_an_inside_link_counts_as_skipped_and_the_job_finishes() {
    let src = Src::new("expand-inside-link");
    fs::create_dir_all(src.dir().join("sub")).unwrap();
    std::os::unix::fs::symlink("sub", src.dir().join("in")).unwrap();
    src.put("f", b"through");
    src.put("ok.txt", b"ok");
    let bytes = src.tar(
        "i.tar",
        &[
            ["-c"].as_slice(),
            &PLAIN,
            &["-s", "|^f$|in/x.txt|", "sub", "in", "f", "ok.txt"],
        ]
        .concat(),
    );
    let o = Opened::named("expand-inside-link", "i.tar", &bytes);
    let dest = o.place("dest");
    let job = o.expand(&[], true, &dest);
    assert_eq!((job.problem, job.skipped), (None, 1));
    let inner = dest.join("i");
    assert_eq!(listing(&inner), ["in", "ok.txt", "sub"]);
    assert_eq!(
        fs::read_link(inner.join("in")).unwrap(),
        PathBuf::from("sub")
    );
    assert!(listing(&inner.join("sub")).is_empty());
    assert_eq!(fs::read(inner.join("ok.txt")).unwrap(), b"ok");
}

#[test]
fn nfc_stored_name_expands_through_bsdtars_spelling() {
    use tar::tests::{entry, header, pax};
    let nfc = "caf\u{e9}.txt";
    let bytes = ustar(&[
        pax(b'x', &[("path", nfc)]),
        entry(header(b"placeholder.txt", b'0', 8), b"nfc body"),
        entry(header(b"ok.txt", b'0', 2), b"ok"),
    ]);
    let o = Opened::named("expand-nfc", "n.tar", &bytes);
    assert!(o.source().entries.iter().any(|e| e.path == nfc));
    let dest = o.place("dest");
    let job = o.expand(&[nfc], false, &dest);
    assert_eq!((job.problem, job.skipped), (None, 0));
    assert_eq!(listing(&dest).len(), 1);
    assert_eq!(fs::read(dest.join(nfc)).unwrap(), b"nfc body");
    let staged = staged_for(&o.path);
    assert_eq!(staged.len(), 1);
    assert_ne!(staged[0].1, [nfc.as_bytes(), b"\0"].concat());
}

impl Opened {
    fn found(&self, query: &str) -> Vec<EngineHit> {
        let generation = self.session.search(query.into(), NAME).unwrap();
        self.wait(generation, Duration::from_secs(10));
        self.session.rows(generation, 0, u32::MAX).unwrap()
    }
}

fn places(rows: &[EngineHit]) -> Vec<(String, String)> {
    rows.iter()
        .map(|r| (r.folder.clone(), r.name.clone()))
        .collect()
}

#[test]
fn finds_entries_in_every_folder_in_a_stable_order_while_narrowing() {
    let o = Opened::new(
        "archive-search-narrow",
        &fixture(&[
            ("report.txt", b""),
            ("a/report old.txt", b""),
            ("a/b/reports.md", b""),
            ("a/b/other.txt", b""),
            ("notes.txt", b""),
        ]),
    );
    assert_eq!(names(o.rows("a")), ["b", "report old.txt"]);
    let wide = places(&o.found("rep"));
    assert_eq!(
        wide,
        [
            ("/shown/archive.zip/a", "report old.txt"),
            ("/shown/archive.zip", "report.txt"),
            ("/shown/archive.zip/a/b", "reports.md"),
        ]
        .map(|(f, n)| (f.to_owned(), n.to_owned()))
    );
    for text in ["repo", "report", "reports"] {
        let narrow = places(&o.found(text));
        let kept: Vec<_> = wide
            .iter()
            .filter(|p| narrow.contains(p))
            .cloned()
            .collect();
        assert_eq!(narrow, kept, "{text}");
    }
    assert_eq!(names(o.found("reports")), ["reports.md"]);
    o.found("rep");
    let descending = o
        .session
        .sort(EngineSort {
            ascending: false,
            ..NAME
        })
        .unwrap();
    o.wait(descending, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(descending, 0, u32::MAX).unwrap()),
        ["reports.md", "report.txt", "report old.txt"]
    );
}

#[test]
fn side_by_side_match_by_default() {
    let o = Opened::new(
        "archive-search-together",
        &fixture(&[
            ("hell.txt", b""),
            ("hello.txt", b""),
            ("dir/h-e-l-l-o.txt", b""),
            ("dir/HeLLo world.txt", b""),
        ]),
    );
    assert_eq!(names(o.found("hello")), ["HeLLo world.txt", "hello.txt"]);
    assert!(o.found("hlelo").is_empty());
}

#[test]
fn typo_switch_finds_typos_only_when_nothing_matches() {
    let o = Opened::new(
        "archive-search-typos",
        &fixture(&[
            ("deep/explorer.txt", b""),
            ("hello.txt", b""),
            ("hell.txt", b""),
        ]),
    );
    assert!(o.found("epxlorer").is_empty());
    o.engine.set_typos(true).unwrap();
    let rescued = o.found("epxlorer");
    assert_eq!(
        places(&rescued),
        [(
            "/shown/archive.zip/deep".to_owned(),
            "explorer.txt".to_owned()
        )]
    );
    assert!(!rescued[0].matches.is_empty());
    assert_eq!(names(o.found("hello")), ["hello.txt"]);
    o.engine.set_typos(false).unwrap();
    assert!(o.found("epxlorer").is_empty());
}

#[test]
fn accents_fold() {
    let o = Opened::new(
        "archive-search-accents",
        &fixture(&[
            ("Caf\u{e9} menu.txt", b""),
            ("sub/cafe list.txt", b""),
            ("sub/Cafe\u{301} bar.txt", b""),
            ("tea.txt", b""),
        ]),
    );
    let mut plain = names(o.found("cafe"));
    plain.sort();
    assert_eq!(
        plain,
        ["Cafe\u{301} bar.txt", "Caf\u{e9} menu.txt", "cafe list.txt"]
    );
    let mut accented = names(o.found("CAF\u{c9}"));
    accented.sort();
    assert_eq!(accented, plain);
}

#[test]
fn hidden_filter_hides_macosx_entries() {
    let o = Opened::new(
        "archive-search-hidden",
        &fixture(&[
            ("photo.jpg", b""),
            ("__MACOSX/._photo.jpg", b""),
            ("._photo2.jpg", b""),
            ("album/.photo3.jpg", b""),
            ("album/photo4.jpg", b""),
        ]),
    );
    assert_eq!(
        names(o.found("photo")),
        [
            "._photo.jpg",
            "._photo2.jpg",
            ".photo3.jpg",
            "photo.jpg",
            "photo4.jpg"
        ]
    );
    assert_eq!(
        names(o.found("hidden:no photo")),
        ["photo.jpg", "photo4.jpg"]
    );
    assert_eq!(names(o.found("hidden:no")), ["album", "photo.jpg"]);
    assert_eq!(
        names(o.found("")),
        ["__MACOSX", "album", "._photo2.jpg", "photo.jpg"]
    );
    let dotted = o
        .engine
        .clone()
        .open_archive(
            o.path.to_string_lossy().into_owned(),
            "/shown/.dot/archive.zip".into(),
        )
        .unwrap();
    let generation = dotted.search("hidden:no photo".into(), NAME).unwrap();
    o.wait(generation, Duration::from_secs(10));
    assert_eq!(
        names(dotted.rows(generation, 0, u32::MAX).unwrap()),
        ["photo.jpg", "photo4.jpg"]
    );
}

#[test]
fn empty_text_returns_to_the_folder() {
    let o = Opened::new(
        "archive-search-empty",
        &fixture(&[
            ("top note.txt", b""),
            ("sub/note.txt", b""),
            ("sub/deep/note.md", b""),
        ]),
    );
    assert_eq!(names(o.rows("sub")), ["deep", "note.txt"]);
    assert_eq!(
        names(o.found("note")),
        ["note.md", "note.txt", "top note.txt"]
    );
    assert_eq!(names(o.found("")), ["deep", "note.txt"]);
    assert_eq!(names(o.found("ext:md hidden:no")), ["deep", "note.txt"]);
    o.found("note");
    assert_eq!(names(o.rows("sub/deep")), ["note.md"]);
    assert_eq!(o.rows("sub/deep")[0].folder, "/shown/archive.zip/sub/deep");
}

#[test]
fn new_search_makes_the_old_generation_stale() {
    let o = Opened::new(
        "archive-search-stale",
        &fixture(&[("a/alpha.txt", b""), ("b/beta.txt", b"")]),
    );
    let first = o.session.search("alpha".into(), NAME).unwrap();
    o.wait(first, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(first, 0, u32::MAX).unwrap()),
        ["alpha.txt"]
    );
    let second = o.session.search("beta".into(), NAME).unwrap();
    assert!(second > first);
    o.wait(second, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(second, 0, u32::MAX).unwrap()),
        ["beta.txt"]
    );
    assert!(matches!(
        o.session.rows(first, 0, 1),
        Err(EngineError::Stale { generation }) if generation == first
    ));
    let folder = o.session.browse("a".into()).unwrap();
    o.wait(folder, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(folder, 0, u32::MAX).unwrap()),
        ["alpha.txt"]
    );
    assert!(matches!(
        o.session.rows(second, 0, 1),
        Err(EngineError::Stale { generation }) if generation == second
    ));
}

use ::zip::HasZipMetadata;

fn add(source: &std::path::Path, folder: &str, name: &str) -> ArchiveChange {
    ArchiveChange::Add {
        source: source.to_string_lossy().into_owned(),
        folder: folder.into(),
        name: name.into(),
    }
}

fn delete(path: &str) -> ArchiveChange {
    ArchiveChange::Delete { path: path.into() }
}

impl Opened {
    fn change(&self, session: &ArchiveSession, changes: Vec<ArchiveChange>) {
        let listed = session.browse(String::new()).unwrap();
        self.wait(listed, Duration::from_secs(10));
        let generation = session.set_changes(changes).unwrap();
        self.wait(generation, Duration::from_secs(10));
    }

    fn changed(&self, changes: Vec<ArchiveChange>) {
        self.change(&self.session, changes);
    }

    fn save(&self, session: &ArchiveSession, name: &str) -> (ArchiveJob, PathBuf) {
        let out = PathBuf::from(self.tree.real()).join(name);
        let id = session
            .write_edited(out.to_string_lossy().into_owned())
            .unwrap();
        (finished(session, id), out)
    }

    fn saved(&self, name: &str) -> (ArchiveJob, PathBuf) {
        self.save(&self.session, name)
    }
}

fn zip_at(path: &std::path::Path) -> ::zip::ZipArchive<File> {
    ::zip::ZipArchive::new(File::open(path).unwrap()).unwrap()
}

fn zip_names(path: &std::path::Path) -> Vec<String> {
    let zip = zip_at(path);
    (0..zip.len())
        .map(|i| zip.by_index_data(i).unwrap().name().unwrap().into_owned())
        .collect()
}

fn zip_read(path: &std::path::Path, name: &str, password: Option<&[u8]>) -> Vec<u8> {
    let mut zip = zip_at(path);
    let mut file = zip
        .by_name_with_options(name, ::zip::ZipReadOptions::new().password(password))
        .unwrap();
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).unwrap();
    bytes
}

#[derive(Debug, PartialEq)]
struct RawEntry {
    name: Vec<u8>,
    method: CompressionMethod,
    crc: u32,
    sizes: (u64, u64),
    date: Option<(u16, u16)>,
    mode: Option<u32>,
    external: u32,
    comment: String,
    data: Vec<u8>,
}

fn raw_entries(bytes: &[u8]) -> Vec<RawEntry> {
    let mut zip = ::zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    (0..zip.len())
        .map(|i| {
            let mut file = zip.by_index_raw(i).unwrap();
            let mut data = Vec::new();
            file.read_to_end(&mut data).unwrap();
            RawEntry {
                name: file.name_raw().to_vec(),
                method: file.compression(),
                crc: file.crc32(),
                sizes: (file.compressed_size(), file.size()),
                date: file.last_modified().map(|d| (d.datepart(), d.timepart())),
                mode: file.unix_mode(),
                external: file.external_attributes(),
                comment: file.comment().to_owned(),
                data,
            }
        })
        .collect()
}

fn rich() -> Vec<u8> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    zip.set_comment("the archive comment").unwrap();
    zip.add_directory("dir/", FullFileOptions::default().unix_permissions(0o750))
        .unwrap();
    zip.start_file(
        "dir/deflated.txt",
        FullFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o640)
            .with_file_comment("first comment"),
    )
    .unwrap();
    zip.write_all(&[b"deflate me ".repeat(400), noise(3000)].concat())
        .unwrap();
    zip.start_file(
        "stored.bin",
        FullFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(0o600)
            .last_modified_time(::zip::DateTime::from_date_and_time(2001, 2, 3, 4, 5, 6).unwrap()),
    )
    .unwrap();
    zip.write_all(b"stored bytes").unwrap();
    zip.start_file(
        "gone.txt",
        FullFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .unwrap();
    zip.write_all(b"to be deleted").unwrap();
    zip.finish().unwrap().into_inner()
}

#[test]
fn set_changes_hides_a_deleted_entry_and_its_subtree() {
    let o = Opened::new(
        "edit-delete",
        &fixture(&[
            ("keep.txt", b"k"),
            ("dir/a.txt", b"a"),
            ("dir/sub/b.txt", b"b"),
            ("dirx.txt", b"x"),
        ]),
    );
    assert_eq!(names(o.rows("")), ["dir", "dirx.txt", "keep.txt"]);
    assert_eq!(names(o.found("b.txt")), ["b.txt"]);
    o.changed(vec![delete("dir")]);
    assert_eq!(names(o.rows("")), ["dirx.txt", "keep.txt"]);
    assert!(o.rows("dir").is_empty());
    assert!(o.rows("dir/sub").is_empty());
    assert!(o.found("b.txt").is_empty());
    o.changed(vec![delete("dir/sub/b.txt")]);
    assert_eq!(names(o.rows("dir")), ["a.txt"]);
    assert!(o.rows("dir/sub").is_empty());
}

#[test]
fn struck_matches_inside_for_every_path_and_delete() {
    let paths = [
        "", "a", "a/", "a//x", "a/b", "a/b/", "a/b/c", "a/bc", "a/b c", "ab", "/a", "/", "a/b/c/d",
    ];
    for top in paths {
        let gone: std::collections::HashSet<&str> = [top].into_iter().collect();
        for path in paths {
            assert_eq!(
                edit::struck(&gone, path),
                expand::inside(path, top),
                "{path:?} under {top:?}"
            );
        }
    }
}

#[test]
fn set_changes_hides_a_folder_and_a_file_inside_it_both_deleted() {
    let o = Opened::new(
        "edit-delete-nested",
        &fixture(&[
            ("keep.txt", b"k"),
            ("dir/a.txt", b"a"),
            ("dir/sub/b.txt", b"b"),
        ]),
    );
    o.changed(vec![delete("dir/sub/b.txt"), delete("dir")]);
    assert_eq!(names(o.rows("")), ["keep.txt"]);
    assert!(o.rows("dir").is_empty());
    assert!(o.rows("dir/sub").is_empty());
}

#[test]
fn set_changes_deleting_a_name_keeps_names_that_share_its_prefix() {
    let o = Opened::new(
        "edit-delete-prefix",
        &fixture(&[
            ("a/b", b"1"),
            ("a/bc", b"2"),
            ("a/b c", b"3"),
            ("a/b.txt", b"4"),
        ]),
    );
    o.changed(vec![delete("a/b")]);
    assert_eq!(sorted(o.rows("a")), ["b c", "b.txt", "bc"]);
}

#[test]
fn set_changes_deleting_a_root_name_keeps_its_siblings() {
    let o = Opened::new(
        "edit-delete-root",
        &fixture(&[("t/x", b"1"), ("top.txt", b"2"), ("top.txt.bak", b"3")]),
    );
    o.changed(vec![delete("top.txt")]);
    assert_eq!(sorted(o.rows("")), ["t", "top.txt.bak"]);
}

#[test]
fn set_changes_deleting_inside_an_added_folder_drops_only_the_archive_copy() {
    let o = Opened::new(
        "edit-delete-added-folder",
        &fixture(&[("docs/a.txt", b"a"), ("docs/keep.txt", b"k")]),
    );
    let src = Src::new("edit-delete-added-folder");
    src.put("docs/b.txt", b"b");
    let folder = src.dir().join("docs");
    o.changed(vec![
        add(&folder, "", "docs"),
        delete("docs/a.txt"),
        delete("docs/b.txt"),
    ]);
    let rows = names(o.rows("docs"));
    assert!(rows.contains(&"b.txt".to_owned()), "{rows:?}");
    assert!(rows.contains(&"keep.txt".to_owned()), "{rows:?}");
    assert!(!rows.contains(&"a.txt".to_owned()), "{rows:?}");
}

#[test]
fn set_changes_lists_an_added_file_with_its_disk_size_and_date() {
    let o = Opened::new("edit-add-listed", &fixture(&[("old.txt", b"old")]));
    let src = Src::new("edit-add-listed");
    let path = src.put("new.txt", b"fresh");
    dated(&path, MARCH);
    o.changed(vec![add(&path, "", "new.txt")]);
    let rows = o.rows("");
    assert_eq!(names(rows.clone()), ["new.txt", "old.txt"]);
    let added = row(&rows, "new.txt");
    assert_eq!(
        (added.size, added.modified, added.kind),
        (5, MARCH, EngineKind::File)
    );
    assert_eq!(added.folder, "/shown/archive.zip");
}

#[test]
fn set_changes_replaces_the_whole_list_so_the_previous_list_undoes() {
    let o = Opened::new("edit-undo", &fixture(&[("a.txt", b"a"), ("b.txt", b"b")]));
    let src = Src::new("edit-undo");
    let path = src.put("new.txt", b"new");
    o.changed(vec![delete("a.txt")]);
    assert_eq!(names(o.rows("")), ["b.txt"]);
    o.changed(Vec::new());
    assert_eq!(names(o.rows("")), ["a.txt", "b.txt"]);
    o.changed(vec![add(&path, "", "new.txt")]);
    assert_eq!(names(o.rows("")), ["a.txt", "b.txt", "new.txt"]);
    let (job, out) = o.saved("undo.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["a.txt", "b.txt", "new.txt"]);
}

fn stalled(disk: &std::path::Path) {
    let end = Instant::now() + Duration::from_secs(10);
    while !edit::STALL
        .lock()
        .unwrap()
        .iter()
        .any(|(p, reached)| p == disk && *reached)
    {
        assert!(Instant::now() < end, "the walk never reached {disk:?}");
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn released(disk: &std::path::Path) {
    edit::STALL.lock().unwrap().retain(|(p, _)| p != disk);
}

fn stalled_add(label: &str) -> (Opened, Src, PathBuf) {
    let o = Opened::new(label, &fixture(&[("old.txt", b"old")]));
    let src = Src::new(label);
    src.put("big/a.txt", b"a");
    let big = src.dir().join("big");
    edit::STALL.lock().unwrap().push((big.clone(), false));
    o.rows("");
    o.session.set_changes(vec![add(&big, "", "big")]).unwrap();
    stalled(&big);
    (o, src, big)
}

#[test]
fn stop_during_an_add_walk_interrupts_it_and_the_newest_list_shows() {
    let (o, _src, big) = stalled_add("edit-stop-add");
    o.session.set_changes(Vec::new()).unwrap();
    let generation = o.session.search(String::new(), NAME).unwrap();
    o.wait(generation, Duration::from_secs(2));
    assert_eq!(
        names(o.session.rows(generation, 0, u32::MAX).unwrap()),
        ["old.txt"]
    );
    assert!(edit::STALL.lock().unwrap().iter().any(|(p, _)| *p == big));
    released(&big);
}

#[test]
fn a_browse_during_an_add_walk_keeps_the_add() {
    let (o, _src, big) = stalled_add("edit-browse-add");
    let generation = o.session.browse(String::new()).unwrap();
    std::thread::sleep(Duration::from_millis(50));
    released(&big);
    o.wait(generation, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(generation, 0, u32::MAX).unwrap()),
        ["big", "old.txt"]
    );
}

#[test]
fn a_newer_edit_during_an_add_walk_restarts_it_with_the_newest_list() {
    let (o, _src, big) = stalled_add("edit-newer-add");
    let generation = o
        .session
        .set_changes(vec![add(&big, "", "big"), delete("old.txt")])
        .unwrap();
    std::thread::sleep(Duration::from_millis(50));
    released(&big);
    o.wait(generation, Duration::from_secs(10));
    assert_eq!(
        names(o.session.rows(generation, 0, u32::MAX).unwrap()),
        ["big"]
    );
}

#[test]
fn replace_lists_the_name_once() {
    let o = Opened::new("edit-replace-list", &fixture(&[("note.txt", b"old")]));
    let src = Src::new("edit-replace-list");
    let path = src.put("note.txt", b"new bytes");
    o.changed(vec![delete("note.txt"), add(&path, "", "note.txt")]);
    let rows = o.rows("");
    assert_eq!(names(rows.clone()), ["note.txt"]);
    assert_eq!(rows[0].size, 9);
}

#[test]
fn clashes_ignore_case_and_normalization_and_give_the_free_name() {
    let o = Opened::new(
        "edit-clashes",
        &fixture(&[
            ("Café.txt", b"c"),
            ("photos.2024/x.jpg", b"x"),
            ("notes.txt", b"n"),
            ("notes 2.txt", b"n2"),
        ]),
    );
    o.rows("");
    let clashes = o
        .session
        .clashes(
            String::new(),
            vec![
                "CAFE\u{301}.TXT".into(),
                "photos.2024".into(),
                "notes.txt".into(),
                "fresh.txt".into(),
            ],
        )
        .unwrap();
    assert_eq!(
        clashes,
        [
            ArchiveClash {
                name: "CAFE\u{301}.TXT".into(),
                existing: "Café.txt".into(),
                folder: false,
                free_name: "CAFE\u{301} 2.TXT".into(),
            },
            ArchiveClash {
                name: "photos.2024".into(),
                existing: "photos.2024".into(),
                folder: true,
                free_name: "photos.2024 2".into(),
            },
            ArchiveClash {
                name: "notes.txt".into(),
                existing: "notes.txt".into(),
                folder: false,
                free_name: "notes 3.txt".into(),
            },
        ]
    );
    let inner = o
        .session
        .clashes("photos.2024".into(), vec!["X.JPG".into(), "y.jpg".into()])
        .unwrap();
    assert_eq!(inner.len(), 1);
    assert_eq!(
        (inner[0].existing.as_str(), inner[0].free_name.as_str()),
        ("photos.2024/x.jpg", "X 2.JPG")
    );
    let src = Src::new("edit-clashes");
    let path = src.put("added.txt", b"a");
    o.changed(vec![add(&path, "", "added.txt"), delete("notes.txt")]);
    let edited = o
        .session
        .clashes(String::new(), vec!["ADDED.txt".into(), "notes.txt".into()])
        .unwrap();
    assert_eq!(edited.len(), 1);
    assert_eq!(edited[0].existing, "added.txt");
}

#[test]
fn clashes_count_a_name_dropped_twice_once_per_later_copy() {
    let o = Opened::new(
        "edit-clash-drop",
        &fixture(&[("docs/n.txt", b"n"), ("README 2.md", b"r")]),
    );
    o.rows("");
    let clashes = o
        .session
        .clashes(
            String::new(),
            vec![
                "README.md".into(),
                "fresh.txt".into(),
                "readme.MD".into(),
                "README.md".into(),
            ],
        )
        .unwrap();
    assert_eq!(
        clashes,
        [
            ArchiveClash {
                name: "readme.MD".into(),
                existing: "README.md".into(),
                folder: false,
                free_name: "readme 3.MD".into(),
            },
            ArchiveClash {
                name: "README.md".into(),
                existing: "README.md".into(),
                folder: false,
                free_name: "README 4.md".into(),
            },
        ]
    );
    let inner = o
        .session
        .clashes("docs".into(), vec!["m.txt".into(), "M.TXT".into()])
        .unwrap();
    assert_eq!(
        inner,
        [ArchiveClash {
            name: "M.TXT".into(),
            existing: "docs/m.txt".into(),
            folder: false,
            free_name: "M 2.TXT".into(),
        }]
    );
}

#[test]
fn a_name_dropped_twice_beside_an_archive_item_clashes_with_the_item_each_time() {
    let o = Opened::new("edit-clash-both", &fixture(&[("docs/n.txt", b"n")]));
    o.rows("");
    let clashes = o
        .session
        .clashes(String::new(), vec!["DOCS".into(), "docs".into()])
        .unwrap();
    assert_eq!(
        clashes
            .iter()
            .map(|c| (c.existing.as_str(), c.folder, c.free_name.as_str()))
            .collect::<Vec<_>>(),
        [("docs", true, "DOCS 2"), ("docs", true, "docs 3")]
    );
}

#[test]
fn extract_of_an_added_entry_copies_its_source_file() {
    let value = b"0081;5f000000;Safari;";
    let o = Opened::new("edit-extract-added", &fixture(&[("old.txt", b"old")])).quarantined(value);
    let src = Src::new("edit-extract-added");
    let body = noise(70_000);
    let path = src.put("added.bin", &body);
    o.changed(vec![add(&path, "", "added.bin")]);
    let job = o.extract(&["old.txt"], false);
    assert_eq!(job.problem, None);
    let old = File::open(o.output().join("old.txt")).unwrap();
    assert_eq!(write::read_quarantine(&old).unwrap(), value);
    let job = o.extract(&["added.bin"], false);
    assert_eq!((job.problem, job.done_items), (None, 1));
    let copied = o.output().join("added.bin");
    assert_eq!(fs::read(&copied).unwrap(), body);
    assert!(
        write::read_quarantine(&File::open(&copied).unwrap())
            .unwrap()
            .is_empty()
    );
}

#[test]
fn extract_of_a_folder_writes_its_subtree_with_pending_edits() {
    let o = Opened::new(
        "folder-subtree",
        &fixture(&[
            ("docs/old.txt", b"old"),
            ("docs/keep.txt", b"keep"),
            ("docs/sub/deep.txt", b"deep"),
            ("docs2/other.txt", b"other"),
        ]),
    );
    let src = Src::new("folder-subtree");
    let notes = src.put("notes.txt", b"added notes");
    o.changed(vec![
        add(&notes, "docs", "notes.txt"),
        delete("docs/old.txt"),
    ]);
    let job = o.extract(&["docs"], false);
    assert_eq!(job.problem, None);
    assert_eq!((job.done_items, job.total_items), (5, 5));
    let out = o.output();
    assert_eq!(
        fs::read(out.join("docs/notes.txt")).unwrap(),
        b"added notes"
    );
    assert_eq!(fs::read(out.join("docs/keep.txt")).unwrap(), b"keep");
    assert_eq!(fs::read(out.join("docs/sub/deep.txt")).unwrap(), b"deep");
    assert!(!out.join("docs/old.txt").exists());
    assert!(!out.join("docs2").exists());
}

#[test]
fn a_folder_sent_with_its_own_children_writes_each_item_once() {
    let o = Opened::new(
        "folder-and-children",
        &fixture(&[("docs/keep.txt", b"keep"), ("docs/sub/deep.txt", b"deep")]),
    );
    let src = Src::new("folder-and-children");
    let notes = src.put("notes.txt", b"added notes");
    o.changed(vec![add(&notes, "docs/sub", "notes.txt")]);
    let job = o.extract(
        &["docs/sub/deep.txt", "docs", "docs/keep.txt", "docs/sub"],
        false,
    );
    assert_eq!(job.problem, None);
    assert_eq!((job.done_items, job.total_items), (5, 5));
    assert_eq!(job.written.len(), 5);
    assert_eq!(
        fs::read(o.output().join("docs/sub/notes.txt")).unwrap(),
        b"added notes"
    );
}

#[test]
fn an_added_folder_extracts_with_everything_inside_it() {
    let o = Opened::new("added-folder-out", &fixture(&[("old.txt", b"old")]));
    let src = Src::new("added-folder-out");
    src.put("pics/a.jpg", b"a");
    src.put("pics/inner/b.jpg", b"b");
    o.changed(vec![add(&src.dir().join("pics"), "", "pics")]);
    let job = o.extract(&["pics"], false);
    assert_eq!(job.problem, None);
    assert_eq!((job.done_items, job.total_items), (4, 4));
    assert_eq!(fs::read(o.output().join("pics/inner/b.jpg")).unwrap(), b"b");
}

#[test]
fn zip_delete_writes_a_copy_without_the_entry_and_every_other_entry_byte_identical() {
    let bytes = rich();
    let o = Opened::new("edit-zip-delete", &bytes);
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("deleted.zip");
    assert_eq!(job.problem, None);
    assert_eq!(job.written, [out.to_string_lossy().into_owned()]);
    let before: Vec<RawEntry> = raw_entries(&bytes)
        .into_iter()
        .filter(|e| e.name != b"gone.txt")
        .collect();
    assert_eq!(before.len(), 3);
    assert_eq!(raw_entries(&fs::read(&out).unwrap()), before);
    assert_eq!(fs::read(&o.path).unwrap(), bytes);
}

#[test]
fn zip_rewrite_keeps_the_archive_comment() {
    let o = Opened::new("edit-zip-comment", &rich());
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("comment.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_at(&out).comment(), b"the archive comment");
    let src = Src::new("edit-zip-comment");
    let path = src.put("new.txt", b"new");
    o.changed(vec![add(&path, "", "new.txt")]);
    let (job, out) = o.saved("comment-add.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_at(&out).comment(), b"the archive comment");
}

#[test]
fn info_zip_archive_with_0x7875_rewrites() {
    let src = Src::new("edit-info-zip");
    src.put("a.txt", b"alpha");
    src.put("dir/b.txt", b"beta body");
    tool(
        &src.dir(),
        "/usr/bin/zip",
        &["-qry", "info.zip", "a.txt", "dir"],
    );
    let bytes = fs::read(src.dir().join("info.zip")).unwrap();
    let mut source = ::zip::ZipArchive::new(Cursor::new(bytes.as_slice())).unwrap();
    assert!(source.by_index_raw(0).unwrap().extra_data_fields().count() > 0);
    let mut probe = ZipWriter::new(Cursor::new(Vec::new()));
    assert!(
        probe
            .raw_copy_file(source.by_index_raw(0).unwrap())
            .is_err()
    );
    let o = Opened::new("edit-info-zip", &bytes);
    o.changed(vec![delete("a.txt")]);
    let (job, out) = o.saved("info-edited.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["dir/", "dir/b.txt"]);
    assert_eq!(zip_read(&out, "dir/b.txt", None), b"beta body");
}

#[test]
fn add_only_list_rewrites_and_keeps_every_old_entry_byte_identical() {
    let bytes = rich();
    let o = Opened::new("edit-add-only", &bytes);
    let src = Src::new("edit-add-only");
    let path = src.put("new.txt", b"brand new");
    o.changed(vec![add(&path, "dir", "new.txt")]);
    let (job, out) = o.saved("added.zip");
    assert_eq!(job.problem, None);
    let written = fs::read(&out).unwrap();
    let old = raw_entries(&bytes);
    let new = raw_entries(&written);
    assert_eq!(new.len(), old.len() + 1);
    assert_eq!(new[..old.len()], old[..]);
    assert_eq!(new[old.len()].name, b"dir/new.txt");
    assert_eq!(headers(&written, b"PK\x01\x02").len(), old.len() + 1);
    assert_eq!(headers(&written, b"PK\x05\x06").len(), 1);
    assert_eq!(zip_at(&out).comment(), b"the archive comment");
    assert_eq!(zip_read(&out, "dir/new.txt", None), b"brand new");
}

#[test]
fn empty_list_copies_the_archive_byte_for_byte() {
    let plain = rich();
    let o = Opened::new("edit-empty-plain", &plain);
    assert_eq!(o.summary().editing, ArchiveEditing::All);
    let (job, out) = o.saved("copy.zip");
    assert_eq!(job.problem, None);
    assert_eq!(fs::read(&out).unwrap(), plain);
    let locked = sealed(&[
        ("a.txt", b"alpha secret", crypto("pw")),
        ("b.txt", b"beta secret", crypto("pw")),
    ]);
    let o = Opened::new("edit-empty-crypto", &locked);
    assert_eq!(o.summary().editing, ArchiveEditing::OldEncryption);
    o.changed(vec![delete("a.txt")]);
    o.changed(Vec::new());
    let (job, out) = o.saved("copy-locked.zip");
    assert_eq!(job.problem, None);
    assert_eq!(fs::read(&out).unwrap(), locked);
    assert_eq!(
        zip_read(&out, "a.txt", Some(b"pw".as_slice())),
        b"alpha secret"
    );
    assert_eq!(
        zip_read(&out, "b.txt", Some(b"pw".as_slice())),
        b"beta secret"
    );
}

#[test]
fn new_entries_keep_mode_local_date_folders_and_symlinks() {
    let o = Opened::new("edit-new-entries", &fixture(&[("old.txt", b"old")]));
    let src = Src::new("edit-new-entries");
    let run = src.put("pack/run.sh", b"#!/bin/sh\n");
    fs::set_permissions(&run, fs::Permissions::from_mode(0o750)).unwrap();
    dated(&run, MARCH);
    dated(&src.put("pack/old.txt", b"o"), 0);
    dated(&src.put("pack/future.txt", b"f"), 7_258_118_400);
    let inner = src.dir().join("pack/inner");
    fs::create_dir_all(&inner).unwrap();
    fs::set_permissions(&inner, fs::Permissions::from_mode(0o700)).unwrap();
    std::os::unix::fs::symlink("run.sh", src.dir().join("pack/link")).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", src.dir().join("pack/escape")).unwrap();
    o.changed(vec![add(&src.dir().join("pack"), "", "pack")]);
    assert_eq!(
        sorted(o.rows("pack")),
        ["future.txt", "inner", "link", "old.txt", "run.sh"]
    );
    let (job, out) = o.saved("new-entries.zip");
    assert_eq!(job.problem, None);
    assert_eq!(
        zip_names(&out),
        [
            "old.txt",
            "pack/",
            "pack/future.txt",
            "pack/inner/",
            "pack/link",
            "pack/old.txt",
            "pack/run.sh"
        ]
    );
    let mut zip = zip_at(&out);
    let mode = |zip: &mut ::zip::ZipArchive<File>, name: &str| {
        zip.by_name(name).unwrap().unix_mode().unwrap()
    };
    let pack = fs::metadata(src.dir().join("pack")).unwrap().mode();
    assert_eq!(mode(&mut zip, "pack/") & 0o777, pack & 0o777);
    assert_eq!(mode(&mut zip, "pack/inner/") & 0o777, 0o700);
    assert_eq!(mode(&mut zip, "pack/run.sh") & 0o777, 0o750);
    assert_eq!(
        mode(&mut zip, "pack/link") & libc::S_IFMT as u32,
        libc::S_IFLNK as u32
    );
    let date = |zip: &mut ::zip::ZipArchive<File>, name: &str| {
        let d = zip.by_name(name).unwrap().last_modified().unwrap();
        (
            i32::from(d.year()),
            i32::from(d.month()),
            i32::from(d.day()),
            i32::from(d.hour()),
            i32::from(d.minute()),
            i32::from(d.second()),
        )
    };
    let (y, m, d, h, mi, s) = local(MARCH);
    assert_eq!(date(&mut zip, "pack/run.sh"), (y, m, d, h, mi, s - s % 2));
    assert_eq!(date(&mut zip, "pack/old.txt"), (1980, 1, 1, 0, 0, 0));
    assert_eq!(
        date(&mut zip, "pack/future.txt"),
        (2107, 12, 31, 23, 59, 58)
    );
    assert_eq!(zip_read(&out, "pack/link", None), b"run.sh");
    assert_eq!(zip_read(&out, "pack/run.sh", None), b"#!/bin/sh\n");
}

#[test]
fn large_file_flag_follows_the_source_size() {
    let at = |size: u64| super::zip::options(size, 0o644, MARCH);
    assert_eq!(at(4 << 30), at(4 << 30).large_file(true));
    assert_eq!(
        at(::zip::ZIP64_BYTES_THR),
        at(::zip::ZIP64_BYTES_THR).large_file(true)
    );
    assert_eq!(
        at(::zip::ZIP64_BYTES_THR - 1),
        at(::zip::ZIP64_BYTES_THR - 1).large_file(false)
    );
    assert_eq!(at(10), at(10).large_file(false));
    assert_ne!(at(10), at(4 << 30));
}

#[test]
fn added_names_never_hold_dotdot_or_a_leading_slash() {
    let o = Opened::new("edit-names", &fixture(&[("dir/old.txt", b"old")]));
    let src = Src::new("edit-names");
    let path = src.put("safe.txt", b"safe");
    o.changed(vec![add(&path, "dir", "safe.txt")]);
    let (job, out) = o.saved("names.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["dir/old.txt", "dir/safe.txt"]);
    let refused = [
        add(&path, "", ".."),
        add(&path, "", "."),
        add(&path, "", ""),
        add(&path, "", "../up.txt"),
        add(&path, "", "/root.txt"),
        add(&path, "", "a/b.txt"),
        add(&path, "../up", "x.txt"),
        add(&path, "/abs", "x.txt"),
        add(&path, "dir/../..", "x.txt"),
        add(std::path::Path::new("relative/safe.txt"), "", "x.txt"),
        delete("../dir"),
        delete("/dir"),
    ];
    for change in refused {
        assert!(
            matches!(
                o.session.set_changes(vec![change.clone()]),
                Err(EngineError::Io { .. })
            ),
            "{change:?} was taken"
        );
    }
    assert_eq!(names(o.rows("dir")), ["old.txt", "safe.txt"]);
    let (job, out) = o.saved("names-again.zip");
    assert_eq!(job.problem, None);
    for name in zip_names(&out) {
        assert!(!name.starts_with('/') && !name.split('/').any(|p| p == ".."));
    }
    assert_eq!(zip_names(&out), ["dir/old.txt", "dir/safe.txt"]);
}

fn crypto_pair() -> (Vec<u8>, Vec<u8>) {
    (
        sealed(&[("a.txt", b"alpha", stored()), ("b.txt", b"beta", stored())]),
        sealed(&[
            ("a.txt", b"alpha", crypto("pw")),
            ("b.txt", b"beta", crypto("pw")),
        ]),
    )
}

#[test]
fn zipcrypto_zip_refuses_delete_with_old_encryption_and_writes_nothing() {
    let (plain, locked) = crypto_pair();
    let twin = Opened::new("edit-crypto-delete-twin", &plain);
    twin.changed(vec![delete("a.txt")]);
    let (job, out) = twin.saved("twin.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["b.txt"]);
    let o = Opened::new("edit-crypto-delete", &locked);
    assert_eq!(o.summary().editing, ArchiveEditing::OldEncryption);
    o.changed(vec![delete("a.txt")]);
    let (job, out) = o.saved("refused.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::OldEncryption));
    assert!(!out.exists());
    assert!(o.session.unlock("pw".into()).unwrap());
    let (job, out) = o.saved("refused-unlocked.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::OldEncryption));
    assert!(!out.exists());
    assert_eq!(fs::read(&o.path).unwrap(), locked);
}

#[test]
fn zipcrypto_zip_with_a_pending_add_ends_old_encryption_and_writes_nothing() {
    let (plain, locked) = crypto_pair();
    let src = Src::new("edit-crypto-add");
    let path = src.put("new.txt", b"new");
    let twin = Opened::new("edit-crypto-add-twin", &plain);
    twin.changed(vec![add(&path, "", "new.txt")]);
    let (job, out) = twin.saved("twin.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["a.txt", "b.txt", "new.txt"]);
    let o = Opened::new("edit-crypto-add", &locked);
    o.changed(vec![add(&path, "", "new.txt")]);
    assert_eq!(names(o.rows("")), ["a.txt", "b.txt", "new.txt"]);
    let (job, out) = o.saved("refused.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::OldEncryption));
    assert!(!out.exists());
    assert!(o.session.unlock("pw".into()).unwrap());
    let (job, out) = o.saved("refused-unlocked.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::OldEncryption));
    assert!(!out.exists());
}

fn aes(password: &str) -> FileOptions<'_, 'static, ()> {
    stored().with_aes_encryption(AesMode::Aes256, password)
}

#[test]
fn aes_zip_delete_keeps_aes_entries_readable_and_new_entries_are_aes() {
    let locked = sealed(&[
        ("keep.txt", b"keep body", aes("pw")),
        ("gone.txt", b"gone body", aes("pw")),
    ]);
    let o = Opened::new("edit-aes", &locked);
    assert_eq!(o.summary().editing, ArchiveEditing::All);
    assert!(o.session.unlock("pw".into()).unwrap());
    let src = Src::new("edit-aes");
    let path = src.put("new.txt", b"new secret");
    o.changed(vec![delete("gone.txt"), add(&path, "", "new.txt")]);
    let (job, out) = o.saved("aes.zip");
    assert_eq!(job.problem, None);
    assert_eq!(zip_names(&out), ["keep.txt", "new.txt"]);
    let before = raw_entries(&locked);
    assert_eq!(raw_entries(&fs::read(&out).unwrap())[0], before[0]);
    let mut zip = zip_at(&out);
    for name in ["keep.txt", "new.txt"] {
        let file = zip.by_index_raw(zip.index_for_name(name).unwrap()).unwrap();
        assert!(file.encrypted(), "{name}");
        assert_eq!(
            file.get_metadata().aes_settings().map(|(mode, _)| mode),
            Some(AesMode::Aes256),
            "{name}"
        );
    }
    assert!(zip.by_name("new.txt").is_err());
    assert_eq!(
        zip_read(&out, "keep.txt", Some(b"pw".as_slice())),
        b"keep body"
    );
    assert_eq!(
        zip_read(&out, "new.txt", Some(b"pw".as_slice())),
        b"new secret"
    );
}

#[test]
fn add_to_an_encrypted_zip_without_a_password_ends_password_needed() {
    let locked = sealed(&[("keep.txt", b"keep body", aes("pw"))]);
    let o = Opened::new("edit-aes-password", &locked);
    let src = Src::new("edit-aes-password");
    let path = src.put("new.txt", b"new secret");
    assert!(o.session.unlock("pw".into()).unwrap());
    o.changed(vec![add(&path, "", "new.txt")]);
    let (job, out) = o.saved("twin.zip");
    assert_eq!(job.problem, None);
    assert_eq!(
        zip_read(&out, "new.txt", Some(b"pw".as_slice())),
        b"new secret"
    );
    let bare = o.open(&o.path);
    o.change(&bare, vec![delete("keep.txt")]);
    let (job, out) = o.save(&bare, "delete-only.zip");
    assert_eq!(job.problem, None);
    assert!(zip_names(&out).is_empty());
    o.change(&bare, vec![add(&path, "", "new.txt")]);
    let (job, out) = o.save(&bare, "refused.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::PasswordNeeded));
    assert!(!out.exists());
}

#[test]
fn changed_archive_ends_changed_before_writing() {
    let o = Opened::new("edit-changed", &rich());
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("twin.zip");
    assert_eq!(job.problem, None);
    assert!(out.exists());
    dated(&o.path, NEW_YEAR);
    let (job, out) = o.saved("refused.zip");
    assert_eq!(job.problem, Some(ArchiveProblem::Changed));
    assert!(!out.exists());
    fs::remove_file(&o.path).unwrap();
    let (job, out) = o.saved("gone.zip");
    assert!(matches!(job.problem, Some(ArchiveProblem::Gone { .. })));
    assert!(!out.exists());
}

#[test]
fn out_equal_to_the_archive_or_existing_is_refused() {
    let bytes = rich();
    let o = Opened::new("edit-out", &bytes);
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("free.zip");
    assert_eq!(job.problem, None);
    let taken = PathBuf::from(o.tree.real()).join("taken.zip");
    fs::write(&taken, b"keep me").unwrap();
    for path in [
        o.path.clone(),
        o.linked("archive.zip"),
        out.clone(),
        taken.clone(),
        PathBuf::from("relative.zip"),
    ] {
        assert!(
            matches!(
                o.session.write_edited(path.to_string_lossy().into_owned()),
                Err(EngineError::Io { .. })
            ),
            "{path:?} was taken"
        );
    }
    assert_eq!(fs::read(&o.path).unwrap(), bytes);
    assert_eq!(fs::read(&taken).unwrap(), b"keep me");
    assert_eq!(zip_names(&out), ["dir/", "dir/deflated.txt", "stored.bin"]);
}

#[test]
fn cancel_deletes_the_partial_copy() {
    let o = Opened::new(
        "edit-cancel",
        &fixture(&[
            ("one.bin", &noise(200_000)),
            ("two.bin", &noise(200_001)),
            ("three.bin", &noise(200_002)),
            ("gone.bin", b"gone"),
        ]),
    );
    o.changed(vec![delete("gone.bin")]);
    let out = PathBuf::from(o.tree.real()).join("cancelled.zip");
    let (reached, release) = o.hold();
    let id = o
        .session
        .write_edited(out.to_string_lossy().into_owned())
        .unwrap();
    reached.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(fs::metadata(&out).unwrap().len() > 200_000);
    o.session.cancel(id).unwrap();
    release.send(()).unwrap();
    let job = finished(&o.session, id);
    assert!(job.written.is_empty());
    assert!(!out.exists());
}

fn listed_by_bsdtar(bytes: &[u8]) -> Vec<String> {
    let mut child = std::process::Command::new("/usr/bin/tar")
        .args(["-tf", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let bytes = bytes.to_vec();
    let feeder = std::thread::spawn(move || input.write_all(&bytes).unwrap());
    let out = child.wait_with_output().unwrap();
    feeder.join().unwrap();
    assert!(out.status.success());
    let mut names: Vec<String> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    names.sort();
    names
}

fn expanded_by_ditto(zip: &std::path::Path, into: &std::path::Path) -> Vec<String> {
    tool(
        into.parent().unwrap(),
        "/usr/bin/ditto",
        &["-x", "-k", &zip.to_string_lossy(), &into.to_string_lossy()],
    );
    let mut found = Vec::new();
    let mut stack = vec![into.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for item in fs::read_dir(dir).unwrap() {
            let path = item.unwrap().path();
            let name = path
                .strip_prefix(into)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            if path.is_dir() {
                found.push(format!("{name}/"));
                stack.push(path);
            } else {
                found.push(name);
            }
        }
    }
    found.sort();
    found
}

#[test]
fn written_copy_passes_unzip_t_and_ditto() {
    let o = Opened::new("edit-readers", &rich());
    let src = Src::new("edit-readers");
    let path = src.put("new.txt", b"new body");
    let lists = [
        (
            vec![add(&path, "", "new.txt")],
            "added.zip",
            vec![
                "dir/",
                "dir/deflated.txt",
                "gone.txt",
                "new.txt",
                "stored.bin",
            ],
        ),
        (
            vec![delete("gone.txt")],
            "deleted.zip",
            vec!["dir/", "dir/deflated.txt", "stored.bin"],
        ),
    ];
    for (changes, name, expected) in lists {
        o.changed(changes);
        let (job, out) = o.saved(name);
        assert_eq!(job.problem, None);
        let test = std::process::Command::new("/usr/bin/unzip")
            .arg("-t")
            .arg(&out)
            .output()
            .unwrap();
        assert!(test.status.success(), "unzip -t {name}");
        let into = PathBuf::from(o.tree.real()).join(format!("{name}.ditto"));
        assert_eq!(expanded_by_ditto(&out, &into), expected, "ditto {name}");
        assert_eq!(
            listed_by_bsdtar(&fs::read(&out).unwrap()),
            expected,
            "bsdtar {name}"
        );
    }
}

#[test]
fn replace_never_leaves_two_entries_with_one_name() {
    let o = Opened::new(
        "edit-replace",
        &fixture(&[
            ("note.txt", b"old note"),
            ("photos/a.jpg", b"a"),
            ("other.txt", b"other"),
        ]),
    );
    let src = Src::new("edit-replace");
    let note = src.put("note.txt", b"new note");
    src.put("photos/b.jpg", b"b");
    o.changed(vec![
        delete("note.txt"),
        add(&note, "", "note.txt"),
        delete("photos"),
        add(&src.dir().join("photos"), "", "photos"),
    ]);
    let (job, out) = o.saved("replaced.zip");
    assert_eq!(job.problem, None);
    assert_eq!(
        zip_names(&out),
        ["other.txt", "note.txt", "photos/", "photos/b.jpg"]
    );
    assert_eq!(zip_read(&out, "note.txt", None), b"new note");
    o.changed(vec![add(&note, "", "note.txt")]);
    assert_eq!(
        names(o.rows("")),
        ["photos", "note.txt", "note.txt", "other.txt"]
    );
    let (job, out) = o.saved("doubled.zip");
    assert_eq!(
        job.problem,
        Some(ArchiveProblem::Duplicate {
            name: "note.txt".into()
        })
    );
    assert!(!out.exists());
}

#[test]
fn editing_is_none_for_jar_apk_aar_cbz_rar_cbr_and_pkg() {
    let zip = fixture(&[("a.txt", b"a")]);
    let src = Src::new("edit-kinds");
    src.put("t/a.txt", b"a");
    let tar = gzipped(&src.tar("t.tar", &["-c", "t"]));
    for (at, (name, bytes)) in [
        ("x.zip", &zip),
        ("X.ZIP", &zip),
        ("x.tar.gz", &tar),
        ("x.tgz", &tar),
    ]
    .into_iter()
    .enumerate()
    {
        let o = Opened::named(&format!("edit-kind-all-{at}"), name, bytes);
        assert_eq!(o.summary().editing, ArchiveEditing::All, "{name}");
    }
    let (pkg, _, _built) = built_pkgs("edit-kind-pkg");
    let rar = rar5_stored();
    for (at, (name, bytes)) in [
        ("x.jar", &zip),
        ("x.apk", &zip),
        ("x.aar", &zip),
        ("x.cbz", &zip),
        ("x.rar", &rar),
        ("x.cbr", &rar),
        ("x.pkg", &pkg),
    ]
    .into_iter()
    .enumerate()
    {
        let o = Opened::named(&format!("edit-kind-none-{at}"), name, bytes);
        o.source();
        assert_eq!(o.summary().editing, ArchiveEditing::None, "{name}");
        assert!(
            matches!(
                o.session.set_changes(vec![delete("a.txt")]),
                Err(EngineError::Io { .. })
            ),
            "{name}"
        );
    }
}

#[test]
fn search_shows_added_entries_and_hides_deleted_ones() {
    let o = Opened::new(
        "edit-search",
        &fixture(&[
            ("docs/report.txt", b"r"),
            ("docs/report-old.txt", b"o"),
            ("other.txt", b"x"),
        ]),
    );
    assert_eq!(sorted(o.found("report")), ["report-old.txt", "report.txt"]);
    let src = Src::new("edit-search");
    let path = src.put("report-new.txt", b"n");
    o.changed(vec![
        delete("docs/report-old.txt"),
        add(&path, "docs", "report-new.txt"),
    ]);
    let found = o.found("report");
    assert_eq!(sorted(found.clone()), ["report-new.txt", "report.txt"]);
    assert_eq!(
        row(&found, "report-new.txt").folder,
        "/shown/archive.zip/docs"
    );
    assert!(o.found("old").is_empty());
}

fn tar_reader(path: &std::path::Path) -> detect::Reader {
    detect::Reader::open(path, Arc::new(std::sync::atomic::AtomicBool::new(false))).unwrap()
}

fn tar_members(path: &std::path::Path) -> Vec<tar::Member> {
    let Ok((members, problem)) = tar::list(&tar_reader(path), &|| false) else {
        panic!("the tarball did not list");
    };
    assert_eq!(problem, None);
    members
}

fn tar_key(name: &[u8]) -> String {
    let name = String::from_utf8_lossy(name);
    let name = name.trim_end_matches('/');
    crate::query::nfd(name).unwrap_or_else(|| name.to_owned())
}

fn tar_names(path: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = tar_members(path).iter().map(|m| tar_key(&m.name)).collect();
    names.sort();
    names
}

fn tar_bytes(path: &std::path::Path, name: &str) -> Vec<u8> {
    let members = tar_members(path);
    let member = members
        .iter()
        .rev()
        .find(|m| tar_key(&m.name) == tar_key(name.as_bytes()))
        .unwrap_or_else(|| panic!("{name} is not in the tarball"));
    let mut bytes = Vec::new();
    let mut stream = None;
    let Ok(mut contents) = tar::contents(&tar_reader(path), &mut stream, member, &|| false) else {
        panic!("{name} did not read");
    };
    contents.read_to_end(&mut bytes).unwrap();
    bytes
}

fn spawned(path: &std::path::Path) -> bool {
    bsdtar::SPAWNED
        .lock()
        .unwrap()
        .iter()
        .any(|(p, _)| p == path)
}

fn moded(mut h: [u8; 512], mode: &[u8; 7]) -> [u8; 512] {
    h[100..107].copy_from_slice(mode);
    h
}

fn pointing(name: &[u8], flag: u8, target: &[u8]) -> [u8; 512] {
    let mut h = tar::tests::header(name, flag, 0);
    h[157..157 + target.len()].copy_from_slice(target);
    h
}

impl Opened {
    fn edits_left(&self) -> Vec<String> {
        fs::read_dir(self.cache())
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("edit-"))
            .collect()
    }
}

#[test]
fn tar_delete_file_keeps_every_other_header() {
    use tar::tests::{entry, header, pax};
    let bytes = ustar(&[
        entry(moded(header(b"top/", b'5', 0), b"0000750"), b""),
        pax(
            b'x',
            &[
                ("mtime", "1614834367.123456789"),
                ("uid", "7001"),
                ("gid", "7002"),
            ],
        ),
        entry(moded(header(b"top/keep.txt", b'0', 4), b"0000640"), b"keep"),
        entry(pointing(b"top/link", b'2', b"keep.txt"), b""),
        entry(header(b"top/gone.txt", b'0', 4), b"gone"),
        entry(pointing(b"top/hard", b'1', b"top/keep.txt"), b""),
        entry(moded(header(b"other.sh", b'0', 2), b"0000755"), b"sh"),
    ]);
    let o = Opened::named("tar-edit-headers", "t.tar", &bytes);
    let before: Vec<tar::Member> = tar_members(&o.path)
        .into_iter()
        .filter(|m| tar_key(&m.name) != "top/gone.txt")
        .collect();
    assert_eq!(before.len(), 5);
    o.changed(vec![delete("top/gone.txt")]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(job.written, [out.to_string_lossy().into_owned()]);
    let after = tar_members(&out);
    assert_eq!(after.len(), 5);
    let shape = |m: &tar::Member| {
        (
            tar_key(&m.name),
            m.kind,
            m.size,
            m.mode & 0o7777,
            m.uid,
            m.gid,
            m.mtime,
            m.target.clone(),
        )
    };
    let mut want: Vec<_> = before.iter().map(shape).collect();
    let mut got: Vec<_> = after.iter().map(shape).collect();
    want.sort_by(|a, b| a.0.cmp(&b.0));
    got.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(got, want);
    let keep = after
        .iter()
        .find(|m| tar_key(&m.name) == "top/keep.txt")
        .unwrap();
    assert_eq!(
        (keep.mode & 0o777, keep.uid, keep.gid, keep.mtime),
        (0o640, 7001, 7002, (1_614_834_367, 123_456_789))
    );
    assert_eq!(tar_bytes(&out, "top/keep.txt"), b"keep");
    assert_eq!(tar_bytes(&out, "other.sh"), b"sh");
    assert!(o.edits_left().is_empty());
}

#[test]
fn tar_delete_folder_removes_its_subtree_and_keeps_a_longer_sibling() {
    let src = Src::new("tar-edit-folder");
    src.put("top/dirA/x.txt", b"x");
    src.put("top/dirA/sub/y.txt", b"y");
    src.put("top/dirAB/z.txt", b"z");
    src.put("top/keep.txt", b"k");
    let bytes = src.tar("f.tar", &["-c", "--no-mac-metadata", "--no-xattrs", "top"]);
    let o = Opened::named("tar-edit-folder", "f.tar", &bytes);
    o.changed(vec![delete("top/dirA")]);
    assert_eq!(names(o.rows("top")), ["dirAB", "keep.txt"]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(
        tar_names(&out),
        ["top", "top/dirAB", "top/dirAB/z.txt", "top/keep.txt"]
    );
    assert_eq!(tar_bytes(&out, "top/dirAB/z.txt"), b"z");
}

#[test]
fn names_with_glob_characters_delete_exactly() {
    let targets = [
        "a*b", "a?b", "a[1]b", "a\\b", "x]y", "^car", "dol$", "-dash",
    ];
    let decoys = ["aXb", "aYb", "a1b", "car", "dol", "x", "y"];
    let src = Src::new("tar-edit-glob");
    for name in targets.iter().chain(&decoys) {
        src.put(&format!("top/{name}"), name.as_bytes());
    }
    let bytes = src.tar("g.tar", &["-c", "--no-mac-metadata", "--no-xattrs", "top"]);
    let o = Opened::named("tar-edit-glob", "g.tar", &bytes);
    o.changed(
        targets
            .iter()
            .map(|t| delete(&format!("top/{t}")))
            .collect(),
    );
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    let mut want: Vec<String> = decoys.iter().map(|d| format!("top/{d}")).collect();
    want.push("top".into());
    want.sort();
    assert_eq!(tar_names(&out), want);
    for decoy in decoys {
        assert_eq!(tar_bytes(&out, &format!("top/{decoy}")), decoy.as_bytes());
    }
}

#[test]
fn nfc_stored_name_deletes_through_bsdtars_spelling() {
    use tar::tests::{entry, header, pax};
    let nfc = "top/caf\u{e9}.txt";
    let fixtures = [
        (
            "ustar",
            ustar(&[
                entry(header(nfc.as_bytes(), b'0', 3), b"nfc"),
                entry(header(b"top/keep.txt", b'0', 4), b"keep"),
            ]),
        ),
        (
            "pax",
            ustar(&[
                pax(b'x', &[("path", nfc)]),
                entry(header(b"top/placeholder.txt", b'0', 3), b"nfc"),
                entry(header(b"top/keep.txt", b'0', 4), b"keep"),
            ]),
        ),
    ];
    for (label, bytes) in fixtures {
        let o = Opened::named(&format!("tar-edit-nfc-{label}"), "n.tar", &bytes);
        assert!(o.source().entries.iter().any(|e| e.path == nfc), "{label}");
        o.changed(vec![delete(nfc)]);
        let (job, out) = o.saved("out.tar");
        assert_eq!(job.problem, None, "{label}");
        assert_eq!(tar_names(&out), ["top/keep.txt"], "{label}");
        assert_eq!(tar_bytes(&out, "top/keep.txt"), b"keep", "{label}");
    }
}

#[test]
fn name_stored_twice_deletes_every_copy() {
    use tar::tests::{entry, header};
    let bytes = ustar(&[
        entry(header(b"same.txt", b'0', 5), b"first"),
        entry(header(b"keep.txt", b'0', 4), b"keep"),
        entry(header(b"same.txt", b'0', 6), b"second"),
    ]);
    let o = Opened::named("tar-edit-twice", "s.tar", &bytes);
    assert_eq!(names(o.rows("")), ["keep.txt", "same.txt"]);
    o.changed(vec![delete("same.txt")]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["keep.txt"]);
}

#[test]
fn cr_or_newline_name_deletes_through_exclude() {
    use tar::tests::{entry, header};
    let names_stored: [&[u8]; 5] = [
        b"top/cr\rname.txt",
        b"top/nl\nname.txt",
        b"top/cr",
        b"top/nl",
        b"top/name.txt",
    ];
    let bytes = ustar(
        &names_stored
            .iter()
            .map(|n| entry(header(n, b'0', n.len() as u64), n))
            .collect::<Vec<_>>(),
    );
    let o = Opened::named("tar-edit-crlf", "c.tar", &bytes);
    o.changed(vec![delete("top/cr\rname.txt"), delete("top/nl\nname.txt")]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["top/cr", "top/name.txt", "top/nl"]);
    for name in ["top/cr", "top/nl", "top/name.txt"] {
        assert_eq!(tar_bytes(&out, name), name.as_bytes());
    }
}

fn small_tar(label: &str, flags: &str, name: &str) -> Opened {
    let src = Src::new(label);
    src.put("top/keep.txt", b"keep");
    src.put("gone.txt", b"gone");
    let bytes = src.tar(
        name,
        &[flags, "--no-mac-metadata", "--no-xattrs", "top", "gone.txt"],
    );
    Opened::named(label, name, &bytes)
}

#[test]
fn save_names_the_added_folder_inside_that_can_no_longer_be_read() {
    for (name, flags) in [
        ("a.zip", None),
        ("a.tar", Some("-c")),
        ("a.tar.gz", Some("-cz")),
    ] {
        let label = format!("edit-unreadable-folder-{name}");
        let o = match flags {
            None => Opened::named(&label, name, &fixture(&[("old.txt", b"old")])),
            Some(flags) => small_tar(&label, flags, name),
        };
        let src = Src::new(&format!("{label}-add"));
        src.put("pics/a.jpg", b"a");
        src.put("pics/inner/b.jpg", b"b");
        o.changed(vec![add(&src.dir().join("pics"), "", "pics")]);
        let inner = src.dir().join("pics/inner");
        let locked = crate::crawl::tests::Locked::new(vec![inner.clone()]);
        let (job, out) = o.saved(&format!("saved-{name}"));
        drop(locked);
        assert_eq!(
            job.problem,
            Some(ArchiveProblem::Gone {
                name: inner.to_string_lossy().into_owned()
            }),
            "{name}"
        );
        assert!(!out.exists(), "{name}");
    }
}

#[test]
fn save_names_an_added_file_that_can_no_longer_be_read() {
    for (name, flags) in [
        ("a.zip", None),
        ("a.tar", Some("-c")),
        ("a.tar.gz", Some("-cz")),
    ] {
        let label = format!("edit-unreadable-file-{name}");
        let o = match flags {
            None => Opened::named(&label, name, &fixture(&[("old.txt", b"old")])),
            Some(flags) => small_tar(&label, flags, name),
        };
        let src = Src::new(&format!("{label}-add"));
        let photo = src.put("photo.jpg", b"photo");
        o.changed(vec![add(&photo, "", "photo.jpg")]);
        let locked = crate::crawl::tests::Locked::new(vec![photo.clone()]);
        let (job, out) = o.saved(&format!("saved-{name}"));
        drop(locked);
        assert_eq!(
            job.problem,
            Some(ArchiveProblem::Gone {
                name: photo.to_string_lossy().into_owned()
            }),
            "{name}"
        );
        assert!(!out.exists(), "{name}");
    }
}

#[test]
fn add_file_and_folder_with_an_inner_symlink() {
    let o = small_tar("tar-edit-add", "-c", "a.tar");
    let src = Src::new("tar-edit-add-items");
    let file = src.put("new.txt", b"fresh");
    src.put("pack/inner/f.txt", b"inner");
    std::os::unix::fs::symlink("inner/f.txt", src.dir().join("pack/rel-link")).unwrap();
    o.changed(vec![
        add(&file, "top", "new.txt"),
        add(&src.dir().join("pack"), "", "pack"),
    ]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(
        tar_names(&out),
        [
            "gone.txt",
            "pack",
            "pack/inner",
            "pack/inner/f.txt",
            "pack/rel-link",
            "top",
            "top/keep.txt",
            "top/new.txt",
        ]
    );
    let members = tar_members(&out);
    let of = |name: &str| {
        members
            .iter()
            .find(|m| tar_key(&m.name) == name)
            .unwrap()
            .clone()
    };
    assert_eq!(of("pack").kind, tar::Kind::Folder);
    assert_eq!(of("top/new.txt").kind, tar::Kind::File);
    let link = of("pack/rel-link");
    assert_eq!(
        (link.kind, link.target.as_deref()),
        (tar::Kind::Symlink, Some(&b"inner/f.txt"[..]))
    );
    assert_eq!(tar_bytes(&out, "top/new.txt"), b"fresh");
    assert_eq!(tar_bytes(&out, "pack/inner/f.txt"), b"inner");
    assert!(o.edits_left().is_empty());
}

#[test]
fn replace_in_one_pass_keeps_one_entry_with_the_new_bytes() {
    let o = small_tar("tar-edit-replace", "-cz", "r.tar.gz");
    let src = Src::new("tar-edit-replace-items");
    let path = src.put("keep.txt", b"new bytes");
    o.changed(vec![delete("top/keep.txt"), add(&path, "top", "keep.txt")]);
    let (job, out) = o.saved("out.tar.gz");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["gone.txt", "top", "top/keep.txt"]);
    assert_eq!(tar_bytes(&out, "top/keep.txt"), b"new bytes");
}

#[test]
fn names_starting_with_at_or_dash_add() {
    let o = small_tar("tar-edit-at-dash", "-c", "d.tar");
    let src = Src::new("tar-edit-at-dash-items");
    let at = src.put("@at.txt", b"at");
    let dash = src.put("-dash.txt", b"dash");
    o.changed(vec![
        add(&at, "", "@at.txt"),
        add(&dash, "top", "-dash.txt"),
    ]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(
        tar_names(&out),
        [
            "@at.txt",
            "gone.txt",
            "top",
            "top/-dash.txt",
            "top/keep.txt"
        ]
    );
    assert_eq!(tar_bytes(&out, "@at.txt"), b"at");
    assert_eq!(tar_bytes(&out, "top/-dash.txt"), b"dash");
}

fn compression(bytes: &[u8]) -> &'static str {
    match bytes {
        [0x1f, 0x8b, ..] => "gzip",
        [b'B', b'Z', b'h', ..] => "bzip2",
        [0xfd, b'7', b'z', b'X', b'Z', 0, ..] => "xz",
        _ if bytes.get(257..262) == Some(b"ustar") => "plain",
        _ => "unknown",
    }
}

#[test]
fn compression_follows_the_source_magic() {
    for (label, flags) in [
        ("plain", "-c"),
        ("gzip", "-cz"),
        ("bzip2", "-cj"),
        ("xz", "-cJ"),
    ] {
        let o = small_tar(&format!("tar-edit-magic-{label}"), flags, "x.tar");
        assert_eq!(compression(&fs::read(&o.path).unwrap()), label);
        o.changed(vec![delete("gone.txt")]);
        let (job, out) = o.saved("out.tar");
        assert_eq!(job.problem, None, "{label}");
        assert_eq!(compression(&fs::read(&out).unwrap()), label);
        assert_eq!(tar_names(&out), ["top", "top/keep.txt"], "{label}");
    }
}

#[test]
fn delete_that_strands_a_hard_link_is_refused_with_linked_item() {
    let src = Src::new("tar-edit-hard");
    let a = src.put("a.txt", b"shared");
    fs::hard_link(&a, src.dir().join("b.txt")).unwrap();
    src.put("c.txt", b"c");
    let bytes = src.tar(
        "h.tar",
        &[
            "-c",
            "--no-mac-metadata",
            "--no-xattrs",
            "a.txt",
            "b.txt",
            "c.txt",
        ],
    );
    let o = Opened::named("tar-edit-hard", "h.tar", &bytes);
    let link = tar_members(&o.path)
        .into_iter()
        .find(|m| tar_key(&m.name) == "b.txt")
        .unwrap();
    assert_eq!(link.kind, tar::Kind::HardLink);
    o.changed(vec![delete("c.txt")]);
    let (job, out) = o.saved("twin.tar");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["a.txt", "b.txt"]);
    o.changed(vec![delete("a.txt")]);
    let (job, out) = o.saved("refused.tar");
    assert_eq!(
        job.problem,
        Some(ArchiveProblem::LinkedItem {
            name: "a.txt".into()
        })
    );
    assert!(!out.exists());
    assert!(!spawned(&out));
    assert!(o.edits_left().is_empty());
}

#[test]
fn damaged_gzip_source_is_refused() {
    let src = Src::new("tar-edit-crc");
    src.put("a.txt", &noise(5000));
    src.put("gone.txt", b"gone");
    let good = src.tar(
        "d.tar.gz",
        &[
            "-cz",
            "--no-mac-metadata",
            "--no-xattrs",
            "a.txt",
            "gone.txt",
        ],
    );
    let twin = Opened::named("tar-edit-crc-good", "d.tar.gz", &good);
    twin.changed(vec![delete("gone.txt")]);
    let (job, out) = twin.saved("twin.tar.gz");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["a.txt"]);
    let mut bad = good.clone();
    let at = bad.len() - 8;
    bad[at] ^= 0xff;
    let o = Opened::named("tar-edit-crc-bad", "d.tar.gz", &bad);
    assert_eq!(o.summary().problem, None);
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("refused.tar.gz");
    assert_eq!(job.problem, Some(ArchiveProblem::Damaged));
    assert!(!out.exists());
    assert!(!spawned(&out));
    assert!(o.edits_left().is_empty());
}

#[test]
fn post_check_failure_deletes_the_copy() {
    let o = small_tar("tar-edit-spoiled", "-c", "p.tar");
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("twin.tar");
    assert_eq!(job.problem, None);
    assert_eq!(tar_names(&out), ["top", "top/keep.txt"]);
    let spoiled = PathBuf::from(o.tree.real()).join("spoiled.tar");
    tar::SPOILED.lock().unwrap().push(spoiled.clone());
    let (job, out) = o.saved("spoiled.tar");
    assert_eq!(out, spoiled);
    assert_eq!(job.problem, Some(ArchiveProblem::Damaged));
    assert!(spawned(&out));
    assert!(!out.exists());
    assert!(o.edits_left().is_empty());
}

#[test]
fn out_equal_to_the_input_is_refused() {
    let o = small_tar("tar-edit-same-out", "-cz", "o.tar.gz");
    let before = fs::read(&o.path).unwrap();
    o.changed(vec![delete("gone.txt")]);
    let (job, _) = o.saved("twin.tar.gz");
    assert_eq!(job.problem, None);
    assert!(
        o.session
            .write_edited(o.path.to_string_lossy().into_owned())
            .is_err()
    );
    assert_eq!(fs::read(&o.path).unwrap(), before);
}

#[test]
fn changed_source_ends_changed_before_spawning() {
    let o = small_tar("tar-edit-changed", "-c", "c.tar");
    o.changed(vec![delete("gone.txt")]);
    let (job, _) = o.saved("twin.tar");
    assert_eq!(job.problem, None);
    dated(&o.path, NEW_YEAR);
    let (job, out) = o.saved("changed.tar");
    assert_eq!(job.problem, Some(ArchiveProblem::Changed));
    assert!(!out.exists());
    assert!(!spawned(&out));
}

#[test]
fn dot_underscore_companions_follow_their_file() {
    let src = Src::new("tar-edit-companions");
    let keep = src.put("keep.txt", b"keep");
    let gone = src.put("gone.txt", b"gone");
    set_xattr(&keep, c"com.example.kept", b"k");
    set_xattr(&gone, c"com.example.gone", b"g");
    let bytes = src.tar("m.tar", &["-c", "keep.txt", "gone.txt"]);
    let o = Opened::named("tar-edit-companions", "m.tar", &bytes);
    let before = tar_members(&o.path);
    assert!(before.iter().all(|m| m.companion.is_some()));
    assert_eq!(names(o.rows("")), ["gone.txt", "keep.txt"]);
    o.changed(vec![delete("gone.txt")]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    let after = tar_members(&out);
    assert_eq!(after.len(), 1);
    assert_eq!(tar_key(&after[0].name), "keep.txt");
    assert_eq!(
        after[0].companion.as_ref().map(|c| tar_key(&c.name)),
        Some("._keep.txt".to_owned())
    );
    assert_eq!(tar_bytes(&out, "keep.txt"), b"keep");
    let session = o.open(&out);
    assert_eq!(names(o.in_session(&session, "")), ["keep.txt"]);
}

fn slow_tar(label: &str, size: usize) -> (Opened, Src) {
    let o = small_tar(label, "-cj", "s.tar.bz2");
    let src = Src::new(&format!("{label}-items"));
    let big = src.put("big.bin", &noise(size));
    o.changed(vec![delete("gone.txt"), add(&big, "", "big.bin")]);
    (o, src)
}

#[test]
fn cancel_kills_the_child_and_deletes_copy_and_stage() {
    let (o, _src) = slow_tar("tar-edit-cancel", 48 * 1024 * 1024);
    let out = PathBuf::from(o.tree.real()).join("cancelled.tar.bz2");
    let (reached, release) = o.hold();
    let id = o
        .session
        .write_edited(out.to_string_lossy().into_owned())
        .unwrap();
    reached.recv_timeout(Duration::from_secs(60)).unwrap();
    assert!(fs::metadata(&out).unwrap().len() > 0);
    let pids: Vec<u32> = bsdtar::SPAWNED
        .lock()
        .unwrap()
        .iter()
        .filter(|(p, _)| *p == out)
        .map(|&(_, pid)| pid)
        .collect();
    assert_eq!(pids.len(), 1);
    assert_eq!(unsafe { libc::kill(pids[0] as i32, 0) }, 0);
    assert_eq!(o.edits_left().len(), 1);
    o.session.cancel(id).unwrap();
    release.send(()).unwrap();
    let job = finished(&o.session, id);
    assert!(job.written.is_empty());
    assert!(reaped(&out));
    assert!(!out.exists());
    assert!(o.edits_left().is_empty());
}

#[test]
fn progress_stays_under_100_until_the_child_exits() {
    let (o, _src) = slow_tar("tar-edit-progress", 8 * 1024 * 1024);
    let out = PathBuf::from(o.tree.real()).join("progress.tar.bz2");
    let (reached, release) = o.hold();
    let id = o
        .session
        .write_edited(out.to_string_lossy().into_owned())
        .unwrap();
    reached.recv_timeout(Duration::from_secs(60)).unwrap();
    let held = o.session.job(id).unwrap();
    assert!(!held.finished);
    assert!(held.done_bytes > 0, "{held:?}");
    assert!(held.done_bytes < held.total_bytes, "{held:?}");
    release.send(()).unwrap();
    let job = expanded_job(&o.session, id);
    assert_eq!(job.problem, None);
    assert_eq!(job.done_bytes, job.total_bytes);
    assert_eq!(job.written, [out.to_string_lossy().into_owned()]);
}

#[test]
fn pax_nfc_folder_keeps_its_mode_after_expand() {
    use tar::tests::{entry, header, pax};
    let folder = "caf\u{e9}";
    let bytes = ustar(&[
        pax(b'x', &[("path", "caf\u{e9}/")]),
        entry(moded(header(b"placeholder/", b'5', 0), b"0000555"), b""),
        pax(b'x', &[("path", "caf\u{e9}/inner.txt")]),
        entry(header(b"placeholder/inner.txt", b'0', 5), b"inner"),
    ]);
    let o = Opened::named("expand-nfc-folder", "f.tar", &bytes);
    let dest = o.place("dest");
    let job = o.expand(&[folder], false, &dest);
    assert_eq!((job.problem, job.skipped), (None, 0));
    assert_eq!(
        fs::read(dest.join(folder).join("inner.txt")).unwrap(),
        b"inner"
    );
    let mode = fs::metadata(dest.join(folder)).unwrap().mode() & 0o777;
    fs::set_permissions(dest.join(folder), fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(mode, 0o555);
}

#[test]
fn expand_of_an_edited_tarball_writes_added_items_and_skips_deleted_ones() {
    let o = small_tar("expand-edited-tar", "-cz", "e.tar.gz");
    let src = Src::new("expand-edited-tar-items");
    let replaced = src.put("keep.txt", b"replaced");
    let new = src.put("new.txt", b"new");
    src.put("pack/inner.txt", b"inner");
    o.changed(vec![
        delete("gone.txt"),
        delete("top/keep.txt"),
        add(&replaced, "top", "keep.txt"),
        add(&new, "top", "new.txt"),
        add(&src.dir().join("pack"), "", "pack"),
    ]);
    let whole = o.place("whole");
    let job = o.expand(&[], true, &whole);
    assert_eq!((job.problem, job.skipped), (None, 0));
    assert_eq!(job.done_bytes, job.total_bytes);
    let boxed = listing(&whole);
    assert_eq!(boxed.len(), 1);
    let root = whole.join(&boxed[0]);
    assert_eq!(listing(&root), ["pack", "top"]);
    assert_eq!(listing(&root.join("top")), ["keep.txt", "new.txt"]);
    assert_eq!(fs::read(root.join("top/keep.txt")).unwrap(), b"replaced");
    assert_eq!(fs::read(root.join("top/new.txt")).unwrap(), b"new");
    assert_eq!(fs::read(root.join("pack/inner.txt")).unwrap(), b"inner");
    let folder = o.place("folder");
    let job = o.expand(&["top"], false, &folder);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&folder.join("top")), ["keep.txt", "new.txt"]);
    assert_eq!(fs::read(folder.join("top/keep.txt")).unwrap(), b"replaced");
    let picked = o.place("picked");
    let job = o.expand(&["top/new.txt", "top/keep.txt"], false, &picked);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&picked), ["keep.txt", "new.txt"]);
    assert_eq!(fs::read(picked.join("keep.txt")).unwrap(), b"replaced");
}

#[test]
fn added_folder_with_a_fifo_and_dot_underscore_items_saves_what_the_view_shows() {
    use std::os::unix::ffi::OsStrExt;
    let o = small_tar("tar-edit-skips", "-c", "k.tar");
    let src = Src::new("tar-edit-skips-items");
    src.put("pack/f.txt", b"f");
    src.put("pack/._f.txt", b"apple double");
    src.put("pack/._g/inner.txt", b"g");
    let pipe = std::ffi::CString::new(src.dir().join("pack/pipe").as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(pipe.as_ptr(), 0o644) }, 0);
    o.changed(vec![add(&src.dir().join("pack"), "", "pack")]);
    assert_eq!(sorted(o.rows("pack")), ["f.txt"]);
    let (job, out) = o.saved("out.tar");
    assert_eq!(job.problem, None);
    assert_eq!(
        tar_names(&out),
        ["gone.txt", "pack", "pack/f.txt", "top", "top/keep.txt"]
    );
    assert!(tar_members(&out).iter().all(|m| m.companion.is_none()));
    assert_eq!(tar_bytes(&out, "pack/f.txt"), b"f");
    let session = o.open(&out);
    assert_eq!(sorted(o.in_session(&session, "pack")), ["f.txt"]);
    assert!(o.edits_left().is_empty());
}

#[test]
fn expand_of_a_kept_hard_link_whose_target_changed_is_refused_with_linked_item() {
    let src = Src::new("expand-tar-hard");
    let a = src.put("a.txt", b"shared");
    fs::hard_link(&a, src.dir().join("b.txt")).unwrap();
    src.put("c.txt", b"c");
    let bytes = src.tar(
        "h.tar",
        &[
            "-c",
            "--no-mac-metadata",
            "--no-xattrs",
            "a.txt",
            "b.txt",
            "c.txt",
        ],
    );
    let o = Opened::named("expand-tar-hard", "h.tar", &bytes);
    let disk = Src::new("expand-tar-hard-items");
    let new_a = disk.put("a.txt", b"new a");
    let new_c = disk.put("c.txt", b"new c");
    o.changed(vec![delete("c.txt"), add(&new_c, "", "c.txt")]);
    let twin = o.place("twin");
    let job = o.expand(&[], true, &twin);
    assert_eq!(job.problem, None);
    let boxed = listing(&twin);
    assert_eq!(boxed.len(), 1);
    let root = twin.join(&boxed[0]);
    assert_eq!(listing(&root), ["a.txt", "b.txt", "c.txt"]);
    assert_eq!(fs::read(root.join("b.txt")).unwrap(), b"shared");
    assert_eq!(fs::read(root.join("c.txt")).unwrap(), b"new c");
    o.changed(vec![delete("a.txt"), add(&new_a, "", "a.txt")]);
    let other = o.place("other");
    let job = o.expand(&["c.txt"], false, &other);
    assert_eq!(job.problem, None);
    assert_eq!(listing(&other), ["c.txt"]);
    let linked = Some(ArchiveProblem::LinkedItem {
        name: "a.txt".into(),
    });
    let whole = o.place("whole");
    assert_eq!(o.expand(&[], true, &whole).problem, linked);
    assert!(listing(&whole).is_empty());
    let picked = o.place("picked");
    assert_eq!(o.expand(&["b.txt"], false, &picked).problem, linked);
    assert!(listing(&picked).is_empty());
    o.changed(vec![delete("a.txt")]);
    let deleted = o.place("deleted");
    assert_eq!(o.expand(&["b.txt"], false, &deleted).problem, linked);
    assert!(listing(&deleted).is_empty());
    let (job, out) = o.saved("refused.tar");
    assert_eq!(job.problem, linked);
    assert!(!out.exists());
}

fn disk_image(label: &str, password: &[u8]) -> Vec<u8> {
    use std::ffi::OsStr;
    let src = TempTree::new(&format!("{label}-src"));
    let tool = src.0.join("tool");
    fs::write(&tool, b"#!/bin/sh\n").unwrap();
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).unwrap();
    fs::create_dir_all(src.data()).unwrap();
    let out = src.data().join("image.dmg");
    let mut args: Vec<&OsStr> = [
        "create", "-size", "2m", "-fs", "HFS+", "-volname", "Wherever",
    ]
    .map(OsStr::new)
    .to_vec();
    if !password.is_empty() {
        args.extend(["-encryption", "AES-256", "-stdinpass"].map(OsStr::new));
    }
    args.extend([OsStr::new("-srcfolder"), src.0.as_os_str(), out.as_os_str()]);
    let (status, _, _) = image::hdiutil(&args, password, Duration::from_secs(60), &|| false)
        .ok()
        .expect("hdiutil create ran past its cap");
    assert!(status.success(), "hdiutil create failed");
    fs::read(&out).unwrap()
}

struct Detached(PathBuf);

impl Detached {
    fn under(o: &Opened) -> Self {
        Self(
            PathBuf::from(o.tree.real())
                .join("home")
                .join(CACHES)
                .join("Mounts"),
        )
    }

    fn mounted(&self) -> Vec<PathBuf> {
        fs::read_dir(&self.0)
            .into_iter()
            .flatten()
            .flatten()
            .map(|item| item.path())
            .filter(|point| crate::crawl::is_mount(point))
            .collect()
    }

    fn gone(&self) -> bool {
        let end = Instant::now() + Duration::from_secs(90);
        while Instant::now() < end {
            if self.mounted().is_empty() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }
}

impl Drop for Detached {
    fn drop(&mut self) {
        for point in self.mounted() {
            image::detach(&point);
        }
    }
}

fn hdiutil_calls(file: &std::path::Path) -> Vec<(Vec<String>, usize)> {
    let file = detect::resolved(file).to_string_lossy().into_owned();
    image::SPAWNED
        .lock()
        .unwrap()
        .iter()
        .filter(|(args, _)| args.last().is_some_and(|a| *a == file))
        .cloned()
        .collect()
}

#[test]
fn attach_list_read_detach() {
    let o = Opened::named(
        "image-attach",
        "image.dmg",
        &disk_image("image-attach", b""),
    );
    let mounts = Detached::under(&o);
    let s = o.summary();
    assert_eq!(s.format, "dmg");
    assert_eq!(s.problem, None);
    assert!(!s.encrypted);
    assert_eq!(s.editing, ArchiveEditing::None);
    let mounted = mounts.mounted();
    assert_eq!(mounted.len(), 1, "one mount under the cache");
    let mut shown: Vec<String> = names(o.rows(""))
        .into_iter()
        .filter(|n| !n.starts_with('.'))
        .collect();
    shown.sort();
    assert_eq!(
        shown,
        ["Alpha.TXT", "Gamma.md", "Sub", "beta.txt", "link", "tool"]
    );
    assert_eq!(names(o.rows("Sub")), ["DELTA.Txt"]);
    let job = o.extract(&["Alpha.TXT", "tool", "link"], false);
    assert_eq!(job.problem, None);
    let out = o.output();
    assert_eq!(fs::read(out.join("Alpha.TXT")).unwrap(), b"hello");
    assert_eq!(
        fs::metadata(out.join("tool")).unwrap().permissions().mode() & 0o777,
        0o755
    );
    assert_eq!(
        fs::read_link(out.join("link")).unwrap(),
        PathBuf::from("Alpha.TXT")
    );
    o.session.close().unwrap();
    assert!(mounts.gone(), "the image stayed mounted after close");
    assert!(!crate::crawl::is_mount(&mounted[0]));
}

#[test]
fn encrypted_image_needs_the_password() {
    let o = Opened::named(
        "image-locked",
        "image.dmg",
        &disk_image("image-locked", b"wherever-pass"),
    );
    let mounts = Detached::under(&o);
    let s = o.summary();
    assert_eq!(s.format, "dmg");
    assert!(s.encrypted);
    assert_eq!(s.problem, Some(ArchiveProblem::PasswordNeeded));
    assert!(o.rows("").is_empty());
    assert!(mounts.mounted().is_empty(), "attached without the password");
    assert!(!o.session.unlock("wrong-pass".into()).unwrap());
    assert_eq!(
        o.session.summary().unwrap().problem,
        Some(ArchiveProblem::PasswordNeeded)
    );
    assert!(mounts.mounted().is_empty(), "a wrong password left a mount");
    assert!(o.session.unlock("wherever-pass".into()).unwrap());
    let s = o.session.summary().unwrap();
    assert_eq!(s.problem, None);
    assert!(s.encrypted);
    assert!(names(o.rows("")).contains(&"Alpha.TXT".to_owned()));
    let job = o.extract(&["Alpha.TXT"], false);
    assert_eq!(job.problem, None);
    assert_eq!(fs::read(o.output().join("Alpha.TXT")).unwrap(), b"hello");
    let calls = hdiutil_calls(&o.path);
    assert_eq!(
        calls
            .iter()
            .map(|(args, input)| (args[0].as_str(), *input))
            .collect::<Vec<_>>(),
        [
            ("isencrypted", 0),
            ("isencrypted", 0),
            ("attach", "wrong-pass".len()),
            ("isencrypted", 0),
            ("attach", "wherever-pass".len()),
        ]
    );
    assert!(
        calls
            .iter()
            .filter(|(args, _)| args[0] == "attach")
            .all(|(args, _)| args.iter().any(|a| a == "-stdinpass"))
    );
    o.session.close().unwrap();
    assert!(mounts.gone(), "the image stayed mounted after close");
}

#[test]
fn a_folder_of_an_unlocked_image_extracts_its_files() {
    let o = Opened::named(
        "image-folder",
        "image.dmg",
        &disk_image("image-folder", b"wherever-pass"),
    );
    let mounts = Detached::under(&o);
    assert_eq!(o.summary().problem, Some(ArchiveProblem::PasswordNeeded));
    assert!(o.session.unlock("wherever-pass".into()).unwrap());
    let job = o.extract(&["Sub"], false);
    assert_eq!(job.problem, None);
    assert!(o.output().join("Sub/DELTA.Txt").is_file());
    o.session.close().unwrap();
    assert!(mounts.gone(), "the image stayed mounted after close");
}

#[test]
fn plain_image_attaches_with_stdinpass_and_empty_input() {
    let o = Opened::named("image-stdin", "image.dmg", &disk_image("image-stdin", b""));
    let mounts = Detached::under(&o);
    assert_eq!(o.summary().problem, None);
    let calls = hdiutil_calls(&o.path);
    assert_eq!(
        calls.iter().map(|(a, _)| a[0].as_str()).collect::<Vec<_>>(),
        ["isencrypted", "attach"]
    );
    let (args, input) = &calls[1];
    for flag in [
        "-readonly",
        "-nobrowse",
        "-noautoopen",
        "-stdinpass",
        "-plist",
        "-mountrandom",
    ] {
        assert!(args.iter().any(|a| a == flag), "{flag} missing");
    }
    assert_eq!(*input, 0);
    assert_eq!(
        PathBuf::from(&args[args.len() - 2]),
        fs::canonicalize(&mounts.0).unwrap()
    );
    assert_eq!(mounts.mounted().len(), 1);
    assert_eq!(names(o.rows("Sub")), ["DELTA.Txt"]);
    o.session.close().unwrap();
    assert!(mounts.gone(), "the image stayed mounted after close");
}

fn silence_fseventsd(volume: &std::path::Path) {
    let log = volume.join(".fseventsd");
    fs::create_dir_all(&log).unwrap();
    fs::write(log.join("no_log"), b"").unwrap();
}

fn drop_fseventsd(volume: &std::path::Path) {
    let _ = fs::remove_dir_all(volume.join(".fseventsd"));
}

fn two_volume_image(label: &str) -> Vec<u8> {
    use std::ffi::OsStr;
    let src = TempTree::new(&format!("{label}-src"));
    fs::create_dir_all(src.data()).unwrap();
    let dir = fs::canonicalize(src.data()).unwrap();
    let mounts = dir.join("mounts");
    fs::create_dir_all(mounts.join("two")).unwrap();
    let attached = Detached(mounts.clone());
    let sparse = dir.join("many.sparseimage");
    let hdiutil = |args: &[&OsStr]| {
        let (status, out, _) = image::hdiutil(args, b"", Duration::from_secs(120), &|| false)
            .ok()
            .expect("hdiutil ran past its cap");
        assert!(status.success(), "hdiutil {:?} failed", args[0]);
        out
    };
    let diskutil = |args: &[&str]| {
        let out = std::process::Command::new("/usr/sbin/diskutil")
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "diskutil {} failed", args[0]);
        out
    };
    let base = dir.join("many");
    let mut create: Vec<&OsStr> = [
        "create", "-size", "1100m", "-fs", "APFS", "-volname", "One", "-type", "SPARSE",
    ]
    .map(OsStr::new)
    .to_vec();
    create.push(base.as_os_str());
    hdiutil(&create);
    let out = hdiutil(&[
        OsStr::new("attach"),
        OsStr::new("-nobrowse"),
        OsStr::new("-noautoopen"),
        OsStr::new("-plist"),
        OsStr::new("-mountrandom"),
        mounts.as_os_str(),
        sparse.as_os_str(),
    ]);
    let points = image::mount_points(&out).unwrap();
    let [one] = points.as_slice() else {
        panic!("the new image did not mount one volume");
    };
    silence_fseventsd(one);
    fs::write(one.join("one.txt"), b"one").unwrap();
    let one_path = one.clone();
    let one = one.to_string_lossy().into_owned();
    let image::Plist::Dict(info) =
        image::plist(&diskutil(&["info", "-plist", &one]).stdout).unwrap()
    else {
        panic!("diskutil info is not a dictionary");
    };
    let container = info
        .iter()
        .find_map(|(key, value)| match (key.as_str(), value) {
            ("APFSContainerReference", image::Plist::Text(disk)) => Some(disk.clone()),
            _ => None,
        })
        .unwrap();
    let added = diskutil(&["apfs", "addVolume", &container, "APFS", "Two", "-nomount"]);
    let added = String::from_utf8_lossy(&[added.stdout, added.stderr].concat()).into_owned();
    let volume = added
        .lines()
        .find_map(|line| line.strip_prefix("Disk from APFS operation: "))
        .unwrap()
        .trim()
        .to_owned();
    let two = mounts.join("two").to_string_lossy().into_owned();
    diskutil(&[
        "mount",
        "-mountOptions",
        "nobrowse",
        "-mountPoint",
        &two,
        &volume,
    ]);
    silence_fseventsd(&mounts.join("two"));
    fs::write(mounts.join("two/two.txt"), b"two").unwrap();
    drop_fseventsd(&one_path);
    drop_fseventsd(&mounts.join("two"));
    image::detach(std::path::Path::new(&one));
    assert!(attached.gone(), "the new image stayed mounted");
    let packed = dir.join("many.dmg");
    hdiutil(&[
        OsStr::new("convert"),
        sparse.as_os_str(),
        OsStr::new("-format"),
        OsStr::new("UDZO"),
        OsStr::new("-o"),
        packed.as_os_str(),
    ]);
    fs::read(&packed).unwrap()
}

#[test]
fn every_volume_of_an_image_lists_extracts_and_expands() {
    let o = Opened::named(
        "image-volumes",
        "image.dmg",
        &two_volume_image("image-volumes"),
    );
    let mounts = Detached::under(&o);
    assert_eq!(o.summary().problem, None);
    assert_eq!(mounts.mounted().len(), 2);
    assert_eq!(names(o.rows("")), ["One", "Two"]);
    assert_eq!(names(o.rows("One")), ["one.txt"]);
    assert_eq!(names(o.rows("Two")), ["two.txt"]);
    assert_eq!(o.read("Two/two.txt"), b"two");
    assert_eq!(o.read("One/one.txt"), b"one");
    let picked = o.place("picked");
    assert_eq!(o.expand(&["Two/two.txt"], false, &picked).problem, None);
    assert_eq!(listing(&picked), ["two.txt"]);
    assert_eq!(fs::read(picked.join("two.txt")).unwrap(), b"two");
    let whole = o.place("whole");
    assert_eq!(o.expand(&[], true, &whole).problem, None);
    assert_eq!(fs::read(whole.join("image/One/one.txt")).unwrap(), b"one");
    assert_eq!(fs::read(whole.join("image/Two/two.txt")).unwrap(), b"two");
    o.session.close().unwrap();
    assert!(mounts.gone(), "the image stayed mounted after close");
}

#[test]
fn image_plist_reads_every_entity() {
    let xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>system-entities</key>
	<array>
		<dict>
			<key>content-hint</key>
			<string>GUID_partition_scheme</string>
			<key>potentially-mountable</key>
			<false/>
		</dict>
		<dict>
			<key>content-hint</key>
			<string>Apple_APFS</string>
		</dict>
		<dict>
			<key>mount-point</key>
			<string>/Caches/Mounts/dmg.a&amp;b</string>
			<key>volume-kind</key>
			<string>apfs</string>
		</dict>
	</array>
</dict>
</plist>"#;
    assert_eq!(
        image::mount_points(xml),
        Some(vec![PathBuf::from("/Caches/Mounts/dmg.a&b")])
    );
    assert_eq!(
        image::encrypted(b"<plist><dict><key>encrypted</key><true/></dict></plist>"),
        Some(true)
    );
    assert_eq!(
        image::encrypted(b"<plist><dict><key>encrypted</key><false/></dict></plist>"),
        Some(false)
    );
    assert_eq!(image::mount_points(b"<plist><dict>"), None);
}
