# Changelog

All notable changes to the C++ package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- keyframe-delta decode: `fourdgs::keyframeDeltaStatesJson` and `fourdgs::peekTemporalModel`,
  binding the core's additive states-JSON C ABI. The summary is computed in the Rust core, so the
  binding does no arithmetic of its own; the `decode_streamed` and `decode_indexed` conformance
  runners peek the temporal model from the bytes — an opened `Scene` refuses the model — and print
  the core's JSON verbatim on each read path. The suite now passes the four keyframe-delta variants
  both ways.
- The encode surface: `fourdgs::encodeScene`, binding the core's `fourdgs_writer_*` C ABI, so the
  package authors files through the same core it decodes through rather than a second encoder. A
  `test_writer` unit test builds a tiny scene, encodes it and reopens the bytes, and an
  `encode_roundtrip` conformance runner re-encodes each variant's gaussians for the cross-language
  gate, which requires the Python decoder to read the binding's output the same as the Rust
  reference's.
- Multiple spatial `AudioSource` values with independently timed payloads, fixed or keyframed
  scene-space poses, quaternion rotation, gain and looping. `audioSourceStateAt` reconstructs the
  source state at time `t`; spatialization against a listener remains player-owned.
- Descriptor-only source inspection and bounded payload range reads, plus explicit whole-source
  helpers for callers that have already accepted the validated allocation size.
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

Conformance-verified: 79 checks across the 45 valid variants this binding supports, and the feature
matrix records exactly what that proves. Nothing is released yet — the package has no version to
release from.
