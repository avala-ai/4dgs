# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Primitives: the magic, record framing, and attribute-stream coding.

Everything on the wire goes through this module, so a reader only has to trust one
implementation of "read a length-prefixed thing without walking off the end".

The framing rule the format depends on is enforced here rather than remembered by
callers: every record carries its own length, so an unknown opcode is skipped by
arithmetic instead of by guesswork, and a record that has grown fields a reader does not
know about is still exactly as long as it says it is.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

import numpy as np

from .exceptions import MalformedFile, TruncatedFile, UnsupportedCodec, UnsupportedVersion

#: `0x89 4 D G S 1 CR LF`. The high bit stops byte-oriented tooling treating the file as
#: text; the `1` is the major version; the CR LF catches transports that mangle line
#: endings, which is a real failure mode for binary payloads served as text.
MAGIC = b"\x894DGS1\r\n"
VERSION = 1

_RECORD_HEADER = struct.Struct("<BQ")
_STREAM_HEADER = struct.Struct("<BBBBBIQ")

MODE_RAW = 0
MODE_DELTA = 1
MODE_CONST = 2

CODEC_DEFLATE = 0
CODEC_ZSTD = 1
CODEC_NAMES = {CODEC_DEFLATE: "deflate", CODEC_ZSTD: "zstd"}

#: A crafted length must not be able to make a reader allocate before it has been
#: checked against the resource. Streams above this are refused outright.
MAX_STREAM_BYTES = 512 * 1024 * 1024


# --------------------------------------------------------------------------
# Scalars
# --------------------------------------------------------------------------


class Cursor:
    """A bounds-checked read head over a byte buffer."""

    __slots__ = ("buf", "pos")

    def __init__(self, buf: bytes | memoryview, pos: int = 0) -> None:
        self.buf = memoryview(buf)
        self.pos = pos

    def remaining(self) -> int:
        return len(self.buf) - self.pos

    def take(self, n: int) -> memoryview:
        if n < 0 or self.pos + n > len(self.buf):
            raise TruncatedFile(f"need {n} bytes at offset {self.pos}, {self.remaining()} remain")
        out = self.buf[self.pos : self.pos + n]
        self.pos += n
        return out

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return int(struct.unpack_from("<H", self.take(2))[0])

    def u32(self) -> int:
        return int(struct.unpack_from("<I", self.take(4))[0])

    def u64(self) -> int:
        return int(struct.unpack_from("<Q", self.take(8))[0])

    def f64(self) -> float:
        return float(struct.unpack_from("<d", self.take(8))[0])

    def f32s(self, n: int) -> list[float]:
        return [float(v) for v in struct.unpack_from(f"<{n}f", self.take(4 * n))]

    def f64s(self, n: int) -> list[float]:
        return [float(v) for v in struct.unpack_from(f"<{n}d", self.take(8 * n))]

    def string(self) -> str:
        """`u32` byte length then that many UTF-8 bytes. Not NUL-terminated.

        The offset reported on failure is where the bytes start, and the exception
        names the byte inside them that failed: a reader that refuses a record says
        which byte is wrong, and pointing at the length prefix — which decoded fine —
        sends whoever is holding the file to the wrong place in it.
        """
        length = self.u32()
        at = self.pos
        raw = bytes(self.take(length))
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise MalformedFile(
                f"string at offset {at} is not valid UTF-8: byte {at + exc.start} is {raw[exc.start]:#04x}"
            ) from exc

    def blob(self) -> bytes:
        return bytes(self.take(self.u64()))

    def str_map(self) -> dict[str, str]:
        block = Cursor(self.take(self.u32()))
        out: dict[str, str] = {}
        while block.remaining():
            key = block.string()
            out[key] = block.string()
        return out


def put_u8(v: int) -> bytes:
    return struct.pack("<B", v)


def put_u16(v: int) -> bytes:
    return struct.pack("<H", v)


def put_u32(v: int) -> bytes:
    return struct.pack("<I", v)


def put_u64(v: int) -> bytes:
    return struct.pack("<Q", v)


def put_f64(v: float) -> bytes:
    return struct.pack("<d", v)


def put_f32s(vs) -> bytes:
    vs = list(vs)
    return struct.pack(f"<{len(vs)}f", *vs)


def put_f64s(vs) -> bytes:
    vs = list(vs)
    return struct.pack(f"<{len(vs)}d", *vs)


def put_string(s: str) -> bytes:
    raw = s.encode("utf-8")
    return put_u32(len(raw)) + raw


def put_blob(b: bytes) -> bytes:
    return put_u64(len(b)) + b


def put_str_map(m: dict[str, str]) -> bytes:
    body = b"".join(put_string(k) + put_string(v) for k, v in sorted(m.items()))
    return put_u32(len(body)) + body


# --------------------------------------------------------------------------
# Record framing
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class RawRecord:
    opcode: int
    content: memoryview
    #: Offset of the record's opcode byte within the enclosing buffer.
    offset: int


def put_record(opcode: int, content: bytes) -> bytes:
    return _RECORD_HEADER.pack(opcode, len(content)) + content


def read_record(cursor: Cursor) -> RawRecord:
    offset = cursor.pos
    head = cursor.take(_RECORD_HEADER.size)
    opcode, length = _RECORD_HEADER.unpack_from(head)
    return RawRecord(opcode=opcode, content=cursor.take(length), offset=offset)


def iter_records(buf: bytes | memoryview, pos: int = 0):
    """Yield every record in `buf`, skipping nothing and interpreting nothing.

    A caller that does not recognize an opcode simply ignores the record — that is the
    whole forward-compatibility story, and it works because this loop never needs to know
    what a record means to know how long it is.
    """
    cursor = Cursor(buf, pos)
    while cursor.remaining() >= _RECORD_HEADER.size:
        yield read_record(cursor)


def check_magic(head: bytes) -> None:
    if len(head) < len(MAGIC):
        raise TruncatedFile("file is shorter than the magic")
    if head[: len(MAGIC)] != MAGIC:
        # Two different failures, and the fix differs: a newer reader, or a different
        # file. They are told apart by whether the version byte is the ONLY difference —
        # every other byte of the magic is a fixed sentinel, so a file that differs
        # elsewhere is not a 4dgs file whatever its version byte happens to say.
        # Testing only `head[1:5] == b"4DGS"` reported a corrupt first byte as an
        # unsupported version 1, which sends its holder looking for a newer reader that
        # would not have helped.
        VERSION_AT = 5
        before = head[:VERSION_AT] != MAGIC[:VERSION_AT]
        after = head[VERSION_AT + 1 : len(MAGIC)] != MAGIC[VERSION_AT + 1 :]
        elsewhere = before or after
        if not elsewhere:
            raise UnsupportedVersion(
                f"4dgs major version {head[VERSION_AT : VERSION_AT + 1]!r} is not supported by this reader",
                code="unsupported-major-version",
            )
        raise UnsupportedVersion("not a 4dgs file (bad magic)", code="magic-mismatch")


# --------------------------------------------------------------------------
# Attribute streams
# --------------------------------------------------------------------------


def zigzag(a: np.ndarray) -> np.ndarray:
    a = a.astype(np.int64, copy=False)
    return ((a << 1) ^ (a >> 63)).astype(np.uint64)


def unzigzag(a: np.ndarray) -> np.ndarray:
    a = a.astype(np.uint64, copy=False)
    return (a >> np.uint64(1)).astype(np.int64) ^ -(a & np.uint64(1)).astype(np.int64)


def _width_for(u: np.ndarray) -> int:
    m = int(u.max()) if u.size else 0
    if m <= 0xFF:
        return 1
    if m <= 0xFFFF:
        return 2
    if m <= 0xFFFFFFFF:
        return 4
    raise ValueError(f"symbol {m} exceeds 32 bits; the error bound is too tight for this data")


def _shuffle(buf: np.ndarray, width: int) -> bytes:
    """Byte-plane shuffle: all least-significant bytes, then the next plane, ...

    Groups the near-constant high bytes together, which is most of what makes a general
    purpose codec effective on quantized attributes.
    """
    if width == 1:
        return buf.tobytes()
    return np.ascontiguousarray(buf.view(np.uint8).reshape(-1, width).T).tobytes()


def _unshuffle(raw: bytes, width: int, symbols: int) -> np.ndarray:
    if width == 1:
        return np.frombuffer(raw, dtype=np.uint8, count=symbols)
    planes = np.frombuffer(raw, dtype=np.uint8, count=symbols * width).reshape(width, symbols)
    return np.ascontiguousarray(planes.T).view({2: "<u2", 4: "<u4"}[width]).reshape(symbols)


def compress(raw: bytes, codec: int, level: int) -> bytes:
    if codec == CODEC_DEFLATE:
        return zlib.compress(raw, min(level, 9))
    if codec == CODEC_ZSTD:
        try:
            import zstandard
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise UnsupportedCodec("zstd support needs the 'zstd' extra: pip install 'fourdgs[zstd]'") from exc
        params = zstandard.ZstdCompressionParameters.from_level(level, window_log=23, source_size=len(raw))
        return zstandard.ZstdCompressor(compression_params=params).compress(raw)
    raise UnsupportedCodec(f"unknown stream codec {codec}", code="unknown-stream-codec")


def decompress(body: bytes, codec: int, expected: int) -> bytes:
    """Undo one stream's compression, refusing a payload that is not what it claims.

    A codec library's own exception type is not this library's, and a caller decoding an
    untrusted file should not have to catch `zlib.error` to find out that the file was
    corrupt. Every failure in here comes back as a `MalformedFile`.
    """
    if expected > MAX_STREAM_BYTES:
        raise MalformedFile(f"compressed block declares {expected} bytes, past the {MAX_STREAM_BYTES} cap")
    if codec == CODEC_DEFLATE:
        try:
            decoder = zlib.decompressobj()
            # `zlib.decompress(..., bufsize=...)` treats bufsize only as a growth hint. A
            # small payload can therefore expand without limit before the length check
            # below runs. Asking for one byte beyond the declaration both caps allocation
            # and distinguishes an over-producing stream from one of exactly that size.
            out = decoder.decompress(body, expected + 1)
        except zlib.error as exc:
            raise MalformedFile(f"deflate stream is corrupt: {exc}") from exc
        if len(out) > expected or decoder.unconsumed_tail:
            raise TruncatedFile(f"stream decompresses past the {expected} bytes declared by its header")
        if not decoder.eof:
            raise TruncatedFile("deflate stream ends before its end marker")
    elif codec == CODEC_ZSTD:
        try:
            import zstandard
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise UnsupportedCodec("this file uses zstd streams: pip install 'fourdgs[zstd]'") from exc
        try:
            out = zstandard.ZstdDecompressor().decompress(body, max_output_size=expected)
        except zstandard.ZstdError as exc:
            raise MalformedFile(f"zstd stream is corrupt: {exc}") from exc
    else:
        raise UnsupportedCodec(f"unknown stream codec {codec}", code="unknown-stream-codec")
    if len(out) != expected:
        raise TruncatedFile(f"stream decompressed to {len(out)} bytes, header declared {expected}")
    return out


def encode_stream(
    attribute_id: int,
    values: np.ndarray,
    *,
    channels: int = 1,
    codec: int = CODEC_DEFLATE,
    level: int = 6,
    allow_delta: bool = True,
) -> bytes:
    """Serialize signed integer bins as one attribute stream.

    Raw and delta coding are both tried and the smaller kept, with the choice recorded in
    the header — a decoder never has to infer which one was used.
    """
    v = np.asarray(values, dtype=np.int64)
    if v.ndim == 1:
        v = v[:, None]
    n, ch = v.shape
    if ch != channels:
        raise ValueError(f"channels mismatch: array has {ch}, caller said {channels}")

    if n == 0:
        return _STREAM_HEADER.pack(attribute_id, 1, MODE_RAW, codec, channels, 0, 0)

    if n > 1 and np.array_equal(v, np.repeat(v[:1], n, axis=0)):
        z = zigzag(v[0])
        width = _width_for(z)
        body = compress(_shuffle(z.astype({1: np.uint8, 2: np.uint16, 4: np.uint32}[width]), width), codec, level)
        return _STREAM_HEADER.pack(attribute_id, width, MODE_CONST, codec, channels, n, len(body)) + body

    candidates = [(MODE_RAW, v)]
    if allow_delta and n > 1:
        d = v.copy()
        d[1:] = v[1:] - v[:-1]
        candidates.append((MODE_DELTA, d))

    best: tuple[int, int, bytes] | None = None
    for mode, arr in candidates:
        z = zigzag(arr.reshape(-1))
        width = _width_for(z)
        body = compress(_shuffle(z.astype({1: np.uint8, 2: np.uint16, 4: np.uint32}[width]), width), codec, level)
        if best is None or len(body) < len(best[2]):
            best = (mode, width, body)
    assert best is not None
    mode, width, body = best
    return _STREAM_HEADER.pack(attribute_id, width, mode, codec, channels, n, len(body)) + body


def decode_stream(cursor: Cursor) -> tuple[int, np.ndarray]:
    """Read one attribute stream, returning `(attribute_id, (n, channels) int64)`."""
    head = cursor.take(_STREAM_HEADER.size)
    attribute_id, width, mode, codec, channels, count, payload_len = _STREAM_HEADER.unpack_from(head)
    if count == 0:
        cursor.take(payload_len)
        return attribute_id, np.zeros((0, channels), dtype=np.int64)
    if width not in (1, 2, 4):
        raise MalformedFile(f"attribute {attribute_id}: bad symbol width {width}")
    if channels == 0:
        raise MalformedFile(f"attribute {attribute_id}: zero channels")

    symbols = channels if mode == MODE_CONST else count * channels
    expected = symbols * width
    if expected > MAX_STREAM_BYTES:
        raise MalformedFile(f"attribute {attribute_id} declares {expected} bytes, past the {MAX_STREAM_BYTES} cap")

    # The cap above bounds what arrives; this one bounds what it becomes. A constant
    # stream stores `channels` symbols and repeats them `count` times, so a header
    # declaring 2^30 elements expands a one-byte payload into gigabytes — and a raw
    # stream of one-byte symbols still expands eightfold into int64. Neither is caught by
    # a cap on the payload, and both are a few bytes of input away from any file.
    produced = count * channels * 8
    if produced > MAX_STREAM_BYTES:
        raise MalformedFile(
            f"attribute {attribute_id} declares {count} elements x {channels} channels, "
            f"which would decode to {produced} bytes, past the {MAX_STREAM_BYTES} cap"
        )

    raw = decompress(bytes(cursor.take(payload_len)), codec, expected)
    sym = _unshuffle(raw, width, symbols)

    if mode == MODE_CONST:
        return attribute_id, np.repeat(unzigzag(sym).reshape(1, channels), count, axis=0)
    vals = unzigzag(sym).reshape(count, channels)
    if mode == MODE_DELTA:
        vals = np.cumsum(vals, axis=0, dtype=np.int64)
    elif mode != MODE_RAW:
        raise TruncatedFile(f"attribute {attribute_id}: unknown stream mode {mode}")
    return attribute_id, vals


def decode_stream_or_skip(cursor: Cursor, known: set[int] | frozenset[int]) -> tuple[int, np.ndarray | None]:
    """Decode a known attribute, or skip an unknown one by its framed payload.

    Unknown attributes are the format's extension seam. Their codec, symbol
    width, mode, and channel semantics belong to the revision that defines the
    attribute; this reader needs only the common header's ``payload_len`` to
    reach the next stream without interpreting any of them.
    """
    if cursor.remaining() < _STREAM_HEADER.size:
        cursor.take(_STREAM_HEADER.size)  # raises the ordinary truncated-stream diagnosis
    attribute_id = int(cursor.buf[cursor.pos])
    if attribute_id in known:
        return decode_stream(cursor)
    head = cursor.take(_STREAM_HEADER.size)
    unpacked = _STREAM_HEADER.unpack_from(head)
    payload_len = int(unpacked[-1])
    cursor.take(payload_len)
    return attribute_id, None


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF
