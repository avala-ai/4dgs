// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The half of the browser smoke test that runs inside the browser.
 *
 * Two things here cannot be tested from Node, and they are the reasons this file exists:
 * the browser's own `DecompressionStream` doing the inflating, and a real HTTP server
 * answering real range requests. Everything else is the same code the conformance runners
 * use, which is the point — the transports change, the decoder does not.
 */

import { decodeScene, IndexedDecoder, MAX_SH_DEGREE, assembleGaussians } from "@4dgs/core";
import type { ChunkGaussians, ShCoefficients } from "@4dgs/core";
import { BlobReadable, HttpRangeReadable } from "@4dgs/browser";

import { AudioPayloadDigests, canonical, summarize } from "./canonical.js";

export interface PageResult {
  readonly variant: string;
  readonly path: string;
  readonly ok: boolean;
  readonly detail: string;
}

function concatSh(parts: readonly ShCoefficients[], count: number): ShCoefficients | null {
  if (parts.length === 0) return null;
  let length = 0;
  for (const part of parts) length += part.values.length;
  const values = new Uint8Array(length);
  let at = 0;
  for (const part of parts) {
    values.set(part.values, at);
    at += part.values.length;
  }
  return {
    degree: parts[0]!.degree,
    coefficients: parts[0]!.coefficients,
    count,
    values,
    bands: parts[0]!.bands,
  };
}

/** Decode front to back from a `Blob`, the way a dropped file arrives. */
async function viaBlob(variant: string): Promise<string> {
  const response = await fetch(`/data/${variant}.4dgs`);
  const payloads = new AudioPayloadDigests();
  const scene = await decodeScene(new BlobReadable(await response.blob()), {
    onAudioData: payloads.consume,
  });
  return canonical(
    summarize({
      header: scene.header,
      gaussians: scene.gaussians,
      audioSources: payloads.sources(scene.audioSources),
      chunkIntervals: scene.chunkIndex.map((e) => [e.t0, e.t1] as const),
      camera: scene.camera,
      metadata: scene.metadata,
      attachments: scene.attachments,
      statistics: scene.statistics,
      summaryOffsets: scene.summaryOffsets,
      summaryCrcOk: scene.summaryCrcOk,
    }),
  );
}

/** Decode through the index over HTTP range requests, the way a scene on a CDN arrives. */
async function viaRange(variant: string): Promise<string> {
  const readable = new HttpRangeReadable(`/data/${variant}.4dgs`);
  const scene = await IndexedDecoder.open(readable);
  const chunks: ChunkGaussians[] = [];
  const shParts: ShCoefficients[] = [];
  for (const entry of scene.index) {
    const chunk = await scene.readChunk(entry, { maxShBand: MAX_SH_DEGREE });
    chunks.push(chunk.gaussians);
    if (chunk.sh !== null) shParts.push(chunk.sh);
  }
  let count = 0;
  for (const chunk of chunks) count += chunk.count;
  return canonical(
    summarize({
      header: scene.header,
      gaussians: assembleGaussians(
        chunks,
        scene.windows,
        scene.header.shDegree,
        concatSh(shParts, count),
      ),
      audioSources: await scene.readAudioSources(),
      chunkIntervals: scene.index.map((e) => [e.t0, e.t1] as const),
      camera: await scene.readCamera(),
      metadata: await scene.readMetadata(),
      attachments: await scene.readAttachments(),
      statistics: scene.statistics,
      summaryOffsets: scene.summaryOffsets,
      summaryCrcOk: scene.summaryCrcOk,
    }),
  );
}

/** Decode every variant both ways and diff against the committed expectation. */
export async function run(variants: readonly string[]): Promise<PageResult[]> {
  const results: PageResult[] = [];
  for (const variant of variants) {
    const expected = await (await fetch(`/data/${variant}.json`)).text();
    for (const [path, decode] of [
      ["BlobReadable", viaBlob],
      ["HttpRangeReadable", viaRange],
    ] as const) {
      try {
        const actual = await decode(variant);
        const same = JSON.stringify(JSON.parse(actual)) === JSON.stringify(JSON.parse(expected));
        results.push({
          variant,
          path,
          ok: same,
          detail: same
            ? `${JSON.parse(actual).gaussianCount} gaussians`
            : firstDifference(expected, actual),
        });
      } catch (error) {
        results.push({
          variant,
          path,
          ok: false,
          detail: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
        });
      }
    }
  }
  return results;
}

function firstDifference(expected: string, actual: string): string {
  const a = expected.split("\n");
  const b = actual.split("\n");
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) return `line ${i + 1}: expected ${a[i] ?? "<end>"}, got ${b[i] ?? "<end>"}`;
  }
  return "differs, but not by line";
}

declare global {
  interface Window {
    fourdgsSmokeTest?: typeof run;
  }
}

window.fourdgsSmokeTest = run;
