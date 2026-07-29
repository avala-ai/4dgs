# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The in-memory scene: gaussians on one clock, plus what travels with them.

There are no frames here and none anywhere else in the library. Each gaussian carries its
own temporal description, so the number alive at any instant follows from the data rather
than from a frame count someone had to choose.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .quantization import DEFAULT_CUTOFF, support_k


@dataclass
class AudioTrack:
    """An embedded track. Absent scenes hold `None`, never an empty track."""

    codec: str
    data: bytes
    start_sec: float = 0.0


@dataclass
class CameraTrajectory:
    fov_y_deg: float = 50.0
    position: tuple[float, float, float] = (0.0, 0.0, 3.0)
    target: tuple[float, float, float] = (0.0, 0.0, 0.0)
    times: list[float] = field(default_factory=list)
    positions: list[tuple[float, float, float]] = field(default_factory=list)
    targets: list[tuple[float, float, float]] = field(default_factory=list)
    interpolation: str = "spline"
    loop: bool = True


@dataclass
class GaussianSet:
    """Every gaussian in a scene, structure-of-arrays.

    `sigma_t` may contain `inf`, meaning the gaussian never fades inside its window. That
    is a value, not a sentinel to be pattern-matched: it survives encode and decode as
    infinity, and readers expose it as such.
    """

    positions: np.ndarray  # (n, 3) f32
    scales: np.ndarray  # (n, 3) f32, linear
    rotations: np.ndarray  # (n, 4) f32, xyzw
    colors: np.ndarray  # (n, 4) f32, rgba
    motions: np.ndarray  # (n, 3) f32, units/second
    mu_t: np.ndarray  # (n,) f32
    sigma_t: np.ndarray  # (n,) f32, inf allowed
    win_lo: np.ndarray  # (n,) f32
    win_hi: np.ndarray  # (n,) f32
    sh: np.ndarray | None = None  # (n, coeffs*3) u8
    sh_degree: int = 0
    source_group: np.ndarray | None = None
    source_index: np.ndarray | None = None
    #: Per-gaussian object membership (spec section 6.6), or `None` when the file
    #: carries no `object_id` stream. Exact integers, `0` = background/unassigned; the
    #: object layer's tracks transform the gaussians of a given id (see `object_layer`).
    object_id: np.ndarray | None = None

    @property
    def count(self) -> int:
        return int(self.positions.shape[0])

    def support(self, cutoff: float = DEFAULT_CUTOFF) -> tuple[np.ndarray, np.ndarray]:
        """Per-gaussian visible interval, clipped to the validity window.

        This is what the chunker partitions on, and it is why content whose gaussians all
        live for the whole clip cannot be partitioned: every interval is the whole
        timeline, so every gaussian lands at the root.
        """
        sigma = self.sigma_t.astype(np.float64)
        mu = self.mu_t.astype(np.float64)
        half = np.where(np.isfinite(sigma), support_k(cutoff) * sigma, np.inf)
        lo = np.maximum(mu - half, self.win_lo.astype(np.float64))
        hi = np.minimum(mu + half, self.win_hi.astype(np.float64))
        return lo, hi

    def aabb(self) -> list[float]:
        if self.count == 0:
            return [0.0] * 6
        return [float(v) for v in self.positions.min(axis=0)] + [float(v) for v in self.positions.max(axis=0)]

    def state_at(self, t: float, cutoff: float = DEFAULT_CUTOFF) -> dict:
        """Reconstructed state at scene time `t`, exactly as the specification defines it.

        `cutoff` is the file's own threshold, from its Header. It defaults to the default
        so a caller holding only a `GaussianSet` still gets the common case right.

        Returned as index arrays plus attributes so a caller can do what it likes with
        them. This is where decoding ends: what happens to these numbers afterwards is
        not this library's concern.
        """
        mu = self.mu_t.astype(np.float64)
        sigma = self.sigma_t.astype(np.float64)
        marginal = np.where(
            np.isfinite(sigma),
            np.exp(-0.5 * np.square((t - mu) / np.maximum(sigma, 1e-30))),
            1.0,
        )
        visible = (self.win_lo <= t) & (t < self.win_hi) & (marginal >= cutoff)
        idx = np.flatnonzero(visible)
        centers = self.positions[idx].astype(np.float64) + self.motions[idx].astype(np.float64) * (t - mu[idx])[:, None]
        return {
            "indices": idx,
            "centers": centers,
            "orientations": self.rotations[idx].astype(np.float64),
            "opacity": self.colors[idx, 3].astype(np.float64) * marginal[idx],
            "object_id": (
                np.zeros(idx.size, dtype=np.uint32)
                if self.object_id is None
                else np.asarray(self.object_id, dtype=np.uint32).reshape(-1)[idx]
            ),
        }


def window_table(win_lo: np.ndarray, win_hi: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Distinct validity windows and a per-gaussian index into them.

    Windows repeat heavily — one per span the scene was fitted over — so the per-gaussian
    cost is an index rather than two floats.
    """
    pairs = np.stack([win_lo, win_hi], axis=1).astype(np.float64)
    table, index = np.unique(pairs, axis=0, return_inverse=True)
    return table, index.astype(np.int64)
