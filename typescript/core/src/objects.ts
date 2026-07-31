// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The object layer: what the Object Table and the SE(3) tracks mean once read.
 *
 * `records.ts` knows the bytes; this module knows the composition and the one rule that
 * spans more than one record — that at most one track moves any object.
 *
 * The layer changes a reconstructed instant in exactly one way, and it is the
 * load-bearing rule of the whole design (spec section 5.15.6):
 *
 * > A track transforms the base state; it does not replace it.
 *
 * For a gaussian belonging to object `k`, with the base centre `c0` that the temporal
 * model produced (spec section 3), and the track's pose `(R, T)` at `t`:
 *
 * ```text
 * center(t) = R * c0 + T
 * orientation(t) = R ⊗ orientation0
 * ```
 *
 * The pose is relative to the object's stored (rest) configuration, so ignoring the whole
 * layer leaves every object at rest — a valid scene — rather than a pile at the origin.
 * The transform is rigid: it moves the centre, composes the orientation, and touches
 * neither opacity nor the temporal fields, so section 3's visibility runs unchanged on
 * the base. A gaussian that carries per-gaussian motion AND belongs to a moving track is
 * neither forbidden nor track-wins: its motion moves it inside the object's frame (folded
 * into `c0`), and the track then transports the object. The two compose, base first.
 *
 * Nothing here is required to decode gaussians. A file with no object layer produces an
 * empty {@link ObjectLayer}, which is a value and never an error.
 */

import { MalformedFile } from "./errors.js";
import { poseApply, poseAt, quaternionMultiply, type Pose } from "./provenance.js";
import { BACKGROUND_OBJECT, type ObjectTable, type ObjectTrack } from "./records.js";

/**
 * Every object-layer record a file carried, and the rule that spans the tracks.
 *
 * `table` is the file's one Object Table, or `null`. `tracks` is the SE(3) tracks, at
 * most one per object. An empty instance is what a scene with no objects produces.
 */
export class ObjectLayer {
  table: ObjectTable | null;
  readonly tracks: ObjectTrack[];

  constructor(table: ObjectTable | null = null, tracks: ObjectTrack[] = []) {
    this.table = table;
    this.tracks = tracks;
  }

  get isEmpty(): boolean {
    return this.table === null && this.tracks.length === 0;
  }

  track(objectId: number): ObjectTrack | null {
    return this.tracks.find((t) => t.objectId === objectId) ?? null;
  }

  /**
   * At most one track per object.
   *
   * Two tracks for one object would move its gaussians by two poses. Each track's own
   * rules are enforced at parse; this is the one rule no single record can see.
   */
  check(): void {
    const seen = new Set<number>();
    for (const track of this.tracks) {
      if (seen.has(track.objectId)) {
        throw new MalformedFile(
          `two ObjectTrack records move object ${track.objectId}; a gaussian has one object ` +
            "and cannot be transported by two poses (section 5.15.7)",
        );
      }
      seen.add(track.objectId);
    }
  }

  /**
   * The rigid pose that transforms object `objectId` at scene time `t`.
   *
   * `null` when the object has no track — background, or an untracked object — in which
   * case its gaussians keep their base state. A track reuses the trajectory
   * clamp-and-slerp of {@link poseAt}, so a query outside the sample range returns the
   * nearest end sample rather than extrapolating.
   */
  poseAt(objectId: number, t: number): Pose | null {
    if (objectId === BACKGROUND_OBJECT) return null;
    const track = this.track(objectId);
    if (track === null || track.times.length === 0) return null;
    return poseAt(
      {
        name: `object ${objectId}`,
        interpolation: track.interpolation,
        times: track.times,
        rotations: track.rotations,
        translations: track.translations,
      },
      t,
    );
  }

  /**
   * Compose tracks onto reconstructed centres and orientations, in place.
   *
   * `centers` is `n × 3` flat, `orientations` is `n × 4` xyzw, and `objectIds` is `n`.
   * Each gaussian whose object has a track is transformed; the rest pass through
   * unchanged. Poses are sampled once per track and looked up by id, so composition is
   * O(gaussians + tracks), not O(gaussians × tracks).
   */
  apply(
    centers: Float32Array,
    orientations: Float32Array,
    objectIds: ArrayLike<number>,
    t: number,
  ): void {
    this.check();
    const count = objectIds.length;
    if (centers.length !== count * 3) {
      throw new MalformedFile(
        `object-layer composition received ${centers.length} center values for ${count} ` +
          `gaussians; expected ${count * 3}`,
      );
    }
    if (orientations.length !== count * 4) {
      throw new MalformedFile(
        `object-layer composition received ${orientations.length} orientation values for ` +
          `${count} gaussians; expected ${count * 4}`,
      );
    }

    const referenced = new Set<number>();
    for (let i = 0; i < count; i++) {
      const id = objectIds[i]!;
      if (id !== BACKGROUND_OBJECT) referenced.add(id);
    }
    const poses = new Map<number, Pose>();
    for (const track of this.tracks) {
      if (!referenced.has(track.objectId)) continue;
      const pose = this.poseAt(track.objectId, t);
      if (pose !== null) poses.set(track.objectId, pose);
    }
    if (poses.size === 0) return;

    for (let i = 0; i < count; i++) {
      const pose = poses.get(objectIds[i]!);
      if (pose === undefined) continue;
      const moved = poseApply(pose, [centers[i * 3]!, centers[i * 3 + 1]!, centers[i * 3 + 2]!]);
      centers[i * 3] = moved[0];
      centers[i * 3 + 1] = moved[1];
      centers[i * 3 + 2] = moved[2];

      const turned = quaternionMultiply(pose.rotation, [
        orientations[i * 4]!,
        orientations[i * 4 + 1]!,
        orientations[i * 4 + 2]!,
        orientations[i * 4 + 3]!,
      ]);
      for (let axis = 0; axis < 4; axis++) orientations[i * 4 + axis] = turned[axis]!;
    }
  }
}
