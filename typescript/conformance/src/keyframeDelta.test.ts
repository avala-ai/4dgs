// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Unit tests for the keyframe-delta decode: composition, the two read paths, and the
 * canonical `states` byte-parity against the Python reference.
 *
 * The fixtures ({@link KEYFRAME_DELTA_FIXTURES}) are whole files the reference wrote; the
 * hand-built states here exercise the composition refusals a valid file never reaches, so
 * a failure points at a function rather than at a file. Mirrors the assertions in
 * `python/fourdgs/tests/test_keyframe_delta_file.py`.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  type BinColumn,
  type Grids,
  type Group,
  type State,
  Attribute,
  MalformedFile,
  UnsupportedCodec,
  applyDelta,
  chainFor,
  checkTiling,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decompressChunkBlock,
  DEFAULT_CODECS,
  gridsFor,
  keyframeState,
  lifeClass,
  motionStep,
  reconstructAt,
  stateCount,
  supportK,
} from "@4dgs/core";

import { canonical } from "./canonical.js";
import { deflate } from "./testing.js";
import { KEYFRAME_DELTA_FIXTURES } from "./keyframeDelta.fixture.js";
import { keyframeDeltaStates } from "./keyframeDeltaCanonical.js";

function bytes(base64: string): Uint8Array {
  return new Uint8Array(Buffer.from(base64, "base64"));
}

// --- byte-identical canonical parity, both read paths ---------------------

/**
 * The parity comparison the shared harness uses: `json.loads(actual) == json.loads(expected)`
 * (run.py). Structural, not string, equality — so Python's `0.0` and JS's `0` are the same
 * value, exactly as for every other TS runner against the Python reference. Every rounded
 * float and every stringified integer must still match to the digit.
 */
function assertMatchesReference(produced: string, reference: string): void {
  assert.deepEqual(JSON.parse(produced), JSON.parse(reference));
  // And the field ordering and rounding are ours to control, so the two agree as strings
  // once Python's trailing `.0` on integer-valued floats is normalized — the one formatting
  // difference the harness's structural compare absorbs.
  const normalize = (s: string): string => s.replace(/(-?\d+)\.0\b(?!\d)/g, "$1");
  assert.equal(produced, normalize(reference));
}

for (const fixture of KEYFRAME_DELTA_FIXTURES) {
  test(`${fixture.name}: streamed and indexed read paths produce the same canonical states`, async () => {
    const streamed = await decodeKeyframeDeltaStreamed(bytes(fixture.base64));
    const { decoded: indexed } = await decodeKeyframeDeltaIndexed(bytes(fixture.base64));
    // Agreeing across two very different read paths is most of what makes a keyframe-delta
    // implementation trustworthy (spec §11); neither path is an optimization of the other.
    const streamedJson = canonical(keyframeDeltaStates(streamed));
    assert.equal(streamedJson, canonical(keyframeDeltaStates(indexed)));

    // Where the reference canonical is embedded, prove byte-parity against Python too.
    if (fixture.canonical !== undefined) {
      assertMatchesReference(streamedJson, fixture.canonical);
    }
  });
}

test("both delta modes are covered by the fixtures", () => {
  const names = KEYFRAME_DELTA_FIXTURES.map((f) => f.name);
  assert.ok(names.includes("moving-chained"));
  assert.ok(names.includes("moving-keyframe-ref"));
});

test("births and deaths move the population across the clip", async () => {
  const decoded = await decodeKeyframeDeltaStreamed(
    bytes(KEYFRAME_DELTA_FIXTURES.find((f) => f.name === "moving-chained")!.base64),
  );
  const live = decoded.chunks.map((c) => stateCount(c.state));
  // The population grows and shrinks: a birth raises the live count, a death lowers it.
  assert.ok(Math.max(...live) > Math.min(...live));
  const hasBirth = decoded.chunks.some((c) => (c.birthCount ?? 0) > 0);
  const hasDeath = decoded.chunks.some((c) => (c.deathCount ?? 0) > 0);
  assert.ok(hasBirth && hasDeath);
});

test("a keyframe-only file is the frame-sequence shape: every chunk a keyframe", async () => {
  const decoded = await decodeKeyframeDeltaStreamed(
    bytes(KEYFRAME_DELTA_FIXTURES.find((f) => f.name === "keyframe-only")!.base64),
  );
  assert.ok(decoded.chunks.every((c) => c.kind === 0));
});

test("error does not grow with chain depth", async () => {
  const decoded = await decodeKeyframeDeltaStreamed(
    bytes(KEYFRAME_DELTA_FIXTURES.find((f) => f.name === "deep-chain")!.base64),
  );
  const last = decoded.chunks[decoded.chunks.length - 1]!;
  assert.equal(last.depth, decoded.chunks.length - 1); // a genuinely deep chain
  const grids = gridsFor(decoded);
  const r = reconstructAt(last.state, grids, decoded.chunks.length - 1);
  const trueX = 0.001 * (decoded.chunks.length - 1);
  // Within one grid pitch — the one-shot quantization error, not depth times it.
  assert.ok(Math.abs(r.centers[0]! - trueX) <= decoded.quantization.stepPos);
});

test("the temporal-model gate refuses a gaussian-birth file, naming the model", async () => {
  // A minimal well-formed header whose temporal_model is the default gaussian-birth.
  const decoded = await decodeKeyframeDeltaStreamed(bytes(KEYFRAME_DELTA_FIXTURES[0]!.base64)).then(
    () => "ok",
  );
  assert.equal(decoded, "ok"); // sanity: the keyframe-delta file itself is accepted
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(gaussianBirthHeaderFile()),
    (err: unknown) => err instanceof MalformedFile && err.code === "wrong-temporal-model",
  );
});

// --- composition refusals, on hand-built states ---------------------------

function col(values: number[], channels = 1): BinColumn {
  return { values: new Int32Array(values), channels };
}

/** A tiny state carrying the attributes the composition rules touch. */
function baseState(): State {
  return keyframeState(
    new Int32Array([10, 20, 30]),
    new Map<number, BinColumn>([
      [Attribute.Position, col([0, 0, 0, 1, 1, 1, 2, 2, 2], 3)],
      [Attribute.SigmaT, col([5, 5, 5])],
      [Attribute.Flags, col([0, 0, 0])],
    ]),
  );
}

function group(ids: number[], bins: Map<number, BinColumn> = new Map()): Group {
  return { ids: new Int32Array(ids), bins };
}

const NO_DEATHS = new Int32Array(0);

test("deaths remove the named ids; updates compose by bin difference", () => {
  const composed = applyDelta(
    baseState(),
    group([20], new Map([[Attribute.Position, col([5, 0, 0], 3)]])),
    group([]),
    new Int32Array([30]),
  );
  assert.deepEqual([...composed.ids], [10, 20]);
  // id 20 was at (1,1,1); a +5 delta on x composes to bin 6.
  const pos = composed.bins.get(Attribute.Position)!;
  const row = [...composed.ids].indexOf(20) * 3;
  assert.deepEqual([pos.values[row], pos.values[row + 1], pos.values[row + 2]], [6, 1, 1]);
});

test("a birth inserts absolute state and refuses a partial one", () => {
  const full = new Map<number, BinColumn>([
    [Attribute.Position, col([9, 9, 9], 3)],
    [Attribute.SigmaT, col([7])],
    [Attribute.Flags, col([0])],
  ]);
  const composed = applyDelta(baseState(), group([]), group([40], full), NO_DEATHS);
  assert.ok([...composed.ids].includes(40));

  const partial = new Map<number, BinColumn>([[Attribute.Position, col([9, 9, 9], 3)]]);
  assert.throws(
    () => applyDelta(baseState(), group([]), group([40], partial), NO_DEATHS),
    (e: unknown) => e instanceof MalformedFile && e.code === "incomplete-birth",
  );
});

test("an update carrying a GOP-invariant attribute is refused", () => {
  assert.throws(
    () =>
      applyDelta(
        baseState(),
        group([10], new Map([[Attribute.SigmaT, col([1])]])),
        group([]),
        NO_DEATHS,
      ),
    (e: unknown) => e instanceof MalformedFile && e.code === "invariant-changed-in-update",
  );
});

test("an id in two groups of one delta is refused", () => {
  assert.throws(
    () => applyDelta(baseState(), group([10]), group([10], new Map()), NO_DEATHS),
    (e: unknown) => e instanceof MalformedFile && e.code === "id-in-two-groups",
  );
});

test("updating or killing an id that is not live is refused", () => {
  assert.throws(
    () =>
      applyDelta(
        baseState(),
        group([999], new Map([[Attribute.Position, col([1, 0, 0], 3)]])),
        group([]),
        NO_DEATHS,
      ),
    (e: unknown) => e instanceof MalformedFile && e.code === "unknown-gaussian-id",
  );
  assert.throws(
    () => applyDelta(baseState(), group([]), group([]), new Int32Array([999])),
    (e: unknown) => e instanceof MalformedFile && e.code === "unknown-gaussian-id",
  );
});

test("a birth of an already-live id is refused", () => {
  const full = new Map<number, BinColumn>([
    [Attribute.Position, col([9, 9, 9], 3)],
    [Attribute.SigmaT, col([7])],
    [Attribute.Flags, col([0])],
  ]);
  assert.throws(
    () => applyDelta(baseState(), group([]), group([10], full), NO_DEATHS),
    (e: unknown) => e instanceof MalformedFile && e.code === "duplicate-gaussian-id",
  );
});

test("a composed bin outside i32 is refused, not wrapped", () => {
  const state = keyframeState(
    new Int32Array([1]),
    new Map([[Attribute.Position, col([2147483647, 0, 0], 3)]]),
  );
  assert.throws(
    () =>
      applyDelta(
        state,
        group([1], new Map([[Attribute.Position, col([1, 0, 0], 3)]])),
        group([]),
        NO_DEATHS,
      ),
    (e: unknown) => e instanceof MalformedFile && e.code === "bin-overflow",
  );
});

test("rotation in an update is absolute, replacing rather than differencing", () => {
  const state = keyframeState(
    new Int32Array([1]),
    new Map<number, BinColumn>([
      [Attribute.RotationIndex, col([3])],
      [Attribute.Rotation, col([10, 20, 30], 3)],
    ]),
  );
  const composed = applyDelta(
    state,
    group(
      [1],
      new Map<number, BinColumn>([
        [Attribute.RotationIndex, col([0])],
        [Attribute.Rotation, col([1, 2, 3], 3)],
      ]),
    ),
    group([]),
    NO_DEATHS,
  );
  assert.deepEqual([...composed.bins.get(Attribute.Rotation)!.values], [1, 2, 3]);
  assert.deepEqual([...composed.bins.get(Attribute.RotationIndex)!.values], [0]);
});

// --- the seek walk, on synthetic index entries ----------------------------

function entry(over: Partial<Record<string, number>>): import("@4dgs/core").ChunkIndexEntry {
  return {
    t0: 0,
    t1: 1,
    chunkOffset: 0,
    chunkLength: 0,
    gaussianCount: 0,
    bands: [],
    extended: true,
    kind: 0,
    deltaMode: 0,
    referenceOffset: 0,
    keyframeOffset: 0,
    depth: 0,
    liveCount: 0,
    ...over,
  } as import("@4dgs/core").ChunkIndexEntry;
}

test("checkTiling refuses a gap and an overlap", () => {
  assert.throws(
    () => checkTiling([entry({ t0: 0, t1: 1 }), entry({ t0: 2, t1: 3 })]),
    (e: unknown) => e instanceof MalformedFile && e.code === "non-tiling-chunks",
  );
  assert.throws(
    () => checkTiling([entry({ t0: 0, t1: 2 }), entry({ t0: 1, t1: 3 })]),
    (e: unknown) => e instanceof MalformedFile && e.code === "non-tiling-chunks",
  );
});

test("chainFor walks a keyframe then its deltas, and refuses a forward reference", () => {
  const index = [
    entry({ t0: 0, t1: 1, chunkOffset: 100, kind: 0, keyframeOffset: 100 }),
    entry({ t0: 1, t1: 2, chunkOffset: 200, kind: 1, referenceOffset: 100, depth: 1 }),
    entry({ t0: 2, t1: 3, chunkOffset: 300, kind: 1, referenceOffset: 200, depth: 2 }),
  ];
  const chain = chainFor(index, 2.5);
  assert.deepEqual(
    chain.map((e) => e.chunkOffset),
    [100, 200, 300],
  );

  const forward = [
    entry({ t0: 0, t1: 1, chunkOffset: 100, kind: 1, referenceOffset: 500, depth: 1 }),
  ];
  assert.throws(
    () => chainFor(forward, 0.5),
    (e: unknown) => e instanceof MalformedFile && e.code === "forward-reference",
  );
});

test("chainFor refuses a depth that disagrees with the walk", () => {
  const index = [
    entry({ t0: 0, t1: 1, chunkOffset: 100, kind: 0, keyframeOffset: 100 }),
    entry({ t0: 1, t1: 2, chunkOffset: 200, kind: 1, referenceOffset: 100, depth: 5 }),
  ];
  assert.throws(
    () => chainFor(index, 1.5),
    (e: unknown) => e instanceof MalformedFile && e.code === "depth-mismatch",
  );
});

/** A header-only file whose temporal_model is gaussian-birth, for the gate test. */
function gaussianBirthHeaderFile(): Uint8Array {
  const enc = new TextEncoder();
  const str = (s: string): number[] => {
    const b = enc.encode(s);
    return [
      b.length & 0xff,
      (b.length >>> 8) & 0xff,
      (b.length >>> 16) & 0xff,
      (b.length >>> 24) & 0xff,
      ...b,
    ];
  };
  const f64 = (v: number): number[] => {
    const dv = new DataView(new ArrayBuffer(8));
    dv.setFloat64(0, v, true);
    return [...new Uint8Array(dv.buffer)];
  };
  const u64 = (v: number): number[] => {
    const dv = new DataView(new ArrayBuffer(8));
    dv.setBigUint64(0, BigInt(v), true);
    return [...new Uint8Array(dv.buffer)];
  };
  const body = [
    ...str(""), // profile
    ...str(""), // library
    ...f64(1), // duration_sec
    ...u64(0), // gaussian_count
    ...f64(0.05), // cutoff
    ...str("gaussian-birth"), // temporal_model
    ...f64(0),
    ...f64(0),
    ...f64(0),
    ...f64(0),
    ...f64(0),
    ...f64(0), // aabb
    0, // sh_degree
    0, // flags
    ...[0, 0, 0, 0], // attributes map: u32 block length 0
  ];
  const magic = [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a];
  const header = [0x01, ...u64(body.length), ...body];
  return new Uint8Array([...magic, ...header]);
}

// --- chunk-level compression (codex P1 §5.5/§5.18) ------------------------

test("decompressChunkBlock undoes chunk-level compression before framing", async () => {
  const payload = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);

  // Empty compression is a pass-through: the block is already the streams.
  const passthrough = await decompressChunkBlock(payload, "", payload.length, DEFAULT_CODECS, "x");
  assert.deepEqual([...passthrough], [...payload]);

  // A deflate-compressed block is inflated to exactly its declared size — the path a
  // compressed keyframe or Delta Chunk now takes before its streams are framed.
  const compressed = await deflate(payload);
  const restored = await decompressChunkBlock(
    compressed,
    "deflate",
    payload.length,
    DEFAULT_CODECS,
    "x",
  );
  assert.deepEqual([...restored], [...payload]);

  // An unrecognized codec is refused by name — the file may be conforming and this build
  // simply cannot read it.
  await assert.rejects(
    () => decompressChunkBlock(compressed, "brotli", payload.length, DEFAULT_CODECS, "delta chunk"),
    (e: unknown) => e instanceof UnsupportedCodec,
  );
});

// --- per-gaussian velocity precision (codex P1 §6.3) ----------------------

test("motion precision follows each gaussian's own validity window, not window 0", () => {
  const steps = {
    pos: 0.001,
    scaleLog: 0.01,
    rot: 0.001,
    rgb: 0.01,
    alpha: 0.01,
    motion: 0.01,
    time: 0.01,
    sigmaLog: 0.01,
    sh: 8,
  };
  // Two windows: a long window 0 and a short window 1. One always-visible gaussian
  // (flags bit 0 set) references window 1, so its velocity grid must come from window 1's
  // 0.02 s length, not window 0's 4 s.
  const windows = new Float64Array([0, 4, 0, 0.02]);
  const grids: Grids = { steps, origin: [0, 0, 0], windows, cutoff: 0.05 };

  const c1 = (v: number): BinColumn => ({ values: new Int32Array([v]), channels: 1 });
  const c3 = (a: number, b: number, d: number): BinColumn => ({
    values: new Int32Array([a, b, d]),
    channels: 3,
  });
  const motionBinX = 10;
  const state = keyframeState(
    new Int32Array([0]),
    new Map<number, BinColumn>([
      [Attribute.Position, c3(0, 0, 0)],
      [Attribute.Scale, c3(0, 0, 0)],
      [Attribute.RotationIndex, c1(3)],
      [Attribute.Rotation, c3(0, 0, 0)],
      [Attribute.Color, c3(0, 0, 0)],
      [Attribute.Opacity, c1(0)],
      [Attribute.Motion, c3(motionBinX, 0, 0)],
      [Attribute.MuT, c1(0)],
      [Attribute.SigmaT, c1(0)],
      [Attribute.Flags, c1(1)], // never fades
      [Attribute.WindowIndex, c1(1)], // references window 1
    ]),
  );

  const r = reconstructAt(state, grids, 1);
  const k = supportK(0.05);
  const stepForWindow = (len: number): number =>
    motionStep(lifeClass(0, steps.sigmaLog, true, len, k), steps.motion);
  // The reconstructed x is `motionBinX * step(window 1)`, and demonstrably not the value a
  // shared window-0 pitch would give.
  assert.equal(r.centers[0], motionBinX * stepForWindow(0.02));
  assert.notEqual(stepForWindow(0.02), stepForWindow(4));
  assert.notEqual(r.centers[0], motionBinX * stepForWindow(4));
});

test("an out-of-range window index is refused, not clamped", () => {
  const steps = {
    pos: 1,
    scaleLog: 1,
    rot: 1,
    rgb: 1,
    alpha: 1,
    motion: 1,
    time: 1,
    sigmaLog: 1,
    sh: 8,
  };
  const grids: Grids = {
    steps,
    origin: [0, 0, 0],
    windows: new Float64Array([0, 1]),
    cutoff: 0.05,
  };
  const c1 = (v: number): BinColumn => ({ values: new Int32Array([v]), channels: 1 });
  const c3 = (): BinColumn => ({ values: new Int32Array([0, 0, 0]), channels: 3 });
  const state = keyframeState(
    new Int32Array([0]),
    new Map<number, BinColumn>([
      [Attribute.Position, c3()],
      [Attribute.Scale, c3()],
      [Attribute.RotationIndex, c1(3)],
      [Attribute.Rotation, c3()],
      [Attribute.Color, c3()],
      [Attribute.Opacity, c1(0)],
      [Attribute.Motion, c3()],
      [Attribute.MuT, c1(0)],
      [Attribute.SigmaT, c1(0)],
      [Attribute.Flags, c1(1)],
      [Attribute.WindowIndex, c1(5)], // only window 0 exists
    ]),
  );
  assert.throws(() => reconstructAt(state, grids, 0.5), MalformedFile);
});

// --- index/record cross-check on seek (codex P2 §5.8/§11.9) ---------------

test("indexed decode refuses a Delta Chunk header that disagrees with its index entry", async () => {
  const data = bytes(KEYFRAME_DELTA_FIXTURES.find((f) => f.name === "moving-chained")!.base64);
  const { index } = await decodeKeyframeDeltaIndexed(data);
  const delta = index.find((e) => e.kind === 1)!;
  assert.ok(delta, "fixture has at least one delta chunk");

  // Corrupt the Delta Chunk header's depth so it disagrees with the (unchanged) index
  // depth. The chain walk uses the index, so it still composes; the cross-check is what
  // must catch the disagreement. depth sits at content offset 8+8+4+1+8+8 = 37, after the
  // record's 9-byte framing.
  const mutated = data.slice();
  const view = new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength);
  const depthOffset = delta.chunkOffset + 9 + 37;
  view.setUint16(depthOffset, view.getUint16(depthOffset, true) + 7, true);

  await assert.rejects(
    () => decodeKeyframeDeltaIndexed(mutated),
    (e: unknown) => e instanceof MalformedFile && e.code === "index-record-mismatch",
  );
});
