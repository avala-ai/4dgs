// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/** Canonical projections for the optional-identity conformance witnesses. */

import { type GaussianSet, type Header, type KeyframeDeltaSequence } from "@4dgs/core";

import { num } from "./canonical.js";

const MARKER_KEY = "conformance";
const MARKER_VALUE = "optional-identity-zero-defaults-v1";

/** Whether a Header opts into the narrow optional-identity result. */
export function isOptionalIdentityWitness(header: Header): boolean {
  return header.attributes.get(MARKER_KEY) === MARKER_VALUE;
}

/** Logical identity rows from a gaussian-birth population, ordered by position. */
export function gaussianBirthIdentityJson(gaussians: GaussianSet): Record<string, unknown> {
  const order = Array.from({ length: gaussians.count }, (_, row) => row).sort((a, b) => {
    for (let component = 0; component < 3; component++) {
      const difference =
        gaussians.positions[a * 3 + component]! - gaussians.positions[b * 3 + component]!;
      if (difference !== 0) return difference;
    }
    return 0;
  });

  return {
    temporalModel: "gaussian-birth",
    identityRows: order.map((row) => ({
      sourceGroup: String(gaussians.sourceGroup?.[row] ?? 0),
      sourceIndex: String(gaussians.sourceIndex?.[row] ?? 0),
      objectId: String(gaussians.objectId?.[row] ?? 0),
      position: [
        num(gaussians.positions[row * 3]),
        num(gaussians.positions[row * 3 + 1]),
        num(gaussians.positions[row * 3 + 2]),
      ],
    })),
  };
}

/** Logical identity columns at every keyframe-delta state record. */
export function keyframeDeltaIdentityJson(
  sequence: KeyframeDeltaSequence,
): Record<string, unknown> {
  return {
    temporalModel: "keyframe-delta",
    identityStates: sequence.chunks.map((chunk) => {
      const order = Array.from({ length: chunk.state.count }, (_, row) => row).sort(
        (a, b) => chunk.state.ids[a]! - chunk.state.ids[b]!,
      );
      return {
        t: num(chunk.t0),
        rows: order.map((row) => {
          const identity = chunk.state.identityAt(row);
          return {
            sourceGroup: String(identity.sourceGroup),
            sourceIndex: String(identity.sourceIndex),
            objectId: String(identity.objectId),
            gaussianId: String(chunk.state.ids[row]),
          };
        }),
      };
    }),
  };
}
