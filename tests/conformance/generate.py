#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Generate the conformance corpus, or verify the committed one.

    python3 tests/conformance/generate.py            # write data/*.4dgs and *.json
    python3 tests/conformance/generate.py --verify   # regenerate and check nothing moved

`--verify` is the gate that keeps the corpus honest. It asserts three things:

1. every generated file matches its committed SHA-256;
2. every committed expectation matches, character for character, a fresh decode;
3. two consecutive generator runs are byte-identical.

The second and third are the ones that earn their keep, and they catch different things.
Accidental nondeterminism in an encoder — iteration order, a hash seed, a timestamp — is
invisible locally and shows up as somebody else's failing CI. A canonical form that varies
by machine is quieter still: the bytes are identical, so every checksum passes, and only
the expectations move (issue #153).
"""

from __future__ import annotations

import argparse
import hashlib
import io
import math
import os
import struct
import sys
from decimal import Decimal
from itertools import zip_longest
from typing import NamedTuple

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
INVALID = os.path.join(DATA, "invalid")
LATE_FRONT_MATTER = os.path.join(INVALID, "late-front-matter")
KEYFRAME = os.path.join(DATA, "keyframe")
OBJECT = os.path.join(DATA, "object")
IDENTITY = os.path.join(DATA, "identity")
CHUNK_WINDOW = os.path.join(DATA, "chunk-window-intersection")
CHECKSUMS = os.path.join(DATA, "CHECKSUMS.txt")
sys.path.insert(0, os.path.join(HERE, "generator"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "python", "fourdgs"))

import canonical as canonical_module
import chunk_window
import fourdgs
import invalid
import scenarios
from canonical import canonical, summarize
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.model import DEFAULT_CUTOFF
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
    TRAJECTORY_LINEAR,
    TRAJECTORY_STEP,
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
from fourdgs.serialization import MAGIC, crc32, encode_stream, put_record

MAX_DATA_BYTES = 2_500_000


def _sh_coefficients(n: int, coeffs: int, flags) -> np.ndarray | None:
    """The spherical-harmonic coefficient block for a variant, or `None` at degree 0.

    The default fill is `% 251`, and the modulus is load-bearing in a way nobody intended:
    it is coprime with the 45-column stride, so consecutive gaussians get different
    coefficients rather than the same ones repeating — but it also keeps **251..255 out of
    the entire corpus**. At the `coarse` profile's `step_sh = 3` exactly one input value
    overflows its own encoding: 255 rounds to the bin centre 256, which no `u8` holds. So a
    coarse-profile file with spherical harmonics already existed and still could not reach
    the bug (issues #181, #190).

    `SHTopCoefficients` fills `% 256` instead, which reaches 255 and keeps the same
    stride-coprimality property only incidentally — what matters is that the extreme value
    is present. Changing the default here instead would move every existing SH fixture's
    checksum for a property only one variant needs.
    """
    if not coeffs:
        return None
    modulus = 256 if "SHTopCoefficients" in flags else 251
    return (np.arange(n * coeffs, dtype=np.int64) % modulus).astype(np.uint8).reshape(n, coeffs)


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
        sh=_sh_coefficients(n, coeffs, flags),
        sh_degree=sh_degree,
        # The one object-bearing top-level variant also carries both exact
        # producer-side identity lanes. Distinct nontrivial values make a
        # decode/re-encode loss or substitution observable in the Dart encode
        # gate rather than merely proving that all readers agree on the
        # degraded file.
        source_group=(
            (np.arange(n, dtype=np.int64) * np.int64(31) - np.int64(1009)) if "WithObjects" in flags else None
        ),
        source_index=(
            (np.arange(n, dtype=np.uint32) * np.uint32(104729) + np.uint32(17)) if "WithObjects" in flags else None
        ),
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
        preserve_source_ids="WithObjects" in flags,
        library="4dgs conformance generator",
        scene_profile="objects" if "WithObjects" in flags else ("baked" if scenario.long_lived else "capture"),
        metadata={"scenario": scenario.name} if "WithMetadata" in flags else None,
        provenance=_provenance(scenarios.build_provenance(scenario, flags)),
        objects=_objects(raw["duration_sec"]) if "WithObjects" in flags else None,
        extra_records=tuple(extra),
        record_trailers=trailers,
        cutoff=0.2 if "CustomCutoff" in flags else 0.05,
        sh_bit_depths=sh_bit_depths,
        # Bands 1..3 unless a variant asks for fewer. Capping is what makes the degree the
        # file carries differ from the degree the scene holds.
        sh_bands=1 if "SHBandsCapped" in flags else 3,
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
        out.append((refusal.name, data, canonical(refusal.expectation(data))))
    for name, code, _rule, overrides in invalid.ENCODED:
        data, _ = build(base_scenario, tuple(sorted(invalid.BASE_FLAGS)), read_back=False, **overrides)
        if data == base:
            raise AssertionError(f"{name}: the override changed nothing")
        out.append((name, data, canonical({"refused": code})))

    # Count fields have different meanings only in keyframe-delta: gaussian_count is the
    # operation count while live_count is the composed population. Cut these witnesses from
    # that corpus rather than corrupting the gaussian-birth base in a second way.
    index_name, index_base, _ = next(
        item for item in build_keyframe_delta_corpus() if item[0] == invalid.INDEX_COUNT_BASE
    )
    if index_name != invalid.INDEX_COUNT_BASE:
        raise AssertionError(f"wrong index-count base: {index_name}")
    for refusal in invalid.INDEX_COUNT_REFUSALS:
        data = refusal.mutate(index_base)
        if data == index_base:
            raise AssertionError(f"{refusal.name}: the mutation changed nothing")
        out.append((refusal.name, data, canonical(refusal.expectation(data))))

    # Placement is enforced by both temporal models' independent streamed loops. These
    # bases remain indexed so a skipped indexed verdict really exercises the normative
    # exemption, rather than merely avoiding a file that has no index.
    late_scenario = next(s for s in scenarios.SCENARIOS if s.name == invalid.LATE_GAUSSIAN_BASE)
    late_base, _ = build(late_scenario, tuple(sorted(invalid.LATE_GAUSSIAN_FLAGS)))
    for refusal in invalid.LATE_GAUSSIAN_REFUSALS:
        data = refusal.mutate(late_base)
        if data == late_base:
            raise AssertionError(f"{refusal.name}: the mutation changed nothing")
        out.append((refusal.name, data, canonical(refusal.expectation(data))))

    late_kd_name, late_kd_base, _ = next(
        item for item in build_keyframe_delta_corpus() if item[0] == invalid.LATE_KEYFRAME_DELTA_BASE
    )
    if late_kd_name != invalid.LATE_KEYFRAME_DELTA_BASE:
        raise AssertionError(f"wrong late keyframe-delta base: {late_kd_name}")
    for refusal in invalid.LATE_KEYFRAME_DELTA_REFUSALS:
        data = refusal.mutate(late_kd_base)
        if data == late_kd_base:
            raise AssertionError(f"{refusal.name}: the mutation changed nothing")
        out.append((refusal.name, data, canonical(refusal.expectation(data))))
    return out


# --------------------------------------------------------------------------
# gaussian-birth Chunk/window-intersection corpus
# --------------------------------------------------------------------------
#
# These two files differ only in whether the writer emits a Chunk Index. The writer
# first creates the ordinary contained shape (window and owning Chunk both [1, 2)); a
# length-preserving replacement then widens the Window Table row to [0, 3). This keeps
# every offset and index claim valid while producing the legal overhang §3/§5.5 defines.
# The expectation is authored from that normative intersection, not from the current
# Python GaussianSet.state_at implementation, which intentionally has no owning-Chunk
# argument yet. No SDK implementation is therefore allowed to become the oracle for
# the conformance rule it has not claimed.

_CHUNK_WINDOW_NAMES = (
    "WindowOverhang-NoChunkIndex",
    "WindowOverhang-UseChunkIndex-UseCrc",
)


def _chunk_window_gaussian() -> fourdgs.GaussianSet:
    return fourdgs.GaussianSet(
        positions=np.asarray([[1.0, 2.0, 3.0]], dtype=np.float32),
        scales=np.asarray([[0.1, 0.1, 0.1]], dtype=np.float32),
        rotations=np.asarray([[0.0, 0.0, 0.0, 1.0]], dtype=np.float32),
        colors=np.asarray([[0.25, 0.5, 0.75, 0.8]], dtype=np.float32),
        motions=np.zeros((1, 3), dtype=np.float32),
        mu_t=np.asarray([1.5], dtype=np.float32),
        # Marginal 1 at every probe: only the two half-open gates decide contribution.
        sigma_t=np.asarray([np.inf], dtype=np.float32),
        win_lo=np.asarray([1.0], dtype=np.float64),
        win_hi=np.asarray([2.0], dtype=np.float64),
    )


def _widen_chunk_window(data: bytes) -> bytes:
    """Replace the only Window Table row with [0, 3), without moving any byte."""
    from fourdgs import opcode as op
    from fourdgs.records import WindowTable, parse_chunk
    from fourdgs.serialization import MAGIC, iter_records

    records = list(iter_records(data, len(MAGIC)))
    table = [record for record in records if record.opcode == op.WINDOW_TABLE]
    chunks = [record for record in records if record.opcode == op.CHUNK]
    if len(table) != 1 or WindowTable.parse(table[0].content).windows != [(1.0, 2.0)]:
        raise AssertionError("Chunk/window base must carry exactly the contained [1, 2) window")
    if len(chunks) != 1:
        raise AssertionError("Chunk/window base must carry exactly one Chunk")
    head, _streams = parse_chunk(chunks[0].content)
    if (head.t0, head.t1, head.count) != (1.0, 2.0, 1):
        raise AssertionError(f"Chunk/window base moved to {(head.t0, head.t1, head.count)!r}")

    widened = bytearray(data)
    # Record header, then the Window Table's u32 row count, then its two f64 endpoints.
    struct.pack_into("<dd", widened, table[0].offset + 9 + 4, 0.0, 3.0)
    return bytes(widened)


def _chunk_window_summary(data: bytes) -> str:
    scene = fourdgs.read(data)
    summary = summarize(
        scene.header,
        scene.gaussians,
        scene.audio_sources,
        [(entry.t0, entry.t1) for entry in scene.chunk_index],
        camera=scene.camera,
        metadata=scene.metadata,
        attachments=scene.attachments,
        statistics=scene.statistics,
        summary_offsets=scene.summary_offsets,
        summary_crc_ok=scene.summary_crc_ok,
        provenance=scene.provenance,
        objects=scene.objects,
    )
    # The stored window contains every probe and never_fades makes the marginal 1, so
    # the owning Chunk's [1, 2) interval is the only term that can change this count.
    summary["states"] = [
        {
            "t": canonical_module.num(t),
            "liveCount": "1" if 1.0 <= t < 2.0 else "0",
        }
        for t in chunk_window.PROBE_TIMES
    ]
    return canonical(summary)


def build_chunk_window_corpus() -> list[tuple[str, bytes, str]]:
    out = []
    for name in _CHUNK_WINDOW_NAMES:
        indexed = "UseChunkIndex" in name
        buf = io.BytesIO()
        fourdgs.write(
            buf,
            _chunk_window_gaussian(),
            3.0,
            options=fourdgs.WriteOptions(
                max_depth=0,
                min_chunk_gaussians=1,
                write_index=indexed,
                write_statistics=False,
                write_summary_offsets=False,
                write_crc=indexed,
                library="4dgs conformance generator",
                metadata={"conformance": chunk_window.MARKER},
            ),
        )
        data = _widen_chunk_window(buf.getvalue())
        out.append((name, data, _chunk_window_summary(data)))
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


#: The validity windows the multi-window sequence declares, in Window Table order: one
#: that spans the clip, one that closes at 2s, and one that does not open until 4s. Two
#: gaussians sit in each.
#:
#: Every other keyframe-delta variant carries a single window `[0, 8)`, so a gaussian's
#: window never closes before the scene does and section 3's visibility rule has nothing
#: to decide. That gap hid three defects: `a4b1efa`, where every gaussian was given the
#: *first* window's motion grid and reconstructed positions moved in three SDKs at once;
#: issue #185, the same rule applied on one implementation's reconstruction path and not
#: another's; and a third sighting while the TypeScript keyframe-delta encoder was written.
#: All three were invisible because no fixture could express a window that shuts.
_KD_WINDOWS = ((0.0, _KD_DURATION), (0.0, 2.0), (4.0, _KD_DURATION))


#: Gaussians in the multi-window sequence. Two per window.
_KD_MULTI_WINDOW_COUNT = 6


def _kd_multi_window_gaussians(step: int) -> fourdgs.GaussianSet:
    """The multi-window population at one sample, every attribute distinct per gaussian.

    Uniform attributes would make this variant prove less than it looks like it proves: if
    every row carried the same scale, rotation and colour, a decoder that kept the *wrong*
    two rows at 3s would still emit the right numbers, and only the count and the ids could
    ever disagree. So scale, rotation, colour, velocity, birth time and sigma all differ per
    gaussian, and position and rotation drift as the clip runs.

    `sigma_t`, `flags` and `window_index` are GOP-invariant (spec section 11.5), so they are
    a function of the gaussian alone and never of the step; everything that drifts is what
    the delta chunks carry. `mu_t` sits inside each gaussian's own window, because a birth
    time outside the window it belongs to would leave the marginal doing the work the window
    is supposed to do.

    `sigma_t` is finite on every row: this reference writer requires it and writes
    `never_fades = 0` throughout, which is also why this variant cannot reach the one place
    a window's *length* changes a grid (the velocity precision class reads the window length
    only for a never-fading gaussian, spec section 6.3). What it does reach is the
    visibility rule and `window_index` naming the right row of a three-row table.
    """
    n = _KD_MULTI_WINDOW_COUNT
    windows = [_KD_WINDOWS[i % len(_KD_WINDOWS)] for i in range(n)]
    positions, scales, rotations, colors, motions = [], [], [], [], []
    for i in range(n):
        positions.append([0.3 * i + 0.11 * step, -0.7 + 0.05 * i * step, 0.25 * step - 0.4 * i])
        scales.append([0.02 + 0.013 * i + 0.004 * a for a in range(3)])
        # A rotation about a tilted axis, turning as the clip runs, so the smallest-three
        # coding has a different largest component on different rows.
        angle = 0.21 * i + 0.37 * step
        axis = (0.3, 0.6, math.sqrt(1.0 - 0.09 - 0.36))
        s = math.sin(angle / 2.0)
        rotations.append([axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2.0)])
        colors.append([0.1 + 0.14 * i, 0.9 - 0.11 * i, 0.33 + 0.07 * i, 0.4 + 0.09 * i])
        motions.append([0.13 * (i - 2), -0.06 * i, 0.21])
    return fourdgs.GaussianSet(
        positions=np.asarray(positions, dtype=np.float32).reshape(n, 3),
        scales=np.asarray(scales, dtype=np.float32).reshape(n, 3),
        rotations=np.asarray(rotations, dtype=np.float32).reshape(n, 4),
        colors=np.asarray(colors, dtype=np.float32).reshape(n, 4),
        motions=np.asarray(motions, dtype=np.float32).reshape(n, 3),
        mu_t=np.asarray([0.5 * (lo + hi) for lo, hi in windows], dtype=np.float32),
        # Keep every in-window row comfortably above the Header's temporal cutoff for the
        # full window. This scenario isolates the hard validity-window gate; a narrow sigma
        # would also test the independent marginal gate and change the intended 4/2/4 count.
        sigma_t=np.asarray([2.0 + 0.35 * i for i in range(n)], dtype=np.float32),
        win_lo=np.asarray([lo for lo, _ in windows], dtype=np.float32),
        win_hi=np.asarray([hi for _, hi in windows], dtype=np.float32),
    )


def _kd_multi_window_sequence() -> list[Sample]:
    """A drifting population of six gaussians spread across three validity windows.

    No births and no deaths: every id is live in every chunk, so the composed population is
    the same six rows throughout and the only thing that can remove a row from a
    reconstructed instant is its own validity window. That is the point — a decoder that
    skips the gate reports six gaussians at every probe, while one that applies it reports
    four before 2s (window 2 has not opened), two from 2s to 4s (window 1 has shut and
    window 2 is still closed) and four from 4s on.
    """
    ids = np.arange(_KD_MULTI_WINDOW_COUNT)
    return [
        Sample(
            t0=float(i) * (_KD_DURATION / _KD_STEPS),
            ids=ids,
            gaussians=_kd_multi_window_gaussians(i),
        )
        for i in range(_KD_STEPS)
    ]


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


_KD_ROW_LANES = (
    "positions",
    "scales",
    "rotations",
    "colors",
    "motions",
    "sigma_t",
    "win_lo",
    "win_hi",
    "sh",
    "source_group",
    "source_index",
    "object_id",
)


def _kd_state_temporal_origins(samples: list[Sample], keyframe_every: int, delta_mode: int) -> None:
    """State `mu_t` at the Chunk that actually restates each row.

    A keyframe states every live gaussian. A delta states births and rows whose
    other authored lanes changed; an omitted row must retain the temporal origin
    from its reference state. Keeping one such row is itself a conformance claim:
    a decoder that drops untouched identities can no longer pass this corpus.
    """
    last_keyframe = 0
    for index, sample in enumerate(samples):
        keyframe = index == 0 or (keyframe_every > 0 and index % keyframe_every == 0)
        if keyframe:
            sample.gaussians.mu_t.fill(sample.t0)
            last_keyframe = index
            continue

        reference = samples[index - 1 if delta_mode == DELTA_MODE_CHAINED else last_keyframe]
        reference_rows = {int(identity): row for row, identity in enumerate(reference.ids)}
        for row, identity_value in enumerate(sample.ids):
            identity = int(identity_value)
            reference_row = reference_rows.get(identity)
            if reference_row is None:
                sample.gaussians.mu_t[row] = sample.t0
                continue

            changed = False
            for lane in _KD_ROW_LANES:
                current_values = getattr(sample.gaussians, lane)
                reference_values = getattr(reference.gaussians, lane)
                if current_values is None or reference_values is None:
                    changed = current_values is not reference_values
                else:
                    changed = not np.array_equal(current_values[row], reference_values[reference_row])
                if changed:
                    break
            sample.gaussians.mu_t[row] = sample.t0 if changed else reference.gaussians.mu_t[reference_row]


#: (name, sequence-builder, cadence, delta-mode). Four variants, each a distinct decode:
#: every chunk a keyframe; chained pure-update deltas; chained deltas carrying births and
#: deaths; and keyframe-referenced deltas.
KEYFRAME_DELTA_VARIANTS = (
    ("KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 1, DELTA_MODE_CHAINED),
    ("KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics", _kd_drift_sequence, 4, DELTA_MODE_CHAINED),
    ("KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 4, DELTA_MODE_CHAINED),
    ("KeyframeDeltaModesMixed-UseChunkIndex-UseCrc-UseStatistics", _kd_churn_sequence, 4, DELTA_MODE_KEYFRAME),
    (
        "KeyframeDeltaMultiWindow-UseChunkIndex-UseCrc-UseStatistics",
        _kd_multi_window_sequence,
        4,
        DELTA_MODE_CHAINED,
    ),
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
        samples = sequence_of()
        # §11.3: a row that is stated uses that Chunk's t0 as its temporal origin;
        # a row omitted from a delta retains the origin from its reference state.
        _kd_state_temporal_origins(samples, keyframe_every, delta_mode)
        data = kdf.write_sequence(
            samples,
            _KD_DURATION,
            kd=KeyframeDeltaOptions(keyframe_every=keyframe_every, delta_mode=delta_mode),
            library="4dgs conformance generator",
        )
        expectation = canonical(kdf.states_json(kdf.decode_streamed(data)))
        out.append((name, data, expectation))
    return out


# --------------------------------------------------------------------------
# optional-identity conformance family
# --------------------------------------------------------------------------
#
# These files follow the normative decision in
# `website/docs/spec/proposals/optional-identity-zero-defaults.md`, ahead of any SDK
# claiming it.  They therefore cannot be written or summarized through the current
# reference SDK: doing that would either omit the three streams or make today's Python
# behaviour the contract the other languages are asked to implement.  The small encoder
# below uses only the public wire record/stream encoders and writes the expected logical
# identity state explicitly.  `test_verify.py` independently inspects the physical
# streams, counts, references and omitted groups, so the expectation cannot accidentally
# describe a different file.

IDENTITY_MARKER_KEY = "conformance"
IDENTITY_MARKER_VALUE = "optional-identity-zero-defaults-v1"
OPTIONAL_IDENTITY_ATTRIBUTES = (op.A_SOURCE_GROUP, op.A_SOURCE_INDEX, op.A_OBJECT_ID)


def _identity_front(temporal_model: str, duration: float, gaussian_count: int, aabb: list[float]) -> list[bytes]:
    """Common deterministic front matter for the two identity witnesses."""
    return [
        MAGIC,
        rec.Header(
            duration_sec=duration,
            gaussian_count=gaussian_count,
            aabb=aabb,
            profile="capture",
            library="4dgs conformance optional-identity generator",
            temporal_model=temporal_model,
            cutoff=0.05,
            attributes={IDENTITY_MARKER_KEY: IDENTITY_MARKER_VALUE},
        ).encode(),
        rec.Quantization(
            scheme="uniform-v1",
            pos_origin=[0.0, 0.0, 0.0],
            step_pos=1.0,
            step_scale_log=1.0,
            step_rot=1.0,
            step_rgb=1.0,
            step_alpha=1.0,
            step_motion=1.0,
            step_time=1.0,
            step_sigma_log=1.0,
            step_sh=1,
        ).encode(),
        rec.WindowTable(windows=[(0.0, duration)]).encode(),
    ]


def _identity_required(positions: list[list[int]], mu_t: int) -> dict[int, np.ndarray]:
    """A complete, deliberately simple set of absolute gaussian bins."""
    count = len(positions)
    zeros3 = np.zeros((count, 3), dtype=np.int64)
    return {
        op.A_POSITION: np.asarray(positions, dtype=np.int64).reshape(count, 3),
        op.A_SCALE: zeros3,
        op.A_ROTATION_INDEX: np.full((count, 1), 3, dtype=np.int64),
        op.A_ROTATION: zeros3,
        op.A_COLOR: zeros3,
        op.A_OPACITY: np.ones((count, 1), dtype=np.int64),
        op.A_MOTION: zeros3,
        op.A_MU_T: np.full((count, 1), mu_t, dtype=np.int64),
        op.A_SIGMA_T: np.zeros((count, 1), dtype=np.int64),
        op.A_FLAGS: np.zeros((count, 1), dtype=np.int64),
        op.A_WINDOW_INDEX: np.zeros((count, 1), dtype=np.int64),
    }


def _identity_streams(
    bins: dict[int, np.ndarray],
    *,
    gaussian_ids: list[int] | None = None,
) -> bytes:
    """Encode one keyframe/delta group in stable attribute-id order."""
    streams: list[bytes] = []
    if gaussian_ids is not None:
        streams.append(encode_stream(op.A_GAUSSIAN_ID, np.asarray(gaussian_ids, dtype=np.int64)))
    for attribute, values in sorted(bins.items()):
        array = np.asarray(values, dtype=np.int64)
        channels = 1 if array.ndim == 1 else int(array.shape[1])
        streams.append(
            encode_stream(
                attribute,
                array,
                channels=channels,
                # Keep exact identity streams raw: adjacent signed endpoints (and u32
                # same-bit codes) can need a 33-bit intra-stream subtraction even though
                # every label fits its domain. That compression mode is independent of
                # state-chunk update semantics.
                allow_delta=attribute not in OPTIONAL_IDENTITY_ATTRIBUTES,
            )
        )
    return b"".join(streams)


def _identity_finish(
    parts: list[bytes],
    indexes: list[rec.ChunkIndexEntry],
    statistics: rec.Statistics | None = None,
) -> bytes:
    """Append the indexed summary, its CRC, and trailing magic."""
    summary_start = sum(len(part) for part in parts)
    summary_records = [entry.encode() for entry in indexes]
    if statistics is not None:
        summary_records.append(statistics.encode())
    summary = b"".join(summary_records)
    parts.extend(
        [
            summary,
            rec.Footer(summary_start=summary_start, summary_crc=crc32(summary)).encode(),
            MAGIC,
        ]
    )
    return b"".join(parts)


def _identity_row(
    *,
    source_group: int,
    source_index: int,
    object_id: int,
    position: list[float] | None = None,
    gaussian_id: int | None = None,
) -> dict:
    """One row in the capability's exact canonical result."""
    row = {
        "sourceGroup": str(source_group),
        "sourceIndex": str(source_index),
        "objectId": str(object_id),
    }
    if position is not None:
        row["position"] = [canonical_module.num(value) for value in position]
    if gaussian_id is not None:
        row["gaussianId"] = str(gaussian_id)
    return row


def _build_gaussian_birth_identity() -> tuple[str, bytes, str]:
    """Mixed physical Chunk presence, with omitted and explicit zero rows."""
    name = "OptionalIdentityGaussianBirth-UseChunkIndex-UseCrc"
    parts = _identity_front("gaussian-birth", 1.0, 5, [0.0, 0.0, 0.0, 4.0, 0.0, 0.0])
    indexes: list[rec.ChunkIndexEntry] = []

    present_bins = _identity_required([[0, 0, 0], [1, 0, 0], [2, 0, 0]], 0)
    present_bins.update(
        {
            op.A_SOURCE_GROUP: np.asarray([-(2**31), 2**31 - 1, 0], dtype=np.int64),
            op.A_SOURCE_INDEX: np.asarray([2**31 - 1, -(2**31), 0], dtype=np.int64),
            # Same-bit signed stream codes for u32 values 0x80000000, 0xffffffff and 0.
            op.A_OBJECT_ID: np.asarray([-(2**31), -1, 0], dtype=np.int64),
        }
    )
    omitted_bins = _identity_required([[3, 0, 0], [4, 0, 0]], 0)
    for bins in (present_bins, omitted_bins):
        count = int(bins[op.A_POSITION].shape[0])
        blob = rec.encode_chunk(0.0, 1.0, 0, count, _identity_streams(bins))
        at = sum(len(part) for part in parts)
        parts.append(blob)
        indexes.append(
            rec.ChunkIndexEntry(
                t0=0.0,
                t1=1.0,
                chunk_offset=at,
                chunk_length=len(blob),
                gaussian_count=count,
            )
        )

    data = _identity_finish(parts, indexes)
    expectation = canonical(
        {
            "temporalModel": "gaussian-birth",
            "identityRows": [
                _identity_row(
                    position=[0.0, 0.0, 0.0],
                    source_group=-(2**31),
                    source_index=2**31 - 1,
                    object_id=2**31,
                ),
                _identity_row(
                    position=[1.0, 0.0, 0.0],
                    source_group=2**31 - 1,
                    source_index=-(2**31),
                    object_id=2**32 - 1,
                ),
                _identity_row(
                    position=[2.0, 0.0, 0.0],
                    source_group=0,
                    source_index=0,
                    object_id=0,
                ),
                _identity_row(
                    position=[3.0, 0.0, 0.0],
                    source_group=0,
                    source_index=0,
                    object_id=0,
                ),
                _identity_row(
                    position=[4.0, 0.0, 0.0],
                    source_group=0,
                    source_index=0,
                    object_id=0,
                ),
            ],
        }
    )
    return name, data, expectation


def _build_keyframe_delta_identity() -> tuple[str, bytes, str]:
    """One compact sequence covering every optional-identity composition transition."""
    name = "OptionalIdentityKeyframeDelta-UseChunkIndex-UseCrc-UseStatistics"
    duration = 7.0
    parts = _identity_front("keyframe-delta", duration, 4, [0.0, 0.0, 0.0, 3.0, 0.0, 0.0])
    indexes: list[rec.ChunkIndexEntry] = []
    offsets: list[int] = []
    keyframe_offset = 0

    def emit_keyframe(t0: int, ids: list[int], positions: list[list[int]]) -> None:
        nonlocal keyframe_offset
        bins = _identity_required(positions, t0)
        blob = rec.encode_chunk(float(t0), float(t0 + 1), 0, len(ids), _identity_streams(bins, gaussian_ids=ids))
        at = sum(len(part) for part in parts)
        parts.append(blob)
        offsets.append(at)
        keyframe_offset = at
        indexes.append(
            rec.ChunkIndexEntry(
                t0=float(t0),
                t1=float(t0 + 1),
                chunk_offset=at,
                chunk_length=len(blob),
                gaussian_count=len(ids),
                extended=True,
                kind=0,
                keyframe_offset=at,
                live_count=len(ids),
            )
        )

    def emit_delta(
        t0: int,
        *,
        update_ids: list[int] | None = None,
        update_bins: dict[int, np.ndarray] | None = None,
        birth_ids: list[int] | None = None,
        birth_bins: dict[int, np.ndarray] | None = None,
        live_count: int,
    ) -> None:
        update_ids = update_ids or []
        birth_ids = birth_ids or []
        updates = _identity_streams(update_bins or {}, gaussian_ids=update_ids) if update_ids else b""
        births = _identity_streams(birth_bins or {}, gaussian_ids=birth_ids) if birth_ids else b""
        reference_offset = offsets[-1]
        depth = indexes[-1].depth + 1
        blob = rec.encode_delta_chunk(
            float(t0),
            float(t0 + 1),
            level=0,
            delta_mode=DELTA_MODE_CHAINED,
            reference_offset=reference_offset,
            keyframe_offset=keyframe_offset,
            depth=depth,
            updates=updates,
            births=births,
            deaths=b"",
            counts=(len(update_ids), len(birth_ids), 0),
        )
        at = sum(len(part) for part in parts)
        parts.append(blob)
        offsets.append(at)
        indexes.append(
            rec.ChunkIndexEntry(
                t0=float(t0),
                t1=float(t0 + 1),
                chunk_offset=at,
                chunk_length=len(blob),
                gaussian_count=len(update_ids) + len(birth_ids),
                extended=True,
                kind=1,
                delta_mode=DELTA_MODE_CHAINED,
                reference_offset=reference_offset,
                keyframe_offset=keyframe_offset,
                depth=depth,
                live_count=live_count,
            )
        )

    # Complete keyframe omission gives both existing rows logical zero.
    emit_keyframe(0, [10, 20], [[0, 0, 0], [1, 0, 0]])
    # All three lanes are introduced by an update into a physically absent reference.
    emit_delta(
        1,
        update_ids=[10],
        update_bins={
            op.A_SOURCE_GROUP: np.asarray([-17], dtype=np.int64),
            op.A_SOURCE_INDEX: np.asarray([23], dtype=np.int64),
            op.A_OBJECT_ID: np.asarray([-1], dtype=np.int64),
        },
        live_count=2,
    )
    # A birth omitting all three appends logical zeros beside the present survivor columns.
    emit_delta(
        2,
        birth_ids=[30],
        birth_bins=_identity_required([[2, 0, 0]], 2),
        live_count=3,
    )
    # A touched row with no identity stream carries all reference labels forward.
    emit_delta(
        3,
        update_ids=[10],
        update_bins={op.A_POSITION: np.asarray([[1, 0, 0]], dtype=np.int64)},
        live_count=3,
    )
    # Present update values are absolute labels, so explicit zero resets rather than adds.
    emit_delta(
        4,
        update_ids=[10],
        update_bins={attribute: np.asarray([0], dtype=np.int64) for attribute in OPTIONAL_IDENTITY_ATTRIBUTES},
        live_count=3,
    )
    # A new complete keyframe does not inherit identity from the preceding GOP.
    emit_keyframe(5, [10, 20], [[0, 0, 0], [1, 0, 0]])
    # A birth introduces all three columns into an absent reference: survivors are the
    # zero prefix, followed by exact signed labels and a same-bit u32 object id.
    emit_delta(
        6,
        birth_ids=[40],
        birth_bins={
            **_identity_required([[3, 0, 0]], 6),
            op.A_SOURCE_GROUP: np.asarray([2**31 - 1], dtype=np.int64),
            op.A_SOURCE_INDEX: np.asarray([-(2**31)], dtype=np.int64),
            op.A_OBJECT_ID: np.asarray([-(2**31)], dtype=np.int64),
        },
        live_count=3,
    )

    data = _identity_finish(
        parts,
        indexes,
        rec.Statistics(
            gaussian_count=4,
            chunk_count=len(indexes),
            duration_sec=duration,
            aabb=[0.0, 0.0, 0.0, 3.0, 0.0, 0.0],
        ),
    )

    def state(t: int, rows: list[tuple[int, int, int, int]]) -> dict:
        return {
            "t": canonical_module.num(float(t)),
            "rows": [
                _identity_row(
                    gaussian_id=gaussian_id,
                    source_group=source_group,
                    source_index=source_index,
                    object_id=object_id,
                )
                for gaussian_id, source_group, source_index, object_id in rows
            ],
        }

    labelled = [(10, -17, 23, 2**32 - 1), (20, 0, 0, 0)]
    expectation = canonical(
        {
            "temporalModel": "keyframe-delta",
            "identityStates": [
                state(0, [(10, 0, 0, 0), (20, 0, 0, 0)]),
                state(1, labelled),
                state(2, [*labelled, (30, 0, 0, 0)]),
                state(3, [*labelled, (30, 0, 0, 0)]),
                state(4, [(10, 0, 0, 0), (20, 0, 0, 0), (30, 0, 0, 0)]),
                state(5, [(10, 0, 0, 0), (20, 0, 0, 0)]),
                state(6, [(10, 0, 0, 0), (20, 0, 0, 0), (40, 2**31 - 1, -(2**31), 2**31)]),
            ],
        }
    )
    return name, data, expectation


def build_optional_identity_corpus() -> list[tuple[str, str, bytes, str]]:
    """Capability-gated witnesses as ``(subdirectory, name, bytes, expectation)``."""
    return [
        ("gaussian-birth", *_build_gaussian_birth_identity()),
        ("keyframe-delta", *_build_keyframe_delta_identity()),
    ]


# --------------------------------------------------------------------------
# object-layer corpus
# --------------------------------------------------------------------------
#
# A separate generation path, like the keyframe-delta one above and for the same reason: an
# object-layer variant is a gaussian-birth file plus an Object Table and SE(3) tracks, and
# the interesting thing about it is not a flag on the `Scenario`/`FLAGS` cross-product but
# the reconstruction it composes — `center = R*c0 + T`, `orient = R (x) r0`, base first.
# `scenarios.py` already carries one `WithObjects` variant at the top level, which is where
# the Kaitai grammar and the fuzzer prove the records frame and skip; these variants go a
# level deeper into decode/compose that only the conformance harness dispatches on: a
# multi-object table with a tracked, an untracked and a background object, and a track
# composed over a base that itself moves.
#
# They live in `data/object/`, not because an object record breaks a top-level consumer —
# it does not, and the one `WithObjects` variant at the top proves that — but to keep the
# object-layer family gathered where `run.py` reaches for it, exactly as `data/keyframe/`
# gathers the temporal-model family. The `.4dgs` bytes stay generator-only; only the JSON
# expectations and CHECKSUMS are committed.
#
# Every name carries `UseChunkIndex` so the indexed read path is exercised, plus `UseCrc`.

#: Seconds of the synthetic object scenes. Short — the poses are what matter, not a long
#: clip — and every file stays well under the corpus size cap.
_OBJ_DURATION = 4.0
_OBJ_OPACITY_DURATION = 4.000000021908035
_OBJ_NONFINITE_MOTIONS = (
    np.float32(1.0),
    np.nextafter(np.float32(1.0), np.float32(np.inf)),
)
_OBJ_NONFINITE_DURATION = float(
    np.finfo(np.float64).max / ((float(_OBJ_NONFINITE_MOTIONS[0]) + float(_OBJ_NONFINITE_MOTIONS[1])) / 2)
)


def _obj_gaussians(
    positions: list[list[float]],
    object_ids: list[int],
    *,
    motions: list[list[float]] | None = None,
    rotations: list[list[float]] | None = None,
) -> fourdgs.GaussianSet:
    """A population at one instant carrying object membership, over one full-clip window.

    Sigma is finite and the window spans the whole clip, so every gaussian is live at every
    probe and the composition — not visibility — is what the states measure. `motions` and
    `rotations` default to still and identity; a variant that wants to prove `track ∘ base`
    over a moving base passes non-zero ones.
    """
    n = len(positions)
    return fourdgs.GaussianSet(
        positions=np.asarray(positions, dtype=np.float32).reshape(n, 3),
        scales=np.full((n, 3), 0.05, dtype=np.float32),
        rotations=(
            np.asarray(rotations, dtype=np.float32).reshape(n, 4)
            if rotations is not None
            else np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1))
        ),
        colors=np.tile(np.array([0.6, 0.4, 0.2, 0.9], dtype=np.float32), (n, 1)),
        motions=(
            np.asarray(motions, dtype=np.float32).reshape(n, 3)
            if motions is not None
            else np.zeros((n, 3), dtype=np.float32)
        ),
        mu_t=np.zeros(n, dtype=np.float32),
        sigma_t=np.full(n, 100.0, dtype=np.float32),  # finite, effectively non-fading over the clip
        win_lo=np.zeros(n, dtype=np.float32),
        win_hi=np.full(n, _OBJ_DURATION, dtype=np.float32),
        object_id=np.asarray(object_ids, dtype=np.uint32),
    )


def _obj_single() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """One tracked object over a static base: an Object Table entry with dynamics and an
    embedding, and a two-sample track that rotates a half-turn and translates."""
    gaussians = _obj_gaussians(
        positions=[
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [2.0, 2.0, 0.0],
            [0.0, 0.0, 1.0],
            [1.0, 1.0, 1.0],
        ],
        object_ids=[7, 7, 7, 0, 0, 0],
    )
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=4,
            entries=[
                ObjectTableEntry(
                    object_id=7,
                    label="synthetic vehicle",
                    anchor=(1.0, -2.0, 0.5),
                    # Nine distinct nonzero values, so the canonical's dynamics block discriminates
                    # a decoder that reads the record but exposes zeros or crosses a component.
                    dynamics=([2.0, -1.0, 0.5], [0.1, -0.2, 0.3], [-0.4, 0.5, -0.6]),
                    embedding=[0.25, -0.5, 0.75, 1.0],
                )
            ],
        ),
        tracks=[
            ObjectTrack(
                object_id=7,
                interpolation=TRAJECTORY_LINEAR,
                times=[1.0, _OBJ_DURATION - 1.0],
                rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.0]],
                translations=[[0.0, 0.0, 0.0], [10.0, 4.0, 0.0]],
            )
        ],
    )
    return gaussians, layer


def _obj_multi() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """Three named objects and a background: object 7 linear-tracked, object 9 step-tracked,
    object 11 untracked (a table entry whose gaussians pass through), and object 0 the
    background. Proves a multi-entry table, more than one track, an object that is labelled
    but not moved, and the entries with and without dynamics/embedding side by side."""
    gaussians = _obj_gaussians(
        positions=[
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [1.0, 1.0, 0.0],
            [2.0, 0.0, 0.0],
            [2.0, 1.0, 0.0],
            [3.0, 3.0, 0.0],
            [3.0, 3.0, 1.0],
        ],
        object_ids=[7, 7, 9, 9, 11, 11, 0, 0],
    )
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=3,
            entries=[
                ObjectTableEntry(
                    object_id=7,
                    label="vehicle",
                    anchor=(0.5, 0.0, 0.0),
                    dynamics=([1.0, -0.5, 0.25], [0.2, 0.1, -0.3], [0.05, -0.1, 0.15]),
                    embedding=[0.2, -0.4, 0.6],
                ),
                ObjectTableEntry(object_id=9, label="pedestrian", anchor=(0.5, 1.0, 0.0)),
                ObjectTableEntry(object_id=11, label="static sign", anchor=(2.0, 0.5, 0.0)),
            ],
        ),
        tracks=[
            ObjectTrack(
                object_id=7,
                interpolation=TRAJECTORY_LINEAR,
                times=[0.0, _OBJ_DURATION],
                rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.0]],
                translations=[[0.0, 0.0, 0.0], [4.0, 0.0, 0.0]],
            ),
            # A two-sample step track whose samples straddle the midpoint probe. The
            # canonical evaluates a track at 0.5*(first+last) — here 2.0, strictly between
            # 1.0 and 3.0 with no sample on it — and the states probe at half duration is
            # 2.0 as well, so both land in the open interval where a step track HOLDS its
            # left sample. The two samples differ in both rotation (identity vs a half-turn)
            # and translation, so the held value is distinct from what a linear reading would
            # interpolate: a decoder that lerped or slerped between the samples instead of
            # holding fails the diff rather than passing it unnoticed.
            ObjectTrack(
                object_id=9,
                interpolation=TRAJECTORY_STEP,
                times=[1.0, 3.0],
                rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.0]],
                translations=[[0.0, 2.0, 0.0], [0.0, 6.0, 0.0]],
            ),
        ],
    )
    return gaussians, layer


def _obj_track_composed() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """One object whose base itself moves and turns: every gaussian carries per-gaussian
    motion and a non-identity rest rotation, and a three-sample track rotates and translates
    it. The states are the assertion that motion is folded into the base center first and the
    track transports the result — `R*(c0 + motion*t) + T` — and that orientation composes as
    `R (x) r0` rather than replacing r0."""
    # The rest orientation turns about x and the track turns about y (xyzw). The axes must
    # differ: quaternion multiplication commutes for two rotations about the same axis, so a
    # same-axis pair would make `R (x) r0` and the wrong order `r0 (x) R` produce the identical
    # canonical, and a decoder that composed backwards would pass. Non-commuting axes make the
    # order observable — `R (x) r0` differs from `r0 (x) R` — so the row proves order, not just
    # that some product was taken.
    rest = [0.3826834, 0.0, 0.0, 0.9238795]
    gaussians = _obj_gaussians(
        positions=[
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [1.0, 1.0, 0.0],
            [0.5, 0.5, 0.0],
            [0.0, 0.0, 1.0],
        ],
        object_ids=[7, 7, 7, 7, 7, 7],
        motions=[[0.2, 0.0, 0.0], [0.0, 0.2, 0.0], [0.0, 0.0, 0.1], [0.1, 0.1, 0.0], [0.0, 0.0, 0.0], [-0.1, 0.0, 0.0]],
        rotations=[rest, rest, rest, rest, rest, rest],
    )
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[ObjectTableEntry(object_id=7, label="turning object", anchor=(0.5, 0.5, 0.0))],
        ),
        tracks=[
            ObjectTrack(
                object_id=7,
                interpolation=TRAJECTORY_LINEAR,
                times=[0.0, 0.5 * _OBJ_DURATION, _OBJ_DURATION],
                rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.7071068, 0.0, 0.7071068], [0.0, 1.0, 0.0, 0.0]],
                translations=[[0.0, 0.0, 0.0], [2.0, 1.0, 0.0], [4.0, 0.0, 0.0]],
            )
        ],
    )
    return gaussians, layer


def _obj_fixture_layer(label: str) -> ObjectLayer:
    """One fixed half-turn track that opposes stored and emitted tie order."""
    return ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[ObjectTableEntry(object_id=7, label=label, anchor=(0.0, 0.0, 0.0))],
        ),
        tracks=[
            ObjectTrack(
                object_id=7,
                times=[0.0, _OBJ_DURATION],
                # A half-turn around Z reverses X.  Exact ascending motion order is
                # therefore the opposite of the rounded composed-state order.
                rotations=[[0.0, 0.0, 1.0, 0.0]] * 2,
                translations=[[0.0, 0.0, 0.0]] * 2,
            )
        ],
    )


def _obj_tied_gaussians() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """Two primary-key ties whose motion becomes visible only after composition."""
    gaussians = _obj_gaussians(
        positions=[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
        object_ids=[7, 7],
        # Descending emitted-state order on purpose.  The paired encoding reverses it.
        motions=[[4e-7, 0.0, 0.0], [1e-7, 0.0, 0.0]],
    )
    # The position and motion pitches are derived from median scale.  This makes the two
    # decoded motions adjacent representable bins which round to the same six-decimal
    # primary key, rather than relying on a hand-written unencodable float.
    gaussians.scales[:] = 2e-6
    return gaussians, _obj_fixture_layer("tied gaussians")


def _obj_tied_gaussians_reordered() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    gaussians, layer = _obj_tied_gaussians()
    order = np.array([1, 0], dtype=np.intp)
    return _permute_gaussians(gaussians, order), layer


def _permute_gaussians(gaussians: fourdgs.GaussianSet, order: np.ndarray) -> fourdgs.GaussianSet:
    """Copy one fixture in a different physical order, preserving every decoded field."""
    return fourdgs.GaussianSet(
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


def _obj_content_order_sum() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """Resident and content orders land on opposite sides of cancellation."""
    gaussians = _obj_gaussians(
        positions=[[0.0, 0.0, 0.0]] * 3,
        # Resident order 3,1,2 sums small,+large,-large.  Content order is 1,2,3.
        object_ids=[3, 1, 2],
    )
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[
                ObjectTableEntry(object_id=1, label="positive", anchor=(0.0, 0.0, 0.0)),
                ObjectTableEntry(object_id=2, label="negative", anchor=(0.0, 0.0, 0.0)),
                ObjectTableEntry(object_id=3, label="small", anchor=(0.0, 0.0, 0.0)),
            ],
        ),
        tracks=[
            ObjectTrack(
                object_id=object_id,
                times=[0.0, _OBJ_DURATION],
                rotations=[[0.0, 0.0, 0.0, 1.0]] * 2,
                translations=[translation] * 2,
            )
            for object_id, translation in (
                (1, [1e20, 0.0, 0.0]),
                (2, [-1e20, 0.0, 0.0]),
                (3, [3.25, 0.0, 0.0]),
            )
        ],
    )
    return gaussians, layer


def _obj_opacity_order() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """Resident and content opacity sums straddle a six-decimal boundary."""
    count = 64
    gaussians = _obj_gaussians(
        positions=[[0.0, 0.0, 0.0]] * count,
        object_ids=[7] * count,
    )
    gaussians.colors[:, 3] = 1.0
    # Physical order groups permanent, medium and boundary marginals. The portable key
    # orders the finite sigma values first and never-fading values last.
    gaussians.sigma_t[:32] = np.inf
    gaussians.sigma_t[32:63] = 3.0311653
    gaussians.sigma_t[63] = 1.0
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[ObjectTableEntry(object_id=7, label="opacity order", anchor=(0.0, 0.0, 0.0))],
        )
    )
    return gaussians, layer


def _obj_wide_unit_aggregate() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """A finite f32 whose canonical units exceed every signed 128-bit accumulator."""

    wide_rows = canonical_module.SAMPLE + 1
    gaussians = _obj_gaussians(
        # Sixteen portable zero rows fill the root/state samples. The wide rows are still
        # live and included in each aggregate, so the fixture tests accumulator width
        # without making ordinary sampled-f32 spelling part of this contract.
        positions=[[0.0, 0.0, 0.0]] * canonical_module.SAMPLE
        + [[float(np.finfo(np.float32).max), 0.0, 0.0]] * wide_rows,
        object_ids=[7] * (canonical_module.SAMPLE + wide_rows),
    )
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[ObjectTableEntry(object_id=7, label="wide units", anchor=(0.0, 0.0, 0.0))],
        )
    )
    # A majority of large, unsampled scales makes the global position pitch wide enough
    # to encode zero and max-f32 in one Quantization grid. The 16 sampled zero rows keep
    # their ordinary, small scale values.
    gaussians.scales[canonical_module.SAMPLE :] = np.float32(1.6e30)
    return gaussians, layer


def _obj_tied_nonfinite_rows() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    """Rounded motion ties that become one finite and one null center at the last probe."""

    gaussians = _obj_gaussians(
        positions=[[0.0, 0.0, 0.0]] * 2,
        object_ids=[7, 7],
        motions=[
            [float(_OBJ_NONFINITE_MOTIONS[0]), 0.0, 0.0],
            [float(_OBJ_NONFINITE_MOTIONS[1]), 0.0, 0.0],
        ],
    )
    # A fine pitch preserves the adjacent f32 motions; both still round to 1.000000 in
    # the primary content key. Infinite sigma/window keeps them live at the huge f64 probe.
    gaussians.scales[:] = 2e-6
    gaussians.sigma_t[:] = np.inf
    gaussians.win_hi[:] = np.inf
    layer = ObjectLayer(
        table=ObjectTable(
            embedding_dim=0,
            entries=[ObjectTableEntry(object_id=7, label="non-finite rows", anchor=(0.0, 0.0, 0.0))],
        )
    )
    return gaussians, layer


def _obj_tied_nonfinite_rows_reordered() -> tuple[fourdgs.GaussianSet, ObjectLayer]:
    gaussians, layer = _obj_tied_nonfinite_rows()
    return _permute_gaussians(gaussians, np.array([1, 0], dtype=np.intp)), layer


#: (name, builder). The ordinary decode-and-compose cases are followed by canonical-order,
#: exact-sum and accumulator-width adversaries.
OBJECT_VARIANTS = (
    ("SingleObject-UseChunkIndex-UseCrc", _obj_single),
    ("MultiObject-UseChunkIndex-UseCrc", _obj_multi),
    ("ObjectTrackComposed-UseChunkIndex-UseCrc", _obj_track_composed),
    ("ObjectTiedGaussians-UseChunkIndex-UseCrc", _obj_tied_gaussians),
    ("ObjectTiedGaussiansReordered-UseChunkIndex-UseCrc", _obj_tied_gaussians_reordered),
    ("ObjectContentOrderSum-UseChunkIndex-UseCrc", _obj_content_order_sum),
    ("ObjectOpacityOrder-UseChunkIndex-UseCrc", _obj_opacity_order),
    ("ObjectWideUnitAggregate-UseChunkIndex-UseCrc", _obj_wide_unit_aggregate),
    ("ObjectTiedNonFiniteRows-UseChunkIndex-UseCrc", _obj_tied_nonfinite_rows),
    (
        "ObjectTiedNonFiniteRowsReordered-UseChunkIndex-UseCrc",
        _obj_tied_nonfinite_rows_reordered,
    ),
)


def _same_canonical_decimal(rounded: float, exact: canonical_module.ExactNumber) -> bool:
    """Compare rounded and exact JSON numbers without either type's equality rules."""

    return Decimal(str(rounded)) == Decimal(exact.token)


def build_object_corpus() -> list[tuple[str, bytes, str]]:
    """Every object-layer variant: `(name, bytes, expectation)`.

    The expectation is the read-back canonical summary, whose `objects` block carries the
    table and tracks and whose `states` carry the post-track centers and orientations at
    three scene-clock probes — the reconstruction `track ∘ base` that the whole layer exists
    to make, and the statement every SDK that decodes objects is diffed against.
    """
    out: list[tuple[str, bytes, str]] = []
    summaries: dict[str, dict] = {}
    resident_tie_rows: dict[str, list] = {}
    resident_nonfinite_rows: dict[str, list] = {}
    for name, builder in OBJECT_VARIANTS:
        gaussians, layer = builder()
        if name.startswith("ObjectOpacityOrder"):
            duration = _OBJ_OPACITY_DURATION
        elif name.startswith("ObjectTiedNonFiniteRows"):
            duration = _OBJ_NONFINITE_DURATION
        else:
            duration = _OBJ_DURATION
        options = fourdgs.WriteOptions(
            profile="default",
            cutoff=1e-20 if name.startswith("ObjectOpacityOrder") else DEFAULT_CUTOFF,
            min_chunk_gaussians=10**9,
            max_depth=0,
            write_index=True,
            write_crc=True,
            library="4dgs conformance generator",
            scene_profile="objects",
            objects=layer,
        )
        buf = io.BytesIO()
        fourdgs.write(buf, gaussians, duration, options=options)
        data = buf.getvalue()
        scene = fourdgs.read(data)
        if name.startswith("ObjectTiedGaussians"):
            keys = canonical_module._stable_keys(scene.gaussians)
            if len(keys) != 2 or keys[0] != keys[1]:
                raise AssertionError(f"{name}: the adversarial primary keys do not tie")
            state = scene.gaussians.state_at(0.5 * _OBJ_DURATION, scene.header.cutoff)
            centers, _ = scene.objects.apply(
                centers=state["centers"],
                orientations=state["orientations"],
                object_ids=state["object_id"],
                t=0.5 * _OBJ_DURATION,
            )
            resident_tie_rows[name] = [[canonical_module.num(v) for v in row] for row in centers]
        if name.startswith("ObjectTiedNonFiniteRows"):
            keys = canonical_module._stable_keys(scene.gaussians)
            if len(keys) != 2 or keys[0] != keys[1]:
                raise AssertionError(f"{name}: the finite/null primary keys do not tie")
            state = scene.gaussians.state_at(duration, scene.header.cutoff)
            centers, _ = scene.objects.apply(
                centers=state["centers"],
                orientations=state["orientations"],
                object_ids=state["object_id"],
                t=duration,
            )
            rows = [[canonical_module.num(v) for v in row] for row in centers]
            if [row[0] is None for row in rows].count(False) != 1 or [row[0] is None for row in rows].count(True) != 1:
                raise AssertionError(f"{name}: expected one finite and one null row, got {rows!r}")
            resident_nonfinite_rows[name] = rows
        # The same full summarize the runners call, so the committed expectation matches what
        # a decoder prints — a file written with a CRC and an index reports `summaryCrcOk`
        # and chunk intervals, and omitting those here would diff against every runner.
        summary = summarize(
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
        summaries[name] = summary
        if name == "ObjectContentOrderSum-UseChunkIndex-UseCrc":
            state = scene.gaussians.state_at(0.5 * _OBJ_DURATION, scene.header.cutoff)
            centers, _ = scene.objects.apply(
                centers=state["centers"],
                orientations=state["orientations"],
                object_ids=state["object_id"],
                t=0.5 * _OBJ_DURATION,
            )
            resident_raw = 0.0
            for row in centers:
                resident_raw += float(row[0])
            resident = canonical_module.num(resident_raw)
            emitted = summary["states"][1]["aggregate"]["positionSum"][0]
            if not isinstance(emitted, canonical_module.ExactNumber):
                raise AssertionError(f"{name}: exact-unit position witness is not exact: {emitted!r}")
            # Compare the rounded resident sum and exact-unit result in one decimal
            # domain. ExactNumber deliberately does not compare equal to a float, so a
            # direct comparison here could never detect a fixture that had drifted until
            # the two strategies produced the same number.
            if _same_canonical_decimal(resident, emitted):
                raise AssertionError(f"{name}: resident and content-order sums no longer differ")
        if name == "ObjectOpacityOrder-UseChunkIndex-UseCrc":
            state = scene.gaussians.state_at(0.5 * duration, scene.header.cutoff)
            row_for_index = {int(index): row for row, index in enumerate(state["indices"])}
            resident_raw = 0.0
            for value in state["opacity"]:
                resident_raw += float(value)
            keys = canonical_module._stable_keys(scene.gaussians)
            content_raw = 0.0
            for index in sorted(range(scene.gaussians.count), key=keys.__getitem__):
                content_raw += float(state["opacity"][row_for_index[index]])
            exact = summary["states"][1]["aggregate"]["opacitySum"]
            if canonical_module.num(resident_raw) != 57.0713:
                raise AssertionError(f"{name}: resident opacity witness moved to {resident_raw!r}")
            if canonical_module.num(content_raw) != 57.071299:
                raise AssertionError(f"{name}: content opacity witness moved to {content_raw!r}")
            if not isinstance(exact, canonical_module.ExactNumber) or exact.token != "57.071301":
                raise AssertionError(f"{name}: exact-unit opacity witness moved to {exact!r}")
        if name == "ObjectWideUnitAggregate-UseChunkIndex-UseCrc":
            expected = "5784799892854990616798971119236787732480.0"
            order = canonical_module._stable_order(scene.gaussians)
            wide_index = int(np.argmax(scene.gaussians.positions[:, 0]))
            if wide_index in order[: canonical_module.SAMPLE]:
                raise AssertionError(f"{name}: wide row leaked into the ordinary root sample")
            decoded = float(scene.gaussians.positions[wide_index, 0])
            if not math.isfinite(decoded) or decoded != float(np.finfo(np.float32).max):
                raise AssertionError(f"{name}: max-f32 encoded row moved to {decoded!r}")
            if any(position[0] != 0.0 for position in summary["sample"]["positions"]):
                raise AssertionError(f"{name}: wide row leaked into the ordinary root sample")
            if any(scale[0] > 1.0 for scale in summary["sample"]["scales"]):
                raise AssertionError(f"{name}: wide quantization scale leaked into the root sample")
            totals = [summary["aggregate"]["positionSum"][0]] + [
                state["aggregate"]["positionSum"][0] for state in summary["states"]
            ]
            if any(not isinstance(total, canonical_module.ExactNumber) or total.token != expected for total in totals):
                raise AssertionError(f"{name}: wide root/state totals moved to {totals!r}")
            units = int(Decimal(expected) * (10**canonical_module.FLOAT_DECIMALS))
            if units <= 2**127 - 1:
                raise AssertionError(f"{name}: scaled total no longer exceeds signed 128-bit")
            expected_live = 2 * canonical_module.SAMPLE + 1
            if any(state["liveCount"] != str(expected_live) for state in summary["states"]):
                raise AssertionError(f"{name}: wide row is not live in every state aggregate")
            if any(any(position[0] != 0.0 for position in state["sample"]["positions"]) for state in summary["states"]):
                raise AssertionError(f"{name}: wide row leaked into an ordinary state sample")
        expectation = canonical(summary)
        out.append((name, data, expectation))

    tied = "ObjectTiedGaussians-UseChunkIndex-UseCrc"
    reordered = "ObjectTiedGaussiansReordered-UseChunkIndex-UseCrc"
    if resident_tie_rows[tied] == resident_tie_rows[reordered]:
        raise AssertionError("the tied pair's resident-order state rows do not differ")
    if canonical(summaries[tied]) != canonical(summaries[reordered]):
        raise AssertionError("the tied pair does not share one order-independent canonical summary")
    nonfinite = "ObjectTiedNonFiniteRows-UseChunkIndex-UseCrc"
    nonfinite_reordered = "ObjectTiedNonFiniteRowsReordered-UseChunkIndex-UseCrc"
    if resident_nonfinite_rows[nonfinite] == resident_nonfinite_rows[nonfinite_reordered]:
        raise AssertionError("the finite/null pair's resident-order state rows do not differ")
    if canonical(summaries[nonfinite]) != canonical(summaries[nonfinite_reordered]):
        raise AssertionError("the finite/null pair does not share one canonical summary")
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
                    # Nine distinct nonzero values, so the canonical's dynamics block discriminates
                    # a decoder that reads the record but exposes zeros or crosses a component.
                    dynamics=([2.0, -1.0, 0.5], [0.1, -0.2, 0.3], [-0.4, 0.5, -0.6]),
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


class Corpus(NamedTuple):
    """One generator run, including fresh expectations that cannot include stale files."""

    checksums: dict[str, str]
    expectations: dict[str, str]


def write_corpus(target: str) -> Corpus:
    os.makedirs(target, exist_ok=True)
    checksums: dict[str, str] = {}
    expectations: dict[str, str] = {}
    for scenario, flags in scenarios.variants():
        name = scenarios.variant_name(scenario, flags)
        data, expectation = build(scenario, flags)
        with open(os.path.join(target, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(target, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        checksums[f"{name}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"{name}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[name] = expectation + "\n"

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
        with open(os.path.join(keyframe_dir, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        checksums[f"keyframe/{name}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"keyframe/{name}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[f"keyframe/{name}"] = expectation + "\n"

    # Object-layer variants live in their own subdirectory too, for the same gathering
    # reason as keyframe/: run.py is the one consumer that reaches into it. Unlike a
    # keyframe-delta file, an object record does not break a top-level consumer — the one
    # WithObjects variant in the cross-product sits at the top level and the Kaitai grammar
    # and fuzzer read it — but the object-layer decode/compose family belongs together, and
    # the harness dispatches on the subdirectory the same way.
    object_dir = os.path.join(target, "object")
    os.makedirs(object_dir, exist_ok=True)
    for name, data, expectation in build_object_corpus():
        with open(os.path.join(object_dir, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(object_dir, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        checksums[f"object/{name}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"object/{name}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[f"object/{name}"] = expectation + "\n"

    # Optional identity defaults are capability-gated valid files.  Their two temporal
    # models stay in named subdirectories so downloadable-corpus manifests can report the
    # model without interpreting a Header (which would be wrong for invalid files).
    for model, name, data, expectation in build_optional_identity_corpus():
        directory = os.path.join(target, "identity", model)
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(directory, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        qualified = f"identity/{model}/{name}"
        checksums[f"{qualified}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"{qualified}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[qualified] = expectation + "\n"

    # The resident-only top-level summary cannot prove an instant contribution rule.
    # Keep these explicit-query witnesses in their own capability-gated family, where
    # old SDK runners skip them until their language layer implements the invocation.
    chunk_window_dir = os.path.join(target, chunk_window.FAMILY)
    os.makedirs(chunk_window_dir, exist_ok=True)
    for name, data, expectation in build_chunk_window_corpus():
        with open(os.path.join(chunk_window_dir, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(chunk_window_dir, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        qualified = f"{chunk_window.PREFIX}{name}"
        checksums[f"{qualified}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"{qualified}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[qualified] = expectation + "\n"

    invalid_dir = os.path.join(target, "invalid")
    late_front_matter_dir = os.path.join(invalid_dir, "late-front-matter")
    os.makedirs(invalid_dir, exist_ok=True)
    os.makedirs(late_front_matter_dir, exist_ok=True)
    for name, data, expectation in build_invalid():
        qualified = f"invalid/{name}"
        if f"{invalid.LATE_FRONT_MATTER_PREFIX}{name}" in invalid.STREAMED_ONLY_REFUSALS:
            directory = late_front_matter_dir
            qualified = f"{invalid.LATE_FRONT_MATTER_PREFIX}{name}"
        else:
            directory = invalid_dir
        with open(os.path.join(directory, f"{name}.4dgs"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(directory, f"{name}.json"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(expectation + "\n")
        checksums[f"{qualified}.4dgs"] = hashlib.sha256(data).hexdigest()
        checksums[f"{qualified}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()
        expectations[qualified] = expectation + "\n"
    return Corpus(checksums, expectations)


def write_checksums(checksums: dict[str, str]) -> None:
    lines = [
        "# SHA-256 of each generated variant and expectation, asserted by `generate.py --verify`.",
        "# Written by the generator; do not edit by hand.",
    ]
    lines += [f"{digest}  {name}" for name, digest in sorted(checksums.items())]
    with open(CHECKSUMS, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def read_expectations() -> dict[str, str]:
    """Read committed expectations before regeneration overwrites their files."""
    out: dict[str, str] = {}
    for root, prefix in (
        (DATA, ""),
        (INVALID, "invalid/"),
        (LATE_FRONT_MATTER, invalid.LATE_FRONT_MATTER_PREFIX),
        (KEYFRAME, "keyframe/"),
        (OBJECT, "object/"),
        (os.path.join(IDENTITY, "gaussian-birth"), "identity/gaussian-birth/"),
        (os.path.join(IDENTITY, "keyframe-delta"), "identity/keyframe-delta/"),
        (CHUNK_WINDOW, chunk_window.PREFIX),
    ):
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            if name.endswith(".json"):
                with open(os.path.join(root, name), encoding="utf-8") as fh:
                    out[prefix + name[: -len(".json")]] = fh.read()
    return out


def read_checksums() -> dict[str, str]:
    out: dict[str, str] = {}
    if not os.path.exists(CHECKSUMS):
        return out
    with open(CHECKSUMS, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            digest, name = line.split()
            out[name] = digest
    return out


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="generate or verify the 4dgs conformance corpus")
    parser.add_argument("--verify", action="store_true", help="regenerate and assert nothing moved")
    args = parser.parse_args(argv)

    committed_expectations = read_expectations() if args.verify else {}
    corpus = write_corpus(DATA)
    checksums = corpus.checksums
    total = sum(os.path.getsize(os.path.join(DATA, *name.split("/"))) for name in checksums)
    variants = sum(name.endswith(".4dgs") for name in checksums)
    print(f"{variants} variants, {total / 1024:.0f} KiB in {DATA}")

    if total > MAX_DATA_BYTES:
        print(f"error: corpus is {total} bytes, over the {MAX_DATA_BYTES} cap — prune variants", file=sys.stderr)
        return 1

    if not args.verify:
        write_checksums(checksums)
        print(f"wrote {CHECKSUMS}")
        return 0

    return 0 if _verify(corpus, committed_expectations) else 1


def _verify(corpus: Corpus, committed_expectations: dict[str, str]) -> bool:
    """Assert the corpus matches what is committed and that the encoder is stable."""
    checksums = corpus.checksums
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

    fresh_expectations = corpus.expectations
    for name, text in sorted(fresh_expectations.items()):
        if name not in committed_expectations:
            failures.append(f"{name}.json: no committed expectation")
        elif committed_expectations[name] != text:
            failures.append(f"{name}.json: {_first_difference(committed_expectations[name], text)}")
    for name in committed_expectations:
        if name not in fresh_expectations:
            failures.append(f"{name}.json: committed expectation has no variant")

    # Determinism: a second run must produce the same bytes.
    second: dict[str, str] = {}

    def record(name: str, data: bytes, expectation: str) -> None:
        second[f"{name}.4dgs"] = hashlib.sha256(data).hexdigest()
        second[f"{name}.json"] = hashlib.sha256((expectation + "\n").encode()).hexdigest()

    for scenario, flags in scenarios.variants():
        data, expectation = build(scenario, flags)
        record(scenarios.variant_name(scenario, flags), data, expectation)
    for name, data, expectation in build_invalid():
        qualified = (
            f"{invalid.LATE_FRONT_MATTER_PREFIX}{name}"
            if f"{invalid.LATE_FRONT_MATTER_PREFIX}{name}" in invalid.STREAMED_ONLY_REFUSALS
            else f"invalid/{name}"
        )
        record(qualified, data, expectation)
    for name, data, expectation in build_keyframe_delta_corpus():
        record(f"keyframe/{name}", data, expectation)
    for name, data, expectation in build_object_corpus():
        record(f"object/{name}", data, expectation)
    for model, name, data, expectation in build_optional_identity_corpus():
        record(f"identity/{model}/{name}", data, expectation)
    for name, data, expectation in build_chunk_window_corpus():
        record(f"{chunk_window.PREFIX}{name}", data, expectation)
    for name, digest in checksums.items():
        if second.get(name) != digest:
            failures.append(f"{name}: encoder is not deterministic between runs")

    if failures:
        print("conformance corpus verification FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print("\nif the change was intended, rerun without --verify and commit the result", file=sys.stderr)
        return False

    variants = sum(name.endswith(".4dgs") for name in checksums)
    print(f"verified {variants} variants: checksums and expectations match, and the encoder is deterministic")
    return True


def _first_difference(committed: str, fresh: str) -> str:
    """Name the first character-level expectation difference."""
    old, new = committed.splitlines(keepends=True), fresh.splitlines(keepends=True)
    for i, (a, b) in enumerate(zip(old, new, strict=False), start=1):
        if a != b:
            column = next(j for j, (x, y) in enumerate(zip_longest(a, b), start=1) if x != y)
            return f"line {i}, column {column}: committed {a!r}, fresh decode {b!r}"
    shared = min(len(old), len(new))
    extra, side = (new, "a fresh decode") if len(new) > len(old) else (old, "the committed file")
    return (
        f"{len(old)} committed lines against {len(new)} from a fresh decode; "
        f"line {shared + 1} is in {side} only: {extra[shared]!r}"
    )


if __name__ == "__main__":
    sys.exit(main())
