#[allow(dead_code)]
mod common;

use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;

use common::start;

#[test]
fn a_client_that_closes_early_leaves_the_app_running() {
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    let files: Vec<(String, usize)> = (0..5000).map(|i| (format!("row-{i:04}.dat"), 0)).collect();
    let f = start(&[], &files);
    f.engine.serve_command_line(true).unwrap();

    let mut stream = UnixStream::connect(f.socket()).unwrap();
    stream
        .write_all("WHV1|dat|name|0|0|0|".replace('|', "\0").as_bytes())
        .unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    let (mut got, mut byte) = (Vec::new(), [0u8]);
    while got.iter().filter(|&&b| b == 0).count() < 12 {
        stream.read_exact(&mut byte).unwrap();
        got.push(byte[0]);
    }
    assert!(got.starts_with(b"WHV1\0ok\x005000\0"), "{got:?}");
    drop(stream);

    let (code, out, err) = f.cli(&["-n", "0", "dat"]);
    assert_eq!((code, err.as_str()), (0, ""));
    assert_eq!(out.lines().count(), 5000);
}
