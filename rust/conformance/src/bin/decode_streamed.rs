// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: streamed decode, canonical JSON to stdout.
//!
//! The whole interface between an implementation and the harness is this: take a path,
//! print the canonical JSON.

use std::process::ExitCode;

use fourdgs::keyframe_delta_file::decode_streamed as decode_keyframe_delta_streamed;
use fourdgs::opcode;
use fourdgs::records::Header;
use fourdgs::serialization::{check_magic, Records, MAGIC};
use fourdgs_conformance::{keyframe_delta_states_json, summarize, Extras};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: decode_streamed <file.4dgs>");
        return ExitCode::from(2);
    }
    match run(&args[1]) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// The Header's temporal model, read without decoding the gaussians. A `keyframe-delta`
/// file composes and summarizes differently from a `gaussian-birth` one, so the runner
/// branches on this before doing either.
fn temporal_model(data: &[u8]) -> Result<Option<String>, String> {
    check_magic(data).map_err(|e| e.to_string())?;
    for record in Records::new(data, MAGIC.len()) {
        let record = record.map_err(|e| e.to_string())?;
        if record.opcode == opcode::HEADER {
            return Ok(Some(
                Header::parse(record.content)
                    .map_err(|e| e.to_string())?
                    .temporal_model,
            ));
        }
    }
    Ok(None)
}

fn run(path: &str) -> Result<String, String> {
    let data = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;

    if temporal_model(&data)?.as_deref() == Some("keyframe-delta") {
        // The whole model exists to make reconstruction-at-an-instant cheap, and that
        // reconstruction — not a whole-population summary — is what the SDKs are diffed on.
        // Truncation recovery is a gaussian-birth check: the states canonical is a
        // different statement and a cut file is a different file.
        let seq = decode_keyframe_delta_streamed(&data).map_err(|e| format!("{path}: {e}"))?;
        return Ok(keyframe_delta_states_json(&seq));
    }

    let scene = fourdgs::read_bytes(&data).map_err(|e| format!("{path}: {e}"))?;
    check_truncation_recovery(&data, &scene)?;

    let intervals: Vec<(f64, f64)> = scene.chunk_index.iter().map(|e| (e.t0, e.t1)).collect();
    summarize(
        &scene.header,
        &scene.gaussians,
        &scene.audio_sources,
        &intervals,
        &Extras {
            camera: scene.camera.as_ref(),
            metadata: &scene.metadata,
            attachments: &scene.attachments,
            statistics: scene.statistics.as_ref(),
            summary_offsets: &scene.summary_offsets,
            summary_crc_ok: scene.summary_crc_ok,
            provenance: Some(&scene.provenance),
            objects: Some(&scene.objects),
        },
    )
    .map_err(|e| format!("{path}: {e}"))
}

/// Decode the same file cut short, and insist on what survives.
///
/// Nothing in the corpus is truncated, so this makes one. The canonical JSON cannot express
/// truncation recovery — a cut file is a different file — so the check lives here, where a
/// failure exits non-zero and the harness reports it like any other.
fn check_truncation_recovery(data: &[u8], full: &fourdgs::Scene) -> Result<(), String> {
    let cut = fourdgs::read_bytes(&data[..data.len() - 1])
        .map_err(|e| format!("a file cut before its trailing magic did not decode: {e}"))?;
    if !cut.truncated {
        return Err("a file cut before its trailing magic was not reported truncated".into());
    }
    if cut.gaussians.count() != full.gaussians.count() {
        return Err(format!(
            "cutting the trailing magic lost gaussians: {} of {}",
            cut.gaussians.count(),
            full.gaussians.count()
        ));
    }

    if full.chunk_index.len() >= 2 {
        let last = full.chunk_index.last().expect("at least two entries");
        let at = last.chunk_offset as usize + 5;
        let mid = fourdgs::read_bytes(&data[..at])
            .map_err(|e| format!("a file cut inside a chunk record did not decode: {e}"))?;
        if !mid.truncated {
            return Err("a file cut inside a chunk record was not reported truncated".into());
        }
        let expected = full.gaussians.count() - last.gaussian_count as usize;
        if mid.gaussians.count() != expected {
            return Err(format!(
                "cutting the last chunk left {} gaussians, expected {expected}",
                mid.gaussians.count()
            ));
        }
    }
    Ok(())
}
