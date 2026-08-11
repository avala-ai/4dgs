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
const WITH_AUDIO: Selector = (&["WithSpatialAudio"], &[]);
const CUSTOM_CUTOFF: Selector = (&["CustomCutoff"], &[]);
const INDEXED: Selector = (
    &["UseChunkIndex"],
    &["WithSpatialAudio", "WithMultipleAudioSources"],
);
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
fn info_names_the_audio_source_count_from_the_header_walk() {
    let Some(path) = file(WITH_AUDIO) else {
        return;
    };
    let text = stdout(&run(&["info", path.to_str().unwrap()]));
    assert!(text.contains("audio sources  1"), "{text}");
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
    // 3, not 1: a command nobody can parse is the absence of an answer about a file, and
    // exit 1 is an answer about a file. See `EXIT_TOOL`.
    assert_eq!(run(&["frobnicate", "x"]).status.code(), Some(3));
}

#[test]
fn a_file_the_tool_cannot_read_is_told_apart_from_a_file_it_refuses() {
    // The distinction the exit codes exist for. A pipeline that saw 1 for both could not
    // tell a corrupt asset from a typo in a path, which makes the tool indistinguishable
    // from a broken one on the day it matters.
    let missing = std::env::temp_dir().join("fourdgs-cli-no-such-file.4dgs");
    std::fs::remove_file(&missing).ok();
    for command in ["info", "validate", "inspect", "decode"] {
        let out = run(&[command, missing.to_str().unwrap()]);
        assert_eq!(
            out.status.code(),
            Some(3),
            "`{command}` reported a missing file as a verdict on its contents"
        );
    }
}

// ---------------------------------------------------------------------------------------
// The refusal corpus knows the right answer; this is the tool checked against it.

/// The refusal identifier the corpus says a reader must produce for this variant.
///
/// The expectation is read from the corpus rather than written here, so a test that
/// asserted the wrong identifier would have to be wrong in the same way the generator is.
/// The file is `{"refused": "<id>"}` and nothing else, which is under the bar for a JSON
/// dependency in a tool whose whole point is a small dependency tree.
fn expected_refusal(json_path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(json_path).ok()?;
    let rest = text.split("\"refused\"").nth(1)?;
    let rest = rest.split(':').nth(1)?;
    let start = rest.find('"')? + 1;
    let end = rest[start..].find('"')? + start;
    Some(rest[start..end].to_string())
}

/// Every file in the invalid corpus, with the identifier it must be refused for.
fn invalid_corpus() -> Vec<(String, PathBuf, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data/invalid");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<(String, PathBuf, String)> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "4dgs"))
        .filter_map(|p| {
            let code = expected_refusal(&p.with_extension("json"))?;
            let name = p.file_stem()?.to_string_lossy().into_owned();
            Some((name, p, code))
        })
        .collect();
    out.sort();
    out
}

#[test]
fn every_invalid_variant_is_refused_by_its_own_identifier() {
    // The strongest evidence there is that this tool is right, because the corpus already
    // knows the answer and the tool had no hand in writing it. "Refused" alone is not the
    // property: a reader that refuses every one of these for the wrong reason passes a
    // test that only checks the exit code, and that is precisely the failure the invalid
    // corpus was built to catch.
    let corpus = invalid_corpus();
    if corpus.is_empty() {
        assert!(
            std::env::var_os("CI").is_none(),
            "CI generates the corpus before this suite, so an empty one is a test that \
             silently did not run"
        );
        return;
    }
    for (name, path, code) in &corpus {
        let out = run(&["validate", path.to_str().unwrap()]);
        let text = stdout(&out);
        assert_eq!(
            out.status.code(),
            Some(1),
            "{name} must be refused, and non-zero is how a pipeline learns it: {text}"
        );
        assert!(
            text.contains(&format!("refusal {code}")),
            "{name} must be refused as `{code}`, and the tool said: {text}"
        );
        // And the byte, which is the question its holder actually has. Every one of these
        // is placeable: four in the front matter, two inside a chunk the tool decodes.
        assert!(
            text.contains(&format!("refusal {code} at byte ")),
            "{name} named the refusal but not where it fired: {text}"
        );
    }
    assert_eq!(
        corpus.len(),
        7,
        "the invalid corpus is seven variants; a run that saw a different number is \
         checking a corpus this test has not been read against"
    );
}

// ---------------------------------------------------------------------------------------
// A fault inside a stream, in each of the places a stream can be.
//
// The framing walk steps over a record by its declared length, so nothing above this line
// can see inside one. These take a conforming corpus file, make exactly one stream
// undecodable, and require the tool to say so — with the identifier the corpus uses for
// that fault and the byte of the record the fault is actually in.

/// Every top-level record: its opcode, where it starts, and how long its content is.
///
/// The framing, done by hand, because the point of these tests is to reach a byte inside a
/// record and the tool's own walk is one of the things under test.
fn framing(data: &[u8]) -> Vec<(u8, usize, usize)> {
    let mut out = Vec::new();
    let mut at = 8usize;
    while at + 9 <= data.len().saturating_sub(8) {
        let opcode = data[at];
        let length = u64::from_le_bytes(data[at + 1..at + 9].try_into().unwrap()) as usize;
        out.push((opcode, at, length));
        let Some(next) = at.checked_add(9 + length).filter(|n| *n <= data.len()) else {
            break;
        };
        at = next;
    }
    out
}

/// Make the first record with this opcode declare a stream codec no build implements.
///
/// Returns the record's offset. A stream header is `attribute_id, width, mode,
/// stream_codec, channels`, so this is one byte — the same fault the corpus's
/// `UnknownStreamCodec` variant carries, moved into whichever record the caller names.
fn break_the_codec_in(data: &mut [u8], opcode: u8) -> Option<u64> {
    let (_, at, length) = framing(data).into_iter().find(|(o, ..)| *o == opcode)?;
    let content = &data[at + 9..at + 9 + length];
    let stream_at = match opcode {
        // A Chunk's streams follow its header, whose length varies with the compression
        // name it carries — so the library is what says where they start.
        0x05 => {
            let (_, streams) = fourdgs::records::parse_chunk(content).ok()?;
            content.len() - streams.len()
        }
        // An SH Band Stream record is the band index, then the stream (spec §5.7).
        0x07 => 1,
        _ => return None,
    };
    data[at + 9 + stream_at + 3] = 9;
    Some(at as u64)
}

/// A corpus file with one byte changed, written where a test can hand it to the tool.
fn broken_copy(source: &Path, name: &str, opcode: u8) -> Option<(PathBuf, u64)> {
    let mut data = std::fs::read(source).ok()?;
    let at = break_the_codec_in(&mut data, opcode)?;
    let path = std::env::temp_dir().join(name);
    std::fs::write(&path, &data).ok()?;
    Some((path, at))
}

#[test]
fn a_fault_inside_a_spherical_harmonic_band_is_not_reported_valid() {
    // Bands were fetched at a cap of 0 — a rendering choice, applied to a question that is
    // not about rendering. An SH Band Stream is a stream like any other, so a band record
    // carrying a codec this build does not implement is a file that does not decode; with
    // the cap in place the tool decoded the base chunk, found it healthy, and printed
    // `valid`. And the byte names the band record, not the Chunk it belongs to: the two
    // are thousands of bytes apart, and the Chunk's own streams are fine.
    let Some(source) = file(SH_DEGREE_2) else {
        return;
    };
    let Some((path, at)) = broken_copy(&source, "fourdgs-cli-bad-band.4dgs", 0x07) else {
        panic!("the SHDegree2 variant carries SH Band Stream records");
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {at} ")),
        "{text}"
    );
    assert!(text.contains("SH Band Stream for band"), "{text}");
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_file_with_no_index_names_the_chunk_it_could_not_decode() {
    // Without an index there is nothing to seek with, so this file used to be decoded in
    // one call that either succeeded or failed — which meant the whole scene resident, and
    // a refusal with no byte at all to report. It is walked record by record now, so the
    // Chunk that refused is the Chunk the report names, and nothing is held past it.
    let Some(source) = file(NO_INDEX) else {
        return;
    };
    let Some((path, at)) = broken_copy(&source, "fourdgs-cli-bad-unindexed.4dgs", 0x05) else {
        panic!("every corpus variant carries Chunk records");
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {at} ")),
        "{text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_keyframe_delta_chunk_that_does_not_decode_is_named_and_placed() {
    // The keyframe-delta branch composed the whole sequence in one call, so a refusal
    // inside one chunk's streams arrived with no entry to attribute it to and printed the
    // identifier with no byte — below the contract the rest of this tool now holds. It
    // composes one chain at a time, which is what the report needs and what keeps a long
    // sequence from being resident all at once.
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data/keyframe");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        assert!(std::env::var_os("CI").is_none(), "CI generates the corpus");
        return;
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "4dgs"))
        .collect();
    paths.sort();
    let source = paths.first().expect("a keyframe-delta variant");
    let Some((path, at)) = broken_copy(source, "fourdgs-cli-bad-keyframe.4dgs", 0x05) else {
        panic!("a keyframe-delta file carries Chunk records; they are its keyframes");
    };
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {at} ")),
        "{text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_file_cut_inside_its_own_footer_is_still_reported_record_by_record() {
    // The one truncation point that used to take `inspect` out through the error path
    // before it printed a row. The Footer is where the summary checksum is declared, so
    // the tool reads it to say which records that checksum covers — and asking for a
    // record the file was cut inside returns `Truncated`, losing the intact-prefix report
    // for precisely the file the report exists for.
    let Some(source) = file(INDEXED) else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    // The Footer's content is 20 bytes and the trailing magic is 8; cutting four bytes
    // into that content leaves the record framed and its content missing.
    let footer_at = data.len() - (9 + 20 + 8);
    assert_eq!(data[footer_at], 0x02, "the last record is the Footer");
    let path = std::env::temp_dir().join("fourdgs-cli-cut-footer.4dgs");
    std::fs::write(&path, &data[..footer_at + 9 + 4]).unwrap();

    let out = run(&["inspect", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "a cut file is not a whole one");
    assert!(text.contains("Header"), "{text}");
    assert!(text.contains("Footer"), "{text}");
    assert!(text.contains("truncated at byte"), "{text}");
    assert!(text.contains("intact prefix"), "{text}");
    // And no checksum verdict is invented for a Footer nobody could read.
    assert!(text.contains("declares no summary checksum"), "{text}");
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_conforming_keyframe_delta_file_is_valid() {
    // It was not, in either validator: every structural check assumed the gaussian-birth
    // chunk shape, so a file whose Chunks are keyframes and whose Delta Chunks are
    // differences came back with seven errors and an INVALID. The Rust core implements the
    // model — the conformance suite proves it — so refusing a file for declaring it was
    // never a statement about the file.
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data/keyframe");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        assert!(std::env::var_os("CI").is_none(), "CI generates the corpus");
        return;
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "4dgs"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no keyframe-delta variants to check");
    for path in &paths {
        let out = run(&["validate", path.to_str().unwrap()]);
        assert_eq!(
            out.status.code(),
            Some(0),
            "{} is a conforming file: {}",
            path.display(),
            stdout(&out)
        );
        assert_eq!(stdout(&out).trim(), "valid");
    }
}

#[test]
fn inspect_reports_the_crc_status_of_every_record() {
    let Some(path) = file(INDEXED) else {
        return;
    };
    let text = stdout(&run(&["inspect", path.to_str().unwrap()]));
    // The only checksum the format defines covers the summary, so the index rows are
    // covered and the Header is not — and saying so per record is what tells a reader
    // whether the checksum has anything to say about the row they are looking at.
    let cell = |record: &str| -> String {
        text.lines()
            .find(|l| l.contains(&format!(" {record} ")))
            .and_then(|l| l.split_whitespace().last())
            .unwrap_or_else(|| panic!("no {record} row in {text}"))
            .to_string()
    };
    assert_eq!(cell("ChunkIndex"), "ok", "{text}");
    assert_eq!(cell("Header"), "-", "{text}");
    assert!(
        text.contains("crc: the Footer's summary checksum covers"),
        "{text}"
    );

    let json = stdout(&run(&["inspect", "--json", path.to_str().unwrap()]));
    assert!(json.contains("\"crc\": \"ok\""), "{json}");
    assert!(json.contains("\"crc\": null"), "{json}");
    assert!(json.contains("\"ok\": true"), "{json}");
}

#[test]
fn a_corrupted_summary_is_reported_against_the_records_it_covers() {
    let Some(path) = file(INDEXED) else {
        return;
    };
    let mut data = std::fs::read(&path).unwrap();
    // Inside the first summary record's content rather than its framing: the walk still
    // ends where it should, and the checksum is the only thing that can notice.
    let tail = data.len() - (9 + 20 + 8);
    let summary_start = u64::from_le_bytes(data[tail + 9..tail + 17].try_into().unwrap()) as usize;
    assert!(summary_start > 0, "the variant was selected for its index");
    data[summary_start + 9 + 4] ^= 0xFF;
    let broken = std::env::temp_dir().join("fourdgs-cli-bad-summary.4dgs");
    std::fs::write(&broken, &data).unwrap();

    let text = stdout(&run(&["inspect", broken.to_str().unwrap()]));
    assert!(text.contains("MISMATCH"), "{text}");
    // And the framing is still whole, which is the distinction: a checksum that disagrees
    // says the index is untrustworthy, not that the file stopped being a 4dgs file.
    assert!(!text.contains("truncated at byte"), "{text}");
    std::fs::remove_file(&broken).ok();
}

#[test]
fn a_cut_file_reports_what_was_decodable_rather_than_only_that_it_stopped() {
    let Some(path) = file(INDEXED) else {
        return;
    };
    let data = std::fs::read(&path).unwrap();
    let cut = std::env::temp_dir().join("fourdgs-cli-cut.4dgs");
    std::fs::write(&cut, &data[..data.len() / 2]).unwrap();

    let out = run(&["inspect", cut.to_str().unwrap()]);
    let text = stdout(&out);
    assert!(text.contains("truncated at byte"), "{text}");
    assert!(text.contains("intact prefix"), "{text}");
    // Records, not one error line. Reporting only that the file stopped leaves its holder
    // to guess whether anything is salvageable, which is the question they had.
    assert!(text.contains("Header"), "{text}");
    assert!(text.contains("Quantization"), "{text}");
    assert_eq!(out.status.code(), Some(1), "a cut file is not a whole one");

    let notes = stdout(&run(&["validate", cut.to_str().unwrap()]));
    assert!(notes.contains("a streamed reader recovers them"), "{notes}");
    std::fs::remove_file(&cut).ok();
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
    // The keyframe-delta variants live in their own subdirectory and are selected by it
    // rather than by name, so they need their own guard. Six tests below are about that
    // model, and a moved subdirectory would take all six out of the run in silence.
    assert!(
        !keyframe_files().is_empty(),
        "no keyframe-delta variants; the corpus subdirectory moved under this suite"
    );
    assert!(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/conformance/data/invalid/UnknownStreamCodec.4dgs")
            .exists(),
        "no invalid corpus; the refusal tests below would skip themselves green"
    );
}

// ---------------------------------------------------------------------------------------
// Files no encoder writes.
//
// Every fixture below starts as a real corpus file and has one thing changed, because a
// fixture written from scratch tests the fixture. What is rewritten is the *summary region*
// — the run of chunk-index entries between `Footer.summary_start` and the Footer record —
// which is the only part of a file that can be replaced without moving a chunk: nothing
// points forward into it, and the Footer that follows it is rebuilt with its checksum.

/// The `keyframe-delta` corpus variants, which live in their own subdirectory.
fn keyframe_files() -> Vec<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data/keyframe");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "4dgs"))
        .collect();
    paths.sort();
    paths
}

/// The first one, in name order. `None` only when the corpus has not been generated, which
/// `the_corpus_is_present_in_ci` refuses to let happen where it matters.
fn keyframe_file() -> Option<PathBuf> {
    keyframe_files().into_iter().next()
}

/// Where a file's summary region begins and ends.
///
/// Both read out of the file: the Footer names `summary_start`, and the Footer record is
/// the last one before the trailing magic.
fn summary_bounds(data: &[u8]) -> (usize, usize) {
    let footer_at = data.len() - (9 + 20 + 8);
    assert_eq!(data[footer_at], 0x02, "the last record is the Footer");
    let footer = fourdgs::records::Footer::parse(&data[footer_at + 9..]).unwrap();
    (footer.summary_start as usize, footer_at)
}

/// A file made of this front matter and this summary, with a Footer that describes them.
///
/// An empty summary produces a file with no index at all — `summary_start` zero, no
/// checksum — which is the legal stream-only shape and not something the encoder emits.
fn rebuilt(front: &[u8], summary: &[u8]) -> Vec<u8> {
    let mut out = front.to_vec();
    out.extend_from_slice(summary);
    out.extend_from_slice(
        &fourdgs::records::Footer {
            summary_start: if summary.is_empty() {
                0
            } else {
                front.len() as u64
            },
            summary_offset_start: 0,
            summary_crc: if summary.is_empty() {
                0
            } else {
                fourdgs::serialization::crc32(summary)
            },
        }
        .encode(),
    );
    out.extend_from_slice(&fourdgs::serialization::MAGIC);
    out
}

/// The index entries of a file, and whatever else its summary region holds after them.
///
/// The remainder is returned verbatim rather than re-encoded — it is the Statistics record
/// on every variant that has one — so a fixture changes the entries and nothing else.
fn summary_parts(data: &[u8]) -> (Vec<fourdgs::records::ChunkIndexEntry>, Vec<u8>) {
    let (start, end) = summary_bounds(data);
    let mut entries = Vec::new();
    let mut at = start;
    for record in fourdgs::serialization::Records::new(&data[..end], start) {
        let record = record.expect("the summary region parses");
        if record.opcode != 0x08 {
            break;
        }
        entries.push(fourdgs::records::ChunkIndexEntry::parse(record.content).expect("an entry"));
        at = record.offset + 9 + record.content.len();
    }
    // Re-encoding has to be byte-stable, or every offset a fixture computes is wrong.
    let re: Vec<u8> = entries.iter().flat_map(|e| e.encode()).collect();
    assert_eq!(
        re.as_slice(),
        &data[start..at],
        "an index entry does not round-trip; the fixtures below rely on it"
    );
    (entries, data[at..end].to_vec())
}

/// An SH Band Stream record whose stream declares a codec no build implements.
///
/// Hand-written because no encoder emits one, and because the fault has to be the codec
/// rather than the framing: everything before the codec byte is well-formed, so a reader
/// that gets as far as decoding the stream is what this catches.
fn undecodable_band(band: u8, count: u32) -> Vec<u8> {
    let mut content = vec![band];
    content.push(0x07); // attribute id: the SH band attribute
    content.push(1); // symbol width
    content.push(0); // mode: raw
    content.push(0xEE); // codec: not one this build implements
    content.push(1); // channels
    content.extend_from_slice(&count.to_le_bytes());
    content.extend_from_slice(&1u64.to_le_bytes()); // payload length
    content.push(0);
    let mut out = vec![0x07u8]; // opcode: SH Band Stream
    out.extend_from_slice(&(content.len() as u64).to_le_bytes());
    out.extend_from_slice(&content);
    out
}

/// Write a fixture to the temporary directory and hand back its path.
fn fixture(name: &str, data: &[u8]) -> PathBuf {
    let path = std::env::temp_dir().join(name);
    std::fs::write(&path, data).unwrap();
    path
}

fn header_gaussian_count_offset(data: &[u8]) -> usize {
    let record = fourdgs::serialization::Records::new(data, fourdgs::serialization::MAGIC.len())
        .next()
        .expect("a Header record")
        .expect("the Header framing parses");
    assert_eq!(record.opcode, 0x01);
    let mut content = fourdgs::serialization::Cursor::new(record.content);
    content.string().unwrap();
    content.string().unwrap();
    content.f64().unwrap();
    record.offset + fourdgs::serialization::RECORD_HEADER_SIZE + content.position()
}

#[test]
fn keyframe_delta_header_count_is_the_distinct_identity_count() {
    let Some(source) = keyframe_file() else {
        return;
    };
    let mut data = std::fs::read(&source).unwrap();
    let at = header_gaussian_count_offset(&data);
    let declared = u64::from_le_bytes(data[at..at + 8].try_into().unwrap());
    data[at..at + 8].copy_from_slice(&(declared + 1).to_le_bytes());
    let path = fixture("fourdgs-cli-kd-header-count.4dgs", &data);

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("keyframes and birth groups introduce"),
        "{text}"
    );
    std::fs::remove_file(path).ok();
}

#[test]
fn delta_mode_must_name_the_reference_that_mode_defines() {
    let Some(source) = keyframe_files().into_iter().find(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("KeyframeDelta-"))
    }) else {
        return;
    };
    let mut data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    assert!(entries.len() >= 3, "the fixture needs two deltas");
    let target = 2usize;
    assert_eq!(entries[target].kind, 1);
    assert_eq!(entries[target - 1].kind, 1);

    // Make both copies of the metadata self-consistent and make the generic chain walk
    // succeed: only the mode-specific rule can reject this file.
    entries[target].delta_mode = fourdgs::records::DELTA_MODE_KEYFRAME;
    entries[target].reference_offset = entries[target - 1].chunk_offset;
    entries[target].depth = entries[target - 1].depth + 1;
    let content =
        entries[target].chunk_offset as usize + fourdgs::serialization::RECORD_HEADER_SIZE;
    data[content + 20] = fourdgs::records::DELTA_MODE_KEYFRAME;
    data[content + 21..content + 29]
        .copy_from_slice(&entries[target].reference_offset.to_le_bytes());
    data[content + 37..content + 39].copy_from_slice(&entries[target].depth.to_le_bytes());

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|entry| entry.encode())
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-mode-reference.4dgs",
        &rebuilt(&data[..start], &summary),
    );
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("uses keyframe mode but references"), "{text}");
    std::fs::remove_file(path).ok();
}

#[test]
fn a_keyframe_index_must_clear_its_delta_only_fields() {
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    assert_eq!(entries[0].kind, 0);
    entries[0].delta_mode = fourdgs::records::DELTA_MODE_CHAINED;
    entries[0].reference_offset = 123;

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|entry| entry.encode())
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-keyframe-index-fields.4dgs",
        &rebuilt(&data[..start], &summary),
    );
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("delta mode 1, reference 123"), "{text}");
    std::fs::remove_file(path).ok();
}

#[test]
fn a_delta_chunk_must_match_its_references_level() {
    let Some(source) = keyframe_file() else {
        return;
    };
    let mut data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (entries, rest) = summary_parts(&data);
    let target = entries.iter().find(|entry| entry.kind == 1).unwrap();
    let content = target.chunk_offset as usize + fourdgs::serialization::RECORD_HEADER_SIZE;
    data[content + 16..content + 20].copy_from_slice(&1u32.to_le_bytes());

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|entry| entry.encode())
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-level.4dgs",
        &rebuilt(&data[..start], &summary),
    );
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("declares level 1") && text.contains("declares level 0"),
        "{text}"
    );
    std::fs::remove_file(path).ok();
}

#[test]
fn a_delta_reference_must_be_physically_behind_its_chunk() {
    let Some(source) = keyframe_files().into_iter().find(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("KeyframeDelta-"))
    }) else {
        return;
    };
    let mut data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    assert!(entries.len() >= 3);
    assert_eq!((entries[1].kind, entries[2].kind), (1, 1));

    // Put the later physical Delta first on the timeline and make it a legal
    // keyframe-referenced state. The earlier physical Delta then chains from it: every
    // timeline relationship is sound, leaving only the backwards-offset invariant to
    // reject the file.
    let first_interval = (entries[1].t0, entries[1].t1);
    let second_interval = (entries[2].t0, entries[2].t1);
    entries[1].t0 = second_interval.0;
    entries[1].t1 = second_interval.1;
    entries[1].delta_mode = fourdgs::records::DELTA_MODE_CHAINED;
    entries[1].reference_offset = entries[2].chunk_offset;
    entries[1].depth = 2;
    entries[2].t0 = first_interval.0;
    entries[2].t1 = first_interval.1;
    entries[2].delta_mode = fourdgs::records::DELTA_MODE_KEYFRAME;
    entries[2].reference_offset = entries[0].chunk_offset;
    entries[2].depth = 1;

    for &i in &[1usize, 2] {
        let content = entries[i].chunk_offset as usize + fourdgs::serialization::RECORD_HEADER_SIZE;
        data[content..content + 8].copy_from_slice(&entries[i].t0.to_le_bytes());
        data[content + 8..content + 16].copy_from_slice(&entries[i].t1.to_le_bytes());
        data[content + 20] = entries[i].delta_mode;
        data[content + 21..content + 29]
            .copy_from_slice(&entries[i].reference_offset.to_le_bytes());
        data[content + 37..content + 39].copy_from_slice(&entries[i].depth.to_le_bytes());
    }

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|entry| entry.encode())
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-forward-reference.4dgs",
        &rebuilt(&data[..start], &summary),
    );
    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("must reference a physically earlier record"),
        "{text}"
    );
    std::fs::remove_file(path).ok();
}

#[test]
fn indexed_band_number_must_match_the_physical_record() {
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    let count = entries[0].gaussian_count as usize;
    entries[0].bands.push((1, 0, 0));
    let entries_len: usize = entries.iter().map(|entry| entry.encode().len()).sum();
    let band_at = (start + entries_len) as u64;
    let mut content = vec![2u8];
    content.extend_from_slice(
        &fourdgs::stream::encode_stream(0x07, &vec![0; count], 1, 0, 0, false).unwrap(),
    );
    let mut band = vec![0x07u8];
    band.extend_from_slice(&(content.len() as u64).to_le_bytes());
    band.extend_from_slice(&content);
    entries[0].bands = vec![(1, band_at, band.len() as u64)];
    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|entry| entry.encode())
        .chain(band)
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-band-number.4dgs",
        &rebuilt(&data[..start], &summary),
    );

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("record declares band 2"), "{text}");
    std::fs::remove_file(path).ok();
}

#[test]
fn a_keyframe_delta_file_declaring_an_unknown_quantization_scheme_is_refused() {
    // The keyframe-delta reader parsed its Quantization record and never asked the registry
    // about it, so a scheme this build does not implement composed all the way to a state
    // and the tool printed `valid`, exit 0 — while the gaussian-birth reader refuses the
    // same declaration by name at open. Two readers of one format disagreeing about which
    // files they can read is the divergence this repository exists to prevent.
    let Some(source) = keyframe_file() else {
        return;
    };
    let mut data = std::fs::read(&source).unwrap();
    // The declared scheme, overwritten with one nobody implements. Both names are ten
    // characters, so the record's length is unchanged and nothing in the file moves.
    let at = data
        .windows(10)
        .position(|w| w == b"uniform-v1")
        .expect("the file declares a quantization scheme");
    data[at..at + 10].copy_from_slice(b"uniform-v9");
    let path = fixture("fourdgs-cli-kd-scheme.4dgs", &data);

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("refusal unknown-quantization-scheme at byte "),
        "{text}"
    );
    assert!(text.contains("(the Quantization record)"), "{text}");
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_keyframe_delta_index_that_does_not_reach_the_ends_is_refused() {
    // Spec §11.1 is one sentence with three clauses, and `check_tiling` implemented one of
    // them: it compares neighbours, which says everything about the interior and nothing
    // about either end. An index starting after zero is internally adjacent, composes every
    // entry successfully, and validated clean — on a file where a seek to t=0 answers "no
    // state chunk covers t=0".
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    assert!(entries.len() > 1, "the fixture has a timeline to shorten");
    assert_eq!(entries[0].t0, 0.0, "which starts at zero before the change");
    entries[0].t0 = entries[0].t1 / 2.0;

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|e| e.encode())
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-endpoints.4dgs",
        &rebuilt(&data[..start], &summary),
    );

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains("the state chunks start at ") && text.contains("section 11.1"),
        "{text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn an_undecodable_band_of_a_keyframe_delta_chunk_is_not_reported_valid() {
    // Composing a chain reads Chunk and Delta Chunk records and nothing else, so an SH Band
    // Stream the index names was a record the verdict never visited: `valid`, exit 0, for a
    // file that does not decode. The gaussian-birth path has decoded every declared band
    // since the last round; this is the same rule on the other model.
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);

    // Two passes: the band record sits after the entries, and an entry has to name where.
    // Adding the range first fixes the entries' encoded length, which is what the offset is
    // measured from.
    let count = entries[0].gaussian_count;
    entries[0].bands.push((1, 0, 0));
    let entries_len: usize = entries.iter().map(|e| e.encode().len()).sum();
    let band_at = (start + entries_len) as u64;
    let band = undecodable_band(1, count);
    entries[0].bands = vec![(1, band_at, band.len() as u64)];

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|e| e.encode())
        .chain(band)
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-kd-band.4dgs",
        &rebuilt(&data[..start], &summary),
    );

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {band_at} ")),
        "{text}"
    );
    assert!(
        text.contains("SH Band Stream for band 1 of the Chunk at index entry 0"),
        "{text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_keyframe_delta_file_with_no_index_is_read_front_to_back() {
    // `open_indexed` starts its index walk at `Footer.summary_start`. On a stream-only file
    // that is zero, so it walked from byte 0, read the file magic as record framing, and
    // returned an error — and `validate` reported every conforming stream-only
    // keyframe-delta file as invalid, for a fault that was the tool's. The gaussian-birth
    // branch has always had the other path.
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let path = fixture(
        "fourdgs-cli-kd-unindexed.4dgs",
        &rebuilt(&data[..start], &[]),
    );

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    // Valid, with the warning that says what was given up: `2` is this tool's code for
    // "valid, with warnings", and a warning a script cannot see is a warning nobody acts on.
    assert_eq!(out.status.code(), Some(2), "{text}");
    assert!(text.contains("no chunk index"), "{text}");
    assert!(!text.contains("error:"), "{text}");
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_stream_only_keyframe_delta_file_still_has_its_chunks_decoded() {
    // The other half of the test above, and the one that matters: reporting a stream-only
    // file `valid` by not looking at it would pass that test and prove nothing. The same
    // file with one codec byte changed has to be refused, at the byte.
    let Some(source) = keyframe_file() else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let mut unindexed = rebuilt(&data[..start], &[]);
    let at = break_the_codec_in(&mut unindexed, 0x05)
        .expect("a keyframe-delta file carries Chunk records; they are its keyframes");
    let path = fixture("fourdgs-cli-kd-unindexed-bad.4dgs", &unindexed);

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {at} ")),
        "{text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn the_failing_one_of_two_ranges_for_the_same_band_is_the_one_reported() {
    // Nothing in the index forbids two ranges for the same band, and `read_chunk` decodes
    // both — it keys its results by band, so the second merely overwrites the first. Raising
    // a cap until the read fails therefore cannot tell them apart: the cap that admits the
    // bad duplicate admits the good one with it, and the offset reported was whichever
    // sorted first. That is a byte pointing at a healthy record, which is worse than no byte.
    let Some(source) = file(SH_DEGREE_2) else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let (start, _) = summary_bounds(&data);
    let (mut entries, rest) = summary_parts(&data);
    let good = *entries[0]
        .bands
        .first()
        .expect("the SHDegree2 variant declares bands");
    assert!(
        good.1 < start as u64,
        "the healthy band record sits before the summary region"
    );

    let count = entries[0].gaussian_count;
    entries[0].bands = vec![good, (good.0, 0, 0)];
    let entries_len: usize = entries.iter().map(|e| e.encode().len()).sum();
    let band_at = (start + entries_len) as u64;
    let band = undecodable_band(good.0, count);
    entries[0].bands = vec![good, (good.0, band_at, band.len() as u64)];

    let summary: Vec<u8> = entries
        .iter()
        .flat_map(|e| e.encode())
        .chain(band)
        .chain(rest)
        .collect();
    let path = fixture(
        "fourdgs-cli-duplicate-band.4dgs",
        &rebuilt(&data[..start], &summary),
    );

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(
        text.contains(&format!("refusal unknown-stream-codec at byte {band_at} ")),
        "the second range is the one that refuses; {text}"
    );
    assert!(
        !text.contains(&format!("at byte {} ", good.1)),
        "the first range is healthy and must not be named; {text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn a_file_cut_on_a_record_boundary_is_reported_as_cut_rather_than_noted() {
    // The simplest truncation there is: remove only the eight-byte trailing magic. Every
    // record is whole, so the walk reached the end with nothing left over and recorded no
    // cut — `inspect` printed a note about the missing magic and exited **0** for an
    // incomplete file, and `validate` left off the note that says how much of it survives.
    let Some(source) = file(INDEXED) else {
        return;
    };
    let data = std::fs::read(&source).unwrap();
    let path = fixture(
        "fourdgs-cli-no-magic.4dgs",
        &data[..data.len() - fourdgs::serialization::MAGIC.len()],
    );

    let out = run(&["inspect", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(
        out.status.code(),
        Some(1),
        "an incomplete file is not a whole one: {text}"
    );
    assert!(text.contains("truncated at byte"), "{text}");
    assert!(text.contains("intact prefix"), "{text}");

    let out = run(&["validate", path.to_str().unwrap()]);
    let text = stdout(&out);
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("does not end with the magic"), "{text}");
    assert!(
        text.contains("complete records before it are intact"),
        "the recovery note says how much survives: {text}"
    );
    std::fs::remove_file(&path).ok();
}

#[test]
fn decode_places_a_refusal_that_lives_inside_a_chunk() {
    // `decode` refused an unknown stream codec with the identifier and no byte: the table
    // that places a refusal from the framing has no entry for a chunk-level code, because
    // the framing walk steps over a chunk by its declared length and never looks inside it.
    // The file is scanned front to back instead, one record at a time, and the first record
    // raising *this same refusal* is the site.
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data/invalid");
    let variant = dir.join("UnknownStreamCodec.4dgs");
    if !variant.exists() {
        assert!(std::env::var_os("CI").is_none(), "CI generates the corpus");
        return;
    }
    // The identifier is read out of the corpus rather than restated here, so this test and
    // the expectation every SDK is scored against cannot drift apart.
    let expectation = std::fs::read_to_string(dir.join("UnknownStreamCodec.json")).unwrap();
    let code = expectation
        .split("\"refused\"")
        .nth(1)
        .and_then(|rest| rest.split('"').nth(1))
        .expect("the expectation names the refusal")
        .to_string();

    let out = run(&["decode", variant.to_str().unwrap()]);
    let text = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(
        out.status.code(),
        Some(1),
        "a file that was read and refused: {text}"
    );
    let placed = text
        .lines()
        .find(|l| l.contains(&format!("refusal {code}")))
        .unwrap_or_else(|| panic!("no `{code}` refusal in {text}"));
    assert!(
        placed.contains(" at byte "),
        "the refusal is named but not placed: {placed}"
    );
    // And the byte names a record, not the top of the file.
    assert!(!placed.contains(" at byte 0 "), "{placed}");
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

// ---------------------------------------------------------------------------------------
// The two validators are one validator, or they are worse than one.

/// Build a file with `count` Quantization records, the one at `bad_at` carrying a
/// non-finite `step_pos`. Written by hand rather than by the encoder, because the encoder
/// now refuses to produce a non-finite grid — which is the point of the encoder check, and
/// would otherwise leave both validators untestable against the file they exist to catch.
fn file_with_grids(count: usize, bad_at: Option<usize>) -> Vec<u8> {
    use fourdgs::records as rec;
    use fourdgs::serialization::MAGIC;

    let mut out = MAGIC.to_vec();
    out.extend_from_slice(
        &rec::Header {
            duration_sec: 1.0,
            gaussian_count: 0,
            aabb: vec![0.0; 6],
            // Default's empty string is not a temporal model, and a fixture named
            // "clean" must be clean: Python refuses the empty model at open (as the
            // spec requires) while the Rust core does not gate it yet, and the
            // cross-validator turned that divergence into a red main within hours
            // of landing. The core-side gate lands with the keyframe-delta reader
            // work, which pins the refusal wording normatively.
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(&[]),
    );
    for i in 0..count {
        let mut quant = rec::Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: vec![0.0, 0.0, 0.0],
            step_pos: 1e-4,
            step_scale_log: 0.04,
            step_rot: 0.004,
            step_rgb: 0.008,
            step_alpha: 0.008,
            step_motion: 2e-4,
            step_time: 0.004,
            step_sigma_log: 0.04,
            step_sh: 1,
            bounds: Default::default(),
            sh_bit_depths: Vec::new(),
        };
        if bad_at == Some(i) {
            quant.step_pos = f64::INFINITY;
        }
        out.extend_from_slice(&quant.encode(&[]));
    }
    out.extend_from_slice(
        &rec::WindowTable {
            windows: vec![(0.0, 1.0)],
        }
        .encode(),
    );
    out.extend_from_slice(&rec::Footer::default().encode());
    out.extend_from_slice(&MAGIC);
    out
}

/// The Python validator's findings for the same bytes, or `None` if it is not installed.
///
/// Both interpreter names are tried: the CI job that installs the package runs on Windows
/// too, where `setup-python` provides `python` and `python3` may not resolve at all.
///
/// `PYTHONIOENCODING` is not optional. Writing to a pipe, Python encodes stdout with the
/// locale's preferred encoding, which on a Windows runner is cp1252 — so the `§` in
/// "must be finite (§5.3)" arrives as the single byte `0xA7` while the Rust tool writes it
/// as UTF-8 `0xC2 0xA7`. Both are correct in their own encoding and the two tools do agree
/// about the message; only the transport disagreed. Pinning it makes this a comparison of
/// what the validators say rather than of how a pipe happened to spell it.
fn python_findings(path: &Path) -> Option<Vec<String>> {
    const PROGRAM: &str =
        "import sys\nfrom fourdgs.cli import main\nsys.exit(main(['validate', sys.argv[1]]))";
    for interpreter in ["python3", "python"] {
        let Ok(out) = Command::new(interpreter)
            .env("PYTHONIOENCODING", "utf-8")
            .args(["-c", PROGRAM, path.to_str().unwrap()])
            .output()
        else {
            continue; // no such interpreter
        };
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        // The package missing prints an ImportError to stderr and nothing to stdout.
        if text.is_empty() && !out.stderr.is_empty() {
            continue;
        }
        return Some(findings(&text));
    }
    None
}

/// Only the findings. The trailing status line and the exit code differ between the two
/// tools by design — the Rust one gives a warning its own exit code — and that divergence
/// is documented where it is made rather than asserted away here.
fn findings(text: &str) -> Vec<String> {
    text.lines()
        .filter(|l| {
            l.starts_with("error: ") || l.starts_with("warning: ") || l.starts_with("note: ")
        })
        .map(str::to_owned)
        .collect()
}

#[test]
fn both_validators_say_the_same_thing_about_the_same_bytes() {
    // The Rust validator mirrors the Python one deliberately, and a mirror is only worth
    // having while it is checked. The duplicate-record cases are the ones that matter: a
    // validator that inspects only the last Quantization record it parsed passes
    // `bad_then_good` while a streamed decoder — which takes the first grid it meets —
    // decodes the whole scene through the broken one. Both tools have to catch it, and
    // say the same words about it.
    let dir = std::env::temp_dir().join("fourdgs-xvalidate");
    std::fs::create_dir_all(&dir).expect("a scratch directory");

    let cases: [(&str, Vec<u8>); 4] = [
        ("clean", file_with_grids(1, None)),
        ("single_bad", file_with_grids(1, Some(0))),
        ("bad_then_good", file_with_grids(2, Some(0))),
        ("good_then_bad", file_with_grids(2, Some(1))),
    ];

    let mut compared = 0;
    for (name, bytes) in cases {
        let path = dir.join(format!("{name}.4dgs"));
        std::fs::write(&path, &bytes).expect("write the fixture");

        let ours = findings(&stdout(&run(&["validate", path.to_str().unwrap()])));
        let Some(theirs) = python_findings(&path) else {
            // Not installed. CI installs it before this suite; locally a contributor
            // without the Python package still gets a green run.
            assert!(
                std::env::var_os("CI").is_none(),
                "CI installs the Python package before this suite, so a run that could not \
                 reach it is a comparison that silently did not happen"
            );
            return;
        };
        assert_eq!(
            ours, theirs,
            "the two validators disagree about {name}.4dgs"
        );
        compared += 1;
    }
    assert_eq!(compared, 4, "every case must actually have been compared");
}

/// The same comparison, over the corpus of files a reader must refuse.
///
/// The four hand-built cases above isolate one rule each; these are the suite's own
/// invalid variants, and they are where a missing check actually shows. Every one of them
/// is a file that is well-formed apart from a single rule, so a reader without that check
/// decodes it into a plausible scene and says nothing — which is precisely how this
/// implementation shipped with no temporal-model gate at all while passing every valid
/// variant.
///
/// The refusal wording is contract here, not prose. Both CLIs print the same sentence
/// because the specification writes it, and this test is what keeps that true.
#[test]
fn both_validators_refuse_the_invalid_corpus_the_same_way() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/data/invalid");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        // The corpus is generated, not committed. CI generates it before this suite.
        assert!(
            std::env::var_os("CI").is_none(),
            "CI generates the corpus before this suite, so a run that could not find it \
             is a comparison that silently did not happen"
        );
        return;
    };

    let mut paths: Vec<std::path::PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "4dgs"))
        .collect();
    paths.sort();

    let mut compared = 0;
    let mut gated = 0;
    for path in &paths {
        let ours = findings(&stdout(&run(&["validate", path.to_str().unwrap()])));
        let Some(theirs) = python_findings(path) else {
            assert!(
                std::env::var_os("CI").is_none(),
                "CI installs the Python package before this suite"
            );
            return;
        };
        let name = path.file_name().unwrap().to_string_lossy().into_owned();

        // The two must say the same thing about the same bytes, wherever they say
        // anything. That is the property this file exists to hold, and it is what a check
        // present in one implementation and missing from the other breaks.
        //
        // Two classes are exempt from the wording comparison for now, and both are
        // recorded as gaps rather than quietly skipped:
        //
        // * the magic and version refusals, which the two word differently — this crate
        //   prefixes its error kind and Python does not. Closing that means changing
        //   messages in both languages.
        // * files whose only fault is inside a chunk's streams, such as an unimplemented
        //   stream codec. This validator now decodes the chunks and reports them, named
        //   and placed; the Python one still walks the framing and opens the file the way
        //   a seeking client would, so it never sees inside a stream and calls those files
        //   clean. That is the direction a divergence is allowed to run — this reader says
        //   more, and nothing it says contradicts the other — and #125's Python-side
        //   counterpart is what closes it. `every_invalid_variant_is_refused_by_its_own_-
        //   identifier` is where the added reporting is held to the corpus.
        let wording_is_contract =
            name.contains("TemporalModel") || name.contains("QuantizationScheme");
        if wording_is_contract {
            assert_eq!(ours, theirs, "the two validators disagree about {name}");
            for (who, found) in [("this reader", &ours), ("the Python reader", &theirs)] {
                assert!(
                    found.iter().any(|l| l.starts_with("error: ")),
                    "{name} declares a value neither reader implements and {who} said \
                     nothing about it: {found:?}"
                );
            }
            gated += 1;
        }

        compared += 1;
    }
    assert!(
        compared >= 7,
        "the invalid corpus should have been compared file by file, saw {compared}"
    );
    // Both the unknown model and the empty one, on the gate this whole comparison exists
    // for. A run where neither was reached is a green test that checked nothing.
    assert!(
        gated >= 3,
        "the temporal-model and scheme refusals must have been compared, saw {gated}"
    );
}
