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
from dataclasses import dataclass

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile
from .readable import Readable
from .serialization import MAGIC, Cursor, check_magic, crc32, iter_records, read_record
from .stream_reader import decode_streams, steps_from

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
    seen_window_table = False
    audio_range = None
    audio_codec = None
    for record in front.records(len(MAGIC)):
        if record.opcode == op.CHUNK:
            break
        if record.opcode == op.HEADER:
            header = rec.Header.parse(front.content(record))
        elif record.opcode == op.QUANTIZATION:
            quant = rec.Quantization.parse(front.content(record))
        elif record.opcode == op.WINDOW_TABLE:
            windows = rec.WindowTable.parse(front.content(record)).windows
            seen_window_table = True
        elif record.opcode == op.AUDIO:
            # The track's bytes are not read here, and the record is not stepped into: a
            # caller may want the gaussians and never the audio. Only the codec name is
            # parsed, out of a prefix, so a scene with a large track costs nothing to open.
            audio_codec = _audio_codec(front.content(record, limit=AUDIO_CODEC_PREFIX))
            audio_range = (record.offset, record.total_length)
        # Everything the indexed path needs is in hand; the rest of the front matter is
        # somebody else's business and is not worth another read.
        audio_settled = audio_range is not None or (header is not None and not header.has_audio)
        if header is not None and quant is not None and seen_window_table and audio_settled:
            break
    if header is None or quant is None:
        raise MalformedFile("the file has no Header or no Quantization record before its first Chunk")

    footer_size = 9 + 20 + len(MAGIC)
    tail = source.read(max(size - footer_size, 0), min(footer_size, size))
    if tail[-len(MAGIC) :] != MAGIC:
        raise MalformedFile("file does not end with the magic; it may be truncated")
    footer = rec.Footer.parse(read_record(Cursor(tail)).content)

    index: list[rec.ChunkIndexEntry] = []
    crc_ok = None
    if footer.summary_start:
        summary_len = size - footer_size - footer.summary_start
        summary = source.read(footer.summary_start, summary_len)
        if footer.summary_crc:
            crc_ok = crc32(summary) == footer.summary_crc
        for record in iter_records(summary):
            if record.opcode == op.CHUNK_INDEX:
                index.append(rec.ChunkIndexEntry.parse(record.content))

    return IndexedScene(
        header=header,
        quantization=quant,
        windows=windows,
        index=index,
        audio_range=audio_range,
        audio_codec=audio_codec,
        summary_crc_ok=crc_ok,
    )


def read_chunk(source: Readable, scene: IndexedScene, entry: rec.ChunkIndexEntry, *, max_sh_band: int = 0) -> dict:
    """Fetch and decode one chunk, plus only the SH bands asked for."""
    blob = source.read(entry.chunk_offset, entry.chunk_length)
    head, streams = rec.parse_chunk(Cursor(blob, 9).take(len(blob) - 9))
    decoded = decode_streams(
        streams, head.count, steps_from(scene.quantization), np.asarray(scene.quantization.pos_origin), scene.windows
    )
    decoded["sh"] = {}
    for band, offset, length in entry.bands:
        if band > max_sh_band:
            continue
        band_blob = source.read(offset, length)
        cur = Cursor(band_blob, 9)
        cur.u8()  # band index, already known from the index
        from .serialization import decode_stream

        _, values = decode_stream(cur)
        decoded["sh"][band] = values
    return decoded


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
    return rec.Audio.parse(Cursor(source.read(offset, length), 9).take(length - 9)).data
