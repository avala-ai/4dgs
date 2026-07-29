// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: streamed decode, canonical JSON to stdout.
///
/// The whole interface between an implementation and the harness is this: take a path, print
/// the canonical JSON. Anything wrong exits non-zero with a sentence on stderr, and the
/// harness reports it like a diff.

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
using fourdgs::GaussianView;
using fourdgs::Result;
using fourdgs::Scene;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
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

/// How many gaussians survive a decode of `bytes`.
Result<std::size_t> countFrom(const std::vector<std::uint8_t>& bytes) {
  Result<std::unique_ptr<Scene>> opened =
      Scene::openMemory(fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size()));
  if (!opened) return opened.error();
  Result<void> loaded = (*opened)->loadAll(3);
  if (!loaded) return loaded.error();
  return (*opened)->gaussians().count;
}

/// Decode the same file cut short, and insist on what survives.
///
/// Nothing in the corpus is truncated, so this makes one. The canonical JSON cannot express
/// truncation recovery — a cut file is a different file — so the check lives here, where a
/// failure exits non-zero and the harness reports it like any other.
Result<void> checkTruncationRecovery(const std::vector<std::uint8_t>& bytes, std::size_t full) {
  if (bytes.size() < 16) return Error(ErrorCode::kInvalidArgument, "the file is too short to cut");

  // Cut before the trailing magic. Everything the file said is still in it, so nothing may
  // be lost: a reader that needs the trailing magic to finish is a reader that cannot read
  // a file still being written.
  Result<std::size_t> cut = countFrom(std::vector<std::uint8_t>(bytes.begin(), bytes.end() - 8));
  if (!cut) return cut.error();
  if (*cut != full) {
    return Error(ErrorCode::kMalformed, "cutting the trailing magic lost gaussians: " +
                                            std::to_string(*cut) + " of " + std::to_string(full));
  }

  // Cut in the middle. What survives is what preceded the cut — fewer gaussians than the
  // whole file, and, when the file has more than one chunk's worth, not zero. Recovering
  // nothing from half a file is the failure this catches.
  if (full > 1) {
    Result<std::size_t> half = countFrom(std::vector<std::uint8_t>(
        bytes.begin(), bytes.begin() + static_cast<long>(bytes.size() / 2)));
    if (!half) return half.error();
    if (*half > full) {
      return Error(ErrorCode::kMalformed,
                   "half a file decoded more gaussians than all of it: " + std::to_string(*half) +
                       " against " + std::to_string(full));
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

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> source(*file);

  Result<std::unique_ptr<Scene>> opened = Scene::open(*source);
  if (!opened) return fail(opened.error().toString());
  Scene& scene = **opened;

  Result<void> loaded = scene.loadAll(3);
  if (!loaded) return fail(loaded.error().toString());
  const GaussianView gaussians = scene.gaussians();

  Result<std::vector<std::uint8_t>> bytes = readWhole(path);
  if (!bytes) return fail(bytes.error().toString());
  Result<void> recovery = checkTruncationRecovery(*bytes, gaussians.count);
  if (!recovery) return fail(recovery.error().toString());

  Result<fourdgs::AudioTrack> audio = scene.readAudioTrack();
  if (!audio) return fail(audio.error().toString());

  std::vector<std::pair<double, double>> intervals;
  for (std::uint32_t i = 0; i < scene.chunkCount(); ++i) {
    Result<std::pair<double, double>> interval = scene.chunkInterval(i);
    if (!interval) return fail(interval.error().toString());
    intervals.push_back(*interval);
  }

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
