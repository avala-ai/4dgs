// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#ifndef FOURDGS_SRC_BACKEND_HPP
#define FOURDGS_SRC_BACKEND_HPP

#include <string>
#include <vector>

#include "fourdgs/model.hpp"
#include "fourdgs/readable.hpp"
#include "fourdgs/result.hpp"

/// The seam.
///
/// Everything above this line is ordinary C++ — RAII, views, `Result`. Everything below it is
/// the Rust core's C ABI. Exactly one translation unit implements these functions against
/// that ABI (`backend_capi.cpp`) and exactly one implements them as honest refusals for a
/// build made without a core (`backend_unavailable.cpp`); CMake picks between them. Nothing
/// else in the package includes `fourdgs.h`, so the ABI's shape stays a detail of one file.
namespace fourdgs {
namespace detail {

/// The state one open decoder holds.
///
/// The model objects are C++-owned so the public API can hand out references and views into
/// them. `core` is whatever the ABI's opaque reader pointer is, owned by the backend and
/// released in `closeHandle`.
class Handle {
 public:
  Handle() = default;
  ~Handle();
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;

  Readable* source = nullptr;
  void* core = nullptr;

  Header header;
  bool hasCamera = false;
  Camera camera;
  bool hasAudio = false;
  AudioTrack audio;
  std::vector<MetadataRecord> metadata;

  /// The chunk a streaming decoder currently holds, and the view handed to callers.
  GaussianData chunk;
  GaussianView view;
  double chunkT0 = 0.0;
  double chunkT1 = 0.0;
  bool ended = false;
  bool truncated = false;

  /// Trailing records.
  std::vector<ChunkIndexEntry> index;
  bool hasStatistics = false;
  Statistics statistics;
  std::vector<Attachment> attachments;
  std::vector<SummaryOffset> summaryOffsets;
  bool hasSummaryCrcOk = false;
  bool summaryCrcOk = false;

  /// Refresh `view` from `chunk`, after the backend has filled the arrays.
  void refreshView() { view = GaussianView(chunk); }
};

/// Open for front-to-back decode; fills the header and the front matter.
Result<void> openStream(Handle& handle);

/// Decode the next chunk into `handle.chunk`, or report the end of the stream. On `false`
/// the trailing records and `truncated` are filled in.
Result<bool> nextChunk(Handle& handle);

/// Open for indexed decode; fills the header, the index and the trailing records by range.
Result<void> openIndexed(Handle& handle);

/// Read one chunk by its index entry, transferring only the SH bands at or below `maxShBand`.
Result<void> readChunk(Handle& handle, const ChunkIndexEntry& entry, int maxShBand,
                       GaussianData& out);

/// Front matter by byte range, for an indexed reader. `false` means the file has none, which
/// is a value and not an error.
Result<bool> readAudio(Handle& handle, AudioTrack* out);
Result<bool> readCamera(Handle& handle, Camera* out);
Result<std::vector<MetadataRecord>> readMetadata(Handle& handle);
Result<std::vector<Attachment>> readAttachments(Handle& handle);

/// Release the core's reader. Called from `~Handle`, and safe on a handle that never opened.
void closeHandle(Handle& handle) noexcept;

/// What the linked core reports, or null when there is none.
const char* coreVersionString() noexcept;
bool available() noexcept;

}  // namespace detail
}  // namespace fourdgs

#endif  // FOURDGS_SRC_BACKEND_HPP
