// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_SPAN_HPP
#define FOURDGS_SPAN_HPP

#include <cstddef>
#include <type_traits>

namespace fourdgs {

/// A pointer and a length over memory somebody else owns.
///
/// `std::span` is C++20 and this package is C++17, because the consumers it exists for —
/// engines and DCC plugins — pin older toolchains. The subset here is the part a decode
/// API needs: the flat attribute arrays are handed out as views rather than copied, which
/// is what keeps a chunk's cost the chunk's size.
template <typename T>
class Span {
 public:
  using element_type = T;
  using value_type = typename std::remove_cv<T>::type;

  constexpr Span() noexcept : data_(nullptr), size_(0) {}
  constexpr Span(T* data, std::size_t size) noexcept : data_(data), size_(size) {}

  /// Converting constructor from `Span<U>` to `Span<const U>`.
  template <typename U, typename = typename std::enable_if<std::is_same<const U, T>::value>::type>
  constexpr Span(const Span<U>& other) noexcept : data_(other.data()), size_(other.size()) {}

  constexpr T* data() const noexcept { return data_; }
  constexpr std::size_t size() const noexcept { return size_; }
  constexpr bool empty() const noexcept { return size_ == 0; }

  constexpr T* begin() const noexcept { return data_; }
  constexpr T* end() const noexcept { return data_ + size_; }

  /// Unchecked, like every other span. Callers that index from file data validate the
  /// index against `size()` first; the decoder itself never hands out a span whose length
  /// it has not read from a validated field.
  constexpr T& operator[](std::size_t i) const noexcept { return data_[i]; }

  constexpr Span<T> subspan(std::size_t offset, std::size_t count) const noexcept {
    return Span<T>(data_ + offset, count);
  }

 private:
  T* data_;
  std::size_t size_;
};

using ByteSpan = Span<const unsigned char>;

}  // namespace fourdgs

#endif  // FOURDGS_SPAN_HPP
