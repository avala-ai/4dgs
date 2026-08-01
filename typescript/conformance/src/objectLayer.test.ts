// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Unit tests for the object layer's rules and arithmetic.
 *
 * The corpus proves that three whole files compose to the right states. These prove the
 * parts underneath against values chosen by hand: the refusals a malformed record is
 * supposed to produce, the clamp at the ends of a track, and — the load-bearing one —
 * that a track transforms the base state rather than replacing it. A decoder that
 * dropped per-gaussian motion, or applied the pose before it, would still agree with a
 * summary that only reported stored fields; it cannot agree with these.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  GaussianSet,
  MalformedFile,
  ObjectLayer,
  TruncatedFile,
  parseObjectTable,
  parseObjectTrack,
  parseQuantization,
  stateAtWithObjects,
  type ObjectTrack,
} from "@4dgs/core";

/** Little-endian record bytes, written the way the reference encoder would. */
class Bytes {
  private readonly parts: number[] = [];

  u8(value: number): this {
    this.parts.push(value & 0xff);
    return this;
  }

  u16(value: number): this {
    return this.u8(value).u8(value >>> 8);
  }

  u32(value: number): this {
    return this.u16(value & 0xffff).u16(value >>> 16);
  }

  string(value: string): this {
    const encoded = new TextEncoder().encode(value);
    this.u32(encoded.length);
    for (const byte of encoded) this.u8(byte);
    return this;
  }

  f32(value: number): this {
    const view = new DataView(new ArrayBuffer(4));
    view.setFloat32(0, value, true);
    for (let i = 0; i < 4; i++) this.u8(view.getUint8(i));
    return this;
  }

  f64(value: number): this {
    const view = new DataView(new ArrayBuffer(8));
    view.setFloat64(0, value, true);
    for (let i = 0; i < 8; i++) this.u8(view.getUint8(i));
    return this;
  }

  done(): Uint8Array {
    return Uint8Array.from(this.parts);
  }
}

/** A one-entry Object Table: id 7, an anchor, no dynamics, no embedding space. */
function simpleTable(): Uint8Array {
  return new Bytes().u32(1).u16(0).u32(7).string("vehicle").f32(1).f32(-2).f32(0.5).u8(0).done();
}

/** A track for object `id` with two samples: identity at t=0, then a quarter turn about z. */
function quarterTurnTrack(id = 7): Uint8Array {
  const b = new Bytes().u32(id).u8(0).u32(2);
  b.f64(0).f64(0).f64(0).f64(0).f64(1).f64(0).f64(0).f64(0);
  const halfRoot = Math.SQRT1_2;
  b.f64(2).f64(0).f64(0).f64(halfRoot).f64(halfRoot).f64(5).f64(2).f64(0);
  return b.done();
}

test("an Object Table round-trips its advisory fields", () => {
  const table = parseObjectTable(simpleTable());
  assert.equal(table.embeddingDim, 0);
  assert.equal(table.entries.length, 1);
  const entry = table.entries[0]!;
  assert.equal(entry.objectId, 7);
  assert.equal(entry.label, "vehicle");
  assert.deepEqual([...entry.anchor], [1, -2, 0.5]);
  assert.equal(entry.dynamics, null);
  assert.equal(entry.embedding, null);
});

test("an Object Table carries dynamics and an embedding when they are present", () => {
  const b = new Bytes().u32(1).u16(3).u32(4).string("");
  b.f32(0).f32(0).f32(0).u8(1);
  b.f32(1).f32(2).f32(3).f32(4).f32(5).f32(6).f32(7).f32(8).f32(9);
  b.u8(1).f32(0.25).f32(0.5).f32(0.75);
  const table = parseObjectTable(b.done());
  const entry = table.entries[0]!;
  assert.deepEqual([...entry.dynamics![0]], [1, 2, 3]);
  assert.deepEqual([...entry.dynamics![1]], [4, 5, 6]);
  assert.deepEqual([...entry.dynamics![2]], [7, 8, 9]);
  assert.deepEqual([...entry.embedding!], [0.25, 0.5, 0.75]);
});

test("an Object Table with two entries for one id is refused, naming it", () => {
  const b = new Bytes().u32(2).u16(0);
  b.u32(7).string("first").f32(0).f32(0).f32(0).u8(0);
  b.u32(7).string("second").f32(0).f32(0).f32(0).u8(0);
  assert.throws(
    () => parseObjectTable(b.done()),
    (error: Error) => {
      assert.ok(error instanceof MalformedFile);
      assert.match(error.message, /object 7/);
      return true;
    },
  );
});

test("a declared object count larger than the record is refused before it is allocated", () => {
  const b = new Bytes().u32(1_000_000).u16(0);
  assert.throws(() => parseObjectTable(b.done()), TruncatedFile);
});

test("a track for object 0 is refused: 0 is background", () => {
  assert.throws(
    () => parseObjectTrack(quarterTurnTrack(0)),
    (error: Error) => {
      assert.ok(error instanceof MalformedFile);
      assert.match(error.message, /background/);
      return true;
    },
  );
});

test("a track whose times do not strictly increase is refused", () => {
  const b = new Bytes().u32(7).u8(0).u32(2);
  b.f64(1).f64(0).f64(0).f64(0).f64(1).f64(0).f64(0).f64(0);
  b.f64(1).f64(0).f64(0).f64(0).f64(1).f64(0).f64(0).f64(0);
  assert.throws(() => parseObjectTrack(b.done()), MalformedFile);
});

test("two tracks for one object are refused; that rule spans records", () => {
  const layer = new ObjectLayer(null, [
    parseObjectTrack(quarterTurnTrack(7)),
    parseObjectTrack(quarterTurnTrack(7)),
  ]);
  assert.throws(
    () => layer.check(),
    (error: Error) => {
      assert.ok(error instanceof MalformedFile);
      assert.match(error.message, /object 7/);
      return true;
    },
  );
});

test("a pose query outside the sample range clamps rather than extrapolating", () => {
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack())]);
  const before = layer.poseAt(7, -100)!;
  assert.deepEqual([...before.translation], [0, 0, 0]);
  const after = layer.poseAt(7, 100)!;
  // The last sample, not the last sample plus ninety-eight seconds of velocity.
  assert.deepEqual([...after.translation], [5, 2, 0]);
});

test("an untracked object and the background keep their base state", () => {
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack(7))]);
  assert.equal(layer.poseAt(0, 2), null);
  assert.equal(layer.poseAt(9, 2), null);
});

test("a track transforms the base state; it does not replace it", () => {
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack(7))]);
  // Two gaussians one unit out along +x: one in object 7, one in the background.
  const centers = Float32Array.from([1, 0, 0, 1, 0, 0]);
  const orientations = Float32Array.from([0, 0, 0, 1, 0, 0, 0, 1]);
  layer.apply(centers, orientations, Int32Array.from([7, 0]), 2);

  // At t=2 the pose is a quarter turn about z then a translation of (5, 2, 0):
  // R * (1,0,0) = (0,1,0), plus T = (5, 3, 0). The base centre went through the
  // rotation — a decoder that replaced it would report (5, 2, 0).
  assert.ok(Math.abs(centers[0]! - 5) < 1e-6);
  assert.ok(Math.abs(centers[1]! - 3) < 1e-6);
  assert.ok(Math.abs(centers[2]!) < 1e-6);
  // The background gaussian is untouched, pose or no pose.
  assert.deepEqual([...centers.slice(3)], [1, 0, 0]);

  // The orientation composes as a quaternion product, base second.
  assert.ok(Math.abs(orientations[2]! - Math.SQRT1_2) < 1e-6);
  assert.ok(Math.abs(orientations[3]! - Math.SQRT1_2) < 1e-6);
  assert.deepEqual([...orientations.slice(4)], [0, 0, 0, 1]);
});

test("composition refuses arrays that do not match the gaussian count", () => {
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack(7))]);
  assert.throws(
    () => layer.apply(new Float32Array(3), new Float32Array(4), Int32Array.from([7, 0]), 0),
    MalformedFile,
  );
});

test("an empty layer is a value, not an error", () => {
  const layer = new ObjectLayer();
  assert.ok(layer.isEmpty);
  layer.check();
  assert.equal(layer.track(7), null);
  const centers = Float32Array.from([1, 2, 3]);
  layer.apply(centers, Float32Array.from([0, 0, 0, 1]), Int32Array.from([7]), 0);
  assert.deepEqual([...centers], [1, 2, 3]);
});

test("an object id in the upper half of the u32 range still matches its track", () => {
  // `object_id` is an exact label over the whole u32 range (spec section 6.6), and a
  // stream decodes into signed bins. Read back as an `Int32Array` this id is -1, while
  // the track parses its own id as 4294967295 — the two would never meet, the object
  // would silently stop moving, and the canonical summary would print a negative label
  // no other SDK emits. Membership is therefore stored unsigned.
  const big = 0xffffffff;
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack(big))]);
  assert.equal(layer.tracks[0]!.objectId, big);

  // The bits a decoded lane would hold, reinterpreted the way `chunk.ts` does.
  const signedBins = Int32Array.from([-1]);
  const ids = new Uint32Array(signedBins.buffer, signedBins.byteOffset, signedBins.length);
  assert.equal(ids[0], big);

  const centers = Float32Array.from([1, 0, 0]);
  const orientations = Float32Array.from([0, 0, 0, 1]);
  layer.apply(centers, orientations, ids, 2);
  assert.ok(Math.abs(centers[0]! - 5) < 1e-6);
  assert.ok(Math.abs(centers[1]! - 3) < 1e-6);
});

test("a Quantization record that bounds object_id is refused", () => {
  // An id is an exact label (spec section 6.6), so there is no meaningful error bound
  // between two of them; section 6.5 makes this a refusal rather than something to ignore.
  // Python and Rust refuse it, and an SDK that accepted it would claim object-layer support
  // while decoding a file the references reject.
  // A string map is a u32 byte length followed by that many bytes of key/value pairs.
  const pairs = new Bytes().string("object_id").string("0.5").done();
  const record = new Bytes().string("grid-v1");
  for (let i = 0; i < 3; i++) record.f64(0); // posOrigin
  for (let i = 0; i < 8; i++) record.f64(1); // the eight steps
  record.u8(0); // stepSh
  record.u32(pairs.length);
  const withBounds = Uint8Array.from([...record.done(), ...pairs]);

  assert.throws(
    () => parseQuantization(withBounds),
    (error: Error) => {
      assert.ok(error instanceof MalformedFile);
      assert.match(error.message, /object_id/);
      return true;
    },
  );
});

test("a zero-sample track has no pose and is read as absent", () => {
  const empty: ObjectTrack = parseObjectTrack(new Bytes().u32(7).u8(0).u32(0).done());
  const layer = new ObjectLayer(null, [empty]);
  assert.equal(layer.poseAt(7, 0), null);
});

test("stateAtWithObjects composes the layer that stateAt alone leaves off", async () => {
  // The gap this closes: `gaussians.stateAt` is the temporal model alone, so a caller who
  // never learns the object layer exists would render a tracked object at its rest place.
  const layer = new ObjectLayer(null, [parseObjectTrack(quarterTurnTrack(7))]);
  const gaussians = new GaussianSet({
    count: 2,
    positions: Float32Array.from([1, 0, 0, 1, 0, 0]),
    scales: Float32Array.from([0.1, 0.1, 0.1, 0.1, 0.1, 0.1]),
    rotations: Float32Array.from([0, 0, 0, 1, 0, 0, 0, 1]),
    colors: Float32Array.from([1, 1, 1, 1, 1, 1, 1, 1]),
    motions: new Float32Array(6),
    muT: Float32Array.from([1, 1]),
    sigmaT: Float32Array.from([Infinity, Infinity]),
    winLo: Float32Array.from([0, 0]),
    winHi: Float32Array.from([4, 4]),
    objectId: Uint32Array.from([7, 0]),
  });

  const base = gaussians.stateAt(2);
  assert.deepEqual([...base.centers.slice(0, 3)], [1, 0, 0]);

  const composed = stateAtWithObjects(gaussians, layer, 2);
  // Object 7 is transported; the background gaussian is not.
  assert.ok(Math.abs(composed.centers[0]! - 5) < 1e-6);
  assert.ok(Math.abs(composed.centers[1]! - 3) < 1e-6);
  assert.deepEqual([...composed.centers.slice(3)], [1, 0, 0]);

  // An empty layer is a no-op rather than an error.
  const untouched = stateAtWithObjects(gaussians, new ObjectLayer(), 2);
  assert.deepEqual([...untouched.centers.slice(0, 3)], [1, 0, 0]);
});
