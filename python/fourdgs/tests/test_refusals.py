# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Refusal identifiers: that a reader refuses, and that it says which rule.

The conformance corpus checks these across languages. These tests check the two things
the corpus cannot: that the identifier is on the exception a caller catches, and that the
two read paths — front to back and through the index — refuse the same file for the same
reason. A check on only one path refuses half the files it should, and the half it misses
is whichever path the consumer happens to use.
"""

from __future__ import annotations

import io
import os
import sys

import fourdgs
import numpy as np
import pytest
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.readable import BytesReadable

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "tests", "conformance", "generator"))
import invalid

RNG = np.random.default_rng(20260729)


def _scene(n: int = 24, windows: int = 4) -> bytes:
    """A small valid file with more than one validity window."""
    span = 1.0
    gaussians = fourdgs.GaussianSet(
        positions=RNG.normal(size=(n, 3)).astype(np.float32),
        scales=np.full((n, 3), 0.01, dtype=np.float32),
        rotations=np.tile(np.asarray([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=RNG.uniform(0.1, 0.9, size=(n, 4)).astype(np.float32),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.asarray([(i % windows) * span + span / 2 for i in range(n)], dtype=np.float32),
        sigma_t=np.full(n, 0.1, dtype=np.float32),
        win_lo=np.asarray([(i % windows) * span for i in range(n)], dtype=np.float32),
        win_hi=np.asarray([(i % windows + 1) * span for i in range(n)], dtype=np.float32),
    )
    buf = io.BytesIO()
    fourdgs.write(buf, gaussians, windows * span, options=fourdgs.WriteOptions(write_index=True, write_crc=True))
    return buf.getvalue()


def _read_streamed(data: bytes):
    return fourdgs.read(data)


def _read_indexed(data: bytes):
    """The other read path: Footer, then index, then the chunks it needs.

    It reaches the Header by a different route than the streamed reader, which is why
    both are checked. A registry check placed on one path only refuses half the files it
    should, and which half depends on how the consumer opened the file.
    """
    source = BytesReadable(data)
    scene = open_indexed(source)
    for entry in scene.index:
        read_chunk(source, scene, entry)
    return scene


@pytest.mark.parametrize("refusal", invalid.REFUSALS, ids=lambda r: r.name)
def test_streamed_read_refuses_with_the_declared_code(refusal):
    """Every mutation the conformance corpus declares is refused, by its own identifier.

    Driven from `invalid.REFUSALS` rather than from a list copied here, so a refusal
    added to the corpus cannot silently go unimplemented in the reference reader.
    """
    broken = refusal.mutate(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(broken)
    assert caught.value.code == refusal.code, f"{refusal.name}: refused as {caught.value.code!r}"


@pytest.mark.parametrize("refusal", invalid.REFUSALS, ids=lambda r: r.name)
def test_indexed_read_refuses_with_the_same_code(refusal):
    broken = refusal.mutate(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_indexed(broken)
    assert caught.value.code == refusal.code, f"{refusal.name}: refused as {caught.value.code!r}"


def test_the_base_scene_is_valid():
    """The control. A mutation proves nothing if the file was already broken."""
    data = _scene()
    assert _read_streamed(data).gaussians.count == 24
    assert len(_read_indexed(data).index) >= 1


def test_an_unknown_temporal_model_is_refused_not_assumed():
    """The refusal the whole extension story rests on.

    A file naming a temporal model this reader does not implement carries gaussians whose
    every other field is well-formed, so a reader that skips the check decodes it as
    `gaussian-birth` and returns a plausible scene. Nothing downstream can tell that the
    motion it is drawing is not the motion the file describes.
    """
    broken = invalid._unknown_temporal_model(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(broken)
    assert caught.value.code == "unknown-temporal-model"
    assert "frame-sequence" in str(caught.value), "the message must name the value it does not know"


def test_a_corrupt_first_byte_is_not_reported_as_a_version_problem():
    """`0x89` is a sentinel, not a version.

    Reported as an unsupported version, this sends its holder looking for a newer reader,
    which would refuse it too. The two failures have different fixes and must have
    different names.
    """
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(invalid._bad_magic(_scene()))
    assert caught.value.code == "magic-mismatch"


def test_an_error_without_an_identifier_is_still_an_error():
    """An empty code is the normal state for the many faults the suite does not name.

    It must not become a reason to treat the file as readable, and it must not be
    mistaken for a code — which is why the conformance runner prints it as an empty
    identifier that matches no expectation rather than omitting the key.
    """
    err = fourdgs.MalformedFile("something specific went wrong")
    assert err.code == ""
    assert str(err) == "something specific went wrong"
