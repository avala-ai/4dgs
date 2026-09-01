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
/// the reader itself decides, which is where the seven named refusals live.
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
///   fault inside a chunk's streams is invisible to it; two invalid corpus files are exactly
///   that, and Python calls them clean.
/// * **It knows `keyframe-delta`.** Python reports a conforming keyframe-delta file as invalid,
///   because its structural checks assume the gaussian-birth chunk shape. The core implements
///   the model — the conformance suite proves it — so refusing a file for declaring it was never
///   a statement about the file.

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <new>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "backend.hpp"
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

Result<void> readExactly(Readable& source, std::uint64_t offset, std::uint8_t* into,
                         std::size_t length) {
  Result<std::size_t> got = source.read(offset, Span<std::uint8_t>(into, length));
  if (!got) return got.error();
  if (*got != length) {
    return Error(ErrorCode::kIo, "short range read at byte " + std::to_string(offset) +
                                     ": wanted " + std::to_string(length) + " bytes, got " +
                                     std::to_string(*got));
  }
  return Result<void>();
}

std::uint32_t readU32(const std::uint8_t* at) {
  std::uint32_t value = 0;
  for (int i = 3; i >= 0; --i) value = (value << 8) | at[i];
  return value;
}

std::uint64_t readU64(const std::uint8_t* at) {
  std::uint64_t value = 0;
  for (int i = 7; i >= 0; --i) value = (value << 8) | at[i];
  return value;
}

double readF64(const std::uint8_t* at) {
  const std::uint64_t bits = readU64(at);
  double value = 0.0;
  static_assert(sizeof(value) == sizeof(bits), "f64 and uint64 must have equal width");
  std::memcpy(&value, &bits, sizeof(value));
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
/// unimplemented temporal model, an unimplemented quantization scheme, or a non-positive
/// birth-time grid. Decoding the chunks is
/// where the rest do, and there is no substitute for it: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range window index are
/// both invisible to everything before this point. Both are in the invalid corpus.
void checkGaussianBirth(Readable& source, const Walk& walk, const std::vector<IndexEntry>& index,
                        const std::optional<SummaryDeclaration>& summary,
                        bool indexedCoreSupportsFooter, Report* report) {
  if (index.empty()) {
    incomplete(report,
               "chunk payload validation is incomplete: the file has no Chunk Index, and the "
               "C++ core has no bounded per-record sequential validation surface");
    return;
  }
  if (!indexedCoreSupportsFooter) {
    incomplete(report,
               "chunk payload validation is incomplete: the file extends the Footer beyond "
               "its version-1 prefix, which this indexed core cannot locate from a fixed tail");
    return;
  }
  if (!summaryFitsValidationMemory(summary)) {
    const std::uint64_t bytes = summary->end - summary->start;
    incomplete(report, "chunk payload validation is incomplete: the Footer declares a " +
                           commas(bytes) + "-byte summary, beyond the " +
                           commas(kMaxValidationSummaryBytes) +
                           "-byte validation limit; refusing to let the indexed core "
                           "materialize the untrusted range");
    return;
  }
  Result<std::unique_ptr<Scene>> opened = Scene::open(source, ReadMode::kIndexed);
  if (!opened) {
    if (opened.error().code == ErrorCode::kIo) {
      incomplete(report, "a seeking reader could not obtain the file: " + opened.error().message);
    } else {
      refused(report, "a seeking reader cannot open this file: ", opened.error(), &walk,
              std::nullopt);
    }
    // A file that will not open will not decode either, and the second error would say the same
    // thing about the same byte.
    return;
  }
  // Closed before the scan, so only one reader — and one chunk — is resident at a time.
  opened->reset();
  std::optional<ChunkRefusal> refusal = scanChunks(source, index);
  if (refusal.has_value()) {
    if (refusal->error.code == ErrorCode::kIo) {
      incomplete(report,
                 "chunk payload validation could not read the file: " + refusal->error.message);
    } else {
      refused(report, "a chunk does not decode: ", refusal->error, &walk, refusal->site);
    }
  }
}

/// Fixed-memory distinct-id counting for full-file validation.
///
/// The high nibble selects one of sixteen temporary files. Each is reduced through one
/// 2^28-bit bitmap (32 MiB) and discarded before the next is read, so memory never grows with
/// the number of state records or lifetime identities. Filesystem I/O stays here at the CLI edge.
class IdentityCounter {
 public:
  static Result<std::unique_ptr<IdentityCounter>> create() {
    std::error_code error;
    const std::filesystem::path base = std::filesystem::temp_directory_path(error);
    if (error)
      return Error(ErrorCode::kIo,
                   "cannot locate temporary storage for identity validation: " + error.message());
    const std::uint64_t stamp =
        static_cast<std::uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count());
    std::filesystem::path directory;
    for (std::uint32_t attempt = 0; attempt < 100; ++attempt) {
      const std::filesystem::path candidate =
          base / ("4dgs-validate-ids-" + std::to_string(stamp) + "-" + std::to_string(attempt));
      error.clear();
      if (std::filesystem::create_directory(candidate, error)) {
        directory = candidate;
        break;
      }
      if (error && error != std::errc::file_exists)
        return Error(ErrorCode::kIo,
                     "cannot create temporary identity storage: " + error.message());
    }
    if (directory.empty())
      return Error(ErrorCode::kIo, "cannot reserve unique temporary identity storage");
    std::unique_ptr<IdentityCounter> counter(new (std::nothrow) IdentityCounter(directory));
    if (!counter) {
      std::filesystem::remove_all(directory, error);
      return Error(ErrorCode::kInternal, "out of memory preparing bounded identity validation");
    }
    for (std::size_t bucket = 0; bucket < kBuckets; ++bucket) {
      counter->writers_[bucket].open(counter->path(bucket),
                                     std::ios::binary | std::ios::out | std::ios::trunc);
      if (!counter->writers_[bucket])
        return Error(ErrorCode::kIo,
                     "cannot open temporary identity partition " + std::to_string(bucket));
    }
    return counter;
  }

  ~IdentityCounter() {
    // On Windows an open file cannot be removed. Member destructors run only after this
    // destructor body, so close the partitions explicitly before removing their directory.
    // This path also covers setup failures and validation refusals that return before finish().
    for (std::ofstream& writer : writers_) writer.close();
    std::error_code ignored;
    std::filesystem::remove_all(directory_, ignored);
  }

  Result<void> add(std::uint64_t recordOffset, std::uint32_t id) {
    const std::size_t bucket = id >> kLowBits;
    nonempty_[bucket] = true;
    writers_[bucket].write(reinterpret_cast<const char*>(&id), sizeof(id));
    writers_[bucket].write(reinterpret_cast<const char*>(&recordOffset), sizeof(recordOffset));
    if (!writers_[bucket])
      return Error(ErrorCode::kIo,
                   "cannot write temporary identity partition " + std::to_string(bucket));
    return Result<void>();
  }

  Result<std::uint64_t> finish() {
    for (std::size_t bucket = 0; bucket < kBuckets; ++bucket) {
      std::ofstream& writer = writers_[bucket];
      writer.flush();
      if (!writer) return Error(ErrorCode::kIo, "cannot flush temporary identity storage");
      writer.close();
      Result<void> closed = checkIdentityPartitionClose(writer, bucket);
      if (!closed) return closed.error();
    }
    constexpr std::size_t kWordBits = 64;
    if (std::none_of(nonempty_.begin(), nonempty_.end(), [](bool value) { return value; }))
      return std::uint64_t{0};
    const std::size_t words = std::size_t{1} << (kLowBits - 6);
    std::unique_ptr<std::uint64_t[]> bits(new (std::nothrow) std::uint64_t[words]);
    if (!bits)
      return Error(ErrorCode::kInternal,
                   "out of memory allocating the fixed identity partition bitmap");
    std::uint64_t total = 0;
    for (std::size_t bucket = 0; bucket < kBuckets; ++bucket) {
      if (!nonempty_[bucket]) continue;
      std::fill_n(bits.get(), words, std::uint64_t{0});
      std::ifstream reader(path(bucket), std::ios::binary);
      if (!reader)
        return Error(ErrorCode::kIo,
                     "cannot read temporary identity partition " + std::to_string(bucket));
      for (;;) {
        std::uint32_t id = 0;
        std::uint64_t recordOffset = 0;
        reader.read(reinterpret_cast<char*>(&id), sizeof(id));
        if (reader.gcount() == 0 && reader.eof()) break;
        if (reader.gcount() != static_cast<std::streamsize>(sizeof(id)))
          return Error(ErrorCode::kIo, "temporary identity partition ended inside an id");
        reader.read(reinterpret_cast<char*>(&recordOffset), sizeof(recordOffset));
        if (reader.gcount() != static_cast<std::streamsize>(sizeof(recordOffset)))
          return Error(ErrorCode::kIo, "temporary identity partition ended inside an offset");
        const std::size_t low = id & ((std::uint32_t{1} << kLowBits) - 1);
        const std::uint64_t mask = std::uint64_t{1} << (low & (kWordBits - 1));
        std::uint64_t& word = bits[low >> 6];
        if ((word & mask) != 0)
          return Error(
              ErrorCode::kMalformed,
              "gaussian_id " + std::to_string(id) + " is introduced more than once at byte " +
                  std::to_string(recordOffset) +
                  " (the keyframe-delta record); an identity may not be reused after death");
        word |= mask;
      }
      for (std::size_t i = 0; i < words; ++i) {
        std::uint64_t word = bits[i];
        while (word != 0) {
          word &= word - 1;
          ++total;
        }
      }
    }
    return total;
  }

 private:
  static constexpr std::size_t kBuckets = 16;
  static constexpr std::size_t kLowBits = 28;

  explicit IdentityCounter(std::filesystem::path directory) : directory_(std::move(directory)) {}
  std::filesystem::path path(std::size_t bucket) const {
    return directory_ / std::to_string(bucket);
  }

  std::filesystem::path directory_;
  std::array<std::ofstream, kBuckets> writers_;
  std::array<bool, kBuckets> nonempty_{};
};

void checkKeyframeDeltaPath(Readable& source, const Walk& walk, ReadMode mode, const char* pathName,
                            Report* report) {
  Result<std::unique_ptr<IdentityCounter>> made = IdentityCounter::create();
  if (!made) {
    incomplete(report, "keyframe-delta " + std::string(pathName) +
                           " validation could not prepare bounded identity storage: " +
                           made.error().message);
    return;
  }
  std::unique_ptr<IdentityCounter> identities = std::move(*made);
  bool identitySinkFailed = false;
  std::optional<std::uint64_t> offset;
  Result<std::uint64_t> declared = detail::validateKeyframeDelta(
      source, static_cast<int>(mode),
      [&](std::uint64_t recordOffset, std::uint32_t id) {
        Result<void> added = identities->add(recordOffset, id);
        if (!added) identitySinkFailed = true;
        return added;
      },
      &offset);
  if (!declared) {
    if (declared.error().code == ErrorCode::kIo || declared.error().code == ErrorCode::kInternal ||
        declared.error().code == ErrorCode::kNotImplemented ||
        declared.error().code == ErrorCode::kUnsupportedMode) {
      reportKeyframeDeltaToolFailure(report, pathName, declared.error(), identitySinkFailed);
    } else {
      std::optional<Site> site;
      if (offset.has_value()) site = Site{*offset, "the keyframe-delta record"};
      const std::string prefix =
          "keyframe-delta " + std::string(pathName) + " validation refused this file: ";
      refused(report, prefix.c_str(), declared.error(), &walk, site);
    }
    return;
  }
  Result<std::uint64_t> distinct = identities->finish();
  if (!distinct) {
    if (distinct.error().code != ErrorCode::kMalformed) {
      incomplete(report, "keyframe-delta " + std::string(pathName) +
                             " identity validation could not use temporary storage: " +
                             distinct.error().message);
    } else {
      error(report, distinct.error().message);
    }
    return;
  }
  if (*distinct != *declared) {
    const Frame* header = walk.firstIntact(op::kHeader);
    const std::string site =
        header == nullptr ? std::string()
                          : " at byte " + std::to_string(header->offset) + " (the Header record)";
    error(report, "Header declares " + std::to_string(*declared) + " distinct gaussians" + site +
                      "; keyframes and birth groups introduce " + std::to_string(*distinct));
  }
}

void checkKeyframeDelta(Readable& source, const Walk& walk, bool hasIndex, Report* report) {
  checkKeyframeDeltaPath(source, walk, ReadMode::kSequential, "sequential", report);
  if (!report->complete || report->hasErrors()) return;
  if (hasIndex) checkKeyframeDeltaPath(source, walk, ReadMode::kIndexed, "indexed", report);
}

/// The Header's temporal model, range-parsed through its two variable-length prefixes.
///
/// A fixed head probe is unrelated to the wire format: `profile` and `library` are legal strings
/// of any framed length, so either can move `temporal_model` past such a probe. Only the model's
/// own bytes are read here; large preceding strings are skipped by their validated lengths.
Result<std::string> rangeParsedModel(Readable& source, const Walk& walk) {
  const Frame* header = walk.firstIntact(op::kHeader);
  if (header == nullptr) return std::string();
  const std::uint64_t start = header->offset + kRecordHeaderSize;
  const std::uint64_t limit = start + header->length;
  if (limit < start) return std::string();
  std::uint64_t at = start;
  auto skipString = [&]() -> Result<bool> {
    if (at > limit || limit - at < 4) return false;
    std::uint8_t lengthBytes[4];
    Result<void> read = readExactly(source, at, lengthBytes, sizeof(lengthBytes));
    if (!read) return read.error();
    const std::uint64_t length = readU32(lengthBytes);
    at += 4;
    if (at > limit || length > limit - at) return false;
    at += length;
    return true;
  };
  Result<bool> profile = skipString();
  if (!profile) return profile.error();
  if (!*profile) return std::string();
  Result<bool> library = skipString();
  if (!library) return library.error();
  if (!*library) return std::string();
  // duration_sec, gaussian_count, cutoff.
  constexpr std::uint64_t kFixedBeforeModel = 8 + 8 + 8;
  if (at > limit || kFixedBeforeModel > limit - at) return std::string();
  at += kFixedBeforeModel;
  if (at > limit || limit - at < 4) return std::string();
  std::uint8_t lengthBytes[4];
  Result<void> readLength = readExactly(source, at, lengthBytes, sizeof(lengthBytes));
  if (!readLength) return readLength.error();
  const std::uint64_t length = readU32(lengthBytes);
  at += 4;
  if (at > limit || length > limit - at) return std::string();
  constexpr char kKeyframeDelta[] = "keyframe-delta";
  constexpr char kGaussianBirth[] = "gaussian-birth";
  constexpr std::size_t kKeyframeDeltaLength = sizeof(kKeyframeDelta) - 1;
  static_assert(kKeyframeDeltaLength == sizeof(kGaussianBirth) - 1,
                "version-1 temporal model names have equal length");
  if (length != kKeyframeDeltaLength) return std::string("other");
  std::uint8_t model[kKeyframeDeltaLength];
  Result<void> readModel = readExactly(source, at, model, sizeof(model));
  if (!readModel) return readModel.error();
  bool keyframeDelta = true;
  bool gaussianBirth = true;
  for (std::size_t i = 0; i < kKeyframeDeltaLength; ++i) {
    keyframeDelta = keyframeDelta && model[i] == static_cast<std::uint8_t>(kKeyframeDelta[i]);
    gaussianBirth = gaussianBirth && model[i] == static_cast<std::uint8_t>(kGaussianBirth[i]);
  }
  if (keyframeDelta) return std::string(kKeyframeDelta);
  if (gaussianBirth) return std::string(kGaussianBirth);
  return std::string("other");
}

/// The Header's SH degree, reached through every variable-length field before it.
///
/// Empty means the Header is absent or structurally too short; the core names
/// that malformed Header later. Transport failures remain distinct so a failed
/// range read is never described as a missing declaration.
struct HeaderShape {
  std::uint8_t shDegree = 0;
  std::uint8_t flags = 0;
};

Result<std::optional<HeaderShape>> rangeParsedHeaderShape(Readable& source, const Walk& walk) {
  const Frame* header = walk.firstIntact(op::kHeader);
  if (header == nullptr) return std::optional<HeaderShape>();
  const std::uint64_t start = header->offset + kRecordHeaderSize;
  const std::uint64_t limit = start + header->length;
  if (limit < start) return std::optional<HeaderShape>();
  std::uint64_t at = start;
  auto skipString = [&]() -> Result<bool> {
    if (at > limit || limit - at < 4) return false;
    std::uint8_t lengthBytes[4];
    Result<void> read = readExactly(source, at, lengthBytes, sizeof(lengthBytes));
    if (!read) return read.error();
    const std::uint64_t length = readU32(lengthBytes);
    at += 4;
    if (at > limit || length > limit - at) return false;
    at += length;
    return true;
  };
  Result<bool> profile = skipString();
  if (!profile) return profile.error();
  if (!*profile) return std::optional<HeaderShape>();
  Result<bool> library = skipString();
  if (!library) return library.error();
  if (!*library) return std::optional<HeaderShape>();
  constexpr std::uint64_t kFixedBeforeModel = 8 + 8 + 8;
  if (at > limit || kFixedBeforeModel > limit - at) return std::optional<HeaderShape>();
  at += kFixedBeforeModel;
  Result<bool> model = skipString();
  if (!model) return model.error();
  if (!*model) return std::optional<HeaderShape>();
  constexpr std::uint64_t kAabbBytes = 6 * 8;
  if (at > limit || kAabbBytes + 2 > limit - at) return std::optional<HeaderShape>();
  at += kAabbBytes;
  std::uint8_t fields[2] = {0, 0};
  Result<void> read = readExactly(source, at, fields, sizeof(fields));
  if (!read) return read.error();
  return std::optional<HeaderShape>(HeaderShape{fields[0], fields[1]});
}

}  // namespace

void reportKeyframeDeltaToolFailure(Report* report, const char* pathName, const Error& failure,
                                    bool identitySinkFailed) {
  std::string operation;
  if (identitySinkFailed) {
    operation = " identity validation could not use temporary storage: ";
  } else {
    switch (failure.code) {
      case ErrorCode::kIo:
        operation = " validation could not read the file: ";
        break;
      case ErrorCode::kUnsupportedMode:
        operation = " validation reached a bounded tool limit: ";
        break;
      case ErrorCode::kNotImplemented:
        operation = " validation needs functionality this tool does not implement: ";
        break;
      case ErrorCode::kInternal:
        operation = " validation failed inside the tool: ";
        break;
      default:
        operation = " validation could not finish: ";
        break;
    }
  }
  incomplete(report, "keyframe-delta " + std::string(pathName) + operation + failure.message);
}

Result<void> checkIdentityPartitionClose(const std::ostream& writer, std::size_t bucket) {
  if (writer) return Result<void>();
  return Error(ErrorCode::kIo,
               "cannot close temporary identity partition " + std::to_string(bucket));
}

Result<std::string> temporalModel(Readable& source, const Walk& walk) {
  return rangeParsedModel(source, walk);
}

bool summaryFitsValidationMemory(const std::optional<SummaryDeclaration>& summary) {
  if (!summary.has_value() || summary->start == 0 || summary->start >= summary->end) return true;
  return summary->end - summary->start <= kMaxValidationSummaryBytes;
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
    if (sized.error().code == ErrorCode::kIo) {
      incomplete(&report, "cannot size the input resource: " + sized.error().message);
    } else {
      refused(&report, "", sized.error(), nullptr, std::nullopt);
    }
    return report;
  }
  const std::uint64_t size = *sized;

  // Framing first, and for two reasons: it refuses a file that is not ours before anything reads
  // a byte as an opcode, and it is what gives every later refusal a byte to point at.
  std::optional<Frame> undersizedIndex;
  std::optional<Frame> undersizedFooter;
  std::optional<Frame> firstStateRecord;
  std::optional<Frame> lateDecodeFrontMatter;
  std::optional<Frame> lateModernAudio;
  Result<Walk> walked = walk(source, [&](const Frame& frame, bool complete) {
    if (complete && frame.opcode == op::kChunkIndex && frame.length < 40 &&
        !undersizedIndex.has_value()) {
      undersizedIndex = frame;
    }
    if (complete && frame.opcode == op::kFooter && frame.length < 20 &&
        !undersizedFooter.has_value()) {
      undersizedFooter = frame;
    }
    if (!complete) return;
    const bool state = frame.opcode == op::kChunk || frame.opcode == op::kDeltaChunk;
    if (state && !firstStateRecord.has_value()) firstStateRecord = frame;
    if (firstStateRecord.has_value() && !lateDecodeFrontMatter.has_value() &&
        (frame.opcode == op::kQuantization || frame.opcode == op::kWindowTable)) {
      lateDecodeFrontMatter = frame;
    }
    if (firstStateRecord.has_value() && !lateModernAudio.has_value() &&
        (frame.opcode == op::kAudioSource || frame.opcode == op::kAudioData)) {
      lateModernAudio = frame;
    }
  });
  if (!walked) {
    if (walked.error().code == ErrorCode::kIo) {
      incomplete(&report, "cannot walk the input resource framing: " + walked.error().message);
    } else {
      refused(&report, "", walked.error(), nullptr, std::nullopt);
    }
    return report;
  }
  const Walk& walk = *walked;

  const bool endsWithMagic = walk.trailingMagic;
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
    if (opcode == op::kReservedZero) {
      error(&report, "the top-level record at byte " +
                         std::to_string(first == nullptr ? 0 : first->offset) +
                         " uses reserved opcode 0x00; section 4.3 says it is never emitted");
    } else if (opcode == op::kAttributeStream) {
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
  if (lateDecodeFrontMatter.has_value()) {
    error(&report, "the " + opcodeName(lateDecodeFrontMatter->opcode) + " record at byte " +
                       std::to_string(lateDecodeFrontMatter->offset) + " appears after the first " +
                       opcodeName(firstStateRecord->opcode) + " record at byte " +
                       std::to_string(firstStateRecord->offset) +
                       "; decode-affecting front matter must precede state records so streamed "
                       "and indexed reads use the same grids");
  }
  if (lateModernAudio.has_value()) {
    error(&report, "the " + opcodeName(lateModernAudio->opcode) + " record at byte " +
                       std::to_string(lateModernAudio->offset) + " appears after the first " +
                       opcodeName(firstStateRecord->opcode) + " record at byte " +
                       std::to_string(firstStateRecord->offset) +
                       "; Audio Source and Audio Data records must precede state records");
  }
  if (walk.intactOpcodeCounts[op::kFooter] > 1) {
    error(&report, "the file carries " + std::to_string(walk.intactOpcodeCounts[op::kFooter]) +
                       " Footer records; the Footer must be unique and final");
  }
  if (undersizedFooter.has_value()) {
    error(&report, "the Footer record at byte " + std::to_string(undersizedFooter->offset) +
                       " declares " + std::to_string(undersizedFooter->length) +
                       " content bytes; the fixed version-1 prefix requires at least 20");
  }
  if (walk.intactOpcodeCounts[op::kHeader] > 1) {
    error(&report, "the file carries " + std::to_string(walk.intactOpcodeCounts[op::kHeader]) +
                       " Header records; the Header must be unique and first");
    return report;
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
  Result<std::string> model = temporalModel(source, walk);
  if (!model) {
    incomplete(&report, "cannot range-read the Header temporal_model: " + model.error().message);
    return report;
  }
  if (*model != "gaussian-birth" && *model != "keyframe-delta") {
    const Error unknown(
        ErrorCode::kUnsupported,
        "unknown temporal model '" + *model + "' (expected 'gaussian-birth' or 'keyframe-delta')",
        std::string("unknown-temporal-model"));
    refused(&report, "the Header is not supported: ", unknown, &walk, std::nullopt);
    return report;
  }
  const bool keyframeDelta = *model == "keyframe-delta";
  Result<std::optional<HeaderShape>> parsedHeaderShape = rangeParsedHeaderShape(source, walk);
  if (!parsedHeaderShape) {
    incomplete(&report, "cannot range-read the Header sh_degree and flags: " +
                            parsedHeaderShape.error().message);
    return report;
  }
  const HeaderShape* headerShape =
      parsedHeaderShape->has_value() ? &parsedHeaderShape->value() : nullptr;
  if (headerShape != nullptr && (headerShape->flags & 0xFC) != 0) {
    error(&report, "Header flags is " + hex2(headerShape->flags) +
                       "; bits 2-7 are reserved and MUST be 0 (section 5.1)");
  }

  Result<std::vector<IndexEntry>> parsedIndex = chunkIndexEntries(source, walk);
  if (!parsedIndex) {
    incomplete(&report, "cannot range-read the Chunk Index: " + parsedIndex.error().message);
    return report;
  }
  const std::vector<IndexEntry> index = *parsedIndex;
  const std::uint64_t physicalIndexCount = walk.intactOpcodeCounts[op::kChunkIndex];
  if (undersizedIndex.has_value()) {
    error(&report, "the Chunk Index record at byte " + std::to_string(undersizedIndex->offset) +
                       " declares " + std::to_string(undersizedIndex->length) +
                       " content bytes; the fixed version-1 prefix requires at least 40");
  }
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
    std::optional<std::uint64_t> physicalOwner;
  };
  std::vector<IndexedBand> indexedBands;
  std::unordered_map<std::uint64_t, std::vector<std::size_t>> wantedBands;
  for (std::size_t i = 0; i < index.size(); ++i) {
    wanted[index[i].offset].push_back(i);
    if (index[i].declaredBandCount > 3) {
      error(&report, "chunk index entry " + std::to_string(i) + " declares " +
                         std::to_string(index[i].declaredBandCount) +
                         " SH band ranges; version 1 defines at most 3");
    }
    if (!indexedChunkOffsets.insert(index[i].offset).second) {
      error(&report, "chunk index entry " + std::to_string(i) + " duplicates physical chunk " +
                         std::to_string(index[i].offset) +
                         "; each state record must have exactly one index entry");
    }
    std::unordered_set<std::uint8_t> entryBands;
    for (const BandRange& range : index[i].bands) {
      if (range.band < 1 || (headerShape != nullptr && range.band > headerShape->shDegree)) {
        error(&report,
              "chunk index entry " + std::to_string(i) + " declares SH band " +
                  std::to_string(range.band) + "; expected a band in 1 through Header " +
                  "sh_degree " +
                  (headerShape != nullptr ? std::to_string(headerShape->shDegree) : "unknown"));
      }
      if (!entryBands.insert(range.band).second) {
        error(&report, "chunk index entry " + std::to_string(i) + " declares SH band " +
                           std::to_string(range.band) +
                           " more than once; each band has exactly one range per state record");
      }
      const std::size_t at = indexedBands.size();
      indexedBands.push_back(IndexedBand{i, range, std::nullopt, std::nullopt});
      wantedBands[range.offset].push_back(at);
      indexedBandOffsets.insert(range.offset);
    }
    if (headerShape != nullptr) {
      for (std::uint16_t band = 1; band <= headerShape->shDegree; ++band) {
        if (entryBands.find(static_cast<std::uint8_t>(band)) == entryBands.end()) {
          error(&report, "chunk index entry " + std::to_string(i) + " omits SH band " +
                             std::to_string(band) + "; Header sh_degree " +
                             std::to_string(headerShape->shDegree) +
                             " requires every band 1 through " +
                             std::to_string(headerShape->shDegree));
        }
      }
    }
  }
  std::optional<Frame> firstUnindexedState;
  std::optional<Frame> firstUnindexedBand;
  std::optional<std::uint64_t> firstUnindexedBandOwner;
  std::optional<Frame> firstGaussianBirthDelta;
  std::optional<std::uint64_t> physicalStateOwner;
  Result<Walk> resolvedIndex = fourdgs::tool::walk(source, [&](const Frame& frame, bool complete) {
    if (!complete) return;
    const auto found = wanted.find(frame.offset);
    if (found != wanted.end()) {
      for (std::size_t i : found->second) physical[i] = frame;
    }
    const auto foundBands = wantedBands.find(frame.offset);
    if (foundBands != wantedBands.end()) {
      for (std::size_t i : foundBands->second) {
        indexedBands[i].physical = frame;
        indexedBands[i].physicalOwner = physicalStateOwner;
      }
    }
    const bool state = frame.opcode == op::kChunk || frame.opcode == op::kDeltaChunk;
    if (state) {
      physicalStateOwner = frame.offset;
    } else if (frame.opcode != op::kShBandStream &&
               !(!isSpecified(frame.opcode) && frame.opcode != op::kReservedZero &&
                 frame.opcode != op::kAttachmentIndex)) {
      physicalStateOwner.reset();
    }
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
  if (!resolvedIndex) {
    incomplete(&report, "cannot resolve indexed ranges against the physical record walk: " +
                            resolvedIndex.error().message);
    return report;
  }
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
      error(
          &report,
          "chunk index entry " + std::to_string(i) + " does not point at the start of a " +
              (keyframeDelta ? "top-level Chunk or Delta Chunk record" : "top-level Chunk record"));
    } else if (physical[i]->total() != entry.length) {
      error(&report, "chunk index entry " + std::to_string(i) + " declares " +
                         std::to_string(entry.length) + " bytes at " +
                         std::to_string(entry.offset) + "; the record there is " +
                         std::to_string(physical[i]->total()) + " bytes");
    }
    if (!overflows && physical[i].has_value() && physical[i]->opcode == op::kChunk &&
        physical[i]->total() == entry.length) {
      constexpr std::size_t kChunkPrefix = 8 + 8 + 4 + 4;
      if (physical[i]->length < kChunkPrefix) {
        error(&report, "the Chunk at byte " + std::to_string(entry.offset) + " declares " +
                           std::to_string(physical[i]->length) +
                           " content bytes; its fixed header requires 24");
      } else {
        std::uint8_t prefix[kChunkPrefix];
        Result<void> read =
            readExactly(source, entry.offset + kRecordHeaderSize, prefix, sizeof(prefix));
        if (!read) {
          incomplete(&report, "cannot range-read the Chunk header at byte " +
                                  std::to_string(entry.offset) + ": " + read.error().message);
          return report;
        }
        const double chunkT0 = readF64(prefix);
        const double chunkT1 = readF64(prefix + 8);
        const std::uint32_t chunkCount = readU32(prefix + 20);
        if (chunkT0 != entry.t0 || chunkT1 != entry.t1) {
          error(&report, "chunk index entry " + std::to_string(i) + " declares interval [" +
                             std::to_string(entry.t0) + ", " + std::to_string(entry.t1) +
                             "); the Chunk at byte " + std::to_string(entry.offset) +
                             " declares [" + std::to_string(chunkT0) + ", " +
                             std::to_string(chunkT1) + ")");
        }
        if (chunkCount != entry.gaussianCount) {
          error(&report, "chunk index entry " + std::to_string(i) + " declares " +
                             std::to_string(entry.gaussianCount) +
                             " gaussians; the Chunk at byte " + std::to_string(entry.offset) +
                             " declares " + std::to_string(chunkCount));
        }
      }
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
    } else {
      if (!band.physicalOwner.has_value() || *band.physicalOwner != index[band.entry].offset) {
        error(&report, "SH band " + std::to_string(band.range.band) + " at index entry " +
                           std::to_string(band.entry) + " points at byte " +
                           std::to_string(band.range.offset) +
                           ", which does not belong to its preceding state record at byte " +
                           std::to_string(index[band.entry].offset));
      }
      if (band.physical->length < 1) {
        error(&report, "the SH Band Stream at byte " + std::to_string(band.range.offset) +
                           " declares 0 content bytes; its band label requires at least 1");
      } else {
        std::uint8_t declaredBand = 0;
        Result<void> read = readExactly(source, band.range.offset + kRecordHeaderSize,
                                        &declaredBand, sizeof(declaredBand));
        if (!read) {
          incomplete(&report, "cannot range-read the SH Band Stream at byte " +
                                  std::to_string(band.range.offset) + ": " + read.error().message);
          return report;
        }
        if (declaredBand != band.range.band) {
          error(&report, "SH band " + std::to_string(band.range.band) + " at index entry " +
                             std::to_string(band.entry) + " points at byte " +
                             std::to_string(band.range.offset) + ", whose record declares band " +
                             std::to_string(declaredBand));
        }
      }
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

  Result<std::optional<SummaryDeclaration>> declaredSummary = summaryDeclaration(source, walk);
  if (!declaredSummary) {
    incomplete(&report,
               "the Footer declaration could not be read: " + declaredSummary.error().message);
    return report;
  }
  std::optional<SummaryDeclaration> summary = *declaredSummary;
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
    checkKeyframeDelta(source, walk, physicalIndexCount > 0, &report);
  } else {
    const bool indexedCoreSupportsFooter = !walk.lastIntactRecord.has_value() ||
                                           walk.lastIntactRecord->opcode != op::kFooter ||
                                           walk.lastIntactRecord->length == 20;
    checkGaussianBirth(source, walk, index, summary, indexedCoreSupportsFooter, &report);
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
