// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Record opcodes and attribute ids.
///
/// The opcode space is partitioned so that extension never needs permission:
/// `0x01`-`0x7F` is specification territory, `0x80`-`0xFF` belongs to
/// applications and is never defined by the specification. A reader skips what
/// it does not recognize in either range, by length.
library;

const int opHeader = 0x01;
const int opFooter = 0x02;
const int opQuantization = 0x03;
const int opWindowTable = 0x04;
const int opChunk = 0x05;
const int opAttributeStream = 0x06;
const int opShBandStream = 0x07;
const int opChunkIndex = 0x08;
const int opAudio = 0x09;
const int opCamera = 0x0A;
const int opMetadata = 0x0B;
const int opStatistics = 0x0C;
const int opAttachment = 0x0D;
const int opAttachmentIndex = 0x0E;
const int opSummaryOffset = 0x0F;
const int opDeltaChunk = 0x10;
const int opAudioSource = 0x11;
const int opAudioData = 0x12;

// The provenance family, spec section 5.15. Assigned in dependency order: the
// two records that carry poses come after the one that names the frame those
// poses are in. GEODETIC_ANCHOR holds 0x23 because it was defined after them;
// an opcode is not something a later revision gets to renumber for tidiness.
const int opCoordinateFrame = 0x20;
const int opSensorCalibration = 0x21;
const int opRigTrajectory = 0x22;
const int opGeodeticAnchor = 0x23;

// The object layer (spec §5.15.6–5.15.7). Not decoded by this SDK yet; a
// conforming reader steps over them by length.
const int opObjectTable = 0x24;
const int opObjectTrack = 0x25;

/// First opcode of the provenance family, and one past its last. `0x26`–`0x2F`
/// are reserved for source timing (spec section 5.15.6).
const int opProvenanceStart = 0x20;
const int opProvenanceEnd = 0x30;

/// True for the provenance family, defined and reserved alike.
bool isProvenanceOpcode(int opcode) =>
    opcode >= opProvenanceStart && opcode < opProvenanceEnd;

// Audio Source flags (spec §5.16).
const int audioSourceFlagSpatial = 1 << 0;
const int audioSourceFlagLoop = 1 << 1;

/// First opcode of the application range, which the specification never
/// defines and a conforming reader always skips.
const int opPrivateStart = 0x80;

bool isPrivateOpcode(int opcode) => opcode >= opPrivateStart;

/// The names in [_opcodeNames], plus the two ranges a reader steps over.
///
/// Character for character what `rust/fourdgs/src/opcode.rs` answers, because
/// these names are what the inspect tables in six SDKs print for the same
/// record. A row that reads `WindowTable` in one tool and `Window Table` in
/// another is a diff a reader has to squint at before deciding it means nothing.
String opcodeName(int opcode) {
  final String? known = _opcodeNames[opcode];
  if (known != null) return known;
  final String hex = opcode.toRadixString(16).padLeft(2, '0').toUpperCase();
  return isPrivateOpcode(opcode) ? 'Private(0x$hex)' : 'Unknown(0x$hex)';
}

const Map<int, String> _opcodeNames = <int, String>{
  opHeader: 'Header',
  opFooter: 'Footer',
  opQuantization: 'Quantization',
  opWindowTable: 'WindowTable',
  opChunk: 'Chunk',
  opAttributeStream: 'AttributeStream',
  opShBandStream: 'ShBandStream',
  opChunkIndex: 'ChunkIndex',
  opAudio: 'Audio',
  opCamera: 'Camera',
  opMetadata: 'Metadata',
  opStatistics: 'Statistics',
  opAttachment: 'Attachment',
  opAttachmentIndex: 'AttachmentIndex',
  opSummaryOffset: 'SummaryOffset',
  opDeltaChunk: 'DeltaChunk',
  opAudioSource: 'Audio Source',
  opAudioData: 'Audio Data',
  opCoordinateFrame: 'CoordinateFrame',
  opSensorCalibration: 'SensorCalibration',
  opRigTrajectory: 'RigTrajectory',
  opGeodeticAnchor: 'GeodeticAnchor',
  opObjectTable: 'ObjectTable',
  opObjectTrack: 'ObjectTrack',
};

/// True for the opcodes this version of the specification defines.
///
/// Everything else is either the application range or a record from a revision
/// this build does not implement, and both are skipped rather than refused.
bool isSpecifiedOpcode(int opcode) => _opcodeNames.containsKey(opcode);

/// True when a specified opcode is itself a top-level record.
///
/// Attribute Stream is an embedded structure inside a Chunk or delta group,
/// and Attachment Index remains reserved with an explicit writer prohibition.
/// Keeping their registry names is useful to inspection output; it does not
/// make either legal in the outer record sequence.
bool isLegalTopLevelOpcode(int opcode) =>
    isSpecifiedOpcode(opcode) &&
    opcode != opAttributeStream &&
    opcode != opAttachmentIndex;

// Attribute ids carried by Attribute Stream records.
const int attrPosition = 0;
const int attrScale = 1;
const int attrRotationIndex = 2;
const int attrRotation = 3;
const int attrColor = 4;
const int attrOpacity = 5;
const int attrMotion = 6;
const int attrMuT = 7;
const int attrSigmaT = 8;
const int attrFlags = 9;
const int attrWindowIndex = 10;
const int attrSourceGroup = 11;
const int attrSourceIndex = 12;

/// Identity, required in every chunk of a `keyframe-delta` file and absent from a
/// `gaussian-birth` one. Distinct from [attrSourceIndex], which is a
/// producer-side handle a reader may skip; this is what a delta names its
/// gaussians by.
const int attrGaussianId = 13;

/// Object membership, spec section 6.6. A `u32` per gaussian, `0` = background
/// / unassigned. Optional: a chunk without it carries gaussians that belong to
/// no object.
const int attrObjectId = 14;

/// The first and last id of the reserved extension pool, registry §"Attribute
/// ids". Ids 15–63 are reserved and a version-1 writer MUST NOT emit them; ids
/// 64–127 are private and application-defined. A reader skips both the same
/// way, by `payload_length`, which is what forward compatibility requires — but
/// only one of the two is a file a conformance validator should accept.
const int attrReservedFirst = 15;
const int attrReservedLast = 63;

/// Ids every chunk must carry. 11 and 12 are optional producer-side identities
/// and readers that do not need them skip the streams.
const List<int> requiredAttributes = <int>[
  attrPosition,
  attrScale,
  attrRotationIndex,
  attrRotation,
  attrColor,
  attrOpacity,
  attrMotion,
  attrMuT,
  attrSigmaT,
  attrFlags,
  attrWindowIndex,
];

/// Bit 0 of the per-gaussian flags attribute: this gaussian never fades, so its
/// `sigma_t` is infinite and its marginal is 1 across its whole window.
const int flagNeverFades = 1;

// Header `flags` bits.
const int headerFlagHasAudio = 1 << 0;
const int headerFlagChunksCompressed = 1 << 1;

// Attribute-stream coding modes.
const int modeRaw = 0;
const int modeDelta = 1;
const int modeConst = 2;

// Stream codecs.
const int codecDeflate = 0;
const int codecZstd = 1;
