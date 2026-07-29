// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: indexed decode.
///
/// Reads the footer, then the index, then the byte ranges the index names — the path a
/// seeking client takes — and produces the same canonical JSON the streamed runner does.
/// Agreeing with itself across two different read paths is most of what makes an indexed
/// implementation trustworthy.
///
/// The summary is taken from a whole-scene load rather than by concatenating a seek to every
/// chunk. Chunk intervals overlap by design — a scene is chunked at several temporal
/// resolutions, so `[0, 2)`, `[0, 1)` and `[0, 0.5)` all exist and all contain `t = 0` — and
/// a runner that summed a seek per entry would count the same gaussians repeatedly and report
/// a scene the file does not describe. The seek path is exercised on its own terms below.

#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "canonical.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::Result;
using fourdgs::Scene;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

/// A seek transfers exactly what the index says it will, and a band cap removes bytes from
/// the wire rather than values after they arrive.
///
/// Counted at the transport, because that is the claim. Each measurement gets its own scene:
/// a decoder that has already fetched a range does not fetch it twice, which is correct
/// behaviour and would otherwise be indistinguishable from never fetching it at all.
Result<void> checkSeekCost(const std::string& path, Scene& scene) {
  const std::uint32_t chunks = scene.chunkCount();
  // Every cap is worth measuring only where the bands exist to skip; without spherical
  // harmonics all four caps describe the same bytes.
  const int caps = scene.shDegree() > 0 ? 3 : 0;

  for (std::uint32_t i = 0; i < chunks; ++i) {
    Result<std::pair<double, double>> interval = scene.chunkInterval(i);
    if (!interval) return interval.error();
    const double t = interval->first;

    std::uint64_t previous = 0;
    for (int cap = 0; cap <= caps; ++cap) {
      Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
      if (!file) return file.error();
      std::unique_ptr<fourdgs::FileReadable> raw(*file);
      fourdgs::CountingReadable counting(raw.get());

      Result<std::unique_ptr<Scene>> fresh = Scene::open(counting);
      if (!fresh) return fresh.error();
      const std::uint64_t predicted = (*fresh)->bytesForTime(t, cap);
      const std::uint64_t beforeLoad = counting.bytesRead();
      Result<void> loaded = (*fresh)->loadAt(t, cap);
      if (!loaded) return loaded.error();
      const std::uint64_t moved = counting.bytesRead() - beforeLoad;

      if (moved != predicted) {
        return Error(ErrorCode::kMalformed,
                     "seeking to " + std::to_string(t) + " with maxShBand=" + std::to_string(cap) +
                         " transferred " + std::to_string(moved) + " bytes, the index says " +
                         std::to_string(predicted));
      }
      if (predicted < previous) {
        return Error(ErrorCode::kMalformed,
                     "raising the band cap to " + std::to_string(cap) + " at " + std::to_string(t) +
                         " transferred fewer bytes, " + std::to_string(predicted) + " against " +
                         std::to_string(previous));
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

  Result<std::unique_ptr<Scene>> opened = Scene::open(source);
  if (!opened) return fail(opened.error().toString());
  Scene& scene = **opened;
  // A scene with no chunks has nothing to index, and a file written without an index cannot
  // be read this way at all. The first is a legal file; the second the harness never hands
  // to this runner.
  if (!scene.isIndexed() && scene.chunkCount() > 0) {
    return fail("the file has a chunk index, but it was not opened on the seeking path");
  }

  Result<void> loaded = scene.loadAll(3);
  if (!loaded) return fail(loaded.error().toString());
  const fourdgs::GaussianView gaussians = scene.gaussians();

  Result<fourdgs::AudioTrack> audio = scene.readAudioTrack();
  if (!audio) return fail(audio.error().toString());

  std::vector<std::pair<double, double>> intervals;
  for (std::uint32_t i = 0; i < scene.chunkCount(); ++i) {
    Result<std::pair<double, double>> interval = scene.chunkInterval(i);
    if (!interval) return fail(interval.error().toString());
    intervals.push_back(*interval);
  }

  Result<void> seeks = checkSeekCost(path, scene);
  if (!seeks) return fail(seeks.error().toString());

  fourdgs::Header header;
  header.durationSec = scene.durationSec();
  header.cutoff = scene.cutoff();
  header.gaussianCount = scene.gaussianCount();
  header.shDegree = scene.shDegree();
  header.hasAudio = scene.hasAudio();

  fourdgs::conformance::SceneSummary summary;
  summary.header = &header;
  summary.gaussians = &gaussians;
  summary.audio = scene.hasAudio() ? &*audio : nullptr;
  summary.chunkIntervals = intervals;

  std::printf("%s\n", fourdgs::conformance::canonical(summary).c_str());
  return 0;
}
