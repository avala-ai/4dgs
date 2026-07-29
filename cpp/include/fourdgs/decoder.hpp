// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_DECODER_HPP
#define FOURDGS_DECODER_HPP

#include <memory>
#include <vector>

#include "fourdgs/model.hpp"
#include "fourdgs/readable.hpp"
#include "fourdgs/result.hpp"

namespace fourdgs {

namespace detail {
class Handle;
}

/// Front-to-back decode: works on a pipe, and on a file that stops mid-record.
///
/// One chunk is resident at a time. `next()` decodes the following chunk into the decoder's
/// own buffers and `gaussians()` views them, so a scene of any size costs its largest chunk
/// (cross-SDK principle 1). Records that follow the chunks — the index, statistics,
/// attachments, the footer — are only available once the stream has ended, because that is
/// where the file puts them.
class StreamDecoder {
 public:
  static Result<std::unique_ptr<StreamDecoder>> open(Readable& source);

  ~StreamDecoder();
  StreamDecoder(const StreamDecoder&) = delete;
  StreamDecoder& operator=(const StreamDecoder&) = delete;

  /// Available as soon as the decoder is open: the file's front matter.
  const Header& header() const;
  bool hasAudio() const;                          ///< Header flag alone; no probing, spec §7.
  const AudioTrack* audio() const;                ///< Null when the scene has none.
  const Camera* camera() const;                   ///< Null when the file declares none.
  const std::vector<MetadataRecord>& metadata() const;

  /// Decode the next chunk. `false` means the stream ended; check `truncated()` to learn
  /// whether it ended at the footer or short of it.
  Result<bool> next();

  /// The current chunk's gaussians. Valid until the next call to `next()`.
  const GaussianView& gaussians() const;
  double chunkT0() const;
  double chunkT1() const;

  /// Trailing records, valid once `next()` has returned `false`.
  const std::vector<ChunkIndexEntry>& chunkIndex() const;
  const Statistics* statistics() const;
  const std::vector<Attachment>& attachments() const;
  const std::vector<SummaryOffset>& summaryOffsets() const;
  /// Whether the footer's CRC over the summary verified; absent when the file has no
  /// summary or the bytes never arrived.
  const bool* summaryCrcOk() const;

  /// True when the file ended inside a record. What was decoded before the cut stands.
  bool truncated() const;

 private:
  explicit StreamDecoder(std::unique_ptr<detail::Handle> handle);
  std::unique_ptr<detail::Handle> handle_;
};

/// Indexed decode: the footer, the index, and then only the ranges an instant needs.
///
/// Not an optimization of streaming — a different read path for a different consumer, and
/// both are first-class (cross-SDK principle 2). A file written without an index cannot be
/// read this way; `open()` says so rather than falling back to a sequential scan the caller
/// did not ask for.
class IndexedReader {
 public:
  static Result<std::unique_ptr<IndexedReader>> open(Readable& source);

  ~IndexedReader();
  IndexedReader(const IndexedReader&) = delete;
  IndexedReader& operator=(const IndexedReader&) = delete;

  const Header& header() const;
  const std::vector<ChunkIndexEntry>& index() const;
  const Statistics* statistics() const;
  const std::vector<SummaryOffset>& summaryOffsets() const;
  const bool* summaryCrcOk() const;

  /// The whole seek algorithm, spec §8: every entry whose `[t0, t1)` contains `t`. Local to
  /// the index the reader already holds — no I/O, no core call.
  std::vector<const ChunkIndexEntry*> chunksFor(double t) const;

  /// Read and decode one chunk. `maxShBand` caps the spherical-harmonic bands transferred:
  /// bands above it are never requested from the transport, which is the feature (spec §5.7).
  /// Pass 0 for none and 3 for all.
  Result<GaussianData> readChunk(const ChunkIndexEntry& entry, int maxShBand);

  /// Front matter, each by its own byte range. Audio is absent, not empty, when the scene
  /// has none.
  Result<bool> readAudio(AudioTrack* out);
  Result<bool> readCamera(Camera* out);
  Result<std::vector<MetadataRecord>> readMetadata();
  Result<std::vector<Attachment>> readAttachments();

 private:
  explicit IndexedReader(std::unique_ptr<detail::Handle> handle);
  std::unique_ptr<detail::Handle> handle_;
};

}  // namespace fourdgs

#endif  // FOURDGS_DECODER_HPP
