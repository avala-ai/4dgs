// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Decoding one chunk's attribute streams into gaussian state.
 *
 * A chunk is independently decodable: nothing here reads anything outside the chunk
 * except the file-level quantization grids and the window table, both of which a reader
 * has before it fetches a byte of gaussian data.
 *
 * The window table is required rather than optional. A never-fading gaussian's velocity
 * precision is derived from the length of its validity window, so a decoder that guesses
 * a window length decodes different velocities than the encoder wrote — precisely the
 * class of divergence the conformance suite exists to catch.
 */

import { CODEC_DEFLATE, CODEC_ZSTD, type CodecRegistry, decompressorFor } from "./codec.js";
import { Cursor } from "./cursor.js";
import { MalformedFile, UnsupportedCodec } from "./errors.js";
import { Attribute, REQUIRED_ATTRIBUTES } from "./opcodes.js";
import {
  clamp,
  dequantizeRotation,
  lifeClass,
  motionStep,
  muStep,
  rctInverse,
  type Steps,
} from "./quantization.js";
import type { ParsedChunk, Quantization } from "./records.js";
import { decodeStream, frameStreams, type RawStream } from "./streams.js";

/** The grids from a Quantization record, in the shape the decoder uses them. */
export function stepsFrom(q: Quantization): Steps {
  return {
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
}

/**
 * One chunk's gaussians, structure-of-arrays.
 *
 * Float32 throughout, because that is the precision the reconstructed state is defined
 * at and because it is what a consumer uploads without a conversion pass.
 */
export interface ChunkGaussians {
  readonly count: number;
  readonly positions: Float32Array;
  readonly scales: Float32Array;
  readonly rotations: Float32Array;
  readonly colors: Float32Array;
  readonly motions: Float32Array;
  readonly muT: Float32Array;
  /** `+Infinity` for a gaussian that never fades. A value, not a sentinel. */
  readonly sigmaT: Float32Array;
  readonly windowIndex: Int32Array;
  readonly sourceGroup: Int32Array | null;
  readonly sourceIndex: Int32Array | null;
}

export interface DecodeChunkOptions {
  readonly steps: Steps;
  readonly posOrigin: readonly number[];
  /** Flattened `[lo, hi]` pairs from the Window Table record. */
  readonly windows: Float64Array;
  /** `sqrt(-2 ln cutoff)`, from the Header's cutoff. */
  readonly supportK: number;
  readonly codecs: CodecRegistry;
}

const EMPTY_CHUNK: ChunkGaussians = {
  count: 0,
  positions: new Float32Array(0),
  scales: new Float32Array(0),
  rotations: new Float32Array(0),
  colors: new Float32Array(0),
  motions: new Float32Array(0),
  muT: new Float32Array(0),
  sigmaT: new Float32Array(0),
  windowIndex: new Int32Array(0),
  sourceGroup: null,
  sourceIndex: null,
};

/**
 * Decode the attribute streams of one chunk.
 *
 * The streams are framed synchronously and then decompressed together: they are
 * independent, and decompressing them one at a time is time spent waiting for no reason.
 */
export async function decodeChunkStreams(
  streamBytes: Uint8Array,
  count: number,
  options: DecodeChunkOptions,
): Promise<ChunkGaussians> {
  const framed = frameStreams(new Cursor(streamBytes));
  const byId = new Map<number, RawStream>();
  for (const stream of framed) {
    if (stream.elementCount !== count && stream.elementCount !== 0) {
      throw new MalformedFile(
        `attribute ${stream.attributeId} declares ${stream.elementCount} elements, ` +
          `the chunk declares ${count} gaussians`,
      );
    }
    byId.set(stream.attributeId, stream);
  }

  if (count === 0) return EMPTY_CHUNK;

  const missing = REQUIRED_ATTRIBUTES.filter((id) => !byId.has(id));
  if (missing.length > 0) {
    throw new MalformedFile(`chunk is missing required attributes ${missing.join(", ")}`);
  }

  const wanted = [...REQUIRED_ATTRIBUTES, Attribute.SourceGroup, Attribute.SourceIndex].filter(
    (id) => byId.has(id),
  );
  const decoded = new Map<number, Int32Array>();
  await Promise.all(
    wanted.map(async (id) => {
      decoded.set(id, await decodeStream(byId.get(id)!, options.codecs));
    }),
  );

  return assemble(count, decoded, options);
}

function assemble(
  count: number,
  decoded: ReadonlyMap<number, Int32Array>,
  options: DecodeChunkOptions,
): ChunkGaussians {
  const { steps, posOrigin, windows } = options;
  const posBins = decoded.get(Attribute.Position)!;
  const scaleBins = decoded.get(Attribute.Scale)!;
  const rotIndex = decoded.get(Attribute.RotationIndex)!;
  const rotBins = decoded.get(Attribute.Rotation)!;
  const colorBins = decoded.get(Attribute.Color)!;
  const alphaBins = decoded.get(Attribute.Opacity)!;
  const motionBins = decoded.get(Attribute.Motion)!;
  const muBins = decoded.get(Attribute.MuT)!;
  const sigmaBins = decoded.get(Attribute.SigmaT)!;
  const flagBins = decoded.get(Attribute.Flags)!;
  const windowBins = decoded.get(Attribute.WindowIndex)!;

  const positions = new Float32Array(count * 3);
  const scales = new Float32Array(count * 3);
  const rotations = new Float32Array(count * 4);
  const colors = new Float32Array(count * 4);
  const motions = new Float32Array(count * 3);
  const muT = new Float32Array(count);
  const sigmaT = new Float32Array(count);
  const windowIndex = new Int32Array(count);

  const windowCount = windows.length >>> 1;
  const originX = posOrigin[0] ?? 0;
  const originY = posOrigin[1] ?? 0;
  const originZ = posOrigin[2] ?? 0;

  for (let i = 0; i < count; i++) {
    const i3 = i * 3;
    positions[i3] = posBins[i3]! * steps.pos + originX;
    positions[i3 + 1] = posBins[i3 + 1]! * steps.pos + originY;
    positions[i3 + 2] = posBins[i3 + 2]! * steps.pos + originZ;

    scales[i3] = Math.exp(scaleBins[i3]! * steps.scaleLog);
    scales[i3 + 1] = Math.exp(scaleBins[i3 + 1]! * steps.scaleLog);
    scales[i3 + 2] = Math.exp(scaleBins[i3 + 2]! * steps.scaleLog);

    dequantizeRotation(
      rotIndex[i]!,
      rotBins[i3]!,
      rotBins[i3 + 1]!,
      rotBins[i3 + 2]!,
      steps.rot,
      rotations,
      i * 4,
    );

    const [r, g, b] = rctInverse(colorBins[i3]!, colorBins[i3 + 1]!, colorBins[i3 + 2]!);
    colors[i * 4] = clamp(r * steps.rgb, 0, 1);
    colors[i * 4 + 1] = clamp(g * steps.rgb, 0, 1);
    colors[i * 4 + 2] = clamp(b * steps.rgb, 0, 1);
    colors[i * 4 + 3] = clamp(alphaBins[i]! * steps.alpha, 0, 1);

    // Per-gaussian precision: both pitches come from this gaussian's own sigma bin, which
    // the decoder has already read. There is no side channel and no lookup table.
    const neverFades = (flagBins[i]! & 1) !== 0;
    const sigmaBin = sigmaBins[i]!;
    const rawIndex = windowBins[i]!;
    const safeIndex = clamp(rawIndex, 0, Math.max(windowCount - 1, 0));
    windowIndex[i] = safeIndex;
    const windowLength =
      windowCount > 0 ? windows[safeIndex * 2 + 1]! - windows[safeIndex * 2]! : 0;

    const step = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, windowLength, options.supportK),
      steps.motion,
    );
    motions[i3] = motionBins[i3]! * step;
    motions[i3 + 1] = motionBins[i3 + 1]! * step;
    motions[i3 + 2] = motionBins[i3 + 2]! * step;

    muT[i] = muBins[i]! * muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    sigmaT[i] = neverFades ? Infinity : Math.exp(sigmaBin * steps.sigmaLog);
  }

  return {
    count,
    positions,
    scales,
    rotations,
    colors,
    motions,
    muT,
    sigmaT,
    windowIndex,
    sourceGroup: decoded.get(Attribute.SourceGroup) ?? null,
    sourceIndex: decoded.get(Attribute.SourceIndex) ?? null,
  };
}

/** Registry codec names, as the Chunk record's `compression` field spells them. */
const CHUNK_COMPRESSION_IDS: ReadonlyMap<string, number> = new Map([
  ["deflate", CODEC_DEFLATE],
  ["zstd", CODEC_ZSTD],
]);

/**
 * A chunk's attribute streams, with any chunk-level compression undone.
 *
 * Compression is normally per stream and this field is empty, but the format allows a
 * codec over the whole records block. An unrecognized name is refused by name: the file
 * may be perfectly conforming and this build simply cannot read it, which is a different
 * problem from a corrupt one.
 */
export async function chunkStreamBytes(
  chunk: ParsedChunk,
  codecs: CodecRegistry,
): Promise<Uint8Array> {
  const { compression, uncompressedSize, t0 } = chunk.header;
  if (compression === "") return chunk.streams;
  const codec = CHUNK_COMPRESSION_IDS.get(compression);
  if (codec === undefined) {
    throw new UnsupportedCodec(
      `chunk at t0=${t0} is compressed with "${compression}", which this build does not know`,
    );
  }
  return decompressorFor(codec, codecs)(chunk.streams, uncompressedSize);
}
