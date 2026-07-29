# Changelog

All notable changes to the Python package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-07-28

The first release of the Python reference implementation, and the first cut from a tag. It is what
the specification is checked against: where the two disagree, the conformance suite decides which
one is wrong.

_Fixed_ and _Changed_ below describe behaviour that changed against the pre-release code in this
repository, which people do vendor from git — not against `0.0.1`, which held the name on PyPI and
contained nothing.

### Added

- The reader. Every top-level structure is a length-prefixed record with an opcode, so an
  unrecognized record is stepped over rather than fatal. Two read paths, neither an optimization of
  the other: `read()` walks a file front to back in bounded blocks and works on a pipe or a
  truncated file, and `open_indexed()` reads the index and then only the byte ranges an instant
  needs.
- Gaussian state at a time `t`: per-gaussian birth, velocity, temporal extent and validity window,
  the two precision rules recomputed from the sigma bin, smallest-three rotations, the colour
  transform, and spherical harmonic bands merged as whole degrees. `state_at()` is where decoding
  ends — nothing here renders.
- The writer, `write()` with `WriteOptions`. It optimizes for a file that is easy to reason about
  rather than for size or throughput, and verifies its own stated error bounds by decoding what it
  wrote.
- `WriteOptions.cutoff`, so a file can declare a marginal threshold other than the default. It is
  not decoration: the cutoff sets the support constant the per-gaussian velocity grid is derived
  from, so encoder and decoder have to agree on it.
- `WriteOptions.record_trailers`, which appends bytes to a record's content the way a later minor
  revision would add a field. Used by the conformance corpus to write a file that a reader must step
  over rather than stop at.
- Audio, a camera trajectory, metadata and attachments as front-matter records. On the indexed path
  each costs exactly its own bytes to read, through `read_camera`, `read_metadata` and
  `read_attachments`; the streamed reader decodes spherical harmonic bands, verifies the Footer's
  summary CRC and collects Summary Offset records.
- `validate()`, and `fourdgs validate` over it: structural validation where every finding names the
  record, the field and what was expected. This is what makes a third-party encoder possible —
  finding out why a file is wrong without reading this decoder.
- `convert_ply_sequence()`, and `fourdgs convert` over it: a directory of per-frame gaussian splat
  `.ply` files becomes one continuous scene, each frame's gaussians taking that frame's slot as
  their validity window and velocities fitted across the frames a gaussian appears in.
- `fourdgs info` and `fourdgs decode`, thin enough over the library that anything the CLI can do a
  caller can do. `info` reports what seeking costs: the bytes needed to display an instant.
- Errors that name the problem — `MalformedFile`, `TruncatedFile`, `UnsupportedCodec`,
  `UnsupportedVersion` and `BoundViolation`, all under `FourdgsError` — so a file that is malformed
  is distinguishable from one that is merely newer.
- Conformance runners under `python/conformance/`, which decode the generated corpus and print the
  canonical JSON the suite compares across SDKs.

### Fixed

- `open_indexed` raised `ValueError` — not a `FourdgsError` — on a footer whose `summary_start`
  points past the footer itself, so `validate` could not catch it and a malformed file crashed the
  tool meant to diagnose it. It is now a `MalformedFile` naming both offsets.
- `open_indexed` could not open a file whose front matter held a record larger than its 64 KiB
  probe. An Audio record lives in the front matter, so any scene with a real soundtrack failed — on
  the seekable path, on the format's flagship case. The walk now steps over a record by arithmetic
  and fetches only what it wants.
- A chunk's `compression` field was parsed and then ignored, so a conforming chunk-compressed file
  decoded to garbage instead of either working or failing. It is now honoured, and an unrecognized
  codec is refused by name.
- The velocity precision grid used the default cutoff rather than the file's own, so any file
  declaring a different threshold decoded velocities the encoder did not write. `state_at` had the
  same assumption in its visibility test.
- A file whose trailing magic is missing is now reported as truncated rather than as complete.

### Changed

- **A window index outside the Window Table is refused rather than clamped.** Clamping substituted
  one gaussian's lifetime for another's in a file that was already corrupt, turning a detectable
  fault into plausible wrong output. Files written by this encoder are unaffected; a reader that
  relied on the old behaviour will now see `MalformedFile`.
- A file with no Window Table, or an empty one, reads as a single `(0, 0)` window. That was already
  the behaviour; it is now the documented one.

## [0.0.1] - 2026-07-28

A name reservation, published by hand before the release workflow existed: `4dgs` on PyPI belongs to
an unrelated project, so `fourdgs` was claimed before there was anything to put in it. It contains
no implementation, has no tag and no GitHub Release, and nothing should depend on it.
