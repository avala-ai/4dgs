// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Which refusal, and which byte it fired at.
//!
//! The library returns stable refusal identifiers and diagnostic values, but parsing has
//! already lost the source offset. The tool recovers it with a framing walk: front matter
//! is located by record kind and occurrence, while chunk refusals are found by decoding
//! one chunk at a time.
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
    #[allow(dead_code)] // retained for the focused framing tests; inspect uses WalkSummary
    pub trailing_magic: bool,
    #[allow(dead_code)] // retained for the focused framing tests; inspect uses WalkSummary
    pub size: u64,
}

impl Walk {
    /// The first *whole* record with this opcode, if the file carries one.
    ///
    /// Whole is the only useful sense here. The walk also reports the record a file was cut
    /// inside — its declared length is the fault, and hiding the record would hide the
    /// field that carries it — but that record's content is not in the file, so a caller
    /// that means to read one must not be handed it.
    #[allow(dead_code)] // coverage tests exercise the former retained-walk caller directly
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

/// Aggregate framing facts for a pass that does not retain one [`Frame`] per record.
#[derive(Debug, Clone, Default)]
pub struct WalkSummary {
    pub cut: Option<Cut>,
    pub trailing_magic: bool,
    pub size: u64,
    pub record_count: usize,
    pub intact: usize,
}

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap on a file
/// carrying an hour of audio as on one carrying none. The magic is checked first, because
/// a walk over bytes that are not ours would report whatever the first byte happened to
/// mean as an opcode.
#[cfg_attr(not(test), allow(dead_code))]
pub fn walk(source: &mut dyn Readable) -> Result<Walk> {
    let mut records = Vec::new();
    let summary = walk_each(source, |frame, _| records.push(frame))?;
    Ok(Walk {
        records,
        cut: summary.cut,
        trailing_magic: summary.trailing_magic,
        size: summary.size,
    })
}

/// Walk every frame through a callback while retaining only aggregate facts.
///
/// `intact` is false only for the final reported frame when the file ends inside that
/// record. Inspect uses two passes: one finds the Footer/checksum declaration, and one emits
/// rows directly. Its memory therefore stays constant even for millions of empty records.
pub fn walk_each(
    source: &mut dyn Readable,
    mut visit: impl FnMut(Frame, bool),
) -> Result<WalkSummary> {
    let size = source.size()?;
    let head = source.read(0, (MAGIC.len() as u64).min(size))?;
    fourdgs::serialization::check_magic(&head)?;

    let mut out = WalkSummary {
        size,
        ..Default::default()
    };
    let mut at = MAGIC.len() as u64;
    loop {
        let remaining = size.saturating_sub(at);
        if remaining == 0 {
            // The file ended on a record boundary, so nothing here is malformed — and
            // nothing here is the trailing magic either. A whole file ends with those eight
            // bytes; a file that ends without them is cut, most simply by removing only the
            // magic, and the cut is exactly here. Without this the walk reports no cut at
            // all: `inspect` printed a note and exited 0 for a file it had just walked to
            // the end of the wrong thing, and `validate` left off the intact-prefix note
            // that says how much of it survives.
            if !out.trailing_magic {
                out.cut = Some(Cut {
                    at,
                    reason: "the file ends here, with no trailing magic".into(),
                    inside_a_record: false,
                });
            }
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
        match at.checked_add(frame.total()) {
            Some(end) if end <= size => {
                visit(frame, true);
                out.record_count += 1;
                out.intact += 1;
                at = end;
            }
            _ => {
                visit(frame, false);
                out.record_count += 1;
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

/// Framing, one record at a time, holding none of it.
///
/// [`walk`] answers "what is in this file?", and keeping a `Frame` per record is how it
/// answers. The questions on this side are narrower — "which record carries the value that
/// was refused?", "which chunk does not decode?" — and a caller asking one of those stops at
/// the answer. So nothing is retained: a file with a million small records costs what a file
/// with one costs, which is what keeps an early refusal on a large file an early refusal
/// (principle 1).
///
/// The records it yields are the whole ones, in file order. A record the file was cut inside
/// ends the walk without being yielded — a reader never parsed it either, so it cannot be
/// the record that refused.
struct Streamed<'a> {
    source: &'a mut dyn Readable,
    size: u64,
    at: u64,
    done: bool,
}

impl<'a> Streamed<'a> {
    /// Check the magic and stand at the first record.
    fn open(source: &'a mut dyn Readable) -> Result<Streamed<'a>> {
        let size = source.size()?;
        let head = source.read(0, (MAGIC.len() as u64).min(size))?;
        fourdgs::serialization::check_magic(&head)?;
        Ok(Streamed {
            source,
            size,
            at: MAGIC.len() as u64,
            done: false,
        })
    }

    fn next_frame(&mut self) -> Option<Frame> {
        if self.done {
            return None;
        }
        // A whole file ends with the magic, so its last eight bytes are not a record; a cut
        // one has too few bytes left to frame one. Either way there is no next record.
        if self.size.saturating_sub(self.at) <= MAGIC.len() as u64 {
            self.done = true;
            return None;
        }
        let framing = match self.source.read(self.at, RECORD_HEADER_SIZE as u64) {
            Ok(framing) if framing.len() == RECORD_HEADER_SIZE => framing,
            _ => {
                self.done = true;
                return None;
            }
        };
        let frame = Frame {
            opcode: framing[0],
            offset: self.at,
            length: u64::from_le_bytes([
                framing[1], framing[2], framing[3], framing[4], framing[5], framing[6], framing[7],
                framing[8],
            ]),
        };
        match self.at.checked_add(frame.total()) {
            Some(end) if end <= self.size => {
                self.at = end;
                Some(frame)
            }
            // The declared length runs off the end. The record is not whole, so it is not
            // yielded, and there is nothing after it to frame.
            _ => {
                self.done = true;
                None
            }
        }
    }

    /// One record's content. `None` when the file stopped answering.
    fn content(&mut self, frame: &Frame) -> Option<Vec<u8>> {
        self.source
            .read(frame.offset + RECORD_HEADER_SIZE as u64, frame.length)
            .ok()
    }

    /// A bounded slice of one record's content.
    ///
    /// Refusal placement needs only the declaration string in Header or Quantization.
    /// Reading through this method means an extensible record's appended trailer is never
    /// transferred merely to say which byte carried an unsupported value.
    fn range(&mut self, frame: &Frame, at: u64, length: u64) -> Option<Vec<u8>> {
        let end = at.checked_add(length)?;
        if end > frame.length || length > fourdgs::indexed_reader::MAX_FRONT_MATTER_BYTES {
            return None;
        }
        self.source
            .read(
                frame
                    .offset
                    .checked_add(RECORD_HEADER_SIZE as u64)?
                    .checked_add(at)?,
                length,
            )
            .ok()
    }
}

/// The byte a refusal fired at, found without holding the file or a walk of it.
///
/// The tool's error path calls this: a command has just been refused, and the only thing
/// left to add to the library's message is where. A walk would answer the same question by
/// building a `Frame` for every record in the file first — including the ones after the one
/// that refused, which no reader ever reached — and an early refusal on a large file would
/// cost memory proportional to that file. This stops at the record it is looking for.
///
/// Two shapes of refusal are placed, and they are placed differently because they are found
/// differently:
///
/// * **Front matter** — an unimplemented temporal model or quantization scheme — is placed
///   by streaming the framing and asking each Header or Quantization record whether its own
///   declared value is the refused one. The first that says yes is the record the reader
///   refused at, in the order the reader met them.
/// * **A chunk's streams** — an unimplemented stream codec, a window index outside the
///   table — cannot be found from framing at all, because stepping over a chunk by its
///   declared length is exactly not looking inside it. So the file is decoded front to back,
///   one record at a time, and the first record that raises **this same refusal** is the
///   site. Same refusal, because a scan that stopped at a different one would be answering a
///   different question, and an offset that points at the wrong record is worse than none.
pub fn locate_streaming(source: &mut dyn Readable, code: &str) -> Option<Site> {
    match code {
        // Known without a walk: the magic is the first eight bytes, and a walk cannot start
        // until they pass.
        id::MAGIC_MISMATCH | id::UNSUPPORTED_MAJOR_VERSION => Some(Site {
            offset: 0,
            what: "the magic".into(),
        }),
        id::UNKNOWN_TEMPORAL_MODEL => first_declaring(source, op::HEADER, "the Header record"),
        id::UNKNOWN_QUANTIZATION_SCHEME => {
            first_declaring(source, op::QUANTIZATION, "the Quantization record")
        }
        id::UNKNOWN_STREAM_CODEC | id::WINDOW_INDEX_OUT_OF_RANGE => match scan_streamed(source) {
            Err((error, site)) if error.refusal_code() == Some(code) => site,
            _ => None,
        },
        _ => None,
    }
}

/// The first whole record of this kind whose own declared value is the one being refused.
fn first_declaring(source: &mut dyn Readable, opcode: u8, what: &str) -> Option<Site> {
    let mut records = Streamed::open(source).ok()?;
    while let Some(frame) = records.next_frame() {
        if frame.opcode != opcode {
            continue;
        }
        let refuses = match opcode {
            op::HEADER => header_declaration_refuses(&mut records, &frame),
            op::QUANTIZATION => quantization_declaration_refuses(&mut records, &frame),
            _ => false,
        };
        if refuses {
            return Some(Site {
                offset: frame.offset,
                what: what.into(),
            });
        }
    }
    None
}

/// The byte immediately after a length-prefixed string, without fetching its contents.
fn skip_string(records: &mut Streamed<'_>, frame: &Frame, at: u64) -> Option<u64> {
    let length = records.range(frame, at, 4)?;
    let length = u32::from_le_bytes(length.try_into().ok()?) as u64;
    at.checked_add(4)?
        .checked_add(length)
        .filter(|end| *end <= frame.length)
}

/// One declaration string, bounded independently of the record's extensible trailer.
fn string_at(records: &mut Streamed<'_>, frame: &Frame, at: u64) -> Option<String> {
    let prefix = records.range(frame, at, 4)?;
    let length = u32::from_le_bytes(prefix.try_into().ok()?) as u64;
    let bytes = records.range(frame, at.checked_add(4)?, length)?;
    String::from_utf8(bytes).ok()
}

fn header_declaration_refuses(records: &mut Streamed<'_>, frame: &Frame) -> bool {
    let Some(after_profile) = skip_string(records, frame, 0) else {
        return false;
    };
    let Some(after_library) = skip_string(records, frame, after_profile) else {
        return false;
    };
    // duration_sec, gaussian_count, cutoff
    let Some(temporal_model_at) = after_library.checked_add(8 + 8 + 8) else {
        return false;
    };
    string_at(records, frame, temporal_model_at)
        .is_some_and(|model| fourdgs::registry::check_temporal_model(&model).is_err())
}

fn quantization_declaration_refuses(records: &mut Streamed<'_>, frame: &Frame) -> bool {
    string_at(records, frame, 0)
        .is_some_and(|scheme| fourdgs::registry::check_quantization_scheme(&scheme).is_err())
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
    scene: &IndexedScene,
) -> std::result::Result<(), (Error, Option<Site>)> {
    if scene.index.is_empty() {
        return scan_streamed(&mut BytesReadable::new(data));
    }
    let mut source = BytesReadable::new(data);
    for (i, entry) in scene.index.iter().enumerate() {
        // The returned chunk is dropped here, at the end of the iteration.
        match read_chunk(&mut source, scene, entry, u8::MAX) {
            Err(error) => {
                let site = refusing_record(&mut source, scene, entry, i);
                return Err((error, Some(site)));
            }
            Ok(chunk) if chunk.count > 0 => {
                // Decode first, then compare the complete declaration. That order keeps a
                // bad band stream localized to its own physical record instead of hiding
                // it behind a second index-shape finding on the Chunk.
                let mut declared: Vec<u8> = entry.bands.iter().map(|(band, _, _)| *band).collect();
                declared.sort_unstable();
                let expected: Vec<u8> = (1..=scene.header.sh_degree).collect();
                if declared != expected {
                    return Err((
                        Error::Malformed(format!(
                            "the Chunk at byte {} carries SH bands {declared:?}; the Header declares degree {} and requires {expected:?}",
                            entry.chunk_offset, scene.header.sh_degree
                        )),
                        Some(Site {
                            offset: entry.chunk_offset,
                            what: format!("the Chunk record at index entry {i}"),
                        }),
                    ));
                }
            }
            Ok(_) => {}
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
/// a reader wants. So the two are told apart by asking it narrower questions — the chunk
/// with no bands at all, then one band range at a time — rather than by restating the
/// library's fetch here and drifting from it. It costs a second decode of one chunk, and it
/// only ever runs on the file that has already refused.
///
/// **One range at a time, not one band at a time.** Nothing in the index forbids two ranges
/// for the same band, and `read_chunk` decodes both of them — it keys the results by band,
/// so the second merely overwrites the first. Raising a cap therefore cannot distinguish
/// them: the cap that admits the bad duplicate admits the good one with it, and the offset
/// reported would be whichever sorted first. Handing `read_chunk` an entry carrying exactly
/// one range asks about exactly that range.
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
    // The chunk's own streams, with no band record admitted at all. Emptying the list is
    // what a cap of zero cannot do: a hostile index may declare a range for band 0, and a
    // cap of zero admits it — so the Chunk would be blamed for a band record's fault.
    let mut bare = entry.clone();
    bare.bands.clear();
    if read_chunk(source, scene, &bare, 0).is_err() {
        return chunk();
    }
    let mut ranges = entry.bands.clone();
    ranges.sort_by_key(|(band, at, _)| (*band, *at));
    for range in ranges {
        let (band, at, _) = range;
        let mut only = entry.clone();
        only.bands = vec![range];
        if read_chunk(source, scene, &only, band).is_err() {
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
/// Front to back over the framing, decoding each Chunk and each SH Band Stream on its own
/// and keeping neither. The library's streamed reader assembles the scene as it goes — which
/// is what a *reader* wants and what a validator must not do — so this drives the same
/// decode primitives directly and throws each result away.
///
/// Being framing-driven, it also places the refusal: an unindexed file used to report the
/// identifier with no byte at all, because "every chunk or none" was the only answer the
/// whole-file decode could give.
///
/// Streamed rather than handed a walk, because the other caller is the tool's error path,
/// which has a file it has just been refused and no reason to hold either the file or a
/// `Frame` per record of it. Nothing here outlives one record.
pub fn scan_streamed(source: &mut dyn Readable) -> std::result::Result<(), (Error, Option<Site>)> {
    let mut records = match Streamed::open(source) {
        Ok(records) => records,
        Err(error) => return Err((error, None)),
    };
    let mut quantization: Option<rec::Quantization> = None;
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut cutoff = fourdgs::quantization::DEFAULT_CUTOFF;
    // The count of the chunk a band record belongs to. Bands belong to the Chunk that
    // precedes them and are sized against it (spec §5.7).
    let mut count = 0usize;

    while let Some(frame) = records.next_frame() {
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
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                if let Ok(header) = rec::Header::parse(&content) {
                    cutoff = header.cutoff;
                }
            }
            op::QUANTIZATION => {
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                if let Ok(parsed) = rec::Quantization::parse(&content) {
                    quantization = Some(parsed);
                }
            }
            op::WINDOW_TABLE => {
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                if let Ok(table) = rec::WindowTable::parse(&content) {
                    windows = table.windows;
                }
            }
            op::CHUNK => {
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                // A Chunk before the grid it is quantized against is a fault the validator
                // reports itself; there is nothing to decode it with here.
                let Some(quantization) = &quantization else {
                    continue;
                };
                let (head, streams) =
                    rec::parse_chunk(&content).map_err(|error| (error, here()))?;
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
            op::DELTA_CHUNK => {
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                fourdgs::keyframe_delta_file::check_delta_chunk(&content, &windows)
                    .map_err(|error| (error, here()))?;
                if let Ok((head, _)) = rec::parse_delta_chunk_records(&content) {
                    count = head.birth_count as usize;
                }
            }
            op::SH_BAND_STREAM => {
                let Some(content) = records.content(&frame) else {
                    continue;
                };
                let mut cursor = Cursor::new(&content);
                // The band index, which the record carries and the stream header does not:
                // a band stream's `attribute_id` is 0x07 and collides with `mu_t` (§5.7).
                let band = cursor.u8().map_err(|error| (error, here()))?;
                if !(1..=3).contains(&band) {
                    return Err((
                        Error::Malformed(format!(
                            "the SH Band Stream at byte {} declares band {band}; only bands 1 through 3 are defined",
                            frame.offset
                        )),
                        here(),
                    ));
                }
                let (_, stream) =
                    decode_stream(&mut cursor, Some(count)).map_err(|error| (error, here()))?;
                let expected_channels = 3 * (2 * band as usize + 1);
                if stream.channels != expected_channels {
                    return Err((
                        Error::Malformed(format!(
                            "the SH Band Stream at byte {} for band {band} declares {} channels; band {band} requires {expected_channels}",
                            frame.offset, stream.channels
                        )),
                        here(),
                    ));
                }
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
    fn a_streaming_walk_retains_only_aggregate_facts_for_many_records() {
        let mut data = MAGIC.to_vec();
        for _ in 0..50_000 {
            fourdgs::serialization::put_record(&mut data, 0xee, &[]);
        }
        data.extend_from_slice(&MAGIC);

        let mut visited = 0usize;
        let summary = walk_each(&mut BytesReadable::new(&data), |_, intact| {
            assert!(intact);
            visited += 1;
        })
        .unwrap();

        assert_eq!(visited, 50_000);
        assert_eq!(summary.record_count, visited);
        assert_eq!(summary.intact, visited);
        assert!(summary.trailing_magic);
        assert!(summary.cut.is_none());
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
    fn a_file_cut_exactly_on_a_record_boundary_is_still_a_cut() {
        // The simplest truncation there is: remove only the trailing magic. Every record is
        // whole, the walk reaches the end of the last one with nothing left over — and it
        // used to leave through the `remaining == 0` door without recording a cut at all.
        // `inspect` then printed a note and exited 0 for an incomplete file, and `validate`
        // left off the intact-prefix note that says how much of it survives.
        let whole = valid();
        let data = &whole[..whole.len() - MAGIC.len()];
        let walk = walk(&mut BytesReadable::new(data)).unwrap();
        assert!(!walk.trailing_magic);
        let cut = walk
            .cut
            .as_ref()
            .expect("a file with no trailing magic is cut");
        assert_eq!(cut.at, data.len() as u64, "the cut is at the end");
        assert!(
            !cut.inside_a_record,
            "every record is whole; it is the magic that is missing"
        );
        // And nothing is lost: the prefix is the whole record list, which is what the
        // recovery note counts.
        assert_eq!(walk.intact(), walk.records.len());
    }

    #[test]
    fn a_whole_file_is_not_reported_as_cut() {
        // The other half of the rule above, because a cut invented for a conforming file
        // would take `inspect` to exit 1 on every good file in the corpus.
        let walk = walk(&mut BytesReadable::new(&valid())).unwrap();
        assert!(walk.trailing_magic);
        assert!(walk.cut.is_none());
    }

    /// A reader that remembers how far into the file it was asked to look.
    ///
    /// Placing a refusal is supposed to stop at the record that carries it. Nothing about
    /// peak memory can be asserted directly, but "which bytes were asked for" can, and it
    /// is the same claim: a walk that keeps a `Frame` per record has to visit every record
    /// to build them.
    struct Watched<'a> {
        inner: BytesReadable<'a>,
        furthest: u64,
    }

    impl<'a> Watched<'a> {
        fn new(data: &'a [u8]) -> Watched<'a> {
            Watched {
                inner: BytesReadable::new(data),
                furthest: 0,
            }
        }
    }

    impl Readable for Watched<'_> {
        fn size(&mut self) -> Result<u64> {
            self.inner.size()
        }

        fn read(&mut self, offset: u64, length: u64) -> Result<Vec<u8>> {
            self.furthest = self.furthest.max(offset.saturating_add(length));
            self.inner.read(offset, length)
        }
    }

    #[test]
    fn placing_a_front_matter_refusal_stops_at_the_record_that_carries_it() {
        // The Header is the first record in the file, and an unimplemented temporal model
        // is refused there — so the tool has its answer nine bytes in. Walking the rest of
        // the file to say so is what turned a bounded early refusal into memory
        // proportional to the file, on exactly the files that cannot be held.
        let mut data = crate::validate::sample_file(Vec::new());
        // A model this build does not implement, written over the one it does. Both names
        // are fourteen characters, so nothing in the file moves.
        let at = data
            .windows(14)
            .position(|w| w == b"gaussian-birth")
            .expect("the sample declares its temporal model");
        data[at..at + 14].copy_from_slice(b"frame-sequence");

        let mut source = Watched::new(&data);
        let site = locate_streaming(&mut source, id::UNKNOWN_TEMPORAL_MODEL)
            .expect("the Header is the record that declares it");
        assert_eq!(site.offset, MAGIC.len() as u64);
        let header_end = MAGIC.len() as u64
            + RECORD_HEADER_SIZE as u64
            + walk(&mut BytesReadable::new(&data))
                .unwrap()
                .first_intact(op::HEADER)
                .unwrap()
                .length;
        assert!(
            source.furthest <= header_end,
            "read to byte {} of a {}-byte file to place a refusal in the first record, \
             which ends at {header_end}",
            source.furthest,
            data.len()
        );
    }

    #[test]
    fn placing_a_front_matter_refusal_does_not_read_an_appended_trailer() {
        let mut data = crate::validate::sample_file(Vec::new());
        let header_at = MAGIC.len();
        let old_length = u64::from_le_bytes(
            data[header_at + 1..header_at + RECORD_HEADER_SIZE]
                .try_into()
                .unwrap(),
        ) as usize;
        let old_end = header_at + RECORD_HEADER_SIZE + old_length;
        let trailer = vec![0xA5; 1024 * 1024];
        data.splice(old_end..old_end, trailer.iter().copied());
        let new_length = old_length + trailer.len();
        data[header_at + 1..header_at + RECORD_HEADER_SIZE]
            .copy_from_slice(&(new_length as u64).to_le_bytes());
        let model = data
            .windows(14)
            .position(|w| w == b"gaussian-birth")
            .unwrap();
        data[model..model + 14].copy_from_slice(b"frame-sequence");

        let mut source = Watched::new(&data);
        let site = locate_streaming(&mut source, id::UNKNOWN_TEMPORAL_MODEL).unwrap();
        assert_eq!(site.offset, header_at as u64);
        assert!(
            source.furthest < old_end as u64,
            "the locator read through byte {}, into an appended trailer that starts at {old_end}",
            source.furthest
        );
    }

    #[test]
    fn placing_a_refusal_reports_no_byte_rather_than_the_wrong_one() {
        // A conforming file carries no refusing record, and the search says so instead of
        // naming whichever record it stopped at. An offset is believed; a missing one is
        // merely unhelpful.
        let data = valid();
        assert!(
            locate_streaming(&mut BytesReadable::new(&data), id::UNKNOWN_TEMPORAL_MODEL).is_none()
        );
        assert!(
            locate_streaming(&mut BytesReadable::new(&data), id::UNKNOWN_STREAM_CODEC).is_none()
        );
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
