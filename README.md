# 🧊 4dgs

[![PyPI][pypi-badge]][pypi] [![npm][npm-badge]][npm] [![crates.io][crates-badge]][crates]
[![CI][ci-badge]][ci] [![Conformance][conformance-badge]][conformance]

**4D gaussian splat video with native audio — one file, seekable.**

Documentation lives at **[4dgs.dev](https://4dgs.dev)** — the specification, per-language guides,
and the conformance story, rendered from this repository.

A `.4dgs` file holds a whole moving gaussian-splat scene: gaussians whose position, opacity and
existence vary continuously over time, plus an optional soundtrack and a default camera, in a single
self-contained resource you can range-request and seek like a video.

> This repository is the 4dgs format: its specification, its conformance suite, and SDKs for reading
> and writing it. Viewers, renderers, engine integrations, and performance tooling are out of scope.

## What it is

- **Continuous time, not sampled frames.** Each gaussian carries its own birth time, temporal
  extent, motion and validity window, so the number of live gaussians varies over time with no frame
  machinery and no fixed splat count.
- **Seekable.** A byte-range index maps time to chunks. Displaying an instant reads the index and
  then only that instant's ranges.
- **Audio is native, and its absence is free.** A scene with a soundtrack carries it in the file; a
  scene without one carries nothing at all — no placeholder, no silent track, no branch in your
  code.
- **Forward compatible by construction.** Every top-level structure is a length-prefixed record with
  an opcode, so readers skip what they do not recognize. A private opcode range is reserved for
  application data.
- **Stated error bounds.** Lossy encodings declare the maximum deviation per attribute, and encoders
  verify it.
- **Renderer-agnostic.** Decoding ends at reconstructed gaussian state at time `t`.

## Specification

- [Specification](website/docs/spec/index.md) — normative
- [Registry](website/docs/spec/registry.md) — codecs, schemes, profiles, well-known keys
- [Implementation notes](website/docs/spec/notes.md) — non-normative decode guidance
- [Feature support matrix](website/docs/reference/index.md) — what each SDK implements
- [Concepts](website/docs/guides/concepts.md) — the vocabulary every SDK uses
- [Kaitai Struct grammar](kaitai/) — the file's structure, machine-readable, for tooling that does
  not link an SDK. Not a decoder and not on the matrix

## Libraries

| Language   | Readme                     | Package      | Status                                           |
| ---------- | -------------------------- | ------------ | ------------------------------------------------ |
| Python     | [python/](python/)         | `fourdgs`    | Reference implementation                         |
| TypeScript | [typescript/](typescript/) | `@4dgs/core` | Decoder, conformance-verified                    |
| Rust       | [rust/](rust/)             | `fourdgs`    | Decoder, conformance-verified                    |
| C++        | [cpp/](cpp/)               | —            | Decoder over Rust's C ABI, conformance-verified  |
| Swift      | [swift/](swift/)           | —            | Binding over Rust; decoder, conformance-verified |

Package names are `fourdgs` where a registry will not take `4dgs`; the format, the CLI and the file
extension are always `4dgs`. [RELEASING.md](RELEASING.md) has the constraint per registry.

Packages are versioned independently. [CHANGELOG.md](CHANGELOG.md) indexes the per-package
changelogs and logs every release; each one is also a
[GitHub Release](https://github.com/avala-ai/4dgs/releases) carrying the same notes.

Support is per-feature, not per-language: see the [feature matrix](website/docs/reference/index.md),
which the conformance suite enforces.

## Getting started

- [Encode a scene (Python)](website/docs/guides/getting-started/encode-python.md)
- [Decode in a browser](website/docs/guides/getting-started/decode-web.md)
- [Decode in Python](website/docs/guides/getting-started/decode-python.md)
- [Decode in C++](website/docs/guides/getting-started/decode-cpp.md)

## Conformance

Every implementation is checked against the same generated corpus of synthetic scenes; a "Yes" in
the feature matrix means the conformance suite passes for that feature. See
[tests/conformance/](tests/conformance/).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first — it states what is in scope and what is not. Spec
changes follow a defined process; new language SDKs have a three-step recipe.

## Citation

```bibtex
@software{4dgs,
  title = {4dgs: a container format for 4D gaussian splat scenes},
  year  = {2026},
  url   = {https://github.com/avala-ai/4dgs}
}
```

## License

[Apache-2.0](LICENSE). See [NOTICE](NOTICE).

[pypi-badge]: https://img.shields.io/pypi/v/fourdgs?style=flat-square&label=PyPI
[pypi]: https://pypi.org/project/fourdgs/
[npm-badge]: https://img.shields.io/npm/v/%404dgs%2Fcore?style=flat-square&label=npm
[npm]: https://www.npmjs.com/package/@4dgs/core
[crates-badge]: https://img.shields.io/crates/v/fourdgs?style=flat-square&label=crates.io
[crates]: https://crates.io/crates/fourdgs
[ci-badge]:
  https://img.shields.io/github/actions/workflow/status/avala-ai/4dgs/ci.yml?branch=main&style=flat-square&label=CI
[ci]: https://github.com/avala-ai/4dgs/actions/workflows/ci.yml
[conformance-badge]:
  https://img.shields.io/github/actions/workflow/status/avala-ai/4dgs/conformance.yml?branch=main&style=flat-square&label=conformance
[conformance]: https://github.com/avala-ai/4dgs/actions/workflows/conformance.yml
