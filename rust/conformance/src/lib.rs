// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The canonical JSON two implementations are diffed on.
//!
//! Representation is pinned so that a disagreement is always about the format and never
//! about how a language spells a number: integers are strings, floats are rounded to a
//! fixed number of decimals, a never-fading gaussian's sigma is `null`, `audio` is `null`
//! when absent and an object when present, and keys are sorted.
//!
//! **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an
//! encoder and readers must not rely on their order, so a summary that did would be asking
//! two correct decoders to disagree. Everything per-gaussian is taken in the content order
//! defined by [`stable_order`], which is derived from decoded values alone.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use fourdgs::model::GaussianSet;
use fourdgs::records::{Attachment, Camera, Header, Metadata, Statistics, SummaryOffset};

pub const FLOAT_DECIMALS: usize = 6;
/// How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
/// pass by getting a prefix right.
pub const SAMPLE: usize = 16;
/// How many camera keyframes appear in full, so a long trajectory cannot bloat a summary.
pub const CAMERA_KEYFRAMES: usize = 4;

/// A JSON value, with objects sorted by key.
pub enum J {
    Null,
    Bool(bool),
    Num(f64),
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
            J::Num(v) => {
                let _ = write!(out, "{v:.*}", FLOAT_DECIMALS);
            }
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
}

/// An embedded track, as the summary sees it.
pub struct AudioSummary {
    pub codec: String,
    pub data: Vec<u8>,
}

/// The statement every implementation must agree on for a variant.
pub fn summarize(
    header: &Header,
    gaussians: &GaussianSet,
    audio: Option<&AudioSummary>,
    chunk_intervals: &[(f64, f64)],
    extras: &Extras<'_>,
) -> String {
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

    let mut total_pos = [0.0f64; 3];
    let mut alpha_sum = 0.0f64;
    let mut never_fades = 0u64;
    let mut still = 0u64;
    for i in &order {
        for (k, slot) in total_pos.iter_mut().enumerate() {
            *slot += gaussians.positions[i * 3 + k] as f64;
        }
        alpha_sum += gaussians.colors[i * 4 + 3] as f64;
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

    let summary = J::obj(vec![
        ("gaussianCount", int(n as u64)),
        ("durationSec", num(header.duration_sec)),
        ("cutoff", num(header.cutoff)),
        // The Header's first two fields: readable everywhere, asserted nowhere until now.
        ("profile", J::Str(header.profile.clone())),
        ("library", J::Str(header.library.clone())),
        ("shDegree", J::Num(header.sh_degree as f64)),
        ("temporalModel", J::Str(header.temporal_model.clone())),
        ("hasAudio", J::Bool(header.has_audio())),
        // Absent audio is a value, not a missing key: both paths are conformance-visible.
        (
            "audio",
            match audio {
                None => J::Null,
                Some(a) => J::obj(vec![
                    ("codec", J::Str(a.codec.clone())),
                    ("byteLength", int(a.data.len() as u64)),
                    ("crc", crc(&a.data)),
                ]),
            },
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
        (
            "sample",
            J::obj(vec![
                ("positions", rows(&gaussians.positions, 3)),
                ("scales", rows(&gaussians.scales, 3)),
                ("rotations", rows(&gaussians.rotations, 4)),
                ("colors", rows(&gaussians.colors, 4)),
                ("motions", rows(&gaussians.motions, 3)),
                ("muT", scalars(&gaussians.mu_t)),
                ("sigmaT", scalars(&gaussians.sigma_t)),
                ("winLo", scalars(&gaussians.win_lo)),
                ("winHi", scalars(&gaussians.win_hi)),
            ]),
        ),
        (
            "aggregate",
            J::obj(vec![
                (
                    "positionSum",
                    J::Arr(total_pos.iter().map(|v| num(*v)).collect()),
                ),
                ("opacitySum", num(alpha_sum)),
                ("neverFadesCount", int(never_fades)),
                ("zeroMotionCount", int(still)),
            ]),
        ),
    ]);
    summary.to_json()
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

/// Sort gaussians into an order both implementations can reproduce.
///
/// Chunking and Morton ordering are encoder choices, so decoded order is not part of the
/// contract — but a comparison needs *some* order. The key is the gaussian's whole decoded
/// state, rounded exactly as the summary rounds it, with its spherical harmonic
/// coefficients last. Two gaussians that tie on all of it are identical in every value this
/// summary emits, so their relative order cannot change the output.
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
        keys.push((row, i));
    }
    // A stable sort, so gaussians that tie on every rounded value keep decode order — the
    // same tiebreak every other implementation's sort makes.
    keys.sort_by(|a, b| {
        a.0.partial_cmp(&b.0)
            .expect("no key value is NaN; see `sortable`")
    });
    keys.into_iter().map(|(_, i)| i).collect()
}

/// A comparison key: rounded like the summary, with infinity kept as infinity so the two
/// languages order never-fading gaussians identically.
fn sortable(value: f32) -> f64 {
    let v = value as f64;
    if v.is_nan() {
        return f64::INFINITY;
    }
    if v.is_infinite() {
        return v;
    }
    round_decimals(v)
}

/// The double nearest to `v` rounded to [`FLOAT_DECIMALS`] places — the same value Python's
/// `round(v, 6)` produces, reached the same way: correct decimal rounding, then the nearest
/// double to that decimal.
fn round_decimals(v: f64) -> f64 {
    let text = format!("{v:.*}", FLOAT_DECIMALS);
    text.parse().unwrap_or(v)
}
