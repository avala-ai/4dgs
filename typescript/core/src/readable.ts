// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The one abstraction the core depends on.
 *
 * A reader needs exactly two things from a resource: how big it is, and the bytes in a
 * range. Everything else — a file, an HTTP server, a cache, an in-memory buffer — is a
 * transport, and transports live at the edges so the decoder can be tested without a
 * network and shipped without a platform.
 */

/** Anything that can report its size and read a byte range. */
export interface IReadable {
  /** Total size of the resource in bytes. */
  size(): Promise<bigint>;

  /**
   * Read exactly `length` bytes starting at `offset`.
   *
   * Implementations MUST return the requested range or throw. Returning a short read
   * silently is the one behaviour that breaks every caller.
   */
  read(offset: bigint, length: bigint): Promise<Uint8Array>;
}

/** A whole resource already in memory. */
export class BytesReadable implements IReadable {
  constructor(private readonly bytes: Uint8Array) {}

  size(): Promise<bigint> {
    return Promise.resolve(BigInt(this.bytes.byteLength));
  }

  read(offset: bigint, length: bigint): Promise<Uint8Array> {
    const at = Number(offset);
    const n = Number(length);
    if (at < 0 || n < 0 || at + n > this.bytes.byteLength) {
      throw new RangeError(
        `range [${at}, ${at + n}) is outside the ${this.bytes.byteLength}-byte resource`,
      );
    }
    return Promise.resolve(this.bytes.subarray(at, at + n));
  }
}
