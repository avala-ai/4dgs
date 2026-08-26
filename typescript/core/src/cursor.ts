// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * A bounds-checked read head over a byte buffer.
 *
 * Everything on the wire goes through this, so a reader only has to trust one
 * implementation of "read a length-prefixed thing without walking off the end". Reads
 * return views, never copies, so decoding a chunk does not duplicate it.
 */

import { MalformedFile, TruncatedFile } from "./errors.js";

/**
 * `ignoreBOM: true` is what keeps a leading U+FEFF, and the default would drop it.
 *
 * That default is for decoding a text *file*, where a byte-order mark is a preamble. Every
 * string here is length-prefixed UTF-8 inside a binary record, so U+FEFF is a character the
 * writer wrote — and dropping it made this reader return a different string from the Python,
 * Rust and Dart readers for the same bytes. A `bounds` value, a metadata key and an
 * `object_id` are each a place where that silently changes what the file says.
 */
const textDecoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

/** The largest byte count a JavaScript number addresses exactly: 2^53 - 1. */
export const MAX_ADDRESSABLE_LENGTH = BigInt(Number.MAX_SAFE_INTEGER);

export class Cursor {
  readonly bytes: Uint8Array;
  private readonly view: DataView;
  /** Offset of `bytes[0]` within the resource, for error messages only. */
  private readonly base: number;
  pos: number;

  constructor(bytes: Uint8Array, pos = 0, base = 0) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.pos = pos;
    this.base = base;
  }

  get remaining(): number {
    return this.bytes.byteLength - this.pos;
  }

  /** A cursor over `length` bytes at the current position, without copying. */
  slice(length: number): Cursor {
    const at = this.pos;
    return new Cursor(this.take(length), 0, this.base + at);
  }

  take(n: number): Uint8Array {
    if (n < 0 || !Number.isSafeInteger(n)) {
      throw new MalformedFile(`bad length ${n} at offset ${this.base + this.pos}`);
    }
    if (this.pos + n > this.bytes.byteLength) {
      throw new TruncatedFile(
        `need ${n} bytes at offset ${this.base + this.pos}, ${this.remaining} remain`,
      );
    }
    const out = this.bytes.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  skip(n: number): void {
    this.take(n);
  }

  u8(): number {
    if (this.pos + 1 > this.bytes.byteLength) {
      throw new TruncatedFile(`need 1 byte at offset ${this.base + this.pos}, none remain`);
    }
    return this.view.getUint8(this.pos++);
  }

  u16(): number {
    const at = this.pos;
    this.take(2);
    return this.view.getUint16(at, true);
  }

  u32(): number {
    const at = this.pos;
    this.take(4);
    return this.view.getUint32(at, true);
  }

  /** A `u64` as it sits on the wire, for a caller that classifies the range itself. */
  u64Raw(): bigint {
    const at = this.pos;
    this.take(8);
    return this.view.getBigUint64(at, true);
  }

  /**
   * A `u64`, as a number.
   *
   * Lengths and offsets in this format are byte counts; past 2^53 a JavaScript number
   * cannot represent one exactly, and silently rounding an offset is how a decoder reads
   * the wrong bytes. Refusing is the only safe answer — malformed, for a field inside a
   * record whose framing held. A record's own length is `recordLength()`.
   */
  u64(): number {
    const at = this.base + this.pos;
    const value = this.u64Raw();
    if (value > MAX_ADDRESSABLE_LENGTH) {
      throw new MalformedFile(`64-bit value ${value} at offset ${at} exceeds 2^53`);
    }
    return Number(value);
  }

  /**
   * A record's content length, as the framing walk reads it.
   *
   * On the walk the length *is* the framing: it says how far the file must extend for
   * the record to be all here. A value past 2^53 is a claim no resource this reader can
   * address satisfies — the same finding as a length that runs a few bytes past the end,
   * and classified the same way, so that streamed recovery salvages the prefix in both
   * cases. Python, Rust and Dart read such a file that way; refusing it as malformed let
   * one corrupt byte in a length field refuse a file the other SDKs decode.
   *
   * `recordAt` is the resource offset of the record's opcode byte, so the message names
   * the record and not only the field.
   */
  recordLength(recordAt: number): number {
    const value = this.u64Raw();
    if (value > MAX_ADDRESSABLE_LENGTH) {
      throw new TruncatedFile(
        `the record at byte ${recordAt} declares 0x${value.toString(16)} content bytes, past any resource this reader can address; ${this.remaining} remain`,
      );
    }
    return Number(value);
  }

  f32(): number {
    const at = this.pos;
    this.take(4);
    return this.view.getFloat32(at, true);
  }

  f64(): number {
    const at = this.pos;
    this.take(8);
    return this.view.getFloat64(at, true);
  }

  f32s(n: number): number[] {
    const out: number[] = new Array<number>(n);
    for (let i = 0; i < n; i++) out[i] = this.f32();
    return out;
  }

  f64s(n: number): number[] {
    const out: number[] = new Array<number>(n);
    for (let i = 0; i < n; i++) out[i] = this.f64();
    return out;
  }

  /**
   * `u32` byte length followed by that many UTF-8 bytes. Not NUL-terminated.
   *
   * The offset reported on failure is where the *bytes* start, not where the length
   * prefix does: a reader that refuses a record says which byte is wrong (AGENTS.md
   * §6), and pointing four bytes upstream at a length that decoded fine sends whoever
   * is holding the file to the wrong place in it.
   */
  string(): string {
    const length = this.u32();
    const at = this.pos;
    const raw = this.take(length);
    try {
      return textDecoder.decode(raw);
    } catch {
      throw new MalformedFile(`string at offset ${this.base + at} is not valid UTF-8`);
    }
  }

  /** `u64` byte length followed by that many bytes, returned as a view. */
  blob(): Uint8Array {
    return this.take(this.u64());
  }

  /**
   * `u32` byte length of the whole block, then `string` key / `string` value pairs
   * filling exactly that block.
   *
   * The block length is authoritative: a pair that runs past it is a malformed map, not a
   * map that happens to overlap the next field.
   */
  stringMap(): Map<string, string> {
    const block = this.slice(this.u32());
    const out = new Map<string, string>();
    while (block.remaining > 0) {
      const key = block.string();
      out.set(key, block.string());
    }
    return out;
  }
}
