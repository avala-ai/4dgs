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
  /**
   * A keyframe-delta file's delta chunks. Deliberately not a flag on Chunk: a Chunk is
   * independently decodable and a Delta Chunk is exactly the record that is not, so a
   * reader that does not implement the model skips these rather than decoding bin
   * differences as absolute positions.
   */
  DeltaChunk: 0x10,
  AudioSource: 0x11,
  AudioData: 0x12,
  /**
   * Provenance family, spec §5.15. Assigned in dependency order: the two records that
   * carry poses come after the one that names the frame those poses are in.
   */
  CoordinateFrame: 0x20,
  SensorCalibration: 0x21,
  RigTrajectory: 0x22,
  /** Defined after the three above, so it took the next free number rather than a tidier one. */
  GeodeticAnchor: 0x23,
  /**
   * The object layer, spec §5.15.6–§5.15.7. The Object Table names the scene's objects
   * (labels, anchors, embeddings); the SE(3) Track carries one object's rigid pose over
   * the scene clock. Both are advisory front matter in the provenance family's sense — a
   * reader that skips them by length decodes a valid base scene — so they sit inside the
   * family range and are framed by the same walk.
   */
  ObjectTable: 0x24,
  ObjectTrack: 0x25,
} as const;

/** First opcode of the provenance family, and one past its last. `0x26`–`0x2F` are reserved. */
export const PROVENANCE_START = 0x20;
export const PROVENANCE_END = 0x30;

/** True for the provenance family, defined and reserved alike. */
export function isProvenanceOpcode(opcode: number): boolean {
  return opcode >= PROVENANCE_START && opcode < PROVENANCE_END;
}

/** True for the two object-layer opcodes, which are a family within the family. */
export function isObjectOpcode(opcode: number): boolean {
  return opcode === Opcode.ObjectTable || opcode === Opcode.ObjectTrack;
}

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
  /**
   * Identity, required in every chunk of a `keyframe-delta` file and absent from a
   * `gaussian-birth` one. Distinct from `SourceIndex`, which is a producer-side handle a
   * reader may skip; this is what a delta names its gaussians by.
   */
  GaussianId: 13,
  /**
   * Object membership, spec §6.6. A `u32` per gaussian, `0` = background / unassigned.
   * Optional: a chunk without it carries gaussians that belong to no object.
   */
  ObjectId: 14,
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

/** Bit 0 of Header flags: the file contains legacy Audio or Audio Source/Data records. */
export const HEADER_FLAG_HAS_AUDIO = 1 << 0;

/** Bit 1 of the Header `flags` field: chunk data is compressed. */
export const HEADER_FLAG_CHUNKS_COMPRESSED = 1 << 1;

/** Audio Source flag bits, spec §5.16. */
export const AUDIO_SOURCE_FLAG_SPATIAL = 1 << 0;
export const AUDIO_SOURCE_FLAG_LOOP = 1 << 1;
