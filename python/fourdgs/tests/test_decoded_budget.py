# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The aggregate decoded-state contract on Python's three collecting APIs."""

from __future__ import annotations

import io

import fourdgs
import numpy as np
import pytest
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs import stream_reader
from fourdgs.decoded_budget import (
    DecodedStateBudget,
    gaussian_birth_decode_working_bytes,
    keyframe_decode_working_bytes,
)
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.serialization import MAGIC, iter_records


def _gaussians(windows: list[tuple[float, float]]) -> fourdgs.GaussianSet:
    count = len(windows)
    return fourdgs.GaussianSet(
        positions=np.arange(count * 3, dtype=np.float32).reshape(count, 3) / 10,
        scales=np.full((count, 3), 0.05, dtype=np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (count, 1)),
        colors=np.full((count, 4), 0.5, dtype=np.float32),
        motions=np.zeros((count, 3), dtype=np.float32),
        mu_t=np.asarray([(lo + hi) / 2 for lo, hi in windows], dtype=np.float32),
        sigma_t=np.full(count, np.inf, dtype=np.float32),
        win_lo=np.asarray([lo for lo, _hi in windows], dtype=np.float64),
        win_hi=np.asarray([hi for _lo, hi in windows], dtype=np.float64),
    )


def _gaussian_birth_file(*, two_chunks: bool = False) -> bytes:
    windows = [(0.0, 1.0), (1.0, 2.0)] if two_chunks else [(0.0, 1.0)]
    output = io.BytesIO()
    fourdgs.write(
        output,
        _gaussians(windows),
        2.0 if two_chunks else 1.0,
        options=fourdgs.WriteOptions(max_depth=0, min_chunk_gaussians=1),
    )
    return output.getvalue()


def _keyframe_delta_file() -> bytes:
    first = _gaussians([(0.0, 2.0)])
    second = _gaussians([(0.0, 2.0)])
    first.sigma_t[:] = 10.0
    second.sigma_t[:] = 10.0
    samples = [
        Sample(t0=0.0, ids=np.array([7]), gaussians=first),
        Sample(t0=1.0, ids=np.array([7]), gaussians=second),
    ]
    samples[1].gaussians.positions[0, 0] += 0.25
    return kdf.write_sequence(
        samples,
        2.0,
        kd=KeyframeDeltaOptions(keyframe_every=1, delta_mode=rec.DELTA_MODE_CHAINED),
    )


@pytest.mark.parametrize("bad", [True, False, 0, -1, 1.0, float("inf"), "1", None])
@pytest.mark.parametrize(
    "collect",
    [
        lambda value: fourdgs.read(b"", max_decoded_state_bytes=value),
        lambda value: kdf.decode_streamed(b"", max_decoded_state_bytes=value),
        lambda value: kdf.decode_indexed(b"", max_decoded_state_bytes=value),
    ],
    ids=["gaussian-birth", "keyframe-delta-streamed", "keyframe-delta-indexed"],
)
def test_collecting_api_rejects_a_non_positive_integer_budget(collect, bad):
    with pytest.raises(ValueError, match="max_decoded_state_bytes must be a positive integer"):
        collect(bad)


def test_positive_integral_subclasses_and_exact_equality_are_allowed():
    budget = DecodedStateBudget(np.int64(5))
    assert budget.check(5, "test") == 5
    assert budget.retain(5, "test") == 5


@pytest.mark.parametrize(
    "collect,data",
    [
        (fourdgs.read, _gaussian_birth_file()),
        (kdf.decode_streamed, _keyframe_delta_file()),
        (kdf.decode_indexed, _keyframe_delta_file()),
    ],
    ids=["gaussian-birth", "keyframe-delta-streamed", "keyframe-delta-indexed"],
)
def test_one_byte_is_a_resource_limit_not_a_file_refusal(collect, data):
    with pytest.raises(fourdgs.ExceedsReaderLimit) as caught:
        collect(data, max_decoded_state_bytes=1)
    assert caught.value.code == ""
    message = str(caught.value)
    assert "decoded-state" in message
    assert "configured limit is 1 bytes" in message
    assert "during" in message
    assert "at least" in message


def test_gaussian_birth_checks_before_decoding_or_allocating(monkeypatch):
    data = _gaussian_birth_file()

    def unexpected(*_args, **_kwargs):
        raise AssertionError("decoded a Chunk after its declared working set crossed the budget")

    monkeypatch.setattr(stream_reader, "decode_streams", unexpected)
    with pytest.raises(fourdgs.ExceedsReaderLimit):
        fourdgs.read(data, max_decoded_state_bytes=1)


@pytest.mark.parametrize("collect", [kdf.decode_streamed, kdf.decode_indexed])
def test_keyframe_delta_checks_before_decoding_or_allocating(monkeypatch, collect):
    data = _keyframe_delta_file()

    def unexpected(*_args, **_kwargs):
        raise AssertionError("decoded a keyframe after its declared working set crossed the budget")

    monkeypatch.setattr(kdf, "_keyframe_from_chunk", unexpected)
    with pytest.raises(fourdgs.ExceedsReaderLimit):
        collect(data, max_decoded_state_bytes=1)


def test_gaussian_birth_counts_prior_chunk_results_against_the_next_decode():
    data = _gaussian_birth_file(two_chunks=True)
    chunks = [rec.parse_chunk(record.content) for record in iter_records(data, len(MAGIC)) if record.opcode == op.CHUNK]
    assert len(chunks) == 2
    one_decode = max(
        gaussian_birth_decode_working_bytes(
            head.count,
            stream_reader.chunk_decoded_body_bytes(head, stored),
        )
        for head, stored in chunks
    )

    with pytest.raises(fourdgs.ExceedsReaderLimit, match="streamed Chunk decode"):
        fourdgs.read(data, max_decoded_state_bytes=one_decode)


@pytest.mark.parametrize("collect", [kdf.decode_streamed, kdf.decode_indexed])
def test_keyframe_delta_counts_prior_results_against_the_next_composition(collect):
    data = _keyframe_delta_file()
    chunks = [rec.parse_chunk(record.content) for record in iter_records(data, len(MAGIC)) if record.opcode == op.CHUNK]
    assert len(chunks) == 2
    one_composition = max(
        keyframe_decode_working_bytes(
            head.count,
            stream_reader.chunk_decoded_body_bytes(head, stored),
        )
        for head, stored in chunks
    )

    with pytest.raises(fourdgs.ExceedsReaderLimit):
        collect(data, max_decoded_state_bytes=one_composition)


def test_omitting_the_option_keeps_all_three_collectors_compatible():
    ordinary = fourdgs.read(_gaussian_birth_file())
    data = _keyframe_delta_file()
    streamed = kdf.decode_streamed(data)
    indexed, _ = kdf.decode_indexed(data)

    assert ordinary.gaussians.count == 1
    assert kdf.states_json(streamed) == kdf.states_json(indexed)
    assert fourdgs.DEFAULT_MAX_DECODED_STATE_BYTES == 536_870_912
