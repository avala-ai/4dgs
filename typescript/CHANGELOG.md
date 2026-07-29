# Changelog

All notable changes to the TypeScript packages are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The four packages version together.

## [Unreleased]

### Fixed

- `@4dgs/core`: the window-table parser allocated its output from the record's declared count before
  reading a byte, so a corrupt count named a 68 GB allocation and crashed a memory-limited runtime
  instead of refusing the file. The count is now proven against the bytes that remain first. The
  chunk-level `uncompressedSize` had the same shape on the decompression path and is now held to the
  same cap as a stream's.

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
- A fuzz suite holding one invariant: for any input at all, the decoder either succeeds or throws a
  `FourdgsError` — never a `RangeError` from a transport, never unbounded allocation, never a hang.
  It shares its generator and its mutation operators with the Python fuzzer seed for seed, so a
  crash found by one implementation reproduces in the other from two integers.
- A browser smoke test that decodes corpus fixtures in a real headless Chrome, through both
  `BlobReadable` and `HttpRangeReadable` against a server answering `206 Partial Content`, with the
  browser's own `DecompressionStream` doing the inflating. Node can prove the decoder decodes; it
  cannot prove either of those two things, which is why they were previously unproven.

### Fixed

- **Crash classes found by fuzzing.** A corrupt payload escaped as whatever the runtime's inflater
  throws — a `TypeError` from Node's `DecompressionStream` — and a chunk, band, audio or record
  range pointing outside the file escaped as a `RangeError` from the transport. Both are
  `MalformedFile` now. The same fuzzer found a denial of service shared with the Python decoder: a
  constant-mode stream declaring 2^30 elements expanded a one-byte payload into gigabytes, because
  the size cap bounded what arrives rather than what it becomes.
- `IndexedDecoder.open` could not open a file whose front matter held a record larger than its 64
  KiB probe — the same bug the Python reader had, found by the same corpus variant. The walk now
  steps over a record by arithmetic and fetches only what it wants.

### Changed

- **A window index outside the Window Table is refused rather than clamped**, matching the
  specification's rule. A reader that relied on the old behaviour will now see `MalformedFile`.
