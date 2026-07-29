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


def minimal_file(*, header: rec.Header | None = None, extra: bytes = b"", footer: bytes | None = None) -> bytes:
    """The smallest thing that is meant to validate: header, grids, windows, footer."""
    head = header or rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6)
    quant = rec.Quantization(
        scheme="uniform-v1",
        pos_origin=[0.0, 0.0, 0.0],
        step_pos=1e-4,
        step_scale_log=0.04,
        step_rot=0.004,
        step_rgb=0.008,
        step_alpha=0.008,
        step_motion=2e-4,
        step_time=0.004,
        step_sigma_log=0.04,
        step_sh=1,
    )
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

    def test_the_audio_flag_and_the_audio_record_must_agree(self):
        # Flag set, no record.
        header = rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6, flags=rec.FLAG_HAS_AUDIO)
        report = validate(minimal_file(header=header))
        assert any("no Audio record" in m for m in errors(report))

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
