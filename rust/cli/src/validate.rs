// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Structural validation.
//!
//! This is what makes a third-party encoder possible: a way to find out *why* a file is
//! wrong that does not involve reading someone else's decoder. Every finding names the
//! record, the field and what was expected.
//!
//! The checks, their severities and their wording are `python/fourdgs/fourdgs/validate.py`'s.
//! Two validators that disagree about whether a file conforms are worse than one, so where
//! the two differ the Python module is the reference and this is the bug.
//!
//! Three things this validator does that the Python one does not yet, each recorded here
//! because a divergence nobody wrote down is indistinguishable from a bug:
//!
//! * **It prints the refusal identifier and the byte.** The finding lines themselves are
//!   unchanged and still match Python's word for word; the identifier goes on a line of
//!   its own beneath the finding it belongs to. Python's exceptions carry the same `code`
//!   — its CLI simply does not print it.
//! * **It decodes the chunks.** A framing walk steps over a chunk by its declared length,
//!   so a fault inside a chunk's streams is invisible to it; two of the invalid corpus's
//!   seven files are exactly that, and both validators called them clean.
//! * **It knows `keyframe-delta`.** Both validators used to report a conforming
//!   keyframe-delta file as invalid, because every structural check assumed the
//!   gaussian-birth chunk shape. The Rust core implements the model, so its validator now
//!   validates against the model the file declares.

use std::collections::BTreeMap;

use fourdgs::quantization::{sh_bound, sh_step};
use fourdgs::serialization::{crc32, Records, MAGIC, RECORD_HEADER_SIZE};
use fourdgs::{opcode as op, records as rec, BytesReadable, Result};

use crate::args::Args;
use crate::refusal::{self, Named, Walk};
use crate::{EXIT_FAILED, EXIT_OK, EXIT_TOOL, EXIT_WARNINGS};

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
    fn refused(
        &mut self,
        prefix: &str,
        error: &fourdgs::Error,
        walk: Option<&Walk>,
        site: Option<refusal::Site>,
    ) {
        let named = refusal::describe(error, walk, site);
        self.push(Severity::Error, format!("{prefix}{error}"), named);
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
    let report = validate(&data);
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
pub fn validate(data: &[u8]) -> Report {
    let mut report = Report::default();
    // Framing first, and for two reasons: it refuses a file that is not ours before
    // anything reads a byte as an opcode, and it is what gives every later refusal a byte
    // to point at.
    let walk = match refusal::walk(&mut BytesReadable::new(data)) {
        Ok(walk) => walk,
        Err(error) => {
            report.refused("", &error, None, None);
            return report;
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
            // The reserved tail of the provenance family, which is a different thing from
            // an unknown record: the range is spoken for, so a reader that meets one knows
            // it is looking at a record from a later revision rather than at a byte it
            // cannot account for. Python's wording, because a note the two tools spell
            // differently is a diff nobody can read.
            opcode if op::is_provenance(opcode) && !is_specified(opcode) => report.note(format!(
                "reserved provenance record 0x{opcode:02X} — skipped, as required \
                 (0x24-0x2F, section 5.15.6)"
            )),
            opcode if !is_specified(opcode) => report.note(format!(
                "unknown record 0x{opcode:02X} — skipped, as required"
            )),
            _ => {}
        }
    }

    if seen.is_empty() {
        report.error("no records at all".into());
        return report;
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
    }

    // Which chunk shape the rest of this validator is entitled to assume. A
    // `keyframe-delta` file's Chunks are keyframes and its Delta Chunks are differences
    // against them, so several checks below are about the gaussian-birth shape and about
    // nothing else. Read from the Header rather than guessed from the records, because a
    // file that carries Delta Chunks and does not say so is itself a fault.
    let keyframe_delta = header
        .as_ref()
        .is_some_and(|h| h.temporal_model == "keyframe-delta");

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
            walk.intact()
        ));
    }

    if keyframe_delta {
        check_keyframe_delta(data, &walk, &mut report);
    } else {
        check_gaussian_birth(data, &walk, &mut report);
    }

    report
}

/// The two checks that only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks
/// is where the rest do, and there is no substitute for it: the framing walk above steps
/// over a chunk by its declared length, so an unimplemented stream codec and an
/// out-of-range window index are both invisible to everything before this point. Both are
/// in the invalid corpus, and both used to validate clean.
fn check_gaussian_birth(data: &[u8], walk: &Walk, report: &mut Report) {
    if let Err(error) = fourdgs::indexed_reader::open_indexed(&mut BytesReadable::new(data)) {
        report.refused(
            "a seeking reader cannot open this file: ",
            &error,
            Some(walk),
            None,
        );
        // A file that will not open will not decode either, and the second error would say
        // the same thing about the same byte.
        return;
    }
    if let Err((error, site)) = refusal::scan_chunks(BytesReadable::new(data)) {
        report.refused("a chunk does not decode: ", &error, Some(walk), site);
    }
}

/// The same, for the temporal model whose chunks are keyframes and differences.
///
/// `decode_indexed` is the model's own reader, so this is the same statement as the branch
/// above — open the file the way a client would, and decode what it carries — expressed in
/// the reader the file's declared model actually needs. The alternative, which is what
/// both validators did until now, is to run the gaussian-birth reader over it and report
/// its refusal as a fault in the file.
fn check_keyframe_delta(data: &[u8], walk: &Walk, report: &mut Report) {
    if let Err(error) = fourdgs::keyframe_delta_file::decode_indexed(data) {
        report.refused(
            "a seeking reader cannot open this file: ",
            &error,
            Some(walk),
            None,
        );
    }
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
        let expected = sh_bound(*bits).to_string();
        match quant.bounds.get(&key) {
            None => report.warn(format!(
                "Quantization declares {bits} bits for SH band {band} but no `{key}` bound (§5.3)"
            )),
            Some(found) if *found != expected => report.warn(format!(
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
        let header = rec::Header {
            duration_sec: 1.0,
            gaussian_count: 0,
            aabb: vec![0.0; 6],
            ..Default::default()
        };
        let mut out = MAGIC.to_vec();
        out.extend_from_slice(&header.encode(&[]));
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
    fn a_minimal_handmade_file_validates_clean() {
        let report = validate(&minimal_file(&grids()));
        assert!(report.ok(), "{:?}", errors(&report));
        assert!(errors(&report).is_empty(), "{:?}", errors(&report));
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
