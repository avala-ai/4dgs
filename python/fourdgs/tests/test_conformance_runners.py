# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""What the conformance runners claim when a file will not decode.

The harness reads two things from a runner: its exit status and its stdout. Those carry
two different claims, and the invalid corpus only means anything while they stay apart.
Exit 0 with `{"refused": "<identifier>"}` says "I refused this file, and here is the rule
it broke" — an answer, diffed against the committed expectation. A non-zero exit says "I
did not produce an answer at all".

An error the refusal vocabulary does not name belongs to the second claim. Serialized as
`{"refused": ""}` with exit 0 it becomes the first: the empty string is not an identifier
the format defines, so the harness is handed a refusal it cannot check, and `--update`
would write it into the corpus as the contract. These tests drive both entry points
through an unnamed error and hold them to stdout, stderr and status together, because any
one of the three in isolation looks the same either way.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys

import fourdgs
import numpy as np
import pytest
from fourdgs.exceptions import MalformedFile, TruncatedFile

CONFORMANCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "conformance")
RUNNERS = ("decode_streamed.py", "decode_indexed.py")

#: The runners are scripts beside the package rather than part of it, so the classifier
#: they share is imported the way they import each other.
sys.path.insert(0, CONFORMANCE)
from refusal import CODES, refusal_answer

#: Too short to hold the magic: a truncated transport, which is a real decode failure and
#: one the six identifiers deliberately do not name. Both read paths reach it — the
#: streamed runner through `check_magic`, the indexed one through its opener — so it is
#: the same question asked of both.
UNNAMED = b"4DG"

#: The magic is the one refusal a file this small can still carry a name for, which makes
#: it the control: the fix must not turn refusals into failures on its way to turning
#: failures into failures.
NAMED = b"NOT4DGS!\n"


def _large_finite_window_file() -> bytes:
    gaussians = fourdgs.GaussianSet(
        positions=np.zeros((1, 3), dtype=np.float32),
        scales=np.ones((1, 3), dtype=np.float32),
        rotations=np.array([[0, 0, 0, 1]], dtype=np.float32),
        colors=np.ones((1, 4), dtype=np.float32),
        motions=np.zeros((1, 3), dtype=np.float32),
        mu_t=np.zeros(1, dtype=np.float32),
        sigma_t=np.full(1, np.inf, dtype=np.float32),
        win_lo=np.zeros(1, dtype=np.float64),
        win_hi=np.full(1, 1e100, dtype=np.float64),
        sh_degree=0,
        object_id=np.ones(1, dtype=np.uint32),
    )
    output = io.BytesIO()
    fourdgs.write(output, gaussians, 1e101)
    return output.getvalue()


def _run(runner: str, data: bytes, tmp_path) -> subprocess.CompletedProcess:
    path = tmp_path / "input.4dgs"
    path.write_bytes(data)
    return subprocess.run(
        [sys.executable, os.path.join(CONFORMANCE, runner), str(path)],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize("runner", RUNNERS)
def test_an_unnamed_error_is_a_failed_invocation(runner, tmp_path):
    """No refusal document, a diagnosis on stderr, and a non-zero status.

    All three are asserted because the defect this covers passed two of them: it printed
    a well-formed JSON document and exited cleanly, and only the identifier inside it —
    `""` — said anything was wrong.
    """
    done = _run(runner, UNNAMED, tmp_path)
    assert done.returncode != 0, f"{runner} claimed an answer for an error it cannot name"
    assert "refused" not in done.stdout, f"{runner} printed a refusal document: {done.stdout!r}"
    assert done.stdout.strip() == ""
    assert done.stderr.strip(), f"{runner} failed without saying why"


@pytest.mark.parametrize("runner", RUNNERS)
def test_a_named_refusal_is_still_an_answer(runner, tmp_path):
    """The other half of the split, which is the half a careless fix breaks.

    A refusal is a result, not a crash. Exiting non-zero here would collapse "refused for
    the right reason" and "fell over" into one outcome, which is what the invalid corpus
    exists to tell apart.
    """
    done = _run(runner, NAMED, tmp_path)
    assert done.returncode == 0, f"{runner} failed the invocation for a refusal it named: {done.stderr!r}"
    assert json.loads(done.stdout) == {"refused": "magic-mismatch"}


def test_large_finite_window_endpoint_agrees_on_both_read_paths(tmp_path):
    answers = []
    for runner in RUNNERS:
        done = _run(runner, _large_finite_window_file(), tmp_path)
        assert done.returncode == 0, f"{runner} failed: {done.stderr}"
        answers.append(json.loads(done.stdout))

    assert answers[0] == answers[1]
    assert any(state["t"] > 1e100 and state["liveCount"] == "0" for state in answers[0]["states"])


def test_only_a_registered_identifier_is_an_answer():
    """The rule the two runners share, stated once against the corpus's own registry.

    The unregistered case has no cheap file to make — every identifier the reference
    reader produces for a small broken file is one the corpus knows — so it is asked of
    the classifier directly. `index-record-mismatch` is a refusal this library names and
    the invalid corpus does not register; answering with it would put an identifier into
    the corpus that no expectation was written against.
    """
    assert refusal_answer(TruncatedFile("file is shorter than the magic")) is None
    assert refusal_answer(MalformedFile("bad index", code="index-record-mismatch")) is None
    assert "index-record-mismatch" not in CODES
    assert json.loads(refusal_answer(MalformedFile("bad magic", code="magic-mismatch"))) == {
        "refused": "magic-mismatch"
    }
