// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: keyframe-delta indexed decode.
 *
 * Reads the Footer, then the index, then composes each chunk by walking its chain (spec
 * §11.8) — the path a seeking client takes — and produces the same canonical `states` JSON
 * the streamed runner does. Agreeing with itself across two very different read paths is
 * most of what makes an indexed implementation trustworthy.
 */

import { readFile } from "node:fs/promises";

import { decodeKeyframeDeltaIndexed, keyframeDeltaStatesJson } from "@4dgs/core";

import { canonical } from "./canonical.js";

/** The name tokens the keyframe-delta corpus variants carry (matches run.py). */
const KEYFRAME_DELTA_TOKENS = ["KeyframeOnly", "KeyframeDelta"] as const;

/** A file written without an index cannot be read this way; keyframe-delta variants only. */
export function supportsVariant(name: string): boolean {
  return (
    KEYFRAME_DELTA_TOKENS.some((token) => name.includes(token)) && name.includes("UseChunkIndex")
  );
}

export async function run(path: string): Promise<string> {
  const data = new Uint8Array(await readFile(path));
  const { sequence } = await decodeKeyframeDeltaIndexed(data);
  return canonical(keyframeDeltaStatesJson(sequence));
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_keyframe_delta_indexed.js <file.4dgs>\n");
  process.exit(2);
}
process.stdout.write((await run(path)) + "\n");
