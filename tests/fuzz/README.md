# Fuzzing

A decoder reads bytes somebody else wrote. The invariant every implementation here holds:

> **For any input at all, a decoder either succeeds or raises the format's own error type.**

Never an uncaught error from a codec library, a transport or a maths function; never unbounded
allocation; never a hang. "It crashed" and "it refused" are different outcomes for whoever is
running it, and only one of them is acceptable. This is the executable half of
[SECURITY.md](../../SECURITY.md)'s threat model.

This directory is the **Python and TypeScript** fuzzers: they mutate the shared corpus and share a
seed scheme, which is what the rest of this file describes. Rust fuzzes in
`rust/fourdgs/tests/fuzz.rs` against seeds it encodes itself, so `cargo test` needs nothing
generated first, and covers the C ABI as well as the two read paths. Same invariant, different
inputs — deliberately, because two fuzzers that explore the same inputs find the same bugs.

## What it does

Mutations are structural rather than purely random, because a byte-flipper spends almost all of its
time on inputs the magic check rejects in a microsecond. The fuzzer starts from real corpus files
and breaks them the way a corrupt or hostile file is actually broken:

| Operator             | What it does                                                        |
| -------------------- | ------------------------------------------------------------------- |
| `truncate_at_record` | Cut at a record boundary — the shape a half-written file has        |
| `truncate_anywhere`  | Cut mid-record, mid-field, mid-payload                              |
| `impossible_length`  | Set a record's length to 0, 1, 2^32, 2^53, 2^63 or 2^64−1           |
| `flip_bit`           | One bit, anywhere                                                   |
| `zero_run`           | Eight zero bytes, anywhere                                          |
| `max_run`            | Eight `0xFF` bytes, anywhere                                        |
| `duplicate_record`   | A record appears twice                                              |
| `drop_record`        | A record the file's own offsets still refer to is gone              |
| `swap_records`       | Two records change places, so nothing is where the index says       |
| `corrupt_footer`     | The one record every seeking reader trusts before it reads anything |
| `garbage_tail`       | A valid prefix followed by noise                                    |
| `random_bytes`       | Noise, with and without a valid magic in front                      |

Each language also decodes every prefix of a real file, exhaustively: truncation is the most common
corruption there is, and the one a streamed reader promises to survive.

## Both languages, the same bytes

The generator is a hand-written xorshift32 and every operator consumes it in a fixed order, so
**seed `n` with operator `k` names the same input in both languages** — verified by hashing. A crash
found by one implementation is handed to the other as two integers, and a fix can be shown to hold
on the same input rather than on a similar one.

Keep `python/fourdgs/tests/test_fuzz.py` and `typescript/conformance/src/fuzz.ts` in step. If you
add an operator, add it to both, at the end of the list — inserting one in the middle renumbers
every recorded case.

To re-check the claim after touching either fuzzer, hash the same seed range from both and compare:
draw a base and an operator from `Rng(0x4d473500 + i)` exactly as the loop does, mutate, and SHA-256
the result for `i` in `0..300`. The two lists must be identical. They are checked this way rather
than in CI because the two fuzzers run in different jobs and a shared assertion would need a third;
if the lists ever diverge, the recorded regression seeds stop reproducing in one language and that
is the symptom to expect.

## Running it

```bash
python3 tests/conformance/generate.py                      # the fuzzer mutates real files
FOURDGS_FUZZ_ITERATIONS=20000 pytest python/fourdgs/tests/test_fuzz.py
FOURDGS_FUZZ_ITERATIONS=8000 node --test typescript/conformance/dist/fuzz.test.js
```

Both default to a few hundred inputs so an ordinary test run stays quick; CI turns them up. A single
input that takes longer than the ceiling is a **failure**, not a slow test: a decoder that spends
seconds on a few kilobytes is a denial of service waiting for a bigger file.

## Regressions

`regressions.json` records every input that has found something. They run on every fuzz run, forever
— the same rule the conformance corpus follows, for the same reason. A case is a seed plus the
variant and operator that seed selected; recording those two explicitly is what keeps a case
reproducing the same bytes after the corpus grows.

**When the fuzzer finds a crash: fix it, then add the seed here.** A fix without a recorded case is
a fix that comes back.

## What the first pass found

Ten crash classes across the two implementations, nine of them shared or mirrored:

- a corrupt payload escaping as the codec library's own exception (`zlib.error`, `ZstdError`, and a
  `TypeError` out of `DecompressionStream`);
- a string field that is not UTF-8 escaping as `UnicodeDecodeError`;
- an index entry, a band range or an audio range pointing outside the file, escaping as whatever the
  transport raised;
- a footer whose summary starts past the footer — the bug that made `validate` crash on exactly the
  file it exists to diagnose;
- a spherical-harmonic band whose element count disagreed with its chunk;
- an attribute stream with no columns, a rotation index outside 0..3, and a header cutoff of zero
  reaching a logarithm;
- and one that was not an exception at all: **a constant-mode stream declaring 2^30 elements**,
  which expands a one-byte payload into gigabytes. One flipped bit, 1.4 seconds, and the existing
  cap never saw it because it bounds the payload rather than what the payload becomes.
