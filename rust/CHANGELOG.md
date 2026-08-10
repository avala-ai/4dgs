# Changelog

All notable changes to the Rust crate are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-08-10

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

### Added

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

## [0.3.0] - 2026-07-31

This release adds the normative `keyframe-delta` temporal model in the crate and exposes whole-file
decode through an additive C ABI for the C++ and Swift bindings. Reconstruction still ends at
composed gaussian state; rendering remains a consumer responsibility. The LOD proposal is
documentation only and is not advertised here.

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
