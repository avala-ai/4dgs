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
  Cursor,
  IndexedDecoder,
  MAGIC,
  MAX_SH_DEGREE,
  Opcode,
  RECORD_HEADER_BYTES,
  audioSourceStateAt,
  assembleGaussians,
  decodeScene,
  iterateRecords,
  type ChunkGaussians,
} from "@4dgs/core";
import { BlobReadable, HttpRangeReadable } from "@4dgs/browser";
import { withCodec } from "@4dgs/codecs";
import { FileHandleReadable } from "@4dgs/nodejs";

import { AudioPayloadDigests, canonical, summarize } from "./canonical.js";
import { CountingReadable } from "./checks.js";
import { concat } from "./testing.js";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));

function corpus(variant: string): string | null {
  const path = `${DATA}${variant}.4dgs`;
  return existsSync(path) ? path : null;
}

/** The canonical JSON of a file, decoded front to back. */
async function streamed(path: string): Promise<string> {
  const bytes = new Uint8Array(readFileSync(path));
  const payloads = new AudioPayloadDigests();
  const scene = await decodeScene(new BytesReadable(bytes), {
    blockSize: 4096,
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

/** The canonical JSON of a file, read through the index. */
async function indexed(path: string): Promise<string> {
  const source = await FileHandleReadable.open(path);
  try {
    const scene = await IndexedDecoder.open(source);
    const chunks: ChunkGaussians[] = [];
    const shParts = [];
    for (const entry of scene.index) {
      const chunk = await scene.readChunk(entry, { maxShBand: MAX_SH_DEGREE });
      chunks.push(chunk.gaussians);
      if (chunk.sh !== null) shParts.push(chunk.sh);
    }
    const merged =
      shParts.length === 0
        ? null
        : {
            degree: shParts[0]!.degree,
            coefficients: shParts[0]!.coefficients,
            count: chunks.reduce((n, c) => n + c.count, 0),
            values: concat(shParts.map((p) => p.values)),
            bands: shParts[0]!.bands,
          };
    return canonical(
      summarize({
        header: scene.header,
        gaussians: assembleGaussians(chunks, scene.windows, scene.header.shDegree, merged),
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
  } finally {
    await source.close();
  }
}

test("truncation does not excuse a complete audio source when the Header flag is clear", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  if (path === null) return t.skip("corpus not generated");

  const bytes = Uint8Array.from(readFileSync(path));
  const header = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.Header,
  );
  assert.ok(header);
  const cursor = new Cursor(header.content);
  cursor.string();
  cursor.string();
  cursor.skip(8 + 8 + 8);
  cursor.string();
  cursor.skip(6 * 8);
  cursor.u8();
  const flags = header.offset + RECORD_HEADER_BYTES + cursor.pos;
  bytes[flags] = bytes[flags]! & ~1;

  await assert.rejects(
    () => decodeScene(bytes.subarray(0, bytes.length - 1)),
    /Header audio flag is clear/,
  );

  const payload = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.AudioData,
  );
  assert.ok(payload);
  await assert.rejects(
    () => decodeScene(bytes.subarray(0, payload.offset)),
    /Header audio flag is clear/,
  );
});

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

test("spatial audio sources and their payloads come back independently", async (t) => {
  const withAudio = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  const without = corpus("OneWindow-UseChunkIndex-UseCrc");
  if (withAudio === null || without === null) return t.skip("corpus not generated");

  const quiet = await decodeScene(new Uint8Array(readFileSync(without)));
  assert.deepEqual(quiet.audioSources, []);
  assert.equal(quiet.header.hasAudio, false);

  let payloadBytes = 0;
  let payloadParts = 0;
  let largestPart = 0;
  const riff = new Uint8Array(4);
  const loud = await decodeScene(new Uint8Array(readFileSync(withAudio)), {
    blockSize: 128,
    onAudioData: ({ offset, bytes }) => {
      payloadBytes += bytes.byteLength;
      payloadParts += 1;
      largestPart = Math.max(largestPart, bytes.byteLength);
      if (offset < riff.byteLength) {
        riff.set(bytes.subarray(0, riff.byteLength - offset), offset);
      }
    },
  });
  assert.equal(loud.header.hasAudio, true);
  assert.equal(loud.audioSources[0]?.codec, "wav");
  assert.deepEqual(loud.audioSources[0]?.position, [1.5, 0.75, -0.5]);
  assert.ok(loud.audioSources[0]!.dataLength > 1000);
  assert.equal("data" in loud.audioSources[0]!, false, "the completed scene retained the payload");
  assert.equal(payloadBytes, loud.audioSources[0]!.dataLength);
  assert.ok(payloadParts > 1, "the payload should arrive incrementally");
  assert.ok(largestPart <= 128, `one payload part retained ${largestPart} bytes`);
  // A RIFF header, byte for byte, consumed from the bounded payload pieces.
  assert.equal(new TextDecoder().decode(riff), "RIFF");

  // The indexed path fetches the same bytes without touching a chunk.
  const source = await FileHandleReadable.open(withAudio);
  try {
    const scene = await IndexedDecoder.open(source);
    const sources = await scene.readAudioSources();
    assert.deepEqual(sources[0]?.data.byteLength, loud.audioSources[0]!.dataLength);
    assert.equal(sources[0]?.codec, "wav");
    assert.equal(scene.audioSourceCount, 1);
  } finally {
    await source.close();
  }
});

test("legacy audio payloads arrive in bounded streamed pieces", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  if (path === null) return t.skip("corpus not generated");

  // Reframe the source pair without moving later offsets: the descriptor becomes an
  // unknown, legal record, and the Audio Data body becomes a legacy Audio body. Its
  // variable-size prefix is deliberately split across the decoder's small input blocks.
  const bytes = Uint8Array.from(readFileSync(path));
  const records = [...iterateRecords(bytes, MAGIC.length)];
  const descriptor = records.find((entry) => entry.opcode === Opcode.AudioSource);
  const payload = records.find((entry) => entry.opcode === Opcode.AudioData);
  assert.ok(descriptor && payload);
  bytes[descriptor.offset] = 0x7f;
  bytes[payload.offset] = Opcode.Audio;
  const contentStart = payload.offset + RECORD_HEADER_BYTES;
  const contentLength = payload.length - RECORD_HEADER_BYTES;
  const view = new DataView(bytes.buffer, bytes.byteOffset + contentStart, contentLength);
  view.setUint32(0, 3, true);
  bytes.set(new TextEncoder().encode("wav"), contentStart + 4);
  view.setFloat64(7, 0, true);
  view.setBigUint64(15, BigInt(contentLength - 23), true);

  let payloadBytes = 0;
  let payloadParts = 0;
  let largestPart = 0;
  const scene = await decodeScene(bytes, {
    blockSize: 32,
    onAudioData: ({ bytes: part }) => {
      payloadBytes += part.byteLength;
      payloadParts += 1;
      largestPart = Math.max(largestPart, part.byteLength);
    },
  });
  assert.equal(scene.audioSources.length, 1);
  assert.equal(scene.audioSources[0]!.codec, "wav");
  assert.equal(payloadBytes, scene.audioSources[0]!.dataLength);
  assert.ok(payloadParts > 1);
  assert.ok(largestPart <= 32, `one legacy payload part retained ${largestPart} bytes`);
});

test("a truncated legacy descriptor cannot allocate from its codec length", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  if (path === null) return t.skip("corpus not generated");

  const bytes = Uint8Array.from(readFileSync(path));
  const descriptor = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.AudioSource,
  );
  assert.ok(descriptor);
  bytes[descriptor.offset] = Opcode.Audio;
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  view.setBigUint64(descriptor.offset + 1, BigInt(bytes.byteLength), true);
  view.setUint32(descriptor.offset + RECORD_HEADER_BYTES, 0xffff_ffff, true);

  const scene = await decodeScene(bytes, { blockSize: 32 });
  assert.equal(scene.truncated, true);
  assert.equal(scene.audioSources.length, 0);
});

test("a legacy codec descriptor has a fixed allocation bound", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithLargeAudio");
  if (path === null) return t.skip("corpus not generated");

  const bytes = Uint8Array.from(readFileSync(path));
  const audio = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.AudioData,
  );
  assert.ok(audio);
  bytes[audio.offset] = Opcode.Audio;
  new DataView(bytes.buffer, bytes.byteOffset).setUint32(
    audio.offset + RECORD_HEADER_BYTES,
    5000,
    true,
  );
  await assert.rejects(
    () => decodeScene(bytes, { blockSize: 32 }),
    /descriptor exceeds the bounded 4096-byte limit/,
  );
});

test("indexed opening rejects orphan Audio Data beside legacy audio", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  if (path === null) return t.skip("corpus not generated");

  // Rewrite the descriptor record in place as a valid, empty legacy Audio record. The
  // paired Audio Data record remains, so accepting this would silently ignore an orphan.
  const bytes = Uint8Array.from(readFileSync(path));
  const descriptor = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.AudioSource,
  );
  assert.ok(descriptor);
  bytes[descriptor.offset] = Opcode.Audio;
  const contentStart = descriptor.offset + RECORD_HEADER_BYTES;
  const contentLength = descriptor.length - RECORD_HEADER_BYTES;
  bytes.fill(0, contentStart, contentStart + contentLength);
  const view = new DataView(bytes.buffer, bytes.byteOffset + contentStart, contentLength);
  view.setUint32(0, 3, true);
  bytes.set(new TextEncoder().encode("wav"), contentStart + 4);
  view.setFloat64(7, 0, true);
  view.setBigUint64(15, 0n, true);

  await assert.rejects(
    () => IndexedDecoder.open(new BytesReadable(bytes)),
    /Audio Data id \d+ has no matching Audio Source record/,
  );
});

test("indexed opening rejects Audio Data framing that passes EOF", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio");
  if (path === null) return t.skip("corpus not generated");

  const bytes = Uint8Array.from(readFileSync(path));
  const payload = [...iterateRecords(bytes, MAGIC.length)].find(
    (record) => record.opcode === Opcode.AudioData,
  );
  assert.ok(payload);
  new DataView(bytes.buffer, bytes.byteOffset).setBigUint64(
    payload.offset + 1,
    BigInt(bytes.byteLength),
    true,
  );
  await assert.rejects(
    () => IndexedDecoder.open(new BytesReadable(bytes)),
    /spans .* outside the .*byte file/,
  );
});

test("moving audio source pose is reconstructed at scene time", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithMultipleAudioSources");
  if (path === null) return t.skip("corpus not generated");

  const decoded = await decodeScene(new Uint8Array(readFileSync(path)));
  assert.equal(decoded.audioSources.length, 2);
  const moving = decoded.audioSources.find((source) => source.sourceId === 42);
  assert.ok(moving);
  assert.equal(moving.keyframes.length, 2);
  const halfway = audioSourceStateAt(moving, decoded.header.durationSec / 2);
  assert.deepEqual(halfway.position, [0, 1, 0]);
  assert.ok(Math.abs(halfway.rotation[1]! - Math.SQRT1_2) < 1e-12);
  assert.ok(Math.abs(halfway.rotation[3]! - Math.SQRT1_2) < 1e-12);

  const exactStep = audioSourceStateAt(
    {
      ...moving,
      interpolation: "step",
      keyframes: [
        { time: 0, position: [0, 0, 0], rotation: [0, 0, 0, 1] },
        { time: 1, position: [1, 2, 3], rotation: [0, 1, 0, 1] },
        { time: 2, position: [9, 9, 9], rotation: [0, 0, 0, 1] },
      ],
    },
    1,
  );
  assert.deepEqual(exactStep.position, [1, 2, 3]);
  assert.ok(Math.abs(exactStep.rotation[1]! - Math.SQRT1_2) < 1e-12);
  assert.ok(Math.abs(exactStep.rotation[3]! - Math.SQRT1_2) < 1e-12);
});

test("a track larger than the head probe does not cost anything to open", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithLargeAudio");
  if (path === null) return t.skip("corpus not generated");

  const file = await FileHandleReadable.open(path);
  try {
    const counter = new CountingReadable(file);
    const scene = await IndexedDecoder.open(counter);
    const toOpen = counter.bytesRead;
    const beforeDescriptors = counter.bytesRead;
    const descriptors = await scene.readAudioSourceDescriptors();
    const descriptorBytes = counter.bytesRead - beforeDescriptors;
    assert.equal(descriptors.length, 1);
    assert.ok(descriptors[0]!.dataLength > 64 * 1024);
    assert.ok(
      descriptorBytes < 4096,
      `fetching the descriptor transferred ${descriptorBytes} bytes of encoded audio`,
    );

    // The audio record sits in the front matter and is bigger than the probe. Opening the
    // file has to step over it rather than read it, so the cost of opening is the probe
    // and the tail, not the track.
    const source = (await scene.readAudioSources())[0]!;
    assert.equal(source.codec, "wav");
    assert.ok(source.data.byteLength > 64 * 1024, "this variant's track must exceed the probe");
    assert.ok(
      toOpen < source.data.byteLength,
      `opening transferred ${toOpen} bytes, more than the ${source.data.byteLength}-byte track it should have skipped`,
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
