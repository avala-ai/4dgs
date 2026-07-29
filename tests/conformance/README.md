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

**A new entry in `RUNNERS` needs the `EXE` suffix if it is compiled.** Windows names an executable
`decode_streamed.exe`, and the harness finds a runner by testing its path for existence — so a
compiled family without the suffix is reported "not built" on Windows and silently contributes
nothing. It does not stay silent for long, because a family asked for by name and never executed is
a failure, but the error names the runner rather than the platform and reads like a build problem.

## Platforms

The suite runs on GitHub-hosted runners for Python, TypeScript and Rust on Linux, macOS and Windows;
C++ and Swift run it on Linux. Every platform decodes the same 32 variants and compares against the
same committed expectations — 63 passing comparisons per family, with the single `decode_indexed`
variant that declares no chunk index skipped.

That the corpus is bytes is the whole reason this is worth doing on more than one platform: a
decoder that agrees with the expectation on Linux and disagrees on Windows is exactly the bug this
suite exists to find, and it is invisible to a suite that only ever runs in one place.

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

### How a number is allowed to be spelled

**The harness compares parsed JSON, not text.** `run.py` diffs `json.loads(actual)` against
`json.loads(expected)`, so a runner is never required to reproduce the expectation file
byte-for-byte — only to parse to the same values. This is the convention, stated here so nobody has
to rediscover it from a checksum mismatch:

- **A language may spell a number however it likes.** Python writes `50.0` where JavaScript writes
  `50`; `1e-06` and `0.000001` are the same number; `1.0E+2` and `100.0` are the same number. All of
  these compare equal, and none of them needs normalizing in a runner.
- **`-0.0` and `0` compare equal**, so a runner need not chase the sign of a zero.
- **Type is not spelling.** `50` and `"50"` are _not_ equal — one is a number and one is a string.
  This matters because the summary deliberately emits 64-bit integers _as strings_ (so a parser
  backed by doubles cannot round them), and a runner that emits those as JSON numbers fails even
  though the digits match.
- **Rounding is the runner's job, not the harness's.** Comparison is exact equality on the parsed
  value — there is no tolerance. Every float must already be rounded to `FLOAT_DECIMALS` (6) before
  it is printed, because `0.30000000000000004` and `0.3` are simply different numbers here.
- **Non-finite values are never spelled at all.** JSON has no `NaN` or `Infinity`, so the summary
  maps them to `null` (`allow_nan=False` makes emitting one an error rather than a surprise). A
  never-fading gaussian's `sigma_t` is `null` for that reason.

The committed `.json` files are written by the Python generator, so they carry Python's spelling of
every float. That is an artifact of who wrote them, not a requirement on anyone reading them.

## Fixture variety is a feature to cover, too

The sibling of the size blind spot above, and the one that is easier to miss: a corpus can be
uniform in a way real data never is. Every scenario here draws its positions from a PRNG, so every
position in the corpus was distinct — and the canonical order's tie-break, the rule that says the
sort key is the gaussian's _whole_ decoded state, never actually ran. A decoder that ranked
gaussians by position and then fell back to its own decode index agreed with all 28 variants and
disagreed with every real file. That is not hypothetical; it happened downstream.

Real multi-window content carries one gaussian per validity window at the **same** position, because
a thing that stays put while the clip runs is stored once per window. `RepeatedPositions` is that
shape: 32 points, each repeated across seven windows with identical position, scale, rotation,
colour and velocity, so only the temporal fields separate a group — tie-groups seven deep, which is
what the real file that exposed this had.

When you add a scenario, ask what the generator makes _uniform_ that real captures do not, and say
so in the scenario comment. Distinctness is the one that bit; it will not be the last.
