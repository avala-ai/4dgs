# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Record bodies: one dataclass per record type, each able to write and read itself.

Every `parse` here reads the fields it knows and stops. It never asserts that the record
ended where its knowledge did, because a newer writer may have appended fields — that is
the compatibility rule, and honouring it is one line per record rather than a policy
nobody remembers.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import opcode as op
from .serialization import (
    Cursor,
    put_blob,
    put_f64,
    put_f64s,
    put_record,
    put_str_map,
    put_string,
    put_u8,
    put_u32,
    put_u64,
)

FLAG_HAS_AUDIO = 1 << 0
FLAG_CHUNKS_COMPRESSED = 1 << 1


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

    def encode(self) -> bytes:
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
        return put_record(op.HEADER, body)

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

    def encode(self) -> bytes:
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
        return put_record(op.QUANTIZATION, body)

    @staticmethod
    def parse(content) -> Quantization:
        c = Cursor(content)
        scheme = c.string()
        origin = c.f64s(3)
        steps = c.f64s(8)
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
            step_sh=c.u8(),
            bounds=c.str_map(),
        )


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
class ChunkIndexEntry:
    t0: float
    t1: float
    chunk_offset: int
    chunk_length: int
    gaussian_count: int
    bands: list[tuple[int, int, int]] = field(default_factory=list)  # (band, offset, length)

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
