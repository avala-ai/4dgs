// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_READABLE_HPP
#define FOURDGS_READABLE_HPP

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "fourdgs/result.hpp"
#include "fourdgs/span.hpp"

namespace fourdgs {

/// Something that can report its size and read a byte range.
///
/// The core depends on this and nothing else — no HTTP client, no filesystem, no platform
/// types (cross-SDK principle 3). A transport is a subclass: the two below, or an HTTP range
/// reader, or a cache, written by whoever needs it. Implementations are called from the
/// decoder and must not throw; report failure as `ErrorCode::kIo` with a message.
class Readable {
 public:
  virtual ~Readable();

  /// Total size of the resource in bytes.
  virtual Result<std::uint64_t> size() = 0;

  /// Read into `into`, starting at `offset`. Returns how many bytes were read, which is
  /// short only at the end of the resource — a decoder reads that as truncation, not as an
  /// I/O error, and recovers what the file did contain.
  virtual Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) = 0;
};

/// A file on disk, read with positioned reads and no seek state.
class FileReadable : public Readable {
 public:
  /// Opens `path`, or returns `kIo` naming it.
  static Result<FileReadable*> open(const std::string& path);

  ~FileReadable() override;
  FileReadable(const FileReadable&) = delete;
  FileReadable& operator=(const FileReadable&) = delete;

  Result<std::uint64_t> size() override;
  Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override;

 private:
  FileReadable(std::FILE* handle, std::uint64_t size, std::string path)
      : handle_(handle), size_(size), path_(std::move(path)) {}

  std::FILE* handle_ = nullptr;
  std::uint64_t size_ = 0;
  std::string path_;
};

/// Bytes already in memory. The transport a test uses, so the core is testable without a
/// filesystem or a network.
class MemoryReadable : public Readable {
 public:
  explicit MemoryReadable(std::vector<std::uint8_t> bytes) : bytes_(std::move(bytes)) {}
  explicit MemoryReadable(Span<const std::uint8_t> bytes)
      : bytes_(bytes.begin(), bytes.end()) {}

  Result<std::uint64_t> size() override;
  Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override;

 private:
  std::vector<std::uint8_t> bytes_;
};

/// A transport that counts what it transferred, wrapping another.
///
/// Band skipping is a claim about bytes that never moved, so it is checked at the transport
/// rather than at the decoded value: reading a chunk at a band cap must transfer exactly what
/// the chunk index declares for the bands at or below it.
class CountingReadable : public Readable {
 public:
  explicit CountingReadable(Readable* inner) : inner_(inner) {}

  Result<std::uint64_t> size() override;
  Result<std::size_t> read(std::uint64_t offset, Span<std::uint8_t> into) override;

  std::uint64_t bytesRead() const noexcept { return bytesRead_; }
  void resetCount() noexcept { bytesRead_ = 0; }

 private:
  Readable* inner_;
  std::uint64_t bytesRead_ = 0;
};

}  // namespace fourdgs

#endif  // FOURDGS_READABLE_HPP
