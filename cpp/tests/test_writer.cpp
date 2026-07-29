// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The encode surface, at the edge of the C ABI.
///
/// Two builds exist. Without a core, `encodeScene` refuses with `kNotImplemented` and a
/// sentence naming the fix, exactly as the decode side does. With one, a tiny scene built by
/// hand encodes to bytes that reopen as a real 4dgs file and decode back to what went in —
/// including a never-fading gaussian's infinite sigma, which is a value the writer must carry
/// rather than a sentinel it may drop.

#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ErrorCode;
using fourdgs::GaussianData;
using fourdgs::GaussianView;
using fourdgs::Result;
using fourdgs::Scene;
using fourdgs::WriteOptions;

GaussianData tinyScene() {
  GaussianData data;
  data.resize(3, 0, 0);
  data.positions = {0.0f, 0.0f, 0.0f, 1.0f, 0.5f, -0.5f, -1.0f, 2.0f, 0.25f};
  data.scales = {0.1f, 0.1f, 0.1f, 0.2f, 0.15f, 0.1f, 0.05f, 0.05f, 0.05f};
  data.rotations = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
  data.colors = {0.9f, 0.1f, 0.1f, 1.0f, 0.1f, 0.9f, 0.1f, 0.8f, 0.1f, 0.1f, 0.9f, 0.5f};
  data.motions = {0, 0, 0, 0.1f, 0, 0, 0, -0.1f, 0};
  data.muT = {0.5f, 1.0f, 1.5f};
  // The middle gaussian never fades: its sigma is +inf, and it must survive as +inf.
  data.sigmaT = {0.3f, std::numeric_limits<float>::infinity(), 0.4f};
  data.winLo = {0.0f, 0.0f, 0.0f};
  data.winHi = {2.0f, 2.0f, 2.0f};
  return data;
}

void encodeRefusesWithoutACore() {
  const GaussianData data = tinyScene();
  Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeScene(GaussianView(data), 2.0);
  CHECK(!encoded.ok());
  CHECK_EQ(encoded.error().code, ErrorCode::kNotImplemented);
  CHECK(encoded.error().message.find("cargo build") != std::string::npos);
}

void encodeRoundTrips() {
  const GaussianData data = tinyScene();
  WriteOptions options;
  options.maxDepth = 4;
  options.minChunkGaussians = 1;
  options.profile = "test";

  Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeScene(GaussianView(data), 2.0, options);
  CHECK(encoded.ok());
  if (!encoded.ok()) return;

  Result<std::unique_ptr<Scene>> reopened =
      Scene::openMemory(fourdgs::Span<const std::uint8_t>(encoded->data(), encoded->size()));
  CHECK(reopened.ok());
  if (!reopened.ok()) return;
  Scene& scene = **reopened;

  CHECK_EQ(scene.gaussianCount(), static_cast<std::uint64_t>(3));
  CHECK_EQ(scene.durationSec(), 2.0);
  CHECK(scene.profile() == "test");
  CHECK(scene.temporalModel() == "gaussian-birth");

  Result<void> loaded = scene.loadAll(3);
  CHECK(loaded.ok());
  if (!loaded.ok()) return;
  const GaussianView back = scene.gaussians();
  CHECK_EQ(back.count, static_cast<std::size_t>(3));

  int infinities = 0;
  for (std::size_t i = 0; i < back.count; ++i) {
    if (std::isinf(back.sigmaT[i])) ++infinities;
    CHECK(!std::isnan(back.sigmaT[i]));
  }
  CHECK_EQ(infinities, 1);
}

void runTests() {
  if (fourdgs::backendAvailable()) {
    encodeRoundTrips();
  } else {
    encodeRefusesWithoutACore();
  }
}

}  // namespace

TEST_MAIN
