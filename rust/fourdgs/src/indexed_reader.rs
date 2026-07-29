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

use std::collections::BTreeMap;

use crate::chunk::{decode_streams, DecodedChunk};
use crate::error::{Error, Result};
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

/// One record's framing: everything except its bytes.
#[derive(Debug, Clone, Copy)]
struct FrontRecord {
    opcode: u8,
    /// Offset of the record's opcode byte.
    offset: u64,
    content_length: u64,
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
/// Quantization grids, the Window Table, and the byte range of the audio track if there is
/// one — and none of them requires reading a record it does not care about. That
/// distinction is not academic: an embedded audio track is a first-class part of a scene
/// and sits in the front matter at whatever size the track is, so a walk that materializes
/// every record's content fails on the format's flagship case, a single file with sound.
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
    /// an audio track nobody asked for is never fetched at all.
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
    /// `(offset, length)` of the whole Audio record, or `None`.
    pub audio_range: Option<(u64, u64)>,
    pub audio_codec: Option<String>,
    pub summary_crc_ok: Option<bool>,
    /// `(offset, length)` of the front-matter records this reader did not parse. Opening a
    /// file frames them and stops: a camera nobody asked for costs nothing, and neither
    /// does an attachment the size of a thumbnail sheet.
    pub camera_range: Option<(u64, u64)>,
    pub metadata_ranges: Vec<(u64, u64)>,
    pub attachment_ranges: Vec<(u64, u64)>,
    pub statistics: Option<rec::Statistics>,
    pub summary_offsets: Vec<rec::SummaryOffset>,
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

    /// What a seek to `t` will transfer, so a caller can budget before asking.
    pub fn bytes_for_time(&self, t: f64, max_sh_band: u8) -> u64 {
        self.chunks_for_time(t)
            .iter()
            .map(|e| {
                e.bands
                    .iter()
                    .filter(|(band, _, _)| *band <= max_sh_band)
                    .fold(e.chunk_length, |total, (_, _, length)| {
                        total.saturating_add(*length)
                    })
            })
            .fold(0u64, u64::saturating_add)
    }
}

/// Open a scene: a bounded read from the front, then the index. Never the file.
pub fn open_indexed<R: Readable + ?Sized>(source: &mut R) -> Result<IndexedScene> {
    let size = source.size()?;
    let mut scene = IndexedScene::default();

    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
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
                op::HEADER => header = Some(rec::Header::parse(&front.content(&record, None)?)?),
                op::QUANTIZATION => {
                    quant = Some(rec::Quantization::parse(&front.content(&record, None)?)?)
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
                    scene.audio_codec = Some(audio_codec(&prefix)?);
                    scene.audio_range = Some((record.offset, record.total_length()));
                }
                op::CAMERA => scene.camera_range = Some((record.offset, record.total_length())),
                op::METADATA => scene
                    .metadata_ranges
                    .push((record.offset, record.total_length())),
                op::ATTACHMENT => scene
                    .attachment_ranges
                    .push((record.offset, record.total_length())),
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

/// The embedded track, fetched independently of any gaussian data.
///
/// `None` when the scene has none — a normal value, not an error.
pub fn read_audio<R: Readable + ?Sized>(
    source: &mut R,
    scene: &IndexedScene,
) -> Result<Option<Vec<u8>>> {
    match scene.audio_range {
        None => Ok(None),
        Some((offset, length)) => {
            let blob = source.read(offset, length)?;
            Ok(Some(
                rec::Audio::parse(record_content(&blob, op::AUDIO)?)?.data,
            ))
        }
    }
}

/// The `codec` field at the front of an Audio record, read out of a prefix of it.
fn audio_codec(prefix: &[u8]) -> Result<String> {
    Cursor::new(prefix).string().map_err(|_| {
        Error::Malformed(format!(
            "the Audio record's codec name does not fit the first {AUDIO_CODEC_PREFIX} bytes of the record"
        ))
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
