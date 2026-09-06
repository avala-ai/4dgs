// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: indexed decode.
///
/// The footer, then the index, then only the byte ranges the index names — the path a
/// seeking client takes, forced rather than left to the opener, and producing the same
/// canonical JSON the streamed runner does. Agreeing with itself across two different read
/// paths is most of what makes an indexed implementation trustworthy.
///
/// That applies to refusals too, and it is why the invalid corpus is read both ways: the two
/// paths reach the Header by different routes — one front to back, one through the Footer —
/// and a check placed on only one of them refuses half the files it should. A refused file
/// prints `{"refused": "<id>"}` and exits 0, exactly as it does streamed.

#include <charconv>
#include <cstdio>
#include <cstring>
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
using fourdgs::ReadMode;
using fourdgs::ReadOptions;
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
  if (error.code == ErrorCode::kResourceLimit) {
    std::printf("{\"unsupported\":\"resource-limit\"}\n");
    return 0;
  }
  if (!error.refusal.has_value()) return fail(error.toString());
  std::printf("%s\n", fourdgs::conformance::refusalJson(*error.refusal).c_str());
  return 0;
}

bool parseArguments(int argc, char** argv, std::string* path, ReadOptions* options) {
  if (argc == 2) {
    *path = argv[1];
    return true;
  }
  if (argc != 4 || std::strcmp(argv[1], "--max-decoded-state-bytes") != 0) return false;

  std::uint64_t limit = 0;
  const char* begin = argv[2];
  const char* end = begin + std::strlen(begin);
  const std::from_chars_result parsed = std::from_chars(begin, end, limit, 10);
  if (parsed.ec != std::errc() || parsed.ptr != end || limit == 0) return false;
  options->maxDecodedStateBytes = limit;
  *path = argv[3];
  return true;
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

/// A chunk read costs exactly what the index says, and a band cap removes bytes from the
/// wire rather than values after they arrive.
///
/// Counted at the transport, because that is the claim: not that the coefficients are
/// dropped after arriving, but that their bytes were never asked for. One chunk at a time,
/// because `loadAt` cannot isolate a chunk when intervals overlap — and each measurement
/// gets its own scene, because a decoder that has already fetched a range does not fetch it
/// twice, which is correct and would otherwise look identical to never fetching it.
Result<void> checkChunkCost(const std::string& path, Scene& scene) {
  // Every cap is worth measuring only where there are bands to skip; without spherical
  // harmonics all four describe the same bytes.
  const int caps = scene.shDegree() > 0 ? 3 : 0;

  for (std::uint32_t i = 0; i < scene.chunkCount(); ++i) {
    std::uint64_t previous = 0;
    for (int cap = 0; cap <= caps; ++cap) {
      Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
      if (!file) return file.error();
      std::unique_ptr<fourdgs::FileReadable> raw(*file);
      fourdgs::CountingReadable counting(raw.get());

      Result<std::unique_ptr<Scene>> fresh = Scene::open(counting, ReadMode::kIndexed);
      if (!fresh) return fresh.error();
      const std::uint64_t predicted = (*fresh)->bytesForChunk(i, cap);
      const std::uint64_t before = counting.bytesRead();
      Result<void> loaded = (*fresh)->loadChunk(i, cap);
      if (!loaded) {
        // A legal request on the wrong path is a skip, not a failure.
        if (loaded.error().code == ErrorCode::kUnsupportedMode) return Result<void>();
        return loaded.error();
      }
      const std::uint64_t moved = counting.bytesRead() - before;

      if (moved != predicted) {
        return Error(ErrorCode::kMalformed,
                     "reading chunk " + std::to_string(i) + " with maxShBand=" +
                         std::to_string(cap) + " transferred " + std::to_string(moved) +
                         " bytes, the index says " + std::to_string(predicted));
      }
      if (predicted < previous) {
        return Error(ErrorCode::kMalformed,
                     "raising the band cap to " + std::to_string(cap) + " on chunk " +
                         std::to_string(i) + " transferred fewer bytes, " +
                         std::to_string(predicted) + " against " + std::to_string(previous));
      }
      previous = predicted;
    }
  }
  return Result<void>();
}

}  // namespace

int main(int argc, char** argv) {
  std::string path;
  ReadOptions options;
  if (!parseArguments(argc, argv, &path, &options)) {
    std::fprintf(stderr, "usage: decode_indexed [--max-decoded-state-bytes N] <file.4dgs>\n");
    return 2;
  }

  // keyframe-delta dispatch, before opening: an opened Scene refuses the model. The indexed
  // read path walks each instant's chain through the index; the JSON is computed in Rust and
  // printed verbatim, and it must equal what the streamed runner prints for the same file.
  Result<std::vector<std::uint8_t>> whole = readWhole(path);
  if (!whole) return fail(whole.error().toString());
  Result<std::string> model =
      fourdgs::peekTemporalModel(fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()));
  // A file refused this early — bad magic, a major version from the future — never reaches a
  // Scene, so the refusal is answered here as well as below.
  if (!model) return refusedOrFailed(model.error());
  Result<std::optional<std::string>> marker = fourdgs::peekHeaderAttribute(
      fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()), "conformance");
  if (!marker) return refusedOrFailed(marker.error());
  const bool optionalIdentity =
      marker->has_value() && fourdgs::conformance::isOptionalIdentityWitness(**marker);
  if (*model == "keyframe-delta") {
    Result<std::string> json =
        optionalIdentity ? fourdgs::keyframeDeltaIdentityStatesJson(
                               fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()),
                               /*indexed=*/true, options)
                         : fourdgs::keyframeDeltaStatesJson(
                               fourdgs::Span<const std::uint8_t>(whole->data(), whole->size()),
                               /*indexed=*/true, options);
    if (!json) return refusedOrFailed(json.error());
    std::printf("%s\n", json->c_str());
    return 0;
  }

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> raw(*file);
  fourdgs::CountingReadable source(raw.get());

  Result<std::unique_ptr<Scene>> opened = Scene::open(source, options, ReadMode::kIndexed);
  if (!opened) return refusedOrFailed(opened.error());
  Scene& scene = **opened;

  // The summary comes from a whole-scene load rather than from concatenating a seek per
  // entry: chunk intervals overlap by design — a scene is chunked at several temporal
  // resolutions, so [0, 2), [0, 1) and [0, 0.5) all contain t = 0 — and summing them would
  // count the same gaussians repeatedly and report a scene the file does not describe. The
  // seek path is exercised on its own terms in checkChunkCost.
  //
  // It is also where the last of the named refusals fires: not every rule is checked at open,
  // and a window index past the end of its table is a record read during the load.
  Result<void> loaded = scene.loadAll(3, options);
  if (!loaded) return refusedOrFailed(loaded.error());
  if (optionalIdentity) {
    const fourdgs::GaussianView gaussians = scene.gaussians();
    std::printf("%s\n", fourdgs::conformance::optionalIdentityGaussianBirthJson(gaussians).c_str());
    return 0;
  }
  fourdgs::conformance::SceneRecords records;
  Result<void> collected = fourdgs::conformance::collectRecords(scene, &records);
  if (!collected) return refusedOrFailed(collected.error());

  // After the records, not before: `objectsJson` decodes the whole population and
  // invalidates any view taken earlier. It happens to be a no-op here — the scene is
  // already loaded whole — and depending on that is exactly how this becomes a dangling
  // read the day the order above changes.
  const fourdgs::GaussianView gaussians = scene.gaussians();

  Result<void> costs = checkChunkCost(path, scene);
  if (!costs) return fail(costs.error().toString());

  std::printf(
      "%s\n",
      fourdgs::conformance::canonical(fourdgs::conformance::summaryOf(records, gaussians)).c_str());
  return 0;
}
