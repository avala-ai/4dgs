// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The object layer: what the Object Table and the SE(3) tracks mean once read.
//!
//! [`crate::records`] knows the bytes; this module knows the composition and the one rule
//! that spans more than one record — that at most one track moves any object.
//!
//! The layer changes a reconstructed instant in exactly one way, and it is the
//! load-bearing rule of the whole design (spec section 5.15.6):
//!
//! > A track transforms the base state; it does not replace it.
//!
//! For a gaussian belonging to object `k`, with the base centre `c0` that the temporal
//! model produced (spec section 3), and the track's pose `(R, T)` at `t`:
//!
//! ```text
//! center(t) = R * c0 + T
//! orientation(t) = rotation(R) ⊗ orientation0
//! ```
//!
//! The pose is relative to the object's stored (rest) configuration, so ignoring the whole
//! layer leaves every object at rest — a valid scene — rather than a pile at the origin.
//! The transform is rigid: it moves the centre, composes the orientation, and touches
//! neither opacity nor the temporal fields, so section 3's visibility runs unchanged on
//! the base. A gaussian that carries per-gaussian motion AND belongs to a moving track is
//! neither forbidden nor track-wins: its motion moves it inside the object's frame (folded
//! into `c0`), and the track then transports the object. The two compose, base first.
//!
//! Nothing here is required to decode gaussians. A file with no object layer produces an
//! empty [`ObjectLayer`], which is a value and never an error.

use std::collections::{HashMap, HashSet};

use crate::error::{Error, Result};
use crate::provenance::{pose_at, quaternion_multiply, Pose, PoseSampled};
use crate::records::{ObjectTable, ObjectTrack};

/// Background / unassigned. A gaussian carrying this id belongs to no object and is never
/// transformed; a track may not name it (refused at parse).
pub const BACKGROUND: u32 = 0;

impl PoseSampled for ObjectTrack {
    fn name(&self) -> &str {
        // Tracks are named by object id, not a string; this is only for messages.
        "object track"
    }
    fn interpolation(&self) -> u8 {
        self.interpolation
    }
    fn sample_count(&self) -> usize {
        self.times.len()
    }
    fn time(&self, i: usize) -> f64 {
        self.times[i]
    }
    fn rotation(&self, i: usize) -> [f64; 4] {
        self.rotations[i]
    }
    fn translation(&self, i: usize) -> [f64; 3] {
        self.translations[i]
    }
}

/// Every object-layer record a file carried, and the rule that spans the tracks.
///
/// `table` is the file's one Object Table, or `None`. `tracks` is the SE(3) tracks, at
/// most one per object. An empty instance is what a scene with no objects produces.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObjectLayer {
    pub table: Option<ObjectTable>,
    pub tracks: Vec<ObjectTrack>,
}

impl ObjectLayer {
    pub fn is_empty(&self) -> bool {
        self.table.is_none() && self.tracks.is_empty()
    }

    pub fn track(&self, object_id: u32) -> Option<&ObjectTrack> {
        self.tracks.iter().find(|t| t.object_id == object_id)
    }

    /// At most one track per object.
    ///
    /// Two tracks for one object would move its gaussians by two poses, which is the
    /// duplicate-name failure section 5.15.2 refuses for frames and sensors. Each track's
    /// own rules are enforced at parse; this is the one rule no single record can see.
    pub fn check(&self) -> Result<()> {
        let mut seen: HashSet<u32> = HashSet::with_capacity(self.tracks.len());
        for t in &self.tracks {
            if !seen.insert(t.object_id) {
                return Err(Error::Malformed(format!(
                    "two ObjectTrack records move object {}; a gaussian has one object and cannot \
                     be transported by two poses (section 5.15.6)",
                    t.object_id
                )));
            }
        }
        Ok(())
    }

    /// The rigid pose that transforms object `object_id` at scene time `t`.
    ///
    /// `None` when the object has no track — background, or an untracked object — in which
    /// case its gaussians keep their base state. A track reuses the trajectory
    /// clamp-and-slerp of [`pose_at`], so a query outside the sample range returns the
    /// nearest end sample rather than extrapolating.
    pub fn pose_at(&self, object_id: u32, t: f64) -> Result<Option<crate::provenance::Pose>> {
        if object_id == BACKGROUND {
            return Ok(None);
        }
        match self.track(object_id) {
            Some(track) if track.sample_count() > 0 => pose_at(track, t),
            _ => Ok(None),
        }
    }

    /// Compose tracks onto reconstructed centres and orientations.
    ///
    /// `centers` is `3 * n` flat, `orientations` is `4 * n` xyzw, and `object_ids` is
    /// `n`. Each gaussian whose object has a track is transformed in place; the rest pass
    /// through unchanged. Poses are sampled once per track and looked up by id, so
    /// composition is O(gaussians + tracks), not O(gaussians × tracks).
    pub fn apply(
        &self,
        centers: &mut [f32],
        orientations: &mut [f32],
        object_ids: &[u32],
        t: f64,
    ) -> Result<()> {
        self.check()?;
        let referenced: HashSet<u32> = object_ids
            .iter()
            .copied()
            .filter(|id| *id != BACKGROUND)
            .collect();
        let mut poses: HashMap<u32, Pose> =
            HashMap::with_capacity(self.tracks.len().min(referenced.len()));
        for track in &self.tracks {
            if !referenced.contains(&track.object_id) {
                continue;
            }
            if let Some(pose) = pose_at(track, t)? {
                poses.insert(track.object_id, pose);
            }
        }
        apply_poses(centers, orientations, object_ids, &poses)
    }
}

/// Compose already-sampled object poses onto one reconstructed instant.
///
/// Indexed readers use this entry point so they can range-sample a track without
/// materializing its complete sample arrays. The same transform implementation is shared
/// with [`ObjectLayer::apply`], keeping streamed and indexed reconstruction identical.
pub(crate) fn apply_poses(
    centers: &mut [f32],
    orientations: &mut [f32],
    object_ids: &[u32],
    poses: &HashMap<u32, Pose>,
) -> Result<()> {
    let count = object_ids.len();
    if centers.len() != count * 3 {
        return Err(Error::Malformed(format!(
            "object-layer composition received {} center values for {count} gaussians; expected {}",
            centers.len(),
            count * 3
        )));
    }
    if orientations.len() != count * 4 {
        return Err(Error::Malformed(format!(
            "object-layer composition received {} orientation values for {count} gaussians; \
             expected {}",
            orientations.len(),
            count * 4
        )));
    }
    for (i, &object_id) in object_ids.iter().enumerate() {
        let Some(pose) = poses.get(&object_id) else {
            continue;
        };
        let c0 = [
            centers[i * 3] as f64,
            centers[i * 3 + 1] as f64,
            centers[i * 3 + 2] as f64,
        ];
        let moved = pose.apply(c0);
        centers[i * 3] = moved[0] as f32;
        centers[i * 3 + 1] = moved[1] as f32;
        centers[i * 3 + 2] = moved[2] as f32;

        let r0 = [
            orientations[i * 4] as f64,
            orientations[i * 4 + 1] as f64,
            orientations[i * 4 + 2] as f64,
            orientations[i * 4 + 3] as f64,
        ];
        let moved_orientation = quaternion_multiply(pose.rotation, r0);
        for (axis, value) in moved_orientation.iter().enumerate() {
            orientations[i * 4 + axis] = *value as f32;
        }
    }
    Ok(())
}

/// Reconstructed state at `t` with the object layer composed onto it.
///
/// [`GaussianSet::state_at`] returns the base temporal state, which is the right answer
/// for a scene with no object layer and the wrong one for a scene that has tracks: the
/// gaussians of a moving object come back at their rest centres and orientations.
/// Composition stays a separate step because the layer is additive and a consumer that
/// only wants geometry should not pay for it — but leaving every caller to remember
/// [`ObjectLayer::apply`] makes the default answer the wrong one.
///
/// A scene with no layer, or one whose gaussians carry no membership, returns the base
/// state unchanged.
pub fn state_at_with_objects(
    gaussians: &crate::model::GaussianSet,
    objects: Option<&ObjectLayer>,
    t: f64,
    cutoff: f64,
) -> Result<crate::model::StateAt> {
    let mut state = gaussians.state_at(t, cutoff);
    let (Some(layer), Some(ids)) = (objects, gaussians.object_id.as_ref()) else {
        return Ok(state);
    };
    if layer.is_empty() {
        return Ok(state);
    }
    // `state_at` returns only the visible gaussians, so membership is gathered through
    // the same indices rather than assumed to be aligned with the whole set.
    let visible: Vec<u32> = state
        .indices
        .iter()
        .map(|i| ids.get(*i as usize).copied().unwrap_or(BACKGROUND))
        .collect();
    layer.apply(&mut state.centers, &mut state.orientations, &visible, t)?;
    Ok(state)
}

// ---------------------------------------------------------------------------
// Canonical JSON — the object summary every SDK is diffed on
// ---------------------------------------------------------------------------
//
// This lives in the core, beside the composition it reports, for the same reason
// `provenance::canonical_json` and `keyframe_delta_states_json` do: C++ and Swift reach the
// format through the C ABI, and a summary computed twice is a summary two bindings can
// disagree about. The arithmetic that matters here — base-then-track composition, the
// clamp-and-slerp behind each pose — happens once, in one language.

use crate::model::GaussianSet;
use crate::provenance::{int, num, Json};
use crate::records::Header;
use crate::serialization::crc32;

/// How many gaussians appear in full in a state's sample. The aggregates cover the rest.
const SAMPLE: usize = 16;

/// A comparison key: rounded like the summary, with infinity kept as infinity so every
/// language orders never-fading gaussians identically.
fn sortable(value: f32) -> f64 {
    let v = value as f64;
    if v.is_nan() {
        return f64::INFINITY;
    }
    if v.is_infinite() {
        return v;
    }
    let scale = 10f64.powi(6);
    (v * scale).round() / scale
}

/// Content order: derived from decoded values alone, never from decode order.
///
/// Gaussians may be reordered freely by an encoder and readers must not rely on their
/// order, so a summary that did would ask two correct decoders to disagree. Membership
/// joins the key after the harmonics — two gaussians can tie on every rounded field and
/// still belong to different objects.
pub fn stable_order(gaussians: &GaussianSet) -> Vec<usize> {
    let n = gaussians.count();
    let sh_width = gaussians
        .sh
        .as_ref()
        .map_or(0, |_| gaussians.sh_coefficients * 3);
    let mut keys: Vec<(Vec<f64>, usize)> = Vec::with_capacity(n);
    for i in 0..n {
        let mut row = Vec::with_capacity(17 + sh_width);
        for (arr, width) in [
            (&gaussians.positions, 3usize),
            (&gaussians.scales, 3),
            (&gaussians.rotations, 4),
            (&gaussians.colors, 4),
            (&gaussians.motions, 3),
        ] {
            for k in 0..width {
                row.push(sortable(arr[i * width + k]));
            }
        }
        row.push(sortable(gaussians.mu_t[i]));
        row.push(sortable(gaussians.sigma_t[i]));
        row.push(sortable(gaussians.win_lo[i]));
        row.push(sortable(gaussians.win_hi[i]));
        if let Some(sh) = &gaussians.sh {
            for k in 0..sh_width {
                row.push(sh[i * sh_width + k] as f64);
            }
        }
        if let Some(object_ids) = &gaussians.object_id {
            row.push(object_ids[i] as f64);
        }
        keys.push((row, i));
    }
    keys.sort_by(|a, b| {
        a.0.partial_cmp(&b.0)
            .expect("no key value is NaN; see `sortable`")
    });
    keys.into_iter().map(|(_, i)| i).collect()
}

/// Times a summary evaluates an object track at, derived from the track itself.
///
/// Two of the five are outside the sample range on purpose: clamping is a rule, and a rule
/// no expectation exercises is a rule an implementation can decline to have.
fn probe_times(track: &ObjectTrack) -> Vec<f64> {
    if track.sample_count() == 0 {
        return Vec::new();
    }
    let first = track.times[0];
    let last = track.times[track.sample_count() - 1];
    vec![
        first - 0.5,
        first,
        first / 2.0 + last / 2.0,
        last,
        last + 0.5,
    ]
}

fn pose_row(t: f64, pose: Option<&Pose>) -> Json {
    match pose {
        None => Json::obj(vec![
            ("time", num(t)),
            ("rotation", Json::Null),
            ("translation", Json::Null),
        ]),
        Some(p) => Json::obj(vec![
            ("time", num(t)),
            (
                "rotation",
                Json::Arr(p.rotation.iter().map(|v| num(*v)).collect()),
            ),
            (
                "translation",
                Json::Arr(p.translation.iter().map(|v| num(*v)).collect()),
            ),
        ]),
    }
}

/// One instant, reconstructed in f64 and composed.
struct CanonicalState {
    indices: Vec<usize>,
    centers: Vec<f64>,
    orientations: Vec<f64>,
    opacity: Vec<f64>,
    object_ids: Vec<u32>,
}

/// Reconstruct in double precision for the six-decimal comparison.
///
/// Production state arrays are f32 and that is the right storage for a decoder; widening
/// the decoded fields first is what keeps the summary a statement about the format rather
/// than about an SDK's output storage type.
fn canonical_state_at(
    gaussians: &GaussianSet,
    layer: &ObjectLayer,
    t: f64,
    cutoff: f64,
) -> Result<CanonicalState> {
    let mut state = CanonicalState {
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
                .map(|v| *v as f64),
        );
        state
            .opacity
            .push(gaussians.colors[i * 4 + 3] as f64 * marginal);
        state
            .object_ids
            .push(gaussians.object_id.as_ref().map_or(0, |ids| ids[i]));
    }

    let referenced: HashSet<u32> = state
        .object_ids
        .iter()
        .copied()
        .filter(|id| *id != BACKGROUND)
        .collect();
    let mut poses: HashMap<u32, Pose> = HashMap::new();
    for track in &layer.tracks {
        if !referenced.contains(&track.object_id) {
            continue;
        }
        if let Some(pose) = pose_at(track, t)? {
            poses.insert(track.object_id, pose);
        }
    }
    for (row, object_id) in state.object_ids.iter().enumerate() {
        let Some(pose) = poses.get(object_id) else {
            continue;
        };
        let c0 = [
            state.centers[row * 3],
            state.centers[row * 3 + 1],
            state.centers[row * 3 + 2],
        ];
        let moved = pose.apply(c0);
        state.centers[row * 3..row * 3 + 3].copy_from_slice(&moved);
        let r0 = [
            state.orientations[row * 4],
            state.orientations[row * 4 + 1],
            state.orientations[row * 4 + 2],
            state.orientations[row * 4 + 3],
        ];
        let turned = quaternion_multiply(pose.rotation, r0);
        state.orientations[row * 4..row * 4 + 4].copy_from_slice(&turned);
    }
    Ok(state)
}

/// The canonical object summary: the records, and the composed state at three probes.
///
/// Empty string when the file carries neither object records nor per-gaussian membership,
/// which is deliberate and mirrors provenance: an object record is additive to the
/// gaussian-birth model, so a file without one must summarize exactly as it did before the
/// layer existed. A binding omits the keys rather than emitting nulls.
///
/// Stored fields alone would not prove reconstruction. Two implementations can agree on
/// every table entry and every track sample and still disagree about where a gaussian ends
/// up, because the layer's one rule is an order — base first, track second. The `states`
/// make that order visible, including orientation.
pub fn canonical_json(
    header: &Header,
    gaussians: &GaussianSet,
    layer: &ObjectLayer,
) -> Result<String> {
    if layer.is_empty() && gaussians.object_id.is_none() {
        return Ok(String::new());
    }
    layer.check()?;

    let mut tracks = Vec::with_capacity(layer.tracks.len());
    for track in &layer.tracks {
        let mut poses = Vec::new();
        for probe in probe_times(track) {
            poses.push(pose_row(probe, pose_at(track, probe)?.as_ref()));
        }
        tracks.push(Json::obj(vec![
            ("objectId", int(track.object_id as u64)),
            ("interpolation", Json::Num(track.interpolation as f64)),
            ("sampleCount", int(track.sample_count() as u64)),
            ("posesAt", Json::Arr(poses)),
        ]));
    }

    let mut entries = Vec::new();
    let embedding_dim = match &layer.table {
        None => 0,
        Some(table) => {
            entries.reserve(table.entries.len());
            for entry in &table.entries {
                let embedding_crc = match &entry.embedding {
                    None => Json::Null,
                    Some(embedding) => {
                        let mut bytes = Vec::with_capacity(embedding.len() * 4);
                        for value in embedding {
                            bytes.extend_from_slice(&value.to_le_bytes());
                        }
                        Json::Str(crc32(&bytes).to_string())
                    }
                };
                entries.push(Json::obj(vec![
                    ("objectId", int(entry.object_id as u64)),
                    ("label", Json::Str(entry.label.clone())),
                    (
                        "anchor",
                        Json::Arr(entry.anchor.iter().map(|v| num(*v as f64)).collect()),
                    ),
                    // The decoded dynamics values, not merely their presence: a summary
                    // that said only whether the record was there would pass a decoder
                    // that read the nine floats and exposed zeros.
                    (
                        "dynamics",
                        match &entry.dynamics {
                            None => Json::Null,
                            Some((velocity, angular, acceleration)) => Json::obj(vec![
                                (
                                    "velocity",
                                    Json::Arr(velocity.iter().map(|v| num(*v as f64)).collect()),
                                ),
                                (
                                    "angularVelocity",
                                    Json::Arr(angular.iter().map(|v| num(*v as f64)).collect()),
                                ),
                                (
                                    "acceleration",
                                    Json::Arr(
                                        acceleration.iter().map(|v| num(*v as f64)).collect(),
                                    ),
                                ),
                            ]),
                        },
                    ),
                    ("hasEmbedding", Json::Bool(entry.embedding.is_some())),
                    ("embeddingCrc", embedding_crc),
                ]));
            }
            table.embedding_dim
        }
    };

    let order = stable_order(gaussians);
    let duration = header.duration_sec.max(0.0);
    let mut states = Vec::with_capacity(3);
    for t in [0.0, 0.5 * duration, (duration - 1e-6).max(0.0)] {
        let state = canonical_state_at(gaussians, layer, t, header.cutoff)?;

        let mut row_for_index = vec![None; gaussians.count()];
        for (row, index) in state.indices.iter().enumerate() {
            row_for_index[*index] = Some(row);
        }
        let sample_rows: Vec<usize> = order
            .iter()
            .filter_map(|index| row_for_index[*index])
            .take(SAMPLE)
            .collect();
        let rows = |values: &[f64], width: usize| {
            Json::Arr(
                sample_rows
                    .iter()
                    .map(|row| {
                        Json::Arr(
                            (0..width)
                                .map(|axis| num(values[row * width + axis]))
                                .collect(),
                        )
                    })
                    .collect(),
            )
        };
        let position_sum: Vec<Json> = (0..3)
            .map(|axis| {
                num((0..state.indices.len())
                    .map(|row| state.centers[row * 3 + axis])
                    .sum())
            })
            .collect();
        let opacity_sum: f64 = state.opacity.iter().sum();
        states.push(Json::obj(vec![
            ("t", num(t)),
            ("liveCount", int(state.indices.len() as u64)),
            (
                "sample",
                Json::obj(vec![
                    ("positions", rows(&state.centers, 3)),
                    ("orientations", rows(&state.orientations, 4)),
                    (
                        "objectIds",
                        Json::Arr(
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
                Json::obj(vec![
                    ("positionSum", Json::Arr(position_sum)),
                    ("opacitySum", num(opacity_sum)),
                ]),
            ),
        ]));
    }

    Ok(Json::obj(vec![
        (
            "objects",
            Json::obj(vec![
                ("embeddingDim", Json::Num(embedding_dim as f64)),
                ("table", Json::Arr(entries)),
                ("tracks", Json::Arr(tracks)),
            ]),
        ),
        ("states", Json::Arr(states)),
    ])
    .to_json())
}
