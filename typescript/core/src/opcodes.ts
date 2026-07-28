// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Record opcodes and attribute ids.
 *
 * The opcode space is partitioned so extension never needs permission: `0x01`-`0x7F` is
 * specification territory, `0x80`-`0xFF` belongs to applications and is never defined
 * here. A reader skips what it does not recognize in either range.
 */

export const Opcode = {
  Header: 0x01,
  Footer: 0x02,
  Quantization: 0x03,
  WindowTable: 0x04,
  Chunk: 0x05,
  AttributeStream: 0x06,
  ShBandStream: 0x07,
  ChunkIndex: 0x08,
  Audio: 0x09,
  Camera: 0x0a,
  Metadata: 0x0b,
  Statistics: 0x0c,
  Attachment: 0x0d,
  AttachmentIndex: 0x0e,
  SummaryOffset: 0x0f,
} as const;

/** Records whose currently defined fields are frozen for the life of version 1. */
export const FROZEN_OPCODES: ReadonlySet<number> = new Set([
  Opcode.Header,
  Opcode.Footer,
  Opcode.Quantization,
  Opcode.WindowTable,
  Opcode.Chunk,
  Opcode.AttributeStream,
  Opcode.ChunkIndex,
]);

/** First opcode of the private / application range. */
export const PRIVATE_OPCODE_START = 0x80;

const OPCODE_NAMES = new Map<number, string>(
  Object.entries(Opcode).map(([name, code]) => [code as number, name]),
);

/** True for the application range, which the specification never defines. */
export function isPrivateOpcode(opcode: number): boolean {
  return opcode >= PRIVATE_OPCODE_START;
}

/** A human name for an opcode, for error messages. */
export function opcodeName(opcode: number): string {
  const hex = `0x${opcode.toString(16).padStart(2, "0").toUpperCase()}`;
  if (isPrivateOpcode(opcode)) return `Private(${hex})`;
  return OPCODE_NAMES.get(opcode) ?? `Unknown(${hex})`;
}

/** Attribute ids carried by Attribute Stream records. */
export const Attribute = {
  Position: 0,
  Scale: 1,
  RotationIndex: 2,
  Rotation: 3,
  Color: 4,
  Opacity: 5,
  Motion: 6,
  MuT: 7,
  SigmaT: 8,
  Flags: 9,
  WindowIndex: 10,
  SourceGroup: 11,
  SourceIndex: 12,
} as const;

/** Attribute ids every chunk must carry. */
export const REQUIRED_ATTRIBUTES: readonly number[] = [
  Attribute.Position,
  Attribute.Scale,
  Attribute.RotationIndex,
  Attribute.Rotation,
  Attribute.Color,
  Attribute.Opacity,
  Attribute.Motion,
  Attribute.MuT,
  Attribute.SigmaT,
  Attribute.Flags,
  Attribute.WindowIndex,
];

/** Bit 0 of the per-gaussian flags attribute: this gaussian never fades. */
export const GAUSSIAN_FLAG_NEVER_FADES = 1;

/** Bit 0 of the Header `flags` field: the file contains an Audio record. */
export const HEADER_FLAG_HAS_AUDIO = 1 << 0;

/** Bit 1 of the Header `flags` field: chunk data is compressed. */
export const HEADER_FLAG_CHUNKS_COMPRESSED = 1 << 1;
