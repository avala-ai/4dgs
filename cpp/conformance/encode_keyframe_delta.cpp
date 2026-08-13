// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: encode a `keyframe-delta` file (spec §11).
///
/// There is no corpus variant to re-encode here the way `encode_roundtrip` re-encodes one:
/// the keyframe-delta corpus is a whole-file format this package reads through the core's
/// byte-in / string-out surface rather than through an opened `Scene`, so there is no
/// decoded sample sequence to hand back to a writer. This synthesizes one instead —
/// deterministically, from an LCG, so the encoder has no hidden state — matching
/// `rust/conformance/src/bin/encode_keyframe_delta.rs` sample for sample in shape: gaussians
/// move, so every non-keyframe sample carries updates; a band of ids is born partway through
/// and another dies later, so births and deaths both occur; ids are rotated within each
/// sample, so a writer that paired gaussians by row rather than by `gaussian_id` would be
/// wrong; and the cadence lays down more than one keyframe with deltas between them.
///
/// Beside each file it writes the samples it was written from, as JSON. That is what lets
/// the gate around this (`cpp/keyframe-delta-roundtrip.sh`) make the claim no amount of
/// decoder agreement can make: the file, read back by the *Python reference*, against the
/// population that went in and the bounds the file itself declares. An encoder that displaced
/// every position produces a file every decoder reads the same way, and it is wrong.
///
/// Usage: encode_keyframe_delta <out-dir> [chained|keyframe|cadence-one]

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ErrorCode;
using fourdgs::GaussianData;
using fourdgs::GaussianView;
using fourdgs::KeyframeDeltaOptions;
using fourdgs::KeyframeDeltaSample;
using fourdgs::Result;

constexpr double kDuration = 2.0;
constexpr std::size_t kSamples = 17;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

/// A tiny linear congruential generator: deterministic, portable, and enough variety for a
/// synthetic scene. Not for anything that needs statistical quality. Unsigned overflow wraps
/// by definition in C++, which is what makes this the same generator in every language that
/// has it.
class Lcg {
 public:
  explicit Lcg(std::uint64_t seed)
      // Offset so id 0 is not a degenerate all-zero stream.
      : state_(seed * 0x9E3779B97F4A7C15ull + 1ull) {}

  /// A value in `[0, 1)`.
  double unit() {
    state_ = state_ * 6364136223846793005ull + 1442695040888963407ull;
    return static_cast<double>(state_ >> 11) / static_cast<double>(1ull << 53);
  }

 private:
  std::uint64_t state_;
};

/// One sample's identities and its population.
struct Population {
  std::vector<std::uint32_t> ids;
  GaussianData gaussians;
};

/// Which ids are live at sample `i`, in the order this sample states them.
std::vector<std::uint32_t> idsAt(std::size_t i) {
  std::vector<std::uint32_t> ids;
  for (std::uint32_t id = 0; id < 24; ++id) ids.push_back(id);
  if (i >= 5) {
    for (std::uint32_t id = 24; id < 28; ++id) ids.push_back(id);  // born at sample 5
  }
  if (i >= 11) {
    std::vector<std::uint32_t> survivors;
    for (std::uint32_t id : ids) {
      if (id >= 4) survivors.push_back(id);  // ids 0..3 die at sample 11
    }
    ids = survivors;
  }
  // Rotate, so that identity and not row position decides correspondence.
  const std::size_t shift = ids.empty() ? 0 : i % ids.size();
  std::rotate(ids.begin(), ids.begin() + static_cast<std::ptrdiff_t>(shift), ids.end());
  return ids;
}

Population populationAt(std::size_t i) {
  Population population;
  population.ids = idsAt(i);
  const std::size_t n = population.ids.size();
  GaussianData& g = population.gaussians;
  g.resize(n, 0, 0);
  for (std::size_t row = 0; row < n; ++row) {
    Lcg rng(population.ids[row]);
    // A per-gaussian base plus a small per-sample drift: the drift is what a non-keyframe
    // sample records as an update.
    const double base[3] = {rng.unit() * 4.0 - 2.0, rng.unit() * 4.0 - 2.0, rng.unit() * 4.0 - 2.0};
    const double drift[3] = {(rng.unit() - 0.5) * 0.2, (rng.unit() - 0.5) * 0.2,
                             (rng.unit() - 0.5) * 0.2};
    for (std::size_t axis = 0; axis < 3; ++axis) {
      g.positions[row * 3 + axis] =
          static_cast<float>(base[axis] + drift[axis] * static_cast<double>(i));
      g.scales[row * 3 + axis] = static_cast<float>(0.02 + rng.unit() * 0.1);
    }
    // A unit quaternion, restated absolutely by every update (§11.5).
    const double qx = rng.unit() - 0.5;
    const double qy = rng.unit() - 0.5;
    const double qz = rng.unit() - 0.5;
    const double qw = 1.0;
    const double norm = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    g.rotations[row * 4 + 0] = static_cast<float>(qx / norm);
    g.rotations[row * 4 + 1] = static_cast<float>(qy / norm);
    g.rotations[row * 4 + 2] = static_cast<float>(qz / norm);
    g.rotations[row * 4 + 3] = static_cast<float>(qw / norm);
    g.colors[row * 4 + 0] = static_cast<float>(rng.unit());
    g.colors[row * 4 + 1] = static_cast<float>(rng.unit());
    g.colors[row * 4 + 2] = static_cast<float>(rng.unit());
    g.colors[row * 4 + 3] = static_cast<float>(0.3 + 0.6 * rng.unit());
    // A constant velocity per gaussian: the motion bins differ from zero and telescope
    // through the chain, which is the property §11.7 is about.
    for (std::size_t axis = 0; axis < 3; ++axis) {
      g.motions[row * 3 + axis] = static_cast<float>((rng.unit() - 0.5) * 0.5);
    }
    g.muT[row] = static_cast<float>(rng.unit() * kDuration);
    g.sigmaT[row] = static_cast<float>(0.2 + rng.unit() * 0.8);
    // One validity window for the whole sequence. `window_index` is GOP-invariant (§11.5),
    // so a fixture that varied it would be exercising the refusal rather than the encode.
    g.winLo[row] = 0.0f;
    g.winHi[row] = static_cast<float>(kDuration);
  }
  return population;
}

/// A number as JSON, at the precision that round-trips a `double` exactly.
///
/// Seventeen significant digits rather than the nine a `float` needs: `t0` is a double, and
/// the gate compares it against the chunk interval the file carries, which is also a double.
/// Nine digits there turns an exact comparison into a near-miss.
std::string number(double value) {
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%.17g", value);
  return buffer;
}

std::string floatArray(const std::vector<float>& values) {
  std::string out = "[";
  for (std::size_t i = 0; i < values.size(); ++i) {
    if (i != 0) out += ",";
    out += number(static_cast<double>(values[i]));
  }
  return out + "]";
}

/// The samples, as the gate reads them back. Hand-written rather than through a JSON library
/// for the reason `check.hpp` has no test framework: a dependency for four object shapes.
Result<void> writeSamplesJson(const std::string& path, const std::vector<Population>& populations,
                              const std::vector<double>& t0s) {
  std::FILE* handle = std::fopen(path.c_str(), "wb");
  if (handle == nullptr) return fourdgs::Error(ErrorCode::kIo, "cannot open " + path);
  std::string out = "{\"durationSec\":" + number(kDuration) + ",\"samples\":[";
  for (std::size_t i = 0; i < populations.size(); ++i) {
    const GaussianData& g = populations[i].gaussians;
    if (i != 0) out += ",";
    out += "{\"t0\":" + number(t0s[i]) + ",\"count\":" + std::to_string(g.count) + ",\"ids\":[";
    for (std::size_t row = 0; row < populations[i].ids.size(); ++row) {
      if (row != 0) out += ",";
      out += std::to_string(populations[i].ids[row]);
    }
    out += "],\"positions\":" + floatArray(g.positions);
    out += ",\"scales\":" + floatArray(g.scales);
    out += ",\"rotations\":" + floatArray(g.rotations);
    out += ",\"colors\":" + floatArray(g.colors);
    out += ",\"motions\":" + floatArray(g.motions);
    out += ",\"muT\":" + floatArray(g.muT);
    out += ",\"sigmaT\":" + floatArray(g.sigmaT);
    out += ",\"winLo\":" + floatArray(g.winLo);
    out += ",\"winHi\":" + floatArray(g.winHi) + "}";
  }
  out += "]}\n";
  std::fwrite(out.data(), 1, out.size(), handle);
  std::fclose(handle);
  return Result<void>();
}

Result<void> writeWhole(const std::string& path, const std::vector<std::uint8_t>& bytes) {
  std::FILE* handle = std::fopen(path.c_str(), "wb");
  if (handle == nullptr) return fourdgs::Error(ErrorCode::kIo, "cannot open " + path);
  if (!bytes.empty()) std::fwrite(bytes.data(), 1, bytes.size(), handle);
  std::fclose(handle);
  return Result<void>();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3) {
    std::fprintf(stderr, "usage: encode_keyframe_delta <out-dir> [chained|keyframe|cadence-one]\n");
    return 2;
  }
  const std::string directory = argv[1];
  const std::string shape = argc == 3 ? argv[2] : "chained";

  KeyframeDeltaOptions options;
  if (shape == "chained") {
    options.keyframeEvery = 8;
    options.deltaMode = fourdgs::kDeltaModeChained;
  } else if (shape == "keyframe") {
    options.keyframeEvery = 8;
    options.deltaMode = fourdgs::kDeltaModeKeyframe;
  } else if (shape == "cadence-one") {
    // §11.11: every chunk a keyframe. The shape that subsumes the reserved
    // `frame-sequence` name, and the one a writer reaches by cadence alone.
    options.keyframeEvery = 1;
  } else {
    std::fprintf(stderr, "unknown shape %s; expected chained, keyframe or cadence-one\n",
                 shape.c_str());
    return 2;
  }

  std::vector<Population> populations;
  std::vector<double> t0s;
  populations.reserve(kSamples);
  for (std::size_t i = 0; i < kSamples; ++i) {
    populations.push_back(populationAt(i));
    // The t0s tile [0, duration): the last sample starts below the end and its interval
    // closes at `duration`, so no chunk gets a zero-width span (§11.1).
    t0s.push_back(static_cast<double>(i) / static_cast<double>(kSamples) * kDuration);
  }

  // Built after every population is in place: a `GaussianView` borrows, so a view taken from
  // a vector that later reallocates would dangle.
  std::vector<KeyframeDeltaSample> samples;
  samples.reserve(kSamples);
  for (std::size_t i = 0; i < kSamples; ++i) {
    KeyframeDeltaSample sample;
    sample.t0 = t0s[i];
    sample.ids =
        fourdgs::Span<const std::uint32_t>(populations[i].ids.data(), populations[i].ids.size());
    sample.gaussians = GaussianView(populations[i].gaussians);
    samples.push_back(sample);
  }
  const fourdgs::Span<const KeyframeDeltaSample> span(samples.data(), samples.size());

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(span, kDuration, options);
  if (!encoded) return fail(encoded.error().toString());

  // Two encodes of one sequence must be the same bytes. A writer that iterated a map, or
  // sorted unstably, passes every value-based check and still produces a file that differs
  // between runs — a property nobody notices until a build is expected to reproduce.
  Result<std::vector<std::uint8_t>> again =
      fourdgs::encodeKeyframeDeltaSequence(span, kDuration, options);
  if (!again) return fail(again.error().toString());
  if (*again != *encoded) {
    return fail(shape + ": two encodes of one sequence differ; the writer is not deterministic");
  }

  // The file has to survive both of this package's read paths, and they must reach the same
  // populations, before it is worth asking another implementation about it.
  const fourdgs::Span<const std::uint8_t> bytes(encoded->data(), encoded->size());
  Result<std::string> streamed = fourdgs::keyframeDeltaStatesJson(bytes, false);
  if (!streamed)
    return fail(shape + ": the writer wrote a file it cannot stream-decode: " +
                streamed.error().toString());
  Result<std::string> indexed = fourdgs::keyframeDeltaStatesJson(bytes, true);
  if (!indexed)
    return fail(shape +
                ": the writer wrote a file it cannot index-decode: " + indexed.error().toString());
  if (*streamed != *indexed) {
    return fail(shape + ": the two read paths disagree on a file the writer produced");
  }

  const std::string stem = directory + "/keyframe-delta-" + shape;
  Result<void> written = writeWhole(stem + ".4dgs", *encoded);
  if (!written) return fail(written.error().toString());
  written = writeSamplesJson(stem + ".samples.json", populations, t0s);
  if (!written) return fail(written.error().toString());

  std::printf("keyframe-delta-%s %zu samples, %zu bytes, deterministic, both read paths agree\n",
              shape.c_str(), samples.size(), encoded->size());
  return 0;
}
