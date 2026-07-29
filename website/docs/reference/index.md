# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a deliberate,
documented state — not a defect — and this table is the public contract that says so.

**A `Yes` means the conformance suite proves it.** Each SDK declares the variants it supports via
`supportsVariant()`, the harness runs exactly those, and this table is kept in lockstep with those
declarations. Nothing is marked `Yes` on the strength of code existing.

Every row is filled in from a suite that runs: 39 valid variants and 6 invalid ones, over two read
paths (streamed and indexed). A language takes the variants it declares support for, and what it
declines is what this table records — 89 checks passing for Python, 77 for Rust, 67 each for
TypeScript, C++, Swift and Dart. Rust declines the refusal expectations; TypeScript, C++, Swift and
Dart decline those and the five variants that carry provenance records.

| Feature                                              | Python | TypeScript | Rust    | C++     | Swift   | Dart    |
| ---------------------------------------------------- | ------ | ---------- | ------- | ------- | ------- | ------- |
| Streaming decode                                     | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Indexed / seeking decode                             | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Range-request decode                                 | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Truncated-file recovery                              | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Chunk index                                          | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Summary offsets                                      | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| CRC validation                                       | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Quantized attributes                                 | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 1                        | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 2                        | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Spherical harmonics, degree 3                        | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| SH band range-skipping                               | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Embedded audio (optional, zero-overhead when absent) | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Camera trajectory                                    | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Metadata                                             | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Attachments                                          | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Statistics                                           | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Provenance: coordinate frame + georeference          | Yes    | No         | Yes     | No      | No      | No      |
| Provenance: sensor calibration                       | Yes    | No         | Yes     | No      | No      | No      |
| Provenance: rig trajectory + pose interpolation      | Yes    | No         | Yes     | No      | No      | No      |
| Unknown-record skipping                              | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Refusal diagnosis (named, not merely refused)        | Yes    | No         | No      | No      | No      | No      |
| Private-range records                                | Yes    | Yes        | Yes     | Yes     | Yes     | Yes     |
| Encode                                               | Yes    | Planned    | Yes     | Planned | Planned | Planned |
| Chunked encode                                       | Yes    | Planned    | Yes     | Planned | Planned | Planned |
| Summary writing                                      | Yes    | Planned    | Yes     | Planned | Planned | Planned |
| Convert from PLY frame sequences                     | Yes    | No         | No      | No      | No      | No      |
| Inspect and validate                                 | Yes    | Planned    | Planned | Planned | Planned | Planned |

## Reading this table

- **Yes** — implemented, and the conformance suite proves it.
- **Untested** — implemented, and nothing in this repository proves it. A promise with no evidence
  behind it, recorded as such rather than as a `Yes`.
- **Planned** — intended for this SDK; not implemented yet.
- **No** — not intended for this SDK. Conversion tooling, for example, belongs where people run
  batch jobs, not in a browser bundle.

## Notes

**Embedded audio** is optional in every sense. A scene without audio carries no audio record at all,
and every SDK exposes audio as an optional value rather than an error state. Most files will have
none; that is the common case, and it costs nothing.

**Provenance** (spec §5.15) is the newest feature here and the clearest illustration of what this
table is for. Python and Rust decode the four records and surface them; TypeScript, C++, Swift and
Dart do not, and say so. That is not a gap anyone has to close before the format is usable, because
the records are optional and no Header flag announces them: an SDK that has never heard of opcode
`0x20` skips it by length and decodes every gaussian in the file correctly. It was verified rather
than assumed — TypeScript, given a file carrying all four records plus appended fields on them,
produces output identical to the expectation with the provenance section removed, with no change to
a line of TypeScript. C++ and Swift are bindings over the Rust core rather than independent
decoders, so their `No` means the binding does not surface the records, not that nothing there can
read them.

Dart is the case that shows why the row is about _reporting_ rather than reading. It arrived after
the family existed and skipped every provenance record on the first run of the corpus, decoding all
five of those variants' gaussians correctly — including
`TenWindows-AddExtraDataToRecords-…-WithGeodetic-WithRig-WithSensors`, which appends unknown fields
to the records as well. What it does not do is put the family in its summary, so a diff would see a
missing key and could not tell that apart from a decoder that got it wrong. Declining is how it says
which of the two it is.

**Range-request decode** is a property of the transport an SDK offers, not of the format: every SDK
can decode from an arbitrary byte-range reader, but only some ship an HTTP one. TypeScript's and
Rust's `Yes` cover the decode, which each indexed runner exercises over ranged reads; the HTTP
transport TypeScript ships in `@4dgs/browser` is covered by that package's own tests, not by the
corpus. Rust ships no HTTP transport at all — its core takes a `Readable`, and the C ABI takes the
same thing as callbacks, so an HTTP reader belongs to the consumer. Dart is the same shape: the
decoder takes a `FourdgsReadable`, ships an in-memory and a file transport, and leaves HTTP to the
consumer.

**Encode** stays `Planned` for TypeScript because there is no TypeScript encoder. The packages there
decode; Python's encoder is the reference and Rust's is the production one.

**Convert from PLY frame sequences** takes a directory of standard per-frame gaussian splat PLY
files — the common interchange form — and produces a `.4dgs`. It lives in the Python package because
it is a batch operation.

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

**SH band range-skipping** is proved by a byte count taken at the transport rather than by a decoded
value: each runner reads a chunk at every band cap and asserts the bytes transferred equal exactly
what the chunk index declares for the bands at or below it. Never transferring a band you will not
evaluate is the whole feature, and that is what is measured.

**Refusal diagnosis** is a `Yes` only where a runner names _which_ rule a file broke, not merely
that it refused one. The invalid corpus pairs each deliberately broken file with a refusal
identifier, and a runner prints that identifier as its answer. The distinction is the whole row: a
decoder that refuses every invalid file for the wrong reason is indistinguishable, to a suite that
only checks that something was raised, from one that refuses correctly. The four `No` cells are the
honest state — those SDKs refuse these files today, and nothing here proves they refuse them for the
right reason.

The row was also the first thing to find a gap in the reference: neither an unknown `temporal_model`
nor an unknown quantization `scheme` was refused at all before it existed, despite the registry
requiring both. Each decoded as though it carried the known value.

**Truncated-file recovery** is the one row no expectation can carry, because a cut file is a
different file. Each runner decodes its variant twice more — once cut before the trailing magic,
once cut inside the last chunk — and asserts what survives. A failure exits the runner non-zero and
the harness reports it like a diff.

**Reconstruction at an instant is the one thing the canonical JSON does not carry**, and so the one
thing the suite cannot compare. The summary is a statement about a file, not about a moment in it:
two implementations could disagree about §3's arithmetic — the marginal, the centre, the visibility
test — and pass every check. Where an SDK implements that arithmetic itself rather than only calling
into a decoder, it is checked against the decoder's own answer. C++ is the case that exists today:
its unit tests reconstruct at four instants per variant, with the file's own cutoff, and assert the
sets agree in both directions — every gaussian the core calls visible must be visible there with the
same centre and opacity, and every gaussian it calls visible must appear in the core's set, so the
check cannot pass against a decoder that returns nothing.

**Encode**, **Chunked encode** and **Summary writing** are proved by a gate rather than by a runner,
and the two encoders are gated differently because they play different roles.

Python's is proved by the corpus gate: `generate.py --verify` re-encodes all 34 variants, asserts
every committed checksum, and asserts that two consecutive runs are byte-identical. Every variant is
an encode; the chunked and summary-bearing ones are the flags that say so.

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
native tier binds to rather than hand-writing and then maintaining parallel implementations. That
header is checked by a C program compiled and run in CI, not by the corpus, because a drift between
a header and the symbols behind it is not something a decode suite can see.

**C++** and **Swift** take their surface from that C ABI — the header plus a thin shim per language.
Swift targets visionOS and iOS.

**Dart** is an independent decoder rather than a binding: pure Dart, no Flutter dependency, sharing
no code with the other five. That is what makes its agreement with them worth something — the row it
fills in is a sixth derivation from the specification, not a sixth caller of the same one. It runs
on the Dart VM, inside Flutter, and compiled to JavaScript or Wasm, and its `dart:io` transport is a
separate import so the decoder itself stays platform-free.

Its arrival moved no other cell, but it did find one: the velocity precision class is derived from
the Header's `cutoff`, and a decoder that assumes the default 0.05 decodes a minority of gaussians'
motion on the wrong pitch. The corpus's `CustomCutoff` variant is what catches it — a reminder that
a variant only earns its keep when some implementation gets it wrong.
