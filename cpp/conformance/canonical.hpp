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

/// A float rounded for comparison; a non-finite value becomes `null`.
Json num(double value);
/// An integer as a string, so it survives a parser backed by doubles.
Json integer(std::uint64_t value);
Json integer(std::int64_t value);

/// CRC-32 (IEEE), as a decimal string. Used where a summary needs to prove it read the bytes
/// and not merely their length.
std::string crc32String(const std::uint8_t* data, std::size_t length);

/// The content order both implementations reproduce: the gaussian's whole decoded state,
/// rounded exactly as the summary rounds it, with its spherical harmonic coefficients last.
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
};

/// The statement every implementation must agree on for a variant.
std::string canonical(const SceneSummary& summary);

}  // namespace conformance
}  // namespace fourdgs

#endif  // FOURDGS_CONFORMANCE_CANONICAL_HPP
