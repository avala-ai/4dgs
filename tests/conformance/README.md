# Conformance suite

The contract between implementations. An SDK claims a feature by passing this suite for it, and the
[feature matrix](../../website/docs/reference/index.md) records only what the suite proves.

## How it works

`generator/scenarios.py` declares **scenarios** (scene shapes) and **feature flags**, and their
legal combinations are **variants**. For each variant the generator writes:

- `data/<variant>.4dgs` — a real file, **not committed** (see below)
- `data/<variant>.json` — exactly what a correct decoder must produce from it, committed

Each implementation ships a small runner that reads a `.4dgs` and prints the canonical JSON to
stdout. The harness runs every runner over every variant it declares support for and diffs against
the committed expectation.

## No binaries in the repository

The `.4dgs` files are **generated, not committed** — `data/.gitignore` excludes them, and
`generate.py` reconstructs them deterministically before every run. What is committed is the JSON
expectations plus `data/CHECKSUMS.txt`, a SHA-256 per variant.

`generate.py --verify` is the gate: it regenerates the corpus, asserts every checksum matches, and
asserts that **two consecutive generator runs produce byte-identical files**. That second check is
the one that catches accidental nondeterminism in an encoder — iteration order, a timestamp, a hash
seed — which is otherwise invisible until someone else's CI fails.

Hard cap: `data/` stays under 2.5 MB. If new variants push past it, prune combinations; do not raise
the cap.

## Synthetic only

Every scene is generated from a fixed seed by `build_gaussians`, and the audio track is a generated
sine sweep. There is no captured data in this repository and there will not be: the corpus must be
redistributable without a licence question and reproducible without a download.

## Runners

A runner is three abstractions:

| Runner           | Reads                                    | Produces                                         |
| ---------------- | ---------------------------------------- | ------------------------------------------------ |
| `StreamedDecode` | the file front to back, no seeking       | canonical JSON of all gaussians                  |
| `IndexedDecode`  | the index, then only the chunks it needs | the same JSON, derived from the same expectation |
| `Encode`         | the expectation JSON                     | a `.4dgs` the decoders must agree on             |

Each declares `name` and `supportsVariant(variant)`. **A partial implementation is expected**: a
runner that returns `False` for a variant is skipped, not failed, and the feature matrix is where
that shows up publicly.

Python runners are invoked as subprocesses that print JSON to stdout; TypeScript runners run in
process. A new language needs one stdout CLI and one small entry in the harness.

## Canonical JSON

So that two languages can be diffed without arguing about representation:

- integers are strings, so a 64-bit value survives a JSON parser that uses doubles
- byte strings are arrays of numbers
- floats are rounded to a fixed number of decimals before comparison
- `sigma_t` for a never-fading gaussian is `null`, never a sentinel number
- `"audio"` is `null` when absent and an object when present, so both paths are visible in every
  implementation's output
- keys are sorted; the harness stable-stringifies before diffing and colourizes the first divergence

`--update` rewrites the expectations from the current implementation. Use it when you have decided a
change is correct, never to make a red suite green.
