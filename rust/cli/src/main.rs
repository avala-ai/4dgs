// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! `4dgs`: read, inspect and check `.4dgs` files from a shell.
//!
//! Thin by design — every command is a few lines over the library, so anything the CLI can
//! do is something a caller can do. That rule is the Python tool's, and it is repeated
//! here because it is what keeps a command-line tool from becoming a second, undocumented
//! implementation of the format.
//!
//! The two tools are expected to agree. Where a command exists in both, it reads the same
//! records, prints the same values in the same order, and exits the same way; a difference
//! between them on one file is a bug in one of them, not a matter of taste.

// Declared first: the modules below print through its macro.
#[macro_use]
mod out;
mod args;
mod commands;
mod validate;

use std::process::ExitCode;

use args::{Args, Command};

/// Exit codes, which are the only part of a CLI another program reads.
///
/// A validator that answered 0 for "some warnings" and 0 for "nothing to say" would make
/// the warnings unreachable from a script, so they get their own code.
pub const EXIT_OK: u8 = 0;
pub const EXIT_FAILED: u8 = 1;
pub const EXIT_WARNINGS: u8 = 2;

const USAGE: &str = "\
4dgs — read and inspect .4dgs files

usage:
  4dgs info <file> [--names]         summarize a file and what seeking it costs
  4dgs validate <file>               check a file against the specification
  4dgs inspect <file> [--json]       walk the records: offset, opcode, length
  4dgs decode <file> [-t <sec>]      report the gaussians visible at an instant
  4dgs --version
  4dgs --help

options:
  --json          machine-readable output (inspect, decode)
  --names         also list metadata and attachment names (info); off by default
                  because reading an attachment's name reads its payload too
  -t, --time      the instant to decode, in seconds (default 0)

exit codes:
  0  fine       1  refused, or invalid       2  valid, with warnings
";

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = match Args::parse(&argv) {
        Ok(Some(args)) => args,
        // `--help` and `--version` are a request that was served, not a failure.
        Ok(None) => return ExitCode::from(EXIT_OK),
        Err(message) => {
            eprintln!("4dgs: {message}");
            eprintln!("\n{USAGE}");
            return ExitCode::from(EXIT_FAILED);
        }
    };

    let outcome = match &args.command {
        Command::Info => commands::info(&args),
        Command::Validate => validate::run(&args),
        Command::Inspect => commands::inspect(&args),
        Command::Decode => commands::decode(&args),
    };
    match outcome {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            // The library's errors already name the field, the value and what was
            // expected, so the file is the only thing left to add.
            eprintln!("4dgs: {}: {error}", args.file);
            ExitCode::from(EXIT_FAILED)
        }
    }
}

/// A count with thousands separators, matching the Python tool's `{:,}`.
pub fn commas(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// Four decimal places with the trailing zeros dropped, which is what Python's
/// `round(v, 4)` prints for every value a header carries.
pub fn round4(v: f64) -> String {
    if !v.is_finite() {
        return format!("{v}");
    }
    let mut s = format!("{v:.4}");
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.push('0');
        }
    }
    s
}

/// A string as a JSON string. The only escapes a record's fields can need are these:
/// names and codecs are UTF-8, and control characters are spelled `\u00XX`.
pub fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn print_usage() {
    out::write_all(USAGE);
}
