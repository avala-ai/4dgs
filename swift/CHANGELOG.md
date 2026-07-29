# Changelog

All notable changes to the Swift package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Not yet

A conformance summary. The ABI reaches the Header's numbers, the audio, the chunk intervals and the
gaussians; it has no accessor for the metadata, attachment, camera, statistics or summary-offset
records, nor the Footer's summary CRC. `Scene.recordsAvailable` says so rather than letting an empty
array read as a fact, and the runners refuse to print a partial summary. No Swift cell in the
feature matrix moves until the conformance suite says otherwise.

Nothing is released. There is no Swift package registry entry and nothing should depend on this yet.
