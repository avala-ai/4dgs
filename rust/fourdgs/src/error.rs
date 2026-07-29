// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Error types.
//!
//! A decoder that refuses a file says which field, which value, and what was expected.
//! These variants exist so a caller can tell apart the cases that need different
//! responses: the file is not ours, the file is ours but from the future, the file is
//! ours and broken, and the file is fine but this build cannot read it.

use std::fmt;

/// Everything this library can refuse a file for.
#[derive(Debug)]
pub enum Error {
    /// Not a 4dgs file, or a major version this reader does not implement. The fix is a
    /// newer reader, not a new file.
    UnsupportedVersion(String),
    /// The file ended, or a length ran past the end of its container. Common and often
    /// recoverable: records are length-prefixed, so a streamed reader keeps the prefix.
    Truncated(String),
    /// Structurally invalid: a required record missing, an index out of range, a value
    /// outside its legal domain.
    Malformed(String),
    /// A legal but unimplemented codec. The file is fine; this build cannot read it.
    UnsupportedCodec(String),
    /// An encoder's own verification failed: a decoded value fell outside the bound the
    /// file was about to declare. Always a bug in the encoder, never in the input.
    BoundViolation(String),
    /// A legal request on the wrong read path — asking a front-to-back reader for one
    /// chunk by index, for instance. Neither the file nor the caller is malformed; the
    /// operation simply belongs to the other path.
    UnsupportedOperation(String),
    /// The transport failed.
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::UnsupportedVersion(m) => write!(f, "unsupported version: {m}"),
            Error::Truncated(m) => write!(f, "truncated: {m}"),
            Error::Malformed(m) => write!(f, "malformed: {m}"),
            Error::UnsupportedCodec(m) => write!(f, "unsupported codec: {m}"),
            Error::BoundViolation(m) => write!(f, "bound violation: {m}"),
            Error::UnsupportedOperation(m) => write!(f, "unsupported operation: {m}"),
            Error::Io(e) => write!(f, "io: {e}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl Error {
    /// True for the one error a streamed reader recovers from by keeping what it already
    /// decoded.
    pub fn is_truncation(&self) -> bool {
        matches!(self, Error::Truncated(_))
    }
}

pub type Result<T> = std::result::Result<T, Error>;
