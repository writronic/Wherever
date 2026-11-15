use super::*;
use crate::crawl::tests::{TempTree, crawl};
use crate::crawl::{Listing, NONE};
use crate::live::Disk;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;

fn dates(path: &Path, times: [i64; 3]) {
    let path = CString::new(path.as_os_str().as_bytes()).unwrap();
    let mut al: libc::attrlist = unsafe { std::mem::zeroed() };
    al.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    al.commonattr = libc::ATTR_CMN_CRTIME | libc::ATTR_CMN_MODTIME | libc::ATTR_CMN_ACCTIME;
    let mut values = times.map(|tv_sec| libc::timespec { tv_sec, tv_nsec: 0 });
    assert_eq!(
        unsafe {
            libc::setattrlist(
                path.as_ptr(),
                (&raw mut al).cast(),
                values.as_mut_ptr().cast(),
                size_of_val(&values),
                0,
            )
        },
        0
    );
}

fn live(tree: &TempTree) -> Live {
    Live::new(Arc::new(
        Index::build(
            crawl(tree, &[], false),
            PathBuf::from(tree.real()),
            b"",
            1,
            1,
        )
        .unwrap(),
    ))
}

fn row(live: &Live, name: &str) -> EngineHit {
    live.find("", || false)
        .unwrap()
        .rows(0, 100)
        .into_iter()
        .find(|h| h.name == name)
        .unwrap()
}

fn refresh(live: &mut Live, tree: &TempTree) {
    let pool = Pool::new(2).unwrap();
    let disk = Disk {
        pool: &pool,
        skip: &[],
        stop: &AtomicBool::new(false),
    };
    let fetched = live.fetch(tree.real().as_bytes(), false, &disk);
    live.apply(fetched, &disk);
}

#[test]
fn columns_crawl_and_live_read_distinct_dates_exactly() {
    let tree = TempTree::new("columns-dates");
    let path = tree.0.join("Alpha.TXT");
    let first = [1_600_000_010, 1_600_000_020, 1_600_000_030];
    dates(&path, first);
    let mut live = live(&tree);
    let hit = row(&live, "Alpha.TXT");
    assert_eq!([hit.created, hit.modified, hit.opened], first);
    let second = [1_610_000_010, first[1], 1_610_000_030];
    dates(&path, second);
    refresh(&mut live, &tree);
    let hit = row(&live, "Alpha.TXT");
    assert_eq!([hit.created, hit.modified, hit.opened], second);
    let own = crawl::lstat(&path).unwrap();
    assert_eq!([own.created, own.mtime, own.opened], second);
    let saved = tree.data().join("dates.index");
    let compact = Index::build(live.to_crawl(), PathBuf::from(tree.real()), b"", 1, 1).unwrap();
    compact.save(&saved).unwrap();
    assert_eq!(
        row(
            &Live::new(Arc::new(
                Index::load(&saved, PathBuf::from(tree.real())).unwrap()
            )),
            "Alpha.TXT"
        ),
        hit
    );
}

#[test]
fn columns_existing_folder_dates_refresh_without_losing_children() {
    let tree = TempTree::new("columns-folder");
    let path = tree.0.join("Sub");
    let first = [1_600_000_010, 1_600_000_020, 1_600_000_030];
    dates(&path, first);
    let mut live = live(&tree);
    let held = live.find("", || false).unwrap();
    let second = [1_610_000_010, first[1], 1_610_000_030];
    dates(&path, second);
    let own = crawl::lstat(&path).unwrap();
    assert_eq!([own.created, own.mtime, own.opened], second);
    let pool = Pool::new(2).unwrap();
    let disk = Disk {
        pool: &pool,
        skip: &[],
        stop: &AtomicBool::new(false),
    };
    let fetched = live
        .fetch_changed(tree.real().as_bytes(), &disk)
        .expect("date-only change");
    live.apply(fetched, &disk);
    let hit = row(&live, "Sub");
    assert_eq!([hit.created, hit.modified, hit.opened], second);
    assert_eq!(row(&live, "DELTA.Txt").name, "DELTA.Txt");
    let old = held
        .rows(0, 100)
        .into_iter()
        .find(|h| h.name == "Sub")
        .unwrap();
    assert_eq!([old.created, old.modified, old.opened], first);
    let third = [1_620_000_010, first[1], 1_620_000_030];
    dates(&path, third);
    let real = PathBuf::from(tree.real()).join("Sub");
    let fetched = live.fetch(real.as_os_str().as_bytes(), false, &disk);
    live.apply(fetched, &disk);
    let hit = row(&live, "Sub");
    assert_eq!([hit.created, hit.modified, hit.opened], third);
    let compact = Live::new(Arc::new(
        Index::build(live.to_crawl(), PathBuf::from(tree.real()), b"", 1, 1).unwrap(),
    ));
    assert_eq!(row(&compact, "Sub"), hit);
    assert_eq!(row(&compact, "DELTA.Txt").name, "DELTA.Txt");
    assert!(live.fetch_changed(tree.real().as_bytes(), &disk).is_none());
}

#[test]
fn columns_new_file_has_created() {
    let tree = TempTree::new("columns-new");
    let mut live = live(&tree);
    let start = now_secs() as i64;
    let path = tree.0.join("New.txt");
    fs::write(&path, b"new").unwrap();
    refresh(&mut live, &tree);
    let hit = row(&live, "New.txt");
    use std::os::macos::fs::MetadataExt;
    assert_eq!(
        hit.created,
        fs::symlink_metadata(&path).unwrap().st_birthtime()
    );
    assert!(hit.created >= start);
}

fn sorted(column: EngineColumn, ascending: bool, folders_first: bool) -> Vec<EngineHit> {
    let mut listing = Listing::default();
    for (i, name) in ["z-folder", "a-file", "b-link", "c-folder", "d-file"]
        .iter()
        .enumerate()
    {
        let attrs = Attrs {
            kind: if name.ends_with("folder") {
                EngineKind::Folder
            } else if name.ends_with("link") {
                EngineKind::Link
            } else {
                EngineKind::File
            },
            size: i as u64,
            mtime: i as i64,
            created: [3, 1, 4, 0, 2][i],
            opened: [2, 0, 3, 4, 1][i],
            mount: false,
            hidden: false,
        };
        listing.push(name.as_bytes(), attrs, NONE);
    }
    let index = Index::build(
        crawl::Crawl {
            listings: vec![listing],
            failed: vec![],
        },
        PathBuf::from("/columns"),
        b"",
        0,
        0,
    )
    .unwrap();
    let live = Live::new(Arc::new(index));
    let (scanned, _) = Live::find_units("", false, &[&live], || false).unwrap();
    Results::new(
        1,
        Query::parse("", "/"),
        scanned,
        EngineSort {
            column,
            ascending,
            folders_first,
        },
        &Opens::new(PathBuf::from("/nonexistent/columns")),
        &|| false,
    )
    .unwrap()
    .rows(0, 10)
}

#[test]
fn columns_dates_sort_both_directions() {
    for (column, names) in [
        (
            EngineColumn::Created,
            ["c-folder", "a-file", "d-file", "z-folder", "b-link"],
        ),
        (
            EngineColumn::Opened,
            ["a-file", "d-file", "z-folder", "b-link", "c-folder"],
        ),
    ] {
        for ascending in [true, false] {
            let mut expected = names.to_vec();
            if !ascending {
                expected.reverse();
            }
            assert_eq!(
                sorted(column, ascending, false)
                    .iter()
                    .map(|h| h.name.as_str())
                    .collect::<Vec<_>>(),
                expected,
                "{column:?} {ascending}"
            );
        }
    }
}

#[test]
fn columns_folders_first_preserves_each_group_in_every_order() {
    for column in [
        EngineColumn::Relevance,
        EngineColumn::Name,
        EngineColumn::Folder,
        EngineColumn::Size,
        EngineColumn::Modified,
        EngineColumn::Created,
        EngineColumn::Opened,
        EngineColumn::Kind,
    ] {
        for ascending in [true, false] {
            let off = sorted(column, ascending, false);
            let expected: Vec<_> = off
                .iter()
                .filter(|h| h.kind == EngineKind::Folder)
                .chain(off.iter().filter(|h| h.kind != EngineKind::Folder))
                .cloned()
                .collect();
            assert_eq!(
                sorted(column, ascending, true),
                expected,
                "{column:?} {ascending}"
            );
            assert_eq!(sorted(column, ascending, false), off);
        }
    }
}
