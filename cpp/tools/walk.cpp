// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Which record is where, which refusal fired, and at which byte.
///
/// The binding already names its refusals — `Error::refusal` carries the identifier the
/// conformance corpus is written against — and the core's messages already say which value was
/// found and what was expected. What neither of them carries is the **offset**: an error is
/// raised where the value was parsed, not where the bytes sit, and by then the record's
/// position is several frames down the call stack, on the other side of an ABI.
///
/// So the tool supplies it. The refusal vocabulary is six identifiers, each of which is about
/// exactly one kind of record, and a framing walk knows where every record is. That is the
/// whole mechanism: walk the framing, ask which record this refusal is about, print the byte.
///
/// Front matter is located from framing alone. A refusal that lives inside a chunk's streams is
/// located by decoding chunks one at a time until one of them refuses, which is also the only
/// way to *find* those refusals at all — the framing walk steps over a chunk by its declared
/// length and never looks inside it, which is why a framing-only validator calls two of the
/// invalid corpus's seven files clean.

#include <cstdio>
#include <memory>

#include "tool.hpp"

namespace fourdgs {
namespace tool {

const std::uint8_t kMagic[8] = {0x89, '4', 'D', 'G', 'S', '1', 0x0D, 0x0A};

namespace {

/// The refusal identifiers, spec §4. Compared by value against what the core reports, so this
/// list is a reader of the vocabulary rather than a second definition of it: an identifier that
/// is not here is left unplaced, not renamed.
constexpr const char* kMagicMismatch = "magic-mismatch";
constexpr const char* kUnsupportedMajorVersion = "unsupported-major-version";
constexpr const char* kUnknownTemporalModel = "unknown-temporal-model";
constexpr const char* kUnknownQuantizationScheme = "unknown-quantization-scheme";

std::uint64_t readU64(const std::uint8_t* at) {
  std::uint64_t value = 0;
  for (int i = 7; i >= 0; --i) value = (value << 8) | at[i];
  return value;
}

/// Exactly `length` bytes at `offset`, or nothing.
///
/// `Readable::read` is allowed to come back short — the abstraction says so, because a resource
/// can shrink between the `size()` that was asked for and the read that follows. A caller that
/// parses the buffer regardless is parsing whatever was there before, which is how a truncated
/// file turns into an invented opcode or a magic that does not match. Every fixed-size read in
/// this file goes through here so that a short one is reported as a short one.
bool readExactly(Readable& source, std::uint64_t offset, std::uint8_t* into, std::size_t length) {
  Result<std::size_t> got = source.read(offset, Span<std::uint8_t>(into, length));
  return got.ok() && *got == length;
}

/// Ask the core to name a bad magic, so the wording and the identifier are the reader's.
///
/// Only reached once the eight bytes have already been found not to be ours, and only over the
/// prefix: `peekTemporalModel` checks the magic before it needs another byte, so a few kilobytes
/// are enough to get the diagnosis without reading a file this tool has just refused.
///
/// Two refusals live here and telling them apart is the reader's job, not this tool's: every byte
/// of the magic except one is a fixed sentinel, so a file that differs elsewhere is not a 4dgs
/// file whatever its version byte says, while a file that differs only there wants a newer reader.
/// Guessing between them sends somebody looking for a build that would not have helped.
///
/// When there is no reader — the no-core build — the tool still says what it can see for itself,
/// without an identifier it has not been given. `inspect` is framing, and framing does not need a
/// decoder.
Error refuseMagic(Readable& source, std::uint64_t size) {
  const std::uint64_t take = size < 4096 ? size : 4096;
  std::vector<std::uint8_t> head(static_cast<std::size_t>(take));
  Result<std::size_t> got = source.read(0, Span<std::uint8_t>(head.data(), head.size()));
  if (got) head.resize(*got);
  Result<std::string> peek = peekTemporalModel(Span<const std::uint8_t>(head.data(), head.size()));
  if (!peek && peek.error().refusal.has_value()) return peek.error();
  return Error(ErrorCode::kBadMagic, "the first eight bytes are not the 4dgs magic");
}

}  // namespace

Result<std::uint64_t> BorrowedReadable::size() { return static_cast<std::uint64_t>(bytes_.size()); }

Result<std::size_t> BorrowedReadable::read(std::uint64_t offset, Span<std::uint8_t> into) {
  if (offset > bytes_.size()) return static_cast<std::size_t>(0);
  const std::size_t available = bytes_.size() - static_cast<std::size_t>(offset);
  const std::size_t take = available < into.size() ? available : into.size();
  for (std::size_t i = 0; i < take; ++i) into[i] = bytes_[static_cast<std::size_t>(offset) + i];
  return take;
}

std::uint64_t Frame::total() const {
  const std::uint64_t sum = length + kRecordHeaderSize;
  return sum < length ? UINT64_MAX : sum;
}

const Frame* Walk::first(std::uint8_t opcode) const {
  for (const Frame& frame : representatives) {
    if (frame.opcode == opcode) return &frame;
  }
  return nullptr;
}

const Frame* Walk::firstIntact(std::uint8_t opcode) const {
  if (intactOpcodeCounts[opcode] == 0) return nullptr;
  for (const Frame& frame : representatives) {
    if (frame.opcode == opcode && frame.offset + frame.total() >= frame.offset &&
        frame.offset + frame.total() <= size) {
      return &frame;
    }
  }
  return nullptr;
}

const BandRange* IndexEntry::bandRange(int band) const {
  for (const BandRange& range : bands) {
    if (range.band == band) return &range;
  }
  return nullptr;
}

std::uint64_t Walk::intact() const { return intactRecordCount; }

bool isPrivate(std::uint8_t opcode) { return opcode >= op::kPrivateStart; }

bool isProvenance(std::uint8_t opcode) {
  return opcode >= op::kCoordinateFrame && opcode < op::kProvenanceEnd;
}

bool isSpecified(std::uint8_t opcode) {
  return ((opcode >= op::kHeader && opcode <= op::kAudioData) && opcode != op::kAttributeStream &&
          opcode != op::kAttachmentIndex) ||
         (opcode >= op::kCoordinateFrame && opcode <= op::kObjectTrack);
}

std::string opcodeName(std::uint8_t opcode) {
  switch (opcode) {
    case 0x01:
      return "Header";
    case 0x02:
      return "Footer";
    case 0x03:
      return "Quantization";
    case 0x04:
      return "WindowTable";
    case 0x05:
      return "Chunk";
    case 0x06:
      return "AttributeStream";
    case 0x07:
      return "ShBandStream";
    case 0x08:
      return "ChunkIndex";
    case 0x09:
      return "Audio";
    case 0x0A:
      return "Camera";
    case 0x0B:
      return "Metadata";
    case 0x0C:
      return "Statistics";
    case 0x0D:
      return "Attachment";
    case 0x0E:
      return "AttachmentIndex";
    case 0x0F:
      return "SummaryOffset";
    case 0x10:
      return "DeltaChunk";
    case 0x11:
      return "Audio Source";
    case 0x12:
      return "Audio Data";
    case 0x20:
      return "CoordinateFrame";
    case 0x21:
      return "SensorCalibration";
    case 0x22:
      return "RigTrajectory";
    case 0x23:
      return "GeodeticAnchor";
    case 0x24:
      return "ObjectTable";
    case 0x25:
      return "ObjectTrack";
    default:
      break;
  }
  char buffer[24];
  std::snprintf(buffer, sizeof(buffer), isPrivate(opcode) ? "Private(0x%02X)" : "Unknown(0x%02X)",
                static_cast<unsigned>(opcode));
  return std::string(buffer);
}

std::string commas(std::uint64_t value) {
  const std::string digits = std::to_string(value);
  std::string out;
  out.reserve(digits.size() + digits.size() / 3);
  for (std::size_t i = 0; i < digits.size(); ++i) {
    if (i > 0 && (digits.size() - i) % 3 == 0) out.push_back(',');
    out.push_back(digits[i]);
  }
  return out;
}

namespace {

/// CRC-32 (IEEE). Written out rather than linked, exactly as the conformance helper writes it
/// out: a checksum is fifteen lines and a dependency is forever.
///
/// Built once, in the initializer of a function-local `static`, which C++11 makes thread-safe:
/// the first caller through builds it and every other caller blocks until it is whole. The
/// obvious spelling — a file-scope table beside a `bool ready` — is a data race the moment two
/// threads validate two files, and its symptom is a checksum computed from a half-built table,
/// which reads as a corrupt file rather than as a bug in this function.
struct Crc32Table {
  std::uint32_t entry[256];

  Crc32Table() {
    for (std::uint32_t i = 0; i < 256; ++i) {
      std::uint32_t c = i;
      for (int k = 0; k < 8; ++k) c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      entry[i] = c;
    }
  }
};

const Crc32Table& crc32Table() {
  static const Crc32Table table;
  return table;
}

/// The running value, so a checksum can be accumulated across reads without holding the range.
std::uint32_t crc32Update(std::uint32_t crc, const std::uint8_t* data, std::size_t length) {
  const Crc32Table& table = crc32Table();
  for (std::size_t i = 0; i < length; ++i) {
    crc = table.entry[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  }
  return crc;
}

/// One buffer, whatever the range. 64 KiB is a read size a filesystem is happy with and a number
/// this tool never multiplies by anything.
constexpr std::size_t kCrcBuffer = 64 * 1024;

}  // namespace

std::uint32_t crc32(const std::uint8_t* data, std::size_t length) {
  return crc32Update(0xFFFFFFFFu, data, length) ^ 0xFFFFFFFFu;
}

Result<std::uint32_t> crc32Range(Readable& source, std::uint64_t start, std::uint64_t end) {
  if (end < start) {
    return Error(ErrorCode::kInvalidArgument, "summary checksum range starts after it ends (" +
                                                  std::to_string(start) + ".." +
                                                  std::to_string(end) + ")");
  }
  std::vector<std::uint8_t> buffer(kCrcBuffer);
  std::uint32_t crc = 0xFFFFFFFFu;
  for (std::uint64_t at = start; at < end;) {
    const std::uint64_t remaining = end - at;
    const std::size_t take = remaining < static_cast<std::uint64_t>(buffer.size())
                                 ? static_cast<std::size_t>(remaining)
                                 : buffer.size();
    Result<std::size_t> got = source.read(at, Span<std::uint8_t>(buffer.data(), take));
    if (!got) {
      return Error(got.error().code, "summary checksum bytes " + std::to_string(at) + ".." +
                                         std::to_string(at + take) +
                                         " could not be read: " + got.error().message);
    }
    if (*got != take) {
      return Error(ErrorCode::kTruncated, "summary checksum bytes " + std::to_string(at) + ".." +
                                              std::to_string(at + take) + " returned only " +
                                              std::to_string(*got) + " bytes");
    }
    crc = crc32Update(crc, buffer.data(), take);
    at += take;
  }
  return crc ^ 0xFFFFFFFFu;
}

Result<Walk> walk(Readable& source, const FrameVisitor& visitor) {
  Result<std::uint64_t> sized = source.size();
  if (!sized) return sized.error();
  const std::uint64_t size = *sized;

  std::uint8_t head[kMagicSize] = {0};
  const std::uint64_t headBytes = size < kMagicSize ? size : kMagicSize;
  Result<std::size_t> got =
      source.read(0, Span<std::uint8_t>(head, static_cast<std::size_t>(headBytes)));
  if (!got) return got.error();
  // The bytes that arrived, not the bytes that were asked for. A resource is allowed to come back
  // short, and eight zero bytes read as "this is not a 4dgs file" rather than as the truncation
  // they are — a diagnosis that sends its reader after the wrong problem entirely.
  if (headBytes < kMagicSize || *got < kMagicSize) {
    return Error(ErrorCode::kTruncated, "truncated: file is shorter than the magic");
  }
  for (std::size_t i = 0; i < kMagicSize; ++i) {
    if (head[i] != kMagic[i]) return refuseMagic(source, size);
  }

  Walk out;
  out.size = size;
  std::uint64_t at = kMagicSize;
  while (true) {
    const std::uint64_t remaining = size - at;
    if (remaining == 0) break;
    // A whole file ends with the magic, so its last eight bytes are not a record.
    if (remaining <= kMagicSize) {
      std::uint8_t tail[kMagicSize] = {0};
      Result<std::size_t> tailRead =
          source.read(at, Span<std::uint8_t>(tail, static_cast<std::size_t>(remaining)));
      if (!tailRead) return tailRead.error();
      if (*tailRead != remaining) {
        Cut cut;
        cut.at = at;
        cut.reason = "the last " + commas(remaining) + " bytes returned only " +
                     commas(*tailRead) + " bytes";
        out.cut = cut;
        break;
      }
      out.trailingMagic = remaining == kMagicSize;
      for (std::size_t i = 0; i < static_cast<std::size_t>(remaining) && out.trailingMagic; ++i) {
        if (tail[i] != kMagic[i]) out.trailingMagic = false;
      }
      if (!out.trailingMagic) {
        Cut cut;
        cut.at = at;
        cut.reason = commas(remaining) + " trailing bytes are neither a record nor the magic";
        out.cut = cut;
      }
      break;
    }
    if (remaining < kRecordHeaderSize) {
      Cut cut;
      cut.at = at;
      cut.reason = commas(remaining) + " bytes are too few for a record header";
      out.cut = cut;
      break;
    }
    std::uint8_t framing[kRecordHeaderSize] = {0};
    // Nine bytes or none. A short read here would otherwise be parsed as a record: whatever byte
    // arrived becomes an opcode and the unread remainder becomes a declared length, so the walk
    // would report an invented record instead of naming the byte the file stops at.
    Result<std::size_t> framingRead = source.read(
        at, Span<std::uint8_t>(framing, static_cast<std::size_t>(kRecordHeaderSize)));
    if (!framingRead) return framingRead.error();
    if (*framingRead != kRecordHeaderSize) {
      Cut cut;
      cut.at = at;
      cut.reason = "the record header at this byte returned only " +
                   commas(*framingRead) + " of " + commas(kRecordHeaderSize) + " bytes";
      out.cut = cut;
      break;
    }

    Frame frame;
    frame.opcode = framing[0];
    frame.offset = at;
    frame.length = readU64(framing + 1);
    out.recordCount += 1;
    out.opcodeCounts[frame.opcode] += 1;
    out.firstRecord = out.firstRecord.has_value() ? out.firstRecord : std::optional<Frame>(frame);
    out.lastRecord = frame;
    // Two representatives per opcode are sufficient for every later use: the first places a
    // unique refusal, and the second proves it is not unique. Memory therefore stays fixed even
    // for a valid file containing millions of empty private records.
    if (out.opcodeCounts[frame.opcode] <= 2) out.representatives.push_back(frame);

    const std::uint64_t end = at + frame.total();
    if (frame.total() == UINT64_MAX || end < at || end > size) {
      if (visitor) visitor(frame, false);
      Cut cut;
      cut.at = at;
      cut.reason = "the " + opcodeName(frame.opcode) + " record declares " + commas(frame.length) +
                   " bytes, past the end of a " + commas(size) + "-byte file";
      cut.insideARecord = true;
      out.cut = cut;
      break;
    }
    out.intactRecordCount += 1;
    out.intactOpcodeCounts[frame.opcode] += 1;
    out.firstIntactRecord =
        out.firstIntactRecord.has_value() ? out.firstIntactRecord : std::optional<Frame>(frame);
    out.lastIntactRecord = frame;
    if (visitor) visitor(frame, true);
    at = end;
  }
  return out;
}

std::string Named::toString() const {
  std::string out = "refusal " + code;
  if (site.has_value()) {
    out += " at byte " + std::to_string(site->offset) + " (" + site->what + ")";
  }
  return out;
}

namespace {

/// Which record a named refusal is about.
///
/// A table rather than a guess, and a short one because the refusal vocabulary is short. A code
/// this build has not been taught is not placed rather than placed wrongly — an offset that
/// points at the wrong record is worse than no offset, because the reader believes it.
std::optional<Site> frontMatterSite(const Walk* walk, const std::string& code) {
  // Both of these are about the eight bytes of the magic itself, which is why neither needs a
  // walk to place: the walk that would find a record cannot start until they pass, and the
  // offset is known without one.
  if (code == kMagicMismatch || code == kUnsupportedMajorVersion) {
    return Site{0, "the magic"};
  }
  std::uint8_t opcode = 0;
  const char* what = nullptr;
  if (code == kUnknownTemporalModel) {
    opcode = op::kHeader;
    what = "the Header record";
  } else if (code == kUnknownQuantizationScheme) {
    opcode = op::kQuantization;
    what = "the Quantization record";
  } else {
    return std::nullopt;
  }
  if (walk == nullptr) return std::nullopt;
  // Exactly one record of that kind, or no offset. Nothing in the format forbids a second Header
  // or a second Quantization record, and a reader refuses at whichever copy carries the value it
  // does not implement — which need not be the first. Telling them apart means parsing each
  // candidate and asking a registry about the value it declares, and this package has neither a
  // parser nor a registry; the alternative on offer is an offset pointing at a record with
  // nothing wrong with it, which the paragraph above rules out for the reason it gives. Every
  // corpus variant carries one of each, so this costs none of the seven placements.
  const Frame* found = nullptr;
  if (walk->intactOpcodeCounts[opcode] != 1) return std::nullopt;
  for (const Frame& frame : walk->representatives) {
    if (frame.opcode == opcode) found = &frame;
  }
  if (found == nullptr) return std::nullopt;
  return Site{found->offset, what};
}

}  // namespace

std::optional<Named> describe(const Error& error, const Walk* walk,
                              const std::optional<Site>& site) {
  if (!error.refusal.has_value()) return std::nullopt;
  Named named;
  named.code = *error.refusal;
  named.site = site.has_value() ? site : frontMatterSite(walk, named.code);
  return named;
}

std::vector<IndexEntry> chunkIndexEntries(Readable& source, const Walk& framing) {
  // `t0`, `t1`, `chunk_offset`, `chunk_length`: two doubles in, and the only fields this needs.
  // Everything after them is what a seek costs rather than where the chunk is, and a later
  // revision may append to it — which is why this reads a prefix and not a record.
  constexpr std::uint64_t kOffsetField = 16;
  constexpr std::size_t kPrefix = 40;
  // Band 1 upwards, appended after the fixed prefix: `u8 band`, `u64 offset`, `u64 length`.
  constexpr std::size_t kBandEntry = 17;
  std::vector<IndexEntry> out;
  if (framing.intactOpcodeCounts[op::kChunkIndex] == 0) return out;
  std::uint8_t prefix[kPrefix];
  std::uint8_t band[kBandEntry];
  (void)walk(source, [&](const Frame& frame, bool complete) {
    if (!complete || out.size() >= kMaxChunkIndexEntries) return;
    if (frame.opcode != op::kChunkIndex) return;
    const std::uint64_t content = frame.offset + kRecordHeaderSize;
    if (frame.length < kPrefix) return;
    if (!readExactly(source, content, prefix, kPrefix)) return;
    IndexEntry entry;
    entry.offset = readU64(prefix + kOffsetField);
    entry.length = readU64(prefix + kOffsetField + 8);
    // `gaussian_count` then `band_count`, two `u32`s closing the prefix.
    std::uint32_t bands = 0;
    for (int i = 3; i >= 0; --i) bands = (bands << 8) | prefix[36 + i];
    // The format defines at most three SH bands. Reading more would only retain an untrusted
    // count's worth of ranges for a record the decoder will refuse independently.
    const std::uint32_t keptBands = bands < 3 ? bands : 3;
    for (std::uint32_t b = 0; b < keptBands; ++b) {
      const std::uint64_t at = content + kPrefix + static_cast<std::uint64_t>(b) * kBandEntry;
      // The declared count is off an untrusted file; the record's own length is the bound.
      if (kPrefix + static_cast<std::uint64_t>(b + 1) * kBandEntry > frame.length) break;
      if (!readExactly(source, at, band, kBandEntry)) break;
      BandRange range;
      range.band = band[0];
      range.offset = readU64(band + 1);
      range.length = readU64(band + 9);
      entry.bands.push_back(range);
    }
    out.push_back(entry);
  });
  return out;
}

std::optional<ChunkRefusal> scanChunks(Readable& source, const std::vector<IndexEntry>& index) {
  if (index.empty()) return std::nullopt;
  Result<std::unique_ptr<Scene>> opened = Scene::open(source, ReadMode::kIndexed);
  if (!opened) return ChunkRefusal{opened.error(), std::nullopt};
  Scene& scene = **opened;

  // The degree the file declares, so the scan fetches what the file says it carries. A cap of 0
  // transfers no band record at all, which is why a band that will not decode used to come back
  // as a file with nothing wrong with it.
  const int degree = scene.shDegree();
  const std::uint32_t chunks = scene.chunkCount();
  if (scene.isIndexed()) {
    for (std::uint32_t i = 0; i < chunks; ++i) {
      Result<void> loaded = scene.loadChunk(i, degree);
      if (loaded) continue;

      std::optional<Site> site;
      if (i < index.size()) {
        site = Site{index[i].offset, "the Chunk record at index entry " + std::to_string(i)};
        // Which band, if it was a band. The cap is raised from nothing until the fetch starts
        // failing: the first cap that fails is the first band the reader could not decode, and
        // failing at 0 means the fault is in the chunk's own attribute streams rather than in
        // any band. This runs only here, on the failure path, so a healthy file pays nothing.
        for (int cap = 0; cap <= degree; ++cap) {
          if (scene.loadChunk(i, cap)) continue;
          if (cap == 0) break;
          const BandRange* range = index[i].bandRange(cap);
          if (range != nullptr) {
            site = Site{range->offset, "the SH Band Stream record for band " + std::to_string(cap) +
                                           " at index entry " + std::to_string(i)};
          }
          break;
        }
      }
      return ChunkRefusal{loaded.error(), site};
    }
  }
  return std::nullopt;
}

std::optional<SummaryDeclaration> summaryDeclaration(Readable& source, const Walk& walk) {
  // A summary declaration belongs to the unique trailing Footer. Reading the
  // first Footer lets an earlier counterfeit suppress or redirect the checksum
  // while a second Footer satisfies the last-record shape.
  if (walk.intactOpcodeCounts[op::kFooter] != 1 || !walk.lastIntactRecord.has_value() ||
      walk.lastIntactRecord->opcode != op::kFooter) {
    return std::nullopt;
  }
  const Frame* frame = &*walk.lastIntactRecord;
  // `summary_start`, `summary_offset_start`, `summary_crc` — twenty bytes, and the only record
  // this tool reads the content of. A Footer a later revision extends still parses: the fields
  // this needs are the first three and they do not move.
  constexpr std::size_t kFooterFields = 20;
  const std::uint64_t content = frame->offset + kRecordHeaderSize;
  if (frame->length < kFooterFields) return std::nullopt;
  std::uint8_t at[kFooterFields];
  if (!readExactly(source, content, at, kFooterFields)) return std::nullopt;
  SummaryDeclaration out;
  out.start = readU64(at);
  out.offsetStart = readU64(at + 8);
  for (int i = 3; i >= 0; --i) out.crc = (out.crc << 8) | at[16 + i];
  // The summary ends where the Footer begins — taken from the walk rather than computed from a
  // footer's expected size, so a Footer that a later revision extends does not move the region
  // out from under the check.
  out.end = frame->offset;
  return out;
}

Result<std::optional<Coverage>> coverage(Readable& source, const Walk& walk) {
  std::optional<SummaryDeclaration> declared = summaryDeclaration(source, walk);
  if (!declared.has_value() || declared->crc == 0 || declared->start == 0 ||
      declared->start > declared->end) {
    return std::optional<Coverage>();
  }
  Result<std::uint32_t> actual = crc32Range(source, declared->start, declared->end);
  if (!actual) return actual.error();
  Coverage out;
  out.start = declared->start;
  out.end = declared->end;
  out.ok = *actual == declared->crc;
  return std::optional<Coverage>(out);
}

const char* coverageCell(const std::optional<Coverage>& coverage, std::uint64_t at,
                         std::uint64_t total) {
  if (!coverage.has_value()) return "-";
  const std::uint64_t end = at + total;
  if (at < coverage->start || end < at || end > coverage->end) return "-";
  return coverage->ok ? "ok" : "MISMATCH";
}

Result<std::vector<std::uint8_t>> readWhole(const std::string& path) {
  Result<FileReadable*> file = FileReadable::open(path);
  if (!file) return file.error();
  std::unique_ptr<FileReadable> source(*file);
  Result<std::uint64_t> size = source->size();
  if (!size) return size.error();
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(*size));
  if (bytes.empty()) return bytes;
  Result<std::size_t> got = source->read(0, Span<std::uint8_t>(bytes.data(), bytes.size()));
  if (!got) return got.error();
  bytes.resize(*got);
  return bytes;
}

Result<Walk> walkBytes(Span<const std::uint8_t> data, const FrameVisitor& visitor) {
  BorrowedReadable source(data);
  return walk(source, visitor);
}

}  // namespace tool
}  // namespace fourdgs
