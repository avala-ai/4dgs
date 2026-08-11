# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Which refusal, and which byte it fired at.

The library already names its refusals — every exception carries a `code`, the stable
identifier the conformance corpus is written against — and its messages already say which
value was found and what was expected. What neither of them carries is the **offset**: an
exception is raised where the value was parsed, not where its bytes sit, and by then the
record's position is several frames up the stack.

So the tool supplies it. The refusal vocabulary the corpus compares is six identifiers,
each of which is about exactly one kind of record, and a framing walk knows where every
record is. That is the whole mechanism: walk the framing, ask which record this refusal is
about, print the byte.

Front matter is located from the framing and the bytes it frames: which record, and then
which record *of that kind*, since nothing forbids a second Header and a reader refuses at
the first one carrying a value it does not implement. A refusal that lives inside a chunk's
streams is located by decoding chunks one at a time until one of them refuses, which is
also the only way to *find* those refusals at all — the framing walk steps over a chunk by
its declared length and never looks inside it, which is why the framing-only validator
called two of the invalid corpus's seven files clean.

Nothing here holds more than one chunk. That is not an optimization: the files this tool
exists for are the ones nobody can afford to hold, and a validator that answers "do the
chunks decode?" by keeping every chunk it decoded is unusable on them.

This module is `rust/cli/src/refusal.rs` in Python. Two tools that place the same refusal
at two different bytes would be worse than one that places none, so the table below and
the one there are the same table.
"""

from __future__ import annotations

import struct
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import FourdgsError, MalformedFile
from .serialization import MAGIC, check_magic

_RECORD_HEADER = struct.Struct("<BQ")

#: Framing bytes in front of every record's content: one opcode byte, one `u64` length.
RECORD_HEADER_SIZE = _RECORD_HEADER.size


@dataclass(frozen=True)
class Frame:
    """One record's framing: what it is, where it starts, how long its content is."""

    opcode: int
    #: Offset of the opcode byte.
    offset: int
    #: Content length, as the record declares it.
    length: int

    @property
    def total(self) -> int:
        """Framing plus content, which is what an offset has to advance by."""
        return self.length + RECORD_HEADER_SIZE

    def content(self, data: bytes) -> bytes | None:
        """The record's content, or `None` when the declared length runs past the file.

        The walk lists a record whose length overruns the end — that length is the fault —
        so every caller that means to read one has to be told the bytes are not there.
        """
        start = self.offset + RECORD_HEADER_SIZE
        end = start + self.length
        return data[start:end] if end <= len(data) else None


@dataclass(frozen=True)
class Cut:
    """Where a framing walk stopped, when it did not reach the end."""

    #: The first byte the walk could not account for.
    at: int
    reason: str
    #: True when the cut is inside a record whose framing was read — so the last record
    #: the walk reports is the incomplete one, and everything before it is intact.
    inside_a_record: bool
    #: Opcode byte of that incomplete record. ``None`` when framing itself was cut.
    record_at: int | None = None


@dataclass
class Walk:
    """The result of walking a file's framing: every record, and the cut if there was one."""

    records: list[Frame] = field(default_factory=list)
    cut: Cut | None = None
    #: True when the last eight bytes are the magic, as a whole file's are.
    trailing_magic: bool = False
    size: int = 0
    record_count: int = 0
    #: False for validation: `intact_records()` then streams framing from `data` on each
    #: pass instead of retaining one Python object per record.
    retained: bool = True
    #: The bytes this walk framed. Placing a refusal takes both the framing and the bytes
    #: it frames — which record, and then which record of that kind — and the caller here
    #: is a validator that was handed the whole file to begin with, so this is the same
    #: object rather than a copy of it.
    data: bytes = b""

    def first_intact(self, opcode: int) -> Frame | None:
        """The first *whole* record with this opcode, if the file carries one.

        Whole is the only useful sense here. The walk also reports the record a file was
        cut inside — its declared length is the fault, and hiding the record would hide
        the field that carries it — but that record's content is not in the file, so a
        caller that means to read one must not be handed it.
        """
        return next((r for r in self.intact_records() if r.opcode == opcode), None)

    def intact_records(self) -> Iterable[Frame]:
        """The records a streamed reader keeps: every one framed, less the one it was cut
        inside."""
        if self.retained:
            return self.records[: self.intact()]
        return _intact_frames(self.data)

    def intact(self) -> int:
        """How many of the reported records are whole.

        All of them, except when the file was cut inside one: that record is reported —
        hiding it would hide the declared length that is the whole fault — but it is not
        something a streamed reader keeps.
        """
        incomplete = 1 if self.cut is not None and self.cut.inside_a_record else 0
        return max(self.record_count - incomplete, 0)


def _intact_frames(data: bytes) -> Iterable[Frame]:
    """Frame complete records lazily, stopping before a cut or trailing magic."""
    at = len(MAGIC)
    size = len(data)
    while size - at > len(MAGIC):
        if size - at < RECORD_HEADER_SIZE:
            return
        opcode, length = _RECORD_HEADER.unpack_from(data, at)
        frame = Frame(opcode=opcode, offset=at, length=length)
        end = at + frame.total
        if end > size:
            return
        yield frame
        at = end


def walk(data: bytes, *, retain_records: bool = True) -> Walk:
    """Every top-level record, from framing alone.

    Reads nine bytes per record and steps over the content, so this is as cheap on a file
    carrying an hour of audio as on one carrying none. The magic is checked first, because
    a walk over bytes that are not ours would report whatever the first byte happened to
    mean as an opcode.
    """
    check_magic(data)
    out = Walk(size=len(data), data=data, retained=retain_records)
    at = len(MAGIC)
    while True:
        remaining = out.size - at
        if remaining == 0:
            break
        # A whole file ends with the magic, so its last eight bytes are not a record.
        if remaining <= len(MAGIC):
            out.trailing_magic = data[at:] == MAGIC
            if not out.trailing_magic:
                out.cut = Cut(
                    at=at,
                    reason=f"{remaining} trailing bytes are neither a record nor the magic",
                    inside_a_record=False,
                )
            break
        if remaining < RECORD_HEADER_SIZE:
            out.cut = Cut(
                at=at,
                reason=f"{remaining} bytes are too few for a record header",
                inside_a_record=False,
            )
            break
        opcode, length = _RECORD_HEADER.unpack_from(data, at)
        frame = Frame(opcode=opcode, offset=at, length=length)
        # A record is listed either way: a declared length that runs off the end is a fact
        # about that record, and hiding the record hides the field that carries the fault.
        out.record_count += 1
        if retain_records:
            out.records.append(frame)
        end = at + frame.total
        if end > out.size:
            out.cut = Cut(
                at=out.size,
                reason=(
                    f"the {op.name(opcode)} record declares {length:,} bytes, past the end of a {out.size:,}-byte file"
                ),
                inside_a_record=True,
                record_at=at,
            )
            break
        at = end
    return out


@dataclass(frozen=True)
class Site:
    """The byte a refusal fired at, and what sits there."""

    offset: int
    #: What the offset points at, in the vocabulary of `concepts.md`.
    what: str


@dataclass(frozen=True)
class Named:
    """A refusal with a name, and where it is if the tool could place it."""

    code: str
    site: Site | None = None

    def __str__(self) -> str:
        if self.site is None:
            return f"refusal {self.code}"
        return f"refusal {self.code} at byte {self.site.offset} ({self.site.what})"


def _header_refuses(content: bytes) -> bool:
    from .registry import check_temporal_model

    try:
        check_temporal_model(rec.Header.parse(content).temporal_model)
    except FourdgsError:
        return True
    return False


def _quantization_refuses(content: bytes) -> bool:
    from .registry import check_quantization_scheme

    try:
        check_quantization_scheme(rec.Quantization.parse(content).scheme)
    except FourdgsError:
        return True
    return False


#: Which record each named refusal is about, and which record *of that kind*.
#:
#: A table rather than a guess, and a short one because the refusal vocabulary the corpus
#: compares is short. A code this build has not been taught is left unplaced rather than
#: placed wrongly — an offset that points at the wrong record is worse than no offset,
#: because the reader believes it.
#:
#: The record is the one the reader **refused at**, not the first of its kind. Nothing in
#: the framing forbids a second Header or a second Quantization record, and both readers
#: check every one they meet as they meet it — so a file whose first Header is fine and
#: whose second declares a model this build does not implement is refused at the second.
#: Reporting the first would name a record that is perfectly good, with an offset its
#: reader has no reason to doubt.
_FRONT_MATTER: dict[str, tuple[int, str, Callable[[bytes], bool]]] = {
    "unknown-temporal-model": (op.HEADER, "the Header record", _header_refuses),
    "unknown-quantization-scheme": (op.QUANTIZATION, "the Quantization record", _quantization_refuses),
}

#: Refusals about the eight bytes of the magic itself, which is why neither needs a walk
#: to place: the walk that would find a record cannot start until they pass, so the offset
#: is known without one.
_AT_THE_MAGIC = frozenset({"magic-mismatch", "unsupported-major-version"})


def _front_matter_site(where: Walk | None, code: str) -> Site | None:
    if code in _AT_THE_MAGIC:
        return Site(offset=0, what="the magic")
    entry = _FRONT_MATTER.get(code)
    if entry is None or where is None:
        return None
    opcode, what, refuses = entry
    for frame in where.intact_records():
        # Whole records only, in the order the reader meets them, and only the candidates
        # are parsed — so a file carrying an hour of audio is not read to place a refusal
        # about its Header.
        if frame.opcode != opcode:
            continue
        content = frame.content(where.data)
        if content is not None and refuses(content):
            return Site(offset=frame.offset, what=what)
    # The value the reader refused is not in any record this walk can read — a file cut
    # inside the record that carries it, or a caller that passed a walk of other bytes.
    # An unplaced refusal is the honest answer; the first record of the kind would be a
    # confident one about a record that is fine.
    return None


def describe(error: FourdgsError, where: Walk | None = None, site: Site | None = None) -> Named | None:
    """Everything the tool can say about one refusal: the identifier and the byte.

    `None` for an error that carries no identifier — a truncated transport, an encoder
    bound violation. That is not a failure of this function; it is the library saying
    "this is not one of the refusals the corpus compares", and a tool that invented an
    identifier there would be inventing conformance.
    """
    code = getattr(error, "code", "")
    if not code:
        return None
    return Named(code=code, site=site if site is not None else _front_matter_site(where, code))


@dataclass(frozen=True)
class ChunkRefusal:
    """A chunk that would not decode, and the Chunk record it was fetched from."""

    error: FourdgsError
    site: Site | None


#: Every band a chunk declares. `read_chunk` caps the spherical-harmonic bands it fetches,
#: which is right for a *renderer* — coefficients do not enter reconstructed state, so a
#: consumer that will not use them should not pay for them. It is wrong for a validator: an
#: SH Band Stream is a stream like any other, and a band carrying a codec this build does
#: not implement is a file that does not decode. Capping the bands here reported it `valid`.
_EVERY_BAND = 255


def scan_chunks(data: bytes, where: Walk | None = None) -> ChunkRefusal | None:
    """The first chunk that refuses, decoded one chunk at a time.

    `None` means every chunk decoded, which is the only evidence there is that a file's
    streams are readable — the framing walk cannot produce it, because stepping over a
    chunk by its declared length is exactly not looking inside it.

    **One chunk resident at a time, on both paths.** Each decoded chunk is dropped before
    the next is read, so this costs the largest chunk rather than the scene (AGENTS.md §1).
    The question being asked is whether each chunk decodes, not what any of them decoded
    to, and a validator that answered it by assembling the whole population would need
    memory proportional to the file it was handed — on exactly the files nobody can afford
    to hold.
    """
    # Imported here rather than at module scope: the readers reach for `opcode`,
    # `records` and `serialization` as this module does, and a top-level import would
    # make the cycle depend on which of them a caller imported first.
    from .indexed_reader import open_indexed, read_chunk
    from .readable import BytesReadable

    source = BytesReadable(data)
    try:
        scene = open_indexed(source)
    except FourdgsError as exc:
        return ChunkRefusal(exc, None)

    if not scene.index:
        return scan_front_to_back(data, where if where is not None else walk(data))

    for i, entry in enumerate(scene.index):
        try:
            # The decoded chunk is dropped here, at the end of the iteration.
            read_chunk(source, scene, entry, max_sh_band=_EVERY_BAND)
        except FourdgsError as exc:
            return ChunkRefusal(exc, _refusing_record(source, scene, entry, i))
    return None


def _refusing_record(source, scene, entry, i: int) -> Site:
    """Which of a chunk's records the refusal came out of: the Chunk itself, or one band.

    A chunk is not one record. The Chunk record carries the attribute streams and each
    spherical-harmonic band sits in an SH Band Stream record of its own, somewhere else in
    the file entirely — so "the chunk did not decode" can be about a byte thousands of
    bytes from where the Chunk record starts, and pointing at the Chunk would send its
    reader to a stream that is perfectly healthy.

    `read_chunk` fetches the chunk and every band the cap admits in one call, which is
    what a reader wants. Raising the cap until it starts failing is therefore how to tell
    the two apart without restating the library's fetch here and drifting from it. It
    costs a second decode of one chunk, and it only ever runs on a file that has already
    refused.
    """
    from .indexed_reader import read_chunk

    chunk = Site(entry.chunk_offset, f"the Chunk record at index entry {i}")
    try:
        read_chunk(source, scene, entry, max_sh_band=0)
    except FourdgsError:
        return chunk
    for band, at, _length in sorted(entry.bands):
        # The cap admits every band up to `band`, and everything below it has already
        # decoded, so the first cap that fails names the band that failed.
        try:
            read_chunk(source, scene, entry, max_sh_band=band)
        except FourdgsError:
            return Site(at, f"the SH Band Stream for band {band} of the Chunk at index entry {i}")
    return chunk


def scan_front_to_back(data: bytes, where: Walk) -> ChunkRefusal | None:
    """The same scan for a file with no index, which has no per-chunk addressing to seek with.

    Front to back over the framing the walk already produced, decoding each Chunk and each
    SH Band Stream on its own and keeping neither. The library's streamed reader assembles
    the scene as it goes — which is what a *reader* wants and what a validator must not do
    — so this drives the same decode primitives directly and throws each result away.

    Being framing-driven, it also places the refusal: an unindexed file used to report the
    identifier with no byte at all, because "every chunk or none" was the only answer a
    whole-file decode could give.
    """
    from .quantization import DEFAULT_CUTOFF
    from .serialization import Cursor, decode_stream
    from .stream_reader import check_sh_codes, chunk_stream_bytes, decode_streams, steps_from

    quant: rec.Quantization | None = None
    windows: list[tuple[float, float]] = []
    cutoff = DEFAULT_CUTOFF
    declared_degree: int | None = None
    band_owner_count: int | None = None
    band_owner_at: int | None = None
    bands: list[int] = []

    def finish_bands() -> ChunkRefusal | None:
        nonlocal band_owner_count, band_owner_at, bands
        if band_owner_at is None:
            return None
        if declared_degree is not None:
            wanted = list(range(1, declared_degree + 1))
            if bands != wanted:
                return ChunkRefusal(
                    MalformedFile(
                        f"the Chunk at {band_owner_at} is followed by SH bands {bands}; "
                        f"the Header declares degree {declared_degree}, requiring bands {wanted}",
                        code="index-record-mismatch",
                    ),
                    Site(band_owner_at, f"the Chunk record at byte {band_owner_at}"),
                )
        band_owner_count = None
        band_owner_at = None
        bands = []
        return None

    for frame in where.intact_records():
        content = frame.content(where.data)
        if content is None:
            continue
        if frame.opcode != op.SH_BAND_STREAM:
            unfinished = finish_bands()
            if unfinished is not None:
                return unfinished
        here = Site(frame.offset, f"the {op.name(frame.opcode)} record")
        try:
            if frame.opcode == op.HEADER:
                # Taken as met, and not required to parse: a record whose body is broken
                # is a finding the validator has already made, and stopping here would
                # replace it with a worse one.
                header = rec.Header.parse(content)
                cutoff = header.cutoff
                declared_degree = int(header.sh_degree)
            elif frame.opcode == op.QUANTIZATION:
                quant = rec.Quantization.parse(content)
            elif frame.opcode == op.WINDOW_TABLE:
                windows = rec.WindowTable.parse(content).windows
        except FourdgsError:
            continue
        if frame.opcode == op.CHUNK:
            # A Chunk before the grid it is quantized against is a fault the validator
            # reports itself; there is nothing to decode it with here.
            try:
                head, streams = rec.parse_chunk(content)
                band_owner_count = int(head.count)
                band_owner_at = frame.offset
                bands = []
                if quant is None:
                    continue
                # The decoded chunk is dropped when this iteration ends.
                decode_streams(
                    chunk_stream_bytes(head, streams),
                    head.count,
                    steps_from(quant),
                    np.asarray(quant.pos_origin),
                    windows,
                    cutoff,
                )
            except FourdgsError as exc:
                return ChunkRefusal(exc, here)
        elif frame.opcode == op.SH_BAND_STREAM:
            try:
                cursor = Cursor(bytes(content))
                # The band index, which the record carries and the stream header does not:
                # a band stream's `attribute_id` is 0x07 and collides with `mu_t` (§5.7).
                band = cursor.u8()
                attribute, values = decode_stream(cursor)
                if attribute != op.SH_BAND_STREAM:
                    raise MalformedFile(
                        f"the SH Band Stream at {frame.offset} declares inner attribute_id "
                        f"{attribute}; version 1 fixes it at {op.SH_BAND_STREAM}",
                        code="index-record-mismatch",
                    )
                if band_owner_count is None:
                    raise MalformedFile(
                        f"the SH Band Stream at {frame.offset} does not immediately follow a Chunk",
                        code="index-record-mismatch",
                    )
                expected_shape = (band_owner_count, 3 * (2 * band + 1))
                if values.shape != expected_shape:
                    raise MalformedFile(
                        f"the SH Band Stream at {frame.offset} for band {band} decodes to "
                        f"shape {values.shape}; its owning Chunk requires {expected_shape}",
                        code="stream-element-count-mismatch",
                    )
                check_sh_codes(values, f"the SH Band Stream at {frame.offset}")
                bands.append(band)
            except FourdgsError as exc:
                return ChunkRefusal(exc, here)
    return finish_bands()
