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
  keyframeDeltaChunkAt,
  keyframeDeltaStatesJson,
  reconstructKeyframeDelta,
  type KeyframeDeltaSequence,
} from "@4dgs/core";

import { num } from "./canonical.js";

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

// --- the full reconstruction (spec §11.7, §3) -----------------------------

/** Every probe instant the canonical summary reports, in order. */
function probes(summary: Record<string, unknown>): number[] {
  return (summary.states as Row[]).map((s) => s.t as number);
}

test("the reconstruction at an instant carries every attribute, not a sample of two", async () => {
  const sequence = await decodeKeyframeDeltaStreamed(bytes(MOVING_CHAINED));
  let seen = 0;
  for (const t of probes(keyframeDeltaStatesJson(sequence))) {
    const g = reconstructKeyframeDelta(sequence, keyframeDeltaChunkAt(sequence, t), t);
    assert.equal(g.t, t);
    assert.equal(g.ids.length, g.count);
    assert.equal(g.centers.length, g.count * 3);
    assert.equal(g.scales.length, g.count * 3);
    assert.equal(g.rotations.length, g.count * 4);
    assert.equal(g.rgb.length, g.count * 3);
    assert.equal(g.opacity.length, g.count);
    // Ascending gaussian_id is the only order two implementations can agree on: stream
    // order is an encoder's choice (spec §11.2).
    for (let i = 1; i < g.count; i++) assert.ok(g.ids[i]! > g.ids[i - 1]!);
    for (let i = 0; i < g.count; i++) {
      const norm = Math.hypot(
        g.rotations[i * 4]!,
        g.rotations[i * 4 + 1]!,
        g.rotations[i * 4 + 2]!,
        g.rotations[i * 4 + 3]!,
      );
      assert.ok(Math.abs(norm - 1) < 1e-9, `rotation ${i} at t=${t} has norm ${norm}`);
      assert.ok(g.scales[i * 3]! > 0);
      for (let c = 0; c < 3; c++) assert.ok(g.rgb[i * 3 + c]! >= 0 && g.rgb[i * 3 + c]! <= 1);
      assert.ok(g.opacity[i]! >= 0 && g.opacity[i]! <= 1);
    }
    // No fixture here carries object membership on a keyframe-delta chunk, so `null` is the
    // honest answer rather than a column of zeroes reading as "everything is background".
    assert.equal(g.objectId, null);
    seen += g.count;
  }
  assert.ok(seen > 0);
});

test("the canonical summary is that reconstruction, not a second one", async () => {
  // The summary two SDKs are diffed on reads the rows a consumer gets. If these two ever
  // came apart, the conformance suite would be proving something no caller can see.
  const sequence = await decodeKeyframeDeltaStreamed(bytes(MOVING_CHAINED));
  for (const row of keyframeDeltaStatesJson(sequence).states as Row[]) {
    const t = row.t as number;
    const g = reconstructKeyframeDelta(sequence, keyframeDeltaChunkAt(sequence, t), t);
    assert.equal(String(g.count), row.liveCount);
    const sample = row.sample as Record<string, unknown>;
    const ids = sample.gaussianIds as string[];
    const positions = sample.positions as number[][];
    for (let i = 0; i < ids.length; i++) {
      assert.equal(String(g.ids[i]), ids[i]);
      for (let c = 0; c < 3; c++) assert.equal(num(g.centers[i * 3 + c]!), positions[i]![c]);
    }
  }
});

test("both read paths reconstruct the same values, rotations and colour included", async () => {
  // The canonical statement samples centres and scales; agreeing on those says nothing
  // about the attributes it never prints. Composing a chain by byte range and composing
  // front to back must reach the same gaussians in every attribute, or one of the two read
  // paths is decoding a different scene.
  const streamed = await decodeKeyframeDeltaStreamed(bytes(MOVING_KEYFRAME));
  const indexed = (await decodeKeyframeDeltaIndexed(bytes(MOVING_KEYFRAME))).sequence;
  for (const t of probes(keyframeDeltaStatesJson(streamed))) {
    const a = reconstructKeyframeDelta(streamed, keyframeDeltaChunkAt(streamed, t), t);
    const b = reconstructKeyframeDelta(indexed, keyframeDeltaChunkAt(indexed, t), t);
    assert.deepEqual([...a.ids], [...b.ids]);
    assert.deepEqual([...a.centers], [...b.centers]);
    assert.deepEqual([...a.scales], [...b.scales]);
    assert.deepEqual([...a.rotations], [...b.rotations]);
    assert.deepEqual([...a.rgb], [...b.rgb]);
    assert.deepEqual([...a.opacity], [...b.opacity]);
  }
});

test("the covering chunk is the seek, and the end of the timeline is not a refusal", async () => {
  const sequence = await decodeKeyframeDeltaStreamed(bytes(MOVING_CHAINED));
  for (const chunk of sequence.chunks) {
    assert.equal(keyframeDeltaChunkAt(sequence, chunk.t0), chunk);
    assert.equal(keyframeDeltaChunkAt(sequence, (chunk.t0 + chunk.t1) / 2), chunk);
  }
  const last = sequence.chunks[sequence.chunks.length - 1]!;
  assert.equal(keyframeDeltaChunkAt(sequence, last.t1), last);
});
