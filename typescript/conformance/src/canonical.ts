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
 * - `audioSources` is empty when absent and contains every independent source;
 * - keys are sorted.
 *
 * Nothing here may depend on decoded order. Gaussians may be reordered freely by an
 * encoder and readers must not rely on their order, so a summary that did would be asking
 * two correct decoders to disagree. Everything per-gaussian is taken in the content order
 * defined by `stableOrder`, which is derived from decoded values alone.
 *
 * Rounding is round-half-to-even on the value's exact decimal expansion, which is what
 * Python's `round` does. `toFixed` rounds halves away from zero, so it cannot be used on
 * its own: the two disagree on values like `0.0078125`, and every value a decoder
 * produces is a float32, whose exact ties are precisely those numbers.
 */

import {
  type AudioPayloadChunk,
  Crc32,
  audioSourceStateAt,
  crc32,
  ObjectLayer as ObjectLayerClass,
  poseApply,
  poseAt,
  quaternionMultiply,
  type Attachment,
  type AudioSource,
  type AudioSourceDescriptor,
  type Camera,
  type GaussianSet,
  type Header,
  type ObjectLayer,
  type Metadata,
  type Pose,
  type Provenance,
  type Statistics,
  type SummaryOffset,
} from "@4dgs/core";

export const FLOAT_DECIMALS = 6;

/** Decimal places that expand a near-tie exactly. See {@link roundHalfEven}. */
const EXACT_DECIMALS = 100;

/** How many gaussians appear in full. The aggregates cover the rest. */
export const SAMPLE = 16;

/** How many camera keyframes appear in full, so a long trajectory cannot bloat a summary. */
export const CAMERA_KEYFRAMES = 4;
export const AUDIO_KEYFRAMES = 4;

/** How many rig trajectory samples appear in full. */
export const RIG_SAMPLES = 4;

/** A descriptor plus the digest computed while its payload streamed past. */
export interface DigestedAudioSource extends AudioSourceDescriptor {
  readonly payloadCrc: string;
}

type CanonicalAudioSource = AudioSource | DigestedAudioSource;

/** Retain only one CRC state per source while streamed payload pieces are consumed. */
export class AudioPayloadDigests {
  private readonly states = new Map<
    number,
    { crc: Crc32; offset: number; dataLength: number; complete: boolean }
  >();

  readonly consume = (chunk: AudioPayloadChunk): void => {
    let state = this.states.get(chunk.sourceId);
    if (state === undefined) {
      if (chunk.offset !== 0) {
        throw new Error(`audio source ${chunk.sourceId} starts at payload offset ${chunk.offset}`);
      }
      state = {
        crc: new Crc32(),
        offset: 0,
        dataLength: chunk.dataLength,
        complete: false,
      };
      this.states.set(chunk.sourceId, state);
    }
    if (state.complete) throw new Error(`audio source ${chunk.sourceId} continued after its end`);
    if (state.dataLength !== chunk.dataLength || state.offset !== chunk.offset) {
      throw new Error(`audio source ${chunk.sourceId} payload pieces are not contiguous`);
    }
    state.crc.update(chunk.bytes);
    state.offset += chunk.bytes.byteLength;
    state.complete = chunk.final;
  };

  sources(descriptors: readonly AudioSourceDescriptor[]): DigestedAudioSource[] {
    return descriptors.map((descriptor) => {
      const state = this.states.get(descriptor.sourceId);
      if (
        state === undefined ||
        !state.complete ||
        state.offset !== descriptor.dataLength ||
        state.dataLength !== descriptor.dataLength
      ) {
        throw new Error(`audio source ${descriptor.sourceId} has no complete streamed payload`);
      }
      return { ...descriptor, payloadCrc: String(state.crc.digest()) };
    });
  }
}

/** CRC-32 of a payload, as a string: a summary proving it read bytes, not just lengths. */
export function crc(data: Uint8Array): string {
  return String(crc32(data));
}

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
  readonly header: Pick<
    Header,
    | "durationSec"
    | "cutoff"
    | "profile"
    | "library"
    | "shDegree"
    | "temporalModel"
    | "hasAudio"
    | "attributes"
  >;
  readonly gaussians: GaussianSet;
  readonly audioSources: readonly CanonicalAudioSource[];
  readonly chunkIntervals: readonly (readonly [number, number])[];
  readonly camera?: Camera | null;
  readonly metadata?: readonly Metadata[];
  readonly attachments?: readonly Attachment[];
  readonly statistics?: Statistics | null;
  readonly summaryOffsets?: readonly SummaryOffset[];
  readonly summaryCrcOk?: boolean | null;
  /**
   * Provenance records. Omitted from the summary entirely when empty or absent — see
   * the note in {@link summarize}.
   */
  readonly provenance?: Provenance | null;
  /**
   * Object-layer records. Like provenance, absent from the summary entirely when the
   * file carries neither them nor per-gaussian membership.
   */
  readonly objects?: ObjectLayer | null;
}

/** The statement every implementation must agree on for a variant. */
export function summarize(input: SceneSummaryInput): unknown {
  const { header, gaussians, audioSources, chunkIntervals } = input;
  const n = gaussians.count;
  const order = stableOrder(gaussians);
  const sample = order.slice(0, SAMPLE);

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
  for (const i of order) {
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
    cutoff: num(header.cutoff),
    // The Header's first two fields: readable everywhere, asserted nowhere until now.
    profile: header.profile,
    library: header.library,
    shDegree: header.shDegree,
    temporalModel: header.temporalModel,
    hasAudio: header.hasAudio,
    audioSources: [...audioSources]
      .sort((a, b) => a.sourceId - b.sourceId)
      .map((source) => summarizeAudioSource(source, header.durationSec / 2)),
    chunkIntervals: chunkIntervals.map(([a, b]) => [num(a), num(b)]),
    headerAttributes: sortedMap(header.attributes),
    metadataRecords: (input.metadata ?? []).map((m) => ({
      name: m.name,
      entries: sortedMap(m.entries),
    })),
    attachments: (input.attachments ?? []).map((a) => ({
      name: a.name,
      mediaType: a.mediaType,
      byteLength: String(a.data.byteLength),
      crc: crc(a.data),
    })),
    camera: input.camera == null ? null : summarizeCamera(input.camera),
    statistics:
      input.statistics == null
        ? null
        : {
            gaussianCount: String(input.statistics.gaussianCount),
            chunkCount: String(input.statistics.chunkCount),
            durationSec: num(input.statistics.durationSec),
            aabb: input.statistics.aabb.map((v) => num(v)),
          },
    summaryOffsets: (input.summaryOffsets ?? []).map((s) => ({
      groupOpcode: String(s.groupOpcode),
      groupStart: String(s.groupStart),
      groupLength: String(s.groupLength),
    })),
    summaryCrcOk: input.summaryCrcOk ?? null,
    // Omitted entirely when the file carries no provenance, which is deliberate and
    // is NOT the `audioSources` convention above. A file without provenance is
    // byte-identical to what it was before the family existed; emitting
    // `"provenance": null` would change every pre-existing expectation.
    ...(input.provenance != null && !input.provenance.isEmpty
      ? { provenance: summarizeProvenance(input.provenance) }
      : {}),
    // Same omission rule, and for the same reason: an object record is additive to the
    // gaussian-birth model, so a file without one must summarize exactly as it did
    // before the layer existed. Membership alone is enough to report — a scene can
    // carry ids and no table.
    ...((input.objects != null && !input.objects.isEmpty) || gaussians.objectId !== null
      ? objectsAndStates(header, gaussians, input.objects ?? null, order)
      : {}),
    sh: summarizeSh(gaussians, order),
    sample: {
      positions: rows(gaussians.positions, 3),
      scales: rows(gaussians.scales, 3),
      rotations: rows(gaussians.rotations, 4),
      colors: rows(gaussians.colors, 4),
      motions: rows(gaussians.motions, 3),
      muT: sample.map((i) => num(gaussians.muT[i])),
      sigmaT: sample.map((i) => num(gaussians.sigmaT[i])),
      winLo: sample.map((i) => num(gaussians.winLo[i])),
      winHi: sample.map((i) => num(gaussians.winHi[i])),
      ...(gaussians.objectId === null
        ? {}
        : { objectIds: sample.map((i) => String(gaussians.objectId![i])) }),
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
 * Every readable provenance field, plus the arithmetic the fields imply.
 *
 * The fields alone would not be enough: two implementations can agree on every stored
 * quaternion and still disagree about the pose halfway between two of them, because
 * slerp has a sign convention and clamping has an edge. So the summary carries the
 * interpolated poses as well as the samples.
 */
function summarizeProvenance(prov: Provenance): unknown {
  const trajectories = prov.trajectories.map((t) => {
    const probes = probeTimes(t);
    return {
      name: t.name,
      interpolation: t.interpolation,
      sampleCount: String(t.times.length),
      samples: t.times.slice(0, RIG_SAMPLES).map((time, i) => ({
        time: num(time),
        rotation: t.rotations[i]!.map((v) => num(v)),
        translation: t.translations[i]!.map((v) => num(v)),
      })),
      posesAt: probes.map((probe) => poseRow(probe, poseAt(t, probe))),
    };
  });

  return {
    frames: prov.frames.map((f) => ({
      name: f.name,
      handedness: f.handedness,
      upAxis: f.upAxis,
      forwardAxis: f.forwardAxis,
      lengthUnit: f.lengthUnit,
      metresPerUnit: num(f.metresPerUnit),
      // The resolution rule, per frame: a consumer handed a file whose two unit fields
      // disagree still has to produce one number, and this is it.
      metresPerUnitResolved: num(prov.metresPerUnit(f.name)),
    })),
    anchors: prov.anchors.map((a) => ({
      frameName: a.frameName,
      latitudeDeg: num(a.latitudeDeg),
      longitudeDeg: num(a.longitudeDeg),
      altitudeM: num(a.altitudeM),
      headingDeg: num(a.headingDeg),
    })),
    sensors: prov.sensors.map((s) => ({
      name: s.name,
      modality: s.modality,
      cameraModel: s.cameraModel,
      widthPx: String(s.widthPx),
      heightPx: String(s.heightPx),
      fx: num(s.fx),
      fy: num(s.fy),
      cx: num(s.cx),
      cy: num(s.cy),
      distortion: s.distortion.map((v) => num(v)),
      rotation: s.rotation.map((v) => num(v)),
      translation: s.translation.map((v) => num(v)),
      poseReference: s.poseReference,
      rigName: s.rigName,
    })),
    trajectories,
    // The composition rule, which is the one thing here no single record states and
    // every consumer of a moving rig depends on.
    sensorPosesAt: prov.sensors.map((s) => {
      const probe = sensorProbeTime(prov, s.rigName);
      return poseRow(probe, prov.sensorPoseAt(s.name, probe), s.name);
    }),
  };
}

/**
 * Object records plus post-track gaussian states at three scene-clock probes.
 *
 * Stored fields alone do not prove reconstruction: two implementations can agree on
 * every entry in the table and every sample in a track and still disagree about where a
 * gaussian ends up, because the layer's one rule is an order — base first, track second.
 * The states make that order visible, including orientation, and the canonical gaussian
 * order keeps the result independent of chunk and decoder order.
 */
function objectsAndStates(
  header: SceneSummaryInput["header"],
  gaussians: GaussianSet,
  objects: ObjectLayer | null,
  order: readonly number[],
): Record<string, unknown> {
  const layer = objects ?? new ObjectLayerClass();

  const tracks = layer.tracks.map((track) => ({
    objectId: String(track.objectId),
    interpolation: track.interpolation,
    sampleCount: String(track.times.length),
    posesAt: probeTimes(track).map((probe) => poseRow(probe, layer.poseAt(track.objectId, probe))),
  }));

  const entries = (layer.table?.entries ?? []).map((entry) => {
    let embeddingCrc: string | null = null;
    if (entry.embedding !== null) {
      const bytes = new Uint8Array(entry.embedding.length * 4);
      const view = new DataView(bytes.buffer);
      for (let i = 0; i < entry.embedding.length; i++) {
        view.setFloat32(i * 4, entry.embedding[i]!, true);
      }
      embeddingCrc = crc(bytes);
    }
    return {
      objectId: String(entry.objectId),
      label: entry.label,
      anchor: entry.anchor.map((v) => num(v)),
      // The decoded dynamics values, not merely their presence: a summary that said only
      // whether the record was there would pass a decoder that read the nine floats and
      // exposed zeros. Null when the entry carries none.
      dynamics:
        entry.dynamics === null
          ? null
          : {
              velocity: entry.dynamics[0].map((v) => num(v)),
              angularVelocity: entry.dynamics[1].map((v) => num(v)),
              acceleration: entry.dynamics[2].map((v) => num(v)),
            },
      hasEmbedding: entry.embedding !== null,
      embeddingCrc,
    };
  });

  const duration = Math.max(0, header.durationSec);
  const states = [0, 0.5 * duration, Math.max(0, duration - 1e-6)].map((t) => {
    const base = canonicalObjectStateAt(gaussians, layer, t, header.cutoff);

    const rowForIndex = new Map<number, number>();
    base.indices.forEach((index, row) => rowForIndex.set(index, row));
    const sampleRows: number[] = [];
    for (const index of order) {
      const row = rowForIndex.get(index);
      if (row !== undefined) sampleRows.push(row);
      if (sampleRows.length === SAMPLE) break;
    }

    const rows = (values: readonly number[], width: number): (number | null)[][] =>
      sampleRows.map((row) => {
        const out: (number | null)[] = [];
        for (let axis = 0; axis < width; axis++) out.push(num(values[row * width + axis]));
        return out;
      });

    const positionSum = [0, 1, 2].map((axis) => {
      let total = 0;
      for (let row = 0; row < base.indices.length; row++) total += base.centers[row * 3 + axis]!;
      return num(total);
    });
    let opacitySum = 0;
    for (const value of base.opacity) opacitySum += value;

    return {
      t: num(t),
      liveCount: String(base.indices.length),
      sample: {
        positions: rows(base.centers, 3),
        orientations: rows(base.orientations, 4),
        objectIds: sampleRows.map((row) => String(base.objectIds[row])),
      },
      aggregate: { positionSum, opacitySum: num(opacitySum) },
    };
  });

  return {
    objects: {
      embeddingDim: layer.table === null ? 0 : layer.table.embeddingDim,
      table: entries,
      tracks,
    },
    states,
  };
}

interface CanonicalObjectState {
  readonly indices: number[];
  readonly centers: number[];
  readonly orientations: number[];
  readonly opacity: number[];
  readonly objectIds: number[];
}

/**
 * Reconstruct in double precision for the six-decimal comparison.
 *
 * Production state arrays are float32 — {@link GaussianSet.stateAt} returns those, and
 * that is the right storage for a decoder. Widening the decoded fields first is what
 * keeps the canonical summary a statement about the format rather than about an SDK's
 * output storage type, and it is what the Python and Rust references do.
 */
function canonicalObjectStateAt(
  gaussians: GaussianSet,
  layer: ObjectLayer,
  t: number,
  cutoff: number,
): CanonicalObjectState {
  const state: CanonicalObjectState = {
    indices: [],
    centers: [],
    orientations: [],
    opacity: [],
    objectIds: [],
  };
  for (let i = 0; i < gaussians.count; i++) {
    if (!(gaussians.winLo[i]! <= t && t < gaussians.winHi[i]!)) continue;
    const mu = gaussians.muT[i]!;
    const sigma = gaussians.sigmaT[i]!;
    const marginal = Number.isFinite(sigma)
      ? Math.exp(-0.5 * ((t - mu) / Math.max(sigma, 1e-30)) ** 2)
      : 1;
    if (marginal < cutoff) continue;
    state.indices.push(i);
    for (let axis = 0; axis < 3; axis++) {
      state.centers.push(
        gaussians.positions[i * 3 + axis]! + gaussians.motions[i * 3 + axis]! * (t - mu),
      );
    }
    for (let axis = 0; axis < 4; axis++)
      state.orientations.push(gaussians.rotations[i * 4 + axis]!);
    state.opacity.push(gaussians.colors[i * 4 + 3]! * marginal);
    state.objectIds.push(gaussians.objectId === null ? 0 : gaussians.objectId[i]!);
  }

  const referenced = new Set(state.objectIds.filter((id) => id !== 0));
  const poses = new Map<number, Pose>();
  for (const track of layer.tracks) {
    if (!referenced.has(track.objectId)) continue;
    const pose = layer.poseAt(track.objectId, t);
    if (pose !== null) poses.set(track.objectId, pose);
  }
  for (let row = 0; row < state.objectIds.length; row++) {
    const pose = poses.get(state.objectIds[row]!);
    if (pose === undefined) continue;
    const moved = poseApply(pose, state.centers.slice(row * 3, row * 3 + 3));
    for (let axis = 0; axis < 3; axis++) state.centers[row * 3 + axis] = moved[axis]!;
    const turned = quaternionMultiply(
      pose.rotation,
      state.orientations.slice(row * 4, row * 4 + 4),
    );
    for (let axis = 0; axis < 4; axis++) state.orientations[row * 4 + axis] = turned[axis]!;
  }
  return state;
}

/** Times a summary evaluates a trajectory at, derived from the trajectory itself. */
function probeTimes(trajectory: { readonly times: readonly number[] }): number[] {
  if (trajectory.times.length === 0) return [];
  const first = trajectory.times[0]!;
  const last = trajectory.times[trajectory.times.length - 1]!;
  return [first - 0.5, first, first + (last - first) * 0.5, last, last + 0.5];
}

/** When to evaluate a sensor's scene pose: the midpoint of the rig it rides. */
function sensorProbeTime(prov: Provenance, rigName: string): number {
  const trajectory = rigName ? prov.trajectory(rigName) : null;
  if (trajectory === null || trajectory.times.length === 0) return 0;
  return (
    trajectory.times[0]! +
    (trajectory.times[trajectory.times.length - 1]! - trajectory.times[0]!) * 0.5
  );
}

function poseRow(t: number, pose: Pose | null, sensor?: string): unknown {
  const row: Record<string, unknown> = { time: num(t) };
  if (sensor !== undefined) row.sensor = sensor;
  if (pose === null) {
    row.rotation = null;
    row.translation = null;
    return row;
  }
  row.rotation = pose.rotation.map((v) => num(v));
  row.translation = pose.translation.map((v) => num(v));
  return row;
}

function summarizeAudioSource(source: CanonicalAudioSource, sampleTime: number): unknown {
  const state = audioSourceStateAt(source, sampleTime);
  return {
    sourceId: String(source.sourceId),
    name: source.name,
    codec: source.codec,
    channelLayout: source.channelLayout,
    startSec: num(source.startSec),
    durationSec: num(source.durationSec),
    gain: num(source.gain),
    spatial: source.spatial,
    loop: source.loop,
    position: source.position.map(num),
    rotation: source.rotation.map(num),
    keyframeCount: String(source.keyframes.length),
    keyframes: source.keyframes.slice(0, AUDIO_KEYFRAMES).map((keyframe) => ({
      time: num(keyframe.time),
      position: keyframe.position.map(num),
      rotation: keyframe.rotation.map(num),
    })),
    interpolation: source.interpolation,
    stateAtHalf: {
      active: state.active,
      localTime: num(state.localTime),
      position: state.position.map(num),
      rotation: state.rotation.map(num),
      gain: num(state.gain),
    },
    byteLength: String(source.dataLength),
    crc: "data" in source ? crc(source.data) : source.payloadCrc,
  };
}

function sortedMap(map: ReadonlyMap<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of [...map.keys()].sort()) out[key] = map.get(key)!;
  return out;
}

function summarizeCamera(camera: Camera): unknown {
  return {
    fovYDeg: num(camera.fovYDeg),
    position: camera.position.map((v) => num(v)),
    target: camera.target.map((v) => num(v)),
    keyframeCount: String(camera.keyframes.length),
    keyframes: camera.keyframes.slice(0, CAMERA_KEYFRAMES).map((k) => ({
      time: num(k.time),
      position: k.position.map((v) => num(v)),
      target: k.target.map((v) => num(v)),
    })),
    interpolation: camera.interpolation,
    loop: camera.loop,
  };
}

/**
 * Degree, width and a checksum of the coefficients in content order.
 *
 * A digest rather than the coefficients themselves: degree 2 over 512 gaussians is 12,288
 * bytes, which would swamp the expectation without proving anything the checksum does
 * not. Taken in content order so that two decoders which visit gaussians differently
 * still agree.
 */
function summarizeSh(gaussians: GaussianSet, order: readonly number[]): unknown {
  const sh = gaussians.sh;
  if (sh === null || gaussians.shDegree === 0) return null;
  const width = sh.coefficients * 3;
  const payload = new Uint8Array(order.length * width);
  let at = 0;
  for (const i of order) {
    payload.set(sh.values.subarray(i * width, i * width + width), at);
    at += width;
  }
  return {
    degree: gaussians.shDegree,
    coefficients: String(sh.coefficients),
    crc: crc(payload),
  };
}

/**
 * Sort gaussians into an order both implementations can reproduce.
 *
 * Chunking and spatial ordering are encoder choices, so decoded order is not part of the
 * contract — but a comparison needs some order. The key is the gaussian's whole decoded
 * state, rounded exactly as the summary rounds it, with its spherical harmonic
 * coefficients last. Two gaussians that tie on all of it are identical in every value
 * this summary emits, so their relative order cannot change the output.
 */
function stableOrder(gaussians: GaussianSet): number[] {
  const keys: number[][] = new Array<number[]>(gaussians.count);
  const shWidth = gaussians.sh === null ? 0 : gaussians.sh.coefficients * 3;
  for (let i = 0; i < gaussians.count; i++) {
    const row: number[] = [];
    for (const [array, width] of [
      [gaussians.positions, 3],
      [gaussians.scales, 3],
      [gaussians.rotations, 4],
      [gaussians.colors, 4],
      [gaussians.motions, 3],
    ] as const) {
      for (let k = 0; k < width; k++) row.push(sortable(array[i * width + k]!));
    }
    row.push(
      sortable(gaussians.muT[i]!),
      sortable(gaussians.sigmaT[i]!),
      sortable(gaussians.winLo[i]!),
      sortable(gaussians.winHi[i]!),
    );
    for (let k = 0; k < shWidth; k++) row.push(gaussians.sh!.values[i * shWidth + k]!);
    // Membership joins the key, after the harmonics and before the index tiebreak, exactly
    // where the Python and Rust references put it. Two gaussians can tie on every rounded
    // field and still belong to different objects — and then the `objectIds` sample, and the
    // states composed from it, would be ordered by decode order, which differs between two
    // correct readers that chunked the scene differently.
    if (gaussians.objectId !== null) row.push(gaussians.objectId[i]!);
    row.push(i);
    keys[i] = row;
  }
  keys.sort(compareRows);
  return keys.map((row) => row[row.length - 1]!);
}

/**
 * Lexicographic comparison, written out rather than subtracted: infinity minus infinity
 * is not a number, and a never-fading gaussian's sigma is infinity.
 */
function compareRows(a: readonly number[], b: readonly number[]): number {
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x < y) return -1;
    if (x > y) return 1;
  }
  return 0;
}

/** A comparison key: rounded like the summary, with infinity kept as infinity. */
function sortable(value: number): number {
  if (Number.isNaN(value)) return Infinity;
  if (!Number.isFinite(value)) return value;
  return roundHalfEven(value, FLOAT_DECIMALS);
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
