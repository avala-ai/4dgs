// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Structural validation.
///
/// This is what makes a third-party encoder possible: a way to find out *why* a file is wrong
/// that does not involve reading someone else's decoder. Every finding names the record, the
/// field and what was expected.
///
/// The findings, their severities and their wording are `python/fourdgs/fourdgs/validate.py`'s.
/// Two validators that disagree about whether a file conforms are worse than one, so where the
/// two differ the Python module is the reference and this is the bug.
///
/// **What this validator does not check, and why.** The Python and Rust validators parse every
/// record's body and check its fields — the Header's gaussian count against the chunks, each
/// Audio Source's pose and timing, every quantization step for finiteness. This one does not,
/// because the C++ package is a binding: it has no record parsers of its own, and writing them
/// here would make the tool a second implementation of the format that could disagree with the
/// decoder it ships beside. So the checks below are the ones that need no parser — framing, the
/// records a file must carry, where the index points, the summary checksum — plus everything
/// the reader itself decides, which is where the six named refusals live.
///
/// The consequence is worth stating plainly: on a file this tool calls valid, Python may still
/// have something to say. It reports a subset of Python's findings and never a finding Python
/// contradicts, which is the property that matters — a validator that is quieter is a gap, and
/// one that disagrees is a bug.
///
/// Three things it does that the Python tool does not:
///
/// * **It prints the refusal identifier and the byte.** The finding lines themselves match
///   Python's word for word; the identifier goes on a line of its own beneath the finding it
///   belongs to. Python's exceptions carry the same `code` — its CLI simply does not print it.
/// * **It decodes the chunks.** A framing walk steps over a chunk by its declared length, so a
///   fault inside a chunk's streams is invisible to it; two of the invalid corpus's seven files
///   are exactly that, and Python calls them clean.
/// * **It knows `keyframe-delta`.** Python reports a conforming keyframe-delta file as invalid,
///   because its structural checks assume the gaussian-birth chunk shape. The core implements
///   the model — the conformance suite proves it — so refusing a file for declaring it was never
///   a statement about the file.

#include <memory>
#include <string>
#include <vector>

#include "tool.hpp"

namespace fourdgs {
namespace tool {

namespace {

void push(Report* report, Severity severity, std::string message, std::optional<Named> refusal) {
  Finding finding;
  finding.severity = severity;
  finding.message = std::move(message);
  finding.refusal = std::move(refusal);
  report->findings.push_back(std::move(finding));
}

void error(Report* report, std::string message) {
  push(report, Severity::kError, std::move(message), std::nullopt);
}

void warn(Report* report, std::string message) {
  push(report, Severity::kWarning, std::move(message), std::nullopt);
}

void note(Report* report, std::string message) {
  push(report, Severity::kNote, std::move(message), std::nullopt);
}

/// An error the reader raised, carrying its identifier and the byte if it has one.
///
/// `prefix` is what the message is introduced with, so the sentence stays the one the other
/// validators print; the identifier arrives on its own line and changes nothing about it.
void refused(Report* report, const char* prefix, const Error& err, const Walk* walk,
             const std::optional<Site>& site) {
  push(report, Severity::kError, std::string(prefix) + err.message, describe(err, walk, site));
}

std::string hex2(std::uint8_t value) {
  static const char* digits = "0123456789ABCDEF";
  std::string out = "0x";
  out.push_back(digits[value >> 4]);
  out.push_back(digits[value & 0x0F]);
  return out;
}

/// The two checks only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks is
/// where the rest do, and there is no substitute for it: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range window index are
/// both invisible to everything before this point. Both are in the invalid corpus.
void checkGaussianBirth(Span<const std::uint8_t> data, const Walk& walk,
                        const std::vector<std::uint64_t>& chunkOffsets, Report* report) {
  Result<std::unique_ptr<Scene>> opened = Scene::openMemory(data, ReadMode::kIndexed);
  if (!opened) {
    refused(report, "a seeking reader cannot open this file: ", opened.error(), &walk,
            std::nullopt);
    // A file that will not open will not decode either, and the second error would say the same
    // thing about the same byte.
    return;
  }
  // Closed before the scan, so only one reader — and one chunk — is resident at a time.
  opened->reset();
  std::optional<ChunkRefusal> refusal = scanChunks(data, chunkOffsets);
  if (refusal.has_value()) {
    refused(report, "a chunk does not decode: ", refusal->error, &walk, refusal->site);
  }
}

/// The same, for the temporal model whose chunks are keyframes and differences.
///
/// This is the same statement as the branch above — open the file the way a client would, and
/// decode what it carries — expressed in the reader the file's declared model actually needs.
/// The alternative, which is what the Python validator still does, is to run the gaussian-birth
/// reader over it and report its refusal as a fault in the file.
void checkKeyframeDelta(Span<const std::uint8_t> data, const Walk& walk, Report* report) {
  Result<std::string> states = keyframeDeltaStatesJson(data, /*indexed=*/true);
  if (!states) {
    refused(report, "a seeking reader cannot open this file: ", states.error(), &walk,
            std::nullopt);
  }
}

}  // namespace

bool Report::ok() const {
  for (const Finding& finding : findings) {
    if (finding.severity == Severity::kError) return false;
  }
  return true;
}

std::optional<Severity> Report::worst() const {
  std::optional<Severity> out;
  for (const Finding& finding : findings) {
    if (!out.has_value() || static_cast<int>(finding.severity) > static_cast<int>(*out)) {
      out = finding.severity;
    }
  }
  return out;
}

Report validate(Span<const std::uint8_t> data) {
  Report report;

  // Framing first, and for two reasons: it refuses a file that is not ours before anything reads
  // a byte as an opcode, and it is what gives every later refusal a byte to point at.
  Result<Walk> walked = walkBytes(data);
  if (!walked) {
    refused(&report, "", walked.error(), nullptr, std::nullopt);
    return report;
  }
  const Walk& walk = *walked;

  bool endsWithMagic = data.size() >= kMagicSize;
  for (std::size_t i = 0; i < kMagicSize && endsWithMagic; ++i) {
    if (data[data.size() - kMagicSize + i] != kMagic[i]) endsWithMagic = false;
  }
  if (!endsWithMagic) {
    error(&report,
          "file does not end with the magic; it is truncated or was written by a broken encoder");
  }

  // Only the whole records: a record the file was cut inside is reported by the note below, and
  // counting it as present would say a Footer exists in a file that stops before one.
  const std::size_t intact = walk.intact();
  std::vector<std::uint8_t> seen;
  bool header = false;
  bool quantization = false;
  bool footer = false;
  for (std::size_t i = 0; i < intact; ++i) {
    const std::uint8_t opcode = walk.records[i].opcode;
    seen.push_back(opcode);
    if (opcode == op::kHeader) header = true;
    if (opcode == op::kQuantization) quantization = true;
    if (opcode == op::kFooter) footer = true;
    if (isPrivate(opcode)) {
      note(&report, "private record " + hex2(opcode) + " (" +
                        std::to_string(walk.records[i].length) + " bytes) — skipped, as required");
    } else if (isProvenance(opcode) && !isSpecified(opcode)) {
      // The reserved tail of the provenance family, which is a different thing from an unknown
      // record: the range is spoken for, so a reader that meets one knows it is looking at a
      // record from a later revision rather than at a byte it cannot account for.
      note(&report, "reserved provenance record " + hex2(opcode) +
                        " — skipped, as required (0x24-0x2F, section 5.15.6)");
    } else if (!isSpecified(opcode)) {
      note(&report, "unknown record " + hex2(opcode) + " — skipped, as required");
    }
  }

  if (seen.empty()) {
    error(&report, "no records at all");
    return report;
  }
  if (seen[0] != op::kHeader) {
    error(&report, "first record is " + opcodeName(seen[0]) + "; the Header must come first");
  }
  if (!header) error(&report, "no Header record");
  if (!quantization) error(&report, "no Quantization record");
  if (!footer) error(&report, "no Footer record");

  // Which chunk shape the rest of this validator is entitled to assume. A `keyframe-delta`
  // file's Chunks are keyframes and its Delta Chunks are differences against them, so the index
  // check below is about the gaussian-birth shape and about nothing else. Read from the Header
  // rather than guessed from the records, because a file that carries Delta Chunks and does not
  // say so is itself a fault.
  //
  // Asked of the reader rather than parsed here: this is the one field the whole branch turns
  // on, and a tool that read it out of the Header itself could disagree with the reader about
  // which model a file declares — which is the one disagreement that would matter.
  std::string model;
  Result<std::string> peeked = peekTemporalModel(data);
  if (peeked) model = *peeked;
  const bool keyframeDelta = model == "keyframe-delta";

  const std::vector<IndexEntry> index = chunkIndexEntries(data, walk);
  for (std::size_t i = 0; i < index.size(); ++i) {
    const IndexEntry& entry = index[i];
    const std::uint64_t end = entry.offset + entry.length;
    const bool overflows = end < entry.offset || end > data.size();
    // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta Chunk is a
    // difference against one, and an index that could only name the former could not seek the
    // model at all.
    const std::uint8_t at = overflows ? 0 : data[static_cast<std::size_t>(entry.offset)];
    const bool addressable = at == op::kChunk || (keyframeDelta && at == op::kDeltaChunk);
    if (overflows) {
      error(&report, "chunk index entry " + std::to_string(i) + " points past the end of the file");
    } else if (!addressable) {
      error(&report,
            "chunk index entry " + std::to_string(i) + " does not point at a Chunk record");
    }
  }

  std::optional<SummaryDeclaration> summary = summaryDeclaration(data, walk);
  if (summary.has_value()) {
    if (summary->start > summary->end) {
      error(&report, "the Footer's summary starts at " + std::to_string(summary->start) +
                         ", after the summary ends at " + std::to_string(summary->end));
    } else {
      std::optional<Coverage> covered = coverage(data, walk);
      if (covered.has_value() && !covered->ok) {
        error(&report,
              "summary CRC mismatch: the index is untrustworthy (a streamed read still works)");
      }
    }
  }

  if (header && index.empty()) {
    warn(&report, "no chunk index: this file can only be read front to back, not seeked");
  }

  // What survived the cut, which is the question the errors above do not answer.
  //
  // A cut file is invalid and every finding about it stands — but records are length-prefixed,
  // so everything complete before the cut is intact and the library's streamed reader keeps it.
  // Saying only that the file stopped reading leaves its holder to guess whether anything is
  // salvageable; this says how much.
  if (walk.cut.has_value()) {
    note(&report, "the file is cut at byte " + commas(walk.cut->at) + ": " + walk.cut->reason +
                      ". The " + std::to_string(walk.intact()) +
                      " complete records before it are intact, and a streamed reader recovers "
                      "them");
  }

  if (keyframeDelta) {
    checkKeyframeDelta(data, walk, &report);
  } else {
    std::vector<std::uint64_t> chunkOffsets;
    chunkOffsets.reserve(index.size());
    for (const IndexEntry& entry : index) chunkOffsets.push_back(entry.offset);
    checkGaussianBirth(data, walk, chunkOffsets, &report);
  }

  return report;
}

const char* severityName(Severity severity) {
  switch (severity) {
    case Severity::kNote:
      return "note";
    case Severity::kWarning:
      return "warning";
    case Severity::kError:
      break;
  }
  return "error";
}

int runValidate(const std::string& path, std::ostream& out, std::ostream& err) {
  // Half of what this command checks is what the reader decides, so a build with no decoder
  // behind it cannot answer the question — and saying `valid` on the half it can check would be
  // the worst answer available. `kExitTool` is exactly this case: the absence of an answer, told
  // apart from a verdict on the file. `inspect` still works, because framing is not decoding.
  if (!backendAvailable()) {
    err << "4dgs: this build has no decoder behind it, so a file cannot be validated; see the "
           "C++ package README for how to link the core (`inspect` still walks the framing)\n";
    return kExitTool;
  }
  Result<std::vector<std::uint8_t>> data = readWhole(path);
  if (!data) {
    // Not the file's fault, and not a refusal. See `kExitTool`.
    err << "4dgs: " << path << ": " << data.error().message << "\n";
    return kExitTool;
  }
  const Report report = validate(Span<const std::uint8_t>(data->data(), data->size()));
  for (const Finding& finding : report.findings) {
    out << severityName(finding.severity) << ": " << finding.message << "\n";
    // Indented, and with a prefix of its own, so that a caller filtering the findings on
    // `error:`/`warning:`/`note:` — which is how the validators are compared — sees exactly what
    // it saw before.
    if (finding.refusal.has_value()) out << "  " << finding.refusal->toString() << "\n";
  }
  if (!report.ok()) {
    err << "INVALID\n";
    return kExitFailed;
  }
  out << (report.findings.empty() ? "valid" : "valid (with notes)") << "\n";
  // The one deliberate divergence from the Python tool, which exits 0 here, and the Rust tool's
  // too. A warning a script cannot see is a warning nobody acts on, so it gets its own code.
  return report.worst() == Severity::kWarning ? kExitWarnings : kExitOk;
}

}  // namespace tool
}  // namespace fourdgs
