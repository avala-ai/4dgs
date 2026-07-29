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

}  // namespace fourdgs

#endif  // FOURDGS_WRITER_HPP
