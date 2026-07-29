# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The object layer: what the Object Table and the SE(3) tracks mean once read.

`records.py` knows the bytes; this module knows the composition and the one rule that
spans more than one record — that at most one track moves any object.

The layer changes a reconstructed instant in exactly one way, and it is the load-bearing
rule of the whole design (spec section 5.15.6):

    A track transforms the base state; it does not replace it.

For a gaussian belonging to object `k`, with the base center `c0` and base orientation
`r0` that the temporal model produced (section 3, or keyframe-delta composition), and the
track's pose `(R, T)` at `t`:

    center(t)      = R * c0 + T          -- the pose applied to the base center
    orientation(t) = R (x) r0            -- the pose's rotation composed onto the base

The pose is relative to the object's stored (rest) configuration, so ignoring the whole
layer leaves every object at rest — a valid scene — rather than a pile at the origin. The
transform is rigid: it moves centre and orientation and touches neither scale, colour, nor
the temporal fields, so section 3's visibility and opacity run unchanged on the base.

A gaussian that carries per-gaussian motion AND belongs to a moving track is neither
forbidden nor track-wins: its motion moves it inside the object's frame (folded into `c0`),
and the track then transports the object. The two COMPOSE, base first.

Nothing here is required to decode gaussians. A file with no object layer produces an empty
`ObjectLayer`, which is a value and never an error.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .exceptions import MalformedFile
from .provenance import Pose, pose_at
from .records import ObjectTable, ObjectTrack

#: Background / unassigned. A gaussian carrying this id belongs to no object and is never
#: transformed; a track may not name it (refused at parse, `track-names-background`).
BACKGROUND = 0


@dataclass
class ObjectLayer:
    """Every object-layer record a file carried, and the rule that spans the tracks.

    `table` is the file's one Object Table, or `None`. `tracks` is the SE(3) tracks, at
    most one per object. An empty instance is what a scene with no objects produces.
    """

    table: ObjectTable | None = None
    tracks: list[ObjectTrack] = field(default_factory=list)

    def __bool__(self) -> bool:
        return self.table is not None or bool(self.tracks)

    def track(self, object_id: int) -> ObjectTrack | None:
        return next((t for t in self.tracks if t.object_id == object_id), None)

    def check(self) -> None:
        """At most one track per object.

        Two tracks for one object would move its gaussians by two poses, which is the
        duplicate-name failure section 5.15.2 refuses for frames and sensors. Each track's
        own rules (not the background, increasing times, real rotations) are enforced at
        parse; this is the one rule no single record can see.
        """
        seen: set[int] = set()
        for t in self.tracks:
            if t.object_id in seen:
                raise MalformedFile(
                    f"two ObjectTrack records move object {t.object_id}; a gaussian has one object "
                    f"and cannot be transported by two poses (section 5.15.6)",
                    code="duplicate-object-track",
                )
            seen.add(t.object_id)

    def pose_at(self, object_id: int, t: float) -> Pose | None:
        """The rigid pose that transforms object `object_id` at scene time `t`.

        `None` when the object has no track — background, or an untracked object — in
        which case its gaussians keep their base state unchanged. A track reuses the
        trajectory clamp-and-slerp of `provenance.pose_at`, so a query outside the sample
        range returns the nearest end sample rather than extrapolating.
        """
        if object_id == BACKGROUND:
            return None
        track = self.track(object_id)
        if track is None or track.sample_count == 0:
            return None
        return pose_at(track, t)

    def apply(
        self,
        *,
        centers: np.ndarray,
        orientations: np.ndarray,
        object_ids: np.ndarray,
        t: float,
    ) -> tuple[np.ndarray, np.ndarray]:
        """Compose the tracks onto a decoded instant: `center = R*c0 + T`, `orient = R (x) r0`.

        `centers` is (n, 3), `orientations` is (n, 4) xyzw, `object_ids` is (n,). Returns
        the transformed centres and orientations. Gaussians whose object has no track pass
        through unchanged, which is the identity case, so a file with no tracks is a no-op.
        The transform is applied once, after the base state is fully reconstructed.
        """
        centers = np.asarray(centers, dtype=np.float64).reshape(-1, 3)
        orientations = np.asarray(orientations, dtype=np.float64).reshape(-1, 4)
        object_ids = np.asarray(object_ids).reshape(-1)
        out_centers = centers.copy()
        out_orientations = orientations.copy()

        # Group rows once. Building a fresh full-scene mask for every tracked object makes
        # composition O(gaussians * tracks); a stable sort visits every row in one group and
        # keeps all of the per-group arithmetic in typed arrays.
        tracks: dict[int, ObjectTrack] = {}
        for track in self.tracks:
            if track.object_id != BACKGROUND and track.sample_count > 0:
                tracks.setdefault(track.object_id, track)
        if not tracks or object_ids.size == 0:
            return out_centers, out_orientations
        order = np.argsort(object_ids, kind="stable")
        sorted_ids = object_ids[order]
        starts = np.flatnonzero(np.r_[True, sorted_ids[1:] != sorted_ids[:-1]])
        ends = np.r_[starts[1:], sorted_ids.size]
        for start, end in zip(starts, ends, strict=True):
            track = tracks.get(int(sorted_ids[start]))
            if track is None:
                continue
            pose = pose_at(track, t)
            rows = order[start:end]
            matrix = _rotation_matrix(pose.rotation)
            out_centers[rows] = centers[rows] @ matrix.T + np.asarray(pose.translation, dtype=np.float64)
            out_orientations[rows] = _quaternion_left_multiply(pose.rotation, orientations[rows])

        return out_centers, out_orientations


def _rotation_matrix(q) -> np.ndarray:
    """The 3x3 rotation of a unit quaternion in xyzw order.

    Applying this to many points is one matmul, which is why the layer builds it once per
    object rather than sandwiching each point through the quaternion.
    """
    x, y, z, w = (float(v) for v in q)
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )


def _quaternion_left_multiply(q, rs: np.ndarray) -> np.ndarray:
    """`q (x) r` for each row `r` of `rs`, all quaternions in xyzw order.

    This is the pose's rotation composed onto each gaussian's base orientation. Left
    multiplication, because the track rotates the object's whole frame and the gaussian's
    own orientation is expressed within it.
    """
    ax, ay, az, aw = (float(v) for v in q)
    bx, by, bz, bw = rs[:, 0], rs[:, 1], rs[:, 2], rs[:, 3]
    return np.stack(
        [
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ],
        axis=1,
    )


__all__ = ["BACKGROUND", "ObjectLayer"]
