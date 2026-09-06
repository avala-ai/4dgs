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

import dataclasses
import json
import os
import struct
import sys
import zlib
from decimal import InvalidOperation
from types import SimpleNamespace

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import canonical
import chunk_window
import encode_roundtrip
import generate
import json_compare
import pack_corpus
import run as conformance_run

# `generate` puts `python/fourdgs` on the path as it imports, which is why this follows it.
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.model import GaussianSet
from fourdgs.records import Header
from fourdgs.serialization import MAGIC, Cursor, crc32, decode_stream, iter_records
from generator import invalid

#: The expectation the signed zero was found in (#153): two composed values at the noise
#: floor, which round to `-0.0` where the arithmetic lands a hair below zero.
COMPOSED = "object/ObjectTrackComposed-UseChunkIndex-UseCrc"


def _raise(error):
    raise error


def test_encode_gate_accepts_only_the_named_index_count_refusal():
    message = (
        "the chunk index entry at 903 declares gaussian_count 4; "
        "the decoded Delta Chunk's validated operation count is 3"
    )
    accepted = encode_roundtrip._expect_index_count_failure(
        "index/keyframe-delta",
        lambda: _raise(encode_roundtrip.fourdgs.MalformedFile(message, code="index-record-mismatch")),
        assertion_field="live_count",
        refusal_field="gaussian_count",
    )
    assert accepted == message

    for error in (
        encode_roundtrip.fourdgs.MalformedFile(message),
        encode_roundtrip.fourdgs.MalformedFile("an unrelated index fault", code="index-record-mismatch"),
    ):
        with pytest.raises(AssertionError, match="expected refusal code 'index-record-mismatch'"):
            encode_roundtrip._expect_index_count_failure(
                "index/keyframe-delta",
                lambda error=error: _raise(error),
                assertion_field="live_count",
                refusal_field="gaussian_count",
            )


def test_non_positive_step_time_refusal_witnesses_change_only_the_field():
    scenario = next(item for item in generate.scenarios.SCENARIOS if item.name == invalid.BASE_SCENARIO)
    base, _ = generate.build(scenario, tuple(sorted(invalid.BASE_FLAGS)))
    field = invalid._step_time_offset(base)

    witnesses = {refusal.name: refusal.mutate(base) for refusal in invalid.STEP_TIME_REFUSALS}

    assert {refusal.code for refusal in invalid.STEP_TIME_REFUSALS} == {"non-positive-step-time"}
    assert {refusal.name for refusal in invalid.STEP_TIME_REFUSALS} <= {refusal.name for refusal in invalid.REFUSALS}, (
        "the witnesses must remain active in the all-or-none invalid corpus"
    )
    assert struct.unpack_from("<d", witnesses["ZeroStepTime"], field) == (0.0,)
    assert struct.unpack_from("<d", witnesses["NegativeStepTime"], field) == (-0.004,)
    for mutated in witnesses.values():
        changed = [index for index, pair in enumerate(zip(base, mutated, strict=True)) if pair[0] != pair[1]]
        assert changed
        assert set(changed) <= set(range(field, field + 8))


def test_index_count_refusal_witnesses_change_only_the_claim_and_repair_summary_crc():
    name, base, _expectation = next(
        item for item in generate.build_keyframe_delta_corpus() if item[0] == invalid.INDEX_COUNT_BASE
    )
    assert name == invalid.INDEX_COUNT_BASE
    chunk_offset, gaussian_field, live_field = invalid._delta_index_count_offsets(base)
    crc_field, summary_start, footer_start, base_crc = invalid._summary_crc_fields(base)
    decoded = kdf.decode_streamed(base)
    chunk = next(item for item in decoded.chunks if item.offset == chunk_offset)
    operations = chunk.update_count + chunk.birth_count + chunk.death_count
    population = len(chunk.state.ids)

    assert operations != population, "the witness must distinguish operation cost from live population"
    assert struct.unpack_from("<I", base, gaussian_field) == (operations,)
    assert struct.unpack_from("<Q", base, live_field) == (population,)
    assert zlib.crc32(base[summary_start:footer_start]) & 0xFFFFFFFF == base_crc
    assert {refusal.code for refusal in invalid.INDEX_COUNT_REFUSALS} == {"index-record-mismatch"}
    active_names = {name for name, _data, _expectation in generate.build_invalid()}
    assert {refusal.name for refusal in invalid.INDEX_COUNT_REFUSALS} <= active_names
    assert "index-record-mismatch" in invalid.CODES

    witnesses = {refusal.name: refusal.mutate(base) for refusal in invalid.INDEX_COUNT_REFUSALS}
    assert witnesses == {refusal.name: refusal.mutate(base) for refusal in invalid.INDEX_COUNT_REFUSALS}
    assert struct.unpack_from("<I", witnesses["WrongIndexGaussianCount"], gaussian_field) == (operations + 1,)
    assert struct.unpack_from("<Q", witnesses["WrongIndexGaussianCount"], live_field) == (population,)
    assert struct.unpack_from("<I", witnesses["WrongIndexLiveCount"], gaussian_field) == (operations,)
    assert struct.unpack_from("<Q", witnesses["WrongIndexLiveCount"], live_field) == (population + 1,)

    count_fields = {
        "WrongIndexGaussianCount": set(range(gaussian_field, gaussian_field + 4)),
        "WrongIndexLiveCount": set(range(live_field, live_field + 8)),
    }
    crc_bytes = set(range(crc_field, crc_field + 4))
    for witness_name, mutated in witnesses.items():
        changed = {index for index, pair in enumerate(zip(base, mutated, strict=True)) if pair[0] != pair[1]}
        assert changed & count_fields[witness_name]
        assert changed & crc_bytes
        assert changed <= count_fields[witness_name] | crc_bytes
        _, mutated_start, mutated_end, declared_crc = invalid._summary_crc_fields(mutated)
        assert (mutated_start, mutated_end) == (summary_start, footer_start)
        assert declared_crc != base_crc
        assert zlib.crc32(mutated[mutated_start:mutated_end]) & 0xFFFFFFFF == declared_crc


def _late_bases() -> tuple[bytes, bytes]:
    scenario = next(item for item in generate.scenarios.SCENARIOS if item.name == invalid.LATE_GAUSSIAN_BASE)
    gaussian, _ = generate.build(scenario, tuple(sorted(invalid.LATE_GAUSSIAN_FLAGS)))
    kd_name, keyframe_delta, _ = next(
        item for item in generate.build_keyframe_delta_corpus() if item[0] == invalid.LATE_KEYFRAME_DELTA_BASE
    )
    assert kd_name == invalid.LATE_KEYFRAME_DELTA_BASE
    return gaussian, keyframe_delta


def _assert_late_witness(base: bytes, refusal: invalid.Refusal, expected_opcode: int) -> None:
    mutated = refusal.mutate(base)
    assert len(mutated) == len(base) + invalid._RECORD_HEADER.size
    first_state = next(
        (opcode, content - invalid._RECORD_HEADER.size)
        for opcode, content, _length in invalid._records(mutated)
        if opcode in invalid._STATE_OPCODES
    )
    late = next(
        (opcode, content - invalid._RECORD_HEADER.size, length)
        for opcode, content, length in invalid._records(mutated)
        if content - invalid._RECORD_HEADER.size > first_state[1] and opcode in invalid._FRONT_MATTER_OPCODES
    )
    assert late[0] == expected_opcode
    assert late[2] == 0, "an empty body makes parse-before-placement observable"

    expectation = refusal.expectation(mutated)
    assert expectation == {
        "refused": "late-front-matter-record",
        "firstStateRecord": {"opcode": first_state[0], "at": str(first_state[1])},
        "lateRecord": {"opcode": late[0], "at": str(late[1])},
    }

    _base_crc_field, base_summary, base_footer, base_crc = invalid._summary_crc_fields(base)
    _crc_field, summary_start, footer_start, declared_crc = invalid._summary_crc_fields(mutated)
    assert summary_start == base_summary + invalid._RECORD_HEADER.size
    assert footer_start == base_footer + invalid._RECORD_HEADER.size
    assert mutated[summary_start:footer_start] == base[base_summary:base_footer]
    assert declared_crc == base_crc == zlib.crc32(mutated[summary_start:footer_start]) & 0xFFFFFFFF


def test_late_front_matter_witnesses_cover_the_closed_class_and_both_stream_loops():
    gaussian, keyframe_delta = _late_bases()
    expected_gaussian = dict(invalid._LATE_GAUSSIAN_CASES)
    expected_keyframe_delta = dict(invalid._LATE_KEYFRAME_DELTA_CASES)

    assert set(expected_gaussian.values()) == invalid._FRONT_MATTER_OPCODES
    assert set(expected_keyframe_delta.values()) == {0x03, 0x04, 0x25}
    assert {refusal.name for refusal in invalid.LATE_GAUSSIAN_REFUSALS} == set(expected_gaussian)
    assert {refusal.name for refusal in invalid.LATE_KEYFRAME_DELTA_REFUSALS} == set(expected_keyframe_delta)
    assert invalid.STREAMED_ONLY_REFUSALS == {
        f"{invalid.LATE_FRONT_MATTER_PREFIX}{name}" for name in (*expected_gaussian, *expected_keyframe_delta)
    }

    for refusal in invalid.LATE_GAUSSIAN_REFUSALS:
        _assert_late_witness(gaussian, refusal, expected_gaussian[refusal.name])
    for refusal in invalid.LATE_KEYFRAME_DELTA_REFUSALS:
        _assert_late_witness(keyframe_delta, refusal, expected_keyframe_delta[refusal.name])

    # These three are both late and forbidden duplicates. Their empty bodies also make
    # body parsing invalid, so the corpus requires placement to win over both alternatives.
    for opcode in (0x01, 0x03, 0x04):
        refusal = next(item for item in invalid.LATE_GAUSSIAN_REFUSALS if expected_gaussian[item.name] == opcode)
        records = [item for item in invalid._records(refusal.mutate(gaussian)) if item[0] == opcode]
        assert len(records) == 2

    active = {name for name, _data, _expectation in generate.build_invalid()}
    assert {name.removeprefix(invalid.LATE_FRONT_MATTER_PREFIX) for name in invalid.STREAMED_ONLY_REFUSALS} <= active
    discovered = set(conformance_run.variants())
    assert invalid.STREAMED_ONLY_REFUSALS <= discovered
    assert not any(name.startswith("invalid/Late") for name in discovered)
    assert "late-front-matter-record" in invalid.CODES


@pytest.mark.parametrize("opcode", [0x7D, 0x91], ids=["unknown", "private"])
def test_unknown_and_private_records_remain_legal_after_state(opcode: int):
    gaussian, keyframe_delta = _late_bases()
    expected_chunks = len(kdf.decode_streamed(keyframe_delta).chunks)
    gaussian = invalid._insert_before_summary(gaussian, opcode, b"control")
    keyframe_delta = invalid._insert_before_summary(keyframe_delta, opcode, b"control")

    scene = generate.fourdgs.read(gaussian)
    assert opcode in scene.skipped_opcodes
    assert len(kdf.decode_streamed(keyframe_delta).chunks) == expected_chunks


def _caps(*, indexed: bool, refusals: bool = True, late: bool = False) -> conformance_run.Capabilities:
    path = "indexed" if indexed else "streamed"
    return conformance_run.Capabilities(
        family="test",
        name=f"test/decode_{path}",
        indexed=indexed,
        refusals=refusals,
        late_front_matter_records=late,
    )


def test_late_front_matter_capability_is_streamed_only_and_does_not_weaken_other_refusals():
    baseline = "invalid/BadMagic"
    for variant in invalid.STREAMED_ONLY_REFUSALS:
        assert conformance_run.supports(_caps(indexed=False, late=True), variant)
        assert not conformance_run.supports(_caps(indexed=False, late=False), variant)
        assert not conformance_run.supports(_caps(indexed=False, refusals=False, late=True), variant)
        assert not conformance_run.supports(_caps(indexed=True, late=True), variant)
    assert conformance_run.supports(_caps(indexed=False), baseline)
    assert conformance_run.supports(_caps(indexed=True), baseline)


def test_external_late_front_matter_capability_is_explicit_and_requires_refusals(monkeypatch):
    declaration = {
        "protocol": 1,
        "name": "outside/decode_streamed",
        "family": "outside",
        "readPath": "streamed",
        "refusals": True,
        "lateFrontMatterRecords": True,
    }
    monkeypatch.setattr(
        conformance_run,
        "invoke",
        lambda _command, _args, _timeout: conformance_run.Outcome(0, json.dumps(declaration), ""),
    )
    assert conformance_run.declared_capabilities(["runner"], 1).late_front_matter_records

    declaration["refusals"] = False
    with pytest.raises(conformance_run.ProtocolError, match="lateFrontMatterRecords true but refusals false"):
        conformance_run.declared_capabilities(["runner"], 1)

    declaration["lateFrontMatterRecords"] = "yes"
    with pytest.raises(conformance_run.ProtocolError, match="expected true or false"):
        conformance_run.declared_capabilities(["runner"], 1)


def _attribute_streams(blob) -> dict[int, np.ndarray]:
    cursor = Cursor(blob)
    streams = {}
    while cursor.remaining():
        attribute, values = decode_stream(cursor)
        streams[attribute] = values
    return streams


def test_optional_identity_witnesses_pin_physical_omission_and_every_transition():
    generated = {
        model: (name, data, json.loads(expectation))
        for model, name, data, expectation in generate.build_optional_identity_corpus()
    }
    assert set(generated) == {"gaussian-birth", "keyframe-delta"}

    gaussian_name, gaussian, gaussian_expectation = generated["gaussian-birth"]
    assert "UseChunkIndex" in gaussian_name
    gaussian_records = list(iter_records(gaussian, len(MAGIC)))
    assert not {op.OBJECT_TABLE, op.OBJECT_TRACK} & {record.opcode for record in gaussian_records}
    chunks = [record for record in gaussian_records if record.opcode == op.CHUNK]
    assert len(chunks) == 2
    physical = []
    physical_maps = []
    for record in chunks:
        _head, body = rec.parse_chunk(record.content)
        streams = _attribute_streams(body)
        physical_maps.append(streams)
        physical.append(set(streams) & set(generate.OPTIONAL_IDENTITY_ATTRIBUTES))
    assert physical == [set(generate.OPTIONAL_IDENTITY_ATTRIBUTES), set()]
    assert physical_maps[0][op.A_SOURCE_GROUP][:, 0].tolist() == [-(2**31), 2**31 - 1, 0]
    assert physical_maps[0][op.A_SOURCE_INDEX][:, 0].tolist() == [2**31 - 1, -(2**31), 0]
    assert physical_maps[0][op.A_OBJECT_ID][:, 0].tolist() == [-(2**31), -1, 0]
    assert [row["sourceGroup"] for row in gaussian_expectation["identityRows"]] == [
        str(-(2**31)),
        str(2**31 - 1),
        "0",
        "0",
        "0",
    ]
    assert [row["sourceIndex"] for row in gaussian_expectation["identityRows"]][-3:] == ["0", "0", "0"]
    assert [row["objectId"] for row in gaussian_expectation["identityRows"]] == [
        str(2**31),
        str(2**32 - 1),
        "0",
        "0",
        "0",
    ]
    gaussian_indexes = [
        rec.ChunkIndexEntry.parse(record.content) for record in gaussian_records if record.opcode == op.CHUNK_INDEX
    ]
    assert [entry.chunk_offset for entry in gaussian_indexes] == [record.offset for record in chunks]
    assert [entry.chunk_length for entry in gaussian_indexes] == [9 + len(record.content) for record in chunks]

    kd_name, keyframe_delta, kd_expectation = generated["keyframe-delta"]
    assert "UseChunkIndex" in kd_name
    kd_records = list(iter_records(keyframe_delta, len(MAGIC)))
    assert not {op.OBJECT_TABLE, op.OBJECT_TRACK} & {record.opcode for record in kd_records}
    state_records = [record for record in kd_records if record.opcode in (op.CHUNK, op.DELTA_CHUNK)]
    assert [record.opcode for record in state_records] == [
        op.CHUNK,
        op.DELTA_CHUNK,
        op.DELTA_CHUNK,
        op.DELTA_CHUNK,
        op.DELTA_CHUNK,
        op.CHUNK,
        op.DELTA_CHUNK,
    ]

    group_presence = []
    group_maps = []
    for record in state_records:
        if record.opcode == op.CHUNK:
            _head, body = rec.parse_chunk(record.content)
            keyframe_streams = _attribute_streams(body)
            group_maps.append((keyframe_streams, {}))
            group_presence.append((set(keyframe_streams) & set(generate.OPTIONAL_IDENTITY_ATTRIBUTES), set()))
        else:
            _head, updates, births, _deaths = rec.parse_delta_chunk(record.content)
            update_streams = _attribute_streams(updates)
            birth_streams = _attribute_streams(births)
            group_maps.append((update_streams, birth_streams))
            group_presence.append(
                (
                    set(update_streams) & set(generate.OPTIONAL_IDENTITY_ATTRIBUTES),
                    set(birth_streams) & set(generate.OPTIONAL_IDENTITY_ATTRIBUTES),
                )
            )
    identity = set(generate.OPTIONAL_IDENTITY_ATTRIBUTES)
    assert group_presence == [
        (set(), set()),  # omitted complete keyframe
        (identity, set()),  # absent -> present update
        (set(), set()),  # omitted birth beside present survivor columns
        (set(), set()),  # omitted update carries reference
        (identity, set()),  # explicit absolute zero reset
        (set(), set()),  # new keyframe resets to logical zero
        (set(), identity),  # absent -> present birth materializes survivor zeros
    ]
    assert group_maps[1][0][op.A_SOURCE_GROUP][:, 0].tolist() == [-17]
    assert group_maps[1][0][op.A_SOURCE_INDEX][:, 0].tolist() == [23]
    assert group_maps[1][0][op.A_OBJECT_ID][:, 0].tolist() == [-1]
    assert all(group_maps[4][0][attribute][:, 0].tolist() == [0] for attribute in identity)
    assert group_maps[6][1][op.A_SOURCE_GROUP][:, 0].tolist() == [2**31 - 1]
    assert group_maps[6][1][op.A_SOURCE_INDEX][:, 0].tolist() == [-(2**31)]
    assert group_maps[6][1][op.A_OBJECT_ID][:, 0].tolist() == [-(2**31)]

    states = kd_expectation["identityStates"]
    assert [row["objectId"] for row in states[1]["rows"]] == [str(2**32 - 1), "0"]
    assert states[2]["rows"][-1] == {
        "gaussianId": "30",
        "objectId": "0",
        "sourceGroup": "0",
        "sourceIndex": "0",
    }
    assert states[3]["rows"] == states[2]["rows"], "an identity-omitting update must carry every label"
    assert all(row["sourceGroup"] == row["sourceIndex"] == row["objectId"] == "0" for row in states[4]["rows"])
    assert states[6]["rows"][-1] == {
        "gaussianId": "40",
        "objectId": str(2**31),
        "sourceGroup": str(2**31 - 1),
        "sourceIndex": str(-(2**31)),
    }

    # Every index names the exact physical record and a valid backwards chain. This is
    # what makes both the streamed and indexed runner paths applicable to the same bytes.
    indexes = [rec.ChunkIndexEntry.parse(record.content) for record in kd_records if record.opcode == op.CHUNK_INDEX]
    assert [entry.chunk_offset for entry in indexes] == [record.offset for record in state_records]
    assert [entry.chunk_length for entry in indexes] == [9 + len(record.content) for record in state_records]
    for index, entry in enumerate(indexes):
        if entry.kind == 0:
            assert entry.depth == 0 and entry.keyframe_offset == entry.chunk_offset
        else:
            assert entry.reference_offset == indexes[index - 1].chunk_offset
            assert entry.reference_offset < entry.chunk_offset
    footer = rec.Footer.parse(next(record.content for record in kd_records if record.opcode == op.FOOTER))
    footer_record = next(record for record in kd_records if record.opcode == op.FOOTER)
    assert crc32(keyframe_delta[footer.summary_start : footer_record.offset]) == footer.summary_crc


def test_optional_identity_capability_is_explicit_all_or_none_and_runs_both_read_paths():
    gaussian = "identity/gaussian-birth/OptionalIdentityGaussianBirth-UseChunkIndex-UseCrc"
    keyframe = "identity/keyframe-delta/OptionalIdentityKeyframeDelta-UseChunkIndex-UseCrc-UseStatistics"
    for indexed in (False, True):
        claimed = dataclasses.replace(_caps(indexed=indexed), optional_identity_defaults=True)
        unclaimed = _caps(indexed=indexed)
        declining = dataclasses.replace(claimed, declines=("GaussianBirth", "KeyframeDelta"))
        assert conformance_run.supports(claimed, gaussian)
        assert conformance_run.supports(claimed, keyframe)
        assert not conformance_run.supports(unclaimed, gaussian)
        assert not conformance_run.supports(unclaimed, keyframe)
        assert conformance_run.supports(declining, gaussian)
        assert conformance_run.supports(declining, keyframe)


def test_external_optional_identity_capability_is_a_boolean(monkeypatch):
    declaration = {
        "protocol": 1,
        "name": "outside/decode_streamed",
        "family": "outside",
        "readPath": "streamed",
        "optionalIdentityDefaults": True,
    }
    monkeypatch.setattr(
        conformance_run,
        "invoke",
        lambda _command, _args, _timeout: conformance_run.Outcome(0, json.dumps(declaration), ""),
    )
    assert conformance_run.declared_capabilities(["runner"], 1).optional_identity_defaults

    declaration["optionalIdentityDefaults"] = "yes"
    with pytest.raises(conformance_run.ProtocolError, match=r"optionalIdentityDefaults.*expected true or false"):
        conformance_run.declared_capabilities(["runner"], 1)


def test_chunk_window_witnesses_pin_both_half_open_gates_and_index_shapes():
    from fourdgs import opcode as op
    from fourdgs.records import ChunkIndexEntry, Header, WindowTable, parse_chunk
    from fourdgs.serialization import MAGIC, iter_records

    witnesses = {
        name: (data, json.loads(expectation)) for name, data, expectation in generate.build_chunk_window_corpus()
    }
    assert set(witnesses) == {
        "WindowOverhang-NoChunkIndex",
        "WindowOverhang-UseChunkIndex-UseCrc",
    }

    for name, (data, expectation) in witnesses.items():
        records = list(iter_records(data, len(MAGIC)))
        header = Header.parse(next(record.content for record in records if record.opcode == op.HEADER))
        windows = WindowTable.parse(next(record.content for record in records if record.opcode == op.WINDOW_TABLE))
        chunks = [record for record in records if record.opcode == op.CHUNK]
        indexes = [ChunkIndexEntry.parse(record.content) for record in records if record.opcode == op.CHUNK_INDEX]
        head, _streams = parse_chunk(chunks[0].content)

        assert header.temporal_model == "gaussian-birth"
        assert header.attributes == {"conformance": chunk_window.MARKER}
        assert windows.windows == [(0.0, 3.0)]
        assert len(chunks) == 1
        assert (head.t0, head.t1, head.count) == (1.0, 2.0, 1)
        assert bool(indexes) == ("UseChunkIndex" in name)
        if indexes:
            assert len(indexes) == 1
            assert (indexes[0].t0, indexes[0].t1, indexes[0].gaussian_count) == (1.0, 2.0, 1)
            assert indexes[0].chunk_offset == chunks[0].offset

        scene = generate.fourdgs.read(data)
        assert scene.gaussians.win_lo.tolist() == [0.0]
        assert scene.gaussians.win_hi.tolist() == [3.0]
        assert np.isposinf(scene.gaussians.sigma_t).tolist() == [True]
        # Window-only reconstruction returns the row at all four probes. The committed
        # verdict differs at three of them, so the witness cannot pass without the Chunk gate.
        assert [scene.gaussians.state_at(t, header.cutoff)["indices"].size for t in chunk_window.PROBE_TIMES] == [
            1,
            1,
            1,
            1,
        ]
        assert expectation["sample"]["winLo"] == [0.0]
        assert expectation["sample"]["winHi"] == [3.0]
        assert expectation["states"] == [
            {"liveCount": "0", "t": 0.5},
            {"liveCount": "1", "t": 1.5},
            {"liveCount": "0", "t": 2.0},
            {"liveCount": "0", "t": 2.5},
        ]


def _chunk_window_caps(*, indexed: bool, claimed: bool, declines=()) -> conformance_run.Capabilities:
    path = "indexed" if indexed else "streamed"
    return conformance_run.Capabilities(
        family="test",
        name=f"test/decode_{path}",
        indexed=indexed,
        refusals=False,
        declines=declines,
        gaussian_birth_chunk_window_intersection=claimed,
    )


def test_chunk_window_capability_is_all_or_none_and_preserves_index_applicability():
    indexed = f"{chunk_window.PREFIX}WindowOverhang-UseChunkIndex-UseCrc"
    no_index = f"{chunk_window.PREFIX}WindowOverhang-NoChunkIndex"

    assert conformance_run.supports(_chunk_window_caps(indexed=False, claimed=True), indexed)
    assert conformance_run.supports(_chunk_window_caps(indexed=False, claimed=True), no_index)
    assert conformance_run.supports(
        _chunk_window_caps(indexed=False, claimed=True, declines=("WindowOverhang",)), indexed
    )
    assert conformance_run.supports(_chunk_window_caps(indexed=True, claimed=True), indexed)
    assert not conformance_run.supports(_chunk_window_caps(indexed=True, claimed=True), no_index)
    assert not conformance_run.supports(_chunk_window_caps(indexed=False, claimed=False), indexed)
    assert not conformance_run.supports(_chunk_window_caps(indexed=False, claimed=False), no_index)
    assert {indexed, no_index} <= set(conformance_run.variants())
    assert not conformance_run.GAUSSIAN_BIRTH_CHUNK_WINDOW_INTERSECTION_FAMILIES


def test_external_chunk_window_capability_is_boolean_and_defaults_false(monkeypatch):
    declaration = {
        "protocol": 1,
        "name": "outside/decode_streamed",
        "family": "outside",
        "readPath": "streamed",
    }

    def declared():
        monkeypatch.setattr(
            conformance_run,
            "invoke",
            lambda _command, _args, _timeout: conformance_run.Outcome(0, json.dumps(declaration), ""),
        )
        return conformance_run.declared_capabilities(["runner"], 1)

    assert not declared().gaussian_birth_chunk_window_intersection
    declaration[chunk_window.CAPABILITY] = True
    assert declared().gaussian_birth_chunk_window_intersection
    declaration[chunk_window.CAPABILITY] = 1
    with pytest.raises(conformance_run.ProtocolError, match=rf"{chunk_window.CAPABILITY}.*expected true or false"):
        declared()


def test_chunk_window_query_invocation_and_direct_path_verdict_pairing():
    variant = f"{chunk_window.PREFIX}WindowOverhang-UseChunkIndex-UseCrc"
    assert conformance_run.variant_arguments(variant, "/tmp/witness.4dgs") == [
        "--gaussian-birth-state-times",
        "[0.5,1.5,2.0,2.5]",
        "/tmp/witness.4dgs",
    ]
    assert conformance_run.variant_arguments("OneGaussian-UseChunkIndex-UseCrc", "/tmp/base.4dgs") == ["/tmp/base.4dgs"]

    streamed = {"states": [{"t": 0.5, "liveCount": "0"}, {"t": 1.5, "liveCount": "1"}]}
    indexed = {"states": [{"t": 0.5, "liveCount": "0"}, {"t": 1.5, "liveCount": "0"}]}
    streamed_verdict = conformance_run.chunk_window_verdict(streamed)
    indexed_verdict = conformance_run.chunk_window_verdict(indexed)
    results = {
        ("test", variant, False): streamed_verdict,
        ("test", variant, True): indexed_verdict,
    }
    assert list(conformance_run.chunk_window_path_pairs(results)) == [
        ("test", variant, streamed_verdict, indexed_verdict)
    ]
    assert streamed_verdict != indexed_verdict


def test_release_manifest_uses_the_same_indexed_exemption_and_temporal_model_registry(tmp_path):
    file_path = tmp_path / "fixture.4dgs"
    expectation_path = tmp_path / "fixture.json"
    file_path.write_bytes(b"fixture")
    expectation_path.write_text('{"refused":"late-front-matter-record"}\n', encoding="utf-8")

    for qualified in invalid.STREAMED_ONLY_REFUSALS:
        name = qualified.removeprefix(invalid.LATE_FRONT_MATTER_PREFIX)
        entry = pack_corpus.describe(name, "invalid/late-front-matter", str(file_path), str(expectation_path))
        assert entry["family"] == "invalid/late-front-matter"
        assert not entry["indexed"]
        expected_model = "keyframe-delta" if qualified in invalid.KEYFRAME_DELTA_REFUSALS else "gaussian-birth"
        assert entry["temporalModel"] == expected_model

    ordinary = pack_corpus.describe("BadMagic", "invalid", str(file_path), str(expectation_path))
    assert ordinary["indexed"]
    assert ordinary["requiredCapability"] is None
    assert ordinary["runnerArguments"] == []
    indexed_delta = pack_corpus.describe("WrongIndexLiveCount", "invalid", str(file_path), str(expectation_path))
    assert indexed_delta["indexed"] and indexed_delta["temporalModel"] == "keyframe-delta"

    identity_gaussian = pack_corpus.describe(
        "OptionalIdentityGaussianBirth-UseChunkIndex-UseCrc",
        "identity/gaussian-birth",
        str(file_path),
        str(expectation_path),
    )
    identity_delta = pack_corpus.describe(
        "OptionalIdentityKeyframeDelta-UseChunkIndex-UseCrc-UseStatistics",
        "identity/keyframe-delta",
        str(file_path),
        str(expectation_path),
    )
    assert identity_gaussian["temporalModel"] == "gaussian-birth"
    assert identity_delta["temporalModel"] == "keyframe-delta"
    assert identity_gaussian["requiredCapability"] == "optionalIdentityDefaults"
    assert identity_delta["requiredCapability"] == "optionalIdentityDefaults"

    chunk_window_entry = pack_corpus.describe(
        "WindowOverhang-UseChunkIndex-UseCrc",
        chunk_window.FAMILY,
        str(file_path),
        str(expectation_path),
    )
    assert chunk_window_entry["family"] == chunk_window.FAMILY
    assert chunk_window_entry["temporalModel"] == "gaussian-birth"
    assert chunk_window_entry["indexed"]
    assert chunk_window_entry["requiredCapability"] == chunk_window.CAPABILITY
    assert chunk_window_entry["runnerArguments"] == list(chunk_window.runner_arguments())


class TestExactAggregateTransition:
    @staticmethod
    def _summary():
        return {
            "aggregate": {
                "positionSum": [1.0, 2.0, 3.0],
                "opacitySum": 4.0,
                "neverFadesCount": "5",
                "zeroMotionCount": "6",
            },
            "camera": {"fovYDeg": 60.0},
            "objects": {"table": [{"objectId": "7"}]},
            "states": [
                {
                    "t": 7.0,
                    "liveCount": "8",
                    "aggregate": {
                        "positionSum": [9.0, 10.0, 11.0],
                        "opacitySum": 12.0,
                        "contributingCount": "9",
                    },
                    "sample": {"positions": [[13.0, 14.0, 15.0]]},
                }
            ],
        }

    def test_only_root_and_state_exact_totals_are_transitional(self):
        expected = self._summary()
        actual = self._summary()
        actual["aggregate"]["positionSum"] = [100.0, 200.0, 300.0]
        actual["aggregate"]["opacitySum"] = 400.0
        actual["states"][0]["aggregate"].update({"positionSum": [0.0, 0.0, 0.0], "opacitySum": 0.0})

        assert json_compare.without_exact_aggregates(actual) == json_compare.without_exact_aggregates(expected)
        assert actual["aggregate"]["positionSum"] == [100.0, 200.0, 300.0], "the helper must not mutate runner output"

    def test_dart_child_claims_only_its_proved_implementations(self):
        proved_families = frozenset({"dart", "python", "rust", "typescript"})
        assert conformance_run.EXACT_AGGREGATE_FAMILIES == proved_families
        assert conformance_run.CANONICAL_STATE_ORDER_FAMILIES == proved_families

    def test_only_exact_aggregate_tokens_use_lossless_decimal_equality(self):
        expected = json_compare.loads(
            '{"durationSec":9007199254740992.0,"aggregate":{"opacitySum":9007199254740992.0}}'
        )
        actual = json_compare.loads('{"durationSec":9007199254740993.0,"aggregate":{"opacitySum":9007199254740993.0}}')

        # The two duration spellings narrow to the same binary64 value, as ordinary
        # canonical fields always have. Exact aggregate units must retain the one-unit gap.
        assert json_compare.for_capabilities(
            actual, exact_aggregates=False, canonical_state_order=True
        ) == json_compare.for_capabilities(expected, exact_aggregates=False, canonical_state_order=True)
        assert json_compare.for_capabilities(
            actual, exact_aggregates=True, canonical_state_order=True
        ) != json_compare.for_capabilities(expected, exact_aggregates=True, canonical_state_order=True)

    def test_comparison_depth_is_a_runner_failure_not_a_harness_traceback(self):
        nested = None
        for _ in range(sys.getrecursionlimit()):
            nested = [nested]
        caps = conformance_run.Capabilities(
            family="outside",
            name="outside/decode_streamed",
            indexed=False,
            refusals=False,
        )

        compared, error = conformance_run.compared_documents(nested, {}, caps)

        assert compared is None
        assert isinstance(error, RecursionError)

    def test_filtered_failure_diagnostic_excludes_transitional_fields(self):
        expected = self._summary()
        actual = self._summary()
        actual["aggregate"]["opacitySum"] = 999.0
        actual["states"][0]["sample"] = {"positions": [[999.0]]}
        actual["states"][0]["liveCount"] = "99"

        expected_filtered = json_compare.for_capabilities(expected, exact_aggregates=False, canonical_state_order=False)
        actual_filtered = json_compare.for_capabilities(actual, exact_aggregates=False, canonical_state_order=False)
        text = "\n".join(json_compare.diagnostic_differences(expected_filtered, actual_filtered))

        assert "liveCount" in text and "99" in text
        assert "opacitySum" not in text
        assert '"sample"' not in text

    def test_diagnostic_is_bounded_for_deep_broad_documents(self):
        expected = {f"field-{index}": [0] for index in range(10_000)}
        actual = {key: list(value) for key, value in expected.items()}
        for index in range(50):
            actual[f"field-{index}"][0] = 1
        for _ in range(300):
            expected = [expected]
            actual = [actual]

        lines = json_compare.diagnostic_differences(expected, actual, max_lines=12, max_chars=1200)

        assert len(lines) <= 12
        assert sum(map(len, lines)) <= 1200
        assert lines

    def test_diagnostic_preserves_json_number_type(self):
        expected = json_compare.loads('{"aggregate":{"opacitySum":1.0}}')
        actual = json_compare.loads('{"aggregate":{"opacitySum":"1.0"}}')

        text = "\n".join(json_compare.diagnostic_differences(expected, actual))

        assert "json-number" in text
        assert "json-string" in text

    def test_unsupported_decimal_exponent_is_a_runner_document_failure(self):
        document, error = conformance_run.runner_document("1e9999999999999999999")

        assert document is None
        assert isinstance(error, InvalidOperation)

    def test_unclaimed_state_order_omits_only_the_state_sample(self):
        expected = self._summary()
        actual = self._summary()
        actual["states"][0]["sample"] = {"positions": [[99.0, 99.0, 99.0]]}

        assert json_compare.for_capabilities(
            actual, exact_aggregates=True, canonical_state_order=False
        ) == json_compare.for_capabilities(expected, exact_aggregates=True, canonical_state_order=False)
        assert json_compare.for_capabilities(
            actual, exact_aggregates=True, canonical_state_order=True
        ) != json_compare.for_capabilities(expected, exact_aggregates=True, canonical_state_order=True)

    @pytest.mark.parametrize(
        ("section", "key", "value"),
        [
            ("aggregate", "neverFadesCount", "99"),
            ("aggregate", "zeroMotionCount", "99"),
            ("camera", "fovYDeg", 75.0),
            ("objects", "table", []),
        ],
    )
    def test_every_unrelated_root_field_remains_strict(self, section, key, value):
        expected = self._summary()
        actual = self._summary()
        actual[section][key] = value
        assert json_compare.without_exact_aggregates(actual) != json_compare.without_exact_aggregates(expected)

    @pytest.mark.parametrize(
        ("path", "value"),
        [
            (("states", 0, "t"), 8.0),
            (("states", 0, "liveCount"), "99"),
            (("states", 0, "aggregate", "contributingCount"), "99"),
        ],
    )
    def test_unrelated_state_fields_remain_strict(self, path, value):
        expected = self._summary()
        actual = self._summary()
        target = actual
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        assert json_compare.for_capabilities(
            actual, exact_aggregates=False, canonical_state_order=False
        ) != json_compare.for_capabilities(expected, exact_aggregates=False, canonical_state_order=False)


class TestAggregateDecodedBudgetGate:
    @staticmethod
    def _capabilities(**extra):
        return {
            "protocol": 1,
            "name": "outside/decode_streamed",
            "family": "outside",
            "readPath": "streamed",
            **extra,
        }

    def test_capability_defaults_to_unclaimed(self, monkeypatch):
        monkeypatch.setattr(
            conformance_run,
            "invoke",
            lambda _command, _args, _timeout: conformance_run.Outcome(0, json.dumps(self._capabilities()), ""),
        )

        caps = conformance_run.declared_capabilities(["runner"], 1.0)

        assert not caps.aggregate_decoded_budget

    def test_capability_accepts_only_a_boolean(self, monkeypatch):
        def answer(value):
            monkeypatch.setattr(
                conformance_run,
                "invoke",
                lambda _command, _args, _timeout: conformance_run.Outcome(
                    0,
                    json.dumps(self._capabilities(aggregateDecodedBudget=value)),
                    "",
                ),
            )
            return conformance_run.declared_capabilities(["runner"], 1.0)

        assert answer(True).aggregate_decoded_budget
        with pytest.raises(conformance_run.ProtocolError, match=r"aggregateDecodedBudget.*true or false"):
            answer(1)

    def test_probe_injects_one_byte_into_the_existing_tiny_variant(self, monkeypatch):
        calls = []

        def invoke(command, args, timeout):
            calls.append((command, args, timeout))
            return conformance_run.Outcome(0, '{"unsupported":"resource-limit"}\n', "")

        monkeypatch.setattr(conformance_run, "invoke", invoke)

        assert conformance_run.aggregate_budget_problem(["runner"], 7.0) is None
        assert calls == [
            (
                ["runner"],
                [
                    "--max-decoded-state-bytes",
                    "1",
                    os.path.join(
                        conformance_run.DATA,
                        "OneGaussian-UseChunkIndex-UseCrc.4dgs",
                    ),
                ],
                7.0,
            )
        ]

    @pytest.mark.parametrize(
        ("outcome", "message"),
        [
            (conformance_run.Outcome(1, "", "too small"), "runner exited 1: too small"),
            (
                conformance_run.Outcome(0, '{"refused":"resource-limit"}', ""),
                "expected {'unsupported': 'resource-limit'}",
            ),
            (conformance_run.Outcome(0, "not json", ""), "stdout is not one JSON document"),
        ],
    )
    def test_probe_rejects_crash_refusal_and_non_json(self, monkeypatch, outcome, message):
        monkeypatch.setattr(conformance_run, "invoke", lambda _command, _args, _timeout: outcome)

        assert message in conformance_run.aggregate_budget_problem(["runner"], 1.0)

    def test_capability_claims_match_landed_language_layers(self):
        assert conformance_run.AGGREGATE_DECODED_BUDGET_FAMILIES == frozenset(
            {"cpp", "dart", "python", "rust", "typescript"}
        )


class TestTheHarnessCanSeeASignedZero:
    """`run.py`'s blind spot, and the only place in the suite that could see it.

    `generate.py --verify` compares committed expectations to a fresh Python decode as
    *text*, so a signed zero in a `.json` file is caught — that is
    `TestTheExpectationsAreChecked.test_a_signed_zero_fails_even_though_it_parses_equal`.
    `run.py` compares a runner's stdout to that expectation as *parsed values*, and
    `-0.0 == 0.0` holds for `float` and for `Decimal` alike. So a runner emitting
    `-0.000000` where the reference emits `0.0` passed, on the committed corpus, in three
    of the six SDKs at once — and the canonical form's first rule ("a zero is `0.0` and
    never `-0.0`") had no test that could fail.
    """

    @staticmethod
    def _document(zero: str) -> str:
        return (
            '{"cutoff":0.05,'
            f'"aggregate":{{"opacitySum":{zero},"positionSum":[{zero},0.0,0.0]}},'
            f'"states":[{{"sample":{{"positions":[[{zero},0.0,0.0]]}}}}]}}'
        )

    def _compare(self, zero: str, **caps):
        expected = json_compare.loads(self._document("0.0"))
        actual = json_compare.loads(self._document(zero))
        return (
            json_compare.for_capabilities(actual, **caps),
            json_compare.for_capabilities(expected, **caps),
        )

    @pytest.mark.parametrize("zero", ["-0.0", "-0.000000", "-0e-9"])
    def test_an_ordinary_signed_zero_is_not_an_unsigned_one(self, zero):
        actual, expected = self._compare(zero, exact_aggregates=False, canonical_state_order=True)
        assert actual != expected

    @pytest.mark.parametrize("zero", ["-0.0", "-0.000000"])
    def test_an_exact_aggregate_signed_zero_is_not_an_unsigned_one(self, zero):
        actual, expected = self._compare(zero, exact_aggregates=True, canonical_state_order=True)
        assert actual != expected

    def test_an_unsigned_zero_still_compares_equal_to_every_spelling_of_itself(self):
        for zero in ("0.0", "0.000000", "0e-9"):
            actual, expected = self._compare(zero, exact_aggregates=True, canonical_state_order=True)
            assert actual == expected, zero

    def test_the_diagnostic_names_the_sign_rather_than_two_identical_zeros(self):
        actual, expected = self._compare("-0.0", exact_aggregates=False, canonical_state_order=True)
        text = "\n".join(json_compare.diagnostic_differences(expected, actual))
        assert "-0.0" in text, text
        assert '["cutoff"]' not in text, text


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
    monkeypatch.setattr(generate, "IDENTITY", str(data / "identity"))
    monkeypatch.setattr(generate, "CHUNK_WINDOW", str(data / chunk_window.FAMILY))
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


class TestTheCanonicalFormHasNoDecodedOrder:
    @staticmethod
    def _gaussians(positions, motions) -> GaussianSet:
        positions = np.asarray(positions, dtype=np.float32)
        motions = np.asarray(motions, dtype=np.float32)
        count = positions.shape[0]
        return GaussianSet(
            positions=positions,
            scales=np.ones((count, 3), dtype=np.float32),
            rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (count, 1)),
            colors=np.ones((count, 4), dtype=np.float32),
            motions=motions,
            mu_t=np.zeros(count, dtype=np.float32),
            sigma_t=np.full(count, np.inf, dtype=np.float32),
            win_lo=np.zeros(count, dtype=np.float32),
            win_hi=np.full(count, 4_000_000.0, dtype=np.float32),
            object_id=np.zeros(count, dtype=np.uint32),
        )

    @staticmethod
    def _permuted(gaussians: GaussianSet, order) -> GaussianSet:
        order = np.asarray(order, dtype=np.intp)
        return GaussianSet(
            positions=gaussians.positions[order],
            scales=gaussians.scales[order],
            rotations=gaussians.rotations[order],
            colors=gaussians.colors[order],
            motions=gaussians.motions[order],
            mu_t=gaussians.mu_t[order],
            sigma_t=gaussians.sigma_t[order],
            win_lo=gaussians.win_lo[order],
            win_hi=gaussians.win_hi[order],
            object_id=gaussians.object_id[order],
        )

    @staticmethod
    def _summary(gaussians: GaussianSet) -> dict:
        header = Header(
            duration_sec=4_000_000.0,
            gaussian_count=gaussians.count,
            aabb=[0.0] * 6,
        )
        return canonical.summarize(header, gaussians, [], [])

    def test_rounded_key_ties_do_not_order_composed_state_samples(self):
        """Sub-micro motions tie in the emitted stored fields, but not after composition.

        Stable sorting therefore falls back to decoded order unless the content key keeps
        enough precision to distinguish them. Both rows fit inside the sample: reversing
        them proves the sample's sequence itself, rather than only its membership.
        """
        gaussians = self._gaussians(
            positions=[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
            motions=[[1e-7, 0.0, 0.0], [4e-7, 0.0, 0.0]],
        )

        forward = self._summary(gaussians)
        reversed_ = self._summary(self._permuted(gaussians, [1, 0]))

        assert forward == reversed_
        assert forward["states"][1]["sample"]["positions"] == [[0.2, 0.0, 0.0], [0.8, 0.0, 0.0]]

    def test_state_aggregates_sum_in_emitted_content_order(self):
        """The same four f32 values sum identically after a decoded-order change."""
        gaussians = self._gaussians(
            positions=[
                [332.6397705078125, 3.0, 0.0],
                [7.838928940049353e-21, 1.0, 0.0],
                [1577422159872.0, 4.0, 0.0],
                [9.658209299783168e-21, 2.0, 0.0],
            ],
            motions=np.zeros((4, 3), dtype=np.float32),
        )

        cancellation_first = self._summary(gaussians)
        cancellation_last = self._summary(self._permuted(gaussians, [0, 3, 1, 2]))

        assert cancellation_first == cancellation_last
        assert [value.token for value in cancellation_first["states"][0]["aggregate"]["positionSum"]] == [
            "1577422160204.639771",
            "10.0",
            "0.0",
        ]

    def test_aggregate_addends_are_exact_canonical_units(self):
        values = [1e20, -1e20, 3.25]
        forward = canonical._exact_sum(values)
        reversed_ = canonical._exact_sum(list(reversed(values)))

        assert forward == reversed_
        assert forward.token == "3.25"
        assert canonical._exact_sum([1.0, float("inf")]) is None


def test_exact_number_tokens_and_comparisons_never_narrow_through_binary64():
    total = canonical._exact_sum([1e308] * 10)
    text = canonical.canonical({"total": total})
    parsed = json_compare.loads(text)
    nearby = json_compare.loads(text.replace(".0", ".1", 1))

    assert len(total.token.split(".")[0]) == 310
    assert parsed != nearby
    message = encode_roundtrip._diff({"total": (parsed["total"], nearby["total"])})
    assert "total" in message
    assert "json-number" in message and "adjusted=309" in message
    assert len(message) <= 8000


def test_fixture_witness_compares_float_and_exact_number_in_one_decimal_domain():
    assert generate._same_canonical_decimal(3.25, canonical.ExactNumber("3.250000"))
    assert not generate._same_canonical_decimal(3.25, canonical.ExactNumber("3.250001"))


def test_adversarial_order_cases_are_encoded_corpus_variants():
    variants = {name: expectation for name, _data, expectation in generate.build_object_corpus()}
    tied = "ObjectTiedGaussians-UseChunkIndex-UseCrc"
    reordered = "ObjectTiedGaussiansReordered-UseChunkIndex-UseCrc"
    content_sum = "ObjectContentOrderSum-UseChunkIndex-UseCrc"

    assert variants[tied] == variants[reordered]
    tied_summary = json.loads(variants[tied])
    assert tied_summary["states"][1]["sample"]["positions"] == [
        [-1e-6, 0.0, 0.0],
        [0.0, 0.0, 0.0],
    ]
    content_summary = json.loads(variants[content_sum])
    assert content_summary["states"][1]["sample"]["objectIds"] == ["1", "2", "3"]
    assert content_summary["states"][1]["aggregate"]["positionSum"] == [3.25, 0.0, 0.0]
    opacity_summary = json.loads(variants["ObjectOpacityOrder-UseChunkIndex-UseCrc"])
    assert opacity_summary["states"][1]["aggregate"]["opacitySum"] == 57.071301

    wide_summary = json_compare.loads(variants["ObjectWideUnitAggregate-UseChunkIndex-UseCrc"])
    expected = json_compare.loads("5784799892854990616798971119236787732480.0")
    assert wide_summary["aggregate"]["positionSum"][0] == expected
    assert all(state["aggregate"]["positionSum"][0] == expected for state in wide_summary["states"])
    assert int(expected * 10**canonical.FLOAT_DECIMALS) > 2**127 - 1
    assert len(wide_summary["sample"]["positions"]) == canonical.SAMPLE
    assert all(position == [0, 0, 0] for position in wide_summary["sample"]["positions"])
    assert all(state["liveCount"] == str(2 * canonical.SAMPLE + 1) for state in wide_summary["states"])
    assert all(
        all(position == [0, 0, 0] for position in state["sample"]["positions"]) for state in wide_summary["states"]
    )

    nonfinite = "ObjectTiedNonFiniteRows-UseChunkIndex-UseCrc"
    nonfinite_reordered = "ObjectTiedNonFiniteRowsReordered-UseChunkIndex-UseCrc"
    assert variants[nonfinite] == variants[nonfinite_reordered]
    nonfinite_summary = json_compare.loads(variants[nonfinite])
    assert nonfinite_summary["states"][2]["sample"]["positions"][0][0].is_finite()
    assert nonfinite_summary["states"][2]["sample"]["positions"][1][0] is None


def test_keyframe_delta_variants_retain_an_untouched_common_row():
    for name, data, _ in generate.build_keyframe_delta_corpus():
        if name.startswith("KeyframeOnly"):
            continue
        # `KeyframeDeltaMultiWindow` drifts every row's position and rotation at every
        # step, by construction: it exists to prove the validity-window gate on a
        # population where nothing but the window can remove a gaussian from a probe, so
        # it has no untouched row to keep and cannot carry this claim. The claim is about
        # the corpus rather than about each variant, and the three variants above still
        # make it — a decoder that drops untouched identities still fails here.
        if name.startswith("KeyframeDeltaMultiWindow"):
            continue
        decoded = kdf.decode_streamed(data)
        deltas = [chunk for chunk in decoded.chunks if chunk.kind == 1]
        assert deltas, name
        assert any(chunk.update_count < len(chunk.state.ids) - chunk.birth_count for chunk in deltas), (
            f"{name} restates every common row"
        )


class TestEncodeAabbGeometryGate:
    def test_a_nan_bound_cannot_bypass_ordered_comparisons(self):
        with pytest.raises(AssertionError, match="non-finite bound"):
            encode_roundtrip._check_declared_aabb(
                "Header",
                [float("nan"), 0.0, 0.0, 1.0, 1.0, 1.0],
                [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
            )

    def test_an_inverted_bound_is_named_before_containment(self):
        with pytest.raises(AssertionError, match="inverted on axis 0"):
            encode_roundtrip._check_declared_aabb(
                "Statistics",
                [2.0, 0.0, 0.0, 1.0, 1.0, 1.0],
                [2.0, 0.0, 0.0, 1.0, 1.0, 1.0],
            )

    def test_a_loose_bound_does_not_count_as_reconstructed_geometry(self):
        with pytest.raises(AssertionError, match="does not equal reconstructed axis 0"):
            encode_roundtrip._check_declared_aabb(
                "Header",
                [-1.0, 0.0, 0.0, 2.0, 1.0, 1.0],
                [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
            )

    def test_the_empty_scene_aabb_is_the_zero_box(self):
        encode_roundtrip._check_declared_aabb("Header", [0.0] * 6, [0.0] * 6)


class TestEncodeSummaryOffsetGeometryGate:
    @staticmethod
    def _candidate(tmp_path, summary_opcodes, *, pointer=None):
        def record(number, content=b""):
            return encode_roundtrip.RECORD_HEADER.pack(number, len(content)) + content

        data = bytearray(encode_roundtrip.MAGIC)
        summary_start = len(data)
        offsets = []
        for number in summary_opcodes:
            offsets.append(len(data))
            data.extend(record(number))
        if pointer is None:
            pointer = next(
                (
                    at
                    for at, number in zip(offsets, summary_opcodes, strict=True)
                    if number == encode_roundtrip.opcode.SUMMARY_OFFSET
                ),
                0,
            )
        data.extend(
            record(
                encode_roundtrip.opcode.FOOTER,
                struct.pack("<QQI", summary_start, pointer, 0),
            )
        )
        data.extend(encode_roundtrip.MAGIC)
        path = tmp_path / "candidate.4dgs"
        path.write_bytes(data)
        return path, summary_start, offsets

    @staticmethod
    def _declared_index(start):
        return SimpleNamespace(
            group_opcode=encode_roundtrip.opcode.CHUNK_INDEX,
            group_start=start,
            group_length=encode_roundtrip.RECORD_HEADER.size,
        )

    def test_footer_points_at_the_first_summary_offset(self, tmp_path):
        path, summary_start, _ = self._candidate(
            tmp_path,
            [encode_roundtrip.opcode.CHUNK_INDEX, encode_roundtrip.opcode.SUMMARY_OFFSET],
            pointer=0,
        )
        with encode_roundtrip.FileReadable(str(path)) as source:
            with pytest.raises(AssertionError, match="summary_offset_start"):
                encode_roundtrip._check_summary_offset_geometry(
                    source,
                    [self._declared_index(summary_start)],
                    require_chunk_index=True,
                )

    def test_non_summary_records_are_rejected_from_the_summary_run(self, tmp_path):
        path, summary_start, _ = self._candidate(
            tmp_path,
            [encode_roundtrip.opcode.CHUNK_INDEX, 0x7D, encode_roundtrip.opcode.SUMMARY_OFFSET],
        )
        with encode_roundtrip.FileReadable(str(path)) as source:
            with pytest.raises(AssertionError, match="expected only Chunk Index"):
                encode_roundtrip._check_summary_offset_geometry(
                    source,
                    [self._declared_index(summary_start)],
                    require_chunk_index=True,
                )

    def test_an_index_requires_its_summary_offset_declaration(self, tmp_path):
        path, _, _ = self._candidate(tmp_path, [encode_roundtrip.opcode.CHUNK_INDEX])
        with encode_roundtrip.FileReadable(str(path)) as source:
            with pytest.raises(AssertionError, match="exactly one Chunk Index Summary Offset"):
                encode_roundtrip._check_summary_offset_geometry(
                    source,
                    [],
                    require_chunk_index=True,
                )

    def test_a_complete_summary_geometry_is_accepted(self, tmp_path):
        path, summary_start, _ = self._candidate(
            tmp_path,
            [encode_roundtrip.opcode.CHUNK_INDEX, encode_roundtrip.opcode.SUMMARY_OFFSET],
        )
        with encode_roundtrip.FileReadable(str(path)) as source:
            encode_roundtrip._check_summary_offset_geometry(
                source,
                [self._declared_index(summary_start)],
                require_chunk_index=True,
            )
