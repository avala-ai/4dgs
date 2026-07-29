// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_CONFORMANCE_SCENE_SUMMARY_HPP
#define FOURDGS_CONFORMANCE_SCENE_SUMMARY_HPP

#include <string>
#include <vector>

#include "canonical.hpp"
#include "fourdgs/fourdgs.hpp"

namespace fourdgs {
namespace conformance {

/// The parts of a summary that outlive the call that built them.
///
/// `SceneSummary` holds pointers, so the records it points at have to live somewhere; this
/// is that somewhere, and it exists so the two runners fill the file's non-gaussian half
/// exactly once and identically. A record summarized differently by two runners of the same
/// implementation would be a disagreement this suite cannot see.
struct SceneRecords {
  Header header;
  std::vector<MetadataRecord> metadata;
  std::vector<Attachment> attachments;
  std::vector<SummaryOffset> summaryOffsets;
  Camera camera;
  Statistics statistics;
  AudioTrack audio;
  bool hasCamera = false;
  bool hasStatistics = false;
  bool crcKnown = false;
  bool crcOk = false;
  std::vector<std::pair<double, double>> chunkIntervals;
};

/// Read everything the summary reports beyond the gaussians.
inline Result<void> collectRecords(Scene& scene, SceneRecords* out) {
  out->header.durationSec = scene.durationSec();
  out->header.cutoff = scene.cutoff();
  out->header.gaussianCount = scene.gaussianCount();
  out->header.shDegree = scene.shDegree();
  out->header.hasAudio = scene.hasAudio();
  out->header.temporalModel = scene.temporalModel();
  out->header.profile = scene.profile();
  out->header.library = scene.library();
  out->header.attributes = scene.attributes();

  Result<AudioTrack> audio = scene.readAudioTrack();
  if (!audio) return audio.error();
  out->audio = *audio;

  Result<std::vector<MetadataRecord>> metadata = scene.metadata();
  if (!metadata) return metadata.error();
  out->metadata = *metadata;

  Result<std::vector<Attachment>> attachments = scene.attachments();
  if (!attachments) return attachments.error();
  out->attachments = *attachments;

  out->hasCamera = scene.hasCamera();
  if (out->hasCamera) {
    Result<Camera> camera = scene.camera();
    if (!camera) return camera.error();
    out->camera = *camera;
  }

  out->hasStatistics = scene.hasStatistics();
  if (out->hasStatistics) {
    Result<Statistics> statistics = scene.statistics();
    if (!statistics) return statistics.error();
    out->statistics = *statistics;
  }

  out->summaryOffsets = scene.summaryOffsets();

  // Three states collapse to two here only because the expectation has two and a null: not
  // checked is null, and the other two are the boolean.
  const Scene::CrcState crc = scene.summaryCrcState();
  out->crcKnown = crc != Scene::CrcState::kNotChecked;
  out->crcOk = crc == Scene::CrcState::kVerified;

  for (std::uint32_t i = 0; i < scene.chunkCount(); ++i) {
    Result<std::pair<double, double>> interval = scene.chunkInterval(i);
    if (!interval) return interval.error();
    out->chunkIntervals.push_back(*interval);
  }
  return Result<void>();
}

/// Point a summary at the records collected above.
inline SceneSummary summaryOf(const SceneRecords& records, const GaussianView& gaussians) {
  SceneSummary summary;
  summary.header = &records.header;
  summary.gaussians = &gaussians;
  summary.audio = records.header.hasAudio ? &records.audio : nullptr;
  summary.chunkIntervals = records.chunkIntervals;
  summary.camera = records.hasCamera ? &records.camera : nullptr;
  summary.metadata = records.metadata;
  summary.attachments = records.attachments;
  summary.statistics = records.hasStatistics ? &records.statistics : nullptr;
  summary.summaryOffsets = records.summaryOffsets;
  summary.summaryCrcOk = records.crcKnown ? &records.crcOk : nullptr;
  return summary;
}

}  // namespace conformance
}  // namespace fourdgs

#endif  // FOURDGS_CONFORMANCE_SCENE_SUMMARY_HPP
