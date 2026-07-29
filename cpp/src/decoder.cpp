// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/decoder.hpp"

#include <utility>

#include "backend.hpp"

namespace fourdgs {

StreamDecoder::StreamDecoder(std::unique_ptr<detail::Handle> handle)
    : handle_(std::move(handle)) {}

StreamDecoder::~StreamDecoder() = default;

Result<std::unique_ptr<StreamDecoder>> StreamDecoder::open(Readable& source) {
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  handle->source = &source;
  Result<void> opened = detail::openStream(*handle);
  if (!opened) return opened.error();
  handle->refreshView();
  return std::unique_ptr<StreamDecoder>(new StreamDecoder(std::move(handle)));
}

const Header& StreamDecoder::header() const { return handle_->header; }

bool StreamDecoder::hasAudio() const { return handle_->header.hasAudio; }

const AudioTrack* StreamDecoder::audio() const {
  return handle_->hasAudio ? &handle_->audio : nullptr;
}

const Camera* StreamDecoder::camera() const {
  return handle_->hasCamera ? &handle_->camera : nullptr;
}

const std::vector<MetadataRecord>& StreamDecoder::metadata() const { return handle_->metadata; }

Result<bool> StreamDecoder::next() {
  Result<bool> advanced = detail::nextChunk(*handle_);
  if (advanced && *advanced) handle_->refreshView();
  return advanced;
}

const GaussianView& StreamDecoder::gaussians() const { return handle_->view; }

double StreamDecoder::chunkT0() const { return handle_->chunkT0; }

double StreamDecoder::chunkT1() const { return handle_->chunkT1; }

const std::vector<ChunkIndexEntry>& StreamDecoder::chunkIndex() const { return handle_->index; }

const Statistics* StreamDecoder::statistics() const {
  return handle_->hasStatistics ? &handle_->statistics : nullptr;
}

const std::vector<Attachment>& StreamDecoder::attachments() const { return handle_->attachments; }

const std::vector<SummaryOffset>& StreamDecoder::summaryOffsets() const {
  return handle_->summaryOffsets;
}

const bool* StreamDecoder::summaryCrcOk() const {
  return handle_->hasSummaryCrcOk ? &handle_->summaryCrcOk : nullptr;
}

bool StreamDecoder::truncated() const { return handle_->truncated; }

IndexedReader::IndexedReader(std::unique_ptr<detail::Handle> handle)
    : handle_(std::move(handle)) {}

IndexedReader::~IndexedReader() = default;

Result<std::unique_ptr<IndexedReader>> IndexedReader::open(Readable& source) {
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  handle->source = &source;
  Result<void> opened = detail::openIndexed(*handle);
  if (!opened) return opened.error();
  return std::unique_ptr<IndexedReader>(new IndexedReader(std::move(handle)));
}

const Header& IndexedReader::header() const { return handle_->header; }

const std::vector<ChunkIndexEntry>& IndexedReader::index() const { return handle_->index; }

const Statistics* IndexedReader::statistics() const {
  return handle_->hasStatistics ? &handle_->statistics : nullptr;
}

const std::vector<SummaryOffset>& IndexedReader::summaryOffsets() const {
  return handle_->summaryOffsets;
}

const bool* IndexedReader::summaryCrcOk() const {
  return handle_->hasSummaryCrcOk ? &handle_->summaryCrcOk : nullptr;
}

std::vector<const ChunkIndexEntry*> IndexedReader::chunksFor(double t) const {
  // Spec §8, and the whole of it: every entry whose half-open interval contains t. The
  // index is already resident, so this asks the transport for nothing.
  std::vector<const ChunkIndexEntry*> hits;
  for (const ChunkIndexEntry& entry : handle_->index) {
    if (entry.t0 <= t && t < entry.t1) hits.push_back(&entry);
  }
  return hits;
}

Result<GaussianData> IndexedReader::readChunk(const ChunkIndexEntry& entry, int maxShBand) {
  GaussianData out;
  Result<void> read = detail::readChunk(*handle_, entry, maxShBand, out);
  if (!read) return read.error();
  return out;
}

Result<bool> IndexedReader::readAudio(AudioTrack* out) { return detail::readAudio(*handle_, out); }

Result<bool> IndexedReader::readCamera(Camera* out) { return detail::readCamera(*handle_, out); }

Result<std::vector<MetadataRecord>> IndexedReader::readMetadata() {
  return detail::readMetadata(*handle_);
}

Result<std::vector<Attachment>> IndexedReader::readAttachments() {
  return detail::readAttachments(*handle_);
}

}  // namespace fourdgs
