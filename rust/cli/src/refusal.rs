// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Which refusal, and which byte it fired at.
//!
//! The library already names its refusals — `Error::refusal_code()` returns a stable
//! identifier the conformance corpus is written against — and its messages already say
//! which value was found and what was expected. What neither of them carries is the
//! **offset**: an error is raised where the value was parsed, not where the bytes sit, and
//! by then the record's position is several frames up the stack.
//!
//! So the tool supplies it. The refusal vocabulary is six identifiers, each of which is
//! about exactly one kind of record, and a framing walk knows where every record is. That
//! is the whole mechanism: walk the framing, ask which record this refusal is about, print
//! the byte.
//!
//! Front matter is located from framing alone. A refusal that lives inside a chunk's
//! streams is located by decoding chunks one at a time until one of them refuses, which is
//! also the only way to *find* those refusals at all — the framing walk steps over a chunk
//! by its declared length and never looks inside it, which is why the framing-only
//! validator called two of the invalid corpus's seven files clean.

use fourdgs::error::refusal as id;
use fourdgs::readable::Readable;
use fourdgs::reader::OpenMode;
use fourdgs::serialization::{MAGIC, RECORD_HEADER_SIZE};
use fourdgs::{opcode as op, Error, Result, SceneReader};

/// One record's framing: what it is, where it starts, how long its content is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub opcode: u8,
    /// Offset of the opcode byte.
    pub offset: u64,
    /// Content length, as the record declares it.
    pub length: u64,
}

impl Frame {
    /// Framing plus content, which is what an offset has to advance by.
    ///
    /// Saturating: the length is eight bytes off an untrusted file, so a record can
    /// declare `u64::MAX` and this is where that would wrap. Saturating produces a total
    /// that runs past the end of any file, which is exactly what the walk then reports.
    pub fn total(&self) -> u64 {
        self.length.saturating_add(RECORD_HEADER_SIZE as u64)
    }
}

/// Where a framing walk stopped, when it did not reach the end.
#[derive(Debug, Clone)]
pub struct Cut {
    /// The first byte the walk could not account for.
    pub at: u64,
    pub reason: String,
    /// True when the cut is inside a record whose framing was read — so the last record
    /// the walk reports is the incomplete one, and everything before it is intact.
    pub inside_a_record: bool,
}

/// The result of walking a file's framing: every record, and the cut if there was one.
#[derive(Debug, Clone, Default)]
pub struct Walk {
    pub records: Vec<Frame>,
    pub cut: Option<Cut>,
    /// True when the last eight bytes are the magic, as a whole file's are.
    pub trailing_magic: bool,
    pub size: u64,
}

impl Walk {
    /// The first record with this opcode, if the file carries one.
    pub fn first(&self, opcode: u8) -> Option<Frame> {
        self.records.iter().copied().find(|r| r.opcode == opcode)
    }

    /// How many of the reported records are whole.
    ///
    /// All of them, except when the file was cut inside one: that record is reported —
    /// hiding it would hide the declared length that is the whole fault — but it is not
    /// something a streamed reader keeps.
    pub fn intact(&self) -> usize {
        let incomplete = self.cut.as_ref().is_some_and(|cut| cut.inside_a_record) as usize;
        self.records.len().saturating_sub(incomplete)
    }
}

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap on a file
/// carrying an hour of audio as on one carrying none. The magic is checked first, because
/// a walk over bytes that are not ours would report whatever the first byte happened to
/// mean as an opcode.
pub fn walk(source: &mut dyn Readable) -> Result<Walk> {
    let size = source.size()?;
    let head = source.read(0, (MAGIC.len() as u64).min(size))?;
    fourdgs::serialization::check_magic(&head)?;

    let mut out = Walk {
        size,
        ..Default::default()
    };
    let mut at = MAGIC.len() as u64;
    loop {
        let remaining = size.saturating_sub(at);
        if remaining == 0 {
            break;
        }
        // A whole file ends with the magic, so its last eight bytes are not a record.
        if remaining <= MAGIC.len() as u64 {
            out.trailing_magic = source.read(at, remaining)? == MAGIC;
            if !out.trailing_magic {
                out.cut = Some(Cut {
                    at,
                    reason: format!(
                        "{remaining} trailing bytes are neither a record nor the magic"
                    ),
                    inside_a_record: false,
                });
            }
            break;
        }
        if remaining < RECORD_HEADER_SIZE as u64 {
            out.cut = Some(Cut {
                at,
                reason: format!("{remaining} bytes are too few for a record header"),
                inside_a_record: false,
            });
            break;
        }
        let framing = source.read(at, RECORD_HEADER_SIZE as u64)?;
        let opcode = framing[0];
        let length = u64::from_le_bytes([
            framing[1], framing[2], framing[3], framing[4], framing[5], framing[6], framing[7],
            framing[8],
        ]);
        let frame = Frame {
            opcode,
            offset: at,
            length,
        };
        // A record is listed either way: a declared length that runs off the end is a fact
        // about that record, and hiding the record hides the field that carries the fault.
        out.records.push(frame);
        match at.checked_add(frame.total()) {
            Some(end) if end <= size => at = end,
            _ => {
                out.cut = Some(Cut {
                    at,
                    reason: format!(
                        "the {} record declares {} bytes, past the end of a {}-byte file",
                        op::name(opcode),
                        crate::commas(length),
                        crate::commas(size)
                    ),
                    inside_a_record: true,
                });
                break;
            }
        }
    }
    Ok(out)
}

/// The byte a refusal fired at, and what sits there.
#[derive(Debug, Clone)]
pub struct Site {
    pub offset: u64,
    /// What the offset points at, in the vocabulary of `concepts.md`.
    pub what: String,
}

/// Which record a named refusal is about.
///
/// A table rather than a guess, and a short one because the refusal vocabulary is short.
/// A code this build has not been taught is not placed rather than placed wrongly — an
/// offset that points at the wrong record is worse than no offset, because the reader
/// believes it.
fn front_matter_site(walk: Option<&Walk>, code: &str) -> Option<Site> {
    let (opcode, what) = match code {
        // Both are about the eight bytes of the magic itself, which is why neither needs a
        // walk to place: the walk that would find a record cannot start until they pass,
        // and the offset is known without one.
        id::MAGIC_MISMATCH | id::UNSUPPORTED_MAJOR_VERSION => {
            return Some(Site {
                offset: 0,
                what: "the magic".into(),
            })
        }
        id::UNKNOWN_TEMPORAL_MODEL => (op::HEADER, "the Header record"),
        id::UNKNOWN_QUANTIZATION_SCHEME => (op::QUANTIZATION, "the Quantization record"),
        _ => return None,
    };
    walk?.first(opcode).map(|frame| Site {
        offset: frame.offset,
        what: what.into(),
    })
}

/// The first chunk that refuses, decoded one chunk at a time.
///
/// Returns the refusal and the byte its Chunk record starts at. `Ok(())` means every chunk
/// decoded, which is the only evidence there is that a file's streams are readable — the
/// framing walk cannot produce it, because stepping over a chunk by its declared length is
/// exactly not looking inside it.
///
/// One chunk resident at a time on the indexed path, which is what keeps this bounded on a
/// file too large to hold. A file with no index has no per-chunk addressing to use, so it
/// is decoded front to back and the refusal comes back without an offset rather than with
/// a guessed one.
pub fn scan_chunks<R: Readable>(source: R) -> std::result::Result<(), (Error, Option<Site>)> {
    let mut reader = match SceneReader::open_with(source, OpenMode::Auto) {
        Ok(reader) => reader,
        Err(error) => return Err((error, None)),
    };
    let offsets: Vec<u64> = reader
        .chunk_index()
        .iter()
        .map(|entry| entry.chunk_offset)
        .collect();
    if offsets.is_empty() {
        // Front to back: every chunk or none, and no per-chunk offset to attribute to.
        // Band 0 throughout — spherical harmonics do not enter reconstructed state, so
        // fetching them would only move bytes nobody is checking.
        return match reader.load_all(0) {
            Ok(_) => Ok(()),
            Err(error) => Err((error, None)),
        };
    }
    for (i, offset) in offsets.iter().enumerate() {
        if let Err(error) = reader.load_chunk(i as u32, 0) {
            return Err((
                error,
                Some(Site {
                    offset: *offset,
                    what: format!("the Chunk record at index entry {i}"),
                }),
            ));
        }
    }
    Ok(())
}

/// Everything the tool can say about one refusal: the identifier and the byte.
///
/// `None` for an error the refusal table does not name — a truncated transport, an
/// encoder bound violation. That is not a failure of this function; it is the library
/// saying "this is not one of the refusals the corpus compares", and a tool that invented
/// an identifier there would be inventing conformance.
pub fn describe(error: &Error, walk: Option<&Walk>, site: Option<Site>) -> Option<Named> {
    let code = error.refusal_code()?;
    let site = site.or_else(|| front_matter_site(walk, code));
    Some(Named { code, site })
}

/// A refusal with a name, and where it is if the tool could place it.
#[derive(Debug, Clone)]
pub struct Named {
    pub code: &'static str,
    pub site: Option<Site>,
}

impl std::fmt::Display for Named {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "refusal {}", self.code)?;
        if let Some(site) = &self.site {
            write!(f, " at byte {} ({})", site.offset, site.what)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fourdgs::BytesReadable;

    fn valid() -> Vec<u8> {
        crate::validate::sample_file(Vec::new())
    }

    #[test]
    fn a_walk_frames_every_record_and_ends_on_the_magic() {
        let data = valid();
        let walk = walk(&mut BytesReadable::new(&data)).unwrap();
        assert!(walk.trailing_magic);
        assert!(walk.cut.is_none());
        assert_eq!(walk.first(op::HEADER).unwrap().offset, MAGIC.len() as u64);
        assert!(walk.first(op::FOOTER).is_some());
        // Every record accounted for, back to back: the offsets have to tile the file.
        let mut at = MAGIC.len() as u64;
        for frame in &walk.records {
            assert_eq!(frame.offset, at);
            at += frame.total();
        }
        assert_eq!(at, walk.size - MAGIC.len() as u64);
    }

    #[test]
    fn a_cut_file_reports_the_records_before_the_cut_and_the_byte() {
        let mut data = valid();
        let whole = walk(&mut BytesReadable::new(&data)).unwrap();
        data.truncate(data.len() / 2);
        let walk = walk(&mut BytesReadable::new(&data)).unwrap();
        let cut = walk.cut.expect("a cut file names where it was cut");
        assert!(cut.at < data.len() as u64);
        assert!(
            !walk.records.is_empty(),
            "the intact prefix is still framed"
        );
        assert!(walk.records.len() < whole.records.len());
        assert!(!walk.trailing_magic);
    }

    #[test]
    fn a_magic_refusal_is_placed_at_byte_zero_without_a_walk() {
        let error = fourdgs::serialization::check_magic(b"not ours").unwrap_err();
        let named = describe(&error, Some(&Walk::default()), None).expect("a named refusal");
        assert_eq!(named.code, id::MAGIC_MISMATCH);
        assert_eq!(named.site.unwrap().offset, 0);
    }

    #[test]
    fn an_error_the_refusal_table_does_not_name_is_not_given_an_identifier() {
        // A truncated transport is a real error and not a refusal. Inventing a code for it
        // would be inventing conformance.
        let error = Error::Truncated("cut".into());
        assert!(describe(&error, Some(&Walk::default()), None).is_none());
    }

    #[test]
    fn the_display_form_carries_the_code_and_the_byte() {
        let named = Named {
            code: id::UNKNOWN_TEMPORAL_MODEL,
            site: Some(Site {
                offset: 8,
                what: "the Header record".into(),
            }),
        };
        assert_eq!(
            named.to_string(),
            "refusal unknown-temporal-model at byte 8 (the Header record)"
        );
        let unplaced = Named {
            code: id::UNKNOWN_STREAM_CODEC,
            site: None,
        };
        assert_eq!(unplaced.to_string(), "refusal unknown-stream-codec");
    }
}
