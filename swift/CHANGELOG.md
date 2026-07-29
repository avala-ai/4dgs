# Changelog

All notable changes to the Swift package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The encode surface: `SceneWriter.encode`, binding the core's `fourdgs_writer_*` C ABI through
  `CoreSeam`, so the package authors files through the same core it decodes through. An
  `encode_roundtrip` runner re-encodes each variant's gaussians for the cross-language encode gate,
  which requires the Python decoder to read the binding's output the same as the Rust reference's.
- Multiple spatial `AudioSource` values with independent timing, encoded payloads, gain, looping and
  fixed or keyframed scene-space poses. `audioSourceState(_:at:)` reconstructs moving source state;
  listener-relative rendering remains the app or player's responsibility.
- Descriptor-only source discovery and bounded `audioSourceData` reads, keeping payload allocation
  under caller control and preserving the package's byte-range I/O boundary.
- The package is a real SPM package rather than a skeleton: `FourDGS` for visionOS, iOS and macOS,
  with the value types, errors and readers the spec's data model calls for.
- `StreamedReader` and `IndexedReader`, the two read paths, with `ByteRangeReader` as the single
  abstraction either one needs and `InMemoryReader` and `FileReader` as its transports.
- §3's reconstruction arithmetic — marginal, validity window, centre and opacity at a time `t` — and
  the tests that pin it, including that the cutoff comes from the file's own Header.
- `conformance/`, building `decode_streamed` and `decode_indexed`, registered in
  `tests/conformance/run.py` and skipped until built.
- A canonical-JSON self-test: `canonical_selftest` and `conformance/selftest.py` build the same
  synthetic scene from the same seed in each language, and CI asserts that the Swift emitter and
  `tests/conformance/canonical.py` produce documents that parse equal. It runs with no decoding
  involved, so a conformance mismatch once the ABI lands is about the decode and nothing else.

- The seam is wired: `CFourDGS` imports `rust/fourdgs/include/fourdgs.h` through a module map rather
  than a copied header, `SceneReader` decodes real files over the C ABI, and a Swift
  `ByteRangeReader` is bridged to the core's `fourdgs_reader` callbacks. CI builds the core's
  staticlib for Linux, macOS, **visionOS and iOS** and links against each — a Linux build proves
  nothing about the platforms this package exists for.

### Changed

- `StreamedReader` and `IndexedReader` are replaced by one `SceneReader`. The ABI opens a file and
  chooses its own read path; two types that could not actually differ would have been a claim the
  code could not keep, and the suite runs two runners precisely so the paths can disagree. They come
  back when the ABI can be told which to use. Nothing is released, so nothing depended on them.

### Notes

The shared suite proves 79 comparisons across the 45 valid variants Swift supports, including fixed,
moving and multiple audio-source scenes. Swift's runners materialize payloads only for canonical
comparison; the public `SceneReader` leaves them deferred.

Nothing is released. There is no Swift package registry entry and nothing should depend on this yet.
