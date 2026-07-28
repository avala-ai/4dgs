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
}


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
