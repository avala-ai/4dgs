# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Spec section 4's boundary between front matter and physical state."""

from __future__ import annotations

import io

import fourdgs
import numpy as np
import pytest
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs.indexed_reader import open_indexed
from fourdgs.keyframe_delta_writer import Sample
from fourdgs.readable import BytesReadable
from fourdgs.serialization import MAGIC, iter_records, put_record
from fourdgs.validate import validate

DEFINED_FRONT_MATTER = (
    op.HEADER,
    op.QUANTIZATION,
    op.WINDOW_TABLE,
    op.AUDIO,
    op.CAMERA,
    op.METADATA,
    op.ATTACHMENT,
    op.AUDIO_SOURCE,
    op.AUDIO_DATA,
    op.COORDINATE_FRAME,
    op.SENSOR_CALIBRATION,
    op.RIG_TRAJECTORY,
    op.GEODETIC_ANCHOR,
    op.OBJECT_TABLE,
    op.OBJECT_TRACK,
)


def _gaussians() -> fourdgs.GaussianSet:
    return fourdgs.GaussianSet(
        positions=np.zeros((1, 3), dtype=np.float32),
        scales=np.full((1, 3), 0.05, dtype=np.float32),
        rotations=np.array([[0.0, 0.0, 0.0, 1.0]], dtype=np.float32),
        colors=np.array([[0.5, 0.4, 0.3, 0.8]], dtype=np.float32),
        motions=np.zeros((1, 3), dtype=np.float32),
        mu_t=np.array([0.5], dtype=np.float32),
        sigma_t=np.array([0.1], dtype=np.float32),
        win_lo=np.zeros(1, dtype=np.float32),
        win_hi=np.ones(1, dtype=np.float32),
    )


@pytest.fixture(scope="module")
def gaussian_birth_file() -> bytes:
    output = io.BytesIO()
    fourdgs.write(
        output,
        _gaussians(),
        1.0,
        options=fourdgs.WriteOptions(max_depth=0, write_index=False, write_crc=False),
    )
    return output.getvalue()


@pytest.fixture(scope="module")
def keyframe_delta_file() -> bytes:
    return kdf.write_sequence(
        [Sample(t0=0.0, ids=np.array([7], dtype=np.int64), gaussians=_gaussians())],
        1.0,
        write_index=False,
        write_statistics=False,
        write_crc=False,
    )


def _insert_after_first_state(data: bytes, records: tuple[tuple[int, bytes], ...]):
    state = next(record for record in iter_records(data, len(MAGIC)) if record.opcode in op.STATE_OPCODES)
    at = state.offset + 9 + len(state.content)
    inserted = b"".join(put_record(opcode, content) for opcode, content in records)
    return data[:at] + inserted + data[at:], state, at


def _assert_diagnostic(message: str, opcode: int, late_at: int, state_opcode: int, state_at: int) -> None:
    assert f"{op.name(opcode)} record (opcode 0x{opcode:02X}) at byte {late_at}" in message
    assert f"first state {op.name(state_opcode)} record (opcode 0x{state_opcode:02X}) at byte {state_at}" in message


def test_placement_classes_are_the_registry_closed_sets():
    assert op.FRONT_MATTER_OPCODES == frozenset(DEFINED_FRONT_MATTER)
    assert op.STATE_OPCODES == frozenset({op.CHUNK, op.DELTA_CHUNK})


@pytest.mark.parametrize("opcode", DEFINED_FRONT_MATTER, ids=op.name)
def test_streamed_readers_refuse_every_defined_front_matter_opcode(
    opcode: int,
    gaussian_birth_file: bytes,
    keyframe_delta_file: bytes,
):
    # Empty content makes every defined record malformed on its own. Placement must win
    # anyway, including for the three records that are also forbidden duplicates.
    for data, read in ((gaussian_birth_file, fourdgs.read), (keyframe_delta_file, kdf.decode_streamed)):
        broken, state, late_at = _insert_after_first_state(data, ((opcode, b""),))
        with pytest.raises(fourdgs.MalformedFile) as caught:
            read(broken)
        assert caught.value.code == "late-front-matter-record"
        _assert_diagnostic(str(caught.value), opcode, late_at, state.opcode, state.offset)


@pytest.mark.parametrize("opcode", DEFINED_FRONT_MATTER, ids=op.name)
def test_validator_names_the_late_record_before_parsing_it(opcode: int, gaussian_birth_file: bytes):
    broken, state, late_at = _insert_after_first_state(gaussian_birth_file, ((opcode, b""),))
    report = validate(broken)
    assert not report.ok
    finding = next(finding for finding in report.findings if finding.refusal is not None)
    assert finding.refusal.code == "late-front-matter-record"
    assert finding.refusal.site is not None and finding.refusal.site.offset == late_at
    _assert_diagnostic(finding.message, opcode, late_at, state.opcode, state.offset)


def test_validator_diagnostic_can_name_a_delta_as_the_first_state(keyframe_delta_file: bytes):
    data = bytearray(keyframe_delta_file)
    first = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.CHUNK)
    data[first.offset] = op.DELTA_CHUNK
    broken, state, late_at = _insert_after_first_state(bytes(data), ((op.METADATA, b""),))
    finding = next(finding for finding in validate(broken).findings if finding.refusal is not None)
    assert finding.refusal.site is not None and finding.refusal.site.offset == late_at
    assert finding.refusal.code == "late-front-matter-record"
    _assert_diagnostic(finding.message, op.METADATA, late_at, state.opcode, state.offset)


def test_undefined_and_private_opcodes_remain_position_independent(
    gaussian_birth_file: bytes,
    keyframe_delta_file: bytes,
):
    extensions = ((0x26, b"reserved"), (0x7D, b"future"), (0x91, b"private"))
    gaussian, _state, _at = _insert_after_first_state(gaussian_birth_file, extensions)
    scene = fourdgs.read(gaussian)
    assert scene.skipped_opcodes[-3:] == [0x26, 0x7D, 0x91]
    report = validate(gaussian)
    assert report.ok
    assert not any(
        finding.refusal is not None and finding.refusal.code == "late-front-matter-record"
        for finding in report.findings
    )

    keyframe_delta, _state, _at = _insert_after_first_state(keyframe_delta_file, extensions)
    assert len(kdf.decode_streamed(keyframe_delta).chunks) == 1
    assert validate(keyframe_delta).ok


def test_indexed_opener_may_stop_at_the_first_state(gaussian_birth_file: bytes):
    broken, _state, _at = _insert_after_first_state(gaussian_birth_file, ((op.METADATA, b""),))
    opened = open_indexed(BytesReadable(broken))
    assert opened.header.temporal_model == "gaussian-birth"
