// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Record opcodes and attribute ids.
//!
//! The space is partitioned so that extension never needs permission: `0x01`-`0x7F` is
//! specification territory, `0x80`-`0xFF` belongs to applications and is never defined
//! here. A reader skips what it does not recognize in either range.

pub const HEADER: u8 = 0x01;
pub const FOOTER: u8 = 0x02;
pub const QUANTIZATION: u8 = 0x03;
pub const WINDOW_TABLE: u8 = 0x04;
pub const CHUNK: u8 = 0x05;
pub const ATTRIBUTE_STREAM: u8 = 0x06;
pub const SH_BAND_STREAM: u8 = 0x07;
pub const CHUNK_INDEX: u8 = 0x08;
pub const AUDIO: u8 = 0x09;
pub const CAMERA: u8 = 0x0A;
pub const METADATA: u8 = 0x0B;
pub const STATISTICS: u8 = 0x0C;
pub const ATTACHMENT: u8 = 0x0D;
pub const ATTACHMENT_INDEX: u8 = 0x0E;
pub const SUMMARY_OFFSET: u8 = 0x0F;

/// A keyframe-delta file's delta chunks. Deliberately NOT a flag on `Chunk`: a Chunk is
/// independently decodable and a Delta Chunk is exactly the record that is not, so a
/// reader that does not implement the model skips these rather than decoding bin
/// differences as absolute positions.
pub const DELTA_CHUNK: u8 = 0x10;

// Multi-source audio follows the already-assigned Delta Chunk opcode.
pub const AUDIO_SOURCE: u8 = 0x11;
pub const AUDIO_DATA: u8 = 0x12;

// The provenance family, spec section 5.15. The first three run in dependency order —
// a sensor's extrinsic and a rig's pose are poses in a frame, and `0x20` names that
// frame. `GEODETIC_ANCHOR` holds `0x23` because it was defined after them; an opcode is
// not something a later revision gets to renumber for tidiness.
pub const COORDINATE_FRAME: u8 = 0x20;
pub const SENSOR_CALIBRATION: u8 = 0x21;
pub const RIG_TRAJECTORY: u8 = 0x22;
pub const GEODETIC_ANCHOR: u8 = 0x23;

// The object layer, spec section 5.15.6's per-gaussian label work realized. The Object
// Table names the scene's objects; the SE(3) Track carries one object's rigid pose. Both
// are advisory front matter in the provenance family's sense — a reader that skips them
// decodes a valid base scene — and took the next two free numbers after the georeference.
pub const OBJECT_TABLE: u8 = 0x24;
pub const OBJECT_TRACK: u8 = 0x25;

/// First opcode of the provenance family, and one past its last. `0x26`-`0x2F` are
/// reserved for source timing (spec section 5.15.6).
pub const PROVENANCE_START: u8 = 0x20;
pub const PROVENANCE_END: u8 = 0x30;

/// True for the provenance family, defined and reserved alike.
pub fn is_provenance(opcode: u8) -> bool {
    (PROVENANCE_START..PROVENANCE_END).contains(&opcode)
}

/// First opcode of the application range, which this specification never defines.
pub const PRIVATE_START: u8 = 0x80;

/// True for the application range.
pub fn is_private(opcode: u8) -> bool {
    opcode >= PRIVATE_START
}

/// A human name for an opcode, for error messages.
pub fn name(opcode: u8) -> String {
    let known = match opcode {
        HEADER => "Header",
        FOOTER => "Footer",
        QUANTIZATION => "Quantization",
        WINDOW_TABLE => "WindowTable",
        CHUNK => "Chunk",
        ATTRIBUTE_STREAM => "AttributeStream",
        SH_BAND_STREAM => "ShBandStream",
        CHUNK_INDEX => "ChunkIndex",
        AUDIO => "Audio",
        CAMERA => "Camera",
        METADATA => "Metadata",
        STATISTICS => "Statistics",
        ATTACHMENT => "Attachment",
        ATTACHMENT_INDEX => "AttachmentIndex",
        SUMMARY_OFFSET => "SummaryOffset",
        DELTA_CHUNK => "DeltaChunk",
        AUDIO_SOURCE => "Audio Source",
        AUDIO_DATA => "Audio Data",
        COORDINATE_FRAME => "CoordinateFrame",
        SENSOR_CALIBRATION => "SensorCalibration",
        RIG_TRAJECTORY => "RigTrajectory",
        GEODETIC_ANCHOR => "GeodeticAnchor",
        OBJECT_TABLE => "ObjectTable",
        OBJECT_TRACK => "ObjectTrack",
        _ => {
            return if is_private(opcode) {
                format!("Private(0x{opcode:02X})")
            } else {
                format!("Unknown(0x{opcode:02X})")
            }
        }
    };
    known.to_string()
}

// Attribute ids carried by Attribute Stream records.
pub const A_POSITION: u8 = 0;
pub const A_SCALE: u8 = 1;
pub const A_ROTATION_INDEX: u8 = 2;
pub const A_ROTATION: u8 = 3;
pub const A_COLOR: u8 = 4;
pub const A_OPACITY: u8 = 5;
pub const A_MOTION: u8 = 6;
pub const A_MU_T: u8 = 7;
pub const A_SIGMA_T: u8 = 8;
pub const A_FLAGS: u8 = 9;
pub const A_WINDOW_INDEX: u8 = 10;
pub const A_SOURCE_GROUP: u8 = 11;
pub const A_SOURCE_INDEX: u8 = 12;

/// Identity, required in every chunk of a `keyframe-delta` file and absent from a
/// `gaussian-birth` one. Distinct from `A_SOURCE_INDEX`, which is a producer-side handle a
/// reader may skip; this is what a delta names its gaussians by.
pub const A_GAUSSIAN_ID: u8 = 13;

/// Object membership (spec section 5.15.6). A `u32`, `0` = background/unassigned. Exact:
/// an id is a label, not a metric, so it is never dequantized and the Quantization record
/// carries no step or bound for it, as with the other index attributes.
pub const A_OBJECT_ID: u8 = 14;

/// Ids every chunk must carry.
pub const REQUIRED_ATTRIBUTES: [u8; 11] = [
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
];

/// Bit 0 of the per-gaussian flags attribute: this gaussian never fades.
pub const FLAG_NEVER_FADES: i64 = 1;
