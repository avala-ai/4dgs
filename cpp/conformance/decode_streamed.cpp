// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: streamed decode, canonical JSON to stdout.
///
/// The whole interface between an implementation and the harness is this: take a path, print
/// the canonical JSON. Anything wrong exits non-zero with a sentence on stderr, and the
/// harness reports it like a diff.

#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "canonical.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ChunkIndexEntry;
using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::GaussianData;
using fourdgs::GaussianView;
using fourdgs::Result;
using fourdgs::StreamDecoder;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

template <typename T>
void copyInto(std::vector<T>* out, const fourdgs::Span<const T>& in) {
  out->assign(in.begin(), in.end());
}

/// One streamed decode: the scene's gaussians, and the decoder still holding everything the
/// file said about itself.
struct Decoded {
  std::unique_ptr<StreamDecoder> decoder;
  GaussianData gaussians;
  std::vector<std::pair<double, double>> chunkIntervals;
  bool truncated = false;
};

Result<Decoded> decode(fourdgs::Readable& source) {
  Result<std::unique_ptr<StreamDecoder>> opened = StreamDecoder::open(source);
  if (!opened) return opened.error();

  Decoded decoded;
  decoded.decoder = std::move(*opened);
  StreamDecoder& decoder = *decoded.decoder;

  GaussianData chunk;
  for (;;) {
    Result<bool> advanced = decoder.next();
    if (!advanced) return advanced.error();
    if (!*advanced) break;
    // Accumulating is the runner's choice, not the decoder's: the summary is over the whole
    // scene. The decoder still holds one chunk at a time, which is the property under test.
    const GaussianView& view = decoder.gaussians();
    chunk.count = view.count;
    chunk.shDegree = view.shDegree;
    chunk.shCoefficients = view.shCoefficients;
    copyInto(&chunk.positions, view.positions);
    copyInto(&chunk.scales, view.scales);
    copyInto(&chunk.rotations, view.rotations);
    copyInto(&chunk.colors, view.colors);
    copyInto(&chunk.motions, view.motions);
    copyInto(&chunk.muT, view.muT);
    copyInto(&chunk.sigmaT, view.sigmaT);
    copyInto(&chunk.winLo, view.winLo);
    copyInto(&chunk.winHi, view.winHi);
    copyInto(&chunk.sh, view.sh);
    decoded.gaussians.append(chunk);
  }

  for (const ChunkIndexEntry& entry : decoder.chunkIndex()) {
    decoded.chunkIntervals.emplace_back(entry.t0, entry.t1);
  }
  decoded.truncated = decoder.truncated();
  return std::move(decoded);
}

/// Decode the same file cut short, and insist on what survives.
///
/// Nothing in the corpus is truncated, so this makes one. The canonical JSON cannot express
/// truncation recovery — a cut file is a different file — so the check lives here, where a
/// failure exits non-zero and the harness reports it like any other.
Result<void> checkTruncationRecovery(const std::vector<std::uint8_t>& bytes, const Decoded& full) {
  if (bytes.size() < 2) return Error(ErrorCode::kInvalidArgument, "the file is too short to cut");

  {
    fourdgs::MemoryReadable source(std::vector<std::uint8_t>(bytes.begin(), bytes.end() - 1));
    Result<Decoded> cut = decode(source);
    if (!cut) return cut.error();
    if (!cut->truncated) {
      return Error(ErrorCode::kMalformed,
                   "a file cut before its trailing magic was not reported truncated");
    }
    if (cut->gaussians.count != full.gaussians.count) {
      return Error(ErrorCode::kMalformed,
                   "cutting the trailing magic lost gaussians: " +
                       std::to_string(cut->gaussians.count) + " of " +
                       std::to_string(full.gaussians.count));
    }
  }

  const std::vector<ChunkIndexEntry>& index = full.decoder->chunkIndex();
  if (index.size() >= 2) {
    const ChunkIndexEntry& last = index.back();
    const std::size_t at = static_cast<std::size_t>(last.chunkOffset) + 5;
    if (at >= bytes.size()) return Result<void>();
    fourdgs::MemoryReadable source(
        std::vector<std::uint8_t>(bytes.begin(), bytes.begin() + static_cast<long>(at)));
    Result<Decoded> cut = decode(source);
    if (!cut) return cut.error();
    if (!cut->truncated) {
      return Error(ErrorCode::kMalformed,
                   "a file cut inside a chunk record was not reported truncated");
    }
    const std::size_t expected = full.gaussians.count - last.gaussianCount;
    if (cut->gaussians.count != expected) {
      return Error(ErrorCode::kMalformed,
                   "cutting the last chunk left " + std::to_string(cut->gaussians.count) +
                       " gaussians, expected " + std::to_string(expected));
    }
  }
  return Result<void>();
}

Result<std::vector<std::uint8_t>> readWhole(const std::string& path) {
  std::FILE* handle = std::fopen(path.c_str(), "rb");
  if (handle == nullptr) return Error(ErrorCode::kIo, "cannot open " + path);
  std::vector<std::uint8_t> bytes;
  std::uint8_t buffer[65536];
  std::size_t got = 0;
  while ((got = std::fread(buffer, 1, sizeof(buffer), handle)) > 0) {
    bytes.insert(bytes.end(), buffer, buffer + got);
  }
  std::fclose(handle);
  return bytes;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: decode_streamed <file.4dgs>\n");
    return 2;
  }
  const std::string path = argv[1];

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> source(*file);

  Result<Decoded> decoded = decode(*source);
  if (!decoded) return fail(decoded.error().toString());

  Result<std::vector<std::uint8_t>> bytes = readWhole(path);
  if (!bytes) return fail(bytes.error().toString());
  Result<void> recovery = checkTruncationRecovery(*bytes, *decoded);
  if (!recovery) return fail(recovery.error().toString());

  const StreamDecoder& decoder = *decoded->decoder;
  GaussianView view(decoded->gaussians);
  fourdgs::conformance::SceneSummary summary;
  summary.header = &decoder.header();
  summary.gaussians = &view;
  summary.audio = decoder.audio();
  summary.chunkIntervals = decoded->chunkIntervals;
  summary.camera = decoder.camera();
  summary.metadata = decoder.metadata();
  summary.attachments = decoder.attachments();
  summary.statistics = decoder.statistics();
  summary.summaryOffsets = decoder.summaryOffsets();
  summary.summaryCrcOk = decoder.summaryCrcOk();

  std::printf("%s\n", fourdgs::conformance::canonical(summary).c_str());
  return 0;
}
