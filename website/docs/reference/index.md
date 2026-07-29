# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a deliberate,
documented state — not a defect — and this table is the public contract that says so.

**A `Yes` means the conformance suite proves it.** Each SDK declares the variants it supports via
`supportsVariant()`, the harness runs exactly those, and this table is kept in lockstep with those
declarations. Nothing is marked `Yes` on the strength of code existing.

Python's row and TypeScript's are filled in from a suite that runs: 28 variants, two read paths
(streamed and indexed), 55 checks passing for each. The other languages have not been run against it
yet.

| Feature                                              | Python   | TypeScript | Rust    | C++     | Swift   |
| ---------------------------------------------------- | -------- | ---------- | ------- | ------- | ------- |
| Streaming decode                                     | Yes      | Yes        | Planned | Planned | Planned |
| Indexed / seeking decode                             | Yes      | Yes        | Planned | Planned | Planned |
| Range-request decode                                 | Yes      | Yes        | Planned | Planned | Planned |
| Truncated-file recovery                              | Yes      | Yes        | Planned | Planned | Planned |
| Chunk index                                          | Yes      | Yes        | Planned | Planned | Planned |
| Summary offsets                                      | Yes      | Yes        | Planned | Planned | Planned |
| CRC validation                                       | Yes      | Yes        | Planned | Planned | Planned |
| Quantized attributes                                 | Yes      | Yes        | Planned | Planned | Planned |
| Spherical harmonics, degree 1                        | Yes      | Yes        | Planned | Planned | Planned |
| Spherical harmonics, degree 2                        | Yes      | Yes        | Planned | Planned | Planned |
| Spherical harmonics, degree 3                        | Planned  | Planned    | Planned | Planned | Planned |
| SH band range-skipping                               | Yes      | Yes        | Planned | Planned | Planned |
| Embedded audio (optional, zero-overhead when absent) | Yes      | Yes        | Planned | Planned | Planned |
| Camera trajectory                                    | Yes      | Yes        | Planned | Planned | Planned |
| Metadata                                             | Yes      | Yes        | Planned | Planned | Planned |
| Attachments                                          | Yes      | Yes        | Planned | Planned | Planned |
| Statistics                                           | Yes      | Yes        | Planned | Planned | Planned |
| Unknown-record skipping                              | Yes      | Yes        | Planned | Planned | Planned |
| Private-range records                                | Yes      | Yes        | Planned | Planned | Planned |
| Encode                                               | Yes      | Planned    | Planned | Planned | Planned |
| Chunked encode                                       | Yes      | Planned    | Planned | Planned | Planned |
| Summary writing                                      | Yes      | Planned    | Planned | Planned | Planned |
| Convert from PLY frame sequences                     | Untested | No         | No      | No      | No      |
| Inspect and validate                                 | Untested | Planned    | Planned | Planned | Planned |

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
can decode from an arbitrary byte-range reader, but only some ship an HTTP one. TypeScript's `Yes`
covers the decode, which the indexed runner exercises over ranged reads; the HTTP transport it ships
in `@4dgs/browser` is covered by that package's own tests, not by the corpus.

**Encode** stays `Planned` for TypeScript because there is no TypeScript encoder. The packages there
decode; the reference encoder is Python's.

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
features, so the conformance suite does not cover them. This table said they were marked from their
own tests. They have none — not a partial suite, none — so they are `Untested` until they do. The
code exists and may well be correct; that is not the same claim and this table does not make it.

**Rust** is a compiling stub today: the crate exists so the workspace and the release machinery are
real, and its bodies are unimplemented. Python is the reference implementation until it lands.

**C++** and **Swift** are declared, not started. When Rust lands, the intended path for both is to
generate their surface from Rust's C ABI — a header or a binding plus a thin shim — rather than
hand-writing and then maintaining parallel implementations. Swift targets visionOS and iOS.
