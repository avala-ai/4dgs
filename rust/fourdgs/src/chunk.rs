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
use crate::serialization::{Cursor, MAX_STREAM_BYTES};
use crate::stream::{decode_stream_with_limit, DecodedStream};

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
    /// Per-gaussian object membership, or `None` when the chunk carries no `object_id`
    /// stream. Exact: each signed stream code contributes its same 32 bits to the
    /// unsigned id, with no dequantization.
    pub object_id: Option<Vec<u32>>,
    /// Band number to its decoded coefficients, populated only for the bands a caller
    /// asked for.
    pub bands: BTreeMap<u8, DecodedStream>,
}

/// Resident bytes the required gaussian-state columns consume per decoded row.
///
/// Optional source/object/SH columns are bounded by their own decoded streams. This
/// minimum is checked before any output vector is allocated, closing the amplification
/// where tiny constant streams declare billions of logical rows.
const REQUIRED_STATE_BYTES_PER_GAUSSIAN: usize = 80;

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
    chunk_stream_bytes_with_limit(head, streams, MAX_STREAM_BYTES as usize)
}

/// Undo whole-Chunk compression within the bytes still available at the caller's peak.
///
/// `max_unpacked_bytes` covers only a newly allocated outer output. The caller owns the
/// record buffer that `streams` borrows from and accounts that buffer separately; an
/// uncompressed Chunk therefore returns its borrowed slice without charging it twice.
pub(crate) fn chunk_stream_bytes_with_limit<'a>(
    head: &ChunkHeader,
    streams: &'a [u8],
    max_unpacked_bytes: usize,
) -> Result<std::borrow::Cow<'a, [u8]>> {
    if head.compression.is_empty() && streams.len() as u64 != head.uncompressed_size {
        return Err(Error::Malformed(format!(
            "the uncompressed Chunk at t0={} declares {} record bytes but carries {}",
            head.t0,
            head.uncompressed_size,
            streams.len()
        )));
    }
    // Codec identity is a capability question, independent of how large its decoded
    // payload would be. Preserve that named refusal before applying local resource
    // ceilings so callers know whether adding codec support or raising a budget is the
    // relevant remedy.
    let numeric = if head.compression.is_empty() {
        None
    } else {
        let numeric = codec::codec_from_name(&head.compression).ok_or_else(|| {
            Error::refused(
                crate::error::refusal::UNKNOWN_STREAM_CODEC,
                crate::error::RefusalKind::UnsupportedCodec,
                format!(
                    "the chunk at t0={} is compressed with {:?}, which this build does not know",
                    head.t0, head.compression
                ),
            )
        })?;
        codec::check_decoder(numeric)?;
        Some(numeric)
    };
    let expected = usize::try_from(head.uncompressed_size).map_err(|_| {
        Error::UnsupportedOperation(format!(
            "the Chunk at t0={} declares {} uncompressed bytes, more than this platform can address",
            head.t0, head.uncompressed_size
        ))
    })?;
    if head.uncompressed_size > MAX_STREAM_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the Chunk at t0={} declares {} uncompressed record bytes, past the {MAX_STREAM_BYTES} byte reader ceiling",
            head.t0, head.uncompressed_size
        )));
    }
    if head.compression.is_empty() {
        debug_assert_eq!(streams.len(), expected);
        return Ok(std::borrow::Cow::Borrowed(streams));
    }
    if expected > max_unpacked_bytes {
        return Err(Error::UnsupportedOperation(format!(
            "the compressed Chunk at t0={} needs {expected} uncompressed record bytes, past the {max_unpacked_bytes} bytes remaining in the decode working-set budget",
            head.t0
        )));
    }
    Ok(std::borrow::Cow::Owned(codec::decompress(
        streams,
        numeric.expect("a non-empty compression name has a checked codec"),
        expected,
    )?))
}

/// Refuse a window index outside the table rather than clamping it.
///
/// Clamping substitutes one gaussian's lifetime for another's, in a file that is already
/// wrong in some way nobody has diagnosed — it turns a detectable fault into plausible
/// wrong output. Refusing names the index and the table.
pub fn check_window_index(index: i64, table_len: usize) -> Result<u32> {
    if index < 0 || index as usize >= table_len {
        return Err(Error::refused(
            crate::error::refusal::WINDOW_INDEX_OUT_OF_RANGE,
            crate::error::RefusalKind::Malformed,
            format!("window index {index} is outside the {table_len}-entry window table"),
        ));
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
    decode_streams_with_limit(
        streams,
        count,
        steps,
        origin,
        windows,
        cutoff,
        MAX_STREAM_BYTES as usize,
    )
}

/// Decode one Chunk while limiting the resident gaussian columns it may add to a scene.
///
/// The public single-Chunk surface gets the ordinary stream ceiling. Whole-scene readers
/// pass the remaining aggregate budget so the next Chunk is refused before its output
/// vectors are allocated, rather than only after they have joined an already-large set.
pub(crate) fn decode_streams_with_limit(
    streams: &[u8],
    count: usize,
    steps: &Steps,
    origin: &[f64],
    windows: &[(f64, f64)],
    cutoff: f64,
    max_output_bytes: usize,
) -> Result<DecodedChunk> {
    let mut got: BTreeMap<u8, DecodedStream> = BTreeMap::new();
    let mut decoded_stream_bytes = 0usize;
    let mut cursor = Cursor::new(streams);
    while cursor.remaining() > 0 {
        // A repeated attribute is already malformed once its complete fixed header is
        // present.  Check it before applying the remaining allocation budget so a large
        // duplicate names the structural defect instead of looking like a scene that only
        // needs a larger reader ceiling.
        let fixed_header = cursor
            .rest()
            .get(..crate::serialization::STREAM_HEADER_SIZE);
        if let Some(header) = fixed_header {
            let attribute_id = header[0];
            if got.contains_key(&attribute_id) {
                return Err(Error::Malformed(format!(
                    "a chunk carries attribute {attribute_id} twice; the format defines one \
                     stream per attribute"
                )));
            }
        }
        let attribute_id = cursor.rest()[0];
        let expected_channels = match attribute_id {
            op::A_POSITION | op::A_SCALE | op::A_ROTATION | op::A_COLOR | op::A_MOTION => Some(3),
            op::A_ROTATION_INDEX
            | op::A_OPACITY
            | op::A_MU_T
            | op::A_SIGMA_T
            | op::A_FLAGS
            | op::A_WINDOW_INDEX
            | op::A_SOURCE_INDEX
            | op::A_OBJECT_ID => Some(1),
            _ => None,
        };
        let remaining = max_output_bytes
            .checked_sub(decoded_stream_bytes)
            .ok_or_else(|| {
                Error::UnsupportedOperation(
                    "decoded attribute streams exceed the remaining Chunk budget".into(),
                )
            })?;
        let (attribute_id, values) =
            decode_stream_with_limit(&mut cursor, Some(count), expected_channels, remaining)?;
        // The format defines one stream per attribute, so a second is a chunk that
        // cannot say which stream defines its gaussians. Overwriting resolved it
        // silently — and differently per SDK: this reader, Python and TypeScript kept
        // the last stream while Dart kept the first, so one malformed chunk decoded to
        // two memberships.
        debug_assert!(!got.contains_key(&attribute_id));
        let resident = values
            .values
            .capacity()
            .checked_mul(std::mem::size_of::<i64>())
            .ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "attribute {attribute_id} resident decoded-symbol bytes overflow"
                ))
            })?;
        decoded_stream_bytes = decoded_stream_bytes.checked_add(resident).ok_or_else(|| {
            Error::UnsupportedOperation("aggregate decoded attribute bytes overflow".into())
        })?;
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

    // Element counts were checked against `count` as each stream was read, before
    // anything was sized from them.
    let need = |id: u8| -> &DecodedStream { got.get(&id).expect("required attribute present") };

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
    for (name, stream) in [
        ("rotation_index", rotation_index),
        ("opacity", opacity),
        ("mu_t", mu),
        ("sigma_t", sigma),
        ("flags", flags),
        ("window_index", window_index),
    ] {
        if stream.channels != 1 {
            return Err(Error::Malformed(format!(
                "the {name} stream declares {} channels, the format defines 1",
                stream.channels
            )));
        }
    }
    for (name, stream) in [
        ("source_index", got.get(&op::A_SOURCE_INDEX)),
        ("object_id", got.get(&op::A_OBJECT_ID)),
    ] {
        if let Some(stream) = stream {
            if stream.channels != 1 {
                return Err(Error::Malformed(format!(
                    "the {name} stream declares {} channels, the format defines 1",
                    stream.channels
                )));
            }
        }
    }
    if origin.len() < 3 {
        return Err(Error::Malformed(
            "the Quantization record's position origin is not three values".into(),
        ));
    }

    // Constant streams already retain the one value every row will use. Validate domain
    // failures available from that value before a hostile declared count reaches the
    // state-size ceiling; neither check needs an expanded row allocation.
    let table = window_table_or_default(windows);
    if count > 0 && window_index.constant {
        check_window_index(window_index.get(0, 0), table.len())?;
    }
    if count > 0 {
        if let Some(ids) = got.get(&op::A_OBJECT_ID).filter(|ids| ids.constant) {
            let value = ids.get(0, 0);
            i32::try_from(value).map_err(|_| {
                Error::Malformed(format!(
                    "object_id element 0 has signed stream code {value}; expected an i32"
                ))
            })?;
        }
    }

    // Do this only after the sparse stream headers and required channel shapes have been
    // validated. A malformed huge-count Chunk stays malformed; a structurally valid set
    // of constant streams reaches this implementation resource ceiling without ever
    // materializing the repeated rows.
    let optional_state_bytes = usize::from(got.contains_key(&op::A_SOURCE_INDEX))
        .checked_mul(8)
        .and_then(|bytes| {
            usize::from(got.contains_key(&op::A_OBJECT_ID))
                .checked_mul(4)
                .and_then(|object_bytes| bytes.checked_add(object_bytes))
        })
        .ok_or_else(|| Error::UnsupportedOperation("optional Chunk row size overflows".into()))?;
    let state_bytes_per_gaussian = REQUIRED_STATE_BYTES_PER_GAUSSIAN
        .checked_add(optional_state_bytes)
        .ok_or_else(|| Error::UnsupportedOperation("decoded Chunk row size overflows".into()))?;
    let required_state_bytes = count.checked_mul(state_bytes_per_gaussian).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "a Chunk declaring {count} gaussians overflows its decoded-state byte count"
        ))
    })?;
    if required_state_bytes > MAX_STREAM_BYTES as usize {
        return Err(Error::UnsupportedOperation(format!(
            "a Chunk declaring {count} gaussians needs at least {required_state_bytes} resident state bytes, past the {MAX_STREAM_BYTES} byte decoded-state ceiling"
        )));
    }
    if required_state_bytes > max_output_bytes {
        return Err(Error::UnsupportedOperation(format!(
            "a Chunk declaring {count} gaussians would add {required_state_bytes} resident state bytes, past the {max_output_bytes} bytes remaining in the aggregate decoded-scene budget"
        )));
    }
    let peak_decoded_bytes = decoded_stream_bytes
        .checked_add(required_state_bytes)
        .ok_or_else(|| Error::UnsupportedOperation("Chunk decode peak bytes overflow".into()))?;
    if peak_decoded_bytes > max_output_bytes {
        return Err(Error::UnsupportedOperation(format!(
            "decoding the Chunk needs {peak_decoded_bytes} bytes across attribute symbols and {required_state_bytes} output state bytes, past the {max_output_bytes} byte remaining aggregate decoded-scene budget"
        )));
    }

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
    if let Some(ids) = got.get(&op::A_OBJECT_ID) {
        if ids.channels != 1 {
            return Err(Error::Malformed(format!(
                "the object_id stream declares {} channels, the format defines 1",
                ids.channels
            )));
        }
        let mut object_ids = Vec::with_capacity(count);
        for i in 0..count {
            let value = ids.get(i, 0);
            let signed = i32::try_from(value).map_err(|_| {
                Error::Malformed(format!(
                    "object_id element {i} has signed stream code {value}; expected an i32"
                ))
            })?;
            object_ids.push(signed as u32);
        }
        out.object_id = Some(object_ids);
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_chunk_codec_precedes_the_decoded_size_ceiling() {
        let error = chunk_stream_bytes(
            &ChunkHeader {
                t0: 2.5,
                t1: 3.0,
                level: 0,
                count: 0,
                compression: "future-codec".into(),
                uncompressed_size: MAX_STREAM_BYTES + 1,
            },
            &[],
        )
        .unwrap_err();
        assert_eq!(
            error.refusal_code(),
            Some(crate::error::refusal::UNKNOWN_STREAM_CODEC)
        );
        assert!(error.to_string().contains("future-codec"), "{error}");
    }

    #[test]
    fn compressed_chunk_output_obeys_the_callers_remaining_budget() {
        let raw = [0x5a; 257];
        let compressed = codec::compress(&raw, codec::DEFLATE, 6).expect("compress test block");
        let head = ChunkHeader {
            t0: 2.5,
            t1: 3.0,
            level: 0,
            count: 0,
            compression: "deflate".into(),
            uncompressed_size: raw.len() as u64,
        };

        let error = chunk_stream_bytes_with_limit(&head, &compressed, raw.len() - 1).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("257 uncompressed"), "{error}");
        assert!(error.to_string().contains("256 bytes remaining"), "{error}");
    }

    #[test]
    fn retained_width_one_streams_are_budgeted_with_their_output_state() {
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            streams.extend_from_slice(
                &crate::stream::encode_stream(
                    attribute,
                    &vec![0; channel_count],
                    channel_count,
                    codec::DEFLATE,
                    6,
                    false,
                )
                .expect("one-row width-one stream"),
            );
        }

        // Required symbols occupy 21 * 8 = 168 bytes after decode; the gaussian output
        // adds 80. Each stream fits alone, but their joint 248-byte peak does not.
        let error = decode_streams_with_limit(
            &streams,
            1,
            &Steps {
                pos: 1.0,
                scale_log: 1.0,
                rot: 1.0,
                rgb: 1.0,
                alpha: 1.0,
                motion: 1.0,
                time: 1.0,
                sigma_log: 1.0,
                sh: 1,
            },
            &[0.0; 3],
            &[(0.0, 1.0)],
            crate::quantization::DEFAULT_CUTOFF,
            247,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("248 bytes"), "{error}");
        assert!(error.to_string().contains("attribute symbols"), "{error}");
    }

    #[test]
    fn hostile_count_does_not_hide_a_known_attribute_channel_mismatch() {
        let mut stream =
            crate::stream::encode_stream(op::A_POSITION, &[0, 0], 2, codec::DEFLATE, 6, false)
                .expect("two-channel position stream");
        stream[5..9].copy_from_slice(&u32::MAX.to_le_bytes());

        let error = decode_streams_with_limit(
            &stream,
            u32::MAX as usize,
            &Steps {
                pos: 1.0,
                scale_log: 1.0,
                rot: 1.0,
                rgb: 1.0,
                alpha: 1.0,
                motion: 1.0,
                time: 1.0,
                sigma_log: 1.0,
                sh: 1,
            },
            &[0.0; 3],
            &[(0.0, 1.0)],
            crate::quantization::DEFAULT_CUTOFF,
            0,
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("declares 2 channels"), "{error}");
        assert!(error.to_string().contains("format defines 3"), "{error}");
    }

    #[test]
    fn hostile_count_does_not_hide_a_constant_window_domain_error() {
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            let value = i64::from(attribute == op::A_WINDOW_INDEX);
            let mut stream = crate::stream::encode_stream(
                attribute,
                &vec![value; channel_count * 2],
                channel_count,
                codec::DEFLATE,
                6,
                false,
            )
            .expect("constant required stream");
            stream[5..9].copy_from_slice(&u32::MAX.to_le_bytes());
            streams.extend_from_slice(&stream);
        }

        let error = decode_streams_with_limit(
            &streams,
            u32::MAX as usize,
            &Steps {
                pos: 1.0,
                scale_log: 1.0,
                rot: 1.0,
                rgb: 1.0,
                alpha: 1.0,
                motion: 1.0,
                time: 1.0,
                sigma_log: 1.0,
                sh: 1,
            },
            &[0.0; 3],
            &[(0.0, 1.0)],
            crate::quantization::DEFAULT_CUTOFF,
            MAX_STREAM_BYTES as usize,
        )
        .unwrap_err();
        assert_eq!(
            error.refusal_code(),
            Some(crate::error::refusal::WINDOW_INDEX_OUT_OF_RANGE),
            "{error}"
        );
        assert!(error.to_string().contains("window index 1"), "{error}");
    }

    #[test]
    fn a_trailing_duplicate_id_byte_is_an_incomplete_stream_header() {
        let mut streams =
            crate::stream::encode_stream(op::A_POSITION, &[0, 0, 0], 3, codec::DEFLATE, 6, false)
                .expect("one complete position stream");
        streams.push(op::A_POSITION);

        let error = decode_streams(
            &streams,
            1,
            &Steps {
                pos: 1.0,
                scale_log: 1.0,
                rot: 1.0,
                rgb: 1.0,
                alpha: 1.0,
                motion: 1.0,
                time: 1.0,
                sigma_log: 1.0,
                sh: 1,
            },
            &[0.0; 3],
            &[(0.0, 1.0)],
            crate::quantization::DEFAULT_CUTOFF,
        )
        .unwrap_err();
        assert!(matches!(error, Error::Truncated(_)), "{error}");
        assert!(error.to_string().contains("need 17 bytes"), "{error}");
        assert!(!error.to_string().contains("twice"), "{error}");
    }

    #[test]
    fn a_complete_duplicate_header_precedes_the_remaining_decode_budget() {
        let stream =
            crate::stream::encode_stream(op::A_POSITION, &[0, 0, 0], 3, codec::DEFLATE, 6, false)
                .expect("one complete position stream");
        let mut streams = stream.clone();
        streams.extend_from_slice(&stream);

        let error = decode_streams_with_limit(
            &streams,
            1,
            &Steps {
                pos: 1.0,
                scale_log: 1.0,
                rot: 1.0,
                rgb: 1.0,
                alpha: 1.0,
                motion: 1.0,
                time: 1.0,
                sigma_log: 1.0,
                sh: 1,
            },
            &[0.0; 3],
            &[(0.0, 1.0)],
            crate::quantization::DEFAULT_CUTOFF,
            3 + 3 * std::mem::size_of::<i64>(),
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("attribute 0 twice"), "{error}");
    }
}
