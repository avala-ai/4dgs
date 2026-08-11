// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The error policy: returned, never thrown, unless the caller asks.

#include <string>

#include "check.hpp"
#include "fourdgs/result.hpp"

namespace {

using fourdgs::Error;
using fourdgs::ErrorCode;
using fourdgs::Exception;
using fourdgs::Result;

void carriesAValue() {
  Result<int> result(7);
  CHECK(result.ok());
  CHECK(static_cast<bool>(result));
  CHECK_EQ(*result, 7);
  CHECK_EQ(result.value(), 7);
  CHECK_EQ(result.valueOr(9), 7);
}

void carriesAnError() {
  Result<int> result(ErrorCode::kMalformed, "window index 7 is outside a table of 4");
  CHECK(!result.ok());
  CHECK(!static_cast<bool>(result));
  CHECK_EQ(result.error().code, ErrorCode::kMalformed);
  CHECK_EQ(result.valueOr(9), 9);
  // Code and detail, so a log line names the problem — cross-SDK principle 6.
  CHECK_EQ(result.error().toString(),
           std::string("kMalformed: window index 7 is outside a table of 4"));
}

void valueThrowsForCallersWhoWantThat() {
  Result<int> result(ErrorCode::kTruncated, "the file ends inside chunk 3");
  bool threw = false;
  try {
    (void)result.value();
  } catch (const Exception& error) {
    threw = true;
    CHECK_EQ(error.error().code, ErrorCode::kTruncated);
    CHECK_EQ(std::string(error.what()), std::string("kTruncated: the file ends inside chunk 3"));
  }
  CHECK(threw);
}

void voidResultReportsBothWays() {
  Result<void> fine;
  CHECK(fine.ok());
  fine.value();  // does not throw

  Result<void> bad(Error(ErrorCode::kUnsupported, "codec \"brotli\" is not implemented here"));
  CHECK(!bad.ok());
  // Legal-but-unimplemented is its own code: the fix is a different build, not a different
  // file, and a caller cannot tell those apart from kMalformed.
  CHECK_EQ(bad.error().code, ErrorCode::kUnsupported);
}

/// The refusal identifier is optional, and absent is a real answer.
///
/// `code` says what kind of thing went wrong and `refusal` says which rule fired, so the two
/// are not the same field: `kUnsupported` alone covers three of the six named refusals, and
/// plenty of genuine failures — a truncated file, a transport that gave up — name no rule at
/// all. Absent is therefore not "no error"; `Result::ok()` is what answers that.
void refusalIsOptionalAndTravelsWithTheError() {
  Result<int> unnamed(ErrorCode::kTruncated, "the file ends inside chunk 3");
  CHECK(!unnamed.error().refusal.has_value());

  Result<void> named(Error(ErrorCode::kUnsupported,
                           "the Header declares temporal model 'frame-sequence'",
                           std::string("unknown-temporal-model")));
  CHECK(!named.ok());
  CHECK(named.error().refusal.has_value());
  CHECK_EQ(*named.error().refusal, std::string("unknown-temporal-model"));

  // A caller who asked for exceptions gets the identifier too, rather than having to parse
  // it back out of `what()`.
  bool threw = false;
  try {
    named.value();
  } catch (const Exception& error) {
    threw = true;
    CHECK(error.error().refusal.has_value());
    CHECK_EQ(*error.error().refusal, std::string("unknown-temporal-model"));
  }
  CHECK(threw);
}

void codesHaveNames() {
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kBadMagic)), std::string("kBadMagic"));
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kOk)), std::string("kOk"));
}

void runTests() {
  carriesAValue();
  carriesAnError();
  valueThrowsForCallersWhoWantThat();
  voidResultReportsBothWays();
  refusalIsOptionalAndTravelsWithTheError();
  codesHaveNames();
}

}  // namespace

TEST_MAIN
