// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Unit tests for the pieces the conformance corpus cannot observe on its own.
 *
 * The corpus proves that a whole file decodes to the right gaussians. These prove the
 * parts underneath it against values chosen by hand — stream modes, symbol widths,
 * spherical harmonic layout, the errors a malformed file is supposed to produce — so a
 * failure points at a function rather than at a file.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BytesReadable,
  Crc32,
  Cursor,
  MalformedFile,
  MAX_TRAJECTORY_SAMPLES,
  TruncatedFile,
  parseRigTrajectory,
  parseObjectTrack,
  checkObjectTrack,
  checkObjectTable,
  ObjectLayer,
  quaternionNorm,
  checkRigTrajectory,
  poseAt,
  UnsupportedVersion,
  StreamDecoder,
  audioSourceStateAt,
  bandCoefficientRange,
  decodeScene,
  encodeScene,
  checkMagic,
  coefficientsForDegree,
  coefficientsInBand,
  crc32,
  decodeStream,
  frameOneStream,
  lifeClass,
  marginalAt,
  mergeBands,
  motionStep,
  muStep,
  rctInverse,
  supportK,
  unshuffleAndUnzigzag,
  DEFAULT_CODECS,
  MAGIC,
  Opcode,
} from "@4dgs/core";

import { roundHalfEven } from "./canonical.js";
import { MODE_CONST, MODE_DELTA, MODE_RAW, concat, encodeTestStream, record } from "./testing.js";

async function decodeOne(bytes: Uint8Array): Promise<Int32Array> {
  return decodeStream(frameOneStream(new Cursor(bytes)), DEFAULT_CODECS);
}

test("raw streams decode to the values they were built from", async () => {
  const values = [0, 1, -1, 127, -128, 63];
  const decoded = await decodeOne(
    await encodeTestStream({ attributeId: 0, values, channels: 1, mode: MODE_RAW }),
  );
  assert.deepEqual([...decoded], values);
});

test("delta streams accumulate along element order, per channel", async () => {
  const values = [10, 100, 12, 90, 15, 80, 15, 80];
  const decoded = await decodeOne(
    await encodeTestStream({
      attributeId: 6,
      values,
      channels: 2,
      mode: MODE_DELTA,
      symbolWidth: 2,
    }),
  );
  assert.deepEqual([...decoded], values);
});

test("constant streams repeat one element for the whole chunk", async () => {
  const bytes = await encodeTestStream({
    attributeId: 9,
    values: [7, -7],
    channels: 2,
    mode: MODE_CONST,
  });
  // A constant stream stores `channels` symbols and repeats them `element_count` times;
  // the header is rewritten here because the count is not derivable from the payload.
  new DataView(bytes.buffer, bytes.byteOffset).setUint32(5, 4, true);
  const decoded = await decodeOne(bytes);
  assert.deepEqual([...decoded], [7, -7, 7, -7, 7, -7, 7, -7]);
});

test("symbol widths 1, 2 and 4 all round-trip", async () => {
  for (const [width, value] of [
    [1, 100],
    [2, 30000],
    [4, 1000000],
  ] as const) {
    const decoded = await decodeOne(
      await encodeTestStream({
        attributeId: 0,
        values: [value, -value],
        channels: 1,
        symbolWidth: width,
      }),
    );
    assert.deepEqual([...decoded], [value, -value], `width ${width}`);
  }
});

test("the byte-plane unshuffle is the inverse of the plane layout", () => {
  // Two symbols, width 2: plane 0 holds both low bytes, plane 1 both high bytes.
  const raw = Uint8Array.from([0x02, 0x06, 0x01, 0x00]);
  assert.deepEqual([...unshuffleAndUnzigzag(raw, 2, 2)], [129, 3]);
});

test("a stream with an impossible symbol width is refused by name", async () => {
  const bytes = await encodeTestStream({ attributeId: 0, values: [1], channels: 1 });
  bytes[1] = 3;
  await assert.rejects(() => decodeOne(bytes), /symbol width 3 is not 1, 2 or 4/);
});

test("an unknown stream mode is refused rather than guessed at", async () => {
  const bytes = await encodeTestStream({ attributeId: 0, values: [1], channels: 1 });
  bytes[2] = 7;
  await assert.rejects(() => decodeOne(bytes), /unknown stream mode 7/);
});

test("a stream whose payload does not decompress to its declared size is truncated", async () => {
  const bytes = await encodeTestStream({ attributeId: 0, values: [1, 2, 3], channels: 1 });
  new DataView(bytes.buffer, bytes.byteOffset).setUint32(5, 4, true);
  await assert.rejects(() => decodeOne(bytes), TruncatedFile);
});

test("magic checking separates a foreign file from a future version", () => {
  assert.doesNotThrow(() => checkMagic(MAGIC));
  const future = Uint8Array.from(MAGIC);
  future[5] = 0x39; // "9"
  assert.throws(() => checkMagic(future), /major version 9 is not supported/);
  assert.throws(() => checkMagic(new Uint8Array(8)), /not a 4dgs file/);
  assert.throws(() => checkMagic(new Uint8Array(3)), TruncatedFile);
});

test("CRC-32 matches the IEEE values the footer is written with", () => {
  assert.equal(crc32(new TextEncoder().encode("")), 0);
  assert.equal(crc32(new TextEncoder().encode("123456789")), 0xcbf43926);
  assert.equal(crc32(new TextEncoder().encode("4dgs")), 0xf2630ef0);
  const incremental = new Crc32();
  incremental.update(new TextEncoder().encode("1234"));
  incremental.update(new TextEncoder().encode("56789"));
  assert.equal(incremental.digest(), 0xcbf43926);
});

test("a cursor refuses to read past its buffer, naming the offset", () => {
  const cursor = new Cursor(Uint8Array.from([1, 2, 3]));
  cursor.u8();
  assert.throws(() => cursor.u32(), /need 4 bytes at offset 1, 2 remain/);
});

test("a string map must fill its declared block", () => {
  // Block length 4, but the key inside claims 16 bytes.
  const bytes = Uint8Array.from([4, 0, 0, 0, 16, 0, 0, 0]);
  assert.throws(() => new Cursor(bytes).stringMap(), TruncatedFile);
});

test("record framing yields complete records and holds the rest", () => {
  const decoder = new StreamDecoder();
  const whole = record(0x01, Uint8Array.from([1, 2, 3]));
  decoder.append(MAGIC);
  decoder.append(whole.subarray(0, 5));
  assert.deepEqual([...decoder.records()], []);
  decoder.append(whole.subarray(5));
  const records = [...decoder.records()];
  assert.equal(records.length, 1);
  assert.equal(records[0]!.opcode, 0x01);
  assert.deepEqual([...records[0]!.content], [1, 2, 3]);
  assert.equal(records[0]!.offset, MAGIC.length);
});

test("selected record bodies stream without buffering a complete record", () => {
  const decoder = new StreamDecoder();
  const content = Uint8Array.from({ length: 1024 }, (_, i) => i & 0xff);
  const whole = concat([MAGIC, record(Opcode.AudioData, content), MAGIC]);
  const parts: Uint8Array[] = [];
  let finalParts = 0;
  let maxPart = 0;
  for (let at = 0; at < whole.byteLength; at += 31) {
    decoder.append(whole.subarray(at, Math.min(at + 31, whole.byteLength)));
    for (const item of decoder.recordsStreaming(new Set([Opcode.AudioData]))) {
      assert.ok("bytes" in item, "the selected opcode was buffered as a complete record");
      parts.push(Uint8Array.from(item.bytes));
      maxPart = Math.max(maxPart, item.bytes.byteLength);
      if (item.final) finalParts += 1;
    }
  }
  decoder.end();
  assert.equal(decoder.truncated, false);
  assert.equal(finalParts, 1);
  assert.ok(maxPart <= 31);
  assert.deepEqual(concat(parts), content);
});

test("audio normalization preserves extreme and tiny finite directions", () => {
  const source = (rotation: readonly number[]) => ({
    sourceId: 1,
    name: "",
    codec: "wav",
    channelLayout: "mono",
    dataLength: 0,
    startSec: 0,
    durationSec: 2,
    gain: 1,
    spatial: true,
    loop: false,
    position: [0, 0, 0],
    rotation,
    keyframes: [],
    interpolation: "linear",
  });
  assert.deepEqual(
    audioSourceStateAt(source([1e308, 1e308, 1e308, 1e308]), 1).rotation,
    [0.5, 0.5, 0.5, 0.5],
  );
  assert.deepEqual(
    audioSourceStateAt(source([Number.MIN_VALUE, 0, 0, 0]), 1).rotation,
    [1, 0, 0, 0],
  );
  const looping = {
    ...source([0, 0, 0, 1]),
    startSec: -1e308,
    durationSec: 1,
    loop: true,
  };
  const extremeTime = audioSourceStateAt(looping, 1e308);
  assert.equal(extremeTime.active, true);
  assert.equal(extremeTime.localTime, 0);
  assert.equal(Number.isFinite(extremeTime.localTime), true);
  assert.equal(audioSourceStateAt({ ...looping, startSec: 1e-20 }, 1).localTime, 1);

  const shortAtLargeTime = {
    ...source([0, 0, 0, 1]),
    startSec: 1e308,
    durationSec: 1,
  };
  assert.equal(audioSourceStateAt(shortAtLargeTime, 1e308).active, true);

  const extremeMotion = {
    ...source([0, 0, 0, 1]),
    startSec: -1e308,
    durationSec: 1,
    loop: true,
    keyframes: [
      { time: -1e308, position: [-1e308, 0, 0], rotation: [0, 0, 0, 1] },
      { time: 1e308, position: [1e308, 0, 0], rotation: [0, 0, 0, 1] },
    ],
  };
  assert.deepEqual(audioSourceStateAt(extremeMotion, 0).position, [0, 0, 0]);
});

test("a stream that ends on the trailing magic is not truncated", () => {
  const decoder = new StreamDecoder();
  decoder.append(MAGIC);
  decoder.append(record(0x02, new Uint8Array(20)));
  decoder.append(MAGIC);
  assert.deepEqual([...decoder.records()].length, 1);
  decoder.end();
  assert.equal(decoder.truncated, false);
});

test("a stream that stops mid-record keeps what completed and says it was cut", () => {
  const decoder = new StreamDecoder();
  decoder.append(MAGIC);
  decoder.append(record(0x02, new Uint8Array(20)));
  decoder.append(record(0x05, new Uint8Array(400)).subarray(0, 100));
  assert.equal([...decoder.records()].length, 1);
  decoder.end();
  assert.equal(decoder.truncated, true);
});

test("a file that is not ours is refused before anything else happens", () => {
  const decoder = new StreamDecoder();
  decoder.append(new TextEncoder().encode("ply\nformat "));
  assert.throws(() => [...decoder.records()], UnsupportedVersion);
});

test("spherical harmonic degrees are whole", () => {
  assert.deepEqual([0, 1, 2, 3].map(coefficientsForDegree), [0, 3, 8, 15]);
  assert.deepEqual([1, 2, 3].map(coefficientsInBand), [3, 5, 7]);
  assert.deepEqual(
    [1, 2, 3].map((b) => [...bandCoefficientRange(b)]),
    [
      [0, 3],
      [3, 8],
      [8, 15],
    ],
  );
});

test("merging bands lays coefficients out component-major, band by band", () => {
  // Two gaussians. Band 1 is three coefficients per component, band 2 is five.
  const band1 = Int32Array.from([
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9, // gaussian 0: R0..2, G0..2, B0..2
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
  ]);
  const band2 = Int32Array.from([
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 41, 42, 43, 44, 45, 46, 47, 48, 49,
    50, 51, 52, 53, 54, 55,
  ]);
  const merged = mergeBands(
    2,
    new Map([
      [1, band1],
      [2, band2],
    ]),
    3,
  );
  assert.equal(merged.degree, 2);
  assert.equal(merged.coefficients, 8);
  // Gaussian 0, red: band 1's first three, then band 2's first five.
  assert.deepEqual([...merged.values.slice(0, 8)], [1, 2, 3, 21, 22, 23, 24, 25]);
  // Gaussian 0, green: band 1's next three, then band 2's next five.
  assert.deepEqual([...merged.values.slice(8, 16)], [4, 5, 6, 26, 27, 28, 29, 30]);
  // Gaussian 1, blue.
  assert.deepEqual([...merged.values.slice(40, 48)], [17, 18, 19, 51, 52, 53, 54, 55]);
});

test("a cap keeps whole degrees and drops the bands above it", () => {
  const band1 = Int32Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9]);
  const band2 = Int32Array.from(new Array(15).fill(0).map((_, i) => 20 + i));
  const capped = mergeBands(
    1,
    new Map([
      [1, band1],
      [2, band2],
    ]),
    1,
  );
  assert.equal(capped.degree, 1);
  assert.equal(capped.coefficients, 3);
  assert.deepEqual([...capped.values], [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.deepEqual(capped.bands, [1]);
});

test("bands that do not form whole degrees are refused", () => {
  const band2 = Int32Array.from(new Array(15).fill(1));
  assert.throws(() => mergeBands(1, new Map([[2, band2]]), 3), MalformedFile);
});

test("velocity precision follows lifetime, and rounds the class up", () => {
  const sigmaLogStep = 2 * Math.log1p(0.02);
  const k = supportK(0.05);
  // A short-lived gaussian gets a coarser velocity grid than a long-lived one.
  const shortLived = motionStep(lifeClass(-200, sigmaLogStep, false, 0, k), 1);
  const longLived = motionStep(lifeClass(0, sigmaLogStep, false, 0, k), 1);
  assert.ok(shortLived > longLived, `${shortLived} should be coarser than ${longLived}`);
  // The clamps are the ends of the class range, exactly.
  assert.equal(lifeClass(-10000, sigmaLogStep, false, 0, k), -4);
  assert.equal(lifeClass(10000, sigmaLogStep, false, 0, k), 2);
  // A gaussian that never fades takes its lifetime from the validity window.
  assert.equal(lifeClass(0, sigmaLogStep, true, 2.0, k), 2);
});

test("birth-time precision is a fraction of the gaussian's own sigma", () => {
  const sigmaLogStep = 2 * Math.log1p(0.02);
  const stepTime = 0.004;
  // A large sigma cannot make the pitch coarser than the declared grid.
  assert.equal(muStep(400, sigmaLogStep, false, stepTime), stepTime);
  assert.equal(muStep(0, sigmaLogStep, true, stepTime), stepTime);
  // A tiny sigma refines it, by powers of two, down to the floor.
  assert.ok(muStep(-200, sigmaLogStep, false, stepTime) < stepTime);
  assert.equal(muStep(-100000, sigmaLogStep, false, stepTime), stepTime * 2 ** -10);
});

test("the colour transform inverts (g, r - g, b - g) exactly", () => {
  for (const rgb of [
    [0, 0, 0],
    [10, 200, 30],
    [255, 1, 128],
  ]) {
    const [r, g, b] = rgb as [number, number, number];
    assert.deepEqual([...rctInverse(g, r - g, b - g)], [r, g, b]);
  }
});

test("the marginal is 1 for a gaussian that never fades", () => {
  assert.equal(marginalAt(0.5, Infinity, 1000), 1);
  assert.equal(marginalAt(0.5, 0.1, 0.5), 1);
  assert.ok(marginalAt(0.5, 0.1, 0.7) < 0.14);
});

test("rounding matches Python's round, including the ties a float32 can hit", () => {
  const cases: [number, number][] = [
    [0.0078125, 0.007812],
    [-0.0078125, -0.007812],
    [0.0234375, 0.023438],
    [0.0390625, 0.039062],
    [3.0078125, 3.007812],
    [0.1234565, 0.123456],
    [0.1234575, 0.123457],
    [1.0000005, 1.000001],
    [-1.0000005, -1.000001],
    [123.4567891, 123.456789],
    [1e-7, 0],
    [5e-7, 0],
    [0.9999999, 1],
    [640.0078125, 640.007812],
    [2.5e-6, 3e-6],
    [1.5e-6, 2e-6],
  ];
  for (const [input, expected] of cases) {
    assert.equal(roundHalfEven(input, 6), expected, `round(${input}, 6)`);
  }
});

test("the encoder writes a file that decodes back to what went in", async () => {
  const count = 3;
  const gaussians = {
    count,
    positions: [0, 0, 0, 1, 0.5, -0.5, -1, 2, 0.25],
    scales: [0.1, 0.1, 0.1, 0.2, 0.15, 0.1, 0.05, 0.05, 0.05],
    rotations: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
    colors: [0.9, 0.1, 0.1, 1, 0.1, 0.9, 0.1, 0.8, 0.1, 0.1, 0.9, 0.5],
    motions: [0, 0, 0, 0.1, 0, 0, 0, -0.1, 0],
    muT: [0.5, 1, 1.5],
    // The middle gaussian never fades: +Infinity must survive as +Infinity.
    sigmaT: [0.3, Number.POSITIVE_INFINITY, 0.4],
    winLo: [0, 0, 0],
    winHi: [2, 2, 2],
  };

  const bytes = await encodeScene(gaussians, 2, {
    maxDepth: 4,
    minChunkGaussians: 1,
    profile: "test",
  });
  const scene = await decodeScene(new BytesReadable(bytes));

  assert.equal(scene.header.durationSec, 2);
  assert.equal(scene.header.profile, "test");
  assert.equal(scene.header.temporalModel, "gaussian-birth");
  assert.equal(scene.gaussians.count, count);

  let infinities = 0;
  for (let i = 0; i < count; i++) {
    assert.ok(!Number.isNaN(scene.gaussians.sigmaT[i]));
    if (!Number.isFinite(scene.gaussians.sigmaT[i]!)) infinities += 1;
  }
  assert.equal(infinities, 1);

  // Every decoded position lands within the grid's bound of the input it came from.
  for (let i = 0; i < count * 3; i++) {
    assert.ok(Math.abs(scene.gaussians.positions[i]! - gaussians.positions[i]!) < 0.05);
  }
});

/** Little-endian record bytes for the trajectory tests below. */
function trajectoryBytes(samples: readonly (readonly number[])[]): Uint8Array {
  const head = [0x03, 0, 0, 0, 0x72, 0x69, 0x67, 0x00]; // "rig" as a u32-prefixed string
  const parts: number[] = head.slice(0, 7); // u32 length 3, then the three bytes
  parts.push(0); // interpolation: linear
  const count = new DataView(new ArrayBuffer(4));
  count.setUint32(0, samples.length, true);
  for (let i = 0; i < 4; i++) parts.push(count.getUint8(i));
  for (const sample of samples) {
    for (const value of sample) {
      const view = new DataView(new ArrayBuffer(8));
      view.setFloat64(0, value, true);
      for (let i = 0; i < 8; i++) parts.push(view.getUint8(i));
    }
  }
  return Uint8Array.from(parts);
}

test("a trajectory interpolates without overflowing between extreme translations", () => {
  // Two finite samples whose difference is not representable. A naive lerp reports
  // infinity where the midpoint is zero, and the parser accepts these samples, so a
  // TypeScript consumer would diverge from Dart and Python on a file all three accept.
  const trajectory = parseRigTrajectory(
    trajectoryBytes([
      [0, 0, 0, 0, 1, -1e308, -1e308, -1e308],
      [2, 0, 0, 0, 1, 1e308, 1e308, 1e308],
    ]),
  );

  const pose = poseAt(trajectory, 1)!;
  for (const value of pose.translation) {
    assert.ok(Number.isFinite(value), `translation ${value} should be finite`);
    assert.ok(Math.abs(value) < 1e-6, `midpoint should be ~0, got ${value}`);
  }
});

test("a trajectory past the sample ceiling is refused before it is allocated", () => {
  // The byte-length check cannot catch this on its own: the ceiling is what bounds the
  // decoded arrays a single record can ask a reader to build, as the Dart decoder's does.
  const declared = MAX_TRAJECTORY_SAMPLES + 1;
  const parts: number[] = [3, 0, 0, 0, 0x72, 0x69, 0x67, 0];
  const count = new DataView(new ArrayBuffer(4));
  count.setUint32(0, declared, true);
  for (let i = 0; i < 4; i++) parts.push(count.getUint8(i));
  // Room for every declared sample, so only the ceiling can refuse it.
  const body = new Uint8Array(parts.length + declared * 64);
  body.set(Uint8Array.from(parts));
  assert.throws(() => parseRigTrajectory(body), MalformedFile);
});

test("a finite quaternion near the top of the range is renormalized, not refused", () => {
  // §5.15.4 refuses "zero or non-finite norms" — a claim about the quaternion, not about
  // the arithmetic used to measure it. [1e308, 0, 0, 0] has a finite norm and a good
  // direction; only the naive sum of squares overflows, so squaring first refuses a file
  // the format allows — and refuses it here while another SDK accepts it.
  assert.equal(quaternionNorm([1e308, 0, 0, 0]), 1e308);
  assert.ok(Number.isFinite(quaternionNorm([1e300, 1e300, 1e300, 1e300])));
  // A quaternion with no direction is still refused, which is what the sentence means.
  assert.equal(quaternionNorm([0, 0, 0, 0]), 0);
  assert.ok(!Number.isFinite(quaternionNorm([Infinity, 0, 0, 0])));
});

test("a zero-sample trajectory is read as absent rather than refused", () => {
  // §5.15.4: it "MUST be read as though the record were absent", so reading one refuses
  // nothing — not even interpolation 7, which describes how to read samples it does not
  // carry. checkRigTrajectory stays strict for the writer.
  const body = Uint8Array.from([3, 0, 0, 0, 0x72, 0x69, 0x67, 7, 0, 0, 0, 0]);
  const trajectory = parseRigTrajectory(body);
  assert.equal(trajectory.times.length, 0);
  assert.throws(
    () =>
      checkRigTrajectory({
        ...trajectory,
        times: [0],
        rotations: [[0, 0, 0, 1]],
        translations: [[0, 0, 0]],
      }),
    MalformedFile,
  );
});

test("a zero-sample object track is read as absent rather than refused", () => {
  // The same sentence as §5.15.4, in §5.15.7, for the object layer. Kept, one empty track
  // would make a non-empty object layer and two empty tracks for an id would be a
  // duplicate ObjectLayer.check() refuses.
  const body = Uint8Array.from([7, 0, 0, 0, 7, 0, 0, 0, 0]);
  const track = parseObjectTrack(body);
  assert.equal(track.times.length, 0);
  assert.throws(
    () =>
      checkObjectTrack({
        ...track,
        interpolation: 7,
        times: [0],
        rotations: [[0, 0, 0, 1]],
        translations: [[0, 0, 0]],
      }),
    MalformedFile,
  );
});

test("an object track with mismatched sample arrays is a malformed file, not a TypeError", () => {
  // The trajectory rules iterate each array independently, so a track with two times and
  // one rotation used to pass and fail later inside poseAt with a raw TypeError. Python
  // and Rust refuse it at check time; this pins the same answer here.
  assert.throws(
    () =>
      checkObjectTrack({
        objectId: 7,
        interpolation: 0,
        times: [0, 1],
        rotations: [[0, 0, 0, 1]],
        translations: [
          [0, 0, 0],
          [1, 1, 1],
        ],
      }),
    MalformedFile,
  );
});

test("an object track sample of the wrong width is refused, not composed into NaN", () => {
  // A translation of two numbers passes the trajectory rules, which iterate whatever
  // coordinates are there, and then reads as undefined in composition — NaN centres
  // rather than a refusal. Python names this; Rust cannot express it.
  const base = { objectId: 7, interpolation: 0, times: [0] };
  assert.throws(
    () => checkObjectTrack({ ...base, rotations: [[0, 0, 0, 1]], translations: [[1, 2]] }),
    MalformedFile,
  );
  assert.throws(
    () => checkObjectTrack({ ...base, rotations: [[0, 0, 1]], translations: [[1, 2, 3]] }),
    MalformedFile,
  );
});

test("an object table embedding must match the space the table declares", () => {
  // embedding_dim is declared once for the whole file, so a vector of another width —
  // or any vector when the table declares no embedding space — describes a coordinate
  // system nothing else in the file shares. Python refuses both.
  const entry = { objectId: 1, label: "", anchor: [0, 0, 0], dynamics: null };
  assert.throws(
    () => checkObjectTable({ embeddingDim: 4, entries: [{ ...entry, embedding: [1, 2, 3] }] }),
    MalformedFile,
  );
  assert.throws(
    () => checkObjectTable({ embeddingDim: 0, entries: [{ ...entry, embedding: [1, 2, 3] }] }),
    MalformedFile,
  );
});

test("object ids and embedding_dim must fit the fields that carry them", () => {
  // u32 and u16 on the wire, so the parser cannot produce anything else — but a caller
  // constructing a record can, and nothing downstream notices: a track keyed by 1.5
  // composes onto nothing, one keyed by -1 matches no gaussian, and both look valid.
  // Rust gets this from its types; Python checks it by hand.
  for (const bad of [-1, 1.5, 2 ** 32]) {
    assert.throws(
      () =>
        checkObjectTrack({
          objectId: bad,
          interpolation: 0,
          times: [],
          rotations: [],
          translations: [],
        }),
      MalformedFile,
      `object_id ${bad} should be refused`,
    );
  }
  assert.throws(() => checkObjectTable({ embeddingDim: 0x10000, entries: [] }), MalformedFile);
  assert.throws(
    () =>
      checkObjectTable({
        embeddingDim: 0,
        entries: [{ objectId: -1, label: "", anchor: [0, 0, 0], dynamics: null, embedding: null }],
      }),
    MalformedFile,
  );
});

test("object table lanes are refused outside the f32 range they are stored in", () => {
  // 1e100 is a finite double and fits no conforming record: written as f32 it rounds
  // to Infinity. Python refuses it as `object-value-out-of-f32-range`, so accepting it
  // here would bless a table no other reader can hold.
  const entry = { objectId: 1, label: "", dynamics: null, embedding: null };
  assert.throws(
    () => checkObjectTable({ embeddingDim: 0, entries: [{ ...entry, anchor: [1e100, 0, 0] }] }),
    MalformedFile,
  );
  // The largest finite f32 is still a legal value.
  checkObjectTable({
    embeddingDim: 0,
    entries: [{ ...entry, anchor: [3.4028234663852886e38, 0, 0] }],
  });
});

test("an object table vector of the wrong width is refused", () => {
  // The wire record carries f32[3] for the anchor and each dynamics vector, so a
  // shorter one is a shape no conforming file can hold. Rust cannot express it.
  const entry = { objectId: 1, label: "", dynamics: null, embedding: null };
  assert.throws(
    () => checkObjectTable({ embeddingDim: 0, entries: [{ ...entry, anchor: [1, 2] }] }),
    MalformedFile,
  );
  assert.throws(
    () =>
      checkObjectTable({
        embeddingDim: 0,
        entries: [
          {
            ...entry,
            anchor: [0, 0, 0],
            dynamics: [
              [0, 0],
              [0, 0, 0],
              [0, 0, 0],
            ],
          },
        ],
      }),
    MalformedFile,
  );
});

test("a table-only object layer composes without scanning every gaussian", () => {
  // Labels and anchors with nothing moving is a valid, common layer. It has no pose to
  // apply, so composition must not build a scene-sized set for nothing — but the shape
  // checks still run, because mismatched arrays are wrong either way.
  const layer = new ObjectLayer();
  const centers = new Float32Array([1, 0, 0]);
  const orientations = new Float32Array([0, 0, 0, 1]);
  layer.apply(centers, orientations, new Uint32Array([7]), 2);
  assert.deepEqual(Array.from(centers), [1, 0, 0]);
  assert.throws(
    () => layer.apply(new Float32Array([1, 0]), orientations, new Uint32Array([7]), 2),
    MalformedFile,
  );
});
