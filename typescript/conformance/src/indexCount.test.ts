// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/** Regression coverage for the two Chunk Index count claims (spec section 5.8). */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BytesReadable,
  FOOTER_TAIL_BYTES,
  IndexedDecoder,
  KeyframeDeltaIndexedDecoder,
  MAGIC,
  MalformedFile,
  Opcode,
  RECORD_HEADER_BYTES,
  Refusal,
  crc32,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  encodeKeyframeDeltaSequence,
  encodeScene,
  iterateRecords,
  parseChunkIndexEntry,
  parseDeltaChunk,
  parseFooter,
  validateKeyframeDeltaStreamed,
  type ChunkIndexEntry,
  type IReadable,
  type RawRecord,
} from "@4dgs/core";

import {
  CORPUS_LIBRARY,
  KEYFRAME_DELTA_DURATION,
  KEYFRAME_DELTA_VARIANTS,
} from "./keyframeDeltaSequences.js";

type CountField = "gaussian_count" | "live_count";

interface CountMutation {
  readonly bytes: Uint8Array;
  readonly entry: ChunkIndexEntry;
  readonly observed: number;
}

function records(data: Uint8Array): RawRecord[] {
  return [...iterateRecords(data, MAGIC.length)];
}

/** Change only one count claim and repair the summary checksum that covers it. */
function withWrongIndexCount(
  source: Uint8Array,
  field: CountField,
  choose: (entry: ChunkIndexEntry) => boolean,
): CountMutation {
  const bytes = Uint8Array.from(source);
  const indexRecord = records(bytes).find((record) => {
    if (record.opcode !== Opcode.ChunkIndex) return false;
    return choose(parseChunkIndexEntry(record.content));
  });
  assert.ok(indexRecord !== undefined, "the witness carries the requested Chunk Index entry");

  const original = parseChunkIndexEntry(indexRecord.content);
  const contentAt = indexRecord.offset + RECORD_HEADER_BYTES;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let observed: number;
  if (field === "gaussian_count") {
    observed = original.gaussianCount;
    view.setUint32(contentAt + 32, observed + 1, true);
  } else {
    observed = original.liveCount;
    const bandCount = view.getUint32(contentAt + 36, true);
    const extensionAt = contentAt + 40 + bandCount * 17;
    view.setBigUint64(extensionAt + 20, BigInt(observed + 1), true);
  }

  const footerAt = bytes.byteLength - FOOTER_TAIL_BYTES;
  const footerContentAt = footerAt + RECORD_HEADER_BYTES;
  const footer = parseFooter(bytes.subarray(footerContentAt));
  view.setUint32(footerContentAt + 16, crc32(bytes.subarray(footer.summaryStart, footerAt)), true);

  const entry = parseChunkIndexEntry(
    records(bytes).find((record) => record.offset === indexRecord.offset)!.content,
  );
  return { bytes, entry, observed };
}

function checksExactDiagnostic(mutation: CountMutation, field: CountField) {
  return (error: unknown): boolean => {
    assert.ok(error instanceof MalformedFile, String(error));
    assert.equal(error.refusalCode, Refusal.IndexRecordMismatch);
    assert.match(error.message, new RegExp(`chunk index entry at ${mutation.entry.chunkOffset}`));
    const declared =
      field === "gaussian_count" ? mutation.entry.gaussianCount : mutation.entry.liveCount;
    assert.match(error.message, new RegExp(`declares ${field} ${declared}`));
    assert.match(error.message, new RegExp(`is ${mutation.observed}(?:$|\\D)`));
    return true;
  };
}

function oneGaussian() {
  return {
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
}

test("gaussian-birth verifies decoded rows against the index on both read paths", async () => {
  const mutation = withWrongIndexCount(
    await encodeScene(oneGaussian(), 1, { minChunkGaussians: 1 }),
    "gaussian_count",
    () => true,
  );
  const expected = checksExactDiagnostic(mutation, "gaussian_count");

  await assert.rejects(() => decodeScene(new BytesReadable(mutation.bytes)), expected);

  const indexed = await IndexedDecoder.open(new BytesReadable(mutation.bytes));
  await assert.rejects(() => indexed.readChunk(indexed.index[0]!), expected);
});

async function churnFile(): Promise<Uint8Array> {
  const variant = KEYFRAME_DELTA_VARIANTS.find((item) =>
    item.name.startsWith("KeyframeDeltaChurn"),
  )!;
  return encodeKeyframeDeltaSequence(variant.samples, KEYFRAME_DELTA_DURATION, {
    keyframeEvery: variant.keyframeEvery,
    deltaMode: variant.deltaMode,
    library: CORPUS_LIBRARY,
  });
}

/** A range source whose log can be cleared after the bounded open. */
class RecordingReadable implements IReadable {
  readonly reads: { readonly offset: number; readonly length: number }[] = [];

  constructor(private readonly bytes: Uint8Array) {}

  size(): Promise<bigint> {
    return Promise.resolve(BigInt(this.bytes.byteLength));
  }

  read(offset: bigint, length: bigint): Promise<Uint8Array> {
    const start = Number(offset);
    const count = Number(length);
    this.reads.push({ offset: start, length: count });
    return Promise.resolve(this.bytes.subarray(start, start + count));
  }
}

test("keyframe-delta verifies both staged count witnesses on every decoded path", async () => {
  const base = await churnFile();
  const baseRecords = records(base);
  const entries = baseRecords
    .filter((record) => record.opcode === Opcode.ChunkIndex)
    .map((record) => parseChunkIndexEntry(record.content));
  const staged = entries.find((candidate) => {
    if (candidate.kind !== 1) return false;
    const record = baseRecords.find((item) => item.offset === candidate.chunkOffset)!;
    const head = parseDeltaChunk(record.content).header;
    const operations = head.updateCount + head.birthCount + head.deathCount;
    return (
      operations !== candidate.liveCount &&
      entries.some((entry) => entry.referenceOffset === candidate.chunkOffset)
    );
  });
  assert.ok(
    staged !== undefined,
    "the staged witness distinguishes operations from population on an intermediate delta",
  );
  for (const field of ["gaussian_count", "live_count"] as const) {
    const mutation = withWrongIndexCount(
      base,
      field,
      (entry) => entry.chunkOffset === staged.chunkOffset,
    );
    const expected = checksExactDiagnostic(mutation, field);
    const deltaRecord = records(base).find(
      (record) => record.offset === mutation.entry.chunkOffset,
    )!;
    const delta = parseDeltaChunk(deltaRecord.content).header;
    const operations = delta.updateCount + delta.birthCount + delta.deathCount;
    assert.equal(
      mutation.observed,
      field === "gaussian_count" ? operations : mutation.entry.liveCount - 1,
    );
    assert.notEqual(operations, mutation.entry.liveCount - (field === "live_count" ? 1 : 0));

    await assert.rejects(() => decodeKeyframeDeltaStreamed(mutation.bytes), expected);
    await assert.rejects(() => decodeKeyframeDeltaIndexed(mutation.bytes), expected);
    await assert.rejects(() => validateKeyframeDeltaStreamed(mutation.bytes), expected);

    const source = new RecordingReadable(mutation.bytes);
    const opened = await KeyframeDeltaIndexedDecoder.open(source);
    const selected = opened.index.find(
      (entry) => entry.referenceOffset === mutation.entry.chunkOffset,
    );
    assert.ok(selected !== undefined, "the staged wrong entry is an intermediate chain link");
    await assert.rejects(() => opened.chunkAt((selected.t0 + selected.t1) / 2), expected);

    const unrelatedKeyframe = opened.index.find(
      (entry) => entry.kind === 0 && entry.chunkOffset !== mutation.entry.keyframeOffset,
    );
    assert.ok(unrelatedKeyframe !== undefined, "the witness has an independent GOP");
    source.reads.length = 0;
    const unrelated = await opened.chunkAt((unrelatedKeyframe.t0 + unrelatedKeyframe.t1) / 2);
    assert.equal(unrelated.state.count, unrelatedKeyframe.liveCount);
    const wrongStart = mutation.entry.chunkOffset;
    const wrongEnd = wrongStart + mutation.entry.chunkLength;
    assert.ok(
      source.reads.every(
        (read) => read.offset + read.length <= wrongStart || read.offset >= wrongEnd,
      ),
      "a seek into another GOP must not fetch the unrelated mismatched entry",
    );
  }
});

test("keyframe-delta checks both count claims on extended keyframe entries", async () => {
  const base = await churnFile();
  for (const field of ["gaussian_count", "live_count"] as const) {
    const mutation = withWrongIndexCount(base, field, (entry) => entry.kind === 0);
    const expected = checksExactDiagnostic(mutation, field);
    await assert.rejects(() => decodeKeyframeDeltaStreamed(mutation.bytes), expected);

    const opened = await KeyframeDeltaIndexedDecoder.open(new BytesReadable(mutation.bytes));
    await assert.rejects(
      () => opened.chunkAt((mutation.entry.t0 + mutation.entry.t1) / 2),
      expected,
    );
  }
});
