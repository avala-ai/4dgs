// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "fourdgs/readable.hpp"

#include <cerrno>
#include <cstring>

namespace fourdgs {

Readable::~Readable() = default;

Result<FileReadable*> FileReadable::open(const std::string& path) {
  std::FILE* handle = std::fopen(path.c_str(), "rb");
  if (handle == nullptr) {
    return Error(ErrorCode::kIo, "cannot open " + path + ": " + std::strerror(errno));
  }
  if (std::fseek(handle, 0, SEEK_END) != 0) {
    std::fclose(handle);
    return Error(ErrorCode::kIo, "cannot measure " + path + ": " + std::strerror(errno));
  }
  const long end = std::ftell(handle);  // NOLINT(runtime/int) — what ftell returns
  if (end < 0) {
    std::fclose(handle);
    return Error(ErrorCode::kIo, "cannot measure " + path + ": " + std::strerror(errno));
  }
  return new FileReadable(handle, static_cast<std::uint64_t>(end), path);
}

FileReadable::~FileReadable() {
  if (handle_ != nullptr) std::fclose(handle_);
}

Result<std::uint64_t> FileReadable::size() { return size_; }

Result<std::size_t> FileReadable::read(std::uint64_t offset, Span<std::uint8_t> into) {
  if (offset > size_) {
    return Error(ErrorCode::kInvalidArgument, "read at offset " + std::to_string(offset) +
                                                  " past the end of " + path_ + ", which is " +
                                                  std::to_string(size_) + " bytes");
  }
  if (std::fseek(handle_, static_cast<long>(offset), SEEK_SET) != 0) {  // NOLINT(runtime/int)
    return Error(ErrorCode::kIo, "cannot seek " + path_ + ": " + std::strerror(errno));
  }
  const std::size_t got = std::fread(into.data(), 1, into.size(), handle_);
  if (got != into.size() && std::ferror(handle_) != 0) {
    return Error(ErrorCode::kIo, "cannot read " + path_ + ": " + std::strerror(errno));
  }
  // A short read at the end of the file is truncation for the decoder to report, not an
  // I/O failure for the transport to raise.
  return got;
}

Result<std::uint64_t> MemoryReadable::size() { return static_cast<std::uint64_t>(bytes_.size()); }

Result<std::size_t> MemoryReadable::read(std::uint64_t offset, Span<std::uint8_t> into) {
  if (offset > bytes_.size()) {
    return Error(ErrorCode::kInvalidArgument, "read at offset " + std::to_string(offset) +
                                                  " past the end of a " +
                                                  std::to_string(bytes_.size()) + " byte buffer");
  }
  const std::size_t available = bytes_.size() - static_cast<std::size_t>(offset);
  const std::size_t got = available < into.size() ? available : into.size();
  if (got != 0) std::memcpy(into.data(), bytes_.data() + offset, got);
  return got;
}

Result<std::uint64_t> CountingReadable::size() { return inner_->size(); }

Result<std::size_t> CountingReadable::read(std::uint64_t offset, Span<std::uint8_t> into) {
  // Counted as asked for, not as delivered: the claim being checked is that the bytes of a
  // skipped band are never requested.
  bytesRead_ += into.size();
  return inner_->read(offset, into);
}

}  // namespace fourdgs
