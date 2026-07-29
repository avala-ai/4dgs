// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// FFI hygiene: what the binding does at the edge of the C ABI.
///
/// Two builds exist — one with the Rust core linked and one without — and this asserts the
/// contract of whichever one it was compiled into. Without a core, every entry point refuses
/// with `kNotImplemented` and a sentence naming the fix; with one, a buffer that is not a
/// 4dgs file comes back as `kBadMagic` rather than as a crash, an empty scene, or a code the
/// caller has never heard of.

#include <memory>
#include <string>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ErrorCode;
using fourdgs::IndexedReader;
using fourdgs::MemoryReadable;
using fourdgs::Result;
using fourdgs::StreamDecoder;

std::vector<std::uint8_t> notA4dgsFile() {
  const std::string text = "this is not a 4dgs file, it is a sentence";
  return std::vector<std::uint8_t>(text.begin(), text.end());
}

void versionsAreReported() {
  CHECK(std::string(fourdgs::version()) == std::string("0.0.0"));
  if (fourdgs::backendAvailable()) {
    CHECK(fourdgs::coreVersion() != nullptr);
  } else {
    // No core, and the package says so rather than implying one.
    CHECK(fourdgs::coreVersion() == nullptr);
  }
}

void refusalsAreTyped() {
  MemoryReadable source(notA4dgsFile());
  Result<std::unique_ptr<StreamDecoder>> streamed = StreamDecoder::open(source);
  CHECK(!streamed.ok());

  MemoryReadable other(notA4dgsFile());
  Result<std::unique_ptr<IndexedReader>> indexed = IndexedReader::open(other);
  CHECK(!indexed.ok());

  if (fourdgs::backendAvailable()) {
    // The core read the bytes and refused them for what they are.
    CHECK_EQ(streamed.error().code, ErrorCode::kBadMagic);
    CHECK_EQ(indexed.error().code, ErrorCode::kBadMagic);
    CHECK(!streamed.error().message.empty());
  } else {
    CHECK_EQ(streamed.error().code, ErrorCode::kNotImplemented);
    CHECK_EQ(indexed.error().code, ErrorCode::kNotImplemented);
    // The message names what to do about it, not merely that something is missing.
    CHECK(streamed.error().message.find("Rust core") != std::string::npos);
    CHECK(streamed.error().message.find("cargo build") != std::string::npos);
  }
}

/// Open and close many times over. Nothing here asserts on memory by itself — the assertion
/// is the sanitizer this runs under. It is a loop so that a leak of one handle is a leak of
/// two hundred, which a leak checker reports and a human notices.
void openAndCloseRepeatedly() {
  for (int i = 0; i < 200; ++i) {
    MemoryReadable source(notA4dgsFile());
    Result<std::unique_ptr<StreamDecoder>> streamed = StreamDecoder::open(source);
    if (streamed.ok()) {
      Result<bool> advanced = (*streamed)->next();
      (void)advanced;
    }
  }
}

void runTests() {
  versionsAreReported();
  refusalsAreTyped();
  openAndCloseRepeatedly();
}

}  // namespace

TEST_MAIN
