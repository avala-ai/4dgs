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
import math
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
from fourdgs.exceptions import FourdgsError, MalformedFile, UnsupportedCodec
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.readable import BytesReadable
from fourdgs.serialization import (
    CODEC_DEFLATE,
    MAGIC,
    MAX_STREAM_BYTES,
    Cursor,
    compress,
    crc32,
    decode_stream,
    decode_stream_or_skip,
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

    def test_a_reader_that_leaves_early_does_not_change_the_verdict(self, tmp_path):
        """`4dgs validate bad.4dgs | head -1` is a verdict about the file, not about who
        was listening. The closed pipe arrives as `BrokenPipeError` — an `OSError`, and so
        indistinguishable from an unreadable file unless this tool tells them apart. Both
        bufferings are exercised: piped output is block-buffered, which defers the failure
        to interpreter shutdown, where an unhandled one exits 120 rather than the verdict.
        """
        path = tmp_path / "truncated.4dgs"
        path.write_bytes(MAGIC + b"\x00" * 512)
        root = Path(__file__).resolve().parents[1]
        env = dict(os.environ)
        env["PYTHONPATH"] = os.pathsep.join(p for p in (str(root), env.get("PYTHONPATH", "")) if p)
        for unbuffered in (False, True):
            # A pipe whose read end the parent closes at once, so the tool faces a reader
            # that has already gone — the state `head -1` leaves behind, without the race
            # of waiting for the tool to out-write a 64 KiB buffer first.
            read_end, write_end = os.pipe()
            argv = [sys.executable, *(["-u"] if unbuffered else []), "-m", "fourdgs.cli"]
            tool = subprocess.Popen(
                [*argv, "validate", str(path)],
                stdout=write_end,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            os.close(write_end)
            os.close(read_end)
            assert tool.stderr is not None
            err = tool.stderr.read()
            tool.stderr.close()
            status = tool.wait(timeout=300)
            assert status == 1, f"unbuffered={unbuffered}: exit {status}, stderr {err!r}"
            assert "Broken pipe" not in err, f"unbuffered={unbuffered}: {err!r}"


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

    def test_an_open_ended_indexed_sequence_composes_its_selected_entry(self):
        data = _single_keyframe_file(write_index=True)
        header_record = _first_record(data, op.HEADER)
        header = rec.Header.parse(header_record.content)
        header.duration_sec = math.inf
        data = (
            data[: header_record.offset]
            + header.encode()
            + data[header_record.offset + 9 + len(header_record.content) :]
        )
        chunk = _first_record(data, op.CHUNK)
        patched = bytearray(data)
        struct.pack_into("<d", patched, chunk.offset + 9 + 8, math.inf)
        data = _repack_summary(
            bytes(patched),
            lambda _i, entry: _with(entry, t1=math.inf),
        )
        opened = kdf.open_indexed(data)
        state = kdf.compose_chain(
            data,
            opened.index,
            opened.index[-1],
            opened.windows,
            opened.grids,
        )
        assert state.count == 1

    def test_compose_chain_reads_the_window_table_when_it_is_not_passed_one(self):
        """An omitted `windows` means "read it from `data`", not "the file has none".

        `check_window_indices_of` reads an empty table as the single implicit window a
        file with no Window Table carries, so defaulting to `[]` made this entry point —
        the one its own docstring offers to validators — refuse every multi-window file
        it was handed. `grids` had a real fallback from the same `open_indexed` call all
        along; `windows` now comes from beside it.
        """
        duration = 2.0
        sample = Sample(
            t0=0.0,
            ids=np.array([7, 8]),
            gaussians=_keyframe_gaussians(
                [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]],
                duration,
                [(0.0, 1.0), (1.0, 2.0)],
            ),
        )
        data = kdf.write_sequence(
            [sample],
            duration,
            kd=KeyframeDeltaOptions(keyframe_every=1),
            write_index=True,
        )
        opened = kdf.open_indexed(data)
        assert len(opened.windows) == 2, "the fixture has to be multi-window to prove anything"

        state = kdf.compose_chain(data, opened.index, opened.index[-1])

        assert state.count == 2

    def test_compose_chain_refuses_what_scan_indexed_refuses(self):
        """The seeking entry point and the scan must agree on which files are legal.

        `compose_chain` is what a validator is told to call per entry, and it carried
        neither the forward-reference check, the depth-chain check, nor the rule that a
        keyframe entry zeroes its delta fields. `scan_indexed` carried all three, so the
        same bytes were `forward-reference` on one path and readable on the other.
        """
        import copy

        duration = 2.0
        samples = [
            Sample(
                t0=float(step),
                ids=np.array([1, 2]),
                gaussians=_keyframe_gaussians([[0.1 * step, 0.0, 0.0], [1.0, 0.0, 0.0]], duration, None),
            )
            for step in range(2)
        ]
        data = kdf.write_sequence(samples, duration, kd=KeyframeDeltaOptions(keyframe_every=0), write_index=True)
        opened = kdf.open_indexed(data)
        assert any(e.kind == 1 for e in opened.index), "the fixture must carry a delta entry"

        def verdicts(mutate):
            index = copy.deepcopy(opened.index)
            target = mutate(index)

            def code(call):
                try:
                    call()
                    return None
                except FourdgsError as exc:
                    return getattr(exc, "code", None)

            return (
                code(lambda: list(kdf.scan_indexed(data, index, opened.windows))),
                code(lambda: kdf.compose_chain(data, index, target, opened.windows, opened.grids)),
            )

        def forward(index):
            entry = next(e for e in index if e.kind == 1)
            entry.reference_offset = entry.chunk_offset + 8
            return entry

        def depth(index):
            entry = next(e for e in index if e.kind == 1)
            entry.depth = 99
            return entry

        def keyframe_fields(index):
            next(e for e in index if e.kind == 0).depth = 3
            return next(e for e in index if e.kind == 1)

        for mutate in (forward, depth, keyframe_fields):
            scanned, composed = verdicts(mutate)
            assert scanned is not None, "the scan is supposed to refuse this"
            assert composed == scanned, f"{mutate.__name__}: scan said {scanned}, compose said {composed}"

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

    def test_every_header_is_checked_on_the_selected_keyframe_delta_path(self):
        data = _keyframe_file(write_index=False)
        original = _first_record(data, op.HEADER)
        wrong = rec.Header.parse(original.content)
        wrong.temporal_model = "gaussian-birth"
        wrong_first = data[: original.offset] + wrong.encode() + data[original.offset + 9 + len(original.content) :]
        report = validate(_splice(wrong_first, original))
        assert not report.ok
        assert any("contains a Header declaring" in finding.message for finding in report.findings)

    def test_an_indexless_sequence_requires_every_declared_sh_band(self):
        data = _patch_sh_degree(_single_keyframe_file(write_index=False), 1)
        report = validate(data)
        assert not report.ok
        assert any("followed by SH bands []; the Header declares degree 1" in f.message for f in report.findings)

    def test_an_indexless_keyframe_delta_band_must_match_its_owner_shape(self):
        data = _patch_sh_degree(_single_keyframe_file(write_index=False), 1)
        malformed = next(
            iter_records(
                put_record(
                    op.SH_BAND_STREAM,
                    bytes([1])
                    + encode_stream(
                        op.SH_BAND_STREAM,
                        np.zeros((1, 3), dtype=np.int64),
                        channels=3,
                    ),
                )
            )
        )
        report = validate(_splice(data, malformed))
        assert not report.ok
        assert any("owning state record requires (1, 9)" in f.message for f in report.findings)

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

    def test_every_keyframe_delta_index_entry_carries_the_extension(self):
        data = _keyframe_file()
        report = validate(_repack_summary(data, lambda i, entry: _with(entry, extended=False) if i == 0 else entry))
        assert not report.ok
        assert any("omits chunk_kind" in finding.message for finding in report.findings)

    def test_an_indexed_state_range_frames_exactly_one_record(self):
        data = _keyframe_file()
        report = validate(
            _repack_summary(
                data,
                lambda i, entry: _with(entry, chunk_length=entry.chunk_length + 9) if i == 0 else entry,
            )
        )
        assert not report.ok
        assert any("frames exactly" in finding.message for finding in report.findings)

    def test_a_keyframe_chunk_interval_must_match_its_index_entry(self):
        data = _keyframe_file()
        chunk = _first_record(data, op.CHUNK)
        patched = bytearray(data)
        struct.pack_into("<d", patched, chunk.offset + 9, 0.25)
        report = validate(bytes(patched))
        assert not report.ok
        assert any("keyframe Chunk record there declares" in f.message for f in report.findings), report.findings

    @pytest.mark.parametrize("write_index", [False, True], ids=("streamed", "indexed"))
    def test_every_keyframe_mu_t_decodes_to_its_chunk_timestamp(self, write_index):
        data = _single_keyframe_file(write_index=write_index, codec=0)
        chunk = _first_record(data, op.CHUNK)
        head, streams = rec.parse_chunk(chunk.content)
        cursor = Cursor(bytes(streams))
        rewritten: list[bytes] = []
        while cursor.remaining():
            start = cursor.pos
            attribute, values = decode_stream(cursor)
            if attribute == op.A_MU_T:
                replacement = encode_stream(
                    attribute,
                    values + 1,
                    channels=values.shape[1],
                    codec=0,
                )
                assert len(replacement) == cursor.pos - start
                rewritten.append(replacement)
            else:
                rewritten.append(bytes(cursor.buf[start : cursor.pos]))
        replacement = rec.encode_chunk(head.t0, head.t1, head.level, head.count, b"".join(rewritten))
        original_length = 9 + len(chunk.content)
        assert len(replacement) == original_length
        malformed = data[: chunk.offset] + replacement + data[chunk.offset + original_length :]

        report = validate(malformed)
        assert not report.ok
        assert any(
            "decodes mu_t=" in f.message and "expected the Chunk timestamp" in f.message for f in report.findings
        )

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

    @pytest.mark.parametrize("write_index", [False, True], ids=("streamed", "indexed"))
    def test_an_uncompressed_keyframe_block_matches_its_declared_size(self, write_index):
        data = _single_keyframe_file(write_index=write_index)
        chunk = _first_record(data, op.CHUNK)
        head, streams = rec.parse_chunk(chunk.content)
        content = (
            put_f64(head.t0)
            + put_f64(head.t1)
            + put_u32(head.level)
            + put_u32(head.count)
            + put_string("")
            + put_u64(head.uncompressed_size + 1)
            + put_blob(bytes(streams))
        )
        replacement = put_record(op.CHUNK, content)
        original_length = 9 + len(chunk.content)
        assert len(replacement) == original_length
        malformed = data[: chunk.offset] + replacement + data[chunk.offset + original_length :]

        report = validate(malformed)
        assert not report.ok
        assert any("declares uncompressed_size" in f.message for f in report.findings), report.findings

    def test_delta_chunk_level_compression_is_honored(self):
        delta = _first_record(_keyframe_file(), op.DELTA_CHUNK)
        head, raw = rec.parse_delta_chunk_block(delta.content)
        compressed = compress(bytes(raw), CODEC_DEFLATE, 6)
        content = (
            put_f64(head.t0)
            + put_f64(head.t1)
            + put_u32(head.level)
            + bytes([head.delta_mode])
            + put_u64(head.reference_offset)
            + put_u64(head.keyframe_offset)
            + struct.pack("<H", head.depth)
            + put_u32(head.update_count)
            + put_u32(head.birth_count)
            + put_u32(head.death_count)
            + put_string("deflate")
            + put_u64(len(raw))
            + put_blob(compressed)
        )
        parsed, *_groups = kdf._delta_chunk_groups(content)
        assert parsed.t0 == head.t0 and parsed.t1 == head.t1
        assert parsed.compression == "deflate" and parsed.uncompressed_size == len(raw)

    @pytest.mark.parametrize(
        ("declared", "raw", "message"),
        [
            (MAX_STREAM_BYTES + 1, b"", "past the"),
            (8, b"x" * (1 << 20), "decompresses past"),
        ],
        ids=("declared-cap", "expansion-cap"),
    )
    def test_delta_chunk_decompression_is_bounded(self, declared, raw, message):
        delta = _first_record(_keyframe_file(), op.DELTA_CHUNK)
        head, _original = rec.parse_delta_chunk_block(delta.content)
        content = (
            put_f64(head.t0)
            + put_f64(head.t1)
            + put_u32(head.level)
            + bytes([head.delta_mode])
            + put_u64(head.reference_offset)
            + put_u64(head.keyframe_offset)
            + struct.pack("<H", head.depth)
            + put_u32(head.update_count)
            + put_u32(head.birth_count)
            + put_u32(head.death_count)
            + put_string("deflate")
            + put_u64(declared)
            + put_blob(compress(raw, CODEC_DEFLATE, 9))
        )
        with pytest.raises(FourdgsError, match=message):
            kdf._delta_chunk_groups(content)

    def test_births_are_complete_and_deaths_carry_only_identity(self):
        empty = kdf.State(ids=np.zeros(0, dtype=np.int64), bins={})
        birth = encode_stream(op.A_GAUSSIAN_ID, np.array([[7]], dtype=np.int64), channels=1)
        birth += encode_stream(op.A_WINDOW_INDEX, np.array([[0]], dtype=np.int64), channels=1)
        born = rec.encode_delta_chunk(0.0, 1.0, 0, 0, 0, 0, 1, b"", birth, b"", (0, 1, 0))
        with pytest.raises(MalformedFile, match="missing required attributes"):
            kdf._compose_delta(empty, born[9:])

        live = kdf.State(ids=np.array([7], dtype=np.int64), bins={})
        death = encode_stream(op.A_GAUSSIAN_ID, np.array([[7]], dtype=np.int64), channels=1)
        death += encode_stream(op.A_POSITION, np.zeros((1, 3), dtype=np.int64), channels=3)
        killed = rec.encode_delta_chunk(0.0, 1.0, 0, 0, 0, 0, 1, b"", b"", death, (0, 0, 1))
        with pytest.raises(MalformedFile, match="deaths group carries attributes"):
            kdf._compose_delta(live, killed[9:])

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

    def test_an_indexed_keyframe_delta_band_refusal_names_the_band_record(self):
        data = _patch_sh_degree(_single_keyframe_file(write_index=True), 1)
        stream = bytearray(encode_stream(op.SH_BAND_STREAM, np.zeros((1, 9), dtype=np.int64), channels=9, codec=0))
        stream[3] = 9
        data, band_at = _insert_single_indexed_band(data, put_record(op.SH_BAND_STREAM, bytes([1]) + stream))

        report = validate(data)
        named = [f.refusal for f in report.findings if f.refusal is not None]
        refusal_ = next(item for item in named if item.code == "unknown-stream-codec")
        assert refusal_.site is not None
        assert refusal_.site.offset == band_at
        assert "SH Band Stream for band 1" in refusal_.site.what

    def test_indexed_keyframe_delta_bands_must_have_the_declared_shape(self):
        data = _keyframe_file()
        index = _index_entries(data)
        first = index[0]
        # Band one is nine coefficients per gaussian. Keep the rows correct so this
        # mutation proves the channel-width check rather than the row-count check.
        band_blob = put_record(
            op.SH_BAND_STREAM,
            bytes([1])
            + encode_stream(
                op.SH_BAND_STREAM,
                np.zeros((first.live_count, 1), dtype=np.int64),
                channels=1,
            ),
        )
        band_at = len(data)
        index[0] = _with(first, bands=[(1, band_at, len(band_blob))])
        with pytest.raises(MalformedFile, match=r"requires \(4, 9\)"):
            kdf.compose_chain(data + band_blob, index, index[0])

    def test_an_index_cannot_omit_a_physical_keyframe_delta_band(self):
        data = _keyframe_file()
        header_record = _first_record(data, op.HEADER)
        header = rec.Header.parse(header_record.content)
        header.sh_degree = 1
        data = (
            data[: header_record.offset]
            + header.encode()
            + data[header_record.offset + 9 + len(header_record.content) :]
        )

        footer_record = _first_record(data, op.FOOTER)
        footer = rec.Footer.parse(footer_record.content)
        band = put_record(
            op.SH_BAND_STREAM,
            bytes([1]) + encode_stream(op.SH_BAND_STREAM, np.zeros((0, 9), dtype=np.int64), channels=9),
        )
        summary = data[footer.summary_start : footer_record.offset]
        footer.summary_start += len(band)
        data = data[: footer_record.offset - len(summary)] + band + summary + footer.encode() + MAGIC

        report = validate(data)
        assert not report.ok
        assert any(
            "physical records following that chunk" in finding.message
            or "the Header declares degree 1, requiring bands [1]" in finding.message
            for finding in report.findings
        ), report.findings

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

    def test_keyframe_and_delta_group_streams_use_registry_channel_counts(self):
        keyframe_streams = encode_stream(op.A_GAUSSIAN_ID, np.array([[7]], dtype=np.int64), channels=1) + encode_stream(
            op.A_POSITION, np.array([[1]], dtype=np.int64), channels=1
        )
        keyframe = next(iter_records(rec.encode_chunk(0.0, 1.0, 0, 1, keyframe_streams)))
        with pytest.raises(MalformedFile, match="attribute 0 declares 1 channels; the registry says 3"):
            kdf._keyframe_from_chunk(keyframe.content)

        group = encode_stream(op.A_GAUSSIAN_ID, np.array([[7, 8]], dtype=np.int64), channels=2)
        with pytest.raises(MalformedFile, match="attribute 13 declares 2 channels; the registry says 1"):
            kdf._decode_group(group)

    def test_gaussian_identity_stream_codes_are_reinterpreted_as_u32(self):
        group = encode_stream(
            op.A_GAUSSIAN_ID,
            np.array([[np.iinfo(np.int32).min]], dtype=np.int64),
            channels=1,
            codec=0,
        )
        ids, bins = kdf._decode_group(group)
        assert bins == {}
        assert ids.tolist() == [0x80000000]

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

    def test_indexless_validation_uses_the_last_window_table_like_reconstruction(self):
        data = _keyframe_file(two_windows=True, write_index=False)
        second = next(iter_records(rec.WindowTable(windows=[(0.0, 8.0)]).encode()))
        data = _splice(data, second)
        assert len(kdf.decode_streamed(data).windows) == 1

        report = validate(data)
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

    def test_an_indexless_sequence_must_tile_the_timeline_too(self):
        data = bytearray(_keyframe_file(write_index=False))
        delta = _first_record(bytes(data), op.DELTA_CHUNK)
        struct.pack_into("<d", data, delta.offset + 9, 1.25)
        report = validate(bytes(data))
        assert not report.ok
        assert any("preceding interval ends" in finding.message for finding in report.findings)

    def test_an_indexless_sequence_cannot_tile_file_order_with_a_reversed_interval(self):
        data = bytearray(_keyframe_file(write_index=False))
        states = [
            record for record in iter_records(bytes(data), len(MAGIC)) if record.opcode in (op.CHUNK, op.DELTA_CHUNK)
        ]
        assert len(states) >= 3
        # [0,2), [2,1), [1,3) is adjacent in physical order and reaches the same
        # endpoint. Only the middle interval being inverted exposes the old check.
        for record, t0, t1 in (
            (states[0], 0.0, 2.0),
            (states[1], 2.0, 1.0),
            (states[2], 1.0, 3.0),
        ):
            struct.pack_into("<dd", data, record.offset + 9, t0, t1)
        report = validate(bytes(data))
        assert not report.ok
        assert any("inverted interval [2.0, 1.0)" in finding.message for finding in report.findings)


class TestTheIndexIsData:
    def test_the_footer_selected_index_continues_after_statistics(self):
        data = _real_file()
        entries = _index_entries(data)
        assert len(entries) >= 2
        omitted = entries[-1]
        without = _repack_summary(
            data,
            lambda i, entry: None if i == len(entries) - 1 else entry,
        )
        footer = _first_record(without, op.FOOTER)
        # Summary records are contiguous, but indexes need not form one opcode run. The
        # indexed reader scans this complete Footer-selected range and sees the entry after
        # Statistics, so validation must use that same index.
        stray = omitted.encode()
        parsed_footer = rec.Footer.parse(footer.content)
        summary = without[parsed_footer.summary_start : footer.offset] + stray
        if parsed_footer.summary_crc:
            parsed_footer.summary_crc = crc32(summary)
        separated = without[: footer.offset] + stray + parsed_footer.encode() + MAGIC
        report = validate(separated)
        assert report.ok, report.findings

    def test_zero_count_keyframe_with_only_an_optional_stream_does_not_need_mu_t(self):
        header = rec.Header(
            duration_sec=1.0,
            gaussian_count=0,
            aabb=[0.0] * 6,
            temporal_model="keyframe-delta",
        )
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
        empty_ids = encode_stream(op.A_GAUSSIAN_ID, np.zeros((0, 1), dtype=np.int64), channels=1)
        optional = encode_stream(op.A_OBJECT_ID, np.zeros((0, 1), dtype=np.int64), channels=1)
        chunk = rec.encode_chunk(0.0, 1.0, 0, 0, empty_ids + optional)
        data = (
            MAGIC
            + header.encode()
            + quant.encode()
            + rec.WindowTable(windows=[(0.0, 1.0)]).encode()
            + chunk
            + rec.Footer().encode()
            + MAGIC
        )
        report = validate(data)
        assert report.ok, report.findings

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

    def test_a_gaussian_birth_indexed_range_frames_exactly_one_chunk_record(self):
        data = _real_file()
        report = validate(
            _repack_summary(
                data,
                lambda i, entry: _with(entry, chunk_length=entry.chunk_length + 1) if i == 0 else entry,
            )
        )
        assert not report.ok
        assert any("record there frames exactly" in finding.message for finding in report.findings), report.findings

    @pytest.mark.parametrize("field", ["t0", "t1", "gaussian_count"])
    def test_gaussian_birth_index_metadata_matches_its_chunk(self, field):
        data = _real_file()

        def change(i, entry):
            if i:
                return entry
            value = getattr(entry, field)
            return _with(entry, **{field: value + 1})

        report = validate(_repack_summary(data, change))
        assert not report.ok
        assert any(
            f"declares {field}" in finding.message and "Chunk record there declares" in finding.message
            for finding in report.findings
        ), report.findings

    def test_a_zero_length_range_at_eof_is_a_finding_not_an_index_error(self):
        data = _keyframe_file()
        report = validate(
            _repack_summary(
                data,
                lambda i, entry: _with(entry, chunk_offset=len(data), chunk_length=0) if i == 0 else entry,
            )
        )
        assert not report.ok
        assert any("does not contain a complete record header" in f.message for f in report.findings), report.findings


class TestSHBandStreams:
    def test_duplicate_physical_bands_are_refused_as_they_arrive(self):
        owner = len(MAGIC)
        data = (
            MAGIC
            + put_record(op.CHUNK, b"")
            + put_record(op.SH_BAND_STREAM, b"\x01")
            + put_record(op.SH_BAND_STREAM, b"\x01")
        )
        indexed = _with(_index_entries(_keyframe_file())[0], chunk_offset=owner)
        with pytest.raises(MalformedFile, match="band 1 more than once"):
            kdf.check_index_bands(data, [indexed], sh_degree=1)

    def test_indexless_scanners_reject_duplicate_bands_before_retaining_a_run(self):
        band = put_record(
            op.SH_BAND_STREAM,
            bytes([1])
            + encode_stream(
                op.SH_BAND_STREAM,
                np.zeros((1, 9), dtype=np.int64),
                channels=9,
            ),
        )
        keyframe = _patch_sh_degree(_single_keyframe_file(write_index=False), 1)
        chunk = _first_record(keyframe, op.CHUNK)
        after = chunk.offset + 9 + len(chunk.content)
        duplicate = keyframe[:after] + band + band + keyframe[after:]
        with pytest.raises(MalformedFile, match="band 1 more than once"):
            list(kdf.scan_streamed(duplicate))

        birth = _patch_sh_degree(_real_file(write_index=False), 1)
        owner = _first_record(birth, op.CHUNK)
        head, _streams = rec.parse_chunk(owner.content)
        birth_band = put_record(
            op.SH_BAND_STREAM,
            bytes([1])
            + encode_stream(
                op.SH_BAND_STREAM,
                np.zeros((head.count, 9), dtype=np.int64),
                channels=9,
            ),
        )
        after = owner.offset + 9 + len(owner.content)
        duplicate = birth[:after] + birth_band + birth_band + birth[after:]
        refused = refusal.scan_front_to_back(duplicate, refusal.walk(duplicate, retain_records=False))
        assert refused is not None
        assert "band 1 more than once" in str(refused.error)

    def test_keyframe_delta_physical_bands_need_not_be_in_band_number_order(self):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem and "UseChunkIndex" in p.stem]
        _require_corpus(paths, "indexed SH-degree-2 variants")
        data = bytearray(paths[0].read_bytes())
        entries = _index_entries(bytes(data))
        owner = next(entry for entry in entries if len(entry.bands) >= 2)
        first_band = next(
            record for record in iter_records(bytes(data), len(MAGIC)) if record.offset == owner.bands[0][1]
        )
        second_band = next(
            record for record in iter_records(bytes(data), len(MAGIC)) if record.offset == owner.bands[1][1]
        )
        first_bytes = bytes(data[first_band.offset : first_band.offset + 9 + len(first_band.content)])
        second_bytes = bytes(data[second_band.offset : second_band.offset + 9 + len(second_band.content)])
        data[first_band.offset : second_band.offset + 9 + len(second_band.content)] = second_bytes + first_bytes
        reordered_bands = [
            (owner.bands[1][0], first_band.offset, len(second_bytes)),
            (owner.bands[0][0], first_band.offset + len(second_bytes), len(first_bytes)),
        ]
        entries = [
            _with(entry, bands=reordered_bands) if entry.chunk_offset == owner.chunk_offset else entry
            for entry in entries
        ]

        kdf.check_index_bands(bytes(data), entries, 2)

    def test_an_indexless_gaussian_birth_chunk_requires_each_declared_band_once(self):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem and "UseChunkIndex" in p.stem]
        _require_corpus(paths, "indexed SH-degree-2 variants")
        data = paths[0].read_bytes()
        footer_record = _first_record(data, op.FOOTER)
        footer = rec.Footer.parse(footer_record.content)
        data = bytearray(data[: footer.summary_start] + rec.Footer().encode() + MAGIC)
        bands = [
            (record.offset, 9 + len(record.content))
            for record in iter_records(data, len(MAGIC))
            if record.opcode == op.SH_BAND_STREAM
        ]
        assert len(bands) >= 2
        missing_at, missing_length = bands[1]
        del data[missing_at : missing_at + missing_length]
        walked = refusal.walk(bytes(data), retain_records=False)
        refused = refusal.scan_front_to_back(bytes(data), walked)
        assert refused is not None
        assert "followed by SH bands [1]" in str(refused.error)

    def test_indexless_gaussian_birth_bands_may_be_reordered(self):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem and "UseChunkIndex" in p.stem]
        _require_corpus(paths, "indexed SH-degree-2 variants")
        data = paths[0].read_bytes()
        footer_record = _first_record(data, op.FOOTER)
        footer = rec.Footer.parse(footer_record.content)
        data = bytearray(data[: footer.summary_start] + rec.Footer().encode() + MAGIC)
        bands = [record for record in iter_records(bytes(data), len(MAGIC)) if record.opcode == op.SH_BAND_STREAM]
        assert len(bands) >= 2
        first, second = bands[:2]
        first_blob = bytes(data[first.offset : first.offset + 9 + len(first.content)])
        second_blob = bytes(data[second.offset : second.offset + 9 + len(second.content)])
        data[first.offset : second.offset + len(second_blob)] = second_blob + first_blob

        walked = refusal.walk(bytes(data), retain_records=False)
        assert refusal.scan_front_to_back(bytes(data), walked) is None

    def test_a_gaussian_birth_index_cannot_omit_a_physical_band(self):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem and "UseChunkIndex" in p.stem]
        _require_corpus(paths, "indexed gaussian-birth variants carrying SH bands")
        data = paths[0].read_bytes()
        first = _index_entries(data)[0]
        assert first.bands
        report = validate(
            _repack_summary(
                data,
                lambda i, entry: _with(entry, bands=entry.bands[1:]) if i == 0 else entry,
            )
        )
        assert not report.ok
        assert any("physical records following that chunk" in f.message for f in report.findings), report.findings

    def test_a_band_stream_has_the_fixed_inner_attribute_id(self):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem]
        _require_corpus(paths, "corpus variants carrying SH bands")
        data = bytearray(paths[0].read_bytes())
        band = _first_record(bytes(data), op.SH_BAND_STREAM)
        assert band is not None
        data[band.offset + 9 + 1] = op.A_POSITION
        report = validate(bytes(data))
        assert not report.ok
        assert any("inner attribute_id" in f.message for f in report.findings), report.findings

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

    @pytest.mark.parametrize("indexed", [False, True])
    def test_a_gaussian_birth_band_must_match_its_owning_chunk_shape(self, indexed):
        paths = [p for p in _variants(CORPUS) if "SHDegree2" in p.stem and "UseChunkIndex" in p.stem]
        _require_corpus(paths, "indexed SH-degree-2 variants")
        data = paths[0].read_bytes()
        if not indexed:
            # The generated matrix currently has no indexless SH fixture. Strip only the
            # optional summary from a generated file; all physical Chunks and bands stay
            # byte-for-byte identical, and the Footer declares that no index exists.
            footer_record = _first_record(data, op.FOOTER)
            footer = rec.Footer.parse(footer_record.content)
            data = data[: footer.summary_start] + rec.Footer().encode() + MAGIC
        data = bytearray(data)
        band = _first_record(bytes(data), op.SH_BAND_STREAM)
        assert band is not None
        # The stream remains completely framed and its payload length is unchanged. A
        # zero element count makes it decode to (0, channels), proving the owner-row check
        # rather than a decompressor or truncation check.
        stream_at = band.offset + 9 + 1
        struct.pack_into("<I", data, stream_at + 5, 0)
        report = validate(bytes(data))
        assert not report.ok
        assert any("owning Chunk requires" in f.message for f in report.findings), report.findings

    def test_indexed_and_streamed_keyframe_delta_bands_reject_non_byte_codes(self):
        band = put_record(
            op.SH_BAND_STREAM,
            bytes([1])
            + encode_stream(
                op.SH_BAND_STREAM,
                np.array([[-1] + [0] * 8], dtype=np.int64),
                channels=9,
                codec=0,
            ),
        )

        indexed = _patch_sh_degree(_single_keyframe_file(write_index=True), 1)
        indexed, _band_at = _insert_single_indexed_band(indexed, band)
        with pytest.raises(MalformedFile, match=r"expected 0\.\.255"):
            kdf.compose_chain(indexed, _index_entries(indexed), _index_entries(indexed)[0])

        streamed = _patch_sh_degree(_single_keyframe_file(write_index=False), 1)
        chunk = _first_record(streamed, op.CHUNK)
        after_chunk = chunk.offset + 9 + len(chunk.content)
        streamed = streamed[:after_chunk] + band + streamed[after_chunk:]
        with pytest.raises(MalformedFile, match=r"expected 0\.\.255"):
            list(kdf.scan_streamed(streamed))

    def test_indexed_gaussian_birth_bands_reject_non_byte_codes(self):
        data = _patch_sh_degree(_real_file(), 1)
        first = _index_entries(data)[0]
        values = np.zeros((first.gaussian_count, 9), dtype=np.int64)
        values[0, 0] = -1
        band = put_record(
            op.SH_BAND_STREAM,
            bytes([1]) + encode_stream(op.SH_BAND_STREAM, values, channels=9, codec=0),
        )
        malformed, _ = _insert_indexed_band(data, band)
        source = BytesReadable(malformed)
        scene = open_indexed(source)
        with pytest.raises(MalformedFile, match=r"expected 0\.\.255"):
            read_chunk(source, scene, scene.index[0], max_sh_band=1)


class TestWholeFileCompatibilityGates:
    def test_an_unknown_attribute_is_skipped_without_dispatching_its_codec(self):
        stream = bytearray(encode_stream(0x7F, np.array([[1]], dtype=np.int64), channels=1, codec=0))
        stream[1] = 3  # unknown symbol width
        stream[2] = 0xFF  # unknown mode
        stream[3] = 9  # unknown codec
        stream[4] = 0  # unknown channel semantics
        cursor = Cursor(bytes(stream))

        attribute, values = decode_stream_or_skip(cursor, frozenset(op.ATTRIBUTE_CHANNELS))

        assert attribute == 0x7F
        assert values is None
        assert cursor.remaining() == 0

    def test_a_known_empty_stream_still_rejects_an_unknown_codec(self):
        stream = bytearray(
            encode_stream(
                op.A_POSITION,
                np.zeros((0, 3), dtype=np.int64),
                channels=3,
                codec=CODEC_DEFLATE,
            )
        )
        stream[3] = 9
        with pytest.raises(UnsupportedCodec, match="unknown stream codec 9") as caught:
            decode_stream(Cursor(bytes(stream)))
        assert caught.value.code == "unknown-stream-codec"

    def test_header_sh_degree_is_limited_to_the_version_one_registry(self):
        header = _first_record(_single_keyframe_file(write_index=False), op.HEADER)
        content = bytearray(header.content)
        # Re-encode to locate the fixed one-byte field without depending on the
        # lengths of the profile, library, or temporal-model strings.
        parsed = rec.Header.parse(content)
        parsed.sh_degree = 4
        malformed = next(iter_records(parsed.encode()))
        with pytest.raises(MalformedFile, match=r"sh_degree 4.*0 through 3"):
            rec.Header.parse(malformed.content)

    @pytest.mark.parametrize(
        ("opcode", "mutate", "code"),
        [
            (
                op.HEADER,
                lambda value: setattr(value, "temporal_model", "future-model"),
                "unknown-temporal-model",
            ),
            (
                op.QUANTIZATION,
                lambda value: setattr(value, "scheme", "uniform-v9"),
                "unknown-quantization-scheme",
            ),
        ],
    )
    def test_a_later_gaussian_birth_compatibility_record_is_still_gated(self, opcode, mutate, code):
        data = _real_file()
        original = _first_record(data, opcode)
        value = rec.Header.parse(original.content) if opcode == op.HEADER else rec.Quantization.parse(original.content)
        mutate(value)
        later = next(iter_records(value.encode()))
        report = validate(_splice(data, later))
        named = [f.refusal for f in report.findings if f.refusal is not None]
        refusal_ = next(item for item in named if item.code == code)
        assert refusal_.site is not None
        assert refusal_.site.offset != original.offset

    def test_a_gaussian_birth_stream_uses_the_registry_channel_count(self):
        data = _real_file(write_index=False)
        chunk = _first_record(data, op.CHUNK)
        head, streams = rec.parse_chunk(chunk.content)
        assert head.compression == ""
        cursor = Cursor(bytes(streams))
        rewritten: list[bytes] = []
        while cursor.remaining():
            start = cursor.pos
            attribute, _values = decode_stream(cursor)
            if attribute == op.A_POSITION:
                rewritten.append(
                    encode_stream(
                        attribute,
                        np.zeros((head.count, 1), dtype=np.int64),
                        channels=1,
                    )
                )
            else:
                rewritten.append(bytes(cursor.buf[start : cursor.pos]))
        replacement = rec.encode_chunk(head.t0, head.t1, head.level, head.count, b"".join(rewritten))
        malformed = data[: chunk.offset] + replacement + data[chunk.offset + 9 + len(chunk.content) :]

        report = validate(malformed)
        assert not report.ok
        assert any("attribute 0 declares 1 channels; the registry says 3" in f.message for f in report.findings)

    def test_a_gaussian_birth_chunk_rejects_gaussian_id(self):
        data = _real_file(write_index=False)
        chunk = _first_record(data, op.CHUNK)
        head, streams = rec.parse_chunk(chunk.content)
        identities = encode_stream(
            op.A_GAUSSIAN_ID,
            np.arange(head.count, dtype=np.int64).reshape(-1, 1),
            channels=1,
            codec=0,
        )
        replacement = rec.encode_chunk(
            head.t0,
            head.t1,
            head.level,
            head.count,
            bytes(streams) + identities,
        )
        malformed = data[: chunk.offset] + replacement + data[chunk.offset + 9 + len(chunk.content) :]

        report = validate(malformed)
        assert not report.ok
        assert any("gaussian-birth chunk carries gaussian_id" in f.message for f in report.findings)


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
        assert walk.cut.at == len(whole) // 2
        assert walk.records[-1].offset == walk.cut.record_at
        assert not walk.trailing_magic

    def test_a_cut_after_a_complete_index_stays_a_validation_report(self):
        whole = _real_file()
        footer = _first_record(whole, op.FOOTER)
        cut = whole[: footer.offset + 10]
        report = validate(cut)
        assert not report.ok
        assert any(f"cut at byte {len(cut):,}" in finding.message for finding in report.findings)


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

    def test_an_indexed_keyframe_delta_file_is_composed_in_one_linear_scan(self, monkeypatch):
        """Validating every entry with `compose_chain` recomposes the whole prefix, making
        a long chained GOP quadratic. The validator applies each physical delta exactly
        once while retaining only the current and GOP-keyframe states."""
        from fourdgs import keyframe_delta_file

        original = keyframe_delta_file._compose_delta
        calls = 0

        def watched(*args, **kwargs):
            nonlocal calls
            calls += 1
            return original(*args, **kwargs)

        monkeypatch.setattr(keyframe_delta_file, "_compose_delta", watched)
        data = _keyframe_file()
        report = validate(data)
        assert report.ok, [str(f) for f in report.findings]
        expected = sum(entry.kind == 1 for entry in _index_entries(data))
        assert expected > 1, "the fixture must carry more than one delta for this to prove anything"
        assert calls == expected

    def test_bounded_indexed_identity_fallback_keeps_timeline_order(self, monkeypatch):
        states = [
            kdf.State(ids=np.array([0]), bins={}),
            kdf.State(ids=np.array([2]), bins={}),
        ]

        def indexed(*_args, **_kwargs):
            for i, state in enumerate(states):
                yield rec.ChunkIndexEntry(float(i), float(i + 1), i, 0, 1), state

        def streamed(*_args, **_kwargs):
            raise AssertionError("an indexed fallback must not switch to physical record order")

        monkeypatch.setattr(kdf, "scan_indexed", indexed)
        monkeypatch.setattr(kdf, "scan_streamed", streamed)
        assert kdf.count_distinct_ids_bounded(b"", capacity=1, index=[], windows=[]) == 2

    def test_an_indexed_keyframe_delta_file_keeps_two_states_at_most(self):
        import weakref

        data = _keyframe_file()
        opened = kdf.open_indexed(data)
        seen: list[weakref.ref] = []
        for _entry, state in kdf.scan_indexed(data, opened.index, opened.windows):
            seen.append(weakref.ref(state.ids))
            del state
            alive = [ref for ref in seen if ref() is not None]
            assert len(alive) <= 2, f"{len(alive)} states resident at once"
        assert len(seen) > 2, "the fixture must carry more than two chunks for this to prove anything"

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

    def test_an_unindexed_delta_depth_must_match_its_selected_reference(self):
        data = _keyframe_file(write_index=False)
        delta = _first_record(data, op.DELTA_CHUNK)
        patched = bytearray(data)
        # t0, t1, level, mode, reference_offset, keyframe_offset, then u16 depth.
        struct.pack_into("<H", patched, delta.offset + 9 + 37, 7)
        report = validate(bytes(patched))
        assert not report.ok
        assert any("selected reference requires depth" in finding.message for finding in report.findings)

    def test_an_unindexed_delta_must_name_the_keyframe_its_chain_reaches(self):
        data = bytearray(_keyframe_file(write_index=False))
        delta = _first_record(bytes(data), op.DELTA_CHUNK)
        # t0, t1, level, mode, reference_offset, then keyframe_offset.
        struct.pack_into("<Q", data, delta.offset + 9 + 29, delta.offset)
        report = validate(bytes(data))
        assert not report.ok
        assert any(
            "declares keyframe_offset" in finding.message and "chain reaches" in finding.message
            for finding in report.findings
        )

    def test_an_unindexed_delta_level_must_match_its_selected_reference(self):
        data = bytearray(_keyframe_file(write_index=False))
        delta = _first_record(bytes(data), op.DELTA_CHUNK)
        # t0, t1, then u32 level.
        struct.pack_into("<I", data, delta.offset + 9 + 16, 7)
        report = validate(bytes(data))
        assert not report.ok
        assert any(
            "its reference at" in finding.message and "declares level" in finding.message for finding in report.findings
        )

    def test_an_unindexed_keyframe_refusal_keeps_its_record_site(self):
        data = bytearray(_keyframe_file(write_index=False))
        chunk = _first_record(bytes(data), op.CHUNK)
        _head, streams = rec.parse_chunk(chunk.content)
        stream_at = chunk.offset + 9 + len(chunk.content) - len(streams)
        data[stream_at + 3] = 9
        report = validate(bytes(data))
        named = [finding.refusal for finding in report.findings if finding.refusal is not None]
        refusal_ = next(item for item in named if item.code == "unknown-stream-codec")
        assert refusal_.site is not None
        assert refusal_.site.offset == chunk.offset

    def test_validation_framing_does_not_retain_one_object_per_record(self):
        data = _keyframe_file(write_index=False)
        framed = refusal.walk(data, retain_records=False)
        assert framed.record_count > 2
        assert framed.records == []
        assert sum(1 for _ in framed.intact_records()) == framed.intact()


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


def _patch_sh_degree(data: bytes, degree: int) -> bytes:
    record = _first_record(data, op.HEADER)
    header = rec.Header.parse(record.content)
    before = header.encode()
    header.sh_degree = degree
    after = header.encode()
    assert len(before) == len(after)
    return data[: record.offset] + after + data[record.offset + len(before) :]


def _single_keyframe_file(*, write_index: bool, codec: int = CODEC_DEFLATE) -> bytes:
    duration = 1.0
    sample = Sample(
        t0=0.0,
        ids=np.array([7]),
        gaussians=_keyframe_gaussians([[0.0, 0.0, 0.0]], duration, None),
    )
    return kdf.write_sequence(
        [sample],
        duration,
        kd=KeyframeDeltaOptions(keyframe_every=1),
        write_index=write_index,
        codec=codec,
    )


def _insert_single_indexed_band(data: bytes, band: bytes) -> tuple[bytes, int]:
    footer_record = _first_record(data, op.FOOTER)
    footer = rec.Footer.parse(footer_record.content)
    entries = _index_entries(data)
    assert len(entries) == 1
    band_at = footer.summary_start
    entry = _with(entries[0], bands=[(1, band_at, len(band))])
    summary_records = [
        record
        for record in iter_records(data, footer.summary_start)
        if record.offset < footer_record.offset and record.opcode != op.CHUNK_INDEX
    ]
    summary = entry.encode() + b"".join(put_record(record.opcode, bytes(record.content)) for record in summary_records)
    footer.summary_start += len(band)
    if footer.summary_crc:
        footer.summary_crc = crc32(summary)
    return data[:band_at] + band + summary + footer.encode() + MAGIC, band_at


def _insert_indexed_band(data: bytes, band: bytes) -> tuple[bytes, int]:
    """Insert `band` before the summary and attach it to the first index entry."""
    footer_record = _first_record(data, op.FOOTER)
    footer = rec.Footer.parse(footer_record.content)
    band_at = footer.summary_start
    summary = b""
    entry_index = 0
    for record in iter_records(data, footer.summary_start):
        if record.offset >= footer_record.offset:
            break
        if record.opcode == op.CHUNK_INDEX:
            entry = rec.ChunkIndexEntry.parse(record.content)
            if entry_index == 0:
                entry = _with(entry, bands=[*entry.bands, (1, band_at, len(band))])
            summary += entry.encode()
            entry_index += 1
        else:
            summary += put_record(record.opcode, bytes(record.content))
    assert entry_index > 0
    footer.summary_start += len(band)
    if footer.summary_crc:
        footer.summary_crc = crc32(summary)
    return data[:band_at] + band + summary + footer.encode() + MAGIC, band_at


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
