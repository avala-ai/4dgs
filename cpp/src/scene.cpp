// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/scene.hpp"

#include <limits>
#include <utility>

#include "backend.hpp"

namespace fourdgs {

namespace {

constexpr std::uint64_t kMagicSize = 8;
constexpr std::uint64_t kRecordHeaderSize = 9;
constexpr const char* kLateFrontMatterRecord = "late-front-matter-record";

std::uint64_t readU64(const std::uint8_t* at) {
  std::uint64_t value = 0;
  for (int i = 7; i >= 0; --i) value = (value << 8) | at[i];
  return value;
}

bool isStateRecord(std::uint8_t opcode) { return opcode == 0x05 || opcode == 0x10; }

bool isDefinedFrontMatter(std::uint8_t opcode) {
  switch (opcode) {
    case 0x01:  // Header
    case 0x03:  // Quantization
    case 0x04:  // Window Table
    case 0x09:  // legacy Audio
    case 0x0A:  // Camera
    case 0x0B:  // Metadata
    case 0x0D:  // Attachment
    case 0x11:  // Audio Source
    case 0x12:  // Audio Data
    case 0x20:  // Coordinate Frame
    case 0x21:  // Sensor Calibration
    case 0x22:  // Rig Trajectory
    case 0x23:  // Geodetic Anchor
    case 0x24:  // Object Table
    case 0x25:  // Object Track
      return true;
    default:
      return false;
  }
}

template <typename ReadHeader>
std::optional<LateFrontMatterRecords> locateLateFrontMatter(std::uint64_t size,
                                                            ReadHeader readHeader) {
  std::optional<RecordSite> firstState;
  std::uint64_t at = kMagicSize;
  while (at <= size && size - at >= kRecordHeaderSize) {
    std::uint8_t framing[kRecordHeaderSize] = {0};
    if (!readHeader(at, framing)) return std::nullopt;
    const std::uint8_t opcode = framing[0];
    const std::uint64_t length = readU64(framing + 1);
    if (length > size - at - kRecordHeaderSize) return std::nullopt;

    if (firstState.has_value() && isDefinedFrontMatter(opcode)) {
      return LateFrontMatterRecords{RecordSite{opcode, at}, *firstState};
    }
    if (!firstState.has_value() && isStateRecord(opcode)) {
      firstState = RecordSite{opcode, at};
    }
    at += kRecordHeaderSize + length;
  }
  return std::nullopt;
}

std::optional<LateFrontMatterRecords> locateLateFrontMatter(Span<const std::uint8_t> bytes) {
  return locateLateFrontMatter(bytes.size(), [&](std::uint64_t at, std::uint8_t* framing) {
    const std::size_t offset = static_cast<std::size_t>(at);
    for (std::size_t i = 0; i < kRecordHeaderSize; ++i) framing[i] = bytes[offset + i];
    return true;
  });
}

std::optional<LateFrontMatterRecords> locateLateFrontMatter(Readable& source) {
  Result<std::uint64_t> size = source.size();
  if (!size) return std::nullopt;
  return locateLateFrontMatter(*size, [&](std::uint64_t at, std::uint8_t* framing) {
    Result<std::size_t> got =
        source.read(at, Span<std::uint8_t>(framing, static_cast<std::size_t>(kRecordHeaderSize)));
    return got.ok() && *got == kRecordHeaderSize;
  });
}

Error withLateFrontMatterRecords(Error error,
                                 const std::optional<LateFrontMatterRecords>& records) {
  if (error.refusal.has_value() && *error.refusal == kLateFrontMatterRecord &&
      !error.lateFrontMatterRecords.has_value()) {
    error.lateFrontMatterRecords = records;
  }
  return error;
}

Error withLateFrontMatterRecords(Error error, Readable& source) {
  if (!error.refusal.has_value() || *error.refusal != kLateFrontMatterRecord) return error;
  return withLateFrontMatterRecords(std::move(error), locateLateFrontMatter(source));
}

Error withLateFrontMatterRecords(Error error, Span<const std::uint8_t> bytes) {
  if (!error.refusal.has_value() || *error.refusal != kLateFrontMatterRecord) return error;
  return withLateFrontMatterRecords(std::move(error), locateLateFrontMatter(bytes));
}

Result<void> validateReadOptions(const ReadOptions& options) {
  if (options.maxDecodedStateBytes != 0) return Result<void>();
  return Error(ErrorCode::kInvalidArgument, "maxDecodedStateBytes must be greater than zero");
}

}  // namespace

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
  return openPath(path, ReadOptions(), mode);
}

Result<std::unique_ptr<Scene>> Scene::openPath(const std::string& path, const ReadOptions& options,
                                               ReadMode mode) {
  Result<void> valid = validateReadOptions(options);
  if (!valid) return valid.error();
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened =
      detail::openPath(*handle, path, static_cast<int>(mode), options.maxDecodedStateBytes);
  if (!opened) {
    Error error = opened.error();
    if (error.refusal.has_value() && *error.refusal == kLateFrontMatterRecord) {
      Result<FileReadable*> file = FileReadable::open(path);
      if (file) {
        std::unique_ptr<FileReadable> source(*file);
        error = withLateFrontMatterRecords(std::move(error), *source);
      }
    }
    return error;
  }
  return std::unique_ptr<Scene>(new Scene(std::move(handle)));
}

Result<std::unique_ptr<Scene>> Scene::openMemory(Span<const std::uint8_t> bytes, ReadMode mode) {
  return openMemory(bytes, ReadOptions(), mode);
}

Result<std::unique_ptr<Scene>> Scene::openMemory(Span<const std::uint8_t> bytes,
                                                 const ReadOptions& options, ReadMode mode) {
  Result<void> valid = validateReadOptions(options);
  if (!valid) return valid.error();
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened =
      detail::openMemory(*handle, bytes, static_cast<int>(mode), options.maxDecodedStateBytes);
  if (!opened) return withLateFrontMatterRecords(opened.error(), bytes);
  return std::unique_ptr<Scene>(new Scene(std::move(handle)));
}

Result<std::unique_ptr<Scene>> Scene::open(Readable& source, ReadMode mode) {
  return open(source, ReadOptions(), mode);
}

Result<std::unique_ptr<Scene>> Scene::open(Readable& source, const ReadOptions& options,
                                           ReadMode mode) {
  Result<void> valid = validateReadOptions(options);
  if (!valid) return valid.error();
  auto handle = std::unique_ptr<detail::Handle>(new detail::Handle());
  Result<void> opened =
      detail::openReadable(*handle, source, static_cast<int>(mode), options.maxDecodedStateBytes);
  if (!opened) return withLateFrontMatterRecords(opened.error(), source);
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

Result<void> Scene::loadAll(int maxShBand) { return loadAll(maxShBand, ReadOptions()); }

Result<void> Scene::loadAll(int maxShBand, const ReadOptions& options) {
  Result<void> valid = validateReadOptions(options);
  if (!valid) return valid;
  return detail::loadAll(*handle_, maxShBand, options.maxDecodedStateBytes);
}

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

Result<std::string> Scene::provenanceJson() { return detail::provenanceJson(*handle_); }

Result<std::string> Scene::objectsJson() { return detail::objectsJson(*handle_); }

Result<std::string> Scene::objectStatesJson() { return detail::objectStatesJson(*handle_); }

Result<std::string> peekTemporalModel(Span<const std::uint8_t> bytes) {
  return detail::peekTemporalModel(bytes);
}

Result<std::string> keyframeDeltaStatesJson(Span<const std::uint8_t> bytes, bool indexed) {
  return keyframeDeltaStatesJson(bytes, indexed, ReadOptions());
}

Result<std::string> keyframeDeltaStatesJson(Span<const std::uint8_t> bytes, bool indexed,
                                            const ReadOptions& options) {
  Result<void> valid = validateReadOptions(options);
  if (!valid) return valid.error();
  Result<std::string> decoded =
      detail::keyframeDeltaStatesJson(bytes, indexed, options.maxDecodedStateBytes);
  if (!decoded) return withLateFrontMatterRecords(decoded.error(), bytes);
  return decoded;
}

}  // namespace fourdgs
