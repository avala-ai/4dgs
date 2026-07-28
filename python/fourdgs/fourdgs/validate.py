# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Structural validation.

This is what makes a third-party encoder possible: a way to find out *why* a file is
wrong that does not involve reading someone else's decoder. Every finding names the
record, the field and what was expected.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import opcode as op
from . import records as rec
from .exceptions import FourdgsError
from .readable import BytesReadable
from .serialization import MAGIC, check_magic, crc32, iter_records


@dataclass
class Finding:
    severity: str  # "error" | "warning" | "note"
    message: str

    def __str__(self) -> str:
        return f"{self.severity}: {self.message}"


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(f.severity == "error" for f in self.findings)

    def error(self, msg: str) -> None:
        self.findings.append(Finding("error", msg))

    def warn(self, msg: str) -> None:
        self.findings.append(Finding("warning", msg))

    def note(self, msg: str) -> None:
        self.findings.append(Finding("note", msg))


def validate(data: bytes) -> Report:
    report = Report()
    try:
        check_magic(data)
    except FourdgsError as exc:
        report.error(str(exc))
        return report

    if not data.endswith(MAGIC):
        report.error("file does not end with the magic; it is truncated or was written by a broken encoder")

    seen: list[int] = []
    header = None
    quant = None
    chunk_count = 0
    counted = 0
    index: list[rec.ChunkIndexEntry] = []
    footer = None

    try:
        for record in iter_records(data, len(MAGIC)):
            seen.append(record.opcode)
            if record.opcode == op.HEADER:
                header = rec.Header.parse(record.content)
            elif record.opcode == op.QUANTIZATION:
                quant = rec.Quantization.parse(record.content)
            elif record.opcode == op.CHUNK:
                head, _ = rec.parse_chunk(record.content)
                chunk_count += 1
                counted += head.count
                if head.t1 < head.t0:
                    report.error(f"chunk {chunk_count} has t1 ({head.t1}) before t0 ({head.t0})")
            elif record.opcode == op.CHUNK_INDEX:
                index.append(rec.ChunkIndexEntry.parse(record.content))
            elif record.opcode == op.FOOTER:
                footer = rec.Footer.parse(record.content)
            elif op.is_private(record.opcode):
                report.note(
                    f"private record 0x{record.opcode:02X} ({len(record.content)} bytes) — skipped, as required"
                )
            elif record.opcode not in op.NAMES:
                report.note(f"unknown record 0x{record.opcode:02X} — skipped, as required")
    except FourdgsError as exc:
        report.error(f"stopped reading: {exc}")

    if not seen:
        report.error("no records at all")
        return report
    if seen[0] != op.HEADER:
        report.error(f"first record is {op.name(seen[0])}; the Header must come first")
    if header is None:
        report.error("no Header record")
    if quant is None:
        report.error("no Quantization record")
    if footer is None:
        report.error("no Footer record")

    if header is not None and counted != header.gaussian_count:
        report.error(f"Header declares {header.gaussian_count} gaussians; chunks contain {counted}")

    if header is not None and header.has_audio and op.AUDIO not in seen:
        report.error("Header says the file has audio, but there is no Audio record")
    if header is not None and not header.has_audio and op.AUDIO in seen:
        report.error("there is an Audio record, but the Header's audio flag is clear")

    for i, entry in enumerate(index):
        if entry.chunk_offset + entry.chunk_length > len(data):
            report.error(f"chunk index entry {i} points past the end of the file")
        elif data[entry.chunk_offset] != op.CHUNK:
            report.error(f"chunk index entry {i} does not point at a Chunk record")

    if footer is not None and footer.summary_crc and footer.summary_start:
        tail = len(data) - (9 + 20 + len(MAGIC))
        actual = crc32(data[footer.summary_start : tail])
        if actual != footer.summary_crc:
            report.error("summary CRC mismatch: the index is untrustworthy (a streamed read still works)")

    if header is not None and not index:
        report.warn("no chunk index: this file can only be read front to back, not seeked")

    # Opening the file the way a seeking client would is itself a check.
    try:
        from .indexed_reader import open_indexed

        open_indexed(BytesReadable(data))
    except FourdgsError as exc:
        report.error(f"a seeking reader cannot open this file: {exc}")

    return report
