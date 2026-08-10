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

Front matter is located from framing alone. A refusal that lives inside a chunk's streams
is located by decoding chunks one at a time until one of them refuses, which is also the
only way to *find* those refusals at all — the framing walk steps over a chunk by its
declared length and never looks inside it, which is why the framing-only validator called
two of the invalid corpus's seven files clean.

This module is `rust/cli/src/refusal.rs` in Python. Two tools that place the same refusal
at two different bytes would be worse than one that places none, so the table below and
the one there are the same table.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

from . import opcode as op
from .exceptions import FourdgsError
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


@dataclass(frozen=True)
class Cut:
    """Where a framing walk stopped, when it did not reach the end."""

    #: The first byte the walk could not account for.
    at: int
    reason: str
    #: True when the cut is inside a record whose framing was read — so the last record
    #: the walk reports is the incomplete one, and everything before it is intact.
    inside_a_record: bool


@dataclass
class Walk:
    """The result of walking a file's framing: every record, and the cut if there was one."""

    records: list[Frame] = field(default_factory=list)
    cut: Cut | None = None
    #: True when the last eight bytes are the magic, as a whole file's are.
    trailing_magic: bool = False
    size: int = 0

    def first(self, opcode: int) -> Frame | None:
        """The first record with this opcode, if the file carries one."""
        return next((r for r in self.records if r.opcode == opcode), None)

    def intact(self) -> int:
        """How many of the reported records are whole.

        All of them, except when the file was cut inside one: that record is reported —
        hiding it would hide the declared length that is the whole fault — but it is not
        something a streamed reader keeps.
        """
        incomplete = 1 if self.cut is not None and self.cut.inside_a_record else 0
        return max(len(self.records) - incomplete, 0)


def walk(data: bytes) -> Walk:
    """Every top-level record, from framing alone.

    Reads nine bytes per record and steps over the content, so this is as cheap on a file
    carrying an hour of audio as on one carrying none. The magic is checked first, because
    a walk over bytes that are not ours would report whatever the first byte happened to
    mean as an opcode.
    """
    check_magic(data)
    out = Walk(size=len(data))
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
        out.records.append(frame)
        end = at + frame.total
        if end > out.size:
            out.cut = Cut(
                at=at,
                reason=(
                    f"the {op.name(opcode)} record declares {length:,} bytes, past the end of a {out.size:,}-byte file"
                ),
                inside_a_record=True,
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


#: Which record each named refusal is about.
#:
#: A table rather than a guess, and a short one because the refusal vocabulary the corpus
#: compares is short. A code this build has not been taught is left unplaced rather than
#: placed wrongly — an offset that points at the wrong record is worse than no offset,
#: because the reader believes it.
_FRONT_MATTER: dict[str, tuple[int, str]] = {
    "unknown-temporal-model": (op.HEADER, "the Header record"),
    "unknown-quantization-scheme": (op.QUANTIZATION, "the Quantization record"),
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
    opcode, what = entry
    frame = where.first(opcode)
    return None if frame is None else Site(offset=frame.offset, what=what)


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


def scan_chunks(data: bytes) -> ChunkRefusal | None:
    """The first chunk that refuses, decoded one chunk at a time.

    `None` means every chunk decoded, which is the only evidence there is that a file's
    streams are readable — the framing walk cannot produce it, because stepping over a
    chunk by its declared length is exactly not looking inside it.

    One chunk resident at a time on the indexed path, which is what keeps this bounded on
    a file too large to hold (AGENTS.md §1): each decoded chunk is dropped before the next
    is fetched. A file with no index has no per-chunk addressing to use, so it is decoded
    front to back and the refusal comes back without an offset rather than with a guessed
    one.
    """
    # Imported here rather than at module scope: the readers reach for `opcode`,
    # `records` and `serialization` as this module does, and a top-level import would
    # make the cycle depend on which of them a caller imported first.
    from .indexed_reader import open_indexed, read_chunk
    from .readable import BytesReadable
    from .stream_reader import read

    source = BytesReadable(data)
    try:
        scene = open_indexed(source)
    except FourdgsError as exc:
        return ChunkRefusal(exc, None)

    if not scene.index:
        # Front to back: every chunk or none, and no per-chunk offset to attribute to.
        # Band 0 throughout — spherical harmonics do not enter reconstructed state, so
        # fetching them would only move bytes nobody is checking.
        try:
            read(data, max_sh_band=0)
        except FourdgsError as exc:
            return ChunkRefusal(exc, None)
        return None

    for i, entry in enumerate(scene.index):
        try:
            read_chunk(source, scene, entry)
        except FourdgsError as exc:
            return ChunkRefusal(exc, Site(entry.chunk_offset, f"the Chunk record at index entry {i}"))
    return None
