# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The one abstraction the core depends on.

A reader needs exactly two things from a resource: how big it is, and the bytes in a
range. Everything else — a file, an HTTP server, a cache, an in-memory buffer — is a
transport, and transports live at the edges so the decoder can be tested without a
network and shipped without a platform.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable


@runtime_checkable
class Readable(Protocol):
    """Something that can report its size and read a byte range."""

    def size(self) -> int:
        """Total size of the resource in bytes."""

    def read(self, offset: int, length: int) -> bytes:
        """Return exactly `length` bytes at `offset`, or raise.

        Returning a short read silently is the one behaviour that breaks every caller, so
        implementations must not do it.
        """


class BytesReadable:
    """A whole resource already in memory."""

    def __init__(self, data: bytes) -> None:
        self._data = bytes(data)

    def size(self) -> int:
        return len(self._data)

    def read(self, offset: int, length: int) -> bytes:
        if offset < 0 or length < 0 or offset + length > len(self._data):
            raise ValueError(f"range [{offset}, {offset + length}) outside {len(self._data)} bytes")
        return self._data[offset : offset + length]


class FileReadable:
    """A local file, read with `pread` semantics so it is safe to share."""

    def __init__(self, path) -> None:
        self._fh = open(path, "rb")
        self._fh.seek(0, 2)
        self._size = self._fh.tell()

    def size(self) -> int:
        return self._size

    def read(self, offset: int, length: int) -> bytes:
        self._fh.seek(offset)
        data = self._fh.read(length)
        if len(data) != length:
            raise ValueError(f"short read: wanted {length} bytes at {offset}, got {len(data)}")
        return data

    def close(self) -> None:
        self._fh.close()

    def __enter__(self) -> FileReadable:
        return self

    def __exit__(self, *exc) -> None:
        self.close()
