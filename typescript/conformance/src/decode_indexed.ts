// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: indexed decode.
 *
 * Reads the Footer, then the index, then each chunk by byte range — the path a seeking
 * client takes — and produces the same canonical JSON the streamed runner does. Agreeing
 * with itself across two very different read paths is most of what makes an indexed
 * implementation trustworthy.
 */

import {
  FourdgsError,
  MAGIC,
  Opcode,
  assembleGaussians,
  checkMagic,
  decodeKeyframeDeltaIndexed,
  IndexedDecoder,
  iterateRecords,
  keyframeDeltaStatesJson,
  MAX_SH_DEGREE,
  parseHeader,
  type ChunkGaussians,
  type IReadable,
  type ShCoefficients,
} from "@4dgs/core";
import { FileHandleReadable } from "@4dgs/nodejs";

import { canonical, refusalAnswer, summarize } from "./canonical.js";
import { checkIndexedInvariants, CountingReadable } from "./checks.js";

/** How much of the front is read to learn the temporal model without decoding gaussians. */
const HEADER_PROBE_BYTES = 64 * 1024;

/** A file written without an index cannot be read this way; the harness skips those. */
export function supportsVariant(name: string): boolean {
  return name.includes("UseChunkIndex");
}

/** The Header's temporal model, read from a bounded prefix. */
async function temporalModel(source: IReadable, size: number): Promise<string | null> {
  const probe = await source.read(0n, BigInt(Math.min(size, HEADER_PROBE_BYTES)));
  checkMagic(probe);
  for (const record of iterateRecords(probe, MAGIC.length)) {
    if (record.opcode === Opcode.Header) return parseHeader(record.content).temporalModel;
  }
  return null;
}

export async function run(path: string): Promise<string> {
  const file = await FileHandleReadable.open(path);
  const source = new CountingReadable(file);
  try {
    const size = Number(await source.size());
    if ((await temporalModel(source, size)) === "keyframe-delta") {
      // Read the Footer, then the index, then compose each chunk by walking its chain — the
      // seeking client's path — and emit the same states canonical the streamed runner does.
      // Agreeing across the two paths is most of what makes an indexed keyframe-delta reader
      // trustworthy.
      const data = await source.read(0n, BigInt(size));
      return canonical(keyframeDeltaStatesJson((await decodeKeyframeDeltaIndexed(data)).sequence));
    }
    const scene = await IndexedDecoder.open(source);
    const chunks: ChunkGaussians[] = [];
    const shParts: ShCoefficients[] = [];
    for (const entry of scene.index) {
      const chunk = await scene.readChunk(entry, { maxShBand: MAX_SH_DEGREE });
      chunks.push(chunk.gaussians);
      if (chunk.sh !== null) shParts.push(chunk.sh);
    }
    const audioSources = await scene.readAudioSources();
    const camera = await scene.readCamera();
    const metadata = await scene.readMetadata();
    const attachments = await scene.readAttachments();
    const provenance = await scene.readProvenance();
    const objects = await scene.readObjects();

    await checkIndexedInvariants(scene, source);

    return canonical(
      summarize({
        header: scene.header,
        gaussians: assembleGaussians(
          chunks,
          scene.windows,
          scene.header.shDegree,
          concatenateSh(shParts),
        ),
        audioSources,
        chunkIntervals: scene.index.map((entry) => [entry.t0, entry.t1] as const),
        camera,
        metadata,
        attachments,
        statistics: scene.statistics,
        summaryOffsets: scene.summaryOffsets,
        summaryCrcOk: scene.summaryCrcOk,
        provenance,
        objects,
      }),
    );
  } finally {
    await file.close();
  }
}

/** One scene's coefficients, out of the per-chunk arrays the index led to. */
function concatenateSh(parts: readonly ShCoefficients[]): ShCoefficients | null {
  if (parts.length === 0) return null;
  const degree = parts[0]!.degree;
  let count = 0;
  let length = 0;
  for (const part of parts) {
    if (part.degree !== degree) {
      throw new Error(`chunks disagree on SH degree: ${part.degree} after ${degree}`);
    }
    count += part.count;
    length += part.values.length;
  }
  const values = new Uint8Array(length);
  let at = 0;
  for (const part of parts) {
    values.set(part.values, at);
    at += part.values.length;
  }
  return { degree, coefficients: parts[0]!.coefficients, count, values, bands: parts[0]!.bands };
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_indexed.js <file.4dgs>\n");
  process.exit(2);
}
try {
  process.stdout.write((await run(path)) + "\n");
} catch (error) {
  // Both read paths answer the invalid corpus, and they reach the Header by different
  // routes — one front to back, one through the Footer. A check placed on only one of
  // them refuses half the files it should, and only running both can show that.
  if (!(error instanceof FourdgsError)) throw error;
  // The same rule about what counts as an answer, reached by the other route: only an
  // error the refusal table names is one. Anything else is a failed invocation, on
  // stderr with a non-zero exit. See `refusalAnswer`.
  const answer = refusalAnswer(error);
  if (answer === null) {
    process.stderr.write(`${path}: ${error.message}\n`);
    process.exit(1);
  }
  process.stdout.write(answer + "\n");
}
