// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: streamed decode, canonical JSON to stdout.
//!
//! The whole interface between an implementation and the harness is this: take a path,
//! print the canonical JSON.

use std::process::ExitCode;

use fourdgs_conformance::{summarize, AudioSummary, Extras};

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

fn run(path: &str) -> Result<String, String> {
    let data = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let scene = fourdgs::read_bytes(&data).map_err(|e| format!("{path}: {e}"))?;
    check_truncation_recovery(&data, &scene)?;

    let audio = scene.audio.as_ref().map(|a| AudioSummary {
        codec: a.codec.clone(),
        data: a.data.clone(),
    });
    let intervals: Vec<(f64, f64)> = scene.chunk_index.iter().map(|e| (e.t0, e.t1)).collect();
    summarize(
        &scene.header,
        &scene.gaussians,
        audio.as_ref(),
        &intervals,
        &Extras {
            camera: scene.camera.as_ref(),
            metadata: &scene.metadata,
            attachments: &scene.attachments,
            statistics: scene.statistics.as_ref(),
            summary_offsets: &scene.summary_offsets,
            summary_crc_ok: scene.summary_crc_ok,
            provenance: Some(&scene.provenance),
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
