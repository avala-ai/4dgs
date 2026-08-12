#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The cross-language encode gate: prove an encoder against a shared reference.

    python3 tests/conformance/encode_roundtrip.py --encoder cpp
    python3 tests/conformance/encode_roundtrip.py --encoder swift
    python3 tests/conformance/encode_roundtrip.py --encoder typescript
    python3 tests/conformance/encode_roundtrip.py --encoder dart
    python3 tests/conformance/encode_roundtrip.py --encoder rust    # self-check

The corpus proves decoders against files the reference *encoder* wrote. This proves an
encoder, and it does it without a second corpus. Every encode family ships one small CLI —
`<encoder> <in.4dgs> <out.4dgs> [sh-bit-depths]` — that decodes a variant, re-encodes the
gaussians it yielded with a fixed option preset, and writes the result. The preset drops
every non-gaussian record, because these authoring surfaces write gaussians and cannot
reproduce audio, cameras, attachments or provenance a variant happens to carry.

The gate: encode the same variant with `encode_gaussians` (the Rust reference) and with the
candidate, decode BOTH with the Python reference decoder, and require identical canonical
gaussian state. For C++ and Swift, which reach the Rust encoder through the C ABI, the files
also have identical layout and derived metadata. Genuine second encoders make independent
layout, partition and quantization choices; those fields are validated against the candidate's
own reconstructed state rather than compared byte-for-byte with Rust's choices.

A second pass repeats this for the spherical-harmonic variants at per-band bit depths, where
the coefficients one encoder coarsened must come back out of the decoder as the same bytes
and the declared depths must read as the ones that were written.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

sys.path.insert(0, os.path.join(ROOT, "python", "fourdgs"))
sys.path.insert(0, HERE)

import fourdgs
from canonical import canonical, summarize
from fourdgs import opcode
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.quantization import support_k
from fourdgs.readable import FileReadable
from fourdgs.serialization import MAGIC
from fourdgs.stream_reader import window_table_or_default

EXE = ".exe" if os.name == "nt" else ""

RUST_BIN = os.path.join(ROOT, "target", "release")
CPP_BUILD = os.path.join(ROOT, "cpp", "build", "conformance")
SWIFT_BIN = os.path.join(ROOT, "swift", ".build", "release")
TYPESCRIPT_DIST = os.path.join(ROOT, "typescript", "conformance", "dist")
DART_BIN = os.path.join(ROOT, "dart", "conformance", "build")

#: The shared baseline every candidate is diffed against.
REFERENCE = [os.path.join(RUST_BIN, "encode_gaussians" + EXE)]

#: family -> the CLI that re-encodes one variant. A new encoder adds one line, the same way
#: the decode harness adds a runner.
ENCODERS = {
    "rust": [os.path.join(RUST_BIN, "encode_gaussians" + EXE)],
    "cpp": [os.path.join(CPP_BUILD, "encode_roundtrip" + EXE)],
    "swift": [os.path.join(SWIFT_BIN, "encode_roundtrip" + EXE)],
    "typescript": ["node", os.path.join(TYPESCRIPT_DIST, "encode_roundtrip.js")],
    "dart": [os.path.join(DART_BIN, "encode_roundtrip" + EXE)],
}

#: The per-band depths the SH pass re-encodes at, band 1 first. Passed as a comma-separated
#: list rather than a ladder name so every encoder parses the same thing without carrying the
#: ladder registry. A writer takes as many as its degree needs and declares exactly those.
SH_LADDER_DEPTHS = [6, 4, 3]
SH_LADDER = ",".join(str(depth) for depth in SH_LADDER_DEPTHS)

#: Encoders that are genuine second implementations rather than bindings over the Rust core.
#: A binding produces byte-identical files to the reference, so the gate compares everything;
#: a second encoder makes its own byte-layout choices — how well deflate did, which order
#: gaussians sit in a chunk — that are legitimately its own and are not part of what the file
#: means. Summary byte offsets and the producer string are dropped for both. Dart's temporal
#: partition is also independent, so its intervals and derived chunk count are checked by the
#: geometry gate rather than compared with Rust's. TypeScript retains the pre-existing exact
#: interval/count comparison until its own geometry gate proves that feature directly.
SECOND_ENCODERS = frozenset({"typescript", "dart"})
#: Encoders whose round-trip CLI accepts the optional per-band depth argument. Dart's
#: first independent writer proves its fixed quantization preset here; its CLI does not
#: yet expose graded SH depths, so passing a third argument would test argv parsing rather
#: than an encoder feature it claims.
SH_LADDER_ENCODERS = frozenset(set(ENCODERS) - {"dart"})
#: Gaussian-only Dart output deliberately clears the source's capture profile. Keep that
#: compatibility normalization local to Dart: TypeScript's profile is part of the state
#: its independent encoder must preserve.
CAPTURE_PROFILE_NORMALIZATION_ENCODERS = frozenset({"dart"})
#: Encoders whose feature claim includes their own temporal partition. Add a family only
#: in its language PR, once its writer proves reconstructed support is range-seekable.
CHUNK_GEOMETRY_ENCODERS = frozenset({"dart"})
#: Encoders whose Header and Statistics bounds are derived from their independently
#: reconstructed positions. The geometry check proves those bounds contain exactly the
#: public f32 state; an exact comparison with Rust's independently quantized positions would
#: reject valid files while failing to prove the invariant readers rely on.
AABB_GEOMETRY_ENCODERS = frozenset({"dart"})
LAYOUT_DEPENDENT_KEYS = ("summaryOffsets", "library")
RECORD_HEADER = struct.Struct("<BQ")


def variants() -> list[str]:
    return sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))


def decode_canonical(path: str) -> str:
    scene = fourdgs.read(path)
    return canonical(
        summarize(
            scene.header,
            scene.gaussians,
            scene.audio_sources,
            [(e.t0, e.t1) for e in scene.chunk_index],
            camera=scene.camera,
            metadata=scene.metadata,
            attachments=scene.attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
            provenance=scene.provenance,
        )
    )


def encode(command: list[str], source: str, out: str, ladder: str | None) -> None:
    argv = [*command, source, out]
    if ladder is not None:
        argv.append(ladder)
    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} failed on {os.path.basename(source)}:\n{result.stderr.strip()}")


def compare(
    reference: list[str],
    candidate: list[str],
    source: str,
    tmp: str,
    ladder: str | None,
    second_encoder: bool,
    check_chunk_geometry: bool,
    check_aabb_geometry: bool,
    normalize_capture_profile: bool,
) -> None:
    ref_out = os.path.join(tmp, "reference.4dgs")
    cand_out = os.path.join(tmp, "candidate.4dgs")
    encode(reference, source, ref_out, ladder)
    encode(candidate, source, cand_out, ladder)
    ref = json.loads(decode_canonical(ref_out))
    cand = json.loads(decode_canonical(cand_out))
    if check_chunk_geometry:
        _check_chunk_geometry(cand_out)
    if check_aabb_geometry:
        _check_aabb_geometry(cand_out)
    if second_encoder:
        for key in LAYOUT_DEPENDENT_KEYS:
            ref.pop(key, None)
            cand.pop(key, None)
        if check_aabb_geometry:
            for summary in (ref, cand):
                statistics = summary.get("statistics")
                if statistics is not None:
                    statistics.pop("aabb", None)
        if check_chunk_geometry:
            for summary in (ref, cand):
                summary.pop("chunkIntervals", None)
                statistics = summary.get("statistics")
                if statistics is not None:
                    statistics.pop("chunkCount", None)
        # Dart deliberately clears `capture`: this gaussian-only preset does not
        # promise the source's original Statistics/multi-chunk capture shape. Rust
        # preserves the string even though the layout comparison is already removed.
        # Normalize the two legal spellings before comparing reconstructed state.
        if normalize_capture_profile and {ref.get("profile"), cand.get("profile")} <= {"", "capture"}:
            ref.pop("profile", None)
            cand.pop("profile", None)
        # Gaussian-only authoring surfaces do not reproduce the Object Table. The Rust
        # reference currently drops object_id with it, while Dart preserves the optional
        # gaussian lane. Dart's fidelity gate proves that lane one-to-one against the source;
        # remove the resulting object-derived canonical sections from this agreement check.
        if normalize_capture_profile and (ref.get("profile") == "objects" or cand.get("profile") == "objects"):
            for summary in (ref, cand):
                summary.pop("profile", None)
                summary.pop("objects", None)
                summary.pop("states", None)
                summary.get("sample", {}).pop("objectIds", None)
    if ref != cand:
        raise AssertionError(_diff(json.dumps(ref), json.dumps(cand)))
    if ladder is not None:
        _check_declared_depths(cand_out)


def _check_chunk_geometry(path: str) -> None:
    """Every candidate Chunk is indexed once and its interval contains its support.

    A streamed canonical decode visits every Chunk, so equal reconstructed state alone
    cannot prove that an indexed seek can find that state. Layout may differ from the
    reference encoder; this invariant may not.
    """
    with FileReadable(path) as source:
        scene = open_indexed(source)
        chunks, physical_bands = _physical_geometry(source)
        indexed_chunks = [(entry.chunk_offset, entry.chunk_length) for entry in scene.index]
        physical_chunks = sorted((offset, length) for offset, (length, _, _) in chunks.items())
        if sorted(indexed_chunks) != physical_chunks:
            raise AssertionError(
                "the Chunk Index must name every complete Chunk range exactly once; "
                f"chunks are {physical_chunks}, index names {sorted(indexed_chunks)}"
            )

        indexed_bands = sorted(band_range for entry in scene.index for band_range in entry.bands)
        all_physical_bands = sorted(band for bands in physical_bands.values() for band in bands)
        if indexed_bands != all_physical_bands:
            raise AssertionError(
                "the Chunk Index must name every complete SH band range exactly once; "
                f"bands are {all_physical_bands}, index names {indexed_bands}"
            )

        if scene.statistics is not None and scene.statistics.chunk_count != len(chunks):
            raise AssertionError(
                f"Statistics declares {scene.statistics.chunk_count} chunks, the candidate contains {len(chunks)}"
            )
        _check_summary_offset_geometry(source, scene.summary_offsets, require_chunk_index=bool(scene.index))

        table = window_table_or_default(scene.windows)
        k = support_k(scene.header.cutoff)
        clock_end = max(scene.header.duration_sec, 1e-9)
        indexed_gaussians = 0
        for number, entry in enumerate(scene.index):
            if not (entry.t0 < entry.t1):
                raise AssertionError(f"chunk index entry {number} has invalid interval [{entry.t0}, {entry.t1})")
            _, physical_t0, physical_t1 = chunks[entry.chunk_offset]
            if entry.t0 != physical_t0 or entry.t1 != physical_t1:
                raise AssertionError(
                    f"chunk index entry {number} declares interval [{entry.t0}, {entry.t1}), "
                    f"its Chunk declares [{physical_t0}, {physical_t1})"
                )

            owned_bands = sorted(physical_bands.get(entry.chunk_offset, []))
            if sorted(entry.bands) != owned_bands:
                raise AssertionError(
                    f"chunk index entry {number} names SH ranges {sorted(entry.bands)}, "
                    f"but the Chunk at {entry.chunk_offset} owns {owned_bands}"
                )

            expected_bands = set(range(1, int(scene.header.sh_degree) + 1))
            entry_bands = [band for band, _, _ in entry.bands]
            if set(entry_bands) != expected_bands or len(entry_bands) != len(expected_bands):
                raise AssertionError(
                    f"chunk index entry {number} names SH bands {entry_bands}, "
                    f"Header degree {scene.header.sh_degree} requires {sorted(expected_bands)}"
                )
            chunk = read_chunk(source, scene, entry, max_sh_band=int(scene.header.sh_degree))
            if set(chunk["sh"]) != expected_bands:
                raise AssertionError(
                    f"indexed read of chunk {number} returned SH bands {sorted(chunk['sh'])}, "
                    f"expected {sorted(expected_bands)}"
                )
            count = len(chunk["mu_t"])
            if count != entry.gaussian_count:
                raise AssertionError(
                    f"chunk index entry {number} declares {entry.gaussian_count} gaussians, its Chunk has {count}"
                )
            indexed_gaussians += count

            # Canonical gaussian state is f32 even though read_chunk has f64
            # intermediates. Round first, then widen for the support arithmetic
            # and apply the same sigma floor as state_at.
            sigma = np.asarray(chunk["sigma_t"], dtype=np.float32).astype(np.float64)
            mu = np.asarray(chunk["mu_t"], dtype=np.float32).astype(np.float64)
            half = np.where(np.isfinite(sigma), k * np.maximum(sigma, 1e-30), np.inf)
            windows = table[chunk["window_index"]]
            window_lo = np.maximum(windows[:, 0], 0.0)
            window_hi = np.minimum(windows[:, 1], clock_end)
            lo = np.maximum(mu - half, window_lo)
            hi = np.minimum(mu + half, window_hi)
            # t1 is half-open. Equality is safe only when the gaussian's own
            # validity window also ends there, so it is not visible at t1.
            outside = (lo < entry.t0) | (hi > entry.t1) | ((hi == entry.t1) & (window_hi > entry.t1))
            if np.any(outside):
                gaussian = int(np.flatnonzero(outside)[0])
                raise AssertionError(
                    f"chunk index entry {number} [{entry.t0}, {entry.t1}) omits support "
                    f"[{lo[gaussian]}, {hi[gaussian]}] for gaussian {gaussian} in its Chunk"
                )

        if indexed_gaussians != scene.header.gaussian_count:
            raise AssertionError(
                f"the index reaches {indexed_gaussians} gaussians, Header declares {scene.header.gaussian_count}"
            )


def _check_aabb_geometry(path: str) -> None:
    """Header and Statistics bounds equal the candidate's public f32 extrema."""
    scene = fourdgs.read(path)
    actual = scene.gaussians.aabb()

    declared = [("Header", scene.header.aabb)]
    if scene.statistics is not None:
        declared.append(("Statistics", scene.statistics.aabb))
        if list(scene.statistics.aabb) != list(scene.header.aabb):
            raise AssertionError(
                f"Statistics AABB {scene.statistics.aabb} does not match Header AABB {scene.header.aabb}"
            )

    for record, bounds in declared:
        _check_declared_aabb(record, bounds, actual)


def _check_declared_aabb(record: str, bounds: list[float], actual: list[float]) -> None:
    if len(bounds) != 6:
        raise AssertionError(f"{record} AABB has {len(bounds)} values, expected 6")
    if not all(np.isfinite(bounds)):
        raise AssertionError(f"{record} AABB {bounds} contains a non-finite bound")
    for axis in range(3):
        if bounds[axis] > bounds[3 + axis]:
            raise AssertionError(f"{record} AABB {bounds} is inverted on axis {axis}")
        if bounds[axis] != actual[axis] or bounds[3 + axis] != actual[3 + axis]:
            raise AssertionError(
                f"{record} AABB {bounds} does not equal reconstructed axis {axis} "
                f"range [{actual[axis]}, {actual[3 + axis]}]"
            )


def _physical_geometry(
    source: FileReadable,
) -> tuple[dict[int, tuple[int, float, float]], dict[int, list[tuple[int, int, int]]]]:
    """Return physical Chunk and SH ranges from a bounded framing scan.

    Only the 16-byte Chunk interval and one-byte SH label are read from payloads. The
    encoded streams themselves remain untouched, however large the candidate file is.
    """
    payload_end = source.size() - len(MAGIC)
    if payload_end < len(MAGIC) or source.read(payload_end, len(MAGIC)) != MAGIC:
        raise AssertionError("candidate has no final magic")

    chunks: dict[int, tuple[int, float, float]] = {}
    bands: dict[int, list[tuple[int, int, int]]] = {}
    band_owner: int | None = None
    offset = len(MAGIC)
    while offset < payload_end:
        if offset + RECORD_HEADER.size > payload_end:
            raise AssertionError(f"record header at offset {offset} overlaps the final magic")
        record_opcode, length = RECORD_HEADER.unpack(source.read(offset, RECORD_HEADER.size))
        record_end = offset + RECORD_HEADER.size + length
        if record_end > payload_end:
            raise AssertionError(f"record at offset {offset} ends at {record_end}, beyond payload end {payload_end}")
        if record_opcode == opcode.CHUNK:
            if length < 16:
                raise AssertionError(f"Chunk at offset {offset} is {length} bytes, too short for its interval")
            t0, t1 = struct.unpack("<dd", source.read(offset + RECORD_HEADER.size, 16))
            chunks[offset] = (RECORD_HEADER.size + length, t0, t1)
            bands[offset] = []
            band_owner = offset
        elif record_opcode == opcode.SH_BAND_STREAM:
            if length < 1:
                raise AssertionError(f"SH band at offset {offset} has no band label")
            if band_owner is None:
                raise AssertionError(f"SH band at offset {offset} does not follow a Chunk")
            band = source.read(offset + RECORD_HEADER.size, 1)[0]
            bands[band_owner].append((band, offset, RECORD_HEADER.size + length))
        else:
            band_owner = None
        offset = record_end
    return chunks, bands


def _check_summary_offset_geometry(
    source: FileReadable,
    declared: list,
    *,
    require_chunk_index: bool = False,
) -> None:
    """Every candidate Summary Offset frames its own complete summary-record class."""
    footer_offset = source.size() - len(MAGIC) - RECORD_HEADER.size - 20
    footer_opcode, footer_length = RECORD_HEADER.unpack(source.read(footer_offset, RECORD_HEADER.size))
    if footer_opcode != opcode.FOOTER or footer_length < 20:
        raise AssertionError(f"candidate Footer at {footer_offset} is not a complete Footer record")
    summary_start, summary_offset_start = struct.unpack("<QQ", source.read(footer_offset + RECORD_HEADER.size, 16))
    if summary_start == 0:
        if declared:
            raise AssertionError("candidate declares Summary Offsets without a summary region")
        if summary_offset_start != 0:
            raise AssertionError("candidate Footer declares a summary_offset_start without a summary region")
        if require_chunk_index:
            raise AssertionError("candidate writes an index but declares no summary region")
        return
    summary_opcodes = {opcode.CHUNK_INDEX, opcode.STATISTICS, opcode.SUMMARY_OFFSET}
    physical: dict[int, list[tuple[int, int]]] = {}
    offset = summary_start
    while offset < footer_offset:
        if offset + RECORD_HEADER.size > footer_offset:
            raise AssertionError(f"summary record header at {offset} overlaps the Footer")
        record_opcode, length = RECORD_HEADER.unpack(source.read(offset, RECORD_HEADER.size))
        end = offset + RECORD_HEADER.size + length
        if end > footer_offset:
            raise AssertionError(f"summary record at {offset} extends into the Footer")
        if record_opcode not in summary_opcodes:
            raise AssertionError(
                f"summary record at {offset} has opcode {record_opcode:#04x}; expected only "
                "Chunk Index, Statistics, or Summary Offset records"
            )
        physical.setdefault(record_opcode, []).append((offset, end - offset))
        offset = end

    physical_offsets = physical.get(opcode.SUMMARY_OFFSET, [])
    expected_offset_start = physical_offsets[0][0] if physical_offsets else 0
    if summary_offset_start != expected_offset_start:
        raise AssertionError(f"Footer summary_offset_start is {summary_offset_start}, expected {expected_offset_start}")

    index_declarations = [item for item in declared if item.group_opcode == opcode.CHUNK_INDEX]
    if require_chunk_index and len(index_declarations) != 1:
        raise AssertionError(
            "an indexed Dart preset must declare exactly one Chunk Index Summary Offset; "
            f"found {len(index_declarations)}"
        )

    seen: set[int] = set()
    for number, summary_offset in enumerate(declared):
        group_opcode = summary_offset.group_opcode
        if group_opcode in seen:
            raise AssertionError(f"Summary Offset {number} repeats group opcode {group_opcode:#04x}")
        seen.add(group_opcode)
        start = summary_offset.group_start
        length = summary_offset.group_length
        end = start + length
        if length <= 0 or start < summary_start or end > footer_offset:
            raise AssertionError(
                f"Summary Offset {number} range [{start}, {end}) is not a nonempty range "
                f"inside summary [{summary_start}, {footer_offset})"
            )
        expected = physical.get(group_opcode, [])
        if not expected:
            raise AssertionError(
                f"Summary Offset {number} names opcode {group_opcode:#04x}, "
                "but the summary contains no record of that class"
            )
        if expected[0][0] != start or expected[-1][0] + expected[-1][1] != end:
            raise AssertionError(
                f"Summary Offset {number} range [{start}, {end}) does not frame all "
                f"opcode {group_opcode:#04x} records {expected}"
            )
        if any(at + record_length != next_at for (at, record_length), (next_at, _) in itertools.pairwise(expected)):
            raise AssertionError(f"Summary Offset {number} opcode {group_opcode:#04x} records are not contiguous")


def _check_declared_depths(path: str) -> None:
    """The candidate declared its depths, per-band bounds, and coarsest fallback fields.

    A file whose coefficients and whose declaration disagree passes the canonical diff on its
    data and fails here on its metadata, or the reverse — which is why both are checked.
    """
    scene = fourdgs.read(path)
    quant = scene.quantization
    degree = int(scene.header.sh_degree)
    expected = SH_LADDER_DEPTHS[:degree]
    if quant.sh_bit_depths != expected:
        raise AssertionError(f"declares SH bit depths {quant.sh_bit_depths}, not {expected}")
    missing = [band for band in range(1, degree + 1) if f"sh_band{band}" not in quant.bounds]
    if missing:
        raise AssertionError(f"declares depths but no bound for bands {missing}")
    wrong = []
    for band, depth in enumerate(expected, start=1):
        key = f"sh_band{band}"
        expected_bound = (1 << (8 - depth)) // 2
        try:
            found = float(quant.bounds[key])
        except (TypeError, ValueError):
            found = quant.bounds[key]
        if found != expected_bound:
            wrong.append(f"band {band}: {found!r}, expected {expected_bound}")
    if wrong:
        raise AssertionError("declares the wrong SH bound (" + "; ".join(wrong) + ")")

    coarsest_step = max(1 << (8 - depth) for depth in expected)
    coarsest_bound = coarsest_step // 2
    if quant.step_sh != coarsest_step:
        raise AssertionError(f"declares legacy step_sh {quant.step_sh}, not coarsest-band pitch {coarsest_step}")
    try:
        fallback_bound = float(quant.bounds["sh"])
    except (KeyError, TypeError, ValueError):
        fallback_bound = quant.bounds.get("sh")
    if fallback_bound != coarsest_bound:
        raise AssertionError(f"declares legacy sh bound {fallback_bound!r}, not coarsest-band bound {coarsest_bound}")


def _diff(reference: str, candidate: str) -> str:
    a = json.loads(reference)
    b = json.loads(candidate)
    lines = ["the reference and the candidate decode differently:"]
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            lines.append(f"  {key}")
            lines.append(f"    reference: {json.dumps(a.get(key))[:300]}")
            lines.append(f"    candidate: {json.dumps(b.get(key))[:300]}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="the cross-language 4dgs encode gate")
    parser.add_argument("--encoder", required=True, choices=sorted(ENCODERS), help="which encoder to prove")
    args = parser.parse_args(argv)

    if not os.path.exists(REFERENCE[-1]):
        print(
            f"error: the reference {REFERENCE[-1]} is not built; run cargo build --release --workspace", file=sys.stderr
        )
        return 1
    command = ENCODERS[args.encoder]
    if not os.path.exists(command[-1]):
        print(f"skipping {args.encoder}: {command[-1]} is not built")
        return 0

    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1

    second_encoder = args.encoder in SECOND_ENCODERS
    check_chunk_geometry = args.encoder in CHUNK_GEOMETRY_ENCODERS
    check_aabb_geometry = args.encoder in AABB_GEOMETRY_ENCODERS
    normalize_capture_profile = args.encoder in CAPTURE_PROFILE_NORMALIZATION_ENCODERS
    agreed = graded = failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for variant in names:
            source = os.path.join(DATA, f"{variant}.4dgs")
            try:
                compare(
                    REFERENCE,
                    command,
                    source,
                    tmp,
                    None,
                    second_encoder,
                    check_chunk_geometry,
                    check_aabb_geometry,
                    normalize_capture_profile,
                )
                agreed += 1
            except (AssertionError, RuntimeError) as exc:
                failed += 1
                print(f"FAIL {args.encoder} {variant}\n  {exc}")
                continue
            if "SHDegree" in variant and args.encoder in SH_LADDER_ENCODERS:
                try:
                    compare(
                        REFERENCE,
                        command,
                        source,
                        tmp,
                        SH_LADDER,
                        second_encoder,
                        check_chunk_geometry,
                        check_aabb_geometry,
                        normalize_capture_profile,
                    )
                    graded += 1
                except (AssertionError, RuntimeError) as exc:
                    failed += 1
                    print(f"FAIL {args.encoder} {variant} @ {SH_LADDER}\n  {exc}")

    print(f"\n{agreed} variants re-encoded, {graded} at per-band SH depths, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
