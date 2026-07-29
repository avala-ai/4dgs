# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Record opcodes.

The space is partitioned so that extension never needs permission: `0x01`-`0x7F` is
specification territory, `0x80`-`0xFF` belongs to applications and is never defined here.
A reader skips what it does not recognize in either range.
"""

from __future__ import annotations

HEADER = 0x01
FOOTER = 0x02
QUANTIZATION = 0x03
WINDOW_TABLE = 0x04
CHUNK = 0x05
ATTRIBUTE_STREAM = 0x06
SH_BAND_STREAM = 0x07
CHUNK_INDEX = 0x08
AUDIO = 0x09
CAMERA = 0x0A
METADATA = 0x0B
STATISTICS = 0x0C
ATTACHMENT = 0x0D
ATTACHMENT_INDEX = 0x0E
SUMMARY_OFFSET = 0x0F

#: A keyframe-delta file's delta chunks. Deliberately NOT a flag on `Chunk`: a Chunk is
#: independently decodable and a Delta Chunk is exactly the record that is not, so a
#: reader that does not implement the model skips these rather than decoding bin
#: differences as absolute positions.
DELTA_CHUNK = 0x10

# Multi-source audio follows the already-assigned Delta Chunk opcode.
AUDIO_SOURCE = 0x11
AUDIO_DATA = 0x12

# The provenance family, spec section 5.15. Assigned in dependency order: the two records
# that carry poses come after the one that names the frame those poses are in.
COORDINATE_FRAME = 0x20
SENSOR_CALIBRATION = 0x21
RIG_TRAJECTORY = 0x22
# Defined after the three above, so it took the next free number rather than a tidier
# one. An opcode is not something a later revision gets to renumber.
GEODETIC_ANCHOR = 0x23

#: The object layer, spec sections 5.15.6-5.15.7. The Object
#: Table names the scene's objects (labels, embeddings, anchors); the SE(3) Track carries
#: one object's rigid pose over the scene clock. Both are advisory front matter in the
#: provenance family's sense — a reader that skips them decodes a valid base scene — and
#: they took the next two free numbers after the georeference.
OBJECT_TABLE = 0x24
OBJECT_TRACK = 0x25

#: First opcode of the provenance family, and one past its last. `0x26`-`0x2F` are
#: reserved for source timing (spec section 5.15.8).
PROVENANCE_START = 0x20
PROVENANCE_END = 0x30

#: Records a version-1 reader must understand; their fields are frozen.
FROZEN = frozenset({HEADER, FOOTER, QUANTIZATION, WINDOW_TABLE, CHUNK, ATTRIBUTE_STREAM, CHUNK_INDEX})

PRIVATE_START = 0x80

NAMES = {
    HEADER: "Header",
    FOOTER: "Footer",
    QUANTIZATION: "Quantization",
    WINDOW_TABLE: "WindowTable",
    CHUNK: "Chunk",
    ATTRIBUTE_STREAM: "AttributeStream",
    SH_BAND_STREAM: "ShBandStream",
    CHUNK_INDEX: "ChunkIndex",
    AUDIO: "Audio",
    CAMERA: "Camera",
    METADATA: "Metadata",
    STATISTICS: "Statistics",
    ATTACHMENT: "Attachment",
    ATTACHMENT_INDEX: "AttachmentIndex",
    SUMMARY_OFFSET: "SummaryOffset",
    DELTA_CHUNK: "DeltaChunk",
    AUDIO_SOURCE: "AudioSource",
    AUDIO_DATA: "AudioData",
    COORDINATE_FRAME: "CoordinateFrame",
    SENSOR_CALIBRATION: "SensorCalibration",
    RIG_TRAJECTORY: "RigTrajectory",
    GEODETIC_ANCHOR: "GeodeticAnchor",
    OBJECT_TABLE: "ObjectTable",
    OBJECT_TRACK: "ObjectTrack",
}


def is_provenance(opcode: int) -> bool:
    """True for the provenance family, defined and reserved alike."""
    return PROVENANCE_START <= opcode < PROVENANCE_END


def is_private(opcode: int) -> bool:
    """True for the application range, which this specification never defines."""
    return opcode >= PRIVATE_START


def name(opcode: int) -> str:
    if is_private(opcode):
        return f"Private(0x{opcode:02X})"
    return NAMES.get(opcode, f"Unknown(0x{opcode:02X})")


# Attribute ids carried by Attribute Stream records.
A_POSITION = 0
A_SCALE = 1
A_ROTATION_INDEX = 2
A_ROTATION = 3
A_COLOR = 4
A_OPACITY = 5
A_MOTION = 6
A_MU_T = 7
A_SIGMA_T = 8
A_FLAGS = 9
A_WINDOW_INDEX = 10
A_SOURCE_GROUP = 11
A_SOURCE_INDEX = 12

#: Identity, required in every chunk of a `keyframe-delta` file and absent from a
#: `gaussian-birth` one. Distinct from `A_SOURCE_INDEX`, which is a producer-side handle a
#: reader may skip; this is what a delta names its gaussians by.
A_GAUSSIAN_ID = 13

#: Object membership, spec section 6.6. A `u32`, `0` = background/unassigned. Optional
#: and orthogonal to the temporal model: a `gaussian-birth` or `keyframe-delta` file may
#: carry it. It is EXACT — an id is a label, not a metric, so it is never dequantized and
#: the Quantization record carries no step or bound for it, exactly as for the other index
#: attributes (`A_ROTATION_INDEX`, `A_WINDOW_INDEX`).
A_OBJECT_ID = 14

REQUIRED_ATTRIBUTES = (
    A_POSITION,
    A_SCALE,
    A_ROTATION_INDEX,
    A_ROTATION,
    A_COLOR,
    A_OPACITY,
    A_MOTION,
    A_MU_T,
    A_SIGMA_T,
    A_FLAGS,
    A_WINDOW_INDEX,
)

#: Bit 0 of the per-gaussian flags attribute.
FLAG_NEVER_FADES = 1
