// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The record-by-record walk: what is in a file, where, how long, and whether the file's
 * own checksum covers it.
 *
 * Framing only. A record's content is never read, so this costs the same on a scene
 * carrying a six-megabyte audio payload as on one carrying none, and an opcode nobody here
 * has heard of is stepped over by its own declared length — the whole forward-compatibility
 * story, exercised rather than described.
 *
 * The one thing it does read is the tail: the Footer names the byte range its `summary_crc`
 * covers, and "which records are under the checksum, and did the checksum verify" is not
 * answerable from framing alone. That is one bounded read plus a streamed pass over the
 * summary, never the whole file.
 */

import {
  Crc32,
  Cursor,
  FOOTER_TAIL_BYTES,
  FourdgsError,
  MAGIC,
  Opcode,
  RECORD_HEADER_BYTES,
  bytesEqual,
  checkMagic,
  opcodeName,
  parseFooter,
  type IReadable,
} from "@4dgs/core";

/** One record's framing, and its standing with the file's checksum. */
export interface InspectedRecord {
  readonly opcode: number;
  /** The opcode's registry name, or `Unknown(0xNN)` / `Private(0xNN)`. */
  readonly name: string;
  /** Offset of the record's opcode byte. */
  readonly offset: number;
  /** Content bytes, excluding the nine-byte record header. */
  readonly contentLength: number;
  /** Total bytes the record occupies, header included. */
  readonly totalLength: number;
  /** True when this record lies inside the range the Footer's `summary_crc` covers. */
  readonly covered: boolean;
}

/** The summary checksum, as the Footer declares it and as the bytes actually compute. */
export interface SummaryCrc {
  /** First byte covered — the Footer's `summary_start`. */
  readonly start: number;
  /** One past the last byte covered: the Footer record's own first byte. */
  readonly end: number;
  readonly declared: number;
  readonly actual: number;
  readonly ok: boolean;
}

export interface InspectReport {
  readonly size: number;
  readonly records: readonly InspectedRecord[];
  /** True when the last eight bytes are the magic, as a complete file's are. */
  readonly trailingMagic: boolean;
  /**
   * Why the walk stopped early, or `null` when it reached the end.
   *
   * A cut file is reported, not thrown: everything framed before the cut is what the
   * decoder would also recover, and hiding it behind an exception would answer "this file
   * is broken" to a question that was "how far in does it break".
   */
  readonly stopped: string | null;
  /** `null` when the file's summary checksum could not be reached or was never written. */
  readonly summaryCrc: SummaryCrc | null;
  /**
   * Why there is no checksum to report, when there is none — and `null` when there is one.
   *
   * A file that declares no checksum and a file whose tail was cut off both have nothing to
   * verify, and saying so the same way would be the tool misreading the second as the first.
   */
  readonly summaryCrcAbsent: string | null;
}

/** Bytes per read while checksumming the summary. Bounds what is in flight, not what fits. */
const CRC_BLOCK_BYTES = 64 * 1024;

/**
 * Walk `source` record by record.
 *
 * Throws only what the magic check throws — a file that is not ours, or is from a major
 * version this reader does not implement, has no records to walk. Everything after that is
 * reported rather than raised.
 */
export async function inspectFile(source: IReadable): Promise<InspectReport> {
  const size = Number(await source.size());
  checkMagic(await source.read(0n, BigInt(Math.min(MAGIC.length, size))));

  const summary = await readSummaryCrc(source, size);
  const summaryCrc = typeof summary === "string" ? null : summary;
  const summaryCrcAbsent = typeof summary === "string" ? summary : null;
  const records: InspectedRecord[] = [];
  let at = MAGIC.length;
  let trailingMagic = false;
  let stopped: string | null = null;

  for (;;) {
    const remaining = size - at;
    if (remaining <= 0) break;
    // A complete file ends with the magic, which is shorter than a record header and so is
    // never framed as one.
    if (remaining <= MAGIC.length) {
      trailingMagic = bytesEqual(await source.read(BigInt(at), BigInt(remaining)), MAGIC);
      // Anything else in that space is a file that was cut inside its own closing magic:
      // the records all framed, so nothing above reported a stop, and the tail is short by
      // a byte or seven. Saying so here is what keeps `inspect` from exiting 0 on a file
      // the validator refuses one line later for the same reason — "file does not end with
      // the magic" is a finding there, and it was a note here.
      if (!trailingMagic) {
        stopped = `${remaining} bytes at ${at} are not the closing magic; the file is truncated`;
      }
      break;
    }
    if (remaining < RECORD_HEADER_BYTES) {
      stopped = `${remaining} bytes at ${at} are not a record header`;
      break;
    }
    const framing = new Cursor(await source.read(BigInt(at), BigInt(RECORD_HEADER_BYTES)));
    const opcode = framing.u8();
    let contentLength: number;
    try {
      contentLength = framing.u64();
    } catch (error) {
      // A length past 2^53 is a number this runtime cannot hold exactly, and an offset
      // rounded to the nearest even byte reads the wrong record rather than failing.
      stopped = error instanceof FourdgsError ? error.message : String(error);
      break;
    }
    const totalLength = contentLength + RECORD_HEADER_BYTES;
    const end = at + totalLength;
    if (!Number.isSafeInteger(end) || end > size) {
      stopped =
        `the ${opcodeName(opcode)} record at ${at} declares ${contentLength} bytes, ` +
        `past the end of a ${size}-byte file`;
      records.push(row(opcode, at, contentLength, totalLength, summaryCrc));
      break;
    }
    records.push(row(opcode, at, contentLength, totalLength, summaryCrc));
    at = end;
  }

  return { size, records, trailingMagic, stopped, summaryCrc, summaryCrcAbsent };
}

function row(
  opcode: number,
  offset: number,
  contentLength: number,
  totalLength: number,
  summary: SummaryCrc | null,
): InspectedRecord {
  return {
    opcode,
    name: opcodeName(opcode),
    offset,
    contentLength,
    totalLength,
    covered: summary !== null && offset >= summary.start && offset < summary.end,
  };
}

/**
 * The Footer's declared summary checksum, and what the covered bytes actually compute to.
 *
 * A string instead for every file that does not answer the question: one too short to hold
 * a footer, one whose tail is not a Footer record, one that declares no checksum (legal —
 * the field is zero when a writer did not compute one), and one whose declared range is
 * impossible. A checksum nobody can check is not a failed checksum, and each of those is a
 * different reason worth saying out loud.
 */
async function readSummaryCrc(source: IReadable, size: number): Promise<SummaryCrc | string> {
  if (size < MAGIC.length + FOOTER_TAIL_BYTES) {
    return "the file is too short to hold a Footer record";
  }
  const end = size - FOOTER_TAIL_BYTES;
  const tail = await source.read(BigInt(end), BigInt(FOOTER_TAIL_BYTES));
  if (tail[0] !== Opcode.Footer) return "there is no Footer record at the tail";
  let footer;
  try {
    footer = parseFooter(tail.subarray(RECORD_HEADER_BYTES));
  } catch {
    return "the Footer record does not parse";
  }
  if (footer.summaryCrc === 0 || footer.summaryStart === 0) return "the file declares none";
  if (footer.summaryStart > end) {
    return `the Footer's summary starts at ${footer.summaryStart}, after the summary ends at ${end}`;
  }

  const crc = new Crc32();
  for (let at = footer.summaryStart; at < end; at += CRC_BLOCK_BYTES) {
    crc.update(await source.read(BigInt(at), BigInt(Math.min(CRC_BLOCK_BYTES, end - at))));
  }
  const actual = crc.digest();
  return {
    start: footer.summaryStart,
    end,
    declared: footer.summaryCrc,
    actual,
    ok: actual === footer.summaryCrc,
  };
}
