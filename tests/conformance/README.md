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

## The invalid corpus: files that must be refused

A corpus of valid files can only prove that a decoder accepts what it should. It cannot prove that a
decoder **refuses** what it should — and a large part of this specification is rules whose entire
content is a refusal: a window index outside its table, a codec this build does not implement, a
temporal model this reader has never heard of. A decoder that ignores every one of them passes all
34 valid variants.

`generator/invalid.py` declares the other half. Each entry is a length-preserving byte mutation of
one valid base file, chosen so that **exactly one** rule is broken, paired with the **refusal
identifier** a conforming reader must produce. `data/invalid/<Name>.json` is the expectation, and it
looks like this:

```json
{ "refused": "window-index-out-of-range" }
```

### Why an identifier and not an exception type

"Both decoders raised an error" is not agreement. `MalformedFile` covers a dozen distinct faults, so
a negative test that only checks that something was raised passes when a decoder refuses for the
wrong reason — which is the failure mode a negative test is supposed to catch. The identifier says
**which rule**, and it is the same string in every language.

The identifiers are declared once, in `invalid.py`. A language does not invent one.

### The runner contract

A refusal is a **result, not a crash**: the runner prints `{"refused": "<id>"}` on stdout and exits
0, and the harness diffs it like any other answer. Exiting non-zero would collapse "refused
correctly" and "fell over" into one outcome, and those are exactly what this corpus exists to tell
apart.

An exception carrying no identifier prints an empty one, which matches no expectation and fails with
a readable diff. A refusal a library cannot name is one the suite cannot check, and it should look
like a gap rather than a pass.

`REFUSAL_FAMILIES` in `run.py` lists the families whose runners answer these. A family absent from
it skips the invalid corpus exactly as it would skip any variant it declines, and the feature matrix
is where that shows up publicly.

### Every rule here already existed

Nothing in the invalid corpus is new specification. That is deliberate: the contract is exercised
against rules that predate it, rather than arriving at the same time as the rules it is meant to
police. A harness feature whose only exercise is the feature it was built for has not been tested —
it has been co-designed with its single test.

It earned its keep on the first run. Two rules the specification states plainly were not enforced by
the reference reader at all: an unknown `temporal_model` and an unknown quantization `scheme` both
decoded as though they were the known value, silently, into a scene that looks entirely plausible.
And a file whose first byte was corrupt was reported as an unsupported _version 1_ — an error that
sends its holder looking for a newer reader that would have refused it too.

### Truncation is not in here

A cut file is recoverable, not refusable: records are length-prefixed and a reader should salvage
the intact prefix. Truncation stays where it was, checked by each runner against the valid corpus.

## Synthetic only

Every scene is generated from a fixed seed by `build_gaussians`, and the audio track is a generated
sine sweep. There is no captured data in this repository and there will not be: the corpus must be
redistributable without a licence question and reproducible without a download.

## Known gaps

Recorded here rather than left implicit, because a gap nobody wrote down is indistinguishable from
coverage.

- **The Header's `library` is the same string in every variant.** `profile` varies — `baked` in the
  two `LongLived` variants, `capture` everywhere else — so an implementation that drops it fails.
  `library` is always `4dgs conformance generator`, which catches a runner that omits the field or
  returns an empty string, but not one that hardcodes the expected value. Fixing it means varying
  the generator's `library` per variant, which moves every checksum; it is recorded rather than done
  because the failure it would catch is one nobody has ever made, and the one it does catch —
  omission — is the one that actually happened.

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
C++ and Swift run it on Linux. Every platform decodes the same 34 variants and compares against the
same committed expectations — 67 passing comparisons per family, with the single `decode_indexed`
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
- the same holds field by field. The Header's `profile` and `library` are emitted for that reason:
  every SDK could read them and none asserted them, so a runner that returned an empty string for
  both produced a summary identical to a correct one. A field no expectation mentions is a field an
  implementation can decline to decode, and the failure that hides is the dangerous kind — a pass
  that proves less than it looks like it does

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
