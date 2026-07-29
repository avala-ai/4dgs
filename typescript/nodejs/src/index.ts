// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * `@4dgs/nodejs` — file transports.
 *
 * A readable with `pread` semantics, so one open file can serve concurrent range reads
 * without a shared seek position, and a writable for the byte sinks around a decoder —
 * extracting audio source payloads, splitting an attachment out of a scene.
 */

import { open, type FileHandle } from "node:fs/promises";
import type { IReadable } from "@4dgs/core";

/**
 * A local file, read by range.
 *
 * Positional reads throughout: the file handle carries no cursor between reads, so two
 * seeks in flight at once cannot read each other's bytes.
 */
export class FileHandleReadable implements IReadable {
  private constructor(
    private readonly handle: FileHandle,
    private readonly bytes: bigint,
    private readonly owned: boolean,
  ) {}

  /** Open `path` for reading. The returned readable owns the handle; close it. */
  static async open(path: string): Promise<FileHandleReadable> {
    const handle = await open(path, "r");
    try {
      const stat = await handle.stat({ bigint: true });
      return new FileHandleReadable(handle, stat.size, true);
    } catch (error) {
      await handle.close();
      throw error;
    }
  }

  /** Wrap a handle the caller opened. Closing it stays the caller's business. */
  static async wrap(handle: FileHandle): Promise<FileHandleReadable> {
    const stat = await handle.stat({ bigint: true });
    return new FileHandleReadable(handle, stat.size, false);
  }

  size(): Promise<bigint> {
    return Promise.resolve(this.bytes);
  }

  async read(offset: bigint, length: bigint): Promise<Uint8Array> {
    const n = Number(length);
    if (offset < 0n || n < 0 || offset + length > this.bytes) {
      throw new RangeError(
        `range [${offset}, ${offset + length}) is outside the ${this.bytes}-byte file`,
      );
    }
    // A fresh buffer per read: the decoder keeps views into what it is given, so a reused
    // buffer would rewrite records it had already framed.
    const out = new Uint8Array(n);
    let filled = 0;
    while (filled < n) {
      const { bytesRead } = await this.handle.read(
        out,
        filled,
        n - filled,
        Number(offset) + filled,
      );
      if (bytesRead === 0) {
        throw new Error(`short read: wanted ${n} bytes at ${offset}, got ${filled}`);
      }
      filled += bytesRead;
    }
    return out;
  }

  async close(): Promise<void> {
    if (this.owned) await this.handle.close();
  }
}

/** A byte sink over a file handle, for the payloads a decoder hands back. */
export class FileHandleWritable {
  private constructor(
    private readonly handle: FileHandle,
    private readonly owned: boolean,
    private at: bigint,
  ) {}

  /** Open `path` for writing, truncating it. */
  static async create(path: string): Promise<FileHandleWritable> {
    return new FileHandleWritable(await open(path, "w"), true, 0n);
  }

  static wrap(handle: FileHandle, position = 0n): FileHandleWritable {
    return new FileHandleWritable(handle, false, position);
  }

  /** Bytes written so far. */
  get position(): bigint {
    return this.at;
  }

  async write(bytes: Uint8Array): Promise<void> {
    let written = 0;
    while (written < bytes.byteLength) {
      const result = await this.handle.write(
        bytes,
        written,
        bytes.byteLength - written,
        Number(this.at) + written,
      );
      if (result.bytesWritten === 0) {
        throw new Error(`short write: ${written} of ${bytes.byteLength} bytes`);
      }
      written += result.bytesWritten;
    }
    this.at += BigInt(written);
  }

  async close(): Promise<void> {
    if (this.owned) await this.handle.close();
  }
}
