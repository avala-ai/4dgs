// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Record bodies: one struct per record type, each able to read and write itself.
//!
//! Every `parse` here reads the fields it knows and stops. It never asserts that the
//! record ended where its knowledge did, because a newer writer may have appended fields —
//! that is the compatibility rule, and honouring it is one line per record rather than a
//! policy nobody remembers.

use std::collections::BTreeMap;

use crate::error::Result;
use crate::opcode as op;
use crate::serialization::{
    put_blob, put_f64, put_f64s, put_record, put_str_map, put_string, put_u32, put_u64, put_u8,
    Cursor,
};

pub const FLAG_HAS_AUDIO: u8 = 1 << 0;
pub const FLAG_CHUNKS_COMPRESSED: u8 = 1 << 1;

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
    /// This is the whole audio-discovery rule, and it is why a scene without a soundtrack
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
}

impl Quantization {
    pub fn parse(content: &[u8]) -> Result<Quantization> {
        let mut c = Cursor::new(content);
        let scheme = c.string()?;
        let pos_origin = c.f64s(3)?;
        let steps = c.f64s(8)?;
        Ok(Quantization {
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
        })
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
        body.extend_from_slice(trailer);
        let mut out = Vec::new();
        put_record(&mut out, op::QUANTIZATION, &body);
        out
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

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChunkIndexEntry {
    pub t0: f64,
    pub t1: f64,
    pub chunk_offset: u64,
    pub chunk_length: u64,
    pub gaussian_count: u32,
    /// `(band, offset, length)`, each framing a whole SH Band Stream record.
    pub bands: Vec<(u8, u64, u64)>,
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
            bands: Vec::new(),
        };
        let bands = c.u32()? as usize;
        entry.bands.reserve(bands.min(1 << 12));
        for _ in 0..bands {
            let band = c.u8()?;
            let offset = c.u64()?;
            let length = c.u64()?;
            entry.bands.push((band, offset, length));
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
