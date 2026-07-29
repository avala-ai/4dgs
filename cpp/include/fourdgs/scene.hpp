// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_SCENE_HPP
#define FOURDGS_SCENE_HPP

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "fourdgs/model.hpp"
#include "fourdgs/readable.hpp"
#include "fourdgs/result.hpp"

namespace fourdgs {

namespace detail {
class Handle;
class StateHandle;
}  // namespace detail

/// The gaussians that exist at one instant, owned by the caller.
///
/// `indices()` refer to the scene's resident arrays — which the call that produced this
/// state has just populated — so a state and those arrays are read together, before the
/// next load.
class State {
 public:
  ~State();
  State(State&&) noexcept;
  State& operator=(State&&) noexcept;
  State(const State&) = delete;
  State& operator=(const State&) = delete;

  std::size_t count() const;
  /// One index into the scene's resident arrays per visible gaussian.
  Span<const std::uint32_t> indices() const;
  /// `position + motion × (t − mu_t)`, 3 floats each, packed by visible index.
  Span<const float> centers() const;
  /// `color.a × marginal`, one float each, packed by visible index.
  Span<const float> opacity() const;

 private:
  friend class Scene;
  explicit State(std::unique_ptr<detail::StateHandle> handle);
  std::unique_ptr<detail::StateHandle> handle_;
};

/// Which read path to open on.
///
/// `kAuto` is the convenient answer and the wrong one when you are proving a path: two
/// readers that both take whatever `kAuto` picked exercise one path twice, and the reason
/// there are two is that they may differ in everything except what they decode a file to
/// mean.
enum class ReadMode {
  kAuto = 0,
  /// Front to back, whatever the file carries. Truncation recovery lives here.
  kSequential = 1,
  /// The indexed path. A file with no index still opens; it simply has nothing to seek to.
  kIndexed = 2,
};

/// An open `.4dgs` scene.
///
/// A scene has a working set — the gaussians currently decoded. `loadAll()` fills it with
/// every chunk; `loadAt()` fills it with only the chunks an instant needs, which is the seek
/// rule and the whole of it (spec §8). The views `gaussians()` returns point into the
/// decoder's memory and are invalidated by the next load, so a caller who wants to keep them
/// copies them.
///
/// One scene belongs to one thread at a time. Decoding is pure CPU over immutable input, so
/// the pattern for more is one scene per worker.
class Scene {
 public:
  /// Open from a path, from bytes, or over any `Readable`.
  ///
  /// The `Readable` overload borrows: the caller keeps ownership and must outlive the scene.
  /// It is what an HTTP range reader or a cache plugs into, and what lets a test count the
  /// bytes a decode actually transferred.
  static Result<std::unique_ptr<Scene>> openPath(const std::string& path,
                                                 ReadMode mode = ReadMode::kAuto);
  static Result<std::unique_ptr<Scene>> openMemory(Span<const std::uint8_t> bytes,
                                                   ReadMode mode = ReadMode::kAuto);
  static Result<std::unique_ptr<Scene>> open(Readable& source, ReadMode mode = ReadMode::kAuto);

  ~Scene();
  Scene(const Scene&) = delete;
  Scene& operator=(const Scene&) = delete;

  double durationSec() const;
  /// The file's own marginal threshold, not the 0.05 default — spec §6.3 makes the
  /// distinction load-bearing for velocity precision.
  double cutoff() const;
  std::uint64_t gaussianCount() const;
  int shDegree() const;
  /// True when the file was opened on the indexed path rather than read front to back.
  bool isIndexed() const;
  /// True when the file ended inside a record, with everything complete before the cut
  /// still decoded. Always false on the indexed path, which requires a complete file.
  bool truncated() const;

  /// The header's own strings, and its free-form attributes.
  std::string temporalModel() const;
  std::string profile() const;
  std::string library() const;
  std::map<std::string, std::string> attributes() const;

  /// Chunk index entries; 0 for a file with no index, which must be read sequentially.
  std::uint32_t chunkCount() const;
  Result<std::pair<double, double>> chunkInterval(std::uint32_t index) const;
  /// What a seek to `t` would transfer at this band cap, so a caller can budget before
  /// asking. Seek cost is a property of the content, not of the container.
  std::uint64_t bytesForTime(double t, int maxShBand) const;
  /// The same, for exactly one chunk, which is what a byte-budget check needs: `loadAt`
  /// cannot isolate a chunk when intervals overlap.
  std::uint64_t bytesForChunk(std::uint32_t index, int maxShBand) const;
  /// Decode exactly chunk `index`. `kUnsupportedMode` on a sequential reader, which has no
  /// index to fetch from and has already decoded every chunk.
  Result<void> loadChunk(std::uint32_t index, int maxShBand);

  /// Audio presence, answered from the header alone: no probing, no speculative range
  /// request, and absence is a normal complete file rather than an error (spec §7).
  bool hasAudio() const;
  std::string audioCodec() const;
  std::uint64_t audioSize() const;
  /// Read a byte range of the track. Offsets are relative to the track, not to the file.
  Result<void> readAudio(std::uint64_t offset, Span<std::uint8_t> into);
  /// The whole track, bounded by `audioSize()`, which is known without fetching it.
  Result<AudioTrack> readAudioTrack();

  /// Decode every chunk into the working set, or only the chunks covering `t`. `maxShBand`
  /// caps spherical harmonics: the bands above it are never transferred (spec §5.7). Pass 0
  /// for none and 3 for all.
  Result<void> loadAll(int maxShBand);
  Result<void> loadAt(double t, int maxShBand);

  /// The resident gaussians. Valid until the next load on this scene.
  GaussianView gaussians() const;

  /// Reconstruct the state at scene time `t`, loading what that instant needs. This is where
  /// decoding ends: no ordering, no culling, no level of detail.
  Result<State> stateAt(double t, int maxShBand);

  /// The rest of the file: what it says about itself beyond its gaussians.
  ///
  /// Opening frames the camera, metadata and attachment records and stops, so a camera
  /// nobody asked for costs nothing; these fetch on first use. `loadRecords()` does it up
  /// front, which is how a caller learns whether those records are readable at all rather
  /// than one accessor at a time.
  Result<void> loadRecords();
  Result<std::vector<MetadataRecord>> metadata();
  Result<std::vector<Attachment>> attachments();
  bool hasCamera() const;
  Result<Camera> camera();
  bool hasStatistics() const;
  Result<Statistics> statistics() const;
  std::vector<SummaryOffset> summaryOffsets() const;

  /// Three states, not two: "not checked" and "did not match" are different claims about a
  /// file, and collapsing them reports corruption nobody observed.
  enum class CrcState { kNotChecked = -1, kFailed = 0, kVerified = 1 };
  CrcState summaryCrcState() const;

 private:
  explicit Scene(std::unique_ptr<detail::Handle> handle);
  std::unique_ptr<detail::Handle> handle_;
};

}  // namespace fourdgs

#endif  // FOURDGS_SCENE_HPP
