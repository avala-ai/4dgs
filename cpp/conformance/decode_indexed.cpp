// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: indexed decode.
///
/// The footer, then the index, then only the byte ranges the index names — the path a
/// seeking client takes, forced rather than left to the opener, and producing the same
/// canonical JSON the streamed runner does. Agreeing with itself across two different read
/// paths is most of what makes an indexed implementation trustworthy.

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
using fourdgs::ReadMode;
using fourdgs::Result;
using fourdgs::Scene;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
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
  if (argc != 2) {
    std::fprintf(stderr, "usage: decode_indexed <file.4dgs>\n");
    return 2;
  }
  const std::string path = argv[1];

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> raw(*file);
  fourdgs::CountingReadable source(raw.get());

  Result<std::unique_ptr<Scene>> opened = Scene::open(source, ReadMode::kIndexed);
  if (!opened) return fail(opened.error().toString());
  Scene& scene = **opened;

  // The summary comes from a whole-scene load rather than from concatenating a seek per
  // entry: chunk intervals overlap by design — a scene is chunked at several temporal
  // resolutions, so [0, 2), [0, 1) and [0, 0.5) all contain t = 0 — and summing them would
  // count the same gaussians repeatedly and report a scene the file does not describe. The
  // seek path is exercised on its own terms in checkChunkCost.
  Result<void> loaded = scene.loadAll(3);
  if (!loaded) return fail(loaded.error().toString());
  const fourdgs::GaussianView gaussians = scene.gaussians();

  fourdgs::conformance::SceneRecords records;
  Result<void> collected = fourdgs::conformance::collectRecords(scene, &records);
  if (!collected) return fail(collected.error().toString());

  Result<void> costs = checkChunkCost(path, scene);
  if (!costs) return fail(costs.error().toString());

  std::printf(
      "%s\n",
      fourdgs::conformance::canonical(fourdgs::conformance::summaryOf(records, gaussians)).c_str());
  return 0;
}
