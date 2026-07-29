// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_RESULT_HPP
#define FOURDGS_RESULT_HPP

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

namespace fourdgs {

/// What went wrong, in the categories a caller can act on differently.
///
/// The split that matters is `kUnsupported` against `kMalformed`: a file that uses a codec
/// this build does not implement is a legal file and the fix is a different build, while a
/// malformed one is a bad file and the fix is a different file. Collapsing the two into one
/// error is how a user ends up debugging their pipeline over a missing feature.
enum class ErrorCode : std::int32_t {
  kOk = 0,
  kNotImplemented = 1,  ///< This build has no decoder behind it. See the README.
  kInvalidArgument = 2,
  kIo = 3,        ///< The transport failed; `Error::message` carries its report.
  kBadMagic = 4,  ///< Not a 4dgs file.
  kUnsupportedVersion = 5,
  kTruncated = 6,    ///< The file ends inside a record. Partial results may still be valid.
  kMalformed = 7,    ///< Structurally wrong: a length, an offset, or a value out of range.
  kUnsupported = 8,  ///< Legal but unimplemented here: an unknown codec, a future feature.
  kChecksumMismatch = 9,
  kInternal = 10,
  /// A legal request on the wrong read path — one chunk by index from a sequential reader.
  /// Neither the file nor the call is wrong, so a caller that meets this skips rather than
  /// fails.
  kUnsupportedMode = 11,
};

const char* toString(ErrorCode code) noexcept;

/// A code and the sentence that names the problem.
///
/// Cross-SDK principle 6: a decoder that refuses a file says which byte, which record, which
/// value, and what was expected. The message comes from the core, so every SDK reports a
/// refusal in the same words.
struct Error {
  ErrorCode code = ErrorCode::kInternal;
  std::string message;

  Error() = default;
  Error(ErrorCode c, std::string m) : code(c), message(std::move(m)) {}

  /// `"kMalformed: window index 7 is outside a table of 4"` — code and detail, for a log line
  /// or a `what()`.
  std::string toString() const;
};

/// Thrown only by `Result::value()`, and only by callers who asked for exceptions.
class Exception : public std::runtime_error {
 public:
  explicit Exception(Error error)
      : std::runtime_error(error.toString()), error_(std::move(error)) {}
  const Error& error() const noexcept { return error_; }

 private:
  Error error_;
};

/// `std::expected` in the subset this API uses, because the package is C++17.
///
/// Errors are returned, not thrown. The C ABI underneath cannot throw, engine and DCC
/// integrators routinely build with `-fno-exceptions`, and a decoder's failures are
/// expected control flow rather than exceptional: a viewer handed a truncated download
/// wants a diagnosis, not a stack unwind. `value()` throws for callers who prefer the other
/// style, so the choice stays theirs.
template <typename T>
class Result {
 public:
  Result(T value) : value_(std::move(value)) {}      // NOLINT(runtime/explicit)
  Result(Error error) : error_(std::move(error)) {}  // NOLINT(runtime/explicit)
  Result(ErrorCode code, std::string message) : error_(code, std::move(message)) {}

  Result(const Result&) = default;
  Result(Result&&) = default;
  Result& operator=(const Result&) = default;
  Result& operator=(Result&&) = default;

  bool ok() const noexcept { return value_.has_value(); }
  explicit operator bool() const noexcept { return ok(); }

  /// Undefined unless `ok()`. The checked accessor is `value()`.
  const T& operator*() const noexcept { return *value_; }
  T& operator*() noexcept { return *value_; }
  const T* operator->() const noexcept { return &*value_; }
  T* operator->() noexcept { return &*value_; }

  /// Throws `Exception` when this holds an error.
  const T& value() const {
    if (!ok()) throw Exception(error_);
    return *value_;
  }
  T& value() {
    if (!ok()) throw Exception(error_);
    return *value_;
  }

  T valueOr(T fallback) const { return ok() ? *value_ : std::move(fallback); }

  /// Undefined unless `!ok()`.
  const Error& error() const noexcept { return error_; }

 private:
  // `std::optional` rather than a default-constructed member, so that a `T` which cannot be
  // default-constructed — an RAII handle, which is most of what this API returns — can still
  // be carried.
  std::optional<T> value_;
  Error error_;
};

/// The `void` case: an operation that either succeeded or says why not.
template <>
class Result<void> {
 public:
  Result() : ok_(true) {}
  Result(Error error) : ok_(false), error_(std::move(error)) {}  // NOLINT(runtime/explicit)
  Result(ErrorCode code, std::string message) : ok_(false), error_(code, std::move(message)) {}

  bool ok() const noexcept { return ok_; }
  explicit operator bool() const noexcept { return ok_; }

  void value() const {
    if (!ok_) throw Exception(error_);
  }

  const Error& error() const noexcept { return error_; }

 private:
  bool ok_;
  Error error_;
};

}  // namespace fourdgs

#endif  // FOURDGS_RESULT_HPP
