// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_SRC_BACKEND_HPP
#define FOURDGS_SRC_BACKEND_HPP

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "fourdgs/model.hpp"
#include "fourdgs/readable.hpp"
#include "fourdgs/result.hpp"
#include "fourdgs/writer.hpp"

/// The seam.
///
/// Everything above this line is ordinary C++ — RAII, views, `Result`. Everything below it
/// is the Rust core's C ABI. Exactly one translation unit implements these functions against
/// that ABI (`backend_capi.cpp`) and exactly one implements them as honest refusals for a
/// build made without a core (`backend_unavailable.cpp`); CMake picks between them. Nothing
/// else in the package includes `fourdgs.h`, so the ABI's shape stays a detail of one file.
namespace fourdgs {
namespace detail {

/// An open scene: the core's opaque pointer, plus whatever the binding must keep alive for
/// as long as the core holds it.
class Handle {
 public:
  Handle() = default;
  ~Handle();
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;

  void* scene = nullptr;
};

/// Reconstructed state at an instant, owned by the caller and freed with it.
class StateHandle {
 public:
  StateHandle() = default;
  ~StateHandle();
  StateHandle(const StateHandle&) = delete;
  StateHandle& operator=(const StateHandle&) = delete;

  void* state = nullptr;
};

/// Open, three ways. The `Readable` overload borrows the source: the caller keeps ownership
/// and must outlive the handle.
Result<void> openPath(Handle& handle, const std::string& path, int mode);
Result<void> openMemory(Handle& handle, Span<const std::uint8_t> bytes, int mode);
Result<void> openReadable(Handle& handle, Readable& source, int mode);

/// Header fields, none of which can fail once a scene is open.
double durationSec(const Handle& handle);
double cutoff(const Handle& handle);
std::uint64_t gaussianCount(const Handle& handle);
int shDegree(const Handle& handle);
bool isIndexed(const Handle& handle);
bool truncated(const Handle& handle);
std::string temporalModel(const Handle& handle);
std::string profile(const Handle& handle);
std::string library(const Handle& handle);
std::map<std::string, std::string> attributes(const Handle& handle);

/// The chunk index.
std::uint32_t chunkCount(const Handle& handle);
Result<void> chunkInterval(const Handle& handle, std::uint32_t index, double* t0, double* t1);
std::uint64_t bytesForTime(const Handle& handle, double t, int maxShBand);
std::uint64_t bytesForChunk(const Handle& handle, std::uint32_t index, int maxShBand);
Result<void> loadChunk(Handle& handle, std::uint32_t index, int maxShBand);

/// Audio. Absence is a value: `hasAudio` false, an empty codec, a zero size.
bool hasAudio(const Handle& handle);
std::string audioCodec(Handle& handle);
std::uint64_t audioSize(const Handle& handle);
Result<void> readAudio(Handle& handle, std::uint64_t offset, Span<std::uint8_t> into);

/// Fill the working set, and view what is in it. The view is invalidated by the next load.
Result<void> loadAll(Handle& handle, int maxShBand);
Result<void> loadAt(Handle& handle, double t, int maxShBand);
GaussianView loadedGaussians(const Handle& handle);

/// Reconstruct at an instant.
Result<void> stateAt(Handle& handle, double t, int maxShBand, StateHandle& out);
std::size_t stateCount(const StateHandle& state);
Span<const std::uint32_t> stateIndices(const StateHandle& state);
Span<const float> stateCenters(const StateHandle& state);
Span<const float> stateOpacity(const StateHandle& state);

/// The rest of the file. The record accessors may fetch on first use, which is why they
/// take a mutable handle and return a `Result`.
Result<void> loadRecords(Handle& handle);
Result<std::vector<MetadataRecord>> metadata(Handle& handle);
Result<std::vector<Attachment>> attachments(Handle& handle);
bool hasCamera(const Handle& handle);
Result<Camera> camera(Handle& handle);
bool hasStatistics(const Handle& handle);
Result<Statistics> statistics(const Handle& handle);
std::vector<SummaryOffset> summaryOffsets(const Handle& handle);
int summaryCrcState(const Handle& handle);

/// Encode. The gaussians are borrowed for the call and copied into the core's writer, so a
/// view from a decoder's working set is a valid argument.
Result<std::vector<std::uint8_t>> encodeScene(const GaussianView& gaussians, double durationSec,
                                              const WriteOptions& options);

/// Release. Both are safe on a handle that never opened, and on a null one.
void closeScene(Handle& handle) noexcept;
void closeState(StateHandle& state) noexcept;

/// What the linked core reports, or null when there is none.
const char* coreVersionString() noexcept;
bool available() noexcept;

}  // namespace detail
}  // namespace fourdgs

#endif  // FOURDGS_SRC_BACKEND_HPP
