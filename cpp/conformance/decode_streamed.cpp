// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: streamed decode, canonical JSON to stdout.
///
/// Front to back, no seeking — the path forced rather than left to the opener, because two
/// runners that both take whatever the automatic choice picked would test one path twice.
/// The whole interface between an implementation and the harness is this: take a path, print
/// the canonical JSON. Anything wrong exits non-zero with a sentence on stderr, and the
/// harness reports it like a diff.
///
/// A refused file is the exception, and it is not "anything wrong": the invalid corpus is
/// files this reader is *supposed* to reject, so a refusal whose rule the specification names
/// prints `{"refused": "<id>"}` and exits 0. Exiting non-zero instead would make "refused for
/// the right reason" and "fell over in the right place" one outcome.

#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "canonical.hpp"
#include "fourdgs/fourdgs.hpp"
#include "scene_summary.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::GaussianView;
using fourdgs::ReadMode;
using fourdgs::Result;
using fourdgs::Scene;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

/// The answer for a file the reader would not decode.
///
/// An error carrying an identifier is a refusal the specification names, and it is printed as
/// the run's result. An error without one — an unreadable path, a file cut short, an internal
/// mistake — is a failure and stays on stderr: there is no rule for the suite to check, and
/// dressing it up as a refusal would let a broken runner answer every invalid variant.
int refusedOrFailed(const Error& error) {
  if (!error.refusal.has_value()) return fail(error.toString());
  std::printf("%s\n", fourdgs::conformance::refusalJson(*error.refusal).c_str());
  return 0;
}

Result<std::vector<std::uint8_t>> readWhole(const std::string& path) {
  std::FILE* handle = std::fopen(path.c_str(), "rb");
  if (handle == nullptr) return Error(ErrorCode::kIo, "cannot open " + path);
  std::vector<std::uint8_t> bytes;
  std::uint8_t buffer[65536];
  std::size_t got = 0;
  while ((got = std::fread(buffer, 1, sizeof(buffer), handle)) > 0) {
    bytes.insert(bytes.end(), buffer, buffer + got);
  }
  std::fclose(handle);
  return bytes;
}

/// What a cut file decodes to: how many gaussians survived, and whether it said so.
struct Cut {
  std::size_t count = 0;
  bool truncated = false;
};

Result<Cut> decodeCut(const std::vector<std::uint8_t>& bytes) {
  Result<std::unique_ptr<Scene>> opened = Scene::openMemory(
      fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size()), ReadMode::kSequential);
  if (!opened) return opened.error();
  Result<void> loaded = (*opened)->loadAll(3);
  if (!loaded) return loaded.error();
  Cut cut;
  cut.count = (*opened)->gaussians().count;
  cut.truncated = (*opened)->truncated();
  return cut;
}

/// Decode the same file cut short, and insist on what survives.
///
/// Nothing in the corpus is truncated, so this makes one. The canonical JSON cannot express
/// truncation recovery — a cut file is a different file — so the check lives here, where a
/// failure exits non-zero and the harness reports it like any other.
Result<void> checkTruncationRecovery(const std::vector<std::uint8_t>& bytes, std::size_t full) {
  if (bytes.size() < 16) return Error(ErrorCode::kInvalidArgument, "the file is too short to cut");

  // Cut before the trailing magic. Everything the file said is still in it, so nothing may
  // be lost — a reader that needs the trailing magic to finish is a reader that cannot read
  // a file still being written — and the reader must report that it was cut.
  Result<Cut> tail = decodeCut(std::vector<std::uint8_t>(bytes.begin(), bytes.end() - 8));
  if (!tail) return tail.error();
  if (!tail->truncated) {
    return Error(ErrorCode::kMalformed,
                 "a file cut before its trailing magic was not reported truncated");
  }
  if (tail->count != full) {
    return Error(ErrorCode::kMalformed,
                 "cutting the trailing magic lost gaussians: " + std::to_string(tail->count) +
                     " of " + std::to_string(full));
  }

  // Cut in the middle. What survives is what preceded the cut: no more than the whole file
  // had, and reported as truncated rather than passed off as a complete short scene.
  if (full > 1) {
    Result<Cut> half = decodeCut(std::vector<std::uint8_t>(
        bytes.begin(), bytes.begin() + static_cast<long>(bytes.size() / 2)));
    if (!half) return half.error();
    if (!half->truncated) {
      return Error(ErrorCode::kMalformed, "half a file was not reported truncated");
    }
    if (half->count > full) {
      return Error(ErrorCode::kMalformed, "half a file decoded more gaussians than all of it: " +
                                              std::to_string(half->count) + " against " +
                                              std::to_string(full));
    }
  }
  return Result<void>();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: decode_streamed <file.4dgs>\n");
    return 2;
  }
  const std::string path = argv[1];

  // Dispatch on the temporal model before opening: keyframe-delta is a whole-file format an
  // opened Scene refuses, decoded through the core's byte-in / string-out surface. The JSON
  // is computed in Rust and printed verbatim, so it is byte-identical to every other SDK's.
  Result<std::vector<std::uint8_t>> whole = readWhole(path);
  if (!whole) return fail(whole.error().toString());
  Result<std::string> model =
      fourdgs::peekTemporalModel(fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()));
  // A file refused this early — bad magic, a major version from the future — never reaches a
  // Scene, so the refusal is answered here as well as below.
  if (!model) return refusedOrFailed(model.error());
  if (*model == "keyframe-delta") {
    Result<std::string> json = fourdgs::keyframeDeltaStatesJson(
        fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()), /*indexed=*/false);
    if (!json) return refusedOrFailed(json.error());
    std::printf("%s\n", json->c_str());
    return 0;
  }

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> source(*file);

  Result<std::unique_ptr<Scene>> opened = Scene::open(*source, ReadMode::kSequential);
  if (!opened) return refusedOrFailed(opened.error());
  Scene& scene = **opened;
  if (scene.isIndexed()) {
    return fail("asked for the sequential path and got the indexed one");
  }

  // Not every rule fires at open: a window index past the end of its table is a record read
  // during the load, and a refusal the suite would miss if only the open were answered.
  Result<void> loaded = scene.loadAll(3);
  if (!loaded) return refusedOrFailed(loaded.error());
  fourdgs::conformance::SceneRecords records;
  Result<void> collected = fourdgs::conformance::collectRecords(scene, &records);
  if (!collected) return refusedOrFailed(collected.error());

  // After the records, not before: `objectsJson` decodes the whole population and
  // invalidates any view taken earlier. It happens to be a no-op here — the scene is
  // already loaded whole — and depending on that is exactly how this becomes a dangling
  // read the day the order above changes.
  const GaussianView gaussians = scene.gaussians();

  Result<std::vector<std::uint8_t>> bytes = readWhole(path);
  if (!bytes) return fail(bytes.error().toString());
  Result<void> recovery = checkTruncationRecovery(*bytes, gaussians.count);
  if (!recovery) return fail(recovery.error().toString());

  std::printf(
      "%s\n",
      fourdgs::conformance::canonical(fourdgs::conformance::summaryOf(records, gaussians)).c_str());
  return 0;
}
