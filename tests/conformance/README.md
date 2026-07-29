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

## Known gaps

Recorded here rather than left implicit, because a gap nobody wrote down is indistinguishable from
coverage.

- **Spherical harmonics, degree 3.** The corpus carries degree 1 and 2 only, so no implementation
  can claim degree 3 however complete its code is. Adding it is one line in `scenarios.py` — degree
  3 is 45 coefficients per gaussian against degree 2's 24, so the variant should use a small
  scenario to stay inside the size cap, and `SH_BAND_RANGE`'s band 3 entry already describes the
  layout.

## Fixture scale is a feature to cover, not a detail

Small fixtures hide a whole class of bug: anything that only appears once a record is larger than a
buffer, a window, or a threshold an implementation chose. `WithLargeAudio` exists for exactly that
reason — its track is bigger than the 64 KiB probe an indexed reader opens a file with, and an Audio
record lives in the front matter, so a reader that walks the front matter by materializing each
record instead of stepping over it by length fails on that variant and on no other. Both
implementations in this repository had that bug, and every other fixture was too small to say so.

A new variant that exists to cross a size threshold should say which threshold, and why, in its
scenario comment. Keep them few and keep them just past the line: the corpus cap is 2.5 MB, and a
fixture that is merely large proves nothing that one which is deliberately one byte too big does
not.

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

Every runner is invoked the same way: as a subprocess, with a path, printing canonical JSON to
stdout. A new language needs one stdout CLI and one line in `RUNNERS`. A language with a build step
adds its built entry point there; the harness skips a family whose entry point is missing, so a
contributor who has not built it still gets a clean run, and fails if a family was asked for by name
and never ran.

## Canonical JSON

So that two languages can be diffed without arguing about representation:

- integers are strings, so a 64-bit value survives a JSON parser that uses doubles
- byte strings are arrays of numbers
- floats are rounded to a fixed number of decimals before comparison
- `sigma_t` for a never-fading gaussian is `null`, never a sentinel number
- `"audio"` is `null` when absent and an object when present, so both paths are visible in every
  implementation's output
- keys are sorted; the harness stable-stringifies before diffing and colourizes the first divergence
- **nothing depends on decoded order.** Gaussians may be reordered freely by an encoder, so the
  sample, the aggregates and the spherical harmonic digest are all taken in a content order derived
  from decoded values alone. Two gaussians that tie on every decoded value are identical in every
  number the summary emits, so their relative order cannot change it
- records that are not gaussians are summarized too — the camera, the metadata, the attachments, the
  statistics, the summary offsets, and whether the footer's CRC verified. A record that changes
  nothing here is a record an implementation could ignore entirely and still pass, which is how a
  feature matrix ends up claiming things the suite never checked

`--update` rewrites the expectations from the current implementation. Use it when you have decided a
change is correct, never to make a red suite green.
