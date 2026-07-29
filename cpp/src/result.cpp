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

const char* version() noexcept { return "0.0.0"; }

const char* coreVersion() noexcept { return detail::coreVersionString(); }

bool backendAvailable() noexcept { return detail::available(); }

}  // namespace fourdgs
