/**
 * The conformance corpus, as the viewer's tests see it.
 *
 * Every expected value in these tests comes from `tests/conformance/data` — the same files
 * the six SDKs are diffed against — and never from a number typed into a test. The corpus
 * is generated rather than committed (`tests/conformance/data/.gitignore` ignores `*.4dgs`),
 * so a missing corpus is a hard failure with the command that fixes it, never a skip: a
 * suite that goes green because it found nothing to check is worse than no suite.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { open } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(here, "../../..");
export const CORPUS = path.join(REPO_ROOT, "tests/conformance/data");

/** Subdirectories of the corpus, by what they hold. */
export const FAMILIES = {
  gaussianBirth: ["", "object"],
  keyframeDelta: ["keyframe"],
  invalid: ["invalid"],
};

function requireCorpus() {
  let ok = false;
  try {
    ok = statSync(CORPUS).isDirectory();
  } catch {
    ok = false;
  }
  if (!ok) {
    throw new Error(
      `the conformance corpus is not at ${CORPUS}. Generate it first:\n` +
        `    python3 tests/conformance/generate.py`,
    );
  }
}

/**
 * Every `.4dgs` under the given corpus subdirectories, with its committed expectation.
 *
 * Throws when a directory holds no scene files, so a corpus that generated partially fails
 * the suite instead of quietly shrinking it.
 */
export function variants(directories) {
  requireCorpus();
  const out = [];
  for (const directory of directories) {
    const at = path.join(CORPUS, directory);
    const names = readdirSync(at).filter((name) => name.endsWith(".4dgs"));
    if (names.length === 0) {
      throw new Error(
        `${at} holds no .4dgs files; run \`python3 tests/conformance/generate.py\` first`,
      );
    }
    for (const name of names.sort()) {
      const file = path.join(at, name);
      const expectation = file.replace(/\.4dgs$/, ".json");
      out.push({
        name: path.join(directory, name),
        file,
        expected: JSON.parse(readFileSync(expectation, "utf8")),
      });
    }
  }
  return out;
}

/** One named variant, by the filename the corpus generator gives it. */
export function variant(relative) {
  requireCorpus();
  const file = path.join(CORPUS, relative);
  statSync(file);
  return {
    name: relative,
    file,
    bytes: new Uint8Array(readFileSync(file)),
    expected: JSON.parse(readFileSync(file.replace(/\.4dgs$/, ".json"), "utf8")),
  };
}

/** `IReadable` over a file on disk: one `read` per range, as a transport would be. */
export class FileReadable {
  constructor(file) {
    this.file = file;
    this.bytes = statSync(file).size;
  }
  async size() {
    return BigInt(this.bytes);
  }
  async read(offset, length) {
    const at = Number(offset);
    const want = Math.min(Number(length), Math.max(0, this.bytes - at));
    const handle = await open(this.file, "r");
    try {
      const buffer = new Uint8Array(want);
      if (want > 0) await handle.read(buffer, 0, want, at);
      return buffer;
    } finally {
      await handle.close();
    }
  }
}

/**
 * `IReadable` over bytes in memory, for a mutated copy of a corpus file.
 *
 * `hideFooter` corrupts the tail on the way out, which is how a test reaches the streamed
 * read path on a file the corpus wrote a Footer for.
 */
export class BytesReadable {
  constructor(bytes, { hideFooter = false } = {}) {
    this.b = bytes;
    this.hideFooter = hideFooter;
  }
  async size() {
    return BigInt(this.b.length);
  }
  async read(offset, length) {
    const at = Number(offset);
    const out = this.b.slice(at, at + Math.min(Number(length), Math.max(0, this.b.length - at)));
    if (this.hideFooter && at + out.length >= this.b.length && out.length > 0) {
      for (let i = Math.max(0, out.length - 8); i < out.length; i++) out[i] ^= 0xff;
    }
    return out;
  }
}

/**
 * A readable whose tail is corrupted, so `IndexedDecoder.open` cannot find the Footer.
 *
 * This is how the streamed read path is reached for a file that has an index: without it
 * the viewer would always take the indexed path on a corpus that always writes a Footer,
 * and the two paths could never be compared on the same bytes.
 */
export class NoFooterReadable extends FileReadable {
  async read(offset, length) {
    const bytes = await super.read(offset, length);
    const at = Number(offset);
    if (at + bytes.byteLength >= this.bytes && bytes.byteLength > 0) {
      const copy = bytes.slice();
      for (let i = Math.max(0, copy.length - 8); i < copy.length; i++) copy[i] ^= 0xff;
      return copy;
    }
    return bytes;
  }
}

/** The instants a file is probed at: the ends of `[0, duration)` and three inside it. */
export function instantsFor(duration) {
  if (!(duration > 0)) return [0];
  const last = duration - Math.max(duration * 1e-9, Number.EPSILON);
  return [0, duration * 0.25, duration * 0.5, duration * 0.75, last].map((t) => Math.min(t, last));
}

const round = (value) => Math.round(value * 1e6) / 1e6;

/**
 * A frame reduced to numbers two read paths must agree on exactly.
 *
 * Sums rather than samples, because the two paths assemble the population in different
 * orders and a decoded scene is a set, not a sequence.
 */
export function digest(frame) {
  let cx = 0;
  let cy = 0;
  let cz = 0;
  let scale = 0;
  let opacity = 0;
  let worstQuaternion = 0;
  let finite = true;
  let positiveScales = true;
  let opacityInRange = true;
  for (let i = 0; i < frame.count; i++) {
    cx += frame.centers[i * 3];
    cy += frame.centers[i * 3 + 1];
    cz += frame.centers[i * 3 + 2];
    for (let c = 0; c < 3; c++) {
      const s = frame.scales[i * 3 + c];
      scale += s;
      if (!(s > 0)) positiveScales = false;
      if (!Number.isFinite(frame.centers[i * 3 + c])) finite = false;
    }
    let norm = 0;
    for (let c = 0; c < 4; c++) norm += frame.rotations[i * 4 + c] ** 2;
    worstQuaternion = Math.max(worstQuaternion, Math.abs(Math.sqrt(norm) - 1));
    const alpha = frame.colors[i * 4 + 3];
    opacity += alpha;
    if (!(alpha >= 0 && alpha <= 1)) opacityInRange = false;
  }
  return {
    count: frame.count,
    centerSum: [round(cx), round(cy), round(cz)],
    scaleSum: round(scale),
    opacitySum: round(opacity),
    worstQuaternion,
    finite,
    positiveScales,
    opacityInRange,
  };
}

export { round };
