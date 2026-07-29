# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Scenario and feature-flag matrix for the conformance corpus.

This file is the single declaration of what a conforming implementation must handle.
Every scene here is **synthetic and deterministic**: generated from a fixed seed, with no
captured data of any kind. That is deliberate — the corpus has to be redistributable
without a licence question, reproducible byte-for-byte, and small.

A *variant* is one scenario crossed with a set of feature flags. The generator writes each
variant twice: as a `.4dgs` file and as a `.json` statement of exactly what a correct
decoder must produce from it. Implementations declare which variants they support and the
harness runs those.

Adding a case here — never to one language's test — is how the contract grows.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# Feature flags
# --------------------------------------------------------------------------

FLAGS = (
    "UseChunks",  # split gaussians across more than one chunk
    "UseChunkIndex",  # write the chunk index (seekable)
    "UseStatistics",  # write the statistics record
    "UseSummaryOffset",  # write summary offset records
    "UseCrc",  # write and expect the summary CRC
    "Quantized",  # lossy attribute quantization rather than the finest grid
    "SHDegree1",
    "SHDegree2",
    "DeltaStreams",  # delta-coded attribute streams rather than raw
    "WithAudio",  # embed an audio track
    "WithLargeAudio",  # embed a track larger than an indexed reader's head probe
    "WithCamera",  # embed a camera trajectory
    "WithMetadata",
    "WithAttachment",
    "AddExtraDataToRecords",  # append unknown trailing fields + a private-range record
)


@dataclass(frozen=True)
class Scenario:
    """A scene shape, independent of which features are switched on."""

    name: str
    gaussians: int
    duration_sec: float
    windows: int
    #: Fraction of gaussians that never fade (`sigma_t = +inf`).
    always_visible: float = 0.0
    #: Fraction with exactly zero velocity.
    still: float = 0.0
    #: When true every gaussian spans the whole timeline, so the chunk tree cannot
    #: partition and seeking costs the whole scene. The format stores this correctly;
    #: the point of the scenario is that a decoder must not assume otherwise.
    long_lived: bool = False
    #: Flags that make no sense for this scenario and are skipped.
    excludes: tuple[str, ...] = field(default_factory=tuple)


SCENARIOS: tuple[Scenario, ...] = (
    # The degenerate cases first: they are where decoders actually break.
    Scenario("NoData", gaussians=0, duration_sec=0.0, windows=1, excludes=("SHDegree1", "SHDegree2", "DeltaStreams")),
    Scenario("OneGaussian", gaussians=1, duration_sec=1.0, windows=1, excludes=("UseChunks", "DeltaStreams")),
    Scenario("OneWindow", gaussians=64, duration_sec=2.0, windows=1),
    Scenario("TenWindows", gaussians=640, duration_sec=20.0, windows=10),
    # Mixed temporal behaviour in one file: the combination that exercises both
    # per-gaussian precision rules at once.
    Scenario("MixedLifetimes", gaussians=512, duration_sec=8.0, windows=4, always_visible=0.15, still=0.3),
    # Every gaussian alive for the whole clip — the "baked" profile.
    Scenario("LongLived", gaussians=256, duration_sec=6.0, windows=1, long_lived=True, always_visible=1.0, still=0.5),
    # Sub-millisecond sigmas, where a birth-time error flips a gaussian on or off.
    Scenario("TinySigmas", gaussians=128, duration_sec=1.0, windows=1),
)

#: Most files in the world will have no audio, so most variants here have none. Audio is
#: the flagged case, not the default — see the specification's audio section.
DEFAULT_FLAGS: tuple[str, ...] = ("UseChunkIndex", "UseCrc")


def variants() -> list[tuple[Scenario, tuple[str, ...]]]:
    """Every legal (scenario, flags) pair, in a stable order.

    The matrix is deliberately not a full cross product: a full one is thousands of
    near-identical files that cost size and prove nothing extra. Each flag is exercised
    against the scenario that stresses it, plus a few combinations that have historically
    interacted.
    """
    out: list[tuple[Scenario, tuple[str, ...]]] = []

    def add(scenario: Scenario, *flags: str) -> None:
        chosen = tuple(f for f in flags if f not in scenario.excludes)
        if any(f not in FLAGS for f in chosen):
            raise ValueError(f"unknown flag in {chosen}")
        out.append((scenario, tuple(sorted(set(DEFAULT_FLAGS + chosen)))))

    for scenario in SCENARIOS:
        add(scenario)  # baseline: no audio, no SH, indexed
        add(scenario, "Quantized")

    # Structural flags, on the scenario with enough gaussians to make them meaningful.
    ten = SCENARIOS[3]
    add(ten, "UseChunks")
    add(ten, "UseChunks", "UseStatistics", "UseSummaryOffset")
    add(ten, "UseChunks", "DeltaStreams", "Quantized")
    add(ten, "AddExtraDataToRecords")  # unknown fields + a private-range record
    add(ten, "WithMetadata", "WithAttachment")
    add(ten, "WithCamera")

    # Spherical harmonics, including the band-skipping path.
    mixed = SCENARIOS[4]
    add(mixed, "SHDegree1")
    add(mixed, "SHDegree2")
    add(mixed, "SHDegree2", "Quantized", "UseChunks")

    # Audio: exactly one scenario carries a track, and one asserts clean absence.
    add(SCENARIOS[2], "WithAudio")
    add(SCENARIOS[2], "WithAudio", "WithCamera", "WithMetadata")
    add(SCENARIOS[2])  # the no-audio twin of the above, same scene

    # A track larger than the 64 KiB probe an indexed reader opens a file with. The Audio
    # record lives in the front matter, so this is the variant that catches a reader which
    # walks the front matter by materializing each record instead of stepping over it by
    # length. Every other fixture here is small enough that the distinction is invisible,
    # which is exactly why the bug it catches survived until a real scene with sound.
    add(SCENARIOS[2], "WithLargeAudio")

    # Streaming without an index: a writer piping to stdout cannot seek back.
    out.append((ten, ("UseCrc",)))

    return out


def variant_name(scenario: Scenario, flags: tuple[str, ...]) -> str:
    """Stable file stem, e.g. `TenWindows-UseChunkIndex-UseCrc-WithAudio`."""
    return "-".join((scenario.name, *flags)) if flags else scenario.name


# --------------------------------------------------------------------------
# Synthetic scene construction
# --------------------------------------------------------------------------


def build_gaussians(scenario: Scenario, seed: int = 20260728) -> dict:
    """Deterministic gaussians for a scenario, as plain Python lists.

    Deliberately dependency-free: see the note on `rnd` for why the PRNG is hand-written
    rather than borrowed.
    """
    state = seed & 0xFFFFFFFF

    def rnd() -> float:
        """xorshift32 in [0, 1).

        DO NOT replace this with a library PRNG. It is hand-written on purpose: the
        corpus must reproduce byte-for-byte across versions of every dependency, and a
        library generator's stream is only stable as far as that library promises.
        "The fixtures changed because numpy changed" is a debugging session nobody should
        ever have to sit through, and the `--verify` determinism gate would fail with a
        message pointing at the encoder rather than at the real culprit.
        """
        nonlocal state
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        return state / 0x100000000

    n = scenario.gaussians
    window_len = scenario.duration_sec / scenario.windows if scenario.windows else 0.0

    positions, scales, rotations, colors, motions = [], [], [], [], []
    mu_t, sigma_t, win_lo, win_hi = [], [], [], []

    for i in range(n):
        w = i % scenario.windows if scenario.windows else 0
        lo = w * window_len
        hi = lo + window_len

        positions.append([rnd() * 2 - 1, rnd() * 2 - 1, rnd() * 2 - 1])
        scales.append([math.exp(-7 + 2 * rnd()) for _ in range(3)])

        # Cover all four largest-component branches of the smallest-three coding.
        q = [rnd() * 0.3 - 0.15 for _ in range(4)]
        q[i % 4] = 1.0
        norm = math.sqrt(sum(c * c for c in q))
        rotations.append([c / norm for c in q])

        colors.append([rnd(), rnd(), rnd(), 0.05 + 0.95 * rnd()])

        if i / max(n, 1) < scenario.still:
            motions.append([0.0, 0.0, 0.0])
        else:
            motions.append([rnd() * 0.4 - 0.2, rnd() * 0.4 - 0.2, rnd() * 0.4 - 0.2])

        if scenario.long_lived:
            mu_t.append(lo + window_len * 0.5)
            sigma_t.append(float("inf"))
        elif i / max(n, 1) < scenario.always_visible:
            mu_t.append(lo + window_len * rnd())
            sigma_t.append(float("inf"))
        elif scenario.name == "TinySigmas":
            mu_t.append(lo + window_len * rnd())
            sigma_t.append(0.0005 + 0.002 * rnd())
        else:
            mu_t.append(lo + window_len * rnd())
            sigma_t.append(0.01 * math.exp(4 * rnd()))

        win_lo.append(lo)
        win_hi.append(hi)

    return {
        "positions": positions,
        "scales": scales,
        "rotations": rotations,
        "colors": colors,
        "motions": motions,
        "mu_t": mu_t,
        "sigma_t": sigma_t,
        "win_lo": win_lo,
        "win_hi": win_hi,
        "duration_sec": scenario.duration_sec,
    }


def build_audio(seconds: float = 0.25, rate: int = 8000) -> bytes:
    """A synthetic WAV — a sine sweep, generated, never sampled.

    Present so audio embedding and extraction are conformance-tested from day one without
    shipping anyone's recording. `seconds` is a deliberate knob: one variant asks for a
    track big enough to exceed a reader's head probe, because fixture scale is itself a
    thing the corpus has to cover.
    """
    frames = int(seconds * rate)
    samples = bytearray()
    for i in range(frames):
        f = 220.0 + (880.0 - 220.0) * (i / max(frames - 1, 1))
        value = int(12000 * math.sin(2 * math.pi * f * i / rate))
        samples += struct.pack("<h", value)

    data_len = len(samples)
    header = b"RIFF" + struct.pack("<I", 36 + data_len) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", data_len)
    return bytes(header + samples)
