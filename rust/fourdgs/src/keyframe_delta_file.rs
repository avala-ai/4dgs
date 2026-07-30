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

use std::collections::{BTreeMap, BTreeSet};

use crate::error::{Error, Result};
use crate::keyframe_delta::{
    apply_delta, chain_for, check_tiling, keyframe_state, BinArray, State, ABSOLUTE_IN_UPDATE,
    GOP_INVARIANT,
};
use crate::model::GaussianSet;
use crate::opcode as op;
use crate::quantization::{
    life_class, motion_step, mu_step, rct_forward, rint, support_k, Bounds, Profile, Steps,
};
use crate::records as rec;
use crate::serialization::{check_magic, crc32, Cursor, Records, MAGIC};
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
    pub window: (f64, f64),
    pub cutoff: f64,
}

impl Grids {
    fn motion_step_for(&self, sigma_bin: i64, never_fades: bool) -> f64 {
        let win_len = self.window.1 - self.window.0;
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
        window_index.push(0);

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

        let m_step = grids.motion_step_for(q_sigma, never_fades);
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
        window: (0.0, duration_sec),
        cutoff,
    }
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
    let grids = grids_for(samples, duration_sec, kd.profile, kd.cutoff);
    let quantized: Vec<(Vec<i64>, BTreeMap<u8, BinArray>)> = samples
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
            windows: vec![grids.window],
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
            let streams = keyframe_streams(ids, bins, kd.codec, kd.level)?;
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
            window: self.windows.first().copied().unwrap_or((0.0, 0.0)),
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

/// One length-framed sub-block: its ids, and a bin array per other attribute.
fn decode_group(bytes: &[u8]) -> Result<(Vec<i64>, BTreeMap<u8, BinArray>)> {
    if bytes.is_empty() {
        return Ok((Vec::new(), BTreeMap::new()));
    }
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut cursor = Cursor::new(bytes);
    while cursor.remaining() > 0 {
        let (attribute_id, values) = decode_stream(&mut cursor, None)?;
        got.insert(attribute_id, values);
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

fn keyframe_from_chunk(content: &[u8]) -> Result<(Vec<i64>, BTreeMap<u8, BinArray>)> {
    let (head, streams) = rec::parse_chunk(content)?;
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut cursor = Cursor::new(streams);
    while cursor.remaining() > 0 {
        let (attribute_id, values) = decode_stream(&mut cursor, None)?;
        got.insert(attribute_id, values);
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
    Ok((ids, bins))
}

fn compose_delta(reference: &State, content: &[u8]) -> Result<(State, rec::DeltaChunkHeader)> {
    let (head, updates, births, deaths) = rec::parse_delta_chunk(content)?;
    let (update_ids, update_bins) = decode_group(updates)?;
    let (birth_ids, birth_bins) = decode_group(births)?;
    let (death_ids, _) = decode_group(deaths)?;
    let state = apply_delta(
        reference,
        &update_ids,
        &update_bins,
        &birth_ids,
        &birth_bins,
        &death_ids,
    )?;
    Ok((state, head))
}

/// Front to back: decode each chunk and compose it onto the state it references.
pub fn decode_streamed(data: &[u8]) -> Result<DecodedSequence> {
    check_magic(data)?;
    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut chunks: Vec<ChunkInfo> = Vec::new();
    let mut by_offset: BTreeMap<u64, State> = BTreeMap::new();

    for record in Records::new(data, MAGIC.len()) {
        let record = record?;
        match record.opcode {
            op::HEADER => {
                let parsed = rec::Header::parse(record.content)?;
                if parsed.temporal_model != "keyframe-delta" {
                    return Err(Error::Malformed(format!(
                        "decode_streamed is the keyframe-delta path; this file is {:?}",
                        parsed.temporal_model
                    )));
                }
                header = Some(parsed);
            }
            op::QUANTIZATION => quant = Some(rec::Quantization::parse(record.content)?),
            op::WINDOW_TABLE => windows = rec::WindowTable::parse(record.content)?.windows,
            op::CHUNK => {
                let (ids, bins) = keyframe_from_chunk(record.content)?;
                let (head, _) = rec::parse_chunk(record.content)?;
                let state = keyframe_state(ids, bins)?;
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
                let (head, ..) = rec::parse_delta_chunk(record.content)?;
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
                let (state, head) = compose_delta(reference, record.content)?;
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

fn record_content(data: &[u8], offset: u64, length: u64) -> Result<&[u8]> {
    let start = offset as usize;
    let end = start
        .checked_add(length as usize)
        .filter(|e| *e <= data.len())
        .ok_or_else(|| Error::Truncated(format!("record at {offset} runs past the file")))?;
    let mut c = Cursor::new(&data[start..end]);
    c.u8()?;
    c.blob()
}

fn compose_chain(
    data: &[u8],
    index: &[rec::ChunkIndexEntry],
    entry: &rec::ChunkIndexEntry,
) -> Result<State> {
    let chain = chain_for(index, (entry.t0 + entry.t1) / 2.0)?;
    let mut state: Option<State> = None;
    for link in &chain {
        let content = record_content(data, link.chunk_offset, link.chunk_length)?;
        if link.kind == 0 {
            let (ids, bins) = keyframe_from_chunk(content)?;
            state = Some(keyframe_state(ids, bins)?);
        } else {
            let reference = state
                .take()
                .ok_or_else(|| Error::Malformed("a chain begins with a delta chunk".into()))?;
            state = Some(compose_delta(&reference, content)?.0);
        }
    }
    state.ok_or_else(|| Error::Malformed("an empty chain".into()))
}

/// Read the Footer, then the index, then compose each chunk by walking its chain.
pub fn decode_indexed(data: &[u8]) -> Result<(DecodedSequence, Vec<rec::ChunkIndexEntry>)> {
    check_magic(data)?;
    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut footer: Option<rec::Footer> = None;
    for record in Records::new(data, MAGIC.len()) {
        let record = record?;
        match record.opcode {
            op::HEADER => header = Some(rec::Header::parse(record.content)?),
            op::QUANTIZATION => quant = Some(rec::Quantization::parse(record.content)?),
            op::WINDOW_TABLE => windows = rec::WindowTable::parse(record.content)?.windows,
            op::FOOTER => {
                footer = Some(rec::Footer::parse(record.content)?);
                break;
            }
            _ => {}
        }
    }
    let Some(footer) = footer else {
        return Err(Error::Malformed("file has no Footer".into()));
    };
    let (Some(header), Some(quantization)) = (header, quant) else {
        return Err(Error::Malformed(
            "keyframe-delta file has no Header or Quantization record".into(),
        ));
    };

    let mut index: Vec<rec::ChunkIndexEntry> = Vec::new();
    for record in Records::new(data, footer.summary_start as usize) {
        let record = record?;
        if record.opcode == op::CHUNK_INDEX {
            index.push(rec::ChunkIndexEntry::parse(record.content)?);
        } else {
            break;
        }
    }
    check_tiling(&index)?;

    let mut chunks: Vec<ChunkInfo> = Vec::with_capacity(index.len());
    for entry in &index {
        let state = compose_chain(data, &index, entry)?;
        let (update_count, birth_count, death_count) = if entry.kind != 0 {
            let content = record_content(data, entry.chunk_offset, entry.chunk_length)?;
            let (head, ..) = rec::parse_delta_chunk(content)?;
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

    for &i in &order {
        out.ids.push(state.ids[i]);
        let sigma_bin = sigma.values[i];
        let never_fades = flags.values[i] != 0;
        let sigma_f = if never_fades {
            f64::INFINITY
        } else {
            (sigma_bin as f64 * grids.steps.sigma_log).exp()
        };
        let m_step = grids.motion_step_for(sigma_bin, never_fades);
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
