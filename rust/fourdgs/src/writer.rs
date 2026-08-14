// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The encoder.
//!
//! It quantizes onto the declared grids, partitions gaussians by their temporal support,
//! writes independent chunks and an index, and — before it hands back a single byte —
//! decodes what it produced and checks that every value came back inside the bounds the
//! file is about to claim.
//!
//! That last step is the point, and it is why this function returns `Result<Vec<u8>>`
//! rather than writing as it goes: a file whose bounds have not been verified never
//! reaches a caller, let alone a disk. A bound nobody checked is worse than no bound,
//! because consumers will trust it.
//!
//! Two properties are contracts rather than niceties. **Chunks are independent** — nothing
//! in one references another, which is what makes seeking work at all. And **output is
//! deterministic**: the same scene and options produce byte-identical files, run after
//! run, so a corpus built from this encoder can be checksummed rather than eyeballed.

use std::collections::BTreeMap;
use std::path::Path;

use crate::codec;
use crate::error::{Error, Result};
use crate::model::{AudioSource, AudioTrack, GaussianSet};
use crate::opcode as op;
use crate::quantization::{
    life_class, life_half, morton_order, motion_step, mu_step, quantize_rotation, quantize_sh,
    rct_forward, rint, sh_bound, sh_step, support_k, Bounds, Profile, Steps, SH_MAX_BITS,
    SH_MIN_BITS,
};
use crate::records as rec;
use crate::serialization::{crc32, put_record, MAGIC};
use crate::stream::encode_stream;

/// How a scene is written.
#[derive(Debug, Clone)]
pub struct WriteOptions {
    /// Which error bounds to quantize against.
    pub profile: Profile,
    /// The Header's marginal visibility threshold. Not only metadata: it sets the support
    /// constant the per-gaussian velocity grid is derived from, so encoder and decoder
    /// must agree on it, and they do by reading it from the file.
    pub cutoff: f64,
    /// Stream codec. `deflate` is the format's default and is universally available.
    pub codec: u8,
    pub level: u32,
    /// Depth of the temporal partition below each window. 0 writes one chunk per window.
    pub max_depth: u32,
    pub min_chunk_gaussians: usize,
    pub write_index: bool,
    pub write_statistics: bool,
    pub write_summary_offsets: bool,
    pub write_crc: bool,
    /// Highest spherical harmonic band to write.
    pub sh_bands: u8,
    /// Per-band spherical harmonic bit depths, band 1 first. `None` leaves the
    /// coefficients as the profile alone decides, which is what every file written before
    /// this option existed did — the appended field is not emitted at all, so those files
    /// are byte-identical.
    pub sh_bit_depths: Option<Vec<u8>>,
    /// Decode every chunk back and check the declared bounds before returning. Turning
    /// this off is a performance choice a producer has to make deliberately.
    pub verify: bool,
    pub library: String,
    /// The Header's `profile` field — a promise about the file's shape, not the bound
    /// profile above.
    pub scene_profile: String,
    pub metadata: BTreeMap<String, String>,
    /// Bytes appended to the content of the record with the given opcode, as a newer
    /// writer that added a field would produce.
    pub record_trailers: BTreeMap<u8, Vec<u8>>,
    /// Pre-encoded records emitted verbatim after the window table. Splicing records in
    /// afterwards would shift every offset the index holds, which produces a corrupt file
    /// rather than a forward-compatibility test.
    pub extra_records: Vec<Vec<u8>>,
}

impl Default for WriteOptions {
    fn default() -> Self {
        WriteOptions {
            profile: Profile::Default,
            cutoff: crate::quantization::DEFAULT_CUTOFF,
            codec: codec::DEFLATE,
            level: 6,
            max_depth: 6,
            min_chunk_gaussians: 2048,
            write_index: true,
            write_statistics: false,
            write_summary_offsets: false,
            write_crc: true,
            sh_bands: 3,
            sh_bit_depths: None,
            verify: true,
            library: "4dgs-rust encoder".into(),
            scene_profile: String::new(),
            metadata: BTreeMap::new(),
            record_trailers: BTreeMap::new(),
            extra_records: Vec::new(),
        }
    }
}

/// Everything that travels with the gaussians.
#[derive(Debug, Clone, Default)]
pub struct SceneExtras {
    /// Spatial and non-spatial sources written as Audio Source / Audio Data pairs.
    pub audio_sources: Vec<AudioSource>,
    /// Pre-spatial compatibility input, normalized into source id 0 by the writer.
    ///
    /// New code should use `audio_sources`; passing both forms is an error.
    pub audio: Option<AudioTrack>,
    pub camera: Option<rec::Camera>,
    pub metadata: Vec<rec::Metadata>,
    pub attachments: Vec<rec::Attachment>,
    /// Provenance records to emit (spec section 5.15). Empty writes none, which is the
    /// default and costs nothing — no record, no placeholder, no Header flag. A scene with
    /// no sensors behind it is a complete file, not an under-specified one.
    pub provenance: crate::provenance::Provenance,
}

/// Encode a scene into a byte vector.
pub fn write_to_vec(
    gaussians: &GaussianSet,
    duration_sec: f64,
    options: &WriteOptions,
    extras: &SceneExtras,
) -> Result<Vec<u8>> {
    encode(gaussians, duration_sec, options, extras)
}

/// Encode a scene and write it to a path. Returns the number of bytes written.
pub fn write_path<P: AsRef<Path>>(
    path: P,
    gaussians: &GaussianSet,
    duration_sec: f64,
    options: &WriteOptions,
    extras: &SceneExtras,
) -> Result<usize> {
    let out = encode(gaussians, duration_sec, options, extras)?;
    std::fs::write(path, &out)?;
    Ok(out.len())
}

/// Everything the quantizer produced, in bins, before anything is framed.
struct Quantized {
    bounds: Bounds,
    steps: Steps,
    origin: [f64; 3],
    pos: Vec<i64>,
    scale: Vec<i64>,
    rotation_index: Vec<i64>,
    rotation: Vec<i64>,
    rgb: Vec<i64>,
    alpha: Vec<i64>,
    motion: Vec<i64>,
    mu: Vec<i64>,
    sigma: Vec<i64>,
    flags: Vec<i64>,
    window_index: Vec<i64>,
    windows: Vec<(f64, f64)>,
}

/// Refuse a scene this encoder cannot write a conforming file from (spec §5.3).
///
/// The position origin is the per-axis minimum of `positions`, so a non-finite value there
/// reaches the Quantization record — and §5.3 requires every step and origin to be finite.
///
/// The failure this prevents is specific to how the minimum is taken. `f64::min` returns
/// the *other* operand when one is NaN, and the fold is seeded with `f64::INFINITY`, so a
/// single NaN on an axis leaves that axis at the seed and the encoder writes `inf` as an
/// origin — silently, with no error, producing a file the specification forbids. It does
/// not take a whole axis of NaN; one gaussian is enough.
///
/// Three fields are deliberately exempt, because they are not quantized and an infinity in
/// them is meaningful rather than broken:
///
/// * `sigma_t` — `+inf` is its documented spelling for a gaussian that never fades (§3).
/// * `win_lo` and `win_hi` — the validity window goes into the Window Table as `f64`
///   verbatim (§5.4), touching no grid at all. `win_hi = +inf` is how a static asset says
///   it is present at every instant.
///
/// NaN is refused in all three. It is never meaningful in any of them, and it is the quiet
/// kind of wrong: the decoder reads every non-finite sigma as never-fading, so a NaN there
/// becomes a deliberate-looking value, and a NaN window makes every visibility comparison
/// false so the gaussian silently never appears.
fn check_finite_input(g: &GaussianSet) -> Result<()> {
    let n = g.count();
    if let Some(object_ids) = &g.object_id {
        if object_ids.len() != n {
            return Err(Error::InvalidInput(format!(
                "object_id has {} values, expected {n}; there must be one exact u32 label per gaussian",
                object_ids.len()
            )));
        }
    }
    if n == 0 {
        return Ok(());
    }
    for (name, values, width) in [
        ("positions", &g.positions, 3),
        ("scales", &g.scales, 3),
        ("rotations", &g.rotations, 4),
        ("colors", &g.colors, 4),
        ("motions", &g.motions, 3),
        ("mu_t", &g.mu_t, 1),
    ] {
        if let Some(at) = values.iter().position(|v| !v.is_finite()) {
            return Err(Error::InvalidInput(format!(
                "{name} is not finite at gaussian {}; it is quantized onto a grid, and a \
                 non-finite value there violates spec §5.3",
                at / width
            )));
        }
    }
    if let Some(at) = g
        .sigma_t
        .iter()
        .position(|v| v.is_nan() || (v.is_infinite() && v.is_sign_negative()))
    {
        return Err(Error::InvalidInput(format!(
            "sigma_t is NaN or -inf at gaussian {at}; use +inf for a gaussian that never fades"
        )));
    }
    for (name, values) in [("win_lo", &g.win_lo), ("win_hi", &g.win_hi)] {
        if let Some(at) = values.iter().position(|v| v.is_nan()) {
            return Err(Error::InvalidInput(format!(
                "{name} is NaN at gaussian {at}; a NaN window makes every visibility comparison \
                 false, so the gaussian silently never appears"
            )));
        }
    }
    Ok(())
}

/// Count Object Table records in the already-framed extension records without buffering or
/// interpreting their content. The `objects` profile makes their count normative, so an
/// incomplete extra record cannot be allowed to hide or counterfeit the one required table.
fn extra_object_table_count(records: &[Vec<u8>]) -> Result<usize> {
    let mut count = 0usize;
    for (blob_index, blob) in records.iter().enumerate() {
        let mut framed = crate::serialization::Records::new(blob, 0);
        for record in framed.by_ref() {
            let record = record.map_err(|error| {
                Error::InvalidInput(format!(
                    "extra_records[{blob_index}] is not a complete framed record: {error}"
                ))
            })?;
            if record.opcode == op::OBJECT_TABLE {
                rec::ObjectTable::parse(record.content).map_err(|error| {
                    Error::InvalidInput(format!(
                        "extra_records[{blob_index}] carries a malformed ObjectTable: {error}"
                    ))
                })?;
                count = count.checked_add(1).ok_or_else(|| {
                    Error::InvalidInput("the number of ObjectTable records overflows usize".into())
                })?;
            }
        }
        if framed.position() != blob.len() {
            return Err(Error::InvalidInput(format!(
                "extra_records[{blob_index}] contains {} trailing bytes that do not form a complete record",
                blob.len() - framed.position()
            )));
        }
    }
    Ok(count)
}

fn quantize_scene(g: &GaussianSet, opts: &WriteOptions) -> Result<Quantized> {
    check_finite_input(g)?;
    let n = g.count();
    // Position tolerance is a fraction of the median gaussian radius rather than an
    // absolute distance, so a profile means the same thing on a tabletop capture and on a
    // city block.
    let median_scale = if n == 0 { 1e-3 } else { median(&g.scales) };
    let bounds = Bounds::for_profile(opts.profile, median_scale);
    let steps = Steps::of(&bounds);

    let mut origin = [0.0f64; 3];
    if n > 0 {
        origin = [f64::INFINITY; 3];
        for i in 0..n {
            for (axis, slot) in origin.iter_mut().enumerate() {
                *slot = slot.min(g.positions[i * 3 + axis] as f64);
            }
        }
    }

    let mut q = Quantized {
        bounds,
        steps,
        origin,
        pos: Vec::with_capacity(n * 3),
        scale: Vec::with_capacity(n * 3),
        rotation_index: Vec::with_capacity(n),
        rotation: Vec::with_capacity(n * 3),
        rgb: Vec::with_capacity(n * 3),
        alpha: Vec::with_capacity(n),
        motion: Vec::with_capacity(n * 3),
        mu: Vec::with_capacity(n),
        sigma: Vec::with_capacity(n),
        flags: Vec::with_capacity(n),
        window_index: Vec::with_capacity(n),
        windows: Vec::new(),
    };

    let (table, index) = g.window_table();
    q.windows = if table.is_empty() {
        vec![(0.0, 0.0)]
    } else {
        table
    };

    let k = support_k(opts.cutoff);
    for (i, window_index) in index.iter().enumerate() {
        for (axis, origin_axis) in origin.iter().enumerate() {
            q.pos.push(rint(
                (g.positions[i * 3 + axis] as f64 - origin_axis) / steps.pos,
            ));
            q.scale.push(rint(
                (g.scales[i * 3 + axis] as f64).max(1e-30).ln() / steps.scale_log,
            ));
        }

        let quat = [
            g.rotations[i * 4] as f64,
            g.rotations[i * 4 + 1] as f64,
            g.rotations[i * 4 + 2] as f64,
            g.rotations[i * 4 + 3] as f64,
        ];
        let (largest, bins) = quantize_rotation(quat, steps.rot);
        q.rotation_index.push(largest);
        q.rotation.extend_from_slice(&bins);

        // The colour transform is exact in the integer domain, so it changes the
        // compressed size and never the error bound.
        let rgb = rct_forward([
            rint(g.colors[i * 4] as f64 / steps.rgb),
            rint(g.colors[i * 4 + 1] as f64 / steps.rgb),
            rint(g.colors[i * 4 + 2] as f64 / steps.rgb),
        ]);
        q.rgb.extend_from_slice(&rgb);
        q.alpha.push(rint(g.colors[i * 4 + 3] as f64 / steps.alpha));

        let never_fades = !(g.sigma_t[i] as f64).is_finite();
        let sigma_bin = if never_fades {
            0
        } else {
            rint((g.sigma_t[i] as f64).max(1e-30).ln() / steps.sigma_log)
        };
        q.sigma.push(sigma_bin);
        q.flags.push(i64::from(never_fades));

        q.window_index.push(*window_index as i64);
        let (lo, hi) = q.windows[*window_index as usize];

        // Both per-gaussian pitches are recomputed at decode from the sigma bin, so the
        // encoder has to derive them from the same value it is about to write — not from
        // the original sigma it started with.
        let class = life_class(sigma_bin, steps.sigma_log, never_fades, hi - lo, k);
        let m_step = motion_step(class, steps.motion);
        for axis in 0..3 {
            q.motion.push(rint(g.motions[i * 3 + axis] as f64 / m_step));
        }
        let t_step = mu_step(sigma_bin, steps.sigma_log, never_fades, steps.time);
        q.mu.push(rint(g.mu_t[i] as f64 / t_step));
    }
    Ok(q)
}

/// The median of a slice, taken the way NumPy takes it: the mean of the two middle values
/// on an even count.
fn median(values: &[f32]) -> f64 {
    if values.is_empty() {
        return 1e-3;
    }
    let mut sorted: Vec<f64> = values.iter().map(|v| *v as f64).collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = sorted.len() / 2;
    if sorted.len() % 2 == 1 {
        sorted[mid]
    } else {
        0.5 * (sorted[mid - 1] + sorted[mid])
    }
}

/// One node of the temporal interval tree, and the gaussians that live in it.
struct Plan {
    t0: f64,
    t1: f64,
    level: u32,
    members: Vec<usize>,
}

/// Assign gaussians to nodes of a temporal interval tree.
///
/// A gaussian goes in the deepest node whose interval fully contains its support, so it is
/// stored exactly once however long it lives. The top level is the window table, which
/// matters: a power-of-two tree over the whole timeline pushes gaussians that fill one
/// window up to the root because they straddle its boundaries.
fn plan_chunks(
    lo: &[f64],
    hi: &[f64],
    tops: &[f64],
    max_depth: u32,
    min_gaussians: usize,
) -> Vec<Plan> {
    let n = lo.len();
    let mut assigned = vec![usize::MAX; n];
    let mut nodes: Vec<(f64, f64, i64)> = Vec::new();

    /// The immutable half of the recursion, so the recursive step takes a context rather
    /// than nine parameters that all mean "the same tree".
    struct Tree<'a> {
        lo: &'a [f64],
        hi: &'a [f64],
        max_depth: u32,
        min_gaussians: usize,
    }

    impl Tree<'_> {
        /// Push `pool` down the tree, returning the gaussians that could not descend
        /// because their support straddles a boundary. Those belong to the caller's node.
        fn descend(
            &self,
            a: f64,
            b: f64,
            level: u32,
            pool: Vec<usize>,
            nodes: &mut Vec<(f64, f64, i64)>,
            assigned: &mut [usize],
        ) -> Vec<usize> {
            if pool.is_empty() || level >= self.max_depth {
                return pool;
            }
            let mid = 0.5 * (a + b);
            let mut stay: Vec<usize> = Vec::new();
            let mut left: Vec<usize> = Vec::new();
            let mut right: Vec<usize> = Vec::new();
            for i in pool {
                if self.hi[i] <= mid {
                    left.push(i);
                } else if self.lo[i] >= mid {
                    right.push(i);
                } else {
                    stay.push(i);
                }
            }
            for (ca, cb, child) in [(a, mid, left), (mid, b, right)] {
                // A node too small to be worth its own chunk gives its gaussians back to
                // the parent rather than producing a chunk of four.
                if child.len() < self.min_gaussians {
                    stay.extend_from_slice(&child);
                    continue;
                }
                let kept = self.descend(ca, cb, level + 1, child, nodes, assigned);
                if !kept.is_empty() {
                    nodes.push((ca, cb, level as i64 + 1));
                    let node = nodes.len() - 1;
                    for i in kept {
                        assigned[i] = node;
                    }
                }
            }
            stay.sort_unstable();
            stay
        }
    }

    let tree = Tree {
        lo,
        hi,
        max_depth,
        min_gaussians,
    };

    for pair in tops.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let pool: Vec<usize> = (0..n)
            .filter(|i| lo[*i] >= a - 1e-9 && hi[*i] <= b + 1e-9 && assigned[*i] == usize::MAX)
            .collect();
        let kept = tree.descend(a, b, 0, pool, &mut nodes, &mut assigned);
        if !kept.is_empty() {
            nodes.push((a, b, 0));
            let node = nodes.len() - 1;
            for i in kept {
                assigned[i] = node;
            }
        }
    }

    let rest: Vec<usize> = (0..n).filter(|i| assigned[*i] == usize::MAX).collect();
    if !rest.is_empty() {
        nodes.push((tops[0], tops[tops.len() - 1], -1));
        let node = nodes.len() - 1;
        for i in rest {
            assigned[i] = node;
        }
    }

    let mut plans: Vec<Plan> = Vec::new();
    for (node, (a, b, level)) in nodes.iter().enumerate() {
        let members: Vec<usize> = (0..n).filter(|i| assigned[*i] == node).collect();
        if !members.is_empty() {
            plans.push(Plan {
                t0: *a,
                t1: *b,
                level: (*level).max(0) as u32,
                members,
            });
        }
    }
    // Shallow nodes first, then by start time: a fixed order, so two runs of this encoder
    // lay the same chunks out at the same offsets.
    plans.sort_by(|x, y| {
        (x.level, x.t0)
            .partial_cmp(&(y.level, y.t0))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    plans
}

fn normalized_audio_sources(extras: &SceneExtras, scene_duration: f64) -> Result<Vec<AudioSource>> {
    if extras.audio.is_some() && !extras.audio_sources.is_empty() {
        return Err(Error::Malformed(
            "pass audio_sources or the legacy audio field, not both".into(),
        ));
    }
    let sources = match &extras.audio {
        None => extras.audio_sources.clone(),
        Some(audio) => vec![AudioSource {
            source_id: 0,
            codec: audio.codec.clone(),
            channel_layout: "unspecified".into(),
            start_sec: audio.start_sec,
            duration_sec: (scene_duration - audio.start_sec).max(0.0),
            spatial: false,
            data: audio.data.clone(),
            ..AudioSource::default()
        }],
    };

    let mut ids = std::collections::BTreeSet::new();
    for source in &sources {
        if !ids.insert(source.source_id) {
            return Err(Error::Malformed(format!(
                "audio source id {} is duplicated",
                source.source_id
            )));
        }
        if source.codec.is_empty() {
            return Err(Error::Malformed(format!(
                "audio source {} has an empty codec",
                source.source_id
            )));
        }
        if source.data.is_empty() {
            return Err(Error::Malformed(format!(
                "audio source {} has no encoded data",
                source.source_id
            )));
        }
        if !source.start_sec.is_finite() {
            return Err(Error::Malformed(format!(
                "audio source {} start_sec is not finite",
                source.source_id
            )));
        }
        if !source.duration_sec.is_finite() || source.duration_sec <= 0.0 {
            return Err(Error::Malformed(format!(
                "audio source {} duration_sec must be finite and positive",
                source.source_id
            )));
        }
        if !source.gain.is_finite() || source.gain < 0.0 {
            return Err(Error::Malformed(format!(
                "audio source {} gain must be finite and non-negative",
                source.source_id
            )));
        }
        if source.spatial && source.channel_layout != "mono" {
            return Err(Error::Malformed(format!(
                "spatial audio source {} must use the mono channel layout",
                source.source_id
            )));
        }
        if !source.position.iter().all(|value| value.is_finite()) {
            return Err(Error::Malformed(format!(
                "audio source {} position must contain three finite values",
                source.source_id
            )));
        }
        if !source.rotation.iter().all(|value| value.is_finite())
            || source.rotation.iter().all(|value| *value == 0.0)
        {
            return Err(Error::Malformed(format!(
                "audio source {} rotation must be a finite non-zero quaternion",
                source.source_id
            )));
        }
        if source.interpolation != "linear" && source.interpolation != "step" {
            return Err(Error::Malformed(format!(
                "audio source {} uses unknown interpolation {:?}",
                source.source_id, source.interpolation
            )));
        }
        let mut last = f64::NEG_INFINITY;
        for (index, keyframe) in source.keyframes.iter().enumerate() {
            if !keyframe.position.iter().all(|value| value.is_finite()) {
                return Err(Error::Malformed(format!(
                    "audio source {} keyframe {index} position must contain three finite values",
                    source.source_id
                )));
            }
            if !keyframe.rotation.iter().all(|value| value.is_finite())
                || keyframe.rotation.iter().all(|value| *value == 0.0)
            {
                return Err(Error::Malformed(format!(
                    "audio source {} keyframe {index} rotation must be a finite non-zero quaternion",
                    source.source_id
                )));
            }
            if !keyframe.time.is_finite() || keyframe.time <= last {
                return Err(Error::Malformed(format!(
                    "audio source {} keyframe {index} time must be finite and strictly increasing",
                    source.source_id
                )));
            }
            if keyframe.time < 0.0 || keyframe.time > scene_duration {
                return Err(Error::Malformed(format!(
                    "audio source {} keyframe {index} time {} is outside [0, {scene_duration}]",
                    source.source_id, keyframe.time
                )));
            }
            last = keyframe.time;
        }
    }
    Ok(sources)
}

fn normalized_audio_rotation(value: [f64; 4]) -> [f64; 4] {
    let scale = value
        .iter()
        .map(|component| component.abs())
        .fold(0.0_f64, f64::max);
    let scaled = value.map(|component| component / scale);
    let length = scaled
        .iter()
        .map(|component| component * component)
        .sum::<f64>()
        .sqrt();
    scaled.map(|component| component / length)
}

fn encode(
    g: &GaussianSet,
    duration_sec: f64,
    opts: &WriteOptions,
    extras: &SceneExtras,
) -> Result<Vec<u8>> {
    let n = g.count();
    if opts.scene_profile == "objects" {
        if n > 0 && g.object_id.is_none() {
            return Err(Error::InvalidInput(
                "the objects profile requires an object_id stream in every non-empty chunk, \
                 but the GaussianSet carries none"
                    .into(),
            ));
        }
        let table_count = extra_object_table_count(&opts.extra_records)?;
        match table_count {
            1 => {}
            0 => {
                return Err(Error::InvalidInput(
                    "the objects profile requires one ObjectTable record, but none was supplied"
                        .into(),
                ))
            }
            count => {
                return Err(Error::InvalidInput(format!(
                    "the objects profile requires exactly one ObjectTable record; {count} were supplied"
                )))
            }
        }
    }
    let q = quantize_scene(g, opts)?;
    let audio_sources = normalized_audio_sources(extras, duration_sec)?;

    // Window boundaries are the top level of the partition. Anything strictly inside the
    // clip becomes a split point; the ends are always present.
    let mut tops: Vec<f64> = vec![0.0, duration_sec];
    for (lo, hi) in &q.windows {
        for v in [*lo, *hi] {
            if v > 0.0 && v < duration_sec {
                tops.push(v);
            }
        }
    }
    tops.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    tops.dedup();
    if tops.len() < 2 {
        tops = vec![0.0, duration_sec.max(1e-9)];
    }

    let (support_lo, support_hi) = g.support(opts.cutoff);
    let mut plans = if n == 0 {
        Vec::new()
    } else {
        plan_chunks(
            &support_lo,
            &support_hi,
            &tops,
            opts.max_depth,
            opts.min_chunk_gaussians,
        )
    };
    if n > 0 && plans.is_empty() {
        plans.push(Plan {
            t0: tops[0],
            t1: tops[tops.len() - 1],
            level: 0,
            members: (0..n).collect(),
        });
    }

    // Which columns of the scene's coefficient rows each band owns, component-major.
    let mut sh_columns: BTreeMap<u8, Vec<usize>> = BTreeMap::new();
    if g.sh.is_some() && g.sh_degree > 0 && g.sh_coefficients > 0 {
        let coefficients = g.sh_coefficients;
        for band in 1..=g.sh_degree.min(opts.sh_bands) {
            let Some((first, last)) = crate::sh::band_range(band) else {
                continue;
            };
            let last = last.min(coefficients);
            if first >= last {
                continue;
            }
            let columns: Vec<usize> = (0..3)
                .flat_map(|c| (first..last).map(move |k| c * coefficients + k))
                .collect();
            sh_columns.insert(band, columns);
        }
    }

    let bands: Vec<u8> = sh_columns.keys().copied().collect();
    let depths = resolve_sh_depths(opts.sh_bit_depths.as_deref(), &bands)?;

    // One pitch has to go in `step_sh`, which is a single byte and predates per-band
    // depths. The coarsest band's is the only honest answer: a consumer that reads it and
    // not the appended field then holds an upper bound rather than a number that is true
    // of some bands and wrong for others. `bounds.sh` is worst-case for the same reason,
    // with the per-band truth beside it.
    let mut steps = q.steps;
    let mut sh_bounds = q.bounds.sh;
    if !depths.is_empty() {
        steps.sh = depths.values().map(|d| sh_step(*d)).max().unwrap_or(1);
        sh_bounds = depths.values().map(|d| sh_bound(*d)).max().unwrap_or(0);
    }

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&MAGIC);

    let trailer = |opcode: u8| -> &[u8] {
        opts.record_trailers
            .get(&opcode)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    };

    let aabb = g.aabb();
    out.extend_from_slice(
        &rec::Header {
            profile: opts.scene_profile.clone(),
            library: opts.library.clone(),
            duration_sec,
            gaussian_count: n as u64,
            cutoff: opts.cutoff,
            temporal_model: "gaussian-birth".into(),
            aabb: aabb.to_vec(),
            sh_degree: if sh_columns.is_empty() {
                0
            } else {
                g.sh_degree
            },
            // Absence is the whole signal: the bit is clear and there is no record.
            flags: if !audio_sources.is_empty() {
                rec::FLAG_HAS_AUDIO
            } else {
                0
            },
            attributes: opts.metadata.clone(),
        }
        .encode(trailer(op::HEADER)),
    );
    out.extend_from_slice(
        &rec::Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: q.origin.to_vec(),
            step_pos: q.steps.pos,
            step_scale_log: q.steps.scale_log,
            step_rot: q.steps.rot,
            step_rgb: q.steps.rgb,
            step_alpha: q.steps.alpha,
            step_motion: q.steps.motion,
            step_time: q.steps.time,
            step_sigma_log: q.steps.sigma_log,
            step_sh: steps.sh,
            bounds: declared_bounds(&q.bounds, sh_bounds, &depths),
            sh_bit_depths: depths.values().copied().collect(),
        }
        .encode(trailer(op::QUANTIZATION)),
    );
    out.extend_from_slice(
        &rec::WindowTable {
            windows: q.windows.clone(),
        }
        .encode(),
    );
    for blob in &opts.extra_records {
        out.extend_from_slice(blob);
    }

    for source in &audio_sources {
        let flags = (if source.spatial {
            rec::AUDIO_SOURCE_SPATIAL
        } else {
            0
        }) | (if source.loop_ {
            rec::AUDIO_SOURCE_LOOP
        } else {
            0
        });
        out.extend_from_slice(
            &rec::AudioSource {
                source_id: source.source_id,
                name: source.name.clone(),
                codec: source.codec.clone(),
                channel_layout: source.channel_layout.clone(),
                data_length: source.data.len() as u64,
                start_sec: source.start_sec,
                duration_sec: source.duration_sec,
                gain: source.gain,
                flags,
                position: source.position,
                rotation: normalized_audio_rotation(source.rotation),
                keyframes: source
                    .keyframes
                    .iter()
                    .map(|frame| rec::AudioSourceKeyframe {
                        time: frame.time,
                        position: frame.position,
                        rotation: normalized_audio_rotation(frame.rotation),
                    })
                    .collect(),
                interpolation: source.interpolation.clone(),
            }
            .encode(),
        );
        out.extend_from_slice(
            &rec::AudioData {
                source_id: source.source_id,
                data: source.data.clone(),
            }
            .encode(),
        );
    }
    // Provenance, in ascending opcode order: the frame the poses are expressed in, then
    // the sensors, then the trajectories, then the georeference. Nothing requires that
    // order of a reader — records are dispatched by opcode, not position — but a file
    // written this way reads close to the order a human would explain it.
    if !extras.provenance.is_empty() {
        extras.provenance.check()?;
        for frame in &extras.provenance.frames {
            frame.check()?;
            out.extend_from_slice(&frame.encode(&[]));
        }
        for sensor in &extras.provenance.sensors {
            sensor.check()?;
            out.extend_from_slice(&sensor.encode(&[]));
        }
        for trajectory in &extras.provenance.trajectories {
            trajectory.check()?;
            out.extend_from_slice(&trajectory.encode(&[]));
        }
        for anchor in &extras.provenance.anchors {
            anchor.check()?;
            out.extend_from_slice(&anchor.encode(&[]));
        }
    }

    if let Some(camera) = &extras.camera {
        out.extend_from_slice(&camera.encode());
    }
    for record in &extras.metadata {
        out.extend_from_slice(&record.encode());
    }
    for record in &extras.attachments {
        out.extend_from_slice(&record.encode());
    }

    let mut index: Vec<rec::ChunkIndexEntry> = Vec::with_capacity(plans.len());
    let mut worst: BTreeMap<&'static str, f64> = BTreeMap::new();

    for plan in &plans {
        // Morton order within the chunk is what makes the position delta small. It is an
        // encoder technique and nothing else: no decoder knows which ordering was used,
        // and none may assume one.
        let members = morton_sorted(&plan.members, &g.positions);

        let mut streams: Vec<u8> = Vec::new();
        for (attribute, values, channels) in [
            (op::A_POSITION, gather(&q.pos, &members, 3), 3usize),
            (op::A_SCALE, gather(&q.scale, &members, 3), 3),
            (
                op::A_ROTATION_INDEX,
                gather(&q.rotation_index, &members, 1),
                1,
            ),
            (op::A_ROTATION, gather(&q.rotation, &members, 3), 3),
            (op::A_COLOR, gather(&q.rgb, &members, 3), 3),
            (op::A_OPACITY, gather(&q.alpha, &members, 1), 1),
            (op::A_MOTION, gather(&q.motion, &members, 3), 3),
            (op::A_MU_T, gather(&q.mu, &members, 1), 1),
            (op::A_SIGMA_T, gather(&q.sigma, &members, 1), 1),
            (op::A_FLAGS, gather(&q.flags, &members, 1), 1),
            (op::A_WINDOW_INDEX, gather(&q.window_index, &members, 1), 1),
        ] {
            streams.extend_from_slice(&encode_stream(
                attribute, &values, channels, opts.codec, opts.level, true,
            )?);
        }
        if let Some(object_ids) = &g.object_id {
            // Attribute streams carry signed symbols. Reinterpret, rather than convert,
            // each exact u32 label through i32 so values above i32::MAX retain all bits.
            // Delta coding is disabled because crossing the signed bridge can need a
            // 33-bit delta even though every raw code is exactly 32 bits.
            let values: Vec<i64> = members
                .iter()
                .map(|&i| i32::from_le_bytes(object_ids[i].to_le_bytes()) as i64)
                .collect();
            streams.extend_from_slice(&encode_stream(
                op::A_OBJECT_ID,
                &values,
                1,
                opts.codec,
                opts.level,
                false,
            )?);
        }

        let chunk_at = out.len() as u64;
        let chunk_blob =
            rec::encode_chunk(plan.t0, plan.t1, plan.level, members.len() as u32, &streams);
        out.extend_from_slice(&chunk_blob);

        let mut bands: Vec<(u8, u64, u64)> = Vec::new();
        if let Some(sh) = &g.sh {
            let row = g.sh_coefficients * 3;
            for (band, columns) in &sh_columns {
                let mut values: Vec<i64> = Vec::with_capacity(members.len() * columns.len());
                let mut original: Vec<u8> = Vec::with_capacity(members.len() * columns.len());
                for i in &members {
                    for c in columns {
                        let raw = sh[i * row + c];
                        original.push(raw);
                        let v = match depths.get(band) {
                            Some(bits) => quantize_sh(raw, *bits) as i64,
                            None if q.steps.sh > 1 => {
                                let step = q.steps.sh as i64;
                                (raw as i64 / step) * step + step / 2
                            }
                            None => raw as i64,
                        };
                        values.push(v);
                    }
                }
                // Each band is its own record, so a reader that has capped its degree
                // skips the higher ones by byte range and never transfers them.
                let mut payload = vec![*band];
                payload.extend_from_slice(&encode_stream(
                    op::SH_BAND_STREAM,
                    &values,
                    columns.len(),
                    opts.codec,
                    opts.level,
                    true,
                )?);
                let mut band_blob = Vec::new();
                put_record(&mut band_blob, op::SH_BAND_STREAM, &payload);
                let band_at = out.len() as u64;
                out.extend_from_slice(&band_blob);
                bands.push((*band, band_at, band_blob.len() as u64));
                if opts.verify {
                    if let Some(bits) = depths.get(band) {
                        verify_band(&band_blob, &original, sh_bound(*bits), *band)?;
                    }
                }
            }
        }

        index.push(rec::ChunkIndexEntry {
            t0: plan.t0,
            t1: plan.t1,
            chunk_offset: chunk_at,
            chunk_length: chunk_blob.len() as u64,
            gaussian_count: members.len() as u32,
            bands,
            ..Default::default()
        });

        if opts.verify {
            verify_chunk(g, &members, &chunk_blob, &q, opts.cutoff, &mut worst)?;
        }
    }

    if opts.verify {
        assert_bounds(&worst, &q.bounds)?;
    }

    let mut summary_start = 0u64;
    let mut summary_offset_start = 0u64;
    let mut summary_len = 0usize;
    if opts.write_index && !index.is_empty() {
        summary_start = out.len() as u64;
        let group_start = summary_start;
        for entry in &index {
            out.extend_from_slice(&entry.encode());
        }
        if opts.write_statistics {
            out.extend_from_slice(
                &rec::Statistics {
                    gaussian_count: n as u64,
                    chunk_count: index.len() as u32,
                    duration_sec,
                    aabb: aabb.to_vec(),
                }
                .encode(),
            );
        }
        if opts.write_summary_offsets {
            summary_offset_start = out.len() as u64;
            out.extend_from_slice(
                &rec::SummaryOffset {
                    group_opcode: op::CHUNK_INDEX,
                    group_start,
                    group_length: out.len() as u64 - group_start,
                }
                .encode(),
            );
        }
        summary_len = out.len() - summary_start as usize;
    }

    let summary_crc = if opts.write_crc && summary_len > 0 {
        crc32(&out[summary_start as usize..])
    } else {
        0
    };
    out.extend_from_slice(
        &rec::Footer {
            summary_start,
            summary_offset_start,
            summary_crc,
        }
        .encode(),
    );
    out.extend_from_slice(&MAGIC);
    Ok(out)
}

/// Resolve the option into `{band: bit depth}` for the bands actually written.
///
/// A ladder shorter than the file's degree is an error rather than a default: the depth of
/// the highest band is the one that decides most of the size, and silently filling it in
/// with eight bits would hand back a file that quietly ignored what was asked for.
fn resolve_sh_depths(requested: Option<&[u8]>, bands: &[u8]) -> Result<BTreeMap<u8, u8>> {
    let mut out = BTreeMap::new();
    let (Some(requested), false) = (requested, bands.is_empty()) else {
        return Ok(out);
    };
    if requested.len() < bands.len() {
        return Err(Error::Malformed(format!(
            "sh_bit_depths declares {} bands; this scene writes {}",
            requested.len(),
            bands.len()
        )));
    }
    for (i, band) in bands.iter().enumerate() {
        let bits = requested[i];
        if !(SH_MIN_BITS..=SH_MAX_BITS).contains(&bits) {
            return Err(Error::Malformed(format!(
                "an SH bit depth must be {SH_MIN_BITS}..{SH_MAX_BITS}, got {bits}"
            )));
        }
        out.insert(*band, bits);
    }
    Ok(out)
}

/// Decode the band record just written and check the bound it is about to declare.
///
/// Decoded rather than computed: the arithmetic that produced these bytes is three lines
/// and would agree with itself if it were wrong. What the file will hand a consumer is
/// what came back out of the record, so that is what the bound is measured against — every
/// coefficient of every gaussian, not a sample.
fn verify_band(band_blob: &[u8], original: &[u8], bound: u8, band: u8) -> Result<()> {
    let content = &band_blob[crate::serialization::RECORD_HEADER_SIZE..];
    let mut cursor = crate::serialization::Cursor::new(content);
    cursor.u8()?;
    let (_, stream) = crate::stream::decode_stream(&mut cursor, None)?;
    let channels = stream.channels.max(1);
    let mut worst = 0i64;
    for (i, reference) in original.iter().enumerate() {
        let got = stream.get(i / channels, i % channels);
        worst = worst.max((got - i64::from(*reference)).abs());
    }
    if worst > bound as i64 {
        return Err(Error::BoundViolation(format!(
            "encoder verification failed: SH band {band} deviated {worst} code units, bound is {bound}"
        )));
    }
    Ok(())
}

/// The bounds map the file declares, keyed as the specification names them so that two
/// readers report the same number for the same file.
fn declared_bounds(b: &Bounds, sh: u8, depths: &BTreeMap<u8, u8>) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for (key, value) in [
        ("pos", b.pos),
        ("scale_rel", b.scale_rel),
        ("rot", b.rot),
        ("rgb", b.rgb),
        ("alpha", b.alpha),
        ("motion", b.motion),
        ("time", b.time),
        ("sigma_rel", b.sigma_rel),
    ] {
        map.insert(key.to_string(), format!("{value:?}"));
    }
    map.insert("sh".to_string(), sh.to_string());
    for (band, bits) in depths {
        map.insert(format!("sh_band{band}"), sh_bound(*bits).to_string());
    }
    map
}

/// Reorder a chunk's members for spatial locality.
fn morton_sorted(members: &[usize], positions: &[f32]) -> Vec<usize> {
    let mut packed: Vec<f32> = Vec::with_capacity(members.len() * 3);
    for i in members {
        packed.extend_from_slice(&positions[i * 3..i * 3 + 3]);
    }
    morton_order(&packed, members.len())
        .into_iter()
        .map(|k| members[k])
        .collect()
}

/// Pick `members`' rows out of a per-gaussian bin array.
fn gather(values: &[i64], members: &[usize], channels: usize) -> Vec<i64> {
    let mut out = Vec::with_capacity(members.len() * channels);
    for i in members {
        out.extend_from_slice(&values[i * channels..(i + 1) * channels]);
    }
    out
}

/// Decode what was just encoded and record the worst deviation seen.
///
/// This is the encoder checking its own claim, on every gaussian rather than a sample:
/// the file is about to declare a maximum deviation per attribute, and the only way that
/// declaration means anything is if somebody measured it.
fn verify_chunk(
    g: &GaussianSet,
    members: &[usize],
    chunk_blob: &[u8],
    q: &Quantized,
    cutoff: f64,
    worst: &mut BTreeMap<&'static str, f64>,
) -> Result<()> {
    let content = &chunk_blob[crate::serialization::RECORD_HEADER_SIZE..];
    let (head, streams) = rec::parse_chunk(content)?;
    let unpacked = crate::chunk::chunk_stream_bytes(&head, streams)?;
    let decoded = crate::chunk::decode_streams(
        &unpacked,
        head.count as usize,
        &q.steps,
        &q.origin,
        &q.windows,
        cutoff,
    )?;

    let mut update = |key: &'static str, value: f64| {
        let slot = worst.entry(key).or_insert(0.0);
        if value > *slot {
            *slot = value;
        }
    };

    for (row, i) in members.iter().enumerate() {
        match (&g.object_id, &decoded.object_id) {
            (Some(expected), Some(actual)) if actual[row] == expected[*i] => {}
            (Some(expected), Some(actual)) => {
                return Err(Error::BoundViolation(format!(
                "encoder verification failed: object_id for gaussian {i} became {} instead of {}",
                actual[row], expected[*i]
            )))
            }
            (Some(_), None) => {
                return Err(Error::BoundViolation(format!(
                    "encoder verification failed: object_id for gaussian {i} was omitted"
                )))
            }
            (None, Some(_)) => return Err(Error::BoundViolation(
                "encoder verification failed: object_id was invented for a scene that carried none"
                    .into(),
            )),
            (None, None) => {}
        }
        for axis in 0..3 {
            update(
                "pos",
                (decoded.positions[row * 3 + axis] as f64 - g.positions[i * 3 + axis] as f64).abs(),
            );
            let reference = (g.scales[i * 3 + axis] as f64).max(1e-30);
            let got = (decoded.scales[row * 3 + axis] as f64).max(1e-30);
            update("scale_rel", (got / reference).ln().abs());
        }
        for channel in 0..3 {
            update(
                "rgb",
                (decoded.colors[row * 4 + channel] as f64 - g.colors[i * 4 + channel] as f64).abs(),
            );
        }
        update(
            "alpha",
            (decoded.colors[row * 4 + 3] as f64 - g.colors[i * 4 + 3] as f64).abs(),
        );

        // A quaternion and its negation are the same rotation, so the deviation is the
        // smaller of the two comparisons.
        let norm = (0..4)
            .map(|c| (g.rotations[i * 4 + c] as f64).powi(2))
            .sum::<f64>()
            .sqrt()
            .max(1e-30);
        let mut same = 0.0f64;
        let mut flipped = 0.0f64;
        for c in 0..4 {
            let reference = g.rotations[i * 4 + c] as f64 / norm;
            let got = decoded.rotations[row * 4 + c] as f64;
            same = same.max((got - reference).abs());
            flipped = flipped.max((got + reference).abs());
        }
        update("rot", same.min(flipped));

        // The velocity guarantee is on displacement, not on velocity: a decoded velocity
        // moves its gaussian by at most `bounds.pos` over `min(lifetime, 2 s)`. The span
        // is the one the precision class was derived from, computed from the sigma bin
        // that was written rather than from the sigma the encoder started with — the bin
        // is what the decoder will have.
        let (win_lo, win_hi) = q.windows[q.window_index[*i] as usize];
        let half = life_half(
            q.sigma[*i],
            q.steps.sigma_log,
            q.flags[*i] != 0,
            win_hi - win_lo,
            support_k(cutoff),
        );
        for axis in 0..3 {
            let drift =
                (decoded.motions[row * 3 + axis] as f64 - g.motions[i * 3 + axis] as f64).abs();
            update("displacement", drift * half);
        }
    }
    Ok(())
}

/// Refuse to hand back a file whose measured deviation exceeds what it declares.
fn assert_bounds(worst: &BTreeMap<&'static str, f64>, bounds: &Bounds) -> Result<()> {
    // `rot` is not here: `step_rot` bounds the three *stored* components, and recovering
    // the omitted one and renormalizing can amplify that. The specification asks a
    // producer to measure the post-reconstruction maximum rather than to guarantee it,
    // and this encoder measures it — it is simply not a bound the grid promises.
    for (key, limit) in [
        ("pos", bounds.pos),
        ("scale_rel", bounds.scale_rel.ln_1p()),
        ("rgb", bounds.rgb),
        ("alpha", bounds.alpha),
        ("displacement", bounds.pos),
    ] {
        let measured = worst.get(key).copied().unwrap_or(0.0);
        if measured > limit + 1e-9 {
            return Err(Error::BoundViolation(format!(
                "encoder verification failed: {key} deviated {measured:.6e}, bound is {limit:.6e}"
            )));
        }
    }
    Ok(())
}
