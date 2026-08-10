// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_TOOL_HPP
#define FOURDGS_TOOL_HPP

#include <cstdint>
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
constexpr std::uint8_t kChunkIndex = 0x08;
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

/// The result of walking a file's framing: every record, and the cut if there was one.
struct Walk {
  std::vector<Frame> records;
  std::optional<Cut> cut;
  /// True when the last eight bytes are the magic, as a whole file's are.
  bool trailingMagic = false;
  std::uint64_t size = 0;

  /// The first record with this opcode, or `nullptr`. Valid until `records` changes.
  const Frame* first(std::uint8_t opcode) const;

  /// How many of the reported records are whole.
  ///
  /// All of them, except when the file was cut inside one: that record is reported — hiding
  /// it would hide the declared length that is the whole fault — but it is not something a
  /// streamed reader keeps.
  std::size_t intact() const;
};

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap on a file
/// carrying an hour of audio as on one carrying none. The magic is checked first, because a
/// walk over bytes that are not ours would report whatever the first byte happened to mean as
/// an opcode — and when it fails, the core is asked to name the refusal so that the wording
/// and the identifier are the reader's rather than this tool's.
Result<Walk> walk(Readable& source);

/// The same, over bytes already in hand and without copying them.
Result<Walk> walkBytes(Span<const std::uint8_t> data);

/// A whole file, for the commands that need one.
///
/// `validate` does: the summary checksum has to cover a contiguous region to mean anything, and
/// the reader is handed the same bytes rather than a second transport that could disagree with
/// this walk. Cross-SDK principle 1 is about decode paths, and the decode this performs is
/// chunk by chunk.
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

/// The first chunk that refuses, decoded one chunk at a time.
///
/// Empty means every chunk decoded, which is the only evidence there is that a file's streams
/// are readable — the framing walk cannot produce it, because stepping over a chunk by its
/// declared length is exactly not looking inside it.
///
/// One chunk resident at a time on the indexed path (cross-SDK principle 1), which is what
/// keeps this bounded on a file too large to hold. A file with no index has no per-chunk
/// addressing to use, so it is decoded front to back and the refusal comes back without an
/// offset rather than with a guessed one.
std::optional<ChunkRefusal> scanChunks(Span<const std::uint8_t> data,
                                       const std::vector<std::uint64_t>& chunkOffsets);

/// One chunk index entry, in the two fields that are about where its chunk sits.
struct IndexEntry {
  std::uint64_t offset = 0;
  std::uint64_t length = 0;
};

/// What the file's own index says about where its chunks are, in index order.
///
/// Read from the Chunk Index records rather than from the Chunk records the walk found, because
/// "index entry 3" is what the reader was asked for and what it will name back — and because an
/// entry pointing somewhere there is no Chunk is one of the things a validator is for.
std::vector<IndexEntry> chunkIndexEntries(Span<const std::uint8_t> data, const Walk& walk);

/// What the Footer declares about the summary checksum, and where the summary ends.
struct SummaryDeclaration {
  /// First byte the checksum covers.
  std::uint64_t start = 0;
  std::uint32_t crc = 0;
  /// One past the last covered byte: where the Footer record's opcode sits.
  std::uint64_t end = 0;
};

/// Empty when the file has no Footer, or declares no summary checksum — which is a property of
/// the file rather than a failure, because writing one is an encoder option.
std::optional<SummaryDeclaration> summaryDeclaration(Span<const std::uint8_t> data,
                                                     const Walk& walk);

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

/// Empty when the file declares no summary checksum, which is a property of the file rather
/// than a failure: writing one is an encoder option.
std::optional<Coverage> coverage(Span<const std::uint8_t> data, const Walk& walk);

/// The cell for one record: `ok`, `MISMATCH`, or `-` for a record the checksum does not cover.
const char* coverageCell(const std::optional<Coverage>& coverage, std::uint64_t at,
                         std::uint64_t total);

/// CRC-32 (IEEE), the polynomial the Footer declares its summary under.
std::uint32_t crc32(const std::uint8_t* data, std::size_t length);

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

  bool ok() const;
  std::optional<Severity> worst() const;
};

/// Every check, over bytes already in hand.
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
