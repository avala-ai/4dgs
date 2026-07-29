// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Stream codecs.
 *
 * `deflate` is the format's default and is decoded with `DecompressionStream`, which
 * every target this package runs on already has — no dependency, no WebAssembly blob, no
 * platform branch. Anything else is supplied by the caller through {@link CodecRegistry},
 * which is how `zstd` stays out of a browser bundle that will never see it.
 */

import { MalformedFile, TruncatedFile, UnsupportedCodec } from "./errors.js";

export const CODEC_DEFLATE = 0;
export const CODEC_ZSTD = 1;

const CODEC_NAMES = new Map<number, string>([
  [CODEC_DEFLATE, "deflate"],
  [CODEC_ZSTD, "zstd"],
  [2, "atlas-image (reserved)"],
  [3, "atlas-video (reserved)"],
]);

/** The registry name for a codec id, for error messages. */
export function codecName(codec: number): string {
  const known = CODEC_NAMES.get(codec);
  if (known) return known;
  return codec >= 128 ? `private codec ${codec}` : `unassigned codec ${codec}`;
}

/**
 * Decompress `input` into exactly `expectedLength` bytes.
 *
 * The decoder always knows the decoded size before it decompresses, so an implementation
 * allocates once, from a number it has already validated, and a payload that expands to
 * anything else is a malformed file rather than a surprise allocation.
 */
export type Decompressor = (input: Uint8Array, expectedLength: number) => Promise<Uint8Array>;

/** Codec id to decompressor. Absent ids are refused by name, not guessed at. */
export type CodecRegistry = ReadonlyMap<number, Decompressor>;

/**
 * RFC 1950 zlib streams — the format's default codec.
 *
 * `DecompressionStream("deflate")` is the zlib wrapper, not raw deflate; the registry
 * says RFC 1950, so this is the right one of the two.
 */
export const inflateZlib: Decompressor = async (input, expectedLength) => {
  if (typeof DecompressionStream === "undefined") {
    throw new UnsupportedCodec(
      "deflate needs DecompressionStream, which this runtime does not provide; " +
        "supply a decompressor for codec 0 through the decode options",
    );
  }
  const stream = new DecompressionStream("deflate");
  const writer = stream.writable.getWriter();
  // The write is driven independently of the read so a payload larger than the internal
  // queue cannot deadlock. Its rejection is deliberately swallowed: the reader below
  // surfaces the same failure with the diagnosis attached.
  const written = (async () => {
    await writer.write(input);
    await writer.close();
  })().catch(() => undefined);

  const out = new Uint8Array(expectedLength);
  let filled = 0;
  const reader = stream.readable.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (filled + value.byteLength > expectedLength) {
        throw new MalformedFile(`stream decompressed past its declared ${expectedLength} bytes`);
      }
      out.set(value, filled);
      filled += value.byteLength;
    }
  } catch (error) {
    // A corrupt payload surfaces as whatever the runtime's inflater throws — a TypeError
    // in Node, a DOMException in a browser. A caller decoding an untrusted file should
    // not have to know which, or which runtime it is on.
    if (error instanceof MalformedFile) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    throw new MalformedFile(`deflate stream is corrupt${detail ? `: ${detail}` : ""}`);
  } finally {
    reader.releaseLock();
    await written;
  }
  if (filled !== expectedLength) {
    throw new TruncatedFile(
      `stream decompressed to ${filled} bytes, header declared ${expectedLength}`,
    );
  }
  return out;
};

/** The codecs a decoder has without being given any. */
export const DEFAULT_CODECS: CodecRegistry = new Map<number, Decompressor>([
  [CODEC_DEFLATE, inflateZlib],
]);

export function decompressorFor(codec: number, registry: CodecRegistry): Decompressor {
  const found = registry.get(codec);
  if (found) return found;
  throw new UnsupportedCodec(
    `stream codec ${codec} (${codecName(codec)}) is not available in this build; ` +
      "register a decompressor for it through the decode options",
  );
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

/** Incremental CRC-32 (IEEE), for records consumed in bounded pieces. */
export class Crc32 {
  private state = 0xffffffff;

  update(bytes: Uint8Array): this {
    for (let i = 0; i < bytes.length; i++) {
      this.state = CRC_TABLE[(this.state ^ bytes[i]!) & 0xff]! ^ (this.state >>> 8);
    }
    return this;
  }

  digest(): number {
    return (this.state ^ 0xffffffff) >>> 0;
  }
}

/** CRC-32 (IEEE), as the Footer's `summary_crc` uses it. */
export function crc32(bytes: Uint8Array): number {
  return new Crc32().update(bytes).digest();
}
