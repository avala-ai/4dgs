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
using fourdgs::LateFrontMatterRecords;
using fourdgs::RecordSite;
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
/// are not the same field: `kUnsupported` alone covers three of the ten named refusals, and
/// plenty of genuine failures — a truncated file, a transport that gave up — name no rule at
/// all. Absent is therefore not "no error"; `Result::ok()` is what answers that.
void refusalIsOptionalAndTravelsWithTheError() {
  Result<int> unnamed(ErrorCode::kTruncated, "the file ends inside chunk 3");
  CHECK(!unnamed.error().refusal.has_value());
  CHECK(!unnamed.error().lateFrontMatterRecords.has_value());

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

/// Placement evidence is typed data and follows every way an Error can travel.
void lateFrontMatterSitesTravelWithTheError() {
  const LateFrontMatterRecords records{
      RecordSite{0x03, 2374},
      RecordSite{0x05, 516},
  };
  Result<void> named(Error(ErrorCode::kMalformed, "Quantization follows the first Chunk",
                           std::string("late-front-matter-record"), records));
  CHECK(named.error().lateFrontMatterRecords.has_value());
  if (!named.error().lateFrontMatterRecords.has_value()) return;
  CHECK_EQ(named.error().lateFrontMatterRecords->lateRecord.opcode,
           static_cast<std::uint8_t>(0x03));
  CHECK_EQ(named.error().lateFrontMatterRecords->lateRecord.offset,
           static_cast<std::uint64_t>(2374));
  CHECK_EQ(named.error().lateFrontMatterRecords->firstStateRecord.opcode,
           static_cast<std::uint8_t>(0x05));
  CHECK_EQ(named.error().lateFrontMatterRecords->firstStateRecord.offset,
           static_cast<std::uint64_t>(516));

  bool threw = false;
  try {
    named.value();
  } catch (const Exception& exception) {
    threw = true;
    CHECK_EQ(exception.error().code, ErrorCode::kMalformed);
    CHECK(exception.error().lateFrontMatterRecords.has_value());
    if (exception.error().lateFrontMatterRecords.has_value()) {
      CHECK_EQ(exception.error().lateFrontMatterRecords->lateRecord.offset,
               static_cast<std::uint64_t>(2374));
      CHECK_EQ(exception.error().lateFrontMatterRecords->firstStateRecord.offset,
               static_cast<std::uint64_t>(516));
    }
  }
  CHECK(threw);
}

void codesHaveNames() {
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kBadMagic)), std::string("kBadMagic"));
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kOk)), std::string("kOk"));
  CHECK_EQ(std::string(fourdgs::toString(ErrorCode::kResourceLimit)),
           std::string("kResourceLimit"));
}

void runTests() {
  carriesAValue();
  carriesAnError();
  valueThrowsForCallersWhoWantThat();
  voidResultReportsBothWays();
  refusalIsOptionalAndTravelsWithTheError();
  lateFrontMatterSitesTravelWithTheError();
  codesHaveNames();
}

}  // namespace

TEST_MAIN
