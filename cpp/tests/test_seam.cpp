// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// FFI hygiene: what the binding does at the edge of the C ABI.
///
/// Two builds exist — one with the Rust core linked and one without — and this asserts the
/// contract of whichever one it was compiled into. Without a core, every open refuses with
/// `kNotImplemented` and a sentence naming the fix; with one, a buffer that is not a 4dgs
/// file comes back as a typed refusal carrying the core's own message, rather than as a
/// crash, an empty scene, or a code the caller has never heard of.

#include <memory>
#include <string>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ErrorCode;
using fourdgs::MemoryReadable;
using fourdgs::Result;
using fourdgs::Scene;

std::vector<std::uint8_t> notA4dgsFile() {
  const std::string text = "this is not a 4dgs file, it is a sentence";
  return std::vector<std::uint8_t>(text.begin(), text.end());
}

fourdgs::Span<const std::uint8_t> bytesOf(const std::vector<std::uint8_t>& bytes) {
  return fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size());
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

/// Every open path refuses the same bytes the same way. Three entry points into one decoder
/// that disagreed about what a file is would be a binding bug, not a format one.
void refusalsAreTypedAndConsistent() {
  const std::vector<std::uint8_t> bytes = notA4dgsFile();

  Result<std::unique_ptr<Scene>> fromMemory = Scene::openMemory(bytesOf(bytes));
  CHECK(!fromMemory.ok());

  MemoryReadable source(bytes);
  Result<std::unique_ptr<Scene>> fromReadable = Scene::open(source);
  CHECK(!fromReadable.ok());

  Result<std::unique_ptr<Scene>> fromMissingPath = Scene::openPath("/nonexistent/scene.4dgs");
  CHECK(!fromMissingPath.ok());

  if (fourdgs::backendAvailable()) {
    CHECK_EQ(fromMemory.error().code, fromReadable.error().code);
    // Not a 4dgs file, and the core says which problem that is rather than a bare failure.
    CHECK_EQ(fromMemory.error().code, ErrorCode::kUnsupportedVersion);
    CHECK(!fromMemory.error().message.empty());
    // A path that does not exist is a transport failure, which is a different problem from
    // bytes that are not a scene.
    CHECK_EQ(fromMissingPath.error().code, ErrorCode::kIo);
  } else {
    CHECK_EQ(fromMemory.error().code, ErrorCode::kNotImplemented);
    CHECK_EQ(fromReadable.error().code, ErrorCode::kNotImplemented);
    // The message names what to do about it, not merely that something is missing.
    CHECK(fromMemory.error().message.find("Rust core") != std::string::npos);
    CHECK(fromMemory.error().message.find("cargo build") != std::string::npos);
  }
}

/// Open and close many times over, on every entry point.
///
/// Nothing here asserts on memory by itself — the assertion is the sanitizer this runs under.
/// It is a loop so that a leak of one handle is a leak of six hundred, which a leak checker
/// reports and a human notices. The reader path matters most: the ABI takes ownership of the
/// callback context and releases it once, including when the open it was passed to failed.
void openAndCloseRepeatedly() {
  const std::vector<std::uint8_t> bytes = notA4dgsFile();
  for (int i = 0; i < 200; ++i) {
    Result<std::unique_ptr<Scene>> fromMemory = Scene::openMemory(bytesOf(bytes));
    if (fromMemory.ok()) (void)(*fromMemory)->loadAll(3);

    MemoryReadable source(bytes);
    Result<std::unique_ptr<Scene>> fromReadable = Scene::open(source);
    if (fromReadable.ok()) (void)(*fromReadable)->loadAll(3);

    Result<std::unique_ptr<Scene>> fromPath = Scene::openPath("/nonexistent/scene.4dgs");
    (void)fromPath.ok();
  }
}

void runTests() {
  versionsAreReported();
  refusalsAreTypedAndConsistent();
  openAndCloseRepeatedly();
}

}  // namespace

TEST_MAIN
