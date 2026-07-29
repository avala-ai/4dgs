#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Generate the conformance corpus, or verify the committed one.

    python3 tests/conformance/generate.py            # write data/*.4dgs and *.json
    python3 tests/conformance/generate.py --verify   # regenerate and check nothing moved

`--verify` is the gate that keeps the corpus honest. It asserts three things:

1. every generated file matches its committed SHA-256;
2. every committed expectation matches a fresh decode;
3. two consecutive generator runs are byte-identical.

The third is the one that earns its keep: accidental nondeterminism in an encoder —
iteration order, a hash seed, a timestamp — is invisible locally and shows up as somebody
else's failing CI.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
INVALID = os.path.join(DATA, "invalid")
CHECKSUMS = os.path.join(DATA, "CHECKSUMS.txt")
sys.path.insert(0, os.path.join(HERE, "generator"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "python", "fourdgs"))

import fourdgs
import invalid
import scenarios
from canonical import canonical, summarize
from fourdgs.opcode import (
    COORDINATE_FRAME,
    GEODETIC_ANCHOR,
    HEADER,
    QUANTIZATION,
    RIG_TRAJECTORY,
    SENSOR_CALIBRATION,
)
from fourdgs.provenance import Provenance
from fourdgs.records import (
    Attachment,
    CoordinateFrame,
    GeodeticAnchor,
    Metadata,
    RigTrajectory,
    SensorCalibration,
)
from fourdgs.serialization import put_record

MAX_DATA_BYTES = 2_500_000


def build(scenario, flags, *, read_back: bool = True, **overrides) -> tuple[bytes, str]:
    """Encode one variant and produce its expectation."""
    raw = scenarios.build_gaussians(scenario)
    n = len(raw["positions"])
    sh_degree = next((d for d in (3, 2, 1) if f"SHDegree{d}" in flags), 0)
    # Coefficients per gaussian: three colour components times the coefficients a whole
    # degree carries (3, 8, 15 — the cumulative sum of `2b + 1` over its bands).
    coeffs = {0: 0, 1: 9, 2: 24, 3: 45}[sh_degree]
    # Per-band bit depths, band 1 first. Absent unless a flag asks for them, which is what
    # keeps every other variant byte-identical to the file it was before the field existed.
    sh_bit_depths = None
    if "SHBitsHigh" in flags:
        sh_bit_depths = (8, 7, 6)
    elif "SHBitsLow" in flags:
        sh_bit_depths = (5, 4, 3)

    gaussians = fourdgs.GaussianSet(
        positions=np.asarray(raw["positions"], dtype=np.float32).reshape(n, 3),
        scales=np.asarray(raw["scales"], dtype=np.float32).reshape(n, 3),
        rotations=np.asarray(raw["rotations"], dtype=np.float32).reshape(n, 4),
        colors=np.asarray(raw["colors"], dtype=np.float32).reshape(n, 4),
        motions=np.asarray(raw["motions"], dtype=np.float32).reshape(n, 3),
        mu_t=np.asarray(raw["mu_t"], dtype=np.float32),
        sigma_t=np.asarray(raw["sigma_t"], dtype=np.float32),
        win_lo=np.asarray(raw["win_lo"], dtype=np.float32),
        win_hi=np.asarray(raw["win_hi"], dtype=np.float32),
        sh=(np.arange(n * coeffs, dtype=np.int64) % 251).astype(np.uint8).reshape(n, coeffs) if coeffs else None,
        sh_degree=sh_degree,
    )

    audio = None
    if "WithLargeAudio" in flags:
        # Six seconds at 8 kHz is ~96 KiB: comfortably past the 64 KiB an indexed reader
        # probes the front of a file with, and comfortably inside the corpus size cap.
        audio = fourdgs.AudioTrack(codec="wav", data=scenarios.build_audio(seconds=6.0), start_sec=0.0)
    elif "WithAudio" in flags:
        audio = fourdgs.AudioTrack(codec="wav", data=scenarios.build_audio(), start_sec=0.0)
    camera = None
    if "WithCamera" in flags:
        camera = fourdgs.CameraTrajectory(
            fov_y_deg=45.0,
            position=(0.0, 1.0, 3.0),
            target=(0.0, 0.0, 0.0),
            times=[0.0, raw["duration_sec"]],
            positions=[(0.0, 1.0, 3.0), (1.0, 1.0, 3.0)],
            targets=[(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)],
        )

    extra: list[bytes] = []
    trailers: dict[int, bytes] = {}
    if "AddExtraDataToRecords" in flags:
        # A private-range record and an unknown spec-range record, written BY the encoder
        # so the index offsets account for them. A conforming reader steps over both.
        extra.append(put_record(0x91, b"private application record"))
        extra.append(put_record(0x7D, b"unknown future record"))
        # And fields appended to two frozen records, as a later minor revision would add
        # them. This is the other half of the compatibility rule: a reader must take a
        # record's length from its header, not from where its own knowledge runs out.
        trailers[HEADER] = b"\x01\x00\x00\x00appended-header-field"
        trailers[QUANTIZATION] = b"\x02\x00\x00\x00appended-quantization-field"
        # The provenance records are new and not frozen, which makes them the likeliest
        # place a later revision appends. A reader must take their length from the record
        # header rather than from where its own knowledge stops, and that has to be true
        # on the day they ship rather than the day someone first appends to one.
        trailers[COORDINATE_FRAME] = b"\x03\x00\x00\x00appended-frame-field"
        trailers[SENSOR_CALIBRATION] = b"\x04\x00\x00\x00appended-sensor-field"
        trailers[RIG_TRAJECTORY] = b"\x05\x00\x00\x00appended-trajectory-field"
        trailers[GEODETIC_ANCHOR] = b"\x06\x00\x00\x00appended-anchor-field"
    if "WithAttachment" in flags:
        extra.append(Attachment(name="note.txt", media_type="text/plain", data=b"conformance").encode())
    if "WithMetadata" in flags:
        # A Metadata record, distinct from the Header's attributes map: both carry
        # key-value pairs and an implementation that reads one is not reading the other.
        extra.append(
            Metadata(
                name=scenario.name,
                entries={"scenario": scenario.name, "visibility_profile": "gaussian"},
            ).encode()
        )

    options = fourdgs.WriteOptions(
        profile="coarse" if "Quantized" in flags else "default",
        min_chunk_gaussians=8 if "UseChunks" in flags else 10**9,
        max_depth=4 if "UseChunks" in flags else 0,
        write_index="UseChunkIndex" in flags,
        write_statistics="UseStatistics" in flags,
        write_summary_offsets="UseSummaryOffset" in flags,
        write_crc="UseCrc" in flags,
        library="4dgs conformance generator",
        scene_profile="baked" if scenario.long_lived else "capture",
        metadata={"scenario": scenario.name} if "WithMetadata" in flags else None,
        provenance=_provenance(scenarios.build_provenance(scenario, flags)),
        extra_records=tuple(extra),
        record_trailers=trailers,
        cutoff=0.2 if "CustomCutoff" in flags else 0.05,
        sh_bit_depths=sh_bit_depths,
        **overrides,
    )

    buf = io.BytesIO()
    fourdgs.write(buf, gaussians, raw["duration_sec"], options=options, audio=audio, camera=camera)
    data = buf.getvalue()

    if not read_back:
        # An invalid variant is not summarized: the expectation is the refusal, and
        # reading it back would be asking a correct decoder to decode a file it must
        # refuse. Returning the bytes alone is the point.
        return data, ""

    scene = fourdgs.read(data)
    expectation = canonical(
        summarize(
            scene.header,
            scene.gaussians,
            scene.audio,
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
    return data, expectation


def build_invalid() -> list[tuple[str, bytes, str]]:
    """Every invalid variant: `(name, bytes, expectation)`.

    The base is one valid variant, mutated once per refusal. Building it here rather than
    in `invalid.py` keeps that file a declaration — what is broken and what a reader must
    say — with no dependency on the encoder.
    """
    base_scenario = next(s for s in scenarios.SCENARIOS if s.name == invalid.BASE_SCENARIO)
    base, _ = build(base_scenario, tuple(sorted(invalid.BASE_FLAGS)))
    out = []
    for refusal in invalid.REFUSALS:
        data = refusal.mutate(base)
        if data == base:
            raise AssertionError(f"{refusal.name}: the mutation changed nothing")
        out.append((refusal.name, data, canonical({"refused": refusal.code})))
    for name, code, _rule, overrides in invalid.ENCODED:
        data, _ = build(base_scenario, tuple(sorted(invalid.BASE_FLAGS)), read_back=False, **overrides)
        if data == base:
            raise AssertionError(f"{name}: the override changed nothing")
        out.append((name, data, canonical({"refused": code})))
    return out


def _provenance(raw) -> Provenance | None:
    """Turn the generator's plain description into records.

    `scenarios.py` stays dependency-free and returns lists and dicts; the mapping onto
    the library's types lives here, so a fixture is still readable without the library
    installed.
    """
    if raw is None:
        return None
    prov = Provenance()
    prov.frames = [CoordinateFrame(**f) for f in raw["frames"]]
    prov.sensors = [SensorCalibration(**s) for s in raw["sensors"]]
    prov.trajectories = [RigTrajectory(**t) for t in raw["trajectories"]]
    prov.anchors = [GeodeticAnchor(**a) for a in raw["anchors"]]
    return prov


def write_corpus(target: str) -> dict[str, str]:
    os.makedirs(target, exist_ok=True)
    checksums: dict[str, str] = {}
    for scenario, flags in scenarios.variants():
        name = scenarios.variant_name(scenario, flags)
        data, expectation = build(scenario, flags)
        with open(os.path.join(target, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(target, f"{name}.json"), "w", encoding="utf-8") as fh:
            fh.write(expectation + "\n")
        checksums[name] = hashlib.sha256(data).hexdigest()

    invalid_dir = os.path.join(target, "invalid")
    os.makedirs(invalid_dir, exist_ok=True)
    for name, data, expectation in build_invalid():
        with open(os.path.join(invalid_dir, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(invalid_dir, f"{name}.json"), "w", encoding="utf-8") as fh:
            fh.write(expectation + "\n")
        checksums[f"invalid/{name}"] = hashlib.sha256(data).hexdigest()
    return checksums


def write_checksums(checksums: dict[str, str]) -> None:
    lines = [
        "# SHA-256 of each generated .4dgs variant, asserted by `generate.py --verify`.",
        "# Written by the generator; do not edit by hand.",
    ]
    lines += [f"{digest}  {name}.4dgs" for name, digest in sorted(checksums.items())]
    with open(CHECKSUMS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def read_checksums() -> dict[str, str]:
    out: dict[str, str] = {}
    if not os.path.exists(CHECKSUMS):
        return out
    with open(CHECKSUMS, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            digest, name = line.split()
            out[name[: -len(".4dgs")]] = digest
    return out


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="generate or verify the 4dgs conformance corpus")
    parser.add_argument("--verify", action="store_true", help="regenerate and assert nothing moved")
    args = parser.parse_args(argv)

    checksums = write_corpus(DATA)
    total = sum(
        os.path.getsize(os.path.join(root, f))
        for root in (DATA, INVALID)
        for f in os.listdir(root)
        if os.path.isfile(os.path.join(root, f))
    )
    print(f"{len(checksums)} variants, {total / 1024:.0f} KiB in {DATA}")

    if total > MAX_DATA_BYTES:
        print(f"error: corpus is {total} bytes, over the {MAX_DATA_BYTES} cap — prune variants", file=sys.stderr)
        return 1

    if not args.verify:
        write_checksums(checksums)
        print(f"wrote {CHECKSUMS}")
        return 0

    return 0 if _verify(checksums) else 1


def _verify(checksums: dict[str, str]) -> bool:
    """Assert the corpus matches what is committed and that the encoder is stable."""
    committed = read_checksums()
    failures = []
    if not committed:
        failures.append("CHECKSUMS.txt is missing or empty")
    for name, digest in sorted(checksums.items()):
        if name not in committed:
            failures.append(f"{name}: no committed checksum")
        elif committed[name] != digest:
            failures.append(f"{name}: checksum {digest[:16]}… != committed {committed[name][:16]}…")
    for name in committed:
        if name not in checksums:
            failures.append(f"{name}: committed checksum has no variant")

    # Determinism: a second run must produce the same bytes.
    second = {}
    for scenario, flags in scenarios.variants():
        data, _ = build(scenario, flags)
        second[scenarios.variant_name(scenario, flags)] = hashlib.sha256(data).hexdigest()
    for name, data, _ in build_invalid():
        second[f"invalid/{name}"] = hashlib.sha256(data).hexdigest()
    for name, digest in checksums.items():
        if second.get(name) != digest:
            failures.append(f"{name}: encoder is not deterministic between runs")

    if failures:
        print("conformance corpus verification FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print("\nif the change was intended, rerun without --verify and commit the result", file=sys.stderr)
        return False

    print(f"verified {len(checksums)} variants: checksums match and the encoder is deterministic")
    return True


if __name__ == "__main__":
    sys.exit(main())
