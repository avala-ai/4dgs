// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: encode.
//!
//! The corpus proves decoders against files the reference encoder wrote. This proves the
//! encoder, and it does it without a second corpus: take a variant, decode it, re-encode
//! the gaussians it yielded, and write the result out. The harness step around this then
//! makes the claim that matters — that the file this encoder produced is read *identically
//! by two independent implementations*, which is the only definition of a conforming file
//! that means anything.
//!
//! Two things are asserted here rather than by the step around it:
//!
//! * **Determinism.** The scene is encoded twice and the bytes must be identical. Accidental
//!   nondeterminism — an iteration order, a hash seed — is invisible locally and shows up
//!   as somebody else's failing CI.
//! * **The bounds.** `WriteOptions::verify` decodes every chunk back and refuses to return
//!   a file whose measured deviation exceeds what it is about to declare, so reaching this
//!   line at all means the claim in the Quantization record was checked on every gaussian.
//!
//! An optional third argument names the per-band spherical harmonic bit depths to
//! re-encode with — a ladder from the registry or a comma-separated list. That is how the
//! harness proves the depths across implementations: the coefficients this encoder
//! coarsened have to come back out of the Python decoder as the same bytes, and the
//! appended field it wrote has to parse there as the depths it meant.
//!
//! Usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]

use std::process::ExitCode;

use fourdgs::writer::{SceneExtras, WriteOptions};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 || args.len() > 4 {
        eprintln!("usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]");
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

fn run(input: &str, output: &str, sh_bit_depths: Option<Vec<u8>>) -> Result<String, String> {
    let scene = fourdgs::read_path(input).map_err(|e| format!("{input}: {e}"))?;

    let options = WriteOptions {
        cutoff: scene.header.cutoff,
        // Small on purpose: the corpus scenes are hundreds of gaussians, and the default
        // threshold would collapse every one of them to a single chunk, which would leave
        // the chunk tree untested by the very files that exist to stress it.
        min_chunk_gaussians: 8,
        max_depth: 4,
        write_statistics: true,
        write_summary_offsets: true,
        scene_profile: scene.header.profile.clone(),
        metadata: scene.header.attributes.clone(),
        sh_bit_depths,
        ..Default::default()
    };
    let extras = SceneExtras {
        audio_sources: scene.audio_sources.clone(),
        audio: None,
        camera: scene.camera.clone(),
        metadata: scene.metadata.clone(),
        attachments: scene.attachments.clone(),
        provenance: scene.provenance.clone(),
    };

    let first = fourdgs::write_to_vec(&scene.gaussians, scene.duration_sec, &options, &extras)
        .map_err(|e| format!("{input}: encoding failed: {e}"))?;
    let second = fourdgs::write_to_vec(&scene.gaussians, scene.duration_sec, &options, &extras)
        .map_err(|e| format!("{input}: the second encode failed: {e}"))?;
    if first != second {
        return Err(format!(
            "{input}: two encodes of one scene differ; the encoder is not deterministic"
        ));
    }

    // The file has to survive this implementation's own two read paths before it is worth
    // asking another implementation about it.
    let reread = fourdgs::read_bytes(&first)
        .map_err(|e| format!("{input}: the encoder wrote a file it cannot read: {e}"))?;
    if reread.gaussians.count() != scene.gaussians.count() {
        return Err(format!(
            "{input}: re-encoding turned {} gaussians into {}",
            scene.gaussians.count(),
            reread.gaussians.count()
        ));
    }
    if reread.header.has_audio() != scene.header.has_audio() {
        return Err(format!(
            "{input}: the audio bit did not survive re-encoding"
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
