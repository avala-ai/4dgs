// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The seam, for a build with no core behind it.
///
/// Compiled when `rust/fourdgs/include/fourdgs.h` is not present. Opening always fails with
/// the same sentence, so a caller gets a diagnosis rather than an empty scene, and
/// `backendAvailable()` says so before the first decode. Every other entry point is
/// unreachable — a `Handle` only exists when an open succeeded — and returns the zero value
/// its documentation promises rather than pretending to have read a file.

#include "backend.hpp"

namespace fourdgs {
namespace detail {

namespace {

const char kReason[] =
    "this build of the 4dgs C++ binding was compiled without the Rust core; "
    "build the workspace with `cargo build -p fourdgs --release` and reconfigure CMake";

Error notImplemented() { return Error(ErrorCode::kNotImplemented, kReason); }

}  // namespace

Handle::~Handle() { closeScene(*this); }

StateHandle::~StateHandle() { closeState(*this); }

Result<void> openPath(Handle&, const std::string&) { return notImplemented(); }
Result<void> openMemory(Handle&, Span<const std::uint8_t>) { return notImplemented(); }
Result<void> openReadable(Handle&, Readable&) { return notImplemented(); }

double durationSec(const Handle&) { return 0.0; }
double cutoff(const Handle&) { return 0.0; }
std::uint64_t gaussianCount(const Handle&) { return 0; }
int shDegree(const Handle&) { return 0; }
bool isIndexed(const Handle&) { return false; }

std::uint32_t chunkCount(const Handle&) { return 0; }
Result<void> chunkInterval(const Handle&, std::uint32_t, double*, double*) {
  return notImplemented();
}
std::uint64_t bytesForTime(const Handle&, double, int) { return 0; }

bool hasAudio(const Handle&) { return false; }
std::string audioCodec(Handle&) { return std::string(); }
std::uint64_t audioSize(const Handle&) { return 0; }
Result<void> readAudio(Handle&, std::uint64_t, Span<std::uint8_t>) { return notImplemented(); }

Result<void> loadAll(Handle&, int) { return notImplemented(); }
Result<void> loadAt(Handle&, double, int) { return notImplemented(); }
GaussianView loadedGaussians(const Handle&) { return GaussianView(); }

Result<void> stateAt(Handle&, double, int, StateHandle&) { return notImplemented(); }
std::size_t stateCount(const StateHandle&) { return 0; }
Span<const std::uint32_t> stateIndices(const StateHandle&) { return Span<const std::uint32_t>(); }
Span<const float> stateCenters(const StateHandle&) { return Span<const float>(); }
Span<const float> stateOpacity(const StateHandle&) { return Span<const float>(); }

void closeScene(Handle& handle) noexcept { handle.scene = nullptr; }
void closeState(StateHandle& state) noexcept { state.state = nullptr; }

const char* coreVersionString() noexcept { return nullptr; }

bool available() noexcept { return false; }

}  // namespace detail
}  // namespace fourdgs
