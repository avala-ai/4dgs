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

import { unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";

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

function pythonSummary(path: string): Record<string, unknown> {
  const result = spawnSync("python3", ["python/conformance/decode_streamed.py", path], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`Python refused the TypeScript objects proof for ${path}:\n${result.stderr}`);
  }
  return JSON.parse(result.stdout) as Record<string, unknown>;
}

const membershipScript = String.raw`
import hashlib, json, os, sys
root = os.getcwd()
sys.path.insert(0, os.path.join(root, "python", "fourdgs"))
sys.path.insert(0, os.path.join(root, "tests", "conformance"))
import fourdgs
from canonical import _stable_order

claims = []
for path in sys.argv[1:]:
    scene = fourdgs.read(path)
    ids = scene.gaussians.object_id
    if ids is None:
        claims.append({"count": 0, "sha256": None})
        continue
    digest = hashlib.sha256()
    block = bytearray()
    for index in _stable_order(scene.gaussians):
        block += int(ids[index]).to_bytes(4, "little", signed=False)
        if len(block) >= 64 * 1024:
            digest.update(block)
            block.clear()
    digest.update(block)
    claims.append({"count": len(ids), "sha256": digest.hexdigest()})
print(json.dumps(claims))
`;

function pythonMembership(paths: string[]): unknown[] {
  const result = spawnSync("python3", ["-c", membershipScript, ...paths], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`Python refused the complete membership proof:\n${result.stderr}`);
  }
  return JSON.parse(result.stdout) as unknown[];
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
    objectId: g.objectId,
  };

  // The ordinary agreement preset below is deliberately gaussian-only, so an
  // `objects` source must refuse once its Object Table is omitted. Before that
  // negative assertion, positively exercise the complete writer surface: emit
  // the decoded table/tracks, then have the independent Python implementation
  // decode both files and compare the object records (including sampled track
  // poses) and membership. The temporary file is bounded to one encoded scene and
  // removed before this runner returns.
  if (scene.header.profile === "objects") {
    const proof = `${output}.objects-proof.4dgs`;
    try {
      const proofBytes = await encodeScene(gaussians, scene.header.durationSec, {
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
        objects: scene.objects,
      });
      writeFileSync(proof, proofBytes);
      const sourceSummary = pythonSummary(input);
      const proofSummary = pythonSummary(proof);
      const sourceSample = sourceSummary.sample as Record<string, unknown>;
      const proofSample = proofSummary.sample as Record<string, unknown>;
      const [sourceMembership, proofMembership] = pythonMembership([input, proof]);
      const claims = {
        objects: proofSummary.objects,
        objectIds: proofSample.objectIds,
        completeMembership: proofMembership,
      };
      const expected = {
        objects: sourceSummary.objects,
        objectIds: sourceSample.objectIds,
        completeMembership: sourceMembership,
      };
      if (!isDeepStrictEqual(claims, expected)) {
        throw new Error(
          `Python decoded a different object layer from the TypeScript proof:\n` +
            `expected ${JSON.stringify(expected)}\nactual ${JSON.stringify(claims)}`,
        );
      }
    } finally {
      try {
        unlinkSync(proof);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
  }

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
