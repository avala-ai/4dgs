// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Whole-file `keyframe-delta` decode: both read paths, and the reconstruction at an instant.
 *
 * `keyframeDelta.ts` holds the composition and the chain a seek walks; this module is the
 * file *around* them — the Header, a keyframe Chunk or a Delta Chunk per sample, the
 * extended Chunk Index, the Footer — and the two read paths a consumer takes:
 *
 * - {@link decodeKeyframeDeltaStreamed} walks the file front to back, composing each chunk
 *   onto the last;
 * - {@link decodeKeyframeDeltaIndexed} reads the index and, for an instant, walks only that
 *   instant's chain.
 *
 * They MUST agree. Agreeing across two very different read paths is most of what makes a
 * `keyframe-delta` implementation trustworthy. Everything upstream of the reconstruction is
 * bins, never values (spec §11.7); {@link reconstructAt} is the one place a bin becomes a
 * number, by the same arithmetic §3/§6 give a keyframe chunk.
 */

import { type CodecRegistry, DEFAULT_CODECS } from "./codec.js";
import { Cursor } from "./cursor.js";
import { MalformedFile } from "./errors.js";
import {
  applyDelta,
  type BinColumn,
  chainFor,
  checkTiling,
  type Group,
  keyframeState,
  type State,
  stateCount,
} from "./keyframeDelta.js";
import { Attribute, Opcode, REQUIRED_ATTRIBUTES } from "./opcodes.js";
import {
  clamp,
  dequantizeRotation,
  lifeClass,
  motionStep,
  muStep,
  rctInverse,
  type Steps,
} from "./quantization.js";
import {
  type ChunkIndexEntry,
  checkMagic,
  type DeltaChunkHeader,
  type Header,
  iterateRecords,
  MAGIC,
  parseChunk,
  parseChunkIndexEntry,
  parseDeltaChunk,
  parseFooter,
  parseHeader,
  parseQuantization,
  parseWindowTable,
  type Quantization,
  readRecord,
} from "./records.js";
import { frameStreams, decodeStream } from "./streams.js";
import { supportK } from "./quantization.js";

/** One decoded state chunk and the composed population valid over `[t0, t1)`. */
export interface ChunkInfo {
  readonly t0: number;
  readonly t1: number;
  /** 0 keyframe, 1 delta. */
  readonly kind: number;
  readonly deltaMode: number | null;
  readonly depth: number;
  readonly offset: number;
  readonly referenceOffset: number;
  readonly updateCount: number | null;
  readonly birthCount: number | null;
  readonly deathCount: number | null;
  readonly state: State;
}

/** The grids the whole sequence is quantized on, in the shape the reconstruction uses. */
export interface Grids {
  readonly steps: Steps;
  readonly origin: readonly number[];
  /** The single validity window `[lo, hi]` every gaussian references (spec §11 reference writer). */
  readonly window: readonly [number, number];
  readonly cutoff: number;
}

export interface DecodedSequence {
  readonly header: Header;
  readonly quantization: Quantization;
  readonly windows: Float64Array;
  readonly chunks: readonly ChunkInfo[];
}

export function gridsFor(decoded: DecodedSequence): Grids {
  const q = decoded.quantization;
  const steps: Steps = {
    pos: q.stepPos,
    scaleLog: q.stepScaleLog,
    rot: q.stepRot,
    rgb: q.stepRgb,
    alpha: q.stepAlpha,
    motion: q.stepMotion,
    time: q.stepTime,
    sigmaLog: q.stepSigmaLog,
    sh: q.stepSh,
  };
  const window: [number, number] =
    decoded.windows.length >= 2 ? [decoded.windows[0]!, decoded.windows[1]!] : [0, 0];
  return { steps, origin: q.posOrigin, window, cutoff: decoded.header.cutoff };
}

/** One length-framed sub-block: its ids, and a bin column per other attribute. */
async function decodeGroup(streamBytes: Uint8Array, codecs: CodecRegistry): Promise<Group> {
  if (streamBytes.length === 0) return { ids: new Int32Array(0), bins: new Map() };
  const framed = frameStreams(new Cursor(streamBytes));
  const bins = new Map<number, BinColumn>();
  let ids: Int32Array | null = null;
  for (const stream of framed) {
    const values = await decodeStream(stream, codecs);
    if (stream.attributeId === Attribute.GaussianId) {
      ids = values;
    } else {
      bins.set(stream.attributeId, { values, channels: stream.channels });
    }
  }
  if (ids === null) {
    throw new MalformedFile(
      "a keyframe-delta group carries no gaussian_id stream",
      "missing-gaussian-id",
    );
  }
  return { ids, bins };
}

/** A keyframe chunk's ids and bins, with the required attribute set enforced. */
async function keyframeFromChunk(content: Uint8Array, codecs: CodecRegistry): Promise<State> {
  const { header, streams } = parseChunk(content);
  const group = await decodeGroup(streams, codecs);
  if (header.count > 0) {
    const missing = REQUIRED_ATTRIBUTES.filter((id) => !group.bins.has(id));
    if (missing.length > 0) {
      throw new MalformedFile(
        `keyframe chunk is missing required attributes ${missing.join(", ")}`,
      );
    }
  }
  return keyframeState(group.ids, group.bins);
}

async function composeDelta(
  reference: State,
  content: Uint8Array,
  codecs: CodecRegistry,
): Promise<{ state: State; header: DeltaChunkHeader }> {
  const { header, updates, births, deaths } = parseDeltaChunk(content);
  const updateGroup = updates.length === 0 ? emptyGroup() : await decodeGroup(updates, codecs);
  const birthGroup = births.length === 0 ? emptyGroup() : await decodeGroup(births, codecs);
  const deathIds =
    deaths.length === 0 ? new Int32Array(0) : (await decodeGroup(deaths, codecs)).ids;
  const state = applyDelta(reference, updateGroup, birthGroup, deathIds);
  return { state, header };
}

function emptyGroup(): Group {
  return { ids: new Int32Array(0), bins: new Map() };
}

function readT0(content: Uint8Array): number {
  return new Cursor(content).f64();
}

function readT1(content: Uint8Array): number {
  const c = new Cursor(content);
  c.f64();
  return c.f64();
}

/** Front to back: decode each chunk and compose it onto the state it references (spec §11). */
export async function decodeKeyframeDeltaStreamed(
  data: Uint8Array,
  codecs: CodecRegistry = DEFAULT_CODECS,
): Promise<DecodedSequence> {
  checkMagic(data);
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  const chunks: ChunkInfo[] = [];
  const byOffset = new Map<number, State>();

  for (const record of iterateRecords(data, MAGIC.length)) {
    if (record.opcode === Opcode.Header) {
      header = parseHeader(record.content);
      if (header.temporalModel !== "keyframe-delta") {
        throw new MalformedFile(
          `decodeKeyframeDeltaStreamed is the keyframe-delta path; this file is ` +
            `${JSON.stringify(header.temporalModel)}`,
          "wrong-temporal-model",
        );
      }
    } else if (record.opcode === Opcode.Quantization) {
      quantization = parseQuantization(record.content);
    } else if (record.opcode === Opcode.WindowTable) {
      windows = parseWindowTable(record.content);
    } else if (record.opcode === Opcode.Chunk) {
      const state = await keyframeFromChunk(record.content, codecs);
      byOffset.set(record.offset, state);
      chunks.push({
        t0: readT0(record.content),
        t1: readT1(record.content),
        kind: 0,
        deltaMode: null,
        depth: 0,
        offset: record.offset,
        referenceOffset: 0,
        updateCount: null,
        birthCount: null,
        deathCount: null,
        state,
      });
    } else if (record.opcode === Opcode.DeltaChunk) {
      const peek = parseDeltaChunk(record.content).header;
      const reference = byOffset.get(peek.referenceOffset);
      if (reference === undefined) {
        throw new MalformedFile(
          `delta chunk at ${record.offset} references ${peek.referenceOffset}, which has not been ` +
            `decoded (references point backwards only)`,
          "broken-reference",
        );
      }
      if (peek.referenceOffset >= record.offset) {
        throw new MalformedFile(
          `delta chunk at ${record.offset} references ${peek.referenceOffset}, which is not behind it`,
          "forward-reference",
        );
      }
      const { state, header: head } = await composeDelta(reference, record.content, codecs);
      byOffset.set(record.offset, state);
      chunks.push({
        t0: head.t0,
        t1: head.t1,
        kind: 1,
        deltaMode: head.deltaMode,
        depth: head.depth,
        offset: record.offset,
        referenceOffset: head.referenceOffset,
        updateCount: head.updateCount,
        birthCount: head.birthCount,
        deathCount: head.deathCount,
        state,
      });
    }
  }

  if (header === null || quantization === null) {
    throw new MalformedFile("keyframe-delta file has no Header or Quantization record");
  }
  return { header, quantization, windows, chunks };
}

function recordContentAt(data: Uint8Array, offset: number, length: number): Uint8Array {
  return readRecord(new Cursor(data.subarray(offset, offset + length))).content;
}

/**
 * Read the Footer, then the index, then compose each chunk by walking its chain (spec §11.8).
 *
 * The seeking client's path, and it must reach the same population the streamed path reaches
 * front to back.
 */
export async function decodeKeyframeDeltaIndexed(
  data: Uint8Array,
  codecs: CodecRegistry = DEFAULT_CODECS,
): Promise<{ decoded: DecodedSequence; index: ChunkIndexEntry[] }> {
  checkMagic(data);
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  let summaryStart = -1;
  for (const record of iterateRecords(data, MAGIC.length)) {
    if (record.opcode === Opcode.Header) {
      header = parseHeader(record.content);
    } else if (record.opcode === Opcode.Quantization) {
      quantization = parseQuantization(record.content);
    } else if (record.opcode === Opcode.WindowTable) {
      windows = parseWindowTable(record.content);
    } else if (record.opcode === Opcode.Footer) {
      summaryStart = parseFooter(record.content).summaryStart;
      break;
    }
  }
  if (summaryStart < 0) throw new MalformedFile("file has no Footer");
  if (header === null || quantization === null) {
    throw new MalformedFile("keyframe-delta file has no Header or Quantization record");
  }

  const index: ChunkIndexEntry[] = [];
  for (const record of iterateRecords(data, summaryStart)) {
    if (record.opcode === Opcode.ChunkIndex) {
      index.push(parseChunkIndexEntry(record.content));
    } else {
      break;
    }
  }
  checkTiling(index);

  const chunks: ChunkInfo[] = [];
  for (const entry of index) {
    const state = await composeChain(data, index, entry, codecs);
    let updateCount: number | null = null;
    let birthCount: number | null = null;
    let deathCount: number | null = null;
    if (entry.kind !== 0) {
      const head = parseDeltaChunk(
        recordContentAt(data, entry.chunkOffset, entry.chunkLength),
      ).header;
      updateCount = head.updateCount;
      birthCount = head.birthCount;
      deathCount = head.deathCount;
    }
    chunks.push({
      t0: entry.t0,
      t1: entry.t1,
      kind: entry.kind,
      deltaMode: entry.kind ? entry.deltaMode : null,
      depth: entry.depth,
      offset: entry.chunkOffset,
      referenceOffset: entry.referenceOffset,
      updateCount,
      birthCount,
      deathCount,
      state,
    });
  }
  return { decoded: { header, quantization, windows, chunks }, index };
}

async function composeChain(
  data: Uint8Array,
  index: readonly ChunkIndexEntry[],
  entry: ChunkIndexEntry,
  codecs: CodecRegistry,
): Promise<State> {
  const chain = chainFor(index, (entry.t0 + entry.t1) / 2);
  let state: State | null = null;
  for (const link of chain) {
    const content = recordContentAt(data, link.chunkOffset, link.chunkLength);
    if (link.kind === 0) {
      state = await keyframeFromChunk(content, codecs);
    } else {
      if (state === null) throw new MalformedFile("a chain begins with a delta chunk");
      state = (await composeDelta(state, content, codecs)).state;
    }
  }
  if (state === null) throw new MalformedFile("an empty chain composed to no state");
  return state;
}

// --------------------------------------------------------------------------
// Reconstruction — the composed bins as float gaussian state (spec §3/§6)
// --------------------------------------------------------------------------

/** The composed population reconstructed at instant `t`, in `gaussian_id` order (spec §11.2). */
export interface Reconstruction {
  /** Ids ascending — decoded-value order, not stream order. */
  readonly ids: Int32Array;
  /** `center` per gaussian, `position + motion * (t - mu_t)`, row-major xyz. */
  readonly centers: Float64Array;
  readonly scales: Float64Array;
  /** `colour alpha * marginal(t)`. */
  readonly opacity: Float64Array;
}

/**
 * Reconstruct the composed population at `t`, ordered by `gaussian_id`.
 *
 * Everything downstream orders by id, which is unique within a state (spec §11.2). That is
 * decoded-value order — not stream order, which a reader may not rely on — so two
 * implementations that compose the same population agree on every row. The arithmetic is
 * §3's verbatim, in float64 to match the reference's canonical.
 */
export function reconstructAt(state: State, grids: Grids, t: number): Reconstruction {
  const n = stateCount(state);
  const order = Array.from({ length: n }, (_, i) => i).sort(
    (a, b) => state.ids[a]! - state.ids[b]!,
  );
  const ids = new Int32Array(n);
  const centers = new Float64Array(n * 3);
  const scales = new Float64Array(n * 3);
  const opacity = new Float64Array(n);
  if (n === 0) return { ids, centers, scales, opacity };

  const { steps, origin } = grids;
  const k = supportK(grids.cutoff);
  const windowLength = grids.window[1] - grids.window[0];

  const position = state.bins.get(Attribute.Position)!;
  const scaleCol = state.bins.get(Attribute.Scale)!;
  const rotIndex = state.bins.get(Attribute.RotationIndex)!;
  const rotCol = state.bins.get(Attribute.Rotation)!;
  const colorCol = state.bins.get(Attribute.Color)!;
  const alphaCol = state.bins.get(Attribute.Opacity)!;
  const motionCol = state.bins.get(Attribute.Motion)!;
  const muCol = state.bins.get(Attribute.MuT)!;
  const sigmaCol = state.bins.get(Attribute.SigmaT)!;
  const flagCol = state.bins.get(Attribute.Flags)!;

  const rotationScratch = new Float32Array(4);

  for (let out = 0; out < n; out++) {
    const i = order[out]!;
    ids[out] = state.ids[i]!;

    const sigmaBin = sigmaCol.values[i]!;
    const neverFades = (flagCol.values[i]! & 1) !== 0;
    const sigma = neverFades ? Infinity : Math.exp(sigmaBin * steps.sigmaLog);
    const mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, windowLength, k),
      steps.motion,
    );
    const tStep = muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    const mu = muCol.values[i]! * tStep;
    const marginal = Number.isFinite(sigma) ? Math.exp(-0.5 * ((t - mu) / sigma) ** 2) : 1;

    for (let c = 0; c < 3; c++) {
      const pos = position.values[i * 3 + c]! * steps.pos + (origin[c] ?? 0);
      const motion = motionCol.values[i * 3 + c]! * mStep;
      centers[out * 3 + c] = pos + motion * (t - mu);
      scales[out * 3 + c] = Math.exp(scaleCol.values[i * 3 + c]! * steps.scaleLog);
    }

    // The dequantized colours are not carried out — only the alpha feeds `opacity` — but
    // rotation and rgb are dequantized where a fuller consumer would want them, matching
    // the reference's per-row work exactly.
    dequantizeRotation(
      rotIndex.values[i]!,
      rotCol.values[i * 3]!,
      rotCol.values[i * 3 + 1]!,
      rotCol.values[i * 3 + 2]!,
      steps.rot,
      rotationScratch,
      0,
    );
    const [r, g, b] = rctInverse(
      colorCol.values[i * 3]!,
      colorCol.values[i * 3 + 1]!,
      colorCol.values[i * 3 + 2]!,
    );
    void r;
    void g;
    void b;
    const alpha = clamp(alphaCol.values[i]! * steps.alpha, 0, 1);
    opacity[out] = alpha * marginal;
  }
  return { ids, centers, scales, opacity };
}

/**
 * Every chunk's `t0` and interval midpoint, plus one instant just below the end (spec §11.2
 * probe rule). Derived from the file rather than hardcoded, so "seek to every chunk" is the
 * expectation rather than a separate test.
 */
export function probeTimes(chunks: readonly ChunkInfo[], durationSec: number): number[] {
  const times = new Set<number>();
  const round9 = (v: number) => Math.round(v * 1e9) / 1e9;
  for (const c of chunks) {
    times.add(round9(c.t0));
    times.add(round9((c.t0 + c.t1) / 2));
  }
  times.add(round9(Math.max(0, durationSec - 1e-6)));
  return [...times].sort((a, b) => a - b);
}

/** The chunk whose interval covers `t`, or the last chunk when none does. */
export function stateCovering(chunks: readonly ChunkInfo[], t: number): ChunkInfo {
  for (const c of chunks) if (c.t0 <= t && t < c.t1) return c;
  return chunks[chunks.length - 1]!;
}
