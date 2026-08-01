// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Indexed reading: the Footer, then the index, then only what an instant needs.
//!
//! The seek rule is one line and it is the whole algorithm:
//!
//! ```text
//! chunks_for(t) == every index entry whose [t0, t1) contains t
//! ```
//!
//! Whether that is cheap depends on the content, not on this code. Gaussians with finite
//! lifetimes partition into many small chunks; content where everything lives for the
//! whole clip collapses to a single entry and an instant costs the scene. Both are correct
//! files.

use std::collections::{BTreeMap, HashMap, HashSet};

use crate::chunk::{decode_streams, DecodedChunk};
use crate::error::{Error, Result};
use crate::model::{AudioSource, AudioSourceKeyframe};
use crate::opcode as op;
use crate::readable::Readable;
use crate::records as rec;
use crate::serialization::{crc32, Cursor, Records, MAGIC, RECORD_HEADER_SIZE};
use crate::stream::decode_stream;

/// The first read from the front of a resource.
///
/// Deliberately small. The front matter a reader must parse is the Header, the Quantization
/// grids and the Window Table — a few hundred bytes on every scene measured so far — and
/// everything else there is stepped over by arithmetic rather than read. A larger probe
/// would not save a round trip, because this is one request either way; it would only
/// transfer bytes nobody asked for, and on a small file it would pull the whole thing in
/// while the caller was still deciding whether to seek. A record bigger than this is still
/// fetched whole, by `content`, so the probe bounds waste rather than capability.
pub const HEAD_PROBE: u64 = 8 * 1024;

/// How much of an Audio record is read to learn its codec. The codec name is the record's
/// first field, so a prefix answers it; the track stays where it is.
pub const AUDIO_CODEC_PREFIX: u64 = 4096;

const OBJECT_TRACK_HEADER_BYTES: u64 = 4 + 1 + 4;
const OBJECT_TRACK_SAMPLE_BYTES: u64 = 8 + 4 * 8 + 3 * 8;
const OBJECT_TRACK_VALIDATION_BLOCK_BYTES: u64 = 64 * 1024;

/// One record's framing: everything except its bytes.
#[derive(Debug, Clone, Copy)]
struct FrontRecord {
    opcode: u8,
    /// Offset of the record's opcode byte.
    offset: u64,
    content_length: u64,
}

/// The fixed-width portion of one Object Track, discovered without reading its samples.
///
/// The record range remains available for [`read_objects`], while indexed reconstruction
/// uses the content offset and sample count to range-read only the samples bracketing its
/// requested instant.
#[derive(Debug, Clone, Copy)]
pub struct ObjectTrackRange {
    pub object_id: u32,
    pub interpolation: u8,
    pub sample_count: u32,
    pub record_offset: u64,
    pub record_length: u64,
    pub content_offset: u64,
}

impl FrontRecord {
    /// Saturating, because `content_length` comes off the wire: a corrupt one must produce
    /// an error from the caller's bounds check rather than wrap around into a small number
    /// and send the walk backwards.
    fn total_length(&self) -> u64 {
        self.content_length
            .saturating_add(RECORD_HEADER_SIZE as u64)
    }
}

/// A sliding window over the front of a resource, walked by header.
///
/// An indexed reader wants four things from the front matter — the Header, the
/// Quantization grids, the Window Table, and the byte ranges of any audio sources — and
/// none requires reading a payload it does not care about. Encoded audio is a first-class
/// part of a scene and may be arbitrarily large, so materializing every record's content
/// defeats bounded indexed opening.
///
/// So a record is stepped over by arithmetic. Its length is in its header, and its bytes
/// are not needed to find the next one.
struct FrontMatter<'a, R: Readable + ?Sized> {
    source: &'a mut R,
    size: u64,
    probe: u64,
    window: Vec<u8>,
    window_at: u64,
}

impl<'a, R: Readable + ?Sized> FrontMatter<'a, R> {
    fn new(source: &'a mut R, size: u64) -> Self {
        FrontMatter {
            source,
            size,
            probe: HEAD_PROBE,
            window: Vec::new(),
            window_at: 0,
        }
    }

    /// The first `length` bytes of the resource, for the magic check.
    fn head(&mut self, length: u64) -> Result<Vec<u8>> {
        let want = length.min(self.size);
        self.ensure(0, want)?;
        Ok(self.window[..want as usize].to_vec())
    }

    /// The framing of the record at `at`, without its content.
    ///
    /// A front-matter record has to fit inside the resource, so a declared length that
    /// runs past the end — or overflows on the way there — is refused here rather than
    /// carried forward into arithmetic that would wrap.
    fn record_at(&mut self, at: u64) -> Result<FrontRecord> {
        self.ensure(at, RECORD_HEADER_SIZE as u64)?;
        let start = (at - self.window_at) as usize;
        let head = &self.window[start..start + RECORD_HEADER_SIZE];
        let content_length = u64::from_le_bytes([
            head[1], head[2], head[3], head[4], head[5], head[6], head[7], head[8],
        ]);
        let end = at
            .checked_add(RECORD_HEADER_SIZE as u64)
            .and_then(|v| v.checked_add(content_length));
        match end {
            Some(end) if end <= self.size => Ok(FrontRecord {
                opcode: head[0],
                offset: at,
                content_length,
            }),
            _ => Err(Error::Truncated(format!(
                "a {} record at offset {at} declares {content_length} bytes of content, past the end of a {}-byte resource",
                op::name(head[0]),
                self.size
            ))),
        }
    }

    /// One record's content, from the window when it is there and by a read of exactly
    /// that record when it is not.
    ///
    /// A Window Table larger than the probe is therefore fetched rather than refused, and
    /// audio payloads nobody asked for are never fetched at all.
    fn content(&mut self, record: &FrontRecord, limit: Option<u64>) -> Result<Vec<u8>> {
        let at = record.offset + RECORD_HEADER_SIZE as u64;
        if at > self.size {
            return Err(Error::Truncated(format!(
                "a {} record claims to start at {at}, past the end of the resource",
                op::name(record.opcode)
            )));
        }
        let mut length = record.content_length.min(self.size - at);
        if let Some(cap) = limit {
            length = length.min(cap);
        }
        if !self.covers(at, length) && length > self.probe {
            return self.source.read(at, length);
        }
        self.ensure(at, length)?;
        let start = (at - self.window_at) as usize;
        Ok(self.window[start..start + length as usize].to_vec())
    }

    fn covers(&self, at: u64, length: u64) -> bool {
        at >= self.window_at
            && at.saturating_add(length) <= self.window_at + self.window.len() as u64
    }

    fn ensure(&mut self, at: u64, length: u64) -> Result<()> {
        if self.covers(at, length) {
            return Ok(());
        }
        if at.saturating_add(length) > self.size {
            return Err(Error::Truncated(format!(
                "the front matter needs bytes [{at}, {}) of a {}-byte resource",
                at.saturating_add(length),
                self.size
            )));
        }
        let want = self.probe.max(length).min(self.size - at);
        self.window = self.source.read(at, want)?;
        self.window_at = at;
        Ok(())
    }
}

/// A scene opened for seeking: everything an instant needs to be located, and nothing an
/// instant does not need to be transferred.
#[derive(Debug, Clone, Default)]
pub struct IndexedScene {
    pub header: rec::Header,
    pub quantization: rec::Quantization,
    pub windows: Vec<(f64, f64)>,
    pub index: Vec<rec::ChunkIndexEntry>,
    pub audio_sources: Vec<IndexedAudioSource>,
    pub summary_crc_ok: Option<bool>,
    /// `(offset, length)` of the front-matter records this reader did not parse. Opening a
    /// file frames them and stops: a camera nobody asked for costs nothing, and neither
    /// does an attachment the size of a thumbnail sheet.
    pub camera_range: Option<(u64, u64)>,
    pub metadata_ranges: Vec<(u64, u64)>,
    pub attachment_ranges: Vec<(u64, u64)>,
    /// `(opcode, offset, length)` of every provenance record framed during the walk.
    /// Framed, not read: a Rig Trajectory is unbounded — a ten-minute capture logged at
    /// 100 Hz is sixty thousand samples — and a consumer that wants the gaussians should
    /// not pay for it. This is also the whole discovery mechanism for the family, which is
    /// why no Header flag announces it: the walk was already happening.
    pub provenance_ranges: Vec<(u8, u64, u64)>,
    /// Object Tables stay fully lazy because reconstructed state never needs labels,
    /// embeddings, anchors, or dynamics.
    pub object_table_ranges: Vec<(u64, u64)>,
    /// The framing and fixed-width header of each Object Track, keyed by object id.
    /// Opening reads no samples; the lookup lets an indexed instant visit only the tracks
    /// its resident memberships reference.
    pub object_track_ranges: BTreeMap<u32, ObjectTrackRange>,
    pub statistics: Option<rec::Statistics>,
    pub summary_offsets: Vec<rec::SummaryOffset>,
}

#[derive(Debug, Clone, Default)]
pub struct IndexedAudioSource {
    pub source_id: u32,
    /// Whole Audio Source record, absent for a legacy Audio record.
    pub descriptor_range: Option<(u64, u64)>,
    /// Raw encoded bytes only, excluding Audio Data framing and its id/length prefix.
    pub data_offset: u64,
    pub data_length: u64,
    pub legacy_codec: Option<String>,
    pub legacy_start_sec: f64,
}

impl IndexedScene {
    pub fn has_audio(&self) -> bool {
        self.header.has_audio()
    }

    /// The normative seek rule.
    pub fn chunks_for_time(&self, t: f64) -> Vec<&rec::ChunkIndexEntry> {
        self.index.iter().filter(|e| e.covers(t)).collect()
    }

    pub fn chunks_for_range(&self, a: f64, b: f64) -> Vec<&rec::ChunkIndexEntry> {
        self.index.iter().filter(|e| e.t0 < b && a < e.t1).collect()
    }

    /// A conservative upper bound on what a cold seek to `t` will transfer.
    ///
    /// Object membership lives inside the chunks, so it is unknowable before those bytes
    /// arrive. The bound therefore includes first-use validation and pose sampling for
    /// every framed Object Track. Actual transfer is lower when the instant references
    /// fewer tracks, and later seeks reuse the bounded validation cache in
    /// [`crate::SceneReader`].
    pub fn bytes_for_time(&self, t: f64, max_sh_band: u8) -> u64 {
        let chunks = self
            .chunks_for_time(t)
            .iter()
            .map(|e| {
                e.bands
                    .iter()
                    .filter(|(band, _, _)| *band <= max_sh_band)
                    .fold(e.chunk_length, |total, (_, _, length)| {
                        total.saturating_add(*length)
                    })
            })
            .fold(0u64, u64::saturating_add);
        self.object_track_ranges
            .values()
            .map(object_track_cold_seek_bytes)
            .fold(chunks, u64::saturating_add)
    }
}

fn object_track_cold_seek_bytes(range: &ObjectTrackRange) -> u64 {
    let count = u64::from(range.sample_count);
    if count == 0 {
        return 0;
    }
    let validation = count.saturating_mul(OBJECT_TRACK_SAMPLE_BYTES);
    if count == 1 {
        return validation
            .saturating_add(8)
            .saturating_add(OBJECT_TRACK_SAMPLE_BYTES);
    }
    // This deliberately rounds the bisection probes up: the API promises a budget
    // ceiling, not an average for a particular query time.
    let bisection_upper = u64::from(range.sample_count.ilog2()) + 1;
    validation
        .saturating_add((2 + bisection_upper).saturating_mul(8))
        .saturating_add(2 * OBJECT_TRACK_SAMPLE_BYTES)
}

/// Open a scene: a bounded read from the front, then the index. Never the file.
pub fn open_indexed<R: Readable + ?Sized>(source: &mut R) -> Result<IndexedScene> {
    let size = source.size()?;
    let mut scene = IndexedScene::default();

    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut source_ranges: BTreeMap<u32, (u64, u64)> = BTreeMap::new();
    let mut data_ranges: BTreeMap<u32, (u64, u64)> = BTreeMap::new();
    let mut legacy_audio: Option<IndexedAudioSource> = None;
    {
        let mut front = FrontMatter::new(source, size);
        crate::serialization::check_magic(&front.head(MAGIC.len() as u64)?)?;

        let mut at = MAGIC.len() as u64;
        while at + RECORD_HEADER_SIZE as u64 <= size {
            let record = front.record_at(at)?;
            if record.opcode == op::CHUNK {
                break;
            }
            match record.opcode {
                op::HEADER => {
                    let parsed = rec::Header::parse(&front.content(&record, None)?)?;
                    crate::registry::check_temporal_model(&parsed.temporal_model)?;
                    header = Some(parsed)
                }
                op::QUANTIZATION => {
                    let parsed = rec::Quantization::parse(&front.content(&record, None)?)?;
                    crate::registry::check_quantization_scheme(&parsed.scheme)?;
                    quant = Some(parsed)
                }
                op::WINDOW_TABLE => {
                    scene.windows = rec::WindowTable::parse(&front.content(&record, None)?)?.windows
                }
                op::AUDIO => {
                    // The track's bytes are not read here, and the record is not stepped
                    // into: a caller may want the gaussians and never the audio. Only the
                    // codec name is parsed, out of a prefix, so a scene with a large track
                    // costs nothing to open.
                    let prefix = front.content(&record, Some(AUDIO_CODEC_PREFIX))?;
                    legacy_audio = Some(legacy_audio_range(
                        &prefix,
                        record.offset,
                        record.content_length,
                    )?);
                }
                op::AUDIO_SOURCE => {
                    let prefix = front.content(&record, Some(4))?;
                    let source_id = source_id(&prefix, "Audio Source")?;
                    if source_ranges
                        .insert(source_id, (record.offset, record.total_length()))
                        .is_some()
                    {
                        return Err(Error::Malformed(format!(
                            "Audio Source id {source_id} appears more than once"
                        )));
                    }
                }
                op::AUDIO_DATA => {
                    let prefix = front.content(&record, Some(12))?;
                    let mut cursor = Cursor::new(&prefix);
                    let source_id = cursor.u32()?;
                    let data_length = cursor.u64()?;
                    if record.content_length < 12u64.saturating_add(data_length) {
                        return Err(Error::Malformed(format!(
                            "Audio Data id {source_id} declares {data_length} bytes, but its record content is only {} bytes",
                            record.content_length
                        )));
                    }
                    if data_ranges
                        .insert(
                            source_id,
                            (record.offset + RECORD_HEADER_SIZE as u64 + 12, data_length),
                        )
                        .is_some()
                    {
                        return Err(Error::Malformed(format!(
                            "Audio Data id {source_id} appears more than once"
                        )));
                    }
                }
                op::CAMERA => scene.camera_range = Some((record.offset, record.total_length())),
                op::METADATA => scene
                    .metadata_ranges
                    .push((record.offset, record.total_length())),
                op::ATTACHMENT => scene
                    .attachment_ranges
                    .push((record.offset, record.total_length())),
                op::OBJECT_TABLE => scene
                    .object_table_ranges
                    .push((record.offset, record.total_length())),
                op::OBJECT_TRACK => {
                    let prefix = front.content(&record, Some(OBJECT_TRACK_HEADER_BYTES))?;
                    if prefix.len() < OBJECT_TRACK_HEADER_BYTES as usize {
                        return Err(Error::Truncated(format!(
                            "ObjectTrack at byte {} has {} content bytes; its object id, \
                             interpolation, and sample count need {OBJECT_TRACK_HEADER_BYTES}",
                            record.offset,
                            prefix.len()
                        )));
                    }
                    let mut header = Cursor::new(&prefix);
                    let object_id = header.u32()?;
                    if object_id == crate::object_layer::BACKGROUND {
                        return Err(Error::Malformed(format!(
                            "ObjectTrack at byte {} names object 0, which is background/unassigned",
                            record.offset
                        )));
                    }
                    let interpolation = header.u8()?;
                    let sample_count = header.u32()?;
                    if let Some(first) = scene.object_track_ranges.get(&object_id) {
                        return Err(Error::Malformed(format!(
                            "ObjectTrack for object {object_id} at byte {} duplicates the track at \
                             byte {first_offset}; expected at most one track per object (section \
                             5.15.6)",
                            record.offset,
                            first_offset = first.record_offset
                        )));
                    }
                    let sample_bytes = u64::from(sample_count)
                        .checked_mul(OBJECT_TRACK_SAMPLE_BYTES)
                        .and_then(|bytes| bytes.checked_add(OBJECT_TRACK_HEADER_BYTES))
                        .ok_or_else(|| {
                            Error::Malformed(format!(
                                "ObjectTrack for object {object_id} at byte {} declares \
                                 {sample_count} samples whose byte length overflows",
                                record.offset
                            ))
                        })?;
                    if sample_bytes > record.content_length {
                        return Err(Error::Truncated(format!(
                            "ObjectTrack for object {object_id} at byte {} declares \
                             {sample_count} samples needing {sample_bytes} content bytes, but \
                             its content length is {}",
                            record.offset, record.content_length
                        )));
                    }
                    scene.object_track_ranges.insert(
                        object_id,
                        ObjectTrackRange {
                            object_id,
                            interpolation,
                            sample_count,
                            record_offset: record.offset,
                            record_length: record.total_length(),
                            content_offset: record.offset + RECORD_HEADER_SIZE as u64,
                        },
                    );
                }
                code if op::is_provenance(code) => {
                    scene
                        .provenance_ranges
                        .push((code, record.offset, record.total_length()))
                }
                _ => {}
            }
            at += record.total_length();
        }
    }

    scene.header = header.ok_or_else(|| {
        Error::Malformed(
            "the file has no Header or no Quantization record before its first Chunk".into(),
        )
    })?;
    scene.quantization = quant.ok_or_else(|| {
        Error::Malformed(
            "the file has no Header or no Quantization record before its first Chunk".into(),
        )
    })?;
    if legacy_audio.is_some() && !source_ranges.is_empty() {
        return Err(Error::Malformed(
            "the file mixes a legacy Audio record with Audio Source records".into(),
        ));
    }
    // A legacy Audio record stands alone: an Audio Data record beside it has no descriptor
    // to match, exactly the orphan the streamed reader rejects. The legacy branch below
    // otherwise never inspects `data_ranges`, so this is where it is caught.
    if legacy_audio.is_some() && !data_ranges.is_empty() {
        let source_id = *data_ranges.keys().next().expect("not empty");
        return Err(Error::Malformed(format!(
            "Audio Data id {source_id} has no matching Audio Source record"
        )));
    }
    if let Some(legacy) = legacy_audio {
        scene.audio_sources.push(legacy);
    } else {
        for (source_id, descriptor_range) in source_ranges {
            let Some((data_offset, data_length)) = data_ranges.remove(&source_id) else {
                return Err(Error::Malformed(format!(
                    "Audio Source id {source_id} has no matching Audio Data record"
                )));
            };
            scene.audio_sources.push(IndexedAudioSource {
                source_id,
                descriptor_range: Some(descriptor_range),
                data_offset,
                data_length,
                legacy_codec: None,
                legacy_start_sec: 0.0,
            });
        }
        if let Some(source_id) = data_ranges.keys().next() {
            return Err(Error::Malformed(format!(
                "Audio Data id {source_id} has no matching Audio Source record"
            )));
        }
    }
    if scene.header.has_audio() == scene.audio_sources.is_empty() {
        return Err(Error::Malformed(format!(
            "the Header audio flag is {}, but the file contains {} audio sources",
            if scene.header.has_audio() {
                "set"
            } else {
                "clear"
            },
            scene.audio_sources.len()
        )));
    }

    // The three-read open: the tail carries the magic and the Footer, and the Footer says
    // where the index is.
    let footer_size = (RECORD_HEADER_SIZE + 20 + MAGIC.len()) as u64;
    let tail = source.read(size.saturating_sub(footer_size), footer_size.min(size))?;
    if tail.len() < MAGIC.len() || tail[tail.len() - MAGIC.len()..] != MAGIC {
        return Err(Error::Malformed(
            "file does not end with the magic; it may be truncated".into(),
        ));
    }
    let footer =
        rec::Footer::parse(crate::serialization::read_record(&mut Cursor::new(&tail))?.content)?;

    if footer.summary_start != 0 {
        let summary_end = size - footer_size;
        if footer.summary_start > summary_end {
            return Err(Error::Malformed(format!(
                "the footer says the summary starts at {}, past the footer itself at {summary_end}",
                footer.summary_start
            )));
        }
        let summary = source.read(footer.summary_start, summary_end - footer.summary_start)?;
        if footer.summary_crc != 0 {
            scene.summary_crc_ok = Some(crc32(&summary) == footer.summary_crc);
        }
        for record in Records::new(&summary, 0) {
            let record = record?;
            match record.opcode {
                op::CHUNK_INDEX => scene
                    .index
                    .push(rec::ChunkIndexEntry::parse(record.content)?),
                op::STATISTICS => scene.statistics = Some(rec::Statistics::parse(record.content)?),
                op::SUMMARY_OFFSET => scene
                    .summary_offsets
                    .push(rec::SummaryOffset::parse(record.content)?),
                _ => {}
            }
        }
    }

    Ok(scene)
}

/// Fetch and decode one chunk, plus only the SH bands asked for.
///
/// Never transferring a band you will not evaluate is the whole point of storing each one
/// in its own record with its own byte range.
pub fn read_chunk<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    entry: &rec::ChunkIndexEntry,
    max_sh_band: u8,
) -> Result<DecodedChunk> {
    let blob = source.read(entry.chunk_offset, entry.chunk_length)?;
    let content = record_content(&blob, op::CHUNK)?;
    let (head, streams) = rec::parse_chunk(content)?;
    let unpacked = crate::chunk::chunk_stream_bytes(&head, streams)?;
    let mut decoded = decode_streams(
        &unpacked,
        head.count as usize,
        &scene.quantization.steps(),
        &scene.quantization.pos_origin,
        &scene.windows,
        scene.header.cutoff,
    )?;

    let mut bands = BTreeMap::new();
    for (band, offset, length) in &entry.bands {
        if *band > max_sh_band {
            continue;
        }
        let blob = source.read(*offset, *length)?;
        let content = record_content(&blob, op::SH_BAND_STREAM)?;
        let mut cursor = Cursor::new(content);
        cursor.u8()?; // the band index, already known from the index
        let (_, values) = decode_stream(&mut cursor, Some(head.count as usize))?;
        bands.insert(*band, values);
    }
    decoded.bands = bands;
    Ok(decoded)
}

/// The suggested camera trajectory, fetched only when a caller wants it.
pub fn read_camera<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Option<rec::Camera>> {
    match scene.camera_range {
        None => Ok(None),
        Some((offset, length)) => {
            let blob = source.read(offset, length)?;
            Ok(Some(rec::Camera::parse(record_content(
                &blob,
                op::CAMERA,
            )?)?))
        }
    }
}

/// Every Metadata record, by range.
pub fn read_metadata<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Vec<rec::Metadata>> {
    let mut out = Vec::with_capacity(scene.metadata_ranges.len());
    for (offset, length) in &scene.metadata_ranges {
        let blob = source.read(*offset, *length)?;
        out.push(rec::Metadata::parse(record_content(&blob, op::METADATA)?)?);
    }
    Ok(out)
}

/// Every Attachment record, by range. Each one costs exactly its own bytes.
pub fn read_attachments<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Vec<rec::Attachment>> {
    let mut out = Vec::with_capacity(scene.attachment_ranges.len());
    for (offset, length) in &scene.attachment_ranges {
        let blob = source.read(*offset, *length)?;
        out.push(rec::Attachment::parse(record_content(
            &blob,
            op::ATTACHMENT,
        )?)?);
    }
    Ok(out)
}

/// Every provenance record, by range, fetched only when a caller wants them.
///
/// Opening a file frames these and stops, so a scene with a long rig trajectory costs the
/// same to open as one with none. This is where a caller says it wants them.
///
/// The object-layer records (`0x24`, `0x25`) are in the same opcode family and framed by
/// the same walk, but they belong to the object layer rather than provenance, so they are
/// skipped here and read by [`read_objects`]. A still-reserved opcode (`0x26`-`0x2F`, which
/// no version-1 writer emits) is framed and skipped by both — the forward-compatibility
/// rule doing its job inside a family, and why the ranges carry their opcode.
/// The most bytes one front-matter record may occupy before this reader refuses it.
///
/// Not a format limit; a bound on what a single declared length can cost. Staying inside
/// the file is not enough on its own — a record declaring hundreds of megabytes sits
/// happily inside a large file, and these paths allocate the whole range before a parser
/// can ignore an appended tail or refuse an oversized count. The Dart and TypeScript
/// readers cap the same reads at the same number.
pub const MAX_FRONT_MATTER_BYTES: u64 = 64 * 1024 * 1024;

fn check_front_matter_length(length: u64, what: &str) -> Result<()> {
    if length > MAX_FRONT_MATTER_BYTES {
        return Err(Error::Malformed(format!(
            "a {what} record is {length} bytes, past the {MAX_FRONT_MATTER_BYTES} byte \
             ceiling for a single front-matter record"
        )));
    }
    Ok(())
}

pub fn read_provenance<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<crate::provenance::Provenance> {
    let mut out = crate::provenance::Provenance::default();
    for (opcode, offset, length) in &scene.provenance_ranges {
        if !matches!(
            *opcode,
            op::COORDINATE_FRAME
                | op::SENSOR_CALIBRATION
                | op::RIG_TRAJECTORY
                | op::GEODETIC_ANCHOR
        ) {
            continue;
        }
        check_front_matter_length(*length, "provenance")?;
        let blob = source.read(*offset, *length)?;
        let content = record_content(&blob, *opcode)?;
        match *opcode {
            op::COORDINATE_FRAME => out.frames.push(rec::CoordinateFrame::parse(content)?),
            op::SENSOR_CALIBRATION => out.sensors.push(rec::SensorCalibration::parse(content)?),
            op::RIG_TRAJECTORY => {
                // Section 5.15.4: a trajectory with no samples is read as though absent.
                let trajectory = rec::RigTrajectory::parse(content)?;
                if trajectory.sample_count() > 0 {
                    out.trajectories.push(trajectory);
                }
            }
            op::GEODETIC_ANCHOR => out.anchors.push(rec::GeodeticAnchor::parse(content)?),
            _ => {}
        }
    }
    out.check()?;
    Ok(out)
}

/// The object layer — the Object Table and the SE(3) tracks — fetched by range.
///
/// Framed by the same front-matter walk as provenance (both families share the opcode
/// range) and read only when a caller asks. A file that names no objects returns an empty
/// layer, which is a value and not an error.
pub fn read_objects<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<crate::object_layer::ObjectLayer> {
    let mut out = crate::object_layer::ObjectLayer::default();
    for (offset, length) in &scene.object_table_ranges {
        if out.table.is_some() {
            return Err(Error::Malformed(format!(
                "a second ObjectTable record appears at byte {offset}; a file may carry \
                 exactly one scene-wide object table"
            )));
        }
        check_front_matter_length(*length, "object layer")?;
        let blob = source.read(*offset, *length)?;
        out.table = Some(rec::ObjectTable::parse(record_content(
            &blob,
            op::OBJECT_TABLE,
        )?)?);
    }
    for range in scene.object_track_ranges.values() {
        let blob = source.read(range.record_offset, range.record_length)?;
        // Section 5.15.7: a zero-sample track "has no pose and is read as absent".
        let track = rec::ObjectTrack::parse(record_content(&blob, op::OBJECT_TRACK)?)?;
        if track.sample_count() > 0 {
            out.tracks.push(track);
        }
    }
    out.check()?;
    Ok(out)
}

/// Sample only Object Tracks referenced by the resident gaussian memberships.
///
/// Object Tables, unrelated tracks, and unrelated samples remain lazy behind
/// [`read_objects`]. A referenced track's complete time order is validated in bounded
/// contiguous blocks, then sampling costs logarithmic eight-byte probes and at most two
/// fixed-width pose samples.
pub fn read_object_poses<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    object_ids: &HashSet<u32>,
    t: f64,
) -> Result<HashMap<u32, crate::provenance::Pose>> {
    let mut validated = HashSet::new();
    read_object_poses_cached(source, scene, object_ids, t, &mut validated)
}

/// [`read_object_poses`] with the per-reader validation cache used by [`crate::SceneReader`].
///
/// The cache stores one record offset per validated track, never samples or payload bytes.
/// It is therefore bounded by the already-framed Object Track ranges while avoiding a
/// second full-order scan when a caller seeks to another instant.
pub(crate) fn read_object_poses_cached<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    object_ids: &HashSet<u32>,
    t: f64,
    validated: &mut HashSet<u64>,
) -> Result<HashMap<u32, crate::provenance::Pose>> {
    let mut out = HashMap::with_capacity(object_ids.len().min(scene.object_track_ranges.len()));
    for object_id in object_ids {
        let Some(range) = scene.object_track_ranges.get(object_id) else {
            continue;
        };
        let needs_validation = !validated.contains(&range.record_offset);
        let Some(pose) = sample_object_track(source, range, t, needs_validation)? else {
            validated.insert(range.record_offset);
            continue;
        };
        validated.insert(range.record_offset);
        out.insert(range.object_id, pose);
    }
    Ok(out)
}

#[derive(Clone, Copy)]
struct IndexedObjectSample {
    time: f64,
    pose: crate::provenance::Pose,
}

fn sample_object_track<R: Readable + ?Sized>(
    source: &mut R,
    range: &ObjectTrackRange,
    t: f64,
    validate_times: bool,
) -> Result<Option<crate::provenance::Pose>> {
    crate::provenance::check_scene_time(t)?;
    if range.object_id == crate::object_layer::BACKGROUND {
        return Err(Error::Malformed(format!(
            "ObjectTrack at byte {} names object 0, which is background/unassigned",
            range.record_offset
        )));
    }
    if !matches!(
        range.interpolation,
        rec::TRAJECTORY_LINEAR | rec::TRAJECTORY_STEP
    ) {
        return Err(Error::Malformed(format!(
            "track for object {} at byte {} uses interpolation {}; this reader supports \
             trajectory interpolation registry values 0 (linear) and 1 (step)",
            range.object_id, range.record_offset, range.interpolation
        )));
    }
    let count = range.sample_count as usize;
    if count == 0 {
        return Ok(None);
    }
    if validate_times {
        validate_object_track_times(source, range)?;
    }

    let first_time = read_object_time(source, range, 0)?;
    if count == 1 || t <= first_time {
        return Ok(Some(read_object_sample(source, range, 0)?.pose));
    }
    let last_time = read_object_time(source, range, count - 1)?;
    if t >= last_time {
        return Ok(Some(read_object_sample(source, range, count - 1)?.pose));
    }

    let (mut lo, mut hi) = (0usize, count - 1);
    let (mut lo_time, mut hi_time) = (first_time, last_time);
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        let mid_time = read_object_time(source, range, mid)?;
        if mid_time <= t {
            lo = mid;
            lo_time = mid_time;
        } else {
            hi = mid;
            hi_time = mid_time;
        }
    }

    let a = read_object_sample(source, range, lo)?;
    if range.interpolation == rec::TRAJECTORY_STEP {
        return Ok(Some(a.pose));
    }
    let b = read_object_sample(source, range, hi)?;
    if a.time != lo_time || b.time != hi_time {
        return Err(Error::Malformed(format!(
            "track for object {} changed while its samples were being range-read",
            range.object_id
        )));
    }
    let u = crate::provenance::interpolation_fraction(t, a.time, b.time);
    let mut translation = [0.0; 3];
    for (axis, value) in translation.iter_mut().enumerate() {
        *value =
            crate::provenance::finite_lerp(a.pose.translation[axis], b.pose.translation[axis], u);
    }
    Ok(Some(crate::provenance::Pose {
        rotation: crate::provenance::slerp(a.pose.rotation, b.pose.rotation, u)?,
        translation,
    }))
}

fn validate_object_track_times<R: Readable + ?Sized>(
    source: &mut R,
    range: &ObjectTrackRange,
) -> Result<()> {
    let count = range.sample_count as usize;
    if count == 0 {
        return Ok(());
    }
    let samples_per_block =
        (OBJECT_TRACK_VALIDATION_BLOCK_BYTES / OBJECT_TRACK_SAMPLE_BYTES) as usize;
    let mut previous = None;
    for first in (0..count).step_by(samples_per_block) {
        let block_samples = samples_per_block.min(count - first);
        let offset = object_sample_offset(range, first)?;
        let length = u64::try_from(block_samples)
            .ok()
            .and_then(|samples| samples.checked_mul(OBJECT_TRACK_SAMPLE_BYTES))
            .ok_or_else(|| {
                Error::Malformed(format!(
                    "validation block length overflows for ObjectTrack {} at sample {first}",
                    range.object_id
                ))
            })?;
        let bytes = source.read(offset, length)?;
        for local in 0..block_samples {
            let sample = first + local;
            let at = local * OBJECT_TRACK_SAMPLE_BYTES as usize;
            let time = Cursor::new(&bytes[at..]).f64()?;
            let time = check_object_time(range, sample, time)?;
            if let Some(previous_time) = previous {
                if time <= previous_time {
                    return Err(Error::Malformed(format!(
                        "track for object {}: sample {sample} is at t={time}, not after sample {} \
                         at t={previous_time}; times must strictly increase (section 5.15.4)",
                        range.object_id,
                        sample - 1
                    )));
                }
            }
            previous = Some(time);
        }
    }
    Ok(())
}

fn read_object_time<R: Readable + ?Sized>(
    source: &mut R,
    range: &ObjectTrackRange,
    sample: usize,
) -> Result<f64> {
    let offset = object_sample_offset(range, sample)?;
    let bytes = source.read(offset, 8)?;
    let time = Cursor::new(&bytes).f64()?;
    check_object_time(range, sample, time)
}

fn check_object_time(range: &ObjectTrackRange, sample: usize, time: f64) -> Result<f64> {
    if !time.is_finite() {
        return Err(Error::Malformed(format!(
            "track for object {}: sample {sample} has a non-finite time ({time})",
            range.object_id
        )));
    }
    Ok(time)
}

fn read_object_sample<R: Readable + ?Sized>(
    source: &mut R,
    range: &ObjectTrackRange,
    sample: usize,
) -> Result<IndexedObjectSample> {
    let offset = object_sample_offset(range, sample)?;
    let bytes = source.read(offset, OBJECT_TRACK_SAMPLE_BYTES)?;
    let mut cursor = Cursor::new(&bytes);
    let time = cursor.f64()?;
    if !time.is_finite() {
        return Err(Error::Malformed(format!(
            "track for object {}: sample {sample} has a non-finite time ({time})",
            range.object_id
        )));
    }
    let rotation_values = cursor.f64s(4)?;
    let mut rotation = [
        rotation_values[0],
        rotation_values[1],
        rotation_values[2],
        rotation_values[3],
    ];
    let norm = rotation
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt();
    if !norm.is_finite() || norm == 0.0 {
        return Err(Error::Malformed(format!(
            "track for object {}: sample {sample} rotation has no direction (norm {norm})",
            range.object_id
        )));
    }
    for value in &mut rotation {
        *value /= norm;
    }
    let translation_values = cursor.f64s(3)?;
    let translation = [
        translation_values[0],
        translation_values[1],
        translation_values[2],
    ];
    for (axis, value) in translation.iter().enumerate() {
        if !value.is_finite() {
            return Err(Error::Malformed(format!(
                "track for object {}: sample {sample} translation[{axis}] is {value}",
                range.object_id
            )));
        }
    }
    Ok(IndexedObjectSample {
        time,
        pose: crate::provenance::Pose {
            rotation,
            translation,
        },
    })
}

fn object_sample_offset(range: &ObjectTrackRange, sample: usize) -> Result<u64> {
    if sample >= range.sample_count as usize {
        return Err(Error::Malformed(format!(
            "sample {sample} is outside ObjectTrack {}'s {} samples",
            range.object_id, range.sample_count
        )));
    }
    let sample = u64::try_from(sample).map_err(|_| {
        Error::Malformed(format!(
            "sample {sample} of ObjectTrack {} is past this platform's range",
            range.object_id
        ))
    })?;
    range
        .content_offset
        .checked_add(OBJECT_TRACK_HEADER_BYTES)
        .and_then(|offset| {
            sample
                .checked_mul(OBJECT_TRACK_SAMPLE_BYTES)
                .and_then(|bytes| offset.checked_add(bytes))
        })
        .ok_or_else(|| {
            Error::Malformed(format!(
                "sample {sample} offset overflows for ObjectTrack {}",
                range.object_id
            ))
        })
}

/// The embedded track, fetched independently of any gaussian data.
///
/// `None` when the scene has none — a normal value, not an error.
pub fn read_audio<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Option<Vec<u8>>> {
    match scene.audio_sources.first() {
        None => Ok(None),
        Some(entry) => {
            read_audio_source_descriptor(source, scene, entry)?;
            Ok(Some(source.read(entry.data_offset, entry.data_length)?))
        }
    }
}

pub fn read_audio_sources<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Vec<AudioSource>> {
    let mut out = Vec::with_capacity(scene.audio_sources.len());
    for entry in &scene.audio_sources {
        let mut descriptor = read_audio_source_descriptor(source, scene, entry)?;
        descriptor.data = source.read(entry.data_offset, entry.data_length)?;
        out.push(descriptor);
    }
    Ok(out)
}

/// Validate the small descriptor, then read one source-relative payload range.
pub fn read_audio_range<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    source_id: u32,
    offset: u64,
    length: u64,
) -> Result<Vec<u8>> {
    let entry = scene
        .audio_sources
        .iter()
        .find(|entry| entry.source_id == source_id)
        .ok_or_else(|| {
            Error::Malformed(format!("this scene has no audio source id {source_id}"))
        })?;
    read_audio_source_descriptor(source, scene, entry)?;
    let end = offset.checked_add(length).ok_or_else(|| {
        Error::Malformed(format!(
            "audio source {source_id} range [{offset}, +{length}) overflows"
        ))
    })?;
    if end > entry.data_length {
        return Err(Error::Malformed(format!(
            "audio source {source_id} range [{offset}, {end}) is outside its {}-byte payload",
            entry.data_length
        )));
    }
    source.read(entry.data_offset + offset, length)
}

pub fn read_audio_source_descriptor<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    entry: &IndexedAudioSource,
) -> Result<AudioSource> {
    let Some((offset, length)) = entry.descriptor_range else {
        let start_sec = entry.legacy_start_sec;
        return Ok(AudioSource {
            source_id: entry.source_id,
            codec: entry.legacy_codec.clone().unwrap_or_default(),
            channel_layout: String::new(),
            start_sec,
            duration_sec: (scene.header.duration_sec - start_sec).max(0.0),
            spatial: false,
            ..AudioSource::default()
        });
    };
    let blob = source.read(offset, length)?;
    let descriptor = rec::AudioSource::parse(record_content(&blob, op::AUDIO_SOURCE)?)?;
    if descriptor.source_id != entry.source_id {
        return Err(Error::Malformed(format!(
            "Audio Source range for id {} contains id {}",
            entry.source_id, descriptor.source_id
        )));
    }
    if descriptor.data_length != entry.data_length {
        return Err(Error::Malformed(format!(
            "Audio Source id {} declares {} bytes, its Audio Data record declares {}",
            entry.source_id, descriptor.data_length, entry.data_length
        )));
    }
    for (index, keyframe) in descriptor.keyframes.iter().enumerate() {
        if keyframe.time < 0.0 || keyframe.time > scene.header.duration_sec {
            return Err(Error::Malformed(format!(
                "Audio Source id {} keyframe {index} time {} is outside [0, {}]",
                entry.source_id, keyframe.time, scene.header.duration_sec
            )));
        }
    }
    let spatial = descriptor.spatial();
    let loop_ = descriptor.loop_();
    Ok(AudioSource {
        source_id: descriptor.source_id,
        name: descriptor.name,
        codec: descriptor.codec,
        channel_layout: descriptor.channel_layout,
        start_sec: descriptor.start_sec,
        duration_sec: descriptor.duration_sec,
        gain: descriptor.gain,
        spatial,
        loop_,
        position: descriptor.position,
        rotation: descriptor.rotation,
        keyframes: descriptor
            .keyframes
            .into_iter()
            .map(|frame| AudioSourceKeyframe {
                time: frame.time,
                position: frame.position,
                rotation: frame.rotation,
            })
            .collect(),
        interpolation: descriptor.interpolation,
        data: Vec::new(),
    })
}

fn source_id(prefix: &[u8], record_name: &str) -> Result<u32> {
    Cursor::new(prefix).u32().map_err(|_| {
        Error::Malformed(format!(
            "the {record_name} record does not contain its u32 source id"
        ))
    })
}

fn legacy_audio_range(
    prefix: &[u8],
    record_offset: u64,
    content_length: u64,
) -> Result<IndexedAudioSource> {
    let mut cursor = Cursor::new(prefix);
    let codec = cursor.string().map_err(|_| {
        Error::Malformed(format!(
            "the legacy Audio descriptor does not fit the first {AUDIO_CODEC_PREFIX} bytes"
        ))
    })?;
    let start_sec = cursor.f64()?;
    let data_length = cursor.u64()?;
    if content_length < cursor.position() as u64 + data_length {
        return Err(Error::Malformed(format!(
            "the legacy Audio record declares {data_length} data bytes, but its content is only {content_length} bytes"
        )));
    }
    Ok(IndexedAudioSource {
        source_id: 0,
        descriptor_range: None,
        data_offset: record_offset + RECORD_HEADER_SIZE as u64 + cursor.position() as u64,
        data_length,
        legacy_codec: Some(codec),
        legacy_start_sec: start_sec,
    })
}

/// Strip a record's framing from a range that the index said holds exactly that record.
///
/// Every offset and length in the Chunk Index frames a whole record, opcode byte and
/// content length included (spec §5.8), so a range that does not start with the opcode it
/// was filed under is an index that disagrees with the file.
fn record_content(blob: &[u8], expect: u8) -> Result<&[u8]> {
    if blob.len() < RECORD_HEADER_SIZE {
        return Err(Error::Truncated(format!(
            "a {} record was fetched as {} bytes, less than a record header",
            op::name(expect),
            blob.len()
        )));
    }
    if blob[0] != expect {
        return Err(Error::Malformed(format!(
            "a range filed as {} begins with opcode 0x{:02X}",
            op::name(expect),
            blob[0]
        )));
    }
    let declared = u64::from_le_bytes([
        blob[1], blob[2], blob[3], blob[4], blob[5], blob[6], blob[7], blob[8],
    ]);
    let available = (blob.len() - RECORD_HEADER_SIZE) as u64;
    if declared > available {
        return Err(Error::Truncated(format!(
            "a {} record declares {declared} bytes of content and the range holds {available}",
            op::name(expect)
        )));
    }
    Ok(&blob[RECORD_HEADER_SIZE..RECORD_HEADER_SIZE + declared as usize])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::readable::BytesReadable;

    #[test]
    fn indexed_sampling_validates_times_it_does_not_bracket() {
        let mut bytes = vec![0; OBJECT_TRACK_HEADER_BYTES as usize];
        for time in [0.0f64, 1.0, 0.25, 2.0] {
            bytes.extend(time.to_le_bytes());
            for value in [0.0f64, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0] {
                bytes.extend(value.to_le_bytes());
            }
        }
        let range = ObjectTrackRange {
            object_id: 7,
            interpolation: rec::TRAJECTORY_LINEAR,
            sample_count: 4,
            record_offset: 41,
            record_length: bytes.len() as u64,
            content_offset: 0,
        };
        let mut source = BytesReadable::new(&bytes);
        let error = sample_object_track(&mut source, &range, 0.7, true).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("sample 2"), "{message}");
        assert!(message.contains("sample 1"), "{message}");
    }

    #[test]
    fn indexed_sampling_rejects_a_non_finite_query_time() {
        let bytes =
            vec![0; OBJECT_TRACK_HEADER_BYTES as usize + 2 * OBJECT_TRACK_SAMPLE_BYTES as usize];
        let range = ObjectTrackRange {
            object_id: 7,
            interpolation: rec::TRAJECTORY_LINEAR,
            sample_count: 2,
            record_offset: 41,
            record_length: bytes.len() as u64,
            content_offset: 0,
        };
        let mut source = BytesReadable::new(&bytes);
        let error = sample_object_track(&mut source, &range, f64::NAN, true).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("scene query time is NaN"), "{message}");
        assert!(message.contains("expected a finite value"), "{message}");
    }
}
