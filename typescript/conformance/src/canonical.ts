// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The canonical JSON two implementations are diffed on.
 *
 * This is a restatement of `tests/conformance/canonical.py` in TypeScript, and it has to
 * agree with it digit for digit, so the representation rules are copied deliberately
 * rather than reinvented:
 *
 * - integers are strings, so a 64-bit value survives a JSON parser backed by doubles;
 * - floats are rounded to a fixed number of decimals before comparison;
 * - a never-fading gaussian's sigma is `null`, never a sentinel;
 * - `audio` is `null` when absent and an object when present, so both paths are visible;
 * - keys are sorted.
 *
 * Rounding is round-half-to-even on the value's exact decimal expansion, which is what
 * Python's `round` does. `toFixed` rounds halves away from zero, so it cannot be used on
 * its own: the two disagree on values like `0.0078125`, and every value a decoder
 * produces is a float32, whose exact ties are precisely those numbers.
 */

import type { AudioTrack, GaussianSet, Header } from "@4dgs/core";

export const FLOAT_DECIMALS = 6;

/** Decimal places that expand a near-tie exactly. See {@link roundHalfEven}. */
const EXACT_DECIMALS = 100;

/** How many gaussians appear in full. The aggregates cover the rest. */
export const SAMPLE = 16;

/** Round for comparison; a non-finite value becomes `null`, which JSON can spell. */
export function num(value: number | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  if (!Number.isFinite(value)) return null;
  return roundHalfEven(value, FLOAT_DECIMALS);
}

/**
 * Round to `decimals` places, halves to even, on the exact value.
 *
 * The expansion has to be exact, not merely long: a double a hair above a tie and one
 * exactly on it round differently, and they agree for the first twenty digits. A hundred
 * places is exact for every value that can be near a six-decimal tie — such a value is at
 * least 5e-7, whose exact expansion ends by the seventy-third decimal.
 */
export function roundHalfEven(value: number, decimals: number): number {
  if (!Number.isFinite(value) || Math.abs(value) >= 1e21) return value;
  const negative = value < 0;
  const text = Math.abs(value).toFixed(EXACT_DECIMALS);
  const dot = text.indexOf(".");
  const digits = text.slice(0, dot) + text.slice(dot + 1);
  const keep = dot + decimals;
  const kept = digits.slice(0, keep);
  const rest = digits.slice(keep);

  let roundUp = false;
  const first = rest.charCodeAt(0) - 48;
  if (first > 5) {
    roundUp = true;
  } else if (first === 5) {
    const remainder = rest.slice(1);
    // A tie goes to the even neighbour; anything past the half goes up.
    roundUp = /[1-9]/.test(remainder) ? true : (kept.charCodeAt(keep - 1) - 48) % 2 === 1;
  }

  const scaled = BigInt(kept) + (roundUp ? 1n : 0n);
  const out = Number(scaled) / 10 ** decimals;
  return negative ? -out : out;
}

export interface SceneSummaryInput {
  readonly header: Pick<Header, "durationSec" | "shDegree" | "temporalModel" | "hasAudio">;
  readonly gaussians: GaussianSet;
  readonly audio: AudioTrack | null;
  readonly chunkIntervals: readonly (readonly [number, number])[];
}

/** The statement every implementation must agree on for a variant. */
export function summarize(input: SceneSummaryInput): unknown {
  const { header, gaussians, audio, chunkIntervals } = input;
  const n = gaussians.count;
  const sample = stableOrder(gaussians).slice(0, SAMPLE);

  const rows = (array: Float32Array, width: number): (number | null)[][] =>
    sample.map((i) => {
      const row: (number | null)[] = [];
      for (let k = 0; k < width; k++) row.push(num(array[i * width + k]));
      return row;
    });

  const positionSum = [0, 0, 0];
  let alphaSum = 0;
  let neverFades = 0;
  let still = 0;
  for (let i = 0; i < n; i++) {
    positionSum[0]! += gaussians.positions[i * 3]!;
    positionSum[1]! += gaussians.positions[i * 3 + 1]!;
    positionSum[2]! += gaussians.positions[i * 3 + 2]!;
    alphaSum += gaussians.colors[i * 4 + 3]!;
    if (!Number.isFinite(gaussians.sigmaT[i]!)) neverFades += 1;
    const m = gaussians.motions;
    if (Math.abs(m[i * 3]!) + Math.abs(m[i * 3 + 1]!) + Math.abs(m[i * 3 + 2]!) === 0) still += 1;
  }

  return {
    gaussianCount: String(n),
    durationSec: num(header.durationSec),
    shDegree: header.shDegree,
    temporalModel: header.temporalModel,
    hasAudio: header.hasAudio,
    // Absent audio is a value, not a missing key: both paths are conformance-visible.
    audio:
      audio === null ? null : { codec: audio.codec, byteLength: String(audio.data.byteLength) },
    chunkIntervals: chunkIntervals.map(([a, b]) => [num(a), num(b)]),
    sample: {
      indices: sample.map((i) => String(i)),
      positions: rows(gaussians.positions, 3),
      scales: rows(gaussians.scales, 3),
      rotations: rows(gaussians.rotations, 4),
      colors: rows(gaussians.colors, 4),
      motions: rows(gaussians.motions, 3),
      muT: sample.map((i) => num(gaussians.muT[i])),
      sigmaT: sample.map((i) => num(gaussians.sigmaT[i])),
      winLo: sample.map((i) => num(gaussians.winLo[i])),
      winHi: sample.map((i) => num(gaussians.winHi[i])),
    },
    aggregate: {
      positionSum: positionSum.map((v) => num(v)),
      opacitySum: num(alphaSum),
      neverFadesCount: String(neverFades),
      zeroMotionCount: String(still),
    },
  };
}

/**
 * Sort gaussians into an order both implementations can reproduce.
 *
 * Chunking and spatial ordering are encoder choices, so decoded order is not part of the
 * contract — but a comparison needs some order. Sorting on decoded values gives one
 * without making the encoder's choices normative.
 */
function stableOrder(gaussians: GaussianSet): number[] {
  const keys = new Array<[number, number, number, number]>(gaussians.count);
  for (let i = 0; i < gaussians.count; i++) {
    keys[i] = [
      roundHalfEven(gaussians.positions[i * 3]!, 6),
      roundHalfEven(gaussians.positions[i * 3 + 1]!, 6),
      roundHalfEven(gaussians.positions[i * 3 + 2]!, 6),
      i,
    ];
  }
  keys.sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || a[3] - b[3]);
  return keys.map((k) => k[3]);
}

/** Stable JSON: sorted keys, two-space indent, the shape the expectations are stored in. */
export function canonical(summary: unknown): string {
  return JSON.stringify(sortKeys(summary), null, 2);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = sortKeys((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}
