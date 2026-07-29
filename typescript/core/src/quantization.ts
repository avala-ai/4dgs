// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Dequantization, including the two grids whose pitch varies per gaussian.
 *
 * Every attribute lands on a uniform grid whose pitch is twice its declared bound, so
 * recovering a value is one multiply-add. The two exceptions are velocity and birth time,
 * whose pitch is derived from the gaussian's own already-decoded sigma bin. There is no
 * side channel for them: a decoder recomputes the pitch from values it has read, with the
 * formulas in specification section 6.3, and a decoder that guesses instead decodes
 * different numbers than the encoder wrote.
 */

import { MalformedFile } from "./errors.js";

/** Grid pitches, as the Quantization record declares them. */
export interface Steps {
  readonly pos: number;
  readonly scaleLog: number;
  readonly rot: number;
  readonly rgb: number;
  readonly alpha: number;
  readonly motion: number;
  readonly time: number;
  readonly sigmaLog: number;
  readonly sh: number;
}

/** The reference lifetime a velocity precision class is measured against, in seconds. */
export const LIFE_REF = 0.5;
export const LIFE_MIN_CLASS = -4;
export const LIFE_MAX_CLASS = 2;
export const LIFE_HALF_MIN = 0.02;
export const LIFE_HALF_MAX = 2.0;

/** Birth-time pitch as a fraction of the gaussian's own sigma. */
export const MU_REL = 0.05;
export const MU_MIN_CLASS = -10;
export const MU_MAX_CLASS = 0;

/** The default marginal visibility threshold, when the Header does not say otherwise. */
export const DEFAULT_CUTOFF = 0.05;

/**
 * Half-width of a gaussian's visible support, in sigmas: `marginal >= cutoff` holds
 * exactly while `|t - mu_t| <= K * sigma_t`.
 */
export function supportK(cutoff: number): number {
  if (!(cutoff > 0 && cutoff <= 1)) {
    throw new MalformedFile(
      `the Header's cutoff is ${cutoff}; a marginal threshold must be in (0, 1]`,
    );
  }
  return Math.sqrt(-2 * Math.log(cutoff));
}

/**
 * Velocity precision class for one gaussian.
 *
 * A velocity error only becomes visible as displacement over the span the gaussian is on
 * screen, so precision follows lifetime. `ceil` rather than `round` is required: the
 * class's nominal lifetime has to be an upper bound on the real one, or the displacement
 * guarantee fails by up to sqrt(2).
 */
export function lifeClass(
  sigmaBin: number,
  sigmaLogStep: number,
  neverFades: boolean,
  windowLength: number,
  k: number,
): number {
  let half = neverFades ? windowLength : k * Math.exp(sigmaBin * sigmaLogStep);
  half = Math.min(Math.max(half, LIFE_HALF_MIN), LIFE_HALF_MAX);
  const cls = Math.ceil(Math.log2(half / LIFE_REF));
  return Math.min(Math.max(cls, LIFE_MIN_CLASS), LIFE_MAX_CLASS);
}

/** The velocity grid pitch for a precision class. */
export function motionStep(lifeClassValue: number, stepMotion: number): number {
  return stepMotion * Math.pow(2, -lifeClassValue);
}

/**
 * Birth-time grid pitch for one gaussian.
 *
 * The temporal term reads `(t - mu_t) / sigma_t`, never `mu_t` alone, so the pitch has to
 * be a fraction of the gaussian's own sigma: a gaussian with a 1 ms sigma and a 2 ms
 * birth-time error is not slightly wrong, it is on when it should be off.
 */
export function muStep(
  sigmaBin: number,
  sigmaLogStep: number,
  neverFades: boolean,
  stepTime: number,
): number {
  const target = neverFades
    ? stepTime
    : Math.min(stepTime, MU_REL * Math.exp(sigmaBin * sigmaLogStep));
  const cls = Math.min(
    Math.max(Math.floor(Math.log2(target / stepTime)), MU_MIN_CLASS),
    MU_MAX_CLASS,
  );
  return stepTime * Math.pow(2, cls);
}

/** Which quaternion components a `rotation_index` keeps, in ascending order. */
const REST_COMPONENTS: readonly (readonly [number, number, number])[] = [
  [1, 2, 3],
  [0, 2, 3],
  [0, 1, 3],
  [0, 1, 2],
];

/**
 * Recover one quaternion from smallest-three coding.
 *
 * The largest-magnitude component was omitted and its sign canonicalized positive, so it
 * comes back as the square root of what the other three leave over. The result is
 * renormalized, which is why `step_rot` bounds the stored components rather than the
 * reconstructed quaternion.
 *
 * Writes `xyzw` into `out` at `outOffset`.
 */
export function dequantizeRotation(
  largest: number,
  bin0: number,
  bin1: number,
  bin2: number,
  step: number,
  out: Float32Array,
  outOffset: number,
): void {
  const rest = REST_COMPONENTS[largest];
  if (rest === undefined) {
    throw new MalformedFile(
      `rotation index ${largest} is outside 0..3; it names which quaternion component was omitted`,
    );
  }
  const a = clamp(bin0 * step, -1, 1);
  const b = clamp(bin1 * step, -1, 1);
  const c = clamp(bin2 * step, -1, 1);
  const q = [0, 0, 0, 0];
  q[rest[0]] = a;
  q[rest[1]] = b;
  q[rest[2]] = c;
  q[largest] = Math.sqrt(Math.max(1 - (a * a + b * b + c * c), 0));
  let norm = Math.sqrt(q[0]! * q[0]! + q[1]! * q[1]! + q[2]! * q[2]! + q[3]! * q[3]!);
  if (norm === 0) norm = 1;
  out[outOffset] = q[0]! / norm;
  out[outOffset + 1] = q[1]! / norm;
  out[outOffset + 2] = q[2]! / norm;
  out[outOffset + 3] = q[3]! / norm;
}

/**
 * Invert the colour transform: bins are stored as `(g, r - g, b - g)`.
 *
 * Exact in the integer domain, so it changes the compressed size and never the error
 * bound.
 */
export function rctInverse(c0: number, c1: number, c2: number): readonly [number, number, number] {
  const g = c0;
  return [c1 + g, g, c2 + g];
}

export function clamp(value: number, lo: number, hi: number): number {
  return value < lo ? lo : value > hi ? hi : value;
}
