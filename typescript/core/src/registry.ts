// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Well-known values, and the refusal a reader owes an unknown one.
 *
 * The registry's standing rule is that a value it does not list is legal but
 * unrecognized, and that a reader which does not know a value **must fail cleanly with a
 * message naming it** rather than guess. That rule is what makes every future extension
 * safe: a new temporal model, a new quantization scheme, a new codec can all be added
 * without a version bump precisely because an old reader stops instead of misreading.
 *
 * Until this module existed, this reader enforced neither. A file declaring a temporal
 * model it has never heard of decoded as though it were `gaussian-birth` — silently, and
 * into geometry that looks entirely plausible, because every other Header field is still
 * valid. Nothing downstream could tell that the motion it was drawing was not the motion
 * the file described.
 *
 * The wording of these messages is contract, not style: the specification's refusal table
 * writes the sentence so that two readers refusing one file say the same thing about it,
 * and the conformance suite compares refusals across languages by identifier.
 */

import { UnsupportedCodec } from "./errors.js";

/**
 * Temporal models this reader implements.
 *
 * A name the registry lists as *reserved* is one this reader must refuse, not one it may
 * treat as the default. `keyframe-delta` belongs here only when this reader can decode
 * it; until then, accepting the name would mean accepting files it cannot read, which is
 * the opposite of the refusal the rule exists for.
 */
export const KNOWN_TEMPORAL_MODELS: readonly string[] = ["gaussian-birth"];

/** Quantization schemes this reader implements. */
export const KNOWN_QUANTIZATION_SCHEMES: readonly string[] = ["uniform-v1"];

function listed(known: readonly string[]): string {
  return [...known].sort().join(", ");
}

export function checkTemporalModel(model: string): void {
  if (!KNOWN_TEMPORAL_MODELS.includes(model)) {
    throw new UnsupportedCodec(
      `the Header declares temporal model '${model}', which this reader does not implement ` +
        `(it implements ${listed(KNOWN_TEMPORAL_MODELS)})`,
    );
  }
}

export function checkQuantizationScheme(scheme: string): void {
  if (!KNOWN_QUANTIZATION_SCHEMES.includes(scheme)) {
    throw new UnsupportedCodec(
      `the Quantization record declares scheme '${scheme}', which this reader does not implement ` +
        `(it implements ${listed(KNOWN_QUANTIZATION_SCHEMES)})`,
    );
  }
}
