// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The public aggregate decoded-state budget, at every C++ collecting seam.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::ReadMode;
using fourdgs::ReadOptions;
using fourdgs::Result;
using fourdgs::Scene;

#ifndef FOURDGS_CORPUS_DIR
#define FOURDGS_CORPUS_DIR "tests/conformance/data"
#endif

std::string corpusPath(const std::string& relative) {
  return std::string(FOURDGS_CORPUS_DIR) + "/" + relative;
}

std::vector<std::uint8_t> readWhole(const std::string& path) {
  std::vector<std::uint8_t> bytes;
  std::FILE* file = std::fopen(path.c_str(), "rb");
  CHECK(file != nullptr);
  if (file == nullptr) return bytes;
  std::uint8_t buffer[65536];
  std::size_t got = 0;
  while ((got = std::fread(buffer, 1, sizeof(buffer), file)) != 0) {
    bytes.insert(bytes.end(), buffer, buffer + got);
  }
  std::fclose(file);
  return bytes;
}

fourdgs::Span<const std::uint8_t> view(const std::vector<std::uint8_t>& bytes) {
  return fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size());
}

void checkResourceLimit(const Error& error, const std::string& phase) {
  CHECK_EQ(error.code, ErrorCode::kResourceLimit);
  CHECK(!error.refusal.has_value());
  CHECK(error.message.find("decoded-state") != std::string::npos);
  CHECK(error.message.find("configured limit is 1 bytes") != std::string::npos);
  CHECK(error.message.find(phase) != std::string::npos);
}

class ProbeReadable : public fourdgs::Readable {
 public:
  Result<std::uint64_t> size() override {
    ++sizeCalls;
    return std::uint64_t{0};
  }

  Result<std::size_t> read(std::uint64_t, fourdgs::Span<std::uint8_t>) override {
    ++readCalls;
    return std::size_t{0};
  }

  int sizeCalls = 0;
  int readCalls = 0;
};

void zeroIsACallerErrorBeforeIo() {
  CHECK_EQ(ReadOptions().maxDecodedStateBytes, std::uint64_t{536870912});

  ReadOptions zero;
  zero.maxDecodedStateBytes = 0;
  Result<std::unique_ptr<Scene>> path =
      Scene::openPath("/this-budget-test-must-not-open.4dgs", zero, ReadMode::kSequential);
  CHECK(!path.ok());
  if (!path.ok()) CHECK_EQ(path.error().code, ErrorCode::kInvalidArgument);

  const std::vector<std::uint8_t> empty;
  Result<std::unique_ptr<Scene>> memory = Scene::openMemory(view(empty), zero);
  CHECK(!memory.ok());
  if (!memory.ok()) CHECK_EQ(memory.error().code, ErrorCode::kInvalidArgument);

  ProbeReadable source;
  Result<std::unique_ptr<Scene>> readable = Scene::open(source, zero);
  CHECK(!readable.ok());
  if (!readable.ok()) CHECK_EQ(readable.error().code, ErrorCode::kInvalidArgument);
  CHECK_EQ(source.sizeCalls, 0);
  CHECK_EQ(source.readCalls, 0);

  Result<std::string> keyframe = fourdgs::keyframeDeltaStatesJson(view(empty), false, zero);
  CHECK(!keyframe.ok());
  if (!keyframe.ok()) CHECK_EQ(keyframe.error().code, ErrorCode::kInvalidArgument);
}

void everyCollectorReceivesTheSelectedLimit() {
  const std::string gaussianPath = corpusPath("OneGaussian-UseChunkIndex-UseCrc.4dgs");
  const std::vector<std::uint8_t> gaussian = readWhole(gaussianPath);
  const std::vector<std::uint8_t> keyframe =
      readWhole(corpusPath("keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs"));
  if (gaussian.empty() || keyframe.empty()) return;

  ReadOptions tiny;
  tiny.maxDecodedStateBytes = 1;

  Result<std::unique_ptr<Scene>> fromPath =
      Scene::openPath(gaussianPath, tiny, ReadMode::kSequential);
  CHECK(!fromPath.ok());
  if (!fromPath.ok()) checkResourceLimit(fromPath.error(), "streamed gaussian-birth");

  Result<std::unique_ptr<Scene>> fromMemory =
      Scene::openMemory(view(gaussian), tiny, ReadMode::kSequential);
  CHECK(!fromMemory.ok());
  if (!fromMemory.ok()) checkResourceLimit(fromMemory.error(), "streamed gaussian-birth");

  fourdgs::MemoryReadable memory(gaussian);
  Result<std::unique_ptr<Scene>> fromReadable = Scene::open(memory, tiny, ReadMode::kSequential);
  CHECK(!fromReadable.ok());
  if (!fromReadable.ok()) checkResourceLimit(fromReadable.error(), "streamed gaussian-birth");

  Result<std::unique_ptr<Scene>> indexed =
      Scene::openMemory(view(gaussian), tiny, ReadMode::kIndexed);
  CHECK(indexed.ok());
  if (indexed.ok()) {
    Result<void> loaded = (*indexed)->loadAll(3, tiny);
    CHECK(!loaded.ok());
    if (!loaded.ok()) checkResourceLimit(loaded.error(), "indexed gaussian-birth");

    // These public summaries contain a hidden whole-population collection. Their C ABI calls
    // inherit the budget selected at open, rather than escaping through the compatibility default.
    Result<std::string> objects = (*indexed)->objectsJson();
    CHECK(!objects.ok());
    if (!objects.ok()) checkResourceLimit(objects.error(), "indexed gaussian-birth");
    Result<std::string> states = (*indexed)->objectStatesJson();
    CHECK(!states.ok());
    if (!states.ok()) checkResourceLimit(states.error(), "indexed gaussian-birth");
  }

  for (const bool useIndex : {false, true}) {
    Result<std::string> states = fourdgs::keyframeDeltaStatesJson(view(keyframe), useIndex, tiny);
    CHECK(!states.ok());
    if (!states.ok()) {
      checkResourceLimit(states.error(), useIndex ? "indexed" : "streamed");
    }
  }
}

void aPerCallFailureKeepsTheResidentState() {
  const std::vector<std::uint8_t> gaussian =
      readWhole(corpusPath("OneGaussian-UseChunkIndex-UseCrc.4dgs"));
  if (gaussian.empty()) return;

  Result<std::unique_ptr<Scene>> opened = Scene::openMemory(view(gaussian), ReadMode::kIndexed);
  CHECK(opened.ok());
  if (!opened.ok()) return;
  CHECK((*opened)->loadAll(3).ok());
  const fourdgs::GaussianView before = (*opened)->gaussians();
  CHECK_EQ(before.count, std::size_t{1});
  const float* positions = before.positions.data();

  ReadOptions tiny;
  tiny.maxDecodedStateBytes = 1;
  Result<void> cached = (*opened)->loadAll(3, tiny);
  CHECK(!cached.ok());
  if (!cached.ok()) checkResourceLimit(cached.error(), "cached gaussian-birth load");
  const fourdgs::GaussianView after = (*opened)->gaussians();
  CHECK_EQ(after.count, before.count);
  CHECK_EQ(after.positions.data(), positions);

  ReadOptions zero;
  zero.maxDecodedStateBytes = 0;
  Result<void> invalid = (*opened)->loadAll(3, zero);
  CHECK(!invalid.ok());
  if (!invalid.ok()) CHECK_EQ(invalid.error().code, ErrorCode::kInvalidArgument);
  CHECK_EQ((*opened)->gaussians().positions.data(), positions);
}

void defaultsStillDecode() {
  const std::vector<std::uint8_t> gaussian =
      readWhole(corpusPath("OneGaussian-UseChunkIndex-UseCrc.4dgs"));
  const std::vector<std::uint8_t> keyframe =
      readWhole(corpusPath("keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs"));
  if (gaussian.empty() || keyframe.empty()) return;

  Result<std::unique_ptr<Scene>> scene = Scene::openMemory(view(gaussian), ReadMode::kSequential);
  CHECK(scene.ok());
  if (scene.ok()) CHECK((*scene)->loadAll(3).ok());
  CHECK(fourdgs::keyframeDeltaStatesJson(view(keyframe), false).ok());
  CHECK(fourdgs::keyframeDeltaStatesJson(view(keyframe), true).ok());
}

void runTests() {
  zeroIsACallerErrorBeforeIo();
  CHECK_EQ(static_cast<std::int32_t>(ErrorCode::kResourceLimit), std::int32_t{12});
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kResourceLimit)),
           std::string("kResourceLimit"));
  if (!fourdgs::backendAvailable()) return;
  everyCollectorReceivesTheSelectedLimit();
  aPerCallFailureKeepsTheResidentState();
  defaultsStillDecode();
}

}  // namespace

TEST_MAIN
