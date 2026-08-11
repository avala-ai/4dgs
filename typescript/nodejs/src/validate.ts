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
 * The whole file is held in memory here, which no decode path in this package does. A
 * validator is not a decode path: the summary checksum covers a byte range, the index
 * points into one, and "is this file self-consistent" is a question about all of it at
 * once. The Python and Rust validators read the file the same way, for the same reason.
 */

import {
  BytesReadable,
  CAMERA_MODEL_COEFFICIENTS,
  Crc32,
  Cursor,
  DEFAULT_CODECS,
  DEFAULT_CUTOFF,
  FOOTER_TAIL_BYTES,
  FourdgsError,
  HEADER_FLAG_CHUNKS_COMPRESSED,
  HEADER_FLAG_HAS_AUDIO,
  IndexedDecoder,
  LENGTH_UNIT_METRES,
  MAGIC,
  MAX_SH_DEGREE,
  ObjectLayer,
  Opcode,
  Provenance,
  RECORD_HEADER_BYTES,
  bytesEqual,
  checkMagic,
  checkQuantizationScheme,
  checkTemporalModel,
  chunkStreamBytes,
  decodeChunkStreams,
  decodeStream,
  frameOneStream,
  isPrivateOpcode,
  isProvenanceOpcode,
  iterateRecords,
  mergeBands,
  opcodeName,
  parseAudioData,
  parseAudioSource,
  parseChunk,
  parseChunkIndexEntry,
  parseCoordinateFrame,
  parseFooter,
  parseGeodeticAnchor,
  parseHeader,
  parseObjectTable,
  parseObjectTrack,
  parseQuantization,
  parseRigTrajectory,
  parseSensorCalibration,
  parseShBandRecord,
  parseWindowTable,
  shBound,
  shStep,
  stepsFrom,
  supportK,
  windowTableOrDefault,
  type AudioSourceDescriptor,
  type ChunkIndexEntry,
  type Footer,
  type Header,
  type Quantization,
  type RefusalCode,
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

  /** The first refusal in file order wins; a later one is a consequence of it. */
  refuse(error: unknown, at: number, where: string): void {
    if (this.refused !== null) return;
    if (!(error instanceof FourdgsError) || error.refusalCode === undefined) return;
    this.refused = { code: error.refusalCode, message: error.message, at, where };
  }
}

/** Every check, in the Python validator's order. */
export async function validateFile(
  data: Uint8Array,
  options: ValidateOptions = {},
): Promise<Report> {
  const found = new Findings();
  try {
    checkMagic(data);
  } catch (error) {
    found.error(message(error));
    found.refuse(error, 0, "the file magic");
    return report(found);
  }

  if (!bytesEqual(data.subarray(data.length - MAGIC.length), MAGIC)) {
    found.error(
      "file does not end with the magic; it is truncated or was written by a broken encoder",
    );
  }

  const seen: number[] = [];
  const topLevelOffsets = new Set<number>();
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let quantizationCount = 0;
  let windows: Float64Array | null = null;
  let footer: Footer | null = null;
  let chunkCount = 0;
  let counted = 0;
  const index: ChunkIndexEntry[] = [];
  let firstIndexOffset: number | null = null;
  const physicalChunkOffsets: number[] = [];
  const physicalBands = new Map<
    number,
    { readonly band: number; readonly offset: number; readonly length: number }[]
  >();
  let currentChunkOffset: number | null = null;
  const audioSources = new Map<number, AudioSourceDescriptor>();
  const audioData = new Map<number, number>();
  const provenance = new Provenance();
  const emptyTrajectories: string[] = [];
  const objects = new ObjectLayer();
  let firstChunkSeen = false;
  const decodedShChunks: {
    readonly count: number;
    readonly bands: Map<number, Int32Array>;
    decoded: boolean;
  }[] = [];

  try {
    for (const record of iterateRecords(data, MAGIC.length)) {
      seen.push(record.opcode);
      const { content, offset } = record;
      topLevelOffsets.add(offset);
      // An SH Band Stream belongs only to the Chunk immediately before the run of band
      // records. Any other top-level record ends that run.
      if (record.opcode !== Opcode.Chunk && record.opcode !== Opcode.ShBandStream) {
        currentChunkOffset = null;
      }
      // A record whose own body will not parse is a finding rather than an abort: the point
      // of a validator is to say everything that is wrong with a file, not the first thing.
      switch (record.opcode) {
        case Opcode.Header:
          try {
            header = parseHeader(content);
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
            checkTemporalModel(header.temporalModel);
          } catch (error) {
            found.refuse(error, offset, "the Header record");
          }
          if (header.shDegree > MAX_SH_DEGREE) {
            found.error(
              `Header sh_degree is ${header.shDegree}; the attribute registry defines only ` +
                `degrees 0-${MAX_SH_DEGREE} (§5.1)`,
            );
          }
          break;
        case Opcode.Quantization:
          try {
            quantization = parseQuantization(content);
          } catch (error) {
            found.error(`Quantization does not parse: ${message(error)}`);
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
            windows = parseWindowTable(content);
          } catch (error) {
            windows = null;
            if (options.decode === true) {
              found.error(`Window Table does not parse: ${message(error)}`);
            }
          }
          break;
        case Opcode.Chunk: {
          physicalChunkOffsets.push(offset);
          physicalBands.set(offset, []);
          currentChunkOffset = offset;
          firstChunkSeen = true;
          chunkCount += 1;
          let parsed;
          try {
            parsed = parseChunk(content);
          } catch (error) {
            found.error(`chunk ${chunkCount} does not parse: ${message(error)}`);
            break;
          }
          counted += parsed.header.count;
          const decodedShChunk = {
            count: parsed.header.count,
            bands: new Map<number, Int32Array>(),
            decoded: false,
          };
          if (options.decode === true) decodedShChunks.push(decodedShChunk);
          if (parsed.header.t1 < parsed.header.t0) {
            found.error(
              `chunk ${chunkCount} has t1 (${parsed.header.t1}) before t0 (${parsed.header.t0})`,
            );
          }
          if (options.decode === true && header !== null && quantization !== null) {
            try {
              const bytes = await chunkStreamBytes(parsed, DEFAULT_CODECS);
              await decodeChunkStreams(bytes, parsed.header.count, {
                steps: stepsFrom(quantization),
                posOrigin: quantization.posOrigin,
                windows: windowTableOrDefault(windows ?? new Float64Array(0)),
                supportK: supportK(header.cutoff || DEFAULT_CUTOFF),
                codecs: DEFAULT_CODECS,
              });
              decodedShChunk.decoded = true;
            } catch (error) {
              found.error(`chunk ${chunkCount} does not decode: ${message(error)}`);
              found.refuse(error, offset, "the Chunk record");
            }
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
          try {
            const parsedBand = parseShBandRecord(content);
            band = parsedBand.band;
            if (band < 1 || band > MAX_SH_DEGREE) {
              found.error(
                `SH Band Stream at byte ${offset} declares band ${band}; the registry defines ` +
                  `bands 1-${MAX_SH_DEGREE} (§5.7)`,
              );
            }
            if (currentChunkOffset === null) {
              found.error(
                `SH Band Stream at byte ${offset} does not immediately follow a Chunk or one of ` +
                  "that Chunk's SH Band Stream records",
              );
            } else {
              physicalBands.get(currentChunkOffset)!.push({
                band,
                offset,
                length: record.length,
              });
            }
            if (options.decode !== true || decodedShChunks.length === 0) break;
            if (band < 1 || band > MAX_SH_DEGREE) break;
            const values = await decodeStream(frameOneStream(parsedBand.cursor), DEFAULT_CODECS);
            decodedShChunks[decodedShChunks.length - 1]!.bands.set(band, values);
          } catch (error) {
            found.error(`chunk ${chunkCount} SH band ${band} does not decode: ${message(error)}`);
            found.refuse(error, offset, "the SH Band Stream record");
          }
          break;
        }
        case Opcode.ChunkIndex:
          firstIndexOffset ??= offset;
          try {
            index.push(parseChunkIndexEntry(content));
          } catch (error) {
            found.error(`a chunk index entry does not parse: ${message(error)}`);
          }
          break;
        case Opcode.Footer:
          try {
            footer = parseFooter(content);
          } catch (error) {
            found.error(`Footer does not parse: ${message(error)}`);
          }
          break;
        case Opcode.AudioSource: {
          let source;
          try {
            source = parseAudioSource(content);
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
            payload = parseAudioData(content);
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
          audioData.set(payload.sourceId, payload.data.length);
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
          parseInto(found, "CoordinateFrame", () => {
            provenance.frames.push(parseCoordinateFrame(content));
          });
          break;
        case Opcode.SensorCalibration:
          parseInto(found, "SensorCalibration", () => {
            provenance.sensors.push(parseSensorCalibration(content));
          });
          break;
        case Opcode.RigTrajectory:
          parseInto(found, "RigTrajectory", () => {
            const trajectory = parseRigTrajectory(content);
            // §5.15.4 reads a zero-sample trajectory as absent. In
            // particular, it neither collides with another absent record nor
            // shadows a later, real trajectory with the same name.
            if (trajectory.times.length > 0) provenance.trajectories.push(trajectory);
            else emptyTrajectories.push(trajectory.name);
          });
          break;
        case Opcode.GeodeticAnchor:
          parseInto(found, "GeodeticAnchor", () => {
            provenance.anchors.push(parseGeodeticAnchor(content));
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
          parseInto(found, "ObjectTable", () => {
            objects.table = parseObjectTable(content);
          });
          break;
        case Opcode.ObjectTrack:
          parseInto(found, "ObjectTrack", () => {
            const track = parseObjectTrack(content);
            // §5.15.7 reads a zero-sample track as absent. In particular, two
            // absent records for one id are not two active tracks.
            if (track.times.length > 0) objects.tracks.push(track);
          });
          break;
        default:
          if (isPrivateOpcode(record.opcode)) {
            found.note(
              `private record ${hex(record.opcode)} (${content.length} bytes) — skipped, as required`,
            );
          } else if (SPECIFIED.has(record.opcode)) {
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
    found.error(`stopped reading: ${message(error)}`);
  }

  // Decoding each SH stream proves only its framing and codec. The decoded values become
  // gaussian state only after the bands are assembled, and that step enforces the semantic
  // invariants a normal streamed read enforces: whole degrees starting at band 1, the
  // coefficient count for this chunk, values in the stored u8 range, and one scene-wide
  // degree shared by every chunk.
  if (options.decode === true) {
    const degrees: number[] = [];
    decodedShChunks.forEach((chunk, i) => {
      if (!chunk.decoded) return;
      try {
        const degree = mergeBands(chunk.count, chunk.bands, MAX_SH_DEGREE).degree;
        degrees.push(degree);
      } catch (error) {
        found.error(`chunk ${i + 1} SH bands do not assemble: ${message(error)}`);
      }
    });
    if (
      degrees.length === decodedShChunks.filter((chunk) => chunk.decoded).length &&
      new Set(degrees).size > 1
    ) {
      found.error(`chunks disagree on SH degree: ${[...new Set(degrees)].join(", ")}`);
    }
    if (header !== null && degrees.some((degree) => degree !== header!.shDegree)) {
      found.error(
        `chunks assemble SH degree ${[...new Set(degrees)].join(", ")}; the Header ` +
          `declares degree ${header.shDegree} (§6.5)`,
      );
    }
  }

  if (seen.length === 0) {
    found.error("no records at all");
    return report(found);
  }
  if (seen[0] !== Opcode.Header) {
    found.error(`first record is ${opcodeName(seen[0]!)}; the Header must come first`);
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
  if (footer !== null && seen.at(-1) !== Opcode.Footer) {
    found.error(
      `the last record is ${opcodeName(seen.at(-1)!)}; the Footer must be the last record (§4)`,
    );
  }
  const earlyFooter = seen.slice(0, -1).indexOf(Opcode.Footer);
  if (earlyFooter >= 0) {
    found.error(
      `Footer record ${earlyFooter + 1} is followed by another record; every Footer must be ` +
        "the last record (§4)",
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
    if (counted !== header.gaussianCount) {
      found.error(`Header declares ${header.gaussianCount} gaussians; chunks contain ${counted}`);
    }
    const hasAudioRecords =
      seen.includes(Opcode.Audio) || audioSources.size > 0 || audioData.size > 0;
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
  if (seen.includes(Opcode.Audio) && audioSources.size > 0) {
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
    if (!Number.isSafeInteger(chunkEnd) || chunkEnd > data.length) {
      found.error(`chunk index entry ${i} points past the end of the file`);
    } else if (!topLevelOffsets.has(entry.chunkOffset)) {
      found.error(
        `chunk index entry ${i} points at byte ${entry.chunkOffset}, which is not the start ` +
          `of a top-level record`,
      );
    } else if (data[entry.chunkOffset] !== Opcode.Chunk) {
      found.error(`chunk index entry ${i} does not point at a Chunk record`);
    } else {
      // §5.8: "Every offset and length here frames a whole record, opcode byte and
      // content length included, so a reader fetches `[offset, offset + length)` and
      // parses it exactly as it would parse that record mid-stream." An entry whose first
      // byte is right and whose length is not describes a range no reader can parse:
      // `IndexedDecoder.readChunk` range-reads exactly this many bytes before framing
      // them, so the seek path — a first-class read path, not an optimization (AGENTS.md
      // §2) — fails on a file the checks above call conforming.
      const framed = recordLengthAt(data, entry.chunkOffset);
      if (framed === null) {
        found.error(`chunk index entry ${i} does not frame a complete Chunk record`);
      } else if (framed !== entry.chunkLength) {
        found.error(
          `chunk index entry ${i} declares ${entry.chunkLength} bytes at ` +
            `${entry.chunkOffset}; the record there is ${framed} bytes (§5.8)`,
        );
      } else {
        try {
          const parsed = parseChunk(
            data.subarray(entry.chunkOffset + RECORD_HEADER_BYTES, entry.chunkOffset + framed),
          );
          if (parsed.header.count !== entry.gaussianCount) {
            found.error(
              `chunk index entry ${i} declares ${entry.gaussianCount} gaussians; the Chunk ` +
                `at ${entry.chunkOffset} contains ${parsed.header.count}`,
            );
          }
          if (!Object.is(parsed.header.t0, entry.t0) || !Object.is(parsed.header.t1, entry.t1)) {
            found.error(
              `chunk index entry ${i} declares interval [${entry.t0}, ${entry.t1}); the Chunk ` +
                `at ${entry.chunkOffset} declares [${parsed.header.t0}, ${parsed.header.t1})`,
            );
          }
        } catch (error) {
          found.error(
            `chunk index entry ${i} references a Chunk that does not parse: ${message(error)}`,
          );
        }
      }
    }

    entry.bands.forEach((band, j) => {
      const bandEnd = band.offset + band.length;
      const where = `chunk index entry ${i} SH band range ${j}`;
      if (!Number.isSafeInteger(bandEnd) || bandEnd > data.length) {
        found.error(`${where} points past the end of the file`);
        return;
      }
      if (!topLevelOffsets.has(band.offset)) {
        found.error(`${where} does not point at the start of a top-level record`);
        return;
      }
      if (data[band.offset] !== Opcode.ShBandStream) {
        found.error(`${where} does not point at an SH Band Stream record`);
        return;
      }
      const framed = recordLengthAt(data, band.offset);
      if (framed === null) {
        found.error(`${where} does not frame a complete SH Band Stream record`);
        return;
      }
      if (framed !== band.length) {
        found.error(
          `${where} declares ${band.length} bytes at ${band.offset}; the record there is ` +
            `${framed} bytes (§5.8)`,
        );
        return;
      }
      try {
        const parsed = parseShBandRecord(
          data.subarray(band.offset + RECORD_HEADER_BYTES, band.offset + framed),
        );
        if (parsed.band !== band.band) {
          found.error(
            `${where} says band ${band.band}; the record at ${band.offset} says band ` +
              `${parsed.band}`,
          );
        }
      } catch (error) {
        found.error(`${where} references a record that does not parse: ${message(error)}`);
      }
    });
  });

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
    const physicalChunks = new Set(physicalChunkOffsets);
    for (const [chunkOffset, count] of indexedCounts) {
      if (!physicalChunks.has(chunkOffset)) {
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
    const tail = data.length - FOOTER_TAIL_BYTES;
    if (footer.summaryStart > tail) {
      found.error(
        `the Footer's summary starts at ${footer.summaryStart}, after the summary ends at ${tail}`,
      );
    } else if (
      footer.summaryCrc !== 0 &&
      new Crc32().update(data.subarray(footer.summaryStart, tail)).digest() !== footer.summaryCrc
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
    checkSummaryComposition(data, footer.summaryStart, tail, found);
  }

  if (header !== null && index.length === 0) {
    found.warn("no chunk index: this file can only be read front to back, not seeked");
  }

  // Opening the file the way a seeking client would is itself a check.
  try {
    await IndexedDecoder.open(new BytesReadable(data));
  } catch (error) {
    found.error(`a seeking reader cannot open this file: ${message(error)}`);
  }

  return report(found);
}

interface PhysicalBandRange {
  readonly band: number;
  readonly offset: number;
  readonly length: number;
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
  if (quant.shBitDepths.length === 0 || shDegree <= 0) return;
  if (quant.shBitDepths.length !== shDegree) {
    found.error(
      `Quantization declares ${quant.shBitDepths.length} SH bit depths; the Header declares ` +
        `degree ${shDegree}, and there is one band per degree (§6.5)`,
    );
  }
  const declared = quant.shBitDepths.slice(0, shDegree);
  declared.forEach((bits, i) => {
    const key = `sh_band${i + 1}`;
    const expected = String(shBound(bits));
    const value = quant.bounds.get(key);
    if (value === undefined) {
      found.warn(
        `Quantization declares ${bits} bits for SH band ${i + 1} but no \`${key}\` bound (§5.3)`,
      );
    } else if (value !== expected) {
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
 * The summary is exactly the Chunk Index, Statistics and Summary Offset records, as one
 * contiguous run (spec §4.5).
 *
 * The checksum above proves the bytes in the range are the bytes the writer checksummed;
 * it says nothing about what they are. A Chunk or an Attachment inside the run passes it
 * with a recomputed CRC — and then a streamed reader, which retains the trailing run of
 * summary records precisely because §4.5 promises it is one, has retained the wrong bytes,
 * while `IndexedDecoder.open` reads the whole declared range in one allocation to find an
 * index inside it.
 */
function checkSummaryComposition(
  data: Uint8Array,
  start: number,
  end: number,
  found: Findings,
): void {
  let at = start;
  while (at < end) {
    const length = recordLengthAt(data, at);
    if (length === null || at + length > end) {
      found.error(
        `the summary at ${start} is not a whole run of records; the one at ${at} does not ` +
          `frame inside it (§4.5)`,
      );
      return;
    }
    if (!SUMMARY_OPCODES.has(data[at]!)) {
      found.error(
        `the summary carries a ${opcodeName(data[at]!)} record at ${at}; the summary is ` +
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
function recordLengthAt(data: Uint8Array, offset: number): number | null {
  if (offset + RECORD_HEADER_BYTES > data.length) return null;
  let contentLength: number;
  try {
    contentLength = new Cursor(data, offset + 1).u64();
  } catch {
    return null;
  }
  const total = contentLength + RECORD_HEADER_BYTES;
  if (!Number.isSafeInteger(offset + total) || offset + total > data.length) return null;
  return total;
}

/** Run a record parser, turning a refusal into a finding rather than an abort. */
function parseInto(found: Findings, record: string, parse: () => void): void {
  try {
    parse();
  } catch (error) {
    found.error(`${record} does not parse: ${message(error)}`);
  }
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
const SPECIFIED: ReadonlySet<number> = new Set<number>(Object.values(Opcode));

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
