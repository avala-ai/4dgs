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
use std::io::{self, Read};
use std::path::Path;

use crate::chunk::{decode_streams, window_table_or_default, DecodedChunk};
use crate::error::{Error, Result};
use crate::model::{AudioTrack, GaussianSet};
use crate::opcode as op;
use crate::records as rec;
use crate::serialization::{crc32, Cursor, MAGIC, RECORD_HEADER_SIZE};
use crate::sh::merge_chunk_bands;
use crate::stream::{decode_stream, DecodedStream};

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
    /// `None` when the scene has no soundtrack, which is the common case and not an error.
    pub audio: Option<AudioTrack>,
    pub camera: Option<rec::Camera>,
    pub metadata: Vec<rec::Metadata>,
    pub attachments: Vec<rec::Attachment>,
    /// Every provenance record the file carried (spec section 5.15). Empty when it
    /// carried none, which is the common case and not an error: absence costs nothing and
    /// no Header flag announces the family, so this is filled by the walk itself.
    pub provenance: crate::provenance::Provenance,
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

/// Decode a whole file from any byte source.
pub fn read_from<R: Read>(source: R, options: &ReadOptions) -> Result<Scene> {
    let mut source = io::BufReader::new(source);

    let mut magic = [0u8; MAGIC.len()];
    read_exactly(&mut source, &mut magic)?;
    crate::serialization::check_magic(&magic)?;

    let mut scene = Scene::default();
    let mut header: Option<rec::Header> = None;
    let mut quant: Option<rec::Quantization> = None;
    let mut chunks: Vec<DecodedChunk> = Vec::new();
    let mut chunk_bands: Vec<BTreeMap<u8, DecodedStream>> = Vec::new();
    let mut truncated = false;

    // The Footer's CRC covers `[summary_start, footer_start)`, and a front-to-back reader
    // does not learn where that starts until the very last record. So the trailing run of
    // records that may legally sit in a summary is retained as it goes — the same bytes an
    // indexed reader would have loaded — and checked against the Footer at the end.
    let mut summary_tail: Vec<u8> = Vec::new();
    let mut summary_tail_start: u64 = 0;

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
            summary_tail.clear();
        }

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
                | op::CAMERA
                | op::METADATA
                | op::ATTACHMENT
                | op::COORDINATE_FRAME
                | op::SENSOR_CALIBRATION
                | op::RIG_TRAJECTORY
                | op::GEODETIC_ANCHOR
                | op::STATISTICS
                | op::CHUNK_INDEX
                | op::SUMMARY_OFFSET
                | op::FOOTER
        );
        if !known {
            scene.skipped_opcodes.push(opcode);
            if skip_exactly(&mut source, length)? {
                at = at.saturating_add(length);
                continue;
            }
            truncated = true;
            break;
        }

        let content = match read_content(&mut source, length) {
            Ok(c) => c,
            Err(e) if e.is_truncation() => {
                truncated = true;
                break;
            }
            Err(e) => return Err(e),
        };
        at = at.saturating_add(length);

        if is_summary {
            if summary_tail.is_empty() {
                summary_tail_start = offset;
            }
            summary_tail.extend_from_slice(&head);
            summary_tail.extend_from_slice(&content);
        }

        match opcode {
            op::HEADER => header = Some(rec::Header::parse(&content)?),
            op::QUANTIZATION => quant = Some(rec::Quantization::parse(&content)?),
            op::WINDOW_TABLE => scene.windows = rec::WindowTable::parse(&content)?.windows,
            op::CHUNK => {
                let quantization = quant.as_ref().ok_or_else(|| {
                    Error::Malformed("a Chunk arrived before the Quantization record".into())
                })?;
                let (chunk_head, streams) = rec::parse_chunk(&content)?;
                let blob = crate::chunk::chunk_stream_bytes(&chunk_head, streams)?;
                let cutoff = header
                    .as_ref()
                    .map(|h| h.cutoff)
                    .unwrap_or(crate::quantization::DEFAULT_CUTOFF);
                chunks.push(decode_streams(
                    &blob,
                    chunk_head.count as usize,
                    &quantization.steps(),
                    &quantization.pos_origin,
                    &scene.windows,
                    cutoff,
                )?);
                chunk_bands.push(BTreeMap::new());
                scene.chunk_intervals.push((chunk_head.t0, chunk_head.t1));
            }
            op::SH_BAND_STREAM => {
                // Bands belong to the chunk that precedes them, and are identified by the
                // record that contains them — never by the `attribute_id` in the stream
                // header, which carries 0x07 and collides with `mu_t` (spec §5.7).
                if let (Some(bands), Some(chunk)) = (chunk_bands.last_mut(), chunks.last()) {
                    let mut cursor = Cursor::new(&content);
                    let band = cursor.u8()?;
                    if band <= options.max_sh_band {
                        let (_, values) = decode_stream(&mut cursor, Some(chunk.count))?;
                        bands.insert(band, values);
                    }
                }
            }
            op::AUDIO => {
                let a = rec::Audio::parse(&content)?;
                scene.audio = Some(AudioTrack {
                    codec: a.codec,
                    start_sec: a.start_sec,
                    data: a.data,
                });
            }
            op::CAMERA => scene.camera = Some(rec::Camera::parse(&content)?),
            op::METADATA => scene.metadata.push(rec::Metadata::parse(&content)?),
            op::ATTACHMENT => scene.attachments.push(rec::Attachment::parse(&content)?),
            op::COORDINATE_FRAME => scene
                .provenance
                .frames
                .push(rec::CoordinateFrame::parse(&content)?),
            op::SENSOR_CALIBRATION => scene
                .provenance
                .sensors
                .push(rec::SensorCalibration::parse(&content)?),
            op::RIG_TRAJECTORY => scene
                .provenance
                .trajectories
                .push(rec::RigTrajectory::parse(&content)?),
            op::GEODETIC_ANCHOR => scene
                .provenance
                .anchors
                .push(rec::GeodeticAnchor::parse(&content)?),
            op::STATISTICS => scene.statistics = Some(rec::Statistics::parse(&content)?),
            op::CHUNK_INDEX => scene
                .chunk_index
                .push(rec::ChunkIndexEntry::parse(&content)?),
            op::SUMMARY_OFFSET => scene
                .summary_offsets
                .push(rec::SummaryOffset::parse(&content)?),
            op::FOOTER => {
                let footer = rec::Footer::parse(&content)?;
                if footer.summary_start != 0 && footer.summary_crc != 0 {
                    // Only claim a verdict when the retained bytes are exactly the range
                    // the Footer names. Anything else leaves `summary_crc_ok` as `None`:
                    // "not verified" is a different statement from "did not match", and a
                    // reader that conflated them would report corruption it never saw.
                    let covered = summary_tail_start == footer.summary_start
                        && summary_tail_start + summary_tail.len() as u64 == offset;
                    if covered {
                        scene.summary_crc_ok = Some(crc32(&summary_tail) == footer.summary_crc);
                    }
                }
            }
            _ => unreachable!("opcode was checked against the known set"),
        }
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
    // legitimately be missing the trajectory a sensor names, so this is skipped there: the
    // recovery contract is that everything complete before the cut still stands.
    if !truncated {
        scene.provenance.check()?;
    }

    scene.gaussians = assemble(&chunks, &chunk_bands, &scene.windows, &header)?;
    scene.duration_sec = header.duration_sec;
    scene.header = header;
    scene.quantization = quant;
    scene.truncated = truncated;
    Ok(scene)
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

/// Concatenate decoded chunks into one scene-wide set.
pub fn assemble(
    chunks: &[DecodedChunk],
    chunk_bands: &[BTreeMap<u8, DecodedStream>],
    windows: &[(f64, f64)],
    header: &rec::Header,
) -> Result<GaussianSet> {
    let table = window_table_or_default(windows);
    let total: usize = chunks.iter().map(|c| c.count).sum();

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
    for chunk in chunks {
        out.positions.extend_from_slice(&chunk.positions);
        out.scales.extend_from_slice(&chunk.scales);
        out.rotations.extend_from_slice(&chunk.rotations);
        out.colors.extend_from_slice(&chunk.colors);
        out.motions.extend_from_slice(&chunk.motions);
        out.mu_t.extend_from_slice(&chunk.mu_t);
        out.sigma_t.extend_from_slice(&chunk.sigma_t);
        for wi in &chunk.window_index {
            let (lo, hi) = table[*wi as usize];
            out.win_lo.push(lo as f32);
            out.win_hi.push(hi as f32);
        }
        match (&mut source_index, &chunk.source_index) {
            (Some(acc), Some(src)) => acc.extend_from_slice(src),
            _ => source_index = None,
        }
    }
    out.source_index = source_index.filter(|s| s.len() == total && total > 0);

    if header.sh_degree > 0 {
        let counts: Vec<usize> = chunks.iter().map(|c| c.count).collect();
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

/// One record's content, read in bounded blocks.
///
/// The buffer grows as bytes actually arrive rather than being sized from the declared
/// length, so a crafted length cannot make this allocate what the file does not contain.
/// `Read::read_to_end` on a `Take` will not do: it reserves the limit up front, which is
/// exactly the allocation this has to avoid — a fuzz case with a 115 MB length field in a
/// 3 KB file is what said so.
fn read_content<R: Read>(source: &mut R, length: u64) -> Result<Vec<u8>> {
    const BLOCK: usize = 64 * 1024;
    let mut out: Vec<u8> = Vec::new();
    let mut block = vec![0u8; BLOCK];
    let mut remaining = length;
    while remaining > 0 {
        let want = remaining.min(BLOCK as u64) as usize;
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
