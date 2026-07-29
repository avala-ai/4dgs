// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/model.hpp"

#include <algorithm>

namespace fourdgs {
namespace {

double loopingLocalTime(double t, double startSec, double durationSec) {
  if (t <= startSec) return 0.0;
  double timeRemainder = std::fmod(t, durationSec);
  if (timeRemainder < 0.0) timeRemainder += durationSec;
  double startRemainder = std::fmod(startSec, durationSec);
  if (startRemainder < 0.0) startRemainder += durationSec;
  const double difference = timeRemainder - startRemainder;
  return difference < 0.0 ? difference + durationSec : difference;
}

void normalizeQuaternion(const double value[4], double out[4]) {
  const double scale =
      std::max({std::abs(value[0]), std::abs(value[1]), std::abs(value[2]), std::abs(value[3])});
  if (!std::isfinite(scale) || scale == 0.0) {
    out[0] = out[1] = out[2] = 0.0;
    out[3] = 1.0;
    return;
  }
  double scaled[4];
  for (int i = 0; i < 4; ++i) scaled[i] = value[i] / scale;
  const double length = std::sqrt(scaled[0] * scaled[0] + scaled[1] * scaled[1] +
                                  scaled[2] * scaled[2] + scaled[3] * scaled[3]);
  for (int i = 0; i < 4; ++i) out[i] = scaled[i] / length;
}

void slerp(const double a[4], const double b[4], double u, double out[4]) {
  double qa[4];
  double qb[4];
  normalizeQuaternion(a, qa);
  normalizeQuaternion(b, qb);
  double dot = 0.0;
  for (int i = 0; i < 4; ++i) dot += qa[i] * qb[i];
  if (dot < 0.0) {
    for (double& value : qb) value = -value;
    dot = -dot;
  }
  dot = std::max(-1.0, std::min(1.0, dot));
  if (dot > 0.9995) {
    for (int i = 0; i < 4; ++i) out[i] = qa[i] + (qb[i] - qa[i]) * u;
    double normalized[4];
    normalizeQuaternion(out, normalized);
    std::copy(normalized, normalized + 4, out);
    return;
  }
  const double theta = std::acos(dot);
  const double sinTheta = std::sin(theta);
  const double wa = std::sin((1.0 - u) * theta) / sinTheta;
  const double wb = std::sin(u * theta) / sinTheta;
  for (int i = 0; i < 4; ++i) out[i] = wa * qa[i] + wb * qb[i];
}

}  // namespace

AudioSourceState AudioSource::stateAt(double t) const {
  AudioSourceState state;
  state.active = t >= startSec && (loop || t < startSec + durationSec);
  state.localTime = loop && durationSec > 0.0
                        ? loopingLocalTime(t, startSec, durationSec)
                        : std::min(std::max(0.0, t - startSec), std::max(0.0, durationSec));
  state.gain = gain;

  if (keyframes.empty()) {
    std::copy(position, position + 3, state.position);
    normalizeQuaternion(rotation, state.rotation);
    return state;
  }
  if (t <= keyframes.front().time) {
    std::copy(keyframes.front().position, keyframes.front().position + 3, state.position);
    normalizeQuaternion(keyframes.front().rotation, state.rotation);
    return state;
  }
  if (t >= keyframes.back().time) {
    std::copy(keyframes.back().position, keyframes.back().position + 3, state.position);
    normalizeQuaternion(keyframes.back().rotation, state.rotation);
    return state;
  }
  const auto high = std::upper_bound(
      keyframes.begin(), keyframes.end(), t,
      [](double time, const AudioSource::Keyframe& frame) { return time < frame.time; });
  const AudioSource::Keyframe& a = *(high - 1);
  const AudioSource::Keyframe& b = *high;
  if (interpolation == "step") {
    std::copy(a.position, a.position + 3, state.position);
    normalizeQuaternion(a.rotation, state.rotation);
    return state;
  }
  const double u = (t - a.time) / (b.time - a.time);
  for (int i = 0; i < 3; ++i) {
    state.position[i] = a.position[i] + (b.position[i] - a.position[i]) * u;
  }
  slerp(a.rotation, b.rotation, u, state.rotation);
  return state;
}

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
