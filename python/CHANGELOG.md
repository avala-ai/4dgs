# Changelog

All notable changes to the Python package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-08-13

### Fixed

- **Validity-window comparisons retain their f64 wire precision.** Decoding narrowed Window Table
  endpoints to f32, turning a large finite upper bound into infinity, while `GaussianSet.state_at`
  compared caller-constructed f32 windows directly with an f64 query. Readers now retain decoded
  endpoints as f64 and comparisons widen caller-provided arrays, so a query after a large finite
  window is excluded and an infinite window remains live at huge finite times. Finite inputs that
  reconstruct a non-finite center at an extreme time remain a valid state whose canonical scalar is
  `null`.

- **`4dgs validate` counts distinct gaussian ids in one decode of the file, not a hundred.** The
  count is bounded-memory by design — a set of every id ever seen grows with cumulative births — and
  it was bounded by auditing one fixed-capacity partition of the id space at a time, splitting by
  the next high bit and re-streaming the whole file for each half whenever a partition filled. Every
  split doubled the partitions and every partition drove a fresh scan, so the passes grew with the
  number of distinct ids: a 400,000-id sequence took 40 complete decodes, and a 4M-id capture well
  over a hundred, which is a validate that runs for hours and looks hung. It now makes one pass and
  keeps the ids it is counting, four bytes each. On a 1.3 MiB, 400,000-id file: 6.1s to 0.4s.
  Sequences past the declared one-pass ceiling fall back to the old exact partitioned rescan, so
  bounded memory never makes validation skip identity reuse or the Header's required distinct-count
  comparison.

### Changed

- **`count_distinct_ids_bounded` bounds itself by a declared ceiling rather than a fixed budget.**
  Its `capacity` argument, which sized one partition, is now `max_distinct_ids`, which is the number
  of distinct ids it will count before refusing — 8,388,608 by default, 32 MiB of identities. Exact
  one-pass distinct counting cannot be done in fixed space, and the second thing this function
  decides, whether an id died and came back, rules out the probabilistic estimators that can. So the
  honest bound is one this module declares, never one the file's own contents choose (AGENTS.md §1).

### Added

- **`ExceedsReaderLimit`**, for a legal file whose scale is past a ceiling a reader states in
  advance. Distinct from a malformed file, and reported as such by the standalone bounded counter.
  Validation cannot leave a required check unmade, so it changes strategy at that point instead of
  treating the limit as a finding about the file.

  Reuse is tested as the pass reaches each state, before that state's ceiling check, so an earlier
  reuse is not hidden by a later limit and is refused at the chunk where it appears. Validation then
  uses a fixed-capacity partitioned rescan if the one-pass audit crosses its limit; reuse after that
  point and the Header's distinct-count claim still receive exact answers. The first version stopped
  both checks at the ceiling and could report a later §11.2 violation as valid, exit 0.

## [0.4.0] - 2026-08-12

### Fixed

- **`4dgs validate` no longer calls two malformed files valid.** `UnknownStreamCodec` and
  `WindowIndexOutOfRange` — two of the conformance corpus's seven invalid variants — were reported
  `valid`, exit 0. Both break a rule inside a chunk's attribute streams, and the validator only
  walked the framing, which steps _over_ a chunk by its declared length rather than into it. It now
  decodes the chunks after the framing checks, one resident at a time on the indexed path (AGENTS.md
  §1), so validating a file larger than memory still works. All seven variants are now refused, each
  by the identifier its own corpus entry declares.

- **`keyframe-delta` files are validated against the model they declare.** They were validated
  against the `gaussian-birth` reading and came back with seven errors and an `INVALID`, for a
  temporal model this package has implemented since 0.3.0. `gaussian_count` counts distinct
  gaussians over the sequence while every keyframe carries a full population, so summing chunks is a
  larger number by design; the chunk index addresses Delta Chunks as well as Chunks; and the
  gaussian-birth reader is not the reader that opens the file. The Header's `temporal_model` now
  selects the path.

- **The reserved-provenance note names the range that is actually reserved.** `0x24` and `0x25` were
  assigned to the object layer, so `(0x24-0x2F, section 5.15.6)` told its reader that two records
  this package parses had been skipped. It reads `(0x26-0x2F, …)` now. The note still fires only for
  the still-reserved tail: a capture carrying frames, sensors, a rig and a georeference collects
  none.

- **Spherical-harmonic band streams are decoded during validation.** `read_chunk` caps the bands it
  fetches, which is right for a renderer — coefficients do not enter reconstructed state — and wrong
  for a validator: an SH Band Stream is a stream like any other, and a band carrying a codec no
  build implements is a file that does not decode. Every band a chunk declares is now decoded, and a
  refusal inside one names that band's own record rather than the Chunk it belongs to, which can be
  thousands of bytes away.

- **A chunk the index does not name is reported.** The file layout is one Chunk Index entry per
  chunk (§4), and every check that decodes a chunk is driven by the index — so a file whose index
  simply omitted the chunk carrying an unimplemented codec was reported valid. An omitted chunk and
  two entries naming one chunk are both errors now.

- **A Delta Chunk in a `gaussian-birth` file is refused.** §5.18: the record "exists only under
  `temporal_model = "keyframe-delta"`". Neither reader said so — the streamed one skipped the opcode
  as though it came from a later revision, the indexed one stopped at the first Chunk — so the
  record was read by nobody and reported by nobody.

- **A refusal is placed at the record the reader refused at, not the first of its kind.** Nothing in
  the framing forbids a second Header or a second Quantization record, and a reader refuses at the
  first one carrying a value it does not implement. The report named the first, sending its holder
  to bytes that were perfectly good.

- **The `keyframe-delta` read paths check what they parse.** Six fields were parsed and then used
  for nothing, each of them a rule the specification states as a MUST:

  - the four index fields that duplicate a Delta Chunk's own (§5.8: "a reader MUST refuse a file
    where the index and the record disagree, naming the field"), plus `gaussian_count` and
    `live_count`;
  - a Delta Chunk's `update_count`, `birth_count` and `death_count` against the groups that arrived
    (§5.18: "a stream whose `element_count` disagrees with its group's count is a refusal rather
    than an allocation");
  - a keyframe chunk's declared `count` against its streams, which `decode_streams` has always
    checked on the `gaussian-birth` path;
  - `window_index` against the Window Table, which composition never looked at — the bound was
    proved during reconstruction, so a file whose keyframe named a window its table does not have
    composed cleanly and refused when it was rendered;
  - the ends of the timeline (§11.1: "the first `t0` is `0`; the last `t1` is the Header's
    `duration_sec`"), which `check_tiling` never checked — it compared adjacent entries, and a
    single-entry index has no adjacent pair at all;
  - the Header's `gaussian_count` against the distinct ids the sequence carries, which was skipped
    entirely for this model and so checked by nothing.

- **A `keyframe-delta` file with no chunk index validates.** No index is a legal file (§4, AGENTS.md
  §2). The indexed reader was run over it regardless, and a Footer whose `summary_start` is 0 sent
  it to read records from byte 0 — where the magic sits — so every conforming one was reported
  invalid with a diagnosis about a record that does not exist.

- **Validation no longer assembles what it validates.** Three paths held the whole file: a
  `gaussian-birth` file with no index went through the streamed reader, which concatenates every
  chunk into one `GaussianSet`; an indexed `keyframe-delta` file went through `decode_indexed`,
  which keeps a composed population per index entry; one with no index would have kept a state per
  chunk plus a map of every offset a delta might reference. Each is now a scan that drops what it
  decoded — one chunk on the indexed paths, and two composed states front to back, which is what
  §5.18's two reference kinds require (AGENTS.md §1).

### Added

- **`4dgs validate` names the refusal, and the byte it fired at.** The exceptions have always
  carried `code`, the language-independent identifier the conformance suite compares across SDKs;
  the CLI dropped it. It is printed on an indented line of its own beneath the finding it belongs
  to, so a caller filtering output on `error:`/`warning:`/`note:` — which is how this tool and the
  Rust one are diffed — sees exactly what it saw before:

  ```
  error: a chunk does not decode: window index 1 is outside the 1-entry window table
    refusal window-index-out-of-range at byte 2506 (the Chunk record at index entry 1)
  ```

  The byte is the tool's own contribution: an exception is raised where a value is parsed, not where
  its bytes sit, so the new `fourdgs.refusal` module walks the framing and asks which record a given
  identifier is about. It is a table, not a guess, and a code it has not been taught is left
  unplaced rather than placed wrongly.

- **A cut file says how much of it survived.** Alongside the errors it already produced, `validate`
  now notes the byte the file was cut at, the record it was cut inside, and how many complete
  records before it a streamed reader recovers.

- **A file the tool could not open exits `3`, not `1`.** Exit `1` is a verdict about a file this
  tool read; a missing path or an unreadable mount is not that, and a caller handed the same status
  for both cannot tell a malformed corpus from a typo in a directory name. `0` (valid) and `1`
  (refused) are unchanged, which is the contract five other SDKs are written against; `2` remains
  argparse's usage error, and `3` is what the Rust tool already returns for the same thing. What was
  there before was an uncaught traceback, which is exit `1` by accident.

## [0.3.0] - 2026-08-10

This release ships the normative `keyframe-delta` temporal model as a whole-file reference path and
animated OpenUSD export for those sequences. Rendering and player policy remain outside the package.
The LOD proposal is documentation only and is not advertised here.

### Added

- **The `keyframe-delta` temporal model (whole-file reference).**
  `keyframe_delta_file.write_sequence` quantizes a sample sequence on one shared set of grids, then
  emits `Header(temporal_model="keyframe-delta")`, keyframe Chunks, Delta Chunks, the extended Chunk
  Index and the Footer. Cadence and `delta_mode` (chained or keyframe-referenced) come from
  `KeyframeDeltaOptions`. `decode_streamed` composes each chunk onto the state it references front
  to back; `decode_indexed` walks only the bounded chain needed for a seek (spec §11). Composition
  is bin-difference and telescopes, so the declared error bound holds at any chain depth;
  GOP-invariant attributes are banned from updates and rotation is restated absolutely.
  `states_json` is the canonical §11.2 summary — a `chunks[]` table and a `states[]` array at probe
  instants in `gaussian_id` order — which the other SDKs are diffed against.

- **Animated OpenUSD export of keyframe-delta scenes.** `to_usd_keyframe_delta` (and the
  `4dgs to-usd` path when the input is keyframe-delta) decodes the file, composes the population at
  each frame via `render_at`, and writes one USD time sample per frame. A keyframe-delta file has no
  closed-form `state_at` for a static snapshot, so animated USD is the interchange that can hold the
  temporal model over time. Births and deaths are exact per frame; USD time samples do not carry
  `gaussian_id` correspondence across samples.

- **`state_at_with_objects(gaussians, objects, t, cutoff)`**, exported at the top level, takes a
  `GaussianSet`, reconstructs its state at `t` itself, and composes an object layer onto the result
  in one call. `Scene.state_at` already did this for a decoded streamed scene; this is the same rule
  for a caller holding the two separately — a set from `scene.gaussians` or an import path, a layer
  from `read_objects` — and it saves every caller from remembering `ObjectLayer.apply`. It is not a
  drop-in for indexed output: `read_chunk` returns one chunk's decoded arrays and `IndexedScene`
  carries no `GaussianSet`, so an indexed caller assembles one before composing. It has no Header to
  read either, so `cutoff` defaults to `0.05` where `Scene.state_at` passes its own file's
  `header.cutoff`: a caller whose file declares a different threshold has to pass
  `scene.header.cutoff`, or the visibility test runs against `0.05` and a different set of gaussians
  can reach composition.
- **A ceiling on trajectory and object-track samples.** `MAX_TRAJECTORY_SAMPLES` bounds what one
  count-prefixed record may ask a reader to allocate before the bytes behind it are shown to exist.
  Shared by value with the other SDKs, because a ceiling only one implementation has is a file that
  decodes here and is refused there.
- **A ceiling on indexed front-matter records.** `MAX_FRONT_MATTER_BYTES` (64 MiB) bounds a Camera,
  Metadata, provenance, object-layer or Audio Source descriptor record, so a declared length cannot
  size a transfer the file has not justified. Chunks and audio payloads are not front matter and are
  unaffected. The check runs when the record is fetched rather than at open: `open_indexed` frames
  these ranges without reading them, so a file carrying an oversized one still opens and still
  decodes its chunks — it is the accessor for that record that refuses, where 0.2.0 transferred it.

### Fixed

- **An empty trajectory or object track is read as though the record were absent** (spec §5.15.4 and
  §5.15.7), so its pose rules are not applied — not even an interpolation byte outside the registry,
  which describes how to read samples it does not carry. Rules that are not about the pose still
  hold: a track naming object 0 is refused whether or not it carries samples, because the same
  section requires every track to name something to move.

  Two consequences worth stating. A rig-relative sensor naming a zero-sample trajectory is now
  refused, because the trajectory it references is absent — 0.2.0 kept the empty record and returned
  the bare extrinsic. And the writer does not refuse a zero-sample record: `check()` validates
  sample times and not the count, so one encodes with a count of zero.

- **Each gaussian gets the validity window its `window_index` names.** The keyframe-delta reader
  derived every gaussian's velocity grid from the first validity window (spec §6.3), while the
  writer forced a single full-duration window and wrote `window_index = 0` for everyone, ignoring
  the `win_lo` and `win_hi` each gaussian already carried. Both sides are fixed — the writer now
  round-trips distinct windows and exercises their liveness, and the reader resolves each row
  against the one its own index names. The reference writer still cannot demonstrate the precision
  defect because it emits no never-fading gaussian, the case whose velocity grid uses window length.

  The precision half of this is narrower than it sounds. §6.3 takes the velocity grid from the
  window length only for gaussians flagged as never fading; for every other gaussian the grid comes
  from its own `sigma_t` and the window never entered it. So the positions that drifted from the
  bins the encoder wrote were those of never-fading gaussians whose window is a different length
  from window 0's, and different by enough to land in another precision class. No refusal, just
  numbers nobody wrote.

  **The liveness half reaches a gaussian that references a window excluding the requested instant.**
  `reconstruct_at` now drops gaussians outside their own half-open window and `states_json`'s
  `liveCount` follows, so a probe in that excluded interval returns a different population — where
  before an expired or not-yet-born gaussian was still reported at an instant it does not exist, at
  full opacity if it is one that never fades. Merely declaring extra, unreferenced windows changes
  nothing. Both halves correct code drafted for this release and never tagged: 0.2.0 shipped no
  whole-file keyframe-delta reader, so there is no 0.2.0 output to compare against — this is for
  whoever ran the path off `main` before 2026-08-02.

- **A keyframe-delta state carrying no `window_index` is refused by name.** A zero-count keyframe
  may legally omit every stream, and a delta carries forward only the attributes its reference
  already had, so a later birth group can compose a non-empty state with no `window_index` column.
  Reconstruction needs one per row now that each row resolves its own window, so a state without it
  is refused as `missing-window-index`, naming the §11.5 rule that makes the attribute required,
  rather than failing as a `KeyError` raised inside reconstruction.

  The column is also range-checked now that it is read. An index outside the Window Table is refused
  as `window-index-out-of-range` — the code the chunk decoder has raised since 0.2.0 for the same
  fault — where the draft path never looked at the column and reconstructed everyone against window
  0, so the same bytes were accepted here and refused on the regular chunk path.

- **Cross-record rules run on a truncated file too, where they can.** `read` now applies the
  provenance and object-layer checks whatever `recover_truncated` returned, because a duplicate
  sensor name among records that arrived complete is a fault no later byte could repair. Rules that
  resolve one record against another are still deferred for a cut file — the record it names may
  simply not have arrived — unless a Footer went past, which means the record stream was complete
  and a missing rig or frame is missing for good. **0.2.0 skipped all of these for any truncated
  file and returned the partial scene.**
- **A `pose_reference` outside the registry is refused.** The registry defines 0 (scene) and 1
  (rig); 0.2.0 treated every other value as scene-relative, which puts a sensor somewhere plausible
  and wrong rather than saying it cannot place it.
- **Object Table shapes are validated before they are written.** An anchor that is not three values,
  a dynamics tuple that is not three vectors, or a dynamics vector that is not three values is
  refused with an identifier naming the object and the field. 0.2.0 wrote short anchors into a
  structurally shifted record, and a wrong dynamics count surfaced as a bare `ValueError`.
- **An invalid UTF-8 string names the byte that failed.** The diagnostic pointed at the length
  prefix, which had decoded fine, sending whoever held the file four bytes short of the problem. It
  now names the offending byte and its value.
- **A duplicate attribute stream is refused rather than resolved.** A malformed chunk or
  keyframe-delta group carrying the same attribute twice decoded last-stream-wins, so the same bytes
  could yield different memberships or values depending on order. It now refuses with
  `duplicate-attribute-stream`.
- **Quaternions near the top of the `f64` range normalize instead of being refused.** Trajectory,
  object-track and sensor-extrinsic rotations use `math.hypot` rather than a sum of squares, so an
  input like `[1e308, 0, 0, 0]` no longer overflows on the way to its own norm.
- **Canonical keyframe-delta JSON writes zero without a negative sign.** A value that rounds from
  `-0.0` to zero is emitted as `0.0`, so textual `states_json` comparisons no longer differ on a
  sign that carries no numeric distinction.

- **The Header declares the SH degree the file actually carries.** `sh_bands` caps how many bands
  the writer emits, but the Header went on declaring the degree the input `GaussianSet` held. A
  degree-3 scene written with `sh_bands=1` carries three coefficients per component and declared
  fifteen, so a reader sizing its buffers from the Header read a different number of coefficients
  than the file contained. The declared degree is now the highest band written (issue #190).

- **The top spherical-harmonic coefficient survives a pitch that does not divide 256.** The `coarse`
  profile's `step_sh = 3` centred the coefficient 255 on **256**, which no `u8` holds: the reference
  reader refused the file the reference writer had just produced, and a reader whose stream codec
  narrows to a byte instead reported the extreme positive coefficient as the extreme negative one.
  Coefficient rounding now lives in one place, `quantization.coarsen_sh`, and clamps back into the
  byte range — a move that can only be towards the original, so the declared half-pitch bound is
  kept (issues #181, #190).

- **Chunk-compressed PLY segment fidelity.** Segmented imports now retain every source gaussian and
  use the `.4dgs` validity window—not temporal-center filtering—to reproduce which segment is
  active. Gaussians centred outside a segment can still overlap it through their temporal extent,
  while the source format's static and always-visible sentinel bands are normalized to fixed motion
  and infinite temporal extent. The previous filter could remove visible support and persistent
  background from converted scenes.

## [0.2.0] - 2026-07-29

This release adds the format's new scene-description layers while keeping reconstruction bounded,
range-seekable and renderer-agnostic. Spatial rendering, object presentation and rate-control policy
remain outside the package.

### Added

- **Object-layer records and streamed reconstruction.** Exact `u32` `object_id` membership, optional
  Object Tables and time-sampled SE(3) Object Tracks now round-trip through the reference reader and
  writer. `Scene.state_at` composes each object's rigid pose onto gaussian centres and orientations
  after base temporal reconstruction; background and untracked gaussians remain unchanged. The
  indexed API exposes the records through `read_objects`, but does not yet compose them in
  `read_chunk` or promise referenced-track-only reads.

- **Scene provenance.** Coordinate Frame, Geodetic Anchor, Sensor Calibration and Rig Trajectory
  records round-trip through streamed and indexed reads. Pose reconstruction clamps outside the
  sampled interval, uses shortest-arc quaternion interpolation inside it and composes rig-relative
  sensor poses without making provenance a prerequisite for gaussian decoding.

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
  gaussians it contributes. The sidecar and its parts become a single seekable file, which is the
  point.

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
