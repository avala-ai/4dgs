// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Decoding real files, over the conformance corpus.
///
/// The conformance suite compares this implementation against the others. This compares it
/// against itself, on the two claims a binding can get wrong on its own: that the three ways
/// to open a scene are three doors into one decoder, and that the state the core reconstructs
/// at an instant is the state spec §3 defines — because this package also computes that, in
/// `fourdgs::stateAt`, and two implementations of one formula that never meet will drift.
///
/// The corpus is generated rather than committed, so its location comes from the environment
/// when it is not where this file expects it. A build with no core behind it has nothing to
/// decode and says so instead of pretending to have checked.

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::GaussianView;
using fourdgs::Result;
using fourdgs::Scene;

#ifndef FOURDGS_CORPUS_DIR
#define FOURDGS_CORPUS_DIR "tests/conformance/data"
#endif

/// Where the corpus is, resolved at configure time rather than relative to whatever
/// directory the test was launched from.
std::string corpusDirectory() {
  const char* fromEnvironment = std::getenv("FOURDGS_CORPUS");
  if (fromEnvironment != nullptr) return std::string(fromEnvironment);
  return std::string(FOURDGS_CORPUS_DIR);
}

/// The corpus variants this test decodes. Named rather than globbed, so a corpus that failed
/// to generate is a failing test rather than a loop over nothing.
const char* kVariants[] = {
    "OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio",
    "OneWindow-UseChunkIndex-UseCrc-WithMultipleAudioSources",
    "TenWindows-UseChunkIndex-UseChunks-UseCrc",
    "MixedLifetimes-UseChunkIndex-UseCrc",
    // Declares a cutoff other than the 0.05 default, which is the only way the "use the
    // file's own cutoff" rule can be checked rather than assumed.
    "MixedLifetimes-CustomCutoff-UseChunkIndex-UseCrc",
    "TinySigmas-UseChunkIndex-UseCrc",
    "LongLived-Quantized-UseChunkIndex-UseCrc",
    "NoData-UseChunkIndex-UseCrc",
};

std::vector<std::uint8_t> readWhole(const std::string& path, bool* found) {
  std::vector<std::uint8_t> bytes;
  std::FILE* handle = std::fopen(path.c_str(), "rb");
  *found = handle != nullptr;
  if (handle == nullptr) return bytes;
  std::uint8_t buffer[65536];
  std::size_t got = 0;
  while ((got = std::fread(buffer, 1, sizeof(buffer), handle)) > 0) {
    bytes.insert(bytes.end(), buffer, buffer + got);
  }
  std::fclose(handle);
  return bytes;
}

/// The codes this package documents. Anything else — or an empty message — means a caller
/// cannot tell what to do about the failure, which is the whole point of the enum.
bool isDocumented(const fourdgs::Error& error) {
  switch (error.code) {
    case fourdgs::ErrorCode::kInvalidArgument:
    case fourdgs::ErrorCode::kIo:
    case fourdgs::ErrorCode::kBadMagic:
    case fourdgs::ErrorCode::kUnsupportedVersion:
    case fourdgs::ErrorCode::kTruncated:
    case fourdgs::ErrorCode::kMalformed:
    case fourdgs::ErrorCode::kUnsupported:
    case fourdgs::ErrorCode::kChecksumMismatch:
    case fourdgs::ErrorCode::kInternal:
      return !error.message.empty();
    case fourdgs::ErrorCode::kOk:
    case fourdgs::ErrorCode::kNotImplemented:
      return false;
  }
  return false;
}

/// Three entry points, one decoder. A path, a buffer and a caller's transport must not
/// disagree about what a file contains.
void everyDoorOpensTheSameScene(const std::string& path, const std::vector<std::uint8_t>& bytes) {
  Result<std::unique_ptr<Scene>> fromPath = Scene::openPath(path);
  CHECK(fromPath.ok());
  if (!fromPath.ok()) return;

  Result<std::unique_ptr<Scene>> fromMemory =
      Scene::openMemory(fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size()));
  CHECK(fromMemory.ok());
  if (!fromMemory.ok()) return;

  fourdgs::MemoryReadable transport(bytes);
  Result<std::unique_ptr<Scene>> fromReadable = Scene::open(transport);
  CHECK(fromReadable.ok());
  if (!fromReadable.ok()) return;

  CHECK_EQ((*fromPath)->gaussianCount(), (*fromMemory)->gaussianCount());
  CHECK_EQ((*fromPath)->gaussianCount(), (*fromReadable)->gaussianCount());
  CHECK_EQ((*fromPath)->durationSec(), (*fromReadable)->durationSec());
  CHECK_EQ((*fromPath)->cutoff(), (*fromReadable)->cutoff());
  CHECK_EQ((*fromPath)->chunkCount(), (*fromReadable)->chunkCount());

  for (Scene* scene : {fromPath->get(), fromMemory->get(), fromReadable->get()}) {
    CHECK(scene->loadAll(3).ok());
  }
  const GaussianView byPath = (*fromPath)->gaussians();
  const GaussianView byMemory = (*fromMemory)->gaussians();
  const GaussianView byReadable = (*fromReadable)->gaussians();
  CHECK_EQ(byPath.count, byMemory.count);
  CHECK_EQ(byPath.count, byReadable.count);
  for (std::size_t i = 0; i < byPath.positions.size(); ++i) {
    if (byPath.positions[i] != byReadable.positions[i]) {
      CHECK_EQ(byPath.positions[i], byReadable.positions[i]);
      break;  // one report is a diagnosis; a hundred thousand is a wall of text
    }
  }
}

/// The header's gaussian count is what a whole-scene load produces.
void theWorkingSetMatchesTheHeader(Scene& scene) {
  CHECK(scene.loadAll(3).ok());
  CHECK_EQ(static_cast<std::uint64_t>(scene.gaussians().count), scene.gaussianCount());
}

/// The core's reconstruction at an instant, against this package's.
///
/// `fourdgs::stateAt` implements spec §3 in C++ and the core implements it in Rust; the
/// suite compares neither, because the canonical JSON does not carry a reconstruction. So
/// they are compared here, with the file's own cutoff — the value §6.3 makes load-bearing
/// and the one a decoder substituting the 0.05 default would get wrong on exactly the
/// variants that declare something else.
void reconstructionAgreesWithTheCore(Scene& scene) {
  const double duration = scene.durationSec();
  const double cutoff = scene.cutoff();
  const double times[] = {0.0, duration * 0.25, duration * 0.5, duration * 0.75};

  for (double t : times) {
    Result<fourdgs::State> state = scene.stateAt(t, 3);
    CHECK(state.ok());
    if (!state.ok()) continue;

    const GaussianView resident = scene.gaussians();
    // Every gaussian the core calls visible, this package must also call visible.
    for (std::size_t i = 0; i < state->count(); ++i) {
      const std::uint32_t g = state->indices()[i];
      CHECK(g < resident.count);
      if (g >= resident.count) break;

      const fourdgs::GaussianState mine = fourdgs::stateAt(resident, g, t, cutoff);
      if (!mine.visible) {
        CHECK(mine.visible);
        break;
      }
      // Float32 inputs widened to double on both sides, so the tolerance covers the
      // arithmetic and not a difference of opinion about the formula.
      for (std::size_t k = 0; k < 3; ++k) {
        const double theirs = static_cast<double>(state->centers()[i * 3 + k]);
        if (std::fabs(theirs - mine.center[k]) > 1e-4) {
          CHECK(std::fabs(theirs - mine.center[k]) <= 1e-4);
          break;
        }
      }
      const double theirOpacity = static_cast<double>(state->opacity()[i]);
      if (std::fabs(theirOpacity - mine.opacity) > 1e-4) {
        CHECK(std::fabs(theirOpacity - mine.opacity) <= 1e-4);
        break;
      }
    }

    // And the converse: nothing this package calls visible may be missing from the core's
    // set. Without this the check passes for a core that returns an empty state.
    std::vector<bool> claimed(resident.count, false);
    for (std::size_t i = 0; i < state->count(); ++i) claimed[state->indices()[i]] = true;
    std::size_t missing = 0;
    for (std::size_t g = 0; g < resident.count; ++g) {
      if (fourdgs::stateAt(resident, g, t, cutoff).visible && !claimed[g]) ++missing;
    }
    CHECK_EQ(missing, static_cast<std::size_t>(0));
  }
}

/// Every source is independently readable at its declared length. Absence stays absence.
void audioReadsBackAtItsDeclaredLength(Scene& scene) {
  Result<std::vector<fourdgs::AudioSource>> sources = scene.readAudioSources();
  CHECK(sources.ok());
  if (!sources.ok()) return;
  if (scene.hasAudio()) {
    CHECK(!sources->empty());
    CHECK_EQ(sources->size(), static_cast<std::size_t>(scene.audioSourceCount()));
    for (const fourdgs::AudioSource& source : *sources) {
      CHECK_EQ(static_cast<std::uint64_t>(source.data.size()), source.dataSize);
      CHECK(!source.codec.empty());
    }
    Result<fourdgs::AudioSourceState> state = scene.audioSourceStateAt(0, 0.25);
    CHECK(state.ok());
  } else {
    CHECK(sources->empty());
  }
}

/// Every refusal is a documented error, and no input is a crash.
///
/// The corpus is all well-formed files, so this makes ill-formed ones: cut the file at a
/// dozen points, flip a byte in each region, blank the magic. What comes back must be a
/// `Result` carrying one of this package's codes with a sentence in it — never a throw
/// across the ABI, never a partial read past the end of the buffer, never silence. Under the
/// sanitizers this is also where a malformed length that made the decoder index out of
/// bounds would show up.
void malformedInputIsRefusedAndNamed(const std::vector<std::uint8_t>& original) {
  std::vector<std::vector<std::uint8_t>> broken;

  for (int cut = 1; cut <= 12; ++cut) {
    const std::size_t at = original.size() * static_cast<std::size_t>(cut) / 13;
    broken.push_back(std::vector<std::uint8_t>(original.begin(), original.begin() + at));
  }
  for (int at : {0, 3, 7, 9, 17, 33, 64, 129}) {
    if (static_cast<std::size_t>(at) >= original.size()) continue;
    std::vector<std::uint8_t> flipped = original;
    flipped[static_cast<std::size_t>(at)] ^= 0xFF;
    broken.push_back(std::move(flipped));
  }
  std::vector<std::uint8_t> blanked = original;
  for (std::size_t i = 0; i < 8 && i < blanked.size(); ++i) blanked[i] = 0;
  broken.push_back(std::move(blanked));
  broken.push_back(std::vector<std::uint8_t>());

  for (const std::vector<std::uint8_t>& bytes : broken) {
    Result<std::unique_ptr<Scene>> opened =
        Scene::openMemory(fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size()));
    if (!opened.ok()) {
      CHECK(isDocumented(opened.error()));
      continue;
    }
    // Opening succeeded, which is legitimate for a file cut after its header. Loading it is
    // the other half of the boundary, and it has the same obligation.
    Result<void> loaded = (*opened)->loadAll(3);
    if (!loaded.ok()) CHECK(isDocumented(loaded.error()));

    Result<fourdgs::State> state = (*opened)->stateAt(0.0, 3);
    if (!state.ok()) CHECK(isDocumented(state.error()));

    Result<fourdgs::AudioTrack> audio = (*opened)->readAudioTrack();
    if (!audio.ok()) CHECK(isDocumented(audio.error()));
  }
}

void runTests() {
  if (!fourdgs::backendAvailable()) {
    // Nothing to decode, and nothing claimed. The no-core build's contract is `test_seam`'s
    // business; this file has no opinion about it.
    return;
  }

  const std::string directory = corpusDirectory();
  for (const char* variant : kVariants) {
    const std::string path = directory + "/" + variant + ".4dgs";
    bool found = false;
    const std::vector<std::uint8_t> bytes = readWhole(path, &found);
    if (!found) {
      // A corpus that did not generate must fail the test rather than skip it: a green run
      // that decoded nothing is worse than a red one.
      ::fourdgs::testing::report(__FILE__, __LINE__, path.c_str(),
                                 "corpus file missing; run tests/conformance/generate.py");
      continue;
    }

    everyDoorOpensTheSameScene(path, bytes);

    Result<std::unique_ptr<Scene>> opened = Scene::openPath(path);
    CHECK(opened.ok());
    if (!opened.ok()) continue;
    Scene& scene = **opened;

    theWorkingSetMatchesTheHeader(scene);
    reconstructionAgreesWithTheCore(scene);
    audioReadsBackAtItsDeclaredLength(scene);
    malformedInputIsRefusedAndNamed(bytes);
  }
}

}  // namespace

TEST_MAIN
