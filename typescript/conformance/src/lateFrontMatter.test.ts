// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BytesReadable,
  IndexedDecoder,
  MAGIC,
  MalformedFile,
  Opcode,
  Refusal,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  encodeKeyframeDeltaSequence,
  encodeScene,
  isFrontMatterOpcode,
  isStateOpcode,
  iterateRecords,
  keyframeDeltaValidationRecordOffset,
  opcodeName,
  validateKeyframeDeltaStreamed,
  type GaussianInput,
} from "@4dgs/core";
import { validateFile } from "@4dgs/nodejs";

import { concat, record } from "./testing.js";

interface LateFixture {
  readonly bytes: Uint8Array;
  readonly firstStateOpcode: number;
  readonly firstStateOffset: number;
  readonly lateOffset: number;
}

const FRONT_MATTER_OPCODES: readonly number[] = [
  Opcode.Header,
  Opcode.Quantization,
  Opcode.WindowTable,
  Opcode.Audio,
  Opcode.Camera,
  Opcode.Metadata,
  Opcode.Attachment,
  Opcode.AudioSource,
  Opcode.AudioData,
  Opcode.CoordinateFrame,
  Opcode.SensorCalibration,
  Opcode.RigTrajectory,
  Opcode.GeodeticAnchor,
  Opcode.ObjectTable,
  Opcode.ObjectTrack,
];

const gaussian: GaussianInput = {
  count: 1,
  positions: [0, 0, 0],
  scales: [1, 1, 1],
  rotations: [0, 0, 0, 1],
  colors: [0.5, 0.5, 0.5, 1],
  motions: [0, 0, 0],
  muT: [0.5],
  sigmaT: [0.5],
  winLo: [0],
  winHi: [1],
};

const gaussianBirth = encodeScene(gaussian, 1, {
  writeIndex: false,
  writeCrc: false,
  shBands: 0,
});
const keyframeDelta = encodeKeyframeDeltaSequence([{ t0: 0, ids: [7], gaussians: gaussian }], 1, {
  writeIndex: false,
  writeStatistics: false,
  writeCrc: false,
});

function afterFirstState(source: Uint8Array, opcode: number): LateFixture {
  const state = [...iterateRecords(source, MAGIC.length)].find((item) =>
    isStateOpcode(item.opcode),
  );
  assert.ok(state !== undefined, "the writer emitted a state record");
  const lateOffset = state.offset + state.length;
  return {
    bytes: concat([
      source.subarray(0, lateOffset),
      record(opcode, new Uint8Array(0)),
      source.subarray(lateOffset),
    ]),
    firstStateOpcode: state.opcode,
    firstStateOffset: state.offset,
    lateOffset,
  };
}

function hex(opcode: number): string {
  return `0x${opcode.toString(16).padStart(2, "0").toUpperCase()}`;
}

function checkDiagnosis(error: unknown, fixture: LateFixture, lateOpcode: number): boolean {
  assert.ok(error instanceof MalformedFile, String(error));
  assert.equal(error.refusalCode, Refusal.LateFrontMatterRecord);
  assert.match(
    error.message,
    new RegExp(
      `${opcodeName(lateOpcode)} record \\(opcode ${hex(lateOpcode)}\\) at byte ` +
        `${fixture.lateOffset}`,
    ),
  );
  assert.match(
    error.message,
    new RegExp(
      `first state record, ${opcodeName(fixture.firstStateOpcode)} \\(opcode ` +
        `${hex(fixture.firstStateOpcode)}\\) at byte ${fixture.firstStateOffset}`,
    ),
  );
  assert.match(error.message, /expected every defined front-matter record before/);
  return true;
}

async function checkValidator(fixture: LateFixture, lateOpcode: number): Promise<void> {
  const report = await validateFile(new BytesReadable(fixture.bytes));
  assert.equal(report.ok, false);
  assert.equal(report.refused?.code, Refusal.LateFrontMatterRecord);
  assert.equal(report.refused?.at, fixture.lateOffset);
  assert.equal(report.refused?.where, `the ${opcodeName(lateOpcode)} record`);
  checkDiagnosis(
    new MalformedFile(report.refused!.message, { refusalCode: report.refused!.code }),
    fixture,
    lateOpcode,
  );
}

for (const opcode of FRONT_MATTER_OPCODES) {
  test(`${opcodeName(opcode)} is refused before duplicate or body parsing`, async () => {
    // Every inserted body is empty and therefore hostile to its structured parser.
    // Header, Quantization and WindowTable are also duplicates. Only a placement
    // check before both semantics can give all fifteen records the same answer.
    const gaussianFixture = afterFirstState(await gaussianBirth, opcode);
    const deltaFixture = afterFirstState(await keyframeDelta, opcode);

    await assert.rejects(
      () => decodeScene(new BytesReadable(gaussianFixture.bytes), { recoverTruncated: false }),
      (error: unknown) => checkDiagnosis(error, gaussianFixture, opcode),
    );
    await assert.rejects(
      () => decodeKeyframeDeltaStreamed(deltaFixture.bytes),
      (error: unknown) => checkDiagnosis(error, deltaFixture, opcode),
    );
    await checkValidator(gaussianFixture, opcode);
    await assert.rejects(
      () => validateKeyframeDeltaStreamed(deltaFixture.bytes),
      (error: unknown) => {
        assert.equal(keyframeDeltaValidationRecordOffset(error), deltaFixture.lateOffset);
        return checkDiagnosis(error, deltaFixture, opcode);
      },
    );
  });
}

test("the first state record may itself be a DeltaChunk", async () => {
  const source = Uint8Array.from(await gaussianBirth);
  const state = [...iterateRecords(source, MAGIC.length)].find(
    (item) => item.opcode === Opcode.Chunk,
  );
  assert.ok(state !== undefined);
  source[state.offset] = Opcode.DeltaChunk;
  const fixture = afterFirstState(source, Opcode.Header);

  await assert.rejects(
    () => decodeScene(fixture.bytes, { recoverTruncated: false }),
    (error: unknown) => checkDiagnosis(error, fixture, Opcode.Header),
  );
  await checkValidator(fixture, Opcode.Header);
});

for (const opcode of [0x7f, 0x80]) {
  test(`${opcodeName(opcode)} remains position-independent`, async () => {
    assert.equal(isFrontMatterOpcode(opcode), false);
    const gaussianFixture = afterFirstState(await gaussianBirth, opcode);
    const deltaFixture = afterFirstState(await keyframeDelta, opcode);

    const scene = await decodeScene(gaussianFixture.bytes, { recoverTruncated: false });
    assert.equal(scene.gaussians.count, 1);
    assert.ok(scene.skippedOpcodes.includes(opcode));
    assert.equal((await decodeKeyframeDeltaStreamed(deltaFixture.bytes)).chunks.length, 1);
    assert.equal(await validateKeyframeDeltaStreamed(deltaFixture.bytes), 1);

    const report = await validateFile(gaussianFixture.bytes);
    assert.equal(report.ok, true, report.findings.map((finding) => finding.message).join("\n"));
    assert.equal(report.refused, null);
  });
}

test("the placement classifier is the registry's closed set", () => {
  assert.deepEqual(
    Array.from({ length: 256 }, (_, opcode) => opcode).filter(isFrontMatterOpcode),
    FRONT_MATTER_OPCODES,
  );
  assert.equal(isStateOpcode(Opcode.Chunk), true);
  assert.equal(isStateOpcode(Opcode.DeltaChunk), true);
  assert.equal(isStateOpcode(0x26), false, "reserved opcodes stay unassigned");
});

test("indexed open stops at state; deferred discovery names the late record", async () => {
  const fixture = afterFirstState(await gaussianBirth, Opcode.Metadata);
  const reads: { readonly offset: number; readonly length: number }[] = [];
  const source = {
    size: () => Promise.resolve(BigInt(fixture.bytes.byteLength)),
    read: (offset: bigint, length: bigint): Promise<Uint8Array> => {
      const at = Number(offset);
      const count = Number(length);
      reads.push({ offset: at, length: count });
      return Promise.resolve(fixture.bytes.subarray(at, at + count));
    },
  };
  const opened = await IndexedDecoder.open(source, { headProbeBytes: 32 });
  assert.ok(
    reads.every(
      ({ offset, length }) => fixture.lateOffset < offset || fixture.lateOffset >= offset + length,
    ),
    "indexed open must not scan across state to discover the late record",
  );
  await assert.rejects(
    () => opened.readMetadata(),
    (error: unknown) => checkDiagnosis(error, fixture, Opcode.Metadata),
  );
});
