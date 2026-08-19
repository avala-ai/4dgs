// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_FOURDGS_HPP
#define FOURDGS_FOURDGS_HPP

/// 4dgs — C++ binding.
///
/// A thin, RAII surface over the Rust core's C ABI, for engine, DCC and native-viewer
/// integrators. It is not a second decoder: the bytes are parsed once, in one place, so the
/// two cannot drift apart on what a file means.
///
/// Decoding ends at reconstructed gaussian state at time `t`. Rendering — ordering, culling,
/// level of detail, anything touching a GPU — is out of scope for this repository and lives
/// wherever the splats are drawn.

#include "fourdgs/model.hpp"
#include "fourdgs/readable.hpp"
#include "fourdgs/result.hpp"
#include "fourdgs/scene.hpp"
#include "fourdgs/span.hpp"
#include "fourdgs/writer.hpp"

namespace fourdgs {

/// This package's version — the same number `project(fourdgs-cpp VERSION ...)` declares and
/// the installed `fourdgs-cpp-config-version.cmake` answers `find_package` with, so what an
/// application reports at run time and what its build resolved cannot disagree.
const char* version() noexcept;

/// The version string the linked core reports, or `nullptr` when no core is linked.
const char* coreVersion() noexcept;

/// Whether this build has a decoder behind it.
///
/// False for a build made before the core landed: the API is present, every call returns
/// `ErrorCode::kNotImplemented`, and nothing pretends otherwise. A consumer can assert on
/// this at startup rather than discovering it at the first decode.
bool backendAvailable() noexcept;

}  // namespace fourdgs

#endif  // FOURDGS_FOURDGS_HPP
