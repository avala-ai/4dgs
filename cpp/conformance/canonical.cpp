// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include "canonical.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>

namespace fourdgs {
namespace conformance {
namespace {

/// How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
/// pass by getting a prefix right.
constexpr std::size_t kSample = 16;
/// How many camera keyframes appear in full, so a long trajectory cannot bloat a summary.
constexpr std::size_t kCameraKeyframes = 4;
constexpr std::size_t kAudioKeyframes = 4;
constexpr int kFloatDecimals = 6;

/// Six decimals, correctly rounded, then read back — the same value Python's `round(v, 6)`
/// produces, arrived at the same way rather than by a different arithmetic that agrees most
/// of the time.
std::string renderRounded(double value) {
  char buffer[512];
  std::snprintf(buffer, sizeof(buffer), "%.*f", kFloatDecimals, value);
  return std::string(buffer);
}

double roundToDecimals(double value) {
  if (!std::isfinite(value)) return value;
  return std::strtod(renderRounded(value).c_str(), nullptr);
}

/// A comparison key: rounded like the summary, with infinity kept as infinity so the two
/// languages order never-fading gaussians identically, and NaN folded to infinity so they
/// order an undecodable one identically too.
double sortable(double value) {
  if (std::isnan(value)) return std::numeric_limits<double>::infinity();
  if (std::isinf(value)) return value;
  return roundToDecimals(value);
}

std::string escape(const std::string& text) {
  std::string out;
  out.reserve(text.size() + 2);
  for (unsigned char c : text) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

Json floatRow(const Span<const float>& values, std::size_t index, std::size_t width) {
  std::vector<Json> row;
  row.reserve(width);
  for (std::size_t k = 0; k < width; ++k) {
    row.push_back(num(static_cast<double>(values[index * width + k])));
  }
  return Json::array(std::move(row));
}

Json floatRows(const Span<const float>& values, const std::vector<std::size_t>& sample,
               std::size_t width) {
  std::vector<Json> rows;
  rows.reserve(sample.size());
  for (std::size_t i : sample) rows.push_back(floatRow(values, i, width));
  return Json::array(std::move(rows));
}

Json scalarRow(const Span<const float>& values, const std::vector<std::size_t>& sample) {
  std::vector<Json> row;
  row.reserve(sample.size());
  for (std::size_t i : sample) row.push_back(num(static_cast<double>(values[i])));
  return Json::array(std::move(row));
}

Json doubleArray(const double* values, std::size_t count) {
  std::vector<Json> out;
  out.reserve(count);
  for (std::size_t i = 0; i < count; ++i) out.push_back(num(values[i]));
  return Json::array(std::move(out));
}

Json stringMap(const std::map<std::string, std::string>& entries) {
  std::map<std::string, Json> out;
  for (const auto& entry : entries) out.emplace(entry.first, Json::string(entry.second));
  return Json::object(std::move(out));
}

Json cameraJson(const Camera& camera) {
  std::vector<Json> keyframes;
  const std::size_t shown = std::min(camera.keyframes.size(), kCameraKeyframes);
  for (std::size_t i = 0; i < shown; ++i) {
    const Camera::Keyframe& frame = camera.keyframes[i];
    keyframes.push_back(Json::object({
        {"position", doubleArray(frame.position, 3)},
        {"target", doubleArray(frame.target, 3)},
        {"time", num(frame.time)},
    }));
  }
  return Json::object({
      {"fovYDeg", num(camera.fovYDeg)},
      {"interpolation", Json::string(camera.interpolation)},
      {"keyframeCount", integer(static_cast<std::uint64_t>(camera.keyframes.size()))},
      {"keyframes", Json::array(std::move(keyframes))},
      {"loop", Json::boolean(camera.loop)},
      {"position", doubleArray(camera.position, 3)},
      {"target", doubleArray(camera.target, 3)},
  });
}

Json audioSourceJson(const AudioSource& source, double sampleTime) {
  const AudioSourceState state = source.stateAt(sampleTime);
  std::vector<Json> keyframes;
  const std::size_t shown = std::min(source.keyframes.size(), kAudioKeyframes);
  for (std::size_t i = 0; i < shown; ++i) {
    const AudioSource::Keyframe& frame = source.keyframes[i];
    keyframes.push_back(Json::object({
        {"position", doubleArray(frame.position, 3)},
        {"rotation", doubleArray(frame.rotation, 4)},
        {"time", num(frame.time)},
    }));
  }
  return Json::object({
      {"byteLength", integer(static_cast<std::uint64_t>(source.data.size()))},
      {"channelLayout", Json::string(source.channelLayout)},
      {"codec", Json::string(source.codec)},
      {"crc", Json::string(crc32String(source.data.data(), source.data.size()))},
      {"durationSec", num(source.durationSec)},
      {"gain", num(source.gain)},
      {"interpolation", Json::string(source.interpolation)},
      {"keyframeCount", integer(static_cast<std::uint64_t>(source.keyframes.size()))},
      {"keyframes", Json::array(std::move(keyframes))},
      {"loop", Json::boolean(source.loop)},
      {"name", Json::string(source.name)},
      {"position", doubleArray(source.position, 3)},
      {"rotation", doubleArray(source.rotation, 4)},
      {"sourceId", integer(static_cast<std::uint64_t>(source.sourceId))},
      {"spatial", Json::boolean(source.spatial)},
      {"startSec", num(source.startSec)},
      {"stateAtHalf", Json::object({
                          {"active", Json::boolean(state.active)},
                          {"gain", num(state.gain)},
                          {"localTime", num(state.localTime)},
                          {"position", doubleArray(state.position, 3)},
                          {"rotation", doubleArray(state.rotation, 4)},
                      })},
  });
}

/// Degree, width and a checksum of the coefficients in content order.
///
/// A digest rather than the coefficients themselves: degree 2 over 512 gaussians is 12,288
/// bytes, which would swamp the expectation without proving anything the checksum does not.
Json sphericalHarmonics(const GaussianView& gaussians, const std::vector<std::size_t>& order) {
  if (gaussians.shDegree == 0 || gaussians.sh.empty() || gaussians.shCoefficients == 0) {
    return Json::null();
  }
  const std::size_t width = gaussians.shCoefficients * 3;
  std::vector<std::uint8_t> payload;
  payload.reserve(order.size() * width);
  for (std::size_t i : order) {
    for (std::size_t k = 0; k < width; ++k) payload.push_back(gaussians.sh[i * width + k]);
  }
  return Json::object({
      {"coefficients", integer(static_cast<std::uint64_t>(gaussians.shCoefficients))},
      {"crc", Json::string(crc32String(payload.data(), payload.size()))},
      // A plain number, not a string: the degree is 0..3 and the expectations carry it as
      // an int, where a count that could exceed a double's integers is carried as a string.
      {"degree", Json::number(std::to_string(gaussians.shDegree))},
  });
}

}  // namespace

Json Json::null() { return Json(); }

Json Json::boolean(bool value) {
  Json json;
  json.kind_ = Kind::kBool;
  json.bool_ = value;
  return json;
}

Json Json::number(std::string rendered) {
  Json json;
  json.kind_ = Kind::kNumber;
  json.text_ = std::move(rendered);
  return json;
}

Json Json::string(std::string value) {
  Json json;
  json.kind_ = Kind::kString;
  json.text_ = std::move(value);
  return json;
}

Json Json::array(std::vector<Json> items) {
  Json json;
  json.kind_ = Kind::kArray;
  json.array_ = std::move(items);
  return json;
}

Json Json::object(std::map<std::string, Json> members) {
  Json json;
  json.kind_ = Kind::kObject;
  json.object_ = std::move(members);
  return json;
}

Json Json::raw(std::string json) {
  Json value;
  // Rendered as text verbatim, like a pre-formatted number: the core already produced the
  // complete object, and re-parsing it here would only risk a second rounding pass.
  value.kind_ = Kind::kNumber;
  value.text_ = std::move(json);
  return value;
}

std::string Json::render(int indent) const {
  const std::string pad(static_cast<std::size_t>(indent) * 2, ' ');
  const std::string inner(static_cast<std::size_t>(indent + 1) * 2, ' ');
  switch (kind_) {
    case Kind::kNull:
      return "null";
    case Kind::kBool:
      return bool_ ? "true" : "false";
    case Kind::kNumber:
      return text_;
    case Kind::kString:
      return "\"" + escape(text_) + "\"";
    case Kind::kArray: {
      if (array_.empty()) return "[]";
      std::string out = "[\n";
      for (std::size_t i = 0; i < array_.size(); ++i) {
        out += inner + array_[i].render(indent + 1);
        out += (i + 1 < array_.size()) ? ",\n" : "\n";
      }
      return out + pad + "]";
    }
    case Kind::kObject: {
      if (object_.empty()) return "{}";
      std::string out = "{\n";
      std::size_t i = 0;
      for (const auto& member : object_) {
        out += inner + "\"" + escape(member.first) + "\": " + member.second.render(indent + 1);
        out += (++i < object_.size()) ? ",\n" : "\n";
      }
      return out + pad + "}";
    }
  }
  return "null";
}

Json num(double value) {
  if (!std::isfinite(value)) return Json::null();
  return Json::number(renderRounded(value));
}

Json integer(std::uint64_t value) { return Json::string(std::to_string(value)); }

Json integer(std::int64_t value) { return Json::string(std::to_string(value)); }

std::string crc32String(const std::uint8_t* data, std::size_t length) {
  // CRC-32 (IEEE), the polynomial the footer and the expectations both use. Written out
  // rather than linked, because a checksum is fifteen lines and a dependency is forever.
  static std::uint32_t table[256];
  static bool ready = false;
  if (!ready) {
    for (std::uint32_t i = 0; i < 256; ++i) {
      std::uint32_t c = i;
      for (int k = 0; k < 8; ++k) c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      table[i] = c;
    }
    ready = true;
  }
  std::uint32_t crc = 0xFFFFFFFFu;
  for (std::size_t i = 0; i < length; ++i) {
    crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  }
  return std::to_string(crc ^ 0xFFFFFFFFu);
}

std::vector<std::size_t> stableOrder(const GaussianView& gaussians) {
  const std::size_t n = gaussians.count;
  const std::size_t shWidth =
      (gaussians.shDegree == 0 || gaussians.sh.empty()) ? 0 : gaussians.shCoefficients * 3;
  // Membership is part of the key, after the harmonics, exactly as `canonical.py` orders
  // it. It matters where the harmonics do not: two gaussians alike in every attribute but
  // belonging to different objects tie on everything above, and `sample.objectIds` is a
  // value this summary emits — so leaving membership out would let decode order pick which
  // of `["0", "7"]` and `["7", "0"]` this file reports.
  const std::size_t idWidth = gaussians.objectIds.empty() ? 0 : 1;
  const std::size_t width = 3 + 3 + 4 + 4 + 3 + 4 + shWidth + idWidth;

  std::vector<double> keys(n * width);
  for (std::size_t i = 0; i < n; ++i) {
    double* row = keys.data() + i * width;
    std::size_t at = 0;
    for (std::size_t k = 0; k < 3; ++k) row[at++] = sortable(gaussians.positions[i * 3 + k]);
    for (std::size_t k = 0; k < 3; ++k) row[at++] = sortable(gaussians.scales[i * 3 + k]);
    for (std::size_t k = 0; k < 4; ++k) row[at++] = sortable(gaussians.rotations[i * 4 + k]);
    for (std::size_t k = 0; k < 4; ++k) row[at++] = sortable(gaussians.colors[i * 4 + k]);
    for (std::size_t k = 0; k < 3; ++k) row[at++] = sortable(gaussians.motions[i * 3 + k]);
    row[at++] = sortable(gaussians.muT[i]);
    row[at++] = sortable(gaussians.sigmaT[i]);
    row[at++] = sortable(gaussians.winLo[i]);
    row[at++] = sortable(gaussians.winHi[i]);
    for (std::size_t k = 0; k < shWidth; ++k) {
      row[at++] = static_cast<double>(gaussians.sh[i * shWidth + k]);
    }
    if (idWidth != 0) row[at++] = static_cast<double>(gaussians.objectIds[i]);
  }

  std::vector<std::size_t> order(n);
  for (std::size_t i = 0; i < n; ++i) order[i] = i;
  // Stable, so that two gaussians identical in every value the summary emits keep the order
  // they arrived in — which cannot change any number here, and makes the sort reproducible.
  std::stable_sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
    const double* rowA = keys.data() + a * width;
    const double* rowB = keys.data() + b * width;
    for (std::size_t k = 0; k < width; ++k) {
      if (rowA[k] < rowB[k]) return true;
      if (rowB[k] < rowA[k]) return false;
    }
    return false;
  });
  return order;
}

std::string canonical(const SceneSummary& summary) {
  const Header& header = *summary.header;
  const GaussianView& gaussians = *summary.gaussians;

  const std::vector<std::size_t> order = stableOrder(gaussians);
  const std::vector<std::size_t> sample(order.begin(),
                                        order.begin() + std::min(kSample, order.size()));

  double positionSum[3] = {0.0, 0.0, 0.0};
  double opacitySum = 0.0;
  std::uint64_t neverFades = 0;
  std::uint64_t zeroMotion = 0;
  for (std::size_t i : order) {
    for (std::size_t k = 0; k < 3; ++k) {
      positionSum[k] += static_cast<double>(gaussians.positions[i * 3 + k]);
    }
    opacitySum += static_cast<double>(gaussians.colors[i * 4 + 3]);
    if (!std::isfinite(static_cast<double>(gaussians.sigmaT[i]))) ++neverFades;
    const double motion = std::fabs(static_cast<double>(gaussians.motions[i * 3 + 0])) +
                          std::fabs(static_cast<double>(gaussians.motions[i * 3 + 1])) +
                          std::fabs(static_cast<double>(gaussians.motions[i * 3 + 2]));
    if (motion == 0.0) ++zeroMotion;
  }

  std::vector<Json> intervals;
  intervals.reserve(summary.chunkIntervals.size());
  for (const auto& interval : summary.chunkIntervals) {
    intervals.push_back(Json::array({num(interval.first), num(interval.second)}));
  }

  std::vector<Json> metadata;
  for (const MetadataRecord& record : summary.metadata) {
    metadata.push_back(Json::object({
        {"entries", stringMap(record.entries)},
        {"name", Json::string(record.name)},
    }));
  }

  std::vector<Json> attachments;
  for (const Attachment& attachment : summary.attachments) {
    attachments.push_back(Json::object({
        {"byteLength", integer(static_cast<std::uint64_t>(attachment.data.size()))},
        {"crc", Json::string(crc32String(attachment.data.data(), attachment.data.size()))},
        {"mediaType", Json::string(attachment.mediaType)},
        {"name", Json::string(attachment.name)},
    }));
  }

  std::vector<Json> summaryOffsets;
  for (const SummaryOffset& offset : summary.summaryOffsets) {
    summaryOffsets.push_back(Json::object({
        {"groupLength", integer(offset.groupLength)},
        {"groupOpcode", integer(static_cast<std::uint64_t>(offset.groupOpcode))},
        {"groupStart", integer(offset.groupStart)},
    }));
  }

  std::vector<AudioSource> orderedAudio = summary.audioSources;
  std::sort(orderedAudio.begin(), orderedAudio.end(),
            [](const AudioSource& a, const AudioSource& b) { return a.sourceId < b.sourceId; });
  std::vector<Json> audioSources;
  audioSources.reserve(orderedAudio.size());
  for (const AudioSource& source : orderedAudio) {
    audioSources.push_back(audioSourceJson(source, header.durationSec / 2.0));
  }

  Json statistics = Json::null();
  if (summary.statistics != nullptr) {
    statistics = Json::object({
        {"aabb", doubleArray(summary.statistics->aabb, 6)},
        {"chunkCount", integer(static_cast<std::uint64_t>(summary.statistics->chunkCount))},
        {"durationSec", num(summary.statistics->durationSec)},
        {"gaussianCount", integer(summary.statistics->gaussianCount)},
    });
  }

  std::map<std::string, Json> sampleFields{
      {"colors", floatRows(gaussians.colors, sample, 4)},
      {"motions", floatRows(gaussians.motions, sample, 3)},
      {"muT", scalarRow(gaussians.muT, sample)},
      {"positions", floatRows(gaussians.positions, sample, 3)},
      {"rotations", floatRows(gaussians.rotations, sample, 4)},
      {"scales", floatRows(gaussians.scales, sample, 3)},
      {"sigmaT", scalarRow(gaussians.sigmaT, sample)},
      {"winHi", scalarRow(gaussians.winHi, sample)},
      {"winLo", scalarRow(gaussians.winLo, sample)},
  };
  // Membership is an exact label, so it is rendered as an integer string like the counts
  // are — never as a float. The key is omitted when the scene carries no `object_id`
  // stream at all, which is a different file from one where every gaussian is background.
  if (!gaussians.objectIds.empty()) {
    std::vector<Json> ids;
    ids.reserve(sample.size());
    for (const std::size_t row : sample) {
      ids.push_back(Json::string(std::to_string(gaussians.objectIds[row])));
    }
    sampleFields.emplace("objectIds", Json::array(std::move(ids)));
  }
  Json sampleMembers = Json::object(std::move(sampleFields));

  std::map<std::string, Json> rootMembers = {
      {"aggregate", Json::object({
                        {"neverFadesCount", integer(neverFades)},
                        {"opacitySum", num(opacitySum)},
                        {"positionSum", doubleArray(positionSum, 3)},
                        {"zeroMotionCount", integer(zeroMotion)},
                    })},
      {"attachments", Json::array(std::move(attachments))},
      {"audioSources", Json::array(std::move(audioSources))},
      {"camera", summary.camera == nullptr ? Json::null() : cameraJson(*summary.camera)},
      {"chunkIntervals", Json::array(std::move(intervals))},
      {"cutoff", num(header.cutoff)},
      {"durationSec", num(header.durationSec)},
      {"gaussianCount", integer(static_cast<std::uint64_t>(gaussians.count))},
      {"hasAudio", Json::boolean(header.hasAudio)},
      {"headerAttributes", stringMap(header.attributes)},
      // The Header's first two fields: read into this summary's struct since the binding
      // existed, emitted by nothing until now. Keys stay alphabetical.
      {"library", Json::string(header.library)},
      {"metadataRecords", Json::array(std::move(metadata))},
      {"profile", Json::string(header.profile)},
      {"sample", std::move(sampleMembers)},
      {"sh", sphericalHarmonics(gaussians, order)},
      {"shDegree", Json::number(std::to_string(header.shDegree))},
      {"statistics", std::move(statistics)},
      {"summaryCrcOk",
       summary.summaryCrcOk == nullptr ? Json::null() : Json::boolean(*summary.summaryCrcOk)},
      {"summaryOffsets", Json::array(std::move(summaryOffsets))},
      {"temporalModel", Json::string(header.temporalModel)},
  };

  // Omitted entirely when the file carries no provenance — not the `audioSources`
  // convention. A file without provenance is a file the record family does not apply to.
  if (!summary.provenanceJson.empty()) {
    rootMembers.emplace("provenance", Json::raw(summary.provenanceJson));
  }

  // The object layer adds two root keys beside the rest, on the same omit-when-absent
  // rule: a file with neither object records nor membership reads exactly as it did
  // before the layer existed.
  if (!summary.objectsJson.empty()) {
    rootMembers.emplace("objects", Json::raw(summary.objectsJson));
  }
  if (!summary.objectStatesJson.empty()) {
    rootMembers.emplace("states", Json::raw(summary.objectStatesJson));
  }

  return Json::object(std::move(rootMembers)).render();
}

}  // namespace conformance
}  // namespace fourdgs
