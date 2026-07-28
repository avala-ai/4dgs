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

import { assembleGaussians, IndexedDecoder, MAX_SH_DEGREE, type ChunkGaussians } from "@4dgs/core";
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
    for (const entry of scene.index) {
      chunks.push((await scene.readChunk(entry, { maxShBand: MAX_SH_DEGREE })).gaussians);
    }
    const audio = await scene.readAudio();

    await checkIndexedInvariants(scene, source);

    return canonical(
      summarize({
        header: scene.header,
        gaussians: assembleGaussians(chunks, scene.windows, scene.header.shDegree),
        audio,
        chunkIntervals: scene.index.map((entry) => [entry.t0, entry.t1] as const),
      }),
    );
  } finally {
    await file.close();
  }
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_indexed.js <file.4dgs>\n");
  process.exit(2);
}
process.stdout.write((await run(path)) + "\n");
