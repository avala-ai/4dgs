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
    head = source.read(0, min(HEAD_PROBE, size))
    check_magic(head)

    header = quant = None
    windows: list[tuple[float, float]] = []
    audio_range = None
    audio_codec = None
    for record in iter_records(head, len(MAGIC)):
        if record.opcode == op.HEADER:
            header = rec.Header.parse(record.content)
        elif record.opcode == op.QUANTIZATION:
            quant = rec.Quantization.parse(record.content)
        elif record.opcode == op.WINDOW_TABLE:
            windows = rec.WindowTable.parse(record.content).windows
        elif record.opcode == op.AUDIO:
            audio = rec.Audio.parse(record.content)
            audio_codec = audio.codec
            audio_range = (record.offset, len(record.content) + 9)
        elif record.opcode == op.CHUNK:
            break
    if header is None or quant is None:
        raise MalformedFile("header records did not fit the probe read; a larger probe is needed")

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


def read_audio(source: Readable, scene: IndexedScene) -> bytes | None:
    """The embedded track, fetched independently of any gaussian data.

    `None` when the scene has none — a normal value, not an error.
    """
    if scene.audio_range is None:
        return None
    offset, length = scene.audio_range
    return rec.Audio.parse(Cursor(source.read(offset, length), 9).take(length - 9)).data
