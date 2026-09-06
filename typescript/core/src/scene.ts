// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * A whole file, decoded front to back.
 *
 * The resource is consumed in bounded reads and never held in one piece: the decoder
 * frames records as bytes arrive, decodes each chunk when it completes, and keeps only
 * the gaussians. A file larger than memory decodes the same way a small one does.
 */

import {
  type ChunkGaussians,
  chunkStreamBytes,
  decodeChunkStreams,
  type DecodeChunkOptions,
  stepsFrom,
} from "./chunk.js";
import { crc32, DEFAULT_CODECS, type CodecRegistry } from "./codec.js";
import { Cursor } from "./cursor.js";
import {
  DEFAULT_MAX_DECODED_STATE_BYTES,
  DecodedStateBudget,
  decodedChunkStateBytes,
} from "./decodedStateBudget.js";
import {
  duplicateStructuralRecord,
  ExceedsReaderLimit,
  lateFrontMatterRecord,
  MalformedFile,
  TruncatedFile,
} from "./errors.js";
import { assembleGaussians, type GaussianSet } from "./gaussians.js";
import { isFrontMatterOpcode, isStateOpcode, Opcode } from "./opcodes.js";
import { ObjectLayer } from "./objects.js";
import { Provenance } from "./provenance.js";
import { DEFAULT_CUTOFF, supportK } from "./quantization.js";
import { checkQuantizationScheme, checkTemporalModel } from "./registry.js";
import {
  type Attachment,
  type AudioSourceDescriptor,
  type Camera,
  type ChunkIndexEntry,
  type Header,
  type Metadata,
  type Quantization,
  type Statistics,
  type SummaryOffset,
  RECORD_HEADER_BYTES,
  checkIndexCount,
  parseAttachment,
  parseAudioSource,
  parseCamera,
  parseChunk,
  parseChunkIndexEntry,
  parseCoordinateFrame,
  parseGeodeticAnchor,
  parseHeader,
  parseMetadata,
  parseObjectTable,
  parseObjectTrack,
  parseQuantization,
  parseRigTrajectory,
  parseSensorCalibration,
  parseShBandRecord,
  parseStatistics,
  parseFooter,
  parseSummaryOffset,
  parseWindowTable,
} from "./records.js";
import { type IReadable, BytesReadable } from "./readable.js";
import { MAX_SH_DEGREE, coefficientsForDegree, mergeBands, type ShCoefficients } from "./sh.js";
import { StreamDecoder, type StreamedRecordPart } from "./streamDecoder.js";
import { decodedStreamWorkingBytes, decodeStream, frameOneStream } from "./streams.js";

/** Everything a `.4dgs` file describes, decoded. */
export interface Scene {
  readonly header: Header;
  readonly quantization: Quantization;
  /** Flattened `[lo, hi]` pairs from the Window Table record. */
  readonly windows: Float64Array;
  readonly gaussians: GaussianSet;
  /**
   * Small source descriptors, empty when the scene has no audio.
   *
   * Encoded payload bytes are delivered through `DecodeOptions.onAudioData` while the
   * resource is consumed; they are never retained in the completed scene.
   */
  readonly audioSources: readonly AudioSourceDescriptor[];
  readonly camera: Camera | null;
  readonly metadata: readonly Metadata[];
  readonly attachments: readonly Attachment[];
  readonly statistics: Statistics | null;
  readonly chunkIndex: readonly ChunkIndexEntry[];
  readonly summaryOffsets: readonly SummaryOffset[];
  /**
   * Whether the Footer's summary CRC matched, or `null` when the file declares none.
   *
   * A front-to-back reader can answer this too: it has seen the bytes the CRC covers, so
   * it retains the summary region — the index, which is small by design — until the
   * Footer arrives and says where that region began.
   */
  readonly summaryCrcOk: boolean | null;
  /**
   * Every object-layer record the file carried (spec sections 5.15.6-5.15.7). Empty
   * when it carried none, which is a value and not an error.
   */
  readonly objects: ObjectLayer;
  /**
   * Every provenance record the file carried (spec section 5.15). Empty when it carried
   * none — a value, never an error.
   */
  readonly provenance: Provenance;
  /** Opcodes seen but not understood, in the order they appeared. */
  readonly skippedOpcodes: readonly number[];
  /** True when the resource ended before the file did. What decoded still stands. */
  readonly truncated: boolean;
}

export interface DecodeOptions {
  /** Decompressors by codec id. Defaults to deflate only; zstd is opt-in. */
  readonly codecs?: CodecRegistry;
  /** Aggregate ceiling for decoded state retained by this collecting call. */
  readonly maxDecodedStateBytes?: number;
  /** Highest SH band to decode. 0 skips spherical harmonics entirely. */
  readonly maxShBand?: number;
  /** Bytes per read from the resource. Bounds how much is in flight, not what fits. */
  readonly blockSize?: number;
  /**
   * Whether a resource that ends mid-record yields what decoded before the cut.
   *
   * On by default: a truncated file is common and usually recoverable, and the `truncated`
   * flag says so without the caller having to catch anything.
   */
  readonly recoverTruncated?: boolean;
  /**
   * Consume one bounded piece of encoded audio as it arrives.
   *
   * The callback is awaited before the decoder reads another block. `bytes` is a view
   * into that block and should be consumed before the callback returns; retaining it is
   * an explicit caller-owned copy/ownership decision.
   */
  readonly onAudioData?: (chunk: AudioPayloadChunk) => void | Promise<void>;
}

/** One source-relative piece of an encoded payload on the streamed read path. */
export interface AudioPayloadChunk {
  readonly sourceId: number;
  readonly offset: number;
  readonly dataLength: number;
  readonly bytes: Uint8Array;
  readonly final: boolean;
}

const DEFAULT_BLOCK_SIZE = 1 << 20;
/**
 * Maximum state Chunks one whole-scene streamed decode retains.
 *
 * This is a reader resource limit, not a format limit. The returned Scene already owns one
 * decoded population per Chunk; the same ceiling also bounds the one-integer-per-Chunk index
 * observations retained until the trailing summary arrives.
 */
export const MAX_STREAMED_SCENE_CHUNKS = 262_144;
// Kept in step with the indexed reader's bounded prefix read. A codec name is a registry
// descriptor, not payload; letting its u32 length size an allocation would give a few
// hostile bytes a multi-gigabyte memory effect.
const MAX_LEGACY_AUDIO_DESCRIPTOR_BYTES = 4096;
const STREAMED_RECORD_OPCODES: ReadonlySet<number> = new Set([Opcode.Audio, Opcode.AudioData]);

interface LegacyAudioDescriptor {
  readonly codec: string;
  readonly startSec: number;
  readonly dataLength: number;
}

interface ObservedAudioRecord {
  readonly name: "Audio" | "Audio Source" | "Audio Data";
  readonly offset: number;
  sourceId?: number;
}

interface StreamingAudioData {
  readonly recordOffset: number;
  readonly contentLength: number;
  readonly prefix: Uint8Array;
  prefixLength: number;
  sourceId: number | null;
  dataLength: number | null;
  emitted: number;
  finalCallbackEmitted: boolean;
}

interface StreamingLegacyAudio {
  readonly recordOffset: number;
  readonly contentLength: number;
  prefix: Uint8Array;
  prefixLength: number;
  codecLength: number | null;
  codec: string | null;
  startSec: number | null;
  dataLength: number | null;
  emitted: number;
  finalCallbackEmitted: boolean;
}

/**
 * Decode a whole scene, front to back.
 *
 * Accepts bytes for the common small case and an {@link IReadable} for everything else;
 * either way the decoder pulls in bounded blocks and never asks for the whole resource.
 */
export async function decodeScene(
  source: IReadable | Uint8Array,
  options: DecodeOptions = {},
): Promise<Scene> {
  // Validate configuration before constructing or touching the input abstraction. A bad
  // caller argument is independent of what bytes, transport, or error the input carries.
  const decodedStateBudget = new DecodedStateBudget(
    options.maxDecodedStateBytes === undefined
      ? DEFAULT_MAX_DECODED_STATE_BYTES
      : options.maxDecodedStateBytes,
  );
  const readable = source instanceof Uint8Array ? new BytesReadable(source) : source;
  const codecs = options.codecs ?? DEFAULT_CODECS;
  const maxShBand = options.maxShBand ?? MAX_SH_DEGREE;
  const blockSize = options.blockSize ?? DEFAULT_BLOCK_SIZE;
  const recoverTruncated = options.recoverTruncated ?? true;

  const decoder = new StreamDecoder();
  const size = Number(await readable.size());

  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let windows = new Float64Array(0);
  let sawWindowTable = false;
  let chunkOptions: DecodeChunkOptions | null = null;

  const chunks: ChunkGaussians[] = [];
  // The summary follows the chunks, so keep one bounded observation per decoded Chunk
  // until its index entry arrives. Never retain a second copy of a population.
  const decodedChunkRows = new Map<number, number>();
  const chunkBands: Map<number, Int32Array>[] = [];
  const metadata: Metadata[] = [];
  const attachments: Attachment[] = [];
  const chunkIndex: ChunkIndexEntry[] = [];
  const summaryOffsets: SummaryOffset[] = [];
  const skippedOpcodes: number[] = [];
  // The summary region, retained from the first record that belongs to it so the Footer's
  // CRC can be checked. Bounded by the index, which every reader has to hold anyway.
  const summaryParts: Uint8Array[] = [];
  let summaryPartsStart = -1;
  let sawFooter = false;
  let summaryCrcOk: boolean | null = null;
  let legacyAudio: LegacyAudioDescriptor | null = null;
  const audioDescriptors = new Map<number, AudioSourceDescriptor>();
  const audioPayloadLengths = new Map<number, number>();
  let firstAudioRecord: ObservedAudioRecord | null = null;
  let streamingAudioData: StreamingAudioData | null = null;
  let streamingLegacyAudio: StreamingLegacyAudio | null = null;
  let camera: Camera | null = null;
  let statistics: Statistics | null = null;
  const provenance = new Provenance();
  const objects = new ObjectLayer();
  let truncated = false;
  let firstState: { readonly opcode: number; readonly offset: number } | null = null;

  let at = 0;
  while (at < size) {
    const length = Math.min(blockSize, size - at);
    decoder.append(await readable.read(BigInt(at), BigInt(length)));
    at += length;

    // Records complete as bytes arrive. A record that is not complete yet is simply not
    // yielded, which is the whole of truncation recovery: what is complete is decoded,
    // what is cut is not, and nothing has to be undone.
    for (const item of decoder.recordsStreaming(STREAMED_RECORD_OPCODES)) {
      const opcodeOffset = "bytes" in item ? item.recordOffset : item.offset;
      if (firstState !== null && isFrontMatterOpcode(item.opcode)) {
        throw lateFrontMatterRecord(
          item.opcode,
          opcodeOffset,
          firstState.opcode,
          firstState.offset,
        );
      }
      if (firstState === null && isStateOpcode(item.opcode)) {
        firstState = { opcode: item.opcode, offset: opcodeOffset };
      }
      if ("bytes" in item) {
        const recordEnd = item.recordOffset + RECORD_HEADER_BYTES + item.contentLength;
        if (!Number.isSafeInteger(recordEnd) || recordEnd > size) {
          // The resource ends inside this streamed record. Do not parse a partial prefix:
          // in particular, do not allocate from a codec length whose containing record
          // has not been shown to exist. `decoder.end()` records the truncation.
          truncated = true;
          continue;
        }
        if (item.opcode === Opcode.Audio) {
          firstAudioRecord ??= { name: "Audio", offset: item.recordOffset };
          const consumed = await consumeLegacyAudioPart(
            item,
            streamingLegacyAudio,
            options.onAudioData,
          );
          streamingLegacyAudio = consumed.state;
          if (consumed.descriptor !== null) legacyAudio = consumed.descriptor;
        } else {
          const observed = (firstAudioRecord ??= {
            name: "Audio Data",
            offset: item.recordOffset,
          });
          streamingAudioData = await consumeAudioDataPart(
            item,
            streamingAudioData,
            audioPayloadLengths,
            observed,
            options.onAudioData,
          );
        }
        continue;
      }
      const record = item;
      const { opcode, content } = record;
      if (SUMMARY_OPCODES.has(opcode)) {
        if (summaryPartsStart < 0) summaryPartsStart = record.offset;
        summaryParts.push(record.raw);
      }
      switch (opcode) {
        case Opcode.Header:
          if (header !== null) throw duplicateStructuralRecord("Header", record.offset);
          header = parseHeader(content);
          checkTemporalModel(header.temporalModel);
          break;
        case Opcode.Quantization:
          if (quantization !== null) {
            throw duplicateStructuralRecord("Quantization", record.offset);
          }
          quantization = parseQuantization(content, record.offset);
          checkQuantizationScheme(quantization.scheme);
          break;
        case Opcode.WindowTable:
          // Tracked with a flag rather than by testing `windows` for emptiness: a file
          // may legitimately carry a table with no entries, which is not the same thing
          // as carrying no table at all.
          if (sawWindowTable) {
            throw duplicateStructuralRecord("Window Table", record.offset);
          }
          sawWindowTable = true;
          windows = parseWindowTable(content);
          break;
        case Opcode.Chunk: {
          if (quantization === null || header === null) {
            throw new MalformedFile("a Chunk arrived before the Header or Quantization record");
          }
          if (chunks.length === MAX_STREAMED_SCENE_CHUNKS) {
            throw new ExceedsReaderLimit(
              `streamed scene decode stopped after ${MAX_STREAMED_SCENE_CHUNKS} retained ` +
                "Chunks; this is the reader's bounded-memory limit, not a malformed-file verdict",
            );
          }
          chunkOptions ??= {
            steps: stepsFrom(quantization),
            posOrigin: quantization.posOrigin,
            windows,
            supportK: supportK(header.cutoff || DEFAULT_CUTOFF),
            codecs,
          };
          const parsed = parseChunk(content);
          decodedStateBudget.check(
            BigInt(parsed.header.count) * 512n + BigInt(parsed.header.uncompressedSize) * 2n,
            `streamed Chunk decode at byte ${record.offset}`,
          );
          const streamBytes = await chunkStreamBytes(parsed, codecs);
          const decoded = await decodeChunkStreams(streamBytes, parsed.header.count, {
            ...chunkOptions,
            recordOffset: record.offset,
          });
          decodedStateBudget.retain(
            decodedChunkStateBytes(decoded),
            `streamed Chunk collection after byte ${record.offset}`,
          );
          chunks.push(decoded);
          decodedChunkRows.set(record.offset, decoded.count);
          chunkBands.push(new Map());
          break;
        }
        case Opcode.ShBandStream: {
          if (maxShBand <= 0 || chunks.length === 0) break;
          const { band, cursor } = parseShBandRecord(content);
          if (band > maxShBand) break;
          const stream = frameOneStream(cursor);
          decodedStateBudget.check(
            decodedStreamWorkingBytes(stream),
            `streamed SH band ${band} decode at byte ${record.offset}`,
          );
          const values = await decodeStream(stream, codecs);
          const bands = chunkBands[chunkBands.length - 1]!;
          const previous = bands.get(band);
          decodedStateBudget.retain(
            values.byteLength,
            `streamed SH band ${band} collection after byte ${record.offset}`,
          );
          bands.set(band, values);
          if (previous !== undefined) decodedStateBudget.release(previous.byteLength);
          break;
        }
        case Opcode.AudioSource: {
          const source = parseAudioSource(content);
          if (audioDescriptors.has(source.sourceId)) {
            throw new MalformedFile(`Audio Source id ${source.sourceId} appears more than once`);
          }
          firstAudioRecord ??= {
            name: "Audio Source",
            offset: record.offset,
            sourceId: source.sourceId,
          };
          audioDescriptors.set(source.sourceId, source);
          break;
        }
        case Opcode.Camera:
          camera = parseCamera(content);
          break;
        case Opcode.Metadata:
          metadata.push(parseMetadata(content));
          break;
        case Opcode.Attachment:
          attachments.push(parseAttachment(content));
          break;
        case Opcode.CoordinateFrame:
          provenance.frames.push(parseCoordinateFrame(content));
          break;
        case Opcode.SensorCalibration:
          provenance.sensors.push(parseSensorCalibration(content));
          break;
        case Opcode.RigTrajectory:
          {
            // Section 5.15.4: a trajectory with no samples "MUST be read as though the
            // record were absent". Reporting it would put a rig in the summary that
            // carries no pose and that no sensor may reference.
            const trajectory = parseRigTrajectory(content);
            if (trajectory.times.length > 0) provenance.trajectories.push(trajectory);
          }
          break;
        case Opcode.GeodeticAnchor:
          provenance.anchors.push(parseGeodeticAnchor(content));
          break;
        case Opcode.ObjectTable:
          // Relative order within front matter is free. The placement check above has
          // already established that this table is not after state.
          if (objects.table !== null) {
            throw new MalformedFile(
              "the file carries a second Object Table; a scene has one (section 5.15.6)",
            );
          }
          objects.table = parseObjectTable(content);
          break;
        case Opcode.ObjectTrack:
          // §5.15.7: a zero-sample track "has no pose and is read as absent". Kept, one
          // empty track would make a non-empty object layer, and two empty tracks for an
          // id would be a duplicate the layer refuses.
          {
            const track = parseObjectTrack(content);
            if (track.times.length > 0) objects.tracks.push(track);
          }
          break;
        case Opcode.Statistics:
          statistics = parseStatistics(content);
          break;
        case Opcode.ChunkIndex: {
          const entry = parseChunkIndexEntry(content);
          const observed = decodedChunkRows.get(entry.chunkOffset);
          if (observed !== undefined) {
            checkIndexCount(
              entry,
              "gaussian_count",
              observed,
              "the decoded Chunk's validated gaussian row count",
            );
          }
          chunkIndex.push(entry);
          break;
        }
        case Opcode.SummaryOffset:
          summaryOffsets.push(parseSummaryOffset(content));
          break;
        case Opcode.Footer: {
          sawFooter = true;
          const footer = parseFooter(content);
          if (footer.summaryStart > 0 && footer.summaryCrc !== 0) {
            summaryCrcOk = checkSummaryCrc(
              summaryParts,
              summaryPartsStart,
              footer.summaryStart,
              record.offset,
              footer.summaryCrc,
            );
          }
          break;
        }
        case Opcode.AttachmentIndex:
          break;
        default:
          // Unknown or private: skipped by length, which is the whole point of framing.
          skippedOpcodes.push(opcode);
          break;
      }
    }
  }

  decoder.end();
  truncated ||= decoder.truncated;
  if (truncated && !recoverTruncated) {
    throw new TruncatedFile(`resource ended after ${decoder.consumed} bytes, mid-file`);
  }
  if (header === null || quantization === null) {
    throw new MalformedFile("file has no Header or no Quantization record");
  }

  // The cross-record rules — unique sensor names, a rig reference that resolves — can
  // only run once the whole front matter has gone past. A truncated file may legitimately
  // be missing the trajectory a sensor names, so those reference rules are deferred there
  // — but the recovery contract is that everything complete before the cut still stands,
  // and a duplicate name among complete records is exactly that: no later byte can repair
  // it, so it is refused whether or not the file was cut.
  // A cut file defers only what a later record could still have supplied. If a Footer went
  // past, the record stream is complete — the Footer is the last record a file carries —
  // so a missing rig or frame is missing for good and refusing it is right, even though
  // the trailing magic never arrived. Without this, a file cut after the Footer accepted
  // a sensor posed against a rig that is not there, while the same records uncut refused.
  provenance.check(truncated && !sawFooter);
  objects.check();

  const audioSources = assembleAudioSourceDescriptors(
    header,
    audioDescriptors,
    audioPayloadLengths,
    legacyAudio,
    firstAudioRecord,
    truncated,
  );

  const mergedShBytes = mergedShStateBytes(chunks, chunkBands, maxShBand);
  // `mergeChunkBands` temporarily owns per-chunk merged arrays as well as its final array.
  decodedStateBudget.check(mergedShBytes * 2n, "gaussian-birth SH band assembly");
  const sh = mergeChunkBands(chunks, chunkBands, maxShBand);
  if (sh !== null) {
    decodedStateBudget.retain(sh.values.byteLength, "gaussian-birth SH band collection");
  }

  return {
    header,
    quantization,
    windows,
    gaussians: assembleGaussians(chunks, windows, header.shDegree, sh, {
      decodedStateBudget,
    }),
    audioSources,
    camera,
    metadata,
    attachments,
    statistics,
    chunkIndex,
    summaryOffsets,
    provenance,
    objects,
    skippedOpcodes,
    summaryCrcOk,
    truncated,
  };
}

function assembleAudioSourceDescriptors(
  header: Header,
  descriptors: ReadonlyMap<number, AudioSourceDescriptor>,
  payloadLengths: Map<number, number>,
  legacy: LegacyAudioDescriptor | null,
  firstAudioRecord: ObservedAudioRecord | null,
  truncated: boolean,
): AudioSourceDescriptor[] {
  if (!header.hasAudio && (descriptors.size > 0 || payloadLengths.size > 0 || legacy !== null)) {
    const record = firstAudioRecord!;
    const source = record.sourceId === undefined ? "" : ` for source id ${record.sourceId}`;
    throw new MalformedFile(
      `the Header audio flag is clear, but an ${record.name} record${source} at byte ` +
        `${record.offset} is present; expected no audio records`,
    );
  }
  if (descriptors.size > 0 && legacy !== null) {
    throw new MalformedFile("the file mixes a legacy Audio record with Audio Source records");
  }
  // A legacy Audio record can never coexist with new-format audio. Unlike an unmatched new
  // descriptor — which a lost Audio Source could still have matched in a truncated file — a
  // payload beside a legacy record is an orphan no later bytes can legitimize, so it is
  // refused even in recovery, matching the indexed reader.
  if (legacy !== null && payloadLengths.size > 0) {
    const sourceId = Math.min(...payloadLengths.keys());
    throw new MalformedFile(`Audio Data id ${sourceId} has no matching Audio Source record`);
  }
  const sources: AudioSourceDescriptor[] = [];
  for (const sourceId of [...descriptors.keys()].sort((a, b) => a - b)) {
    const descriptor = descriptors.get(sourceId)!;
    const dataLength = payloadLengths.get(sourceId);
    if (dataLength === undefined) {
      if (truncated) continue;
      throw new MalformedFile(`Audio Source id ${sourceId} has no matching Audio Data record`);
    }
    payloadLengths.delete(sourceId);
    if (dataLength !== descriptor.dataLength) {
      throw new MalformedFile(
        `Audio Source id ${sourceId} declares ${descriptor.dataLength} data bytes, ` +
          `its Audio Data record contains ${dataLength}`,
      );
    }
    for (let i = 0; i < descriptor.keyframes.length; i++) {
      const time = descriptor.keyframes[i]!.time;
      if (time < 0 || time > header.durationSec) {
        throw new MalformedFile(
          `Audio Source id ${sourceId} keyframe ${i} time ${time} is outside ` +
            `[0, ${header.durationSec}]`,
        );
      }
    }
    sources.push(descriptor);
  }
  if (payloadLengths.size > 0 && !truncated) {
    const sourceId = Math.min(...payloadLengths.keys());
    throw new MalformedFile(`Audio Data id ${sourceId} has no matching Audio Source record`);
  }
  if (legacy !== null) {
    sources.push({
      sourceId: 0,
      name: "",
      codec: legacy.codec,
      channelLayout: "",
      dataLength: legacy.dataLength,
      startSec: legacy.startSec,
      durationSec: Math.max(0, header.durationSec - legacy.startSec),
      gain: 1,
      spatial: false,
      loop: false,
      position: [0, 0, 0],
      rotation: [0, 0, 0, 1],
      keyframes: [],
      interpolation: "linear",
    });
  }
  if (
    (!header.hasAudio && sources.length > 0) ||
    (header.hasAudio && sources.length === 0 && !truncated)
  ) {
    throw new MalformedFile(
      `the Header audio flag is ${header.hasAudio ? "set" : "clear"}, but the file contains ` +
        `${sources.length} complete audio sources`,
    );
  }
  return sources;
}

async function consumeLegacyAudioPart(
  part: StreamedRecordPart,
  current: StreamingLegacyAudio | null,
  onAudioData: DecodeOptions["onAudioData"],
): Promise<{ state: StreamingLegacyAudio | null; descriptor: LegacyAudioDescriptor | null }> {
  let state = current;
  if (state === null) {
    state = {
      recordOffset: part.recordOffset,
      contentLength: part.contentLength,
      prefix: new Uint8Array(4),
      prefixLength: 0,
      codecLength: null,
      codec: null,
      startSec: null,
      dataLength: null,
      emitted: 0,
      finalCallbackEmitted: false,
    };
  } else if (
    state.recordOffset !== part.recordOffset ||
    state.contentLength !== part.contentLength
  ) {
    throw new Error("internal error: interleaved streamed records");
  }

  let at = 0;
  while (state.dataLength === null && at < part.bytes.byteLength) {
    const taken = Math.min(
      state.prefix.byteLength - state.prefixLength,
      part.bytes.byteLength - at,
    );
    state.prefix.set(part.bytes.subarray(at, at + taken), state.prefixLength);
    state.prefixLength += taken;
    at += taken;
    if (state.prefixLength !== state.prefix.byteLength) break;

    if (state.codecLength === null) {
      const codecLength = new DataView(
        state.prefix.buffer,
        state.prefix.byteOffset,
        state.prefix.byteLength,
      ).getUint32(0, true);
      const prefixLength = 4 + codecLength + 8 + 8;
      if (!Number.isSafeInteger(prefixLength) || prefixLength > state.contentLength) {
        throw new MalformedFile(
          `legacy Audio record at offset ${state.recordOffset} declares a ${codecLength}-byte ` +
            `codec, but its content is only ${state.contentLength} bytes`,
        );
      }
      if (prefixLength > MAX_LEGACY_AUDIO_DESCRIPTOR_BYTES) {
        throw new MalformedFile(
          `legacy Audio record at offset ${state.recordOffset} declares a ${codecLength}-byte ` +
            `codec; its ${prefixLength}-byte descriptor exceeds the bounded ` +
            `${MAX_LEGACY_AUDIO_DESCRIPTOR_BYTES}-byte limit`,
        );
      }
      const expanded = new Uint8Array(prefixLength);
      expanded.set(state.prefix);
      state.prefix = expanded;
      state.codecLength = codecLength;
      continue;
    }

    const prefix = new Cursor(state.prefix, 0, state.recordOffset + RECORD_HEADER_BYTES);
    state.codec = prefix.string();
    state.startSec = prefix.f64();
    state.dataLength = prefix.u64();
    if (state.contentLength < state.prefix.byteLength + state.dataLength) {
      throw new MalformedFile(
        `legacy Audio record at offset ${state.recordOffset} declares ${state.dataLength} ` +
          `data bytes, but its content is only ${state.contentLength} bytes`,
      );
    }
  }

  if (state.dataLength !== null) {
    const remaining = state.dataLength - state.emitted;
    const taken = Math.min(remaining, part.bytes.byteLength - at);
    if (taken > 0) {
      const bytes = part.bytes.subarray(at, at + taken);
      const offset = state.emitted;
      state.emitted += taken;
      const final = state.emitted === state.dataLength;
      await onAudioData?.({
        sourceId: 0,
        offset,
        dataLength: state.dataLength,
        bytes,
        final,
      });
      state.finalCallbackEmitted ||= final;
    }
  }

  if (!part.final) return { state, descriptor: null };
  if (state.codec === null || state.startSec === null || state.dataLength === null) {
    throw new MalformedFile(
      `legacy Audio record at offset ${state.recordOffset} is shorter than its prefix`,
    );
  }
  if (state.emitted !== state.dataLength) {
    throw new MalformedFile(
      `legacy Audio record at offset ${state.recordOffset} ended after ${state.emitted} of ` +
        `${state.dataLength} declared data bytes`,
    );
  }
  if (!state.finalCallbackEmitted) {
    await onAudioData?.({
      sourceId: 0,
      offset: 0,
      dataLength: 0,
      bytes: new Uint8Array(0),
      final: true,
    });
  }
  return {
    state: null,
    descriptor: {
      codec: state.codec,
      startSec: state.startSec,
      dataLength: state.dataLength,
    },
  };
}

async function consumeAudioDataPart(
  part: StreamedRecordPart,
  current: StreamingAudioData | null,
  payloadLengths: Map<number, number>,
  observed: ObservedAudioRecord,
  onAudioData: DecodeOptions["onAudioData"],
): Promise<StreamingAudioData | null> {
  let state = current;
  if (state === null) {
    state = {
      recordOffset: part.recordOffset,
      contentLength: part.contentLength,
      prefix: new Uint8Array(12),
      prefixLength: 0,
      sourceId: null,
      dataLength: null,
      emitted: 0,
      finalCallbackEmitted: false,
    };
  } else if (
    state.recordOffset !== part.recordOffset ||
    state.contentLength !== part.contentLength
  ) {
    throw new Error("internal error: interleaved streamed records");
  }

  let at = 0;
  if (state.prefixLength < state.prefix.byteLength) {
    const taken = Math.min(state.prefix.byteLength - state.prefixLength, part.bytes.byteLength);
    state.prefix.set(part.bytes.subarray(0, taken), state.prefixLength);
    state.prefixLength += taken;
    at += taken;
    if (state.prefixLength === state.prefix.byteLength) {
      const prefix = new Cursor(state.prefix, 0, state.recordOffset + RECORD_HEADER_BYTES);
      const sourceId = prefix.u32();
      const dataLength = prefix.u64();
      state.sourceId = sourceId;
      state.dataLength = dataLength;
      if (observed.name === "Audio Data" && observed.offset === state.recordOffset) {
        observed.sourceId = sourceId;
      }
      if (state.contentLength < state.prefix.byteLength + dataLength) {
        throw new MalformedFile(
          `Audio Data id ${sourceId} declares ${dataLength} bytes, ` +
            `but its record content is only ${state.contentLength} bytes`,
        );
      }
      if (payloadLengths.has(sourceId)) {
        throw new MalformedFile(`Audio Data id ${sourceId} appears more than once`);
      }
    }
  }

  if (state.sourceId !== null && state.dataLength !== null) {
    const remaining = state.dataLength - state.emitted;
    const taken = Math.min(remaining, part.bytes.byteLength - at);
    if (taken > 0) {
      const bytes = part.bytes.subarray(at, at + taken);
      const offset = state.emitted;
      state.emitted += taken;
      const final = state.emitted === state.dataLength;
      await onAudioData?.({
        sourceId: state.sourceId,
        offset,
        dataLength: state.dataLength,
        bytes,
        final,
      });
      state.finalCallbackEmitted ||= final;
    }
  }

  if (!part.final) return state;
  if (state.sourceId === null || state.dataLength === null) {
    throw new MalformedFile(
      `Audio Data record at offset ${state.recordOffset} is shorter than its 12-byte prefix`,
    );
  }
  if (state.emitted !== state.dataLength) {
    throw new MalformedFile(
      `Audio Data id ${state.sourceId} ended after ${state.emitted} of ` +
        `${state.dataLength} declared bytes`,
    );
  }
  if (!state.finalCallbackEmitted) {
    await onAudioData?.({
      sourceId: state.sourceId,
      offset: 0,
      dataLength: 0,
      bytes: new Uint8Array(0),
      final: true,
    });
  }
  payloadLengths.set(state.sourceId, state.dataLength);
  return null;
}

/** Records that belong to the summary region a Footer CRC covers. */
const SUMMARY_OPCODES: ReadonlySet<number> = new Set([
  Opcode.ChunkIndex,
  Opcode.Statistics,
  Opcode.SummaryOffset,
  Opcode.AttachmentIndex,
]);

/**
 * Check the Footer's CRC over `[summaryStart, footerStart)` against the retained bytes.
 *
 * `null` rather than `false` when the retained region does not reach back to where the
 * Footer says the summary began: that is a reader which cannot answer, not a file that
 * failed.
 */
function checkSummaryCrc(
  parts: readonly Uint8Array[],
  partsStart: number,
  summaryStart: number,
  footerStart: number,
  expected: number,
): boolean | null {
  if (partsStart < 0 || summaryStart < partsStart) return null;
  let total = 0;
  for (const part of parts) total += part.byteLength;
  const joined = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    joined.set(part, at);
    at += part.byteLength;
  }
  const from = summaryStart - partsStart;
  const to = footerStart - partsStart;
  if (to > joined.byteLength || from > to) return null;
  return crc32(joined.subarray(from, to)) === expected;
}

/**
 * Merge every chunk's SH bands into one scene-wide coefficient array.
 *
 * Degrees are whole and scene-wide, so chunks that disagree about how many bands they
 * carry describe a file no reader can evaluate consistently.
 */
function mergeChunkBands(
  chunks: readonly ChunkGaussians[],
  bands: readonly Map<number, Int32Array>[],
  degreeCap: number,
): ShCoefficients | null {
  const merged = chunks.map((chunk, i) =>
    mergeBands(chunk.count, bands[i] ?? new Map(), degreeCap),
  );
  const withBands = merged.filter((m) => m.degree > 0);
  if (withBands.length === 0) return null;
  const degree = withBands[0]!.degree;
  if (withBands.length !== merged.length || merged.some((m) => m.degree !== degree)) {
    throw new MalformedFile(
      `chunks disagree on SH degree: ${[...new Set(merged.map((m) => m.degree))].join(", ")}`,
    );
  }
  const coefficients = withBands[0]!.coefficients;
  let count = 0;
  let length = 0;
  for (const part of merged) {
    count += part.count;
    length += part.values.length;
  }
  const values = new Uint8Array(length);
  let at = 0;
  for (const part of merged) {
    values.set(part.values, at);
    at += part.values.length;
  }
  return { degree, coefficients, count, values, bands: withBands[0]!.bands };
}

/** Capacity of the final SH buffer implied by the retained per-chunk band maps. */
function mergedShStateBytes(
  chunks: readonly ChunkGaussians[],
  bands: readonly ReadonlyMap<number, Int32Array>[],
  degreeCap: number,
): bigint {
  let highest = 0;
  for (const chunkBands of bands) {
    for (const band of chunkBands.keys()) {
      if (band <= degreeCap) highest = Math.max(highest, band);
    }
  }
  if (highest === 0) return 0n;
  let count = 0n;
  for (const chunk of chunks) count += BigInt(chunk.count);
  return count * BigInt(3 * coefficientsForDegree(highest));
}
