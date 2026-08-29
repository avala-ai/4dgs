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
import { MalformedFile, Refusal, TruncatedFile, UnsupportedVersion } from "./errors.js";
import {
  AUDIO_SOURCE_FLAG_LOOP,
  AUDIO_SOURCE_FLAG_SPATIAL,
  HEADER_FLAG_HAS_AUDIO,
} from "./opcodes.js";
import { SH_MAX_BITS, SH_MIN_BITS } from "./sh.js";

/**
 * `0x89 4 D G S 1 CR LF`.
 *
 * The high bit stops byte-oriented tooling treating the file as text; the `1` is the
 * major version; the CR LF catches transports that mangle line endings.
 */
export const MAGIC = new Uint8Array([0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]);

/** The major version this reader implements. */
export const VERSION = 1;

/** Where the major version sits in the magic. Every other byte is a fixed sentinel. */
const VERSION_AT = 5;

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
  // Told apart by whether the version byte is the ONLY difference: every other byte of
  // the magic is a fixed sentinel, so a file that differs elsewhere is not a 4dgs file
  // whatever its version byte happens to say. Testing only `found[1..5] === "4DGS"` — as
  // this did — reported a corrupted first byte as an unsupported version 1, which sends
  // its holder looking for a newer reader that would not have helped. Nothing in the
  // valid corpus can reach this, which is why it survived until the invalid corpus asked.
  const isFourdgs =
    bytesEqual(found.subarray(0, VERSION_AT), MAGIC.subarray(0, VERSION_AT)) &&
    bytesEqual(found.subarray(VERSION_AT + 1), MAGIC.subarray(VERSION_AT + 1));
  if (isFourdgs) {
    throw new UnsupportedVersion(
      `4dgs major version ${String.fromCharCode(found[VERSION_AT]!)} is not supported by this reader`,
      { refusalCode: Refusal.UnsupportedMajorVersion },
    );
  }
  throw new UnsupportedVersion(
    `not a 4dgs file: magic is ${Array.from(found, (b) => b.toString(16).padStart(2, "0")).join(" ")}`,
    { refusalCode: Refusal.MagicMismatch },
  );
}

/** Read one record at the cursor. */
export function readRecord(cursor: Cursor, base = 0): RawRecord {
  const start = cursor.pos;
  const offset = base + start;
  const opcode = cursor.u8();
  const length = cursor.recordLength(offset);
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
  /**
   * Per-band spherical harmonic bit depths, band 1 first, or empty.
   *
   * Appended after the record's original fields, so a file that declares none is
   * byte-identical to one written before the field existed — an empty list is written as
   * no bytes at all, not as a zero count.
   */
  readonly shBitDepths: readonly number[];
  /** True when appended bytes look like an SH depth list but do not frame a legal one. */
  readonly shBitDepthsMalformed: boolean;
}

export function parseQuantization(content: Uint8Array, recordOffset?: number): Quantization {
  const c = new Cursor(content);
  const scheme = c.string();
  const posOrigin = c.f64s(3);
  const stepsAt = c.pos;
  const steps = c.f64s(8);
  const stepTime = steps[6]!;
  if (Number.isFinite(stepTime) && stepTime <= 0) {
    const fieldAt = stepsAt + 6 * 8;
    const value = Object.is(stepTime, -0)
      ? "-0.0"
      : Number.isInteger(stepTime)
        ? `${stepTime}.0`
        : String(stepTime);
    const record =
      recordOffset === undefined
        ? "the Quantization record"
        : `the Quantization record at byte ${recordOffset}`;
    const where =
      recordOffset === undefined
        ? `content byte ${fieldAt}`
        : `byte ${recordOffset + RECORD_HEADER_BYTES + fieldAt}`;
    throw new MalformedFile(
      `${record} has step_time ${value} at ${where}; expected a finite value greater than 0`,
      { refusalCode: Refusal.NonPositiveStepTime },
    );
  }
  const stepSh = c.u8();
  const bounds = c.stringMap();
  const parsedDepths = shBitDepths(c);
  const quantization: Quantization = {
    scheme,
    posOrigin,
    stepPos: steps[0]!,
    stepScaleLog: steps[1]!,
    stepRot: steps[2]!,
    stepRgb: steps[3]!,
    stepAlpha: steps[4]!,
    stepMotion: steps[5]!,
    stepTime,
    stepSigmaLog: steps[7]!,
    stepSh,
    bounds,
    shBitDepths: parsedDepths.values,
    shBitDepthsMalformed: parsedDepths.malformed,
  };
  // `object_id` is an exact label (spec section 6.6), not a metric value, so there is no
  // meaningful error bound between two different labels — section 6.5 makes a bound for it
  // a refusal rather than something to ignore.
  const objectBound = quantization.bounds.get("object_id");
  if (objectBound !== undefined) {
    throw new MalformedFile(
      `Quantization.bounds contains object_id=${JSON.stringify(objectBound)}; ` +
        "object_id is an exact label and MUST NOT carry a bound",
    );
  }
  return quantization;
}

/**
 * Read the appended per-band SH bit depths, or nothing.
 *
 * Deliberately tolerant, exactly as the Python and Rust readers are. Appended fields are
 * positional, so anything sitting after the bounds map lands where this field is —
 * including bytes a *different* newer writer appended, or the arbitrary trailer a
 * forward-compatibility fixture puts there. The declaration describes encoding that
 * already happened and no decoded value depends on it, so a count the record is too short
 * for, or a depth outside the legal range, is read as "this file declares none" rather
 * than as a corrupt file (spec §5.3).
 */
function shBitDepths(c: Cursor): {
  readonly values: readonly number[];
  readonly malformed: boolean;
} {
  if (c.remaining < 1) return { values: [], malformed: false };
  const at = c.pos;
  const count = c.u8();
  if (count === 0) {
    c.pos = at;
    return { values: [], malformed: false };
  }
  if (c.remaining < count) {
    c.pos = at;
    return { values: [], malformed: true };
  }
  const depths: number[] = [];
  for (let i = 0; i < count; i++) depths.push(c.u8());
  if (depths.some((bits) => bits < SH_MIN_BITS || bits > SH_MAX_BITS)) {
    c.pos = at;
    return { values: [], malformed: true };
  }
  return { values: depths, malformed: false };
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
  /**
   * The records blob, exactly as `parseChunk` returns a keyframe's `streams`: still under
   * whatever `header.compression` names. A caller undoes that (honouring
   * `uncompressedSize`) and then frames the three sub-blocks with {@link frameDeltaGroups},
   * so chunk-level compression is handled the same way for both kinds of chunk (§5.18).
   */
  readonly records: Uint8Array;
}

/** A Delta Chunk's three length-framed sub-blocks, updates then births then deaths. */
export interface DeltaGroups {
  readonly updates: Uint8Array;
  readonly births: Uint8Array;
  readonly deaths: Uint8Array;
}

/** A Delta Chunk record (opcode `0x10`, spec §5.18): its header and its raw records blob. */
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
  return { header, records: c.blob() };
}

/**
 * Frame the decompressed records blob into its three sub-blocks (spec §5.18).
 *
 * The order is `updates`, `births`, `deaths`, framed by length rather than tagged per
 * stream, so a reader can take the death list alone by skipping the first two lengths.
 */
export function frameDeltaGroups(records: Uint8Array): DeltaGroups {
  const c = new Cursor(records);
  const updates = c.blob();
  const births = c.blob();
  const deaths = c.blob();
  return { updates, births, deaths };
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

/**
 * The normalized position of `t` between finite, strictly increasing `a` and `b`.
 *
 * Scaling is necessary when the mathematical span is finite but cannot be represented as
 * a double — `-1e308..1e308` is a legal pair of finite samples whose difference is not.
 */
export function interpolationFraction(t: number, a: number, b: number): number {
  const span = b - a;
  if (Number.isFinite(span)) return (t - a) / span;
  const scale = Math.max(Math.abs(a), Math.abs(b));
  return (t / scale - a / scale) / (b / scale - a / scale);
}

/** Interpolate two finite values without overflowing their difference across zero. */
export function finiteLerp(a: number, b: number, u: number): number {
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

// ---------------------------------------------------------------------------
// Provenance family (spec section 5.15)
//
// Four optional records. Absence is the common case and costs nothing: a scene with no
// provenance carries no record, no Header flag, and no empty table. See provenance.ts
// for the arithmetic and the rules that span more than one record.
// ---------------------------------------------------------------------------

/** Pose is expressed in the scene frame. */
export const POSE_TO_SCENE = 0;
/** Pose is expressed relative to a named rig trajectory. */
export const POSE_TO_RIG = 1;

export const TRAJECTORY_LINEAR = 0;
export const TRAJECTORY_STEP = 1;

export const CAMERA_MODEL_NONE = 0;

/**
 * Coefficient counts each camera model defines, keyed by its registry id. A model
 * absent from here is one this build does not know, which is not the same as one that
 * is wrong: `undefined` means "ask the caller", not "refuse".
 */
export const CAMERA_MODEL_COEFFICIENTS: ReadonlyMap<number, readonly number[]> = new Map([
  [0, [0]], // none — the sensor is not a camera
  [1, [0]], // pinhole
  [2, [5, 8]], // brown-conrady, plain or rational
  [3, [4]], // kannala-brandt
]);

/**
 * The frame the file's own coordinates are expressed in. Opcode `0x20`.
 *
 * A fixed shape: every field is always present, so a reader that knows these six knows
 * exactly where an appended seventh would begin.
 */
export interface CoordinateFrame {
  readonly name: string;
  readonly handedness: number;
  readonly upAxis: number;
  readonly forwardAxis: number;
  readonly lengthUnit: number;
  readonly metresPerUnit: number;
}

export function parseCoordinateFrame(content: Uint8Array): CoordinateFrame {
  const c = new Cursor(content);
  const frame: CoordinateFrame = {
    name: c.string(),
    handedness: c.u8(),
    upAxis: c.u8(),
    forwardAxis: c.u8(),
    lengthUnit: c.u8(),
    metresPerUnit: c.f64(),
  };
  checkCoordinateFrame(frame);
  return frame;
}

/** Refuse a frame that is not one, rather than repair it. */
export function checkCoordinateFrame(frame: CoordinateFrame): void {
  for (const [label, axis] of [
    ["up_axis", frame.upAxis],
    ["forward_axis", frame.forwardAxis],
  ] as const) {
    if (axis > 5) {
      throw new MalformedFile(
        `CoordinateFrame ${label} is ${axis}; the registry defines 0..5 (section 5.15.2)`,
      );
    }
  }
  if (frame.upAxis % 3 === frame.forwardAxis % 3) {
    throw new MalformedFile(
      `CoordinateFrame up_axis ${frame.upAxis} and forward_axis ${frame.forwardAxis} ` +
        "name the same axis; a frame needs two different ones (section 5.15.2)",
    );
  }
  if (!Number.isFinite(frame.metresPerUnit) || frame.metresPerUnit < 0) {
    throw new MalformedFile(
      `CoordinateFrame metres_per_unit is ${frame.metresPerUnit}; ` +
        "it must be finite and not negative (section 5.15.2)",
    );
  }
}

/**
 * Where a frame's origin sits on the WGS-84 ellipsoid, and which way it faces.
 * Opcode `0x23`.
 */
export interface GeodeticAnchor {
  readonly frameName: string;
  readonly latitudeDeg: number;
  readonly longitudeDeg: number;
  readonly altitudeM: number;
  readonly headingDeg: number;
}

export function parseGeodeticAnchor(content: Uint8Array): GeodeticAnchor {
  const c = new Cursor(content);
  const frameName = c.string();
  const values = c.f64s(4);
  const anchor: GeodeticAnchor = {
    frameName,
    latitudeDeg: values[0]!,
    longitudeDeg: values[1]!,
    altitudeM: values[2]!,
    headingDeg: values[3]!,
  };
  checkGeodeticAnchor(anchor);
  return anchor;
}

/** Refuse an out-of-range angle rather than wrap it. */
export function checkGeodeticAnchor(anchor: GeodeticAnchor): void {
  for (const [label, value, lo, hi] of [
    ["latitude_deg", anchor.latitudeDeg, -90, 90],
    ["longitude_deg", anchor.longitudeDeg, -180, 180],
    ["altitude_m", anchor.altitudeM, Number.NEGATIVE_INFINITY, Number.POSITIVE_INFINITY],
    ["heading_deg", anchor.headingDeg, 0, 360],
  ] as const) {
    if (!Number.isFinite(value)) {
      throw new MalformedFile(`GeodeticAnchor ${label} is ${value}; every field must be finite`);
    }
    if (value < lo || value > hi || (label === "heading_deg" && value === 360)) {
      throw new MalformedFile(
        `GeodeticAnchor ${label} is ${value}, outside its legal range (section 5.15.5)`,
      );
    }
  }
}

/**
 * One sensor's intrinsics and extrinsics. Opcode `0x21`, one record per sensor.
 *
 * The extrinsic maps sensor coordinates into the frame `poseReference` names:
 * `p_target = R(rotation) * p_sensor + translation`.
 */
export interface SensorCalibration {
  readonly name: string;
  readonly modality: string;
  readonly cameraModel: number;
  readonly widthPx: number;
  readonly heightPx: number;
  readonly fx: number;
  readonly fy: number;
  readonly cx: number;
  readonly cy: number;
  readonly distortion: readonly number[];
  /** Unit quaternion, `xyzw`. */
  readonly rotation: readonly number[];
  readonly translation: readonly number[];
  readonly poseReference: number;
  readonly rigName: string;
}

export function parseSensorCalibration(content: Uint8Array): SensorCalibration {
  const c = new Cursor(content);
  const name = c.string();
  const modality = c.string();
  const cameraModel = c.u8();
  const widthPx = c.u32();
  const heightPx = c.u32();
  const intrinsics = c.f64s(4);
  const distortion = c.f64s(c.u8());
  const rotation = c.f64s(4);
  const translation = c.f64s(3);
  const sensor: SensorCalibration = {
    name,
    modality,
    cameraModel,
    widthPx,
    heightPx,
    fx: intrinsics[0]!,
    fy: intrinsics[1]!,
    cx: intrinsics[2]!,
    cy: intrinsics[3]!,
    distortion,
    rotation,
    translation,
    poseReference: c.u8(),
    rigName: c.string(),
  };
  checkSensorCalibration(sensor);
  return sensor;
}

export function checkSensorCalibration(sensor: SensorCalibration): void {
  const finite = (label: string, value: number): void => {
    if (!Number.isFinite(value)) {
      throw new MalformedFile(
        `sensor ${JSON.stringify(sensor.name)}: ${label} is ${value}; every value must be finite`,
      );
    }
  };
  finite("fx", sensor.fx);
  finite("fy", sensor.fy);
  finite("cx", sensor.cx);
  finite("cy", sensor.cy);
  for (let i = 0; i < sensor.distortion.length; i++)
    finite(`distortion[${i}]`, sensor.distortion[i]!);
  for (let i = 0; i < sensor.rotation.length; i++) finite(`rotation[${i}]`, sensor.rotation[i]!);
  for (let i = 0; i < sensor.translation.length; i++) {
    finite(`translation[${i}]`, sensor.translation[i]!);
  }

  const norm = quaternionNorm(sensor.rotation);
  if (!Number.isFinite(norm) || norm === 0) {
    throw new MalformedFile(
      `sensor ${JSON.stringify(sensor.name)}: rotation quaternion has no direction (norm ${norm})`,
    );
  }

  const legal = CAMERA_MODEL_COEFFICIENTS.get(sensor.cameraModel);
  if (legal !== undefined && !legal.includes(sensor.distortion.length)) {
    throw new MalformedFile(
      `sensor ${JSON.stringify(sensor.name)}: camera model ${sensor.cameraModel} defines ` +
        `${legal.join(" or ")} distortion coefficients, the record carries ${sensor.distortion.length}`,
    );
  }

  const isCamera = sensor.cameraModel !== CAMERA_MODEL_NONE;
  if (!isCamera) {
    for (const [label, value] of [
      ["width_px", sensor.widthPx],
      ["height_px", sensor.heightPx],
      ["fx", sensor.fx],
      ["fy", sensor.fy],
      ["cx", sensor.cx],
      ["cy", sensor.cy],
    ] as const) {
      if (value) {
        throw new MalformedFile(
          `sensor ${JSON.stringify(sensor.name)} declares camera_model 0 but a non-zero ` +
            `${label} (${value})`,
        );
      }
    }
  } else if (sensor.fx === 0 || sensor.fy === 0 || !sensor.widthPx || !sensor.heightPx) {
    throw new MalformedFile(
      `sensor ${JSON.stringify(sensor.name)} declares camera model ${sensor.cameraModel} but ` +
        "has a zero focal length or image size",
    );
  }
}

/** Background / unassigned. A gaussian carrying this id belongs to no object. */
export const BACKGROUND_OBJECT = 0;

/** One object's advisory description. Nothing here transforms a gaussian. */
export interface ObjectTableEntry {
  readonly objectId: number;
  readonly label: string;
  readonly anchor: readonly number[];
  /** `[velocity, angularVelocity, acceleration]`, or `null` when the entry carries none. */
  readonly dynamics: readonly [readonly number[], readonly number[], readonly number[]] | null;
  readonly embedding: readonly number[] | null;
}

/**
 * The scene's one Object Table. Opcode `0x24`.
 *
 * Everything in it is advisory: membership comes from the `object_id` attribute (§6.6)
 * and geometry changes only through an Object Track (§5.15.7). A reader that skips this
 * record still decodes every gaussian correctly; what it loses is the names.
 */
export interface ObjectTable {
  readonly embeddingDim: number;
  readonly entries: readonly ObjectTableEntry[];
}

export function parseObjectTable(content: Uint8Array): ObjectTable {
  const c = new Cursor(content);
  const objectCount = c.u32();
  const embeddingDim = c.u16();
  // Bounded before anything is sized from it, like every other count-prefixed record.
  // The smallest an entry can be is 4 (id) + 4 (empty label) + 12 (anchor) + 1 (dynamics
  // flag), plus one more byte for the embedding flag once a space is declared.
  const minimumEntryBytes = 4 + 4 + 12 + 1 + (embeddingDim > 0 ? 1 : 0);
  if (objectCount * minimumEntryBytes > c.remaining) {
    throw new TruncatedFile(
      `ObjectTable declares ${objectCount} objects (at least ` +
        `${objectCount * minimumEntryBytes} bytes), ${c.remaining} remain`,
    );
  }
  const entries: ObjectTableEntry[] = [];
  for (let i = 0; i < objectCount; i++) {
    const objectId = c.u32();
    const label = c.string();
    const anchor = c.f32s(3);
    const dynamicsPresent = c.u8();
    if (dynamicsPresent > 1) {
      throw new MalformedFile(
        `ObjectTable entry ${i} has dynamics_present ${dynamicsPresent}; it must be 0 or 1 ` +
          "(section 5.15.6)",
      );
    }
    const dynamics =
      dynamicsPresent === 1
        ? ([c.f32s(3), c.f32s(3), c.f32s(3)] as [number[], number[], number[]])
        : null;
    let embedding: number[] | null = null;
    if (embeddingDim > 0) {
      const hasEmbedding = c.u8();
      if (hasEmbedding > 1) {
        throw new MalformedFile(
          `ObjectTable entry ${i} has has_embedding ${hasEmbedding}; it must be 0 or 1 ` +
            "(section 5.15.6)",
        );
      }
      if (hasEmbedding === 1) {
        if (embeddingDim * 4 > c.remaining) {
          throw new TruncatedFile(
            `ObjectTable entry ${i} declares a ${embeddingDim}-dimensional embedding ` +
              `(${embeddingDim * 4} bytes), ${c.remaining} remain`,
          );
        }
        embedding = c.f32s(embeddingDim);
      }
    }
    entries.push({ objectId, label, anchor, dynamics, embedding });
  }
  const table: ObjectTable = { embeddingDim, entries };
  checkObjectTable(table);
  return table;
}

/**
 * Refuse a table that cannot be indexed by id, and values that are not numbers.
 *
 * Two entries for one id make every lookup a coin toss, which is the duplicate-name
 * failure section 5.15.2 refuses for frames and sensors, spelled with integers.
 */
/**
 * Refuse a value that the record's field cannot hold.
 *
 * These ids and dimensions are `u32` and `u16` on the wire, so the parser can only ever
 * produce values inside them. A caller constructing a record can produce `-1`, `1.5` or
 * `2 ** 32`, and nothing downstream would notice: membership is compared as an unsigned
 * integer, so a track keyed by `1.5` composes onto nothing and one keyed by `-1` matches
 * no gaussian while still looking valid. Rust gets this from its types and Python checks
 * it by hand; TypeScript carries `number`, so it checks too.
 */
function checkUnsignedField(value: number, max: number, message: string): void {
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw new MalformedFile(message);
  }
}

/** The largest finite f32, the range every object-table lane is stored in. */
const F32_MAX = 3.4028234663852886e38;

export function checkObjectTable(table: ObjectTable): void {
  checkUnsignedField(
    table.embeddingDim,
    0xffff,
    `ObjectTable embedding_dim is ${table.embeddingDim}; expected an integer in [0, 65535]`,
  );
  const seen = new Set<number>();
  for (const entry of table.entries) {
    checkUnsignedField(
      entry.objectId,
      0xffffffff,
      `ObjectTable entry has object_id ${entry.objectId}; expected an integer in ` +
        "[0, 4294967295]",
    );
    if (seen.has(entry.objectId)) {
      throw new MalformedFile(
        `two ObjectTable entries describe object ${entry.objectId}; entries are referred to ` +
          "by id and nothing else (section 5.15.6)",
      );
    }
    seen.add(entry.objectId);
    // These lanes are stored as f32, so the range is the field's, not the double's.
    // A finite double such as 1e100 fits no conforming record — writing it would
    // round to Infinity — and Python refuses it as `object-value-out-of-f32-range`,
    // so accepting it here would bless a table no other reader can hold.
    const finite = (label: string, values: readonly number[]): void => {
      for (let k = 0; k < values.length; k++) {
        const value = values[k]!;
        if (!Number.isFinite(value)) {
          throw new MalformedFile(
            `ObjectTable entry ${entry.objectId}: ${label}[${k}] is ${value}; every stored ` +
              "value must be finite (section 5.15.6)",
          );
        }
        if (Math.abs(value) > F32_MAX) {
          throw new MalformedFile(
            `ObjectTable entry ${entry.objectId}: ${label}[${k}] is ${value}, outside the ` +
              `finite f32 range [-${F32_MAX}, ${F32_MAX}]`,
          );
        }
      }
    };
    // The wire record carries f32[3] for each of these, so a shorter vector is a shape
    // no conforming file can hold — Rust cannot express it, its fields are [f32; 3].
    // The parser always builds three; a caller constructing a table can hand over two,
    // and every value in it would be checked and accepted.
    const width = (label: string, values: readonly number[]): void => {
      if (values.length !== 3) {
        throw new MalformedFile(
          `ObjectTable entry ${entry.objectId}: ${label} has ${values.length} values, expected 3`,
        );
      }
    };
    width("anchor", entry.anchor);
    finite("anchor", entry.anchor);
    if (entry.dynamics !== null) {
      // The tuple is three vectors when the dynamics flag is set. The type says so, but
      // this is the validator a JavaScript caller reaches, and indexing a short tuple
      // hands `undefined` to the width check — a TypeError from a library, rather than
      // this library naming the object and the field.
      if (entry.dynamics.length !== 3) {
        throw new MalformedFile(
          `ObjectTable entry ${entry.objectId}: dynamics has ${entry.dynamics.length} vectors, ` +
            "expected 3 (velocity, angular_velocity, acceleration)",
        );
      }
      width("velocity", entry.dynamics[0]);
      width("angular_velocity", entry.dynamics[1]);
      width("acceleration", entry.dynamics[2]);
      finite("velocity", entry.dynamics[0]);
      finite("angular_velocity", entry.dynamics[1]);
      finite("acceleration", entry.dynamics[2]);
    }
    // An embedding has to match the space the table declares. `embedding_dim` is
    // declared once for the whole file, so a vector of a different width — or any
    // vector at all when the table declares no embedding space — describes a
    // coordinate system nothing else in the file shares. Python refuses both
    // (`records.py`, "invalid-object-embedding-shape"); the parser cannot build
    // either shape, but a caller constructing a table can.
    if (entry.embedding !== null) {
      if (table.embeddingDim === 0) {
        throw new MalformedFile(
          `object ${entry.objectId}: an embedding is present but embedding_dim is 0`,
        );
      }
      if (entry.embedding.length !== table.embeddingDim) {
        throw new MalformedFile(
          `object ${entry.objectId}: embedding has ${entry.embedding.length} values, ` +
            `embedding_dim declares ${table.embeddingDim}`,
        );
      }
      finite("embedding", entry.embedding);
    }
  }
}

/**
 * One object's rigid pose over the scene clock. Opcode `0x25`, one record per object.
 *
 * Structurally a {@link RigTrajectory} keyed by object id rather than by name, and
 * deliberately so: it satisfies `PoseSampled`, so the clamp-and-slerp of section 5.15.4
 * is the same code for both and cannot drift between them.
 */
export interface ObjectTrack {
  readonly objectId: number;
  readonly interpolation: number;
  readonly times: readonly number[];
  readonly rotations: readonly (readonly number[])[];
  readonly translations: readonly (readonly number[])[];
}

export function parseObjectTrack(content: Uint8Array): ObjectTrack {
  const c = new Cursor(content);
  const objectId = c.u32();
  const interpolation = c.u8();
  const count = c.u32();
  // Each sample is 8 + 32 + 24 = 64 bytes, as for a rig trajectory.
  if (count * 64 > c.remaining) {
    throw new TruncatedFile(
      `ObjectTrack for object ${objectId} declares ${count} samples (${count * 64} bytes), ` +
        `${c.remaining} remain`,
    );
  }
  // The same ceiling a rig trajectory gets, and for the same reason: the streamed decoder
  // buffers a whole non-streamed record before yielding it, so a track is bounded by what
  // one record may ask a reader to allocate rather than by how it arrives. The Dart
  // decoder already refuses past this count.
  if (count > MAX_TRAJECTORY_SAMPLES) {
    throw new MalformedFile(
      `ObjectTrack for object ${objectId} declares ${count} samples, past the ` +
        `${MAX_TRAJECTORY_SAMPLES} ceiling`,
    );
  }
  const times: number[] = [];
  const rotations: number[][] = [];
  const translations: number[][] = [];
  for (let i = 0; i < count; i++) {
    times.push(c.f64());
    rotations.push(c.f64s(4));
    translations.push(c.f64s(3));
  }
  const track: ObjectTrack = { objectId, interpolation, times, rotations, translations };
  // §5.15.7: a zero-sample track "has no pose and is read as absent", so reading one
  // refuses nothing about its pose. The id is not part of the pose — the same section
  // requires every track to refuse object 0 — so that rule holds for an absent track
  // too, and the rest waits for the writer's own checkObjectTrack.
  if (times.length > 0) {
    checkObjectTrack(track);
  } else if (objectId === BACKGROUND_OBJECT) {
    throw new MalformedFile(
      "an ObjectTrack names object 0, which means background / unassigned; a track must " +
        "move an object that exists (section 5.15.7)",
    );
  }
  return track;
}

/**
 * A track's own rules: it moves a real object, and its samples are a function of time.
 *
 * The pose rules are the trajectory's, so they are checked by the trajectory's checker
 * rather than restated — the two records interpolate identically and a second copy of
 * the rule is a second thing to get wrong.
 */
export function checkObjectTrack(track: ObjectTrack): void {
  checkUnsignedField(
    track.objectId,
    0xffffffff,
    `ObjectTrack has object_id ${track.objectId}; expected an integer in [0, 4294967295]`,
  );
  if (track.objectId === BACKGROUND_OBJECT) {
    throw new MalformedFile(
      "an ObjectTrack names object 0, which means background / unassigned; a track must move " +
        "an object that exists (section 5.15.7)",
    );
  }
  // The streamed and indexed readers enforce this before allocating their
  // sample arrays. A caller-authored track has to meet the same ceiling before
  // validation walks the arrays or the writer materializes 64 bytes per row,
  // otherwise this SDK can write a record it refuses to reopen.
  if (track.times.length > MAX_TRAJECTORY_SAMPLES) {
    throw new MalformedFile(
      `ObjectTrack for object ${track.objectId} declares ${track.times.length} samples, past the ` +
        `${MAX_TRAJECTORY_SAMPLES} ceiling`,
    );
  }
  // The trajectory rules iterate each array on its own, so they cannot see a track whose
  // arrays disagree in length — a shape the parser cannot produce but a caller building a
  // record can. Left to them, `poseAt` reads past the short array and the file comes back
  // as a TypeError rather than a MalformedFile. Python and Rust check this before
  // delegating; so does this.
  if (
    track.rotations.length !== track.times.length ||
    track.translations.length !== track.times.length
  ) {
    throw new MalformedFile(
      `track for object ${track.objectId}: ${track.times.length} times, ` +
        `${track.rotations.length} rotations, and ${track.translations.length} translations; ` +
        "every sample needs all three",
    );
  }
  // And each sample has to be the right width. The trajectory rules iterate whatever
  // coordinates are present, so a translation of two numbers passes them and then reads
  // as `undefined` in composition, which writes NaN into the centres rather than
  // refusing. Rust cannot express this — its samples are [f64; 4] and [f64; 3] — and
  // Python names it; here it has to be checked.
  for (let i = 0; i < track.times.length; i++) {
    if (track.rotations[i]!.length !== 4) {
      throw new MalformedFile(
        `track for object ${track.objectId}: sample ${i} rotation has ` +
          `${track.rotations[i]!.length} values, expected 4`,
      );
    }
    if (track.translations[i]!.length !== 3) {
      throw new MalformedFile(
        `track for object ${track.objectId}: sample ${i} translation has ` +
          `${track.translations[i]!.length} values, expected 3`,
      );
    }
  }
  checkRigTrajectory({
    name: `object ${track.objectId}`,
    interpolation: track.interpolation,
    times: track.times,
    rotations: track.rotations,
    translations: track.translations,
  });
}

/**
 * The measured pose of the capture platform over the scene clock. Opcode `0x22`.
 *
 * Not the Camera record of section 5.10, which is a viewing suggestion a reader may
 * ignore. This is where the sensors were.
 */
export interface RigTrajectory {
  readonly name: string;
  readonly interpolation: number;
  readonly times: readonly number[];
  readonly rotations: readonly (readonly number[])[];
  readonly translations: readonly (readonly number[])[];
}

/**
 * The most samples one trajectory may declare.
 *
 * Not a format limit — the format states none — but a ceiling on what a single record can
 * cost a reader, matching the Dart decoder's. A million samples is a ten-minute capture at
 * more than 1.5 kHz, well past any real rig, and each one becomes 64 bytes of decoded
 * arrays here.
 *
 * Sized to stay under the 64 MiB front-matter range cap the indexed readers enforce: at 64
 * bytes a sample this is 64 MB of samples, leaving room for the name, the count and the
 * record framing. `1 << 20` would have been 64 MiB of samples *exactly*, so a trajectory at
 * the ceiling would parse on the streamed path and be refused on the indexed one — the same
 * file, two answers from one SDK.
 */
export const MAX_TRAJECTORY_SAMPLES = 1_000_000;

export function parseRigTrajectory(content: Uint8Array): RigTrajectory {
  const c = new Cursor(content);
  const name = c.string();
  const interpolation = c.u8();
  const count = c.u32();
  // Bounded like the other count-prefixed records: a crafted count must not size an
  // allocation before the bytes behind it have been shown to exist. Each sample is
  // 8 + 32 + 24 = 64 bytes.
  if (count * 64 > c.remaining) {
    throw new TruncatedFile(
      `trajectory ${JSON.stringify(name)} declares ${count} samples (${count * 64} bytes), ` +
        `${c.remaining} remain`,
    );
  }
  if (count > MAX_TRAJECTORY_SAMPLES) {
    throw new MalformedFile(
      `trajectory ${JSON.stringify(name)} declares ${count} samples, past the ` +
        `${MAX_TRAJECTORY_SAMPLES} ceiling`,
    );
  }
  const times: number[] = [];
  const rotations: number[][] = [];
  const translations: number[][] = [];
  for (let i = 0; i < count; i++) {
    times.push(c.f64());
    rotations.push(c.f64s(4));
    translations.push(c.f64s(3));
  }
  const trajectory: RigTrajectory = { name, interpolation, times, rotations, translations };
  // §5.15.4: a trajectory with no samples "MUST be read as though the record were
  // absent", so reading one refuses nothing — not even an interpolation byte outside the
  // registry, which describes how to read samples it does not carry. The check stays
  // strict for the writer, which must not emit such a record.
  if (trajectory.times.length > 0) checkRigTrajectory(trajectory);
  return trajectory;
}

/**
 * Refuse times that are not strictly increasing, naming the sample.
 *
 * Every interpolation rule is stated in terms of the interval a query lands in, and a
 * repeated or reversed timestamp makes that interval ambiguous.
 */
/**
 * The Euclidean norm of a quaternion, computed without squaring the components first.
 *
 * A component near the top of the double range squares to Infinity, so the naive sum
 * reports an infinite norm for a rotation whose norm is finite and whose direction is
 * perfectly good. Section 5.15.4 refuses "zero or non-finite norms" — a statement about
 * the quaternion, not about the arithmetic used to measure it. Dividing by the largest
 * magnitude first makes the sum safe and leaves the direction untouched.
 */
export function quaternionNorm(q: readonly number[]): number {
  let scale = 0;
  for (const v of q) {
    const m = Math.abs(v);
    if (m > scale) scale = m;
  }
  // Left for the caller to refuse, with the message it words for its own record.
  if (!Number.isFinite(scale) || scale === 0) return scale;
  let sum = 0;
  for (const v of q) {
    const u = v / scale;
    sum += u * u;
  }
  return scale * Math.sqrt(sum);
}

export function checkRigTrajectory(trajectory: RigTrajectory): void {
  if (
    trajectory.interpolation !== TRAJECTORY_LINEAR &&
    trajectory.interpolation !== TRAJECTORY_STEP
  ) {
    throw new MalformedFile(
      `trajectory ${JSON.stringify(trajectory.name)} uses interpolation ${trajectory.interpolation}; ` +
        "this reader supports trajectory interpolation registry values 0 (linear) and 1 (step)",
    );
  }
  for (let i = 0; i < trajectory.times.length; i++) {
    const t = trajectory.times[i]!;
    if (!Number.isFinite(t)) {
      throw new MalformedFile(
        `trajectory ${JSON.stringify(trajectory.name)}: sample ${i} has a non-finite time (${t})`,
      );
    }
    if (i > 0 && t <= trajectory.times[i - 1]!) {
      throw new MalformedFile(
        `trajectory ${JSON.stringify(trajectory.name)}: sample ${i} is at t=${t}, not after ` +
          `sample ${i - 1} at t=${trajectory.times[i - 1]}; times must strictly increase ` +
          "(section 5.15.4)",
      );
    }
  }
  for (let i = 0; i < trajectory.rotations.length; i++) {
    const q = trajectory.rotations[i]!;
    const norm = quaternionNorm(q);
    if (!Number.isFinite(norm) || norm === 0) {
      throw new MalformedFile(
        `trajectory ${JSON.stringify(trajectory.name)}: sample ${i} rotation has no direction ` +
          `(norm ${norm})`,
      );
    }
  }
  for (let i = 0; i < trajectory.translations.length; i++) {
    const tr = trajectory.translations[i]!;
    for (let k = 0; k < tr.length; k++) {
      const value = tr[k]!;
      if (!Number.isFinite(value)) {
        throw new MalformedFile(
          `trajectory ${JSON.stringify(trajectory.name)}: sample ${i} translation[${k}] is ${value}`,
        );
      }
    }
  }
}
