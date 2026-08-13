# Changelog

All notable changes to the TypeScript packages are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The four packages version together.

## [Unreleased]

## [0.5.0] - 2026-08-12

### Added

- `reconstructKeyframeDelta` in `@4dgs/core`: the full population at an instant of a
  `keyframe-delta` sequence — gaussian ids, centres, scales, rotations, linear RGB, marginal-folded
  opacity, spherical harmonics, and object membership where a chunk carries it — in ascending
  `gaussian_id` order (spec §11.7). `keyframeDeltaChunkAt` answers the seek that precedes it: the
  chunk whose half-open `[t0, t1)` contains `t`. Until now the package published only
  `keyframeDeltaStatesJson`, which samples positions and scales for the cross-SDK statement, so
  consumers had to reimplement §11.7 to get every attribute of every gaussian.
- `dequantizeRotation` accepts a `Float64Array` output as well as a `Float32Array`.
- `ATTRIBUTE_CHANNELS`, the interleaving width the registry gives each attribute id it defines.
- `KeyframeDeltaIndexedDecoder`, a range-backed `IReadable` seek for `keyframe-delta` files. Opening
  reads bounded front-matter and summary windows; `reconstructAt(t)` fetches and composes only the
  index chain and spherical-harmonic ranges needed for that instant.
- **A `4dgs` command-line tool, in `@4dgs/nodejs`.** `4dgs inspect <file>` walks the file record by
  record and prints opcode, byte offset, content and total length, and whether the file's own
  summary checksum covers that record — framing only, so it costs the same on a scene carrying a
  six-megabyte audio payload as on one carrying none. `4dgs validate <file>` runs the structural
  checks, and every check, severity and sentence it composes is
  `python/fourdgs/fourdgs/validate.py`'s: over the whole 60-file conformance corpus the two tools
  print identical findings, and the two remaining differences are sentences the libraries raise
  rather than the validators write. `--json` gives `inspect` a machine-readable form; `--decode`
  gives `validate` the two refusals that live inside a chunk's attribute streams, where no amount of
  framing reaches them. The tool lives in `@4dgs/nodejs` because it opens files and I/O lives at the
  edges; `inspectFile` and `validateFile` are exported, so anything the tool can do a caller can do
  in process. Also exported: `bytesEqual` from `@4dgs/core`, which the walk needs to recognize a
  trailing magic.
- **A refused file is named by rule and by byte.** Both commands print
  `refused: <identifier> at byte <n> (<what sits there>)` —
  `unknown-quantization-scheme at byte 154 (the Quantization record)` — using the `Refusal`
  identifiers below. All seven files in the invalid conformance corpus are answered this way, each
  with the identifier the corpus expects.
- **Exit codes a pipeline can act on.** `0` fine, `1` refused or invalid, `2` valid with warnings,
  `3` the tool itself failed. The third is the one that is not the Rust tool's: exiting `1` both for
  "I read this file and it does not conform" and for "I fell over" makes a verdict about a file
  indistinguishable from a broken validator, and those need opposite reactions from whoever is
  holding the file.
- **A truncated file is reported, not thrown.** `inspect` names every record that was complete
  before the cut, with the offsets and lengths it has in the whole file, and then says where the cut
  is; `validate` prints what the Python validator prints for the same file, byte for byte.
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
- **`keyframe-delta` encode in `@4dgs/core`** (spec §11), closing the last writer gap on the
  TypeScript side: `encodeKeyframeDeltaSequence(samples, durationSec, options)` takes a sequence of
  populations with identities and writes a whole file — Header, Quantization, Window Table, a
  keyframe Chunk or a Delta Chunk per sample, the extended Chunk Index, Statistics and the Footer.
  `KeyframeDeltaWriteOptions` carries cadence (`keyframeEvery`, `keyframeAt`), `deltaMode`, the
  quantization profile and cutoff, and which summary records to write. Shared grids are derived in
  bounded passes over the sequence, then only the current population and its reference are quantized
  at once; a delta is an integer subtraction between bins on one grid, the composition telescopes,
  and the declared bound holds at any depth.
- A gaussian is written into a delta only when one of its bins moved, so an unchanged gaussian costs
  no bytes — the property the model exists to buy. Rotation is restated absolutely rather than
  differenced, because the smallest-three basis changes with the largest component.
- The writer refuses what it cannot honestly write, naming the field and the sample: a timeline that
  does not tile `[0, duration_sec)`, a non-finite duration, an id list that does not match the
  population, falls outside `u32`, repeats an id or reuses one after death, a chained depth that
  cannot fit its `u16` field, a `delta_mode` outside `{0, 1}`, an unknown profile, a non-positive or
  non-finite `sigma_t`, an absolute bin outside `i32`, spherical harmonics (which are never silently
  dropped even when their degree metadata is missing), and a GOP-invariant attribute — `sigma_t`,
  `flags`, `window_index` — that changes mid-group, where a bin difference would subtract bins
  living on two different grids and decode into a wrong value rather than into an error. Valid
  gaussian ids use the complete `u32` domain through the stream codec's signed two's-complement
  bridge, and each sample's `mu_t` is anchored to that sample's timestamp as §11.3 requires.
- **`parseQuantization` reads the appended per-band SH bit depths** into `Quantization.shBitDepths`,
  as the Python and Rust readers already did — TypeScript wrote the field in `encodeScene` and was
  the only reader that could not read it back. `shStep` and `shBound`, the pitch and bound a depth
  implies, move out of the writer and are exported from `@4dgs/core` alongside `SH_MIN_BITS` and
  `SH_MAX_BITS`. Reading it is deliberately tolerant: appended fields are positional, so a count the
  record is too short for, or a depth outside 3..8, is read as "this file declares none" rather than
  as a corrupt file (§5.3).

### Changed

- `keyframeDeltaStatesJson` is now computed from `reconstructKeyframeDelta` rather than from a
  second private reconstruction, so the statement the SDKs are diffed on is exactly the rows a
  consumer gets. Its `states[].liveCount` is the count of gaussians the reconstruction returns
  rather than the chunk's composed population, which matches the Python reference.
- A gaussian outside its own validity window is absent from a reconstructed instant rather than
  present at full opacity: outside the window a gaussian does not exist at that time (spec §3),
  which is how the `gaussian-birth` path has always decided it. Unobservable on files that carry one
  full-duration window, which is every keyframe-delta file in the corpus today.
- `ObjectLayer.apply` accepts either `Float32Array` or `Float64Array` centres and orientations, so
  object tracks compose directly onto `keyframe-delta` reconstruction without a narrowing copy.
- `writer.ts` now exports its quantization and record-framing internals (`rint`, `median`,
  `quantizeRotation`, `rctForward`, `ByteWriter`, `putStrMap`, `record`, `encodeStream`) as
  `@internal`, so both encoders share one arithmetic instead of restating it. They are not
  re-exported from the package entry point and are not API.

### Fixed

- **An attribute stream whose `channels` is not the width the registry gives it is refused**, on
  both the `gaussian-birth` chunk path and the `keyframe-delta` composition path. Every reader of
  these bins indexes with a fixed stride, so a `rotation` column declaring one channel and the right
  element count read the next row's bin as this row's second component — and `undefined` past the
  end, which arithmetic turns into a `NaN` quaternion rather than into a refusal. The rule was
  enforced for `object_id` alone, where a wrong width would have shifted every gaussian's
  membership; `ATTRIBUTE_CHANNELS` now states it once for every attribute the registry names.
- **SH Band Stream dimensions are checked before payload decode.** A constant stream can expand a
  handful of symbols into its declared row count, so band, width, and chunk row count are now
  compared before an untrusted declaration can allocate hundreds of megabytes.
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
- **`4dgs` runs when it is invoked through the symlink npm installs.** `bin` is linked into
  `node_modules/.bin`, and Node reports the link path in `process.argv[1]` while resolving
  `import.meta.url` through it, so the entry-point comparison was false for every installed
  invocation: the advertised executable printed nothing and exited `0`, which a pipeline cannot tell
  from success. Both ends are now resolved before they are compared.
- **`inspect` fails a file that does not end with the magic.** A file cut inside its own closing
  magic framed every record, so nothing reported a stop, and the walk exited `0` with a note — while
  `validate` called the same file truncated and refused it. The walk now says which bytes are not
  the magic, and a missing magic is a failing exit code in either shape.
- **`validate --decode` decodes SH Band Streams.** Framing steps over these records, so a band
  declaring a codec this build does not have, or carrying a cut payload, was reported valid by the
  validator and refused by this package's own streamed decoder. Both refusals a chunk's streams can
  raise are reachable from a band's stream, and `--decode` now reaches them.
- **`validate` checks the records it was stepping over.** The provenance and object-layer records
  are parsed for the cross-record rules `scene.ts` already enforces and the Python validator already
  checks — a duplicate name, a sensor posed against a rig the file does not carry, two tracks moving
  one object, a second Object Table — so a file this package cannot decode is no longer reported as
  conforming. The per-band SH bit depths are checked against the Header's degree and the declared
  bounds (§6.5), which the Python and Rust validators both do.
- **Four normative rules a structural pass could not see.** The Footer must be the last record (§4);
  Header flag bits 2-7 are reserved and must be zero (§4.2) — the same rule the parser already
  applies to an Audio Source's flags; the summary is exactly the Chunk Index, Statistics and Summary
  Offset records, contiguous (§4.5), which its checksum cannot answer because a writer that smuggles
  a record in there recomputes it; and a chunk index entry frames a whole record (§5.8), without
  which an entry with a plausible offset and a wrong length passes validation and makes the seek
  path unusable.
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
