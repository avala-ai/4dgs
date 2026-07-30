// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: keyframe-delta streamed decode, canonical `states` JSON to stdout.
 *
 * The whole interface between an implementation and the harness is this: take a path,
 * print the canonical JSON. This runner walks the file front to back, composing each chunk
 * onto the one it references (spec §11), and prints the reconstruction-at-an-instant
 * statement the other SDKs are diffed against.
 */

import { readFile } from "node:fs/promises";

import { decodeKeyframeDeltaStreamed, keyframeDeltaStatesJson } from "@4dgs/core";

import { canonical } from "./canonical.js";

/** Only the keyframe-delta corpus variants; the gaussian-birth runners own the rest. */
export function supportsVariant(name: string): boolean {
  return name.includes("KeyframeDelta");
}

export async function run(path: string): Promise<string> {
  const data = new Uint8Array(await readFile(path));
  return canonical(keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(data)));
}

const path = process.argv[2];
if (path === undefined) {
  process.stderr.write("usage: decode_keyframe_delta_streamed.js <file.4dgs>\n");
  process.exit(2);
}
process.stdout.write((await run(path)) + "\n");
