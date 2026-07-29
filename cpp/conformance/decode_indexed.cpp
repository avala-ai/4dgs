// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: indexed decode.
///
/// Reads the footer, then the index, then each chunk by byte range — the path a seeking
/// client takes — and produces the same canonical JSON the streamed runner does. Agreeing
/// with itself across two very different read paths is most of what makes an indexed
/// implementation trustworthy.

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "canonical.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ChunkIndexEntry;
using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::IndexedReader;
using fourdgs::Result;

int fail(const std::string& message) {
  std::fprintf(stderr, "%s\n", message.c_str());
  return 1;
}

/// A reader that has capped its spherical-harmonic degree never transfers the bands above it.
///
/// Counted at the transport, because that is the claim: not that the coefficients are dropped
/// after arriving, but that their bytes were never asked for.
Result<void> checkBandSkipping(fourdgs::CountingReadable& source, IndexedReader& reader) {
  for (const ChunkIndexEntry& entry : reader.index()) {
    if (entry.bands.empty()) continue;
    std::vector<int> caps{0};
    for (const ChunkIndexEntry::Band& band : entry.bands) caps.push_back(band.band);
    for (int cap : caps) {
      const std::uint64_t before = source.bytesRead();
      Result<fourdgs::GaussianData> chunk = reader.readChunk(entry, cap);
      if (!chunk) return chunk.error();
      const std::uint64_t moved = source.bytesRead() - before;
      std::uint64_t wanted = entry.chunkLength;
      for (const ChunkIndexEntry::Band& band : entry.bands) {
        if (band.band <= cap) wanted += band.length;
      }
      if (moved != wanted) {
        return Error(ErrorCode::kMalformed,
                     "reading a chunk with maxShBand=" + std::to_string(cap) + " transferred " +
                         std::to_string(moved) + " bytes, the index says " +
                         std::to_string(wanted));
      }
    }
  }
  return Result<void>();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: decode_indexed <file.4dgs>\n");
    return 2;
  }
  const std::string path = argv[1];

  Result<fourdgs::FileReadable*> file = fourdgs::FileReadable::open(path);
  if (!file) return fail(file.error().toString());
  std::unique_ptr<fourdgs::FileReadable> raw(*file);
  fourdgs::CountingReadable source(raw.get());

  Result<std::unique_ptr<IndexedReader>> opened = IndexedReader::open(source);
  if (!opened) return fail(opened.error().toString());
  IndexedReader& reader = **opened;

  fourdgs::GaussianData gaussians;
  std::vector<std::pair<double, double>> intervals;
  for (const ChunkIndexEntry& entry : reader.index()) {
    Result<fourdgs::GaussianData> chunk = reader.readChunk(entry, 3);
    if (!chunk) return fail(chunk.error().toString());
    gaussians.append(*chunk);
    intervals.emplace_back(entry.t0, entry.t1);
  }

  fourdgs::AudioTrack audio;
  Result<bool> hasAudio = reader.readAudio(&audio);
  if (!hasAudio) return fail(hasAudio.error().toString());

  fourdgs::Camera camera;
  Result<bool> hasCamera = reader.readCamera(&camera);
  if (!hasCamera) return fail(hasCamera.error().toString());

  Result<std::vector<fourdgs::MetadataRecord>> metadata = reader.readMetadata();
  if (!metadata) return fail(metadata.error().toString());

  Result<std::vector<fourdgs::Attachment>> attachments = reader.readAttachments();
  if (!attachments) return fail(attachments.error().toString());

  Result<void> bands = checkBandSkipping(source, reader);
  if (!bands) return fail(bands.error().toString());

  fourdgs::GaussianView view(gaussians);
  fourdgs::conformance::SceneSummary summary;
  summary.header = &reader.header();
  summary.gaussians = &view;
  summary.audio = *hasAudio ? &audio : nullptr;
  summary.chunkIntervals = intervals;
  summary.camera = *hasCamera ? &camera : nullptr;
  summary.metadata = *metadata;
  summary.attachments = *attachments;
  summary.statistics = reader.statistics();
  summary.summaryOffsets = reader.summaryOffsets();
  summary.summaryCrcOk = reader.summaryCrcOk();

  std::printf("%s\n", fourdgs::conformance::canonical(summary).c_str());
  return 0;
}
