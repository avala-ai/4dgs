# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""What `generate.py --verify` catches, and what the canonical form guarantees.

`--verify` is the corpus's only gate, and the two things it asserts here are both things a
green run used to be compatible with: an expectation that no longer matches a fresh decode,
and an expectation no variant produces at all. Both were true of the corpus while the gate
printed `verified 60 variants`.

Every test drives the real `generate.main(["--verify"])` against a corpus of its own,
generated into a temporary directory, so nothing here depends on — or disturbs — the
committed one. The mutations are the ones that actually happened: the signed zero of issue
#153, and a `.json` left behind by a variant that no longer exists.
"""

from __future__ import annotations

import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import canonical
import generate

# `generate` puts `python/fourdgs` on the path as it imports, which is why this follows it.
from fourdgs import keyframe_delta_file as kdf

#: The expectation the signed zero was found in (#153): two composed values at the noise
#: floor, which round to `-0.0` where the arithmetic lands a hair below zero.
COMPOSED = "object/ObjectTrackComposed-UseChunkIndex-UseCrc"


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A freshly generated corpus in a directory of its own, committed to disk.

    `--verify` regenerates in place and compares against what it found, so the fixture
    generates once — that written corpus *is* the committed one as far as the gate is
    concerned — and each test then plants its mutation in it.
    """
    data = tmp_path / "data"
    monkeypatch.setattr(generate, "DATA", str(data))
    monkeypatch.setattr(generate, "INVALID", str(data / "invalid"))
    monkeypatch.setattr(generate, "KEYFRAME", str(data / "keyframe"))
    monkeypatch.setattr(generate, "OBJECT", str(data / "object"))
    monkeypatch.setattr(generate, "CHECKSUMS", str(data / "CHECKSUMS.txt"))
    assert generate.main([]) == 0
    assert (data / f"{COMPOSED}.json").is_file(), "the fixture the signed-zero tests plant into"
    return data


def _verify(capsys) -> tuple[int, str]:
    code = generate.main(["--verify"])
    captured = capsys.readouterr()
    return code, captured.out + captured.err


class TestTheExpectationsAreChecked:
    def test_an_expectation_a_fresh_decode_does_not_produce_fails(self, corpus, capsys):
        """The second of the three things the docstring has always claimed `--verify`
        asserts, and the one it did not: the `.json` files were overwritten by the run and
        then compared to nothing at all."""
        path = corpus / f"{COMPOSED}.json"
        path.write_text(path.read_text().replace("2.2,", "2.3,", 1), encoding="utf-8")
        code, text = _verify(capsys)
        assert code == 1, text
        assert f"{COMPOSED}.json" in text, text
        assert "line " in text and "committed" in text, text

    def test_a_signed_zero_fails_even_though_it_parses_equal(self, corpus, capsys):
        """The bug itself, and the reason the comparison is text and not parsed JSON.

        `-0.0 == 0.0` is true in Python and in every language `run.py` compares in, so a
        gate that parsed before comparing would call these two corpora identical — which
        is exactly how a machine's floating-point path stayed in a committed expectation
        while every checksum passed.
        """
        path = corpus / f"{COMPOSED}.json"
        fresh = path.read_text(encoding="utf-8")
        assert "-0.0" not in fresh, "the canonical form must not produce a signed zero"
        planted = fresh.replace("            0.0\n", "            -0.0\n", 1)
        assert planted != fresh, "the fixture must contain a zero to plant a sign on"
        assert json.loads(planted) == json.loads(fresh), "the two must be equal as JSON, or this proves nothing"
        path.write_text(planted, encoding="utf-8")

        code, text = _verify(capsys)
        assert code == 1, text
        assert f"{COMPOSED}.json" in text, text
        assert "-0.0" in text and "committed" in text, text

    def test_a_difference_in_whitespace_alone_is_still_named(self, corpus, capsys):
        """The failure this gate exists to catch is character-level, so its message has to
        be. A comparison that stripped each line, or split without keeping line endings,
        reports a file whose only difference is its final newline as having the same lines
        as the fresh decode — a verification failure whose diagnosis says the two agree.
        """
        path = corpus / f"{COMPOSED}.json"
        path.write_text(path.read_text(encoding="utf-8").rstrip("\n"), encoding="utf-8")
        code, text = _verify(capsys)
        assert code == 1, text
        assert f"{COMPOSED}.json" in text, text
        assert "line " in text and "column " in text, text
        # The repr is what makes an invisible difference visible at all.
        assert "'}'" in text and "'}\\n'" in text, text

    def test_an_expectation_that_stops_short_names_the_line_that_is_missing(self, corpus, capsys):
        """One file a prefix of the other, which is the only way the line lists can be
        equal as far as the shorter one goes."""
        path = corpus / f"{COMPOSED}.json"
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        path.write_text("".join(lines[:-20]), encoding="utf-8")
        code, text = _verify(capsys)
        assert code == 1, text
        assert "committed lines against" in text and "is in a fresh decode only" in text, text

    def test_an_expectation_no_variant_produces_fails(self, corpus, capsys):
        """An orphan reads back identically on both sides of a directory listing, so it
        used to compare equal to itself and pass. It is not harmless: `run.py` lists the
        `.json` files to find variants, so an orphan is a variant it tries to run against a
        `.4dgs` that no longer exists."""
        orphan = corpus / "object" / "OrphanedVariant.json"
        orphan.write_text((corpus / f"{COMPOSED}.json").read_text(encoding="utf-8"), encoding="utf-8")
        code, text = _verify(capsys)
        assert code == 1, text
        assert "object/OrphanedVariant.json: committed expectation has no variant" in text, text

    def test_a_variant_with_no_committed_expectation_fails(self, corpus, capsys):
        """The other direction: a variant whose expectation was never committed."""
        (corpus / f"{COMPOSED}.json").unlink()
        code, text = _verify(capsys)
        assert code == 1, text
        assert f"{COMPOSED}.json: no committed expectation" in text, text

    def test_an_untouched_corpus_verifies(self, corpus, capsys):
        """The control. A gate that fails on everything proves nothing about the four
        above, and this is also what catches a mutation that made `--verify` fail for a
        reason none of them named."""
        code, text = _verify(capsys)
        assert code == 0, text
        assert "checksums and expectations match" in text, text


class TestTheCanonicalFormHasNoSignedZero:
    def test_num_unsigns_a_zero_and_leaves_every_other_value_alone(self):
        assert canonical.num(-1e-9) == 0.0
        assert not str(canonical.num(-1e-9)).startswith("-")
        assert canonical.num(-1.5) == -1.5
        assert canonical.num(float("nan")) is None

    def test_the_serializer_unsigns_zeros_wherever_they_sit(self):
        """A property of the canonical form itself, not of whichever helper produced the
        number: `states_json` does not go through `num`, and the next temporal model will
        very likely bring a third path.
        """
        text = canonical.canonical({"a": [-0.0, {"b": (-0.0, 1.5)}], "c": "-0", "d": True, "e": -3})
        assert "-0.0" not in text, text
        # A structural walk and not a substitution: the string-encoded integers this format
        # uses must survive, and `bool` is a subclass of `int` rather than of `float`.
        assert '"c": "-0"' in text and '"d": true' in text and '"e": -3' in text, text

    def test_the_keyframe_delta_helper_unsigns_too(self):
        """The second place the same defect lived. `build_keyframe_delta_corpus` passes
        `states_json` straight to `canonical`, so this helper is the one that produces
        every number in the `keyframe/` expectations."""
        assert kdf._num(-1e-9) == 0.0
        assert not str(kdf._num(-1e-9)).startswith("-")
        assert kdf._num(-1.5) == -1.5
        assert kdf._num(float("inf")) is None
