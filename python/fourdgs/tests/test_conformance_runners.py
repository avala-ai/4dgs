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
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs.exceptions import MalformedFile, TruncatedFile
from fourdgs.indexed_reader import open_indexed
from fourdgs.readable import BytesReadable
from fourdgs.validate import validate

CONFORMANCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "conformance")
SHARED_CONFORMANCE = os.path.join(CONFORMANCE, "..", "..", "tests", "conformance")
INVALID_GENERATOR = os.path.join(SHARED_CONFORMANCE, "generator")
RUNNERS = ("decode_streamed.py", "decode_indexed.py")

#: The runners are scripts beside the package rather than part of it, so the classifier
#: they share is imported the way they import each other.
sys.path.insert(0, CONFORMANCE)
sys.path.insert(0, SHARED_CONFORMANCE)
sys.path.insert(0, INVALID_GENERATOR)
import generate
import invalid
from refusal import CODES, refusal_answer

#: Too short to hold the magic: a truncated transport, which is a real decode failure and
#: one the named identifiers deliberately do not cover. Both read paths reach it — the
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


def _run(
    runner: str,
    data: bytes,
    tmp_path,
    *runner_args: str,
) -> subprocess.CompletedProcess:
    path = tmp_path / "input.4dgs"
    path.write_bytes(data)
    return subprocess.run(
        [sys.executable, os.path.join(CONFORMANCE, runner), *runner_args, str(path)],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize("runner", RUNNERS)
def test_one_byte_decoded_state_budget_is_the_portable_resource_result(runner, tmp_path):
    done = _run(runner, _large_finite_window_file(), tmp_path, "--max-decoded-state-bytes", "1")
    assert done.returncode == 0, done.stderr
    assert done.stdout.strip() == '{"unsupported":"resource-limit"}'
    assert done.stderr == ""


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


@pytest.mark.parametrize("value", [0.0, -0.0, -0.004], ids=["zero", "negative-zero", "negative"])
def test_non_positive_step_time_is_one_named_refusal_on_both_read_paths(value, tmp_path):
    data = invalid._step_time(_large_finite_window_file(), value)

    for decode in (fourdgs.read, lambda raw: open_indexed(BytesReadable(raw))):
        with pytest.raises(MalformedFile) as caught:
            decode(data)
        assert caught.value.code == "non-positive-step-time"
        message = str(caught.value)
        assert "Quantization record at byte" in message
        assert f"step_time {value!r} at byte" in message
        assert "greater than 0" in message

    for runner in RUNNERS:
        done = _run(runner, data, tmp_path)
        assert done.returncode == 0, f"{runner} failed: {done.stderr}"
        assert json.loads(done.stdout) == {"refused": "non-positive-step-time"}


def _index_count_base() -> bytes:
    return next(
        data for name, data, _expectation in generate.build_keyframe_delta_corpus() if name == invalid.INDEX_COUNT_BASE
    )


@pytest.mark.parametrize("refusal", invalid.INDEX_COUNT_REFUSALS, ids=lambda refusal: refusal.name)
def test_index_count_mismatches_are_one_named_refusal_on_both_read_paths(refusal, tmp_path):
    base = _index_count_base()
    data = refusal.mutate(base)
    opened = kdf.open_indexed(data)
    wrong = next(entry for entry in opened.index if entry.kind == 1)
    field = "gaussian_count" if "Gaussian" in refusal.name else "live_count"
    declared = getattr(wrong, field)
    decoded = next(chunk for chunk in kdf.decode_streamed(base).chunks if chunk.offset == wrong.chunk_offset)
    observed = (
        decoded.update_count + decoded.birth_count + decoded.death_count
        if field == "gaussian_count"
        else decoded.state.count
    )

    # The validator's refusal belongs to the physical state record named by the
    # disagreeing entry, not to the summary entry that carries the wrong count. This
    # assertion runs from the staged witnesses before they join the invalid corpus, so
    # the corpus-driven placement sweep cannot silently lose coverage while activation
    # is waiting on another SDK layer.
    report = validate(data)
    placed = next(
        finding.refusal
        for finding in report.findings
        if finding.refusal is not None and finding.refusal.code == "index-record-mismatch"
    )
    assert placed.site is not None
    assert placed.site.offset == wrong.chunk_offset
    assert data[placed.site.offset] == op.DELTA_CHUNK

    # The whole streamed decoder and the ordinary indexed decoder both own the rule.
    for decode in (kdf.decode_streamed, kdf.decode_indexed):
        with pytest.raises(MalformedFile) as caught:
            decode(data)
        assert caught.value.code == "index-record-mismatch"
        message = str(caught.value)
        assert f"chunk index entry at {wrong.chunk_offset}" in message
        assert f"declares {field} {declared}" in message
        assert f"is {observed}" in message

    # A selected entry also verifies every state in its required chain. The wrong first
    # delta is an intermediate of the next delta, not the selected entry itself.
    selected = opened.index[2]
    assert selected.reference_offset == wrong.chunk_offset
    with pytest.raises(MalformedFile) as caught:
        kdf.compose_chain(data, opened.index, selected, opened.windows, opened.grids)
    assert caught.value.code == "index-record-mismatch"
    assert f"chunk index entry at {wrong.chunk_offset}" in str(caught.value)

    for runner in RUNNERS:
        done = _run(runner, data, tmp_path)
        assert done.returncode == 0, f"{runner} failed: {done.stderr}"
        assert json.loads(done.stdout) == {"refused": "index-record-mismatch"}


@pytest.mark.parametrize("refusal", invalid.INDEX_COUNT_REFUSALS, ids=lambda refusal: refusal.name)
def test_an_index_count_mismatch_in_an_unrelated_gop_does_not_expand_a_seek(refusal):
    data = refusal.mutate(_index_count_base())
    opened = kdf.open_indexed(data)
    later_keyframe = next(entry for entry in opened.index if entry.kind == 0 and entry.t0 > 0)

    state = kdf.compose_chain(data, opened.index, later_keyframe, opened.windows, opened.grids)

    assert state.count == later_keyframe.live_count


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
    the classifier directly. `index-record-mismatch` is staged vocabulary for the two
    count witnesses, while `depth-mismatch` remains outside this corpus family.
    """
    assert refusal_answer(TruncatedFile("file is shorter than the magic")) is None
    assert refusal_answer(MalformedFile("bad depth", code="depth-mismatch")) is None
    assert "depth-mismatch" not in CODES
    assert "index-record-mismatch" in CODES
    assert json.loads(refusal_answer(MalformedFile("bad index", code="index-record-mismatch"))) == {
        "refused": "index-record-mismatch"
    }
    assert json.loads(refusal_answer(MalformedFile("bad magic", code="magic-mismatch"))) == {
        "refused": "magic-mismatch"
    }
