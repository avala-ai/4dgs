// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The transport abstraction: size, positioned read, and a short read at the end that is
/// truncation for the decoder rather than an error for the transport.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "check.hpp"
#include "fourdgs/readable.hpp"

namespace {

using fourdgs::CountingReadable;
using fourdgs::ErrorCode;
using fourdgs::FileReadable;
using fourdgs::MemoryReadable;
using fourdgs::Result;
using fourdgs::Span;

std::vector<std::uint8_t> counted(std::size_t n) {
  std::vector<std::uint8_t> bytes(n);
  for (std::size_t i = 0; i < n; ++i) bytes[i] = static_cast<std::uint8_t>(i);
  return bytes;
}

void memoryReadsRanges() {
  MemoryReadable source(counted(16));
  CHECK_EQ(*source.size(), static_cast<std::uint64_t>(16));

  std::vector<std::uint8_t> into(4);
  Result<std::size_t> got = source.read(4, Span<std::uint8_t>(into.data(), into.size()));
  CHECK(got.ok());
  CHECK_EQ(*got, static_cast<std::size_t>(4));
  CHECK_EQ(into[0], static_cast<std::uint8_t>(4));
  CHECK_EQ(into[3], static_cast<std::uint8_t>(7));
}

void shortReadAtTheEndIsNotAnError() {
  MemoryReadable source(counted(6));
  std::vector<std::uint8_t> into(10);
  Result<std::size_t> got = source.read(2, Span<std::uint8_t>(into.data(), into.size()));
  CHECK(got.ok());
  CHECK_EQ(*got, static_cast<std::size_t>(4));
}

void readingPastTheEndIsAnError() {
  MemoryReadable source(counted(6));
  std::vector<std::uint8_t> into(1);
  Result<std::size_t> got = source.read(7, Span<std::uint8_t>(into.data(), into.size()));
  CHECK(!got.ok());
  CHECK_EQ(got.error().code, ErrorCode::kInvalidArgument);
  // The message names the offset and the size, not just "bad read".
  CHECK(got.error().message.find("7") != std::string::npos);
  CHECK(got.error().message.find("6") != std::string::npos);
}

void countingMeasuresWhatWasAskedFor() {
  MemoryReadable inner(counted(64));
  CountingReadable source(&inner);
  std::vector<std::uint8_t> into(10);
  (void)source.read(0, Span<std::uint8_t>(into.data(), into.size()));
  (void)source.read(20, Span<std::uint8_t>(into.data(), 5));
  CHECK_EQ(source.bytesRead(), static_cast<std::uint64_t>(15));
  source.resetCount();
  CHECK_EQ(source.bytesRead(), static_cast<std::uint64_t>(0));
}

void filesOpenAndFailByName() {
  Result<FileReadable*> missing = FileReadable::open("/nonexistent/4dgs/fixture.4dgs");
  CHECK(!missing.ok());
  CHECK_EQ(missing.error().code, ErrorCode::kIo);
  CHECK(missing.error().message.find("fixture.4dgs") != std::string::npos);

  // In the build directory, where CTest runs, and removed below. `tmpnam` would be the
  // obvious call and is the one the linker warns about.
  const std::string path = "fourdgs-readable-test.bin";
  std::FILE* handle = std::fopen(path.c_str(), "wb");
  CHECK(handle != nullptr);
  if (handle == nullptr) return;
  const std::vector<std::uint8_t> bytes = counted(32);
  std::fwrite(bytes.data(), 1, bytes.size(), handle);
  std::fclose(handle);

  Result<FileReadable*> opened = FileReadable::open(path);
  CHECK(opened.ok());
  if (opened.ok()) {
    std::unique_ptr<FileReadable> source(*opened);
    CHECK_EQ(*source->size(), static_cast<std::uint64_t>(32));
    std::vector<std::uint8_t> into(3);
    Result<std::size_t> got = source->read(29, Span<std::uint8_t>(into.data(), into.size()));
    CHECK(got.ok());
    CHECK_EQ(into[2], static_cast<std::uint8_t>(31));
  }
  std::remove(path.c_str());
}

void runTests() {
  memoryReadsRanges();
  shortReadAtTheEndIsNotAnError();
  readingPastTheEndIsAnError();
  countingMeasuresWhatWasAskedFor();
  filesOpenAndFailByName();
}

}  // namespace

TEST_MAIN
