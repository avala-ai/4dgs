// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Test-only encoders.
 *
 * The reference encoder is Python's; this builds just enough of the wire format in
 * TypeScript to feed the decoder bytes whose correct decoding is known by construction —
 * a stream with values chosen by hand, rather than values that happen to be in a corpus
 * file. It is not a writer and is not exported from any published package.
 */

export const MODE_RAW = 0;
export const MODE_DELTA = 1;
export const MODE_CONST = 2;

/** Deflate, through the same standard facility the decoder inflates with. */
export async function deflate(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new CompressionStream("deflate");
  const writer = stream.writable.getWriter();
  const written = (async () => {
    await writer.write(bytes);
    await writer.close();
  })();
  const parts: Uint8Array[] = [];
  const reader = stream.readable.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
  }
  await written;
  return concat(parts);
}

export function concat(parts: readonly Uint8Array[]): Uint8Array {
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

export function zigzag(value: number): number {
  return ((value << 1) ^ (value >> 31)) >>> 0;
}

/** Byte-plane shuffle: all least-significant bytes, then the next plane, and so on. */
export function shuffle(symbols: readonly number[], width: number): Uint8Array {
  const out = new Uint8Array(symbols.length * width);
  for (let i = 0; i < symbols.length; i++) {
    for (let j = 0; j < width; j++) {
      out[j * symbols.length + i] = (symbols[i]! >>> (8 * j)) & 0xff;
    }
  }
  return out;
}

export interface TestStreamOptions {
  readonly attributeId: number;
  /** Element-major values, `elementCount × channels`. */
  readonly values: readonly number[];
  readonly channels: number;
  readonly mode?: number;
  readonly symbolWidth?: number;
  readonly codec?: number;
}

/** One Attribute Stream record body: header, then a deflated shuffled payload. */
export async function encodeTestStream(options: TestStreamOptions): Promise<Uint8Array> {
  const { attributeId, values, channels } = options;
  const mode = options.mode ?? MODE_RAW;
  const width = options.symbolWidth ?? 1;
  const codec = options.codec ?? 0;
  const elementCount = mode === MODE_CONST ? values.length / channels : values.length / channels;

  let symbols: number[];
  if (mode === MODE_DELTA) {
    symbols = [];
    for (let i = 0; i < values.length / channels; i++) {
      for (let c = 0; c < channels; c++) {
        const here = values[i * channels + c]!;
        const previous = i === 0 ? 0 : values[(i - 1) * channels + c]!;
        symbols.push(zigzag(i === 0 ? here : here - previous));
      }
    }
  } else {
    symbols = values.map(zigzag);
  }

  const payload = await deflate(shuffle(symbols, width));
  const head = new Uint8Array(17);
  const view = new DataView(head.buffer);
  head[0] = attributeId;
  head[1] = width;
  head[2] = mode;
  head[3] = codec;
  head[4] = channels;
  view.setUint32(5, elementCount, true);
  view.setBigUint64(9, BigInt(payload.byteLength), true);
  return concat([head, payload]);
}

/** A record: `u8` opcode, `u64` content length, content. */
export function record(opcode: number, content: Uint8Array): Uint8Array {
  const head = new Uint8Array(9);
  head[0] = opcode;
  new DataView(head.buffer).setBigUint64(1, BigInt(content.byteLength), true);
  return concat([head, content]);
}
