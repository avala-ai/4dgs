// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Walking the records at the front of a file by header, never by content.
 *
 * An indexed reader wants four things from the front matter — the Header, the
 * Quantization grids, the Window Table, and the byte ranges of any audio sources — and
 * none of them requires reading a record it does not care about. That distinction is not
 * academic: encoded audio payloads are first-class parts of a scene and land in the front
 * matter at arbitrary sizes, so a walk that materializes every record's content defeats
 * bounded indexed opening.
 *
 * So this steps over a record by arithmetic. The length is in the header; the bytes are
 * not needed to find the next record. Content is fetched only for records the caller asks
 * for, and only then, which for a scene with a 6 MB track is the difference between one
 * bounded read and a failure.
 */

import { Cursor } from "./cursor.js";
import { MalformedFile } from "./errors.js";
import type { IReadable } from "./readable.js";
import { RECORD_HEADER_BYTES } from "./records.js";

/** One record's framing: everything except its bytes. */
export interface FrontMatterRecord {
  readonly opcode: number;
  /** Offset of the record's opcode byte. */
  readonly offset: number;
  /** Length of the record's content, excluding the header. */
  readonly contentLength: number;
  /** Total bytes the record occupies, header included. */
  readonly totalLength: number;
}

/**
 * A sliding window over the front of a resource.
 *
 * Only one window is resident at a time, and it never grows past the probe size the
 * caller chose. A record larger than the window is stepped over, not buffered.
 */
export class FrontMatterScanner {
  private window: Uint8Array = new Uint8Array(0);
  private windowAt = 0;

  constructor(
    private readonly source: IReadable,
    private readonly size: number,
    private readonly probeBytes: number,
  ) {}

  /** The first `length` bytes of the resource, for the magic check. */
  async head(length: number): Promise<Uint8Array> {
    await this.ensure(0, Math.min(length, this.size));
    return this.window.subarray(0, Math.min(length, this.window.byteLength));
  }

  /** Every record from `from`, in file order, reading a bounded window at a time. */
  async *records(from: number): AsyncGenerator<FrontMatterRecord> {
    let at = from;
    while (at + RECORD_HEADER_BYTES <= this.size) {
      await this.ensure(at, RECORD_HEADER_BYTES);
      const cursor = new Cursor(this.window, at - this.windowAt, this.windowAt);
      const opcode = cursor.u8();
      const contentLength = cursor.u64();
      const totalLength = contentLength + RECORD_HEADER_BYTES;
      const end = at + totalLength;
      if (!Number.isSafeInteger(totalLength) || !Number.isSafeInteger(end) || end > this.size) {
        throw new MalformedFile(
          `record opcode 0x${opcode.toString(16).padStart(2, "0")} at offset ${at} spans ` +
            `[${at}, ${end}), outside the ${this.size}-byte file`,
        );
      }
      yield { opcode, offset: at, contentLength, totalLength };
      at = end;
    }
  }

  /**
   * The content of one record.
   *
   * Served from the window when the record happens to be in it, and by a read of exactly
   * that record otherwise — so a Window Table larger than the probe is fetched rather
   * than refused, and audio payloads that nobody asked for are never fetched at all.
   */
  async content(record: FrontMatterRecord, limit = Number.POSITIVE_INFINITY): Promise<Uint8Array> {
    const at = record.offset + RECORD_HEADER_BYTES;
    const length = Math.min(record.contentLength, limit, this.size - at);
    if (this.covers(at, length)) {
      return this.window.subarray(at - this.windowAt, at - this.windowAt + length);
    }
    if (length <= this.probeBytes) {
      await this.ensure(at, length);
      return this.window.subarray(at - this.windowAt, at - this.windowAt + length);
    }
    return this.source.read(BigInt(at), BigInt(length));
  }

  private covers(at: number, length: number): boolean {
    return at >= this.windowAt && at + length <= this.windowAt + this.window.byteLength;
  }

  private async ensure(at: number, length: number): Promise<void> {
    if (this.covers(at, length)) return;
    if (at < 0 || at + length > this.size) {
      throw new MalformedFile(
        `a record spans [${at}, ${at + length}), outside the ${this.size}-byte file`,
      );
    }
    const want = Math.min(Math.max(this.probeBytes, length), this.size - at);
    this.window = await this.source.read(BigInt(at), BigInt(want));
    this.windowAt = at;
  }
}
