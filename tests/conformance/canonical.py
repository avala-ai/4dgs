# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The canonical JSON two implementations are diffed on.

Representation is pinned so that a disagreement is always about the format and never
about how a language spells a number:

* integers are strings, so a 64-bit value survives a JSON parser backed by doubles;
* floats are rounded to a fixed number of decimals before comparison;
* a never-fading gaussian's sigma is `null`, never a sentinel a decoder could produce by
  accident;
* `audio` is `null` when absent and an object when present, so both paths are visible in
  every implementation's output rather than one of them being invisible;
* keys are sorted.
"""

from __future__ import annotations

import json
import math

FLOAT_DECIMALS = 6
#: How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
#: pass by getting a prefix right.
SAMPLE = 16


def num(value) -> float | None:
    """Round for comparison; a non-finite value becomes `null`.

    The `float()` first is load-bearing: a numpy scalar is not a Python float, so an
    `isinstance` check would let infinity through into JSON, which has no way to spell it.
    """
    if value is None:
        return None
    v = float(value)
    if not math.isfinite(v):
        return None
    return round(v, FLOAT_DECIMALS)


def canonical(scene_summary: dict) -> str:
    return json.dumps(scene_summary, sort_keys=True, indent=2, allow_nan=False)


def summarize(header, gaussians, audio, chunk_intervals) -> dict:
    """The statement every implementation must agree on for a variant."""
    n = gaussians.count
    order = _stable_order(gaussians)
    sample = order[:SAMPLE]

    def rows(arr, width):
        return [[num(v) for v in arr[i][:width]] for i in sample]

    total_pos = [0.0, 0.0, 0.0]
    alpha_sum = 0.0
    never_fades = 0
    still = 0
    for i in range(n):
        for k in range(3):
            total_pos[k] += float(gaussians.positions[i][k])
        alpha_sum += float(gaussians.colors[i][3])
        if not math.isfinite(float(gaussians.sigma_t[i])):
            never_fades += 1
        if (
            abs(float(gaussians.motions[i][0]))
            + abs(float(gaussians.motions[i][1]))
            + abs(float(gaussians.motions[i][2]))
            == 0.0
        ):
            still += 1

    return {
        "gaussianCount": str(n),
        "durationSec": num(header.duration_sec),
        "shDegree": int(header.sh_degree),
        "temporalModel": header.temporal_model,
        "hasAudio": bool(header.has_audio),
        # Absent audio is a value, not a missing key: both paths are conformance-visible.
        "audio": None if audio is None else {"codec": audio.codec, "byteLength": str(len(audio.data))},
        "chunkIntervals": [[num(a), num(b)] for a, b in chunk_intervals],
        "sample": {
            "indices": [str(i) for i in sample],
            "positions": rows(gaussians.positions, 3),
            "scales": rows(gaussians.scales, 3),
            "rotations": rows(gaussians.rotations, 4),
            "colors": rows(gaussians.colors, 4),
            "motions": rows(gaussians.motions, 3),
            "muT": [num(gaussians.mu_t[i]) for i in sample],
            "sigmaT": [num(gaussians.sigma_t[i]) for i in sample],
            "winLo": [num(gaussians.win_lo[i]) for i in sample],
            "winHi": [num(gaussians.win_hi[i]) for i in sample],
        },
        "aggregate": {
            "positionSum": [num(v) for v in total_pos],
            "opacitySum": num(alpha_sum),
            "neverFadesCount": str(never_fades),
            "zeroMotionCount": str(still),
        },
    }


def _stable_order(gaussians) -> list[int]:
    """Sort gaussians into an order both implementations can reproduce.

    Chunking and Morton ordering are encoder choices, so decoded order is not part of the
    contract — but a comparison needs *some* order. Sorting on decoded values gives one
    without making the encoder's choices normative.
    """
    keys = []
    for i in range(gaussians.count):
        p = gaussians.positions[i]
        keys.append((round(float(p[0]), 6), round(float(p[1]), 6), round(float(p[2]), 6), i))
    keys.sort()
    return [k[3] for k in keys]
