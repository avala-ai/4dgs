// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Decoding one chunk's attribute streams into gaussian state.
//!
//! Both read paths — streamed and indexed — end up here, which is the point: they differ
//! in how bytes are obtained and not at all in what those bytes mean.

use std::collections::BTreeMap;

use crate::codec;
use crate::error::{Error, Result};
use crate::opcode as op;
use crate::quantization::{
    dequantize_rotation, life_class, motion_step, mu_step, rct_inverse, Steps,
};
use crate::records::ChunkHeader;
use crate::serialization::Cursor;
use crate::stream::{decode_stream, DecodedStream};

/// One chunk's gaussians, in the same flat layout the scene uses.
#[derive(Debug, Clone, Default)]
pub struct DecodedChunk {
    pub count: usize,
    pub positions: Vec<f32>,
    pub scales: Vec<f32>,
    pub rotations: Vec<f32>,
    pub colors: Vec<f32>,
    pub motions: Vec<f32>,
    pub mu_t: Vec<f32>,
    pub sigma_t: Vec<f32>,
    pub window_index: Vec<u32>,
    pub source_index: Option<Vec<i64>>,
    /// Band number to its decoded coefficients, populated only for the bands a caller
    /// asked for.
    pub bands: BTreeMap<u8, DecodedStream>,
}

/// The Window Table as pairs, or the one-window default.
///
/// A file with no Window Table, or one whose count is zero, reads as though it declared
/// exactly one window `(0, 0)`: every gaussian references index 0 and nothing is visible
/// at any time. Degenerate, well defined, and not an error (spec §5.4).
pub fn window_table_or_default(windows: &[(f64, f64)]) -> &[(f64, f64)] {
    const DEFAULT: [(f64, f64); 1] = [(0.0, 0.0)];
    if windows.is_empty() {
        &DEFAULT
    } else {
        windows
    }
}

/// A chunk's attribute streams, with any chunk-level compression undone.
///
/// Compression is normally per stream and this field is empty, but the format allows a
/// codec over the whole records block. Ignoring it decodes the compressed bytes as though
/// they were attribute streams, which produces wrong gaussians instead of an error.
pub fn chunk_stream_bytes<'a>(
    head: &ChunkHeader,
    streams: &'a [u8],
) -> Result<std::borrow::Cow<'a, [u8]>> {
    if head.compression.is_empty() {
        return Ok(std::borrow::Cow::Borrowed(streams));
    }
    let numeric = codec::codec_from_name(&head.compression).ok_or_else(|| {
        Error::UnsupportedCodec(format!(
            "the chunk at t0={} is compressed with {:?}, which this build does not know",
            head.t0, head.compression
        ))
    })?;
    let expected = usize::try_from(head.uncompressed_size).map_err(|_| {
        Error::Malformed(format!(
            "the chunk at t0={} declares {} uncompressed bytes, more than this platform can address",
            head.t0, head.uncompressed_size
        ))
    })?;
    Ok(std::borrow::Cow::Owned(codec::decompress(
        streams, numeric, expected,
    )?))
}

/// Refuse a window index outside the table rather than clamping it.
///
/// Clamping substitutes one gaussian's lifetime for another's, in a file that is already
/// wrong in some way nobody has diagnosed — it turns a detectable fault into plausible
/// wrong output. Refusing names the index and the table.
pub fn check_window_index(index: i64, table_len: usize) -> Result<u32> {
    if index < 0 || index as usize >= table_len {
        return Err(Error::Malformed(format!(
            "window index {index} is outside the {table_len}-entry window table"
        )));
    }
    Ok(index as u32)
}

/// Decode a chunk's attribute streams.
///
/// `windows` and `cutoff` are required, not optional: a never-fading gaussian's velocity
/// precision is derived from the length of its validity window, and the cutoff sets the
/// support constant that derivation starts from. A decoder that guesses either decodes
/// different velocities than the encoder wrote, and the file gives it no way to notice.
pub fn decode_streams(
    streams: &[u8],
    count: usize,
    steps: &Steps,
    origin: &[f64],
    windows: &[(f64, f64)],
    cutoff: f64,
) -> Result<DecodedChunk> {
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut cursor = Cursor::new(streams);
    while cursor.remaining() > 0 {
        let (attribute_id, values) = decode_stream(&mut cursor)?;
        got.insert(attribute_id, values);
    }

    let mut out = DecodedChunk {
        count,
        ..Default::default()
    };
    if count == 0 {
        return Ok(out);
    }

    let missing: Vec<u8> = op::REQUIRED_ATTRIBUTES
        .iter()
        .copied()
        .filter(|a| !got.contains_key(a))
        .collect();
    if !missing.is_empty() {
        return Err(Error::Malformed(format!(
            "chunk is missing required attributes {missing:?}"
        )));
    }

    let need = |id: u8| -> &DecodedStream { got.get(&id).expect("required attribute present") };
    for id in op::REQUIRED_ATTRIBUTES {
        let s = need(id);
        if s.count != count {
            return Err(Error::Malformed(format!(
                "attribute {id} carries {} elements, the chunk declares {count}",
                s.count
            )));
        }
    }

    let position = need(op::A_POSITION);
    let scale = need(op::A_SCALE);
    let rotation_index = need(op::A_ROTATION_INDEX);
    let rotation = need(op::A_ROTATION);
    let color = need(op::A_COLOR);
    let opacity = need(op::A_OPACITY);
    let motion = need(op::A_MOTION);
    let mu = need(op::A_MU_T);
    let sigma = need(op::A_SIGMA_T);
    let flags = need(op::A_FLAGS);
    let window_index = need(op::A_WINDOW_INDEX);

    for (name, stream, want) in [
        ("position", position, 3usize),
        ("scale", scale, 3),
        ("rotation", rotation, 3),
        ("color", color, 3),
        ("motion", motion, 3),
    ] {
        if stream.channels != want {
            return Err(Error::Malformed(format!(
                "the {name} stream declares {} channels, the format defines {want}",
                stream.channels
            )));
        }
    }
    if origin.len() < 3 {
        return Err(Error::Malformed(
            "the Quantization record's position origin is not three values".into(),
        ));
    }

    let table = window_table_or_default(windows);
    let k = crate::quantization::support_k(cutoff);

    out.positions = Vec::with_capacity(count * 3);
    out.scales = Vec::with_capacity(count * 3);
    out.rotations = Vec::with_capacity(count * 4);
    out.colors = Vec::with_capacity(count * 4);
    out.motions = Vec::with_capacity(count * 3);
    out.mu_t = Vec::with_capacity(count);
    out.sigma_t = Vec::with_capacity(count);
    out.window_index = Vec::with_capacity(count);

    for i in 0..count {
        let wi = check_window_index(window_index.get(i, 0), table.len())?;
        out.window_index.push(wi);
        let (win_lo, win_hi) = table[wi as usize];

        let never_fades = flags.get(i, 0) & op::FLAG_NEVER_FADES != 0;
        let sigma_bin = sigma.get(i, 0);
        out.sigma_t.push(if never_fades {
            f32::INFINITY
        } else {
            ((sigma_bin as f64 * steps.sigma_log).exp()) as f32
        });

        for (axis, origin_axis) in origin.iter().enumerate().take(3) {
            out.positions
                .push((position.get(i, axis) as f64 * steps.pos + origin_axis) as f32);
            out.scales
                .push(((scale.get(i, axis) as f64 * steps.scale_log).exp()) as f32);
        }

        let quat = dequantize_rotation(rotation_index.get(i, 0), rotation.row(i), steps.rot);
        out.rotations.extend_from_slice(&quat);

        let rgb = rct_inverse(color.row(i));
        for c in rgb {
            out.colors
                .push((c as f64 * steps.rgb).clamp(0.0, 1.0) as f32);
        }
        out.colors
            .push((opacity.get(i, 0) as f64 * steps.alpha).clamp(0.0, 1.0) as f32);

        // Both per-gaussian pitches come from the sigma bin this decoder has already
        // read, so there is no side channel to get wrong (spec §6.3).
        let class = life_class(sigma_bin, steps.sigma_log, never_fades, win_hi - win_lo, k);
        let m_step = motion_step(class, steps.motion);
        for k_axis in 0..3 {
            out.motions
                .push((motion.get(i, k_axis) as f64 * m_step) as f32);
        }
        let t_step = mu_step(sigma_bin, steps.sigma_log, never_fades, steps.time);
        out.mu_t.push((mu.get(i, 0) as f64 * t_step) as f32);
    }

    if let Some(src) = got.get(&op::A_SOURCE_INDEX) {
        out.source_index = Some((0..count).map(|i| src.get(i, 0)).collect());
    }

    Ok(out)
}
