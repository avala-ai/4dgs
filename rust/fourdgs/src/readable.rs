// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The one abstraction the core depends on.
//!
//! A reader needs exactly two things from a resource: how big it is, and the bytes in a
//! range. Everything else — a file, an HTTP server, a cache, an in-memory buffer — is a
//! transport, and transports live at the edges so the decoder can be tested without a
//! network and shipped without a platform.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use crate::error::{Error, Result};

/// Something that can report its size and read a byte range.
pub trait Readable {
    /// Total size of the resource in bytes.
    fn size(&mut self) -> Result<u64>;

    /// Exactly `length` bytes at `offset`, or an error.
    ///
    /// Returning a short read silently is the one behaviour that breaks every caller, so
    /// implementations must not do it.
    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>>;
}

/// A whole resource already in memory.
pub struct BytesReadable<'a> {
    data: &'a [u8],
}

impl<'a> BytesReadable<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BytesReadable { data }
    }
}

impl Readable for BytesReadable<'_> {
    fn size(&mut self) -> Result<u64> {
        Ok(self.data.len() as u64)
    }

    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        let start = usize::try_from(offset).map_err(|_| {
            Error::Truncated(format!("offset {offset} is past this platform's reach"))
        })?;
        let len = usize::try_from(length).map_err(|_| {
            Error::Truncated(format!("length {length} is past this platform's reach"))
        })?;
        let end = start
            .checked_add(len)
            .ok_or_else(|| Error::Truncated(format!("range [{start}, +{len}) overflows")))?;
        if end > self.data.len() {
            return Err(Error::Truncated(format!(
                "range [{start}, {end}) is outside the {} bytes of this resource",
                self.data.len()
            )));
        }
        Ok(self.data[start..end].to_vec())
    }
}

/// A local file. Seeks rather than mapping, so the reader's memory stays bounded by what
/// it asked for rather than by the file's size.
pub struct FileReadable {
    file: File,
    size: u64,
}

impl FileReadable {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<FileReadable> {
        let mut file = File::open(path)?;
        let size = file.seek(SeekFrom::End(0))?;
        Ok(FileReadable { file, size })
    }
}

impl Readable for FileReadable {
    fn size(&mut self) -> Result<u64> {
        Ok(self.size)
    }

    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        if offset.saturating_add(length) > self.size {
            return Err(Error::Truncated(format!(
                "range [{offset}, {}) is outside the {} bytes of this file",
                offset + length,
                self.size
            )));
        }
        let len = usize::try_from(length).map_err(|_| {
            Error::Truncated(format!("length {length} is past this platform's reach"))
        })?;
        self.file.seek(SeekFrom::Start(offset))?;
        let mut out = vec![0u8; len];
        self.file.read_exact(&mut out).map_err(|e| {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                Error::Truncated(format!("short read: wanted {length} bytes at {offset}"))
            } else {
                Error::Io(e)
            }
        })?;
        Ok(out)
    }
}

impl<T: Readable + ?Sized> Readable for Box<T> {
    fn size(&mut self) -> Result<u64> {
        (**self).size()
    }

    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        (**self).read(offset, length)
    }
}

impl<T: Readable + ?Sized> Readable for &mut T {
    fn size(&mut self) -> Result<u64> {
        (**self).size()
    }

    fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
        (**self).read(offset, length)
    }
}
