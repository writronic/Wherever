use std::io::{self, BufWriter, IsTerminal};
use std::process::ExitCode;

use wherever_cli::{Env, run, socket};

fn main() -> ExitCode {
    let Ok(args) = (std::env::args_os().skip(1))
        .map(|a| a.into_string())
        .collect::<Result<Vec<_>, _>>()
    else {
        eprintln!("wherever: an argument is not valid UTF-8.");
        return ExitCode::from(2);
    };
    let Some(socket) = socket() else {
        eprintln!("wherever: cannot find your per-user cache folder.");
        return ExitCode::from(2);
    };
    let stdout = io::stdout();
    let terminal = stdout.is_terminal();
    let mut out = BufWriter::new(stdout.lock());
    let code = run(
        &args,
        &mut out,
        &mut io::stderr(),
        &socket,
        terminal,
        &Env::current(),
    );
    ExitCode::from(code as u8)
}
