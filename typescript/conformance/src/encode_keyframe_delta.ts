// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Write every `keyframe-delta` sequence in {@link KEYFRAME_DELTA_VARIANTS} to a directory.
 *
 * Beside each `<name>.4dgs` it writes `<name>.samples.json` — the populations that went in,
 * lane by lane. That file is the *source*, and it is what `typescript/keyframe-delta-roundtrip.sh`
 * holds the written bytes against: four decoders agreeing about one file say nothing about
 * whether that file is the scene that went in, so the scene has to leave the encoder in a
 * form another language can read.
 *
 *     node encode_keyframe_delta.js <output-dir>
 */

import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { encodeKeyframeDeltaSequence } from "@4dgs/core";

import {
  CORPUS_LIBRARY,
  KEYFRAME_DELTA_DURATION,
  KEYFRAME_DELTA_VARIANTS,
} from "./keyframeDeltaSequences.js";

function lanes(g: {
  count: number;
  positions: ArrayLike<number>;
  scales: ArrayLike<number>;
  rotations: ArrayLike<number>;
  colors: ArrayLike<number>;
  motions: ArrayLike<number>;
  muT: ArrayLike<number>;
  sigmaT: ArrayLike<number>;
  winLo: ArrayLike<number>;
  winHi: ArrayLike<number>;
}): Record<string, unknown> {
  const of = (a: ArrayLike<number>): number[] => Array.from(a, (v) => v);
  return {
    count: g.count,
    positions: of(g.positions),
    scales: of(g.scales),
    rotations: of(g.rotations),
    colors: of(g.colors),
    motions: of(g.motions),
    muT: of(g.muT),
    sigmaT: of(g.sigmaT),
    winLo: of(g.winLo),
    winHi: of(g.winHi),
  };
}

const out = process.argv[2];
if (out === undefined) {
  process.stderr.write("usage: encode_keyframe_delta.js <output-dir>\n");
  process.exit(2);
}

for (const variant of KEYFRAME_DELTA_VARIANTS) {
  const bytes = await encodeKeyframeDeltaSequence(variant.samples, KEYFRAME_DELTA_DURATION, {
    keyframeEvery: variant.keyframeEvery,
    deltaMode: variant.deltaMode,
    library: CORPUS_LIBRARY,
  });
  writeFileSync(join(out, `${variant.name}.4dgs`), bytes);
  writeFileSync(
    join(out, `${variant.name}.samples.json`),
    JSON.stringify({
      durationSec: KEYFRAME_DELTA_DURATION,
      inCorpus: variant.inCorpus,
      crossLanguage: variant.crossLanguage,
      samples: variant.samples.map((s) => ({
        t0: s.t0,
        ids: Array.from(s.ids, (v) => v),
        gaussians: lanes(s.gaussians as Parameters<typeof lanes>[0]),
      })),
    }),
  );
  process.stdout.write(`${variant.name} ${bytes.length}\n`);
}
