// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The decoded scene: gaussians on one clock.
 *
 * There are no frames here and none anywhere else in this package. Each gaussian carries
 * its own temporal description, so the number alive at any instant follows from the data
 * rather than from a frame count someone had to choose.
 *
 * Reconstructing state at a time `t` is where decoding ends. What happens to these
 * numbers afterwards is not this package's concern.
 */

import type { ChunkGaussians } from "./chunk.js";
import { DEFAULT_CUTOFF, supportK } from "./quantization.js";
import type { ShCoefficients } from "./sh.js";

/** Every gaussian in a scene, structure-of-arrays, in decoded order. */
export class GaussianSet {
  readonly count: number;
  /** `count × 3`, rest positions. */
  readonly positions: Float32Array;
  /** `count × 3`, linear scale. */
  readonly scales: Float32Array;
  /** `count × 4`, unit quaternion, xyzw. */
  readonly rotations: Float32Array;
  /** `count × 4`, linear RGB and opacity, each in [0, 1]. */
  readonly colors: Float32Array;
  /** `count × 3`, linear velocity in units per second. */
  readonly motions: Float32Array;
  /** `count`, temporal centre in seconds. */
  readonly muT: Float32Array;
  /** `count`, temporal standard deviation; `+Infinity` means the gaussian never fades. */
  readonly sigmaT: Float32Array;
  /** `count`, validity window start. */
  readonly winLo: Float32Array;
  /** `count`, validity window end, exclusive. */
  readonly winHi: Float32Array;
  readonly sh: ShCoefficients | null;
  readonly shDegree: number;

  constructor(fields: {
    count: number;
    positions: Float32Array;
    scales: Float32Array;
    rotations: Float32Array;
    colors: Float32Array;
    motions: Float32Array;
    muT: Float32Array;
    sigmaT: Float32Array;
    winLo: Float32Array;
    winHi: Float32Array;
    sh?: ShCoefficients | null;
    shDegree?: number;
  }) {
    this.count = fields.count;
    this.positions = fields.positions;
    this.scales = fields.scales;
    this.rotations = fields.rotations;
    this.colors = fields.colors;
    this.motions = fields.motions;
    this.muT = fields.muT;
    this.sigmaT = fields.sigmaT;
    this.winLo = fields.winLo;
    this.winHi = fields.winHi;
    this.sh = fields.sh ?? null;
    this.shDegree = fields.shDegree ?? 0;
  }

  static empty(shDegree = 0): GaussianSet {
    return new GaussianSet({
      count: 0,
      positions: new Float32Array(0),
      scales: new Float32Array(0),
      rotations: new Float32Array(0),
      colors: new Float32Array(0),
      motions: new Float32Array(0),
      muT: new Float32Array(0),
      sigmaT: new Float32Array(0),
      winLo: new Float32Array(0),
      winHi: new Float32Array(0),
      shDegree,
    });
  }

  /**
   * The state the specification defines at scene time `t`.
   *
   * The validity window is the only hard temporal gate: outside it a gaussian does not
   * exist at that time, whatever its marginal. Inside it, the marginal fades the opacity
   * and the linear velocity moves the centre.
   */
  stateAt(t: number, cutoff = DEFAULT_CUTOFF): GaussianState {
    const visible: number[] = [];
    for (let i = 0; i < this.count; i++) {
      if (!(this.winLo[i]! <= t && t < this.winHi[i]!)) continue;
      if (marginalAt(this.muT[i]!, this.sigmaT[i]!, t) >= cutoff) visible.push(i);
    }
    const indices = Uint32Array.from(visible);
    const centers = new Float32Array(indices.length * 3);
    const opacity = new Float32Array(indices.length);
    for (let k = 0; k < indices.length; k++) {
      const i = indices[k]!;
      const dt = t - this.muT[i]!;
      centers[k * 3] = this.positions[i * 3]! + this.motions[i * 3]! * dt;
      centers[k * 3 + 1] = this.positions[i * 3 + 1]! + this.motions[i * 3 + 1]! * dt;
      centers[k * 3 + 2] = this.positions[i * 3 + 2]! + this.motions[i * 3 + 2]! * dt;
      opacity[k] = this.colors[i * 4 + 3]! * marginalAt(this.muT[i]!, this.sigmaT[i]!, t);
    }
    return { t, indices, centers, opacity };
  }

  /** Per-gaussian visible interval, clipped to the validity window. */
  support(index: number, cutoff = DEFAULT_CUTOFF): readonly [number, number] {
    const sigma = this.sigmaT[index]!;
    const mu = this.muT[index]!;
    const half = Number.isFinite(sigma) ? supportK(cutoff) * sigma : Infinity;
    return [Math.max(mu - half, this.winLo[index]!), Math.min(mu + half, this.winHi[index]!)];
  }
}

/** Which gaussians exist at an instant, where they are, and how opaque they are. */
export interface GaussianState {
  readonly t: number;
  readonly indices: Uint32Array;
  /** `indices.length × 3`. */
  readonly centers: Float32Array;
  readonly opacity: Float32Array;
}

/** The soft temporal weight of a gaussian at a time. 1 for a gaussian that never fades. */
export function marginalAt(muT: number, sigmaT: number, t: number): number {
  if (!Number.isFinite(sigmaT)) return 1;
  const z = (t - muT) / sigmaT;
  return Math.exp(-0.5 * z * z);
}

/**
 * Concatenate decoded chunks and resolve each gaussian's validity window.
 *
 * Chunk order is the order the reader visited them in, and gaussian order within a chunk
 * is the encoder's. Neither is part of the contract — nothing in the format depends on
 * gaussian order and no reader may assume one.
 */
export function assembleGaussians(
  chunks: readonly ChunkGaussians[],
  windows: Float64Array,
  shDegree: number,
  sh: ShCoefficients | null = null,
): GaussianSet {
  let count = 0;
  for (const chunk of chunks) count += chunk.count;
  if (count === 0) return GaussianSet.empty(shDegree);

  const positions = new Float32Array(count * 3);
  const scales = new Float32Array(count * 3);
  const rotations = new Float32Array(count * 4);
  const colors = new Float32Array(count * 4);
  const motions = new Float32Array(count * 3);
  const muT = new Float32Array(count);
  const sigmaT = new Float32Array(count);
  const winLo = new Float32Array(count);
  const winHi = new Float32Array(count);

  const windowCount = windows.length >>> 1;
  let at = 0;
  for (const chunk of chunks) {
    positions.set(chunk.positions, at * 3);
    scales.set(chunk.scales, at * 3);
    rotations.set(chunk.rotations, at * 4);
    colors.set(chunk.colors, at * 4);
    motions.set(chunk.motions, at * 3);
    muT.set(chunk.muT, at);
    sigmaT.set(chunk.sigmaT, at);
    for (let i = 0; i < chunk.count; i++) {
      const w = Math.min(Math.max(chunk.windowIndex[i]!, 0), Math.max(windowCount - 1, 0));
      winLo[at + i] = windowCount > 0 ? windows[w * 2]! : 0;
      winHi[at + i] = windowCount > 0 ? windows[w * 2 + 1]! : 0;
    }
    at += chunk.count;
  }

  return new GaussianSet({
    count,
    positions,
    scales,
    rotations,
    colors,
    motions,
    muT,
    sigmaT,
    winLo,
    winHi,
    sh,
    shDegree,
  });
}
