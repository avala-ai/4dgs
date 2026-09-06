// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/** The aggregate decoded-state contract on TypeScript's collecting APIs. */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DEFAULT_MAX_DECODED_STATE_BYTES,
  DecodedStateBudget,
  ExceedsReaderLimit,
  IndexedDecoder,
  assembleGaussians,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  encodeScene,
  gaussianSetAssemblyBytes,
  type IReadable,
} from "@4dgs/core";

import { KEYFRAME_ONLY } from "./keyframeDeltaFixtures.js";

const oneGaussian = {
  count: 1,
  positions: [0, 0, 0],
  scales: [0.01, 0.01, 0.01],
  rotations: [0, 0, 0, 1],
  colors: [0.5, 0.5, 0.5, 1],
  motions: [0, 0, 0],
  muT: [0.5],
  sigmaT: [Number.POSITIVE_INFINITY],
  winLo: [0],
  winHi: [1],
};

function bytes(b64: string): Uint8Array {
  return new Uint8Array(Buffer.from(b64, "base64"));
}

function resourceLimit(phase: RegExp, limit = 1): (error: unknown) => boolean {
  return (error): boolean => {
    assert.ok(error instanceof ExceedsReaderLimit, String(error));
    assert.equal(error.refusalCode, undefined);
    assert.match(error.message, /decoded-state/);
    assert.match(error.message, new RegExp(`configured limit is ${limit} bytes`));
    assert.match(error.message, phase);
    assert.match(error.message, /at least \d+ bytes are required/);
    return true;
  };
}

test("the shared default is 512 MiB and exact equality is allowed", () => {
  assert.equal(DEFAULT_MAX_DECODED_STATE_BYTES, 536_870_912);
  const budget = new DecodedStateBudget(5);
  assert.equal(budget.check(5, "exact"), 5);
  assert.equal(budget.retain(5, "exact"), 5);
  assert.equal(budget.remainingBytes, 0);
});

test("invalid limits are caller errors before transport I/O or input parsing", async () => {
  let touched = false;
  const source: IReadable = {
    size(): Promise<bigint> {
      touched = true;
      throw new Error("input was touched");
    },
    read(): Promise<Uint8Array> {
      touched = true;
      throw new Error("input was touched");
    },
  };
  for (const bad of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, null]) {
    const options = { maxDecodedStateBytes: bad } as unknown as {
      maxDecodedStateBytes: number;
    };
    await assert.rejects(
      () => decodeScene(source, options),
      /maxDecodedStateBytes must be a positive safe integer/,
    );
    await assert.rejects(
      () => decodeKeyframeDeltaStreamed(new Uint8Array(0), options),
      /maxDecodedStateBytes must be a positive safe integer/,
    );
    await assert.rejects(
      () => decodeKeyframeDeltaIndexed(new Uint8Array(0), options),
      /maxDecodedStateBytes must be a positive safe integer/,
    );
  }
  assert.equal(touched, false);
});

test("one byte is a resource limit on every collecting decoder", async () => {
  const gaussianBirth = await encodeScene(oneGaussian, 1, {
    maxDepth: 0,
    minChunkGaussians: 1,
  });
  await assert.rejects(
    () => decodeScene(gaussianBirth, { maxDecodedStateBytes: 1 }),
    resourceLimit(/streamed Chunk decode/),
  );
  await assert.rejects(
    () => decodeKeyframeDeltaStreamed(bytes(KEYFRAME_ONLY), { maxDecodedStateBytes: 1 }),
    resourceLimit(/streamed keyframe composition/),
  );
  await assert.rejects(
    () => decodeKeyframeDeltaIndexed(bytes(KEYFRAME_ONLY), { maxDecodedStateBytes: 1 }),
    resourceLimit(/indexed keyframe composition/),
  );
});

test("indexed adapters share one budget and public assembly checks before allocation", async () => {
  const encoded = await encodeScene(oneGaussian, 1, {
    maxDepth: 0,
    minChunkGaussians: 1,
  });
  const source = {
    size: () => Promise.resolve(BigInt(encoded.byteLength)),
    read: (offset: bigint, length: bigint) =>
      Promise.resolve(encoded.subarray(Number(offset), Number(offset + length))),
  } satisfies IReadable;
  const indexed = await IndexedDecoder.open(source);
  const tiny = new DecodedStateBudget(1);
  await assert.rejects(
    () => indexed.readChunk(indexed.index[0]!, { decodedStateBudget: tiny }),
    resourceLimit(/indexed Chunk decode/),
  );
  assert.equal(tiny.retainedBytes, 0);

  const chunk = (await indexed.readChunk(indexed.index[0]!)).gaussians;
  assert.throws(
    () => assembleGaussians([chunk], indexed.windows, 0, null, { maxDecodedStateBytes: 1 }),
    resourceLimit(/final scene assembly/),
  );
  const exact = Number(gaussianSetAssemblyBytes([chunk]));
  assert.equal(
    assembleGaussians([chunk], indexed.windows, 0, null, {
      maxDecodedStateBytes: exact,
    }).count,
    1,
  );
});

test("public assembly validates runtime limits and rejects competing budget sources", () => {
  const nullLimit = { maxDecodedStateBytes: null } as unknown as {
    maxDecodedStateBytes: number;
  };
  assert.throws(
    () => assembleGaussians([], new Float64Array(0), 0, null, nullLimit),
    /maxDecodedStateBytes must be a positive safe integer/,
  );
  assert.throws(
    () =>
      assembleGaussians([], new Float64Array(0), 0, null, {
        maxDecodedStateBytes: DEFAULT_MAX_DECODED_STATE_BYTES,
        decodedStateBudget: new DecodedStateBudget(1),
      }),
    /alternative budget sources/,
  );
});

test("checked row arithmetic cannot wrap around a tiny budget", () => {
  assert.throws(
    () => new DecodedStateBudget(8).checkRows(Number.MAX_SAFE_INTEGER, 104, "hostile row count"),
    resourceLimit(/hostile row count/, 8),
  );
});
