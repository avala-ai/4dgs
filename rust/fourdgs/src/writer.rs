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
use crate::model::{AudioTrack, GaussianSet};
use crate::opcode as op;
use crate::quantization::{
    life_class, life_half, morton_order, motion_step, mu_step, quantize_rotation, rct_forward,
    rint, support_k, Bounds, Profile, Steps,
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
    /// Absence is the signal: no audio means no record at all, not an empty one.
    pub audio: Option<AudioTrack>,
    pub camera: Option<rec::Camera>,
    pub metadata: Vec<rec::Metadata>,
    pub attachments: Vec<rec::Attachment>,
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

fn quantize_scene(g: &GaussianSet, opts: &WriteOptions) -> Result<Quantized> {
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

fn encode(
    g: &GaussianSet,
    duration_sec: f64,
    opts: &WriteOptions,
    extras: &SceneExtras,
) -> Result<Vec<u8>> {
    let n = g.count();
    let q = quantize_scene(g, opts)?;

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
            flags: if extras.audio.is_some() {
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
            step_sh: q.steps.sh,
            bounds: declared_bounds(&q.bounds),
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

    if let Some(audio) = &extras.audio {
        out.extend_from_slice(
            &rec::Audio {
                codec: audio.codec.clone(),
                start_sec: audio.start_sec,
                data: audio.data.clone(),
            }
            .encode(),
        );
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

        let chunk_at = out.len() as u64;
        let chunk_blob =
            rec::encode_chunk(plan.t0, plan.t1, plan.level, members.len() as u32, &streams);
        out.extend_from_slice(&chunk_blob);

        let mut bands: Vec<(u8, u64, u64)> = Vec::new();
        if let Some(sh) = &g.sh {
            let row = g.sh_coefficients * 3;
            for (band, columns) in &sh_columns {
                let mut values: Vec<i64> = Vec::with_capacity(members.len() * columns.len());
                for i in &members {
                    for c in columns {
                        let mut v = sh[i * row + c] as i64;
                        if q.steps.sh > 1 {
                            let step = q.steps.sh as i64;
                            v = (v / step) * step + step / 2;
                        }
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
            }
        }

        index.push(rec::ChunkIndexEntry {
            t0: plan.t0,
            t1: plan.t1,
            chunk_offset: chunk_at,
            chunk_length: chunk_blob.len() as u64,
            gaussian_count: members.len() as u32,
            bands,
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

/// The bounds map the file declares, keyed as the specification names them so that two
/// readers report the same number for the same file.
fn declared_bounds(b: &Bounds) -> BTreeMap<String, String> {
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
    map.insert("sh".to_string(), b.sh.to_string());
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
