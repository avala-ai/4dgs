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
 * The largest `keyframe-delta` resource this page will read whole.
 *
 * `decodeKeyframeDeltaStreamed` and `decodeKeyframeDeltaIndexed` both take a `Uint8Array`
 * rather than an `IReadable`, so this model's read path cannot be given bytes a range at a
 * time and the whole resource has to be in memory before anything is composed. A tab that
 * dies on the allocation says nothing; a sentence naming the size and the reason says what
 * happened and why the other temporal model has no such bound.
 */
const KEYFRAME_DELTA_BYTE_LIMIT = 512 * 1024 * 1024;

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
    // Every gaussian in the assembled set came from a chunk covering `t`, so §5.5's
    // "invisible outside its interval" is already satisfied by which chunks were read.
    frameAt: async (t) => frameFromSet(await setFor(t), t, cutoff, null),
    intervalsAt: (t) => decoder.chunksForTime(t).map(({ t0, t1 }) => ({ t0, t1 })),
    transfer: () => transferOf(source),
    notes,
  };
}

/** Front to back: the whole scene decoded once, then reconstructed at each instant. */
function streamedPlayable(scene, source, notes) {
  const cutoff = cutoffOf(scene.header);
  const gate = chunkGateOf(scene);
  if (gate === null) {
    notes.push(
      "This file was read front to back and carries no Chunk Index, so which chunk a " +
        "gaussian was stored in is not recoverable here. §5.5 says a chunk's gaussians are " +
        "invisible outside its [t0, t1); a gaussian whose validity window outlives its chunk " +
        "therefore stays on screen after that chunk ends, where the indexed path would drop " +
        "it. Every other visibility rule is applied.",
    );
  }
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
    frameAt: async (t) => frameFromSet(scene.gaussians, t, cutoff, gate),
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
 *
 * `gate`, when the caller has one, is §5.5's other hard gate — the interval of the chunk a
 * gaussian was stored in, which is not part of a `GaussianSet` and so has to be carried
 * alongside it.
 */
function frameFromSet(set, t, cutoff, gate) {
  const state = set.stateAt(t, cutoff);
  const total = state.indices.length;
  const centers = new Float32Array(total * 3);
  const rotations = new Float32Array(total * 4);
  const scales = new Float32Array(total * 3);
  const colors = new Float32Array(total * 4);
  const coefficients = set.sh === null ? 0 : set.sh.coefficients;
  const sh = coefficients === 0 ? null : new Uint8Array(total * 3 * coefficients);

  let count = 0;
  for (let k = 0; k < total; k++) {
    const i = state.indices[k];
    if (gate !== null && !(gate.t0[i] <= t && t < gate.t1[i])) continue;
    centers[count * 3] = state.centers[k * 3];
    centers[count * 3 + 1] = state.centers[k * 3 + 1];
    centers[count * 3 + 2] = state.centers[k * 3 + 2];
    for (let axis = 0; axis < 4; axis++) {
      rotations[count * 4 + axis] = state.orientations[k * 4 + axis];
    }
    scales[count * 3] = set.scales[i * 3];
    scales[count * 3 + 1] = set.scales[i * 3 + 1];
    scales[count * 3 + 2] = set.scales[i * 3 + 2];
    colors[count * 4] = set.colors[i * 4];
    colors[count * 4 + 1] = set.colors[i * 4 + 1];
    colors[count * 4 + 2] = set.colors[i * 4 + 2];
    // The temporal marginal is already folded into `opacity` by `stateAt`.
    colors[count * 4 + 3] = state.opacity[k];
    if (sh !== null) {
      const width = 3 * coefficients;
      sh.set(set.sh.values.subarray(i * width, i * width + width), count * width);
    }
    count += 1;
  }

  return {
    time: t,
    count,
    centers: centers.subarray(0, count * 3),
    scales: scales.subarray(0, count * 3),
    rotations: rotations.subarray(0, count * 4),
    colors: colors.subarray(0, count * 4),
    sh: sh === null ? null : sh.subarray(0, count * 3 * coefficients),
    shCoefficients: coefficients,
    shDegree: set.sh === null ? 0 : set.sh.degree,
  };
}

/**
 * Each gaussian's originating chunk interval, when the file makes it recoverable.
 *
 * §5.5: "its gaussians are invisible outside it". The indexed path gets this for free by
 * reading only the chunks that cover the instant, but `decodeScene` concatenates every
 * chunk into one `GaussianSet` and keeps no interval, so a front-to-back reader has to
 * recover the mapping or admit it cannot. It can be recovered exactly when the file carries
 * a Chunk Index: `assembleGaussians` lays chunks out in the order it visited them, which is
 * file order, and each index entry says how many gaussians its chunk holds. Anything that
 * does not add up — no index, or counts that disagree with the population — is `null`, and
 * the caller says so on the page rather than guessing a gate.
 */
function chunkGateOf(scene) {
  const entries = [...scene.chunkIndex].sort((a, b) => a.chunkOffset - b.chunkOffset);
  const count = scene.gaussians.count;
  let total = 0;
  for (const entry of entries) total += entry.gaussianCount;
  if (entries.length === 0 || total !== count) return null;

  const t0 = new Float64Array(count);
  const t1 = new Float64Array(count);
  let at = 0;
  for (const entry of entries) {
    t0.fill(entry.t0, at, at + entry.gaussianCount);
    t1.fill(entry.t1, at, at + entry.gaussianCount);
    at += entry.gaussianCount;
  }
  return { t0, t1 };
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
  if (size > KEYFRAME_DELTA_BYTE_LIMIT) {
    throw new MalformedFile(
      `this keyframe-delta resource is ${size} bytes, and this page composes a keyframe-delta ` +
        `file whole — @4dgs/core's keyframe-delta read paths take a byte array rather than a ` +
        `byte-range reader — so it declines anything over ${KEYFRAME_DELTA_BYTE_LIMIT} bytes ` +
        `rather than attempting the allocation. A gaussian-birth file of any size is read by ` +
        `range and has no such bound.`,
    );
  }
  const data = await source.read(0n, BigInt(size));
  const sequence = await decodeKeyframeDeltaStreamed(data);
  const cutoff = cutoffOf(sequence.header);
  const notes = [
    "This reader composes a keyframe-delta file whole before playing it, so the resource " +
      "is read in one piece rather than by byte range.",
    "The composed population carries no spherical harmonics: SH bands live in their own " +
      "records, which this temporal model's read path does not visit.",
  ];

  // The last instant this file can be reconstructed at is the last complete chunk's `t1`
  // (§11.10), which is the Header's duration for a whole file and less than it for one cut
  // short. Playing past it would repeat the last chunk's state under a clock that has moved
  // on — an answer the file does not give — so the timeline stops where the chunks do.
  const chunks = sequence.chunks;
  const covered = chunks.length === 0 ? 0 : chunks[chunks.length - 1].t1;
  const duration = Math.min(sequence.header.durationSec, covered);
  if (duration < sequence.header.durationSec) {
    notes.push(
      `The chunks that decoded cover [0, ${covered}), short of the Header's ` +
        `duration_sec ${sequence.header.durationSec}: the file was cut after a complete ` +
        `chunk. The timeline here ends where the chunks do rather than extrapolating.`,
    );
  }

  const covering = (t) => {
    for (const chunk of chunks) if (chunk.t0 <= t && t < chunk.t1) return chunk;
    return null;
  };

  return {
    readMode: "keyframe-delta",
    header: sequence.header,
    duration,
    frameAt: async (t) => {
      const chunk = covering(t);
      if (chunk === null) {
        throw new MalformedFile(
          chunks.length === 0
            ? "this keyframe-delta file carries no state chunks"
            : `no state chunk of this keyframe-delta file covers t = ${t}; the chunks that ` +
                `decoded cover [${chunks[0].t0}, ${covered})`,
        );
      }
      return reconstructKeyframeDelta(sequence, chunk, t, cutoff);
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
