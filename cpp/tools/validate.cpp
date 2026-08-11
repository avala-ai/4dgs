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
#include <unordered_map>
#include <unordered_set>
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

void incomplete(Report* report, std::string message) {
  report->complete = false;
  warn(report, std::move(message));
}

/// An error the reader raised, carrying its identifier and the byte if it has one.
///
/// `prefix` is what the message is introduced with, so the sentence stays the one the other
/// validators print; the identifier arrives on its own line and changes nothing about it.
void refused(Report* report, const char* prefix, const Error& err, const Walk* walk,
             const std::optional<Site>& site) {
  push(report, Severity::kError, std::string(prefix) + err.message, describe(err, walk, site));
}

/// What survived the cut, in one sentence, from the two places that need it.
///
/// A cut file is invalid and every finding about it stands — but records are length-prefixed, so
/// everything complete before the cut is intact and the library's streamed reader keeps it.
/// Saying only that the file stopped reading leaves its holder to guess whether anything is
/// salvageable; this says how much.
void noteTheCut(Report* report, const Walk& walk) {
  note(report, "the file is cut at byte " + commas(walk.cut->at) + ": " + walk.cut->reason +
                   ". The " + std::to_string(walk.intact()) +
                   " complete records before it are intact, and a streamed reader recovers them");
}

bool readExactly(Readable& source, std::uint64_t offset, std::uint8_t* into, std::size_t length) {
  Result<std::size_t> got = source.read(offset, Span<std::uint8_t>(into, length));
  return got.ok() && *got == length;
}

std::uint32_t readU32(const std::uint8_t* at) {
  std::uint32_t value = 0;
  for (int i = 3; i >= 0; --i) value = (value << 8) | at[i];
  return value;
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
void checkGaussianBirth(Readable& source, const Walk& walk, const std::vector<IndexEntry>& index,
                        Report* report) {
  if (index.empty()) {
    incomplete(report,
               "chunk payload validation is incomplete: the file has no Chunk Index, and the "
               "C++ core has no bounded per-record sequential validation surface");
    return;
  }
  Result<std::unique_ptr<Scene>> opened = Scene::open(source, ReadMode::kIndexed);
  if (!opened) {
    refused(report, "a seeking reader cannot open this file: ", opened.error(), &walk,
            std::nullopt);
    // A file that will not open will not decode either, and the second error would say the same
    // thing about the same byte.
    return;
  }
  // Closed before the scan, so only one reader — and one chunk — is resident at a time.
  opened->reset();
  std::optional<ChunkRefusal> refusal = scanChunks(source, index);
  if (refusal.has_value()) {
    refused(report, "a chunk does not decode: ", refusal->error, &walk, refusal->site);
  }
}

/// The keyframe-delta C ABI accepts one contiguous byte span. Calling it here would necessarily
/// buffer the whole resource, and a validator may not turn a large valid capture into an
/// allocation attempt. Until the core exposes range-based streamed and indexed composition, say
/// that the verdict is incomplete instead of certifying bytes this binding could not inspect.
void checkKeyframeDelta(Report* report) {
  incomplete(report,
             "keyframe-delta payload validation is unavailable through the bounded C++ core "
             "surface; structural checks completed, but neither read mode was certified");
}

/// The Header's temporal model, range-parsed through its two variable-length prefixes.
///
/// A fixed head probe is unrelated to the wire format: `profile` and `library` are legal strings
/// of any framed length, so either can move `temporal_model` past such a probe. Only the model's
/// own bytes are read here; large preceding strings are skipped by their validated lengths.
std::string rangeParsedModel(Readable& source, const Walk& walk) {
  const Frame* header = walk.firstIntact(op::kHeader);
  if (header == nullptr) return std::string();
  const std::uint64_t start = header->offset + kRecordHeaderSize;
  const std::uint64_t limit = start + header->length;
  if (limit < start) return std::string();
  std::uint64_t at = start;
  auto skipString = [&]() -> bool {
    if (at > limit || limit - at < 4) return false;
    std::uint8_t lengthBytes[4];
    if (!readExactly(source, at, lengthBytes, sizeof(lengthBytes))) return false;
    const std::uint64_t length = readU32(lengthBytes);
    at += 4;
    if (at > limit || length > limit - at) return false;
    at += length;
    return true;
  };
  if (!skipString() || !skipString()) return std::string();
  // duration_sec, gaussian_count, cutoff.
  constexpr std::uint64_t kFixedBeforeModel = 8 + 8 + 8;
  if (at > limit || kFixedBeforeModel > limit - at) return std::string();
  at += kFixedBeforeModel;
  if (at > limit || limit - at < 4) return std::string();
  std::uint8_t lengthBytes[4];
  if (!readExactly(source, at, lengthBytes, sizeof(lengthBytes))) return std::string();
  const std::uint64_t length = readU32(lengthBytes);
  at += 4;
  if (at > limit || length > limit - at) return std::string();
  constexpr char kKeyframeDelta[] = "keyframe-delta";
  constexpr std::size_t kKeyframeDeltaLength = sizeof(kKeyframeDelta) - 1;
  if (length != kKeyframeDeltaLength) return std::string("other");
  std::uint8_t model[kKeyframeDeltaLength];
  if (!readExactly(source, at, model, sizeof(model))) return std::string();
  for (std::size_t i = 0; i < kKeyframeDeltaLength; ++i) {
    if (model[i] != static_cast<std::uint8_t>(kKeyframeDelta[i])) return std::string("other");
  }
  return std::string(kKeyframeDelta);
}

}  // namespace

std::string temporalModel(Readable& source, const Walk& walk) {
  return rangeParsedModel(source, walk);
}

bool Report::hasErrors() const {
  for (const Finding& finding : findings) {
    if (finding.severity == Severity::kError) return true;
  }
  return false;
}

bool Report::ok() const { return complete && !hasErrors(); }

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
  BorrowedReadable source(data);
  return validate(source);
}

Report validate(Readable& source) {
  Report report;

  Result<std::uint64_t> sized = source.size();
  if (!sized) {
    refused(&report, "", sized.error(), nullptr, std::nullopt);
    return report;
  }
  const std::uint64_t size = *sized;

  // Framing first, and for two reasons: it refuses a file that is not ours before anything reads
  // a byte as an opcode, and it is what gives every later refusal a byte to point at.
  Result<Walk> walked = walk(source);
  if (!walked) {
    refused(&report, "", walked.error(), nullptr, std::nullopt);
    return report;
  }
  const Walk& walk = *walked;

  bool endsWithMagic = size >= kMagicSize;
  if (endsWithMagic) {
    std::uint8_t tail[kMagicSize] = {0};
    Result<std::size_t> got = source.read(size - kMagicSize, Span<std::uint8_t>(tail, kMagicSize));
    endsWithMagic = got.ok() && *got == kMagicSize;
    for (std::size_t i = 0; i < kMagicSize && endsWithMagic; ++i) {
      if (tail[i] != kMagic[i]) endsWithMagic = false;
    }
  }
  if (!endsWithMagic) {
    error(&report,
          "file does not end with the magic; it is truncated or was written by a broken encoder");
  }

  // Only the whole records: a record the file was cut inside is reported by the note below, and
  // counting it as present would say a Footer exists in a file that stops before one.
  const bool header = walk.intactOpcodeCounts[op::kHeader] > 0;
  const bool quantization = walk.intactOpcodeCounts[op::kQuantization] > 0;
  const bool footer = walk.intactOpcodeCounts[op::kFooter] > 0;
  for (std::size_t value = 0; value < walk.intactOpcodeCounts.size(); ++value) {
    const std::uint64_t count = walk.intactOpcodeCounts[value];
    if (count == 0) continue;
    const std::uint8_t opcode = static_cast<std::uint8_t>(value);
    const Frame* first = walk.firstIntact(opcode);
    if (opcode == op::kAttributeStream) {
      // Its registry number is used inside Chunk; the structural error is emitted below.
      continue;
    } else if (opcode == op::kAttachmentIndex) {
      error(&report, "the top-level Attachment Index at byte " +
                         std::to_string(first == nullptr ? 0 : first->offset) +
                         " uses reserved opcode 0x0e; its body is undefined and writers "
                         "MUST NOT emit it (section 5.13)");
    } else if (isPrivate(opcode)) {
      if (count == 1 && first != nullptr) {
        note(&report, "private record " + hex2(opcode) + " (" + std::to_string(first->length) +
                          " bytes) — skipped, as required");
      } else {
        note(&report, std::to_string(count) + " private records " + hex2(opcode) +
                          " — skipped, as required");
      }
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

  if (walk.intact() == 0) {
    error(&report, "no records at all");
    // And where it stopped, which on this path is everything else the file has to say. A magic
    // followed by an incomplete first record has nothing intact, so `seen` is empty and this
    // return fires before the cut note below — leaving the byte, the record and the declared
    // length the walk had already recovered unreported, in exactly the case carrying the least
    // other information. "No records at all" was the whole answer.
    if (walk.cut.has_value()) noteTheCut(&report, walk);
    return report;
  }
  if (walk.firstIntactRecord->opcode != op::kHeader) {
    error(&report, "first record is " + opcodeName(walk.firstIntactRecord->opcode) +
                       "; the Header must come first");
  }
  if (!header) error(&report, "no Header record");
  if (!quantization) error(&report, "no Quantization record");
  if (!footer) error(&report, "no Footer record");
  if (walk.intactOpcodeCounts[op::kFooter] > 1) {
    error(&report, "the file carries " + std::to_string(walk.intactOpcodeCounts[op::kFooter]) +
                       " Footer records; the Footer must be unique and final");
  }
  // The other half of the same normative sentence (spec §4: "the Header MUST be the first record,
  // the Footer MUST be the last"), and a note rather than an error on purpose.
  //
  // Neither the Python reference validator nor the Rust one checks this — both check only the
  // Header half, in the wording copied above. Raising it to `error` here would make this the one
  // validator that calls a file invalid while the reference calls it valid, and a verdict this
  // tool reaches alone is the exact failure this epic exists to prevent. A note carries the fact
  // without moving the verdict, and the check belongs in the reference first.
  if (footer && walk.lastIntactRecord->opcode != op::kFooter) {
    note(&report, "the last record is " + opcodeName(walk.lastIntactRecord->opcode) +
                      "; the Footer must be the last record (section 4)");
  }

  // Which chunk shape the rest of this validator is entitled to assume. A `keyframe-delta`
  // file's Chunks are keyframes and its Delta Chunks are differences against them, so the index
  // check below is about the gaussian-birth shape and about nothing else. Read from the Header
  // rather than guessed from the records, because a file that carries Delta Chunks and does not
  // say so is itself a fault.
  //
  // Asked of the reader rather than parsed here: this is the one field the whole branch turns
  // on, and a tool that read it out of the Header itself could disagree with the reader about
  // which model a file declares — which is the one disagreement that would matter.
  const std::string model = temporalModel(source, walk);
  const bool keyframeDelta = model == "keyframe-delta";

  const std::vector<IndexEntry> index = chunkIndexEntries(source, walk);
  const std::uint64_t physicalIndexCount = walk.intactOpcodeCounts[op::kChunkIndex];
  const bool completeIndex = physicalIndexCount <= kMaxChunkIndexEntries;
  if (!completeIndex) {
    incomplete(&report, "index validation is incomplete: the file carries more than " +
                            std::to_string(kMaxChunkIndexEntries) +
                            " Chunk Index records, beyond this validator's bounded retained index");
  }
  // Resolve every indexed offset against the top-level framing walk. Looking only at the byte at
  // an offset accepts a counterfeit Chunk header embedded in another record's payload; a valid
  // range has to equal one complete frame, opcode and declared total alike.
  std::vector<std::optional<Frame>> physical(index.size());
  std::unordered_map<std::uint64_t, std::vector<std::size_t>> wanted;
  std::unordered_set<std::uint64_t> indexedChunkOffsets;
  std::unordered_set<std::uint64_t> indexedBandOffsets;
  struct IndexedBand {
    std::size_t entry = 0;
    BandRange range;
    std::optional<Frame> physical;
  };
  std::vector<IndexedBand> indexedBands;
  std::unordered_map<std::uint64_t, std::vector<std::size_t>> wantedBands;
  for (std::size_t i = 0; i < index.size(); ++i) {
    wanted[index[i].offset].push_back(i);
    if (!indexedChunkOffsets.insert(index[i].offset).second) {
      error(&report, "chunk index entry " + std::to_string(i) + " duplicates physical chunk " +
                         std::to_string(index[i].offset) +
                         "; each state record must have exactly one index entry");
    }
    for (const BandRange& range : index[i].bands) {
      const std::size_t at = indexedBands.size();
      indexedBands.push_back(IndexedBand{i, range, std::nullopt});
      wantedBands[range.offset].push_back(at);
      indexedBandOffsets.insert(range.offset);
    }
  }
  std::optional<Frame> firstUnindexedState;
  std::optional<Frame> firstUnindexedBand;
  std::optional<std::uint64_t> firstUnindexedBandOwner;
  std::optional<Frame> firstGaussianBirthDelta;
  std::optional<std::uint64_t> physicalStateOwner;
  (void)fourdgs::tool::walk(source, [&](const Frame& frame, bool complete) {
    if (!complete) return;
    const auto found = wanted.find(frame.offset);
    if (found != wanted.end()) {
      for (std::size_t i : found->second) physical[i] = frame;
    }
    const auto foundBands = wantedBands.find(frame.offset);
    if (foundBands != wantedBands.end()) {
      for (std::size_t i : foundBands->second) indexedBands[i].physical = frame;
    }
    const bool state = frame.opcode == op::kChunk || frame.opcode == op::kDeltaChunk;
    if (state) physicalStateOwner = frame.offset;
    if (!keyframeDelta && frame.opcode == op::kDeltaChunk && !firstGaussianBirthDelta.has_value()) {
      firstGaussianBirthDelta = frame;
    }
    if (state && physicalIndexCount > 0 && completeIndex &&
        indexedChunkOffsets.find(frame.offset) == indexedChunkOffsets.end() &&
        !firstUnindexedState.has_value()) {
      firstUnindexedState = frame;
    }
    if (frame.opcode == op::kShBandStream && physicalIndexCount > 0 && completeIndex &&
        indexedBandOffsets.find(frame.offset) == indexedBandOffsets.end() &&
        !firstUnindexedBand.has_value()) {
      firstUnindexedBand = frame;
      firstUnindexedBandOwner = physicalStateOwner;
    }
  });
  for (std::size_t i = 0; i < index.size(); ++i) {
    const IndexEntry& entry = index[i];
    const std::uint64_t end = entry.offset + entry.length;
    // `offset >= size` and not just `end > size`. An entry declaring `chunk_offset == size` with
    // `chunk_length == 0` has an end exactly at the end of the file, so the arithmetic check
    // passes — and the opcode read below then reaches one byte past the last, which over a
    // borrowed buffer is a read outside it. These are untrusted bytes off the file being
    // validated, so an entry naming the byte after the file is a diagnosis to print, not an
    // address to dereference.
    const bool overflows = end < entry.offset || end > size || entry.offset >= size;
    // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta Chunk is a
    // difference against one, and an index that could only name the former could not seek the
    // model at all.
    if (overflows) {
      error(&report, "chunk index entry " + std::to_string(i) + " points past the end of the file");
    } else if (!physical[i].has_value() ||
               (physical[i]->opcode != op::kChunk &&
                !(keyframeDelta && physical[i]->opcode == op::kDeltaChunk))) {
      error(&report, "chunk index entry " + std::to_string(i) +
                         " does not point at the start of a "
                         "top-level Chunk record");
    } else if (physical[i]->total() != entry.length) {
      error(&report, "chunk index entry " + std::to_string(i) + " declares " +
                         std::to_string(entry.length) + " bytes at " +
                         std::to_string(entry.offset) + "; the record there is " +
                         std::to_string(physical[i]->total()) + " bytes");
    }
  }
  for (const IndexedBand& band : indexedBands) {
    const std::uint64_t end = band.range.offset + band.range.length;
    const bool overflows = end < band.range.offset || end > size || band.range.offset >= size;
    if (overflows) {
      error(&report, "SH band " + std::to_string(band.range.band) + " at index entry " +
                         std::to_string(band.entry) + " points past the end of the file");
    } else if (!band.physical.has_value() || band.physical->opcode != op::kShBandStream) {
      error(&report, "SH band " + std::to_string(band.range.band) + " at index entry " +
                         std::to_string(band.entry) +
                         " does not point at the start of a top-level SH Band Stream record");
    } else if (band.physical->total() != band.range.length) {
      error(&report, "SH band " + std::to_string(band.range.band) + " at index entry " +
                         std::to_string(band.entry) + " declares " +
                         std::to_string(band.range.length) + " bytes at " +
                         std::to_string(band.range.offset) + "; the record there is " +
                         std::to_string(band.physical->total()) + " bytes");
    }
  }
  if (firstUnindexedState.has_value()) {
    error(&report, "the physical " + opcodeName(firstUnindexedState->opcode) + " record at byte " +
                       std::to_string(firstUnindexedState->offset) +
                       " is absent from the Chunk Index");
  }
  if (firstUnindexedBand.has_value()) {
    std::string owner =
        firstUnindexedBandOwner.has_value()
            ? " following state record at byte " + std::to_string(*firstUnindexedBandOwner)
            : " with no preceding state record";
    error(&report, "the physical SH Band Stream record at byte " +
                       std::to_string(firstUnindexedBand->offset) + owner +
                       " is absent from the Chunk Index");
  }
  if (firstGaussianBirthDelta.has_value()) {
    error(&report, "the gaussian-birth file carries a Delta Chunk record at byte " +
                       std::to_string(firstGaussianBirthDelta->offset) +
                       "; Delta Chunk is legal only under keyframe-delta");
  }
  if (walk.intactOpcodeCounts[op::kAttributeStream] > 0) {
    const Frame* attribute = walk.firstIntact(op::kAttributeStream);
    error(&report,
          "the top-level Attribute Stream at byte " +
              std::to_string(attribute == nullptr ? 0 : attribute->offset) +
              " is invalid; Attribute Stream is a bare structure inside Chunk, not a record");
  }

  std::optional<SummaryDeclaration> summary = summaryDeclaration(source, walk);
  if (summary.has_value()) {
    if (summary->start > summary->end) {
      error(&report, "the Footer's summary starts at " + std::to_string(summary->start) +
                         ", after the summary ends at " + std::to_string(summary->end));
    } else if (summary->start == 0) {
      if (physicalIndexCount > 0) {
        error(&report, "the Footer's summary_start is 0, but the file carries Chunk Index records");
      }
      if (summary->offsetStart != 0) {
        error(&report, "the Footer's summary_offset_start is nonzero while summary_start is 0");
      }
    } else {
      const Frame* firstIndex = walk.firstIntact(op::kChunkIndex);
      if (firstIndex == nullptr || firstIndex->offset != summary->start) {
        error(&report, "the Footer's summary_start " + std::to_string(summary->start) +
                           " does not name the first Chunk Index record");
      }
      std::optional<Frame> firstOffset;
      std::optional<Frame> foreignSummaryRecord;
      std::optional<Frame> earlySummaryRecord;
      (void)fourdgs::tool::walk(source, [&](const Frame& frame, bool complete) {
        if (!complete || frame.offset >= summary->end) return;
        const bool summaryKind = frame.opcode == op::kChunkIndex ||
                                 frame.opcode == op::kStatistics ||
                                 frame.opcode == op::kSummaryOffset;
        if (frame.opcode == op::kSummaryOffset && !firstOffset.has_value()) firstOffset = frame;
        if (frame.offset < summary->start) {
          if (summaryKind && !earlySummaryRecord.has_value()) earlySummaryRecord = frame;
          return;
        }
        if (!summaryKind && !foreignSummaryRecord.has_value()) foreignSummaryRecord = frame;
      });
      if (earlySummaryRecord.has_value()) {
        error(&report, "the " + opcodeName(earlySummaryRecord->opcode) + " record at byte " +
                           std::to_string(earlySummaryRecord->offset) +
                           " lies before the Footer's contiguous summary");
      }
      if (foreignSummaryRecord.has_value()) {
        error(&report, "the Footer's summary contains " + opcodeName(foreignSummaryRecord->opcode) +
                           " at byte " + std::to_string(foreignSummaryRecord->offset) +
                           "; expected only Chunk Index, Statistics, or Summary Offset records");
      }
      const std::uint64_t actualOffsetStart =
          firstOffset.has_value() ? firstOffset->offset : static_cast<std::uint64_t>(0);
      if (summary->offsetStart != actualOffsetStart) {
        error(&report, "the Footer's summary_offset_start is " +
                           std::to_string(summary->offsetStart) + "; expected " +
                           std::to_string(actualOffsetStart));
      }
    }

    if (summary->crc != 0 && summary->start != 0 && summary->start <= summary->end) {
      Result<std::optional<Coverage>> covered = coverage(source, walk);
      if (!covered) {
        incomplete(&report,
                   "the summary checksum could not be verified: " + covered.error().message);
      } else if (covered->has_value() && !covered->value().ok) {
        error(&report,
              "summary CRC mismatch: the index is untrustworthy (a streamed read still works)");
      }
    }
  }

  if (header && physicalIndexCount == 0) {
    warn(&report, "no chunk index: this file can only be read front to back, not seeked");
  }

  // What survived the cut, which is the question the errors above do not answer.
  if (walk.cut.has_value()) noteTheCut(&report, walk);

  if (keyframeDelta) {
    checkKeyframeDelta(&report);
  } else {
    checkGaussianBirth(source, walk, index, &report);
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
  Result<FileReadable*> file = FileReadable::open(path);
  if (!file) {
    // Not the file's fault, and not a refusal. See `kExitTool`.
    err << "4dgs: " << path << ": " << file.error().message << "\n";
    return kExitTool;
  }
  std::unique_ptr<FileReadable> source(*file);
  const Report report = validate(*source);
  for (const Finding& finding : report.findings) {
    out << severityName(finding.severity) << ": " << finding.message << "\n";
    // Indented, and with a prefix of its own, so that a caller filtering the findings on
    // `error:`/`warning:`/`note:` — which is how the validators are compared — sees exactly what
    // it saw before.
    if (finding.refusal.has_value()) out << "  " << finding.refusal->toString() << "\n";
  }
  if (report.hasErrors()) {
    err << "INVALID\n";
    return kExitFailed;
  }
  if (!report.complete) {
    err << "INCOMPLETE\n";
    return kExitTool;
  }
  out << (report.findings.empty() ? "valid" : "valid (with notes)") << "\n";
  // The one deliberate divergence from the Python tool, which exits 0 here, and the Rust tool's
  // too. A warning a script cannot see is a warning nobody acts on, so it gets its own code.
  return report.worst() == Severity::kWarning ? kExitWarnings : kExitOk;
}

}  // namespace tool
}  // namespace fourdgs
