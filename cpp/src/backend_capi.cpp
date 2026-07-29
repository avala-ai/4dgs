// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The seam, bound to the Rust core's C ABI.
///
/// The only file in this package that includes `fourdgs.h`. Everything here is translation
/// and nothing here is decoding: statuses become `ErrorCode`s carrying the core's own
/// message, borrowed pointers become `Span`s with the lifetime the header states, and a C++
/// `Readable` becomes the callback struct the decoder reads through.

#include <cstring>
#include <new>

#include "backend.hpp"
#include "fourdgs.h"

namespace fourdgs {
namespace detail {
namespace {

fourdgs_scene* asScene(void* handle) { return static_cast<fourdgs_scene*>(handle); }

fourdgs_scene* asScene(const Handle& handle) { return static_cast<fourdgs_scene*>(handle.scene); }

fourdgs_state* asState(const StateHandle& state) {
  return static_cast<fourdgs_state*>(state.state);
}

/// The core's statuses, mapped to this package's. The two that must not merge are
/// `UNSUPPORTED_CODEC` and `MALFORMED`: a legal file this build cannot read needs a
/// different build, a bad file needs a different file.
ErrorCode translate(int status) {
  switch (status) {
    case FOURDGS_STATUS_OK:
      return ErrorCode::kOk;
    case FOURDGS_STATUS_INVALID_ARGUMENT:
      return ErrorCode::kInvalidArgument;
    case FOURDGS_STATUS_UNSUPPORTED_VERSION:
      return ErrorCode::kUnsupportedVersion;
    case FOURDGS_STATUS_TRUNCATED:
      return ErrorCode::kTruncated;
    case FOURDGS_STATUS_MALFORMED:
      return ErrorCode::kMalformed;
    case FOURDGS_STATUS_UNSUPPORTED_CODEC:
      return ErrorCode::kUnsupported;
    case FOURDGS_STATUS_IO:
      return ErrorCode::kIo;
    case FOURDGS_STATUS_OUT_OF_RANGE:
      return ErrorCode::kInvalidArgument;
    case FOURDGS_STATUS_UNSUPPORTED_MODE:
      return ErrorCode::kUnsupportedMode;
    case FOURDGS_STATUS_INTERNAL:
    default:
      return ErrorCode::kInternal;
  }
}

/// A failed call, with the core's diagnosis rather than a category name.
///
/// `fourdgs_last_error()` is thread-local and borrowed until the next failure on this
/// thread, so it is copied here and not held.
Result<void> failure(int status) {
  const char* message = fourdgs_last_error();
  std::string detail = (message != nullptr && message[0] != '\0')
                           ? std::string(message)
                           : std::string(fourdgs_status_message(status));
  return Error(translate(status), std::move(detail));
}

Result<void> check(int status) {
  if (status == FOURDGS_STATUS_OK) return Result<void>();
  return failure(status);
}

/// What the core calls back into. Owned by the scene, released once when the scene is freed
/// — including when the open that created it failed, which is why this is heap-allocated and
/// not a member of `Handle`.
struct ReadableBridge {
  Readable* source = nullptr;
};

int bridgeSize(void* ctx, std::uint64_t* outSize) {
  ReadableBridge* bridge = static_cast<ReadableBridge*>(ctx);
  if (bridge == nullptr || bridge->source == nullptr) return FOURDGS_STATUS_INVALID_ARGUMENT;
  Result<std::uint64_t> size = bridge->source->size();
  if (!size) return FOURDGS_STATUS_IO;
  *outSize = *size;
  return FOURDGS_STATUS_OK;
}

/// Fill `out` exactly, or fail.
///
/// The header is explicit that reporting success after a short read breaks every caller, so
/// a transport that ran out of bytes reports TRUNCATED — which is what a file cut short
/// actually is, and what lets the decoder keep whatever preceded the cut.
int bridgeRead(void* ctx, std::uint64_t offset, std::uint64_t length, std::uint8_t* out) {
  ReadableBridge* bridge = static_cast<ReadableBridge*>(ctx);
  if (bridge == nullptr || bridge->source == nullptr) return FOURDGS_STATUS_INVALID_ARGUMENT;
  std::uint64_t done = 0;
  while (done < length) {
    const std::uint64_t remaining = length - done;
    const std::size_t want = static_cast<std::size_t>(remaining);
    Result<std::size_t> got =
        bridge->source->read(offset + done, Span<std::uint8_t>(out + done, want));
    if (!got)
      return got.error().code == ErrorCode::kInvalidArgument ? FOURDGS_STATUS_TRUNCATED
                                                             : FOURDGS_STATUS_IO;
    if (*got == 0) return FOURDGS_STATUS_TRUNCATED;
    done += *got;
  }
  return FOURDGS_STATUS_OK;
}

void bridgeRelease(void* ctx) { delete static_cast<ReadableBridge*>(ctx); }

/// A borrowed (pointer, length) string from the ABI, copied.
///
/// Not NUL-terminated and valid only until the scene is freed, so it is copied here rather
/// than held — the same rule as the error message.
std::string borrowedString(int status, const char* data, std::size_t length) {
  if (status != FOURDGS_STATUS_OK || data == nullptr || length == 0) return std::string();
  return std::string(data, length);
}

template <typename T>
Span<const T> spanOf(const T* data, std::size_t count) {
  if (data == nullptr || count == 0) return Span<const T>();
  return Span<const T>(data, count);
}

}  // namespace

Handle::~Handle() { closeScene(*this); }

StateHandle::~StateHandle() { closeState(*this); }

Result<void> openPath(Handle& handle, const std::string& path, int mode) {
  fourdgs_scene* scene = nullptr;
  const int status = fourdgs_open_path_ex(path.c_str(), mode, &scene);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  handle.scene = scene;
  return Result<void>();
}

Result<void> openMemory(Handle& handle, Span<const std::uint8_t> bytes, int mode) {
  fourdgs_scene* scene = nullptr;
  const int status = fourdgs_open_memory_ex(bytes.data(), bytes.size(), mode, &scene);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  handle.scene = scene;
  return Result<void>();
}

Result<void> openReadable(Handle& handle, Readable& source, int mode) {
  ReadableBridge* bridge = new (std::nothrow) ReadableBridge();
  if (bridge == nullptr) return Error(ErrorCode::kInternal, "out of memory opening a scene");
  bridge->source = &source;

  fourdgs_reader reader;
  reader.ctx = bridge;
  reader.size = &bridgeSize;
  reader.read = &bridgeRead;
  // The scene releases the bridge exactly once, including when this open fails, so there is
  // no path where the allocation above leaks.
  reader.release = &bridgeRelease;

  fourdgs_scene* scene = nullptr;
  const int status = fourdgs_open_reader_ex(reader, mode, &scene);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  handle.scene = scene;
  return Result<void>();
}

double durationSec(const Handle& handle) { return fourdgs_scene_duration_sec(asScene(handle)); }

double cutoff(const Handle& handle) { return fourdgs_scene_cutoff(asScene(handle)); }

std::uint64_t gaussianCount(const Handle& handle) {
  return fourdgs_scene_gaussian_count(asScene(handle));
}

int shDegree(const Handle& handle) {
  return static_cast<int>(fourdgs_scene_sh_degree(asScene(handle)));
}

bool isIndexed(const Handle& handle) { return fourdgs_scene_is_indexed(asScene(handle)) != 0; }

std::uint32_t chunkCount(const Handle& handle) {
  return fourdgs_scene_chunk_count(asScene(handle));
}

Result<void> chunkInterval(const Handle& handle, std::uint32_t index, double* t0, double* t1) {
  return check(fourdgs_scene_chunk_interval(asScene(handle), index, t0, t1));
}

std::uint64_t bytesForTime(const Handle& handle, double t, int maxShBand) {
  return fourdgs_scene_bytes_for_time(asScene(handle), t, static_cast<std::uint8_t>(maxShBand));
}

bool hasAudio(const Handle& handle) { return fourdgs_scene_has_audio(asScene(handle)) != 0; }

std::string audioCodec(Handle& handle) {
  const char* codec = fourdgs_scene_audio_codec(asScene(handle.scene));
  return codec == nullptr ? std::string() : std::string(codec);
}

std::uint64_t audioSize(const Handle& handle) { return fourdgs_scene_audio_size(asScene(handle)); }

Result<void> readAudio(Handle& handle, std::uint64_t offset, Span<std::uint8_t> into) {
  if (into.empty()) return Result<void>();
  return check(fourdgs_scene_audio_read(asScene(handle.scene), offset, into.size(), into.data()));
}

Result<void> loadAll(Handle& handle, int maxShBand) {
  return check(fourdgs_scene_load_all(asScene(handle.scene), static_cast<std::uint8_t>(maxShBand)));
}

Result<void> loadAt(Handle& handle, double t, int maxShBand) {
  return check(
      fourdgs_scene_load_at(asScene(handle.scene), t, static_cast<std::uint8_t>(maxShBand)));
}

GaussianView loadedGaussians(const Handle& handle) {
  const fourdgs_scene* scene = asScene(handle);
  const std::size_t n = fourdgs_scene_loaded_count(scene);

  GaussianView view;
  view.count = n;
  view.positions = spanOf(fourdgs_scene_positions(scene), n * 3);
  view.scales = spanOf(fourdgs_scene_scales(scene), n * 3);
  view.rotations = spanOf(fourdgs_scene_rotations(scene), n * 4);
  view.colors = spanOf(fourdgs_scene_colors(scene), n * 4);
  view.motions = spanOf(fourdgs_scene_motions(scene), n * 3);
  view.muT = spanOf(fourdgs_scene_mu_t(scene), n);
  view.sigmaT = spanOf(fourdgs_scene_sigma_t(scene), n);
  view.winLo = spanOf(fourdgs_scene_win_lo(scene), n);
  view.winHi = spanOf(fourdgs_scene_win_hi(scene), n);
  // Coefficients per colour component, so a row is three times this wide. Reported for the
  // working set rather than for the file, because capping the band cap lowers it.
  view.shCoefficients = fourdgs_scene_sh_coefficients(scene);
  view.shDegree = static_cast<int>(fourdgs_scene_sh_degree(scene));
  view.sh = spanOf(fourdgs_scene_sh(scene), n * view.shCoefficients * 3);
  if (view.sh.empty()) {
    // No coefficients in the working set is degree 0 for anything reading this view, whatever
    // the header declared.
    view.shDegree = 0;
    view.shCoefficients = 0;
  }
  return view;
}

Result<void> stateAt(Handle& handle, double t, int maxShBand, StateHandle& out) {
  fourdgs_state* state = nullptr;
  const int status = fourdgs_scene_state_at(asScene(handle.scene), t,
                                            static_cast<std::uint8_t>(maxShBand), &state);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  closeState(out);
  out.state = state;
  return Result<void>();
}

std::size_t stateCount(const StateHandle& state) { return fourdgs_state_count(asState(state)); }

Span<const std::uint32_t> stateIndices(const StateHandle& state) {
  return spanOf(fourdgs_state_indices(asState(state)), stateCount(state));
}

Span<const float> stateCenters(const StateHandle& state) {
  return spanOf(fourdgs_state_centers(asState(state)), stateCount(state) * 3);
}

Span<const float> stateOpacity(const StateHandle& state) {
  return spanOf(fourdgs_state_opacity(asState(state)), stateCount(state));
}

bool truncated(const Handle& handle) { return fourdgs_scene_truncated(asScene(handle)) != 0; }

std::string temporalModel(const Handle& handle) {
  const char* data = nullptr;
  std::size_t length = 0;
  // Sequenced deliberately: passing the call and its out parameters as three arguments of
  // one expression reads `data` and `length` before the call has filled them, because the
  // order of argument evaluation is unspecified. It compiles, and it returns empty.
  const int status = fourdgs_scene_temporal_model(asScene(handle), &data, &length);
  return borrowedString(status, data, length);
}

std::string profile(const Handle& handle) {
  const char* data = nullptr;
  std::size_t length = 0;
  // Sequenced deliberately: passing the call and its out parameters as three arguments of
  // one expression reads `data` and `length` before the call has filled them, because the
  // order of argument evaluation is unspecified. It compiles, and it returns empty.
  const int status = fourdgs_scene_profile(asScene(handle), &data, &length);
  return borrowedString(status, data, length);
}

std::string library(const Handle& handle) {
  const char* data = nullptr;
  std::size_t length = 0;
  // Sequenced deliberately: passing the call and its out parameters as three arguments of
  // one expression reads `data` and `length` before the call has filled them, because the
  // order of argument evaluation is unspecified. It compiles, and it returns empty.
  const int status = fourdgs_scene_library(asScene(handle), &data, &length);
  return borrowedString(status, data, length);
}

std::map<std::string, std::string> attributes(const Handle& handle) {
  std::map<std::string, std::string> out;
  const std::uint32_t count = fourdgs_scene_attribute_count(asScene(handle));
  for (std::uint32_t i = 0; i < count; ++i) {
    const char* key = nullptr;
    const char* value = nullptr;
    std::size_t keyLength = 0;
    std::size_t valueLength = 0;
    const int status =
        fourdgs_scene_attribute_at(asScene(handle), i, &key, &keyLength, &value, &valueLength);
    if (status != FOURDGS_STATUS_OK) continue;
    out.emplace(borrowedString(status, key, keyLength), borrowedString(status, value, valueLength));
  }
  return out;
}

std::uint64_t bytesForChunk(const Handle& handle, std::uint32_t index, int maxShBand) {
  return fourdgs_scene_bytes_for_chunk(asScene(handle), index,
                                       static_cast<std::uint8_t>(maxShBand));
}

Result<void> loadChunk(Handle& handle, std::uint32_t index, int maxShBand) {
  return check(
      fourdgs_scene_load_chunk(asScene(handle.scene), index, static_cast<std::uint8_t>(maxShBand)));
}

Result<void> loadRecords(Handle& handle) {
  return check(fourdgs_scene_load_records(asScene(handle.scene)));
}

Result<std::vector<MetadataRecord>> metadata(Handle& handle) {
  Result<void> ready = loadRecords(handle);
  if (!ready) return ready.error();

  std::vector<MetadataRecord> out;
  fourdgs_scene* scene = asScene(handle.scene);
  const std::uint32_t count = fourdgs_scene_metadata_count(scene);
  for (std::uint32_t i = 0; i < count; ++i) {
    MetadataRecord record;
    const char* name = nullptr;
    std::size_t nameLength = 0;
    const int named = fourdgs_scene_metadata_name(scene, i, &name, &nameLength);
    if (named != FOURDGS_STATUS_OK) return failure(named).error();
    record.name = borrowedString(named, name, nameLength);

    const std::uint32_t entries = fourdgs_scene_metadata_entry_count(scene, i);
    for (std::uint32_t j = 0; j < entries; ++j) {
      const char* key = nullptr;
      const char* value = nullptr;
      std::size_t keyLength = 0;
      std::size_t valueLength = 0;
      const int status =
          fourdgs_scene_metadata_entry_at(scene, i, j, &key, &keyLength, &value, &valueLength);
      if (status != FOURDGS_STATUS_OK) return failure(status).error();
      record.entries.emplace(borrowedString(status, key, keyLength),
                             borrowedString(status, value, valueLength));
    }
    out.push_back(std::move(record));
  }
  return out;
}

Result<std::vector<Attachment>> attachments(Handle& handle) {
  Result<void> ready = loadRecords(handle);
  if (!ready) return ready.error();

  std::vector<Attachment> out;
  fourdgs_scene* scene = asScene(handle.scene);
  const std::uint32_t count = fourdgs_scene_attachment_count(scene);
  for (std::uint32_t i = 0; i < count; ++i) {
    Attachment attachment;
    const char* name = nullptr;
    std::size_t nameLength = 0;
    const int named = fourdgs_scene_attachment_name(scene, i, &name, &nameLength);
    if (named != FOURDGS_STATUS_OK) return failure(named).error();
    attachment.name = borrowedString(named, name, nameLength);

    const char* mediaType = nullptr;
    std::size_t mediaTypeLength = 0;
    const int typed = fourdgs_scene_attachment_media_type(scene, i, &mediaType, &mediaTypeLength);
    if (typed != FOURDGS_STATUS_OK) return failure(typed).error();
    attachment.mediaType = borrowedString(typed, mediaType, mediaTypeLength);

    // The bytes, not just their length: a summary that reported the length and discarded
    // the payload would be indistinguishable from one that never read it.
    const std::uint64_t size = fourdgs_scene_attachment_size(scene, i);
    attachment.data.resize(static_cast<std::size_t>(size));
    if (size != 0) {
      const int read = fourdgs_scene_attachment_read(scene, i, 0, size, attachment.data.data());
      if (read != FOURDGS_STATUS_OK) return failure(read).error();
    }
    out.push_back(std::move(attachment));
  }
  return out;
}

bool hasCamera(const Handle& handle) { return fourdgs_scene_has_camera(asScene(handle)) != 0; }

Result<Camera> camera(Handle& handle) {
  fourdgs_scene* scene = asScene(handle.scene);
  fourdgs_camera raw;
  const int status = fourdgs_scene_camera(scene, &raw);
  if (status != FOURDGS_STATUS_OK) return failure(status).error();

  Camera out;
  out.fovYDeg = raw.fov_y_deg;
  for (std::size_t k = 0; k < 3; ++k) {
    out.position[k] = raw.position[k];
    out.target[k] = raw.target[k];
  }
  out.loop = raw.loop_enabled != 0;
  out.interpolation =
      borrowedString(FOURDGS_STATUS_OK, raw.interpolation, raw.interpolation_length);

  for (std::uint32_t i = 0; i < raw.keyframe_count; ++i) {
    Camera::Keyframe frame;
    const int read =
        fourdgs_scene_camera_keyframe(scene, i, &frame.time, frame.position, frame.target);
    if (read != FOURDGS_STATUS_OK) return failure(read).error();
    out.keyframes.push_back(frame);
  }
  return out;
}

bool hasStatistics(const Handle& handle) {
  return fourdgs_scene_has_statistics(asScene(handle)) != 0;
}

Result<Statistics> statistics(const Handle& handle) {
  Statistics out;
  const int status = fourdgs_scene_statistics(asScene(handle), &out.gaussianCount, &out.chunkCount,
                                              &out.durationSec, out.aabb);
  if (status != FOURDGS_STATUS_OK) return failure(status).error();
  return out;
}

std::vector<SummaryOffset> summaryOffsets(const Handle& handle) {
  std::vector<SummaryOffset> out;
  const std::uint32_t count = fourdgs_scene_summary_offset_count(asScene(handle));
  for (std::uint32_t i = 0; i < count; ++i) {
    SummaryOffset offset;
    if (fourdgs_scene_summary_offset_at(asScene(handle), i, &offset.groupOpcode, &offset.groupStart,
                                        &offset.groupLength) != FOURDGS_STATUS_OK) {
      continue;
    }
    out.push_back(offset);
  }
  return out;
}

int summaryCrcState(const Handle& handle) {
  return fourdgs_scene_summary_crc_state(asScene(handle));
}

/// A writer owned for exactly the length of an encode. The core copies every column in, so
/// nothing the caller lent has to outlive this scope.
struct WriterGuard {
  fourdgs_writer* writer = fourdgs_writer_new();
  WriterGuard() = default;
  ~WriterGuard() { fourdgs_writer_free(writer); }
  WriterGuard(const WriterGuard&) = delete;
  WriterGuard& operator=(const WriterGuard&) = delete;
};

Result<std::vector<std::uint8_t>> encodeScene(const GaussianView& gaussians, double durationSec,
                                              const WriteOptions& options) {
  WriterGuard guard;
  if (guard.writer == nullptr) {
    return Error(ErrorCode::kInternal, "the core could not allocate a writer");
  }
  fourdgs_writer* writer = guard.writer;

  // Options first, then the columns: setting the columns clears any harmonics, so the sh
  // call has to come after them.
  Result<void> staged = check(fourdgs_writer_set_duration(writer, durationSec));
  if (!staged) return staged.error();
  staged = check(fourdgs_writer_set_cutoff(writer, options.cutoff));
  if (!staged) return staged.error();
  staged = check(fourdgs_writer_set_chunking(writer, options.maxDepth, options.minChunkGaussians));
  if (!staged) return staged.error();
  staged = check(fourdgs_writer_set_summary(writer, options.writeIndex ? 1 : 0,
                                            options.writeStatistics ? 1 : 0,
                                            options.writeSummaryOffsets ? 1 : 0,
                                            options.writeCrc ? 1 : 0));
  if (!staged) return staged.error();
  staged = check(fourdgs_writer_set_sh_bands(writer, options.shBands));
  if (!staged) return staged.error();
  staged = check(fourdgs_writer_set_sh_bit_depths(
      writer, options.shBitDepths.empty() ? nullptr : options.shBitDepths.data(),
      options.shBitDepths.size()));
  if (!staged) return staged.error();
  if (!options.profile.empty()) {
    staged = check(fourdgs_writer_set_profile(writer, options.profile.data(), options.profile.size()));
    if (!staged) return staged.error();
  }
  if (!options.library.empty()) {
    staged = check(fourdgs_writer_set_library(writer, options.library.data(), options.library.size()));
    if (!staged) return staged.error();
  }
  for (const auto& [key, value] : options.attributes) {
    staged = check(fourdgs_writer_add_attribute(writer, key.data(), key.size(), value.data(),
                                                value.size()));
    if (!staged) return staged.error();
  }

  const auto count = static_cast<std::uint32_t>(gaussians.count);
  staged = check(fourdgs_writer_set_gaussians(
      writer, count, gaussians.positions.data(), gaussians.scales.data(),
      gaussians.rotations.data(), gaussians.colors.data(), gaussians.motions.data(),
      gaussians.muT.data(), gaussians.sigmaT.data(), gaussians.winLo.data(),
      gaussians.winHi.data()));
  if (!staged) return staged.error();
  if (gaussians.shDegree > 0 && gaussians.shCoefficients > 0 && !gaussians.sh.empty()) {
    staged = check(fourdgs_writer_set_sh(writer, static_cast<std::uint8_t>(gaussians.shDegree),
                                         static_cast<std::uint32_t>(gaussians.shCoefficients),
                                         gaussians.sh.data(), gaussians.sh.size()));
    if (!staged) return staged.error();
  }

  fourdgs_buffer* buffer = nullptr;
  const int status = fourdgs_writer_encode(writer, &buffer);
  if (status != FOURDGS_STATUS_OK) return failure(status).error();

  // Copied out before the buffer is freed: the bytes are the caller's to keep, and the ABI's
  // pointer lives only until fourdgs_buffer_free.
  const std::uint8_t* data = fourdgs_buffer_data(buffer);
  const std::size_t length = fourdgs_buffer_len(buffer);
  std::vector<std::uint8_t> out(length);
  if (length != 0 && data != nullptr) std::memcpy(out.data(), data, length);
  fourdgs_buffer_free(buffer);
  return out;
}

void closeScene(Handle& handle) noexcept {
  // Null is ignored by the ABI, and freeing invalidates every pointer borrowed from it —
  // which is why nothing in this package holds one across a close.
  fourdgs_scene_free(static_cast<fourdgs_scene*>(handle.scene));
  handle.scene = nullptr;
}

void closeState(StateHandle& state) noexcept {
  fourdgs_state_free(static_cast<fourdgs_state*>(state.state));
  state.state = nullptr;
}

const char* coreVersionString() noexcept {
  // The ABI reports the format version it implements rather than a package version, so that
  // is what this returns: the number a consumer can actually act on.
  static char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "4dgs format v%u", fourdgs_format_version());
  return buffer;
}

bool available() noexcept { return true; }

}  // namespace detail
}  // namespace fourdgs
