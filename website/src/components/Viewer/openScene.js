/**
 * Opening a `.4dgs` and asking it for the gaussians alive at an instant.
 *
 * Everything here is `@4dgs/core` driving; there is no second parser on this page. The
 * only job of this module is to give the renderer one shape — a {@link Frame} — whichever
 * of the format's three read paths produced it:
 *
 * - **indexed** (`gaussian-birth`, file carries a Chunk Index): the Footer, then the
 *   index, then only the byte ranges whose `[t0, t1)` contains the instant on screen.
 *   This is the seek path the format exists for, and it is the default.
 * - **streamed** (`gaussian-birth`, no usable index): `decodeScene` walks the resource
 *   front to back in bounded reads. Also the fallback for a truncated file, whose Footer
 *   never arrived.
 * - **keyframe-delta**: composition, then reconstruction at the instant.
 *
 * All three take an `IReadable`, so a local `File` (`BlobReadable`) and a pasted URL
 * (`HttpRangeReadable`) are the same code from here down.
 */

import {
  DEFAULT_CUTOFF,
  IndexedDecoder,
  MAGIC,
  MalformedFile,
  Opcode,
  assembleGaussians,
  checkMagic,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  iterateRecords,
  parseHeader,
} from "@4dgs/core";

import { reconstructKeyframeDelta } from "./keyframeDelta.js";

/**
 * The gaussians alive at one instant, in the layout the renderer uploads.
 *
 * @typedef {object} Frame
 * @property {number} time scene time these values were reconstructed at
 * @property {number} count how many gaussians exist at that time
 * @property {Float32Array} centers `count × 3`
 * @property {Float32Array} scales `count × 3`, linear
 * @property {Float32Array} rotations `count × 4`, unit quaternion, xyzw
 * @property {Float32Array} colors `count × 4`, linear RGB plus opacity at this instant
 * @property {Uint8Array|null} sh `count × 3 × shCoefficients`, component-major, or null
 * @property {number} shCoefficients coefficients per colour component
 * @property {number} shDegree highest whole degree present
 */

/**
 * A file the viewer can play.
 *
 * @typedef {object} Playable
 * @property {"indexed"|"streamed"|"keyframe-delta"} readMode
 * @property {object} header the decoded Header record
 * @property {number} duration seconds; the timeline is the half-open `[0, duration)`
 * @property {(t: number) => Promise<Frame>} frameAt
 * @property {(t: number) => {t0: number, t1: number}[]} intervalsAt chunks covering `t`
 * @property {() => {bytes: number, reads: number, size: number}} transfer
 * @property {string[]} notes things worth saying about this particular file
 */

/** How much of the front is read to learn the temporal model, before anything is decoded. */
const HEADER_PROBE_BYTES = 64 * 1024;

/** Decoded chunks kept on the indexed path. Bounds the memory a long scrub can reach. */
const CHUNK_CACHE_LIMIT = 64;

/**
 * Counts what the transport actually moved.
 *
 * Only here so the page can show it: "opening this instant read 41 KiB of a 3.2 MiB file"
 * is the claim the byte-range index makes, and a viewer is in a position to prove it
 * rather than repeat it.
 */
class CountingReadable {
  constructor(inner) {
    this.inner = inner;
    this.bytes = 0;
    this.reads = 0;
    this.total = 0;
  }

  async size() {
    const size = await this.inner.size();
    this.total = Number(size);
    return size;
  }

  async read(offset, length) {
    const bytes = await this.inner.read(offset, length);
    this.bytes += bytes.byteLength;
    this.reads += 1;
    return bytes;
  }
}

/**
 * Open a resource and return something the transport control can play.
 *
 * Refusals are not caught here. A decoder that names the byte, the record and the value is
 * the most useful thing this page has to say about a file that will not open, and wrapping
 * it in "could not open this file" would throw that away.
 */
export async function openScene(source) {
  const counting = new CountingReadable(source);
  const size = Number(await counting.size());
  try {
    return await openGaussianBirth(counting);
  } catch (refusal) {
    // `decodeScene` and `IndexedDecoder` implement `gaussian-birth`, and they refuse
    // anything else by name. A `keyframe-delta` file lands here, so the Header is read
    // only once that refusal has happened — which keeps the common case to a single pass
    // over the front matter rather than a probe and then a pass.
    if ((await temporalModelOf(counting, size)) !== "keyframe-delta") throw refusal;
    return await openKeyframeDelta(counting, size);
  }
}

/**
 * The Header's temporal model, from a bounded read of the front.
 *
 * `null` when the probe did not reach a Header, or when it could not be read at all — a
 * short or malformed file, whose real refusal the caller is already holding.
 */
async function temporalModelOf(source, size) {
  try {
    const probe = await source.read(0n, BigInt(Math.min(size, HEADER_PROBE_BYTES)));
    checkMagic(probe);
    for (const record of iterateRecords(probe, MAGIC.length)) {
      if (record.opcode === Opcode.Header) return parseHeader(record.content).temporalModel;
    }
  } catch {
    return null;
  }
  return null;
}

// --------------------------------------------------------------------------
// gaussian-birth
// --------------------------------------------------------------------------

async function openGaussianBirth(source) {
  const notes = [];
  try {
    const decoder = await IndexedDecoder.open(source);
    if (decoder.index.length > 0) return indexedPlayable(decoder, source, notes);
    notes.push("The file carries no Chunk Index, so it is read front to back instead of seeked.");
  } catch (error) {
    // An index that cannot be read is a reason to read the file the other way, not a
    // reason to refuse it: a file cut before its Footer has no index and still decodes.
    // If the streamed path refuses too, its diagnosis is the one that surfaces.
    notes.push(`The indexed read path was not usable: ${error.message}`);
  }
  const scene = await decodeScene(source);
  return streamedPlayable(scene, source, notes);
}

function cutoffOf(header) {
  return header.cutoff > 0 ? header.cutoff : DEFAULT_CUTOFF;
}

/** Seeked reads: for each instant, only the chunks whose `[t0, t1)` contains it. */
function indexedPlayable(decoder, source, notes) {
  const { header } = decoder;
  const cutoff = cutoffOf(header);
  const chunks = new Map();
  let assembled = { key: null, set: null };

  async function setFor(t) {
    // The normative seek rule, and the whole of it. `chunksForTime` is `t0 <= t < t1`.
    const entries = decoder.chunksForTime(t);
    const key = entries.map((entry) => entry.chunkOffset).join(",");
    if (assembled.key === key) return assembled.set;

    const decoded = [];
    for (const entry of entries) {
      let chunk = chunks.get(entry.chunkOffset);
      if (chunk === undefined) {
        chunk = await decoder.readChunk(entry, { maxShBand: header.shDegree });
        chunks.set(entry.chunkOffset, chunk);
        if (chunks.size > CHUNK_CACHE_LIMIT) chunks.delete(chunks.keys().next().value);
      }
      decoded.push(chunk);
    }
    const set = assembleGaussians(
      decoded.map((chunk) => chunk.gaussians),
      decoder.windows,
      header.shDegree,
      concatSh(decoded),
    );
    assembled = { key, set };
    return set;
  }

  if (decoder.summaryCrcOk === false) {
    notes.push("The Footer's summary CRC does not match the index it covers.");
  }
  return {
    readMode: "indexed",
    header,
    duration: header.durationSec,
    frameAt: async (t) => frameFromSet(await setFor(t), t, cutoff),
    intervalsAt: (t) => decoder.chunksForTime(t).map(({ t0, t1 }) => ({ t0, t1 })),
    transfer: () => transferOf(source),
    notes,
  };
}

/** Front to back: the whole scene decoded once, then reconstructed at each instant. */
function streamedPlayable(scene, source, notes) {
  const cutoff = cutoffOf(scene.header);
  if (scene.truncated) {
    notes.push("The resource ended before the file did. Everything decoded before the cut stands.");
  }
  if (scene.skippedOpcodes.length > 0) {
    const seen = [...new Set(scene.skippedOpcodes)].map((code) => `0x${code.toString(16)}`);
    notes.push(`Records skipped by length, unrecognized by this reader: ${seen.join(", ")}.`);
  }
  return {
    readMode: "streamed",
    header: scene.header,
    duration: scene.header.durationSec,
    frameAt: async (t) => frameFromSet(scene.gaussians, t, cutoff),
    intervalsAt: (t) =>
      scene.chunkIndex.filter((e) => e.t0 <= t && t < e.t1).map(({ t0, t1 }) => ({ t0, t1 })),
    transfer: () => transferOf(source),
    notes,
  };
}

/**
 * A {@link Frame} from a decoded population.
 *
 * `stateAt` is where the format's decoding ends: it applies the validity window as a hard
 * gate, drops anything whose marginal has fallen under the file's own cutoff, and moves
 * what is left along its velocity. Everything after this line is drawing.
 */
function frameFromSet(set, t, cutoff) {
  const state = set.stateAt(t, cutoff);
  const count = state.indices.length;
  const scales = new Float32Array(count * 3);
  const colors = new Float32Array(count * 4);
  const coefficients = set.sh === null ? 0 : set.sh.coefficients;
  const sh = coefficients === 0 ? null : new Uint8Array(count * 3 * coefficients);

  for (let k = 0; k < count; k++) {
    const i = state.indices[k];
    scales[k * 3] = set.scales[i * 3];
    scales[k * 3 + 1] = set.scales[i * 3 + 1];
    scales[k * 3 + 2] = set.scales[i * 3 + 2];
    colors[k * 4] = set.colors[i * 4];
    colors[k * 4 + 1] = set.colors[i * 4 + 1];
    colors[k * 4 + 2] = set.colors[i * 4 + 2];
    // The temporal marginal is already folded into `opacity` by `stateAt`.
    colors[k * 4 + 3] = state.opacity[k];
    if (sh !== null) {
      const width = 3 * coefficients;
      sh.set(set.sh.values.subarray(i * width, i * width + width), k * width);
    }
  }

  return {
    time: t,
    count,
    centers: state.centers,
    scales,
    rotations: state.orientations,
    colors,
    sh,
    shCoefficients: coefficients,
    shDegree: set.sh === null ? 0 : set.sh.degree,
  };
}

/**
 * Concatenate several chunks' spherical harmonics into one population-wide block.
 *
 * Each chunk merges its own bands, so the only thing left to do is lay the per-gaussian
 * blocks end to end in the same order `assembleGaussians` lays out everything else.
 */
function concatSh(chunks) {
  const withBands = chunks.filter((chunk) => chunk.sh !== null && chunk.sh.degree > 0);
  if (withBands.length === 0) return null;
  const degrees = new Set(withBands.map((chunk) => chunk.sh.degree));
  if (withBands.length !== chunks.length || degrees.size > 1) {
    throw new MalformedFile(
      `chunks covering this instant disagree on SH degree: ${[...degrees].join(", ")}`,
    );
  }
  const { degree, coefficients } = withBands[0].sh;
  const width = 3 * coefficients;
  let count = 0;
  for (const chunk of chunks) count += chunk.gaussians.count;
  const values = new Uint8Array(count * width);
  let at = 0;
  for (const chunk of chunks) {
    values.set(chunk.sh.values, at * width);
    at += chunk.gaussians.count;
  }
  return { degree, coefficients, count, values, bands: withBands[0].sh.bands };
}

// --------------------------------------------------------------------------
// keyframe-delta
// --------------------------------------------------------------------------

/**
 * The `keyframe-delta` model, composed front to back.
 *
 * This path is the one exception to the bounded-memory reading above: `@4dgs/core`
 * composes a `keyframe-delta` file from a byte array rather than from an `IReadable`, so
 * the whole resource is read before anything is composed. The page says so.
 */
async function openKeyframeDelta(source, size) {
  const data = await source.read(0n, BigInt(size));
  const sequence = await decodeKeyframeDeltaStreamed(data);
  const notes = [
    "This reader composes a keyframe-delta file whole before playing it, so the resource " +
      "is read in one piece rather than by byte range.",
    "The composed population carries no spherical harmonics: SH bands live in their own " +
      "records, which this temporal model's read path does not visit.",
  ];

  const covering = (t) => {
    for (const chunk of sequence.chunks) if (chunk.t0 <= t && t < chunk.t1) return chunk;
    return sequence.chunks.length === 0 ? null : sequence.chunks[sequence.chunks.length - 1];
  };

  return {
    readMode: "keyframe-delta",
    header: sequence.header,
    duration: sequence.header.durationSec,
    frameAt: async (t) => {
      const chunk = covering(t);
      if (chunk === null) throw new MalformedFile("this keyframe-delta file carries no chunks");
      return reconstructKeyframeDelta(sequence, chunk, t);
    },
    intervalsAt: (t) => {
      const chunk = covering(t);
      return chunk === null ? [] : [{ t0: chunk.t0, t1: chunk.t1 }];
    },
    transfer: () => transferOf(source),
    notes,
  };
}

function transferOf(source) {
  return { bytes: source.bytes, reads: source.reads, size: source.total };
}
