# Changelog

All notable changes to the Swift package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Encoding the `keyframe-delta` temporal model**, turning the Swift cell of that row from Planned
  to Yes; C++ is now the only one still Planned.
  `KeyframeDeltaWriter.encode(_:durationSec:options:)` takes a sequence of `KeyframeDeltaSample` — a
  population, at one instant, with identity — and returns the file bytes. `SceneWriter` could
  already author the other model, one population whose gaussians each carry their own birth time;
  what it could not say is the thing this model exists for, the _same_ population restated at a
  sequence of instants with gaussians entering and leaving.

  Like `SceneWriter` this is a binding, and here that is a correctness property rather than a
  convenience. A delta is a **difference of bins, never a quantization of a difference** (spec
  §11.7), which is what makes chained deltas accumulate no error at any depth — and it holds only if
  every sample was quantized up front on grids derived from the whole sequence. So the whole
  sequence crosses the C ABI before anything is encoded, and nothing in Swift subtracts anything. An
  encoder that subtracted here and quantized afterwards would produce a file whose declared bounds
  mean nothing after the second delta.

  `KeyframeDeltaWriteOptions` carries the cadence (`keyframeEvery`, with `keyframeAt` for a cut a
  producer knows about), `deltaMode` — `.chained` for deltas that reference the previous chunk and
  coalesce into one range request, `.keyframeReferenced` for a likely seek target — the bound
  `profile`, `cutoff`, `library` and the stream codec. Refusals arrive as the same typed errors the
  reader throws: an empty sequence, a sample whose ids and gaussians are different lengths, a
  non-finite `sigmaT`, and a gaussian whose `sigmaT` or validity window changes inside a group,
  which is refused rather than written because those values _derive the grid_ a bin difference is
  taken on (spec §11.5) and a file carrying such a change decodes silently into a wrong velocity.

  Proved by `swift/keyframe-delta-roundtrip.sh`, which writes five sequences and requires the Python
  reference and both Swift read paths to agree on every one; four of them are the corpus generator's
  own sequences — the encoder declares which, so a name that drifts is a failure rather than a
  comparison that quietly stops running — and are additionally held to the committed corpus's
  population and geometry. Every written file is also held to its own chunk index: the counts an
  entry declares are not consulted by any reader that composes the chunks it names, so a binding
  that swapped a delta's operation count for its live population would otherwise reconstruct
  identically everywhere and still misstate what a seek costs. Spherical harmonics are not carried,
  so a file written this way declares `sh_degree` 0.

- `4dgs`, the inspect-and-validate tool, turning the Swift cell of that row from Planned to Yes;
  TypeScript, Rust, C++ and Dart still read Planned. `4dgs inspect` walks a file record by record —
  offset, opcode by name, content and total length, and whether the Footer's summary checksum covers
  that record and agrees — and a file that was cut is walked as far as it goes, then reports the
  byte it stopped at and how many complete records before it a streamed reader keeps.
  `4dgs validate` names the refusal identifier and the byte it fired at: all seven invalid corpus
  variants are refused by the identifier their `.json` declares, at bytes 0, 8, 0, 154, 659, 8 and
  2506 — the same bytes the Rust tool prints. Exit codes are 0 valid, 1 refused or invalid, 2 valid
  with warnings, and 3 for the tool could not run, which is the absence of an answer rather than an
  answer about the file.

  The tool is a library plus a three-line executable, so its tests drive the whole of it — arguments
  in, output and exit code out — without spawning a process. It decodes the chunks, and every band
  the index declares rather than band 0: an SH Band Stream carrying a codec this build does not
  implement is a file that does not decode, and a scan that capped the bands would call it valid.
  When one refuses, the byte names that band's own record.

  Being a binding, it validates a strict subset of what the Python validator checks — framing, the
  records a file must carry, where the chunk index points, the summary checksum, and everything the
  reader itself decides. It has no record parsers of its own and does not grow any; the consequence
  is that on a file it calls valid, Python may still have something to say. It never reports a
  finding Python contradicts.

## [0.1.0] - 2026-08-10

### Added

- The package can be depended on. `Package.swift` moved to the repository root, because SwiftPM
  clones the URL it is given and looks for a manifest at the top of that clone — a manifest under
  `swift/` is invisible to `.package(url:)`, so nothing could depend on this package at all. The
  sources did not move; every target names its own path under `swift/`.
- `fourdgsPackageVersion`, the one place this package's version is written, asserted against the
  release tag before anything is built.
- Named refusals: `RefusalCode` gives the six identifiers the specification's refusal table defines,
  and `FourDGSError.refusalCode` answers which rule a file broke — `nil` when the table does not
  name the failure, which truncation and I/O errors legitimately are. The identifier comes from the
  core through `fourdgs_last_refusal_code`, read as the pointer-and-length pair the ABI returns
  rather than as a C string, and rides on three existing cases as a trailing associated value
  defaulted to `nil` — see the breaking-change note below for what that default does and does not
  buy. The `decode_streamed` and `decode_indexed` runners print `{"refused": "<id>"}` and exit 0 for
  a file they refuse, which adds the invalid corpus to Swift's conformance run: 105 comparisons
  become 119.
- keyframe-delta decode: `peekTemporalModel` and `keyframeDeltaStatesJson`, binding the core's
  additive states-JSON C ABI through `CoreSeam`. The summary is computed in the Rust core, so the
  binding does no arithmetic of its own; the `decode_streamed` and `decode_indexed` runners peek the
  temporal model from the bytes — an opened scene refuses the model — and print the core's JSON
  verbatim on each read path.
- The encode surface: `SceneWriter.encode`, binding the core's `fourdgs_writer_*` C ABI through
  `CoreSeam`, so the package authors files through the same core it decodes through. An
  `encode_roundtrip` runner re-encodes each variant's gaussians for the cross-language encode gate,
  which requires the Python decoder to read the binding's output the same as the Rust reference's.
- Multiple spatial `AudioSource` values with independent timing, encoded payloads, gain, looping and
  fixed or keyframed scene-space poses. `audioSourceState(_:at:)` reconstructs moving source state;
  listener-relative rendering remains the app or player's responsibility.
- Descriptor-only source discovery and bounded `audioSourceData` reads, keeping payload allocation
  under caller control and preserving the package's byte-range I/O boundary.
- The package is a real SPM package rather than a skeleton: `FourDGS` for visionOS, iOS and macOS,
  with the value types, errors and readers the spec's data model calls for.
- `StreamedReader` and `IndexedReader`, the two read paths, with `ByteRangeReader` as the single
  abstraction either one needs and `InMemoryReader` and `FileReader` as its transports.
- §3's reconstruction arithmetic — marginal, validity window, centre and opacity at a time `t` — and
  the tests that pin it, including that the cutoff comes from the file's own Header.
- `conformance/`, building `decode_streamed` and `decode_indexed`, registered in
  `tests/conformance/run.py` and skipped until built.
- A canonical-JSON self-test: `canonical_selftest` and `conformance/selftest.py` build the same
  synthetic scene from the same seed in each language, and CI asserts that the Swift emitter and
  `tests/conformance/canonical.py` produce documents that parse equal. It runs with no decoding
  involved, so a conformance mismatch once the ABI lands is about the decode and nothing else.

- The seam is wired: `CFourDGS` imports `rust/fourdgs/include/fourdgs.h` through a module map rather
  than a copied header, `SceneReader` decodes real files over the C ABI, and a Swift
  `ByteRangeReader` is bridged to the core's `fourdgs_reader` callbacks. CI builds the core's
  staticlib for Linux, macOS, **visionOS and iOS** and links against each — a Linux build proves
  nothing about the platforms this package exists for.

### Changed

- **Source-breaking:** `FourDGSError.malformed`, `.unsupportedCodec` and `.core` each gained a
  trailing `refusal: RefusalCode?` associated value. The `= nil` default keeps every _construction_
  compiling, but a default has no bearing on a _pattern_: code that binds these cases with the
  previous arity — `case .malformed(let offset, let record, let field, let reason)` — now fails to
  compile with "tuple pattern has the wrong length", and gains a `_` for the new element. No
  exhaustive `switch` over `FourDGSError` breaks, because no case was added or removed; that is why
  the identifier rides on the existing cases rather than arriving as a seventh one. Nothing is
  released and no package registry entry exists, so nothing depended on the old arity.

- `StreamedReader` and `IndexedReader` are replaced by one `SceneReader`. The ABI opens a file and
  chooses its own read path; two types that could not actually differ would have been a claim the
  code could not keep, and the suite runs two runners precisely so the paths can disagree. They come
  back when the ABI can be told which to use. Nothing is released, so nothing depended on them.

### Notes

The shared suite proves 105 comparisons across the valid variants Swift supports, including fixed,
moving and multiple audio-source scenes. Swift's runners materialize payloads only for canonical
comparison; the public `SceneReader` leaves them deferred.

**This version resolves and does not link out of tree.** There is no Swift registry; the package is
consumed from this repository's URL, at plain `vX.Y.Z` tags, which are the only tags SwiftPM reads.
`FourDGS` binds the Rust core through its C ABI and ships no prebuilt copy of it, so a consumer with
no checkout of this repository has no `libfourdgs` for the linker to find. The manifest emits a
warning saying so, naming what is missing and how to supply it, instead of leaving
`cannot find -lfourdgs` as the whole diagnosis. A `binaryTarget` pointing at a checksummed
`.xcframework` built for visionOS, iOS and macOS is the fix, and is not in this version.
