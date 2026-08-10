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
#include <sstream>
#include <string>
#include <vector>

#include "check.hpp"
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
  if (std::filesystem::is_directory(corpusDirectory() / "invalid")) return false;
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

/// Every `.4dgs` in a corpus directory, sorted so a failure names the same file twice running.
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

void aConformingKeyframeDeltaFileIsValid() {
  // It is not, in the Python validator: every structural check there assumes the
  // gaussian-birth chunk shape, so a file whose Chunks are keyframes and whose Delta Chunks are
  // differences comes back invalid. The core implements the model — the conformance suite
  // proves it — so refusing a file for declaring it was never a statement about the file.
  if (corpusMissing()) return;
  if (noDecoder()) return;
  const std::vector<std::filesystem::path> files = variants(corpusDirectory() / "keyframe");
  CHECK(!files.empty());
  for (const std::filesystem::path& file : files) {
    const Run result = run({"validate", file.string()});
    CHECK_EQ(result.code, fourdgs::tool::kExitOk);
    CHECK(!result.outContains("error:"));
    if (result.outContains("error:")) {
      std::fprintf(stderr, "  %s said: %s", file.filename().string().c_str(), result.out.c_str());
    }
  }
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
    // 0, or 2 for the three variants that carry no chunk index and warn about it. Never 1.
    CHECK(result.code == fourdgs::tool::kExitOk || result.code == fourdgs::tool::kExitWarnings);
    if (result.code == fourdgs::tool::kExitFailed) {
      std::fprintf(stderr, "  %s said: %s", file.filename().string().c_str(), result.out.c_str());
    }
  }
}

void aWalkFramesEveryRecordAndEndsOnTheMagic() {
  if (corpusMissing()) return;
  const std::vector<std::uint8_t> data = readBytes(corpusDirectory() / kProvenanceVariant);
  CHECK(!data.empty());
  fourdgs::Result<Walk> walked =
      fourdgs::tool::walkBytes(Span<const std::uint8_t>(data.data(), data.size()));
  CHECK(walked.ok());
  if (!walked) return;
  CHECK(walked->trailingMagic);
  CHECK(!walked->cut.has_value());
  CHECK(walked->first(fourdgs::tool::op::kHeader) != nullptr);
  CHECK(walked->first(fourdgs::tool::op::kFooter) != nullptr);
  // Every record accounted for, back to back: the offsets have to tile the file.
  std::uint64_t at = fourdgs::tool::kMagicSize;
  for (const fourdgs::tool::Frame& frame : walked->records) {
    CHECK_EQ(frame.offset, at);
    at += frame.total();
  }
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
  CHECK(!cut->records.empty());
  CHECK(cut->records.size() < whole->records.size());
  CHECK_EQ(cut->intact(), cut->records.size() - 1);

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
  aConformingKeyframeDeltaFileIsValid();
  everyValidVariantIsValid();
  aWalkFramesEveryRecordAndEndsOnTheMagic();
  aCutFileReportsTheIntactPrefixAndTheByte();
  inspectPrintsOneRowPerRecordAndReportsACut();
  theToolCouldNotRunHasItsOwnExitCode();
  anErrorTheRefusalTableDoesNotNameIsNotGivenAnIdentifier();
  theDisplayFormCarriesTheCodeAndTheByte();
  opcodeNamesCoverTheOpenRanges();
  commasMatchThePythonToolsThousandsSeparator();
}

TEST_MAIN
