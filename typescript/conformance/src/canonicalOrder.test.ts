// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";

import { GaussianSet } from "@4dgs/core";

import { canonical, exactSum, ExactNumber, summarize } from "./canonical.js";

const DURATION = 4_000_000;

interface StateSummary {
  readonly states: readonly {
    readonly sample: { readonly positions: readonly (readonly (number | null)[])[] };
    readonly aggregate: { readonly positionSum: readonly (ExactNumber | null)[] };
  }[];
}

function gaussianSet(
  positions: readonly (readonly number[])[],
  motions: readonly (readonly number[])[],
): GaussianSet {
  const count = positions.length;
  return new GaussianSet({
    count,
    positions: Float32Array.from(positions.flat()),
    scales: Float32Array.from({ length: count * 3 }, () => 1),
    rotations: Float32Array.from({ length: count * 4 }, (_, i) => (i % 4 === 3 ? 1 : 0)),
    colors: Float32Array.from({ length: count * 4 }, (_, i) => (i % 4 === 3 ? 1 : 0)),
    motions: Float32Array.from(motions.flat()),
    muT: new Float32Array(count),
    sigmaT: Float32Array.from({ length: count }, () => Infinity),
    winLo: new Float32Array(count),
    winHi: Float32Array.from({ length: count }, () => DURATION),
    objectId: new Uint32Array(count),
  });
}

function permuted(gaussians: GaussianSet, order: readonly number[]): GaussianSet {
  const rows = (values: Float32Array, width: number): Float32Array =>
    Float32Array.from(
      order.flatMap((index) => [...values.subarray(index * width, (index + 1) * width)]),
    );
  const scalars = (values: Float32Array): Float32Array =>
    Float32Array.from(order.map((index) => values[index]!));

  return new GaussianSet({
    count: gaussians.count,
    positions: rows(gaussians.positions, 3),
    scales: rows(gaussians.scales, 3),
    rotations: rows(gaussians.rotations, 4),
    colors: rows(gaussians.colors, 4),
    motions: rows(gaussians.motions, 3),
    muT: scalars(gaussians.muT),
    sigmaT: scalars(gaussians.sigmaT),
    winLo: scalars(gaussians.winLo),
    winHi: scalars(gaussians.winHi),
    objectId: Uint32Array.from(order.map((index) => gaussians.objectId![index]!)),
  });
}

function summary(gaussians: GaussianSet): StateSummary {
  return summarize({
    header: {
      durationSec: DURATION,
      cutoff: 0.05,
      profile: "default",
      library: "canonical-order-test",
      shDegree: 0,
      temporalModel: "gaussian-birth",
      hasAudio: false,
      attributes: new Map(),
    },
    gaussians,
    audioSources: [],
    chunkIntervals: [],
  }) as StateSummary;
}

test("emitted composed rows break rounded stored-key ties", () => {
  const gaussians = gaussianSet(
    [
      [1e-7, 0, 0],
      [4e-7, 0, 0],
    ],
    [
      [4e-7, 0, 0],
      [1e-7, 0, 0],
    ],
  );

  const forward = summary(gaussians);
  const reversed = summary(permuted(gaussians, [1, 0]));

  assert.deepEqual(forward, reversed);
  assert.deepEqual(forward.states[1]!.sample.positions, [
    [0.2, 0, 0],
    [0.8, 0, 0],
  ]);
});

test("state aggregates sum in emitted content order", () => {
  const gaussians = gaussianSet(
    [
      [1577422159872, 0, 0],
      [1e-4, 0, 0],
      [1e-4, 0, 0],
    ],
    Array.from({ length: 3 }, () => [0, 0, 0]),
  );

  const cancellationFirst = summary(gaussians);
  const cancellationLast = summary(permuted(gaussians, [1, 2, 0]));

  assert.deepEqual(cancellationFirst, cancellationLast);
  assert.deepEqual(
    cancellationFirst.states[0]!.aggregate.positionSum.map((value) => value?.token ?? null),
    ["1577422159872.0002", "0.0", "0.0"],
  );
});

test("canonical aggregates retain arbitrary precision JSON number tokens", () => {
  const forward = exactSum([1e16, 1, -1e16]);
  const reversed = exactSum([-1e16, 1, 1e16]);
  assert.equal(forward?.token, "1.0");
  assert.equal(reversed?.token, "1.0");
  assert.equal(exactSum([-0])?.token, "0.0");
  assert.equal(exactSum([1, Number.POSITIVE_INFINITY]), null);

  const huge = exactSum(Array.from({ length: 10 }, () => 1e308));
  assert.ok(huge instanceof ExactNumber);
  assert.equal(huge.token.split(".")[0]!.length, 310);
  const text = canonical({ total: huge });
  assert.ok(text.includes(`"total": ${huge.token}`));
  assert.ok(!text.includes(`"${huge.token}"`));
});
