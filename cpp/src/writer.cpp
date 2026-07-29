// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The public encode surface, forwarded to the seam.
///
/// Everything real happens in `backend_capi.cpp`, which owns the core's C ABI; this file is
/// the one line of public API that stays out of that ABI's way, mirroring how `scene.cpp`
/// forwards the decode surface.

#include "fourdgs/writer.hpp"

#include "backend.hpp"

namespace fourdgs {

Result<std::vector<std::uint8_t>> encodeScene(const GaussianView& gaussians, double durationSec,
                                              const WriteOptions& options) {
  return detail::encodeScene(gaussians, durationSec, options);
}

}  // namespace fourdgs
