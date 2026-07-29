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
//! Usage: encode_roundtrip <in.4dgs> <out.4dgs>

use std::process::ExitCode;

use fourdgs::writer::{SceneExtras, WriteOptions};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: encode_roundtrip <in.4dgs> <out.4dgs>");
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2]) {
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

fn run(input: &str, output: &str) -> Result<String, String> {
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
        ..Default::default()
    };
    let extras = SceneExtras {
        audio: scene.audio.clone(),
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
    Ok(format!(
        "{} gaussians, {} chunks, {} bytes, deterministic",
        reread.gaussians.count(),
        reread.chunk_index.len(),
        first.len()
    ))
}
