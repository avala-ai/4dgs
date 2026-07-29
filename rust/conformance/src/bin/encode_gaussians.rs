// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: the shared encode reference for the cross-language gate.
//!
//! `encode_roundtrip` re-encodes a whole scene — gaussians plus audio, camera, metadata,
//! attachments and provenance — which is right for proving the Rust encoder against the
//! Python decoder. It is the wrong baseline for the other encoders, because the C++, Swift
//! and TypeScript authoring surfaces write gaussians and cannot reproduce every extra a
//! corpus variant happens to carry. A gate that compared against a file with those extras
//! would fail on the extras rather than on the encode.
//!
//! So this binary re-encodes the **gaussians alone**, with a fixed option preset, and drops
//! everything else. It is the one baseline the three language encoders are diffed against:
//! each of them re-encodes the same decoded gaussians with the same preset, and the Python
//! decoder must produce identical canonical JSON from both files. For C++ and Swift, which
//! reach the same Rust encoder through the C ABI, that proves the binding wired the gaussians
//! and options through correctly; for TypeScript, which is a second encoder, it proves the
//! two implementations agree.
//!
//! The preset below is the contract. A binding that means to be diffed against this baseline
//! sets exactly these options, and the file layout — chunk intervals, summary offsets, the
//! CRC — then matches, because the encoder is deterministic in its input and its options.
//!
//! An optional third argument names per-band spherical harmonic bit depths, exactly as
//! `encode_roundtrip` takes them.
//!
//! Usage: encode_gaussians <in.4dgs> <out.4dgs> [sh-bit-depths]

use std::process::ExitCode;

use fourdgs::writer::{SceneExtras, WriteOptions};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 || args.len() > 4 {
        eprintln!("usage: encode_gaussians <in.4dgs> <out.4dgs> [sh-bit-depths]");
        return ExitCode::from(2);
    }
    let depths = match args.get(3).map(|spec| parse_depths(spec)) {
        Some(Ok(depths)) => Some(depths),
        Some(Err(message)) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
        None => None,
    };
    match run(&args[1], &args[2], depths) {
        Ok(note) => {
            println!("{note}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// A registry ladder name, or a comma-separated list of depths, band 1 first.
fn parse_depths(spec: &str) -> Result<Vec<u8>, String> {
    if let Some(ladder) = fourdgs::quantization::sh_ladder(spec) {
        return Ok(ladder.to_vec());
    }
    spec.split(',')
        .map(|part| {
            part.trim()
                .parse::<u8>()
                .map_err(|_| format!("{spec}: not a ladder name or a list of bit depths"))
        })
        .collect()
}

/// The gaussians-only option preset the language encoders reproduce. Everything that shows
/// up in the canonical summary and is not a gaussian value is here: the duration and cutoff
/// come from the file, the chunking is small so the corpus scenes exercise the tree, the
/// whole summary is written, and the profile and attributes are carried through. The library
/// string is left at the encoder's default, so both sides carry the same one.
pub fn gaussians_only_options(
    cutoff: f64,
    profile: String,
    attributes: std::collections::BTreeMap<String, String>,
    sh_bit_depths: Option<Vec<u8>>,
) -> WriteOptions {
    WriteOptions {
        cutoff,
        min_chunk_gaussians: 8,
        max_depth: 4,
        write_index: true,
        write_statistics: true,
        write_summary_offsets: true,
        write_crc: true,
        sh_bands: 3,
        scene_profile: profile,
        metadata: attributes,
        sh_bit_depths,
        ..Default::default()
    }
}

fn run(input: &str, output: &str, sh_bit_depths: Option<Vec<u8>>) -> Result<String, String> {
    let scene = fourdgs::read_path(input).map_err(|e| format!("{input}: {e}"))?;

    let options = gaussians_only_options(
        scene.header.cutoff,
        scene.header.profile.clone(),
        scene.header.attributes.clone(),
        sh_bit_depths,
    );
    // The gaussians alone: no audio, no camera, no metadata records, no attachments, no
    // provenance. That is the whole point of this baseline.
    let extras = SceneExtras::default();

    let first = fourdgs::write_to_vec(&scene.gaussians, scene.duration_sec, &options, &extras)
        .map_err(|e| format!("{input}: encoding failed: {e}"))?;
    let second = fourdgs::write_to_vec(&scene.gaussians, scene.duration_sec, &options, &extras)
        .map_err(|e| format!("{input}: the second encode failed: {e}"))?;
    if first != second {
        return Err(format!(
            "{input}: two encodes of one scene differ; the encoder is not deterministic"
        ));
    }

    let reread = fourdgs::read_bytes(&first)
        .map_err(|e| format!("{input}: the encoder wrote a file it cannot read: {e}"))?;
    if reread.gaussians.count() != scene.gaussians.count() {
        return Err(format!(
            "{input}: re-encoding turned {} gaussians into {}",
            scene.gaussians.count(),
            reread.gaussians.count()
        ));
    }

    std::fs::write(output, &first).map_err(|e| format!("{output}: {e}"))?;
    let declared = reread.quantization.sh_bit_depths.clone();
    Ok(format!(
        "{} gaussians, {} chunks, {} bytes, deterministic, sh bits {declared:?}",
        reread.gaussians.count(),
        reread.chunk_index.len(),
        first.len()
    ))
}
