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
KEYFRAME = os.path.join(DATA, "keyframe")
CHECKSUMS = os.path.join(DATA, "CHECKSUMS.txt")
sys.path.insert(0, os.path.join(HERE, "generator"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "python", "fourdgs"))

import fourdgs
import invalid
import scenarios
from canonical import canonical, summarize
from fourdgs import keyframe_delta_file as kdf
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.object_layer import ObjectLayer
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
    DELTA_MODE_CHAINED,
    DELTA_MODE_KEYFRAME,
    Attachment,
    CoordinateFrame,
    GeodeticAnchor,
    Metadata,
    ObjectTable,
    ObjectTableEntry,
    ObjectTrack,
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
        object_id=(np.where(np.arange(n) % 3 == 0, 7, 0).astype(np.uint32) if "WithObjects" in flags else None),
    )

    audio_sources = []
    if "WithLargeAudio" in flags:
        # Six seconds at 8 kHz is ~96 KiB: comfortably past the 64 KiB an indexed reader
        # probes the front of a file with, and comfortably inside the corpus size cap.
        audio_sources = [
            fourdgs.AudioSource(
                source_id=7,
                name="large-source",
                codec="wav",
                data=scenarios.build_audio(seconds=6.0),
                duration_sec=6.0,
                position=(-2.0, 0.5, 1.0),
            )
        ]
    elif "WithMultipleAudioSources" in flags:
        audio_sources = [
            fourdgs.AudioSource(
                source_id=7,
                name="fixed-source",
                codec="wav",
                data=scenarios.build_audio(),
                duration_sec=0.25,
                gain=0.75,
                position=(-2.0, 0.5, 1.0),
            ),
            fourdgs.AudioSource(
                source_id=42,
                name="moving-source",
                codec="wav",
                data=scenarios.build_audio(seconds=0.5),
                start_sec=0.125,
                duration_sec=0.5,
                gain=0.5,
                loop=True,
                position=(2.0, 0.5, 1.0),
                keyframes=[
                    fourdgs.AudioSourceKeyframe(
                        time=0.0,
                        position=(2.0, 0.5, 1.0),
                        rotation=(0.0, 0.0, 0.0, 1.0),
                    ),
                    fourdgs.AudioSourceKeyframe(
                        time=raw["duration_sec"],
                        position=(-2.0, 1.5, -1.0),
                        rotation=(0.0, 1.0, 0.0, 0.0),
                    ),
                ],
            ),
        ]
    elif "WithSpatialAudio" in flags:
        audio_sources = [
            fourdgs.AudioSource(
                source_id=7,
                name="speaker",
                codec="wav",
                data=scenarios.build_audio(),
                duration_sec=0.25,
                position=(1.5, 0.75, -0.5),
            )
        ]
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
        scene_profile="objects" if "WithObjects" in flags else ("baked" if scenario.long_lived else "capture"),
        metadata={"scenario": scenario.name} if "WithMetadata" in flags else None,
        provenance=_provenance(scenarios.build_provenance(scenario, flags)),
        objects=_objects(raw["duration_sec"]) if "WithObjects" in flags else None,
        extra_records=tuple(extra),
        record_trailers=trailers,
        cutoff=0.2 if "CustomCutoff" in flags else 0.05,
        sh_bit_depths=sh_bit_depths,
        **overrides,
    )

    buf = io.BytesIO()
    fourdgs.write(
        buf,
        gaussians,
        raw["duration_sec"],
        options=options,
        audio_sources=audio_sources,
        camera=camera,
    )
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
            scene.audio_sources,
            [(e.t0, e.t1) for e in scene.chunk_index],
            camera=scene.camera,
            metadata=scene.metadata,
            attachments=scene.attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
            provenance=scene.provenance,
            objects=scene.objects,
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


# --------------------------------------------------------------------------
# keyframe-delta corpus
# --------------------------------------------------------------------------
#
# A separate generation path, deliberately NOT folded into the `Scenario`/`FLAGS`
# cross-product in `scenarios.py`: keyframe-delta is a whole-file temporal model with its
# own writer (`write_sequence`) and its own canonical (`states_json`), not a flag on a
# gaussian-birth file. Its variants are built here directly and folded into `write_corpus`
# alongside the others, so the shared harness proves them for every SDK that decodes them.
#
# Every name carries `UseChunkIndex` so the indexed read path is exercised (run.py routes
# decode_indexed on it), plus `UseCrc` and `UseStatistics` — all three are what
# `write_sequence` emits by default, so the name states what the file actually contains.

#: Seconds and sample count of the synthetic sequences. Eight samples over eight seconds is
#: enough for a genuine chain — a keyframe then three deltas per group at cadence 4 — while
#: keeping every file well under the corpus size cap.
_KD_STEPS = 8
_KD_DURATION = 8.0


def _kd_gaussians(positions: list[list[float]]) -> fourdgs.GaussianSet:
    """A population at one instant, finite sigma, one shared full-duration window.

    Mirrors the shape `python/fourdgs/tests/test_keyframe_delta_file.py` builds: identity is
    carried by the Sample, sigma_t is finite (so the per-gaussian velocity and birth-time
    grids stay uniform, which is all this reference needs), and the validity window is the
    whole clip.
    """
    n = len(positions)
    return fourdgs.GaussianSet(
        positions=np.asarray(positions, dtype=np.float32).reshape(n, 3),
        scales=np.full((n, 3), 0.05, dtype=np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=np.tile(np.array([0.6, 0.4, 0.2, 0.9], dtype=np.float32), (n, 1)),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.zeros(n, dtype=np.float32),
        sigma_t=np.full(n, 100.0, dtype=np.float32),  # finite, effectively non-fading over the clip
        win_lo=np.zeros(n, dtype=np.float32),
        win_hi=np.full(n, _KD_DURATION, dtype=np.float32),
    )


def _kd_drift_sequence() -> list[Sample]:
    """A fixed population of four gaussians that drifts. No births or deaths, so every
    delta is a pure update — the plain keyframe-delta shape."""
    samples = []
    for i in range(_KD_STEPS):
        base = [
            [float(i) * 0.1, 0.0, 0.0],
            [1.0, float(i) * 0.05, 0.0],
            [0.0, 1.0, float(i) * 0.03],
            [1.0, 1.0, 0.0],
        ]
        t0 = float(i) * (_KD_DURATION / _KD_STEPS)
        samples.append(Sample(t0=t0, ids=np.array([0, 1, 2, 3]), gaussians=_kd_gaussians(base)))
    return samples


def _kd_churn_sequence() -> list[Sample]:
    """A drifting population with one birth (id 4) and one death (id 2), so deltas carry
    birth and death groups, not only updates."""
    samples = []
    for i in range(_KD_STEPS):
        ids = [0, 1, 2, 3]
        base = [[float(i) * 0.1, 0.0, 0.0], [1.0, float(i) * 0.05, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]]
        if i >= 2:  # a birth
            ids = [*ids, 4]
            base = [*base, [2.0, 2.0, float(i) * 0.02]]
        if i >= 5 and 2 in ids:  # a death of id 2
            keep = [k for k in range(len(ids)) if ids[k] != 2]
            ids = [ids[k] for k in keep]
            base = [base[k] for k in keep]
        t0 = float(i) * (_KD_DURATION / _KD_STEPS)
        samples.append(Sample(t0=t0, ids=np.array(ids), gaussians=_kd_gaussians(base)))
    return samples


#: (name, sequence-builder, cadence, delta-mode). Four variants, each a distinct decode:
#: every chunk a keyframe; chained pure-update deltas; chained deltas carrying births and
#: deaths; and keyframe-referenced deltas.
KEYFRAME_DELTA_VARIANTS = (
    ("KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 1, DELTA_MODE_CHAINED),
    ("KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics", _kd_drift_sequence, 4, DELTA_MODE_CHAINED),
    ("KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 4, DELTA_MODE_CHAINED),
    ("KeyframeDeltaModesMixed-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 4, DELTA_MODE_KEYFRAME),
)


def build_keyframe_delta_corpus() -> list[tuple[str, bytes, str]]:
    """Every keyframe-delta variant: `(name, bytes, expectation)`.

    The expectation is the streamed decode's canonical `states` JSON — the reconstruction
    at an instant that the whole model exists to make cheap, and the statement every SDK
    that decodes the model is diffed against. Built here rather than in `scenarios.py` so
    the shared cross-product stays untouched.
    """
    out: list[tuple[str, bytes, str]] = []
    for name, sequence_of, keyframe_every, delta_mode in KEYFRAME_DELTA_VARIANTS:
        data = kdf.write_sequence(
            sequence_of(),
            _KD_DURATION,
            kd=KeyframeDeltaOptions(keyframe_every=keyframe_every, delta_mode=delta_mode),
            library="4dgs conformance generator",
        )
        expectation = canonical(kdf.states_json(kdf.decode_streamed(data)))
        out.append((name, data, expectation))
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


def _objects(duration_sec: float) -> ObjectLayer:
    """A labelled object whose rigid pose exercises interpolation and end clamping."""
    return ObjectLayer(
        table=ObjectTable(
            embedding_dim=4,
            entries=[
                ObjectTableEntry(
                    object_id=7,
                    label="synthetic vehicle",
                    anchor=(1.0, -2.0, 0.5),
                    dynamics=([2.0, 0.0, 0.0], [0.0, 0.0, 0.5], [0.0, 0.0, 0.0]),
                    embedding=[0.25, -0.5, 0.75, 1.0],
                )
            ],
        ),
        tracks=[
            ObjectTrack(
                object_id=7,
                times=[1.0, duration_sec - 1.0],
                rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.0]],
                translations=[[0.0, 0.0, 0.0], [10.0, 4.0, 0.0]],
            )
        ],
    )


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

    # keyframe-delta variants live in their own subdirectory, exactly as the invalid
    # corpus does, and for the same structural reason: every whole-corpus consumer that
    # is not the conformance harness — the fuzzer, the Kaitai grammar, the C++ named-list
    # decode test — globs the top level of `data/` only, and each of those assumes the
    # single gaussian-birth temporal model. A keyframe-delta file at the top level breaks
    # them; under `keyframe/` it is invisible to them and visible to `run.py`, which is
    # the one consumer that dispatches on the model.
    keyframe_dir = os.path.join(target, "keyframe")
    os.makedirs(keyframe_dir, exist_ok=True)
    for name, data, expectation in build_keyframe_delta_corpus():
        with open(os.path.join(keyframe_dir, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(keyframe_dir, f"{name}.json"), "w", encoding="utf-8") as fh:
            fh.write(expectation + "\n")
        checksums[f"keyframe/{name}"] = hashlib.sha256(data).hexdigest()

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
        for root in (DATA, INVALID, KEYFRAME)
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
    for name, data, _ in build_keyframe_delta_corpus():
        second[f"keyframe/{name}"] = hashlib.sha256(data).hexdigest()
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
