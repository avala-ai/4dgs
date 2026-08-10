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
  UnsupportedCodec,
  checkTiling,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decompressChunkBlock,
  keyframeDeltaChunkAt,
  keyframeDeltaStatesJson,
  reconstructKeyframeDelta,
  DEFAULT_CODECS,
  lifeClass,
  motionStep,
  supportK,
} from "@4dgs/core";

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

function headerBody(durationSec: number): Uint8Array {
  return concat([
    str(""), // profile
    str(""), // library
    f64(durationSec),
    u64(1), // gaussian_count
    f64(0.05), // cutoff
    str("keyframe-delta"),
    f64(0),
    f64(0),
    f64(0),
    f64(0),
    f64(0),
    f64(0), // aabb
    new Uint8Array([0]), // sh_degree
    new Uint8Array([0]), // flags
    EMPTY_MAP,
  ]);
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
): Promise<Uint8Array> {
  const s = (attributeId: number, values: number[], channels: number) =>
    encodeTestStream({ attributeId, values, channels });
  const membership = objectId === undefined ? [] : [s(Attribute.ObjectId, [objectId], 1)];
  return concat(
    await Promise.all([
      ...membership,
      s(Attribute.GaussianId, [0], 1),
      s(Attribute.Position, [0, 0, 0], 3),
      s(Attribute.Scale, [0, 0, 0], 3),
      s(Attribute.RotationIndex, [3], 1),
      s(Attribute.Rotation, [0, 0, 0], 3),
      s(Attribute.Color, [0, 0, 0], 3),
      s(Attribute.Opacity, [0], 1),
      s(Attribute.Motion, [motionBinX, 0, 0], 3),
      s(Attribute.MuT, [0], 1),
      s(Attribute.SigmaT, [0], 1),
      s(Attribute.Flags, [1], 1), // never fades
      s(Attribute.WindowIndex, [windowIndex], 1),
    ]),
  );
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
): Uint8Array {
  const body = concat([
    f64(t0),
    f64(t1),
    u32(0), // level
    u32(1), // count
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
}): Promise<Uint8Array> {
  const rawStreams = await oneGaussianStreams(
    options.windowIndex,
    options.motionBinX,
    options.objectId,
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
  assert.equal(reconstructKeyframeDelta(sequence, chunk, 0.5).count, 0);
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
