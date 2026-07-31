// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * What the provenance records mean once they have been read.
 *
 * `records.ts` knows the bytes; this module knows the arithmetic and the rules that
 * span more than one record — that sensor names are unique, that a sensor posed against
 * a rig names a rig the file actually carries, and how a pose is recovered between two
 * trajectory samples.
 *
 * The interpolation rules here are the specification's, executable. Section 5.15.4
 * states them in prose because a specification has to; a reference implementation
 * exists so that "shortest-arc slerp" and "clamped, never extrapolated" have exactly
 * one meaning rather than one per reader.
 *
 * Nothing here is required to decode gaussians. A consumer that only wants geometry
 * never constructs a {@link Provenance}, and a file that carries none produces an empty
 * one — which is a value, not an error.
 */

import { MalformedFile } from "./errors.js";
import {
  type CoordinateFrame,
  type GeodeticAnchor,
  type RigTrajectory,
  type SensorCalibration,
  POSE_TO_RIG,
  TRAJECTORY_LINEAR,
  TRAJECTORY_STEP,
} from "./records.js";

/** Metres per unit for each registry length unit, or `undefined` for one this build does not know. */
export const LENGTH_UNIT_METRES: ReadonlyMap<number, number> = new Map([
  [1, 1.0],
  [2, 0.01],
  [3, 0.001],
  [4, 1000.0],
  [5, 0.3048],
  [6, 0.0254],
]);

/** A rigid transform: rotate by a unit quaternion, then translate. */
export interface Pose {
  /** Unit quaternion, `xyzw`. */
  readonly rotation: readonly [number, number, number, number];
  readonly translation: readonly [number, number, number];
}

/** `R(rotation) * point + translation`, the direction section 5.15.3 states. */
export function poseApply(
  pose: Pose,
  point: readonly [number, number, number] | readonly number[],
): [number, number, number] {
  const [x, y, z, w] = pose.rotation;
  const px = point[0]!;
  const py = point[1]!;
  const pz = point[2]!;
  // q * (0, p) * q^-1, expanded. Two cross products rather than a 3x3 build.
  const tx = 2.0 * (y * pz - z * py);
  const ty = 2.0 * (z * px - x * pz);
  const tz = 2.0 * (x * py - y * px);
  return [
    px + w * tx + (y * tz - z * ty) + pose.translation[0],
    py + w * ty + (z * tx - x * tz) + pose.translation[1],
    pz + w * tz + (x * ty - y * tx) + pose.translation[2],
  ];
}

/** `self ∘ inner`: apply `inner` first, then `self`. */
export function poseCompose(self: Pose, inner: Pose): Pose {
  return {
    rotation: quaternionMultiply(self.rotation, inner.rotation),
    translation: poseApply(self, inner.translation),
  };
}

function quaternionMultiply(
  a: readonly number[],
  b: readonly number[],
): [number, number, number, number] {
  const [ax, ay, az, aw] = a;
  const [bx, by, bz, bw] = b;
  return [
    aw! * bx! + ax! * bw! + ay! * bz! - az! * by!,
    aw! * by! - ax! * bz! + ay! * bw! + az! * bx!,
    aw! * bz! + ax! * by! - ay! * bx! + az! * bw!,
    aw! * bw! - ax! * bx! - ay! * by! - az! * bz!,
  ];
}

function normalize(q: readonly number[]): [number, number, number, number] {
  const norm = Math.sqrt(q.reduce((sum, v) => sum + v * v, 0));
  if (!Number.isFinite(norm) || norm === 0) {
    throw new MalformedFile(`a quaternion with norm ${norm} has no direction`);
  }
  return [q[0]! / norm, q[1]! / norm, q[2]! / norm, q[3]! / norm];
}

/**
 * Shortest-arc spherical interpolation between two unit quaternions.
 *
 * The sign flip is a correctness rule, not an optimization: `q` and `-q` are the same
 * rotation, so without it a trajectory takes the long way round between two poses a
 * degree apart.
 */
export function slerp(
  a: readonly number[],
  b: readonly number[],
  u: number,
): [number, number, number, number] {
  const qa = normalize(a);
  let qb: readonly number[] = normalize(b);
  let dot = qa[0] * qb[0]! + qa[1] * qb[1]! + qa[2] * qb[2]! + qa[3] * qb[3]!;
  if (dot < 0) {
    qb = [-qb[0]!, -qb[1]!, -qb[2]!, -qb[3]!];
    dot = -dot;
  }
  if (dot > 0.9995) {
    // Near-parallel: the great-circle formula divides by a sine approaching zero, and a
    // straight lerp is within float noise of it here.
    return normalize([
      qa[0] + u * (qb[0]! - qa[0]),
      qa[1] + u * (qb[1]! - qa[1]),
      qa[2] + u * (qb[2]! - qa[2]),
      qa[3] + u * (qb[3]! - qa[3]),
    ]);
  }
  const theta = Math.acos(Math.min(1, Math.max(-1, dot)));
  const sinTheta = Math.sin(theta);
  const wa = Math.sin((1 - u) * theta) / sinTheta;
  const wb = Math.sin(u * theta) / sinTheta;
  return [
    wa * qa[0] + wb * qb[0]!,
    wa * qa[1] + wb * qb[1]!,
    wa * qa[2] + wb * qb[2]!,
    wa * qa[3] + wb * qb[3]!,
  ];
}

/**
 * A record {@link poseAt} can sample: time-stamped rigid poses with an interpolation mode.
 *
 * Both {@link RigTrajectory} and (later) the object layer's SE(3) track satisfy this
 * structurally — the clamp-and-slerp is written once and shared.
 */
export interface PoseSampled {
  readonly name: string;
  readonly interpolation: number;
  readonly times: readonly number[];
  readonly rotations: readonly (readonly number[])[];
  readonly translations: readonly (readonly number[])[];
}

/**
 * The pose at scene time `t`, or `null` when the record has no samples.
 *
 * Outside the sample range the pose is **clamped**, never extrapolated: before the first
 * sample it is the first sample, at or after the last it is the last.
 */
export function poseAt(trajectory: PoseSampled, t: number): Pose | null {
  const n = trajectory.times.length;
  if (n === 0) return null;
  const times = trajectory.times;
  if (t <= times[0]!) return sample(trajectory, 0);
  if (t >= times[n - 1]!) return sample(trajectory, n - 1);

  // Times are strictly increasing (enforced at parse), so a bisection is exact.
  let lo = 0;
  let hi = n - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (times[mid]! <= t) lo = mid;
    else hi = mid;
  }

  if (trajectory.interpolation === TRAJECTORY_STEP) return sample(trajectory, lo);
  if (trajectory.interpolation !== TRAJECTORY_LINEAR) {
    // Unknown-but-legal, not malformed — but there is no defensible way to invent the
    // rule, and picking linear would silently answer a question the file asked
    // differently. Naming it is the whole obligation.
    throw new MalformedFile(
      `trajectory ${JSON.stringify(trajectory.name)} uses interpolation ${trajectory.interpolation}, ` +
        "which this build does not implement",
    );
  }

  const span = times[lo + 1]! - times[lo]!;
  const u = (t - times[lo]!) / span;
  const a = sample(trajectory, lo);
  const b = sample(trajectory, lo + 1);
  return {
    rotation: slerp(a.rotation, b.rotation, u),
    translation: [
      a.translation[0] + u * (b.translation[0] - a.translation[0]),
      a.translation[1] + u * (b.translation[1] - a.translation[1]),
      a.translation[2] + u * (b.translation[2] - a.translation[2]),
    ],
  };
}

function sample(trajectory: PoseSampled, i: number): Pose {
  const r = trajectory.rotations[i]!;
  const t = trajectory.translations[i]!;
  return {
    rotation: normalize(r),
    translation: [t[0]!, t[1]!, t[2]!],
  };
}

/**
 * Every provenance record a file carried, and the rules that span them.
 *
 * An empty instance is what a scene with no provenance produces. That is a value and
 * never an error: absence costs nothing and means nothing is claimed.
 */
export class Provenance {
  readonly frames: CoordinateFrame[];
  readonly sensors: SensorCalibration[];
  readonly trajectories: RigTrajectory[];
  readonly anchors: GeodeticAnchor[];

  constructor(
    frames: CoordinateFrame[] = [],
    sensors: SensorCalibration[] = [],
    trajectories: RigTrajectory[] = [],
    anchors: GeodeticAnchor[] = [],
  ) {
    this.frames = frames;
    this.sensors = sensors;
    this.trajectories = trajectories;
    this.anchors = anchors;
  }

  /** True when the file carried at least one provenance record. */
  get isEmpty(): boolean {
    return (
      this.frames.length === 0 &&
      this.sensors.length === 0 &&
      this.trajectories.length === 0 &&
      this.anchors.length === 0
    );
  }

  /** The file's own scene frame — the one named `""` — or `null`. */
  get frame(): CoordinateFrame | null {
    return this.frameNamed("");
  }

  frameNamed(name: string): CoordinateFrame | null {
    return this.frames.find((f) => f.name === name) ?? null;
  }

  sensor(name: string): SensorCalibration | null {
    return this.sensors.find((s) => s.name === name) ?? null;
  }

  trajectory(name = ""): RigTrajectory | null {
    return this.trajectories.find((t) => t.name === name) ?? null;
  }

  anchor(frameName = ""): GeodeticAnchor | null {
    return this.anchors.find((a) => a.frameName === frameName) ?? null;
  }

  /**
   * One unit of a frame in metres, or `null` when the file does not say.
   *
   * `metresPerUnit` is the authority where it and `lengthUnit` disagree (spec
   * section 5.15.2): the number is what a consumer computes with, the enum is what it
   * prints.
   */
  metresPerUnit(frameName = ""): number | null {
    const frame = this.frameNamed(frameName);
    if (frame === null) return null;
    if (frame.metresPerUnit > 0) return frame.metresPerUnit;
    return LENGTH_UNIT_METRES.get(frame.lengthUnit) ?? null;
  }

  /**
   * A sensor's pose in the scene frame at scene time `t`.
   *
   * For a sensor posed against the scene this is its extrinsic and `t` is ignored. For
   * one posed against a rig it is the rig's pose at `t` composed with the extrinsic.
   */
  sensorPoseAt(name: string, t: number): Pose | null {
    const sensor = this.sensor(name);
    if (sensor === null) return null;
    const extrinsic: Pose = {
      rotation: normalize(sensor.rotation),
      translation: [sensor.translation[0]!, sensor.translation[1]!, sensor.translation[2]!],
    };
    if (sensor.poseReference !== POSE_TO_RIG) return extrinsic;
    const trajectory = this.trajectory(sensor.rigName);
    if (trajectory === null) {
      throw new MalformedFile(
        `sensor ${JSON.stringify(sensor.name)} is posed against rig ` +
          `${JSON.stringify(sensor.rigName)}, which this file does not carry`,
      );
    }
    const rig = poseAt(trajectory, t);
    return rig === null ? extrinsic : poseCompose(rig, extrinsic);
  }

  /**
   * The rules no single record can enforce on its own.
   *
   * Both are refusals rather than repairs: a duplicate name makes every reference a coin
   * toss; a rig reference into a file that carries no such rig would put every sensor on
   * that rig at the origin.
   */
  check(): void {
    const groups: readonly [string, readonly string[], string][] = [
      ["CoordinateFrame", this.frames.map((f) => f.name), "5.15.2"],
      ["SensorCalibration", this.sensors.map((s) => s.name), "5.15.3"],
      ["RigTrajectory", this.trajectories.map((t) => t.name), "5.15.4"],
      ["GeodeticAnchor", this.anchors.map((a) => a.frameName), "5.15.5"],
    ];
    for (const [label, names, section] of groups) {
      const seen = new Set<string>();
      for (const name of names) {
        if (seen.has(name)) {
          throw new MalformedFile(
            `two ${label} records are named ${JSON.stringify(name)}; these records are ` +
              `referred to by name and nothing else (section ${section})`,
          );
        }
        seen.add(name);
      }
    }

    const rigs = new Set(this.trajectories.map((t) => t.name));
    for (const sensor of this.sensors) {
      if (sensor.poseReference === POSE_TO_RIG && !rigs.has(sensor.rigName)) {
        throw new MalformedFile(
          `sensor ${JSON.stringify(sensor.name)} is posed against rig ` +
            `${JSON.stringify(sensor.rigName)}, which this file does not carry (section 5.15.3)`,
        );
      }
    }

    const frames = new Set(this.frames.map((f) => f.name));
    for (const anchor of this.anchors) {
      if (!frames.has(anchor.frameName)) {
        throw new MalformedFile(
          `a GeodeticAnchor anchors frame ${JSON.stringify(anchor.frameName)}, which this ` +
            "file does not define; an anchor for a frame nobody declared is a latitude " +
            "attached to nothing (section 5.15.5)",
        );
      }
    }
  }
}
