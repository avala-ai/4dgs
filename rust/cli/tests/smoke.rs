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

/// The variants this suite selects on, by the property each one has to have.
///
/// A corpus variant's name is a list of the properties it was built with, so selecting on
/// the property is both what the test means and what survives the corpus growing. Naming a
/// whole filename couples the suite to a file list that is generated and expected to
/// change; this couples it to the property the assertion is actually about.
/// Substrings a variant's name must have, and substrings it must not.
type Selector = (&'static [&'static str], &'static [&'static str]);

const SH_DEGREE_2: Selector = (&["SHDegree2", "UseChunkIndex", "UseCrc"], &[]);
const WITH_AUDIO: Selector = (&["WithAudio"], &[]);
const CUSTOM_CUTOFF: Selector = (&["CustomCutoff"], &[]);
const INDEXED: Selector = (&["UseChunkIndex"], &["WithAudio"]);
const NO_INDEX: Selector = (&[], &["UseChunkIndex"]);

/// Every selector above, so the CI check can prove each one still resolves.
const SELECTORS: [(&str, Selector); 5] = [
    ("SH_DEGREE_2", SH_DEGREE_2),
    ("WITH_AUDIO", WITH_AUDIO),
    ("CUSTOM_CUTOFF", CUSTOM_CUTOFF),
    ("INDEXED", INDEXED),
    ("NO_INDEX", NO_INDEX),
];

/// The first corpus file, in name order, carrying every `must` property and none of the
/// `must_not` ones. Sorted so that a growing corpus does not change which file is chosen
/// while an existing one still matches.
fn file(selector: Selector) -> Option<PathBuf> {
    let (must, must_not) = selector;
    let dir = corpus()?;
    let mut names: Vec<String> = dir
        .read_dir()
        .ok()?
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "4dgs"))
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|name| {
            must.iter().all(|part| name.contains(part))
                && !must_not.iter().any(|part| name.contains(part))
        })
        .collect();
    names.sort();
    names.first().map(|name| dir.join(name))
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
    let Some(path) = file(SH_DEGREE_2) else {
        return;
    };
    let out = run(&["info", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0));
    let text = stdout(&out);
    // Each of these is a property the file was selected for, so the assertion and the
    // selector cannot drift apart: `SHDegree2` means degree 2, `UseCrc` means the summary
    // checksum is there and agrees, `UseChunkIndex` means there is something to seek in.
    assert!(text.contains("spherical harm degree 2"), "{text}");
    assert!(text.contains("summary crc    ok"), "{text}");
    assert!(text.contains("seek cost"), "{text}");
}

#[test]
fn info_names_the_audio_codec_from_the_header_alone() {
    let Some(path) = file(WITH_AUDIO) else {
        return;
    };
    let text = stdout(&run(&["info", path.to_str().unwrap()]));
    assert!(text.contains("audio          "), "{text}");
    assert!(!text.contains("audio          none"), "{text}");
}

#[test]
fn validate_passes_the_corpus_and_says_why_when_it_does_not() {
    let Some(path) = file(INDEXED) else {
        return;
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0), "{}", stdout(&out));
    assert_eq!(stdout(&out).trim(), "valid");
}

#[test]
fn a_file_with_no_index_is_valid_with_a_warning_and_its_own_exit_code() {
    let Some(path) = file(NO_INDEX) else {
        return;
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(2), "{}", stdout(&out));
    assert!(stdout(&out).contains("warning: no chunk index"));
}

#[test]
fn inspect_walks_the_framing_and_json_says_the_same_thing() {
    let Some(path) = file(WITH_AUDIO) else {
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
    let Some(path) = file(INDEXED) else {
        return;
    };
    let out = run(&["decode", path.to_str().unwrap(), "-t", "0.5", "--json"]);
    assert_eq!(out.status.code(), Some(0));
    let json = stdout(&out);
    assert!(json.contains("\"time\": 0.5"), "{json}");

    // `total` is the file's declared count, so it does not move with the seek — and the
    // count itself comes from `info` rather than from a literal, which makes this the
    // cross-command invariant it was trying to be rather than a note about one variant.
    let declared: u64 = stdout(&run(&["info", path.to_str().unwrap()]))
        .lines()
        .find_map(|l| l.strip_prefix("gaussians      "))
        .map(|n| n.replace(',', ""))
        .and_then(|n| n.parse().ok())
        .expect("a gaussian count from info");
    assert_eq!(field(&json, "total"), declared, "{json}");
    let visible = field(&json, "visible");
    assert!(visible > 0 && visible <= declared, "{json}");
}

#[test]
fn decode_honours_the_header_cutoff_rather_than_the_default() {
    let Some(path) = file(CUSTOM_CUTOFF) else {
        return;
    };
    let text = stdout(&run(&["decode", path.to_str().unwrap(), "-t", "0.5"]));
    // The variant exists because its Header declares a cutoff of its own, so what this
    // asserts is that the printed cutoff is that one and not the format's default —
    // decoding against the default is the bug, and its value is what the file says, not
    // what this test remembers.
    let cutoff = text
        .lines()
        .find_map(|l| l.strip_prefix("cutoff         "))
        .expect("a cutoff line");
    assert_ne!(cutoff.trim(), "0.05", "the default cutoff, not the file's");
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

#[test]
fn a_reader_that_goes_away_is_not_an_error() {
    let Some(path) = file(INDEXED) else {
        return;
    };
    // `4dgs info x | grep -q y` closes the pipe on grep's first match, and `| head` closes
    // it after n lines. Rust's `println!` panics on the write that follows — exit 101 —
    // which took a CI step red on the leg whose scheduler let grep exit first.
    //
    // Closing the read end before the child writes is the same condition without the
    // race, and it is not probabilistic: against the code that had this bug it reproduced
    // 40 times out of 40. The loop is here because a scheduler is still involved, not
    // because one run would be inconclusive.
    for _ in 0..5 {
        let mut child = Command::new(BIN)
            .args(["info", path.to_str().unwrap()])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("the binary this test was built alongside");
        drop(child.stdout.take());
        let status = child.wait().expect("the child to exit");
        assert_ne!(
            status.code(),
            Some(101),
            "a closed pipe panicked instead of ending the run"
        );
        assert!(
            matches!(status.code(), Some(0) | None),
            "a closed pipe should end the run quietly, got {status:?}"
        );
    }
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
    // And every selector still names something. Without this a renamed variant would take
    // its test out of the run silently, which is the shape of green this repo keeps
    // finding: a suite that passed by testing nothing.
    for (name, selector) in SELECTORS {
        assert!(
            file(selector).is_some(),
            "no corpus variant matches {name}; the corpus was renamed under this suite"
        );
    }
}

/// One unsigned field out of the tool's own JSON. Enough for `{"key": 123}` one per line,
/// which is the only shape this suite reads.
fn field(json: &str, key: &str) -> u64 {
    json.lines()
        .find_map(|l| l.trim().strip_prefix(&format!("\"{key}\": ")))
        .map(|v| v.trim_end_matches(','))
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| panic!("no {key} in {json}"))
}
