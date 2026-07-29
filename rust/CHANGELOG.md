# Changelog

All notable changes to the Rust crate are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Structural fuzzing over seeded mutations, covering both read paths and the C ABI, with a counting
  allocator and a timer enforcing that no input causes an unbounded allocation or a hang. It found
  two allocation bugs and an integer overflow on its first run.
- `rust/encode-roundtrip.sh`: the encoder's gate. Re-encodes every corpus variant and requires the
  Rust and Python decoders to agree on the result, because an encoder checked only against its own
  decoder proves nothing about the format.

Not released. `fourdgs 0.0.1` on crates.io is a name reservation, published by hand to hold the name
against Cargo's rule that a crate name may not begin with a digit; it contains no implementation and
nothing should depend on it. The first release with a decoder in it will be `0.1.0`, and it will be
cut from a tag like every other release here.
