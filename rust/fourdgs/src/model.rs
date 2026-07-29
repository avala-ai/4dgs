// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The in-memory scene: gaussians on one clock, plus what travels with them.
//!
//! There are no frames here and none anywhere else in the library. Each gaussian carries
//! its own temporal description, so the number alive at any instant follows from the data
//! rather than from a frame count somebody had to choose.
//!
//! Everything is structure-of-arrays and flat: that is how the data is stored, how
//! consumers want it, and what the C ABI hands across the boundary without a copy.

use crate::quantization::{support_k, DEFAULT_CUTOFF};

/// A legacy non-spatial track, retained as a read compatibility type.
#[derive(Debug, Clone, Default)]
pub struct AudioTrack {
    pub codec: String,
    pub start_sec: f64,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioSourceKeyframe {
    pub time: f64,
    pub position: [f64; 3],
    /// Unit quaternion, xyzw.
    pub rotation: [f64; 4],
}

/// One independently timed audio payload and its scene-space pose.
#[derive(Debug, Clone, PartialEq)]
pub struct AudioSource {
    pub source_id: u32,
    pub name: String,
    pub codec: String,
    pub channel_layout: String,
    pub start_sec: f64,
    pub duration_sec: f64,
    pub gain: f64,
    pub spatial: bool,
    pub loop_: bool,
    pub position: [f64; 3],
    /// Unit quaternion, xyzw.
    pub rotation: [f64; 4],
    pub keyframes: Vec<AudioSourceKeyframe>,
    pub interpolation: String,
    /// The encoded payload, verbatim and independently range-readable.
    pub data: Vec<u8>,
}

impl Default for AudioSource {
    fn default() -> Self {
        AudioSource {
            source_id: 0,
            name: String::new(),
            codec: String::new(),
            channel_layout: "mono".into(),
            start_sec: 0.0,
            duration_sec: 0.0,
            gain: 1.0,
            spatial: true,
            loop_: false,
            position: [0.0; 3],
            rotation: [0.0, 0.0, 0.0, 1.0],
            keyframes: Vec::new(),
            interpolation: "linear".into(),
            data: Vec::new(),
        }
    }
}

/// The source facts a player needs at scene time `t`.
#[derive(Debug, Clone, PartialEq)]
pub struct AudioSourceState {
    pub active: bool,
    pub local_time: f64,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
    pub gain: f64,
}

impl AudioSource {
    /// Reconstruct timing and pose. HRTF, panning, attenuation and mixing stay in the
    /// player, which combines this with its listener pose.
    pub fn state_at(&self, t: f64) -> AudioSourceState {
        let active = t >= self.start_sec && (self.loop_ || t - self.start_sec < self.duration_sec);
        let local_time = if self.loop_ && self.duration_sec > 0.0 {
            looping_local_time(t, self.start_sec, self.duration_sec)
        } else {
            (t - self.start_sec)
                .max(0.0)
                .min(self.duration_sec.max(0.0))
        };
        let (position, rotation) = self.pose_at(t);
        AudioSourceState {
            active,
            local_time,
            position,
            rotation,
            gain: self.gain,
        }
    }

    fn pose_at(&self, t: f64) -> ([f64; 3], [f64; 4]) {
        if self.keyframes.is_empty() {
            return (self.position, normalized_quaternion(self.rotation));
        }
        if t <= self.keyframes[0].time {
            let frame = &self.keyframes[0];
            return (frame.position, normalized_quaternion(frame.rotation));
        }
        let last = self.keyframes.len() - 1;
        if t >= self.keyframes[last].time {
            let frame = &self.keyframes[last];
            return (frame.position, normalized_quaternion(frame.rotation));
        }
        let high = self
            .keyframes
            .partition_point(|frame| frame.time <= t)
            .min(last);
        let a = &self.keyframes[high - 1];
        let b = &self.keyframes[high];
        if self.interpolation == "step" {
            return (a.position, normalized_quaternion(a.rotation));
        }
        let u = interpolation_fraction(t, a.time, b.time);
        let mut position = [0.0; 3];
        for (i, value) in position.iter_mut().enumerate() {
            *value = finite_lerp(a.position[i], b.position[i], u);
        }
        (position, slerp(a.rotation, b.rotation, u))
    }
}

fn interpolation_fraction(t: f64, a: f64, b: f64) -> f64 {
    let span = b - a;
    if span.is_finite() {
        return (t - a) / span;
    }
    let scale = a.abs().max(b.abs());
    (t / scale - a / scale) / (b / scale - a / scale)
}

fn finite_lerp(a: f64, b: f64, u: f64) -> f64 {
    if (a <= 0.0 && b >= 0.0) || (a >= 0.0 && b <= 0.0) {
        a * (1.0 - u) + b * u
    } else {
        a + (b - a) * u
    }
}

fn looping_local_time(t: f64, start_sec: f64, duration_sec: f64) -> f64 {
    if t <= start_sec {
        return 0.0;
    }
    let time_remainder = t.rem_euclid(duration_sec);
    let start_remainder = start_sec.rem_euclid(duration_sec);
    (time_remainder - start_remainder).rem_euclid(duration_sec)
}

fn normalized_quaternion(value: [f64; 4]) -> [f64; 4] {
    // Normalize the scaled components directly. Reconstructing the original magnitude can
    // still overflow even when every component is finite: the norm of [1e308; 4] is 2e308.
    let scale = value.iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
    if !scale.is_finite() || scale == 0.0 {
        return [0.0, 0.0, 0.0, 1.0];
    }
    let scaled = value.map(|v| v / scale);
    let length = scaled.iter().map(|v| v * v).sum::<f64>().sqrt();
    scaled.map(|v| v / length)
}

fn slerp(a: [f64; 4], b: [f64; 4], u: f64) -> [f64; 4] {
    let qa = normalized_quaternion(a);
    let mut qb = normalized_quaternion(b);
    let mut dot = qa.iter().zip(qb).map(|(x, y)| x * y).sum::<f64>();
    if dot < 0.0 {
        qb = qb.map(|v| -v);
        dot = -dot;
    }
    dot = dot.clamp(-1.0, 1.0);
    if dot > 0.9995 {
        return normalized_quaternion(std::array::from_fn(|i| qa[i] + (qb[i] - qa[i]) * u));
    }
    let theta = dot.acos();
    let sin_theta = theta.sin();
    let wa = ((1.0 - u) * theta).sin() / sin_theta;
    let wb = (u * theta).sin() / sin_theta;
    normalized_quaternion(std::array::from_fn(|i| wa * qa[i] + wb * qb[i]))
}

/// A default viewpoint and optional suggested path. Purely advisory.
pub type CameraTrajectory = crate::records::Camera;

/// Every gaussian in a scene, structure-of-arrays.
///
/// `sigma_t` may contain `+inf`, meaning the gaussian never fades inside its window. That
/// is a value, not a sentinel to be pattern-matched: it survives encode and decode as
/// infinity, and readers expose it as such.
#[derive(Debug, Clone, Default)]
pub struct GaussianSet {
    /// 3 per gaussian.
    pub positions: Vec<f32>,
    /// 3 per gaussian, linear.
    pub scales: Vec<f32>,
    /// 4 per gaussian, unit quaternion, xyzw.
    pub rotations: Vec<f32>,
    /// 4 per gaussian, linear RGB and opacity.
    pub colors: Vec<f32>,
    /// 3 per gaussian, units per second.
    pub motions: Vec<f32>,
    pub mu_t: Vec<f32>,
    /// `+inf` for a gaussian that never fades.
    pub sigma_t: Vec<f32>,
    pub win_lo: Vec<f32>,
    pub win_hi: Vec<f32>,
    /// `3 * coefficients` per gaussian, component-major, or `None`.
    pub sh: Option<Vec<u8>>,
    /// Coefficients per colour component, so `sh` rows are `3 * this` wide.
    pub sh_coefficients: usize,
    pub sh_degree: u8,
    pub source_index: Option<Vec<i64>>,
    /// Per-gaussian object membership (spec section 5.15.6), or `None` when the file
    /// carries no `object_id` stream. Exact integers, `0` = background/unassigned; the
    /// object layer's tracks transform the gaussians of a given id (see [`crate::object_layer`]).
    pub object_id: Option<Vec<u32>>,
}

/// Reconstructed state at one instant: which gaussians exist, where they are, and how
/// opaque they are. This is where decoding ends.
#[derive(Debug, Clone, Default)]
pub struct StateAt {
    pub indices: Vec<u32>,
    /// 3 per visible gaussian.
    pub centers: Vec<f32>,
    /// 1 per visible gaussian.
    pub opacity: Vec<f32>,
}

impl StateAt {
    pub fn count(&self) -> usize {
        self.indices.len()
    }
}

impl GaussianSet {
    pub fn count(&self) -> usize {
        self.mu_t.len()
    }

    pub fn is_empty(&self) -> bool {
        self.mu_t.is_empty()
    }

    /// Per-gaussian visible interval, clipped to the validity window.
    pub fn support(&self, cutoff: f64) -> (Vec<f64>, Vec<f64>) {
        let k = support_k(cutoff);
        let mut lo = Vec::with_capacity(self.count());
        let mut hi = Vec::with_capacity(self.count());
        for i in 0..self.count() {
            let sigma = self.sigma_t[i] as f64;
            let mu = self.mu_t[i] as f64;
            let half = if sigma.is_finite() {
                k * sigma
            } else {
                f64::INFINITY
            };
            lo.push((mu - half).max(self.win_lo[i] as f64));
            hi.push((mu + half).min(self.win_hi[i] as f64));
        }
        (lo, hi)
    }

    /// Min xyz then max xyz over all rest positions, or six zeros for an empty scene.
    pub fn aabb(&self) -> [f64; 6] {
        if self.is_empty() {
            return [0.0; 6];
        }
        let mut out = [
            f64::INFINITY,
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for i in 0..self.count() {
            for k in 0..3 {
                let v = self.positions[i * 3 + k] as f64;
                out[k] = out[k].min(v);
                out[3 + k] = out[3 + k].max(v);
            }
        }
        out
    }

    /// Reconstructed state at scene time `t`, exactly as the specification defines it:
    ///
    /// ```text
    /// visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
    /// marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
    /// center   =  position + motion * (t - mu_t)
    /// opacity  =  color.a * marginal
    /// ```
    ///
    /// `cutoff` is the file's own threshold, from its Header. The validity window is the
    /// format's only hard temporal gate: a gaussian outside its window does not exist at
    /// that time regardless of its marginal.
    pub fn state_at(&self, t: f64, cutoff: f64) -> StateAt {
        let mut out = StateAt::default();
        for i in 0..self.count() {
            if !(self.win_lo[i] as f64 <= t && t < self.win_hi[i] as f64) {
                continue;
            }
            let mu = self.mu_t[i] as f64;
            let sigma = self.sigma_t[i] as f64;
            let marginal = if sigma.is_finite() {
                let z = (t - mu) / sigma.max(1e-30);
                (-0.5 * z * z).exp()
            } else {
                1.0
            };
            if marginal < cutoff {
                continue;
            }
            out.indices.push(i as u32);
            for k in 0..3 {
                let p = self.positions[i * 3 + k] as f64;
                let v = self.motions[i * 3 + k] as f64;
                out.centers.push((p + v * (t - mu)) as f32);
            }
            out.opacity
                .push((self.colors[i * 4 + 3] as f64 * marginal) as f32);
        }
        out
    }

    /// `state_at` with the format's default cutoff, for a caller holding no header.
    pub fn state_at_default(&self, t: f64) -> StateAt {
        self.state_at(t, DEFAULT_CUTOFF)
    }

    /// Distinct validity windows and a per-gaussian index into them.
    ///
    /// Windows repeat heavily — one per span the scene was fitted over — so the
    /// per-gaussian cost is an index rather than two floats.
    pub fn window_table(&self) -> (Vec<(f64, f64)>, Vec<u32>) {
        let mut sorted: Vec<(f64, f64)> = (0..self.count())
            .map(|i| (self.win_lo[i] as f64, self.win_hi[i] as f64))
            .collect();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        sorted.dedup();
        let index = (0..self.count())
            .map(|i| {
                let key = (self.win_lo[i] as f64, self.win_hi[i] as f64);
                sorted
                    .binary_search_by(|w| w.partial_cmp(&key).unwrap_or(std::cmp::Ordering::Equal))
                    .expect("every window is in the table it was built from") as u32
            })
            .collect();
        (sorted, index)
    }
}
