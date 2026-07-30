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
import { MalformedFile, TruncatedFile, UnsupportedVersion } from "./errors.js";
import {
  AUDIO_SOURCE_FLAG_LOOP,
  AUDIO_SOURCE_FLAG_SPATIAL,
  HEADER_FLAG_HAS_AUDIO,
} from "./opcodes.js";

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
  // The allocation is sized from the count, so the count must be proven against the
  // bytes that remain before anything is allocated. A corrupt count of 2^32 - 1 names
  // a 68 GB table; reading would refuse it eight bytes in, but the allocation comes
  // first, and an allocation the runtime cannot satisfy is a crash, not a diagnosis.
  if (count * 16 > c.remaining) {
    throw new TruncatedFile(
      `window table declares ${count} windows (${count * 16} bytes), ${c.remaining} remain`,
    );
  }
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

/**
 * `delta_mode` values, per chunk rather than per file: an encoder that knows an instant is
 * a likely seek target can make it cost two records regardless of how deep into the group
 * it falls, without spending a whole keyframe on it.
 */
export const DELTA_MODE_KEYFRAME = 0;
export const DELTA_MODE_CHAINED = 1;

export interface DeltaChunkHeader {
  readonly t0: number;
  readonly t1: number;
  readonly level: number;
  readonly deltaMode: number;
  /**
   * The chunk this delta applies to. Strictly less than the delta's own offset: references
   * point backwards only, so the chain walk terminates and cycles are unrepresentable.
   */
  readonly referenceOffset: number;
  /** The keyframe at the head of this group. */
  readonly keyframeOffset: number;
  /** Delta chunks that must be composed to reach this one — the exact read cost. */
  readonly depth: number;
  readonly updateCount: number;
  readonly birthCount: number;
  readonly deathCount: number;
  readonly compression: string;
  readonly uncompressedSize: number;
}

export interface ParsedDeltaChunk {
  readonly header: DeltaChunkHeader;
  /** The update group's concatenated Attribute Stream records, still compressed. */
  readonly updates: Uint8Array;
  /** The birth group's streams. */
  readonly births: Uint8Array;
  /** The death group's stream: identities only. */
  readonly deaths: Uint8Array;
}

/**
 * A Delta Chunk record.
 *
 * The three groups are framed by length inside one records blob rather than tagged with a
 * group byte on every stream, so a reader takes the death list — which is small and which
 * a consumer often wants alone — by stepping over two lengths.
 */
export function parseDeltaChunk(content: Uint8Array): ParsedDeltaChunk {
  const c = new Cursor(content);
  const header: DeltaChunkHeader = {
    t0: c.f64(),
    t1: c.f64(),
    level: c.u32(),
    deltaMode: c.u8(),
    referenceOffset: c.u64(),
    keyframeOffset: c.u64(),
    depth: c.u16(),
    updateCount: c.u32(),
    birthCount: c.u32(),
    deathCount: c.u32(),
    compression: c.string(),
    uncompressedSize: c.u64(),
  };
  const records = new Cursor(c.blob());
  const updates = records.blob();
  const births = records.blob();
  const deaths = records.blob();
  return { header, updates, births, deaths };
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
  /**
   * True when this entry carries the `keyframe-delta` block below. False for every
   * `gaussian-birth` file, whose entries stay byte-identical to those written before this
   * revision existed.
   */
  readonly extended: boolean;
  /** 0 keyframe (a Chunk record), 1 delta (a Delta Chunk record). */
  readonly kind: number;
  readonly deltaMode: number;
  readonly referenceOffset: number;
  readonly keyframeOffset: number;
  readonly depth: number;
  /** Gaussians live over `[t0, t1)` after composition. */
  readonly liveCount: number;
}

/**
 * Bytes the `keyframe-delta` block appends to a Chunk Index entry: `u8` kind, `u8`
 * delta_mode, `u64` reference_offset, `u64` keyframe_offset, `u16` depth, `u64`
 * live_count. A reader takes the record's length from its header, so an entry with at
 * least this many bytes left after the band array carries the block and one without simply
 * does not — which is how a `gaussian-birth` entry still parses, unchanged, to the same
 * values.
 */
const INDEX_DELTA_BLOCK_BYTES = 1 + 1 + 8 + 8 + 2 + 8;

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
  let extended = false;
  let kind = 0;
  let deltaMode = 0;
  let referenceOffset = 0;
  let keyframeOffset = 0;
  let depth = 0;
  let liveCount = 0;
  if (c.remaining >= INDEX_DELTA_BLOCK_BYTES) {
    extended = true;
    kind = c.u8();
    deltaMode = c.u8();
    referenceOffset = c.u64();
    keyframeOffset = c.u64();
    depth = c.u16();
    liveCount = c.u64();
  }
  return {
    t0,
    t1,
    chunkOffset,
    chunkLength,
    gaussianCount,
    bands,
    extended,
    kind,
    deltaMode,
    referenceOffset,
    keyframeOffset,
    depth,
    liveCount,
  };
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

export interface AudioSourceKeyframe {
  readonly time: number;
  readonly position: readonly number[];
  /** Unit quaternion, xyzw. */
  readonly rotation: readonly number[];
}

/** A small descriptor whose encoded bytes live in a paired Audio Data record. */
export interface AudioSourceDescriptor {
  readonly sourceId: number;
  readonly name: string;
  readonly codec: string;
  readonly channelLayout: string;
  readonly dataLength: number;
  readonly startSec: number;
  readonly durationSec: number;
  readonly gain: number;
  readonly spatial: boolean;
  readonly loop: boolean;
  readonly position: readonly number[];
  readonly rotation: readonly number[];
  readonly keyframes: readonly AudioSourceKeyframe[];
  readonly interpolation: string;
}

/** One independently timed, optionally spatial audio source. */
export interface AudioSource extends AudioSourceDescriptor {
  /** The encoded payload, verbatim. */
  readonly data: Uint8Array;
}

export interface AudioSourceState {
  readonly active: boolean;
  readonly localTime: number;
  readonly position: readonly number[];
  readonly rotation: readonly number[];
  readonly gain: number;
}

export function parseAudioSource(content: Uint8Array): AudioSourceDescriptor {
  const c = new Cursor(content);
  const sourceId = c.u32();
  const name = c.string();
  const codec = c.string();
  const channelLayout = c.string();
  const dataLength = c.u64();
  const startSec = c.f64();
  const durationSec = c.f64();
  const gain = c.f64();
  const flags = c.u8();
  const position = c.f64s(3);
  const rotation = c.f64s(4);
  const count = c.u32();
  if (count * 64 > c.remaining) {
    throw new TruncatedFile(
      `Audio Source ${sourceId} declares ${count} keyframes needing ${count * 64} bytes, ` +
        `${c.remaining} remain`,
    );
  }
  const keyframes: AudioSourceKeyframe[] = [];
  let lastTime = Number.NEGATIVE_INFINITY;
  for (let i = 0; i < count; i++) {
    const keyframe = { time: c.f64(), position: c.f64s(3), rotation: c.f64s(4) };
    if (!Number.isFinite(keyframe.time) || keyframe.time <= lastTime) {
      throw new MalformedFile(
        `Audio Source ${sourceId} keyframe ${i} time must be finite and strictly increasing`,
      );
    }
    lastTime = keyframe.time;
    keyframes.push(keyframe);
  }
  const interpolation = c.string();
  if ((flags & ~(AUDIO_SOURCE_FLAG_SPATIAL | AUDIO_SOURCE_FLAG_LOOP)) !== 0) {
    throw new MalformedFile(`Audio Source ${sourceId} has reserved flag bits set`);
  }
  if (codec.length === 0) throw new MalformedFile(`Audio Source ${sourceId} has an empty codec`);
  if (!Number.isFinite(startSec)) {
    throw new MalformedFile(`Audio Source ${sourceId} start_sec is not finite`);
  }
  if (!Number.isFinite(durationSec) || durationSec <= 0) {
    throw new MalformedFile(`Audio Source ${sourceId} duration_sec must be finite and positive`);
  }
  if (!Number.isFinite(gain) || gain < 0) {
    throw new MalformedFile(`Audio Source ${sourceId} gain must be finite and non-negative`);
  }
  if (!position.every(Number.isFinite)) {
    throw new MalformedFile(`Audio Source ${sourceId} position must contain three finite values`);
  }
  if (!rotation.every(Number.isFinite) || rotation.every((value) => value === 0)) {
    throw new MalformedFile(
      `Audio Source ${sourceId} rotation must be a finite non-zero quaternion`,
    );
  }
  for (let i = 0; i < keyframes.length; i++) {
    const keyframe = keyframes[i]!;
    if (!keyframe.position.every(Number.isFinite)) {
      throw new MalformedFile(
        `Audio Source ${sourceId} keyframe ${i} position must contain three finite values`,
      );
    }
    if (
      !keyframe.rotation.every(Number.isFinite) ||
      keyframe.rotation.every((value) => value === 0)
    ) {
      throw new MalformedFile(
        `Audio Source ${sourceId} keyframe ${i} rotation must be a finite non-zero quaternion`,
      );
    }
  }
  if ((flags & AUDIO_SOURCE_FLAG_SPATIAL) !== 0 && channelLayout !== "mono") {
    throw new MalformedFile(`spatial Audio Source ${sourceId} must use channel layout "mono"`);
  }
  if (interpolation !== "linear" && interpolation !== "step") {
    throw new MalformedFile(
      `Audio Source ${sourceId} uses unknown interpolation ${JSON.stringify(interpolation)}`,
    );
  }
  return {
    sourceId,
    name,
    codec,
    channelLayout,
    dataLength,
    startSec,
    durationSec,
    gain,
    spatial: (flags & AUDIO_SOURCE_FLAG_SPATIAL) !== 0,
    loop: (flags & AUDIO_SOURCE_FLAG_LOOP) !== 0,
    position,
    rotation,
    keyframes,
    interpolation,
  };
}

export interface AudioData {
  readonly sourceId: number;
  readonly data: Uint8Array;
}

export function parseAudioData(content: Uint8Array): AudioData {
  const c = new Cursor(content);
  return { sourceId: c.u32(), data: c.blob() };
}

/** Reconstruct source-local timing and pose. Spatialization remains player-owned. */
export function audioSourceStateAt(source: AudioSourceDescriptor, t: number): AudioSourceState {
  const active = t >= source.startSec && (source.loop || t - source.startSec < source.durationSec);
  const localTime =
    source.loop && source.durationSec > 0
      ? loopingLocalTime(t, source.startSec, source.durationSec)
      : Math.min(Math.max(0, t - source.startSec), Math.max(0, source.durationSec));
  const [position, rotation] = audioPoseAt(source, t);
  return { active, localTime, position, rotation, gain: source.gain };
}

function loopingLocalTime(t: number, startSec: number, durationSec: number): number {
  if (t <= startSec) return 0;
  let timeRemainder = t % durationSec;
  if (timeRemainder < 0) timeRemainder += durationSec;
  let startRemainder = startSec % durationSec;
  if (startRemainder < 0) startRemainder += durationSec;
  const difference = timeRemainder - startRemainder;
  return difference < 0 ? difference + durationSec : difference;
}

function audioPoseAt(
  source: AudioSourceDescriptor,
  t: number,
): readonly [readonly number[], readonly number[]] {
  const frames = source.keyframes;
  if (frames.length === 0) return [source.position, normalizedQuaternion(source.rotation)];
  if (t <= frames[0]!.time) {
    return [frames[0]!.position, normalizedQuaternion(frames[0]!.rotation)];
  }
  if (t >= frames[frames.length - 1]!.time) {
    const last = frames[frames.length - 1]!;
    return [last.position, normalizedQuaternion(last.rotation)];
  }
  let high = 1;
  while (frames[high]!.time <= t) high++;
  const a = frames[high - 1]!;
  const b = frames[high]!;
  if (source.interpolation === "step") {
    return [a.position, normalizedQuaternion(a.rotation)];
  }
  const u = interpolationFraction(t, a.time, b.time);
  return [
    a.position.map((value, i) => finiteLerp(value, b.position[i]!, u)),
    slerp(a.rotation, b.rotation, u),
  ];
}

function interpolationFraction(t: number, a: number, b: number): number {
  const span = b - a;
  if (Number.isFinite(span)) return (t - a) / span;
  const scale = Math.max(Math.abs(a), Math.abs(b));
  return (t / scale - a / scale) / (b / scale - a / scale);
}

function finiteLerp(a: number, b: number, u: number): number {
  return (a <= 0 && b >= 0) || (a >= 0 && b <= 0) ? a * (1 - u) + b * u : a + (b - a) * u;
}

function normalizedQuaternion(value: readonly number[]): readonly number[] {
  const scale = Math.max(...value.map(Math.abs));
  if (!Number.isFinite(scale) || scale === 0) return [0, 0, 0, 1];
  const scaled = value.map((component) => component / scale);
  const length = Math.sqrt(scaled.reduce((sum, component) => sum + component * component, 0));
  return scaled.map((component) => component / length);
}

function slerp(a: readonly number[], b: readonly number[], u: number): readonly number[] {
  const qa = normalizedQuaternion(a);
  let qb = normalizedQuaternion(b);
  let dot = qa.reduce((sum, value, i) => sum + value * qb[i]!, 0);
  if (dot < 0) {
    qb = qb.map((value) => -value);
    dot = -dot;
  }
  dot = Math.min(1, Math.max(-1, dot));
  if (dot > 0.9995) {
    return normalizedQuaternion(qa.map((value, i) => value + (qb[i]! - value) * u));
  }
  const theta = Math.acos(dot);
  const sinTheta = Math.sin(theta);
  const wa = Math.sin((1 - u) * theta) / sinTheta;
  const wb = Math.sin(u * theta) / sinTheta;
  return normalizedQuaternion(qa.map((value, i) => wa * value + wb * qb[i]!));
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
