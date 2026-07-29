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
  assembleGaussians,
  IndexedDecoder,
  MAX_SH_DEGREE,
  type ChunkGaussians,
  type ShCoefficients,
} from "@4dgs/core";
import { FileHandleReadable } from "@4dgs/nodejs";

import { canonical, summarize } from "./canonical.js";
import { checkIndexedInvariants, CountingReadable } from "./checks.js";

/** A file written without an index cannot be read this way; the harness skips those. */
export function supportsVariant(name: string): boolean {
  return name.includes("UseChunkIndex");
}

export async function run(path: string): Promise<string> {
  const file = await FileHandleReadable.open(path);
  const source = new CountingReadable(file);
  try {
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
process.stdout.write((await run(path)) + "\n");
