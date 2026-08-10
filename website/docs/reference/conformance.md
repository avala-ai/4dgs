# Conformance suite

The contract between implementations. An SDK claims a feature by passing this suite for it, and the
[feature matrix](./index.md) records only what the suite proves.

The suite itself lives in
[`tests/conformance/`](https://github.com/avala-ai/4dgs/tree/main/tests/conformance), and its
[README](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/README.md) is the authority on
how to run it and how to add to it. The first sections here are the short orientation; from
[The runner protocol](#the-runner-protocol) onwards this page states the contract a runner has to
satisfy, in enough detail to write one in a language this repository has never heard of.

## Scenarios, flags, variants

`generator/scenarios.py` declares scenarios — scene shapes — and feature flags. Their legal
combinations are **variants**, and for each variant the generator writes two things:

- `data/<variant>.4dgs`, a real file, **not committed**
- `data/<variant>.json`, exactly what a correct decoder must produce from it, committed

A variant's name is its scenario followed by the flags it carries, hyphen-separated —
`MixedLifetimes-Quantized-SHDegree2-UseChunkIndex-UseCrc`. The name is load-bearing in one place:
the harness matches fragments of it to decide which runners are asked to answer the variant at all.
Most variants sit at the top of `data/`; three families live in subdirectories — `data/keyframe/`,
`data/object/` and `data/invalid/` — and a variant there is named with its directory as a prefix.
Today that is 46 valid variants at the top level, 4 keyframe-delta, 3 object-layer and 7 invalid.

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

## Download the corpus

Generating the corpus is right for this repository and wrong for everybody else: it makes a Python
generator and a clone of six SDKs the price of testing a decoder written somewhere else. So the
generated corpus is also published, as one archive attached to a GitHub Release.

```sh
curl -LO https://github.com/avala-ai/4dgs/releases/download/releases%2Fcorpus%2Fv0.1.0/4dgs-conformance-corpus-0.1.0.tar.gz
tar -xzf 4dgs-conformance-corpus-0.1.0.tar.gz
```

That URL is stable in the sense that matters for a checksummed artifact: the bytes behind it never
change. There is deliberately no `latest` link — a conformance score is only meaningful beside the
corpus version it was taken against, so citing a version is part of citing a result. To find the
newest one:

```sh
gh release list --repo avala-ai/4dgs | grep releases/corpus/
```

The corpus is versioned on its own tag, `releases/corpus/vX.Y.Z`, and released independently of
every SDK — it changes when variants are added, which has nothing to do with any package's version.
Its changelog is
[`tests/conformance/CHANGELOG.md`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/CHANGELOG.md),
and it says what a major, minor and patch bump each mean for a score taken against it.

### What is inside

```
4dgs-conformance-corpus-0.1.0/
  README.md          the same orientation as this section, offline
  LICENSE  NOTICE    Apache-2.0
  MANIFEST.json      machine-readable index of every variant
  corpus/            byte-for-byte `tests/conformance/data` in the repository
    CHECKSUMS.txt    SHA-256 per generated file, `sha256sum -c` compatible
    <variant>.4dgs   the file
    <variant>.json   exactly what a correct decoder must produce from it
    keyframe/        the keyframe-delta temporal model
    object/          the object layer: an Object Table and SE(3) tracks
    invalid/         files a conforming reader must refuse
```

`corpus/` being byte-for-byte the generated directory is the point rather than a coincidence: an
unpacked corpus is a drop-in replacement for a generated one, so nothing that already reads
`tests/conformance/data` needs to learn a second layout.

`MANIFEST.json` is what a harness that is not `run.py` reads. Per variant it carries both paths,
both SHA-256s, the byte length, the temporal model, whether a runner reading through the chunk index
may be asked it at all, and — for an invalid variant — the refusal identifier a conforming reader
must produce. Those last two are the rules the harness applies when it decides what to skip, written
down as data so an outside harness does not have to reimplement them by reading Python.

### Verify it

```sh
cd 4dgs-conformance-corpus-0.1.0/corpus && sha256sum -c CHECKSUMS.txt
```

`CHECKSUMS.txt` is not written for the download. It is the manifest committed at
[`tests/conformance/data/CHECKSUMS.txt`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/data/CHECKSUMS.txt),
packed verbatim, and its format was already `sha256sum`'s. So the digests can be read out of git at
the tag and compared without trusting the archive at all, and a corpus that verifies here is the
same corpus the `--verify` gate asserts on every pull request.

The archive itself has a `.sha256` beside it on the release page, and it is reproducible: every
member is written with a fixed mtime, uid, gid and mode in sorted order, and gzipped with no
timestamp, so rebuilding the same corpus at the same version produces the same digest rather than
one you have to take on faith.

`MANIFEST.json` carries the same per-variant digests together with the metadata a harness needs.

### Point a runner at an unpacked corpus

A runner takes one `.4dgs` path and prints one JSON document on stdout; scoring it is diffing that
document against the variant's `.json`, parsed rather than compared as text. The full contract —
invocation, stdout and stderr, exit codes, what declining and refusing mean, and the canonical JSON
rules — is the runner section further down this page, and it is written to be implementable without
reading any source here.

The harness in this repository can be driven against a download rather than a generated corpus,
because the two directories are the same shape:

```sh
mv tests/conformance/data tests/conformance/data.generated
ln -s /path/to/4dgs-conformance-corpus-0.1.0/corpus tests/conformance/data
python3 tests/conformance/run.py --runner python
```

The release job does exactly this before it attaches anything: it unpacks its own tarball and scores
the reference implementation against the unpacked copy. An archive whose checksums verify proves
only that the bytes survived the tar, which is not the same as proving they are still a corpus.

### Licence

**Apache-2.0, the same as the repository, and there is nothing else to clear.** This is worth
stating where somebody is deciding whether they may use the download, because for most conformance
corpora the answer is complicated and here it is not.

The corpus is redistributable by construction rather than by permission. Every scene is synthetic,
generated from a fixed seed by `generator/scenarios.py`; every audio payload is a generated sine
sweep; there is no captured data of any kind anywhere in it — no scan, no recording, no photograph,
no third-party asset, and so no third party with a claim on it. It may be vendored into another
project's test suite, mirrored, or baked into a product's CI image, and none of that needs asking.

## The runner protocol

A runner is a command-line program that reads one `.4dgs` file and prints one JSON document. That is
the entire interface between an implementation and the harness: no library binding, no in-process
API, no shared build system, nothing that assumes the implementation was written in a language
already in this repository.

What follows is that interface written as a contract, rather than as a description of how the six
runners here happen to be built. Everything in it is what
[`run.py`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/run.py) actually does. Where
the harness is stricter or looser than it means to be, that is said plainly instead of smoothed
over, because a runner author will meet the behaviour and not the intention.

One limit belongs at the top, because it decides what is worth building today: `run.py` drives the
runners named in its own `RUNNERS` table and no others. A program that satisfies every rule below is
still not reachable from an unmodified harness — the flag that would point it at an out-of-tree
runner is [issue #137](https://github.com/avala-ai/4dgs/issues/137), and this is the contract that
flag will point at.

### Invocation

The harness spawns the runner as a child process, once per variant, and appends exactly one argument
to its command line: the path of the `.4dgs` file to read. Nothing else is passed.

The path is absolute, so the runner's working directory is irrelevant — deliberately, because the
harness does not set one, and a runner that resolved a relative path would work only when the suite
was started from the repository root. For a variant from a subdirectory the path carries that
directory, joined with the platform's separator, so it ends `…/data/invalid/BadMagic.4dgs` on Linux
and with backslashes on Windows.

The variant's **name** is not an argument. It reaches the runner only as part of the file's own
name, and a runner that read it there would be answering from the filename rather than from the
bytes, which is the one thing this suite exists to prevent. Everything a runner needs in order to
decide — which temporal model to compose, whether the file carries an index, whether to refuse it —
is inside the file.

There is no stdin. The harness neither writes to it nor closes it, so the runner inherits whatever
the harness inherited; a runner that reads stdin will block or read something unrelated to its job.
No environment variable carries part of the request and no configuration file is consulted.

Each invocation is a fresh process handling one file. Nothing may be carried between variants, and
nothing needs to be — the corpus is sixty files, so a runner is allowed to be slow to start and is
not allowed to be stateful.

### What goes on stdout, and what may go on stderr

**Stdout is the answer and nothing else.** The harness captures it, strips surrounding whitespace
and parses the result as a single JSON document. A progress line, a banner, a warning or a second
document all make that text unparseable.

Unparseable stdout is worse than a failing variant, and this is the first place the harness is
rougher than its intent: `run.py` hands whatever a zero-exit runner printed straight to `json.loads`
without guarding it, so the exception escapes and the whole run stops with a traceback rather than
one variant going red. A stray debug print does not cost a runner author one variant; it costs them
the run.

**Stderr is free.** The harness captures it, parses none of it, and prints its first 2000 characters
only when the runner exits non-zero. So stderr is where diagnostics belong — with the caveat that on
a passing run nobody will ever see them.

### Exit codes: refused is not crashed

**Zero means the runner produced an answer. Non-zero means it did not.**

The narrowness is the whole point, because _refusing a file is an answer_. Handed
`invalid/BadMagic.4dgs`, a conforming decoder prints `{"refused": "magic-mismatch"}` on stdout and
exits **0**. It did what the specification asks of it. It has a result, and the result is a refusal.

A runner that exits non-zero for a file it refused, and also for a file that crashed it, has
collapsed the two into one observation — and from outside the process a correct decoder is then
indistinguishable from a broken one. Telling those apart is the entire reason the invalid corpus
exists, and it cannot be done if the runner throws the distinction away in its exit status.

The harness tells no non-zero code from another: `if result.returncode != 0` is the whole test, so
1, 2 and a segfault's 139 are the same failure with a different number printed beside it. The
runners here nonetheless use 2 for a usage error — the wrong number of arguments — and 1 for a
decode that genuinely failed. Nothing checks that, and an outside runner that follows the convention
buys only a log that reads more clearly.

Non-zero must also not be used to mean "I do not support this variant". Declining happens before the
process starts; see [below](#declining-a-variant).

### The two read paths

Each implementation ships **two** runners, and the harness runs both over the same corpus, diffing
both against the same committed expectation:

| Runner            | Reads                                    | Produces                                     |
| ----------------- | ---------------------------------------- | -------------------------------------------- |
| `decode_streamed` | the file front to back, no seeking       | the canonical summary of everything it found |
| `decode_indexed`  | the index, then only the chunks it needs | the same summary, reached a different way    |

They are driven separately rather than left to whichever path a core would pick, because **they have
to be able to disagree**. A streamed reader arrives at the Header front to back; an indexed one
arrives through the Footer and the chunk index. A check placed on one route is invisible from the
other, and a suite that ran whichever path an implementation preferred would run one of them twice
and count it as two passes.

A file written without a chunk index cannot be read the indexed way at all, so the indexed runner is
not asked about those variants: the harness skips any variant whose name lacks `UseChunkIndex` for a
runner whose name ends in `decode_indexed`. Exactly one valid variant, `TenWindows-UseCrc`, is in
that position, and it is skipped for the indexed path in every language.

The invalid corpus is the exception, deliberately. It is cut from a base file that carries an index
precisely so that both paths can be asked to refuse all seven, and both are. A refusal check written
into only one read path refuses half the files it should, and there is no other way to notice.

Encoding is proved by a different program — `tests/conformance/encode_roundtrip.py`, which drives an
`<encoder> <in.4dgs> <out.4dgs>` CLI and diffs its output against the Rust reference encoder through
the Python decoder. It is not part of this protocol, and as far as `run.py` is concerned a
decoder-only implementation is a complete one.

### Declining a variant

**A variant a runner declines is skipped, not failed.** This is what makes an in-progress SDK
testable at all. An implementation that decodes gaussians but not the object layer can run the suite
today, score what it actually supports, and have that number mean something. Were declining a
failure, a partial implementation would be indistinguishable from a broken one, and the only route
to a green suite would be to implement everything before landing anything — which is how
implementations get abandoned rather than finished.

Here is where an outside author will trip, and it is worth stating bluntly: **the decision is the
harness's, not the runner's.** This page used to say that a runner declares a
`supportsVariant(variant)` predicate, and three runners in this repository do define one —
`supports_variant` in both Python runners, an exported `supportsVariant` in the TypeScript indexed
runner. `run.py` calls none of them. The predicate that actually decides is `supports()` in the
harness, and it consults three things:

1. `FAMILY_DECLINES`, a table mapping a language family to name fragments it has not implemented; a
   variant containing one of that family's fragments is skipped. The table is empty today — every
   family decodes provenance and the object layer — but it is the mechanism a partial SDK uses, and
   `Object` was the fragment in it until the last family that needed it stopped. (`OBJECT_TOKENS`
   still sits beside the table, now unused, as the fossil of that.)
2. `REFUSAL_FAMILIES`, the set of families whose runners answer refusal expectations. A family
   absent from it skips the whole invalid corpus. See [Refusing a file](#refusing-a-file).
3. The `decode_indexed` rule above.

So "declining" today is a fact the harness records about a family, not something a runner declares
about itself, and an out-of-tree runner has no way to express it at all. Reconciling the two — the
predicate the runners define and the tables the harness reads — is part of #137. Until that happens,
the `supportsVariant` functions in this repository are a statement of intent rather than working
code, and this section is what they intend.

One thing declining is _not_: **stepping a record over by its length is not declining it.** An SDK
that skips an unknown record correctly finishes the file, decodes every gaussian, and produces a
summary missing the key that record contributes — and a diff cannot tell that apart from a decoder
that read the record and got it wrong. Forward compatibility is the right behaviour for a reader in
the field and the wrong answer for a runner. Decline the variant, take the skip, and let the feature
matrix say `No`.

### Refusing a file

A corpus of valid files proves only that a decoder accepts what it should. Much of the specification
is rules whose whole content is a refusal — an out-of-range window index, an unimplemented codec, a
temporal model the reader does not know — and a decoder that ignores all of them passes every valid
variant.

`generator/invalid.py` declares the other half: mutations of one valid base file, each breaking
exactly one rule, each paired with the **refusal identifier** a conforming reader must produce. The
mutations are length-preserving wherever they can be, so nothing after the patch shifts and the file
is wrong in exactly one way; a mutation that moved offsets would produce a file broken twice, and a
reader could pass by noticing the wrong fault.

The expectation — and so the document the runner prints — is a JSON object with one key:

```json
{ "refused": "window-index-out-of-range" }
```

and the runner exits 0, because a refusal is a result rather than a crash.

The identifier matters more than it looks. "Both decoders raised an error" is not agreement: one of
them may have refused for the wrong reason, which is precisely the failure a negative test exists to
catch. The identifier names the rule, and it is the same string in every language. There are six,
declared as constants in `mod refusal` in
[`rust/fourdgs/src/error.rs`](https://github.com/avala-ai/4dgs/blob/main/rust/fourdgs/src/error.rs)
and gathered as `CODES` in `invalid.py`. That set is closed: a runner may produce no identifier
outside it, and a new refusal is added there rather than invented in one language.

| Invalid variant             | Identifier                    | The rule it breaks                                                     | Where    |
| --------------------------- | ----------------------------- | ---------------------------------------------------------------------- | -------- |
| `BadMagic`                  | `magic-mismatch`              | the file does not begin with the 4dgs magic                            | §4.1     |
| `FutureMajorVersion`        | `unsupported-major-version`   | the magic is ours; the major version is not one this reader implements | §4.1     |
| `UnknownTemporalModel`      | `unknown-temporal-model`      | the Header names a temporal model this build does not implement        | registry |
| `EmptyTemporalModel`        | `unknown-temporal-model`      | the Header's temporal model is the empty string                        | registry |
| `UnknownQuantizationScheme` | `unknown-quantization-scheme` | the Quantization record names a scheme this build does not implement   | registry |
| `UnknownStreamCodec`        | `unknown-stream-codec`        | an attribute stream declares a codec this build does not implement     | §5.5     |
| `WindowIndexOutOfRange`     | `window-index-out-of-range`   | a gaussian's `window_index` names a row the Window Table does not have | §5.4     |

Seven variants, six identifiers, and the pair that shares one is not redundant. An unknown name is
what a _future_ writer produces; the empty string is what a struct left at its zero value produces,
which is the shape a **bug** writes. Two SDKs in this repository disagreed about exactly that — one
defaulted the field to `gaussian-birth`, the other left it blank — and nothing inside either
language could see it. The two files break the same rule from opposite directions, and a reader must
refuse both under the same name. A useful side effect: the identifier cannot be derived from the
variant name, which is as it should be, since it names the rule and not the file.

An exception that carries no identifier should print an empty one. `{"refused": ""}` matches no
expectation and fails with a readable diff, and that is the intended outcome rather than a fallback:
a refusal a library cannot name is a refusal the suite cannot check, and it should look like a gap
rather than a pass.

Whether any of this runs at all is gated at family granularity by `REFUSAL_FAMILIES`
([`run.py:114`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/run.py#L114)), which
today holds `python` and `rust`. A family absent from it skips all seven invalid variants exactly as
it would skip any variant it declines — 105 checks rather than 119 — and the feature matrix is where
that shows up publicly. The consequence for an outside implementation is sharp: a runner that
answers every refusal perfectly proves nothing until its family is named in that set, which today
means editing the harness. It is the hardest edge an out-of-tree runner meets, and the clearest
thing #137 has to solve.

The two **indexed** refusal-answering runners inspect the version prefix before Header dispatch. If
it is the exact version-1 magic, they read through the Header's length-prefixed `profile` and
`library` fields to choose the gaussian-birth or keyframe-delta indexed decoder. If the prefix
differs — including `BadMagic` and `FutureMajorVersion` — they bypass that Header read and route to
the gaussian-birth indexed opener. The selected opener owns the magic rule, so it produces the
refusal without asking dispatch code to parse an unrecognized layout.

For a recognized version-1 file, the Header pre-read is still dispatch rather than the validation
this suite credits. Mutation pins that distinction: deleting `check_magic` from either indexed
opener turns exactly the two prefix variants red; deleting its temporal-model or quantization-scheme
check turns their variants red; and deleting the shared window-index or stream-codec check turns the
corresponding variant red on both paths. The streamed runners still validate magic while selecting
the streamed decoder; this claim is about the indexed path.

Every rule in this corpus already existed in version 1 — nothing here is new specification, so the
contract is proved against rules that predate it. It found three real faults on its first run:
neither an unknown `temporal_model` nor an unknown quantization `scheme` was refused at all, both
decoding silently as the known value, and a corrupt first byte was reported as an unsupported
version 1.

Truncation is deliberately not here. A cut file is recoverable rather than refusable, so no
expectation can express it. The runners in this repository make their own truncated copy of each
valid variant, assert what survives, and exit non-zero if it does not — a check the harness cannot
see except as a failure. An outside runner is welcome to do the same and is not required to.

### The canonical JSON contract

The summary a runner prints is defined by
[`tests/conformance/canonical.py`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/canonical.py).
It is written in Python and it is the normative shape: `summarize()` names every key and the type
each carries, and the rounding, the string-integers, the null-for-non-finite rule and the content
order all live there. Read it as the schema. A prose copy of it on this page would go stale against
the code, which is the one thing a normative shape may not do.

**What is compared.** The harness parses the runner's stdout and the committed expectation, and
compares the parsed values:

```python
if json.loads(actual) == json.loads(expected):
```

That is [`run.py:207`](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/run.py#L207),
and it is the whole comparison: recursive value equality over two parsed documents, with no
tolerance and no text matching. The unified diff printed on a failure is generated afterwards, from
the text, purely so that a human can read the disagreement; it decides nothing.

Several rules follow from that one line, and they are what an implementer actually needs.

**Spelling is free.** Python writes `50.0` where JavaScript writes `50`; `1e-06` and `0.000001` are
the same number; `-0.0` and `0` compare equal. None of it needs normalizing in a runner. Key order
and indentation are free for the same reason — the expectations are pretty-printed with sorted keys
because a human reads the diff, not because the comparison cares.

**Type is not spelling.** `"50"` and `50` are not equal, and this is the rule that catches people.
The summary emits 64-bit integers **as strings** — `gaussianCount`, `byteLength`, every count and
every offset — so that a JSON parser backed by doubles cannot silently round one. A runner that
emits those as JSON numbers **fails**, with digits that match exactly. It is not a formatting
difference and no amount of re-reading the diff will make it into one: the failing key is a number
where the expectation has a string.

**Rounding is the runner's job.** There is no tolerance anywhere in the comparison, so `0.3` and
`0.30000000000000004` are simply different numbers here. Every float is rounded before it is
printed, by `num()`: take the value as a double, map any non-finite value to `null`, otherwise round
to `FLOAT_DECIMALS` — 6 — decimal places. Two details of it will be met by anyone reimplementing it.
The conversion to a double happens first and deliberately, because a numpy scalar is not a Python
float and an `isinstance` check would let an infinity slip through into JSON, which has no way to
spell it. And Python's `round` breaks an exact tie towards the nearest even digit, where many
languages round half away from zero — so two correct-looking implementations can differ in the sixth
decimal of a value that lands precisely on the boundary. Binary floats make such a tie rare rather
than impossible, and the corpus does not currently contain one, which is why this is a note rather
than a failure. It is underspecified, and it is the sort of thing that should be pinned down before
an outside runner meets it.

**Non-finite values are never spelled at all.** JSON has no `NaN` and no `Infinity`. `num()` maps
both to `null`, and `canonical()` passes `allow_nan=False` so that an attempt to emit one is an
error rather than a surprise in somebody else's parser. A never-fading gaussian's `sigmaT` is `null`
for exactly this reason, and `null` there means "never fades" rather than "missing".

**Nothing may depend on decoded order.** An encoder may reorder gaussians freely and a reader must
not rely on their order, so a summary that did would be asking two correct decoders to disagree.
Everything per-gaussian — the sample, the aggregates, the spherical-harmonic digest — is taken in
the content order `_stable_order` defines: sort by the gaussian's whole decoded state, rounded
exactly as the summary rounds it, with its spherical-harmonic coefficients and object id last. Two
gaussians that tie on all of that are identical in every value the summary emits, so their relative
order cannot change the output. A runner therefore materializes every gaussian and sorts them, which
is precisely what the SDK underneath it must never do. The runner is not the SDK.

**Bulk payloads become digests.** Spherical-harmonic coefficients, attachment contents and audio
payloads are summarized as a CRC-32 over the bytes in content order, rendered as a decimal string.
Degree 2 over 512 gaussians is 12 KiB of coefficients that would swamp the expectation without
proving anything the checksum does not — and the checksum does prove the bytes were read, which a
byte count alone would not.

**Absence has two shapes, and the difference is deliberate.** `audioSources` is always present, an
empty array when the file carries none, because audio presence is a property of _every_ file — the
Header declares it either way — so both paths have to be visible in every variant or one of them is
never checked. `provenance`, and the object and state sections, are **omitted entirely** when the
file carries none, because there is no such flag and no such duty: a file without them is a file the
record family does not apply to. Had provenance followed the `audioSources` convention, every
pre-existing expectation would have gained `"provenance": null` and the SDKs that correctly skip
those records by length would have gone red on all of them — the suite would have reported the
format's forward-compatibility mechanism working as a wall of failures.

**Records that are not gaussians are summarized too** — the camera, the metadata, the attachments,
the statistics, the summary offsets, whether the Footer's CRC verified, and the Header's own
`profile` and `library`. A record that changes nothing in the output is a record an implementation
could ignore entirely and still pass, which is how a feature matrix ends up claiming things the
suite never checked. The same holds field by field: `profile` and `library` were readable in every
SDK and asserted by none, so a binding that returned an empty string for both produced a summary
identical to a correct one, and passed. That is the worst shape a gap can take — not a failure, but
a success that proves less than it appears to.

**The summary's shape depends on the file's temporal model.** A `keyframe-delta` variant is not
summarized as a population of gaussians at all. A runner reads the Header's `temporal_model` before
choosing a path, and for `keyframe-delta` emits the states summary instead — per-chunk kind, depth,
delta mode and live/birth/death/update counts, plus reconstructed states at probe times — because
the reason that model exists is cheap reconstruction at an instant, and that is what two
implementations should be diffed on. Its shape lives in `states_json`, in `keyframe_delta_file` in
the Python and Rust cores rather than in `canonical.py`; the `data/keyframe/` expectations are
those, and every other expectation is `summarize()`'s.

Finally, an artifact worth naming so that nobody chases it: the committed `.json` files were written
by the Python implementation, so they carry Python's spelling of every float. That is a fact about
who wrote them, not a requirement on anyone reading them.

## Running it

```sh
python3 tests/conformance/generate.py
python3 tests/conformance/run.py --runner python
```

Swap `--runner` for the language you are working on. A language with a build step needs its entry
point built first; the harness decides whether a family was built by testing the **last element of
its command line** for existence, so `["node", ".../decode_streamed.js"]` is judged by the script
and a compiled family by its binary — including the `.exe` suffix Windows puts on it. A family whose
entry point is missing is skipped with a note rather than reported as a wall of failures, and a
family asked for by name that never ran is an error, because a green suite that proved nothing is
worse than a red one.

`--update` rewrites the expectations from the current runner output. Use it when you have decided
that a change to the format or the summary is correct — never to make a red suite green, which is
the one use that turns the expectations from a contract into a record of the last thing anyone ran.

## Known gaps

Gaps are recorded rather than left implicit, because a gap nobody wrote down is indistinguishable
from coverage. Degree-3 spherical harmonics used to be the one worth naming here; the corpus now
carries two degree-3 variants and every SDK decodes them, so the current entry is a smaller one —
the Header's `library` is the same string in every variant, which catches a runner that drops the
field but not one that hardcodes it. The
[conformance README](https://github.com/avala-ai/4dgs/blob/main/tests/conformance/README.md) keeps
that list current.
