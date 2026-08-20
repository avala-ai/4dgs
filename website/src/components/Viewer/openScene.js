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
  Cursor,
  DEFAULT_CUTOFF,
  FrontMatterScanner,
  HEAD_PROBE_BYTES,
  IndexedDecoder,
  MAGIC,
  KeyframeDeltaIndexedDecoder,
  MalformedFile,
  Opcode,
  TruncatedFile,
  RECORD_HEADER_BYTES,
  assembleGaussians,
  checkMagic,
  decodeKeyframeDeltaStreamed,
  decodeScene,
  parseChunk,
  parseHeader,
  readRecord,
  reconstructKeyframeDelta,
} from "@4dgs/core";

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
 * @property {number} [firstInstant] the earliest instant this file can be reconstructed
 *   at, when that is not zero — a keyframe-delta file's chunks may begin later. Absent
 *   means zero.
 * @property {string[]} notes things worth saying about this particular file
 */

/**
 * The largest Header record this page will fetch to learn the temporal model.
 *
 * Mirrors `MAX_FRONT_MATTER_BYTES` in `@4dgs/core`'s indexed reader, which is the ceiling
 * that reader puts on a single front-matter record. It is not exported, so it is restated
 * here rather than invented: a Header is framed by a `u64`, and a length field is not a
 * reason to allocate.
 */
const MAX_HEADER_RECORD_BYTES = 64 * 1024 * 1024;

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
    return await openGaussianBirth(counting, size);
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
 * The Header's temporal model, from a bounded walk of the front.
 *
 * `FrontMatterScanner` is the same walk `IndexedDecoder.open` does: it steps records by
 * their framed length, holding one window of `HEAD_PROBE_BYTES`, and fetches content only
 * for the record asked for. That matters because the Header is not the only thing at the
 * front of a file and it is not bounded by any probe size — a scene with a large
 * attributes map has a Header record of whatever size it needs, and a fixed-size read that
 * happens not to contain it would answer "not keyframe-delta" about a file that is one.
 *
 * `null` when the walk did not reach a Header, or when it could not be read at all — a
 * short or malformed file, whose real refusal the caller is already holding.
 */
async function temporalModelOf(source, size) {
  try {
    const scanner = new FrontMatterScanner(source, size, HEAD_PROBE_BYTES);
    checkMagic(await scanner.head(MAGIC.length));
    for await (const record of scanner.records(MAGIC.length)) {
      if (record.opcode !== Opcode.Header) continue;
      if (record.contentLength > MAX_HEADER_RECORD_BYTES) return null;
      return parseHeader(await scanner.content(record)).temporalModel;
    }
  } catch {
    return null;
  }
  return null;
}

// --------------------------------------------------------------------------
// gaussian-birth
// --------------------------------------------------------------------------

async function openGaussianBirth(source, size) {
  const notes = [];
  try {
    const decoder = await IndexedDecoder.open(source);
    // A summary CRC that does not match is a reason to stop trusting the index, not a
    // footnote to render underneath it. The dangerous corruption is the quiet one: an
    // index whose chunk offsets still resolve but whose `[t0, t1)` have moved selects the
    // wrong chunks for an instant, and the page draws a scene that looks entirely
    // plausible and is not the file's. The chunks themselves are untouched in that case,
    // so reading front to back recovers the real scene — the CRC exists precisely to say
    // when to do that.
    if (decoder.summaryCrcOk === false) {
      notes.push(
        "The Footer's summary CRC does not match the index it covers, so the index is not " +
          "trusted and the file is read front to back instead. The chunks are unaffected " +
          "by that mismatch; only the summary describing them is.",
      );
    } else if (decoder.index.length > 0) {
      return indexedPlayable(decoder, source, notes);
    } else {
      notes.push("The file carries no Chunk Index, so it is read front to back instead of seeked.");
    }
  } catch (error) {
    // An index that cannot be read is a reason to read the file the other way, not a
    // reason to refuse it: a file cut before its Footer has no index and still decodes.
    // If the streamed path refuses too, its diagnosis is the one that surfaces.
    notes.push(`The indexed read path was not usable: ${error.message}`);
  }
  const scene = await decodeScene(source);
  return await streamedPlayable(scene, source, size, notes);
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
async function streamedPlayable(scene, source, size, notes) {
  const cutoff = cutoffOf(scene.header);
  const { gate, why } = await chunkGateOf(scene, source, size);
  if (gate === null) {
    notes.push(
      `${why} §5.5 says a chunk's gaussians are invisible outside its [t0, t1); a gaussian ` +
        "whose validity window outlives its chunk therefore stays on screen after that chunk " +
        "ends, where the indexed path would drop it. Every other visibility rule is applied.",
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
/**
 * `@4dgs/core`'s reconstructed keyframe-delta state, in this page's frame shape.
 *
 * The two disagree on colour and on width, and both differences are the core's call
 * rather than this page's: it hands back `rgb` and `opacity` as separate `Float64Array`s
 * where a renderer wants one interleaved RGBA buffer, and it works in float64 where the
 * GPU takes float32. Converting here keeps that seam in one function instead of spreading
 * it across the renderer.
 *
 * No visibility filtering: `reconstructKeyframeDelta` has already applied the window test
 * and the file's own cutoff, which is why the cutoff argument this used to take is gone.
 */
function frameFromKeyframeDelta(state) {
  const count = state.count;
  const colors = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) {
    colors[i * 4] = state.rgb[i * 3];
    colors[i * 4 + 1] = state.rgb[i * 3 + 1];
    colors[i * 4 + 2] = state.rgb[i * 3 + 2];
    colors[i * 4 + 3] = state.opacity[i];
  }
  return {
    count,
    centers: Float32Array.from(state.centers),
    rotations: Float32Array.from(state.rotations),
    scales: Float32Array.from(state.scales),
    colors,
  };
}

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
 * Each gaussian's originating chunk interval, when the file makes it recoverable — and
 * when the file's own chunks agree that it does.
 *
 * §5.5: "its gaussians are invisible outside it". The indexed path gets this for free by
 * reading only the chunks that cover the instant, but `decodeScene` concatenates every
 * chunk into one `GaussianSet` and keeps no interval, so a front-to-back reader has to
 * recover the mapping or admit it cannot. It can be recovered exactly when the file carries
 * a Chunk Index: `assembleGaussians` lays chunks out in the order it visited them, which is
 * file order, and each index entry says how many gaussians its chunk holds.
 *
 * A Chunk Index reached this way has been vouched for by nothing. This path runs precisely
 * when the Footer did not open, so no summary CRC covered the index, and a per-entry
 * `gaussian_count` that is wrong in a way the total hides — two entries with their counts
 * swapped — would assign decoded rows to the wrong intervals and draw a plausible, wrong
 * scene. So every entry is checked against the Chunk record it names, exactly as
 * `IndexedDecoder.readChunk` checks it before decoding: the record at `chunk_offset` must
 * be a Chunk, and its header's `count`, `t0` and `t1` must be the ones the entry claims.
 * That costs one bounded read of each chunk record, on a path already reading the file
 * front to back, and it is the difference between a gate and a guess.
 *
 * A gate is not built unless every one of those checks passes. Nothing here refuses the
 * file: the gaussians decoded, and the indexed reader — the one whose contract an index
 * is — was already unusable on this file. An index that disagrees with its own chunks
 * simply does not get to decide what is visible, and the returned `why` says which record
 * disagreed and by how much.
 *
 * @returns {Promise<{gate: {t0: Float64Array, t1: Float64Array}|null, why: string}>}
 */
async function chunkGateOf(scene, source, size) {
  const entries = [...scene.chunkIndex].sort((a, b) => a.chunkOffset - b.chunkOffset);
  const count = scene.gaussians.count;
  if (entries.length === 0) {
    // No index is not the same as no intervals. §5.5 puts `t0` and `t1` in the Chunk
    // record's own header, so a file with no Chunk Index still says where each chunk
    // belongs on the timeline — it just does not say so in a place a seeking reader can
    // reach cheaply. Walking the records for them keeps the streamed path applying the
    // same visibility rule as the indexed one, rather than warning that it cannot.
    return chunkGateFromRecords(source, size, count);
  }
  let total = 0;
  for (const entry of entries) total += entry.gaussianCount;
  if (total !== count) {
    return {
      gate: null,
      why:
        `This file's Chunk Index accounts for ${total} gaussians and ${count} were decoded, ` +
        "so it cannot say which chunk each one came from.",
    };
  }

  for (const entry of entries) {
    const mismatch = await chunkDisagreement(entry, source, size);
    if (mismatch !== null) return { gate: null, why: `This file's ${mismatch}` };
  }

  const t0 = new Float64Array(count);
  const t1 = new Float64Array(count);
  let at = 0;
  for (const entry of entries) {
    t0.fill(entry.t0, at, at + entry.gaussianCount);
    t1.fill(entry.t1, at, at + entry.gaussianCount);
    at += entry.gaussianCount;
  }
  return { gate: { t0, t1 }, why: "" };
}

/**
 * How one Chunk Index entry disagrees with the Chunk record it points at, or `null`.
 *
 * The record is read and framed by `@4dgs/core` — `readRecord` then `parseChunk` — so this
 * is the indexed reader's own check on the streamed reader's data, not a second opinion
 * about what a Chunk record contains.
 */
/**
 * `f64 t0, f64 t1, u32 level, u32 count` — the front of a Chunk record's content (§5.5).
 *
 * `parseChunk` is not used for this. It finishes by taking the record's attribute streams
 * as a length-prefixed blob, so it needs the whole content and throws on a prefix — which
 * is exactly what must not be read here. A legal file may hold its entire scene in one
 * chunk, and checking that chunk's interval must not cost the scene a second time after
 * the streamed decode has already paid for it.
 *
 * The three fields this returns are all any caller here wants, and they sit in the first
 * 24 bytes, ahead of the variable-length compression name.
 */
const CHUNK_HEAD_BYTES = 24;

function chunkHeadOf(content) {
  if (content.length < CHUNK_HEAD_BYTES) {
    throw new MalformedFile(
      `a Chunk record's content is ${content.length} bytes, too short for the ` +
        `${CHUNK_HEAD_BYTES}-byte interval and count at its front`,
    );
  }
  const view = new DataView(content.buffer, content.byteOffset, content.byteLength);
  return {
    t0: view.getFloat64(0, true),
    t1: view.getFloat64(8, true),
    count: view.getUint32(20, true),
  };
}

/**
 * The chunk gate built from the Chunk records themselves, for a file with no index.
 *
 * No index is not the same as no intervals. §5.5 puts `t0` and `t1` at the very front of
 * a Chunk record's content, ahead of everything that makes a chunk large, so a file with
 * no Chunk Index still says where each chunk belongs on the timeline. Walking for them
 * keeps the streamed path applying the same visibility rule as the indexed one.
 *
 * Bounded, as §1 requires: one 9-byte framing read per record and one short prefix per
 * Chunk, stepping over every payload by its declared length. Nothing here reads a chunk's
 * attribute streams — those were already decoded, once, by `decodeScene`.
 *
 * Returns the same `{gate, why}` shape as the indexed path. A file whose records cannot be
 * walked, or whose chunk counts do not add up to what was decoded, yields a `null` gate
 * and a sentence saying so — the same outcome as before, but now only when the file really
 * cannot support the gate.
 */
async function chunkGateFromRecords(source, size, count) {
  const t0 = new Float64Array(count);
  const t1 = new Float64Array(count);
  let at = MAGIC.length;
  let filled = 0;
  try {
    while (at + RECORD_HEADER_BYTES <= size) {
      const head = await source.read(BigInt(at), BigInt(RECORD_HEADER_BYTES));
      if (head.length < RECORD_HEADER_BYTES) break;
      // Framed by hand rather than through `readRecord`, which takes the whole content:
      // the point here is to not read it.
      const view = new DataView(head.buffer, head.byteOffset, head.byteLength);
      const opcode = view.getUint8(0);
      const contentLength = Number(view.getBigUint64(1, true));
      if (contentLength < 0 || at + RECORD_HEADER_BYTES + contentLength > size) break;
      if (opcode === Opcode.Chunk) {
        const wanted = Math.min(contentLength, CHUNK_HEAD_BYTES);
        const prefix = await source.read(BigInt(at + RECORD_HEADER_BYTES), BigInt(wanted));
        const header = chunkHeadOf(prefix);
        if (filled + header.count > count) {
          return {
            gate: null,
            why:
              `This file's Chunk records account for more than the ${count} gaussians that ` +
              "were decoded, so which chunk each one came from is not recoverable.",
          };
        }
        t0.fill(header.t0, filled, filled + header.count);
        t1.fill(header.t1, filled, filled + header.count);
        filled += header.count;
      }
      at += RECORD_HEADER_BYTES + contentLength;
    }
  } catch (error) {
    return {
      gate: null,
      why:
        "This file was read front to back and its Chunk records could not be walked for " +
        `their intervals (${error.message}), so which chunk a gaussian was stored in is ` +
        "not recoverable here.",
    };
  }
  if (filled !== count) {
    return {
      gate: null,
      why:
        `This file's Chunk records account for ${filled} gaussians and ${count} were ` +
        "decoded, so they cannot say which chunk each one came from.",
    };
  }
  return { gate: { t0, t1 }, why: "" };
}

async function chunkDisagreement(entry, source, size) {
  const { chunkOffset, chunkLength } = entry;
  if (chunkOffset < 0 || chunkLength < RECORD_HEADER_BYTES || chunkOffset + chunkLength > size) {
    return (
      `Chunk Index entry for [${entry.t0}, ${entry.t1}) spans ` +
      `[${chunkOffset}, ${chunkOffset + chunkLength}), outside the ${size}-byte resource.`
    );
  }
  let parsed;
  try {
    // The framing plus the head of the content, never `chunkLength`. This runs to check a
    // header, and a legal file may hold its whole scene in one chunk — reading that chunk
    // to look at its first 36 bytes would allocate the scene a second time, after the
    // streamed decode has already paid for it once.
    const wanted = Math.min(chunkLength, RECORD_HEADER_BYTES + CHUNK_HEAD_BYTES);
    const blob = await source.read(BigInt(chunkOffset), BigInt(wanted));
    const view = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
    const opcode = view.getUint8(0);
    if (opcode !== Opcode.Chunk) {
      return (
        `Chunk Index points at offset ${chunkOffset}, which holds opcode ` +
        `0x${opcode.toString(16)} rather than a Chunk.`
      );
    }
    parsed = { header: chunkHeadOf(blob.subarray(RECORD_HEADER_BYTES)) };
  } catch (error) {
    return `Chunk Index entry at offset ${chunkOffset} could not be read back: ${error.message}`;
  }
  const { count, t0, t1 } = parsed.header;
  if (count !== entry.gaussianCount) {
    return (
      `chunk at ${chunkOffset} holds ${count} gaussians and its index entry says ` +
      `${entry.gaussianCount}.`
    );
  }
  if (t0 !== entry.t0 || t1 !== entry.t1) {
    return (
      `chunk at ${chunkOffset} covers [${t0}, ${t1}) and its index entry says ` +
      `[${entry.t0}, ${entry.t1}).`
    );
  }
  return null;
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
 * A `keyframe-delta` file opened by byte range, through `@4dgs/core`'s indexed decoder.
 *
 * The decoder reads the front matter and the summary, then fetches only the chunks an
 * instant needs — for a chained delta, the keyframe at the head of its group and the
 * deltas between. Nothing composes the file whole, so there is no size ceiling on this
 * path and none of the retention the streamed one pays for.
 */
async function openKeyframeDeltaIndexed(source) {
  const decoder = await KeyframeDeltaIndexedDecoder.open(source);
  const index = decoder.index;
  if (index.length === 0) {
    throw new MalformedFile(
      "this keyframe-delta file carries no Chunk Index, so it cannot be read by range",
    );
  }
  // §11.10, as on the streamed path: the timeline ends at the largest `t1`, which is not
  // necessarily the last entry — chunks tile in time order and may be stored in any order.
  let covered = index[0].t1;
  let earliest = index[0].t0;
  for (const entry of index) {
    covered = Math.max(covered, entry.t1);
    earliest = Math.min(earliest, entry.t0);
  }
  const duration = Math.min(decoder.header.durationSec, covered);
  const notes = [
    "This file is read by byte range: the Footer, the Chunk Index, then only the chunks " +
      "the instant on screen is reconstructed from.",
    "The composed population carries no spherical harmonics: SH bands live in their own " +
      "records, which this temporal model's read path does not visit.",
  ];
  if (duration < decoder.header.durationSec) {
    notes.push(
      `The indexed chunks cover [${earliest}, ${covered}), short of the Header's ` +
        `duration_sec ${decoder.header.durationSec}: the timeline here ends where the ` +
        "chunks do rather than extrapolating.",
    );
  }
  return {
    readMode: "keyframe-delta",
    header: decoder.header,
    duration,
    // Where this file's timeline actually starts. Chunks need not begin at zero, and the
    // camera framing asks for this instant rather than assuming one exists at 0.
    firstInstant: earliest,
    frameAt: async (t) => frameFromKeyframeDelta(await decoder.reconstructAt(t)),
    intervalsAt: (t) => {
      for (const entry of index) {
        if (entry.t0 <= t && t < entry.t1) return [{ t0: entry.t0, t1: entry.t1 }];
      }
      return [];
    },
    // Required by the playable contract and read every frame by the readout, so omitting
    // it is not a missing statistic — it throws in the animation loop and freezes
    // playback on the first frame.
    transfer: () => transferOf(source),
    notes,
  };
}

/**
 * The `keyframe-delta` model, read by byte range when the file carries an index.
 *
 * `KeyframeDeltaIndexedDecoder` opens over an `IReadable` and reconstructs an instant from
 * the chunks that instant needs, which is the same bargain the gaussian-birth indexed path
 * makes and the reason §1's bounded-memory rule is satisfiable here at all. An earlier
 * version of this page composed every keyframe-delta file whole, behind a size limit,
 * because that decoder did not exist yet; a fixed ceiling is not bounded memory, it is a
 * larger unbounded read.
 *
 * The whole-file path below survives for files this one cannot open — no Chunk Index, or
 * one cut before its Footer — where there is nothing to seek with. That case keeps the
 * limit, and the page still says so.
 */
async function openKeyframeDelta(source, size) {
  try {
    return await openKeyframeDeltaIndexed(source);
  } catch (error) {
    // Not a swallow: the streamed composition below re-reads the same bytes and refuses
    // them in its own words if they are genuinely bad. What this catch covers is a file
    // with no usable index, which is a legal file and the reason the other path exists.
    if (!(error instanceof MalformedFile) && !(error instanceof TruncatedFile)) throw error;
  }
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
  //
  // "Last" is the largest `t1`, not the last element: state chunks tile the timeline in
  // *time* order and `checkTiling` sorts them by `t0` before checking adjacency, so nothing
  // requires a file to store them in that order. `sequence.chunks` is file order. Taking the
  // final element would cut an 8-second scene stored as [4, 8), [0, 4) down to 4 seconds and
  // call the missing half a truncation. `keyframeDeltaStatesJson` bounds its own probes the
  // same way, by a maximum over every chunk's `t1`.
  const chunks = sequence.chunks;
  let covered = 0;
  let earliest = 0;
  for (let i = 0; i < chunks.length; i++) {
    covered = i === 0 ? chunks[i].t1 : Math.max(covered, chunks[i].t1);
    earliest = i === 0 ? chunks[i].t0 : Math.min(earliest, chunks[i].t0);
  }
  const duration = Math.min(sequence.header.durationSec, covered);
  if (duration < sequence.header.durationSec) {
    notes.push(
      `The chunks that decoded cover [${earliest}, ${covered}), short of the Header's ` +
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
    // As on the indexed path: a file whose chunks begin after zero has nothing at zero,
    // and the camera framing asks here rather than assuming.
    firstInstant: earliest,
    frameAt: async (t) => {
      const chunk = covering(t);
      if (chunk === null) {
        throw new MalformedFile(
          chunks.length === 0
            ? "this keyframe-delta file carries no state chunks"
            : `no state chunk of this keyframe-delta file covers t = ${t}; the chunks that ` +
                `decoded cover [${earliest}, ${covered})`,
        );
      }
      // No cutoff argument: `@4dgs/core` reads `sequence.header.cutoff` itself, which
      // is the same number `cutoffOf` was passing and one fewer place for the two to
      // disagree.
      return frameFromKeyframeDelta(reconstructKeyframeDelta(sequence, chunk, t));
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
