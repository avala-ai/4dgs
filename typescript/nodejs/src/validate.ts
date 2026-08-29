// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Structural validation.
 *
 * This is what makes a third-party encoder possible: a way to find out *why* a file is
 * wrong that does not involve reading someone else's decoder. Every finding names the
 * record, the field and what was expected.
 *
 * The checks, their severities and their wording are `python/fourdgs/fourdgs/validate.py`'s,
 * exactly as the Rust validator's are. Two validators that disagree about whether a file
 * conforms are worse than one, so where the two differ the Python module is the reference
 * and this is the bug. What this adds rather than changes is the **refusal identifier** and
 * the byte it fired at: the messages a library raises are each language's own, so the
 * identifier is the only part of a refusal two implementations can be compared on.
 *
 * The walk is range-backed. It retains the small cross-record tables needed for semantic
 * checks, but record bodies and checksum blocks are fetched one at a time and released.
 */

import {
  BytesReadable,
  CAMERA_MODEL_COEFFICIENTS,
  Crc32,
  Cursor,
  DELTA_MODE_CHAINED,
  DELTA_MODE_KEYFRAME,
  DEFAULT_CODECS,
  DEFAULT_CUTOFF,
  FOOTER_TAIL_BYTES,
  FourdgsError,
  FrontMatterScanner,
  HEADER_FLAG_CHUNKS_COMPRESSED,
  HEADER_FLAG_HAS_AUDIO,
  LENGTH_UNIT_METRES,
  MAGIC,
  MAX_FRONT_MATTER_BYTES,
  MAX_SH_DEGREE,
  MalformedFile,
  ObjectLayer,
  Opcode,
  Provenance,
  RECORD_HEADER_BYTES,
  bytesEqual,
  checkMagic,
  checkTiling,
  checkQuantizationScheme,
  checkTemporalModel,
  chunkStreamBytes,
  decodeChunkStreams,
  decodeStream,
  frameOneStream,
  isPrivateOpcode,
  isProvenanceOpcode,
  keyframeDeltaValidationRecordOffset,
  mergeBands,
  opcodeName,
  parseAudioSource,
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
  shBound,
  shStep,
  stepsFrom,
  supportK,
  validateKeyframeDeltaStreamed,
  windowTableOrDefault,
  type AudioSourceDescriptor,
  type ChunkIndexEntry,
  type ChunkHeader,
  type DeltaChunkHeader,
  type Footer,
  type FrontMatterRecord,
  type Header,
  type IReadable,
  type Quantization,
  type RefusalCode,
  type Statistics,
  type SummaryOffset,
} from "@4dgs/core";

export type Severity = "error" | "warning" | "note";

export interface Finding {
  readonly severity: Severity;
  readonly message: string;
}

/**
 * A refusal the specification names, and where in the file it fired.
 *
 * `code` is the language-independent identifier; `message` is this reader's sentence about
 * it; `at` is the byte a holder of the file should look at, and `where` says what sits
 * there — "the Header record", not just a number.
 */
export interface Refused {
  readonly code: RefusalCode;
  readonly message: string;
  readonly at: number;
  readonly where: string;
}

export interface Report {
  readonly findings: readonly Finding[];
  /** `null` when nothing the refusal table names went wrong. */
  readonly refused: Refused | null;
  /** True when no finding is an error. */
  readonly ok: boolean;
  /** True when there is at least one warning and no error. */
  readonly warned: boolean;
}

export interface ValidateOptions {
  /**
   * Also decode every chunk.
   *
   * Off by default, so the default verdict is the Python validator's verdict on the same
   * file. Two refusals in the specification's table — an unimplemented stream codec and a
   * window index with no row — live inside a chunk's attribute streams, and no amount of
   * framing reaches them: the structural pass calls such a file valid because structurally
   * it is. This decodes the chunks so those two are named as well, at the cost of reading
   * every byte the scene has.
   */
  readonly decode?: boolean;
}

class Findings {
  readonly items: Finding[] = [];
  refused: Refused | null = null;

  error(message: string): void {
    this.items.push({ severity: "error", message });
  }

  warn(message: string): void {
    this.items.push({ severity: "warning", message });
  }

  note(message: string): void {
    this.items.push({ severity: "note", message });
  }

  /** The earliest refusal in file order wins, independent of validation-pass order. */
  refuse(error: unknown, at: number, where: string): void {
    if (!(error instanceof FourdgsError) || error.refusalCode === undefined) return;
    if (this.refused !== null && this.refused.at <= at) return;
    this.refused = { code: error.refusalCode, message: error.message, at, where };
  }
}

/** Every check, in the Python validator's order. */
export async function validateFile(
  input: IReadable | Uint8Array,
  options: ValidateOptions = {},
): Promise<Report> {
  const source = input instanceof Uint8Array ? new BytesReadable(input) : input;
  const found = new Findings();
  const sizeBig = await source.size();
  if (sizeBig > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError(
      `resource size ${sizeBig} exceeds the largest exactly addressable size ` +
        `${Number.MAX_SAFE_INTEGER} in this implementation`,
    );
  }
  const size = Number(sizeBig);
  const scanner = new FrontMatterScanner(source, size, VALIDATION_PROBE_BYTES);
  try {
    checkMagic(await scanner.head(MAGIC.length));
  } catch (error) {
    found.error(message(error));
    const at =
      error instanceof FourdgsError && error.refusalCode === "unsupported-major-version" ? 5 : 0;
    found.refuse(error, at, at === 5 ? "the major-version byte" : "the file magic");
    return report(found);
  }

  if (
    size < MAGIC.length ||
    !bytesEqual(await source.read(BigInt(size - MAGIC.length), BigInt(MAGIC.length)), MAGIC)
  ) {
    found.error(
      "file does not end with the magic; it is truncated or was written by a broken encoder",
    );
  }

  let recordCount = 0;
  let firstOpcode: number | null = null;
  let lastOpcode: number | null = null;
  let headerCount = 0;
  let footerCount = 0;
  let legacyAudioCount = 0;
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let quantizationCount = 0;
  let windows: Float64Array | null = null;
  let footer: Footer | null = null;
  let chunkCount = 0;
  let counted = 0;
  const index: ChunkIndexEntry[] = [];
  let firstIndexOffset: number | null = null;
  const statisticsOffsets: number[] = [];
  const summaryOffsetOffsets: number[] = [];
  const statisticsRecords: { readonly offset: number; readonly value: Statistics }[] = [];
  const summaryOffsetRecords: { readonly offset: number; readonly value: SummaryOffset }[] = [];
  const physicalChunkOffsets: number[] = [];
  const physicalChunks = new Map<
    number,
    {
      readonly opcode: number;
      readonly length: number;
      readonly header: ChunkHeader | DeltaChunkHeader;
    }
  >();
  const physicalBands = new Map<
    number,
    { readonly band: number; readonly offset: number; readonly length: number }[]
  >();
  const physicalBandRecords = new Map<number, { readonly band: number; readonly length: number }>();
  let currentChunkOffset: number | null = null;
  const audioSources = new Map<number, AudioSourceDescriptor>();
  const audioData = new Map<number, number>();
  const provenance = new Provenance();
  const emptyTrajectories: string[] = [];
  const objects = new ObjectLayer();
  let firstChunkSeen = false;
  let decodedShChunk: {
    readonly ordinal: number;
    readonly count: number;
    readonly bands: Map<number, Int32Array>;
    decoded: boolean;
  } | null = null;
  const decodedShDegrees = new Set<number>();

  try {
    for await (const framed of scanner.records(MAGIC.length)) {
      recordCount += 1;
      if (recordCount > MAX_VALIDATION_RECORDS) {
        throw new RangeError(
          `validation stopped after ${MAX_VALIDATION_RECORDS} records; this is the tool's ` +
            "bounded-memory limit, not a malformed-file verdict",
        );
      }
      firstOpcode ??= framed.opcode;
      lastOpcode = framed.opcode;
      const record = {
        opcode: framed.opcode,
        offset: framed.offset,
        length: framed.totalLength,
      };
      const { offset } = record;
      let contentValue: Uint8Array | null = null;
      const content = async (): Promise<Uint8Array> => {
        if (framed.contentLength > MAX_FRONT_MATTER_BYTES) {
          throw new RangeError(
            `${opcodeName(framed.opcode)} record at byte ${framed.offset} is ` +
              `${framed.contentLength} bytes, past the ${MAX_FRONT_MATTER_BYTES} byte ` +
              "resource limit for a single parsed record",
          );
        }
        contentValue ??= await scanner.content(framed);
        return contentValue;
      };
      if (record.opcode !== Opcode.ShBandStream && decodedShChunk !== null) {
        finalizeDecodedShChunk(decodedShChunk, decodedShDegrees, found);
        decodedShChunk = null;
      }
      // An SH Band Stream belongs only to the Chunk immediately before the run of band
      // records. Any other top-level record ends that run.
      if (
        record.opcode !== Opcode.Chunk &&
        record.opcode !== Opcode.DeltaChunk &&
        record.opcode !== Opcode.ShBandStream
      ) {
        currentChunkOffset = null;
      }
      // A record whose own body will not parse is a finding rather than an abort: the point
      // of a validator is to say everything that is wrong with a file, not the first thing.
      switch (record.opcode) {
        case Opcode.Header:
          headerCount += 1;
          if (headerCount > 1) {
            found.error(
              `Header record ${headerCount} appears at byte ${offset}; the Header must be ` +
                "the first and only Header (§4)",
            );
          }
          try {
            header = parseHeader(await content());
          } catch (error) {
            found.error(`Header does not parse: ${message(error)}`);
            break;
          }
          // §4.2's Header definition spells the flags byte out: bit 0 is audio, bit 1 is
          // compressed chunks, "bits 2-7: reserved, MUST be 0". Nothing downstream can
          // notice a set reserved bit — `hasAudio` reads bit 0 and the rest is dropped —
          // so a writer that put meaning in one of them ships a file every reader
          // silently disagrees with it about. The parser makes this check for the Audio
          // Source record's flags already; the Header's had nobody making it.
          {
            const reserved =
              header.flags & ~(HEADER_FLAG_HAS_AUDIO | HEADER_FLAG_CHUNKS_COMPRESSED);
            if (reserved !== 0) {
              found.error(
                `Header flags is ${hex(header.flags)}; bits 2-7 are reserved and MUST be 0 (§4.2)`,
              );
            }
          }
          try {
            if (header.temporalModel !== "keyframe-delta") {
              checkTemporalModel(header.temporalModel);
            }
          } catch (error) {
            found.refuse(error, offset, "the Header record");
          }
          if (header.shDegree > MAX_SH_DEGREE) {
            found.error(
              `Header sh_degree is ${header.shDegree}; the attribute registry defines only ` +
                `degrees 0-${MAX_SH_DEGREE} (§5.1)`,
            );
          }
          if (!Number.isFinite(header.cutoff) || header.cutoff <= 0 || header.cutoff > 1) {
            found.error(
              `Header cutoff is ${header.cutoff}; expected a finite value in (0, 1] (§4.2)`,
            );
          }
          break;
        case Opcode.Quantization:
          try {
            quantization = parseQuantization(await content(), offset);
          } catch (error) {
            found.error(`Quantization does not parse: ${message(error)}`);
            found.refuse(error, offset, "the Quantization record");
            break;
          }
          // Checked here, as the record is met, rather than once at the end on whichever
          // copy survived the loop. Nothing in the framing forbids a second Quantization
          // record, and a streamed decoder takes the first grid it meets — so checking only
          // the last would pass a file whose first grid is non-finite while the whole scene
          // decodes through it.
          checkQuantizationFinite(quantization, found, quantizationCount);
          checkShBitDepths(quantization, header === null ? 0 : header.shDegree, found);
          quantizationCount += 1;
          try {
            checkQuantizationScheme(quantization.scheme);
          } catch (error) {
            found.refuse(error, offset, "the Quantization record");
          }
          break;
        case Opcode.WindowTable:
          // Read for the decode pass below, quietly: the Python validator does not parse
          // this record, and a finding it does not have is a disagreement about a file.
          try {
            windows = parseWindowTable(await content());
            if (options.decode === true) {
              for (let i = 0; i < windows.length; i += 2) {
                const lo = windows[i]!;
                const hi = windows[i + 1]!;
                if (Number.isNaN(lo) || Number.isNaN(hi) || hi < lo) {
                  found.error(
                    `Window Table row ${i / 2} is [${spell(lo)}, ${spell(hi)}]; expected ` +
                      "non-NaN ordered bounds (empty windows and infinities are legal)",
                  );
                }
              }
            }
          } catch (error) {
            windows = null;
            if (options.decode === true) {
              found.error(`Window Table does not parse: ${message(error)}`);
            }
          }
          break;
        case Opcode.Chunk: {
          const activeHeader = header as Header | null;
          physicalChunkOffsets.push(offset);
          physicalBands.set(offset, []);
          currentChunkOffset = offset;
          firstChunkSeen = true;
          chunkCount += 1;
          let parsed;
          try {
            parsed = {
              header: await parseChunkRecordHeader(source, framed),
              streams: new Uint8Array(),
            };
          } catch (error) {
            if (error instanceof RangeError) throw error;
            found.error(`chunk ${chunkCount} does not parse: ${message(error)}`);
            break;
          }
          counted += parsed.header.count;
          if (
            activeHeader?.temporalModel === "keyframe-delta" &&
            parsed.header.count > activeHeader.gaussianCount
          ) {
            found.error(
              `keyframe Chunk at byte ${offset} declares ${parsed.header.count} gaussians; ` +
                `the Header declares only ${activeHeader.gaussianCount} distinct gaussian ids`,
            );
          }
          physicalChunks.set(offset, {
            opcode: Opcode.Chunk,
            length: record.length,
            header: parsed.header,
          });
          decodedShChunk = {
            ordinal: physicalChunkOffsets.length,
            count: parsed.header.count,
            bands: new Map<number, Int32Array>(),
            decoded: options.decode === true,
          };
          if (Number.isNaN(parsed.header.t0) || Number.isNaN(parsed.header.t1)) {
            found.error(
              `chunk ${chunkCount} has a NaN interval endpoint; expected finite or infinite ` +
                "ordered bounds",
            );
          } else if (parsed.header.t1 < parsed.header.t0) {
            found.error(
              `chunk ${chunkCount} has t1 (${parsed.header.t1}) before t0 (${parsed.header.t0})`,
            );
          }
          if (
            activeHeader?.temporalModel !== "keyframe-delta" &&
            parsed.header.count > 0 &&
            parsed.header.t0 === parsed.header.t1
          ) {
            found.error(
              `gaussian-birth chunk ${chunkCount} has ${parsed.header.count} gaussians in ` +
                `zero-width interval [${parsed.header.t0}, ${parsed.header.t1}); no seek can ` +
                "select them",
            );
          }
          break;
        }
        case Opcode.DeltaChunk: {
          physicalChunkOffsets.push(offset);
          physicalBands.set(offset, []);
          currentChunkOffset = offset;
          firstChunkSeen = true;
          chunkCount += 1;
          let parsed;
          try {
            parsed =
              options.decode === true
                ? parseDeltaChunk(await scanner.content(framed))
                : {
                    header: await parseDeltaChunkRecordHeader(source, framed),
                    records: new Uint8Array(),
                  };
          } catch (error) {
            if (error instanceof RangeError) throw error;
            found.error(`Delta Chunk at byte ${offset} does not parse: ${message(error)}`);
            break;
          }
          physicalChunks.set(offset, {
            opcode: Opcode.DeltaChunk,
            length: record.length,
            header: parsed.header,
          });
          decodedShChunk = {
            ordinal: physicalChunkOffsets.length,
            count: parsed.header.birthCount,
            bands: new Map<number, Int32Array>(),
            decoded: options.decode === true,
          };
          if (header !== null && header.temporalModel !== "keyframe-delta") {
            found.error(
              `Delta Chunk at byte ${offset} is not legal under temporal_model ` +
                `${JSON.stringify(header.temporalModel)}; it belongs only to keyframe-delta`,
            );
          }
          if (Number.isNaN(parsed.header.t0) || Number.isNaN(parsed.header.t1)) {
            found.error(
              `Delta Chunk at byte ${offset} has a NaN interval endpoint; expected finite or ` +
                "infinite ordered bounds",
            );
          } else if (parsed.header.t1 < parsed.header.t0) {
            found.error(
              `Delta Chunk at byte ${offset} has t1 (${parsed.header.t1}) before t0 ` +
                `(${parsed.header.t0})`,
            );
          }
          break;
        }
        case Opcode.ShBandStream: {
          // Framing steps over these; only a decoder reaches inside one. The streamed
          // decoder parses and decodes every band record it meets (`scene.ts`), so a file
          // whose band declares a codec this build does not have, or whose payload is cut,
          // is refused there — and a `--decode` pass that skipped them would report that
          // same file valid. The two refusals a chunk's own streams can raise are exactly
          // the two a band's stream can raise, for the same reason.
          let band = 0;
          let duplicateBand = false;
          try {
            const parsedBand = parseShBandRecord(
              options.decode === true
                ? await scanner.content(framed)
                : await scanner.content(framed, 1),
            );
            band = parsedBand.band;
            if (band < 1 || band > MAX_SH_DEGREE) {
              found.error(
                `SH Band Stream at byte ${offset} declares band ${band}; the registry defines ` +
                  `bands 1-${MAX_SH_DEGREE} (§5.7)`,
              );
            }
            if (currentChunkOffset === null) {
              found.error(
                `SH Band Stream at byte ${offset} does not immediately follow a Chunk, Delta ` +
                  "Chunk, or one of that state Chunk's SH Band Stream records",
              );
            } else {
              const ownerBands = physicalBands.get(currentChunkOffset)!;
              duplicateBand = ownerBands.some((range) => range.band === band);
              if (duplicateBand) {
                found.error(
                  `SH Band Stream at byte ${offset} repeats band ${band} for the state Chunk ` +
                    `at byte ${currentChunkOffset}; expected each band at most once`,
                );
              }
              ownerBands.push({
                band,
                offset,
                length: record.length,
              });
              physicalBandRecords.set(offset, { band, length: record.length });
            }
            if (options.decode !== true || decodedShChunk === null) break;
            if (band < 1 || band > MAX_SH_DEGREE) break;
            const framedBand = frameOneStream(parsedBand.cursor);
            if (framedBand.attributeId !== Opcode.ShBandStream) {
              found.error(
                `SH Band Stream at byte ${offset} declares nested attribute_id ` +
                  `${framedBand.attributeId}; version 1 fixes it at ${Opcode.ShBandStream}`,
              );
            }
            const values = await decodeStream(framedBand, DEFAULT_CODECS);
            if (!duplicateBand) decodedShChunk.bands.set(band, values);
          } catch (error) {
            found.error(
              `SH Band Stream at byte ${offset}: chunk ${chunkCount} SH band ${band} ` +
                `does not decode: ${message(error)}`,
            );
            found.refuse(error, offset, "the SH Band Stream record");
          }
          break;
        }
        case Opcode.ChunkIndex:
          firstIndexOffset ??= offset;
          try {
            index.push(parseChunkIndexEntry(await content()));
          } catch (error) {
            found.error(`a chunk index entry does not parse: ${message(error)}`);
          }
          break;
        case Opcode.Footer:
          footerCount += 1;
          try {
            footer = parseFooter(await content());
          } catch (error) {
            found.error(`Footer does not parse: ${message(error)}`);
          }
          break;
        case Opcode.AudioSource: {
          let source;
          try {
            source = parseAudioSource(await content());
          } catch (error) {
            found.error(`Audio Source does not parse: ${message(error)}`);
            break;
          }
          if (firstChunkSeen) {
            found.error(`Audio Source id ${source.sourceId} appears after the first Chunk`);
          }
          if (audioSources.has(source.sourceId)) {
            found.error(`Audio Source id ${source.sourceId} appears more than once`);
          }
          audioSources.set(source.sourceId, source);
          break;
        }
        case Opcode.AudioData: {
          let payload;
          try {
            payload = await parseAudioDataRecord(source, framed);
          } catch (error) {
            found.error(`Audio Data does not parse: ${message(error)}`);
            break;
          }
          if (firstChunkSeen) {
            found.error(`Audio Data id ${payload.sourceId} appears after the first Chunk`);
          }
          if (audioData.has(payload.sourceId)) {
            found.error(`Audio Data id ${payload.sourceId} appears more than once`);
          }
          audioData.set(payload.sourceId, payload.dataLength);
          break;
        }
        // The provenance and object-layer records, parsed for the rules that span more
        // than one of them. A validator that skipped these declared a file valid that
        // this package's own streamed decoder refuses — `scene.ts` calls the same two
        // `check()` methods — and that the Python validator refuses too. Neither their
        // per-record fields nor Python's semantic provenance findings belong in those
        // cross-record checkers: the parsers make the first, and `checkProvenance` below
        // reports the second without turning unknown-but-legal registry values into
        // malformed bytes.
        case Opcode.CoordinateFrame:
          await parseInto(found, "CoordinateFrame", offset, async () => {
            provenance.frames.push(parseCoordinateFrame(await content()));
          });
          break;
        case Opcode.SensorCalibration:
          await parseInto(found, "SensorCalibration", offset, async () => {
            provenance.sensors.push(parseSensorCalibration(await content()));
          });
          break;
        case Opcode.RigTrajectory:
          await parseInto(found, "RigTrajectory", offset, async () => {
            const trajectory = parseRigTrajectory(await content());
            // §5.15.4 reads a zero-sample trajectory as absent. In
            // particular, it neither collides with another absent record nor
            // shadows a later, real trajectory with the same name.
            if (trajectory.times.length > 0) provenance.trajectories.push(trajectory);
            else emptyTrajectories.push(trajectory.name);
          });
          break;
        case Opcode.GeodeticAnchor:
          await parseInto(found, "GeodeticAnchor", offset, async () => {
            provenance.anchors.push(parseGeodeticAnchor(await content()));
          });
          break;
        case Opcode.ObjectTable:
          if (objects.table !== null) {
            found.error(
              `a second ObjectTable record appears at byte ${offset}; ` +
                "a file may carry exactly one scene-wide object table",
            );
            break;
          }
          await parseInto(found, "ObjectTable", offset, async () => {
            objects.table = parseObjectTable(await content());
          });
          break;
        case Opcode.ObjectTrack:
          await parseInto(found, "ObjectTrack", offset, async () => {
            const track = parseObjectTrack(await content());
            // §5.15.7 reads a zero-sample track as absent. In particular, two
            // absent records for one id are not two active tracks.
            if (track.times.length > 0) objects.tracks.push(track);
          });
          break;
        case Opcode.Camera:
          await parseInto(found, "Camera", offset, async () => {
            parseCamera(await content());
          });
          break;
        case Opcode.Metadata:
          await parseInto(found, "Metadata", offset, async () => {
            parseMetadata(await content());
          });
          break;
        case Opcode.Attachment:
          await parseInto(found, "Attachment", offset, async () => {
            await validatePayloadRecord(source, framed, 2, 0);
          });
          break;
        case Opcode.Statistics:
          statisticsOffsets.push(offset);
          await parseInto(found, "Statistics", offset, async () => {
            statisticsRecords.push({ offset, value: parseStatistics(await content()) });
          });
          break;
        case Opcode.SummaryOffset:
          summaryOffsetOffsets.push(offset);
          await parseInto(found, "SummaryOffset", offset, async () => {
            summaryOffsetRecords.push({ offset, value: parseSummaryOffset(await content()) });
          });
          break;
        case Opcode.Audio:
          legacyAudioCount += 1;
          if (legacyAudioCount > 1) {
            found.error(
              `legacy Audio record ${legacyAudioCount} appears at byte ${offset}; ` +
                "a file may carry at most one legacy Audio record",
            );
          }
          await parseInto(found, "Audio", offset, async () => {
            await validatePayloadRecord(source, framed, 1, 8);
          });
          break;
        default:
          if (isPrivateOpcode(record.opcode)) {
            found.note(
              `private record ${hex(record.opcode)} (${framed.contentLength} bytes) — skipped, as required`,
            );
          } else if (ILLEGAL_TOP_LEVEL_OPCODES.has(record.opcode)) {
            found.error(
              `${opcodeName(record.opcode)} (${hex(record.opcode)}) is not a legal top-level ` +
                "record (§5)",
            );
          } else if (TOP_LEVEL_OPCODES.has(record.opcode)) {
            // A record this validator has nothing to say about — provenance, the object
            // layer, a camera. Framed, stepped over, not remarked on.
          } else if (isProvenanceOpcode(record.opcode)) {
            found.note(
              `reserved provenance record ${hex(record.opcode)} — skipped, as required ` +
                `(0x24-0x2F, section 5.15.6)`,
            );
          } else {
            found.note(`unknown record ${hex(record.opcode)} — skipped, as required`);
          }
          break;
      }
    }
  } catch (error) {
    if (error instanceof RangeError) throw error;
    found.error(`stopped reading: ${message(error)}`);
  }
  if (decodedShChunk !== null) {
    finalizeDecodedShChunk(decodedShChunk, decodedShDegrees, found);
    decodedShChunk = null;
  }

  if (
    options.decode === true &&
    header !== null &&
    quantization !== null &&
    header.temporalModel !== "keyframe-delta"
  ) {
    await decodeGaussianBirthChunks(
      source,
      size,
      header,
      quantization,
      windows ?? new Float64Array(0),
      physicalChunks,
      found,
    );
  }

  // Decoding each SH stream proves only its framing and codec. The decoded values become
  // gaussian state only after the bands are assembled, and that step enforces the semantic
  // invariants a normal streamed read enforces: whole degrees starting at band 1, the
  // coefficient count for this chunk, values in the stored u8 range, and one scene-wide
  // degree shared by every chunk.
  if (options.decode === true) {
    if (decodedShDegrees.size > 1) {
      found.error(`chunks disagree on SH degree: ${[...decodedShDegrees].join(", ")}`);
    }
    if (header !== null && [...decodedShDegrees].some((degree) => degree !== header!.shDegree)) {
      found.error(
        `chunks assemble SH degree ${[...decodedShDegrees].join(", ")}; the Header ` +
          `declares degree ${header.shDegree} (§6.5)`,
      );
    }
  }

  if (recordCount === 0) {
    found.error("no records at all");
    return report(found);
  }
  if (firstOpcode !== Opcode.Header) {
    found.error(`first record is ${opcodeName(firstOpcode!)}; the Header must come first`);
  }
  if (header === null) found.error("no Header record");
  if (quantization === null) found.error("no Quantization record");
  if (footer === null) found.error("no Footer record");
  // §4: "the Footer MUST be the last [record]". Presence is not position, and the
  // difference is reachable: a record wedged between a real Footer and the trailing magic
  // leaves every check above satisfied, while `IndexedDecoder.open` reads the tail record
  // and parses its content as Footer fields whatever its opcode. The walk in `inspect.ts`
  // refuses to read a tail that is not a Footer record; this is the same rule, on the same
  // file, from the other tool.
  if (footer !== null && lastOpcode !== Opcode.Footer) {
    found.error(
      `the last record is ${opcodeName(lastOpcode!)}; the Footer must be the last record (§4)`,
    );
  }
  if (footerCount > 1) {
    found.error(
      `the file carries ${footerCount} Footer records; every Footer must be the last record (§4)`,
    );
  }

  // The rules no single provenance or object record can enforce on its own — a duplicate
  // name, a sensor posed against a rig the file does not carry, two tracks moving one
  // object. `scene.ts` refuses these, so without them a file this package cannot decode
  // was being reported as conforming.
  for (const layer of [provenance, objects]) {
    try {
      layer.check();
    } catch (error) {
      found.error(message(error));
    }
  }
  checkProvenance(provenance, emptyTrajectories, found);

  if (header !== null) {
    if (header.temporalModel !== "keyframe-delta" && counted !== header.gaussianCount) {
      found.error(`Header declares ${header.gaussianCount} gaussians; chunks contain ${counted}`);
    }
    const hasAudioRecords = legacyAudioCount > 0 || audioSources.size > 0 || audioData.size > 0;
    if (header.hasAudio && !hasAudioRecords) {
      found.error(
        "Header says the file has audio, but there is no Audio Source or legacy Audio record",
      );
    }
    if (!header.hasAudio && hasAudioRecords) {
      found.error(
        "there is an Audio Source or legacy Audio record, but the Header's audio flag is clear",
      );
    }
    // The parser already refuses a keyframe list that is not finite and strictly
    // increasing; what it cannot know is the scene clock those times have to sit on.
    for (const source of audioSources.values()) {
      source.keyframes.forEach((keyframe, i) => {
        if (keyframe.time < 0 || keyframe.time > header!.durationSec) {
          found.error(
            `Audio Source id ${source.sourceId} keyframe ${i} time ${keyframe.time} ` +
              `is outside [0, ${header!.durationSec}]`,
          );
        }
      });
    }
  }

  for (const { offset, value: statistics } of statisticsRecords) {
    if (header !== null && statistics.gaussianCount !== header.gaussianCount) {
      found.error(
        `Statistics record at byte ${offset} declares gaussian_count ` +
          `${statistics.gaussianCount}; the Header declares ${header.gaussianCount}`,
      );
    }
    if (header !== null && !Object.is(statistics.durationSec, header.durationSec)) {
      found.error(
        `Statistics record at byte ${offset} declares duration_sec ` +
          `${statistics.durationSec}; the Header declares ${header.durationSec}`,
      );
    }
    if (statistics.chunkCount !== chunkCount) {
      found.error(
        `Statistics record at byte ${offset} declares chunk_count ${statistics.chunkCount}; ` +
          `the physical record walk found ${chunkCount} state chunks`,
      );
    }
    if (index.length > 0 && statistics.chunkCount !== index.length) {
      found.error(
        `Statistics record at byte ${offset} declares chunk_count ${statistics.chunkCount}; ` +
          `the Chunk Index contains ${index.length} entries`,
      );
    }
  }

  if (header?.temporalModel === "keyframe-delta") {
    const intervals =
      index.length > 0
        ? index
        : [...physicalChunks.values()].map(({ header: stateHeader }) => ({
            t0: stateHeader.t0,
            t1: stateHeader.t1,
          }));
    try {
      checkTiling(intervals, header.durationSec, true);
    } catch (error) {
      found.error(`keyframe-delta timeline does not tile the scene clock: ${message(error)}`);
    }
  }

  if (options.decode === true && header?.temporalModel === "keyframe-delta") {
    const liveCounts = new Map<number, number>();
    try {
      await validateKeyframeDeltaStreamed(source, DEFAULT_CODECS, (offset, liveCount) => {
        liveCounts.set(offset, liveCount);
      });
      index.forEach((entry, i) => {
        if (!entry.extended) return;
        const composed = liveCounts.get(entry.chunkOffset);
        if (composed !== undefined && entry.liveCount !== composed) {
          found.error(
            `chunk index entry ${i} declares live_count ${entry.liveCount}; composing the ` +
              `state at ${entry.chunkOffset} produces ${composed} gaussians`,
          );
        }
      });
    } catch (error) {
      if (error instanceof RangeError) throw error;
      found.error(`keyframe-delta timeline does not decode: ${message(error)}`);
      const at =
        keyframeDeltaValidationRecordOffset(error) ?? physicalChunkOffsets[0] ?? MAGIC.length;
      found.refuse(error, at, "the keyframe-delta state record");
    }
  }
  if (legacyAudioCount > 0 && audioSources.size > 0) {
    found.error("legacy Audio and Audio Source records must not be mixed");
  }
  for (const [sourceId, source] of audioSources) {
    const length = audioData.get(sourceId);
    if (length === undefined) {
      found.error(`Audio Source id ${sourceId} has no matching Audio Data record`);
    } else if (source.dataLength !== length) {
      found.error(
        `Audio Source id ${sourceId} declares ${source.dataLength} bytes; ` +
          `Audio Data contains ${length}`,
      );
    }
  }
  for (const sourceId of audioData.keys()) {
    if (!audioSources.has(sourceId)) {
      found.error(`Audio Data id ${sourceId} has no matching Audio Source record`);
    }
  }

  index.forEach((entry, i) => {
    const chunkEnd = entry.chunkOffset + entry.chunkLength;
    const physical = physicalChunks.get(entry.chunkOffset);
    if (!Number.isSafeInteger(chunkEnd) || chunkEnd > size) {
      found.error(`chunk index entry ${i} points past the end of the file`);
    } else if (physical === undefined) {
      found.error(
        `chunk index entry ${i} points at byte ${entry.chunkOffset}, which is not the start ` +
          `of a top-level record holding a Chunk or Delta Chunk`,
      );
    } else {
      // §5.8: "Every offset and length here frames a whole record, opcode byte and
      // content length included, so a reader fetches `[offset, offset + length)` and
      // parses it exactly as it would parse that record mid-stream." An entry whose first
      // byte is right and whose length is not describes a range no reader can parse:
      // `IndexedDecoder.readChunk` range-reads exactly this many bytes before framing
      // them, so the seek path — a first-class read path, not an optimization (AGENTS.md
      // §2) — fails on a file the checks above call conforming.
      if (physical.length !== entry.chunkLength) {
        found.error(
          `chunk index entry ${i} declares ${entry.chunkLength} bytes at ` +
            `${entry.chunkOffset}; the record there is ${physical.length} bytes (§5.8)`,
        );
      } else if (
        header?.temporalModel === "keyframe-delta" &&
        entry.extended &&
        entry.kind === 1 &&
        physical.opcode !== Opcode.DeltaChunk
      ) {
        found.error(`chunk index entry ${i} declares a delta but points at a Chunk record`);
      } else if (
        (header?.temporalModel !== "keyframe-delta" || !entry.extended || entry.kind === 0) &&
        physical.opcode !== Opcode.Chunk
      ) {
        found.error(`chunk index entry ${i} declares a keyframe but points at a Delta Chunk`);
      } else {
        const head = physical.header;
        if (physical.opcode === Opcode.Chunk) {
          const chunkHead = head as ChunkHeader;
          if (chunkHead.count !== entry.gaussianCount) {
            found.error(
              `chunk index entry ${i} declares ${entry.gaussianCount} gaussians; the Chunk ` +
                `at ${entry.chunkOffset} contains ${chunkHead.count}`,
            );
          }
        } else {
          const deltaHead = head as DeltaChunkHeader;
          const deltaCount = deltaHead.updateCount + deltaHead.birthCount + deltaHead.deathCount;
          if (entry.gaussianCount !== deltaCount) {
            found.error(
              `chunk index entry ${i} declares ${entry.gaussianCount} affected gaussians; ` +
                `the Delta Chunk at ${entry.chunkOffset} declares ${deltaCount} across its groups`,
            );
          }
          const fields: readonly (readonly [string, number, number])[] = [
            ["delta_mode", entry.deltaMode, deltaHead.deltaMode],
            ["reference_offset", entry.referenceOffset, deltaHead.referenceOffset],
            ["keyframe_offset", entry.keyframeOffset, deltaHead.keyframeOffset],
            ["depth", entry.depth, deltaHead.depth],
          ];
          for (const [name, indexed, actual] of fields) {
            if (indexed !== actual) {
              found.error(
                `chunk index entry ${i} declares ${name}=${indexed}; the Delta Chunk at ` +
                  `${entry.chunkOffset} declares ${name}=${actual}`,
              );
            }
          }
        }
        if (!Object.is(head.t0, entry.t0) || !Object.is(head.t1, entry.t1)) {
          found.error(
            `chunk index entry ${i} declares interval [${entry.t0}, ${entry.t1}); the ` +
              `${opcodeName(physical.opcode)} at ${entry.chunkOffset} declares ` +
              `[${head.t0}, ${head.t1})`,
          );
        }
      }
    }

    entry.bands.forEach((band, j) => {
      const bandEnd = band.offset + band.length;
      const where = `chunk index entry ${i} SH band range ${j}`;
      if (!Number.isSafeInteger(bandEnd) || bandEnd > size) {
        found.error(`${where} points past the end of the file`);
        return;
      }
      const physicalBand = physicalBandRecords.get(band.offset);
      if (physicalBand === undefined) {
        found.error(`${where} does not point at the start of a top-level record`);
        return;
      }
      if (physicalBand.length !== band.length) {
        found.error(
          `${where} declares ${band.length} bytes at ${band.offset}; the record there is ` +
            `${physicalBand.length} bytes (§5.8)`,
        );
        return;
      }
      if (physicalBand.band !== band.band) {
        found.error(
          `${where} says band ${band.band}; the record at ${band.offset} says band ` +
            `${physicalBand.band}`,
        );
      }
    });
  });

  checkKeyframeDeltaIndexChains(index, found, header?.temporalModel === "keyframe-delta");
  if (index.length === 0) {
    checkKeyframeDeltaPhysicalChains(
      physicalChunks,
      found,
      header?.temporalModel === "keyframe-delta",
    );
  }

  // An index is a one-for-one description of the physical Chunk records, not merely a
  // collection of individually valid pointers. Missing and duplicate entries both make
  // indexed reads disagree with a front-to-back walk.
  if (firstIndexOffset !== null) {
    const indexedCounts = new Map<number, number>();
    for (const entry of index) {
      indexedCounts.set(entry.chunkOffset, (indexedCounts.get(entry.chunkOffset) ?? 0) + 1);
    }
    for (const chunkOffset of physicalChunkOffsets) {
      const count = indexedCounts.get(chunkOffset) ?? 0;
      if (count === 0) {
        found.error(`the Chunk at byte ${chunkOffset} has no Chunk Index entry`);
      } else if (count > 1) {
        found.error(
          `the Chunk at byte ${chunkOffset} has ${count} Chunk Index entries; expected 1`,
        );
      }
    }
    const physicalChunkSet = new Set(physicalChunkOffsets);
    for (const [chunkOffset, count] of indexedCounts) {
      if (!physicalChunkSet.has(chunkOffset)) {
        found.error(
          `${count} Chunk Index ${count === 1 ? "entry points" : "entries point"} at byte ` +
            `${chunkOffset}, where there is no physical Chunk`,
        );
      }
    }

    index.forEach((entry, i) => {
      const expected = physicalBands.get(entry.chunkOffset);
      if (expected === undefined) return;
      const expectedCounts = rangeCounts(expected);
      const indexedCountsForChunk = rangeCounts(entry.bands);
      for (const range of expected) {
        const key = bandRangeKey(range);
        const actual = indexedCountsForChunk.get(key) ?? 0;
        const required = expectedCounts.get(key)!;
        if (actual < required) {
          found.error(
            `chunk index entry ${i} omits physical SH band ${range.band} at byte ` +
              `${range.offset} (${range.length} bytes) from its Chunk at ${entry.chunkOffset}`,
          );
          expectedCounts.set(key, actual);
        }
      }
      for (const range of entry.bands) {
        const key = bandRangeKey(range);
        const actual = indexedCountsForChunk.get(key)!;
        const required = rangeCounts(expected).get(key) ?? 0;
        if (actual > required) {
          found.error(
            `chunk index entry ${i} includes SH band ${range.band} at byte ${range.offset} ` +
              `(${range.length} bytes), which does not belong to its Chunk at ${entry.chunkOffset}`,
          );
          indexedCountsForChunk.set(key, required);
        }
      }
    });
  }

  if (footer !== null && footer.summaryStart === 0 && firstIndexOffset !== null) {
    found.error(
      `the file carries Chunk Index records starting at byte ${firstIndexOffset}, but the ` +
        "Footer's summary_start is 0 (§5.2)",
    );
  }

  if (footer !== null && footer.summaryStart !== 0) {
    // The Footer record itself is not covered: nine bytes of framing plus its twenty bytes
    // of content plus the trailing magic.
    const tail = size - FOOTER_TAIL_BYTES;
    if (footer.summaryStart > tail) {
      found.error(
        `the Footer's summary starts at ${footer.summaryStart}, after the summary ends at ${tail}`,
      );
    } else if (
      footer.summaryCrc !== 0 &&
      (await crcRange(source, footer.summaryStart, tail)) !== footer.summaryCrc
    ) {
      found.error("summary CRC mismatch: the index is untrustworthy (a streamed read still works)");
    }
    if (firstIndexOffset === null) {
      found.error(
        `the Footer's nonzero summary_start ${footer.summaryStart} names no Chunk Index ` +
          `record (§5.2)`,
      );
    } else if (footer.summaryStart !== firstIndexOffset) {
      found.error(
        `the Footer's summary starts at ${footer.summaryStart}; the first Chunk Index ` +
          `record starts at ${firstIndexOffset} (§5.2)`,
      );
    }
    await checkSummaryComposition(source, size, footer.summaryStart, tail, found);
  }

  if (footer !== null) {
    const tail = size - FOOTER_TAIL_BYTES;
    for (const offset of statisticsOffsets) {
      if (footer.summaryStart === 0 || offset < footer.summaryStart || offset >= tail) {
        found.error(
          `Statistics record at byte ${offset} lies outside the declared summary ` +
            `[${footer.summaryStart}, ${tail}) (§4.5)`,
        );
      }
    }
    const summaryOffsetsInSummary = summaryOffsetOffsets.filter(
      (offset) => footer!.summaryStart !== 0 && offset >= footer!.summaryStart && offset < tail,
    );
    const summaryOffsetSet = new Set(summaryOffsetsInSummary);
    for (const offset of summaryOffsetOffsets) {
      if (!summaryOffsetSet.has(offset)) {
        found.error(
          `Summary Offset record at byte ${offset} lies outside the declared summary ` +
            `[${footer.summaryStart}, ${tail}) (§5.2)`,
        );
      }
    }
    for (const { offset, value } of summaryOffsetRecords) {
      const groupEnd = value.groupStart + value.groupLength;
      if (value.groupLength === 0) {
        found.error(
          `Summary Offset record at byte ${offset} declares a zero-length group for ` +
            `${opcodeName(value.groupOpcode)}`,
        );
      } else if (
        !Number.isSafeInteger(groupEnd) ||
        footer.summaryStart === 0 ||
        value.groupStart < footer.summaryStart ||
        groupEnd > tail
      ) {
        found.error(
          `Summary Offset record at byte ${offset} declares ` +
            `${opcodeName(value.groupOpcode)} range [${value.groupStart}, ${groupEnd}), ` +
            `outside the summary [${footer.summaryStart}, ${tail})`,
        );
      }
    }
    const expectedSummaryOffset = summaryOffsetsInSummary[0] ?? 0;
    if (footer.summaryOffsetStart !== expectedSummaryOffset) {
      found.error(
        `the Footer's summary_offset_start is ${footer.summaryOffsetStart}; the first Summary ` +
          `Offset record starts at ${expectedSummaryOffset} (§5.2)`,
      );
    }
  }

  if (header !== null && index.length === 0) {
    found.warn("no chunk index: this file can only be read front to back, not seeked");
  }

  return report(found);
}

interface PhysicalBandRange {
  readonly band: number;
  readonly offset: number;
  readonly length: number;
}

/**
 * Derive depth and GOP identity from the index's references, independently of the duplicated
 * Delta Chunk headers. Comparing index fields with record fields catches disagreement; this
 * catches the equally corrupt case where both copies agree on a false seek cost.
 */
function checkKeyframeDeltaIndexChains(
  index: readonly ChunkIndexEntry[],
  found: Findings,
  keyframeDelta: boolean,
): void {
  if (!keyframeDelta) return;
  const ordered = [...index].sort((a, b) => a.chunkOffset - b.chunkOffset);
  const derived = new Map<number, { depth: number; keyframeOffset: number; kind: number }>();
  let previousOffset: number | null = null;
  for (const entry of ordered) {
    if (!entry.extended) {
      found.error(
        `the keyframe-delta chunk index entry at ${entry.chunkOffset} omits ` +
          "chunk_kind, delta reference, depth and live_count fields",
      );
      previousOffset = entry.chunkOffset;
      continue;
    }
    if (entry.kind === 0) {
      if (entry.deltaMode !== 0) {
        found.error(
          `the keyframe index entry at ${entry.chunkOffset} declares delta_mode ` +
            `${entry.deltaMode}; a keyframe must declare 0`,
        );
      }
      if (entry.referenceOffset !== 0) {
        found.error(
          `the keyframe index entry at ${entry.chunkOffset} declares reference_offset ` +
            `${entry.referenceOffset}; a keyframe must declare 0`,
        );
      }
      if (entry.depth !== 0) {
        found.error(
          `the keyframe index entry at ${entry.chunkOffset} declares depth ${entry.depth}; ` +
            "a keyframe has depth 0",
        );
      }
      if (entry.keyframeOffset !== entry.chunkOffset) {
        found.error(
          `the keyframe index entry at ${entry.chunkOffset} declares keyframe_offset ` +
            `${entry.keyframeOffset}; expected its own offset`,
        );
      }
      derived.set(entry.chunkOffset, {
        depth: 0,
        keyframeOffset: entry.chunkOffset,
        kind: entry.kind,
      });
      previousOffset = entry.chunkOffset;
      continue;
    }
    if (entry.kind !== 1) {
      found.error(
        `chunk index entry at ${entry.chunkOffset} declares chunk_kind ${entry.kind}; expected ` +
          "0 (keyframe) or 1 (delta)",
      );
      previousOffset = entry.chunkOffset;
      continue;
    }
    const reference = derived.get(entry.referenceOffset);
    if (reference === undefined) {
      found.error(
        `the delta index entry at ${entry.chunkOffset} references ${entry.referenceOffset}, ` +
          "which is not an earlier indexed state chunk",
      );
      previousOffset = entry.chunkOffset;
      continue;
    }
    if (entry.deltaMode === DELTA_MODE_KEYFRAME && reference.kind !== 0) {
      found.error(
        `the keyframe-referenced delta index entry at ${entry.chunkOffset} references ` +
          `${entry.referenceOffset}, which is itself a delta`,
      );
    } else if (entry.deltaMode === DELTA_MODE_CHAINED && previousOffset !== entry.referenceOffset) {
      found.error(
        `the chained delta index entry at ${entry.chunkOffset} references ` +
          `${entry.referenceOffset}; the immediately preceding state is at ${previousOffset}`,
      );
    } else if (entry.deltaMode !== DELTA_MODE_KEYFRAME && entry.deltaMode !== DELTA_MODE_CHAINED) {
      found.error(
        `the delta index entry at ${entry.chunkOffset} declares delta_mode ` +
          `${entry.deltaMode}; expected ${DELTA_MODE_KEYFRAME} (keyframe) or ` +
          `${DELTA_MODE_CHAINED} (chained)`,
      );
    }
    const expectedDepth = reference.depth + 1;
    if (entry.depth !== expectedDepth) {
      found.error(
        `the delta index entry at ${entry.chunkOffset} declares depth ${entry.depth}, but its ` +
          `reference chain walks ${expectedDepth} delta chunks`,
      );
    }
    if (entry.keyframeOffset !== reference.keyframeOffset) {
      found.error(
        `the delta index entry at ${entry.chunkOffset} declares keyframe_offset ` +
          `${entry.keyframeOffset}, but its reference chain reaches ` +
          `${reference.keyframeOffset}`,
      );
    }
    derived.set(entry.chunkOffset, {
      depth: expectedDepth,
      keyframeOffset: reference.keyframeOffset,
      kind: entry.kind,
    });
    previousOffset = entry.chunkOffset;
  }
}

/** Validate the fixed state-record chain when no Chunk Index duplicates that metadata. */
function checkKeyframeDeltaPhysicalChains(
  chunks: ReadonlyMap<
    number,
    {
      readonly opcode: number;
      readonly header: ChunkHeader | DeltaChunkHeader;
    }
  >,
  found: Findings,
  keyframeDelta: boolean,
): void {
  if (!keyframeDelta) return;
  const ordered = [...chunks.entries()].sort(([a], [b]) => a - b);
  const derived = new Map<number, { depth: number; keyframeOffset: number; kind: number }>();
  let previousOffset: number | null = null;
  for (const [offset, chunk] of ordered) {
    if (chunk.opcode === Opcode.Chunk) {
      derived.set(offset, { depth: 0, keyframeOffset: offset, kind: 0 });
      previousOffset = offset;
      continue;
    }

    const delta = chunk.header as DeltaChunkHeader;
    const reference = derived.get(delta.referenceOffset);
    if (reference === undefined) {
      found.error(
        `the Delta Chunk at ${offset} references ${delta.referenceOffset}, which is not an ` +
          "earlier physical state chunk",
      );
      previousOffset = offset;
      continue;
    }
    if (delta.deltaMode === DELTA_MODE_KEYFRAME && reference.kind !== 0) {
      found.error(
        `the keyframe-referenced Delta Chunk at ${offset} references ${delta.referenceOffset}, ` +
          "which is itself a delta",
      );
    } else if (delta.deltaMode === DELTA_MODE_CHAINED && previousOffset !== delta.referenceOffset) {
      found.error(
        `the chained Delta Chunk at ${offset} references ${delta.referenceOffset}; the ` +
          `immediately preceding state is at ${previousOffset}`,
      );
    } else if (delta.deltaMode !== DELTA_MODE_KEYFRAME && delta.deltaMode !== DELTA_MODE_CHAINED) {
      found.error(
        `the Delta Chunk at ${offset} declares delta_mode ${delta.deltaMode}; expected ` +
          `${DELTA_MODE_KEYFRAME} (keyframe) or ${DELTA_MODE_CHAINED} (chained)`,
      );
    }

    const expectedDepth = reference.depth + 1;
    if (delta.depth !== expectedDepth) {
      found.error(
        `the Delta Chunk at ${offset} declares depth ${delta.depth}, but its reference chain ` +
          `walks ${expectedDepth} delta chunks`,
      );
    }
    if (delta.keyframeOffset !== reference.keyframeOffset) {
      found.error(
        `the Delta Chunk at ${offset} declares keyframe_offset ${delta.keyframeOffset}, but ` +
          `its reference chain reaches ${reference.keyframeOffset}`,
      );
    }
    derived.set(offset, {
      depth: expectedDepth,
      keyframeOffset: reference.keyframeOffset,
      kind: 1,
    });
    previousOffset = offset;
  }
}

function finalizeDecodedShChunk(
  chunk: {
    readonly ordinal: number;
    readonly count: number;
    readonly bands: Map<number, Int32Array>;
    readonly decoded: boolean;
  } | null,
  degrees: Set<number>,
  found: Findings,
): void {
  if (chunk === null || !chunk.decoded) return;
  // An update-only or death-only delta has no born coefficients to infer a degree from.
  // It may therefore omit bands, but a band that is physically present still has to
  // assemble against birth_count=0 instead of disappearing behind that inference rule.
  if (chunk.count === 0 && chunk.bands.size === 0) return;
  try {
    // Keep only the scalar degree. The decoded coefficient arrays can be several times
    // larger than their compressed streams and must die with this chunk.
    const degree = mergeBands(chunk.count, chunk.bands, MAX_SH_DEGREE).degree;
    if (chunk.count > 0) degrees.add(degree);
  } catch (error) {
    found.error(`chunk ${chunk.ordinal} SH bands do not assemble: ${message(error)}`);
  }
}

/**
 * Decode gaussian-birth streams after a late Quantization record was discovered.
 *
 * The pass retains no Chunk bodies: each record is parsed, decoded, and released before
 * the next framing header is read. `knownChunks` also prevents a record that failed the
 * structural pass from producing the same parse finding twice.
 */
async function decodeGaussianBirthChunks(
  source: IReadable,
  size: number,
  header: Header,
  quantization: Quantization,
  windows: Float64Array,
  knownChunks: ReadonlyMap<number, unknown>,
  found: Findings,
): Promise<void> {
  const scanner = new FrontMatterScanner(source, size, VALIDATION_PROBE_BYTES);
  let ordinal = 0;
  try {
    for await (const framed of scanner.records(MAGIC.length)) {
      if (framed.opcode === Opcode.DeltaChunk) {
        ordinal += 1;
        continue;
      }
      if (framed.opcode !== Opcode.Chunk) continue;
      ordinal += 1;
      if (!knownChunks.has(framed.offset)) continue;
      try {
        const parsed = parseChunk(await scanner.content(framed));
        const bytes = await chunkStreamBytes(parsed, DEFAULT_CODECS);
        await decodeChunkStreams(bytes, parsed.header.count, {
          steps: stepsFrom(quantization),
          posOrigin: quantization.posOrigin,
          windows: windowTableOrDefault(windows),
          supportK: supportK(header.cutoff || DEFAULT_CUTOFF),
          codecs: DEFAULT_CODECS,
        });
      } catch (error) {
        found.error(`chunk ${ordinal} does not decode: ${message(error)}`);
        found.refuse(error, framed.offset, "the Chunk record");
      }
    }
  } catch (error) {
    if (error instanceof RangeError) throw error;
    // The structural pass already names the framing problem. This sentence distinguishes
    // a failed second pass without turning a file verdict into an uncaught tool failure.
    found.error(`stopped deferred chunk decoding: ${message(error)}`);
  }
}

function bandRangeKey(range: PhysicalBandRange): string {
  return `${range.band}:${range.offset}:${range.length}`;
}

function rangeCounts(ranges: readonly PhysicalBandRange[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const range of ranges) {
    const key = bandRangeKey(range);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

/** Semantic provenance findings that parsing deliberately leaves to validators. */
function checkProvenance(
  provenance: Provenance,
  emptyTrajectories: readonly string[],
  found: Findings,
): void {
  for (const frame of provenance.frames) {
    const where = `CoordinateFrame ${JSON.stringify(frame.name)}`;
    if (frame.handedness !== 0 && frame.handedness !== 1 && frame.handedness !== 2) {
      found.warn(`${where} handedness ${frame.handedness} is not in the registry`);
    }
    if (frame.lengthUnit !== 0 && !LENGTH_UNIT_METRES.has(frame.lengthUnit)) {
      found.warn(`${where} length_unit ${frame.lengthUnit} is not in the registry`);
    }
    const declared = LENGTH_UNIT_METRES.get(frame.lengthUnit);
    if (
      declared !== undefined &&
      frame.metresPerUnit > 0 &&
      Math.abs(frame.metresPerUnit - declared) > 1e-12 * Math.max(declared, 1)
    ) {
      found.error(
        `${where} declares length_unit ${frame.lengthUnit} (${declared} m per unit) and ` +
          `metres_per_unit ${frame.metresPerUnit}; a writer must make them agree. A consumer ` +
          "handed this file takes metres_per_unit (section 5.15.2)",
      );
    }
    if (frame.handedness === 0) {
      found.note(`${where} does not state a handedness, so a consumer cannot mirror-correct it`);
    }
  }

  for (const anchor of provenance.anchors) {
    if (anchor.latitudeDeg === 0 && anchor.longitudeDeg === 0) {
      found.warn(
        `a GeodeticAnchor for frame ${JSON.stringify(anchor.frameName)} sits at exactly ` +
          "(0, 0), which is far more often an unset field than a location in the Gulf of Guinea",
      );
    }
  }

  for (const sensor of provenance.sensors) {
    if (!CAMERA_MODEL_COEFFICIENTS.has(sensor.cameraModel)) {
      found.warn(
        `sensor ${JSON.stringify(sensor.name)} names camera model ${sensor.cameraModel}, which ` +
          "is not in the registry; a reader that cannot project with it must decline rather " +
          "than apply part of it (section 5.15.3)",
      );
    }
    if (
      sensor.cameraModel !== 0 &&
      (sensor.cx < 0 || sensor.cx > sensor.widthPx || sensor.cy < 0 || sensor.cy > sensor.heightPx)
    ) {
      found.warn(
        `sensor ${JSON.stringify(sensor.name)} has a principal point (${sensor.cx}, ` +
          `${sensor.cy}) outside its ${sensor.widthPx}x${sensor.heightPx} image`,
      );
    }
  }

  for (const name of emptyTrajectories) {
    found.warn(
      `trajectory ${JSON.stringify(name)} carries no samples; it is read as though absent ` +
        "and should have been omitted (section 5.15.4)",
    );
  }

  if (
    provenance.frames.length === 0 &&
    (provenance.sensors.length > 0 ||
      provenance.trajectories.length > 0 ||
      emptyTrajectories.length > 0)
  ) {
    found.note(
      "the file carries sensor or rig provenance but no CoordinateFrame record, so the frame " +
        "those poses are expressed in is whatever the consumer assumes",
    );
  }
}

/**
 * Every step and origin must be finite (spec §5.3).
 *
 * A non-finite step is the one corrupt field that ruins every gaussian rather than one:
 * each bin multiplied by it decodes to infinity or NaN, so the whole scene comes out with
 * no position to occupy. Nothing downstream complains — dequantization is arithmetic and
 * arithmetic on infinity is defined — so without this check the first symptom is a renderer
 * drawing an empty frame, which points at the renderer.
 */
function checkQuantizationFinite(quant: Quantization, found: Findings, ordinal: number): void {
  // Named when there is more than one, so the report points at the offending copy rather
  // than at "the" Quantization record.
  const where = ordinal === 0 ? "Quantization" : `Quantization record ${ordinal + 1}`;
  const fields: readonly (readonly [string, number])[] = [
    ["pos_origin[0]", quant.posOrigin[0] ?? Number.NaN],
    ["pos_origin[1]", quant.posOrigin[1] ?? Number.NaN],
    ["pos_origin[2]", quant.posOrigin[2] ?? Number.NaN],
    ["step_pos", quant.stepPos],
    ["step_scale_log", quant.stepScaleLog],
    ["step_rot", quant.stepRot],
    ["step_rgb", quant.stepRgb],
    ["step_alpha", quant.stepAlpha],
    ["step_motion", quant.stepMotion],
    ["step_time", quant.stepTime],
    ["step_sigma_log", quant.stepSigmaLog],
  ];
  for (const [name, value] of fields) {
    if (!Number.isFinite(value)) {
      found.error(
        `${where} ${name} is ${spell(value)}; every step and origin must be finite (§5.3)`,
      );
    }
  }
}

/**
 * The per-band SH bit depths, against the degree the Header declares (spec §6.5).
 *
 * The Python and Rust validators both make this check; until `parseQuantization` read the
 * appended field, this one could not, which is the whole of why it was missing. Only
 * checked when the file actually carries bands: appended fields are positional, so a
 * record that ends in bytes some other writer appended can parse as a depth list by
 * coincidence, and on a file with no coefficients that is a false alarm waiting to happen.
 */
function checkShBitDepths(quant: Quantization, shDegree: number, found: Findings): void {
  if (shDegree <= 0) return;
  if (quant.shBitDepthsMalformed) {
    found.error(
      "Quantization carries a malformed SH bit-depth declaration; the count must fit the " +
        "record and every depth must be in 3..8 (§5.3)",
    );
  }
  if (quant.shBitDepths.length === 0) return;
  if (quant.shBitDepths.length !== shDegree) {
    found.error(
      `Quantization declares ${quant.shBitDepths.length} SH bit depths; the Header declares ` +
        `degree ${shDegree}, and there is one band per degree (§6.5)`,
    );
  }
  const declared = quant.shBitDepths.slice(0, shDegree);
  declared.forEach((bits, i) => {
    const key = `sh_band${i + 1}`;
    const expected = shBound(bits);
    const value = quant.bounds.get(key);
    if (value === undefined) {
      found.warn(
        `Quantization declares ${bits} bits for SH band ${i + 1} but no \`${key}\` bound (§5.3)`,
      );
    } else if (!decimalEqualsInteger(value, expected)) {
      found.warn(
        `Quantization declares \`${key}\` as ${value}; ${bits} bits gives a bound of ` +
          `${expected} (§6.5)`,
      );
    }
  });
  const coarsest = Math.max(...declared.map(shStep));
  if (quant.stepSh !== coarsest) {
    found.warn(
      `Quantization step_sh is ${quant.stepSh}; the coarsest declared band has a pitch of ` +
        `${coarsest}, which is what a consumer that reads only step_sh has to be given (§6.5)`,
    );
  }
}

/**
 * The whole of the spelling §5.3 allows a `bounds` value: an optional sign, ASCII digits
 * with an optional point, and an optional exponent. Nothing surrounds it.
 *
 * Anchored with no `\s` at either end, and spelled `[0-9]` rather than `\d`, because both
 * shorthands drag in a language the format does not have: JavaScript's `\s` matches U+FEFF, so
 * a byte-order mark in front of a bound read as padding, while `\d` means ASCII only until
 * someone adds `/u` and it stops meaning that. The grammar should not turn on a flag.
 */
const BOUND = /^([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?$/;

/**
 * Whether the §5.3 bound `value` spells exactly the small non-negative integer `expected`.
 *
 * Matched against the grammar rather than handed to a runtime's number parser, so this agrees
 * with the Python, Rust and Dart validators on every input rather than on the ones their
 * runtimes happen to read alike. Digits are compared as digits: no exponent is too large to
 * read, and no value passes through binary64.
 */
function decimalEqualsInteger(value: string, expected: number): boolean {
  const match = BOUND.exec(value);
  if (match === null) return false;

  const integer = match[2] ?? "";
  let digits = integer + (match[3] ?? match[4] ?? "");
  const firstNonzero = digits.search(/[1-9]/);
  // A significand of zeroes is the value zero, at whatever exponent it carries.
  if (firstNonzero < 0) return expected === 0;
  if (match[1] === "-") return false;

  digits = digits.slice(firstNonzero).replace(/0+$/, "");
  const expectedDigits = String(expected);
  const requiredExponent = expectedDigits.length - integer.length + firstNonzero;
  return digits === expectedDigits && decimalIntegerEquals(match[5] ?? "0", requiredExponent);
}

/** Whether the signed digit string `value` is `expected`, without building the number. */
function decimalIntegerEquals(value: string, expected: number): boolean {
  const negative = value.startsWith("-");
  const digits = value.replace(/^[+-]?0*/, "");
  if (digits === "") return expected === 0;
  if (negative !== expected < 0) return false;
  return digits === String(Math.abs(expected));
}

/**
 * The summary is exactly the Chunk Index, Statistics and Summary Offset records, as one
 * contiguous run (spec §4.5).
 *
 * The checksum above proves the bytes in the range are the bytes the writer checksummed;
 * it says nothing about what they are. A Chunk or an Attachment inside the run passes it
 * with a recomputed CRC — and then a streamed reader, which retains the trailing run of
 * summary records precisely because §4.5 promises it is one, has retained the wrong bytes,
 * while a seeking reader trusts this range to contain only bounded index metadata.
 */
async function checkSummaryComposition(
  source: IReadable,
  size: number,
  start: number,
  end: number,
  found: Findings,
): Promise<void> {
  let at = start;
  while (at < end) {
    const framed = await recordAt(source, size, at);
    const length = framed?.totalLength ?? null;
    if (length === null || at + length > end) {
      found.error(
        `the summary at ${start} is not a whole run of records; the one at ${at} does not ` +
          `frame inside it (§4.5)`,
      );
      return;
    }
    if (!SUMMARY_OPCODES.has(framed!.opcode)) {
      found.error(
        `the summary carries a ${opcodeName(framed!.opcode)} record at ${at}; the summary is ` +
          `exactly the Chunk Index, Statistics and Summary Offset records (§4.5)`,
      );
      return;
    }
    at += length;
  }
}

/** The three records §4.5 admits into the summary. */
const SUMMARY_OPCODES: ReadonlySet<number> = new Set<number>([
  Opcode.ChunkIndex,
  Opcode.Statistics,
  Opcode.SummaryOffset,
]);

/**
 * The whole length of the record framed at `offset` — header included — or `null` when
 * the bytes there do not frame one inside the file.
 */
async function recordAt(
  source: IReadable,
  size: number,
  offset: number,
): Promise<FrontMatterRecord | null> {
  if (offset + RECORD_HEADER_BYTES > size) return null;
  let contentLength: number;
  let opcode: number;
  try {
    const cursor = new Cursor(
      await source.read(BigInt(offset), BigInt(RECORD_HEADER_BYTES)),
      0,
      offset,
    );
    opcode = cursor.u8();
    contentLength = cursor.u64();
  } catch {
    return null;
  }
  const total = contentLength + RECORD_HEADER_BYTES;
  if (!Number.isSafeInteger(offset + total) || offset + total > size) return null;
  return { opcode, offset, contentLength, totalLength: total };
}

/** Run a record parser, turning a refusal into a finding rather than an abort. */
async function parseInto(
  found: Findings,
  record: string,
  offset: number,
  parse: () => void | Promise<void>,
): Promise<void> {
  try {
    await parse();
  } catch (error) {
    if (error instanceof RangeError) throw error;
    found.error(`${record} record at byte ${offset} does not parse: ${message(error)}`);
  }
}

async function crcRange(source: IReadable, start: number, end: number): Promise<number> {
  const crc = new Crc32();
  for (let at = start; at < end; at += VALIDATION_PROBE_BYTES) {
    crc.update(await source.read(BigInt(at), BigInt(Math.min(VALIDATION_PROBE_BYTES, end - at))));
  }
  return crc.digest();
}

async function parseAudioDataRecord(
  source: IReadable,
  record: FrontMatterRecord,
): Promise<{ readonly sourceId: number; readonly dataLength: number }> {
  let at = record.offset + RECORD_HEADER_BYTES;
  const end = at + record.contentLength;
  const idBytes = await fixedRecordBytes(source, at, 4, end, "Audio Data source_id");
  const sourceId = new Cursor(idBytes, 0, at).u32();
  at += 4;
  const lengthBytes = await fixedRecordBytes(source, at, 8, end, "Audio Data payload length");
  const dataLength = new Cursor(lengthBytes, 0, at).u64();
  at += 8;
  if (at + dataLength > end) {
    throw new Error(
      `Audio Data id ${sourceId} declares ${dataLength} payload bytes at ${at}, only ` +
        `${end - at} remain in the record`,
    );
  }
  return { sourceId, dataLength };
}

/** Parse a Chunk's fixed fields and blob framing without fetching its stream payload. */
async function parseChunkRecordHeader(
  source: IReadable,
  record: FrontMatterRecord,
): Promise<ChunkHeader> {
  let at = record.offset + RECORD_HEADER_BYTES;
  const end = at + record.contentLength;
  const fixed = new Cursor(
    await fixedRecordBytes(source, at, 24, end, "Chunk fixed fields"),
    0,
    at,
  );
  const t0 = fixed.f64();
  const t1 = fixed.f64();
  const level = fixed.u32();
  const count = fixed.u32();
  at += 24;
  const named = await boundedStringAt(source, at, end, "Chunk compression");
  at = named.after;
  const uncompressed = new Cursor(
    await fixedRecordBytes(source, at, 8, end, "Chunk uncompressed_size"),
    0,
    at,
  ).u64();
  at += 8;
  await validateBlobAt(source, at, end, "Chunk streams");
  return { t0, t1, level, count, compression: named.value, uncompressedSize: uncompressed };
}

/** Parse a Delta Chunk's fixed fields and blob framing without fetching its records payload. */
async function parseDeltaChunkRecordHeader(
  source: IReadable,
  record: FrontMatterRecord,
): Promise<DeltaChunkHeader> {
  let at = record.offset + RECORD_HEADER_BYTES;
  const end = at + record.contentLength;
  const fixed = new Cursor(
    await fixedRecordBytes(source, at, 51, end, "Delta Chunk fixed fields"),
    0,
    at,
  );
  const header = {
    t0: fixed.f64(),
    t1: fixed.f64(),
    level: fixed.u32(),
    deltaMode: fixed.u8(),
    referenceOffset: fixed.u64(),
    keyframeOffset: fixed.u64(),
    depth: fixed.u16(),
    updateCount: fixed.u32(),
    birthCount: fixed.u32(),
    deathCount: fixed.u32(),
  };
  at += 51;
  const named = await boundedStringAt(source, at, end, "Delta Chunk compression");
  at = named.after;
  const uncompressed = new Cursor(
    await fixedRecordBytes(source, at, 8, end, "Delta Chunk uncompressed_size"),
    0,
    at,
  ).u64();
  at += 8;
  await validateBlobAt(source, at, end, "Delta Chunk records");
  return { ...header, compression: named.value, uncompressedSize: uncompressed };
}

async function boundedStringAt(
  source: IReadable,
  at: number,
  end: number,
  field: string,
): Promise<{ readonly value: string; readonly after: number }> {
  const length = new Cursor(
    await fixedRecordBytes(source, at, 4, end, `${field} length`),
    0,
    at,
  ).u32();
  at += 4;
  if (length > VALIDATION_STRING_BYTES) {
    throw new RangeError(
      `${field} declares ${length} bytes, past this tool's ${VALIDATION_STRING_BYTES}-byte ` +
        "bounded-memory string limit; this is not a malformed-file verdict",
    );
  }
  const bytes = await fixedRecordBytes(source, at, length, end, field);
  let value: string;
  try {
    // `ignoreBOM: true` for the reason `Cursor` gives: a length-prefixed string's leading
    // U+FEFF is a character, not a preamble, and the default would drop it.
    value = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    throw new MalformedFile(`${field} at byte ${at} is not valid UTF-8`);
  }
  return { value, after: at + length };
}

async function validateBlobAt(
  source: IReadable,
  at: number,
  end: number,
  field: string,
): Promise<void> {
  const length = new Cursor(
    await fixedRecordBytes(source, at, 8, end, `${field} length`),
    0,
    at,
  ).u64();
  at += 8;
  if (!Number.isSafeInteger(at + length) || at + length > end) {
    throw new MalformedFile(
      `${field} at byte ${at} declares ${length} bytes, only ${end - at} remain in the record`,
    );
  }
}

/** Validate string/string/blob payload framing without ever reading the payload itself. */
async function validatePayloadRecord(
  source: IReadable,
  record: FrontMatterRecord,
  stringCount: number,
  fixedBytesAfterStrings: number,
): Promise<void> {
  let at = record.offset + RECORD_HEADER_BYTES;
  const end = at + record.contentLength;
  for (let i = 0; i < stringCount; i++) at = await validateStringAt(source, at, end);
  await fixedRecordBytes(source, at, fixedBytesAfterStrings, end, "fixed payload fields");
  at += fixedBytesAfterStrings;
  const lengthBytes = await fixedRecordBytes(source, at, 8, end, "payload length");
  const payloadLength = new Cursor(lengthBytes, 0, at).u64();
  at += 8;
  if (at + payloadLength > end) {
    throw new Error(
      `payload at byte ${at} declares ${payloadLength} bytes, only ${end - at} remain in ` +
        `the ${opcodeName(record.opcode)} record`,
    );
  }
}

async function validateStringAt(source: IReadable, at: number, end: number): Promise<number> {
  const lengthBytes = await fixedRecordBytes(source, at, 4, end, "string length");
  const length = new Cursor(lengthBytes, 0, at).u32();
  at += 4;
  if (at + length > end) {
    throw new Error(`string at byte ${at} declares ${length} bytes, only ${end - at} remain`);
  }
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  try {
    for (let readAt = at; readAt < at + length; readAt += VALIDATION_PROBE_BYTES) {
      decoder.decode(
        await source.read(
          BigInt(readAt),
          BigInt(Math.min(VALIDATION_PROBE_BYTES, at + length - readAt)),
        ),
        { stream: true },
      );
    }
    decoder.decode();
  } catch {
    throw new Error(`string at byte ${at} is not valid UTF-8`);
  }
  return at + length;
}

async function fixedRecordBytes(
  source: IReadable,
  at: number,
  length: number,
  end: number,
  field: string,
): Promise<Uint8Array> {
  if (at + length > end) {
    throw new Error(`${field} needs ${length} bytes at ${at}, only ${end - at} remain`);
  }
  return source.read(BigInt(at), BigInt(length));
}

/**
 * A non-finite value spelled the way the other validators spell it.
 *
 * JavaScript writes `Infinity` and `NaN` where Python writes `inf` and `nan`, and a report
 * a caller diffs between two tools is a report where that is a difference.
 */
function spell(value: number): string {
  if (Number.isNaN(value)) return "nan";
  if (value === Number.POSITIVE_INFINITY) return "inf";
  if (value === Number.NEGATIVE_INFINITY) return "-inf";
  return String(value);
}

/**
 * The opcodes the specification defines. Everything else is either the application range or
 * a record from a version this build does not implement, and both are skipped rather than
 * refused — with a note, because a reader silently dropping records is how a file loses
 * half its meaning without anybody noticing.
 */
const TOP_LEVEL_OPCODES: ReadonlySet<number> = new Set<number>([
  Opcode.Header,
  Opcode.Footer,
  Opcode.Quantization,
  Opcode.WindowTable,
  Opcode.Chunk,
  Opcode.ShBandStream,
  Opcode.ChunkIndex,
  Opcode.Camera,
  Opcode.Audio,
  Opcode.Metadata,
  Opcode.Attachment,
  Opcode.Statistics,
  Opcode.SummaryOffset,
  Opcode.AudioSource,
  Opcode.AudioData,
  Opcode.DeltaChunk,
  Opcode.CoordinateFrame,
  Opcode.SensorCalibration,
  Opcode.RigTrajectory,
  Opcode.GeodeticAnchor,
  Opcode.ObjectTable,
  Opcode.ObjectTrack,
]);

const ILLEGAL_TOP_LEVEL_OPCODES: ReadonlySet<number> = new Set<number>([
  0,
  Opcode.AttributeStream,
  Opcode.AttachmentIndex,
]);

const VALIDATION_PROBE_BYTES = 64 * 1024;
const VALIDATION_STRING_BYTES = 4096;
/** Tool resource policy: cross-record tables never grow past this many rows. */
const MAX_VALIDATION_RECORDS = 65_536;

function hex(opcode: number): string {
  return `0x${opcode.toString(16).padStart(2, "0").toUpperCase()}`;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function report(found: Findings): Report {
  // A named refusal is a failure whether or not a check also wrote a sentence about it: the
  // refusal table is the list of things a reader will not read, and printing `refused: …`
  // above the word `valid` would be the tool contradicting itself in four lines.
  const ok = found.refused === null && !found.items.some((f) => f.severity === "error");
  return {
    findings: found.items,
    refused: found.refused,
    ok,
    warned: ok && found.items.some((f) => f.severity === "warning"),
  };
}
