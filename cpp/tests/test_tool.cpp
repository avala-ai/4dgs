// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The `4dgs` tool, over the corpus that already knows the answers.
///
/// The invalid corpus is seven files, each with a `.json` beside it naming the rule it breaks.
/// That mapping is not restated here: it is read out of the corpus, so this suite cannot drift
/// into agreeing with a stale copy of itself, and a corpus that grows an eighth variant fails
/// this suite until the tool has an answer for it.
///
/// The tool is driven through `fourdgs::tool::run` with argument strings and a pair of streams,
/// which is the whole tool including its exit codes — no subprocess, so this behaves the same on
/// Windows as on Linux.

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "check.hpp"
#include "fourdgs/writer.hpp"
#include "tool.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::Span;
using fourdgs::tool::Named;
using fourdgs::tool::Report;
using fourdgs::tool::Severity;
using fourdgs::tool::Site;
using fourdgs::tool::Walk;

#ifndef FOURDGS_CORPUS_DIR
#define FOURDGS_CORPUS_DIR "tests/conformance/data"
#endif

/// Every `.4dgs` in a corpus directory, sorted so a failure names the same file twice running.
std::vector<std::filesystem::path> variants(const std::filesystem::path& directory);

std::filesystem::path corpusDirectory() {
  const char* fromEnvironment = std::getenv("FOURDGS_CORPUS");
  if (fromEnvironment != nullptr) return std::filesystem::path(fromEnvironment);
  return std::filesystem::path(FOURDGS_CORPUS_DIR);
}

/// True when the corpus is not on disk.
///
/// The corpus is generated rather than committed, so a developer who has not run the generator
/// gets skipped checks instead of failures — but CI generates it before this suite runs, and
/// there a missing corpus is a suite that silently did not run.
bool corpusMissing() {
  // The generated files, not the directory that holds them. `tests/conformance/data/invalid/` is
  // tracked — the seven `.json` expectations are committed and only the `.4dgs` beside each one
  // is generated — so a check for the directory answers "present" in a checkout where the
  // generator has never run. This suite then ran against files that were not there and failed,
  // which is the opposite of the local skip the paragraph above promises; it also made the skip
  // untestable, because nothing could make it fire.
  const bool generated =
      !variants(corpusDirectory()).empty() && !variants(corpusDirectory() / "invalid").empty();
  if (generated) return false;
  CHECK(std::getenv("CI") == nullptr);
  return true;
}

/// True when this build has no decoder behind it.
///
/// Both configurations ship, and the no-core one is what an integrator gets before they have
/// built the crate. `validate` refuses to answer there — see `runValidate` — so the checks that
/// are about what the reader decides have nothing to check, while the framing walk, the opcode
/// names and `inspect` are the tool's own code and run either way.
bool noDecoder() { return !fourdgs::backendAvailable(); }

/// One run of the tool: what it printed, and what it exited with.
struct Run {
  int code = 0;
  std::string out;
  std::string err;

  bool outContains(const std::string& needle) const {
    return out.find(needle) != std::string::npos;
  }
};

Run run(const std::vector<std::string>& argv) {
  std::ostringstream out;
  std::ostringstream err;
  Run result;
  result.code = fourdgs::tool::run(argv, out, err);
  result.out = out.str();
  result.err = err.str();
  return result;
}

std::vector<std::uint8_t> readBytes(const std::filesystem::path& path) {
  fourdgs::Result<std::vector<std::uint8_t>> data = fourdgs::tool::readWhole(path.string());
  if (!data) return {};
  return *data;
}

void appendU32(std::vector<std::uint8_t>* out, std::uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<std::uint8_t>(value >> (8 * i)));
}

void appendU64(std::vector<std::uint8_t>* out, std::uint64_t value) {
  for (int i = 0; i < 8; ++i) out->push_back(static_cast<std::uint8_t>(value >> (8 * i)));
}

std::uint64_t readU64(const std::vector<std::uint8_t>& bytes, std::size_t at) {
  std::uint64_t value = 0;
  for (int i = 7; i >= 0; --i) value = (value << 8) | bytes[at + static_cast<std::size_t>(i)];
  return value;
}

std::uint32_t readU32(const std::vector<std::uint8_t>& bytes, std::size_t at) {
  std::uint32_t value = 0;
  for (int i = 3; i >= 0; --i) value = (value << 8) | bytes[at + static_cast<std::size_t>(i)];
  return value;
}

void writeU64(std::vector<std::uint8_t>* bytes, std::size_t at, std::uint64_t value) {
  for (int i = 0; i < 8; ++i)
    (*bytes)[at + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(value >> (8 * i));
}

void writeU32(std::vector<std::uint8_t>* bytes, std::size_t at, std::uint32_t value) {
  for (int i = 0; i < 4; ++i)
    (*bytes)[at + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(value >> (8 * i));
}

void resealSummary(std::vector<std::uint8_t>* bytes) {
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes->data(), bytes->size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr) return;
  const std::size_t content =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize);
  const std::uint64_t start = readU64(*bytes, content);
  CHECK(start <= footer->offset);
  if (start > footer->offset) return;
  const std::uint32_t crc = fourdgs::tool::crc32(bytes->data() + static_cast<std::size_t>(start),
                                                 static_cast<std::size_t>(footer->offset - start));
  writeU32(bytes, content + 16, crc);
}

/// Insert a complete top-level record and keep every file-relative index and
/// Footer pointer aimed at the same logical record as before.
bool insertTopLevelRecord(std::vector<std::uint8_t>* bytes, std::uint64_t at,
                          const std::vector<std::uint8_t>& record) {
  std::vector<fourdgs::tool::Frame> indexes;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes->data(), bytes->size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                   indexes.push_back(frame);
                               });
  CHECK(walked.ok());
  if (!walked) return false;
  fourdgs::tool::BorrowedReadable source(Span<const std::uint8_t>(bytes->data(), bytes->size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> parsed =
      fourdgs::tool::chunkIndexEntries(source, *walked);
  CHECK(parsed.ok());
  if (!parsed || parsed->size() != indexes.size()) return false;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr) return false;
  const std::size_t oldFooterContent =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize);
  const std::uint64_t oldSummaryStart = readU64(*bytes, oldFooterContent);
  const std::uint64_t oldSummaryOffsetStart = readU64(*bytes, oldFooterContent + 8);

  bytes->insert(bytes->begin() + static_cast<std::ptrdiff_t>(at), record.begin(), record.end());
  const std::uint64_t added = record.size();
  const auto shifted = [&](std::uint64_t value) { return value >= at ? value + added : value; };
  for (std::size_t i = 0; i < indexes.size(); ++i) {
    const std::size_t content =
        static_cast<std::size_t>(shifted(indexes[i].offset) + fourdgs::tool::kRecordHeaderSize);
    writeU64(bytes, content + 16, shifted((*parsed)[i].offset));
    for (std::size_t band = 0; band < (*parsed)[i].bands.size(); ++band) {
      const std::size_t range = content + 40 + band * 17;
      writeU64(bytes, range + 1, shifted((*parsed)[i].bands[band].offset));
    }
  }
  const std::size_t footerContent =
      static_cast<std::size_t>(shifted(footer->offset) + fourdgs::tool::kRecordHeaderSize);
  writeU64(bytes, footerContent, shifted(oldSummaryStart));
  writeU64(bytes, footerContent + 8,
           oldSummaryOffsetStart == 0 ? 0 : shifted(oldSummaryOffsetStart));
  resealSummary(bytes);
  return true;
}

/// The `"refused"` member of an expectation file.
///
/// Enough JSON for one string member, which is all the corpus is asked for here. A JSON parser
/// is a dependency in a package whose whole argument is that it has none.
std::string expectedRefusal(const std::filesystem::path& json) {
  std::ifstream stream(json);
  if (!stream) return {};
  std::string text((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
  const std::size_t key = text.find("\"refused\"");
  if (key == std::string::npos) return {};
  const std::size_t colon = text.find(':', key);
  if (colon == std::string::npos) return {};
  const std::size_t open = text.find('"', colon);
  if (open == std::string::npos) return {};
  const std::size_t close = text.find('"', open + 1);
  if (close == std::string::npos) return {};
  return text.substr(open + 1, close - open - 1);
}

std::vector<std::filesystem::path> variants(const std::filesystem::path& directory) {
  std::vector<std::filesystem::path> out;
  if (!std::filesystem::is_directory(directory)) return out;
  for (const std::filesystem::directory_entry& entry :
       std::filesystem::directory_iterator(directory)) {
    if (entry.path().extension() == ".4dgs") out.push_back(entry.path());
  }
  std::sort(out.begin(), out.end());
  return out;
}

std::set<std::filesystem::path> identityScratchDirectories() {
  std::set<std::filesystem::path> out;
  std::error_code error;
  const std::filesystem::path temporary = std::filesystem::temp_directory_path(error);
  if (error) return out;
  for (std::filesystem::directory_iterator entries(temporary, error), end; !error && entries != end;
       entries.increment(error)) {
    const std::string name = entries->path().filename().string();
    if (name.rfind("4dgs-validate-ids-", 0) == 0) out.insert(entries->path());
  }
  return out;
}

/// A conforming capture carrying provenance records — a coordinate frame, a rig trajectory and
/// sensor calibrations — which is the variant that would produce spurious "unknown record" notes
/// if the provenance family were not recognized.
constexpr const char* kProvenanceVariant =
    "TenWindows-UseChunkIndex-UseCrc-WithFrame-WithRig-WithSensors.4dgs";

void everyInvalidVariantIsRefusedByItsOwnIdentifier() {
  // The strongest evidence there is that this tool is right, because the corpus already knows
  // the answer and the tool had no hand in writing it. "Refused" alone is not the property: a
  // reader that refuses every one of these for the wrong reason passes a test that only checks
  // the exit code, and that is precisely the failure the invalid corpus was built to catch.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::filesystem::path> files = variants(corpusDirectory() / "invalid");
  CHECK_EQ(files.size(), static_cast<std::size_t>(7));
  for (const std::filesystem::path& file : files) {
    const std::string code =
        expectedRefusal(std::filesystem::path(file).replace_extension(".json"));
    CHECK(!code.empty());
    if (code.empty()) continue;
    const Run result = run({"validate", file.string()});
    // Non-zero, and this non-zero: 3 would mean the tool could not read the file at all.
    CHECK_EQ(result.code, fourdgs::tool::kExitFailed);
    CHECK(result.outContains("refusal " + code));
    // And the byte, which is the question its holder actually has. Every one of these is
    // placeable: four in the front matter, two inside a chunk the tool decodes.
    CHECK(result.outContains("refusal " + code + " at byte "));
    if (!result.outContains("refusal " + code + " at byte ")) {
      std::fprintf(stderr, "  %s said: %s", file.filename().string().c_str(), result.out.c_str());
    }
  }
}

void aConformingCaptureIsValid() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const Run result = run({"validate", (corpusDirectory() / kProvenanceVariant).string()});
  CHECK_EQ(result.code, fourdgs::tool::kExitOk);
  CHECK(result.outContains("valid"));
  // Provenance records are specified records, not unknown ones. Reporting them as unknown put
  // four notes on every conforming capture that the Python validator says nothing about.
  CHECK(!result.outContains("unknown record"));
  CHECK(!result.outContains("error:"));
}

void aConformingKeyframeDeltaFileIsNotMisclassified() {
  // Both concrete paths are certified through the range-reader ABI, rather than by handing the
  // core a whole-file byte span. A conforming file therefore receives a complete verdict.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::filesystem::path> files = variants(corpusDirectory() / "keyframe");
  CHECK(!files.empty());
  for (const std::filesystem::path& file : files) {
    const Run result = run({"validate", file.string()});
    CHECK_EQ(result.code, fourdgs::tool::kExitOk);
    CHECK(result.outContains("valid"));
    CHECK(!result.outContains("error:"));
    if (result.outContains("error:")) {
      std::fprintf(stderr, "  %s said: %s", file.filename().string().c_str(), result.out.c_str());
    }
  }
}

void keyframeDeltaHeaderCountIsTheLifetimeDistinctIdentityCount() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(
      corpusDirectory() / "keyframe" / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  CHECK(header != nullptr);
  if (header == nullptr) return;
  std::size_t at = static_cast<std::size_t>(header->offset + fourdgs::tool::kRecordHeaderSize);
  for (int field = 0; field < 2; ++field) {
    const std::uint32_t length = readU32(bytes, at);
    at += 4 + length;
  }
  at += 8;  // duration_sec
  const std::uint64_t declared = readU64(bytes, at);
  writeU64(&bytes, at, declared + 1);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  CHECK(report.hasErrors());
  bool found = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("Header declares " + std::to_string(declared + 1) +
                             " distinct gaussians at byte " + std::to_string(header->offset) +
                             " (the Header record); keyframes and birth groups introduce " +
                             std::to_string(declared)) != std::string::npos) {
      found = true;
    }
  }
  CHECK(found);
}

void identitySinkIoIsNotCalledAnInputReadFailure() {
  Report report;
  fourdgs::tool::reportKeyframeDeltaToolFailure(
      &report, "sequential", Error(ErrorCode::kIo, "cannot write temporary identity partition 0"),
      true);
  CHECK(!report.complete);
  CHECK_EQ(report.findings.size(), static_cast<std::size_t>(1));
  CHECK(report.findings[0].message.find("identity validation could not use temporary storage") !=
        std::string::npos);
  CHECK(report.findings[0].message.find("could not read the file") == std::string::npos);
}

void validatorToolFailuresNameTheirActualCause() {
  struct Case {
    ErrorCode code;
    const char* expected;
  };
  for (const Case& test : {
           Case{ErrorCode::kIo, "could not read the file"},
           Case{ErrorCode::kUnsupportedMode, "reached a bounded tool limit"},
           Case{ErrorCode::kNotImplemented, "functionality this tool does not implement"},
           Case{ErrorCode::kInternal, "failed inside the tool"},
       }) {
    Report report;
    fourdgs::tool::reportKeyframeDeltaToolFailure(&report, "indexed",
                                                  Error(test.code, "injected diagnosis"), false);
    CHECK(!report.complete);
    CHECK_EQ(report.findings.size(), static_cast<std::size_t>(1));
    CHECK(report.findings[0].message.find(test.expected) != std::string::npos);
    if (test.code != ErrorCode::kIo) {
      CHECK(report.findings[0].message.find("could not read the file") == std::string::npos);
    }
  }
}

void identityPartitionCloseFailureIsIo() {
  std::ofstream failed;
  failed.setstate(std::ios::badbit);
  fourdgs::Result<void> closed = fourdgs::tool::checkIdentityPartitionClose(failed, 3);
  CHECK(!closed.ok());
  if (!closed) {
    CHECK_EQ(closed.error().code, ErrorCode::kIo);
    CHECK(closed.error().message.find("close temporary identity partition 3") != std::string::npos);
  }
}

void anEarlyKeyframeRefusalRemovesIdentityScratchStorage() {
  // Identity validation opens its bounded disk partitions before asking the core to decode.
  // This malformed first state makes that decode return before finish() closes the streams.
  // Windows does not permit an open file to be unlinked, so the destructor must close the
  // partitions before removing their directory rather than relying on POSIX unlink semantics.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(
      corpusDirectory() / "keyframe" / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* keyframe = walked->firstIntact(fourdgs::tool::op::kChunk);
  CHECK(keyframe != nullptr);
  if (keyframe == nullptr) return;
  bytes[static_cast<std::size_t>(keyframe->offset)] = fourdgs::tool::op::kDeltaChunk;

  const std::set<std::filesystem::path> before = identityScratchDirectories();
  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  CHECK_EQ(identityScratchDirectories(), before);
}

void aReusedIdentityNamesItsSecondIntroductionRecord() {
  if (noDecoder()) return;
  const auto population = [](std::size_t count) {
    fourdgs::GaussianData data;
    data.resize(count, 0, 0);
    if (count == 0) return data;
    data.scales = {0.05f, 0.05f, 0.05f};
    data.rotations = {0.0f, 0.0f, 0.0f, 1.0f};
    data.colors = {0.5f, 0.25f, 0.75f, 0.9f};
    data.sigmaT = {0.5f};
    data.winHi = {1.0f};
    return data;
  };
  std::vector<std::vector<std::uint32_t>> ids{{7}, {}, {7}};
  std::vector<fourdgs::GaussianData> populations{population(1), population(0), population(1)};
  std::vector<fourdgs::KeyframeDeltaSample> samples;
  for (std::size_t i = 0; i < ids.size(); ++i) {
    fourdgs::KeyframeDeltaSample sample;
    sample.t0 = static_cast<double>(i) / 3.0;
    sample.ids = Span<const std::uint32_t>(ids[i].data(), ids[i].size());
    sample.gaussians = fourdgs::GaussianView(populations[i]);
    samples.push_back(sample);
  }
  fourdgs::KeyframeDeltaOptions options;
  options.keyframeEvery = 8;
  options.deltaMode = fourdgs::kDeltaModeKeyframe;
  fourdgs::Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeKeyframeDeltaSequence(
      Span<const fourdgs::KeyframeDeltaSample>(samples.data(), samples.size()), 1.0, options);
  CHECK(encoded.ok());
  if (!encoded) return;
  std::vector<fourdgs::tool::Frame> states;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(encoded->data(), encoded->size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && (frame.opcode == fourdgs::tool::op::kChunk ||
                                                  frame.opcode == fourdgs::tool::op::kDeltaChunk)) {
                                   states.push_back(frame);
                                 }
                               });
  CHECK(walked.ok());
  CHECK_EQ(states.size(), static_cast<std::size_t>(3));
  if (!walked || states.size() != 3) return;

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(encoded->data(), encoded->size()));
  CHECK(!report.ok());
  bool placed = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("gaussian_id 7 is introduced more than once at byte " +
                             std::to_string(states[2].offset) + " (the keyframe-delta record)") !=
        std::string::npos) {
      placed = true;
    }
  }
  CHECK(placed);
}

void everyValidVariantIsValid() {
  // The other half of the corpus's evidence: a validator that refused everything would pass the
  // check above and fail this one.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::filesystem::path> files = variants(corpusDirectory());
  // The object-layer variants live in their own directory and are conforming files like any
  // other; a validator that only ever saw the flat directory would not know that.
  for (const std::filesystem::path& file : variants(corpusDirectory() / "object")) {
    files.push_back(file);
  }
  CHECK(files.size() >= 40);
  for (const std::filesystem::path& file : files) {
    const Run result = run({"validate", file.string()});
    // Indexed files are complete. An indexless file is structurally accepted but returns 3:
    // the bounded C++ core cannot decode one physical chunk at a time on that path. Never 1.
    CHECK(result.code == fourdgs::tool::kExitOk || result.code == fourdgs::tool::kExitWarnings ||
          result.code == fourdgs::tool::kExitTool);
    if (result.code == fourdgs::tool::kExitFailed) {
      std::fprintf(stderr, "  %s said: %s", file.filename().string().c_str(), result.out.c_str());
    }
  }
}

void aWalkFramesEveryRecordAndEndsOnTheMagic() {
  if (corpusMissing()) return;
  const std::vector<std::uint8_t> data = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!data.empty());
  std::uint64_t at = fourdgs::tool::kMagicSize;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(data.data(), data.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 CHECK(complete);
                                 CHECK_EQ(frame.offset, at);
                                 at += frame.total();
                               });
  CHECK(walked.ok());
  if (!walked) return;
  CHECK(walked->trailingMagic);
  CHECK(!walked->cut.has_value());
  CHECK(walked->first(fourdgs::tool::op::kHeader) != nullptr);
  CHECK(walked->first(fourdgs::tool::op::kFooter) != nullptr);
  // Every record accounted for, back to back: the offsets have to tile the file.
  CHECK_EQ(at, walked->size - fourdgs::tool::kMagicSize);
}

void aCutFileReportsTheIntactPrefixAndTheByte() {
  if (corpusMissing()) return;
  std::vector<std::uint8_t> data = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!data.empty());
  fourdgs::Result<Walk> whole =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(data.data(), data.size()));
  CHECK(whole.ok());
  if (!whole) return;

  data.resize(data.size() / 2);
  fourdgs::Result<Walk> cut =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(data.data(), data.size()));
  CHECK(cut.ok());
  if (!cut) return;
  CHECK(cut->cut.has_value());
  if (!cut->cut.has_value()) return;
  CHECK(cut->cut->at < data.size());
  CHECK(!cut->trailingMagic);
  // The intact prefix is still framed, and the record the file was cut inside is reported but
  // is not part of it: hiding that record would hide the declared length that is the fault.
  CHECK(cut->recordCount > 0);
  CHECK(cut->recordCount < whole->recordCount);
  CHECK_EQ(cut->intact(), cut->recordCount - 1);

  const Report report = fourdgs::tool::validate(Span<const std::uint8_t>(data.data(), data.size()));
  CHECK(!report.ok());
  bool saidWhereItWasCut = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.severity == Severity::kNote &&
        finding.message.find("the file is cut at byte ") != std::string::npos) {
      saidWhereItWasCut = true;
    }
  }
  CHECK(saidWhereItWasCut);
}

void inspectPrintsOneRowPerRecordAndReportsACut() {
  if (corpusMissing()) return;
  const Run whole = run({"inspect", (corpusDirectory() / kProvenanceVariant).string()});
  CHECK_EQ(whole.code, fourdgs::tool::kExitOk);
  CHECK(whole.outContains("offset  record"));
  CHECK(whole.outContains(" records, "));
  CHECK(!whole.outContains("truncated at byte"));
  // The summary checksum is a fact about a region, so the covered range is named beneath the
  // table rather than left for the reader to infer from the column.
  CHECK(whole.outContains("crc: the Footer's summary checksum covers bytes "));

  const Run json = run({"inspect", "--json", (corpusDirectory() / kProvenanceVariant).string()});
  CHECK_EQ(json.code, fourdgs::tool::kExitOk);
  CHECK(json.outContains("\"records\": ["));
  CHECK(json.outContains("\"truncated_at\": null"));
}

void theToolCouldNotRunHasItsOwnExitCode() {
  // `1` is an answer about a file: it was read, and it is bad. `3` is the absence of an answer,
  // and a pipeline that saw `1` for both could not tell a corrupt asset from a typo in a path.
  CHECK_EQ(run({"validate", "/nonexistent-4dgs-file"}).code, fourdgs::tool::kExitTool);
  CHECK_EQ(run({"inspect", "/nonexistent-4dgs-file"}).code, fourdgs::tool::kExitTool);
  CHECK_EQ(run({"frobnicate", "x"}).code, fourdgs::tool::kExitTool);
  CHECK_EQ(run({"validate"}).code, fourdgs::tool::kExitTool);
  CHECK_EQ(run({"validate", "--nonsense", "x"}).code, fourdgs::tool::kExitTool);
  // A request that was served is not a failure.
  CHECK_EQ(run({"--help"}).code, fourdgs::tool::kExitOk);
  CHECK_EQ(run({}).code, fourdgs::tool::kExitOk);
  CHECK_EQ(run({"--version"}).code, fourdgs::tool::kExitOk);
}

void anErrorTheRefusalTableDoesNotNameIsNotGivenAnIdentifier() {
  // A truncated transport is a real error and not a refusal. Inventing a code for it would be
  // inventing conformance.
  const Error truncated(ErrorCode::kTruncated, "cut");
  CHECK(!fourdgs::tool::describe(truncated, nullptr, std::nullopt).has_value());

  // And a refusal is placed at byte zero without a walk, because the walk that would find a
  // record cannot start until the magic passes.
  const Error refused(ErrorCode::kUnsupportedVersion, "not a 4dgs file (bad magic)",
                      std::string("magic-mismatch"));
  const std::optional<Named> named = fourdgs::tool::describe(refused, nullptr, std::nullopt);
  CHECK(named.has_value());
  if (named.has_value()) {
    CHECK_EQ(named->code, std::string("magic-mismatch"));
    CHECK(named->site.has_value());
    CHECK_EQ(named->site->offset, static_cast<std::uint64_t>(0));
  }
}

void inspectTransportFailuresUseTheToolFailureExit() {
  CHECK_EQ(fourdgs::tool::inspectFailureExit(
               Error(ErrorCode::kIo, "injected inspect transport failure")),
           fourdgs::tool::kExitTool);
  CHECK_EQ(fourdgs::tool::inspectFailureExit(Error(ErrorCode::kBadMagic, "not a 4dgs file")),
           fourdgs::tool::kExitFailed);
}

void theDisplayFormCarriesTheCodeAndTheByte() {
  Named named;
  named.code = "unknown-temporal-model";
  named.site = Site{8, "the Header record"};
  CHECK_EQ(named.toString(),
           std::string("refusal unknown-temporal-model at byte 8 (the Header record)"));

  Named unplaced;
  unplaced.code = "unknown-stream-codec";
  CHECK_EQ(unplaced.toString(), std::string("refusal unknown-stream-codec"));
}

void opcodeNamesCoverTheOpenRanges() {
  CHECK_EQ(fourdgs::tool::opcodeName(0x01), std::string("Header"));
  CHECK_EQ(fourdgs::tool::opcodeName(0x10), std::string("DeltaChunk"));
  CHECK_EQ(fourdgs::tool::opcodeName(0x25), std::string("ObjectTrack"));
  // The two ranges the specification leaves open, told apart because the fix differs: a private
  // record is somebody else's business and an unknown one is a later revision's.
  CHECK_EQ(fourdgs::tool::opcodeName(0x7D), std::string("Unknown(0x7D)"));
  CHECK_EQ(fourdgs::tool::opcodeName(0x91), std::string("Private(0x91)"));
  CHECK(fourdgs::tool::isSpecified(0x25));
  CHECK(!fourdgs::tool::isSpecified(0x26));
  CHECK(fourdgs::tool::isProvenance(0x26));
  CHECK(fourdgs::tool::isPrivate(0x80));
}

/// A transport that stops early, which `Readable` explicitly permits.
///
/// A file can shrink between the `size()` a walk asks for and the read that follows, and the
/// abstraction surfaces that as a short read rather than an error. A walk that parsed the buffer
/// regardless would be parsing bytes that never arrived.
class ShortReadable : public fourdgs::Readable {
 public:
  ShortReadable(std::vector<std::uint8_t> bytes, std::uint64_t claimed, std::size_t cap)
      : bytes_(std::move(bytes)), claimed_(claimed), cap_(cap) {}

  fourdgs::Result<std::uint64_t> size() override { return claimed_; }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    std::size_t take = bytes_.size() - static_cast<std::size_t>(offset);
    if (take > into.size()) take = into.size();
    if (take > cap_) take = cap_;
    for (std::size_t i = 0; i < take; ++i) into[i] = bytes_[static_cast<std::size_t>(offset) + i];
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
  std::uint64_t claimed_;
  std::size_t cap_;
};

class FailingRangeReadable : public fourdgs::Readable {
 public:
  FailingRangeReadable(std::vector<std::uint8_t> bytes, std::uint64_t failAt)
      : bytes_(std::move(bytes)), failAt_(failAt) {}

  fourdgs::Result<std::uint64_t> size() override { return bytes_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset == failAt_) return Error(ErrorCode::kIo, "injected Header transport failure");
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t take =
        std::min(into.size(), bytes_.size() - static_cast<std::size_t>(offset));
    std::copy_n(bytes_.begin() + static_cast<std::size_t>(offset), take, into.data());
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
  std::uint64_t failAt_;
};

/// A transport that fails when a requested range reaches one chosen payload byte.
class FailingCoveredByteReadable : public fourdgs::Readable {
 public:
  FailingCoveredByteReadable(std::vector<std::uint8_t> bytes, std::uint64_t failAt)
      : bytes_(std::move(bytes)), failAt_(failAt) {}

  fourdgs::Result<std::uint64_t> size() override { return bytes_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    const std::uint64_t end = offset + into.size();
    if (end >= offset && offset <= failAt_ && failAt_ < end) {
      return Error(ErrorCode::kIo, "injected chunk payload transport failure");
    }
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t take =
        std::min(into.size(), bytes_.size() - static_cast<std::size_t>(offset));
    std::copy_n(bytes_.begin() + static_cast<std::size_t>(offset), take, into.data());
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
  std::uint64_t failAt_;
};

/// A transport that fails only after an earlier range walk has succeeded.
///
/// Validation walks the framing once to establish the structure and again to resolve indexed
/// offsets. A failure on the second visit proves that a later transport error cannot disappear
/// behind facts retained from the first successful pass.
class FailingRepeatedRangeReadable : public fourdgs::Readable {
 public:
  FailingRepeatedRangeReadable(std::vector<std::uint8_t> bytes, std::uint64_t failAt,
                               std::size_t failOnVisit)
      : bytes_(std::move(bytes)), failAt_(failAt), failOnVisit_(failOnVisit) {}

  fourdgs::Result<std::uint64_t> size() override { return bytes_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset == failAt_ && ++visits_ == failOnVisit_) {
      return Error(ErrorCode::kIo, "injected repeated transport failure");
    }
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t take =
        std::min(into.size(), bytes_.size() - static_cast<std::size_t>(offset));
    std::copy_n(bytes_.begin() + static_cast<std::size_t>(offset), take, into.data());
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
  std::uint64_t failAt_;
  std::size_t failOnVisit_;
  std::size_t visits_ = 0;
};

class LargestRangeReadable : public fourdgs::Readable {
 public:
  explicit LargestRangeReadable(Span<const std::uint8_t> bytes) : inner_(bytes) {}

  fourdgs::Result<std::uint64_t> size() override { return inner_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    largest_ = std::max(largest_, into.size());
    return inner_.read(offset, into);
  }

  std::size_t largest() const { return largest_; }

 private:
  fourdgs::MemoryReadable inner_;
  std::size_t largest_ = 0;
};

void aWalkRetainsBoundedFactsForUnboundedPrivateRecords() {
  constexpr std::size_t kRecords = 50000;
  std::vector<std::uint8_t> bytes;
  bytes.reserve(fourdgs::tool::kMagicSize + kRecords * fourdgs::tool::kRecordHeaderSize +
                fourdgs::tool::kMagicSize);
  bytes.insert(bytes.end(), fourdgs::tool::kMagic,
               fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  for (std::size_t i = 0; i < kRecords; ++i) {
    bytes.push_back(0x80);
    for (int j = 0; j < 8; ++j) bytes.push_back(0);
  }
  bytes.insert(bytes.end(), fourdgs::tool::kMagic,
               fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);

  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  CHECK_EQ(walked->recordCount, static_cast<std::uint64_t>(kRecords));
  CHECK_EQ(walked->intact(), static_cast<std::uint64_t>(kRecords));
  CHECK_EQ(walked->representatives.size(), static_cast<std::size_t>(2));
  CHECK_EQ(walked->opcodeCounts[0x80], static_cast<std::uint64_t>(kRecords));
}

void aLongHeaderIsRangeParsedThroughItsTemporalModel() {
  constexpr std::size_t kProfileBytes = 6000;
  std::vector<std::uint8_t> content;
  appendU32(&content, static_cast<std::uint32_t>(kProfileBytes));
  content.insert(content.end(), kProfileBytes, static_cast<std::uint8_t>('p'));
  appendU32(&content, 0);                       // library
  content.insert(content.end(), 8 + 8 + 8, 0);  // duration, gaussian_count, cutoff
  const std::string model = "keyframe-delta";
  appendU32(&content, static_cast<std::uint32_t>(model.size()));
  content.insert(content.end(), model.begin(), model.end());

  std::vector<std::uint8_t> bytes(fourdgs::tool::kMagic,
                                  fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  bytes.push_back(fourdgs::tool::op::kHeader);
  appendU64(&bytes, content.size());
  bytes.insert(bytes.end(), content.begin(), content.end());
  bytes.insert(bytes.end(), fourdgs::tool::kMagic,
               fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);

  fourdgs::tool::BorrowedReadable source(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(source);
  CHECK(walked.ok());
  if (!walked) return;
  fourdgs::Result<std::string> parsed = fourdgs::tool::temporalModel(source, *walked);
  CHECK(parsed.ok());
  if (parsed) CHECK_EQ(*parsed, model);
}

void aTemporalModelTransportFailureMakesValidationIncomplete() {
  if (corpusMissing()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::tool::BorrowedReadable ordinary(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(ordinary);
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  CHECK(header != nullptr);
  if (header == nullptr) return;

  FailingRangeReadable failing(std::move(bytes), header->offset + fourdgs::tool::kRecordHeaderSize);
  const Report report = fourdgs::tool::validate(failing);
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool propagated = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("cannot range-read the Header temporal_model") != std::string::npos &&
        finding.message.find("injected Header transport failure") != std::string::npos) {
      propagated = true;
    }
  }
  CHECK(propagated);
}

void aChunkIndexTransportFailureMakesValidationIncomplete() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* index = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  CHECK(index != nullptr);
  if (index == nullptr) return;

  FailingRangeReadable failing(std::move(bytes), index->offset + fourdgs::tool::kRecordHeaderSize);
  const Report report = fourdgs::tool::validate(failing);
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool propagated = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("cannot range-read the Chunk Index") != std::string::npos &&
        finding.message.find("injected Header transport failure") != std::string::npos) {
      propagated = true;
    }
  }
  CHECK(propagated);
}

void aLaterIndexResolutionTransportFailureMakesValidationIncomplete() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;

  // The first visit is the framing pass; Chunk Index parsing performs the second walk; indexed
  // range resolution is the third.
  FailingRepeatedRangeReadable failing(std::move(bytes), 0, 3);
  const Report report = fourdgs::tool::validate(failing);
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool propagated = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("cannot resolve indexed ranges") != std::string::npos &&
        finding.message.find("injected repeated transport failure") != std::string::npos) {
      propagated = true;
    }
  }
  CHECK(propagated);
}

void aKeyframeDeltaPayloadTransportFailurePreservesCause() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(
      corpusDirectory() / "keyframe" / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* chunk = walked->firstIntact(fourdgs::tool::op::kChunk);
  CHECK(chunk != nullptr);
  if (chunk == nullptr) return;

  // Structural validation reads the 24-byte Chunk prefix. The following payload byte is first
  // needed by the core decoder, after all range and index checks have succeeded.
  const std::uint64_t payload = chunk->offset + fourdgs::tool::kRecordHeaderSize + 8 + 8 + 4 + 4;
  FailingCoveredByteReadable failing(std::move(bytes), payload);
  const Report report = fourdgs::tool::validate(failing);
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool propagated = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("keyframe-delta sequential validation could not read the file") !=
            std::string::npos &&
        finding.message.find("injected chunk payload transport failure") != std::string::npos) {
      propagated = true;
    }
  }
  if (!propagated) {
    for (const fourdgs::tool::Finding& finding : report.findings)
      std::fprintf(stderr, "  keyframe transport finding: %s\n", finding.message.c_str());
  }
  CHECK(propagated);
}

void anUnindexedKeyframeDeltaIsCertifiedFrontToBack() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(
      corpusDirectory() / "keyframe" / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* firstIndex = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(firstIndex != nullptr);
  CHECK(footer != nullptr);
  if (firstIndex == nullptr || footer == nullptr) return;

  std::vector<std::uint8_t> unindexed(bytes.begin(), bytes.begin() + firstIndex->offset);
  const std::size_t newFooter = unindexed.size();
  unindexed.insert(unindexed.end(), bytes.begin() + footer->offset,
                   bytes.begin() + footer->offset + footer->total());
  unindexed.insert(unindexed.end(), bytes.end() - fourdgs::tool::kMagicSize, bytes.end());
  // summary_start, summary_offset_start and summary_crc all declare no summary.
  for (std::size_t i = 0; i < 20; ++i) {
    unindexed[newFooter + fourdgs::tool::kRecordHeaderSize + i] = 0;
  }

  fourdgs::MemoryReadable inner(Span<const std::uint8_t>(unindexed.data(), unindexed.size()));
  fourdgs::CountingReadable counting(&inner);
  const Report report = fourdgs::tool::validate(counting);
  CHECK(report.ok());
  CHECK(!report.hasErrors());
  CHECK(report.complete);
  bool warnedOnly = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("can only be read front to back") != std::string::npos) {
      warnedOnly = finding.severity == Severity::kWarning;
    }
  }
  CHECK(warnedOnly);
}

void anUnindexedFileStillReceivesAFrontMatterVerdict() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  const fourdgs::tool::Frame* firstIndex = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(header != nullptr);
  CHECK(firstIndex != nullptr);
  CHECK(footer != nullptr);
  if (header == nullptr || firstIndex == nullptr || footer == nullptr) return;

  std::size_t model = static_cast<std::size_t>(header->offset + fourdgs::tool::kRecordHeaderSize);
  for (int field = 0; field < 2; ++field) model += 4 + readU32(bytes, model);
  model += 8 + 8 + 8;
  const std::uint32_t modelLength = readU32(bytes, model);
  model += 4;
  const std::string unknown = "unknown-model!";
  CHECK_EQ(modelLength, unknown.size());
  if (modelLength != unknown.size()) return;
  std::copy(unknown.begin(), unknown.end(), bytes.begin() + static_cast<std::ptrdiff_t>(model));

  std::vector<std::uint8_t> unindexed(bytes.begin(), bytes.begin() + firstIndex->offset);
  const std::size_t newFooter = unindexed.size();
  unindexed.insert(unindexed.end(), bytes.begin() + footer->offset,
                   bytes.begin() + footer->offset + footer->total());
  unindexed.insert(unindexed.end(), bytes.end() - fourdgs::tool::kMagicSize, bytes.end());
  for (std::size_t i = 0; i < 20; ++i) {
    unindexed[newFooter + fourdgs::tool::kRecordHeaderSize + i] = 0;
  }

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(unindexed.data(), unindexed.size()));
  bool refusedModel = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.refusal.has_value() && finding.refusal->code == "unknown-temporal-model") {
      refusedModel = true;
    }
  }
  CHECK(refusedModel);
}

void duplicateHeadersAreRejectedBeforeModelDispatch() {
  if (corpusMissing()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  const fourdgs::tool::Frame* chunk = walked->firstIntact(fourdgs::tool::op::kChunk);
  CHECK(header != nullptr);
  CHECK(chunk != nullptr);
  if (header == nullptr || chunk == nullptr) return;
  const std::vector<std::uint8_t> duplicate(
      bytes.begin() + static_cast<std::ptrdiff_t>(header->offset),
      bytes.begin() + static_cast<std::ptrdiff_t>(header->offset + header->total()));
  bytes.insert(bytes.begin() + static_cast<std::ptrdiff_t>(chunk->offset), duplicate.begin(),
               duplicate.end());

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool unique = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("Header records; the Header must be unique") != std::string::npos) {
      unique = true;
    }
  }
  CHECK(unique);
}

void anEmbeddedChunkOpcodeIsNotARecordBoundary() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  const fourdgs::tool::Frame* entry = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  CHECK(header != nullptr);
  CHECK(entry != nullptr);
  if (header == nullptr || entry == nullptr) return;
  const std::size_t embedded =
      static_cast<std::size_t>(header->offset + fourdgs::tool::kRecordHeaderSize + 4);
  bytes[embedded] = fourdgs::tool::op::kChunk;
  const std::size_t indexFields =
      static_cast<std::size_t>(entry->offset + fourdgs::tool::kRecordHeaderSize + 16);
  writeU64(&bytes, indexFields, embedded);
  writeU64(&bytes, indexFields + 8, 1);
  resealSummary(&bytes);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  bool namedBoundary = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("does not point at the start of a top-level Chunk record") !=
        std::string::npos) {
      namedBoundary = true;
    }
  }
  CHECK(namedBoundary);
}

void anOrphanChunkIsDecodedByTheStreamedValidationPass() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  const std::vector<std::uint8_t> invalid =
      readBytes(corpusDirectory() / "invalid" / "UnknownStreamCodec.4dgs");
  CHECK(!bytes.empty());
  CHECK(!invalid.empty());
  if (bytes.empty() || invalid.empty()) return;
  fourdgs::Result<Walk> validWalk =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<Walk> invalidWalk =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(invalid.data(), invalid.size()));
  CHECK(validWalk.ok());
  CHECK(invalidWalk.ok());
  if (!validWalk || !invalidWalk) return;
  const fourdgs::tool::Frame* summary = validWalk->firstIntact(fourdgs::tool::op::kChunkIndex);
  const fourdgs::tool::Frame* badChunk = invalidWalk->firstIntact(fourdgs::tool::op::kChunk);
  const fourdgs::tool::Frame* oldFooter = validWalk->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(summary != nullptr);
  CHECK(badChunk != nullptr);
  CHECK(oldFooter != nullptr);
  if (summary == nullptr || badChunk == nullptr || oldFooter == nullptr) return;

  const std::size_t insertAt = static_cast<std::size_t>(summary->offset);
  const std::size_t badStart = static_cast<std::size_t>(badChunk->offset);
  const std::size_t badEnd = badStart + static_cast<std::size_t>(badChunk->total());
  std::vector<std::uint8_t> withOrphan(bytes.begin(), bytes.begin() + insertAt);
  withOrphan.insert(withOrphan.end(), invalid.begin() + badStart, invalid.begin() + badEnd);
  withOrphan.insert(withOrphan.end(), bytes.begin() + insertAt, bytes.end());
  const std::uint64_t shift = badChunk->total();
  const std::size_t footerContent =
      static_cast<std::size_t>(oldFooter->offset + shift + fourdgs::tool::kRecordHeaderSize);
  const std::uint64_t oldSummaryStart = readU64(
      bytes, static_cast<std::size_t>(oldFooter->offset + fourdgs::tool::kRecordHeaderSize));
  writeU64(&withOrphan, footerContent, oldSummaryStart + shift);
  const std::uint64_t oldSummaryOffset = readU64(
      bytes, static_cast<std::size_t>(oldFooter->offset + fourdgs::tool::kRecordHeaderSize + 8));
  if (oldSummaryOffset != 0) writeU64(&withOrphan, footerContent + 8, oldSummaryOffset + shift);
  resealSummary(&withOrphan);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(withOrphan.data(), withOrphan.size()));
  CHECK(!report.ok());
  bool foundOrphan = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("absent from the Chunk Index") != std::string::npos) {
      foundOrphan = true;
    }
  }
  CHECK(foundOrphan);
}

void anUnindexedPhysicalBandIsRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes =
      readBytes(corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs");
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* index = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  CHECK(index != nullptr);
  if (index == nullptr) return;

  // band_count is the last u32 in the fixed 40-byte index prefix. Leave the
  // physical band records in place while making the indexed path omit them.
  const std::size_t bandCount =
      static_cast<std::size_t>(index->offset + fourdgs::tool::kRecordHeaderSize + 36);
  writeU32(&bytes, bandCount, 0);
  resealSummary(&bytes);
  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool found = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("physical SH Band Stream record") != std::string::npos &&
        finding.message.find("absent from the Chunk Index") != std::string::npos) {
      found = true;
    }
  }
  CHECK(found);
}

void duplicateFootersAndIndexEntriesAreRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::uint8_t> original = readBytes(corpusDirectory() / kProvenanceVariant);
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr) return;

  const std::size_t footerAt = static_cast<std::size_t>(footer->offset);
  const std::size_t footerEnd = footerAt + static_cast<std::size_t>(footer->total());
  std::vector<std::uint8_t> duplicateFooter(original.begin(), original.begin() + footerAt);
  duplicateFooter.insert(duplicateFooter.end(), original.begin() + footerAt,
                         original.begin() + footerEnd);
  duplicateFooter.insert(duplicateFooter.end(), original.begin() + footerAt, original.end());
  const Report footerReport = fourdgs::tool::validate(
      Span<const std::uint8_t>(duplicateFooter.data(), duplicateFooter.size()));
  bool foundFooter = false;
  for (const fourdgs::tool::Finding& finding : footerReport.findings) {
    if (finding.message.find("Footer records; the Footer must be unique") != std::string::npos) {
      foundFooter = true;
    }
  }
  CHECK(foundFooter);

  std::vector<fourdgs::tool::Frame> indexes;
  (void)fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()),
                                 [&](const fourdgs::tool::Frame& frame, bool complete) {
                                   if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                     indexes.push_back(frame);
                                 });
  CHECK(indexes.size() >= 2);
  if (indexes.size() < 2) return;
  std::vector<std::uint8_t> duplicateIndex = original;
  const std::size_t firstOffset =
      static_cast<std::size_t>(indexes[0].offset + fourdgs::tool::kRecordHeaderSize + 16);
  const std::size_t secondOffset =
      static_cast<std::size_t>(indexes[1].offset + fourdgs::tool::kRecordHeaderSize + 16);
  writeU64(&duplicateIndex, secondOffset, readU64(original, firstOffset));
  resealSummary(&duplicateIndex);
  const Report indexReport = fourdgs::tool::validate(
      Span<const std::uint8_t>(duplicateIndex.data(), duplicateIndex.size()));
  bool foundIndex = false;
  for (const fourdgs::tool::Finding& finding : indexReport.findings) {
    if (finding.message.find("duplicates physical chunk") != std::string::npos) foundIndex = true;
  }
  CHECK(foundIndex);
}

void inspectReadsRangesRatherThanTheWholeFile() {
  // Cross-SDK principle 1, checked at the transport rather than argued in a comment: `inspect` is
  // framing plus the summary checksum, so what it transfers is nine bytes per record and the
  // covered range — never the payload it steps over. The audio variant is the one that makes the
  // difference visible, because most of it is an Audio Data record nothing here looks inside.
  if (corpusMissing()) return;
  const std::filesystem::path file =
      corpusDirectory() / "OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio.4dgs";
  const std::vector<std::uint8_t> bytes = readBytes(file);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;

  fourdgs::MemoryReadable inner(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::CountingReadable counting(&inner);
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(counting);
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::Result<std::optional<fourdgs::tool::Coverage>> covered =
      fourdgs::tool::coverage(counting, *walked);
  CHECK(covered.ok());
  CHECK(covered.ok() && covered->has_value());
  // Framing (nine bytes a record, plus both magics) and the covered range, and nothing else. The
  // Audio Data record alone is over four kilobytes, so a whole-file read could not fit under this.
  CHECK(counting.bytesRead() < bytes.size() / 2);
  if (counting.bytesRead() >= bytes.size() / 2) {
    std::fprintf(stderr, "  transferred %llu of %llu bytes\n",
                 static_cast<unsigned long long>(counting.bytesRead()),
                 static_cast<unsigned long long>(bytes.size()));
  }
}

void keyframeDeltaValidationDoesNotReadTheWholeResource() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::uint8_t> bytes = readBytes(
      corpusDirectory() / "keyframe" / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;

  LargestRangeReadable ranges(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  const Report report = fourdgs::tool::validate(ranges);
  CHECK(report.ok());
  CHECK(!report.hasErrors());
  CHECK(report.complete);
  CHECK(ranges.largest() < bytes.size());
}

void indexedBandRangesMustNameWholeTopLevelRecords() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes =
      readBytes(corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* index = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  CHECK(index != nullptr);
  if (index == nullptr) return;

  // Fixed index fields, then band 1's number and offset; its length begins nine bytes in.
  const std::size_t lengthField =
      static_cast<std::size_t>(index->offset + fourdgs::tool::kRecordHeaderSize + 40 + 9);
  const std::uint64_t original = readU64(bytes, lengthField);
  writeU64(&bytes, lengthField, original + 1);
  resealSummary(&bytes);
  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool namedWholeRecord = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("SH band 1 at index entry 0 declares") != std::string::npos &&
        finding.message.find("the record there is") != std::string::npos) {
      namedWholeRecord = true;
    }
  }
  CHECK(namedWholeRecord);
}

void indexMetadataMustMatchThePointedRecords() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::uint8_t> original = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!original.empty());
  if (original.empty()) return;
  std::vector<fourdgs::tool::Frame> indexFrames;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                   indexFrames.push_back(frame);
                               });
  CHECK(walked.ok());
  if (!walked) return;
  fourdgs::tool::BorrowedReadable source(
      Span<const std::uint8_t>(original.data(), original.size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> parsedEntries =
      fourdgs::tool::chunkIndexEntries(source, *walked);
  CHECK(parsedEntries.ok());
  if (!parsedEntries) return;
  const std::vector<fourdgs::tool::IndexEntry>& entries = *parsedEntries;
  CHECK_EQ(indexFrames.size(), entries.size());
  if (indexFrames.size() != entries.size()) return;

  std::size_t left = entries.size();
  std::size_t right = entries.size();
  for (std::size_t i = 0; i < entries.size() && left == entries.size(); ++i) {
    for (std::size_t j = i + 1; j < entries.size(); ++j) {
      const bool differentMetadata = entries[i].t0 != entries[j].t0 ||
                                     entries[i].t1 != entries[j].t1 ||
                                     entries[i].gaussianCount != entries[j].gaussianCount;
      if (entries[i].length == entries[j].length && differentMetadata) {
        left = i;
        right = j;
        break;
      }
    }
  }
  CHECK(left < entries.size());
  if (left >= entries.size()) return;

  std::vector<std::uint8_t> swapped = original;
  const std::size_t leftOffset =
      static_cast<std::size_t>(indexFrames[left].offset + fourdgs::tool::kRecordHeaderSize + 16);
  const std::size_t rightOffset =
      static_cast<std::size_t>(indexFrames[right].offset + fourdgs::tool::kRecordHeaderSize + 16);
  writeU64(&swapped, leftOffset, entries[right].offset);
  writeU64(&swapped, rightOffset, entries[left].offset);
  resealSummary(&swapped);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(swapped.data(), swapped.size()));
  bool compared = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("declares interval") != std::string::npos ||
        finding.message.find("gaussians; the Chunk at byte") != std::string::npos) {
      compared = true;
    }
  }
  CHECK(compared);
}

void indexedBandsMustMatchTheirRecordsAndOwners() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::uint8_t> original =
      readBytes(corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs");
  CHECK(!original.empty());
  if (original.empty()) return;
  std::vector<fourdgs::tool::Frame> indexFrames;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                   indexFrames.push_back(frame);
                               });
  CHECK(walked.ok());
  if (!walked) return;
  fourdgs::tool::BorrowedReadable source(
      Span<const std::uint8_t>(original.data(), original.size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> parsedEntries =
      fourdgs::tool::chunkIndexEntries(source, *walked);
  CHECK(parsedEntries.ok());
  if (!parsedEntries) return;
  const std::vector<fourdgs::tool::IndexEntry>& entries = *parsedEntries;
  CHECK_EQ(indexFrames.size(), entries.size());
  if (indexFrames.size() != entries.size() || entries.empty() || entries[0].bands.empty()) return;

  std::vector<std::uint8_t> mislabeled = original;
  const fourdgs::tool::BandRange& firstBand = entries[0].bands[0];
  const std::size_t declaredBand =
      static_cast<std::size_t>(firstBand.offset + fourdgs::tool::kRecordHeaderSize);
  mislabeled[declaredBand] = static_cast<std::uint8_t>(firstBand.band + 1);
  const Report mislabeledReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(mislabeled.data(), mislabeled.size()));
  bool checkedLabel = false;
  for (const fourdgs::tool::Finding& finding : mislabeledReport.findings) {
    if (finding.message.find("whose record declares band") != std::string::npos) {
      checkedLabel = true;
    }
  }
  CHECK(checkedLabel);

  std::vector<std::uint8_t> outsideDegree = original;
  const std::size_t firstIndexBand =
      static_cast<std::size_t>(indexFrames[0].offset + fourdgs::tool::kRecordHeaderSize + 40);
  outsideDegree[firstIndexBand] = 4;
  outsideDegree[declaredBand] = 4;
  resealSummary(&outsideDegree);
  const Report outsideDegreeReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(outsideDegree.data(), outsideDegree.size()));
  bool checkedDegree = false;
  for (const fourdgs::tool::Finding& finding : outsideDegreeReport.findings) {
    if (finding.message.find(
            "declares SH band 4; expected a band in 1 through Header sh_degree 3") !=
        std::string::npos) {
      checkedDegree = true;
    }
  }
  CHECK(checkedDegree);

  std::vector<std::uint8_t> tooManyBands = original;
  const std::size_t bandCount =
      static_cast<std::size_t>(indexFrames[0].offset + fourdgs::tool::kRecordHeaderSize + 36);
  writeU32(&tooManyBands, bandCount, 4);
  resealSummary(&tooManyBands);
  const Report tooManyReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(tooManyBands.data(), tooManyBands.size()));
  bool rejectedCount = false;
  for (const fourdgs::tool::Finding& finding : tooManyReport.findings) {
    if (finding.message.find("declares 4 SH band ranges; version 1 defines at most 3") !=
        std::string::npos) {
      rejectedCount = true;
    }
  }
  CHECK(rejectedCount);

  CHECK(entries[0].bands.size() >= 2);
  if (entries[0].bands.size() >= 2) {
    std::vector<std::uint8_t> duplicate = original;
    const std::uint8_t repeated = entries[0].bands[0].band;
    const std::size_t secondIndexBand = static_cast<std::size_t>(
        indexFrames[0].offset + fourdgs::tool::kRecordHeaderSize + 40 + 17);
    const std::size_t secondRecordBand =
        static_cast<std::size_t>(entries[0].bands[1].offset + fourdgs::tool::kRecordHeaderSize);
    duplicate[secondIndexBand] = repeated;
    duplicate[secondRecordBand] = repeated;
    resealSummary(&duplicate);
    const Report duplicateReport =
        fourdgs::tool::validate(Span<const std::uint8_t>(duplicate.data(), duplicate.size()));
    bool checkedDuplicate = false;
    bool checkedMissing = false;
    for (const fourdgs::tool::Finding& finding : duplicateReport.findings) {
      if (finding.message.find("declares SH band " + std::to_string(repeated) +
                               " more than once") != std::string::npos) {
        checkedDuplicate = true;
      }
      if (finding.message.find("chunk index entry 0 omits SH band 2") != std::string::npos) {
        checkedMissing = true;
      }
    }
    CHECK(checkedDuplicate);
    CHECK(checkedMissing);
  }

  std::size_t leftEntry = entries.size();
  std::size_t rightEntry = entries.size();
  std::size_t leftBand = 0;
  std::size_t rightBand = 0;
  for (std::size_t i = 0; i < entries.size() && leftEntry == entries.size(); ++i) {
    for (std::size_t j = i + 1; j < entries.size(); ++j) {
      for (std::size_t a = 0; a < entries[i].bands.size(); ++a) {
        for (std::size_t b = 0; b < entries[j].bands.size(); ++b) {
          if (entries[i].bands[a].band == entries[j].bands[b].band) {
            leftEntry = i;
            rightEntry = j;
            leftBand = a;
            rightBand = b;
            break;
          }
        }
        if (leftEntry != entries.size()) break;
      }
      if (leftEntry != entries.size()) break;
    }
  }
  CHECK(leftEntry < entries.size());
  if (leftEntry >= entries.size()) return;

  std::vector<std::uint8_t> swapped = original;
  const std::size_t leftField = static_cast<std::size_t>(
      indexFrames[leftEntry].offset + fourdgs::tool::kRecordHeaderSize + 40 + leftBand * 17 + 1);
  const std::size_t rightField = static_cast<std::size_t>(
      indexFrames[rightEntry].offset + fourdgs::tool::kRecordHeaderSize + 40 + rightBand * 17 + 1);
  writeU64(&swapped, leftField, entries[rightEntry].bands[rightBand].offset);
  writeU64(&swapped, leftField + 8, entries[rightEntry].bands[rightBand].length);
  writeU64(&swapped, rightField, entries[leftEntry].bands[leftBand].offset);
  writeU64(&swapped, rightField + 8, entries[leftEntry].bands[leftBand].length);
  resealSummary(&swapped);
  const Report swappedReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(swapped.data(), swapped.size()));
  bool checkedOwner = false;
  for (const fourdgs::tool::Finding& finding : swappedReport.findings) {
    if (finding.message.find("does not belong to its preceding state record") !=
        std::string::npos) {
      checkedOwner = true;
    }
  }
  CHECK(checkedOwner);
}

void skippedExtensionsPreservePhysicalBandOwnership() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes =
      readBytes(corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  fourdgs::tool::BorrowedReadable source(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> entries =
      fourdgs::tool::chunkIndexEntries(source, *walked);
  CHECK(entries.ok());
  if (!entries || entries->empty() || (*entries)[0].bands.empty()) return;

  const std::uint64_t at = (*entries)[0].bands[0].offset;
  std::vector<std::uint8_t> privateRecord{0x80};
  appendU64(&privateRecord, 0);
  CHECK(insertTopLevelRecord(&bytes, at, privateRecord));
  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool lostOwner = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("does not belong to its preceding state record") !=
        std::string::npos) {
      lostOwner = true;
    }
  }
  CHECK(!lostOwner);
  CHECK(report.ok());
}

void emptyIndexedBandsAreMalformedRatherThanIncomplete() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes =
      readBytes(corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs");
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  std::vector<fourdgs::tool::Frame> indexes;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                   indexes.push_back(frame);
                               });
  CHECK(walked.ok());
  if (!walked) return;
  fourdgs::tool::BorrowedReadable source(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> entries =
      fourdgs::tool::chunkIndexEntries(source, *walked);
  CHECK(entries.ok());
  if (!entries || entries->empty() || (*entries)[0].bands.empty()) return;
  const std::uint64_t at = (*entries)[0].bands[0].offset;

  std::vector<std::uint8_t> emptyBand{fourdgs::tool::op::kShBandStream};
  appendU64(&emptyBand, 0);
  CHECK(insertTopLevelRecord(&bytes, at, emptyBand));
  const std::size_t shiftedIndex = static_cast<std::size_t>(indexes[0].offset + emptyBand.size() +
                                                            fourdgs::tool::kRecordHeaderSize);
  writeU64(&bytes, shiftedIndex + 40 + 1, at);
  writeU64(&bytes, shiftedIndex + 40 + 9, emptyBand.size());
  resealSummary(&bytes);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool malformed = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("SH Band Stream at byte " + std::to_string(at) +
                             " declares 0 content bytes; its band label requires at least 1") !=
        std::string::npos) {
      malformed = true;
    }
  }
  CHECK(malformed);
  CHECK(report.hasErrors());
}

void decodeFrontMatterAfterStateIsRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  std::vector<fourdgs::tool::Frame> chunks;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunk)
                                   chunks.push_back(frame);
                               });
  CHECK(walked.ok());
  if (!walked || chunks.size() < 2) return;
  const fourdgs::tool::Frame* quantization = walked->firstIntact(fourdgs::tool::op::kQuantization);
  CHECK(quantization != nullptr);
  if (quantization == nullptr) return;
  const auto begin = bytes.begin() + static_cast<std::ptrdiff_t>(quantization->offset);
  const auto end = begin + static_cast<std::ptrdiff_t>(quantization->total());
  const std::vector<std::uint8_t> duplicate(begin, end);
  CHECK(insertTopLevelRecord(&bytes, chunks[1].offset, duplicate));

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool rejected = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("Quantization record at byte " + std::to_string(chunks[1].offset) +
                             " appears after the first Chunk record") != std::string::npos) {
      rejected = true;
    }
  }
  CHECK(rejected);
}

void modernAudioAfterStateIsRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  bool sawState = false;
  std::optional<fourdgs::tool::Frame> late;
  fourdgs::Result<Walk> walked = fourdgs::tool::walkBytes(
      Span<const std::uint8_t>(bytes.data(), bytes.size()),
      [&](const fourdgs::tool::Frame& frame, bool complete) {
        if (!complete) return;
        if (frame.opcode == fourdgs::tool::op::kChunk ||
            frame.opcode == fourdgs::tool::op::kDeltaChunk) {
          sawState = true;
        } else if (sawState && frame.opcode == fourdgs::tool::op::kChunkIndex &&
                   !late.has_value()) {
          late = frame;
        }
      });
  CHECK(walked.ok());
  CHECK(late.has_value());
  if (!walked || !late.has_value()) return;
  bytes[static_cast<std::size_t>(late->offset)] = fourdgs::tool::op::kAudioSource;
  resealSummary(&bytes);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool rejected = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("Audio Source record at byte " + std::to_string(late->offset) +
                             " appears after the first Chunk record") != std::string::npos) {
      rejected = true;
    }
  }
  CHECK(rejected);
}

void reservedHeaderFlagBitsAreRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* header = walked->firstIntact(fourdgs::tool::op::kHeader);
  CHECK(header != nullptr);
  if (header == nullptr) return;

  std::size_t at = static_cast<std::size_t>(header->offset + fourdgs::tool::kRecordHeaderSize);
  for (int field = 0; field < 2; ++field) at += 4 + readU32(bytes, at);
  at += 8 + 8 + 8;
  at += 4 + readU32(bytes, at);
  at += 6 * 8;
  const std::size_t flags = at + 1;
  CHECK(flags < bytes.size());
  if (flags >= bytes.size()) return;
  bytes[flags] = static_cast<std::uint8_t>(bytes[flags] | 0x04);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool rejected = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("Header flags is ") != std::string::npos &&
        finding.message.find("bits 2-7 are reserved") != std::string::npos) {
      rejected = true;
    }
  }
  CHECK(rejected);
}

void indexedCoreSummaryMemoryIsBounded() {
  const std::uint64_t start = 100;
  fourdgs::tool::SummaryDeclaration exact;
  exact.start = start;
  exact.end = start + fourdgs::tool::kMaxValidationSummaryBytes;
  CHECK(fourdgs::tool::summaryFitsValidationMemory(exact));
  fourdgs::tool::SummaryDeclaration over = exact;
  over.end += 1;
  CHECK(!fourdgs::tool::summaryFitsValidationMemory(over));
  CHECK(fourdgs::tool::summaryFitsValidationMemory(std::nullopt));
}

void undersizedChunkIndexesNameTheirDeclaredSize() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* index = walked->firstIntact(fourdgs::tool::op::kChunkIndex);
  CHECK(index != nullptr);
  if (index == nullptr || index->length < 40) return;

  constexpr std::uint64_t kShortLength = 39;
  const std::size_t eraseBegin =
      static_cast<std::size_t>(index->offset + fourdgs::tool::kRecordHeaderSize + kShortLength);
  const std::size_t eraseEnd =
      static_cast<std::size_t>(index->offset + fourdgs::tool::kRecordHeaderSize + index->length);
  const std::uint64_t removed = eraseEnd - eraseBegin;
  writeU64(&bytes, static_cast<std::size_t>(index->offset + 1), kShortLength);
  bytes.erase(bytes.begin() + static_cast<std::ptrdiff_t>(eraseBegin),
              bytes.begin() + static_cast<std::ptrdiff_t>(eraseEnd));

  fourdgs::Result<Walk> shortened =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(shortened.ok());
  if (!shortened) return;
  const fourdgs::tool::Frame* footer = shortened->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr) return;
  const std::size_t footerContent =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize);
  const std::uint64_t summaryOffset = readU64(bytes, footerContent + 8);
  if (summaryOffset >= eraseEnd) writeU64(&bytes, footerContent + 8, summaryOffset - removed);
  resealSummary(&bytes);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool named = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("declares 39 content bytes") != std::string::npos &&
        finding.message.find("requires at least 40") != std::string::npos) {
      named = true;
    }
  }
  CHECK(named);
}

void summaryPlacementIsCheckedWithoutAChecksum() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  std::vector<fourdgs::tool::Frame> indexes;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()),
                               [&](const fourdgs::tool::Frame& frame, bool complete) {
                                 if (complete && frame.opcode == fourdgs::tool::op::kChunkIndex)
                                   indexes.push_back(frame);
                               });
  CHECK(walked.ok());
  CHECK(indexes.size() >= 2);
  if (!walked || indexes.size() < 2) return;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr) return;
  const std::size_t content =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize);
  writeU64(&bytes, content, indexes[1].offset);
  writeU32(&bytes, content + 16, 0);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  bool found = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("does not name the first Chunk Index record") != std::string::npos) {
      found = true;
    }
  }
  CHECK(found);
}

void modelSpecificAndBareStructureOpcodesAreRejected() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::uint8_t> original = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!original.empty());
  if (original.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* chunk = walked->firstIntact(fourdgs::tool::op::kChunk);
  CHECK(chunk != nullptr);
  if (chunk == nullptr) return;

  std::vector<std::uint8_t> delta = original;
  delta[static_cast<std::size_t>(chunk->offset)] = fourdgs::tool::op::kDeltaChunk;
  const Report deltaReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(delta.data(), delta.size()));
  bool rejectedDelta = false;
  for (const fourdgs::tool::Finding& finding : deltaReport.findings) {
    if (finding.message.find("Delta Chunk is legal only under keyframe-delta") !=
        std::string::npos) {
      rejectedDelta = true;
    }
  }
  CHECK(rejectedDelta);

  std::vector<std::uint8_t> attribute = original;
  attribute[static_cast<std::size_t>(chunk->offset)] = fourdgs::tool::op::kAttributeStream;
  const Report attributeReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(attribute.data(), attribute.size()));
  bool rejectedAttribute = false;
  for (const fourdgs::tool::Finding& finding : attributeReport.findings) {
    if (finding.message.find("Attribute Stream is a bare structure inside Chunk") !=
        std::string::npos) {
      rejectedAttribute = true;
    }
  }
  CHECK(rejectedAttribute);

  std::vector<std::uint8_t> attachmentIndex = original;
  attachmentIndex[static_cast<std::size_t>(chunk->offset)] = fourdgs::tool::op::kAttachmentIndex;
  const Report attachmentIndexReport = fourdgs::tool::validate(
      Span<const std::uint8_t>(attachmentIndex.data(), attachmentIndex.size()));
  bool rejectedAttachmentIndex = false;
  for (const fourdgs::tool::Finding& finding : attachmentIndexReport.findings) {
    if (finding.message.find("reserved opcode 0x0e") != std::string::npos) {
      rejectedAttachmentIndex = true;
    }
  }
  CHECK(rejectedAttachmentIndex);

  std::vector<std::uint8_t> reserved = original;
  reserved[static_cast<std::size_t>(chunk->offset)] = fourdgs::tool::op::kReservedZero;
  const Report reservedReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(reserved.data(), reserved.size()));
  bool rejectedReserved = false;
  for (const fourdgs::tool::Finding& finding : reservedReport.findings) {
    if (finding.message.find("uses reserved opcode 0x00") != std::string::npos) {
      rejectedReserved = true;
    }
  }
  CHECK(rejectedReserved);
}

class FailingSummaryReadable : public fourdgs::Readable {
 public:
  FailingSummaryReadable(std::vector<std::uint8_t> bytes, std::uint64_t failAt)
      : bytes_(std::move(bytes)), failAt_(failAt) {}

  fourdgs::Result<std::uint64_t> size() override { return bytes_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset == failAt_ && into.size() > fourdgs::tool::kRecordHeaderSize) {
      return Error(ErrorCode::kIo, "injected summary transport failure");
    }
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t available = bytes_.size() - static_cast<std::size_t>(offset);
    const std::size_t take = std::min(available, into.size());
    for (std::size_t i = 0; i < take; ++i) {
      into[i] = bytes_[static_cast<std::size_t>(offset) + i];
    }
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
  std::uint64_t failAt_;
};

void checksumReadFailuresAreNotReportedAsNoChecksum() {
  if (corpusMissing()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::tool::BorrowedReadable ordinary(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(ordinary);
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::Result<std::optional<fourdgs::tool::SummaryDeclaration>> summary =
      fourdgs::tool::summaryDeclaration(ordinary, *walked);
  CHECK(summary.ok());
  CHECK(summary.ok() && summary->has_value());
  if (!summary || !summary->has_value()) return;

  FailingSummaryReadable failing(std::move(bytes), summary->value().start);
  fourdgs::Result<std::optional<fourdgs::tool::Coverage>> covered =
      fourdgs::tool::coverage(failing, *walked);
  CHECK(!covered.ok());
  if (!covered) {
    CHECK(covered.error().message.find("injected summary transport failure") != std::string::npos);
  }
}

void footerDeclarationsNameShortRecordsAndTransportFailures() {
  if (corpusMissing()) return;
  std::vector<std::uint8_t> original = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!original.empty());
  if (original.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(original.data(), original.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr || footer->length < 20) return;

  std::vector<std::uint8_t> shortFooter = original;
  writeU64(&shortFooter, static_cast<std::size_t>(footer->offset + 1), 19);
  const std::size_t eraseBegin =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize + 19);
  const std::size_t eraseEnd =
      static_cast<std::size_t>(footer->offset + fourdgs::tool::kRecordHeaderSize + footer->length);
  shortFooter.erase(shortFooter.begin() + static_cast<std::ptrdiff_t>(eraseBegin),
                    shortFooter.begin() + static_cast<std::ptrdiff_t>(eraseEnd));
  const Report shortReport =
      fourdgs::tool::validate(Span<const std::uint8_t>(shortFooter.data(), shortFooter.size()));
  bool namedMinimum = false;
  for (const fourdgs::tool::Finding& finding : shortReport.findings) {
    if (finding.message.find("Footer record at byte") != std::string::npos &&
        finding.message.find("declares 19 content bytes") != std::string::npos &&
        finding.message.find("requires at least 20") != std::string::npos) {
      namedMinimum = true;
    }
  }
  CHECK(namedMinimum);

  FailingRangeReadable failing(std::move(original),
                               footer->offset + fourdgs::tool::kRecordHeaderSize);
  const Report failedRead = fourdgs::tool::validate(failing);
  CHECK(!failedRead.ok());
  CHECK(!failedRead.hasErrors());
  CHECK(!failedRead.complete);
  bool preserved = false;
  for (const fourdgs::tool::Finding& finding : failedRead.findings) {
    if (finding.message.find("Footer declaration could not be read") != std::string::npos &&
        finding.message.find("injected Header transport failure") != std::string::npos) {
      preserved = true;
    }
  }
  CHECK(preserved);
}

void anAppendedFooterFieldIsIncompleteRatherThanInvalid() {
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;
  const fourdgs::tool::Frame* footer = walked->firstIntact(fourdgs::tool::op::kFooter);
  CHECK(footer != nullptr);
  if (footer == nullptr || footer->length != 20) return;

  const std::size_t extensionAt = static_cast<std::size_t>(footer->offset + footer->total());
  bytes.insert(bytes.begin() + static_cast<std::ptrdiff_t>(extensionAt), 0xA5);
  writeU64(&bytes, static_cast<std::size_t>(footer->offset + 1), footer->length + 1);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool explained = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("extends the Footer beyond its version-1 prefix") !=
        std::string::npos) {
      explained = true;
    }
  }
  CHECK(explained);
}

void aFileMissingOnlyItsTrailingMagicIsNotInspectedCleanly() {
  // Cut exactly on a record boundary, which is the shape `head -c` produces without needing to
  // land anywhere lucky: every record is whole, so the walk has no cut to report and only the
  // closing magic is gone. This used to print the note and exit 0, telling a script the
  // incomplete file was fine.
  if (corpusMissing()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(bytes.size() > fourdgs::tool::kMagicSize);
  if (bytes.size() <= fourdgs::tool::kMagicSize) return;
  bytes.resize(bytes.size() - fourdgs::tool::kMagicSize);

  const std::filesystem::path cut =
      std::filesystem::temp_directory_path() / "fourdgs-test-no-trailing-magic.4dgs";
  {
    std::ofstream stream(cut, std::ios::binary);
    stream.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
  }
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (walked) {
    // The precondition the check is about: no cut, and no trailing magic.
    CHECK(!walked->cut.has_value());
    CHECK(!walked->trailingMagic);
  }
  const Run result = run({"inspect", cut.string()});
  CHECK_EQ(result.code, fourdgs::tool::kExitFailed);
  CHECK(result.outContains("the file does not end with the magic"));
  std::filesystem::remove(cut);
}

void anIndexEntryAtTheEndOfTheFileIsRefusedRatherThanDereferenced() {
  // `chunk_offset == size`, `chunk_length == 0`: the end is exactly the end of the file, so an
  // arithmetic bounds check passes and the opcode read that follows is one byte past the last.
  // These are untrusted bytes off the file being validated.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;

  // Point the first index entry's `chunk_offset` at the byte after the file, and its length at 0.
  const fourdgs::tool::Frame* entry = walked->first(fourdgs::tool::op::kChunkIndex);
  CHECK(entry != nullptr);
  if (entry == nullptr) return;
  const std::size_t field =
      static_cast<std::size_t>(entry->offset + fourdgs::tool::kRecordHeaderSize + 16);
  CHECK(field + 16 <= bytes.size());
  if (field + 16 > bytes.size()) return;
  const std::uint64_t size = bytes.size();
  for (int i = 0; i < 8; ++i) {
    bytes[field + i] = static_cast<std::uint8_t>((size >> (8 * i)) & 0xFF);
  }
  for (int i = 0; i < 8; ++i) bytes[field + 8 + i] = 0;

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  bool pointsPastTheEnd = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("points past the end of the file") != std::string::npos) {
      pointsPastTheEnd = true;
    }
  }
  CHECK(pointsPastTheEnd);
}

void aFileCutInsideItsFirstRecordStillSaysWhereItWasCut() {
  // Nothing intact, so the "no records at all" error fires — and used to be the whole answer,
  // returning before the note that carries the byte, the record and the declared length.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(bytes.size() > 32);
  if (bytes.size() <= 32) return;
  // The magic, then the Header's nine framing bytes and four of its content: a first record whose
  // declared length runs past the end of what is here.
  bytes.resize(fourdgs::tool::kMagicSize + fourdgs::tool::kRecordHeaderSize + 4);

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(!report.ok());
  bool noRecords = false;
  bool saidWhereItWasCut = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message == "no records at all") noRecords = true;
    if (finding.message.find("the file is cut at byte ") != std::string::npos) {
      saidWhereItWasCut = true;
      // Not just that it stopped: the record and the length that is the fault.
      CHECK(finding.message.find("the Header record declares ") != std::string::npos);
    }
  }
  CHECK(noRecords);
  CHECK(saidWhereItWasCut);
}

void aShortReadIsTruncationRatherThanAnInventedRecord() {
  // A resource that reports one size and then reads short. The magic never arrives whole, so a
  // walk that trusted the requested length would compare partly-unwritten bytes and report "not a
  // 4dgs file" — sending its reader after the wrong problem entirely.
  std::vector<std::uint8_t> bytes(64, 0x11);
  for (std::size_t i = 0; i < fourdgs::tool::kMagicSize; ++i) {
    bytes[i] = fourdgs::tool::kMagic[i];
  }
  ShortReadable stingy(bytes, /*claimed=*/64, /*cap=*/4);
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(stingy);
  CHECK(!walked.ok());
  if (!walked) {
    CHECK_EQ(static_cast<int>(walked.error().code), static_cast<int>(ErrorCode::kTruncated));
    CHECK(walked.error().message.find("shorter than the magic") != std::string::npos);
  }

  // And past the magic: a record header is nine bytes, and a transport that hands over eight of
  // them must not become an opcode plus a declared length.
  ShortReadable partial(bytes, /*claimed=*/64, /*cap=*/8);
  fourdgs::Result<Walk> framed = fourdgs::tool::walk(partial);
  CHECK(framed.ok());
  if (framed) {
    CHECK_EQ(framed->recordCount, static_cast<std::uint64_t>(0));
    CHECK(framed->cut.has_value());
  }
}

class FailingFramingReadable : public fourdgs::Readable {
 public:
  explicit FailingFramingReadable(std::vector<std::uint8_t> bytes) : bytes_(std::move(bytes)) {}

  fourdgs::Result<std::uint64_t> size() override { return bytes_.size(); }

  fourdgs::Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override {
    if (offset == fourdgs::tool::kMagicSize) {
      return Error(ErrorCode::kIo, "injected framing transport failure");
    }
    if (offset >= bytes_.size()) return static_cast<std::size_t>(0);
    const std::size_t take =
        std::min(into.size(), bytes_.size() - static_cast<std::size_t>(offset));
    std::copy_n(bytes_.begin() + static_cast<std::size_t>(offset), take, into.data());
    return take;
  }

 private:
  std::vector<std::uint8_t> bytes_;
};

void aFramingTransportFailureIsNotReportedAsAFileCut() {
  std::vector<std::uint8_t> bytes(fourdgs::tool::kMagic,
                                  fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  bytes.push_back(0x80);
  bytes.insert(bytes.end(), 8, 0);
  bytes.insert(bytes.end(), fourdgs::tool::kMagic,
               fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  FailingFramingReadable source(std::move(bytes));
  fourdgs::Result<Walk> walked = fourdgs::tool::walk(source);
  CHECK(!walked.ok());
  if (!walked) {
    CHECK_EQ(static_cast<int>(walked.error().code), static_cast<int>(ErrorCode::kIo));
    CHECK(walked.error().message.find("injected framing transport failure") != std::string::npos);
  }

  std::vector<std::uint8_t> validationBytes(fourdgs::tool::kMagic,
                                            fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  validationBytes.push_back(0x80);
  validationBytes.insert(validationBytes.end(), 8, 0);
  validationBytes.insert(validationBytes.end(), fourdgs::tool::kMagic,
                         fourdgs::tool::kMagic + fourdgs::tool::kMagicSize);
  FailingFramingReadable validationSource(std::move(validationBytes));
  const Report report = fourdgs::tool::validate(validationSource);
  CHECK(!report.ok());
  CHECK(!report.hasErrors());
  CHECK(!report.complete);
  bool toolFailure = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("cannot walk the input resource framing") != std::string::npos &&
        finding.message.find("injected framing transport failure") != std::string::npos) {
      toolFailure = true;
    }
  }
  CHECK(toolFailure);
}

void aDuplicateFrontMatterRecordLeavesTheRefusalUnplaced() {
  // Two Headers, and a refusal named for one of them. Which copy the reader refused at is not
  // something a framing walk can know, and an offset pointing at a record with nothing wrong with
  // it is worse than no offset because a reader believes it.
  Walk one;
  one.representatives.push_back(fourdgs::tool::Frame{fourdgs::tool::op::kHeader, 8, 100});
  one.opcodeCounts[fourdgs::tool::op::kHeader] = 1;
  one.intactOpcodeCounts[fourdgs::tool::op::kHeader] = 1;
  const Error refusal(ErrorCode::kUnsupported, "the Header declares temporal model 'x'",
                      std::string("unknown-temporal-model"));
  const std::optional<Named> placed = fourdgs::tool::describe(refusal, &one, std::nullopt);
  CHECK(placed.has_value());
  if (placed.has_value()) {
    CHECK(placed->site.has_value());
    if (placed->site.has_value()) CHECK_EQ(placed->site->offset, static_cast<std::uint64_t>(8));
  }

  Walk two = one;
  two.representatives.push_back(fourdgs::tool::Frame{fourdgs::tool::op::kHeader, 117, 100});
  two.opcodeCounts[fourdgs::tool::op::kHeader] = 2;
  two.intactOpcodeCounts[fourdgs::tool::op::kHeader] = 2;
  const std::optional<Named> ambiguous = fourdgs::tool::describe(refusal, &two, std::nullopt);
  // Still named — the identifier is the reader's and is not in doubt — and no longer placed.
  CHECK(ambiguous.has_value());
  if (ambiguous.has_value()) {
    CHECK_EQ(ambiguous->code, std::string("unknown-temporal-model"));
    CHECK(!ambiguous->site.has_value());
  }
}

void aRecordAfterTheFooterIsReportedWithoutMovingTheVerdict() {
  // Spec section 4: the Footer MUST be the last record. Neither the Python reference validator
  // nor the Rust one checks it, so this is a note — the fact is reported and the verdict stays
  // the reference's, because a validator that alone calls a file invalid is the disagreement the
  // whole epic is about.
  if (corpusMissing()) return;
  std::vector<std::uint8_t> bytes = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(bytes.size() > fourdgs::tool::kMagicSize);
  if (bytes.size() <= fourdgs::tool::kMagicSize) return;

  // A private record, empty, wedged between the Footer and the closing magic. The summary
  // checksum covers only up to where the Footer begins, so it is untouched by this.
  std::vector<std::uint8_t> spliced(bytes.begin(), bytes.end() - fourdgs::tool::kMagicSize);
  spliced.push_back(0x80);
  for (int i = 0; i < 8; ++i) spliced.push_back(0);
  for (std::size_t i = 0; i < fourdgs::tool::kMagicSize; ++i) {
    spliced.push_back(fourdgs::tool::kMagic[i]);
  }

  const Report report =
      fourdgs::tool::validate(Span<const std::uint8_t>(spliced.data(), spliced.size()));
  bool saidFooterIsNotLast = false;
  for (const fourdgs::tool::Finding& finding : report.findings) {
    if (finding.message.find("the Footer must be the last record") != std::string::npos) {
      saidFooterIsNotLast = true;
      CHECK(finding.severity == Severity::kNote);
    }
  }
  CHECK(saidFooterIsNotLast);
}

void aBandThatWillNotDecodeIsRefusedAndPlacedAtItsOwnRecord() {
  // #168's finding, in the language it was found in. Every SH band is its own record with its own
  // stream header, addressed by byte range so a reader that has capped its degree never transfers
  // the higher ones — which is exactly what hid them from this validator. A scan at band 0 fetches
  // no band record at all, so a file whose band 2 will not decode came back `valid`, exit 0.
  //
  // The mutation is `invalid.py`'s own: the codec byte of a stream header set to 9, which the
  // registry reserves, so it is legal-but-unimplemented rather than nonsense — an
  // `unknown-stream-codec` refusal and not a corrupt-payload one.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::filesystem::path source =
      corpusDirectory() / "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs";
  std::vector<std::uint8_t> bytes = readBytes(source);
  CHECK(!bytes.empty());
  if (bytes.empty()) return;

  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(walked.ok());
  if (!walked) return;

  // The band ranges come out of the file's own index, which is where the tool reads them too.
  fourdgs::tool::BorrowedReadable reader(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  fourdgs::Result<std::vector<fourdgs::tool::IndexEntry>> parsedIndex =
      fourdgs::tool::chunkIndexEntries(reader, *walked);
  CHECK(parsedIndex.ok());
  if (!parsedIndex) return;
  const std::vector<fourdgs::tool::IndexEntry>& index = *parsedIndex;
  CHECK(!index.empty());
  if (index.empty()) return;
  const fourdgs::tool::BandRange* band = index[0].bandRange(2);
  CHECK(band != nullptr);
  if (band == nullptr) return;

  // Inside the band's record: nine framing bytes, the band number, then the stream header whose
  // fourth byte is the codec — `attribute_id, symbol_width, mode, [codec]`.
  const std::size_t codecByte =
      static_cast<std::size_t>(band->offset + fourdgs::tool::kRecordHeaderSize + 1 + 3);
  CHECK(codecByte < bytes.size());
  if (codecByte >= bytes.size()) return;

  // The file is valid before the patch: without this the check below could pass on a file that
  // was already being refused for some other reason.
  const Report before =
      fourdgs::tool::validate(Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(before.ok());

  bytes[codecByte] = 0x09;
  const std::filesystem::path patched =
      std::filesystem::temp_directory_path() / "fourdgs-test-bad-band.4dgs";
  {
    std::ofstream stream(patched, std::ios::binary);
    stream.write(reinterpret_cast<const char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
  }

  // End to end, through the tool: the identifier, the byte, the band, and the exit code.
  const Run result = run({"validate", patched.string()});
  CHECK_EQ(result.code, fourdgs::tool::kExitFailed);
  // Exact equality on the identifier, read from the corpus rather than restated here — this is
  // the same string the seven invalid variants are compared by.
  const std::string expected =
      expectedRefusal(corpusDirectory() / "invalid" / "UnknownStreamCodec.json");
  CHECK_EQ(expected, std::string("unknown-stream-codec"));
  CHECK(result.outContains("refusal " + expected + " at byte " + std::to_string(band->offset) +
                           " (the SH Band Stream record for band 2"));
  if (!result.outContains("refusal " + expected + " at byte ")) {
    std::fprintf(stderr, "  patched band said: %s", result.out.c_str());
  }
  std::filesystem::remove(patched);
}

void commasMatchThePythonToolsThousandsSeparator() {
  CHECK_EQ(fourdgs::tool::commas(0), std::string("0"));
  CHECK_EQ(fourdgs::tool::commas(999), std::string("999"));
  CHECK_EQ(fourdgs::tool::commas(1000), std::string("1,000"));
  CHECK_EQ(fourdgs::tool::commas(9896), std::string("9,896"));
  CHECK_EQ(fourdgs::tool::commas(1234567), std::string("1,234,567"));
}

}  // namespace

void runTests() {
  everyInvalidVariantIsRefusedByItsOwnIdentifier();
  aConformingCaptureIsValid();
  aConformingKeyframeDeltaFileIsNotMisclassified();
  keyframeDeltaHeaderCountIsTheLifetimeDistinctIdentityCount();
  identitySinkIoIsNotCalledAnInputReadFailure();
  validatorToolFailuresNameTheirActualCause();
  identityPartitionCloseFailureIsIo();
  anEarlyKeyframeRefusalRemovesIdentityScratchStorage();
  aReusedIdentityNamesItsSecondIntroductionRecord();
  everyValidVariantIsValid();
  aWalkFramesEveryRecordAndEndsOnTheMagic();
  aCutFileReportsTheIntactPrefixAndTheByte();
  inspectPrintsOneRowPerRecordAndReportsACut();
  theToolCouldNotRunHasItsOwnExitCode();
  anErrorTheRefusalTableDoesNotNameIsNotGivenAnIdentifier();
  inspectTransportFailuresUseTheToolFailureExit();
  theDisplayFormCarriesTheCodeAndTheByte();
  opcodeNamesCoverTheOpenRanges();
  aWalkRetainsBoundedFactsForUnboundedPrivateRecords();
  aLongHeaderIsRangeParsedThroughItsTemporalModel();
  aTemporalModelTransportFailureMakesValidationIncomplete();
  aChunkIndexTransportFailureMakesValidationIncomplete();
  aLaterIndexResolutionTransportFailureMakesValidationIncomplete();
  aKeyframeDeltaPayloadTransportFailurePreservesCause();
  anUnindexedKeyframeDeltaIsCertifiedFrontToBack();
  anUnindexedFileStillReceivesAFrontMatterVerdict();
  duplicateHeadersAreRejectedBeforeModelDispatch();
  anEmbeddedChunkOpcodeIsNotARecordBoundary();
  anOrphanChunkIsDecodedByTheStreamedValidationPass();
  anUnindexedPhysicalBandIsRejected();
  duplicateFootersAndIndexEntriesAreRejected();
  inspectReadsRangesRatherThanTheWholeFile();
  keyframeDeltaValidationDoesNotReadTheWholeResource();
  indexedBandRangesMustNameWholeTopLevelRecords();
  indexMetadataMustMatchThePointedRecords();
  indexedBandsMustMatchTheirRecordsAndOwners();
  skippedExtensionsPreservePhysicalBandOwnership();
  emptyIndexedBandsAreMalformedRatherThanIncomplete();
  decodeFrontMatterAfterStateIsRejected();
  modernAudioAfterStateIsRejected();
  reservedHeaderFlagBitsAreRejected();
  indexedCoreSummaryMemoryIsBounded();
  undersizedChunkIndexesNameTheirDeclaredSize();
  summaryPlacementIsCheckedWithoutAChecksum();
  modelSpecificAndBareStructureOpcodesAreRejected();
  checksumReadFailuresAreNotReportedAsNoChecksum();
  footerDeclarationsNameShortRecordsAndTransportFailures();
  anAppendedFooterFieldIsIncompleteRatherThanInvalid();
  aFileMissingOnlyItsTrailingMagicIsNotInspectedCleanly();
  anIndexEntryAtTheEndOfTheFileIsRefusedRatherThanDereferenced();
  aFileCutInsideItsFirstRecordStillSaysWhereItWasCut();
  aShortReadIsTruncationRatherThanAnInventedRecord();
  aFramingTransportFailureIsNotReportedAsAFileCut();
  aDuplicateFrontMatterRecordLeavesTheRefusalUnplaced();
  aRecordAfterTheFooterIsReportedWithoutMovingTheVerdict();
  aBandThatWillNotDecodeIsRefusedAndPlacedAtItsOwnRecord();
  commasMatchThePythonToolsThousandsSeparator();
}

TEST_MAIN
