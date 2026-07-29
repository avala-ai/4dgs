// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The canonical JSON, and the property the whole comparison rests on: nothing in it depends
/// on decoded order.

#include <algorithm>
#include <limits>
#include <random>
#include <string>
#include <vector>

#include "canonical.hpp"
#include "check.hpp"

namespace {

using fourdgs::GaussianData;
using fourdgs::GaussianView;
using fourdgs::Header;
using fourdgs::conformance::Json;

GaussianData scene(std::size_t n, unsigned seed) {
  GaussianData data;
  data.resize(n, 1, 3);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> unit(0.0f, 1.0f);
  for (std::size_t i = 0; i < n; ++i) {
    for (std::size_t k = 0; k < 3; ++k) {
      data.positions[i * 3 + k] = unit(rng) * 10.0f;
      data.scales[i * 3 + k] = unit(rng);
      data.motions[i * 3 + k] = (i % 3 == 0) ? 0.0f : unit(rng);
    }
    for (std::size_t k = 0; k < 4; ++k) {
      data.rotations[i * 4 + k] = unit(rng);
      data.colors[i * 4 + k] = unit(rng);
    }
    data.muT[i] = unit(rng);
    data.sigmaT[i] = (i % 4 == 0) ? std::numeric_limits<float>::infinity() : unit(rng);
    data.winLo[i] = 0.0f;
    data.winHi[i] = 1.0f;
    for (std::size_t k = 0; k < 9; ++k) {
      data.sh[i * 9 + k] = static_cast<std::uint8_t>((i * 7 + k) % 251);
    }
  }
  return data;
}

/// The same gaussians, visited in a different order.
GaussianData shuffled(const GaussianData& source, unsigned seed) {
  std::vector<std::size_t> order(source.count);
  for (std::size_t i = 0; i < source.count; ++i) order[i] = i;
  std::mt19937 rng(seed);
  std::shuffle(order.begin(), order.end(), rng);

  GaussianData out;
  out.resize(source.count, source.shDegree, source.shCoefficients);
  for (std::size_t to = 0; to < order.size(); ++to) {
    const std::size_t from = order[to];
    for (std::size_t k = 0; k < 3; ++k) {
      out.positions[to * 3 + k] = source.positions[from * 3 + k];
      out.scales[to * 3 + k] = source.scales[from * 3 + k];
      out.motions[to * 3 + k] = source.motions[from * 3 + k];
    }
    for (std::size_t k = 0; k < 4; ++k) {
      out.rotations[to * 4 + k] = source.rotations[from * 4 + k];
      out.colors[to * 4 + k] = source.colors[from * 4 + k];
    }
    out.muT[to] = source.muT[from];
    out.sigmaT[to] = source.sigmaT[from];
    out.winLo[to] = source.winLo[from];
    out.winHi[to] = source.winHi[from];
    for (std::size_t k = 0; k < 9; ++k) out.sh[to * 9 + k] = source.sh[from * 9 + k];
  }
  return out;
}

std::string summarize(const GaussianData& data) {
  Header header;
  header.durationSec = 2.0;
  header.cutoff = 0.05;
  header.shDegree = 1;
  header.temporalModel = "gaussian-birth";
  header.attributes = {{"units", "metres"}, {"axis", "z-up"}};
  const GaussianView view(data);
  fourdgs::conformance::SceneSummary summary;
  summary.header = &header;
  summary.gaussians = &view;
  summary.chunkIntervals = {{0.0, 1.0}, {1.0, 2.0}};
  return fourdgs::conformance::canonical(summary);
}

/// Reordering the gaussians must not change one character of the summary. An encoder may
/// reorder them freely, so a summary that depended on their order would ask two correct
/// decoders to disagree.
void orderCannotChangeTheSummary() {
  const GaussianData original = scene(64, 11);
  const std::string first = summarize(original);
  for (unsigned seed = 1; seed <= 3; ++seed) {
    CHECK_EQ(summarize(shuffled(original, seed)), first);
  }
}

void integersAreStringsAndInfinityIsNull() {
  const std::string json = summarize(scene(8, 3));
  // A 64-bit count survives a JSON parser backed by doubles only as a string.
  CHECK(json.find("\"gaussianCount\": \"8\"") != std::string::npos);
  // A never-fading gaussian's sigma is null, never a sentinel a decoder could produce.
  CHECK(json.find("null") != std::string::npos);
  CHECK(fourdgs::conformance::num(std::numeric_limits<double>::infinity()).render() == "null");
  CHECK(fourdgs::conformance::num(-std::numeric_limits<double>::infinity()).render() == "null");
  CHECK(fourdgs::conformance::num(std::numeric_limits<double>::quiet_NaN()).render() == "null");
}

void floatsAreRoundedToSixDecimals() {
  CHECK_EQ(fourdgs::conformance::num(1.0 / 3.0).render(), std::string("0.333333"));
  CHECK_EQ(fourdgs::conformance::num(-0.0000004).render(), std::string("-0.000000"));
  CHECK_EQ(fourdgs::conformance::num(2.5).render(), std::string("2.500000"));
}

void absentAudioIsAValue() {
  const std::string json = summarize(scene(4, 5));
  CHECK(json.find("\"audio\": null") != std::string::npos);
  // Both paths visible in every implementation's output, rather than one being invisible.
  CHECK(json.find("\"hasAudio\": false") != std::string::npos);
}

void checksumMatchesTheReference() {
  // The check value every CRC-32 (IEEE) implementation agrees on for "123456789".
  const std::string input = "123456789";
  CHECK_EQ(fourdgs::conformance::crc32String(
               reinterpret_cast<const std::uint8_t*>(input.data()), input.size()),
           std::string("3421780262"));
  CHECK_EQ(fourdgs::conformance::crc32String(nullptr, 0), std::string("0"));
}

void keysAreSorted() {
  Json json = Json::object({
      {"zulu", Json::number("1")},
      {"alpha", Json::number("2")},
  });
  const std::string rendered = json.render();
  CHECK(rendered.find("alpha") < rendered.find("zulu"));
}

void stringsAreEscaped() {
  CHECK_EQ(Json::string("a\"b\\c\nd").render(), std::string("\"a\\\"b\\\\c\\nd\""));
}

void runTests() {
  orderCannotChangeTheSummary();
  integersAreStringsAndInfinityIsNull();
  floatsAreRoundedToSixDecimals();
  absentAudioIsAValue();
  checksumMatchesTheReference();
  keysAreSorted();
  stringsAreEscaped();
}

}  // namespace

TEST_MAIN
