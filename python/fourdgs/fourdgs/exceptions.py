# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Exception types.

A decoder that refuses a file says which field, which value, and what was expected.
These types exist so a caller can tell apart the three cases that need different
responses: the file is not ours, the file is ours but from the future, and the file is
ours and broken.
"""

from __future__ import annotations


class FourdgsError(Exception):
    """Base class for every error raised by this library."""


class UnsupportedVersion(FourdgsError):
    """Not a 4dgs file, or a major version this reader does not implement.

    Distinct from a malformed file: the fix is a newer reader, not a new file.
    """


class TruncatedFile(FourdgsError):
    """The file ended, or a length ran past the end of its container.

    Common and often recoverable: records are length-prefixed, so a streamed reader can
    keep everything before the truncation point.
    """


class MalformedFile(FourdgsError):
    """A structurally invalid file: a required record missing, a bad index, a value
    outside its legal range."""


class UnsupportedCodec(FourdgsError):
    """A legal but unimplemented codec. The file is fine; this build cannot read it."""


class BoundViolation(FourdgsError):
    """An encoder's own verification failed: a decoded value fell outside the bound the
    file was about to declare. Always a bug in the encoder, never in the input."""


class InvalidInput(FourdgsError):
    """A caller handed the encoder something it cannot write a conforming file from.

    The mirror of every other error here: those describe a file that arrived broken,
    this one describes a scene that never should have been offered. It exists because
    the alternative is worse than an exception — an encoder that accepts a non-finite
    position and writes it into a quantization grid produces a file the specification
    forbids (§5.3), and one that nothing downstream will complain about, because
    arithmetic on infinity is perfectly well defined.
    """
