// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_TOOL_HPP
#define FOURDGS_TOOL_HPP

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <ostream>
#include <string>
#include <vector>

#include "fourdgs/fourdgs.hpp"

/// `4dgs`: walk a file's records, and say why one is refused.
///
/// Thin over the binding, which is thin over the core: everything this tool decides about a
/// file's contents is decided by the reader, and everything it decides about a file's framing
/// is nine bytes per record. It is deliberately not a second implementation of the format —
/// the one thing a diagnostic tool must never be is a decoder that disagrees with the
/// decoder.
namespace fourdgs {
namespace tool {

/// Exit codes, which are the only part of a command-line tool another program reads.
///
/// `kExitFailed` and `kExitTool` are the split that matters. `1` is an answer about the file:
/// it was read, and it is bad. `3` is the absence of an answer — no such file, an argument
/// this tool does not understand — and a pipeline that saw `1` for both could not tell a
/// corrupt asset from a typo in a path. A tool that exits 1 for both is indistinguishable
/// from a broken one.
constexpr int kExitOk = 0;
constexpr int kExitFailed = 1;
constexpr int kExitWarnings = 2;
constexpr int kExitTool = 3;

/// The eight bytes a 4dgs file opens and closes with (spec §5.1).
extern const std::uint8_t kMagic[8];
constexpr std::uint64_t kMagicSize = 8;
/// `u8` opcode plus `u64` content length.
constexpr std::uint64_t kRecordHeaderSize = 9;
/// A fixed ceiling for the small summary index retained by validation.
constexpr std::size_t kMaxChunkIndexEntries = 262144;

/// The record opcodes this tool names by hand, spec §5.2.
///
/// Only the ones it reasons about: the front matter a refusal is placed against, the two chunk
/// kinds, the index and the two open ranges. The wire numbers are the one part of the format
/// that never moves, and a tool that walks framing has to know them to walk anything.
namespace op {
constexpr std::uint8_t kHeader = 0x01;
constexpr std::uint8_t kFooter = 0x02;
constexpr std::uint8_t kQuantization = 0x03;
constexpr std::uint8_t kChunk = 0x05;
/// Attribute Stream has a registry number for use inside Chunk, but is never a wire record.
constexpr std::uint8_t kAttributeStream = 0x06;
constexpr std::uint8_t kShBandStream = 0x07;
constexpr std::uint8_t kChunkIndex = 0x08;
constexpr std::uint8_t kStatistics = 0x0C;
/// Reserved Attachment Index: the format assigns the number but no body.
constexpr std::uint8_t kAttachmentIndex = 0x0E;
constexpr std::uint8_t kSummaryOffset = 0x0F;
/// A keyframe-delta file's delta chunks. Deliberately not a flag on Chunk: a Chunk is
/// independently decodable and a Delta Chunk is exactly the record that is not.
constexpr std::uint8_t kDeltaChunk = 0x10;
constexpr std::uint8_t kAudioData = 0x12;
constexpr std::uint8_t kCoordinateFrame = 0x20;
constexpr std::uint8_t kObjectTrack = 0x25;
/// One past the provenance family's last reserved opcode.
constexpr std::uint8_t kProvenanceEnd = 0x30;
/// First opcode of the application range, which this specification never defines.
constexpr std::uint8_t kPrivateStart = 0x80;
}  // namespace op

/// A human name for an opcode, in the vocabulary of `concepts.md`. `Unknown(0xNN)` and
/// `Private(0xNN)` for the two ranges this specification leaves open.
std::string opcodeName(std::uint8_t opcode);
/// The application range `0x80`-`0xFF`, which the specification never defines.
bool isPrivate(std::uint8_t opcode);
/// The provenance family `0x20`-`0x2F`, defined and reserved alike.
bool isProvenance(std::uint8_t opcode);
/// True for the opcodes the specification defines. Everything else is either the application
/// range or a record from a revision this build does not implement, and both are skipped
/// rather than refused.
bool isSpecified(std::uint8_t opcode);

/// One record's framing: what it is, where it starts, how long its content is.
struct Frame {
  std::uint8_t opcode = 0;
  /// Offset of the opcode byte.
  std::uint64_t offset = 0;
  /// Content length, as the record declares it.
  std::uint64_t length = 0;

  /// Framing plus content, which is what an offset has to advance by.
  ///
  /// Saturating: the length is eight bytes off an untrusted file, so a record can declare
  /// `UINT64_MAX` and this is where that would wrap. Saturating produces a total that runs
  /// past the end of any file, which is exactly what the walk then reports.
  std::uint64_t total() const;
};

/// Where a framing walk stopped, when it did not reach the end.
struct Cut {
  /// The first byte the walk could not account for.
  std::uint64_t at = 0;
  std::string reason;
  /// True when the cut is inside a record whose framing was read — so the last record the
  /// walk reports is the incomplete one, and everything before it is intact.
  bool insideARecord = false;
};

/// Called as each record frame is found. `complete` is false only for the final frame when its
/// declared content runs past the resource.
using FrameVisitor = std::function<void(const Frame&, bool complete)>;

/// The result of walking a file's framing: bounded facts about the records, and any cut.
struct Walk {
  /// At most the first two records of each opcode. Two are enough to place a unique
  /// front-matter refusal or prove that placement ambiguous; retaining every private record
  /// would make a framing walk use memory proportional to an untrusted record count.
  std::vector<Frame> representatives;
  std::array<std::uint64_t, 256> opcodeCounts{};
  std::array<std::uint64_t, 256> intactOpcodeCounts{};
  std::uint64_t recordCount = 0;
  std::uint64_t intactRecordCount = 0;
  std::optional<Frame> firstRecord;
  std::optional<Frame> lastRecord;
  std::optional<Frame> firstIntactRecord;
  std::optional<Frame> lastIntactRecord;
  std::optional<Cut> cut;
  /// True when the last eight bytes are the magic, as a whole file's are.
  bool trailingMagic = false;
  std::uint64_t size = 0;

  /// The first record with this opcode, or `nullptr`.
  const Frame* first(std::uint8_t opcode) const;
  /// The first complete record with this opcode, or `nullptr`.
  const Frame* firstIntact(std::uint8_t opcode) const;

  /// How many of the reported records are whole.
  ///
  /// All of them, except when the file was cut inside one: that record is reported — hiding
  /// it would hide the declared length that is the whole fault — but it is not something a
  /// streamed reader keeps.
  std::uint64_t intact() const;
};

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap on a file
/// carrying an hour of audio as on one carrying none. The magic is checked first, because a
/// walk over bytes that are not ours would report whatever the first byte happened to mean as
/// an opcode — and when it fails, the core is asked to name the refusal so that the wording
/// and the identifier are the reader's rather than this tool's.
Result<Walk> walk(Readable& source, const FrameVisitor& visitor = FrameVisitor());

/// The same, over bytes already in hand and without copying them.
Result<Walk> walkBytes(Span<const std::uint8_t> data, const FrameVisitor& visitor = FrameVisitor());

/// A `Readable` over bytes the caller already holds, without copying them.
///
/// `MemoryReadable` takes ownership of a copy, which is the right shape for a test fixture and
/// the wrong one for bytes that are already in hand. Everything in this tool that used to take a
/// `Span` takes a `Readable&`, so this is how a caller with bytes reaches it.
class BorrowedReadable : public Readable {
 public:
  explicit BorrowedReadable(Span<const std::uint8_t> bytes) : bytes_(bytes) {}

  Result<std::uint64_t> size() override;
  Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override;

 private:
  Span<const std::uint8_t> bytes_;
};

/// Convenience for small test fixtures and callers that explicitly request owned bytes.
/// Validation and inspection never use it; both operate on `Readable` ranges.
Result<std::vector<std::uint8_t>> readWhole(const std::string& path);

/// The byte a refusal fired at, and what sits there.
struct Site {
  std::uint64_t offset = 0;
  /// What the offset points at, in the vocabulary of `concepts.md`.
  std::string what;
};

/// A refusal with a name, and where it is if the tool could place it.
struct Named {
  /// The identifier the specification and the conformance corpus use.
  std::string code;
  std::optional<Site> site;

  /// `refusal unknown-temporal-model at byte 8 (the Header record)`.
  std::string toString() const;
};

/// Everything the tool can say about one refusal: the identifier and the byte.
///
/// Empty for an error the refusal table does not name — a truncated transport, a null
/// argument. That is not a failure of this function; it is the library saying "this is not one
/// of the refusals the corpus compares", and a tool that invented an identifier there would be
/// inventing conformance.
std::optional<Named> describe(const Error& error, const Walk* walk,
                              const std::optional<Site>& site);

/// A refusal raised while decoding chunks, with the chunk it came from.
struct ChunkRefusal {
  Error error;
  std::optional<Site> site;
};

/// Where one band's stream record sits, as the chunk index entry declares it.
struct BandRange {
  int band = 0;
  std::uint64_t offset = 0;
  std::uint64_t length = 0;
};

/// One chunk index entry: where its chunk sits, and where each of its bands does.
struct IndexEntry {
  std::uint64_t offset = 0;
  std::uint64_t length = 0;
  /// Band 1 upwards, in the order the entry lists them. Empty for a file with no spherical
  /// harmonics, and for one whose encoder wrote none — both of which are ordinary.
  std::vector<BandRange> bands;

  /// The record for `band`, or `nullptr`.
  const BandRange* bandRange(int band) const;
};

/// The first chunk that refuses, decoded one chunk at a time.
///
/// Empty means every chunk decoded, which is the only evidence there is that a file's streams
/// are readable — the framing walk cannot produce it, because stepping over a chunk by its
/// declared length is exactly not looking inside it.
///
/// **Every band the file declares, not band 0.** Each spherical-harmonic band is its own record
/// with its own stream header, addressed by byte range so that a reader which has capped its
/// degree never transfers the higher ones. That is exactly what makes them invisible to a
/// validator: a scan at band 0 fetches none of them, and a file whose band 2 will not decode
/// comes back `valid`, exit 0. This is #168's finding, and the cap here is the file's own
/// declared degree so that what gets decoded is what the file claims to carry.
///
/// One chunk resident at a time on the indexed path (cross-SDK principle 1), which is what
/// keeps this bounded on a file too large to hold. A file with no index has no bounded
/// per-chunk surface in the C++ core, so validation reports that check as incomplete.
///
/// The scene is opened over `source` rather than over a buffer: `fourdgs_open_memory` copies the
/// bytes it is given, so handing it a whole file would cost a second copy of that file before the
/// first chunk was decoded.
std::optional<ChunkRefusal> scanChunks(Readable& source, const std::vector<IndexEntry>& index);

/// What the file's own index says about where its chunks are, in index order.
///
/// Read from the Chunk Index records rather than from the Chunk records the walk found, because
/// "index entry 3" is what the reader was asked for and what it will name back — and because an
/// entry pointing somewhere there is no Chunk is one of the things a validator is for.
///
/// Forty bytes per index record plus seventeen per band it declares, read where the walk says
/// that record is, and bounded by the record's own declared length rather than by its band count.
std::vector<IndexEntry> chunkIndexEntries(Readable& source, const Walk& walk);

/// The Header's temporal model, range-parsed through its length-framed profile and library.
/// Empty when the Header is absent or malformed.
std::string temporalModel(Readable& source, const Walk& walk);

/// What the Footer declares about the summary checksum, and where the summary ends.
struct SummaryDeclaration {
  /// First byte the checksum covers.
  std::uint64_t start = 0;
  /// First Summary Offset record, or zero when that group is absent.
  std::uint64_t offsetStart = 0;
  std::uint32_t crc = 0;
  /// One past the last covered byte: where the Footer record's opcode sits.
  std::uint64_t end = 0;
};

/// Empty only when a complete Footer cannot be read. A zero checksum remains in the declaration,
/// because summary placement is normative independently of checksum presence.
std::optional<SummaryDeclaration> summaryDeclaration(Readable& source, const Walk& walk);

/// The region the Footer's summary checksum covers, and whether it agrees.
///
/// The only checksum the format defines is `summary_crc` over the bytes from `summary_start`
/// to where the Footer begins. So a record's "CRC status" is a fact about the region it sits
/// in rather than a field of its own, and saying so per record is what tells a reader whether
/// the checksum has anything to say about the record they are looking at.
struct Coverage {
  std::uint64_t start = 0;
  /// One past the last covered byte: where the Footer record's opcode sits.
  std::uint64_t end = 0;
  bool ok = false;
};

/// A successful empty value means the file declares no checksum. An error means the declared
/// range could not be read, which callers must not describe as checksum absence.
///
/// The checksum is accumulated over the covered range through a fixed buffer, so a summary that
/// spans most of a large file costs that buffer and not the range.
Result<std::optional<Coverage>> coverage(Readable& source, const Walk& walk);

/// The cell for one record: `ok`, `MISMATCH`, or `-` for a record the checksum does not cover.
const char* coverageCell(const std::optional<Coverage>& coverage, std::uint64_t at,
                         std::uint64_t total);

/// CRC-32 (IEEE), the polynomial the Footer declares its summary under.
std::uint32_t crc32(const std::uint8_t* data, std::size_t length);

/// The same, over a byte range of `source`, a buffer at a time.
///
/// A file that shrank under the walk or a transport failure is returned as an error carrying the
/// failed byte range; it is never collapsed into checksum absence.
Result<std::uint32_t> crc32Range(Readable& source, std::uint64_t start, std::uint64_t end);

/// A count with thousands separators, matching the Python tool's `{:,}`.
std::string commas(std::uint64_t value);

enum class Severity { kNote, kWarning, kError };

/// `note`, `warning`, `error` — the prefix a finding is printed under.
const char* severityName(Severity severity);

/// One thing wrong with a file, and — when the library named it — which refusal it is.
struct Finding {
  Severity severity = Severity::kNote;
  /// Word for word what the Python validator prints for the same bytes.
  std::string message;
  /// The refusal identifier and the byte it fired at, for the findings that have one. Most do
  /// not: "first record is Footer; the Header must come first" is a rule this validator checks
  /// itself, not a refusal the reader raised, and the refusal table does not name it.
  std::optional<Named> refusal;
};

struct Report {
  std::vector<Finding> findings;
  /// False when a bounded implementation cannot finish a check with the available core API.
  /// This is not a verdict against the file, and the CLI reports it as a tool failure rather
  /// than printing `valid` or `INVALID`.
  bool complete = true;

  bool hasErrors() const;
  bool ok() const;
  std::optional<Severity> worst() const;
};

/// Every check, reading ranges of `source`.
Report validate(Readable& source);

/// The same, over bytes already in hand.
Report validate(Span<const std::uint8_t> data);

/// `4dgs validate <file>` — check a file against the specification.
int runValidate(const std::string& path, std::ostream& out, std::ostream& err);

/// `4dgs inspect <file> [--json]` — walk the records: offset, opcode, length, CRC status.
int runInspect(const std::string& path, bool json, std::ostream& out, std::ostream& err);

/// Parse the arguments and run the command. Returns the process's exit code.
int run(const std::vector<std::string>& argv, std::ostream& out, std::ostream& err);

/// The usage text, which is also where the exit codes are documented.
extern const char* const kUsage;

}  // namespace tool
}  // namespace fourdgs

#endif  // FOURDGS_TOOL_HPP
