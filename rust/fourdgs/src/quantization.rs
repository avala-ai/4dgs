// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Error-bounded quantization.
//!
//! Every attribute lands on a uniform grid whose pitch is exactly twice its declared
//! bound, so `|decoded - original| <= bound` holds by construction rather than by testing.
//! After that point the pipeline is integer-only, which is what makes decoders in
//! different languages produce identical results.
//!
//! Two attributes get a pitch that varies per gaussian, derived from a value the decoder
//! has already read, so there is no side channel. Both exist because a fixed pitch spends
//! its budget in the wrong place: a velocity error only becomes visible as displacement
//! over the span a gaussian is on screen, and the temporal term reads `(t - mu) / sigma`
//! rather than `mu` alone.

/// The Header's default marginal visibility threshold.
pub const DEFAULT_CUTOFF: f64 = 0.05;

// Velocity precision classes (spec §6.3).
const LIFE_REF: f64 = 0.5;
const LIFE_MIN_CLASS: f64 = -4.0;
const LIFE_MAX_CLASS: f64 = 2.0;
const LIFE_HALF_MIN: f64 = 0.02;
const LIFE_HALF_MAX: f64 = 2.0;

// Birth-time precision classes.
const MU_REL: f64 = 0.05;
const MU_MIN_CLASS: f64 = -10.0;

/// Half-width of a gaussian's visible support, in sigmas, for a file's own cutoff.
///
/// Reading this from the Header rather than assuming the default is not cosmetic: it feeds
/// the velocity precision class, so a decoder that assumes 0.05 decodes different
/// velocities than the encoder wrote for any file that declares something else, and
/// nothing in the file tells it that it did.
pub fn support_k(cutoff: f64) -> f64 {
    (-2.0 * cutoff.ln()).sqrt()
}

/// The grid pitches a file declares, in the domain each attribute is stored in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Steps {
    pub pos: f64,
    pub scale_log: f64,
    pub rot: f64,
    pub rgb: f64,
    pub alpha: f64,
    pub motion: f64,
    pub time: f64,
    pub sigma_log: f64,
    pub sh: u8,
}

/// The maximum deviation a decoder may observe, per attribute.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub pos: f64,
    pub scale_rel: f64,
    pub rot: f64,
    pub rgb: f64,
    pub alpha: f64,
    pub motion: f64,
    pub time: f64,
    pub sigma_rel: f64,
    pub sh: u8,
}

/// The three profiles the reference encoder offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    Fine,
    Default,
    Coarse,
}

impl Profile {
    pub fn parse(name: &str) -> Option<Profile> {
        match name {
            "fine" => Some(Profile::Fine),
            "default" => Some(Profile::Default),
            "coarse" => Some(Profile::Coarse),
            _ => None,
        }
    }
}

impl Bounds {
    /// Bounds derived from the scene's own geometry.
    ///
    /// Position tolerance is a fraction of the median gaussian radius rather than an
    /// absolute distance, so a profile means the same thing on a tabletop capture and on
    /// a city block.
    pub fn for_profile(profile: Profile, median_scale: f64) -> Bounds {
        let (k, scale_rel, rot, rgb255, time, sigma_rel, sh) = match profile {
            Profile::Fine => (0.02, 0.005, 0.0005, 0.5, 0.0005, 0.005, 0),
            Profile::Default => (0.05, 0.02, 0.002, 1.0, 0.002, 0.02, 0),
            Profile::Coarse => (0.20, 0.06, 0.006, 3.0, 0.008, 0.06, 1),
        };
        let pos = k * median_scale;
        Bounds {
            pos,
            scale_rel,
            rot,
            rgb: rgb255 / 255.0,
            alpha: rgb255 / 255.0,
            // The promise is on displacement, not velocity: this is the velocity bound
            // for a gaussian of the reference lifetime. See `life_class`.
            motion: pos / LIFE_REF,
            time,
            sigma_rel,
            sh,
        }
    }
}

impl Steps {
    /// Grid pitches: exactly twice the bound, in the appropriate domain.
    pub fn of(b: &Bounds) -> Steps {
        Steps {
            pos: 2.0 * b.pos,
            scale_log: 2.0 * b.scale_rel.ln_1p(),
            rot: 2.0 * b.rot,
            rgb: 2.0 * b.rgb,
            alpha: 2.0 * b.alpha,
            motion: 2.0 * b.motion,
            time: 2.0 * b.time,
            sigma_log: 2.0 * b.sigma_rel.ln_1p(),
            sh: std::cmp::max(1, 2 * b.sh + 1),
        }
    }
}

/// The span a velocity error is judged over: a gaussian's visible half-width, or the
/// length of its window when it never fades, clamped to the range the classes cover.
///
/// The clamp at two seconds is why the format's promise reads "over `min(lifetime, 2 s)`"
/// rather than over the whole lifetime.
pub fn life_half(
    sigma_bin: i64,
    sigma_log_step: f64,
    never_fades: bool,
    window_len: f64,
    k: f64,
) -> f64 {
    let sigma = (sigma_bin as f64 * sigma_log_step).exp();
    let half = if never_fades { window_len } else { k * sigma };
    half.clamp(LIFE_HALF_MIN, LIFE_HALF_MAX)
}

/// Velocity precision class, from the sigma bin a decoder has already read.
///
/// `ceil`, not `round`: the class's nominal lifetime has to be an upper bound on the real
/// one, or the displacement guarantee fails by up to sqrt(2).
pub fn life_class(
    sigma_bin: i64,
    sigma_log_step: f64,
    never_fades: bool,
    window_len: f64,
    k: f64,
) -> f64 {
    let half = life_half(sigma_bin, sigma_log_step, never_fades, window_len, k);
    (half / LIFE_REF)
        .log2()
        .ceil()
        .clamp(LIFE_MIN_CLASS, LIFE_MAX_CLASS)
}

/// The velocity pitch a class implies.
pub fn motion_step(class: f64, step_ref: f64) -> f64 {
    step_ref * 2.0f64.powf(-class)
}

/// Birth-time pitch: `step_ref`, refined by powers of two until it is at most `MU_REL` of
/// the gaussian's own sigma.
pub fn mu_step(sigma_bin: i64, sigma_log_step: f64, never_fades: bool, step_ref: f64) -> f64 {
    let sigma = (sigma_bin as f64 * sigma_log_step).exp();
    let target = if never_fades {
        step_ref
    } else {
        step_ref.min(MU_REL * sigma)
    };
    let class = (target / step_ref).log2().floor().clamp(MU_MIN_CLASS, 0.0);
    step_ref * 2.0f64.powf(class)
}

/// Which components a smallest-three encoding stores, given the omitted one's index.
pub const REST: [[usize; 3]; 4] = [[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]];

/// Recover one unit quaternion from its smallest-three encoding.
///
/// The omitted component is the largest in magnitude with its sign canonicalized
/// positive, so it comes back as a square root; the result is renormalized because that
/// reconstruction and the grid together can leave the quaternion slightly off unit.
pub fn dequantize_rotation(largest: i64, bins: &[i64], step: f64) -> [f32; 4] {
    let largest = largest.clamp(0, 3) as usize;
    let mut rest = [0.0f64; 3];
    for (i, slot) in rest.iter_mut().enumerate() {
        *slot = (bins[i] as f64 * step).clamp(-1.0, 1.0);
    }
    let mut out = [0.0f64; 4];
    let mut sum_sq = 0.0;
    for (i, c) in REST[largest].iter().enumerate() {
        out[*c] = rest[i];
        sum_sq += rest[i] * rest[i];
    }
    out[largest] = (1.0 - sum_sq).max(0.0).sqrt();
    let norm = (out.iter().map(|v| v * v).sum::<f64>()).sqrt();
    let norm = if norm == 0.0 { 1.0 } else { norm };
    [
        (out[0] / norm) as f32,
        (out[1] / norm) as f32,
        (out[2] / norm) as f32,
        (out[3] / norm) as f32,
    ]
}

/// The forward smallest-three transform: `(largest index, three residual bins)`.
pub fn quantize_rotation(quat: [f64; 4], step: f64) -> (i64, [i64; 3]) {
    let norm = quat.iter().map(|v| v * v).sum::<f64>().sqrt().max(1e-30);
    let q = [
        quat[0] / norm,
        quat[1] / norm,
        quat[2] / norm,
        quat[3] / norm,
    ];
    let mut largest = 0usize;
    for i in 1..4 {
        if q[i].abs() > q[largest].abs() {
            largest = i;
        }
    }
    let sign = if q[largest] < 0.0 { -1.0 } else { 1.0 };
    let mut bins = [0i64; 3];
    for (i, c) in REST[largest].iter().enumerate() {
        bins[i] = ((q[*c] * sign) / step).round() as i64;
    }
    (largest as i64, bins)
}

/// Undo the reversible colour transform: the stream stores `(g, r - g, b - g)`.
///
/// Exact in the integer domain, so it changes the compressed size and never the bound.
#[inline]
pub fn rct_inverse(bins: &[i64]) -> [i64; 3] {
    let g = bins[0];
    [bins[1] + g, g, bins[2] + g]
}

/// The forward transform, for the encoder.
#[inline]
pub fn rct_forward(rgb: [i64; 3]) -> [i64; 3] {
    [rgb[1], rgb[0] - rgb[1], rgb[2] - rgb[1]]
}

/// Round to the nearest bin, the way every encoder in this repository does.
///
/// `f64::round` breaks ties away from zero and NumPy's `rint` breaks them to even, which
/// differ on exact halves — and exact halves happen constantly on synthetic data, so this
/// has to be the even rule or two encoders produce different files from one scene.
#[inline]
pub fn rint(v: f64) -> i64 {
    let nearest = v.round();
    let out = if (v - v.trunc()).abs() == 0.5 && nearest % 2.0 != 0.0 {
        nearest - v.signum()
    } else {
        nearest
    };
    out as i64
}

/// Argsort by Morton code over the points' own bounding box.
///
/// Spatial locality is what makes the position delta stream small; nothing else in the
/// format depends on gaussian order, and no decoder may assume one.
pub fn morton_order(positions: &[f32], count: usize) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    let mut lo = [f64::INFINITY; 3];
    let mut hi = [f64::NEG_INFINITY; 3];
    for i in 0..count {
        for k in 0..3 {
            let v = positions[i * 3 + k] as f64;
            lo[k] = lo[k].min(v);
            hi[k] = hi[k].max(v);
        }
    }
    let span = [
        if hi[0] - lo[0] <= 0.0 {
            1.0
        } else {
            hi[0] - lo[0]
        },
        if hi[1] - lo[1] <= 0.0 {
            1.0
        } else {
            hi[1] - lo[1]
        },
        if hi[2] - lo[2] <= 0.0 {
            1.0
        } else {
            hi[2] - lo[2]
        },
    ];
    let scale = ((1u64 << 21) - 1) as f64;
    let mut keyed: Vec<(u64, usize)> = (0..count)
        .map(|i| {
            let mut code = 0u64;
            for k in 0..3 {
                let t = (((positions[i * 3 + k] as f64) - lo[k]) / span[k]).clamp(0.0, 1.0);
                code |= part1by2(rint(t * scale) as u64) << k;
            }
            (code, i)
        })
        .collect();
    keyed.sort_by_key(|(code, i)| (*code, *i));
    keyed.into_iter().map(|(_, i)| i).collect()
}

fn part1by2(x: u64) -> u64 {
    let mut x = x & 0x1F_FFFF;
    x = (x | (x << 32)) & 0x001F_0000_0000_FFFF;
    x = (x | (x << 16)) & 0x001F_0000_FF00_00FF;
    x = (x | (x << 8)) & 0x100F_00F0_0F00_F00F;
    x = (x | (x << 4)) & 0x10C3_0C30_C30C_30C3;
    x = (x | (x << 2)) & 0x1249_2492_4924_9249;
    x
}
