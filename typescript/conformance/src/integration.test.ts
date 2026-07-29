// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Tests over real corpus files and the transports that fetch them.
 *
 * These need `tests/conformance/data`, which is generated rather than committed. When it
 * is absent the corpus tests skip and say so; CI generates it first, so a skip there
 * would be a failure of the workflow rather than of the code.
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  BytesReadable,
  IndexedDecoder,
  MAX_SH_DEGREE,
  assembleGaussians,
  decodeScene,
  type ChunkGaussians,
} from "@4dgs/core";
import { BlobReadable, HttpRangeReadable } from "@4dgs/browser";
import { withCodec } from "@4dgs/codecs";
import { FileHandleReadable } from "@4dgs/nodejs";

import { canonical, summarize } from "./canonical.js";
import { CountingReadable } from "./checks.js";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));

function corpus(variant: string): string | null {
  const path = `${DATA}${variant}.4dgs`;
  return existsSync(path) ? path : null;
}

/** The canonical JSON of a file, decoded front to back. */
async function streamed(path: string): Promise<string> {
  const bytes = new Uint8Array(readFileSync(path));
  const scene = await decodeScene(new BytesReadable(bytes), { blockSize: 4096 });
  return canonical(
    summarize({
      header: scene.header,
      gaussians: scene.gaussians,
      audio: scene.audio,
      chunkIntervals: scene.chunkIndex.map((e) => [e.t0, e.t1] as const),
    }),
  );
}

/** The canonical JSON of a file, read through the index. */
async function indexed(path: string): Promise<string> {
  const source = await FileHandleReadable.open(path);
  try {
    const scene = await IndexedDecoder.open(source);
    const chunks: ChunkGaussians[] = [];
    for (const entry of scene.index) {
      chunks.push((await scene.readChunk(entry, { maxShBand: MAX_SH_DEGREE })).gaussians);
    }
    return canonical(
      summarize({
        header: scene.header,
        gaussians: assembleGaussians(chunks, scene.windows, scene.header.shDegree),
        audio: await scene.readAudio(),
        chunkIntervals: scene.index.map((e) => [e.t0, e.t1] as const),
      }),
    );
  } finally {
    await source.close();
  }
}

test("the two read paths agree on the same file", async (t) => {
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  assert.equal(await streamed(path), await indexed(path));
});

test("both read paths recover the same spherical harmonics", async (t) => {
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");

  const bytes = new Uint8Array(readFileSync(path));
  const scene = await decodeScene(bytes);
  assert.equal(scene.header.shDegree, 2);
  assert.ok(scene.gaussians.sh !== null, "the streamed path decoded no SH");
  assert.equal(scene.gaussians.sh.degree, 2);
  assert.equal(scene.gaussians.sh.coefficients, 8);
  assert.equal(scene.gaussians.sh.values.length, scene.gaussians.count * 3 * 8);

  const source = await FileHandleReadable.open(path);
  try {
    const seekable = await IndexedDecoder.open(source);
    let at = 0;
    for (const entry of seekable.index) {
      const chunk = await seekable.readChunk(entry, { maxShBand: MAX_SH_DEGREE });
      assert.ok(chunk.sh !== null, "the indexed path decoded no SH");
      assert.deepEqual(
        [...chunk.sh.values],
        [...scene.gaussians.sh.values.slice(at, at + chunk.sh.values.length)],
        `chunk at ${entry.t0} disagrees with the streamed decode`,
      );
      at += chunk.sh.values.length;
    }
    assert.equal(at, scene.gaussians.sh.values.length);
  } finally {
    await source.close();
  }
});

test("capping the SH degree yields a whole lower degree", async (t) => {
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));

  const full = await decodeScene(bytes, { maxShBand: MAX_SH_DEGREE });
  const capped = await decodeScene(bytes, { maxShBand: 1 });
  const none = await decodeScene(bytes, { maxShBand: 0 });

  assert.equal(capped.gaussians.sh?.degree, 1);
  assert.equal(capped.gaussians.sh?.coefficients, 3);
  assert.equal(none.gaussians.sh, null);

  // The kept degree is the same data, not a resampling of it: coefficients 0..2 of every
  // component survive the cap unchanged.
  const fullSh = full.gaussians.sh!;
  const cappedSh = capped.gaussians.sh!;
  for (let i = 0; i < 4; i++) {
    for (let c = 0; c < 3; c++) {
      assert.deepEqual(
        [...cappedSh.values.slice(i * 9 + c * 3, i * 9 + c * 3 + 3)],
        [...fullSh.values.slice(i * 24 + c * 8, i * 24 + c * 8 + 3)],
        `gaussian ${i}, component ${c}`,
      );
    }
  }
});

test("the seek rule returns the chunks whose interval contains the instant", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseChunks-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const source = await FileHandleReadable.open(path);
  try {
    const scene = await IndexedDecoder.open(source);
    assert.ok(scene.index.length > 1, "this variant should partition into several chunks");
    for (const entry of scene.index) {
      const middle = entry.t0 + (entry.t1 - entry.t0) / 2;
      assert.ok(scene.chunksForTime(middle).includes(entry));
      assert.ok(!scene.chunksForTime(entry.t1).includes(entry), "the interval is half-open");
    }
    // A time outside every interval costs nothing.
    assert.equal(scene.bytesForTime(1e9), 0);
    assert.deepEqual(scene.chunksForTime(1e9), []);
  } finally {
    await source.close();
  }
});

test("absent audio is a value, and present audio comes back verbatim", async (t) => {
  const withAudio = corpus("OneWindow-UseChunkIndex-UseCrc-WithAudio");
  const without = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (withAudio === null || without === null) return t.skip("corpus not generated");

  const quiet = await decodeScene(new Uint8Array(readFileSync(without)));
  assert.equal(quiet.audio, null);
  assert.equal(quiet.header.hasAudio, false);

  const loud = await decodeScene(new Uint8Array(readFileSync(withAudio)));
  assert.equal(loud.header.hasAudio, true);
  assert.equal(loud.audio?.codec, "wav");
  assert.ok(loud.audio!.data.byteLength > 1000);
  // A RIFF header, byte for byte, out of the middle of a container.
  assert.equal(new TextDecoder().decode(loud.audio!.data.subarray(0, 4)), "RIFF");

  // The indexed path fetches the same bytes without touching a chunk.
  const source = await FileHandleReadable.open(withAudio);
  try {
    const scene = await IndexedDecoder.open(source);
    const track = await scene.readAudio();
    assert.deepEqual(track?.data.byteLength, loud.audio!.data.byteLength);
    assert.equal(track?.codec, "wav");
  } finally {
    await source.close();
  }
});

test("a track larger than the head probe does not cost anything to open", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithLargeAudio");
  if (path === null) return t.skip("corpus not generated");

  const file = await FileHandleReadable.open(path);
  try {
    const counter = new CountingReadable(file);
    const scene = await IndexedDecoder.open(counter);
    const toOpen = counter.bytesRead;

    // The audio record sits in the front matter and is bigger than the probe. Opening the
    // file has to step over it rather than read it, so the cost of opening is the probe
    // and the tail, not the track.
    const track = await scene.readAudio();
    assert.equal(track?.codec, "wav");
    assert.ok(track!.data.byteLength > 64 * 1024, "this variant's track must exceed the probe");
    assert.ok(
      toOpen < track!.data.byteLength,
      `opening transferred ${toOpen} bytes, more than the ${track!.data.byteLength}-byte track it should have skipped`,
    );
    assert.equal(scene.index.length, 1);
    assert.equal(scene.header.gaussianCount, 64);
  } finally {
    await file.close();
  }
});

test("the front matter is walked in windows, however small the probe", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithLargeAudio");
  if (path === null) return t.skip("corpus not generated");

  const file = await FileHandleReadable.open(path);
  try {
    // A probe far too small for even one record forces the scanner to slide repeatedly,
    // and a record larger than the whole window has to be stepped over by arithmetic.
    const cramped = await IndexedDecoder.open(file, { headProbeBytes: 128 });
    const roomy = await IndexedDecoder.open(file);
    assert.equal(cramped.header.gaussianCount, roomy.header.gaussianCount);
    assert.equal(cramped.header.hasAudio, true);
    assert.deepEqual([...cramped.windows], [...roomy.windows]);
    assert.equal(cramped.index.length, roomy.index.length);
    assert.equal((await cramped.readAudio())?.data.byteLength, 96044);
  } finally {
    await file.close();
  }
});

test("a scene with no gaussians decodes to an empty set, not an error", async (t) => {
  const path = corpus("NoData-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const scene = await decodeScene(new Uint8Array(readFileSync(path)));
  assert.equal(scene.gaussians.count, 0);
  assert.deepEqual(scene.chunkIndex, []);
  assert.equal(scene.gaussians.stateAt(0).indices.length, 0);
});

test("reconstructed state at an instant honours the validity window", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const scene = await decodeScene(new Uint8Array(readFileSync(path)));
  const state = scene.gaussians.stateAt(5.0, scene.header.cutoff);
  assert.ok(state.indices.length > 0);
  for (const i of state.indices) {
    assert.ok(scene.gaussians.winLo[i]! <= 5.0 && 5.0 < scene.gaussians.winHi[i]!);
  }
  // Outside every window there is nothing to draw, and that is not an error.
  assert.equal(scene.gaussians.stateAt(1e6).indices.length, 0);
});

test("a codec the file needs and the build lacks is refused by name", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));
  await assert.rejects(
    () => decodeScene(bytes, { codecs: new Map() }),
    /stream codec 0 \(deflate\) is not available/,
  );
});

test("a caller can register a codec of its own", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));
  let calls = 0;
  const registry = withCodec(new Map(), 0, async (input, expected) => {
    calls += 1;
    const { inflateZlib } = await import("@4dgs/core");
    return inflateZlib(input, expected);
  });
  const scene = await decodeScene(bytes, { codecs: registry });
  assert.ok(calls > 0, "the registered codec was never called");
  assert.equal(scene.gaussians.count, 64);
});

test("a blob reads by range like any other transport", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));
  const readable = new BlobReadable(new Blob([bytes]));
  assert.equal(await readable.size(), BigInt(bytes.byteLength));
  assert.deepEqual([...(await readable.read(0n, 8n))], [...bytes.subarray(0, 8)]);
  const scene = await IndexedDecoder.open(readable);
  assert.equal(scene.header.gaussianCount, 64);
});

function rangeServer(bytes: Uint8Array, options: { head: boolean; honourRanges?: boolean }) {
  const calls: string[] = [];
  const impl = ((_url: string, init?: RequestInit) => {
    const method = init?.method ?? "GET";
    const headers = (init?.headers ?? {}) as Record<string, string>;
    calls.push(`${method} ${headers["Range"] ?? ""}`.trim());
    if (method === "HEAD") {
      if (!options.head) return Promise.resolve(new Response(null, { status: 405 }));
      return Promise.resolve(
        new Response(null, {
          status: 200,
          headers: { "content-length": String(bytes.byteLength), "accept-ranges": "bytes" },
        }),
      );
    }
    if (options.honourRanges === false) {
      return Promise.resolve(new Response(bytes, { status: 200 }));
    }
    const match = /bytes=(\d+)-(\d+)/.exec(headers["Range"] ?? "");
    if (match === null) return Promise.resolve(new Response(bytes, { status: 200 }));
    const from = Number(match[1]);
    const to = Number(match[2]);
    return Promise.resolve(
      new Response(bytes.subarray(from, to + 1), {
        status: 206,
        headers: { "content-range": `bytes ${from}-${to}/${bytes.byteLength}` },
      }),
    );
  }) as unknown as typeof fetch;
  return { impl, calls };
}

test("an HTTP resource is sized with HEAD when the server allows it", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));
  const server = rangeServer(bytes, { head: true });
  const readable = new HttpRangeReadable("https://example.invalid/scene.4dgs", {
    fetch: server.impl,
  });
  const scene = await IndexedDecoder.open(readable);
  assert.equal(scene.header.gaussianCount, 64);
  assert.equal(server.calls[0], "HEAD");
  assert.ok(server.calls.slice(1).every((c) => c.startsWith("GET bytes=")));
});

test("a server that refuses HEAD is sized from a one-byte range instead", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const bytes = new Uint8Array(readFileSync(path));
  const server = rangeServer(bytes, { head: false });
  const readable = new HttpRangeReadable("https://example.invalid/scene.4dgs", {
    fetch: server.impl,
  });
  assert.equal(await readable.size(), BigInt(bytes.byteLength));
  assert.deepEqual(server.calls, ["HEAD", "GET bytes=0-0"]);
});

test("a server that ignores Range is caught rather than trusted", async () => {
  const bytes = new Uint8Array(64);
  const server = rangeServer(bytes, { head: true, honourRanges: false });
  const readable = new HttpRangeReadable("https://example.invalid/scene.4dgs", {
    fetch: server.impl,
  });
  await assert.rejects(() => readable.read(0n, 8n), /answered 200 to bytes=0-7/);
});

test("a known size skips the probe entirely", async () => {
  const bytes = new Uint8Array(64);
  const server = rangeServer(bytes, { head: true });
  const readable = new HttpRangeReadable("https://example.invalid/scene.4dgs", {
    fetch: server.impl,
    size: 64n,
  });
  assert.equal(await readable.size(), 64n);
  assert.deepEqual(server.calls, []);
});

test("a file handle refuses a range that runs off the end", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const source = await FileHandleReadable.open(path);
  try {
    const size = await source.size();
    await assert.rejects(() => source.read(size - 4n, 16n), RangeError);
    assert.equal((await source.read(0n, 8n)).byteLength, 8);
  } finally {
    await source.close();
  }
});
