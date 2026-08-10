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
46 valid variants.

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
is where that shows up publicly. A runner from outside this repository does not appear in that set
and does not need to: it says `"refusals": true` in its own declaration (see
[below](#running-a-runner-that-lives-outside-this-repository)) and is scored on all seven.

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

### Two gaps the invalid corpus has surfaced but does not yet close

Recorded here because a gap nobody wrote down is indistinguishable from coverage.

**The validators do not decode streams.** `validate` walks the framing and opens the file the way a
seeking client would; it never decodes a chunk's attribute streams. So neither the Rust nor the
Python validator reports anything about `UnknownStreamCodec.4dgs`, whose only fault is a codec byte
inside a stream. The _decoders_ refuse it — the conformance runners prove that — so this is a
thinness in the validators rather than a hole in the readers, and the cross-validator test exempts
that class explicitly rather than passing over it silently.

**The two languages word the magic and version refusals differently.** Rust prefixes its error kind
(`unsupported version: not a 4dgs file (bad magic)`) where Python does not, and Python spells a byte
`b'2'` where Rust spells it `'2'`. The temporal-model and quantization-scheme refusals are compared
line for line because the specification writes those sentences; the magic and version ones are not,
yet. Closing it means changing messages in both languages, which is its own change.

### Truncation is not in here

A cut file is recoverable, not refusable: records are length-prefixed and a reader should salvage
the intact prefix. Truncation stays where it was, checked by each runner against the valid corpus.

## Synthetic only

Every scene is generated from a fixed seed by `build_gaussians`, and audio source payloads are
generated sine sweeps. There is no captured data in this repository and there will not be: the
corpus must be redistributable without a licence question and reproducible without a download.

## Declining a feature is how a partial SDK stays honest

`run.py` lets a whole language family decline the variants carrying a feature it has not
implemented, through `FAMILY_DECLINES`; a runner from outside this repository declines by listing
the same name fragments in its own declaration. The object-layer variants are the current users of
it: C++ and Swift decline them, and the feature matrix records the `No`. TypeScript and Dart used to
sit in that list and no longer do — they decode the object layer and compose its tracks natively,
which is what removing a family from `FAMILY_DECLINES` is supposed to look like. Every family
reports provenance (spec §5.15); C++ and Swift do so through the Rust C ABI's additive
provenance-JSON accessor.

The alternative to optional keys was worse in a way worth writing down. The canonical summary emits
its `provenance` section **only when the file carries provenance** — unlike `audioSources`, which is
empty when absent because audio presence is a property of every file and both paths must stay
visible. Had provenance followed the `audioSources` convention, every one of the 34 pre-existing
expectations would have gained `"provenance": null`, and any SDK that correctly skipped the records
by length would have gone red on all of them. The suite would have reported the format's
forward-compatibility mechanism working as 34 failures.

So the shape is: a file without provenance is byte-identical to what it was before the family
existed, its expectation is unchanged, and every SDK passes it untouched — that is the assertion. A
file with provenance is compared in full by every SDK that reports the family.

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
reason — its Audio Data payload is bigger than the 64 KiB probe an indexed reader opens a file with,
and source pairs live in the front matter. A reader that walks the front matter by materializing
each record instead of stepping over it by length fails on that variant and on no other. Both
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

**A partial implementation is expected**: a variant a runner declines is skipped, not failed, and
the feature matrix is where that shows up publicly. For the runners in this repository the decision
is the harness's — `FAMILY_DECLINES`, `REFUSAL_FAMILIES` and the `decode_indexed` rule, all in
`run.py`. For a runner outside it, the runner declares it; see the next section.

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

**Every entry in `RUNNERS` ends in a path**, because that last element existing is how the harness
decides the family is built. That is a property of this table, not of runners in general:
`go run ./cmd/runner` and `dotnet run --project X` end in neither a script nor a binary, which is
why a runner driven with `--runner-cmd` is asked a different question entirely.

## Running a runner that lives outside this repository

An implementation this repository has never heard of is scored with `--runner-cmd`, once per read
path, and is compared exactly as a built-in family is — same corpus, same expectations, same
`json.loads(actual) == json.loads(expected)`. Nothing about it is special-cased, and 119/119 is
reachable from outside without editing this harness at all:

```sh
python3 tests/conformance/run.py \
  --runner-cmd 'go run ./cmd/decode_streamed' \
  --runner-cmd 'go run ./cmd/decode_indexed'
```

The command is split with shell quoting rules, and the variant's file path is appended to it — so a
runner sees whatever arguments you wrote, then one path, which is the same invocation the built-in
runners get.

### The capabilities handshake

Before any variant runs, the harness spawns the command once with a single `--capabilities` argument
and no path. The runner answers with one JSON object on stdout and exits 0:

```json
{
  "protocol": 1,
  "name": "go/decode_indexed",
  "family": "go",
  "readPath": "indexed",
  "refusals": true,
  "declines": ["Object", "SHDegree3"]
}
```

| Key        | Required | Meaning                                                                                                 |
| ---------- | -------- | ------------------------------------------------------------------------------------------------------- |
| `protocol` | yes      | the protocol version, `1`. A mismatch is an error naming both numbers                                   |
| `name`     | yes      | `<family>/<read path>`, printed on every line about this runner                                         |
| `family`   | no       | defaults to `name` up to the first `/`                                                                  |
| `readPath` | yes      | `streamed` or `indexed`. An indexed runner is not asked about a variant written without `UseChunkIndex` |
| `refusals` | no       | `true` to be scored on the seven invalid variants. Absent means no, and the seven are skipped           |
| `declines` | no       | variant-name fragments this runner has not implemented; a variant containing one is skipped, not failed |

Two consequences worth stating, because they are what the built-in tables get wrong for an outsider.
The runner opts into the invalid corpus itself, so it does not need its family added to
`REFUSAL_FAMILIES` — a file it does not own. And declining is something the runner says about itself
rather than something the harness records about it, so a partial implementation can be scored
honestly on its first day.

The handshake doubles as the liveness check. A command that cannot be started, hangs, exits non-zero
or prints something other than one JSON object fails the run with a message naming the command and
the reason — not a skip, because a runner named on the command line is one somebody is actively
trying to score, and scoring nothing silently is the green-suite-that-proved-nothing failure this
harness refuses everywhere else.

`--update` is refused with `--runner-cmd`. The expectations are the contract every implementation is
scored against; a runner this repository does not own may be compared to them and may not become
them.

### When a runner misbehaves

Each invocation is bounded by `--timeout` (120 seconds by default), and every way an invocation can
go wrong costs exactly one red variant rather than the run:

```
FAIL go/decode_streamed invalid/BadMagic: runner did not answer within 120s
FAIL go/decode_streamed invalid/BadMagic: runner exited 1
FAIL go/decode_streamed invalid/BadMagic: stdout is not one JSON document (Expecting value: line 1 column 1 (char 0))
  stdout: 'reading /…/BadMagic.4dgs\n{"refused": "magic-mismatch"}'
```

The third is the one every runner author meets: **stdout is the answer and nothing else**, and a
progress line printed beside the JSON leaves the whole document impossible to parse. Diagnostics go
on stderr, which the harness captures and prints when the runner exits non-zero.

## Platforms

The suite runs on GitHub-hosted runners for Python, TypeScript and Rust on Linux, macOS and Windows;
C++, Swift and Dart run it on Linux. Every platform decodes the same 46 valid variants and compares
against the same committed expectations — 97 passing comparisons for a family that reports
provenance but declines the object layer (C++ and Swift), 105 for Rust, TypeScript and Dart, which
also answer the object variants, and 119 for Python, which answers all of them including the refusal
expectations. The single `decode_indexed` variant that declares no chunk index is skipped
everywhere.

That the corpus is bytes is the whole reason this is worth doing on more than one platform: a
decoder that agrees with the expectation on Linux and disagrees on Windows is exactly the bug this
suite exists to find, and it is invisible to a suite that only ever runs in one place.

## Canonical JSON

So that two languages can be diffed without arguing about representation:

- integers are strings, so a 64-bit value survives a JSON parser that uses doubles
- byte strings are arrays of numbers
- floats are rounded to a fixed number of decimals before comparison
- `sigma_t` for a never-fading gaussian is `null`, never a sentinel number
- `"audioSources"` is an array, empty when absent, containing every descriptor, midpoint moving-pose
  reconstruction and payload digest, so absence and multiplicity are visible in every implementation
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
