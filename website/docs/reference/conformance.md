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
