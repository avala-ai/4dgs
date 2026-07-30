// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: encode a `keyframe-delta` file.
//!
//! There is no committed keyframe-delta corpus variant — a separate milestone owns the
//! corpus — so this synthesizes a deterministic sample sequence in memory and writes it
//! with the Rust keyframe-delta writer. The sequence is built to exercise the model rather
//! than merely to be legal: gaussians move (so every non-keyframe sample carries updates),
//! a group of ids is born partway through, another dies later, ids are rotated within each
//! sample (so a decoder that found gaussians by row instead of by identity would be wrong),
//! and the cadence lays down more than one keyframe with chained deltas between them.
//!
//! The harness step around this then makes the claim that matters: the file this encoder
//! produced is read to an identical canonical `states` summary by the Rust decoder and by
//! the Python reference decoder — the only definition of a conforming file that means
//! anything.
//!
//! Usage: encode_keyframe_delta <out.4dgs> [keyframe|chained]

use std::process::ExitCode;

use fourdgs::keyframe_delta_file::{write_sequence, KeyframeDeltaOptions, Sample};
use fourdgs::model::GaussianSet;
use fourdgs::records::{DELTA_MODE_CHAINED, DELTA_MODE_KEYFRAME};

const DURATION: f64 = 2.0;
const SAMPLES: usize = 17;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 || args.len() > 3 {
        eprintln!("usage: encode_keyframe_delta <out.4dgs> [keyframe|chained]");
        return ExitCode::from(2);
    }
    let delta_mode = match args.get(2).map(String::as_str) {
        None | Some("chained") => DELTA_MODE_CHAINED,
        Some("keyframe") => DELTA_MODE_KEYFRAME,
        Some(other) => {
            eprintln!("unknown delta mode {other:?}; expected 'keyframe' or 'chained'");
            return ExitCode::from(2);
        }
    };
    match run(&args[1], delta_mode) {
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

fn run(output: &str, delta_mode: u8) -> Result<String, String> {
    let samples = synthesize();
    let kd = KeyframeDeltaOptions {
        keyframe_every: 8,
        delta_mode,
        ..Default::default()
    };
    let first = write_sequence(&samples, DURATION, &kd)
        .map_err(|e| format!("{output}: encode failed: {e}"))?;
    let second = write_sequence(&samples, DURATION, &kd)
        .map_err(|e| format!("{output}: the second encode failed: {e}"))?;
    if first != second {
        return Err(format!(
            "{output}: two encodes of one sequence differ; the writer is not deterministic"
        ));
    }

    // The file has to survive both of this implementation's read paths, and they must reach
    // the same populations, before it is worth asking another implementation about it.
    let streamed = fourdgs::keyframe_delta_file::decode_streamed(&first)
        .map_err(|e| format!("{output}: the writer wrote a file it cannot stream-decode: {e}"))?;
    let (indexed, _) = fourdgs::keyframe_delta_file::decode_indexed(&first)
        .map_err(|e| format!("{output}: the writer wrote a file it cannot index-decode: {e}"))?;
    let a = fourdgs_conformance::keyframe_delta_states_json(&streamed);
    let b = fourdgs_conformance::keyframe_delta_states_json(&indexed);
    if a != b {
        return Err(format!(
            "{output}: the two read paths disagree on a file the writer produced"
        ));
    }

    std::fs::write(output, &first).map_err(|e| format!("{output}: {e}"))?;
    Ok(format!(
        "{} samples, {} chunks, {} bytes, deterministic, both read paths agree",
        samples.len(),
        streamed.chunks.len(),
        first.len()
    ))
}

/// A deterministic sample sequence. Reproducible from an LCG so the encoder has no hidden
/// state; the population is chosen to make every group non-empty somewhere in the file.
fn synthesize() -> Vec<Sample> {
    let mut samples = Vec::with_capacity(SAMPLES);
    for i in 0..SAMPLES {
        // t0s tile [0, duration): the last sample starts below the end, and its interval
        // closes at `duration`, so no chunk gets a zero-width span.
        let frac = i as f64 / SAMPLES as f64;
        let t0 = frac * DURATION;

        // Which ids are live at this sample. The core is always present; one band is born
        // partway in and another dies later, so births, deaths and updates all occur.
        let mut ids: Vec<i64> = (0..24).collect();
        if i >= 5 {
            ids.extend(24..28); // born at sample 5
        }
        if i >= 11 {
            ids.retain(|id| *id >= 4); // ids 0..4 die at sample 11
        }
        // Rotate the order so identity, not row position, decides correspondence.
        let shift = i % ids.len().max(1);
        ids.rotate_left(shift);

        let n = ids.len();
        let mut g = GaussianSet {
            positions: Vec::with_capacity(n * 3),
            scales: Vec::with_capacity(n * 3),
            rotations: Vec::with_capacity(n * 4),
            colors: Vec::with_capacity(n * 4),
            motions: Vec::with_capacity(n * 3),
            mu_t: Vec::with_capacity(n),
            sigma_t: Vec::with_capacity(n),
            ..Default::default()
        };
        for &id in &ids {
            let mut rng = Lcg::seeded(id as u64);
            // A per-gaussian base plus a small per-sample drift: the drift makes position
            // move sample to sample, which is what a non-keyframe sample records as an update.
            let base = [
                rng.unit() * 4.0 - 2.0,
                rng.unit() * 4.0 - 2.0,
                rng.unit() * 4.0 - 2.0,
            ];
            let drift = [
                (rng.unit() - 0.5) * 0.2,
                (rng.unit() - 0.5) * 0.2,
                (rng.unit() - 0.5) * 0.2,
            ];
            for axis in 0..3 {
                g.positions
                    .push((base[axis] + drift[axis] * i as f64) as f32);
                g.scales.push((0.02 + rng.unit() * 0.1) as f32);
            }
            // A unit quaternion, restated absolutely by every update.
            let (qx, qy, qz) = (rng.unit() - 0.5, rng.unit() - 0.5, rng.unit() - 0.5);
            let qw = 1.0;
            let norm = (qx * qx + qy * qy + qz * qz + qw * qw).sqrt();
            g.rotations.extend_from_slice(&[
                (qx / norm) as f32,
                (qy / norm) as f32,
                (qz / norm) as f32,
                (qw / norm) as f32,
            ]);
            g.colors.extend_from_slice(&[
                rng.unit() as f32,
                rng.unit() as f32,
                rng.unit() as f32,
                (0.3 + 0.6 * rng.unit()) as f32,
            ]);
            // A constant velocity per gaussian (a GOP-invariant grid still applies, so the
            // motion bins differ from zero and telescope through the chain).
            g.motions.extend_from_slice(&[
                ((rng.unit() - 0.5) * 0.5) as f32,
                ((rng.unit() - 0.5) * 0.5) as f32,
                ((rng.unit() - 0.5) * 0.5) as f32,
            ]);
            g.mu_t.push((rng.unit() * DURATION) as f32);
            g.sigma_t.push((0.2 + rng.unit() * 0.8) as f32);
        }
        samples.push(Sample {
            t0,
            ids,
            gaussians: g,
        });
    }
    samples
}

/// A tiny linear congruential generator: deterministic, portable, and enough variety for a
/// synthetic scene. Not for anything that needs statistical quality.
struct Lcg {
    state: u64,
}

impl Lcg {
    fn seeded(seed: u64) -> Lcg {
        // Offset so id 0 is not a degenerate all-zero stream.
        Lcg {
            state: seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1),
        }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self
            .state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.state
    }

    /// A value in `[0, 1)`.
    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}
