// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Bounded payload validation for the `keyframe-delta` temporal model.
//!
//! Decoding a whole sequence is the wrong primitive for a validator: it retains every
//! reconstructed population and, on the byte-oriented C ABI, first requires the whole file.
//! These walkers use [`crate::Readable`], retain only the current state and GOP keyframe, and
//! report identity introductions to an edge-owned sink. The sink is deliberately supplied by
//! the caller: a complete validator can partition the lifetime identity set onto scratch storage
//! without putting filesystem I/O in the core or accumulating one set across all chunks.

use std::collections::{BTreeMap, BTreeSet};

use crate::keyframe_delta::State;
use crate::keyframe_delta_file::{
    check_keyframe_mu_t, compose_delta_chunk, open_indexed, ranged_framing,
    ranged_front_matter_content, ranged_header, ranged_record, read_delta_entry,
    read_keyframe_entry,
};
use crate::opcode as op;
use crate::records as rec;
use crate::serialization::{Cursor, MAGIC, RECORD_HEADER_SIZE, STREAM_HEADER_SIZE};
use crate::stream::{decode_stream, DecodedStream};
use crate::{Error, Readable, Result};

/// The read path whose payload contract is being certified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidationMode {
    Streamed,
    Indexed,
}

/// A model-specific failure, with the record byte when one record caused it.
#[derive(Debug)]
pub struct ValidationFailure {
    pub error: Error,
    pub offset: Option<u64>,
}

impl ValidationFailure {
    fn new(error: Error, offset: Option<u64>) -> Self {
        Self { error, offset }
    }

    fn at(error: Error, offset: u64) -> Self {
        Self::new(error, Some(offset))
    }
}

/// Facts the caller needs to finish validation at its I/O edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ValidationSummary {
    /// The Header's lifetime distinct-identity claim.
    pub declared_gaussian_count: u64,
}

type ValidationResult<T> = std::result::Result<T, ValidationFailure>;
type BirthBands = BTreeMap<(i64, u8), Vec<i64>>;

struct LocatingReadable<'a, R: Readable + ?Sized> {
    inner: &'a mut R,
    last_record: Option<u64>,
    index_records: usize,
    pending_index: Option<(u64, u64)>,
    index_intervals: Vec<(u64, f64, f64)>,
    size: Option<u64>,
}

const MAX_INDEX_RECORD_BYTES: u64 = 4096;
const MAX_INDEX_ENTRIES: usize = 1 << 16;
const MAX_STATE_BYTES: u64 = crate::serialization::MAX_STREAM_BYTES;
const MAX_BAND_BYTES: u64 = MAX_STATE_BYTES + STREAM_HEADER_SIZE as u64 + 1;
const MAX_POPULATION: usize = 1 << 20;

impl<R: Readable + ?Sized> Readable for LocatingReadable<'_, R> {
    fn size(&mut self) -> Result<u64> {
        let size = self.inner.size()?;
        self.size = Some(size);
        Ok(size)
    }

    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        const FIXED_TAIL: u64 = RECORD_HEADER_SIZE as u64 + 20 + MAGIC.len() as u64;
        if self.size == offset.checked_add(length) && length == FIXED_TAIL {
            self.last_record = Some(offset);
        }
        if offset == 0 && length <= MAGIC.len() as u64 {
            self.last_record = Some(0);
        }
        let bytes = self.inner.read(offset, length)?;
        let consumed_index_content = if let Some((index_at, content_length)) = self.pending_index {
            if offset == index_at + RECORD_HEADER_SIZE as u64 && length == content_length {
                if let Ok(entry) = rec::ChunkIndexEntry::parse(&bytes) {
                    self.index_intervals.push((index_at, entry.t0, entry.t1));
                }
                self.pending_index = None;
                true
            } else {
                false
            }
        } else {
            false
        };
        if !consumed_index_content
            && length == RECORD_HEADER_SIZE as u64
            && matches!(
                bytes.first(),
                Some(&op::HEADER)
                    | Some(&op::QUANTIZATION)
                    | Some(&op::WINDOW_TABLE)
                    | Some(&op::CHUNK_INDEX)
            )
        {
            self.last_record = Some(offset);
        }
        if !consumed_index_content
            && length == RECORD_HEADER_SIZE as u64
            && bytes.first() == Some(&op::CHUNK_INDEX)
        {
            self.index_records += 1;
            let content_length = u64::from_le_bytes(bytes[1..].try_into().unwrap());
            if content_length > MAX_INDEX_RECORD_BYTES || self.index_records > MAX_INDEX_ENTRIES {
                return Err(Error::UnsupportedOperation(format!(
                    "indexed validation limits Chunk Index records to {MAX_INDEX_RECORD_BYTES} bytes and {MAX_INDEX_ENTRIES} entries; record {} declares {content_length} bytes",
                    self.index_records
                )));
            }
            self.pending_index = Some((offset, content_length));
        }
        Ok(bytes)
    }
}

fn indexed_timeline_failure_offset(index: &[(u64, f64, f64)]) -> Option<u64> {
    let mut ordered: Vec<_> = index.iter().collect();
    ordered.sort_by(|(_, a, _), (_, b, _)| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let first = ordered.first()?;
    if first.1 != 0.0 {
        return Some(first.0);
    }
    ordered.windows(2).find_map(|pair| {
        let previous_t1 = pair[0].2;
        let (at, t0, _) = pair[1];
        (previous_t1 != *t0).then_some(*at)
    })
}

fn check_state_content_length(at: u64, length: u64) -> Result<()> {
    if length > MAX_STATE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "state record at {at} declares {length} content bytes, past the {MAX_STATE_BYTES} byte validation ceiling"
        )));
    }
    Ok(())
}

fn check_band_content_length(at: u64, length: u64) -> Result<()> {
    if length > MAX_BAND_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "SH Band Stream at {at} declares {length} content bytes, past the {MAX_BAND_BYTES} byte validation ceiling"
        )));
    }
    Ok(())
}

fn check_population(at: u64, what: &str, count: usize) -> Result<()> {
    if count > MAX_POPULATION {
        return Err(Error::UnsupportedOperation(format!(
            "{what} at {at} declares {count} rows, past the {MAX_POPULATION} row validation ceiling"
        )));
    }
    Ok(())
}

fn check_interval(at: u64, what: &str, t0: f64, t1: f64) -> Result<()> {
    if !t0.is_finite() || t1.is_nan() || t1 == f64::NEG_INFINITY {
        return Err(Error::Malformed(format!(
            "{what} at {at} has interval [{t0}, {t1}); t0 must be finite and only a final t1 may be +Infinity"
        )));
    }
    if t1 < t0 {
        return Err(Error::Malformed(format!(
            "{what} at {at} has t1 ({t1}) before t0 ({t0})"
        )));
    }
    Ok(())
}

fn validate_header_declaration(header: &rec::Header) -> Result<()> {
    if header.temporal_model != "keyframe-delta" {
        return Err(Error::refused(
            crate::error::refusal::UNKNOWN_TEMPORAL_MODEL,
            crate::error::RefusalKind::UnsupportedModel,
            format!(
                "the Header declares temporal model '{}', which this reader does not implement (it implements keyframe-delta)",
                header.temporal_model
            ),
        ));
    }
    if header.sh_degree > 3 {
        return Err(Error::Malformed(format!(
            "the Header declares sh_degree {}; version 1 defines only degrees 0 through 3",
            header.sh_degree
        )));
    }
    if header.duration_sec.is_nan() || header.duration_sec < 0.0 {
        return Err(Error::Malformed(format!(
            "the Header declares duration_sec {}; a keyframe-delta timeline has a non-negative duration, optionally +Infinity for an open-ended final interval",
            header.duration_sec
        )));
    }
    Ok(())
}

fn validate_quantization_declaration(quantization: &rec::Quantization) -> Result<()> {
    crate::registry::check_quantization_scheme(&quantization.scheme)?;
    let origin = |i: usize| quantization.pos_origin.get(i).copied().unwrap_or(f64::NAN);
    for (name, value) in [
        ("pos_origin[0]", origin(0)),
        ("pos_origin[1]", origin(1)),
        ("pos_origin[2]", origin(2)),
        ("step_pos", quantization.step_pos),
        ("step_scale_log", quantization.step_scale_log),
        ("step_rot", quantization.step_rot),
        ("step_rgb", quantization.step_rgb),
        ("step_alpha", quantization.step_alpha),
        ("step_motion", quantization.step_motion),
        ("step_time", quantization.step_time),
        ("step_sigma_log", quantization.step_sigma_log),
    ] {
        if !value.is_finite() {
            return Err(Error::Malformed(format!(
                "Quantization {name} is {value}; every step and origin must be finite (section 5.3)"
            )));
        }
    }
    Ok(())
}

fn ranged_state_rows<R: Readable + ?Sized>(
    source: &mut R,
    at: u64,
    content_length: u64,
    opcode: u8,
) -> Result<usize> {
    const CHUNK_PREFIX: u64 = 8 + 8 + 4 + 4;
    const DELTA_PREFIX: u64 = 8 + 8 + 4 + 1 + 8 + 8 + 2 + 4 + 4 + 4;
    let prefix_length = if opcode == op::CHUNK {
        CHUNK_PREFIX
    } else {
        DELTA_PREFIX
    };
    if content_length < prefix_length {
        return Err(Error::Truncated(format!(
            "the {} record at {at} is too short for its fixed header prefix: it carries {content_length} bytes, expected at least {prefix_length}",
            op::name(opcode)
        )));
    }
    let content_at = at
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| Error::Truncated("state content offset overflows".into()))?;
    let prefix = source.read(content_at, prefix_length)?;
    let mut cursor = Cursor::new(&prefix);
    cursor.f64()?;
    cursor.f64()?;
    cursor.u32()?;
    if opcode == op::CHUNK {
        let count = cursor.u32()? as usize;
        check_population(at, "Chunk", count)?;
        return Ok(count);
    }
    cursor.u8()?;
    cursor.u64()?;
    cursor.u64()?;
    cursor.u16()?;
    let updates = cursor.u32()? as usize;
    let births = cursor.u32()? as usize;
    let deaths = cursor.u32()? as usize;
    for (name, count) in [
        ("update group", updates),
        ("birth group", births),
        ("death group", deaths),
    ] {
        check_population(at, name, count)?;
    }
    Ok(births)
}

fn introductions(current: Option<&State>, next: &State) -> Vec<i64> {
    let Some(current) = current else {
        return next.ids.clone();
    };
    let live: BTreeSet<i64> = current.ids.iter().copied().collect();
    next.ids
        .iter()
        .copied()
        .filter(|id| !live.contains(id))
        .collect()
}

fn emit_introductions<F>(ids: &[i64], at: u64, introduce: &mut F) -> ValidationResult<()>
where
    F: FnMut(u64, u32) -> Result<()>,
{
    for &id in ids {
        let signed = i32::try_from(id).map_err(|_| {
            ValidationFailure::at(
                Error::Malformed(format!(
                    "gaussian_id stream code {id} is outside the signed 32-bit wire domain defined by section 11.2"
                )),
                at,
            )
        })?;
        introduce(at, signed as u32).map_err(|error| ValidationFailure::at(error, at))?;
    }
    Ok(())
}

fn validate_band<R: Readable + ?Sized>(
    source: &mut R,
    at: u64,
    length: u64,
    expected_band: u8,
    count: usize,
) -> ValidationResult<DecodedStream> {
    let (opcode, content_length) = ranged_framing(source, at, Some(length))
        .map_err(|error| ValidationFailure::at(error, at))?;
    if opcode != op::SH_BAND_STREAM {
        return Err(ValidationFailure::at(
            Error::Malformed(format!(
                "the SH band range at {at} points at {}",
                op::name(opcode)
            )),
            at,
        ));
    }
    check_band_content_length(at, content_length)
        .map_err(|error| ValidationFailure::at(error, at))?;
    let content = source
        .read(at + RECORD_HEADER_SIZE as u64, content_length)
        .map_err(|error| ValidationFailure::at(error, at))?;
    validate_band_content(&content, at, expected_band, count)
        .map_err(|error| ValidationFailure::at(error, at))
}

fn ranged_band_label<R: Readable + ?Sized>(source: &mut R, at: u64, length: u64) -> Result<u8> {
    if length == 0 {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} has no band label"
        )));
    }
    Ok(source.read(at + RECORD_HEADER_SIZE as u64, 1)?[0])
}

fn validate_band_content(
    content: &[u8],
    at: u64,
    expected_band: u8,
    count: usize,
) -> Result<DecodedStream> {
    let mut cursor = Cursor::new(content);
    let band = cursor.u8()?;
    if band != expected_band {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} declares band {band}; the index names band {expected_band}"
        )));
    }
    if !(1..=3).contains(&band) {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} declares band {band}; only bands 1 through 3 are defined"
        )));
    }
    let expected_channels = 3 * (2 * band as usize + 1);
    let stream_head = cursor.rest().get(..STREAM_HEADER_SIZE).ok_or_else(|| {
        Error::Truncated(format!(
            "the SH Band Stream at {at} ends before its {STREAM_HEADER_SIZE}-byte stream header"
        ))
    })?;
    let attribute = stream_head[0];
    if attribute != op::SH_BAND_STREAM {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} declares inner attribute_id {attribute}; version 1 fixes it at {}",
            op::SH_BAND_STREAM
        )));
    }
    let channels = stream_head[4] as usize;
    if channels != expected_channels {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} for band {band} declares {channels} channels; band {band} requires {expected_channels}"
        )));
    }
    let (attribute, stream) = decode_stream(&mut cursor, Some(count))?;
    debug_assert_eq!(attribute, op::SH_BAND_STREAM);
    debug_assert_eq!(stream.channels, expected_channels);
    if stream.values.iter().any(|value| !(0..=255).contains(value)) {
        return Err(Error::Malformed(format!(
            "the SH Band Stream at {at} carries a coefficient code outside 0..255"
        )));
    }
    Ok(stream)
}

fn retain_live_birth_bands(bands: &mut BirthBands, state: &State) {
    let live: BTreeSet<i64> = state.ids.iter().copied().collect();
    bands.retain(|(id, _), _| live.contains(id));
}

fn check_repeated_birth_invariants(
    previous: Option<&State>,
    state: &State,
    births: &[i64],
    at: u64,
) -> Result<()> {
    let Some(previous) = previous else {
        return Ok(());
    };
    let wire_births: BTreeSet<i64> = births.iter().copied().collect();
    let previous_rows: BTreeMap<i64, usize> = previous
        .ids
        .iter()
        .enumerate()
        .filter(|(_, id)| wire_births.contains(id))
        .map(|(row, id)| (*id, row))
        .collect();
    for (state_row, id) in state.ids.iter().enumerate() {
        let Some(&previous_row) = previous_rows.get(id) else {
            continue;
        };
        for attribute in crate::keyframe_delta::GOP_INVARIANT {
            let same = match (previous.bins.get(&attribute), state.bins.get(&attribute)) {
                (Some(before), Some(after)) if before.channels == after.channels => {
                    let channels = before.channels;
                    before.values[previous_row * channels..(previous_row + 1) * channels]
                        == after.values[state_row * channels..(state_row + 1) * channels]
                }
                (None, None) => true,
                _ => false,
            };
            if !same {
                return Err(Error::Malformed(format!(
                    "gaussian_id {id} changes invariant attribute {attribute} in a repeated birth at byte {at}; sigma_t, flags, and window_index are fixed for its lifetime within a GOP"
                )));
            }
        }
    }
    Ok(())
}

fn remember_birth_band(
    seen: &mut BirthBands,
    births: &[i64],
    band: u8,
    values: &DecodedStream,
    at: u64,
) -> Result<()> {
    for (row, id) in births.iter().enumerate() {
        let coefficients = values.row(row);
        match seen.entry((*id, band)) {
            std::collections::btree_map::Entry::Vacant(entry) => {
                entry.insert(coefficients.to_vec());
            }
            std::collections::btree_map::Entry::Occupied(entry)
                if entry.get().as_slice() != coefficients =>
            {
                return Err(Error::Malformed(format!(
                    "SH band {band} for gaussian_id {id} changes at byte {at}; coefficients are fixed for its lifetime within a GOP (section 11.7)"
                )));
            }
            _ => {}
        }
    }
    Ok(())
}

fn finish_bands(owner: u64, rows: usize, degree: u8, bands: &mut Vec<u8>) -> ValidationResult<()> {
    let expected: Vec<u8> = if rows == 0 {
        Vec::new()
    } else {
        (1..=degree).collect()
    };
    let mut actual = std::mem::take(bands);
    actual.sort_unstable();
    if actual != expected {
        return Err(ValidationFailure::at(
            Error::Malformed(format!(
                "the state chunk at {owner} is followed by SH bands {actual:?}; its Header degree and {rows} coefficient rows require bands {expected:?}"
            )),
            owner,
        ));
    }
    Ok(())
}

fn validate_delta<R: Readable + ?Sized>(
    source: &mut R,
    entry: &rec::ChunkIndexEntry,
    ordinal: usize,
    current: Option<&(u64, u16, u32, State)>,
    keyframe: Option<&(u64, u32, State)>,
    windows: &[(f64, f64)],
) -> Result<(State, rec::DeltaChunkHeader, Vec<i64>)> {
    if entry.reference_offset >= entry.chunk_offset {
        return Err(Error::Malformed(format!(
            "delta index entry {ordinal} at {} references {}; a Delta Chunk must reference a physically earlier record",
            entry.chunk_offset, entry.reference_offset
        )));
    }
    let (reference_offset, reference_depth, reference_level, reference) = match entry.delta_mode {
        rec::DELTA_MODE_KEYFRAME => match keyframe {
            Some((offset, level, state)) if entry.reference_offset == *offset => {
                (*offset, 0, *level, state)
            }
            Some((offset, _, _)) => {
                return Err(Error::Malformed(format!(
                    "delta index entry {ordinal} uses keyframe mode but references {}; its GOP keyframe is at {offset}",
                    entry.reference_offset
                )))
            }
            None => return Err(Error::Malformed("a delta appears before its GOP keyframe".into())),
        },
        rec::DELTA_MODE_CHAINED => match current {
            Some((offset, depth, level, state)) if entry.reference_offset == *offset => {
                (*offset, *depth, *level, state)
            }
            Some((offset, _, _, _)) => {
                return Err(Error::Malformed(format!(
                    "delta index entry {ordinal} uses chained mode but references {}; the immediately preceding state is at {offset}",
                    entry.reference_offset
                )))
            }
            None => return Err(Error::Malformed("a delta appears before any preceding state".into())),
        },
        mode => {
            return Err(Error::Malformed(format!(
                "delta index entry {ordinal} declares delta_mode {mode}; only 0 (keyframe) and 1 (chained) are defined"
            )))
        }
    };
    let expected_depth = reference_depth.checked_add(1).ok_or_else(|| {
        Error::Malformed(format!(
            "the chain depth before delta index entry {ordinal} overflows u16"
        ))
    })?;
    if entry.depth != expected_depth {
        return Err(Error::Malformed(format!(
            "delta index entry {ordinal} declares depth {}; its selected reference at {reference_offset} gives depth {expected_depth}",
            entry.depth
        )));
    }
    let (state, head, births) = read_delta_entry(source, entry, reference, windows)?;
    check_population(entry.chunk_offset, "composed state", state.count())?;
    if head.level != reference_level {
        return Err(Error::Malformed(format!(
            "delta index entry {ordinal} declares level {}; its reference at {reference_offset} declares level {reference_level}",
            head.level
        )));
    }
    let expected_keyframe = keyframe.map(|(offset, _, _)| *offset).unwrap_or(0);
    let working = head
        .update_count
        .checked_add(head.birth_count)
        .and_then(|n| n.checked_add(head.death_count));
    if !entry.extended
        || head.t0 != entry.t0
        || head.t1 != entry.t1
        || head.delta_mode != entry.delta_mode
        || head.reference_offset != entry.reference_offset
        || head.keyframe_offset != entry.keyframe_offset
        || head.depth != entry.depth
        || head.keyframe_offset != expected_keyframe
        || working != Some(entry.gaussian_count)
    {
        return Err(Error::Malformed(format!(
            "delta index entry {ordinal} disagrees with its Delta Chunk header on its interval, mode, reference, keyframe, depth, or group count"
        )));
    }
    if entry.live_count != state.count() as u64 {
        return Err(Error::Malformed(format!(
            "delta index entry {ordinal} declares {} live gaussians; composition reconstructs {}",
            entry.live_count,
            state.count()
        )));
    }
    Ok((state, head, births))
}

/// Require the summary's band ranges to be exactly the physical consecutive SH records
/// following each state record. Following only the index cannot discover an omitted physical
/// band or a range borrowed from another state.
fn validate_index_band_ownership<R: Readable + ?Sized>(
    source: &mut R,
    index: &[rec::ChunkIndexEntry],
    sh_degree: u8,
) -> ValidationResult<()> {
    let size = source
        .size()
        .map_err(|error| ValidationFailure::new(error, None))?;
    let mut indexed = std::collections::BTreeMap::new();
    for entry in index {
        if indexed.insert(entry.chunk_offset, entry).is_some() {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "two chunk index entries name the state chunk at {}",
                    entry.chunk_offset
                )),
                entry.chunk_offset,
            ));
        }
    }
    let mut seen = BTreeSet::new();
    let mut owner: Option<(u64, usize)> = None;
    let mut following: Vec<(u8, u64, u64)> = Vec::new();

    let finish = |owner: &mut Option<(u64, usize)>,
                  following: &mut Vec<(u8, u64, u64)>,
                  seen: &mut BTreeSet<u64>|
     -> ValidationResult<()> {
        let Some((at, rows)) = owner.take() else {
            return Ok(());
        };
        let entry = indexed.get(&at).ok_or_else(|| {
            ValidationFailure::at(
                Error::Malformed(format!(
                    "the state chunk at {at} is not named by the Chunk Index"
                )),
                at,
            )
        })?;
        let mut declared = entry.bands.clone();
        declared.sort_unstable();
        following.sort_unstable();
        if declared != *following {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "the chunk index entry at {at} declares SH band ranges {declared:?}; the physical records following that chunk are {following:?}"
                )),
                at,
            ));
        }
        let mut bands: Vec<u8> = following.iter().map(|(band, _, _)| *band).collect();
        let expected: Vec<u8> = if rows == 0 {
            Vec::new()
        } else {
            (1..=sh_degree).collect()
        };
        bands.sort_unstable();
        if bands != expected {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "the state chunk at {at} is followed by SH bands {bands:?}; the Header declares degree {sh_degree}, requiring bands {expected:?}"
                )),
                at,
            ));
        }
        seen.insert(at);
        following.clear();
        Ok(())
    };

    let mut at = MAGIC.len() as u64;
    while at < size {
        if size - at == MAGIC.len() as u64 {
            let tail = source
                .read(at, MAGIC.len() as u64)
                .map_err(|error| ValidationFailure::new(error, Some(at)))?;
            if tail == MAGIC {
                break;
            }
        }
        let (opcode, length) =
            ranged_framing(source, at, None).map_err(|error| ValidationFailure::at(error, at))?;
        let total = (RECORD_HEADER_SIZE as u64)
            .checked_add(length)
            .ok_or_else(|| {
                ValidationFailure::at(Error::Truncated("record length overflows".into()), at)
            })?;
        match opcode {
            op::CHUNK | op::DELTA_CHUNK => {
                finish(&mut owner, &mut following, &mut seen)?;
                let rows = ranged_state_rows(source, at, length, opcode)
                    .map_err(|error| ValidationFailure::at(error, at))?;
                owner = Some((at, rows));
            }
            op::SH_BAND_STREAM => {
                let Some((owner_at, _)) = owner else {
                    return Err(ValidationFailure::at(
                        Error::Malformed(format!(
                            "SH Band Stream at byte {at} does not immediately follow a state chunk"
                        )),
                        at,
                    ));
                };
                let band = ranged_band_label(source, at, length)
                    .map_err(|error| ValidationFailure::at(error, at))?;
                if !(1..=sh_degree).contains(&band) {
                    return Err(ValidationFailure::at(
                        Error::Malformed(format!(
                            "the state chunk at {owner_at} is followed by SH band {band}; the Header declares degree {sh_degree}"
                        )),
                        at,
                    ));
                }
                if following.iter().any(|(seen, _, _)| *seen == band) {
                    return Err(ValidationFailure::at(
                        Error::Malformed(format!(
                            "the state chunk at {owner_at} is followed by SH band {band} more than once"
                        )),
                        at,
                    ));
                }
                following.push((band, at, total));
            }
            op::HEADER => {
                finish(&mut owner, &mut following, &mut seen)?;
                let parsed = ranged_header(source, at + RECORD_HEADER_SIZE as u64, length)
                    .map_err(|error| ValidationFailure::at(error, at))?;
                validate_header_declaration(&parsed)
                    .map_err(|error| ValidationFailure::at(error, at))?;
            }
            op::QUANTIZATION => {
                finish(&mut owner, &mut following, &mut seen)?;
                let content = ranged_front_matter_content(
                    source,
                    at + RECORD_HEADER_SIZE as u64,
                    length,
                    "Quantization",
                )
                .map_err(|error| ValidationFailure::at(error, at))?;
                let parsed = rec::Quantization::parse(&content)
                    .map_err(|error| ValidationFailure::at(error, at))?;
                validate_quantization_declaration(&parsed)
                    .map_err(|error| ValidationFailure::at(error, at))?;
            }
            op::WINDOW_TABLE => {
                finish(&mut owner, &mut following, &mut seen)?;
                let content = ranged_front_matter_content(
                    source,
                    at + RECORD_HEADER_SIZE as u64,
                    length,
                    "Window Table",
                )
                .map_err(|error| ValidationFailure::at(error, at))?;
                rec::WindowTable::parse(&content)
                    .map_err(|error| ValidationFailure::at(error, at))?;
            }
            _ => finish(&mut owner, &mut following, &mut seen)?,
        }
        at = at.checked_add(total).ok_or_else(|| {
            ValidationFailure::at(Error::Truncated("record walk offset overflows".into()), at)
        })?;
    }
    finish(&mut owner, &mut following, &mut seen)?;
    for entry in index {
        if !seen.contains(&entry.chunk_offset) {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "the chunk index entry at {} does not name a physical state chunk",
                    entry.chunk_offset
                )),
                entry.chunk_offset,
            ));
        }
    }
    Ok(())
}

fn validate_indexed<R, F>(source: &mut R, introduce: &mut F) -> ValidationResult<ValidationSummary>
where
    R: Readable + ?Sized,
    F: FnMut(u64, u32) -> Result<()>,
{
    let mut located = LocatingReadable {
        inner: source,
        last_record: None,
        index_records: 0,
        pending_index: None,
        index_intervals: Vec::new(),
        size: None,
    };
    let sequence = open_indexed(&mut located).map_err(|error| {
        // `open_indexed` checks the timeline only after every index record parsed. If one
        // entry itself failed, its framing byte is the diagnosis; an earlier gap is merely
        // a second fault the reader has not reached yet.
        let index_complete = located.index_records == located.index_intervals.len();
        let offset = if index_complete {
            indexed_timeline_failure_offset(&located.index_intervals).or(located.last_record)
        } else {
            located.last_record
        };
        ValidationFailure::new(error, offset)
    })?;
    if sequence.index.is_empty() {
        return Err(ValidationFailure::new(
            Error::UnsupportedOperation(
                "the indexed keyframe-delta validation path cannot certify a file with no Chunk Index"
                    .into(),
            ),
            None,
        ));
    }
    validate_index_band_ownership(source, &sequence.index, sequence.header.sh_degree)?;
    let declared_gaussian_count = sequence.header.gaussian_count;
    let mut ordered: Vec<(usize, &rec::ChunkIndexEntry)> =
        sequence.index.iter().enumerate().collect();
    ordered.sort_by_key(|(_, entry)| entry.chunk_offset);
    let mut current: Option<(u64, u16, u32, State)> = None;
    let mut keyframe: Option<(u64, u32, State)> = None;
    let mut previous_t1: Option<f64> = None;
    let mut birth_bands = BirthBands::new();

    for (ordinal, entry) in ordered {
        let at = entry.chunk_offset;
        let content_length = entry
            .chunk_length
            .checked_sub(RECORD_HEADER_SIZE as u64)
            .ok_or_else(|| {
                ValidationFailure::at(
                    Error::Malformed("an indexed state range is shorter than its framing".into()),
                    at,
                )
            })?;
        check_state_content_length(at, content_length)
            .map_err(|error| ValidationFailure::at(error, at))?;
        check_interval(at, &format!("index entry {ordinal}"), entry.t0, entry.t1)
            .map_err(|error| ValidationFailure::at(error, at))?;
        match previous_t1 {
            None if entry.t0 != 0.0 => {
                return Err(ValidationFailure::at(
                    Error::Malformed(format!(
                        "the physically first state record starts at {}; it must start at 0",
                        entry.t0
                    )),
                    at,
                ));
            }
            Some(end) if end != entry.t0 => {
                return Err(ValidationFailure::at(
                    Error::Malformed(format!(
                        "physical state records do not tile: the previous state ends at {end} and the record at {at} starts at {}",
                        entry.t0
                    )),
                    at,
                ));
            }
            _ => {}
        }
        previous_t1 = Some(entry.t1);
        let (band_count, birth_ids) = if entry.kind == 0 {
            let (state, head) =
                read_keyframe_entry(source, entry, &sequence.quantization, &sequence.windows)
                    .map_err(|error| ValidationFailure::at(error, at))?;
            if !entry.extended
                || head.t0 != entry.t0
                || head.t1 != entry.t1
                || head.count != entry.gaussian_count
                || entry.keyframe_offset != entry.chunk_offset
                || entry.depth != 0
                || entry.delta_mode != 0
                || entry.reference_offset != 0
            {
                return Err(ValidationFailure::at(
                    Error::Malformed(format!(
                        "keyframe index entry {ordinal} disagrees with its Chunk: index interval [{}, {}), count {}, keyframe offset {}, depth {}, delta mode {}, reference {}; record interval [{}, {}), count {}",
                        entry.t0,
                        entry.t1,
                        entry.gaussian_count,
                        entry.keyframe_offset,
                        entry.depth,
                        entry.delta_mode,
                        entry.reference_offset,
                        head.t0,
                        head.t1,
                        head.count
                    )),
                    at,
                ));
            }
            if entry.live_count != state.count() as u64 {
                return Err(ValidationFailure::at(
                    Error::Malformed(format!(
                        "keyframe index entry {ordinal} declares {} live gaussians; its Chunk reconstructs {}",
                        entry.live_count,
                        state.count()
                    )),
                    at,
                ));
            }
            let ids = introductions(current.as_ref().map(|(_, _, _, state)| state), &state);
            emit_introductions(&ids, at, introduce)?;
            birth_bands.clear();
            keyframe = Some((entry.chunk_offset, head.level, state.clone()));
            current = Some((entry.chunk_offset, 0, head.level, state));
            (head.count as usize, Vec::new())
        } else if entry.kind == 1 {
            let (state, head, births) = validate_delta(
                source,
                entry,
                ordinal,
                current.as_ref(),
                keyframe.as_ref(),
                &sequence.windows,
            )
            .map_err(|error| ValidationFailure::at(error, at))?;
            check_repeated_birth_invariants(
                current.as_ref().map(|(_, _, _, state)| state),
                &state,
                &births,
                at,
            )
            .map_err(|error| ValidationFailure::at(error, at))?;
            // In keyframe-reference mode, a gaussian born after the GOP keyframe appears in
            // every later delta's birth group. It is a lifetime introduction only the first
            // time it joins the timeline state, so compare composed populations rather than
            // forwarding the wire group.
            let ids = introductions(current.as_ref().map(|(_, _, _, state)| state), &state);
            emit_introductions(&ids, at, introduce)?;
            retain_live_birth_bands(&mut birth_bands, &state);
            current = Some((entry.chunk_offset, entry.depth, head.level, state));
            (head.birth_count as usize, births)
        } else {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "keyframe-delta index entry {ordinal} declares chunk kind {}; only 0 (Chunk) and 1 (Delta Chunk) are defined",
                    entry.kind
                )),
                at,
            ));
        };

        let expected: Vec<u8> = if band_count == 0 {
            Vec::new()
        } else {
            (1..=sequence.header.sh_degree).collect()
        };
        let mut actual: Vec<u8> = entry.bands.iter().map(|(band, _, _)| *band).collect();
        actual.sort_unstable();
        if actual != expected {
            return Err(ValidationFailure::at(
                Error::Malformed(format!(
                    "the state record at index entry {ordinal} has SH bands {actual:?}; its Header degree {} and {band_count} coefficient rows require exactly {expected:?}",
                    sequence.header.sh_degree
                )),
                at,
            ));
        }
        for &(band, band_at, length) in &entry.bands {
            let values = validate_band(source, band_at, length, band, band_count)?;
            remember_birth_band(&mut birth_bands, &birth_ids, band, &values, band_at)
                .map_err(|error| ValidationFailure::at(error, band_at))?;
        }
    }
    Ok(ValidationSummary {
        declared_gaussian_count,
    })
}

fn validate_streamed<R, F>(source: &mut R, introduce: &mut F) -> ValidationResult<ValidationSummary>
where
    R: Readable + ?Sized,
    F: FnMut(u64, u32) -> Result<()>,
{
    let size = source
        .size()
        .map_err(|error| ValidationFailure::new(error, None))?;
    let magic = source
        .read(0, (MAGIC.len() as u64).min(size))
        .map_err(|error| ValidationFailure::new(error, None))?;
    crate::serialization::check_magic(&magic)
        .map_err(|error| ValidationFailure::new(error, Some(0)))?;

    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut header: Option<rec::Header> = None;
    let mut quantization: Option<rec::Quantization> = None;
    let mut current: Option<(u64, u16, u32, State)> = None;
    let mut keyframe: Option<(u64, u32, State)> = None;
    let mut previous_t1: Option<f64> = None;
    let mut band_count: Option<usize> = None;
    let mut band_owner: Option<u64> = None;
    let mut bands: Vec<u8> = Vec::new();
    let mut band_births: Vec<i64> = Vec::new();
    let mut birth_bands = BirthBands::new();
    let mut at = MAGIC.len() as u64;

    while at < size {
        if size - at == MAGIC.len() as u64 {
            let tail = source
                .read(at, MAGIC.len() as u64)
                .map_err(|error| ValidationFailure::new(error, Some(at)))?;
            if tail == MAGIC {
                break;
            }
        }
        let (opcode, content_length) =
            ranged_framing(source, at, None).map_err(|error| ValidationFailure::at(error, at))?;
        if opcode != op::SH_BAND_STREAM {
            if let Some(owner) = band_owner.take() {
                finish_bands(
                    owner,
                    band_count.unwrap_or(0),
                    header.as_ref().map(|h| h.sh_degree).unwrap_or(0),
                    &mut bands,
                )?;
            }
        }
        let total = (RECORD_HEADER_SIZE as u64)
            .checked_add(content_length)
            .ok_or_else(|| {
                ValidationFailure::at(
                    Error::Truncated(format!("record length overflows at {at}")),
                    at,
                )
            })?;
        if matches!(opcode, op::CHUNK | op::DELTA_CHUNK) {
            check_state_content_length(at, content_length)
                .map_err(|error| ValidationFailure::at(error, at))?;
            ranged_state_rows(source, at, content_length, opcode)
                .map_err(|error| ValidationFailure::at(error, at))?;
        }
        if opcode == op::SH_BAND_STREAM {
            check_band_content_length(at, content_length)
                .map_err(|error| ValidationFailure::at(error, at))?;
        }
        let outcome: Result<()> = match opcode {
            op::HEADER => ranged_header(source, at + RECORD_HEADER_SIZE as u64, content_length)
                .and_then(|parsed| {
                    validate_header_declaration(&parsed)?;
                    if current.is_none() {
                        header = Some(parsed);
                    }
                    Ok(())
                }),
            op::QUANTIZATION => ranged_front_matter_content(
                source,
                at + RECORD_HEADER_SIZE as u64,
                content_length,
                "Quantization",
            )
            .and_then(|content| rec::Quantization::parse(&content))
            .and_then(|parsed| {
                validate_quantization_declaration(&parsed)?;
                if current.is_none() {
                    quantization = Some(parsed);
                }
                Ok(())
            }),
            op::WINDOW_TABLE => ranged_front_matter_content(
                source,
                at + RECORD_HEADER_SIZE as u64,
                content_length,
                "Window Table",
            )
            .and_then(|content| rec::WindowTable::parse(&content))
            .map(|table| {
                if current.is_none() {
                    windows = table.windows;
                }
            }),
            op::CHUNK => ranged_record(source, at, Some(total)).and_then(|(_, content)| {
                crate::keyframe_delta_file::decode_keyframe_chunk(&content, &windows).and_then(
                    |(state, head)| {
                        check_interval(at, "Chunk", head.t0, head.t1)?;
                        let quantization = quantization.as_ref().ok_or_else(|| {
                            Error::Malformed("a keyframe Chunk appears before Quantization".into())
                        })?;
                        check_keyframe_mu_t(&state, head.t0, quantization)?;
                        if previous_t1.is_none() && head.t0 != 0.0 {
                            return Err(Error::Malformed(format!(
                                "the state chunks start at {}; they tile the timeline from 0 (section 11.1)",
                                head.t0
                            )));
                        }
                        if let Some(previous) = previous_t1 {
                            if previous != head.t0 {
                                return Err(Error::Malformed(format!(
                                    "state chunks do not tile: the previous state ends at {previous} and this keyframe starts at {}",
                                    head.t0
                                )));
                            }
                        }
                        let ids = introductions(
                            current.as_ref().map(|(_, _, _, state)| state),
                            &state,
                        );
                        emit_introductions(&ids, at, introduce).map_err(|failure| failure.error)?;
                        previous_t1 = Some(head.t1);
                        band_count = Some(head.count as usize);
                        band_owner = Some(at);
                        band_births.clear();
                        birth_bands.clear();
                        keyframe = Some((at, head.level, state.clone()));
                        current = Some((at, 0, head.level, state));
                        Ok(())
                    },
                )
            }),
            op::DELTA_CHUNK => ranged_record(source, at, Some(total)).and_then(|(_, content)| {
                rec::parse_delta_chunk_records(&content).and_then(|(declared, _)| {
                    check_interval(at, "Delta Chunk", declared.t0, declared.t1)?;
                    if declared.reference_offset >= at {
                        return Err(Error::Malformed(format!(
                            "Delta Chunk at {at} references {}; a Delta Chunk must reference a physically earlier record",
                            declared.reference_offset
                        )));
                    }
                    if let Some(previous) = previous_t1 {
                        if previous != declared.t0 {
                            return Err(Error::Malformed(format!(
                                "state chunks do not tile: the previous state ends at {previous} and this delta starts at {}",
                                declared.t0
                            )));
                        }
                    } else {
                        return Err(Error::Malformed(
                            "a streamed keyframe-delta sequence begins with a Delta Chunk".into(),
                        ));
                    }
                    let (reference_depth, reference_level, reference) = match declared.delta_mode {
                        rec::DELTA_MODE_KEYFRAME => match &keyframe {
                            Some((offset, level, state)) if declared.reference_offset == *offset => {
                                (0, *level, state)
                            }
                            Some((offset, _, _)) => {
                                return Err(Error::Malformed(format!(
                                    "a keyframe-mode delta at {at} references {}; its GOP keyframe is at {offset}",
                                    declared.reference_offset
                                )))
                            }
                            None => {
                                return Err(Error::Malformed(
                                    "a delta appears before its GOP keyframe".into(),
                                ))
                            }
                        },
                        rec::DELTA_MODE_CHAINED => match &current {
                            Some((offset, depth, level, state))
                                if declared.reference_offset == *offset =>
                            {
                                (*depth, *level, state)
                            }
                            Some((offset, _, _, _)) => {
                                return Err(Error::Malformed(format!(
                                    "a chained delta at {at} references {}; the immediately preceding state is at {offset}",
                                    declared.reference_offset
                                )))
                            }
                            None => {
                                return Err(Error::Malformed(
                                    "a delta appears before any preceding state".into(),
                                ))
                            }
                        },
                        mode => {
                            return Err(Error::Malformed(format!(
                                "Delta Chunk at {at} declares delta_mode {mode}; only 0 and 1 are defined"
                            )))
                        }
                    };
                    let expected_depth = reference_depth.checked_add(1).ok_or_else(|| {
                        Error::Malformed("delta chain depth overflows u16".into())
                    })?;
                    let keyframe_offset =
                        keyframe.as_ref().map(|(offset, _, _)| *offset).unwrap_or(0);
                    if declared.depth != expected_depth
                        || declared.keyframe_offset != keyframe_offset
                        || declared.level != reference_level
                    {
                        return Err(Error::Malformed(format!(
                            "Delta Chunk at {at} declares depth {}, keyframe {}, and level {}; its reference requires depth {expected_depth}, keyframe {keyframe_offset}, and level {reference_level}",
                            declared.depth, declared.keyframe_offset, declared.level
                        )));
                    }
                    compose_delta_chunk(reference, &content, &windows).and_then(
                        |(state, head, births)| {
                            check_population(at, "composed state", state.count())?;
                            check_repeated_birth_invariants(
                                current.as_ref().map(|(_, _, _, state)| state),
                                &state,
                                &births,
                                at,
                            )?;
                            let ids = introductions(
                                current.as_ref().map(|(_, _, _, state)| state),
                                &state,
                            );
                            emit_introductions(&ids, at, introduce)
                                .map_err(|failure| failure.error)?;
                            previous_t1 = Some(head.t1);
                            band_count = Some(head.birth_count as usize);
                            band_owner = Some(at);
                            retain_live_birth_bands(&mut birth_bands, &state);
                            band_births = births;
                            current = Some((at, head.depth, head.level, state));
                            Ok(())
                        },
                    )
                })
            }),
            op::SH_BAND_STREAM => ranged_record(source, at, Some(total)).and_then(|(_, content)| {
                let count = band_count.ok_or_else(|| {
                    Error::Malformed(format!(
                        "an SH Band Stream at {at} appears before a state chunk"
                    ))
                })?;
                let band = *content.first().ok_or_else(|| {
                    Error::Malformed(format!("the SH Band Stream at {at} has no band label"))
                })?;
                let Some(owner) = band_owner else {
                    return Err(Error::Malformed(format!(
                        "an SH Band Stream at {at} has no immediately preceding state record"
                    )));
                };
                if bands.contains(&band) {
                    return Err(Error::Malformed(format!(
                        "the state chunk at {owner} is followed by SH band {band} more than once"
                    )));
                }
                let values = validate_band_content(&content, at, band, count)?;
                remember_birth_band(&mut birth_bands, &band_births, band, &values, at)?;
                bands.push(band);
                Ok(())
            }),
            _ => Ok(()),
        };
        outcome.map_err(|error| ValidationFailure::at(error, at))?;
        at = at.checked_add(total).ok_or_else(|| {
            ValidationFailure::at(Error::Truncated("record walk offset overflows".into()), at)
        })?;
    }

    if let Some(owner) = band_owner.take() {
        finish_bands(
            owner,
            band_count.unwrap_or(0),
            header.as_ref().map(|h| h.sh_degree).unwrap_or(0),
            &mut bands,
        )?;
    }

    let header = header.ok_or_else(|| {
        ValidationFailure::new(
            Error::Malformed("keyframe-delta file has no Header record".into()),
            None,
        )
    })?;
    if quantization.is_none() {
        return Err(ValidationFailure::new(
            Error::Malformed("keyframe-delta file has no Quantization record".into()),
            None,
        ));
    }
    match previous_t1 {
        Some(end) if end != header.duration_sec => {
            return Err(ValidationFailure::new(
                Error::Malformed(format!(
                    "the state chunks end at {end}; the Header declares a duration of {}, and they tile the whole of it (section 11.1)",
                    header.duration_sec
                )),
                current.as_ref().map(|(offset, _, _, _)| *offset),
            ));
        }
        None if header.duration_sec > 0.0 => {
            return Err(ValidationFailure::new(
                Error::Malformed(format!(
                    "the file has no state chunks; the Header declares a positive duration of {}, which state chunks must tile from 0 (section 11.1)",
                    header.duration_sec
                )),
                None,
            ));
        }
        _ => {}
    }
    Ok(ValidationSummary {
        declared_gaussian_count: header.gaussian_count,
    })
}

/// Validate every model-specific payload through one read path.
///
/// `introduce` is called once for every lifetime identity introduction, with the introducing
/// keyframe or delta record's byte offset and the identity. It may stream those pairs to
/// fixed-memory external storage; after success the caller must reject duplicates and compare the
/// distinct count with [`ValidationSummary::declared_gaussian_count`]. Keeping that operation
/// outside the core preserves the transport-only I/O boundary.
pub fn validate<R, F>(
    source: &mut R,
    mode: ValidationMode,
    mut introduce: F,
) -> ValidationResult<ValidationSummary>
where
    R: Readable + ?Sized,
    F: FnMut(u64, u32) -> Result<()>,
{
    match mode {
        ValidationMode::Streamed => validate_streamed(source, &mut introduce),
        ValidationMode::Indexed => validate_indexed(source, &mut introduce),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframe_delta_file::{write_sequence, KeyframeDeltaOptions, Sample};
    use crate::model::GaussianSet;
    use crate::serialization::{put_record, Records};
    use crate::stream::encode_stream;

    fn gaussian() -> GaussianSet {
        GaussianSet {
            positions: vec![0.0, 0.0, 0.0],
            scales: vec![0.1, 0.1, 0.1],
            rotations: vec![0.0, 0.0, 0.0, 1.0],
            colors: vec![0.5, 0.5, 0.5, 1.0],
            motions: vec![0.0, 0.0, 0.0],
            mu_t: vec![0.0],
            sigma_t: vec![0.2],
            win_lo: vec![0.0],
            win_hi: vec![2.0],
            ..Default::default()
        }
    }

    fn sequence() -> Vec<u8> {
        let gaussian = gaussian();
        write_sequence(
            &[
                Sample {
                    t0: 0.0,
                    ids: vec![7],
                    gaussians: gaussian.clone(),
                },
                Sample {
                    t0: 1.0,
                    ids: vec![7],
                    gaussians: gaussian,
                },
            ],
            2.0,
            &KeyframeDeltaOptions::default(),
        )
        .unwrap()
    }

    fn keyframe_reference_sequence() -> Vec<u8> {
        let samples = [
            Sample {
                ids: vec![7],
                gaussians: population(&[7]),
                ..Default::default()
            },
            Sample {
                t0: 1.0,
                ids: vec![7, 9],
                gaussians: population(&[7, 9]),
            },
            Sample {
                t0: 2.0,
                ids: vec![7, 9],
                gaussians: population(&[7, 9]),
            },
        ];
        write_sequence(
            &samples,
            3.0,
            &KeyframeDeltaOptions {
                delta_mode: rec::DELTA_MODE_KEYFRAME,
                ..Default::default()
            },
        )
        .unwrap()
    }

    fn population(ids: &[i64]) -> GaussianSet {
        let one = gaussian();
        let mut out = GaussianSet::default();
        for _ in ids {
            out.positions.extend_from_slice(&one.positions);
            out.scales.extend_from_slice(&one.scales);
            out.rotations.extend_from_slice(&one.rotations);
            out.colors.extend_from_slice(&one.colors);
            out.motions.extend_from_slice(&one.motions);
            out.mu_t.extend_from_slice(&one.mu_t);
            out.sigma_t.extend_from_slice(&one.sigma_t);
            out.win_lo.extend_from_slice(&one.win_lo);
            out.win_hi.extend_from_slice(&one.win_hi);
        }
        out
    }

    fn records(bytes: &[u8]) -> impl Iterator<Item = crate::serialization::RawRecord<'_>> {
        Records::new(bytes, MAGIC.len()).map(|record| record.unwrap())
    }

    fn record_offset(bytes: &[u8], opcode: u8) -> usize {
        records(bytes)
            .find(|record| record.opcode == opcode)
            .map(|record| record.offset)
            .unwrap_or_else(|| panic!("the fixture has no {} record", op::name(opcode)))
    }

    fn record_content(bytes: &[u8], opcode: u8) -> Vec<u8> {
        records(bytes)
            .find(|record| record.opcode == opcode)
            .unwrap_or_else(|| panic!("the fixture has no {} record", op::name(opcode)))
            .content
            .to_vec()
    }

    fn replace_record(bytes: &mut Vec<u8>, opcode: u8, replacement: &[u8]) -> usize {
        let (at, end) = records(bytes)
            .find(|record| record.opcode == opcode)
            .map(|record| {
                (
                    record.offset,
                    record.offset + RECORD_HEADER_SIZE + record.content.len(),
                )
            })
            .unwrap_or_else(|| panic!("the fixture has no {} record", op::name(opcode)));
        bytes.splice(at..end, replacement.iter().copied());
        at
    }

    fn empty_sequence() -> Vec<u8> {
        write_sequence(&[Sample::default()], 1.0, &KeyframeDeltaOptions::default()).unwrap()
    }

    fn failure(bytes: &[u8], mode: ValidationMode) -> ValidationFailure {
        validate(&mut crate::BytesReadable::new(bytes), mode, |_, _| Ok(())).unwrap_err()
    }

    fn invalid_both(bytes: &[u8], field: &str) {
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            assert!(failure(bytes, mode).error.to_string().contains(field));
        }
    }

    fn first_state_end(bytes: &[u8]) -> usize {
        records(bytes)
            .find(|record| matches!(record.opcode, op::CHUNK | op::DELTA_CHUNK))
            .map(|record| record.offset + RECORD_HEADER_SIZE + record.content.len())
            .expect("the fixture has a state record")
    }

    fn set_header_sh_degree(bytes: &mut [u8], degree: u8) {
        let header_at = record_offset(bytes, op::HEADER);
        let content_at = header_at + RECORD_HEADER_SIZE;
        let content_length = u64::from_le_bytes(
            bytes[header_at + 1..content_at]
                .try_into()
                .expect("record framing"),
        ) as usize;
        let mut cursor = Cursor::new(&bytes[content_at..content_at + content_length]);
        cursor.string().unwrap();
        cursor.string().unwrap();
        cursor.f64().unwrap();
        cursor.u64().unwrap();
        cursor.f64().unwrap();
        cursor.string().unwrap();
        cursor.f64s(6).unwrap();
        bytes[content_at + cursor.position()] = degree;
    }

    fn sh_band_record(attribute: u8, coefficient: i64) -> Vec<u8> {
        let stream = encode_stream(
            attribute,
            &[coefficient; 9],
            9,
            crate::codec::DEFLATE,
            6,
            true,
        )
        .unwrap();
        let mut content = vec![1];
        content.extend_from_slice(&stream);
        let mut record = Vec::new();
        put_record(&mut record, op::SH_BAND_STREAM, &content);
        record
    }

    struct Watched<'a> {
        inner: crate::BytesReadable<'a>,
        reported_size: Option<u64>,
        largest: u64,
        reads: Vec<(u64, u64)>,
    }

    impl Readable for Watched<'_> {
        fn size(&mut self) -> Result<u64> {
            self.reported_size.map_or_else(|| self.inner.size(), Ok)
        }

        fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
            self.largest = self.largest.max(length);
            self.reads.push((offset, length));
            self.inner.read(offset, length)
        }
    }

    #[test]
    fn both_paths_validate_without_reading_the_whole_resource() {
        let bytes = sequence();
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            let mut source = Watched {
                inner: crate::BytesReadable::new(&bytes),
                reported_size: None,
                largest: 0,
                reads: Vec::new(),
            };
            let mut ids = Vec::new();
            let summary = validate(&mut source, mode, |_, id| {
                ids.push(id);
                Ok(())
            })
            .unwrap();
            assert_eq!(summary.declared_gaussian_count, 1);
            assert_eq!(ids, [7]);
            assert!(source.largest < bytes.len() as u64);
        }
    }

    #[test]
    fn an_identity_sink_failure_names_the_state_record() {
        let bytes = sequence();
        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Indexed, |_, _| {
            Err(Error::Io(std::io::Error::other("scratch write failed")))
        })
        .unwrap_err();
        assert!(failure.offset.is_some());
        assert!(failure.error.to_string().contains("scratch write failed"));
    }

    #[test]
    fn keyframe_referenced_births_are_lifetime_introductions_only_once() {
        let bytes = keyframe_reference_sequence();
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            let mut source = crate::BytesReadable::new(&bytes);
            let mut ids = Vec::new();
            validate(&mut source, mode, |record_offset, id| {
                ids.push((record_offset, id));
                Ok(())
            })
            .unwrap();
            assert_eq!(
                ids.iter().map(|(_, id)| *id).collect::<Vec<_>>(),
                [7, 9],
                "{mode:?}"
            );
            assert_eq!(bytes[ids[0].0 as usize], op::CHUNK, "{mode:?}");
            assert_eq!(bytes[ids[1].0 as usize], op::DELTA_CHUNK, "{mode:?}");
        }
    }

    #[test]
    fn a_keyframe_identity_reappearing_after_death_is_reintroduced() {
        let samples = [
            Sample {
                t0: 0.0,
                ids: vec![7],
                gaussians: population(&[7]),
            },
            Sample {
                t0: 1.0,
                ids: Vec::new(),
                gaussians: GaussianSet::default(),
            },
            Sample {
                t0: 2.0,
                ids: vec![7],
                gaussians: population(&[7]),
            },
        ];
        let options = KeyframeDeltaOptions {
            delta_mode: rec::DELTA_MODE_KEYFRAME,
            ..Default::default()
        };
        let bytes = write_sequence(&samples, 3.0, &options).unwrap();
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            let mut source = crate::BytesReadable::new(&bytes);
            let mut ids = Vec::new();
            validate(&mut source, mode, |_, id| {
                ids.push(id);
                Ok(())
            })
            .unwrap();
            assert_eq!(ids, [7, 7], "{mode:?}");
        }
    }

    #[test]
    fn declarations_are_validated_even_when_no_state_has_rows() {
        let base = empty_sequence();
        let mut degree = base.clone();
        set_header_sh_degree(&mut degree, 4);
        invalid_both(&degree, "sh_degree");
        for duration_sec in [f64::NAN, f64::NEG_INFINITY, -1.0] {
            let mut bytes = base.clone();
            let mut header = rec::Header::parse(&record_content(&bytes, op::HEADER)).unwrap();
            header.duration_sec = duration_sec;
            replace_record(&mut bytes, op::HEADER, &header.encode(&[]));
            invalid_both(&bytes, "duration");
        }
        for (field, value) in [("pos_origin", f64::INFINITY), ("step_time", f64::NAN)] {
            let mut bytes = base.clone();
            let mut quant =
                rec::Quantization::parse(&record_content(&bytes, op::QUANTIZATION)).unwrap();
            if field == "pos_origin" {
                quant.pos_origin[1] = value
            } else {
                quant.step_time = value
            }
            replace_record(&mut bytes, op::QUANTIZATION, &quant.encode(&[]));
            invalid_both(&bytes, field);
        }
    }

    #[test]
    fn a_positive_infinite_duration_accepts_an_open_ended_final_state() {
        let mut bytes = empty_sequence();
        let mut header = rec::Header::parse(&record_content(&bytes, op::HEADER)).unwrap();
        header.duration_sec = f64::INFINITY;
        replace_record(&mut bytes, op::HEADER, &header.encode(&[]));

        let chunk_at = record_offset(&bytes, op::CHUNK) + RECORD_HEADER_SIZE;
        bytes[chunk_at + 8..chunk_at + 16].copy_from_slice(&f64::INFINITY.to_le_bytes());
        let index_at = record_offset(&bytes, op::CHUNK_INDEX) + RECORD_HEADER_SIZE;
        bytes[index_at + 8..index_at + 16].copy_from_slice(&f64::INFINITY.to_le_bytes());

        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            validate(&mut crate::BytesReadable::new(&bytes), mode, |_, _| Ok(())).unwrap();
        }
    }

    #[test]
    fn indexed_validation_checks_late_header_and_quantization_records() {
        for declaration in [op::HEADER, op::QUANTIZATION] {
            let mut bytes = empty_sequence();
            let replacement = if declaration == op::HEADER {
                let mut header = rec::Header::parse(&record_content(&bytes, op::HEADER)).unwrap();
                header.temporal_model = "future-model".into();
                header.encode(&[])
            } else {
                let mut quant =
                    rec::Quantization::parse(&record_content(&bytes, op::QUANTIZATION)).unwrap();
                quant.scheme = "future-grid".into();
                quant.encode(&[])
            };
            let at = replace_record(&mut bytes, op::STATISTICS, &replacement);
            let failure = failure(&bytes, ValidationMode::Indexed);
            assert_eq!(failure.offset, Some(at as u64));
            assert!(failure.error.refusal_code().is_some(), "{}", failure.error);
        }
        let mut bytes = empty_sequence();
        let at = record_offset(&bytes, op::HEADER);
        let mut header = rec::Header::parse(&record_content(&bytes, op::HEADER)).unwrap();
        header.temporal_model = "future-model".into();
        replace_record(&mut bytes, op::HEADER, &header.encode(&[]));
        assert_eq!(
            failure(&bytes, ValidationMode::Indexed).offset,
            Some(at as u64)
        );

        let mut bytes = empty_sequence();
        let at = record_offset(&bytes, op::CHUNK_INDEX);
        bytes[at + RECORD_HEADER_SIZE + 36..at + RECORD_HEADER_SIZE + 40]
            .copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(
            failure(&bytes, ValidationMode::Indexed).offset,
            Some(at as u64)
        );
    }

    #[test]
    fn indexed_validation_parses_late_window_tables() {
        let mut bytes = sequence();
        let at = record_offset(&bytes, op::STATISTICS);
        bytes[at] = op::WINDOW_TABLE;
        bytes[at + RECORD_HEADER_SIZE..at + RECORD_HEADER_SIZE + 4]
            .copy_from_slice(&u32::MAX.to_le_bytes());
        let failure = failure(&bytes, ValidationMode::Indexed);
        assert_eq!(failure.offset, Some(at as u64));
        assert!(failure.error.to_string().contains("truncated"));
    }

    #[test]
    fn indexed_validation_rejects_reversed_index_intervals() {
        let mut bytes = sequence();
        let delta_at = record_offset(&bytes, op::DELTA_CHUNK);
        let index_at = records(&bytes)
            .find(|record| {
                record.opcode == op::CHUNK_INDEX
                    && rec::ChunkIndexEntry::parse(record.content).unwrap().kind == 1
            })
            .unwrap()
            .offset;
        let t1 = 0.5f64.to_le_bytes();
        bytes[delta_at + RECORD_HEADER_SIZE + 8..delta_at + RECORD_HEADER_SIZE + 16]
            .copy_from_slice(&t1);
        bytes[index_at + RECORD_HEADER_SIZE + 8..index_at + RECORD_HEADER_SIZE + 16]
            .copy_from_slice(&t1);
        let mut header = rec::Header::parse(&record_content(&bytes, op::HEADER)).unwrap();
        header.duration_sec = 0.5;
        replace_record(&mut bytes, op::HEADER, &header.encode(&[]));
        let indexed_failure = failure(&bytes, ValidationMode::Indexed);
        assert_eq!(indexed_failure.offset, Some(delta_at as u64));
        assert!(indexed_failure
            .error
            .to_string()
            .contains("t1 (0.5) before t0 (1)"));

        let mut bytes = sequence();
        let states: Vec<_> = records(&bytes)
            .filter(|record| matches!(record.opcode, op::CHUNK | op::DELTA_CHUNK))
            .map(|record| record.offset)
            .collect();
        bytes[states[0] + RECORD_HEADER_SIZE + 8..states[0] + RECORD_HEADER_SIZE + 16]
            .copy_from_slice(&(-1.0f64).to_le_bytes());
        bytes[states[1] + RECORD_HEADER_SIZE..states[1] + RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&(-1.0f64).to_le_bytes());
        assert_eq!(
            failure(&bytes, ValidationMode::Streamed).offset,
            Some(states[0] as u64)
        );
    }

    #[test]
    fn ownership_reads_only_fixed_state_prefixes() {
        let bytes = sequence();
        let states: Vec<_> = records(&bytes)
            .filter(|record| matches!(record.opcode, op::CHUNK | op::DELTA_CHUNK))
            .map(|record| {
                (
                    (record.offset + RECORD_HEADER_SIZE) as u64,
                    if record.opcode == op::CHUNK { 24 } else { 51 },
                )
            })
            .collect();
        let mut source = Watched {
            inner: crate::BytesReadable::new(&bytes),
            reported_size: None,
            largest: 0,
            reads: Vec::new(),
        };
        validate(&mut source, ValidationMode::Indexed, |_, _| Ok(())).unwrap();
        for wanted in states {
            assert!(source.reads.contains(&wanted));
        }
    }

    #[test]
    fn indexed_validation_bounds_each_index_record_before_reading_it() {
        let mut bytes = sequence();
        let at = record_offset(&bytes, op::CHUNK_INDEX);
        let length = u64::from_le_bytes(bytes[at + 1..at + RECORD_HEADER_SIZE].try_into().unwrap());
        let added = (MAX_INDEX_RECORD_BYTES + 1 - length) as usize;
        bytes.splice(
            at + RECORD_HEADER_SIZE + length as usize..at + RECORD_HEADER_SIZE + length as usize,
            std::iter::repeat_n(0, added),
        );
        bytes[at + 1..at + RECORD_HEADER_SIZE]
            .copy_from_slice(&(MAX_INDEX_RECORD_BYTES + 1).to_le_bytes());
        let mut source = Watched {
            inner: crate::BytesReadable::new(&bytes),
            reported_size: None,
            largest: 0,
            reads: Vec::new(),
        };
        let failure = validate(&mut source, ValidationMode::Indexed, |_, _| Ok(())).unwrap_err();
        assert_eq!(failure.offset, Some(at as u64));
        assert!(failure
            .error
            .to_string()
            .contains("limits Chunk Index records"));
        assert!(source.largest < MAX_INDEX_RECORD_BYTES);
    }

    #[test]
    fn indexed_validation_bounds_accumulated_index_entries() {
        struct IndexHeaders;
        impl Readable for IndexHeaders {
            fn size(&mut self) -> Result<u64> {
                Ok(u64::MAX)
            }
            fn read(&mut self, _: u64, length: u64) -> Result<Vec<u8>> {
                assert_eq!(length, RECORD_HEADER_SIZE as u64);
                let mut bytes = vec![op::CHUNK_INDEX];
                bytes.extend_from_slice(&0u64.to_le_bytes());
                Ok(bytes)
            }
        }
        let mut source = IndexHeaders;
        let mut located = LocatingReadable {
            inner: &mut source,
            last_record: None,
            index_records: 0,
            pending_index: None,
            index_intervals: Vec::new(),
            size: None,
        };
        for at in 0..MAX_INDEX_ENTRIES {
            located.read(at as u64, RECORD_HEADER_SIZE as u64).unwrap();
        }
        let error = located
            .read(MAX_INDEX_ENTRIES as u64, RECORD_HEADER_SIZE as u64)
            .unwrap_err();
        assert!(error
            .to_string()
            .contains(&format!("{MAX_INDEX_ENTRIES} entries")));
    }

    #[test]
    fn streamed_validation_caps_state_content_before_reading_it() {
        let mut prefix = empty_sequence();
        let at = record_offset(&prefix, op::CHUNK);
        prefix.truncate(at + RECORD_HEADER_SIZE);
        prefix[at + 1..].copy_from_slice(&(MAX_STATE_BYTES + 1).to_le_bytes());
        let mut source = Watched {
            inner: crate::BytesReadable::new(&prefix),
            reported_size: Some(at as u64 + RECORD_HEADER_SIZE as u64 + MAX_STATE_BYTES + 1),
            largest: 0,
            reads: Vec::new(),
        };
        let failure = validate(&mut source, ValidationMode::Streamed, |_, _| Ok(())).unwrap_err();
        assert_eq!(failure.offset, Some(at as u64));
        assert!(failure.error.to_string().contains("validation ceiling"));
        assert!(source.largest < MAX_STATE_BYTES);
    }

    #[test]
    fn indexed_open_failure_preserves_the_footer_byte() {
        let mut bytes = empty_sequence();
        let at = bytes.len() - MAGIC.len() - (RECORD_HEADER_SIZE + 20);
        bytes[at + 1..at + RECORD_HEADER_SIZE].copy_from_slice(&19u64.to_le_bytes());
        assert_eq!(
            failure(&bytes, ValidationMode::Indexed).offset,
            Some(at as u64)
        );
        bytes[at + 1..at + RECORD_HEADER_SIZE].copy_from_slice(&20u64.to_le_bytes());
        bytes[at + RECORD_HEADER_SIZE..at + RECORD_HEADER_SIZE + 8]
            .copy_from_slice(&u64::MAX.to_le_bytes());
        assert_eq!(
            failure(&bytes, ValidationMode::Indexed).offset,
            Some(at as u64)
        );
    }

    #[test]
    fn opening_magic_failures_name_byte_zero() {
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            assert_eq!(failure(b"not-4dgs", mode).offset, Some(0), "{mode:?}");
        }
    }

    #[test]
    fn population_and_interval_limits_precede_state_decode() {
        let mut bytes = vec![op::CHUNK];
        bytes.extend_from_slice(&24u64.to_le_bytes());
        bytes.extend_from_slice(&0.0f64.to_le_bytes());
        bytes.extend_from_slice(&1.0f64.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&u32::MAX.to_le_bytes());
        let mut source = crate::BytesReadable::new(&bytes);
        let error = ranged_state_rows(&mut source, 0, 24, op::CHUNK).unwrap_err();
        assert!(error.to_string().contains("row validation ceiling"));
        assert!(check_interval(0, "Chunk", 0.0, f64::INFINITY).is_ok());
        assert!(check_interval(1, "Chunk", f64::INFINITY, f64::INFINITY).is_err());
        assert!(check_interval(1, "Chunk", 1.0, f64::NAN).is_err());
    }

    #[test]
    fn indexed_timeline_failures_name_the_offending_index_entry() {
        let mut bytes = keyframe_reference_sequence();
        let index_records: Vec<_> = records(&bytes)
            .filter(|record| record.opcode == op::CHUNK_INDEX)
            .map(|record| record.offset)
            .collect();
        assert_eq!(index_records.len(), 3);
        let second_content = index_records[1] + RECORD_HEADER_SIZE;
        bytes[second_content..second_content + 8].copy_from_slice(&1.25f64.to_le_bytes());

        let gap_failure = failure(&bytes, ValidationMode::Indexed);
        assert_eq!(gap_failure.offset, Some(index_records[1] as u64));
        assert!(gap_failure.error.to_string().contains("leave a gap"));

        // The same earlier gap must not steal attribution from a later record that fails
        // before `open_indexed` reaches its timeline checks.
        let third_content = index_records[2] + RECORD_HEADER_SIZE;
        bytes[third_content + 36..third_content + 40].copy_from_slice(&u32::MAX.to_le_bytes());
        let failure = failure(&bytes, ValidationMode::Indexed);
        assert_eq!(failure.offset, Some(index_records[2] as u64));
        assert!(failure.error.to_string().contains("truncated"));
    }

    #[test]
    fn band_ranges_are_bounded_before_content_reads() {
        let length = MAX_BAND_BYTES + 1;
        let mut bytes = vec![op::SH_BAND_STREAM];
        bytes.extend_from_slice(&length.to_le_bytes());
        bytes.push(1);
        let mut source = Watched {
            inner: crate::BytesReadable::new(&bytes),
            reported_size: Some(RECORD_HEADER_SIZE as u64 + length),
            largest: 0,
            reads: Vec::new(),
        };
        assert_eq!(ranged_band_label(&mut source, 0, length).unwrap(), 1);
        let failure =
            validate_band(&mut source, 0, RECORD_HEADER_SIZE as u64 + length, 1, 1).unwrap_err();
        assert_eq!(failure.offset, Some(0));
        assert!(failure.error.to_string().contains("validation ceiling"));
        assert!(source.largest <= RECORD_HEADER_SIZE as u64);
    }

    #[test]
    fn sh_channel_counts_are_checked_before_payload_decode() {
        let mut content = vec![1, op::SH_BAND_STREAM, 1, crate::stream::MODE_RAW, 9, 255];
        content.extend_from_slice(&(MAX_POPULATION as u32).to_le_bytes());
        content.extend_from_slice(&0u64.to_le_bytes());
        let error = validate_band_content(&content, 41, 1, MAX_POPULATION).unwrap_err();
        assert!(error.to_string().contains("declares 255 channels"));
        assert!(error.to_string().contains("requires 9"));
    }

    #[test]
    fn indexed_validation_rejects_descending_physical_state_order() {
        let second = Sample {
            t0: 1.0,
            ..Default::default()
        };
        let options = KeyframeDeltaOptions {
            keyframe_every: 1,
            ..Default::default()
        };
        let mut bytes = write_sequence(&[Sample::default(), second], 2.0, &options).unwrap();
        let states: Vec<_> = records(&bytes)
            .filter(|record| record.opcode == op::CHUNK)
            .map(|record| {
                (
                    record.offset,
                    record.offset + RECORD_HEADER_SIZE + record.content.len(),
                )
            })
            .collect();
        assert_eq!(states[0].1 - states[0].0, states[1].1 - states[1].0);
        let first = bytes[states[0].0..states[0].1].to_vec();
        let second = bytes[states[1].0..states[1].1].to_vec();
        bytes[states[0].0..states[0].1].copy_from_slice(&second);
        bytes[states[1].0..states[1].1].copy_from_slice(&first);
        let entries: Vec<_> = records(&bytes)
            .filter(|record| record.opcode == op::CHUNK_INDEX)
            .map(|record| {
                (
                    record.offset,
                    rec::ChunkIndexEntry::parse(record.content).unwrap(),
                )
            })
            .collect();
        for (offset, entry) in entries {
            let interval = if entry.chunk_offset == states[0].0 as u64 {
                (1.0f64, 2.0f64)
            } else {
                (0.0f64, 1.0f64)
            };
            let content = offset + RECORD_HEADER_SIZE;
            bytes[content..content + 8].copy_from_slice(&interval.0.to_le_bytes());
            bytes[content + 8..content + 16].copy_from_slice(&interval.1.to_le_bytes());
        }
        let failure = failure(&bytes, ValidationMode::Indexed);
        assert_eq!(failure.offset, Some(states[0].0 as u64));
        assert!(failure.error.to_string().contains("physically first"));
    }

    #[test]
    fn repeated_keyframe_births_keep_their_sh_coefficients() {
        let mut bytes = keyframe_reference_sequence();
        set_header_sh_degree(&mut bytes, 1);
        let ends: Vec<_> = records(&bytes)
            .filter(|record| matches!(record.opcode, op::CHUNK | op::DELTA_CHUNK))
            .map(|record| record.offset + RECORD_HEADER_SIZE + record.content.len())
            .collect();
        for (end, coefficient) in ends.into_iter().zip([0, 0, 1]).rev() {
            bytes.splice(end..end, sh_band_record(op::SH_BAND_STREAM, coefficient));
        }
        let band_at = records(&bytes)
            .filter(|record| record.opcode == op::SH_BAND_STREAM)
            .nth(2)
            .unwrap()
            .offset;
        let failure = failure(&bytes, ValidationMode::Streamed);
        assert_eq!(failure.offset, Some(band_at as u64));
        assert!(failure.error.to_string().contains("fixed for its lifetime"));
    }

    #[test]
    fn repeated_keyframe_births_keep_their_invariant_bins() {
        let mut changed = population(&[7, 9]);
        changed.sigma_t[1] = 2.0;
        let samples = [
            Sample {
                ids: vec![7],
                gaussians: population(&[7]),
                ..Default::default()
            },
            Sample {
                t0: 1.0,
                ids: vec![7, 9],
                gaussians: population(&[7, 9]),
            },
            Sample {
                t0: 2.0,
                ids: vec![7, 9],
                gaussians: changed,
            },
        ];
        let bytes = write_sequence(
            &samples,
            3.0,
            &KeyframeDeltaOptions {
                delta_mode: rec::DELTA_MODE_KEYFRAME,
                ..Default::default()
            },
        )
        .unwrap();
        let third = records(&bytes)
            .filter(|record| record.opcode == op::DELTA_CHUNK)
            .nth(1)
            .unwrap()
            .offset;
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            let failure = failure(&bytes, mode);
            assert_eq!(failure.offset, Some(third as u64), "{mode:?}");
            assert!(
                failure.error.to_string().contains("invariant attribute"),
                "{mode:?}: {}",
                failure.error
            );
        }
    }

    #[test]
    fn gaussian_identity_codes_reinterpret_the_full_u32_domain() {
        let bytes = write_sequence(
            &[Sample {
                ids: vec![-1],
                gaussians: gaussian(),
                ..Default::default()
            }],
            1.0,
            &KeyframeDeltaOptions::default(),
        )
        .unwrap();
        for mode in [ValidationMode::Streamed, ValidationMode::Indexed] {
            let mut ids = Vec::new();
            validate(&mut crate::BytesReadable::new(&bytes), mode, |_, id| {
                ids.push(id);
                Ok(())
            })
            .unwrap();
            assert_eq!(ids, [u32::MAX], "{mode:?}");
        }

        let mut emitted = Vec::new();
        let failure = emit_introductions(&[i64::from(i32::MAX) + 1], 17, &mut |_, id| {
            emitted.push(id);
            Ok(())
        })
        .unwrap_err();
        assert_eq!(failure.offset, Some(17));
        assert!(failure
            .error
            .to_string()
            .contains("signed 32-bit wire domain"));
        assert!(emitted.is_empty());
    }

    #[test]
    fn an_sh_band_must_use_the_fixed_inner_attribute() {
        let record = sh_band_record(op::ATTRIBUTE_STREAM, 0);
        let mut source = crate::BytesReadable::new(&record);
        let failure = validate_band(&mut source, 0, record.len() as u64, 1, 1).unwrap_err();
        assert!(
            failure.error.to_string().contains("inner attribute_id 6"),
            "{}",
            failure.error
        );
        assert_eq!(failure.offset, Some(0));
    }

    #[test]
    fn sh_coefficient_codes_are_unsigned_bytes() {
        for coefficient in [-1, 256] {
            let record = sh_band_record(op::SH_BAND_STREAM, coefficient);
            let mut source = crate::BytesReadable::new(&record);
            let failure = validate_band(&mut source, 0, record.len() as u64, 1, 1).unwrap_err();
            assert!(
                failure
                    .error
                    .to_string()
                    .contains("coefficient code outside 0..255"),
                "coefficient {coefficient}: {}",
                failure.error
            );
        }
    }

    #[test]
    fn constant_sh_bands_expose_every_declared_birth_row_without_expansion() {
        let stream = encode_stream(
            op::SH_BAND_STREAM,
            &[19; 18],
            9,
            crate::codec::DEFLATE,
            6,
            true,
        )
        .unwrap();
        assert_eq!(stream[2], crate::stream::MODE_CONST);
        let mut content = vec![1];
        content.extend_from_slice(&stream);
        let values = validate_band_content(&content, 41, 1, 2).unwrap();
        assert!(values.constant);
        let mut bands = BirthBands::new();
        remember_birth_band(&mut bands, &[7, 9], 1, &values, 41).unwrap();
        assert_eq!(bands[&(7, 1)], vec![19; 9]);
        assert_eq!(bands[&(9, 1)], vec![19; 9]);
    }

    #[test]
    fn an_unsupported_sh_codec_is_a_named_refusal() {
        let mut record = sh_band_record(op::SH_BAND_STREAM, 0);
        record[RECORD_HEADER_SIZE + 1 + 3] = 9;
        let mut source = crate::BytesReadable::new(&record);
        let failure = validate_band(&mut source, 0, record.len() as u64, 1, 1).unwrap_err();
        assert_eq!(
            failure.error.refusal_code(),
            Some(crate::error::refusal::UNKNOWN_STREAM_CODEC)
        );
        assert_eq!(failure.offset, Some(0));
    }

    #[test]
    fn indexed_validation_refuses_a_file_with_no_index() {
        let mut bytes = sequence();
        let footer_at = bytes.len() - MAGIC.len() - (RECORD_HEADER_SIZE + 20);
        assert_eq!(bytes[footer_at], op::FOOTER);
        let summary_start_at = footer_at + RECORD_HEADER_SIZE;
        bytes[summary_start_at..summary_start_at + 8].fill(0);

        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Indexed, |_, _| Ok(())).unwrap_err();
        assert!(matches!(failure.error, Error::UnsupportedOperation(_)));
        assert!(failure.error.to_string().contains("no Chunk Index"));
    }

    #[test]
    fn indexed_validation_rejects_an_orphan_physical_band() {
        let mut bytes = sequence();
        let window_at = record_offset(&bytes, op::WINDOW_TABLE);
        // Keep every range stable while turning an existing front-matter record into an
        // orphan SH record. Ownership is a framing property, so its body need not decode.
        bytes[window_at] = op::SH_BAND_STREAM;

        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Indexed, |_, _| Ok(())).unwrap_err();
        assert_eq!(failure.offset, Some(window_at as u64));
        assert!(
            failure
                .error
                .to_string()
                .contains("does not immediately follow a state chunk"),
            "{}",
            failure.error
        );
    }

    #[test]
    fn streamed_validation_requires_every_declared_band() {
        let mut bytes = sequence();
        set_header_sh_degree(&mut bytes, 1);

        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Streamed, |_, _| Ok(())).unwrap_err();
        assert!(
            failure.error.to_string().contains("require bands [1]"),
            "{}",
            failure.error
        );
    }

    #[test]
    fn streamed_validation_rejects_a_duplicate_band() {
        let mut bytes = sequence();
        set_header_sh_degree(&mut bytes, 1);
        let state_end = first_state_end(&bytes);
        let band = sh_band_record(op::SH_BAND_STREAM, 0);
        let repeated: Vec<u8> = band.iter().chain(&band).copied().collect();
        bytes.splice(state_end..state_end, repeated);

        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Streamed, |_, _| Ok(())).unwrap_err();
        assert!(
            failure.error.to_string().contains("band 1 more than once"),
            "{}",
            failure.error
        );
    }

    #[test]
    fn streamed_validation_rejects_a_band_above_degree_zero() {
        let mut bytes = sequence();
        let state_end = first_state_end(&bytes);
        let band = sh_band_record(op::SH_BAND_STREAM, 0);
        bytes.splice(state_end..state_end, band);

        let mut source = crate::BytesReadable::new(&bytes);
        let failure = validate(&mut source, ValidationMode::Streamed, |_, _| Ok(())).unwrap_err();
        assert!(
            failure.error.to_string().contains("require bands []"),
            "{}",
            failure.error
        );
    }
}
