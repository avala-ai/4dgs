// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The encoder.
 *
 * A native TypeScript encoder, not a binding: browser-side authoring is the point, so this
 * mirrors the reference encoder's arithmetic rather than calling into it. It quantizes every
 * attribute onto the grids the Quantization record declares, partitions gaussians into a
 * temporal chunk tree, frames the records, and writes an index, a summary and a CRC.
 *
 * What makes two independent encoders interchangeable is that a decoder cannot tell their
 * output apart once decoded: the quantization here lands on the same integer bins the Rust
 * and Python encoders do, so the decoded values agree to the last bit, and the chunk tree is
 * the same deterministic partition, so the seek intervals agree too. Byte layout — which
 * order gaussians sit in a chunk, how well `deflate` did — is an encoder's own business and
 * is not part of what the file means.
 *
 * `deflate` is reached through {@link CompressionStream}, the mirror of the decoder's
 * {@link DecompressionStream}, so the encoder carries no dependency and runs in a browser.
 */

import { crc32 } from "./codec.js";
import { MAX_FRONT_MATTER_BYTES } from "./indexedDecoder.js";
import type { ObjectLayer } from "./objects.js";
import {
  checkObjectTable,
  checkObjectTrack,
  RECORD_HEADER_BYTES,
  type ObjectTable,
  type ObjectTrack,
} from "./records.js";
import { SH_MAX_BITS, SH_MIN_BITS, bandCoefficientRange, shBound, shStep } from "./sh.js";

/** The gaussians to encode, structure-of-arrays — the shape a decoder hands back. */
export interface GaussianInput {
  readonly count: number;
  readonly positions: Float32Array | number[]; // count × 3
  readonly scales: Float32Array | number[]; // count × 3
  readonly rotations: Float32Array | number[]; // count × 4, xyzw
  readonly colors: Float32Array | number[]; // count × 4, linear RGB + alpha
  readonly motions: Float32Array | number[]; // count × 3
  readonly muT: Float32Array | number[]; // count
  readonly sigmaT: Float32Array | number[]; // count; +Infinity never fades
  readonly winLo: Float32Array | number[]; // count
  readonly winHi: Float32Array | number[]; // count
  /** count × 3 × shCoefficients, component-major, or null. */
  readonly sh?: Uint8Array | null;
  readonly shDegree?: number;
  readonly shCoefficients?: number;
  /** Exact per-gaussian object membership, or null when the scene has no object layer. */
  readonly objectId?: Uint32Array | readonly number[] | null;
}

/** How a scene is written. The defaults are the reference encoder's own. */
export interface WriteOptions {
  cutoff?: number;
  maxDepth?: number;
  minChunkGaussians?: number;
  writeIndex?: boolean;
  writeStatistics?: boolean;
  writeSummaryOffsets?: boolean;
  writeCrc?: boolean;
  shBands?: number;
  /** Per-band bit depths, band 1 first. Empty leaves coefficients as the profile decides. */
  shBitDepths?: number[];
  profile?: string;
  library?: string;
  attributes?: Record<string, string>;
  /** The Object Table and optional SE(3) tracks to write. */
  objects?: ObjectLayer | null;
}

// Opcodes and attribute ids (spec §4.2, §6.1).
const OP_HEADER = 0x01;
const OP_FOOTER = 0x02;
const OP_QUANTIZATION = 0x03;
const OP_WINDOW_TABLE = 0x04;
const OP_CHUNK = 0x05;
const OP_SH_BAND_STREAM = 0x07;
const OP_CHUNK_INDEX = 0x08;
const OP_STATISTICS = 0x0c;
const OP_SUMMARY_OFFSET = 0x0f;
const OP_OBJECT_TABLE = 0x24;
const OP_OBJECT_TRACK = 0x25;

const A_POSITION = 0;
const A_SCALE = 1;
const A_ROTATION_INDEX = 2;
const A_ROTATION = 3;
const A_COLOR = 4;
const A_OPACITY = 5;
const A_MOTION = 6;
const A_MU_T = 7;
const A_SIGMA_T = 8;
const A_FLAGS = 9;
const A_WINDOW_INDEX = 10;
const A_OBJECT_ID = 14;

const CODEC_DEFLATE = 0;
const MODE_RAW = 0;

const MAGIC = new Uint8Array([0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]);

// Grid constants (spec §6.3, §6.5), matching quantization.ts and the Rust core.
const LIFE_REF = 0.5;
const LIFE_MIN_CLASS = -4;
const LIFE_MAX_CLASS = 2;
const LIFE_HALF_MIN = 0.02;
const LIFE_HALF_MAX = 2.0;
const MU_REL = 0.05;
const MU_MIN_CLASS = -10;

/** The default profile's error bounds and the grid pitches they imply. */
interface Grid {
  origin: [number, number, number];
  stepPos: number;
  stepScaleLog: number;
  stepRot: number;
  stepRgb: number;
  stepAlpha: number;
  stepMotion: number;
  stepTime: number;
  stepSigmaLog: number;
  boundPos: number;
}

function supportK(cutoff: number): number {
  return Math.sqrt(-2 * Math.log(cutoff));
}

/**
 * Round half to even, the rule every attribute grid but rotation uses.
 *
 * @internal shared with the `keyframe-delta` writer, so one arithmetic serves both
 * encoders. Not part of the package's API.
 */
export function rint(v: number): number {
  const nearest = v < 0 ? -Math.round(-v) : Math.round(v); // half away from zero
  const frac = Math.abs(v - Math.trunc(v));
  if (frac === 0.5 && nearest % 2 !== 0) {
    return nearest - Math.sign(v);
  }
  return nearest;
}

/** Round half away from zero, which the rotation grid uses (matching the Rust `.round()`). */
function roundTiesAway(v: number): number {
  return v >= 0 ? Math.floor(v + 0.5) : Math.ceil(v - 0.5);
}

/** The median of a slice, the way NumPy takes it. @internal */
export function median(values: ArrayLike<number>): number {
  const n = values.length;
  if (n === 0) return 1e-3;
  const sorted = Array.from(values, (v) => v).sort((a, b) => a - b);
  const mid = n >> 1;
  return n % 2 === 1 ? sorted[mid]! : 0.5 * (sorted[mid - 1]! + sorted[mid]!);
}

function lifeHalf(
  sigmaBin: number,
  sigmaLogStep: number,
  neverFades: boolean,
  windowLen: number,
  k: number,
): number {
  const sigma = Math.exp(sigmaBin * sigmaLogStep);
  const half = neverFades ? windowLen : k * sigma;
  return Math.min(Math.max(half, LIFE_HALF_MIN), LIFE_HALF_MAX);
}

function lifeClass(
  sigmaBin: number,
  sigmaLogStep: number,
  neverFades: boolean,
  windowLen: number,
  k: number,
): number {
  const half = lifeHalf(sigmaBin, sigmaLogStep, neverFades, windowLen, k);
  return Math.min(Math.max(Math.ceil(Math.log2(half / LIFE_REF)), LIFE_MIN_CLASS), LIFE_MAX_CLASS);
}

function motionStep(cls: number, stepRef: number): number {
  return stepRef * Math.pow(2, -cls);
}

function muStep(
  sigmaBin: number,
  sigmaLogStep: number,
  neverFades: boolean,
  stepRef: number,
): number {
  const sigma = Math.exp(sigmaBin * sigmaLogStep);
  const target = neverFades ? stepRef : Math.min(stepRef, MU_REL * sigma);
  const cls = Math.min(Math.max(Math.floor(Math.log2(target / stepRef)), MU_MIN_CLASS), 0);
  return stepRef * Math.pow(2, cls);
}

const REST: readonly (readonly [number, number, number])[] = [
  [1, 2, 3],
  [0, 2, 3],
  [0, 1, 3],
  [0, 1, 2],
];

/**
 * The forward smallest-three quaternion transform: largest index and three residual bins.
 *
 * @internal Ties round away from zero, which is the Rust reference's rule; Python's
 * `quantize_rotation` reaches for `np.rint` and rounds them to even. The two disagree only
 * on a residual that lands exactly on a half-step, and both encoders here take the Rust
 * rule so that one SDK does not hold two opinions about the same input.
 */
export function quantizeRotation(
  q0: number,
  q1: number,
  q2: number,
  q3: number,
  step: number,
): [number, [number, number, number]] {
  const norm = Math.max(Math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3), 1e-30);
  const q = [q0 / norm, q1 / norm, q2 / norm, q3 / norm];
  let largest = 0;
  for (let i = 1; i < 4; i++) if (Math.abs(q[i]!) > Math.abs(q[largest]!)) largest = i;
  const sign = q[largest]! < 0 ? -1 : 1;
  const rest = REST[largest]!;
  const bins: [number, number, number] = [
    roundTiesAway((q[rest[0]]! * sign) / step),
    roundTiesAway((q[rest[1]]! * sign) / step),
    roundTiesAway((q[rest[2]]! * sign) / step),
  ];
  return [largest, bins];
}

/** The forward reversible colour transform: store `(g, r - g, b - g)`. @internal */
export function rctForward(r: number, g: number, b: number): [number, number, number] {
  return [g, r - g, b - g];
}

/** Round one coefficient byte onto the grid `bits` names, at bin centres. */
function quantizeSh(value: number, bits: number): number {
  const step = shStep(bits);
  if (step === 1) return value;
  return Math.floor(value / step) * step + (step >> 1);
}

// --- little-endian byte writer -------------------------------------------

/** @internal a little-endian byte sink, shared by both encoders. */
export class ByteWriter {
  private buf: Uint8Array;
  private view: DataView;
  private len = 0;

  constructor(capacity = 1024) {
    this.buf = new Uint8Array(capacity);
    this.view = new DataView(this.buf.buffer);
  }

  private ensure(extra: number): void {
    if (this.len + extra <= this.buf.length) return;
    let next = this.buf.length * 2;
    while (next < this.len + extra) next *= 2;
    const grown = new Uint8Array(next);
    grown.set(this.buf.subarray(0, this.len));
    this.buf = grown;
    this.view = new DataView(this.buf.buffer);
  }

  get length(): number {
    return this.len;
  }

  u8(v: number): void {
    this.ensure(1);
    this.buf[this.len++] = v & 0xff;
  }

  u16(v: number): void {
    this.ensure(2);
    this.view.setUint16(this.len, v & 0xffff, true);
    this.len += 2;
  }

  u32(v: number): void {
    this.ensure(4);
    this.view.setUint32(this.len, v >>> 0, true);
    this.len += 4;
  }

  u64(v: number): void {
    this.ensure(8);
    this.view.setBigUint64(this.len, BigInt(v), true);
    this.len += 8;
  }

  f64(v: number): void {
    this.ensure(8);
    this.view.setFloat64(this.len, v, true);
    this.len += 8;
  }

  f32(v: number): void {
    this.ensure(4);
    this.view.setFloat32(this.len, v, true);
    this.len += 4;
  }

  bytes(b: Uint8Array): void {
    this.ensure(b.length);
    this.buf.set(b, this.len);
    this.len += b.length;
  }

  string(s: string): void {
    const encoded = new TextEncoder().encode(s);
    this.u32(encoded.length);
    this.bytes(encoded);
  }

  blob(b: Uint8Array): void {
    this.u64(b.length);
    this.bytes(b);
  }

  finish(): Uint8Array {
    return this.buf.subarray(0, this.len);
  }
}

/** A sorted-key string map, matching the Rust `put_str_map` a determinism gate depends on. @internal */
export function putStrMap(w: ByteWriter, map: Record<string, string>): void {
  const body = new ByteWriter();
  for (const key of Object.keys(map).sort()) {
    body.string(key);
    body.string(map[key]!);
  }
  const bytes = body.finish();
  w.u32(bytes.length);
  w.bytes(bytes);
}

/** @internal one opcode-tagged, length-prefixed record. */
export function record(opcode: number, content: Uint8Array): Uint8Array {
  const w = new ByteWriter(content.length + 9);
  w.u8(opcode);
  w.u64(content.length);
  w.bytes(content);
  return w.finish();
}

// --- stream encoding ------------------------------------------------------

function zigzag(v: number): number {
  return v >= 0 ? v * 2 : -v * 2 - 1;
}

async function deflate(raw: Uint8Array): Promise<Uint8Array> {
  const stream = new CompressionStream("deflate");
  const writer = stream.writable.getWriter();
  const written = (async () => {
    await writer.write(raw);
    await writer.close();
  })();
  const chunks: Uint8Array[] = [];
  const reader = stream.readable.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  await written;
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/**
 * One attribute stream: raw mode, zigzag, the narrowest symbol width that fits, byte-plane
 * shuffle, deflate.
 *
 * Raw mode alone, deliberately: delta and constant modes only shrink the payload, and a
 * decoder reads all three, so the encoded values a decoder sees are identical whichever is
 * chosen. Picking the smallest is a size optimization this encoder forgoes for simplicity —
 * what it must get exactly right is the decoded integers, not the byte count.
 */
export async function encodeStream(
  attributeId: number,
  values: number[],
  channels: number,
): Promise<Uint8Array> {
  const count = values.length / channels;
  const header = new ByteWriter(17);
  if (count === 0) {
    header.u8(attributeId);
    header.u8(1); // width
    header.u8(MODE_RAW);
    header.u8(CODEC_DEFLATE);
    header.u8(channels);
    header.u32(0);
    header.u64(0);
    return header.finish();
  }

  const zig = values.map(zigzag);
  let max = 0;
  for (const z of zig) if (z > max) max = z;
  const width = max <= 0xff ? 1 : max <= 0xffff ? 2 : 4;
  if (max > 0xffffffff) {
    throw new Error(`symbol ${max} exceeds 32 bits; the error bound is too tight for this data`);
  }

  const n = zig.length;
  const raw = new Uint8Array(n * width);
  if (width === 1) {
    for (let i = 0; i < n; i++) raw[i] = zig[i]! & 0xff;
  } else {
    for (let j = 0; j < width; j++) {
      const shift = Math.pow(2, 8 * j);
      for (let i = 0; i < n; i++) raw[j * n + i] = Math.floor(zig[i]! / shift) % 256;
    }
  }
  const payload = await deflate(raw);

  header.u8(attributeId);
  header.u8(width);
  header.u8(MODE_RAW);
  header.u8(CODEC_DEFLATE);
  header.u8(channels);
  header.u32(count);
  header.u64(payload.length);
  const head = header.finish();
  const out = new Uint8Array(head.length + payload.length);
  out.set(head, 0);
  out.set(payload, head.length);
  return out;
}

// --- quantization ---------------------------------------------------------

interface Quantized {
  grid: Grid;
  steps: { sigmaLog: number };
  pos: number[]; // count × 3
  scale: number[]; // count × 3
  rotationIndex: number[]; // count
  rotation: number[]; // count × 3
  rgb: number[]; // count × 3
  alpha: number[]; // count
  motion: number[]; // count × 3
  mu: number[]; // count
  sigma: number[]; // count
  flags: number[]; // count
  windowIndex: number[]; // count
  windows: [number, number][];
}

function ln1p(x: number): number {
  return Math.log1p(x);
}

function buildGrid(g: GaussianInput): Grid {
  const n = g.count;
  const medianScale = n === 0 ? 1e-3 : median(g.scales);
  const boundPos = 0.05 * medianScale;
  const boundRgb = 1.0 / 255;
  const origin: [number, number, number] = [Infinity, Infinity, Infinity];
  if (n > 0) {
    for (let i = 0; i < n; i++) {
      for (let a = 0; a < 3; a++) origin[a] = Math.min(origin[a]!, g.positions[i * 3 + a]!);
    }
  } else {
    origin[0] = origin[1] = origin[2] = 0;
  }
  return {
    origin,
    stepPos: 2 * boundPos,
    stepScaleLog: 2 * ln1p(0.02),
    stepRot: 2 * 0.002,
    stepRgb: 2 * boundRgb,
    stepAlpha: 2 * boundRgb,
    stepMotion: 2 * (boundPos / LIFE_REF),
    stepTime: 2 * 0.002,
    stepSigmaLog: 2 * ln1p(0.02),
    boundPos,
  };
}

function windowTable(g: GaussianInput): { windows: [number, number][]; index: number[] } {
  const seen = new Map<string, number>();
  const distinct: [number, number][] = [];
  for (let i = 0; i < g.count; i++) {
    const lo = g.winLo[i]!;
    const hi = g.winHi[i]!;
    const key = `${lo},${hi}`;
    if (!seen.has(key)) {
      seen.set(key, distinct.length);
      distinct.push([lo, hi]);
    }
  }
  distinct.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const rank = new Map<string, number>();
  distinct.forEach(([lo, hi], i) => rank.set(`${lo},${hi}`, i));
  const index = new Array<number>(g.count);
  for (let i = 0; i < g.count; i++) index[i] = rank.get(`${g.winLo[i]!},${g.winHi[i]!}`)!;
  return { windows: distinct.length > 0 ? distinct : [[0, 0]], index };
}

function quantizeScene(g: GaussianInput, cutoff: number): Quantized {
  const grid = buildGrid(g);
  const k = supportK(cutoff);
  const { windows, index } = windowTable(g);
  const q: Quantized = {
    grid,
    steps: { sigmaLog: grid.stepSigmaLog },
    pos: [],
    scale: [],
    rotationIndex: [],
    rotation: [],
    rgb: [],
    alpha: [],
    motion: [],
    mu: [],
    sigma: [],
    flags: [],
    windowIndex: [],
    windows,
  };

  for (let i = 0; i < g.count; i++) {
    for (let a = 0; a < 3; a++) {
      q.pos.push(rint((g.positions[i * 3 + a]! - grid.origin[a]!) / grid.stepPos));
      q.scale.push(rint(Math.log(Math.max(g.scales[i * 3 + a]!, 1e-30)) / grid.stepScaleLog));
    }
    const [largest, bins] = quantizeRotation(
      g.rotations[i * 4]!,
      g.rotations[i * 4 + 1]!,
      g.rotations[i * 4 + 2]!,
      g.rotations[i * 4 + 3]!,
      grid.stepRot,
    );
    q.rotationIndex.push(largest);
    q.rotation.push(bins[0], bins[1], bins[2]);

    const rgb = rctForward(
      rint(g.colors[i * 4]! / grid.stepRgb),
      rint(g.colors[i * 4 + 1]! / grid.stepRgb),
      rint(g.colors[i * 4 + 2]! / grid.stepRgb),
    );
    q.rgb.push(rgb[0], rgb[1], rgb[2]);
    q.alpha.push(rint(g.colors[i * 4 + 3]! / grid.stepAlpha));

    const neverFades = !Number.isFinite(g.sigmaT[i]!);
    const sigmaBin = neverFades
      ? 0
      : rint(Math.log(Math.max(g.sigmaT[i]!, 1e-30)) / grid.stepSigmaLog);
    q.sigma.push(sigmaBin);
    q.flags.push(neverFades ? 1 : 0);
    q.windowIndex.push(index[i]!);

    const [lo, hi] = windows[index[i]!]!;
    const cls = lifeClass(sigmaBin, grid.stepSigmaLog, neverFades, hi - lo, k);
    const mStep = motionStep(cls, grid.stepMotion);
    for (let a = 0; a < 3; a++) q.motion.push(rint(g.motions[i * 3 + a]! / mStep));
    const tStep = muStep(sigmaBin, grid.stepSigmaLog, neverFades, grid.stepTime);
    q.mu.push(rint(g.muT[i]! / tStep));
  }
  return q;
}

// --- the temporal chunk tree (spec §5.6) ----------------------------------

interface Plan {
  t0: number;
  t1: number;
  level: number;
  members: number[];
}

function support(g: GaussianInput, cutoff: number): { lo: number[]; hi: number[] } {
  const k = supportK(cutoff);
  const lo = new Array<number>(g.count);
  const hi = new Array<number>(g.count);
  for (let i = 0; i < g.count; i++) {
    const sigma = g.sigmaT[i]!;
    const mu = g.muT[i]!;
    const half = Number.isFinite(sigma) ? k * sigma : Infinity;
    lo[i] = Math.max(mu - half, g.winLo[i]!);
    hi[i] = Math.min(mu + half, g.winHi[i]!);
  }
  return { lo, hi };
}

function planChunks(
  lo: number[],
  hi: number[],
  tops: number[],
  maxDepth: number,
  minGaussians: number,
): Plan[] {
  const n = lo.length;
  const assigned = new Array<number>(n).fill(-1);
  const nodes: [number, number, number][] = [];

  function descend(a: number, b: number, level: number, pool: number[]): number[] {
    if (pool.length === 0 || level >= maxDepth) return pool;
    const mid = 0.5 * (a + b);
    const stay: number[] = [];
    const left: number[] = [];
    const right: number[] = [];
    for (const i of pool) {
      if (hi[i]! <= mid) left.push(i);
      else if (lo[i]! >= mid) right.push(i);
      else stay.push(i);
    }
    for (const [ca, cb, child] of [[a, mid, left] as const, [mid, b, right] as const]) {
      if (child.length < minGaussians) {
        for (const i of child) stay.push(i);
        continue;
      }
      const kept = descend(ca, cb, level + 1, child);
      if (kept.length > 0) {
        nodes.push([ca, cb, level + 1]);
        const node = nodes.length - 1;
        for (const i of kept) assigned[i] = node;
      }
    }
    stay.sort((x, y) => x - y);
    return stay;
  }

  for (let w = 0; w + 1 < tops.length; w++) {
    const a = tops[w]!;
    const b = tops[w + 1]!;
    const pool: number[] = [];
    for (let i = 0; i < n; i++) {
      if (lo[i]! >= a - 1e-9 && hi[i]! <= b + 1e-9 && assigned[i] === -1) pool.push(i);
    }
    const kept = descend(a, b, 0, pool);
    if (kept.length > 0) {
      nodes.push([a, b, 0]);
      const node = nodes.length - 1;
      for (const i of kept) assigned[i] = node;
    }
  }

  const rest: number[] = [];
  for (let i = 0; i < n; i++) if (assigned[i] === -1) rest.push(i);
  if (rest.length > 0) {
    nodes.push([tops[0]!, tops[tops.length - 1]!, -1]);
    const node = nodes.length - 1;
    for (const i of rest) assigned[i] = node;
  }

  const plans: Plan[] = [];
  nodes.forEach(([a, b, level], node) => {
    const members: number[] = [];
    for (let i = 0; i < n; i++) if (assigned[i] === node) members.push(i);
    if (members.length > 0) plans.push({ t0: a, t1: b, level: Math.max(level, 0), members });
  });
  plans.sort((x, y) => x.level - y.level || x.t0 - y.t0);
  return plans;
}

// --- the whole file -------------------------------------------------------

function aabb(g: GaussianInput): number[] {
  if (g.count === 0) return [0, 0, 0, 0, 0, 0];
  const out = [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity];
  for (let i = 0; i < g.count; i++) {
    for (let a = 0; a < 3; a++) {
      const v = g.positions[i * 3 + a]!;
      out[a] = Math.min(out[a]!, v);
      out[3 + a] = Math.max(out[3 + a]!, v);
    }
  }
  return out;
}

function gather(values: number[], members: number[], channels: number): number[] {
  const out: number[] = [];
  for (const i of members) for (let c = 0; c < channels; c++) out.push(values[i * channels + c]!);
  return out;
}

function checkedObjectIds(g: GaussianInput): ArrayLike<number> | null {
  const ids = g.objectId ?? null;
  if (ids === null) return null;
  if (ids.length !== g.count) {
    throw new Error(`object_id has ${ids.length} values, expected ${g.count}`);
  }
  for (let i = 0; i < ids.length; i++) {
    const value = ids[i]!;
    if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
      throw new Error(`object_id[${i}] is ${value}; expected an exact integer in [0, 4294967295]`);
    }
  }
  return ids;
}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      const low = value.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4;
        i++;
      } else {
        bytes += 3; // TextEncoder replaces a lone surrogate with U+FFFD.
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function checkObjectTableRecordSize(table: ObjectTable): void {
  let framedBytes = RECORD_HEADER_BYTES + 4 + 2;
  const add = (bytes: number, objectId: number): void => {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > MAX_FRONT_MATTER_BYTES - framedBytes) {
      throw new Error(
        `ObjectTable record exceeds the ${MAX_FRONT_MATTER_BYTES} byte indexed ` +
          `front-matter ceiling while encoding object ${objectId}`,
      );
    }
    framedBytes += bytes;
  };

  for (const entry of table.entries) {
    add(4 + 4 + utf8ByteLength(entry.label), entry.objectId); // object_id and label
    add(entry.anchor.length * 4 + 1, entry.objectId); // anchor and dynamics flag
    if (entry.dynamics !== null) {
      for (const vector of entry.dynamics) add(vector.length * 4, entry.objectId);
    }
    if (table.embeddingDim > 0) {
      add(1, entry.objectId); // has_embedding
      if (entry.embedding !== null) add(entry.embedding.length * 4, entry.objectId);
    }
  }
}

function encodeObjectTable(table: ObjectTable): Uint8Array {
  checkObjectTable(table);
  const body = new ByteWriter();
  body.u32(table.entries.length);
  body.u16(table.embeddingDim);
  for (const entry of table.entries) {
    body.u32(entry.objectId);
    body.string(entry.label);
    for (const value of entry.anchor) body.f32(value);
    body.u8(entry.dynamics === null ? 0 : 1);
    if (entry.dynamics !== null) {
      for (const vector of entry.dynamics) for (const value of vector) body.f32(value);
    }
    if (table.embeddingDim > 0) {
      body.u8(entry.embedding === null ? 0 : 1);
      if (entry.embedding !== null) for (const value of entry.embedding) body.f32(value);
    }
  }
  return record(OP_OBJECT_TABLE, body.finish());
}

function encodeObjectTrack(track: ObjectTrack): Uint8Array {
  checkObjectTrack(track);
  const body = new ByteWriter();
  body.u32(track.objectId);
  body.u8(track.interpolation);
  body.u32(track.times.length);
  for (let i = 0; i < track.times.length; i++) {
    body.f64(track.times[i]!);
    for (const value of track.rotations[i]!) body.f64(value);
    for (const value of track.translations[i]!) body.f64(value);
  }
  return record(OP_OBJECT_TRACK, body.finish());
}

/**
 * Encode a set of gaussians into a `.4dgs` byte buffer.
 *
 * Async because `deflate` is: the runtime's compressor is a stream. The result is a complete
 * file — magic, header, quantization, the chunk tree, an optional index and summary, a footer.
 */
export async function encodeScene(
  gaussians: GaussianInput,
  durationSec: number,
  options: WriteOptions = {},
): Promise<Uint8Array> {
  const cutoff = options.cutoff ?? 0.05;
  const maxDepth = options.maxDepth ?? 6;
  const minChunk = options.minChunkGaussians ?? 2048;
  const writeIndex = options.writeIndex ?? true;
  const writeStatistics = options.writeStatistics ?? false;
  const writeSummaryOffsets = options.writeSummaryOffsets ?? false;
  const writeCrc = options.writeCrc ?? true;
  const shBands = options.shBands ?? 3;
  const shBitDepths = options.shBitDepths ?? [];
  const profile = options.profile ?? "";
  const library = options.library ?? "4dgs-typescript encoder";
  const attributes = options.attributes ?? {};
  const objects = options.objects ?? null;

  const n = gaussians.count;
  const objectIds = checkedObjectIds(gaussians);
  if (profile === "objects") {
    if (n > 0 && objectIds === null) {
      throw new Error(
        "the objects profile requires an object_id stream in every non-empty chunk, " +
          "but the GaussianInput carries none",
      );
    }
    if (objects?.table == null) {
      throw new Error("the objects profile requires one ObjectTable record, but none was supplied");
    }
  }
  if (objects !== null) {
    objects.check();
    if (objects.table !== null) {
      // The indexed object path applies this ceiling before allocating a record
      // from its declared range. Enforce the same bound from lengths alone before
      // validation walks an embedding or the writer materializes its bytes.
      checkObjectTableRecordSize(objects.table);
      checkObjectTable(objects.table);
    }
    for (const track of objects.tracks) checkObjectTrack(track);
  }
  const q = quantizeScene(gaussians, cutoff);

  // Window boundaries are the top level of the partition.
  const tops = new Set<number>([0, durationSec]);
  for (const [lo, hi] of q.windows) {
    for (const v of [lo, hi]) if (v > 0 && v < durationSec) tops.add(v);
  }
  let topsArr = Array.from(tops).sort((a, b) => a - b);
  if (topsArr.length < 2) topsArr = [0, Math.max(durationSec, 1e-9)];

  const { lo, hi } = support(gaussians, cutoff);
  let plans = n === 0 ? [] : planChunks(lo, hi, topsArr, maxDepth, minChunk);
  if (n > 0 && plans.length === 0) {
    plans = [
      {
        t0: topsArr[0]!,
        t1: topsArr[topsArr.length - 1]!,
        level: 0,
        members: Array.from({ length: n }, (_, i) => i),
      },
    ];
  }

  // Which SH bands are written, and their columns within a scene coefficient row.
  const shDegree = gaussians.shDegree ?? 0;
  const shCoefficients = gaussians.shCoefficients ?? 0;
  const bands: number[] = [];
  const bandColumns = new Map<number, number[]>();
  if (gaussians.sh && shDegree > 0 && shCoefficients > 0) {
    for (let band = 1; band <= Math.min(shDegree, shBands); band++) {
      const [first, lastRaw] = bandCoefficientRange(band);
      const last = Math.min(lastRaw, shCoefficients);
      if (first >= last) continue;
      const columns: number[] = [];
      for (let c = 0; c < 3; c++)
        for (let coef = first; coef < last; coef++) columns.push(c * shCoefficients + coef);
      bandColumns.set(band, columns);
      bands.push(band);
    }
  }
  const depths = resolveDepths(shBitDepths, bands);

  // step_sh and the sh bound the record declares.
  let stepSh = 1;
  let boundSh = 0;
  if (depths.length > 0) {
    stepSh = Math.max(...bands.map((_, i) => shStep(depths[i]!)));
    boundSh = Math.max(...bands.map((_, i) => shBound(depths[i]!)));
  }

  const out = new ByteWriter(4096);
  out.bytes(MAGIC);

  // Header.
  const header = new ByteWriter();
  header.string(profile);
  header.string(library);
  header.f64(durationSec);
  header.u64(n);
  header.f64(cutoff);
  header.string("gaussian-birth");
  for (const v of aabb(gaussians)) header.f64(v);
  header.u8(bands.length === 0 ? 0 : shDegree);
  header.u8(0); // flags: no audio
  putStrMap(header, attributes);
  out.bytes(record(OP_HEADER, header.finish()));

  // Quantization.
  const quant = new ByteWriter();
  quant.string("uniform-v1");
  for (const v of q.grid.origin) quant.f64(v);
  quant.f64(q.grid.stepPos);
  quant.f64(q.grid.stepScaleLog);
  quant.f64(q.grid.stepRot);
  quant.f64(q.grid.stepRgb);
  quant.f64(q.grid.stepAlpha);
  quant.f64(q.grid.stepMotion);
  quant.f64(q.grid.stepTime);
  quant.f64(q.grid.stepSigmaLog);
  quant.u8(stepSh);
  putStrMap(quant, declaredBounds(q.grid, boundSh, bands, depths));
  if (depths.length > 0) {
    quant.u8(depths.length);
    for (const d of depths) quant.u8(d);
  }
  out.bytes(record(OP_QUANTIZATION, quant.finish()));

  // Window table.
  const wt = new ByteWriter();
  wt.u32(q.windows.length);
  for (const [wlo, whi] of q.windows) {
    wt.f64(wlo);
    wt.f64(whi);
  }
  out.bytes(record(OP_WINDOW_TABLE, wt.finish()));

  // Advisory object front matter. Membership is still an attribute stream in each Chunk;
  // the table only names those ids, and the tracks transport their reconstructed state.
  if (objects?.table !== null && objects?.table !== undefined) {
    out.bytes(encodeObjectTable(objects.table));
  }
  if (objects !== null) {
    for (const track of objects.tracks) out.bytes(encodeObjectTrack(track));
  }

  // Chunks, each followed by its SH band records.
  interface IndexEntry {
    t0: number;
    t1: number;
    chunkOffset: number;
    chunkLength: number;
    gaussianCount: number;
    bands: [number, number, number][];
  }
  const index: IndexEntry[] = [];
  const row = shCoefficients * 3;

  for (const plan of plans) {
    const members = plan.members; // natural order; decoded order is not part of the contract
    const streams = new ByteWriter();
    const columns: [number, number[], number][] = [
      [A_POSITION, gather(q.pos, members, 3), 3],
      [A_SCALE, gather(q.scale, members, 3), 3],
      [A_ROTATION_INDEX, gather(q.rotationIndex, members, 1), 1],
      [A_ROTATION, gather(q.rotation, members, 3), 3],
      [A_COLOR, gather(q.rgb, members, 3), 3],
      [A_OPACITY, gather(q.alpha, members, 1), 1],
      [A_MOTION, gather(q.motion, members, 3), 3],
      [A_MU_T, gather(q.mu, members, 1), 1],
      [A_SIGMA_T, gather(q.sigma, members, 1), 1],
      [A_FLAGS, gather(q.flags, members, 1), 1],
      [A_WINDOW_INDEX, gather(q.windowIndex, members, 1), 1],
    ];
    for (const [id, values, channels] of columns) {
      streams.bytes(await encodeStream(id, values, channels));
    }
    if (objectIds !== null) {
      // Attribute symbols are signed i32. Reinterpret each u32 label as its two's-
      // complement code so every bit pattern survives exactly; the decoder reverses
      // the view without quantization.
      streams.bytes(
        await encodeStream(
          A_OBJECT_ID,
          members.map((i) => objectIds[i]! | 0),
          1,
        ),
      );
    }

    const chunkOffset = out.length; // absolute byte offset of the record
    const chunkBlob = encodeChunk(plan.t0, plan.t1, plan.level, members.length, streams.finish());
    out.bytes(chunkBlob);

    const entryBands: [number, number, number][] = [];
    if (gaussians.sh) {
      for (let bi = 0; bi < bands.length; bi++) {
        const band = bands[bi]!;
        const cols = bandColumns.get(band)!;
        const values: number[] = [];
        for (const i of members) {
          for (const col of cols) {
            const raw = gaussians.sh[i * row + col]!;
            values.push(depths.length > 0 ? quantizeSh(raw, depths[bi]!) : raw);
          }
        }
        const payload = new ByteWriter();
        payload.u8(band);
        payload.bytes(await encodeStream(OP_SH_BAND_STREAM, values, cols.length));
        const bandBlob = record(OP_SH_BAND_STREAM, payload.finish());
        const bandOffset = out.length;
        out.bytes(bandBlob);
        entryBands.push([band, bandOffset, bandBlob.length]);
      }
    }

    index.push({
      t0: plan.t0,
      t1: plan.t1,
      chunkOffset,
      chunkLength: chunkBlob.length,
      gaussianCount: members.length,
      bands: entryBands,
    });
  }

  // Summary: the index, then optional statistics and summary offsets.
  let summaryStart = 0;
  let summaryOffsetStart = 0;
  let summaryLen = 0;
  if (writeIndex && index.length > 0) {
    summaryStart = out.length;
    const groupStart = summaryStart;
    for (const entry of index) {
      const e = new ByteWriter();
      e.f64(entry.t0);
      e.f64(entry.t1);
      e.u64(entry.chunkOffset);
      e.u64(entry.chunkLength);
      e.u32(entry.gaussianCount);
      e.u32(entry.bands.length);
      for (const [band, offset, length] of entry.bands) {
        e.u8(band);
        e.u64(offset);
        e.u64(length);
      }
      out.bytes(record(OP_CHUNK_INDEX, e.finish()));
    }
    if (writeStatistics) {
      const s = new ByteWriter();
      s.u64(n);
      s.u32(index.length);
      s.f64(durationSec);
      for (const v of aabb(gaussians)) s.f64(v);
      out.bytes(record(OP_STATISTICS, s.finish()));
    }
    if (writeSummaryOffsets) {
      summaryOffsetStart = out.length;
      const s = new ByteWriter();
      s.u8(OP_CHUNK_INDEX);
      s.u64(groupStart);
      s.u64(out.length - groupStart);
      out.bytes(record(OP_SUMMARY_OFFSET, s.finish()));
    }
    summaryLen = out.length - summaryStart;
  }

  const summaryCrc = writeCrc && summaryLen > 0 ? crc32(out.finish().subarray(summaryStart)) : 0;

  const footer = new ByteWriter();
  footer.u64(summaryStart);
  footer.u64(summaryOffsetStart);
  footer.u32(summaryCrc);
  out.bytes(record(OP_FOOTER, footer.finish()));
  out.bytes(MAGIC);
  return out.finish().slice();
}

function encodeChunk(
  t0: number,
  t1: number,
  level: number,
  count: number,
  streams: Uint8Array,
): Uint8Array {
  const body = new ByteWriter(streams.length + 64);
  body.f64(t0);
  body.f64(t1);
  body.u32(level);
  body.u32(count);
  body.string(""); // chunk-level compression: the streams carry their own
  body.u64(streams.length);
  body.blob(streams);
  return record(OP_CHUNK, body.finish());
}

/** A ladder shorter than the file's degree is an error, not a silent fill. */
function resolveDepths(requested: number[], bands: number[]): number[] {
  if (requested.length === 0 || bands.length === 0) return [];
  if (requested.length < bands.length) {
    throw new Error(
      `sh_bit_depths declares ${requested.length} bands; this scene writes ${bands.length}`,
    );
  }
  const out: number[] = [];
  for (let i = 0; i < bands.length; i++) {
    const bits = requested[i]!;
    if (bits < SH_MIN_BITS || bits > SH_MAX_BITS) {
      throw new Error(`an SH bit depth must be ${SH_MIN_BITS}..${SH_MAX_BITS}, got ${bits}`);
    }
    out.push(bits);
  }
  return out;
}

function declaredBounds(
  grid: Grid,
  sh: number,
  bands: number[],
  depths: number[],
): Record<string, string> {
  const map: Record<string, string> = {
    pos: String(grid.boundPos),
    scale_rel: "0.02",
    rot: "0.002",
    rgb: String(1.0 / 255),
    alpha: String(1.0 / 255),
    motion: String(grid.boundPos / LIFE_REF),
    time: "0.002",
    sigma_rel: "0.02",
    sh: String(sh),
  };
  for (let i = 0; i < bands.length; i++) {
    if (depths.length > 0) map[`sh_band${bands[i]}`] = String(shBound(depths[i]!));
  }
  return map;
}
