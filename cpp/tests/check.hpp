// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_TESTS_CHECK_HPP
#define FOURDGS_TESTS_CHECK_HPP

#include <cstdio>
#include <cstdlib>
#include <string>

/// Assertions, and nothing else.
///
/// A test framework is a vendored dependency, and this package's budget does not have one:
/// the whole need is a macro that prints the file, the line and the expression that failed,
/// and a `main` that returns non-zero. CTest reports the rest.
namespace fourdgs {
namespace testing {

inline int& failures() {
  static int count = 0;
  return count;
}

inline void report(const char* file, int line, const char* expression, const std::string& detail) {
  std::fprintf(stderr, "%s:%d: %s%s%s\n", file, line, expression, detail.empty() ? "" : " — ",
               detail.c_str());
  ++failures();
}

}  // namespace testing
}  // namespace fourdgs

#define CHECK(expression)                                                         \
  do {                                                                            \
    if (!(expression)) {                                                          \
      ::fourdgs::testing::report(__FILE__, __LINE__, #expression, std::string()); \
    }                                                                             \
  } while (false)

#define CHECK_EQ(actual, expected)                                                             \
  do {                                                                                         \
    const auto actualValue = (actual);                                                         \
    const auto expectedValue = (expected);                                                     \
    if (!(actualValue == expectedValue)) {                                                     \
      ::fourdgs::testing::report(__FILE__, __LINE__, #actual " == " #expected, "they differ"); \
    }                                                                                          \
  } while (false)

#define TEST_MAIN                                                                   \
  int main() {                                                                      \
    runTests();                                                                     \
    if (::fourdgs::testing::failures() != 0) {                                      \
      std::fprintf(stderr, "%d check(s) failed\n", ::fourdgs::testing::failures()); \
      return 1;                                                                     \
    }                                                                               \
    return 0;                                                                       \
  }

#endif  // FOURDGS_TESTS_CHECK_HPP
