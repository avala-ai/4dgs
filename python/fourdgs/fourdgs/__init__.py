# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""4dgs — reader and writer for the 4dgs container format.

Install `4dgs`, import `fourdgs`: Python identifiers cannot start with a digit.

    import fourdgs

    scene = fourdgs.read("scene.4dgs")
    state = scene.gaussians.state_at(1.5)   # decoding ends here

The specification lives at https://github.com/avala-ai/4dgs.
"""

from __future__ import annotations

#: Single source of truth for the package version; the release workflow asserts this
#: against the tag it was invoked with.
__version__ = "0.1.0"

from .exceptions import (  # noqa: E402
    BoundViolation,
    FourdgsError,
    MalformedFile,
    TruncatedFile,
    UnsupportedCodec,
    UnsupportedVersion,
)
from .model import AudioTrack, CameraTrajectory, GaussianSet  # noqa: E402
from .quantization import Bounds, Steps  # noqa: E402
from .stream_reader import Scene, read  # noqa: E402
from .writer import WriteOptions, write  # noqa: E402

__all__ = [
    "__version__",
    "AudioTrack",
    "Bounds",
    "BoundViolation",
    "CameraTrajectory",
    "FourdgsError",
    "GaussianSet",
    "MalformedFile",
    "Scene",
    "Steps",
    "TruncatedFile",
    "UnsupportedCodec",
    "UnsupportedVersion",
    "WriteOptions",
    "read",
    "write",
]
