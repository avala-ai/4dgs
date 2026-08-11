# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Indexed reading: the Footer, then the index, then only what an instant needs.

The seek rule is one line and it is the whole algorithm:

    chunks_for(t) == every index entry whose [t0, t1) contains t

Whether that is cheap depends on the content, not on this code. Gaussians with finite
lifetimes partition into many small chunks; content where everything lives for the whole
clip collapses to a single entry and an instant costs the scene. Both are correct files.
"""

from __future__ import annotations

import struct
from collections.abc import Iterator
from dataclasses import dataclass, field, replace

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile
from .model import AudioSource, AudioSourceKeyframe
from .object_layer import ObjectLayer
from .provenance import Provenance
from .readable import Readable
from .registry import check_quantization_scheme, check_temporal_model
from .serialization import MAGIC, Cursor, check_magic, crc32, iter_records, read_record
from .stream_reader import check_sh_codes, chunk_stream_bytes, decode_streams, steps_from

#: One read of this size from the front covers the header records of every scene measured
#: so far. A larger header costs one extra round trip, never a wrong parse.
HEAD_PROBE = 64 * 1024

#: The most bytes one deferred front-matter record may ask an indexed read to hold.
#:
#: An index entry is data, and a crafted one can name any length inside the file. The
#: records this bounds — Camera, Metadata, the provenance family, the object layer, an
#: audio source descriptor — are small by construction, so a range past this is a claim
#: the format does not make. It deliberately does not cover chunks, spherical-harmonic
#: bands or Attachments: those carry payloads the spec allows to be arbitrarily large,
#: and capping them would refuse valid files. Shared by value with the Rust, TypeScript
#: and Dart readers, so the same file is read or refused the same way everywhere.
MAX_FRONT_MATTER_BYTES = 64 * 1024 * 1024

#: How much of an Audio record is read to learn its codec. The codec name is the record's
#: first field, so a prefix answers it; the track stays where it is.
AUDIO_CODEC_PREFIX = 4096

_RECORD_HEADER = struct.Struct("<BQ")


@dataclass(frozen=True)
class _FrontRecord:
    """One record's framing: everything except its bytes."""

    opcode: int
    #: Offset of the record's opcode byte.
    offset: int
    content_length: int

    @property
    def total_length(self) -> int:
        return self.content_length + _RECORD_HEADER.size


class _FrontMatter:
    """A sliding window over the front of a resource, walked by header.

    An indexed reader wants four things from the front matter — the Header, the
    Quantization grids, the Window Table, and the byte ranges of any audio sources — and
    none requires reading a payload it does not care about. Encoded audio is a
    first-class part of a scene and may be arbitrarily large, so materializing every
    record's content defeats bounded indexed opening.

    So a record is stepped over by arithmetic. Its length is in its header, and its bytes
    are not needed to find the next one.
    """

    def __init__(self, source: Readable, size: int, probe: int = HEAD_PROBE) -> None:
        self._source = source
        self._size = size
        self._probe = probe
        self._window = b""
        self._window_at = 0

    def head(self, length: int) -> bytes:
        """The first `length` bytes of the resource, for the magic check."""
        want = min(length, self._size)
        self._ensure(0, want)
        return self._window[:want]

    def records(self, start: int) -> Iterator[_FrontRecord]:
        """Every record from `start`, in file order, a bounded window at a time."""
        at = start
        while at + _RECORD_HEADER.size <= self._size:
            self._ensure(at, _RECORD_HEADER.size)
            opcode, length = _RECORD_HEADER.unpack_from(self._window, at - self._window_at)
            end = at + _RECORD_HEADER.size + length
            if end > self._size:
                raise MalformedFile(
                    f"{op.name(opcode)} record at byte {at} spans [{at}, {end}), outside the {self._size}-byte file"
                )
            yield _FrontRecord(opcode=opcode, offset=at, content_length=length)
            at = end

    def content(self, record: _FrontRecord, limit: int | None = None) -> bytes:
        """One record's content, from the window when it is there and by a read of exactly
        that record when it is not.

        A Window Table larger than the probe is therefore fetched rather than refused, and
        audio payloads nobody asked for are never fetched at all.
        """
        at = record.offset + _RECORD_HEADER.size
        length = min(record.content_length, self._size - at)
        if limit is not None:
            length = min(length, limit)
        if self._covers(at, length):
            start = at - self._window_at
            return self._window[start : start + length]
        if at + length > self._size:
            raise MalformedFile(f"a record spans [{at}, {at + length}), outside the {self._size}-byte file")
        if length <= self._probe:
            self._ensure(at, length)
            start = at - self._window_at
            return self._window[start : start + length]
        return self._source.read(at, length)

    def _covers(self, at: int, length: int) -> bool:
        return at >= self._window_at and at + length <= self._window_at + len(self._window)

    def _ensure(self, at: int, length: int) -> None:
        if self._covers(at, length):
            return
        if at < 0 or at + length > self._size:
            raise MalformedFile(f"a record spans [{at}, {at + length}), outside the {self._size}-byte file")
        want = min(max(self._probe, length), self._size - at)
        self._window = self._source.read(at, want)
        self._window_at = at


@dataclass
class IndexedScene:
    header: rec.Header
    quantization: rec.Quantization
    windows: list[tuple[float, float]]
    index: list[rec.ChunkIndexEntry]
    audio_sources: list[IndexedAudioSource]
    summary_crc_ok: bool | None
    #: `(offset, length)` of the front-matter records this reader did not parse. Opening a
    #: file frames them and stops: a camera nobody asked for costs nothing, and neither
    #: does an attachment the size of a thumbnail sheet.
    camera_range: tuple[int, int] | None = None
    metadata_ranges: list[tuple[int, int]] = field(default_factory=list)
    attachment_ranges: list[tuple[int, int]] = field(default_factory=list)
    #: `(opcode, offset, length)` of every provenance record framed during the walk.
    #: Framed, not read: a Rig Trajectory is unbounded — a ten-minute capture logged at
    #: 100 Hz is sixty thousand samples — and a consumer that wants the gaussians should
    #: not pay for it. This is also the whole discovery mechanism for the family, which
    #: is why no Header flag announces it: the walk was already happening.
    provenance_ranges: list[tuple[int, int, int]] = field(default_factory=list)
    statistics: rec.Statistics | None = None
    summary_offsets: list[rec.SummaryOffset] = field(default_factory=list)
    _audio_descriptor_cache: dict[int, AudioSource] = field(default_factory=dict, repr=False)

    @property
    def has_audio(self) -> bool:
        return self.header.has_audio

    def chunks_for_time(self, t: float) -> list[rec.ChunkIndexEntry]:
        """The normative seek rule."""
        return [e for e in self.index if e.covers(t)]

    def chunks_for_range(self, a: float, b: float) -> list[rec.ChunkIndexEntry]:
        return [e for e in self.index if e.t0 < b and a < e.t1]

    def bytes_for_time(self, t: float, *, max_sh_band: int = 0) -> int:
        """What a seek to `t` will transfer, so a caller can budget before asking."""
        total = 0
        for entry in self.chunks_for_time(t):
            total += entry.chunk_length
            total += sum(length for band, _, length in entry.bands if band <= max_sh_band)
        return total


@dataclass(frozen=True)
class IndexedAudioSource:
    """Ranges for one source; opening a scene does not fetch either record."""

    source_id: int
    descriptor_range: tuple[int, int] | None
    data_offset: int
    data_length: int
    legacy_codec: str | None = None
    legacy_start_sec: float = 0.0


def open_indexed(source: Readable) -> IndexedScene:
    """Open a scene: a bounded read from the front, then the index. Never the file."""
    size = source.size()
    front = _FrontMatter(source, size)
    check_magic(front.head(len(MAGIC)))

    header = quant = None
    windows: list[tuple[float, float]] = []
    source_ranges: dict[int, tuple[int, int]] = {}
    data_ranges: dict[int, tuple[int, int]] = {}
    legacy_audio: IndexedAudioSource | None = None
    camera_range = None
    metadata_ranges: list[tuple[int, int]] = []
    attachment_ranges: list[tuple[int, int]] = []
    provenance_ranges: list[tuple[int, int, int]] = []
    for record in front.records(len(MAGIC)):
        if record.opcode == op.CHUNK:
            break
        if record.opcode == op.HEADER:
            header = rec.Header.parse(front.content(record))
            check_temporal_model(header.temporal_model)
        elif record.opcode == op.QUANTIZATION:
            quant = rec.Quantization.parse(front.content(record))
            check_quantization_scheme(quant.scheme)
        elif record.opcode == op.WINDOW_TABLE:
            windows = rec.WindowTable.parse(front.content(record)).windows
        elif record.opcode == op.AUDIO:
            # The track's bytes are not read here, and the record is not stepped into: a
            # caller may want the gaussians and never the audio. Only the codec name is
            # parsed, out of a prefix, so a scene with a large track costs nothing to open.
            prefix = front.content(record, limit=AUDIO_CODEC_PREFIX)
            codec, start_sec, data_at, data_length = _legacy_audio_prefix(prefix, record.offset, record.content_length)
            legacy_audio = IndexedAudioSource(
                source_id=0,
                descriptor_range=None,
                data_offset=data_at,
                data_length=data_length,
                legacy_codec=codec,
                legacy_start_sec=start_sec,
            )
        elif record.opcode == op.AUDIO_SOURCE:
            source_id = _source_id(front.content(record, limit=4), "Audio Source")
            if source_id in source_ranges:
                raise MalformedFile(f"Audio Source id {source_id} appears more than once")
            source_ranges[source_id] = (record.offset, record.total_length)
        elif record.opcode == op.AUDIO_DATA:
            prefix = front.content(record, limit=12)
            source_id, data_length = _audio_data_prefix(prefix)
            if source_id in data_ranges:
                raise MalformedFile(f"Audio Data id {source_id} appears more than once")
            if record.content_length < 12 + data_length:
                raise MalformedFile(
                    f"Audio Data id {source_id} declares {data_length} bytes, "
                    f"but its record content is only {record.content_length} bytes"
                )
            data_ranges[source_id] = (record.offset + _RECORD_HEADER.size + 12, data_length)
        elif record.opcode == op.CAMERA:
            camera_range = (record.offset, record.total_length)
        elif record.opcode == op.METADATA:
            metadata_ranges.append((record.offset, record.total_length))
        elif record.opcode == op.ATTACHMENT:
            attachment_ranges.append((record.offset, record.total_length))
        elif op.is_provenance(record.opcode):
            provenance_ranges.append((record.opcode, record.offset, record.total_length))
    if header is None or quant is None:
        raise MalformedFile("the file has no Header or no Quantization record before its first Chunk")
    if legacy_audio is not None and source_ranges:
        raise MalformedFile("the file mixes a legacy Audio record with Audio Source records")
    # A legacy Audio record stands alone: an Audio Data record beside it has no descriptor to
    # match, the orphan the streamed reader rejects. The legacy branch below never inspects
    # ``data_ranges``, so it is caught here.
    if legacy_audio is not None and data_ranges:
        source_id = min(data_ranges)
        raise MalformedFile(f"Audio Data id {source_id} has no matching Audio Source record")
    audio_sources: list[IndexedAudioSource] = []
    if legacy_audio is not None:
        audio_sources.append(legacy_audio)
    else:
        for source_id in sorted(source_ranges):
            if source_id not in data_ranges:
                raise MalformedFile(f"Audio Source id {source_id} has no matching Audio Data record")
            data_offset, data_length = data_ranges.pop(source_id)
            audio_sources.append(
                IndexedAudioSource(
                    source_id=source_id,
                    descriptor_range=source_ranges[source_id],
                    data_offset=data_offset,
                    data_length=data_length,
                )
            )
        if data_ranges:
            source_id = min(data_ranges)
            raise MalformedFile(f"Audio Data id {source_id} has no matching Audio Source record")
    if header.has_audio != bool(audio_sources):
        state = "set" if header.has_audio else "clear"
        raise MalformedFile(
            f"the Header audio flag is {state}, but the file contains {len(audio_sources)} audio sources"
        )

    footer_size = 9 + 20 + len(MAGIC)
    tail = source.read(max(size - footer_size, 0), min(footer_size, size))
    if tail[-len(MAGIC) :] != MAGIC:
        raise MalformedFile("file does not end with the magic; it may be truncated")
    footer = rec.Footer.parse(read_record(Cursor(tail)).content)

    index: list[rec.ChunkIndexEntry] = []
    statistics = None
    summary_offsets: list[rec.SummaryOffset] = []
    crc_ok = None
    if footer.summary_start:
        summary_len = size - footer_size - footer.summary_start
        if summary_len < 0:
            raise MalformedFile(
                f"the footer says the summary starts at {footer.summary_start}, "
                f"past the footer itself at {size - footer_size}"
            )
        summary = source.read(footer.summary_start, summary_len)
        if footer.summary_crc:
            crc_ok = crc32(summary) == footer.summary_crc
        for record in iter_records(summary):
            if record.opcode == op.CHUNK_INDEX:
                index.append(rec.ChunkIndexEntry.parse(record.content))
            elif record.opcode == op.STATISTICS:
                statistics = rec.Statistics.parse(record.content)
            elif record.opcode == op.SUMMARY_OFFSET:
                summary_offsets.append(rec.SummaryOffset.parse(record.content))

    return IndexedScene(
        header=header,
        quantization=quant,
        windows=windows,
        index=index,
        audio_sources=audio_sources,
        summary_crc_ok=crc_ok,
        camera_range=camera_range,
        metadata_ranges=metadata_ranges,
        attachment_ranges=attachment_ranges,
        provenance_ranges=provenance_ranges,
        statistics=statistics,
        summary_offsets=summary_offsets,
    )


def read_chunk(source: Readable, scene: IndexedScene, entry: rec.ChunkIndexEntry, *, max_sh_band: int = 0) -> dict:
    """Fetch and decode one chunk, plus only the SH bands asked for."""
    blob = _read_range(source, entry.chunk_offset, entry.chunk_length, "a chunk index entry")
    framed = Cursor(blob)
    opcode = framed.u8()
    content_length = framed.u64()
    if opcode != op.CHUNK or content_length + 9 != len(blob):
        raise MalformedFile(
            f"the chunk index entry at {entry.chunk_offset} declares {entry.chunk_length} "
            f"bytes; the record there frames exactly {content_length + 9}",
            code="index-record-mismatch",
        )
    head, streams = rec.parse_chunk(framed.take(content_length))
    for field_name, indexed, actual in (
        ("t0", entry.t0, head.t0),
        ("t1", entry.t1, head.t1),
        ("gaussian_count", entry.gaussian_count, head.count),
    ):
        if indexed != actual:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares {field_name} "
                f"{indexed}; the Chunk record there declares {actual}",
                code="index-record-mismatch",
            )
    decoded = decode_streams(
        chunk_stream_bytes(head, streams),
        head.count,
        steps_from(scene.quantization),
        np.asarray(scene.quantization.pos_origin),
        scene.windows,
        scene.header.cutoff,
    )
    decoded["sh"] = {}
    for band, offset, length in entry.bands:
        if band > max_sh_band:
            continue
        band_blob = _read_range(source, offset, length, f"index band {band}")
        cur = Cursor(band_blob, 9)
        cur.u8()  # band index, already known from the index
        from .serialization import decode_stream

        attribute, values = decode_stream(cur)
        if attribute != op.SH_BAND_STREAM:
            raise MalformedFile(
                f"the SH Band Stream at {offset} declares inner attribute_id {attribute}; "
                f"version 1 fixes it at {op.SH_BAND_STREAM}"
            )
        expected_shape = (int(head.count), 3 * (2 * band + 1))
        if values.shape != expected_shape:
            raise MalformedFile(
                f"the SH Band Stream at {offset} for band {band} decodes to shape "
                f"{values.shape}; its owning Chunk requires {expected_shape}",
                code="stream-element-count-mismatch",
            )
        check_sh_codes(values, f"the SH Band Stream at {offset}")
        decoded["sh"][band] = values
    return decoded


def _read_range(source: Readable, offset: int, length: int, what: str, *, front_matter: bool = False) -> bytes:
    """Read a byte range a record pointed at, refusing one that leaves the file.

    An index entry is data, and data in an untrusted file can say anything. A range that
    runs off the end has to come back as a malformed file rather than as whatever the
    transport happens to raise — a caller decoding a hostile file should not have to catch
    the exception type of somebody's HTTP client.
    """
    size = source.size()
    if offset < 0 or length < 0 or offset + length > size:
        raise MalformedFile(f"{what} spans [{offset}, {offset + length}), outside the {size}-byte file")
    if length < 9:
        raise MalformedFile(f"{what} is {length} bytes, too short to be a record")
    if front_matter and length > MAX_FRONT_MATTER_BYTES:
        raise MalformedFile(f"{what} is {length} bytes, past the {MAX_FRONT_MATTER_BYTES} byte ceiling")
    return source.read(offset, length)


def read_camera(source: Readable, scene: IndexedScene) -> rec.Camera | None:
    """The suggested camera trajectory, fetched only when a caller wants it."""
    if scene.camera_range is None:
        return None
    offset, length = scene.camera_range
    return rec.Camera.parse(
        Cursor(_read_range(source, offset, length, "the Camera record", front_matter=True), 9).take(length - 9)
    )


def read_metadata(source: Readable, scene: IndexedScene) -> list[rec.Metadata]:
    """Every Metadata record, by range."""
    out = []
    for offset, length in scene.metadata_ranges:
        blob = _read_range(source, offset, length, "a Metadata record", front_matter=True)
        out.append(rec.Metadata.parse(Cursor(blob, 9).take(length - 9)))
    return out


def read_attachments(source: Readable, scene: IndexedScene) -> list[rec.Attachment]:
    """Every Attachment record, by range. Each one costs exactly its own bytes."""
    out = []
    for offset, length in scene.attachment_ranges:
        blob = _read_range(source, offset, length, "an Attachment record")
        out.append(rec.Attachment.parse(Cursor(blob, 9).take(length - 9)))
    return out


def read_provenance(source: Readable, scene: IndexedScene) -> Provenance:
    """Every provenance record, by range, fetched only when a caller wants them.

    Opening a file frames these and stops, so a scene with a long rig trajectory costs
    the same to open as one with none. This is where a caller says it wants them.

    The object-layer records (`0x24`, `0x25`) are in the same opcode family and are
    framed by the same walk, but they belong to the object layer rather than provenance,
    so they are skipped here and read by `read_objects`. A still-reserved opcode
    (`0x26`-`0x2F`, which no version-1 writer emits) is framed and skipped by both, which
    is the forward-compatibility rule doing its job inside a family — and why the ranges
    carry their opcode: skipping requires knowing what was skipped.
    """
    out = Provenance()
    for opcode, offset, length in scene.provenance_ranges:
        if opcode not in (op.COORDINATE_FRAME, op.SENSOR_CALIBRATION, op.RIG_TRAJECTORY, op.GEODETIC_ANCHOR):
            continue
        blob = _read_range(source, offset, length, f"a {op.name(opcode)} record", front_matter=True)
        content = Cursor(blob, 9).take(length - 9)
        if opcode == op.COORDINATE_FRAME:
            out.frames.append(rec.CoordinateFrame.parse(content))
        elif opcode == op.SENSOR_CALIBRATION:
            out.sensors.append(rec.SensorCalibration.parse(content))
        elif opcode == op.RIG_TRAJECTORY:
            # Section 5.15.4: a trajectory with no samples "MUST be read as though the
            # record were absent".
            trajectory = rec.RigTrajectory.parse(content)
            if trajectory.sample_count > 0:
                out.trajectories.append(trajectory)
        elif opcode == op.GEODETIC_ANCHOR:
            out.anchors.append(rec.GeodeticAnchor.parse(content))
    out.check()
    return out


def read_objects(source: Readable, scene: IndexedScene) -> ObjectLayer:
    """The object layer — the Object Table and the SE(3) tracks — fetched by range.

    Framed by the same front-matter walk as provenance (both families share the opcode
    range), and read only when a caller asks. A file that names no objects returns an
    empty layer, which is a value and not an error.
    """
    out = ObjectLayer()
    for opcode, offset, length in scene.provenance_ranges:
        if opcode not in (op.OBJECT_TABLE, op.OBJECT_TRACK):
            continue
        blob = _read_range(source, offset, length, f"a {op.name(opcode)} record", front_matter=True)
        content = Cursor(blob, 9).take(length - 9)
        if opcode == op.OBJECT_TABLE:
            if out.table is not None:
                raise MalformedFile(
                    f"a second ObjectTable record appears at byte {offset}; "
                    "a file may carry exactly one scene-wide object table",
                    code="duplicate-object-table",
                )
            out.table = rec.ObjectTable.parse(content)
        else:
            # Section 5.15.7: a zero-sample track "has no pose and is read as absent".
            # Keeping it would make one empty track a non-empty object layer, and two
            # empty tracks for an id a duplicate the layer refuses.
            track = rec.ObjectTrack.parse(content)
            if track.sample_count > 0:
                out.tracks.append(track)
    out.check()
    return out


def _source_id(prefix: bytes, record_name: str) -> int:
    try:
        return Cursor(prefix).u32()
    except Exception as exc:
        raise MalformedFile(f"the {record_name} record does not contain its u32 source id") from exc


def _audio_data_prefix(prefix: bytes) -> tuple[int, int]:
    try:
        c = Cursor(prefix)
        return c.u32(), c.u64()
    except Exception as exc:
        raise MalformedFile("the Audio Data record does not contain its source id and byte length") from exc


def _legacy_audio_prefix(prefix: bytes, record_at: int, content_length: int) -> tuple[str, float, int, int]:
    """Read the old descriptor fields without fetching the old payload."""
    try:
        c = Cursor(prefix)
        codec = c.string()
        start_sec = c.f64()
        data_length = c.u64()
    except Exception as exc:
        raise MalformedFile(
            f"the legacy Audio descriptor does not fit the first {AUDIO_CODEC_PREFIX} bytes of the record"
        ) from exc
    if content_length < c.pos + data_length:
        raise MalformedFile(
            f"the legacy Audio record declares {data_length} data bytes, but its content is only {content_length} bytes"
        )
    return codec, start_sec, record_at + _RECORD_HEADER.size + c.pos, data_length


def read_audio(source: Readable, scene: IndexedScene) -> bytes | None:
    """Compatibility accessor for the first source's encoded bytes."""
    if not scene.audio_sources:
        return None
    entry = scene.audio_sources[0]
    _read_audio_source(source, scene, entry, include_data=False)
    return source.read(entry.data_offset, entry.data_length)


def read_audio_sources(source: Readable, scene: IndexedScene) -> list[AudioSource]:
    """Fetch every descriptor and payload. Use `read_audio_range` to stream one instead."""
    return [_read_audio_source(source, scene, entry) for entry in scene.audio_sources]


def read_audio_source_descriptors(source: Readable, scene: IndexedScene) -> list[AudioSource]:
    """Fetch every small descriptor without transferring any encoded payload bytes."""
    return [_read_audio_source(source, scene, entry, include_data=False) for entry in scene.audio_sources]


def read_audio_source_state(source: Readable, scene: IndexedScene, source_id: int, t: float):
    """Reconstruct one source at scene time `t` without fetching its encoded payload."""
    entry = next((item for item in scene.audio_sources if item.source_id == source_id), None)
    if entry is None:
        raise MalformedFile(f"this scene has no audio source id {source_id}")
    return _read_audio_source(source, scene, entry, include_data=False).state_at(t)


def read_audio_range(source: Readable, scene: IndexedScene, source_id: int, offset: int, length: int) -> bytes:
    """Validate/cache the small descriptor, then read one source-relative payload range."""
    entry = next((item for item in scene.audio_sources if item.source_id == source_id), None)
    if entry is None:
        raise MalformedFile(f"this scene has no audio source id {source_id}")
    _read_audio_source(source, scene, entry, include_data=False)
    if offset < 0 or length < 0 or offset + length > entry.data_length:
        raise MalformedFile(
            f"audio source {source_id} range [{offset}, {offset + length}) is outside "
            f"its {entry.data_length}-byte payload"
        )
    return source.read(entry.data_offset + offset, length)


def _read_audio_source(
    source: Readable, scene: IndexedScene, entry: IndexedAudioSource, *, include_data: bool = True
) -> AudioSource:
    cached = scene._audio_descriptor_cache.get(entry.source_id)
    if cached is not None:
        if not include_data:
            return cached
        return replace(cached, data=source.read(entry.data_offset, entry.data_length))
    if entry.descriptor_range is None:
        data = source.read(entry.data_offset, entry.data_length) if include_data else b""
        descriptor = AudioSource(
            source_id=entry.source_id,
            codec=entry.legacy_codec or "",
            data=data,
            data_size=entry.data_length,
            channel_layout="",
            start_sec=entry.legacy_start_sec,
            duration_sec=max(0.0, scene.header.duration_sec - entry.legacy_start_sec),
            spatial=False,
        )
        scene._audio_descriptor_cache[entry.source_id] = replace(descriptor, data=b"")
        return descriptor
    offset, length = entry.descriptor_range
    descriptor = rec.AudioSource.parse(
        Cursor(_read_range(source, offset, length, "the Audio Source record", front_matter=True), 9).take(length - 9)
    )
    if descriptor.source_id != entry.source_id:
        raise MalformedFile(f"Audio Source range for id {entry.source_id} contains id {descriptor.source_id}")
    if descriptor.data_length != entry.data_length:
        raise MalformedFile(
            f"Audio Source id {entry.source_id} declares {descriptor.data_length} bytes, "
            f"its Audio Data record declares {entry.data_length}"
        )
    for index, keyframe in enumerate(descriptor.keyframes):
        if keyframe.time < 0 or keyframe.time > scene.header.duration_sec:
            raise MalformedFile(
                f"Audio Source id {entry.source_id} keyframe {index} time {keyframe.time} "
                f"is outside [0, {scene.header.duration_sec}]"
            )
    descriptor = AudioSource(
        source_id=descriptor.source_id,
        name=descriptor.name,
        codec=descriptor.codec,
        channel_layout=descriptor.channel_layout,
        data=b"",
        data_size=entry.data_length,
        start_sec=descriptor.start_sec,
        duration_sec=descriptor.duration_sec,
        gain=descriptor.gain,
        spatial=descriptor.spatial,
        loop=descriptor.loop,
        position=tuple(descriptor.position),
        rotation=tuple(descriptor.rotation),
        keyframes=[
            AudioSourceKeyframe(
                time=keyframe.time,
                position=tuple(keyframe.position),
                rotation=tuple(keyframe.rotation),
            )
            for keyframe in descriptor.keyframes
        ],
        interpolation=descriptor.interpolation,
    )
    scene._audio_descriptor_cache[entry.source_id] = descriptor
    if include_data:
        return replace(descriptor, data=source.read(entry.data_offset, entry.data_length))
    return descriptor
