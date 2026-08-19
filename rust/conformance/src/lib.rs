// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The canonical JSON two implementations are diffed on.
//!
//! Representation is pinned so that a disagreement is always about the format and never
//! about how a language spells a number: integers are strings, floats are rounded to a
//! fixed number of decimals, a never-fading gaussian's sigma is `null`, audio sources are
//! an array (empty when absent), and keys are sorted.
//!
//! **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an
//! encoder and readers must not rely on their order, so a summary that did would be asking
//! two correct decoders to disagree. Everything per-gaussian is taken in the content order
//! defined by [`stable_order`], which is derived from decoded values alone.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt::Write as _;

use fourdgs::keyframe_delta_file::DecodedSequence;
use fourdgs::model::{AudioSource, GaussianSet};
use fourdgs::object_layer::{
    canonical_state_scalar_key, compare_content_rows, exact_canonical_sum, stable_order,
    ObjectLayer,
};
use fourdgs::provenance::{pose_at, Pose, PoseSampled, Provenance};
use fourdgs::records::{Attachment, Camera, Header, Metadata, Statistics, SummaryOffset};
use fourdgs::Result;

pub const FLOAT_DECIMALS: usize = 6;
/// How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
/// pass by getting a prefix right.
pub const SAMPLE: usize = 16;
/// How many camera keyframes appear in full, so a long trajectory cannot bloat a summary.
pub const CAMERA_KEYFRAMES: usize = 4;
/// The same cap for a rig trajectory, which is unbounded for the same reason and worse: a
/// ten-minute capture at 100 Hz is sixty thousand samples.
pub const RIG_SAMPLES: usize = 4;
pub const AUDIO_KEYFRAMES: usize = 4;

/// A JSON value, with objects sorted by key.
/// What a runner has to say about a file: the summary, or the name of the refusal.
///
/// A refusal is a result, not a crash. The runner prints `{"refused": "<id>"}` on stdout
/// and exits 0, and the harness diffs that against the expectation like any other answer.
/// Exiting non-zero instead would collapse "refused for the right reason" and "fell over"
/// into one outcome — and the invalid corpus exists precisely to tell those apart.
pub enum Failure {
    /// A refusal this reader can name. The identifier is compared across every SDK.
    Refused(&'static str),
    /// Anything else. Goes to stderr with a non-zero exit, as before.
    Message(String),
}

impl Failure {
    /// Classify a decode error: named refusals become an answer, everything else a failure.
    ///
    /// An error the refusal table does not name — a truncated transport, an encoder bound
    /// violation — is still a failure here. Reporting it as a refusal would let a decoder
    /// pass the invalid corpus by falling over in the right place.
    pub fn from_error(path: &str, error: &fourdgs::Error) -> Failure {
        match error.refusal_code() {
            Some(code) => Failure::Refused(code),
            None => Failure::Message(format!("{path}: {error}")),
        }
    }
}

impl From<String> for Failure {
    /// The extra checks report their own prose; none of them is a refusal.
    fn from(message: String) -> Failure {
        Failure::Message(message)
    }
}

/// The canonical answer for a refused file.
pub fn refusal_json(code: &str) -> String {
    format!("{{\n  \"refused\": \"{code}\"\n}}")
}

pub enum J {
    Null,
    Bool(bool),
    Num(f64),
    ExactNum(String),
    Str(String),
    Arr(Vec<J>),
    Obj(BTreeMap<String, J>),
}

impl J {
    pub fn obj(pairs: Vec<(&str, J)>) -> J {
        J::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn write(&self, out: &mut String) {
        match self {
            J::Null => out.push_str("null"),
            J::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            // Always six decimals: the harness compares parsed values, and a fixed
            // precision is what makes two languages produce the same double.
            J::Num(v) => push_canonical_decimal(out, *v),
            J::ExactNum(token) => out.push_str(token),
            J::Str(s) => write_string(out, s),
            J::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            J::Obj(map) => {
                out.push('{');
                for (i, (key, value)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_string(out, key);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }

    pub fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }
}

/// Append one finite value at the canonical decimal precision, without the sign of a zero.
///
/// `canonical.py` states the rule — "a zero is `0.0` and never `-0.0`" — because the sign
/// records which side of zero the arithmetic landed on, and that is a property of the
/// platform rather than of the scene. `{:.6}` keeps it: every value in `(-5e-7, -0.0]`
/// renders as `-0.000000`, which is precisely where a composed centre at the noise floor
/// lands. Nothing caught it because `run.py` compared parsed values and `-0.0 == 0.0`.
///
/// A rendered fixed-point value is a zero exactly when it holds no digit from one to nine,
/// which stays correct if `FLOAT_DECIMALS` ever changes — a spelled-out `"-0.000000"`
/// comparison would not.
fn push_canonical_decimal(out: &mut String, value: f64) {
    let start = out.len();
    let _ = write!(out, "{value:.*}", FLOAT_DECIMALS);
    let rendered = &out[start..];
    if rendered.starts_with('-') && !rendered.bytes().any(|byte| (b'1'..=b'9').contains(&byte)) {
        out.remove(start);
    }
}

fn exact_sum(values: impl IntoIterator<Item = f64>) -> J {
    exact_canonical_sum(values).map_or(J::Null, J::ExactNum)
}

fn write_string(out: &mut String, s: &str) {
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
pub fn num(v: f64) -> J {
    if v.is_finite() {
        J::Num(v)
    } else {
        J::Null
    }
}

fn numf(v: f32) -> J {
    num(v as f64)
}

/// An integer as a string, so a 64-bit value survives a JSON parser backed by doubles.
pub fn int(v: u64) -> J {
    J::Str(v.to_string())
}

/// CRC-32 of a byte payload, as a string. Used where a summary needs to prove it read the
/// bytes and not merely their length.
pub fn crc(data: &[u8]) -> J {
    J::Str(fourdgs::serialization::crc32(data).to_string())
}

fn str_map(map: &BTreeMap<String, String>) -> J {
    J::Obj(
        map.iter()
            .map(|(k, v)| (k.clone(), J::Str(v.clone())))
            .collect(),
    )
}

/// Everything a runner needs to summarize besides the gaussians themselves.
#[derive(Default)]
pub struct Extras<'a> {
    pub camera: Option<&'a Camera>,
    pub metadata: &'a [Metadata],
    pub attachments: &'a [Attachment],
    pub statistics: Option<&'a Statistics>,
    pub summary_offsets: &'a [SummaryOffset],
    pub summary_crc_ok: Option<bool>,
    pub provenance: Option<&'a Provenance>,
    pub objects: Option<&'a ObjectLayer>,
}

/// The statement every implementation must agree on for a variant.
pub fn summarize(
    header: &Header,
    gaussians: &GaussianSet,
    audio_sources: &[AudioSource],
    chunk_intervals: &[(f64, f64)],
    extras: &Extras<'_>,
) -> Result<String> {
    let n = gaussians.count();
    let order = stable_order(gaussians);
    let sample = &order[..SAMPLE.min(order.len())];

    let rows = |arr: &[f32], width: usize| -> J {
        J::Arr(
            sample
                .iter()
                .map(|i| J::Arr((0..width).map(|k| numf(arr[i * width + k])).collect()))
                .collect(),
        )
    };
    let scalars = |arr: &[f32]| -> J { J::Arr(sample.iter().map(|i| numf(arr[*i])).collect()) };

    let mut never_fades = 0u64;
    let mut still = 0u64;
    for i in &order {
        if !gaussians.sigma_t[*i].is_finite() {
            never_fades += 1;
        }
        let speed = (gaussians.motions[i * 3] as f64).abs()
            + (gaussians.motions[i * 3 + 1] as f64).abs()
            + (gaussians.motions[i * 3 + 2] as f64).abs();
        if speed == 0.0 {
            still += 1;
        }
    }

    let mut sample_pairs = vec![
        ("positions", rows(&gaussians.positions, 3)),
        ("scales", rows(&gaussians.scales, 3)),
        ("rotations", rows(&gaussians.rotations, 4)),
        ("colors", rows(&gaussians.colors, 4)),
        ("motions", rows(&gaussians.motions, 3)),
        ("muT", scalars(&gaussians.mu_t)),
        ("sigmaT", scalars(&gaussians.sigma_t)),
        ("winLo", scalars(&gaussians.win_lo)),
        ("winHi", scalars(&gaussians.win_hi)),
    ];
    if let Some(object_ids) = &gaussians.object_id {
        sample_pairs.push((
            "objectIds",
            J::Arr(sample.iter().map(|i| int(object_ids[*i] as u64)).collect()),
        ));
    }

    let mut pairs: Vec<(&str, J)> = vec![
        ("gaussianCount", int(n as u64)),
        ("durationSec", num(header.duration_sec)),
        ("cutoff", num(header.cutoff)),
        // The Header's first two fields: readable everywhere, asserted nowhere until now.
        ("profile", J::Str(header.profile.clone())),
        ("library", J::Str(header.library.clone())),
        ("shDegree", J::Num(header.sh_degree as f64)),
        ("temporalModel", J::Str(header.temporal_model.clone())),
        ("hasAudio", J::Bool(header.has_audio())),
        (
            "audioSources",
            J::Arr({
                let mut sources: Vec<&AudioSource> = audio_sources.iter().collect();
                sources.sort_by_key(|source| source.source_id);
                sources
                    .into_iter()
                    .map(|source| audio_source(source, header.duration_sec / 2.0))
                    .collect()
            }),
        ),
        (
            "chunkIntervals",
            J::Arr(
                chunk_intervals
                    .iter()
                    .map(|(a, b)| J::Arr(vec![num(*a), num(*b)]))
                    .collect(),
            ),
        ),
        ("headerAttributes", str_map(&header.attributes)),
        (
            "metadataRecords",
            J::Arr(
                extras
                    .metadata
                    .iter()
                    .map(|m| {
                        J::obj(vec![
                            ("name", J::Str(m.name.clone())),
                            ("entries", str_map(&m.entries)),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "attachments",
            J::Arr(
                extras
                    .attachments
                    .iter()
                    .map(|a| {
                        J::obj(vec![
                            ("name", J::Str(a.name.clone())),
                            ("mediaType", J::Str(a.media_type.clone())),
                            ("byteLength", int(a.data.len() as u64)),
                            ("crc", crc(&a.data)),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "camera",
            match extras.camera {
                None => J::Null,
                Some(c) => camera(c),
            },
        ),
        (
            "statistics",
            match extras.statistics {
                None => J::Null,
                Some(s) => J::obj(vec![
                    ("gaussianCount", int(s.gaussian_count)),
                    ("chunkCount", int(s.chunk_count as u64)),
                    ("durationSec", num(s.duration_sec)),
                    ("aabb", J::Arr(s.aabb.iter().map(|v| num(*v)).collect())),
                ]),
            },
        ),
        (
            "summaryOffsets",
            J::Arr(
                extras
                    .summary_offsets
                    .iter()
                    .map(|s| {
                        J::obj(vec![
                            ("groupOpcode", int(s.group_opcode as u64)),
                            ("groupStart", int(s.group_start)),
                            ("groupLength", int(s.group_length)),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "summaryCrcOk",
            match extras.summary_crc_ok {
                None => J::Null,
                Some(v) => J::Bool(v),
            },
        ),
        ("sh", spherical_harmonics(gaussians, &order)),
        ("sample", J::obj(sample_pairs)),
        (
            "aggregate",
            J::obj(vec![
                (
                    "positionSum",
                    J::Arr(
                        (0..3)
                            .map(|axis| {
                                exact_sum(
                                    (0..n)
                                        .map(|index| gaussians.positions[index * 3 + axis] as f64),
                                )
                            })
                            .collect(),
                    ),
                ),
                (
                    "opacitySum",
                    exact_sum((0..n).map(|index| gaussians.colors[index * 4 + 3] as f64)),
                ),
                ("neverFadesCount", int(never_fades)),
                ("zeroMotionCount", int(still)),
            ]),
        ),
    ];

    // Omitted entirely when the file carries no provenance, which is deliberate and is NOT
    // the `audioSources` convention above. `audioSources` is empty when absent because
    // audio presence is a property of every file — the Header declares it either way — so
    // both paths have to be visible in every variant. Provenance has no such flag and no
    // such duty: a file that carries none is a file the record family does not apply to,
    // and announcing it would have changed every pre-existing expectation and reported
    // three SDKs that correctly skip these records by length as failures.
    if let Some(prov) = extras.provenance {
        if !prov.is_empty() {
            pairs.push(("provenance", provenance(prov)?));
        }
    }

    let empty_objects = ObjectLayer::default();
    let objects = extras.objects.unwrap_or(&empty_objects);
    if !objects.is_empty() || gaussians.object_id.is_some() {
        let (object_summary, states) = objects_and_states(header, gaussians, objects)?;
        pairs.push(("objects", object_summary));
        pairs.push(("states", states));
    }

    Ok(J::obj(pairs).to_json())
}

/// Object records and post-track state at three canonical probes.
fn objects_and_states(
    header: &Header,
    gaussians: &GaussianSet,
    layer: &ObjectLayer,
) -> Result<(J, J)> {
    let mut tracks = Vec::with_capacity(layer.tracks.len());
    for track in &layer.tracks {
        let mut poses = Vec::new();
        for probe in probe_times(track) {
            poses.push(pose_row(probe, pose_at(track, probe)?.as_ref(), None));
        }
        tracks.push(J::obj(vec![
            ("objectId", int(track.object_id as u64)),
            ("interpolation", J::Num(track.interpolation as f64)),
            ("sampleCount", int(track.sample_count() as u64)),
            ("posesAt", J::Arr(poses)),
        ]));
    }

    let mut entries = Vec::new();
    let embedding_dim = match &layer.table {
        None => 0,
        Some(table) => {
            entries.reserve(table.entries.len());
            for entry in &table.entries {
                let embedding_crc = match &entry.embedding {
                    None => J::Null,
                    Some(embedding) => {
                        let mut bytes =
                            Vec::with_capacity(embedding.len() * std::mem::size_of::<f32>());
                        for value in embedding {
                            bytes.extend_from_slice(&value.to_le_bytes());
                        }
                        crc(&bytes)
                    }
                };
                entries.push(J::obj(vec![
                    ("objectId", int(entry.object_id as u64)),
                    ("label", J::Str(entry.label.clone())),
                    (
                        "anchor",
                        J::Arr(entry.anchor.iter().map(|value| numf(*value)).collect()),
                    ),
                    // The decoded dynamics values, not merely their presence: a summary that
                    // said only whether the record was there would pass a decoder that read
                    // the nine floats and exposed zeros. Null when the entry carries none.
                    (
                        "dynamics",
                        match &entry.dynamics {
                            None => J::Null,
                            Some((velocity, angular_velocity, acceleration)) => J::obj(vec![
                                (
                                    "velocity",
                                    J::Arr(velocity.iter().map(|v| numf(*v)).collect()),
                                ),
                                (
                                    "angularVelocity",
                                    J::Arr(angular_velocity.iter().map(|v| numf(*v)).collect()),
                                ),
                                (
                                    "acceleration",
                                    J::Arr(acceleration.iter().map(|v| numf(*v)).collect()),
                                ),
                            ]),
                        },
                    ),
                    ("hasEmbedding", J::Bool(entry.embedding.is_some())),
                    ("embeddingCrc", embedding_crc),
                ]));
            }
            table.embedding_dim
        }
    };
    let objects = J::obj(vec![
        ("embeddingDim", J::Num(embedding_dim as f64)),
        ("table", J::Arr(entries)),
        ("tracks", J::Arr(tracks)),
    ]);

    let duration = header.duration_sec.max(0.0);
    let state_times = [0.0, 0.5 * duration, (duration - 1e-6).max(0.0)];
    let mut states = Vec::with_capacity(state_times.len());
    for t in state_times {
        let state = canonical_object_state_at(gaussians, layer, t, header.cutoff)?;

        let mut row_for_index = vec![None; gaussians.count()];
        for (row, index) in state.indices.iter().enumerate() {
            row_for_index[*index] = Some(row);
        }
        let mut live_indices = state.indices.clone();
        live_indices.sort_by(|&a, &b| {
            compare_content_rows(gaussians, a, b).then_with(|| {
                compare_state_rows(
                    &state,
                    row_for_index[a].expect("a live index has a row"),
                    row_for_index[b].expect("a live index has a row"),
                )
            })
        });
        let live_rows: Vec<usize> = live_indices
            .iter()
            .map(|index| row_for_index[*index].expect("a live index has a row"))
            .collect();
        let sample_rows: Vec<usize> = live_rows.iter().copied().take(SAMPLE).collect();
        let rows = |values: &[f64], width: usize| {
            J::Arr(
                sample_rows
                    .iter()
                    .map(|row| {
                        J::Arr(
                            (0..width)
                                .map(|axis| num(values[row * width + axis]))
                                .collect(),
                        )
                    })
                    .collect(),
            )
        };
        states.push(J::obj(vec![
            ("t", num(t)),
            ("liveCount", int(state.indices.len() as u64)),
            (
                "sample",
                J::obj(vec![
                    ("positions", rows(&state.centers, 3)),
                    ("orientations", rows(&state.orientations, 4)),
                    (
                        "objectIds",
                        J::Arr(
                            sample_rows
                                .iter()
                                .map(|row| int(state.object_ids[*row] as u64))
                                .collect(),
                        ),
                    ),
                ]),
            ),
            (
                "aggregate",
                J::obj(vec![
                    (
                        "positionSum",
                        J::Arr(
                            (0..3)
                                .map(|axis| {
                                    exact_sum(
                                        live_rows.iter().map(|row| state.centers[row * 3 + axis]),
                                    )
                                })
                                .collect(),
                        ),
                    ),
                    (
                        "opacitySum",
                        exact_sum(live_rows.iter().map(|row| state.opacity[*row])),
                    ),
                ]),
            ),
        ]));
    }

    Ok((objects, J::Arr(states)))
}

struct CanonicalObjectState {
    indices: Vec<usize>,
    centers: Vec<f64>,
    orientations: Vec<f64>,
    opacity: Vec<f64>,
    object_ids: Vec<u32>,
}

fn compare_state_rows(state: &CanonicalObjectState, a: usize, b: usize) -> Ordering {
    for (values, width) in [(&state.centers, 3usize), (&state.orientations, 4)] {
        for axis in 0..width {
            let ord = match (
                canonical_state_scalar_key(values[a * width + axis]),
                canonical_state_scalar_key(values[b * width + axis]),
            ) {
                (Some(x), Some(y)) => x.partial_cmp(&y).expect("finite state keys are ordered"),
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (None, None) => Ordering::Equal,
            };
            if ord != Ordering::Equal {
                return ord;
            }
        }
    }
    state.object_ids[a].cmp(&state.object_ids[b])
}

/// Reconstruct in f64 for the canonical six-decimal comparison. Production state arrays
/// are f32; widening decoded fields first matches the Python reference and keeps the
/// comparison independent of an SDK's output storage type.
fn canonical_object_state_at(
    gaussians: &GaussianSet,
    layer: &ObjectLayer,
    t: f64,
    cutoff: f64,
) -> Result<CanonicalObjectState> {
    let mut state = CanonicalObjectState {
        indices: Vec::new(),
        centers: Vec::new(),
        orientations: Vec::new(),
        opacity: Vec::new(),
        object_ids: Vec::new(),
    };
    for i in 0..gaussians.count() {
        if !(gaussians.win_lo[i] as f64 <= t && t < gaussians.win_hi[i] as f64) {
            continue;
        }
        let mu = gaussians.mu_t[i] as f64;
        let sigma = gaussians.sigma_t[i] as f64;
        let marginal = if sigma.is_finite() {
            let z = (t - mu) / sigma.max(1e-30);
            (-0.5 * z * z).exp()
        } else {
            1.0
        };
        if marginal < cutoff {
            continue;
        }
        state.indices.push(i);
        for axis in 0..3 {
            state.centers.push(
                gaussians.positions[i * 3 + axis] as f64
                    + gaussians.motions[i * 3 + axis] as f64 * (t - mu),
            );
        }
        state.orientations.extend(
            gaussians.rotations[i * 4..i * 4 + 4]
                .iter()
                .map(|value| *value as f64),
        );
        state
            .opacity
            .push(gaussians.colors[i * 4 + 3] as f64 * marginal);
        state
            .object_ids
            .push(gaussians.object_id.as_ref().map_or(0, |ids| ids[i]));
    }

    let referenced: std::collections::HashSet<u32> = state
        .object_ids
        .iter()
        .copied()
        .filter(|id| *id != 0)
        .collect();
    let mut poses = BTreeMap::new();
    for track in &layer.tracks {
        if referenced.contains(&track.object_id) {
            if let Some(pose) = pose_at(track, t)? {
                poses.insert(track.object_id, pose);
            }
        }
    }
    for (row, object_id) in state.object_ids.iter().enumerate() {
        let Some(pose) = poses.get(object_id) else {
            continue;
        };
        let center = [
            state.centers[row * 3],
            state.centers[row * 3 + 1],
            state.centers[row * 3 + 2],
        ];
        let moved = pose.apply(center);
        state.centers[row * 3..row * 3 + 3].copy_from_slice(&moved);

        let [ax, ay, az, aw] = pose.rotation;
        let bx = state.orientations[row * 4];
        let by = state.orientations[row * 4 + 1];
        let bz = state.orientations[row * 4 + 2];
        let bw = state.orientations[row * 4 + 3];
        state.orientations[row * 4..row * 4 + 4].copy_from_slice(&[
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ]);
    }
    Ok(state)
}

/// Every readable provenance field, plus the arithmetic the fields imply.
///
/// The fields alone would not be enough. `Header.profile` was readable in every SDK and
/// asserted by none, so a binding that returned an empty string passed — and the same
/// hiding place exists one level up here: two implementations can agree on every stored
/// quaternion and still disagree about the pose halfway between two of them, because slerp
/// has a sign convention and clamping has an edge. So the summary carries the interpolated
/// poses as well as the samples, at probe times derived from the decoded data alone,
/// including one before the first sample and one after the last.
fn provenance(prov: &Provenance) -> Result<J> {
    let mut trajectories = Vec::with_capacity(prov.trajectories.len());
    for t in &prov.trajectories {
        let mut poses = Vec::new();
        for probe in probe_times(t) {
            poses.push(pose_row(probe, pose_at(t, probe)?.as_ref(), None));
        }
        trajectories.push(J::obj(vec![
            ("name", J::Str(t.name.clone())),
            ("interpolation", J::Num(t.interpolation as f64)),
            ("sampleCount", int(t.sample_count() as u64)),
            (
                "samples",
                J::Arr(
                    (0..t.sample_count().min(RIG_SAMPLES))
                        .map(|i| {
                            J::obj(vec![
                                ("time", num(t.times[i])),
                                (
                                    "rotation",
                                    J::Arr(t.rotations[i].iter().map(|v| num(*v)).collect()),
                                ),
                                (
                                    "translation",
                                    J::Arr(t.translations[i].iter().map(|v| num(*v)).collect()),
                                ),
                            ])
                        })
                        .collect(),
                ),
            ),
            ("posesAt", J::Arr(poses)),
        ]));
    }

    // The composition rule, which is the one thing here no single record states and every
    // consumer of a moving rig depends on.
    let mut sensor_poses = Vec::with_capacity(prov.sensors.len());
    for s in &prov.sensors {
        let probe = sensor_probe_time(prov, &s.rig_name);
        sensor_poses.push(pose_row(
            probe,
            prov.sensor_pose_at(&s.name, probe)?.as_ref(),
            Some(&s.name),
        ));
    }

    Ok(J::obj(vec![
        (
            "frames",
            J::Arr(
                prov.frames
                    .iter()
                    .map(|f| {
                        J::obj(vec![
                            ("name", J::Str(f.name.clone())),
                            ("handedness", J::Num(f.handedness as f64)),
                            ("upAxis", J::Num(f.up_axis as f64)),
                            ("forwardAxis", J::Num(f.forward_axis as f64)),
                            ("lengthUnit", J::Num(f.length_unit as f64)),
                            ("metresPerUnit", num(f.metres_per_unit)),
                            // The resolution rule, per frame: a consumer handed a file
                            // whose two unit fields disagree still has to produce one
                            // number, and this is it.
                            (
                                "metresPerUnitResolved",
                                match prov.metres_per_unit(&f.name) {
                                    None => J::Null,
                                    Some(v) => num(v),
                                },
                            ),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "anchors",
            J::Arr(
                prov.anchors
                    .iter()
                    .map(|a| {
                        J::obj(vec![
                            ("frameName", J::Str(a.frame_name.clone())),
                            ("latitudeDeg", num(a.latitude_deg)),
                            ("longitudeDeg", num(a.longitude_deg)),
                            ("altitudeM", num(a.altitude_m)),
                            ("headingDeg", num(a.heading_deg)),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "sensors",
            J::Arr(
                prov.sensors
                    .iter()
                    .map(|s| {
                        J::obj(vec![
                            ("name", J::Str(s.name.clone())),
                            ("modality", J::Str(s.modality.clone())),
                            ("cameraModel", J::Num(s.camera_model as f64)),
                            ("widthPx", int(s.width_px as u64)),
                            ("heightPx", int(s.height_px as u64)),
                            ("fx", num(s.fx)),
                            ("fy", num(s.fy)),
                            ("cx", num(s.cx)),
                            ("cy", num(s.cy)),
                            (
                                "distortion",
                                J::Arr(s.distortion.iter().map(|v| num(*v)).collect()),
                            ),
                            (
                                "rotation",
                                J::Arr(s.rotation.iter().map(|v| num(*v)).collect()),
                            ),
                            (
                                "translation",
                                J::Arr(s.translation.iter().map(|v| num(*v)).collect()),
                            ),
                            ("poseReference", J::Num(s.pose_reference as f64)),
                            ("rigName", J::Str(s.rig_name.clone())),
                        ])
                    })
                    .collect(),
            ),
        ),
        ("trajectories", J::Arr(trajectories)),
        ("sensorPosesAt", J::Arr(sensor_poses)),
    ]))
}

/// Times a summary evaluates a trajectory at, derived from the trajectory itself.
///
/// Two of the five are outside the sample range on purpose: clamping is a rule, and a rule
/// no expectation exercises is a rule an implementation can decline to have.
fn probe_times<T: PoseSampled + ?Sized>(trajectory: &T) -> Vec<f64> {
    if trajectory.sample_count() == 0 {
        return Vec::new();
    }
    let first = trajectory.time(0);
    let last = trajectory.time(trajectory.sample_count() - 1);
    vec![
        first - 0.5,
        first,
        first / 2.0 + last / 2.0,
        last,
        last + 0.5,
    ]
}

/// When to evaluate a sensor's scene pose: the midpoint of the rig it rides.
fn sensor_probe_time(prov: &Provenance, rig_name: &str) -> f64 {
    // The empty string is a legal trajectory name — the default capture rig — and
    // `sensor_pose_at` resolves it, so skipping the lookup summarized a moving unnamed
    // rig at t=0 and never exercised its composed pose.
    match prov.trajectory(rig_name) {
        Some(t) if t.sample_count() > 0 => {
            let (first, last) = (t.times[0], t.times[t.sample_count() - 1]);
            first / 2.0 + last / 2.0
        }
        _ => 0.0,
    }
}

fn pose_row(t: f64, pose: Option<&Pose>, sensor: Option<&str>) -> J {
    let mut pairs: Vec<(&str, J)> = vec![("time", num(t))];
    if let Some(name) = sensor {
        pairs.push(("sensor", J::Str(name.to_string())));
    }
    match pose {
        None => {
            pairs.push(("rotation", J::Null));
            pairs.push(("translation", J::Null));
        }
        Some(p) => {
            pairs.push((
                "rotation",
                J::Arr(p.rotation.iter().map(|v| num(*v)).collect()),
            ));
            pairs.push((
                "translation",
                J::Arr(p.translation.iter().map(|v| num(*v)).collect()),
            ));
        }
    }
    J::obj(pairs)
}

fn audio_source(source: &AudioSource, sample_time: f64) -> J {
    let state = source.state_at(sample_time);
    J::obj(vec![
        ("sourceId", int(source.source_id as u64)),
        ("name", J::Str(source.name.clone())),
        ("codec", J::Str(source.codec.clone())),
        ("channelLayout", J::Str(source.channel_layout.clone())),
        ("startSec", num(source.start_sec)),
        ("durationSec", num(source.duration_sec)),
        ("gain", num(source.gain)),
        ("spatial", J::Bool(source.spatial)),
        ("loop", J::Bool(source.loop_)),
        (
            "position",
            J::Arr(source.position.iter().map(|value| num(*value)).collect()),
        ),
        (
            "rotation",
            J::Arr(source.rotation.iter().map(|value| num(*value)).collect()),
        ),
        ("keyframeCount", int(source.keyframes.len() as u64)),
        (
            "keyframes",
            J::Arr(
                source
                    .keyframes
                    .iter()
                    .take(AUDIO_KEYFRAMES)
                    .map(|keyframe| {
                        J::obj(vec![
                            ("time", num(keyframe.time)),
                            (
                                "position",
                                J::Arr(keyframe.position.iter().map(|value| num(*value)).collect()),
                            ),
                            (
                                "rotation",
                                J::Arr(keyframe.rotation.iter().map(|value| num(*value)).collect()),
                            ),
                        ])
                    })
                    .collect(),
            ),
        ),
        ("interpolation", J::Str(source.interpolation.clone())),
        (
            "stateAtHalf",
            J::obj(vec![
                ("active", J::Bool(state.active)),
                ("localTime", num(state.local_time)),
                (
                    "position",
                    J::Arr(state.position.iter().map(|value| num(*value)).collect()),
                ),
                (
                    "rotation",
                    J::Arr(state.rotation.iter().map(|value| num(*value)).collect()),
                ),
                ("gain", num(state.gain)),
            ]),
        ),
        ("byteLength", int(source.data.len() as u64)),
        ("crc", crc(&source.data)),
    ])
}

fn camera(c: &Camera) -> J {
    J::obj(vec![
        ("fovYDeg", num(c.fov_y_deg)),
        (
            "position",
            J::Arr(c.position.iter().map(|v| num(*v)).collect()),
        ),
        ("target", J::Arr(c.target.iter().map(|v| num(*v)).collect())),
        ("keyframeCount", int(c.times.len() as u64)),
        (
            "keyframes",
            J::Arr(
                (0..c.times.len().min(CAMERA_KEYFRAMES))
                    .map(|i| {
                        J::obj(vec![
                            ("time", num(c.times[i])),
                            (
                                "position",
                                J::Arr(c.positions[i].iter().map(|v| num(*v)).collect()),
                            ),
                            (
                                "target",
                                J::Arr(c.targets[i].iter().map(|v| num(*v)).collect()),
                            ),
                        ])
                    })
                    .collect(),
            ),
        ),
        ("interpolation", J::Str(c.interpolation.clone())),
        ("loop", J::Bool(c.loop_)),
    ])
}

/// Degree, width and a checksum of the coefficients in content order.
///
/// A digest rather than the coefficients themselves: degree 2 over 512 gaussians is 12,288
/// bytes, which would swamp the expectation without proving anything the checksum does not.
fn spherical_harmonics(gaussians: &GaussianSet, order: &[usize]) -> J {
    let Some(sh) = &gaussians.sh else {
        return J::Null;
    };
    if gaussians.sh_degree == 0 || gaussians.sh_coefficients == 0 {
        return J::Null;
    }
    let width = gaussians.sh_coefficients * 3;
    let mut payload = Vec::with_capacity(order.len() * width);
    for i in order {
        payload.extend_from_slice(&sh[i * width..(i + 1) * width]);
    }
    J::obj(vec![
        ("degree", J::Num(gaussians.sh_degree as f64)),
        ("coefficients", int(gaussians.sh_coefficients as u64)),
        ("crc", crc(&payload)),
    ])
}

// --------------------------------------------------------------------------
// keyframe-delta: the states summary two implementations are diffed on
// --------------------------------------------------------------------------

/// The statement two implementations are diffed on for a `keyframe-delta` file.
///
/// `chunks` proves a decoder read `depth`, `deltaMode` and `liveCount` — a field no row
/// mentions is one an implementation can decline to decode. `states` is the reconstruction
/// at an instant: for each probe, the composed population's live count, a sample of centres
/// and scales in id order, and the aggregate over the whole population. Reconstruction is in
/// `f64`, matching the Python reference, so the six-decimal comparison is exact.
pub fn keyframe_delta_states_json(seq: &DecodedSequence) -> String {
    // The canonical now lives in the library, so a binding that decodes through the C ABI
    // emits the same bytes this crate does. Delegating keeps the Rust conformance output
    // byte-identical to what it produced when the emitter lived here.
    fourdgs::keyframe_delta_file::keyframe_delta_states_json(seq)
}

#[cfg(test)]
mod tests {
    use super::{summarize, Extras, J};
    use fourdgs::model::GaussianSet;
    use fourdgs::object_layer::{canonical_parts, ObjectLayer};
    use fourdgs::records::Header;

    fn gaussians(positions: &[[f32; 3]], motions: &[[f32; 3]]) -> GaussianSet {
        let count = positions.len();
        GaussianSet {
            positions: positions.iter().flatten().copied().collect(),
            scales: vec![1.0; count * 3],
            rotations: (0..count).flat_map(|_| [0.0, 0.0, 0.0, 1.0]).collect(),
            colors: vec![1.0; count * 4],
            motions: motions.iter().flatten().copied().collect(),
            mu_t: vec![0.0; count],
            sigma_t: vec![f32::INFINITY; count],
            win_lo: vec![0.0; count],
            win_hi: vec![4_000_000.0; count],
            object_id: Some(vec![0; count]),
            ..Default::default()
        }
    }

    fn header(count: usize) -> Header {
        Header {
            duration_sec: 4_000_000.0,
            gaussian_count: count as u64,
            cutoff: 0.05,
            aabb: vec![0.0; 6],
            ..Default::default()
        }
    }

    fn summaries(gaussians: &GaussianSet) -> (String, String) {
        let header = header(gaussians.count());
        let objects = ObjectLayer::default();
        let extras = Extras {
            objects: Some(&objects),
            ..Default::default()
        };
        let runner = summarize(&header, gaussians, &[], &[], &extras).expect("summary");
        let core = canonical_parts(&header, gaussians, &objects)
            .expect("core canonical")
            .states;
        (runner, core)
    }

    /// The runner's own emitter, held to the rule the reference states: a zero is `0.0`
    /// and never `-0.0`. `{:.6}` keeps the sign for every value in `(-5e-7, -0.0]`, and a
    /// composed centre at the noise floor is exactly what lands there — three variants of
    /// the committed corpus carried one before this.
    #[test]
    fn a_rendered_zero_is_never_signed() {
        let render = |v: f64| J::Num(v).to_json();
        assert_eq!(render(-0.0), "0.000000");
        assert_eq!(render(-1e-9), "0.000000");
        assert_eq!(render(-4e-7), "0.000000");
        assert_eq!(render(0.0), "0.000000");
        assert_eq!(render(-1e-6), "-0.000001");
        assert_eq!(render(-1.5), "-1.500000");
    }

    /// Two rows alike but for where the sign of a zero sits. They tie in every emitted
    /// value, so the two decode orders have to produce one document — which they do only
    /// once the emitter refuses to spell the sign.
    #[test]
    fn signed_zero_cannot_order_a_summary() {
        let zero = [0.0f32, 0.0, 0.0];
        let forward = gaussians(&[[-0.0, 0.0, 0.0], [0.0, -0.0, 0.0]], &[zero, zero]);
        let reversed = gaussians(&[[0.0, -0.0, 0.0], [-0.0, 0.0, 0.0]], &[zero, zero]);

        let a = summaries(&forward);
        let b = summaries(&reversed);
        assert_eq!(a, b);
        assert!(!a.0.contains("-0.000000"), "{}", a.0);
        assert!(!a.1.contains("-0.000000"), "{}", a.1);
    }

    #[test]
    fn rounded_key_ties_do_not_fall_back_to_decoded_order() {
        // The stored motion fields tie after six-decimal rounding, but their composed
        // centres at the middle probe are 0.2 and 0.8. A stable rounded-only sort would
        // therefore expose whichever row the decoder happened to return first.
        let forward = gaussians(
            &[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
            &[[1e-7, 0.0, 0.0], [4e-7, 0.0, 0.0]],
        );
        let reversed = gaussians(
            &[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
            &[[4e-7, 0.0, 0.0], [1e-7, 0.0, 0.0]],
        );

        let a = summaries(&forward);
        let b = summaries(&reversed);
        assert_eq!(a, b);
        assert!(
            a.1.contains("\"positions\":[[0.200000,0.000000,0.000000],[0.800000"),
            "the exact motion tie-breaker did not choose content order: {}",
            a.1
        );
    }

    #[test]
    fn state_aggregates_sum_exact_canonical_units() {
        // These are the same three decoded f32 rows in different resident orders. Exact
        // fixed-decimal units retain the small addend without depending on either order.
        let values = [1e20, 1.0, -1e20];
        let zero = [0.0, 0.0, 0.0];
        let forward = gaussians(&values.map(|x| [x, 0.0, 0.0]), &[zero, zero, zero]);
        let reversed = gaussians(
            &[
                [values[0], 0.0, 0.0],
                [values[2], 0.0, 0.0],
                [values[1], 0.0, 0.0],
            ],
            &[zero, zero, zero],
        );

        let a = summaries(&forward);
        let b = summaries(&reversed);
        assert_eq!(a, b);
        assert!(
            a.1.contains("\"positionSum\":[1.0,0.0,0.0]"),
            "the state did not sum exact canonical units: {}",
            a.1
        );
    }

    #[test]
    fn exact_sum_never_narrows_through_binary64() {
        let enormous = super::exact_sum([1e308; 10]).to_json();
        assert!(enormous.starts_with("1000000000000000"));
        assert!(enormous.ends_with(".0"));
        assert!(enormous.len() > 309);
        assert_eq!(super::exact_sum([1e20, -1e20, 3.25]).to_json(), "3.25");
        assert_eq!(super::exact_sum([-0.0]).to_json(), "0.0");
        assert_eq!(super::exact_sum([f64::INFINITY]).to_json(), "null");
    }
}
