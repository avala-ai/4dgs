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
  Crc32,
  DEFAULT_CODECS,
  DEFAULT_CUTOFF,
  FOOTER_TAIL_BYTES,
  FourdgsError,
  IndexedDecoder,
  MAGIC,
  Opcode,
  bytesEqual,
  checkMagic,
  checkQuantizationScheme,
  checkTemporalModel,
  chunkStreamBytes,
  decodeChunkStreams,
  isPrivateOpcode,
  isProvenanceOpcode,
  iterateRecords,
  opcodeName,
  parseAudioData,
  parseAudioSource,
  parseChunk,
  parseChunkIndexEntry,
  parseFooter,
  parseHeader,
  parseQuantization,
  parseWindowTable,
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
  let header: Header | null = null;
  let quantization: Quantization | null = null;
  let quantizationCount = 0;
  let windows: Float64Array | null = null;
  let footer: Footer | null = null;
  let chunkCount = 0;
  let counted = 0;
  const index: ChunkIndexEntry[] = [];
  const audioSources = new Map<number, AudioSourceDescriptor>();
  const audioData = new Map<number, number>();
  let firstChunkSeen = false;

  try {
    for (const record of iterateRecords(data, MAGIC.length)) {
      seen.push(record.opcode);
      const { content, offset } = record;
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
          try {
            checkTemporalModel(header.temporalModel);
          } catch (error) {
            found.refuse(error, offset, "the Header record");
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
          } catch {
            windows = null;
          }
          break;
        case Opcode.Chunk: {
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
            } catch (error) {
              found.error(`chunk ${chunkCount} does not decode: ${message(error)}`);
              found.refuse(error, offset, "the Chunk record");
            }
          }
          break;
        }
        case Opcode.ChunkIndex:
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

  // The one provenance finding a validator can reach without parsing a provenance record:
  // poses expressed in a frame the file never names. The rest of the Python validator's
  // provenance section — registry membership, a `metres_per_unit` that disagrees with its
  // declared unit, a principal point outside its image — needs the parsed records and is
  // not ported here, exactly as it is not ported to the Rust validator.
  if (
    !seen.includes(Opcode.CoordinateFrame) &&
    (seen.includes(Opcode.SensorCalibration) || seen.includes(Opcode.RigTrajectory))
  ) {
    found.note(
      "the file carries sensor or rig provenance but no CoordinateFrame record, so the frame " +
        "those poses are expressed in is whatever the consumer assumes",
    );
  }

  index.forEach((entry, i) => {
    if (entry.chunkOffset + entry.chunkLength > data.length) {
      found.error(`chunk index entry ${i} points past the end of the file`);
    } else if (data[entry.chunkOffset] !== Opcode.Chunk) {
      found.error(`chunk index entry ${i} does not point at a Chunk record`);
    }
  });

  if (footer !== null && footer.summaryCrc !== 0 && footer.summaryStart !== 0) {
    // The Footer record itself is not covered: nine bytes of framing plus its twenty bytes
    // of content plus the trailing magic.
    const tail = data.length - FOOTER_TAIL_BYTES;
    if (footer.summaryStart > tail) {
      found.error(
        `the Footer's summary starts at ${footer.summaryStart}, after the summary ends at ${tail}`,
      );
    } else if (
      new Crc32().update(data.subarray(footer.summaryStart, tail)).digest() !== footer.summaryCrc
    ) {
      found.error("summary CRC mismatch: the index is untrustworthy (a streamed read still works)");
    }
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
