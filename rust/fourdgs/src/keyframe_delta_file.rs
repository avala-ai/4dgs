// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Whole-file `keyframe-delta`: write a sample sequence, decode it, reconstruct instants.
//!
//! [`keyframe_delta`](crate::keyframe_delta) holds the composition and the chain a seek
//! walks; [`records`](crate::records) holds the wire records. This module is the file
//! *around* them — the Header, a keyframe Chunk or a Delta Chunk per sample, the extended
//! Chunk Index, the Footer — and the two read paths a consumer takes:
//!
//! * [`decode_streamed`] walks the file front to back, composing each chunk onto the last;
//! * [`decode_indexed`] reads the index and, for an instant, walks only that instant's chain.
//!
//! They MUST agree. Everything upstream of composition is bins, never values: the writer
//! quantizes every sample on one shared set of grids, so a delta is an integer subtraction
//! between two bins on the same grid and the composition telescopes exactly (spec §11.7).
//! Dequantization happens once, at the end, on the composed state, by the same arithmetic a
//! `gaussian-birth` chunk uses.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};

use crate::codec;
use crate::error::{Error, Result};
use crate::keyframe_delta::{
    apply_delta, chain_ending_at, check_tiling, check_timeline_endpoints, keyframe_state, BinArray,
    State, ABSOLUTE_IN_UPDATE, GOP_INVARIANT,
};
use crate::model::GaussianSet;
use crate::opcode as op;
use crate::quantization::{
    life_class, motion_step, mu_step, rct_forward, rint, support_k, Bounds, Profile, Steps,
};
use crate::records as rec;
use crate::serialization::{
    check_magic, crc32, Cursor, Records, MAGIC, MAX_STREAM_BYTES, STREAM_HEADER_SIZE,
};
use crate::stream::{decode_stream, encode_stream, DecodedStream};

/// How many gaussians appear in full in a probe's sample.
pub const SAMPLE: usize = 16;

/// The eleven required attributes plus identity. A keyframe carries all of them; a birth
/// group carries all of them absolutely; an update carries the subset that changed.
const REQUIRED: [u8; 11] = op::REQUIRED_ATTRIBUTES;

// --------------------------------------------------------------------------
// Options and samples
// --------------------------------------------------------------------------

/// One population, at one instant, with identity.
///
/// `ids` is aligned with the gaussians and is what a delta names them by.
#[derive(Debug, Clone, Default)]
pub struct Sample {
    pub t0: f64,
    pub ids: Vec<i64>,
    pub gaussians: GaussianSet,
}

/// Cadence and mode. Everything else comes from the ordinary write parameters.
#[derive(Debug, Clone)]
pub struct KeyframeDeltaOptions {
    /// Samples per group of pictures. 1 writes every sample as a keyframe.
    pub keyframe_every: usize,
    /// `DELTA_MODE_CHAINED` references the previous chunk; `DELTA_MODE_KEYFRAME` references
    /// the group's keyframe.
    pub delta_mode: u8,
    /// Sample indices to force a keyframe at, beyond the cadence.
    pub keyframe_at: Vec<usize>,
    pub profile: Profile,
    pub cutoff: f64,
    pub library: String,
    pub codec: u8,
    pub level: u32,
}

impl Default for KeyframeDeltaOptions {
    fn default() -> Self {
        KeyframeDeltaOptions {
            keyframe_every: 8,
            delta_mode: rec::DELTA_MODE_CHAINED,
            keyframe_at: Vec::new(),
            profile: Profile::Default,
            cutoff: 0.05,
            library: "4dgs keyframe-delta reference".into(),
            codec: crate::codec::DEFLATE,
            level: 6,
        }
    }
}

fn is_keyframe(index: usize, kd: &KeyframeDeltaOptions) -> bool {
    index == 0
        || kd.keyframe_at.contains(&index)
        || (kd.keyframe_every > 0 && index % kd.keyframe_every == 0)
}

// --------------------------------------------------------------------------
// Shared grids
// --------------------------------------------------------------------------

/// The one set of grids the whole sequence is quantized on.
#[derive(Debug, Clone)]
pub struct Grids {
    pub steps: Steps,
    pub origin: [f64; 3],
    /// Every validity window the sequence declares, in Window Table order. A gaussian's
    /// own window is the one its `window_index` names — the velocity grid comes from that
    /// window's length (spec §6.3), so collapsing the table to its first entry gives every
    /// gaussian outside window 0 the wrong motion precision, and its reconstructed
    /// positions drift from the bins the encoder wrote.
    pub windows: Vec<(f64, f64)>,
    pub cutoff: f64,
}

impl Grids {
    /// The first window. Only the writer uses this: it emits a single-window table.
    pub fn window(&self) -> (f64, f64) {
        self.windows.first().copied().unwrap_or((0.0, 0.0))
    }

    /// The length of the window `index` names.
    ///
    /// Every index is checked against the table when the state is built
    /// (`check_window_index`, the same refusal the chunk path uses), so by the time
    /// reconstruction asks, an out-of-range index cannot have survived. Falling back to
    /// the first window keeps this total rather than panicking on a bound already proved.
    fn window_len(&self, index: i64) -> f64 {
        let w = self.window_at(index);
        w.1 - w.0
    }

    /// The window `index` names, defaulting an absent table to one `(0, 0)` entry.
    ///
    /// Total on purpose: every index is checked against the table when the state is
    /// built — `check_window_indices`, on both read paths — so an out-of-range index
    /// cannot reach reconstruction, and this cannot panic on a bound already proved.
    fn window_at(&self, index: i64) -> (f64, f64) {
        usize::try_from(index)
            .ok()
            .and_then(|i| self.windows.get(i))
            .copied()
            .unwrap_or_else(|| self.window())
    }

    fn motion_step_for(&self, sigma_bin: i64, never_fades: bool, window_index: i64) -> f64 {
        let win_len = self.window_len(window_index);
        let class = life_class(
            sigma_bin,
            self.steps.sigma_log,
            never_fades,
            win_len,
            support_k(self.cutoff),
        );
        motion_step(class, self.steps.motion)
    }

    fn mu_step_for(&self, sigma_bin: i64, never_fades: bool) -> f64 {
        mu_step(
            sigma_bin,
            self.steps.sigma_log,
            never_fades,
            self.steps.time,
        )
    }
}

fn quantize_scalar(value: f64, step: f64, origin: f64) -> i64 {
    rint((value - origin) / step)
}

/// One sample as identities and a bin per attribute, on the shared grids.
///
/// Every gaussian shares one validity window and a finite `sigma_t`, which keeps the
/// per-gaussian velocity and birth-time grids uniform — all this reference needs to
/// exercise the model.
fn quantize_sample(sample: &Sample, grids: &Grids) -> Result<(Vec<i64>, BTreeMap<u8, BinArray>)> {
    let g = &sample.gaussians;
    let n = g.count();
    if sample.ids.len() != n {
        return Err(Error::InvalidInput(format!(
            "sample carries {n} gaussians but {} ids",
            sample.ids.len()
        )));
    }
    let ids = sample.ids.clone();
    let mut bins: BTreeMap<u8, BinArray> = BTreeMap::new();

    let mut position = Vec::with_capacity(n * 3);
    let mut scale = Vec::with_capacity(n * 3);
    let mut rot_index = Vec::with_capacity(n);
    let mut rotation = Vec::with_capacity(n * 3);
    let mut color = Vec::with_capacity(n * 3);
    let mut opacity = Vec::with_capacity(n);
    let mut motion = Vec::with_capacity(n * 3);
    let mut mu = Vec::with_capacity(n);
    let mut sigma = Vec::with_capacity(n);
    let mut flags = Vec::with_capacity(n);
    let mut window_index = Vec::with_capacity(n);

    for i in 0..n {
        let sigma_f = g.sigma_t[i] as f64;
        if !sigma_f.is_finite() {
            return Err(Error::InvalidInput(
                "this reference writer needs finite sigma_t on every gaussian".into(),
            ));
        }
        let q_sigma = quantize_scalar(sigma_f.max(1e-30).ln(), grids.steps.sigma_log, 0.0);
        let never_fades = false;
        sigma.push(q_sigma);
        flags.push(0);
        let row_window = window_index_of(
            &grids.windows,
            g.win_lo.get(i).copied().unwrap_or(0.0),
            g.win_hi.get(i).copied().unwrap_or(0.0),
        );
        window_index.push(row_window);

        for axis in 0..3 {
            position.push(quantize_scalar(
                g.positions[i * 3 + axis] as f64,
                grids.steps.pos,
                grids.origin[axis],
            ));
            scale.push(quantize_scalar(
                (g.scales[i * 3 + axis] as f64).max(1e-30).ln(),
                grids.steps.scale_log,
                0.0,
            ));
        }

        let quat = [
            g.rotations[i * 4] as f64,
            g.rotations[i * 4 + 1] as f64,
            g.rotations[i * 4 + 2] as f64,
            g.rotations[i * 4 + 3] as f64,
        ];
        let (largest, res) = crate::quantization::quantize_rotation(quat, grids.steps.rot);
        rot_index.push(largest);
        rotation.extend_from_slice(&res);

        let rgb = [
            quantize_scalar(g.colors[i * 4] as f64, grids.steps.rgb, 0.0),
            quantize_scalar(g.colors[i * 4 + 1] as f64, grids.steps.rgb, 0.0),
            quantize_scalar(g.colors[i * 4 + 2] as f64, grids.steps.rgb, 0.0),
        ];
        color.extend_from_slice(&rct_forward(rgb));
        opacity.push(quantize_scalar(
            g.colors[i * 4 + 3] as f64,
            grids.steps.alpha,
            0.0,
        ));

        // The row's own window, matching the index written beside it: quantizing against
        // window 0 while recording a different index scales the velocity by one grid and
        // reconstructs it with another.
        let m_step = grids.motion_step_for(q_sigma, never_fades, row_window);
        for axis in 0..3 {
            motion.push(rint(g.motions[i * 3 + axis] as f64 / m_step));
        }
        let t_step = grids.mu_step_for(q_sigma, never_fades);
        mu.push(rint(g.mu_t[i] as f64 / t_step));
    }

    bins.insert(op::A_POSITION, BinArray::new(position, 3));
    bins.insert(op::A_SCALE, BinArray::new(scale, 3));
    bins.insert(op::A_ROTATION_INDEX, BinArray::new(rot_index, 1));
    bins.insert(op::A_ROTATION, BinArray::new(rotation, 3));
    bins.insert(op::A_COLOR, BinArray::new(color, 3));
    bins.insert(op::A_OPACITY, BinArray::new(opacity, 1));
    bins.insert(op::A_MOTION, BinArray::new(motion, 3));
    bins.insert(op::A_MU_T, BinArray::new(mu, 1));
    bins.insert(op::A_SIGMA_T, BinArray::new(sigma, 1));
    bins.insert(op::A_FLAGS, BinArray::new(flags, 1));
    bins.insert(op::A_WINDOW_INDEX, BinArray::new(window_index, 1));
    Ok((ids, bins))
}

fn grids_for(samples: &[Sample], duration_sec: f64, profile: Profile, cutoff: f64) -> Grids {
    let mut scales: Vec<f64> = Vec::new();
    let mut origin = [f64::INFINITY; 3];
    let mut any = false;
    for s in samples {
        let g = &s.gaussians;
        for i in 0..g.count() {
            any = true;
            for (axis, slot) in origin.iter_mut().enumerate() {
                *slot = slot.min(g.positions[i * 3 + axis] as f64);
                scales.push(g.scales[i * 3 + axis] as f64);
            }
        }
    }
    if !any {
        origin = [0.0; 3];
    }
    let median_scale = median(&mut scales).unwrap_or(1e-3);
    let bounds = Bounds::for_profile(profile, median_scale);
    let steps = Steps::of(&bounds);
    Grids {
        steps,
        origin,
        windows: windows_of(samples, duration_sec),
        cutoff,
    }
}

/// The distinct validity windows the population declares, in first-seen order.
///
/// A `GaussianSet` carries `win_lo`/`win_hi` per gaussian and the format lets a sequence
/// declare several windows, so the writer reads them rather than forcing one. Emitting a
/// single full-duration entry meant a Rust-written keyframe-delta file could not express
/// the multi-window scene the readers now honour (issue #87).
///
/// Order is first-seen rather than sorted: `window_index` is written against this list, so
/// a stable order is what makes the indices mean the same thing on both sides.
fn windows_of(samples: &[Sample], duration_sec: f64) -> Vec<(f64, f64)> {
    let mut out: Vec<(f64, f64)> = Vec::new();
    for s in samples {
        let g = &s.gaussians;
        for i in 0..g.win_lo.len().min(g.win_hi.len()) {
            let w = (g.win_lo[i] as f64, g.win_hi[i] as f64);
            if !out
                .iter()
                .any(|e| e.0.to_bits() == w.0.to_bits() && e.1.to_bits() == w.1.to_bits())
            {
                out.push(w);
            }
        }
    }
    if out.is_empty() {
        out.push((0.0, duration_sec));
    }
    out
}

/// The row in the window table a gaussian's own window occupies.
fn window_index_of(windows: &[(f64, f64)], lo: f32, hi: f32) -> i64 {
    let w = (lo as f64, hi as f64);
    windows
        .iter()
        .position(|e| e.0.to_bits() == w.0.to_bits() && e.1.to_bits() == w.1.to_bits())
        .unwrap_or(0) as i64
}

fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = values.len();
    Some(if n % 2 == 1 {
        values[n / 2]
    } else {
        0.5 * (values[n / 2 - 1] + values[n / 2])
    })
}

// --------------------------------------------------------------------------
// Splitting a sample against its reference
// --------------------------------------------------------------------------

type DeltaGroups = (
    Vec<i64>,
    BTreeMap<u8, BinArray>,
    Vec<i64>,
    BTreeMap<u8, BinArray>,
    Vec<i64>,
);

fn delta_groups(
    reference_ids: &[i64],
    reference_bins: &BTreeMap<u8, BinArray>,
    ids: &[i64],
    bins: &BTreeMap<u8, BinArray>,
) -> Result<DeltaGroups> {
    let ref_pos: BTreeMap<i64, usize> = reference_ids
        .iter()
        .enumerate()
        .map(|(i, id)| (*id, i))
        .collect();
    let cur_set: BTreeSet<i64> = ids.iter().copied().collect();

    let death_ids: Vec<i64> = reference_ids
        .iter()
        .copied()
        .filter(|id| !cur_set.contains(id))
        .collect();

    let birth_rows: Vec<usize> = (0..ids.len())
        .filter(|&i| !ref_pos.contains_key(&ids[i]))
        .collect();
    let birth_ids: Vec<i64> = birth_rows.iter().map(|&i| ids[i]).collect();
    let birth_bins = gather(bins, &birth_rows);

    let common_rows: Vec<usize> = (0..ids.len())
        .filter(|&i| ref_pos.contains_key(&ids[i]))
        .collect();
    let common_ids: Vec<i64> = common_rows.iter().map(|&i| ids[i]).collect();
    let ref_rows: Vec<usize> = common_ids.iter().map(|id| ref_pos[id]).collect();

    // Refuse a sequence that changes a per-gaussian grid mid-group.
    for attribute in GOP_INVARIANT {
        let (Some(before), Some(after)) = (reference_bins.get(&attribute), bins.get(&attribute))
        else {
            continue;
        };
        let ch = after.channels;
        for (k, &rrow) in ref_rows.iter().enumerate() {
            let crow = common_rows[k];
            if before.values[rrow * ch..(rrow + 1) * ch] != after.values[crow * ch..(crow + 1) * ch]
            {
                return Err(Error::InvalidInput(format!(
                    "gaussian id {} changes attribute {attribute} between samples, which is fixed \
                     for a gaussian's lifetime within a group. Emit a keyframe, or a death and a \
                     birth.",
                    common_ids[k]
                )));
            }
        }
    }

    // A gaussian is updated when any of its non-invariant bins moved.
    let mut changed = vec![false; common_ids.len()];
    for (attribute, values) in bins {
        if GOP_INVARIANT.contains(attribute) {
            continue;
        }
        let Some(before) = reference_bins.get(attribute) else {
            continue;
        };
        let ch = values.channels;
        for (k, &crow) in common_rows.iter().enumerate() {
            let rrow = ref_rows[k];
            if values.values[crow * ch..(crow + 1) * ch]
                != before.values[rrow * ch..(rrow + 1) * ch]
            {
                changed[k] = true;
            }
        }
    }

    let update_local: Vec<usize> = (0..common_ids.len()).filter(|&k| changed[k]).collect();
    let update_ids: Vec<i64> = update_local.iter().map(|&k| common_ids[k]).collect();
    let mut update_bins: BTreeMap<u8, BinArray> = BTreeMap::new();
    for (attribute, values) in bins {
        if GOP_INVARIANT.contains(attribute) {
            continue;
        }
        let Some(before) = reference_bins.get(attribute) else {
            continue;
        };
        let ch = values.channels;
        let mut out = Vec::with_capacity(update_local.len() * ch);
        for &k in &update_local {
            let crow = common_rows[k];
            if ABSOLUTE_IN_UPDATE.contains(attribute) {
                out.extend_from_slice(&values.values[crow * ch..(crow + 1) * ch]);
            } else {
                let rrow = ref_rows[k];
                for c in 0..ch {
                    out.push(values.values[crow * ch + c] - before.values[rrow * ch + c]);
                }
            }
        }
        update_bins.insert(*attribute, BinArray::new(out, ch));
    }

    Ok((update_ids, update_bins, birth_ids, birth_bins, death_ids))
}

fn gather(bins: &BTreeMap<u8, BinArray>, rows: &[usize]) -> BTreeMap<u8, BinArray> {
    bins.iter()
        .map(|(attribute, array)| {
            let ch = array.channels;
            let mut values = Vec::with_capacity(rows.len() * ch);
            for &r in rows {
                values.extend_from_slice(&array.values[r * ch..(r + 1) * ch]);
            }
            (*attribute, BinArray::new(values, ch))
        })
        .collect()
}

// --------------------------------------------------------------------------
// Writing
// --------------------------------------------------------------------------

fn encode_delta_streams(
    ids: &[i64],
    bins: &BTreeMap<u8, BinArray>,
    codec: u8,
    level: u32,
) -> Result<Vec<u8>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut out = encode_stream(op::A_GAUSSIAN_ID, ids, 1, codec, level, true)?;
    for (attribute, values) in bins {
        out.extend_from_slice(&encode_stream(
            *attribute,
            &values.values,
            values.channels,
            codec,
            level,
            true,
        )?);
    }
    Ok(out)
}

fn death_streams(ids: &[i64], codec: u8, level: u32) -> Result<Vec<u8>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    encode_stream(op::A_GAUSSIAN_ID, ids, 1, codec, level, true)
}

fn keyframe_streams(
    ids: &[i64],
    bins: &BTreeMap<u8, BinArray>,
    codec: u8,
    level: u32,
) -> Result<Vec<u8>> {
    let mut out = encode_stream(op::A_GAUSSIAN_ID, ids, 1, codec, level, true)?;
    for attribute in REQUIRED {
        let values = &bins[&attribute];
        out.extend_from_slice(&encode_stream(
            attribute,
            &values.values,
            values.channels,
            codec,
            level,
            true,
        )?);
    }
    Ok(out)
}

fn aabb(samples: &[Sample]) -> Vec<f64> {
    let mut lo = [f64::INFINITY; 3];
    let mut hi = [f64::NEG_INFINITY; 3];
    let mut any = false;
    for s in samples {
        let g = &s.gaussians;
        for i in 0..g.count() {
            any = true;
            for axis in 0..3 {
                let v = g.positions[i * 3 + axis] as f64;
                lo[axis] = lo[axis].min(v);
                hi[axis] = hi[axis].max(v);
            }
        }
    }
    if !any {
        return vec![0.0; 6];
    }
    vec![lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]]
}

/// Refuse a population no instant can select under the half-open seek rule.
///
/// An empty `[t, t)` state is harmless and is permitted by the tiling rule: it covers no
/// time and carries no unreachable gaussian. A populated one would still count toward the
/// file while being absent from every reconstruction, so it is not authorable.
fn check_sample_width(sample: usize, state: &Sample, t1: f64) -> Result<()> {
    let population = state.gaussians.count();
    if state.t0 == t1 && population != 0 {
        return Err(Error::InvalidInput(format!(
            "sample {sample} has a population of {population} over the zero-width interval \
             [{}, {t1}); expected 0 there, because the half-open seek rule can never select it \
             (section 11.1)",
            state.t0
        )));
    }
    Ok(())
}

/// Check the part of §11.1 a sequence of sample starts can express.
///
/// [`write_sequence`] derives every interval end from the next sample's `t0`, and derives
/// the final end from `duration_sec`. Interior intervals therefore abut by construction:
/// this check makes sure they are not inverted, and that the two derived endpoints cover
/// the declared timeline. Keeping it ahead of grid construction and quantization makes a
/// bad timeline an authoring error before the writer does work proportional to the scene.
fn check_sample_tiling(samples: &[Sample], duration_sec: f64) -> Result<()> {
    if duration_sec.is_nan() || duration_sec == f64::NEG_INFINITY {
        return Err(Error::InvalidInput(format!(
            "duration_sec is {duration_sec}; expected a finite timeline end or +inf so the final \
             sample interval can reach it (section 11.1)"
        )));
    }

    for (sample, state) in samples.iter().enumerate() {
        if !state.t0.is_finite() {
            return Err(Error::InvalidInput(format!(
                "sample {sample} has t0={}; expected a finite sample time (section 11.1)",
                state.t0
            )));
        }
    }

    let first = samples[0].t0;
    if first != 0.0 {
        let relation = if first > 0.0 {
            "leaves a gap at the start"
        } else {
            "overlaps time before the declared timeline"
        };
        return Err(Error::InvalidInput(format!(
            "sample 0 starts at t0={first}; expected t0=0, because this {relation} (section 11.1)"
        )));
    }

    for sample in 1..samples.len() {
        let previous = samples[sample - 1].t0;
        let current = samples[sample].t0;
        if current < previous {
            return Err(Error::InvalidInput(format!(
                "sample {sample} starts at t0={current}, before sample {} at t0={previous}; \
                 expected sample times in nondecreasing order so their derived intervals abut \
                 without overlap (section 11.1)",
                sample - 1
            )));
        }
        check_sample_width(sample - 1, &samples[sample - 1], current)?;
    }

    let last_sample = samples.len() - 1;
    let last = samples[last_sample].t0;
    if last > duration_sec {
        return Err(Error::InvalidInput(format!(
            "sample {last_sample} starts at t0={last}, after duration_sec={duration_sec}; expected \
             its start at or before the declared duration so the final interval reaches that end \
             without being inverted (section 11.1)"
        )));
    }
    check_sample_width(last_sample, &samples[last_sample], duration_sec)?;
    Ok(())
}

/// Assemble a whole `keyframe-delta` file from a sequence of samples.
///
/// The samples must tile the timeline: sample `i` covers `[t_i, t_{i+1})`, the first starts
/// at 0 and the last ends at `duration_sec` (spec §11.1).
pub fn write_sequence(
    samples: &[Sample],
    duration_sec: f64,
    kd: &KeyframeDeltaOptions,
) -> Result<Vec<u8>> {
    if samples.is_empty() {
        return Err(Error::InvalidInput(
            "a keyframe-delta file needs at least one sample".into(),
        ));
    }
    check_sample_tiling(samples, duration_sec)?;
    let grids = grids_for(samples, duration_sec, kd.profile, kd.cutoff);
    let mut quantized: Vec<(Vec<i64>, BTreeMap<u8, BinArray>)> = samples
        .iter()
        .map(|s| quantize_sample(s, &grids))
        .collect::<Result<_>>()?;

    let t0s: Vec<f64> = samples.iter().map(|s| s.t0).collect();
    let mut t1s: Vec<f64> = t0s[1..].to_vec();
    t1s.push(duration_sec);

    let mut distinct: BTreeSet<i64> = BTreeSet::new();
    for (ids, _) in &quantized {
        distinct.extend(ids.iter().copied());
    }

    let mut out = MAGIC.to_vec();
    let profile_name = match kd.profile {
        Profile::Fine => "fine",
        Profile::Default => "default",
        Profile::Coarse => "coarse",
    };

    out.extend_from_slice(
        &rec::Header {
            profile: profile_name.into(),
            library: kd.library.clone(),
            duration_sec,
            gaussian_count: distinct.len() as u64,
            cutoff: kd.cutoff,
            temporal_model: "keyframe-delta".into(),
            aabb: aabb(samples),
            sh_degree: 0,
            flags: 0,
            attributes: BTreeMap::new(),
        }
        .encode(&[]),
    );
    out.extend_from_slice(
        &rec::Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: grids.origin.to_vec(),
            step_pos: grids.steps.pos,
            step_scale_log: grids.steps.scale_log,
            step_rot: grids.steps.rot,
            step_rgb: grids.steps.rgb,
            step_alpha: grids.steps.alpha,
            step_motion: grids.steps.motion,
            step_time: grids.steps.time,
            step_sigma_log: grids.steps.sigma_log,
            step_sh: grids.steps.sh,
            bounds: BTreeMap::new(),
            sh_bit_depths: Vec::new(),
        }
        .encode(&[]),
    );
    out.extend_from_slice(
        &rec::WindowTable {
            windows: grids.windows.clone(),
        }
        .encode(),
    );

    let mut index: Vec<rec::ChunkIndexEntry> = Vec::new();
    let mut offsets: Vec<u64> = Vec::new();
    let mut depths: Vec<u16> = Vec::new();
    let mut keyframe_offset: u64 = 0;

    for i in 0..quantized.len() {
        let (ids, bins) = &quantized[i];
        let (t0, t1) = (t0s[i], t1s[i]);
        if is_keyframe(i, kd) {
            // A keyframe reintroduces its complete live population at the keyframe's
            // physical start, regardless of the birth time carried by the input sample.
            // The corrected bins are both what this keyframe serializes and the reference
            // subsequent deltas subtract from. Keeping the input sample's old mu_t here
            // would make the decoder add those deltas to a different starting state.
            let mut keyframe_bins = bins.clone();
            let sigma = &bins[&op::A_SIGMA_T];
            let flags = &bins[&op::A_FLAGS];
            let mu_t = (0..ids.len())
                .map(|row| {
                    let never_fades = flags.values[row] & op::FLAG_NEVER_FADES != 0;
                    rint(t0 / grids.mu_step_for(sigma.values[row], never_fades))
                })
                .collect();
            keyframe_bins.insert(op::A_MU_T, BinArray::new(mu_t, 1));
            let streams = keyframe_streams(ids, &keyframe_bins, kd.codec, kd.level)?;
            let blob = rec::encode_chunk(t0, t1, 0, ids.len() as u32, &streams);
            let at = out.len() as u64;
            out.extend_from_slice(&blob);
            offsets.push(at);
            depths.push(0);
            keyframe_offset = at;
            index.push(rec::ChunkIndexEntry {
                t0,
                t1,
                chunk_offset: at,
                chunk_length: blob.len() as u64,
                gaussian_count: ids.len() as u32,
                bands: Vec::new(),
                extended: true,
                kind: 0,
                delta_mode: 0,
                reference_offset: 0,
                keyframe_offset: at,
                depth: 0,
                live_count: ids.len() as u64,
            });
            quantized[i].1 = keyframe_bins;
            continue;
        }

        let (ref_sample, depth) = if kd.delta_mode == rec::DELTA_MODE_KEYFRAME {
            (keyframe_index(i, kd), 1u16)
        } else {
            (i - 1, depths[i - 1] + 1)
        };
        let (ref_ids, ref_bins) = &quantized[ref_sample];
        let (update_ids, update_bins, birth_ids, birth_bins, death_ids) =
            delta_groups(ref_ids, ref_bins, ids, bins)?;
        let updates = encode_delta_streams(&update_ids, &update_bins, kd.codec, kd.level)?;
        let births = encode_delta_streams(&birth_ids, &birth_bins, kd.codec, kd.level)?;
        let deaths = death_streams(&death_ids, kd.codec, kd.level)?;
        let blob = rec::encode_delta_chunk(
            t0,
            t1,
            0,
            kd.delta_mode,
            offsets[ref_sample],
            keyframe_offset,
            depth,
            &updates,
            &births,
            &deaths,
            (
                update_ids.len() as u32,
                birth_ids.len() as u32,
                death_ids.len() as u32,
            ),
        );
        let at = out.len() as u64;
        out.extend_from_slice(&blob);
        offsets.push(at);
        depths.push(depth);
        index.push(rec::ChunkIndexEntry {
            t0,
            t1,
            chunk_offset: at,
            chunk_length: blob.len() as u64,
            gaussian_count: (update_ids.len() + birth_ids.len() + death_ids.len()) as u32,
            bands: Vec::new(),
            extended: true,
            kind: 1,
            delta_mode: kd.delta_mode,
            reference_offset: offsets[ref_sample],
            keyframe_offset,
            depth,
            live_count: ids.len() as u64,
        });
    }

    let summary_start = out.len() as u64;
    for entry in &index {
        out.extend_from_slice(&entry.encode());
    }
    out.extend_from_slice(
        &rec::Statistics {
            gaussian_count: distinct.len() as u64,
            chunk_count: index.len() as u32,
            duration_sec,
            aabb: aabb(samples),
        }
        .encode(),
    );
    let summary_bytes = out[summary_start as usize..].to_vec();

    out.extend_from_slice(
        &rec::Footer {
            summary_start,
            summary_offset_start: 0,
            summary_crc: crc32(&summary_bytes),
        }
        .encode(),
    );
    out.extend_from_slice(&MAGIC);
    Ok(out)
}

fn keyframe_index(i: usize, kd: &KeyframeDeltaOptions) -> usize {
    let mut j = i;
    while j > 0 && !is_keyframe(j, kd) {
        j -= 1;
    }
    j
}

// --------------------------------------------------------------------------
// Decoding
// --------------------------------------------------------------------------

/// One decoded state chunk and the composed population that follows from it.
#[derive(Debug, Clone)]
pub struct ChunkInfo {
    pub t0: f64,
    pub t1: f64,
    pub kind: u8,
    pub delta_mode: Option<u8>,
    pub depth: u16,
    pub offset: u64,
    pub reference_offset: u64,
    pub update_count: Option<u32>,
    pub birth_count: Option<u32>,
    pub death_count: Option<u32>,
    pub state: State,
}

/// A whole `keyframe-delta` file, decoded and composed.
#[derive(Debug, Clone)]
pub struct DecodedSequence {
    pub header: rec::Header,
    pub quantization: rec::Quantization,
    pub windows: Vec<(f64, f64)>,
    pub chunks: Vec<ChunkInfo>,
}

impl DecodedSequence {
    pub fn grids(&self) -> Grids {
        let q = &self.quantization;
        let mut origin = [0.0f64; 3];
        for (axis, slot) in origin.iter_mut().enumerate() {
            if let Some(v) = q.pos_origin.get(axis) {
                *slot = *v;
            }
        }
        Grids {
            steps: q.steps(),
            origin,
            windows: self.windows.clone(),
            cutoff: self.header.cutoff,
        }
    }
}

fn bin_array(stream: &DecodedStream) -> BinArray {
    let mut values = Vec::with_capacity(stream.count * stream.channels);
    for i in 0..stream.count {
        for c in 0..stream.channels {
            values.push(stream.get(i, c));
        }
    }
    BinArray::new(values, stream.channels)
}

fn expected_attribute_channels(attribute: u8) -> Option<usize> {
    match attribute {
        op::A_POSITION | op::A_SCALE | op::A_ROTATION | op::A_COLOR | op::A_MOTION => Some(3),
        op::A_ROTATION_INDEX
        | op::A_OPACITY
        | op::A_MU_T
        | op::A_SIGMA_T
        | op::A_FLAGS
        | op::A_WINDOW_INDEX
        | op::A_SOURCE_GROUP
        | op::A_SOURCE_INDEX
        | op::A_GAUSSIAN_ID
        | op::A_OBJECT_ID => Some(1),
        _ => None,
    }
}

fn check_attribute_channels(attribute: u8, stream: &DecodedStream) -> Result<()> {
    let Some(expected) = expected_attribute_channels(attribute) else {
        return Ok(());
    };
    if stream.channels != expected {
        return Err(Error::Malformed(format!(
            "attribute {attribute} declares {} channels; the format defines {expected}",
            stream.channels
        )));
    }
    Ok(())
}

/// Decode a version-1 state stream after checking its fixed header, or skip an unknown
/// extension by its common payload length without interpreting extension-owned semantics.
fn decode_state_stream(
    cursor: &mut Cursor<'_>,
    expected_count: usize,
) -> Result<(u8, Option<DecodedStream>)> {
    let head = cursor.rest().get(..STREAM_HEADER_SIZE).ok_or_else(|| {
        Error::Truncated(format!(
            "a keyframe-delta group ends before its {STREAM_HEADER_SIZE}-byte Attribute Stream header"
        ))
    })?;
    let attribute = head[0];
    let width = head[1];
    let mode = head[2];
    let stream_codec = head[3];
    let channels = head[4] as usize;
    let count = u32::from_le_bytes(head[5..9].try_into().expect("stream count")) as usize;
    if count != expected_count {
        return Err(Error::Malformed(format!(
            "attribute {attribute} carries {count} elements, the group declares {expected_count}"
        )));
    }
    let payload_length = u64::from_le_bytes(head[9..17].try_into().expect("stream payload length"));
    let payload_length = usize::try_from(payload_length).map_err(|_| {
        Error::Truncated(format!(
            "attribute {attribute} declares a payload larger than this platform can address"
        ))
    })?;
    if let Some(expected) = expected_attribute_channels(attribute) {
        if channels != expected {
            return Err(Error::Malformed(format!(
                "attribute {attribute} declares {channels} channels; the format defines {expected}"
            )));
        }
        if !matches!(width, 1 | 2 | 4) {
            return Err(Error::Malformed(format!(
                "attribute {attribute}: symbol width {width} is not 1, 2 or 4"
            )));
        }
        if !matches!(
            mode,
            crate::stream::MODE_RAW | crate::stream::MODE_DELTA | crate::stream::MODE_CONST
        ) {
            return Err(Error::Malformed(format!(
                "attribute {attribute}: unknown stream mode {mode}"
            )));
        }
        codec::check_decoder(stream_codec)?;
        let (decoded_attribute, stream) = decode_stream(cursor, Some(expected_count))?;
        debug_assert_eq!(decoded_attribute, attribute);
        check_attribute_channels(attribute, &stream)?;
        if let Some(value) = stream.values.iter().find(|value| {
            !(crate::keyframe_delta::BIN_MIN..=crate::keyframe_delta::BIN_MAX).contains(value)
        }) {
            return Err(Error::Malformed(format!(
                "attribute {attribute} reconstructs bin {value}, outside the signed 32-bit state domain"
            )));
        }
        return Ok((attribute, Some(stream)));
    }

    cursor.take(STREAM_HEADER_SIZE)?;
    cursor.take(payload_length)?;
    Ok((attribute, None))
}

/// One length-framed sub-block: its ids, and a bin array per other attribute.
fn decode_group(bytes: &[u8], expected_count: usize) -> Result<(Vec<i64>, BTreeMap<u8, BinArray>)> {
    if bytes.is_empty() {
        if expected_count != 0 {
            return Err(Error::Malformed(format!(
                "a keyframe-delta group declares {expected_count} gaussians but carries no streams"
            )));
        }
        return Ok((Vec::new(), BTreeMap::new()));
    }
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut seen = BTreeSet::new();
    let mut cursor = Cursor::new(bytes);
    while cursor.remaining() > 0 {
        let (attribute_id, values) = decode_state_stream(&mut cursor, expected_count)?;
        // One stream per attribute here too: the regular chunk path refuses a second,
        // and this path had its own loop that was still resolving it silently.
        if !seen.insert(attribute_id) {
            return Err(Error::Malformed(format!(
                "a keyframe-delta group carries attribute {attribute_id} twice; the \
                 format defines one stream per attribute"
            )));
        }
        if let Some(values) = values {
            got.insert(attribute_id, values);
        }
    }
    let Some(id_stream) = got.remove(&op::A_GAUSSIAN_ID) else {
        return Err(Error::Malformed(
            "a keyframe-delta group carries no gaussian_id stream".into(),
        ));
    };
    let ids: Vec<i64> = (0..id_stream.count).map(|i| id_stream.get(i, 0)).collect();
    let bins = got.iter().map(|(a, s)| (*a, bin_array(s))).collect();
    Ok((ids, bins))
}

fn keyframe_from_chunk(
    content: &[u8],
) -> Result<(rec::ChunkHeader, Vec<i64>, BTreeMap<u8, BinArray>)> {
    let (head, streams) = rec::parse_chunk(content)?;
    let streams = crate::chunk::chunk_stream_bytes(&head, streams)?;
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut seen = BTreeSet::new();
    let mut cursor = Cursor::new(&streams);
    while cursor.remaining() > 0 {
        let (attribute_id, values) = decode_state_stream(&mut cursor, head.count as usize)?;
        // One stream per attribute here too: the regular chunk path refuses a second,
        // and this path had its own loop that was still resolving it silently.
        if !seen.insert(attribute_id) {
            return Err(Error::Malformed(format!(
                "a keyframe-delta group carries attribute {attribute_id} twice; the \
                 format defines one stream per attribute"
            )));
        }
        if let Some(values) = values {
            got.insert(attribute_id, values);
        }
    }
    let Some(id_stream) = got.remove(&op::A_GAUSSIAN_ID) else {
        return Err(Error::Malformed(
            "a keyframe-delta chunk carries no gaussian_id stream".into(),
        ));
    };
    let ids: Vec<i64> = (0..id_stream.count).map(|i| id_stream.get(i, 0)).collect();
    if head.count > 0 {
        let missing: Vec<u8> = REQUIRED
            .iter()
            .copied()
            .filter(|a| !got.contains_key(a))
            .collect();
        if !missing.is_empty() {
            return Err(Error::Malformed(format!(
                "keyframe chunk is missing required attributes {missing:?}"
            )));
        }
    }
    let bins = got.iter().map(|(a, s)| (*a, bin_array(s))).collect();
    Ok((head, ids, bins))
}

struct DecodedDelta {
    head: rec::DeltaChunkHeader,
    update_ids: Vec<i64>,
    update_bins: BTreeMap<u8, BinArray>,
    birth_ids: Vec<i64>,
    birth_bins: BTreeMap<u8, BinArray>,
    death_ids: Vec<i64>,
}

fn delta_record_bytes<'a>(
    head: &rec::DeltaChunkHeader,
    records: &'a [u8],
) -> Result<Cow<'a, [u8]>> {
    let expected = usize::try_from(head.uncompressed_size).map_err(|_| {
        Error::Malformed(format!(
            "the Delta Chunk at t0={} declares {} uncompressed bytes, more than this platform can address",
            head.t0, head.uncompressed_size
        ))
    })?;
    if head.uncompressed_size > MAX_STREAM_BYTES {
        return Err(Error::Malformed(format!(
            "the Delta Chunk at t0={} declares {} uncompressed record bytes, past the {MAX_STREAM_BYTES} byte cap",
            head.t0, head.uncompressed_size
        )));
    }
    if head.compression.is_empty() {
        if records.len() != expected {
            return Err(Error::Malformed(format!(
                "the uncompressed Delta Chunk at t0={} declares {expected} record bytes but carries {}",
                head.t0,
                records.len()
            )));
        }
        return Ok(Cow::Borrowed(records));
    }
    let numeric = crate::codec::codec_from_name(&head.compression).ok_or_else(|| {
        Error::refused(
            crate::error::refusal::UNKNOWN_STREAM_CODEC,
            crate::error::RefusalKind::UnsupportedCodec,
            format!(
                "the Delta Chunk at t0={} is compressed with {:?}, which this build does not know",
                head.t0, head.compression
            ),
        )
    })?;
    Ok(Cow::Owned(crate::codec::decompress(
        records, numeric, expected,
    )?))
}

fn decode_delta(content: &[u8]) -> Result<DecodedDelta> {
    let (head, encoded_records) = rec::parse_delta_chunk_records(content)?;
    let records = delta_record_bytes(&head, encoded_records)?;
    let mut framed = Cursor::new(&records);
    let updates = framed.blob()?;
    let births = framed.blob()?;
    let deaths = framed.blob()?;
    if framed.remaining() != 0 {
        return Err(Error::Malformed(
            "a Delta Chunk carries bytes after its death group".into(),
        ));
    }
    let (update_ids, update_bins) = decode_group(updates, head.update_count as usize)?;
    let (birth_ids, birth_bins) = decode_group(births, head.birth_count as usize)?;
    let (death_ids, death_bins) = decode_group(deaths, head.death_count as usize)?;
    if !birth_ids.is_empty() {
        let missing: Vec<u8> = REQUIRED
            .iter()
            .copied()
            .filter(|attribute| !birth_bins.contains_key(attribute))
            .collect();
        if !missing.is_empty() {
            return Err(Error::Malformed(format!(
                "a non-empty birth group is missing required attributes {missing:?}"
            )));
        }
    }
    if !death_bins.is_empty() {
        return Err(Error::Malformed(format!(
            "a death group carries attributes {:?}; it may carry only gaussian_id",
            death_bins.keys().collect::<Vec<_>>()
        )));
    }
    Ok(DecodedDelta {
        head,
        update_ids,
        update_bins,
        birth_ids,
        birth_bins,
        death_ids,
    })
}

fn compose_delta(
    reference: &State,
    content: &[u8],
) -> Result<(State, rec::DeltaChunkHeader, Vec<i64>)> {
    let decoded = decode_delta(content)?;
    let state = apply_delta(
        reference,
        &decoded.update_ids,
        &decoded.update_bins,
        &decoded.birth_ids,
        &decoded.birth_bins,
        &decoded.death_ids,
    )?;
    Ok((state, decoded.head, decoded.birth_ids))
}

/// Decode one keyframe chunk's streams, check the state they make, and keep neither.
///
/// What a validator needs from a keyframe chunk of a file it cannot seek: whether the
/// streams decode and whether the window indices they carry are answerable. It is the
/// question [`decode_streamed`] answers by building a `DecodedSequence` — every state
/// resident at once — for a caller that only wanted a verdict.
pub fn check_keyframe_chunk(content: &[u8], windows: &[(f64, f64)]) -> Result<()> {
    decode_keyframe_chunk(content, windows).map(|_| ())
}

/// Decode one keyframe record content into its state and parsed header.
pub fn decode_keyframe_chunk(
    content: &[u8],
    windows: &[(f64, f64)],
) -> Result<(State, rec::ChunkHeader)> {
    let (head, ids, bins) = keyframe_from_chunk(content)?;
    let state = keyframe_state(ids, bins)?;
    check_window_indices(&state, windows)?;
    Ok((state, head))
}

/// Require every keyframe gaussian's encoded birth-time bin to name the Chunk's `t0`.
pub fn check_keyframe_mu_t(state: &State, t0: f64, quantization: &rec::Quantization) -> Result<()> {
    if state.count() == 0 {
        return Ok(());
    }
    let mu = state
        .bins
        .get(&op::A_MU_T)
        .ok_or_else(|| Error::Malformed("a non-empty keyframe carries no mu_t stream".into()))?;
    let sigma = state
        .bins
        .get(&op::A_SIGMA_T)
        .ok_or_else(|| Error::Malformed("a non-empty keyframe carries no sigma_t stream".into()))?;
    let flags = state
        .bins
        .get(&op::A_FLAGS)
        .ok_or_else(|| Error::Malformed("a non-empty keyframe carries no flags stream".into()))?;
    let steps = quantization.steps();
    for row in 0..state.count() {
        let never_fades = flags.values[row] & op::FLAG_NEVER_FADES != 0;
        let step = mu_step(sigma.values[row], steps.sigma_log, never_fades, steps.time);
        if !step.is_finite() || step <= 0.0 {
            return Err(Error::Malformed(format!(
                "keyframe gaussian_id {} has a non-finite or non-positive mu_t grid step {step}",
                state.ids[row]
            )));
        }
        let expected = rint(t0 / step);
        if mu.values[row] != expected {
            return Err(Error::Malformed(format!(
                "keyframe gaussian_id {} has mu_t bin {}; its Chunk t0 {t0} requires bin {expected}",
                state.ids[row], mu.values[row]
            )));
        }
    }
    Ok(())
}

/// The same for one delta chunk, without the reference state it would compose against.
///
/// A delta chunk's three groups are streams like any other, so an unimplemented codec or a
/// corrupt payload in one of them is found by decoding it — no reference needed, and a
/// file read front to back has none to give until the chain is walked. The window indices a
/// group carries are checked here too: births bring their own, and a birth naming a window
/// the table cannot answer is refused on the indexed path.
pub fn check_delta_chunk(content: &[u8], windows: &[(f64, f64)]) -> Result<()> {
    let decoded = decode_delta(content)?;
    let table_len = crate::chunk::window_table_or_default(windows).len();
    for bins in [&decoded.update_bins, &decoded.birth_bins] {
        let Some(window_index) = bins.get(&op::A_WINDOW_INDEX) else {
            continue;
        };
        for value in &window_index.values {
            crate::chunk::check_window_index(*value, table_len)?;
        }
    }
    Ok(())
}

/// Compose one delta record content onto a previously decoded reference state.
pub fn compose_delta_chunk(
    reference: &State,
    content: &[u8],
    windows: &[(f64, f64)],
) -> Result<(State, rec::DeltaChunkHeader, Vec<i64>)> {
    let (state, head, births) = compose_delta(reference, content)?;
    check_window_indices(&state, windows)?;
    Ok((state, head, births))
}

/// Front to back: decode each chunk and compose it onto the state it references.
pub fn decode_streamed(data: &[u8]) -> Result<DecodedSequence> {
    check_magic(data)?;
    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut chunks: Vec<ChunkInfo> = Vec::new();
    let mut by_offset: BTreeMap<u64, State> = BTreeMap::new();
    let mut state_seen = false;

    for record in Records::new(data, MAGIC.len()) {
        let record = record?;
        match record.opcode {
            op::HEADER => {
                let parsed = rec::Header::parse(record.content)?;
                check_keyframe_temporal_model(&parsed.temporal_model)?;
                if !state_seen {
                    header = Some(parsed);
                }
            }
            op::QUANTIZATION => {
                let parsed = rec::Quantization::parse(record.content)?;
                crate::registry::check_quantization_scheme(&parsed.scheme)?;
                if !state_seen {
                    quant = Some(parsed);
                }
            }
            op::WINDOW_TABLE => {
                let parsed = rec::WindowTable::parse(record.content)?;
                if !state_seen {
                    windows = parsed.windows;
                }
            }
            op::CHUNK => {
                state_seen = true;
                let (head, ids, bins) = keyframe_from_chunk(record.content)?;
                let state = keyframe_state(ids, bins)?;
                let quantization = quant.as_ref().ok_or_else(|| {
                    Error::Malformed("a keyframe appears before Quantization".into())
                })?;
                check_keyframe_mu_t(&state, head.t0, quantization)?;
                check_window_indices(&state, &windows)?;
                check_streamed_population(record.offset as u64, head.t0, head.t1, &state)?;
                by_offset.insert(record.offset as u64, state.clone());
                chunks.push(ChunkInfo {
                    t0: head.t0,
                    t1: head.t1,
                    kind: 0,
                    delta_mode: None,
                    depth: 0,
                    offset: record.offset as u64,
                    reference_offset: 0,
                    update_count: None,
                    birth_count: None,
                    death_count: None,
                    state,
                });
            }
            op::DELTA_CHUNK => {
                state_seen = true;
                let (head, _) = rec::parse_delta_chunk_records(record.content)?;
                if head.reference_offset >= record.offset as u64 {
                    return Err(Error::Malformed(format!(
                        "delta chunk at {} references {}, which is not behind it",
                        record.offset, head.reference_offset
                    )));
                }
                let Some(reference) = by_offset.get(&head.reference_offset) else {
                    return Err(Error::Malformed(format!(
                        "delta chunk at {} references {}, which has not been decoded",
                        record.offset, head.reference_offset
                    )));
                };
                let (state, head, _) = compose_delta(reference, record.content)?;
                // Births in a delta group carry their own `window_index`, so the check
                // belongs on this branch too — not only where a keyframe is read. The
                // indexed path validates the composed state for every chunk, so leaving
                // it off here would accept a birth the other path refuses.
                check_window_indices(&state, &windows)?;
                check_streamed_population(record.offset as u64, head.t0, head.t1, &state)?;
                by_offset.insert(record.offset as u64, state.clone());
                chunks.push(ChunkInfo {
                    t0: head.t0,
                    t1: head.t1,
                    kind: 1,
                    delta_mode: Some(head.delta_mode),
                    depth: head.depth,
                    offset: record.offset as u64,
                    reference_offset: head.reference_offset,
                    update_count: Some(head.update_count),
                    birth_count: Some(head.birth_count),
                    death_count: Some(head.death_count),
                    state,
                });
            }
            _ => {}
        }
    }

    let (Some(header), Some(quantization)) = (header, quant) else {
        return Err(Error::Malformed(
            "keyframe-delta file has no Header or Quantization record".into(),
        ));
    };
    Ok(DecodedSequence {
        header,
        quantization,
        windows,
        chunks,
    })
}

pub(crate) fn ranged_framing<R: crate::Readable + ?Sized>(
    source: &mut R,
    offset: u64,
    declared_length: Option<u64>,
) -> Result<(u8, u64)> {
    let size = source.size()?;
    let header_end = offset
        .checked_add(crate::serialization::RECORD_HEADER_SIZE as u64)
        .filter(|end| *end <= size)
        .ok_or_else(|| {
            Error::Truncated(format!("record framing at {offset} runs past the file"))
        })?;
    let framing = source.read(offset, header_end - offset)?;
    let opcode = framing[0];
    let content_length = u64::from_le_bytes(framing[1..9].try_into().expect("nine-byte framing"));
    let total = content_length
        .checked_add(crate::serialization::RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| {
            Error::Truncated(format!(
                "the {} record at {offset} has a length that overflows",
                op::name(opcode)
            ))
        })?;
    if let Some(declared) = declared_length {
        if declared != total {
            return Err(Error::Malformed(format!(
                "the index declares {declared} bytes for the {} record at {offset}; its framing declares {total}",
                op::name(opcode)
            )));
        }
    }
    let content_at = offset + crate::serialization::RECORD_HEADER_SIZE as u64;
    content_at.checked_add(content_length).filter(|end| *end <= size).ok_or_else(
        || {
            Error::Truncated(format!(
                "the {} record at {offset} declares {content_length} bytes past the end of the {size}-byte file",
                op::name(opcode)
            ))
        },
    )?;
    Ok((opcode, content_length))
}

pub(crate) fn ranged_record<R: crate::Readable + ?Sized>(
    source: &mut R,
    offset: u64,
    declared_length: Option<u64>,
) -> Result<(u8, Vec<u8>)> {
    let (opcode, content_length) = ranged_framing(source, offset, declared_length)?;
    let content_at = offset + crate::serialization::RECORD_HEADER_SIZE as u64;
    Ok((opcode, source.read(content_at, content_length)?))
}

/// Parse a geometrically growing Header prefix, capped at the indexed front-matter limit.
/// Its declared length still locates the next record.
pub(crate) fn ranged_header<R: crate::Readable + ?Sized>(
    source: &mut R,
    content_at: u64,
    content_length: u64,
) -> Result<rec::Header> {
    const HEADER_PROBE: u64 = 8 * 1024;
    let cap = content_length.min(crate::indexed_reader::MAX_FRONT_MATTER_BYTES);
    let mut length = cap.min(HEADER_PROBE);
    loop {
        let prefix = source.read(content_at, length)?;
        match rec::Header::parse(&prefix) {
            Ok(header) => return Ok(header),
            Err(Error::Truncated(message)) if length < cap => {
                length = length.saturating_mul(2).max(1).min(cap);
                let _ = message;
            }
            Err(Error::Truncated(message)) if content_length > cap => {
                return Err(Error::Malformed(format!(
                    "the Header's required fields do not fit in the {} byte front-matter ceiling: {message}",
                    crate::indexed_reader::MAX_FRONT_MATTER_BYTES
                )))
            }
            Err(error) => return Err(error),
        }
    }
}

/// Read variable Quantization or Window Table content after enforcing the shared ceiling.
pub(crate) fn ranged_front_matter_content<R: crate::Readable + ?Sized>(
    source: &mut R,
    content_at: u64,
    content_length: u64,
    what: &str,
) -> Result<Vec<u8>> {
    if content_length > crate::indexed_reader::MAX_FRONT_MATTER_BYTES {
        return Err(Error::Malformed(format!(
            "the {what} record is {content_length} bytes, past the {} byte ceiling for a single front-matter record",
            crate::indexed_reader::MAX_FRONT_MATTER_BYTES
        )));
    }
    source.read(content_at, content_length)
}

fn check_keyframe_temporal_model(model: &str) -> Result<()> {
    if model == "keyframe-delta" {
        return Ok(());
    }
    Err(Error::refused(
        crate::error::refusal::UNKNOWN_TEMPORAL_MODEL,
        crate::error::RefusalKind::UnsupportedModel,
        format!(
            "the Header declares temporal model '{model}', which this reader does not implement \
             (it implements keyframe-delta)"
        ),
    ))
}

/// Refuse a `window_index` the table cannot answer, on either read path.
///
/// The table defaults to a single `(0, 0)` entry when a file declares none
/// (`chunk::window_table_or_default`), so index 0 stays legal for a file with no Window
/// Table — validating against the raw count would refuse those files on one path while
/// the other decoded them.
fn check_window_indices(state: &State, windows: &[(f64, f64)]) -> Result<()> {
    let table_len = crate::chunk::window_table_or_default(windows).len();
    let Some(window_index) = state.bins.get(&op::A_WINDOW_INDEX) else {
        // A zero-count keyframe can omit every stream, and `apply_delta` only carries
        // forward attributes the reference already had — so a later birth can compose a
        // non-empty state with no window_index at all. Reconstruction indexes it, so
        // this has to be a refusal here rather than a panic there.
        if state.count() > 0 {
            return Err(Error::Malformed(
                "a non-empty state carries no window_index column; it is a required \
                 keyframe attribute (section 11.5)"
                    .into(),
            ));
        }
        return Ok(());
    };
    for &index in &window_index.values {
        crate::chunk::check_window_index(index, table_len)?;
    }
    Ok(())
}

/// Fetch and decode one indexed keyframe through the caller's range source.
///
/// The returned state is one chunk's population. A sequential validator can retain it as
/// its current/GOP reference, advance once, and never accumulate a state per index entry.
pub fn read_keyframe_entry<R: crate::Readable + ?Sized>(
    source: &mut R,
    entry: &rec::ChunkIndexEntry,
    quantization: &rec::Quantization,
    windows: &[(f64, f64)],
) -> Result<(State, rec::ChunkHeader)> {
    let (opcode, content) = ranged_record(source, entry.chunk_offset, Some(entry.chunk_length))?;
    if opcode != op::CHUNK {
        return Err(Error::Malformed(format!(
            "the keyframe index entry at {} points at {}",
            entry.chunk_offset,
            op::name(opcode)
        )));
    }
    let (state, head) = decode_keyframe_chunk(&content, windows)?;
    check_keyframe_mu_t(&state, head.t0, quantization)?;
    Ok((state, head))
}

/// Fetch and compose one indexed delta through the caller's range source.
///
/// `birth_ids` is returned with the state so a bounded full-file validator can stream
/// identity-introduction events to its fixed-memory counter without decoding the record a
/// second time.
pub fn read_delta_entry<R: crate::Readable + ?Sized>(
    source: &mut R,
    entry: &rec::ChunkIndexEntry,
    reference: &State,
    windows: &[(f64, f64)],
) -> Result<(State, rec::DeltaChunkHeader, Vec<i64>)> {
    let (opcode, content) = ranged_record(source, entry.chunk_offset, Some(entry.chunk_length))?;
    if opcode != op::DELTA_CHUNK {
        return Err(Error::Malformed(format!(
            "the delta index entry at {} points at {}",
            entry.chunk_offset,
            op::name(opcode)
        )));
    }
    compose_delta_chunk(reference, &content, windows)
}

/// Check that an indexed entry's declared population is the state composition produced.
///
/// A zero-width half-open interval cannot expose a populated state at any instant. Keeping
/// this check beside composition makes the range-seeking decoder and the full-file validator
/// enforce the same invariant.
pub fn check_composed_population(entry: &rec::ChunkIndexEntry, state: &State) -> Result<()> {
    let composed = state.count() as u64;
    if entry.live_count != composed {
        return Err(Error::Malformed(format!(
            "the index entry at {} declares live_count {}; composing its [{}, {}) state yields {} gaussians",
            entry.chunk_offset, entry.live_count, entry.t0, entry.t1, composed
        )));
    }
    if entry.t0 == entry.t1 && composed != 0 {
        return Err(Error::Malformed(format!(
            "the index entry at {} composes {} gaussians over the zero-width interval [{}, {}); expected 0 because no instant can select a half-open zero-width interval",
            entry.chunk_offset, composed, entry.t0, entry.t1
        )));
    }
    Ok(())
}

/// Refuse populated zero-width state records on the front-to-back path.
///
/// An indexed entry carries `live_count`, so [`check_composed_population`] checks both that
/// declaration and this half-open interval invariant. A streamed record has no separate count;
/// its composed state is the authoritative population and must obey the same rule.
pub fn check_streamed_population(
    record_offset: u64,
    t0: f64,
    t1: f64,
    state: &State,
) -> Result<()> {
    let composed = state.count();
    if t0 == t1 && composed != 0 {
        return Err(Error::Malformed(format!(
            "the streamed state record at {record_offset} composes {composed} gaussians over the zero-width interval [{t0}, {t1}); expected 0 because no instant can select a half-open zero-width interval"
        )));
    }
    Ok(())
}

/// Compose the chain ending at `entry`, and check the state it produces.
///
/// Public because a range-seeking caller may want one instant without materializing the
/// asset. A full-file validator should instead walk entries once with
/// [`read_keyframe_entry`] and [`read_delta_entry`], retaining only its current/GOP states;
/// calling this for every chained entry would decode the same prefixes repeatedly.
pub fn compose_chain<R: crate::Readable + ?Sized>(
    source: &mut R,
    index: &[rec::ChunkIndexEntry],
    entry: &rec::ChunkIndexEntry,
    quantization: &rec::Quantization,
    windows: &[(f64, f64)],
) -> Result<State> {
    // Compose the entry the caller named. Recovering it via a midpoint is equivalent for
    // ordinary half-open intervals, but impossible for a valid empty `[t, t)` entry.
    let chain = chain_ending_at(index, entry)?;
    let mut state: Option<State> = None;
    for link in &chain {
        if link.kind == 0 {
            state = Some(read_keyframe_entry(source, link, quantization, windows)?.0);
        } else {
            let reference = state
                .take()
                .ok_or_else(|| Error::Malformed("a chain begins with a delta chunk".into()))?;
            state = Some(read_delta_entry(source, link, &reference, windows)?.0);
        }
    }
    let state = state.ok_or_else(|| Error::Malformed("an empty chain".into()))?;
    check_window_indices(&state, windows)?;
    check_composed_population(entry, &state)?;
    Ok(state)
}

/// A `keyframe-delta` file's front matter and its index, with nothing composed.
///
/// What [`decode_indexed`] reads before it decodes anything, split out because two callers
/// want only this much: one that means to compose a single instant, and one that means to
/// check each chunk in turn and keep none of them.
#[derive(Debug, Clone)]
pub struct IndexedSequence {
    pub header: rec::Header,
    pub quantization: rec::Quantization,
    pub windows: Vec<(f64, f64)>,
    pub index: Vec<rec::ChunkIndexEntry>,
}

/// Read the Footer and the index, and check that the index tiles the timeline.
///
/// The quantization scheme is checked against the registry as the record is read, exactly as
/// [`crate::indexed_reader::open_indexed`] checks it on the gaussian-birth path. Parsing a
/// Quantization record is not the same as understanding it: a file declaring a scheme this
/// build does not implement parses perfectly and dequantizes to nothing meaningful, and this
/// path used to carry it all the way to a composed state — so `4dgs validate` printed
/// `valid` for a file the other model's reader refuses by name.
///
/// Every Header is checked here too. The shared temporal-model registry belongs to the
/// gaussian-birth reader and therefore does not list `keyframe-delta`; this model-specific
/// reader performs the equivalent named check against the one model it implements. Doing
/// so per record matters when duplicate Headers disagree.
pub fn open_indexed<R: crate::Readable + ?Sized>(source: &mut R) -> Result<IndexedSequence> {
    let size = source.size()?;
    let head = source.read(0, (MAGIC.len() as u64).min(size))?;
    check_magic(&head)?;
    const FOOTER_CONTENT: u64 = 20;
    let footer_total = crate::serialization::RECORD_HEADER_SIZE as u64 + FOOTER_CONTENT;
    let fixed_tail = footer_total + MAGIC.len() as u64;
    if size < MAGIC.len() as u64 + fixed_tail {
        return Err(Error::Truncated(
            "the file is too short to contain a Header, Footer, and both magic values".into(),
        ));
    }
    let footer_at = size - fixed_tail;
    let tail = source.read(footer_at, fixed_tail)?;
    if tail[footer_total as usize..] != MAGIC {
        return Err(Error::Malformed(
            "file does not end with the magic; it may be truncated".into(),
        ));
    }
    if tail[0] != op::FOOTER {
        return Err(Error::Malformed(format!(
            "the final record is {}; expected Footer",
            op::name(tail[0])
        )));
    }
    let footer_length = u64::from_le_bytes(
        tail[1..crate::serialization::RECORD_HEADER_SIZE]
            .try_into()
            .expect("nine-byte Footer framing"),
    );
    if footer_length != FOOTER_CONTENT {
        return Err(Error::Malformed(format!(
            "the final Footer declares {footer_length} content bytes; this version defines {FOOTER_CONTENT}"
        )));
    }
    let footer =
        rec::Footer::parse(&tail[crate::serialization::RECORD_HEADER_SIZE..footer_total as usize])?;
    if footer.summary_start > footer_at {
        return Err(Error::Malformed(format!(
            "the footer says the summary starts at {}, past the footer itself at {footer_at}",
            footer.summary_start
        )));
    }

    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut at = MAGIC.len() as u64;
    // Front matter ends at the first state record. Indexed open must not turn into a
    // physical-record scan: the tail locates the index, and composition later reads only
    // the selected chain. The streamed path uses the same pre-state declarations as the
    // authoritative Header, Quantization and Window Table.
    while at < footer_at {
        let (opcode, content_length) = ranged_framing(source, at, None)?;
        let total = crate::serialization::RECORD_HEADER_SIZE as u64 + content_length;
        if opcode == op::CHUNK || opcode == op::DELTA_CHUNK {
            break;
        }
        match opcode {
            op::HEADER => {
                let parsed = ranged_header(
                    source,
                    at + crate::serialization::RECORD_HEADER_SIZE as u64,
                    content_length,
                )?;
                check_keyframe_temporal_model(&parsed.temporal_model)?;
                header = Some(parsed);
            }
            op::QUANTIZATION => {
                let content = ranged_front_matter_content(
                    source,
                    at + crate::serialization::RECORD_HEADER_SIZE as u64,
                    content_length,
                    "Quantization",
                )?;
                let parsed = rec::Quantization::parse(&content)?;
                crate::registry::check_quantization_scheme(&parsed.scheme)?;
                quant = Some(parsed);
            }
            op::WINDOW_TABLE => {
                let content = ranged_front_matter_content(
                    source,
                    at + crate::serialization::RECORD_HEADER_SIZE as u64,
                    content_length,
                    "Window Table",
                )?;
                windows = rec::WindowTable::parse(&content)?.windows;
            }
            _ => {}
        }
        at = at
            .checked_add(total)
            .ok_or_else(|| Error::Truncated("record walk offset overflows".into()))?;
        if at > footer_at {
            return Err(Error::Truncated(format!(
                "the {} record before the final Footer extends to byte {at}, past the Footer at {footer_at}",
                op::name(opcode)
            )));
        }
    }
    let (Some(header), Some(quantization)) = (header, quant) else {
        return Err(Error::Malformed(
            "keyframe-delta file has no Header or Quantization record".into(),
        ));
    };

    let mut index: Vec<rec::ChunkIndexEntry> = Vec::new();
    let mut summary_at = footer.summary_start;
    while summary_at != 0 && summary_at < footer_at {
        let (opcode, content_length) = ranged_framing(source, summary_at, None)?;
        let total = (crate::serialization::RECORD_HEADER_SIZE as u64)
            .checked_add(content_length)
            .ok_or_else(|| Error::Truncated("summary record length overflows".into()))?;
        let end = summary_at
            .checked_add(total)
            .filter(|end| *end <= footer_at)
            .ok_or_else(|| {
                Error::Malformed(format!(
                    "the {} record at {summary_at} extends past the Footer at {footer_at}",
                    op::name(opcode)
                ))
            })?;
        if opcode != op::CHUNK_INDEX {
            break;
        }
        let content = source.read(
            summary_at + crate::serialization::RECORD_HEADER_SIZE as u64,
            content_length,
        )?;
        index.push(rec::ChunkIndexEntry::parse(&content)?);
        summary_at = end;
    }
    check_tiling(&index)?;
    check_timeline_endpoints(&index, header.duration_sec)?;

    Ok(IndexedSequence {
        header,
        quantization,
        windows,
        index,
    })
}

/// Read the Footer, then the index, then compose each chunk by walking its chain.
pub fn decode_indexed(data: &[u8]) -> Result<(DecodedSequence, Vec<rec::ChunkIndexEntry>)> {
    let mut source = crate::BytesReadable::new(data);
    let IndexedSequence {
        header,
        quantization,
        windows,
        index,
    } = open_indexed(&mut source)?;

    let mut chunks: Vec<ChunkInfo> = Vec::with_capacity(index.len());
    for entry in &index {
        let state = compose_chain(&mut source, &index, entry, &quantization, &windows)?;
        let (update_count, birth_count, death_count) = if entry.kind != 0 {
            let (_, content) =
                ranged_record(&mut source, entry.chunk_offset, Some(entry.chunk_length))?;
            let (head, _) = rec::parse_delta_chunk_records(&content)?;
            (
                Some(head.update_count),
                Some(head.birth_count),
                Some(head.death_count),
            )
        } else {
            (None, None, None)
        };
        chunks.push(ChunkInfo {
            t0: entry.t0,
            t1: entry.t1,
            kind: entry.kind,
            delta_mode: if entry.kind != 0 {
                Some(entry.delta_mode)
            } else {
                None
            },
            depth: entry.depth,
            offset: entry.chunk_offset,
            reference_offset: entry.reference_offset,
            update_count,
            birth_count,
            death_count,
            state,
        });
    }

    Ok((
        DecodedSequence {
            header,
            quantization,
            windows,
            chunks,
        },
        index,
    ))
}

// --------------------------------------------------------------------------
// Reconstruction
// --------------------------------------------------------------------------

/// The composed population reconstructed at instant `t`, per spec §3, in id order.
///
/// Everything orders by `gaussian_id`, which is unique within a state — decoded-value order,
/// not stream order — so two implementations that compose the same population agree on every
/// row. All arithmetic is `f64`, matching the Python reference, so the six-decimal canonical
/// comparison is exact.
#[derive(Debug, Clone, Default)]
pub struct Reconstruction {
    /// Ids in ascending order.
    pub ids: Vec<i64>,
    /// `3` per gaussian: `position + motion * (t - mu)`.
    pub centers: Vec<f64>,
    /// `3` per gaussian.
    pub scales: Vec<f64>,
    /// `color.a * marginal` per gaussian.
    pub opacity: Vec<f64>,
}

pub fn reconstruct_at(seq: &DecodedSequence, state: &State, t: f64) -> Reconstruction {
    let grids = seq.grids();
    let n = state.count();
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by_key(|&i| state.ids[i]);

    let mut out = Reconstruction {
        ids: Vec::with_capacity(n),
        centers: Vec::with_capacity(n * 3),
        scales: Vec::with_capacity(n * 3),
        opacity: Vec::with_capacity(n),
    };
    if n == 0 {
        return out;
    }
    let position = &state.bins[&op::A_POSITION];
    let scale = &state.bins[&op::A_SCALE];
    let opacity = &state.bins[&op::A_OPACITY];
    let motion = &state.bins[&op::A_MOTION];
    let mu = &state.bins[&op::A_MU_T];
    let sigma = &state.bins[&op::A_SIGMA_T];
    let flags = &state.bins[&op::A_FLAGS];
    let window = &state.bins[&op::A_WINDOW_INDEX];

    for &i in &order {
        // A gaussian is absent outside its own validity window, exactly as the
        // gaussian-birth path decides it (`win_lo <= t < win_hi`) — dropped, not merely
        // made transparent, so id, centre, scale and the live count all exclude it.
        // Unobservable while every keyframe-delta file carried one full-duration window;
        // reachable the moment a file declares more than one.
        let (lo, hi) = grids.window_at(window.values[i]);
        if !(lo <= t && t < hi) {
            continue;
        }
        out.ids.push(state.ids[i]);
        let sigma_bin = sigma.values[i];
        let never_fades = flags.values[i] != 0;
        let sigma_f = if never_fades {
            f64::INFINITY
        } else {
            (sigma_bin as f64 * grids.steps.sigma_log).exp()
        };
        let m_step = grids.motion_step_for(sigma_bin, never_fades, window.values[i]);
        let t_step = grids.mu_step_for(sigma_bin, never_fades);
        let mu_f = mu.values[i] as f64 * t_step;

        for axis in 0..3 {
            let pos = position.values[i * 3 + axis] as f64 * grids.steps.pos + grids.origin[axis];
            let vel = motion.values[i * 3 + axis] as f64 * m_step;
            out.centers.push(pos + vel * (t - mu_f));
            out.scales
                .push((scale.values[i * 3 + axis] as f64 * grids.steps.scale_log).exp());
        }

        let alpha = (opacity.values[i] as f64 * grids.steps.alpha).clamp(0.0, 1.0);
        let marginal = if sigma_f.is_infinite() {
            1.0
        } else {
            let z = (t - mu_f) / sigma_f;
            (-0.5 * z * z).exp()
        };
        out.opacity.push(alpha * marginal);
    }
    out
}

/// Every chunk's `t0` and interval midpoint, plus one instant just below the end.
pub fn probe_times(chunks: &[ChunkInfo], duration_sec: f64) -> Vec<f64> {
    let mut times: Vec<f64> = Vec::new();
    for c in chunks {
        times.push(round9(c.t0));
        times.push(round9((c.t0 + c.t1) / 2.0));
    }
    times.push(round9((duration_sec - 1e-6).max(0.0)));
    times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    times.dedup();
    times
}

/// The composed state covering `t`, or the last chunk when none does.
pub fn state_covering(chunks: &[ChunkInfo], t: f64) -> &ChunkInfo {
    chunks
        .iter()
        .find(|c| c.t0 <= t && t < c.t1)
        .unwrap_or_else(|| {
            chunks
                .last()
                .expect("a decoded sequence has at least one chunk")
        })
}

fn round9(v: f64) -> f64 {
    format!("{v:.9}").parse().unwrap_or(v)
}

// --------------------------------------------------------------------------
// The canonical states summary
// --------------------------------------------------------------------------
//
// The statement two implementations are diffed on for a `keyframe-delta` file, computed
// here in the core so every SDK — C++ and Swift bind it through the C ABI — emits the same
// bytes. It lived in the conformance crate first; lifting it here is what lets a binding
// that cannot open a keyframe-delta scene still produce the summary the suite compares.
//
// Representation is pinned exactly as the shared canonical pins it: integers are strings so
// a 64-bit value survives a double-backed JSON parser, floats round to a fixed number of
// decimals so two languages spell the same double, a non-finite float is `null`, and object
// keys are sorted (a `BTreeMap`). Nothing here depends on decoded stream order: every row
// orders by `gaussian_id`, which is unique within a state, so two decoders that compose the
// same population agree on every row.

/// Decimal places every float in the states summary carries, matching the shared canonical.
const STATES_JSON_DECIMALS: usize = 6;

/// A JSON value whose objects are sorted by key. Deliberately a private mirror of the
/// conformance emitter rather than a dependency on it: the core does not depend on its own
/// test crate, and the two are diffed against each other by construction — the conformance
/// runner calls this function.
enum Json {
    Null,
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    fn obj(pairs: Vec<(&str, Json)>) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    fn write(&self, out: &mut String) {
        use std::fmt::Write as _;
        match self {
            Json::Null => out.push_str("null"),
            // Always the fixed precision: the harness compares parsed values, and a fixed
            // precision is what makes two languages produce the same double.
            Json::Num(v) => {
                let _ = write!(out, "{v:.*}", STATES_JSON_DECIMALS);
            }
            Json::Str(s) => write_json_string(out, s),
            Json::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Json::Obj(map) => {
                out.push('{');
                for (i, (key, value)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json_string(out, key);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }

    fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }
}

fn write_json_string(out: &mut String, s: &str) {
    use std::fmt::Write as _;
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Round for comparison; a non-finite value becomes `null`.
fn num(v: f64) -> Json {
    if v.is_finite() {
        Json::Num(v)
    } else {
        Json::Null
    }
}

/// An integer as a string, so a 64-bit value survives a JSON parser backed by doubles.
fn int(v: u64) -> Json {
    Json::Str(v.to_string())
}

fn opt_int(v: Option<u32>) -> Json {
    match v {
        None => Json::Null,
        Some(v) => int(v as u64),
    }
}

/// The statement two implementations are diffed on for a `keyframe-delta` file.
///
/// `chunks` proves a decoder read `depth`, `deltaMode` and `liveCount` — a field no row
/// mentions is one an implementation can decline to decode. `states` is the reconstruction
/// at an instant: for each probe, the composed population's live count, a sample of centres
/// and scales in id order, and the aggregate over the whole population. Reconstruction is in
/// `f64`, matching the Python reference, so the fixed-precision comparison is exact.
pub fn keyframe_delta_states_json(seq: &DecodedSequence) -> String {
    let duration = seq.header.duration_sec;

    let chunk_rows: Vec<Json> = seq
        .chunks
        .iter()
        .map(|c| {
            let delta_mode = if c.kind == 0 {
                Json::Null
            } else if c.delta_mode == Some(rec::DELTA_MODE_CHAINED) {
                Json::Str("chained".into())
            } else {
                Json::Str("keyframe".into())
            };
            Json::obj(vec![
                ("t0", num(c.t0)),
                ("t1", num(c.t1)),
                (
                    "kind",
                    Json::Str(if c.kind == 0 { "keyframe" } else { "delta" }.into()),
                ),
                ("deltaMode", delta_mode),
                ("depth", int(c.depth as u64)),
                ("liveCount", int(c.state.count() as u64)),
                ("updateCount", opt_int(c.update_count)),
                ("birthCount", opt_int(c.birth_count)),
                ("deathCount", opt_int(c.death_count)),
            ])
        })
        .collect();

    let mut states: Vec<Json> = Vec::new();
    for t in probe_times(&seq.chunks, duration) {
        let info = state_covering(&seq.chunks, t);
        let r = reconstruct_at(seq, &info.state, t);
        let n = r.ids.len();
        let sample_n = SAMPLE.min(n);

        let gaussian_ids: Vec<Json> = r.ids[..sample_n]
            .iter()
            .map(|id| Json::Str(id.to_string()))
            .collect();
        let positions: Vec<Json> = (0..sample_n)
            .map(|i| Json::Arr((0..3).map(|k| num(r.centers[i * 3 + k])).collect()))
            .collect();
        let scales: Vec<Json> = (0..sample_n)
            .map(|i| Json::Arr((0..3).map(|k| num(r.scales[i * 3 + k])).collect()))
            .collect();

        let mut position_sum = [0.0f64; 3];
        for i in 0..n {
            for (axis, slot) in position_sum.iter_mut().enumerate() {
                *slot += r.centers[i * 3 + axis];
            }
        }
        let opacity_sum: f64 = r.opacity.iter().sum();

        states.push(Json::obj(vec![
            ("t", num(t)),
            // The count at this instant, from the rows reconstruction returned:
            // `info.state.count()` is the chunk's population, which differs once a
            // validity window has closed.
            ("liveCount", int(r.ids.len() as u64)),
            (
                "sample",
                Json::obj(vec![
                    ("gaussianIds", Json::Arr(gaussian_ids)),
                    ("positions", Json::Arr(positions)),
                    ("scales", Json::Arr(scales)),
                ]),
            ),
            (
                "aggregate",
                Json::obj(vec![
                    (
                        "positionSum",
                        Json::Arr(position_sum.iter().map(|v| num(*v)).collect()),
                    ),
                    ("opacitySum", num(opacity_sum)),
                ]),
            ),
        ]));
    }

    Json::obj(vec![
        ("temporalModel", Json::Str("keyframe-delta".into())),
        ("gaussianCount", int(seq.header.gaussian_count)),
        ("durationSec", num(duration)),
        ("cutoff", num(seq.header.cutoff)),
        ("chunks", Json::Arr(chunk_rows)),
        ("states", Json::Arr(states)),
    ])
    .to_json()
}

/// The Header's declared temporal model, read without decoding the body.
///
/// A binding that dispatches on the temporal model needs it before it commits to a read
/// path, and the ordinary open refuses a model this build's scene reader does not implement
/// — so a keyframe-delta file cannot answer the question through an opened scene. This walks
/// only as far as the Header record and reads the one field.
pub fn peek_temporal_model(data: &[u8]) -> Result<String> {
    check_magic(data)?;
    for record in Records::new(data, MAGIC.len()) {
        let record = record?;
        if record.opcode == op::HEADER {
            return Ok(rec::Header::parse(record.content)?.temporal_model);
        }
    }
    Err(Error::Malformed(
        "file has no Header record to read a temporal model from".into(),
    ))
}

#[cfg(test)]
mod window_grid_tests {
    use super::*;

    fn grids(windows: Vec<(f64, f64)>) -> Grids {
        Grids {
            steps: Steps::of(&Bounds::for_profile(Profile::Default, 1e-2)),
            origin: [0.0; 3],
            windows,
            cutoff: 0.05,
        }
    }

    #[test]
    fn a_never_fading_gaussian_takes_the_grid_of_the_window_it_names() {
        // `life_half` reads the window length only when `never_fades` is set, so this is
        // the shape where the index actually changes the answer — and the reason a test
        // driven through `write_sequence` cannot see it: that writer emits no
        // never-fading gaussians.
        let g = grids(vec![(0.0, 10.0), (0.0, 0.5)]);
        let long = g.motion_step_for(0, true, 0);
        let short = g.motion_step_for(0, true, 1);
        assert_ne!(
            long, short,
            "a 10s window and a 0.5s window cannot share a velocity grid"
        );
    }

    #[test]
    fn an_absent_window_table_is_one_default_window() {
        // Not an unbounded fallback: index 0 is legal, and the length is the default
        // window's, which is what the chunk path's `window_table_or_default` means.
        let g = grids(Vec::new());
        assert_eq!(g.window_len(0), 0.0);
        assert_eq!(g.window_len(7), 0.0, "the fallback is total, not a panic");
    }
}

#[cfg(test)]
mod hostile_record_tests {
    use super::*;
    use crate::codec;
    use crate::readable::Readable;
    use crate::serialization::{put_blob, put_f64, put_string, put_u16, put_u32, put_u64};
    use crate::BytesReadable;

    fn record_content(record: &[u8]) -> &[u8] {
        &record[crate::serialization::RECORD_HEADER_SIZE..]
    }

    fn empty_delta_records() -> Vec<u8> {
        let mut records = Vec::new();
        put_blob(&mut records, &[]);
        put_blob(&mut records, &[]);
        put_blob(&mut records, &[]);
        records
    }

    fn delta_content_with_compression(name: &str, payload: &[u8], decoded_size: u64) -> Vec<u8> {
        let mut body = Vec::new();
        put_f64(&mut body, 0.0);
        put_f64(&mut body, 1.0);
        put_u32(&mut body, 0);
        body.push(rec::DELTA_MODE_CHAINED);
        put_u64(&mut body, 8);
        put_u64(&mut body, 8);
        put_u16(&mut body, 1);
        put_u32(&mut body, 0);
        put_u32(&mut body, 0);
        put_u32(&mut body, 0);
        put_string(&mut body, name);
        put_u64(&mut body, decoded_size);
        put_blob(&mut body, payload);
        body
    }

    fn chunk_content_with_compression(
        name: &str,
        payload: &[u8],
        decoded_size: u64,
        count: u32,
    ) -> Vec<u8> {
        let mut body = Vec::new();
        put_f64(&mut body, 0.0);
        put_f64(&mut body, 1.0);
        put_u32(&mut body, 0);
        put_u32(&mut body, count);
        put_string(&mut body, name);
        put_u64(&mut body, decoded_size);
        put_blob(&mut body, payload);
        body
    }

    fn raw_stream_header(
        attribute: u8,
        width: u8,
        mode: u8,
        stream_codec: u8,
        channels: u8,
        count: u32,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut stream = vec![attribute, width, mode, stream_codec, channels];
        put_u32(&mut stream, count);
        put_u64(&mut stream, payload.len() as u64);
        stream.extend_from_slice(payload);
        stream
    }

    #[test]
    fn delta_chunk_compression_is_decoded_before_group_framing() {
        let records = empty_delta_records();
        let compressed = codec::compress(&records, codec::DEFLATE, 6).unwrap();
        let content = delta_content_with_compression("deflate", &compressed, records.len() as u64);
        check_delta_chunk(&content, &[]).unwrap();
    }

    #[test]
    fn keyframe_chunk_compression_is_decoded_before_stream_framing() {
        let streams = encode_stream(op::A_GAUSSIAN_ID, &[], 1, codec::DEFLATE, 6, true).unwrap();
        let compressed = codec::compress(&streams, codec::DEFLATE, 6).unwrap();
        let content =
            chunk_content_with_compression("deflate", &compressed, streams.len() as u64, 0);
        decode_keyframe_chunk(&content, &[]).unwrap();
    }

    #[test]
    fn a_compressed_keyframe_cannot_expand_past_the_fixed_cap() {
        let content = chunk_content_with_compression(
            "deflate",
            &[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01],
            MAX_STREAM_BYTES + 1,
            0,
        );
        let error = decode_keyframe_chunk(&content, &[]).unwrap_err();
        assert!(error.to_string().contains("past the"), "{error}");
        assert!(error.to_string().contains("byte cap"), "{error}");
    }

    #[test]
    fn an_unknown_delta_chunk_compression_is_a_named_refusal() {
        let records = empty_delta_records();
        let content =
            delta_content_with_compression("future-codec", &records, records.len() as u64);
        let error = check_delta_chunk(&content, &[]).unwrap_err();
        assert_eq!(
            error.refusal_code(),
            Some(crate::error::refusal::UNKNOWN_STREAM_CODEC)
        );
    }

    #[test]
    fn a_delta_records_block_cannot_decompress_past_the_fixed_cap() {
        let content = delta_content_with_compression(
            "deflate",
            &[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01],
            MAX_STREAM_BYTES + 1,
        );
        let error = check_delta_chunk(&content, &[]).unwrap_err();
        assert!(error.to_string().contains("past the"), "{error}");
        assert!(error.to_string().contains("byte cap"), "{error}");
    }

    #[test]
    fn an_uncompressed_delta_records_block_must_match_its_declared_size() {
        let records = empty_delta_records();
        let content = delta_content_with_compression("", &records, records.len() as u64 + 1);
        let error = check_delta_chunk(&content, &[]).unwrap_err();
        assert!(error.to_string().contains("declares"), "{error}");
        assert!(error.to_string().contains("but carries"), "{error}");
    }

    #[test]
    fn defined_attributes_must_use_their_defined_channel_count() {
        let bytes = encode_stream(op::A_POSITION, &[1, 2], 2, codec::DEFLATE, 6, true).unwrap();
        let error = decode_group(&bytes, 1).unwrap_err();
        assert!(error.to_string().contains("declares 2 channels"), "{error}");
    }

    #[test]
    fn defined_attribute_channels_are_checked_before_payload_decode() {
        let stream = raw_stream_header(
            op::A_POSITION,
            1,
            crate::stream::MODE_RAW,
            9,
            255,
            (1 << 20) as u32,
            &[],
        );
        let error = decode_group(&stream, 1 << 20).unwrap_err();
        assert!(
            error.to_string().contains("declares 255 channels"),
            "{error}"
        );
    }

    #[test]
    fn unknown_attributes_are_skipped_without_decoding_extension_semantics() {
        let unknown = raw_stream_header(32, 99, 88, 77, 66, 1, &[1, 2, 3]);
        let mut group = encode_stream(op::A_GAUSSIAN_ID, &[7], 1, codec::DEFLATE, 6, true).unwrap();
        group.extend_from_slice(&unknown);
        let (ids, bins) = decode_group(&group, 1).unwrap();
        assert_eq!(ids, [7]);
        assert!(bins.is_empty());

        let mut keyframe_streams =
            encode_stream(op::A_GAUSSIAN_ID, &[], 1, codec::DEFLATE, 6, true).unwrap();
        keyframe_streams.extend_from_slice(&raw_stream_header(32, 99, 88, 77, 66, 0, &[4, 5]));
        let record = rec::encode_chunk(0.0, 1.0, 0, 0, &keyframe_streams);
        decode_keyframe_chunk(record_content(&record), &[]).unwrap();
    }

    #[test]
    fn empty_defined_attributes_still_validate_their_fixed_header_semantics() {
        for (label, width, mode, stream_codec) in [
            ("symbol width", 3, crate::stream::MODE_RAW, codec::DEFLATE),
            ("stream mode", 1, 9, codec::DEFLATE),
            ("stream codec", 1, crate::stream::MODE_RAW, 9),
        ] {
            let stream = raw_stream_header(op::A_GAUSSIAN_ID, width, mode, stream_codec, 1, 0, &[]);
            let error = decode_state_stream(&mut Cursor::new(&stream), 0).unwrap_err();
            assert!(error.to_string().contains(label), "{label}: {error}");
        }
    }

    #[test]
    fn state_stream_delta_runs_cannot_leave_the_i32_domain() {
        let symbols = [
            crate::stream::zigzag(i64::from(i32::MAX)),
            crate::stream::zigzag(1),
        ];
        let mut raw = vec![0u8; symbols.len() * 4];
        for byte in 0..4 {
            for (i, symbol) in symbols.iter().enumerate() {
                raw[byte * symbols.len() + i] = (symbol >> (8 * byte)) as u8;
            }
        }
        let payload = codec::compress(&raw, codec::DEFLATE, 6).unwrap();
        let stream = raw_stream_header(
            op::A_OPACITY,
            4,
            crate::stream::MODE_DELTA,
            codec::DEFLATE,
            1,
            2,
            &payload,
        );
        let error = decode_state_stream(&mut Cursor::new(&stream), 2).unwrap_err();
        assert!(
            error.to_string().contains("outside the signed 32-bit"),
            "{error}"
        );
    }

    #[test]
    fn a_nonempty_birth_must_carry_the_full_state() {
        let births = encode_stream(op::A_GAUSSIAN_ID, &[7], 1, codec::DEFLATE, 6, true).unwrap();
        let record = rec::encode_delta_chunk(
            0.0,
            1.0,
            0,
            rec::DELTA_MODE_CHAINED,
            8,
            8,
            1,
            &[],
            &births,
            &[],
            (0, 1, 0),
        );
        let error = check_delta_chunk(record_content(&record), &[]).unwrap_err();
        assert!(
            error.to_string().contains("missing required attributes"),
            "{error}"
        );
    }

    #[test]
    fn a_death_group_may_carry_only_gaussian_id() {
        let mut deaths =
            encode_stream(op::A_GAUSSIAN_ID, &[7], 1, codec::DEFLATE, 6, true).unwrap();
        deaths.extend_from_slice(
            &encode_stream(op::A_OPACITY, &[1], 1, codec::DEFLATE, 6, true).unwrap(),
        );
        let record = rec::encode_delta_chunk(
            0.0,
            1.0,
            0,
            rec::DELTA_MODE_CHAINED,
            8,
            8,
            1,
            &[],
            &[],
            &deaths,
            (0, 0, 1),
        );
        let error = check_delta_chunk(record_content(&record), &[]).unwrap_err();
        assert!(
            error.to_string().contains("may carry only gaussian_id"),
            "{error}"
        );
    }

    #[test]
    fn a_keyframe_mu_t_bin_must_represent_its_chunk_t0() {
        let mut bins = BTreeMap::new();
        bins.insert(op::A_MU_T, BinArray::new(vec![0], 1));
        bins.insert(op::A_SIGMA_T, BinArray::new(vec![0], 1));
        bins.insert(op::A_FLAGS, BinArray::new(vec![0], 1));
        let state = State { ids: vec![9], bins };
        let quantization = rec::Quantization {
            step_time: 0.004,
            step_sigma_log: 0.04,
            ..Default::default()
        };
        let error = check_keyframe_mu_t(&state, 1.0, &quantization).unwrap_err();
        assert!(error.to_string().contains("Chunk t0 1"), "{error}");

        for step_time in [0.0, -0.004] {
            let quantization = rec::Quantization {
                step_time,
                step_sigma_log: 0.04,
                ..Default::default()
            };
            let error = check_keyframe_mu_t(&state, 0.0, &quantization).unwrap_err();
            assert!(
                error.to_string().contains("non-positive mu_t grid step"),
                "{error}"
            );
        }
    }

    struct Watched<'a> {
        inner: crate::BytesReadable<'a>,
        reads: Vec<(u64, u64)>,
    }

    impl<'a> Watched<'a> {
        fn new(data: &'a [u8]) -> Self {
            Self {
                inner: crate::BytesReadable::new(data),
                reads: Vec::new(),
            }
        }
    }

    impl Readable for Watched<'_> {
        fn size(&mut self) -> Result<u64> {
            self.inner.size()
        }

        fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
            self.reads.push((offset, length));
            self.inner.read(offset, length)
        }
    }

    fn empty_indexed_file() -> Vec<u8> {
        write_sequence(
            &[Sample {
                t0: 0.0,
                ids: Vec::new(),
                gaussians: GaussianSet::default(),
            }],
            1.0,
            &KeyframeDeltaOptions::default(),
        )
        .unwrap()
    }

    #[test]
    fn indexed_open_reads_the_fixed_tail_and_never_fetches_chunk_content() {
        let data = empty_indexed_file();
        let chunk = Records::new(&data, MAGIC.len())
            .filter_map(|record| record.ok())
            .find(|record| record.opcode == op::CHUNK)
            .unwrap();
        let content_start = chunk.offset as u64 + crate::serialization::RECORD_HEADER_SIZE as u64;
        let content_end = content_start + chunk.content.len() as u64;

        let mut source = Watched::new(&data);
        let sequence = open_indexed(&mut source).unwrap();
        assert_eq!(sequence.index.len(), 1);
        assert!(source.reads.iter().all(|(offset, length)| {
            let end = offset.saturating_add(*length);
            end <= content_start || *offset >= content_end
        }));
    }

    #[test]
    fn a_hostile_summary_start_never_sizes_one_summary_allocation() {
        let mut data = empty_indexed_file();
        let footer_at = data.len() - MAGIC.len() - crate::serialization::RECORD_HEADER_SIZE - 20;
        data[footer_at + crate::serialization::RECORD_HEADER_SIZE
            ..footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&(MAGIC.len() as u64).to_le_bytes());

        let mut source = Watched::new(&data);
        let _ = open_indexed(&mut source);
        assert!(
            source.reads.iter().all(|(_, length)| *length < 1024),
            "unexpected bulk read: {:?}",
            source.reads
        );
    }

    #[test]
    fn indexed_open_does_not_scan_records_after_the_first_state_record() {
        let mut data = empty_indexed_file();
        let old_footer_at =
            data.len() - MAGIC.len() - crate::serialization::RECORD_HEADER_SIZE - 20;
        let old_summary_start = u64::from_le_bytes(
            data[old_footer_at + crate::serialization::RECORD_HEADER_SIZE
                ..old_footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
                .try_into()
                .unwrap(),
        ) as usize;
        let late = rec::Header {
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
            temporal_model: "frame-sequence".into(),
            ..Default::default()
        }
        .encode(&[]);
        data.splice(old_summary_start..old_summary_start, late.iter().copied());

        let footer_at = old_footer_at + late.len();
        let shifted_summary = (old_summary_start + late.len()) as u64;
        data[footer_at + crate::serialization::RECORD_HEADER_SIZE
            ..footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&shifted_summary.to_le_bytes());

        let late_at = old_summary_start as u64;
        let mut source = Watched::new(&data);
        let sequence = open_indexed(&mut source).unwrap();
        assert_eq!(sequence.header.temporal_model, "keyframe-delta");
        assert!(
            !source
                .reads
                .iter()
                .any(|(offset, length)| *offset == late_at && *length == 9),
            "indexed open walked into the late Header: {:?}",
            source.reads
        );
    }

    #[test]
    fn indexed_open_skips_an_extensible_header_trailer() {
        let mut data = empty_indexed_file();
        let old_footer_at =
            data.len() - MAGIC.len() - crate::serialization::RECORD_HEADER_SIZE - 20;
        let old_summary_start = u64::from_le_bytes(
            data[old_footer_at + crate::serialization::RECORD_HEADER_SIZE
                ..old_footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
                .try_into()
                .unwrap(),
        ) as usize;
        let trailer = vec![0u8; 1024 * 1024];
        let late = rec::Header {
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
            temporal_model: "keyframe-delta".into(),
            ..Default::default()
        }
        .encode(&trailer);
        data.splice(old_summary_start..old_summary_start, late.iter().copied());

        let footer_at = old_footer_at + late.len();
        let shifted_summary = (old_summary_start + late.len()) as u64;
        data[footer_at + crate::serialization::RECORD_HEADER_SIZE
            ..footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&shifted_summary.to_le_bytes());

        let mut source = Watched::new(&data);
        open_indexed(&mut source).unwrap();
        assert!(
            source.reads.iter().all(|(_, length)| *length <= 8 * 1024),
            "the Header trailer was transferred: {:?}",
            source.reads
        );
    }

    #[test]
    fn streamed_and_indexed_reads_keep_the_pre_state_window_table() {
        let mut data = empty_indexed_file();
        let old_footer_at =
            data.len() - MAGIC.len() - crate::serialization::RECORD_HEADER_SIZE - 20;
        let old_summary_start = u64::from_le_bytes(
            data[old_footer_at + crate::serialization::RECORD_HEADER_SIZE
                ..old_footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
                .try_into()
                .unwrap(),
        ) as usize;
        let late = rec::WindowTable {
            windows: vec![(10.0, 20.0)],
        }
        .encode();
        data.splice(old_summary_start..old_summary_start, late.iter().copied());

        let footer_at = old_footer_at + late.len();
        let shifted_summary = (old_summary_start + late.len()) as u64;
        data[footer_at + crate::serialization::RECORD_HEADER_SIZE
            ..footer_at + crate::serialization::RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&shifted_summary.to_le_bytes());

        let streamed = decode_streamed(&data).unwrap();
        let indexed = open_indexed(&mut BytesReadable::new(&data)).unwrap();
        assert_eq!(streamed.windows, indexed.windows);
        assert_ne!(streamed.windows, vec![(10.0, 20.0)]);
    }

    #[test]
    fn quantization_length_is_bounded_before_the_range_is_read() {
        struct NoReads;
        impl Readable for NoReads {
            fn size(&mut self) -> Result<u64> {
                Ok(u64::MAX)
            }

            fn read(&mut self, _offset: u64, _length: u64) -> Result<Vec<u8>> {
                panic!("the oversized range must be rejected before Readable::read")
            }
        }

        let error = ranged_front_matter_content(
            &mut NoReads,
            0,
            crate::indexed_reader::MAX_FRONT_MATTER_BYTES + 1,
            "Quantization",
        )
        .unwrap_err();
        assert!(error.to_string().contains("Quantization"), "{error}");
        assert!(error.to_string().contains("ceiling"), "{error}");
    }
}
