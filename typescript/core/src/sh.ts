// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Spherical harmonic bands.
 *
 * A file declares one SH degree for the whole scene, and each band above the constant
 * term is stored in its own record with its own byte range in the chunk index. A reader
 * that has decided to evaluate fewer bands never transfers the ones it will not use.
 *
 * Degrees are whole: band `b` carries every coefficient of that degree for all three
 * colour components, so a reader takes bands 1..D and has exactly a degree-D scene. There
 * is no half a degree, and a reader must not synthesize one by taking part of a band.
 */

import { MalformedFile } from "./errors.js";

/** The highest degree version 1 defines. */
export const MAX_SH_DEGREE = 3;

/**
 * Coefficients per colour component in band `b`: 3, 5, 7 for bands 1, 2, 3.
 *
 * Degree `d` adds `2d + 1` coefficients, which is what makes a degree whole.
 */
export function coefficientsInBand(band: number): number {
  if (band < 1 || band > MAX_SH_DEGREE) {
    throw new MalformedFile(`SH band ${band} is outside the 1..${MAX_SH_DEGREE} range`);
  }
  return 2 * band + 1;
}

/** Coefficients per colour component for a whole degree: 0, 3, 8, 15. */
export function coefficientsForDegree(degree: number): number {
  if (degree < 0 || degree > MAX_SH_DEGREE) {
    throw new MalformedFile(`SH degree ${degree} is outside the 0..${MAX_SH_DEGREE} range`);
  }
  return (degree + 1) * (degree + 1) - 1;
}

/** The half-open coefficient range band `b` occupies within a component's coefficients. */
export function bandCoefficientRange(band: number): readonly [number, number] {
  const first = coefficientsForDegree(band - 1);
  return [first, first + coefficientsInBand(band)];
}

/**
 * Spherical harmonic coefficients for one chunk, component-major.
 *
 * `values[c * coefficients + k]` for gaussian `i` lives at
 * `i * 3 * coefficients + c * coefficients + k`, which is the layout the streams are
 * written in: all of red's coefficients, then green's, then blue's.
 */
export interface ShCoefficients {
  /** Highest whole degree present, after any cap the reader asked for. */
  readonly degree: number;
  /** Coefficients per colour component. */
  readonly coefficients: number;
  readonly count: number;
  readonly values: Uint8Array;
  /** Which bands were actually transferred and merged. */
  readonly bands: readonly number[];
}

/**
 * Merge decoded band streams into one component-major coefficient array.
 *
 * Each band stream is `3 × coefficientsInBand(band)` channels per gaussian, ordered
 * component-major within the band. Bands are placed at their own offset inside the whole
 * degree's coefficient block, so merging never has to know which bands came before it.
 */
export function mergeBands(
  count: number,
  bands: ReadonlyMap<number, Int32Array>,
  degreeCap: number,
): ShCoefficients {
  const present = [...bands.keys()].filter((b) => b <= degreeCap).sort((a, b) => a - b);
  if (present.length === 0) {
    return { degree: 0, coefficients: 0, count, values: new Uint8Array(0), bands: [] };
  }
  // Whole degrees only: bands must run 1..N with nothing missing, or the result would be
  // a scene that is neither degree N nor degree N-1.
  for (let i = 0; i < present.length; i++) {
    if (present[i] !== i + 1) {
      throw new MalformedFile(
        `SH bands ${present.join(", ")} do not form whole degrees starting at band 1`,
      );
    }
  }
  const degree = present.length;
  const coefficients = coefficientsForDegree(degree);
  const values = new Uint8Array(count * 3 * coefficients);
  for (const band of present) {
    const [first] = bandCoefficientRange(band);
    const width = coefficientsInBand(band);
    const stream = bands.get(band)!;
    if (stream.length !== count * 3 * width) {
      throw new MalformedFile(
        `SH band ${band} decoded ${stream.length} values, expected ${count * 3 * width}`,
      );
    }
    for (let i = 0; i < count; i++) {
      for (let c = 0; c < 3; c++) {
        const from = i * 3 * width + c * width;
        const to = i * 3 * coefficients + c * coefficients + first;
        for (let k = 0; k < width; k++) {
          const value = stream[from + k]!;
          if (value < 0 || value > 255) {
            throw new MalformedFile(
              `SH band ${band} coefficient ${value} is outside the 0..255 range this version stores`,
            );
          }
          values[to + k] = value;
        }
      }
    }
  }
  return { degree, coefficients, count, values, bands: present };
}
