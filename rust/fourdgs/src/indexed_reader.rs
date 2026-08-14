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

use crate::chunk::DecodedChunk;
use crate::error::{Error, Result};
use crate::model::AudioSource;
use crate::opcode as op;
use crate::readable::Readable;
use crate::records as rec;
use crate::serialization::{crc32, Cursor, Records, MAGIC, MAX_STREAM_BYTES, RECORD_HEADER_SIZE};
use crate::stream::decode_stream_with_limit;

/// The first read from the front of a resource.
///
/// Deliberately small. The front matter a reader must parse is the Header, the Quantization
/// grids and the Window Table — a few hundred bytes on every scene measured so far — and
/// everything else there is stepped over by arithmetic rather than read. A larger probe
/// would not save a round trip, because this is one request either way; it would only
/// transfer bytes nobody asked for, and on a small file it would pull the whole thing in
/// while the caller was still deciding whether to seek. A record bigger than this is still
/// parsed from progressively larger prefixes, so the probe bounds waste rather than
/// capability.
pub const HEAD_PROBE: u64 = 8 * 1024;

/// How much of an Audio record is read to learn its codec. The codec name is the record's
/// first field, so a prefix answers it; the track stays where it is.
pub const AUDIO_CODEC_PREFIX: u64 = 4096;

const OBJECT_TRACK_HEADER_BYTES: u64 = 4 + 1 + 4;
const OBJECT_TRACK_SAMPLE_BYTES: u64 = 8 + 4 * 8 + 3 * 8;
const OBJECT_TRACK_VALIDATION_BLOCK_BYTES: u64 = 64 * 1024;

/// The most bytes one front-matter record or contiguous summary may make an indexed
/// reader retain at once.
///
/// This is an implementation ceiling, not a format limit. A newer writer may append an
/// arbitrarily large suffix to a record a version-1 reader already understands; opening
/// reads at most this prefix and steps over the remainder by its framed length.
pub const MAX_FRONT_MATTER_BYTES: u64 = 64 * 1024 * 1024;

/// The largest encoded Chunk or SH Band Stream range fetched in one indexed read.
///
/// Decoded streams have their own 512 MiB ceiling. Keeping the encoded range under the
/// same bound prevents an index entry from allocating an arbitrarily large buffer before
/// the record header and decoded-size declaration can be inspected.
pub const MAX_INDEXED_STATE_RECORD_BYTES: u64 = crate::serialization::MAX_STREAM_BYTES;

/// The most records an indexed open retains or walks in either front matter or one
/// contiguous summary.
///
/// Counting every framed record also bounds CPU spent on legal zero-length unknown
/// records, while one ceiling per framed section bounds all vectors and maps populated by
/// that walk rather than leaving a separate unbounded collection for each opcode family.
pub const MAX_RETAINED_RECORDS: usize = 1 << 18;

fn check_resource_length(at: u64, length: u64, cap: u64, what: &str) -> Result<()> {
    if length > cap {
        return Err(Error::UnsupportedOperation(format!(
            "the {what} at byte {at} declares {length} bytes, past the {cap} byte indexed-reader ceiling"
        )));
    }
    Ok(())
}

fn check_record_count(count: usize, at: u64, what: &str) -> Result<()> {
    if count > MAX_RETAINED_RECORDS {
        return Err(Error::UnsupportedOperation(format!(
            "the {what} reaches record {count} at byte {at}, past the {MAX_RETAINED_RECORDS} record indexed-reader ceiling"
        )));
    }
    Ok(())
}

fn replace_indexed_front_bytes(
    current: usize,
    replaced: usize,
    added: usize,
    prefix_capacity: usize,
    what: &str,
    at: u64,
    limit: usize,
) -> Result<usize> {
    let parse_peak = current
        .checked_add(prefix_capacity)
        .and_then(|bytes| bytes.checked_add(added))
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed {what} parse working-set bytes overflow at byte {at}"
            ))
        })?;
    if parse_peak > limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed {what} at byte {at} needs {parse_peak} bytes with already retained front matter and its parse prefix, past the {limit} byte scene ceiling"
        )));
    }
    current
        .checked_sub(replaced)
        .and_then(|bytes| bytes.checked_add(added))
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed {what} retained-byte accounting overflows at byte {at}"
            ))
        })
}

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
/// An indexed reader wants the Header, Quantization grids, Window Table, the small
/// descriptors that validate audio sources, and the byte ranges of lazy records. None
/// requires reading an encoded Audio Data payload. Encoded audio is a first-class part of
/// a scene and may be arbitrarily large, so materializing every record's content defeats
/// bounded indexed opening.
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

/// Parse the known prefix of one extensible front-matter record.
///
/// The record's framed length remains the authority for finding the next record. Only the
/// prefix this reader is willing to retain is transferred; a successful version-1 parse
/// therefore skips an arbitrarily large legal suffix without allocating it. If the known
/// fields themselves do not fit, the file is legal but outside this reader's resource
/// envelope, so the error is `UnsupportedOperation` rather than `Malformed`.
/// Parse one retained front value and report the allocation that held its successful
/// prefix.  The prefix is still live while `parse` constructs the owned value, and it may
/// be a direct range-read larger than `FrontMatter::window`; callers performing shared
/// scene accounting therefore need this allocation rather than the probe capacity.
#[cfg(test)]
fn parse_front_record_accounted<R, T>(
    front: &mut FrontMatter<'_, R>,
    record: &FrontRecord,
    what: &str,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<(T, usize)>
where
    R: Readable + ?Sized,
{
    parse_front_record_with_limit_accounted(front, record, what, MAX_FRONT_MATTER_BYTES, parse)
}

#[cfg(test)]
fn parse_front_record_with_limit<R, T>(
    front: &mut FrontMatter<'_, R>,
    record: &FrontRecord,
    what: &str,
    cap: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<T>
where
    R: Readable + ?Sized,
{
    parse_front_record_with_limit_accounted(front, record, what, cap, parse).map(|(value, _)| value)
}

fn parse_front_record_with_limit_accounted<R, T>(
    front: &mut FrontMatter<'_, R>,
    record: &FrontRecord,
    what: &str,
    cap: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<(T, usize)>
where
    R: Readable + ?Sized,
{
    let maximum = record.content_length.min(cap);
    let mut prefix_length = maximum.min(HEAD_PROBE);
    loop {
        let prefix = front.content(record, Some(prefix_length))?;
        let complete = prefix_length == record.content_length;
        rec::preflight_counted_record_length(record.opcode, &prefix, record.content_length)
            .map_err(|error| error.at_record(what, record.offset))?;
        match parse(&prefix, complete) {
            Ok(value) => return Ok((value, prefix.capacity())),
            Err(Error::Truncated(_)) if prefix_length < maximum => {
                prefix_length = prefix_length.max(1).saturating_mul(2).min(maximum);
            }
            Err(Error::Truncated(_)) if record.content_length > maximum => {
                return Err(Error::UnsupportedOperation(format!(
                    "the {what} at byte {} has required fields beyond the {cap} byte indexed-reader prefix ceiling",
                    record.offset
                )));
            }
            Err(error) => return Err(error.at_record(what, record.offset)),
        }
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

/// Descriptor range, declared payload length, and first/last keyframe time retained only
/// while indexed opening matches Audio Source and Audio Data records.
type AudioSourceFacts = ((u64, u64), u64, Option<(f64, f64)>);

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

fn indexed_vec_bytes<T>(values: &Vec<T>, what: &str) -> Result<usize> {
    values
        .capacity()
        .checked_mul(std::mem::size_of::<T>())
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} vector bytes overflow")))
}

fn planned_exact_vec_bytes<T>(len: usize, what: &str) -> Result<usize> {
    // RawVec keeps a small non-zero minimum for sub-kilobyte element types, including all
    // summary/index structs.  `reserve_exact` therefore reports at least four slots even
    // when one record is requested; planning that minimum makes the preflight match the
    // capacity subsequently charged.
    let capacity = if len == 0 { 0 } else { len.max(4) };
    capacity
        .checked_mul(std::mem::size_of::<T>())
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} planned bytes overflow")))
}

fn indexed_open_collection_bytes(scene: &IndexedScene) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        indexed_vec_bytes(&scene.metadata_ranges, "Metadata ranges")?,
        indexed_vec_bytes(&scene.attachment_ranges, "Attachment ranges")?,
        indexed_vec_bytes(&scene.provenance_ranges, "provenance ranges")?,
        indexed_vec_bytes(&scene.object_table_ranges, "Object Table ranges")?,
        indexed_vec_bytes(&scene.audio_sources, "indexed audio sources")?,
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("indexed front collection bytes overflow".into())
        })?;
    }
    total = total
        .checked_add(indexed_btree_node_bytes::<u32, ObjectTrackRange>(
            scene.object_track_ranges.len(),
            "indexed Object Track",
        )?)
        .ok_or_else(|| Error::UnsupportedOperation("indexed Object Track bytes overflow".into()))?;
    for source in &scene.audio_sources {
        total = total
            .checked_add(
                source
                    .legacy_codec
                    .as_ref()
                    .map_or(0, |codec| codec.capacity()),
            )
            .ok_or_else(|| {
                Error::UnsupportedOperation("indexed audio descriptor bytes overflow".into())
            })?;
    }
    Ok(total)
}

fn indexed_front_live_bytes(
    scene: &IndexedScene,
    retained_front_bytes: usize,
    window_bytes: usize,
    source_ranges: &BTreeMap<u32, AudioSourceFacts>,
    data_ranges: &BTreeMap<u32, (u64, u64)>,
    legacy_audio: Option<&IndexedAudioSource>,
) -> Result<usize> {
    let source_map_bytes = indexed_btree_node_bytes::<u32, AudioSourceFacts>(
        source_ranges.len(),
        "Audio Source fact",
    )?;
    let data_map_bytes =
        indexed_btree_node_bytes::<u32, (u64, u64)>(data_ranges.len(), "Audio Data fact")?;
    let legacy_bytes = legacy_audio
        .and_then(|audio| audio.legacy_codec.as_ref())
        .map_or(0, |codec| codec.capacity());
    retained_front_bytes
        .checked_add(indexed_open_collection_bytes(scene)?)
        .and_then(|bytes| bytes.checked_add(window_bytes))
        .and_then(|bytes| bytes.checked_add(source_map_bytes))
        .and_then(|bytes| bytes.checked_add(data_map_bytes))
        .and_then(|bytes| bytes.checked_add(legacy_bytes))
        .ok_or_else(|| Error::UnsupportedOperation("indexed front-matter bytes overflow".into()))
}

fn push_indexed_front_value<T>(
    values: &mut Vec<T>,
    value: T,
    live_bytes: usize,
    what: &str,
    offset: u64,
) -> Result<()> {
    let before = indexed_vec_bytes(values, what)?;
    if values.len() == values.capacity() {
        let target = if values.capacity() == 0 {
            4
        } else {
            values.capacity().checked_mul(2).ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "indexed {what} capacity overflows at byte {offset}"
                ))
            })?
        };
        let target_bytes = target
            .checked_mul(std::mem::size_of::<T>())
            .ok_or_else(|| {
                Error::UnsupportedOperation(format!(
                    "indexed {what} allocation bytes overflow at byte {offset}"
                ))
            })?;
        let added = target_bytes.checked_sub(before).ok_or_else(|| {
            Error::Malformed(format!(
                "internal indexed {what} capacity accounting underflows at byte {offset}"
            ))
        })?;
        let planned = live_bytes.checked_add(added).ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "indexed {what} working-set bytes overflow at byte {offset}"
            ))
        })?;
        if planned > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
            return Err(Error::UnsupportedOperation(format!(
                "the indexed {what} collection needs {planned} bytes with earlier front matter before byte {offset}, past the {} byte shared scene ceiling",
                crate::stream_reader::MAX_DECODED_SCENE_BYTES
            )));
        }
        values.try_reserve_exact(target - values.len()).map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed {what} collection could not reserve {target} values before byte {offset}: {error}"
            ))
        })?;
    }
    let after = indexed_vec_bytes(values, what)?;
    let actual = live_bytes
        .checked_add(after.checked_sub(before).ok_or_else(|| {
            Error::Malformed(format!(
                "internal indexed {what} capacity accounting underflows at byte {offset}"
            ))
        })?)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "indexed {what} working-set bytes overflow at byte {offset}"
            ))
        })?;
    if actual > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed {what} collection retains {actual} bytes with earlier front matter before byte {offset}, past the {} byte shared scene ceiling",
            crate::stream_reader::MAX_DECODED_SCENE_BYTES
        )));
    }
    values.push(value);
    Ok(())
}

fn check_indexed_front_map_insert<K, V>(live_bytes: usize, what: &str, offset: u64) -> Result<()> {
    let node = indexed_btree_node_bytes::<K, V>(1, what)?;
    let planned = live_bytes.checked_add(node).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "indexed {what} working-set bytes overflow at byte {offset}"
        ))
    })?;
    if planned > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed {what} map needs {planned} bytes with earlier front matter before byte {offset}, past the {} byte shared scene ceiling",
            crate::stream_reader::MAX_DECODED_SCENE_BYTES
        )));
    }
    Ok(())
}

fn indexed_summary_collection_bytes(scene: &IndexedScene) -> Result<usize> {
    let mut total = indexed_vec_bytes(&scene.index, "Chunk Index")?
        .checked_add(indexed_vec_bytes(&scene.summary_offsets, "Summary Offset")?)
        .ok_or_else(|| Error::UnsupportedOperation("summary collection bytes overflow".into()))?;
    for entry in &scene.index {
        total = total
            .checked_add(indexed_vec_bytes(&entry.bands, "Chunk Index band")?)
            .ok_or_else(|| Error::UnsupportedOperation("Chunk Index band bytes overflow".into()))?;
    }
    if let Some(statistics) = &scene.statistics {
        total = total
            .checked_add(indexed_vec_bytes(&statistics.aabb, "Statistics AABB")?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("Statistics resident bytes overflow".into())
            })?;
    }
    Ok(total)
}

/// Heap storage retained by an opened indexed scene.
///
/// This value remains live for the lifetime of `SceneReader`, including while a new
/// GaussianSet is decoded transactionally beside the previous one.  Keeping the measure
/// here makes indexed open and every later load use the same accounting vocabulary.
pub(crate) fn indexed_scene_resident_bytes(scene: &IndexedScene) -> Result<usize> {
    let mut total = crate::stream_reader::header_resident_bytes(&scene.header)?;
    for bytes in [
        crate::stream_reader::quantization_resident_bytes(&scene.quantization)?,
        indexed_vec_bytes(&scene.windows, "Window Table")?,
        indexed_open_collection_bytes(scene)?,
        indexed_summary_collection_bytes(scene)?,
    ] {
        total = total
            .checked_add(bytes)
            .ok_or_else(|| Error::UnsupportedOperation("indexed scene bytes overflow".into()))?;
    }
    Ok(total)
}

fn indexed_summary_allowance(
    retained_before_summary: usize,
    summary_start: u64,
    summary_length: u64,
    limit: usize,
) -> Result<usize> {
    let allowance = limit.checked_sub(retained_before_summary).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "the indexed front matter retains {retained_before_summary} bytes before the summary, past the {limit} byte scene ceiling"
        ))
    })?;
    if summary_length > allowance as u64 {
        return Err(Error::UnsupportedOperation(format!(
            "the contiguous summary at byte {summary_start} needs {summary_length} bytes beside {retained_before_summary} retained front-matter and range bytes, past the {limit} byte scene ceiling"
        )));
    }
    Ok(allowance)
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

/// Allocation-free bound for the owned strings and keyframes parsed from an Audio Source
/// descriptor while its prefix remains live during indexed opening.
fn audio_source_prefix_resident_bound(prefix: &[u8], full_content_length: u64) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    cursor.u32()?;
    let mut resident = scanned_string_bytes(&mut cursor)?;
    let codec = scanned_string_bytes(&mut cursor)?;
    let channel_layout = scanned_string_bytes(&mut cursor)?;
    resident = resident
        .checked_add(codec)
        .and_then(|bytes| bytes.checked_add(channel_layout))
        .ok_or_else(|| Error::UnsupportedOperation("Audio Source string bytes overflow".into()))?;
    cursor.take(std::mem::size_of::<u64>() + 3 * std::mem::size_of::<f64>() + 1)?;
    cursor.take(7 * std::mem::size_of::<f64>())?;
    let count = cursor.u32()? as usize;
    let wire_bytes = count
        .checked_mul(64)
        .ok_or_else(|| Error::Malformed("Audio Source keyframe byte count overflows".into()))?;
    let minimum = (cursor.position() as u64)
        .checked_add(wire_bytes as u64)
        .and_then(|bytes| bytes.checked_add(4))
        .ok_or_else(|| Error::Malformed("Audio Source keyframes overflow record length".into()))?;
    if minimum > full_content_length {
        return Err(Error::Malformed(format!(
            "Audio Source declares {count} keyframes needing at least {minimum} content bytes, but its record declares {full_content_length}"
        )));
    }
    cursor.take(wire_bytes)?;
    let interpolation = scanned_string_bytes(&mut cursor)?;
    resident = resident
        .checked_add(planned_exact_vec_bytes::<rec::AudioSourceKeyframe>(
            count,
            "Audio Source keyframe",
        )?)
        .and_then(|bytes| bytes.checked_add(interpolation))
        .ok_or_else(|| {
            Error::UnsupportedOperation("Audio Source resident bytes overflow".into())
        })?;
    Ok(resident)
}

fn audio_source_descriptor_resident_bytes(value: &rec::AudioSource) -> Result<usize> {
    let keyframes = indexed_vec_bytes(&value.keyframes, "Audio Source keyframes")?;
    value
        .name
        .capacity()
        .checked_add(value.codec.capacity())
        .and_then(|bytes| bytes.checked_add(value.channel_layout.capacity()))
        .and_then(|bytes| bytes.checked_add(value.interpolation.capacity()))
        .and_then(|bytes| bytes.checked_add(keyframes))
        .ok_or_else(|| Error::UnsupportedOperation("Audio Source resident bytes overflow".into()))
}

fn check_audio_source_prefix_parse_budget(
    prefix: &[u8],
    full_content_length: u64,
    remaining: usize,
    offset: u64,
) -> Result<()> {
    let projected = audio_source_prefix_resident_bound(prefix, full_content_length)?;
    let peak = prefix.len().checked_add(projected).ok_or_else(|| {
        Error::UnsupportedOperation("Audio Source parse working-set bytes overflow".into())
    })?;
    if peak > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Audio Source record at byte {offset} needs {peak} bytes for its live prefix and parsed descriptor, past the {remaining} bytes remaining beside earlier indexed front matter"
        )));
    }
    Ok(())
}

/// Open a scene: a bounded read from the front, then the index. Never the file.
pub fn open_indexed<R: Readable + ?Sized>(source: &mut R) -> Result<IndexedScene> {
    let size = source.size()?;
    let mut scene = IndexedScene::default();

    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    // Scalar facts let open validate descriptor cross-record claims without retaining
    // every keyframe or fetching one byte of Audio Data payload.
    let mut source_ranges: BTreeMap<u32, AudioSourceFacts> = BTreeMap::new();
    let mut data_ranges: BTreeMap<u32, (u64, u64)> = BTreeMap::new();
    let mut legacy_audio: Option<IndexedAudioSource> = None;
    let mut front_record_count = 0usize;
    let mut retained_front_bytes = 0usize;
    let mut header_resident_bytes = 0usize;
    let mut quantization_resident_bytes = 0usize;
    let mut window_table_resident_bytes = 0usize;
    {
        let mut front = FrontMatter::new(source, size);
        crate::serialization::check_magic(&front.head(MAGIC.len() as u64)?)?;

        let mut at = MAGIC.len() as u64;
        while at + RECORD_HEADER_SIZE as u64 <= size {
            let record = front.record_at(at)?;
            if record.opcode == op::CHUNK {
                break;
            }
            front_record_count = front_record_count.saturating_add(1);
            check_record_count(front_record_count, record.offset, "indexed front matter")?;
            match record.opcode {
                op::HEADER => {
                    let live_before_header = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        .checked_sub(live_before_header)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(format!(
                                "the indexed scene retains {live_before_header} bytes before Header at byte {}, past the {} byte shared scene ceiling",
                                record.offset,
                                crate::stream_reader::MAX_DECODED_SCENE_BYTES
                            ))
                        })?;
                    let (parsed, prefix_capacity) = parse_front_record_with_limit_accounted(
                        &mut front,
                        &record,
                        "Header record",
                        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
                        |bytes, _| {
                            crate::stream_reader::check_header_prefix_parse_budget(
                                bytes,
                                remaining,
                                record.offset,
                            )?;
                            rec::Header::parse(bytes)
                        },
                    )?;
                    crate::registry::check_temporal_model(&parsed.temporal_model)?;
                    let resident = crate::stream_reader::header_resident_bytes(&parsed)?;
                    let actual_peak = prefix_capacity.checked_add(resident).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Header parse working-set bytes overflow".into(),
                        )
                    })?;
                    if actual_peak > remaining {
                        return Err(Error::UnsupportedOperation(format!(
                            "the Header record at byte {} retains {actual_peak} prefix and parsed bytes, past the {remaining} bytes remaining beside earlier indexed front matter",
                            record.offset
                        )));
                    }
                    retained_front_bytes = replace_indexed_front_bytes(
                        retained_front_bytes,
                        header_resident_bytes,
                        resident,
                        prefix_capacity,
                        "Header",
                        record.offset,
                        crate::stream_reader::MAX_DECODED_SCENE_BYTES,
                    )?;
                    header_resident_bytes = resident;
                    header = Some(parsed)
                }
                op::QUANTIZATION => {
                    let live_before_quantization = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        .checked_sub(live_before_quantization)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(format!(
                                "the indexed scene retains {live_before_quantization} bytes before Quantization at byte {}, past the {} byte shared scene ceiling",
                                record.offset,
                                crate::stream_reader::MAX_DECODED_SCENE_BYTES
                            ))
                        })?;
                    let (parsed, prefix_capacity) = parse_front_record_with_limit_accounted(
                        &mut front,
                        &record,
                        "Quantization record",
                        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
                        |bytes, complete| {
                            crate::stream_reader::check_quantization_prefix_parse_budget(
                                bytes,
                                remaining,
                                record.offset,
                            )?;
                            rec::Quantization::parse_prefix(bytes, complete)
                        },
                    )?;
                    crate::registry::check_quantization_scheme(&parsed.scheme)?;
                    let resident = crate::stream_reader::quantization_resident_bytes(&parsed)?;
                    let actual_peak = prefix_capacity.checked_add(resident).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Quantization parse working-set bytes overflow".into(),
                        )
                    })?;
                    if actual_peak > remaining {
                        return Err(Error::UnsupportedOperation(format!(
                            "the Quantization record at byte {} retains {actual_peak} prefix and parsed bytes, past the {remaining} bytes remaining beside earlier indexed front matter",
                            record.offset
                        )));
                    }
                    retained_front_bytes = replace_indexed_front_bytes(
                        retained_front_bytes,
                        quantization_resident_bytes,
                        resident,
                        prefix_capacity,
                        "Quantization",
                        record.offset,
                        crate::stream_reader::MAX_DECODED_SCENE_BYTES,
                    )?;
                    quantization_resident_bytes = resident;
                    quant = Some(parsed)
                }
                op::WINDOW_TABLE => {
                    let live_before_windows = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        .checked_sub(live_before_windows)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(format!(
                                "the indexed scene retains {live_before_windows} bytes before Window Table at byte {}, past the {} byte shared scene ceiling",
                                record.offset,
                                crate::stream_reader::MAX_DECODED_SCENE_BYTES
                            ))
                        })?;
                    let (parsed, prefix_capacity) = parse_front_record_with_limit_accounted(
                        &mut front,
                        &record,
                        "Window Table record",
                        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
                        |bytes, _| {
                            crate::stream_reader::check_window_table_prefix_parse_budget(
                                bytes,
                                remaining,
                                record.offset,
                            )?;
                            rec::WindowTable::parse(bytes)
                        },
                    )?;
                    let resident = crate::stream_reader::window_table_resident_bytes(&parsed)?;
                    let actual_peak = prefix_capacity.checked_add(resident).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Window Table parse working-set bytes overflow".into(),
                        )
                    })?;
                    if actual_peak > remaining {
                        return Err(Error::UnsupportedOperation(format!(
                            "the Window Table record at byte {} retains {actual_peak} prefix and parsed bytes, past the {remaining} bytes remaining beside earlier indexed front matter",
                            record.offset
                        )));
                    }
                    retained_front_bytes = replace_indexed_front_bytes(
                        retained_front_bytes,
                        window_table_resident_bytes,
                        resident,
                        prefix_capacity,
                        "Window Table",
                        record.offset,
                        crate::stream_reader::MAX_DECODED_SCENE_BYTES,
                    )?;
                    window_table_resident_bytes = resident;
                    scene.windows = parsed.windows
                }
                op::AUDIO => {
                    // The track's bytes are not read here, and the record is not stepped
                    // into: a caller may want the gaussians and never the audio. Only the
                    // codec name is parsed, out of a prefix, so a scene with a large track
                    // costs nothing to open.
                    let live_before_audio = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    let prefix_length = record.content_length.min(AUDIO_CODEC_PREFIX) as usize;
                    let prefix_peak =
                        live_before_audio
                            .checked_add(prefix_length)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "indexed legacy Audio prefix bytes overflow".into(),
                                )
                            })?;
                    if prefix_peak > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
                        return Err(Error::UnsupportedOperation(format!(
                            "the legacy Audio record at byte {} needs a {prefix_length} byte prefix beside {live_before_audio} earlier indexed front-matter bytes, past the {} byte shared scene ceiling",
                            record.offset,
                            crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        )));
                    }
                    let prefix = front.content(&record, Some(AUDIO_CODEC_PREFIX))?;
                    let mut scan = Cursor::new(&prefix);
                    let codec_bytes = scanned_string_bytes(&mut scan).map_err(|_| {
                        Error::Malformed(format!(
                            "the legacy Audio descriptor does not fit the first {AUDIO_CODEC_PREFIX} bytes"
                        ))
                    })?;
                    scan.take(std::mem::size_of::<f64>() + std::mem::size_of::<u64>())?;
                    let parse_peak = live_before_audio
                        .checked_add(prefix.capacity())
                        .and_then(|bytes| bytes.checked_add(codec_bytes))
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(
                                "indexed legacy Audio parse working-set bytes overflow".into(),
                            )
                        })?;
                    if parse_peak > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
                        return Err(Error::UnsupportedOperation(format!(
                            "the legacy Audio record at byte {} needs {parse_peak} bytes for earlier front matter, its live prefix, and codec string, past the {} byte shared scene ceiling",
                            record.offset,
                            crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        )));
                    }
                    let parsed = legacy_audio_range(&prefix, record.offset, record.content_length)?;
                    let actual_peak = live_before_audio
                        .checked_add(prefix.capacity())
                        .and_then(|bytes| {
                            bytes.checked_add(
                                parsed
                                    .legacy_codec
                                    .as_ref()
                                    .map_or(0, |codec| codec.capacity()),
                            )
                        })
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(
                                "indexed legacy Audio parse working-set bytes overflow".into(),
                            )
                        })?;
                    if actual_peak > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
                        return Err(Error::UnsupportedOperation(format!(
                            "the legacy Audio record at byte {} retains {actual_peak} bytes while its prefix is live, past the {} byte shared scene ceiling",
                            record.offset,
                            crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        )));
                    }
                    legacy_audio = Some(parsed);
                }
                op::AUDIO_SOURCE => {
                    // The descriptor is intentionally reduced to scalar range facts after
                    // validation, but its strings and keyframe Vec coexist with the prefix,
                    // the sliding window, every earlier range, and both fact maps here.
                    let live_before_descriptor = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?
                    .checked_add(indexed_btree_node_bytes::<u32, AudioSourceFacts>(
                        1,
                        "Audio Source fact",
                    )?)
                    .ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Audio Source opening bytes overflow".into(),
                        )
                    })?;
                    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
                        .checked_sub(live_before_descriptor)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(format!(
                                "the indexed scene retains {live_before_descriptor} bytes before Audio Source at byte {}, past the {} byte shared scene ceiling",
                                record.offset,
                                crate::stream_reader::MAX_DECODED_SCENE_BYTES
                            ))
                        })?;
                    let (descriptor, prefix_capacity) = parse_front_record_with_limit_accounted(
                        &mut front,
                        &record,
                        "Audio Source record",
                        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
                        |bytes, complete| {
                            check_audio_source_prefix_parse_budget(
                                bytes,
                                record.content_length,
                                remaining,
                                record.offset,
                            )?;
                            rec::AudioSource::parse_prefix(bytes, complete, record.content_length)
                        },
                    )?;
                    let descriptor_bytes = audio_source_descriptor_resident_bytes(&descriptor)?;
                    let actual_peak =
                        prefix_capacity
                            .checked_add(descriptor_bytes)
                            .ok_or_else(|| {
                                Error::UnsupportedOperation(
                                    "Audio Source parse working-set bytes overflow".into(),
                                )
                            })?;
                    if actual_peak > remaining {
                        return Err(Error::UnsupportedOperation(format!(
                            "the Audio Source record at byte {} retains {actual_peak} prefix and descriptor bytes, past the {remaining} bytes remaining beside earlier indexed front matter",
                            record.offset
                        )));
                    }
                    let source_id = descriptor.source_id;
                    let keyframe_range = descriptor
                        .keyframes
                        .first()
                        .zip(descriptor.keyframes.last())
                        .map(|(first, last)| (first.time, last.time));
                    if source_ranges
                        .insert(
                            source_id,
                            (
                                (record.offset, record.total_length()),
                                descriptor.data_length,
                                keyframe_range,
                            ),
                        )
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
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?
                    .checked_add(prefix.capacity())
                    .ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Audio Data opening bytes overflow".into(),
                        )
                    })?;
                    check_indexed_front_map_insert::<u32, (u64, u64)>(
                        live,
                        "Audio Data fact",
                        record.offset,
                    )?;
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
                op::METADATA => {
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    push_indexed_front_value(
                        &mut scene.metadata_ranges,
                        (record.offset, record.total_length()),
                        live,
                        "Metadata range",
                        record.offset,
                    )?;
                }
                op::ATTACHMENT => {
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    push_indexed_front_value(
                        &mut scene.attachment_ranges,
                        (record.offset, record.total_length()),
                        live,
                        "Attachment range",
                        record.offset,
                    )?;
                }
                op::OBJECT_TABLE => {
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    push_indexed_front_value(
                        &mut scene.object_table_ranges,
                        (record.offset, record.total_length()),
                        live,
                        "Object Table range",
                        record.offset,
                    )?;
                }
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
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?
                    .checked_add(prefix.capacity())
                    .ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "indexed Object Track opening bytes overflow".into(),
                        )
                    })?;
                    check_indexed_front_map_insert::<u32, ObjectTrackRange>(
                        live,
                        "Object Track range",
                        record.offset,
                    )?;
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
                    let live = indexed_front_live_bytes(
                        &scene,
                        retained_front_bytes,
                        front.window.capacity(),
                        &source_ranges,
                        &data_ranges,
                        legacy_audio.as_ref(),
                    )?;
                    push_indexed_front_value(
                        &mut scene.provenance_ranges,
                        (code, record.offset, record.total_length()),
                        live,
                        "provenance range",
                        record.offset,
                    )?;
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
    let audio_count = if legacy_audio.is_some() {
        1
    } else {
        source_ranges.len()
    };
    let audio_slots =
        planned_exact_vec_bytes::<IndexedAudioSource>(audio_count, "indexed Audio Source")?;
    let source_fact_bytes = indexed_btree_node_bytes::<u32, AudioSourceFacts>(
        source_ranges.len(),
        "Audio Source fact",
    )?;
    let data_fact_bytes =
        indexed_btree_node_bytes::<u32, (u64, u64)>(data_ranges.len(), "Audio Data fact")?;
    let legacy_audio_bytes = legacy_audio
        .as_ref()
        .and_then(|audio| audio.legacy_codec.as_ref())
        .map_or(0, |codec| codec.capacity());
    let audio_open_live = indexed_scene_resident_bytes(&scene)?
        .checked_add(source_fact_bytes)
        .and_then(|bytes| bytes.checked_add(data_fact_bytes))
        .and_then(|bytes| bytes.checked_add(legacy_audio_bytes))
        .and_then(|bytes| bytes.checked_add(audio_slots))
        .ok_or_else(|| {
            Error::UnsupportedOperation("indexed Audio Source collection bytes overflow".into())
        })?;
    if audio_open_live > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Audio Source collection needs {audio_open_live} bytes beside retained front matter and matching maps, past the {} byte shared scene ceiling",
            crate::stream_reader::MAX_DECODED_SCENE_BYTES
        )));
    }
    scene
        .audio_sources
        .try_reserve_exact(audio_count)
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Audio Source collection could not reserve {audio_count} entries within the shared scene ceiling: {error}"
            ))
        })?;
    let actual_audio_slots = indexed_vec_bytes(&scene.audio_sources, "indexed Audio Source")?;
    let actual_audio_open_live = audio_open_live
        .checked_sub(audio_slots)
        .and_then(|bytes| bytes.checked_add(actual_audio_slots))
        .ok_or_else(|| {
            Error::UnsupportedOperation(
                "indexed Audio Source collection bytes overflow after reservation".into(),
            )
        })?;
    if actual_audio_open_live > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Audio Source collection retained {actual_audio_open_live} bytes after reservation, past the {} byte shared scene ceiling",
            crate::stream_reader::MAX_DECODED_SCENE_BYTES
        )));
    }
    if let Some(legacy) = legacy_audio {
        scene.audio_sources.push(legacy);
    } else {
        for (source_id, (descriptor_range, declared_data_length, keyframe_range)) in source_ranges {
            let Some((data_offset, data_length)) = data_ranges.remove(&source_id) else {
                return Err(Error::Malformed(format!(
                    "Audio Source record at byte {} for id {source_id} has no matching Audio Data record",
                    descriptor_range.0
                )));
            };
            if declared_data_length != data_length {
                return Err(Error::Malformed(format!(
                    "Audio Source record at byte {} for id {source_id} declares {declared_data_length} bytes, its Audio Data record declares {data_length}",
                    descriptor_range.0
                )));
            }
            if let Some((first, last)) = keyframe_range {
                if first < 0.0 || last > scene.header.duration_sec {
                    return Err(Error::Malformed(format!(
                        "Audio Source record at byte {} for id {source_id} has keyframes spanning [{first}, {last}], outside [0, {}]",
                        descriptor_range.0,
                        scene.header.duration_sec
                    )));
                }
            }
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
    drop(tail);

    if footer.summary_start != 0 {
        let summary_end = size - footer_size;
        if footer.summary_start > summary_end {
            return Err(Error::Malformed(format!(
                "the footer says the summary starts at {}, past the footer itself at {summary_end}",
                footer.summary_start
            )));
        }
        let summary_length = summary_end - footer.summary_start;
        check_resource_length(
            footer.summary_start,
            summary_length,
            MAX_FRONT_MATTER_BYTES,
            "contiguous summary",
        )?;
        let retained_before_summary = retained_front_bytes
            .checked_add(indexed_open_collection_bytes(&scene)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation(
                    "indexed front-matter and range-collection bytes overflow".into(),
                )
            })?;
        let summary_allowance = indexed_summary_allowance(
            retained_before_summary,
            footer.summary_start,
            summary_length,
            crate::stream_reader::MAX_DECODED_SCENE_BYTES,
        )?;
        let summary = source.read(footer.summary_start, summary_length)?;
        let summary_bytes = summary.capacity();
        let after_summary = summary_allowance.checked_sub(summary_bytes).ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the contiguous summary at byte {} retained {summary_bytes} bytes, past the {summary_allowance} bytes remaining beside indexed front matter",
                footer.summary_start
            ))
        })?;
        if footer.summary_crc != 0 {
            scene.summary_crc_ok = Some(crc32(&summary) == footer.summary_crc);
        }

        // Plan every allocation the summary parsers retain before constructing any of
        // them.  The summary bytes remain live throughout this walk, so outer Vec slots,
        // per-entry band vectors, and Statistics storage all share `after_summary`.
        let mut index_count = 0usize;
        let mut summary_offset_count = 0usize;
        let mut planned_band_bytes = 0usize;
        let mut statistics_count = 0usize;
        let mut planned_record_count = 0usize;
        for record in Records::new(&summary, 0) {
            let record = record?;
            planned_record_count = planned_record_count.saturating_add(1);
            let record_at = footer.summary_start.saturating_add(record.offset as u64);
            check_record_count(planned_record_count, record_at, "contiguous summary")?;
            match record.opcode {
                op::CHUNK_INDEX => {
                    rec::preflight_counted_record_length(
                        op::CHUNK_INDEX,
                        record.content,
                        record.content.len() as u64,
                    )
                    .map_err(|error| error.at_record("Chunk Index record", record_at))?;
                    let mut prefix = Cursor::new(record.content);
                    prefix.take(8 + 8 + 8 + 8 + 4)?;
                    let bands = prefix.u32()? as usize;
                    if bands > 3 {
                        return Err(Error::Malformed(format!(
                            "the Chunk Index entry at byte {record_at} declares {bands} SH band ranges; version 1 defines at most 3"
                        )));
                    }
                    index_count = index_count.checked_add(1).ok_or_else(|| {
                        Error::UnsupportedOperation("Chunk Index count overflows".into())
                    })?;
                    planned_band_bytes = planned_band_bytes
                        .checked_add(planned_exact_vec_bytes::<(u8, u64, u64)>(
                            bands,
                            "Chunk Index band",
                        )?)
                        .ok_or_else(|| {
                            Error::UnsupportedOperation(
                                "planned Chunk Index band bytes overflow".into(),
                            )
                        })?;
                }
                op::STATISTICS => {
                    statistics_count = statistics_count.checked_add(1).ok_or_else(|| {
                        Error::UnsupportedOperation("Statistics record count overflows".into())
                    })?;
                }
                op::SUMMARY_OFFSET => {
                    summary_offset_count =
                        summary_offset_count.checked_add(1).ok_or_else(|| {
                            Error::UnsupportedOperation("Summary Offset count overflows".into())
                        })?;
                }
                _ => {}
            }
        }
        let mut planned_summary_values =
            planned_exact_vec_bytes::<rec::ChunkIndexEntry>(index_count, "Chunk Index")?
                .checked_add(planned_exact_vec_bytes::<rec::SummaryOffset>(
                    summary_offset_count,
                    "Summary Offset",
                )?)
                .and_then(|bytes| bytes.checked_add(planned_band_bytes))
                .ok_or_else(|| {
                    Error::UnsupportedOperation("planned summary collection bytes overflow".into())
                })?;
        if statistics_count != 0 {
            planned_summary_values = planned_summary_values
                .checked_add(statistics_count.min(2) * 6 * std::mem::size_of::<f64>())
                .ok_or_else(|| {
                    Error::UnsupportedOperation("planned Statistics bytes overflow".into())
                })?;
        }
        if planned_summary_values > after_summary {
            return Err(Error::UnsupportedOperation(format!(
                "the contiguous summary at byte {} needs {planned_summary_values} retained index/statistics bytes beside its {summary_bytes} byte range and {retained_before_summary} retained front-matter bytes, past the {} byte scene ceiling",
                footer.summary_start,
                crate::stream_reader::MAX_DECODED_SCENE_BYTES
            )));
        }
        scene.index.try_reserve_exact(index_count).map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the Chunk Index collection could not reserve {index_count} entries within the indexed scene ceiling: {error}"
            ))
        })?;
        scene
            .summary_offsets
            .try_reserve_exact(summary_offset_count)
            .map_err(|error| {
                Error::UnsupportedOperation(format!(
                    "the Summary Offset collection could not reserve {summary_offset_count} entries within the indexed scene ceiling: {error}"
                ))
            })?;
        let mut summary_record_count = 0usize;
        for record in Records::new(&summary, 0) {
            let record = record?;
            summary_record_count = summary_record_count.saturating_add(1);
            let record_at = footer.summary_start.saturating_add(record.offset as u64);
            check_record_count(summary_record_count, record_at, "contiguous summary")?;
            match record.opcode {
                op::CHUNK_INDEX => {
                    let entry = rec::ChunkIndexEntry::parse(record.content)
                        .map_err(|error| error.at_record("Chunk Index record", record_at))?;
                    scene.index.push(entry);
                }
                op::STATISTICS => scene.statistics = Some(rec::Statistics::parse(record.content)?),
                op::SUMMARY_OFFSET => scene
                    .summary_offsets
                    .push(rec::SummaryOffset::parse(record.content)?),
                _ => {}
            }
        }
        let actual_summary_values = indexed_summary_collection_bytes(&scene)?;
        if actual_summary_values > after_summary {
            return Err(Error::UnsupportedOperation(format!(
                "the contiguous summary at byte {} retained {actual_summary_values} parsed bytes beside its {summary_bytes} byte range and {retained_before_summary} retained front-matter bytes, past the {} byte scene ceiling",
                footer.summary_start,
                crate::stream_reader::MAX_DECODED_SCENE_BYTES
            )));
        }
    }

    let retained = indexed_scene_resident_bytes(&scene)?;
    if retained > crate::stream_reader::MAX_DECODED_SCENE_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "the opened indexed scene retains {retained} bytes, past the {} byte shared scene ceiling",
            crate::stream_reader::MAX_DECODED_SCENE_BYTES
        )));
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
    read_chunk_with_limit(
        source,
        scene,
        entry,
        max_sh_band,
        crate::stream_reader::MAX_DECODED_SCENE_BYTES,
    )
}

/// Fetch one indexed Chunk within the remaining resident budget of its scene.
pub(crate) fn read_chunk_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    entry: &rec::ChunkIndexEntry,
    max_sh_band: u8,
    max_output_bytes: usize,
) -> Result<DecodedChunk> {
    check_resource_length(
        entry.chunk_offset,
        entry.chunk_length,
        MAX_INDEXED_STATE_RECORD_BYTES,
        "indexed Chunk range",
    )?;
    if entry.chunk_length > max_output_bytes as u64 {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Chunk range at byte {} needs {} encoded bytes, past the {max_output_bytes} bytes remaining in the decode working-set budget",
            entry.chunk_offset, entry.chunk_length
        )));
    }
    let mut indexed_bands = HashSet::new();
    for (band, _, _) in &entry.bands {
        if !(1..=3).contains(band) {
            return Err(Error::Malformed(format!(
                "the index labels an SH Band Stream for the Chunk at byte {} as band {band}; only bands 1 through 3 are defined",
                entry.chunk_offset
            )));
        }
        if !indexed_bands.insert(*band) {
            return Err(Error::Malformed(format!(
                "the index names SH band {band} more than once for the Chunk at byte {}",
                entry.chunk_offset
            )));
        }
    }
    let blob = source.read(entry.chunk_offset, entry.chunk_length)?;
    let content = record_content(&blob, op::CHUNK)?;
    let (head, streams) = rec::parse_chunk(content)?;
    let encoded_bytes = blob.capacity();
    let after_encoded = max_output_bytes.checked_sub(encoded_bytes).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "the indexed Chunk range at byte {} retains {encoded_bytes} encoded bytes, past the {max_output_bytes} bytes remaining in the decode working-set budget",
            entry.chunk_offset
        ))
    })?;
    let unpacked = crate::chunk::chunk_stream_bytes_with_limit(&head, streams, after_encoded)
        .map_err(|error| error.at_record("Chunk record", entry.chunk_offset))?;
    let unpacked_bytes = match &unpacked {
        std::borrow::Cow::Borrowed(_) => 0,
        std::borrow::Cow::Owned(bytes) => bytes.capacity(),
    };
    let decode_budget = after_encoded.checked_sub(unpacked_bytes).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "the indexed Chunk at byte {} retains {unpacked_bytes} unpacked bytes, past the {after_encoded} bytes remaining after its encoded range",
            entry.chunk_offset
        ))
    })?;
    let mut decoded = crate::chunk::decode_streams_with_limit(
        &unpacked,
        head.count as usize,
        &scene.quantization.steps(),
        &scene.quantization.pos_origin,
        &scene.windows,
        scene.header.cutoff,
        decode_budget,
    )?;
    drop(unpacked);
    drop(blob);

    let mut decoded_bytes =
        crate::stream_reader::decoded_chunk_resident_bytes(&decoded, &BTreeMap::new())?;

    let mut bands = BTreeMap::new();
    for (band, offset, length) in &entry.bands {
        if *band > max_sh_band {
            continue;
        }
        check_resource_length(
            *offset,
            *length,
            MAX_INDEXED_STATE_RECORD_BYTES,
            "indexed SH Band Stream range",
        )?;
        let band_node_bytes = crate::stream_reader::decoded_band_map_node_bytes(1)?;
        let encoded_remaining = max_output_bytes
            .checked_sub(decoded_bytes)
            .and_then(|bytes| bytes.checked_sub(band_node_bytes))
            .ok_or_else(|| {
                Error::UnsupportedOperation(
                    "resident indexed Chunk state and its SH map node leave no bytes beside them for the SH range read".into(),
                )
            })?;
        if *length > encoded_remaining as u64 {
            return Err(Error::UnsupportedOperation(format!(
                "the indexed SH Band Stream range at byte {offset} needs {length} encoded bytes beside {decoded_bytes} resident Chunk and SH bytes, past the {max_output_bytes} byte decode working-set budget"
            )));
        }
        let blob = source.read(*offset, *length)?;
        let content = record_content(&blob, op::SH_BAND_STREAM)?;
        let mut cursor = Cursor::new(content);
        let physical_band = cursor.u8()?;
        if !(1..=3).contains(&physical_band) {
            return Err(Error::Malformed(format!(
                "the SH Band Stream at byte {offset} declares band {physical_band}; only bands 1 through 3 are defined"
            )));
        }
        if physical_band != *band {
            return Err(Error::Malformed(format!(
                "the index labels the SH Band Stream at byte {offset} as band {band}; the record declares band {physical_band}"
            )));
        }
        let encoded_bytes = blob.capacity();
        let live_before_values = decoded_bytes
            .checked_add(band_node_bytes)
            .and_then(|bytes| bytes.checked_add(encoded_bytes))
            .ok_or_else(|| {
                Error::UnsupportedOperation("indexed SH decode working-set bytes overflow".into())
            })?;
        // Let the stream decoder inspect its fixed header even when no allocation budget
        // remains, so a defined-channel mismatch stays malformed rather than being hidden
        // behind the resource ceiling. A structurally valid non-empty stream will refuse
        // before allocating output against this zero remainder.
        let remaining = max_output_bytes.saturating_sub(live_before_values);
        let expected_channels = 3 * (2 * physical_band as usize + 1);
        let (_, values) = decode_stream_with_limit(
            &mut cursor,
            Some(head.count as usize),
            Some(expected_channels),
            remaining,
        )
        .map_err(|error| error.at_record("SH Band Stream record", *offset))?;
        if live_before_values > max_output_bytes {
            return Err(Error::UnsupportedOperation(format!(
                "the indexed SH Band Stream at byte {offset} and resident Chunk state need {live_before_values} bytes, past the {max_output_bytes} byte decode working-set budget"
            )));
        }
        drop(blob);
        let added = crate::stream_reader::decoded_stream_resident_bytes(&values)?
            .checked_add(band_node_bytes)
            .ok_or_else(|| {
                Error::UnsupportedOperation("indexed SH retained bytes overflow".into())
            })?;
        decoded_bytes = decoded_bytes.checked_add(added).ok_or_else(|| {
            Error::UnsupportedOperation("indexed Chunk and SH resident bytes overflow".into())
        })?;
        if decoded_bytes > max_output_bytes {
            return Err(Error::UnsupportedOperation(format!(
                "the indexed Chunk and requested SH bands need {decoded_bytes} resident bytes, past the {max_output_bytes} bytes remaining in the aggregate decoded-scene budget"
            )));
        }
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
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
        .checked_sub(scene_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for the Camera record"
            ))
        })?;
    read_camera_with_limit(source, scene, remaining)
}

fn camera_prefix_resident_bound(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    cursor.take(7 * std::mem::size_of::<f64>())?;
    let count = cursor.u32()? as usize;
    let sample_bytes = count
        .checked_mul(7 * std::mem::size_of::<f64>())
        .ok_or_else(|| Error::Malformed("Camera sample-byte count overflows".into()))?;
    cursor.take(sample_bytes)?;
    let interpolation = scanned_string_bytes(&mut cursor)?;
    cursor.u8()?;
    let positions = planned_exact_vec_bytes::<[f64; 3]>(count, "Camera positions")?;
    let targets = planned_exact_vec_bytes::<[f64; 3]>(count, "Camera targets")?;
    let resident_samples = planned_exact_vec_bytes::<f64>(count, "Camera times")?
        .checked_add(positions)
        .and_then(|bytes| bytes.checked_add(targets))
        .ok_or_else(|| Error::UnsupportedOperation("Camera sample bytes overflow".into()))?;
    resident_samples
        .checked_add(interpolation)
        .ok_or_else(|| Error::UnsupportedOperation("Camera resident-byte bound overflows".into()))
}

pub(crate) fn camera_resident_bytes(camera: &rec::Camera) -> Result<usize> {
    let mut total = camera.interpolation.capacity();
    for bytes in [
        indexed_vec_bytes(&camera.times, "Camera times")?,
        indexed_vec_bytes(&camera.positions, "Camera positions")?,
        indexed_vec_bytes(&camera.targets, "Camera targets")?,
    ] {
        total = total
            .checked_add(bytes)
            .ok_or_else(|| Error::UnsupportedOperation("Camera resident bytes overflow".into()))?;
    }
    Ok(total)
}

pub(crate) fn read_camera_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    retained_limit: usize,
) -> Result<Option<rec::Camera>> {
    match scene.camera_range {
        None => Ok(None),
        Some((offset, length)) => {
            let camera = read_capped_record_with_limit(
                source,
                offset,
                length,
                op::CAMERA,
                "Camera record",
                (retained_limit as u64).min(MAX_FRONT_MATTER_BYTES),
                |bytes, _| {
                    let projected = camera_prefix_resident_bound(bytes)?;
                    let peak = bytes.len().checked_add(projected).ok_or_else(|| {
                        Error::UnsupportedOperation(
                            "Camera parse working-set bytes overflow".into(),
                        )
                    })?;
                    if peak > retained_limit {
                        return Err(Error::UnsupportedOperation(format!(
                            "the Camera record at byte {offset} needs {peak} bytes for its live prefix and parsed value, past the {retained_limit} bytes remaining in the shared retained-record budget"
                        )));
                    }
                    rec::Camera::parse(bytes)
                },
            )?;
            let resident = camera_resident_bytes(&camera)?;
            if resident > retained_limit {
                return Err(Error::UnsupportedOperation(format!(
                    "the Camera record at byte {offset} retains {resident} bytes, past the {retained_limit} bytes remaining in the shared retained-record budget"
                )));
            }
            Ok(Some(camera))
        }
    }
}

/// Every Metadata record, by range.
pub fn read_metadata<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Vec<rec::Metadata>> {
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
        .checked_sub(scene_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for Metadata records"
            ))
        })?;
    read_metadata_with_limit(source, scene, remaining)
}

fn indexed_btree_node_bytes<K, V>(len: usize, what: &str) -> Result<usize> {
    let per_node = std::mem::size_of::<(K, V)>()
        .checked_add(4 * std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} map-row bytes overflow")))?;
    len.checked_mul(per_node)
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} map bytes overflow")))
}

fn indexed_hash_table_bytes<K, V>(capacity: usize, what: &str) -> Result<usize> {
    let per_entry = std::mem::size_of::<(K, V)>()
        .checked_add(4 * std::mem::size_of::<usize>())
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} hash-row bytes overflow")))?;
    capacity
        .checked_mul(per_entry)
        .ok_or_else(|| Error::UnsupportedOperation(format!("{what} hash bytes overflow")))
}

fn metadata_resident_bytes(metadata: &rec::Metadata) -> Result<usize> {
    let mut total = metadata.name.capacity();
    total = total
        .checked_add(indexed_btree_node_bytes::<String, String>(
            metadata.entries.len(),
            "Metadata",
        )?)
        .ok_or_else(|| Error::UnsupportedOperation("Metadata resident bytes overflow".into()))?;
    for (key, value) in &metadata.entries {
        total = total
            .checked_add(key.capacity())
            .and_then(|bytes| bytes.checked_add(value.capacity()))
            .ok_or_else(|| Error::UnsupportedOperation("Metadata string bytes overflow".into()))?;
    }
    Ok(total)
}

/// Allocation-free upper bound for the owned strings/map a Metadata prefix will parse.
pub(crate) fn metadata_prefix_resident_bound(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    let name_len = cursor.u32()? as usize;
    let name = cursor.take(name_len)?;
    std::str::from_utf8(name)
        .map_err(|error| Error::Malformed(format!("a string field is not valid UTF-8: {error}")))?;
    let block_length = cursor.u32()? as usize;
    let block = cursor.take(block_length)?;
    let mut entries = Cursor::new(block);
    let mut count = 0usize;
    let mut strings = name_len;
    while entries.remaining() > 0 {
        for _ in 0..2 {
            let length = entries.u32()? as usize;
            let value = entries.take(length)?;
            std::str::from_utf8(value).map_err(|error| {
                Error::Malformed(format!("a string field is not valid UTF-8: {error}"))
            })?;
            strings = strings.checked_add(length).ok_or_else(|| {
                Error::UnsupportedOperation("Metadata string-byte bound overflows".into())
            })?;
        }
        count = count
            .checked_add(1)
            .ok_or_else(|| Error::UnsupportedOperation("Metadata entry count overflows".into()))?;
    }
    strings
        .checked_add(indexed_btree_node_bytes::<String, String>(
            count, "Metadata",
        )?)
        .ok_or_else(|| Error::UnsupportedOperation("Metadata resident bound overflows".into()))
}

fn read_metadata_record<R: Readable + ?Sized>(
    source: &mut R,
    offset: u64,
    total_length: u64,
    remaining: usize,
) -> Result<(rec::Metadata, usize)> {
    if total_length < RECORD_HEADER_SIZE as u64 {
        return Err(Error::Truncated(format!(
            "the Metadata record at byte {offset} is only {total_length} bytes; its record header needs {RECORD_HEADER_SIZE}"
        )));
    }
    if remaining < RECORD_HEADER_SIZE {
        return Err(Error::UnsupportedOperation(format!(
            "the Metadata record at byte {offset} needs {RECORD_HEADER_SIZE} framing bytes, past the {remaining} bytes remaining in the shared retained-record budget"
        )));
    }
    let head = source.read(offset, RECORD_HEADER_SIZE as u64)?;
    let mut framing = Cursor::new(&head);
    let physical_opcode = framing.u8()?;
    let declared = framing.u64()?;
    if physical_opcode != op::METADATA {
        return Err(Error::Malformed(format!(
            "the Metadata record range at byte {offset} contains {}; expected Metadata",
            op::name(physical_opcode)
        )));
    }
    let framed_total = declared
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| Error::Malformed("the Metadata record length overflows".into()))?;
    if framed_total != total_length {
        return Err(Error::Malformed(format!(
            "the Metadata record at byte {offset} frames {framed_total} bytes, but its retained range is {total_length} bytes"
        )));
    }

    let maximum = declared.min(MAX_FRONT_MATTER_BYTES);
    let content_offset = offset
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| Error::Malformed("the Metadata content offset overflows".into()))?;
    let mut prefix_length = maximum.min(HEAD_PROBE);
    loop {
        if prefix_length > remaining as u64 {
            return Err(Error::UnsupportedOperation(format!(
                "the Metadata record at byte {offset} needs {prefix_length} prefix bytes, past the {remaining} bytes remaining in the shared retained-record budget"
            )));
        }
        let prefix = source.read(content_offset, prefix_length)?;
        let complete = prefix_length == declared;
        rec::preflight_counted_record_length(op::METADATA, &prefix, declared)
            .map_err(|error| error.at_record("Metadata record", offset))?;
        match metadata_prefix_resident_bound(&prefix) {
            Ok(projected) => {
                let peak = prefix.capacity().checked_add(projected).ok_or_else(|| {
                    Error::UnsupportedOperation("Metadata parse working-set bytes overflow".into())
                })?;
                if peak > remaining {
                    return Err(Error::UnsupportedOperation(format!(
                        "the Metadata record at byte {offset} needs {peak} bytes for its live prefix and parsed value, past the {remaining} bytes remaining in the shared retained-record budget"
                    )));
                }
                let metadata = rec::Metadata::parse(&prefix)
                    .map_err(|error| error.at_record("Metadata record", offset))?;
                let resident = metadata_resident_bytes(&metadata)?;
                debug_assert!(resident <= projected);
                return Ok((metadata, resident));
            }
            Err(Error::Truncated(_)) if prefix_length < maximum => {
                prefix_length = prefix_length.max(1).saturating_mul(2).min(maximum);
            }
            Err(Error::Truncated(_)) if declared > maximum => {
                return Err(Error::UnsupportedOperation(format!(
                    "the Metadata record at byte {offset} has required fields beyond the {MAX_FRONT_MATTER_BYTES} byte indexed-reader prefix ceiling"
                )));
            }
            Err(error) => return Err(error.at_record("Metadata record", offset)),
        }
        if complete {
            unreachable!("a complete Metadata record cannot need a longer prefix");
        }
    }
}

pub(crate) fn metadata_collection_resident_bytes(values: &Vec<rec::Metadata>) -> Result<usize> {
    let mut total = indexed_vec_bytes(values, "Metadata result")?;
    for value in values {
        total = total
            .checked_add(metadata_resident_bytes(value)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("Metadata collection resident bytes overflow".into())
            })?;
    }
    Ok(total)
}

pub(crate) fn read_metadata_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    retained_limit: usize,
) -> Result<Vec<rec::Metadata>> {
    let planned = planned_exact_vec_bytes::<rec::Metadata>(
        scene.metadata_ranges.len(),
        "indexed Metadata result",
    )?;
    if planned > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Metadata result vector needs at least {planned} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    let mut out = Vec::new();
    out.try_reserve_exact(scene.metadata_ranges.len())
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Metadata result vector could not reserve {} entries within the {retained_limit} byte retained-record ceiling: {error}",
                scene.metadata_ranges.len()
            ))
        })?;
    let mut retained = out
        .capacity()
        .checked_mul(std::mem::size_of::<rec::Metadata>())
        .ok_or_else(|| {
            Error::UnsupportedOperation("indexed Metadata result-vector bytes overflow".into())
        })?;
    if retained > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Metadata result vector retained {retained} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    for (offset, length) in &scene.metadata_ranges {
        let remaining = retained_limit - retained;
        let (metadata, bytes) = read_metadata_record(source, *offset, *length, remaining)?;
        retained = retained.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("retained indexed Metadata bytes overflow".into())
        })?;
        out.push(metadata);
    }
    Ok(out)
}

/// Every Attachment record, by range. Each one costs exactly its own bytes.
pub fn read_attachments<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Vec<rec::Attachment>> {
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = (MAX_STREAM_BYTES as usize).checked_sub(scene_bytes).ok_or_else(|| {
        Error::UnsupportedOperation(format!(
            "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for Attachment records"
        ))
    })?;
    read_attachments_with_limit(source, scene, remaining)
}

pub(crate) fn attachment_collection_resident_bytes(values: &Vec<rec::Attachment>) -> Result<usize> {
    let mut total = indexed_vec_bytes(values, "Attachment result")?;
    for value in values {
        total = total
            .checked_add(value.name.capacity())
            .and_then(|bytes| bytes.checked_add(value.media_type.capacity()))
            .and_then(|bytes| bytes.checked_add(value.data.capacity()))
            .ok_or_else(|| {
                Error::UnsupportedOperation("Attachment collection resident bytes overflow".into())
            })?;
    }
    Ok(total)
}

pub(crate) fn read_attachments_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    retained_limit: usize,
) -> Result<Vec<rec::Attachment>> {
    let planned = planned_exact_vec_bytes::<rec::Attachment>(
        scene.attachment_ranges.len(),
        "indexed Attachment result",
    )?;
    if planned > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Attachment result vector needs at least {planned} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    let mut out = Vec::new();
    out.try_reserve_exact(scene.attachment_ranges.len())
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Attachment result vector could not reserve {} entries within the {retained_limit} byte retained-record ceiling: {error}",
                scene.attachment_ranges.len()
            ))
        })?;
    let mut retained = out
        .capacity()
        .checked_mul(std::mem::size_of::<rec::Attachment>())
        .ok_or_else(|| {
            Error::UnsupportedOperation("indexed Attachment result-vector bytes overflow".into())
        })?;
    if retained > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Attachment result vector retained {retained} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    for (offset, length) in &scene.attachment_ranges {
        let remaining = retained_limit - retained;
        let (attachment, bytes) = read_attachment_record(source, *offset, *length, remaining)?;
        retained = retained.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("retained indexed Attachment bytes overflow".into())
        })?;
        out.push(attachment);
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
fn scanned_string_bytes(cursor: &mut Cursor<'_>) -> Result<usize> {
    let length = cursor.u32()? as usize;
    let value = cursor.take(length)?;
    std::str::from_utf8(value)
        .map_err(|error| Error::Malformed(format!("a string field is not valid UTF-8: {error}")))?;
    Ok(length)
}

/// Allocation-free bound for the heap storage a provenance prefix will retain.
fn provenance_prefix_resident_bound(opcode: u8, prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    match opcode {
        op::COORDINATE_FRAME => {
            let name = scanned_string_bytes(&mut cursor)?;
            cursor.take(4 + std::mem::size_of::<f64>())?;
            Ok(name)
        }
        op::SENSOR_CALIBRATION => {
            let name = scanned_string_bytes(&mut cursor)?;
            let modality = scanned_string_bytes(&mut cursor)?;
            cursor.take(1 + 2 * std::mem::size_of::<u32>() + 4 * std::mem::size_of::<f64>())?;
            let distortion_count = cursor.u8()? as usize;
            let distortion_bytes = distortion_count
                .checked_mul(std::mem::size_of::<f64>())
                .ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "Sensor Calibration distortion bytes overflow".into(),
                    )
                })?;
            cursor.take(distortion_bytes)?;
            cursor.take(7 * std::mem::size_of::<f64>() + 1)?;
            let rig_name = scanned_string_bytes(&mut cursor)?;
            name.checked_add(modality)
                .and_then(|bytes| bytes.checked_add(distortion_bytes))
                .and_then(|bytes| bytes.checked_add(rig_name))
                .ok_or_else(|| {
                    Error::UnsupportedOperation("Sensor Calibration resident bytes overflow".into())
                })
        }
        op::RIG_TRAJECTORY => {
            let name = scanned_string_bytes(&mut cursor)?;
            cursor.u8()?;
            let count = cursor.u32()? as usize;
            if count > rec::MAX_TRAJECTORY_SAMPLES {
                return Err(Error::Malformed(format!(
                    "trajectory declares {count} samples, past the {} ceiling",
                    rec::MAX_TRAJECTORY_SAMPLES
                )));
            }
            let wire_samples = count
                .checked_mul(8 * std::mem::size_of::<f64>())
                .ok_or_else(|| {
                    Error::UnsupportedOperation("Rig Trajectory sample bytes overflow".into())
                })?;
            cursor.take(wire_samples)?;
            let rotations = planned_exact_vec_bytes::<[f64; 4]>(count, "Rig Trajectory rotations")?;
            let translations =
                planned_exact_vec_bytes::<[f64; 3]>(count, "Rig Trajectory translations")?;
            let samples = planned_exact_vec_bytes::<f64>(count, "Rig Trajectory times")?
                .checked_add(rotations)
                .and_then(|bytes| bytes.checked_add(translations))
                .ok_or_else(|| {
                    Error::UnsupportedOperation("Rig Trajectory sample bytes overflow".into())
                })?;
            name.checked_add(samples).ok_or_else(|| {
                Error::UnsupportedOperation("Rig Trajectory resident bytes overflow".into())
            })
        }
        op::GEODETIC_ANCHOR => {
            let frame_name = scanned_string_bytes(&mut cursor)?;
            cursor.take(4 * std::mem::size_of::<f64>())?;
            Ok(frame_name)
        }
        _ => Ok(0),
    }
}

fn coordinate_frame_resident_bytes(value: &rec::CoordinateFrame) -> usize {
    value.name.capacity()
}

fn sensor_calibration_resident_bytes(value: &rec::SensorCalibration) -> Result<usize> {
    value
        .name
        .capacity()
        .checked_add(value.modality.capacity())
        .and_then(|bytes| {
            value
                .distortion
                .capacity()
                .checked_mul(std::mem::size_of::<f64>())
                .and_then(|distortion| bytes.checked_add(distortion))
        })
        .and_then(|bytes| bytes.checked_add(value.rig_name.capacity()))
        .ok_or_else(|| {
            Error::UnsupportedOperation("Sensor Calibration resident bytes overflow".into())
        })
}

fn rig_trajectory_resident_bytes(value: &rec::RigTrajectory) -> Result<usize> {
    let mut total = value.name.capacity();
    for bytes in [
        indexed_vec_bytes(&value.times, "Rig Trajectory times")?,
        indexed_vec_bytes(&value.rotations, "Rig Trajectory rotations")?,
        indexed_vec_bytes(&value.translations, "Rig Trajectory translations")?,
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("Rig Trajectory resident bytes overflow".into())
        })?;
    }
    Ok(total)
}

fn reserve_provenance_collection<T>(
    values: &mut Vec<T>,
    count: usize,
    retained: usize,
    retained_limit: usize,
    what: &str,
) -> Result<usize> {
    let planned = planned_exact_vec_bytes::<T>(count, what)?
        .checked_add(retained)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!("indexed {what} result bytes overflow"))
        })?;
    if planned > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed {what} result vector needs {planned} retained bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    values.try_reserve_exact(count).map_err(|error| {
        Error::UnsupportedOperation(format!(
            "the indexed {what} result vector could not reserve {count} entries within the shared retained-record ceiling: {error}"
        ))
    })?;
    retained
        .checked_add(indexed_vec_bytes(values, what)?)
        .ok_or_else(|| Error::UnsupportedOperation("indexed provenance bytes overflow".into()))
}

fn read_provenance_value<R, T>(
    source: &mut R,
    range: (u64, u64),
    opcode: u8,
    what: &str,
    remaining: usize,
    parse: impl Fn(&[u8], bool) -> Result<T>,
    resident: impl Fn(&T) -> Result<usize>,
) -> Result<(T, usize)>
where
    R: Readable + ?Sized,
{
    let (offset, length) = range;
    let value = read_capped_record_with_limit(
        source,
        offset,
        length,
        opcode,
        what,
        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
        |bytes, complete| {
            let projected = provenance_prefix_resident_bound(opcode, bytes)?;
            let peak = bytes.len().checked_add(projected).ok_or_else(|| {
                Error::UnsupportedOperation("provenance parse working-set bytes overflow".into())
            })?;
            if peak > remaining {
                return Err(Error::UnsupportedOperation(format!(
                    "the {what} at byte {offset} needs {peak} bytes for its live prefix and parsed value, past the {remaining} bytes remaining in the shared retained-record budget"
                )));
            }
            parse(bytes, complete)
        },
    )?;
    let bytes = resident(&value)?;
    if bytes > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the {what} at byte {offset} retained {bytes} bytes, past the {remaining} bytes remaining in the shared retained-record budget"
        )));
    }
    Ok((value, bytes))
}

pub fn read_provenance<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<crate::provenance::Provenance> {
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
        .checked_sub(scene_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for provenance records"
            ))
        })?;
    read_provenance_with_limit(source, scene, remaining)
}

pub(crate) fn provenance_resident_bytes(value: &crate::provenance::Provenance) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        indexed_vec_bytes(&value.frames, "Coordinate Frame result")?,
        indexed_vec_bytes(&value.sensors, "Sensor Calibration result")?,
        indexed_vec_bytes(&value.trajectories, "Rig Trajectory result")?,
        indexed_vec_bytes(&value.anchors, "Geodetic Anchor result")?,
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("provenance collection resident bytes overflow".into())
        })?;
    }
    for frame in &value.frames {
        total = total
            .checked_add(coordinate_frame_resident_bytes(frame))
            .ok_or_else(|| {
                Error::UnsupportedOperation("provenance collection resident bytes overflow".into())
            })?;
    }
    for sensor in &value.sensors {
        total = total
            .checked_add(sensor_calibration_resident_bytes(sensor)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("provenance collection resident bytes overflow".into())
            })?;
    }
    for trajectory in &value.trajectories {
        total = total
            .checked_add(rig_trajectory_resident_bytes(trajectory)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("provenance collection resident bytes overflow".into())
            })?;
    }
    for anchor in &value.anchors {
        total = total
            .checked_add(anchor.frame_name.capacity())
            .ok_or_else(|| {
                Error::UnsupportedOperation("provenance collection resident bytes overflow".into())
            })?;
    }
    Ok(total)
}

pub(crate) fn read_provenance_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    retained_limit: usize,
) -> Result<crate::provenance::Provenance> {
    let mut out = crate::provenance::Provenance::default();
    let count = |wanted| {
        scene
            .provenance_ranges
            .iter()
            .filter(|(opcode, _, _)| *opcode == wanted)
            .count()
    };
    let mut retained = 0usize;
    retained = reserve_provenance_collection(
        &mut out.frames,
        count(op::COORDINATE_FRAME),
        retained,
        retained_limit,
        "Coordinate Frame",
    )?;
    retained = reserve_provenance_collection(
        &mut out.sensors,
        count(op::SENSOR_CALIBRATION),
        retained,
        retained_limit,
        "Sensor Calibration",
    )?;
    retained = reserve_provenance_collection(
        &mut out.trajectories,
        count(op::RIG_TRAJECTORY),
        retained,
        retained_limit,
        "Rig Trajectory",
    )?;
    retained = reserve_provenance_collection(
        &mut out.anchors,
        count(op::GEODETIC_ANCHOR),
        retained,
        retained_limit,
        "Geodetic Anchor",
    )?;
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
        let remaining = retained_limit - retained;
        match *opcode {
            op::COORDINATE_FRAME => {
                let (value, bytes) = read_provenance_value(
                    source,
                    (*offset, *length),
                    *opcode,
                    "Coordinate Frame record",
                    remaining,
                    |bytes, _| rec::CoordinateFrame::parse(bytes),
                    |value| Ok(coordinate_frame_resident_bytes(value)),
                )?;
                retained = retained.checked_add(bytes).ok_or_else(|| {
                    Error::UnsupportedOperation("indexed provenance bytes overflow".into())
                })?;
                out.frames.push(value);
            }
            op::SENSOR_CALIBRATION => {
                let (value, bytes) = read_provenance_value(
                    source,
                    (*offset, *length),
                    *opcode,
                    "Sensor Calibration record",
                    remaining,
                    |bytes, _| rec::SensorCalibration::parse(bytes),
                    sensor_calibration_resident_bytes,
                )?;
                retained = retained.checked_add(bytes).ok_or_else(|| {
                    Error::UnsupportedOperation("indexed provenance bytes overflow".into())
                })?;
                out.sensors.push(value);
            }
            op::RIG_TRAJECTORY => {
                // Section 5.15.4: a trajectory with no samples is read as though absent.
                let (trajectory, bytes) = read_provenance_value(
                    source,
                    (*offset, *length),
                    *opcode,
                    "Rig Trajectory record",
                    remaining,
                    |bytes, _| rec::RigTrajectory::parse(bytes),
                    rig_trajectory_resident_bytes,
                )?;
                if trajectory.sample_count() > 0 {
                    retained = retained.checked_add(bytes).ok_or_else(|| {
                        Error::UnsupportedOperation("indexed provenance bytes overflow".into())
                    })?;
                    out.trajectories.push(trajectory);
                }
            }
            op::GEODETIC_ANCHOR => {
                let (value, bytes) = read_provenance_value(
                    source,
                    (*offset, *length),
                    *opcode,
                    "Geodetic Anchor record",
                    remaining,
                    |bytes, _| rec::GeodeticAnchor::parse(bytes),
                    |value| Ok(value.frame_name.capacity()),
                )?;
                retained = retained.checked_add(bytes).ok_or_else(|| {
                    Error::UnsupportedOperation("indexed provenance bytes overflow".into())
                })?;
                out.anchors.push(value);
            }
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
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
        .checked_sub(scene_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for the Object Layer"
            ))
        })?;
    read_objects_with_limit(source, scene, remaining)
}

fn object_table_resident_bytes(value: &rec::ObjectTable) -> Result<usize> {
    let mut total = indexed_vec_bytes(&value.entries, "Object Table entries")?;
    for entry in &value.entries {
        total = total.checked_add(entry.label.capacity()).ok_or_else(|| {
            Error::UnsupportedOperation("Object Table resident bytes overflow".into())
        })?;
        if let Some(embedding) = &entry.embedding {
            total = total
                .checked_add(indexed_vec_bytes(embedding, "Object embedding")?)
                .ok_or_else(|| {
                    Error::UnsupportedOperation("Object Table resident bytes overflow".into())
                })?;
        }
    }
    Ok(total)
}

fn object_track_resident_bytes(value: &rec::ObjectTrack) -> Result<usize> {
    let mut total = 0usize;
    for bytes in [
        indexed_vec_bytes(&value.times, "Object Track times")?,
        indexed_vec_bytes(&value.rotations, "Object Track rotations")?,
        indexed_vec_bytes(&value.translations, "Object Track translations")?,
    ] {
        total = total.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("Object Track resident bytes overflow".into())
        })?;
    }
    Ok(total)
}

pub(crate) fn object_layer_resident_bytes(
    value: &crate::object_layer::ObjectLayer,
) -> Result<usize> {
    let mut total = indexed_vec_bytes(&value.tracks, "Object Layer tracks")?;
    if let Some(table) = &value.table {
        total = total
            .checked_add(object_table_resident_bytes(table)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("Object Layer resident bytes overflow".into())
            })?;
    }
    for track in &value.tracks {
        total = total
            .checked_add(object_track_resident_bytes(track)?)
            .ok_or_else(|| {
                Error::UnsupportedOperation("Object Layer resident bytes overflow".into())
            })?;
    }
    Ok(total)
}

fn object_track_prefix_resident_bound(prefix: &[u8]) -> Result<usize> {
    let mut cursor = Cursor::new(prefix);
    cursor.u32()?;
    cursor.u8()?;
    let count = cursor.u32()? as usize;
    if count > rec::MAX_TRAJECTORY_SAMPLES {
        return Err(Error::Malformed(format!(
            "Object Track declares {count} samples, past the {} ceiling",
            rec::MAX_TRAJECTORY_SAMPLES
        )));
    }
    let wire_bytes = count
        .checked_mul(OBJECT_TRACK_SAMPLE_BYTES as usize)
        .ok_or_else(|| Error::Malformed("Object Track sample-byte count overflows".into()))?;
    cursor.take(wire_bytes)?;
    let rotations = planned_exact_vec_bytes::<[f64; 4]>(count, "Object Track rotations")?;
    let translations = planned_exact_vec_bytes::<[f64; 3]>(count, "Object Track translations")?;
    planned_exact_vec_bytes::<f64>(count, "Object Track times")?
        .checked_add(rotations)
        .and_then(|bytes| bytes.checked_add(translations))
        .ok_or_else(|| Error::UnsupportedOperation("Object Track sample bytes overflow".into()))
}

pub(crate) fn read_objects_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    retained_limit: usize,
) -> Result<crate::object_layer::ObjectLayer> {
    let mut out = crate::object_layer::ObjectLayer::default();
    let planned_tracks = planned_exact_vec_bytes::<rec::ObjectTrack>(
        scene.object_track_ranges.len(),
        "Object Layer track",
    )?;
    let planned_range_order = planned_exact_vec_bytes::<&ObjectTrackRange>(
        scene.object_track_ranges.len(),
        "Object Layer range order",
    )?;
    let planned_id_capacity = if scene.object_track_ranges.is_empty() {
        0
    } else {
        scene
            .object_track_ranges
            .len()
            .checked_mul(2)
            .map(|capacity| capacity.max(4))
            .ok_or_else(|| {
                Error::UnsupportedOperation("Object Layer identity-set capacity overflows".into())
            })?
    };
    let planned_id_set =
        indexed_hash_table_bytes::<u32, ()>(planned_id_capacity, "Object Layer identity")?;
    let planned_collections = planned_tracks
        .checked_add(planned_range_order)
        .and_then(|bytes| bytes.checked_add(planned_id_set))
        .ok_or_else(|| {
            Error::UnsupportedOperation("Object Layer collection bytes overflow".into())
        })?;
    if planned_collections > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Object Layer track and file-order vectors need {planned_collections} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    out.tracks
        .try_reserve_exact(scene.object_track_ranges.len())
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Object Layer could not reserve {} track slots within the shared retained-record ceiling: {error}",
                scene.object_track_ranges.len()
            ))
        })?;
    let mut ranges: Vec<&ObjectTrackRange> = Vec::new();
    ranges
        .try_reserve_exact(scene.object_track_ranges.len())
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Object Layer could not reserve {} file-order references within the shared retained-record ceiling: {error}",
                scene.object_track_ranges.len()
            ))
        })?;
    ranges.extend(scene.object_track_ranges.values());
    ranges.sort_by_key(|range| range.record_offset);
    let mut seen = HashSet::new();
    seen.try_reserve(scene.object_track_ranges.len())
        .map_err(|error| {
            Error::UnsupportedOperation(format!(
                "the indexed Object Layer could not reserve {} track identities within the shared retained-record ceiling: {error}",
                scene.object_track_ranges.len()
            ))
        })?;
    let identity_bytes =
        indexed_hash_table_bytes::<u32, ()>(seen.capacity(), "Object Layer identity")?;
    let mut retained = indexed_vec_bytes(&out.tracks, "Object Layer tracks")?
        .checked_add(indexed_vec_bytes(&ranges, "Object Layer range order")?)
        .and_then(|bytes| bytes.checked_add(identity_bytes))
        .ok_or_else(|| {
            Error::UnsupportedOperation("Object Layer collection bytes overflow".into())
        })?;
    if retained > retained_limit {
        return Err(Error::UnsupportedOperation(format!(
            "the indexed Object Layer track vector retains {retained} bytes, past the {retained_limit} byte retained-record ceiling"
        )));
    }
    for (offset, length) in &scene.object_table_ranges {
        if out.table.is_some() {
            return Err(Error::Malformed(format!(
                "a second ObjectTable record appears at byte {offset}; a file may carry \
                 exactly one scene-wide object table"
            )));
        }
        let remaining = retained_limit - retained;
        let table = read_capped_record_with_limit(
            source,
            *offset,
            *length,
            op::OBJECT_TABLE,
            "Object Table record",
            (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
            |bytes, _| {
                let working = crate::stream_reader::object_table_prefix_parse_working_bytes(bytes)?;
                if working > remaining {
                    return Err(Error::UnsupportedOperation(format!(
                        "the Object Table record at byte {offset} needs {working} bytes for its live prefix and parsed rows, past the {remaining} bytes remaining in the shared retained-record budget"
                    )));
                }
                rec::ObjectTable::parse(bytes)
            },
        )?;
        let bytes = object_table_resident_bytes(&table)?;
        if bytes > remaining {
            return Err(Error::UnsupportedOperation(format!(
                "the Object Table record at byte {offset} retains {bytes} bytes, past the {remaining} bytes remaining in the shared retained-record budget"
            )));
        }
        retained = retained.checked_add(bytes).ok_or_else(|| {
            Error::UnsupportedOperation("Object Layer retained bytes overflow".into())
        })?;
        out.table = Some(table);
    }
    // File order, not id order. The ranges are keyed by object id so a duplicate track can
    // be refused by lookup, but iterating that map would emit the layer sorted by id while
    // the streamed reader and `canonical.py` emit it in the order the records appear. A
    // file is free to write track 7 before track 3, and then the two paths would summarize
    // the same layer differently — a canonical form that disagrees with itself depending on
    // which reader produced it.
    for range in ranges {
        // The same ceiling the table branch above applies. A track is front matter, so a
        // crafted record_length must not size an allocation before anything has looked at
        // the bytes — and the parse that would reject it only runs after the read.
        // Section 5.15.7: a zero-sample track "has no pose and is read as absent".
        let remaining = retained_limit - retained;
        let track = read_capped_record_with_limit(
            source,
            range.record_offset,
            range.record_length,
            op::OBJECT_TRACK,
            "Object Track record",
            (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
            |bytes, _| {
                let projected = object_track_prefix_resident_bound(bytes)?;
                let peak = bytes.len().checked_add(projected).ok_or_else(|| {
                    Error::UnsupportedOperation(
                        "Object Track parse working-set bytes overflow".into(),
                    )
                })?;
                if peak > remaining {
                    return Err(Error::UnsupportedOperation(format!(
                        "the Object Track record at byte {} needs {peak} bytes for its live prefix and parsed samples, past the {remaining} bytes remaining in the shared retained-record budget",
                        range.record_offset
                    )));
                }
                rec::ObjectTrack::parse(bytes)
            },
        )?;
        if track.sample_count() > 0 {
            let bytes = object_track_resident_bytes(&track)?;
            if bytes > remaining {
                return Err(Error::UnsupportedOperation(format!(
                    "the Object Track record at byte {} retains {bytes} bytes, past the {remaining} bytes remaining in the shared retained-record budget",
                    range.record_offset
                )));
            }
            retained = retained.checked_add(bytes).ok_or_else(|| {
                Error::UnsupportedOperation("Object Layer retained bytes overflow".into())
            })?;
            if !seen.insert(track.object_id) {
                return Err(Error::Malformed(format!(
                    "two ObjectTrack records move object {}; a gaussian has one object and cannot be transported by two poses (section 5.15.6)",
                    track.object_id
                )));
            }
            out.tracks.push(track);
        }
    }
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
    let scene_bytes = indexed_scene_resident_bytes(scene)?;
    let remaining = crate::stream_reader::MAX_DECODED_SCENE_BYTES
        .checked_sub(scene_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation(format!(
                "the indexed scene retains {scene_bytes} bytes, leaving no shared budget for an Audio Source descriptor"
            ))
        })?;
    read_audio_source_descriptor_with_limit(source, scene, entry, remaining)
}

pub(crate) fn read_audio_source_descriptor_with_limit<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
    entry: &IndexedAudioSource,
    remaining: usize,
) -> Result<AudioSource> {
    let Some((offset, length)) = entry.descriptor_range else {
        let start_sec = entry.legacy_start_sec;
        let codec_bytes = entry.legacy_codec.as_ref().map_or(0, |codec| codec.len());
        if codec_bytes > remaining {
            return Err(Error::UnsupportedOperation(format!(
                "the legacy Audio Source descriptor needs {codec_bytes} codec bytes, past the {remaining} bytes remaining in the shared scene budget"
            )));
        }
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
    let content_length = length.checked_sub(RECORD_HEADER_SIZE as u64).ok_or_else(|| {
        Error::Truncated(format!(
            "the Audio Source record at byte {offset} is only {length} bytes; its record header needs {RECORD_HEADER_SIZE}"
        ))
    })?;
    let (descriptor, prefix_capacity) = read_capped_record_accounted_with_limit(
        source,
        offset,
        length,
        op::AUDIO_SOURCE,
        "Audio Source record",
        (remaining as u64).min(MAX_FRONT_MATTER_BYTES),
        |bytes, complete| {
            check_audio_source_prefix_parse_budget(bytes, content_length, remaining, offset)?;
            rec::AudioSource::parse_prefix(bytes, complete, content_length)
        },
    )?;
    let descriptor_bytes = audio_source_descriptor_resident_bytes(&descriptor)?;
    let peak = prefix_capacity
        .checked_add(descriptor_bytes)
        .ok_or_else(|| {
            Error::UnsupportedOperation("lazy Audio Source parse working-set bytes overflow".into())
        })?;
    if peak > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Audio Source record at byte {offset} retains {peak} prefix and descriptor bytes, past the {remaining} bytes remaining beside the indexed scene and its caches"
        )));
    }
    if descriptor.source_id != entry.source_id {
        return Err(Error::Malformed(format!(
            "Audio Source record at byte {offset} retained for id {} contains id {}",
            entry.source_id, descriptor.source_id,
        )));
    }
    if descriptor.data_length != entry.data_length {
        return Err(Error::Malformed(format!(
            "Audio Source record at byte {offset} for id {} declares {} bytes, its Audio Data record declares {}",
            entry.source_id, descriptor.data_length, entry.data_length,
        )));
    }
    for (index, keyframe) in descriptor.keyframes.iter().enumerate() {
        if keyframe.time < 0.0 || keyframe.time > scene.header.duration_sec {
            return Err(Error::Malformed(format!(
                "Audio Source record at byte {offset} for id {} has keyframe {index} time {} outside [0, {}]",
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
        keyframes: descriptor.keyframes,
        interpolation: descriptor.interpolation,
        data: Vec::new(),
    })
}

fn read_capped_record_with_limit<R, T>(
    source: &mut R,
    offset: u64,
    total_length: u64,
    opcode: u8,
    what: &str,
    cap: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<T>
where
    R: Readable + ?Sized,
{
    read_capped_record_accounted_with_limit(source, offset, total_length, opcode, what, cap, parse)
        .map(|(value, _)| value)
}

fn read_capped_record_accounted_with_limit<R, T>(
    source: &mut R,
    offset: u64,
    total_length: u64,
    opcode: u8,
    what: &str,
    cap: u64,
    parse: impl Fn(&[u8], bool) -> Result<T>,
) -> Result<(T, usize)>
where
    R: Readable + ?Sized,
{
    if total_length < RECORD_HEADER_SIZE as u64 {
        return Err(Error::Truncated(format!(
            "the {what} at byte {offset} is only {total_length} bytes; its record header needs {RECORD_HEADER_SIZE}"
        )));
    }
    if cap < RECORD_HEADER_SIZE as u64 {
        return Err(Error::UnsupportedOperation(format!(
            "the {what} at byte {offset} needs {RECORD_HEADER_SIZE} framing bytes, past the {cap} byte indexed-reader prefix ceiling"
        )));
    }
    let head = source.read(offset, RECORD_HEADER_SIZE as u64)?;
    let mut framing = Cursor::new(&head);
    let physical_opcode = framing.u8()?;
    let declared = framing.u64()?;
    if physical_opcode != opcode {
        return Err(Error::Malformed(format!(
            "the {what} range at byte {offset} contains {}; expected {}",
            op::name(physical_opcode),
            op::name(opcode)
        )));
    }
    let framed_total = declared
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| {
            Error::Malformed(format!(
                "the {what} at byte {offset} overflows while framing {declared} content bytes"
            ))
        })?;
    if framed_total != total_length {
        return Err(Error::Malformed(format!(
            "the {what} at byte {offset} frames {framed_total} bytes, but its retained range is {total_length} bytes"
        )));
    }
    let content_offset = offset
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| Error::Malformed(format!("the {what} byte offset overflows")))?;
    drop(head);
    let maximum = declared.min(cap);
    let mut prefix_length = maximum.min(HEAD_PROBE);
    loop {
        let prefix = source.read(content_offset, prefix_length)?;
        let complete = prefix_length == declared;
        rec::preflight_counted_record_length(opcode, &prefix, declared)
            .map_err(|error| error.at_record(what, offset))?;
        match parse(&prefix, complete) {
            Ok(value) => return Ok((value, prefix.capacity())),
            Err(Error::Truncated(_)) if prefix_length < maximum => {
                prefix_length = prefix_length.max(1).saturating_mul(2).min(maximum);
            }
            Err(Error::Truncated(_)) if declared > maximum => {
                return Err(Error::UnsupportedOperation(format!(
                    "the {what} at byte {offset} has required fields beyond the {cap} byte indexed-reader prefix ceiling"
                )));
            }
            Err(error) => return Err(error.at_record(what, offset)),
        }
    }
}

/// Read one Attachment's complete retained content, rather than treating its payload as
/// an extensible front-matter suffix. The returned payload reuses this exact allocation.
fn read_attachment_record<R: Readable + ?Sized>(
    source: &mut R,
    offset: u64,
    total_length: u64,
    remaining: usize,
) -> Result<(rec::Attachment, usize)> {
    if total_length < RECORD_HEADER_SIZE as u64 {
        return Err(Error::Truncated(format!(
            "the Attachment record at byte {offset} is only {total_length} bytes; its record header needs {RECORD_HEADER_SIZE}"
        )));
    }
    if remaining < RECORD_HEADER_SIZE {
        return Err(Error::UnsupportedOperation(format!(
            "the Attachment record at byte {offset} needs {RECORD_HEADER_SIZE} framing bytes, past the {remaining} bytes remaining in the indexed retained-record budget"
        )));
    }
    let head = source.read(offset, RECORD_HEADER_SIZE as u64)?;
    let mut framing = Cursor::new(&head);
    let physical_opcode = framing.u8()?;
    let declared = framing.u64()?;
    if physical_opcode != op::ATTACHMENT {
        return Err(Error::Malformed(format!(
            "the Attachment record range at byte {offset} contains {}; expected {}",
            op::name(physical_opcode),
            op::name(op::ATTACHMENT)
        )));
    }
    let framed_total = declared
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| {
            Error::Malformed(format!(
                "the Attachment record at byte {offset} overflows while framing {declared} content bytes"
            ))
        })?;
    if framed_total != total_length {
        return Err(Error::Malformed(format!(
            "the Attachment record at byte {offset} frames {framed_total} bytes, but its retained range is {total_length} bytes"
        )));
    }
    if declared > remaining as u64 {
        return Err(Error::UnsupportedOperation(format!(
            "the Attachment record at byte {offset} needs {declared} retained content bytes, past the {remaining} bytes remaining in the indexed retained-record budget"
        )));
    }
    let content_offset = offset
        .checked_add(RECORD_HEADER_SIZE as u64)
        .ok_or_else(|| Error::Malformed("the Attachment content byte offset overflows".into()))?;
    drop(head);
    let content = source.read(content_offset, declared)?;
    let retained = content.capacity();
    if retained > remaining {
        return Err(Error::UnsupportedOperation(format!(
            "the Attachment record at byte {offset} retained an allocation of {retained} bytes, past the {remaining} bytes remaining in the indexed retained-record budget"
        )));
    }
    let descriptor_budget = remaining - retained;
    let (attachment, descriptor_bytes) =
        rec::Attachment::into_payload_with_descriptor_budget(content, descriptor_budget)?;
    let total = retained.checked_add(descriptor_bytes).ok_or_else(|| {
        Error::UnsupportedOperation("retained indexed Attachment bytes overflow".into())
    })?;
    Ok((attachment, total))
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
    if declared != available {
        return Err(Error::Malformed(format!(
            "the indexed {} range holds {available} content bytes, but its record framing declares {declared}; an index range must contain exactly one record",
            op::name(expect)
        )));
    }
    Ok(&blob[RECORD_HEADER_SIZE..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::readable::BytesReadable;
    use std::collections::BTreeMap;

    #[derive(Default)]
    struct TrackingReadable {
        bytes: Vec<u8>,
        largest_read: u64,
        reads: usize,
    }

    impl Readable for TrackingReadable {
        fn size(&mut self) -> Result<u64> {
            Ok(self.bytes.len() as u64)
        }

        fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
            self.reads += 1;
            self.largest_read = self.largest_read.max(length);
            BytesReadable::new(&self.bytes).read(offset, length)
        }
    }

    struct NeverRead;

    impl Readable for NeverRead {
        fn size(&mut self) -> Result<u64> {
            Ok(u64::MAX)
        }

        fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
            panic!("resource ceiling must be checked before reading [{offset}, +{length})")
        }
    }

    fn basic_header(flags: u8) -> rec::Header {
        rec::Header {
            duration_sec: 1.0,
            gaussian_count: 0,
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            aabb: vec![0.0; 6],
            sh_degree: 0,
            flags,
            ..Default::default()
        }
    }

    fn basic_quantization() -> rec::Quantization {
        rec::Quantization {
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
            bounds: BTreeMap::new(),
            sh_bit_depths: Vec::new(),
        }
    }

    fn empty_indexed_file() -> Vec<u8> {
        indexed_file_with_header_trailer(&[])
    }

    fn indexed_file_with_header_trailer(trailer: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MAGIC);
        bytes.extend_from_slice(&basic_header(0).encode(trailer));
        bytes.extend_from_slice(&basic_quantization().encode(&[]));
        bytes.extend_from_slice(
            &rec::WindowTable {
                windows: vec![(0.0, 1.0)],
            }
            .encode(),
        );
        bytes.extend_from_slice(&rec::Footer::default().encode());
        bytes.extend_from_slice(&MAGIC);
        bytes
    }

    fn hostile_chunk(
        count: u32,
        compression: &str,
        uncompressed_size: u64,
        streams: &[u8],
    ) -> Vec<u8> {
        use crate::serialization::{put_blob, put_f64, put_record, put_string, put_u32, put_u64};

        let mut content = Vec::new();
        put_f64(&mut content, 0.0);
        put_f64(&mut content, 1.0);
        put_u32(&mut content, 0);
        put_u32(&mut content, count);
        put_string(&mut content, compression);
        put_u64(&mut content, uncompressed_size);
        put_blob(&mut content, streams);
        let mut record = Vec::new();
        put_record(&mut record, op::CHUNK, &content);
        record
    }

    fn entry_for_chunk(chunk: &[u8]) -> rec::ChunkIndexEntry {
        rec::ChunkIndexEntry {
            t0: 0.0,
            t1: 1.0,
            chunk_offset: 0,
            chunk_length: chunk.len() as u64,
            ..Default::default()
        }
    }

    #[test]
    fn production_indexed_open_does_not_fetch_a_large_header_suffix() {
        let suffix = vec![0x5a; HEAD_PROBE as usize * 128];
        let mut source = TrackingReadable {
            bytes: indexed_file_with_header_trailer(&suffix),
            ..Default::default()
        };

        let scene = open_indexed(&mut source).expect("large legal suffix");
        assert_eq!(scene.header.temporal_model, "gaussian-birth");
        assert!(
            source.largest_read <= HEAD_PROBE,
            "the suffix must be stepped over by framing; largest range was {} bytes",
            source.largest_read
        );
    }

    #[test]
    fn an_extensible_front_record_skips_the_suffix_by_framing() {
        let encoded = basic_header(0).encode(&[]);
        let known = &encoded[RECORD_HEADER_SIZE..];
        let suffix = HEAD_PROBE as usize * 4;
        let mut bytes = vec![0; RECORD_HEADER_SIZE + known.len() + suffix];
        bytes[RECORD_HEADER_SIZE..RECORD_HEADER_SIZE + known.len()].copy_from_slice(known);
        let mut source = TrackingReadable {
            bytes,
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::HEADER,
            offset: 0,
            content_length: (known.len() + suffix) as u64,
        };

        let parsed = parse_front_record_with_limit(
            &mut front,
            &record,
            "Header record",
            known.len() as u64,
            |bytes, _| rec::Header::parse(bytes),
        )
        .expect("the known prefix is complete");
        assert_eq!(parsed.temporal_model, "gaussian-birth");
        assert!(
            source.largest_read <= HEAD_PROBE,
            "the {}-byte suffix was stepped over, not fetched; largest read was {}",
            suffix,
            source.largest_read
        );
    }

    #[test]
    fn required_front_fields_past_the_cap_are_incomplete_not_malformed() {
        let encoded = rec::Header {
            profile: "x".repeat(256),
            ..basic_header(0)
        }
        .encode(&[]);
        let mut source = TrackingReadable {
            bytes: encoded.clone(),
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::HEADER,
            offset: 0,
            content_length: (encoded.len() - RECORD_HEADER_SIZE) as u64,
        };
        let error =
            parse_front_record_with_limit(&mut front, &record, "Header record", 64, |bytes, _| {
                rec::Header::parse(bytes)
            })
            .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 0"), "{error}");
        assert!(error.to_string().contains("64 byte"), "{error}");
    }

    #[test]
    fn impossible_counted_prefix_is_malformed_before_the_indexed_cap() {
        let mut encoded = Vec::new();
        let mut body = u32::MAX.to_le_bytes().to_vec();
        body.resize(16, 0);
        crate::serialization::put_record(&mut encoded, op::WINDOW_TABLE, &body);
        let mut source = TrackingReadable {
            bytes: encoded,
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::WINDOW_TABLE,
            offset: 0,
            content_length: body.len() as u64,
        };

        let error = parse_front_record_with_limit(
            &mut front,
            &record,
            "Window Table record",
            4,
            |bytes, _| rec::WindowTable::parse(bytes),
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("4294967295 rows"), "{error}");
        assert!(error.to_string().contains("record declares 16"), "{error}");
    }

    #[test]
    fn impossible_lazy_counted_prefix_is_malformed_before_its_cap() {
        let mut body = vec![0; 64];
        body[56..60].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut encoded = Vec::new();
        crate::serialization::put_record(&mut encoded, op::CAMERA, &body);
        let mut source = TrackingReadable {
            bytes: encoded.clone(),
            ..Default::default()
        };

        let error = read_capped_record_with_limit(
            &mut source,
            0,
            encoded.len() as u64,
            op::CAMERA,
            "Camera record",
            60,
            |bytes, _| rec::Camera::parse(bytes),
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("4294967295 rows"), "{error}");
        assert!(error.to_string().contains("record declares 64"), "{error}");
    }

    #[test]
    fn indexed_front_values_share_the_prefix_peak_envelope() {
        let total = replace_indexed_front_bytes(65, 20, 25, 10, "Header", 41, 100)
            .expect("the parse peak reaches but does not cross the limit");
        assert_eq!(total, 70, "the replaced value is removed after parsing");

        let error = replace_indexed_front_bytes(65, 20, 25, 11, "Header", 41, 100).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("101 bytes"), "{error}");
    }

    #[test]
    fn direct_front_reads_report_their_actual_prefix_capacity() {
        let encoded = rec::Header {
            profile: "p".repeat(HEAD_PROBE as usize * 2),
            ..basic_header(0)
        }
        .encode(&[]);
        let mut source = TrackingReadable {
            bytes: encoded.clone(),
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = front.record_at(0).expect("Header framing");
        let (_, prefix_capacity) =
            parse_front_record_accounted(&mut front, &record, "Header record", |bytes, _| {
                rec::Header::parse(bytes)
            })
            .expect("large required Header prefix");

        assert!(prefix_capacity > HEAD_PROBE as usize);
        assert!(
            prefix_capacity > front.window.capacity(),
            "the direct allocation, not the stale probe window, is reported"
        );
    }

    #[test]
    fn indexed_summary_read_shares_the_front_and_range_budget() {
        let limit = 100usize;
        assert_eq!(
            indexed_summary_allowance(73, 41, 27, limit)
                .expect("the exact remaining envelope is legal"),
            27
        );
        let error = indexed_summary_allowance(73, 41, 28, limit).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 41"), "{error}");
        assert!(error.to_string().contains("73 retained"), "{error}");
    }

    #[test]
    fn indexed_metadata_records_share_one_retained_budget() {
        let metadata = rec::Metadata {
            name: "capture".into(),
            entries: BTreeMap::from([("note".into(), "x".repeat(1024))]),
        };
        let first = metadata.encode();
        let mut bytes = first.clone();
        bytes.extend_from_slice(&first);
        let scene = IndexedScene {
            metadata_ranges: vec![
                (0, first.len() as u64),
                (first.len() as u64, first.len() as u64),
            ],
            ..Default::default()
        };
        let content = &first[RECORD_HEADER_SIZE..];
        let resident = metadata_prefix_resident_bound(content).expect("Metadata bound");
        let outer =
            planned_exact_vec_bytes::<rec::Metadata>(2, "Metadata").expect("outer result backing");
        let limit = outer + content.len() + resident;
        let mut source = TrackingReadable {
            bytes,
            ..Default::default()
        };

        let error = read_metadata_with_limit(&mut source, &scene, limit).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("Metadata record"), "{error}");
        assert!(
            error.to_string().contains("shared retained-record budget"),
            "{error}"
        );
    }

    #[test]
    fn indexed_provenance_records_share_one_retained_budget() {
        let trajectory = rec::RigTrajectory {
            name: "rig".into(),
            interpolation: crate::records::TRAJECTORY_LINEAR,
            times: vec![0.0],
            rotations: vec![[0.0, 0.0, 0.0, 1.0]],
            translations: vec![[0.0, 0.0, 0.0]],
        };
        let first = trajectory.encode(&[]);
        let mut bytes = first.clone();
        bytes.extend_from_slice(&first);
        let scene = IndexedScene {
            provenance_ranges: vec![
                (op::RIG_TRAJECTORY, 0, first.len() as u64),
                (op::RIG_TRAJECTORY, first.len() as u64, first.len() as u64),
            ],
            ..Default::default()
        };
        let resident = rig_trajectory_resident_bytes(&trajectory).expect("resident trajectory");
        let outer = 2 * std::mem::size_of::<rec::RigTrajectory>();
        let content = first.len() - RECORD_HEADER_SIZE;
        let limit = outer + resident + content + resident - 1;
        let mut source = TrackingReadable {
            bytes,
            ..Default::default()
        };

        let error = read_provenance_with_limit(&mut source, &scene, limit).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("shared retained-record budget"),
            "{error}"
        );
        assert!(error.to_string().contains("Rig Trajectory"), "{error}");
    }

    #[test]
    fn audio_keyframes_past_a_prefix_cap_are_incomplete_not_malformed() {
        let descriptor = rec::AudioSource {
            source_id: 9,
            codec: "wav".into(),
            channel_layout: "mono".into(),
            duration_sec: 1.0,
            rotation: [1.0, 0.0, 0.0, 0.0],
            keyframes: vec![
                rec::AudioSourceKeyframe {
                    time: 0.0,
                    rotation: [1.0, 0.0, 0.0, 0.0],
                    ..Default::default()
                },
                rec::AudioSourceKeyframe {
                    time: 1.0,
                    rotation: [1.0, 0.0, 0.0, 0.0],
                    ..Default::default()
                },
            ],
            interpolation: "linear".into(),
            ..Default::default()
        }
        .encode();
        let mut source = TrackingReadable {
            bytes: descriptor.clone(),
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::AUDIO_SOURCE,
            offset: 0,
            content_length: (descriptor.len() - RECORD_HEADER_SIZE) as u64,
        };
        // The count is visible, but neither keyframe nor the trailing interpolation is.
        let cap = 4 + 4 + (4 + 3) + (4 + 4) + 4 * 8 + 1 + 3 * 8 + 4 * 8 + 4;
        let error = parse_front_record_with_limit(
            &mut front,
            &record,
            "Audio Source record",
            cap,
            |bytes, complete| {
                rec::AudioSource::parse_prefix(bytes, complete, record.content_length)
            },
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 0"), "{error}");

        let mut impossible = descriptor;
        impossible[RECORD_HEADER_SIZE + cap as usize - 4..RECORD_HEADER_SIZE + cap as usize]
            .copy_from_slice(&100u32.to_le_bytes());
        let mut source = TrackingReadable {
            bytes: impossible.clone(),
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::AUDIO_SOURCE,
            offset: 0,
            content_length: (impossible.len() - RECORD_HEADER_SIZE) as u64,
        };
        let error = parse_front_record_with_limit(
            &mut front,
            &record,
            "Audio Source record",
            cap,
            |bytes, complete| {
                rec::AudioSource::parse_prefix(bytes, complete, record.content_length)
            },
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("record declares"), "{error}");
    }

    #[test]
    fn malformed_front_fields_stay_malformed_despite_an_oversized_suffix() {
        let encoded = rec::Header {
            profile: "\u{80}".into(),
            ..basic_header(0)
        }
        .encode(&[]);
        let known_length = encoded.len() - RECORD_HEADER_SIZE;
        let mut bytes = encoded;
        // Break the profile's first UTF-8 byte, then make the record longer than the
        // artificial prefix cap. The malformed field is wholly inside the bytes read.
        bytes[RECORD_HEADER_SIZE + 4] = 0xff;
        bytes.resize(bytes.len() + 128, 0);
        let content_length = bytes.len() - RECORD_HEADER_SIZE;
        bytes[1..RECORD_HEADER_SIZE].copy_from_slice(&(content_length as u64).to_le_bytes());
        let mut source = TrackingReadable {
            bytes,
            ..Default::default()
        };
        let size = source.bytes.len() as u64;
        let mut front = FrontMatter::new(&mut source, size);
        let record = FrontRecord {
            opcode: op::HEADER,
            offset: 0,
            content_length: content_length as u64,
        };

        let error = parse_front_record_with_limit(
            &mut front,
            &record,
            "Header record",
            known_length as u64,
            |bytes, _| rec::Header::parse(bytes),
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("UTF-8"), "{error}");
    }

    #[test]
    fn oversized_indexed_state_ranges_are_refused_before_read() {
        let entry = rec::ChunkIndexEntry {
            chunk_offset: 91,
            chunk_length: MAX_INDEXED_STATE_RECORD_BYTES + 1,
            ..Default::default()
        };
        let error = read_chunk(&mut NeverRead, &IndexedScene::default(), &entry, 3).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 91"), "{error}");
        assert!(
            error
                .to_string()
                .contains(&(MAX_INDEXED_STATE_RECORD_BYTES + 1).to_string()),
            "{error}"
        );
    }

    #[test]
    fn duplicate_filtered_sh_band_labels_are_rejected_before_read() {
        let entry = rec::ChunkIndexEntry {
            chunk_offset: 91,
            chunk_length: 1,
            bands: vec![(3, 100, 1), (3, 200, 1)],
            ..Default::default()
        };

        let error = read_chunk(&mut NeverRead, &IndexedScene::default(), &entry, 0).unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(
            error.to_string().contains("band 3 more than once"),
            "{error}"
        );
        assert!(error.to_string().contains("byte 91"), "{error}");
    }

    #[test]
    fn oversized_sh_ranges_are_refused_before_their_read() {
        let chunk = rec::encode_chunk(0.0, 1.0, 0, 0, &[]);
        let mut source = TrackingReadable {
            bytes: chunk.clone(),
            ..Default::default()
        };
        let mut entry = entry_for_chunk(&chunk);
        entry
            .bands
            .push((1, chunk.len() as u64, MAX_INDEXED_STATE_RECORD_BYTES + 1));

        let error = read_chunk(&mut source, &IndexedScene::default(), &entry, 3).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("SH Band Stream"), "{error}");
        assert_eq!(source.reads, 1, "only the bounded Chunk range was fetched");
    }

    #[test]
    fn sh_ranges_are_preflighted_against_resident_state_before_read() {
        let chunk = rec::encode_chunk(0.0, 1.0, 0, 0, &[]);
        let mut source = TrackingReadable {
            bytes: chunk.clone(),
            ..Default::default()
        };
        let mut entry = entry_for_chunk(&chunk);
        entry
            .bands
            .push((1, chunk.len() as u64, MAX_INDEXED_STATE_RECORD_BYTES));

        let error = read_chunk_with_limit(
            &mut source,
            &IndexedScene::default(),
            &entry,
            3,
            chunk.len(),
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("beside"), "{error}");
        assert_eq!(source.reads, 1, "the SH range was refused before fetch");
    }

    #[test]
    fn indexed_band_labels_are_validated_before_the_cutoff_and_reads() {
        let mut source = TrackingReadable::default();
        let mut entry = rec::ChunkIndexEntry::default();
        entry.bands.push((4, 0, 0));

        let error =
            read_chunk_with_limit(&mut source, &IndexedScene::default(), &entry, 3, 1).unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("band 4"), "{error}");
        assert_eq!(
            source.reads, 0,
            "an invalid index label needs no range read"
        );
    }

    #[test]
    fn indexed_attachments_read_complete_payloads_into_one_retained_buffer() {
        let encoded = rec::Attachment {
            name: "preview".into(),
            media_type: "image/avif".into(),
            data: vec![0x5a; 80 * 1024],
        }
        .encode();
        let mut source = TrackingReadable {
            bytes: encoded.clone(),
            ..Default::default()
        };
        let scene = IndexedScene {
            attachment_ranges: vec![(0, encoded.len() as u64)],
            ..Default::default()
        };

        let attachments = read_attachments(&mut source, &scene).expect("one Attachment");
        assert_eq!(attachments[0].data.len(), 80 * 1024);
        assert_eq!(source.reads, 2, "one header read and one content read");
        assert_eq!(
            source.largest_read,
            (encoded.len() - RECORD_HEADER_SIZE) as u64
        );
    }

    #[test]
    fn indexed_attachment_budget_is_checked_before_payload_read() {
        let encoded = rec::Attachment {
            name: "preview".into(),
            media_type: "image/avif".into(),
            data: vec![0x5a; 1024],
        }
        .encode();
        let content_length = encoded.len() - RECORD_HEADER_SIZE;
        let mut source = TrackingReadable {
            bytes: encoded.clone(),
            ..Default::default()
        };

        let error =
            read_attachment_record(&mut source, 0, encoded.len() as u64, content_length - 1)
                .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert_eq!(source.reads, 1, "only the fixed record header was fetched");
    }

    #[test]
    fn indexed_attachment_result_backing_is_preflighted_before_read() {
        let mut source = TrackingReadable::default();
        let scene = IndexedScene {
            attachment_ranges: vec![(0, 0)],
            ..Default::default()
        };
        let error = read_attachments_with_limit(
            &mut source,
            &scene,
            std::mem::size_of::<rec::Attachment>() - 1,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("result vector"), "{error}");
        assert_eq!(source.reads, 0, "the result allocation is refused first");
    }

    #[test]
    fn chunk_uncompressed_size_is_capped_before_decompression() {
        let chunk = hostile_chunk(
            0,
            "deflate",
            crate::serialization::MAX_STREAM_BYTES + 1,
            &[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01],
        );
        let entry = entry_for_chunk(&chunk);
        let error = read_chunk(
            &mut BytesReadable::new(&chunk),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("uncompressed"), "{error}");
        assert!(
            error
                .to_string()
                .contains(&(crate::serialization::MAX_STREAM_BYTES + 1).to_string()),
            "{error}"
        );
    }

    #[test]
    fn tiny_constant_streams_cannot_amplify_a_hostile_chunk_count() {
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            let values = vec![0; channel_count * 2];
            let mut encoded = crate::stream::encode_stream(
                attribute,
                &values,
                channel_count,
                crate::codec::DEFLATE,
                6,
                true,
            )
            .expect("constant stream");
            assert_eq!(encoded[2], crate::stream::MODE_CONST);
            encoded[5..9].copy_from_slice(&u32::MAX.to_le_bytes());
            streams.extend_from_slice(&encoded);
        }
        let chunk = hostile_chunk(u32::MAX, "", streams.len() as u64, &streams);
        let entry = entry_for_chunk(&chunk);
        let scene = IndexedScene {
            header: basic_header(0),
            quantization: basic_quantization(),
            windows: vec![(0.0, 1.0)],
            ..Default::default()
        };

        let error = read_chunk(&mut BytesReadable::new(&chunk), &scene, &entry, 3).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains(&u32::MAX.to_string()), "{error}");
        assert!(
            error.to_string().contains("resident state bytes"),
            "{error}"
        );
    }

    #[test]
    fn hostile_count_does_not_hide_a_structurally_malformed_chunk() {
        let chunk = hostile_chunk(u32::MAX, "", 0, &[]);
        let entry = entry_for_chunk(&chunk);

        let error = read_chunk(
            &mut BytesReadable::new(&chunk),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(error.to_string().contains("missing required"), "{error}");
    }

    #[test]
    fn indexed_chunk_output_is_preflighted_against_the_remaining_scene_budget() {
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            streams.extend_from_slice(
                &crate::stream::encode_stream(
                    attribute,
                    &vec![0; channel_count],
                    channel_count,
                    crate::codec::DEFLATE,
                    6,
                    true,
                )
                .expect("one-row constant stream"),
            );
        }
        let chunk = hostile_chunk(1, "", streams.len() as u64, &streams);
        let entry = entry_for_chunk(&chunk);
        let scene = IndexedScene {
            header: basic_header(0),
            quantization: basic_quantization(),
            windows: vec![(0.0, 1.0)],
            ..Default::default()
        };

        let error = read_chunk_with_limit(
            &mut BytesReadable::new(&chunk),
            &scene,
            &entry,
            3,
            // One required row occupies 80 bytes; stop one byte short.
            79,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("remaining"), "{error}");
    }

    #[test]
    fn indexed_whole_chunk_compression_charges_encoded_and_unpacked_buffers() {
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            streams.extend_from_slice(
                &crate::stream::encode_stream(
                    attribute,
                    &vec![0; channel_count],
                    channel_count,
                    crate::codec::DEFLATE,
                    6,
                    false,
                )
                .expect("one-row constant stream"),
            );
        }
        let compressed = crate::codec::compress(&streams, crate::codec::DEFLATE, 6)
            .expect("whole-Chunk compression");
        let chunk = hostile_chunk(1, "deflate", streams.len() as u64, &compressed);
        let entry = entry_for_chunk(&chunk);
        let scene = IndexedScene {
            header: basic_header(0),
            quantization: basic_quantization(),
            windows: vec![(0.0, 1.0)],
            ..Default::default()
        };

        let error = read_chunk_with_limit(
            &mut BytesReadable::new(&chunk),
            &scene,
            &entry,
            0,
            chunk.len() + streams.len() - 1,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("compressed Chunk"), "{error}");
        assert!(error.to_string().contains("bytes remaining"), "{error}");
    }

    #[test]
    fn indexed_sh_symbol_expansion_uses_the_remaining_scene_budget() {
        const COUNT: usize = 32;
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            streams.extend_from_slice(
                &crate::stream::encode_stream(
                    attribute,
                    &vec![0; channel_count * COUNT],
                    channel_count,
                    crate::codec::DEFLATE,
                    6,
                    false,
                )
                .expect("constant required stream"),
            );
        }
        let chunk = hostile_chunk(COUNT as u32, "", streams.len() as u64, &streams);
        let sh_values: Vec<i64> = (0..(9 * COUNT) as i64).collect();
        let mut sh_content = vec![1];
        sh_content.extend_from_slice(
            &crate::stream::encode_stream(
                op::SH_BAND_STREAM,
                &sh_values,
                9,
                crate::codec::DEFLATE,
                6,
                false,
            )
            .expect("non-constant SH stream"),
        );
        let mut sh = Vec::new();
        crate::serialization::put_record(&mut sh, op::SH_BAND_STREAM, &sh_content);
        let mut bytes = chunk.clone();
        let sh_offset = bytes.len() as u64;
        bytes.extend_from_slice(&sh);
        let mut entry = entry_for_chunk(&chunk);
        entry.bands.push((1, sh_offset, sh.len() as u64));
        let scene = IndexedScene {
            header: rec::Header {
                sh_degree: 1,
                ..basic_header(0)
            },
            quantization: basic_quantization(),
            windows: vec![(0.0, 1.0)],
            ..Default::default()
        };

        // Charge the raw Chunk range beside its 168 bytes of constant symbols and the
        // 80-byte output row. Once that input is dropped, the larger non-constant SH
        // symbols still exceed what remains beside the resident gaussian rows and their
        // own encoded range.
        let chunk_peak = chunk.len() + 168 + COUNT * 80;
        let error = read_chunk_with_limit(
            &mut BytesReadable::new(&bytes),
            &scene,
            &entry,
            1,
            chunk_peak,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error
                .to_string()
                .contains(&format!("{} raw bytes", 9 * COUNT * 2)),
            "{error}"
        );
        assert!(
            error
                .to_string()
                .contains(&format!("{} resident decoded-symbol", 9 * COUNT * 8)),
            "{error}"
        );
        assert!(
            error.to_string().contains("remaining decode budget"),
            "{error}"
        );
    }

    #[test]
    fn indexed_sh_channel_mismatch_precedes_resident_budgeting() {
        const COUNT: usize = 32;
        let channels = [3usize, 3, 1, 3, 3, 1, 3, 1, 1, 1, 1];
        let mut streams = Vec::new();
        for (&attribute, &channel_count) in op::REQUIRED_ATTRIBUTES.iter().zip(&channels) {
            streams.extend_from_slice(
                &crate::stream::encode_stream(
                    attribute,
                    &vec![0; channel_count * COUNT],
                    channel_count,
                    crate::codec::DEFLATE,
                    6,
                    false,
                )
                .expect("constant required stream"),
            );
        }
        let chunk = hostile_chunk(COUNT as u32, "", streams.len() as u64, &streams);
        let sh_values: Vec<i64> = (0..(255 * COUNT)).map(|value| value as i64).collect();
        let mut sh_content = vec![1];
        sh_content.extend_from_slice(
            &crate::stream::encode_stream(
                op::SH_BAND_STREAM,
                &sh_values,
                255,
                crate::codec::DEFLATE,
                6,
                false,
            )
            .expect("hostile-channel SH stream"),
        );
        let mut sh = Vec::new();
        crate::serialization::put_record(&mut sh, op::SH_BAND_STREAM, &sh_content);
        let mut bytes = chunk.clone();
        let sh_offset = bytes.len() as u64;
        bytes.extend_from_slice(&sh);
        let mut entry = entry_for_chunk(&chunk);
        entry.bands.push((1, sh_offset, sh.len() as u64));
        let scene = IndexedScene {
            header: rec::Header {
                sh_degree: 1,
                ..basic_header(0)
            },
            quantization: basic_quantization(),
            windows: vec![(0.0, 1.0)],
            ..Default::default()
        };

        // The input buffers and decoded rows leave too little room for 255 channels, but
        // band 1 structurally defines nine channels and that defect still wins first.
        let chunk_peak = chunk.len() + 168 + COUNT * 80;
        let error = read_chunk_with_limit(
            &mut BytesReadable::new(&bytes),
            &scene,
            &entry,
            1,
            chunk_peak,
        )
        .unwrap_err();
        assert!(matches!(error, Error::Malformed(_)), "{error}");
        assert!(
            error.to_string().contains("declares 255 channels"),
            "{error}"
        );
        assert!(error.to_string().contains("format defines 9"), "{error}");
    }

    #[test]
    fn indexed_chunk_and_sh_ranges_must_frame_exactly_one_record() {
        let chunk = rec::encode_chunk(0.0, 1.0, 0, 0, &[]);
        let mut overlong_chunk = chunk.clone();
        overlong_chunk.push(0xaa);
        let entry = entry_for_chunk(&overlong_chunk);
        let chunk_error = read_chunk(
            &mut BytesReadable::new(&overlong_chunk),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(chunk_error, Error::Malformed(_)), "{chunk_error}");
        assert!(
            chunk_error.to_string().contains("exactly one record"),
            "{chunk_error}"
        );

        let short_chunk = chunk[..chunk.len() - 1].to_vec();
        let entry = entry_for_chunk(&short_chunk);
        let chunk_error = read_chunk(
            &mut BytesReadable::new(&short_chunk),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(chunk_error, Error::Malformed(_)), "{chunk_error}");
        assert!(
            chunk_error.to_string().contains("exactly one record"),
            "{chunk_error}"
        );

        let mut sh_content = vec![1];
        sh_content.extend_from_slice(
            &crate::stream::encode_stream(
                op::SH_BAND_STREAM,
                &[],
                9,
                crate::codec::DEFLATE,
                6,
                false,
            )
            .expect("empty SH stream"),
        );
        let mut sh = Vec::new();
        crate::serialization::put_record(&mut sh, op::SH_BAND_STREAM, &sh_content);
        sh.push(0xbb);
        let mut bytes = chunk.clone();
        let sh_offset = bytes.len() as u64;
        bytes.extend_from_slice(&sh);
        let mut entry = entry_for_chunk(&chunk);
        entry.bands.push((1, sh_offset, sh.len() as u64));
        let sh_error = read_chunk(
            &mut BytesReadable::new(&bytes),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(sh_error, Error::Malformed(_)), "{sh_error}");
        assert!(
            sh_error.to_string().contains("exactly one record"),
            "{sh_error}"
        );

        let short_sh = sh[..sh.len() - 2].to_vec();
        let mut bytes = chunk.clone();
        let sh_offset = bytes.len() as u64;
        bytes.extend_from_slice(&short_sh);
        let mut entry = entry_for_chunk(&chunk);
        entry.bands.push((1, sh_offset, short_sh.len() as u64));
        let sh_error = read_chunk(
            &mut BytesReadable::new(&bytes),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(sh_error, Error::Malformed(_)), "{sh_error}");
        assert!(
            sh_error.to_string().contains("exactly one record"),
            "{sh_error}"
        );
    }

    #[test]
    fn indexed_open_caps_the_combined_record_collections() {
        let mut bytes = empty_indexed_file();
        let footer_and_magic = rec::Footer::default().encode().len() + MAGIC.len();
        let insert_at = bytes.len() - footer_and_magic;
        let mut records = Vec::with_capacity((MAX_RETAINED_RECORDS + 1) * RECORD_HEADER_SIZE);
        // Header, Quantization and Window Table already consume three slots. The final
        // record below is therefore exactly the first one past the shared ceiling.
        for _ in 0..(MAX_RETAINED_RECORDS - 2) {
            crate::serialization::put_record(&mut records, op::METADATA, &[]);
        }
        bytes.splice(insert_at..insert_at, records);

        let error = open_indexed(&mut BytesReadable::new(&bytes)).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error
                .to_string()
                .contains(&(MAX_RETAINED_RECORDS + 1).to_string()),
            "{error}"
        );
        assert!(error.to_string().contains("byte "), "{error}");
    }

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

    #[test]
    fn audio_source_prefix_is_admitted_with_earlier_front_matter_still_live() {
        let descriptor = rec::AudioSource {
            source_id: 7,
            name: "moving source".into(),
            codec: "opus".into(),
            channel_layout: "mono".into(),
            duration_sec: 1.0,
            gain: 1.0,
            rotation: [0.0, 0.0, 0.0, 1.0],
            keyframes: [0.0, 0.5, 1.0]
                .into_iter()
                .map(|time| rec::AudioSourceKeyframe {
                    time,
                    rotation: [0.0, 0.0, 0.0, 1.0],
                    ..Default::default()
                })
                .collect(),
            interpolation: "linear".into(),
            ..Default::default()
        };
        let encoded = descriptor.encode();
        let prefix = &encoded[RECORD_HEADER_SIZE..];
        let working =
            prefix.len() + audio_source_prefix_resident_bound(prefix, prefix.len() as u64).unwrap();

        check_audio_source_prefix_parse_budget(prefix, prefix.len() as u64, working, 123)
            .expect("the exact remaining descriptor allowance is admitted");
        let error =
            check_audio_source_prefix_parse_budget(prefix, prefix.len() as u64, working - 1, 123)
                .expect_err("one byte already retained by earlier front matter must refuse");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 123"), "{error}");
        assert!(error.to_string().contains("earlier indexed"), "{error}");
    }

    #[test]
    fn lazy_audio_descriptor_uses_the_callers_remaining_scene_allowance() {
        let descriptor = rec::AudioSource {
            source_id: 7,
            name: "moving source".into(),
            codec: "opus".into(),
            channel_layout: "mono".into(),
            duration_sec: 1.0,
            gain: 1.0,
            rotation: [0.0, 0.0, 0.0, 1.0],
            keyframes: [0.0, 0.5, 1.0]
                .into_iter()
                .map(|time| rec::AudioSourceKeyframe {
                    time,
                    rotation: [0.0, 0.0, 0.0, 1.0],
                    ..Default::default()
                })
                .collect(),
            interpolation: "linear".into(),
            ..Default::default()
        };
        let encoded = descriptor.encode();
        let content = &encoded[RECORD_HEADER_SIZE..];
        let peak = content.len()
            + audio_source_prefix_resident_bound(content, content.len() as u64).unwrap();
        let scene = IndexedScene {
            header: rec::Header {
                duration_sec: 1.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let entry = IndexedAudioSource {
            source_id: 7,
            descriptor_range: Some((0, encoded.len() as u64)),
            ..Default::default()
        };

        read_audio_source_descriptor_with_limit(
            &mut BytesReadable::new(&encoded),
            &scene,
            &entry,
            peak,
        )
        .expect("the exact lazy descriptor allowance is admitted");
        let error = read_audio_source_descriptor_with_limit(
            &mut BytesReadable::new(&encoded),
            &scene,
            &entry,
            peak - 1,
        )
        .expect_err("one byte retained by other SceneReader caches must refuse");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("Audio Source"), "{error}");
    }

    #[test]
    fn indexed_object_tracks_share_one_aggregate_result_budget() {
        let track = |object_id| rec::ObjectTrack {
            object_id,
            interpolation: rec::TRAJECTORY_LINEAR,
            times: vec![0.0],
            rotations: vec![[0.0, 0.0, 0.0, 1.0]],
            translations: vec![[0.0; 3]],
        };
        let first = track(1).encode(&[]).unwrap();
        let second = track(2).encode(&[]).unwrap();
        let mut bytes = first.clone();
        bytes.extend_from_slice(&second);
        let mut scene = IndexedScene::default();
        scene.object_track_ranges.insert(
            1,
            ObjectTrackRange {
                object_id: 1,
                interpolation: rec::TRAJECTORY_LINEAR,
                sample_count: 1,
                record_offset: 0,
                record_length: first.len() as u64,
                content_offset: RECORD_HEADER_SIZE as u64,
            },
        );
        scene.object_track_ranges.insert(
            2,
            ObjectTrackRange {
                object_id: 2,
                interpolation: rec::TRAJECTORY_LINEAR,
                sample_count: 1,
                record_offset: first.len() as u64,
                record_length: second.len() as u64,
                content_offset: first.len() as u64 + RECORD_HEADER_SIZE as u64,
            },
        );
        let mut slots = Vec::<rec::ObjectTrack>::new();
        slots.try_reserve_exact(2).unwrap();
        let outer = indexed_vec_bytes(&slots, "test tracks").unwrap();
        let mut order = Vec::<&ObjectTrackRange>::new();
        order.try_reserve_exact(2).unwrap();
        let order_bytes = indexed_vec_bytes(&order, "test order").unwrap();
        let mut identities = HashSet::<u32>::new();
        identities.try_reserve(2).unwrap();
        let identity_bytes =
            indexed_hash_table_bytes::<u32, ()>(identities.capacity(), "test identities").unwrap();
        let one_track = object_track_resident_bytes(&track(1)).unwrap();
        let second_content = &second[RECORD_HEADER_SIZE..];
        let second_peak =
            second_content.len() + object_track_prefix_resident_bound(second_content).unwrap();
        let limit = outer + order_bytes + identity_bytes + one_track + second_peak - 1;

        let error = read_objects_with_limit(&mut BytesReadable::new(&bytes), &scene, limit)
            .expect_err("the second track must see the first track's retained bytes");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("Object Track"), "{error}");
        assert!(error.to_string().contains("shared retained"), "{error}");
    }

    #[test]
    fn indexed_front_collections_preflight_their_next_growth() {
        let planned = 4 * std::mem::size_of::<(u64, u64)>();
        let mut admitted = Vec::new();
        push_indexed_front_value(
            &mut admitted,
            (1u64, 2u64),
            crate::stream_reader::MAX_DECODED_SCENE_BYTES - planned,
            "Metadata range",
            71,
        )
        .expect("the exact remaining range-vector capacity is admitted");

        let mut refused = Vec::new();
        let error = push_indexed_front_value(
            &mut refused,
            (1u64, 2u64),
            crate::stream_reader::MAX_DECODED_SCENE_BYTES - planned + 1,
            "Metadata range",
            72,
        )
        .expect_err("one byte below the next capacity must refuse before reserve");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("byte 72"), "{error}");

        let node = indexed_btree_node_bytes::<u32, ObjectTrackRange>(1, "Object Track").unwrap();
        check_indexed_front_map_insert::<u32, ObjectTrackRange>(
            crate::stream_reader::MAX_DECODED_SCENE_BYTES - node,
            "Object Track",
            73,
        )
        .expect("the exact map-node allowance is admitted");
        let error = check_indexed_front_map_insert::<u32, ObjectTrackRange>(
            crate::stream_reader::MAX_DECODED_SCENE_BYTES - node + 1,
            "Object Track",
            74,
        )
        .expect_err("one byte below the map node must refuse before insertion");
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
    }

    #[test]
    fn indexed_chunk_unpacking_errors_name_the_record_byte() {
        let chunk = hostile_chunk(
            0,
            "deflate",
            crate::serialization::MAX_STREAM_BYTES + 1,
            &[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01],
        );
        let offset = 17usize;
        let mut bytes = vec![0; offset];
        bytes.extend_from_slice(&chunk);
        let entry = rec::ChunkIndexEntry {
            chunk_offset: offset as u64,
            chunk_length: chunk.len() as u64,
            ..Default::default()
        };
        let error = read_chunk(
            &mut BytesReadable::new(&bytes),
            &IndexedScene::default(),
            &entry,
            3,
        )
        .unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("Chunk record at byte 17"),
            "{error}"
        );
    }
}
