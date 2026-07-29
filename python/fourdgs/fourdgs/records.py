# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Record bodies: one dataclass per record type, each able to write and read itself.

Every `parse` here reads the fields it knows and stops. It never asserts that the record
ended where its knowledge did, because a newer writer may have appended fields — that is
the compatibility rule, and honouring it is one line per record rather than a policy
nobody remembers.
"""

from __future__ import annotations

import math
import operator
from dataclasses import dataclass, field

from . import opcode as op
from .exceptions import MalformedFile
from .serialization import (
    Cursor,
    put_blob,
    put_f32s,
    put_f64,
    put_f64s,
    put_record,
    put_str_map,
    put_string,
    put_u8,
    put_u16,
    put_u32,
    put_u64,
)

FLAG_HAS_AUDIO = 1 << 0
FLAG_CHUNKS_COMPRESSED = 1 << 1
_F32_MAX = float.fromhex("0x1.fffffep+127")


@dataclass
class Header:
    duration_sec: float
    gaussian_count: int
    aabb: list[float]
    profile: str = ""
    library: str = ""
    cutoff: float = 0.05
    temporal_model: str = "gaussian-birth"
    sh_degree: int = 0
    flags: int = 0
    attributes: dict[str, str] = field(default_factory=dict)

    @property
    def has_audio(self) -> bool:
        """Answered from the header alone — no probing, no speculative range request.

        This is the whole audio-discovery rule, and it is why a scene without a
        soundtrack costs nothing: the bit is clear and there is no record.
        """
        return bool(self.flags & FLAG_HAS_AUDIO)

    def encode(self, trailer: bytes = b"") -> bytes:
        body = (
            put_string(self.profile)
            + put_string(self.library)
            + put_f64(self.duration_sec)
            + put_u64(self.gaussian_count)
            + put_f64(self.cutoff)
            + put_string(self.temporal_model)
            + put_f64s(self.aabb)
            + put_u8(self.sh_degree)
            + put_u8(self.flags)
            + put_str_map(self.attributes)
        )
        # A newer writer may append fields; a reader uses content_length and steps over
        # what it does not know. `trailer` is how a test writes that newer file.
        return put_record(op.HEADER, body + trailer)

    @staticmethod
    def parse(content) -> Header:
        c = Cursor(content)
        return Header(
            profile=c.string(),
            library=c.string(),
            duration_sec=c.f64(),
            gaussian_count=c.u64(),
            cutoff=c.f64(),
            temporal_model=c.string(),
            aabb=c.f64s(6),
            sh_degree=c.u8(),
            flags=c.u8(),
            attributes=c.str_map(),
        )


@dataclass
class Footer:
    summary_start: int = 0
    summary_offset_start: int = 0
    summary_crc: int = 0

    def encode(self) -> bytes:
        return put_record(
            op.FOOTER,
            put_u64(self.summary_start) + put_u64(self.summary_offset_start) + put_u32(self.summary_crc),
        )

    @staticmethod
    def parse(content) -> Footer:
        c = Cursor(content)
        return Footer(summary_start=c.u64(), summary_offset_start=c.u64(), summary_crc=c.u32())


@dataclass
class Quantization:
    scheme: str
    pos_origin: list[float]
    step_pos: float
    step_scale_log: float
    step_rot: float
    step_rgb: float
    step_alpha: float
    step_motion: float
    step_time: float
    step_sigma_log: float
    step_sh: int
    bounds: dict[str, str] = field(default_factory=dict)
    #: Per-band spherical harmonic bit depths, band 1 first. Appended after the record's
    #: original fields, so a file that declares none is byte-identical to one written
    #: before the field existed — an empty list is written as no bytes at all, not as a
    #: zero count.
    sh_bit_depths: list[int] = field(default_factory=list)

    def encode(self, trailer: bytes = b"") -> bytes:
        if "object_id" in self.bounds:
            raise MalformedFile(
                f"Quantization.bounds contains object_id={self.bounds['object_id']!r}; "
                "object_id is an exact label and MUST NOT carry a bound",
                code="invalid-object-id-bound",
            )
        body = (
            put_string(self.scheme)
            + put_f64s(self.pos_origin)
            + put_f64s(
                [
                    self.step_pos,
                    self.step_scale_log,
                    self.step_rot,
                    self.step_rgb,
                    self.step_alpha,
                    self.step_motion,
                    self.step_time,
                    self.step_sigma_log,
                ]
            )
            + put_u8(self.step_sh)
            + put_str_map(self.bounds)
        )
        if self.sh_bit_depths:
            body += put_u8(len(self.sh_bit_depths)) + bytes(bytearray(self.sh_bit_depths))
        return put_record(op.QUANTIZATION, body + trailer)

    @staticmethod
    def parse(content) -> Quantization:
        c = Cursor(content)
        scheme = c.string()
        origin = c.f64s(3)
        steps = c.f64s(8)
        step_sh = c.u8()
        bounds = c.str_map()
        if "object_id" in bounds:
            raise MalformedFile(
                f"Quantization.bounds contains object_id={bounds['object_id']!r}; "
                "object_id is an exact label and MUST NOT carry a bound",
                code="invalid-object-id-bound",
            )
        return Quantization(
            scheme=scheme,
            pos_origin=origin,
            step_pos=steps[0],
            step_scale_log=steps[1],
            step_rot=steps[2],
            step_rgb=steps[3],
            step_alpha=steps[4],
            step_motion=steps[5],
            step_time=steps[6],
            step_sigma_log=steps[7],
            step_sh=step_sh,
            bounds=bounds,
            sh_bit_depths=_sh_bit_depths(c),
        )


def _sh_bit_depths(c: Cursor) -> list[int]:
    """Read the appended per-band SH bit depths, or nothing.

    Deliberately tolerant. Appended fields are positional, so anything sitting after the
    bounds map lands where this field is — including bytes a *different* newer writer
    appended, or the arbitrary trailer a forward-compatibility fixture puts there. The
    declaration describes encoding that already happened and no decoded value depends on
    it, so a count the record is too short for, or a depth outside the legal range, is
    read as "this file declares none" rather than as a corrupt file (spec §5.3).
    """
    if c.remaining() < 1:
        return []
    at = c.pos
    count = c.u8()
    if count == 0 or c.remaining() < count:
        c.pos = at
        return []
    depths = [c.u8() for _ in range(count)]
    if any(not (3 <= d <= 8) for d in depths):
        c.pos = at
        return []
    return depths


@dataclass
class WindowTable:
    windows: list[tuple[float, float]]

    def encode(self) -> bytes:
        body = put_u32(len(self.windows))
        for lo, hi in self.windows:
            body += put_f64(lo) + put_f64(hi)
        return put_record(op.WINDOW_TABLE, body)

    @staticmethod
    def parse(content) -> WindowTable:
        c = Cursor(content)
        return WindowTable(windows=[(c.f64(), c.f64()) for _ in range(c.u32())])


@dataclass
class ChunkHeader:
    """A chunk's own fields; the streams follow inside its `records` blob."""

    t0: float
    t1: float
    level: int
    count: int
    compression: str
    uncompressed_size: int


def encode_chunk(t0: float, t1: float, level: int, count: int, records: bytes) -> bytes:
    body = (
        put_f64(t0)
        + put_f64(t1)
        + put_u32(level)
        + put_u32(count)
        + put_string("")  # chunk-level compression: streams carry their own
        + put_u64(len(records))
        + put_blob(records)
    )
    return put_record(op.CHUNK, body)


def parse_chunk(content) -> tuple[ChunkHeader, memoryview]:
    c = Cursor(content)
    head = ChunkHeader(
        t0=c.f64(),
        t1=c.f64(),
        level=c.u32(),
        count=c.u32(),
        compression=c.string(),
        uncompressed_size=c.u64(),
    )
    return head, c.take(c.u64())


@dataclass
class DeltaChunkHeader:
    """A delta chunk's own fields; its three groups follow inside `records`."""

    t0: float
    t1: float
    level: int
    delta_mode: int
    reference_offset: int
    keyframe_offset: int
    depth: int
    update_count: int
    birth_count: int
    death_count: int
    compression: str
    uncompressed_size: int


#: `delta_mode` values. Per chunk, not per file: an encoder that knows an instant is a
#: likely seek target can make it cost two records regardless of how deep into the group
#: it falls, without spending a whole keyframe on it.
DELTA_MODE_KEYFRAME = 0
DELTA_MODE_CHAINED = 1


def encode_delta_chunk(
    t0: float,
    t1: float,
    level: int,
    delta_mode: int,
    reference_offset: int,
    keyframe_offset: int,
    depth: int,
    updates: bytes,
    births: bytes,
    deaths: bytes,
    counts: tuple[int, int, int],
) -> bytes:
    """A Delta Chunk record.

    The three groups are framed by length inside one `records` blob rather than tagged
    with a group byte on every stream. That spends no second opcode, leaves the Attribute
    Stream record untouched, and lets a reader take the death list — which is small and
    which a consumer often wants alone — by stepping over two lengths.
    """
    update_count, birth_count, death_count = counts
    records = put_blob(updates) + put_blob(births) + put_blob(deaths)
    body = (
        put_f64(t0)
        + put_f64(t1)
        + put_u32(level)
        + put_u8(delta_mode)
        + put_u64(reference_offset)
        + put_u64(keyframe_offset)
        + put_u16(depth)
        + put_u32(update_count)
        + put_u32(birth_count)
        + put_u32(death_count)
        + put_string("")  # chunk-level compression: streams carry their own
        + put_u64(len(records))
        + put_blob(records)
    )
    return put_record(op.DELTA_CHUNK, body)


def parse_delta_chunk(content) -> tuple[DeltaChunkHeader, memoryview, memoryview, memoryview]:
    c = Cursor(content)
    head = DeltaChunkHeader(
        t0=c.f64(),
        t1=c.f64(),
        level=c.u32(),
        delta_mode=c.u8(),
        reference_offset=c.u64(),
        keyframe_offset=c.u64(),
        depth=c.u16(),
        update_count=c.u32(),
        birth_count=c.u32(),
        death_count=c.u32(),
        compression=c.string(),
        uncompressed_size=c.u64(),
    )
    records = Cursor(c.take(c.u64()))
    return head, records.take(records.u64()), records.take(records.u64()), records.take(records.u64())


#: Bytes the `keyframe-delta` block appends to a Chunk Index entry. A reader takes the
#: record's length from its header, so an entry with at least this many bytes left after
#: the band array carries the block and one without simply does not — which is how a
#: `gaussian-birth` file written before this revision still parses, unchanged, to the same
#: values.
_INDEX_DELTA_BLOCK = 1 + 1 + 8 + 8 + 2 + 8


@dataclass
class ChunkIndexEntry:
    t0: float
    t1: float
    chunk_offset: int
    chunk_length: int
    gaussian_count: int
    bands: list[tuple[int, int, int]] = field(default_factory=list)  # (band, offset, length)
    #: True when this entry carries the `keyframe-delta` block below. False for every
    #: `gaussian-birth` file, whose entries must stay byte-identical.
    extended: bool = False
    #: 0 keyframe (a Chunk record), 1 delta (a Delta Chunk record).
    kind: int = 0
    delta_mode: int = 0
    #: The chunk this delta applies to. Strictly less than `chunk_offset`: references
    #: point backwards only, so the chain walk terminates, cycles are unrepresentable, and
    #: any complete prefix of a truncated file is a complete set of chains.
    reference_offset: int = 0
    #: The keyframe at the head of this group. Equals `chunk_offset` for a keyframe.
    keyframe_offset: int = 0
    #: Delta chunks that must be composed to reach this one. The exact read cost, known
    #: from the index before anything is fetched.
    depth: int = 0
    #: Gaussians live over [t0, t1) after composition. `gaussian_count` cannot answer
    #: this for a delta entry — there it is the size of the delta, not of the population.
    live_count: int = 0

    def covers(self, t: float) -> bool:
        return self.t0 <= t < self.t1

    def encode(self) -> bytes:
        body = (
            put_f64(self.t0)
            + put_f64(self.t1)
            + put_u64(self.chunk_offset)
            + put_u64(self.chunk_length)
            + put_u32(self.gaussian_count)
            + put_u32(len(self.bands))
        )
        for band, offset, length in self.bands:
            body += put_u8(band) + put_u64(offset) + put_u64(length)
        if self.extended:
            body += (
                put_u8(self.kind)
                + put_u8(self.delta_mode)
                + put_u64(self.reference_offset)
                + put_u64(self.keyframe_offset)
                + put_u16(self.depth)
                + put_u64(self.live_count)
            )
        return put_record(op.CHUNK_INDEX, body)

    @staticmethod
    def parse(content) -> ChunkIndexEntry:
        c = Cursor(content)
        entry = ChunkIndexEntry(
            t0=c.f64(),
            t1=c.f64(),
            chunk_offset=c.u64(),
            chunk_length=c.u64(),
            gaussian_count=c.u32(),
        )
        entry.bands = [(c.u8(), c.u64(), c.u64()) for _ in range(c.u32())]
        if c.remaining() >= _INDEX_DELTA_BLOCK:
            entry.extended = True
            entry.kind = c.u8()
            entry.delta_mode = c.u8()
            entry.reference_offset = c.u64()
            entry.keyframe_offset = c.u64()
            entry.depth = c.u16()
            entry.live_count = c.u64()
        return entry


@dataclass
class Audio:
    codec: str
    data: bytes
    start_sec: float = 0.0

    def encode(self) -> bytes:
        return put_record(op.AUDIO, put_string(self.codec) + put_f64(self.start_sec) + put_blob(self.data))

    @staticmethod
    def parse(content) -> Audio:
        c = Cursor(content)
        return Audio(codec=c.string(), start_sec=c.f64(), data=c.blob())


@dataclass
class Camera:
    fov_y_deg: float
    position: list[float]
    target: list[float]
    times: list[float] = field(default_factory=list)
    positions: list[list[float]] = field(default_factory=list)
    targets: list[list[float]] = field(default_factory=list)
    interpolation: str = "spline"
    loop: bool = True

    def encode(self) -> bytes:
        body = put_f64(self.fov_y_deg) + put_f64s(self.position) + put_f64s(self.target) + put_u32(len(self.times))
        for i, t in enumerate(self.times):
            body += put_f64(t) + put_f64s(self.positions[i]) + put_f64s(self.targets[i])
        body += put_string(self.interpolation) + put_u8(1 if self.loop else 0)
        return put_record(op.CAMERA, body)

    @staticmethod
    def parse(content) -> Camera:
        c = Cursor(content)
        cam = Camera(fov_y_deg=c.f64(), position=c.f64s(3), target=c.f64s(3))
        for _ in range(c.u32()):
            cam.times.append(c.f64())
            cam.positions.append(c.f64s(3))
            cam.targets.append(c.f64s(3))
        cam.interpolation = c.string()
        cam.loop = bool(c.u8())
        return cam


@dataclass
class Metadata:
    name: str
    entries: dict[str, str] = field(default_factory=dict)

    def encode(self) -> bytes:
        return put_record(op.METADATA, put_string(self.name) + put_str_map(self.entries))

    @staticmethod
    def parse(content) -> Metadata:
        c = Cursor(content)
        return Metadata(name=c.string(), entries=c.str_map())


@dataclass
class Statistics:
    gaussian_count: int
    chunk_count: int
    duration_sec: float
    aabb: list[float]

    def encode(self) -> bytes:
        return put_record(
            op.STATISTICS,
            put_u64(self.gaussian_count) + put_u32(self.chunk_count) + put_f64(self.duration_sec) + put_f64s(self.aabb),
        )

    @staticmethod
    def parse(content) -> Statistics:
        c = Cursor(content)
        return Statistics(gaussian_count=c.u64(), chunk_count=c.u32(), duration_sec=c.f64(), aabb=c.f64s(6))


@dataclass
class Attachment:
    name: str
    media_type: str
    data: bytes

    def encode(self) -> bytes:
        return put_record(op.ATTACHMENT, put_string(self.name) + put_string(self.media_type) + put_blob(self.data))

    @staticmethod
    def parse(content) -> Attachment:
        c = Cursor(content)
        return Attachment(name=c.string(), media_type=c.string(), data=c.blob())


@dataclass
class SummaryOffset:
    group_opcode: int
    group_start: int
    group_length: int

    def encode(self) -> bytes:
        return put_record(
            op.SUMMARY_OFFSET,
            put_u8(self.group_opcode) + put_u64(self.group_start) + put_u64(self.group_length),
        )

    @staticmethod
    def parse(content) -> SummaryOffset:
        c = Cursor(content)
        return SummaryOffset(group_opcode=c.u8(), group_start=c.u64(), group_length=c.u64())


# --------------------------------------------------------------------------
# Provenance family (spec section 5.15)
#
# Three optional records, none of them announced by a Header flag. Absence is the
# common case and costs nothing: a scene with no provenance carries no record, no
# placeholder and no reserved bytes, exactly as a scene without audio does.
#
# What `parse` refuses here is narrower than what a validator reports. A parse
# refuses only the structurally impossible — a basis that is not a basis, a
# quaternion with no direction, timestamps that make an interval ambiguous —
# because those are values no consumer can do anything sensible with. A value that
# is merely unrecognized (a modality this build has not heard of, a camera model it
# cannot project with) survives parsing and reaches the caller raw, which is the
# distinction between "malformed" and "from a newer registry" that the caller needs
# in order to react differently to the two.
# --------------------------------------------------------------------------


@dataclass
class CoordinateFrame:
    """The frame the file's own coordinates are expressed in. Opcode 0x20.

    A **fixed shape**: every field is always present, so a reader that knows these
    six knows exactly where an appended seventh would begin. The georeference is a
    separate record (`GeodeticAnchor`, 0x23) for that reason — a conditional block
    inside a record makes the offset of everything after it depend on a value, and
    the format already has an idiom for optional-with-zero-cost-absence: a record
    that is not there.

    This supersedes the free-form `coordinate_system` metadata key: where a file
    carries both, the record wins in whole and a reader must not merge them (spec
    section 5.15.2). Merging is the tempting move and the wrong one — the key names
    one entire convention, so half of it cannot be true.
    """

    name: str = ""
    handedness: int = 0
    up_axis: int = 0
    forward_axis: int = 0
    length_unit: int = 0
    metres_per_unit: float = 0.0

    def encode(self, trailer: bytes = b"") -> bytes:
        body = (
            put_string(self.name)
            + put_u8(self.handedness)
            + put_u8(self.up_axis)
            + put_u8(self.forward_axis)
            + put_u8(self.length_unit)
            + put_f64(self.metres_per_unit)
        )
        return put_record(op.COORDINATE_FRAME, body + trailer)

    @staticmethod
    def parse(content) -> CoordinateFrame:
        c = Cursor(content)
        frame = CoordinateFrame(
            name=c.string(),
            handedness=c.u8(),
            up_axis=c.u8(),
            forward_axis=c.u8(),
            length_unit=c.u8(),
            metres_per_unit=c.f64(),
        )
        frame.check()
        return frame

    def check(self) -> None:
        """Refuse a frame that is not one, rather than repair it.

        The reasoning is section 5.4's, about window indices: a degenerate basis does
        not announce itself. It silently re-orients everything a consumer derives from
        it, and a reader that guessed the missing axis would turn a detectable fault
        into plausible wrong output.
        """
        for name, axis in (("up_axis", self.up_axis), ("forward_axis", self.forward_axis)):
            if axis > 5:
                raise MalformedFile(f"CoordinateFrame {name} is {axis}; the registry defines 0..5 (section 5.15.2)")
        if self.up_axis % 3 == self.forward_axis % 3:
            raise MalformedFile(
                f"CoordinateFrame up_axis {self.up_axis} and forward_axis {self.forward_axis} "
                "name the same axis; a frame needs two different ones (section 5.15.2)"
            )
        if not math.isfinite(self.metres_per_unit) or self.metres_per_unit < 0.0:
            raise MalformedFile(
                f"CoordinateFrame metres_per_unit is {self.metres_per_unit}; "
                "it must be finite and not negative (section 5.15.2)"
            )


@dataclass
class GeodeticAnchor:
    """Where a frame's origin sits on the WGS-84 ellipsoid, and which way it faces.

    Opcode 0x23, and its own record rather than a tail on the Coordinate Frame: a
    scene with no georeference carries no anchor, which costs nothing and keeps
    every record in the format one shape (spec section 5.15.5).

    It answers "roughly where on Earth is this" and stops. A producer needing a
    projected coordinate system, a geoid model or a datum other than WGS-84 puts it
    in metadata or an attachment; growing this record into a geodetic library is how
    a container format stops being one.
    """

    frame_name: str = ""
    latitude_deg: float = 0.0
    longitude_deg: float = 0.0
    altitude_m: float = 0.0
    heading_deg: float = 0.0

    def encode(self, trailer: bytes = b"") -> bytes:
        body = put_string(self.frame_name) + put_f64s(
            [self.latitude_deg, self.longitude_deg, self.altitude_m, self.heading_deg]
        )
        return put_record(op.GEODETIC_ANCHOR, body + trailer)

    @staticmethod
    def parse(content) -> GeodeticAnchor:
        c = Cursor(content)
        frame_name = c.string()
        values = c.f64s(4)
        anchor = GeodeticAnchor(
            frame_name=frame_name,
            latitude_deg=values[0],
            longitude_deg=values[1],
            altitude_m=values[2],
            heading_deg=values[3],
        )
        anchor.check()
        return anchor

    def check(self) -> None:
        """Refuse an out-of-range angle rather than wrap it.

        Unlike the unit disagreement in `CoordinateFrame`, there is no second field
        to fall back on here: a latitude of 130 degrees has no reading that is merely
        approximate, and normalizing it would invent a location.
        """
        for label, value, lo, hi in (
            ("latitude_deg", self.latitude_deg, -90.0, 90.0),
            ("longitude_deg", self.longitude_deg, -180.0, 180.0),
            ("altitude_m", self.altitude_m, -math.inf, math.inf),
            ("heading_deg", self.heading_deg, 0.0, 360.0),
        ):
            if not math.isfinite(value):
                raise MalformedFile(f"GeodeticAnchor {label} is {value}; every field must be finite")
            if not lo <= value <= hi or (label == "heading_deg" and value == 360.0):
                raise MalformedFile(f"GeodeticAnchor {label} is {value}, outside its legal range (section 5.15.5)")


#: Coefficient counts each camera model defines, keyed by its registry id. A model
#: absent from here is one this build does not know, which is not the same as one
#: that is wrong: `None` means "ask the caller", not "refuse".
CAMERA_MODEL_COEFFICIENTS: dict[int, tuple[int, ...]] = {
    0: (0,),  # none — the sensor is not a camera
    1: (0,),  # pinhole
    2: (5, 8),  # brown-conrady, plain or rational
    3: (4,),  # kannala-brandt
}

CAMERA_MODEL_NONE = 0
POSE_TO_SCENE = 0
POSE_TO_RIG = 1


@dataclass
class SensorCalibration:
    """One sensor's intrinsics and extrinsics. Opcode 0x21, one record per sensor.

    One record each rather than one record listing all of them, which is the shape
    the rest of the format already uses for anything there can be several of: a
    consumer that wants one sensor fetches one record's byte range.

    The extrinsic maps sensor coordinates into the frame `pose_reference` names,
    in that direction: `p_target = R(rotation) * p_sensor + translation`. The
    opposite convention is equally common in the field, which is why the direction
    is written down in both the specification and here — a consumer that assumes
    wrongly gets a scene that is merely mis-placed rather than one that fails.
    """

    name: str
    modality: str = ""
    camera_model: int = CAMERA_MODEL_NONE
    width_px: int = 0
    height_px: int = 0
    fx: float = 0.0
    fy: float = 0.0
    cx: float = 0.0
    cy: float = 0.0
    distortion: list[float] = field(default_factory=list)
    rotation: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0, 1.0])
    translation: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    pose_reference: int = POSE_TO_SCENE
    rig_name: str = ""

    @property
    def is_camera(self) -> bool:
        return self.camera_model != CAMERA_MODEL_NONE

    def encode(self, trailer: bytes = b"") -> bytes:
        body = (
            put_string(self.name)
            + put_string(self.modality)
            + put_u8(self.camera_model)
            + put_u32(self.width_px)
            + put_u32(self.height_px)
            + put_f64s([self.fx, self.fy, self.cx, self.cy])
            + put_u8(len(self.distortion))
            + put_f64s(self.distortion)
            + put_f64s(self.rotation)
            + put_f64s(self.translation)
            + put_u8(self.pose_reference)
            + put_string(self.rig_name)
        )
        return put_record(op.SENSOR_CALIBRATION, body + trailer)

    @staticmethod
    def parse(content) -> SensorCalibration:
        c = Cursor(content)
        name = c.string()
        modality = c.string()
        camera_model = c.u8()
        width_px = c.u32()
        height_px = c.u32()
        intrinsics = c.f64s(4)
        distortion = c.f64s(c.u8())
        rotation = c.f64s(4)
        translation = c.f64s(3)
        sensor = SensorCalibration(
            name=name,
            modality=modality,
            camera_model=camera_model,
            width_px=width_px,
            height_px=height_px,
            fx=intrinsics[0],
            fy=intrinsics[1],
            cx=intrinsics[2],
            cy=intrinsics[3],
            distortion=distortion,
            rotation=rotation,
            translation=translation,
            pose_reference=c.u8(),
            rig_name=c.string(),
        )
        sensor.check()
        return sensor

    def check(self) -> None:
        for label, value in (
            ("fx", self.fx),
            ("fy", self.fy),
            ("cx", self.cx),
            ("cy", self.cy),
            *((f"distortion[{i}]", v) for i, v in enumerate(self.distortion)),
            *((f"rotation[{i}]", v) for i, v in enumerate(self.rotation)),
            *((f"translation[{i}]", v) for i, v in enumerate(self.translation)),
        ):
            if not math.isfinite(value):
                raise MalformedFile(f"sensor {self.name!r}: {label} is {value}; every value must be finite")

        norm = math.sqrt(sum(v * v for v in self.rotation))
        if not math.isfinite(norm) or norm == 0.0:
            raise MalformedFile(f"sensor {self.name!r}: rotation quaternion has no direction (norm {norm})")

        legal = CAMERA_MODEL_COEFFICIENTS.get(self.camera_model)
        if legal is not None and len(self.distortion) not in legal:
            raise MalformedFile(
                f"sensor {self.name!r}: camera model {self.camera_model} defines "
                f"{' or '.join(str(v) for v in legal)} distortion coefficients, the record carries "
                f"{len(self.distortion)}"
            )
        if not self.is_camera:
            for label, value in (
                ("width_px", self.width_px),
                ("height_px", self.height_px),
                ("fx", self.fx),
                ("fy", self.fy),
                ("cx", self.cx),
                ("cy", self.cy),
            ):
                if value:
                    raise MalformedFile(
                        f"sensor {self.name!r} declares camera_model 0 but a non-zero {label} ({value})"
                    )
        elif self.fx == 0.0 or self.fy == 0.0 or not self.width_px or not self.height_px:
            raise MalformedFile(
                f"sensor {self.name!r} declares camera model {self.camera_model} but has a zero "
                "focal length or image size"
            )

    def unit_rotation(self) -> list[float]:
        """The extrinsic quaternion, renormalized as section 6.4 renormalizes its own."""
        norm = math.sqrt(sum(v * v for v in self.rotation))
        return [v / norm for v in self.rotation]


TRAJECTORY_LINEAR = 0
TRAJECTORY_STEP = 1


@dataclass
class RigTrajectory:
    """The measured pose of the capture platform over the scene clock. Opcode 0x22.

    Not the Camera record of section 5.10, which is a viewing suggestion a reader may
    ignore. This is where the sensors were, and a consumer doing analysis or
    simulation needs it to be right rather than plausible.
    """

    name: str = ""
    interpolation: int = TRAJECTORY_LINEAR
    times: list[float] = field(default_factory=list)
    rotations: list[list[float]] = field(default_factory=list)
    translations: list[list[float]] = field(default_factory=list)

    @property
    def sample_count(self) -> int:
        return len(self.times)

    def encode(self, trailer: bytes = b"") -> bytes:
        body = put_string(self.name) + put_u8(self.interpolation) + put_u32(len(self.times))
        for i, t in enumerate(self.times):
            body += put_f64(t) + put_f64s(self.rotations[i]) + put_f64s(self.translations[i])
        return put_record(op.RIG_TRAJECTORY, body + trailer)

    @staticmethod
    def parse(content) -> RigTrajectory:
        c = Cursor(content)
        trajectory = RigTrajectory(name=c.string(), interpolation=c.u8())
        for _ in range(c.u32()):
            trajectory.times.append(c.f64())
            trajectory.rotations.append(c.f64s(4))
            trajectory.translations.append(c.f64s(3))
        trajectory.check()
        return trajectory

    def check(self) -> None:
        """Refuse times that are not strictly increasing, naming the sample.

        Every interpolation rule is stated in terms of the interval a query lands in,
        and a repeated or reversed timestamp makes that interval ambiguous. There is
        no reading of such a trajectory that is merely approximate.
        """
        if self.interpolation not in (TRAJECTORY_LINEAR, TRAJECTORY_STEP):
            raise MalformedFile(
                f"trajectory {self.name!r} uses interpolation {self.interpolation}; "
                "this reader supports trajectory interpolation registry values "
                "0 (linear) and 1 (step)"
            )
        for i, t in enumerate(self.times):
            if not math.isfinite(t):
                raise MalformedFile(f"trajectory {self.name!r}: sample {i} has a non-finite time ({t})")
            if i and t <= self.times[i - 1]:
                raise MalformedFile(
                    f"trajectory {self.name!r}: sample {i} is at t={t}, not after sample {i - 1} "
                    f"at t={self.times[i - 1]}; times must strictly increase (section 5.15.4)"
                )
        for i, quaternion in enumerate(self.rotations):
            norm = math.sqrt(sum(v * v for v in quaternion))
            if not math.isfinite(norm) or norm == 0.0:
                raise MalformedFile(f"trajectory {self.name!r}: sample {i} rotation has no direction (norm {norm})")
        for i, translation in enumerate(self.translations):
            for k, value in enumerate(translation):
                if not math.isfinite(value):
                    raise MalformedFile(f"trajectory {self.name!r}: sample {i} translation[{k}] is {value}")


@dataclass
class ObjectTableEntry:
    """One object the file names. Everything here is advisory — no field moves a gaussian.

    `object_id` ties the entry to the gaussians carrying that id in their `object_id`
    attribute stream. `anchor` is a representative point for a label or a camera focus,
    NOT the transform pivot (a track folds its pivot into its translation). `dynamics`, when
    present, is a coarse constant-acceleration summary a consumer may read instead of a
    track; it is never read by reconstruction. `embedding`, when present, is the object's
    point in the file's one text-aligned vector space.
    """

    object_id: int
    label: str = ""
    anchor: tuple[float, float, float] = (0.0, 0.0, 0.0)
    #: (velocity, angular_velocity, acceleration), each a 3-vector, or `None`.
    dynamics: tuple[list[float], list[float], list[float]] | None = None
    embedding: list[float] | None = None


@dataclass
class ObjectTable:
    """The scene-wide table of objects. Opcode 0x24, one per file, front matter.

    `embedding_dim` is declared once for the whole file: every embedding is a vector of
    exactly this many `f32`, and `0` means the file declares no embedding space at all.
    A per-entry flag then says whether that object carries a vector, so an object without
    one costs a single byte.
    """

    embedding_dim: int = 0
    entries: list[ObjectTableEntry] = field(default_factory=list)

    def encode(self, trailer: bytes = b"") -> bytes:
        self.check()
        body = put_u32(len(self.entries)) + put_u16(self.embedding_dim)
        for e in self.entries:
            body += put_u32(e.object_id) + put_string(e.label) + put_f32s(e.anchor)
            if e.dynamics is None:
                body += put_u8(0)
            else:
                velocity, angular, acceleration = e.dynamics
                body += put_u8(1) + put_f32s(velocity) + put_f32s(angular) + put_f32s(acceleration)
            if self.embedding_dim > 0:
                if e.embedding is None:
                    body += put_u8(0)
                else:
                    body += put_u8(1) + put_f32s(e.embedding)
        return put_record(op.OBJECT_TABLE, body + trailer)

    @staticmethod
    def parse(content) -> ObjectTable:
        c = Cursor(content)
        count = c.u32()
        table = ObjectTable(embedding_dim=c.u16())
        for _ in range(count):
            entry = ObjectTableEntry(
                object_id=c.u32(),
                label=c.string(),
                anchor=tuple(c.f32s(3)),  # type: ignore[arg-type]
            )
            dynamics_present = c.u8()
            if dynamics_present not in (0, 1):
                raise MalformedFile(
                    f"object {entry.object_id}: dynamics_present is {dynamics_present}, expected 0 or 1",
                    code="invalid-object-presence-flag",
                )
            if dynamics_present:
                entry.dynamics = (c.f32s(3), c.f32s(3), c.f32s(3))
            if table.embedding_dim > 0:
                has_embedding = c.u8()
                if has_embedding not in (0, 1):
                    raise MalformedFile(
                        f"object {entry.object_id}: has_embedding is {has_embedding}, expected 0 or 1",
                        code="invalid-object-presence-flag",
                    )
                if has_embedding:
                    entry.embedding = c.f32s(table.embedding_dim)
            table.entries.append(entry)
        table.check()
        return table

    def check(self) -> None:
        """Distinct object ids, and every stored float finite.

        A duplicate id makes every reference to that object ambiguous, which is the
        duplicate-name failure section 5.15.2 refuses for frames — picking one silently
        is a coin toss. A non-finite embedding is not a weak match, it poisons every
        cosine similarity computed against it, so it is refused rather than surfaced.
        """
        try:
            embedding_dim = operator.index(self.embedding_dim)
        except TypeError:
            embedding_dim = -1
        if not 0 <= embedding_dim <= 0xFFFF:
            raise MalformedFile(
                f"ObjectTable embedding_dim is {self.embedding_dim!r}; expected an integer in [0, 65535]",
                code="invalid-object-embedding-dim",
            )
        seen: set[int] = set()
        for e in self.entries:
            try:
                object_id = operator.index(e.object_id)
            except TypeError:
                object_id = -1
            if not 0 <= object_id <= 0xFFFF_FFFF:
                raise MalformedFile(
                    f"ObjectTable entry has object_id {e.object_id!r}; expected an integer in [0, 4294967295]",
                    code="invalid-object-id",
                )
            if e.object_id in seen:
                raise MalformedFile(
                    f"two ObjectTable entries describe object {e.object_id}; an object is referred to "
                    f"by id and nothing else (section 5.15.6)",
                    code="duplicate-object-id",
                )
            seen.add(e.object_id)
            for k, value in enumerate(e.anchor):
                _check_object_f32(value, f"object {e.object_id}: anchor[{k}]")
            if e.dynamics is not None:
                for name, vector in zip(("velocity", "angular_velocity", "acceleration"), e.dynamics, strict=True):
                    for k, value in enumerate(vector):
                        _check_object_f32(value, f"object {e.object_id}: {name}[{k}]")
            if e.embedding is not None:
                if self.embedding_dim == 0:
                    raise MalformedFile(
                        f"object {e.object_id}: an embedding is present but embedding_dim is 0",
                        code="invalid-object-embedding-shape",
                    )
                if len(e.embedding) != self.embedding_dim:
                    raise MalformedFile(
                        f"object {e.object_id}: embedding has {len(e.embedding)} values, "
                        f"embedding_dim declares {self.embedding_dim}",
                        code="invalid-object-embedding-shape",
                    )
                for k, value in enumerate(e.embedding):
                    _check_object_f32(value, f"object {e.object_id}: embedding[{k}]")


def _check_object_f32(value, field: str) -> None:
    try:
        finite = math.isfinite(value)
        magnitude = abs(value)
    except (TypeError, OverflowError):
        finite = False
        magnitude = math.inf
    if not finite:
        raise MalformedFile(f"{field} is {value!r}, expected a finite f32", code="non-finite-object-value")
    if magnitude > _F32_MAX:
        raise MalformedFile(
            f"{field} is {value!r}, outside the finite f32 range [-{_F32_MAX}, {_F32_MAX}]",
            code="object-value-out-of-f32-range",
        )


@dataclass
class ObjectTrack:
    """One object's rigid pose sampled over the scene clock. Opcode 0x25, front matter.

    The Rig Trajectory of section 5.15.4 pointed at a scene object instead of the capture
    platform: same strictly-increasing times, same clamp-never-extrapolate rule, same
    shortest-arc slerp. It reuses the trajectory interpolation registry (0 linear, 1 step)
    and the `pose_at` machinery in `provenance`, which is why it exposes a `name`.
    """

    object_id: int
    interpolation: int = TRAJECTORY_LINEAR
    times: list[float] = field(default_factory=list)
    rotations: list[list[float]] = field(default_factory=list)
    translations: list[list[float]] = field(default_factory=list)

    @property
    def name(self) -> str:
        """A label for messages, so `pose_at` (written against a trajectory) can reuse it."""
        return f"object {self.object_id}"

    @property
    def sample_count(self) -> int:
        return len(self.times)

    def encode(self, trailer: bytes = b"") -> bytes:
        body = put_u32(self.object_id) + put_u8(self.interpolation) + put_u32(len(self.times))
        for i, t in enumerate(self.times):
            body += put_f64(t) + put_f64s(self.rotations[i]) + put_f64s(self.translations[i])
        return put_record(op.OBJECT_TRACK, body + trailer)

    @staticmethod
    def parse(content) -> ObjectTrack:
        c = Cursor(content)
        track = ObjectTrack(object_id=c.u32(), interpolation=c.u8())
        for _ in range(c.u32()):
            track.times.append(c.f64())
            track.rotations.append(c.f64s(4))
            track.translations.append(c.f64s(3))
        track.check()
        return track

    def check(self) -> None:
        """The object-track rules: not the background, increasing times, real rotations.

        `object_id = 0` is "no object", and a track needs an object to move, so it is
        refused rather than treated as a whole-scene transform. The time and quaternion
        rules are section 5.15.4's, for the same reasons: a repeated timestamp makes an
        interval ambiguous and a zero-norm quaternion is not a rotation.
        """
        try:
            object_id = operator.index(self.object_id)
        except TypeError:
            object_id = -1
        if not 0 <= object_id <= 0xFFFF_FFFF:
            raise MalformedFile(
                f"ObjectTrack has object_id {self.object_id!r}; expected an integer in [0, 4294967295]",
                code="invalid-object-id",
            )
        if self.object_id == 0:
            raise MalformedFile(
                "an ObjectTrack names object 0, which is background/unassigned; a track needs an object "
                "to move (section 5.15.7)",
                code="track-names-background",
            )
        if self.interpolation not in (TRAJECTORY_LINEAR, TRAJECTORY_STEP):
            raise MalformedFile(
                f"track for object {self.object_id} uses interpolation {self.interpolation}; "
                "this reader supports trajectory interpolation registry values "
                "0 (linear) and 1 (step)",
                code="unsupported-trajectory-interpolation",
            )
        if len(self.rotations) != self.sample_count or len(self.translations) != self.sample_count:
            raise MalformedFile(
                f"track for object {self.object_id}: {self.sample_count} times, "
                f"{len(self.rotations)} rotations, and {len(self.translations)} translations; "
                "every sample needs all three",
                code="invalid-object-track-shape",
            )
        for i, t in enumerate(self.times):
            if not math.isfinite(t):
                raise MalformedFile(
                    f"track for object {self.object_id}: sample {i} has a non-finite time ({t})",
                    code="non-finite-object-value",
                )
            if i and t <= self.times[i - 1]:
                raise MalformedFile(
                    f"track for object {self.object_id}: sample {i} is at t={t}, not after sample "
                    f"{i - 1} at t={self.times[i - 1]}; times must strictly increase (section 5.15.4)",
                    code="non-increasing-track-time",
                )
        for i, quaternion in enumerate(self.rotations):
            if len(quaternion) != 4:
                raise MalformedFile(
                    f"track for object {self.object_id}: sample {i} rotation has {len(quaternion)} values, expected 4",
                    code="invalid-object-track-shape",
                )
            norm = math.sqrt(sum(v * v for v in quaternion))
            if not math.isfinite(norm) or norm == 0.0:
                raise MalformedFile(
                    f"track for object {self.object_id}: sample {i} rotation has no direction (norm {norm})",
                    code="non-unit-track-quaternion",
                )
        for i, translation in enumerate(self.translations):
            if len(translation) != 3:
                raise MalformedFile(
                    f"track for object {self.object_id}: sample {i} translation has "
                    f"{len(translation)} values, expected 3",
                    code="invalid-object-track-shape",
                )
            for k, value in enumerate(translation):
                if not math.isfinite(value):
                    raise MalformedFile(
                        f"track for object {self.object_id}: sample {i} translation[{k}] is {value}",
                        code="non-finite-object-value",
                    )
