# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""4dgs — reader and writer for the 4dgs container format.

Distributed as `fourdgs` on PyPI.

    import fourdgs

    scene = fourdgs.read("scene.4dgs")
    state = scene.gaussians.state_at(1.5)   # decoding ends here

The specification lives at https://github.com/avala-ai/4dgs.
"""

from __future__ import annotations

#: Single source of truth for the package version; the release workflow asserts this
#: against the tag it was invoked with.
__version__ = "0.1.0"

from .exceptions import (
    BoundViolation,
    FourdgsError,
    InvalidInput,
    MalformedFile,
    TruncatedFile,
    UnsupportedCodec,
    UnsupportedVersion,
)
from .gltf import GltfImport, from_gltf, to_gltf
from .model import AudioTrack, CameraTrajectory, GaussianSet
from .quantization import Bounds, Steps
from .stream_reader import Scene, read
from .writer import WriteOptions, write

__all__ = [
    "AudioTrack",
    "BoundViolation",
    "Bounds",
    "CameraTrajectory",
    "FourdgsError",
    "GaussianSet",
    "GltfImport",
    "InvalidInput",
    "MalformedFile",
    "Scene",
    "Steps",
    "TruncatedFile",
    "UnsupportedCodec",
    "UnsupportedVersion",
    "WriteOptions",
    "__version__",
    "from_gltf",
    "read",
    "to_gltf",
    "write",
]
