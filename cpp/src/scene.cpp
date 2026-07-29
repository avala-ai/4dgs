// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/scene.hpp"

#include <limits>
#include <utility>

#include "backend.hpp"

namespace fourdgs {

State::State(std::unique_ptr<detail::StateHandle> handle) : handle_(std::move(handle)) {}

State::~State() = default;

State::State(State&&) noexcept = default;

State& State::operator=(State&&) noexcept = default;

std::size_t State::count() const { return detail::stateCount(*handle_); }

Span<const std::uint32_t> State::indices() const { return detail::stateIndices(*handle_); }

Span<const float> State::centers() const { return detail::stateCenters(*handle_); }

Span<const float> State::opacity() const { return detail::stateOpacity(*handle_); }

Scene::Scene(std::unique_ptr<detail::Handle> handle) : handle_(std::move(handle)) {}

Scene::~Scene() = default;

Result<std::unique_ptr<Scene>> Scene::openPath(const std::string& path, ReadMode mode) {
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened = detail::openPath(*handle, path, static_cast<int>(mode));
  if (!opened) return opened.error();
  return std::unique_ptr<Scene>(new Scene(std::move(handle)));
}

Result<std::unique_ptr<Scene>> Scene::openMemory(Span<const std::uint8_t> bytes, ReadMode mode) {
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened = detail::openMemory(*handle, bytes, static_cast<int>(mode));
  if (!opened) return opened.error();
  return std::unique_ptr<Scene>(new Scene(std::move(handle)));
}

Result<std::unique_ptr<Scene>> Scene::open(Readable& source, ReadMode mode) {
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened = detail::openReadable(*handle, source, static_cast<int>(mode));
  if (!opened) return opened.error();
  return std::unique_ptr<Scene>(new Scene(std::move(handle)));
}

double Scene::durationSec() const { return detail::durationSec(*handle_); }

double Scene::cutoff() const { return detail::cutoff(*handle_); }

std::uint64_t Scene::gaussianCount() const { return detail::gaussianCount(*handle_); }

int Scene::shDegree() const { return detail::shDegree(*handle_); }

bool Scene::isIndexed() const { return detail::isIndexed(*handle_); }

bool Scene::truncated() const { return detail::truncated(*handle_); }

std::string Scene::temporalModel() const { return detail::temporalModel(*handle_); }

std::string Scene::profile() const { return detail::profile(*handle_); }

std::string Scene::library() const { return detail::library(*handle_); }

std::map<std::string, std::string> Scene::attributes() const {
  return detail::attributes(*handle_);
}

std::uint32_t Scene::chunkCount() const { return detail::chunkCount(*handle_); }

Result<std::pair<double, double>> Scene::chunkInterval(std::uint32_t index) const {
  double t0 = 0.0;
  double t1 = 0.0;
  Result<void> read = detail::chunkInterval(*handle_, index, &t0, &t1);
  if (!read) return read.error();
  return std::make_pair(t0, t1);
}

std::uint64_t Scene::bytesForTime(double t, int maxShBand) const {
  return detail::bytesForTime(*handle_, t, maxShBand);
}

std::uint64_t Scene::bytesForChunk(std::uint32_t index, int maxShBand) const {
  return detail::bytesForChunk(*handle_, index, maxShBand);
}

Result<void> Scene::loadChunk(std::uint32_t index, int maxShBand) {
  return detail::loadChunk(*handle_, index, maxShBand);
}

Result<void> Scene::loadRecords() { return detail::loadRecords(*handle_); }

Result<std::vector<MetadataRecord>> Scene::metadata() { return detail::metadata(*handle_); }

Result<std::vector<Attachment>> Scene::attachments() { return detail::attachments(*handle_); }

bool Scene::hasCamera() const { return detail::hasCamera(*handle_); }

Result<Camera> Scene::camera() { return detail::camera(*handle_); }

bool Scene::hasStatistics() const { return detail::hasStatistics(*handle_); }

Result<Statistics> Scene::statistics() const { return detail::statistics(*handle_); }

std::vector<SummaryOffset> Scene::summaryOffsets() const {
  return detail::summaryOffsets(*handle_);
}

Scene::CrcState Scene::summaryCrcState() const {
  switch (detail::summaryCrcState(*handle_)) {
    case 0:
      return CrcState::kFailed;
    case 1:
      return CrcState::kVerified;
    default:
      return CrcState::kNotChecked;
  }
}

bool Scene::hasAudio() const { return detail::hasAudio(*handle_); }

std::uint32_t Scene::audioSourceCount() const { return detail::audioSourceCount(*handle_); }

Result<AudioSource> Scene::audioSource(std::uint32_t index) {
  return detail::audioSource(*handle_, index);
}

Result<AudioSourceState> Scene::audioSourceStateAt(std::uint32_t index, double t) {
  return detail::audioSourceStateAt(*handle_, index, t);
}

Result<void> Scene::readAudioSource(std::uint32_t index, std::uint64_t offset,
                                    Span<std::uint8_t> into) {
  return detail::readAudioSource(*handle_, index, offset, into);
}

Result<AudioSource> Scene::readAudioSource(std::uint32_t index) {
  Result<AudioSource> descriptor = audioSource(index);
  if (!descriptor) return descriptor.error();
  if (descriptor->dataSize > std::numeric_limits<std::size_t>::max()) {
    return Error(ErrorCode::kMalformed,
                 "Audio Source id " + std::to_string(descriptor->sourceId) + " declares " +
                     std::to_string(descriptor->dataSize) +
                     " payload bytes; this platform can address at most " +
                     std::to_string(std::numeric_limits<std::size_t>::max()));
  }
  descriptor->data.resize(static_cast<std::size_t>(descriptor->dataSize));
  if (descriptor->data.empty()) return descriptor;
  Result<void> read = readAudioSource(
      index, 0, Span<std::uint8_t>(descriptor->data.data(), descriptor->data.size()));
  if (!read) return read.error();
  return descriptor;
}

Result<std::vector<AudioSource>> Scene::readAudioSources() {
  std::vector<AudioSource> sources;
  sources.reserve(audioSourceCount());
  for (std::uint32_t index = 0; index < audioSourceCount(); ++index) {
    Result<AudioSource> source = readAudioSource(index);
    if (!source) return source.error();
    sources.push_back(std::move(*source));
  }
  return sources;
}

std::string Scene::audioCodec() const { return detail::audioCodec(*handle_); }

std::uint64_t Scene::audioSize() const { return detail::audioSize(*handle_); }

Result<void> Scene::readAudio(std::uint64_t offset, Span<std::uint8_t> into) {
  return detail::readAudio(*handle_, offset, into);
}

Result<AudioTrack> Scene::readAudioTrack() {
  AudioTrack track;
  if (!hasAudio()) return track;
  track.codec = audioCodec();
  // Sized from a value the reader has already validated, and known without fetching the
  // track: the allocation is never larger than the file says the track is.
  const std::uint64_t size = audioSize();
  if (size > std::numeric_limits<std::size_t>::max()) {
    return Error(ErrorCode::kMalformed,
                 "legacy Audio declares " + std::to_string(size) +
                     " payload bytes; this platform can address at most " +
                     std::to_string(std::numeric_limits<std::size_t>::max()));
  }
  track.data.resize(static_cast<std::size_t>(size));
  if (size == 0) return track;
  Result<void> read = readAudio(0, Span<std::uint8_t>(track.data.data(), track.data.size()));
  if (!read) return read.error();
  return track;
}

Result<void> Scene::loadAll(int maxShBand) { return detail::loadAll(*handle_, maxShBand); }

Result<void> Scene::loadAt(double t, int maxShBand) {
  return detail::loadAt(*handle_, t, maxShBand);
}

GaussianView Scene::gaussians() const { return detail::loadedGaussians(*handle_); }

Result<State> Scene::stateAt(double t, int maxShBand) {
  auto handle = std::unique_ptr<detail::StateHandle>(new detail::StateHandle());
  Result<void> reconstructed = detail::stateAt(*handle_, t, maxShBand, *handle);
  if (!reconstructed) return reconstructed.error();
  return State(std::move(handle));
}

}  // namespace fourdgs
