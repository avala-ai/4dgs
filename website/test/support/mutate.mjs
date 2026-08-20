/**
 * Corpus files bent in specific, documented ways.
 *
 * Each function here produces the file a finding described and the corpus does not contain.
 * They are byte edits on a generated variant rather than hand-written scenes, so what they
 * prove is still anchored to `tests/conformance/data` — only one property of a real file is
 * changed, and the rest of it stays exactly what the generator wrote.
 */

import {
  MAGIC,
  Opcode,
  RECORD_HEADER_BYTES,
  iterateRecords,
  parseChunkIndexEntry,
} from "@4dgs/core";

/** Offset within a Chunk Index entry's content of its `u32` gaussian_count (spec §5.9). */
const INDEX_ENTRY_COUNT_AT = 8 + 8 + 8 + 8;

function records(bytes) {
  return [...iterateRecords(bytes, MAGIC.length)];
}

function join(pieces) {
  let total = 0;
  for (const piece of pieces) total += piece.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const piece of pieces) {
    out.set(piece, at);
    at += piece.length;
  }
  return out;
}

/**
 * One gaussian moved from the first Chunk Index entry to the second.
 *
 * The *total* over the index is unchanged, which is the whole point: a reader that checks
 * only the sum sees nothing wrong and lays the decoded rows out against the wrong chunk
 * intervals.
 */
export function withRedistributedIndexCounts(bytes) {
  const entries = records(bytes)
    .filter((record) => record.opcode === Opcode.ChunkIndex)
    .map((record) => ({
      contentAt: record.offset + RECORD_HEADER_BYTES,
      parsed: parseChunkIndexEntry(record.content),
    }));
  if (entries.length < 2) throw new Error("this variant has fewer than two Chunk Index entries");
  const out = bytes.slice();
  const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
  view.setUint32(
    entries[0].contentAt + INDEX_ENTRY_COUNT_AT,
    entries[0].parsed.gaussianCount - 1,
    true,
  );
  view.setUint32(
    entries[1].contentAt + INDEX_ENTRY_COUNT_AT,
    entries[1].parsed.gaussianCount + 1,
    true,
  );
  return {
    bytes: out,
    firstEntry: entries[0].parsed,
    claimed: entries[0].parsed.gaussianCount - 1,
  };
}

/**
 * The Chunk records written in reverse file order.
 *
 * A conforming `keyframe-delta` file's state chunks tile the timeline in *time* order;
 * nothing says they are stored in it. Safe only on a file whose chunks are all independent
 * keyframes, since a delta names its reference by absolute offset.
 */
export function withStateChunksReversed(bytes) {
  const all = records(bytes);
  const chunks = all.filter((record) => record.opcode === Opcode.Chunk);
  if (chunks.length < 2) throw new Error("this variant has fewer than two state chunks");
  if (all.some((record) => record.opcode === Opcode.DeltaChunk)) {
    throw new Error("reversing storage order is only safe for a file with no delta chunks");
  }
  const pieces = [bytes.slice(0, MAGIC.length)];
  let placed = false;
  for (const record of all) {
    if (record.opcode === Opcode.Chunk) {
      if (!placed) {
        placed = true;
        for (const chunk of [...chunks].reverse()) {
          pieces.push(bytes.slice(chunk.offset, chunk.offset + chunk.length));
        }
      }
      continue;
    }
    pieces.push(bytes.slice(record.offset, record.offset + record.length));
  }
  return { bytes: join(pieces), chunkCount: chunks.length };
}

/**
 * The same file with its Header record grown past `atLeast` bytes.
 *
 * Grown by adding to the attributes map, which is the Header's last field: a `u32` byte
 * length followed by exactly that many bytes of `string` key / `string` value pairs (see
 * `parseHeader` and `Cursor.stringMap`). Everything before it is untouched, so the file
 * still says exactly what it said, at a size a fixed-size probe of the front cannot hold.
 */
export function withPaddedHeader(bytes, atLeast) {
  const header = records(bytes).find((record) => record.opcode === Opcode.Header);
  if (header === undefined) throw new Error("no Header record in this variant");
  const content = header.content;
  const view = new DataView(content.buffer, content.byteOffset, content.byteLength);

  // The map block is the tail of the content, so its length field is the one u32 whose
  // value places the block end exactly at the end of the content.
  let blockAt = -1;
  for (let at = 0; at + 4 <= content.length; at++) {
    if (at + 4 + view.getUint32(at, true) === content.length) {
      blockAt = at;
      break;
    }
  }
  if (blockAt < 0) throw new Error("could not locate the Header's attributes map");
  const blockLength = view.getUint32(blockAt, true);

  const text = new TextEncoder();
  const string = (value) => {
    const encoded = text.encode(value);
    const out = new Uint8Array(4 + encoded.length);
    new DataView(out.buffer).setUint32(0, encoded.length, true);
    out.set(encoded, 4);
    return out;
  };
  const pad = Math.max(atLeast - content.length, 1);
  const added = join([string("test-padding"), string("x".repeat(pad))]);

  const lengthField = new Uint8Array(4);
  new DataView(lengthField.buffer).setUint32(0, blockLength + added.length, true);
  const newContent = join([
    content.subarray(0, blockAt),
    lengthField,
    content.subarray(blockAt + 4),
    added,
  ]);

  const framed = new Uint8Array(RECORD_HEADER_BYTES + newContent.length);
  framed[0] = Opcode.Header;
  new DataView(framed.buffer).setBigUint64(1, BigInt(newContent.length), true);
  framed.set(newContent, RECORD_HEADER_BYTES);

  return {
    bytes: join([
      bytes.slice(0, header.offset),
      framed,
      bytes.slice(header.offset + header.length),
    ]),
    headerRecordBytes: framed.length,
  };
}

/**
 * The file cut immediately after its `n`th state chunk.
 *
 * Returns the cut bytes and that chunk's own `[t0, t1)` read out of the file, so a test can
 * assert against the file's statement of where its chunks end rather than against a number.
 */
export function cutAfterChunk(bytes, n) {
  const chunkRecords = records(bytes).filter(
    (record) => record.opcode === Opcode.Chunk || record.opcode === Opcode.DeltaChunk,
  );
  if (chunkRecords.length <= n) throw new Error(`this variant has ${chunkRecords.length} chunks`);
  const last = chunkRecords[n];
  return { bytes: bytes.slice(0, last.offset + last.length), chunkIndex: n };
}
