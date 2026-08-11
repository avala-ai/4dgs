// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The `keyframe-delta` temporal model: composition, the two read paths, and the
 * reconstruction-at-an-instant the whole model exists to make cheap.
 *
 * State at time `t` is the nearest previous keyframe with the deltas between it and `t`
 * composed onto it. Everything up to composition is **quantization bins**, never values,
 * and that is the single load-bearing decision:
 *
 *     A delta is a difference of bins, never a quantization of a difference.
 *
 * The keyframe stores `b0 = q(x0)`; delta `j` stores the integer `q(xj) - q(x_{j-1})`; the
 * composition telescopes over integers, so the composed bin *is* `q(x_d)` — the bin an
 * absolute statement of that instant would carry. The declared error bound therefore holds
 * at any depth, and dequantization is the same arithmetic a keyframe uses (spec §11.7).
 *
 * Two read paths are provided because agreeing across them is most of what makes an
 * implementation trustworthy:
 *
 * - {@link decodeKeyframeDeltaStreamed} walks the file front to back, composing each chunk
 *   onto the last;
 * - {@link decodeKeyframeDeltaIndexed} reads the index and, for an instant, walks only that
 *   instant's chain.
 *
 * Either way the answer is a composed population per chunk, still in bins. Turning one into
 * gaussians at an instant is {@link reconstructKeyframeDelta}, which is where decoding ends
 * (design §5), and {@link keyframeDeltaChunkAt} is the seek in front of it.
 *
 * {@link keyframeDeltaStatesJson} is the statement other SDKs are diffed against, and it is
 * a sample of that same reconstruction — not a second one — with integers as strings so a
 * 64-bit value survives a double-backed JSON parser.
 */

import {
  checkWindowIndex,
  chunkStreamBytes,
  decompressChunkBlock,
  stepsFrom,
  windowTableOrDefault,
} from "./chunk.js";
import { DEFAULT_CODECS, type CodecRegistry } from "./codec.js";
import { Cursor } from "./cursor.js";
import { MalformedFile } from "./errors.js";
import { ATTRIBUTE_CHANNELS, Attribute, GAUSSIAN_FLAG_NEVER_FADES } from "./opcodes.js";
import {
  clamp,
  dequantizeRotation,
  lifeClass,
  motionStep,
  muStep,
  rctInverse,
  supportK,
} from "./quantization.js";
import {
  DELTA_MODE_CHAINED,
  MAGIC,
  type ChunkIndexEntry,
  type DeltaChunkHeader,
  type Header,
  type ParsedDeltaChunk,
  type Quantization,
  checkMagic,
  frameDeltaGroups,
  iterateRecords,
  parseChunk,
  parseChunkIndexEntry,
  parseDeltaChunk,
  parseFooter,
  parseHeader,
  parseQuantization,
  parseShBandRecord,
  parseWindowTable,
  readRecord,
} from "./records.js";
import { Opcode } from "./opcodes.js";
import { coefficientsInBand, mergeBands, type ShCoefficients } from "./sh.js";
import { decodeStream, frameOneStream, frameStreams, type RawStream } from "./streams.js";

/**
 * Composed bins are signed 32-bit. Not a limit anyone meets — at a millimetre grid it
 * spans about 2,000 km — but stated so two decoders in two languages agree on where the
 * boundary is rather than one finding it on a 64-bit accumulator and the other on a 32-bit
 * one. Overflow is refused, never wrapped: a wrapped position bin is a gaussian at a
 * plausible-looking wrong place, which is the failure the bounds contract exists to make
 * impossible.
 */
export const KEYFRAME_DELTA_BIN_MIN = -2147483648;
export const KEYFRAME_DELTA_BIN_MAX = 2147483647;

/**
 * Attributes a delta's update group MUST NOT carry. The per-gaussian grids for velocity
 * and birth time are derived from these three, so a bin difference across a change in any
 * of them is a difference between bins on two different grids — a number with no
 * interpretation (spec §11.5).
 */
const GOP_INVARIANT: ReadonlySet<number> = new Set([
  Attribute.SigmaT,
  Attribute.Flags,
  Attribute.WindowIndex,
]);

/**
 * Attributes an update restates outright rather than differencing. The smallest-three
 * rotation coding omits the largest-magnitude component, so the three stored bins mean
 * different components either side of a change; a rotating object crosses that boundary
 * constantly, so rotation is restated.
 */
const ABSOLUTE_IN_UPDATE: ReadonlySet<number> = new Set([
  Attribute.RotationIndex,
  Attribute.Rotation,
]);

/**
 * One attribute's bins for a whole population: `channels` per gaussian, packed
 * `values[i * channels + c]`.
 */
interface Column {
  readonly channels: number;
  readonly values: Int32Array;
}

function columnRows(column: Column): number {
  return column.channels === 0 ? 0 : column.values.length / column.channels;
}

/**
 * Read a composed state's bin columns. Assigned by {@link KeyframeDeltaState}'s static
 * block, which is the only way past a `#` field.
 *
 * Composed bins are not public API. A consumer reads reconstructed values through
 * {@link reconstructKeyframeDelta}, and this file — the one place that composes bins and
 * the one place that turns them into values — is the only holder of this reader. The
 * class used to publish a `column()` method marked `@internal`, which is a comment where
 * a language feature will do.
 */
let binsOf!: (state: KeyframeDeltaState) => Map<number, Column>;
let bandsOf!: (state: KeyframeDeltaState) => Map<number, Int32Array>;

/**
 * A composed population: identities, one bin column per attribute, and stored SH bands.
 *
 * `ids` and every column are aligned, and the order is an implementation detail — nothing
 * in the format depends on it and no reader may rely on it. The bins stay private: a
 * consumer reads reconstructed gaussians through {@link reconstructKeyframeDelta}, not raw
 * composed bins. SH stays private for the same reason and is exposed only with the fully
 * reconstructed state.
 */
export class KeyframeDeltaState {
  readonly #bins: Map<number, Column>;
  readonly #bands: Map<number, Int32Array>;

  static {
    binsOf = (state) => state.#bins;
    bandsOf = (state) => state.#bands;
  }

  constructor(
    readonly ids: Int32Array,
    bins: Map<number, Column>,
    bands: Map<number, Int32Array> = new Map(),
  ) {
    this.#bins = bins;
    this.#bands = bands;
  }

  get count(): number {
    return this.ids.length;
  }
}

/** The state a keyframe chunk states outright, with its identities checked. */
function keyframeState(ids: Int32Array, bins: Map<number, Column>): KeyframeDeltaState {
  checkUnique(ids, "a keyframe");
  for (const [attribute, column] of bins) {
    if (columnRows(column) !== ids.length) {
      throw new MalformedFile(
        `attribute ${attribute} carries ${columnRows(column)} rows, the keyframe declares ` +
          `${ids.length} gaussians`,
      );
    }
    checkChannels(attribute, column, "a keyframe");
  }
  return new KeyframeDeltaState(ids, bins);
}

/**
 * An attribute's interleaving width, against the one the registry gives it.
 *
 * The row count alone does not pin the shape: a `rotation` column declaring one channel
 * and `count` rows passes every count check and then feeds a reader that indexes
 * `values[i * 3 + c]`, which reads the next row's bin as this row's second component and
 * `undefined` past the end — a plausible-looking wrong quaternion, or a `NaN` one. The
 * check exists in `decodeChunkStreams` for the same reason; a composed state has to make
 * it too, because a delta group's columns never pass through that path.
 */
function checkChannels(attribute: number, column: Column, where: string): void {
  const channels = ATTRIBUTE_CHANNELS.get(attribute);
  if (channels !== undefined && column.channels !== channels) {
    throw new MalformedFile(
      `attribute ${attribute} in ${where} declares ${column.channels} channels, the format ` +
        `defines ${channels}`,
    );
  }
}

/**
 * Compose one delta onto the state it references.
 *
 * Deaths, then updates, then births. The order is normative because a chunk that both
 * kills and creates would otherwise be ambiguous — and an id may appear in only one of the
 * three groups, so the order decides nothing a file is allowed to depend on. It is fixed
 * anyway, because "nothing depends on it" is a claim a reader should not have to take on
 * trust from a file it did not write (spec §11.4).
 */
function applyDelta(
  state: KeyframeDeltaState,
  updateIds: Int32Array,
  updateBins: Map<number, Column>,
  birthIds: Int32Array,
  birthBins: Map<number, Column>,
  deathIds: Int32Array,
): KeyframeDeltaState {
  checkGroupsDisjoint(updateIds, birthIds, deathIds);
  checkUnique(updateIds, "an update group");
  checkUnique(birthIds, "a birth group");
  checkUnique(deathIds, "a death group");

  for (const attribute of updateBins.keys()) {
    if (GOP_INVARIANT.has(attribute)) {
      throw new MalformedFile(
        `an update carries attribute ${attribute}, which is fixed for a gaussian's lifetime ` +
          `within a group: the per-gaussian grids for velocity and birth time are derived ` +
          `from it, so a bin difference across a change in it has no defined meaning`,
      );
    }
  }

  // --- deaths -----------------------------------------------------------
  let ids = state.ids;
  let bins = new Map<number, Column>(binsOf(state));
  let bands = new Map<number, Int32Array>();

  if (deathIds.length > 0) {
    const live = new Set<number>(ids);
    for (const id of deathIds) {
      if (!live.has(id)) {
        throw new MalformedFile(
          `a delta kills gaussian id ${id}, which is not live at its reference`,
        );
      }
    }
    const dying = new Set<number>(deathIds);
    const keep: number[] = [];
    for (let i = 0; i < ids.length; i++) if (!dying.has(ids[i]!)) keep.push(i);
    ids = gatherIds(ids, keep);
    const kept = new Map<number, Column>();
    for (const [attribute, column] of bins) kept.set(attribute, selectRows(column, keep));
    bins = kept;
    for (const [band, values] of bandsOf(state)) {
      bands.set(band, selectBandRows(values, coefficientsInBand(band) * 3, keep));
    }
  } else {
    // Copied because updates mutate columns in place, and the reference must not change
    // under a sibling chunk that also composes onto it.
    const copied = new Map<number, Column>();
    for (const [attribute, column] of bins) {
      copied.set(attribute, { channels: column.channels, values: Int32Array.from(column.values) });
    }
    bins = copied;
    for (const [band, values] of bandsOf(state)) bands.set(band, Int32Array.from(values));
  }

  // --- updates ----------------------------------------------------------
  if (updateIds.length > 0) {
    const rowOf = new Map<number, number>();
    for (let i = 0; i < ids.length; i++) rowOf.set(ids[i]!, i);
    const rows: number[] = [];
    for (const id of updateIds) {
      const row = rowOf.get(id);
      if (row === undefined) {
        throw new MalformedFile(
          `a delta updates gaussian id ${id}, which is not live at its reference`,
        );
      }
      rows.push(row);
    }
    for (const [attribute, delta] of updateBins) {
      if (columnRows(delta) !== updateIds.length) {
        throw new MalformedFile(
          `attribute ${attribute} carries ${columnRows(delta)} rows, the update group ` +
            `declares ${updateIds.length}`,
        );
      }
      checkChannels(attribute, delta, "an update group");
      const target = bins.get(attribute);
      if (target === undefined) {
        throw new MalformedFile(
          `an update touches attribute ${attribute}, which the referenced state does not carry`,
        );
      }
      const ch = target.channels;
      const absolute = ABSOLUTE_IN_UPDATE.has(attribute);
      for (let r = 0; r < rows.length; r++) {
        const dst = rows[r]! * ch;
        const src = r * ch;
        for (let c = 0; c < ch; c++) {
          if (absolute) {
            target.values[dst + c] = delta.values[src + c]!;
          } else {
            const composed = target.values[dst + c]! + delta.values[src + c]!;
            if (composed < KEYFRAME_DELTA_BIN_MIN || composed > KEYFRAME_DELTA_BIN_MAX) {
              throw new MalformedFile(
                `composing attribute ${attribute} for gaussian id ${updateIds[r]} leaves the ` +
                  `signed 32-bit range a composed bin must stay inside`,
              );
            }
            target.values[dst + c] = composed;
          }
        }
      }
    }
  }

  // --- births -----------------------------------------------------------
  if (birthIds.length > 0) {
    const live = new Set<number>(ids);
    for (const id of birthIds) {
      if (live.has(id)) {
        throw new MalformedFile(
          `a delta creates gaussian id ${id}, which is already live; ids are unique within a ` +
            `state and are not reused after a death`,
        );
      }
    }
    const absent: number[] = [];
    for (const attribute of bins.keys()) if (!birthBins.has(attribute)) absent.push(attribute);
    if (absent.length > 0) {
      absent.sort((a, b) => a - b);
      throw new MalformedFile(
        `a birth group carries no value for attributes ${absent.join(", ")}; a birth is ` +
          `absolute state, not a delta`,
      );
    }
    for (const [attribute, column] of birthBins) {
      if (columnRows(column) !== birthIds.length) {
        throw new MalformedFile(
          `attribute ${attribute} carries ${columnRows(column)} rows, the birth group ` +
            `declares ${birthIds.length}`,
        );
      }
      checkChannels(attribute, column, "a birth group");
    }

    const attributes = new Set<number>([...bins.keys(), ...birthBins.keys()]);
    const grownIds = new Int32Array(ids.length + birthIds.length);
    grownIds.set(ids, 0);
    grownIds.set(birthIds, ids.length);
    const grown = new Map<number, Column>();
    for (const attribute of attributes) {
      const existing = bins.get(attribute);
      const added = birthBins.get(attribute)!;
      // A birth may introduce a column the referenced state does not carry: `object_id`
      // is optional per gaussian and per chunk, so a background keyframe legitimately
      // omits it and a later birth legitimately supplies membership. The rows already in
      // the state still need a value, and §6.6 says which one — a state that omits the
      // stream is read as though every gaussian in it carried `0`. Without the prefix the
      // merged column is `birth_count` rows long against `count` ids, so the birth's
      // membership lands on the first pre-existing gaussian and the birth itself reads
      // past the end: two gaussians in the wrong object, silently.
      const before = existing?.values ?? new Int32Array(ids.length * added.channels);
      const merged = new Int32Array(before.length + added.values.length);
      merged.set(before, 0);
      merged.set(added.values, before.length);
      grown.set(attribute, { channels: added.channels, values: merged });
    }
    ids = grownIds;
    bins = grown;
  }

  return new KeyframeDeltaState(ids, bins, bands);
}

function gatherIds(ids: Int32Array, rows: readonly number[]): Int32Array {
  const out = new Int32Array(rows.length);
  for (let i = 0; i < rows.length; i++) out[i] = ids[rows[i]!]!;
  return out;
}

function selectRows(column: Column, rows: readonly number[]): Column {
  const ch = column.channels;
  const out = new Int32Array(rows.length * ch);
  for (let r = 0; r < rows.length; r++) {
    const src = rows[r]! * ch;
    const dst = r * ch;
    for (let c = 0; c < ch; c++) out[dst + c] = column.values[src + c]!;
  }
  return { channels: ch, values: out };
}

function selectBandRows(values: Int32Array, channels: number, rows: readonly number[]): Int32Array {
  const out = new Int32Array(rows.length * channels);
  for (let r = 0; r < rows.length; r++) {
    const src = rows[r]! * channels;
    const dst = r * channels;
    out.set(values.subarray(src, src + channels), dst);
  }
  return out;
}

function checkUnique(ids: Int32Array, what: string): void {
  const seen = new Set<number>();
  for (const id of ids) {
    if (seen.has(id)) {
      throw new MalformedFile(`${what} names gaussian id ${id} more than once`);
    }
    seen.add(id);
  }
}

function checkGroupsDisjoint(a: Int32Array, b: Int32Array, d: Int32Array): void {
  const pair = (x: Int32Array, y: Int32Array, names: string): void => {
    const set = new Set<number>(x);
    for (const id of y) {
      if (set.has(id)) {
        throw new MalformedFile(
          `gaussian id ${id} is ${names} by the same delta; the outcome would depend on the ` +
            `order the groups are applied in`,
        );
      }
    }
  };
  pair(a, b, "updated and born");
  pair(a, d, "updated and killed");
  pair(b, d, "born and killed");
}

// --------------------------------------------------------------------------
// Group and chunk decoding — bins, never values
// --------------------------------------------------------------------------

/** Decode every Attribute Stream in a records block to bin columns, keyed by attribute. */
async function decodeStreams(
  blob: Uint8Array,
  codecs: CodecRegistry,
): Promise<Map<number, Column>> {
  const got = new Map<number, Column>();
  if (blob.length === 0) return got;
  const framed = frameStreams(new Cursor(blob));
  await Promise.all(
    framed.map(async (stream) => {
      const values = await decodeStream(stream, codecs);
      // One stream per attribute here too: the regular chunk path refuses a second,
      // and this path had its own loop that was still resolving it silently.
      if (got.has(stream.attributeId)) {
        throw new MalformedFile(
          `a keyframe-delta group carries attribute ${stream.attributeId} twice; the format ` +
            "defines one stream per attribute",
        );
      }
      got.set(stream.attributeId, { channels: stream.channels, values });
    }),
  );
  return got;
}

/**
 * One length-framed group: its ids and a bin column per other attribute.
 *
 * Deliberately generic — it keeps every stream, including the gaussian_id one, rather than
 * gating on the `gaussian-birth` registry the chunk decoder uses: an update group carries a
 * subset of the required attributes, a death group carries only the identity, and both must
 * decode.
 */
async function decodeGroup(
  blob: Uint8Array,
  codecs: CodecRegistry,
): Promise<{ ids: Int32Array; bins: Map<number, Column> }> {
  if (blob.length === 0) return { ids: new Int32Array(0), bins: new Map() };
  const streams = await decodeStreams(blob, codecs);
  const gaussianId = streams.get(Attribute.GaussianId);
  if (gaussianId === undefined) {
    throw new MalformedFile("a keyframe-delta group carries no gaussian_id stream");
  }
  streams.delete(Attribute.GaussianId);
  return { ids: idsOf(gaussianId), bins: streams };
}

/** Decode and frame one top-level SH Band Stream without losing its declared shape. */
async function decodeShBand(
  content: Uint8Array,
  codecs: CodecRegistry,
): Promise<{ band: number; stream: RawStream; values: Int32Array }> {
  const parsed = parseShBandRecord(content);
  const stream = frameOneStream(parsed.cursor);
  if (parsed.cursor.remaining !== 0) {
    throw new MalformedFile(
      `SH band ${parsed.band} has ${parsed.cursor.remaining} trailing bytes after its stream`,
    );
  }
  if (stream.attributeId !== Opcode.ShBandStream) {
    throw new MalformedFile(
      `SH band ${parsed.band} stream declares attribute id ${stream.attributeId}, the format ` +
        `defines ${Opcode.ShBandStream}`,
    );
  }
  return { band: parsed.band, stream, values: await decodeStream(stream, codecs) };
}

/**
 * Attach one chunk's band rows to the composed state.
 *
 * A keyframe band carries every keyframe row. A Delta Chunk band carries only its births;
 * existing rows inherit their coefficients from the referenced state, updates leave them
 * alone, and deaths have already selected the surviving rows in {@link applyDelta}.
 */
function attachShBand(
  state: KeyframeDeltaState,
  degree: number,
  band: number,
  stream: RawStream,
  values: Int32Array,
  addedRows: number,
  where: string,
  attachedBands: Set<number>,
): void {
  if (band < 1 || band > degree) {
    throw new MalformedFile(
      `${where} carries SH band ${band}, outside the Header's declared degree ${degree}`,
    );
  }
  const channels = coefficientsInBand(band) * 3;
  if (stream.channels !== channels) {
    throw new MalformedFile(
      `${where} SH band ${band} declares ${stream.channels} channels, degree ${band} defines ` +
        `${channels}`,
    );
  }
  if (stream.elementCount !== addedRows) {
    throw new MalformedFile(
      `${where} SH band ${band} carries ${stream.elementCount} rows, expected ${addedRows}`,
    );
  }
  for (let i = 0; i < values.length; i++) {
    const value = values[i]!;
    if (value < 0 || value > 255) {
      throw new MalformedFile(
        `${where} SH band ${band} coefficient ${i} is ${value}, outside the u8 range 0..255`,
      );
    }
  }

  if (attachedBands.has(band)) {
    throw new MalformedFile(`${where} carries SH band ${band} more than once`);
  }
  attachedBands.add(band);
  const bands = bandsOf(state);
  const priorRows = state.count - addedRows;
  if (priorRows < 0) {
    throw new MalformedFile(
      `${where} declares ${addedRows} SH birth rows for a ${state.count}-gaussian state`,
    );
  }
  const inherited = bands.get(band);
  if (priorRows > 0 && inherited === undefined) {
    throw new MalformedFile(
      `${where} cannot append SH band ${band}: its referenced state carries no such band`,
    );
  }
  if (inherited !== undefined && inherited.length !== priorRows * channels) {
    throw new MalformedFile(
      `${where} inherited SH band ${band} with ${inherited.length} values for ${priorRows} rows ` +
        `of ${channels} channels`,
    );
  }
  const merged = new Int32Array((priorRows + addedRows) * channels);
  if (inherited !== undefined) merged.set(inherited, 0);
  merged.set(values, priorRows * channels);
  bands.set(band, merged);
}

/** Every state carries exactly the contiguous band set its Header declares. */
function checkCompleteSh(state: KeyframeDeltaState, degree: number, where: string): void {
  const bands = bandsOf(state);
  if (degree === 0) {
    if (bands.size > 0) throw new MalformedFile(`${where} carries SH bands but sh_degree is 0`);
    return;
  }
  const present = [...bands.keys()].sort((a, b) => a - b);
  const expected = Array.from({ length: degree }, (_, i) => i + 1);
  if (present.length !== expected.length || present.some((band, i) => band !== expected[i])) {
    throw new MalformedFile(
      `${where} carries SH bands ${present.join(", ") || "none"}, the Header requires ` +
        `${expected.join(", ")}`,
    );
  }
  for (const band of expected) {
    const channels = coefficientsInBand(band) * 3;
    const length = bands.get(band)!.length;
    if (length !== state.count * channels) {
      throw new MalformedFile(
        `${where} SH band ${band} carries ${length} values, expected ${state.count} rows x ` +
          `${channels} channels`,
      );
    }
  }
}

/** A keyframe Chunk's ids and its full set of required bins. */
async function keyframeFromChunk(
  content: Uint8Array,
  codecs: CodecRegistry,
): Promise<{ ids: Int32Array; bins: Map<number, Column> }> {
  const parsed = parseChunk(content);
  // Undo any chunk-level compression before framing the streams, exactly as the
  // gaussian-birth chunk path does (§5.5); a compressed keyframe would otherwise decode
  // the codec's output as attribute-stream headers.
  const streamBytes = await chunkStreamBytes(parsed, codecs);
  const streams = await decodeStreams(streamBytes, codecs);
  const gaussianId = streams.get(Attribute.GaussianId);
  if (gaussianId === undefined) {
    if (parsed.header.count === 0) return { ids: new Int32Array(0), bins: streams };
    throw new MalformedFile("a keyframe-delta chunk carries no gaussian_id stream");
  }
  streams.delete(Attribute.GaussianId);
  if (parsed.header.count !== 0) {
    const missing = REQUIRED_KEYFRAME_ATTRIBUTES.filter((id) => !streams.has(id));
    if (missing.length > 0) {
      throw new MalformedFile(
        `keyframe chunk is missing required attributes ${missing.join(", ")}`,
      );
    }
  }
  return { ids: idsOf(gaussianId), bins: streams };
}

/** The eleven required attributes a keyframe chunk carries. */
const REQUIRED_KEYFRAME_ATTRIBUTES: readonly number[] = [
  Attribute.Position,
  Attribute.Scale,
  Attribute.RotationIndex,
  Attribute.Rotation,
  Attribute.Color,
  Attribute.Opacity,
  Attribute.Motion,
  Attribute.MuT,
  Attribute.SigmaT,
  Attribute.Flags,
  Attribute.WindowIndex,
];

function idsOf(gaussianId: Column): Int32Array {
  const n = columnRows(gaussianId);
  const ch = gaussianId.channels;
  const out = new Int32Array(n);
  for (let i = 0; i < n; i++) out[i] = gaussianId.values[i * ch]!;
  return out;
}

async function composeDelta(
  reference: KeyframeDeltaState,
  parsed: ParsedDeltaChunk,
  codecs: CodecRegistry,
): Promise<KeyframeDeltaState> {
  // Undo any chunk-level compression over the whole records block, then frame its three
  // sub-blocks (§5.18) — the same handling a keyframe Chunk gets.
  const block = await decompressChunkBlock(
    parsed.records,
    parsed.header.compression,
    parsed.header.uncompressedSize,
    codecs,
    `delta chunk at t0=${parsed.header.t0}`,
  );
  const groups = frameDeltaGroups(block);
  const updates = await decodeGroup(groups.updates, codecs);
  const births = await decodeGroup(groups.births, codecs);
  const deaths = await decodeGroup(groups.deaths, codecs);
  // EVERY stream in a group MUST carry exactly the count the header declares (§5.18/§11.9),
  // not just its gaussian_id, and a death group carries the identity stream alone. Checking
  // this before composition catches a declared-nonzero-but-empty group, a zero-count group
  // that smuggles attribute streams (which applyDelta would ignore), and a death group with
  // extra attributes (which would be silently discarded). The delta chunk is named by its
  // interval and reference so a file with many of them says which one is wrong.
  const where =
    `delta chunk over [${parsed.header.t0}, ${parsed.header.t1}) ` +
    `referencing offset ${parsed.header.referenceOffset}`;
  checkGroup(where, "update", updates, parsed.header.updateCount);
  checkGroup(where, "birth", births, parsed.header.birthCount);
  checkGroup(where, "death", deaths, parsed.header.deathCount, true);
  return applyDelta(reference, updates.ids, updates.bins, births.ids, births.bins, deaths.ids);
}

function checkGroup(
  where: string,
  group: string,
  decoded: { ids: Int32Array; bins: Map<number, Column> },
  declared: number,
  identityOnly = false,
): void {
  if (decoded.ids.length !== declared) {
    throw new MalformedFile(
      `the ${group} group of the ${where} carries ${decoded.ids.length} gaussian ids, but its ` +
        `header declares ${group}_count=${declared}`,
    );
  }
  if (identityOnly && decoded.bins.size > 0) {
    const extra = [...decoded.bins.keys()].sort((a, b) => a - b).join(", ");
    throw new MalformedFile(
      `the ${group} group of the ${where} carries attribute streams ${extra} beyond gaussian_id; ` +
        `a death group is the identity stream alone`,
    );
  }
  for (const [attribute, column] of decoded.bins) {
    if (columnRows(column) !== declared) {
      throw new MalformedFile(
        `attribute ${attribute} of the ${group} group of the ${where} carries ` +
          `${columnRows(column)} rows, but its header declares ${group}_count=${declared}`,
      );
    }
  }
}

/** Refuse a delta whose reference is at a different `level` (spec §11.6). */
function checkLevelMatch(
  referenceLevel: number,
  deltaLevel: number,
  offset: number,
  referenceOffset: number,
): void {
  if (referenceLevel !== deltaLevel) {
    throw new MalformedFile(
      `delta chunk at ${offset} is level ${deltaLevel}, but its reference at ${referenceOffset} ` +
        `is level ${referenceLevel}; a delta's reference must share its level`,
    );
  }
}

/**
 * Refuse a Delta Chunk whose header disagrees with the index entry that pointed at it
 * (spec §5.8, §11.9). The duplicated fields are what a seek is decided on, so a
 * disagreement means the chain and the record are two different intents.
 */
function checkIndexAgreesWithHeader(entry: ChunkIndexEntry, head: DeltaChunkHeader): void {
  const fields: readonly [string, number, number][] = [
    ["t0", entry.t0, head.t0],
    ["t1", entry.t1, head.t1],
    ["delta_mode", entry.deltaMode, head.deltaMode],
    ["reference_offset", entry.referenceOffset, head.referenceOffset],
    ["keyframe_offset", entry.keyframeOffset, head.keyframeOffset],
    ["depth", entry.depth, head.depth],
  ];
  for (const [name, indexValue, headerValue] of fields) {
    if (indexValue !== headerValue) {
      throw new MalformedFile(
        `the Chunk Index entry at offset ${entry.chunkOffset} says ${name}=${indexValue}, but the ` +
          `Delta Chunk it points at says ${name}=${headerValue}; the index and the record disagree`,
      );
    }
  }
}

// --------------------------------------------------------------------------
// The decoded sequence
// --------------------------------------------------------------------------

/** One decoded chunk and the composed population valid over `[t0, t1)`. */
export interface KeyframeDeltaChunkInfo {
  readonly t0: number;
  readonly t1: number;
  /** 0 keyframe, 1 delta. */
  readonly kind: number;
  /** `null` for a keyframe; the chunk's `delta_mode` otherwise. */
  readonly deltaMode: number | null;
  readonly depth: number;
  readonly offset: number;
  readonly referenceOffset: number;
  readonly updateCount: number | null;
  readonly birthCount: number | null;
  readonly deathCount: number | null;
  readonly state: KeyframeDeltaState;
}

/** A whole `keyframe-delta` file, decoded by either read path. */
export interface KeyframeDeltaSequence {
  readonly header: Header;
  readonly quantization: Quantization;
  /** Flattened `[lo, hi]` window pairs. */
  readonly windows: Float64Array;
  readonly chunks: readonly KeyframeDeltaChunkInfo[];
}

/** Front to back: decode each chunk and compose it onto the state it references. */
export async function decodeKeyframeDeltaStreamed(
  data: Uint8Array,
  codecs: CodecRegistry = DEFAULT_CODECS,
): Promise<KeyframeDeltaSequence> {
  checkMagic(data);
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  const chunks: KeyframeDeltaChunkInfo[] = [];
  // A chunk's composed state and its `level`; the level is kept so a delta can be refused
  // against a reference at a different level (spec §11.6).
  const byOffset = new Map<number, { state: KeyframeDeltaState; level: number }>();
  let currentChunk: KeyframeDeltaChunkInfo | null = null;
  let currentBands = new Set<number>();
  let sawFooter = false;

  const finishCurrentBands = (): void => {
    if (currentChunk === null || header === null) return;
    checkCompleteSh(
      currentChunk.state,
      header.shDegree,
      `state chunk at byte ${currentChunk.offset}`,
    );
  };

  for (const record of iterateRecords(data, MAGIC.length)) {
    if (record.opcode === Opcode.Header) {
      header = parseHeader(record.content);
      if (header.temporalModel !== "keyframe-delta") {
        throw new MalformedFile(
          `decodeKeyframeDeltaStreamed is the keyframe-delta path; this file is ` +
            `"${header.temporalModel}"`,
        );
      }
    } else if (record.opcode === Opcode.Quantization) {
      quantization = parseQuantization(record.content);
    } else if (record.opcode === Opcode.WindowTable) {
      windows = parseWindowTable(record.content);
    } else if (record.opcode === Opcode.Chunk) {
      finishCurrentBands();
      const parsed = parseChunk(record.content);
      const decoded = await keyframeFromChunk(record.content, codecs);
      const state = keyframeState(decoded.ids, decoded.bins);
      byOffset.set(record.offset, { state, level: parsed.header.level });
      currentChunk = {
        t0: parsed.header.t0,
        t1: parsed.header.t1,
        kind: 0,
        deltaMode: null,
        depth: 0,
        offset: record.offset,
        referenceOffset: 0,
        updateCount: null,
        birthCount: null,
        deathCount: null,
        state,
      };
      chunks.push(currentChunk);
      currentBands = new Set();
    } else if (record.opcode === Opcode.DeltaChunk) {
      finishCurrentBands();
      const parsed = parseDeltaChunk(record.content);
      const reference = byOffset.get(parsed.header.referenceOffset);
      if (reference === undefined) {
        throw new MalformedFile(
          `delta chunk at ${record.offset} references ${parsed.header.referenceOffset}, which ` +
            `has not been decoded (references point backwards only)`,
        );
      }
      if (parsed.header.referenceOffset >= record.offset) {
        throw new MalformedFile(
          `delta chunk at ${record.offset} references ${parsed.header.referenceOffset}, which ` +
            `is not behind it`,
        );
      }
      checkLevelMatch(
        reference.level,
        parsed.header.level,
        record.offset,
        parsed.header.referenceOffset,
      );
      const state = await composeDelta(reference.state, parsed, codecs);
      byOffset.set(record.offset, { state, level: parsed.header.level });
      currentChunk = {
        t0: parsed.header.t0,
        t1: parsed.header.t1,
        kind: 1,
        deltaMode: parsed.header.deltaMode,
        depth: parsed.header.depth,
        offset: record.offset,
        referenceOffset: parsed.header.referenceOffset,
        updateCount: parsed.header.updateCount,
        birthCount: parsed.header.birthCount,
        deathCount: parsed.header.deathCount,
        state,
      };
      chunks.push(currentChunk);
      currentBands = new Set();
    } else if (record.opcode === Opcode.ShBandStream) {
      if (currentChunk === null || header === null) {
        throw new MalformedFile(
          `an SH Band Stream appears at byte ${record.offset} before a state chunk or Header`,
        );
      }
      const decoded = await decodeShBand(record.content, codecs);
      const rows = currentChunk.kind === 0 ? currentChunk.state.count : currentChunk.birthCount!;
      attachShBand(
        currentChunk.state,
        header.shDegree,
        decoded.band,
        decoded.stream,
        decoded.values,
        rows,
        `state chunk at byte ${currentChunk.offset}`,
        currentBands,
      );
    } else if (record.opcode === Opcode.Footer) {
      sawFooter = true;
      finishCurrentBands();
    }
  }

  if (header === null || quantization === null) {
    throw new MalformedFile("keyframe-delta file has no Header or Quantization record");
  }
  try {
    finishCurrentBands();
  } catch (error) {
    // A stream may end between a state record and its declared band set. Those bytes do
    // not describe a lower-degree state; retain the longest preceding complete prefix.
    // Once a Footer was seen the file claimed completeness, so the same shape is malformed.
    if (sawFooter || currentChunk === null || !(error instanceof MalformedFile)) throw error;
    chunks.pop();
    byOffset.delete(currentChunk.offset);
  }
  // The timeline must tile [0, duration_sec) with no overlap or gap — checked here as well
  // as on the indexed path, so a hole is refused whichever way the file is read (§11.1).
  checkTiling(chunks, header.durationSec);
  return { header, quantization, windows, chunks };
}

/** The result of the indexed read path: the sequence and the index it walked. */
export interface KeyframeDeltaIndexedResult {
  readonly sequence: KeyframeDeltaSequence;
  readonly index: readonly ChunkIndexEntry[];
}

/**
 * Read the Footer, then the index, then compose each chunk by byte range.
 *
 * The composed state per chunk is produced by walking that chunk's chain (spec §11.8) — the
 * seeking client's path — and must reach the same population the streamed path reaches
 * front to back.
 */
export async function decodeKeyframeDeltaIndexed(
  data: Uint8Array,
  codecs: CodecRegistry = DEFAULT_CODECS,
): Promise<KeyframeDeltaIndexedResult> {
  checkMagic(data);
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  let summaryStart: number | null = null;
  for (const record of iterateRecords(data, MAGIC.length)) {
    if (record.opcode === Opcode.Header) {
      header = parseHeader(record.content);
    } else if (record.opcode === Opcode.Quantization) {
      quantization = parseQuantization(record.content);
    } else if (record.opcode === Opcode.WindowTable) {
      windows = parseWindowTable(record.content);
    } else if (record.opcode === Opcode.Footer) {
      summaryStart = parseFooter(record.content).summaryStart;
      break;
    }
  }
  if (summaryStart === null) throw new MalformedFile("file has no Footer");
  if (header === null || quantization === null) {
    throw new MalformedFile("keyframe-delta file has no Header or Quantization record");
  }

  const index: ChunkIndexEntry[] = [];
  for (const record of iterateRecords(data, summaryStart)) {
    if (record.opcode === Opcode.ChunkIndex) index.push(parseChunkIndexEntry(record.content));
    else break;
  }
  // The indexed path has read the Footer, so it is a complete file: require full timeline
  // coverage, not just adjacency (spec §11.1). The streamed path stays adjacency-only.
  checkTiling(index, header.durationSec, true);

  const chunks: KeyframeDeltaChunkInfo[] = [];
  for (const entry of index) {
    const state = await composeChain(data, index, entry, codecs, header.shDegree);
    let updateCount: number | null = null;
    let birthCount: number | null = null;
    let deathCount: number | null = null;
    if (entry.kind !== 0) {
      // The counts are not in the index — there `gaussianCount` is their sum — so a reader
      // that wants the split reads the delta chunk's own header. The chain walk already
      // fetched this record; parsing its header again is cheap.
      const head = parseDeltaChunk(
        recordContentAt(data, entry.chunkOffset, entry.chunkLength),
      ).header;
      // The index duplicates six of the header's fields (§5.8); refuse a disagreement,
      // because the chain was selected from the index while the composed record is the
      // header's, and a mismatch is plausible wrong state rather than an error (§11.9).
      checkIndexAgreesWithHeader(entry, head);
      updateCount = head.updateCount;
      birthCount = head.birthCount;
      deathCount = head.deathCount;
    }
    chunks.push({
      t0: entry.t0,
      t1: entry.t1,
      kind: entry.kind,
      deltaMode: entry.kind !== 0 ? entry.deltaMode : null,
      depth: entry.depth,
      offset: entry.chunkOffset,
      referenceOffset: entry.referenceOffset,
      updateCount,
      birthCount,
      deathCount,
      state,
    });
  }

  return { sequence: { header, quantization, windows, chunks }, index };
}

function recordContentAt(data: Uint8Array, offset: number, length: number): Uint8Array {
  const c = new Cursor(data.subarray(offset, offset + length));
  c.u8();
  return c.take(c.u64());
}

async function composeChain(
  data: Uint8Array,
  index: readonly ChunkIndexEntry[],
  entry: ChunkIndexEntry,
  codecs: CodecRegistry,
  shDegree: number,
): Promise<KeyframeDeltaState> {
  const chain = chainFor(index, (entry.t0 + entry.t1) / 2.0);
  let state: KeyframeDeltaState | null = null;
  // A GOP shares one `level`: the keyframe sets it and every delta's reference must match
  // it (spec §11.6), so along a chain every link carries the keyframe's level. The index
  // does not hold `level` — it is a chunk field — so the rule is enforced here.
  let keyframeLevel = 0;
  for (const link of chain) {
    const content = recordContentAt(data, link.chunkOffset, link.chunkLength);
    if (link.kind === 0) {
      const decoded = await keyframeFromChunk(content, codecs);
      state = keyframeState(decoded.ids, decoded.bins);
      keyframeLevel = parseChunk(content).header.level;
      await attachIndexedShBands(data, link, state, shDegree, state.count, codecs);
    } else {
      if (state === null) {
        throw new MalformedFile("a keyframe-delta chain begins with a delta chunk");
      }
      const parsed = parseDeltaChunk(content);
      // The reference this delta composes onto is its own `reference_offset` (the previous
      // link for a chained delta, the keyframe for a keyframe-referenced one); name that in
      // the diagnostic, not the GOP keyframe (§11.6).
      checkLevelMatch(
        keyframeLevel,
        parsed.header.level,
        link.chunkOffset,
        parsed.header.referenceOffset,
      );
      state = await composeDelta(state, parsed, codecs);
      await attachIndexedShBands(data, link, state, shDegree, parsed.header.birthCount, codecs);
    }
    checkCompleteSh(state, shDegree, `state chunk at byte ${link.chunkOffset}`);
  }
  if (state === null) throw new MalformedFile("an empty keyframe-delta chain");
  return state;
}

async function attachIndexedShBands(
  data: Uint8Array,
  entry: ChunkIndexEntry,
  state: KeyframeDeltaState,
  shDegree: number,
  addedRows: number,
  codecs: CodecRegistry,
): Promise<void> {
  const attached = new Set<number>();
  for (const range of entry.bands) {
    if (range.offset < 0 || range.length < 0 || range.offset + range.length > data.length) {
      throw new MalformedFile(
        `state chunk at byte ${entry.chunkOffset} indexes SH band ${range.band} at byte ` +
          `${range.offset} for ${range.length} bytes, outside the ${data.length}-byte file`,
      );
    }
    const record = readRecord(
      new Cursor(data.subarray(range.offset, range.offset + range.length), 0, range.offset),
    );
    if (record.opcode !== Opcode.ShBandStream) {
      throw new MalformedFile(
        `state chunk at byte ${entry.chunkOffset} indexes SH band ${range.band} at byte ` +
          `${range.offset}, which holds opcode ${record.opcode} rather than an SH Band Stream`,
      );
    }
    if (record.raw.length !== range.length) {
      throw new MalformedFile(
        `state chunk at byte ${entry.chunkOffset} indexes SH band ${range.band} with length ` +
          `${range.length}, its record occupies ${record.raw.length}`,
      );
    }
    const decoded = await decodeShBand(record.content, codecs);
    if (decoded.band !== range.band) {
      throw new MalformedFile(
        `state chunk at byte ${entry.chunkOffset} indexes SH band ${range.band}, the record ` +
          `at byte ${range.offset} says band ${decoded.band}`,
      );
    }
    attachShBand(
      state,
      shDegree,
      decoded.band,
      decoded.stream,
      decoded.values,
      addedRows,
      `state chunk at byte ${entry.chunkOffset}`,
      attached,
    );
  }
}

/** The half-open interval a state chunk is valid over; enough to check tiling. */
export interface Interval {
  readonly t0: number;
  readonly t1: number;
}

/**
 * State chunks tile the timeline: sorted by `t0`, each chunk's `t1` is the next chunk's
 * `t0` — no overlap, no gap (spec §11.1). This is what makes the seek predicate a lookup
 * rather than a search, and it is checked on both read paths so a hole is refused whichever
 * way the file is read.
 *
 * The two read paths have different completeness contracts. A **streamed** reader may hold
 * only a complete prefix of a truncated file, so it checks adjacency alone and does NOT
 * require the last chunk to reach `duration_sec` — the last decodable instant is simply the
 * last complete chunk's `t1` (spec §11.10). An **indexed** reader has already found the
 * Footer, so it is looking at a whole file, and there `requireFullCoverage` additionally
 * requires the first `t0` to be `0` and the last `t1` to be `duration_sec`, so a complete
 * file with a hole in its declared timeline is refused. `durationSec` is also what rejects
 * the degenerate case of a file that declares a duration but carries no state chunks, which
 * would otherwise reconstruct from an undefined covering chunk.
 */
export function checkTiling(
  intervals: readonly Interval[],
  durationSec?: number,
  requireFullCoverage = false,
): void {
  const ordered = [...intervals].sort((a, b) => a.t0 - b.t0);
  for (let i = 1; i < ordered.length; i++) {
    const previous = ordered[i - 1]!;
    const entry = ordered[i]!;
    if (previous.t1 !== entry.t0) {
      const what = entry.t0 < previous.t1 ? "overlap" : "leave a gap";
      throw new MalformedFile(
        `state chunks ${what}: [${previous.t0}, ${previous.t1}) is followed by ` +
          `[${entry.t0}, ${entry.t1})`,
      );
    }
  }
  if (durationSec !== undefined && ordered.length === 0) {
    throw new MalformedFile(
      `a keyframe-delta file declares duration_sec ${durationSec} but carries no state chunks`,
    );
  }
  if (requireFullCoverage && durationSec !== undefined && ordered.length > 0) {
    const first = ordered[0]!;
    const last = ordered[ordered.length - 1]!;
    if (first.t0 !== 0) {
      throw new MalformedFile(
        `the first state chunk starts at ${first.t0}, not 0; a complete file's timeline must ` +
          `cover [0, duration_sec)`,
      );
    }
    if (last.t1 !== durationSec) {
      throw new MalformedFile(
        `the last state chunk ends at ${last.t1}, not the Header's duration_sec ${durationSec}; ` +
          `a complete file's timeline must cover [0, duration_sec)`,
      );
    }
  }
}

/**
 * The keyframe and deltas a reader must read to reconstruct instant `t`.
 *
 * Answered from the index alone — no chunk is fetched to learn what another references —
 * and returned oldest first, the order {@link applyDelta} composes in (spec §11.8).
 */
export function chainFor(index: readonly ChunkIndexEntry[], t: number): ChunkIndexEntry[] {
  const byOffset = new Map<number, ChunkIndexEntry>();
  for (const entry of index) byOffset.set(entry.chunkOffset, entry);
  let current: ChunkIndexEntry | undefined;
  for (const entry of index) {
    if (entry.t0 <= t && t < entry.t1) {
      current = entry;
      break;
    }
  }
  if (current === undefined) throw new MalformedFile(`no state chunk covers t=${t}`);

  const chain: ChunkIndexEntry[] = [current];
  while (chain[0]!.kind !== 0) {
    const head = chain[0]!;
    if (head.referenceOffset >= head.chunkOffset) {
      throw new MalformedFile(
        `the chunk at ${head.chunkOffset} references ${head.referenceOffset}, which is not ` +
          `behind it; references point backwards only`,
      );
    }
    const reference = byOffset.get(head.referenceOffset);
    if (reference === undefined) {
      throw new MalformedFile(
        `the chunk at ${head.chunkOffset} references ${head.referenceOffset}, which the index ` +
          `does not name`,
      );
    }
    chain.unshift(reference);
    if (chain.length > index.length) {
      throw new MalformedFile("the chain does not reach a keyframe");
    }
  }

  if (chain.length - 1 !== current.depth) {
    throw new MalformedFile(
      `the chunk at ${current.chunkOffset} declares depth ${current.depth}, but its chain walks ` +
        `${chain.length - 1} delta chunks; the index and the file disagree about the cost of ` +
        `this seek`,
    );
  }
  return chain;
}

// --------------------------------------------------------------------------
// Reconstruction and the canonical summary
// --------------------------------------------------------------------------

/**
 * A composed population reconstructed at an instant: values, not bins.
 *
 * Rows are in ascending `gaussian_id` order. That is decoded-value order — not stream
 * order, which is an encoder's choice no reader may rely on — and it is unique within a
 * state (spec §11.2), so two implementations that compose the same population agree row
 * for row. Every array is parallel to `ids` and holds `count` rows.
 *
 * Gaussians outside their own validity window are absent rather than transparent: outside
 * it a gaussian does not exist at that time (spec §3), which is how the `gaussian-birth`
 * path decides it too, so `count`, `ids` and every array exclude them.
 *
 * The value arrays are `Float64Array` because this is also what the cross-SDK statement is
 * computed from, and that statement is diffed at six decimal places on sums over the whole
 * population — an accumulation in `float32` disagrees there.
 */
export interface KeyframeDeltaGaussians {
  /** The instant this was reconstructed at, in seconds. */
  readonly t: number;
  /** Gaussians alive at `t`; the row count of every array below. */
  readonly count: number;
  /** `count` gaussian ids, ascending. */
  readonly ids: Int32Array;
  /** `count × 3` centres: rest position carried along the linear velocity to `t`. */
  readonly centers: Float64Array;
  /** `count × 3` linear scale. */
  readonly scales: Float64Array;
  /** `count × 4` unit quaternion, xyzw. */
  readonly rotations: Float64Array;
  /** `count × 3` linear RGB, each in [0, 1]. */
  readonly rgb: Float64Array;
  /** `count` opacity in [0, 1], already folded with the temporal marginal at `t`. */
  readonly opacity: Float64Array;
  /** Stored spherical-harmonic coefficients in component-major order, or `null` at degree 0. */
  readonly sh: ShCoefficients | null;
  /**
   * `count` object ids (spec §6.6), or `null` when the composed state carries no
   * membership stream. `0` is background.
   */
  readonly objectId: Uint32Array | null;
}

/**
 * The state chunk covering scene time `t` — the seek, answered from the decoded timeline.
 *
 * The chunks tile `[0, duration_sec)` with half-open intervals, so exactly one covers any
 * `t` inside the timeline and finding it is a lookup rather than a search. A `t` at or past
 * the end of a **complete** timeline resolves to the last chunk: a reader asking for the
 * final instant of a file gets its final state rather than a refusal for landing on the
 * boundary of a half-open interval.
 *
 * That convenience stops where the timeline does. A streamed reader may hold only a
 * complete prefix of a truncated file (§11.10), and there the last decodable instant is the
 * last complete chunk's `t1`, not the Header's `duration_sec` — the same rule the canonical
 * probes are bounded by. Handing back the last chunk for a `t` in the missing tail would
 * report the state before the cut as the state after it, which is a decoder inventing
 * content: the bytes that said what happens at that instant are the bytes that are gone.
 * The indexed path already refuses it (`chainFor`), and now both do.
 */
export function keyframeDeltaChunkAt(
  sequence: KeyframeDeltaSequence,
  t: number,
): KeyframeDeltaChunkInfo {
  const chunks = sequence.chunks;
  if (chunks.length === 0) {
    throw new MalformedFile(`no state chunk covers t=${t}; the file carries none`);
  }
  for (const c of chunks) if (c.t0 <= t && t < c.t1) return c;
  const last = chunks[chunks.length - 1]!;
  if (!Number.isFinite(t) || t < last.t1) {
    throw new MalformedFile(`no state chunk covers t=${t}`);
  }
  if (t >= last.t1 && last.t1 < sequence.header.durationSec) {
    throw new MalformedFile(
      `no decoded state chunk covers t=${t}: this timeline ends at ${last.t1}, short of the ` +
        `Header's duration_sec ${sequence.header.durationSec}, so the file was cut before the ` +
        `chunk that would have said`,
    );
  }
  return last;
}

/**
 * The population `chunk` carries, reconstructed at scene time `t`.
 *
 * This is where decoding ends (design §5): composition is over quantization bins, and a
 * composed bin *is* the bin an absolute statement of that instant would carry, so
 * dequantizing here is the same arithmetic a keyframe chunk uses (spec §11.7). `chunk` is
 * the one whose half-open `[t0, t1)` contains `t` — {@link keyframeDeltaChunkAt} finds it,
 * and a player that has already seeked passes the chunk it seeked to rather than looking it
 * up again on every frame.
 */
export function reconstructKeyframeDelta(
  sequence: KeyframeDeltaSequence,
  chunk: KeyframeDeltaChunkInfo,
  t: number,
): KeyframeDeltaGaussians {
  const state = chunk.state;
  const n = state.count;
  const ids = new Int32Array(n);
  const centers = new Float64Array(n * 3);
  const scales = new Float64Array(n * 3);
  const rotations = new Float64Array(n * 4);
  const rgb = new Float64Array(n * 3);
  const opacity = new Float64Array(n);
  checkCompleteSh(state, sequence.header.shDegree, `state chunk at byte ${chunk.offset}`);
  const composedSh =
    sequence.header.shDegree === 0 ? null : mergeBands(n, bandsOf(state), sequence.header.shDegree);
  if (composedSh !== null && composedSh.degree !== sequence.header.shDegree) {
    throw new MalformedFile(
      `state chunk at byte ${chunk.offset} reconstructs SH degree ${composedSh.degree}, the ` +
        `Header declares ${sequence.header.shDegree}`,
    );
  }
  const shStride = composedSh === null ? 0 : composedSh.coefficients * 3;
  const shValues = new Uint8Array(n * shStride);
  const bins = binsOf(state);
  const objectIdColumn = bins.get(Attribute.ObjectId);
  if (objectIdColumn !== undefined && objectIdColumn.channels !== 1) {
    throw new MalformedFile(
      `the object_id column of the keyframe-delta chunk at byte ${chunk.offset} declares ` +
        `${objectIdColumn.channels} channels, the format defines 1`,
    );
  }
  const objectId = objectIdColumn === undefined ? null : new Uint32Array(n);
  if (n === 0) {
    const sh =
      composedSh === null
        ? null
        : { ...composedSh, count: 0, values: shValues, bands: composedSh.bands };
    return { t, count: 0, ids, centers, scales, rotations, rgb, opacity, sh, objectId };
  }

  // A composed state that has lost a required column is refused by name rather than read
  // as zeroes: a gaussian with no colour column is not a black gaussian, it is a file this
  // reader cannot turn into gaussians. Reported before the loop so the answer is every
  // attribute that is missing, not the first one reached.
  const absent = REQUIRED_KEYFRAME_ATTRIBUTES.filter((id) => !bins.has(id));
  if (absent.length > 0) {
    throw new MalformedFile(
      `the population composed at the keyframe-delta chunk at byte ${chunk.offset} carries no ` +
        `attribute ${absent.join(", ")} column, which every keyframe-delta state must have`,
    );
  }
  const position = bins.get(Attribute.Position)!.values;
  const scaleBins = bins.get(Attribute.Scale)!.values;
  const rotationIndex = bins.get(Attribute.RotationIndex)!.values;
  const rotationBins = bins.get(Attribute.Rotation)!.values;
  const colorBins = bins.get(Attribute.Color)!.values;
  const opacityBins = bins.get(Attribute.Opacity)!.values;
  const motion = bins.get(Attribute.Motion)!.values;
  const muBins = bins.get(Attribute.MuT)!.values;
  const sigmaBinsCol = bins.get(Attribute.SigmaT)!.values;
  const flags = bins.get(Attribute.Flags)!.values;
  const windowBins = bins.get(Attribute.WindowIndex)!.values;
  const objectIdBins = objectIdColumn?.values;

  const steps = stepsFrom(sequence.quantization);
  const origin = sequence.quantization.posOrigin;
  const windows = windowTableOrDefault(sequence.windows);
  const windowCount = windows.length >>> 1;
  const k = supportK(sequence.header.cutoff);

  const order = Array.from({ length: n }, (_, i) => i).sort(
    (a, b) => state.ids[a]! - state.ids[b]!,
  );

  let out = 0;
  for (const i of order) {
    // A never-fading gaussian's velocity grid is derived from the length of its own
    // validity window (spec §6.3), so the pitch is selected per gaussian from its
    // window_index rather than from a single shared window; an out-of-range index is
    // refused, not clamped, and refused for every row whether or not this instant keeps it.
    const windowIndex = checkWindowIndex(
      windowBins[i]!,
      windowCount,
      `keyframe-delta chunk at byte ${chunk.offset}, gaussian id ${state.ids[i]!}`,
    );
    const winLo = windows[windowIndex * 2]!;
    const winHi = windows[windowIndex * 2 + 1]!;
    if (!(winLo <= t && t < winHi)) continue;

    const sigmaBin = sigmaBinsCol[i]!;
    const neverFades = (flags[i]! & GAUSSIAN_FLAG_NEVER_FADES) !== 0;
    const sigma = neverFades ? Infinity : Math.exp(sigmaBin * steps.sigmaLog);
    const mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, winHi - winLo, k),
      steps.motion,
    );
    const mu = muBins[i]! * muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    const dt = t - mu;

    ids[out] = state.ids[i]!;
    const o3 = out * 3;
    const i3 = i * 3;
    for (let c = 0; c < 3; c++) {
      const pos = position[i3 + c]! * steps.pos + origin[c]!;
      centers[o3 + c] = pos + motion[i3 + c]! * mStep * dt;
      scales[o3 + c] = Math.exp(scaleBins[i3 + c]! * steps.scaleLog);
    }

    dequantizeRotation(
      rotationIndex[i]!,
      rotationBins[i3]!,
      rotationBins[i3 + 1]!,
      rotationBins[i3 + 2]!,
      steps.rot,
      rotations,
      out * 4,
    );

    const [r, g, b] = rctInverse(colorBins[i3]!, colorBins[i3 + 1]!, colorBins[i3 + 2]!);
    rgb[o3] = clamp(r * steps.rgb, 0, 1);
    rgb[o3 + 1] = clamp(g * steps.rgb, 0, 1);
    rgb[o3 + 2] = clamp(b * steps.rgb, 0, 1);

    const alpha = clamp(opacityBins[i]! * steps.alpha, 0, 1);
    const marginal = sigma === Infinity ? 1 : Math.exp(-0.5 * (dt / sigma) * (dt / sigma));
    opacity[out] = alpha * marginal;
    if (composedSh !== null) {
      shValues.set(composedSh.values.subarray(i * shStride, (i + 1) * shStride), out * shStride);
    }
    if (objectId !== null) objectId[out] = objectIdBins![i]!;
    out++;
  }

  // Views, not copies: nothing was dropped in the ordinary case, and where a window has
  // closed the tail is simply not part of the answer.
  return {
    t,
    count: out,
    ids: ids.subarray(0, out),
    centers: centers.subarray(0, out * 3),
    scales: scales.subarray(0, out * 3),
    rotations: rotations.subarray(0, out * 4),
    rgb: rgb.subarray(0, out * 3),
    opacity: opacity.subarray(0, out),
    sh:
      composedSh === null
        ? null
        : {
            degree: composedSh.degree,
            coefficients: composedSh.coefficients,
            count: out,
            values: shValues.subarray(0, out * shStride),
            bands: composedSh.bands,
          },
    objectId: objectId === null ? null : objectId.subarray(0, out),
  };
}

/** Decimals a float is rounded to before comparison, matching `tests/conformance/canonical.py`. */
const FLOAT_DECIMALS = 6;

/** How many gaussians appear in full in a probe's sample. */
const SAMPLE = 16;

/** Decimal places that expand a near-tie exactly. See {@link roundHalfEven}. */
const EXACT_DECIMALS = 100;

/**
 * Round to `decimals` places, halves to even, on the exact value — the rule Python's
 * `round` uses and the one `tests/conformance/canonical.py` is diffed under. `toFixed`
 * rounds halves away from zero, so it cannot be used on its own: the two disagree on values
 * like `0.0078125`, and every value a decoder produces is a float32, whose exact ties are
 * precisely those numbers.
 */
function roundHalfEven(value: number, decimals: number): number {
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
    roundUp = /[1-9]/.test(remainder) ? true : (kept.charCodeAt(keep - 1) - 48) % 2 === 1;
  }

  const scaled = BigInt(kept) + (roundUp ? 1n : 0n);
  const out = Number(scaled) / 10 ** decimals;
  return negative ? -out : out;
}

/** Round for comparison; a non-finite value becomes `null`, which is all JSON can say. */
function num(value: number | null): number | null {
  if (value === null || !Number.isFinite(value)) return null;
  return roundHalfEven(value, FLOAT_DECIMALS);
}

/**
 * Every chunk's `t0` and interval midpoint, plus one instant just below the end. Derived
 * from the file rather than hardcoded, so "seek to every chunk" is the expectation rather
 * than a separate test (design §11.2).
 */
function probeTimes(chunks: readonly KeyframeDeltaChunkInfo[], durationSec: number): number[] {
  const times = new Set<number>();
  for (const c of chunks) {
    times.add(roundHalfEven(c.t0, 9));
    times.add(roundHalfEven((c.t0 + c.t1) / 2.0, 9));
  }
  times.add(roundHalfEven(Math.max(0, durationSec - 1e-6), 9));
  return [...times].sort((a, b) => a - b);
}

/**
 * The statement two implementations are diffed on for a `keyframe-delta` file.
 *
 * `chunks` proves a decoder read `depth`, `deltaMode` and `liveCount` — a field no row
 * mentions is one an implementation can decline to decode. `states` is the reconstruction
 * at an instant: for each probe, the composed population's live count, a sample of centres
 * and scales in id order, and the aggregate over the whole population. Integers are strings
 * so a 64-bit value survives a double-backed JSON parser.
 */
export function keyframeDeltaStatesJson(sequence: KeyframeDeltaSequence): Record<string, unknown> {
  const duration = sequence.header.durationSec;

  const chunkRows = sequence.chunks.map((c) => ({
    t0: num(c.t0),
    t1: num(c.t1),
    kind: c.kind === 0 ? "keyframe" : "delta",
    deltaMode: c.kind === 0 ? null : c.deltaMode === DELTA_MODE_CHAINED ? "chained" : "keyframe",
    depth: String(c.depth),
    liveCount: String(c.state.count),
    updateCount: c.updateCount === null ? null : String(c.updateCount),
    birthCount: c.birthCount === null ? null : String(c.birthCount),
    deathCount: c.deathCount === null ? null : String(c.deathCount),
  }));

  // Probes are bounded by the last decodable instant — the last complete chunk's `t1`, not
  // the Header's duration. For a complete file they are equal (the timeline tiles to
  // duration), so this changes nothing there; for a streamed prefix it stops the near-end
  // probe from falling past the last chunk and extrapolating stale state (spec §11.10).
  let probeEnd = duration;
  if (sequence.chunks.length > 0) {
    probeEnd = sequence.chunks[0]!.t1;
    for (let i = 1; i < sequence.chunks.length; i++) {
      probeEnd = Math.max(probeEnd, sequence.chunks[i]!.t1);
    }
  }
  const states = probeTimes(sequence.chunks, probeEnd).map((t) => stateRow(sequence, t));

  return {
    temporalModel: "keyframe-delta",
    gaussianCount: String(sequence.header.gaussianCount),
    durationSec: num(duration),
    cutoff: num(sequence.header.cutoff),
    chunks: chunkRows,
    states,
  };
}

function stateRow(sequence: KeyframeDeltaSequence, t: number): Record<string, unknown> {
  const r = reconstructKeyframeDelta(sequence, keyframeDeltaChunkAt(sequence, t), t);
  const sampleN = Math.min(SAMPLE, r.count);
  const positionSum = [0, 0, 0];
  let opacitySum = 0;
  for (let i = 0; i < r.count; i++) {
    positionSum[0]! += r.centers[i * 3]!;
    positionSum[1]! += r.centers[i * 3 + 1]!;
    positionSum[2]! += r.centers[i * 3 + 2]!;
    opacitySum += r.opacity[i]!;
  }
  const positions: (number | null)[][] = [];
  const scales: (number | null)[][] = [];
  const gaussianIds: string[] = [];
  for (let i = 0; i < sampleN; i++) {
    gaussianIds.push(String(r.ids[i]));
    positions.push([
      num(r.centers[i * 3]!),
      num(r.centers[i * 3 + 1]!),
      num(r.centers[i * 3 + 2]!),
    ]);
    scales.push([num(r.scales[i * 3]!), num(r.scales[i * 3 + 1]!), num(r.scales[i * 3 + 2]!)]);
  }
  return {
    t: num(t),
    // The count at this instant, from the rows reconstruction actually returned — not the
    // chunk's population, which differs once a validity window has closed. Reporting the
    // population here would claim gaussians are live that the same row omits from `sample`.
    liveCount: String(r.count),
    sample: {
      gaussianIds,
      positions,
      scales: r.count === 0 ? [] : scales,
    },
    aggregate: {
      positionSum: positionSum.map((v) => num(v)),
      opacitySum: num(opacitySum),
    },
  };
}
