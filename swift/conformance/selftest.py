#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The Python half of the Swift canonical-JSON self-test.

Builds the same synthetic scene as `swift/conformance/Support/Synthetic.swift`, from the
same seed, and prints `canonical.py`'s summary of it. CI runs both and asserts the two
documents parse equal:

    swift run --package-path swift canonical_selftest > swift.json
    python swift/conformance/selftest.py --compare swift.json

The point is to separate two questions that would otherwise arrive together. When the Rust
C ABI lands and the Swift runners meet the corpus, a disagreement could be a wrong decode
or a wrong summary; this settles the second one in advance, with no decoder involved.

The generator is mirrored line for line rather than shared, because sharing it would mean
one of the two languages generating the other's numbers — which is exactly the coupling
the conformance suite exists to avoid.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from types import SimpleNamespace

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "conformance"))

import canonical

GAUSSIAN_COUNT = 300
SH_DEGREE = 2
SEED = 0x4D4753310D0A0001


class LCG:
    """The same sequence `Synthetic.LCG` produces, in the same order."""

    def __init__(self, state: int) -> None:
        self.state = state

    def next(self) -> int:
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return self.state

    def unit(self) -> float:
        # 24 significant bits: exactly representable in both float64 and float32, so no
        # rounding happens on either side of the comparison.
        return (self.next() >> 40) / 16777216.0

    def value(self, lo: float, hi: float) -> np.float32:
        # Computed in float64 and narrowed exactly once, matching the Swift generator.
        return np.float32(lo + self.unit() * (hi - lo))


@dataclass
class Header:
    duration_sec: float
    cutoff: float
    profile: str
    library: str
    sh_degree: int
    temporal_model: str
    has_audio: bool
    attributes: dict


@dataclass
class Gaussians:
    count: int
    positions: np.ndarray
    scales: np.ndarray
    rotations: np.ndarray
    colors: np.ndarray
    motions: np.ndarray
    mu_t: np.ndarray
    sigma_t: np.ndarray
    win_lo: np.ndarray
    win_hi: np.ndarray
    sh_degree: int
    sh: np.ndarray


@dataclass
class AudioSource:
    source_id: int
    name: str
    codec: str
    channel_layout: str
    start_sec: float
    duration_sec: float
    gain: float
    spatial: bool
    loop: bool
    position: list
    rotation: list
    keyframes: list
    interpolation: str
    data: bytes

    def state_at(self, t: float):
        elapsed = max(0.0, t - self.start_sec)
        return SimpleNamespace(
            active=t >= self.start_sec and (self.loop or t < self.start_sec + self.duration_sec),
            local_time=elapsed % self.duration_sec if self.loop else min(elapsed, self.duration_sec),
            position=self.position,
            rotation=self.rotation,
            gain=self.gain,
        )


@dataclass
class Camera:
    fov_y_deg: float
    position: list
    target: list
    times: list
    positions: list
    targets: list
    interpolation: str
    loop: bool


@dataclass
class Metadata:
    name: str
    entries: dict


@dataclass
class Attachment:
    name: str
    media_type: str
    data: bytes


@dataclass
class Statistics:
    gaussian_count: int
    chunk_count: int
    duration_sec: float
    aabb: list


@dataclass
class SummaryOffset:
    group_opcode: int
    group_start: int
    group_length: int


def build_gaussians() -> Gaussians:
    rng = LCG(SEED)
    n = GAUSSIAN_COUNT
    sh_width = ((SH_DEGREE + 1) ** 2 - 1) * 3

    positions, scales, rotations, colors, motions = [], [], [], [], []
    mu_t, sigma_t, win_lo, win_hi, sh = [], [], [], [], []

    for i in range(n):
        positions.append([rng.value(-10, 10) for _ in range(3)])
        scales.append([rng.value(0.001, 0.5) for _ in range(3)])
        rotations.append([rng.value(-1, 1) for _ in range(4)])
        colors.append([rng.value(0, 1) for _ in range(4)])
        # Every fifth gaussian is motionless — and draws no numbers, so the sequence
        # stays in step with the Swift side.
        if i % 5 == 0:
            motions.append([np.float32(0), np.float32(0), np.float32(0)])
        else:
            motions.append([rng.value(-2, 2) for _ in range(3)])
        mu_t.append(rng.value(0, 4))
        sigma_t.append(np.float32(np.inf) if i % 3 == 0 else rng.value(0.001, 1.5))
        lo = rng.value(0, 3)
        win_lo.append(lo)
        win_hi.append(np.float32(float(lo) + 1.25))
        sh.append([rng.next() >> 56 for _ in range(sh_width)])

    gaussians = Gaussians(
        count=n,
        positions=np.array(positions, dtype=np.float32),
        scales=np.array(scales, dtype=np.float32),
        rotations=np.array(rotations, dtype=np.float32),
        colors=np.array(colors, dtype=np.float32),
        motions=np.array(motions, dtype=np.float32),
        mu_t=np.array(mu_t, dtype=np.float32),
        sigma_t=np.array(sigma_t, dtype=np.float32),
        win_lo=np.array(win_lo, dtype=np.float32),
        win_hi=np.array(win_hi, dtype=np.float32),
        sh_degree=SH_DEGREE,
        sh=np.array(sh, dtype=np.uint8),
    )
    # A deliberate tie, so that the content order has to break one. Two gaussians identical
    # in every decoded value cannot change any number the summary emits.
    for array in (
        gaussians.positions,
        gaussians.scales,
        gaussians.rotations,
        gaussians.colors,
        gaussians.motions,
        gaussians.sh,
    ):
        array[8] = array[7]
    for array in (gaussians.mu_t, gaussians.sigma_t, gaussians.win_lo, gaussians.win_hi):
        array[8] = array[7]
    return gaussians


def compare(summary: dict, path: str) -> int:
    """Diff the Swift runner's output against this one, naming the first key that differs.

    Reported per top-level key rather than as a text diff: the two documents are the same
    shape, so the interesting question is always *which statement* disagrees, and a line
    diff of a 10 KB pretty-printed object buries that.
    """
    with open(path, encoding="utf-8") as fh:
        theirs = json.load(fh)
    ours = json.loads(json.dumps(summary, allow_nan=False))
    if ours == theirs:
        print("canonical JSON: Swift and canonical.py agree")
        return 0
    for key in sorted(set(ours) | set(theirs)):
        if ours.get(key) != theirs.get(key):
            print(f"::error::divergence at {key}")
            print("  swift :", json.dumps(theirs.get(key))[:800])
            print("  python:", json.dumps(ours.get(key))[:800])
    return 1


def main() -> int:
    gaussians = build_gaussians()
    header = Header(
        duration_sec=4.5,
        cutoff=0.037,
        # Mirrors `Synthetic.swift`. The empty profile is deliberate: it is the one value a
        # runner that drops the field would still get right, so the pair is what separates
        # "decoded an empty string" from "never read the field at all".
        profile="",
        library="4dgs synthetic",
        sh_degree=SH_DEGREE,
        temporal_model="gaussian-birth",
        has_audio=True,
        attributes={"up_axis": "z", "visibility_profile": "gaussian", "note": 'quote" and \\ and \n'},
    )
    summary = canonical.summarize(
        header,
        gaussians,
        [
            AudioSource(
                source_id=7,
                name="speaker",
                codec="opus",
                channel_layout="mono",
                start_sec=0.25,
                duration_sec=4.0,
                gain=1.0,
                spatial=True,
                loop=False,
                position=[1.0, 0.5, -1.0],
                rotation=[0.0, 0.0, 0.0, 1.0],
                keyframes=[],
                interpolation="linear",
                data=bytes(i % 251 for i in range(5000)),
            )
        ],
        [(0.0, 1.5), (1.5, 3.0), (3.0, 4.5)],
        camera=Camera(
            fov_y_deg=62.5,
            position=[1.0, 2.0, 3.0],
            target=[0.0, 0.0, 0.0],
            times=[i * 0.75 for i in range(6)],
            positions=[[float(i), 1.0, 2.0] for i in range(6)],
            targets=[[0.0, float(i), 0.0] for i in range(6)],
            interpolation="catmull-rom",
            loop=True,
        ),
        metadata=[
            Metadata(name="producer", entries={"tool": "synthetic", "tab": "a\tb"}),
            Metadata(name="licence", entries={"spdx": "CC-BY-4.0"}),
        ],
        attachments=[
            Attachment(name="thumb.png", media_type="image/png", data=bytes(i % 256 for i in range(777))),
            Attachment(name="notes.txt", media_type="text/plain", data=b"hello"),
        ],
        statistics=Statistics(
            gaussian_count=GAUSSIAN_COUNT, chunk_count=3, duration_sec=4.5, aabb=[-10, -10, -10, 10, 10, 10]
        ),
        summary_offsets=[
            SummaryOffset(group_opcode=0x08, group_start=1024, group_length=256),
            SummaryOffset(group_opcode=0x0C, group_start=1280, group_length=48),
            SummaryOffset(group_opcode=0x0F, group_start=1328, group_length=60),
        ],
        summary_crc_ok=True,
    )
    if len(sys.argv) == 3 and sys.argv[1] == "--compare":
        return compare(summary, sys.argv[2])
    print(canonical.canonical(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
