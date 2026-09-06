// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/** Aggregate decoded-state accounting for collecting reader operations. */

import type { ChunkGaussians } from "./chunk.js";
import { ExceedsReaderLimit } from "./errors.js";

/** The shared default for collecting decoded gaussian state: 512 MiB. */
export const DEFAULT_MAX_DECODED_STATE_BYTES = 536_870_912;

/** Validate the public positive-integer decoded-state ceiling. */
export function validateMaxDecodedStateBytes(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new RangeError("maxDecodedStateBytes must be a positive safe integer");
  }
  return value;
}

/** One collecting call's retained decoded-state bytes and peak checks. */
export class DecodedStateBudget {
  readonly limit: number;
  #retainedBytes = 0;

  constructor(limit = DEFAULT_MAX_DECODED_STATE_BYTES) {
    this.limit = validateMaxDecodedStateBytes(limit);
  }

  /** Decoded state already owned by the collecting result. */
  get retainedBytes(): number {
    return this.#retainedBytes;
  }

  /** Bytes still available before the configured ceiling is reached. */
  get remainingBytes(): number {
    return this.limit - this.#retainedBytes;
  }

  /** Check a simultaneous allocation without retaining it. */
  check(additionalBytes: number | bigint, phase: string): number {
    let additional: bigint;
    if (typeof additionalBytes === "number") {
      if (!Number.isSafeInteger(additionalBytes) || additionalBytes < 0) {
        throw new Error("decoded-state accounting requires a non-negative safe integer");
      }
      additional = BigInt(additionalBytes);
    } else {
      if (additionalBytes < 0n) {
        throw new Error("decoded-state accounting cannot subtract through check");
      }
      additional = additionalBytes;
    }
    const required = BigInt(this.#retainedBytes) + additional;
    if (required > BigInt(this.limit)) {
      throw new ExceedsReaderLimit(
        `decoded-state resource limit during ${phase}: at least ${required} bytes are required; ` +
          `configured limit is ${this.limit} bytes`,
      );
    }
    return Number(required);
  }

  /** Check `rows * bytesPerRow` using arithmetic that cannot wrap. */
  checkRows(rows: number, bytesPerRow: number, phase: string): number {
    if (
      !Number.isSafeInteger(rows) ||
      rows < 0 ||
      !Number.isSafeInteger(bytesPerRow) ||
      bytesPerRow <= 0
    ) {
      throw new Error(
        "decoded-state row accounting requires non-negative safe-integer rows and a positive width",
      );
    }
    return this.check(BigInt(rows) * BigInt(bytesPerRow), phase);
  }

  /** Charge decoded output that remains owned by the collecting result. */
  retain(addedBytes: number, phase: string): number {
    const retained = this.check(addedBytes, phase);
    this.#retainedBytes = retained;
    return retained;
  }

  /** Release a replaced buffer that the collector no longer owns. */
  release(releasedBytes: number): void {
    if (
      !Number.isSafeInteger(releasedBytes) ||
      releasedBytes < 0 ||
      releasedBytes > this.#retainedBytes
    ) {
      throw new Error("decoded-state accounting released non-retained bytes");
    }
    this.#retainedBytes -= releasedBytes;
  }
}

/** Element capacity retained by one decoded gaussian-birth Chunk. */
export function decodedChunkStateBytes(chunk: ChunkGaussians): number {
  return (
    chunk.positions.byteLength +
    chunk.scales.byteLength +
    chunk.rotations.byteLength +
    chunk.colors.byteLength +
    chunk.motions.byteLength +
    chunk.muT.byteLength +
    chunk.sigmaT.byteLength +
    chunk.windowIndex.byteLength +
    (chunk.sourceGroup?.byteLength ?? 0) +
    (chunk.sourceIndex?.byteLength ?? 0) +
    (chunk.objectId?.byteLength ?? 0)
  );
}

/** Capacity of the arrays allocated by final gaussian-birth assembly. */
export function gaussianSetAssemblyBytes(chunks: readonly ChunkGaussians[]): bigint {
  let count = 0n;
  let sourceGroup = false;
  let sourceIndex = false;
  let objectId = false;
  for (const chunk of chunks) {
    count += BigInt(chunk.count);
    sourceGroup ||= chunk.sourceGroup !== null;
    sourceIndex ||= chunk.sourceIndex !== null;
    objectId ||= chunk.objectId !== null;
  }
  // 21 f32 lanes: position, scale, rotation, colour, motion, mu, sigma, winLo, winHi.
  const identityLanes = Number(sourceGroup) + Number(sourceIndex) + Number(objectId);
  return count * BigInt(21 * Float32Array.BYTES_PER_ELEMENT + identityLanes * 4);
}
