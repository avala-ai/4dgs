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
 * {@link keyframeDeltaStatesJson} is the statement other SDKs are diffed against: the
 * composed population reconstructed at an instant, in `gaussian_id` order, with integers as
 * strings so a 64-bit value survives a double-backed JSON parser.
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
import { Attribute, GAUSSIAN_FLAG_NEVER_FADES } from "./opcodes.js";
import { clamp, lifeClass, motionStep, muStep, supportK, type Steps } from "./quantization.js";
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
  parseWindowTable,
} from "./records.js";
import { Opcode } from "./opcodes.js";
import { decodeStream, frameStreams } from "./streams.js";

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
 * A composed population: identities, and one bin column per attribute.
 *
 * `ids` and every column are aligned, and the order is an implementation detail — nothing
 * in the format depends on it and no reader may rely on it. The bins stay private: a
 * consumer reads reconstructed gaussians through {@link keyframeDeltaStatesJson}, not raw
 * composed bins.
 */
export class KeyframeDeltaState {
  constructor(
    readonly ids: Int32Array,
    private readonly bins: Map<number, Column>,
  ) {}

  get count(): number {
    return this.ids.length;
  }

  /** @internal a bin column, for reconstruction. */
  column(attribute: number): Column | undefined {
    return this.bins.get(attribute);
  }

  /** @internal every attribute the state carries. */
  attributes(): IterableIterator<number> {
    return this.bins.keys();
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
  }
  return new KeyframeDeltaState(ids, bins);
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
  let bins = new Map<number, Column>();
  for (const attribute of state.attributes()) bins.set(attribute, state.column(attribute)!);

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
  } else {
    // Copied because updates mutate columns in place, and the reference must not change
    // under a sibling chunk that also composes onto it.
    const copied = new Map<number, Column>();
    for (const [attribute, column] of bins) {
      copied.set(attribute, { channels: column.channels, values: Int32Array.from(column.values) });
    }
    bins = copied;
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
    }

    const attributes = new Set<number>([...bins.keys(), ...birthBins.keys()]);
    const grownIds = new Int32Array(ids.length + birthIds.length);
    grownIds.set(ids, 0);
    grownIds.set(birthIds, ids.length);
    const grown = new Map<number, Column>();
    for (const attribute of attributes) {
      const existing = bins.get(attribute);
      const added = birthBins.get(attribute)!;
      const before = existing?.values ?? new Int32Array(0);
      const merged = new Int32Array(before.length + added.values.length);
      merged.set(before, 0);
      merged.set(added.values, before.length);
      grown.set(attribute, { channels: added.channels, values: merged });
    }
    ids = grownIds;
    bins = grown;
  }

  return new KeyframeDeltaState(ids, bins);
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
  // Each group's gaussian_id stream MUST carry exactly the count the header declares
  // (§5.18/§11.9), so a declared-nonzero-but-empty group is a refusal rather than a
  // silent zero and a streamed reader can size its working set before decompressing.
  checkGroupCount("update", updates.ids.length, parsed.header.updateCount);
  checkGroupCount("birth", births.ids.length, parsed.header.birthCount);
  checkGroupCount("death", deaths.ids.length, parsed.header.deathCount);
  return applyDelta(reference, updates.ids, updates.bins, births.ids, births.bins, deaths.ids);
}

function checkGroupCount(group: string, actual: number, declared: number): void {
  if (actual !== declared) {
    throw new MalformedFile(
      `the ${group} group carries ${actual} gaussian ids, but the Delta Chunk header declares ` +
        `${group}_count=${declared}`,
    );
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
      const parsed = parseChunk(record.content);
      const decoded = await keyframeFromChunk(record.content, codecs);
      const state = keyframeState(decoded.ids, decoded.bins);
      byOffset.set(record.offset, { state, level: parsed.header.level });
      chunks.push({
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
      });
    } else if (record.opcode === Opcode.DeltaChunk) {
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
      chunks.push({
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
      });
    }
  }

  if (header === null || quantization === null) {
    throw new MalformedFile("keyframe-delta file has no Header or Quantization record");
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
  checkTiling(index, header.durationSec);

  const chunks: KeyframeDeltaChunkInfo[] = [];
  for (const entry of index) {
    const state = await composeChain(data, index, entry, codecs);
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
    } else {
      if (state === null) {
        throw new MalformedFile("a keyframe-delta chain begins with a delta chunk");
      }
      const parsed = parseDeltaChunk(content);
      checkLevelMatch(keyframeLevel, parsed.header.level, link.chunkOffset, entry.keyframeOffset);
      state = await composeDelta(state, parsed, codecs);
    }
  }
  if (state === null) throw new MalformedFile("an empty keyframe-delta chain");
  return state;
}

/** The half-open interval a state chunk is valid over; enough to check tiling. */
export interface Interval {
  readonly t0: number;
  readonly t1: number;
}

/**
 * State chunks tile the timeline: no overlap, no gap, and — when `durationSec` is given —
 * the first `t0` is `0` and the last `t1` is `duration_sec` (spec §11.1). This is what
 * makes the seek predicate a lookup rather than a search, and it is checked on both read
 * paths so a hole is refused whichever way the file is read.
 */
export function checkTiling(intervals: readonly Interval[], durationSec?: number): void {
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
  if (durationSec !== undefined && ordered.length > 0) {
    const first = ordered[0]!;
    const last = ordered[ordered.length - 1]!;
    if (first.t0 !== 0) {
      throw new MalformedFile(
        `the first state chunk starts at ${first.t0}, not 0; the timeline must cover ` +
          `[0, duration_sec)`,
      );
    }
    if (last.t1 !== durationSec) {
      throw new MalformedFile(
        `the last state chunk ends at ${last.t1}, not the Header's duration_sec ${durationSec}`,
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

interface Grids {
  readonly steps: Steps;
  readonly origin: readonly number[];
  /**
   * The whole Window Table as flattened `[lo, hi]` pairs. A never-fading gaussian's
   * velocity precision is derived from its own `window_index`'s length (spec §6.3), so the
   * full table is kept and indexed per gaussian rather than collapsed to one window.
   */
  readonly windows: Float64Array;
  readonly cutoff: number;
}

function gridsFor(sequence: KeyframeDeltaSequence): Grids {
  return {
    steps: stepsFrom(sequence.quantization),
    origin: sequence.quantization.posOrigin,
    windows: windowTableOrDefault(sequence.windows),
    cutoff: sequence.header.cutoff,
  };
}

interface Reconstruction {
  readonly ids: Int32Array; // sorted ascending
  readonly centers: Float64Array; // count * 3
  readonly scales: Float64Array; // count * 3
  readonly opacity: Float64Array; // count
  readonly count: number;
}

/**
 * The composed population reconstructed at instant `t`, in `gaussian_id` order.
 *
 * Everything downstream orders by `gaussian_id`, which is unique within a state (spec
 * §11.2). That is decoded-value order — not stream order, which a reader may not rely on —
 * so two implementations that compose the same population agree on every row.
 */
function reconstructAt(state: KeyframeDeltaState, grids: Grids, t: number): Reconstruction {
  const n = state.count;
  const order = Array.from({ length: n }, (_, i) => i).sort(
    (a, b) => state.ids[a]! - state.ids[b]!,
  );
  const ids = new Int32Array(n);
  const centers = new Float64Array(n * 3);
  const scales = new Float64Array(n * 3);
  const opacity = new Float64Array(n);
  if (n === 0) return { ids, centers, scales, opacity, count: 0 };

  const position = state.column(Attribute.Position)!.values;
  const scaleBins = state.column(Attribute.Scale)!.values;
  const motion = state.column(Attribute.Motion)!.values;
  const muBins = state.column(Attribute.MuT)!.values;
  const sigmaBinsCol = state.column(Attribute.SigmaT)!.values;
  const flags = state.column(Attribute.Flags)!.values;
  const opacityBins = state.column(Attribute.Opacity)!.values;
  const windowBins = state.column(Attribute.WindowIndex)!.values;

  const steps = grids.steps;
  const k = supportK(grids.cutoff);
  const windowCount = grids.windows.length >>> 1;

  for (let outRow = 0; outRow < n; outRow++) {
    const i = order[outRow]!;
    ids[outRow] = state.ids[i]!;

    const sigmaBin = sigmaBinsCol[i]!;
    const neverFades = (flags[i]! & GAUSSIAN_FLAG_NEVER_FADES) !== 0;
    const sigma = neverFades ? Infinity : Math.exp(sigmaBin * steps.sigmaLog);
    // A never-fading gaussian's velocity grid is derived from the length of its own
    // validity window (spec §6.3), so the pitch is selected per gaussian from its
    // window_index rather than from a single shared window; an out-of-range index is
    // refused, not clamped.
    const windowIndex = checkWindowIndex(windowBins[i]!, windowCount);
    const winLen = grids.windows[windowIndex * 2 + 1]! - grids.windows[windowIndex * 2]!;
    const mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, winLen, k),
      steps.motion,
    );
    const tStep = muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    const mu = muBins[i]! * tStep;
    const dt = t - mu;

    const o3 = outRow * 3;
    const i3 = i * 3;
    for (let c = 0; c < 3; c++) {
      const pos = position[i3 + c]! * steps.pos + grids.origin[c]!;
      centers[o3 + c] = pos + motion[i3 + c]! * mStep * dt;
      scales[o3 + c] = Math.exp(scaleBins[i3 + c]! * steps.scaleLog);
    }

    const alpha = clamp(opacityBins[i]! * steps.alpha, 0, 1);
    const marginal = sigma === Infinity ? 1 : Math.exp(-0.5 * (dt / sigma) * (dt / sigma));
    opacity[outRow] = alpha * marginal;
  }
  return { ids, centers, scales, opacity, count: n };
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

function stateCovering(
  chunks: readonly KeyframeDeltaChunkInfo[],
  t: number,
): KeyframeDeltaChunkInfo {
  for (const c of chunks) if (c.t0 <= t && t < c.t1) return c;
  return chunks[chunks.length - 1]!;
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
  const grids = gridsFor(sequence);
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

  const states = probeTimes(sequence.chunks, duration).map((t) =>
    stateRow(stateCovering(sequence.chunks, t), grids, t),
  );

  return {
    temporalModel: "keyframe-delta",
    gaussianCount: String(sequence.header.gaussianCount),
    durationSec: num(duration),
    cutoff: num(sequence.header.cutoff),
    chunks: chunkRows,
    states,
  };
}

function stateRow(info: KeyframeDeltaChunkInfo, grids: Grids, t: number): Record<string, unknown> {
  const r = reconstructAt(info.state, grids, t);
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
    liveCount: String(info.state.count),
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
