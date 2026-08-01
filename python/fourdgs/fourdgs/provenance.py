# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""What the provenance records mean once they have been read.

`records.py` knows the bytes; this module knows the arithmetic and the rules that
span more than one record — that sensor names are unique, that a sensor posed
against a rig names a rig the file actually carries, and how a pose is recovered
between two trajectory samples.

The interpolation rules here are the specification's, executable. Section 5.15.4
states them in prose because a specification has to; a reference implementation
exists so that "shortest-arc slerp" and "clamped, never extrapolated" have exactly
one meaning rather than one per reader.

Nothing here is required to decode gaussians. A consumer that only wants geometry
never constructs a `Provenance`, and a file that carries none produces an empty one
— which is a value, not an error.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Protocol

from .exceptions import MalformedFile
from .records import (
    POSE_TO_RIG,
    POSE_TO_SCENE,
    TRAJECTORY_STEP,
    CoordinateFrame,
    GeodeticAnchor,
    RigTrajectory,
    SensorCalibration,
)


class PoseSampled(Protocol):
    """A record `pose_at` can sample: time-stamped rigid poses with an interpolation mode.

    Both `RigTrajectory` (a capture platform) and the object layer's `ObjectTrack` (a
    scene object) satisfy this structurally, which is the point — the clamp-and-slerp of
    `pose_at` is written once and both records share it, rather than each carrying its own
    interpolation that could drift from the other. `name` is what a refusal message uses.
    """

    name: str
    interpolation: int
    times: list[float]
    rotations: list[list[float]]
    translations: list[list[float]]

    @property
    def sample_count(self) -> int: ...


# Registry names, so a tool printing a file says "right-handed" rather than "1".
# An id this build does not know comes back as its number, which is the honest
# answer: an unrecognized registry value is not a malformed one (spec registry).
HANDEDNESS_NAMES = {0: "unspecified", 1: "right", 2: "left"}
AXIS_NAMES = {0: "+x", 1: "+y", 2: "+z", 3: "-x", 4: "-y", 5: "-z"}
LENGTH_UNIT_NAMES = {
    0: "unspecified",
    1: "metre",
    2: "centimetre",
    3: "millimetre",
    4: "kilometre",
    5: "foot",
    6: "inch",
}
LENGTH_UNIT_METRES = {1: 1.0, 2: 0.01, 3: 0.001, 4: 1000.0, 5: 0.3048, 6: 0.0254}
CAMERA_MODEL_NAMES = {0: "none", 1: "pinhole", 2: "brown-conrady", 3: "kannala-brandt"}
TRAJECTORY_INTERPOLATION_NAMES = {0: "linear", 1: "step"}


def name_of(table: dict[int, str], value: int) -> str:
    return table.get(value, str(value))


@dataclass
class Pose:
    """A rigid transform: rotate by a unit quaternion, then translate."""

    rotation: tuple[float, float, float, float]  # xyzw
    translation: tuple[float, float, float]

    def apply(self, point) -> tuple[float, float, float]:
        """`R(rotation) * point + translation`, the direction section 5.15.3 states."""
        x, y, z, w = self.rotation
        px, py, pz = (float(v) for v in point)
        # q * (0, p) * q^-1, expanded. Two cross products rather than a 3x3 build:
        # fewer operations and no matrix to get the storage order of wrong.
        tx = 2.0 * (y * pz - z * py)
        ty = 2.0 * (z * px - x * pz)
        tz = 2.0 * (x * py - y * px)
        rx = px + w * tx + (y * tz - z * ty)
        ry = py + w * ty + (z * tx - x * tz)
        rz = pz + w * tz + (x * ty - y * tx)
        return (rx + self.translation[0], ry + self.translation[1], rz + self.translation[2])

    def compose(self, inner: Pose) -> Pose:
        """`self ∘ inner`: apply `inner` first, then `self`.

        This is what turns a sensor posed against a rig into a sensor posed in the
        scene, once the rig's pose at the instant of interest is known.
        """
        return Pose(
            rotation=_quaternion_multiply(self.rotation, inner.rotation),
            translation=self.apply(inner.translation),
        )


def _quaternion_multiply(a, b) -> tuple[float, float, float, float]:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def _normalize(q) -> tuple[float, float, float, float]:
    # Scaled before squaring: a component near the top of the double range squares to
    # infinity, so the naive norm refuses a quaternion that has a perfectly good
    # direction and that every other reader renormalizes. Dividing by the largest
    # magnitude first makes the sum safe and leaves the direction untouched.
    scale = max(abs(float(v)) for v in q)
    if not math.isfinite(scale) or scale == 0.0:
        raise MalformedFile(f"a quaternion with scale {scale} has no direction")
    scaled = [float(v) / scale for v in q]
    norm = math.sqrt(sum(v * v for v in scaled))
    if not math.isfinite(norm) or norm == 0.0:
        raise MalformedFile(f"a quaternion with norm {norm} has no direction")
    return tuple(v / norm for v in scaled)  # type: ignore[return-value]


def slerp(a, b, u: float) -> tuple[float, float, float, float]:
    """Shortest-arc spherical interpolation between two unit quaternions.

    The sign flip is a correctness rule, not an optimization: `q` and `-q` are the
    same rotation, so without it a trajectory takes the long way round between two
    poses a degree apart — for one interval, once per sign flip, which is exactly
    the kind of defect that survives a demo and shows up in someone's analysis.
    """
    a = _normalize(a)
    b = _normalize(b)
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    if dot < 0.0:
        b = tuple(-v for v in b)  # type: ignore[assignment]
        dot = -dot
    if dot > 0.9995:
        # Near-parallel: the great-circle formula divides by a sine approaching zero,
        # and a straight lerp is within float noise of it here.
        return _normalize(tuple(x + u * (y - x) for x, y in zip(a, b, strict=True)))
    theta = math.acos(max(-1.0, min(1.0, dot)))
    sin_theta = math.sin(theta)
    wa = math.sin((1.0 - u) * theta) / sin_theta
    wb = math.sin(u * theta) / sin_theta
    return tuple(wa * x + wb * y for x, y in zip(a, b, strict=True))  # type: ignore[return-value]


def pose_at(trajectory: PoseSampled, t: float) -> Pose | None:
    """The pose at scene time `t`, or `None` when the record has no samples.

    Outside the sample range the pose is **clamped**, never extrapolated: before the
    first sample it is the first sample, at or after the last it is the last.
    Extrapolating produces a platform that accelerates away from the scene at the
    ends of the clip, which is never what the capture did.
    """
    n = trajectory.sample_count
    if n == 0:
        return None
    times = trajectory.times
    if t <= times[0]:
        return _sample(trajectory, 0)
    if t >= times[-1]:
        return _sample(trajectory, n - 1)

    # Times are strictly increasing (enforced at parse), so a bisection is exact.
    lo, hi = 0, n - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if times[mid] <= t:
            lo = mid
        else:
            hi = mid

    if trajectory.interpolation == TRAJECTORY_STEP:
        return _sample(trajectory, lo)
    if trajectory.interpolation not in TRAJECTORY_INTERPOLATION_NAMES:
        # Unknown-but-legal, not malformed — but there is no defensible way to invent
        # the rule, and picking linear would silently answer a question the file asked
        # differently. Naming it is the whole obligation.
        raise MalformedFile(
            f"trajectory {trajectory.name!r} uses interpolation {trajectory.interpolation}, "
            "which this build does not implement"
        )

    span = times[lo + 1] - times[lo]
    u = (t - times[lo]) / span
    a, b = _sample(trajectory, lo), _sample(trajectory, lo + 1)
    return Pose(
        rotation=slerp(a.rotation, b.rotation, u),
        translation=tuple(x + u * (y - x) for x, y in zip(a.translation, b.translation, strict=True)),  # type: ignore[arg-type]
    )


def _sample(trajectory: PoseSampled, i: int) -> Pose:
    return Pose(
        rotation=_normalize(trajectory.rotations[i]),
        translation=tuple(float(v) for v in trajectory.translations[i]),  # type: ignore[arg-type]
    )


@dataclass
class Provenance:
    """Every provenance record a file carried, and the rules that span them.

    An empty instance is what a scene with no provenance produces. That is a value
    and never an error: absence costs nothing and means nothing is claimed.
    """

    frames: list[CoordinateFrame] = field(default_factory=list)
    sensors: list[SensorCalibration] = field(default_factory=list)
    trajectories: list[RigTrajectory] = field(default_factory=list)
    anchors: list[GeodeticAnchor] = field(default_factory=list)

    def __bool__(self) -> bool:
        return bool(self.frames or self.sensors or self.trajectories or self.anchors)

    @property
    def frame(self) -> CoordinateFrame | None:
        """The file's own scene frame — the one named `""` — or `None`.

        Almost every file defines exactly one frame and never names it again, so this
        is the accessor that reads naturally at a call site. A file with several
        frames reaches for `frame_named`.
        """
        return self.frame_named("")

    def frame_named(self, name: str) -> CoordinateFrame | None:
        return next((f for f in self.frames if f.name == name), None)

    def sensor(self, name: str) -> SensorCalibration | None:
        return next((s for s in self.sensors if s.name == name), None)

    def trajectory(self, name: str = "") -> RigTrajectory | None:
        return next((t for t in self.trajectories if t.name == name), None)

    def anchor(self, frame_name: str = "") -> GeodeticAnchor | None:
        return next((a for a in self.anchors if a.frame_name == frame_name), None)

    def metres_per_unit(self, frame_name: str = "") -> float | None:
        """One unit of a frame in metres, or `None` when the file does not say.

        `metres_per_unit` is the authority where it and `length_unit` disagree (spec
        section 5.15.2): the number is what a consumer computes with, the enum is
        what it prints. A writer MUST make them agree and a validator reports a
        disagreement as an error, so this rule only ever runs on a file that is
        already non-conforming — it exists so that two consumers handed that file
        still produce one measurement rather than two.
        """
        frame = self.frame_named(frame_name)
        if frame is None:
            return None
        if frame.metres_per_unit > 0.0:
            return frame.metres_per_unit
        return LENGTH_UNIT_METRES.get(frame.length_unit)

    def sensor_pose_at(self, name: str, t: float) -> Pose | None:
        """A sensor's pose in the scene frame at scene time `t`.

        For a sensor posed against the scene this is its extrinsic and `t` is
        ignored. For one posed against a rig it is the rig's pose at `t` composed
        with the extrinsic, which is the whole reason `pose_reference` exists: the
        two cases have different answers and nothing in the numbers distinguishes
        them.
        """
        sensor = self.sensor(name)
        if sensor is None:
            return None
        extrinsic = Pose(
            rotation=_normalize(sensor.rotation),
            translation=tuple(float(v) for v in sensor.translation),  # type: ignore[arg-type]
        )
        if sensor.pose_reference != POSE_TO_RIG:
            return extrinsic
        trajectory = self.trajectory(sensor.rig_name)
        if trajectory is None:
            raise MalformedFile(
                f"sensor {sensor.name!r} is posed against rig {sensor.rig_name!r}, which this file does not carry"
            )
        rig = pose_at(trajectory, t)
        return extrinsic if rig is None else rig.compose(extrinsic)

    def check(self, *, truncated: bool = False) -> None:
        """The rules no single record can enforce on its own.

        `truncated` defers only the rules a later record could still satisfy: a sensor
        naming a rig, an anchor naming a frame. A duplicate name among records that are
        already complete is not one of them — no byte after the cut can make two
        `SensorCalibration` records with one name unambiguous — so those still refuse.

        Both are refusals rather than repairs, for the reason section 5.4 gives about
        window indices. A duplicate sensor name makes every reference to that name a
        coin toss performed silently; a rig reference into a file that carries no such
        rig, resolved by falling back to a scene-frame pose, would put every sensor on
        that rig at the origin — plausible, wrong, and quiet.
        """
        for label, names, section in (
            ("CoordinateFrame", [f.name for f in self.frames], "5.15.2"),
            ("SensorCalibration", [s.name for s in self.sensors], "5.15.3"),
            ("RigTrajectory", [t.name for t in self.trajectories], "5.15.4"),
            ("GeodeticAnchor", [a.frame_name for a in self.anchors], "5.15.5"),
        ):
            seen: set[str] = set()
            for name in names:
                if name in seen:
                    raise MalformedFile(
                        f"two {label} records are named {name!r}; these records are referred to "
                        f"by name and nothing else (section {section})"
                    )
                seen.add(name)

        # A zero-sample trajectory "MUST be read as though the record were absent"
        # (section 5.15.4), so a rig-relative sensor naming one names a rig this file
        # does not carry — the same refusal, reached one step later. Composing it as
        # identity instead would place every sensor on that rig at the rig origin:
        # plausible, wrong, and silent.
        # The registry defines two pose references and no more. An unrecognized value
        # is not a future extension a reader may ignore: it says the extrinsic maps into
        # some frame this build cannot name, and treating it as scene-relative puts the
        # sensor somewhere plausible and wrong.
        for sensor in self.sensors:
            if sensor.pose_reference not in (POSE_TO_SCENE, POSE_TO_RIG):
                raise MalformedFile(
                    f"sensor {sensor.name!r} declares pose_reference "
                    f"{sensor.pose_reference}; the registry defines 0 (scene) and 1 (rig)"
                )

        # Past here the rules resolve a reference into another record. A file cut before
        # that record arrived is missing the target rather than contradicting itself.
        if truncated:
            return

        rigs = {t.name for t in self.trajectories if t.sample_count > 0}
        for sensor in self.sensors:
            if sensor.pose_reference == POSE_TO_RIG and sensor.rig_name not in rigs:
                raise MalformedFile(
                    f"sensor {sensor.name!r} is posed against rig {sensor.rig_name!r}, "
                    f"which this file does not carry (section 5.15.3)"
                )

        frames = {f.name for f in self.frames}
        for anchor in self.anchors:
            if anchor.frame_name not in frames:
                raise MalformedFile(
                    f"a GeodeticAnchor anchors frame {anchor.frame_name!r}, which this file does "
                    f"not define; an anchor for a frame nobody declared is a latitude attached to "
                    f"nothing (section 5.15.5)"
                )


__all__ = [
    "AXIS_NAMES",
    "CAMERA_MODEL_NAMES",
    "HANDEDNESS_NAMES",
    "LENGTH_UNIT_METRES",
    "LENGTH_UNIT_NAMES",
    "TRAJECTORY_INTERPOLATION_NAMES",
    "Pose",
    "Provenance",
    "name_of",
    "pose_at",
    "slerp",
]
