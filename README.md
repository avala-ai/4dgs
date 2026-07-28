# 4dgs

**4D gaussian splat video with native audio — one file, seekable.**

A `.4dgs` file holds a whole moving gaussian-splat scene: gaussians whose position,
opacity and existence vary continuously over time, plus an optional soundtrack and a
default camera, in a single self-contained resource you can range-request and seek like a
video.

> This repository is the 4dgs format: its specification, its conformance suite, and SDKs
> for reading and writing it. Viewers, renderers, engine integrations, and performance
> tooling are out of scope.

## What it is

- **Continuous time, not sampled frames.** Each gaussian carries its own birth time,
  temporal extent, motion and validity window, so the number of live gaussians varies over
  time with no frame machinery and no fixed splat count.
- **Seekable.** A byte-range index maps time to chunks. Displaying an instant reads the
  index and then only that instant's ranges.
- **Audio is native, and its absence is free.** A scene with a soundtrack carries it in
  the file; a scene without one carries nothing at all — no placeholder, no silent track,
  no branch in your code.
- **Forward compatible by construction.** Every top-level structure is a length-prefixed
  record with an opcode, so readers skip what they do not recognize. A private opcode range
  is reserved for application data.
- **Stated error bounds.** Lossy encodings declare the maximum deviation per attribute,
  and encoders verify it.
- **Renderer-agnostic.** Decoding ends at reconstructed gaussian state at time `t`.

## Specification

- [Specification](website/docs/spec/index.md) — normative
- [Registry](website/docs/spec/registry.md) — codecs, schemes, profiles, well-known keys
- [Implementation notes](website/docs/spec/notes.md) — non-normative decode guidance
- [Feature support matrix](website/docs/reference/index.md) — what each SDK implements
- [Concepts](website/docs/guides/concepts.md) — the vocabulary every SDK uses

## Libraries

| Language | Readme | Package | Status |
|---|---|---|---|
| Python | [python/](python/) | `4dgs` | Reference implementation |
| TypeScript | [typescript/](typescript/) | `@4dgs/core` | In progress |
| Rust | [rust/](rust/) | — | Planned |
| C++ | [cpp/](cpp/) | — | Planned |
| Swift | [swift/](swift/) | — | Planned (visionOS) |

Support is per-feature, not per-language: see the
[feature matrix](website/docs/reference/index.md), which the conformance suite enforces.

## Getting started

- [Encode a scene (Python)](website/docs/guides/getting-started/encode-python.md)
- [Decode in a browser](website/docs/guides/getting-started/decode-web.md)
- [Decode in Python](website/docs/guides/getting-started/decode-python.md)

## Conformance

Every implementation is checked against the same generated corpus of synthetic scenes; a
"Yes" in the feature matrix means the conformance suite passes for that feature. See
[tests/conformance/](tests/conformance/).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first — it states what is in scope and what is
not. Spec changes follow a defined process; new language SDKs have a three-step recipe.

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
