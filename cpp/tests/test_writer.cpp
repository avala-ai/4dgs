// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The encode surface, at the edge of the C ABI.
///
/// Two builds exist. Without a core, `encodeScene` refuses with `kNotImplemented` and a
/// sentence naming the fix, exactly as the decode side does. With one, a tiny scene built by
/// hand encodes to bytes that reopen as a real 4dgs file and decode back to what went in —
/// including a never-fading gaussian's infinite sigma, which is a value the writer must carry
/// rather than a sentinel it may drop.

#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

#include "check.hpp"
#include "fourdgs/fourdgs.hpp"

namespace {

using fourdgs::ErrorCode;
using fourdgs::GaussianData;
using fourdgs::GaussianView;
using fourdgs::Result;
using fourdgs::Scene;
using fourdgs::WriteOptions;

GaussianData tinyScene() {
  GaussianData data;
  data.resize(3, 0, 0);
  data.positions = {0.0f, 0.0f, 0.0f, 1.0f, 0.5f, -0.5f, -1.0f, 2.0f, 0.25f};
  data.scales = {0.1f, 0.1f, 0.1f, 0.2f, 0.15f, 0.1f, 0.05f, 0.05f, 0.05f};
  data.rotations = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
  data.colors = {0.9f, 0.1f, 0.1f, 1.0f, 0.1f, 0.9f, 0.1f, 0.8f, 0.1f, 0.1f, 0.9f, 0.5f};
  data.motions = {0, 0, 0, 0.1f, 0, 0, 0, -0.1f, 0};
  data.muT = {0.5f, 1.0f, 1.5f};
  // The middle gaussian never fades: its sigma is +inf, and it must survive as +inf.
  data.sigmaT = {0.3f, std::numeric_limits<float>::infinity(), 0.4f};
  data.winLo = {0.0f, 0.0f, 0.0f};
  data.winHi = {2.0f, 2.0f, 2.0f};
  return data;
}

void encodeRefusesWithoutACore() {
  const GaussianData data = tinyScene();
  Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeScene(GaussianView(data), 2.0);
  CHECK(!encoded.ok());
  CHECK_EQ(encoded.error().code, ErrorCode::kNotImplemented);
  CHECK(encoded.error().message.find("cargo build") != std::string::npos);
}

void encodeRoundTrips() {
  const GaussianData data = tinyScene();
  WriteOptions options;
  options.maxDepth = 4;
  options.minChunkGaussians = 1;
  options.profile = "test";

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeScene(GaussianView(data), 2.0, options);
  CHECK(encoded.ok());
  if (!encoded.ok()) return;

  Result<std::unique_ptr<Scene>> reopened =
      Scene::openMemory(fourdgs::Span<const std::uint8_t>(encoded->data(), encoded->size()));
  CHECK(reopened.ok());
  if (!reopened.ok()) return;
  Scene& scene = **reopened;

  CHECK_EQ(scene.gaussianCount(), static_cast<std::uint64_t>(3));
  CHECK_EQ(scene.durationSec(), 2.0);
  CHECK(scene.profile() == "test");
  CHECK(scene.temporalModel() == "gaussian-birth");

  Result<void> loaded = scene.loadAll(3);
  CHECK(loaded.ok());
  if (!loaded.ok()) return;
  const GaussianView back = scene.gaussians();
  CHECK_EQ(back.count, static_cast<std::size_t>(3));

  int infinities = 0;
  for (std::size_t i = 0; i < back.count; ++i) {
    if (std::isinf(back.sigmaT[i])) ++infinities;
    CHECK(!std::isnan(back.sigmaT[i]));
  }
  CHECK_EQ(infinities, 1);
}

// --------------------------------------------------------------------------
// keyframe-delta (spec §11)
// --------------------------------------------------------------------------

using fourdgs::KeyframeDeltaOptions;
using fourdgs::KeyframeDeltaSample;

/// One population of `ids.size()` gaussians, moved along +x by `step` per sample.
///
/// Everything else is held constant so that a delta's update group is exactly the lanes that
/// moved. `sigmaT`, the flags derived from it and the validity window are the same for every
/// gaussian in every sample on purpose: they are GOP-invariant (§11.5), and a fixture that
/// changed one would be testing the refusal rather than the encode.
GaussianData movingPopulation(const std::vector<std::uint32_t>& ids, float step) {
  GaussianData data;
  data.resize(ids.size(), 0, 0);
  for (std::size_t i = 0; i < ids.size(); ++i) {
    const float base = static_cast<float>(ids[i]);
    data.positions[i * 3 + 0] = base * 0.25f + step;
    data.positions[i * 3 + 1] = base * 0.5f;
    data.positions[i * 3 + 2] = -base * 0.125f;
    data.scales[i * 3 + 0] = 0.05f;
    data.scales[i * 3 + 1] = 0.05f;
    data.scales[i * 3 + 2] = 0.05f;
    data.rotations[i * 4 + 3] = 1.0f;
    data.colors[i * 4 + 0] = 0.5f;
    data.colors[i * 4 + 1] = 0.25f;
    data.colors[i * 4 + 2] = 0.75f;
    data.colors[i * 4 + 3] = 0.9f;
    data.motions[i * 3 + 0] = 0.1f;
    data.muT[i] = 0.0f;
    data.sigmaT[i] = 0.5f;
    data.winLo[i] = 0.0f;
    data.winHi[i] = 1.0f;
  }
  return data;
}

/// Three samples over `[0, 1)`: a steady population that moves, then loses id 0 and gains 4.
struct Sequence {
  std::vector<std::vector<std::uint32_t>> ids;
  std::vector<GaussianData> populations;
  std::vector<KeyframeDeltaSample> samples;
};

Sequence threeSamples() {
  Sequence sequence;
  sequence.ids = {{0, 1, 2, 3}, {0, 1, 2, 3}, {1, 2, 3, 4}};
  for (std::size_t i = 0; i < sequence.ids.size(); ++i) {
    sequence.populations.push_back(movingPopulation(sequence.ids[i], 0.1f * static_cast<float>(i)));
  }
  // Built after every population is in place: `GaussianView` borrows, so a view taken from a
  // vector that later reallocates would dangle.
  for (std::size_t i = 0; i < sequence.ids.size(); ++i) {
    KeyframeDeltaSample sample;
    sample.t0 = static_cast<double>(i) / 3.0;
    sample.ids = fourdgs::Span<const std::uint32_t>(sequence.ids[i].data(), sequence.ids[i].size());
    sample.gaussians = GaussianView(sequence.populations[i]);
    sequence.samples.push_back(sample);
  }
  return sequence;
}

fourdgs::Span<const KeyframeDeltaSample> spanOf(const Sequence& sequence) {
  return fourdgs::Span<const KeyframeDeltaSample>(sequence.samples.data(), sequence.samples.size());
}

/// The `states` member of a canonical summary — the reconstruction, without the chunk rows.
///
/// Substring rather than a parse, because the tests carry no JSON reader and the member is
/// the last one before `temporalModel` in the canonical (sorted-key) order. Empty when it is
/// not there, which callers assert against so a silent miss is not mistaken for agreement.
std::string statesMember(const std::string& summary) {
  const std::size_t start = summary.find("\"states\":");
  if (start == std::string::npos) return std::string();
  const std::size_t end = summary.find(",\"temporalModel\"", start);
  if (end == std::string::npos) return std::string();
  return summary.substr(start, end - start);
}

void keyframeDeltaRefusesWithoutACore() {
  const Sequence sequence = threeSamples();
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
  CHECK(!encoded.ok());
  CHECK_EQ(encoded.error().code, ErrorCode::kNotImplemented);
  CHECK(encoded.error().message.find("cargo build") != std::string::npos);
}

/// The written file reads back through this package's own keyframe-delta reader, on both read
/// paths, and the two agree — which is what proves the index the writer emitted describes the
/// chunks it wrote rather than merely being present.
void keyframeDeltaRoundTrips() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions options;
  options.keyframeEvery = 2;
  options.deltaMode = fourdgs::kDeltaModeChained;

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(encoded.ok());
  if (!encoded.ok()) return;
  const fourdgs::Span<const std::uint8_t> bytes(encoded->data(), encoded->size());

  Result<std::string> model = fourdgs::peekTemporalModel(bytes);
  CHECK(model.ok());
  if (model.ok()) CHECK(*model == "keyframe-delta");

  // The scene reader refuses the model rather than half-reading it, which is the behaviour
  // the whole byte-in/string-out surface exists around.
  Result<std::unique_ptr<Scene>> opened = Scene::openMemory(bytes);
  CHECK(!opened.ok());

  Result<std::string> streamed = fourdgs::keyframeDeltaStatesJson(bytes, false);
  Result<std::string> indexed = fourdgs::keyframeDeltaStatesJson(bytes, true);
  CHECK(streamed.ok());
  CHECK(indexed.ok());
  if (!streamed.ok() || !indexed.ok()) return;
  CHECK(*streamed == *indexed);
  // Five distinct ids over the sequence — 0 dies and 4 is born, so no instant holds more than
  // four — and the Header counts ids rather than operations (§11.2). A binding that dropped
  // the id stream, or renumbered it by row, cannot produce this.
  CHECK(streamed->find("\"gaussianCount\":\"5\"") != std::string::npos);
  CHECK(streamed->find("\"gaussianIds\":[\"1\",\"2\",\"3\",\"4\"]") != std::string::npos);

  // Two encodes of one sequence are the same bytes. An encoder that iterated a map would
  // pass every value-based check above and still produce a build nobody can reproduce.
  Result<std::vector<std::uint8_t>> again =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(again.ok());
  if (again.ok()) CHECK(*again == *encoded);
}

/// Cadence one is the shape §11.11 says subsumes `frame-sequence`: every chunk a keyframe.
/// It has to be reachable through the binding, because it is the only legal way to write a
/// sequence whose steps have no correspondence.
void cadenceOneWritesOnlyKeyframes() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions options;
  options.keyframeEvery = 1;

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(encoded.ok());
  if (!encoded.ok()) return;
  Result<std::string> states = fourdgs::keyframeDeltaStatesJson(
      fourdgs::Span<const std::uint8_t>(encoded->data(), encoded->size()), false);
  CHECK(states.ok());
  if (states.ok()) CHECK(states->find("\"kind\":\"delta\"") == std::string::npos);
}

/// The mode reaches the core rather than being dropped on the way. Keyframe-referenced deltas
/// produce a different file from chained ones on the same samples (§11.4), so two encodes that
/// came back equal would mean the flag never arrived.
void bothDeltaModesReachTheCore() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions chained;
  chained.keyframeEvery = 8;
  chained.deltaMode = fourdgs::kDeltaModeChained;
  KeyframeDeltaOptions referenced = chained;
  referenced.deltaMode = fourdgs::kDeltaModeKeyframe;

  Result<std::vector<std::uint8_t>> a =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, chained);
  Result<std::vector<std::uint8_t>> b =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, referenced);
  CHECK(a.ok());
  CHECK(b.ok());
  if (!a.ok() || !b.ok()) return;
  CHECK(*a != *b);

  Result<std::string> fromChained = fourdgs::keyframeDeltaStatesJson(
      fourdgs::Span<const std::uint8_t>(a->data(), a->size()), false);
  Result<std::string> fromReferenced = fourdgs::keyframeDeltaStatesJson(
      fourdgs::Span<const std::uint8_t>(b->data(), b->size()), false);
  CHECK(fromChained.ok());
  CHECK(fromReferenced.ok());
  if (!fromChained.ok() || !fromReferenced.ok()) return;

  // The chunk rows differ, and must: `deltaMode` names the mode and `depth` counts the
  // records a reader composes, which is where the two modes are not the same file. The
  // reconstructed populations do not differ, because the reference a delta names is an
  // encoder's cost decision and never a change in what the file means (§11.4) — deltas at
  // any depth telescope over integers to exactly the same bins (§11.7).
  CHECK(fromChained->find("\"deltaMode\":\"chained\"") != std::string::npos);
  CHECK(fromReferenced->find("\"deltaMode\":\"keyframe\"") != std::string::npos);
  CHECK(statesMember(*fromChained) == statesMember(*fromReferenced));
  CHECK(!statesMember(*fromChained).empty());
}

/// A gaussian whose `sigma_t` changes inside a group is refused, not written.
///
/// This is §11.5, and it is the rule that makes a delta a difference of bins: `sigma_t`
/// derives the per-gaussian velocity and birth-time grids, so a chunk that changed it would
/// make the next delta a difference between bins on two different grids — a number that
/// decodes silently into a wrong velocity. The producer's options are a keyframe, or a death
/// and a birth; neither is silent, and neither is this.
void aChangedInvariantIsRefused() {
  Sequence sequence = threeSamples();
  sequence.populations[1].sigmaT[0] = 0.9f;
  sequence.samples[1].gaussians = GaussianView(sequence.populations[1]);

  KeyframeDeltaOptions options;
  options.keyframeEvery = 8;
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("gaussian id 0") != std::string::npos);
}

/// Identity is one id per gaussian (§11.2). The ABI takes a single count for both, so a
/// mismatch is invisible to it and is caught here, where both lengths are still in hand.
void aMismatchedIdStreamIsRefused() {
  Sequence sequence = threeSamples();
  sequence.samples[0].ids = fourdgs::Span<const std::uint32_t>(sequence.ids[0].data(), 3);

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("gaussian_id") != std::string::npos);
}

void invalidDurationsAreRefused() {
  const double invalid[] = {0.0, -1.0, std::numeric_limits<double>::infinity(),
                            -std::numeric_limits<double>::infinity(),
                            std::numeric_limits<double>::quiet_NaN()};
  for (double duration : invalid) {
    const Sequence sequence = threeSamples();
    Result<std::vector<std::uint8_t>> encoded =
        fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), duration);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    CHECK(encoded.error().message.find("finite and positive") != std::string::npos);
  }
}

void anEmptySequenceIsRefused() {
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(fourdgs::Span<const KeyframeDeltaSample>(), 1.0);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("at least one sample") != std::string::npos);
}

void aNonFiniteSampleInstantIsRefused() {
  const double invalid[] = {std::numeric_limits<double>::infinity(),
                            -std::numeric_limits<double>::infinity(),
                            std::numeric_limits<double>::quiet_NaN()};
  for (double instant : invalid) {
    Sequence sequence = threeSamples();
    sequence.samples[1].t0 = instant;
    Result<std::vector<std::uint8_t>> encoded =
        fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    CHECK(encoded.error().message.find("sample 1") != std::string::npos);
    CHECK(encoded.error().message.find("non-finite") != std::string::npos);
  }
}

void aSequenceThatDoesNotStartAtZeroIsRefused() {
  Sequence sequence = threeSamples();
  sequence.samples[0].t0 = 0.1;
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("first sample") != std::string::npos);
  CHECK(encoded.error().message.find("not 0") != std::string::npos);
}

void sampleInstantsMustStrictlyIncrease() {
  const double invalid[] = {0.0, -0.1};
  for (double instant : invalid) {
    Sequence sequence = threeSamples();
    sequence.samples[1].t0 = instant;
    Result<std::vector<std::uint8_t>> encoded =
        fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    CHECK(encoded.error().message.find("strictly increasing") != std::string::npos);
  }
}

void theLastSampleMustStartBeforeDuration() {
  const double invalid[] = {1.0, 1.1};
  for (double instant : invalid) {
    Sequence sequence = threeSamples();
    sequence.samples[2].t0 = instant;
    Result<std::vector<std::uint8_t>> encoded =
        fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    CHECK(encoded.error().message.find("last sample") != std::string::npos);
    CHECK(encoded.error().message.find("not before duration_sec") != std::string::npos);
  }
}

void duplicateIdsWithinASampleAreRefused() {
  Sequence sequence = threeSamples();
  sequence.ids[1][3] = 1;

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("sample 1") != std::string::npos);
  CHECK(encoded.error().message.find("gaussian id 1") != std::string::npos);
  CHECK(encoded.error().message.find("more than once") != std::string::npos);
}

/// An identity is never reused within one sequence (§11.2): once absent from a sample, it is
/// dead. The ordinary round-trip fixture above is the positive control — ids 1, 2 and 3 stay
/// continuously live while id 4 is a genuine new birth. Here id 0 instead skips sample 1 and
/// reappears in sample 2, which is a new row trying to claim a dead gaussian's identity.
void anIdThatReappearsAfterDeathIsRefused() {
  Sequence sequence = threeSamples();
  sequence.ids[1][0] = 4;
  sequence.ids[2][3] = 0;

  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
  CHECK(encoded.error().message.find("sample 2") != std::string::npos);
  CHECK(encoded.error().message.find("gaussian id 0") != std::string::npos);
  CHECK(encoded.error().message.find("after it died") != std::string::npos);
}

/// The nine columns the ABI reads, with the floats each holds per gaussian.
struct Column {
  fourdgs::Span<const float> GaussianView::* member;
  const char* name;
  std::size_t width;
};

const Column kColumns[] = {
    {&GaussianView::positions, "positions", 3}, {&GaussianView::scales, "scales", 3},
    {&GaussianView::rotations, "rotations", 4}, {&GaussianView::colors, "colors", 4},
    {&GaussianView::motions, "motions", 3},     {&GaussianView::muT, "mu_t", 1},
    {&GaussianView::sigmaT, "sigma_t", 1},      {&GaussianView::winLo, "win_lo", 1},
    {&GaussianView::winHi, "win_hi", 1},
};

/// Copy a column into an exactly-sized allocation one gaussian short of what `count` claims.
///
/// Exactly sized on purpose: a span merely shortened over a buffer that is still long enough
/// would hide the bug from a sanitizer. This is a real heap block that ends where the span
/// says it does, so a binding that forwarded `count` reads past it and ASAN says so.
std::vector<float> oneGaussianShort(const GaussianView& view, const Column& column) {
  const fourdgs::Span<const float> full = view.*column.member;
  return std::vector<float>(full.data(), full.data() + (view.count - 1) * column.width);
}

/// A view whose columns are shorter than its `count` is refused rather than read past.
///
/// `GaussianView::count` is an independent field: nothing in the type derives it from the
/// spans beside it, so `count = 4` over a six-float `positions` is a value an ordinary caller
/// can construct without writing `unsafe` anywhere. The ABI takes the count and a bare
/// pointer per column and reads `count × width` floats from each, so forwarding one is a heap
/// read out of bounds — AGENTS.md §1, an allocation sized from a value nobody validated. The
/// id-stream check above does not catch it: the ids can be exactly as long as `count` says
/// while a column is not.
void aRaggedSampleIsRefused() {
  // One column truncated at a time, so every one of the nine is proved checked rather than
  // the first standing in for the rest.
  for (const Column& column : kColumns) {
    Sequence sequence = threeSamples();
    GaussianView ragged(sequence.populations[1]);
    const std::vector<float> truncated = oneGaussianShort(ragged, column);
    ragged.*column.member = fourdgs::Span<const float>(truncated.data(), truncated.size());
    sequence.samples[1].gaussians = ragged;

    Result<std::vector<std::uint8_t>> encoded =
        fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    // The message names the sample and the column, because "invalid argument" over nine
    // columns and three samples is not a diagnosis (AGENTS.md §6).
    CHECK(encoded.error().message.find("sample 1") != std::string::npos);
    CHECK(encoded.error().message.find(column.name) != std::string::npos);
  }
}

/// The same defect on the older entry point. `encodeScene` reads the same nine columns off
/// the same public view through the same kind of ABI call, so a ragged view is the same
/// out-of-bounds read there; it is checked in one place and both paths use it.
void aRaggedSceneIsRefused() {
  for (const Column& column : kColumns) {
    const GaussianData data = tinyScene();
    GaussianView ragged(data);
    const std::vector<float> truncated = oneGaussianShort(ragged, column);
    ragged.*column.member = fourdgs::Span<const float>(truncated.data(), truncated.size());

    Result<std::vector<std::uint8_t>> encoded = fourdgs::encodeScene(ragged, 2.0);
    CHECK(!encoded.ok());
    if (encoded.ok()) continue;
    CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
    CHECK(encoded.error().message.find(column.name) != std::string::npos);
  }
}

/// `cutoff`, `codec` and `level` are forwarded, not merely stored.
///
/// The three are the options whose default this struct restates from the core's, so nothing
/// in the suite noticed when the value went nowhere: the conformance runner asks for the
/// defaults, the core applies the same defaults on its own, and the file is identical either
/// way. Deleting any one of the three forwarding calls left the whole C++ suite green. So
/// each is set to something that is not the default and the file has to change — which is
/// the weakest claim that cannot be satisfied by an option that was dropped on the floor.
void compressionAndCutoffReachTheCore() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions defaults;
  Result<std::vector<std::uint8_t>> base =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, defaults);
  CHECK(base.ok());
  if (!base.ok()) return;

  // `cutoff` is the Header's visibility threshold and the divisor the per-gaussian velocity
  // grid is derived through (§6.3), so a file written at another one is a different file.
  KeyframeDeltaOptions coarserCutoff = defaults;
  coarserCutoff.cutoff = 0.4;
  Result<std::vector<std::uint8_t>> other =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, coarserCutoff);
  CHECK(other.ok());
  if (other.ok()) CHECK(*other != *base);

  // The level changes what the deflate coder emits for the same input, so the bytes move
  // while everything they decode to stays put.
  KeyframeDeltaOptions fastest = defaults;
  fastest.level = 1;
  Result<std::vector<std::uint8_t>> cheap =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, fastest);
  CHECK(cheap.ok());
  if (cheap.ok()) CHECK(*cheap != *base);

  // A second codec either writes a different stream or is refused as unimplemented in this
  // build — both prove the value arrived, and which one it is belongs to the core's cargo
  // features rather than to this binding. `kUnsupported` is the legal-but-unbuilt half of
  // the split `result.hpp` draws, so it is checked by name and not merely by "not ok".
  KeyframeDeltaOptions zstd = defaults;
  zstd.codec = 1;
  Result<std::vector<std::uint8_t>> compressed =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, zstd);
  if (compressed.ok()) {
    CHECK(*compressed != *base);
  } else {
    CHECK_EQ(compressed.error().code, ErrorCode::kUnsupported);
  }
}

/// A mode the format does not define never reaches a record. §5.18 gives `delta_mode` two
/// values, and a third would be written into a field every reader dispatches on.
void anUndefinedDeltaModeIsRefused() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions options;
  options.deltaMode = 7;
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
}

/// An unknown profile names no grid, so it cannot be carried through as free-form text the
/// way the Header's own `profile` is.
void anUnknownProfileIsRefused() {
  const Sequence sequence = threeSamples();
  KeyframeDeltaOptions options;
  options.profile = "extremely-fine";
  Result<std::vector<std::uint8_t>> encoded =
      fourdgs::encodeKeyframeDeltaSequence(spanOf(sequence), 1.0, options);
  CHECK(!encoded.ok());
  if (encoded.ok()) return;
  CHECK_EQ(encoded.error().code, ErrorCode::kInvalidArgument);
}

void runTests() {
  if (fourdgs::backendAvailable()) {
    encodeRoundTrips();
    keyframeDeltaRoundTrips();
    cadenceOneWritesOnlyKeyframes();
    bothDeltaModesReachTheCore();
    aChangedInvariantIsRefused();
    aMismatchedIdStreamIsRefused();
    invalidDurationsAreRefused();
    anEmptySequenceIsRefused();
    aNonFiniteSampleInstantIsRefused();
    aSequenceThatDoesNotStartAtZeroIsRefused();
    sampleInstantsMustStrictlyIncrease();
    theLastSampleMustStartBeforeDuration();
    duplicateIdsWithinASampleAreRefused();
    anIdThatReappearsAfterDeathIsRefused();
    aRaggedSampleIsRefused();
    aRaggedSceneIsRefused();
    compressionAndCutoffReachTheCore();
    anUndefinedDeltaModeIsRefused();
    anUnknownProfileIsRefused();
  } else {
    encodeRefusesWithoutACore();
    keyframeDeltaRefusesWithoutACore();
  }
}

}  // namespace

TEST_MAIN
