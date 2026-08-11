// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/result.hpp"

#include "backend.hpp"
#include "fourdgs/fourdgs.hpp"

namespace fourdgs {

const char* toString(ErrorCode code) noexcept {
  switch (code) {
    case ErrorCode::kOk:
      return "kOk";
    case ErrorCode::kNotImplemented:
      return "kNotImplemented";
    case ErrorCode::kInvalidArgument:
      return "kInvalidArgument";
    case ErrorCode::kIo:
      return "kIo";
    case ErrorCode::kBadMagic:
      return "kBadMagic";
    case ErrorCode::kUnsupportedVersion:
      return "kUnsupportedVersion";
    case ErrorCode::kTruncated:
      return "kTruncated";
    case ErrorCode::kMalformed:
      return "kMalformed";
    case ErrorCode::kUnsupported:
      return "kUnsupported";
    case ErrorCode::kChecksumMismatch:
      return "kChecksumMismatch";
    case ErrorCode::kInternal:
      return "kInternal";
    case ErrorCode::kUnsupportedMode:
      return "kUnsupportedMode";
  }
  return "kInternal";
}

std::string Error::toString() const {
  std::string out = fourdgs::toString(code);
  if (!message.empty()) {
    out += ": ";
    out += message;
  }
  return out;
}

// One version per package, and for this one it lives in `project(fourdgs-cpp VERSION ...)`:
// that number is what `write_basic_package_version_file` writes into the installed package
// config, so it is what answers a consumer's `find_package(fourdgs-cpp 0.1)`. A second copy
// here could only ever agree with it by accident, and did not — the package said 0.1.0
// while this function said 0.0.0. The build passes it in; the fallback keeps this file
// compiling in a tool that has not, and `test_seam` asserts the value the build produces.
#ifndef FOURDGS_CPP_VERSION
#define FOURDGS_CPP_VERSION "0.1.0"
#endif

const char* version() noexcept { return FOURDGS_CPP_VERSION; }

const char* coreVersion() noexcept { return detail::coreVersionString(); }

bool backendAvailable() noexcept { return detail::available(); }

}  // namespace fourdgs
