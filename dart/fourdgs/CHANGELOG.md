# Changelog

All notable changes to the Dart package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Prepared, not published. The heading carries the version rather than `Unreleased` because
`pubspec.yaml` already declares 0.1.0 and pub refuses to pack a package whose changelog does not
mention its own version — and because the release gate extracts this section as the release notes,
so it has to exist before the tag rather than after it. There is no date: the release has not
happened.

### Added

- `fourdgs`, a pure-Dart decoder for the `.4dgs` container. No Flutter dependency and no `dart:io`
  in the decoder itself, so the same code runs on the Dart VM, inside Flutter, and compiled to
  JavaScript or Wasm.
- Both read paths. `readFourdgsBytes` walks a whole file front to back, needs no index, and recovers
  what preceded a cut; `openFourdgsIndexed` reads the Footer, then the index, then only the byte
  ranges an instant needs.
- `keyframe-delta` decode, both read paths. `decodeKeyframeDeltaStreamed` composes each chunk onto
  the one it references front to back; `decodeKeyframeDeltaIndexed` walks only an instant's chain
  from the index. Composition is bin-difference and telescopes, so the declared error bound holds at
  any chain depth (spec §11); GOP-invariants are enforced and rotation is restated absolutely.
  `keyframeDeltaStatesJson` emits the canonical reconstruction-at-an-instant the SDKs are diffed on.
  Decode only this milestone — there is no encoder.
- Object-layer decode (spec §5.15.6-§5.15.7, §6.6). `FourdgsObjectTable.parse` and
  `FourdgsObjectTrack.parse` read the two records, the `object_id` attribute stream (id 14) is
  decoded onto `FourdgsGaussianSet.objectId`, and `FourdgsObjectLayer` composes an object's SE(3)
  track onto reconstructed state — `center = R * c0 + T`, `orientation = R ⊗ r0`, base first.
  Available on both read paths: `scene.objects` on the streamed path, `readFourdgsObjects` on the
  indexed one, where the records are framed at open and fetched only when asked for, as provenance
  is. A gaussian with `object_id = 0`, or whose object has no track, keeps its base state; a scene
  that carries no layer produces an empty `FourdgsObjectLayer`, which is a value and not an error.
  `FourdgsState` now carries `orientations` and `objectId` alongside centres and opacity, so a
  caller can compose the layer without re-deriving either.
- `FourdgsReadable` as the single abstraction either path needs — a size and a byte range — with
  `FourdgsBytes` in the core and `FourdgsFileReadable` in `package:fourdgs/io.dart`. Transports live
  at the edges, so the decoder can be tested without a network and shipped without a platform.
- §3's reconstruction arithmetic: `FourdgsGaussianSet.stateAt` gives the marginal, the validity
  window, the advected centre and the scaled opacity at a time `t`, and decoding ends there.
- Multiple spatial `FourdgsAudioSource` values with independent timing, payloads, gain, looping and
  fixed or keyframed scene-space poses. `stateAt` reconstructs source-local playback time and moving
  pose; listener-relative HRTF, attenuation, occlusion and mixing remain player-owned.
- Descriptor-only audio inspection, source-state reconstruction and bounded source-relative payload
  reads, so an indexed caller never has to materialize an entire track to update a moving source.
- Spherical harmonics on both read paths, bands 1 to 3, merged into whole scene-wide degrees. The
  indexed path fetches only the bands asked for, since each band is its own byte range in the chunk
  index.
- Scene provenance (spec §5.15): Coordinate Frame, Sensor Calibration, Rig Trajectory and Geodetic
  Anchor on both read paths. Streamed decode fills `FourdgsScene.provenance`; the indexed path
  frames ranges at open and fetches them via `readFourdgsProvenance`. `FourdgsProvenance` carries
  the cross-record rules (unique names, resolving rig and frame references) and the arithmetic the
  records imply — shortest-arc slerp, clamped pose sampling, sensor-in-scene composition.
- `conformance/`, building `decode_streamed` and `decode_indexed`, registered in
  `tests/conformance/run.py` and skipped until built. Both paths report provenance in the canonical
  summary. The object-layer variants and the invalid corpus's refusal expectations are declined.
- Tests for the one behaviour the corpus cannot reach: the indexed reader's front-matter scan runs
  to the first Chunk, so a Camera, Metadata or Attachment record sitting behind a large embedded
  audio track is still found. The harness only ever exercises the default 64 KiB probe on scenes
  that fit inside it, so a scan that stopped early would pass every check; these decode a real
  corpus file at probes down to 64 bytes and assert that shrinking it changes the number of round
  trips and nothing else. They fail rather than skip when the corpus is absent.

### Security

- Ceilings on the three counts a file chooses and the reader allocates against: validity windows, SH
  band descriptors per chunk-index entry, and chunk-index entries. Each is bounded twice — once
  against the bytes actually present, which the record itself disproves for free, and once against a
  ceiling far past anything a real encoder emits. Without them a 64 MiB summary names millions of
  objects that are built before any later budget is consulted.
- A chunk-index entry may not list the same SH band twice. A repeated descriptor is not merely
  redundant: each copy is fetched and then overwrites the same map entry, so N copies of a valid
  range are N transfers that leave one record behind.

### Fixed

- The velocity precision class is derived from the file's own `cutoff` rather than from the default
  0.05. A file that declares something else was encoded against that number, so assuming the default
  decodes a minority of gaussians' motion on the wrong pitch — the corpus's `CustomCutoff` variant
  is off by a factor of two — and nothing in the file says so. A cutoff outside `(0, 1]` is now
  refused rather than allowed to become a domain error inside a logarithm.
- An unsupported major version is reported as the digit in the magic rather than as that character's
  ordinal, so "version 9" no longer arrives as "version 57".

Nothing is released. There is no pub.dev entry for this package yet and nothing should depend on it.
The first publish must be done by hand — pub.dev requires it before automated publishing can be
enabled — after which the gated job in `.github/workflows/release.yml` takes over.
