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

use fourdgs::serialization::{crc32, Records, MAGIC, RECORD_HEADER_SIZE};
use fourdgs::{opcode as op, records as rec, BytesReadable, Result};

use crate::args::Args;
use crate::{EXIT_FAILED, EXIT_OK, EXIT_WARNINGS};

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

#[derive(Debug, Default)]
pub struct Report {
    pub findings: Vec<(Severity, String)>,
}

impl Report {
    pub fn ok(&self) -> bool {
        !self.findings.iter().any(|(s, _)| *s == Severity::Error)
    }

    fn worst(&self) -> Option<Severity> {
        self.findings.iter().map(|(s, _)| *s).max()
    }

    fn error(&mut self, message: String) {
        self.findings.push((Severity::Error, message));
    }

    fn warn(&mut self, message: String) {
        self.findings.push((Severity::Warning, message));
    }

    fn note(&mut self, message: String) {
        self.findings.push((Severity::Note, message));
    }
}

pub fn run(args: &Args) -> Result<u8> {
    let data = std::fs::read(&args.file)?;
    let report = validate(&data);
    for (severity, message) in &report.findings {
        out!("{}: {message}", severity.as_str());
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
    if let Err(error) = fourdgs::serialization::check_magic(data) {
        report.error(error.to_string());
        return report;
    }
    if !data.ends_with(&MAGIC) {
        report.error(
            "file does not end with the magic; it is truncated or was written by a broken encoder"
                .into(),
        );
    }

    let mut seen: Vec<u8> = Vec::new();
    let mut header: Option<rec::Header> = None;
    let mut quantization = false;
    let mut footer: Option<rec::Footer> = None;
    let mut chunk_count = 0u64;
    let mut counted = 0u64;
    let mut index: Vec<rec::ChunkIndexEntry> = Vec::new();

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
                Ok(_) => quantization = true,
                Err(error) => report.error(format!("Quantization does not parse: {error}")),
            },
            op::CHUNK => match rec::parse_chunk(record.content) {
                Ok((head, _)) => {
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
            opcode if op::is_private(opcode) => report.note(format!(
                "private record 0x{opcode:02X} ({} bytes) — skipped, as required",
                record.content.len()
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

    if let Some(header) = &header {
        if counted != header.gaussian_count {
            report.error(format!(
                "Header declares {} gaussians; chunks contain {counted}",
                header.gaussian_count
            ));
        }
        let audio_record = seen.contains(&op::AUDIO);
        if header.has_audio() && !audio_record {
            report.error("Header says the file has audio, but there is no Audio record".into());
        }
        if !header.has_audio() && audio_record {
            report.error("there is an Audio record, but the Header's audio flag is clear".into());
        }
    }

    for (i, entry) in index.iter().enumerate() {
        let end = entry.chunk_offset.saturating_add(entry.chunk_length);
        if end > data.len() as u64 {
            report.error(format!(
                "chunk index entry {i} points past the end of the file"
            ));
        } else if data.get(entry.chunk_offset as usize) != Some(&op::CHUNK) {
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

    // TODO(#13): mirror `_check_quantization_finite`. Every Quantization step and every
    // component of `pos_origin` must be finite (spec §5.3) — a non-finite step is the one
    // corrupt field that ruins every gaussian rather than one, and nothing downstream
    // complains because dequantization is arithmetic. The Python check lands with the
    // conformance PR; until it does, this validator would report an error that one does
    // not, which is the divergence the two are supposed to be free of.

    if header.is_some() && index.is_empty() {
        report.warn("no chunk index: this file can only be read front to back, not seeked".into());
    }

    // Opening the file the way a seeking client would is itself a check.
    if let Err(error) = fourdgs::indexed_reader::open_indexed(&mut BytesReadable::new(data)) {
        report.error(format!("a seeking reader cannot open this file: {error}"));
    }

    report
}

/// True for the opcodes the specification defines. Everything else is either the
/// application range or a record from a version this build does not implement, and both
/// are skipped rather than refused.
fn is_specified(opcode: u8) -> bool {
    (op::HEADER..=op::SUMMARY_OFFSET).contains(&opcode)
}

/// A conforming file, for the tests below. Written by the library's own encoder so that
/// the fixtures cannot drift away from what the format says.
///
/// `extra` is emitted verbatim by the encoder rather than spliced in afterwards: splicing
/// shifts every offset the index holds, which produces a corrupt file rather than the
/// file from a newer writer the caller was asking for.
#[cfg(test)]
fn fixture(extra: Vec<Vec<u8>>) -> Vec<u8> {
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
    fixture(Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

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
            .any(|(_, m)| m.contains("does not end with the magic")));
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
                .any(|(_, m)| m.contains("summary CRC mismatch")),
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
        let data = fixture(vec![record, private]);
        let report = validate(&data);
        assert!(report.ok(), "{:?}", report.findings);
        assert!(report
            .findings
            .iter()
            .any(|(s, m)| *s == Severity::Note && m.contains("unknown record 0x7F")));
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
