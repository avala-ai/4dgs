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
__version__ = "0.6.0"

from .compressed_ply import import_scene as from_compressed_ply
from .compressed_ply import is_compressed_ply, read_compressed_ply, sorted_segments
from .exceptions import (
    BoundViolation,
    ExceedsReaderLimit,
    FourdgsError,
    InvalidInput,
    MalformedFile,
    TruncatedFile,
    UnsupportedCodec,
    UnsupportedVersion,
)
from .gltf import GltfImport, from_gltf, to_gltf
from .model import AudioSource, AudioSourceKeyframe, AudioSourceState, AudioTrack, CameraTrajectory, GaussianSet
from .object_layer import ObjectLayer, state_at_with_objects
from .provenance import Pose, Provenance, pose_at
from .quantization import SH_LADDERS, Bounds, Steps, sh_bound, sh_step
from .records import (
    CoordinateFrame,
    GeodeticAnchor,
    ObjectTable,
    ObjectTableEntry,
    ObjectTrack,
    RigTrajectory,
    SensorCalibration,
)
from .stream_reader import Scene, read
from .usd import UsdImport, from_usd, to_usd
from .writer import WriteOptions, write

__all__ = [
    "SH_LADDERS",
    "AudioSource",
    "AudioSourceKeyframe",
    "AudioSourceState",
    "AudioTrack",
    "BoundViolation",
    "Bounds",
    "CameraTrajectory",
    "CoordinateFrame",
    "ExceedsReaderLimit",
    "FourdgsError",
    "GaussianSet",
    "GeodeticAnchor",
    "GltfImport",
    "InvalidInput",
    "MalformedFile",
    "ObjectLayer",
    "ObjectTable",
    "ObjectTableEntry",
    "ObjectTrack",
    "Pose",
    "Provenance",
    "RigTrajectory",
    "Scene",
    "SensorCalibration",
    "Steps",
    "TruncatedFile",
    "UnsupportedCodec",
    "UnsupportedVersion",
    "UsdImport",
    "WriteOptions",
    "__version__",
    "from_compressed_ply",
    "from_gltf",
    "from_usd",
    "is_compressed_ply",
    "pose_at",
    "read",
    "read_compressed_ply",
    "sh_bound",
    "sh_step",
    "sorted_segments",
    "state_at_with_objects",
    "to_gltf",
    "to_usd",
    "write",
]
