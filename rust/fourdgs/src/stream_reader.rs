// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Streamed reading: front to back, no seeking.
//!
//! Works on a pipe, on a file with no index, and on a file that was truncated mid-write —
//! records are length-prefixed, so everything complete before the cut is recoverable. That
//! makes this the right mode for validation, conversion and archival scans, and the wrong
//! one for scrubbing.
//!
//! The source is an `io::Read` rather than a byte slice on purpose: nothing here needs the
//! whole file resident, so nothing here asks for it. A record's content is read into a
//! buffer that grows only as bytes actually arrive, so a crafted length cannot make this
//! allocate what the resource does not contain.

use std::collections::BTreeMap;
use std::io::{self, BufRead, Read};
use std::path::Path;

use crate::chunk::{decode_streams_with_limit, window_table_or_default, DecodedChunk};
use crate::error::{Error, Result};
use crate::model::{AudioSource, GaussianSet};
use crate::opcode as op;
use crate::records as rec;
use crate::serialization::{Crc32, Cursor, MAGIC, MAX_STREAM_BYTES, RECORD_HEADER_SIZE};
use crate::sh::merge_chunk_bands;
use crate::stream::{decode_stream_with_limit, DecodedStream};

/// What a streamed read may be told to do differently.
#[derive(Debug, Clone, Copy)]
pub struct ReadOptions {
    /// Keep what was decoded before a cut instead of refusing the file. A file cut short
    /// mid-write is common and recoverable; a partial record is never interpreted.
    pub recover_truncated: bool,
    /// Highest SH band to decode. A streamed reader cannot decline the bytes — it has
    /// already been sent them — but it can decline the work.
    pub max_sh_band: u8,
}

impl Default for ReadOptions {
    fn default() -> Self {
        ReadOptions {
            recover_truncated: true,
            max_sh_band: 3,
        }
    }
}

/// A whole file, decoded.
#[derive(Debug, Clone, Default)]
pub struct Scene {
    pub header: rec::Header,
    /// The grids and the error bounds the file declares. A consumer that wants to know how
    /// wrong a value may be has to be able to reach them.
    pub quantization: rec::Quantization,
    pub windows: Vec<(f64, f64)>,
    pub gaussians: GaussianSet,
    pub duration_sec: f64,
    /// Empty when the scene has no audio, which is the common case and not an error.
    pub audio_sources: Vec<AudioSource>,
    pub camera: Option<rec::Camera>,
    pub metadata: Vec<rec::Metadata>,
    pub attachments: Vec<rec::Attachment>,
    /// Every provenance record the file carried (spec section 5.15). Empty when it
    /// carried none, which is the common case and not an error: absence costs nothing and
    /// no Header flag announces the family, so this is filled by the walk itself.
    pub provenance: crate::provenance::Provenance,
    /// The object layer the file carried (spec section 5.15.6): the Object Table and the
    /// SE(3) tracks. Empty when the file names no objects, which is the common case and not
    /// an error, exactly as with provenance.
    pub objects: crate::object_layer::ObjectLayer,
    pub statistics: Option<rec::Statistics>,
    pub chunk_index: Vec<rec::ChunkIndexEntry>,
    pub summary_offsets: Vec<rec::SummaryOffset>,
    /// Whether the Footer's summary CRC matched, or `None` when the file declares none.
    /// A front-to-back reader can check this too: it has seen the bytes the CRC covers.
    pub summary_crc_ok: Option<bool>,
    /// Opcodes seen but not understood, kept so a caller can report that they were skipped
    /// rather than tripped over.
    pub skipped_opcodes: Vec<u8>,
    pub truncated: bool,
    /// Chunk intervals in file order, for callers that want them without the index.
    pub chunk_intervals: Vec<(f64, f64)>,
}

enum PrefixRecord {
    Header(rec::Header),
    Quantization(rec::Quantization),
    WindowTable(rec::WindowTable),
    AudioSource(rec::AudioSource),
    Camera(rec::Camera),
    Metadata(rec::Metadata),
    CoordinateFrame(rec::CoordinateFrame),
    SensorCalibration(rec::SensorCalibration),
    RigTrajectory(rec::RigTrajectory),
    GeodeticAnchor(rec::GeodeticAnchor),
    ObjectTable(rec::ObjectTable),
    ObjectTrack(rec::ObjectTrack),
    Statistics(rec::Statistics),
    Footer(rec::Footer),
}

fn checked_resident_add(total: &mut usize, added: usize, what: &str) -> Result<()> {
    *total = total.checked_add(added).ok_or_else(|| {
        Error::UnsupportedOperation(format!("retained {what} allocation bytes overflow"))
    })?;
    Ok(())
}

fn string_map_resident_bytes(values: &BTreeMap<String, String>) -> Result<usize> {
    // BTreeMap does not expose node capacities. Charge every stored String object plus a
    // conservative four-pointer node/link allowance, then its two backing allocations.
    let per_entry = std::mem::size_of::<(String, String)>()
        .checked_add(4 * std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation("retained map row bytes overflow".into()))?;
    let mut total = values
        .len()
        .checked_mul(per_entry)
        .ok_or_else(|| Error::UnsupportedOperation("retained map bytes overflow".into()))?;
    for (key, value) in values {
        checked_resident_add(&mut total, key.capacity(), "map key")?;
        checked_resident_add(&mut total, value.capacity(), "map value")?;
    }
    Ok(total)
}

fn streamed_btree_node_bytes<K, V>(len: usize, what: &str) -> Result<usize> {
    let per_node = std::mem::size_of::<(K, V)>()
        .checked_add(4 * std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} map-row bytes overflow")))?;
    len.checked_mul(per_node)
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} map bytes overflow")))
}

fn audio_payload_content_bytes(payloads: &BTreeMap<u32, (Vec<u8>, usize)>) -> Result<usize> {
    payloads
        .values()
        .try_fold(0usize, |total, (_, content_charge)| {
            total.checked_add(*content_charge).ok_or_else(|| {
                Error::UnsupportedOperation("Audio Data content-byte count overflows".into())
            })
        })
}

fn scanned_header_string_bytes(cursor: &mut Cursor<'_>) -> Result<usize> {
    let length = cursor.u32()? as usize;
    let value = cursor.take(length)?;
    std::str::from_utf8(value)
        .map_err(|error| Error::Malformed(format!("a string field is not valid UTF-8: {error}")))?;
    Ok(length)
}

fn scanned_string_map_resident_bytes(cursor: &mut Cursor<'_>, what: &str) -> Result<usize> {
    let block_length = cursor.u32()? as usize;
    let block = cursor.take(block_length)?;
    let mut entries = Cursor::new(block);
    let mut strings = 0usize;
    let mut entry_count = 0usize;
    while entries.remaining() > 0 {
        let key = scanned_header_string_bytes(&mut entries)?;
        let value = scanned_header_string_bytes(&mut entries)?;
        strings = strings
            .checked_add(key)
            .and_then(|bytes| bytes.checked_add(value))
            .ok_or_else(|| Error::UnsupportedOperation(format!("{what} string bytes overflow")))?;
        entry_count = entry_count
            .checked_add(1)
            .ok_or_else(|| Error::UnsupportedOperation(format!("{what} entry count overflows")))?;
    }
    strings
        .checked_add(streamed_btree_node_bytes::<String, String>(
            entry_count,
            what,
        )?)
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} resident bytes overflow")))
}

/// Allocation-free upper bound for parsing a Header while its wire prefix remains live.
///
/// String bytes are copied by `Header::parse`; the six-value AABB owns a Vec; and the
/// attributes map adds two String objects plus conservative B-tree links for every row.
/// Counting these before the allocating parser runs prevents a compact map from using
/// the prefix ceiling and then amplifying past the shared scene envelope.
fn header_prefix_parse_working_bytes(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    let mut resident = scanned_header_string_bytes(&mut cursor)?;
    resident = resident
        .checked_add(scanned_header_string_bytes(&mut cursor)?)
        .ok_or_else(|| Error::UnsupportedOperation("Header string bytes overflow".into()))?;
    cursor.take(3 * std::mem::size_of::<u64>())?;
    resident = resident
        .checked_add(scanned_header_string_bytes(&mut cursor)?)
        .and_then(|bytes| bytes.checked_add(6 * std::mem::size_of::<f64>()))
        .ok_or_else(|| Error::UnsupportedOperation("Header resident bytes overflow".into()))?;
    cursor.take(6 * std::mem::size_of::<f64>() + 2)?;

    resident = resident
        .checked_add(scanned_string_map_resident_bytes(
            &mut cursor,
            "Header attribute",
        )?)
        .ok_or_else(|| Error::UnsupportedOperation("Header attribute bytes overflow".into()))?;
    prefix
        .len()
        .checked_add(resident)
        .ok_or_else(|| Error::UnsupportedOperation("Header parse bytes overflow".into()))
}

pub(crate) fn check_header_prefix_parse_budget(
    prefix: &[u8],
    remaining: usize,
    offset: u64,
) -> Result<()> {
    let working = header_prefix_parse_working_bytes(prefix)?;
    if working > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Header record at byte {offset} needs {working} bytes for its live prefix, strings, AABB, and attribute map, past the {remaining} bytes remaining in the shared scene budget"
        )));
    }
    Ok(())
}

fn quantization_prefix_parse_working_bytes(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    let mut resident = scanned_header_string_bytes(&mut cursor)?;
    cursor.take(11 * std::mem::size_of::<f64>() + 1)?;
    let bounds = scanned_string_map_resident_bytes(&mut cursor, "Quantization bounds")?;
    resident = resident
        .checked_add(3 * std::mem::size_of::<f64>())
        .and_then(|bytes| bytes.checked_add(bounds))
        .ok_or_else(|| {
            Error::UnsupportedOperation("Quantization resident bytes overflow".into())
        })?;
    let tail = cursor.rest();
    if let Some((&count, depths)) = tail.split_first() {
        let count = count as usize;
        let legal = crate::quantization::SH_MIN_BITS..=crate::quantization::SH_MAX_BITS;
        if count != 0 && depths.len() >= count && depths[..count].iter().all(|d| legal.contains(d))
        {
            resident = resident.checked_add(count).ok_or_else(|| {
                Error::UnsupportedOperation("Quantization SH-depth bytes overflow".into())
            })?;
        }
    }
    prefix
        .len()
        .checked_add(resident)
        .ok_or_else(|| Error::UnsupportedOperation("Quantization parse bytes overflow".into()))
}

pub(crate) fn check_quantization_prefix_parse_budget(
    prefix: &[u8],
    remaining: usize,
    offset: u64,
) -> Result<()> {
    let working = quantization_prefix_parse_working_bytes(prefix)?;
    if working > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Quantization record at byte {offset} needs {working} bytes for its live prefix, strings, vectors, and bounds map, past the {remaining} bytes remaining in the shared scene budget"
        )));
    }
    Ok(())
}

fn window_table_prefix_parse_working_bytes(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    let count = cursor.u32()? as usize;
    let wire_bytes = count
        .checked_mul(2 * std::mem::size_of::<f64>())
        .ok_or_else(|| Error::Malformed("Window Table row bytes overflow".into()))?;
    cursor.take(wire_bytes)?;
    let resident = count
        .checked_mul(std::mem::size_of::<(f64, f64)>())
        .ok_or_else(|| {
            Error::UnsupportedOperation("Window Table resident bytes overflow".into())
        })?;
    prefix
        .len()
        .checked_add(resident)
        .ok_or_else(|| Error::UnsupportedOperation("Window Table parse bytes overflow".into()))
}

pub(crate) fn check_window_table_prefix_parse_budget(
    prefix: &[u8],
    remaining: usize,
    offset: u64,
) -> Result<()> {
    let working = window_table_prefix_parse_working_bytes(prefix)?;
    if working > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Window Table record at byte {offset} needs {working} bytes for its live prefix and parsed rows, past the {remaining} bytes remaining in the shared scene budget"
        )));
    }
    Ok(())
}

fn check_metadata_prefix_parse_budget(prefix: &[u8], remaining: usize, offset: u64) -> Result<()> {
    let projected = crate::indexed_reader::metadata_prefix_resident_bound(prefix)?;
    let working = prefix.len().checked_add(projected).ok_or_else(|| {
        Error::UnsupportedOperation("streamed Metadata parse working-set bytes overflow".into())
    })?;
    if working > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Metadata record at byte {offset} needs {working} bytes for its live prefix, strings, and map nodes, past the {remaining} bytes remaining in the shared scene budget"
        )));
    }
    Ok(())
}

/// Heap bytes owned by a parsed extensible-record value, excluding the temporary wire prefix.
pub(crate) fn header_resident_bytes(value: &rec::Header) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        value.profile.capacity(),
        value.library.capacity(),
        value.temporal_model.capacity(),
        vector_bytes(&value.aabb)?,
        string_map_resident_bytes(&value.attributes)?,
    ] {
        checked_resident_add(&mut total, bytes, "Header")?;
    }
    Ok(total)
}

pub(crate) fn quantization_resident_bytes(value: &rec::Quantization) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        value.scheme.capacity(),
        vector_bytes(&value.pos_origin)?,
        string_map_resident_bytes(&value.bounds)?,
        vector_bytes(&value.sh_bit_depths)?,
    ] {
        checked_resident_add(&mut total, bytes, "Quantization")?;
    }
    Ok(total)
}

pub(crate) fn window_table_resident_bytes(value: &rec::WindowTable) -> Result<usize> {
    vector_bytes(&value.windows)
}

fn prefix_record_resident_bytes(record: &PrefixRecord) -> Result<usize> {
    let mut total = 0usize;
    match record {
        PrefixRecord::Header(value) => {
            total = header_resident_bytes(value)?;
        }
        PrefixRecord::Quantization(value) => {
            total = quantization_resident_bytes(value)?;
        }
        PrefixRecord::WindowTable(value) => {
            total = window_table_resident_bytes(value)?;
        }
        PrefixRecord::AudioSource(value) => {
            for bytes in [
                value.name.capacity(),
                value.codec.capacity(),
                value.channel_layout.capacity(),
                value.interpolation.capacity(),
                vector_bytes(&value.keyframes)?,
            ] {
                checked_resident_add(&mut total, bytes, "Audio Source")?;
            }
        }
        PrefixRecord::Camera(value) => {
            for bytes in [
                vector_bytes(&value.times)?,
                vector_bytes(&value.positions)?,
                vector_bytes(&value.targets)?,
                value.interpolation.capacity(),
            ] {
                checked_resident_add(&mut total, bytes, "Camera")?;
            }
        }
        PrefixRecord::Metadata(value) => {
            checked_resident_add(&mut total, value.name.capacity(), "Metadata")?;
            checked_resident_add(
                &mut total,
                string_map_resident_bytes(&value.entries)?,
                "Metadata",
            )?;
        }
        PrefixRecord::CoordinateFrame(value) => {
            checked_resident_add(&mut total, value.name.capacity(), "Coordinate Frame")?;
        }
        PrefixRecord::SensorCalibration(value) => {
            for bytes in [
                value.name.capacity(),
                value.modality.capacity(),
                vector_bytes(&value.distortion)?,
                value.rig_name.capacity(),
            ] {
                checked_resident_add(&mut total, bytes, "Sensor Calibration")?;
            }
        }
        PrefixRecord::RigTrajectory(value) => {
            for bytes in [
                value.name.capacity(),
                vector_bytes(&value.times)?,
                vector_bytes(&value.rotations)?,
                vector_bytes(&value.translations)?,
            ] {
                checked_resident_add(&mut total, bytes, "Rig Trajectory")?;
            }
        }
        PrefixRecord::GeodeticAnchor(value) => {
            checked_resident_add(&mut total, value.frame_name.capacity(), "Geodetic Anchor")?;
        }
        PrefixRecord::ObjectTable(value) => {
            checked_resident_add(&mut total, vector_bytes(&value.entries)?, "Object Table")?;
            for entry in &value.entries {
                checked_resident_add(&mut total, entry.label.capacity(), "Object Table label")?;
                if let Some(embedding) = &entry.embedding {
                    checked_resident_add(
                        &mut total,
                        vector_bytes(embedding)?,
                        "Object Table embedding",
                    )?;
                }
            }
        }
        PrefixRecord::ObjectTrack(value) => {
            for bytes in [
                vector_bytes(&value.times)?,
                vector_bytes(&value.rotations)?,
                vector_bytes(&value.translations)?,
            ] {
                checked_resident_add(&mut total, bytes, "Object Track")?;
            }
        }
        PrefixRecord::Statistics(value) => {
            checked_resident_add(&mut total, vector_bytes(&value.aabb)?, "Statistics")?;
        }
        PrefixRecord::Footer(_) => {}
    }
    Ok(total)
}

/// Allocation-free bound for an Object Table's owned value and its uniqueness check.
///
/// Object rows are compact on the wire but large Rust structs.  `ObjectTable::parse`
/// allocates the row vector before the generic retained-value accounting below can see
/// it, and `ObjectTable::check` temporarily keeps a set of every id beside that vector.
/// Walk the visible version-1 fields first so both allocations are admitted while the
/// prefix and every earlier record are still charged.
pub(crate) fn object_table_prefix_parse_working_bytes(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    let count = cursor.u32()? as usize;
    let embedding_dim = cursor.u16()? as usize;
    let minimum_entry = 4 + 4 + 3 * 4 + 1 + usize::from(embedding_dim > 0);
    if count > cursor.remaining() / minimum_entry {
        return Err(Error::Truncated(format!(
            "ObjectTable declares {count} entries at content offset 0, but {} bytes remain after its header and each entry needs at least {minimum_entry}",
            cursor.remaining()
        )));
    }

    let entry_bytes = count
        .checked_mul(std::mem::size_of::<rec::ObjectTableEntry>())
        .ok_or_else(|| Error::UnsupportedOperation("Object Table entry bytes overflow".into()))?;
    let mut resident = entry_bytes;
    for entry_index in 0..count {
        let object_id = cursor.u32()?;
        let label_length = cursor.u32()? as usize;
        let label = cursor.take(label_length)?;
        std::str::from_utf8(label).map_err(|error| {
            Error::Malformed(format!(
                "ObjectTable entry {entry_index} for object {object_id} has a label that is not valid UTF-8: {error}"
            ))
        })?;
        resident = resident.checked_add(label_length).ok_or_else(|| {
            Error::UnsupportedOperation("Object Table label bytes overflow".into())
        })?;
        cursor.take(3 * std::mem::size_of::<f32>())?;
        match cursor.u8()? {
            0 => {}
            1 => {
                cursor.take(9 * std::mem::size_of::<f32>())?;
            }
            flag => {
                return Err(Error::Malformed(format!(
                    "ObjectTable entry {entry_index} for object {object_id} has dynamics_present={flag}; expected 0 or 1"
                )))
            }
        }
        if embedding_dim > 0 {
            match cursor.u8()? {
                0 => {}
                1 => {
                    let bytes = embedding_dim
                        .checked_mul(std::mem::size_of::<f32>())
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(
                                "Object Table embedding bytes overflow".into(),
                            )
                        })?;
                    cursor.take(bytes)?;
                    resident = resident.checked_add(bytes).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "Object Table resident embedding bytes overflow".into(),
                        )
                    })?;
                }
                flag => {
                    return Err(Error::Malformed(format!(
                        "ObjectTable entry {entry_index} for object {object_id} has has_embedding={flag}; expected 0 or 1"
                    )))
                }
            }
        }
    }

    // One additional row-vector-sized allowance conservatively covers HashSet storage
    // during duplicate-id validation; ObjectTableEntry is much larger than one id bucket.
    prefix
        .len()
        .checked_add(resident)
        .and_then(|bytes| bytes.checked_add(entry_bytes))
        .ok_or_else(|| Error::UnsupportedOperation("Object Table parse bytes overflow".into()))
}

fn check_object_table_prefix_parse_budget(
    prefix: &[u8],
    remaining: usize,
    offset: u64,
) -> Result<()> {
    let working = object_table_prefix_parse_working_bytes(prefix)?;
    if working > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Object Table record at byte {offset} needs {working} bytes for its live prefix, parsed rows, and identity validation beside earlier records, past the {remaining} bytes remaining in the shared retained-record budget"
        )));
    }
    Ok(())
}

enum ParsedContent<T> {
    Complete(T, usize),
    Cut,
}

impl<T> ParsedContent<T> {
    fn map<U>(self, f: impl FnOnce(T) -> U) -> ParsedContent<U> {
        match self {
            ParsedContent::Complete(value, retained) => ParsedContent::Complete(f(value), retained),
            ParsedContent::Cut => ParsedContent::Cut,
        }
    }
}

impl Scene {
    /// Reconstructed gaussian state at scene time `t`, including authoritative Object
    /// Tracks. This is the front-to-back counterpart of [`crate::reader::SceneReader::state_at`].
    pub fn state_at(&self, t: f64) -> Result<crate::model::StateAt> {
        crate::provenance::check_scene_time(t)?;
        let mut state = self.gaussians.state_at(t, self.header.cutoff);
        let visible_object_ids = self.gaussians.object_id.as_ref().map(|object_ids| {
            state
                .indices
                .iter()
                .map(|&index| object_ids[index as usize])
                .collect::<Vec<u32>>()
        });
        if let Some(object_ids) = visible_object_ids.filter(|ids| ids.iter().any(|id| *id != 0)) {
            self.objects
                .apply(&mut state.centers, &mut state.orientations, &object_ids, t)?;
        }
        Ok(state)
    }
}

/// Decode a whole file from any byte source.
pub fn read_from<R: Read>(source: R, options: &ReadOptions) -> Result<Scene> {
    read_from_with_limits(
        source,
        options,
        MAX_STREAM_BYTES as usize,
        crate::indexed_reader::MAX_RETAINED_RECORDS,
    )
}

/// The streamed read with explicit retained-record and record-count ceilings.
///
/// Production callers use the shared reader ceilings. Keeping them explicit here also lets small
/// regressions exercise aggregate accounting and truncation precedence through the real record
/// walk instead of constructing hundreds of megabytes of disposable input.
fn read_from_with_limits<R: Read>(
    source: R,
    options: &ReadOptions,
    retained_limit: usize,
    record_limit: usize,
) -> Result<Scene> {
    let mut source = io::BufReader::new(source);

    let mut magic = [0u8; MAGIC.len()];
    read_exactly(&mut source, &mut magic)?;
    crate::serialization::check_magic(&magic)?;

    let mut scene = Scene::default();
    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut chunks: Vec<DecodedChunk> = Vec::new();
    let mut chunk_bands: Vec<BTreeMap<u8, DecodedStream>> = Vec::new();
    let mut chunk_band_masks: Vec<u8> = Vec::new();
    let mut decoded_bytes = 0usize;
    let mut retained_record_bytes = 0usize;
    let mut header_resident_bytes = 0usize;
    let mut quantization_resident_bytes = 0usize;
    let mut window_table_resident_bytes = 0usize;
    let mut legacy_audio_retained_bytes = 0usize;
    let mut camera_resident_bytes = 0usize;
    let mut statistics_resident_bytes = 0usize;
    let mut record_count = 0usize;
    let mut audio_descriptors: BTreeMap<u32, rec::AudioSource> = BTreeMap::new();
    // The second tuple field is the exact content-byte charge admitted before
    // `AudioData::into_payload` reuses and drains that allocation. It lets truncated
    // recovery release an unmatched payload from the aggregate budget when it drops it.
    let mut audio_payloads: BTreeMap<u32, (Vec<u8>, usize)> = BTreeMap::new();
    let mut audio_descriptor_map_bytes = 0usize;
    let mut audio_payload_map_bytes = 0usize;
    let mut legacy_audio: Option<rec::Audio> = None;
    let mut first_audio_record: Option<(&'static str, u64, Option<u32>)> = None;
    let mut truncated = false;
    let mut saw_footer = false;

    // The Footer names the trailing summary only after those bytes have passed. Keep the
    // checksum of the current candidate run, not a second copy of every retained record.
    let mut summary_crc = Crc32::new();
    let mut summary_tail_start: u64 = 0;
    let mut summary_tail_len: u64 = 0;

    let mut at: u64 = MAGIC.len() as u64;
    let mut clean_end = false;

    loop {
        let mut head = [0u8; RECORD_HEADER_SIZE];
        let got = read_up_to(&mut source, &mut head)?;
        if got == MAGIC.len() && head[..MAGIC.len()] == MAGIC {
            let mut spare = [0u8; 1];
            clean_end = read_up_to(&mut source, &mut spare)? == 0;
            break;
        }
        if got < RECORD_HEADER_SIZE {
            break;
        }

        let opcode = head[0];
        let length = u64::from_le_bytes([
            head[1], head[2], head[3], head[4], head[5], head[6], head[7], head[8],
        ]);
        let offset = at;
        // Saturating: `at` is only used to frame offsets, and a corrupt length must not
        // wrap it into a value that looks like a plausible position in the file.
        at = at.saturating_add(RECORD_HEADER_SIZE as u64);
        record_count = record_count.saturating_add(1);
        if record_count > record_limit {
            // A declaration is not a complete record. If the resource ends immediately after
            // this header, recovery keeps every prior record just as it does for any other cut.
            // One physically present body byte is enough to prove the extra record exists and
            // make the configured count ceiling authoritative. A zero-length record is already
            // complete at its header.
            if length != 0 && source.fill_buf()?.is_empty() {
                truncated = true;
                break;
            }
            return Err(Error::UnsupportedOperation(format!(
                "the streamed record walk reaches record {record_count} at byte {offset}, past the {record_limit} record reader ceiling"
            )));
        }

        // The summary is exactly these three, and §4.5 requires them contiguous immediately
        // before the Footer — which is what makes this retention exact rather than a guess.
        // Attachments are deliberately not here: their size is unbounded, and admitting them
        // would make verifying a checksum cost whatever the payload happens to weigh.
        let is_summary = matches!(
            opcode,
            op::CHUNK_INDEX | op::STATISTICS | op::SUMMARY_OFFSET
        );
        // The Footer closes the range rather than falling outside it, so it must not reset
        // what the range holds.
        if !is_summary && opcode != op::FOOTER {
            summary_crc = Crc32::new();
            summary_tail_start = 0;
            summary_tail_len = 0;
        }
        if is_summary {
            if summary_tail_len == 0 {
                summary_tail_start = offset;
            }
            summary_crc.update(&head);
        }

        // Retained records and decoded state share one scene envelope. This per-record
        // ceiling keeps prefix parsing and retained payload reads aware of state that is
        // already resident, while the decoded paths subtract retained bytes in return.
        let retained_ceiling = retained_limit.min(
            MAX_DECODED_SCENE_BYTES
                .checked_sub(decoded_bytes)
                .ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "streamed decoded state exhausted the shared scene budget".into(),
                    )
                })?,
        );

        // Unknown and private records are stepped over without being materialized. That is
        // the whole forward-compatibility mechanism, and doing it by `copy` rather than by
        // `read_to_end` means an application record the size of a video costs no memory.
        let known = matches!(
            opcode,
            op::HEADER
                | op::QUANTIZATION
                | op::WINDOW_TABLE
                | op::CHUNK
                | op::SH_BAND_STREAM
                | op::AUDIO
                | op::AUDIO_SOURCE
                | op::AUDIO_DATA
                | op::CAMERA
                | op::METADATA
                | op::ATTACHMENT
                | op::COORDINATE_FRAME
                | op::SENSOR_CALIBRATION
                | op::RIG_TRAJECTORY
                | op::GEODETIC_ANCHOR
                | op::OBJECT_TABLE
                | op::OBJECT_TRACK
                | op::STATISTICS
                | op::CHUNK_INDEX
                | op::SUMMARY_OFFSET
                | op::FOOTER
        );
        if !known {
            retained_record_bytes = push_streamed_retained_value(
                &mut scene.skipped_opcodes,
                opcode,
                retained_record_bytes,
                "skipped opcode collection",
                offset,
                retained_ceiling,
            )?;
            if skip_exactly(&mut source, length)? {
                at = at.saturating_add(length);
                continue;
            }
            truncated = true;
            break;
        }

        // These records are extensible: a newer writer may append a very large suffix
        // after the version-1 fields. Grow a small prefix only until the known parser is
        // satisfied, then consume the suffix into the sink so a pipe remains aligned
        // without making the suffix resident.
        let prefix_record = match opcode {
            op::HEADER => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Header record",
                    offset,
                    |bytes, _| {
                        let remaining = retained_ceiling
                            .checked_sub(retained_record_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "the streamed Header has no retained-record budget".into(),
                                )
                            })?;
                        check_header_prefix_parse_budget(bytes, remaining, offset)?;
                        rec::Header::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::Header)),
            ),
            op::QUANTIZATION => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Quantization record",
                    offset,
                    |bytes, complete| {
                        let remaining = retained_ceiling
                            .checked_sub(retained_record_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "the streamed Quantization has no retained-record budget"
                                        .into(),
                                )
                            })?;
                        check_quantization_prefix_parse_budget(bytes, remaining, offset)?;
                        rec::Quantization::parse_prefix(bytes, complete)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::Quantization)),
            ),
            op::WINDOW_TABLE => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Window Table record",
                    offset,
                    |bytes, _| {
                        rec::preflight_counted_record_length(opcode, bytes, length)?;
                        let remaining = retained_ceiling
                            .checked_sub(retained_record_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "the streamed Window Table has no retained-record budget"
                                        .into(),
                                )
                            })?;
                        check_window_table_prefix_parse_budget(bytes, remaining, offset)?;
                        rec::WindowTable::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::WindowTable)),
            ),
            op::AUDIO_SOURCE => {
                if !chunks.is_empty() {
                    return Err(Error::Malformed(format!(
                        "an Audio Source record appears after the first Chunk at byte {offset}"
                    )));
                }
                Some(
                    read_parsed_content(
                        &mut source,
                        length,
                        streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                        "Audio Source record",
                        offset,
                        |bytes, complete| rec::AudioSource::parse_prefix(bytes, complete, length),
                    )
                    .map(|parsed| parsed.map(PrefixRecord::AudioSource)),
                )
            }
            op::CAMERA => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Camera record",
                    offset,
                    |bytes, _| {
                        rec::preflight_counted_record_length(opcode, bytes, length)?;
                        rec::Camera::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::Camera)),
            ),
            op::METADATA => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Metadata record",
                    offset,
                    |bytes, _| {
                        let remaining = retained_ceiling
                            .checked_sub(retained_record_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "the streamed Metadata has no retained-record budget".into(),
                                )
                            })?;
                        check_metadata_prefix_parse_budget(bytes, remaining, offset)?;
                        rec::Metadata::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::Metadata)),
            ),
            op::COORDINATE_FRAME => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Coordinate Frame record",
                    offset,
                    |bytes, _| rec::CoordinateFrame::parse(bytes),
                )
                .map(|parsed| parsed.map(PrefixRecord::CoordinateFrame)),
            ),
            op::SENSOR_CALIBRATION => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Sensor Calibration record",
                    offset,
                    |bytes, _| rec::SensorCalibration::parse(bytes),
                )
                .map(|parsed| parsed.map(PrefixRecord::SensorCalibration)),
            ),
            op::RIG_TRAJECTORY => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Rig Trajectory record",
                    offset,
                    |bytes, _| {
                        rec::preflight_counted_record_length(opcode, bytes, length)?;
                        rec::RigTrajectory::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::RigTrajectory)),
            ),
            op::GEODETIC_ANCHOR => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Geodetic Anchor record",
                    offset,
                    |bytes, _| rec::GeodeticAnchor::parse(bytes),
                )
                .map(|parsed| parsed.map(PrefixRecord::GeodeticAnchor)),
            ),
            op::OBJECT_TABLE => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Object Table record",
                    offset,
                    |bytes, _| {
                        rec::preflight_counted_record_length(opcode, bytes, length)?;
                        let remaining = retained_ceiling
                            .checked_sub(retained_record_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "the streamed Object Table has no retained-record budget"
                                        .into(),
                                )
                            })?;
                        check_object_table_prefix_parse_budget(bytes, remaining, offset)?;
                        rec::ObjectTable::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::ObjectTable)),
            ),
            op::OBJECT_TRACK => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Object Track record",
                    offset,
                    |bytes, _| {
                        rec::preflight_counted_record_length(opcode, bytes, length)?;
                        rec::ObjectTrack::parse(bytes)
                    },
                )
                .map(|parsed| parsed.map(PrefixRecord::ObjectTrack)),
            ),
            op::STATISTICS => Some(
                read_parsed_content_observed(
                    &mut source,
                    length,
                    streamed_prefix_limit(retained_record_bytes, retained_ceiling),
                    "Statistics record",
                    offset,
                    |bytes, _| rec::Statistics::parse(bytes),
                    |bytes| summary_crc.update(bytes),
                )
                .map(|parsed| parsed.map(PrefixRecord::Statistics)),
            ),
            op::FOOTER => Some(
                read_parsed_content(
                    &mut source,
                    length,
                    crate::indexed_reader::MAX_FRONT_MATTER_BYTES
                        .min(retained_ceiling.saturating_sub(retained_record_bytes) as u64),
                    "Footer record",
                    offset,
                    |bytes, _| rec::Footer::parse(bytes),
                )
                .map(|parsed| parsed.map(PrefixRecord::Footer)),
            ),
            _ => None,
        };
        if let Some(parsed) = prefix_record {
            let (parsed, retained_prefix) = match parsed {
                Ok(ParsedContent::Complete(parsed, retained)) => (parsed, retained),
                Ok(ParsedContent::Cut) => {
                    truncated = true;
                    break;
                }
                Err(error) => return Err(error),
            };
            let retained_value = prefix_record_resident_bytes(&parsed)?;
            let peak_charge = retained_prefix.checked_add(retained_value).ok_or_else(|| {
                Error::UnsupportedOperation(
                    "parsed prefix and retained value allocation bytes overflow".into(),
                )
            })?;
            // At this point the helper has just finished constructing `parsed` while its
            // wire prefix was live. Check that peak before replacement accounting removes
            // any older singleton value; otherwise a replacement could hide its overlap.
            add_streamed_retained_bytes(
                retained_record_bytes,
                peak_charge,
                "parsed prefix and owned value peak",
                offset,
                retained_ceiling,
            )?;
            at = at.saturating_add(length);
            if is_summary {
                summary_tail_len = summary_tail_len
                    .checked_add(RECORD_HEADER_SIZE as u64)
                    .and_then(|total| total.checked_add(length))
                    .ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "contiguous streamed summary byte count overflows".into(),
                        )
                    })?;
            }
            match parsed {
                PrefixRecord::Header(parsed) => {
                    crate::registry::check_temporal_model(&parsed.temporal_model)?;
                    retained_record_bytes = replace_streamed_retained_bytes(
                        retained_record_bytes,
                        header_resident_bytes,
                        retained_value,
                        "retained Header value",
                        offset,
                        retained_ceiling,
                    )?;
                    header_resident_bytes = retained_value;
                    header = Some(parsed);
                }
                PrefixRecord::Quantization(parsed) => {
                    crate::registry::check_quantization_scheme(&parsed.scheme)?;
                    retained_record_bytes = replace_streamed_retained_bytes(
                        retained_record_bytes,
                        quantization_resident_bytes,
                        retained_value,
                        "retained Quantization value",
                        offset,
                        retained_ceiling,
                    )?;
                    quantization_resident_bytes = retained_value;
                    quant = Some(parsed);
                }
                PrefixRecord::WindowTable(parsed) => {
                    // A gaussian's window index is checked against the table in force when
                    // its Chunk is decoded (spec §5.4). A second table arriving after a
                    // Chunk would reinterpret indices that were already accepted, and a
                    // shorter one would leave them pointing outside it — so it is refused
                    // here rather than applied retroactively.
                    if !chunks.is_empty() {
                        return Err(Error::Malformed(format!(
                            "the Window Table at byte {offset} follows {} decoded Chunk record(s); the table a gaussian's window index refers to must precede the Chunk that carries it",
                            chunks.len()
                        )));
                    }
                    retained_record_bytes = replace_streamed_retained_bytes(
                        retained_record_bytes,
                        window_table_resident_bytes,
                        retained_value,
                        "retained Window Table value",
                        offset,
                        retained_ceiling,
                    )?;
                    window_table_resident_bytes = retained_value;
                    scene.windows = parsed.windows;
                }
                PrefixRecord::AudioSource(source) => {
                    let id = source.source_id;
                    first_audio_record.get_or_insert(("Audio Source", offset, Some(id)));
                    if audio_descriptors.contains_key(&id) {
                        return Err(Error::Malformed(format!(
                            "Audio Source id {id} appears more than once"
                        )));
                    }
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Audio Source values",
                        offset,
                        retained_ceiling,
                    )?;
                    let node_bytes = streamed_btree_node_bytes::<u32, rec::AudioSource>(
                        1,
                        "streamed Audio Source",
                    )?;
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        node_bytes,
                        "retained Audio Source map nodes",
                        offset,
                        retained_ceiling,
                    )?;
                    audio_descriptor_map_bytes = audio_descriptor_map_bytes
                        .checked_add(node_bytes)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(
                                "streamed Audio Source map bytes overflow".into(),
                            )
                        })?;
                    audio_descriptors.insert(id, source);
                }
                PrefixRecord::Camera(parsed) => {
                    retained_record_bytes = replace_streamed_retained_bytes(
                        retained_record_bytes,
                        camera_resident_bytes,
                        retained_value,
                        "retained Camera value",
                        offset,
                        retained_ceiling,
                    )?;
                    camera_resident_bytes = retained_value;
                    scene.camera = Some(parsed);
                }
                PrefixRecord::Metadata(parsed) => {
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Metadata values",
                        offset,
                        retained_ceiling,
                    )?;
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.metadata,
                        parsed,
                        retained_record_bytes,
                        "Metadata collection",
                        offset,
                        retained_ceiling,
                    )?;
                }
                PrefixRecord::CoordinateFrame(parsed) => {
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Coordinate Frame values",
                        offset,
                        retained_ceiling,
                    )?;
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.provenance.frames,
                        parsed,
                        retained_record_bytes,
                        "Coordinate Frame collection",
                        offset,
                        retained_ceiling,
                    )?;
                }
                PrefixRecord::SensorCalibration(parsed) => {
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Sensor Calibration values",
                        offset,
                        retained_ceiling,
                    )?;
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.provenance.sensors,
                        parsed,
                        retained_record_bytes,
                        "Sensor Calibration collection",
                        offset,
                        retained_ceiling,
                    )?;
                }
                PrefixRecord::RigTrajectory(parsed) => {
                    if parsed.sample_count() > 0 {
                        retained_record_bytes = add_streamed_retained_bytes(
                            retained_record_bytes,
                            retained_value,
                            "retained Rig Trajectory values",
                            offset,
                            retained_ceiling,
                        )?;
                        retained_record_bytes = push_streamed_retained_value(
                            &mut scene.provenance.trajectories,
                            parsed,
                            retained_record_bytes,
                            "Rig Trajectory collection",
                            offset,
                            retained_ceiling,
                        )?;
                    }
                }
                PrefixRecord::GeodeticAnchor(parsed) => {
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Geodetic Anchor values",
                        offset,
                        retained_ceiling,
                    )?;
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.provenance.anchors,
                        parsed,
                        retained_record_bytes,
                        "Geodetic Anchor collection",
                        offset,
                        retained_ceiling,
                    )?;
                }
                PrefixRecord::ObjectTable(parsed) => {
                    if scene.objects.table.is_some() {
                        return Err(Error::Malformed(format!(
                            "a second ObjectTable record appears at byte {offset}; a file may carry exactly one scene-wide object table"
                        )));
                    }
                    retained_record_bytes = add_streamed_retained_bytes(
                        retained_record_bytes,
                        retained_value,
                        "retained Object Table value",
                        offset,
                        retained_ceiling,
                    )?;
                    scene.objects.table = Some(parsed);
                }
                PrefixRecord::ObjectTrack(parsed) => {
                    if parsed.sample_count() > 0 {
                        retained_record_bytes = add_streamed_retained_bytes(
                            retained_record_bytes,
                            retained_value,
                            "retained Object Track values",
                            offset,
                            retained_ceiling,
                        )?;
                        retained_record_bytes = push_streamed_retained_value(
                            &mut scene.objects.tracks,
                            parsed,
                            retained_record_bytes,
                            "Object Track collection",
                            offset,
                            retained_ceiling,
                        )?;
                    }
                }
                PrefixRecord::Statistics(parsed) => {
                    retained_record_bytes = replace_streamed_retained_bytes(
                        retained_record_bytes,
                        statistics_resident_bytes,
                        retained_value,
                        "retained Statistics value",
                        offset,
                        retained_ceiling,
                    )?;
                    statistics_resident_bytes = retained_value;
                    scene.statistics = Some(parsed);
                }
                PrefixRecord::Footer(footer) => {
                    saw_footer = true;
                    if footer.summary_start != 0 && footer.summary_crc != 0 {
                        let covered = summary_tail_start == footer.summary_start
                            && summary_tail_start.checked_add(summary_tail_len) == Some(offset);
                        if covered {
                            scene.summary_crc_ok = Some(summary_crc.finish() == footer.summary_crc);
                        }
                    }
                }
            }
            ensure_streamed_scene_bytes(retained_record_bytes, decoded_bytes, offset)?;
            continue;
        }

        if opcode == op::SH_BAND_STREAM {
            if length == 0 {
                return Err(Error::Truncated("need the SH band byte, 0 remain".into())
                    .at_record("SH Band Stream record", offset));
            }
            let mut band_byte = [0u8; 1];
            if read_up_to(&mut source, &mut band_byte)? == 0 {
                truncated = true;
                break;
            }
            let band = band_byte[0];
            if !(1..=3).contains(&band) {
                return Err(Error::Malformed(format!(
                    "the SH Band Stream at byte {offset} declares band {band}; only bands 1 through 3 are defined"
                )));
            }
            if let Some(mask) = chunk_band_masks.last_mut() {
                let bit = 1u8 << band;
                if *mask & bit != 0 {
                    return Err(Error::Malformed(format!(
                        "SH band {band} appears more than once for the Chunk before byte {offset}"
                    )));
                }
                *mask |= bit;
            }

            let remaining_length = length - 1;
            let Some(chunk) = chunks.last() else {
                if !skip_exactly(&mut source, remaining_length)? {
                    truncated = true;
                    break;
                }
                at = at.saturating_add(length);
                continue;
            };
            if band > options.max_sh_band {
                if !skip_exactly(&mut source, remaining_length)? {
                    truncated = true;
                    break;
                }
                at = at.saturating_add(length);
                continue;
            }

            let band_node_bytes = decoded_band_map_node_bytes(1)?;
            let remaining = MAX_DECODED_SCENE_BYTES
                .checked_sub(retained_record_bytes)
                .and_then(|bytes| bytes.checked_sub(decoded_bytes))
                .and_then(|bytes| bytes.checked_sub(band_node_bytes))
                .ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "streamed SH decoding exhausted the shared scene budget".into(),
                    )
                })?;
            let content = match read_content_capped(
                &mut source,
                remaining_length,
                remaining,
                "SH Band Stream",
                offset,
            ) {
                Ok(content) => content,
                Err(error) if error.is_truncation() => {
                    truncated = true;
                    break;
                }
                Err(error) => return Err(error),
            };
            at = at.saturating_add(length);
            let encoded_bytes = content.capacity();
            let live_bytes = retained_record_bytes
                .checked_add(decoded_bytes)
                .and_then(|bytes| bytes.checked_add(band_node_bytes))
                .and_then(|bytes| bytes.checked_add(encoded_bytes))
                .ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "streamed SH decode working-set bytes overflow".into(),
                    )
                })?;
            let expected_channels = 3 * (2 * band as usize + 1);
            let mut cursor = Cursor::new(&content);
            let values =
                decode_streamed_sh_values(&mut cursor, chunk.count, expected_channels, live_bytes)
                    .map_err(|error| error.at_record("SH Band Stream record", offset))?;
            drop(content);
            let added = decoded_stream_resident_bytes(&values)?
                .checked_add(band_node_bytes)
                .ok_or_else(|| {
                    Error::UnsupportedOperation("streamed SH retained bytes overflow".into())
                })?;
            decoded_bytes = add_decoded_scene_bytes(decoded_bytes, added)?;
            ensure_streamed_scene_bytes(retained_record_bytes, decoded_bytes, offset)?;
            chunk_bands
                .last_mut()
                .expect("the Chunk and its band map are appended together")
                .insert(band, values);
            continue;
        }

        let retains_content = retains_streamed_content(opcode);
        let retained_content_limit = if retains_content {
            retained_ceiling.saturating_sub(retained_record_bytes)
        } else {
            MAX_STREAM_BYTES as usize
        };
        let (content_limit, content_name) = if opcode == op::CHUNK {
            let remaining = MAX_DECODED_SCENE_BYTES
                .checked_sub(retained_record_bytes)
                .and_then(|bytes| bytes.checked_sub(decoded_bytes))
                .expect("the retained decoded total was checked after every record");
            (retained_content_limit.min(remaining), op::name(opcode))
        } else {
            (retained_content_limit, op::name(opcode))
        };
        let content =
            match read_content_capped(&mut source, length, content_limit, &content_name, offset) {
                Ok(c) => c,
                Err(e) if e.is_truncation() => {
                    truncated = true;
                    break;
                }
                Err(e) => return Err(e),
            };
        if retains_content {
            retained_record_bytes = add_streamed_retained_bytes(
                retained_record_bytes,
                content.len(),
                "retained streamed records",
                offset,
                retained_ceiling,
            )?;
        }
        at = at.saturating_add(length);

        if is_summary {
            summary_crc.update(&content);
            summary_tail_len = summary_tail_len
                .checked_add(RECORD_HEADER_SIZE as u64)
                .and_then(|total| total.checked_add(content.len() as u64))
                .ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "contiguous streamed summary byte count overflows".into(),
                    )
                })?;
        }

        match opcode {
            op::CHUNK => {
                let quantization = quant.as_ref().ok_or_else(|| {
                    Error::Malformed("a Chunk arrived before the Quantization record".into())
                })?;
                let (chunk_head, streams) = rec::parse_chunk(&content)?;
                let remaining = MAX_DECODED_SCENE_BYTES
                    .checked_sub(retained_record_bytes)
                    .and_then(|bytes| bytes.checked_sub(decoded_bytes))
                    .expect("the retained decoded total was checked after every record");
                let encoded_bytes = content.capacity();
                let after_encoded = remaining.checked_sub(encoded_bytes).ok_or_else(|| {
                    Error::UnsupportedOperation(format!(
                        "the Chunk at byte {offset} retains {encoded_bytes} encoded bytes, past the {remaining} bytes remaining in the streamed decode working-set budget"
                    ))
                })?;
                let blob = crate::chunk::chunk_stream_bytes_with_limit(
                    &chunk_head,
                    streams,
                    after_encoded,
                )?;
                let unpacked_bytes = match &blob {
                    std::borrow::Cow::Borrowed(_) => 0,
                    std::borrow::Cow::Owned(bytes) => bytes.capacity(),
                };
                let decode_budget = after_encoded.checked_sub(unpacked_bytes).ok_or_else(|| {
                    Error::UnsupportedOperation(format!(
                        "the Chunk at byte {offset} retains {unpacked_bytes} unpacked bytes, past the {after_encoded} bytes remaining after its encoded record"
                    ))
                })?;
                let cutoff = header
                    .as_ref()
                    .map(|h| h.cutoff)
                    .unwrap_or(crate::quantization::DEFAULT_CUTOFF);
                let chunk = decode_streams_with_limit(
                    &blob,
                    chunk_head.count as usize,
                    &quantization.steps(),
                    &quantization.pos_origin,
                    &scene.windows,
                    cutoff,
                    decode_budget,
                )?;
                drop(blob);
                drop(content);
                let added = decoded_chunk_resident_bytes(&chunk, &BTreeMap::new())?;
                decoded_bytes = add_decoded_scene_bytes(decoded_bytes, added)?;
                ensure_streamed_scene_bytes(retained_record_bytes, decoded_bytes, offset)?;
                decoded_bytes = push_streamed_decoded_value(
                    &mut chunks,
                    chunk,
                    decoded_bytes,
                    retained_record_bytes,
                    "decoded Chunk collection",
                    offset,
                )?;
                decoded_bytes = push_streamed_decoded_value(
                    &mut chunk_bands,
                    BTreeMap::new(),
                    decoded_bytes,
                    retained_record_bytes,
                    "decoded SH-map collection",
                    offset,
                )?;
                decoded_bytes = push_streamed_decoded_value(
                    &mut chunk_band_masks,
                    0,
                    decoded_bytes,
                    retained_record_bytes,
                    "decoded band-mask collection",
                    offset,
                )?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.chunk_intervals,
                    (chunk_head.t0, chunk_head.t1),
                    retained_record_bytes,
                    "Chunk interval collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::SH_BAND_STREAM => unreachable!("SH records were handled from their fixed prefix"),
            op::AUDIO => {
                first_audio_record.get_or_insert(("Audio", offset, None));
                let content_len = content.len();
                let descriptor_budget = retained_ceiling
                    .checked_sub(retained_record_bytes)
                    .expect("retained record bytes were checked after the content read");
                let (audio, descriptor_bytes) =
                    rec::Audio::into_payload_with_descriptor_budget(content, descriptor_budget)?;
                retained_record_bytes = subtract_streamed_retained_bytes(
                    retained_record_bytes,
                    legacy_audio_retained_bytes,
                    "replaced legacy Audio record",
                    offset,
                )?;
                retained_record_bytes = add_streamed_retained_bytes(
                    retained_record_bytes,
                    descriptor_bytes,
                    "retained legacy Audio descriptor",
                    offset,
                    retained_ceiling,
                )?;
                legacy_audio_retained_bytes =
                    content_len.checked_add(descriptor_bytes).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "legacy Audio retained allocation bytes overflow".into(),
                        )
                    })?;
                legacy_audio = Some(audio);
            }
            op::AUDIO_DATA => {
                if !chunks.is_empty() {
                    return Err(Error::Malformed(
                        "an Audio Data record appears after the first Chunk".into(),
                    ));
                }
                let content_charge = content.len();
                let (id, data) = rec::AudioData::into_payload(content)?;
                first_audio_record.get_or_insert(("Audio Data", offset, Some(id)));
                if audio_payloads.contains_key(&id) {
                    return Err(Error::Malformed(format!(
                        "Audio Data id {id} appears more than once"
                    )));
                }
                let node_bytes =
                    streamed_btree_node_bytes::<u32, (Vec<u8>, usize)>(1, "streamed Audio Data")?;
                retained_record_bytes = add_streamed_retained_bytes(
                    retained_record_bytes,
                    node_bytes,
                    "retained Audio Data map nodes",
                    offset,
                    retained_ceiling,
                )?;
                audio_payload_map_bytes = audio_payload_map_bytes
                    .checked_add(node_bytes)
                    .ok_or_else(|| {
                        Error::UnsupportedOperation("streamed Audio Data map bytes overflow".into())
                    })?;
                audio_payloads.insert(id, (data, content_charge));
            }
            op::CAMERA => {
                let camera = rec::Camera::parse(&content)?;
                retained_record_bytes = subtract_streamed_retained_bytes(
                    retained_record_bytes,
                    camera_resident_bytes,
                    "replaced Camera record",
                    offset,
                )?;
                camera_resident_bytes = content.len();
                scene.camera = Some(camera);
            }
            op::METADATA => {
                let metadata = rec::Metadata::parse(&content)?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.metadata,
                    metadata,
                    retained_record_bytes,
                    "Metadata collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::ATTACHMENT => {
                let descriptor_budget = retained_ceiling
                    .checked_sub(retained_record_bytes)
                    .expect("retained record bytes were checked after the content read");
                let (attachment, descriptor_bytes) =
                    rec::Attachment::into_payload_with_descriptor_budget(
                        content,
                        descriptor_budget,
                    )?;
                retained_record_bytes = add_streamed_retained_bytes(
                    retained_record_bytes,
                    descriptor_bytes,
                    "retained Attachment descriptors",
                    offset,
                    retained_ceiling,
                )?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.attachments,
                    attachment,
                    retained_record_bytes,
                    "Attachment collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::COORDINATE_FRAME => {
                let frame = rec::CoordinateFrame::parse(&content)?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.provenance.frames,
                    frame,
                    retained_record_bytes,
                    "Coordinate Frame collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::SENSOR_CALIBRATION => {
                let sensor = rec::SensorCalibration::parse(&content)?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.provenance.sensors,
                    sensor,
                    retained_record_bytes,
                    "Sensor Calibration collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::RIG_TRAJECTORY => {
                // Section 5.15.4: a trajectory with no samples "MUST be read as though
                // the record were absent". Reporting it would put a rig in the summary
                // that carries no pose and that no sensor may reference.
                let trajectory = rec::RigTrajectory::parse(&content)?;
                if trajectory.sample_count() > 0 {
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.provenance.trajectories,
                        trajectory,
                        retained_record_bytes,
                        "Rig Trajectory collection",
                        offset,
                        retained_ceiling,
                    )?;
                } else {
                    retained_record_bytes = subtract_streamed_retained_bytes(
                        retained_record_bytes,
                        content.len(),
                        "absent zero-sample Rig Trajectory record",
                        offset,
                    )?;
                }
            }
            op::GEODETIC_ANCHOR => {
                let anchor = rec::GeodeticAnchor::parse(&content)?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.provenance.anchors,
                    anchor,
                    retained_record_bytes,
                    "Geodetic Anchor collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::OBJECT_TABLE => {
                if scene.objects.table.is_some() {
                    return Err(Error::Malformed(format!(
                        "a second ObjectTable record appears at byte {offset}; a file may carry \
                         exactly one scene-wide object table"
                    )));
                }
                scene.objects.table = Some(rec::ObjectTable::parse(&content)?);
            }
            op::OBJECT_TRACK => {
                // Section 5.15.7: a zero-sample track "has no pose and is read as
                // absent". Keeping it would make one empty track a non-empty object
                // layer, and two empty tracks for an id a duplicate the layer refuses.
                let track = rec::ObjectTrack::parse(&content)?;
                if track.sample_count() > 0 {
                    retained_record_bytes = push_streamed_retained_value(
                        &mut scene.objects.tracks,
                        track,
                        retained_record_bytes,
                        "Object Track collection",
                        offset,
                        retained_ceiling,
                    )?;
                } else {
                    retained_record_bytes = subtract_streamed_retained_bytes(
                        retained_record_bytes,
                        content.len(),
                        "absent zero-sample Object Track record",
                        offset,
                    )?;
                }
            }
            op::CHUNK_INDEX => {
                let entry = rec::ChunkIndexEntry::parse(&content)
                    .map_err(|error| error.at_record("Chunk Index record", offset))?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.chunk_index,
                    entry,
                    retained_record_bytes,
                    "Chunk Index collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::SUMMARY_OFFSET => {
                let summary_offset = rec::SummaryOffset::parse(&content)
                    .map_err(|error| error.at_record("Summary Offset record", offset))?;
                retained_record_bytes = push_streamed_retained_value(
                    &mut scene.summary_offsets,
                    summary_offset,
                    retained_record_bytes,
                    "Summary Offset collection",
                    offset,
                    retained_ceiling,
                )?;
            }
            op::HEADER
            | op::QUANTIZATION
            | op::WINDOW_TABLE
            | op::AUDIO_SOURCE
            | op::STATISTICS
            | op::FOOTER => {
                unreachable!("prefix records were handled before the full-content path")
            }
            _ => unreachable!("opcode was checked against the known set"),
        }
        ensure_streamed_scene_bytes(retained_record_bytes, decoded_bytes, offset)?;
    }

    // A complete file ends with the magic and nothing after it. Anything else — an
    // incomplete record, a missing trailing magic — is a cut, and what was decoded before
    // it still stands.
    if !clean_end {
        truncated = true;
    }
    if truncated && !options.recover_truncated {
        return Err(Error::Truncated(
            "the file ends without its trailing magic".into(),
        ));
    }

    let header = header
        .ok_or_else(|| Error::Malformed("file has no Header or no Quantization record".into()))?;
    let quant = quant
        .ok_or_else(|| Error::Malformed("file has no Header or no Quantization record".into()))?;

    // A cut that lands between a chunk and its spherical harmonic band records leaves the
    // trailing chunk carrying fewer bands than the rest of the file. In a complete file
    // that is corruption and stays an error; in a truncated one it is simply the part that
    // did not arrive, and refusing the whole file over it would throw away every complete
    // record before the cut — which is the one thing truncation recovery exists to keep.
    if truncated {
        drop_incomplete_trailing_bands(&mut chunks, &mut chunk_bands, &mut scene.chunk_intervals);
    }

    // The cross-record rules — unique names, a rig reference and an anchor that resolve —
    // can only run once the whole front matter has gone past. A truncated file may
    // legitimately be missing the trajectory a sensor names, so those reference rules are
    // deferred there — but the recovery contract is that everything complete before the
    // cut still stands, and a duplicate name among complete records is exactly that: no
    // later byte can repair it, so it is refused whether or not the file was cut.
    // A cut file defers only what a later record could still have supplied. If a Footer
    // went past, the record stream is complete — the Footer is the last record a file
    // carries — so a missing rig or frame is missing for good and refusing it is right,
    // even though the trailing magic never arrived.
    scene.provenance.check_with(truncated && !saw_footer)?;
    scene.objects.check()?;

    if !header.has_audio()
        && (!audio_descriptors.is_empty() || !audio_payloads.is_empty() || legacy_audio.is_some())
    {
        let (name, offset, source_id) =
            first_audio_record.expect("an audio record was retained above");
        let source = source_id.map_or_else(String::new, |id| format!(" for source id {id}"));
        return Err(Error::Malformed(format!(
            "the Header audio flag is clear, but an {name} record{source} at byte {offset} is \
             present; expected no audio records"
        )));
    }
    if !audio_descriptors.is_empty() && legacy_audio.is_some() {
        return Err(Error::Malformed(
            "the file mixes a legacy Audio record with Audio Source records".into(),
        ));
    }
    // A legacy Audio record can never coexist with new-format audio. Unlike an unmatched new
    // descriptor — which a lost Audio Source could still have matched in a truncated file — a
    // payload beside a legacy record is an orphan no later bytes can legitimize, so it is
    // refused even in recovery, matching the indexed reader.
    if legacy_audio.is_some() && !audio_payloads.is_empty() {
        let source_id = *audio_payloads.keys().next().expect("not empty");
        return Err(Error::Malformed(format!(
            "Audio Data id {source_id} has no matching Audio Source record"
        )));
    }
    for (source_id, descriptor) in audio_descriptors {
        let Some((data, _content_charge)) = audio_payloads.remove(&source_id) else {
            if truncated {
                continue;
            }
            return Err(Error::Malformed(format!(
                "Audio Source id {source_id} has no matching Audio Data record"
            )));
        };
        if data.len() as u64 != descriptor.data_length {
            return Err(Error::Malformed(format!(
                "Audio Source id {source_id} declares {} data bytes, its Audio Data record contains {}",
                descriptor.data_length,
                data.len()
            )));
        }
        for (index, keyframe) in descriptor.keyframes.iter().enumerate() {
            if keyframe.time < 0.0 || keyframe.time > header.duration_sec {
                return Err(Error::Malformed(format!(
                    "Audio Source id {source_id} keyframe {index} time {} is outside [0, {}]",
                    keyframe.time, header.duration_sec
                )));
            }
        }
        retained_record_bytes = push_streamed_retained_value(
            &mut scene.audio_sources,
            audio_source(descriptor, data),
            retained_record_bytes,
            "Audio Source collection",
            at,
            retained_limit.min(MAX_DECODED_SCENE_BYTES.saturating_sub(decoded_bytes)),
        )?;
    }
    if !audio_payloads.is_empty() && !truncated {
        let source_id = *audio_payloads.keys().next().expect("not empty");
        return Err(Error::Malformed(format!(
            "Audio Data id {source_id} has no matching Audio Source record"
        )));
    }
    if let Some(audio) = legacy_audio {
        retained_record_bytes = push_streamed_retained_value(
            &mut scene.audio_sources,
            AudioSource {
                source_id: 0,
                codec: audio.codec,
                start_sec: audio.start_sec,
                duration_sec: (header.duration_sec - audio.start_sec).max(0.0),
                spatial: false,
                channel_layout: String::new(),
                data: audio.data,
                ..AudioSource::default()
            },
            retained_record_bytes,
            "legacy Audio Source collection",
            at,
            retained_limit.min(MAX_DECODED_SCENE_BYTES.saturating_sub(decoded_bytes)),
        )?;
    }
    // Both scratch maps have now been consumed (or are no longer needed for truncated
    // recovery). Drop their nodes before assembly and remove the conservative charges;
    // descriptor strings/keyframes and payload Vecs were moved into `scene.audio_sources`
    // without duplicating their backing allocations.
    let orphan_payload_bytes = audio_payload_content_bytes(&audio_payloads)?;
    drop(audio_payloads);
    retained_record_bytes = subtract_streamed_retained_bytes(
        retained_record_bytes,
        orphan_payload_bytes,
        "released orphan Audio Data payloads",
        at,
    )?;
    retained_record_bytes = subtract_streamed_retained_bytes(
        retained_record_bytes,
        audio_descriptor_map_bytes,
        "released Audio Source map nodes",
        at,
    )?;
    retained_record_bytes = subtract_streamed_retained_bytes(
        retained_record_bytes,
        audio_payload_map_bytes,
        "released Audio Data map nodes",
        at,
    )?;
    if (!header.has_audio() && !scene.audio_sources.is_empty())
        || (header.has_audio() && scene.audio_sources.is_empty() && !truncated)
    {
        return Err(Error::Malformed(format!(
            "the Header audio flag is {}, but the file contains {} complete audio sources",
            if header.has_audio() { "set" } else { "clear" },
            scene.audio_sources.len()
        )));
    }

    // Band masks are needed only while records arrive.  Release them before assembly;
    // the two outer decoded collections remain live beside the assembled output and are
    // charged separately from the per-Chunk column buffers `assemble_with_retained`
    // measures itself.
    drop(chunk_band_masks);
    let decoded_collection_bytes = vector_bytes(&chunks)?
        .checked_add(vector_bytes(&chunk_bands)?)
        .ok_or_else(|| {
            Error::UnsupportedOperation("decoded collection bytes overflow at assembly".into())
        })?;
    let assembly_retained = retained_record_bytes
        .checked_add(decoded_collection_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation("assembly retained-byte count overflows".into())
        })?;
    scene.gaussians = assemble_with_retained(
        &chunks,
        &chunk_bands,
        &scene.windows,
        &header,
        assembly_retained,
    )?;
    scene.duration_sec = header.duration_sec;
    scene.header = header;
    scene.quantization = quant;
    scene.truncated = truncated;
    Ok(scene)
}

fn audio_source(source: rec::AudioSource, data: Vec<u8>) -> AudioSource {
    let spatial = source.spatial();
    let loop_ = source.loop_();
    AudioSource {
        source_id: source.source_id,
        name: source.name,
        codec: source.codec,
        channel_layout: source.channel_layout,
        start_sec: source.start_sec,
        duration_sec: source.duration_sec,
        gain: source.gain,
        spatial,
        loop_,
        position: source.position,
        rotation: source.rotation,
        keyframes: source.keyframes,
        interpolation: source.interpolation,
        data,
    }
}

fn retains_streamed_content(opcode: u8) -> bool {
    matches!(
        opcode,
        op::AUDIO
            | op::AUDIO_DATA
            | op::CAMERA
            | op::METADATA
            | op::ATTACHMENT
            | op::COORDINATE_FRAME
            | op::SENSOR_CALIBRATION
            | op::RIG_TRAJECTORY
            | op::GEODETIC_ANCHOR
            | op::OBJECT_TABLE
            | op::OBJECT_TRACK
            | op::STATISTICS
            | op::CHUNK_INDEX
            | op::SUMMARY_OFFSET
    )
}

fn add_streamed_retained_bytes(
    current: usize,
    added: usize,
    what: &str,
    offset: u64,
    retained_limit: usize,
) -> Result<usize> {
    let total = current.checked_add(added).ok_or_else(|| {
        Error::UnsupportedOperation(format!("the {what} byte count overflows at byte {offset}"))
    })?;
    if total > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the {what} reach {total} bytes at byte {offset}, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    Ok(total)
}

/// Push one retained value while charging the outer Vec's actual backing capacity.
fn push_streamed_retained_value<T>(
    values: &mut Vec<T>,
    value: T,
    current: usize,
    what: &str,
    offset: u64,
    retained_limit: usize,
) -> Result<usize> {
    let before = vector_bytes(values)?;
    if values.len() == values.capacity() {
        // Keep amortized Vec growth, but choose and validate the next geometric capacity
        // ourselves before asking the allocator. Its reported capacity is measured again
        // as the authoritative charge before the value is inserted.
        let target_capacity = if values.capacity() == 0 {
            4
        } else {
            values.capacity().checked_mul(2).ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "the {what} capacity overflows at byte {offset}"
                ))
            })?
        };
        let target_bytes = target_capacity
            .checked_mul(std::mem::size_of::<T>())
            .ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "the {what} allocation bytes overflow at byte {offset}"
                ))
            })?;
        let planned_added = target_bytes.checked_sub(before).ok_or_else(|| {
            Error::Malformed(format!(
                "the internal {what} planned capacity underflows at byte {offset}"
            ))
        })?;
        add_streamed_retained_bytes(current, planned_added, what, offset, retained_limit)?;
        values
            .try_reserve_exact(target_capacity - values.len())
            .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the {what} at byte {offset} could not reserve {target_capacity} values within the {retained_limit} byte retained-record ceiling: {error}"
            ))
        })?;
    }
    let after = vector_bytes(values)?;
    let added = after.checked_sub(before).ok_or_else(|| {
        Error::Malformed(format!(
            "the internal {what} capacity accounting underflows at byte {offset}"
        ))
    })?;
    let total = add_streamed_retained_bytes(current, added, what, offset, retained_limit)?;
    values.push(value);
    Ok(total)
}

/// Push one decode-pipeline value while charging the outer Vec that retains it.
///
/// The gaussian columns inside a `DecodedChunk` have their own accounting.  This covers
/// the collection slots themselves (`DecodedChunk`, its parallel SH map, and the band
/// mask), which remain live until assembly and are substantial at the record-count cap
/// even when every Chunk declares zero rows.
fn push_streamed_decoded_value<T>(
    values: &mut Vec<T>,
    value: T,
    current: usize,
    retained: usize,
    what: &str,
    offset: u64,
) -> Result<usize> {
    let before = vector_bytes(values)?;
    if values.len() == values.capacity() {
        let target_capacity = if values.capacity() == 0 {
            4
        } else {
            values.capacity().checked_mul(2).ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "the {what} capacity overflows at byte {offset}"
                ))
            })?
        };
        let target_bytes = target_capacity
            .checked_mul(std::mem::size_of::<T>())
            .ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "the {what} allocation bytes overflow at byte {offset}"
                ))
            })?;
        let planned_added = target_bytes.checked_sub(before).ok_or_else(|| {
            Error::Malformed(format!(
                "the internal {what} planned capacity underflows at byte {offset}"
            ))
        })?;
        let planned_decoded = current.checked_add(planned_added).ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the {what} decoded-byte count overflows at byte {offset}"
            ))
        })?;
        ensure_streamed_scene_bytes(retained, planned_decoded, offset)?;
        values
            .try_reserve_exact(target_capacity - values.len())
            .map_err(|error| {
                Error::UnsupportedOperation(format!(
                    "the {what} at byte {offset} could not reserve {target_capacity} values \
                     within the shared scene ceiling: {error}"
                ))
            })?;
    }
    let after = vector_bytes(values)?;
    let added = after.checked_sub(before).ok_or_else(|| {
        Error::Malformed(format!(
            "the internal {what} capacity accounting underflows at byte {offset}"
        ))
    })?;
    let total = current.checked_add(added).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "the {what} decoded-byte count overflows at byte {offset}"
        ))
    })?;
    ensure_streamed_scene_bytes(retained, total, offset)?;
    values.push(value);
    Ok(total)
}

/// Available prefix bytes while every previously completed record remains recoverable.
fn streamed_prefix_limit(current: usize, retained_limit: usize) -> u64 {
    let remaining = retained_limit.saturating_sub(current);
    // The parser constructs its owned value while the prefix is still borrowed. Reserving
    // half the remaining envelope for each side bounds that overlap; after the helper
    // returns, the prefix is dropped and only the parsed value's actual capacities remain
    // charged.
    (remaining / 2).min(crate::indexed_reader::MAX_FRONT_MATTER_BYTES as usize) as u64
}

/// Charge only the parsed singleton value that remains resident after replacement.
fn replace_streamed_retained_bytes(
    current: usize,
    replaced: usize,
    added: usize,
    what: &str,
    offset: u64,
    retained_limit: usize,
) -> Result<usize> {
    let without_replaced = current.checked_sub(replaced).ok_or_else(|| {
        Error::Malformed(format!(
            "the internal {what} accounting underflows at byte {offset}"
        ))
    })?;
    add_streamed_retained_bytes(without_replaced, added, what, offset, retained_limit)
}

/// Remove bytes whose parsed record no longer remains in the returned scene.
fn subtract_streamed_retained_bytes(
    current: usize,
    removed: usize,
    what: &str,
    offset: u64,
) -> Result<usize> {
    current.checked_sub(removed).ok_or_else(|| {
        Error::Malformed(format!(
            "the internal {what} accounting underflows at byte {offset}"
        ))
    })
}

fn decode_streamed_sh_values(
    cursor: &mut Cursor<'_>,
    count: usize,
    expected_channels: usize,
    decoded_bytes: usize,
) -> Result<DecodedStream> {
    let remaining = MAX_DECODED_SCENE_BYTES
        .checked_sub(decoded_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(
                "streamed SH decoding exhausted the aggregate decoded-scene budget".into(),
            )
        })?;
    let (_, values) =
        decode_stream_with_limit(cursor, Some(count), Some(expected_channels), remaining)?;
    Ok(values)
}

/// Decode a whole file already in memory.
pub fn read_bytes(data: &[u8]) -> Result<Scene> {
    read_from(io::Cursor::new(data), &ReadOptions::default())
}

/// Decode a file from disk, one record at a time.
pub fn read_path<P: AsRef<Path>>(path: P) -> Result<Scene> {
    let file = std::fs::File::open(path)?;
    read_from(file, &ReadOptions::default())
}

/// Keep the longest prefix of chunks whose spherical harmonic bands all match the first
/// chunk's, and drop the rest.
///
/// Bands are whole and a reader must never assemble a partial degree, so a chunk that lost
/// a band record to a truncation cannot be given one — and zero-filling it would fabricate
/// appearance the file never carried. Dropping those gaussians is the honest recovery: what
/// survives is exactly the prefix that arrived intact, which is what a truncated file
/// promises and all it promises.
fn drop_incomplete_trailing_bands(
    chunks: &mut Vec<DecodedChunk>,
    chunk_bands: &mut Vec<BTreeMap<u8, DecodedStream>>,
    intervals: &mut Vec<(f64, f64)>,
) {
    let Some(full) = chunk_bands
        .first()
        .map(|b| b.keys().copied().collect::<Vec<u8>>())
    else {
        return;
    };
    let keep = chunk_bands
        .iter()
        .position(|b| b.keys().copied().collect::<Vec<u8>>() != full)
        .unwrap_or(chunk_bands.len());
    if keep == chunk_bands.len() {
        return;
    }
    chunks.truncate(keep);
    chunk_bands.truncate(keep);
    intervals.truncate(keep.min(intervals.len()));
}

/// One ceiling for every decoded chunk retained on the way to one resident scene.
pub(crate) const MAX_DECODED_SCENE_BYTES: usize = MAX_STREAM_BYTES as usize;

fn vector_bytes<T>(values: &Vec<T>) -> Result<usize> {
    values
        .capacity()
        .checked_mul(std::mem::size_of::<T>())
        .ok_or_else(|| Error::UnsupportedOperation("decoded vector byte size overflows".into()))
}

pub(crate) fn decoded_stream_resident_bytes(stream: &DecodedStream) -> Result<usize> {
    vector_bytes(&stream.values)
}

pub(crate) fn decoded_band_map_node_bytes(len: usize) -> Result<usize> {
    let per_node = std::mem::size_of::<(u8, DecodedStream)>()
        .checked_add(4 * std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation("decoded SH map-row bytes overflow".into()))?;
    len.checked_mul(per_node)
        .ok_or_else(|| Error::UnsupportedOperation("decoded SH map bytes overflow".into()))
}

pub(crate) fn decoded_chunk_resident_bytes(
    chunk: &DecodedChunk,
    bands: &BTreeMap<u8, DecodedStream>,
) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        vector_bytes(&chunk.positions)?,
        vector_bytes(&chunk.scales)?,
        vector_bytes(&chunk.rotations)?,
        vector_bytes(&chunk.colors)?,
        vector_bytes(&chunk.motions)?,
        vector_bytes(&chunk.mu_t)?,
        vector_bytes(&chunk.sigma_t)?,
        vector_bytes(&chunk.window_index)?,
        chunk
            .source_index
            .as_ref()
            .map(vector_bytes)
            .transpose()?
            .unwrap_or(0),
        chunk
            .object_id
            .as_ref()
            .map(vector_bytes)
            .transpose()?
            .unwrap_or(0),
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("decoded Chunk resident bytes overflow".into())
        })?;
    }
    for stream in bands.values() {
        total = total
            .checked_add(decoded_stream_resident_bytes(stream)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("decoded SH resident bytes overflow".into())
            })?;
    }
    total = total
        .checked_add(decoded_band_map_node_bytes(bands.len())?)
        .ok_or_else(|| Error::UnsupportedOperation("decoded SH map bytes overflow".into()))?;
    Ok(total)
}

pub(crate) fn gaussian_set_resident_bytes(gaussians: &GaussianSet) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        vector_bytes(&gaussians.positions)?,
        vector_bytes(&gaussians.scales)?,
        vector_bytes(&gaussians.rotations)?,
        vector_bytes(&gaussians.colors)?,
        vector_bytes(&gaussians.motions)?,
        vector_bytes(&gaussians.mu_t)?,
        vector_bytes(&gaussians.sigma_t)?,
        vector_bytes(&gaussians.win_lo)?,
        vector_bytes(&gaussians.win_hi)?,
        gaussians
            .sh
            .as_ref()
            .map(vector_bytes)
            .transpose()?
            .unwrap_or(0),
        gaussians
            .source_index
            .as_ref()
            .map(vector_bytes)
            .transpose()?
            .unwrap_or(0),
        gaussians
            .object_id
            .as_ref()
            .map(vector_bytes)
            .transpose()?
            .unwrap_or(0),
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("resident GaussianSet bytes overflow".into())
        })?;
    }
    Ok(total)
}

pub(crate) fn add_decoded_scene_bytes(current: usize, added: usize) -> Result<usize> {
    let total = current.checked_add(added).ok_or_else(|| {
        Error::UnsupportedOperation("aggregate decoded-state bytes overflow".into())
    })?;
    if total > MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "aggregate decoded state needs {total} resident bytes, past the {MAX_DECODED_SCENE_BYTES} byte scene ceiling"
        )));
    }
    Ok(total)
}

fn ensure_streamed_scene_bytes(retained: usize, decoded: usize, offset: u64) -> Result<()> {
    let total = retained.checked_add(decoded).ok_or_else(|| {
        Error::UnsupportedOperation("streamed retained and decoded bytes overflow".into())
    })?;
    if total > MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the streamed scene retains {retained} record bytes and {decoded} decoded-state bytes after byte {offset}, past the {MAX_DECODED_SCENE_BYTES} byte shared scene ceiling"
        )));
    }
    Ok(())
}

/// Concatenate decoded chunks into one scene-wide set.
pub fn assemble(
    chunks: &[DecodedChunk],
    chunk_bands: &[BTreeMap<u8, DecodedStream>],
    windows: &[(f64, f64)],
    header: &rec::Header,
) -> Result<GaussianSet> {
    assemble_with_retained(chunks, chunk_bands, windows, header, 0)
}

pub(crate) fn assemble_with_retained(
    chunks: &[DecodedChunk],
    chunk_bands: &[BTreeMap<u8, DecodedStream>],
    windows: &[(f64, f64)],
    header: &rec::Header,
    retained_elsewhere: usize,
) -> Result<GaussianSet> {
    let table = window_table_or_default(windows);
    if chunks.len() != chunk_bands.len() {
        return Err(Error::Malformed(format!(
            "{} decoded Chunks accompany {} SH band maps",
            chunks.len(),
            chunk_bands.len()
        )));
    }
    let retained_bytes =
        chunks
            .iter()
            .zip(chunk_bands)
            .try_fold(0usize, |total, (chunk, bands)| {
                total
                    .checked_add(decoded_chunk_resident_bytes(chunk, bands)?)
                    .ok_or_else(|| {
                        Error::UnsupportedOperation("aggregate decoded Chunk bytes overflow".into())
                    })
            })?;
    let planned_count_capacity = if chunks.is_empty() {
        0
    } else {
        chunks.len().max(4)
    };
    let planned_count_bytes = planned_count_capacity
        .checked_mul(std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation("Chunk count-vector bytes overflow".into()))?;
    let preflight_peak = retained_bytes
        .checked_add(retained_elsewhere)
        .and_then(|bytes| bytes.checked_add(planned_count_bytes))
        .ok_or_else(|| Error::UnsupportedOperation("Chunk count-vector peak overflows".into()))?;
    if preflight_peak > MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "assembling {} Chunks needs {planned_count_bytes} count-vector bytes beside {retained_bytes} decoded Chunk bytes and {retained_elsewhere} other retained bytes, past the {MAX_DECODED_SCENE_BYTES} byte scene ceiling",
            chunks.len()
        )));
    }
    let mut counts = Vec::new();
    counts.try_reserve_exact(chunks.len()).map_err(|error| {
        Error::UnsupportedOperation(format!(
            "the assembler could not reserve its validated {}-entry Chunk count vector: {error}",
            chunks.len()
        ))
    })?;
    counts.extend(chunks.iter().map(|chunk| chunk.count));
    let total = counts.iter().try_fold(0usize, |total, count| {
        total
            .checked_add(*count)
            .ok_or_else(|| Error::UnsupportedOperation("aggregate gaussian count overflows".into()))
    })?;
    let sh_coefficients = if header.sh_degree > 0 {
        crate::sh::validate_chunk_bands(&counts, chunk_bands)?
    } else {
        None
    };
    let sh_output_bytes = sh_coefficients
        .unwrap_or(0)
        .checked_mul(3)
        .ok_or_else(|| Error::UnsupportedOperation("assembled SH row size overflows".into()))?;
    let output_bytes_per_gaussian = 96usize
        .checked_add(sh_output_bytes)
        .ok_or_else(|| Error::UnsupportedOperation("assembled row size overflows".into()))?;
    let output_bytes = total
        .checked_mul(output_bytes_per_gaussian)
        .ok_or_else(|| Error::UnsupportedOperation("assembled scene byte size overflows".into()))?;
    let counts_bytes = vector_bytes(&counts)?;
    let peak_bytes = retained_bytes
        .checked_add(output_bytes)
        .and_then(|bytes| bytes.checked_add(counts_bytes))
        .and_then(|bytes| bytes.checked_add(retained_elsewhere))
        .ok_or_else(|| Error::UnsupportedOperation("assembled scene peak bytes overflow".into()))?;
    if peak_bytes > MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "assembling {total} gaussians needs at least {peak_bytes} resident bytes across decoded Chunks and scene output, past the {MAX_DECODED_SCENE_BYTES} byte scene ceiling"
        )));
    }

    let mut out = GaussianSet {
        sh_degree: header.sh_degree,
        ..Default::default()
    };
    out.positions.reserve(total * 3);
    out.scales.reserve(total * 3);
    out.rotations.reserve(total * 4);
    out.colors.reserve(total * 4);
    out.motions.reserve(total * 3);
    out.mu_t.reserve(total);
    out.sigma_t.reserve(total);
    out.win_lo.reserve(total);
    out.win_hi.reserve(total);

    let mut source_index: Option<Vec<i64>> = Some(Vec::with_capacity(total));
    let mut object_id: Vec<u32> = Vec::with_capacity(total);
    let mut saw_object_id = false;
    for chunk in chunks {
        out.positions.extend_from_slice(&chunk.positions);
        out.scales.extend_from_slice(&chunk.scales);
        out.rotations.extend_from_slice(&chunk.rotations);
        out.colors.extend_from_slice(&chunk.colors);
        out.motions.extend_from_slice(&chunk.motions);
        out.mu_t.extend_from_slice(&chunk.mu_t);
        out.sigma_t.extend_from_slice(&chunk.sigma_t);
        // Decoding checked these indices against the table it was handed; assembly is a
        // second caller with its own `windows`, and an index that fits one table need not
        // fit another. Checking again costs a comparison and turns what would be a panic —
        // undefined behaviour across the C ABI, an abort under `panic=abort` — into the
        // refusal §5.4 requires.
        for wi in &chunk.window_index {
            let index = crate::chunk::check_window_index(i64::from(*wi), table.len())? as usize;
            let (lo, hi) = table[index];
            out.win_lo.push(lo as f32);
            out.win_hi.push(hi as f32);
        }
        match (&mut source_index, &chunk.source_index) {
            (Some(acc), Some(src)) => acc.extend_from_slice(src),
            _ => source_index = None,
        }
        match &chunk.object_id {
            Some(ids) => {
                object_id.extend_from_slice(ids);
                saw_object_id = true;
            }
            None => object_id.resize(object_id.len() + chunk.count, 0),
        }
    }
    out.source_index = source_index.filter(|s| s.len() == total && total > 0);
    out.object_id = (saw_object_id && object_id.len() == total && total > 0).then_some(object_id);

    if header.sh_degree > 0 {
        if let Some((sh, coefficients)) = merge_chunk_bands(&counts, chunk_bands)? {
            out.sh = Some(sh);
            out.sh_coefficients = coefficients;
        }
    }
    Ok(out)
}

/// Fill `buf` completely or fail; used where a short read is a cut file.
fn read_exactly<R: Read>(source: &mut R, buf: &mut [u8]) -> Result<()> {
    source.read_exact(buf).map_err(|e| {
        if e.kind() == io::ErrorKind::UnexpectedEof {
            Error::Truncated(format!(
                "the file ends inside its first {} bytes",
                buf.len()
            ))
        } else {
            Error::Io(e)
        }
    })
}

/// Fill as much of `buf` as the source has, returning how many bytes arrived.
fn read_up_to<R: Read>(source: &mut R, buf: &mut [u8]) -> Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match source.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(Error::Io(e)),
        }
    }
    Ok(filled)
}

/// Parse the known prefix of an extensible record from a forward-only source.
///
/// Prefixes grow geometrically, so ordinary records cost one small read and a record with
/// a large known field remains supported up to the same fixed ceiling as indexed reads.
/// Once parsing succeeds, the rest is consumed into a sink. A declared suffix that is
/// physically cut is still a truncation: skipping it does not make it optional on the
/// wire.
fn read_parsed_content<R, T>(
    source: &mut R,
    length: u64,
    prefix_limit: u64,
    what: &str,
    offset: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<ParsedContent<T>>
where
    R: Read,
{
    read_parsed_content_observed(source, length, prefix_limit, what, offset, parse, |_| {})
}

/// [`read_parsed_content`] with an observer for every content byte consumed.
///
/// Statistics uses this to checksum its entire legal extension suffix while retaining
/// only the parsed version-1 prefix. The observer sees each wire byte exactly once,
/// whether it belonged to the growing prefix or the discarded suffix.
fn read_parsed_content_observed<R, T>(
    source: &mut R,
    length: u64,
    prefix_limit: u64,
    what: &str,
    offset: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
    mut observe: impl FnMut(&[u8]),
) -> Result<ParsedContent<T>>
where
    R: Read,
{
    let cap = prefix_limit.min(crate::indexed_reader::MAX_FRONT_MATTER_BYTES);
    let maximum = length.min(cap);
    let mut target = maximum.min(crate::indexed_reader::HEAD_PROBE);
    let mut prefix = Vec::new();
    loop {
        let old_len = prefix.len();
        resize_prefix_exact(&mut prefix, target as usize, cap, what, offset)?;
        let got = read_up_to(source, &mut prefix[old_len..])?;
        observe(&prefix[old_len..old_len + got]);
        if got != prefix.len() - old_len {
            prefix.truncate(old_len + got);
            return Ok(ParsedContent::Cut);
        }

        let complete = target == length;
        match parse(&prefix, complete) {
            Ok(value) => {
                let suffix = length - target;
                if !skip_exactly_observed(source, suffix, &mut observe)? {
                    return Ok(ParsedContent::Cut);
                }
                return Ok(ParsedContent::Complete(value, target as usize));
            }
            Err(Error::Truncated(_)) if target < maximum => {
                target = target.max(1).saturating_mul(2).min(maximum);
            }
            Err(Error::Truncated(_)) if length > maximum => {
                let mut probe = [0u8; 1];
                let got = read_up_to(source, &mut probe)?;
                observe(&probe[..got]);
                if got == 0 {
                    return Ok(ParsedContent::Cut);
                }
                return Err(Error::UnsupportedOperation(format!(
                    "the {what} at byte {offset} has required fields beyond the {cap} byte streamed-reader prefix ceiling"
                )));
            }
            Err(error) => return Err(error.at_record(what, offset)),
        }
    }
}

fn resize_prefix_exact(
    prefix: &mut Vec<u8>,
    target: usize,
    cap: u64,
    what: &str,
    offset: u64,
) -> Result<()> {
    let additional = target - prefix.len();
    // `resize` may otherwise double the allocation when a required known field ends
    // just beyond the current probe. The retained-prefix budget charges `target`, so
    // reserve exactly the admitted delta before extending the initialized length.
    prefix.try_reserve_exact(additional).map_err(|error| {
        Error::UnsupportedOperation(format!(
            "the {what} at byte {offset} could not reserve its next {additional} prefix bytes within the {cap} byte streamed-reader prefix ceiling: {error}"
        ))
    })?;
    prefix.resize(target, 0);
    Ok(())
}

/// One record's content, read in bounded blocks.
///
/// The buffer grows as bytes actually arrive rather than being sized from the declared
/// length, so a crafted length cannot make this allocate what the file does not contain.
/// `Read::read_to_end` on a `Take` will not do: it reserves the limit up front, which is
/// exactly the allocation this has to avoid — a fuzz case with a 115 MB length field in a
/// 3 KB file is what said so.
fn read_content_capped<R: Read>(
    source: &mut R,
    length: u64,
    limit: usize,
    what: &str,
    offset: u64,
) -> Result<Vec<u8>> {
    const BLOCK: usize = 64 * 1024;
    let mut out: Vec<u8> = Vec::new();
    let mut block = vec![0u8; BLOCK];
    let mut remaining = length;
    while remaining > 0 {
        if out.len() == limit {
            let mut probe = [0u8; 1];
            if read_up_to(source, &mut probe)? == 0 {
                return Err(Error::Truncated(format!(
                    "a record declares {length} bytes of content and only {} remain",
                    out.len()
                )));
            }
            return Err(Error::UnsupportedOperation(format!(
                "the {what} at byte {offset} exceeds the {limit} bytes remaining in the streamed retained-content ceiling"
            )));
        }
        let want = remaining.min(BLOCK as u64) as usize;
        let want = want.min(limit - out.len());
        // `extend_from_slice` otherwise grows geometrically: a legal record one byte
        // beyond a power-of-two capacity can retain almost twice the bytes charged to
        // this content. Reserve only the next checked block so capacity follows bytes
        // admitted under `limit`, without trusting the file's whole declared length.
        out.try_reserve_exact(want).map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the {what} at byte {offset} could not reserve its next {want} bytes within the {limit} byte streamed retained-content ceiling: {error}"
            ))
        })?;
        let got = read_up_to(source, &mut block[..want])?;
        if got == 0 {
            return Err(Error::Truncated(format!(
                "a record declares {length} bytes of content and only {} remain",
                out.len()
            )));
        }
        out.extend_from_slice(&block[..got]);
        remaining -= got as u64;
    }
    Ok(out)
}

/// Step over a record's content without keeping it. `false` when the file ends first.
fn skip_exactly<R: Read>(source: &mut R, length: u64) -> Result<bool> {
    let moved = io::copy(&mut source.take(length), &mut io::sink())?;
    Ok(moved == length)
}

/// Step over content in fixed blocks while exposing the bytes to an incremental digest.
fn skip_exactly_observed<R: Read>(
    source: &mut R,
    length: u64,
    observe: &mut impl FnMut(&[u8]),
) -> Result<bool> {
    const BLOCK: usize = 8 * 1024;
    let mut block = [0u8; BLOCK];
    let mut remaining = length;
    while remaining > 0 {
        let want = remaining.min(BLOCK as u64) as usize;
        let got = read_up_to(source, &mut block[..want])?;
        observe(&block[..got]);
        if got != want {
            return Ok(false);
        }
        remaining -= got as u64;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::Cursor as IoCursor;

    #[test]
    fn capped_content_does_not_grow_geometrically_past_its_charge() {
        let length = 64 * 1024 + 17;
        let bytes = vec![0x5a; length];
        let content = read_content_capped(
            &mut IoCursor::new(&bytes),
            length as u64,
            length,
            "test record",
            41,
        )
        .expect("the exact capped content");
        assert_eq!(content.len(), length);
        assert_eq!(
            content.capacity(),
            length,
            "the second block must not double a power-of-two Vec allocation"
        );
    }

    #[test]
    fn legacy_audio_reuses_the_streamed_record_buffer_for_its_payload() {
        let encoded = rec::Audio {
            codec: "opus".into(),
            start_sec: 1.25,
            data: vec![0x5a; 64 * 1024 + 17],
        }
        .encode();
        let content = encoded[RECORD_HEADER_SIZE..].to_vec();
        let pointer = content.as_ptr();
        let capacity = content.capacity();

        let (audio, descriptor_bytes) =
            rec::Audio::into_payload_with_descriptor_budget(content, 64)
                .expect("consume legacy Audio content");
        assert_eq!(audio.codec, "opus");
        assert_eq!(descriptor_bytes, "opus".len());
        assert_eq!(audio.start_sec, 1.25);
        assert_eq!(audio.data.len(), 64 * 1024 + 17);
        assert_eq!(audio.data.as_ptr(), pointer);
        assert_eq!(audio.data.capacity(), capacity);
    }

    #[test]
    fn audio_source_finalization_moves_the_keyframe_allocation() {
        let descriptor = rec::AudioSource {
            keyframes: vec![rec::AudioSourceKeyframe::default(); 257],
            ..Default::default()
        };
        let pointer = descriptor.keyframes.as_ptr();
        let capacity = descriptor.keyframes.capacity();

        let source = audio_source(descriptor, Vec::new());
        assert_eq!(source.keyframes.as_ptr(), pointer);
        assert_eq!(source.keyframes.capacity(), capacity);
    }

    #[test]
    fn parsed_prefix_does_not_grow_geometrically_past_its_charge() {
        let mut prefix = Vec::new();
        resize_prefix_exact(&mut prefix, 8 * 1024, 9_000, "test record", 43)
            .expect("the first probe");
        resize_prefix_exact(&mut prefix, 9_000, 9_000, "test record", 43)
            .expect("the final admitted prefix");
        assert_eq!(prefix.len(), 9_000);
        assert_eq!(
            prefix.capacity(),
            9_000,
            "the second probe must not double the prefix allocation"
        );
    }

    #[test]
    fn streamed_prefix_reserves_half_the_envelope_for_its_parsed_value() {
        assert_eq!(streamed_prefix_limit(400, 512), 56);
        assert_eq!(streamed_prefix_limit(511, 512), 0);
    }

    #[test]
    fn object_table_prefix_accounting_includes_resident_entry_amplification() {
        let table = rec::ObjectTable {
            embedding_dim: 0,
            entries: (1..=1024)
                .map(|object_id| rec::ObjectTableEntry {
                    object_id,
                    ..Default::default()
                })
                .collect(),
        };
        let encoded = table.encode(&[]).expect("encode a legal Object Table");
        let parsed = PrefixRecord::ObjectTable(
            rec::ObjectTable::parse(&encoded[RECORD_HEADER_SIZE..])
                .expect("parse the Object Table"),
        );
        let resident = prefix_record_resident_bytes(&parsed).expect("measure parsed storage");
        assert!(
            resident > encoded.len(),
            "entry structs amplify {} wire bytes into {resident} resident bytes",
            encoded.len()
        );
        let content = &encoded[RECORD_HEADER_SIZE..];
        let working = object_table_prefix_parse_working_bytes(content)
            .expect("allocation-free Object Table preflight");
        assert!(working > content.len() + resident);
        let error = check_object_table_prefix_parse_budget(content, working - 1, 73)
            .expect_err("the parsed allocation is refused before ObjectTable::parse");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 73"), "{error}");
        check_object_table_prefix_parse_budget(content, working, 73)
            .expect("the exact shared envelope is admitted");
    }

    #[test]
    fn header_attributes_are_preflighted_before_the_allocating_parser() {
        let header = rec::Header {
            aabb: vec![0.0; 6],
            attributes: (0..1024)
                .map(|index| (format!("key-{index}"), String::new()))
                .collect(),
            ..rec::Header::default()
        };
        let encoded = header.encode(&[]);
        let content = &encoded[RECORD_HEADER_SIZE..];
        let working =
            header_prefix_parse_working_bytes(content).expect("allocation-free Header preflight");
        assert!(working > content.len());
        let error = check_header_prefix_parse_budget(content, working - 1, 91)
            .expect_err("the Header map must be refused before allocating its nodes");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 91"), "{error}");
        check_header_prefix_parse_budget(content, working, 91)
            .expect("the exact Header parse allowance is admitted");
    }

    #[test]
    fn quantization_bounds_are_preflighted_before_the_allocating_parser() {
        let quantization = rec::Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: vec![0.0; 3],
            bounds: (0..1024)
                .map(|index| (format!("bound-{index}"), String::new()))
                .collect(),
            ..Default::default()
        };
        let encoded = quantization.encode(&[]);
        let content = &encoded[RECORD_HEADER_SIZE..];
        let working = quantization_prefix_parse_working_bytes(content)
            .expect("allocation-free Quantization preflight");
        let error = check_quantization_prefix_parse_budget(content, working - 1, 92)
            .expect_err("the bounds map must be refused before allocating its nodes");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 92"), "{error}");
        check_quantization_prefix_parse_budget(content, working, 92)
            .expect("the exact Quantization parse allowance is admitted");
    }

    #[test]
    fn window_rows_are_preflighted_before_the_allocating_parser() {
        let table = rec::WindowTable {
            windows: vec![(0.0, 1.0); 1024],
        };
        let encoded = table.encode();
        let content = &encoded[RECORD_HEADER_SIZE..];
        let working = window_table_prefix_parse_working_bytes(content)
            .expect("allocation-free Window Table preflight");
        let error = check_window_table_prefix_parse_budget(content, working - 1, 93)
            .expect_err("the row Vec must be refused before allocation");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 93"), "{error}");
        check_window_table_prefix_parse_budget(content, working, 93)
            .expect("the exact Window Table parse allowance is admitted");
    }

    #[test]
    fn streamed_metadata_maps_are_preflighted_before_parse() {
        let metadata = rec::Metadata {
            name: "capture".into(),
            entries: (0..1024)
                .map(|index| (format!("entry-{index}"), String::new()))
                .collect(),
        };
        let encoded = metadata.encode();
        let content = &encoded[RECORD_HEADER_SIZE..];
        let projected = crate::indexed_reader::metadata_prefix_resident_bound(content)
            .expect("allocation-free Metadata preflight");
        assert!(projected > content.len());
        let working = content.len() + projected;
        let error = check_metadata_prefix_parse_budget(content, working - 1, 94)
            .expect_err("the Metadata map must be refused before allocation");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 94"), "{error}");
        check_metadata_prefix_parse_budget(content, working, 94)
            .expect("the exact Metadata parse allowance is admitted");
    }

    #[test]
    fn streamed_audio_maps_charge_nodes_before_insertion() {
        let descriptor_node =
            streamed_btree_node_bytes::<u32, rec::AudioSource>(1, "streamed Audio Source").unwrap();
        let payload_node =
            streamed_btree_node_bytes::<u32, (Vec<u8>, usize)>(1, "streamed Audio Data").unwrap();
        let exact = descriptor_node + payload_node;
        let retained =
            add_streamed_retained_bytes(0, descriptor_node, "Audio Source map node", 17, exact)
                .expect("the descriptor node fits");
        add_streamed_retained_bytes(retained, payload_node, "Audio Data map node", 29, exact)
            .expect("both map nodes fit exactly");
        let error = add_streamed_retained_bytes(
            retained,
            payload_node,
            "Audio Data map node",
            29,
            exact - 1,
        )
        .expect_err("one byte below both live map nodes must refuse before insertion");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
    }

    #[test]
    fn dropped_orphan_audio_payloads_release_their_content_charges() {
        let payloads = BTreeMap::from([(7, (vec![0; 8], 20)), (9, (vec![0; 16], 28))]);
        assert_eq!(audio_payload_content_bytes(&payloads).unwrap(), 48);
        assert_eq!(
            subtract_streamed_retained_bytes(100, 48, "orphan payloads", 91).unwrap(),
            52
        );
    }

    #[test]
    fn assembly_preflights_the_chunk_count_vector() {
        let chunks = vec![DecodedChunk::default()];
        let bands = vec![BTreeMap::new()];
        let planned = 4 * std::mem::size_of::<usize>();
        let error = assemble_with_retained(
            &chunks,
            &bands,
            &[],
            &rec::Header::default(),
            MAX_DECODED_SCENE_BYTES - planned + 1,
        )
        .expect_err("the count scratch must be refused before allocation");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("count-vector"), "{error}");
    }

    #[test]
    fn retained_records_and_decoded_state_share_one_envelope() {
        ensure_streamed_scene_bytes(MAX_DECODED_SCENE_BYTES - 1, 1, 17)
            .expect("the exact shared ceiling is legal");
        let error = ensure_streamed_scene_bytes(MAX_DECODED_SCENE_BYTES - 1, 2, 17).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("shared scene ceiling"),
            "{error}"
        );
    }

    #[test]
    fn retained_collection_backing_is_charged_at_its_actual_capacity() {
        let mut values = Vec::new();
        let mut retained = 0usize;
        for offset in 0..257 {
            retained = push_streamed_retained_value(
                &mut values,
                rec::Metadata::default(),
                retained,
                "Metadata collection",
                offset,
                MAX_STREAM_BYTES as usize,
            )
            .expect("the collection remains well below its ceiling");
        }
        assert_eq!(retained, vector_bytes(&values).unwrap());
        assert!(retained > 257 * std::mem::size_of::<rec::Metadata>());
    }

    #[test]
    fn decoded_chunk_collection_is_preflighted_before_vec_growth() {
        let mut chunks: Vec<DecodedChunk> = Vec::new();
        let first_capacity_bytes = 4 * std::mem::size_of::<DecodedChunk>();
        let error = push_streamed_decoded_value(
            &mut chunks,
            DecodedChunk::default(),
            0,
            MAX_DECODED_SCENE_BYTES - first_capacity_bytes + 1,
            "decoded Chunk collection",
            71,
        )
        .expect_err("one byte below the planned backing allocation must refuse");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("shared scene ceiling"),
            "{error}"
        );
        assert_eq!(chunks.capacity(), 0, "the refusal precedes allocation");

        push_streamed_decoded_value(
            &mut chunks,
            DecodedChunk::default(),
            MAX_DECODED_SCENE_BYTES - first_capacity_bytes,
            0,
            "decoded Chunk collection",
            71,
        )
        .expect("the exact scene ceiling is admitted");
        assert_eq!(chunks.capacity(), 4);
    }

    #[test]
    fn streamed_summary_offset_errors_name_the_record_and_byte() {
        let mut data = minimal_streamed_front(0);
        let offset = data.len() as u64;
        crate::serialization::put_record(&mut data, op::SUMMARY_OFFSET, &[0]);
        data.extend_from_slice(&MAGIC);

        let error = read_from(IoCursor::new(data), &ReadOptions::default()).unwrap_err();
        assert!(matches!(error, Error::Truncated(_)), "{error}");
        assert!(
            error.to_string().contains("Summary Offset record"),
            "{error}"
        );
        assert!(
            error.to_string().contains(&format!("byte {offset}")),
            "{error}"
        );
    }

    #[test]
    fn streamed_summary_crc_does_not_retain_a_second_copy() {
        const RETAINED_LIMIT: usize = 48 * 1024;
        let mut data = minimal_streamed_front(0);
        let mut statistics = rec::Statistics {
            gaussian_count: 0,
            chunk_count: 0,
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
        }
        .encode();
        append_record_suffix(&mut statistics, &vec![0x5a; 40 * 1024]);
        let summary_start = data.len() as u64;
        let summary_crc = crate::serialization::crc32(&statistics);
        data.extend_from_slice(&statistics);
        data.extend_from_slice(
            &rec::Footer {
                summary_start,
                summary_offset_start: 0,
                summary_crc,
            }
            .encode(),
        );
        data.extend_from_slice(&MAGIC);

        let scene = read_from_with_limits(
            IoCursor::new(data),
            &ReadOptions::default(),
            RETAINED_LIMIT,
            crate::indexed_reader::MAX_RETAINED_RECORDS,
        )
        .expect("the summary is checksummed without retaining duplicate record bytes");
        assert_eq!(scene.summary_crc_ok, Some(true));
    }

    #[test]
    fn attachment_reuses_the_streamed_record_buffer_for_its_payload() {
        let encoded = rec::Attachment {
            name: "preview".into(),
            media_type: "image/avif".into(),
            data: vec![0x5a; 64 * 1024 + 17],
        }
        .encode();
        let content = encoded[RECORD_HEADER_SIZE..].to_vec();
        let pointer = content.as_ptr();
        let capacity = content.capacity();

        let (attachment, descriptor_bytes) =
            rec::Attachment::into_payload_with_descriptor_budget(content, 64)
                .expect("consume Attachment content");
        assert_eq!(attachment.name, "preview");
        assert_eq!(attachment.media_type, "image/avif");
        assert_eq!(descriptor_bytes, "preview".len() + "image/avif".len());
        assert_eq!(attachment.data.len(), 64 * 1024 + 17);
        assert_eq!(attachment.data.as_ptr(), pointer);
        assert_eq!(attachment.data.capacity(), capacity);
    }

    #[test]
    fn attachment_descriptor_is_refused_before_it_exceeds_its_budget() {
        let encoded = rec::Attachment {
            name: "large descriptor".repeat(64),
            media_type: "application/octet-stream".into(),
            data: vec![0x5a; 32],
        }
        .encode();
        let content = encoded[RECORD_HEADER_SIZE..].to_vec();
        let descriptor_bytes = "large descriptor".len() * 64 + "application/octet-stream".len();

        let error =
            rec::Attachment::into_payload_with_descriptor_budget(content, descriptor_bytes - 1)
                .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("descriptor"), "{error}");
    }

    #[test]
    fn streamed_prefix_parser_never_retains_a_large_legal_suffix() {
        let encoded = rec::Header {
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(&vec![
            0x5a;
            crate::indexed_reader::HEAD_PROBE as usize * 128
        ]);
        let content = &encoded[RECORD_HEADER_SIZE..];
        let largest_prefix = Cell::new(0usize);
        let parsed = read_parsed_content(
            &mut IoCursor::new(content),
            content.len() as u64,
            crate::indexed_reader::MAX_FRONT_MATTER_BYTES,
            "Header record",
            17,
            |prefix, _| {
                largest_prefix.set(largest_prefix.get().max(prefix.len()));
                rec::Header::parse(prefix)
            },
        )
        .expect("known Header fields fit the first production probe");
        let ParsedContent::Complete(parsed, _) = parsed else {
            panic!("the complete test resource was reported cut")
        };

        assert_eq!(parsed.duration_sec, 1.0);
        assert!(
            largest_prefix.get() <= crate::indexed_reader::HEAD_PROBE as usize,
            "the parser retained {} bytes of a legal suffix",
            largest_prefix.get()
        );
    }

    #[test]
    fn impossible_counted_prefix_is_malformed_before_the_streamed_cap() {
        let mut body = u32::MAX.to_le_bytes().to_vec();
        body.resize(16, 0);
        let error = read_parsed_content(
            &mut IoCursor::new(&body),
            body.len() as u64,
            4,
            "Window Table record",
            17,
            |bytes, _| {
                rec::preflight_counted_record_length(op::WINDOW_TABLE, bytes, body.len() as u64)?;
                rec::WindowTable::parse(bytes)
            },
        )
        .err()
        .expect("the impossible count is rejected");
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("4294967295 rows"), "{error}");
        assert!(error.to_string().contains("record declares 16"), "{error}");
    }

    #[test]
    fn statistics_extension_suffix_does_not_consume_later_record_budget() {
        const RETAINED_LIMIT: usize = 12 * 1024;
        let mut data = minimal_streamed_front(0);
        let mut statistics = rec::Statistics {
            gaussian_count: 0,
            chunk_count: 0,
            duration_sec: 1.0,
            aabb: vec![0.0; 6],
        }
        .encode();
        append_record_suffix(&mut statistics, &vec![0x5a; 16 * 1024]);
        data.extend_from_slice(&statistics);
        data.extend_from_slice(
            &rec::Metadata {
                name: "after-statistics".into(),
                entries: BTreeMap::from([("note".into(), "x".repeat(1024))]),
            }
            .encode(),
        );
        data.extend_from_slice(&MAGIC);

        let scene = read_from_with_limits(
            IoCursor::new(data),
            &ReadOptions::default(),
            RETAINED_LIMIT,
            crate::indexed_reader::MAX_RETAINED_RECORDS,
        )
        .expect("the discarded Statistics suffix must not consume retained-record budget");
        assert_eq!(scene.statistics.as_ref().unwrap().duration_sec, 1.0);
        assert_eq!(scene.metadata[0].name, "after-statistics");
    }

    #[test]
    fn streamed_metadata_discards_a_large_legal_extension_suffix() {
        const RETAINED_LIMIT: usize = 4 * 1024;
        let mut data = minimal_streamed_front(0);
        let mut metadata = rec::Metadata {
            name: "capture".into(),
            entries: [("author".into(), "Avala".into())].into(),
        }
        .encode();
        append_record_suffix(&mut metadata, &[0x5a; 16 * 1024]);
        data.extend_from_slice(&metadata);
        data.extend_from_slice(&rec::Footer::default().encode());
        data.extend_from_slice(&MAGIC);

        let scene = read_from_with_limits(
            IoCursor::new(data),
            &ReadOptions::default(),
            RETAINED_LIMIT,
            crate::indexed_reader::MAX_RETAINED_RECORDS,
        )
        .expect("the known Metadata fields fit while the legal suffix stays streamed");
        assert_eq!(scene.metadata.len(), 1);
        assert_eq!(scene.metadata[0].name, "capture");
        assert_eq!(scene.metadata[0].entries["author"], "Avala");
    }

    #[test]
    fn aggregate_decoded_budget_refuses_the_first_byte_past_the_ceiling() {
        assert_eq!(
            add_decoded_scene_bytes(MAX_DECODED_SCENE_BYTES - 1, 1)
                .expect("the ceiling itself is legal"),
            MAX_DECODED_SCENE_BYTES
        );
        let error = add_decoded_scene_bytes(MAX_DECODED_SCENE_BYTES, 1).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("aggregate decoded state"),
            "{error}"
        );
    }

    #[test]
    fn replaced_singleton_prefixes_do_not_accumulate_historical_bytes() {
        let prefix = 64 * 1024;
        let mut retained = 0usize;
        let mut previous = 0usize;
        for offset in 0..8_193u64 {
            retained = replace_streamed_retained_bytes(
                retained,
                previous,
                prefix,
                "retained Header prefix",
                offset,
                MAX_STREAM_BYTES as usize,
            )
            .expect("each Header replaces the previous singleton");
            previous = prefix;
        }
        assert_eq!(retained, prefix);
        assert_eq!(
            streamed_prefix_limit(retained, MAX_STREAM_BYTES as usize),
            crate::indexed_reader::MAX_FRONT_MATTER_BYTES
        );
    }

    fn append_record_suffix(record: &mut Vec<u8>, suffix: &[u8]) {
        let old_length = u64::from_le_bytes(record[1..RECORD_HEADER_SIZE].try_into().unwrap());
        record.extend_from_slice(suffix);
        record[1..RECORD_HEADER_SIZE]
            .copy_from_slice(&(old_length + suffix.len() as u64).to_le_bytes());
    }

    fn minimal_streamed_front(flags: u8) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(&MAGIC);
        data.extend_from_slice(
            &rec::Header {
                duration_sec: 1.0,
                gaussian_count: 0,
                cutoff: 0.05,
                temporal_model: "gaussian-birth".into(),
                aabb: vec![0.0; 6],
                flags,
                ..Default::default()
            }
            .encode(&[]),
        );
        data.extend_from_slice(
            &rec::Quantization {
                scheme: "uniform-v1".into(),
                pos_origin: vec![0.0; 3],
                step_pos: 1e-4,
                step_scale_log: 0.04,
                step_rot: 0.004,
                step_rgb: 2.0 / 255.0,
                step_alpha: 2.0 / 255.0,
                step_motion: 4e-4,
                step_time: 0.004,
                step_sigma_log: 0.04,
                step_sh: 1,
                ..Default::default()
            }
            .encode(&[]),
        );
        data.extend_from_slice(
            &rec::WindowTable {
                windows: vec![(0.0, 1.0)],
            }
            .encode(),
        );
        data
    }

    #[test]
    fn record_count_ceiling_waits_for_the_record_body_before_refusing() {
        const RECORD_LIMIT: usize = 3;
        let mut cut = minimal_streamed_front(0);
        cut.push(0x80);
        cut.extend_from_slice(&1u64.to_le_bytes());

        let scene = read_from_with_limits(
            IoCursor::new(cut.clone()),
            &ReadOptions::default(),
            MAX_STREAM_BYTES as usize,
            RECORD_LIMIT,
        )
        .expect("an incomplete fourth record leaves the first three usable");
        assert!(scene.truncated);

        cut.push(0x5a);
        let error = read_from_with_limits(
            IoCursor::new(cut),
            &ReadOptions::default(),
            MAX_STREAM_BYTES as usize,
            RECORD_LIMIT,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("record 4"), "{error}");
        assert!(error.to_string().contains("at byte "), "{error}");
    }

    #[test]
    fn replaced_and_absent_full_records_do_not_accumulate_historical_bytes() {
        const RETAINED_LIMIT: usize = 4 * 1024;
        let suffix = vec![0x5a; 700];
        let mut data = minimal_streamed_front(rec::FLAG_HAS_AUDIO);

        for _ in 0..3 {
            data.extend_from_slice(
                &rec::Audio {
                    codec: "opus".into(),
                    start_sec: 0.0,
                    data: suffix.clone(),
                }
                .encode(),
            );

            let mut camera = rec::Camera::default().encode();
            append_record_suffix(&mut camera, &suffix);
            data.extend_from_slice(&camera);

            let mut statistics = rec::Statistics {
                gaussian_count: 0,
                chunk_count: 0,
                duration_sec: 1.0,
                aabb: vec![0.0; 6],
            }
            .encode();
            append_record_suffix(&mut statistics, &suffix);
            data.extend_from_slice(&statistics);

            data.extend_from_slice(
                &rec::RigTrajectory {
                    name: "discarded".into(),
                    ..Default::default()
                }
                .encode(&suffix),
            );
            data.extend_from_slice(
                &rec::ObjectTrack {
                    object_id: 7,
                    ..Default::default()
                }
                .encode(&suffix)
                .unwrap(),
            );
        }

        data.extend_from_slice(&rec::Footer::default().encode());
        data.extend_from_slice(&MAGIC);

        let scene = read_from_with_limits(
            IoCursor::new(data),
            &ReadOptions::default(),
            RETAINED_LIMIT,
            crate::indexed_reader::MAX_RETAINED_RECORDS,
        )
        .expect("only the final singleton values remain resident");
        assert_eq!(scene.audio_sources.len(), 1);
        assert_eq!(scene.audio_sources[0].data.len(), suffix.len());
        assert!(scene.camera.is_some());
        assert!(scene.statistics.is_some());
        assert!(scene.provenance.trajectories.is_empty());
        assert!(scene.objects.tracks.is_empty());
    }

    #[test]
    fn streamed_sh_symbol_expansion_uses_the_remaining_scene_budget() {
        let values: Vec<i64> = (0..27).collect();
        let encoded = crate::stream::encode_stream(
            op::SH_BAND_STREAM,
            &values,
            9,
            crate::codec::DEFLATE,
            6,
            false,
        )
        .expect("three-row width-one SH stream");
        assert_eq!(encoded[1], 1);
        let mut cursor = Cursor::new(&encoded);
        let decoded_bytes = MAX_DECODED_SCENE_BYTES - 168;

        let error = decode_streamed_sh_values(&mut cursor, 3, 9, decoded_bytes).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("27 raw bytes"), "{error}");
        assert!(
            error.to_string().contains("216 resident decoded-symbol"),
            "{error}"
        );
        assert_eq!(
            cursor.position(),
            crate::serialization::STREAM_HEADER_SIZE,
            "the streamed SH budget is enforced before its payload is consumed"
        );
    }

    #[test]
    fn streamed_sh_channel_mismatch_precedes_resident_budgeting() {
        let mut encoded = crate::stream::encode_stream(
            op::SH_BAND_STREAM,
            &[0, 1],
            2,
            crate::codec::DEFLATE,
            6,
            false,
        )
        .expect("two-channel SH stream");
        encoded[5..9].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut cursor = Cursor::new(&encoded);

        let error = decode_streamed_sh_values(&mut cursor, u32::MAX as usize, 9, 0).unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("declares 2 channels"), "{error}");
        assert!(error.to_string().contains("format defines 9"), "{error}");
        assert_eq!(
            cursor.position(),
            crate::serialization::STREAM_HEADER_SIZE,
            "the streamed SH arity check runs before its payload is consumed"
        );
    }

    #[test]
    fn duplicate_streamed_sh_bands_are_rejected_above_the_requested_cutoff() {
        let mut data = minimal_streamed_front(0);
        data.extend_from_slice(&rec::encode_chunk(0.0, 1.0, 0, 0, &[]));
        for _ in 0..2 {
            crate::serialization::put_record(&mut data, op::SH_BAND_STREAM, &[3]);
        }
        data.extend_from_slice(&MAGIC);

        let error = read_from(
            IoCursor::new(data),
            &ReadOptions {
                max_sh_band: 0,
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(
            error.to_string().contains("band 3 appears more than once"),
            "{error}"
        );
    }
}
