// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/model.hpp"

namespace fourdgs {

void GaussianData::clear() {
  count = 0;
  positions.clear();
  scales.clear();
  rotations.clear();
  colors.clear();
  motions.clear();
  muT.clear();
  sigmaT.clear();
  winLo.clear();
  winHi.clear();
  sh.clear();
  shDegree = 0;
  shCoefficients = 0;
}

void GaussianData::resize(std::size_t newCount, int degree, std::size_t coefficients) {
  count = newCount;
  shDegree = degree;
  shCoefficients = coefficients;
  positions.resize(newCount * 3);
  scales.resize(newCount * 3);
  rotations.resize(newCount * 4);
  colors.resize(newCount * 4);
  motions.resize(newCount * 3);
  muT.resize(newCount);
  sigmaT.resize(newCount);
  winLo.resize(newCount);
  winHi.resize(newCount);
  sh.resize(coefficients == 0 ? 0 : newCount * coefficients * 3);
}

void GaussianData::append(const GaussianData& other) {
  positions.insert(positions.end(), other.positions.begin(), other.positions.end());
  scales.insert(scales.end(), other.scales.begin(), other.scales.end());
  rotations.insert(rotations.end(), other.rotations.begin(), other.rotations.end());
  colors.insert(colors.end(), other.colors.begin(), other.colors.end());
  motions.insert(motions.end(), other.motions.begin(), other.motions.end());
  muT.insert(muT.end(), other.muT.begin(), other.muT.end());
  sigmaT.insert(sigmaT.end(), other.sigmaT.begin(), other.sigmaT.end());
  winLo.insert(winLo.end(), other.winLo.begin(), other.winLo.end());
  winHi.insert(winHi.end(), other.winHi.begin(), other.winHi.end());
  sh.insert(sh.end(), other.sh.begin(), other.sh.end());
  count += other.count;
  // A scene declares one degree for all of its gaussians (spec §6.5), so this takes the
  // first non-zero it sees rather than trying to reconcile two.
  if (shDegree == 0 && other.shDegree != 0) {
    shDegree = other.shDegree;
    shCoefficients = other.shCoefficients;
  }
}

GaussianView::GaussianView(const GaussianData& data)
    : count(data.count),
      positions(data.positions.data(), data.positions.size()),
      scales(data.scales.data(), data.scales.size()),
      rotations(data.rotations.data(), data.rotations.size()),
      colors(data.colors.data(), data.colors.size()),
      motions(data.motions.data(), data.motions.size()),
      muT(data.muT.data(), data.muT.size()),
      sigmaT(data.sigmaT.data(), data.sigmaT.size()),
      winLo(data.winLo.data(), data.winLo.size()),
      winHi(data.winHi.data(), data.winHi.size()),
      sh(data.sh.data(), data.sh.size()),
      shDegree(data.shDegree),
      shCoefficients(data.shCoefficients) {}

}  // namespace fourdgs
