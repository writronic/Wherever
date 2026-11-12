mod common;

use std::path::Path;

use common::start;
use wherever_cli::UNREACHABLE;
use wherever_core::{EngineColumn, EngineHit, EngineKind, EngineSort};

const BEST_MATCH: EngineSort = EngineSort {
    column: EngineColumn::Relevance,
    ascending: false,
    folders_first: false,
};

fn json(h: &EngineHit) -> String {
    let path = Path::new(&h.folder).join(&h.name);
    let kind = match h.kind {
        EngineKind::File => "file",
        EngineKind::Folder => "folder",
        EngineKind::Link => "link",
    };
    format!(
        "{{\"path\":\"{}\",\"name\":\"{}\",\"folder\":\"{}\",\"kind\":\"{kind}\",\"size\":{},\"modified\":{},\"created\":{},\"opened\":{}}}",
        path.display(),
        h.name,
        h.folder,
        h.size,
        h.modified,
        h.created,
        h.opened
    )
}

#[test]
fn the_command_line_answers_as_the_app_does() {
    let f = start(
        &["Out"],
        &[
            ("Alpha.txt", 5),
            ("beta.txt", 0),
            ("Sub/delta.txt", 0),
            ("Out/kept-out.txt", 0),
            ("explorer.md", 0),
            ("small.bin", 100),
            ("big.bin", 300),
            ("mid.bin", 200),
        ],
    );
    f.engine.serve_command_line(true).unwrap();
    let tree = &f.dirs.tree;

    let (code, out, err) = f.cli(&["--json", "txt"]);
    assert_eq!((code, err.as_str()), (0, ""));
    let session: Vec<String> = f.session_rows("txt", BEST_MATCH).iter().map(json).collect();
    assert_eq!(session.len(), 3, "{session:?}");
    assert_eq!(out.lines().collect::<Vec<_>>(), session);
    assert!(!out.contains("kept-out"), "{out}");

    assert_eq!(f.cli(&["epxlorer"]), (1, String::new(), String::new()));
    f.engine.set_typos(true).unwrap();
    let (code, out, _) = f.cli(&["epxlorer"]);
    let explorer = tree.join("explorer.md");
    assert_eq!((code, out.lines().next()), (0, explorer.to_str()));
    f.engine.set_typos(false).unwrap();

    let sub = tree.join("Sub");
    let (code, out, _) = f.cli(&["--in", sub.to_str().unwrap(), "txt"]);
    assert_eq!(
        (code, out),
        (0, format!("{}\n", sub.join("delta.txt").display()))
    );

    let first = |args: &[&str]| f.cli(args).1.lines().next().map(str::to_owned);
    let path = |name: &str| Some(tree.join(name).to_str().unwrap().to_owned());
    assert_eq!(first(&["--sort", "size", "ext:bin"]), path("big.bin"));
    assert_eq!(
        first(&["--sort", "size", "-r", "ext:bin"]),
        path("small.bin")
    );

    assert_eq!(f.cli(&["zzqqxx"]), (1, String::new(), String::new()));
}

#[test]
fn without_serving_the_command_line_cannot_reach_the_app() {
    let f = start(&[], &[("a.txt", 0)]);
    let unreachable = (2, String::new(), format!("wherever: {UNREACHABLE}\n"));
    assert_eq!(f.cli(&["txt"]), unreachable);
    f.engine.serve_command_line(true).unwrap();
    let (code, out, _) = f.cli(&["txt"]);
    assert_eq!(
        (code, out),
        (0, format!("{}\n", f.dirs.tree.join("a.txt").display()))
    );
    f.engine.serve_command_line(false).unwrap();
    assert_eq!(f.cli(&["txt"]), unreachable);
}
