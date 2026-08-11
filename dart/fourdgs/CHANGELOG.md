# Changelog

All notable changes to the Dart package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Prepared, not published. The heading carries the version rather than `Unreleased` because
`pubspec.yaml` already declares 0.1.0 and pub refuses to pack a package whose changelog does not
mention its own version — and because the release gate extracts this section as the release notes,
so it has to exist before the tag rather than after it. There is no date: the release has not
happened.

### Hostile-input hardening

The decoder refuses a class of file it previously accepted — values that decode into
plausible-looking output rather than an error, so nothing downstream notices:

- **Header.** A spherical-harmonic degree outside the 0-3 registry, a temporal model this build does
  not implement (`gaussian-birth` and `keyframe-delta` are accepted; anything else is named rather
  than assumed), a NaN or negative duration, and a cutoff outside `(0, 1]`. Zero duration stays
  legal — a zero-duration scene is a real fixture — and so does `+Infinity`, which is how an
  open-ended scene declares itself.
- **Chunk and Delta Chunk intervals.** The same rule the Chunk Index gets, applied where a chunk
  states its own interval. Without it the streamed keyframe-delta path, which never reads the index,
  accepted a file the indexed path refused.
- **Validity windows and chunk-index intervals.** NaN or inverted bounds on both. Visibility is
  gated on `lo <= t < hi`, so a NaN bound is false at every instant and the content behind it
  silently never appears. `lo == hi` stays legal.
- **Chunk index.** A nonempty chunk over a zero-width interval. The seek rule is half-open, so
  nothing can ever select it, yet its gaussians still count toward the file's total. For a
  `keyframe-delta` entry the population is `liveCount` rather than the operation count, so that rule
  is applied by the readers, which know the temporal model — the record parser sees the appended
  block by length alone and cannot tell a delta entry from fields a later revision adds. All three
  read paths apply it, including the dedicated keyframe-delta opener. The record parser applies it
  only to an entry with no appended block, where `gaussianCount` is unambiguously a population: a
  delta that only removes gaussians declares its removals there and a `liveCount` of zero, and is
  empty despite the count.
- **Keyframe-delta index.** A `chunk_kind` other than 0 or 1 — not a forward-compatible extension
  but a chunk that cannot be placed in a chain, and one the population rule and the composer read
  differently. And a chain whose composed population disagrees with the `live_count` the index
  declares: §5.8 states that duplication is there to be checked, and checking it is what stops an
  entry declaring nothing from summarising a payload that decodes to something.
- **Keyframe-delta index, continued.** A keyframe's `live_count` is checked against the population
  its chunk composes to, not only the count the population rule happens to select — §5.8 defines the
  field for every extended entry and the reference writers set it on keyframes too.
- **Streamed reader.** The chunk-index clock bound the indexed reader already applied, so a
  container is not accepted or refused according to which reader opened it; and a cross-check that
  the chunks assemble to the total the header declares, for complete files only — a truncated file
  is expected to hold fewer.
- **Truncation recovery is unchanged, deliberately.** A record length running past the buffer and a
  download cut short raise the same error, and they cannot be told apart: in both cases the walk
  never reaches the tail, so nothing at the tail is evidence. `recoverTruncated` therefore still
  returns the decoded prefix with `truncated == true` for both. What a complete file cannot do is
  disagree with itself — once the walk reaches the Footer, the totals above are checked.

### Resource ceilings

The hardening above is about what is _legal_ — which files conform. This is about what is
_affordable_. A malformed length field could still size an allocation before anything noticed it was
malformed, which is the difference between refusing a bad file and being taken down by one. Every
ceiling here is shared **by scope and value** with the other SDKs, because a ceiling only one
implementation has means a file that decodes in three of them and is refused in the fourth:

- **Bounded Camera framing without a Dart-only count ceiling.** Before building any keyframe list,
  the parser proves that all declared 56-byte samples fit in the already bounded record. Camera has
  no cross-SDK `MAX_TRAJECTORY_SAMPLES` rule, so valid large Camera records remain accepted while a
  truncated declaration cannot allocate every available row before failing.
- **Keyframe-delta groups are framed before decoding.** Every declared stream payload is
  bounds-checked before the first decoded array is allocated. Decoded size remains subject to the
  shared per-stream ceiling; no Dart-only aggregate chunk limit changes which conforming files are
  accepted. A repeated stream whose payload is incomplete is consequently diagnosed as truncated
  before the duplicate-attribute rule is considered.
- **Quantization scheme.** `uniform-v1` is what this build implements, and a record naming anything
  else is refused as an unsupported codec rather than decoded through a grid it was not given — the
  steps are the only description of what a bin means, so reading `uniform-v9` bins through
  `uniform-v1` arithmetic produces a scene that is wrong everywhere and complains nowhere.
- **Quantization parameter magnitude.** Every step and `pos_origin` component must be finite (spec
  §5.3), and the refusal names the field. This decoder acts on the rule rather than reporting it for
  a reason specific to Dart: the per-gaussian pitches are derived with `log2` and rounded with
  `floor`, and `double.floor()` on a NaN or an infinity throws `UnsupportedError`, which names no
  byte, no record and no field.
- **A default cutoff, from one constant.** `fourdgsDefaultCutoff` (0.05, `DEFAULT_CUTOFF` elsewhere)
  now supplies every default in the package rather than a repeated literal, and `stateAt` and
  `support` refuse a threshold outside `(0, 1]` instead of turning it into an infinite support
  radius or a comparison that keeps the whole scene. `support` derives its half-width through
  `supportK`, so there is one implementation of the rule.

Each ceiling names the byte, the record, the value and the expectation, so
`FourdgsQuantization.parse` and `FourdgsCamera.parse` take the `fileOffset` their record begins at,
as `FourdgsChunkIndexEntry` already did, and the chunk parsers report where their stream blocks
start.

### Refusal diagnosis

- **Refusals say which rule was broken.** Every exception in this package now carries an optional
  `refusalCode`, and the six identifiers the specification's refusal table names — `magic-mismatch`,
  `unsupported-major-version`, `unknown-temporal-model`, `unknown-quantization-scheme`,
  `unknown-stream-codec`, `window-index-out-of-range` — are exported as named constants rather than
  written as literals at the raise sites, because six implementations are compared on those strings
  and a typo in one reads in CI like a decoder bug. The exception class alone was too coarse to
  compare on: `FourdgsUnsupportedCodec` covers an unknown temporal model, an unknown quantization
  scheme and an unknown stream codec alike, so "it threw `FourdgsUnsupportedCodec`" cannot tell a
  decoder that refused for the right reason from one that refused for the wrong one. `null` means "a
  real error the refusal table does not name", not "no error" — which is why `FourdgsTruncatedFile`,
  the one refusal that is recoverable rather than refusable, offers nowhere to put an identifier.
  This is additive: `refusalCode` is a property on the existing `FourdgsException` rather than a new
  class, so every `catch` and every `is` check keeps working, and `FourdgsException` still extends
  `FormatException`.

### Fixed

- **A file whose magic is corrupted anywhere but the version byte is no longer reported as an
  unsupported version.** `checkMagic` tested only that bytes 1-4 read `4DGS`, so flipping the
  leading `0x89` sentinel — the byte that stops byte-oriented tooling treating a 4dgs file as text —
  produced "4dgs major version 1 is not supported by this reader". That sends the file's holder
  looking for a newer reader, which would not have helped. The version byte must now be the only
  difference, which also catches the mangled `CR LF` the sentinel exists alongside. Nothing inside
  Dart could see this, because both answers are a `FourdgsUnsupportedVersion` carrying a plausible
  sentence; it took giving the two answers different names.
- **A window index outside the Window Table is refused rather than clamped.** The `gaussian-birth`
  chunk decoder clamped an out-of-range index to the nearest window, which substitutes one
  gaussian's lifetime for another's in a file that is already wrong in some way nobody has diagnosed
  — the scene renders and the fault is gone. Python and Rust have always refused it, and this
  package's own `keyframe-delta` path already did, so one file decoded two ways depending on its
  temporal model. An absent or empty Window Table is still one default `(0, 0)` window (spec §5.4),
  so index 0 resolves and everything past it does not. The refusal names the offending record and
  not only the offending value: the identifier says which rule broke, but a file has many chunks and
  all of them decode through one function, so "window index 7 is outside the 1-entry window table"
  left its holder a whole file to search. It is built in one place now — three sites reach it, the
  chunk decoder and both keyframe-delta grid lookups — and reads
  `gaussian 5 of the chunk at byte 4096 names window index 7, …` on the chunk path and
  `gaussian 77 names …` on the keyframe-delta path, where the stable id is what the file carries and
  the row is an artefact of composition order.
- **Every refusal a chunk raises says which chunk.** `decodeChunkStreams` takes the chunk record's
  file offset and names it in all of them — the duplicate attribute stream, the element and channel
  count mismatches, the missing required attributes, the decoded-size ceiling, the chunk-level codec
  and the two per-gaussian refusals. None of them could be placed in a multi-chunk file, and fixing
  one of them would have left the rest to be found the same way a second time.
- **The keyframe-delta window refusal names the gaussian even when its id is in the top half of the
  `u32` range.** `gaussian_id` is a `u32` (spec §11.2) and bins decode as signed 32-bit in every
  SDK, so `0xFFFFFFFF` arrives as `-1` — and "no gaussian supplied" was spelled `-1` too. The one
  gaussian whose id was the largest the format allows was therefore the one gaussian whose refusal
  silently lost its location. The absent case is a `null` now, which no id can collide with. The id
  is still printed as the signed value the decoder holds, because that is the value this package's
  `states` JSON carries and the value Python and Rust print for the same file; a message naming an
  id that appears nowhere else would be a worse diagnosis than a negative one.
- **A truncated Header is not an unsupported one.** A Header that ended after its `temporal_model`
  string was refused for naming a model this build does not implement, when what it actually is, is
  incomplete — sending whoever holds it to add codec support for a file that needs none. Every
  mandatory field is read before the model is classified.
- **An interval refusal names a byte in the file.** The Chunk Index parser reads a cursor over the
  record's content, so its own byte 0 is the start of that content, and a NaN or inverted interval
  was reported at byte 0 whatever its position. Callers pass the record's file origin now, so the
  byte named is one a reader can seek to.
- **An open-ended scene is probed at instants that exist.** The canonical summary derives probe
  times from each chunk's interval and from `duration - 1e-6`, both of which are `+Infinity` for an
  open-ended scene — an instant no half-open interval contains, which reported a nonempty scene as
  an empty state at a null time. Both are omitted when they are not finite; a chunk is still probed
  at its start.
- **An open-ended state chunk is composable on the indexed path.** `[t, +Infinity)` is a legal
  interval, and composing each chunk used to probe it at its own midpoint — which for an open-ended
  interval is `+Infinity`, an instant no half-open interval contains, its own included. The chain is
  now built from the entry the caller already holds, so the indexed path no longer refuses a file
  the streamed path reads.

These checks were pinned by a hostile-input suite kept alongside a first-party viewer that vendors
this decoder. They are here now so that depending on the published package directly is not a step
down in robustness for anyone doing the same.

### Added

- `fourdgs`, a pure-Dart decoder for the `.4dgs` container. No Flutter dependency and no `dart:io`
  in the decoder itself, so the same code runs on the Dart VM, inside Flutter, and compiled to
  JavaScript or Wasm.
- Both read paths. `readFourdgsBytes` walks a whole file front to back, needs no index, and recovers
  what preceded a cut; `openFourdgsIndexed` reads the Footer, then the index, then only the byte
  ranges an instant needs.
- `keyframe-delta` decode, both read paths. `decodeKeyframeDeltaStreamed` composes each chunk onto
  the one it references front to back; `decodeKeyframeDeltaIndexed` walks only an instant's chain
  from the index. Composition is bin-difference and telescopes, so the declared error bound holds at
  any chain depth (spec §11); GOP-invariants are enforced and rotation is restated absolutely.
  `keyframeDeltaStatesJson` emits the canonical reconstruction-at-an-instant the SDKs are diffed on.
  Decode only this milestone — there is no encoder.
- Object-layer decode (spec §5.15.6-§5.15.7, §6.6). `FourdgsObjectTable.parse` and
  `FourdgsObjectTrack.parse` read the two records, the `object_id` attribute stream (id 14) is
  decoded onto `FourdgsGaussianSet.objectId`, and `FourdgsObjectLayer` composes an object's SE(3)
  track onto reconstructed state — `center = R * c0 + T`, `orientation = R ⊗ r0`, base first.
  Available on both read paths: `scene.objects` on the streamed path, `readFourdgsObjects` on the
  indexed one, where the records are framed at open and fetched only when asked for, as provenance
  is. A gaussian with `object_id = 0`, or whose object has no track, keeps its base state; a scene
  that carries no layer produces an empty `FourdgsObjectLayer`, which is a value and not an error.
  `FourdgsState` now carries `orientations` and `objectId` alongside centres and opacity, so a
  caller can compose the layer without re-deriving either.
- `FourdgsReadable` as the single abstraction either path needs — a size and a byte range — with
  `FourdgsBytes` in the core and `FourdgsFileReadable` in `package:fourdgs/io.dart`. Transports live
  at the edges, so the decoder can be tested without a network and shipped without a platform.
- §3's reconstruction arithmetic: `FourdgsGaussianSet.stateAt` gives the marginal, the validity
  window, the advected centre and the scaled opacity at a time `t`, and decoding ends there.
- Multiple spatial `FourdgsAudioSource` values with independent timing, payloads, gain, looping and
  fixed or keyframed scene-space poses. `stateAt` reconstructs source-local playback time and moving
  pose; listener-relative HRTF, attenuation, occlusion and mixing remain player-owned.
- Descriptor-only audio inspection, source-state reconstruction and bounded source-relative payload
  reads, so an indexed caller never has to materialize an entire track to update a moving source.
- Spherical harmonics on both read paths, bands 1 to 3, merged into whole scene-wide degrees. The
  indexed path fetches only the bands asked for, since each band is its own byte range in the chunk
  index.
- Scene provenance (spec §5.15): Coordinate Frame, Sensor Calibration, Rig Trajectory and Geodetic
  Anchor on both read paths. Streamed decode fills `FourdgsScene.provenance`; the indexed path
  frames ranges at open and fetches them via `readFourdgsProvenance`. `FourdgsProvenance` carries
  the cross-record rules (unique names, resolving rig and frame references) and the arithmetic the
  records imply — shortest-arc slerp, clamped pose sampling, sensor-in-scene composition.
- `conformance/`, building `decode_streamed` and `decode_indexed`, registered in
  `tests/conformance/run.py` and skipped until built. Both paths report provenance and compose the
  object layer in the canonical summary, which is 105 checks — the same count Rust and TypeScript
  take. The invalid corpus's refusal expectations are declined.
- Tests for the one behaviour the corpus cannot reach: the indexed reader's front-matter scan runs
  to the first Chunk, so a Camera, Metadata or Attachment record sitting behind a large embedded
  audio track is still found. The harness only ever exercises the default 64 KiB probe on scenes
  that fit inside it, so a scan that stopped early would pass every check; these decode a real
  corpus file at probes down to 64 bytes and assert that shrinking it changes the number of round
  trips and nothing else. They fail rather than skip when the corpus is absent.

### Security

- Ceilings on the three counts a file chooses and the reader allocates against: validity windows, SH
  band descriptors per chunk-index entry, and chunk-index entries. Each is bounded twice — once
  against the bytes actually present, which the record itself disproves for free, and once against a
  ceiling far past anything a real encoder emits. Without them a 64 MiB summary names millions of
  objects that are built before any later budget is consulted.
- A chunk-index entry may not list the same SH band twice. A repeated descriptor is not merely
  redundant: each copy is fetched and then overwrites the same map entry, so N copies of a valid
  range are N transfers that leave one record behind.

### Fixed

- The velocity precision class is derived from the file's own `cutoff` rather than from the default
  0.05. A file that declares something else was encoded against that number, so assuming the default
  decodes a minority of gaussians' motion on the wrong pitch — the corpus's `CustomCutoff` variant
  is off by a factor of two — and nothing in the file says so. A cutoff outside `(0, 1]` is now
  refused rather than allowed to become a domain error inside a logarithm.
- An unsupported major version is reported as the digit in the magic rather than as that character's
  ordinal, so "version 9" no longer arrives as "version 57".

Nothing is released. There is no pub.dev entry for this package yet and nothing should depend on it.
The first publish must be done by hand — pub.dev requires it before automated publishing can be
enabled — after which the gated job in `.github/workflows/release.yml` takes over.
