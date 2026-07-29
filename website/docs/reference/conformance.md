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

Every scene is synthetic, generated from a fixed seed, and audio payloads are generated sine sweeps.
The spatial cases include fixed and moving sources; there is no captured data in the repository. The
corpus has to be redistributable without a licence question and reproducible without a download.

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

## Files that must be refused

A corpus of valid files proves only that a decoder accepts what it should. Much of the specification
is rules whose whole content is a refusal — an out-of-range window index, an unimplemented codec, a
temporal model the reader does not know — and a decoder that ignores all of them passes every valid
variant.

`generator/invalid.py` declares the other half: length-preserving byte mutations of one valid base
file, each breaking exactly one rule, each paired with the **refusal identifier** a conforming
reader must produce. The expectation is `{ "refused": "window-index-out-of-range" }`, and the runner
prints it on stdout and exits 0 — a refusal is a result, not a crash, and collapsing it into a
non-zero exit would make "refused correctly" indistinguishable from "fell over".

The identifier matters more than it looks. "Both decoders raised an error" is not agreement: one of
them may have refused for the wrong reason, which is precisely the failure a negative test exists to
catch. The identifier names the rule, and it is the same string in every language.

Every rule in this corpus already existed in version 1 — nothing here is new specification, so the
contract is proved against rules that predate it. It found three real faults on its first run:
neither an unknown `temporal_model` nor an unknown quantization `scheme` was refused at all, both
decoding silently as the known value, and a corrupt first byte was reported as an unsupported
version 1.

Truncation is deliberately not here. A cut file is recoverable rather than refusable, and each
runner still checks that against the valid corpus.

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
from coverage. Degree-3 spherical harmonics used to be the one worth naming here; the corpus now
carries two degree-3 variants and every SDK decodes them, so the current entry is a smaller one —
the Header's `library` is the same string in every variant, which catches a runner that drops the
field but not one that hardcodes it. The
[conformance README](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/README.md) keeps
that list current.
