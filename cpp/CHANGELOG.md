# Changelog

All notable changes to the C++ package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`keyframe-delta` encode** (spec §11):
  `fourdgs::encodeKeyframeDeltaSequence(samples, durationSec, options)`, with `KeyframeDeltaSample`
  — a `t0`, a `gaussian_id` stream and a `GaussianView`, all borrowed for the call — and
  `KeyframeDeltaOptions` for cadence, delta mode, forced keyframe indices, quantization profile,
  cutoff, `library` and codec. A separate entry point from `encodeScene`, not an option on it: the
  model is a sequence of populations with correspondence between them rather than one population of
  independently-lived gaussians, so it takes samples rather than gaussians.

  Like the rest of this package it is a binding, not a second encoder. The model's arithmetic
  belongs to the core, reached through the `fourdgs_kd_writer_*` exports the layer below adds — a
  delta is a difference of quantization bins against its reference chunk and never a quantization of
  a difference (§11.7), rotation is restated absolutely, and `sigma_t`, `flags` and `window_index`
  never reach an update group (§11.5). The binding stages options and columns and copies bytes out;
  it computes nothing. What it does check is the one thing the ABI cannot see, because that call
  takes a single count for both: a sample whose id stream and gaussian columns are different lengths
  is refused here, where both lengths are still in hand, rather than silently renaming gaussians.

  `cpp/conformance/encode_keyframe_delta` writes three sequences — chained, keyframe-referenced, and
  the cadence-one shape §11.11 says subsumes `frame-sequence` — each with births, deaths, updates
  and ids rotated within every sample so that a writer pairing gaussians by row rather than by
  identity could not pass. `cpp/keyframe-delta-roundtrip.sh` then makes four claims about each: the
  file is inside the bounds its own declared grid pitches promise against the population that went
  in; the C++ and Python decoders read it to the same canonical `states`; every count its chunk
  index declares matches the records it points at; and, given the same samples and options, it is
  byte for byte the file the Rust reference writer produces — which is the claim a binding is
  actually making. The feature matrix's `Encode keyframe-delta` cell for C++ moves from `Planned` to
  `Yes` on that suite (issue #122).

## [0.1.0] - 2026-08-10

### Added

- A CMake package another project can consume. The install already exported its targets under the
  `fourdgs::` namespace but generated no config file, so `find_package(fourdgs-cpp)` could not
  succeed against it — the install rules produced something nothing could find. It now installs
  `fourdgs-cpp-config.cmake` and `fourdgs-cpp-config-version.cmake` beside the targets file, so a
  version request is answerable (`SameMinorVersion`, which is what a 0.x compatibility promise
  means). `fourdgs::cpp` names the library whether it arrived through `find_package` or
  `add_subdirectory`, and the tests, conformance runners and examples build by default only when
  this is the top-level project, so consuming the package no longer adds them to somebody else's
  build. `cpp/README.md` documents the three consumption paths, including the `SOURCE_SUBDIR cpp`
  argument that a `CPMAddPackage` needs and nobody would guess: this repository has no CMakeLists at
  its root, and without that argument the fetch silently adds nothing.
- `fourdgs::version()` now reports the version the CMake project declares, compiled in from
  `PROJECT_VERSION` rather than written out a second time. It returned `"0.0.0"` while the package
  answered `find_package(fourdgs-cpp 0.1)`, so an application reporting the linked SDK version and
  the build that resolved it disagreed.
- A `4dgs` command-line tool (`cpp/tools/`, built as `cpp/build/tools/4dgs`) with two commands.
  `inspect` walks the file record by record — offset, opcode name, content and total length, and the
  CRC status of the region each record sits in — reading nine bytes per record, so it costs the same
  on a file carrying an hour of audio as on one carrying none. `validate` checks the file and, when
  it is refused, prints the refusal identifier **and the byte it fired at** beneath the finding it
  belongs to: `refusal unknown-stream-codec at byte 659 (the Chunk record at index entry 0)`. All
  seven variants of the invalid corpus are refused by the identifier their expectation file
  declares, at the same bytes the Rust tool reports.
- `validate` decodes the chunks, one resident at a time on the indexed path. A framing walk steps
  _over_ a chunk by its declared length, which is exactly not looking inside it — so
  `unknown-stream-codec` and `window-index-out-of-range` are reachable at all only by decoding, and
  a framing-only validator calls those two files valid.
- **Every spherical-harmonic band the file declares is decoded, not just band 0.** Each band is its
  own record with its own stream header, addressed by byte range so a reader that has capped its
  degree never transfers the higher ones — which is what hid them from a validator scanning at band
  0, and what let a file whose band 2 will not decode come back `valid`, exit 0. When a band
  refuses, the byte names _that band's own record_, narrowed by raising the cap until the fetch
  starts failing, on the failure path only.
- Both commands read byte ranges rather than the file. `inspect` transfers nine bytes per record
  plus the checksummed region, and `validate` opens the scene over the same transport instead of
  handing the core a buffer it would copy — so neither holds a capture whose size it does not
  control. The one exception is a `keyframe-delta` file, because
  `fourdgs_keyframe_delta_states_json` takes `(const uint8_t*, size_t)` and the C ABI offers no
  range-reading counterpart.
- `validate` branches on the Header's declared `temporal_model`, so a conforming `keyframe-delta`
  file is validated by the reader its model needs instead of producing errors from the
  gaussian-birth chunk shape it does not have.
- A truncated file is walked as far as it goes and then reports the cut: the byte, the record's
  declared length against the file's size, and how many complete records before it a streamed reader
  keeps. `inspect` prints it beneath the table and `validate` adds it as a note beside its errors.
- Exit codes a pipeline can act on: `0` fine, `1` refused or invalid, `2` valid with warnings, `3`
  the tool could not run. The last is the one that matters — a missing file, an unrecognized
  argument, or a build with no decoder behind it is the absence of an answer, not a verdict on a
  file, and a tool that exits `1` for both is indistinguishable from a broken one.
- Refusal diagnosis: `fourdgs::Error::refusal` names _which_ rule refused a file — `magic-mismatch`,
  `unsupported-major-version`, `unknown-temporal-model`, `unknown-quantization-scheme`,
  `unknown-stream-codec`, `window-index-out-of-range` — in the same words every other SDK prints.
  `ErrorCode` says what kind of thing went wrong and `kUnsupported` alone covers three of those six,
  so the code could not answer the question. A `std::optional`, and empty for every failure the
  specification's table does not name: a truncated file and a transport that gave up are real errors
  with no rule behind them. Additive, so existing catch sites are unchanged. Read across the C ABI
  from `fourdgs_last_refusal_code` as a (pointer, length) pair and copied by length — the string is
  not NUL-terminated, and reading it as though it were is the ABI bug that shape exists to prevent.
- The `decode_streamed` and `decode_indexed` conformance runners answer a refused file with
  `{"refused": "<identifier>"}` on stdout and exit 0, so the suite can tell "refused the file" from
  "refused it for the right reason" — a decoder that rejects a bad-magic file because it mis-parsed
  the version passes the first and fails the second. `cpp` joins `REFUSAL_FAMILIES`, and the
  seven-variant invalid corpus is read on both paths: the suite goes from 105 checks to 119.
- keyframe-delta decode: `fourdgs::keyframeDeltaStatesJson` and `fourdgs::peekTemporalModel`,
  binding the core's additive states-JSON C ABI. The summary is computed in the Rust core, so the
  binding does no arithmetic of its own; the `decode_streamed` and `decode_indexed` conformance
  runners peek the temporal model from the bytes — an opened `Scene` refuses the model — and print
  the core's JSON verbatim on each read path. The suite now passes the four keyframe-delta variants
  both ways.
- The encode surface: `fourdgs::encodeScene`, binding the core's `fourdgs_writer_*` C ABI, so the
  package authors files through the same core it decodes through rather than a second encoder. A
  `test_writer` unit test builds a tiny scene, encodes it and reopens the bytes, and an
  `encode_roundtrip` conformance runner re-encodes each variant's gaussians for the cross-language
  gate, which requires the Python decoder to read the binding's output the same as the Rust
  reference's.
- Multiple spatial `AudioSource` values with independently timed payloads, fixed or keyframed
  scene-space poses, quaternion rotation, gain and looping. `audioSourceStateAt` reconstructs the
  source state at time `t`; spatialization against a listener remains player-owned.
- Descriptor-only source inspection and bounded payload range reads, plus explicit whole-source
  helpers for callers that have already accepted the validated allocation size.
- The package: a CMake project (`fourdgs-cpp`, target `fourdgs::cpp`), the public C++17 API over the
  spec's data model, `Result<T>` error handling, `Readable` transports, and the two conformance
  runners.
- The binding itself, against the Rust core's C ABI: `Scene` over `fourdgs_scene` with the
  working-set model, `State` over `fourdgs_state`, and a `Readable` bridged into the decoder's
  byte-range callbacks so a C++ transport — a file, an HTTP range reader, a cache — is what the
  decode reads through.
- Unit tests for the temporal arithmetic of spec §3, the error policy, the transports, FFI hygiene
  at the ABI edge, and the canonical JSON — including the property the whole cross-language
  comparison rests on, that reordering a scene's gaussians cannot change one character of its
  summary.

### Fixed

- Configuring without a core no longer depends on which half of the core is missing. The backend was
  chosen from the header alone, and `rust/fourdgs/include/fourdgs.h` is committed while
  `target/release/libfourdgs.a` is a build artifact — so in a fresh checkout, `cmake -S cpp` before
  `cargo build` failed outright and `-DFOURDGS_ALLOW_NO_CORE=ON` could not rescue it, which is the
  configuration that option exists for. The header and the library are resolved together now, and a
  failed search is not cached, so configuring the same build directory again after
  `cargo build -p fourdgs --release` links the core rather than keeping the build that has none.

### Known limitations

An out-of-tree build supplies the Rust core itself: this is a binding over that core's C ABI, and
the core's library is a build artifact, so `FOURDGS_CORE_LIBRARY` (and, for a copy of `cpp/` on its
own, `FOURDGS_CORE_HEADER_DIR`) point at what `cargo build -p fourdgs --release` produced.
Configuring without them outside this repository is now a fatal error naming both, rather than a
STATUS line and a library that refuses every call. Building the core from CMake with Corrosion, or
fetching a prebuilt one, would remove the step; neither is implemented, and the choice between them
is deliberately not being made here.

### Notes

Conformance-verified: 79 checks across the 45 valid variants this binding supports, and the feature
matrix records exactly what that proves. This is the first release: 0.1.0 rather than a number
matched to another SDK's, because the packages version independently and this one has shipped
nothing before.
