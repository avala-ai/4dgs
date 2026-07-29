// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! One reader over both read paths.
//!
//! A consumer usually does not want to choose between streamed and indexed decoding; it
//! wants the gaussians an instant needs, from whatever the file happens to be. This type
//! picks the indexed path when the file has an index and falls back to a front-to-back
//! read when it does not — which is exactly what the specification says a reader must do
//! when `summary_start` is 0.
//!
//! Both paths remain first-class and directly usable: this is a convenience over them,
//! not a replacement for either.

use std::collections::BTreeMap;
use std::io::Read;

use crate::chunk::DecodedChunk;
use crate::error::{Error, Result};
use crate::indexed_reader::{self, IndexedScene};
use crate::model::GaussianSet;
use crate::readable::Readable;
use crate::records as rec;
use crate::stream_reader::{self, Scene};

/// Which read path a scene was opened on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The file carries an index and an instant costs only the chunks it names.
    Indexed,
    /// The file declares no index, so it is read front to back (spec §5.2).
    Streamed,
}

/// A scene opened for reading, over either path.
pub struct SceneReader<R: Readable> {
    source: R,
    mode: Mode,
    indexed: Option<IndexedScene>,
    streamed: Option<Scene>,
    /// The gaussians currently resident. `state_at` indices are indices into this.
    loaded: GaussianSet,
    loaded_band: u8,
    loaded_key: Option<LoadKey>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum LoadKey {
    All,
    At(u64),
}

impl<R: Readable> SceneReader<R> {
    /// Open a scene, using the index when the file has one.
    pub fn open(mut source: R) -> Result<SceneReader<R>> {
        match indexed_reader::open_indexed(&mut source) {
            Ok(scene) if !scene.index.is_empty() => Ok(SceneReader {
                source,
                mode: Mode::Indexed,
                indexed: Some(scene),
                streamed: None,
                loaded: GaussianSet::default(),
                loaded_band: 0,
                loaded_key: None,
            }),
            // No index, or an index-less file the indexed open could not make sense of:
            // a front-to-back read is the defined answer, not a failure.
            _ => {
                let scene = stream_reader::read_from(
                    SequentialSource::new(&mut source),
                    &stream_reader::ReadOptions::default(),
                )?;
                let loaded = scene.gaussians.clone();
                Ok(SceneReader {
                    source,
                    mode: Mode::Streamed,
                    indexed: None,
                    streamed: Some(scene),
                    loaded,
                    loaded_band: 3,
                    loaded_key: Some(LoadKey::All),
                })
            }
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn header(&self) -> &rec::Header {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => &s.header,
            (_, Some(s)) => &s.header,
            _ => unreachable!("a reader is opened on exactly one path"),
        }
    }

    pub fn quantization(&self) -> &rec::Quantization {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => &s.quantization,
            (_, Some(s)) => &s.quantization,
            _ => unreachable!("a reader is opened on exactly one path"),
        }
    }

    pub fn windows(&self) -> &[(f64, f64)] {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => &s.windows,
            (_, Some(s)) => &s.windows,
            _ => unreachable!("a reader is opened on exactly one path"),
        }
    }

    pub fn chunk_index(&self) -> &[rec::ChunkIndexEntry] {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => &s.index,
            (_, Some(s)) => &s.chunk_index,
            _ => unreachable!("a reader is opened on exactly one path"),
        }
    }

    pub fn statistics(&self) -> Option<&rec::Statistics> {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => s.statistics.as_ref(),
            (_, Some(s)) => s.statistics.as_ref(),
            _ => None,
        }
    }

    pub fn summary_crc_ok(&self) -> Option<bool> {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => s.summary_crc_ok,
            (_, Some(s)) => s.summary_crc_ok,
            _ => None,
        }
    }

    /// Answered from the Header alone — no probing, no speculative range request.
    pub fn has_audio(&self) -> bool {
        self.header().has_audio()
    }

    /// The audio codec's registry name, or `None` when the scene has no track.
    pub fn audio_codec(&self) -> Option<&str> {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => s.audio_codec.as_deref(),
            (_, Some(s)) => s.audio.as_ref().map(|a| a.codec.as_str()),
            _ => None,
        }
    }

    /// The track's length in bytes, without fetching it.
    pub fn audio_len(&self) -> Option<u64> {
        match (&self.indexed, &self.streamed) {
            (Some(s), _) => s.audio_range.map(|_| self.audio_declared_len()),
            (_, Some(s)) => s.audio.as_ref().map(|a| a.data.len() as u64),
            _ => None,
        }
    }

    fn audio_declared_len(&self) -> u64 {
        // The Audio record is `string codec`, `f64 start_sec`, then `bytes data`, so the
        // track is the record minus its framing and those two fields. Computed rather than
        // fetched: a caller asking how big the audio is has not asked for the audio.
        let scene = self.indexed.as_ref().expect("indexed path");
        let (_, total) = scene.audio_range.expect("audio present");
        let codec_len = scene.audio_codec.as_ref().map_or(0, |c| c.len()) as u64;
        total
            .saturating_sub(crate::serialization::RECORD_HEADER_SIZE as u64 + 4 + codec_len + 8 + 8)
    }

    /// The embedded track, fetched independently of any gaussian data. `None` when the
    /// scene has none — a normal value, never an error.
    pub fn read_audio(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(scene) = &self.indexed {
            return indexed_reader::read_audio(&mut self.source, scene);
        }
        Ok(self
            .streamed
            .as_ref()
            .and_then(|s| s.audio.as_ref())
            .map(|a| a.data.clone()))
    }

    /// A byte range of the embedded track, for a consumer that streams it rather than
    /// holding it. Offsets are relative to the track, not to the file.
    pub fn read_audio_range(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        if let Some(scene) = &self.indexed {
            let (record_at, total) = scene
                .audio_range
                .ok_or_else(|| Error::Malformed("this scene has no audio track".into()))?;
            let codec_len = scene.audio_codec.as_ref().map_or(0, |c| c.len()) as u64;
            let data_at =
                record_at + crate::serialization::RECORD_HEADER_SIZE as u64 + 4 + codec_len + 8 + 8;
            let data_len = (record_at + total).saturating_sub(data_at);
            let end = offset.checked_add(length).ok_or_else(|| {
                Error::Malformed(format!("audio range [{offset}, +{length}) overflows"))
            })?;
            if end > data_len {
                return Err(Error::Malformed(format!(
                    "audio range [{offset}, {end}) is outside the {data_len}-byte track"
                )));
            }
            return self.source.read(data_at + offset, length);
        }
        let track = self
            .streamed
            .as_ref()
            .and_then(|s| s.audio.as_ref())
            .ok_or_else(|| Error::Malformed("this scene has no audio track".into()))?;
        let start = usize::try_from(offset).unwrap_or(usize::MAX);
        let end = start.saturating_add(usize::try_from(length).unwrap_or(usize::MAX));
        if end > track.data.len() {
            return Err(Error::Malformed(format!(
                "audio range [{start}, {end}) is outside the {}-byte track",
                track.data.len()
            )));
        }
        Ok(track.data[start..end].to_vec())
    }

    pub fn camera(&mut self) -> Result<Option<rec::Camera>> {
        if let Some(scene) = &self.indexed {
            return indexed_reader::read_camera(&mut self.source, scene);
        }
        Ok(self.streamed.as_ref().and_then(|s| s.camera.clone()))
    }

    pub fn metadata(&mut self) -> Result<Vec<rec::Metadata>> {
        if let Some(scene) = &self.indexed {
            return indexed_reader::read_metadata(&mut self.source, scene);
        }
        Ok(self
            .streamed
            .as_ref()
            .map(|s| s.metadata.clone())
            .unwrap_or_default())
    }

    pub fn attachments(&mut self) -> Result<Vec<rec::Attachment>> {
        if let Some(scene) = &self.indexed {
            return indexed_reader::read_attachments(&mut self.source, scene);
        }
        Ok(self
            .streamed
            .as_ref()
            .map(|s| s.attachments.clone())
            .unwrap_or_default())
    }

    /// Decode every chunk. Use `load_at` when only one instant is wanted.
    pub fn load_all(&mut self, max_sh_band: u8) -> Result<&GaussianSet> {
        self.load(LoadKey::All, max_sh_band)
    }

    /// Decode only the chunks the seek rule names for `t`.
    pub fn load_at(&mut self, t: f64, max_sh_band: u8) -> Result<&GaussianSet> {
        self.load(LoadKey::At(t.to_bits()), max_sh_band)
    }

    /// The gaussians currently resident.
    pub fn loaded(&self) -> &GaussianSet {
        &self.loaded
    }

    /// Reconstructed state at `t` over whatever is currently resident. Indices index into
    /// `loaded()`.
    pub fn state_at(&mut self, t: f64, max_sh_band: u8) -> Result<crate::model::StateAt> {
        let cutoff = self.header().cutoff;
        self.load_at(t, max_sh_band)?;
        Ok(self.loaded.state_at(t, cutoff))
    }

    fn load(&mut self, key: LoadKey, max_sh_band: u8) -> Result<&GaussianSet> {
        if self.loaded_key == Some(key) && self.loaded_band >= max_sh_band {
            return Ok(&self.loaded);
        }
        if self.mode == Mode::Streamed {
            // A file with no index has already been read front to back; there is no
            // cheaper subset to fetch, and the seek rule has nothing to seek with.
            self.loaded_key = Some(key);
            return Ok(&self.loaded);
        }
        let scene = self.indexed.as_ref().expect("indexed path");
        let wanted: Vec<rec::ChunkIndexEntry> = match key {
            LoadKey::All => scene.index.clone(),
            LoadKey::At(bits) => {
                let t = f64::from_bits(bits);
                scene
                    .index
                    .iter()
                    .filter(|e| e.covers(t))
                    .cloned()
                    .collect()
            }
        };
        let scene = self.indexed.as_ref().expect("indexed path");
        let mut chunks: Vec<DecodedChunk> = Vec::with_capacity(wanted.len());
        for entry in &wanted {
            chunks.push(indexed_reader::read_chunk(
                &mut self.source,
                scene,
                entry,
                max_sh_band,
            )?);
        }
        let bands: Vec<BTreeMap<u8, crate::stream::DecodedStream>> =
            chunks.iter().map(|c| c.bands.clone()).collect();
        self.loaded = stream_reader::assemble(&chunks, &bands, &scene.windows, &scene.header)?;
        self.loaded_band = max_sh_band;
        self.loaded_key = Some(key);
        Ok(&self.loaded)
    }
}

/// An `io::Read` over a `Readable`, so the streamed path can run on a byte-range source.
///
/// Reads a bounded block at a time; nothing here holds the resource.
struct SequentialSource<'a, R: Readable + ?Sized> {
    source: &'a mut R,
    at: u64,
    size: u64,
    block: Vec<u8>,
    block_at: usize,
}

const SEQUENTIAL_BLOCK: u64 = 64 * 1024;

impl<'a, R: Readable + ?Sized> SequentialSource<'a, R> {
    fn new(source: &'a mut R) -> SequentialSource<'a, R> {
        let size = source.size().unwrap_or(0);
        SequentialSource {
            source,
            at: 0,
            size,
            block: Vec::new(),
            block_at: 0,
        }
    }
}

impl<R: Readable + ?Sized> Read for SequentialSource<'_, R> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.block_at >= self.block.len() {
            if self.at >= self.size {
                return Ok(0);
            }
            let want = SEQUENTIAL_BLOCK.min(self.size - self.at);
            self.block = self
                .source
                .read(self.at, want)
                .map_err(|e| std::io::Error::other(e.to_string()))?;
            self.block_at = 0;
            self.at += want;
        }
        let n = out.len().min(self.block.len() - self.block_at);
        out[..n].copy_from_slice(&self.block[self.block_at..self.block_at + n]);
        self.block_at += n;
        Ok(n)
    }
}
