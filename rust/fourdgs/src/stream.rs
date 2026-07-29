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

    if count == 0 {
        cursor.take(payload_length)?;
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
    if !matches!(width, 1 | 2 | 4) {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id}: symbol width {width} is not 1, 2 or 4"
        )));
    }
    if channels == 0 {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id}: a stream with {count} elements declares 0 channels"
        )));
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
    let expected = (symbols as u64) * (width as u64);
    if expected > MAX_STREAM_BYTES {
        return Err(Error::Malformed(format!(
            "attribute {attribute_id} declares {expected} bytes, past the {MAX_STREAM_BYTES} cap"
        )));
    }

    let payload = cursor.take(payload_length)?;
    let raw = codec::decompress(payload, stream_codec, expected as usize)?;
    let symbols_out = unshuffle(&raw, width, symbols);

    let mut values: Vec<i64> = symbols_out.into_iter().map(unzigzag).collect();

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
        other => {
            return Err(Error::Malformed(format!(
                "attribute {attribute_id}: unknown stream mode {other}"
            )))
        }
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
fn unshuffle(raw: &[u8], width: u8, symbols: usize) -> Vec<u64> {
    if width == 1 {
        return raw[..symbols].iter().map(|b| *b as u64).collect();
    }
    let w = width as usize;
    let mut out = vec![0u64; symbols];
    for j in 0..w {
        let plane = &raw[j * symbols..(j + 1) * symbols];
        let shift = 8 * j;
        for (i, byte) in plane.iter().enumerate() {
            out[i] |= (*byte as u64) << shift;
        }
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
