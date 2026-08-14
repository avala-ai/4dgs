# Changelog

All notable changes to the Rust crate are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Scene reading now enforces fixed validated working-set envelopes.** Header, Quantization, Window
  Table, and lazy descriptor records are parsed from progressively fetched prefixes so legal
  extension suffixes are stepped over rather than allocated on indexed and streamed paths. Encoded
  Chunk and SH Band Stream ranges and contiguous summaries are capped before their reads; decoded
  wire symbols and their wider resident values, gaussian-row amplification, aggregate scene state,
  streamed retained bytes, and repeatable record counts are checked before the corresponding
  decompression, output allocation, or collection growth. Indexed state ranges must frame exactly
  one record. Audio Source bodies are validated without fetching Audio Data payloads, and
  record-byte-aware incomplete-versus-malformed diagnoses cross the C ABI. Indexed camera, metadata,
  attachment, provenance, object, and Audio Source parsing now shares the opened scene's diminishing
  allowance, and replacement loads charge every retained lazy and pose-validation cache before
  decoding beside the previous gaussian state. Header attribute maps and streamed audio map nodes
  are checked before allocation, lazy Audio Source descriptors include all `SceneReader` caches, and
  the public decompressor grows only as validated output actually arrives. Quantization bounds,
  Metadata maps, Window Table rows, indexed range collections, and assembly scratch storage receive
  the same pre-allocation checks; truncated orphan audio payloads leave the budget when dropped.
- **Indexed Chunk and SH Band Stream ranges are checked against the resource before they are read.**
  A Chunk Index entry is two numbers with no framing around them, so nothing but this check stands
  between a declared range and the buffer sized from it. `BytesReadable` and `FileReadable` refuse
  an out-of-range read on their own and hid the gap; a caller-supplied range source — which is what
  every C, C++ and Swift consumer provides — sizes the host's buffer before the host sees the
  offset, so a 512 MiB entry in a 933-byte file allocated 512 MiB, once per index entry and once per
  SH band range.
- **A Window Table that arrives after a Chunk is refused rather than applied retroactively.** A
  window index is validated against the table in force when its Chunk is decoded; a second, shorter
  table left indices already accepted pointing outside the table assembly was handed, which indexed
  a `Vec` out of bounds and panicked — `FOURDGS_STATUS_INTERNAL` across the C ABI, an abort under
  `panic=abort`. Assembly now checks the index it is given as well, so a malformed file is a refusal
  on both paths.
- **The indexed decode ceiling accumulates across the chunks a caller keeps.** `read_chunk` gave
  every call the whole shared scene ceiling, so N reads a caller retains cost N ceilings. It now
  bounds one read against the opened scene's remaining budget, and `read_chunk_within` carries a
  `ResidentBudget` across a loop that keeps what it reads.
- **Duplicate provenance record names are found in linear time.** The check rescanned every earlier
  name per record, so the record-count ceiling bounded memory but not CPU: 200,000 `CoordinateFrame`
  records — 6.0 MB of input — took 15.4 s in `read_bytes`, and the ceiling admitted about 26 s. The
  same file now takes 26 ms.

### Changed

- `WriteOptions.cutoff` outside `(0, 1]` is refused as `InvalidInput` rather than written. A
  marginal threshold of zero or less has no logarithm to invert, and the `NaN` support half-width
  that came back was discarded by `f64::max`/`f64::min`, silently planning every chunk as though
  each gaussian filled its whole validity window.
- **A counted record is fetched at the size it declares instead of by doubling towards it.** The
  prefix loop grew 8 KiB, 16 KiB, 32 KiB … re-reading from the same offset each time, so a lazily
  read 100,000-sample Object Track cost `2 + log2(L / 8 KiB)` range requests and moved roughly `2L`
  bytes. Records that declare a row count already state their own length; the prefix now jumps to
  it, which is two requests and `L` bytes. Records with no counted rows still double.

## [0.6.0] - 2026-08-13

### Added

- **Bounded `keyframe-delta` validation on the C ABI.** `fourdgs_validate_keyframe_delta_reader`
  certifies either the sequential or indexed read path over the existing range-reader abstraction,
  retaining only the current population and GOP keyframe. Lifetime identity introductions are
  streamed to a caller-owned sink so a CLI can prove uniqueness with bounded scratch storage at its
  I/O edge; the declared lifetime count is returned only after the complete path validates. The
  validator checks the physical ownership and exact set of SH Band Streams as well as their inner
  attribute, shape, and unsigned-byte coefficient domain. `fourdgs_last_error_offset` exposes the
  offending record byte without making bindings parse an error sentence. Both symbols are additive,
  and transferred reader contexts are released exactly once on every success and failure path.

- **A `keyframe-delta` encoder on the C ABI.** `write_sequence` has been the reference for this
  model since 0.3.0 and no binding could reach it, which is why the feature matrix recorded C++ and
  Swift as Planned for encoding it. Eleven additive symbols close that:
  `fourdgs_kd_writer_new`/`_free`, `_set_duration`, `_set_cutoff`, `_set_cadence`,
  `_add_keyframe_at`, `_set_profile`, `_set_library`, `_set_compression`, `_add_sample`,
  `_sample_count` and `_encode`, which returns the same owned `fourdgs_buffer` the gaussian-birth
  writer does.

  A second handle rather than a mode on `fourdgs_writer`, for the same reason a Delta Chunk is its
  own record and not a flag on Chunk (spec §5.18): that writer takes one population, and this model
  is a population restated at a sequence of instants with identity. The handle accumulates samples
  and encodes once, because a delta is a difference of bins and never a quantization of a difference
  (§11.7) and that holds only if every sample was quantized on grids derived from the whole sequence
  — so a binding that assembled deltas itself would be a second encoder with its own rounding rather
  than a shim. Strings are length-delimited like every other one here.
  `tests/capi_keyframe_delta_writer.rs` drives the surface the way a binding does, including that
  the id column is carried rather than invented from row order, that null is safe on every entry
  point, and that a delta mode which is not a mode is refused before it reaches a file.

## [0.5.0] - 2026-08-12

### Added

- **The refusal identifier on the C ABI.**
  `fourdgs_last_refusal_code(const char **out, size_t *out_len)` returns the identifier the
  specification's refusal table gives the last error on this thread — `magic-mismatch`,
  `unsupported-major-version`, `unknown-temporal-model`, `unknown-quantization-scheme`,
  `unknown-stream-codec`, `window-index-out-of-range` — or NULL with length 0 when the error is not
  one of them, which is an answer rather than a gap: a truncated transport and an I/O failure are
  real errors the table does not name. The nine `FOURDGS_STATUS_*` codes say what _kind_ of thing
  went wrong and `FOURDGS_STATUS_UNSUPPORTED_CODEC` alone covers three of the six, so this is the
  only way a binding can say _which_ refusal it met. Additive — no existing signature moved —
  because two bindings and a downstream application consume this ABI. Length-delimited like every
  other string here, never NUL-terminated. Thread-local and written beside the message, so the
  identifier and `fourdgs_last_error()` always describe one failure and a later error never inherits
  an earlier identifier. `tests/capi_refusal.rs` reads it the way C does and `capi_smoke.c` proves
  it links and compiles as C.
- **Inspect and validate, to the diagnostic bar the format asks for.** The `4dgs` tool already
  walked records and checked files; what it could not do is the thing its holder actually wants,
  which is to be told _which_ rule a file broke and _where_. It now is.

  - **`4dgs validate` names the refusal and the byte.** Findings still read word for word as the
    Python validator's — the identifier arrives on a line of its own beneath the finding it belongs
    to, so anything filtering on `error:`/`warning:`/`note:` sees exactly what it saw before. The
    identifier is `Error::refusal_code`'s, the same string the conformance corpus is written
    against; the byte comes from the tool's own framing walk, since an error is raised where a value
    was parsed rather than where its bytes sit.
  - **It decodes the chunks, one at a time — every chunk, and every band each one declares.** A
    framing walk steps over a chunk by its declared length, so a fault inside a chunk's streams is
    invisible to it — two of the invalid corpus's seven variants are exactly that, and both used to
    validate clean. All seven are now refused, by the identifier the corpus names, with the byte.
    Exactly one chunk is resident at a time on **both** paths: the indexed one reads chunk by chunk
    through the index, and a file with no index is walked record by record rather than decoded in
    one call, which is what used to make the resident set the whole scene. Spherical-harmonic bands
    are decoded rather than capped at band 0 — capping is a rendering choice, and an SH Band Stream
    carrying a codec this build does not implement is a file that does not decode — and the byte
    names the band record itself, not the Chunk it belongs to.
  - **It knows `keyframe-delta`.** Every structural check assumed the gaussian-birth chunk shape, so
    a conforming keyframe-delta file came back with seven errors and an `INVALID`. The Header's
    declared model now selects the reader, and the model's own reader is what opens it. Validation
    walks the timeline once, retaining only the current state and GOP keyframe, so a refusal names
    its index entry without repeatedly decoding chained prefixes or retaining the sequence.
  - **A refusal is placed at the record that carries the refused value.** Nothing in the framing
    forbids a second Header or a second Quantization record, and both read paths check every copy
    they meet — so a file whose first Header is fine and whose second declares a model this build
    does not implement is refused at the second. The byte now says so; it used to name the first
    record of that kind, which is an offset pointing at a record with nothing wrong with it.
  - **A provenance record is no longer reported as an unknown one.** `0x20`-`0x25` are defined, so
    they are skipped in silence; `0x26`-`0x2F` is reserved and keeps the note. The note names that
    range and §5.15.8, where both validators said `0x24-0x2F, section 5.15.6` — true before the
    object layer was assigned `0x24` and `0x25` out of it, and since then a citation pointing at two
    records that exist. Both tools still note the same opcodes. Four spurious notes about a
    conforming capture are gone.

- **`4dgs inspect` reports CRC status per record.** The only checksum the format defines is the
  Footer's `summary_crc`, so the new column says whether the checksum covers a given record and
  whether it agrees — `ok`, `MISMATCH`, or `-` for a record nothing covers — with the covered byte
  range named beneath the table. `--json` carries the same as a per-record `"crc"` and a
  `"summary_crc"` object.

- **A truncated file is reported rather than refused at the first byte that failed.** `inspect`
  lists every record it could frame, then names the cut, the byte, and how many complete records
  before it a streamed reader keeps; `validate` adds the same as a note. Records are
  length-prefixed, so that prefix is genuinely intact — saying only that the file stopped reading
  left its holder to guess whether anything was salvageable.

  This holds for a file cut inside its own **Footer** too. The Footer is where the summary checksum
  is declared, so `inspect` reads it to say which records that checksum covers; asking for a record
  the file was cut inside returned `Truncated` and ended the command before a single row was
  printed. Coverage is now read only from a whole Footer, and a file cut inside one reports its
  records and declares no checksum rather than nothing at all.

- **The summary checksum is computed over bounded reads.** `summary_start` is eight bytes off an
  untrusted file and may name byte 8, which made verifying the checksum a single allocation of
  essentially the whole file. `serialization::Crc32` is the same CRC-32 fed in pieces, and `inspect`
  feeds it a megabyte at a time.

- **Additive library items for callers that want the verdict rather than the whole sequence.**
  `serialization::Crc32`, above. `keyframe_delta_file::open_indexed` returns an `IndexedSequence` —
  a file's front matter and index with nothing composed — and `keyframe_delta_file::compose_chain`
  composes the chain ending at one index entry. Both use the core `Readable` range abstraction.
  `read_keyframe_entry` and `read_delta_entry` support a linear full-file walk without accumulating
  states. `decode_indexed` is those two in a loop and is unchanged; what it cannot do is answer
  "does every chunk decode?" without keeping every state it decoded.
  `keyframe_delta_file::check_keyframe_chunk` and `check_delta_chunk` answer the same question for
  one record of a file that has no index to seek in, and keep nothing.

### Fixed

- **`keyframe-delta` validation now checks the model's complete structural contract.** Indexed
  fields must agree with the Chunk or Delta Chunk they name; keyframe and delta-group stream counts
  must agree with their record headers; keyframe-mode deltas reference the GOP keyframe and chained
  deltas reference the immediately preceding state; SH band numbers must be in `1..3` and agree with
  the index. Stream-only files compose deltas, check their timeline, and decode their SH bands too.
  The Header's `gaussian_count` is checked against distinct identities using a fixed-memory,
  disk-partitioned counter rather than a scene-sized identity map.

- **`inspect` refuses an impossible checksum range.** A nonzero summary checksum whose start lies
  after the Footer is malformed; it is no longer described as a file that intentionally omitted a
  checksum.

- **A `keyframe-delta` file declaring an unknown quantization scheme is refused.** The model's
  reader parsed its Quantization record and never asked the registry about it, so a scheme this
  build does not implement composed all the way to a state and `validate` printed `valid` — while
  the gaussian-birth reader refuses the same declaration by name at open. `open_indexed` now checks
  it as the record is read, exactly as `indexed_reader::open_indexed` does.

- **A `keyframe-delta` index must reach both ends of the timeline.** Spec §11.1 fixes three things:
  each chunk's `t1` is the next chunk's `t0`, the first `t0` is `0`, and the last `t1` is the
  Header's `duration_sec`. `check_tiling` implemented the first, which says everything about the
  interior and nothing about either end — an index covering `[0.4, 0.9)` of a one-second clip is
  internally adjacent and tiles nothing, and a seek to `t=0` on the file it was told was conforming
  answers "no state chunk covers t=0". New: `keyframe_delta::check_timeline_endpoints`.

- **A `keyframe-delta` file with no chunk index is read front to back rather than reported
  invalid.** `open_indexed` starts its index walk at `Footer.summary_start`; on a stream-only file
  that is zero, so it walked from byte 0, read the file magic as record framing, and returned an
  error. `validate` now warns that the file can only be read front to back — as it always has for
  `gaussian-birth` — and checks each keyframe and delta chunk on the way past, keeping none of them.

- **Every SH Band Stream a `keyframe-delta` index declares is decoded.** Composing a chain reads
  Chunk and Delta Chunk records and nothing else, so a band record was a record the verdict never
  visited: an unimplemented codec in one of them validated clean. The same rule the gaussian-birth
  path already holds, on the other model.

- **A refusal inside a chunk's streams is placed by `4dgs decode` and `4dgs info` too.** Only
  `validate` decoded chunks, so `decode` printed `refusal unknown-stream-codec` with no byte at all
  — the framing walk cannot find a fault inside a chunk, because stepping over one by its declared
  length is exactly not looking inside it. The tool's error path now scans the file front to back,
  one record at a time, and names the first record raising that same refusal.

- **Placing a refusal no longer frames the whole file first.** The error path built a `Frame` per
  record before examining the front matter, so an early refusal on a large file — the case the
  refusal exists for — cost memory proportional to that file. The search is streamed and stops at
  the record it is looking for.

- **The Footer is read twenty bytes at a time, whatever it declares.** `Footer::parse` reads three
  fields and ignores the rest, which is what keeps a Footer a later revision extends readable; the
  record's declared length is eight bytes off an untrusted file, and `inspect` was sizing an
  allocation from it. A Footer naming nearly the whole file as its content is now a number in the
  length column rather than a buffer.

- **The duplicate of an SH band is told apart from the healthy one.** Nothing in an index forbids
  two ranges for the same band, and `read_chunk` decodes both — so raising a cap until the read
  failed named whichever sorted first, an offset pointing at a record with nothing wrong with it.
  Each range is now decoded on its own.

- **A file cut exactly on a record boundary is reported as cut.** Remove only the eight-byte
  trailing magic and every record is whole, so the walk reached the end with nothing left over and
  recorded nothing: `inspect` printed a note and exited **0** for an incomplete file, and `validate`
  left off the note that says how much of it survives.

### Changed

- **Exit code 3: the tool could not run.** A missing file, an unreadable one, or an argument the
  tool does not understand now exits 3 rather than 1. `1` is an answer about a file — it was read,
  and it is bad; `3` is the absence of an answer. A pipeline that saw 1 for both could not tell a
  corrupt asset from a typo in a path, which makes the tool indistinguishable from a broken one on
  the day it matters. `0`, `1` and `2` are unchanged.

## [0.4.0] - 2026-08-10

### Added

- **The `keyframe-delta` temporal model.** Composition, write and both read paths mirror the Python
  reference and the normative spec (§11). Deltas are integer bin subtractions on shared grids so
  composition telescopes; the declared error bound holds at any chain depth. Streamed decode
  composes front to back; indexed decode walks only the chain an instant needs. The canonical
  `states` JSON is emitted by `keyframe_delta_file::keyframe_delta_states_json` and is the
  cross-implementation gate. Refusal codes match the reference (`bin-overflow`,
  `invariant-changed-in-update`, `forward-reference`, `depth-mismatch`, and the rest) without
  changing the frozen `Error` enum shape.

- **keyframe-delta on the C ABI.** `fourdgs_keyframe_delta_states_json` decodes a whole
  keyframe-delta file (either read path) to its canonical `states` JSON,
  `fourdgs_peek_temporal_model` reads the Header's model without opening a scene, and
  `fourdgs_string_free` releases the owned strings both return. Additive — no existing signature
  moved. The C++ and Swift packages decode keyframe-delta through these entry points rather than a
  second encoder; `capi_smoke.c` exercises the peek, the decode refusal on a gaussian-birth file,
  and the free.

- **Refusal identifiers.** `Error::refusal_code` returns a stable string for a refusal this reader
  can name, or `None` for errors the refusal table does not cover — a truncated transport, an
  encoder bound violation. The identifiers are constants in `fourdgs::error::refusal`, compared
  across every SDK by the conformance suite, so a typo in one is a conformance failure rather than a
  private detail. Rust now answers the invalid corpus and passes **119** checks, the same as the
  Python reference.

- **Provenance on the C ABI.** `fourdgs_scene_provenance_json` returns the canonical provenance
  object (frames, anchors, sensors, trajectories with `posesAt` probes, and `sensorPosesAt`) for an
  opened scene, or an empty string when the file carries none. Computed by
  `provenance::canonical_json` in the core so C++ and Swift emit the same slerp and clamp as the
  reference; freed with the existing `fourdgs_string_free`. Additive — no existing signature moved.
- **The object layer on the C ABI.** `fourdgs_scene_objects_json` and
  `fourdgs_scene_object_states_json` return the canonical `objects` and `states` members (spec
  §5.15.6-§5.15.7) for an opened scene — the Object Table's entries, the tracks with their sampled
  poses, and the post-composition gaussian state at each probe — or an empty string when the file
  carries neither object records nor membership. Both are views of one
  `object_layer::canonical_parts` computation, so composition order (`center = R*c0 + T`,
  `orientation = R ⊗ r0`) is stated once in the core. `fourdgs_scene_object_ids` borrows the
  resident `object_id` array, or returns NULL when the scene carries no such stream — NULL and
  all-zero are different claims. Additive — no existing signature moved.

### Changed

- **Named refusals are a new `Error` variant.** The six refusals the specification's table names —
  `magic-mismatch`, `unsupported-major-version`, `unknown-temporal-model`,
  `unknown-quantization-scheme`, `unknown-stream-codec`, `window-index-out-of-range` — now arrive as
  `Error::Refused { code, kind, message }` rather than as `UnsupportedVersion`, `UnsupportedCodec`,
  `UnsupportedModel` or `Malformed`. Nothing on the wire changed: `kind` carries the variant it
  would have been, and both `Display` and the C ABI's status mapping defer to it, so every sentence
  and every `FOURDGS_STATUS_*` is what it was.

  **This is a breaking change for code that matched those variants directly** —
  `matches!(err, Error::UnsupportedVersion(_))` no longer catches a bad magic. Use the new
  predicates, which account for both spellings and keep working when a refusal gains a name:
  `Error::is_unsupported_version`, `is_unsupported_feature`, `is_malformed`.

### Fixed

- **Each gaussian gets the validity window its `window_index` names.** The keyframe-delta reader
  carried one window for the whole sequence and derived every gaussian's velocity grid from
  `windows[0]` (spec §6.3), so on a file whose Window Table has more than one entry, every gaussian
  outside window 0 reconstructed at the wrong motion precision — no refusal, just positions that
  drift from the bins the encoder wrote. The writer could not produce such a file either: it forced
  a single full-duration window and wrote `window_index = 0` for everyone, ignoring the `win_lo` and
  `win_hi` each gaussian already carried. Both sides are fixed, so a multi-window population now
  round-trips at the precision it declares.

## [0.3.0] - unreleased

Prepared on 2026-07-31 and never tagged. Its notes are part of 0.4.0, which is the release that
ships them.

## [0.2.0] - 2026-07-29

This release adds native spatial audio, provenance and object motion while preserving the crate's
bounded-memory, range-seekable reconstruction contract. Rendering and playback remain consumer
responsibilities.

### Added

- **Object-layer decoding and reconstruction.** Exact `u32` `object_id` membership, optional Object
  Tables and time-sampled SE(3) Object Tracks are available through streamed and indexed readers.
  `Scene::state_at` and `SceneReader::state_at` compose referenced object poses onto gaussian
  centres and orientations after base temporal reconstruction; indexed reads validate bounded track
  blocks, fetch no unrelated tracks and cache only one instant's reconstructed poses.

- **Scene provenance.** Coordinate Frame, Geodetic Anchor, Sensor Calibration and Rig Trajectory
  records round-trip through the Rust records, scene model and writer. Pose reconstruction clamps
  outside the sampled interval, uses shortest-arc quaternion interpolation and composes rig-relative
  sensor poses without requiring provenance when only gaussian state is requested.

- **An encode surface on the C ABI.** `fourdgs_writer_*` in `include/fourdgs.h` — a builder that
  takes the gaussian columns, spherical harmonics and write options and encodes to an owned
  `fourdgs_buffer` — so the C++ and Swift packages author files through the core rather than a
  second encoder. Appended after the decode surface; no existing signature moved. `capi_smoke.c` now
  builds a tiny scene, encodes it and reopens the bytes, so a drift between the header and the
  symbols is caught in CI. A shared `encode_gaussians` conformance runner re-encodes a variant's
  gaussians alone as the baseline the C++, Swift and TypeScript encoders are diffed against.

- **Per-band spherical harmonic bit depths.** `WriteOptions::sh_bit_depths` takes a depth of 3–8 per
  band; the encoder rounds each band's coefficients onto the implied grid, declares the depths in
  the Quantization record's appended fields and the per-band bounds under `bounds.sh_band<b>`, and
  decodes each band record it wrote to check the bound on every coefficient before returning the
  file. Eight bits is the identity, so a file that declares nothing is unchanged in every byte.
  `Quantization::sh_bit_depths` exposes the declaration to readers; nothing at decode depends on it,
  because the byte a band stream carries is already the quantized value.

- `encode_roundtrip` takes an optional ladder or depth list, and `encode-roundtrip.sh` uses it to
  re-encode every spherical-harmonic variant at per-band depths and require the Python decoder to
  agree with this one about the result — and to read back the depths this encoder declared.

- `sh_step`, `sh_bound`, `sh_bound_float`, `quantize_sh`, `sh_coefficient` and the `SH_QUANT_LO` /
  `SH_QUANT_HI` interval that spec §6.5 now pins, for consumers that hand their callers floats.

- `4dgs info` prints the per-band bit depths on their own line when a file declares them, and
  `4dgs validate` checks them against the Header's degree.

### Fixed

- **The encoder wrote files the specification forbids, silently, when handed a non-finite
  position.** The position origin is a fold of `f64::min` seeded with `f64::INFINITY`, and
  `f64::min` returns the other operand when one is NaN — so a single NaN on an axis left that axis
  at the seed and `inf` was written as a quantization origin, against §5.3. One gaussian was enough;
  a whole axis of NaN was never needed, and no error was raised. `write_to_vec` now refuses a
  non-finite value in any **quantized** field — positions, scales, rotations, colours, motions,
  `mu_t` — with `Error::InvalidInput`, naming the field and the gaussian. The fields that are not
  quantized are deliberately left alone: `+inf` in `sigma_t` means a gaussian that never fades, and
  `+inf` in `win_hi` means a static asset present at every instant, which is what the glTF import
  writes. NaN is refused in those three too, since it is meaningful in none of them and quietly
  passes for a deliberate value.

- `4dgs validate` checked only the last Quantization record parsed. Nothing in the framing forbids a
  second, and a streamed decoder takes the first grid it meets, so a file carrying a non-finite grid
  followed by a clean one validated green while decoding entirely through the broken one. Each
  record is now checked as it is walked, and the report names which copy when there is more than
  one. A test now runs both validators over the same bytes — including the duplicate-record case —
  and requires their findings to match line for line, so the mirror cannot drift again without
  saying so.

### Added

- `Error::InvalidInput`, for a scene the encoder cannot write a conforming file from. The mirror of
  `Malformed`: that describes a file that arrived broken, this describes one that never should have
  been offered. It maps to `FOURDGS_STATUS_INVALID_ARGUMENT`, which already existed in the C header,
  so the ABI does not move.

- Native spatial audio sources across the Rust model, streamed and indexed readers, writer and C
  ABI. Sources have independent encoded payloads, timing, gain, looping, scene-space pose and moving
  pose keyframes; reconstructed `AudioSourceState` deliberately stops before listener-relative
  rendering.
- Descriptor-only, source-state and bounded payload-range access. The payload size is validated and
  available before allocation, allowing C, C++ and Swift players to stream encoded source data
  without reading the whole file or source.
- Audio Source and Audio Data records with legacy Audio read compatibility. Writers validate timing
  and keyframes and normalize quaternions before emission.

## [0.1.0] - 2026-07-29

The first release of the Rust crate, and the first cut from a tag. It is the decoder and the
production encoder, and it is what the C++ and Swift packages bind to: the C ABI in
`include/fourdgs.h` is part of this release, not a side effect of it.

`fourdgs-cli`, which installs the `4dgs` tool, is not released here. It is unpublished for a reason
recorded in its manifest.

_Fixed_ and _Changed_ below describe behaviour that changed against the pre-release code in this
repository, which people do vendor from git — not against `0.0.1`, which held the name on crates.io
and contained nothing.

### Added

- Decoder: TLV container, streamed and indexed readers, both adaptive-precision rules, validity
  windows, whole-degree spherical harmonic bands, `deflate` by default with `zstd` behind a feature,
  and the audio, camera, metadata, attachment, statistics and summary-offset records.
- `include/fourdgs.h`: a C ABI for decoding, and the surface the C++ and Swift packages bind to.
  Nothing unwinds across it, every fallible call returns a status, and null is safe to pass.
- Conformance runners in `rust/conformance`, wired into the shared harness.
- The production encoder: error-bounded quantization on the declared grids, the temporal chunk tree,
  independent chunks, an index, and deterministic output. It verifies its own claim before returning
  a file — every chunk is decoded back and every value checked against the bounds the Quantization
  record is about to declare, so a file whose bounds have not been measured never reaches a caller.
- C ABI: the rest of the file. `temporal_model`, header attributes, metadata records, attachment
  names/media types/**bytes**, camera and keyframes, statistics, summary offsets, a tri-state
  summary CRC, a truncated flag, per-chunk load and per-chunk byte prediction, and `_ex` openers
  that force the sequential or indexed path. Strings read from file bytes cross as (pointer,
  length), never NUL-terminated, because the format's `string` may legally contain a NUL.
- Structural fuzzing over seeded mutations, covering both read paths and the C ABI, with a counting
  allocator and a timer enforcing that no input causes an unbounded allocation or a hang. It found
  two allocation bugs and an integer overflow on its first run.
- `rust/encode-roundtrip.sh`: the encoder's gate. Re-encodes every corpus variant and requires the
  Rust and Python decoders to agree on the result, because an encoder checked only against its own
  decoder proves nothing about the format.

### Fixed

- A file cut between a chunk and its spherical harmonic band records was refused as malformed
  instead of recovering the complete prefix. Bands are whole, so the short trailing chunks are
  dropped and everything that arrived intact is kept.
- Asking for fewer spherical harmonic bands than were already resident answered from the cache,
  handing back a higher degree than requested and transferring nothing — which is exactly what a
  band-skipping byte budget measures.
- The front-matter probe read 64 KiB, which on a small file was the whole thing. It is 8 KiB now:
  the records an indexed open must parse are a few hundred bytes, and everything else in the front
  matter is stepped over rather than read.

### Changed

- The streamed reader's retained summary run narrowed to Chunk Index, Statistics and Summary Offset,
  matching the new spec §4.5. Attachments are no longer retained: their size is unbounded, and
  admitting them would have made verifying a checksum cost whatever the payload weighed.

## [0.0.1] - 2026-07-28

A name reservation, published by hand before the release workflow existed, to hold the name against
Cargo's rule that a crate name may not begin with a digit. It contains no implementation, has no tag
and no GitHub Release, and nothing should depend on it.
