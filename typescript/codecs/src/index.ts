// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * `@4dgs/codecs` — the optional codecs, kept out of the core.
 *
 * The format's default is deflate, which every runtime already has, and `@4dgs/core`
 * therefore depends on nothing. `zstd` is the codec a producer reaches for when every
 * byte counts and the consumer is known, and it is not universally available — so it
 * lives here, behind an explicit opt-in, and a browser bundle that will never meet a zstd
 * file does not carry the machinery for one.
 *
 * ```ts
 * import { decodeScene, DEFAULT_CODECS } from "@4dgs/core";
 * import { withZstd } from "@4dgs/codecs";
 *
 * const scene = await decodeScene(bytes, { codecs: withZstd(DEFAULT_CODECS) });
 * ```
 */

import { CODEC_ZSTD, UnsupportedCodec, type CodecRegistry, type Decompressor } from "@4dgs/core";

/**
 * A zstd decompressor built on the runtime's own implementation.
 *
 * Node has had zstd in `node:zlib` since 22.15; where it is missing the error says so
 * rather than failing somewhere further down, and a caller with its own implementation
 * can register that instead through {@link withCodec}.
 */
export function nodeZstdDecompressor(): Decompressor {
  return async (input, expectedLength) => {
    const decompress = await loadNodeZstd();
    const out = await decompress(input, expectedLength);
    if (out.byteLength !== expectedLength) {
      throw new UnsupportedCodec(
        `zstd stream decompressed to ${out.byteLength} bytes, header declared ${expectedLength}`,
      );
    }
    return out;
  };
}

/** The default registry plus zstd. */
export function withZstd(base: CodecRegistry): CodecRegistry {
  return withCodec(base, CODEC_ZSTD, nodeZstdDecompressor());
}

/** A registry with one codec added or replaced. Registries are never mutated in place. */
export function withCodec(
  base: CodecRegistry,
  codec: number,
  decompressor: Decompressor,
): CodecRegistry {
  const next = new Map(base);
  next.set(codec, decompressor);
  return next;
}

type ZstdFunction = (
  input: Uint8Array,
  options: unknown,
  callback: (error: Error | null, result: Uint8Array) => void,
) => void;

let cached: ((input: Uint8Array, expected: number) => Promise<Uint8Array>) | null = null;

async function loadNodeZstd(): Promise<
  (input: Uint8Array, expected: number) => Promise<Uint8Array>
> {
  if (cached !== null) return cached;

  let zlib: Record<string, unknown>;
  try {
    zlib = (await import("node:zlib")) as unknown as Record<string, unknown>;
  } catch {
    throw new UnsupportedCodec(
      "zstd needs a runtime implementation; this one has no node:zlib. " +
        "Register your own decompressor for codec 1 with withCodec()",
    );
  }
  const raw = zlib["zstdDecompress"];
  if (typeof raw !== "function") {
    throw new UnsupportedCodec(
      "this runtime's node:zlib has no zstdDecompress (Node 22.15 or newer has it). " +
        "Register your own decompressor for codec 1 with withCodec()",
    );
  }
  const zstdDecompress = raw as ZstdFunction;
  cached = (input, expected) =>
    new Promise<Uint8Array>((resolve, reject) => {
      // The decoded size is known before decompression, so the output window is bounded
      // by a number the reader has already validated rather than by whatever the payload
      // claims once it is running.
      zstdDecompress(input, { maxOutputLength: expected }, (error, result) => {
        if (error) reject(error);
        else resolve(new Uint8Array(result.buffer, result.byteOffset, result.byteLength));
      });
    });
  return cached;
}
