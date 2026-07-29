# Changelog

All notable changes to the C++ package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The package: a CMake project (`fourdgs-cpp`, target `fourdgs::cpp`), the public C++17 API over the
  spec's data model, `Result<T>` error handling, `Readable` transports, and the two conformance
  runners.
- The binding itself, against the Rust core's C ABI: `Scene` over `fourdgs_scene` with the
  working-set model, `State` over `fourdgs_state`, and a `Readable` bridged into the decoder's
  byte-range callbacks so a C++ transport — a file, an HTTP range reader, a cache — is what the
  decode reads through.
- Unit tests for the temporal arithmetic of spec §3, the error policy, the transports, FFI hygiene
  at the ABI edge, and the canonical JSON — including the property the whole cross-language
  comparison rests on, that reordering a scene's gaussians cannot change one character of its
  summary.

### Notes

Conformance-verified: 67 checks over 34 variants on both read paths, the same numbers as the
reference implementation, and the feature matrix records exactly what that proves. Nothing is
released yet — the package has no version to release from, and the encode rows stay `Planned`
because it decodes only at v1.
