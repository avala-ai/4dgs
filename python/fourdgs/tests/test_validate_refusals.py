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
import struct
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import fourdgs
import numpy as np
import pytest
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs import refusal
from fourdgs.cli import main
from fourdgs.exceptions import UnsupportedCodec
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.serialization import (
    CODEC_DEFLATE,
    MAGIC,
    compress,
    crc32,
    encode_stream,
    iter_records,
    put_blob,
    put_f64,
    put_record,
    put_string,
    put_u32,
    put_u64,
)
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


def _tool(*argv: str) -> tuple[int, str, str]:
    """The tool as a user runs it: a new process, a real exit status, real streams.

    In-process `main()` is the same code and not the same claim. A caller of this tool is
    a shell, and what it sees is the process's exit status — which nothing inside this
    package returns and no in-process test observes. `python -m fourdgs.cli` is the
    console script's entry point, taken through `sys.exit`.
    """
    root = Path(__file__).resolve().parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(p for p in (str(root), env.get("PYTHONPATH", "")) if p)
    done = subprocess.run(
        [sys.executable, "-m", "fourdgs.cli", *argv],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
        check=False,  # a non-zero status is the thing under test, not an accident
    )
    return done.returncode, done.stdout, done.stderr


class TestTheCommandLine:
    """End to end, through a process, because the exit status is the contract.

    Five other SDKs are written against what this tool prints and what it returns, and a
    pipeline gates on the status alone. None of that is observable from a function call.
    """

    def test_a_conforming_file_prints_valid_and_exits_zero(self):
        paths = _variants(CORPUS)
        _require_corpus(paths, "conformance corpus")
        path = next(p for p in paths if p.stem == "OneWindow-UseChunkIndex-UseCrc")
        status, out, err = _tool("validate", str(path))
        assert (status, out.strip(), err) == (0, "valid", "")

    def test_every_invalid_variant_exits_one_with_its_identifier_on_stdout(self):
        """Both halves, in one process: the finding and its identifier on stdout, the
        verdict on stderr, and an exit status a shell can branch on."""
        corpus = _invalid_corpus()
        _require_corpus([path for _, path, _ in corpus], "invalid corpus")
        for name, path, code in corpus:
            status, out, err = _tool("validate", str(path))
            assert status == 1, f"{name}: exit {status}\n{out}{err}"
            assert f"refusal {code} at byte " in out, f"{name}: {out}"
            assert out.splitlines()[0].startswith("error: "), f"{name}: {out}"
            assert err.strip() == "INVALID", f"{name}: {err}"

    def test_a_file_the_tool_cannot_open_is_not_a_file_it_refused(self, tmp_path):
        """Exit 1 means "I read your file and it is invalid". A missing path is not that,
        and a caller handed the same status for both cannot tell a malformed corpus from a
        typo in a directory name — which is exactly what a nightly pipeline does with it.
        """
        missing = tmp_path / "not-here.4dgs"
        status, out, err = _tool("validate", str(missing))
        assert status == 3, f"exit {status}: {out}{err}"
        assert "not-here.4dgs" in err and "Traceback" not in err, err
        assert out == "", out


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

    def test_a_delta_chunk_in_a_gaussian_birth_file_is_refused(self):
        """§5.18: a Delta Chunk "exists only under `keyframe-delta`".

        Neither reader says so — the streamed one skips the opcode as though it were a
        record from a later revision, and the indexed one stops at the first Chunk — so
        the record was read by nobody and reported by nobody. The state it carries is
        simply not in the scene, and the file that carries it validated clean.
        """
        birth = _real_file()
        spliced = _splice(birth, _first_record(_keyframe_file(), op.DELTA_CHUNK))
        report = validate(spliced)
        assert not report.ok
        assert any("Delta Chunk record appears at byte" in f.message for f in report.findings), report.findings

    def test_a_keyframe_delta_file_with_no_index_is_read_front_to_back(self):
        """No index is a legal file (spec §4, AGENTS.md §2), not a broken one.

        The indexed reader was run over it regardless, and a Footer whose `summary_start`
        is 0 sent it to read records from byte 0 — where the magic sits — so it reported a
        conforming file invalid with a diagnosis about a record that does not exist.
        """
        report = validate(_keyframe_file(write_index=False))
        assert report.ok, [str(f) for f in report.findings]
        assert [f.severity for f in report.findings] == ["warning"], "only the no-index warning"

    def test_the_header_gaussian_count_is_checked_against_the_distinct_ids(self):
        """`gaussian_count` counts distinct gaussians over the sequence under this model.

        Summing the chunks is a larger number by design, which is why that check is
        skipped here — but skipping it left the field checked by nothing at all, and a
        Header could declare any number it liked.
        """
        data = _keyframe_file()
        report = validate(_patch_gaussian_count(data, 999))
        assert not report.ok
        assert any("999 gaussians; the sequence carries" in f.message for f in report.findings), report.findings

    def test_the_quantization_scheme_is_checked_on_this_path_too(self):
        """The gaussian-birth branch gets this from `open_indexed`; this one had nothing.

        So the same Quantization record was a refusal on one path and unremarkable on the
        other, decided by a temporal model that has nothing to do with quantization.
        """
        data = _keyframe_file().replace(b"uniform-v1", b"uniform-v9", 1)
        report = validate(data)
        named = [f.refusal for f in report.findings if f.refusal is not None]
        assert any(n.code == "unknown-quantization-scheme" and n.site is not None for n in named), report.findings

    def test_the_index_and_the_delta_chunk_must_agree_field_by_field(self):
        """§5.8: four index fields duplicate what the Delta Chunk states, and "a reader
        MUST refuse a file where the index and the record disagree, naming the field".

        The duplication is only a corruption check if somebody performs it. Nothing did:
        the chain came from the index and the record was parsed for its group counts, so a
        file whose index and records described two different sequences was read as
        whichever the reader happened to consult.
        """
        data = _keyframe_file()
        delta = _first_record(data, op.DELTA_CHUNK)
        # content: f64 t0, f64 t1, u32 level, u8 delta_mode
        at = delta.offset + 9 + 8 + 8 + 4
        patched = bytearray(data)
        patched[at] = 0 if patched[at] == 1 else 1
        report = validate(bytes(patched))
        assert not report.ok
        assert any("declares delta_mode" in f.message for f in report.findings), report.findings

    def test_unknown_chunk_kinds_are_refused_before_dispatch(self):
        data = _keyframe_file()
        report = validate(_repack_summary(data, lambda _i, e: _with(e, kind=2) if e.kind == 1 else e))
        assert not report.ok
        assert any("unknown chunk_kind 2" in f.message for f in report.findings), report.findings

    def test_a_keyframe_chunk_interval_must_match_its_index_entry(self):
        data = _keyframe_file()
        chunk = _first_record(data, op.CHUNK)
        patched = bytearray(data)
        struct.pack_into("<d", patched, chunk.offset + 9, 0.25)
        report = validate(bytes(patched))
        assert not report.ok
        assert any("keyframe Chunk record there declares" in f.message for f in report.findings), report.findings

    def test_a_delta_must_name_the_keyframe_its_chain_reaches(self):
        data = _keyframe_file()
        entry = next(e for e in _index_entries(data) if e.kind == 1)
        wrong = entry.keyframe_offset + 1
        patched = bytearray(data)
        # Delta Chunk content: t0, t1, level, delta_mode, reference_offset, keyframe_offset.
        struct.pack_into("<Q", patched, entry.chunk_offset + 9 + 29, wrong)
        both_wrong = _repack_summary(
            bytes(patched),
            lambda _i, e: _with(e, keyframe_offset=wrong) if e.chunk_offset == entry.chunk_offset else e,
        )
        report = validate(both_wrong)
        assert not report.ok
        assert any("its chain reaches the keyframe" in f.message for f in report.findings), report.findings

    def test_keyframe_chunk_level_compression_is_honored(self):
        data = _keyframe_file()
        chunk = _first_record(data, op.CHUNK)
        head, streams = rec.parse_chunk(chunk.content)
        raw = bytes(streams)
        compressed = compress(raw, CODEC_DEFLATE, 6)
        content = (
            put_f64(head.t0)
            + put_f64(head.t1)
            + put_u32(head.level)
            + put_u32(head.count)
            + put_string("deflate")
            + put_u64(len(raw))
            + put_blob(compressed)
        )
        ids, _bins = kdf._keyframe_from_chunk(content)
        assert len(ids) == head.count

    def test_indexed_keyframe_delta_bands_are_decoded(self):
        data = _keyframe_file()
        index = _index_entries(data)
        first = index[0]
        stream = bytearray(
            encode_stream(op.SH_BAND_STREAM, np.zeros((first.live_count, 3), dtype=np.int64), channels=3, codec=0)
        )
        stream[3] = 9  # stream codec
        band_blob = put_record(op.SH_BAND_STREAM, bytes([1]) + bytes(stream))
        band_at = len(data)
        indexed = _with(first, bands=[(1, band_at, len(band_blob))])
        index[0] = indexed
        with pytest.raises(UnsupportedCodec, match="unknown stream codec 9"):
            kdf.compose_chain(data + band_blob, index, indexed)

    def test_the_index_and_the_composed_population_must_agree(self):
        """`live_count` is the one index field only a decode can settle: the population
        after composition, which is the number a seeking consumer budgets against. The
        chain was walked from the index and the result was never compared back to it."""
        data = _keyframe_file()
        report = validate(_repack_summary(data, lambda i, e: _with(e, live_count=e.live_count + 1) if i == 0 else e))
        assert not report.ok
        assert any("declares live_count" in f.message for f in report.findings), report.findings

    def test_a_keyframe_chunk_whose_streams_contradict_its_count_is_refused(self):
        """A keyframe chunk is a Chunk record and `count` is the same field there, which
        `decode_streams` checks every stream against on the gaussian-birth path. This path
        had its own loop and never looked at it, so one malformed chunk was refused as a
        gaussian-birth chunk and composed as a keyframe."""
        data = _keyframe_file()
        chunk = _first_record(data, op.CHUNK)
        at = chunk.offset + 9 + 8 + 8 + 4  # f64 t0, f64 t1, u32 level, then u32 count
        patched = bytearray(data)
        struct.pack_into("<I", patched, at, struct.unpack_from("<I", patched, at)[0] + 1)
        report = validate(bytes(patched))
        assert not report.ok
        assert any("the keyframe chunk declares" in f.message for f in report.findings), report.findings

    def test_a_declared_group_count_no_group_carries_is_refused(self):
        """§5.18: "a stream whose `element_count` disagrees with its group's count is a
        refusal rather than an allocation".

        The counts are in the header so a streamed reader can size its working set before
        it decompresses anything. `apply_delta` sized everything from the arrays that
        arrived instead, so the declared counts were parsed and then used for nothing.
        """
        data = _keyframe_file()
        delta = _first_record(data, op.DELTA_CHUNK)
        at = delta.offset + 9 + 8 + 8 + 4 + 1 + 8 + 8 + 2  # ... delta_mode, offsets, depth
        patched = bytearray(data)
        was = struct.unpack_from("<I", patched, at)[0]
        struct.pack_into("<I", patched, at, was + 3)
        report = validate(bytes(patched))
        assert not report.ok
        assert any("its header declares" in f.message for f in report.findings), report.findings

    def test_a_window_index_outside_the_table_is_refused_at_composition(self):
        """Composition produces bins and stops there, so nothing on this path looked at
        `window_index`: the bound was proved during reconstruction, on the one instant
        somebody asked for. A file whose keyframe named a window its table does not have
        composed cleanly here and refused when it was rendered."""
        data = _keyframe_file(two_windows=True)
        table = _first_record(data, op.WINDOW_TABLE)
        assert len(rec.WindowTable.parse(table.content).windows) == 2
        patched = bytearray(data)
        struct.pack_into("<I", patched, table.offset + 9, 1)  # the table now declares one
        report = validate(bytes(patched))
        assert not report.ok
        assert any("window index" in f.message for f in report.findings), report.findings

    def test_the_state_chunks_must_cover_the_whole_timeline(self):
        """§11.1 is three rules, and adjacency is only the middle one: "the first `t0` is
        `0`; the last `t1` is the Header's `duration_sec`".

        Adjacency alone passes a file whose chunks tile the middle of its timeline and
        cover neither end — and a single-entry index has no adjacent pair to check at all.
        A reader asked for an instant in the uncovered part then refuses a file this tool
        called clean.
        """
        data = _keyframe_file()
        entries = len(kdf.open_indexed(data).index)
        for name, keep in (
            ("a gap at the end", lambda i, e: _with(e, t1=e.t1 - 1.0) if i == entries - 1 else e),
            ("a gap at the start", lambda i, e: _with(e, t0=0.5) if i == 0 else e),
        ):
            report = validate(_repack_summary(data, keep))
            assert not report.ok, name
            assert any("state chunks" in f.message for f in report.findings), (name, report.findings)


class TestTheIndexIsData:
    """An index entry is data, and data in an untrusted file can say anything.

    Every check that decodes a chunk is driven by the index, so a chunk no entry names is
    a chunk nothing decodes. The file layout is one entry per chunk (§4), which makes the
    omission itself the fault — and a better finding than quietly decoding around it.
    """

    def test_a_chunk_the_index_does_not_name_is_reported(self):
        corpus = [p for p in _variants(CORPUS / "invalid") if p.stem == "WindowIndexOutOfRange"]
        _require_corpus(corpus, "the WindowIndexOutOfRange variant")
        data = corpus[0].read_bytes()
        # The corpus file's fault is in its second chunk. Drop that entry and the file
        # used to validate clean: the framing walk steps over the chunk, and the scan only
        # visited what the index named.
        thinned = _repack_summary(data, lambda i, e: None if i == 1 else e)
        report = validate(thinned)
        assert not report.ok
        assert any("is not named by any chunk index entry" in f.message for f in report.findings), report.findings

    def test_two_entries_naming_one_chunk_are_reported(self):
        corpus = [p for p in _variants(CORPUS / "invalid") if p.stem == "WindowIndexOutOfRange"]
        _require_corpus(corpus, "the WindowIndexOutOfRange variant")
        data = corpus[0].read_bytes()
        first = _index_entries(data)[0]
        report = validate(_repack_summary(data, lambda i, e: first if i == 1 else e))
        assert any("both name the chunk at byte" in f.message for f in report.findings), report.findings


class TestSHBandStreams:
    def test_a_band_that_does_not_decode_is_found_and_named(self):
        """A framing walk steps over an SH Band Stream exactly as it steps over a Chunk.

        `read_chunk` caps the bands it fetches, which is right for a renderer — the
        coefficients do not enter reconstructed state — and wrong for a validator: a band
        carrying a codec no build implements is a file that does not decode, and capping
        the bands reported it `valid`.
        """
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem]
        _require_corpus(paths, "corpus variants carrying SH bands")
        for path in paths:
            data = bytearray(path.read_bytes())
            band = _first_record(bytes(data), op.SH_BAND_STREAM)
            assert band is not None, path.name
            # content: u8 band index, then the stream header, whose fourth byte is the codec
            data[band.offset + 9 + 1 + 3] = 9
            report = validate(bytes(data))
            named = [f.refusal for f in report.findings if f.refusal is not None]
            assert not report.ok, path.name
            assert any(n.code == "unknown-stream-codec" for n in named), (path.name, report.findings)
            # And at the band's own record, not at the Chunk it belongs to: the two are
            # thousands of bytes apart, and the Chunk's streams are perfectly healthy.
            site = next(n.site for n in named if n.code == "unknown-stream-codec")
            assert site is not None and site.offset == band.offset, path.name
            assert "SH Band Stream for band" in site.what, site.what


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

    def test_the_record_named_is_the_one_the_reader_refused_at(self):
        """Not the first of its kind. Nothing in the framing forbids a second Header, and
        the reader checks every one it meets as it meets it — so a file whose first Header
        is fine and whose second declares a model this build does not implement is refused
        at the second. Naming the first sends its holder to bytes that are perfectly good,
        with an offset they have no reason to doubt."""
        later = rec.Header(duration_sec=1.0, gaussian_count=0, aabb=[0.0] * 6, temporal_model="frame-sequence").encode()
        data = _minimal(extra=later)
        headers = [f for f in refusal.walk(data).records if f.opcode == op.HEADER]
        assert len(headers) == 2 and headers[0].offset == len(MAGIC)
        report = validate(data)
        named = next(f.refusal for f in report.findings if f.refusal is not None)
        assert named.code == "unknown-temporal-model"
        assert named.site is not None
        assert named.site.offset == headers[1].offset, "the first Header declares a model this reader implements"


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
        assert refusal.walk(data).first_intact(op.CHUNK_INDEX) is None
        assert refusal.scan_chunks(data) is None

    def test_an_unindexed_file_is_decoded_without_being_assembled(self, monkeypatch):
        """The library's streamed reader appends every decoded chunk and concatenates the
        lot into one `GaussianSet` — which is what a *reader* wants and what a validator
        must not do. This drives the decode primitives directly and drops each result, so
        the same weak-reference proof applies here as on the indexed path.
        """
        import weakref

        from fourdgs import stream_reader

        original = stream_reader.decode_streams
        earlier: list[weakref.ref] = []

        def watched(*args, **kwargs):
            assert all(ref() is None for ref in earlier), "a previous chunk is still resident"
            decoded = original(*args, **kwargs)
            earlier.append(weakref.ref(decoded["positions"]))
            return decoded

        monkeypatch.setattr(stream_reader, "decode_streams", watched)
        data = _real_file(write_index=False)
        assert refusal.scan_chunks(data) is None
        assert len(earlier) > 1, "the fixture must carry more than one chunk for this to prove anything"

    def test_a_keyframe_delta_file_is_composed_one_state_at_a_time(self, monkeypatch):
        """A composed state is a whole population, and `decode_indexed` keeps one per index
        entry — memory proportional to population times chunk count, on a model whose whole
        point is that a seek is cheap. The validator composes each chain and drops it."""
        import weakref

        from fourdgs import keyframe_delta_file

        original = keyframe_delta_file.compose_chain
        earlier: list[weakref.ref] = []

        def watched(*args, **kwargs):
            assert all(ref() is None for ref in earlier), "a previously composed state is still resident"
            state = original(*args, **kwargs)
            earlier.append(weakref.ref(state.ids))
            return state

        monkeypatch.setattr(keyframe_delta_file, "compose_chain", watched)
        report = validate(_keyframe_file())
        assert report.ok, [str(f) for f in report.findings]
        assert len(earlier) > 1, "the fixture must carry more than one chunk for this to prove anything"

    def test_an_unindexed_keyframe_delta_file_keeps_two_states_at_most(self):
        """`decode_streamed` keeps a state per chunk plus a map of every offset a delta
        could reference. §5.18 defines exactly two references — the keyframe at the head of
        the group, and the chunk before this one — so a scan needs those two and nothing
        else. A reference to anything else is a fault named rather than a third state kept
        in case."""
        import weakref

        data = _keyframe_file(write_index=False)
        seen: list[weakref.ref] = []
        for _offset, _kind, state in kdf.scan_streamed(data):
            seen.append(weakref.ref(state.ids))
            del state
            alive = [ref for ref in seen if ref() is not None]
            assert len(alive) <= 2, f"{len(alive)} states resident at once"
        assert len(seen) > 2, "the fixture must carry more than two chunks for this to prove anything"


def _first_record(data: bytes, opcode: int):
    return next((r for r in iter_records(data, len(MAGIC)) if r.opcode == opcode), None)


def _splice(data: bytes, record) -> bytes:
    """Insert one record's bytes just before the Footer."""
    footer = _first_record(data, op.FOOTER)
    blob = record.content
    return data[: footer.offset] + put_record(record.opcode, bytes(blob)) + data[footer.offset :]


def _index_entries(data: bytes) -> list[rec.ChunkIndexEntry]:
    return [rec.ChunkIndexEntry.parse(r.content) for r in iter_records(data, len(MAGIC)) if r.opcode == op.CHUNK_INDEX]


def _with(entry: rec.ChunkIndexEntry, **fields) -> rec.ChunkIndexEntry:
    return replace(entry, **fields)


def _repack_summary(data: bytes, keep) -> bytes:
    """Rewrite the summary, passing each index entry through `keep`, and fix the CRC.

    The summary sits between `summary_start` and the Footer, so rewriting it moves no
    chunk and invalidates no offset any record holds — which is what makes an index that
    disagrees with the file expressible at all.
    """
    summary = []
    footer_record = None
    for record in iter_records(data, len(MAGIC)):
        if record.opcode == op.FOOTER:
            footer_record = record
        elif record.opcode in (op.CHUNK_INDEX, op.STATISTICS, op.SUMMARY_OFFSET):
            summary.append(record)
    footer = rec.Footer.parse(footer_record.content)
    blob = b""
    entries = 0
    for record in summary:
        if record.opcode == op.CHUNK_INDEX:
            kept = keep(entries, rec.ChunkIndexEntry.parse(record.content))
            entries += 1
            if kept is not None:
                blob += kept.encode()
        else:
            blob += put_record(record.opcode, bytes(record.content))
    if footer.summary_crc:
        footer.summary_crc = crc32(blob)
    return data[: footer.summary_start] + blob + footer.encode() + MAGIC


def _patch_gaussian_count(data: bytes, count: int) -> bytes:
    """The Header's `gaussian_count`, changed in place so no offset moves."""
    record = _first_record(data, op.HEADER)
    header = rec.Header.parse(record.content)
    was = header.encode()
    header.gaussian_count = count
    now = header.encode()
    assert len(was) == len(now), "the count is fixed-width; the file must not move"
    return data.replace(was, now, 1)


def _keyframe_file(*, two_windows: bool = False, **options) -> bytes:
    """A `keyframe-delta` file this package wrote: eight samples, a keyframe every four."""
    steps, duration = 8, 8.0
    windows = [(0.0, duration), (0.0, duration / 2), (0.0, duration), (0.0, duration / 2)] if two_windows else None
    samples = []
    for i in range(steps):
        positions = [
            [float(i) * 0.1, 0.0, 0.0],
            [1.0, float(i) * 0.05, 0.0],
            [0.0, 1.0, float(i) * 0.03],
            [1.0, 1.0, 0.0],
        ]
        samples.append(
            Sample(
                t0=float(i) * (duration / steps),
                ids=np.array([0, 1, 2, 3]),
                gaussians=_keyframe_gaussians(positions, duration, windows),
            )
        )
    return kdf.write_sequence(samples, duration, kd=KeyframeDeltaOptions(keyframe_every=4), **options)


def _keyframe_gaussians(positions, duration: float, windows) -> fourdgs.GaussianSet:
    n = len(positions)
    lo = np.zeros(n, dtype=np.float32) if windows is None else np.asarray([w[0] for w in windows], dtype=np.float32)
    hi = (
        np.full(n, duration, dtype=np.float32)
        if windows is None
        else np.asarray([w[1] for w in windows], dtype=np.float32)
    )
    return fourdgs.GaussianSet(
        positions=np.asarray(positions, dtype=np.float32).reshape(n, 3),
        scales=np.full((n, 3), 0.05, dtype=np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=np.tile(np.array([0.6, 0.4, 0.2, 0.9], dtype=np.float32), (n, 1)),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.zeros(n, dtype=np.float32),
        # Finite and long, so the per-gaussian velocity and birth-time grids stay uniform
        # — the same shape `tests/conformance/generate.py` builds its keyframe corpus with.
        sigma_t=np.full(n, 100.0, dtype=np.float32),
        win_lo=lo,
        win_hi=hi,
    )


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
