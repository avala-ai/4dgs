// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Conformance runner: streamed decode, canonical JSON to stdout.
 *
 * The whole interface between an implementation and the harness is this: take a path,
 * print the canonical JSON. The resource is read in bounded blocks and never held whole,
 * which is the mode this runner exists to exercise — a decoder that quietly buffered the
 * file would pass the diff and fail the point.
 */

import {
  DEFAULT_MAX_DECODED_STATE_BYTES,
  ExceedsReaderLimit,
  FourdgsError,
  MAGIC,
  Opcode,
  checkMagic,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  iterateRecords,
  keyframeDeltaStatesJson,
  parseHeader,
  type IReadable,
  type Scene,
  validateMaxDecodedStateBytes,
} from "@4dgs/core";
import { FileHandleReadable } from "@4dgs/nodejs";

import { AudioPayloadDigests, canonical, refusalAnswer, summarize } from "./canonical.js";
import { checkStreamedRecords, checkTruncationRecovery } from "./checks.js";

/** Reads small enough that even the smallest variant arrives in several of them. */
const BLOCK_SIZE = 8 * 1024;

/** How much of the front is read to learn the temporal model without decoding gaussians. */
const HEADER_PROBE_BYTES = 64 * 1024;

function decode(readable: IReadable, maxDecodedStateBytes: number): Promise<Scene> {
  return decodeScene(readable, { blockSize: BLOCK_SIZE, maxDecodedStateBytes });
}

/** The Header's temporal model, read from a bounded prefix. */
async function temporalModel(source: IReadable, size: number): Promise<string | null> {
  const probe = await source.read(0n, BigInt(Math.min(size, HEADER_PROBE_BYTES)));
  checkMagic(probe);
  for (const record of iterateRecords(probe, MAGIC.length)) {
    if (record.opcode === Opcode.Header) return parseHeader(record.content).temporalModel;
  }
  return null;
}

export async function run(
  path: string,
  maxDecodedStateBytes = DEFAULT_MAX_DECODED_STATE_BYTES,
): Promise<string> {
  const source = await FileHandleReadable.open(path);
  try {
    const size = Number(await source.size());

    if ((await temporalModel(source, size)) === "keyframe-delta") {
      // The whole model exists to make reconstruction-at-an-instant cheap, and that
      // reconstruction — not a whole-population summary — is what the SDKs are diffed on.
      // Truncation recovery is a gaussian-birth check: the states canonical is a different
      // statement and a cut file is a different file.
      const data = await source.read(0n, BigInt(size));
      return canonical(
        keyframeDeltaStatesJson(await decodeKeyframeDeltaStreamed(data, { maxDecodedStateBytes })),
      );
    }

    const payloads = new AudioPayloadDigests();
    const scene = await decodeScene(source, {
      blockSize: BLOCK_SIZE,
      maxDecodedStateBytes,
      onAudioData: payloads.consume,
    });

    checkStreamedRecords(scene, size);
    await checkTruncationRecovery(source, size, scene, (readable) =>
      decode(readable, maxDecodedStateBytes),
    );

    return canonical(
      summarize({
        header: scene.header,
        gaussians: scene.gaussians,
        audioSources: payloads.sources(scene.audioSources),
        chunkIntervals: scene.chunkIndex.map((entry) => [entry.t0, entry.t1] as const),
        camera: scene.camera,
        metadata: scene.metadata,
        attachments: scene.attachments,
        statistics: scene.statistics,
        summaryOffsets: scene.summaryOffsets,
        summaryCrcOk: scene.summaryCrcOk,
        provenance: scene.provenance,
        objects: scene.objects,
      }),
    );
  } finally {
    await source.close();
  }
}

const argv = process.argv.slice(2);
const injected = argv[0] === "--max-decoded-state-bytes";
const path = injected ? argv[2] : argv[0];
const limitArgument = injected ? argv[1] : undefined;
const maxDecodedStateBytes =
  limitArgument !== undefined && /^[0-9]+$/.test(limitArgument)
    ? Number(limitArgument)
    : injected
      ? Number.NaN
      : DEFAULT_MAX_DECODED_STATE_BYTES;
if (
  path === undefined ||
  (injected ? argv.length !== 3 : argv.length !== 1) ||
  !Number.isSafeInteger(maxDecodedStateBytes) ||
  maxDecodedStateBytes <= 0
) {
  process.stderr.write("usage: decode_streamed.js [--max-decoded-state-bytes N] <file.4dgs>\n");
  process.exit(2);
}
validateMaxDecodedStateBytes(maxDecodedStateBytes);
try {
  process.stdout.write((await run(path, maxDecodedStateBytes)) + "\n");
} catch (error) {
  if (error instanceof ExceedsReaderLimit) {
    process.stdout.write('{"unsupported":"resource-limit"}\n');
  } else {
    // Only this library's own errors are answers. Anything else — a bug in the runner, a
    // failed check in checks.ts — stays a crash, because a decoder must not be able to
    // pass the invalid corpus by falling over in roughly the right place.
    if (!(error instanceof FourdgsError)) throw error;
    // And not even all of those: an error the refusal table cannot name is a failed
    // invocation, not a refusal. It goes to stderr with a non-zero exit, because printing
    // an empty identifier and exiting 0 would claim a valid answer for a failure no
    // expectation can check. See `refusalAnswer`.
    const answer = refusalAnswer(error);
    if (answer === null) {
      process.stderr.write(`${path}: ${error.message}\n`);
      process.exit(1);
    }
    process.stdout.write(answer + "\n");
  }
}
