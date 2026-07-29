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

/// First opcode of the application range, which the specification never
/// defines and a conforming reader always skips.
const int opPrivateStart = 0x80;

bool isPrivateOpcode(int opcode) => opcode >= opPrivateStart;

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
