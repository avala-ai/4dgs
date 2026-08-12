// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The `keyframe-delta` encoder.
 *
 * The cross-language claim — that a file written here decodes, in Python, to the canonical
 * `states` the Python-written corpus file decodes to — is made by
 * `typescript/keyframe-delta-roundtrip.sh`, because it needs a Python interpreter. What
 * these tests own is everything provable inside Node: the counting rules, the shape of the
 * records, what the writer refuses, and that the two read paths agree on what it wrote.
 *
 * The corpus expectation is asserted here too, against the committed
 * `tests/conformance/data/keyframe/<name>.json`, because that file is just JSON and this
 * side's decoder can produce the same statement. That makes the strongest claim available
 * without leaving the process: same populations, two encoders, one meaning.
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  DELTA_MODE_CHAINED,
  DELTA_MODE_KEYFRAME,
  MAGIC,
  Opcode,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  encodeKeyframeDeltaSequence,
  iterateRecords,
  reconstructKeyframeDelta,
  keyframeDeltaStatesJson,
  parseChunkIndexEntry,
  parseHeader,
  parseQuantization,
  parseStatistics,
  parseWindowTable,
  type KeyframeDeltaSample,
} from "@4dgs/core";

import { canonical } from "./canonical.js";
import {
  CORPUS_LIBRARY,
  KEYFRAME_DELTA_DURATION,
  KEYFRAME_DELTA_VARIANTS,
} from "./keyframeDeltaSequences.js";

const DURATION = KEYFRAME_DELTA_DURATION;

/** Generated rather than committed; CI builds it before running these. */
const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));

function encode(
  variant: (typeof KEYFRAME_DELTA_VARIANTS)[number],
  library = CORPUS_LIBRARY,
): Promise<Uint8Array> {
  return encodeKeyframeDeltaSequence(variant.samples, DURATION, {
    keyframeEvery: variant.keyframeEvery,
    deltaMode: variant.deltaMode,
    library,
  });
}

/** One gaussian at the origin, finite sigma, one full-duration window. */
function one(x: number): Mutable {
  return {
    count: 1,
    positions: Float32Array.from([x, 0, 0]),
    scales: Float32Array.from([0.05, 0.05, 0.05]),
    rotations: Float32Array.from([0, 0, 0, 1]),
    colors: Float32Array.from([0.6, 0.4, 0.2, 0.9]),
    motions: new Float32Array(3),
    muT: new Float32Array(1),
    sigmaT: Float32Array.from([100]),
    winLo: new Float32Array(1),
    winHi: Float32Array.from([DURATION]),
  };
}

/** Two samples of the same single gaussian; mutable, so a test can spoil one lane. */
function pair(x0: number, x1: number): { t0: number; ids: number[]; gaussians: Mutable }[] {
  return [
    { t0: 0, ids: [7], gaussians: one(x0) },
    { t0: DURATION / 2, ids: [7], gaussians: one(x1) },
  ];
}

/** `GaussianInput` with its lanes writable, which is what these refusal tests need. */
type Mutable = {
  -readonly [K in keyof KeyframeDeltaSample["gaussians"]]: KeyframeDeltaSample["gaussians"][K];
};

function records(data: Uint8Array): { opcode: number; content: Uint8Array }[] {
  return [...iterateRecords(data, MAGIC.length)].map((r) => ({
    opcode: r.opcode,
    content: r.content,
  }));
}

/**
 * The Python reference writer still preserves source mu_t on nonzero keyframes; §11.3
 * requires the state timestamp. Until that writer is corrected, its corpus summary differs
 * only in the temporal marginal folded into this aggregate.
 */
function withoutPythonMuAnchorDifferences(
  summary: Record<string, unknown>,
): Record<string, unknown> {
  const copy = structuredClone(summary) as {
    chunks: { t0: number; kind: string; updateCount?: unknown }[];
    states: { t: number; aggregate: { opacitySum?: number } }[];
  };
  // The Python reference does not emit an update for a persistent gaussian whose only new
  // bin is the sample-time mu_t anchor. TypeScript must, because retaining the older anchor
  // changes reconstructed state. The operational update count therefore differs until the
  // reference writer adopts the same rule; it is not part of the state comparison here.
  for (const chunk of copy.chunks) {
    if (chunk.kind === "delta") delete chunk.updateCount;
  }
  const firstNonzero = copy.chunks.find((chunk) => chunk.t0 > 0)?.t0;
  if (firstNonzero !== undefined) {
    for (const state of copy.states) {
      if (state.t >= firstNonzero) delete state.aggregate.opacitySum;
    }
  }
  return copy as unknown as Record<string, unknown>;
}

// --------------------------------------------------------------------------
// The cross-encoder statement
// --------------------------------------------------------------------------

for (const variant of KEYFRAME_DELTA_VARIANTS.filter((v) => v.inCorpus)) {
  test(`a file this encoder writes means what the Python-written corpus file means — ${variant.name}`, async (t) => {
    const path = `${DATA}keyframe/${variant.name}.json`;
    if (!existsSync(path)) {
      t.skip("corpus not generated; run tests/conformance/generate.py");
      return;
    }
    const data = await encode(variant);
    const expectation = readFileSync(path, "utf8");
    // Both read paths, because they fail differently: the streamed one never looks at the
    // index, so a wrong offset or chunk range decodes there and only the indexed path sees it.
    const streamed = canonical(keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(data)));
    const indexed = canonical(
      keyframeDeltaStatesJson((await decodeKeyframeDeltaIndexed(data)).sequence),
    );
    assert.equal(
      canonical(withoutPythonMuAnchorDifferences(JSON.parse(streamed) as Record<string, unknown>)),
      canonical(
        withoutPythonMuAnchorDifferences(JSON.parse(expectation) as Record<string, unknown>),
      ),
    );
    assert.equal(indexed, streamed);
  });
}

test("the sequence this side invented reads the same on both paths", async () => {
  const variant = KEYFRAME_DELTA_VARIANTS.find((v) => !v.inCorpus)!;
  const data = await encode(variant);
  const streamed = keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(data));
  const indexed = keyframeDeltaStatesJson((await decodeKeyframeDeltaIndexed(data)).sequence);
  assert.equal(canonical(indexed), canonical(streamed));
  // Two distinct validity windows, which is what puts a per-gaussian motion grid under test.
  const table = parseWindowTable(
    records(data).find((r) => r.opcode === Opcode.WindowTable)!.content,
  );
  assert.equal(table.length / 2, 2);
});

// --------------------------------------------------------------------------
// The counting rules
// --------------------------------------------------------------------------

test("the Header's gaussian_count is distinct ids, not a sum over chunks", async () => {
  const variant = KEYFRAME_DELTA_VARIANTS.find((v) => v.name.startsWith("KeyframeDeltaChurn"))!;
  const data = await encode(variant);
  const distinct = new Set<number>();
  let summed = 0;
  for (const s of variant.samples) {
    for (const id of s.ids as number[]) distinct.add(id);
    summed += s.ids.length;
  }
  // The churn sequence is chosen because the two numbers differ by a lot: five ids over
  // eight samples, so a sum would be 35. A test on a fixed population could not tell them apart.
  assert.equal(distinct.size, 5);
  assert.equal(summed, 35);

  const header = parseHeader(records(data).find((r) => r.opcode === Opcode.Header)!.content);
  assert.equal(header.gaussianCount, distinct.size);
  assert.equal(header.temporalModel, "keyframe-delta");

  const statistics = parseStatistics(
    records(data).find((r) => r.opcode === Opcode.Statistics)!.content,
  );
  assert.equal(statistics.gaussianCount, distinct.size);
  assert.equal(statistics.chunkCount, variant.samples.length);
});

test("a delta entry counts operations; live_count counts the population, keyframes included", async () => {
  const variant = KEYFRAME_DELTA_VARIANTS.find((v) => v.name.startsWith("KeyframeDeltaChurn"))!;
  const data = await encode(variant);
  const { sequence, index } = await decodeKeyframeDeltaIndexed(data);
  assert.equal(index.length, sequence.chunks.length);

  let deltas = 0;
  let discriminatingDeltas = 0;
  for (let i = 0; i < index.length; i++) {
    const entry = index[i]!;
    const chunk = sequence.chunks[i]!;
    // §5.8 defines live_count for EVERY extended entry, not only for deltas.
    assert.equal(entry.liveCount, chunk.state.count, `entry ${i} live_count`);
    if (entry.kind === 0) {
      assert.equal(entry.gaussianCount, chunk.state.count, `entry ${i} keyframe gaussian_count`);
      assert.equal(entry.keyframeOffset, entry.chunkOffset);
    } else {
      deltas++;
      const operations = chunk.updateCount! + chunk.birthCount! + chunk.deathCount!;
      assert.equal(entry.gaussianCount, operations, `entry ${i} delta gaussian_count`);
      if (operations !== chunk.state.count) discriminatingDeltas++;
    }
  }
  assert.ok(deltas > 0, "the churn sequence must carry deltas for this to prove anything");
  // At least one entry must distinguish the operation count from the resulting population,
  // or writing live_count in both fields would pass this test accidentally.
  assert.ok(discriminatingDeltas > 0, "the churn sequence must discriminate the two counts");
});

test("births and deaths land in their own groups", async () => {
  const variant = KEYFRAME_DELTA_VARIANTS.find((v) => v.name.startsWith("KeyframeDeltaChurn"))!;
  const { sequence } = await decodeKeyframeDeltaIndexed(await encode(variant));
  const births = sequence.chunks.reduce((n, c) => n + (c.birthCount ?? 0), 0);
  const deaths = sequence.chunks.reduce((n, c) => n + (c.deathCount ?? 0), 0);
  assert.equal(births, 1, "id 4 is born once");
  assert.equal(deaths, 1, "id 2 dies once");
});

// --------------------------------------------------------------------------
// Structure
// --------------------------------------------------------------------------

test("chunk kinds are 0 and 1, and nothing else", async () => {
  for (const variant of KEYFRAME_DELTA_VARIANTS) {
    const { index } = await decodeKeyframeDeltaIndexed(await encode(variant));
    for (const entry of index) assert.ok(entry.kind === 0 || entry.kind === 1);
  }
});

test("cadence decides which samples are keyframes", async () => {
  const samples = Array.from({ length: 8 }, (_, i) => ({
    t0: i * (DURATION / 8),
    ids: [7],
    gaussians: one(i * 0.1),
  }));
  const every4 = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 4 }),
  );
  assert.deepEqual(
    every4.index.map((e) => e.kind),
    [0, 1, 1, 1, 0, 1, 1, 1],
  );

  // keyframeEvery 1 makes every sample a keyframe, which is legal and is the shape the
  // registry's `frame-sequence` reservation describes.
  const all = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 1 }),
  );
  assert.deepEqual(
    all.index.map((e) => e.kind),
    Array(8).fill(0),
  );

  // `keyframeAt` forces one beyond the cadence.
  const forced = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 4, keyframeAt: [2] }),
  );
  assert.deepEqual(
    forced.index.map((e) => e.kind),
    [0, 1, 0, 1, 0, 1, 1, 1],
  );
});

test("a chained delta's depth grows along the chain; a keyframe-referenced one is always 1", async () => {
  const samples = Array.from({ length: 8 }, (_, i) => ({
    t0: i * (DURATION / 8),
    ids: [7],
    gaussians: one(i * 0.1),
  }));
  const chained = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(samples, DURATION, {
      keyframeEvery: 4,
      deltaMode: DELTA_MODE_CHAINED,
    }),
  );
  assert.deepEqual(
    chained.index.map((e) => e.depth),
    [0, 1, 2, 3, 0, 1, 2, 3],
  );
  for (const entry of chained.index) {
    if (entry.kind === 1) assert.equal(entry.deltaMode, DELTA_MODE_CHAINED);
  }

  const referenced = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(samples, DURATION, {
      keyframeEvery: 4,
      deltaMode: DELTA_MODE_KEYFRAME,
    }),
  );
  assert.deepEqual(
    referenced.index.map((e) => e.depth),
    [0, 1, 1, 1, 0, 1, 1, 1],
  );
  // Every delta references its group's keyframe, so a seek costs two records at any depth.
  for (const entry of referenced.index) {
    if (entry.kind === 1) assert.equal(entry.referenceOffset, entry.keyframeOffset);
  }
});

test("a persistent gaussian restates its sample-time anchor", async () => {
  // Nothing visible changes in the authored lanes, but mu_t is the anchor of the stated
  // sample. With motion, retaining the keyframe's anchor would move the decoded centre at
  // the second sample and give the temporal marginal the wrong age.
  const still = pair(0.25, 0.25);
  for (const sample of still) sample.gaussians.motions = Float32Array.from([2, 0, 0]);
  const { sequence } = await decodeKeyframeDeltaIndexed(
    await encodeKeyframeDeltaSequence(still, DURATION, { keyframeEvery: 8 }),
  );
  const delta = sequence.chunks[1]!;
  assert.equal(delta.kind, 1);
  assert.equal(delta.updateCount, 1);
  assert.equal(delta.birthCount, 0);
  assert.equal(delta.deathCount, 0);
});

test("mu_t is anchored to each sample timestamp", async () => {
  const samples = pair(0, 0);
  for (const sample of samples) sample.gaussians.motions = Float32Array.from([2, 0, 0]);
  samples[1]!.gaussians.muT = Float32Array.from([0]); // deliberately not sample t0
  const sequence = await decodeKeyframeDeltaStreamed(
    await encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 8 }),
  );
  const t = samples[1]!.t0;
  const states = keyframeDeltaStatesJson(sequence).states as {
    t: number;
    sample: { positions: number[][] };
  }[];
  const center = states.find((state) => state.t === t)!.sample.positions[0]![0]!;
  assert.ok(Math.abs(center) < 0.01, `centre at sample time: ${center}`);
});

test("the file is framed by magic at both ends, and the summary is the index then statistics", async () => {
  const data = await encode(KEYFRAME_DELTA_VARIANTS[1]!);
  assert.deepEqual([...data.subarray(0, MAGIC.length)], [...MAGIC]);
  assert.deepEqual([...data.subarray(data.length - MAGIC.length)], [...MAGIC]);

  const opcodes = records(data).map((r) => r.opcode);
  assert.deepEqual(opcodes.slice(0, 3), [Opcode.Header, Opcode.Quantization, Opcode.WindowTable]);
  // One contiguous run immediately before the Footer, nothing else inside it.
  const summary = opcodes.slice(opcodes.indexOf(Opcode.ChunkIndex));
  assert.deepEqual(summary[summary.length - 1], Opcode.Footer);
  assert.deepEqual(summary[summary.length - 2], Opcode.Statistics);
  for (const opcode of summary.slice(0, -2)) assert.equal(opcode, Opcode.ChunkIndex);

  // Every index range frames a whole record, opcode byte included (§5.8).
  for (const raw of records(data).filter((r) => r.opcode === Opcode.ChunkIndex)) {
    const entry = parseChunkIndexEntry(raw.content);
    assert.equal(data[entry.chunkOffset], entry.kind === 0 ? Opcode.Chunk : Opcode.DeltaChunk);
  }
});

test("the Quantization record declares the bounds the file is held to", async () => {
  const data = await encode(KEYFRAME_DELTA_VARIANTS[1]!);
  const quantization = parseQuantization(
    records(data).find((r) => r.opcode === Opcode.Quantization)!.content,
  );
  // The Python reference writes these and the Rust one leaves them empty; this follows
  // Python, because a consumer's tolerance should be the encoder's own promise.
  const bound = (key: string): number => Number(quantization.bounds.get(key));
  for (const key of ["pos", "scale_rel", "rot", "rgb", "alpha", "motion", "time", "sigma_rel"]) {
    assert.ok(bound(key) > 0, `bounds.${key}`);
  }
  // Every pitch is exactly twice its bound, in the domain that attribute is quantized in.
  assert.ok(Math.abs(quantization.stepPos - 2 * bound("pos")) < 1e-18);
  assert.ok(Math.abs(quantization.stepRot - 2 * bound("rot")) < 1e-18);
});

test("Header and Statistics bound the serialized positions", async () => {
  const samples = pair(0, 0.003);
  const data = await encodeKeyframeDeltaSequence(samples, DURATION);
  const framed = records(data);
  const quantization = parseQuantization(
    framed.find((r) => r.opcode === Opcode.Quantization)!.content,
  );
  const expected = [0, 0, 0, quantization.stepPos, 0, 0];
  const header = parseHeader(framed.find((r) => r.opcode === Opcode.Header)!.content);
  const statistics = parseStatistics(framed.find((r) => r.opcode === Opcode.Statistics)!.content);
  assert.deepEqual(header.aabb, expected);
  assert.deepEqual(statistics.aabb, expected);
});

test("positive scales below 1e-30 keep the declared relative error", async () => {
  const samples = pair(0, 0);
  const tiny = 1e-35;
  for (const sample of samples) {
    sample.gaussians.scales = [tiny, 0.05, 0.05];
  }
  const data = await encodeKeyframeDeltaSequence(samples, DURATION);
  const sequence = await decodeKeyframeDeltaStreamed(data);
  const reconstructed = reconstructKeyframeDelta(sequence, sequence.chunks[0]!, 0);
  const source = samples[0]!.gaussians.scales[0]!;
  const relativeError = Math.abs(reconstructed.scales[0]! / source - 1);
  const declared = Number(sequence.quantization.bounds.get("scale_rel"));
  assert.ok(relativeError <= declared, `${relativeError} exceeds ${declared}`);
});

test("the even scale median stays finite near Number.MAX_VALUE", async () => {
  const samples = pair(0, 0);
  for (const sample of samples) {
    // Ordinary arrays keep these as finite binary64 values. Adding the middle pair would
    // overflow, while taking half of each operand before adding does not.
    sample.gaussians.scales = [Number.MAX_VALUE, Number.MAX_VALUE, Number.MAX_VALUE];
  }
  const data = await encodeKeyframeDeltaSequence(samples, DURATION);
  const quantization = parseQuantization(
    records(data).find((r) => r.opcode === Opcode.Quantization)!.content,
  );
  for (const [name, step] of Object.entries({
    stepPos: quantization.stepPos,
    stepScaleLog: quantization.stepScaleLog,
    stepRot: quantization.stepRot,
    stepRgb: quantization.stepRgb,
    stepAlpha: quantization.stepAlpha,
    stepMotion: quantization.stepMotion,
    stepTime: quantization.stepTime,
    stepSigmaLog: quantization.stepSigmaLog,
  })) {
    assert.ok(Number.isFinite(step), `${name}: ${step}`);
  }
});

test("two encodes of the same sequence are byte-identical", async () => {
  const variant = KEYFRAME_DELTA_VARIANTS[2]!;
  assert.deepEqual([...(await encode(variant))], [...(await encode(variant))]);
});

// --------------------------------------------------------------------------
// What it refuses
// --------------------------------------------------------------------------

test("a promise the writer cannot keep is refused rather than written", async () => {
  const ok = pair(0, 1);

  await assert.rejects(() => encodeKeyframeDeltaSequence([], DURATION), /at least one sample/);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(ok, Number.POSITIVE_INFINITY),
    /duration_sec must be finite/,
  );

  // A timeline that does not tile is refused here, rather than written into a file both of
  // this package's own read paths would then reject (spec §11.1).
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(
        [
          { t0: 1, ids: [7], gaussians: one(0) },
          { t0: 2, ids: [7], gaussians: one(1) },
        ],
        DURATION,
      ),
    /starts at 1, not 0/,
  );
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(
        [
          { t0: 0, ids: [7], gaussians: one(0) },
          { t0: 5, ids: [7], gaussians: one(1) },
          { t0: 3, ids: [7], gaussians: one(2) },
        ],
        DURATION,
      ),
    /empty or inverted/,
  );

  // An id list that does not match the population is a correspondence nobody asserted.
  await assert.rejects(
    () => encodeKeyframeDeltaSequence([{ t0: 0, ids: [7, 8], gaussians: one(0) }], DURATION),
    /carries 1 gaussians but 2 ids/,
  );
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(
        [{ t0: 0, ids: [7, 7], gaussians: { ...one(0), count: 2 } }],
        DURATION,
      ),
    /names gaussian id 7 twice/,
  );
  await assert.rejects(
    () => encodeKeyframeDeltaSequence([{ t0: 0, ids: [-1], gaussians: one(0) }], DURATION),
    /unsigned 32-bit/,
  );

  // delta_mode is a two-value field, and a third value is not a future extension of it.
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(ok, DURATION, { deltaMode: 2 }),
    /the format defines 0 .* and 1 .*, and nothing else/,
  );

  await assert.rejects(
    () => encodeKeyframeDeltaSequence(ok, DURATION, { profile: "ultra" }),
    /profile must be one of/,
  );

  const nanWindow = pair(0, 1);
  nanWindow[1]!.gaussians.winLo = Float32Array.from([Number.NaN]);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(nanWindow, DURATION),
    /window endpoints must not be NaN/,
  );
});

test("gaussian ids span u32 and are never reused after death", async () => {
  const high = 0xffff_fff0;
  const data = await encodeKeyframeDeltaSequence(
    [{ t0: 0, ids: [high], gaussians: one(0) }],
    DURATION,
  );
  const decoded = await decodeKeyframeDeltaStreamed(data);
  assert.equal(decoded.chunks[0]!.state.ids[0]! >>> 0, high);

  const empty = { ...one(0), count: 0 };
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(
        [
          { t0: 0, ids: [7], gaussians: one(0) },
          { t0: 1, ids: [], gaussians: empty },
          { t0: 2, ids: [7], gaussians: one(0) },
        ],
        3,
      ),
    /reuses gaussian id 7 after it died/,
  );
});

test("a chained depth that cannot fit u16 is refused before encoding", async () => {
  const empty = { ...one(0), count: 0 };
  const samples = Array.from({ length: 0x1_0001 }, (_, i) => ({
    t0: i,
    ids: [] as number[],
    gaussians: empty,
  }));
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(samples, samples.length, {
        keyframeEvery: 0,
        deltaMode: DELTA_MODE_CHAINED,
      }),
    /depth 65536, past the 65535 maximum/,
  );
});

test("a never-fading gaussian is refused, because its grid would come from a window this writer does not vary", async () => {
  const samples = pair(0, 1);
  samples[0]!.gaussians.sigmaT = Float32Array.from([Infinity]);
  await assert.rejects(() => encodeKeyframeDeltaSequence(samples, DURATION), /sigma_t is Infinity/);
});

test("spherical harmonics are refused, not silently dropped", async () => {
  const samples = pair(0, 1);
  samples[0]!.gaussians.sh = new Uint8Array(9);
  samples[0]!.gaussians.shDegree = 1;
  samples[0]!.gaussians.shCoefficients = 3;
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(samples, DURATION),
    /carries spherical harmonics/,
  );

  const undeclared = pair(0, 1);
  undeclared[0]!.gaussians.sh = Uint8Array.from([1]);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(undeclared, DURATION),
    /carries spherical harmonics/,
  );
});

test("absolute bins must fit i32 even when their delta would fit", async () => {
  const samples = pair(0, 20_000_000);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 8 }),
    /attribute 0 bin .*outside the signed 32-bit range/,
  );
});

test("small positive temporal widths are quantized without a floor", async () => {
  const tiny = pair(0, 1);
  const floored = pair(0, 1);
  for (const sample of tiny) sample.gaussians.sigmaT = Float32Array.from([1e-35]);
  for (const sample of floored) sample.gaussians.sigmaT = Float32Array.from([1e-30]);
  const tinyFile = await encodeKeyframeDeltaSequence(tiny, DURATION);
  const floorFile = await encodeKeyframeDeltaSequence(floored, DURATION);
  assert.notDeepEqual([...tinyFile], [...floorFile]);
  await decodeKeyframeDeltaIndexed(tinyFile);

  const invalid = pair(0, 1);
  for (const sample of invalid) sample.gaussians.sigmaT = Float32Array.from([0]);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(invalid, DURATION),
    /requires a finite positive temporal width/,
  );
});

test("a GOP-invariant attribute that changes mid-group is refused", async () => {
  // sigma_t, flags and window_index derive the per-gaussian velocity and birth-time grids,
  // so a bin difference across a change in one of them subtracts bins on different grids —
  // a number with no meaning, which decodes silently into a wrong velocity (spec §11.5).
  const samples = pair(0, 1);
  samples[1]!.gaussians.sigmaT = Float32Array.from([3]);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(samples, DURATION, { keyframeEvery: 8 }),
    /changes attribute 8 between samples/,
  );

  const windowed = pair(0, 1);
  windowed[1]!.gaussians.winHi = Float32Array.from([DURATION / 2]);
  await assert.rejects(
    () => encodeKeyframeDeltaSequence(windowed, DURATION, { keyframeEvery: 8 }),
    /changes attribute 10 between samples/,
  );

  // The fix is always available to the caller: a keyframe at that sample.
  const rescued = pair(0, 1);
  rescued[1]!.gaussians.sigmaT = Float32Array.from([3]);
  const data = await encodeKeyframeDeltaSequence(rescued, DURATION, { keyframeEvery: 1 });
  const { index } = await decodeKeyframeDeltaIndexed(data);
  assert.deepEqual(
    index.map((e) => e.kind),
    [0, 0],
  );

  const empty = { ...one(0), count: 0 };
  const bornAfterKeyframe = [
    { t0: 0, ids: [] as number[], gaussians: empty },
    { t0: 1, ids: [7], gaussians: one(0) },
    { t0: 2, ids: [7], gaussians: one(0) },
  ];
  bornAfterKeyframe[2]!.gaussians.sigmaT = Float32Array.from([3]);
  await assert.rejects(
    () =>
      encodeKeyframeDeltaSequence(bornAfterKeyframe, 3, {
        keyframeEvery: 8,
        deltaMode: DELTA_MODE_KEYFRAME,
      }),
    /changes attribute 8 between samples/,
  );
});
