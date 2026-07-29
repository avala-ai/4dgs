# Changelog

All notable changes to the Python package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-29

This release adds the format's new scene-description layers while keeping reconstruction bounded,
range-seekable and renderer-agnostic. Spatial rendering, object presentation and rate-control policy
remain outside the package.

### Added

- **Object-layer decoding, encoding and reconstruction.** Exact `u32` `object_id` membership,
  optional Object Tables and time-sampled SE(3) Object Tracks now round-trip through the reference
  reader and writer. Both read paths compose each referenced object's rigid pose onto gaussian
  centres and orientations after base temporal reconstruction; background and untracked gaussians
  remain unchanged, and indexed reads do not fetch unrelated tracks.

- **Scene provenance.** Coordinate Frame, Geodetic Anchor, Sensor Calibration and Rig Trajectory
  records round-trip through streamed and indexed reads. Pose reconstruction clamps outside the
  sampled interval, uses shortest-arc quaternion interpolation inside it and composes rig-relative
  sensor poses without making provenance a prerequisite for gaussian decoding.

- **The `keyframe-delta` temporal model.** Reference composition and encoding operate on quantized
  bins, preserve explicit gaussian identities across births, updates and deaths, and support chained
  or keyframe-relative groups. Indexed reconstruction follows only the bounded chain needed for the
  requested instant.

- **glTF interoperability.** `from_gltf` imports static `KHR_gaussian_splatting` assets, while
  `to_gltf` exports the reconstructed state at a requested instant. Coordinate systems, colour
  spaces and whole spherical-harmonic degrees are converted explicitly rather than guessed.

- **OpenUSD interoperability.** The optional `usd` extra adds `from_usd` and `to_usd` for
  `ParticleField3DGaussianSplat` prims. Static imports preserve USD stage units and up-axis
  metadata; exports can write one reconstructed snapshot or a time-sampled sequence without claiming
  that USD stores the continuous temporal model.

- **Chunk-compressed PLY import.** `fourdgs.from_compressed_ply` and the `4dgs from-compressed-ply`
  subcommand read the chunked, quantized `.ply` that splat editors export — per-chunk float bounds
  for every 256 gaussians, each gaussian a handful of packed `uint32` — including its temporal
  extension, which adds per-chunk motion, time-scale and time bounds and the `packed_motion` /
  `packed_time` vertex words. `convert` already imported a directory of per-frame _uncompressed_
  PLYs; this is the other interchange form, and the only one that carries per-gaussian velocity and
  a temporal centre and extent, which is exactly the state this format stores natively.

  A temporal capture is commonly split across segment files that share one timeline, each stored on
  a clock relative to its own start with a sidecar naming the parts. Passing the segments in
  timeline order with `--segment-duration` collapses them into one continuous scene: segment `k`'s
  scene time is `local + k × duration`, and its own span becomes the validity window of the
  gaussians it contributes. Each segment also carries a tail of gaussians centred outside its span
  that a player never shows; those are dropped rather than smeared. The sidecar and its parts become
  a single seekable file, which is the point.

  Four vertex words share one 11-10-11 field split, so position, scale, motion and time all go
  through the same three helpers rather than re-deriving the shifts per call site. That is not
  tidiness: the low 11 bits of the time word are identically zero in real captures, so a hand-rolled
  16/16 reading leaves the temporal _extent_ near-correct while quietly destroying the temporal
  _centre_ — plausible numbers, wrong timing, and no way to tell the layouts apart by inspecting the
  extent. The suite asserts on the centre for that reason.

- **Per-band spherical harmonic bit depths.** `WriteOptions.sh_bit_depths` takes a depth of 3–8 per
  band, or one of the `flat` / `balanced` / `aggressive` ladder names, and the encoder rounds each
  band's coefficients onto the grid that depth implies, declares the depths in the Quantization
  record's appended fields and the per-band bounds under `bounds.sh_band<b>`, and — as it already
  did for position, scale and colour — decodes each band record it wrote and checks the bound on
  every coefficient before it hands the file back. Eight bits is the identity, so a file that
  declares nothing is a file at eight bits and no existing output moved: every previously committed
  conformance checksum is unchanged.

  The saving is entropy, not packing. A coefficient is still a byte and no decoder changes; a band
  at five bits takes 32 distinct values, which is what the stream codec acts on. On the synthetic
  scene in `python/tools/rd_benchmark.py`, a degree-3 file's band streams fall to 44 % of their
  eight-bit size at five bits, or to 61 % on the `balanced` ladder, which leaves band 1 exact.

- `python/tools/rd_benchmark.py`, which sweeps bit depths against codecs and reports bytes against
  reconstruction error. Its README carries the committed tables and the command that regenerates
  them. It exits non-zero if any file's decoded coefficients fall outside the bound that file
  declares, so it is a check as well as a measurement.

- `validate` reports the per-band depths against the Header's degree: a count that disagrees with
  the declared degree is an error, and a `bounds.sh_band<b>` or a `step_sh` that does not follow
  from the depths is a warning.

- `sh_coefficient` and `sh_bound_float`, for consumers that work in coefficients rather than in
  bytes, now that spec §6.5 pins the byte-to-coefficient map that `SH_QUANT_LO` / `SH_QUANT_HI`
  already held. The constants keep their values and their meaning; what changed is that the
  specification now says them, so a second implementation cannot pick a different interval and be
  conforming.
- `InvalidInput`, raised when the encoder is handed a scene it cannot write a conforming file from —
  a non-finite value in a quantized field (position, scale, rotation, colour, velocity, `mu_t`). It
  refused these before, but from inside the codec, with a message about a symbol exceeding 32 bits
  that named neither the field nor the gaussian; the one thing the caller needed to know was the one
  thing it could not say. The fields that are not quantized are left alone: `+inf` in `sigma_t`
  means a gaussian that never fades, and `+inf` in `win_hi` means a static asset present at every
  instant, which is what the glTF import writes. NaN is refused in those three too — it is
  meaningful in none of them, and it is the quiet kind of wrong, since a NaN sigma reads as
  never-fading and a NaN window makes every visibility comparison false.

- `validate` checks **every** Quantization record as it walks the file, not only the one left in
  hand at the end. Nothing in the framing forbids a second, and a streamed decoder takes the first
  grid it meets — so a file carrying a non-finite grid followed by a clean one used to validate
  green while decoding entirely through the broken one. The report names which copy when there is
  more than one.

- Native spatial audio sources. A scene may carry multiple independently timed encoded payloads,
  each with an ID, channel layout, gain, looping policy and scene-space pose. Position and
  quaternion-rotation keyframes reconstruct moving source state at scene time `t`; spatial rendering
  from that state and the listener pose remains the player's responsibility.
- Indexed audio access through `read_audio_source_descriptors`, `read_audio_source_state` and
  `read_audio_range`. Descriptors expose the validated payload size without fetching the payload, so
  a player can schedule bounded range reads for only the sources it needs.
- Reference-writer support for Audio Source and Audio Data records. The writer validates source
  timing and keyframes, normalizes rotations, and retains read compatibility with legacy Audio
  records while emitting only the new representation.
- `validate` reports a non-finite quantization step or position origin as an error, naming the
  field, per the new spec §5.3. This changes no file anything here has ever written — every grid the
  encoder emits is finite — and it adds nothing to what a decoder does: dequantization still
  succeeds or refuses exactly as before. What it ends is the silence. Arithmetic on infinity is
  perfectly well defined, so a single corrupt step decoded quietly into a scene whose every gaussian
  was infinity or NaN, and the first sign of it was a renderer drawing an empty frame.

- A fuzz suite, `tests/test_fuzz.py`, holding one invariant: for any input at all, a decoder either
  succeeds or raises a `FourdgsError`. Never a codec library's exception, never unbounded
  allocation, never a hang — an input that exceeds the time ceiling is a failure, not a slow test.
  Mutations are structural (truncations at record boundaries, impossible lengths, spliced and
  dropped records, corrupted footers) rather than purely random, and the generator is shared with
  the TypeScript fuzzer seed for seed, so a crash found by one implementation reproduces in the
  other from two integers. Every input that has ever found a crash is replayed on every run.

### Fixed

- **Ten crash classes found by fuzzing, and one denial of service.** A corrupt deflate or zstd
  payload escaped as the codec library's own exception; a string field that was not UTF-8 escaped as
  `UnicodeDecodeError`; an index entry, band range or audio range pointing outside the file escaped
  as the transport's error; a spherical-harmonic band whose element count disagreed with its chunk
  raised `ValueError`; an attribute stream with no columns raised `IndexError`; a rotation index
  outside 0..3 indexed off the end of a table; and a header cutoff of zero reached a logarithm. All
  are `MalformedFile` now. The denial of service is separate: a constant-mode stream declaring 2^30
  elements expanded a one-byte payload into gigabytes, because the size cap bounded what arrives
  rather than what it becomes. One flipped bit cost 1.4 seconds; it now costs a refusal.

## [0.1.0] - 2026-07-28

The first release of the Python reference implementation, and the first cut from a tag. It is what
the specification is checked against: where the two disagree, the conformance suite decides which
one is wrong.

_Fixed_ and _Changed_ below describe behaviour that changed against the pre-release code in this
repository, which people do vendor from git — not against `0.0.1`, which held the name on PyPI and
contained nothing.

### Added

- The reader. Every top-level structure is a length-prefixed record with an opcode, so an
  unrecognized record is stepped over rather than fatal. Two read paths, neither an optimization of
  the other: `read()` walks a file front to back in bounded blocks and works on a pipe or a
  truncated file, and `open_indexed()` reads the index and then only the byte ranges an instant
  needs.
- Gaussian state at a time `t`: per-gaussian birth, velocity, temporal extent and validity window,
  the two precision rules recomputed from the sigma bin, smallest-three rotations, the colour
  transform, and spherical harmonic bands merged as whole degrees. `state_at()` is where decoding
  ends — nothing here renders.
- The writer, `write()` with `WriteOptions`. It optimizes for a file that is easy to reason about
  rather than for size or throughput, and verifies its own stated error bounds by decoding what it
  wrote.
- `WriteOptions.cutoff`, so a file can declare a marginal threshold other than the default. It is
  not decoration: the cutoff sets the support constant the per-gaussian velocity grid is derived
  from, so encoder and decoder have to agree on it.
- `WriteOptions.record_trailers`, which appends bytes to a record's content the way a later minor
  revision would add a field. Used by the conformance corpus to write a file that a reader must step
  over rather than stop at.
- Audio, a camera trajectory, metadata and attachments as front-matter records. On the indexed path
  each costs exactly its own bytes to read, through `read_camera`, `read_metadata` and
  `read_attachments`; the streamed reader decodes spherical harmonic bands, verifies the Footer's
  summary CRC and collects Summary Offset records.
- `validate()`, and `fourdgs validate` over it: structural validation where every finding names the
  record, the field and what was expected. This is what makes a third-party encoder possible —
  finding out why a file is wrong without reading this decoder.
- `convert_ply_sequence()`, and `fourdgs convert` over it: a directory of per-frame gaussian splat
  `.ply` files becomes one continuous scene, each frame's gaussians taking that frame's slot as
  their validity window and velocities fitted across the frames a gaussian appears in.
- `fourdgs info` and `fourdgs decode`, thin enough over the library that anything the CLI can do a
  caller can do. `info` reports what seeking costs: the bytes needed to display an instant.
- Errors that name the problem — `MalformedFile`, `TruncatedFile`, `UnsupportedCodec`,
  `UnsupportedVersion` and `BoundViolation`, all under `FourdgsError` — so a file that is malformed
  is distinguishable from one that is merely newer.
- Conformance runners under `python/conformance/`, which decode the generated corpus and print the
  canonical JSON the suite compares across SDKs.

### Fixed

- `open_indexed` raised `ValueError` — not a `FourdgsError` — on a footer whose `summary_start`
  points past the footer itself, so `validate` could not catch it and a malformed file crashed the
  tool meant to diagnose it. It is now a `MalformedFile` naming both offsets.
- `open_indexed` could not open a file whose front matter held a record larger than its 64 KiB
  probe. An Audio record lives in the front matter, so any scene with a real soundtrack failed — on
  the seekable path, on the format's flagship case. The walk now steps over a record by arithmetic
  and fetches only what it wants.
- A chunk's `compression` field was parsed and then ignored, so a conforming chunk-compressed file
  decoded to garbage instead of either working or failing. It is now honoured, and an unrecognized
  codec is refused by name.
- The velocity precision grid used the default cutoff rather than the file's own, so any file
  declaring a different threshold decoded velocities the encoder did not write. `state_at` had the
  same assumption in its visibility test.
- A file whose trailing magic is missing is now reported as truncated rather than as complete.

### Changed

- **A window index outside the Window Table is refused rather than clamped.** Clamping substituted
  one gaussian's lifetime for another's in a file that was already corrupt, turning a detectable
  fault into plausible wrong output. Files written by this encoder are unaffected; a reader that
  relied on the old behaviour will now see `MalformedFile`.
- A file with no Window Table, or an empty one, reads as a single `(0, 0)` window. That was already
  the behaviour; it is now the documented one.

## [0.0.1] - 2026-07-28

A name reservation, published by hand before the release workflow existed: `4dgs` on PyPI belongs to
an unrelated project, so `fourdgs` was claimed before there was anything to put in it. It contains
no implementation, has no tag and no GitHub Release, and nothing should depend on it.
