# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a deliberate,
documented state — not a defect — and this table is the public contract that says so.

**A `Yes` means the conformance suite proves it.** Each SDK declares the variants it supports via
`supportsVariant()`, the harness runs exactly those, and this table is kept in lockstep with those
declarations. Nothing is marked `Yes` on the strength of code existing.

Python's row, TypeScript's and Rust's are filled in from a suite that runs: 28 variants, two read
paths (streamed and indexed), 55 checks passing for each. The other languages have not been run
against it yet.

| Feature                                              | Python  | TypeScript | Rust    | C++     | Swift   |
| ---------------------------------------------------- | ------- | ---------- | ------- | ------- | ------- |
| Streaming decode                                     | Yes     | Yes        | Yes     | Planned | Planned |
| Indexed / seeking decode                             | Yes     | Yes        | Yes     | Planned | Planned |
| Range-request decode                                 | Yes     | Yes        | Yes     | Planned | Planned |
| Truncated-file recovery                              | Yes     | Yes        | Yes     | Planned | Planned |
| Chunk index                                          | Yes     | Yes        | Yes     | Planned | Planned |
| Summary offsets                                      | Yes     | Yes        | Yes     | Planned | Planned |
| CRC validation                                       | Yes     | Yes        | Yes     | Planned | Planned |
| Quantized attributes                                 | Yes     | Yes        | Yes     | Planned | Planned |
| Spherical harmonics, degree 1                        | Yes     | Yes        | Yes     | Planned | Planned |
| Spherical harmonics, degree 2                        | Yes     | Yes        | Yes     | Planned | Planned |
| Spherical harmonics, degree 3                        | Planned | Planned    | Planned | Planned | Planned |
| SH band range-skipping                               | Yes     | Yes        | Yes     | Planned | Planned |
| Embedded audio (optional, zero-overhead when absent) | Yes     | Yes        | Yes     | Planned | Planned |
| Camera trajectory                                    | Yes     | Yes        | Yes     | Planned | Planned |
| Metadata                                             | Yes     | Yes        | Yes     | Planned | Planned |
| Attachments                                          | Yes     | Yes        | Yes     | Planned | Planned |
| Statistics                                           | Yes     | Yes        | Yes     | Planned | Planned |
| Unknown-record skipping                              | Yes     | Yes        | Yes     | Planned | Planned |
| Private-range records                                | Yes     | Yes        | Yes     | Planned | Planned |
| Encode                                               | Yes     | Planned    | Planned | Planned | Planned |
| Chunked encode                                       | Yes     | Planned    | Planned | Planned | Planned |
| Summary writing                                      | Yes     | Planned    | Planned | Planned | Planned |
| Convert from PLY frame sequences                     | Yes     | No         | No      | No      | No      |
| Inspect and validate                                 | Yes     | Planned    | Planned | Planned | Planned |

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

**Range-request decode** is a property of the transport an SDK offers, not of the format: every SDK
can decode from an arbitrary byte-range reader, but only some ship an HTTP one. TypeScript's and
Rust's `Yes` cover the decode, which each indexed runner exercises over ranged reads; the HTTP
transport TypeScript ships in `@4dgs/browser` is covered by that package's own tests, not by the
corpus. Rust ships no HTTP transport at all — its core takes a `Readable`, and the C ABI takes the
same thing as callbacks, so an HTTP reader belongs to the consumer.

**Encode** stays `Planned` for TypeScript and Rust because neither has an encoder yet. Those
packages decode; the reference encoder is Python's.

**Convert from PLY frame sequences** takes a directory of standard per-frame gaussian splat PLY
files — the common interchange form — and produces a `.4dgs`. It lives in the Python package because
it is a batch operation.

**Spherical harmonics, degree 3** is implemented and unit-tested in Python, but the conformance
corpus only carries degree 1 and 2 variants, so by this table's own rule it does not get a `Yes`
yet. Adding the variant is the work, not adding the feature.

**Spherical harmonics, degrees 1 and 2** are proved by a checksum of the decoded coefficients, taken
in content order so two decoders that visit gaussians differently still agree. Before that checksum
existed, every SH variant passed for a decoder that threw the coefficients away — which is why these
cells said `Planned` while the code was already written.

**SH band range-skipping** is proved by a byte count taken at the transport rather than by a decoded
value: each runner reads a chunk at every band cap and asserts the bytes transferred equal exactly
what the chunk index declares for the bands at or below it. Never transferring a band you will not
evaluate is the whole feature, and that is what is measured.

**Truncated-file recovery** is the one row no expectation can carry, because a cut file is a
different file. Each runner decodes its variant twice more — once cut before the trailing magic,
once cut inside the last chunk — and asserts what survives. A failure exits the runner non-zero and
the harness reports it like a diff.

**Encode**, **Chunked encode** and **Summary writing** are proved by the corpus gate rather than by
a runner: `generate.py --verify` re-encodes all 28 variants, asserts every committed checksum, and
asserts that two consecutive runs are byte-identical. Every variant is an encode; the chunked and
summary-bearing ones are the flags that say so.

**Convert from PLY frame sequences** and **Inspect and validate** are tools rather than wire-format
features, so the conformance suite does not cover them; they are marked from their own tests, which
now exist. The converter's fixtures are PLY frames generated into a temporary directory from a fixed
seed — the corpus rule applied to a different file format — and the validator is tested against
files built byte by byte, because a validator tested only on files its own encoder wrote is a
validator tested against nothing.

**Rust** decodes, and its decode row is filled in from the same suite on the same terms as the other
two. Its encode rows stay `Planned`: there is no Rust encoder yet, and the reference encoder is
Python's. The crate also carries the C ABI — `rust/fourdgs/include/fourdgs.h` — which is the surface
the native tier binds to rather than hand-writing and then maintaining parallel implementations.
That header is checked by a C program compiled and run in CI, not by the corpus, because a drift
between a header and the symbols behind it is not something a decode suite can see.

**C++** and **Swift** take their surface from that C ABI — the header plus a thin shim per language.
Swift targets visionOS and iOS.
