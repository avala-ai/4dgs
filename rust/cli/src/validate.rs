// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Structural validation aligned with the Python reference's checks, order, and wording.
//! Rust additionally decodes payloads, supports `keyframe-delta`, prints refusal IDs and
//! bytes, and cites the currently reserved provenance range.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::PathBuf;

use fourdgs::quantization::{sh_bound, sh_step};
use fourdgs::serialization::{crc32, Records, MAGIC, RECORD_HEADER_SIZE};
use fourdgs::{opcode as op, records as rec, BytesReadable, Result};

use crate::args::Args;
use crate::refusal::{self, Framing, Named};
use crate::{EXIT_FAILED, EXIT_OK, EXIT_TOOL, EXIT_WARNINGS};

/// Fixed-memory distinct-id counting for a full-file validator.
///
/// Identity events are partitioned by the high nibble of their `u32` id into temporary
/// files. One partition is then reduced through a 2^28-bit bitmap (32 MiB), discarded, and
/// the next is read. Memory therefore does not grow with the number of chunks or lifetime
/// identities; only disk does, at this CLI I/O edge. This is the numeric-range strategy
/// described by the bounded full-file validation rule.
struct IdentityCounter {
    directory: ScratchDirectory,
    writers: Option<Vec<BufWriter<File>>>,
}

struct ScratchDirectory(PathBuf);

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl IdentityCounter {
    const BUCKETS: usize = 16;
    const LOW_BITS: usize = 28;

    fn new() -> std::io::Result<Self> {
        Self::new_with(|path| OpenOptions::new().create_new(true).write(true).open(path))
    }

    fn new_with<F>(mut open: F) -> std::io::Result<Self>
    where
        F: FnMut(&std::path::Path) -> std::io::Result<File>,
    {
        let base = std::env::temp_dir();
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let mut directory = None;
        for attempt in 0..100u32 {
            let candidate = base.join(format!(
                "4dgs-validate-ids-{}-{stamp}-{attempt}",
                std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => {
                    directory = Some(candidate);
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        let directory = ScratchDirectory(directory.ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "could not reserve a temporary identity-count directory",
            )
        })?);
        let mut writers = Vec::with_capacity(Self::BUCKETS);
        for bucket in 0..Self::BUCKETS {
            let file = open(&directory.0.join(format!("{bucket:02x}")))?;
            writers.push(BufWriter::new(file));
        }
        Ok(Self {
            directory,
            writers: Some(writers),
        })
    }

    fn add_one(&mut self, record_offset: u64, id: u32) -> Result<()> {
        let bucket = (id >> Self::LOW_BITS) as usize;
        let writer = &mut self.writers.as_mut().expect("counter is open")[bucket];
        writer.write_all(&id.to_le_bytes())?;
        writer.write_all(&record_offset.to_le_bytes())?;
        Ok(())
    }

    fn finish(mut self) -> Result<u64> {
        let mut writers = self.writers.take().expect("counter is open");
        for writer in &mut writers {
            writer.flush()?;
        }
        drop(writers);
        let words = 1usize << (Self::LOW_BITS - 6);
        let mut total = 0u64;
        for bucket in 0..Self::BUCKETS {
            let mut bits = vec![0u64; words];
            let mut reader =
                BufReader::new(File::open(self.directory.0.join(format!("{bucket:02x}")))?);
            loop {
                let mut raw = [0u8; 12];
                match reader.read_exact(&mut raw) {
                    Ok(()) => {
                        let id = u32::from_le_bytes(raw[..4].try_into().expect("identity word"));
                        let record_offset = u64::from_le_bytes(
                            raw[4..].try_into().expect("identity record offset"),
                        );
                        let low = (id & ((1u32 << Self::LOW_BITS) - 1)) as usize;
                        let mask = 1u64 << (low & 63);
                        if bits[low >> 6] & mask != 0 {
                            return Err(fourdgs::Error::Malformed(format!(
                                "gaussian_id {id} is introduced more than once; the reuse at byte {record_offset} is not allowed after death"
                            )));
                        }
                        bits[low >> 6] |= mask;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                    Err(error) => return Err(error.into()),
                }
            }
            total += bits
                .iter()
                .map(|word| word.count_ones() as u64)
                .sum::<u64>();
        }
        Ok(total)
    }
}

impl Drop for IdentityCounter {
    fn drop(&mut self) {
        self.writers.take();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Note,
    Warning,
    Error,
}

impl Severity {
    fn as_str(self) -> &'static str {
        match self {
            Severity::Note => "note",
            Severity::Warning => "warning",
            Severity::Error => "error",
        }
    }
}

/// One thing wrong with a file, and — when the library named it — which refusal it is.
#[derive(Debug)]
pub struct Finding {
    pub severity: Severity,
    /// Word for word what the Python validator prints for the same bytes.
    pub message: String,
    /// The refusal identifier and the byte it fired at, for the findings that have one.
    /// Most do not: "the Header declares 640 gaussians; chunks contain 256" is a rule this
    /// validator checks itself, not a refusal the reader raised, and the refusal table
    /// does not name it.
    pub refusal: Option<Named>,
}

#[derive(Debug, Default)]
pub struct Report {
    pub findings: Vec<Finding>,
}

/// An error's message without the kind its `Display` puts in front.
///
/// Matched rather than string-stripped so that a variant added later is a compile error
/// here instead of a sentence that quietly keeps its prefix.
fn bare_message(error: &fourdgs::Error) -> String {
    use fourdgs::Error;
    match error {
        Error::UnsupportedVersion(m)
        | Error::Truncated(m)
        | Error::Malformed(m)
        | Error::UnsupportedCodec(m)
        | Error::UnsupportedModel(m)
        | Error::BoundViolation(m)
        | Error::UnsupportedOperation(m)
        | Error::InvalidInput(m) => m.clone(),
        Error::Refused { message, .. } => message.clone(),
        Error::Io(e) => e.to_string(),
    }
}

impl Report {
    pub fn ok(&self) -> bool {
        !self.findings.iter().any(|f| f.severity == Severity::Error)
    }

    fn worst(&self) -> Option<Severity> {
        self.findings.iter().map(|f| f.severity).max()
    }

    fn push(&mut self, severity: Severity, message: String, refusal: Option<Named>) {
        self.findings.push(Finding {
            severity,
            message,
            refusal,
        });
    }

    fn error(&mut self, message: String) {
        self.push(Severity::Error, message, None);
    }

    fn warn(&mut self, message: String) {
        self.push(Severity::Warning, message, None);
    }

    fn note(&mut self, message: String) {
        self.push(Severity::Note, message, None);
    }

    /// An error the library raised, carrying its identifier and the byte if it has one.
    ///
    /// `prefix` is what the message is introduced with, so the sentence stays the one the
    /// other validator prints; the identifier arrives on its own line and changes nothing
    /// about it.
    ///
    /// The error's own message is printed, not its `Display` — `Display` puts the error
    /// KIND in front (`"malformed: "`, `"truncated: "`), which is right when the error is
    /// the whole of what is being reported and wrong here, where `prefix` has already
    /// said what could not be done. Doubling them reads "a seeking reader cannot open
    /// this file: malformed: ...", and worse, it is the divergence
    /// `both_validators_refuse_the_invalid_corpus_the_same_way` records as a known gap:
    /// this crate prefixed its kind and the Python validator did not, so the two printed
    /// different sentences about the same bytes. `UnsupportedModel` was already exempted
    /// from the kind prefix for exactly this reason, and its doc comment gives the rule —
    /// where the wording is contract between implementations, the sentence is the
    /// message alone. Every refusal a validator prints is that kind of wording.
    fn refused(
        &mut self,
        prefix: &str,
        error: &fourdgs::Error,
        framing: Option<Framing>,
        site: Option<refusal::Site>,
    ) {
        let named = refusal::describe(error, framing, site);
        self.push(
            Severity::Error,
            format!("{prefix}{}", bare_message(error)),
            named,
        );
    }
}

pub fn run(args: &Args) -> Result<u8> {
    // Whole-file, as the Python validator is: a validator's job is to answer for the file
    // it was handed rather than for the part of it that happened to be cheap, and the
    // summary CRC has to cover a contiguous region to mean anything. The bounded-memory
    // rule is about decode paths, and the decode this performs is chunk by chunk.
    let data = match std::fs::read(&args.file) {
        Ok(data) => data,
        // Not the file's fault, and not a refusal. See `EXIT_TOOL`.
        Err(error) => {
            eprintln!("4dgs: {}: {error}", args.file);
            return Ok(EXIT_TOOL);
        }
    };
    let report = match validate_checked(&data) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("4dgs: {}: validator tool failure: {error}", args.file);
            return Ok(EXIT_TOOL);
        }
    };
    for finding in &report.findings {
        out!("{}: {}", finding.severity.as_str(), finding.message);
        // Indented, and with a prefix of its own, so that a caller filtering the findings
        // on `error:`/`warning:`/`note:` — which is how the two validators are compared —
        // sees exactly what it saw before.
        if let Some(named) = &finding.refusal {
            out!("  {named}");
        }
    }
    if !report.ok() {
        eprintln!("INVALID");
        return Ok(EXIT_FAILED);
    }
    out!(
        "{}",
        if report.findings.is_empty() {
            "valid"
        } else {
            "valid (with notes)"
        }
    );
    // The one deliberate divergence from the Python tool, which exits 0 here. A warning a
    // script cannot see is a warning nobody acts on, so it gets its own code.
    Ok(if report.worst() == Some(Severity::Warning) {
        EXIT_WARNINGS
    } else {
        EXIT_OK
    })
}

/// Every check, in the Python validator's order.
#[cfg(test)]
pub fn validate(data: &[u8]) -> Report {
    validate_checked(data).unwrap_or_else(|error| {
        let mut report = Report::default();
        report.error(format!("the validator tool failed: {error}"));
        report
    })
}

fn validate_checked(data: &[u8]) -> Result<Report> {
    let mut report = Report::default();
    // Framing first, and for two reasons: it refuses a file that is not ours before
    // anything reads a byte as an opcode, and it is what gives every later refusal a byte
    // to point at.
    let mut refusing_header = None;
    let mut refusing_quantization = None;
    let walk = match refusal::walk_each(&mut BytesReadable::new(data), |frame, intact| {
        if !intact {
            return;
        }
        let Some(content) = frame.content(data) else {
            return;
        };
        match frame.opcode {
            op::HEADER
                if refusing_header.is_none()
                    && rec::Header::parse(content).is_ok_and(|header| {
                        fourdgs::registry::check_temporal_model(&header.temporal_model).is_err()
                    }) =>
            {
                refusing_header = Some(frame);
            }
            op::QUANTIZATION
                if refusing_quantization.is_none()
                    && rec::Quantization::parse(content).map_or_else(
                        |error| {
                            error.refusal_code()
                                == Some(fourdgs::error::refusal::NON_POSITIVE_STEP_TIME)
                        },
                        |quantization| {
                            fourdgs::registry::check_quantization_scheme(&quantization.scheme)
                                .is_err()
                        },
                    ) =>
            {
                refusing_quantization = Some(frame);
            }
            _ => {}
        }
    }) {
        Ok(walk) => walk,
        Err(error) => {
            report.refused("", &error, None, None);
            return Ok(report);
        }
    };
    if !data.ends_with(&MAGIC) {
        report.error(
            "file does not end with the magic; it is truncated or was written by a broken encoder"
                .into(),
        );
    }

    let mut seen: Vec<u8> = Vec::new();
    let mut header: Option<rec::Header> = None;
    let mut quantization = false;
    let mut quantization_count = 0usize;
    let mut footer: Option<rec::Footer> = None;
    let mut chunk_count = 0u64;
    let mut counted = 0u64;
    let mut index: Vec<rec::ChunkIndexEntry> = Vec::new();
    let mut audio_sources: BTreeMap<u32, rec::AudioSource> = BTreeMap::new();
    let mut audio_data: BTreeMap<u32, usize> = BTreeMap::new();
    let mut first_chunk_seen = false;

    for record in Records::new(data, MAGIC.len()) {
        let record = match record {
            Ok(record) => record,
            Err(error) => {
                report.error(format!("stopped reading: {error}"));
                break;
            }
        };
        seen.push(record.opcode);
        // A record whose own body will not parse is a finding rather than an abort: the
        // point of a validator is to say everything that is wrong with a file, not the
        // first thing.
        match record.opcode {
            op::HEADER => match rec::Header::parse(record.content) {
                Ok(parsed) => header = Some(parsed),
                Err(error) => report.error(format!("Header does not parse: {error}")),
            },
            op::QUANTIZATION => match rec::Quantization::parse(record.content) {
                Ok(parsed) => {
                    // Checked here, as the record is met, rather than once at the end on
                    // whichever copy survived. See `check_quantization_finite`.
                    check_quantization_finite(&parsed, &mut report, quantization_count);
                    let degree = header.as_ref().map(|h| h.sh_degree).unwrap_or(0);
                    check_sh_bit_depths(&parsed, degree, &mut report);
                    quantization_count += 1;
                    quantization = true;
                }
                Err(error) => report.error(format!("Quantization does not parse: {error}")),
            },
            op::CHUNK => match rec::parse_chunk(record.content) {
                Ok((head, _)) => {
                    first_chunk_seen = true;
                    chunk_count += 1;
                    counted += head.count as u64;
                    if head.t1 < head.t0 {
                        report.error(format!(
                            "chunk {chunk_count} has t1 ({}) before t0 ({})",
                            head.t1, head.t0
                        ));
                    }
                }
                Err(error) => {
                    first_chunk_seen = true;
                    chunk_count += 1;
                    report.error(format!("chunk {chunk_count} does not parse: {error}"));
                }
            },
            op::CHUNK_INDEX => match rec::ChunkIndexEntry::parse(record.content) {
                Ok(entry) => index.push(entry),
                Err(error) => report.error(format!("a chunk index entry does not parse: {error}")),
            },
            op::FOOTER => match rec::Footer::parse(record.content) {
                Ok(parsed) => footer = Some(parsed),
                Err(error) => report.error(format!("Footer does not parse: {error}")),
            },
            op::AUDIO_SOURCE => match rec::AudioSource::parse(record.content) {
                Ok(source) => {
                    if first_chunk_seen {
                        report.error(format!(
                            "Audio Source id {} appears after the first Chunk",
                            source.source_id
                        ));
                    }
                    let id = source.source_id;
                    if audio_sources.insert(id, source).is_some() {
                        report.error(format!("Audio Source id {id} appears more than once"));
                    }
                }
                Err(error) => report.error(format!("Audio Source does not parse: {error}")),
            },
            op::AUDIO_DATA => match rec::AudioData::parse(record.content) {
                Ok(payload) => {
                    if first_chunk_seen {
                        report.error(format!(
                            "Audio Data id {} appears after the first Chunk",
                            payload.source_id
                        ));
                    }
                    let id = payload.source_id;
                    if audio_data.insert(id, payload.data.len()).is_some() {
                        report.error(format!("Audio Data id {id} appears more than once"));
                    }
                }
                Err(error) => report.error(format!("Audio Data does not parse: {error}")),
            },
            opcode if op::is_private(opcode) => report.note(format!(
                "private record 0x{opcode:02X} ({} bytes) — skipped, as required",
                record.content.len()
            )),
            // Object Table/Track own 0x24/0x25; only 0x26-0x2F remains reserved by §5.15.8.
            // Keep this note distinct from wholly unknown opcodes.
            opcode if op::is_provenance(opcode) && !is_specified(opcode) => report.note(format!(
                "reserved provenance record 0x{opcode:02X} — skipped, as required \
                 (0x26-0x2F, section 5.15.8)"
            )),
            opcode if !is_specified(opcode) => report.note(format!(
                "unknown record 0x{opcode:02X} — skipped, as required"
            )),
            _ => {}
        }
    }

    if seen.is_empty() {
        report.error("no records at all".into());
        return Ok(report);
    }
    if seen[0] != op::HEADER {
        report.error(format!(
            "first record is {}; the Header must come first",
            op::name(seen[0])
        ));
    }
    if header.is_none() {
        report.error("no Header record".into());
    }
    if !quantization {
        report.error("no Quantization record".into());
    }
    if footer.is_none() {
        report.error("no Footer record".into());
    } else if seen.last() != Some(&op::FOOTER) {
        let final_record = seen
            .last()
            .map_or_else(|| "nothing".into(), |opcode| op::name(*opcode));
        report.error(format!(
            "the final record is {final_record}; the Footer must be final"
        ));
    }

    // Which chunk shape the rest of this validator is entitled to assume. A
    // `keyframe-delta` file's Chunks are keyframes and its Delta Chunks are differences
    // against them, so several checks below are about the gaussian-birth shape and about
    // nothing else. Read from the Header rather than guessed from the records, because a
    // file that carries Delta Chunks and does not say so is itself a fault.
    let keyframe_delta = header
        .as_ref()
        .is_some_and(|h| h.temporal_model == "keyframe-delta");

    if keyframe_delta && !index.is_empty() {
        let mut indexed_offsets = BTreeSet::new();
        for (i, entry) in index.iter().enumerate() {
            if !indexed_offsets.insert(entry.chunk_offset) {
                report.error(format!(
                    "chunk index entry {i} repeats state record byte {}; every physical state record has exactly one index entry",
                    entry.chunk_offset
                ));
            }
        }
        for record in Records::new(data, MAGIC.len()).filter_map(|record| record.ok()) {
            if matches!(record.opcode, op::CHUNK | op::DELTA_CHUNK)
                && !indexed_offsets.contains(&(record.offset as u64))
            {
                report.error(format!(
                    "the {} record at byte {} has no Chunk Index entry; streamed and indexed reads must see the same state records",
                    op::name(record.opcode),
                    record.offset
                ));
            }
        }
    }

    if let Some(header) = &header {
        // `gaussian_count` counts distinct gaussians over the whole sequence under
        // `keyframe-delta`, and every keyframe carries a full population — so the sum
        // across chunks is a larger number by design, not a disagreement. Summing them
        // anyway is what made both validators call a conforming keyframe-delta file
        // invalid.
        if !keyframe_delta && counted != header.gaussian_count {
            report.error(format!(
                "Header declares {} gaussians; chunks contain {counted}",
                header.gaussian_count
            ));
        }
        let has_audio_records =
            seen.contains(&op::AUDIO) || !audio_sources.is_empty() || !audio_data.is_empty();
        if header.has_audio() && !has_audio_records {
            report.error(
                "Header says the file has audio, but there is no Audio Source or legacy Audio record"
                    .into(),
            );
        }
        if !header.has_audio() && has_audio_records {
            report.error(
                "there is an Audio Source or legacy Audio record, but the Header's audio flag is clear"
                    .into(),
            );
        }
        for source in audio_sources.values() {
            validate_audio_source(source, header.duration_sec, &mut report);
        }
    }
    if seen.contains(&op::AUDIO) && !audio_sources.is_empty() {
        report.error("legacy Audio and Audio Source records must not be mixed".into());
    }
    for (source_id, source) in &audio_sources {
        match audio_data.get(source_id) {
            None => report.error(format!(
                "Audio Source id {source_id} has no matching Audio Data record"
            )),
            Some(length) if source.data_length != *length as u64 => report.error(format!(
                "Audio Source id {source_id} declares {} bytes; Audio Data contains {length}",
                source.data_length
            )),
            Some(_) => {}
        }
    }
    for source_id in audio_data.keys() {
        if !audio_sources.contains_key(source_id) {
            report.error(format!(
                "Audio Data id {source_id} has no matching Audio Source record"
            ));
        }
    }

    for (i, entry) in index.iter().enumerate() {
        let end = entry.chunk_offset.saturating_add(entry.chunk_length);
        let at = data.get(entry.chunk_offset as usize).copied();
        // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta
        // Chunk is a difference against one, and an index that could only name the former
        // could not seek the model at all.
        let addressable = at == Some(op::CHUNK) || (keyframe_delta && at == Some(op::DELTA_CHUNK));
        if end > data.len() as u64 {
            report.error(format!(
                "chunk index entry {i} points past the end of the file"
            ));
        } else if !addressable {
            report.error(format!(
                "chunk index entry {i} does not point at a Chunk record"
            ));
        }
    }

    if let Some(footer) = &footer {
        if footer.summary_crc != 0 && footer.summary_start != 0 {
            // The footer record itself is not covered: 9 bytes of framing plus its 20
            // bytes of content plus the trailing magic.
            let tail = data.len() - (RECORD_HEADER_SIZE + 20 + MAGIC.len());
            let start = footer.summary_start as usize;
            if start > tail {
                report.error(format!(
                    "the Footer's summary starts at {start}, after the summary ends at {tail}"
                ));
            } else if crc32(&data[start..tail]) != footer.summary_crc {
                report.error(
                    "summary CRC mismatch: the index is untrustworthy (a streamed read still works)"
                        .into(),
                );
            }
        }
    }

    if header.is_some() && index.is_empty() {
        report.warn("no chunk index: this file can only be read front to back, not seeked".into());
    }

    // What survived the cut, which is the question the errors above do not answer.
    //
    // A cut file is invalid and every finding about it stands — but records are
    // length-prefixed, so everything complete before the cut is intact and the library's
    // streamed reader keeps it. Saying only that the file stopped reading leaves its
    // holder to guess whether anything is salvageable; this says how much.
    if let Some(cut) = &walk.cut {
        report.note(format!(
            "the file is cut at byte {}: {}. The {} complete records before it are intact, \
             and a streamed reader recovers them",
            crate::commas(cut.at),
            cut.reason,
            walk.intact
        ));
    }

    // Refusal placement needs only the first front-matter record that actually refuses,
    // never one Frame per record in the file.  The framing pass above retains these two
    // candidates and aggregate cut facts only; chunk diagnostics already carry their
    // exact site from the chunk-by-chunk decoder.
    let location_walk = refusal::Walk {
        records: [refusing_header, refusing_quantization]
            .into_iter()
            .flatten()
            .collect(),
        cut: None,
        trailing_magic: walk.trailing_magic,
        size: walk.size,
    };
    let fetch = |frame: &refusal::Frame| frame.content(data).map(<[u8]>::to_vec);
    let framing = Framing {
        walk: &location_walk,
        fetch: &fetch,
    };
    if keyframe_delta {
        check_keyframe_delta(data, framing, index.is_empty(), &mut report)?;
    } else {
        check_gaussian_birth(data, framing, &mut report);
    }

    Ok(report)
}

/// The two checks that only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks
/// is where the rest do, and there is no substitute for it: the framing walk above steps
/// over a chunk by its declared length, so an unimplemented stream codec and an
/// out-of-range window index are both invisible to everything before this point. Both are
/// in the invalid corpus, and both used to validate clean.
fn check_gaussian_birth(data: &[u8], framing: Framing, report: &mut Report) {
    let scene = match fourdgs::indexed_reader::open_indexed(&mut BytesReadable::new(data)) {
        Ok(scene) => scene,
        Err(error) => {
            report.refused(
                "a seeking reader cannot open this file: ",
                &error,
                Some(framing),
                None,
            );
            // A file that will not open will not decode either, and the second error would
            // say the same thing about the same byte.
            return;
        }
    };
    if let Err((error, site)) = refusal::scan_chunks(data, &scene) {
        report.refused("a chunk does not decode: ", &error, Some(framing), site);
    }
}

fn check_keyframe_delta(
    data: &[u8],
    framing: Framing,
    unindexed: bool,
    report: &mut Report,
) -> Result<()> {
    let mode = if unindexed {
        fourdgs::keyframe_delta_validate::ValidationMode::Streamed
    } else {
        fourdgs::keyframe_delta_validate::ValidationMode::Indexed
    };
    let mut identities = IdentityCounter::new()?;
    let result = fourdgs::keyframe_delta_validate::validate(
        &mut BytesReadable::new(data),
        mode,
        |record_offset, id| identities.add_one(record_offset, id),
    );
    let summary = match result {
        Ok(summary) => summary,
        Err(failure) if matches!(failure.error, fourdgs::Error::Io(_)) => return Err(failure.error),
        Err(failure) => {
            let site = failure.offset.map(|offset| refusal::Site {
                offset,
                what: "the keyframe-delta record".into(),
            });
            report.refused(
                "a keyframe-delta payload does not decode: ",
                &failure.error,
                Some(framing),
                site,
            );
            return Ok(());
        }
    };
    match identities.finish() {
        Ok(count) if count != summary.declared_gaussian_count => report.error(format!(
            "Header declares {} distinct gaussians; keyframes and birth groups introduce {count}",
            summary.declared_gaussian_count
        )),
        Err(error) if matches!(error, fourdgs::Error::Io(_)) => return Err(error),
        Err(error) => report.error(format!("the file's identities are invalid: {error}")),
        _ => {}
    }
    Ok(())
}

/// Every step and origin must be finite (spec §5.3).
///
/// A non-finite step is the one corrupt field that ruins every gaussian rather than one:
/// each bin multiplied by it decodes to infinity or NaN, so the whole scene comes out with
/// no position to occupy. Nothing downstream complains — dequantization is arithmetic and
/// arithmetic on infinity is defined — so without this check the first symptom is a
/// renderer drawing an empty frame, which points at the renderer.
///
/// Reported per field, because "the file is broken" is what the caller already knows.
///
/// Called once per Quantization record as it is walked, not once on whichever record
/// survived the loop. Nothing in the framing forbids a second one, and a streamed decoder
/// takes the first grid it meets — so checking only the last would pass a file whose first
/// grid is non-finite while the whole scene decodes through it.
fn check_quantization_finite(quant: &rec::Quantization, report: &mut Report, ordinal: usize) {
    // Named when there is more than one, so the report points at the offending copy
    // rather than at "the" Quantization record.
    let where_ = if ordinal == 0 {
        "Quantization".to_string()
    } else {
        format!("Quantization record {}", ordinal + 1)
    };
    let origin = |i: usize| quant.pos_origin.get(i).copied().unwrap_or(f64::NAN);
    for (name, value) in [
        ("pos_origin[0]", origin(0)),
        ("pos_origin[1]", origin(1)),
        ("pos_origin[2]", origin(2)),
        ("step_pos", quant.step_pos),
        ("step_scale_log", quant.step_scale_log),
        ("step_rot", quant.step_rot),
        ("step_rgb", quant.step_rgb),
        ("step_alpha", quant.step_alpha),
        ("step_motion", quant.step_motion),
        ("step_time", quant.step_time),
        ("step_sigma_log", quant.step_sigma_log),
    ] {
        if !value.is_finite() {
            report.error(format!(
                "{where_} {name} is {}; every step and origin must be finite (§5.3)",
                spell(value)
            ));
        }
    }
}

/// The per-band SH bit depths, against the degree the Header declares (spec §6.5).
///
/// Only checked when the file actually carries bands. Appended fields are positional, so a
/// record that ends in bytes some other writer appended can parse as a depth list by
/// coincidence; on a file with no coefficients that is a false alarm waiting to happen, and
/// there is nothing for the declaration to be wrong about.
fn check_sh_bit_depths(quant: &rec::Quantization, sh_degree: u8, report: &mut Report) {
    if quant.sh_bit_depths.is_empty() || sh_degree == 0 {
        return;
    }
    let degree = sh_degree as usize;
    if quant.sh_bit_depths.len() != degree {
        report.error(format!(
            "Quantization declares {} SH bit depths; the Header declares degree {sh_degree}, \
             and there is one band per degree (§6.5)",
            quant.sh_bit_depths.len()
        ));
    }
    let declared: Vec<u8> = quant.sh_bit_depths.iter().copied().take(degree).collect();
    for (i, bits) in declared.iter().enumerate() {
        let band = i + 1;
        let key = format!("sh_band{band}");
        let expected = sh_bound(*bits);
        match quant.bounds.get(&key) {
            None => report.warn(format!(
                "Quantization declares {bits} bits for SH band {band} but no `{key}` bound (§5.3)"
            )),
            Some(found) if !decimal_equals_integer(found, expected) => report.warn(format!(
                "Quantization declares `{key}` as {found}; {bits} bits gives a bound of {expected} (§6.5)"
            )),
            Some(_) => {}
        }
    }
    let coarsest = declared.iter().map(|b| sh_step(*b)).max().unwrap_or(1);
    if quant.step_sh != coarsest {
        report.warn(format!(
            "Quantization step_sh is {}; the coarsest declared band has a pitch of {coarsest}, \
             which is what a consumer that reads only step_sh has to be given (§6.5)",
            quant.step_sh
        ));
    }
}

/// Whether the §5.3 bound `value` spells exactly the small non-negative integer `expected`.
///
/// Matched against the grammar the specification writes down rather than against whatever a
/// decimal library parses, which is what makes this agree with the Python, TypeScript and Dart
/// validators on every input instead of on the ones their runtimes happen to read alike. There
/// is no trim: §5.3 admits nothing around the number, so `value.trim()` — Unicode `White_Space`,
/// which is neither Python's set nor JavaScript's — accepted spellings the format does not have.
///
/// Digits are compared as digits: no exponent is too large to read, nothing is built from the
/// exponent, and nothing passes through binary64.
fn decimal_equals_integer(value: &str, expected: u8) -> bool {
    let mut value = value;
    let negative = if let Some(rest) = value.strip_prefix('-') {
        value = rest;
        true
    } else {
        value = value.strip_prefix('+').unwrap_or(value);
        false
    };
    let mut exponent_parts = value.split(['e', 'E']);
    let mantissa = exponent_parts.next().unwrap_or_default();
    let exponent = match exponent_parts.next() {
        Some(part) if !part.is_empty() => part,
        Some(_) => return false,
        None => "0",
    };
    if exponent_parts.next().is_some() {
        return false;
    }
    let exponent_digits = exponent
        .strip_prefix('+')
        .or_else(|| exponent.strip_prefix('-'))
        .unwrap_or(exponent);
    if exponent_digits.is_empty() || !exponent_digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    // The significand: ASCII digits with at most one point, and at least one digit. The
    // string is bounded by the String Map value it was already read from.
    let mut digits = String::with_capacity(mantissa.len());
    let mut integer_digits = 0usize;
    let mut saw_decimal = false;
    for byte in mantissa.bytes() {
        match byte {
            b'0'..=b'9' => {
                digits.push(char::from(byte));
                if !saw_decimal {
                    integer_digits += 1;
                }
            }
            b'.' if !saw_decimal => saw_decimal = true,
            _ => return false,
        }
    }
    if digits.is_empty() {
        return false;
    }
    // A significand of zeroes is the value zero, at whatever exponent it carries.
    let Some(first_nonzero) = digits.bytes().position(|byte| byte != b'0') else {
        return expected == 0;
    };
    if negative {
        return false;
    }

    let significant = digits[first_nonzero..].trim_end_matches('0');
    let expected = expected.to_string();
    let required_exponent =
        expected.len() as isize - integer_digits as isize + first_nonzero as isize;
    significant == expected && decimal_integer_equals(exponent, required_exponent)
}

/// Whether the signed digit string `value` is `expected`, without building the number.
fn decimal_integer_equals(value: &str, expected: isize) -> bool {
    let (negative, digits) = if let Some(rest) = value.strip_prefix('-') {
        (true, rest)
    } else {
        (false, value.strip_prefix('+').unwrap_or(value))
    };
    if digits.is_empty() {
        return false;
    }
    let digits = digits.trim_start_matches('0');
    if digits.is_empty() {
        return expected == 0;
    }
    negative == expected.is_negative() && digits == expected.unsigned_abs().to_string()
}

/// A non-finite value spelled the way Python spells it, so that the two validators'
/// findings are the same string rather than the same complaint. Rust writes `NaN` where
/// Python writes `nan`, and a report a caller diffs is a report where that matters.
fn spell(v: f64) -> String {
    if v.is_nan() {
        "nan".into()
    } else {
        format!("{v}")
    }
}

/// True for the opcodes the specification defines. Everything else is either the
/// application range or a record from a version this build does not implement, and both
/// are skipped rather than refused.
///
/// The provenance family is listed by name rather than by range: `0x20`-`0x2F` is reserved
/// as a whole, and only six of those numbers are defined. Calling the other ten
/// "specified" would silence the note that tells a reader a record came from a later
/// revision; calling the six of them "unknown" — which is what this did before — reported
/// four notes about a conforming file that the Python validator says nothing about.
fn is_specified(opcode: u8) -> bool {
    (op::HEADER..=op::AUDIO_DATA).contains(&opcode)
        || matches!(
            opcode,
            op::COORDINATE_FRAME
                | op::SENSOR_CALIBRATION
                | op::RIG_TRAJECTORY
                | op::GEODETIC_ANCHOR
                | op::OBJECT_TABLE
                | op::OBJECT_TRACK
        )
}

fn validate_audio_source(source: &rec::AudioSource, scene_duration: f64, report: &mut Report) {
    let finite = source.start_sec.is_finite()
        && source.duration_sec.is_finite()
        && source.gain.is_finite()
        && source.position.iter().all(|value| value.is_finite())
        && source.rotation.iter().all(|value| value.is_finite());
    if !finite {
        report.error(format!(
            "Audio Source id {} has a non-finite numeric field",
            source.source_id
        ));
    }
    if source.rotation.iter().all(|value| *value == 0.0) {
        report.error(format!(
            "Audio Source id {} has a zero rotation quaternion",
            source.source_id
        ));
    }
    if source.codec.is_empty() {
        report.error(format!(
            "Audio Source id {} has an empty codec",
            source.source_id
        ));
    }
    if source.duration_sec <= 0.0 {
        report.error(format!(
            "Audio Source id {} duration_sec must be positive",
            source.source_id
        ));
    }
    if source.gain < 0.0 {
        report.error(format!(
            "Audio Source id {} gain must be non-negative",
            source.source_id
        ));
    }
    if source.spatial() && source.channel_layout != "mono" {
        report.error(format!(
            "spatial Audio Source id {} must use channel_layout 'mono'",
            source.source_id
        ));
    }
    if source.flags & !(rec::AUDIO_SOURCE_SPATIAL | rec::AUDIO_SOURCE_LOOP) != 0 {
        report.error(format!(
            "Audio Source id {} has reserved flag bits set",
            source.source_id
        ));
    }
    if source.interpolation != "linear" && source.interpolation != "step" {
        report.error(format!(
            "Audio Source id {} uses unknown interpolation {:?}",
            source.source_id, source.interpolation
        ));
    }
    let mut last = f64::NEG_INFINITY;
    for (index, keyframe) in source.keyframes.iter().enumerate() {
        let pose_finite = keyframe.position.iter().all(|value| value.is_finite())
            && keyframe.rotation.iter().all(|value| value.is_finite());
        if !keyframe.time.is_finite() || keyframe.time <= last || !pose_finite {
            report.error(format!(
                "Audio Source id {} keyframe {index} must have a finite, strictly increasing time and finite pose",
                source.source_id
            ));
        }
        if keyframe.rotation.iter().all(|value| *value == 0.0) {
            report.error(format!(
                "Audio Source id {} keyframe {index} has a zero rotation quaternion",
                source.source_id
            ));
        }
        if keyframe.time < 0.0 || keyframe.time > scene_duration {
            report.error(format!(
                "Audio Source id {} keyframe {index} time {} is outside [0, {scene_duration}]",
                source.source_id, keyframe.time
            ));
        }
        last = keyframe.time;
    }
}

/// A conforming file, for the tests below. Written by the library's own encoder so that
/// the fixtures cannot drift away from what the format says.
///
/// `extra` is emitted verbatim by the encoder rather than spliced in afterwards: splicing
/// shifts every offset the index holds, which produces a corrupt file rather than the
/// file from a newer writer the caller was asking for.
#[cfg(test)]
pub fn sample_file(extra: Vec<Vec<u8>>) -> Vec<u8> {
    use fourdgs::{GaussianSet, WriteOptions};
    let mut g = GaussianSet::default();
    // Spread over the unit cube, and irregularly: an encoder derives its quantization grid
    // from the scene's own extent, so a scene with no extent has no grid to derive — and
    // one whose points sit exactly on the grid it induces measures the encoder's rounding
    // at the tie, which is the encoder's business and not this test's.
    let mut state: u32 = 20260728;
    let mut rnd = || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state as f32 / 4294967296.0
    };
    for i in 0..32u32 {
        let u = i as f32 / 32.0;
        g.positions
            .extend_from_slice(&[rnd() * 2.0 - 1.0, rnd() * 2.0 - 1.0, rnd() * 2.0 - 1.0]);
        g.scales.extend_from_slice(&[0.01, 0.02, 0.015]);
        g.rotations.extend_from_slice(&[0.0, 0.0, 0.0, 1.0]);
        g.colors.extend_from_slice(&[u, 1.0 - u, 0.5, 0.9]);
        g.motions.extend_from_slice(&[0.1, 0.0, -0.1]);
        g.mu_t.push(u);
        g.sigma_t.push(0.25);
        g.win_lo.push(0.0);
        g.win_hi.push(1.0);
    }
    let options = WriteOptions {
        extra_records: extra,
        ..Default::default()
    };
    fourdgs::write_to_vec(&g, 1.0, &options, &Default::default()).unwrap()
}

#[cfg(test)]
fn minimal() -> Vec<u8> {
    sample_file(Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_setup_failure_removes_partial_scratch_directory() {
        let mut opened = 0;
        let mut directory = None;
        let result = IdentityCounter::new_with(|path| {
            opened += 1;
            directory.get_or_insert_with(|| path.parent().unwrap().to_owned());
            if opened == 2 {
                return Err(std::io::Error::other("injected partition failure"));
            }
            OpenOptions::new().create_new(true).write(true).open(path)
        });
        assert!(result.is_err());
        assert!(!directory.unwrap().exists());
    }

    /// A well-formed Quantization record, with any field replaceable — the Rust half of
    /// the Python suite's `grids()`, field for field.
    fn grids() -> rec::Quantization {
        rec::Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: vec![0.0, 0.0, 0.0],
            step_pos: 1e-4,
            step_scale_log: 0.04,
            step_rot: 0.004,
            step_rgb: 0.008,
            step_alpha: 0.008,
            step_motion: 2e-4,
            step_time: 0.004,
            step_sigma_log: 0.04,
            step_sh: 1,
            bounds: Default::default(),
            sh_bit_depths: Vec::new(),
        }
    }

    /// The smallest thing that is meant to validate: header, grids, windows, footer.
    fn minimal_file(quant: &rec::Quantization) -> Vec<u8> {
        minimal_file_with(std::slice::from_ref(quant))
    }

    /// The same, with however many Quantization records the caller wants. More than one is
    /// legal framing, and the case the per-record check exists for.
    fn minimal_file_with(quants: &[rec::Quantization]) -> Vec<u8> {
        minimal_file_headed(&["gaussian-birth"], quants)
    }

    /// The same again, with however many Header records the caller wants too, each
    /// declaring the temporal model named. Duplicate front matter is legal framing, and a
    /// reader checks every copy it meets — so which copy a refusal is about is a question
    /// with a wrong answer available.
    fn minimal_file_headed(models: &[&str], quants: &[rec::Quantization]) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        for model in models {
            out.extend_from_slice(
                &rec::Header {
                    duration_sec: 1.0,
                    gaussian_count: 0,
                    aabb: vec![0.0; 6],
                    temporal_model: (*model).into(),
                    ..Default::default()
                }
                .encode(&[]),
            );
        }
        for quant in quants {
            out.extend_from_slice(&quant.encode(&[]));
        }
        out.extend_from_slice(
            &rec::WindowTable {
                windows: vec![(0.0, 1.0)],
            }
            .encode(),
        );
        out.extend_from_slice(&rec::Footer::default().encode());
        out.extend_from_slice(&MAGIC);
        out
    }

    fn errors(report: &Report) -> Vec<String> {
        report
            .findings
            .iter()
            .filter(|f| f.severity == Severity::Error)
            .map(|f| f.message.clone())
            .collect()
    }

    #[test]
    fn an_identity_introduction_is_never_counted_twice() {
        let mut identities = IdentityCounter::new().unwrap();
        identities.add_one(100, 17).unwrap();
        identities.add_one(240, 17).unwrap();
        let error = identities.finish().unwrap_err();
        assert!(error.to_string().contains("reuse at byte 240"), "{error}");
    }

    #[test]
    fn a_minimal_handmade_file_validates_clean() {
        let report = validate(&minimal_file(&grids()));
        assert!(report.ok(), "{:?}", errors(&report));
        assert!(errors(&report).is_empty(), "{:?}", errors(&report));
    }

    /// The spellings section 5.3's grammar accepts, against the bound each one declares.
    ///
    /// The identical table is checked by the Python, TypeScript and Dart validators. A row
    /// that moves here without moving there is the disagreement the grammar exists to end,
    /// so keep the four in step.
    fn equivalent_bound_spellings(long_fraction: &str) -> Vec<(&str, u8)> {
        vec![
            ("16", 16),
            ("16.", 16),
            ("16.0", 16),
            ("+016.000", 16),
            ("1.6e1", 16),
            ("160e-1", 16),
            ("0.16E2", 16),
            ("8", 8),
            ("0.8e1", 8),
            ("80e-1", 8),
            (".4e1", 4),
            (long_fraction, 4),
            ("0", 0),
            ("0.0", 0),
            ("-0", 0),
            ("+0.000", 0),
            ("0e999999999999999999999999", 0),
            ("0.0e-999999999999999999999999", 0),
        ]
    }

    /// The spellings section 5.3's grammar refuses, against the bound the record declares.
    ///
    /// Several are accepted by one runtime's decimal type or another: underscores and other
    /// scripts' digits by Python's `Decimal`, U+FEFF by JavaScript's whitespace class, and
    /// U+001C through U+001F by Python's. That is exactly why the grammar is matched here
    /// rather than delegated to a runtime.
    fn rejected_bound_spellings() -> Vec<(&'static str, u8)> {
        vec![
            ("1_6", 16),
            ("8_0e-1", 8),
            ("_16", 16),
            ("16_", 16),
            ("\u{0661}\u{0666}", 16), // Arabic-Indic one six
            ("\u{0668}", 8),          // Arabic-Indic eight
            ("\u{0668}\u{0660}e-\u{06f1}", 8),
            ("\u{ff11}\u{ff16}", 16), // fullwidth one six
            ("\u{2078}", 8),          // superscript eight, a digit in no grammar
            ("\u{feff}16", 16),       // a byte-order mark is data, not padding
            ("\u{feff}4", 4),
            ("16\u{feff}", 16),
            ("\u{001c}8", 8), // Python's `Decimal` trims U+001C; the grammar does not
            ("\u{001f}16", 16),
            (" 16 ", 16),
            ("\t16", 16),
            ("16\n", 16),
            ("\u{2009}16", 16), // thin space
            ("16.0000000000000001", 16),
            ("15.9999999999999999", 16),
            ("1.6", 16),
            ("16e", 16),
            ("16e+", 16),
            ("16e-", 16),
            ("16eNaN", 16),
            ("", 16),
            (".", 16),
            ("+", 16),
            ("_", 0),
            ("NaN", 0),
            ("nan", 0),
            ("Infinity", 16),
            ("inf", 16),
            ("-16", 16),
            ("0e", 0),
            ("0_0", 0),
            ("\u{0660}", 0), // Arabic-Indic zero
            ("\u{feff}0", 0),
            ("\u{001c}0", 0),
            ("1", 0),
        ]
    }

    /// The SH bit depth whose section 6.5 bound is `bound`.
    fn depth_for_bound(bound: u8) -> u8 {
        match bound {
            16 => 3,
            8 => 4,
            4 => 5,
            0 => 8,
            other => panic!("no SH bit depth gives a bound of {other}"),
        }
    }

    #[test]
    fn a_bound_is_read_by_the_grammar_the_specification_writes_down() {
        let long_fraction = format!("0.{}4e1001", "0".repeat(1000));
        for (spelling, expected) in equivalent_bound_spellings(&long_fraction) {
            assert!(
                decimal_equals_integer(spelling, expected),
                "{spelling:?} should be {expected}"
            );
        }
        for (spelling, expected) in rejected_bound_spellings() {
            assert!(
                !decimal_equals_integer(spelling, expected),
                "{spelling:?} should not be {expected}"
            );
        }
    }

    #[test]
    fn a_bound_outside_the_grammar_is_reported_against_the_record() {
        // The comparator is where the grammar lives, but the per-band check is where a
        // holder of a file meets it, so every row is also driven through that.
        let long_fraction = format!("0.{}4e1001", "0".repeat(1000));
        for (spelling, expected) in equivalent_bound_spellings(&long_fraction) {
            let report = sh_band_one_report(spelling, expected);
            assert!(
                report
                    .findings
                    .iter()
                    .all(|finding| !finding.message.contains("`sh_band1` as")),
                "{spelling:?} should be {expected}: {:?}",
                report.findings
            );
        }
        for (spelling, expected) in rejected_bound_spellings() {
            let report = sh_band_one_report(spelling, expected);
            assert!(
                report
                    .findings
                    .iter()
                    .any(|finding| finding.message.contains("`sh_band1` as")),
                "{spelling:?} should not be {expected}: {:?}",
                report.findings
            );
        }
    }

    /// A per-band check of one Quantization record declaring `spelling` for band 1, at the
    /// bit depth whose bound is `expected`.
    fn sh_band_one_report(spelling: &str, expected: u8) -> Report {
        let mut quant = grids();
        quant.sh_bit_depths = vec![depth_for_bound(expected)];
        quant.bounds.insert("sh_band1".into(), spelling.into());
        let mut report = Report::default();
        check_sh_bit_depths(&quant, 1, &mut report);
        report
    }

    #[test]
    fn a_positive_keyframe_delta_duration_requires_a_state_timeline() {
        let report = validate(&minimal_file_headed(&["keyframe-delta"], &[grids()]));
        assert!(!report.ok());
        assert!(
            errors(&report)
                .iter()
                .any(|message| message.contains("no state chunks")
                    && message.contains("positive duration")),
            "{:?}",
            errors(&report)
        );
    }

    #[test]
    fn a_non_finite_quantization_step_is_an_error() {
        // Spec §5.3. The corrupt field that ruins every gaussian rather than one: each bin
        // times an infinite step decodes to a position that does not exist, and nothing
        // downstream complains because arithmetic on infinity is defined.
        let mut quant = grids();
        quant.step_pos = f64::INFINITY;
        let report = validate(&minimal_file(&quant));
        assert!(!report.ok());
        assert!(
            errors(&report).contains(
                &"Quantization step_pos is inf; every step and origin must be finite (§5.3)"
                    .to_string()
            ),
            "{:?}",
            errors(&report)
        );
    }

    #[test]
    fn a_non_finite_position_origin_is_an_error() {
        // The origin is added after the step multiply, so an infinite one is just as fatal
        // and just as quiet as an infinite step.
        let mut quant = grids();
        quant.pos_origin[1] = f64::NEG_INFINITY;
        let report = validate(&minimal_file(&quant));
        assert!(errors(&report).iter().any(|m| m
            == "Quantization pos_origin[1] is -inf; every step and origin must be finite (§5.3)"));
    }

    #[test]
    fn a_bad_quantization_record_is_not_masked_by_a_later_good_one() {
        // Nothing in the framing forbids a second Quantization record, and a streamed
        // decoder takes the first grid it meets. A validator that inspected only the one
        // left in hand after the walk would pass this file while the whole scene decodes
        // through the broken grid. Mirrors the Python suite's test of the same name.
        let mut bad = grids();
        bad.step_pos = f64::INFINITY;
        let report = validate(&minimal_file_with(&[bad, grids()]));
        assert!(!report.ok(), "{:?}", errors(&report));
        assert!(
            errors(&report)
                .iter()
                .any(|m| m.contains("step_pos is inf")),
            "{:?}",
            errors(&report)
        );
    }

    #[test]
    fn the_offending_quantization_record_is_named_when_there_is_more_than_one() {
        // The reverse order: the good grid first. The report has to say which copy, or the
        // reader is left looking at a record that is perfectly fine.
        let mut bad = grids();
        bad.step_time = f64::NAN;
        let report = validate(&minimal_file_with(&[grids(), bad]));
        assert!(!report.ok());
        assert!(
            errors(&report)
                .iter()
                .any(|m| m.contains("Quantization record 2 step_time is nan")),
            "{:?}",
            errors(&report)
        );
    }

    #[test]
    fn a_nan_is_spelled_the_way_the_other_validator_spells_it() {
        // Rust writes `NaN` and Python writes `nan`. A report a caller diffs between the
        // two tools is a report where that is a difference, so it is spelled once.
        let mut quant = grids();
        quant.step_rot = f64::NAN;
        let report = validate(&minimal_file(&quant));
        assert!(
            errors(&report).iter().any(|m| m
                == "Quantization step_rot is nan; every step and origin must be finite (§5.3)"),
            "{:?}",
            errors(&report)
        );
    }

    #[test]
    fn every_quantization_parameter_is_covered() {
        // One field at a time, so a parameter nobody checks fails here rather than in a
        // file somebody ships.
        /// A field's name and the one-liner that makes it non-finite.
        type Breaker = (&'static str, fn(&mut rec::Quantization));
        let fields: [Breaker; 11] = [
            ("pos_origin[0]", |q| q.pos_origin[0] = f64::INFINITY),
            ("pos_origin[1]", |q| q.pos_origin[1] = f64::INFINITY),
            ("pos_origin[2]", |q| q.pos_origin[2] = f64::INFINITY),
            ("step_pos", |q| q.step_pos = f64::INFINITY),
            ("step_scale_log", |q| q.step_scale_log = f64::INFINITY),
            ("step_rot", |q| q.step_rot = f64::INFINITY),
            ("step_rgb", |q| q.step_rgb = f64::INFINITY),
            ("step_alpha", |q| q.step_alpha = f64::INFINITY),
            ("step_motion", |q| q.step_motion = f64::INFINITY),
            ("step_time", |q| q.step_time = f64::INFINITY),
            ("step_sigma_log", |q| q.step_sigma_log = f64::INFINITY),
        ];
        for (name, break_it) in fields {
            let mut quant = grids();
            break_it(&mut quant);
            let report = validate(&minimal_file(&quant));
            assert!(
                errors(&report)
                    .iter()
                    .any(|m| m.starts_with(&format!("Quantization {name} is"))),
                "{name} is not checked"
            );
        }
    }

    #[test]
    fn a_conforming_file_has_nothing_to_report() {
        let report = validate(&minimal());
        assert!(report.ok(), "{:?}", report.findings);
        assert!(report.findings.is_empty(), "{:?}", report.findings);
    }

    #[test]
    fn a_file_that_is_not_ours_is_refused_before_anything_else() {
        let report = validate(b"not a 4dgs file at all");
        assert!(!report.ok());
        assert_eq!(report.findings.len(), 1);
        // And named. "Both readers raised an error" is not agreement — one of them may
        // have refused for the wrong reason, which is the failure a negative test is
        // supposed to catch and cannot without the identifier.
        let named = report.findings[0]
            .refusal
            .as_ref()
            .expect("a refusal the specification names");
        assert_eq!(named.code, fourdgs::error::refusal::MAGIC_MISMATCH);
        assert_eq!(named.site.as_ref().unwrap().offset, 0);
    }

    #[test]
    fn a_version_this_reader_does_not_implement_is_a_different_refusal_from_a_bad_magic() {
        // The fix differs — a newer reader, or a different file — so the identifiers do
        // too, and a tool that collapsed them would send its reader looking for the wrong
        // one.
        let mut data = minimal();
        data[5] = b'9';
        let report = validate(&data);
        let named = report.findings[0].refusal.as_ref().expect("a refusal");
        assert_eq!(
            named.code,
            fourdgs::error::refusal::UNSUPPORTED_MAJOR_VERSION
        );
    }

    #[test]
    fn a_truncated_file_says_the_magic_is_missing() {
        let mut data = minimal();
        data.truncate(data.len() - 4);
        let report = validate(&data);
        assert!(!report.ok());
        assert!(report
            .findings
            .iter()
            .any(|f| f.message.contains("does not end with the magic")));
    }

    #[test]
    fn the_footer_must_be_the_final_record() {
        let mut data = minimal();
        data.truncate(data.len() - MAGIC.len());
        fourdgs::serialization::put_record(&mut data, 0xFE, &[]);
        data.extend_from_slice(&MAGIC);
        let report = validate(&data);
        assert!(
            report
                .findings
                .iter()
                .any(|finding| finding.message.contains("Footer must be final")),
            "{:?}",
            report.findings
        );
    }

    #[test]
    fn a_corrupted_summary_is_named_as_a_crc_mismatch() {
        let mut data = minimal();
        let tail = data.len() - (RECORD_HEADER_SIZE + 20 + MAGIC.len());
        let footer = rec::Footer::parse(&data[tail + RECORD_HEADER_SIZE..]).unwrap();
        assert!(footer.summary_start > 0, "the fixture writes an index");
        // Inside the first summary record's content rather than its framing: the walk
        // still ends where it should, and the CRC is the only thing that can notice.
        data[footer.summary_start as usize + RECORD_HEADER_SIZE + 4] ^= 0xFF;
        let report = validate(&data);
        assert!(!report.ok());
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.message.contains("summary CRC mismatch")),
            "{:?}",
            report.findings
        );
    }

    #[test]
    fn an_unknown_opcode_is_a_note_rather_than_a_failure() {
        // Emitted by the encoder rather than spliced in afterwards: splicing shifts every
        // offset the index holds, which produces a corrupt file rather than a
        // forward-compatibility test.
        let mut record = vec![0x7F];
        record.extend_from_slice(&3u64.to_le_bytes());
        record.extend_from_slice(b"new");
        let mut private = vec![0x81];
        private.extend_from_slice(&2u64.to_le_bytes());
        private.extend_from_slice(b"hi");
        let data = sample_file(vec![record, private]);
        let report = validate(&data);
        assert!(report.ok(), "{:?}", report.findings);
        assert!(report
            .findings
            .iter()
            .any(|f| f.severity == Severity::Note && f.message.contains("unknown record 0x7F")));
    }

    #[test]
    fn a_provenance_record_is_not_an_unknown_one() {
        // Both are skipped, and a reader that met either still decodes the file — but the
        // two say different things about where the record came from, and the Python
        // validator has always said the first. Four notes about a conforming capture is
        // what this reported before, against Python's silence.
        let frame = rec::CoordinateFrame {
            handedness: 1,
            up_axis: 2,
            forward_axis: 1,
            length_unit: 1,
            metres_per_unit: 1.0,
            ..Default::default()
        }
        .encode(&[]);
        // The reserved tail of the same family, which is the case the note does apply to.
        let mut reserved = vec![0x2Fu8];
        reserved.extend_from_slice(&0u64.to_le_bytes());

        let report = validate(&sample_file(vec![frame, reserved]));
        assert!(report.ok(), "{:?}", report.findings);
        let notes: Vec<&str> = report.findings.iter().map(|f| f.message.as_str()).collect();
        assert!(
            !notes.iter().any(|m| m.contains("unknown record 0x20")),
            "{notes:?}"
        );
        assert!(
            notes
                .iter()
                .any(|m| m.contains("reserved provenance record 0x2F")),
            "{notes:?}"
        );
        // And the range it names is the one that is actually reserved. `0x24` and `0x25`
        // are the Object Table and the Object Track — defined records, handled by name a
        // few arms above — so a note saying the reserved range starts at `0x24` sends its
        // reader looking for two records that exist. Spec §5.15 reserves `0x26`-`0x2F` in
        // §5.15.8.
        assert!(
            notes
                .iter()
                .any(|m| m.contains("(0x26-0x2F, section 5.15.8)")),
            "{notes:?}"
        );
    }

    /// The byte a named refusal was placed at, for the tests below.
    fn refused_at(report: &Report, code: &str) -> u64 {
        report
            .findings
            .iter()
            .find_map(|f| f.refusal.as_ref().filter(|n| n.code == code))
            .unwrap_or_else(|| panic!("no `{code}` refusal in {:?}", report.findings))
            .site
            .as_ref()
            .unwrap_or_else(|| panic!("`{code}` was named but not placed"))
            .offset
    }

    /// Where the `n`th record with this opcode starts, counting from zero.
    fn nth_record(data: &[u8], opcode: u8, n: usize) -> u64 {
        let walk = refusal::walk(&mut BytesReadable::new(data)).expect("a walk");
        walk.records
            .iter()
            .filter(|frame| frame.opcode == opcode)
            .nth(n)
            .expect("that many records")
            .offset
    }

    #[test]
    fn the_refused_header_is_the_one_that_declares_the_model_not_the_first_one() {
        // The framing DOES now forbid a second Header (spec §4), so this file is refused
        // for carrying two rather than for the model the second one declares — and that
        // ordering is deliberate. `check_temporal_model` is a compatibility gate: its
        // refusal tells the holder to go and find a newer reader. Saying that about a
        // file that is structurally broken sends them looking for a build that would
        // refuse it too. "This file carries two Headers" is the true answer.
        //
        // What survives from the older test is the property it existed for: the byte in
        // the refusal points at the offending record and not at an innocent one. Here
        // that is the second Header, since the first is unobjectionable.
        let data = minimal_file_headed(&["gaussian-birth", "frame-sequence"], &[grids()]);
        let report = validate(&data);
        assert!(!report.ok(), "{:?}", errors(&report));
        let second = nth_record(&data, op::HEADER, 1);
        assert!(
            errors(&report)
                .iter()
                .any(|m| m.contains("a second Header record")
                    && m.contains(&format!("at byte {second}"))),
            "the refusal must name the second Header and its byte: {:?}",
            errors(&report)
        );
    }

    #[test]
    fn the_refused_quantization_record_is_the_one_that_declares_the_scheme() {
        // The same rule, one record along, and the same reordering: the file is refused
        // for its second Quantization record rather than for the scheme that record
        // names. `check_quantization_scheme` is the other compatibility gate, and the
        // reasoning above applies to it unchanged.
        let mut unknown = grids();
        unknown.scheme = "uniform-v9".into();
        let data = minimal_file_with(&[grids(), unknown]);
        let report = validate(&data);
        assert!(!report.ok());
        let second = nth_record(&data, op::QUANTIZATION, 1);
        assert!(
            errors(&report)
                .iter()
                .any(|m| m.contains("a second Quantization record")
                    && m.contains(&format!("at byte {second}"))),
            "the refusal must name the second Quantization record and its byte: {:?}",
            errors(&report)
        );
    }

    #[test]
    fn a_refusal_in_the_only_record_of_its_kind_is_still_placed() {
        // The ordinary case, which the search above must not have cost: one Header, and
        // it is the one refused.
        let data = minimal_file_headed(&["frame-sequence"], &[grids()]);
        let report = validate(&data);
        assert_eq!(
            refused_at(&report, fourdgs::error::refusal::UNKNOWN_TEMPORAL_MODEL),
            MAGIC.len() as u64
        );
    }

    #[test]
    fn severities_order_so_the_worst_one_picks_the_exit_code() {
        let mut report = Report::default();
        report.note("a".into());
        assert_eq!(report.worst(), Some(Severity::Note));
        report.warn("b".into());
        assert_eq!(report.worst(), Some(Severity::Warning));
        report.error("c".into());
        assert_eq!(report.worst(), Some(Severity::Error));
        assert!(!report.ok());
    }
}
