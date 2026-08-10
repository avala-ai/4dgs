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
//! Front matter is located from the framing and the bytes it frames: which record, and
//! then which record *of that kind*, since nothing forbids a second Header and a reader
//! refuses at the first one carrying a value it does not implement. A refusal that lives
//! inside a chunk's streams is located by decoding chunks one at a time until one of them
//! refuses, which is also the only way to *find* those refusals at all — the framing walk
//! steps over a chunk by its declared length and never looks inside it, which is why the
//! framing-only validator called two of the invalid corpus's seven files clean.
//!
//! Nothing here holds more than one chunk. That is not an optimization: the files this
//! tool exists for are the ones nobody can afford to hold, and a validator that answers
//! "do the chunks decode?" by keeping every chunk it decoded is unusable on them.

use fourdgs::error::refusal as id;
use fourdgs::indexed_reader::{read_chunk, IndexedScene};
use fourdgs::readable::Readable;
use fourdgs::serialization::{Cursor, MAGIC, RECORD_HEADER_SIZE};
use fourdgs::stream::decode_stream;
use fourdgs::{opcode as op, records as rec, BytesReadable, Error, Result};

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

    /// The record's content, or `None` when the declared length runs past the file.
    ///
    /// The walk lists a record whose length overruns the end — that length is the fault —
    /// so every caller that means to read one has to be told the bytes are not there.
    pub fn content<'a>(&self, data: &'a [u8]) -> Option<&'a [u8]> {
        let start = usize::try_from(self.offset.checked_add(RECORD_HEADER_SIZE as u64)?).ok()?;
        let end = start.checked_add(usize::try_from(self.length).ok()?)?;
        data.get(start..end)
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
    /// The first *whole* record with this opcode, if the file carries one.
    ///
    /// Whole is the only useful sense here. The walk also reports the record a file was cut
    /// inside — its declared length is the fault, and hiding the record would hide the
    /// field that carries it — but that record's content is not in the file, so a caller
    /// that means to read one must not be handed it.
    pub fn first_intact(&self, opcode: u8) -> Option<Frame> {
        self.intact_records()
            .iter()
            .copied()
            .find(|r| r.opcode == opcode)
    }

    /// The records a streamed reader keeps: every one the walk framed, less the one the
    /// file was cut inside.
    pub fn intact_records(&self) -> &[Frame] {
        &self.records[..self.intact()]
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

/// One record's content, fetched when something actually needs it.
///
/// `None` for a record whose content cannot be read, which the caller decides the meaning
/// of: for the validator it is a length that runs off the end, and for the tool's error
/// path it is a file that has stopped answering.
pub type Fetch<'a> = &'a dyn Fn(&Frame) -> Option<Vec<u8>>;

/// A file's framing, and a way to read the content of a record in it.
///
/// Both, because placing a refusal takes both: the walk says where each record is, and the
/// record's own bytes say which of several is the one that carries the refused value. The
/// content is fetched per record rather than handed over as a whole file, because the two
/// callers hold different things — the validator has the file resident already (it says
/// why, at `run`), and the tool's error path has a file it has just been refused and no
/// reason at all to buffer.
#[derive(Clone, Copy)]
pub struct Framing<'a> {
    pub walk: &'a Walk,
    pub fetch: Fetch<'a>,
}

/// Which record a named refusal is about.
///
/// A table rather than a guess, and a short one because the refusal vocabulary is short.
/// A code this build has not been taught is not placed rather than placed wrongly — an
/// offset that points at the wrong record is worse than no offset, because the reader
/// believes it.
///
/// The record is the one the reader **refused at**, not the first of its kind. Nothing in
/// the framing forbids a second Header or a second Quantization record, and both readers
/// check every one they meet as they meet it — so a file whose first Header is fine and
/// whose second declares a model this build does not implement is refused at the second.
/// Reporting the first would name a record that is perfectly good, with an offset its
/// reader has no reason to doubt.
fn front_matter_site(framing: Option<Framing>, code: &str) -> Option<Site> {
    /// True when this record's own declared value is the one the reader refuses.
    type Refuses = fn(&[u8]) -> bool;
    let (opcode, what, refuses): (u8, &str, Refuses) = match code {
        // Both are about the eight bytes of the magic itself, which is why neither needs a
        // walk to place: the walk that would find a record cannot start until they pass,
        // and the offset is known without one.
        id::MAGIC_MISMATCH | id::UNSUPPORTED_MAJOR_VERSION => {
            return Some(Site {
                offset: 0,
                what: "the magic".into(),
            })
        }
        id::UNKNOWN_TEMPORAL_MODEL => (op::HEADER, "the Header record", header_refuses),
        id::UNKNOWN_QUANTIZATION_SCHEME => (
            op::QUANTIZATION,
            "the Quantization record",
            quantization_refuses,
        ),
        _ => return None,
    };
    let framing = framing?;
    let frame = framing
        .walk
        // Whole records only. A record the file was cut inside was never parsed by the
        // reader either, so it cannot be the one whose value was refused.
        .intact_records()
        .iter()
        .filter(|frame| frame.opcode == opcode)
        // The same order the reader meets them in, so this lands on the same record. Only
        // the candidates are fetched, so a file with an hour of audio in it is not read.
        .find(|frame| (framing.fetch)(frame).is_some_and(|content| refuses(&content)))?;
    Some(Site {
        offset: frame.offset,
        what: what.into(),
    })
}

fn header_refuses(content: &[u8]) -> bool {
    rec::Header::parse(content).is_ok_and(|header| {
        fourdgs::registry::check_temporal_model(&header.temporal_model).is_err()
    })
}

fn quantization_refuses(content: &[u8]) -> bool {
    rec::Quantization::parse(content).is_ok_and(|quantization| {
        fourdgs::registry::check_quantization_scheme(&quantization.scheme).is_err()
    })
}

/// The first chunk that refuses, decoded one chunk at a time.
///
/// Returns the refusal and the byte the record it fired in starts at. `Ok(())` means every
/// chunk decoded, which is the only evidence there is that a file's streams are readable —
/// the framing walk cannot produce it, because stepping over a chunk by its declared length
/// is exactly not looking inside it.
///
/// **One chunk resident at a time, on both paths.** Each decoded chunk is dropped before
/// the next is read, so this costs the largest chunk rather than the scene (principle 1).
/// The question being asked is whether each chunk decodes, not what any of them decoded to,
/// and a validator that answered it by assembling the whole population would need memory
/// proportional to the file it was handed — on exactly the files nobody can afford to hold.
///
/// **Every band the index declares**, not band 0. Spherical harmonics do not enter
/// reconstructed state, so a *renderer* is right to cap them — but an SH Band Stream is a
/// stream like any other, and a band record carrying a codec this build does not implement
/// is a file that does not decode. Capping the bands here would report it `valid`.
pub fn scan_chunks(
    data: &[u8],
    walk: &Walk,
    scene: &IndexedScene,
) -> std::result::Result<(), (Error, Option<Site>)> {
    if scene.index.is_empty() {
        return scan_front_to_back(data, walk);
    }
    let mut source = BytesReadable::new(data);
    for (i, entry) in scene.index.iter().enumerate() {
        // The returned chunk is dropped here, at the end of the iteration.
        if let Err(error) = read_chunk(&mut source, scene, entry, u8::MAX) {
            let site = refusing_record(&mut source, scene, entry, i);
            return Err((error, Some(site)));
        }
    }
    Ok(())
}

/// Which of a chunk's records the refusal came out of: the Chunk itself, or one band.
///
/// A chunk is not one record. The Chunk record carries the attribute streams and each
/// spherical-harmonic band sits in an SH Band Stream record of its own, somewhere else in
/// the file entirely — so "the chunk did not decode" can be about a byte thousands of
/// bytes from where the Chunk record starts, and pointing at the Chunk would send its
/// reader to a stream that is perfectly healthy.
///
/// `read_chunk` fetches the chunk and every band the cap admits in one call, which is what
/// a reader wants. Raising the cap until it starts failing is therefore how to tell the two
/// apart without restating the library's fetch here and drifting from it. It costs a second
/// decode of one chunk, and it only ever runs on the file that has already refused.
fn refusing_record(
    source: &mut BytesReadable,
    scene: &IndexedScene,
    entry: &fourdgs::records::ChunkIndexEntry,
    i: usize,
) -> Site {
    let chunk = || Site {
        offset: entry.chunk_offset,
        what: format!("the Chunk record at index entry {i}"),
    };
    if read_chunk(source, scene, entry, 0).is_err() {
        return chunk();
    }
    let mut bands: Vec<(u8, u64)> = entry.bands.iter().map(|(b, at, _)| (*b, *at)).collect();
    bands.sort_unstable();
    for (band, at) in bands {
        // The cap admits every band up to `band`, and everything below it has already
        // decoded, so the first cap that fails names the band that failed.
        if read_chunk(source, scene, entry, band).is_err() {
            return Site {
                offset: at,
                what: format!("the SH Band Stream for band {band} of the Chunk at index entry {i}"),
            };
        }
    }
    chunk()
}

/// The same scan for a file with no index, which has no per-chunk addressing to seek with.
///
/// Front to back over the framing the walk already produced, decoding each Chunk and each
/// SH Band Stream on its own and keeping neither. The library's streamed reader assembles
/// the scene as it goes — which is what a *reader* wants and what a validator must not do —
/// so this drives the same decode primitives directly and throws each result away.
///
/// Being framing-driven, it also places the refusal: an unindexed file used to report the
/// identifier with no byte at all, because "every chunk or none" was the only answer the
/// whole-file decode could give.
fn scan_front_to_back(data: &[u8], walk: &Walk) -> std::result::Result<(), (Error, Option<Site>)> {
    let mut quantization: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut cutoff = fourdgs::quantization::DEFAULT_CUTOFF;
    // The count of the chunk a band record belongs to. Bands belong to the Chunk that
    // precedes them and are sized against it (spec §5.7).
    let mut count = 0usize;

    for frame in walk.intact_records() {
        let Some(content) = frame.content(data) else {
            continue;
        };
        let here = || {
            Some(Site {
                offset: frame.offset,
                what: format!("the {} record", op::name(frame.opcode)),
            })
        };
        match frame.opcode {
            // Taken as met, and not required to parse: a record whose body is broken is a
            // finding the validator has already made, and stopping here would replace it
            // with a worse one.
            op::HEADER => {
                if let Ok(header) = rec::Header::parse(content) {
                    cutoff = header.cutoff;
                }
            }
            op::QUANTIZATION => {
                if let Ok(parsed) = rec::Quantization::parse(content) {
                    quantization = Some(parsed);
                }
            }
            op::WINDOW_TABLE => {
                if let Ok(table) = rec::WindowTable::parse(content) {
                    windows = table.windows;
                }
            }
            op::CHUNK => {
                // A Chunk before the grid it is quantized against is a fault the validator
                // reports itself; there is nothing to decode it with here.
                let Some(quantization) = &quantization else {
                    continue;
                };
                let (head, streams) = rec::parse_chunk(content).map_err(|error| (error, here()))?;
                let blob = fourdgs::chunk::chunk_stream_bytes(&head, streams)
                    .map_err(|error| (error, here()))?;
                let decoded = fourdgs::chunk::decode_streams(
                    &blob,
                    head.count as usize,
                    &quantization.steps(),
                    &quantization.pos_origin,
                    &windows,
                    cutoff,
                )
                .map_err(|error| (error, here()))?;
                count = decoded.count;
            }
            op::SH_BAND_STREAM => {
                let mut cursor = Cursor::new(content);
                // The band index, which the record carries and the stream header does not:
                // a band stream's `attribute_id` is 0x07 and collides with `mu_t` (§5.7).
                cursor.u8().map_err(|error| (error, here()))?;
                decode_stream(&mut cursor, Some(count)).map_err(|error| (error, here()))?;
            }
            _ => {}
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
pub fn describe(error: &Error, framing: Option<Framing>, site: Option<Site>) -> Option<Named> {
    let code = error.refusal_code()?;
    let site = site.or_else(|| front_matter_site(framing, code));
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
        assert_eq!(
            walk.first_intact(op::HEADER).unwrap().offset,
            MAGIC.len() as u64
        );
        assert!(walk.first_intact(op::FOOTER).is_some());
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
        let named = describe(&error, None, None).expect("a named refusal");
        assert_eq!(named.code, id::MAGIC_MISMATCH);
        assert_eq!(named.site.unwrap().offset, 0);
    }

    #[test]
    fn an_error_the_refusal_table_does_not_name_is_not_given_an_identifier() {
        // A truncated transport is a real error and not a refusal. Inventing a code for it
        // would be inventing conformance.
        let error = Error::Truncated("cut".into());
        assert!(describe(&error, None, None).is_none());
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
