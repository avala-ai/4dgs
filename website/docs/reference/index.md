# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a deliberate,
documented state — not a defect — and this table is the public contract that says so.

**A `Yes` means the conformance suite proves it.** Each SDK declares the variants it supports via
`supportsVariant()`, the harness runs exactly those, and this table is kept in lockstep with those
declarations. Nothing is marked `Yes` on the strength of code existing.

Python's row is filled in from a suite that runs: 26 variants, two read paths (streamed and
indexed), 51 checks passing. The other languages have not been run against it yet.

| Feature                                              | Python  | TypeScript | Rust    | C++     | Swift   |
| ---------------------------------------------------- | ------- | ---------- | ------- | ------- | ------- |
| Streaming decode                                     | Yes     | Planned    | Planned | Planned | Planned |
| Indexed / seeking decode                             | Yes     | Planned    | Planned | Planned | Planned |
| Range-request decode                                 | Yes     | Planned    | Planned | Planned | Planned |
| Truncated-file recovery                              | Yes     | Planned    | Planned | Planned | Planned |
| Chunk index                                          | Yes     | Planned    | Planned | Planned | Planned |
| Summary offsets                                      | Yes     | Planned    | Planned | Planned | Planned |
| CRC validation                                       | Yes     | Planned    | Planned | Planned | Planned |
| Quantized attributes                                 | Yes     | Planned    | Planned | Planned | Planned |
| Spherical harmonics, degree 1                        | Yes     | Planned    | Planned | Planned | Planned |
| Spherical harmonics, degree 2                        | Yes     | Planned    | Planned | Planned | Planned |
| Spherical harmonics, degree 3                        | Planned | Planned    | Planned | Planned | Planned |
| SH band range-skipping                               | Yes     | Planned    | Planned | Planned | Planned |
| Embedded audio (optional, zero-overhead when absent) | Yes     | Planned    | Planned | Planned | Planned |
| Camera trajectory                                    | Yes     | Planned    | Planned | Planned | Planned |
| Metadata                                             | Yes     | Planned    | Planned | Planned | Planned |
| Attachments                                          | Yes     | Planned    | Planned | Planned | Planned |
| Statistics                                           | Yes     | Planned    | Planned | Planned | Planned |
| Unknown-record skipping                              | Yes     | Planned    | Planned | Planned | Planned |
| Private-range records                                | Yes     | Planned    | Planned | Planned | Planned |
| Encode                                               | Yes     | Planned    | Planned | Planned | Planned |
| Chunked encode                                       | Yes     | Planned    | Planned | Planned | Planned |
| Summary writing                                      | Yes     | Planned    | Planned | Planned | Planned |
| Convert from PLY frame sequences                     | Yes     | No         | No      | No      | No      |
| Inspect and validate                                 | Yes     | Planned    | Planned | Planned | Planned |

## Reading this table

- **Yes** — implemented and conformance-verified.
- **Planned** — intended for this SDK; not implemented yet.
- **No** — not intended for this SDK. Conversion tooling, for example, belongs where people run
  batch jobs, not in a browser bundle.

## Notes

**Embedded audio** is optional in every sense. A scene without audio carries no audio record at all,
and every SDK exposes audio as an optional value rather than an error state. Most files will have
none; that is the common case, and it costs nothing.

**Range-request decode** is a property of the transport an SDK offers, not of the format: every SDK
can decode from an arbitrary byte-range reader, but only some ship an HTTP one.

**Convert from PLY frame sequences** takes a directory of standard per-frame gaussian splat PLY
files — the common interchange form — and produces a `.4dgs`. It lives in the Python package because
it is a batch operation.

**Spherical harmonics, degree 3** is implemented and unit-tested in Python, but the conformance
corpus only carries degree 1 and 2 variants, so by this table's own rule it does not get a `Yes`
yet. Adding the variant is the work, not adding the feature.

**Convert from PLY frame sequences** and **Inspect and validate** are tools rather than wire-format
features, so the conformance suite does not cover them; they are marked from their own tests.

**Rust** is a compiling stub today: the crate exists so the workspace and the release machinery are
real, and its bodies are unimplemented. Python is the reference implementation until it lands.

**C++** and **Swift** are declared, not started. When Rust lands, the intended path for both is to
generate their surface from Rust's C ABI — a header or a binding plus a thin shim — rather than
hand-writing and then maintaining parallel implementations. Swift targets visionOS and iOS.
