// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * A whole file, decoded front to back.
 *
 * The resource is consumed in bounded reads and never held in one piece: the decoder
 * frames records as bytes arrive, decodes each chunk when it completes, and keeps only
 * the gaussians. A file larger than memory decodes the same way a small one does.
 */

import {
  type ChunkGaussians,
  chunkStreamBytes,
  decodeChunkStreams,
  type DecodeChunkOptions,
  stepsFrom,
} from "./chunk.js";
import { crc32, DEFAULT_CODECS, type CodecRegistry } from "./codec.js";
import { MalformedFile, TruncatedFile } from "./errors.js";
import { assembleGaussians, type GaussianSet } from "./gaussians.js";
import { Opcode } from "./opcodes.js";
import { DEFAULT_CUTOFF, supportK } from "./quantization.js";
import {
  type Attachment,
  type AudioTrack,
  type Camera,
  type ChunkIndexEntry,
  type Header,
  type Metadata,
  type Quantization,
  type Statistics,
  type SummaryOffset,
  parseAttachment,
  parseAudio,
  parseCamera,
  parseChunk,
  parseChunkIndexEntry,
  parseHeader,
  parseMetadata,
  parseQuantization,
  parseShBandRecord,
  parseStatistics,
  parseFooter,
  parseSummaryOffset,
  parseWindowTable,
} from "./records.js";
import { type IReadable, BytesReadable } from "./readable.js";
import { MAX_SH_DEGREE, mergeBands, type ShCoefficients } from "./sh.js";
import { StreamDecoder } from "./streamDecoder.js";
import { decodeStream, frameOneStream } from "./streams.js";

/** Everything a `.4dgs` file describes, decoded. */
export interface Scene {
  readonly header: Header;
  readonly quantization: Quantization;
  /** Flattened `[lo, hi]` pairs from the Window Table record. */
  readonly windows: Float64Array;
  readonly gaussians: GaussianSet;
  /** `null` when the scene has no soundtrack, which is the common case and not an error. */
  readonly audio: AudioTrack | null;
  readonly camera: Camera | null;
  readonly metadata: readonly Metadata[];
  readonly attachments: readonly Attachment[];
  readonly statistics: Statistics | null;
  readonly chunkIndex: readonly ChunkIndexEntry[];
  readonly summaryOffsets: readonly SummaryOffset[];
  /**
   * Whether the Footer's summary CRC matched, or `null` when the file declares none.
   *
   * A front-to-back reader can answer this too: it has seen the bytes the CRC covers, so
   * it retains the summary region — the index, which is small by design — until the
   * Footer arrives and says where that region began.
   */
  readonly summaryCrcOk: boolean | null;
  /** Opcodes seen but not understood, in the order they appeared. */
  readonly skippedOpcodes: readonly number[];
  /** True when the resource ended before the file did. What decoded still stands. */
  readonly truncated: boolean;
}

export interface DecodeOptions {
  /** Decompressors by codec id. Defaults to deflate only; zstd is opt-in. */
  readonly codecs?: CodecRegistry;
  /** Highest SH band to decode. 0 skips spherical harmonics entirely. */
  readonly maxShBand?: number;
  /** Bytes per read from the resource. Bounds how much is in flight, not what fits. */
  readonly blockSize?: number;
  /**
   * Whether a resource that ends mid-record yields what decoded before the cut.
   *
   * On by default: a truncated file is common and usually recoverable, and the `truncated`
   * flag says so without the caller having to catch anything.
   */
  readonly recoverTruncated?: boolean;
}

const DEFAULT_BLOCK_SIZE = 1 << 20;

/**
 * Decode a whole scene, front to back.
 *
 * Accepts bytes for the common small case and an {@link IReadable} for everything else;
 * either way the decoder pulls in bounded blocks and never asks for the whole resource.
 */
export async function decodeScene(
  source: IReadable | Uint8Array,
  options: DecodeOptions = {},
): Promise<Scene> {
  const readable = source instanceof Uint8Array ? new BytesReadable(source) : source;
  const codecs = options.codecs ?? DEFAULT_CODECS;
  const maxShBand = options.maxShBand ?? MAX_SH_DEGREE;
  const blockSize = options.blockSize ?? DEFAULT_BLOCK_SIZE;
  const recoverTruncated = options.recoverTruncated ?? true;

  const decoder = new StreamDecoder();
  const size = Number(await readable.size());

  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  let chunkOptions: DecodeChunkOptions | null = null;

  const chunks: ChunkGaussians[] = [];
  const chunkBands: Map<number, Int32Array>[] = [];
  const metadata: Metadata[] = [];
  const attachments: Attachment[] = [];
  const chunkIndex: ChunkIndexEntry[] = [];
  const summaryOffsets: SummaryOffset[] = [];
  const skippedOpcodes: number[] = [];
  // The summary region, retained from the first record that belongs to it so the Footer's
  // CRC can be checked. Bounded by the index, which every reader has to hold anyway.
  const summaryParts: Uint8Array[] = [];
  let summaryPartsStart = -1;
  let summaryCrcOk: boolean | null = null;
  let audio: AudioTrack | null = null;
  let camera: Camera | null = null;
  let statistics: Statistics | null = null;
  let truncated = false;

  let at = 0;
  while (at < size) {
    const length = Math.min(blockSize, size - at);
    decoder.append(await readable.read(BigInt(at), BigInt(length)));
    at += length;

    // Records complete as bytes arrive. A record that is not complete yet is simply not
    // yielded, which is the whole of truncation recovery: what is complete is decoded,
    // what is cut is not, and nothing has to be undone.
    for (const record of decoder.records()) {
      const { opcode, content } = record;
      if (SUMMARY_OPCODES.has(opcode)) {
        if (summaryPartsStart < 0) summaryPartsStart = record.offset;
        summaryParts.push(record.raw);
      }
      switch (opcode) {
        case Opcode.Header:
          header = parseHeader(content);
          break;
        case Opcode.Quantization:
          quantization = parseQuantization(content);
          break;
        case Opcode.WindowTable:
          windows = parseWindowTable(content);
          break;
        case Opcode.Chunk: {
          if (quantization === null || header === null) {
            throw new MalformedFile("a Chunk arrived before the Header or Quantization record");
          }
          chunkOptions ??= {
            steps: stepsFrom(quantization),
            posOrigin: quantization.posOrigin,
            windows,
            supportK: supportK(header.cutoff || DEFAULT_CUTOFF),
            codecs,
          };
          const parsed = parseChunk(content);
          const streamBytes = await chunkStreamBytes(parsed, codecs);
          chunks.push(await decodeChunkStreams(streamBytes, parsed.header.count, chunkOptions));
          chunkBands.push(new Map());
          break;
        }
        case Opcode.ShBandStream: {
          if (maxShBand <= 0 || chunks.length === 0) break;
          const { band, cursor } = parseShBandRecord(content);
          if (band > maxShBand) break;
          const values = await decodeStream(frameOneStream(cursor), codecs);
          chunkBands[chunkBands.length - 1]!.set(band, values);
          break;
        }
        case Opcode.Audio:
          audio = parseAudio(content);
          break;
        case Opcode.Camera:
          camera = parseCamera(content);
          break;
        case Opcode.Metadata:
          metadata.push(parseMetadata(content));
          break;
        case Opcode.Attachment:
          attachments.push(parseAttachment(content));
          break;
        case Opcode.Statistics:
          statistics = parseStatistics(content);
          break;
        case Opcode.ChunkIndex:
          chunkIndex.push(parseChunkIndexEntry(content));
          break;
        case Opcode.SummaryOffset:
          summaryOffsets.push(parseSummaryOffset(content));
          break;
        case Opcode.Footer: {
          const footer = parseFooter(content);
          if (footer.summaryStart > 0 && footer.summaryCrc !== 0) {
            summaryCrcOk = checkSummaryCrc(
              summaryParts,
              summaryPartsStart,
              footer.summaryStart,
              record.offset,
              footer.summaryCrc,
            );
          }
          break;
        }
        case Opcode.AttachmentIndex:
          break;
        default:
          // Unknown or private: skipped by length, which is the whole point of framing.
          skippedOpcodes.push(opcode);
          break;
      }
    }
  }

  decoder.end();
  truncated ||= decoder.truncated;
  if (truncated && !recoverTruncated) {
    throw new TruncatedFile(`resource ended after ${decoder.consumed} bytes, mid-file`);
  }
  if (header === null || quantization === null) {
    throw new MalformedFile("file has no Header or no Quantization record");
  }

  return {
    header,
    quantization,
    windows,
    gaussians: assembleGaussians(
      chunks,
      windows,
      header.shDegree,
      mergeChunkBands(chunks, chunkBands, maxShBand),
    ),
    audio,
    camera,
    metadata,
    attachments,
    statistics,
    chunkIndex,
    summaryOffsets,
    skippedOpcodes,
    summaryCrcOk,
    truncated,
  };
}

/** Records that belong to the summary region a Footer CRC covers. */
const SUMMARY_OPCODES: ReadonlySet<number> = new Set([
  Opcode.ChunkIndex,
  Opcode.Statistics,
  Opcode.SummaryOffset,
  Opcode.AttachmentIndex,
]);

/**
 * Check the Footer's CRC over `[summaryStart, footerStart)` against the retained bytes.
 *
 * `null` rather than `false` when the retained region does not reach back to where the
 * Footer says the summary began: that is a reader which cannot answer, not a file that
 * failed.
 */
function checkSummaryCrc(
  parts: readonly Uint8Array[],
  partsStart: number,
  summaryStart: number,
  footerStart: number,
  expected: number,
): boolean | null {
  if (partsStart < 0 || summaryStart < partsStart) return null;
  let total = 0;
  for (const part of parts) total += part.byteLength;
  const joined = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    joined.set(part, at);
    at += part.byteLength;
  }
  const from = summaryStart - partsStart;
  const to = footerStart - partsStart;
  if (to > joined.byteLength || from > to) return null;
  return crc32(joined.subarray(from, to)) === expected;
}

/**
 * Merge every chunk's SH bands into one scene-wide coefficient array.
 *
 * Degrees are whole and scene-wide, so chunks that disagree about how many bands they
 * carry describe a file no reader can evaluate consistently.
 */
function mergeChunkBands(
  chunks: readonly ChunkGaussians[],
  bands: readonly Map<number, Int32Array>[],
  degreeCap: number,
): ShCoefficients | null {
  const merged = chunks.map((chunk, i) =>
    mergeBands(chunk.count, bands[i] ?? new Map(), degreeCap),
  );
  const withBands = merged.filter((m) => m.degree > 0);
  if (withBands.length === 0) return null;
  const degree = withBands[0]!.degree;
  if (withBands.length !== merged.length || merged.some((m) => m.degree !== degree)) {
    throw new MalformedFile(
      `chunks disagree on SH degree: ${[...new Set(merged.map((m) => m.degree))].join(", ")}`,
    );
  }
  const coefficients = withBands[0]!.coefficients;
  let count = 0;
  let length = 0;
  for (const part of merged) {
    count += part.count;
    length += part.values.length;
  }
  const values = new Uint8Array(length);
  let at = 0;
  for (const part of merged) {
    values.set(part.values, at);
    at += part.values.length;
  }
  return { degree, coefficients, count, values, bands: withBands[0]!.bands };
}
