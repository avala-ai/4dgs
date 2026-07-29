// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Indexed reading: the Footer, then the index, then only what an instant needs.
 *
 * The seek rule is one line and it is the whole algorithm:
 *
 *     chunksForTime(t) === every index entry whose [t0, t1) contains t
 *
 * Whether that is cheap depends on the content, not on this code. Gaussians with finite
 * lifetimes partition into many small chunks; content where everything lives for the
 * whole clip collapses to a single entry and an instant costs the scene. Both are correct
 * files, and a caller that wants to know which it has can ask `bytesForTime` before it
 * asks for the bytes.
 */

import {
  type ChunkGaussians,
  chunkStreamBytes,
  decodeChunkStreams,
  type DecodeChunkOptions,
  stepsFrom,
} from "./chunk.js";
import { crc32, DEFAULT_CODECS, type CodecRegistry } from "./codec.js";
import { MalformedFile } from "./errors.js";
import { FrontMatterScanner } from "./frontMatter.js";
import { Opcode } from "./opcodes.js";
import { DEFAULT_CUTOFF, supportK } from "./quantization.js";
import type { IReadable } from "./readable.js";
import {
  type AudioTrack,
  type ChunkIndexEntry,
  type Footer,
  type Header,
  type Attachment,
  type Camera,
  type Metadata,
  type Quantization,
  type Statistics,
  type SummaryOffset,
  FOOTER_TAIL_BYTES,
  MAGIC,
  bytesEqual,
  checkMagic,
  entryCovers,
  iterateRecords,
  parseAudio,
  parseChunk,
  parseAttachment,
  parseCamera,
  parseChunkIndexEntry,
  parseFooter,
  parseMetadata,
  parseHeader,
  parseQuantization,
  parseShBandRecord,
  parseStatistics,
  parseSummaryOffset,
  parseWindowTable,
  readRecord,
} from "./records.js";
import { Cursor } from "./cursor.js";
import { MAX_SH_DEGREE, mergeBands, type ShCoefficients } from "./sh.js";
import { decodeStream, frameOneStream } from "./streams.js";

/**
 * One read of this size from the front covers the header records of every scene measured
 * so far. A larger header costs one extra round trip, never a wrong parse.
 */
export const HEAD_PROBE_BYTES = 64 * 1024;

/**
 * How much of an Audio record is read to learn its codec.
 *
 * The codec name is the record's first field, so a prefix answers it. The track itself
 * stays where it is until somebody asks for it.
 */
const AUDIO_CODEC_PREFIX_BYTES = 4096;

/** Where a record the reader has not parsed lives. */
interface ByteRange {
  readonly offset: number;
  readonly length: number;
}

export interface OpenIndexedOptions {
  readonly codecs?: CodecRegistry;
  readonly headProbeBytes?: number;
}

export interface ReadChunkOptions {
  /** Highest SH band to transfer. 0 fetches no band bytes at all. */
  readonly maxShBand?: number;
}

/** One chunk's gaussians plus whichever SH bands the caller paid to transfer. */
export interface IndexedChunk {
  readonly entry: ChunkIndexEntry;
  readonly gaussians: ChunkGaussians;
  readonly sh: ShCoefficients | null;
}

/**
 * A scene opened for seeking: the front-matter records and the chunk index, and nothing
 * else until someone asks for a time.
 */
export class IndexedDecoder {
  private cachedChunkOptions: DecodeChunkOptions | null = null;

  private constructor(
    private readonly source: IReadable,
    private readonly codecs: CodecRegistry,
    readonly header: Header,
    readonly quantization: Quantization,
    readonly windows: Float64Array,
    readonly index: readonly ChunkIndexEntry[],
    readonly footer: Footer,
    readonly summaryOffsets: readonly SummaryOffset[],
    private readonly audioRange: { offset: number; length: number; codec: string } | null,
    /**
     * Front-matter records this reader framed and did not parse. Opening a file learns
     * where they are and stops: a camera nobody asked for costs nothing, and neither does
     * an attachment the size of a thumbnail sheet.
     */
    private readonly deferred: {
      camera: ByteRange | null;
      metadata: ByteRange[];
      attachments: ByteRange[];
    },
    readonly statistics: Statistics | null,
    /** Whether the summary CRC matched, or `null` when the file declares none. */
    readonly summaryCrcOk: boolean | null,
    readonly size: number,
  ) {}

  /** Open a scene: a bounded read from the front, then the index. Never the file. */
  static async open(source: IReadable, options: OpenIndexedOptions = {}): Promise<IndexedDecoder> {
    const codecs = options.codecs ?? DEFAULT_CODECS;
    const probeSize = options.headProbeBytes ?? HEAD_PROBE_BYTES;
    const size = Number(await source.size());
    if (size < MAGIC.length + FOOTER_TAIL_BYTES) {
      throw new MalformedFile(`file is ${size} bytes, too short to hold a header and a footer`);
    }

    const scanner = new FrontMatterScanner(source, size, probeSize);
    checkMagic(await scanner.head(MAGIC.length));

    let header: Header | null = null;
    let quantization: Quantization | null = null;
    let windows = new Float64Array(0);
    let audioRange: { offset: number; length: number; codec: string } | null = null;
    const deferred: { camera: ByteRange | null; metadata: ByteRange[]; attachments: ByteRange[] } =
      {
        camera: null,
        metadata: [],
        attachments: [],
      };
    for await (const record of scanner.records(MAGIC.length)) {
      if (record.opcode === Opcode.Chunk) break;
      if (record.opcode === Opcode.Header) {
        header = parseHeader(await scanner.content(record));
      } else if (record.opcode === Opcode.Quantization) {
        quantization = parseQuantization(await scanner.content(record));
      } else if (record.opcode === Opcode.WindowTable) {
        windows = parseWindowTable(await scanner.content(record));
      } else if (record.opcode === Opcode.Audio) {
        // The track's bytes are not read here, and neither is the record stepped into: a
        // caller may want the gaussians and never the audio. Only the codec name is
        // parsed, out of a prefix, so a scene with a large track costs nothing to open.
        audioRange = {
          offset: record.offset,
          length: record.totalLength,
          codec: readAudioCodec(await scanner.content(record, AUDIO_CODEC_PREFIX_BYTES)),
        };
      } else if (record.opcode === Opcode.Camera) {
        deferred.camera = { offset: record.offset, length: record.totalLength };
      } else if (record.opcode === Opcode.Metadata) {
        deferred.metadata.push({ offset: record.offset, length: record.totalLength });
      } else if (record.opcode === Opcode.Attachment) {
        deferred.attachments.push({ offset: record.offset, length: record.totalLength });
      }
    }
    if (header === null || quantization === null) {
      throw new MalformedFile(
        "the file has no Header or no Quantization record before its first Chunk",
      );
    }

    const tail = await source.read(BigInt(size - FOOTER_TAIL_BYTES), BigInt(FOOTER_TAIL_BYTES));
    if (!bytesEqual(tail.subarray(tail.length - MAGIC.length), MAGIC)) {
      throw new MalformedFile("file does not end with the magic; it may be truncated");
    }
    const footer = parseFooter(readRecord(new Cursor(tail, 0, size - FOOTER_TAIL_BYTES)).content);

    const index: ChunkIndexEntry[] = [];
    const summaryOffsets: SummaryOffset[] = [];
    let statistics: Statistics | null = null;
    let summaryCrcOk: boolean | null = null;
    if (footer.summaryStart > 0) {
      const summaryLength = size - FOOTER_TAIL_BYTES - footer.summaryStart;
      if (summaryLength < 0) {
        throw new MalformedFile(
          `footer says the summary starts at ${footer.summaryStart}, past the footer at ` +
            `${size - FOOTER_TAIL_BYTES}`,
        );
      }
      const summary = await source.read(BigInt(footer.summaryStart), BigInt(summaryLength));
      if (footer.summaryCrc !== 0) summaryCrcOk = crc32(summary) === footer.summaryCrc;
      for (const record of iterateRecords(summary, 0, footer.summaryStart)) {
        if (record.opcode === Opcode.ChunkIndex) index.push(parseChunkIndexEntry(record.content));
        else if (record.opcode === Opcode.SummaryOffset) {
          summaryOffsets.push(parseSummaryOffset(record.content));
        } else if (record.opcode === Opcode.Statistics) {
          statistics = parseStatistics(record.content);
        }
      }
    }

    return new IndexedDecoder(
      source,
      codecs,
      header,
      quantization,
      windows,
      index,
      footer,
      summaryOffsets,
      audioRange,
      deferred,
      statistics,
      summaryCrcOk,
      size,
    );
  }

  /** The suggested camera trajectory, fetched only when a caller wants it. */
  async readCamera(): Promise<Camera | null> {
    const range = this.deferred.camera;
    if (range === null) return null;
    return parseCamera(await this.readRecordAt(range, Opcode.Camera));
  }

  /** Every Metadata record, by range. */
  async readMetadata(): Promise<Metadata[]> {
    const out: Metadata[] = [];
    for (const range of this.deferred.metadata) {
      out.push(parseMetadata(await this.readRecordAt(range, Opcode.Metadata)));
    }
    return out;
  }

  /** Every Attachment record, by range. Each one costs exactly its own bytes. */
  async readAttachments(): Promise<Attachment[]> {
    const out: Attachment[] = [];
    for (const range of this.deferred.attachments) {
      out.push(parseAttachment(await this.readRecordAt(range, Opcode.Attachment)));
    }
    return out;
  }

  private async readRecordAt(range: ByteRange, expected: number): Promise<Uint8Array> {
    const blob = await this.source.read(BigInt(range.offset), BigInt(range.length));
    const record = readRecord(new Cursor(blob, 0, range.offset));
    if (record.opcode !== expected) {
      throw new MalformedFile(
        `offset ${range.offset} holds opcode 0x${record.opcode.toString(16)}, expected ` +
          `0x${expected.toString(16)}`,
      );
    }
    return record.content;
  }

  /** Whether the scene has audio, from the Header alone. */
  get hasAudio(): boolean {
    return this.header.hasAudio;
  }

  /** The normative seek rule: every index entry whose `[t0, t1)` contains `t`. */
  chunksForTime(t: number): ChunkIndexEntry[] {
    return this.index.filter((entry) => entryCovers(entry, t));
  }

  /** Every entry overlapping `[a, b)`, for scrubbing and prefetch. */
  chunksForRange(a: number, b: number): ChunkIndexEntry[] {
    return this.index.filter((entry) => entry.t0 < b && a < entry.t1);
  }

  /** What a seek to `t` will transfer, so a caller can budget before it asks. */
  bytesForTime(t: number, maxShBand = 0): number {
    let total = 0;
    for (const entry of this.chunksForTime(t)) {
      total += entry.chunkLength;
      for (const band of entry.bands) if (band.band <= maxShBand) total += band.length;
    }
    return total;
  }

  /**
   * Fetch and decode one chunk, plus only the SH bands asked for.
   *
   * Bands above the cap are never requested from the transport — the point of each band
   * having its own byte range is that a reader which has capped its degree does not pay
   * for the rest.
   */
  async readChunk(entry: ChunkIndexEntry, options: ReadChunkOptions = {}): Promise<IndexedChunk> {
    const maxShBand = options.maxShBand ?? 0;
    const blob = await this.source.read(BigInt(entry.chunkOffset), BigInt(entry.chunkLength));
    const record = readRecord(new Cursor(blob, 0, entry.chunkOffset));
    if (record.opcode !== Opcode.Chunk) {
      throw new MalformedFile(
        `chunk index points at offset ${entry.chunkOffset}, which holds opcode ` +
          `0x${record.opcode.toString(16)} rather than a Chunk`,
      );
    }
    const parsed = parseChunk(record.content);
    if (parsed.header.count !== entry.gaussianCount) {
      throw new MalformedFile(
        `chunk at ${entry.chunkOffset} holds ${parsed.header.count} gaussians, ` +
          `its index entry says ${entry.gaussianCount}`,
      );
    }
    const streamBytes = await chunkStreamBytes(parsed, this.codecs);
    const gaussians = await decodeChunkStreams(
      streamBytes,
      parsed.header.count,
      this.chunkOptions(),
    );

    const bands = new Map<number, Int32Array>();
    for (const band of entry.bands) {
      if (band.band > maxShBand) continue;
      const bandBlob = await this.source.read(BigInt(band.offset), BigInt(band.length));
      const bandRecord = readRecord(new Cursor(bandBlob, 0, band.offset));
      if (bandRecord.opcode !== Opcode.ShBandStream) {
        throw new MalformedFile(
          `index band ${band.band} points at opcode 0x${bandRecord.opcode.toString(16)}, ` +
            "not an SH Band Stream",
        );
      }
      const parsedBand = parseShBandRecord(bandRecord.content);
      if (parsedBand.band !== band.band) {
        throw new MalformedFile(
          `index says band ${band.band}, the record says band ${parsedBand.band}`,
        );
      }
      bands.set(band.band, await decodeStream(frameOneStream(parsedBand.cursor), this.codecs));
    }

    const sh = bands.size > 0 ? mergeBands(gaussians.count, bands, MAX_SH_DEGREE) : null;
    return { entry, gaussians, sh };
  }

  /**
   * The embedded track, fetched independently of any gaussian data.
   *
   * `null` when the scene has none — a normal value, not an error and not a warning.
   */
  async readAudio(): Promise<AudioTrack | null> {
    if (this.audioRange === null) return null;
    const { offset, length } = this.audioRange;
    const blob = await this.source.read(BigInt(offset), BigInt(length));
    return parseAudio(readRecord(new Cursor(blob, 0, offset)).content);
  }

  private chunkOptions(): DecodeChunkOptions {
    this.cachedChunkOptions ??= {
      steps: stepsFrom(this.quantization),
      posOrigin: this.quantization.posOrigin,
      windows: this.windows,
      supportK: supportK(this.header.cutoff || DEFAULT_CUTOFF),
      codecs: this.codecs,
    };
    return this.cachedChunkOptions;
  }
}

/** The `codec` field at the front of an Audio record, read out of a prefix of it. */
function readAudioCodec(prefix: Uint8Array): string {
  try {
    return new Cursor(prefix).string();
  } catch {
    throw new MalformedFile(
      `the Audio record's codec name does not fit the first ${AUDIO_CODEC_PREFIX_BYTES} bytes of the record`,
    );
  }
}
