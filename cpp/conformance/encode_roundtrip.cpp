// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: encode.
///
/// Decode a variant, re-encode the gaussians it yields, and write the result. The gate around
/// this (tests/conformance/encode_roundtrip.py) then re-encodes the same variant with the Rust
/// reference and requires the Python decoder to produce identical canonical JSON from both —
/// which, since C++ reaches the same Rust encoder through the C ABI, proves the binding wired
/// the gaussians and options through correctly rather than that a second encoder agrees.
///
/// The option preset is the reference's `gaussians_only_options`, reproduced here field for
/// field. A drift between the two is what the gate exists to catch, so it lives in both places
/// on purpose rather than in a shared file neither language could own.
///
/// Usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]

#include <cstdint>
#include <cstdio>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::GaussianView;
using fourdgs::ReadMode;
using fourdgs::Result;
using fourdgs::Scene;
using fourdgs::WriteOptions;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

/// A comma-separated list of per-band bit depths, band 1 first. The gate resolves ladder
/// names to a list before handing them here, so every language parses the same thing.
Result<std::vector<std::uint8_t>> parseDepths(const std::string& spec) {
  std::vector<std::uint8_t> depths;
  std::stringstream stream(spec);
  std::string part;
  while (std::getline(stream, part, ',')) {
    try {
      const int value = std::stoi(part);
      if (value < 0 || value > 255) return Error(ErrorCode::kInvalidArgument, spec + ": a bit depth is out of range");
      depths.push_back(static_cast<std::uint8_t>(value));
    } catch (const std::exception&) {
      return Error(ErrorCode::kInvalidArgument, spec + ": not a comma-separated list of bit depths");
    }
  }
  return depths;
}

Result<void> writeWhole(const std::string& path, const std::vector<std::uint8_t>& bytes) {
  std::FILE* handle = std::fopen(path.c_str(), "wb");
  if (handle == nullptr) return Error(ErrorCode::kIo, "cannot open " + path + " for writing");
  if (!bytes.empty()) std::fwrite(bytes.data(), 1, bytes.size(), handle);
  std::fclose(handle);
  return Result<void>();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) {
    std::fprintf(stderr, "usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]\n");
    return 2;
  }
  const std::string input = argv[1];
  const std::string output = argv[2];

  std::vector<std::uint8_t> depths;
  if (argc == 4) {
    Result<std::vector<std::uint8_t>> parsed = parseDepths(argv[3]);
    if (!parsed) return fail(parsed.error().toString());
    depths = *parsed;
  }

  Result<std::unique_ptr<Scene>> opened = Scene::openPath(input, ReadMode::kSequential);
  if (!opened) return fail(opened.error().toString());
  Scene& scene = **opened;

  Result<void> loaded = scene.loadAll(3);
  if (!loaded) return fail(loaded.error().toString());

  // The gaussians-only preset, matching rust/conformance/src/bin/encode_gaussians.rs. The
  // small chunk threshold is what makes the corpus scenes exercise the chunk tree rather than
  // collapse to a single chunk each; the whole summary is written; the profile and attributes
  // ride along; the library is left at the encoder's default so both sides carry the same one.
  WriteOptions options;
  options.cutoff = scene.cutoff();
  options.maxDepth = 4;
  options.minChunkGaussians = 8;
  options.writeIndex = true;
  options.writeStatistics = true;
  options.writeSummaryOffsets = true;
  options.writeCrc = true;
  options.shBands = 3;
  options.shBitDepths = depths;
  options.profile = scene.profile();
  options.attributes = scene.attributes();

  Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeScene(scene.gaussians(), scene.durationSec(), options);
  if (!encoded) return fail(encoded.error().toString());

  Result<void> written = writeWhole(output, *encoded);
  if (!written) return fail(written.error().toString());

  std::printf("%zu gaussians, %zu bytes\n", scene.gaussians().count, encoded->size());
  return 0;
}
