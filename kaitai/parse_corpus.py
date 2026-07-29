#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Compile `fourdgs.ksy` and check it against every file in the conformance corpus.

    python3 kaitai/parse_corpus.py            # compile, then check tests/conformance/data
    python3 kaitai/parse_corpus.py FILE ...   # check specific .4dgs files

Exits non-zero on the first corpus file that fails, naming the file and what went wrong.
Needs `kaitai-struct-compiler` on PATH (or in `$KAITAI_STRUCT_COMPILER`) and the
`kaitaistruct` Python runtime.

**Parsing without an exception is not the check.** A grammar that read the first field of
each record and ignored the rest would pass that, and one that dropped a field in the
middle of a record would pass it too — a fixed-size substream simply leaves the remainder
unconsumed, which is the same leniency that lets appended fields work (§4.2). So each file
is checked three ways:

1. the grammar parses it, records span it exactly, the Header is first and the Footer last;
2. every value the grammar reads from a record it models is diffed against the committed
   `.json` expectation — the reference decoder's own view of that file, which the rest of
   the conformance suite already holds every implementation to. A field this grammar
   misplaces shifts everything after it, and the diff says which one and by what;
3. the structural claims the grammar states but cannot enforce: that every offset/length
   pair in a Chunk Index frames a whole record (§5.8), that the Footer's `summary_start`
   points at the first of them and its CRC covers a contiguous run (§4.5, §5.2), and that
   the Header's audio bit agrees with whether audio records exist and every source has one
   matching payload (§7).

Check 3 is worth its lines because those rules are what a *seeking* reader depends on, and
nothing else in the suite asserts them directly: a decoder that got them wrong would fail
somewhere else, for a reason that did not name them.
"""

from __future__ import annotations

import importlib.util
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GRAMMAR = os.path.join(HERE, "fourdgs.ksy")
CORPUS = os.path.join(ROOT, "tests", "conformance", "data")

OP_HEADER = 0x01
OP_FOOTER = 0x02
OP_CHUNK = 0x05
OP_SH_BAND_STREAM = 0x07
OP_CHUNK_INDEX = 0x08
OP_AUDIO = 0x09
OP_CAMERA = 0x0A
OP_METADATA = 0x0B
OP_STATISTICS = 0x0C
OP_ATTACHMENT = 0x0D
OP_SUMMARY_OFFSET = 0x0F
OP_AUDIO_SOURCE = 0x11
OP_AUDIO_DATA = 0x12

MAGIC_LEN = 8
RECORD_HEADER = struct.Struct("<BQ")

#: `canonical.py` rounds every float to this many decimals before comparison, so the
#: expectation is only as precise as that and this must match it exactly.
FLOAT_DECIMALS = 6
#: `canonical.py` emits at most this many camera keyframes in full.
CAMERA_KEYFRAMES = 4
AUDIO_KEYFRAMES = 4

#: The keys of the canonical summary that follow from structure alone. The rest —
#: `sample`, `aggregate`, `sh` — needs the attribute streams decoded, dequantized and
#: sorted, which is decoding and not this grammar's job.
STRUCTURAL_KEYS = (
    "gaussianCount",
    "durationSec",
    "cutoff",
    "shDegree",
    "temporalModel",
    "hasAudio",
    "audioSources",
    "chunkIntervals",
    "headerAttributes",
    "metadataRecords",
    "attachments",
    "camera",
    "statistics",
    "summaryOffsets",
    "summaryCrcOk",
)

#: Structural keys the summary does not carry yet. Compared when the expectation has them
#: and skipped when it does not, so that widening `canonical.py` widens this check by
#: itself rather than needing a matching edit here — and so that this file does not fail
#: on a corpus generated before the widening.
OPTIONAL_KEYS = ("profile", "library")


def compile_grammar(outdir: str):
    """Run the Kaitai compiler over the grammar and import what it produced."""
    ksc = os.environ.get("KAITAI_STRUCT_COMPILER", "kaitai-struct-compiler")
    proc = subprocess.run(
        [ksc, "--target", "python", "--outdir", outdir, GRAMMAR],
        capture_output=True,
        text=True,
        check=False,
    )
    # The compiler reports recoverable problems on stdout and still exits 0. A warning
    # about this grammar is a defect in this grammar, so it fails here too.
    noise = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0 or noise:
        print(f"kaitai-struct-compiler failed on {GRAMMAR}:", file=sys.stderr)
        print(noise or f"exit status {proc.returncode}", file=sys.stderr)
        raise SystemExit(1)

    path = os.path.join(outdir, "fourdgs.py")
    spec = importlib.util.spec_from_file_location("fourdgs_ksy", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# Restating the canonical summary from the grammar's view of the file
# ---------------------------------------------------------------------------


def num(value):
    """Round as `canonical.py` rounds; a non-finite value becomes `null`."""
    v = float(value)
    return round(v, FLOAT_DECIMALS) if math.isfinite(v) else None


def opcode_of(record) -> int:
    op = record.opcode
    return op if isinstance(op, int) else op.value


def text(field) -> str:
    return field.value


def mapping(field) -> dict:
    return {text(e.key): text(e.value) for e in sorted(field.entries.entries, key=lambda e: text(e.key))}


def normalized_quaternion(value) -> list[float]:
    length = math.sqrt(sum(float(component) ** 2 for component in value))
    if not math.isfinite(length) or length == 0:
        return [0.0, 0.0, 0.0, 1.0]
    return [float(component) / length for component in value]


def slerp(a, b, u: float) -> list[float]:
    qa = normalized_quaternion(a)
    qb = normalized_quaternion(b)
    dot = sum(x * y for x, y in zip(qa, qb, strict=True))
    if dot < 0:
        qb = [-value for value in qb]
        dot = -dot
    dot = min(1.0, max(-1.0, dot))
    if dot > 0.9995:
        return normalized_quaternion([x + (y - x) * u for x, y in zip(qa, qb, strict=True)])
    theta = math.acos(dot)
    sin_theta = math.sin(theta)
    wa = math.sin((1 - u) * theta) / sin_theta
    wb = math.sin(u * theta) / sin_theta
    return normalized_quaternion([wa * x + wb * y for x, y in zip(qa, qb, strict=True)])


def audio_state(source, t: float) -> dict:
    start = float(source.start_sec)
    duration = float(source.duration_sec)
    loop = bool(source.loop_playback)
    elapsed = max(0.0, t - start)
    local_time = elapsed % duration if loop and duration > 0 else min(elapsed, max(0.0, duration))
    frames = source.keyframes
    if not frames:
        position = source.position
        rotation = normalized_quaternion(source.rotation)
    elif t <= frames[0].time:
        position = frames[0].position
        rotation = normalized_quaternion(frames[0].rotation)
    elif t >= frames[-1].time:
        position = frames[-1].position
        rotation = normalized_quaternion(frames[-1].rotation)
    else:
        high = next(i for i, frame in enumerate(frames) if frame.time > t)
        a, b = frames[high - 1], frames[high]
        if text(source.interpolation) == "step":
            position = a.position
            rotation = normalized_quaternion(a.rotation)
        else:
            u = (t - a.time) / (b.time - a.time)
            position = [x + (y - x) * u for x, y in zip(a.position, b.position, strict=True)]
            rotation = slerp(a.rotation, b.rotation, u)
    return {
        "active": t >= start and (loop or t < start + duration),
        "localTime": num(local_time),
        "position": [num(value) for value in position],
        "rotation": [num(value) for value in rotation],
        "gain": num(source.gain),
    }


def audio_source_summary(source, payload: bytes, sample_time: float) -> dict:
    return {
        "sourceId": str(source.source_id),
        "name": text(source.name),
        "codec": text(source.codec),
        "channelLayout": text(source.channel_layout),
        "startSec": num(source.start_sec),
        "durationSec": num(source.duration_sec),
        "gain": num(source.gain),
        "spatial": bool(source.spatial),
        "loop": bool(source.loop_playback),
        "position": [num(value) for value in source.position],
        "rotation": [num(value) for value in source.rotation],
        "keyframeCount": str(source.num_keyframes),
        "keyframes": [
            {
                "time": num(frame.time),
                "position": [num(value) for value in frame.position],
                "rotation": [num(value) for value in frame.rotation],
            }
            for frame in source.keyframes[:AUDIO_KEYFRAMES]
        ],
        "interpolation": text(source.interpolation),
        "stateAtHalf": audio_state(source, sample_time),
        "byteLength": str(len(payload)),
        "crc": str(zlib.crc32(payload) & 0xFFFFFFFF),
    }


def summarize(parsed, data: bytes) -> dict:
    """The structural half of the canonical summary, read only through the grammar."""
    by_opcode: dict[int, list] = {}
    offsets: dict[int, list[int]] = {}
    at = MAGIC_LEN
    for record in parsed.records:
        op = opcode_of(record)
        by_opcode.setdefault(op, []).append(record.content)
        offsets.setdefault(op, []).append(at)
        at += RECORD_HEADER.size + record.len_content
    footer_start = offsets[OP_FOOTER][-1]

    header = by_opcode[OP_HEADER][0]
    footer = by_opcode[OP_FOOTER][0]

    legacy_audio = by_opcode.get(OP_AUDIO, [None])[0]
    audio_payloads = {record.source_id: record.data.data for record in by_opcode.get(OP_AUDIO_DATA, [])}
    audio_sources = [
        audio_source_summary(source, audio_payloads[source.source_id], header.duration_sec / 2)
        for source in sorted(by_opcode.get(OP_AUDIO_SOURCE, []), key=lambda item: item.source_id)
    ]
    if legacy_audio is not None:
        audio_sources = [
            {
                "sourceId": "0",
                "name": "",
                "codec": text(legacy_audio.codec),
                "channelLayout": "",
                "startSec": num(legacy_audio.start_sec),
                "durationSec": num(max(0, header.duration_sec - legacy_audio.start_sec)),
                "gain": num(1),
                "spatial": False,
                "loop": False,
                "position": [num(0), num(0), num(0)],
                "rotation": [num(0), num(0), num(0), num(1)],
                "keyframeCount": "0",
                "keyframes": [],
                "interpolation": "linear",
                "stateAtHalf": {
                    "active": header.duration_sec / 2 >= legacy_audio.start_sec,
                    "localTime": num(max(0, header.duration_sec / 2 - legacy_audio.start_sec)),
                    "position": [num(0), num(0), num(0)],
                    "rotation": [num(0), num(0), num(0), num(1)],
                    "gain": num(1),
                },
                "byteLength": str(len(legacy_audio.data.data)),
                "crc": str(zlib.crc32(legacy_audio.data.data) & 0xFFFFFFFF),
            }
        ]
    camera = by_opcode.get(OP_CAMERA, [None])[0]
    statistics = by_opcode.get(OP_STATISTICS, [None])[0]

    summary_crc_ok = None
    if footer.summary_start and footer.summary_crc:
        run = data[footer.summary_start : footer_start]
        summary_crc_ok = (zlib.crc32(run) & 0xFFFFFFFF) == footer.summary_crc

    return {
        "profile": text(header.profile),
        "library": text(header.library),
        "gaussianCount": str(header.gaussian_count),
        "durationSec": num(header.duration_sec),
        "cutoff": num(header.cutoff),
        "shDegree": int(header.sh_degree),
        "temporalModel": text(header.temporal_model),
        "hasAudio": bool(header.has_audio),
        "audioSources": audio_sources,
        "chunkIntervals": [[num(e.t0), num(e.t1)] for e in by_opcode.get(OP_CHUNK_INDEX, [])],
        "headerAttributes": mapping(header.attributes),
        "metadataRecords": [
            {"name": text(m.name), "entries": mapping(m.entries)} for m in by_opcode.get(OP_METADATA, [])
        ],
        "attachments": [
            {
                "name": text(a.name),
                "mediaType": text(a.media_type),
                "byteLength": str(len(a.data.data)),
                "crc": str(zlib.crc32(a.data.data) & 0xFFFFFFFF),
            }
            for a in by_opcode.get(OP_ATTACHMENT, [])
        ],
        "camera": None
        if camera is None
        else {
            "fovYDeg": num(camera.fov_y_deg),
            "position": [num(v) for v in camera.position],
            "target": [num(v) for v in camera.target],
            "keyframeCount": str(camera.num_keyframes),
            "keyframes": [
                {
                    "time": num(k.time),
                    "position": [num(v) for v in k.position],
                    "target": [num(v) for v in k.target],
                }
                for k in camera.keyframes[:CAMERA_KEYFRAMES]
            ],
            "interpolation": text(camera.interpolation),
            "loop": bool(camera.loop_playback),
        },
        "statistics": None
        if statistics is None
        else {
            "gaussianCount": str(statistics.gaussian_count),
            "chunkCount": str(statistics.chunk_count),
            "durationSec": num(statistics.duration_sec),
            "aabb": [num(v) for v in statistics.aabb],
        },
        "summaryOffsets": [
            {
                "groupOpcode": str(s.group_opcode if isinstance(s.group_opcode, int) else s.group_opcode.value),
                "groupStart": str(s.group_start),
                "groupLength": str(s.group_length),
            }
            for s in by_opcode.get(OP_SUMMARY_OFFSET, [])
        ],
        "summaryCrcOk": summary_crc_ok,
    }


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def frame_at(data: bytes, offset: int) -> tuple[int, int]:
    """Read the record frame at `offset`, returning `(opcode, whole_record_length)`."""
    if offset < 0 or offset + RECORD_HEADER.size > len(data):
        raise ValueError(f"offset {offset} is not inside the file")
    opcode, length = RECORD_HEADER.unpack_from(data, offset)
    return opcode, RECORD_HEADER.size + length


def check_layout(parsed, data: bytes) -> None:
    consumed = parsed._io.pos()
    if consumed != len(data):
        raise ValueError(f"grammar consumed {consumed} of {len(data)} bytes")

    opcodes = [opcode_of(r) for r in parsed.records]
    if opcodes[0] != OP_HEADER:
        raise ValueError(f"first record is opcode 0x{opcodes[0]:02X}, not the Header")
    if opcodes[-1] != OP_FOOTER:
        raise ValueError(f"last record is opcode 0x{opcodes[-1]:02X}, not the Footer")
    if opcodes.count(OP_FOOTER) != 1:
        raise ValueError(f"{opcodes.count(OP_FOOTER)} Footer records; a file has exactly one")


def check_index_ranges(parsed, data: bytes) -> None:
    """§5.8: every offset and length in the index frames a whole record."""
    entries = [r.content for r in parsed.records if opcode_of(r) == OP_CHUNK_INDEX]
    for i, entry in enumerate(entries):
        opcode, length = frame_at(data, entry.chunk_offset)
        if opcode != OP_CHUNK or length != entry.chunk_length:
            raise ValueError(
                f"chunk index entry {i}: [{entry.chunk_offset}, +{entry.chunk_length}) does not frame a "
                f"Chunk record (found opcode 0x{opcode:02X}, whole-record length {length})"
            )
        for band in entry.bands:
            opcode, length = frame_at(data, band.offset)
            if opcode != OP_SH_BAND_STREAM or length != band.length:
                raise ValueError(
                    f"chunk index entry {i}, band {band.band}: [{band.offset}, +{band.length}) does not "
                    f"frame an SH Band Stream record (found opcode 0x{opcode:02X}, length {length})"
                )

    footer = next(r.content for r in parsed.records if opcode_of(r) == OP_FOOTER)
    if footer.summary_start:
        opcode, _ = frame_at(data, footer.summary_start)
        if opcode != OP_CHUNK_INDEX:
            raise ValueError(
                f"footer summary_start {footer.summary_start} points at opcode 0x{opcode:02X}, "
                "not the first Chunk Index record"
            )
    elif entries:
        raise ValueError(f"{len(entries)} Chunk Index records but summary_start is 0")


def check_audio_bit(parsed) -> None:
    """§7: the Header's bit 0 is the entire audio signal, so it must not lie."""
    header = parsed.records[0].content
    opcodes = [opcode_of(record) for record in parsed.records]
    present = OP_AUDIO in opcodes or OP_AUDIO_SOURCE in opcodes or OP_AUDIO_DATA in opcodes
    if header.has_audio != present:
        raise ValueError(
            f"header flags say audio={header.has_audio} but audio records are {'present' if present else 'absent'}"
        )
    if OP_AUDIO in opcodes and (OP_AUDIO_SOURCE in opcodes or OP_AUDIO_DATA in opcodes):
        raise ValueError("file mixes a legacy Audio record with Audio Source/Data records")
    sources = [r.content.source_id for r in parsed.records if opcode_of(r) == OP_AUDIO_SOURCE]
    payloads = [r.content.source_id for r in parsed.records if opcode_of(r) == OP_AUDIO_DATA]
    if sorted(sources) != sorted(payloads):
        raise ValueError(f"Audio Source ids {sorted(sources)} do not match Audio Data ids {sorted(payloads)}")


def check_against_expectation(parsed, data: bytes, expectation_path: str) -> None:
    with open(expectation_path, encoding="utf-8") as fh:
        expected = json.load(fh)

    ours = summarize(parsed, data)
    for key in STRUCTURAL_KEYS + tuple(k for k in OPTIONAL_KEYS if k in expected):
        if ours[key] != expected[key]:
            raise ValueError(
                f"{key} disagrees with {os.path.basename(expectation_path)}\n"
                f"    grammar:  {json.dumps(ours[key], sort_keys=True)}\n"
                f"    expected: {json.dumps(expected[key], sort_keys=True)}"
            )


def check(module, path: str) -> str:
    with open(path, "rb") as fh:
        data = fh.read()

    parsed = module.Fourdgs.from_bytes(data)
    check_layout(parsed, data)
    check_index_ranges(parsed, data)
    check_audio_bit(parsed)

    expectation = path[: -len(".4dgs")] + ".json"
    if os.path.exists(expectation):
        check_against_expectation(parsed, data, expectation)
        return "checked against its expectation"
    return "parsed (no expectation alongside it)"


def main(argv: list[str]) -> int:
    files = argv[1:]
    if not files:
        if not os.path.isdir(CORPUS):
            print(f"no corpus at {CORPUS}; run tests/conformance/generate.py first", file=sys.stderr)
            return 1
        files = sorted(os.path.join(CORPUS, f) for f in os.listdir(CORPUS) if f.endswith(".4dgs"))
    if not files:
        print(f"no .4dgs files in {CORPUS}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as outdir:
        module = compile_grammar(outdir)
        for path in files:
            try:
                note = check(module, path)
            except Exception as exc:
                print(f"FAIL {os.path.basename(path)}: {type(exc).__name__}: {exc}", file=sys.stderr)
                return 1
            print(f"ok   {os.path.basename(path)} — {note}")

    print(f"\nthe grammar parses and agrees with the reference decoder on all {len(files)} corpus files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
