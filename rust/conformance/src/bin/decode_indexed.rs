// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Conformance runner: indexed decode.
//!
//! Reads the Footer, then the index, then each chunk by byte range — the path a seeking
//! client takes — and produces the same canonical JSON the streamed runner does. Agreeing
//! with itself across two very different read paths is most of what makes an indexed
//! implementation trustworthy.

use std::collections::BTreeMap;
use std::process::ExitCode;

use fourdgs::indexed_reader::{
    open_indexed, read_attachments, read_audio_sources, read_camera, read_chunk, read_objects,
    IndexedScene,
};
use fourdgs::readable::{FileReadable, Readable};
use fourdgs::records::ChunkIndexEntry;
use fourdgs_conformance::{summarize, Extras};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: decode_indexed <file.4dgs>");
        return ExitCode::from(2);
    }
    match run(&args[1]) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// A readable that records what it transferred, so a claim about byte ranges can be checked
/// against the bytes that actually moved.
struct Counting<R: Readable> {
    inner: R,
    bytes_read: u64,
}

impl<R: Readable> Readable for Counting<R> {
    fn size(&mut self) -> fourdgs::Result<u64> {
        self.inner.size()
    }

    fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>> {
        self.bytes_read += length;
        self.inner.read(offset, length)
    }
}

fn run(path: &str) -> Result<String, String> {
    let mut source = Counting {
        inner: FileReadable::open(path).map_err(|e| format!("{path}: {e}"))?,
        bytes_read: 0,
    };
    let scene = open_indexed(&mut source).map_err(|e| format!("{path}: {e}"))?;

    let mut chunks = Vec::with_capacity(scene.index.len());
    for entry in &scene.index {
        chunks.push(read_chunk(&mut source, &scene, entry, 3).map_err(|e| e.to_string())?);
    }
    let audio_sources = read_audio_sources(&mut source, &scene).map_err(|e| e.to_string())?;
    let camera = read_camera(&mut source, &scene).map_err(|e| e.to_string())?;
    let metadata =
        fourdgs::indexed_reader::read_metadata(&mut source, &scene).map_err(|e| e.to_string())?;
    let attachments = read_attachments(&mut source, &scene).map_err(|e| e.to_string())?;
    // Framed at open, fetched here — the same contract the camera and the attachments
    // have, and the reason no Header flag announces the family.
    let provenance =
        fourdgs::indexed_reader::read_provenance(&mut source, &scene).map_err(|e| e.to_string())?;
    let objects = read_objects(&mut source, &scene).map_err(|e| e.to_string())?;
    check_band_skipping(&mut source, &scene)?;

    let bands: Vec<BTreeMap<u8, fourdgs::stream::DecodedStream>> =
        chunks.iter().map(|c| c.bands.clone()).collect();
    let gaussians =
        fourdgs::stream_reader::assemble(&chunks, &bands, &scene.windows, &scene.header)
            .map_err(|e| e.to_string())?;

    let intervals: Vec<(f64, f64)> = scene.index.iter().map(|e| (e.t0, e.t1)).collect();
    summarize(
        &scene.header,
        &gaussians,
        &audio_sources,
        &intervals,
        &Extras {
            camera: camera.as_ref(),
            metadata: &metadata,
            attachments: &attachments,
            statistics: scene.statistics.as_ref(),
            summary_offsets: &scene.summary_offsets,
            summary_crc_ok: scene.summary_crc_ok,
            provenance: Some(&provenance),
            objects: Some(&objects),
        },
    )
    .map_err(|e| e.to_string())
}

/// A reader that has capped its SH degree never transfers the bands above it.
///
/// Counted at the transport, because that is the claim: not that the coefficients are
/// dropped after arriving, but that their bytes were never asked for.
fn check_band_skipping<R: Readable>(
    source: &mut Counting<R>,
    scene: &IndexedScene,
) -> Result<(), String> {
    for entry in &scene.index {
        if entry.bands.is_empty() {
            continue;
        }
        let mut caps = vec![0u8];
        caps.extend(entry.bands.iter().map(|(band, _, _)| *band));
        for cap in caps {
            let before = source.bytes_read;
            read_chunk(source, scene, entry, cap).map_err(|e| e.to_string())?;
            let moved = source.bytes_read - before;
            let wanted = wanted_bytes(entry, cap);
            if moved != wanted {
                return Err(format!(
                    "reading a chunk with max_sh_band={cap} transferred {moved} bytes, the index says {wanted}"
                ));
            }
        }
    }
    Ok(())
}

fn wanted_bytes(entry: &ChunkIndexEntry, cap: u8) -> u64 {
    entry.chunk_length
        + entry
            .bands
            .iter()
            .filter(|(band, _, _)| *band <= cap)
            .map(|(_, _, length)| *length)
            .sum::<u64>()
}
