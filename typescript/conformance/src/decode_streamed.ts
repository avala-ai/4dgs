// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: streamed decode, canonical JSON to stdout.
 *
 * The whole interface between an implementation and the harness is this: take a path,
 * print the canonical JSON. The resource is read in bounded blocks and never held whole,
 * which is the mode this runner exists to exercise — a decoder that quietly buffered the
 * file would pass the diff and fail the point.
 */

import { decodeScene, type IReadable, type Scene } from "@4dgs/core";
import { FileHandleReadable } from "@4dgs/nodejs";

import { canonical, summarize } from "./canonical.js";
import { checkStreamedRecords, checkTruncationRecovery } from "./checks.js";

/** Reads small enough that even the smallest variant arrives in several of them. */
const BLOCK_SIZE = 8 * 1024;

function decode(readable: IReadable): Promise<Scene> {
  return decodeScene(readable, { blockSize: BLOCK_SIZE });
}

export async function run(path: string): Promise<string> {
  const source = await FileHandleReadable.open(path);
  try {
    const size = Number(await source.size());
    const scene = await decode(source);

    checkStreamedRecords(scene, size);
    await checkTruncationRecovery(source, size, scene, decode);

    return canonical(
      summarize({
        header: scene.header,
        gaussians: scene.gaussians,
        audio: scene.audio,
        chunkIntervals: scene.chunkIndex.map((entry) => [entry.t0, entry.t1] as const),
      }),
    );
  } finally {
    await source.close();
  }
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_streamed.js <file.4dgs>\n");
  process.exit(2);
}
process.stdout.write((await run(path)) + "\n");
