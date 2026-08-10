# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""What the validator says about a file it refuses: which rule, and which byte.

Every expectation here is **read out of the conformance corpus** rather than restated.
A test that hardcodes the answers drifts from the corpus the moment a variant is added or
an identifier changes, and it drifts silently — the test keeps passing while the thing it
was written to protect stops being true. A test that reads them cannot: a new invalid
variant arrives already asserted, and one whose declared identifier changes fails here
until the validator agrees with it again.

The corpus binaries are generated rather than committed (`tests/conformance/generate.py`),
so a local run without them skips rather than failing. CI generates them before this
suite, which is why the skip is refused there: a comparison that silently did not happen
is worse than one that failed.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path

import fourdgs
import numpy as np
import pytest
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs import refusal
from fourdgs.cli import main
from fourdgs.serialization import MAGIC, put_record
from fourdgs.validate import validate

CORPUS = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "data"

RNG = np.random.default_rng(20260810)


def _variants(directory: Path) -> list[Path]:
    return sorted(directory.glob("*.4dgs")) if directory.is_dir() else []


def _require_corpus(paths: list[Path], what: str) -> None:
    if paths:
        return
    if os.environ.get("CI"):
        raise AssertionError(f"CI generates the corpus before this suite, so no {what} is a test that did not run")
    pytest.skip(f"no {what} in {CORPUS}; run tests/conformance/generate.py")


def _declared_refusal(path: Path) -> str:
    """The identifier the corpus itself declares for this file."""
    return json.loads(path.with_suffix(".json").read_text())["refused"]


def _invalid_corpus() -> list[tuple[str, Path, str]]:
    return [(p.stem, p, _declared_refusal(p)) for p in _variants(CORPUS / "invalid")]


def _cli(capsys, *argv: str) -> tuple[int, str]:
    code = main(list(argv))
    captured = capsys.readouterr()
    return code, captured.out + captured.err


class TestTheInvalidCorpus:
    def test_every_invalid_variant_is_refused_by_its_own_identifier(self, capsys):
        """The strongest evidence there is that this validator is right.

        The corpus already knows the answer and this tool had no hand in writing it.
        "Refused" alone is not the property: a validator that refuses every one of these
        for the wrong reason passes a test that only checks the exit code, and that is
        precisely the failure the invalid corpus was built to catch.
        """
        corpus = _invalid_corpus()
        _require_corpus([path for _, path, _ in corpus], "invalid corpus")
        for name, path, code in corpus:
            status, text = _cli(capsys, "validate", str(path))
            assert status == 1, f"{name} must be refused, and non-zero is how a pipeline learns it: {text}"
            # And the byte, which is the question its holder actually has. Every one of
            # these is placeable: four in the front matter, two inside a chunk that is
            # only reached by decoding it.
            assert f"refusal {code} at byte " in text, f"{name} must be refused as `{code}` at a byte; it said: {text}"

    def test_the_refusal_is_reported_beneath_the_finding_it_belongs_to(self, capsys):
        """The finding line is contract; the identifier is an addition beneath it.

        Both validators are compared by filtering their output on `error:`, `warning:` and
        `note:`, so the identifier must not arrive on a line that filter would take. It
        goes on its own indented line instead, which changes nothing about the comparison.
        """
        corpus = _invalid_corpus()
        _require_corpus([path for _, path, _ in corpus], "invalid corpus")
        for name, path, code in corpus:
            _, text = _cli(capsys, "validate", str(path))
            lines = text.splitlines()
            at = next(i for i, line in enumerate(lines) if line.startswith(f"  refusal {code}"))
            assert lines[at - 1].startswith("error: "), f"{name}: the identifier must sit beneath its finding"
            for line in lines:
                if line.lstrip().startswith("refusal "):
                    assert line.startswith("  "), f"{name}: {line!r} would be taken for a finding"

    def test_the_two_refusals_inside_a_chunk_are_reached_at_all(self, capsys):
        """The gap this whole change exists to close.

        A framing walk steps *over* a chunk by its declared length, so these two were
        reported `valid`, exit 0 — in the two cases where a decoder was right and the byte
        is hardest to find by hand. Named here rather than left to the sweep above,
        because a corpus that stopped carrying them would make that sweep pass by
        checking less.
        """
        inside_a_chunk = {"unknown-stream-codec", "window-index-out-of-range"}
        corpus = [entry for entry in _invalid_corpus() if entry[2] in inside_a_chunk]
        _require_corpus([path for _, path, _ in corpus], "chunk-interior invalid variants")
        assert len(corpus) == len(inside_a_chunk), "both chunk-interior variants must be present"
        for name, path, code in corpus:
            status, text = _cli(capsys, "validate", str(path))
            assert status == 1, f"{name}: {text}"
            assert "a chunk does not decode: " in text, f"{name}: {text}"
            assert f"refusal {code} at byte " in text, f"{name}: {text}"
            assert "the Chunk record at index entry " in text, f"{name}: the byte must name which chunk"

    def test_the_byte_a_refusal_names_is_where_that_record_starts(self):
        """An offset that points at the wrong record is worse than no offset.

        So each one is checked against the file itself: the byte the report names has to
        be the first byte of a record of the kind the report says sits there.
        """
        expected_opcode = {
            "unknown-temporal-model": op.HEADER,
            "unknown-quantization-scheme": op.QUANTIZATION,
            "unknown-stream-codec": op.CHUNK,
            "window-index-out-of-range": op.CHUNK,
        }
        corpus = _invalid_corpus()
        _require_corpus([path for _, path, _ in corpus], "invalid corpus")
        checked = 0
        for name, path, code in corpus:
            data = path.read_bytes()
            named = next(
                (f.refusal for f in validate(data).findings if f.refusal is not None and f.refusal.code == code),
                None,
            )
            assert named is not None, f"{name}: no finding carried the declared identifier"
            assert named.site is not None, f"{name}: the refusal was named but not placed"
            if code in expected_opcode:
                assert data[named.site.offset] == expected_opcode[code], (
                    f"{name}: byte {named.site.offset} is not the {op.name(expected_opcode[code])} record"
                )
                checked += 1
            else:
                assert named.site.offset == 0, f"{name}: a magic refusal is about byte 0"
        assert checked >= 4, "the record-placed refusals must actually have been checked"


class TestKeyframeDelta:
    def test_a_conforming_keyframe_delta_file_is_valid(self, capsys):
        """It was not: every structural check assumed the gaussian-birth chunk shape.

        A file whose Chunks are keyframes and whose Delta Chunks are differences against
        them came back with seven errors and an `INVALID`, for a temporal model this
        library implements and the conformance suite proves it implements. Refusing a file
        for declaring it was never a statement about the file.
        """
        paths = _variants(CORPUS / "keyframe")
        _require_corpus(paths, "keyframe-delta corpus")
        for path in paths:
            status, text = _cli(capsys, "validate", str(path))
            assert status == 0, f"{path.name} declares a model this library implements: {text}"
            assert "error: " not in text, f"{path.name}: {text}"

    def test_the_model_is_taken_from_the_header_not_guessed_from_the_records(self):
        """A file that carries Delta Chunks and does not say so is itself a fault.

        So the branch is on the Header's declared model. Checked by giving a
        gaussian-birth file a Delta Chunk: the index check must not start accepting it.
        """
        paths = _variants(CORPUS / "keyframe")
        _require_corpus(paths, "keyframe-delta corpus")
        data = paths[0].read_bytes()
        assert b"keyframe-delta" in data
        birth = data.replace(b"keyframe-delta", b"gaussian-birth", 1)
        report = validate(birth)
        assert not report.ok, "a keyframe-delta file relabelled gaussian-birth is not a valid file"


class TestProvenanceRecords:
    def test_the_defined_provenance_family_is_parsed_not_reported_as_unknown(self):
        """`0x20`-`0x25` are assigned records, and four of them ride on every capture.

        Reporting them as unknown or reserved puts a note on every conforming
        photogrammetry file that says the validator does not know what its own
        specification defines.
        """
        prov = (
            rec.CoordinateFrame(name="world", handedness=1, up_axis=3, forward_axis=2).encode()
            + rec.SensorCalibration(
                name="cam", rotation=[0.0, 0.0, 0.0, 1.0], translation=[0.0] * 3, camera_model=0
            ).encode()
            + rec.RigTrajectory(
                name="rig", times=[0.0], rotations=[[0.0, 0.0, 0.0, 1.0]], translations=[[0.0] * 3]
            ).encode()
            + rec.GeodeticAnchor(frame_name="world", latitude_deg=37.77, longitude_deg=-122.41).encode()
            + rec.ObjectTable(entries=[rec.ObjectTableEntry(object_id=7)]).encode()
            + rec.ObjectTrack(
                object_id=7, times=[0.0], rotations=[[0.0, 0.0, 0.0, 1.0]], translations=[[0.0] * 3]
            ).encode()
        )
        report = validate(_minimal(extra=prov))
        notes = [f.message for f in report.findings if f.severity == "note"]
        for opcode in range(op.PROVENANCE_START, op.OBJECT_TRACK + 1):
            assert not any(f"0x{opcode:02X}" in note for note in notes), f"0x{opcode:02X} is a defined record: {notes}"

    def test_a_still_reserved_provenance_opcode_is_noted_with_the_range_it_is_in(self):
        """The forward-compatibility rule, and the range it actually covers.

        `0x24` and `0x25` were assigned to the object layer, so a note naming
        `0x24`-`0x2F` as reserved tells its reader that two records this library parses
        are ones it skipped.
        """
        report = validate(_minimal(extra=put_record(0x26, b"a record from a later revision")))
        notes = [f.message for f in report.findings if f.severity == "note"]
        assert any("reserved provenance record 0x26" in note for note in notes), notes
        assert any("0x26-0x2F" in note for note in notes), notes


class TestTruncation:
    def test_a_cut_file_says_how_much_of_it_survived(self, capsys, tmp_path):
        """A file that "stopped reading" leaves its holder guessing what is salvageable.

        Records are length-prefixed, so everything complete before the cut is intact and a
        streamed reader keeps it. The note says how much, and names the record the file
        was cut inside — which is where the declared length that ran off the end lives.
        """
        whole = _real_file()
        cut = tmp_path / "cut.4dgs"
        cut.write_bytes(whole[: len(whole) // 2])
        status, text = _cli(capsys, "validate", str(cut))
        assert status == 1
        assert "note: the file is cut at byte " in text, text
        assert "complete records before it are intact" in text, text

    def test_the_walk_reports_the_record_the_cut_is_inside_and_no_more(self):
        whole = _real_file()
        entire = refusal.walk(whole)
        assert entire.cut is None and entire.trailing_magic
        assert entire.intact() == len(entire.records)

        walk = refusal.walk(whole[: len(whole) // 2])
        assert walk.cut is not None and walk.cut.inside_a_record
        # The incomplete record is listed — hiding it would hide the length that is the
        # fault — and it is not counted as something a streamed reader keeps.
        assert walk.intact() == len(walk.records) - 1
        assert walk.records[-1].offset == walk.cut.at
        assert not walk.trailing_magic


class TestRefusalPlacement:
    def test_an_error_with_no_identifier_is_not_given_one(self):
        """An invented identifier would be inventing conformance.

        A truncated transport and an encoder bound violation are real errors and not
        refusals the corpus names, so they are reported without one rather than with the
        nearest-looking one.
        """
        assert refusal.describe(fourdgs.TruncatedFile("cut")) is None
        assert refusal.describe(fourdgs.MalformedFile("something specific")) is None

    def test_a_magic_refusal_is_placed_at_byte_zero_without_a_walk(self):
        named = refusal.describe(fourdgs.UnsupportedVersion("bad", code="magic-mismatch"))
        assert named is not None and named.site is not None
        assert (named.site.offset, named.site.what) == (0, "the magic")

    def test_a_code_the_table_does_not_know_is_left_unplaced_rather_than_placed_wrongly(self):
        """An offset that points at the wrong record is worse than no offset, because
        whoever is holding the file believes it."""
        named = refusal.describe(fourdgs.MalformedFile("x", code="broken-reference"), refusal.walk(_real_file()))
        assert named is not None and named.code == "broken-reference"
        assert named.site is None
        assert str(named) == "refusal broken-reference"

    def test_the_printed_form_carries_the_code_and_the_byte(self):
        named = refusal.Named("unknown-temporal-model", refusal.Site(8, "the Header record"))
        assert str(named) == "refusal unknown-temporal-model at byte 8 (the Header record)"


class TestBoundedDecoding:
    def test_the_chunks_are_decoded_one_at_a_time(self, monkeypatch):
        """AGENTS.md §1: validating a file must not require holding it.

        The indexed path fetches one chunk, decodes it, and drops it before fetching the
        next. Counting calls would not show that — an implementation that appended every
        decoded chunk to a list makes exactly the same calls — so each chunk's decoded
        positions are held by a weak reference and every earlier one must already be dead
        by the time the next is decoded.
        """
        import weakref

        from fourdgs import indexed_reader

        original = indexed_reader.read_chunk
        earlier: list[weakref.ref] = []

        def watched(source, scene, entry, **kwargs):
            assert all(ref() is None for ref in earlier), "a previous chunk is still resident"
            decoded = original(source, scene, entry, **kwargs)
            earlier.append(weakref.ref(decoded["positions"]))
            return decoded

        monkeypatch.setattr(indexed_reader, "read_chunk", watched)
        data = _real_file()
        assert refusal.scan_chunks(data) is None
        assert len(earlier) > 1, "the fixture must carry more than one chunk for this to prove anything"

    def test_a_file_with_no_index_is_still_decoded_front_to_back(self):
        """No per-chunk addressing to use, so no offset to attribute a refusal to — but
        the streams are still read, which is the only way their faults are seen at all."""
        data = _real_file(write_index=False)
        assert refusal.walk(data).first(op.CHUNK_INDEX) is None
        assert refusal.scan_chunks(data) is None


def _minimal(*, extra: bytes = b"") -> bytes:
    head = rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6)
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
    return MAGIC + body + rec.Footer().encode() + MAGIC


def _real_file(**options) -> bytes:
    """A file this encoder wrote, with several chunks, so the scan has work to do."""
    n = 96
    windows = 4
    scene = fourdgs.GaussianSet(
        positions=RNG.normal(0, 0.5, (n, 3)).astype(np.float32),
        scales=np.exp(RNG.normal(-7, 0.5, (n, 3))).astype(np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=RNG.uniform(0, 1, (n, 4)).astype(np.float32),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.asarray([(i % windows) + 0.5 for i in range(n)], dtype=np.float32),
        sigma_t=np.full(n, 0.1, dtype=np.float32),
        win_lo=np.asarray([float(i % windows) for i in range(n)], dtype=np.float32),
        win_hi=np.asarray([float(i % windows + 1) for i in range(n)], dtype=np.float32),
    )
    settings = {"write_index": True, "write_crc": True}
    settings.update(options)
    buf = io.BytesIO()
    fourdgs.write(buf, scene, float(windows), options=fourdgs.WriteOptions(**settings))
    return buf.getvalue()
