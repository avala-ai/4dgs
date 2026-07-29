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
import { checkQuantizationScheme, checkTemporalModel } from "./registry.js";
import type { IReadable } from "./readable.js";
import {
  type AudioSource,
  type AudioSourceDescriptor,
  type AudioSourceState,
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
  RECORD_HEADER_BYTES,
  bytesEqual,
  checkMagic,
  entryCovers,
  iterateRecords,
  audioSourceStateAt,
  parseAudioSource,
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

interface IndexedAudioSource {
  readonly sourceId: number;
  readonly descriptor: ByteRange | null;
  readonly dataOffset: number;
  readonly dataLength: number;
  readonly legacyCodec?: string;
  readonly legacyStartSec?: number;
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
    private readonly audioSources: readonly IndexedAudioSource[],
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
    const sourceRanges = new Map<number, ByteRange>();
    const dataRanges = new Map<number, { offset: number; length: number }>();
    let legacyAudio: IndexedAudioSource | null = null;
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
        checkTemporalModel(header.temporalModel);
      } else if (record.opcode === Opcode.Quantization) {
        quantization = parseQuantization(await scanner.content(record));
        checkQuantizationScheme(quantization.scheme);
      } else if (record.opcode === Opcode.WindowTable) {
        windows = parseWindowTable(await scanner.content(record));
      } else if (record.opcode === Opcode.Audio) {
        // The track's bytes are not read here, and neither is the record stepped into: a
        // caller may want the gaussians and never the audio. Only the codec name is
        // parsed, out of a prefix, so a scene with a large track costs nothing to open.
        legacyAudio = readLegacyAudioRange(
          await scanner.content(record, AUDIO_CODEC_PREFIX_BYTES),
          record.offset,
          record.contentLength,
        );
      } else if (record.opcode === Opcode.AudioSource) {
        const sourceId = readSourceId(await scanner.content(record, 4), "Audio Source");
        if (sourceRanges.has(sourceId)) {
          throw new MalformedFile(`Audio Source id ${sourceId} appears more than once`);
        }
        sourceRanges.set(sourceId, { offset: record.offset, length: record.totalLength });
      } else if (record.opcode === Opcode.AudioData) {
        const prefix = new Cursor(await scanner.content(record, 12));
        const sourceId = prefix.u32();
        const dataLength = prefix.u64();
        if (dataRanges.has(sourceId)) {
          throw new MalformedFile(`Audio Data id ${sourceId} appears more than once`);
        }
        if (record.contentLength < 12 + dataLength) {
          throw new MalformedFile(
            `Audio Data id ${sourceId} declares ${dataLength} bytes, ` +
              `but its record content is only ${record.contentLength} bytes`,
          );
        }
        dataRanges.set(sourceId, {
          offset: record.offset + RECORD_HEADER_BYTES + 12,
          length: dataLength,
        });
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
    if (legacyAudio !== null && sourceRanges.size > 0) {
      throw new MalformedFile("the file mixes a legacy Audio record with Audio Source records");
    }
    if (legacyAudio !== null && dataRanges.size > 0) {
      const sourceId = Math.min(...dataRanges.keys());
      throw new MalformedFile(`Audio Data id ${sourceId} has no matching Audio Source record`);
    }
    const audioSources: IndexedAudioSource[] = [];
    if (legacyAudio !== null) {
      audioSources.push(legacyAudio);
    } else {
      for (const sourceId of [...sourceRanges.keys()].sort((a, b) => a - b)) {
        const data = dataRanges.get(sourceId);
        if (data === undefined) {
          throw new MalformedFile(`Audio Source id ${sourceId} has no matching Audio Data record`);
        }
        dataRanges.delete(sourceId);
        audioSources.push({
          sourceId,
          descriptor: sourceRanges.get(sourceId)!,
          dataOffset: data.offset,
          dataLength: data.length,
        });
      }
      if (dataRanges.size > 0) {
        const sourceId = Math.min(...dataRanges.keys());
        throw new MalformedFile(`Audio Data id ${sourceId} has no matching Audio Source record`);
      }
    }
    if (header.hasAudio !== audioSources.length > 0) {
      throw new MalformedFile(
        `the Header audio flag is ${header.hasAudio ? "set" : "clear"}, but the file contains ` +
          `${audioSources.length} audio sources`,
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
      audioSources,
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
    const blob = await this.readRange(range.offset, range.length, `the record at ${range.offset}`);
    const record = readRecord(new Cursor(blob, 0, range.offset));
    if (record.opcode !== expected) {
      throw new MalformedFile(
        `offset ${range.offset} holds opcode 0x${record.opcode.toString(16)}, expected ` +
          `0x${expected.toString(16)}`,
      );
    }
    return record.content;
  }

  /**
   * Read a byte range a record pointed at, refusing one that leaves the file.
   *
   * An index entry is data, and data in an untrusted file can say anything. A range that
   * runs off the end has to come back as a malformed file rather than as whatever the
   * transport happens to throw — a caller decoding a hostile file should not have to
   * catch the error type of somebody's HTTP client.
   */
  private async readRange(offset: number, length: number, what: string): Promise<Uint8Array> {
    if (offset < 0 || length < 0 || offset + length > this.size) {
      throw new MalformedFile(
        `${what} spans [${offset}, ${offset + length}), outside the ${this.size}-byte file`,
      );
    }
    if (length < RECORD_HEADER_BYTES) {
      throw new MalformedFile(`${what} is ${length} bytes, too short to be a record`);
    }
    return this.source.read(BigInt(offset), BigInt(length));
  }

  /** Whether the scene has audio, from the Header alone. */
  get hasAudio(): boolean {
    return this.header.hasAudio;
  }

  /** Number of independent sources, learned without fetching any encoded audio bytes. */
  get audioSourceCount(): number {
    return this.audioSources.length;
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
    const blob = await this.readRange(entry.chunkOffset, entry.chunkLength, "a chunk index entry");
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
      const bandBlob = await this.readRange(band.offset, band.length, `index band ${band.band}`);
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
    const source = (await this.readAudioSources())[0];
    return source === undefined
      ? null
      : { codec: source.codec, startSec: source.startSec, data: source.data };
  }

  /** Fetch every source descriptor and payload. */
  async readAudioSources(): Promise<AudioSource[]> {
    const out: AudioSource[] = [];
    for (const entry of this.audioSources) out.push(await this.readAudioSource(entry));
    return out;
  }

  /** Fetch every small descriptor without transferring encoded payload bytes. */
  async readAudioSourceDescriptors(): Promise<AudioSourceDescriptor[]> {
    const out: AudioSourceDescriptor[] = [];
    for (const entry of this.audioSources) {
      out.push(await this.readAudioSourceDescriptor(entry));
    }
    return out;
  }

  /** Reconstruct one source without transferring its encoded payload. */
  async readAudioSourceState(sourceId: number, t: number): Promise<AudioSourceState> {
    const entry = this.audioSources.find((item) => item.sourceId === sourceId);
    if (entry === undefined)
      throw new MalformedFile(`this scene has no audio source id ${sourceId}`);
    return audioSourceStateAt(await this.readAudioSourceDescriptor(entry), t);
  }

  /** Read one source-relative encoded byte range and nothing else. */
  async readAudioRange(sourceId: number, offset: number, length: number): Promise<Uint8Array> {
    const source = this.audioSources.find((item) => item.sourceId === sourceId);
    if (source === undefined)
      throw new MalformedFile(`this scene has no audio source id ${sourceId}`);
    if (offset < 0 || length < 0 || offset + length > source.dataLength) {
      throw new MalformedFile(
        `audio source ${sourceId} range [${offset}, ${offset + length}) is outside ` +
          `its ${source.dataLength}-byte payload`,
      );
    }
    return this.source.read(BigInt(source.dataOffset + offset), BigInt(length));
  }

  private async readAudioSource(entry: IndexedAudioSource): Promise<AudioSource> {
    const descriptor = await this.readAudioSourceDescriptor(entry);
    const data = await this.source.read(BigInt(entry.dataOffset), BigInt(entry.dataLength));
    return { ...descriptor, data };
  }

  private async readAudioSourceDescriptor(
    entry: IndexedAudioSource,
  ): Promise<AudioSourceDescriptor> {
    if (entry.descriptor === null) {
      const startSec = entry.legacyStartSec ?? 0;
      return {
        sourceId: entry.sourceId,
        name: "",
        codec: entry.legacyCodec ?? "",
        channelLayout: "",
        dataLength: entry.dataLength,
        startSec,
        durationSec: Math.max(0, this.header.durationSec - startSec),
        gain: 1,
        spatial: false,
        loop: false,
        position: [0, 0, 0],
        rotation: [0, 0, 0, 1],
        keyframes: [],
        interpolation: "linear",
      };
    }
    const descriptor = parseAudioSource(
      await this.readRecordAt(entry.descriptor, Opcode.AudioSource),
    );
    if (descriptor.sourceId !== entry.sourceId) {
      throw new MalformedFile(
        `Audio Source range for id ${entry.sourceId} contains id ${descriptor.sourceId}`,
      );
    }
    if (descriptor.dataLength !== entry.dataLength) {
      throw new MalformedFile(
        `Audio Source id ${entry.sourceId} declares ${descriptor.dataLength} bytes, ` +
          `its Audio Data record declares ${entry.dataLength}`,
      );
    }
    for (let i = 0; i < descriptor.keyframes.length; i++) {
      const time = descriptor.keyframes[i]!.time;
      if (time < 0 || time > this.header.durationSec) {
        throw new MalformedFile(
          `Audio Source id ${entry.sourceId} keyframe ${i} time ${time} is outside ` +
            `[0, ${this.header.durationSec}]`,
        );
      }
    }
    return descriptor;
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
function readSourceId(prefix: Uint8Array, recordName: string): number {
  try {
    return new Cursor(prefix).u32();
  } catch {
    throw new MalformedFile(`the ${recordName} record does not contain its u32 source id`);
  }
}

function readLegacyAudioRange(
  prefix: Uint8Array,
  recordOffset: number,
  contentLength: number,
): IndexedAudioSource {
  try {
    const cursor = new Cursor(prefix);
    const codec = cursor.string();
    const startSec = cursor.f64();
    const dataLength = cursor.u64();
    if (contentLength < cursor.pos + dataLength) {
      throw new MalformedFile(
        `the legacy Audio record declares ${dataLength} data bytes, but its content is only ` +
          `${contentLength} bytes`,
      );
    }
    return {
      sourceId: 0,
      descriptor: null,
      dataOffset: recordOffset + RECORD_HEADER_BYTES + cursor.pos,
      dataLength,
      legacyCodec: codec,
      legacyStartSec: startSec,
    };
  } catch (error) {
    if (error instanceof MalformedFile) throw error;
    throw new MalformedFile(
      `the legacy Audio descriptor does not fit the first ${AUDIO_CODEC_PREFIX_BYTES} bytes`,
    );
  }
}
