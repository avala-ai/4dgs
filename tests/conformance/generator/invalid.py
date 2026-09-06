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
* **Every rule here belongs to version 1.** The harness began with rules that predated it.
  Later witnesses may follow a normative clarification, but they isolate one cited rule;
  the generator does not introduce a new format revision.

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
import zlib
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


def _step_time_offset(data: bytes) -> int:
    """Locate Quantization.step_time without assuming the scheme's byte length."""
    offset, _ = _find(data, 0x03)
    (scheme_length,) = struct.unpack_from("<I", data, offset)
    steps = offset + 4 + scheme_length + 3 * 8
    return steps + 6 * 8


def _step_time(data: bytes, value: float) -> bytes:
    return _patch(data, _step_time_offset(data), struct.pack("<d", value))


def _zero_step_time(data: bytes) -> bytes:
    return _step_time(data, 0.0)


def _negative_step_time(data: bytes) -> bytes:
    return _step_time(data, -0.004)


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


def _delta_index_count_offsets(data: bytes) -> tuple[int, int, int]:
    """Return `(chunk_offset, gaussian_count byte, live_count byte)` for the first delta entry."""
    for opcode, content, length in _records(data):
        if opcode != 0x08:  # Chunk Index
            continue
        assert length >= 40, "the Chunk Index entry is shorter than its fixed prefix"
        (chunk_offset,) = struct.unpack_from("<Q", data, content + 16)
        (band_count,) = struct.unpack_from("<I", data, content + 36)
        appended = content + 40 + band_count * 17  # u8 band, u64 offset, u64 length
        end = content + length
        if appended == end:  # gaussian-birth: no keyframe-delta block and no live_count
            continue
        assert end - appended >= 28, "the keyframe-delta index block is truncated"
        if data[appended] == 1:  # chunk_kind: Delta Chunk
            return chunk_offset, content + 32, appended + 20
    raise AssertionError("the base file carries no delta Chunk Index entry")


def _summary_crc_fields(data: bytes) -> tuple[int, int, int, int]:
    """Return `(crc byte, summary start, footer start, declared crc)` from the Footer."""
    footer_content, length = _find(data, 0x02)
    assert length >= 20, "the Footer is shorter than its version-1 fields"
    summary_start, _summary_offset_start, declared = struct.unpack_from("<QQI", data, footer_content)
    footer_start = footer_content - _RECORD_HEADER.size
    assert 0 < summary_start <= footer_start, "the base file carries no contiguous summary"
    return footer_content + 16, summary_start, footer_start, declared


def _wrong_index_count(data: bytes, field: str) -> bytes:
    """Increment one delta index count and repair the checksum that covers the summary."""
    _chunk, gaussian_count, live_count = _delta_index_count_offsets(data)
    crc_offset, summary_start, footer_start, declared_crc = _summary_crc_fields(data)
    actual_crc = zlib.crc32(data[summary_start:footer_start]) & 0xFFFFFFFF
    assert declared_crc != 0 and declared_crc == actual_crc, "the witness base must have a valid summary CRC"

    if field == "gaussian_count":
        offset, encoding, limit = gaussian_count, "<I", 0xFFFFFFFF
    elif field == "live_count":
        offset, encoding, limit = live_count, "<Q", 0xFFFFFFFFFFFFFFFF
    else:  # pragma: no cover - private callers pass one of the two wire fields above
        raise AssertionError(f"unknown Chunk Index count {field!r}")
    (value,) = struct.unpack_from(encoding, data, offset)
    assert value < limit, f"the base {field} leaves no value to mutate to"

    mutated = _patch(data, offset, struct.pack(encoding, value + 1))
    repaired_crc = zlib.crc32(mutated[summary_start:footer_start]) & 0xFFFFFFFF
    return _patch(mutated, crc_offset, struct.pack("<I", repaired_crc))


def _wrong_index_gaussian_count(data: bytes) -> bytes:
    return _wrong_index_count(data, "gaussian_count")


def _wrong_index_live_count(data: bytes) -> bytes:
    return _wrong_index_count(data, "live_count")


#: The two witnesses for spec issue #306. Both are length-preserving patches of the
#: Quantization record's birth-time grid, so no later offset or checksum-covered range moves.
STEP_TIME_REFUSALS: tuple[Refusal, ...] = (
    Refusal("ZeroStepTime", "non-positive-step-time", "spec 5.3, 6.3", _zero_step_time),
    Refusal("NegativeStepTime", "non-positive-step-time", "spec 5.3, 6.3", _negative_step_time),
)


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
    *STEP_TIME_REFUSALS,
)

#: The two witnesses for spec issue #195. They are cut from the churn sequence because
#: its first delta has two operations over a four-gaussian live population, making the
#: fields' distinct meanings observable. Each patch changes one count and recomputes the
#: summary CRC, so checksum failure cannot mask the index-record disagreement. They join
#: `build_invalid()` only after every SDK layer can name them: the invalid corpus contract
#: remains all-or-none, while these need a keyframe-delta base rather than `BASE_SCENARIO`.
INDEX_COUNT_BASE = "KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics"
INDEX_COUNT_REFUSALS: tuple[Refusal, ...] = (
    Refusal("WrongIndexGaussianCount", "index-record-mismatch", "spec 5.8", _wrong_index_gaussian_count),
    Refusal("WrongIndexLiveCount", "index-record-mismatch", "spec 5.8", _wrong_index_live_count),
)

#: Invalid variants the encoder writes directly rather than a mutation producing.
#:
#: A byte patch cannot make this one: shortening a length-prefixed string moves every
#: Header field after it, so the file would be wrong in two ways and a reader could pass
#: by noticing the alignment rather than the rule. `WriteOptions.temporal_model` lets the
#: encoder lay the record out correctly around the value under test.
#:
#: The empty string is worth its own case rather than folding into `UnknownTemporalModel`:
#: it is what a struct initialized to its zero value produces, so it is the shape a *bug*
#: writes rather than the shape a future version writes. Two of these SDKs disagreed about
#: exactly this — one defaulted the field to `gaussian-birth`, the other left it blank —
#: and nothing inside either language could see it.
ENCODED: tuple[tuple[str, str, str, dict], ...] = (
    (
        "EmptyTemporalModel",
        "unknown-temporal-model",
        "registry, temporal models",
        {"temporal_model": ""},
    ),
)

#: Every identifier the suite knows. A runner may produce no other, and a new refusal is
#: added here rather than invented in one language. The staged index-count identifier is
#: already vocabulary even though its two corpus files activate only after the SDK stack.
CODES = frozenset(r.code for r in (*REFUSALS, *INDEX_COUNT_REFUSALS)) | {code for _, code, _, _ in ENCODED}
