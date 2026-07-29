# Changelog

All notable changes to the TypeScript packages are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The four packages version together.

## [Unreleased]

### Added

- `@4dgs/core`: the decoder. Record framing that skips unknown opcodes by length, attribute streams
  decoded into typed arrays, the two per-gaussian precision rules recomputed from the sigma bin,
  smallest-three rotations, the colour transform, and spherical harmonic bands merged as whole
  degrees. Two read paths: `decodeScene` front to back in bounded blocks, and `IndexedDecoder`
  reading the index and then only the byte ranges an instant needs.
- `@4dgs/browser`: `BlobReadable` and `HttpRangeReadable`, the latter detecting a server that
  ignores `Range` rather than trusting it.
- `@4dgs/nodejs`: a file-handle readable with pread semantics, and a writable.
- `@4dgs/codecs`: zstd, kept out of the core so a browser bundle that will never meet a zstd file
  does not carry the machinery for one.
- The streamed path verifies the Footer's summary CRC: it has seen the bytes the CRC covers, so it
  retains the summary region until the Footer says where that region began.
- `IndexedDecoder.readCamera`, `readMetadata` and `readAttachments`, each fetching exactly its own
  record.

### Fixed

- `IndexedDecoder.open` could not open a file whose front matter held a record larger than its 64
  KiB probe — the same bug the Python reader had, found by the same corpus variant. The walk now
  steps over a record by arithmetic and fetches only what it wants.

### Changed

- **A window index outside the Window Table is refused rather than clamped**, matching the
  specification's rule. A reader that relied on the old behaviour will now see `MalformedFile`.
