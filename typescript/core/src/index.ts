// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * `@4dgs/core` — the 4dgs decoder.
 *
 * No I/O: everything comes through {@link IReadable}, so the same code runs in a browser,
 * on a server, and in a test over a byte array.
 *
 * ```ts
 * import { decodeScene } from "@4dgs/core";
 *
 * const scene = await decodeScene(bytes);
 * const state = scene.gaussians.stateAt(1.5); // decoding ends here
 * ```
 *
 * Two read paths, both first-class: {@link decodeScene} walks a resource front to back
 * and works on a pipe or a truncated file, and {@link IndexedDecoder} reads the index and
 * then only the byte ranges an instant needs. Neither is an optimization of the other.
 */

export { BytesReadable, type IReadable } from "./readable.js";

export {
  FourdgsError,
  MalformedFile,
  Refusal,
  TruncatedFile,
  UnsupportedCodec,
  UnsupportedVersion,
  type FourdgsErrorOptions,
  type RefusalCode,
} from "./errors.js";

export {
  Attribute,
  ATTRIBUTE_CHANNELS,
  FROZEN_OPCODES,
  GAUSSIAN_FLAG_NEVER_FADES,
  HEADER_FLAG_CHUNKS_COMPRESSED,
  HEADER_FLAG_HAS_AUDIO,
  AUDIO_SOURCE_FLAG_LOOP,
  AUDIO_SOURCE_FLAG_SPATIAL,
  Opcode,
  PRIVATE_OPCODE_START,
  PROVENANCE_END,
  PROVENANCE_START,
  REQUIRED_ATTRIBUTES,
  isPrivateOpcode,
  isObjectOpcode,
  isProvenanceOpcode,
  opcodeName,
} from "./opcodes.js";

export {
  CODEC_DEFLATE,
  CODEC_ZSTD,
  Crc32,
  DEFAULT_CODECS,
  type CodecRegistry,
  type Decompressor,
  codecName,
  crc32,
  decompressorFor,
  inflateZlib,
} from "./codec.js";

export { Cursor } from "./cursor.js";

export {
  CAMERA_MODEL_COEFFICIENTS,
  CAMERA_MODEL_NONE,
  DELTA_MODE_CHAINED,
  DELTA_MODE_KEYFRAME,
  FOOTER_TAIL_BYTES,
  MAGIC,
  POSE_TO_RIG,
  POSE_TO_SCENE,
  RECORD_HEADER_BYTES,
  TRAJECTORY_LINEAR,
  TRAJECTORY_STEP,
  VERSION,
  type Attachment,
  type AudioTrack,
  type AudioData,
  type AudioSource,
  type AudioSourceDescriptor,
  type AudioSourceKeyframe,
  type AudioSourceState,
  type BandRange,
  type Camera,
  type CameraKeyframe,
  type ChunkHeader,
  type ChunkIndexEntry,
  type CoordinateFrame,
  type DeltaChunkHeader,
  type Footer,
  type GeodeticAnchor,
  type Header,
  type Metadata,
  type DeltaGroups,
  type ParsedChunk,
  type ParsedDeltaChunk,
  type Quantization,
  type RawRecord,
  type ObjectTable,
  type ObjectTableEntry,
  type ObjectTrack,
  type RigTrajectory,
  type SensorCalibration,
  type Statistics,
  type SummaryOffset,
  BACKGROUND_OBJECT,
  bytesEqual,
  checkCoordinateFrame,
  checkGeodeticAnchor,
  checkMagic,
  checkObjectTable,
  checkObjectTrack,
  checkRigTrajectory,
  checkSensorCalibration,
  MAX_TRAJECTORY_SAMPLES,
  entryCovers,
  finiteLerp,
  interpolationFraction,
  quaternionNorm,
  frameDeltaGroups,
  iterateRecords,
  parseAttachment,
  parseAudio,
  parseAudioData,
  parseAudioSource,
  audioSourceStateAt,
  parseCamera,
  parseChunk,
  parseChunkIndexEntry,
  parseCoordinateFrame,
  parseDeltaChunk,
  parseFooter,
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
  parseSummaryOffset,
  parseWindowTable,
  readRecord,
} from "./records.js";

export {
  LENGTH_UNIT_METRES,
  Provenance,
  quaternionMultiply,
  type Pose,
  type PoseSampled,
  poseApply,
  poseAt,
  poseCompose,
  slerp,
} from "./provenance.js";
export { ObjectLayer, stateAtWithObjects } from "./objects.js";
export {
  checkQuantizationScheme,
  checkTemporalModel,
  KNOWN_QUANTIZATION_SCHEMES,
  KNOWN_TEMPORAL_MODELS,
} from "./registry.js";

export {
  MAX_STREAM_BYTES,
  MODE_CONST,
  MODE_DELTA,
  MODE_RAW,
  type RawStream,
  decodeStream,
  frameOneStream,
  frameStreams,
  unshuffleAndUnzigzag,
} from "./streams.js";

export {
  DEFAULT_CUTOFF,
  LIFE_MAX_CLASS,
  LIFE_MIN_CLASS,
  LIFE_REF,
  MU_MIN_CLASS,
  MU_REL,
  type Steps,
  dequantizeRotation,
  lifeClass,
  motionStep,
  muStep,
  rctInverse,
  supportK,
} from "./quantization.js";

export {
  MAX_SH_DEGREE,
  SH_MAX_BITS,
  SH_MIN_BITS,
  type ShCoefficients,
  bandCoefficientRange,
  coefficientsForDegree,
  coefficientsInBand,
  mergeBands,
  shBound,
  shStep,
} from "./sh.js";

export {
  type ChunkGaussians,
  type DecodeChunkOptions,
  chunkStreamBytes,
  checkWindowIndex,
  decodeChunkStreams,
  decompressChunkBlock,
  stepsFrom,
  windowTableOrDefault,
} from "./chunk.js";

export { GaussianSet, type GaussianState, assembleGaussians, marginalAt } from "./gaussians.js";

export { type GaussianInput, type WriteOptions, encodeScene } from "./writer.js";

export { StreamDecoder, type StreamedRecordPart } from "./streamDecoder.js";

export { FrontMatterScanner, type FrontMatterRecord } from "./frontMatter.js";

export { type AudioPayloadChunk, type DecodeOptions, type Scene, decodeScene } from "./scene.js";

export {
  HEAD_PROBE_BYTES,
  MAX_DEFERRED_RECORDS,
  MAX_FRONT_MATTER_BYTES,
  MAX_SUMMARY_BYTES,
  IndexedDecoder,
  type IndexedChunk,
  type OpenIndexedOptions,
  type ReadChunkOptions,
} from "./indexedDecoder.js";

export {
  KEYFRAME_DELTA_BIN_MAX,
  KEYFRAME_DELTA_BIN_MIN,
  MAX_KEYFRAME_DELTA_INDEX_ENTRIES,
  MAX_KEYFRAME_DELTA_SUMMARY_BYTES,
  KeyframeDeltaIndexedDecoder,
  KeyframeDeltaState,
  type Interval,
  type KeyframeDeltaChunkInfo,
  type KeyframeDeltaGaussians,
  type KeyframeDeltaIndexedResult,
  type KeyframeDeltaSequence,
  type OpenKeyframeDeltaIndexedOptions,
  chainFor,
  checkTiling,
  decodeKeyframeDeltaIndexed,
  decodeKeyframeDeltaStreamed,
  keyframeDeltaChunkAt,
  keyframeDeltaValidationRecordOffset,
  validateKeyframeDeltaStreamed,
  keyframeDeltaStatesJson,
  reconstructKeyframeDelta,
} from "./keyframeDelta.js";

export {
  type KeyframeDeltaSample,
  type KeyframeDeltaWriteOptions,
  encodeKeyframeDeltaSequence,
} from "./keyframeDeltaWriter.js";
