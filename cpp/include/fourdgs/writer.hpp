// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_WRITER_HPP
#define FOURDGS_WRITER_HPP

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "fourdgs/model.hpp"
#include "fourdgs/result.hpp"

/// Authoring the other direction: gaussians in, a `.4dgs` byte buffer out.
///
/// The C++ package is a binding over the Rust core rather than a second encoder, so this is a
/// thin surface over the core's `fourdgs_writer_*` C ABI — the same relationship the decode
/// side has. Decode ends at gaussian state; encode begins there. What produced the gaussians —
/// a fit, a conversion, a capture — is out of scope, exactly as drawing them is on the decode
/// side.
namespace fourdgs {

/// How a scene is written. The defaults are the encoder's own: a full summary with an index
/// and a CRC, all three spherical harmonic bands, and no per-band bit depths.
struct WriteOptions {
  /// The Header's marginal visibility threshold. It sets the support constant the
  /// per-gaussian velocity grid is derived from, so it must be the one a decoder reads back.
  double cutoff = 0.05;
  /// The temporal partition's depth. 0 writes one chunk per window.
  std::uint32_t maxDepth = 6;
  /// A node with fewer gaussians than this gives them back to its parent rather than
  /// becoming a chunk of its own.
  std::size_t minChunkGaussians = 2048;
  bool writeIndex = true;
  bool writeStatistics = false;
  bool writeSummaryOffsets = false;
  bool writeCrc = true;
  /// The highest spherical harmonic band to write, 0 to 3.
  std::uint8_t shBands = 3;
  /// Per-band bit depths, band 1 first. Empty leaves the coefficients as the profile alone
  /// decides — what a file written before this option existed did, byte for byte.
  std::vector<std::uint8_t> shBitDepths;
  /// The Header's `profile`: a promise about the file's shape.
  std::string profile;
  /// The Header's `library`. Empty leaves the encoder's own default in place, so a caller
  /// that does not care carries the same string every other default-configured writer does.
  std::string library;
  /// The Header's free-form attributes map.
  std::map<std::string, std::string> attributes;
};

/// Encode decoded gaussians into a `.4dgs` byte buffer.
///
/// `gaussians` is borrowed for the duration of the call and copied into the encoder, so a
/// view straight from a decoder's working set is a valid argument. The encoder verifies its
/// own bounds before returning — it decodes every chunk back and refuses a file whose measured
/// deviation exceeds what it declares — so a success is a file whose Quantization record was
/// checked on every gaussian. `kNotImplemented` when the package was built without the core.
Result<std::vector<std::uint8_t>> encodeScene(const GaussianView& gaussians, double durationSec,
                                              const WriteOptions& options = WriteOptions());

/// A delta references the keyframe at the head of its group of pictures — spec §11.4.
constexpr std::uint8_t kDeltaModeKeyframe = 0;
/// A delta references the state chunk immediately before it. The recommended default.
constexpr std::uint8_t kDeltaModeChained = 1;

/// One population at one instant, with identity — spec §11.1 and §11.2.
///
/// `ids` is the `gaussian_id` stream, one per gaussian and aligned with the columns. It is
/// the only thing that ties a delta to the gaussian it changes, so a producer that reorders
/// a population between samples costs nothing: correspondence is by id, never by row.
///
/// Both the ids and the gaussians are borrowed for the duration of the encode call and
/// copied into the core, so a view straight from a decoder's working set is a valid argument.
struct KeyframeDeltaSample {
  /// Where this sample's interval starts. Sample `i` covers `[t0_i, t0_{i+1})`, the first
  /// starts at 0 and the last ends at the sequence's duration — the tiling rule of §11.1.
  /// A duration of positive infinity gives the final sample an open-ended interval.
  double t0 = 0.0;
  Span<const std::uint32_t> ids;
  GaussianView gaussians;
};

/// How a `keyframe-delta` sequence is written. The defaults are the reference writer's.
struct KeyframeDeltaOptions {
  /// Samples per group of pictures. 1 writes every sample as a keyframe, which is the
  /// shape §11.11 says subsumes the reserved `frame-sequence` name.
  std::uint32_t keyframeEvery = 8;
  /// `kDeltaModeChained` or `kDeltaModeKeyframe`, spec §11.4. Chained is smaller and
  /// adjacent in the file; neither accumulates error, because a delta is a difference of
  /// bins rather than a quantization of a difference (§11.7).
  std::uint8_t deltaMode = kDeltaModeChained;
  /// Sample indices to force a keyframe at, beyond the cadence — a chapter boundary, a shot
  /// cut, a loop start, made to cost two records however deep into the group it falls.
  std::vector<std::uint32_t> keyframeAt;
  /// The quantization profile the whole sequence shares: `fine`, `default` or `coarse`.
  /// Every sample is quantized on one set of grids, which is what makes a bin difference
  /// meaningful. Empty leaves the encoder's own default.
  std::string profile;
  /// The Header's marginal visibility threshold, as on `WriteOptions`.
  ///
  /// This and the two compression fields below restate the core's own defaults rather than
  /// deferring to them, which is the convention every SDK follows — Python's `write_sequence`
  /// signature and Swift's `KeyframeDeltaOptions` spell out the same three numbers. The cost
  /// is that there is no way to ask for "whatever the core's default is": these values are
  /// always sent, so if the core's default moves, this keeps writing the old one until it is
  /// updated here too. Changing that is a cross-SDK decision rather than this binding's to
  /// make on its own (AGENTS.md §8), so it is written down instead of quietly diverged from.
  double cutoff = 0.05;
  /// The Header's `library`. Empty leaves the encoder's default in place.
  std::string library;
  /// The codec every attribute stream is compressed with — 0 deflate, 1 zstd — and its level.
  /// Restated defaults, as `cutoff` above. A codec this build of the core has no encoder for
  /// is refused as `kUnsupported`: legal, but not implemented here.
  std::uint8_t codec = 0;
  std::uint32_t level = 6;
};

/// Encode a sequence of populations as a whole `keyframe-delta` file (spec §11).
///
/// This is a different shape of encode from `encodeScene`, not an option on it: a
/// `keyframe-delta` file is a sequence of states with correspondence between them rather than
/// one population of independently-lived gaussians, so it takes samples rather than
/// gaussians. The model's arithmetic is entirely the core's — the writer quantizes every
/// sample on one shared set of grids and each delta carries integer bin differences against
/// its reference, restating `rotation_index` and `rotation` absolutely and never carrying
/// `sigma_t`, `flags` or `window_index` in an update group (§11.5).
///
/// `kNotImplemented` when the package was built without the core; `kInvalidArgument` when the
/// duration is NaN or non-positive, sample instants do not strictly tile `[0, durationSec)`, an
/// identity repeats within one sample or reappears after death, or the samples break another
/// producer rule from §11. Positive infinity is a valid open-ended duration. The error message
/// names the sample and offending instant or gaussian.
Result<std::vector<std::uint8_t>> encodeKeyframeDeltaSequence(
    Span<const KeyframeDeltaSample> samples, double durationSec,
    const KeyframeDeltaOptions& options = KeyframeDeltaOptions());

}  // namespace fourdgs

#endif  // FOURDGS_WRITER_HPP
