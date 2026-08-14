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
import struct
import sys
from decimal import InvalidOperation
from types import SimpleNamespace

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import canonical
import encode_roundtrip
import generate
import json_compare
import run as conformance_run

# `generate` puts `python/fourdgs` on the path as it imports, which is why this follows it.
from fourdgs import keyframe_delta_file as kdf
from fourdgs.model import GaussianSet
from fourdgs.records import Header

#: The expectation the signed zero was found in (#153): two composed values at the noise
#: floor, which round to `-0.0` where the arithmetic lands a hair below zero.
COMPOSED = "object/ObjectTrackComposed-UseChunkIndex-UseCrc"


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

    def test_transition_claims_no_implementation_before_its_child(self):
        assert conformance_run.EXACT_AGGREGATE_FAMILIES == frozenset()
        assert conformance_run.CANONICAL_STATE_ORDER_FAMILIES == frozenset()

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
