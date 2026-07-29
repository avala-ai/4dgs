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

template <typename T>
Span<const T> spanOf(const T* data, std::size_t count) {
  if (data == nullptr || count == 0) return Span<const T>();
  return Span<const T>(data, count);
}

}  // namespace

Handle::~Handle() { closeScene(*this); }

StateHandle::~StateHandle() { closeState(*this); }

Result<void> openPath(Handle& handle, const std::string& path) {
  fourdgs_scene* scene = nullptr;
  const int status = fourdgs_open_path(path.c_str(), &scene);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  handle.scene = scene;
  return Result<void>();
}

Result<void> openMemory(Handle& handle, Span<const std::uint8_t> bytes) {
  fourdgs_scene* scene = nullptr;
  const int status = fourdgs_open_memory(bytes.data(), bytes.size(), &scene);
  if (status != FOURDGS_STATUS_OK) return failure(status);
  handle.scene = scene;
  return Result<void>();
}

Result<void> openReadable(Handle& handle, Readable& source) {
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
  const int status = fourdgs_open_reader(reader, &scene);
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
