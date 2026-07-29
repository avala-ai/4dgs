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

### Not yet

Decoding. `Sources/FourDGS/CoreSeam.swift` is the single seam onto the Rust core's C ABI and throws
`FourDGSError.notImplemented`; the package is published here as an API surface and a set of runners
waiting for `rust/fourdgs/include/fourdgs.h`. No Swift cell in the feature matrix moves until the
conformance suite says so.

Nothing is released. There is no Swift package registry entry and nothing should depend on this yet.
