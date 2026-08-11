# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a deliberate,
documented state — not a defect — and this table is the public contract that says so.

**A `Yes` means the conformance suite proves it.** Each SDK answers the variants it supports, the
harness skips the rest —
[which variants those are, and who decides, is the runner protocol](./conformance.md#declining-a-variant)
— and this table is kept in lockstep with what runs. Nothing is marked `Yes` on the strength of code
existing.

Every row is filled in from a suite that runs: 46 valid variants and 7 invalid ones, plus 4
keyframe-delta and 3 object-layer variants in their own subdirectories, over two read paths
(streamed and indexed). A language takes the variants it declares support for, and what it declines
is what this table records — 119 checks passing for Python, TypeScript, Rust, C++ and Swift, and 105
for Dart. Dart declines the invalid corpus, which asks a decoder to _name_ the refusal rather than
merely refuse. C++ and Swift read 4DGS through the Rust C ABI: the additive states-JSON accessor
computes keyframe-delta summaries in the core, the provenance-JSON accessor does the same for the
provenance family, and the objects-JSON pair does it for the object layer, so every binding emits
identical bytes with no per-language slerp or composition order of its own.

<!-- prettier-ignore -->
| Feature                                           | Python | TypeScript | Rust    | C++     | Swift   | Dart    |
| ------------------------------------------------- | ------ | ---------- | ------- | ------- | ------- | ------- |
| Streaming decode                                  | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Indexed / seeking decode                          | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Range-request decode                              | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Truncated-file recovery                           | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Chunk index                                       | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Summary offsets                                   | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| CRC validation                                    | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Quantized attributes                              | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 1                     | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 2                     | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 3                     | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| SH band range-skipping                            | Yes    | Yes        | Yes     | Yes     | Untested | Yes     |
| SH per-band bit depth, decode                     | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| SH per-band bit depth, encode                     | Yes    | Yes        | Yes     | Yes     | Yes     | Planned |
| Spatial audio sources (optional)                  | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Multiple independent audio sources                | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Moving audio source reconstruction                | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Per-source audio payload range reads              | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Camera trajectory                                 | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Metadata                                          | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Attachments                                       | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Statistics                                        | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Provenance: coordinate frame + georeference       | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Provenance: sensor calibration                    | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Provenance: rig trajectory + pose interpolation   | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Object membership (`object_id`)                   | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Object Table: labels, anchors, embeddings         | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Object Track: rigid state composition¹            | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Temporal model `keyframe-delta`, decode           | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Delta composition, chained                        | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Delta composition, keyframe-referenced            | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Births and deaths in deltas                       | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Reconstruction at an instant                      | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Encode `keyframe-delta`                           | Yes    | Planned    | Yes     | Planned | Planned | Planned |
| Unknown-record skipping                           | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Refusal diagnosis (named, not merely refused)     | Yes    | Yes        | Yes     | Yes     | Yes     | No      |
| Private-range records                             | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Encode                                            | Yes    | Yes        | Yes     | Yes     | Yes     | Planned |
| Chunked encode                                    | Yes    | Yes        | Yes     | Yes     | Yes     | Planned |
| Summary writing                                   | Yes    | Yes        | Yes     | Yes     | Yes     | Planned |
| Convert from PLY frame sequences                  | Yes    | No         | No      | No      | No      | No      |
| glTF interop (import, snapshot export)            | Yes    | No         | No      | No      | No      | No      |
| USD interop (import, snapshot export)             | Yes    | No         | No      | No      | No      | No      |
| USD animated export (keyframe-delta time samples) | Yes    | No         | No      | No      | No      | No      |
| Inspect and validate                              | Yes    | Planned    | Planned | Planned | Planned | Planned |

¹ On the `gaussian-birth` path. No implementation composes object tracks during `keyframe-delta`
reconstruction: that path rebuilds base centres and scales from bins and never reads the object
layer, so a scene carrying both decodes as though the track were absent, in every SDK. The
object-layer variants the suite runs are `gaussian-birth`, so no row here is evidence either way
about the combination — see issue #79.

## Reading this table

- **Yes** — implemented, and the conformance suite proves it.
- **Untested** — implemented, and nothing in this repository proves it. A promise with no evidence
  behind it, recorded as such rather than as a `Yes`.
- **Planned** — intended for this SDK; not implemented yet.
- **No** — not intended for this SDK. Conversion tooling, for example, belongs where people run
  batch jobs, not in a browser bundle.

## Notes

**Spatial audio** is optional in every sense. A scene without it carries no audio records, and every
SDK exposes an empty source collection rather than an error state. A source carries scene-space pose
and timing; SDKs reconstruct moving source state, while listener-relative HRTF/panning, attenuation,
occlusion and mixing remain player-owned.

**Provenance** (spec §5.15) is optional and no Header flag announces it: a file that carries none is
byte-identical to what it was before the family existed. Every SDK now reports the four records —
Python, Rust, TypeScript and Dart natively; C++ and Swift through the Rust C ABI's additive
provenance-JSON accessor, which serializes frames, anchors, sensors, trajectories and the composed
`posesAt` / `sensorPosesAt` probes in the core so the bindings cannot drift on slerp. The row is
about _reporting_ rather than merely reading: stepping over provenance by length still decodes every
gaussian correctly, including `TenWindows-AddExtraDataToRecords-…-WithGeodetic-WithRig-WithSensors`,
which appends unknown fields to the records as well. What reporting proves is that the family is in
the summary with the same arithmetic every other SDK emits.

**The object layer** is proved separately because reading its records is not enough. Composition is
where two implementations that agree on every stored field can still diverge: the layer transforms
the base state rather than replacing it — `center = R*c0 + T`, `orientation = R (x) r0`, base first
— so a summary that carried only the table and the tracks would pass a decoder that dropped the
track or applied it before per-gaussian motion. The canonical `states` therefore carry the
post-track centers and orientations at three scene-clock probes, in the canonical gaussian order,
and three independent implementations — Python, Rust and TypeScript — must agree on them, which is
the cross-check a shared stored field alone would pass. What that proves is decode and the
composition arithmetic, not the reader's own indexed pose-sampling path, which each runner reaches
by loading the whole object layer rather than by range-sampling it.

TypeScript decodes the layer natively and composes it on both read paths: the records are read at
open on the streamed path and framed-then-fetched on the indexed one, exactly as provenance is, so a
thousand-sample track costs nothing to open there either. Its canonical states are reconstructed in
double precision before rounding, which is what keeps the comparison a statement about the format
rather than about an SDK's output storage type — the production arrays stay float32, as Rust's and
Python's do.

Three variants in a `data/object/` subdirectory, the way the keyframe-delta and invalid corpora sit
in theirs, exercise that composition: a single tracked object over a static base (a table entry with
dynamics and an embedding, and a two-sample track that turns and translates); a multi-object scene
with a linearly tracked object, a step-tracked one, an untracked-but-labelled one whose gaussians
pass through unchanged, and background gaussians no track may name; and a track composed over a base
that itself moves and turns, where every gaussian carries per-gaussian motion and a non-identity
rest orientation, so the motion must fold into the base center before the pose transports it and the
rotations must compose as a quaternion product rather than one replacing the other. The subdirectory
is not a workaround the way the keyframe-delta one is — an object record is additive to the
gaussian-birth model, and the one `WithObjects` variant at the top level is read by the Kaitai
grammar and the fuzzer, which is where the records' framing and length-skipping are proved — it just
keeps the decode-and-compose family gathered where the harness reaches for it. Every SDK now emits
those states from both read paths — Python, Rust, TypeScript and Dart natively; C++ and Swift
through the C ABI, which returns the `objects` and `states` members as two accessors over one
computation and the per-gaussian memberships as a borrowed `uint32` array. A null array and an
all-zero one are different claims and both are legal: a file that never assigns membership, and a
file where every gaussian belongs to object 0.

**The `keyframe-delta` temporal model** (spec §11) is proved by four corpus variants that live in
their own `data/keyframe/` subdirectory, the way the invalid corpus does — every whole-corpus
consumer that is not this harness globs the top level only and assumes the single gaussian-birth
model, so a delta file there would break the fuzzer and the Kaitai grammar rather than exercise
them. The variants cover a keyframe-only file (the cadence-one shape that subsumes
`frame-sequence`), chained pure-update deltas, deltas carrying births and deaths, and
keyframe-referenced deltas. Each SDK's runner dispatches on `temporal_model` and emits the canonical
`states` — the reconstruction at probe instants derived from the file, in `gaussian_id` order — and
the streamed and indexed paths must agree, which is what proves the chain walk. The **decode** rows
are `Yes` where that suite passes: all six SDKs. Python, Rust, TypeScript and Dart decode
keyframe-delta natively; C++ and Swift decode it through the Rust C ABI's additive states-JSON
accessor, which composes the file and computes the canonical `states` in the core, so the two
bindings emit bytes identical to the reference with no arithmetic of their own — the runner peeks
the `temporal_model` from the bytes, since an opened scene refuses the model, then calls the
accessor on each read path. **Encode** is `Yes` for Python, whose writer generates the corpus, and
Rust, whose cross-implementation gate encodes a delta file that Python decodes to an identical
canonical. The C++ and Swift encode cells stay `Planned`: the C ABI exposes no keyframe-delta
encoder.

**Range-request decode** is a property of the transport an SDK offers, not of the format: every SDK
can decode from an arbitrary byte-range reader, but only some ship an HTTP one. TypeScript's and
Rust's `Yes` cover the decode, which each indexed runner exercises over ranged reads; the HTTP
transport TypeScript ships in `@4dgs/browser` is covered by that package's own tests, not by the
corpus. Rust ships no HTTP transport at all — its core takes a `Readable`, and the C ABI takes the
same thing as callbacks, so an HTTP reader belongs to the consumer. Dart is the same shape: the
decoder takes a `FourdgsReadable`, ships an in-memory and a file transport, and leaves HTTP to the
consumer.

**Encode** is now `Yes` for TypeScript, C++ and Swift, and the two kinds of encoder are proved
differently. TypeScript is a second implementation — a from-scratch encoder in `@4dgs/core`, so a
browser can author a file — and it is diffed against the reference the way a second decoder is: on
decoded content, not bytes. C++ and Swift are bindings over the Rust core's writer
(`fourdgs_writer_*` in the C ABI), so their gate proves the binding passed the gaussians and options
through correctly rather than that a second encoder agrees. Python remains the reference encoder and
Rust the production one.

**Convert from PLY frame sequences** takes a directory of standard per-frame gaussian splat PLY
files — the common interchange form — and produces a `.4dgs`. It lives in the Python package because
it is a batch operation.

**glTF and USD interop** are bidirectional bridges, and like the PLY converter they live in the
Python package because they are batch operations, not something a browser or a mobile decoder
carries — hence `No`, by design, everywhere else. Both **import** a static asset in full: a
`KHR_gaussian_splatting` glTF or a `ParticleField3DGaussianSplat` USD reads into this format's
degenerate temporal case — one keyframe, never fading, present at every instant. Their **export**
differs by what the target format can hold. glTF's extension describes one static instant, so
`to_gltf` writes the scene reconstructed at a chosen time and stops — a snapshot, the same limit USD
snapshot export has. **USD animated export** is the one that earns a row of its own: USD attributes
are time-sampled, so a whole scene can be written as a sequence that plays. For a `keyframe-delta`
file that is the natural target, and the only one that fits — the model has no closed-form
`state_at` to snapshot, so `to_usd_keyframe_delta` composes the population at each frame (spec §11
reconstruction) and writes it as one time sample. USD time samples permit a different array length
per sample, so a frame's births and deaths are represented exactly; what USD does not carry is the
`gaussian_id` correspondence between frames, so the result is a faithful flipbook of exact
per-instant states rather than tracked gaussians — the per-frame geometry is exact to the file's
declared bounds, and a viewer holds each sample until the next. The `Yes` rests on a round-trip test
under the `usd-core`-gated CI job: every written time sample equals the format's own reconstruction
at that frame.

**Spherical harmonics, degree 3** moved from `Planned` to `Yes` when the corpus gained two degree-3
variants — one coarsely chunked, one finely, at four and twenty-four chunks — and every SDK decoded
both on both read paths in this repository's CI. Nothing about any decoder changed — the code was
already right in all five, and the cells said `Planned` because the corpus could not prove it. That
is the rule working as intended, and it is worth being precise about what the `Yes` now rests on:
Python, Rust and Dart carry the band ranges as a table, TypeScript derives them from
`(d + 1)^2 - 1`, and C++ and Swift reach the Rust core through the C ABI. So the row proves four
independent derivations agree, not six — Dart's table is a fourth arrival at the same numbers, and
C++ and Swift still share Rust's.

**The Header's `profile` and `library`** are asserted by the canonical summary rather than having a
row of their own. They were readable in every SDK from the start and asserted by none, which meant a
runner that returned an empty string for both was indistinguishable from one that decoded them — the
C++ binding did exactly that once. Several rows above rest a little more firmly for it.

**Spherical harmonics, degrees 1 and 2** are proved by a checksum of the decoded coefficients, taken
in content order so two decoders that visit gaussians differently still agree. Before that checksum
existed, every SH variant passed for a decoder that threw the coefficients away — which is why these
cells said `Planned` while the code was already written.

**SH per-band bit depth** splits into two rows because it is two different claims, and the decode
one is the surprising half: it is a `Yes` that cost no decoder a line of code. A band's coefficient
is a byte whatever depth it was quantized at, and the depths themselves ride in fields appended to
the Quantization record, which every SDK already steps over by length. So the row is not "six
implementations wrote this feature"; it is "six implementations were asked to decode files that use
it and did", which the five new corpus variants check on both read paths — the spherical-harmonic
digest is taken over coefficients that are demonstrably not the ones that went in, so a decoder
substituting its own expectation fails.

The encode row is proved the way the other encode rows are: Python's by the corpus gate, which
re-encodes every variant and asserts its checksum, and Rust's by `encode-roundtrip.sh`, which now
re-encodes every SH-bearing variant at per-band depths and requires the Python decoder to agree with
the Rust one about the result — and, separately, to read back the depths that were declared. A file
whose coefficients and whose declaration disagree fails one check or the other. TypeScript, C++ and
Swift are proved by the cross-language encode gate below, which runs the same per-band pass: the
coefficients each encoder coarsened must come back out of the Python decoder as the same bytes, and
the appended depths must read as the ones written.

**SH band range-skipping** is proved for five SDKs by a byte count taken at the transport rather
than by a decoded value: each of those runners reads a chunk at every band cap and asserts the bytes
transferred equal exactly what the chunk index declares for the bands at or below it. Never
transferring a band you will not evaluate is the whole feature, and that is what is measured. Swift
compares the core's estimates without measuring a capped transport read, so its cell remains
`Untested`.

**Refusal diagnosis** is a `Yes` only where a runner names _which_ rule a file broke, not merely
that it refused one. The invalid corpus pairs each deliberately broken file with a refusal
identifier, and a runner prints that identifier as its answer. The distinction is the whole row: a
decoder that refuses every invalid file for the wrong reason is indistinguishable, to a suite that
only checks that something was raised, from one that refuses correctly. Rust carries the identifier
on the error itself — `Error::refusal_code`, from the constants in `fourdgs::error::refusal` — and
TypeScript does the same, as an optional `refusalCode` on `FourdgsError` from the constants in
`Refusal`. C++ carries the same identifier on `fourdgs::Error::refusal`, read across the C ABI
through `fourdgs_last_refusal_code`; it is a `std::optional`, because a truncated file and a
transport that failed are real errors the refusal table does not name. Swift carries the same
identifier on `FourDGSError.refusalCode`, fetched from the core through `fourdgs_last_refusal_code`
— a binding reports the rule the one decoder applied rather than inferring one from a status code,
and `FOURDGS_STATUS_UNSUPPORTED_CODEC` alone stands for three of the six. A consumer can branch on
any of these refusals without reading its prose. Dart's remaining `No` is the honest state: it
refuses these files today, and nothing here proves it refuses them for the right reason.

The row was also the first thing to find a gap in the reference: neither an unknown `temporal_model`
nor an unknown quantization `scheme` was refused at all before it existed, despite the registry
requiring both. Each decoded as though it carried the known value. It found one more on the way into
TypeScript, where a file with a corrupted first magic byte was reported as an unsupported major
version — the reader tested only that bytes 1-4 read `4DGS`. Both refusals are the same class and
carry the same sentence's worth of prose, so nothing short of comparing identifiers could see it.

**Truncated-file recovery** is the one row no expectation can carry, because a cut file is a
different file. Each runner decodes its variant twice more — once cut before the trailing magic,
once cut inside the last chunk — and asserts what survives. A failure exits the runner non-zero and
the harness reports it like a diff.

**Moving audio-source reconstruction is compared at the scene midpoint.** Each canonical source
contains `stateAtHalf`, including its active flag, local payload time, gain, interpolated position
and shortest-path SLERP rotation. The player-owned listener pose and spatialization policy are not
part of that state.

Gaussian reconstruction at an instant is not carried by the canonical JSON. The summary is chiefly a
statement about a file, not an exhaustive sample of §3's continuous arithmetic: two implementations
could disagree about a marginal, centre or visibility boundary and pass the cross-SDK comparison.
SDK unit tests therefore check that arithmetic directly. C++, for example, reconstructs at four
instants per variant with the file's own cutoff and compares the resident and core results in both
directions.

**Encode**, **Chunked encode** and **Summary writing** are proved by a gate rather than by a runner,
and the encoders are gated by their role.

Python's is proved by the corpus gate: `generate.py --verify` re-encodes all 46 valid variants,
asserts every committed checksum, and asserts that two consecutive runs are byte-identical. Every
variant is an encode; the chunked and summary-bearing ones are the flags that say so.

Rust's cannot use that gate, because Rust does not generate the corpus and a second encoder that
produced byte-identical files would be a reimplementation rather than an implementation.
`rust/encode-roundtrip.sh` re-encodes every variant with the Rust encoder and then requires the
**Rust and Python decoders to produce identical canonical JSON** from the result, asserting
byte-identical output across two encodes on the way. An encoder checked only against its own decoder
proves that two halves of one implementation share an opinion, which is the failure mode this suite
exists to catch; agreement with a decoder written in another language against the same specification
is a real claim. Every encode inside that gate also runs the encoder's own verification, which
decodes each chunk back and refuses to return a file whose measured deviation exceeds the bounds it
is about to declare — so the Quantization record's numbers are checked on every gaussian of every
scene rather than sampled. The chunk tree is exercised by the same run: the corpus scenes partition
into up to 42 chunks each.

TypeScript, C++ and Swift are proved by the cross-language encode gate,
`tests/conformance/encode_roundtrip.py`. It re-encodes every variant's decoded gaussians twice —
once with the language under test, once with a shared Rust reference that writes gaussians alone
(`encode_gaussians`) — and requires the Python decoder to read both files to the same summary. What
"the same" means depends on the encoder. C++ and Swift reach the Rust writer through the C ABI
(`fourdgs_writer_*`), so their files match the reference on every field; the gate therefore proves
the binding wired the gaussians and options through correctly, which is the only thing a binding can
get wrong. TypeScript is a genuine second encoder, so it makes its own byte-layout choices — how
well `deflate` did, which order gaussians sit in a chunk — that a decoder cannot see and the
specification does not fix; those fields are set aside and the diff rests on decoded content: the
gaussian values, the chunk intervals, the statistics, the spherical-harmonic digest. The chunked and
summary rows ride the same gate — the small chunk threshold the preset uses partitions the corpus
scenes into a tree whose intervals both encoders must agree on, and the statistics record they both
write carries the chunk count.

**Fuzzed** is a property of an implementation, not a feature of the format, so it is not a row in
this table — a row would imply the format has something called fuzzing that an SDK can support.
Python's, TypeScript's and Rust's decoders are fuzzed in CI, each holding one invariant: for any
input at all, a decoder either succeeds or raises the format's own error type — never a codec
library's exception or a panic, never unbounded allocation, never a hang. Python's and TypeScript's
mutate the shared corpus and share a seed scheme, so a crash found by one reproduces in the other
from two integers; Rust's encodes its own seeds and additionally fuzzes the C ABI, where a panic
crossing the boundary would be undefined behaviour rather than an error the caller can handle. C++
and Swift are not fuzzed yet — they bind to the Rust core, so its fuzzing covers the decode but not
their own bindings. See
[the fuzzing notes](https://github.com/avala-ai/4dgs/blob/main/tests/fuzz/README.md) and
`rust/fourdgs/tests/fuzz.rs`.

**Swift**'s band-skipping check asserts the byte **count**, not that the call succeeded. A cache
that answers a narrow cap from a wider entry returns the wider count while looking perfectly healthy
— that bug existed in the core and was fixed — so the runner requires that capping harmonics away
costs strictly fewer bytes than carrying them, and that no cap ever moves more than a wider one.

**Convert from PLY frame sequences** and **Inspect and validate** are tools rather than wire-format
features, so the conformance suite does not cover them; they are marked from their own tests, which
now exist. The converter's fixtures are PLY frames generated into a temporary directory from a fixed
seed — the corpus rule applied to a different file format — and the validator is tested against
files built byte by byte, because a validator tested only on files its own encoder wrote is a
validator tested against nothing.

**Rust** decodes and encodes. Its decode rows are filled in from the same suite on the same terms as
the other two; its encode rows come from the cross-implementation gate described above. Python
remains the reference encoder — the one the corpus is generated from — and Rust's is the production
one, which is why it verifies its own bounds exhaustively rather than trusting the grid arithmetic.
The crate also carries the C ABI — `rust/fourdgs/include/fourdgs.h` — which is the surface the
native tier binds to rather than hand-writing and then maintaining parallel implementations. It
covers both directions: the decode surface and, appended to it without disturbing a frozen
signature, a `fourdgs_writer_*` surface the native tier authors through. That header is checked by a
C program compiled and run in CI — which now also builds a tiny scene, encodes it and reopens the
bytes — not by the corpus, because a drift between a header and the symbols behind it is not
something a decode suite can see.

**C++** and **Swift** take their surface from that C ABI — the header plus a thin shim per language
— in both directions: they decode through it and, now, encode through it, `fourdgs::encodeScene` and
`SceneWriter.encode` binding the core's `fourdgs_writer_*` functions rather than reimplementing the
quantizer. Swift targets visionOS and iOS.

**Dart** is an independent decoder rather than a binding: pure Dart, no Flutter dependency, sharing
no code with the other five. That is what makes its agreement with them worth something — the row it
fills in is a sixth derivation from the specification, not a sixth caller of the same one. It runs
on the Dart VM, inside Flutter, and compiled to JavaScript or Wasm, and its `dart:io` transport is a
separate import so the decoder itself stays platform-free.

Its arrival moved no other cell, but it did find one: the velocity precision class is derived from
the Header's `cutoff`, and a decoder that assumes the default 0.05 decodes a minority of gaussians'
motion on the wrong pitch. The corpus's `CustomCutoff` variant is what catches it — a reminder that
a variant only earns its keep when some implementation gets it wrong.
