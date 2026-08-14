// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Attribute Stream and SH Band Stream payloads.
//!
//! Payload decoding, in order: decompress with `codec`; if `symbol_width > 1`, reverse the
//! byte-plane shuffle; zigzag-decode each symbol; then apply `mode`. After decompression
//! every stage is integer arithmetic, so decoders in different languages produce
//! bit-identical integers and error cannot accumulate.

use crate::codec;
use crate::error::{Error, Result};
use crate::serialization::{Cursor, MAX_STREAM_BYTES, STREAM_HEADER_SIZE};

pub const MODE_RAW: u8 = 0;
pub const MODE_DELTA: u8 = 1;
pub const MODE_CONST: u8 = 2;

/// One decoded stream: `count` elements of `channels` symbols each, row-major.
///
/// A constant stream keeps its single row rather than the `count` copies of it the wire
/// format describes. That is not only cheaper: materializing the repeat is an amplification
/// a crafted file can aim at, since `mode = 2` stores `channels` symbols and an element
/// count that owes nothing to the payload's size.
#[derive(Debug, Clone, Default)]
pub struct DecodedStream {
    pub values: Vec<i64>,
    pub count: usize,
    pub channels: usize,
    /// When set, `values` holds exactly one element and every index yields it.
    pub constant: bool,
}

impl DecodedStream {
    /// Channel `c` of element `i`.
    #[inline]
    pub fn get(&self, i: usize, c: usize) -> i64 {
        if self.constant {
            self.values[c]
        } else {
            self.values[i * self.channels + c]
        }
    }

    /// Element `i`'s channels.
    #[inline]
    pub fn row(&self, i: usize) -> &[i64] {
        if self.constant {
            &self.values[..self.channels]
        } else {
            &self.values[i * self.channels..(i + 1) * self.channels]
        }
    }
}

/// Read one stream, returning its `attribute_id` and decoded symbols.
///
/// A caller must never dispatch on the returned id for a stream that came out of an SH
/// Band Stream record: those carry `0x07` there, which collides with `mu_t`'s id of 7.
/// Band streams are identified by the record that contains them (spec §5.7).
pub fn decode_stream(
    cursor: &mut Cursor<'_>,
    expected_elements: Option<usize>,
) -> Result<(u8, DecodedStream)> {
    decode_stream_with_limit(cursor, expected_elements, None, MAX_STREAM_BYTES as usize)
}

/// Decode one stream within the bytes its raw symbols and resident `i64` values may
/// occupy together.
///
/// The wire-size ceiling alone is insufficient: one byte on the wire becomes an
/// eight-byte value in [`DecodedStream`]. Whole-scene readers pass their remaining
/// aggregate budget so this amplification is refused before decompression or allocation.
pub(crate) fn decode_stream_with_limit(
    cursor: &mut Cursor<'_>,
    expected_elements: Option<usize>,
    expected_channels: Option<usize>,
    max_working_bytes: usize,
) -> Result<(u8, DecodedStream)> {
    let head = cursor.take(STREAM_HEADER_SIZE)?;
    let attribute_id = head[0];
    let width = head[1];
    let mode = head[2];
    let stream_codec = head[3];
    let channels = head[4] as usize;
    let count = u32::from_le_bytes([head[5], head[6], head[7], head[8]]) as usize;
    let payload_length = u64::from_le_bytes([
        head[9], head[10], head[11], head[12], head[13], head[14], head[15], head[16],
    ]);
    let payload_length = usize::try_from(payload_length).map_err(|_| {
        Error::Truncated(format!(
            "attribute {attribute_id} declares a payload larger than this platform can address"
        ))
    })?;

    // Checked before anything is sized from `count`. A stream that disagrees with the
    // chunk it sits in is rejected rather than decoded and then discarded, which is the
    // difference between refusing a file and allocating for it first.
    if let Some(want) = expected_elements {
        if count != want {
            return Err(Error::Malformed(format!(
                "attribute {attribute_id} carries {count} elements, the chunk declares {want}"
            )));
        }
    }

    if !matches!(width, 1 | 2 | 4) {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id}: symbol width {width} is not 1, 2 or 4"
        )));
    }
    if channels == 0 {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id}: a stream declares 0 channels"
        )));
    }
    if !matches!(mode, MODE_RAW | MODE_DELTA | MODE_CONST) {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id}: unknown stream mode {mode}"
        )));
    }
    // Codec availability is determined from the header alone. Keep this before the
    // known-attribute arity check so a future/unsupported codec remains a named
    // capability refusal even when this build cannot interpret the rest of its stream.
    codec::check_decoder(stream_codec)?;
    if let Some(want) = expected_channels {
        if channels != want {
            return Err(Error::Malformed(format!(
                "attribute {attribute_id} declares {channels} channels; the format defines {want}"
            )));
        }
    }

    // The canonical empty stream is raw and has no payload at all, so no codec frame
    // exists to validate.  Any other zero-row shape still has Attribute Stream payload
    // semantics: raw/delta data must decompress to exactly zero bytes, while constant
    // mode must carry its one channel row even though it will be repeated zero times.
    // Do not let an empty element count turn arbitrary compressed bytes into an ignored
    // extension.
    if count == 0 && mode == MODE_RAW && payload_length == 0 {
        return Ok((
            attribute_id,
            DecodedStream {
                values: Vec::new(),
                count: 0,
                channels,
                constant: false,
            },
        ));
    }

    // A constant stream stores exactly `channels` symbols and repeats them.
    let symbols = if mode == MODE_CONST {
        channels
    } else {
        count.checked_mul(channels).ok_or_else(|| {
            Error::Malformed(format!(
                "attribute {attribute_id}: {count} elements × {channels} channels overflows"
            ))
        })?
    };
    let expected = symbols.checked_mul(width as usize).ok_or_else(|| {
        Error::Malformed(format!(
            "attribute {attribute_id}: decoded wire-byte count overflows"
        ))
    })?;
    if expected as u64 > MAX_STREAM_BYTES {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id} declares {expected} bytes, past the {MAX_STREAM_BYTES} cap"
        )));
    }
    let resident = symbols
        .checked_mul(std::mem::size_of::<i64>())
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "attribute {attribute_id}: resident decoded-symbol bytes overflow"
            ))
        })?;
    let working = expected.checked_add(resident).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "attribute {attribute_id}: raw plus resident decoded-symbol bytes overflow"
        ))
    })?;
    if working > max_working_bytes {
        return Err(Error::UnsupportedOperation(format!(
            "attribute {attribute_id} needs {working} bytes for {expected} raw bytes plus {resident} resident decoded-symbol bytes, past the {max_working_bytes} byte remaining decode budget"
        )));
    }

    let payload = cursor.take(payload_length)?;
    let raw = codec::decompress(payload, stream_codec, expected)?;
    let mut values = unshuffle_signed(&raw, width, symbols);

    let mut constant = false;
    match mode {
        // The repeat is not materialized; `DecodedStream` performs it on access.
        MODE_CONST => constant = true,
        MODE_DELTA => {
            // Delta runs along element order, independently per channel.
            for i in 1..count {
                for c in 0..channels {
                    let prev = values[(i - 1) * channels + c];
                    let here = values[i * channels + c];
                    values[i * channels + c] = prev.wrapping_add(here);
                }
            }
        }
        MODE_RAW => {}
        _ => unreachable!("the mode was validated before allocation"),
    }

    Ok((
        attribute_id,
        DecodedStream {
            values,
            count,
            channels,
            constant,
        },
    ))
}

/// Reverse the byte-plane shuffle: plane `j` holds byte `j` of every symbol.
fn unshuffle_signed(raw: &[u8], width: u8, symbols: usize) -> Vec<i64> {
    if width == 1 {
        let mut out = Vec::with_capacity(symbols);
        out.extend(raw[..symbols].iter().map(|byte| unzigzag(*byte as u64)));
        return out;
    }
    let w = width as usize;
    let mut out = Vec::with_capacity(symbols);
    for i in 0..symbols {
        let mut value = 0u64;
        for j in 0..w {
            value |= (raw[j * symbols + i] as u64) << (8 * j);
        }
        out.push(unzigzag(value));
    }
    out
}

/// `(u >> 1) ^ -(u & 1)`.
#[inline]
pub fn unzigzag(u: u64) -> i64 {
    ((u >> 1) as i64) ^ -((u & 1) as i64)
}

/// The inverse, for the encoder.
#[inline]
pub fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

// --------------------------------------------------------------------------
// Encoding
// --------------------------------------------------------------------------

/// Serialize signed integer bins as one attribute stream.
///
/// Raw and delta coding are both tried and the smaller kept, with the choice recorded in
/// the header — a decoder never has to infer which one was used.
pub fn encode_stream(
    attribute_id: u8,
    values: &[i64],
    channels: usize,
    stream_codec: u8,
    level: u32,
    allow_delta: bool,
) -> Result<Vec<u8>> {
    assert!(channels > 0, "a stream needs at least one channel");
    assert!(
        values.len() % channels == 0,
        "a stream's values must divide by its channel count"
    );
    let count = values.len() / channels;

    if count == 0 {
        return Ok(stream_header(
            attribute_id,
            1,
            MODE_RAW,
            stream_codec,
            channels,
            0,
            0,
        ));
    }

    // A stream whose every element repeats the first stores one element and a count.
    if count > 1
        && values
            .chunks(channels)
            .all(|row| row == &values[..channels])
    {
        let body = shuffled_body(&values[..channels], stream_codec, level)?;
        let mut out = stream_header(
            attribute_id,
            body.0,
            MODE_CONST,
            stream_codec,
            channels,
            count,
            body.1.len(),
        );
        out.extend_from_slice(&body.1);
        return Ok(out);
    }

    let mut best: Option<(u8, u8, Vec<u8>)> = None;
    let mut candidates: Vec<(u8, Vec<i64>)> = vec![(MODE_RAW, values.to_vec())];
    if allow_delta && count > 1 {
        let mut delta = values.to_vec();
        for i in 1..count {
            for c in 0..channels {
                delta[i * channels + c] =
                    values[i * channels + c].wrapping_sub(values[(i - 1) * channels + c]);
            }
        }
        candidates.push((MODE_DELTA, delta));
    }
    for (mode, arr) in candidates {
        let (width, body) = shuffled_body(&arr, stream_codec, level)?;
        if best.as_ref().is_none_or(|b| body.len() < b.2.len()) {
            best = Some((mode, width, body));
        }
    }
    let (mode, width, body) = best.expect("at least one candidate encoding");
    let mut out = stream_header(
        attribute_id,
        width,
        mode,
        stream_codec,
        channels,
        count,
        body.len(),
    );
    out.extend_from_slice(&body);
    Ok(out)
}

fn stream_header(
    attribute_id: u8,
    width: u8,
    mode: u8,
    stream_codec: u8,
    channels: usize,
    count: usize,
    payload_length: usize,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(STREAM_HEADER_SIZE + payload_length);
    out.push(attribute_id);
    out.push(width);
    out.push(mode);
    out.push(stream_codec);
    out.push(channels as u8);
    out.extend_from_slice(&(count as u32).to_le_bytes());
    out.extend_from_slice(&(payload_length as u64).to_le_bytes());
    out
}

/// Zigzag, pick the narrowest symbol width that fits, byte-plane shuffle, compress.
fn shuffled_body(values: &[i64], stream_codec: u8, level: u32) -> Result<(u8, Vec<u8>)> {
    let zig: Vec<u64> = values.iter().map(|v| zigzag(*v)).collect();
    let width = width_for(&zig)?;
    let n = zig.len();
    let mut raw = vec![0u8; n * width as usize];
    if width == 1 {
        for (i, z) in zig.iter().enumerate() {
            raw[i] = *z as u8;
        }
    } else {
        for j in 0..width as usize {
            let shift = 8 * j;
            for (i, z) in zig.iter().enumerate() {
                raw[j * n + i] = ((*z >> shift) & 0xFF) as u8;
            }
        }
    }
    Ok((width, codec::compress(&raw, stream_codec, level)?))
}

fn width_for(zig: &[u64]) -> Result<u8> {
    let max = zig.iter().copied().max().unwrap_or(0);
    if max <= 0xFF {
        Ok(1)
    } else if max <= 0xFFFF {
        Ok(2)
    } else if max <= 0xFFFF_FFFF {
        Ok(4)
    } else {
        Err(Error::Malformed(format!(
            "symbol {max} exceeds 32 bits; the error bound is too tight for this data"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn width_one_symbol_expansion_is_refused_before_payload_decode() {
        let encoded = encode_stream(42, &[0, 1, 2, 3], 1, codec::DEFLATE, 6, false)
            .expect("width-one raw stream");
        assert_eq!(encoded[1], 1, "the fixture exercises one-byte wire symbols");
        assert_eq!(encoded[2], MODE_RAW);
        let mut cursor = Cursor::new(&encoded);

        // Four raw bytes plus four resident i64 values require 36 bytes together.
        let error = decode_stream_with_limit(&mut cursor, Some(4), Some(1), 35).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("4 raw bytes"), "{error}");
        assert!(
            error.to_string().contains("32 resident decoded-symbol"),
            "{error}"
        );
        assert_eq!(
            cursor.position(),
            STREAM_HEADER_SIZE,
            "the resource check runs before the compressed payload is consumed"
        );
    }

    #[test]
    fn non_power_of_two_raw_output_is_budgeted_exactly_before_payload_decode() {
        const SYMBOLS: usize = 8_193;
        let values: Vec<i64> = (0..SYMBOLS).map(|value| (value % 127) as i64).collect();
        let encoded = encode_stream(42, &values, 1, codec::DEFLATE, 6, false)
            .expect("non-power-of-two width-one stream");
        assert_eq!(encoded[1], 1);
        assert_ne!(SYMBOLS.next_power_of_two(), SYMBOLS);
        let resident = SYMBOLS * std::mem::size_of::<i64>();
        let mut cursor = Cursor::new(&encoded);

        let error =
            decode_stream_with_limit(&mut cursor, Some(SYMBOLS), Some(1), SYMBOLS + resident - 1)
                .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains(&format!("{SYMBOLS} raw bytes")),
            "{error}"
        );
        assert_eq!(
            cursor.position(),
            STREAM_HEADER_SIZE,
            "the exact raw-plus-resident budget is checked before payload consumption"
        );
    }

    #[test]
    fn known_channel_arity_is_malformed_before_budget_or_payload_decode() {
        let mut encoded = encode_stream(42, &[0, 1], 2, codec::DEFLATE, 6, false)
            .expect("two-channel raw stream");
        assert_eq!(encoded[2], MODE_RAW);
        // Make the declared row count hostile without making a correspondingly large
        // fixture. If arity were checked after resident-size budgeting, this would be an
        // implementation-limit refusal instead of the structural defect on the wire.
        encoded[5..9].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut cursor = Cursor::new(&encoded);

        let error =
            decode_stream_with_limit(&mut cursor, Some(u32::MAX as usize), Some(1), 0).unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("declares 2 channels"), "{error}");
        assert_eq!(
            cursor.position(),
            STREAM_HEADER_SIZE,
            "the channel check runs before the compressed payload is consumed"
        );
    }

    #[test]
    fn zero_count_streams_still_validate_their_headers() {
        let encoded =
            encode_stream(42, &[], 1, codec::DEFLATE, 6, false).expect("canonical empty stream");
        for (field, value, expected) in [
            (1, 3, "symbol width"),
            (2, 99, "stream mode"),
            (4, 0, "0 channels"),
            (4, 2, "format defines 1"),
        ] {
            let mut malformed = encoded.clone();
            malformed[field] = value;
            let mut cursor = Cursor::new(&malformed);
            let error = decode_stream_with_limit(&mut cursor, Some(0), Some(1), 0).unwrap_err();
            assert!(matches!(error, Error::Malformed(_)), "{error}");
            assert!(error.to_string().contains(expected), "{error}");
            assert_eq!(cursor.position(), STREAM_HEADER_SIZE);
        }

        let mut unsupported = encoded;
        unsupported[3] = 0xff;
        let mut cursor = Cursor::new(&unsupported);
        let error = decode_stream_with_limit(&mut cursor, Some(0), Some(1), 0).unwrap_err();
        assert!(
            matches!(
                error,
                Error::Refused {
                    kind: crate::error::RefusalKind::UnsupportedCodec,
                    ..
                }
            ),
            "{error}"
        );
        assert_eq!(cursor.position(), STREAM_HEADER_SIZE);
    }

    #[test]
    fn zero_count_streams_validate_every_present_payload() {
        let payload = codec::compress(&[0], codec::DEFLATE, 6).expect("one decoded byte");
        let mut extra_raw = stream_header(42, 1, MODE_RAW, codec::DEFLATE, 1, 0, payload.len());
        extra_raw.extend_from_slice(&payload);
        let error = decode_stream_with_limit(
            &mut Cursor::new(&extra_raw),
            Some(0),
            Some(1),
            payload.len(),
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(
            error.to_string().contains("more than the 0 bytes"),
            "{error}"
        );

        let missing_constant = stream_header(42, 1, MODE_CONST, codec::DEFLATE, 1, 0, 0);
        let error =
            decode_stream_with_limit(&mut Cursor::new(&missing_constant), Some(0), Some(1), 9)
                .unwrap_err();
        assert!(matches!(error, Error::Truncated(_)), "{error}");
        assert!(error.to_string().contains("declared 1"), "{error}");
    }
}
