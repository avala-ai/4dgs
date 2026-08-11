# Changelog

All notable changes to the TypeScript packages are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The four packages version together.

## [Unreleased]

### Added

- `reconstructKeyframeDelta` in `@4dgs/core`: the full population at an instant of a
  `keyframe-delta` sequence — gaussian ids, centres, scales, rotations, linear RGB, marginal-folded
  opacity, and object membership where a chunk carries it — in ascending `gaussian_id` order (spec
  §11.7). `keyframeDeltaChunkAt` answers the seek that precedes it: the chunk whose half-open
  `[t0, t1)` contains `t`. Until now the package published only `keyframeDeltaStatesJson`, which
  samples positions and scales for the cross-SDK statement, so the first renderer written against
  this package had to reimplement §11.7 to get every attribute of every gaussian.
- `dequantizeRotation` accepts a `Float64Array` output as well as a `Float32Array`.
- `ATTRIBUTE_CHANNELS`, the interleaving width the registry gives each attribute id it defines.
- **Refusals say which rule was broken.** Every error in `@4dgs/core` now carries an optional
  `refusalCode`, and the six identifiers the specification's refusal table names — `magic-mismatch`,
  `unsupported-major-version`, `unknown-temporal-model`, `unknown-quantization-scheme`,
  `unknown-stream-codec`, `window-index-out-of-range` — are exported as the `Refusal` constants
  rather than written as literals at the raise sites, because six implementations are compared on
  those strings. The class alone was too coarse to compare on: `UnsupportedCodec` covers an unknown
  temporal model, an unknown quantization scheme and an unknown stream codec alike, so "it threw
  `UnsupportedCodec`" cannot tell a decoder that refused for the right reason from one that refused
  for the wrong one. `undefined` means "a real error the refusal table does not name", not "no
  error". This is additive: `refusalCode` is a property on the existing `FourdgsError` rather than a
  new subclass, so every `instanceof` check keeps working.

### Changed

- `keyframeDeltaStatesJson` is now computed from `reconstructKeyframeDelta` rather than from a
  second private reconstruction, so the statement the SDKs are diffed on is exactly the rows a
  consumer gets. Its `states[].liveCount` is the count of gaussians the reconstruction returns
  rather than the chunk's composed population, which matches the Python reference.
- A gaussian outside its own validity window is absent from a reconstructed instant rather than
  present at full opacity: outside the window a gaussian does not exist at that time (spec §3),
  which is how the `gaussian-birth` path has always decided it. Unobservable on files that carry one
  full-duration window, which is every keyframe-delta file in the corpus today.

### Fixed

- **An attribute stream whose `channels` is not the width the registry gives it is refused**, on
  both the `gaussian-birth` chunk path and the `keyframe-delta` composition path. Every reader of
  these bins indexes with a fixed stride, so a `rotation` column declaring one channel and the right
  element count read the next row's bin as this row's second component — and `undefined` past the
  end, which arithmetic turns into a `NaN` quaternion rather than into a refusal. The rule was
  enforced for `object_id` alone, where a wrong width would have shifted every gaussian's
  membership; `ATTRIBUTE_CHANNELS` now states it once for every attribute the registry names.
- **A birth that introduces `object_id` no longer misaligns the column it introduces.** Membership
  is optional per chunk and its omission means `0` (§6.6), so a background keyframe without the
  stream followed by a delta birth that has one is a legal file. Composed without a default for the
  rows already in the state, the merged column was `birth_count` rows long against the whole
  population: the birth's membership landed on a gaussian that was already there, and the birth
  itself read past the end as `0`. The rows that came before an introduced column now carry the
  omission default.
- **A seek past the end of a truncated prefix is refused rather than answered with the last state
  before the cut.** `keyframeDeltaChunkAt` resolves a `t` at or past the end of a _complete_
  timeline to the last chunk, which is the boundary convenience a player wants; on a streamed prefix
  of a truncated file (§11.10) the last decodable instant is the last complete chunk's `t1`, and
  reporting the state before the cut as the state after it is a decoder inventing content. The
  indexed path already refused it.
- **A file whose magic is corrupted anywhere but the version byte is no longer reported as an
  unsupported version.** `checkMagic` tested only that bytes 1-4 read `4DGS`, so flipping the
  leading `0x89` sentinel — the byte that stops byte-oriented tooling treating a 4dgs file as text —
  produced "4dgs major version 1 is not supported by this reader". That sends the file's holder
  looking for a newer reader, which would not have helped. The version byte must now be the only
  difference. Python's reader carries a comment about making exactly this mistake; nothing inside
  TypeScript could see it, because both answers are an `UnsupportedVersion` with a sentence.

### Removed

- `KeyframeDeltaState.column()` and `KeyframeDeltaState.attributes()`, which were exported and
  marked `@internal`. Composed bins are not public API; `reconstructKeyframeDelta` is the supported
  way to values, and the bins are now a JavaScript private field so the boundary is enforced rather
  than documented.

## [0.4.0] - 2026-08-10

### Added

- Native object-layer decode in `@4dgs/core` (spec §5.15.6–§5.15.7, §6.6): `parseObjectTable` and
  `parseObjectTrack` read the two records, the `object_id` attribute stream (id 14) is decoded onto
  `GaussianSet.objectId`, and `ObjectLayer` composes an object's SE(3) track onto reconstructed
  state — `center = R * c0 + T`, `orientation = R ⊗ r0`, base first. Available on both read paths:
  `Scene.objects` on the streamed path, `readObjects()` on the indexed one, where the records are
  framed at open and fetched only when asked for, as provenance is. A gaussian with `object_id = 0`,
  or whose object has no track, keeps its base state; a scene that carries no layer produces an
  empty `ObjectLayer`, which is a value and not an error.
- `GaussianSet.stateAt` now returns `orientations` and `objectId` alongside centres and opacity, so
  a caller can compose the layer onto a reconstructed instant without re-deriving either.

## [0.3.0] - 2026-07-31

This release adds native `keyframe-delta` decode on both read paths in `@4dgs/core`. Decode still
ends at reconstructed gaussian state; rendering and player policy remain outside the package. The
LOD proposal is documentation only and is not advertised here. Version 0.2.0 was prepared in-repo
but never published to npm; 0.3.0 is the first post-0.0.1 registry cut that includes that work plus
keyframe-delta.

### Added

- Native `keyframe-delta` decode in `@4dgs/core`, both read paths. `decodeKeyframeDeltaStreamed`
  composes each chunk onto the state it references front to back; `decodeKeyframeDeltaIndexed` walks
  only an instant's chain from the index. Composition is bin-difference and telescopes (spec §11);
  GOP-invariant attributes are banned from updates and rotation is restated absolutely.
  `keyframeDeltaStatesJson` emits the canonical reconstruction-at-an-instant the SDKs are diffed on.
  Decode only this milestone — there is no keyframe-delta encoder in TypeScript yet.

### Fixed

- **Keyframe-delta decode hardening.** Velocity-grid pitch for a never-fading gaussian comes from
  that gaussian's own validity window (§6.3); out-of-range window indices name the chunk byte and
  gaussian ID. Chunk-level compression is honoured for both Chunk and Delta Chunk records, including
  declared-size validation for uncompressed blocks. Update/birth/death group counts, cross-level
  references and duplicated Delta Chunk/index fields are validated. Streamed decoding remains usable
  on complete truncated prefixes; the indexed path requires full timeline coverage once a Footer is
  found. Canonical probes are bounded to the last complete streamed chunk without argument
  spreading.

## [0.2.0] - 2026-07-29

Prepared in the repository; not published to npm (no trusted publisher configured). The section is
kept so the notes match the code that carried this version number.

### Added

- `@4dgs/core`: `encodeScene`, a native TypeScript encoder — not a binding, a second implementation,
  so a browser can author a `.4dgs`. It quantizes every attribute onto the grids the reference does,
  partitions gaussians into the same deterministic chunk tree, and writes the index, the summary and
  the CRC, including per-band spherical harmonic bit depths. `deflate` is reached through
  `CompressionStream`, the mirror of the decoder's `DecompressionStream`, so the package keeps no
  dependency and runs in a browser. The cross-language encode gate re-encodes every corpus variant
  and requires the Python decoder to read the result the same as the Rust reference.
- Native multiple-source spatial audio in `@4dgs/core`, including moving position and quaternion
  rotation, independent timing, gain and looping. `audioSourceStateAt` reconstructs source facts at
  scene time `t`; listener-relative rendering remains a player concern.
- `IndexedDecoder.readAudioSourceDescriptors`, `readAudioSourceState` and `readAudioRange`, so
  players can inspect and schedule audio without transferring whole encoded payloads.
- `decodeScene` returns the same small descriptors and delivers `Audio Data` through the awaited
  `onAudioData` callback in block-sized pieces, so front-to-back decoding never retains every source
  payload.
- Audio Source and Audio Data parsing on both read paths, with legacy Audio records normalized to a
  single non-spatial compatibility source.

## [0.1.0] - 2026-07-29

The first release of the TypeScript packages, and the first cut from a tag. The four packages
version together, so `@4dgs/core`, `@4dgs/browser`, `@4dgs/nodejs` and `@4dgs/codecs` are all 0.1.0
and each depends on the others at that version.

_Fixed_ and _Changed_ below describe behaviour that changed against the pre-release code in this
repository, which people do vendor from git — not against `0.0.1`, which held the `@4dgs` scope on
npm and contained nothing.

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

- `@4dgs/core`: the window-table parser allocated its output from the record's declared count before
  reading a byte, so a corrupt count named a 68 GB allocation and crashed a memory-limited runtime
  instead of refusing the file. The count is now proven against the bytes that remain first. The
  chunk-level `uncompressedSize` had the same shape on the decompression path and is now held to the
  same cap as a stream's.
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

## [0.0.1] - 2026-07-28

Name reservations, published by hand before the release workflow existed: npm refused the unscoped
`4dgs`, so the `@4dgs` scope was claimed before there was anything to put in it. All four packages
contain no implementation, have no tag and no GitHub Release, and nothing should depend on them.
