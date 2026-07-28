// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Runner-side invariants.
 *
 * The canonical JSON is the contract, but it does not observe everything a variant
 * carries: a file's CRC, its statistics record, its camera, and the byte ranges of its SH
 * bands all leave the expectation unchanged. A decoder could ignore every one of them and
 * still diff clean.
 *
 * So the runners check them here instead. A failure throws, the runner exits non-zero,
 * and the harness reports it exactly like a diff — which means a claim in the feature
 * matrix backed by one of these checks is still a claim the suite proves in public CI.
 */

import {
  type ChunkIndexEntry,
  type IReadable,
  type IndexedDecoder,
  type Scene,
  FOOTER_TAIL_BYTES,
  Opcode,
} from "@4dgs/core";

export class CheckFailed extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CheckFailed";
  }
}

function check(condition: boolean, message: string): void {
  if (!condition) throw new CheckFailed(message);
}

/** A readable that reports a smaller size, so a decode sees a file cut at that byte. */
export class TruncatedReadable implements IReadable {
  constructor(
    private readonly inner: IReadable,
    private readonly limit: number,
  ) {}

  size(): Promise<bigint> {
    return Promise.resolve(BigInt(this.limit));
  }

  read(offset: bigint, length: bigint): Promise<Uint8Array> {
    return this.inner.read(offset, length);
  }
}

/** A readable that records how many bytes were actually transferred through it. */
export class CountingReadable implements IReadable {
  bytesRead = 0;

  constructor(private readonly inner: IReadable) {}

  size(): Promise<bigint> {
    return this.inner.size();
  }

  async read(offset: bigint, length: bigint): Promise<Uint8Array> {
    this.bytesRead += Number(length);
    return this.inner.read(offset, length);
  }
}

/**
 * What the front-to-back path can check that the diff cannot.
 *
 * Every record a variant carries is parsed and cross-checked against something else the
 * file says, so a decoder that mis-parsed one of them fails here rather than passing on
 * a summary that never looked.
 */
export function checkStreamedRecords(scene: Scene, size: number): void {
  const { statistics, camera, metadata, attachments, summaryOffsets, header, chunkIndex } = scene;

  if (statistics !== null) {
    check(
      statistics.gaussianCount === header.gaussianCount,
      `statistics say ${statistics.gaussianCount} gaussians, the header says ${header.gaussianCount}`,
    );
    check(
      statistics.durationSec === header.durationSec,
      `statistics say ${statistics.durationSec}s, the header says ${header.durationSec}s`,
    );
    check(statistics.aabb.length === 6, `statistics aabb has ${statistics.aabb.length} values`);
    if (chunkIndex.length > 0) {
      check(
        statistics.chunkCount === chunkIndex.length,
        `statistics say ${statistics.chunkCount} chunks, the index holds ${chunkIndex.length}`,
      );
    }
  }

  if (camera !== null) {
    check(
      camera.position.length === 3 && camera.target.length === 3,
      "camera position and target must be three components each",
    );
    check(
      camera.interpolation === "linear" || camera.interpolation === "spline",
      `camera interpolation "${camera.interpolation}" is not a registry value`,
    );
    let previous = -Infinity;
    for (const keyframe of camera.keyframes) {
      check(
        keyframe.position.length === 3 && keyframe.target.length === 3,
        "camera keyframes carry a position and a target of three components each",
      );
      check(
        keyframe.time >= previous,
        `camera keyframe times run backwards: ${keyframe.time} after ${previous}`,
      );
      previous = keyframe.time;
    }
  }

  for (const entry of metadata) {
    check(entry.name.length > 0, "a metadata record has an empty name");
    check(entry.entries.size > 0, `metadata record "${entry.name}" parsed to an empty map`);
  }

  for (const attachment of attachments) {
    check(attachment.name.length > 0, "an attachment has an empty name");
    check(
      attachment.mediaType.length > 0,
      `attachment "${attachment.name}" has an empty media type`,
    );
    check(attachment.data.byteLength > 0, `attachment "${attachment.name}" parsed to zero bytes`);
  }

  for (const group of summaryOffsets) {
    check(
      group.groupStart > 0 && group.groupLength > 0,
      `summary offset for opcode ${group.groupOpcode} declares an empty range`,
    );
    check(
      group.groupStart + group.groupLength <= size - FOOTER_TAIL_BYTES,
      `summary offset group [${group.groupStart}, ${group.groupStart + group.groupLength}) ` +
        `runs into the footer at ${size - FOOTER_TAIL_BYTES}`,
    );
    if (group.groupOpcode === Opcode.ChunkIndex) {
      check(
        chunkIndex.length > 0,
        "a summary offset points at a chunk index group, but no chunk index was decoded",
      );
    }
  }
}

/**
 * Truncation recovery, checked against the same file cut at two points.
 *
 * Nothing in the corpus is truncated, so this makes one: a readable that reports a
 * smaller size is exactly a file that ends early, and no bytes are copied to build it.
 */
export async function checkTruncationRecovery(
  source: IReadable,
  size: number,
  full: Scene,
  decode: (readable: IReadable) => Promise<Scene>,
): Promise<void> {
  // One byte short of the trailing magic: everything decodes, and the file says so.
  const nearlyWhole = await decode(new TruncatedReadable(source, size - 1));
  check(nearlyWhole.truncated, "a file cut before its trailing magic was not reported truncated");
  check(
    nearlyWhole.gaussians.count === full.gaussians.count,
    `cutting the trailing magic lost gaussians: ${nearlyWhole.gaussians.count} of ` +
      `${full.gaussians.count}`,
  );

  // Cut into the last chunk: every earlier chunk survives, that one does not.
  const index = full.chunkIndex;
  if (index.length >= 2) {
    const last = index[index.length - 1]!;
    const cut = await decode(new TruncatedReadable(source, last.chunkOffset + 5));
    check(cut.truncated, "a file cut inside a chunk record was not reported truncated");
    check(
      cut.gaussians.count === full.gaussians.count - last.gaussianCount,
      `cutting the last chunk left ${cut.gaussians.count} gaussians, expected ` +
        `${full.gaussians.count - last.gaussianCount}`,
    );
  }
}

/**
 * What the indexed path can check that the diff cannot: the summary CRC, the seek rule,
 * and that a band the reader declined is a band it did not transfer.
 */
export async function checkIndexedInvariants(
  scene: IndexedDecoder,
  counter: CountingReadable,
): Promise<void> {
  if (scene.footer.summaryCrc !== 0) {
    check(
      scene.summaryCrcOk === true,
      `the summary CRC does not match: the footer declares ${scene.footer.summaryCrc}`,
    );
  }

  for (const entry of scene.index) {
    // The seek rule, against the index's own intervals.
    const middle = entry.t0 + (entry.t1 - entry.t0) / 2;
    const covering = scene.chunksForTime(middle);
    check(
      covering.includes(entry),
      `chunksForTime(${middle}) does not return the chunk whose interval contains it`,
    );
    check(
      scene.bytesForTime(middle) === covering.reduce((sum, e) => sum + e.chunkLength, 0),
      `bytesForTime(${middle}) disagrees with the chunk lengths it would transfer`,
    );
    check(
      !scene.chunksForTime(entry.t1).includes(entry),
      `chunksForTime returns a chunk at its own exclusive end ${entry.t1}`,
    );

    await checkBandSkipping(scene, entry, counter);
  }
}

/**
 * A reader that has capped its SH degree never transfers the bands above it.
 *
 * Counted at the transport, because that is the claim: not that the coefficients are
 * dropped after arriving, but that their bytes were never asked for.
 */
async function checkBandSkipping(
  scene: IndexedDecoder,
  entry: ChunkIndexEntry,
  counter: CountingReadable,
): Promise<void> {
  if (entry.bands.length === 0) return;

  for (const cap of [0, ...entry.bands.map((b) => b.band)]) {
    const before = counter.bytesRead;
    await scene.readChunk(entry, { maxShBand: cap });
    const transferred = counter.bytesRead - before;
    const wanted =
      entry.chunkLength +
      entry.bands.filter((b) => b.band <= cap).reduce((sum, b) => sum + b.length, 0);
    check(
      transferred === wanted,
      `reading a chunk with maxShBand=${cap} transferred ${transferred} bytes, ` +
        `the index says ${wanted}`,
    );
  }
}
