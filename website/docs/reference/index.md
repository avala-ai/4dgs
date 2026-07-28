# Feature support matrix

Support in this project is **per feature, not per language**. A partial SDK is a
deliberate, documented state — not a defect — and this table is the public contract that
says so.

**A `Yes` means the conformance suite proves it.** Each SDK declares the variants it
supports via `supportsVariant()`, the harness runs exactly those, and this table is kept
in lockstep with those declarations. Nothing is marked `Yes` on the strength of code
existing — which is why every cell below currently reads `Planned`: the specification and
the conformance scenarios are defined, and no implementation has yet been run against
them in this repository. Cells flip to `Yes` as the suite starts passing, one row at a
time.

| Feature | Python | TypeScript | Rust | C++ | Swift |
|---|---|---|---|---|---|
| Streaming decode | Planned | Planned | Planned | Planned | Planned |
| Indexed / seeking decode | Planned | Planned | Planned | Planned | Planned |
| Range-request decode | Planned | Planned | Planned | Planned | Planned |
| Truncated-file recovery | Planned | Planned | Planned | Planned | Planned |
| Chunk index | Planned | Planned | Planned | Planned | Planned |
| Summary offsets | Planned | Planned | Planned | Planned | Planned |
| CRC validation | Planned | Planned | Planned | Planned | Planned |
| Quantized attributes | Planned | Planned | Planned | Planned | Planned |
| Spherical harmonics, degree 1 | Planned | Planned | Planned | Planned | Planned |
| Spherical harmonics, degree 2 | Planned | Planned | Planned | Planned | Planned |
| Spherical harmonics, degree 3 | Planned | Planned | Planned | Planned | Planned |
| SH band range-skipping | Planned | Planned | Planned | Planned | Planned |
| Embedded audio (optional, zero-overhead when absent) | Planned | Planned | Planned | Planned | Planned |
| Camera trajectory | Planned | Planned | Planned | Planned | Planned |
| Metadata | Planned | Planned | Planned | Planned | Planned |
| Attachments | Planned | Planned | Planned | Planned | Planned |
| Statistics | Planned | Planned | Planned | Planned | Planned |
| Unknown-record skipping | Planned | Planned | Planned | Planned | Planned |
| Private-range records | Planned | Planned | Planned | Planned | Planned |
| Encode | Planned | Planned | Planned | Planned | Planned |
| Chunked encode | Planned | Planned | Planned | Planned | Planned |
| Summary writing | Planned | Planned | Planned | Planned | Planned |
| Convert from PLY frame sequences | Planned | No | No | No | No |
| Inspect and validate | Planned | Planned | Planned | Planned | Planned |

## Reading this table

- **Yes** — implemented and conformance-verified.
- **Planned** — intended for this SDK; not implemented yet.
- **No** — not intended for this SDK. Conversion tooling, for example, belongs where
  people run batch jobs, not in a browser bundle.

## Notes

**Embedded audio** is optional in every sense. A scene without audio carries no audio
record at all, and every SDK exposes audio as an optional value rather than an error
state. Most files will have none; that is the common case, and it costs nothing.

**Range-request decode** is a property of the transport an SDK offers, not of the format:
every SDK can decode from an arbitrary byte-range reader, but only some ship an HTTP one.

**Convert from PLY frame sequences** takes a directory of standard per-frame gaussian
splat PLY files — the common interchange form — and produces a `.4dgs`. It lives in the
Python package because it is a batch operation.

**Rust** is a compiling stub today: the crate exists so the workspace and the release
machinery are real, and its bodies are unimplemented. Python is the reference
implementation until it lands.

**C++** and **Swift** are declared, not started. When Rust lands, the intended path for
both is to generate their surface from Rust's C ABI — a header or a binding plus a thin
shim — rather than hand-writing and then maintaining parallel implementations. Swift
targets visionOS and iOS.
