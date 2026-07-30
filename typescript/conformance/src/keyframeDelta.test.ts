// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The whole-file `keyframe-delta` decode: read a file two ways, agree.
 *
 * A restatement of `python/fourdgs/tests/test_keyframe_delta_file.py` and its Dart mirror.
 * The load-bearing assertion is that the streamed and indexed read paths produce the same
 * canonical `states` — the reconstruction at an instant — because that is the statement the
 * other SDKs are diffed against. The fixtures are `keyframe-delta` files written by the
 * Python reference and embedded as base64, so this test needs no encoder: the TypeScript
 * side is decode-only this milestone. Exact-value parity against Python's `states_json` is
 * proven in the conformance harness; what these unit tests own is agreement across the two
 * read paths, the structural fields, and the depth-invariant error bound.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  MalformedFile,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  keyframeDeltaStatesJson,
  type KeyframeDeltaSequence,
} from "@4dgs/core";

import {
  DEEP_CHAIN,
  GAUSSIAN_BIRTH,
  KEYFRAME_ONLY,
  MOVING_CHAINED,
  MOVING_KEYFRAME,
} from "./keyframeDeltaFixtures.js";

function bytes(b64: string): Uint8Array {
  return new Uint8Array(Buffer.from(b64, "base64"));
}

async function statesStreamed(b64: string): Promise<Record<string, unknown>> {
  return keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(bytes(b64)));
}

async function statesIndexed(b64: string): Promise<Record<string, unknown>> {
  return keyframeDeltaStatesJson((await decodeKeyframeDeltaIndexed(bytes(b64))).sequence);
}

type Row = Record<string, unknown>;

function chunkRows(summary: Record<string, unknown>): Row[] {
  return summary.chunks as Row[];
}

for (const [name, fixture] of Object.entries({
  chained: MOVING_CHAINED,
  keyframe: MOVING_KEYFRAME,
})) {
  test(`streamed and indexed agree — delta_mode ${name}`, async () => {
    assert.equal(
      JSON.stringify(await statesStreamed(fixture)),
      JSON.stringify(await statesIndexed(fixture)),
    );
  });
}

test("the header declares the model and the distinct id count", async () => {
  const decoded = await decodeKeyframeDeltaStreamed(bytes(MOVING_CHAINED));
  assert.equal(decoded.header.temporalModel, "keyframe-delta");
  // ids seen across the whole clip: 0, 1, 2, 3, 4.
  assert.equal(decoded.header.gaussianCount, 5);
});

test("a wrong temporal model is refused on the keyframe-delta path", async () => {
  // A gaussian-birth file names a different model in its Header. The keyframe-delta path
  // must refuse it rather than mis-compose keyframe Chunks as a whole population and
  // silently skip the Delta Chunks it does not find.
  await assert.rejects(() => decodeKeyframeDeltaStreamed(bytes(GAUSSIAN_BIRTH)), MalformedFile);
});

test("a keyframe-only file is the frame-sequence shape", async () => {
  const summary = await statesStreamed(KEYFRAME_ONLY);
  const chunks = chunkRows(summary);
  assert.ok(chunks.every((c) => c.kind === "keyframe"));
  assert.ok(chunks.every((c) => c.deltaMode === null));
});

test("births and deaths move the population", async () => {
  const summary = await statesStreamed(MOVING_CHAINED);
  const live = chunkRows(summary).map((c) => Number(c.liveCount));
  // A birth of id 4 takes the population to 5; a death of id 2 drops it to 4.
  assert.equal(Math.max(...live), 5);
  assert.equal(Math.min(...live), 4);
});

test("a delta chunk reports its update, birth and death counts", async () => {
  const chunks = chunkRows(await statesStreamed(MOVING_CHAINED));
  // Every delta row carries the split; every keyframe row carries null. A field no row
  // mentions is one an implementation can decline to decode.
  for (const c of chunks) {
    if (c.kind === "delta") {
      assert.equal(typeof c.updateCount, "string");
      assert.equal(typeof c.birthCount, "string");
      assert.equal(typeof c.deathCount, "string");
    } else {
      assert.equal(c.updateCount, null);
    }
  }
  assert.ok(chunks.some((c) => c.kind === "delta"));
  assert.ok(chunks.some((c) => c.kind === "keyframe"));
});

test("probe states are derived from the file", async () => {
  const summary = await statesStreamed(MOVING_CHAINED);
  const chunks = chunkRows(summary);
  const states = summary.states as Row[];
  // Every chunk contributes its t0 and midpoint, plus one instant near the end.
  assert.ok(states.length >= chunks.length);
  for (const s of states) {
    const sample = s.sample as Record<string, unknown>;
    const positions = sample.positions as unknown[];
    assert.ok(positions.length > 0 || s.liveCount === "0");
  }
});

test("error does not grow with depth", async () => {
  // A long chain of small drifts reconstructs the last sample within the declared bound:
  // the composed bin at depth d IS the bin an absolute statement would carry, so the error
  // is the one-shot quantization error, not d times it.
  const decoded = await decodeKeyframeDeltaStreamed(bytes(DEEP_CHAIN));
  const deepest = decoded.chunks[decoded.chunks.length - 1]!;
  assert.equal(deepest.depth, decoded.chunks.length - 1); // a genuinely deep chain
  assert.equal(deepest.kind, 1);

  const summary = keyframeDeltaStatesJson(decoded);
  const states = summary.states as Row[];
  const last = states[states.length - 1]!;
  const sample = last.sample as Record<string, unknown>;
  const firstPos = (sample.positions as number[][])[0]!;
  const x = firstPos[0]!;
  const t = last.t as number;
  const steps = decoded.chunks.length;
  const trueX = 0.001 * (steps - 1);
  // Within one position pitch of the true value at the deepest frame — plus a hair for the
  // probe landing at duration-1e-6 rather than exactly t.
  const pitch = decoded.quantization.stepPos;
  assert.ok(Math.abs(x - trueX) <= pitch + 1e-3);
  assert.ok(t > steps - 2);
});

test("the indexed path walks a chain to every chunk", async () => {
  const result = await decodeKeyframeDeltaIndexed(bytes(MOVING_CHAINED));
  // The index tiles the timeline and every entry composed to a live population; the
  // deepest delta's chain length matches its declared depth, which chainFor already
  // asserts, so reaching here is the check.
  assert.equal(result.index.length, result.sequence.chunks.length);
  assert.ok(result.sequence.chunks.every((c) => c.state.count >= 4));
});

// The streamed and indexed sequences expose the same header, a small sanity tie.
test("both read paths report the same header", async () => {
  const streamed: KeyframeDeltaSequence = await decodeKeyframeDeltaStreamed(bytes(MOVING_KEYFRAME));
  const indexed = (await decodeKeyframeDeltaIndexed(bytes(MOVING_KEYFRAME))).sequence;
  assert.equal(streamed.header.gaussianCount, indexed.header.gaussianCount);
  assert.equal(streamed.header.durationSec, indexed.header.durationSec);
});
