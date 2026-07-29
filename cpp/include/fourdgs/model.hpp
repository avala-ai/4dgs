// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_MODEL_HPP
#define FOURDGS_MODEL_HPP

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "fourdgs/span.hpp"

/// The data model of the 4dgs specification, in C++.
///
/// The nouns are the specification's nouns (`website/docs/guides/concepts.md`) spelled the
/// way C++ spells things: a scene, its gaussians, its chunks, its optional audio and camera.
/// Nothing here describes how the state is drawn — decode ends at gaussian state at time `t`.
namespace fourdgs {

/// Header, spec §5.1.
struct Header {
  std::string profile;       ///< Well-known profile name, or empty for the base format.
  std::string library;       ///< Free-form producer identification.
  double durationSec = 0.0;  ///< Playback covers [0, durationSec).
  std::uint64_t gaussianCount = 0;
  double cutoff = 0.05;                 ///< Marginal visibility threshold.
  std::string temporalModel;            ///< `"gaussian-birth"` for version 1.
  double aabb[6] = {0, 0, 0, 0, 0, 0};  ///< min xyz, max xyz over rest positions.
  int shDegree = 0;                     ///< 0..3; 0 means no spherical harmonics.
  bool hasAudio = false;                ///< Flags bit 0. The whole audio-discovery rule, spec §7.
  bool chunksCompressed = false;        ///< Flags bit 1.
  std::map<std::string, std::string> attributes;
};

/// One entry of the Chunk Index, spec §5.8. Every offset/length frames a whole record.
struct ChunkIndexEntry {
  double t0 = 0.0;
  double t1 = 0.0;
  std::uint64_t chunkOffset = 0;
  std::uint64_t chunkLength = 0;
  std::uint32_t gaussianCount = 0;
  /// Per spherical-harmonic band, the byte range of its SH Band Stream record. A reader
  /// that caps its degree never asks for the ranges above the cap — spec §5.7.
  struct Band {
    int band = 0;
    std::uint64_t offset = 0;
    std::uint64_t length = 0;
  };
  std::vector<Band> bands;
};

/// Audio, spec §5.9. Absent audio is an absent `std::optional`, never a silent track.
struct AudioTrack {
  std::string codec;
  double startSec = 0.0;
  std::vector<std::uint8_t> data;  ///< The encoded track, verbatim.
};

/// Camera, spec §5.10. Advisory: a consumer may ignore it entirely.
struct Camera {
  double fovYDeg = 0.0;
  double position[3] = {0, 0, 0};
  double target[3] = {0, 0, 0};
  struct Keyframe {
    double time = 0.0;
    double position[3] = {0, 0, 0};
    double target[3] = {0, 0, 0};
  };
  std::vector<Keyframe> keyframes;
  std::string interpolation;
  bool loop = false;
};

/// Metadata, spec §5.11.
struct MetadataRecord {
  std::string name;
  std::map<std::string, std::string> entries;
};

/// Statistics, spec §5.12. Advisory: a consumer needing certainty computes from the chunks.
struct Statistics {
  std::uint64_t gaussianCount = 0;
  std::uint32_t chunkCount = 0;
  double durationSec = 0.0;
  double aabb[6] = {0, 0, 0, 0, 0, 0};
};

/// Attachment, spec §5.13. Not the mechanism for audio.
struct Attachment {
  std::string name;
  std::string mediaType;
  std::vector<std::uint8_t> data;
};

/// Summary Offset, spec §5.14.
struct SummaryOffset {
  std::uint8_t groupOpcode = 0;
  std::uint64_t groupStart = 0;
  std::uint64_t groupLength = 0;
};

/// Decoded gaussians, structure-of-arrays, owned.
///
/// One allocation per attribute rather than an array of structs: it is how the decoder writes
/// them, how a consumer uploads them, and it means a caller that wants only positions touches
/// only positions. Widths are the specification's: 3 for position/scale/motion, 4 for
/// rotation (xyzw) and colour (linear RGB + opacity).
struct GaussianData {
  std::size_t count = 0;
  std::vector<float> positions;  ///< 3 × count
  std::vector<float> scales;     ///< 3 × count
  std::vector<float> rotations;  ///< 4 × count, xyzw
  std::vector<float> colors;     ///< 4 × count, linear RGB + alpha
  std::vector<float> motions;    ///< 3 × count, units per second
  std::vector<float> muT;        ///< count
  std::vector<float> sigmaT;     ///< count; +inf means "never fades"
  std::vector<float> winLo;      ///< count
  std::vector<float> winHi;      ///< count
  /// Spherical harmonic coefficients as stored: unsigned bytes, component-major within a
  /// band, `count × shCoefficients × 3`. `stepSh` is an encode-side value and is *not*
  /// applied here — spec §6.5.
  std::vector<std::uint8_t> sh;
  int shDegree = 0;
  std::size_t shCoefficients = 0;  ///< Per colour component: (shDegree + 1)² − 1.

  void clear();
  /// Grow every array to hold `count` gaussians of the given degree.
  void resize(std::size_t newCount, int degree, std::size_t coefficients);
  /// Append `other`, for a caller assembling a scene from chunks.
  void append(const GaussianData& other);
};

/// A borrowed view of decoded gaussians.
///
/// What a streaming consumer is handed: valid until the decoder advances, never a copy.
struct GaussianView {
  std::size_t count = 0;
  Span<const float> positions;
  Span<const float> scales;
  Span<const float> rotations;
  Span<const float> colors;
  Span<const float> motions;
  Span<const float> muT;
  Span<const float> sigmaT;
  Span<const float> winLo;
  Span<const float> winHi;
  Span<const std::uint8_t> sh;
  int shDegree = 0;
  std::size_t shCoefficients = 0;

  GaussianView() = default;
  explicit GaussianView(const GaussianData& data);
};

/// One gaussian's reconstructed state at a scene time, spec §3.
///
/// This is where decoding ends. There is deliberately nothing here about draw order,
/// culling, level of detail or budgets: that belongs to whatever draws the splats.
struct GaussianState {
  bool visible = false;
  double center[3] = {0, 0, 0};  ///< position + motion × (t − mu_t)
  double marginal = 0.0;
  double opacity = 0.0;  ///< color.a × marginal
};

/// Evaluate gaussian `i` at scene time `t`, exactly as spec §3 defines it.
///
/// `cutoff` is the value in *this file's* header, not the default — the same rule §6.3 makes
/// load-bearing for velocity precision.
inline GaussianState stateAt(const GaussianView& g, std::size_t i, double t, double cutoff) {
  GaussianState s;
  const double muT = static_cast<double>(g.muT[i]);
  const double sigmaT = static_cast<double>(g.sigmaT[i]);
  const double lo = static_cast<double>(g.winLo[i]);
  const double hi = static_cast<double>(g.winHi[i]);

  // A never-fading gaussian has marginal 1 across its whole window: full opacity, hard
  // edges. Reached with the fields that already exist, spec §3.1.
  if (std::isinf(sigmaT)) {
    s.marginal = 1.0;
  } else {
    const double z = (t - muT) / sigmaT;
    s.marginal = std::exp(-0.5 * z * z);
  }

  // The window is the format's only hard temporal gate; outside it a gaussian is absent,
  // whatever its marginal.
  s.visible = (lo <= t) && (t < hi) && (s.marginal >= cutoff);

  for (std::size_t k = 0; k < 3; ++k) {
    s.center[k] = static_cast<double>(g.positions[i * 3 + k]) +
                  static_cast<double>(g.motions[i * 3 + k]) * (t - muT);
  }
  s.opacity = static_cast<double>(g.colors[i * 4 + 3]) * s.marginal;
  return s;
}

}  // namespace fourdgs

#endif  // FOURDGS_MODEL_HPP
