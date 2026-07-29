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

use crate::error::{Error, Result};
use crate::records::{
    CoordinateFrame, GeodeticAnchor, RigTrajectory, SensorCalibration, POSE_TO_RIG,
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
    let norm = q.iter().map(|v| v * v).sum::<f64>().sqrt();
    if !norm.is_finite() || norm == 0.0 {
        return Err(Error::Malformed(format!(
            "a quaternion with norm {norm} has no direction"
        )));
    }
    Ok([q[0] / norm, q[1] / norm, q[2] / norm, q[3] / norm])
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
        let groups: [(&str, Vec<&str>, &str); 4] = [
            (
                "CoordinateFrame",
                self.frames.iter().map(|f| f.name.as_str()).collect(),
                "5.15.2",
            ),
            (
                "SensorCalibration",
                self.sensors.iter().map(|s| s.name.as_str()).collect(),
                "5.15.3",
            ),
            (
                "RigTrajectory",
                self.trajectories.iter().map(|t| t.name.as_str()).collect(),
                "5.15.4",
            ),
            (
                "GeodeticAnchor",
                self.anchors.iter().map(|a| a.frame_name.as_str()).collect(),
                "5.15.5",
            ),
        ];
        for (label, names, section) in groups {
            let mut seen: Vec<&str> = Vec::with_capacity(names.len());
            for name in names {
                if seen.contains(&name) {
                    return Err(Error::Malformed(format!(
                        "two {label} records are named {name:?}; these records are referred to \
                         by name and nothing else (section {section})"
                    )));
                }
                seen.push(name);
            }
        }

        for sensor in &self.sensors {
            if sensor.pose_reference == POSE_TO_RIG
                && !self.trajectories.iter().any(|t| t.name == sensor.rig_name)
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
