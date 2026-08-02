// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Stream codecs.
//!
//! Every compressed payload in the format declares the size it decompresses to before it
//! is decompressed, so decoding allocates exactly that and never grows to fit whatever
//! the payload turns out to hold. A payload that expands past its declaration is a
//! corrupt file, not a bigger buffer.

use std::io::Read;

use crate::error::{Error, Result};

pub const DEFLATE: u8 = 0;
pub const ZSTD: u8 = 1;

/// The registry name for a numeric stream codec, for error messages and for the Chunk
/// record's `compression` field.
pub fn codec_name(codec: u8) -> String {
    match codec {
        DEFLATE => "deflate".to_string(),
        ZSTD => "zstd".to_string(),
        other => format!("codec {other}"),
    }
}

/// The numeric codec a Chunk's `compression` string names, if this build knows it.
pub fn codec_from_name(name: &str) -> Option<u8> {
    match name {
        "deflate" => Some(DEFLATE),
        "zstd" => Some(ZSTD),
        _ => None,
    }
}

/// Decompress exactly `expected` bytes, refusing anything that produces more or fewer.
pub fn decompress(body: &[u8], codec: u8, expected: usize) -> Result<Vec<u8>> {
    match codec {
        DEFLATE => exact(flate2::read::ZlibDecoder::new(body), expected, "deflate"),
        ZSTD => decompress_zstd(body, expected),
        // Named, because this is the one a file can trigger: an unknown codec id on a
        // stream is a conforming file this build cannot read. Its twin below is the
        // *encoder* refusing its own argument, which no file can cause and the refusal
        // table therefore does not name.
        other => Err(Error::refused(
            crate::error::refusal::UNKNOWN_STREAM_CODEC,
            crate::error::RefusalKind::UnsupportedCodec,
            format!("stream codec {other} is not a codec this build implements"),
        )),
    }
}

#[cfg(feature = "zstd")]
fn decompress_zstd(body: &[u8], expected: usize) -> Result<Vec<u8>> {
    let decoder = zstd::stream::read::Decoder::new(body)
        .map_err(|e| Error::Malformed(format!("zstd stream could not be opened: {e}")))?;
    exact(decoder, expected, "zstd")
}

#[cfg(not(feature = "zstd"))]
fn decompress_zstd(_body: &[u8], _expected: usize) -> Result<Vec<u8>> {
    Err(Error::UnsupportedCodec(
        "this file uses zstd streams; rebuild the crate with the 'zstd' feature".into(),
    ))
}

/// Read exactly `expected` bytes out of a decompressor and insist there are no more.
///
/// Both halves matter. Short output means the payload was cut; long output means the
/// stream header's declared size is not the size of what it holds, and a reader that
/// silently accepted either would be sizing arrays from a number the file contradicts.
/// The buffer grows as output actually arrives rather than being sized from `expected`, so
/// a header that claims far more than its payload can produce costs nothing until the
/// bytes exist. Sizing up front would let a few hundred compressed bytes reserve hundreds
/// of megabytes, which is the same allocation bug the record reader had.
fn exact<R: Read>(mut source: R, expected: usize, name: &str) -> Result<Vec<u8>> {
    const BLOCK: usize = 64 * 1024;
    let mut out: Vec<u8> = Vec::new();
    let mut block = vec![0u8; BLOCK.min(expected.max(1))];
    while out.len() < expected {
        let want = (expected - out.len()).min(block.len());
        let got = source.read(&mut block[..want]).map_err(|e| {
            Error::Malformed(format!("a {name} stream could not be decompressed: {e}"))
        })?;
        if got == 0 {
            return Err(Error::Truncated(format!(
                "a {name} stream ended after {} bytes; the header declared {expected}",
                out.len()
            )));
        }
        out.extend_from_slice(&block[..got]);
    }
    let mut spare = [0u8; 1];
    match source.read(&mut spare) {
        Ok(0) => Ok(out),
        Ok(_) => Err(Error::Malformed(format!(
            "a {name} stream decompressed to more than the {expected} bytes its header declared"
        ))),
        Err(e) => Err(Error::Malformed(format!(
            "a {name} stream could not be decompressed: {e}"
        ))),
    }
}

/// Compress with `codec` at `level`. Used by the encoder only.
pub fn compress(raw: &[u8], codec: u8, level: u32) -> Result<Vec<u8>> {
    match codec {
        DEFLATE => {
            use std::io::Write;
            let mut encoder =
                flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(level.min(9)));
            encoder
                .write_all(raw)
                .map_err(|e| Error::Malformed(format!("deflate failed: {e}")))?;
            encoder
                .finish()
                .map_err(|e| Error::Malformed(format!("deflate failed: {e}")))
        }
        ZSTD => compress_zstd(raw, level),
        other => Err(Error::UnsupportedCodec(format!(
            "stream codec {other} is not a codec this build implements"
        ))),
    }
}

#[cfg(feature = "zstd")]
fn compress_zstd(raw: &[u8], level: u32) -> Result<Vec<u8>> {
    zstd::stream::encode_all(raw, level.min(19) as i32)
        .map_err(|e| Error::Malformed(format!("zstd compression failed: {e}")))
}

#[cfg(not(feature = "zstd"))]
fn compress_zstd(_raw: &[u8], _level: u32) -> Result<Vec<u8>> {
    Err(Error::UnsupportedCodec(
        "zstd encoding needs the crate's 'zstd' feature".into(),
    ))
}
