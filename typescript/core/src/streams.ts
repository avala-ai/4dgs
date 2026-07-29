// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Attribute Stream and SH Band Stream payloads.
 *
 * Payload decoding is fixed by the specification and is the same for every attribute:
 * decompress, reverse the byte-plane shuffle, zigzag-decode, then apply the mode. After
 * decompression every stage is integer arithmetic, which is what makes decoders in
 * different languages produce bit-identical integers.
 *
 * Framing is separated from payload decoding on purpose. Framing is synchronous, so a
 * caller can walk a chunk's streams without awaiting anything; the payloads are then
 * decompressed together, because they are independent and waiting for them one at a time
 * is time spent for no reason.
 */

import { type CodecRegistry, decompressorFor } from "./codec.js";
import type { Cursor } from "./cursor.js";
import { MalformedFile } from "./errors.js";

export const MODE_RAW = 0;
export const MODE_DELTA = 1;
export const MODE_CONST = 2;

/**
 * A declared decoded size above this is refused before anything is allocated.
 *
 * A crafted length must not be able to make a reader allocate half a gigabyte on the way
 * to finding out the file was a lie.
 */
export const MAX_STREAM_BYTES = 512 * 1024 * 1024;

/** `u8` id, width, mode, codec, channels, then `u32` element count and `u64` length. */
const STREAM_HEADER_BYTES = 17;

/** One stream's header plus its still-compressed payload, framed but not decoded. */
export interface RawStream {
  readonly attributeId: number;
  readonly symbolWidth: number;
  readonly mode: number;
  readonly codec: number;
  readonly channels: number;
  readonly elementCount: number;
  readonly payload: Uint8Array;
}

/**
 * Frame every stream in a chunk's records block, decoding no payloads.
 *
 * SH Band Stream records live in their own top-level records rather than here; this walks
 * the concatenated Attribute Streams inside one Chunk.
 */
export function frameStreams(cursor: Cursor): RawStream[] {
  const out: RawStream[] = [];
  while (cursor.remaining > 0) {
    if (cursor.remaining < STREAM_HEADER_BYTES) {
      throw new MalformedFile(
        `chunk has ${cursor.remaining} trailing bytes, too few for an attribute stream header`,
      );
    }
    out.push(frameOneStream(cursor));
  }
  return out;
}

/** Frame a single stream at the cursor, leaving it positioned after the payload. */
export function frameOneStream(cursor: Cursor): RawStream {
  const attributeId = cursor.u8();
  const symbolWidth = cursor.u8();
  const mode = cursor.u8();
  const codec = cursor.u8();
  const channels = cursor.u8();
  const elementCount = cursor.u32();
  const payload = cursor.take(cursor.u64());
  return { attributeId, symbolWidth, mode, codec, channels, elementCount, payload };
}

/**
 * Decode one framed stream to `(elementCount × channels)` signed integers, interleaved.
 *
 * Element-major, so channel `c` of element `i` is at `i * channels + c` — the layout the
 * delta mode accumulates along and the one every attribute reader expects.
 */
export async function decodeStream(stream: RawStream, codecs: CodecRegistry): Promise<Int32Array> {
  const { attributeId, symbolWidth, mode, channels, elementCount } = stream;
  if (elementCount === 0) return new Int32Array(0);
  if (symbolWidth !== 1 && symbolWidth !== 2 && symbolWidth !== 4) {
    throw new MalformedFile(
      `attribute ${attributeId}: symbol width ${symbolWidth} is not 1, 2 or 4`,
    );
  }
  if (mode !== MODE_RAW && mode !== MODE_DELTA && mode !== MODE_CONST) {
    throw new MalformedFile(`attribute ${attributeId}: unknown stream mode ${mode}`);
  }
  if (channels === 0) {
    throw new MalformedFile(`attribute ${attributeId}: zero channels`);
  }

  const symbols = mode === MODE_CONST ? channels : elementCount * channels;
  const expected = symbols * symbolWidth;
  if (expected > MAX_STREAM_BYTES) {
    throw new MalformedFile(
      `attribute ${attributeId} declares ${expected} decoded bytes, past the ${MAX_STREAM_BYTES} cap`,
    );
  }

  // The cap above bounds what arrives; this one bounds what it becomes. A constant stream
  // stores `channels` symbols and repeats them `elementCount` times, so a header declaring
  // 2^30 elements expands a one-byte payload into gigabytes — and a raw stream of one-byte
  // symbols still expands fourfold into Int32. Neither is caught by a cap on the payload,
  // and both are a few bytes of input away from any file.
  const produced = elementCount * channels * 4;
  if (produced > MAX_STREAM_BYTES) {
    throw new MalformedFile(
      `attribute ${attributeId} declares ${elementCount} elements x ${channels} channels, ` +
        `which would decode to ${produced} bytes, past the ${MAX_STREAM_BYTES} cap`,
    );
  }

  const decompress = decompressorFor(stream.codec, codecs);
  const raw = await decompress(stream.payload, expected);
  const values = unshuffleAndUnzigzag(raw, symbolWidth, symbols);

  if (mode === MODE_CONST) {
    const out = new Int32Array(elementCount * channels);
    for (let i = 0; i < elementCount; i++) {
      for (let c = 0; c < channels; c++) out[i * channels + c] = values[c]!;
    }
    return out;
  }
  if (mode === MODE_DELTA) {
    accumulateDeltas(values, channels, attributeId);
  }
  return values;
}

/**
 * Reverse the byte-plane shuffle and the zigzag in one pass.
 *
 * Plane `j` holds byte `j` of every symbol, so symbol `i` is the sum of
 * `raw[j * n + i] << 8j`; zigzag decoding is then `(u >> 1) ^ -(u & 1)`. Doing both in
 * one pass keeps the intermediate out of memory entirely.
 */
export function unshuffleAndUnzigzag(
  raw: Uint8Array,
  symbolWidth: number,
  symbols: number,
): Int32Array {
  const out = new Int32Array(symbols);
  if (symbolWidth === 1) {
    for (let i = 0; i < symbols; i++) {
      const u = raw[i]!;
      out[i] = (u >>> 1) ^ -(u & 1);
    }
    return out;
  }
  if (symbolWidth === 2) {
    for (let i = 0; i < symbols; i++) {
      const u = raw[i]! | (raw[symbols + i]! << 8);
      out[i] = (u >>> 1) ^ -(u & 1);
    }
    return out;
  }
  const p1 = symbols;
  const p2 = symbols * 2;
  const p3 = symbols * 3;
  for (let i = 0; i < symbols; i++) {
    const u = (raw[i]! | (raw[p1 + i]! << 8) | (raw[p2 + i]! << 16) | (raw[p3 + i]! << 24)) >>> 0;
    out[i] = (u >>> 1) ^ -(u & 1);
  }
  return out;
}

/**
 * Delta mode: each symbol is the difference from the previous element of its own channel.
 *
 * The running sum is checked rather than allowed to wrap. A stream whose deltas leave the
 * 32-bit range is a malformed file, and a wrapped value would decode to a plausible
 * wrong number instead of an error.
 */
function accumulateDeltas(values: Int32Array, channels: number, attributeId: number): void {
  const elements = values.length / channels;
  for (let c = 0; c < channels; c++) {
    let acc = values[c]!;
    for (let i = 1; i < elements; i++) {
      acc += values[i * channels + c]!;
      if (acc > 2147483647 || acc < -2147483648) {
        throw new MalformedFile(
          `attribute ${attributeId}: delta stream leaves the 32-bit range at element ${i}`,
        );
      }
      values[i * channels + c] = acc;
    }
  }
}
