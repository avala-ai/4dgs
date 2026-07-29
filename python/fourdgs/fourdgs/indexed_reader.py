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
from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile
from .readable import Readable
from .registry import check_quantization_scheme, check_temporal_model
from .serialization import MAGIC, Cursor, check_magic, crc32, iter_records, read_record
from .stream_reader import chunk_stream_bytes, decode_streams, steps_from

#: One read of this size from the front covers the header records of every scene measured
#: so far. A larger header costs one extra round trip, never a wrong parse.
HEAD_PROBE = 64 * 1024

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
    Quantization grids, the Window Table, and the byte range of the audio track if there
    is one — and none of them requires reading a record it does not care about. That
    distinction is not academic: an embedded audio track is a first-class part of a scene
    and sits in the front matter at whatever size the track is, so a walk that
    materializes every record's content fails on the format's flagship case, a single
    file with sound.

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
            yield _FrontRecord(opcode=opcode, offset=at, content_length=length)
            at += _RECORD_HEADER.size + length

    def content(self, record: _FrontRecord, limit: int | None = None) -> bytes:
        """One record's content, from the window when it is there and by a read of exactly
        that record when it is not.

        A Window Table larger than the probe is therefore fetched rather than refused, and
        an audio track nobody asked for is never fetched at all.
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
    audio_range: tuple[int, int] | None
    audio_codec: str | None
    summary_crc_ok: bool | None
    #: `(offset, length)` of the front-matter records this reader did not parse. Opening a
    #: file frames them and stops: a camera nobody asked for costs nothing, and neither
    #: does an attachment the size of a thumbnail sheet.
    camera_range: tuple[int, int] | None = None
    metadata_ranges: list[tuple[int, int]] = field(default_factory=list)
    attachment_ranges: list[tuple[int, int]] = field(default_factory=list)
    statistics: rec.Statistics | None = None
    summary_offsets: list[rec.SummaryOffset] = field(default_factory=list)

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


def open_indexed(source: Readable) -> IndexedScene:
    """Open a scene: a bounded read from the front, then the index. Never the file."""
    size = source.size()
    front = _FrontMatter(source, size)
    check_magic(front.head(len(MAGIC)))

    header = quant = None
    windows: list[tuple[float, float]] = []
    audio_range = None
    audio_codec = None
    camera_range = None
    metadata_ranges: list[tuple[int, int]] = []
    attachment_ranges: list[tuple[int, int]] = []
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
            audio_codec = _audio_codec(front.content(record, limit=AUDIO_CODEC_PREFIX))
            audio_range = (record.offset, record.total_length)
        elif record.opcode == op.CAMERA:
            camera_range = (record.offset, record.total_length)
        elif record.opcode == op.METADATA:
            metadata_ranges.append((record.offset, record.total_length))
        elif record.opcode == op.ATTACHMENT:
            attachment_ranges.append((record.offset, record.total_length))
    if header is None or quant is None:
        raise MalformedFile("the file has no Header or no Quantization record before its first Chunk")

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
        audio_range=audio_range,
        audio_codec=audio_codec,
        summary_crc_ok=crc_ok,
        camera_range=camera_range,
        metadata_ranges=metadata_ranges,
        attachment_ranges=attachment_ranges,
        statistics=statistics,
        summary_offsets=summary_offsets,
    )


def read_chunk(source: Readable, scene: IndexedScene, entry: rec.ChunkIndexEntry, *, max_sh_band: int = 0) -> dict:
    """Fetch and decode one chunk, plus only the SH bands asked for."""
    blob = _read_range(source, entry.chunk_offset, entry.chunk_length, "a chunk index entry")
    head, streams = rec.parse_chunk(Cursor(blob, 9).take(len(blob) - 9))
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

        _, values = decode_stream(cur)
        decoded["sh"][band] = values
    return decoded


def _read_range(source: Readable, offset: int, length: int, what: str) -> bytes:
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
    return source.read(offset, length)


def read_camera(source: Readable, scene: IndexedScene) -> rec.Camera | None:
    """The suggested camera trajectory, fetched only when a caller wants it."""
    if scene.camera_range is None:
        return None
    offset, length = scene.camera_range
    return rec.Camera.parse(Cursor(_read_range(source, offset, length, "the Camera record"), 9).take(length - 9))


def read_metadata(source: Readable, scene: IndexedScene) -> list[rec.Metadata]:
    """Every Metadata record, by range."""
    out = []
    for offset, length in scene.metadata_ranges:
        blob = _read_range(source, offset, length, "a Metadata record")
        out.append(rec.Metadata.parse(Cursor(blob, 9).take(length - 9)))
    return out


def read_attachments(source: Readable, scene: IndexedScene) -> list[rec.Attachment]:
    """Every Attachment record, by range. Each one costs exactly its own bytes."""
    out = []
    for offset, length in scene.attachment_ranges:
        blob = _read_range(source, offset, length, "an Attachment record")
        out.append(rec.Attachment.parse(Cursor(blob, 9).take(length - 9)))
    return out


def _audio_codec(prefix: bytes) -> str:
    """The `codec` field at the front of an Audio record, read out of a prefix of it."""
    try:
        return Cursor(prefix).string()
    except Exception as exc:
        raise MalformedFile(
            f"the Audio record's codec name does not fit the first {AUDIO_CODEC_PREFIX} bytes of the record"
        ) from exc


def read_audio(source: Readable, scene: IndexedScene) -> bytes | None:
    """The embedded track, fetched independently of any gaussian data.

    `None` when the scene has none — a normal value, not an error.
    """
    if scene.audio_range is None:
        return None
    offset, length = scene.audio_range
    blob = _read_range(source, offset, length, "the Audio record")
    return rec.Audio.parse(Cursor(blob, 9).take(length - 9)).data
