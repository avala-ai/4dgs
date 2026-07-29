// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! All four commands over real corpus files.
//!
//! What can break in a tool this thin is the shell around the library — argument handling,
//! exit codes, and the fields it prints — so that is what these assert: a couple of stable
//! values per command rather than whole transcripts, which would fail on every wording
//! change and prove nothing about the decode.
//!
//! The corpus is generated rather than committed, so these tests skip when it is absent —
//! a contributor who has not run the generator gets a green `cargo test`, and CI runs the
//! generator first, which is where the skip is not allowed to happen. The count is
//! asserted at the end for exactly that reason: a suite that quietly tested nothing is
//! worse than no suite.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const BIN: &str = env!("CARGO_BIN_EXE_4dgs");

fn corpus() -> Option<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/data")
        .canonicalize()
        .ok()?;
    dir.read_dir()
        .ok()?
        .flatten()
        .any(|e| e.path().extension().is_some_and(|x| x == "4dgs"))
        .then_some(dir)
}

fn file(name: &str) -> Option<PathBuf> {
    let path = corpus()?.join(format!("{name}.4dgs"));
    path.exists().then_some(path)
}

fn run(args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .output()
        .expect("the binary this test was built alongside")
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn info_reports_the_header_without_decoding_anything() {
    let Some(path) = file("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc") else {
        return;
    };
    let out = run(&["info", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0));
    let text = stdout(&out);
    // The variant's name is a promise about its content, and these are the two halves of
    // it that `info` is responsible for reading correctly.
    assert!(text.contains("spherical harm degree 2"), "{text}");
    assert!(text.contains("summary crc    ok"), "{text}");
    assert!(text.contains("seek cost"), "{text}");
}

#[test]
fn info_names_the_audio_codec_from_the_header_alone() {
    let Some(path) = file("OneWindow-UseChunkIndex-UseCrc-WithAudio") else {
        return;
    };
    let text = stdout(&run(&["info", path.to_str().unwrap()]));
    assert!(text.contains("audio          "), "{text}");
    assert!(!text.contains("audio          none"), "{text}");
}

#[test]
fn validate_passes_the_corpus_and_says_why_when_it_does_not() {
    let Some(path) = file("MixedLifetimes-UseChunkIndex-UseCrc") else {
        return;
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "{}", stdout(&out));
    assert_eq!(stdout(&out).trim(), "valid");
}

#[test]
fn a_file_with_no_index_is_valid_with_a_warning_and_its_own_exit_code() {
    let Some(path) = file("TenWindows-UseCrc") else {
        return;
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(2), "{}", stdout(&out));
    assert!(stdout(&out).contains("warning: no chunk index"));
}

#[test]
fn inspect_walks_the_framing_and_json_says_the_same_thing() {
    let Some(path) = file("OneWindow-UseChunkIndex-UseCrc-WithAudio") else {
        return;
    };
    let text = stdout(&run(&["inspect", path.to_str().unwrap()]));
    assert!(text.contains("Header"), "{text}");
    assert!(text.contains("Footer"), "{text}");
    // Framed, not fetched: the audio record is named without its track being read.
    assert!(text.contains("Audio"), "{text}");

    let json = stdout(&run(&["inspect", "--json", path.to_str().unwrap()]));
    assert!(json.contains("\"trailing_magic\": true"), "{json}");
    assert!(json.contains("\"stopped\": null"), "{json}");
    assert!(json.contains("\"name\": \"Header\""), "{json}");
    let counted: usize = text
        .lines()
        .find(|l| l.contains(" records, "))
        .and_then(|l| l.split_whitespace().next()?.parse().ok())
        .expect("a record count");
    assert_eq!(
        counted,
        json.matches("\"offset\":").count(),
        "the two renderings must list the same records"
    );
}

#[test]
fn decode_reports_state_at_an_instant() {
    let Some(path) = file("MixedLifetimes-UseChunkIndex-UseCrc") else {
        return;
    };
    let out = run(&["decode", path.to_str().unwrap(), "-t", "0.5", "--json"]);
    assert_eq!(out.status.code(), Some(0));
    let json = stdout(&out);
    assert!(json.contains("\"time\": 0.5"), "{json}");
    // `total` is the file's declared count, so it does not move with the seek.
    assert!(json.contains("\"total\": 512"), "{json}");
    let visible: u64 = json
        .lines()
        .find(|l| l.contains("\"visible\""))
        .and_then(|l| {
            l.trim()
                .trim_end_matches(',')
                .rsplit(' ')
                .next()?
                .parse()
                .ok()
        })
        .expect("a visible count");
    assert!(visible > 0 && visible <= 512, "{json}");
}

#[test]
fn decode_honours_the_header_cutoff_rather_than_the_default() {
    let Some(path) = file("MixedLifetimes-CustomCutoff-UseChunkIndex-UseCrc") else {
        return;
    };
    let text = stdout(&run(&["decode", path.to_str().unwrap(), "-t", "0.5"]));
    // The variant exists because its Header declares a cutoff of its own; decoding it
    // against the format's default is the bug this asserts against.
    assert!(text.contains("cutoff         0.2"), "{text}");
}

#[test]
fn a_file_that_is_not_ours_is_refused_by_every_command() {
    let path = std::env::temp_dir().join("fourdgs-cli-not-ours.bin");
    std::fs::write(&path, b"this is not a 4dgs file, it is a sentence").unwrap();
    for command in ["info", "validate", "inspect", "decode"] {
        let out = run(&[command, path.to_str().unwrap()]);
        assert_eq!(
            out.status.code(),
            Some(1),
            "`{command}` accepted a file that is not ours"
        );
    }
    std::fs::remove_file(&path).ok();
}

#[test]
fn the_usage_message_is_served_rather_than_run() {
    let out = run(&["--help"]);
    assert_eq!(out.status.code(), Some(0));
    assert!(stdout(&out).contains("4dgs info"));
    assert_eq!(run(&["--version"]).status.code(), Some(0));
    assert_eq!(run(&["frobnicate", "x"]).status.code(), Some(1));
}

/// CI generates the corpus before this suite, so a run with nothing to decode there is a
/// green suite that proved nothing. This is the assertion that stops it.
#[test]
fn the_corpus_is_present_in_ci() {
    if std::env::var_os("CI").is_none() {
        return;
    }
    assert!(
        corpus().is_some(),
        "no corpus: run tests/conformance/generate.py before the suite"
    );
}
