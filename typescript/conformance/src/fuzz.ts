// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Structural mutation, byte-identical to the Python fuzzer.
 *
 * The generator is a hand-written xorshift32 and every operator consumes it in a fixed
 * order, so seed `n` with operator `k` names the same bytes in both languages. A crash
 * found by one implementation is handed to the other as two integers, and a fix can be
 * shown to hold on the same input rather than on a similar one.
 *
 * Keep this file and `python/fourdgs/tests/test_fuzz.py` in step. `tests/fuzz/README.md`
 * is the shared description of what the operators mean.
 */

import { MAGIC } from "@4dgs/core";

export const OPERATORS = [
  "truncate_at_record",
  "truncate_anywhere",
  "impossible_length",
  "flip_bit",
  "zero_run",
  "max_run",
  "duplicate_record",
  "drop_record",
  "swap_records",
  "corrupt_footer",
  "garbage_tail",
  "random_bytes",
] as const;

export type Operator = (typeof OPERATORS)[number];

/** Lengths a hostile file declares: zero, one, and everything up to the top of a u64. */
const IMPOSSIBLE_LENGTHS = [
  0n,
  1n,
  0xffffn,
  0xffffffffn,
  0x1fffffffffffffn,
  0x7fffffffffffffffn,
  0xffffffffffffffffn,
];

/** xorshift32. Hand-written so every language reproduces the same stream. */
export class Rng {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0 || 0x1234567;
  }

  next(): number {
    let s = this.state;
    s = (s ^ (s << 13)) >>> 0;
    s = (s ^ (s >>> 17)) >>> 0;
    s = (s ^ (s << 5)) >>> 0;
    this.state = s;
    return s;
  }

  below(n: number): number {
    return n > 0 ? this.next() % n : 0;
  }
}

/**
 * `[offset, totalLength]` of every record, walked without the decoder.
 *
 * Deliberately not the library's own framing: a fuzzer that frames its inputs with the
 * code under test cannot mutate what that code refuses to look at.
 */
export function recordSpans(data: Uint8Array): [number, number][] {
  const spans: [number, number][] = [];
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let at = MAGIC.length;
  while (at + 9 <= data.length) {
    const length = Number(view.getBigUint64(at + 1, true));
    if (length > data.length || at + 9 + length > data.length) break;
    spans.push([at, 9 + length]);
    at += 9 + length;
  }
  return spans;
}

function concat(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) total += part.byteLength;
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.byteLength;
  }
  return out;
}

/** One deterministic mutation. `operator` names the shape, `rng` places it. */
export function mutate(data: Uint8Array, operator: Operator, rng: Rng): Uint8Array {
  const spans = recordSpans(data);
  const out = Uint8Array.from(data);

  switch (operator) {
    case "truncate_at_record": {
      if (spans.length === 0) return out;
      const [offset] = spans[rng.below(spans.length)]!;
      return out.subarray(0, offset);
    }
    case "truncate_anywhere":
      return out.subarray(0, rng.below(out.length + 1));
    case "impossible_length": {
      if (spans.length === 0) return out;
      const [offset] = spans[rng.below(spans.length)]!;
      const value = IMPOSSIBLE_LENGTHS[rng.below(IMPOSSIBLE_LENGTHS.length)]!;
      new DataView(out.buffer, out.byteOffset, out.byteLength).setBigUint64(
        offset + 1,
        value,
        true,
      );
      return out;
    }
    case "flip_bit": {
      if (out.length === 0) return out;
      const at = rng.below(out.length);
      out[at] = out[at]! ^ (1 << rng.below(8));
      return out;
    }
    case "zero_run":
    case "max_run": {
      if (out.length === 0) return out;
      const at = rng.below(out.length);
      out.fill(operator === "zero_run" ? 0x00 : 0xff, at, Math.min(at + 8, out.length));
      return out;
    }
    case "duplicate_record": {
      if (spans.length === 0) return out;
      const [offset, length] = spans[rng.below(spans.length)]!;
      return concat([
        out.subarray(0, offset + length),
        out.subarray(offset, offset + length),
        out.subarray(offset + length),
      ]);
    }
    case "drop_record": {
      if (spans.length === 0) return out;
      const [offset, length] = spans[rng.below(spans.length)]!;
      return concat([out.subarray(0, offset), out.subarray(offset + length)]);
    }
    case "swap_records": {
      if (spans.length <= 1) return out;
      const i = rng.below(spans.length);
      const j = rng.below(spans.length);
      if (i === j) return out;
      const [a, la] = spans[Math.min(i, j)]!;
      const [b, lb] = spans[Math.max(i, j)]!;
      return concat([
        out.subarray(0, a),
        out.subarray(b, b + lb),
        out.subarray(a + la, b),
        out.subarray(a, a + la),
        out.subarray(b + lb),
      ]);
    }
    case "corrupt_footer": {
      const tail = out.length - (9 + 20 + MAGIC.length);
      if (tail > 0) {
        const at = tail + 9 + rng.below(20);
        out[at] = out[at]! ^ 0xff;
      }
      return out;
    }
    case "garbage_tail": {
      const keep = rng.below(out.length + 1);
      const count = rng.below(64);
      const noise = new Uint8Array(count);
      for (let i = 0; i < count; i++) noise[i] = rng.below(256);
      return concat([out.subarray(0, keep), noise]);
    }
    case "random_bytes": {
      const length = rng.below(512);
      const body = new Uint8Array(length);
      for (let i = 0; i < length; i++) body[i] = rng.below(256);
      return rng.below(2) ? concat([MAGIC, body]) : body;
    }
  }
}
