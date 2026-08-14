// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The canonical JSON, and the property the whole comparison rests on: nothing in it depends
/// on decoded order.

#include <algorithm>
#include <clocale>
#include <cstdio>
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

/// The same gaussians, visited in the requested order.
GaussianData permuted(const GaussianData& source, const std::vector<std::size_t>& order) {
  GaussianData out;
  out.resize(source.count, source.shDegree, source.shCoefficients);
  const std::size_t shWidth = source.shCoefficients * 3;
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
    for (std::size_t k = 0; k < shWidth; ++k) {
      out.sh[to * shWidth + k] = source.sh[from * shWidth + k];
    }
  }
  return out;
}

/// The same gaussians, visited in a different order.
GaussianData shuffled(const GaussianData& source, unsigned seed) {
  std::vector<std::size_t> order(source.count);
  for (std::size_t i = 0; i < source.count; ++i) order[i] = i;
  std::mt19937 rng(seed);
  std::shuffle(order.begin(), order.end(), rng);
  return permuted(source, order);
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

/// Exact decoded values are the final content tiebreaker. Both motions round to zero in
/// the canonical key, so a stable sort alone would preserve the resident order and put
/// the larger motion first after the permutation.
void roundedTiesUseExactDecodedValues() {
  GaussianData original = scene(2, 19);
  for (std::size_t k = 0; k < 3; ++k) {
    original.positions[3 + k] = original.positions[k];
    original.scales[3 + k] = original.scales[k];
  }
  for (std::size_t k = 0; k < 4; ++k) {
    original.rotations[4 + k] = original.rotations[k];
    original.colors[4 + k] = original.colors[k];
  }
  original.motions[0] = 1e-7f;
  original.motions[1] = original.motions[2] = 0.0f;
  original.motions[3] = 4e-7f;
  original.motions[4] = original.motions[5] = 0.0f;
  original.muT[1] = original.muT[0];
  original.sigmaT[1] = original.sigmaT[0];
  original.winLo[1] = original.winLo[0];
  original.winHi[1] = original.winHi[0];
  for (std::size_t k = 0; k < 9; ++k) original.sh[9 + k] = original.sh[k];

  const GaussianData reversed = permuted(original, {1, 0});
  const GaussianView originalView(original);
  const GaussianView reversedView(reversed);
  const std::vector<std::size_t> originalOrder = fourdgs::conformance::stableOrder(originalView);
  const std::vector<std::size_t> reversedOrder = fourdgs::conformance::stableOrder(reversedView);

  CHECK_EQ(originalView.motions[originalOrder[0] * 3], 1e-7f);
  CHECK_EQ(reversedView.motions[reversedOrder[0] * 3], 1e-7f);
}

/// Signed zero is not scene content. Rows that differ only in where its sign appears tie
/// in the content order, so the emitted form must erase that sign before stable resident
/// order can become observable.
void signedZeroCannotExposeResidentOrder() {
  GaussianData original = scene(2, 23);
  for (std::size_t k = 0; k < 3; ++k) {
    original.positions[3 + k] = original.positions[k];
    original.scales[3 + k] = original.scales[k];
    original.motions[3 + k] = original.motions[k];
  }
  for (std::size_t k = 0; k < 4; ++k) {
    original.rotations[4 + k] = original.rotations[k];
    original.colors[4 + k] = original.colors[k];
  }
  original.positions[0] = -0.0f;
  original.positions[1] = 0.0f;
  original.positions[3] = 0.0f;
  original.positions[4] = -0.0f;
  original.muT[1] = original.muT[0];
  original.sigmaT[1] = original.sigmaT[0];
  original.winLo[1] = original.winLo[0];
  original.winHi[1] = original.winHi[0];
  for (std::size_t k = 0; k < 9; ++k) original.sh[9 + k] = original.sh[k];

  CHECK_EQ(summarize(original), summarize(permuted(original, {1, 0})));
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
  CHECK_EQ(fourdgs::conformance::num(-0.0000004).render(), std::string("0.000000"));
  CHECK_EQ(fourdgs::conformance::num(-0.0).render(), std::string("0.000000"));
  CHECK_EQ(fourdgs::conformance::num(2.5).render(), std::string("2.500000"));
}

void absentAudioIsAValue() {
  const std::string json = summarize(scene(4, 5));
  CHECK(json.find("\"audioSources\": []") != std::string::npos);
  // Both paths visible in every implementation's output, rather than one being invisible.
  CHECK(json.find("\"hasAudio\": false") != std::string::npos);
}

void checksumMatchesTheReference() {
  // The check value every CRC-32 (IEEE) implementation agrees on for "123456789".
  const std::string input = "123456789";
  CHECK_EQ(fourdgs::conformance::crc32String(reinterpret_cast<const std::uint8_t*>(input.data()),
                                             input.size()),
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

/// The substitution itself, asked directly, because the end-to-end check below can only run
/// on a machine that has a comma-radix locale installed and most CI images do not.
///
/// Both directions and both widths: `,` is one byte, and a locale is free to spell its radix
/// with several — `localeconv()->decimal_point` is a string, not a character, and reading
/// only its first byte would corrupt the number rather than convert it.
void theRadixIsRewrittenBothWays() {
  using fourdgs::conformance::detail::radixFromJson;
  using fourdgs::conformance::detail::radixToJson;

  CHECK_EQ(radixToJson("-0,050000", ","), std::string("-0.050000"));
  CHECK_EQ(radixToJson("0.050000", "."), std::string("0.050000"));
  // Arabic decimal separator U+066B, three bytes in UTF-8.
  CHECK_EQ(radixToJson("12\xd9\xab"
                       "500000",
                       "\xd9\xab"),
           std::string("12.500000"));

  CHECK_EQ(radixFromJson("-0.050000", ","), std::string("-0,050000"));
  CHECK_EQ(radixFromJson("0.050000", "."), std::string("0.050000"));
  CHECK_EQ(radixFromJson("12.500000", "\xd9\xab"), std::string("12\xd9\xab"
                                                               "500000"));

  // A number with no radix at all is left alone rather than gaining one.
  CHECK_EQ(radixToJson("-12", ","), std::string("-12"));
  CHECK_EQ(radixFromJson("-12", ","), std::string("-12"));
}

/// A summary is JSON, and JSON spells a radix `.` — whatever `LC_NUMERIC` says.
///
/// `snprintf` and `strtod` both take the radix from the locale, and this canonicalizer is a
/// library: linked into a host that calls `setlocale(LC_ALL, "")` — which ICU, Qt and GTK all
/// do during initialisation — under a comma-radix locale, `num(0.05).render()` produced
/// `"0,050000"` and every corpus file failed to parse in `run.py`. Rounding is affected too,
/// through `strtod` in `roundToDecimals`, so the content order moved with it.
///
/// The locale is restored before returning: the process runs the rest of the suite after this.
void theCanonicalRadixIsNotTheLocaleRadix() {
  const char* saved = std::setlocale(LC_NUMERIC, nullptr);
  const std::string restore = saved == nullptr ? "C" : saved;

  // No single name is portable, so this asks for several and uses whichever the machine
  // happens to have. Anything with a comma radix answers the question.
  const char* candidates[] = {
      "de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8",         "fr_FR.utf8",
      "en_DK.UTF-8", "en_DK.utf8", "German_Germany.1252", "de_DE",
  };
  std::setlocale(LC_NUMERIC, "C");
  const std::string underC = summarize(scene(8, 11));

  bool exercised = false;
  for (const char* name : candidates) {
    if (std::setlocale(LC_NUMERIC, name) == nullptr) continue;
    if (std::string(std::localeconv()->decimal_point) == ".") continue;
    exercised = true;

    CHECK_EQ(fourdgs::conformance::num(0.05).render(), std::string("0.050000"));
    CHECK_EQ(fourdgs::conformance::num(-2.5).render(), std::string("-2.500000"));
    CHECK_EQ(fourdgs::conformance::num(-0.0000004).render(), std::string("0.000000"));
    // The whole document, not one number. `roundToDecimals` reads the rendered text back
    // through `strtod`, which is as locale-bound as the render was: handed a radix it cannot
    // parse it stops at the integer part, so the content-order key silently loses every
    // fractional digit and the rows come out in a different order.
    CHECK_EQ(summarize(scene(8, 11)), underC);
    break;
  }
  std::setlocale(LC_NUMERIC, restore.c_str());
  // Not a failure: an image with only C and en_US cannot express the question, and
  // `theRadixIsRewrittenBothWays` covers the mechanism on every machine.
  if (!exercised) {
    std::printf("note: no comma-radix locale installed; the end-to-end radix check did not run\n");
  }
}

void runTests() {
  orderCannotChangeTheSummary();
  roundedTiesUseExactDecodedValues();
  signedZeroCannotExposeResidentOrder();
  integersAreStringsAndInfinityIsNull();
  floatsAreRoundedToSixDecimals();
  absentAudioIsAValue();
  checksumMatchesTheReference();
  keysAreSorted();
  stringsAreEscaped();
  theRadixIsRewrittenBothWays();
  theCanonicalRadixIsNotTheLocaleRadix();
}

}  // namespace

TEST_MAIN
