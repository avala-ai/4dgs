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
use crate::serialization::MAX_STREAM_BYTES;

pub const DEFLATE: u8 = 0;
pub const ZSTD: u8 = 1;

/// Maximum zstd back-reference distance accepted by the streaming decoder: 8 MiB.
///
/// Zstd otherwise chooses its internal window from an attacker-controlled frame header.
/// Eight MiB is the interoperability floor recommended by zstd itself and is independent
/// of the stream's declared output allocation, which is bounded separately.
const ZSTD_WINDOW_LOG_MAX: u32 = 23;

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

/// Refuse an unsupported stream codec before a decoder sizes or consumes its payload.
///
/// Stream callers and fixed-header validators use this header-only check to preserve the
/// format's error taxonomy: an unknown-but-legal codec is a named capability refusal,
/// while structural fields meaningful to this build remain malformed-file errors. Empty
/// Attribute Streams still declare codec semantics even though they have no payload.
pub fn check_decoder(codec: u8) -> Result<()> {
    match codec {
        DEFLATE => Ok(()),
        ZSTD => check_zstd_decoder(),
        other => Err(Error::refused(
            crate::error::refusal::UNKNOWN_STREAM_CODEC,
            crate::error::RefusalKind::UnsupportedCodec,
            format!("stream codec {other} is not a codec this build implements"),
        )),
    }
}

#[cfg(feature = "zstd")]
fn check_zstd_decoder() -> Result<()> {
    Ok(())
}

#[cfg(not(feature = "zstd"))]
fn check_zstd_decoder() -> Result<()> {
    Err(Error::refused(
        crate::error::refusal::UNKNOWN_STREAM_CODEC,
        crate::error::RefusalKind::UnsupportedCodec,
        "this file uses zstd streams; rebuild the crate with the 'zstd' feature".into(),
    ))
}

/// Decompress exactly `expected` bytes, refusing anything that produces more or fewer.
pub fn decompress(body: &[u8], codec: u8, expected: usize) -> Result<Vec<u8>> {
    check_decoder(codec)?;
    if expected as u64 > MAX_STREAM_BYTES {
        return Err(Error::UnsupportedOperation(format!(
            "a compressed stream declares {expected} output bytes, past the {MAX_STREAM_BYTES} byte decoded-stream ceiling"
        )));
    }
    match codec {
        DEFLATE => exact(flate2::read::ZlibDecoder::new(body), expected, "deflate"),
        ZSTD => decompress_zstd(body, expected),
        _ => unreachable!("check_decoder accepted only a defined codec"),
    }
}

#[cfg(feature = "zstd")]
fn decompress_zstd(body: &[u8], expected: usize) -> Result<Vec<u8>> {
    let mut decoder = zstd::stream::read::Decoder::new(body)
        .map_err(|e| Error::Malformed(format!("zstd stream could not be opened: {e}")))?;
    decoder
        .window_log_max(ZSTD_WINDOW_LOG_MAX)
        .map_err(|e| {
            Error::UnsupportedOperation(format!(
                "the zstd decoder could not enforce its 2^{ZSTD_WINDOW_LOG_MAX}-byte window ceiling: {e}"
            ))
        })?;
    exact(decoder, expected, "zstd")
}

#[cfg(not(feature = "zstd"))]
fn decompress_zstd(_body: &[u8], _expected: usize) -> Result<Vec<u8>> {
    // Named, like the unknown-id arm above. This is the *default* build's answer to a
    // legal zstd file, so leaving it unnamed would mean the codec a stock Rust build
    // refuses most often is the one it cannot name. The identifier is the same one:
    // from the file's side both are "this reader does not implement my stream codec",
    // and which of the two it is belongs in the message, not in the identifier.
    Err(Error::refused(
        crate::error::refusal::UNKNOWN_STREAM_CODEC,
        crate::error::RefusalKind::UnsupportedCodec,
        "this file uses zstd streams; rebuild the crate with the 'zstd' feature".into(),
    ))
}

/// Read exactly `expected` bytes out of a decompressor and insist there are no more.
///
/// Both halves matter. Short output means the payload was cut; long output means the
/// stream header's declared size is not the size of what it holds, and a reader that
/// silently accepted either would be sizing arrays from a number the file contradicts.
/// The public decoder validates `expected` against the decoded-stream ceiling, but it
/// cannot know a caller's larger live working set. Grow only after bytes have actually
/// decompressed: a tiny malformed payload with a large declaration must not materialize
/// that entire declaration before discovering it is short. Geometric targets keep the
/// number of reallocations logarithmic, and every target remains within `expected`.
fn exact<R: Read>(mut source: R, expected: usize, name: &str) -> Result<Vec<u8>> {
    const BLOCK: usize = 64 * 1024;
    let mut out: Vec<u8> = Vec::new();
    let mut block = [0u8; BLOCK];
    while out.len() < expected {
        let want = (expected - out.len()).min(BLOCK);
        let got = source
            .read(&mut block[..want])
            .map_err(|e| decompression_read_error(name, e, out.len(), expected))?;
        if got == 0 {
            return Err(Error::Truncated(format!(
                "a {name} stream ended after {} bytes; the header declared {expected}",
                out.len()
            )));
        }
        let required = out.len().checked_add(got).ok_or_else(|| {
            Error::UnsupportedOperation(format!("a {name} stream output length overflows"))
        })?;
        if required > out.capacity() {
            let target = if out.capacity() == 0 {
                BLOCK.min(expected)
            } else {
                out.capacity().saturating_mul(2).min(expected).max(required)
            };
            out.try_reserve_exact(target - out.len()).map_err(|e| {
                Error::UnsupportedOperation(format!(
                    "a {name} stream could not reserve its next {target} validated output bytes: {e}"
                ))
            })?;
        }
        out.extend_from_slice(&block[..got]);
    }
    let mut spare = [0u8; 1];
    match source.read(&mut spare) {
        Ok(0) => Ok(out),
        Ok(_) => Err(Error::Malformed(format!(
            "a {name} stream decompressed to more than the {expected} bytes its header declared"
        ))),
        Err(e) => Err(decompression_read_error(name, e, out.len(), expected)),
    }
}

fn decompression_read_error(
    name: &str,
    error: std::io::Error,
    decoded: usize,
    expected: usize,
) -> Error {
    if error.kind() == std::io::ErrorKind::UnexpectedEof {
        return Error::Truncated(format!(
            "a {name} stream ended after {decoded} bytes before its compressed framing completed; the header declared {expected}"
        ));
    }
    if name == "zstd"
        && error
            .to_string()
            .contains("Frame requires too much memory for decoding")
    {
        return Error::UnsupportedOperation(format!(
            "a zstd frame requires a window past the 2^{ZSTD_WINDOW_LOG_MAX}-byte decoder ceiling"
        ));
    }
    Error::Malformed(format!(
        "a {name} stream could not be decompressed: {error}"
    ))
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

#[cfg(test)]
mod tests {
    use super::*;

    struct ImmediateEof {
        largest_request: usize,
    }

    impl Read for ImmediateEof {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.largest_request = self.largest_request.max(bytes.len());
            Ok(0)
        }
    }

    #[test]
    fn exact_output_keeps_the_validated_non_power_of_two_capacity() {
        const EXPECTED: usize = 65_537;
        let bytes = vec![0x5a; EXPECTED];
        let out = exact(std::io::Cursor::new(bytes), EXPECTED, "identity")
            .expect("an exact identity stream");

        assert_eq!(out.len(), EXPECTED);
        assert_eq!(
            out.capacity(),
            EXPECTED,
            "the decoder must not geometrically reserve beyond its validated output size"
        );
    }

    #[test]
    fn a_short_stream_does_not_allocate_or_request_its_large_declaration() {
        let mut source = ImmediateEof { largest_request: 0 };
        let error = exact(&mut source, MAX_STREAM_BYTES as usize, "identity").unwrap_err();
        assert!(matches!(error, Error::Truncated(_)), "{error}");
        assert_eq!(source.largest_request, 64 * 1024);
    }

    #[test]
    fn the_public_decoder_enforces_the_format_stream_ceiling() {
        let error = decompress(&[], DEFLATE, MAX_STREAM_BYTES as usize + 1).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(
            error.to_string().contains("decoded-stream ceiling"),
            "{error}"
        );
    }

    #[test]
    fn incomplete_compressed_framing_is_truncated() {
        let encoded = compress(&[0x5a], DEFLATE, 6).expect("one-byte deflate stream");
        let error = decompress(&encoded[..encoded.len() - 1], DEFLATE, 1).unwrap_err();

        assert!(matches!(error, Error::Truncated(_)), "{error}");
        assert!(error.to_string().contains("header declared 1"), "{error}");
    }

    #[cfg(feature = "zstd")]
    #[test]
    fn zstd_frames_past_the_fixed_window_are_resource_refusals() {
        use std::io::Write;

        // Leave the source size unpledged so zstd writes the configured 16 MiB
        // streaming-window descriptor even though this fixture's payload stays tiny.
        let raw = vec![0u8; 1_024];
        let mut encoder = zstd::stream::Encoder::new(Vec::new(), 1).expect("zstd encoder");
        encoder
            .window_log(ZSTD_WINDOW_LOG_MAX + 1)
            .expect("hostile window");
        encoder.write_all(&raw).expect("zstd input");
        let encoded = encoder.finish().expect("zstd frame");

        let error = decompress(&encoded, ZSTD, raw.len()).unwrap_err();
        assert!(matches!(error, Error::UnsupportedOperation(_)), "{error}");
        assert!(error.to_string().contains("window"), "{error}");
        assert!(
            error
                .to_string()
                .contains(&format!("2^{ZSTD_WINDOW_LOG_MAX}")),
            "{error}"
        );
    }
}
