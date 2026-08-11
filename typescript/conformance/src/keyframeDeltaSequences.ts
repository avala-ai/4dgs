// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The sample sequences the `keyframe-delta` encoder is proved on.
 *
 * The first four rebuild, in TypeScript, exactly the populations
 * `tests/conformance/generate.py` hands the Python reference writer — same positions, same
 * identities, same cadence, same delta mode. That is what makes the claim a cross-language
 * one: a file this encoder writes from these samples must decode, in Python and here, to the
 * canonical `states` JSON the corpus already commits for the Python-written file. Nothing
 * about the byte layout has to match for that; everything about what the file *means* does.
 *
 * `Textured` is this side's own, and it exists because the corpus four are deliberately flat
 * — one window, one sigma, no rotation, no velocity — so a fidelity check run only on them
 * would leave most lanes unexercised. It varies rotation, sigma, velocity, birth time and
 * the validity window per gaussian, which is what puts the per-gaussian motion and mu grids
 * (spec §6.3) and the multi-entry Window Table under the same comparison.
 */

import { DELTA_MODE_CHAINED, DELTA_MODE_KEYFRAME, type KeyframeDeltaSample } from "@4dgs/core";

/** Seconds and sample count of the synthetic sequences, matching the corpus generator. */
const STEPS = 8;
const DURATION = 8.0;

/** A population at one instant: finite sigma, one shared full-duration window. */
function flat(
  positions: readonly (readonly [number, number, number])[],
): KeyframeDeltaSample["gaussians"] {
  const n = positions.length;
  return {
    count: n,
    positions: Float32Array.from(positions.flat()),
    scales: Float32Array.from({ length: n * 3 }, () => 0.05),
    rotations: Float32Array.from({ length: n * 4 }, (_, i) => (i % 4 === 3 ? 1 : 0)),
    colors: Float32Array.from({ length: n * 4 }, (_, i) => [0.6, 0.4, 0.2, 0.9][i % 4]!),
    motions: new Float32Array(n * 3),
    muT: new Float32Array(n),
    // Finite, and effectively non-fading over the clip. A never-fading gaussian would take
    // its velocity grid from its validity window instead, which this writer does not vary.
    sigmaT: Float32Array.from({ length: n }, () => 100.0),
    winLo: new Float32Array(n),
    winHi: Float32Array.from({ length: n }, () => DURATION),
  };
}

/** A fixed population of four gaussians that drifts: every delta is a pure update. */
function drift(): KeyframeDeltaSample[] {
  const out: KeyframeDeltaSample[] = [];
  for (let i = 0; i < STEPS; i++) {
    out.push({
      t0: i * (DURATION / STEPS),
      ids: [0, 1, 2, 3],
      gaussians: flat([
        [i * 0.1, 0, 0],
        [1, i * 0.05, 0],
        [0, 1, i * 0.03],
        [1, 1, 0],
      ]),
    });
  }
  return out;
}

/** A drifting population with one birth (id 4) and one death (id 2). */
function churn(): KeyframeDeltaSample[] {
  const out: KeyframeDeltaSample[] = [];
  for (let i = 0; i < STEPS; i++) {
    let ids = [0, 1, 2, 3];
    let base: [number, number, number][] = [
      [i * 0.1, 0, 0],
      [1, i * 0.05, 0],
      [0, 1, 0],
      [1, 1, 0],
    ];
    if (i >= 2) {
      ids = [...ids, 4];
      base = [...base, [2, 2, i * 0.02]];
    }
    if (i >= 5 && ids.includes(2)) {
      const keep = ids.map((_, k) => k).filter((k) => ids[k] !== 2);
      ids = keep.map((k) => ids[k]!);
      base = keep.map((k) => base[k]!);
    }
    out.push({ t0: i * (DURATION / STEPS), ids, gaussians: flat(base) });
  }
  return out;
}

/**
 * Six gaussians whose rotation, colour, scale, velocity, birth time, sigma and validity
 * window all differ, and which drift and rotate over the clip. Two windows, so the Window
 * Table has more than one row and `window_index` has to name the right one.
 */
function textured(): KeyframeDeltaSample[] {
  const n = 6;
  const out: KeyframeDeltaSample[] = [];
  for (let step = 0; step < STEPS; step++) {
    const t = step * (DURATION / STEPS);
    const positions = new Float32Array(n * 3);
    const scales = new Float32Array(n * 3);
    const rotations = new Float32Array(n * 4);
    const colors = new Float32Array(n * 4);
    const motions = new Float32Array(n * 3);
    const muT = new Float32Array(n);
    const sigmaT = new Float32Array(n);
    const winLo = new Float32Array(n);
    const winHi = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      positions[i * 3] = 0.3 * i + 0.11 * step;
      positions[i * 3 + 1] = -0.7 + 0.05 * i * step;
      positions[i * 3 + 2] = 0.25 * step - 0.4 * i;
      for (let a = 0; a < 3; a++) scales[i * 3 + a] = 0.02 + 0.013 * i + 0.004 * a;
      // A rotation about a tilted axis, turning as the clip runs.
      const angle = 0.21 * i + 0.37 * step;
      const axis = [0.3, 0.6, Math.sqrt(1 - 0.09 - 0.36)];
      const s = Math.sin(angle / 2);
      rotations[i * 4] = axis[0]! * s;
      rotations[i * 4 + 1] = axis[1]! * s;
      rotations[i * 4 + 2] = axis[2]! * s;
      rotations[i * 4 + 3] = Math.cos(angle / 2);
      colors[i * 4] = 0.1 + 0.14 * i;
      colors[i * 4 + 1] = 0.9 - 0.11 * i;
      colors[i * 4 + 2] = 0.33 + 0.07 * i;
      colors[i * 4 + 3] = 0.4 + 0.09 * i;
      motions[i * 3] = 0.13 * (i - 2);
      motions[i * 3 + 1] = -0.06 * i;
      motions[i * 3 + 2] = 0.21;
      // GOP-invariant: sigma, flags and window_index are fixed for a gaussian's lifetime
      // (spec §11.5), so they are a function of `i` alone and never of `step`.
      muT[i] = 0.5 + 0.9 * i;
      sigmaT[i] = 0.35 + 0.6 * i;
      const second = i % 2 === 1;
      winLo[i] = second ? 1.5 : 0;
      winHi[i] = second ? 6.5 : DURATION;
    }
    out.push({
      t0: t,
      ids: Array.from({ length: n }, (_, i) => 100 + i),
      gaussians: {
        count: n,
        positions,
        scales,
        rotations,
        colors,
        motions,
        muT,
        sigmaT,
        winLo,
        winHi,
      },
    });
  }
  return out;
}

/** One sequence to encode: the name it is written under, and how. */
export interface KeyframeDeltaVariant {
  readonly name: string;
  readonly samples: KeyframeDeltaSample[];
  readonly keyframeEvery: number;
  readonly deltaMode: number;
  /**
   * True when `tests/conformance/data/keyframe/<name>.json` is the statement this file must
   * decode to. False for a sequence this side invented, which has no committed expectation
   * and is held only to the fidelity and cross-decoder claims.
   */
  readonly inCorpus: boolean;
  /**
   * True when the reconstruction summary may be compared across languages.
   *
   * False only for `Textured`, and for a decoder defect this pull request does not own:
   * **#185**, where the Python reference applies §3's validity-window gate during
   * `keyframe-delta` reconstruction and Rust and TypeScript do not. A sequence whose windows
   * do not all cover the clip therefore reconstructs to a different population in Python than
   * here — at `t = 0` Python reports three gaussians and this decoder six — and the two
   * summaries differ over a difference in *decoding*, not in what the encoder wrote. Its
   * chunk rows, which is everything the writer decides, agree exactly. Both read paths in
   * each language are still required to agree, and the fidelity check below still runs
   * through the Python decoder, so the multi-window lanes are covered by the claim that can
   * carry them. Set this true when #185 lands.
   */
  readonly crossLanguage: boolean;
}

export const KEYFRAME_DELTA_DURATION = DURATION;

/**
 * The library string the corpus was written with. Passed so a byte-level comparison against
 * the corpus file is not defeated by the producer name, which is not part of what a file
 * means and is dropped from the canonical summary anyway.
 */
export const CORPUS_LIBRARY = "4dgs conformance generator";

export const KEYFRAME_DELTA_VARIANTS: readonly KeyframeDeltaVariant[] = [
  {
    name: "KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics",
    samples: churn(),
    keyframeEvery: 1,
    deltaMode: DELTA_MODE_CHAINED,
    inCorpus: true,
    crossLanguage: true,
  },
  {
    name: "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics",
    samples: drift(),
    keyframeEvery: 4,
    deltaMode: DELTA_MODE_CHAINED,
    inCorpus: true,
    crossLanguage: true,
  },
  {
    name: "KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics",
    samples: churn(),
    keyframeEvery: 4,
    deltaMode: DELTA_MODE_CHAINED,
    inCorpus: true,
    crossLanguage: true,
  },
  {
    name: "KeyframeDeltaModesMixed-UseChunkIndex-UseCrc-UseStatistics",
    samples: churn(),
    keyframeEvery: 4,
    deltaMode: DELTA_MODE_KEYFRAME,
    inCorpus: true,
    crossLanguage: true,
  },
  {
    name: "Textured-TwoWindows-UseChunkIndex-UseCrc-UseStatistics",
    samples: textured(),
    keyframeEvery: 4,
    deltaMode: DELTA_MODE_CHAINED,
    inCorpus: false,
    crossLanguage: false,
  },
];
