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

**Nothing here may depend on decoded order.** Gaussians may be reordered freely by an
encoder and readers must not rely on their order, so a summary that did would be asking
two correct decoders to disagree. Everything per-gaussian — the sample, the aggregates,
the spherical harmonic digest — is taken in the content order defined by `_stable_order`,
which is derived from decoded values alone.

The summary covers what the file says, not only its gaussians. A record that changes
nothing here is a record an implementation could ignore entirely and still pass, which is
how a feature matrix ends up claiming things the suite never checked.

The same applies field by field, not only record by record. `profile` and `library` are
the Header's first two fields; every SDK could read them and none asserted them, so an
implementation returning an empty string for both was indistinguishable here from one that
decoded them properly. That is the worst shape a gap can take — not a failure, but a
success that proves less than it appears to.
"""

from __future__ import annotations

import json
import math
import zlib

FLOAT_DECIMALS = 6
#: How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
#: pass by getting a prefix right.
SAMPLE = 16
#: How many camera keyframes appear in full, so a long trajectory cannot bloat a summary.
CAMERA_KEYFRAMES = 4


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


def crc(data) -> str:
    """CRC-32 of a byte payload, as a string. Used where a summary needs to prove it read
    the bytes and not merely their length."""
    return str(zlib.crc32(bytes(data)) & 0xFFFFFFFF)


def canonical(scene_summary: dict) -> str:
    return json.dumps(scene_summary, sort_keys=True, indent=2, allow_nan=False)


def summarize(
    header,
    gaussians,
    audio,
    chunk_intervals,
    *,
    camera=None,
    metadata=(),
    attachments=(),
    statistics=None,
    summary_offsets=(),
    summary_crc_ok=None,
) -> dict:
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
    for i in order:
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
        "cutoff": num(header.cutoff),
        # The Header's first two fields. Readable in every SDK from the start and asserted
        # by none of them, which is a hiding place rather than an omission: a binding that
        # returned an empty string for both — because it never wired them through — read
        # successfully, produced a summary identical to a correct one, and passed. The C++
        # binding did exactly that once. A field that no expectation mentions is a field an
        # implementation can decline to decode.
        "profile": header.profile,
        "library": header.library,
        "shDegree": int(header.sh_degree),
        "temporalModel": header.temporal_model,
        "hasAudio": bool(header.has_audio),
        # Absent audio is a value, not a missing key: both paths are conformance-visible.
        "audio": None
        if audio is None
        else {"codec": audio.codec, "byteLength": str(len(audio.data)), "crc": crc(audio.data)},
        "chunkIntervals": [[num(a), num(b)] for a, b in chunk_intervals],
        "headerAttributes": {k: v for k, v in sorted(dict(header.attributes).items())},
        "metadataRecords": [
            {"name": m.name, "entries": {k: v for k, v in sorted(dict(m.entries).items())}} for m in metadata
        ],
        "attachments": [
            {
                "name": a.name,
                "mediaType": a.media_type,
                "byteLength": str(len(a.data)),
                "crc": crc(a.data),
            }
            for a in attachments
        ],
        "camera": None if camera is None else _camera(camera),
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
                "groupOpcode": str(s.group_opcode),
                "groupStart": str(s.group_start),
                "groupLength": str(s.group_length),
            }
            for s in summary_offsets
        ],
        "summaryCrcOk": summary_crc_ok,
        "sh": _spherical_harmonics(gaussians, order),
        "sample": {
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


def _camera(camera) -> dict:
    return {
        "fovYDeg": num(camera.fov_y_deg),
        "position": [num(v) for v in camera.position],
        "target": [num(v) for v in camera.target],
        "keyframeCount": str(len(camera.times)),
        "keyframes": [
            {
                "time": num(camera.times[i]),
                "position": [num(v) for v in camera.positions[i]],
                "target": [num(v) for v in camera.targets[i]],
            }
            for i in range(min(len(camera.times), CAMERA_KEYFRAMES))
        ],
        "interpolation": camera.interpolation,
        "loop": bool(camera.loop),
    }


def _spherical_harmonics(gaussians, order) -> dict | None:
    """Degree, width and a checksum of the coefficients in content order.

    A digest rather than the coefficients themselves: degree 2 over 512 gaussians is
    12,288 bytes, which would swamp the expectation without proving anything the checksum
    does not. Taken in content order so that two decoders which visit gaussians
    differently still agree.
    """
    sh = getattr(gaussians, "sh", None)
    if sh is None or gaussians.sh_degree == 0:
        return None
    coefficients = sh.shape[1] // 3
    payload = bytearray()
    for i in order:
        payload += bytes(bytearray(int(v) for v in sh[i]))
    return {
        "degree": int(gaussians.sh_degree),
        "coefficients": str(coefficients),
        "crc": crc(payload),
    }


def _stable_order(gaussians) -> list[int]:
    """Sort gaussians into an order both implementations can reproduce.

    Chunking and Morton ordering are encoder choices, so decoded order is not part of the
    contract — but a comparison needs *some* order. The key is the gaussian's whole
    decoded state, rounded exactly as the summary rounds it, with its spherical harmonic
    coefficients last. Two gaussians that tie on all of it are identical in every value
    this summary emits, so their relative order cannot change the output.
    """
    sh = getattr(gaussians, "sh", None)
    keys = []
    for i in range(gaussians.count):
        row = []
        for arr, width in (
            (gaussians.positions, 3),
            (gaussians.scales, 3),
            (gaussians.rotations, 4),
            (gaussians.colors, 4),
            (gaussians.motions, 3),
        ):
            row += [_sortable(arr[i][k]) for k in range(width)]
        row += [
            _sortable(gaussians.mu_t[i]),
            _sortable(gaussians.sigma_t[i]),
            _sortable(gaussians.win_lo[i]),
            _sortable(gaussians.win_hi[i]),
        ]
        if sh is not None:
            row += [int(v) for v in sh[i]]
        keys.append((row, i))
    keys.sort(key=lambda k: k[0])
    return [k[1] for k in keys]


def _sortable(value) -> float:
    """A comparison key: rounded like the summary, with infinity kept as infinity so the
    two languages order never-fading gaussians identically."""
    v = float(value)
    if math.isnan(v):
        return math.inf
    if math.isinf(v):
        return v
    return round(v, FLOAT_DECIMALS)
