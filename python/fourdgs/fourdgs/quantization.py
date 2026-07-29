# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Error-bounded quantization.

Every attribute lands on a uniform grid whose pitch is exactly twice its declared bound,
so `|decoded - original| <= bound` holds by construction rather than by testing. After
this point the pipeline is integer-only, which is what makes decoders in different
languages produce identical results.

Two attributes get a pitch that varies per gaussian, derived from a value the decoder has
already read, so there is no side channel. Both exist because a fixed pitch spends its
budget in the wrong place:

* **velocity** — an error only becomes visible as displacement over the span a gaussian
  is on screen, so a short-lived gaussian tolerates a much coarser velocity;
* **birth time** — the temporal term reads `(t - mu) / sigma`, never `mu` alone, so
  precision has to be a fraction of the gaussian's own sigma. A gaussian with a
  1 ms sigma and a 2 ms birth-time error is not slightly wrong, it is on when it should
  be off.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import numpy as np

from .exceptions import MalformedFile

PROFILES = ("fine", "default", "coarse")

#: The Header's default marginal visibility threshold.
DEFAULT_CUTOFF = 0.05

#: `marginal >= cutoff` <=> `|t - mu| <= K * sigma`, for the default cutoff.
K_SUPPORT = math.sqrt(-2.0 * math.log(DEFAULT_CUTOFF))


def support_k(cutoff: float = DEFAULT_CUTOFF) -> float:
    """Half-width of a gaussian's visible support, in sigmas, for a file's own cutoff.

    Reading this from the Header rather than assuming the default is not cosmetic: it feeds
    the velocity precision class, so a decoder that assumes 0.05 decodes different
    velocities than the encoder wrote for any file that declares something else, and
    nothing in the file tells it that it did.

    A threshold outside `(0, 1]` is not a threshold. It comes from a corrupt header, and
    it has to be refused here rather than become a domain error inside a logarithm.
    """
    if not (0.0 < cutoff <= 1.0) or math.isnan(cutoff):
        raise MalformedFile(f"the Header's cutoff is {cutoff}; a marginal threshold must be in (0, 1]")
    return math.sqrt(-2.0 * math.log(cutoff))


# Velocity precision classes (spec section 6.3).
LIFE_REF = 0.5
LIFE_MIN_CLASS = -4
LIFE_MAX_CLASS = 2
LIFE_HALF_MIN = 0.02
LIFE_HALF_MAX = 2.0

# Birth-time precision classes.
MU_REL = 0.05
MU_MIN_CLASS = -10


@dataclass
class Bounds:
    """The maximum deviation a decoder may observe, per attribute."""

    pos: float
    scale_rel: float
    rot: float
    rgb: float
    alpha: float
    motion: float
    time: float
    sigma_rel: float
    sh: int

    @staticmethod
    def for_profile(profile: str = "default", *, median_scale: float = 1e-3) -> Bounds:
        """Bounds derived from the scene's own geometry.

        Position tolerance is a fraction of the median gaussian radius rather than an
        absolute distance, so a profile means the same thing on a tabletop capture and on
        a city block.
        """
        if profile not in PROFILES:
            raise ValueError(f"profile must be one of {PROFILES}")
        k = {"fine": 0.02, "default": 0.05, "coarse": 0.20}[profile]
        pos = k * median_scale
        return Bounds(
            pos=pos,
            scale_rel={"fine": 0.005, "default": 0.02, "coarse": 0.06}[profile],
            rot={"fine": 0.0005, "default": 0.002, "coarse": 0.006}[profile],
            rgb={"fine": 0.5, "default": 1.0, "coarse": 3.0}[profile] / 255.0,
            alpha={"fine": 0.5, "default": 1.0, "coarse": 3.0}[profile] / 255.0,
            # The promise is on displacement, not velocity: this is the velocity bound
            # for a gaussian of the reference lifetime. See `life_class`.
            motion=pos / LIFE_REF,
            time={"fine": 0.0005, "default": 0.002, "coarse": 0.008}[profile],
            sigma_rel={"fine": 0.005, "default": 0.02, "coarse": 0.06}[profile],
            sh={"fine": 0, "default": 0, "coarse": 1}[profile],
        )

    def as_strings(self) -> dict[str, str]:
        return {k: repr(v) for k, v in asdict(self).items()}


@dataclass
class Steps:
    """Grid pitches: exactly twice the bound, in the appropriate domain."""

    pos: float
    scale_log: float
    rot: float
    rgb: float
    alpha: float
    motion: float
    time: float
    sigma_log: float
    sh: int

    @staticmethod
    def of(b: Bounds) -> Steps:
        return Steps(
            pos=2.0 * b.pos,
            scale_log=2.0 * math.log1p(b.scale_rel),
            rot=2.0 * b.rot,
            rgb=2.0 * b.rgb,
            alpha=2.0 * b.alpha,
            motion=2.0 * b.motion,
            time=2.0 * b.time,
            sigma_log=2.0 * math.log1p(b.sigma_rel),
            sh=max(1, 2 * b.sh + 1),
        )


def quantize(values, step: float, origin=0.0) -> np.ndarray:
    return np.rint((np.asarray(values, dtype=np.float64) - origin) / step).astype(np.int64)


def dequantize(bins, step: float, origin=0.0) -> np.ndarray:
    return np.asarray(bins, dtype=np.float64) * step + origin


# --------------------------------------------------------------------------
# Per-gaussian precision
# --------------------------------------------------------------------------


def life_class(sigma_bins, sigma_log_step: float, never_fades, window_len, k: float = K_SUPPORT) -> np.ndarray:
    """Velocity precision class, from the sigma bin a decoder has already read.

    `ceil`, not `round`: the class's nominal lifetime has to be an upper bound on the real
    one, or the displacement guarantee fails by up to sqrt(2). This is not hypothetical —
    the encoder's own verification caught exactly that on the first run.

    `k` comes from the file's own cutoff (spec section 6.3); it defaults to the default
    cutoff's value so a caller that has no header still gets the common case right.
    """
    sigma = np.exp(np.asarray(sigma_bins, dtype=np.float64) * sigma_log_step)
    half = np.where(never_fades, np.asarray(window_len, dtype=np.float64), k * sigma)
    half = np.clip(half, LIFE_HALF_MIN, LIFE_HALF_MAX)
    cls = np.ceil(np.log2(half / LIFE_REF))
    return np.clip(cls, LIFE_MIN_CLASS, LIFE_MAX_CLASS).astype(np.int64)


def motion_steps(classes, step_ref: float) -> np.ndarray:
    return step_ref * np.power(2.0, -np.asarray(classes, dtype=np.float64))


def mu_steps(sigma_bins, sigma_log_step: float, never_fades, step_ref: float) -> np.ndarray:
    """Birth-time pitch: `step_ref`, refined by powers of two until it is at most
    `MU_REL` of the gaussian's own sigma."""
    sigma = np.exp(np.asarray(sigma_bins, dtype=np.float64) * sigma_log_step)
    target = np.where(never_fades, step_ref, np.minimum(step_ref, MU_REL * sigma))
    cls = np.clip(np.floor(np.log2(target / step_ref)), MU_MIN_CLASS, 0)
    return step_ref * np.power(2.0, cls)


# --------------------------------------------------------------------------
# Rotation: smallest-three
# --------------------------------------------------------------------------

_REST = np.array([[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]], dtype=np.int64)


def quantize_rotation(quats, step: float) -> tuple[np.ndarray, np.ndarray]:
    """Returns `(largest index u8, residual bins (n, 3))`.

    The sign is canonicalized so the omitted component is positive — `q` and `-q` are the
    same rotation — which is what lets it be recovered as a square root.
    """
    q = np.asarray(quats, dtype=np.float64)
    q = q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-30)
    largest = np.argmax(np.abs(q), axis=1)
    sign = np.sign(q[np.arange(len(q)), largest])
    sign[sign == 0] = 1.0
    q = q * sign[:, None]
    rest = np.take_along_axis(q, _REST[largest], axis=1)
    return largest.astype(np.int64), quantize(rest, step)


def dequantize_rotation(largest, bins, step: float) -> np.ndarray:
    largest = np.asarray(largest, dtype=np.int64)
    if largest.size and (largest.min() < 0 or largest.max() > 3):
        raise MalformedFile(
            f"rotation index {largest.min() if largest.min() < 0 else largest.max()} is outside 0..3; "
            "it names which quaternion component was omitted"
        )
    rest = np.clip(dequantize(bins, step), -1.0, 1.0)
    out = np.zeros((len(largest), 4), dtype=np.float64)
    np.put_along_axis(out, _REST[largest], rest, axis=1)
    out[np.arange(len(largest)), largest] = np.sqrt(np.maximum(1.0 - np.sum(rest * rest, axis=1), 0.0))
    norm = np.linalg.norm(out, axis=1, keepdims=True)
    norm[norm == 0] = 1.0
    return out / norm


# --------------------------------------------------------------------------
# Reversible colour transform
# --------------------------------------------------------------------------


def rct_forward(rgb_bins: np.ndarray) -> np.ndarray:
    """Store `(g, r - g, b - g)`. Exact in the integer domain, so it changes the
    compressed size and never the error bound."""
    out = np.empty_like(rgb_bins)
    out[:, 0] = rgb_bins[:, 1]
    out[:, 1] = rgb_bins[:, 0] - rgb_bins[:, 1]
    out[:, 2] = rgb_bins[:, 2] - rgb_bins[:, 1]
    return out


def rct_inverse(bins: np.ndarray) -> np.ndarray:
    out = np.empty_like(bins)
    out[:, 1] = bins[:, 0]
    out[:, 0] = bins[:, 1] + bins[:, 0]
    out[:, 2] = bins[:, 2] + bins[:, 0]
    return out


def morton_order(positions: np.ndarray) -> np.ndarray:
    """Argsort by Morton code over the points' own bounding box.

    Spatial locality is what makes the position delta stream small; nothing else in the
    format depends on gaussian order.
    """
    p = np.asarray(positions, dtype=np.float64)
    if len(p) == 0:
        return np.zeros(0, dtype=np.int64)
    lo, hi = p.min(axis=0), p.max(axis=0)
    span = np.where(hi - lo <= 0, 1.0, hi - lo)
    g = np.rint(np.clip((p - lo) / span, 0.0, 1.0) * ((1 << 21) - 1)).astype(np.uint64)
    code = _part1by2(g[:, 0]) | (_part1by2(g[:, 1]) << np.uint64(1)) | (_part1by2(g[:, 2]) << np.uint64(2))
    return np.argsort(code, kind="stable")


def _part1by2(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.uint64) & np.uint64(0x1FFFFF)
    x = (x | (x << np.uint64(32))) & np.uint64(0x1F00000000FFFF)
    x = (x | (x << np.uint64(16))) & np.uint64(0x1F0000FF0000FF)
    x = (x | (x << np.uint64(8))) & np.uint64(0x100F00F00F00F00F)
    x = (x | (x << np.uint64(4))) & np.uint64(0x10C30C30C30C30C3)
    x = (x | (x << np.uint64(2))) & np.uint64(0x1249249249249249)
    return x
