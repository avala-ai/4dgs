// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/** Focused integration tests for the optional-identity shared witnesses. */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  BytesReadable,
  IndexedDecoder,
  assembleGaussians,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  type ChunkGaussians,
} from "@4dgs/core";

import { canonical } from "./canonical.js";
import { gaussianBirthIdentityJson, keyframeDeltaIdentityJson } from "./optionalIdentity.js";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/identity/", import.meta.url));

function witness(relative: string): { bytes: Uint8Array; expected: string } | null {
  const stem = `${DATA}${relative}`;
  if (!existsSync(`${stem}.4dgs`)) return null;
  return {
    bytes: new Uint8Array(readFileSync(`${stem}.4dgs`)),
    expected: canonical(JSON.parse(readFileSync(`${stem}.json`, "utf8"))),
  };
}

test("gaussian-birth mixed chunks zero-fill all optional identities on both paths", async (t) => {
  const fixture = witness("gaussian-birth/OptionalIdentityGaussianBirth-UseChunkIndex-UseCrc");
  if (fixture === null) return t.skip("corpus not generated");

  const streamed = await decodeScene(fixture.bytes);
  assert.equal(canonical(gaussianBirthIdentityJson(streamed.gaussians)), fixture.expected);

  const indexed = await IndexedDecoder.open(new BytesReadable(fixture.bytes));
  const chunks: ChunkGaussians[] = [];
  for (const entry of indexed.index) chunks.push((await indexed.readChunk(entry)).gaussians);
  const gaussians = assembleGaussians(chunks, indexed.windows, indexed.header.shDegree);
  assert.equal(canonical(gaussianBirthIdentityJson(gaussians)), fixture.expected);
  assert.deepEqual([...gaussians.sourceGroup!].slice(-2), [0, 0]);
  assert.deepEqual([...gaussians.sourceIndex!].slice(-2), [0, 0]);
  assert.deepEqual([...gaussians.objectId!], [0x80000000, 0xffffffff, 0, 0, 0]);
});

test("keyframe-delta composes all optional identity transitions on both paths", async (t) => {
  const fixture = witness(
    "keyframe-delta/OptionalIdentityKeyframeDelta-UseChunkIndex-UseCrc-UseStatistics",
  );
  if (fixture === null) return t.skip("corpus not generated");

  const streamed = await decodeKeyframeDeltaStreamed(fixture.bytes);
  const indexed = (await decodeKeyframeDeltaIndexed(fixture.bytes)).sequence;
  for (const sequence of [streamed, indexed]) {
    assert.equal(canonical(keyframeDeltaIdentityJson(sequence)), fixture.expected);

    const introduced = sequence.chunks[1]!.state;
    assert.deepEqual(introduced.identityAt(0), {
      sourceGroup: -17,
      sourceIndex: 23,
      objectId: 0xffffffff,
    });
    assert.deepEqual(introduced.identityAt(1), {
      sourceGroup: 0,
      sourceIndex: 0,
      objectId: 0,
    });

    const reset = sequence.chunks[4]!.state;
    for (let row = 0; row < reset.count; row++) {
      assert.deepEqual(reset.identityAt(row), { sourceGroup: 0, sourceIndex: 0, objectId: 0 });
    }
  }
});
