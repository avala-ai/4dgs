# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The invalid corpus: files a conforming reader must refuse, and what it must say.

Every other fixture in this suite is a valid file, and a valid corpus can only ever prove
that a decoder accepts what it should. It cannot prove that a decoder *refuses* what it
should, and the specification is full of rules whose whole content is a refusal — an
out-of-range window index, an unimplemented codec, a temporal model this reader does not
know. A decoder that ignores every one of those passes all 34 valid variants.

So this file declares the other half of the contract. Each entry is a **mutation** of a
valid base file, chosen so that exactly one rule is broken, paired with the **refusal
identifier** a reader must produce.

Two properties are deliberate:

* **The identifier, not the exception type.** "Both decoders raised an error" is not
  agreement — one of them may have refused for the wrong reason, and a negative test that
  cannot tell those apart is the kind that passes while proving nothing. The id says
  which rule.
* **Every rule here already exists in version 1.** Nothing in this file is new
  specification. That is what makes the harness change reviewable on its own: the
  contract is exercised against rules that predate it, rather than arriving at the same
  time as the rules it is meant to police.

The mutations are byte patches rather than a second encoder, and each is length-preserving
wherever it can be, so nothing downstream of the patch shifts. A mutation that moved
offsets would produce a file that is broken in two ways, and a reader could then pass by
noticing the wrong one.

**Truncation is not here.** A cut file is recoverable, not refusable — the implementation
notes are explicit that a reader should salvage the intact prefix — so it stays where it
is, checked by each runner against the valid corpus.
"""

from __future__ import annotations

import struct
from collections.abc import Callable
from dataclasses import dataclass

#: The scenario the invalid corpus is cut from. `TenWindows` because two of the mutations
#: need a scene with more than one validity window, and one file that serves every case
#: keeps the invalid corpus to a handful of kilobytes.
BASE_SCENARIO = "TenWindows"
BASE_FLAGS = ("UseChunkIndex", "UseCrc")


@dataclass(frozen=True)
class Refusal:
    """One invalid file: how to build it, and what a reader must say about it."""

    #: File stem, and the name the harness reports.
    name: str
    #: The refusal identifier a conforming reader must produce.
    code: str
    #: Which rule the file breaks, by specification section. Recorded so that a reader
    #: author can find the rule from the failure rather than from this file.
    rule: str
    #: bytes -> bytes. Must break exactly one rule.
    mutate: Callable[[bytes], bytes]


# --------------------------------------------------------------------------
# Locating a field to patch
#
# The patches that reach past the front matter find their target by walking records the
# way any reader does, rather than by a byte offset written down here. An offset in a
# comment is correct until the encoder changes and wrong silently afterwards.
# --------------------------------------------------------------------------

_RECORD_HEADER = struct.Struct("<BQ")
_MAGIC_LEN = 8


def _records(data: bytes):
    """Yield `(opcode, content_offset, content_length)` for every top-level record."""
    pos = _MAGIC_LEN
    while pos + _RECORD_HEADER.size <= len(data):
        opcode, length = _RECORD_HEADER.unpack_from(data, pos)
        content = pos + _RECORD_HEADER.size
        if content + length > len(data):
            return
        yield opcode, content, length
        pos = content + length


def _find(data: bytes, opcode: int) -> tuple[int, int]:
    for op, offset, length in _records(data):
        if op == opcode:
            return offset, length
    raise AssertionError(f"the base file carries no record with opcode 0x{opcode:02X}")


def _patch(data: bytes, offset: int, new: bytes) -> bytes:
    return data[:offset] + new + data[offset + len(new) :]


def _replace_once(data: bytes, old: bytes, new: bytes) -> bytes:
    """Replace a byte string that must occur exactly once, with one of equal length.

    Equal length is what keeps every later offset — the chunk index, the footer's
    `summary_start` — valid, so the file is wrong in exactly the one way intended.
    """
    assert len(old) == len(new), f"{old!r} and {new!r} differ in length"
    count = data.count(old)
    assert count == 1, f"{old!r} occurs {count} times in the base file, expected once"
    return data.replace(old, new)


# --------------------------------------------------------------------------
# The mutations
# --------------------------------------------------------------------------


def _bad_magic(data: bytes) -> bytes:
    # The high bit that keeps byte-oriented tooling from taking the file for text.
    return _patch(data, 0, b"\x88")


def _future_major_version(data: bytes) -> bytes:
    # `4DGS` intact, version byte '2'. The reader must say "version", not "not a 4dgs
    # file": the fix is a newer reader, and an error that blames the file sends its
    # holder looking for corruption that is not there.
    return _patch(data, 5, b"2")


def _unknown_temporal_model(data: bytes) -> bytes:
    # A name the registry reserves and no reader implements. Fourteen bytes either way,
    # so the Header's length and every offset after it stand.
    return _replace_once(data, b"gaussian-birth", b"frame-sequence")


def _unknown_quantization_scheme(data: bytes) -> bytes:
    return _replace_once(data, b"uniform-v1", b"uniform-v9")


def _window_index_out_of_range(data: bytes) -> bytes:
    """Shrink the Window Table's `count` so the gaussians reference past its end.

    The record keeps its length, so the entries are still there — the table simply
    declares fewer of them than the gaussians use. A reader that clamps an out-of-range
    index substitutes one gaussian's lifetime for another's and produces a scene, which
    is why the specification makes this a refusal rather than a repair.
    """
    offset, _ = _find(data, 0x04)
    return _patch(data, offset, struct.pack("<I", 1))


def _unknown_stream_codec(data: bytes) -> bytes:
    """Point an attribute stream's codec byte at a reserved value.

    The file is otherwise intact: a reader that ignores the field decodes the payload as
    though it were deflate, which fails as a corrupt stream rather than as an
    unimplemented codec — a different diagnosis, and the wrong one. The registry reserves
    4-127, so 9 is legal-but-unimplemented rather than nonsense.
    """
    offset, _ = _find(data, 0x05)
    cursor = offset + 8 + 8 + 4 + 4  # t0, t1, level, count
    (compression_len,) = struct.unpack_from("<I", data, cursor)
    cursor += 4 + compression_len + 8 + 8  # compression, uncompressed_size, records length
    return _patch(data, cursor + 3, b"\x09")  # attribute_id, symbol_width, mode, [codec]


REFUSALS: tuple[Refusal, ...] = (
    Refusal("BadMagic", "magic-mismatch", "spec 4.1", _bad_magic),
    Refusal("FutureMajorVersion", "unsupported-major-version", "spec 4.1", _future_major_version),
    Refusal("UnknownTemporalModel", "unknown-temporal-model", "registry, temporal models", _unknown_temporal_model),
    Refusal(
        "UnknownQuantizationScheme",
        "unknown-quantization-scheme",
        "registry, quantization schemes",
        _unknown_quantization_scheme,
    ),
    Refusal("WindowIndexOutOfRange", "window-index-out-of-range", "spec 5.4", _window_index_out_of_range),
    Refusal("UnknownStreamCodec", "unknown-stream-codec", "spec 5.5, registry stream codecs", _unknown_stream_codec),
)

#: Every identifier the suite knows. A runner may produce no other, and a new refusal is
#: added here rather than invented in one language.
CODES = frozenset(r.code for r in REFUSALS)
