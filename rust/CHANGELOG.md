# Changelog

All notable changes to the Rust crate are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **An encode surface on the C ABI.** `fourdgs_writer_*` in `include/fourdgs.h` — a builder that
  takes the gaussian columns, spherical harmonics and write options and encodes to an owned
  `fourdgs_buffer` — so the C++ and Swift packages author files through the core rather than a
  second encoder. Appended after the decode surface; no existing signature moved. `capi_smoke.c` now
  builds a tiny scene, encodes it and reopens the bytes, so a drift between the header and the
  symbols is caught in CI. A shared `encode_gaussians` conformance runner re-encodes a variant's
  gaussians alone as the baseline the C++, Swift and TypeScript encoders are diffed against.

- **Per-band spherical harmonic bit depths.** `WriteOptions::sh_bit_depths` takes a depth of 3–8 per
  band; the encoder rounds each band's coefficients onto the implied grid, declares the depths in
  the Quantization record's appended fields and the per-band bounds under `bounds.sh_band<b>`, and
  decodes each band record it wrote to check the bound on every coefficient before returning the
  file. Eight bits is the identity, so a file that declares nothing is unchanged in every byte.
  `Quantization::sh_bit_depths` exposes the declaration to readers; nothing at decode depends on it,
  because the byte a band stream carries is already the quantized value.

- `encode_roundtrip` takes an optional ladder or depth list, and `encode-roundtrip.sh` uses it to
  re-encode every spherical-harmonic variant at per-band depths and require the Python decoder to
  agree with this one about the result — and to read back the depths this encoder declared.

- `sh_step`, `sh_bound`, `sh_bound_float`, `quantize_sh`, `sh_coefficient` and the `SH_QUANT_LO` /
  `SH_QUANT_HI` interval that spec §6.5 now pins, for consumers that hand their callers floats.

- `4dgs info` prints the per-band bit depths on their own line when a file declares them, and
  `4dgs validate` checks them against the Header's degree.

### Fixed

- **The encoder wrote files the specification forbids, silently, when handed a non-finite
  position.** The position origin is a fold of `f64::min` seeded with `f64::INFINITY`, and
  `f64::min` returns the other operand when one is NaN — so a single NaN on an axis left that axis
  at the seed and `inf` was written as a quantization origin, against §5.3. One gaussian was enough;
  a whole axis of NaN was never needed, and no error was raised. `write_to_vec` now refuses a
  non-finite value in any **quantized** field — positions, scales, rotations, colours, motions,
  `mu_t` — with `Error::InvalidInput`, naming the field and the gaussian. The fields that are not
  quantized are deliberately left alone: `+inf` in `sigma_t` means a gaussian that never fades, and
  `+inf` in `win_hi` means a static asset present at every instant, which is what the glTF import
  writes. NaN is refused in those three too, since it is meaningful in none of them and quietly
  passes for a deliberate value.

- `4dgs validate` checked only the last Quantization record parsed. Nothing in the framing forbids a
  second, and a streamed decoder takes the first grid it meets, so a file carrying a non-finite grid
  followed by a clean one validated green while decoding entirely through the broken one. Each
  record is now checked as it is walked, and the report names which copy when there is more than
  one. A test now runs both validators over the same bytes — including the duplicate-record case —
  and requires their findings to match line for line, so the mirror cannot drift again without
  saying so.

### Added

- `Error::InvalidInput`, for a scene the encoder cannot write a conforming file from. The mirror of
  `Malformed`: that describes a file that arrived broken, this describes one that never should have
  been offered. It maps to `FOURDGS_STATUS_INVALID_ARGUMENT`, which already existed in the C header,
  so the ABI does not move.

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
