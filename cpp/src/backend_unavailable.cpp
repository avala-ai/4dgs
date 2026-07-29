// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The seam, for a build with no core behind it.
///
/// Compiled when `rust/fourdgs/include/fourdgs.h` is not present. Every entry point refuses
/// with the same sentence, so a caller gets a diagnosis rather than an empty scene, and
/// `backendAvailable()` says so before the first decode. The alternative — a build that
/// silently decodes nothing — is the failure mode this file exists to prevent.

#include "backend.hpp"

namespace fourdgs {
namespace detail {

namespace {

const char kReason[] =
    "this build of the 4dgs C++ binding was compiled without the Rust core; "
    "build the workspace with `cargo build -p fourdgs --release` and reconfigure CMake";

Error notImplemented() { return Error(ErrorCode::kNotImplemented, kReason); }

}  // namespace

Handle::~Handle() { closeHandle(*this); }

Result<void> openStream(Handle&) { return notImplemented(); }

Result<bool> nextChunk(Handle&) { return notImplemented(); }

Result<void> openIndexed(Handle&) { return notImplemented(); }

Result<void> readChunk(Handle&, const ChunkIndexEntry&, int, GaussianData&) {
  return notImplemented();
}

Result<bool> readAudio(Handle&, AudioTrack*) { return notImplemented(); }

Result<bool> readCamera(Handle&, Camera*) { return notImplemented(); }

Result<std::vector<MetadataRecord>> readMetadata(Handle&) { return notImplemented(); }

Result<std::vector<Attachment>> readAttachments(Handle&) { return notImplemented(); }

void closeHandle(Handle& handle) noexcept { handle.core = nullptr; }

const char* coreVersionString() noexcept { return nullptr; }

bool available() noexcept { return false; }

}  // namespace detail
}  // namespace fourdgs
