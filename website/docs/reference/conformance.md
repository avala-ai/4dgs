# Conformance suite

The contract between implementations. An SDK claims a feature by passing this suite for it, and the
[feature matrix](./index.md) records only what the suite proves.

The suite itself lives in
[`tests/conformance/`](https://github.com/avala-ai/4dgs/tree/main/tests/conformance), and its
[README](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/README.md) is the authority on
how to run it and how to add to it. This page is the short orientation.

## Scenarios, flags, variants

`generator/scenarios.py` declares scenarios — scene shapes — and feature flags. Their legal
combinations are **variants**, and for each variant the generator writes two things:

- `data/<variant>.4dgs`, a real file, **not committed**
- `data/<variant>.json`, exactly what a correct decoder must produce from it, committed

## The corpus is generated, not committed

`generate.py` reconstructs every `.4dgs` deterministically before a run, and CI refuses a committed
one. What is committed is the JSON expectations plus a SHA-256 per variant.

`generate.py --verify` is the gate: it regenerates the corpus, asserts every checksum, and asserts
that two consecutive generator runs produce byte-identical files. That second check is what catches
accidental nondeterminism in an encoder — an iteration order, a timestamp, a hash seed — before it
becomes somebody else's failing build.

Every scene is synthetic, generated from a fixed seed, and the audio is a generated sine sweep.
There is no captured data in the repository: the corpus has to be redistributable without a licence
question and reproducible without a download.

## Runners

Each implementation ships small command-line runners that read a `.4dgs` and print canonical JSON to
stdout. The harness runs every runner over every variant it declares support for and diffs the
result against the committed expectation.

| Runner           | Reads                                    | Produces                                         |
| ---------------- | ---------------------------------------- | ------------------------------------------------ |
| `StreamedDecode` | the file front to back, no seeking       | canonical JSON of all gaussians                  |
| `IndexedDecode`  | the index, then only the chunks it needs | the same JSON, derived from the same expectation |
| `Encode`         | the expectation JSON                     | a `.4dgs` the decoders must agree on             |

A runner declares a name and a `supportsVariant(variant)` predicate. **A partial implementation is
expected**: a variant a runner declines is skipped rather than failed, and the feature matrix is
where that shows up publicly. Adding a language needs one stdout CLI and one line in `RUNNERS`.

## Canonical JSON

So two languages can be diffed without arguing about representation, the summary each runner prints
follows fixed rules: 64-bit integers are emitted as strings so a double-backed parser cannot round
them, byte strings are arrays of numbers, floats are rounded to a fixed number of decimals, absent
values are `null` rather than a sentinel, and keys are sorted.

Nothing depends on decoded order — an encoder may reorder gaussians freely, so the sample, the
aggregates and the spherical-harmonic digest are all taken in a content order derived from decoded
values alone. Records that are not gaussians are summarized too, because a record that changes
nothing in the output is a record an implementation could ignore entirely and still pass.

The harness compares parsed JSON rather than text, so a language may spell a number however it
likes; type, however, is not spelling, and a runner that emits a 64-bit integer as a JSON number
fails even though the digits match.

## Running it

```sh
python3 tests/conformance/generate.py
python3 tests/conformance/run.py --runner python
```

Swap `--runner` for the language you are working on. A language with a build step needs its entry
point built first; the harness skips a family whose entry point is missing, and fails if a family
was asked for by name and never ran.

## Known gaps

Gaps are recorded rather than left implicit, because a gap nobody wrote down is indistinguishable
from coverage. The current one is spherical harmonics of degree 3: the corpus carries degree 1 and 2
only, so no implementation can claim degree 3 however complete its code is. The
[conformance README](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/README.md) keeps
that list current.
