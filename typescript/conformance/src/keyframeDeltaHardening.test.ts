// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Hardening tests for the keyframe-delta decode: the refusals and the per-gaussian
 * precision that the whole-file parity fixtures cannot observe on their own.
 *
 * The valid fixtures ({@link MOVING_CHAINED}) prove a correct file decodes correctly; these
 * mutate one and hand-build a couple of small files so a failure points at a specific rule:
 * per-gaussian validity-window pitch (§6.3), chunk-level compression (§5.5/§5.18), the
 * group-count (§5.18), cross-level (§11.6), index/record (§5.8/§11.9) and full-timeline
 * (§11.1) refusals.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  Attribute,
  MalformedFile,
  Opcode,
  RECORD_HEADER_BYTES,
  UnsupportedCodec,
  checkTiling,
  decodeChunkStreams,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decompressChunkBlock,
  iterateRecords,
  keyframeDeltaChunkAt,
  keyframeDeltaStatesJson,
  reconstructKeyframeDelta,
  keyframeDeltaValidationRecordOffset,
  iterateRecords,
  parseChunkIndexEntry,
  DEFAULT_CODECS,
  lifeClass,
  motionStep,
  supportK,
  validateKeyframeDeltaStreamed,
} from "@4dgs/core";
import { validateFile } from "@4dgs/nodejs";

import { num } from "./canonical.js";
import { MOVING_CHAINED } from "./keyframeDeltaFixtures.js";
import { concat, deflate, encodeTestStream, record } from "./testing.js";

function bytes(b64: string): Uint8Array {
  return new Uint8Array(Buffer.from(b64, "base64"));
}

// --- little-endian wire builders ------------------------------------------

const MAGIC = new Uint8Array([0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0d, 0x0a]);
const enc = new TextEncoder();

function f64(v: number): Uint8Array {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setFloat64(0, v, true);
  return b;
}
function u32(v: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, v, true);
  return b;
}
function u16(v: number): Uint8Array {
  const b = new Uint8Array(2);
  new DataView(b.buffer).setUint16(0, v, true);
  return b;
}
function u64(v: number): Uint8Array {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, BigInt(v), true);
  return b;
}
function str(s: string): Uint8Array {
  const body = enc.encode(s);
  return concat([u32(body.length), body]);
}
/** An empty `map<string,string>`: a u32 block length of 0. */
const EMPTY_MAP = u32(0);

const STEPS = {
  pos: 0.001,
  scaleLog: 0.01,
  rot: 0.001,
  rgb: 0.01,
  alpha: 0.01,
  motion: 0.01,
  time: 0.01,
  sigmaLog: 0.01,
};

function headerBody(durationSec: number, shDegree = 0, gaussianCount = 1): Uint8Array {
  return concat([
    str(""), // profile
    str(""), // library
    f64(durationSec),
    u64(gaussianCount),
    f64(0.05), // cutoff
    str("keyframe-delta"),
    f64(0),
    f64(0),
    f64(0),
    f64(0),
    f64(0),
    f64(0), // aabb
    new Uint8Array([shDegree]), // sh_degree
    new Uint8Array([0]), // flags
    EMPTY_MAP,
  ]);
}

async function shBandRecord(band: number, values: number[], channels: number): Promise<Uint8Array> {
  const stream = await encodeTestStream({
    attributeId: 0x07,
    values,
    channels,
    symbolWidth: 2,
  });
  return record(0x07, concat([new Uint8Array([band]), stream]));
}

function quantizationBody(): Uint8Array {
  return concat([
    str("uniform-v1"),
    f64(0),
    f64(0),
    f64(0), // pos_origin
    f64(STEPS.pos),
    f64(STEPS.scaleLog),
    f64(STEPS.rot),
    f64(STEPS.rgb),
    f64(STEPS.alpha),
    f64(STEPS.motion),
    f64(STEPS.time),
    f64(STEPS.sigmaLog),
    new Uint8Array([0]), // step_sh
    EMPTY_MAP, // bounds
  ]);
}

function windowTableBody(windows: readonly (readonly [number, number])[]): Uint8Array {
  const parts = [u32(windows.length)];
  for (const [lo, hi] of windows) parts.push(f64(lo), f64(hi));
  return concat(parts);
}

/** One never-fading gaussian at `windowIndex`, drifting on x by `motionBinX` bins. */
async function oneGaussianStreams(
  windowIndex: number,
  motionBinX: number,
  objectId?: number,
  options: {
    id?: number;
    idChannels?: number;
    rotationChannels?: number;
    muTBin?: number;
    sigmaTBin?: number;
    flags?: number;
  } = {},
): Promise<Uint8Array> {
  const s = (attributeId: number, values: number[], channels: number) =>
    encodeTestStream({ attributeId, values, channels });
  const membership = objectId === undefined ? [] : [s(Attribute.ObjectId, [objectId], 1)];
  // One row either way: three channels is what the registry defines, and a one-channel
  // rotation is the malformed shape whose element count still matches the chunk's.
  const rotationChannels = options.rotationChannels ?? 3;
  const rotation = rotationChannels === 3 ? [0, 0, 0] : [0];
  return concat(
    await Promise.all([
      ...membership,
      s(
        Attribute.GaussianId,
        options.idChannels === 2 ? [options.id ?? 0, 123] : [options.id ?? 0],
        options.idChannels ?? 1,
      ),
      s(Attribute.Position, [0, 0, 0], 3),
      s(Attribute.Scale, [0, 0, 0], 3),
      s(Attribute.RotationIndex, [3], 1),
      s(Attribute.Rotation, rotation, rotationChannels),
      s(Attribute.Color, [0, 0, 0], 3),
      s(Attribute.Opacity, [0], 1),
      s(Attribute.Motion, [motionBinX, 0, 0], 3),
      s(Attribute.MuT, [options.muTBin ?? 0], 1),
      s(Attribute.SigmaT, [options.sigmaTBin ?? 0], 1),
      s(Attribute.Flags, [options.flags ?? 1], 1), // never fades by default
      s(Attribute.WindowIndex, [windowIndex], 1),
    ]),
  );
}

/** The same streams a `gaussian-birth` chunk carries: everything but the identity. */
async function threeChannelStreams(options: { rotationChannels: number }): Promise<Uint8Array> {
  return oneGaussianStreams(0, 0, undefined, options);
}

/**
 * A Delta Chunk record (spec §5.18) over `[t0, t1)` referencing `referenceOffset`, with
 * one birth and nothing else.
 *
 * Written by hand rather than by an encoder, because the file this pins — a keyframe with
 * no `object_id` and a birth that has one — is legal, unrepresentable in the corpus today,
 * and exactly the shape the composition bug lived in.
 */
function deltaChunkRecord(options: {
  t0: number;
  t1: number;
  referenceOffset: number;
  births: Uint8Array;
  deltaMode?: number;
  keyframeOffset?: number;
  depth?: number;
}): Uint8Array {
  const blob = concat([u64(0), u64(options.births.length), options.births, u64(0)]);
  const body = concat([
    f64(options.t0),
    f64(options.t1),
    u32(0), // level
    new Uint8Array([options.deltaMode ?? 0]),
    u64(options.referenceOffset),
    u64(options.keyframeOffset ?? options.referenceOffset),
    u16(options.depth ?? 1),
    u32(0), // update_count
    u32(1), // birth_count
    u32(0), // death_count
    str(""), // compression
    u64(blob.length),
    u64(blob.length),
    blob,
  ]);
  return record(0x10, body);
}

function updateDeltaChunkRecord(options: {
  t0: number;
  t1: number;
  referenceOffset: number;
  updates: Uint8Array;
}): Uint8Array {
  const blob = concat([u64(options.updates.length), options.updates, u64(0), u64(0)]);
  return record(
    0x10,
    concat([
      f64(options.t0),
      f64(options.t1),
      u32(0),
      new Uint8Array([0]),
      u64(options.referenceOffset),
      u64(options.referenceOffset),
      new Uint8Array([1, 0]),
      u32(1),
      u32(0),
      u32(0),
      str(""),
      u64(blob.length),
      u64(blob.length),
      blob,
    ]),
  );
}

/**
 * A keyframe with one gaussian and no `object_id`, then a delta that births one with it.
 *
 * §6.6 makes membership optional per chunk and defines the omission as `0`, so this file
 * conforms; what it asks of a decoder is that the column the birth introduces be as long
 * as the population it lands in.
 */
async function keyframeThenBirthFile(options: {
  born: number;
  objectId?: number;
  keyframeObjectId?: number;
  birthIdChannels?: number;
}): Promise<Uint8Array> {
  const keyframeStreams = await oneGaussianStreams(0, 0, options.keyframeObjectId);
  const keyframe = chunkRecord(0, 0.5, keyframeStreams, "", keyframeStreams.length);
  const front = concat([
    MAGIC,
    record(0x01, headerBody(1)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
  ]);
  const births = await oneGaussianStreams(0, 0, options.objectId, {
    id: options.born,
    ...(options.birthIdChannels === undefined ? {} : { idChannels: options.birthIdChannels }),
  });
  return concat([
    front,
    keyframe,
    deltaChunkRecord({ t0: 0.5, t1: 1, referenceOffset: front.length, births }),
  ]);
}

async function keyframeThenBirthShFile(): Promise<Uint8Array> {
  const keyframeStreams = await oneGaussianStreams(0, 0);
  const keyframe = chunkRecord(0, 0.5, keyframeStreams, "", keyframeStreams.length);
  const front = concat([
    MAGIC,
    record(0x01, headerBody(1, 1)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
  ]);
  const births = await oneGaussianStreams(0, 0, undefined, { id: 7 });
  const keyframeBand = await shBandRecord(
    1,
    Array.from({ length: 9 }, (_, i) => i + 1),
    9,
  );
  const birthBand = await shBandRecord(
    1,
    Array.from({ length: 9 }, (_, i) => 101 + i),
    9,
  );
  return concat([
    front,
    keyframe,
    keyframeBand,
    deltaChunkRecord({ t0: 0.5, t1: 1, referenceOffset: front.length, births }),
    birthBand,
  ]);
}

async function keyframeThenManyBirthsShFile(birthCount: number): Promise<Uint8Array> {
  const intervals = birthCount + 1;
  const keyframeStreams = await oneGaussianStreams(0, 0);
  const front = concat([
    MAGIC,
    record(0x01, headerBody(1, 1, birthCount + 1)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
  ]);
  const keyframeOffset = front.length;
  const keyframe = chunkRecord(0, 1 / intervals, keyframeStreams, "", keyframeStreams.length);
  const firstBand = await shBandRecord(
    1,
    Array.from({ length: 9 }, (_, i) => i + 1),
    9,
  );
  const parts: Uint8Array[] = [front, keyframe, firstBand];
  let length = front.length + keyframe.length + firstBand.length;
  let referenceOffset = keyframeOffset;
  for (let birth = 1; birth <= birthCount; birth++) {
    const births = await oneGaussianStreams(0, 0, undefined, { id: birth });
    const deltaOffset = length;
    const delta = deltaChunkRecord({
      t0: birth / intervals,
      t1: (birth + 1) / intervals,
      referenceOffset,
      keyframeOffset,
      deltaMode: 1,
      depth: birth,
      births,
    });
    const band = await shBandRecord(
      1,
      Array.from({ length: 9 }, (_, i) => birth * 10 + i + 1),
      9,
    );
    parts.push(delta, band);
    length += delta.length + band.length;
    referenceOffset = deltaOffset;
  }
  return concat(parts);
}

/**
 * A Chunk record (spec §5.5): `t0, t1, level, count, compression, uncompressed_size`, then
 * a length-framed records blob. `uncompressedSize` is the decompressed byte count — equal
 * to the blob length when the codec is empty.
 */
function chunkRecord(
  t0: number,
  t1: number,
  blob: Uint8Array,
  compression: string,
  uncompressedSize: number,
  count = 1,
): Uint8Array {
  const body = concat([
    f64(t0),
    f64(t1),
    u32(0), // level
    u32(count),
    str(compression),
    u64(uncompressedSize),
    u64(blob.length),
    blob,
  ]);
  return record(0x05, body);
}

/** A whole one-keyframe file: magic, Header, Quantization, Window Table, one Chunk. */
async function oneKeyframeFile(options: {
  windows: readonly (readonly [number, number])[];
  windowIndex: number;
  motionBinX: number;
  duration: number;
  compress?: boolean;
  objectId?: number;
  idChannels?: number;
  rotationChannels?: number;
  muTBin?: number;
  sigmaTBin?: number;
  flags?: number;
}): Promise<Uint8Array> {
  const rawStreams = await oneGaussianStreams(
    options.windowIndex,
    options.motionBinX,
    options.objectId,
    {
      ...(options.idChannels === undefined ? {} : { idChannels: options.idChannels }),
      ...(options.rotationChannels === undefined
        ? {}
        : { rotationChannels: options.rotationChannels }),
      ...(options.muTBin === undefined ? {} : { muTBin: options.muTBin }),
      ...(options.sigmaTBin === undefined ? {} : { sigmaTBin: options.sigmaTBin }),
      ...(options.flags === undefined ? {} : { flags: options.flags }),
    },
  );
  const blob = options.compress ? await deflate(rawStreams) : rawStreams;
  const chunk = chunkRecord(
    0,
    options.duration,
    blob,
    options.compress ? "deflate" : "",
    rawStreams.length,
  );
  return concat([
    MAGIC,
    record(0x01, headerBody(options.duration)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody(options.windows)),
    chunk,
  ]);
}

/** One SH-bearing keyframe with a complete index, Footer and trailing magic. */
async function oneKeyframeShFile(
  options: { indexASecondBand?: boolean } = {},
): Promise<Uint8Array> {
  const streams = await oneGaussianStreams(0, 0);
  const front = concat([
    MAGIC,
    record(0x01, headerBody(1, 1)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
  ]);
  const chunk = chunkRecord(0, 1, streams, "", streams.length);
  const chunkOffset = front.length;
  const bandValues = Array.from({ length: 9 }, (_, i) => 240 - i);
  const band = await shBandRecord(1, bandValues, 9);
  const bandOffset = chunkOffset + chunk.length;
  const secondBand = options.indexASecondBand
    ? await shBandRecord(
        1,
        Array.from({ length: 9 }, (_, i) => 120 - i),
        9,
      )
    : new Uint8Array(0);
  const indexedBandOffset = bandOffset + (options.indexASecondBand ? band.length : 0);
  const summaryStart = bandOffset + band.length + secondBand.length;
  const index = record(
    0x08,
    concat([
      f64(0),
      f64(1),
      u64(chunkOffset),
      u64(chunk.length),
      u32(1),
      u32(1),
      new Uint8Array([1]),
      u64(indexedBandOffset),
      u64(options.indexASecondBand ? secondBand.length : band.length),
      new Uint8Array([0, 0]), // keyframe, no delta mode
      u64(0),
      u64(chunkOffset),
      u16(0),
      u64(1),
    ]),
  );
  const footer = record(0x02, concat([u64(summaryStart), u64(0), u32(0)]));
  return concat([front, chunk, band, secondBand, index, footer, MAGIC]);
}

// --- per-gaussian validity window (codex P1 §6.3) -------------------------

test("motion precision follows each gaussian's own validity window, not window 0", async () => {
  const motionBinX = 10;
  // Window 0 is long (4 s), window 1 short (0.02 s). The gaussian references window 1, so
  // its velocity pitch must come from window 1 — a decoder using window 0 reconstructs a
  // very different, wrong centre. The timeline is the short window's, so the probe lands
  // inside it: a probe outside would test the §3 gate below instead of the pitch.
  const duration = 0.02;
  const file = await oneKeyframeFile({
    windows: [
      [0, 4],
      [0, duration],
    ],
    windowIndex: 1,
    motionBinX,
    duration,
  });
  const summary = keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(file));
  const states = summary.states as { t: number; sample: { positions: number[][] } }[];
  const k = supportK(0.05);
  const pitch = (winLen: number) =>
    motionStep(lifeClass(0, STEPS.sigmaLog, true, winLen, k), STEPS.motion);
  const probe = states.find((row) => row.t === 0.01)!;
  const centerX = probe.sample.positions[0]![0]!;
  assert.equal(centerX, num(motionBinX * pitch(duration) * 0.01));
  assert.notEqual(pitch(duration), pitch(4));
  assert.notEqual(centerX, num(motionBinX * pitch(4) * 0.01));
});

test("a gaussian whose validity window has closed is absent, not transparent", async () => {
  // The window shuts at 0.02 s and the timeline runs to 1 s. Section 3 makes the window a
  // hard gate: past it the gaussian does not exist, so it leaves the population rather than
  // fading — id, centre, scale and liveCount all drop it, exactly as the gaussian-birth
  // path decides it. Reporting it at full opacity at t = 0.5 is what this pins against.
  const file = await oneKeyframeFile({
    windows: [[0, 0.02]],
    windowIndex: 0,
    motionBinX: 10,
    duration: 1,
  });
  const sequence = await decodeKeyframeDeltaStreamed(file);
  const summary = keyframeDeltaStatesJson(sequence);
  const states = summary.states as { t: number; liveCount: string }[];
  assert.equal(states.find((row) => row.t === 0)!.liveCount, "1");
  assert.equal(states.find((row) => row.t === 0.5)!.liveCount, "0");
  // The chunk's composed population is unchanged — one gaussian, all the way across. It is
  // the instant that has no gaussian in it, not the chunk.
  assert.equal(sequence.chunks[0]!.state.count, 1);
  const chunk = keyframeDeltaChunkAt(sequence, 0.5);
  assert.equal(reconstructKeyframeDelta(sequence, chunk, 0.01).count, 1);
  const absent = reconstructKeyframeDelta(sequence, chunk, 0.5);
  assert.equal(absent.count, 0);
  assert.equal(absent.ids.buffer.byteLength, 0);
  assert.equal(absent.centers.buffer.byteLength, 0);
  assert.equal(absent.rotations.buffer.byteLength, 0);
});

test("a gaussian below the temporal marginal cutoff is absent inside its window", async () => {
  // The hard validity window admits this row for the whole second. Its finite temporal
  // Gaussian is centred at zero and narrow, so near the end the marginal is below
  // the Header cutoff and the reconstructed state must omit it rather than retain a
  // practically transparent row.
  const file = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
    muTBin: 0,
    sigmaTBin: -100,
    flags: 0,
  });
  const sequence = await decodeKeyframeDeltaStreamed(file);
  const chunk = keyframeDeltaChunkAt(sequence, 0.95);
  assert.equal(reconstructKeyframeDelta(sequence, chunk, 0).count, 1);
  assert.equal(reconstructKeyframeDelta(sequence, chunk, 0.95).count, 0);
});

test("object membership is carried through the reconstruction where a chunk has it", async () => {
  // `object_id` is optional on a keyframe-delta chunk (spec §6.6), so the reconstruction
  // reports `null` for a file without it and the ids themselves for a file with it — not a
  // column of zeroes, which would read as "every gaussian is background". The id is read
  // unsigned, because the ids span the whole u32 range and a track compares them for
  // equality against a `u32`.
  const objectId = 0xfffffff0;
  const withMembership = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
    objectId,
  });
  const sequence = await decodeKeyframeDeltaStreamed(withMembership);
  const g = reconstructKeyframeDelta(sequence, keyframeDeltaChunkAt(sequence, 0.5), 0.5);
  assert.equal(g.count, 1);
  assert.deepEqual([...g.objectId!], [objectId]);

  const without = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
  });
  const plain = await decodeKeyframeDeltaStreamed(without);
  assert.equal(
    reconstructKeyframeDelta(plain, keyframeDeltaChunkAt(plain, 0.5), 0.5).objectId,
    null,
  );
});

test("keyframe-delta reconstruction preserves SH on both paths and across a birth", async () => {
  const indexedFile = await oneKeyframeShFile();
  const streamed = await decodeKeyframeDeltaStreamed(indexedFile);
  const indexed = (await decodeKeyframeDeltaIndexed(indexedFile)).sequence;
  const expected = Array.from({ length: 9 }, (_, i) => 240 - i);
  for (const sequence of [streamed, indexed]) {
    const state = reconstructKeyframeDelta(sequence, keyframeDeltaChunkAt(sequence, 0.5), 0.5);
    assert.equal(state.sh?.degree, 1);
    assert.equal(state.sh?.coefficients, 3);
    assert.equal(state.sh?.count, 1);
    assert.deepEqual([...(state.sh?.values ?? [])], expected);
  }

  // A Delta Chunk's band rows belong to its births. Existing rows inherit the keyframe's
  // coefficients; the newly born row is appended, and the public state follows the same
  // gaussian-id order as every other reconstructed attribute.
  const withBirth = await decodeKeyframeDeltaStreamed(await keyframeThenBirthShFile());
  const after = reconstructKeyframeDelta(withBirth, keyframeDeltaChunkAt(withBirth, 0.75), 0.75);
  assert.deepEqual([...after.ids], [0, 7]);
  assert.deepEqual(
    [...after.sh!.values],
    [
      ...Array.from({ length: 9 }, (_, i) => i + 1),
      ...Array.from({ length: 9 }, (_, i) => 101 + i),
    ],
  );
});

test("a streamed SH band must immediately follow the state record it extends", async () => {
  const data = await oneKeyframeShFile();
  const band = [...iterateRecords(data, MAGIC.length)].find((item) => item.opcode === 0x07)!;
  const unrelated = record(0x80, new Uint8Array([1]));
  const interleaved = concat([
    data.subarray(0, band.offset),
    unrelated,
    data.subarray(band.offset),
  ]);

  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(interleaved),
    (error: unknown) =>
      error instanceof MalformedFile && error.message.includes("carries SH bands none"),
  );
});

test("an indexed SH range must trail the state chunk that owns it", async () => {
  // Both records are individually valid band-1 streams with the right row shape. Only the first
  // physically trails the Chunk; pointing the index at the second used to let the indexed path
  // reconstruct different coefficients from the streamed path.
  const misplaced = await oneKeyframeShFile({ indexASecondBand: true });
  await assert.rejects(
    () => decodeKeyframeDeltaIndexed(misplaced),
    (error: unknown) =>
      error instanceof MalformedFile &&
      error.message.includes("its trailing SH records place that band at byte"),
  );
});

test("an append-only SH birth chain reconstructs every persistent segment", async () => {
  const births = 12;
  const sequence = await decodeKeyframeDeltaStreamed(await keyframeThenManyBirthsShFile(births));
  assert.equal(sequence.chunks.length, births + 1);
  const state = reconstructKeyframeDelta(sequence, sequence.chunks.at(-1)!, 0.99);
  assert.deepEqual(
    [...state.ids],
    Array.from({ length: births + 1 }, (_, id) => id),
  );
  const expected = Array.from({ length: births + 1 }, (_, row) =>
    Array.from({ length: 9 }, (_, i) => (row === 0 ? i + 1 : row * 10 + i + 1)),
  ).flat();
  assert.deepEqual([...state.sh!.values], expected);
});

test("an out-of-range window index is refused, not clamped", async () => {
  const file = await oneKeyframeFile({
    windows: [[0, 1]], // only window 0 exists
    windowIndex: 3,
    motionBinX: 1,
    duration: 1,
  });
  // The window index is used when the pitch is derived, i.e. during reconstruction.
  const decoded = await decodeKeyframeDeltaStreamed(file);
  const chunkOffset = decoded.chunks[0]!.offset;
  assert.throws(
    () => keyframeDeltaStatesJson(decoded),
    (error: unknown) =>
      error instanceof MalformedFile &&
      error.message.includes(`keyframe-delta chunk at byte ${chunkOffset}, gaussian id 0`) &&
      error.message.includes("window index 3 is outside the 1-entry window table"),
  );
});

test("decoded validation checks window indices and locates the refusing state record", async () => {
  const file = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 3,
    motionBinX: 1,
    duration: 1,
  });
  const chunkOffset =
    MAGIC.length +
    record(0x01, headerBody(1)).length +
    record(0x03, quantizationBody()).length +
    record(0x04, windowTableBody([[0, 1]])).length;
  let rejected: unknown;
  try {
    await validateKeyframeDeltaStreamed(file);
  } catch (error) {
    rejected = error;
  }
  assert.ok(rejected instanceof MalformedFile);
  assert.equal(keyframeDeltaValidationRecordOffset(rejected), chunkOffset);

  const report = await validateFile(file, { decode: true });
  assert.equal(report.refused?.code, "window-index-out-of-range");
  assert.equal(report.refused?.at, chunkOffset);
});

test("decoded validation keeps the earliest refusal across validation passes", async () => {
  const file = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 3,
    motionBinX: 1,
    duration: 1,
  });
  const chunk = [...iterateRecords(file, MAGIC.length)].find(
    (item) => item.opcode === Opcode.Chunk,
  )!;
  const badBandStream = await encodeTestStream({
    attributeId: Opcode.ShBandStream,
    values: Array(9).fill(0),
    channels: 9,
    codec: 9,
  });
  const withLaterRefusal = concat([
    file,
    record(Opcode.ShBandStream, concat([new Uint8Array([1]), badBandStream])),
  ]);
  const report = await validateFile(withLaterRefusal, { decode: true });
  assert.equal(report.refused?.code, "window-index-out-of-range");
  assert.equal(report.refused?.at, chunk.offset);
});

test("a keyframe's decoded row count must match its Chunk header", async () => {
  const file = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
  });
  const chunk = [...iterateRecords(file, MAGIC.length)].find(
    (item) => item.opcode === Opcode.Chunk,
  )!;
  new DataView(file.buffer, file.byteOffset, file.byteLength).setUint32(
    chunk.offset + RECORD_HEADER_BYTES + 20,
    0,
    true,
  );
  await assert.rejects(
    () => validateKeyframeDeltaStreamed(file),
    (error: unknown) =>
      error instanceof MalformedFile &&
      error.message.includes("declares 0 gaussians") &&
      error.message.includes("attribute streams carry 1"),
  );
});

test("keyframe-delta requires extended Chunk Index entries", async () => {
  const file = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
  });
  const chunk = [...iterateRecords(file, MAGIC.length)].find(
    (item) => item.opcode === Opcode.Chunk,
  )!;
  const legacyIndex = record(
    Opcode.ChunkIndex,
    concat([f64(0), f64(1), u64(chunk.offset), u64(chunk.raw.length), u32(1), u32(0)]),
  );
  const report = await validateFile(concat([file, legacyIndex]));
  assert.ok(
    report.findings.some((finding) =>
      finding.message.includes("omits chunk_kind, delta reference, depth and live_count"),
    ),
  );
});

test("a delta index count must equal the Delta Chunk's three group counts", async () => {
  const file = bytes(MOVING_CHAINED);
  const entry = [...iterateRecords(file, MAGIC.length)].find(
    (item) => item.opcode === Opcode.ChunkIndex && parseChunkIndexEntry(item.content).kind === 1,
  )!;
  const view = new DataView(file.buffer, file.byteOffset, file.byteLength);
  const countAt = entry.offset + RECORD_HEADER_BYTES + 32;
  view.setUint32(countAt, view.getUint32(countAt, true) + 1, true);
  const report = await validateFile(file);
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes("affected gaussians") &&
        finding.message.includes("across its groups"),
    ),
  );
});

test("known-record parse findings include the enclosing record byte", async () => {
  const report = await validateFile(concat([MAGIC, record(Opcode.Camera, new Uint8Array())]));
  assert.ok(
    report.findings.some((finding) =>
      finding.message.includes(`Camera record at byte ${MAGIC.length} does not parse`),
    ),
  );
});

// --- chunk-level compression (codex P1 §5.5/§5.18) ------------------------

test("a chunk-level compressed keyframe decodes to the same state as its plain twin", async () => {
  const opts = {
    windows: [[0, 1]] as const,
    windowIndex: 0,
    motionBinX: 5,
    duration: 1,
  };
  const plain = keyframeDeltaStatesJson(
    await decodeKeyframeDeltaStreamed(await oneKeyframeFile({ ...opts })),
  );
  const compressed = keyframeDeltaStatesJson(
    await decodeKeyframeDeltaStreamed(await oneKeyframeFile({ ...opts, compress: true })),
  );
  assert.equal(JSON.stringify(compressed), JSON.stringify(plain));
});

test("decompressChunkBlock passes an empty codec through and refuses an unknown one", async () => {
  const payload = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const through = await decompressChunkBlock(payload, "", payload.length, DEFAULT_CODECS, "x");
  assert.deepEqual([...through], [...payload]);
  const restored = await decompressChunkBlock(
    await deflate(payload),
    "deflate",
    payload.length,
    DEFAULT_CODECS,
    "x",
  );
  assert.deepEqual([...restored], [...payload]);
  await assert.rejects(
    () => decompressChunkBlock(payload, "brotli", payload.length, DEFAULT_CODECS, "x"),
    (e: unknown) => e instanceof UnsupportedCodec,
  );
  // An uncompressed block whose declared size does not match its bytes is refused (§5.5).
  await assert.rejects(
    () => decompressChunkBlock(payload, "", payload.length + 1, DEFAULT_CODECS, "x"),
    (e: unknown) => e instanceof MalformedFile,
  );
});

// --- full-timeline tiling (codex P2 §11.1) --------------------------------

test("checkTiling: adjacency always, coverage only when required", () => {
  const at = (t0: number, t1: number) => ({ t0, t1 });
  assert.throws(() => checkTiling([at(0, 1), at(2, 3)]), MalformedFile); // gap
  assert.throws(() => checkTiling([at(0, 2), at(1, 3)]), MalformedFile); // overlap
  assert.throws(() => checkTiling([at(0, 2), at(2, 1)], 1, true), MalformedFile); // inverted
  assert.throws(() => checkTiling([], 1), MalformedFile); // duration but no chunks
  checkTiling([at(0, 1), at(1, 2)], 2); // complete: no throw

  // Streamed contract (adjacency only): a complete PREFIX whose last chunk stops short of
  // duration_sec is tolerated, so a streamed reader stays usable on a truncated file (§11.10).
  checkTiling([at(0, 1)], 2); // prefix, no coverage required: no throw

  // Indexed contract (requireFullCoverage): a complete file must cover [0, duration_sec).
  assert.throws(() => checkTiling([at(0, 1)], 2, true), MalformedFile); // ends before duration
  assert.throws(() => checkTiling([at(0.5, 1)], 1, true), MalformedFile); // starts after 0
  checkTiling([at(0, 1), at(1, 2)], 2, true); // full coverage: no throw
});

test("streamed validation reports each composed live population without retaining states", async () => {
  const data = bytes(MOVING_CHAINED);
  const expected = (await decodeKeyframeDeltaStreamed(data)).chunks.map((chunk) => [
    chunk.offset,
    chunk.state.count,
  ]);
  const observed: [number, number][] = [];
  await validateKeyframeDeltaStreamed(data, DEFAULT_CODECS, (offset, liveCount) => {
    observed.push([offset, liveCount]);
  });
  assert.deepEqual(observed, expected);
});

test("streamed validation checks timeline adjacency after sorting state intervals", async () => {
  const frontMatter = [
    MAGIC,
    record(0x01, headerBody(2)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 2]])),
  ];
  const streams = await oneGaussianStreams(0, 0);
  const file = concat([
    ...frontMatter,
    chunkRecord(1, 2, streams, "", streams.length),
    chunkRecord(0, 1, streams, "", streams.length),
  ]);
  assert.equal(await validateKeyframeDeltaStreamed(file), 1);
});

test("streamed validation refuses a gaussian id reused after a temporal gap", async () => {
  const frontMatter = [
    MAGIC,
    record(0x01, headerBody(3, 0, 2)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 3]])),
  ];
  const first = await oneGaussianStreams(0, 0, undefined, { id: 0 });
  const middle = await oneGaussianStreams(0, 0, undefined, { id: 1 });
  const last = await oneGaussianStreams(0, 0, undefined, { id: 0 });
  const firstChunk = chunkRecord(0, 1, first, "", first.length);
  const middleChunk = chunkRecord(1, 2, middle, "", middle.length);
  const lastChunk = chunkRecord(2, 3, last, "", last.length);
  const lastOffset =
    frontMatter.reduce((sum, part) => sum + part.length, 0) +
    firstChunk.length +
    middleChunk.length;
  const file = concat([...frontMatter, firstChunk, middleChunk, lastChunk]);
  await assert.rejects(
    () => validateKeyframeDeltaStreamed(file),
    (error: unknown) =>
      error instanceof MalformedFile &&
      error.message.includes("reintroduces gaussian id 0 after it died") &&
      keyframeDeltaValidationRecordOffset(error) === lastOffset,
  );
});

test("a streamed decode reads a complete prefix and bounds probes to the last chunk", async () => {
  const data = bytes(MOVING_CHAINED);
  const { sequence, index } = await decodeKeyframeDeltaIndexed(data);
  assert.ok(index.length >= 3, "fixture has several chunks");
  // Cut the file at the end of the second chunk record — before the index and Footer — so
  // the streamed reader sees Header/Quantization/Window Table and the first two chunks only.
  const cut = index[1]!.chunkOffset + index[1]!.chunkLength;
  const prefix = data.slice(0, cut);
  const decoded = await decodeKeyframeDeltaStreamed(prefix);
  assert.equal(decoded.chunks.length, 2);
  const lastT1 = decoded.chunks[decoded.chunks.length - 1]!.t1;
  assert.ok(lastT1 < sequence.header.durationSec);
  // It reconstructs rather than refusing the short tiling, and no probe extrapolates past
  // the last complete chunk — every state's instant lies within the decoded prefix.
  const states = keyframeDeltaStatesJson(decoded).states as { t: number }[];
  assert.ok(states.length > 0);
  assert.ok(states.every((s) => s.t < lastT1));

  // And a seek into the tail the cut removed is refused rather than answered with the last
  // state before it. The end-of-timeline convenience — `t` at or past the end resolves to
  // the last chunk — is for a complete file; here the missing bytes are what said what
  // happens at that instant, so handing back the state before the cut would be the decoder
  // inventing content. The indexed path already refuses it; both do now.
  assert.equal(keyframeDeltaChunkAt(decoded, lastT1 - 1e-9).t1, lastT1);
  assert.throws(
    () => keyframeDeltaChunkAt(decoded, lastT1),
    (error: unknown) =>
      error instanceof MalformedFile && /this timeline ends at/.test(error.message),
  );
  assert.throws(
    () => keyframeDeltaChunkAt(decoded, sequence.header.durationSec - 1e-9),
    MalformedFile,
  );
  // The complete file keeps the convenience: its last chunk reaches duration_sec, so the
  // final instant and the boundary itself both resolve.
  assert.equal(
    keyframeDeltaChunkAt(sequence, sequence.header.durationSec).t1,
    sequence.header.durationSec,
  );
  for (const invalid of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => keyframeDeltaChunkAt(sequence, invalid), MalformedFile);
  }
});

test("a cut inside a trailing SH record drops only its incomplete state", async () => {
  const data = await keyframeThenBirthShFile();
  const framed = [...iterateRecords(data, MAGIC.length)];
  const trailingBand = framed[framed.length - 1]!;
  assert.equal(trailingBand.opcode, 0x07);

  // The band frame has arrived, but only one byte of its declared content has.
  const cut = data.slice(0, trailingBand.offset + 9 + 1);
  const decoded = await decodeKeyframeDeltaStreamed(cut);
  assert.equal(decoded.chunks.length, 1);
  const state = reconstructKeyframeDelta(decoded, decoded.chunks[0]!, 0.25);
  assert.equal(state.sh?.degree, 1);
  assert.deepEqual(
    [...state.sh!.values],
    Array.from({ length: 9 }, (_, i) => i + 1),
  );
});

test("the end boundary selects the temporally last chunk, not the physical last", async () => {
  const sequence = (await decodeKeyframeDeltaIndexed(bytes(MOVING_CHAINED))).sequence;
  const temporalLast = sequence.chunks.reduce((latest, chunk) =>
    chunk.t1 > latest.t1 ? chunk : latest,
  );
  const physicallyReordered = { ...sequence, chunks: [...sequence.chunks].reverse() };
  assert.notEqual(physicallyReordered.chunks.at(-1)!.offset, temporalLast.offset);
  assert.equal(
    keyframeDeltaChunkAt(physicallyReordered, sequence.header.durationSec).offset,
    temporalLast.offset,
  );
});

test("a birth that introduces object_id defaults the rows that came before it", async () => {
  // §6.6 makes membership optional per chunk and gives the omission a value: a state that
  // omits the stream is read as though every gaussian in it carried 0. So a background
  // keyframe with no `object_id` followed by a delta birth that has one is a legal file,
  // and the column it composes to must be as long as the population. Composed without the
  // default it was `birth_count` rows long against two ids, so the birth's membership
  // landed on the gaussian that was already there and the birth itself read past the end:
  // two gaussians in the wrong object, and no error anywhere.
  const born = 7;
  const objectId = 0xfffffff0;
  const file = await keyframeThenBirthFile({ born, objectId });
  const sequence = await decodeKeyframeDeltaStreamed(file);
  assert.equal(sequence.chunks.length, 2);

  const before = reconstructKeyframeDelta(sequence, sequence.chunks[0]!, 0.25);
  assert.equal(before.objectId, null, "the keyframe carries no membership at all");

  const after = reconstructKeyframeDelta(sequence, sequence.chunks[1]!, 0.75);
  assert.deepEqual([...after.ids], [0, born], "ascending gaussian_id");
  assert.deepEqual([...after.objectId!], [0, objectId]);
});

test("a birth that omits object_id defaults its new row to background", async () => {
  const existingObject = 42;
  const born = 7;
  const file = await keyframeThenBirthFile({ born, keyframeObjectId: existingObject });
  const sequence = await decodeKeyframeDeltaStreamed(file);
  const after = reconstructKeyframeDelta(sequence, sequence.chunks[1]!, 0.75);
  assert.deepEqual([...after.ids], [0, born]);
  assert.deepEqual([...after.objectId!], [existingObject, 0]);
});

test("a streamless empty keyframe reconstructs as empty state", async () => {
  const empty = new Uint8Array(0);
  const file = concat([
    MAGIC,
    record(0x01, headerBody(1, 0, 0)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
    chunkRecord(0, 1, empty, "", 0, 0),
  ]);
  const sequence = await decodeKeyframeDeltaStreamed(file);
  const reconstructed = reconstructKeyframeDelta(sequence, sequence.chunks[0]!, 0.5);
  assert.equal(reconstructed.count, 0);
  assert.equal(reconstructed.ids.byteLength, 0);
  assert.equal(reconstructed.centers.byteLength, 0);
  assert.equal(reconstructed.sh, null);
});

test("an update restates rotation_index and rotation together", async () => {
  const keyframeStreams = await oneGaussianStreams(0, 0);
  const keyframe = chunkRecord(0, 0.5, keyframeStreams, "", keyframeStreams.length);
  const front = concat([
    MAGIC,
    record(0x01, headerBody(1)),
    record(0x03, quantizationBody()),
    record(0x04, windowTableBody([[0, 1]])),
  ]);
  const updates = concat(
    await Promise.all([
      encodeTestStream({ attributeId: Attribute.GaussianId, values: [0], channels: 1 }),
      encodeTestStream({ attributeId: Attribute.RotationIndex, values: [2], channels: 1 }),
    ]),
  );
  const file = concat([
    front,
    keyframe,
    updateDeltaChunkRecord({
      t0: 0.5,
      t1: 1,
      referenceOffset: front.length,
      updates,
    }),
  ]);
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(file),
    (error: unknown) =>
      error instanceof MalformedFile &&
      /restate rotation_index and all three rotation bins together/.test(error.message),
  );
});

test("an attribute stream whose channel width is not the registry's is refused", async () => {
  // The row count does not pin the shape. A `rotation` column declaring one channel and
  // the right element count passed every check and then met a reader that indexes
  // `values[i * 3 + c]`: it read the next row's bin as this row's second component, and
  // `undefined` past the end, which arithmetic turns into a NaN quaternion. The rule was
  // enforced for `object_id` alone; it is the registry's rule for every attribute it names.
  const wrong = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
    rotationChannels: 1,
  });
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(wrong),
    (error: unknown) =>
      error instanceof MalformedFile &&
      /attribute 3 .*declares 1 channels, the format defines 3/.test(error.message),
  );

  // The same streams read as a `gaussian-birth` chunk: the check belongs to both paths,
  // because a delta group's columns never pass through the chunk decoder.
  const streams = await threeChannelStreams({ rotationChannels: 1 });
  await assert.rejects(
    () =>
      decodeChunkStreams(streams, 1, {
        steps: { ...STEPS, sh: 1 },
        posOrigin: [0, 0, 0],
        windows: new Float64Array([0, 1]),
        supportK: supportK(0.05),
        codecs: DEFAULT_CODECS,
      }),
    (error: unknown) =>
      error instanceof MalformedFile &&
      /attribute 3 declares 1 channels, the format defines 3/.test(error.message),
  );
});

test("gaussian_id is one channel in keyframes and delta groups", async () => {
  const keyframe = await oneKeyframeFile({
    windows: [[0, 1]],
    windowIndex: 0,
    motionBinX: 0,
    duration: 1,
    idChannels: 2,
  });
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(keyframe),
    (error: unknown) =>
      error instanceof MalformedFile &&
      /attribute 13 .*declares 2 channels, the format defines 1/.test(error.message),
  );

  const birth = await keyframeThenBirthFile({
    born: 7,
    objectId: 9,
    birthIdChannels: 2,
  });
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(birth),
    (error: unknown) =>
      error instanceof MalformedFile &&
      /attribute 13 .*declares 2 channels, the format defines 1/.test(error.message),
  );
});

test("SH dimensions are checked before a constant stream can expand", async () => {
  const data = await oneKeyframeShFile();
  const band = [...iterateRecords(data, MAGIC.length)].find((record) => record.opcode === 0x07)!;
  const mutated = data.slice();
  const streamAt = band.offset + 9 + 1;
  mutated[streamAt + 2] = 2; // constant mode: nine payload symbols can claim many rows
  new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength).setUint32(
    streamAt + 5,
    7_000_000,
    true,
  );
  const expected = /SH band 1 carries 7000000 rows, expected 1/;
  await assert.rejects(() => decodeKeyframeDeltaStreamed(mutated), expected);
  await assert.rejects(() => decodeKeyframeDeltaIndexed(mutated), expected);
});

test("canonical summaries handle more chunks than V8's argument limit", async () => {
  const decoded = await decodeKeyframeDeltaStreamed(
    await oneKeyframeFile({
      windows: [[0, 1]],
      windowIndex: 0,
      motionBinX: 0,
      duration: 1,
    }),
  );
  const chunk = decoded.chunks[0]!;
  const chunks = Array.from({ length: 130_000 }, () => chunk);

  const summary = keyframeDeltaStatesJson({ ...decoded, chunks });
  assert.equal((summary.chunks as unknown[]).length, chunks.length);
});

// --- Delta Chunk header refusals, by mutating a valid file ----------------

/**
 * Content-field byte offsets inside a Delta Chunk record, after its 9-byte framing:
 * t0(0) t1(8) level(16) delta_mode(20) reference_offset(21) keyframe_offset(29)
 * depth(37) update_count(39) birth_count(43) death_count(47).
 */
const DELTA_LEVEL = 16;
const DELTA_DEPTH = 37;
const DELTA_UPDATE_COUNT = 39;

async function firstDelta(): Promise<{ data: Uint8Array; offset: number; updateCount: number }> {
  const data = bytes(MOVING_CHAINED);
  const decoded = await decodeKeyframeDeltaStreamed(data);
  const delta = decoded.chunks.find((c) => c.kind === 1 && (c.updateCount ?? 0) > 0)!;
  assert.ok(delta, "fixture has a delta chunk with updates");
  return { data, offset: delta.offset, updateCount: delta.updateCount! };
}

test("a Delta Chunk whose group count disagrees with its block is refused", async () => {
  const { data, offset } = await firstDelta();
  const mutated = data.slice();
  const view = new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength);
  const at = offset + 9 + DELTA_UPDATE_COUNT;
  view.setUint32(at, view.getUint32(at, true) + 1, true);
  await assert.rejects(() => decodeKeyframeDeltaStreamed(mutated), MalformedFile);
});

test("decoded validation derives delta depth from the streamed reference chain", async () => {
  const { data, offset } = await firstDelta();
  const mutated = data.slice();
  const view = new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength);
  view.setUint16(
    offset + 9 + DELTA_DEPTH,
    view.getUint16(offset + 9 + DELTA_DEPTH, true) + 4,
    true,
  );
  await assert.rejects(
    () => validateKeyframeDeltaStreamed(mutated),
    (error: unknown) =>
      error instanceof MalformedFile &&
      error.message.includes("reference chain has depth") &&
      keyframeDeltaValidationRecordOffset(error) === offset,
  );
});

test("a delta whose level differs from its reference is refused", async () => {
  const { data, offset } = await firstDelta();
  const mutated = data.slice();
  new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength).setUint32(
    offset + 9 + DELTA_LEVEL,
    1,
    true,
  );
  await assert.rejects(() => decodeKeyframeDeltaStreamed(mutated), MalformedFile);
});

test("indexed decode refuses a Delta Chunk header that disagrees with its index entry", async () => {
  const data = bytes(MOVING_CHAINED);
  const { index } = await decodeKeyframeDeltaIndexed(data);
  const delta = index.find((e) => e.kind === 1)!;
  const mutated = data.slice();
  const view = new DataView(mutated.buffer, mutated.byteOffset, mutated.byteLength);
  // Corrupt the header's depth so it disagrees with the (unchanged) index depth; the chain
  // walk uses the index and still composes, so only the cross-check can catch this.
  const at = delta.chunkOffset + 9 + DELTA_DEPTH;
  view.setUint16(at, view.getUint16(at, true) + 7, true);
  await assert.rejects(() => decodeKeyframeDeltaIndexed(mutated), MalformedFile);
});
