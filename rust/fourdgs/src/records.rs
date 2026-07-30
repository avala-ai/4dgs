// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Record bodies: one struct per record type, each able to read and write itself.
//!
//! Every `parse` here reads the fields it knows and stops. It never asserts that the
//! record ended where its knowledge did, because a newer writer may have appended fields —
//! that is the compatibility rule, and honouring it is one line per record rather than a
//! policy nobody remembers.

use std::collections::{BTreeMap, HashSet};

use crate::error::{Error, Result};
use crate::opcode as op;
use crate::serialization::{
    put_blob, put_f32s, put_f64, put_f64s, put_record, put_str_map, put_string, put_u16, put_u32,
    put_u64, put_u8, Cursor,
};

pub const FLAG_HAS_AUDIO: u8 = 1 << 0;
pub const FLAG_CHUNKS_COMPRESSED: u8 = 1 << 1;
pub const AUDIO_SOURCE_SPATIAL: u8 = 1 << 0;
pub const AUDIO_SOURCE_LOOP: u8 = 1 << 1;

#[derive(Debug, Clone, PartialEq)]
pub struct Header {
    pub profile: String,
    pub library: String,
    pub duration_sec: f64,
    pub gaussian_count: u64,
    pub cutoff: f64,
    pub temporal_model: String,
    pub aabb: Vec<f64>,
    pub sh_degree: u8,
    pub flags: u8,
    pub attributes: BTreeMap<String, String>,
}

impl Default for Header {
    /// A default Header declares the temporal model this version defines.
    ///
    /// Deriving `Default` left `temporal_model` empty, which is not a value the registry
    /// lists — so a Header built this way and written out produced a file every
    /// conforming reader must refuse, by a rule that names the field. It never reached a
    /// real file because the writer sets the model explicitly, but the two SDKs disagreed
    /// about what an unspecified Header means, and the Python dataclass has always
    /// defaulted to `gaussian-birth`. Two implementations of one format do not get to
    /// have different defaults.
    fn default() -> Self {
        Self {
            profile: String::new(),
            library: String::new(),
            duration_sec: 0.0,
            gaussian_count: 0,
            cutoff: 0.0,
            temporal_model: "gaussian-birth".into(),
            aabb: Vec::new(),
            sh_degree: 0,
            flags: 0,
            attributes: BTreeMap::new(),
        }
    }
}

impl Header {
    /// Answered from the header alone — no probing, no speculative range request.
    ///
    /// This is the whole audio-discovery rule, and it is why a scene without audio
    /// costs nothing: the bit is clear and there is no record.
    pub fn has_audio(&self) -> bool {
        self.flags & FLAG_HAS_AUDIO != 0
    }

    pub fn parse(content: &[u8]) -> Result<Header> {
        let mut c = Cursor::new(content);
        Ok(Header {
            profile: c.string()?,
            library: c.string()?,
            duration_sec: c.f64()?,
            gaussian_count: c.u64()?,
            cutoff: c.f64()?,
            temporal_model: c.string()?,
            aabb: c.f64s(6)?,
            sh_degree: c.u8()?,
            flags: c.u8()?,
            attributes: c.str_map()?,
        })
    }

    /// A newer writer may append fields; a reader uses `content_length` and steps over
    /// what it does not know. `trailer` is how a test writes that newer file.
    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.profile);
        put_string(&mut body, &self.library);
        put_f64(&mut body, self.duration_sec);
        put_u64(&mut body, self.gaussian_count);
        put_f64(&mut body, self.cutoff);
        put_string(&mut body, &self.temporal_model);
        put_f64s(&mut body, &self.aabb);
        put_u8(&mut body, self.sh_degree);
        put_u8(&mut body, self.flags);
        put_str_map(&mut body, &self.attributes);
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::HEADER, &body);
        out
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Footer {
    pub summary_start: u64,
    pub summary_offset_start: u64,
    pub summary_crc: u32,
}

impl Footer {
    pub fn parse(content: &[u8]) -> Result<Footer> {
        let mut c = Cursor::new(content);
        Ok(Footer {
            summary_start: c.u64()?,
            summary_offset_start: c.u64()?,
            summary_crc: c.u32()?,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u64(&mut body, self.summary_start);
        put_u64(&mut body, self.summary_offset_start);
        put_u32(&mut body, self.summary_crc);
        let mut out = Vec::new();
        put_record(&mut out, op::FOOTER, &body);
        out
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Quantization {
    pub scheme: String,
    pub pos_origin: Vec<f64>,
    pub step_pos: f64,
    pub step_scale_log: f64,
    pub step_rot: f64,
    pub step_rgb: f64,
    pub step_alpha: f64,
    pub step_motion: f64,
    pub step_time: f64,
    pub step_sigma_log: f64,
    pub step_sh: u8,
    pub bounds: BTreeMap<String, String>,
    /// Per-band spherical harmonic bit depths, band 1 first. Appended after the record's
    /// original fields, so a file that declares none is byte-identical to one written
    /// before the field existed — an empty list is written as no bytes at all, not as a
    /// zero count.
    pub sh_bit_depths: Vec<u8>,
}

impl Quantization {
    pub fn parse(content: &[u8]) -> Result<Quantization> {
        let mut c = Cursor::new(content);
        let scheme = c.string()?;
        let pos_origin = c.f64s(3)?;
        let steps = c.f64s(8)?;
        let quantization = Quantization {
            scheme,
            pos_origin,
            step_pos: steps[0],
            step_scale_log: steps[1],
            step_rot: steps[2],
            step_rgb: steps[3],
            step_alpha: steps[4],
            step_motion: steps[5],
            step_time: steps[6],
            step_sigma_log: steps[7],
            step_sh: c.u8()?,
            bounds: c.str_map()?,
            sh_bit_depths: sh_bit_depths(c.rest()),
        };
        if let Some(value) = quantization.bounds.get("object_id") {
            return Err(Error::Malformed(format!(
                "Quantization.bounds contains object_id={value:?}; object_id is an exact label \
                 and MUST NOT carry a bound"
            )));
        }
        Ok(quantization)
    }

    pub fn steps(&self) -> crate::quantization::Steps {
        crate::quantization::Steps {
            pos: self.step_pos,
            scale_log: self.step_scale_log,
            rot: self.step_rot,
            rgb: self.step_rgb,
            alpha: self.step_alpha,
            motion: self.step_motion,
            time: self.step_time,
            sigma_log: self.step_sigma_log,
            sh: self.step_sh,
        }
    }

    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.scheme);
        put_f64s(&mut body, &self.pos_origin);
        put_f64s(
            &mut body,
            &[
                self.step_pos,
                self.step_scale_log,
                self.step_rot,
                self.step_rgb,
                self.step_alpha,
                self.step_motion,
                self.step_time,
                self.step_sigma_log,
            ],
        );
        put_u8(&mut body, self.step_sh);
        put_str_map(&mut body, &self.bounds);
        if !self.sh_bit_depths.is_empty() {
            put_u8(&mut body, self.sh_bit_depths.len() as u8);
            body.extend_from_slice(&self.sh_bit_depths);
        }
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::QUANTIZATION, &body);
        out
    }
}

/// Read the appended per-band SH bit depths, or nothing.
///
/// Deliberately tolerant. Appended fields are positional, so anything sitting after the
/// bounds map lands where this field is — including bytes a *different* newer writer
/// appended, or the arbitrary trailer a forward-compatibility fixture puts there. The
/// declaration describes encoding that already happened and no decoded value depends on
/// it, so a count the record is too short for, or a depth outside the legal range, reads
/// as "this file declares none" rather than as a corrupt file (spec §5.3).
fn sh_bit_depths(tail: &[u8]) -> Vec<u8> {
    let Some((count, depths)) = tail.split_first() else {
        return Vec::new();
    };
    let count = *count as usize;
    if count == 0 || depths.len() < count {
        return Vec::new();
    }
    let depths = &depths[..count];
    let legal = crate::quantization::SH_MIN_BITS..=crate::quantization::SH_MAX_BITS;
    if depths.iter().all(|d| legal.contains(d)) {
        depths.to_vec()
    } else {
        Vec::new()
    }
}

/// The validity windows gaussians reference by index.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WindowTable {
    pub windows: Vec<(f64, f64)>,
}

impl WindowTable {
    pub fn parse(content: &[u8]) -> Result<WindowTable> {
        let mut c = Cursor::new(content);
        let count = c.u32()? as usize;
        let mut windows = Vec::with_capacity(count.min(1 << 16));
        for _ in 0..count {
            let lo = c.f64()?;
            let hi = c.f64()?;
            windows.push((lo, hi));
        }
        Ok(WindowTable { windows })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u32(&mut body, self.windows.len() as u32);
        for (lo, hi) in &self.windows {
            put_f64(&mut body, *lo);
            put_f64(&mut body, *hi);
        }
        let mut out = Vec::new();
        put_record(&mut out, op::WINDOW_TABLE, &body);
        out
    }
}

/// A chunk's own fields; its streams follow inside the `records` blob.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChunkHeader {
    pub t0: f64,
    pub t1: f64,
    pub level: u32,
    pub count: u32,
    pub compression: String,
    pub uncompressed_size: u64,
}

/// Parse a Chunk record's content into its header and the streams blob behind it.
pub fn parse_chunk(content: &[u8]) -> Result<(ChunkHeader, &[u8])> {
    let mut c = Cursor::new(content);
    let head = ChunkHeader {
        t0: c.f64()?,
        t1: c.f64()?,
        level: c.u32()?,
        count: c.u32()?,
        compression: c.string()?,
        uncompressed_size: c.u64()?,
    };
    let streams = c.blob()?;
    Ok((head, streams))
}

/// Frame a chunk: its header fields plus the concatenated Attribute Stream records.
pub fn encode_chunk(t0: f64, t1: f64, level: u32, count: u32, streams: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    put_f64(&mut body, t0);
    put_f64(&mut body, t1);
    put_u32(&mut body, level);
    put_u32(&mut body, count);
    // Chunk-level compression: the streams carry their own.
    put_string(&mut body, "");
    put_u64(&mut body, streams.len() as u64);
    put_blob(&mut body, streams);
    let mut out = Vec::new();
    put_record(&mut out, op::CHUNK, &body);
    out
}

/// A delta chunk's own fields; its three groups follow inside the `records` blob.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DeltaChunkHeader {
    pub t0: f64,
    pub t1: f64,
    pub level: u32,
    pub delta_mode: u8,
    pub reference_offset: u64,
    pub keyframe_offset: u64,
    pub depth: u16,
    pub update_count: u32,
    pub birth_count: u32,
    pub death_count: u32,
    pub compression: String,
    pub uncompressed_size: u64,
}

/// `delta_mode` values. Per chunk, not per file: an encoder that knows an instant is a
/// likely seek target can make it cost two records regardless of how deep into the group
/// it falls, without spending a whole keyframe on it.
pub const DELTA_MODE_KEYFRAME: u8 = 0;
pub const DELTA_MODE_CHAINED: u8 = 1;

/// Frame a Delta Chunk record.
///
/// The three groups are framed by length inside one `records` blob rather than tagged with
/// a group byte on every stream. That spends no second opcode, leaves the Attribute Stream
/// record untouched, and lets a reader take the death list — which is small and which a
/// consumer often wants alone — by stepping over two lengths.
#[allow(clippy::too_many_arguments)]
pub fn encode_delta_chunk(
    t0: f64,
    t1: f64,
    level: u32,
    delta_mode: u8,
    reference_offset: u64,
    keyframe_offset: u64,
    depth: u16,
    updates: &[u8],
    births: &[u8],
    deaths: &[u8],
    counts: (u32, u32, u32),
) -> Vec<u8> {
    let (update_count, birth_count, death_count) = counts;
    let mut records = Vec::new();
    put_blob(&mut records, updates);
    put_blob(&mut records, births);
    put_blob(&mut records, deaths);

    let mut body = Vec::new();
    put_f64(&mut body, t0);
    put_f64(&mut body, t1);
    put_u32(&mut body, level);
    put_u8(&mut body, delta_mode);
    put_u64(&mut body, reference_offset);
    put_u64(&mut body, keyframe_offset);
    put_u16(&mut body, depth);
    put_u32(&mut body, update_count);
    put_u32(&mut body, birth_count);
    put_u32(&mut body, death_count);
    // Chunk-level compression: the streams carry their own.
    put_string(&mut body, "");
    put_u64(&mut body, records.len() as u64);
    put_blob(&mut body, &records);

    let mut out = Vec::new();
    put_record(&mut out, op::DELTA_CHUNK, &body);
    out
}

/// A parsed Delta Chunk: its header and its three group blobs (updates, births, deaths),
/// each borrowed from the record content.
pub type DeltaChunkParts<'a> = (DeltaChunkHeader, &'a [u8], &'a [u8], &'a [u8]);

/// Parse a Delta Chunk record's content into its header and its three group blobs
/// (updates, births, deaths).
pub fn parse_delta_chunk(content: &[u8]) -> Result<DeltaChunkParts<'_>> {
    let mut c = Cursor::new(content);
    let head = DeltaChunkHeader {
        t0: c.f64()?,
        t1: c.f64()?,
        level: c.u32()?,
        delta_mode: c.u8()?,
        reference_offset: c.u64()?,
        keyframe_offset: c.u64()?,
        depth: c.u16()?,
        update_count: c.u32()?,
        birth_count: c.u32()?,
        death_count: c.u32()?,
        compression: c.string()?,
        uncompressed_size: c.u64()?,
    };
    let records = c.blob()?;
    let mut r = Cursor::new(records);
    let updates = r.blob()?;
    let births = r.blob()?;
    let deaths = r.blob()?;
    Ok((head, updates, births, deaths))
}

/// Bytes the `keyframe-delta` block appends to a Chunk Index entry. A reader takes the
/// record's length from its header, so an entry with at least this many bytes left after
/// the band array carries the block and one without simply does not — which is how a
/// `gaussian-birth` file written before this revision still parses, unchanged, to the same
/// values.
const INDEX_DELTA_BLOCK: usize = 1 + 1 + 8 + 8 + 2 + 8;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChunkIndexEntry {
    pub t0: f64,
    pub t1: f64,
    pub chunk_offset: u64,
    pub chunk_length: u64,
    pub gaussian_count: u32,
    /// `(band, offset, length)`, each framing a whole SH Band Stream record.
    pub bands: Vec<(u8, u64, u64)>,
    /// True when this entry carries the `keyframe-delta` block below. False for every
    /// `gaussian-birth` file, whose entries must stay byte-identical.
    pub extended: bool,
    /// 0 keyframe (a Chunk record), 1 delta (a Delta Chunk record).
    pub kind: u8,
    pub delta_mode: u8,
    /// The chunk this delta applies to. Strictly less than `chunk_offset`: references point
    /// backwards only, so the chain walk terminates and cycles are unrepresentable.
    pub reference_offset: u64,
    /// The keyframe at the head of this group. Equals `chunk_offset` for a keyframe.
    pub keyframe_offset: u64,
    /// Delta chunks that must be composed to reach this one. The exact read cost, known
    /// from the index before anything is fetched.
    pub depth: u16,
    /// Gaussians live over `[t0, t1)` after composition. `gaussian_count` cannot answer
    /// this for a delta entry — there it is the size of the delta, not of the population.
    pub live_count: u64,
}

impl ChunkIndexEntry {
    /// The normative seek rule, per entry.
    pub fn covers(&self, t: f64) -> bool {
        self.t0 <= t && t < self.t1
    }

    pub fn parse(content: &[u8]) -> Result<ChunkIndexEntry> {
        let mut c = Cursor::new(content);
        let mut entry = ChunkIndexEntry {
            t0: c.f64()?,
            t1: c.f64()?,
            chunk_offset: c.u64()?,
            chunk_length: c.u64()?,
            gaussian_count: c.u32()?,
            ..Default::default()
        };
        let bands = c.u32()? as usize;
        entry.bands.reserve(bands.min(1 << 12));
        for _ in 0..bands {
            let band = c.u8()?;
            let offset = c.u64()?;
            let length = c.u64()?;
            entry.bands.push((band, offset, length));
        }
        if c.remaining() >= INDEX_DELTA_BLOCK {
            entry.extended = true;
            entry.kind = c.u8()?;
            entry.delta_mode = c.u8()?;
            entry.reference_offset = c.u64()?;
            entry.keyframe_offset = c.u64()?;
            entry.depth = c.u16()?;
            entry.live_count = c.u64()?;
        }
        Ok(entry)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_f64(&mut body, self.t0);
        put_f64(&mut body, self.t1);
        put_u64(&mut body, self.chunk_offset);
        put_u64(&mut body, self.chunk_length);
        put_u32(&mut body, self.gaussian_count);
        put_u32(&mut body, self.bands.len() as u32);
        for (band, offset, length) in &self.bands {
            put_u8(&mut body, *band);
            put_u64(&mut body, *offset);
            put_u64(&mut body, *length);
        }
        if self.extended {
            put_u8(&mut body, self.kind);
            put_u8(&mut body, self.delta_mode);
            put_u64(&mut body, self.reference_offset);
            put_u64(&mut body, self.keyframe_offset);
            put_u16(&mut body, self.depth);
            put_u64(&mut body, self.live_count);
        }
        let mut out = Vec::new();
        put_record(&mut out, op::CHUNK_INDEX, &body);
        out
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Audio {
    pub codec: String,
    pub start_sec: f64,
    pub data: Vec<u8>,
}

impl Audio {
    pub fn parse(content: &[u8]) -> Result<Audio> {
        let mut c = Cursor::new(content);
        Ok(Audio {
            codec: c.string()?,
            start_sec: c.f64()?,
            data: c.blob()?.to_vec(),
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.codec);
        put_f64(&mut body, self.start_sec);
        put_blob(&mut body, &self.data);
        let mut out = Vec::new();
        put_record(&mut out, op::AUDIO, &body);
        out
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioSourceKeyframe {
    pub time: f64,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
}

/// The small descriptor in an Audio Source record. Its bytes are in Audio Data.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioSource {
    pub source_id: u32,
    pub name: String,
    pub codec: String,
    pub channel_layout: String,
    pub data_length: u64,
    pub start_sec: f64,
    pub duration_sec: f64,
    pub gain: f64,
    pub flags: u8,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
    pub keyframes: Vec<AudioSourceKeyframe>,
    pub interpolation: String,
}

impl AudioSource {
    pub fn spatial(&self) -> bool {
        self.flags & AUDIO_SOURCE_SPATIAL != 0
    }

    pub fn loop_(&self) -> bool {
        self.flags & AUDIO_SOURCE_LOOP != 0
    }

    pub fn parse(content: &[u8]) -> Result<AudioSource> {
        let mut c = Cursor::new(content);
        let source_id = c.u32()?;
        let name = c.string()?;
        let codec = c.string()?;
        let channel_layout = c.string()?;
        let data_length = c.u64()?;
        let start_sec = c.f64()?;
        let duration_sec = c.f64()?;
        let gain = c.f64()?;
        let flags = c.u8()?;
        let position: [f64; 3] = c.f64s(3)?.try_into().expect("three values");
        let rotation: [f64; 4] = c.f64s(4)?.try_into().expect("four values");
        let count = c.u32()?;
        let needed = usize::try_from(count)
            .unwrap_or(usize::MAX)
            .checked_mul(64)
            .ok_or_else(|| {
                Error::Malformed(format!(
                    "Audio Source {source_id} keyframe count {count} overflows"
                ))
            })?;
        if needed > c.remaining() {
            return Err(Error::Malformed(format!(
                "Audio Source {source_id} declares {count} keyframes needing {needed} bytes, {} remain",
                c.remaining()
            )));
        }
        let mut keyframes = Vec::with_capacity(count as usize);
        for _ in 0..count {
            keyframes.push(AudioSourceKeyframe {
                time: c.f64()?,
                position: c.f64s(3)?.try_into().expect("three values"),
                rotation: c.f64s(4)?.try_into().expect("four values"),
            });
        }
        let source = AudioSource {
            source_id,
            name,
            codec,
            channel_layout,
            data_length,
            start_sec,
            duration_sec,
            gain,
            flags,
            position,
            rotation,
            keyframes,
            interpolation: c.string()?,
        };
        validate_audio_source(&source)?;
        Ok(source)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u32(&mut body, self.source_id);
        put_string(&mut body, &self.name);
        put_string(&mut body, &self.codec);
        put_string(&mut body, &self.channel_layout);
        put_u64(&mut body, self.data_length);
        put_f64(&mut body, self.start_sec);
        put_f64(&mut body, self.duration_sec);
        put_f64(&mut body, self.gain);
        put_u8(&mut body, self.flags);
        put_f64s(&mut body, &self.position);
        put_f64s(&mut body, &self.rotation);
        put_u32(&mut body, self.keyframes.len() as u32);
        for keyframe in &self.keyframes {
            put_f64(&mut body, keyframe.time);
            put_f64s(&mut body, &keyframe.position);
            put_f64s(&mut body, &keyframe.rotation);
        }
        put_string(&mut body, &self.interpolation);
        let mut out = Vec::new();
        put_record(&mut out, op::AUDIO_SOURCE, &body);
        out
    }
}

fn validate_audio_source(source: &AudioSource) -> Result<()> {
    if source.flags & !(AUDIO_SOURCE_SPATIAL | AUDIO_SOURCE_LOOP) != 0 {
        return Err(Error::Malformed(format!(
            "Audio Source {} has reserved flag bits set",
            source.source_id
        )));
    }
    if source.codec.is_empty() {
        return Err(Error::Malformed(format!(
            "Audio Source {} has an empty codec",
            source.source_id
        )));
    }
    if !source.start_sec.is_finite() {
        return Err(Error::Malformed(format!(
            "Audio Source {} start_sec is not finite",
            source.source_id
        )));
    }
    if !source.duration_sec.is_finite() || source.duration_sec <= 0.0 {
        return Err(Error::Malformed(format!(
            "Audio Source {} duration_sec must be finite and positive",
            source.source_id
        )));
    }
    if !source.gain.is_finite() || source.gain < 0.0 {
        return Err(Error::Malformed(format!(
            "Audio Source {} gain must be finite and non-negative",
            source.source_id
        )));
    }
    if source.spatial() && source.channel_layout != "mono" {
        return Err(Error::Malformed(format!(
            "spatial Audio Source {} must use channel layout \"mono\"",
            source.source_id
        )));
    }
    if !source.position.iter().all(|value| value.is_finite()) {
        return Err(Error::Malformed(format!(
            "Audio Source {} position must contain three finite values",
            source.source_id
        )));
    }
    if !source.rotation.iter().all(|value| value.is_finite())
        || source.rotation.iter().all(|value| *value == 0.0)
    {
        return Err(Error::Malformed(format!(
            "Audio Source {} rotation must be a finite non-zero quaternion",
            source.source_id
        )));
    }
    let mut last = f64::NEG_INFINITY;
    for (index, frame) in source.keyframes.iter().enumerate() {
        if !frame.time.is_finite() || frame.time <= last {
            return Err(Error::Malformed(format!(
                "Audio Source {} keyframe {index} time must be finite and strictly increasing",
                source.source_id
            )));
        }
        if !frame.position.iter().all(|value| value.is_finite()) {
            return Err(Error::Malformed(format!(
                "Audio Source {} keyframe {index} position must contain three finite values",
                source.source_id
            )));
        }
        if !frame.rotation.iter().all(|value| value.is_finite())
            || frame.rotation.iter().all(|value| *value == 0.0)
        {
            return Err(Error::Malformed(format!(
                "Audio Source {} keyframe {index} rotation must be a finite non-zero quaternion",
                source.source_id
            )));
        }
        last = frame.time;
    }
    if source.interpolation != "linear" && source.interpolation != "step" {
        return Err(Error::Malformed(format!(
            "Audio Source {} uses unknown interpolation {:?}",
            source.source_id, source.interpolation
        )));
    }
    Ok(())
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AudioData {
    pub source_id: u32,
    pub data: Vec<u8>,
}

impl AudioData {
    pub fn parse(content: &[u8]) -> Result<AudioData> {
        let mut c = Cursor::new(content);
        Ok(AudioData {
            source_id: c.u32()?,
            data: c.blob()?.to_vec(),
        })
    }

    /// Consume a record's content buffer and move its payload out, rather than parsing it
    /// into a fresh allocation the way `parse` does. The streamed reader keeps one payload
    /// per source until the whole file has gone past; for a mostly-audio file that is most
    /// of the bytes it holds, and copying each one out would keep it in memory twice at
    /// once. Reusing the record's own allocation avoids that transient duplication. The
    /// validation is identical to `parse`: a `source_id`, then a length-prefixed blob.
    pub fn into_payload(mut content: Vec<u8>) -> Result<(u32, Vec<u8>)> {
        let (source_id, start, len) = {
            let mut c = Cursor::new(&content);
            let source_id = c.u32()?;
            let data = c.blob()?;
            let len = data.len();
            // The blob's bytes sit between the fields already read and whatever the cursor
            // has not reached, so its start is fixed without hardcoding the framing width.
            (source_id, content.len() - c.remaining() - len, len)
        };
        content.truncate(start + len);
        content.drain(..start);
        Ok((source_id, content))
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u32(&mut body, self.source_id);
        put_blob(&mut body, &self.data);
        let mut out = Vec::new();
        put_record(&mut out, op::AUDIO_DATA, &body);
        out
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Camera {
    pub fov_y_deg: f64,
    pub position: [f64; 3],
    pub target: [f64; 3],
    pub times: Vec<f64>,
    pub positions: Vec<[f64; 3]>,
    pub targets: Vec<[f64; 3]>,
    pub interpolation: String,
    pub loop_: bool,
}

impl Default for Camera {
    fn default() -> Self {
        Camera {
            fov_y_deg: 50.0,
            position: [0.0, 0.0, 3.0],
            target: [0.0; 3],
            times: Vec::new(),
            positions: Vec::new(),
            targets: Vec::new(),
            interpolation: "spline".into(),
            loop_: true,
        }
    }
}

fn triple(v: Vec<f64>) -> [f64; 3] {
    [v[0], v[1], v[2]]
}

impl Camera {
    pub fn parse(content: &[u8]) -> Result<Camera> {
        let mut c = Cursor::new(content);
        let fov_y_deg = c.f64()?;
        let position = triple(c.f64s(3)?);
        let target = triple(c.f64s(3)?);
        let count = c.u32()? as usize;
        let mut times = Vec::with_capacity(count.min(1 << 16));
        let mut positions = Vec::with_capacity(count.min(1 << 16));
        let mut targets = Vec::with_capacity(count.min(1 << 16));
        for _ in 0..count {
            times.push(c.f64()?);
            positions.push(triple(c.f64s(3)?));
            targets.push(triple(c.f64s(3)?));
        }
        Ok(Camera {
            fov_y_deg,
            position,
            target,
            times,
            positions,
            targets,
            interpolation: c.string()?,
            loop_: c.u8()? != 0,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_f64(&mut body, self.fov_y_deg);
        put_f64s(&mut body, &self.position);
        put_f64s(&mut body, &self.target);
        put_u32(&mut body, self.times.len() as u32);
        for i in 0..self.times.len() {
            put_f64(&mut body, self.times[i]);
            put_f64s(&mut body, &self.positions[i]);
            put_f64s(&mut body, &self.targets[i]);
        }
        put_string(&mut body, &self.interpolation);
        put_u8(&mut body, u8::from(self.loop_));
        let mut out = Vec::new();
        put_record(&mut out, op::CAMERA, &body);
        out
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Metadata {
    pub name: String,
    pub entries: BTreeMap<String, String>,
}

impl Metadata {
    pub fn parse(content: &[u8]) -> Result<Metadata> {
        let mut c = Cursor::new(content);
        Ok(Metadata {
            name: c.string()?,
            entries: c.str_map()?,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.name);
        put_str_map(&mut body, &self.entries);
        let mut out = Vec::new();
        put_record(&mut out, op::METADATA, &body);
        out
    }
}

/// A summary a reader can trust without scanning chunks. Advisory: a reader that needs
/// certainty computes from the chunks.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Statistics {
    pub gaussian_count: u64,
    pub chunk_count: u32,
    pub duration_sec: f64,
    pub aabb: Vec<f64>,
}

impl Statistics {
    pub fn parse(content: &[u8]) -> Result<Statistics> {
        let mut c = Cursor::new(content);
        Ok(Statistics {
            gaussian_count: c.u64()?,
            chunk_count: c.u32()?,
            duration_sec: c.f64()?,
            aabb: c.f64s(6)?,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u64(&mut body, self.gaussian_count);
        put_u32(&mut body, self.chunk_count);
        put_f64(&mut body, self.duration_sec);
        put_f64s(&mut body, &self.aabb);
        let mut out = Vec::new();
        put_record(&mut out, op::STATISTICS, &body);
        out
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Attachment {
    pub name: String,
    pub media_type: String,
    pub data: Vec<u8>,
}

impl Attachment {
    pub fn parse(content: &[u8]) -> Result<Attachment> {
        let mut c = Cursor::new(content);
        Ok(Attachment {
            name: c.string()?,
            media_type: c.string()?,
            data: c.blob()?.to_vec(),
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.name);
        put_string(&mut body, &self.media_type);
        put_blob(&mut body, &self.data);
        let mut out = Vec::new();
        put_record(&mut out, op::ATTACHMENT, &body);
        out
    }
}

/// Lets a reader range-read one class of index record without reading the others.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SummaryOffset {
    pub group_opcode: u8,
    pub group_start: u64,
    pub group_length: u64,
}

impl SummaryOffset {
    pub fn parse(content: &[u8]) -> Result<SummaryOffset> {
        let mut c = Cursor::new(content);
        Ok(SummaryOffset {
            group_opcode: c.u8()?,
            group_start: c.u64()?,
            group_length: c.u64()?,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut body = Vec::new();
        put_u8(&mut body, self.group_opcode);
        put_u64(&mut body, self.group_start);
        put_u64(&mut body, self.group_length);
        let mut out = Vec::new();
        put_record(&mut out, op::SUMMARY_OFFSET, &body);
        out
    }
}

// ---------------------------------------------------------------------------
// Provenance family (spec section 5.15)
//
// Four optional records, none announced by a Header flag. Absence is the common case
// and costs nothing: a scene with no provenance carries no record, no placeholder and
// no reserved bytes, exactly as a scene without audio does.
//
// What `parse` refuses here is narrower than what a validator reports. A parse refuses
// only the structurally impossible — a basis that is not a basis, a quaternion with no
// direction, timestamps that make an interval ambiguous — because those are values no
// consumer can do anything sensible with. A value that is merely unrecognized (a
// modality this build has not heard of, a camera model it cannot project with) survives
// parsing and reaches the caller raw, which is the distinction between "malformed" and
// "from a newer registry" that a caller needs in order to react differently to the two.
// ---------------------------------------------------------------------------

/// Registry ids for `CoordinateFrame::camera_model`-adjacent enums live in
/// [`crate::provenance`]; these two are wire constants the records themselves need.
pub const POSE_TO_SCENE: u8 = 0;
pub const POSE_TO_RIG: u8 = 1;

pub const TRAJECTORY_LINEAR: u8 = 0;
pub const TRAJECTORY_STEP: u8 = 1;

/// Coefficient counts each camera model defines, keyed by its registry id. A model
/// absent from here is one this build does not know, which is not the same as one that
/// is wrong: `None` means "ask the caller", not "refuse".
pub fn camera_model_coefficients(model: u8) -> Option<&'static [usize]> {
    match model {
        0 | 1 => Some(&[0]),
        2 => Some(&[5, 8]),
        3 => Some(&[4]),
        _ => None,
    }
}

/// The frame a file's own coordinates are expressed in. Opcode `0x20`.
///
/// A **fixed shape**: every field is always present, so a reader that knows these six
/// knows exactly where an appended seventh would begin. The georeference is a separate
/// record ([`GeodeticAnchor`], `0x23`) for that reason — a conditional block inside a
/// record makes the offset of everything after it depend on a value, and the format
/// already has an idiom for optional-with-zero-cost-absence: a record that is not there.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CoordinateFrame {
    pub name: String,
    pub handedness: u8,
    pub up_axis: u8,
    pub forward_axis: u8,
    pub length_unit: u8,
    pub metres_per_unit: f64,
}

impl CoordinateFrame {
    pub fn parse(content: &[u8]) -> Result<CoordinateFrame> {
        let mut c = Cursor::new(content);
        let frame = CoordinateFrame {
            name: c.string()?,
            handedness: c.u8()?,
            up_axis: c.u8()?,
            forward_axis: c.u8()?,
            length_unit: c.u8()?,
            metres_per_unit: c.f64()?,
        };
        frame.check()?;
        Ok(frame)
    }

    /// Refuse a frame that is not one, rather than repair it.
    ///
    /// The reasoning is section 5.4's, about window indices: a degenerate basis does not
    /// announce itself. It silently re-orients everything a consumer derives from it, and
    /// a reader that guessed the missing axis would turn a detectable fault into
    /// plausible wrong output.
    pub fn check(&self) -> Result<()> {
        for (label, axis) in [
            ("up_axis", self.up_axis),
            ("forward_axis", self.forward_axis),
        ] {
            if axis > 5 {
                return Err(Error::Malformed(format!(
                    "CoordinateFrame {label} is {axis}; the registry defines 0..5 (section 5.15.2)"
                )));
            }
        }
        if self.up_axis % 3 == self.forward_axis % 3 {
            return Err(Error::Malformed(format!(
                "CoordinateFrame up_axis {} and forward_axis {} name the same axis; \
                 a frame needs two different ones (section 5.15.2)",
                self.up_axis, self.forward_axis
            )));
        }
        if !self.metres_per_unit.is_finite() || self.metres_per_unit < 0.0 {
            return Err(Error::Malformed(format!(
                "CoordinateFrame metres_per_unit is {}; it must be finite and not negative \
                 (section 5.15.2)",
                self.metres_per_unit
            )));
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.name);
        put_u8(&mut body, self.handedness);
        put_u8(&mut body, self.up_axis);
        put_u8(&mut body, self.forward_axis);
        put_u8(&mut body, self.length_unit);
        put_f64(&mut body, self.metres_per_unit);
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::COORDINATE_FRAME, &body);
        out
    }
}

/// Where a frame's origin sits on the WGS-84 ellipsoid, and which way it faces.
/// Opcode `0x23`.
///
/// It answers "roughly where on Earth is this" and stops. A producer needing a projected
/// coordinate system, a geoid model or a datum other than WGS-84 puts it in metadata or
/// an attachment; growing this record into a geodetic library is how a container format
/// stops being one.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GeodeticAnchor {
    pub frame_name: String,
    pub latitude_deg: f64,
    pub longitude_deg: f64,
    pub altitude_m: f64,
    pub heading_deg: f64,
}

impl GeodeticAnchor {
    pub fn parse(content: &[u8]) -> Result<GeodeticAnchor> {
        let mut c = Cursor::new(content);
        let frame_name = c.string()?;
        let v = c.f64s(4)?;
        let anchor = GeodeticAnchor {
            frame_name,
            latitude_deg: v[0],
            longitude_deg: v[1],
            altitude_m: v[2],
            heading_deg: v[3],
        };
        anchor.check()?;
        Ok(anchor)
    }

    /// Refuse an out-of-range angle rather than wrap it.
    ///
    /// Unlike the unit disagreement in [`CoordinateFrame`], there is no second field to
    /// fall back on here: a latitude of 130 degrees has no reading that is merely
    /// approximate, and normalizing it would invent a location.
    pub fn check(&self) -> Result<()> {
        for (label, value, lo, hi) in [
            ("latitude_deg", self.latitude_deg, -90.0, 90.0),
            ("longitude_deg", self.longitude_deg, -180.0, 180.0),
            (
                "altitude_m",
                self.altitude_m,
                f64::NEG_INFINITY,
                f64::INFINITY,
            ),
            ("heading_deg", self.heading_deg, 0.0, 360.0),
        ] {
            if !value.is_finite() {
                return Err(Error::Malformed(format!(
                    "GeodeticAnchor {label} is {value}; every field must be finite"
                )));
            }
            let past_end = label == "heading_deg" && value == 360.0;
            if value < lo || value > hi || past_end {
                return Err(Error::Malformed(format!(
                    "GeodeticAnchor {label} is {value}, outside its legal range (section 5.15.5)"
                )));
            }
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.frame_name);
        put_f64s(
            &mut body,
            &[
                self.latitude_deg,
                self.longitude_deg,
                self.altitude_m,
                self.heading_deg,
            ],
        );
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::GEODETIC_ANCHOR, &body);
        out
    }
}

/// One sensor's intrinsics and extrinsics. Opcode `0x21`, one record per sensor.
///
/// The extrinsic maps sensor coordinates into the frame `pose_reference` names, in that
/// direction: `p_target = R(rotation) * p_sensor + translation`. The opposite convention
/// is equally common in the field, which is why the direction is written down in both the
/// specification and here — a consumer that assumes wrongly gets a scene that is merely
/// mis-placed rather than one that fails.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SensorCalibration {
    pub name: String,
    pub modality: String,
    pub camera_model: u8,
    pub width_px: u32,
    pub height_px: u32,
    pub fx: f64,
    pub fy: f64,
    pub cx: f64,
    pub cy: f64,
    pub distortion: Vec<f64>,
    /// Unit quaternion, `xyzw` — the same order as spec §3 and §6.4.
    pub rotation: [f64; 4],
    pub translation: [f64; 3],
    pub pose_reference: u8,
    pub rig_name: String,
}

impl SensorCalibration {
    pub fn is_camera(&self) -> bool {
        self.camera_model != 0
    }

    pub fn parse(content: &[u8]) -> Result<SensorCalibration> {
        let mut c = Cursor::new(content);
        let name = c.string()?;
        let modality = c.string()?;
        let camera_model = c.u8()?;
        let width_px = c.u32()?;
        let height_px = c.u32()?;
        let intr = c.f64s(4)?;
        let count = c.u8()? as usize;
        let distortion = c.f64s(count)?;
        let rot = c.f64s(4)?;
        let tr = c.f64s(3)?;
        let sensor = SensorCalibration {
            name,
            modality,
            camera_model,
            width_px,
            height_px,
            fx: intr[0],
            fy: intr[1],
            cx: intr[2],
            cy: intr[3],
            distortion,
            rotation: [rot[0], rot[1], rot[2], rot[3]],
            translation: [tr[0], tr[1], tr[2]],
            pose_reference: c.u8()?,
            rig_name: c.string()?,
        };
        sensor.check()?;
        Ok(sensor)
    }

    pub fn check(&self) -> Result<()> {
        let finite = |label: &str, value: f64| -> Result<()> {
            if value.is_finite() {
                Ok(())
            } else {
                Err(Error::Malformed(format!(
                    "sensor {:?}: {label} is {value}; every value must be finite",
                    self.name
                )))
            }
        };
        finite("fx", self.fx)?;
        finite("fy", self.fy)?;
        finite("cx", self.cx)?;
        finite("cy", self.cy)?;
        for (i, v) in self.distortion.iter().enumerate() {
            finite(&format!("distortion[{i}]"), *v)?;
        }
        for (i, v) in self.rotation.iter().enumerate() {
            finite(&format!("rotation[{i}]"), *v)?;
        }
        for (i, v) in self.translation.iter().enumerate() {
            finite(&format!("translation[{i}]"), *v)?;
        }

        let norm = self.rotation.iter().map(|v| v * v).sum::<f64>().sqrt();
        if !norm.is_finite() || norm == 0.0 {
            return Err(Error::Malformed(format!(
                "sensor {:?}: rotation quaternion has no direction (norm {norm})",
                self.name
            )));
        }

        if let Some(legal) = camera_model_coefficients(self.camera_model) {
            if !legal.contains(&self.distortion.len()) {
                return Err(Error::Malformed(format!(
                    "sensor {:?}: camera model {} defines {} distortion coefficients, \
                     the record carries {}",
                    self.name,
                    self.camera_model,
                    legal
                        .iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join(" or "),
                    self.distortion.len()
                )));
            }
        }

        if !self.is_camera() {
            for (label, nonzero) in [
                ("width_px", self.width_px != 0),
                ("height_px", self.height_px != 0),
                ("fx", self.fx != 0.0),
                ("fy", self.fy != 0.0),
                ("cx", self.cx != 0.0),
                ("cy", self.cy != 0.0),
            ] {
                if nonzero {
                    return Err(Error::Malformed(format!(
                        "sensor {:?} declares camera_model 0 but a non-zero {label}",
                        self.name
                    )));
                }
            }
        } else if self.fx == 0.0 || self.fy == 0.0 || self.width_px == 0 || self.height_px == 0 {
            return Err(Error::Malformed(format!(
                "sensor {:?} declares camera model {} but has a zero focal length or image size",
                self.name, self.camera_model
            )));
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.name);
        put_string(&mut body, &self.modality);
        put_u8(&mut body, self.camera_model);
        put_u32(&mut body, self.width_px);
        put_u32(&mut body, self.height_px);
        put_f64s(&mut body, &[self.fx, self.fy, self.cx, self.cy]);
        put_u8(&mut body, self.distortion.len() as u8);
        put_f64s(&mut body, &self.distortion);
        put_f64s(&mut body, &self.rotation);
        put_f64s(&mut body, &self.translation);
        put_u8(&mut body, self.pose_reference);
        put_string(&mut body, &self.rig_name);
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::SENSOR_CALIBRATION, &body);
        out
    }
}

/// The measured pose of the capture platform over the scene clock. Opcode `0x22`.
///
/// Not the [`Camera`] record, which is a viewing suggestion a reader may ignore. This is
/// where the sensors were, and a consumer doing analysis or simulation needs it to be
/// right rather than plausible.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RigTrajectory {
    pub name: String,
    pub interpolation: u8,
    pub times: Vec<f64>,
    pub rotations: Vec<[f64; 4]>,
    pub translations: Vec<[f64; 3]>,
}

impl RigTrajectory {
    pub fn sample_count(&self) -> usize {
        self.times.len()
    }

    pub fn parse(content: &[u8]) -> Result<RigTrajectory> {
        let mut c = Cursor::new(content);
        let mut trajectory = RigTrajectory {
            name: c.string()?,
            interpolation: c.u8()?,
            ..Default::default()
        };
        let count = c.u32()? as usize;
        // Bounded like the other count-prefixed records: a crafted count must not size an
        // allocation before the bytes behind it have been shown to exist.
        trajectory.times.reserve(count.min(1 << 16));
        trajectory.rotations.reserve(count.min(1 << 16));
        trajectory.translations.reserve(count.min(1 << 16));
        for _ in 0..count {
            trajectory.times.push(c.f64()?);
            let r = c.f64s(4)?;
            trajectory.rotations.push([r[0], r[1], r[2], r[3]]);
            let t = c.f64s(3)?;
            trajectory.translations.push([t[0], t[1], t[2]]);
        }
        trajectory.check()?;
        Ok(trajectory)
    }

    /// Refuse times that are not strictly increasing, naming the sample.
    ///
    /// Every interpolation rule is stated in terms of the interval a query lands in, and
    /// a repeated or reversed timestamp makes that interval ambiguous. There is no
    /// reading of such a trajectory that is merely approximate.
    pub fn check(&self) -> Result<()> {
        if !matches!(self.interpolation, TRAJECTORY_LINEAR | TRAJECTORY_STEP) {
            return Err(Error::Malformed(format!(
                "trajectory {:?} uses interpolation {}; this reader supports trajectory \
                 interpolation registry values 0 (linear) and 1 (step)",
                self.name, self.interpolation
            )));
        }
        for (i, t) in self.times.iter().enumerate() {
            if !t.is_finite() {
                return Err(Error::Malformed(format!(
                    "trajectory {:?}: sample {i} has a non-finite time ({t})",
                    self.name
                )));
            }
            if i > 0 && *t <= self.times[i - 1] {
                return Err(Error::Malformed(format!(
                    "trajectory {:?}: sample {i} is at t={t}, not after sample {} at t={}; \
                     times must strictly increase (section 5.15.4)",
                    self.name,
                    i - 1,
                    self.times[i - 1]
                )));
            }
        }
        for (i, q) in self.rotations.iter().enumerate() {
            let norm = q.iter().map(|v| v * v).sum::<f64>().sqrt();
            if !norm.is_finite() || norm == 0.0 {
                return Err(Error::Malformed(format!(
                    "trajectory {:?}: sample {i} rotation has no direction (norm {norm})",
                    self.name
                )));
            }
        }
        for (i, tr) in self.translations.iter().enumerate() {
            for (k, v) in tr.iter().enumerate() {
                if !v.is_finite() {
                    return Err(Error::Malformed(format!(
                        "trajectory {:?}: sample {i} translation[{k}] is {v}",
                        self.name
                    )));
                }
            }
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        put_string(&mut body, &self.name);
        put_u8(&mut body, self.interpolation);
        put_u32(&mut body, self.times.len() as u32);
        for i in 0..self.times.len() {
            put_f64(&mut body, self.times[i]);
            put_f64s(&mut body, &self.rotations[i]);
            put_f64s(&mut body, &self.translations[i]);
        }
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::RIG_TRAJECTORY, &body);
        out
    }
}

/// One object the file names. Everything here is advisory — no field moves a gaussian.
///
/// `anchor` is a representative point for a label or camera focus, not the transform pivot
/// (a track folds its pivot into its translation). `dynamics`, when present, is a coarse
/// constant-acceleration summary a consumer may read instead of a track; reconstruction
/// never reads it. `embedding`, when present, is the object's point in the file's one
/// text-aligned vector space.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObjectTableEntry {
    pub object_id: u32,
    pub label: String,
    pub anchor: [f32; 3],
    /// `(velocity, angular_velocity, acceleration)`, each a 3-vector, or `None`.
    pub dynamics: Option<([f32; 3], [f32; 3], [f32; 3])>,
    pub embedding: Option<Vec<f32>>,
}

/// The scene-wide table of objects. Opcode 0x24, one per file, front matter.
///
/// `embedding_dim` is declared once for the whole file: every embedding is a vector of
/// exactly this many `f32`, and `0` means the file declares no embedding space at all. A
/// per-entry flag then says whether an object carries a vector.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObjectTable {
    pub embedding_dim: u16,
    pub entries: Vec<ObjectTableEntry>,
}

impl ObjectTable {
    pub fn parse(content: &[u8]) -> Result<ObjectTable> {
        let mut c = Cursor::new(content);
        let count = c.u32()? as usize;
        let embedding_dim = c.u16()?;
        // Each entry has an id, an empty length-prefixed label, an anchor, the dynamics
        // flag, and (when an embedding space exists) the embedding-presence flag. Prove
        // the declared count can fit before allocating from it.
        let minimum_entry = 4 + 4 + 3 * 4 + 1 + usize::from(embedding_dim > 0);
        if count > c.remaining() / minimum_entry {
            return Err(Error::Truncated(format!(
                "ObjectTable declares {count} entries at content offset 0, but {} bytes remain \
                 after its header and each entry needs at least {minimum_entry}",
                c.remaining()
            )));
        }
        let mut table = ObjectTable {
            embedding_dim,
            entries: Vec::with_capacity(count),
        };
        for entry_index in 0..count {
            let object_id = c.u32()?;
            let label = c.string()?;
            let a = c.f32s(3)?;
            let mut entry = ObjectTableEntry {
                object_id,
                label,
                anchor: [a[0], a[1], a[2]],
                ..Default::default()
            };
            match c.u8()? {
                0 => {}
                1 => {
                    let v = c.f32s(3)?;
                    let w = c.f32s(3)?;
                    let acc = c.f32s(3)?;
                    entry.dynamics = Some((
                        [v[0], v[1], v[2]],
                        [w[0], w[1], w[2]],
                        [acc[0], acc[1], acc[2]],
                    ));
                }
                flag => {
                    return Err(Error::Malformed(format!(
                        "ObjectTable entry {entry_index} for object {object_id} has \
                         dynamics_present={flag}; expected 0 or 1"
                    )))
                }
            }
            if table.embedding_dim > 0 {
                match c.u8()? {
                    0 => {}
                    1 => {
                        let dimensions = table.embedding_dim as usize;
                        let bytes = dimensions * std::mem::size_of::<f32>();
                        if bytes > c.remaining() {
                            return Err(Error::Truncated(format!(
                                "ObjectTable entry {entry_index} for object {object_id} declares \
                                 an embedding of {dimensions} f32 values ({bytes} bytes), but {} \
                                 bytes remain",
                                c.remaining()
                            )));
                        }
                        entry.embedding = Some(c.f32s(dimensions)?);
                    }
                    flag => {
                        return Err(Error::Malformed(format!(
                            "ObjectTable entry {entry_index} for object {object_id} has \
                             has_embedding={flag}; expected 0 or 1"
                        )))
                    }
                }
            }
            table.entries.push(entry);
        }
        table.check()?;
        Ok(table)
    }

    /// Distinct object ids, and every stored float finite.
    ///
    /// A duplicate id makes every reference to that object ambiguous — the duplicate-name
    /// failure section 5.15.2 refuses for frames. A non-finite embedding is not a weak
    /// match, it poisons every cosine similarity computed against it.
    pub fn check(&self) -> Result<()> {
        let mut seen: HashSet<u32> = HashSet::with_capacity(self.entries.len());
        for e in &self.entries {
            if !seen.insert(e.object_id) {
                return Err(Error::Malformed(format!(
                    "two ObjectTable entries describe object {}; an object is referred to by id \
                     and nothing else (section 5.15.6)",
                    e.object_id
                )));
            }
            let check_finite = |vs: &[f32], what: &str| -> Result<()> {
                for (k, v) in vs.iter().enumerate() {
                    if !v.is_finite() {
                        return Err(Error::Malformed(format!(
                            "object {}: {what}[{k}] is {v}",
                            e.object_id
                        )));
                    }
                }
                Ok(())
            };
            check_finite(&e.anchor, "anchor")?;
            if let Some((v, w, a)) = &e.dynamics {
                check_finite(v, "velocity")?;
                check_finite(w, "angular_velocity")?;
                check_finite(a, "acceleration")?;
            }
            if let Some(embedding) = &e.embedding {
                if self.embedding_dim == 0 {
                    return Err(Error::Malformed(format!(
                        "object {} carries an embedding, but ObjectTable.embedding_dim is 0 and \
                         declares no embedding space",
                        e.object_id
                    )));
                }
                if embedding.len() != self.embedding_dim as usize {
                    return Err(Error::Malformed(format!(
                        "object {} embedding has {} values; ObjectTable.embedding_dim declares {}",
                        e.object_id,
                        embedding.len(),
                        self.embedding_dim
                    )));
                }
                check_finite(embedding, "embedding")?;
            }
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Result<Vec<u8>> {
        self.check()?;
        let mut body = Vec::new();
        put_u32(&mut body, self.entries.len() as u32);
        put_u16(&mut body, self.embedding_dim);
        for e in &self.entries {
            put_u32(&mut body, e.object_id);
            put_string(&mut body, &e.label);
            put_f32s(&mut body, &e.anchor);
            match &e.dynamics {
                None => put_u8(&mut body, 0),
                Some((v, w, a)) => {
                    put_u8(&mut body, 1);
                    put_f32s(&mut body, v);
                    put_f32s(&mut body, w);
                    put_f32s(&mut body, a);
                }
            }
            if self.embedding_dim > 0 {
                match &e.embedding {
                    None => put_u8(&mut body, 0),
                    Some(embedding) => {
                        put_u8(&mut body, 1);
                        put_f32s(&mut body, embedding);
                    }
                }
            }
        }
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::OBJECT_TABLE, &body);
        Ok(out)
    }
}

/// One object's rigid pose sampled over the scene clock. Opcode 0x25, front matter.
///
/// The Rig Trajectory of section 5.15.4 pointed at a scene object instead of the capture
/// platform: same strictly-increasing times, same clamp-never-extrapolate rule, same
/// shortest-arc slerp. It reuses the trajectory interpolation registry (0 linear, 1 step)
/// and the [`crate::provenance::pose_at`] machinery through the `PoseSampled` trait.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ObjectTrack {
    pub object_id: u32,
    pub interpolation: u8,
    pub times: Vec<f64>,
    pub rotations: Vec<[f64; 4]>,
    pub translations: Vec<[f64; 3]>,
}

impl ObjectTrack {
    pub fn sample_count(&self) -> usize {
        self.times.len()
    }

    pub fn parse(content: &[u8]) -> Result<ObjectTrack> {
        let mut c = Cursor::new(content);
        let mut track = ObjectTrack {
            object_id: c.u32()?,
            interpolation: c.u8()?,
            ..Default::default()
        };
        let count = c.u32()? as usize;
        const SAMPLE_BYTES: usize = 8 + 4 * 8 + 3 * 8;
        if count > c.remaining() / SAMPLE_BYTES {
            return Err(Error::Truncated(format!(
                "ObjectTrack for object {} declares {count} samples at content offset 5, but {} \
                 bytes remain after its header and each sample needs {SAMPLE_BYTES}",
                track.object_id,
                c.remaining()
            )));
        }
        track.times.reserve(count);
        track.rotations.reserve(count);
        track.translations.reserve(count);
        for _ in 0..count {
            track.times.push(c.f64()?);
            let r = c.f64s(4)?;
            track.rotations.push([r[0], r[1], r[2], r[3]]);
            let t = c.f64s(3)?;
            track.translations.push([t[0], t[1], t[2]]);
        }
        track.check()?;
        Ok(track)
    }

    /// The object-track rules: not the background, increasing times, real rotations.
    ///
    /// `object_id = 0` is "no object", and a track needs an object to move, so it is
    /// refused rather than treated as a whole-scene transform. The time and quaternion
    /// rules are section 5.15.4's, for the same reasons.
    pub fn check(&self) -> Result<()> {
        if self.object_id == 0 {
            return Err(Error::Malformed(
                "an ObjectTrack names object 0, which is background/unassigned; a track needs an \
                 object to move (section 5.15.6)"
                    .to_string(),
            ));
        }
        if !matches!(self.interpolation, TRAJECTORY_LINEAR | TRAJECTORY_STEP) {
            return Err(Error::Malformed(format!(
                "track for object {} uses interpolation {}; this reader supports trajectory \
                 interpolation registry values 0 (linear) and 1 (step)",
                self.object_id, self.interpolation
            )));
        }
        if self.rotations.len() != self.times.len() || self.translations.len() != self.times.len() {
            return Err(Error::Malformed(format!(
                "track for object {} has {} times, {} rotations, and {} translations; expected \
                 equal sample counts",
                self.object_id,
                self.times.len(),
                self.rotations.len(),
                self.translations.len()
            )));
        }
        for (i, t) in self.times.iter().enumerate() {
            if !t.is_finite() {
                return Err(Error::Malformed(format!(
                    "track for object {}: sample {i} has a non-finite time ({t})",
                    self.object_id
                )));
            }
            if i > 0 && *t <= self.times[i - 1] {
                return Err(Error::Malformed(format!(
                    "track for object {}: sample {i} is at t={t}, not after sample {} at t={}; \
                     times must strictly increase (section 5.15.4)",
                    self.object_id,
                    i - 1,
                    self.times[i - 1]
                )));
            }
        }
        for (i, q) in self.rotations.iter().enumerate() {
            let norm = q.iter().map(|v| v * v).sum::<f64>().sqrt();
            if !norm.is_finite() || norm == 0.0 {
                return Err(Error::Malformed(format!(
                    "track for object {}: sample {i} rotation has no direction (norm {norm})",
                    self.object_id
                )));
            }
        }
        for (i, tr) in self.translations.iter().enumerate() {
            for (k, v) in tr.iter().enumerate() {
                if !v.is_finite() {
                    return Err(Error::Malformed(format!(
                        "track for object {}: sample {i} translation[{k}] is {v}",
                        self.object_id
                    )));
                }
            }
        }
        Ok(())
    }

    pub fn encode(&self, trailer: &[u8]) -> Result<Vec<u8>> {
        self.check()?;
        let mut body = Vec::new();
        put_u32(&mut body, self.object_id);
        put_u8(&mut body, self.interpolation);
        put_u32(&mut body, self.times.len() as u32);
        for i in 0..self.times.len() {
            put_f64(&mut body, self.times[i]);
            put_f64s(&mut body, &self.rotations[i]);
            put_f64s(&mut body, &self.translations[i]);
        }
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::OBJECT_TRACK, &body);
        Ok(out)
    }
}
