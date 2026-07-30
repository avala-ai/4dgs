// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The canonical JSON two implementations are diffed on for a `keyframe-delta` file.
 *
 * This is a restatement of `keyframe_delta_file.states_json` in TypeScript, and it has to
 * agree with it digit for digit. Its shape is deliberately not the `gaussian-birth`
 * `summarize` shape (§canonical.ts): a keyframe-delta file's statement is a reconstruction
 * *at an instant*, which the per-file summary could never carry.
 *
 * - `chunks` proves a decoder read `depth`, `deltaMode` and `liveCount` — a field no row
 *   mentions is one an implementation can decline to decode;
 * - `states` is, for each probe instant, the composed population's live count, a sample of
 *   centres and scales in `gaussian_id` order, and the aggregate over the whole population.
 *
 * Integers are strings and floats are rounded exactly as {@link num} rounds them, so a
 * 64-bit value survives a double-backed parser and two decoders agree on every digit.
 */

import {
  DELTA_MODE_CHAINED,
  type DecodedSequence,
  gridsFor,
  probeTimes,
  reconstructAt,
  stateCount,
  stateCovering,
} from "@4dgs/core";

import { num, SAMPLE } from "./canonical.js";

export function keyframeDeltaStates(decoded: DecodedSequence): unknown {
  const grids = gridsFor(decoded);
  const duration = decoded.header.durationSec;

  const chunkRows = decoded.chunks.map((c) => ({
    t0: num(c.t0),
    t1: num(c.t1),
    kind: c.kind === 0 ? "keyframe" : "delta",
    deltaMode: c.kind === 0 ? null : c.deltaMode === DELTA_MODE_CHAINED ? "chained" : "keyframe",
    depth: String(c.depth),
    liveCount: String(stateCount(c.state)),
    updateCount: c.updateCount === null ? null : String(c.updateCount),
    birthCount: c.birthCount === null ? null : String(c.birthCount),
    deathCount: c.deathCount === null ? null : String(c.deathCount),
  }));

  const states = probeTimes(decoded.chunks, duration).map((t) => {
    const info = stateCovering(decoded.chunks, t);
    const r = reconstructAt(info.state, grids, t);
    const total = r.ids.length;
    const sampleN = Math.min(SAMPLE, total);

    const positions: (number | null)[][] = [];
    const scales: (number | null)[][] = [];
    const gaussianIds: string[] = [];
    for (let i = 0; i < sampleN; i++) {
      gaussianIds.push(String(r.ids[i]!));
      positions.push([
        num(r.centers[i * 3]!),
        num(r.centers[i * 3 + 1]!),
        num(r.centers[i * 3 + 2]!),
      ]);
      scales.push([num(r.scales[i * 3]!), num(r.scales[i * 3 + 1]!), num(r.scales[i * 3 + 2]!)]);
    }

    const positionSum = [0, 0, 0];
    let opacitySum = 0;
    for (let i = 0; i < total; i++) {
      positionSum[0]! += r.centers[i * 3]!;
      positionSum[1]! += r.centers[i * 3 + 1]!;
      positionSum[2]! += r.centers[i * 3 + 2]!;
      opacitySum += r.opacity[i]!;
    }

    return {
      t: num(t),
      liveCount: String(stateCount(info.state)),
      sample: {
        gaussianIds,
        positions,
        scales: total === 0 ? [] : scales,
      },
      aggregate: {
        positionSum: positionSum.map((v) => num(v)),
        opacitySum: num(opacitySum),
      },
    };
  });

  return {
    temporalModel: "keyframe-delta",
    gaussianCount: String(decoded.header.gaussianCount),
    durationSec: num(duration),
    cutoff: num(decoded.header.cutoff),
    chunks: chunkRows,
    states,
  };
}
