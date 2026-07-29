// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: encode.
 *
 * Decode a variant, re-encode the gaussians it yields with the reference preset, and write
 * the result. The gate around this (tests/conformance/encode_roundtrip.py) re-encodes the
 * same variant with the Rust reference and requires the Python decoder to read both files
 * identically. TypeScript is a genuine second encoder, not a binding, so that agreement is a
 * real cross-implementation claim: two encoders quantizing onto the same grids and building
 * the same chunk tree produce files that decode to the same scene.
 *
 * The preset mirrors rust/conformance/src/bin/encode_gaussians.rs. Byte layout — deflate,
 * gaussian order within a chunk — legitimately differs between two encoders, so the gate
 * compares decoded content rather than bytes.
 *
 * Usage: encode_roundtrip.js <in.4dgs> <out.4dgs> [sh-bit-depths]
 */

import { writeFileSync } from "node:fs";

import { decodeScene, encodeScene, type GaussianInput } from "@4dgs/core";
import { FileHandleReadable } from "@4dgs/nodejs";

function parseDepths(spec: string): number[] {
  return spec.split(",").map((part) => {
    const value = Number.parseInt(part.trim(), 10);
    if (!Number.isInteger(value) || value < 0 || value > 255) {
      throw new Error(`${spec}: not a comma-separated list of bit depths`);
    }
    return value;
  });
}

async function run(input: string, output: string, depths: number[]): Promise<void> {
  const source = await FileHandleReadable.open(input);
  let scene;
  try {
    scene = await decodeScene(source, { blockSize: 8 * 1024 });
  } finally {
    await source.close();
  }
  const g = scene.gaussians;

  const gaussians: GaussianInput = {
    count: g.count,
    positions: g.positions,
    scales: g.scales,
    rotations: g.rotations,
    colors: g.colors,
    motions: g.motions,
    muT: g.muT,
    sigmaT: g.sigmaT,
    winLo: g.winLo,
    winHi: g.winHi,
    sh: g.sh ? g.sh.values : null,
    shDegree: g.sh ? g.sh.degree : 0,
    shCoefficients: g.sh ? g.sh.coefficients : 0,
  };

  // The gaussians-only preset, matching the Rust reference: a small chunk threshold so the
  // corpus scenes exercise the tree, the whole summary written, the profile and attributes
  // carried through, the library left at the encoder's default.
  const bytes = await encodeScene(gaussians, scene.header.durationSec, {
    cutoff: scene.header.cutoff,
    maxDepth: 4,
    minChunkGaussians: 8,
    writeIndex: true,
    writeStatistics: true,
    writeSummaryOffsets: true,
    writeCrc: true,
    shBands: 3,
    shBitDepths: depths,
    profile: scene.header.profile,
    attributes: Object.fromEntries(scene.header.attributes),
  });

  writeFileSync(output, bytes);
  process.stdout.write(`${g.count} gaussians, ${bytes.length} bytes\n`);
}

const [input, output, depthSpec] = process.argv.slice(2);
if (input === undefined || output === undefined) {
  process.stderr.write("usage: encode_roundtrip.js <in.4dgs> <out.4dgs> [sh-bit-depths]\n");
  process.exit(2);
}
await run(input, output, depthSpec === undefined ? [] : parseDepths(depthSpec));
