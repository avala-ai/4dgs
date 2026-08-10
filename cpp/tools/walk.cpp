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

/// A `Readable` over bytes the caller already holds, without copying them.
///
/// `MemoryReadable` takes ownership of a copy, which is the right shape for a test fixture and
/// the wrong one for a file this tool has just read whole.
class BorrowedReadable : public Readable {
 public:
  explicit BorrowedReadable(Span<const std::uint8_t> bytes) : bytes_(bytes) {}

  Result<std::uint64_t> size() override { return static_cast<std::uint64_t>(bytes_.size()); }

  Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset > bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t available = bytes_.size() - static_cast<std::size_t>(offset);
    const std::size_t take = available < into.size() ? available : into.size();
    for (std::size_t i = 0; i < take; ++i) into[i] = bytes_[static_cast<std::size_t>(offset) + i];
    return take;
  }

 private:
  Span<const std::uint8_t> bytes_;
};

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

std::uint64_t Frame::total() const {
  const std::uint64_t sum = length + kRecordHeaderSize;
  return sum < length ? UINT64_MAX : sum;
}

const Frame* Walk::first(std::uint8_t opcode) const {
  for (const Frame& frame : records) {
    if (frame.opcode == opcode) return &frame;
  }
  return nullptr;
}

std::size_t Walk::intact() const {
  const std::size_t incomplete = (cut.has_value() && cut->insideARecord) ? 1 : 0;
  return records.size() < incomplete ? 0 : records.size() - incomplete;
}

bool isPrivate(std::uint8_t opcode) { return opcode >= op::kPrivateStart; }

bool isProvenance(std::uint8_t opcode) {
  return opcode >= op::kCoordinateFrame && opcode < op::kProvenanceEnd;
}

bool isSpecified(std::uint8_t opcode) {
  return (opcode >= op::kHeader && opcode <= op::kAudioData) ||
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

std::uint32_t crc32(const std::uint8_t* data, std::size_t length) {
  // CRC-32 (IEEE). Written out rather than linked, exactly as the conformance helper writes it
  // out: a checksum is fifteen lines and a dependency is forever.
  static std::uint32_t table[256];
  static bool ready = false;
  if (!ready) {
    for (std::uint32_t i = 0; i < 256; ++i) {
      std::uint32_t c = i;
      for (int k = 0; k < 8; ++k) c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      table[i] = c;
    }
    ready = true;
  }
  std::uint32_t crc = 0xFFFFFFFFu;
  for (std::size_t i = 0; i < length; ++i) {
    crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}

Result<Walk> walk(Readable& source) {
  Result<std::uint64_t> sized = source.size();
  if (!sized) return sized.error();
  const std::uint64_t size = *sized;

  std::uint8_t head[kMagicSize] = {0};
  const std::uint64_t headBytes = size < kMagicSize ? size : kMagicSize;
  Result<std::size_t> got =
      source.read(0, Span<std::uint8_t>(head, static_cast<std::size_t>(headBytes)));
  if (!got) return got.error();
  if (headBytes < kMagicSize) {
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
      Result<std::size_t> read =
          source.read(at, Span<std::uint8_t>(tail, static_cast<std::size_t>(remaining)));
      if (!read) return read.error();
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
    Result<std::size_t> read =
        source.read(at, Span<std::uint8_t>(framing, static_cast<std::size_t>(kRecordHeaderSize)));
    if (!read) return read.error();

    Frame frame;
    frame.opcode = framing[0];
    frame.offset = at;
    frame.length = readU64(framing + 1);
    // A record is listed either way: a declared length that runs off the end is a fact about
    // that record, and hiding the record hides the field that carries the fault.
    out.records.push_back(frame);

    const std::uint64_t end = at + frame.total();
    if (frame.total() == UINT64_MAX || end < at || end > size) {
      Cut cut;
      cut.at = at;
      cut.reason = "the " + opcodeName(frame.opcode) + " record declares " + commas(frame.length) +
                   " bytes, past the end of a " + commas(size) + "-byte file";
      cut.insideARecord = true;
      out.cut = cut;
      break;
    }
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
  const Frame* frame = walk->first(opcode);
  if (frame == nullptr) return std::nullopt;
  return Site{frame->offset, what};
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

std::vector<IndexEntry> chunkIndexEntries(Span<const std::uint8_t> data, const Walk& walk) {
  // `t0`, `t1`, `chunk_offset`, `chunk_length`: two doubles in, and the only fields this needs.
  // Everything after them is what a seek costs rather than where the chunk is, and a later
  // revision may append to it — which is why this reads a prefix and not a record.
  constexpr std::uint64_t kOffsetField = 16;
  constexpr std::uint64_t kPrefix = 32;
  std::vector<IndexEntry> out;
  for (const Frame& frame : walk.records) {
    if (frame.opcode != op::kChunkIndex) continue;
    const std::uint64_t content = frame.offset + kRecordHeaderSize;
    if (frame.length < kPrefix || content + kPrefix > data.size()) continue;
    IndexEntry entry;
    entry.offset = readU64(data.data() + content + kOffsetField);
    entry.length = readU64(data.data() + content + kOffsetField + 8);
    out.push_back(entry);
  }
  return out;
}

std::optional<ChunkRefusal> scanChunks(Span<const std::uint8_t> data,
                                       const std::vector<std::uint64_t>& chunkOffsets) {
  Result<std::unique_ptr<Scene>> opened = Scene::openMemory(data, ReadMode::kAuto);
  if (!opened) return ChunkRefusal{opened.error(), std::nullopt};
  Scene& scene = **opened;

  const std::uint32_t chunks = scene.chunkCount();
  if (chunks == 0 || !scene.isIndexed()) {
    // Front to back: every chunk or none, and no per-chunk offset to attribute to. Band 0
    // throughout — spherical harmonics do not enter reconstructed state, so fetching them would
    // only move bytes nobody is checking.
    Result<void> loaded = scene.loadAll(0);
    if (!loaded) return ChunkRefusal{loaded.error(), std::nullopt};
    return std::nullopt;
  }
  for (std::uint32_t i = 0; i < chunks; ++i) {
    Result<void> loaded = scene.loadChunk(i, 0);
    if (loaded) continue;
    std::optional<Site> site;
    if (i < chunkOffsets.size()) {
      site = Site{chunkOffsets[i], "the Chunk record at index entry " + std::to_string(i)};
    }
    return ChunkRefusal{loaded.error(), site};
  }
  return std::nullopt;
}

std::optional<SummaryDeclaration> summaryDeclaration(Span<const std::uint8_t> data,
                                                     const Walk& walk) {
  const Frame* frame = walk.first(op::kFooter);
  if (frame == nullptr) return std::nullopt;
  // `summary_start`, `summary_offset_start`, `summary_crc` — twenty bytes, and the only record
  // this tool reads the content of. A Footer a later revision extends still parses: the fields
  // this needs are the first three and they do not move.
  constexpr std::uint64_t kFooterFields = 20;
  const std::uint64_t content = frame->offset + kRecordHeaderSize;
  if (frame->length < kFooterFields || content + kFooterFields > data.size()) return std::nullopt;
  const std::uint8_t* at = data.data() + content;
  SummaryDeclaration out;
  out.start = readU64(at);
  for (int i = 3; i >= 0; --i) out.crc = (out.crc << 8) | at[16 + i];
  // The summary ends where the Footer begins — taken from the walk rather than computed from a
  // footer's expected size, so a Footer that a later revision extends does not move the region
  // out from under the check.
  out.end = frame->offset;
  if (out.crc == 0 || out.start == 0) return std::nullopt;
  return out;
}

std::optional<Coverage> coverage(Span<const std::uint8_t> data, const Walk& walk) {
  std::optional<SummaryDeclaration> declared = summaryDeclaration(data, walk);
  if (!declared.has_value() || declared->start > declared->end) return std::nullopt;
  Coverage out;
  out.start = declared->start;
  out.end = declared->end;
  out.ok = crc32(data.data() + out.start, static_cast<std::size_t>(out.end - out.start)) ==
           declared->crc;
  return out;
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

Result<Walk> walkBytes(Span<const std::uint8_t> data) {
  BorrowedReadable source(data);
  return walk(source);
}

}  // namespace tool
}  // namespace fourdgs
