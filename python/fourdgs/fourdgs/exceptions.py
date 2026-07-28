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
