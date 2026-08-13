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

use std::cmp::Ordering;
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

/// How many decimals the canonical form keeps. Matches `FLOAT_DECIMALS` in `canonical.py`.
const CANONICAL_DECIMALS: usize = 6;

/// A comparison key: rounded like the summary, with infinity kept as infinity so every
/// language orders never-fading gaussians identically.
///
/// Rendered and parsed back rather than scaled and rounded, because the two disagree on
/// exact halves and a sort key may not. `f64::round` goes half away from zero, so the f32
/// `0.5078125` — a dyadic value that lands exactly on the boundary — becomes `0.507813`
/// here while `canonical.py`, C++ and Swift all render `0.507812`. Two gaussians straddling
/// such a value would then sort one way in the core and the other way in the reference, and
/// the sampled `states` they produce would disagree even though both decoded correctly.
fn sortable(value: f32) -> f64 {
    let v = value as f64;
    if v.is_nan() {
        return f64::INFINITY;
    }
    if v.is_infinite() {
        return v;
    }
    // Scaled and rounded half to even rather than rendered and parsed. The rendering is
    // the canonical definition, and this agrees with it for every f32 — the input is f32,
    // so the value times a million needs at most thirteen significant digits and stays
    // inside what f64 represents exactly, which is what would otherwise make double
    // rounding disagree. `sortable_matches_the_rendered_form` checks that across the whole
    // f32 bit space. Cheap matters because the comparison below calls this per field per
    // comparison rather than materializing a key.
    let scale = 10f64.powi(CANONICAL_DECIMALS as i32);
    (v * scale).round_ties_even() / scale
}

/// Content order: derived from decoded values alone, never from decode order.
///
/// Gaussians may be reordered freely by an encoder and readers must not rely on their
/// order, so a summary that did would ask two correct decoders to disagree. Membership
/// joins the key after the harmonics, followed by the exact decoded floats as a final
/// tie-breaker. Rows that did not tie keep their established order, while two rows that
/// also tie exactly are interchangeable in every value the summary composes or emits.
pub fn stable_order(gaussians: &GaussianSet) -> Vec<usize> {
    let mut order: Vec<usize> = (0..gaussians.count()).collect();
    order.sort_by(|&a, &b| compare_rows(gaussians, a, b));
    order
}

/// The key, compared field by field instead of built.
///
/// Materializing it is the obvious shape and the expensive one: a row is twenty-one
/// rounded scalars plus the harmonics, so a million gaussians at degree 3 is around five
/// hundred megabytes of keys — allocated *after* the whole population is already resident,
/// on a call whose entire job is to summarize it. Comparing on demand allocates the index
/// vector and nothing else. It costs repeated rounding, which is why `sortable` is
/// arithmetic rather than formatting.
fn compare_rows(gaussians: &GaussianSet, a: usize, b: usize) -> Ordering {
    fn cmp(x: f64, y: f64) -> Ordering {
        x.partial_cmp(&y)
            .expect("no key value is NaN; see `sortable`")
    }

    for (arr, width) in [
        (&gaussians.positions, 3usize),
        (&gaussians.scales, 3),
        (&gaussians.rotations, 4),
        (&gaussians.colors, 4),
        (&gaussians.motions, 3),
    ] {
        for k in 0..width {
            let ord = cmp(sortable(arr[a * width + k]), sortable(arr[b * width + k]));
            if ord != Ordering::Equal {
                return ord;
            }
        }
    }
    for arr in [
        &gaussians.mu_t,
        &gaussians.sigma_t,
        &gaussians.win_lo,
        &gaussians.win_hi,
    ] {
        let ord = cmp(sortable(arr[a]), sortable(arr[b]));
        if ord != Ordering::Equal {
            return ord;
        }
    }
    // Compared as the bytes they are. They were widened to f64 when the key was built, and
    // widening is order-preserving, so this is the same comparison without the conversion.
    if let Some(sh) = &gaussians.sh {
        let sh_width = gaussians.sh_coefficients * 3;
        for k in 0..sh_width {
            let ord = sh[a * sh_width + k].cmp(&sh[b * sh_width + k]);
            if ord != Ordering::Equal {
                return ord;
            }
        }
    }
    // Membership stays after the harmonics, preserving the existing order for rows that
    // never tied on the rounded key.
    if let Some(object_ids) = &gaussians.object_id {
        let ord = object_ids[a].cmp(&object_ids[b]);
        if ord != Ordering::Equal {
            return ord;
        }
    }

    // A rounded tie is not necessarily an emitted-state tie: sub-micro motion can compose
    // into visibly different centres at a later probe. Compare the same decoded floats at
    // full f32 precision only after the existing rounded/SH/membership key has tied.
    for (arr, width) in [
        (&gaussians.positions, 3usize),
        (&gaussians.scales, 3),
        (&gaussians.rotations, 4),
        (&gaussians.colors, 4),
        (&gaussians.motions, 3),
    ] {
        for k in 0..width {
            let ord = exact_cmp(arr[a * width + k], arr[b * width + k]);
            if ord != Ordering::Equal {
                return ord;
            }
        }
    }
    for arr in [
        &gaussians.mu_t,
        &gaussians.sigma_t,
        &gaussians.win_lo,
        &gaussians.win_hi,
    ] {
        let ord = exact_cmp(arr[a], arr[b]);
        if ord != Ordering::Equal {
            return ord;
        }
    }
    Ordering::Equal
}

/// Total ordering for exact decoded floats after the rounded key ties.
///
/// Signed zeros are equivalent because the canonical form never exposes their sign. All
/// NaNs are likewise equivalent because they emit `null`, but they sort after +infinity so
/// their unordered comparison cannot fall through to stable decoded order.
fn exact_cmp(a: f32, b: f32) -> Ordering {
    fn class(value: f32) -> u8 {
        if value.is_nan() {
            3
        } else if value == f32::NEG_INFINITY {
            0
        } else if value == f32::INFINITY {
            2
        } else {
            1
        }
    }
    let ord = class(a).cmp(&class(b));
    if ord != Ordering::Equal || class(a) != 1 {
        return ord;
    }
    a.partial_cmp(&b)
        .expect("finite exact canonical keys are ordered")
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
/// The two canonical members an object-layer file adds to a scene summary, rendered.
///
/// Returned separately rather than as one document because they sit at the *root* of the
/// summary beside `sample`, `aggregate` and the rest — a binding places each under its own
/// key. Handing back `{"objects":…,"states":…}` would make every binding cut the braces off
/// and splice the text, which is the kind of string surgery a canonical output should never
/// ask for. Both are empty when the file carries neither object records nor membership.
pub struct CanonicalParts {
    /// The `objects` value: embedding dimension, table entries, tracks with sampled poses.
    pub objects: String,
    /// The `states` value: post-composition gaussian state at each probe time.
    pub states: String,
}

pub fn canonical_parts(
    header: &Header,
    gaussians: &GaussianSet,
    layer: &ObjectLayer,
) -> Result<CanonicalParts> {
    if layer.is_empty() && gaussians.object_id.is_none() {
        return Ok(CanonicalParts {
            objects: String::new(),
            states: String::new(),
        });
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
        let mut sample_rows = Vec::with_capacity(SAMPLE.min(state.indices.len()));
        let mut position_sum = [0.0f64; 3];
        let mut opacity_sum = 0.0f64;
        for index in &order {
            let Some(row) = row_for_index[*index] else {
                continue;
            };
            if sample_rows.len() < SAMPLE {
                sample_rows.push(row);
            }
            for (axis, sum) in position_sum.iter_mut().enumerate() {
                *sum += state.centers[row * 3 + axis];
            }
            opacity_sum += state.opacity[row];
        }
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
                    (
                        "positionSum",
                        Json::Arr(position_sum.iter().map(|value| num(*value)).collect()),
                    ),
                    ("opacitySum", num(opacity_sum)),
                ]),
            ),
        ]));
    }

    Ok(CanonicalParts {
        objects: Json::obj(vec![
            ("embeddingDim", Json::Num(embedding_dim as f64)),
            ("table", Json::Arr(entries)),
            ("tracks", Json::Arr(tracks)),
        ])
        .to_json(),
        states: Json::Arr(states).to_json(),
    })
}

#[cfg(test)]
mod tests {
    use super::sortable;

    /// The canonical rounding rule is render-then-parse, and exact halves are where the
    /// alternatives part company.
    ///
    /// Each value here is dyadic, so `v * 1e6` is exactly representable and lands on `.5`:
    /// scaling and calling `f64::round` rounds it away from zero, while every reference
    /// implementation — Python's `round`, C++'s `strtod` of a rendered string, Swift's
    /// `%.6f` — renders half to even. A sort key that disagreed with them would reorder
    /// the sampled states for a file no decoder got wrong.
    #[test]
    fn exact_halves_round_the_way_the_reference_does() {
        assert_eq!(sortable(0.5078125), 0.507812);
        assert_eq!(sortable(0.0078125), 0.007812);
        assert_eq!(sortable(-0.5078125), -0.507812);
        // Not a tie: nothing to decide, and both rules agree.
        assert_eq!(sortable(1.015625), 1.015625);
    }

    /// The arithmetic shortcut agrees with the canonical rendered form, everywhere.
    ///
    /// `sortable` scales and rounds half to even instead of rendering to six decimals and
    /// parsing back, because the comparison calls it per field per comparison rather than
    /// building a key once. The rendered form is still the definition, so the shortcut has
    /// to match it — not approximately, and not only on the values a corpus happens to
    /// hold. This sweeps the f32 bit space with a prime stride, so the samples are not
    /// aligned to exponent boundaries, and covers both sides of the magnitude where
    /// scaling by a million could start losing digits.
    #[test]
    fn sortable_matches_the_rendered_form() {
        fn rendered(v: f64) -> f64 {
            format!("{v:.*}", super::CANONICAL_DECIMALS)
                .parse()
                .unwrap_or(v)
        }

        let mut checked = 0u64;
        let mut bits: u32 = 0;
        while bits < u32::MAX - 4099 {
            let v = f32::from_bits(bits);
            if v.is_finite() {
                assert_eq!(
                    sortable(v),
                    rendered(v as f64),
                    "the shortcut and the canonical rendering disagree at {v:e}"
                );
                checked += 1;
            }
            bits += 4099;
        }
        assert!(checked > 500_000, "the sweep covered only {checked} values");
    }

    #[test]
    fn undecodable_values_still_order_identically() {
        assert_eq!(sortable(f32::NAN), f64::INFINITY);
        assert_eq!(sortable(f32::INFINITY), f64::INFINITY);
        assert_eq!(sortable(f32::NEG_INFINITY), f64::NEG_INFINITY);
    }
}
