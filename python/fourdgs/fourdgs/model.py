# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The in-memory scene: gaussians on one clock, plus what travels with them.

There are no frames here and none anywhere else in the library. Each gaussian carries its
own temporal description, so the number alive at any instant follows from the data rather
than from a frame count someone had to choose.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .quantization import DEFAULT_CUTOFF, support_k


@dataclass
class AudioTrack:
    """A legacy, non-spatial track.

    Kept as an input compatibility shim for version-1 files written before spatial audio
    was introduced. New code should use `AudioSource`; new writers encode the shim as one
    non-spatial Audio Source rather than emitting the legacy Audio record.
    """

    codec: str
    data: bytes
    start_sec: float = 0.0


@dataclass(frozen=True)
class AudioSourceKeyframe:
    """One source pose on the scene clock."""

    time: float
    position: tuple[float, float, float]
    rotation: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 1.0)


@dataclass(frozen=True)
class AudioSourceState:
    """The spatial facts a player needs for one source at scene time `t`.

    No panning, HRTF, distance attenuation, occlusion or mixing happens here. Those use
    this state together with the player-owned listener pose.
    """

    active: bool
    local_time: float
    position: tuple[float, float, float]
    rotation: tuple[float, float, float, float]
    gain: float


@dataclass
class AudioSource:
    """One independently timed audio payload and its scene-space pose.

    `spatial=False` is the explicit global/non-spatial case. Point sources are spatial
    and use a mono payload; a player's listener pose makes their direction change as the
    listener turns. The encoded payload stays verbatim and independently range-readable.
    """

    source_id: int
    codec: str
    data: bytes
    name: str = ""
    channel_layout: str = "mono"
    start_sec: float = 0.0
    duration_sec: float = 0.0
    gain: float = 1.0
    spatial: bool = True
    loop: bool = False
    position: tuple[float, float, float] = (0.0, 0.0, 0.0)
    rotation: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 1.0)
    keyframes: list[AudioSourceKeyframe] = field(default_factory=list)
    interpolation: str = "linear"
    #: Declared encoded payload size. Descriptors obtained from an indexed reader leave
    #: `data` empty and still expose this value.
    data_size: int | None = None

    def __post_init__(self) -> None:
        if self.data_size is None:
            self.data_size = len(self.data)

    def state_at(self, t: float) -> AudioSourceState:
        """Reconstruct source timing and pose at scene time `t`.

        Pose keyframes live on the scene clock. Audio sample time is local to this source:
        it starts at `start_sec` and wraps by `duration_sec` only when `loop` is set.
        """
        active = t >= self.start_sec and (self.loop or t - self.start_sec < self.duration_sec)
        local_time = (
            _looping_local_time(t, self.start_sec, self.duration_sec)
            if self.loop and self.duration_sec > 0.0
            else min(max(0.0, t - self.start_sec), max(self.duration_sec, 0.0))
        )
        position, rotation = _audio_pose_at(self, t)
        return AudioSourceState(
            active=active,
            local_time=local_time,
            position=position,
            rotation=rotation,
            gain=self.gain,
        )


def _looping_local_time(t: float, start_sec: float, duration_sec: float) -> float:
    if t <= start_sec:
        return 0.0
    time_remainder = math.fmod(t, duration_sec)
    if time_remainder < 0.0:
        time_remainder += duration_sec
    start_remainder = math.fmod(start_sec, duration_sec)
    if start_remainder < 0.0:
        start_remainder += duration_sec
    difference = time_remainder - start_remainder
    if difference < 0.0:
        difference += duration_sec
    return difference


def _audio_pose_at(
    source: AudioSource, t: float
) -> tuple[tuple[float, float, float], tuple[float, float, float, float]]:
    frames = source.keyframes
    if not frames:
        return source.position, _normalized_quaternion(source.rotation)
    if t <= frames[0].time:
        return frames[0].position, _normalized_quaternion(frames[0].rotation)
    if t >= frames[-1].time:
        return frames[-1].position, _normalized_quaternion(frames[-1].rotation)

    hi = next(i for i, frame in enumerate(frames) if frame.time > t)
    a, b = frames[hi - 1], frames[hi]
    if source.interpolation == "step":
        return a.position, _normalized_quaternion(a.rotation)
    u = _interpolation_fraction(t, a.time, b.time)
    position = tuple(float(_finite_lerp(x, y, u)) for x, y in zip(a.position, b.position, strict=True))
    return position, _slerp(a.rotation, b.rotation, u)


def _interpolation_fraction(t: float, a: float, b: float) -> float:
    span = b - a
    if math.isfinite(span):
        return (t - a) / span
    scale = max(abs(a), abs(b))
    return (t / scale - a / scale) / (b / scale - a / scale)


def _finite_lerp(a: float, b: float, u: float) -> float:
    if (a <= 0.0 <= b) or (b <= 0.0 <= a):
        return a * (1.0 - u) + b * u
    return a + (b - a) * u


def _normalized_quaternion(q) -> tuple[float, float, float, float]:
    # Normalize the scaled components directly. Reconstructing the original magnitude can
    # still overflow even when every component is finite: the norm of (1e308,) * 4 is 2e308.
    values = tuple(float(v) for v in q)
    scale = max(abs(v) for v in values)
    if not math.isfinite(scale) or scale == 0.0:
        return (0.0, 0.0, 0.0, 1.0)
    scaled = tuple(v / scale for v in values)
    length = math.sqrt(sum(v * v for v in scaled))
    return tuple(v / length for v in scaled)  # type: ignore[return-value]


def _slerp(a, b, u: float) -> tuple[float, float, float, float]:
    qa = _normalized_quaternion(a)
    qb = _normalized_quaternion(b)
    dot = sum(x * y for x, y in zip(qa, qb, strict=True))
    if dot < 0.0:
        qb = tuple(-v for v in qb)
        dot = -dot
    dot = min(1.0, max(-1.0, dot))
    if dot > 0.9995:
        return _normalized_quaternion(tuple(x + (y - x) * u for x, y in zip(qa, qb, strict=True)))
    theta = math.acos(dot)
    sin_theta = math.sin(theta)
    wa = math.sin((1.0 - u) * theta) / sin_theta
    wb = math.sin(u * theta) / sin_theta
    return _normalized_quaternion(tuple(wa * x + wb * y for x, y in zip(qa, qb, strict=True)))


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
    # Window Table endpoints are f64 on the wire (§5.4). Writers may accept f32
    # arrays, but readers retain the encoded precision so a large finite endpoint is
    # not silently reinterpreted as infinity.
    win_lo: np.ndarray  # (n,) f64 when decoded
    win_hi: np.ndarray  # (n,) f64 when decoded
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
        # Keep comparison in f64. Decoded Window Table endpoints already retain their
        # wire precision; the conversion also supports caller-constructed f32 sets.
        win_lo = np.asarray(self.win_lo, dtype=np.float64)
        win_hi = np.asarray(self.win_hi, dtype=np.float64)
        visible = (win_lo <= t) & (t < win_hi) & (marginal >= cutoff)
        idx = np.flatnonzero(visible)
        # A finite encoded scene may reconstruct a non-finite center at an extreme time;
        # canonical state represents that scalar as null. It is a result, not a warning.
        with np.errstate(over="ignore", invalid="ignore"):
            centers = (
                self.positions[idx].astype(np.float64) + self.motions[idx].astype(np.float64) * (t - mu[idx])[:, None]
            )
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
