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

/// An embedded track. Absent scenes hold `None`, never an empty track.
#[derive(Debug, Clone, Default)]
pub struct AudioTrack {
    pub codec: String,
    pub start_sec: f64,
    pub data: Vec<u8>,
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
