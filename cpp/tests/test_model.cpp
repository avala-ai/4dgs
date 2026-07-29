// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The arithmetic of spec §3, which is where decoding ends.

#include <cmath>
#include <limits>

#include "check.hpp"
#include "fourdgs/model.hpp"

namespace {

using fourdgs::GaussianData;
using fourdgs::GaussianState;
using fourdgs::GaussianView;

/// One gaussian, born at `muT`, alive over `[lo, hi)`.
GaussianData one(float muT, float sigmaT, float lo, float hi, float alpha, float velocityX) {
  GaussianData data;
  data.resize(1, 0, 0);
  data.positions = {1.0f, 2.0f, 3.0f};
  data.scales = {1.0f, 1.0f, 1.0f};
  data.rotations = {0.0f, 0.0f, 0.0f, 1.0f};
  data.colors = {0.25f, 0.5f, 0.75f, alpha};
  data.motions = {velocityX, 0.0f, 0.0f};
  data.muT = {muT};
  data.sigmaT = {sigmaT};
  data.winLo = {lo};
  data.winHi = {hi};
  return data;
}

void windowIsTheOnlyHardGate() {
  const GaussianData data = one(1.0f, 1.0f, 1.0f, 2.0f, 1.0f, 0.0f);
  const GaussianView view(data);

  // Inside the window and at the peak of the bell: visible.
  CHECK(fourdgs::stateAt(view, 0, 1.0, 0.05).visible);
  // Just outside the half-open window's end: absent, not faded.
  CHECK(!fourdgs::stateAt(view, 0, 2.0, 0.05).visible);
  // Before it opens: absent, even though the marginal is high.
  const GaussianState before = fourdgs::stateAt(view, 0, 0.99, 0.05);
  CHECK(!before.visible);
  CHECK(before.marginal > 0.9);
}

void cutoffComesFromTheFile() {
  const GaussianData data = one(0.0f, 1.0f, -10.0f, 10.0f, 1.0f, 0.0f);
  const GaussianView view(data);
  // At t = 2 sigma the marginal is exp(-2) ≈ 0.135: above the default cutoff, below a file
  // that declared 0.5. A decoder that substitutes the default decodes a different scene.
  const GaussianState state = fourdgs::stateAt(view, 0, 2.0, 0.05);
  CHECK(state.visible);
  CHECK(!fourdgs::stateAt(view, 0, 2.0, 0.5).visible);
  CHECK(std::fabs(state.marginal - std::exp(-2.0)) < 1e-12);
}

void neverFadingHasMarginalOne() {
  const GaussianData data =
      one(0.0f, std::numeric_limits<float>::infinity(), 0.0f, 5.0f, 0.5f, 0.0f);
  const GaussianView view(data);
  const GaussianState state = fourdgs::stateAt(view, 0, 4.9, 0.05);
  CHECK(state.visible);
  CHECK_EQ(state.marginal, 1.0);
  CHECK_EQ(state.opacity, 0.5);
  // Absent outside the window: full opacity, hard edges, no fade — spec §3.1.
  CHECK(!fourdgs::stateAt(view, 0, 5.0, 0.05).visible);
}

void centerFollowsMotionFromBirth() {
  const GaussianData data = one(1.0f, std::numeric_limits<float>::infinity(), 0.0f, 10.0f, 1.0f,
                                2.0f);
  const GaussianView view(data);
  const GaussianState state = fourdgs::stateAt(view, 0, 3.0, 0.05);
  // position.x + velocity.x × (t − mu_t) = 1 + 2 × 2.
  CHECK_EQ(state.center[0], 5.0);
  CHECK_EQ(state.center[1], 2.0);
}

void appendKeepsTheDegree() {
  GaussianData scene;
  GaussianData chunk;
  chunk.resize(2, 1, 3);
  for (std::size_t i = 0; i < chunk.sh.size(); ++i) chunk.sh[i] = static_cast<std::uint8_t>(i);
  scene.append(chunk);
  scene.append(chunk);
  CHECK_EQ(scene.count, static_cast<std::size_t>(4));
  CHECK_EQ(scene.shDegree, 1);
  CHECK_EQ(scene.shCoefficients, static_cast<std::size_t>(3));
  CHECK_EQ(scene.positions.size(), static_cast<std::size_t>(12));
  CHECK_EQ(scene.rotations.size(), static_cast<std::size_t>(16));
  CHECK_EQ(scene.sh.size(), static_cast<std::size_t>(4 * 3 * 3));

  const GaussianView view(scene);
  CHECK_EQ(view.count, static_cast<std::size_t>(4));
  CHECK_EQ(view.sh.size(), scene.sh.size());
  // A view, not a copy: the span points into the data it was built from.
  CHECK(view.positions.data() == scene.positions.data());
}

void runTests() {
  windowIsTheOnlyHardGate();
  cutoffComesFromTheFile();
  neverFadingHasMarginalOne();
  centerFollowsMotionFromBirth();
  appendKeepsTheDegree();
}

}  // namespace

TEST_MAIN
