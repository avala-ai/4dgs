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
import { Cursor, MAX_ADDRESSABLE_LENGTH } from "./cursor.js";

/**
 * One bounded piece of a record selected for incremental consumption.
 *
 * `bytes` is a view into the last appended block. Consumers must finish with it before
 * requesting more records, or copy the bounded portion they intend to retain.
 */
export interface StreamedRecordPart {
  readonly opcode: number;
  /** Resource offset of the record's opcode byte. */
  readonly recordOffset: number;
  /** Total declared bytes in the record body. */
  readonly contentLength: number;
  /** Offset of `bytes[0]` within the record body. */
  readonly contentOffset: number;
  readonly bytes: Uint8Array;
  /** True for the last part, including an empty record body. */
  readonly final: boolean;
}

interface ActiveStreamedRecord {
  readonly opcode: number;
  readonly recordOffset: number;
  readonly contentLength: number;
  emitted: number;
}

const NO_STREAMED_OPCODES: ReadonlySet<number> = new Set();

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
  private activeStreamedRecord: ActiveStreamedRecord | null = null;

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
    for (const item of this.frame(NO_STREAMED_OPCODES)) {
      if ("bytes" in item) throw new Error("internal error: records() yielded a streamed part");
      yield item;
    }
  }

  /**
   * Frame ordinary records and yield selected record bodies incrementally.
   *
   * A selected record never has to fit in `pending`: its header is consumed once, then
   * each appended block is yielded and released before the next block arrives.
   */
  *recordsStreaming(
    streamedOpcodes: ReadonlySet<number>,
  ): Generator<RawRecord | StreamedRecordPart> {
    yield* this.frame(streamedOpcodes);
  }

  private *frame(streamedOpcodes: ReadonlySet<number>): Generator<RawRecord | StreamedRecordPart> {
    if (!this.magicChecked) {
      if (this.buffered < MAGIC.length) return;
      checkMagic(this.pending.subarray(this.cursor));
      this.cursor += MAGIC.length;
      this.magicChecked = true;
    }
    for (;;) {
      const active = this.activeStreamedRecord;
      if (active !== null) {
        const remaining = active.contentLength - active.emitted;
        if (remaining === 0) {
          this.activeStreamedRecord = null;
          yield {
            opcode: active.opcode,
            recordOffset: active.recordOffset,
            contentLength: active.contentLength,
            contentOffset: active.emitted,
            bytes: new Uint8Array(0),
            final: true,
          };
          continue;
        }
        if (this.buffered === 0) return;
        const length = Math.min(this.buffered, remaining);
        const contentOffset = active.emitted;
        const bytes = this.pending.subarray(this.cursor, this.cursor + length);
        this.cursor += length;
        active.emitted += length;
        const final = active.emitted === active.contentLength;
        if (final) this.activeStreamedRecord = null;
        yield {
          opcode: active.opcode,
          recordOffset: active.recordOffset,
          contentLength: active.contentLength,
          contentOffset,
          bytes,
          final,
        };
        continue;
      }
      if (this.buffered < RECORD_HEADER_BYTES) return;
      const head = new Cursor(this.pending, this.cursor, this.base);
      const offset = this.consumed;
      const opcode = head.u8();
      const declared = head.u64Raw();
      // Past 2^53 no resource this reader can address holds the record, so more bytes
      // never complete it. The header stays unconsumed, and `end()` reports the cut the
      // way it does for any other record the resource ended inside.
      if (declared > MAX_ADDRESSABLE_LENGTH) return;
      const length = Number(declared);
      if (streamedOpcodes.has(opcode)) {
        this.cursor += RECORD_HEADER_BYTES;
        this.activeStreamedRecord = {
          opcode,
          recordOffset: offset,
          contentLength: length,
          emitted: 0,
        };
        continue;
      }
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
    this.truncatedFlag = !(
      this.magicChecked &&
      this.activeStreamedRecord === null &&
      bytesEqual(leftover, MAGIC)
    );
  }
}
