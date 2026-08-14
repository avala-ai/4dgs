// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! What the provenance records mean once they have been read.
//!
//! [`crate::records`] knows the bytes; this module knows the arithmetic and the rules
//! that span more than one record — that names are unique, that a sensor posed against a
//! rig names a rig the file actually carries, that an anchor anchors a frame the file
//! actually defines, and how a pose is recovered between two trajectory samples.
//!
//! The interpolation rules here are the specification's, executable. Section 5.15.4
//! states them in prose because a specification has to; a reference implementation exists
//! so that "shortest-arc slerp" and "clamped, never extrapolated" have exactly one
//! meaning rather than one per reader.
//!
//! Nothing here is required to decode gaussians. A consumer that only wants geometry
//! never touches a [`Provenance`], and a file that carries none produces an empty one —
//! which is a value, not an error.

use std::collections::HashSet;

use crate::error::{Error, Result};
use crate::records::{
    CoordinateFrame, GeodeticAnchor, RigTrajectory, SensorCalibration, POSE_TO_RIG, POSE_TO_SCENE,
    TRAJECTORY_LINEAR, TRAJECTORY_STEP,
};

/// Metres per unit for each registry length unit, or `None` for one this build does not
/// know. An unrecognized registry value is not a malformed one.
pub fn length_unit_metres(unit: u8) -> Option<f64> {
    match unit {
        1 => Some(1.0),
        2 => Some(0.01),
        3 => Some(0.001),
        4 => Some(1000.0),
        5 => Some(0.3048),
        6 => Some(0.0254),
        _ => None,
    }
}

/// A rigid transform: rotate by a unit quaternion, then translate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pose {
    /// Unit quaternion, `xyzw`.
    pub rotation: [f64; 4],
    pub translation: [f64; 3],
}

impl Pose {
    /// `R(rotation) * point + translation`, the direction section 5.15.3 states.
    pub fn apply(&self, point: [f64; 3]) -> [f64; 3] {
        let [x, y, z, w] = self.rotation;
        let [px, py, pz] = point;
        // q * (0, p) * q^-1, expanded. Two cross products rather than a 3x3 build: fewer
        // operations and no matrix whose storage order can be got wrong.
        let tx = 2.0 * (y * pz - z * py);
        let ty = 2.0 * (z * px - x * pz);
        let tz = 2.0 * (x * py - y * px);
        [
            px + w * tx + (y * tz - z * ty) + self.translation[0],
            py + w * ty + (z * tx - x * tz) + self.translation[1],
            pz + w * tz + (x * ty - y * tx) + self.translation[2],
        ]
    }

    /// `self ∘ inner`: apply `inner` first, then `self`.
    ///
    /// This is what turns a sensor posed against a rig into a sensor posed in the scene,
    /// once the rig's pose at the instant of interest is known.
    pub fn compose(&self, inner: &Pose) -> Pose {
        Pose {
            rotation: quaternion_multiply(self.rotation, inner.rotation),
            translation: self.apply(inner.translation),
        }
    }
}

pub(crate) fn quaternion_multiply(a: [f64; 4], b: [f64; 4]) -> [f64; 4] {
    let [ax, ay, az, aw] = a;
    let [bx, by, bz, bw] = b;
    [
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]
}

fn normalize(q: [f64; 4]) -> Result<[f64; 4]> {
    // Scaled before squaring: a component near the top of the double range squares to
    // infinity, so the naive norm refuses a quaternion that has a perfectly good
    // direction and that every other reader renormalizes. Dividing by the largest
    // magnitude first makes the sum safe and leaves the direction untouched.
    let scale = q.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    if !scale.is_finite() || scale == 0.0 {
        return Err(Error::Malformed(format!(
            "a quaternion with scale {scale} has no direction"
        )));
    }
    let scaled = [q[0] / scale, q[1] / scale, q[2] / scale, q[3] / scale];
    let norm = scaled.iter().map(|v| v * v).sum::<f64>().sqrt();
    if !norm.is_finite() || norm == 0.0 {
        return Err(Error::Malformed(format!(
            "a quaternion with norm {norm} has no direction"
        )));
    }
    Ok([
        scaled[0] / norm,
        scaled[1] / norm,
        scaled[2] / norm,
        scaled[3] / norm,
    ])
}

/// Shortest-arc spherical interpolation between two unit quaternions.
///
/// The sign flip is a correctness rule, not an optimization: `q` and `−q` are the same
/// rotation, so without it a trajectory takes the long way round between two poses a
/// degree apart — for one interval, once per sign flip, which is exactly the kind of
/// defect that survives a demo and shows up in someone's analysis.
pub fn slerp(a: [f64; 4], b: [f64; 4], u: f64) -> Result<[f64; 4]> {
    let a = normalize(a)?;
    let mut b = normalize(b)?;
    let mut dot = (0..4).map(|i| a[i] * b[i]).sum::<f64>();
    if dot < 0.0 {
        b = [-b[0], -b[1], -b[2], -b[3]];
        dot = -dot;
    }
    if dot > 0.9995 {
        // Near-parallel: the great-circle formula divides by a sine approaching zero, and
        // a straight lerp is within float noise of it here.
        let mut out = [0.0; 4];
        for i in 0..4 {
            out[i] = a[i] + u * (b[i] - a[i]);
        }
        return normalize(out);
    }
    let theta = dot.clamp(-1.0, 1.0).acos();
    let sin_theta = theta.sin();
    let wa = ((1.0 - u) * theta).sin() / sin_theta;
    let wb = (u * theta).sin() / sin_theta;
    let mut out = [0.0; 4];
    for i in 0..4 {
        out[i] = wa * a[i] + wb * b[i];
    }
    Ok(out)
}

/// A record [`pose_at`] can sample: time-stamped rigid poses with an interpolation mode.
///
/// Both [`RigTrajectory`] (a capture platform) and the object layer's
/// [`crate::records::ObjectTrack`] (a scene object) implement this, which is the point —
/// the clamp-and-slerp of [`pose_at`] is written once and both records share it, rather
/// than each carrying its own interpolation that could drift from the other. `name` is
/// what a refusal message uses.
pub trait PoseSampled {
    fn name(&self) -> &str;
    fn interpolation(&self) -> u8;
    fn sample_count(&self) -> usize;
    fn time(&self, i: usize) -> f64;
    fn rotation(&self, i: usize) -> [f64; 4];
    fn translation(&self, i: usize) -> [f64; 3];
}

impl PoseSampled for RigTrajectory {
    fn name(&self) -> &str {
        &self.name
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

fn sample<T: PoseSampled + ?Sized>(track: &T, i: usize) -> Result<Pose> {
    Ok(Pose {
        rotation: normalize(track.rotation(i))?,
        translation: track.translation(i),
    })
}

/// The normalized position of `t` between finite, strictly increasing `a` and `b`.
///
/// Scaling is necessary when the mathematical span is finite but cannot be represented
/// as an `f64`, for example `-1e308..1e308`. Keeping this next to [`pose_at`] also gives
/// materialized and range-sampled tracks one interpolation formula.
pub(crate) fn interpolation_fraction(t: f64, a: f64, b: f64) -> f64 {
    let span = b - a;
    if span.is_finite() {
        return (t - a) / span;
    }
    let scale = a.abs().max(b.abs());
    ((t / scale) - (a / scale)) / ((b / scale) - (a / scale))
}

/// Interpolate two finite values without overflowing their difference across zero.
pub(crate) fn finite_lerp(a: f64, b: f64, u: f64) -> f64 {
    if (a < 0.0) == (b < 0.0) {
        a + u * (b - a)
    } else {
        (1.0 - u) * a + u * b
    }
}

pub(crate) fn check_scene_time(t: f64) -> Result<()> {
    if t.is_finite() {
        Ok(())
    } else {
        Err(Error::InvalidInput(format!(
            "scene query time is {t}; expected a finite value"
        )))
    }
}

/// The pose at scene time `t`, or `None` when the record has no samples.
///
/// Outside the sample range the pose is **clamped**, never extrapolated: before the first
/// sample it is the first sample, at or after the last it is the last. Extrapolating
/// produces a platform that accelerates away from the scene at the ends of the clip,
/// which is never what the capture did.
pub fn pose_at<T: PoseSampled + ?Sized>(track: &T, t: f64) -> Result<Option<Pose>> {
    check_scene_time(t)?;
    let n = track.sample_count();
    if n == 0 {
        return Ok(None);
    }
    if t <= track.time(0) {
        return Ok(Some(sample(track, 0)?));
    }
    if t >= track.time(n - 1) {
        return Ok(Some(sample(track, n - 1)?));
    }

    // Times are strictly increasing (enforced at parse), so a bisection is exact.
    let (mut lo, mut hi) = (0usize, n - 1);
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if track.time(mid) <= t {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    if track.interpolation() == TRAJECTORY_STEP {
        return Ok(Some(sample(track, lo)?));
    }
    if track.interpolation() != TRAJECTORY_LINEAR {
        // Unknown-but-legal, not malformed — but there is no defensible way to invent the
        // rule, and picking linear would silently answer a question the file asked
        // differently. Naming it is the whole obligation.
        return Err(Error::Malformed(format!(
            "trajectory {:?} uses interpolation {}, which this build does not implement",
            track.name(),
            track.interpolation()
        )));
    }

    let u = interpolation_fraction(t, track.time(lo), track.time(lo + 1));
    let a = sample(track, lo)?;
    let b = sample(track, lo + 1)?;
    let mut translation = [0.0; 3];
    for (i, slot) in translation.iter_mut().enumerate() {
        *slot = finite_lerp(a.translation[i], b.translation[i], u);
    }
    Ok(Some(Pose {
        rotation: slerp(a.rotation, b.rotation, u)?,
        translation,
    }))
}

/// Every provenance record a file carried, and the rules that span them.
///
/// An empty instance is what a scene with no provenance produces. That is a value and
/// never an error: absence costs nothing and means nothing is claimed.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Provenance {
    pub frames: Vec<CoordinateFrame>,
    pub sensors: Vec<SensorCalibration>,
    pub trajectories: Vec<RigTrajectory>,
    pub anchors: Vec<GeodeticAnchor>,
}

fn check_unique_record_names<T>(
    values: &[T],
    label: &str,
    section: &str,
    name: impl Fn(&T) -> &str,
) -> Result<()> {
    // A set rather than a scan of everything already seen. The record-count ceiling bounds
    // how many of these there can be, which bounds memory; it only bounds the CPU spent on
    // them if the work per record is constant, and rescanning the prefix is not.
    let mut seen: HashSet<&str> = HashSet::new();
    seen.try_reserve(values.len()).map_err(|error| {
        Error::UnsupportedOperation(format!(
            "the {label} name set could not reserve {} entries: {error}",
            values.len()
        ))
    })?;
    for value in values {
        let value_name = name(value);
        if !seen.insert(value_name) {
            return Err(Error::Malformed(format!(
                "two {label} records are named {value_name:?}; these records are referred to by name and nothing else (section {section})"
            )));
        }
    }
    Ok(())
}

impl Provenance {
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
            && self.sensors.is_empty()
            && self.trajectories.is_empty()
            && self.anchors.is_empty()
    }

    /// The file's own scene frame — the one named `""` — or `None`.
    pub fn frame(&self) -> Option<&CoordinateFrame> {
        self.frame_named("")
    }

    pub fn frame_named(&self, name: &str) -> Option<&CoordinateFrame> {
        self.frames.iter().find(|f| f.name == name)
    }

    pub fn sensor(&self, name: &str) -> Option<&SensorCalibration> {
        self.sensors.iter().find(|s| s.name == name)
    }

    pub fn trajectory(&self, name: &str) -> Option<&RigTrajectory> {
        self.trajectories.iter().find(|t| t.name == name)
    }

    pub fn anchor(&self, frame_name: &str) -> Option<&GeodeticAnchor> {
        self.anchors.iter().find(|a| a.frame_name == frame_name)
    }

    /// One unit of a frame in metres, or `None` when the file does not say.
    ///
    /// `metres_per_unit` is the authority where it and `length_unit` disagree (spec
    /// section 5.15.2): the number is what a consumer computes with, the enum is what it
    /// prints. A writer MUST make them agree and a validator reports a disagreement as an
    /// error, so this rule only ever runs on a file that is already non-conforming — it
    /// exists so that two consumers handed that file still produce one measurement rather
    /// than two.
    pub fn metres_per_unit(&self, frame_name: &str) -> Option<f64> {
        let frame = self.frame_named(frame_name)?;
        if frame.metres_per_unit > 0.0 {
            return Some(frame.metres_per_unit);
        }
        length_unit_metres(frame.length_unit)
    }

    /// A sensor's pose in the scene frame at scene time `t`.
    ///
    /// For a sensor posed against the scene this is its extrinsic and `t` is ignored. For
    /// one posed against a rig it is the rig's pose at `t` composed with the extrinsic,
    /// which is the whole reason `pose_reference` exists: the two cases have different
    /// answers and nothing in the numbers distinguishes them.
    pub fn sensor_pose_at(&self, name: &str, t: f64) -> Result<Option<Pose>> {
        let Some(sensor) = self.sensor(name) else {
            return Ok(None);
        };
        let extrinsic = Pose {
            rotation: normalize(sensor.rotation)?,
            translation: sensor.translation,
        };
        if sensor.pose_reference != POSE_TO_RIG {
            return Ok(Some(extrinsic));
        }
        let trajectory = self.trajectory(&sensor.rig_name).ok_or_else(|| {
            Error::Malformed(format!(
                "sensor {:?} is posed against rig {:?}, which this file does not carry",
                sensor.name, sensor.rig_name
            ))
        })?;
        Ok(match pose_at(trajectory, t)? {
            None => Some(extrinsic),
            Some(rig) => Some(rig.compose(&extrinsic)),
        })
    }

    /// The rules no single record can enforce on its own.
    ///
    /// All refusals rather than repairs, for the reason section 5.4 gives about window
    /// indices. A duplicate name makes every reference to that name a coin toss performed
    /// silently; a rig reference into a file that carries no such rig, resolved by falling
    /// back to a scene-frame pose, would put every sensor on that rig at the origin —
    /// plausible, wrong, and quiet; and an anchor naming a frame the file never defined
    /// would put a whole scene somewhere on Earth no producer ever claimed.
    pub fn check(&self) -> Result<()> {
        self.check_with(false)
    }

    /// The same rules, with the reference checks deferred when the file was cut.
    ///
    /// `truncated` defers only what a later record could still satisfy: a sensor naming
    /// a rig, an anchor naming a frame. A duplicate name among records that are already
    /// complete is not one of them — no byte after the cut can make two
    /// `SensorCalibration` records with one name unambiguous — so those still refuse.
    pub fn check_with(&self, truncated: bool) -> Result<()> {
        check_unique_record_names(&self.frames, "CoordinateFrame", "5.15.2", |value| {
            &value.name
        })?;
        check_unique_record_names(&self.sensors, "SensorCalibration", "5.15.3", |value| {
            &value.name
        })?;
        check_unique_record_names(&self.trajectories, "RigTrajectory", "5.15.4", |value| {
            &value.name
        })?;
        check_unique_record_names(&self.anchors, "GeodeticAnchor", "5.15.5", |value| {
            &value.frame_name
        })?;

        // The registry defines two pose references and no more. An unrecognized value is
        // not a future extension a reader may ignore: it says the extrinsic maps into some
        // frame this build cannot name, and treating it as scene-relative puts the sensor
        // somewhere plausible and wrong.
        for sensor in &self.sensors {
            if sensor.pose_reference != POSE_TO_SCENE && sensor.pose_reference != POSE_TO_RIG {
                return Err(Error::Malformed(format!(
                    "sensor {:?} declares pose_reference {}; the registry defines 0 (scene) \
                     and 1 (rig)",
                    sensor.name, sensor.pose_reference
                )));
            }
        }

        // Past here the rules resolve a reference into another record. A file cut before
        // that record arrived is missing the target rather than contradicting itself.
        if truncated {
            return Ok(());
        }

        for sensor in &self.sensors {
            // A zero-sample trajectory "MUST be read as though the record were absent"
            // (section 5.15.4), so a rig-relative sensor naming one names a rig this
            // file does not carry — the same refusal, reached one step later. Composing
            // it as identity would place every sensor on that rig at the rig origin:
            // plausible, wrong, and silent.
            if sensor.pose_reference == POSE_TO_RIG
                && !self
                    .trajectories
                    .iter()
                    .any(|t| t.name == sensor.rig_name && t.sample_count() > 0)
            {
                return Err(Error::Malformed(format!(
                    "sensor {:?} is posed against rig {:?}, which this file does not carry \
                     (section 5.15.3)",
                    sensor.name, sensor.rig_name
                )));
            }
        }

        for anchor in &self.anchors {
            if !self.frames.iter().any(|f| f.name == anchor.frame_name) {
                return Err(Error::Malformed(format!(
                    "a GeodeticAnchor anchors frame {:?}, which this file does not define; an \
                     anchor for a frame nobody declared is a latitude attached to nothing \
                     (section 5.15.5)",
                    anchor.frame_name
                )));
            }
        }
        Ok(())
    }
}

// --------------------------------------------------------------------------
// Canonical provenance JSON (shared by Rust conformance and the C ABI)
// --------------------------------------------------------------------------
//
// The statement two implementations are diffed on for the provenance family, computed here
// so C++ and Swift — which bind the decoder through the C ABI rather than reimplementing
// slerp — emit the same object the Python and Rust runners do. Representation matches the
// shared canonical: six-decimal floats, integers as strings, sorted object keys, and the
// probe poses that exercise clamp and shortest-arc slerp rather than only the stored samples.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt::Write as _;

/// Decimal places every float in the provenance summary carries, matching the shared
/// canonical (`FLOAT_DECIMALS` in the conformance crate and `canonical.py`).
const PROVENANCE_JSON_DECIMALS: usize = 6;

/// How many trajectory samples appear in full. A long capture would otherwise bloat the
/// summary without proving anything the probes and the sample-count field do not.
const RIG_SAMPLES: usize = 4;

/// A JSON value whose objects are sorted by key. Private mirror of the conformance
/// emitter — the core does not depend on its own test crate.
///
/// Shared with [`crate::object_layer`], which emits the same canonical shapes for the
/// object layer: one writer, one rounding rule, so two families cannot disagree about how
/// a number is spelled.
pub(crate) enum Json {
    Null,
    Bool(bool),
    Num(f64),
    ExactNum(String),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub(crate) fn obj(pairs: Vec<(&str, Json)>) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Num(v) => push_canonical_decimal(out, *v),
            Json::ExactNum(token) => out.push_str(token),
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

    pub(crate) fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }
}

/// Append one finite value at the canonical decimal precision, without the sign of a zero.
///
/// The canonical form's first rule is that a zero is `0.0` and never `-0.0` — the sign
/// records which side of zero the arithmetic landed on, which is a property of the platform
/// rather than of the scene. `{:.6}` keeps it: `-4e-7` renders as `-0.000000`, and a
/// composed centre at the noise floor is exactly the value that lands there.
///
/// This is the one place it can be erased for the core's canonical members, and erasing it
/// here also settles it for the C ABI's consumers: `fourdgs_scene_objects_json` and
/// `fourdgs_scene_object_states_json` hand these strings straight to the C++ and Swift
/// bindings, which splice them into their summaries verbatim, so a sign left here would
/// have been three SDKs' output rather than one.
///
/// A rendered fixed-point value is a zero exactly when it holds no digit from one to nine,
/// which is cheaper and less fragile than comparing against a spelled-out `"-0.000000"`
/// that would silently stop matching if the precision ever changed.
fn push_canonical_decimal(out: &mut String, value: f64) {
    let start = out.len();
    let _ = write!(out, "{value:.*}", PROVENANCE_JSON_DECIMALS);
    let rendered = &out[start..];
    if rendered.starts_with('-') && !rendered.bytes().any(|byte| (b'1'..=b'9').contains(&byte)) {
        out.remove(start);
    }
}

#[derive(Default)]
struct DecimalAccumulator {
    negative: bool,
    // Base ten, least-significant digit first. Six canonical decimal places plus a
    // finite binary64 value do not fit a machine integer in the general case.
    digits: Vec<u8>,
}

impl DecimalAccumulator {
    fn add_fixed(&mut self, fixed: &str) {
        let (negative, magnitude) = fixed
            .strip_prefix('-')
            .map_or((false, fixed), |s| (true, s));
        let mut incoming: Vec<u8> = magnitude
            .bytes()
            .filter(|byte| byte.is_ascii_digit())
            .map(|byte| byte - b'0')
            .rev()
            .collect();
        trim_decimal_zeros(&mut incoming);
        if incoming.is_empty() {
            return;
        }
        if self.digits.is_empty() {
            self.negative = negative;
            self.digits = incoming;
            return;
        }
        if self.negative == negative {
            add_decimal_magnitude(&mut self.digits, &incoming);
            return;
        }
        match compare_decimal_magnitude(&self.digits, &incoming) {
            Ordering::Greater => subtract_decimal_magnitude(&mut self.digits, &incoming),
            Ordering::Equal => {
                self.digits.clear();
                self.negative = false;
            }
            Ordering::Less => {
                subtract_decimal_magnitude(&mut incoming, &self.digits);
                self.digits = incoming;
                self.negative = negative;
            }
        }
    }

    fn token(&self) -> String {
        let mut digits: String = if self.digits.is_empty() {
            "0".into()
        } else {
            self.digits
                .iter()
                .rev()
                .map(|digit| char::from(b'0' + digit))
                .collect()
        };
        if digits.len() <= PROVENANCE_JSON_DECIMALS {
            digits.insert_str(0, &"0".repeat(PROVENANCE_JSON_DECIMALS + 1 - digits.len()));
        }
        let split = digits.len() - PROVENANCE_JSON_DECIMALS;
        let mut fraction = digits.split_off(split);
        while fraction.len() > 1 && fraction.ends_with('0') {
            fraction.pop();
        }
        let sign = if self.negative && !self.digits.is_empty() {
            "-"
        } else {
            ""
        };
        format!("{sign}{digits}.{fraction}")
    }
}

fn trim_decimal_zeros(digits: &mut Vec<u8>) {
    while digits.last() == Some(&0) {
        digits.pop();
    }
}

fn compare_decimal_magnitude(a: &[u8], b: &[u8]) -> Ordering {
    a.len()
        .cmp(&b.len())
        .then_with(|| a.iter().rev().cmp(b.iter().rev()))
}

fn add_decimal_magnitude(accumulator: &mut Vec<u8>, addend: &[u8]) {
    let mut carry = 0u8;
    let width = accumulator.len().max(addend.len());
    accumulator.resize(width, 0);
    for (index, slot) in accumulator.iter_mut().enumerate() {
        let sum = *slot + addend.get(index).copied().unwrap_or(0) + carry;
        *slot = sum % 10;
        carry = sum / 10;
    }
    if carry != 0 {
        accumulator.push(carry);
    }
}

fn subtract_decimal_magnitude(accumulator: &mut Vec<u8>, subtrahend: &[u8]) {
    debug_assert!(compare_decimal_magnitude(accumulator, subtrahend) != Ordering::Less);
    let mut borrow = 0i8;
    for (index, slot) in accumulator.iter_mut().enumerate() {
        let value = *slot as i8 - subtrahend.get(index).copied().unwrap_or(0) as i8 - borrow;
        if value < 0 {
            *slot = (value + 10) as u8;
            borrow = 1;
        } else {
            *slot = value as u8;
            borrow = 0;
        }
    }
    debug_assert_eq!(borrow, 0);
    trim_decimal_zeros(accumulator);
}

pub(crate) fn exact_sum_token(values: impl IntoIterator<Item = f64>) -> Option<String> {
    let mut total = DecimalAccumulator::default();
    for value in values {
        if !value.is_finite() {
            return None;
        }
        total.add_fixed(&format!("{value:.PROVENANCE_JSON_DECIMALS$}"));
    }
    Some(total.token())
}

fn write_json_string(out: &mut String, s: &str) {
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
pub(crate) fn num(v: f64) -> Json {
    if v.is_finite() {
        Json::Num(v)
    } else {
        Json::Null
    }
}

/// An integer as a string, so a 64-bit value survives a JSON parser backed by doubles.
pub(crate) fn int(v: u64) -> Json {
    Json::Str(v.to_string())
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

fn pose_row(t: f64, pose: Option<&Pose>, sensor: Option<&str>) -> Json {
    let mut pairs: Vec<(&str, Json)> = vec![("time", num(t))];
    if let Some(name) = sensor {
        pairs.push(("sensor", Json::Str(name.to_string())));
    }
    match pose {
        None => {
            pairs.push(("rotation", Json::Null));
            pairs.push(("translation", Json::Null));
        }
        Some(p) => {
            pairs.push((
                "rotation",
                Json::Arr(p.rotation.iter().map(|v| num(*v)).collect()),
            ));
            pairs.push((
                "translation",
                Json::Arr(p.translation.iter().map(|v| num(*v)).collect()),
            ));
        }
    }
    Json::obj(pairs)
}

/// Canonical provenance JSON for the conformance suite, or an empty string when the
/// file carries none.
///
/// Empty is deliberate and is **not** the `audioSources` convention: a file without
/// provenance is a file the record family does not apply to, so the summary omits the key
/// rather than announcing `"provenance": null`. Callers that see an empty result should
/// omit the key.
///
/// On a non-empty file this is every readable field plus the arithmetic the fields imply —
/// probe poses on each trajectory and a composed sensor pose — so two implementations that
/// agree on every stored quaternion still have to agree on the pose halfway between them.
pub fn canonical_json(prov: &Provenance) -> Result<String> {
    if prov.is_empty() {
        return Ok(String::new());
    }

    let mut trajectories = Vec::with_capacity(prov.trajectories.len());
    for t in &prov.trajectories {
        let mut poses = Vec::new();
        for probe in probe_times(t) {
            poses.push(pose_row(probe, pose_at(t, probe)?.as_ref(), None));
        }
        trajectories.push(Json::obj(vec![
            ("name", Json::Str(t.name.clone())),
            ("interpolation", Json::Num(t.interpolation as f64)),
            ("sampleCount", int(t.sample_count() as u64)),
            (
                "samples",
                Json::Arr(
                    (0..t.sample_count().min(RIG_SAMPLES))
                        .map(|i| {
                            Json::obj(vec![
                                ("time", num(t.times[i])),
                                (
                                    "rotation",
                                    Json::Arr(t.rotations[i].iter().map(|v| num(*v)).collect()),
                                ),
                                (
                                    "translation",
                                    Json::Arr(t.translations[i].iter().map(|v| num(*v)).collect()),
                                ),
                            ])
                        })
                        .collect(),
                ),
            ),
            ("posesAt", Json::Arr(poses)),
        ]));
    }

    let mut sensor_poses = Vec::with_capacity(prov.sensors.len());
    for s in &prov.sensors {
        let probe = sensor_probe_time(prov, &s.rig_name);
        sensor_poses.push(pose_row(
            probe,
            prov.sensor_pose_at(&s.name, probe)?.as_ref(),
            Some(&s.name),
        ));
    }

    Ok(Json::obj(vec![
        (
            "frames",
            Json::Arr(
                prov.frames
                    .iter()
                    .map(|f| {
                        Json::obj(vec![
                            ("name", Json::Str(f.name.clone())),
                            ("handedness", Json::Num(f.handedness as f64)),
                            ("upAxis", Json::Num(f.up_axis as f64)),
                            ("forwardAxis", Json::Num(f.forward_axis as f64)),
                            ("lengthUnit", Json::Num(f.length_unit as f64)),
                            ("metresPerUnit", num(f.metres_per_unit)),
                            (
                                "metresPerUnitResolved",
                                match prov.metres_per_unit(&f.name) {
                                    None => Json::Null,
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
            Json::Arr(
                prov.anchors
                    .iter()
                    .map(|a| {
                        Json::obj(vec![
                            ("frameName", Json::Str(a.frame_name.clone())),
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
            Json::Arr(
                prov.sensors
                    .iter()
                    .map(|s| {
                        Json::obj(vec![
                            ("name", Json::Str(s.name.clone())),
                            ("modality", Json::Str(s.modality.clone())),
                            ("cameraModel", Json::Num(s.camera_model as f64)),
                            ("widthPx", int(s.width_px as u64)),
                            ("heightPx", int(s.height_px as u64)),
                            ("fx", num(s.fx)),
                            ("fy", num(s.fy)),
                            ("cx", num(s.cx)),
                            ("cy", num(s.cy)),
                            (
                                "distortion",
                                Json::Arr(s.distortion.iter().map(|v| num(*v)).collect()),
                            ),
                            (
                                "rotation",
                                Json::Arr(s.rotation.iter().map(|v| num(*v)).collect()),
                            ),
                            (
                                "translation",
                                Json::Arr(s.translation.iter().map(|v| num(*v)).collect()),
                            ),
                            ("poseReference", Json::Num(s.pose_reference as f64)),
                            ("rigName", Json::Str(s.rig_name.clone())),
                        ])
                    })
                    .collect(),
            ),
        ),
        ("trajectories", Json::Arr(trajectories)),
        ("sensorPosesAt", Json::Arr(sensor_poses)),
    ])
    .to_json())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::{CoordinateFrame, GeodeticAnchor, RigTrajectory, SensorCalibration};

    #[test]
    fn empty_provenance_serializes_to_empty_string() {
        let json = canonical_json(&Provenance::default()).expect("empty is always ok");
        assert_eq!(json, "");
    }

    #[test]
    fn exact_decimal_sums_keep_canonical_units() {
        assert_eq!(
            exact_sum_token([1e20, -1e20, 3.25]).as_deref(),
            Some("3.25")
        );
        assert_eq!(exact_sum_token([-0.0]).as_deref(), Some("0.0"));
        assert_eq!(exact_sum_token([f64::NAN]), None);
        let enormous = exact_sum_token([1e308; 10]).expect("finite values have a sum");
        assert!(enormous.starts_with("1000000000000000"));
        assert!(enormous.ends_with(".0"));
        assert!(enormous.len() > 309);
    }

    /// The canonical form has no signed zero, and `{:.6}` has one for every value in
    /// `(-5e-7, -0.0]`. Rendering is where it has to be erased: `exact_sum_token` already
    /// erased it, `num` cannot (a signed zero is a perfectly finite `f64`), and the same
    /// `Json` writes the object layer's members — the ones the C ABI hands to the C++ and
    /// Swift bindings verbatim.
    #[test]
    fn a_rendered_zero_is_never_signed() {
        let render = |v: f64| Json::Num(v).to_json();
        assert_eq!(render(-0.0), "0.000000");
        assert_eq!(render(-1e-9), "0.000000");
        assert_eq!(render(-4e-7), "0.000000");
        assert_eq!(render(0.0), "0.000000");
        // Only a zero loses its sign; the smallest value that survives rounding keeps it.
        assert_eq!(render(-1e-6), "-0.000001");
        assert_eq!(render(-1.5), "-1.500000");
    }

    #[test]
    fn frame_and_anchor_shape_matches_canonical() {
        let prov = Provenance {
            frames: vec![CoordinateFrame {
                name: String::new(),
                handedness: 1,
                up_axis: 2,
                forward_axis: 0,
                length_unit: 1,
                metres_per_unit: 1.0,
            }],
            anchors: vec![GeodeticAnchor {
                frame_name: String::new(),
                latitude_deg: 12.5,
                longitude_deg: -145.25,
                altitude_m: 8.75,
                heading_deg: 37.5,
            }],
            ..Provenance::default()
        };
        let json = canonical_json(&prov).expect("frame+anchor is valid");
        // Keys sorted; empty name is a legal frame name; resolved metres match the authority.
        assert!(json.contains(r#""frames":[{"forwardAxis":0.000000,"handedness":1.000000"#));
        assert!(json.contains(r#""metresPerUnitResolved":1.000000"#));
        assert!(json
            .contains(r#""anchors":[{"altitudeM":8.750000,"frameName":"","headingDeg":37.500000"#));
        assert!(json.contains(r#""sensorPosesAt":[]"#));
        assert!(json.contains(r#""sensors":[]"#));
        assert!(json.contains(r#""trajectories":[]"#));
    }

    #[test]
    fn trajectory_probes_include_clamped_ends() {
        let prov = Provenance {
            frames: vec![CoordinateFrame {
                name: String::new(),
                handedness: 1,
                up_axis: 2,
                forward_axis: 0,
                length_unit: 1,
                metres_per_unit: 1.0,
            }],
            trajectories: vec![RigTrajectory {
                name: "rig".into(),
                interpolation: TRAJECTORY_LINEAR,
                times: vec![0.0, 2.0],
                rotations: vec![[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]],
                translations: vec![[0.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
            }],
            ..Provenance::default()
        };
        let json = canonical_json(&prov).expect("trajectory is valid");
        // Five probes: first-0.5, first, mid, last, last+0.5. The ends are clamps.
        assert!(json.contains(r#""time":-0.500000"#));
        assert!(json.contains(r#""time":2.500000"#));
        assert!(json.contains(r#""sampleCount":"2""#));
        // Midpoint between the two samples.
        assert!(json.contains(r#""time":1.000000"#));
        assert!(json.contains(r#""translation":[1.000000,0.000000,0.000000]"#));
    }

    #[test]
    fn sensor_pose_composes_with_rig() {
        let prov = Provenance {
            frames: vec![CoordinateFrame {
                name: String::new(),
                handedness: 1,
                up_axis: 2,
                forward_axis: 0,
                length_unit: 1,
                metres_per_unit: 1.0,
            }],
            trajectories: vec![RigTrajectory {
                name: "rig".into(),
                interpolation: TRAJECTORY_LINEAR,
                times: vec![0.0, 2.0],
                rotations: vec![[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]],
                translations: vec![[0.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
            }],
            sensors: vec![SensorCalibration {
                name: "cam".into(),
                modality: "camera".into(),
                camera_model: 1,
                width_px: 100,
                height_px: 50,
                fx: 1.0,
                fy: 1.0,
                cx: 0.0,
                cy: 0.0,
                distortion: vec![],
                rotation: [0.0, 0.0, 0.0, 1.0],
                translation: [0.0, 0.0, 1.0],
                pose_reference: POSE_TO_RIG,
                rig_name: "rig".into(),
            }],
            ..Provenance::default()
        };
        let json = canonical_json(&prov).expect("composed sensor pose is valid");
        // Probe is the midpoint of the rig (t=1); composition is identity R + T_rig + T_sensor.
        assert!(json.contains(r#""sensor":"cam""#));
        assert!(json.contains(r#""translation":[1.000000,0.000000,1.000000]"#));
        assert!(json.contains(r#""widthPx":"100""#));
        assert!(json.contains(r#""heightPx":"50""#));
    }
}
