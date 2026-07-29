// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Printing that survives its reader going away.
//!
//! `4dgs inspect big.4dgs | head -5` closes the pipe while the tool is still writing, and
//! so does `| grep -q`, which exits on its first match. Rust's `println!` panics on the
//! `EPIPE` that follows — exit 101, a backtrace note, and a failed step in anything using
//! `pipefail`. No other tool in a pipeline behaves that way: the reader leaving is how
//! pipelines end, not an error in the writer.
//!
//! So every line of output goes through `out!`, which stops the process quietly when the
//! reader is gone and reports anything else. Doing this without a signal-handling
//! dependency is the reason it is a macro over `writeln!` rather than a `SIGPIPE` reset.

/// `println!` that exits quietly when the reader has closed the pipe.
macro_rules! out {
    () => { out!("") };
    ($($arg:tt)*) => {{
        use std::io::Write;
        let mut lock = std::io::stdout().lock();
        if let Err(error) = writeln!(lock, $($arg)*) {
            $crate::out::stop_or_report(error);
        }
    }};
}

/// A closed pipe ends the process with success; anything else is a real write failure and
/// says so on stderr.
///
/// Success rather than 141: a shell reports a signal-killed writer as 141 and `pipefail`
/// turns that into a failed pipeline, which would make `4dgs info x | head` an error in
/// every script that used it. The reader got what it asked for, so the run worked.
pub fn stop_or_report(error: std::io::Error) -> ! {
    if error.kind() == std::io::ErrorKind::BrokenPipe {
        std::process::exit(crate::EXIT_OK as i32);
    }
    eprintln!("4dgs: cannot write output: {error}");
    std::process::exit(crate::EXIT_FAILED as i32);
}

/// The same, for output written in one piece rather than by line.
pub fn write_all(text: &str) {
    use std::io::Write;
    let mut lock = std::io::stdout().lock();
    if let Err(error) = lock.write_all(text.as_bytes()) {
        stop_or_report(error);
    }
}
