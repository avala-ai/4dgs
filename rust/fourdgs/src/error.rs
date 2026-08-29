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
    /// A well-known value this reader does not implement — a temporal model, a
    /// quantization scheme. The file is fine and conforming; this build cannot read it,
    /// and the registry requires it to say so by name rather than guess.
    ///
    /// Its `Display` is the message alone, where every other variant prefixes its kind.
    /// The wording is contract: the specification's refusal table writes the sentence so
    /// that two readers refusing one file say the same thing about it, and the CLI
    /// cross-validator compares it against the Python reader's line for line. An
    /// `"unsupported codec: "` in front of it would be wrong twice — a temporal model is
    /// neither a codec nor a version — and would put this crate's taxonomy ahead of the
    /// specification's sentence.
    UnsupportedModel(String),
    /// An encoder's own verification failed: a decoded value fell outside the bound the
    /// file was about to declare. Always a bug in the encoder, never in the input.
    BoundViolation(String),
    /// A legal request on the wrong read path — asking a front-to-back reader for one
    /// chunk by index, for instance. Neither the file nor the caller is malformed; the
    /// operation simply belongs to the other path.
    UnsupportedOperation(String),
    /// A caller handed the encoder a scene it cannot write a conforming file from — a
    /// non-finite position, for instance, which would land in a quantization grid the
    /// specification forbids (§5.3). The mirror of `Malformed`: that describes a file that
    /// arrived broken, this describes a scene that never should have been offered.
    InvalidInput(String),
    /// The transport failed.
    Io(std::io::Error),
    /// A refusal the specification names, carrying the identifier that names it.
    ///
    /// The other variants say what *kind* of thing went wrong. This one additionally says
    /// *which* refusal it is, with a stable string the conformance suite compares against
    /// the same identifier every other SDK prints — so "refused for the right reason" and
    /// "refused for some reason" stop being the same observation.
    ///
    /// It does not change how a refusal reads. `kind` carries the variant this would
    /// otherwise have been, and both `Display` and the C ABI's status mapping defer to it,
    /// so the sentence on the wire is byte-for-byte what it was before the identifier
    /// existed. That matters because the specification writes those sentences and the CLI
    /// cross-validator compares them against the Python reader's, line for line.
    Refused {
        /// Stable across releases and across languages. Changing one is a wire-visible
        /// change to the conformance corpus, not an implementation detail.
        code: &'static str,
        kind: RefusalKind,
        message: String,
    },
}

/// The variant a [`Error::Refused`] would have been without its identifier.
///
/// Exists so that adding the identifier changed no sentence and no status code. Each arm
/// maps to exactly the `Display` prefix and the `FOURDGS_STATUS_*` its counterpart had.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalKind {
    /// Not a 4dgs file, or a major version this reader does not implement.
    UnsupportedVersion,
    /// A well-known name this build does not implement — a temporal model, a quantization
    /// scheme. Prints the message alone, as its counterpart does.
    UnsupportedModel,
    /// A legal but unimplemented codec.
    UnsupportedCodec,
    /// Structurally invalid: a value outside its legal domain.
    Malformed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::UnsupportedVersion(m) => write!(f, "unsupported version: {m}"),
            Error::Truncated(m) => write!(f, "truncated: {m}"),
            Error::Malformed(m) => write!(f, "malformed: {m}"),
            Error::UnsupportedCodec(m) => write!(f, "unsupported codec: {m}"),
            Error::UnsupportedModel(m) => write!(f, "{m}"),
            Error::BoundViolation(m) => write!(f, "bound violation: {m}"),
            Error::UnsupportedOperation(m) => write!(f, "unsupported operation: {m}"),
            Error::InvalidInput(m) => write!(f, "invalid input: {m}"),
            Error::Io(e) => write!(f, "io: {e}"),
            // Deferred to the kind so that naming a refusal did not reword it.
            Error::Refused { kind, message, .. } => match kind {
                RefusalKind::UnsupportedVersion => write!(f, "unsupported version: {message}"),
                RefusalKind::UnsupportedModel => write!(f, "{message}"),
                RefusalKind::UnsupportedCodec => write!(f, "unsupported codec: {message}"),
                RefusalKind::Malformed => write!(f, "malformed: {message}"),
            },
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

/// Every refusal this reader can name (spec: the refusal table).
///
/// Constants rather than string literals at the raise sites, because these are compared
/// across six implementations: a typo in one is a conformance failure that reads like a
/// decoder bug.
pub mod refusal {
    /// The file does not begin with the 4dgs magic.
    pub const MAGIC_MISMATCH: &str = "magic-mismatch";
    /// The magic is ours; the major version is not one this reader implements.
    pub const UNSUPPORTED_MAJOR_VERSION: &str = "unsupported-major-version";
    /// The Header names a temporal model this build does not implement — including the
    /// empty name, which is a declaration of nothing rather than a default.
    pub const UNKNOWN_TEMPORAL_MODEL: &str = "unknown-temporal-model";
    /// The Quantization record names a scheme this build does not implement.
    pub const UNKNOWN_QUANTIZATION_SCHEME: &str = "unknown-quantization-scheme";
    /// The Quantization record declares a finite birth-time grid pitch at or below zero.
    pub const NON_POSITIVE_STEP_TIME: &str = "non-positive-step-time";
    /// A stream declares a codec this build does not implement.
    pub const UNKNOWN_STREAM_CODEC: &str = "unknown-stream-codec";
    /// A gaussian's `window_index` names a row the Window Table does not have.
    pub const WINDOW_INDEX_OUT_OF_RANGE: &str = "window-index-out-of-range";
}

impl Error {
    /// True for the one error a streamed reader recovers from by keeping what it already
    /// decoded.
    pub fn is_truncation(&self) -> bool {
        matches!(self, Error::Truncated(_))
    }

    /// Build a named refusal. See [`refusal`] for the identifiers.
    pub fn refused(code: &'static str, kind: RefusalKind, message: String) -> Error {
        Error::Refused {
            code,
            kind,
            message,
        }
    }

    /// Add the outer record and byte to a parser error without changing its taxonomy or
    /// refusal identifier.
    ///
    /// Record parsers deliberately describe the field they were handed. Range and
    /// streaming readers know where that field came from, and diagnostics need both
    /// facts. Keeping the variant intact is what lets the C ABI continue distinguishing
    /// malformed input, a cut resource, and a legal resource outside an implementation
    /// ceiling.
    /// A second Header, Quantization or Window Table record in one file (spec §4).
    ///
    /// These three describe the whole file, and nothing in a `.4dgs` file says which of
    /// two copies wins. A reader that keeps the last silently disagrees with one that
    /// keeps the first — and both of those readers are in this crate: the streamed
    /// reader replaced its retained value as each copy arrived, while the indexed opener
    /// walks the front matter and would keep the first. Same bytes, two scenes.
    ///
    /// Spelled once rather than at each of the six call sites, for the reason the
    /// window-index refusal is spelled once: six spellings is six chances for one of
    /// them to leave the offset out.
    pub(crate) fn duplicate_structural_record(record: &str, offset: u64) -> Error {
        Error::Malformed(format!(
            "a second {record} record at byte {offset}; a file carries exactly one, and nothing says which of two copies a reader should believe"
        ))
    }

    pub(crate) fn at_record(self, record: &str, offset: u64) -> Error {
        let context = |message: String| format!("{record} at byte {offset}: {message}");
        match self {
            Error::UnsupportedVersion(message) => Error::UnsupportedVersion(context(message)),
            Error::Truncated(message) => Error::Truncated(context(message)),
            Error::Malformed(message) => Error::Malformed(context(message)),
            Error::UnsupportedCodec(message) => Error::UnsupportedCodec(context(message)),
            Error::UnsupportedModel(message) => Error::UnsupportedModel(context(message)),
            Error::BoundViolation(message) => Error::BoundViolation(context(message)),
            Error::UnsupportedOperation(message) => Error::UnsupportedOperation(context(message)),
            Error::InvalidInput(message) => Error::InvalidInput(context(message)),
            Error::Refused {
                code,
                kind,
                message,
            } => Error::Refused {
                code,
                kind,
                message: context(message),
            },
            Error::Io(error) => Error::Io(error),
        }
    }

    /// True when this is "not our file, or a version we do not implement", however it was
    /// raised.
    ///
    /// Predicates rather than `matches!` on the variant, because a named refusal lives in
    /// [`Error::Refused`] and carries its taxonomy in `kind`. Asking the question this way
    /// keeps working when a refusal gains a name; matching the variant directly does not.
    pub fn is_unsupported_version(&self) -> bool {
        matches!(
            self,
            Error::UnsupportedVersion(_)
                | Error::Refused {
                    kind: RefusalKind::UnsupportedVersion,
                    ..
                }
        )
    }

    /// True for a legal file this build cannot read — an unimplemented codec, temporal
    /// model or quantization scheme.
    pub fn is_unsupported_feature(&self) -> bool {
        matches!(
            self,
            Error::UnsupportedCodec(_)
                | Error::UnsupportedModel(_)
                | Error::Refused {
                    kind: RefusalKind::UnsupportedCodec | RefusalKind::UnsupportedModel,
                    ..
                }
        )
    }

    /// True for a structurally invalid file.
    pub fn is_malformed(&self) -> bool {
        matches!(
            self,
            Error::Malformed(_)
                | Error::Refused {
                    kind: RefusalKind::Malformed,
                    ..
                }
        )
    }

    /// The identifier for a refusal this reader can name, or `None` for everything else.
    ///
    /// `None` is not a failure — a truncated transport and an encoder bound violation are
    /// real errors that the refusal table does not name. It means "this is not one of the
    /// refusals the corpus compares".
    pub fn refusal_code(&self) -> Option<&'static str> {
        match self {
            Error::Refused { code, .. } => Some(code),
            _ => None,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
