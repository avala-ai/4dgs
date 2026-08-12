# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Tests for structural validation.

`validate` is what a third-party encoder author debugs against, so what matters is not
only that it passes a good file but that it says the right thing about a bad one. Every
broken file here is built byte by byte: a validator tested only against files its own
encoder wrote is a validator tested against nothing.
"""

from __future__ import annotations

import io

import fourdgs
import numpy as np
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.serialization import MAGIC, put_record
from fourdgs.validate import validate

RNG = np.random.default_rng(20260728)


def grids(**overrides) -> rec.Quantization:
    """A well-formed Quantization record, with any field replaceable."""
    fields = {
        "scheme": "uniform-v1",
        "pos_origin": [0.0, 0.0, 0.0],
        "step_pos": 1e-4,
        "step_scale_log": 0.04,
        "step_rot": 0.004,
        "step_rgb": 0.008,
        "step_alpha": 0.008,
        "step_motion": 2e-4,
        "step_time": 0.004,
        "step_sigma_log": 0.04,
        "step_sh": 1,
    }
    fields.update(overrides)
    return rec.Quantization(**fields)


def minimal_file(
    *,
    header: rec.Header | None = None,
    quant: rec.Quantization | None = None,
    extra: bytes = b"",
    footer: bytes | None = None,
) -> bytes:
    """The smallest thing that is meant to validate: header, grids, windows, footer."""
    head = header or rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6)
    quant = quant or grids()
    body = head.encode() + quant.encode() + rec.WindowTable(windows=[(0.0, 1.0)]).encode() + extra
    return MAGIC + body + (footer if footer is not None else rec.Footer().encode()) + MAGIC


def real_file(**options) -> bytes:
    n = 64
    scene = fourdgs.GaussianSet(
        positions=RNG.normal(0, 0.5, (n, 3)).astype(np.float32),
        scales=np.exp(RNG.normal(-7, 0.5, (n, 3))).astype(np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=RNG.uniform(0, 1, (n, 4)).astype(np.float32),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=RNG.uniform(0, 1, n).astype(np.float32),
        sigma_t=np.full(n, 0.1, dtype=np.float32),
        win_lo=np.zeros(n, dtype=np.float32),
        win_hi=np.ones(n, dtype=np.float32),
    )
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 1.0, options=fourdgs.WriteOptions(**options))
    return buf.getvalue()


def errors(report) -> list[str]:
    return [f.message for f in report.findings if f.severity == "error"]


class TestGoodFiles:
    def test_a_file_this_encoder_wrote_validates_clean(self):
        report = validate(real_file())
        assert report.ok, errors(report)
        assert errors(report) == []

    def test_a_minimal_handmade_file_validates_clean(self):
        report = validate(minimal_file())
        assert report.ok, errors(report)

    def test_defined_object_records_are_parsed_not_reported_as_reserved(self):
        table = rec.ObjectTable(entries=[rec.ObjectTableEntry(object_id=7)]).encode()
        track = rec.ObjectTrack(
            object_id=7,
            times=[0.0],
            rotations=[[0.0, 0.0, 0.0, 1.0]],
            translations=[[0.0, 0.0, 0.0]],
        ).encode()
        report = validate(minimal_file(extra=table + track))
        assert report.ok, errors(report)
        notes = [finding.message for finding in report.findings if finding.severity == "note"]
        assert not any("reserved provenance record 0x24" in message for message in notes)
        assert not any("reserved provenance record 0x25" in message for message in notes)

    def test_notes_and_warnings_do_not_make_a_file_invalid(self):
        # No index: readable front to back, not seekable. A warning, not an error.
        report = validate(real_file(write_index=False))
        assert report.ok, errors(report)
        assert any(f.severity == "warning" for f in report.findings)


class TestRefusals:
    def test_not_a_4dgs_file(self):
        report = validate(b"ply\nformat binary_little_endian 1.0\n" + b"\x00" * 64)
        assert not report.ok
        assert "not a 4dgs file" in errors(report)[0]

    def test_a_future_major_version_is_named_as_such(self):
        future = bytearray(minimal_file())
        future[5] = ord("9")
        report = validate(bytes(future))
        assert not report.ok
        assert "version" in errors(report)[0]

    def test_a_missing_trailing_magic_is_reported(self):
        report = validate(minimal_file()[:-1])
        assert not report.ok
        assert any("does not end with the magic" in m for m in errors(report))

    def test_a_header_that_miscounts_its_gaussians(self):
        header = rec.Header(duration_sec=1.0, gaussian_count=5, aabb=[0.0] * 6)
        report = validate(minimal_file(header=header))
        assert not report.ok
        assert any("declares 5 gaussians; chunks contain 0" in m for m in errors(report))

    def test_duplicate_object_tracks_are_rejected_across_records(self):
        track = rec.ObjectTrack(
            object_id=7,
            times=[0.0],
            rotations=[[0.0, 0.0, 0.0, 1.0]],
            translations=[[0.0, 0.0, 0.0]],
        ).encode()
        report = validate(minimal_file(extra=track + track))
        assert not report.ok
        assert any("two ObjectTrack records move object 7" in message for message in errors(report))

    def test_malformed_object_tracks_are_rejected_by_the_validator(self):
        track = bytearray(
            rec.ObjectTrack(
                object_id=7,
                times=[0.0],
                rotations=[[0.0, 0.0, 0.0, 1.0]],
                translations=[[0.0, 0.0, 0.0]],
            ).encode()
        )
        track[9 + 4] = 2
        report = validate(minimal_file(extra=bytes(track)))
        assert not report.ok
        assert any("interpolation 2" in message for message in errors(report))

    def test_the_audio_flag_and_the_audio_record_must_agree(self):
        # Flag set, no record.
        header = rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6, flags=rec.FLAG_HAS_AUDIO)
        report = validate(minimal_file(header=header))
        assert any("no Audio Source or legacy Audio record" in m for m in errors(report))

        # Record present, flag clear. Absence is the signal, so its opposite is an error.
        audio = rec.Audio(codec="wav", data=b"RIFF....").encode()
        report = validate(minimal_file(extra=audio))
        assert any("audio flag is clear" in m for m in errors(report))

    def test_a_header_that_is_not_first(self):
        # A private record before the Header. The Header MUST come first.
        data = minimal_file()
        moved = MAGIC + put_record(0x91, b"too early") + data[len(MAGIC) :]
        report = validate(moved)
        assert not report.ok
        assert any("must come first" in m for m in errors(report))

    def test_a_summary_crc_that_does_not_match(self):
        data = bytearray(real_file(write_crc=True))
        footer = rec.Footer.parse(data[-(20 + len(MAGIC)) : -len(MAGIC)])
        assert footer.summary_crc != 0, "this variant is supposed to carry a CRC"
        # Corrupt a byte inside the first index record's *content*. Flipping one in a
        # record header would break framing, and the walk would fail before the CRC
        # was ever compared — a different bug with a different message.
        data[footer.summary_start + 9 + 4] ^= 0xFF
        report = validate(bytes(data))
        assert any("summary CRC mismatch" in m for m in errors(report))

    def test_a_chunk_index_entry_that_points_at_the_wrong_place(self):
        data = bytearray(real_file())
        footer = rec.Footer.parse(data[-(20 + len(MAGIC)) : -len(MAGIC)])
        # The first index record's chunk_offset field: past the record header, past t0/t1.
        at = footer.summary_start + 9 + 16
        data[at : at + 8] = (len(data) - 4).to_bytes(8, "little")
        report = validate(bytes(data))
        assert not report.ok
        assert any("chunk index entry 0" in m for m in errors(report))

    def test_a_footer_naming_no_summary_still_checks_the_index_entries(self):
        """`summary_start` 0 is §5.2's indexless file, so it selects no summary.

        Reading "selects nothing" as "nothing is valid" was wrong twice over. It reported
        every Chunk Index record in the file as lying outside the selection — one line per
        record, thousands of them on a real capture, and not one of them the actual fault.
        And it emptied the entry list, so every per-entry check below silently stopped
        running on records still sitting there to be read: the entry corrupted here, whose
        range runs off the end of the file, went unreported.
        """
        data = bytearray(real_file())
        summary_start = rec.Footer.parse(bytes(data[-(20 + len(MAGIC)) : -len(MAGIC)])).summary_start
        # The first index record's chunk_offset field: past the record header, past t0/t1.
        at = summary_start + 9 + 16
        data[at : at + 8] = (len(data) - 4).to_bytes(8, "little")
        # Now say the file carries no summary, without moving a single record.
        data[-(20 + len(MAGIC)) : -(len(MAGIC) + 12)] = (0).to_bytes(8, "little")

        report = validate(bytes(data))

        assert not any("lies outside the Footer-selected summary index" in m for m in errors(report))
        assert any("chunk index entry 0" in m for m in errors(report))

    def test_a_keyframe_delta_file_naming_no_summary_is_still_decoded(self):
        """Keeping the index records must not send the file down the seeking branch.

        `_check_keyframe_delta` opens the file with `open_indexed` when it is told the
        file is indexed, and that needs the Footer to name a summary. Passing it
        `bool(index)` meant a `summary_start` of 0 — §5.2's indexless file, which may
        still carry Chunk Index records nothing can reach — was answered with one
        "a seeking reader cannot open this file" and no chunk decoded at all. The
        streamed branch reads it, and that is the branch it belongs on.
        """
        import pathlib

        corpus = pathlib.Path(__file__).resolve().parents[3] / "tests/conformance/data/keyframe"
        source = corpus / "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs"
        if not source.exists():
            import pytest

            pytest.skip("the generated corpus is not present")
        data = bytearray(source.read_bytes())
        data[-(20 + len(MAGIC)) : -(len(MAGIC) + 12)] = (0).to_bytes(8, "little")
        data[-(len(MAGIC) + 4) : -len(MAGIC)] = (0).to_bytes(4, "little")

        report = validate(bytes(data))

        assert not any("a seeking reader cannot open this file" in m for m in errors(report))

    def test_a_non_finite_quantization_step_is_an_error(self):
        # Spec §5.3: every step and origin must be finite. This is the corrupt field that
        # ruins every gaussian rather than one — each bin times an infinite step decodes to
        # infinity — and it is silent, because arithmetic on infinity is perfectly defined.
        for name, value in (
            ("step_pos", float("inf")),
            ("step_motion", float("-inf")),
            ("step_time", float("nan")),
            ("step_sigma_log", float("inf")),
        ):
            report = validate(minimal_file(quant=grids(**{name: value})))
            assert not report.ok, f"{name}={value} should be refused"
            assert any(f"Quantization {name} is" in m and "must be finite" in m for m in errors(report)), errors(report)

    def test_a_non_finite_position_origin_is_an_error(self):
        # The origin is added after the step multiply, so an infinite one is just as fatal
        # and just as quiet as an infinite step.
        report = validate(minimal_file(quant=grids(pos_origin=[0.0, float("inf"), 0.0])))
        assert not report.ok
        assert any("Quantization pos_origin[1] is" in m for m in errors(report))

    def test_every_quantization_parameter_is_covered(self):
        # A field added to the record and forgotten here would be a hole nothing reports.
        # Setting each in turn to infinity must produce an error naming that field.
        numeric = [f"pos_origin[{i}]" for i in range(3)] + [
            "step_pos",
            "step_scale_log",
            "step_rot",
            "step_rgb",
            "step_alpha",
            "step_motion",
            "step_time",
            "step_sigma_log",
        ]
        for name in numeric:
            if name.startswith("pos_origin"):
                origin = [0.0, 0.0, 0.0]
                origin[int(name[-2])] = float("inf")
                quant = grids(pos_origin=origin)
            else:
                quant = grids(**{name: float("inf")})
            report = validate(minimal_file(quant=quant))
            assert any(f"Quantization {name} is" in m for m in errors(report)), f"{name} is not checked"

    def test_a_bad_quantization_record_followed_by_a_good_one_is_still_refused(self):
        # Nothing in the framing forbids a second Quantization record. A validator that
        # inspected only the one left in hand after the walk would pass this file, while a
        # streamed decoder — which takes the first grid it meets — decodes the whole scene
        # through the broken one. Each record is checked as it is met, so this is an error.
        good = grids()
        bad = grids(step_pos=float("inf"))
        body = bad.encode() + good.encode()
        data = MAGIC + rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6).encode()
        data += body + rec.WindowTable(windows=[(0.0, 1.0)]).encode() + rec.Footer().encode() + MAGIC
        report = validate(data)
        assert not report.ok, "the first, non-finite grid must not be masked by the second"
        assert any("step_pos is inf" in m for m in errors(report)), errors(report)

    def test_the_offending_quantization_record_is_named_when_there_is_more_than_one(self):
        # The reverse order: the good grid first, the broken one second. The report has to
        # say which copy, or the reader is left looking at a record that is fine.
        data = MAGIC + rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6).encode()
        data += grids().encode() + grids(step_time=float("nan")).encode()
        data += rec.WindowTable(windows=[(0.0, 1.0)]).encode() + rec.Footer().encode() + MAGIC
        report = validate(data)
        assert not report.ok
        assert any("Quantization record 2 step_time" in m for m in errors(report)), errors(report)

    def test_a_file_with_no_records_at_all(self):
        report = validate(MAGIC)
        assert not report.ok
        assert any("no records at all" in m for m in errors(report))


class TestNotes:
    def test_unknown_and_private_records_are_noted_not_refused(self):
        extra = put_record(0x91, b"private application record") + put_record(0x7D, b"unknown future record")
        report = validate(minimal_file(extra=extra))
        assert report.ok, errors(report)
        notes = [f.message for f in report.findings if f.severity == "note"]
        assert any("private record 0x91" in m for m in notes)
        assert any("unknown record 0x7D" in m for m in notes)

    def test_a_seeking_reader_is_asked_to_open_the_file_too(self):
        # A footer pointing at a summary that is not there: front-to-back reading is
        # unaffected, but a seeking client cannot use this file, and validate says so.
        broken = minimal_file(footer=rec.Footer(summary_start=10**9, summary_crc=1).encode())
        report = validate(broken)
        assert not report.ok
        assert any("seeking reader cannot open" in m for m in errors(report))


class TestReport:
    def test_ok_is_about_errors_only(self):
        report = validate(minimal_file(extra=put_record(0x91, b"x")))
        assert report.findings, "this file should produce a note"
        assert report.ok

    def test_findings_stringify_with_their_severity(self):
        report = validate(b"not a 4dgs file at all")
        assert str(report.findings[0]).startswith("error: ")

    def test_every_defined_opcode_has_a_name(self):
        for opcode, name in op.NAMES.items():
            assert name and op.name(opcode) == name
