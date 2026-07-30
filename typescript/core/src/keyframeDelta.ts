// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The `keyframe-delta` temporal model: composition, and the chain a seek walks (spec §11).
 *
 * State at time `t` is the nearest previous keyframe with the deltas between it and `t`
 * composed onto it. Everything here operates on **quantization bins**, not on values, and
 * that is the single load-bearing decision in the model:
 *
 *     A delta is a difference of bins, never a quantization of a difference.
 *
 * The keyframe stores `b0 = q(x0)`. Delta `j` stores the integer `q(xj) - q(x_{j-1})`. The
 * composition telescopes over integers, so the composed bin *is* `q(x_d)` — the bin the
 * encoder would have written had it stated that instant absolutely (spec §11.7). Nothing
 * here dequantizes; composition produces bins, and the reconstruction turns bins into
 * gaussians by the same arithmetic a keyframe chunk's do.
 */

import { MalformedFile } from "./errors.js";
import { Attribute } from "./opcodes.js";
import type { ChunkIndexEntry } from "./records.js";

/**
 * Composed bins are signed 32-bit (spec §11.7). Not a limit anyone meets — at a millimetre
 * grid it spans about 2,000 km — but stated so two decoders in two languages agree on
 * where the boundary is. Overflow is refused, never wrapped: a wrapped position bin is a
 * gaussian at a plausible-looking wrong place, which is the failure the bounds contract
 * exists to make impossible.
 */
export const BIN_MIN = -(2 ** 31);
export const BIN_MAX = 2 ** 31 - 1;

/**
 * Attributes a delta's update group MUST NOT carry (spec §11.5). The three derive the
 * per-gaussian grids for velocity and birth time, so a bin difference across a change in
 * any of them is a difference between bins on two grids — a number with no interpretation.
 */
export const GOP_INVARIANT: ReadonlySet<number> = new Set([
  Attribute.SigmaT,
  Attribute.Flags,
  Attribute.WindowIndex,
]);

/**
 * Attributes an update restates outright rather than differencing (spec §11.5). The
 * smallest-three coding omits the largest-magnitude component, so the three stored bins
 * mean different components either side of a change; rotation is restated absolutely.
 */
export const ABSOLUTE_IN_UPDATE: ReadonlySet<number> = new Set([
  Attribute.RotationIndex,
  Attribute.Rotation,
]);

/** One attribute's bins for a population, element-major: channel `c` of row `i` at `i*channels+c`. */
export interface BinColumn {
  readonly values: Int32Array;
  readonly channels: number;
}

/**
 * A composed population: identities, and one bin column per attribute.
 *
 * `ids` and every column's rows are aligned, and the order is an implementation detail —
 * nothing in the format depends on it and no reader may rely on it.
 */
export interface State {
  readonly ids: Int32Array;
  readonly bins: ReadonlyMap<number, BinColumn>;
}

export function stateCount(state: State): number {
  return state.ids.length;
}

/** A group's decoded streams: the ids it names, and a bin column per other attribute. */
export interface Group {
  readonly ids: Int32Array;
  readonly bins: ReadonlyMap<number, BinColumn>;
}

/** The state a keyframe chunk states outright, with its identities checked. */
export function keyframeState(ids: Int32Array, bins: ReadonlyMap<number, BinColumn>): State {
  checkUnique(ids, "a keyframe");
  for (const [attribute, column] of bins) {
    const rows = column.values.length / column.channels;
    if (rows !== ids.length) {
      throw new MalformedFile(
        `attribute ${attribute} carries ${rows} rows, the keyframe declares ${ids.length} gaussians`,
        "stream-element-count-mismatch",
      );
    }
  }
  return { ids, bins };
}

/**
 * Compose one delta onto the state it references (spec §11.3).
 *
 * Deaths, then updates, then births. The order is normative because a chunk that both
 * kills and creates would otherwise be ambiguous. An id may appear in only one of the
 * three groups.
 */
export function applyDelta(
  state: State,
  updates: Group,
  births: Group,
  deathIds: Int32Array,
): State {
  checkGroupsDisjoint(updates.ids, births.ids, deathIds);
  checkUnique(updates.ids, "an update group");
  checkUnique(births.ids, "a birth group");
  checkUnique(deathIds, "a death group");

  for (const attribute of updates.bins.keys()) {
    if (GOP_INVARIANT.has(attribute)) {
      throw new MalformedFile(
        `an update carries attribute ${attribute}, which is fixed for a gaussian's lifetime ` +
          `within a group: the per-gaussian grids for velocity and birth time are derived from it, ` +
          `so a bin difference across a change in it has no defined meaning`,
        "invariant-changed-in-update",
      );
    }
  }

  // --- deaths: drop the killed rows, keeping every column aligned ---------
  let ids = state.ids;
  let bins = new Map<number, BinColumn>();
  if (deathIds.length > 0) {
    const rowOf = rowIndex(state.ids);
    const deathRows = new Set<number>();
    for (const id of deathIds) {
      const row = rowOf.get(id);
      if (row === undefined) {
        throw new MalformedFile(
          `a delta kills gaussian id ${id}, which is not live at its reference`,
          "unknown-gaussian-id",
        );
      }
      deathRows.add(row);
    }
    const keep: number[] = [];
    for (let i = 0; i < state.ids.length; i++) if (!deathRows.has(i)) keep.push(i);
    ids = gather(state.ids, keep);
    for (const [attribute, column] of state.bins) {
      bins.set(attribute, gatherColumn(column, keep));
    }
  } else {
    ids = state.ids.slice();
    for (const [attribute, column] of state.bins) {
      bins.set(attribute, { values: column.values.slice(), channels: column.channels });
    }
  }

  // --- updates: replace or add-compose the carried attributes -------------
  if (updates.ids.length > 0) {
    const rowOf = rowIndex(ids);
    const rows = new Int32Array(updates.ids.length);
    for (let i = 0; i < updates.ids.length; i++) {
      const row = rowOf.get(updates.ids[i]!);
      if (row === undefined) {
        throw new MalformedFile(
          `a delta updates gaussian id ${updates.ids[i]!}, which is not live at its reference`,
          "unknown-gaussian-id",
        );
      }
      rows[i] = row;
    }
    for (const [attribute, delta] of updates.bins) {
      const base = bins.get(attribute);
      if (base === undefined) {
        throw new MalformedFile(
          `an update touches attribute ${attribute}, which the referenced state does not carry`,
          "unknown-attribute-in-update",
        );
      }
      const rowsDeclared = delta.values.length / delta.channels;
      if (rowsDeclared !== updates.ids.length) {
        throw new MalformedFile(
          `attribute ${attribute} carries ${rowsDeclared} rows, the update group declares ${updates.ids.length}`,
          "stream-element-count-mismatch",
        );
      }
      const absolute = ABSOLUTE_IN_UPDATE.has(attribute);
      const ch = base.channels;
      for (let i = 0; i < updates.ids.length; i++) {
        const target = rows[i]! * ch;
        const source = i * delta.channels;
        for (let c = 0; c < ch; c++) {
          if (absolute) {
            base.values[target + c] = delta.values[source + c]!;
          } else {
            const composed = base.values[target + c]! + delta.values[source + c]!;
            if (composed < BIN_MIN || composed > BIN_MAX) {
              throw new MalformedFile(
                `composing attribute ${attribute} for gaussian id ${updates.ids[i]!} leaves the ` +
                  `signed 32-bit range a composed bin must stay inside`,
                "bin-overflow",
              );
            }
            base.values[target + c] = composed;
          }
        }
      }
    }
  }

  // --- births: insert absolute state for new ids --------------------------
  if (births.ids.length > 0) {
    const live = new Set(ids);
    for (const id of births.ids) {
      if (live.has(id)) {
        throw new MalformedFile(
          `a delta creates gaussian id ${id}, which is already live; ids are unique within a ` +
            `state and are not reused after a death`,
          "duplicate-gaussian-id",
        );
      }
    }
    const absent: number[] = [];
    for (const attribute of bins.keys()) if (!births.bins.has(attribute)) absent.push(attribute);
    if (absent.length > 0) {
      throw new MalformedFile(
        `a birth group carries no value for attributes ${absent.sort((a, b) => a - b).join(", ")}; ` +
          `a birth is absolute state, not a delta`,
        "incomplete-birth",
      );
    }
    for (const [attribute, column] of births.bins) {
      const rowsDeclared = column.values.length / column.channels;
      if (rowsDeclared !== births.ids.length) {
        throw new MalformedFile(
          `attribute ${attribute} carries ${rowsDeclared} rows, the birth group declares ${births.ids.length}`,
          "stream-element-count-mismatch",
        );
      }
    }
    ids = concatInt32(ids, births.ids);
    const grown = new Map<number, BinColumn>();
    const attributes = new Set<number>([...bins.keys(), ...births.bins.keys()]);
    for (const attribute of attributes) {
      const existing = bins.get(attribute);
      const born = births.bins.get(attribute)!; // present: every state attribute is in births
      if (existing === undefined) {
        grown.set(attribute, { values: born.values.slice(), channels: born.channels });
      } else {
        grown.set(attribute, {
          values: concatInt32(existing.values, born.values),
          channels: existing.channels,
        });
      }
    }
    bins = grown;
  }

  return { ids, bins };
}

function rowIndex(ids: Int32Array): Map<number, number> {
  const out = new Map<number, number>();
  for (let i = 0; i < ids.length; i++) out.set(ids[i]!, i);
  return out;
}

function gather(source: Int32Array, rows: readonly number[]): Int32Array {
  const out = new Int32Array(rows.length);
  for (let i = 0; i < rows.length; i++) out[i] = source[rows[i]!]!;
  return out;
}

function gatherColumn(column: BinColumn, rows: readonly number[]): BinColumn {
  const ch = column.channels;
  const out = new Int32Array(rows.length * ch);
  for (let i = 0; i < rows.length; i++) {
    const src = rows[i]! * ch;
    for (let c = 0; c < ch; c++) out[i * ch + c] = column.values[src + c]!;
  }
  return { values: out, channels: ch };
}

function concatInt32(a: Int32Array, b: Int32Array): Int32Array {
  const out = new Int32Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function checkUnique(ids: Int32Array, what: string): void {
  const seen = new Set<number>();
  for (const id of ids) {
    if (seen.has(id)) {
      throw new MalformedFile(
        `${what} names gaussian id ${id} more than once`,
        "duplicate-gaussian-id",
      );
    }
    seen.add(id);
  }
}

function checkGroupsDisjoint(
  updateIds: Int32Array,
  birthIds: Int32Array,
  deathIds: Int32Array,
): void {
  const pairs: readonly [Int32Array, Int32Array, string][] = [
    [updateIds, birthIds, "updated and born"],
    [updateIds, deathIds, "updated and killed"],
    [birthIds, deathIds, "born and killed"],
  ];
  for (const [a, b, names] of pairs) {
    const set = new Set(a);
    for (const id of b) {
      if (set.has(id)) {
        throw new MalformedFile(
          `gaussian id ${id} is ${names} by the same delta; the outcome would depend on the ` +
            `order the groups are applied in`,
          "id-in-two-groups",
        );
      }
    }
  }
}

// --------------------------------------------------------------------------
// Seeking: the chain, answered from the index alone (spec §11.8)
// --------------------------------------------------------------------------

/**
 * State chunks tile the timeline: no overlap, no gap (spec §11.1).
 *
 * This is what makes the seek predicate a lookup rather than a search, and it is a real
 * constraint — under `gaussian-birth` chunks may overlap freely, and here they may not.
 */
export function checkTiling(index: readonly ChunkIndexEntry[]): void {
  const ordered = [...index].sort((a, b) => a.t0 - b.t0);
  for (let i = 1; i < ordered.length; i++) {
    const previous = ordered[i - 1]!;
    const entry = ordered[i]!;
    if (previous.t1 !== entry.t0) {
      const what = entry.t0 < previous.t1 ? "overlap" : "leave a gap";
      throw new MalformedFile(
        `state chunks ${what}: [${previous.t0}, ${previous.t1}) is followed by [${entry.t0}, ${entry.t1})`,
        "non-tiling-chunks",
      );
    }
  }
}

/**
 * The keyframe and deltas a reader must read to reconstruct instant `t` (spec §11.8).
 *
 * Answered from the index alone — no chunk is fetched to learn what another references —
 * and returned oldest first, which is the order {@link applyDelta} composes in.
 */
export function chainFor(index: readonly ChunkIndexEntry[], t: number): ChunkIndexEntry[] {
  const byOffset = new Map<number, ChunkIndexEntry>();
  for (const entry of index) byOffset.set(entry.chunkOffset, entry);

  const current = index.find((entry) => entry.t0 <= t && t < entry.t1);
  if (current === undefined) {
    throw new MalformedFile(`no state chunk covers t=${t}`, "non-tiling-chunks");
  }

  const chain = [current];
  while (chain[0]!.kind !== 0) {
    const head = chain[0]!;
    if (head.referenceOffset >= head.chunkOffset) {
      throw new MalformedFile(
        `the chunk at ${head.chunkOffset} references ${head.referenceOffset}, which is not behind ` +
          `it; references point backwards only`,
        "forward-reference",
      );
    }
    const reference = byOffset.get(head.referenceOffset);
    if (reference === undefined) {
      throw new MalformedFile(
        `the chunk at ${head.chunkOffset} references ${head.referenceOffset}, which the index does ` +
          `not name`,
        "broken-reference",
      );
    }
    chain.unshift(reference);
    if (chain.length > index.length) {
      throw new MalformedFile("the chain does not reach a keyframe", "chain-without-keyframe");
    }
  }

  if (chain.length - 1 !== current.depth) {
    throw new MalformedFile(
      `the chunk at ${current.chunkOffset} declares depth ${current.depth}, but its chain walks ` +
        `${chain.length - 1} delta chunks; the index and the file disagree about the cost of this seek`,
      "depth-mismatch",
    );
  }
  return chain;
}
