// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: keyframe-delta decode, canonical `states` JSON to stdout.
//!
//! Decodes the file by BOTH read paths and insists they agree before printing — the
//! front-to-back composition and the per-instant chain walk are two very different ways to
//! reach the same population, and agreeing across them is most of what makes a keyframe-delta
//! implementation trustworthy. The JSON printed is the streamed path's; the indexed path is
//! required to match it exactly.

use std::process::ExitCode;

use fourdgs::keyframe_delta_file::{decode_indexed, decode_streamed};
use fourdgs_conformance::keyframe_delta_states_json;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: decode_keyframe_delta <file.4dgs>");
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
    let streamed = decode_streamed(&data).map_err(|e| format!("{path}: streamed: {e}"))?;
    let (indexed, _) = decode_indexed(&data).map_err(|e| format!("{path}: indexed: {e}"))?;

    let a = keyframe_delta_states_json(&streamed);
    let b = keyframe_delta_states_json(&indexed);
    if a != b {
        return Err(format!(
            "{path}: the streamed and indexed read paths disagree on the same file"
        ));
    }
    Ok(a)
}
