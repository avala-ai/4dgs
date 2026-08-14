// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Spherical harmonic bands.
//!
//! A scene declares one degree; each nonconstant band has its own SH Band Stream.
//! Readers take bands whole: 1..D gives exactly a degree-D scene.
//!
//! Coefficients are `u8`, stored as written and consumed as read. `step_sh` in the
//! Quantization record describes what the encoder did before it stored them and is **not**
//! applied at decode — multiplying by it scales appearance by a factor of one to three and
//! is the single most likely way to misread that record (spec §6.5).

use std::collections::BTreeMap;

use crate::error::{Error, Result};
use crate::serialization::MAX_STREAM_BYTES;
use crate::stream::DecodedStream;

/// Coefficients per colour component that each band carries, as `[first, last)` within a
/// whole degree's coefficients. Band `b` carries `2b + 1` of them.
pub fn band_range(band: u8) -> Option<(usize, usize)> {
    match band {
        1 => Some((0, 3)),
        2 => Some((3, 8)),
        3 => Some((8, 15)),
        _ => None,
    }
}

/// Merge per-chunk band streams into one scene-wide `count × (3 * coefficients)` array.
///
/// Columns are component-major — every coefficient of red, then green, then blue — which
/// is the layout the streams are written in.
pub fn merge_chunk_bands(
    counts: &[usize],
    chunk_bands: &[BTreeMap<u8, DecodedStream>],
) -> Result<Option<(Vec<u8>, usize)>> {
    let Some(coefficients) = validate_chunk_bands(counts, chunk_bands)? else {
        return Ok(None);
    };
    let total = counts.iter().try_fold(0usize, |total, count| {
        total.checked_add(*count).ok_or_else(|| {
            Error::UnsupportedOperation("SH gaussian count overflows this platform".into())
        })
    })?;
    let output_length = total
        .checked_mul(3)
        .and_then(|value| value.checked_mul(coefficients))
        .ok_or_else(|| Error::UnsupportedOperation("SH output length overflows".into()))?;
    if output_length > MAX_STREAM_BYTES as usize {
        return Err(Error::UnsupportedOperation(format!(
            "merged SH output needs {output_length} bytes, past the {MAX_STREAM_BYTES} byte decoded-state ceiling"
        )));
    }
    let mut out = vec![0u8; output_length];

    let mut at = 0usize;
    for (chunk, bands) in counts.iter().zip(chunk_bands.iter()) {
        let count = *chunk;
        for (band, stream) in bands {
            let (first, last) = band_range(*band)
                .ok_or_else(|| Error::Malformed(format!("SH band {band} is not 1, 2 or 3")))?;
            let width = last - first;
            for i in 0..count {
                for c in 0..3 {
                    for j in 0..width {
                        let value = stream.get(i, c * width + j);
                        if !(0..=255).contains(&value) {
                            return Err(Error::Malformed(
                                "an SH coefficient is outside the 0..255 range this version stores"
                                    .into(),
                            ));
                        }
                        out[(at + i) * 3 * coefficients + c * coefficients + first + j] =
                            value as u8;
                    }
                }
            }
        }
        at += count;
    }
    Ok(Some((out, coefficients)))
}

/// Validate the logical SH layout without allocating its scene-wide output.
pub(crate) fn validate_chunk_bands(
    counts: &[usize],
    chunk_bands: &[BTreeMap<u8, DecodedStream>],
) -> Result<Option<usize>> {
    if counts.len() != chunk_bands.len() {
        return Err(Error::Malformed(format!(
            "{} chunk counts accompany {} SH band maps",
            counts.len(),
            chunk_bands.len()
        )));
    }
    let mut present: Vec<u8> = Vec::new();
    for bands in chunk_bands {
        for band in bands.keys() {
            if !present.contains(band) {
                present.push(*band);
            }
        }
    }
    present.sort_unstable();
    if present.is_empty() {
        return Ok(None);
    }
    let expected: Vec<u8> = (1..=present.len() as u8).collect();
    if present != expected {
        return Err(Error::Malformed(format!(
            "SH bands {present:?} do not form whole degrees starting at band 1"
        )));
    }

    let coefficients = band_range(*present.last().expect("non-empty"))
        .ok_or_else(|| Error::Malformed(format!("SH band {:?} is not 1, 2 or 3", present.last())))?
        .1;
    for (chunk, bands) in counts.iter().zip(chunk_bands.iter()) {
        let count = *chunk;
        for band in &present {
            let stream = bands.get(band).ok_or_else(|| {
                let mut have: Vec<u8> = bands.keys().copied().collect();
                have.sort_unstable();
                Error::Malformed(format!(
                    "a chunk carries SH bands {have:?}, the file carries {present:?}"
                ))
            })?;
            let (first, last) = band_range(*band)
                .ok_or_else(|| Error::Malformed(format!("SH band {band} is not 1, 2 or 3")))?;
            let width = last - first;
            if stream.channels != 3 * width || stream.count != count {
                return Err(Error::Malformed(format!(
                    "SH band {band} carries {} elements of {} channels; the chunk has {count} gaussians and the band is {} wide",
                    stream.count, stream.channels, 3 * width
                )));
            }
        }
    }
    Ok(Some(coefficients))
}
