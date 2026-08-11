# Changelog

All notable changes to the Swift package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-10

### Added

- The package can be depended on. `Package.swift` moved to the repository root, because SwiftPM
  clones the URL it is given and looks for a manifest at the top of that clone — a manifest under
  `swift/` is invisible to `.package(url:)`, so nothing could depend on this package at all. The
  sources did not move; every target names its own path under `swift/`.
- `fourdgsPackageVersion`, the one place this package's version is written, asserted against the
  release tag before anything is built.
- Named refusals: `RefusalCode` gives the six identifiers the specification's refusal table defines,
  and `FourDGSError.refusalCode` answers which rule a file broke — `nil` when the table does not
  name the failure, which truncation and I/O errors legitimately are. The identifier comes from the
  core through `fourdgs_last_refusal_code`, read as the pointer-and-length pair the ABI returns
  rather than as a C string, and rides on three existing cases as a trailing associated value
  defaulted to `nil` — see the breaking-change note below for what that default does and does not
  buy. The `decode_streamed` and `decode_indexed` runners print `{"refused": "<id>"}` and exit 0 for
  a file they refuse, which adds the invalid corpus to Swift's conformance run: 105 comparisons
  become 119.
- keyframe-delta decode: `peekTemporalModel` and `keyframeDeltaStatesJson`, binding the core's
  additive states-JSON C ABI through `CoreSeam`. The summary is computed in the Rust core, so the
  binding does no arithmetic of its own; the `decode_streamed` and `decode_indexed` runners peek the
  temporal model from the bytes — an opened scene refuses the model — and print the core's JSON
  verbatim on each read path.
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

- **Source-breaking:** `FourDGSError.malformed`, `.unsupportedCodec` and `.core` each gained a
  trailing `refusal: RefusalCode?` associated value. The `= nil` default keeps every _construction_
  compiling, but a default has no bearing on a _pattern_: code that binds these cases with the
  previous arity — `case .malformed(let offset, let record, let field, let reason)` — now fails to
  compile with "tuple pattern has the wrong length", and gains a `_` for the new element. No
  exhaustive `switch` over `FourDGSError` breaks, because no case was added or removed; that is why
  the identifier rides on the existing cases rather than arriving as a seventh one. Nothing is
  released and no package registry entry exists, so nothing depended on the old arity.

- `StreamedReader` and `IndexedReader` are replaced by one `SceneReader`. The ABI opens a file and
  chooses its own read path; two types that could not actually differ would have been a claim the
  code could not keep, and the suite runs two runners precisely so the paths can disagree. They come
  back when the ABI can be told which to use. Nothing is released, so nothing depended on them.

### Notes

The shared suite proves 105 comparisons across the valid variants Swift supports, including fixed,
moving and multiple audio-source scenes. Swift's runners materialize payloads only for canonical
comparison; the public `SceneReader` leaves them deferred.

**This version resolves and does not link out of tree.** There is no Swift registry; the package is
consumed from this repository's URL, at plain `vX.Y.Z` tags, which are the only tags SwiftPM reads.
`FourDGS` binds the Rust core through its C ABI and ships no prebuilt copy of it, so a consumer with
no checkout of this repository has no `libfourdgs` for the linker to find. The manifest emits a
warning saying so, naming what is missing and how to supply it, instead of leaving
`cannot find -lfourdgs` as the whole diagnosis. A `binaryTarget` pointing at a checksummed
`.xcframework` built for visionOS, iOS and macOS is the fix, and is not in this version.
