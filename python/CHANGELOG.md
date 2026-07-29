# Changelog

All notable changes to the Python package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Package skeleton and layout.
- `WriteOptions.cutoff`, so a file can declare a marginal threshold other than the default. It is
  not decoration: the cutoff sets the support constant the per-gaussian velocity grid is derived
  from, so encoder and decoder have to agree on it.
- `WriteOptions.record_trailers`, which appends bytes to a record's content the way a later minor
  revision would add a field. Used by the conformance corpus to write a file that a reader must step
  over rather than stop at.
- The streamed reader decodes spherical harmonic bands, verifies the Footer's summary CRC, and
  collects Summary Offset records. It saw all three already; it now reads them.
- The indexed reader frames the front-matter records it does not parse and exposes `read_camera`,
  `read_metadata` and `read_attachments`, each costing exactly its own bytes.

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
