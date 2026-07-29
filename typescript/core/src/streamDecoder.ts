// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Front-to-back decoding: append bytes, pull records.
 *
 * Works on a pipe, on a file with no index, and on a file that was truncated mid-write —
 * records are length-prefixed, so everything complete before the cut is recoverable. That
 * makes this the right mode for validation, conversion and archival scans, and the wrong
 * one for scrubbing.
 *
 * Framing is synchronous and separate from decoding so the two can be driven by different
 * things: a caller pushes whatever bytes it has, pulls whatever records those completed,
 * and awaits only the payloads it actually wants.
 */

import { MAGIC, RECORD_HEADER_BYTES, type RawRecord, bytesEqual, checkMagic } from "./records.js";
import { Cursor } from "./cursor.js";

/**
 * Incremental record framing over an append-only byte stream.
 *
 * Yielded records are views into the bytes fed in, not copies. They stay valid after
 * further appends: compaction copies the unconsumed tail into a new buffer and leaves the
 * old one to the records that reference it.
 */
export class StreamDecoder {
  private pending: Uint8Array = new Uint8Array(0);
  /** Offset within `pending` of the first unconsumed byte. */
  private cursor = 0;
  /** Resource offset of `pending[0]`. */
  private base = 0;
  private magicChecked = false;
  private ended = false;
  private truncatedFlag = false;

  /** Bytes consumed as complete records, plus the magic. */
  get consumed(): number {
    return this.base + this.cursor;
  }

  /** Bytes held because they do not yet complete a record. */
  get buffered(): number {
    return this.pending.byteLength - this.cursor;
  }

  /**
   * True when the stream ended on something other than a complete file.
   *
   * A complete file ends with the trailing magic, which is shorter than a record header
   * and so is never framed as one; anything else left over is a cut.
   */
  get truncated(): boolean {
    return this.truncatedFlag;
  }

  append(bytes: Uint8Array): void {
    if (this.ended) throw new Error("cannot append after end()");
    if (bytes.byteLength === 0) return;
    if (this.buffered === 0) {
      this.base += this.cursor;
      this.cursor = 0;
      this.pending = bytes;
      return;
    }
    const merged = new Uint8Array(this.buffered + bytes.byteLength);
    merged.set(this.pending.subarray(this.cursor), 0);
    merged.set(bytes, this.buffered);
    this.base += this.cursor;
    this.cursor = 0;
    this.pending = merged;
  }

  /** Every record the bytes seen so far complete. Consumes what it yields. */
  *records(): Generator<RawRecord> {
    if (!this.magicChecked) {
      if (this.buffered < MAGIC.length) return;
      checkMagic(this.pending.subarray(this.cursor));
      this.cursor += MAGIC.length;
      this.magicChecked = true;
    }
    for (;;) {
      if (this.buffered < RECORD_HEADER_BYTES) return;
      const head = new Cursor(this.pending, this.cursor, this.base);
      const offset = this.consumed;
      const opcode = head.u8();
      const length = head.u64();
      if (this.buffered < RECORD_HEADER_BYTES + length) return;
      const start = this.cursor + RECORD_HEADER_BYTES;
      const content = this.pending.subarray(start, start + length);
      const raw = this.pending.subarray(this.cursor, start + length);
      this.cursor = start + length;
      yield { opcode, content, offset, length: length + RECORD_HEADER_BYTES, raw };
    }
  }

  /**
   * Declare the resource exhausted, deciding whether what is left is a clean end.
   *
   * A complete file ends with the magic and nothing after it. Anything else — an
   * incomplete record, a missing trailing magic, a stream that never reached the leading
   * one — is a cut, and what was decoded before it still stands.
   */
  end(): void {
    this.ended = true;
    const leftover = this.pending.subarray(this.cursor);
    this.truncatedFlag = !(this.magicChecked && bytesEqual(leftover, MAGIC));
  }
}
