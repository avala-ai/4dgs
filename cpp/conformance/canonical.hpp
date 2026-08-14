// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_CONFORMANCE_CANONICAL_HPP
#define FOURDGS_CONFORMANCE_CANONICAL_HPP

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "fourdgs/model.hpp"

/// The canonical JSON two implementations are diffed on.
///
/// A restatement of `tests/conformance/canonical.py` in C++, and it has to agree with it to
/// the digit: integers as strings so a 64-bit value survives a JSON parser backed by doubles,
/// floats rounded to six decimals, a never-fading gaussian's sigma as `null`, audio sources
/// as an array (empty when absent), keys sorted.
///
/// **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an
/// encoder, so every per-gaussian number — the sample, the aggregates, the spherical harmonic
/// digest — is taken in the content order `stableOrder` derives from decoded values alone.
namespace fourdgs {
namespace conformance {

/// A JSON value that renders with sorted keys and no floating-point ambiguity.
///
/// Numbers are carried as the text they will be printed as, because the rounding is the
/// contract: rendering happens once, where the value is produced, and not again.
class Json {
 public:
  static Json null();
  static Json boolean(bool value);
  /// A number already rendered — see `num()` and `integer()`.
  static Json number(std::string rendered);
  static Json string(std::string value);
  static Json array(std::vector<Json> items);
  static Json object(std::map<std::string, Json> members);
  /// A value already serialized as JSON text — used for provenance, which the core emits
  /// as a complete object so every binding shares one slerp rather than reimplementing it.
  static Json raw(std::string json);

  std::string render(int indent = 0) const;

 private:
  enum class Kind { kNull, kBool, kNumber, kString, kArray, kObject };
  Kind kind_ = Kind::kNull;
  bool bool_ = false;
  std::string text_;
  std::vector<Json> array_;
  std::map<std::string, Json> object_;
};

namespace detail {

/// Rewrite a rendered fixed-point number's radix to `.`, and back.
///
/// `snprintf` and `strtod` both take the radix from `LC_NUMERIC`, and a canonical summary may
/// not: JSON spells a radix `.` and nothing else. These two are how the rendering and the
/// reading back are pinned to that regardless of the locale the process is running under.
///
/// Declared here rather than kept to the translation unit so the substitution can be tested
/// on a machine with no comma-radix locale installed, which is most CI images. `radix` is a
/// string and not a character because `localeconv()->decimal_point` is one: a locale may
/// spell its radix in several bytes, and taking only the first would corrupt the number.
std::string radixToJson(std::string rendered, const char* radix);
std::string radixFromJson(std::string json, const char* radix);

}  // namespace detail

/// A float rounded for comparison; a non-finite value becomes `null`.
Json num(double value);
/// An integer as a string, so it survives a parser backed by doubles.
Json integer(std::uint64_t value);
Json integer(std::int64_t value);

/// CRC-32 (IEEE), as a decimal string. Used where a summary needs to prove it read the bytes
/// and not merely their length.
std::string crc32String(const std::uint8_t* data, std::size_t length);

/// The content order: the gaussian's whole decoded state, rounded exactly as the summary
/// rounds it, followed by SH, membership, and exact decoded floats as the final tiebreaker.
///
/// The first three are the order every implementation reproduces. The fourth is this
/// binding's alone — `canonical.py`'s `_stable_keys` declines to use exact decoded values on
/// the grounds that independently implemented decoders may differ in their last bits, and
/// reaches order-independence instead by making every emitted value a function of the rounded
/// key. Both give the same document today, because a rounded-key tie is a tie in everything
/// this binding emits. They stop agreeing the moment C++ claims `canonicalStateOrder`, whose
/// state rows the reference orders by the rounded row they emit rather than by the gaussian.
std::vector<std::size_t> stableOrder(const GaussianView& gaussians);

/// What a summary needs beyond the gaussians. A record that changes nothing here is a record
/// an implementation could ignore entirely and still pass.
struct SceneSummary {
  const Header* header = nullptr;
  const GaussianView* gaussians = nullptr;
  std::vector<AudioSource> audioSources;
  std::vector<std::pair<double, double>> chunkIntervals;
  const Camera* camera = nullptr;
  std::vector<MetadataRecord> metadata;
  std::vector<Attachment> attachments;
  const Statistics* statistics = nullptr;
  std::vector<SummaryOffset> summaryOffsets;
  const bool* summaryCrcOk = nullptr;  ///< Null renders as JSON null.
  /// Canonical provenance object from the core. Empty omits the key entirely.
  std::string provenanceJson;
  /// Canonical object-layer JSON from the core: `objects` and `states`. Empty when the
  /// file carries neither object records nor per-gaussian membership.
  std::string objectsJson;
  std::string objectStatesJson;
};

/// The statement every implementation must agree on for a variant.
std::string canonical(const SceneSummary& summary);

/// The canonical answer for a file this reader refused: `{"refused": "<identifier>"}`.
///
/// A refusal is a result, not a crash. The runner prints this on stdout and exits 0, and the
/// harness diffs it against the committed expectation like any other answer — which is what
/// separates "refused the file" from "refused it for the right reason". A decoder that
/// rejects a bad-magic file because it mis-parsed the version would pass a bare-refusal test
/// and fail this one.
std::string refusalJson(const std::string& identifier);

}  // namespace conformance
}  // namespace fourdgs

#endif  // FOURDGS_CONFORMANCE_CANONICAL_HPP
