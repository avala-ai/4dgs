# Changelog

All notable changes to the Rust crate are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-29

The first release of the Rust crate, and the first cut from a tag. It is the decoder and the
production encoder, and it is what the C++ and Swift packages bind to: the C ABI in
`include/fourdgs.h` is part of this release, not a side effect of it.

`fourdgs-cli`, which installs the `4dgs` tool, is not released here. It is unpublished for a reason
recorded in its manifest.

_Fixed_ and _Changed_ below describe behaviour that changed against the pre-release code in this
repository, which people do vendor from git — not against `0.0.1`, which held the name on crates.io
and contained nothing.

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
- C ABI: the rest of the file. `temporal_model`, header attributes, metadata records, attachment
  names/media types/**bytes**, camera and keyframes, statistics, summary offsets, a tri-state
  summary CRC, a truncated flag, per-chunk load and per-chunk byte prediction, and `_ex` openers
  that force the sequential or indexed path. Strings read from file bytes cross as (pointer,
  length), never NUL-terminated, because the format's `string` may legally contain a NUL.
- Structural fuzzing over seeded mutations, covering both read paths and the C ABI, with a counting
  allocator and a timer enforcing that no input causes an unbounded allocation or a hang. It found
  two allocation bugs and an integer overflow on its first run.
- `rust/encode-roundtrip.sh`: the encoder's gate. Re-encodes every corpus variant and requires the
  Rust and Python decoders to agree on the result, because an encoder checked only against its own
  decoder proves nothing about the format.

### Fixed

- A file cut between a chunk and its spherical harmonic band records was refused as malformed
  instead of recovering the complete prefix. Bands are whole, so the short trailing chunks are
  dropped and everything that arrived intact is kept.
- Asking for fewer spherical harmonic bands than were already resident answered from the cache,
  handing back a higher degree than requested and transferring nothing — which is exactly what a
  band-skipping byte budget measures.
- The front-matter probe read 64 KiB, which on a small file was the whole thing. It is 8 KiB now:
  the records an indexed open must parse are a few hundred bytes, and everything else in the front
  matter is stepped over rather than read.

### Changed

- The streamed reader's retained summary run narrowed to Chunk Index, Statistics and Summary Offset,
  matching the new spec §4.5. Attachments are no longer retained: their size is unbounded, and
  admitting them would have made verifying a checksum cost whatever the payload weighed.

## [0.0.1] - 2026-07-28

A name reservation, published by hand before the release workflow existed, to hold the name against
Cargo's rule that a crate name may not begin with a digit. It contains no implementation, has no tag
and no GitHub Release, and nothing should depend on it.
