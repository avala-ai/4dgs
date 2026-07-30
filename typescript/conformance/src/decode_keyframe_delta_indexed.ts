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

import { decodeKeyframeDeltaIndexed } from "@4dgs/core";

import { canonical } from "./canonical.js";
import { keyframeDeltaStates } from "./keyframeDeltaCanonical.js";

/** A file written without an index cannot be read this way; keyframe-delta variants only. */
export function supportsVariant(name: string): boolean {
  return name.includes("KeyframeDelta") && name.includes("UseChunkIndex");
}

export async function run(path: string): Promise<string> {
  const data = new Uint8Array(await readFile(path));
  const { decoded } = await decodeKeyframeDeltaIndexed(data);
  return canonical(keyframeDeltaStates(decoded));
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_keyframe_delta_indexed.js <file.4dgs>\n");
  process.exit(2);
}
process.stdout.write((await run(path)) + "\n");
