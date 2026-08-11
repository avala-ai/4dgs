// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Encoding a `keyframe-delta` file (spec §11).
 *
 * The caller supplies a **sequence of samples**: a population, with identities, stated at a
 * sequence of times. This encoder picks keyframes by cadence, derives one set of grids from
 * bounded passes over the samples, and writes each non-keyframe sample as the *difference of
 * bins* against the chunk it references.
 *
 * Quantizing every sample on grids derived from the whole sequence is the part that makes
 * the model's error claim true. A delta is then an integer subtraction between two bins on
 * the same grid, the composition telescopes, and the reconstructed bin at any depth is
 * exactly the bin an absolute statement of that instant would have carried. Samples are
 * quantized one at a time: only the current population and its reference are retained. An
 * encoder that instead quantized `x_j - x_{j-1}` would produce a file whose declared bounds
 * mean nothing after the second delta.
 *
 * What this encoder does not do is decide *what* to update. Which gaussians moved enough to
 * be worth a byte, and how often to spend a keyframe, is rate control — encoder policy, and
 * the place encoders differentiate (AGENTS.md §4). This one updates a gaussian when any of
 * its bins changed, which is the simplest rule that is also correct.
 *
 * The arithmetic is shared with {@link encodeScene} rather than restated, so the two
 * TypeScript encoders cannot drift into two opinions about the same grid.
 */

import { crc32 } from "./codec.js";
import { Attribute, Opcode, REQUIRED_ATTRIBUTES } from "./opcodes.js";
import { lifeClass, motionStep, muStep, supportK, type Steps } from "./quantization.js";
import { DELTA_MODE_CHAINED, DELTA_MODE_KEYFRAME, MAGIC } from "./records.js";
import {
  ByteWriter,
  encodeStream,
  putStrMap,
  quantizeRotation,
  rctForward,
  record,
  rint,
  type GaussianInput,
} from "./writer.js";

/**
 * One population, at one instant, with identity.
 *
 * `ids` is aligned with the gaussians and is what a delta names them by. It is required
 * rather than derived: the whole model rests on correspondence between samples, and a
 * correspondence the encoder invented from row order is one the caller never asserted.
 */
export interface KeyframeDeltaSample {
  readonly t0: number;
  readonly ids: ArrayLike<number>;
  readonly gaussians: GaussianInput;
}

/** Cadence, mode, and the handful of file-level values a sequence still needs. */
export interface KeyframeDeltaWriteOptions {
  /**
   * Samples per group of pictures. 1 writes every sample as a keyframe, which is legal and
   * is the shape the registry's `frame-sequence` reservation describes.
   */
  keyframeEvery?: number;
  /**
   * {@link DELTA_MODE_CHAINED} references the previous chunk; {@link DELTA_MODE_KEYFRAME}
   * references the group's keyframe. Chained is the default because it is smaller and its
   * chain is contiguous in the file, so a range reader coalesces it into one request.
   */
  deltaMode?: number;
  /**
   * Sample indices to force a keyframe at, beyond the cadence. A producer that knows where
   * a cut is puts one here so that instant costs two records however deep into a group it
   * would otherwise have fallen.
   */
  keyframeAt?: readonly number[];
  cutoff?: number;
  /** `"fine"`, `"default"` or `"coarse"` — the error bounds every grid is derived from. */
  profile?: string;
  library?: string;
  writeIndex?: boolean;
  writeStatistics?: boolean;
  writeCrc?: boolean;
}

/** One attribute's bins for a population: `channels` per gaussian, packed row-major. */
interface Column {
  readonly channels: number;
  readonly values: number[];
}

type Bins = Map<number, Column>;

/**
 * Attributes an update MUST NOT carry: the per-gaussian grids for velocity and birth time
 * are derived from these three, so a bin difference across a change in any of them
 * subtracts bins that live on different grids (spec §11.5).
 */
const GOP_INVARIANT: readonly number[] = [Attribute.SigmaT, Attribute.Flags, Attribute.WindowIndex];

/**
 * Attributes an update restates outright rather than differencing. The smallest-three basis
 * changes whenever the largest quaternion component does, so the three stored bins mean
 * different components either side of it and a difference would be nonsense.
 */
const ABSOLUTE_IN_UPDATE: readonly number[] = [Attribute.RotationIndex, Attribute.Rotation];

const PROFILES = ["fine", "default", "coarse"] as const;
const U32_MAX = 0xffff_ffff;
const I32_MIN = -0x8000_0000;
const I32_MAX = 0x7fff_ffff;
const U32_MODULUS = 0x1_0000_0000;
const U16_MAX = 0xffff;

/** The maximum deviation a decoder may observe, per attribute (spec §6.2). */
interface Bounds {
  readonly pos: number;
  readonly scale_rel: number;
  readonly rot: number;
  readonly rgb: number;
  readonly alpha: number;
  readonly motion: number;
  readonly time: number;
  readonly sigma_rel: number;
  readonly sh: number;
}

/** The reference lifetime a velocity precision class is measured against, in seconds. */
const LIFE_REF = 0.5;

function boundsForProfile(profile: string, medianScale: number): Bounds {
  const at = PROFILES.indexOf(profile as (typeof PROFILES)[number]);
  if (at < 0) {
    throw new Error(`profile must be one of ${PROFILES.join(", ")}, got "${profile}"`);
  }
  const pos = [0.02, 0.05, 0.2][at]! * medianScale;
  return {
    pos,
    scale_rel: [0.005, 0.02, 0.06][at]!,
    rot: [0.0005, 0.002, 0.006][at]!,
    rgb: [0.5, 1.0, 3.0][at]! / 255.0,
    alpha: [0.5, 1.0, 3.0][at]! / 255.0,
    // The promise is on displacement, not velocity: this is the velocity bound for a
    // gaussian of the reference lifetime (spec §6.3).
    motion: pos / LIFE_REF,
    time: [0.0005, 0.002, 0.008][at]!,
    sigma_rel: [0.005, 0.02, 0.06][at]!,
    sh: [0, 0, 1][at]!,
  };
}

/** Grid pitches: exactly twice the bound, in the appropriate domain. */
function stepsOf(b: Bounds): Steps {
  return {
    pos: 2.0 * b.pos,
    scaleLog: 2.0 * Math.log1p(b.scale_rel),
    rot: 2.0 * b.rot,
    rgb: 2.0 * b.rgb,
    alpha: 2.0 * b.alpha,
    motion: 2.0 * b.motion,
    time: 2.0 * b.time,
    sigmaLog: 2.0 * Math.log1p(b.sigma_rel),
    sh: Math.max(1, 2 * b.sh + 1),
  };
}

/**
 * The one set of grids the whole sequence is quantized on.
 *
 * Position origin and the scalar steps come from the sequence as a whole, so a gaussian's
 * bin for an attribute is the same wherever it appears and a delta of bins is meaningful.
 * The velocity and birth-time steps are per-gaussian and derived from `sigma_t`, `flags`
 * and the validity window (spec §6.3) — all three GOP-invariant (spec §11.5), so a gaussian
 * keeps its grid for its whole life and its motion delta telescopes.
 */
interface Grids {
  readonly steps: Steps;
  readonly bounds: Bounds;
  readonly origin: [number, number, number];
  /**
   * Every validity window the sequence declares, in Window Table order. A gaussian's own
   * window is the one its `window_index` names — the velocity grid is derived from that
   * window's length (spec §6.3), so collapsing the table to its first entry gives every
   * gaussian outside window 0 the wrong motion precision and its positions drift from the
   * bins this encoder wrote.
   */
  readonly windows: [number, number][];
  readonly cutoff: number;
}

/**
 * The distinct validity windows the population declares, in first-seen order.
 *
 * Order is first-seen rather than sorted: `window_index` is written against this list, so a
 * stable order is what makes the indices mean the same thing on both sides.
 */
function windowsOf(
  samples: readonly KeyframeDeltaSample[],
  durationSec: number,
): [number, number][] {
  const seen = new Set<string>();
  const out: [number, number][] = [];
  for (let sampleAt = 0; sampleAt < samples.length; sampleAt++) {
    const sample = samples[sampleAt]!;
    const g = sample.gaussians;
    for (let i = 0; i < g.count; i++) {
      const lo = g.winLo[i]!;
      const hi = g.winHi[i]!;
      if (Number.isNaN(lo) || Number.isNaN(hi)) {
        throw new Error(
          `sample ${sampleAt}, gaussian ${i} has validity window [${lo}, ${hi}); ` +
            `window endpoints must not be NaN`,
        );
      }
      const key = `${lo},${hi}`;
      if (!seen.has(key)) {
        seen.add(key);
        out.push([lo, hi]);
      }
    }
  }
  return out.length > 0 ? out : [[0, durationSec]];
}

/**
 * Exact median scale with constant auxiliary memory.
 *
 * Positive finite IEEE-754 bit patterns have the same unsigned order as their numeric
 * values. Selecting one bit at a time therefore finds the kth value in 64 bounded passes,
 * without retaining one scale lane for every gaussian in every sample.
 */
function medianScaleOf(samples: readonly KeyframeDeltaSample[]): number {
  let count = 0;
  for (let sampleAt = 0; sampleAt < samples.length; sampleAt++) {
    const g = samples[sampleAt]!.gaussians;
    for (let i = 0; i < g.count * 3; i++) {
      const value = g.scales[i]!;
      if (!Number.isFinite(value) || value <= 0) {
        throw new Error(
          `sample ${sampleAt}, scale lane ${i} is ${value}; scales must be finite and positive`,
        );
      }
      count++;
    }
  }
  if (count === 0) return 1e-3;

  const kth = (rank: number): number => {
    let prefix = 0n;
    let mask = 0n;
    const storage = new ArrayBuffer(8);
    const view = new DataView(storage);
    for (let shift = 63; shift >= 0; shift--) {
      const bit = 1n << BigInt(shift);
      let zeroes = 0;
      for (const sample of samples) {
        const g = sample.gaussians;
        for (let i = 0; i < g.count * 3; i++) {
          view.setFloat64(0, g.scales[i]!, false);
          const bits = view.getBigUint64(0, false);
          if ((bits & mask) === prefix && (bits & bit) === 0n) zeroes++;
        }
      }
      mask |= bit;
      if (rank >= zeroes) {
        rank -= zeroes;
        prefix |= bit;
      }
    }
    view.setBigUint64(0, prefix, false);
    return view.getFloat64(0, false);
  };

  const high = kth(count >> 1);
  return count % 2 === 1 ? high : 0.5 * kth((count >> 1) - 1) + 0.5 * high;
}

function hasId(ids: ArrayLike<number>, wanted: number): boolean {
  for (let i = 0; i < ids.length; i++) if (ids[i] === wanted) return true;
  return false;
}

/** Validate identity and derive lifetime history in bounded passes over caller-owned samples. */
function validateSequenceIds(samples: readonly KeyframeDeltaSample[]): number {
  let distinct = 0;

  for (let at = 0; at < samples.length; at++) {
    const sample = samples[at]!;
    if (sample.ids.length !== sample.gaussians.count) {
      throw new Error(
        `sample ${at} carries ${sample.gaussians.count} gaussians but ${sample.ids.length} ids`,
      );
    }
    const current = new Set<number>();
    for (let i = 0; i < sample.ids.length; i++) {
      const id = sample.ids[i]!;
      if (!Number.isInteger(id) || id < 0 || id > U32_MAX) {
        throw new Error(
          `sample ${at} carries gaussian id ${id}; gaussian_id is an unsigned 32-bit value`,
        );
      }
      if (current.has(id)) {
        throw new Error(
          `sample ${at} names gaussian id ${id} twice; ids are unique within a state`,
        );
      }
      const livedPreviously = at > 0 && hasId(samples[at - 1]!.ids, id);
      if (!livedPreviously) {
        let seenEarlier = false;
        for (let earlier = 0; earlier < at - 1 && !seenEarlier; earlier++) {
          seenEarlier = hasId(samples[earlier]!.ids, id);
        }
        if (seenEarlier) {
          throw new Error(
            `sample ${at} reuses gaussian id ${id} after it died; gaussian_id is never reused ` +
              `within a sequence`,
          );
        }
        distinct++;
      }
      current.add(id);
    }
  }
  return distinct;
}

function gridsFor(
  samples: readonly KeyframeDeltaSample[],
  durationSec: number,
  profile: string,
  cutoff: number,
): Grids {
  const origin: [number, number, number] = [Infinity, Infinity, Infinity];
  let any = false;
  for (const sample of samples) {
    const g = sample.gaussians;
    for (let i = 0; i < g.count; i++) {
      any = true;
      for (let a = 0; a < 3; a++) {
        origin[a] = Math.min(origin[a]!, g.positions[i * 3 + a]!);
      }
    }
  }
  if (!any) {
    origin[0] = origin[1] = origin[2] = 0;
  }
  const bounds = boundsForProfile(profile, medianScaleOf(samples));
  return {
    steps: stepsOf(bounds),
    bounds,
    origin,
    windows: windowsOf(samples, durationSec),
    cutoff,
  };
}

/** One sample as identities and a bin per attribute, on the shared grids. */
function quantizeSample(
  sample: KeyframeDeltaSample,
  grids: Grids,
  at: number,
): { ids: number[]; bins: Bins } {
  const g = sample.gaussians;
  const n = g.count;
  if (sample.ids.length !== n) {
    throw new Error(`sample ${at} carries ${n} gaussians but ${sample.ids.length} ids`);
  }
  if (g.sh != null && g.sh.length > 0) {
    throw new Error(
      `sample ${at} carries spherical harmonics, which a keyframe-delta file has no place to ` +
        `put: SH Band Stream records hang off a gaussian-birth Chunk and are not composed by ` +
        `a delta (spec §11). Drop them, or write this scene as gaussian-birth.`,
    );
  }
  const ids: number[] = [];
  const seen = new Set<number>();
  for (let i = 0; i < n; i++) {
    const id = sample.ids[i]!;
    if (!Number.isInteger(id) || id < 0 || id > U32_MAX) {
      throw new Error(
        `sample ${at} carries gaussian id ${id}; gaussian_id is an unsigned 32-bit value`,
      );
    }
    if (seen.has(id)) {
      throw new Error(`sample ${at} names gaussian id ${id} twice; ids are unique within a state`);
    }
    seen.add(id);
    ids.push(id);
  }

  const k = supportK(grids.cutoff);
  const steps = grids.steps;
  const position: number[] = [];
  const scale: number[] = [];
  const rotationIndex: number[] = [];
  const rotation: number[] = [];
  const color: number[] = [];
  const opacity: number[] = [];
  const motion: number[] = [];
  const mu: number[] = [];
  const sigma: number[] = [];
  const flags: number[] = [];
  const windowIndex: number[] = [];

  for (let i = 0; i < n; i++) {
    const sigmaValue = g.sigmaT[i]!;
    if (!Number.isFinite(sigmaValue) || sigmaValue <= 0) {
      throw new Error(
        `sample ${at}, gaussian ${i}: sigma_t is ${sigmaValue}; this writer requires a finite ` +
          `positive temporal width`,
      );
    }
    const sigmaBin = rint(Math.log(sigmaValue) / steps.sigmaLog);
    sigma.push(sigmaBin);
    flags.push(0);
    const row = windowRow(grids.windows, g.winLo[i]!, g.winHi[i]!);
    windowIndex.push(row);

    for (let a = 0; a < 3; a++) {
      position.push(rint((g.positions[i * 3 + a]! - grids.origin[a]!) / steps.pos));
      scale.push(rint(Math.log(Math.max(g.scales[i * 3 + a]!, 1e-30)) / steps.scaleLog));
    }

    const [largest, bins] = quantizeRotation(
      g.rotations[i * 4]!,
      g.rotations[i * 4 + 1]!,
      g.rotations[i * 4 + 2]!,
      g.rotations[i * 4 + 3]!,
      steps.rot,
    );
    rotationIndex.push(largest);
    rotation.push(bins[0], bins[1], bins[2]);

    const rgb = rctForward(
      rint(g.colors[i * 4]! / steps.rgb),
      rint(g.colors[i * 4 + 1]! / steps.rgb),
      rint(g.colors[i * 4 + 2]! / steps.rgb),
    );
    color.push(rgb[0], rgb[1], rgb[2]);
    opacity.push(rint(g.colors[i * 4 + 3]! / steps.alpha));

    // The row's own window, matching the index written beside it: quantizing against
    // window 0 while recording a different index scales the velocity by one grid and
    // reconstructs it with another.
    const window = grids.windows[row]!;
    const mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, false, window[1] - window[0], k),
      steps.motion,
    );
    for (let a = 0; a < 3; a++) motion.push(rint(g.motions[i * 3 + a]! / mStep));
    // A state is stated at the sample timestamp (§11.3). Anchoring mu_t anywhere else
    // moves a nonzero-velocity gaussian away from the position the caller supplied at t0.
    mu.push(rint(sample.t0 / muStep(sigmaBin, steps.sigmaLog, false, steps.time)));
  }

  const bins: Bins = new Map();
  bins.set(Attribute.Position, { channels: 3, values: position });
  bins.set(Attribute.Scale, { channels: 3, values: scale });
  bins.set(Attribute.RotationIndex, { channels: 1, values: rotationIndex });
  bins.set(Attribute.Rotation, { channels: 3, values: rotation });
  bins.set(Attribute.Color, { channels: 3, values: color });
  bins.set(Attribute.Opacity, { channels: 1, values: opacity });
  bins.set(Attribute.Motion, { channels: 3, values: motion });
  bins.set(Attribute.MuT, { channels: 1, values: mu });
  bins.set(Attribute.SigmaT, { channels: 1, values: sigma });
  bins.set(Attribute.Flags, { channels: 1, values: flags });
  bins.set(Attribute.WindowIndex, { channels: 1, values: windowIndex });
  for (const [attribute, column] of bins) {
    for (let i = 0; i < column.values.length; i++) {
      const value = column.values[i]!;
      if (!Number.isInteger(value) || value < I32_MIN || value > I32_MAX) {
        const row = Math.floor(i / column.channels);
        throw new Error(
          `sample ${at}, gaussian id ${ids[row]}: attribute ${attribute} bin ${value} is outside ` +
            `the signed 32-bit range composed bins must stay inside`,
        );
      }
    }
  }
  return { ids, bins };
}

function windowRow(windows: readonly [number, number][], lo: number, hi: number): number {
  for (let i = 0; i < windows.length; i++) {
    if (windows[i]![0] === lo && windows[i]![1] === hi) return i;
  }
  return 0;
}

// --------------------------------------------------------------------------
// Splitting one sample against its reference
// --------------------------------------------------------------------------

interface DeltaGroups {
  readonly updateIds: number[];
  readonly updateBins: Bins;
  readonly birthIds: number[];
  readonly birthBins: Bins;
  readonly deathIds: number[];
}

function gather(bins: Bins, rows: readonly number[]): Bins {
  const out: Bins = new Map();
  for (const [attribute, column] of bins) {
    const ch = column.channels;
    const values: number[] = [];
    for (const r of rows) for (let c = 0; c < ch; c++) values.push(column.values[r * ch + c]!);
    out.set(attribute, { channels: ch, values });
  }
  return out;
}

function rowsDiffer(a: Column, rowA: number, b: Column, rowB: number): boolean {
  const ch = a.channels;
  for (let c = 0; c < ch; c++) {
    if (a.values[rowA * ch + c] !== b.values[rowB * ch + c]) return true;
  }
  return false;
}

function checkGopInvariants(
  referenceIds: readonly number[],
  referenceBins: Bins,
  ids: readonly number[],
  bins: Bins,
  at: number,
): void {
  const referenceRow = new Map<number, number>();
  for (let i = 0; i < referenceIds.length; i++) referenceRow.set(referenceIds[i]!, i);
  for (let row = 0; row < ids.length; row++) {
    const beforeRow = referenceRow.get(ids[row]!);
    if (beforeRow === undefined) continue;
    for (const attribute of GOP_INVARIANT) {
      const before = referenceBins.get(attribute);
      const after = bins.get(attribute);
      if (before === undefined || after === undefined) continue;
      if (rowsDiffer(before, beforeRow, after, row)) {
        throw new Error(
          `sample ${at}: gaussian id ${ids[row]} changes attribute ${attribute} between ` +
            `samples, which is fixed for a gaussian's lifetime within a group: the per-gaussian ` +
            `grids for velocity and birth time are derived from it. Emit a keyframe, or a death ` +
            `and a birth.`,
        );
      }
    }
  }
}

/**
 * Split one sample against its reference into updates, births and deaths.
 *
 * A gaussian is updated when any of its bins moved. Untouched means no bytes, which is the
 * property the whole model exists to buy.
 */
function deltaGroups(
  referenceIds: readonly number[],
  referenceBins: Bins,
  ids: readonly number[],
  bins: Bins,
  at: number,
): DeltaGroups {
  checkGopInvariants(referenceIds, referenceBins, ids, bins, at);
  const referenceRow = new Map<number, number>();
  for (let i = 0; i < referenceIds.length; i++) referenceRow.set(referenceIds[i]!, i);
  const live = new Set<number>(ids);

  // Sorted, matching the Python reference's `np.setdiff1d`. Nothing in the format depends
  // on the order within a group, but naming it keeps two encoders comparable byte for byte.
  const deathIds = referenceIds.filter((id) => !live.has(id)).sort((a, b) => a - b);

  const birthRows: number[] = [];
  const commonRows: number[] = [];
  for (let i = 0; i < ids.length; i++) {
    (referenceRow.has(ids[i]!) ? commonRows : birthRows).push(i);
  }
  const birthIds = birthRows.map((i) => ids[i]!);
  const birthBins = gather(bins, birthRows);
  const commonIds = commonRows.map((i) => ids[i]!);
  const referenceRows = commonIds.map((id) => referenceRow.get(id)!);

  const changed = new Array<boolean>(commonRows.length).fill(false);
  for (const [attribute, after] of bins) {
    // mu_t is part of the stated temporal state. Keeping an earlier anchor changes both a
    // moving gaussian's centre and its temporal marginal at this sample's instant.
    if (GOP_INVARIANT.includes(attribute)) continue;
    const before = referenceBins.get(attribute);
    if (before === undefined) continue;
    for (let k = 0; k < commonRows.length; k++) {
      if (rowsDiffer(before, referenceRows[k]!, after, commonRows[k]!)) changed[k] = true;
    }
  }

  const touched: number[] = [];
  for (let k = 0; k < commonRows.length; k++) if (changed[k]) touched.push(k);
  const updateIds = touched.map((k) => commonIds[k]!);
  const updateBins: Bins = new Map();
  for (const [attribute, after] of bins) {
    if (GOP_INVARIANT.includes(attribute)) continue;
    const before = referenceBins.get(attribute);
    if (before === undefined) continue;
    const ch = after.channels;
    const absolute = ABSOLUTE_IN_UPDATE.includes(attribute);
    const values: number[] = [];
    for (const k of touched) {
      const row = commonRows[k]! * ch;
      const referenceOffset = referenceRows[k]! * ch;
      for (let c = 0; c < ch; c++) {
        values.push(
          absolute
            ? after.values[row + c]!
            : after.values[row + c]! - before.values[referenceOffset + c]!,
        );
      }
    }
    updateBins.set(attribute, { channels: ch, values });
  }

  return { updateIds, updateBins, birthIds, birthBins, deathIds };
}

// --------------------------------------------------------------------------
// Streams
// --------------------------------------------------------------------------

async function concatStreams(parts: readonly Uint8Array[]): Promise<Uint8Array> {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** u32 identities travel through the signed stream codec with the same 32 bits. */
function gaussianIdCodes(ids: readonly number[]): number[] {
  return ids.map((id) => (id > I32_MAX ? id - U32_MODULUS : id));
}

/** One group's streams: the ids it names, then the attributes it carries, ascending. */
async function groupStreams(ids: readonly number[], bins: Bins): Promise<Uint8Array> {
  if (ids.length === 0) return new Uint8Array(0);
  const parts = [await encodeStream(Attribute.GaussianId, gaussianIdCodes(ids), 1)];
  for (const attribute of [...bins.keys()].sort((a, b) => a - b)) {
    const column = bins.get(attribute)!;
    parts.push(await encodeStream(attribute, column.values, column.channels));
  }
  return concatStreams(parts);
}

/** A keyframe chunk's streams: identity, then all eleven required attributes in order. */
async function keyframeStreams(ids: readonly number[], bins: Bins): Promise<Uint8Array> {
  const parts = [await encodeStream(Attribute.GaussianId, gaussianIdCodes(ids), 1)];
  for (const attribute of REQUIRED_ATTRIBUTES) {
    const column = bins.get(attribute)!;
    parts.push(await encodeStream(attribute, column.values, column.channels));
  }
  return concatStreams(parts);
}

function encodeChunk(t0: number, t1: number, count: number, streams: Uint8Array): Uint8Array {
  const body = new ByteWriter(streams.length + 64);
  body.f64(t0);
  body.f64(t1);
  body.u32(0); // level
  body.u32(count);
  body.string(""); // chunk-level compression: the streams carry their own
  body.u64(streams.length);
  body.blob(streams);
  return record(Opcode.Chunk, body.finish());
}

/**
 * A Delta Chunk record (spec §5.18).
 *
 * The three groups are framed by length inside one `records` blob rather than tagged with a
 * group byte on every stream, so a reader takes the death list — small, and often wanted
 * alone — by stepping over two lengths.
 */
function encodeDeltaChunk(
  t0: number,
  t1: number,
  deltaMode: number,
  referenceOffset: number,
  keyframeOffset: number,
  depth: number,
  updates: Uint8Array,
  births: Uint8Array,
  deaths: Uint8Array,
  counts: readonly [number, number, number],
): Uint8Array {
  const groups = new ByteWriter(updates.length + births.length + deaths.length + 32);
  groups.blob(updates);
  groups.blob(births);
  groups.blob(deaths);
  const records = groups.finish();

  const body = new ByteWriter(records.length + 96);
  body.f64(t0);
  body.f64(t1);
  body.u32(0); // level
  body.u8(deltaMode);
  body.u64(referenceOffset);
  body.u64(keyframeOffset);
  body.u16(depth);
  body.u32(counts[0]);
  body.u32(counts[1]);
  body.u32(counts[2]);
  body.string(""); // chunk-level compression: the streams carry their own
  body.u64(records.length);
  body.blob(records);
  return record(Opcode.DeltaChunk, body.finish());
}

/**
 * One extended Chunk Index entry (spec §5.8).
 *
 * `gaussianCount` counts what the record carries: the population for a keyframe, and the
 * number of **operations** — updates plus births plus deaths — for a delta. `liveCount` is
 * the population after composition, and it is stated for keyframe entries too: §5.8 defines
 * it for every extended entry and the readers cross-check it.
 */
interface IndexEntry {
  t0: number;
  t1: number;
  chunkOffset: number;
  chunkLength: number;
  gaussianCount: number;
  kind: number;
  deltaMode: number;
  referenceOffset: number;
  keyframeOffset: number;
  depth: number;
  liveCount: number;
}

function encodeIndexEntry(entry: IndexEntry): Uint8Array {
  const w = new ByteWriter(96);
  w.f64(entry.t0);
  w.f64(entry.t1);
  w.u64(entry.chunkOffset);
  w.u64(entry.chunkLength);
  w.u32(entry.gaussianCount);
  w.u32(0); // no SH band ranges: a keyframe-delta file carries no SH Band Stream records
  w.u8(entry.kind);
  w.u8(entry.deltaMode);
  w.u64(entry.referenceOffset);
  w.u64(entry.keyframeOffset);
  w.u16(entry.depth);
  w.u64(entry.liveCount);
  return record(Opcode.ChunkIndex, w.finish());
}

function isKeyframe(index: number, keyframeEvery: number, keyframeAt: readonly number[]): boolean {
  return (
    index === 0 || keyframeAt.includes(index) || (keyframeEvery > 0 && index % keyframeEvery === 0)
  );
}

function checkDepthPlan(
  count: number,
  keyframeEvery: number,
  keyframeAt: readonly number[],
  deltaMode: number,
): void {
  if (!Number.isInteger(keyframeEvery) || keyframeEvery < 0) {
    throw new Error(`keyframeEvery must be a non-negative integer, got ${keyframeEvery}`);
  }
  if (deltaMode !== DELTA_MODE_CHAINED) return;
  let depth = 0;
  for (let i = 0; i < count; i++) {
    depth = isKeyframe(i, keyframeEvery, keyframeAt) ? 0 : depth + 1;
    if (depth > U16_MAX) {
      throw new Error(
        `sample ${i} would have chained depth ${depth}, past the ${U16_MAX} maximum the ` +
          `Delta Chunk u16 depth field can store; add a keyframe or shorten the cadence`,
      );
    }
  }
}

function aabbOf(samples: readonly KeyframeDeltaSample[]): number[] {
  const lo = [Infinity, Infinity, Infinity];
  const hi = [-Infinity, -Infinity, -Infinity];
  let any = false;
  for (const sample of samples) {
    const g = sample.gaussians;
    for (let i = 0; i < g.count; i++) {
      any = true;
      for (let a = 0; a < 3; a++) {
        const v = g.positions[i * 3 + a]!;
        lo[a] = Math.min(lo[a]!, v);
        hi[a] = Math.max(hi[a]!, v);
      }
    }
  }
  return any ? [...lo, ...hi] : [0, 0, 0, 0, 0, 0];
}

// --------------------------------------------------------------------------
// The whole file
// --------------------------------------------------------------------------

/**
 * Assemble a whole `keyframe-delta` file from a sequence of samples.
 *
 * The samples must tile the timeline: sample `i` covers `[t_i, t_{i+1})`, the first starts
 * at 0 and the last ends at `durationSec`. That is the tiling rule (spec §11.1), and it is
 * the writer's job to satisfy it rather than the reader's to tolerate a file that does not
 * — so a sequence that cannot tile is refused here rather than written into a file both of
 * this package's read paths would then reject.
 *
 * Async because `deflate` is: the runtime's compressor is a stream.
 */
export async function encodeKeyframeDeltaSequence(
  samples: readonly KeyframeDeltaSample[],
  durationSec: number,
  options: KeyframeDeltaWriteOptions = {},
): Promise<Uint8Array> {
  const keyframeEvery = options.keyframeEvery ?? 8;
  const deltaMode = options.deltaMode ?? DELTA_MODE_CHAINED;
  const keyframeAt = options.keyframeAt ?? [];
  const cutoff = options.cutoff ?? 0.05;
  const profile = options.profile ?? "default";
  const library = options.library ?? "4dgs-typescript keyframe-delta encoder";
  const writeIndex = options.writeIndex ?? true;
  const writeStatistics = options.writeStatistics ?? true;
  const writeCrc = options.writeCrc ?? true;

  if (samples.length === 0) {
    throw new Error("a keyframe-delta file needs at least one sample");
  }
  if (!Number.isFinite(durationSec)) {
    throw new Error(`duration_sec must be finite, got ${durationSec}`);
  }
  if (deltaMode !== DELTA_MODE_CHAINED && deltaMode !== DELTA_MODE_KEYFRAME) {
    throw new Error(
      `delta_mode is ${deltaMode}; the format defines ${DELTA_MODE_KEYFRAME} (keyframe-referenced) ` +
        `and ${DELTA_MODE_CHAINED} (chained), and nothing else`,
    );
  }
  checkDepthPlan(samples.length, keyframeEvery, keyframeAt, deltaMode);
  const distinctCount = validateSequenceIds(samples);
  if (samples[0]!.t0 !== 0) {
    throw new Error(
      `the first sample starts at ${samples[0]!.t0}, not 0; a keyframe-delta timeline covers ` +
        `[0, duration_sec) with no gap (spec §11.1)`,
    );
  }
  for (let i = 0; i < samples.length; i++) {
    const t0 = samples[i]!.t0;
    const t1 = samples[i + 1]?.t0 ?? durationSec;
    if (!(t1 > t0)) {
      throw new Error(
        `sample ${i} covers [${t0}, ${t1}), which is empty or inverted; samples tile the ` +
          `timeline in order and the last one ends at duration_sec ${durationSec} (spec §11.1)`,
      );
    }
  }

  const grids = gridsFor(samples, durationSec, profile, cutoff);

  const out = new ByteWriter(8192);
  out.bytes(MAGIC);

  const aabb = aabbOf(samples);
  const header = new ByteWriter(256);
  header.string(profile);
  header.string(library);
  header.f64(durationSec);
  header.u64(distinctCount);
  header.f64(cutoff);
  header.string("keyframe-delta");
  for (const v of aabb) header.f64(v);
  header.u8(0); // sh_degree: this model carries no SH Band Stream records
  header.u8(0); // flags: no audio
  putStrMap(header, {});
  out.bytes(record(Opcode.Header, header.finish()));

  const quant = new ByteWriter(256);
  quant.string("uniform-v1");
  for (const v of grids.origin) quant.f64(v);
  quant.f64(grids.steps.pos);
  quant.f64(grids.steps.scaleLog);
  quant.f64(grids.steps.rot);
  quant.f64(grids.steps.rgb);
  quant.f64(grids.steps.alpha);
  quant.f64(grids.steps.motion);
  quant.f64(grids.steps.time);
  quant.f64(grids.steps.sigmaLog);
  quant.u8(grids.steps.sh);
  putStrMap(quant, declaredBounds(grids.bounds));
  out.bytes(record(Opcode.Quantization, quant.finish()));

  const wt = new ByteWriter(16 + grids.windows.length * 16);
  wt.u32(grids.windows.length);
  for (const [lo, hi] of grids.windows) {
    wt.f64(lo);
    wt.f64(hi);
  }
  out.bytes(record(Opcode.WindowTable, wt.finish()));

  const index: IndexEntry[] = [];
  let keyframeOffset = 0;
  let previousOffset = 0;
  let previousDepth = 0;
  let previous: { ids: number[]; bins: Bins } | null = null;
  let gopReference: { ids: number[]; bins: Bins } | null = null;

  for (let i = 0; i < samples.length; i++) {
    const current = quantizeSample(samples[i]!, grids, i);
    const { ids, bins } = current;
    const t0 = samples[i]!.t0;
    const t1 = samples[i + 1]?.t0 ?? durationSec;

    if (isKeyframe(i, keyframeEvery, keyframeAt)) {
      const blob = encodeChunk(t0, t1, ids.length, await keyframeStreams(ids, bins));
      const at = out.length;
      out.bytes(blob);
      keyframeOffset = at;
      previousOffset = at;
      previousDepth = 0;
      previous = current;
      gopReference = deltaMode === DELTA_MODE_KEYFRAME ? current : null;
      index.push({
        t0,
        t1,
        chunkOffset: at,
        chunkLength: blob.length,
        gaussianCount: ids.length,
        kind: 0,
        deltaMode: 0,
        referenceOffset: 0,
        keyframeOffset: at,
        depth: 0,
        liveCount: ids.length,
      });
      continue;
    }

    // A delta: reference the group's keyframe (mode 0) or the previous chunk (mode 1).
    const reference = deltaMode === DELTA_MODE_KEYFRAME ? gopReference : previous;
    if (reference === null) throw new Error(`sample ${i} has no preceding keyframe reference`);
    const referenceOffset = deltaMode === DELTA_MODE_KEYFRAME ? keyframeOffset : previousOffset;
    const depth = deltaMode === DELTA_MODE_KEYFRAME ? 1 : previousDepth + 1;
    if (depth > U16_MAX) {
      throw new Error(`sample ${i} has depth ${depth}, past the u16 maximum ${U16_MAX}`);
    }
    // In keyframe-reference mode a gaussian born after the GOP keyframe is absent
    // from the encoded reference. Its lifetime invariants still compare with the
    // preceding temporal sample, where it is live.
    if (previous !== null && previous !== reference) {
      checkGopInvariants(previous.ids, previous.bins, ids, bins, i);
    }
    const groups = deltaGroups(reference.ids, reference.bins, ids, bins, i);
    const blob = encodeDeltaChunk(
      t0,
      t1,
      deltaMode,
      referenceOffset,
      keyframeOffset,
      depth,
      await groupStreams(groups.updateIds, groups.updateBins),
      await groupStreams(groups.birthIds, groups.birthBins),
      await groupStreams(groups.deathIds, new Map()),
      [groups.updateIds.length, groups.birthIds.length, groups.deathIds.length],
    );
    const at = out.length;
    out.bytes(blob);
    previousOffset = at;
    previousDepth = depth;
    previous = current;
    index.push({
      t0,
      t1,
      chunkOffset: at,
      chunkLength: blob.length,
      // Operations, not population: what this record carries. `liveCount` below is the
      // population it composes to.
      gaussianCount: groups.updateIds.length + groups.birthIds.length + groups.deathIds.length,
      kind: 1,
      deltaMode,
      referenceOffset,
      keyframeOffset,
      depth,
      liveCount: ids.length,
    });
  }

  let summaryStart = 0;
  let summaryLength = 0;
  if (writeIndex) {
    summaryStart = out.length;
    for (const entry of index) out.bytes(encodeIndexEntry(entry));
    if (writeStatistics) {
      const s = new ByteWriter(96);
      s.u64(distinctCount);
      s.u32(index.length);
      s.f64(durationSec);
      for (const v of aabb) s.f64(v);
      out.bytes(record(Opcode.Statistics, s.finish()));
    }
    summaryLength = out.length - summaryStart;
  }

  const footer = new ByteWriter(32);
  footer.u64(summaryStart);
  footer.u64(0); // summary_offset_start: no Summary Offset record
  footer.u32(writeCrc && summaryLength > 0 ? crc32(out.finish().subarray(summaryStart)) : 0);
  out.bytes(record(Opcode.Footer, footer.finish()));
  out.bytes(MAGIC);
  return out.finish().slice();
}

/**
 * The bounds the Quantization record declares about this file.
 *
 * Written because the Python reference writes them and a consumer's tolerance should be the
 * encoder's own promise rather than a number it chose. The Rust reference leaves the map
 * empty on this path, which is the one place the two writers disagree about the bytes.
 */
function declaredBounds(b: Bounds): Record<string, string> {
  return {
    pos: String(b.pos),
    scale_rel: String(b.scale_rel),
    rot: String(b.rot),
    rgb: String(b.rgb),
    alpha: String(b.alpha),
    motion: String(b.motion),
    time: String(b.time),
    sigma_rel: String(b.sigma_rel),
    sh: String(b.sh),
  };
}
