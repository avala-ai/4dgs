// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The magic, record framing, and one parser per record body.
 *
 * Every parser here reads the fields it knows and stops. It never asserts that the record
 * ended where its knowledge did, because a newer writer may have appended fields — that
 * is the compatibility rule, and a reader that checks for trailing bytes breaks on the
 * first file that uses it.
 */

import { Cursor } from "./cursor.js";
import { TruncatedFile, UnsupportedVersion } from "./errors.js";
import { HEADER_FLAG_HAS_AUDIO } from "./opcodes.js";

/**
 * `0x89 4 D G S 1 CR LF`.
 *
 * The high bit stops byte-oriented tooling treating the file as text; the `1` is the
 * major version; the CR LF catches transports that mangle line endings.
 */
export const MAGIC = new Uint8Array([0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]);

/** The major version this reader implements. */
export const VERSION = 1;

/** `u8` opcode plus `u64` content length. */
export const RECORD_HEADER_BYTES = 9;

/** Footer content, plus its own record header, plus the trailing magic. */
export const FOOTER_TAIL_BYTES = RECORD_HEADER_BYTES + 20 + MAGIC.length;

export interface RawRecord {
  readonly opcode: number;
  readonly content: Uint8Array;
  /** Offset of the record's opcode byte within the resource. */
  readonly offset: number;
  /** Total bytes the record occupies, header included. */
  readonly length: number;
  /** The whole record, header included — the bytes a checksum over a range covers. */
  readonly raw: Uint8Array;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * Refuse anything that is not a version-1 4dgs file.
 *
 * A file whose magic says `4DGS` with a different version byte gets a different message
 * from a file that is not ours at all: the first needs a newer reader, the second needs a
 * different tool.
 */
export function checkMagic(head: Uint8Array): void {
  if (head.length < MAGIC.length) {
    throw new TruncatedFile(`file is ${head.length} bytes, shorter than the 8-byte magic`);
  }
  const found = head.subarray(0, MAGIC.length);
  if (bytesEqual(found, MAGIC)) return;
  const isFourdgs =
    found[1] === 0x34 && found[2] === 0x44 && found[3] === 0x47 && found[4] === 0x53;
  if (isFourdgs) {
    throw new UnsupportedVersion(
      `4dgs major version ${String.fromCharCode(found[5]!)} is not supported by this reader`,
    );
  }
  throw new UnsupportedVersion(
    `not a 4dgs file: magic is ${Array.from(found, (b) => b.toString(16).padStart(2, "0")).join(" ")}`,
  );
}

/** Read one record at the cursor. */
export function readRecord(cursor: Cursor, base = 0): RawRecord {
  const start = cursor.pos;
  const offset = base + start;
  const opcode = cursor.u8();
  const length = cursor.u64();
  const content = cursor.take(length);
  return {
    opcode,
    content,
    offset,
    length: length + RECORD_HEADER_BYTES,
    raw: cursor.bytes.subarray(start, start + RECORD_HEADER_BYTES + length),
  };
}

/**
 * Every complete record in `bytes`, interpreting nothing.
 *
 * A caller that does not recognize an opcode ignores the record — that is the whole
 * forward-compatibility story, and it works because this loop never needs to know what a
 * record means to know how long it is.
 */
export function* iterateRecords(bytes: Uint8Array, pos = 0, base = 0): Generator<RawRecord> {
  const cursor = new Cursor(bytes, pos, base);
  while (cursor.remaining >= RECORD_HEADER_BYTES) {
    yield readRecord(cursor, base);
  }
}

export interface Header {
  readonly profile: string;
  readonly library: string;
  readonly durationSec: number;
  readonly gaussianCount: number;
  readonly cutoff: number;
  readonly temporalModel: string;
  readonly aabb: readonly number[];
  readonly shDegree: number;
  readonly flags: number;
  readonly attributes: ReadonlyMap<string, string>;
  /**
   * Whether the scene has audio, answered from the Header alone — no probing and no
   * speculative range request. This is the entire audio discovery rule.
   */
  readonly hasAudio: boolean;
}

export function parseHeader(content: Uint8Array): Header {
  const c = new Cursor(content);
  const profile = c.string();
  const library = c.string();
  const durationSec = c.f64();
  const gaussianCount = c.u64();
  const cutoff = c.f64();
  const temporalModel = c.string();
  const aabb = c.f64s(6);
  const shDegree = c.u8();
  const flags = c.u8();
  const attributes = c.stringMap();
  return {
    profile,
    library,
    durationSec,
    gaussianCount,
    cutoff,
    temporalModel,
    aabb,
    shDegree,
    flags,
    attributes,
    hasAudio: (flags & HEADER_FLAG_HAS_AUDIO) !== 0,
  };
}

export interface Footer {
  /** Byte offset of the first Chunk Index record, or 0 when the file has no index. */
  readonly summaryStart: number;
  readonly summaryOffsetStart: number;
  /** CRC-32 (IEEE) over `[summaryStart, footerStart)`, or 0 when not written. */
  readonly summaryCrc: number;
}

export function parseFooter(content: Uint8Array): Footer {
  const c = new Cursor(content);
  return { summaryStart: c.u64(), summaryOffsetStart: c.u64(), summaryCrc: c.u32() };
}

export interface Quantization {
  readonly scheme: string;
  readonly posOrigin: readonly number[];
  readonly stepPos: number;
  readonly stepScaleLog: number;
  readonly stepRot: number;
  readonly stepRgb: number;
  readonly stepAlpha: number;
  readonly stepMotion: number;
  readonly stepTime: number;
  readonly stepSigmaLog: number;
  readonly stepSh: number;
  /** Declared maximum deviation per attribute, as the decimal strings the file carries. */
  readonly bounds: ReadonlyMap<string, string>;
}

export function parseQuantization(content: Uint8Array): Quantization {
  const c = new Cursor(content);
  const scheme = c.string();
  const posOrigin = c.f64s(3);
  const steps = c.f64s(8);
  return {
    scheme,
    posOrigin,
    stepPos: steps[0]!,
    stepScaleLog: steps[1]!,
    stepRot: steps[2]!,
    stepRgb: steps[3]!,
    stepAlpha: steps[4]!,
    stepMotion: steps[5]!,
    stepTime: steps[6]!,
    stepSigmaLog: steps[7]!,
    stepSh: c.u8(),
    bounds: c.stringMap(),
  };
}

/** Validity windows, as `[lo, hi]` pairs flattened into one array. */
export function parseWindowTable(content: Uint8Array): Float64Array {
  const c = new Cursor(content);
  const count = c.u32();
  const out = new Float64Array(count * 2);
  for (let i = 0; i < count * 2; i++) out[i] = c.f64();
  return out;
}

export interface ChunkHeader {
  readonly t0: number;
  readonly t1: number;
  readonly level: number;
  readonly count: number;
  readonly compression: string;
  readonly uncompressedSize: number;
}

export interface ParsedChunk {
  readonly header: ChunkHeader;
  /** The concatenated Attribute Stream records, still compressed per stream. */
  readonly streams: Uint8Array;
}

export function parseChunk(content: Uint8Array): ParsedChunk {
  const c = new Cursor(content);
  const header: ChunkHeader = {
    t0: c.f64(),
    t1: c.f64(),
    level: c.u32(),
    count: c.u32(),
    compression: c.string(),
    uncompressedSize: c.u64(),
  };
  return { header, streams: c.blob() };
}

export interface BandRange {
  readonly band: number;
  readonly offset: number;
  readonly length: number;
}

export interface ChunkIndexEntry {
  readonly t0: number;
  readonly t1: number;
  readonly chunkOffset: number;
  readonly chunkLength: number;
  readonly gaussianCount: number;
  readonly bands: readonly BandRange[];
}

export function parseChunkIndexEntry(content: Uint8Array): ChunkIndexEntry {
  const c = new Cursor(content);
  const t0 = c.f64();
  const t1 = c.f64();
  const chunkOffset = c.u64();
  const chunkLength = c.u64();
  const gaussianCount = c.u32();
  const bandCount = c.u32();
  const bands: BandRange[] = [];
  for (let i = 0; i < bandCount; i++) {
    bands.push({ band: c.u8(), offset: c.u64(), length: c.u64() });
  }
  return { t0, t1, chunkOffset, chunkLength, gaussianCount, bands };
}

/** The half-open interval test the seek rule is built on. */
export function entryCovers(entry: ChunkIndexEntry, t: number): boolean {
  return entry.t0 <= t && t < entry.t1;
}

export interface AudioTrack {
  readonly codec: string;
  /** Scene time at which the track's first sample plays. */
  readonly startSec: number;
  /** The encoded track, verbatim. */
  readonly data: Uint8Array;
}

export function parseAudio(content: Uint8Array): AudioTrack {
  const c = new Cursor(content);
  return { codec: c.string(), startSec: c.f64(), data: c.blob() };
}

export interface CameraKeyframe {
  readonly time: number;
  readonly position: readonly number[];
  readonly target: readonly number[];
}

export interface Camera {
  readonly fovYDeg: number;
  readonly position: readonly number[];
  readonly target: readonly number[];
  readonly keyframes: readonly CameraKeyframe[];
  readonly interpolation: string;
  readonly loop: boolean;
}

export function parseCamera(content: Uint8Array): Camera {
  const c = new Cursor(content);
  const fovYDeg = c.f64();
  const position = c.f64s(3);
  const target = c.f64s(3);
  const count = c.u32();
  const keyframes: CameraKeyframe[] = [];
  for (let i = 0; i < count; i++) {
    keyframes.push({ time: c.f64(), position: c.f64s(3), target: c.f64s(3) });
  }
  return { fovYDeg, position, target, keyframes, interpolation: c.string(), loop: c.u8() !== 0 };
}

export interface Metadata {
  readonly name: string;
  readonly entries: ReadonlyMap<string, string>;
}

export function parseMetadata(content: Uint8Array): Metadata {
  const c = new Cursor(content);
  return { name: c.string(), entries: c.stringMap() };
}

export interface Statistics {
  readonly gaussianCount: number;
  readonly chunkCount: number;
  readonly durationSec: number;
  readonly aabb: readonly number[];
}

export function parseStatistics(content: Uint8Array): Statistics {
  const c = new Cursor(content);
  return {
    gaussianCount: c.u64(),
    chunkCount: c.u32(),
    durationSec: c.f64(),
    aabb: c.f64s(6),
  };
}

export interface Attachment {
  readonly name: string;
  readonly mediaType: string;
  readonly data: Uint8Array;
}

export function parseAttachment(content: Uint8Array): Attachment {
  const c = new Cursor(content);
  return { name: c.string(), mediaType: c.string(), data: c.blob() };
}

export interface SummaryOffset {
  readonly groupOpcode: number;
  readonly groupStart: number;
  readonly groupLength: number;
}

export function parseSummaryOffset(content: Uint8Array): SummaryOffset {
  const c = new Cursor(content);
  return { groupOpcode: c.u8(), groupStart: c.u64(), groupLength: c.u64() };
}

/** An SH Band Stream record's band byte, followed by an ordinary attribute stream. */
export function parseShBandRecord(content: Uint8Array): { band: number; cursor: Cursor } {
  const cursor = new Cursor(content);
  return { band: cursor.u8(), cursor };
}
