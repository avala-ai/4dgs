# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Finite-binary32 reconstruction at every physical state-record boundary."""

from __future__ import annotations

import sys

import fourdgs
import numpy as np
import pytest
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.readable import BytesReadable
from fourdgs.serialization import MAGIC, crc32, encode_stream
from fourdgs.validate import validate


def _quantization(
    *,
    position_step: float = 0.001,
    scale_step: float = 0.04,
    sigma_step: float = 0.04,
    motion_step: float = 0.001,
    time_step: float = 0.004,
) -> rec.Quantization:
    return rec.Quantization(
        scheme="uniform-v1",
        pos_origin=[0.0, 0.0, 0.0],
        step_pos=position_step,
        step_scale_log=scale_step,
        step_rot=0.004,
        step_rgb=0.008,
        step_alpha=0.008,
        step_motion=motion_step,
        step_time=time_step,
        step_sigma_log=sigma_step,
        step_sh=1,
    )


def _bins(
    *,
    position: int = 0,
    scale: int = 0,
    motion: int = 0,
    mu: int = 0,
    sigma: int = 0,
    flags: int = 0,
) -> dict[int, np.ndarray]:
    return {
        op.A_POSITION: np.array([[position, 0, 0]], dtype=np.int64),
        op.A_SCALE: np.array([[scale, 0, 0]], dtype=np.int64),
        op.A_ROTATION_INDEX: np.array([[3]], dtype=np.int64),
        op.A_ROTATION: np.zeros((1, 3), dtype=np.int64),
        op.A_COLOR: np.zeros((1, 3), dtype=np.int64),
        op.A_OPACITY: np.zeros((1, 1), dtype=np.int64),
        op.A_MOTION: np.array([[motion, 0, 0]], dtype=np.int64),
        op.A_MU_T: np.array([[mu]], dtype=np.int64),
        op.A_SIGMA_T: np.array([[sigma]], dtype=np.int64),
        op.A_FLAGS: np.array([[flags]], dtype=np.int64),
        op.A_WINDOW_INDEX: np.zeros((1, 1), dtype=np.int64),
    }


def _stack_bins(*rows: dict[int, np.ndarray]) -> dict[int, np.ndarray]:
    return {attribute: np.concatenate([row[attribute] for row in rows]) for attribute in rows[0]}


def _ids(values) -> np.ndarray:
    return np.asarray(values, dtype=np.int64).reshape(-1, 1)


def _streams(bins: dict[int, np.ndarray], gaussian_id=None) -> bytes:
    encoded = []
    if gaussian_id is not None:
        encoded.append(encode_stream(op.A_GAUSSIAN_ID, _ids(gaussian_id)))
    for attribute in op.REQUIRED_ATTRIBUTES:
        values = bins[attribute]
        encoded.append(encode_stream(attribute, values, channels=values.shape[1]))
    return b"".join(encoded)


def _group(gaussian_id, bins: dict[int, np.ndarray]) -> bytes:
    encoded = [encode_stream(op.A_GAUSSIAN_ID, _ids(gaussian_id))]
    for attribute, values in sorted(bins.items()):
        encoded.append(encode_stream(attribute, values, channels=values.shape[1]))
    return b"".join(encoded)


def _finish(prefix: bytes, entries: list[rec.ChunkIndexEntry], *, indexed: bool = True) -> bytes:
    if not indexed:
        return prefix + rec.Footer(summary_start=0, summary_crc=0).encode() + MAGIC
    summary_start = len(prefix)
    summary = b"".join(entry.encode() for entry in entries)
    return prefix + summary + rec.Footer(summary_start=summary_start, summary_crc=crc32(summary)).encode() + MAGIC


def _gaussian_birth_file(
    *,
    position: int = 0,
    scale: int = 0,
    motion: int = 0,
    mu: int = 0,
    sigma: int = 0,
    flags: int = 0,
    position_step: float = 0.001,
    scale_step: float = 0.04,
    sigma_step: float = 0.04,
    motion_step: float = 0.001,
    time_step: float = 0.004,
    indexed: bool = True,
) -> tuple[bytes, int]:
    front = (
        MAGIC
        + rec.Header(duration_sec=1.0, gaussian_count=1, aabb=[0.0] * 6).encode()
        + _quantization(
            position_step=position_step,
            scale_step=scale_step,
            sigma_step=sigma_step,
            motion_step=motion_step,
            time_step=time_step,
        ).encode()
        + rec.WindowTable([(0.0, 1.0)]).encode()
    )
    chunk_at = len(front)
    chunk = rec.encode_chunk(
        0.0,
        1.0,
        0,
        1,
        _streams(_bins(position=position, scale=scale, motion=motion, mu=mu, sigma=sigma, flags=flags)),
    )
    prefix = front + chunk
    entry = rec.ChunkIndexEntry(0.0, 1.0, chunk_at, len(chunk), 1)
    return _finish(prefix, [entry], indexed=indexed), chunk_at


def _keyframe_delta_file(
    *,
    keyframe_scale: int = 0,
    keyframe_sigma: int = 0,
    keyframe_flags: int = 0,
    update_scale: int | None = None,
    update: tuple[np.ndarray, dict[int, np.ndarray]] | None = None,
    birth: dict[int, np.ndarray] | None = None,
    birth_ids=None,
    keyframe_bins: dict[int, np.ndarray] | None = None,
    keyframe_ids=None,
    position_step: float = 0.001,
    scale_step: float = 0.04,
    sigma_step: float = 0.04,
    motion_step: float = 0.001,
    time_step: float = 0.004,
    indexed: bool = True,
) -> tuple[bytes, list[int]]:
    if update is not None and update_scale is not None:
        raise ValueError("pass update or update_scale, not both")
    if keyframe_bins is None:
        keyframe_bins = _bins(scale=keyframe_scale, sigma=keyframe_sigma, flags=keyframe_flags)
    if keyframe_ids is None:
        keyframe_ids = np.array([7], dtype=np.int64)
    else:
        keyframe_ids = np.asarray(keyframe_ids, dtype=np.int64).reshape(-1)
    if update is None and update_scale is not None:
        update = (np.array([7], dtype=np.int64), {op.A_SCALE: np.array([[update_scale, 0, 0]], dtype=np.int64)})
    if birth is not None:
        birth_ids = np.array([8], dtype=np.int64) if birth_ids is None else np.asarray(birth_ids, dtype=np.int64)
        birth_ids = birth_ids.reshape(-1)

    has_delta = update is not None or birth is not None
    duration = 2.0 if has_delta else 1.0
    distinct = len(set(keyframe_ids.tolist()) | (set() if birth_ids is None else set(birth_ids.tolist())))
    front = (
        MAGIC
        + rec.Header(
            duration_sec=duration,
            gaussian_count=distinct,
            aabb=[0.0] * 6,
            temporal_model="keyframe-delta",
        ).encode()
        + _quantization(
            position_step=position_step,
            scale_step=scale_step,
            sigma_step=sigma_step,
            motion_step=motion_step,
            time_step=time_step,
        ).encode()
        + rec.WindowTable([(0.0, duration)]).encode()
    )
    keyframe_at = len(front)
    keyframe = rec.encode_chunk(
        0.0,
        1.0 if has_delta else duration,
        0,
        len(keyframe_ids),
        _streams(keyframe_bins, gaussian_id=keyframe_ids),
    )
    prefix = front + keyframe
    entries = [
        rec.ChunkIndexEntry(
            0.0,
            1.0 if has_delta else duration,
            keyframe_at,
            len(keyframe),
            len(keyframe_ids),
            extended=True,
            kind=0,
            keyframe_offset=keyframe_at,
            live_count=len(keyframe_ids),
        )
    ]
    offsets = [keyframe_at]
    if not has_delta:
        return _finish(prefix, entries, indexed=indexed), offsets

    update_count = 0 if update is None else len(update[0])
    birth_count = 0 if birth is None else len(birth_ids)
    updates = b"" if update is None else _group(update[0], update[1])
    births = b"" if birth is None else _group(birth_ids, birth)
    delta_at = len(prefix)
    delta = rec.encode_delta_chunk(
        1.0,
        2.0,
        0,
        rec.DELTA_MODE_CHAINED,
        keyframe_at,
        keyframe_at,
        1,
        updates,
        births,
        b"",
        (update_count, birth_count, 0),
    )
    prefix += delta
    entries.append(
        rec.ChunkIndexEntry(
            1.0,
            2.0,
            delta_at,
            len(delta),
            update_count + birth_count,
            extended=True,
            kind=1,
            delta_mode=rec.DELTA_MODE_CHAINED,
            reference_offset=keyframe_at,
            keyframe_offset=keyframe_at,
            depth=1,
            live_count=len(keyframe_ids) + birth_count,
        )
    )
    offsets.append(delta_at)
    return _finish(prefix, entries, indexed=indexed), offsets


def _gaussian_birth_decodes(data: bytes):
    yield lambda: fourdgs.read(data)

    def indexed():
        source = BytesReadable(data)
        scene = open_indexed(source)
        return read_chunk(source, scene, scene.index[0])

    yield indexed


def _keyframe_delta_decodes(data: bytes):
    yield lambda: kdf.decode_streamed(data)
    yield lambda: kdf.decode_indexed(data)


def _assert_overflow(decodes, data: bytes, offset: int, record: str, *message: str) -> None:
    for decode in decodes:
        with pytest.raises(fourdgs.MalformedFile) as caught:
            decode()
        assert caught.value.code == "decoded-f32-overflow"
        text = str(caught.value)
        assert f"the {record} record opcode at byte {offset}" in text
        for fragment in message:
            assert fragment in text

    _assert_validator_overflow(data, offset, record)


def _assert_validator_overflow(data: bytes, offset: int, record: str) -> None:
    named = next(
        finding.refusal
        for finding in validate(data).findings
        if finding.refusal is not None and finding.refusal.code == "decoded-f32-overflow"
    )
    assert named.site is not None
    assert named.site.offset == offset
    assert f"the {record} record" in named.site.what


@pytest.mark.parametrize(
    ("field", "message"),
    [
        ("scale", ("attribute scale component x", "stored log bin 100", "step_scale_log 1.0")),
        ("sigma", ("attribute sigma_t component value", "stored bin 100", "step_sigma_log 1.0")),
    ],
)
def test_gaussian_birth_overflow_is_refused_before_narrowing(field, message):
    kwargs = {field: 100, f"{field}_step": 1.0}
    data, chunk_at = _gaussian_birth_file(**kwargs)
    _assert_overflow(_gaussian_birth_decodes(data), data, chunk_at, "Chunk", "gaussian-birth row 0", *message)


@pytest.mark.parametrize(
    ("field", "step", "message"),
    [
        ("position", "position_step", ("attribute position component x", "stored bin 1", "step_pos")),
        ("motion", "motion_step", ("attribute motion component x", "stored bin 1", "effective step")),
        ("mu", "time_step", ("attribute mu_t component value", "stored bin 1", "effective step")),
    ],
)
def test_gaussian_birth_linear_lane_overflow_is_refused(field, step, message):
    largest = sys.float_info.max
    data, chunk_at = _gaussian_birth_file(**{field: 1, step: largest})
    _assert_overflow(_gaussian_birth_decodes(data), data, chunk_at, "Chunk", "gaussian-birth row 0", *message)


@pytest.mark.parametrize(
    ("field", "message"),
    [
        ("scale", ("attribute scale component x", "absolute bin 100", "step_scale_log 1.0")),
        ("sigma", ("attribute sigma_t component value", "absolute bin 100", "step_sigma_log 1.0")),
    ],
)
def test_keyframe_overflow_names_the_chunk_row_and_gaussian(field, message):
    kwargs = {f"keyframe_{field}": 100, f"{field}_step": 1.0}
    data, offsets = _keyframe_delta_file(**kwargs)
    _assert_overflow(
        _keyframe_delta_decodes(data),
        data,
        offsets[0],
        "Chunk",
        "keyframe row 0 (gaussian_id 7)",
        *message,
    )


def test_delta_update_overflow_names_stored_and_composed_bins():
    # exp(88) fits f32; adding the stored delta makes composed bin 89, which does not.
    data, offsets = _keyframe_delta_file(keyframe_scale=88, update_scale=1, scale_step=1.0)
    _assert_overflow(
        _keyframe_delta_decodes(data),
        data,
        offsets[1],
        "Delta Chunk",
        "update row 0 (gaussian_id 7)",
        "attribute scale component x",
        "stored delta bin 1 and composed bin 89",
        "step_scale_log 1.0",
    )


def test_delta_update_overflow_names_physical_row_when_ids_are_reordered():
    keyframe = _stack_bins(_bins(scale=88), _bins())
    updates = {
        op.A_SCALE: np.array(
            [
                [0, 0, 0],
                [1, 0, 0],
            ],
            dtype=np.int64,
        )
    }
    data, offsets = _keyframe_delta_file(
        keyframe_bins=keyframe,
        keyframe_ids=np.array([30, 10]),
        update=(np.array([10, 30]), updates),
        scale_step=1.0,
    )
    _assert_overflow(
        _keyframe_delta_decodes(data),
        data,
        offsets[1],
        "Delta Chunk",
        "update row 1 (gaussian_id 30)",
        "stored delta bin 1 and composed bin 89",
    )


@pytest.mark.parametrize(
    ("field", "message"),
    [
        ("scale", ("attribute scale component x", "absolute bin 100", "step_scale_log 1.0")),
        ("sigma", ("attribute sigma_t component value", "absolute bin 100", "step_sigma_log 1.0")),
    ],
)
def test_delta_birth_overflow_names_the_delta_row_and_gaussian(field, message):
    born = _bins(**{field: 100})
    kwargs = {"birth": born, f"{field}_step": 1.0}
    data, offsets = _keyframe_delta_file(**kwargs)
    _assert_overflow(
        _keyframe_delta_decodes(data),
        data,
        offsets[1],
        "Delta Chunk",
        "birth row 0 (gaussian_id 8)",
        *message,
    )


def test_delta_birth_overflow_names_physical_birth_row():
    born = _stack_bins(_bins(), _bins(scale=100))
    data, offsets = _keyframe_delta_file(
        birth=born,
        birth_ids=np.array([90, 80]),
        scale_step=1.0,
    )
    _assert_overflow(
        _keyframe_delta_decodes(data),
        data,
        offsets[1],
        "Delta Chunk",
        "birth row 1 (gaussian_id 80)",
        "stored/composed absolute bin 100",
    )


def test_maximum_f64_step_with_zero_log_bins_is_legal():
    largest = sys.float_info.max
    gaussian, _ = _gaussian_birth_file(scale_step=largest, sigma_step=largest)
    streamed = fourdgs.read(gaussian).gaussians
    source = BytesReadable(gaussian)
    opened = open_indexed(source)
    indexed = read_chunk(source, opened, opened.index[0])
    assert streamed.scales[0, 0] == indexed["scales"][0, 0] == 1.0
    assert streamed.sigma_t[0] == indexed["sigma_t"][0] == 1.0

    keyframe, _ = _keyframe_delta_file(scale_step=largest, sigma_step=largest)
    for decoded in (kdf.decode_streamed(keyframe), kdf.decode_indexed(keyframe)[0]):
        state = kdf.reconstruct_at(decoded.chunks[0].state, decoded.grids, 0.0)
        assert state["scales"][0, 0] == 1.0

    # An underflowed sigma selects an effective motion step beyond binary64. Its zero bin
    # still denotes exact zero, so the completed result remains a legal f32 lane. The mu
    # step stays finite but extreme, and its zero-bin result is zero for the same reason.
    kwargs = dict(sigma=-1, sigma_step=largest, motion_step=largest, time_step=largest)
    gaussian, _ = _gaussian_birth_file(**kwargs)
    with np.errstate(all="raise"):
        for decode in _gaussian_birth_decodes(gaussian):
            decoded = decode()
            values = decoded.gaussians if hasattr(decoded, "gaussians") else decoded
            assert values.motions[0, 0] == 0.0 if hasattr(values, "motions") else values["motions"][0, 0] == 0.0
            assert values.mu_t[0] == 0.0 if hasattr(values, "mu_t") else values["mu_t"][0] == 0.0

    update = (np.array([7]), {op.A_MOTION: np.zeros((1, 3), dtype=np.int64)})
    born = _bins(sigma=-1)
    keyframe_delta, _ = _keyframe_delta_file(
        keyframe_sigma=-1,
        update=update,
        birth=born,
        sigma_step=largest,
        motion_step=largest,
        time_step=largest,
    )
    with np.errstate(all="raise"):
        for decode in _keyframe_delta_decodes(keyframe_delta):
            decoded = decode()
            sequence = decoded[0] if isinstance(decoded, tuple) else decoded
            values = kdf._dequantize(sequence.chunks[-1].state, sequence.grids)
            assert np.all(values["motions"] == 0.0)
            assert np.all(values["mu_t"] == 0.0)
        assert not any(finding.refusal is not None for finding in validate(keyframe_delta).findings)


def test_future_flag_bit_does_not_select_the_never_fades_sentinel():
    future_flag = 1 << 1
    gaussian, chunk_at = _gaussian_birth_file(sigma=100, flags=future_flag, sigma_step=1.0)
    _assert_overflow(
        _gaussian_birth_decodes(gaussian),
        gaussian,
        chunk_at,
        "Chunk",
        "gaussian-birth row 0",
        "attribute sigma_t component value",
    )

    keyframe, offsets = _keyframe_delta_file(
        keyframe_sigma=100,
        keyframe_flags=future_flag,
        sigma_step=1.0,
    )
    _assert_overflow(
        _keyframe_delta_decodes(keyframe),
        keyframe,
        offsets[0],
        "Chunk",
        "keyframe row 0 (gaussian_id 7)",
        "attribute sigma_t component value",
    )


@pytest.mark.parametrize("temporal_model", ["gaussian-birth", "keyframe-delta"])
def test_unindexed_streamed_validator_reports_the_physical_overflow_site(temporal_model):
    if temporal_model == "gaussian-birth":
        data, offset = _gaussian_birth_file(scale=100, scale_step=1.0, indexed=False)
        decodes = (lambda: fourdgs.read(data),)
    else:
        data, offsets = _keyframe_delta_file(keyframe_scale=100, scale_step=1.0, indexed=False)
        offset = offsets[0]
        decodes = (lambda: kdf.decode_streamed(data),)

    _assert_overflow(decodes, data, offset, "Chunk", "row 0", "attribute scale component x")


def test_never_fades_is_the_only_legal_infinite_sigma():
    largest = sys.float_info.max
    flags = op.FLAG_NEVER_FADES | (1 << 1)
    gaussian, _ = _gaussian_birth_file(sigma=100, flags=flags, sigma_step=largest)
    with np.errstate(all="raise"):
        for decode in _gaussian_birth_decodes(gaussian):
            decoded = decode()
            sigma = decoded.gaussians.sigma_t if hasattr(decoded, "gaussians") else decoded["sigma_t"]
            assert np.isposinf(sigma[0])

    keyframe, _ = _keyframe_delta_file(
        keyframe_sigma=100,
        keyframe_flags=flags,
        sigma_step=largest,
    )
    with np.errstate(all="raise"):
        for decode in _keyframe_delta_decodes(keyframe):
            decoded = decode()
            sequence = decoded[0] if isinstance(decoded, tuple) else decoded
            values = kdf._dequantize(sequence.chunks[0].state, sequence.grids)
            assert np.isposinf(values["sigma_t"][0])

    born = _bins(sigma=100, flags=flags)
    delta, _ = _keyframe_delta_file(birth=born, sigma_step=largest)
    with np.errstate(all="raise"):
        for decode in _keyframe_delta_decodes(delta):
            decoded = decode()
            sequence = decoded[0] if isinstance(decoded, tuple) else decoded
            values = kdf._dequantize(sequence.chunks[-1].state, sequence.grids)
            by_id = dict(zip(sequence.chunks[-1].state.ids.tolist(), values["sigma_t"], strict=True))
            assert np.isposinf(by_id[8])
