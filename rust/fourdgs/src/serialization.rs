// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Primitives: the magic, record framing, and the scalar reads everything is built from.
//!
//! Everything on the wire goes through this module, so a reader only has to trust one
//! implementation of "read a length-prefixed thing without walking off the end". The
//! framing rule the format depends on is enforced here rather than remembered by callers:
//! every record carries its own length, so an unknown opcode is skipped by arithmetic
//! instead of by guesswork, and a record that has grown fields a reader does not know
//! about is still exactly as long as it says it is.

use std::collections::BTreeMap;

use crate::error::{Error, Result};

/// `0x89 4 D G S 1 CR LF`. The high bit stops byte-oriented tooling treating the file as
/// text; the `1` is the major version; the CR LF catches transports that mangle line
/// endings, which is a real failure mode for binary payloads served as text.
pub const MAGIC: [u8; 8] = [0x89, b'4', b'D', b'G', b'S', b'1', 0x0D, 0x0A];

/// The major version this build implements.
pub const VERSION: u8 = 1;

/// `u8` opcode plus `u64` content length.
pub const RECORD_HEADER_SIZE: usize = 9;

/// `u8` × 5, `u32`, `u64`.
pub const STREAM_HEADER_SIZE: usize = 17;

/// A crafted length must not be able to make a reader allocate before it has been checked
/// against the resource. Streams above this are refused outright.
pub const MAX_STREAM_BYTES: u64 = 512 * 1024 * 1024;

/// A bounds-checked read head over a byte buffer.
pub struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Cursor { buf, pos: 0 }
    }

    pub fn at(buf: &'a [u8], pos: usize) -> Self {
        Cursor { buf, pos }
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    pub fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    /// The unread tail, without advancing.
    pub fn rest(&self) -> &'a [u8] {
        &self.buf[self.pos.min(self.buf.len())..]
    }

    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).ok_or_else(|| {
            Error::Truncated(format!("a length of {n} at offset {} overflows", self.pos))
        })?;
        if end > self.buf.len() {
            return Err(Error::Truncated(format!(
                "need {n} bytes at offset {}, {} remain",
                self.pos,
                self.remaining()
            )));
        }
        let out = &self.buf[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn u16(&mut self) -> Result<u16> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    pub fn u32(&mut self) -> Result<u32> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64(&mut self) -> Result<u64> {
        let b = self.take(8)?;
        Ok(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub fn f64(&mut self) -> Result<f64> {
        let b = self.take(8)?;
        Ok(f64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub fn f64s(&mut self, n: usize) -> Result<Vec<f64>> {
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(self.f64()?);
        }
        Ok(out)
    }

    pub fn f32(&mut self) -> Result<f32> {
        let b = self.take(4)?;
        Ok(f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn f32s(&mut self, n: usize) -> Result<Vec<f32>> {
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(self.f32()?);
        }
        Ok(out)
    }

    /// `u32` byte length followed by that many UTF-8 bytes. Not NUL-terminated.
    pub fn string(&mut self) -> Result<String> {
        let n = self.u32()? as usize;
        let raw = self.take(n)?;
        String::from_utf8(raw.to_vec())
            .map_err(|e| Error::Malformed(format!("a string field is not valid UTF-8: {e}")))
    }

    /// `u64` byte length followed by that many bytes.
    pub fn blob(&mut self) -> Result<&'a [u8]> {
        let n = self.u64()?;
        let n = usize::try_from(n).map_err(|_| {
            Error::Truncated(format!(
                "a blob declares {n} bytes, more than this platform can address"
            ))
        })?;
        self.take(n)
    }

    /// `u32` byte length of the whole block, then repeated string key / string value
    /// pairs filling exactly that block.
    pub fn str_map(&mut self) -> Result<BTreeMap<String, String>> {
        let n = self.u32()? as usize;
        let block = self.take(n)?;
        let mut inner = Cursor::new(block);
        let mut out = BTreeMap::new();
        while inner.remaining() > 0 {
            let key = inner.string()?;
            let value = inner.string()?;
            out.insert(key, value);
        }
        Ok(out)
    }
}

/// One record's framing plus a borrow of its content.
pub struct RawRecord<'a> {
    pub opcode: u8,
    pub content: &'a [u8],
    /// Offset of the record's opcode byte within the enclosing buffer.
    pub offset: usize,
}

/// Read one record at the cursor.
pub fn read_record<'a>(cursor: &mut Cursor<'a>) -> Result<RawRecord<'a>> {
    let offset = cursor.position();
    let opcode = cursor.u8()?;
    let length = cursor.u64()?;
    let length = usize::try_from(length).map_err(|_| {
        Error::Truncated(format!(
            "record {} at offset {offset} declares {length} bytes, more than this platform can address",
            crate::opcode::name(opcode)
        ))
    })?;
    let content = cursor.take(length)?;
    Ok(RawRecord {
        opcode,
        content,
        offset,
    })
}

/// Every record in `buf` from `pos`, skipping nothing and interpreting nothing.
///
/// A caller that does not recognize an opcode simply ignores the record — that is the
/// whole forward-compatibility story, and it works because this loop never needs to know
/// what a record means to know how long it is.
pub struct Records<'a> {
    cursor: Cursor<'a>,
    stopped: bool,
}

impl<'a> Records<'a> {
    pub fn new(buf: &'a [u8], pos: usize) -> Self {
        Records {
            cursor: Cursor::at(buf, pos),
            stopped: false,
        }
    }

    /// Where the last complete record ended.
    pub fn position(&self) -> usize {
        self.cursor.position()
    }
}

impl<'a> Iterator for Records<'a> {
    type Item = Result<RawRecord<'a>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.stopped || self.cursor.remaining() < RECORD_HEADER_SIZE {
            return None;
        }
        let out = read_record(&mut self.cursor);
        if out.is_err() {
            self.stopped = true;
        }
        Some(out)
    }
}

/// Refuse anything that is not this major version, and say which of the two it is.
pub fn check_magic(head: &[u8]) -> Result<()> {
    if head.len() < MAGIC.len() {
        return Err(Error::Truncated("file is shorter than the magic".into()));
    }
    if head[..MAGIC.len()] == MAGIC {
        return Ok(());
    }
    // Two different failures, and the fix differs: a newer reader, or a different file.
    // They are told apart by whether the version byte is the ONLY difference — every
    // other byte of the magic is a fixed sentinel, so a file that differs elsewhere is not
    // a 4dgs file whatever its version byte happens to say.
    //
    // Testing only `head[1..5] == b"4DGS"` reported a corrupt first byte as an unsupported
    // version 1, which sends its holder looking for a newer reader that would not have
    // helped. The Python reader had the same bug, found the same way: by a corpus of files
    // that must be refused, comparing what the two say about them.
    const VERSION_AT: usize = 5;
    let elsewhere = head[..VERSION_AT] != MAGIC[..VERSION_AT]
        || head[VERSION_AT + 1..MAGIC.len()] != MAGIC[VERSION_AT + 1..];
    if !elsewhere {
        return Err(Error::refused(
            crate::error::refusal::UNSUPPORTED_MAJOR_VERSION,
            crate::error::RefusalKind::UnsupportedVersion,
            format!(
                "4dgs major version {:?} is not supported by this reader",
                head[VERSION_AT] as char
            ),
        ));
    }
    Err(Error::refused(
        crate::error::refusal::MAGIC_MISMATCH,
        crate::error::RefusalKind::UnsupportedVersion,
        "not a 4dgs file (bad magic)".into(),
    ))
}

// --------------------------------------------------------------------------
// Writing
// --------------------------------------------------------------------------

pub fn put_u8(out: &mut Vec<u8>, v: u8) {
    out.push(v);
}

pub fn put_u16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn put_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn put_f64(out: &mut Vec<u8>, v: f64) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn put_f64s(out: &mut Vec<u8>, vs: &[f64]) {
    for v in vs {
        put_f64(out, *v);
    }
}

pub fn put_f32(out: &mut Vec<u8>, v: f32) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn put_f32s(out: &mut Vec<u8>, vs: &[f32]) {
    for v in vs {
        put_f32(out, *v);
    }
}

pub fn put_string(out: &mut Vec<u8>, s: &str) {
    put_u32(out, s.len() as u32);
    out.extend_from_slice(s.as_bytes());
}

pub fn put_blob(out: &mut Vec<u8>, b: &[u8]) {
    put_u64(out, b.len() as u64);
    out.extend_from_slice(b);
}

/// Keys are written in sorted order so that two encoders producing the same map produce
/// the same bytes — the determinism the corpus gate checks.
pub fn put_str_map(out: &mut Vec<u8>, m: &BTreeMap<String, String>) {
    let mut body = Vec::new();
    for (k, v) in m {
        put_string(&mut body, k);
        put_string(&mut body, v);
    }
    put_u32(out, body.len() as u32);
    out.extend_from_slice(&body);
}

/// Frame `content` as a record with `opcode`.
pub fn put_record(out: &mut Vec<u8>, opcode: u8, content: &[u8]) {
    out.push(opcode);
    put_u64(out, content.len() as u64);
    out.extend_from_slice(content);
}

/// CRC-32 (IEEE), the one the Footer's `summary_crc` declares.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = flate2::Crc::new();
    crc.update(data);
    crc.sum()
}
