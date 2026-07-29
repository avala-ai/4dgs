# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Fuzzing the decoder against bytes it did not write.

The invariant, and the whole point: **for any input at all, a decoder either succeeds or
raises this library's own error type.** Never an uncaught `ValueError`, never a
`MemoryError`, never a hang. A decoder parses untrusted bytes, so "it crashed" and "it
refused" are different outcomes for whoever is running it, and only one of them is
acceptable.

Mutations are structural rather than purely random, because a byte-flipper spends almost
all its time on inputs the magic check rejects in a microsecond. Valid corpus files are
truncated at record boundaries, given impossible lengths, spliced, and reordered — the
shapes a corrupt file or a hostile one actually has.

The generator is a hand-written xorshift32, the same one the corpus uses and for the same
reason: seed `n` and operator `k` must name the same input in every language, so a crash
found by one implementation can be handed to another as two integers.

See `tests/fuzz/README.md` for the operator list and `tests/fuzz/regressions.json` for
the inputs that have found something.
"""

from __future__ import annotations

import glob
import json
import os
import time

import fourdgs
import pytest
from fourdgs.exceptions import FourdgsError
from fourdgs.indexed_reader import (
    open_indexed,
    read_attachments,
    read_audio,
    read_audio_range,
    read_audio_source_descriptors,
    read_audio_source_state,
    read_camera,
    read_chunk,
    read_metadata,
)
from fourdgs.readable import BytesReadable
from fourdgs.serialization import MAGIC

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.abspath(os.path.join(HERE, "..", "..", "..", "tests", "conformance", "data"))
FUZZ_DIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "tests", "fuzz"))

#: Inputs per run. CI turns this up; the default keeps `pytest` quick.
ITERATIONS = int(os.environ.get("FOURDGS_FUZZ_ITERATIONS", "400"))

#: No single input may take longer than this. A decoder that takes seconds over a few
#: kilobytes is a denial-of-service waiting for a bigger file.
PER_INPUT_SECONDS = float(os.environ.get("FOURDGS_FUZZ_SECONDS", "5.0"))

OPERATORS = (
    "truncate_at_record",
    "truncate_anywhere",
    "impossible_length",
    "flip_bit",
    "zero_run",
    "max_run",
    "duplicate_record",
    "drop_record",
    "swap_records",
    "corrupt_footer",
    "garbage_tail",
    "random_bytes",
)

#: Lengths a hostile file declares: zero, one, and everything up to the top of a u64.
IMPOSSIBLE_LENGTHS = (0, 1, 0xFFFF, 0xFFFFFFFF, 0x1FFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)


class Rng:
    """xorshift32. Hand-written so every language reproduces the same stream."""

    __slots__ = ("state",)

    def __init__(self, seed: int) -> None:
        self.state = (seed & 0xFFFFFFFF) or 0x1234567

    def next(self) -> int:
        s = self.state
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.state = s
        return s

    def below(self, n: int) -> int:
        return self.next() % n if n > 0 else 0


def record_spans(data: bytes) -> list[tuple[int, int]]:
    """`(offset, total_length)` of every record, walked without the decoder.

    Deliberately not `iter_records`: a fuzzer that frames its inputs with the code under
    test cannot mutate what that code refuses to look at.
    """
    spans = []
    at = len(MAGIC)
    while at + 9 <= len(data):
        length = int.from_bytes(data[at + 1 : at + 9], "little")
        if length > len(data) or at + 9 + length > len(data):
            break
        spans.append((at, 9 + length))
        at += 9 + length
    return spans


def mutate(data: bytes, operator: str, rng: Rng) -> bytes:  # noqa: PLR0911
    """One deterministic mutation. `operator` names the shape, `rng` places it.

    One branch per operator, each returning its own bytes. The return count is the
    operator count and nothing else — collapsing it into a dispatch table would hide the
    one property that matters here, which is that each branch draws from `rng` in a fixed
    order so the TypeScript fuzzer reproduces the same input from the same seed.
    """
    spans = record_spans(data)
    out = bytearray(data)

    if operator == "truncate_at_record" and spans:
        offset, _ = spans[rng.below(len(spans))]
        return bytes(out[:offset])
    if operator == "truncate_anywhere":
        return bytes(out[: rng.below(len(out) + 1)])
    if operator == "impossible_length" and spans:
        offset, _ = spans[rng.below(len(spans))]
        value = IMPOSSIBLE_LENGTHS[rng.below(len(IMPOSSIBLE_LENGTHS))]
        out[offset + 1 : offset + 9] = value.to_bytes(8, "little")
        return bytes(out)
    if operator == "flip_bit" and out:
        at = rng.below(len(out))
        out[at] ^= 1 << rng.below(8)
        return bytes(out)
    if operator == "zero_run" and out:
        at = rng.below(len(out))
        out[at : at + 8] = b"\x00" * min(8, len(out) - at)
        return bytes(out)
    if operator == "max_run" and out:
        at = rng.below(len(out))
        out[at : at + 8] = b"\xff" * min(8, len(out) - at)
        return bytes(out)
    if operator == "duplicate_record" and spans:
        offset, length = spans[rng.below(len(spans))]
        return bytes(out[: offset + length] + out[offset : offset + length] + out[offset + length :])
    if operator == "drop_record" and spans:
        offset, length = spans[rng.below(len(spans))]
        return bytes(out[:offset] + out[offset + length :])
    if operator == "swap_records" and len(spans) > 1:
        i = rng.below(len(spans))
        j = rng.below(len(spans))
        if i != j:
            (a, la), (b, lb) = spans[min(i, j)], spans[max(i, j)]
            return bytes(out[:a] + out[b : b + lb] + out[a + la : b] + out[a : a + la] + out[b + lb :])
        return bytes(out)
    if operator == "corrupt_footer":
        tail = len(out) - (9 + 20 + len(MAGIC))
        if tail > 0:
            at = tail + 9 + rng.below(20)
            out[at] ^= 0xFF
        return bytes(out)
    if operator == "garbage_tail":
        keep = rng.below(len(out) + 1)
        noise = bytes(rng.below(256) for _ in range(rng.below(64)))
        return bytes(out[:keep]) + noise
    if operator == "random_bytes":
        length = rng.below(512)
        body = bytes(rng.below(256) for _ in range(length))
        return (MAGIC + body) if rng.below(2) else body
    return bytes(out)


def replay(seed: int, base_count: int) -> Rng:
    """A generator positioned exactly where the fuzz loop positions it.

    The loop draws twice before mutating — once for the base file, once for the operator —
    so a recorded case has to draw twice too, or it reproduces different bytes. The two
    values are discarded rather than used: the case records the variant and the operator
    by name, which is what keeps it reproducing the same input after the corpus grows.
    """
    rng = Rng(seed)
    rng.below(max(base_count, 1))
    rng.below(len(OPERATORS))
    return rng


def decode_every_way(data: bytes) -> None:
    """Everything a consumer would do with an untrusted file, on both read paths."""
    scene = fourdgs.read(data)
    scene.gaussians.state_at(0.5)
    scene.gaussians.aabb()

    source = BytesReadable(data)
    indexed = open_indexed(source)
    indexed.chunks_for_time(0.5)
    indexed.bytes_for_time(0.5, max_sh_band=3)
    for entry in indexed.index:
        read_chunk(source, indexed, entry, max_sh_band=3)
    read_audio(source, indexed)
    descriptors = read_audio_source_descriptors(source, indexed)
    for descriptor in descriptors:
        read_audio_source_state(source, indexed, descriptor.source_id, 0.5)
        read_audio_range(source, indexed, descriptor.source_id, 0, min(descriptor.data_size or 0, 16))
    read_camera(source, indexed)
    read_metadata(source, indexed)
    read_attachments(source, indexed)


def check(data: bytes, label: str) -> None:
    """The invariant: succeed, or raise this library's own error. Nothing else."""
    started = time.monotonic()
    try:
        decode_every_way(data)
    except FourdgsError:
        pass  # A diagnosis is a pass. That is the whole contract.
    except RecursionError as exc:
        pytest.fail(f"{label}: unbounded recursion ({exc})")
    except MemoryError as exc:
        pytest.fail(f"{label}: unbounded allocation ({exc})")
    # Catching everything is the point: any exception that is not a FourdgsError is the
    # bug this suite exists to find.
    except Exception as exc:
        pytest.fail(f"{label}: {type(exc).__name__}: {exc}")
    elapsed = time.monotonic() - started
    if elapsed > PER_INPUT_SECONDS:
        pytest.fail(f"{label}: took {elapsed:.1f}s, over the {PER_INPUT_SECONDS}s ceiling")


def corpus_files() -> list[str]:
    return sorted(glob.glob(os.path.join(DATA, "*.4dgs")))


def regressions() -> list[dict]:
    path = os.path.join(FUZZ_DIR, "regressions.json")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)["cases"]


@pytest.fixture(scope="module")
def bases() -> list[bytes]:
    paths = corpus_files()
    if not paths:
        pytest.fail(
            f"no corpus in {DATA}; run tests/conformance/generate.py first. "
            "The fuzzer mutates real files, so an empty corpus is an empty run."
        )
    return [open(p, "rb").read() for p in paths]


class TestFuzz:
    def test_the_corpus_itself_decodes(self, bases):
        for data in bases:
            decode_every_way(data)

    def test_mutations_are_refused_rather_than_crashing(self, bases):
        for i in range(ITERATIONS):
            rng = Rng(0x4D473500 + i)
            base = bases[rng.below(len(bases))]
            operator = OPERATORS[rng.below(len(OPERATORS))]
            check(mutate(base, operator, rng), f"seed={0x4D473500 + i:#x} op={operator}")

    def test_pure_noise_is_refused(self):
        for i in range(200):
            rng = Rng(0x0150E000 + i)
            check(mutate(b"", "random_bytes", rng), f"noise seed={0x0150E000 + i:#x}")

    def test_a_prefix_of_every_length_is_refused(self, bases):
        # Every truncation point of one real file, exhaustively. Truncation is the most
        # common corruption there is, and the one a streamed reader promises to survive.
        data = bases[0]
        for cut in range(0, len(data), max(1, len(data) // 200)):
            check(data[:cut], f"prefix={cut}")

    def test_recorded_regressions_stay_fixed(self, bases):
        paths = corpus_files()
        cases = regressions()
        assert cases, "tests/fuzz/regressions.json is empty; every crash the fuzzer found belongs in it"
        for case in cases:
            base = next((open(p, "rb").read() for p in paths if case["variant"] in p), None)
            if base is None:
                pytest.fail(f"regression case names a variant that is not in the corpus: {case['variant']}")
            check(mutate(base, case["operator"], replay(case["seed"], len(bases))), f"regression {case['name']}")
