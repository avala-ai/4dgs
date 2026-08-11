/**
 * What the viewer decodes, checked against the conformance corpus in Node.
 *
 * A renderer's wrong answer looks plausible: a scene with a gaussian too many draws
 * perfectly well. So nothing here is judged by eye. Every assertion is either a comparison
 * between the two read paths on the same bytes, or a comparison against a committed
 * expectation in `tests/conformance/data`, or a property the specification states
 * unconditionally (finite centres, positive scales, unit quaternions, opacity in `[0, 1]`).
 *
 * The corpus is generated, not committed. Run `python3 tests/conformance/generate.py` first;
 * these tests fail rather than skip when it is absent.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  Attribute,
  FourdgsError,
  GAUSSIAN_FLAG_NEVER_FADES,
  MAGIC,
  MalformedFile,
  UnsupportedCodec,
  UnsupportedVersion,
  decodeKeyframeDeltaStreamed,
  stepsFrom,
  supportK,
  lifeClass,
  motionStep,
  muStep,
} from "@4dgs/core";

import { ViewerLimitError, openScene } from "../src/components/Viewer/openScene.js";
import { reconstructKeyframeDelta } from "../src/components/Viewer/keyframeDelta.js";
import {
  BytesReadable,
  FAMILIES,
  FileReadable,
  NoFooterReadable,
  digest,
  instantsFor,
  round,
  variant,
  variants,
} from "./support/corpus.mjs";
import {
  cutAfterChunk,
  withBadSummaryCrc,
  withDuplicateIndexOffset,
  withHeaderDuration,
  withHeaderShDegree,
  withPaddedHeader,
  withRedistributedIndexCounts,
  withStateChunksReversed,
} from "./support/mutate.mjs";

const GAUSSIAN_BIRTH = variants(FAMILIES.gaussianBirth);
const KEYFRAME_DELTA = variants(FAMILIES.keyframeDelta);
const INVALID = variants(FAMILIES.invalid);

/**
 * Whether this variant carries a Chunk Index with anything in it.
 *
 * The corpus encodes each optional feature in the variant's own filename — the same
 * convention `tests/conformance/run.py` reads a variant by — and the expectation records
 * the intervals, so a file that asks for an index but has no chunks to put in one (the
 * empty `NoData` variants) is correctly read front to back.
 */
const hasChunkIndex = (variant) =>
  variant.name.includes("UseChunkIndex") && variant.expected.chunkIntervals.length > 0;

describe("the corpus decodes to the same scene on both read paths", () => {
  // Guards against a corpus, or a viewer, in which nothing ever reaches one of the paths.
  it("the corpus covers both read paths", () => {
    const indexed = GAUSSIAN_BIRTH.filter(hasChunkIndex);
    assert.ok(indexed.length > 1, "no indexed variants to check");
    assert.ok(GAUSSIAN_BIRTH.length - indexed.length > 0, "no unindexed variants to check");
  });

  for (const entry of GAUSSIAN_BIRTH) {
    const { name, file, expected } = entry;
    it(name, async () => {
      const indexed = await openScene(new FileReadable(file));
      const streamed = await openScene(new NoFooterReadable(file));
      assert.equal(
        indexed.readMode,
        hasChunkIndex(entry) ? "indexed" : "streamed",
        "the read path the file asks for",
      );
      assert.equal(streamed.readMode, "streamed", "hiding the Footer must reach the other path");

      // The Header, against the expectation every SDK is diffed on.
      assert.equal(indexed.header.temporalModel, expected.temporalModel);
      assert.equal(indexed.duration, expected.durationSec);
      assert.equal(indexed.header.cutoff, expected.cutoff);
      assert.equal(String(indexed.header.gaussianCount), expected.gaussianCount);
      assert.equal(indexed.header.shDegree, expected.shDegree);

      for (const t of instantsFor(indexed.duration)) {
        // §8's seek rule, against the intervals the expectation lists.
        const covering = expected.chunkIntervals
          .filter(([t0, t1]) => t0 <= t && t < t1)
          .map(([t0, t1]) => `[${t0}, ${t1})`);
        for (const playable of [indexed, streamed]) {
          const seen = playable.intervalsAt(t).map(({ t0, t1 }) => `[${t0}, ${t1})`);
          assert.deepEqual(
            seen,
            covering,
            `chunks covering t = ${t} on the ${playable.readMode} path`,
          );
        }

        const a = digest(await indexed.frameAt(t));
        const b = digest(await streamed.frameAt(t));
        assert.ok(a.finite, `t = ${t}: every centre is finite`);
        assert.ok(a.positiveScales, `t = ${t}: every scale is positive`);
        assert.ok(a.opacityInRange, `t = ${t}: every opacity is within [0, 1]`);
        assert.ok(
          a.worstQuaternion < 1e-3,
          `t = ${t}: quaternions are unit (${a.worstQuaternion})`,
        );
        assert.deepEqual(
          b,
          a,
          `t = ${t}: the indexed and streamed paths must decode the same scene`,
        );
      }
    });
  }
});

describe("keyframe-delta reconstruction matches the canonical statement", () => {
  for (const { name, file, expected } of KEYFRAME_DELTA) {
    it(name, async () => {
      const playable = await openScene(new FileReadable(file));
      assert.equal(playable.readMode, "keyframe-delta");
      assert.equal(playable.header.temporalModel, expected.temporalModel);
      assert.equal(playable.duration, expected.durationSec);
      assert.ok(
        expected.states.length > 0,
        "the committed expectation probes at least one instant",
      );

      for (const row of expected.states) {
        const frame = await playable.frameAt(row.t);
        // Every window in this corpus covers the whole timeline and no probe falls under
        // the cutoff, so the visible population is the composed one. Where that stops being
        // true the viewer is right to differ — see the window/cutoff tests below — but on
        // these files any difference is a bug in this page.
        assert.equal(frame.count, Number(row.liveCount), `live count at t = ${row.t}`);
        let px = 0;
        let py = 0;
        let pz = 0;
        let opacity = 0;
        for (let i = 0; i < frame.count; i++) {
          px += frame.centers[i * 3];
          py += frame.centers[i * 3 + 1];
          pz += frame.centers[i * 3 + 2];
          opacity += frame.colors[i * 4 + 3];
        }
        assert.deepEqual(
          [round(px), round(py), round(pz)],
          row.aggregate.positionSum.map(round),
          `positionSum at t = ${row.t}`,
        );
        assert.equal(round(opacity), round(row.aggregate.opacitySum), `opacitySum at t = ${row.t}`);
        assert.deepEqual(
          Array.from(frame.centers, round),
          row.sample.positions.flat().map(round),
          `sample positions at t = ${row.t}`,
        );
        assert.deepEqual(
          Array.from(frame.scales, round),
          row.sample.scales.flat().map(round),
          `sample scales at t = ${row.t}`,
        );
      }
    });
  }
});

describe("an invalid file is refused in the decoder's own words", () => {
  for (const { name, file, expected } of INVALID) {
    it(name, async () => {
      assert.ok(typeof expected.refused === "string" && expected.refused.length > 0);
      let refusal = null;
      try {
        const playable = await openScene(new FileReadable(file));
        for (const t of instantsFor(playable.duration)) {
          await playable.frameAt(t);
        }
      } catch (error) {
        refusal = error;
      }
      assert.ok(refusal !== null, "every invalid variant must be refused somewhere");
      assert.ok(
        refusal instanceof FourdgsError,
        `refused with ${refusal?.constructor?.name}, not a 4dgs refusal`,
      );
      assert.equal(refusalTag(refusal), expected.refused, refusal.message);
      // §6: a refusal names the value, not just the fact. The page prints this sentence as
      // it came, so a message that stopped saying anything would be invisible here
      // otherwise.
      assert.ok(
        refusal.message.length > 40 && /\d|'/.test(refusal.message),
        `refusal does not name a value: ${refusal.message}`,
      );
    });
  }
});

function refusalTag(error) {
  const message = error.message;
  if (error instanceof UnsupportedVersion) {
    return message.startsWith("not a 4dgs file:") || /major version 1\b/.test(message)
      ? "magic-mismatch"
      : "unsupported-major-version";
  }
  if (error instanceof UnsupportedCodec) {
    if (/temporal model/.test(message)) return "unknown-temporal-model";
    if (/Quantization.*scheme/.test(message)) return "unknown-quantization-scheme";
    if (/stream codec/.test(message)) return "unknown-stream-codec";
  }
  if (error instanceof MalformedFile && /window index/.test(message)) {
    return "window-index-out-of-range";
  }
  return `unmapped:${error.constructor.name}`;
}

describe("§5.5: a chunk's gaussians are invisible outside its interval", () => {
  // The file this PR was opened over: a gaussian whose validity window is [14, 16) stored
  // in the chunk [14, 15), so at t = 15 the chunk interval and the window disagree.
  const divergent = "TenWindows-DeltaStreams-Quantized-UseChunkIndex-UseChunks-UseCrc.4dgs";

  it("the streamed path applies the gate the indexed path gets for free", async () => {
    const { file, expected } = variant(divergent);
    const indexed = await openScene(new FileReadable(file));
    const streamed = await openScene(new NoFooterReadable(file));
    // An instant where a chunk boundary and a validity window disagree: the end of a chunk
    // that is not the end of the file, taken from the expectation rather than assumed.
    const boundaries = expected.chunkIntervals
      .map(([, t1]) => t1)
      .filter((t1) => t1 < expected.durationSec);
    assert.ok(boundaries.length > 0);
    for (const t of boundaries) {
      const a = await indexed.frameAt(t);
      const b = await streamed.frameAt(t);
      assert.equal(
        b.count,
        a.count,
        `t = ${t}: the streamed path drew ${b.count} where the indexed path drew ${a.count}`,
      );
      assert.deepEqual(digest(b), digest(a), `t = ${t}`);
    }
  });

  it("a Chunk Index whose counts do not match its chunks does not get to gate", async () => {
    const { bytes, firstEntry, claimed } = withRedistributedIndexCounts(
      variant("TenWindows-UseChunkIndex-UseChunks-UseCrc.4dgs").bytes,
    );
    const playable = await openScene(new BytesReadable(bytes, { hideFooter: true }));
    assert.equal(playable.readMode, "streamed", "the gate under test is the streamed one");
    const note = playable.notes.find((line) => line.includes(`chunk at ${firstEntry.chunkOffset}`));
    assert.ok(
      note !== undefined,
      `no note named the disagreeing chunk; notes were:\n${playable.notes.join("\n")}`,
    );
    assert.match(note, new RegExp(`holds ${firstEntry.gaussianCount} gaussians`));
    assert.match(note, new RegExp(`index entry says ${claimed}`));
  });

  it("an untouched index does gate, so the check above is not vacuous", async () => {
    const playable = await openScene(
      new BytesReadable(variant("TenWindows-UseChunkIndex-UseChunks-UseCrc.4dgs").bytes.slice(), {
        hideFooter: true,
      }),
    );
    assert.equal(playable.readMode, "streamed");
    assert.ok(
      !playable.notes.some((line) => line.includes("Every other visibility rule is applied")),
      `a conforming file lost its gate:\n${playable.notes.join("\n")}`,
    );
  });

  it("a CRC-rejected index falls back to the streamed path", async () => {
    const bytes = withBadSummaryCrc(
      variant("TenWindows-UseChunkIndex-UseChunks-UseCrc.4dgs").bytes,
    );
    const playable = await openScene(new BytesReadable(bytes));
    assert.equal(playable.readMode, "streamed");
    assert.ok(playable.notes.some((line) => line.includes("summary CRC")));
  });

  it("duplicate Chunk offsets cannot build a streamed interval gate", async () => {
    const { bytes, duplicateOffset } = withDuplicateIndexOffset(
      variant("TenWindows-UseChunkIndex-UseChunks-UseCrc.4dgs").bytes,
    );
    const playable = await openScene(new BytesReadable(bytes, { hideFooter: true }));
    assert.equal(playable.readMode, "streamed");
    assert.ok(
      playable.notes.some(
        (line) =>
          line.includes(`offset ${duplicateOffset} more than once`) && line.includes("one to one"),
      ),
    );
  });
});

describe("§3: a keyframe-delta gaussian exists only inside its window and above the cutoff", () => {
  const source = "keyframe/KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics.4dgs";

  /** One composed chunk of a corpus file, and the marginal of each of its gaussians at `t`. */
  async function chunkAt(t) {
    const sequence = await decodeKeyframeDeltaStreamed(variant(source).bytes);
    const chunk = sequence.chunks.find((c) => c.t0 <= t && t < c.t1);
    assert.ok(chunk !== undefined);
    const steps = stepsFrom(sequence.quantization);
    const k = supportK(sequence.header.cutoff);
    const windows =
      sequence.windows.length > 0
        ? sequence.windows
        : new Float64Array([0, sequence.header.durationSec]);
    const state = chunk.state;
    const sigmaBins = state.column(Attribute.SigmaT).values;
    const muBins = state.column(Attribute.MuT).values;
    const flags = state.column(Attribute.Flags).values;
    const windowBins = state.column(Attribute.WindowIndex).values;
    const marginals = [];
    for (let i = 0; i < state.count; i++) {
      const neverFades = (flags[i] & GAUSSIAN_FLAG_NEVER_FADES) !== 0;
      const sigma = neverFades ? Infinity : Math.exp(sigmaBins[i] * steps.sigmaLog);
      const windowIndex = windowBins[i];
      const length = windows[windowIndex * 2 + 1] - windows[windowIndex * 2];
      // Referenced so the pitch derivation is exercised exactly as the reconstruction does.
      motionStep(lifeClass(sigmaBins[i], steps.sigmaLog, neverFades, length, k), steps.motion);
      const mu = muBins[i] * muStep(sigmaBins[i], steps.sigmaLog, neverFades, steps.time);
      const dt = t - mu;
      marginals.push(sigma === Infinity ? 1 : Math.exp(-0.5 * (dt / sigma) * (dt / sigma)));
    }
    return { sequence, chunk, marginals };
  }

  it("the marginal cutoff drops exactly the gaussians below it", async () => {
    const t = 2;
    const { sequence, chunk, marginals } = await chunkAt(t);
    assert.ok(marginals.length > 0, "this chunk composes a population");
    const lowest = Math.min(...marginals);
    const highest = Math.max(...marginals);
    // Every threshold is one of the file's own marginals, or just past the largest of them.
    // The last of these is what makes the test about `marginal >= cutoff` rather than about
    // some cutoff: it is the smallest value no gaussian in this file can reach.
    const thresholds = [0, lowest, (lowest + highest) / 2, highest, highest * (1 + 1e-9)];
    for (const cutoff of thresholds) {
      const expected = marginals.filter((m) => m >= cutoff).length;
      const frame = reconstructKeyframeDelta(sequence, chunk, t, cutoff);
      assert.equal(frame.count, expected, `cutoff ${cutoff}`);
      assert.equal(frame.centers.length, expected * 3);
      assert.equal(frame.colors.length, expected * 4);
      assert.equal(frame.rotations.length, expected * 4);
      assert.equal(frame.scales.length, expected * 3);
    }
    // The two ends of that list are the ones that would go unnoticed: the whole population
    // and none of it.
    assert.equal(reconstructKeyframeDelta(sequence, chunk, t, 0).count, marginals.length);
    assert.equal(reconstructKeyframeDelta(sequence, chunk, t, highest * (1 + 1e-9)).count, 0);
  });

  it("a validity window that has ended removes the gaussian entirely", async () => {
    const t = 2;
    const { sequence, chunk } = await chunkAt(t);
    const windowBins = chunk.state.column(Attribute.WindowIndex).values;
    const total = chunk.state.count;
    assert.ok(total > 1);
    // A second window that closed before `t`, pointed at by every other gaussian. The
    // window table is the file's, plus one entry; nothing else about the file changes.
    const base =
      sequence.windows.length > 0 ? [...sequence.windows] : [0, sequence.header.durationSec];
    const windows = Float64Array.from([...base, 0, t]);
    const moved = [];
    for (let i = 0; i < total; i += 2) {
      moved.push(i);
      windowBins[i] = base.length / 2;
    }
    const gated = reconstructKeyframeDelta({ ...sequence, windows }, chunk, t, 0);
    assert.equal(
      gated.count,
      total - moved.length,
      "gaussians whose window has closed must not be in the frame at all",
    );
    // The window is half-open, so the gaussians are back one instant earlier.
    const before = reconstructKeyframeDelta({ ...sequence, windows }, chunk, t - 0.5, 0);
    assert.equal(before.count, total);
  });
});

describe("§11.10: a keyframe-delta timeline ends where its chunks do", () => {
  const source = "keyframe/KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics.4dgs";

  it("a file cut after a complete chunk plays to that chunk's t1 and refuses past it", async () => {
    const whole = variant(source);
    const sequence = await decodeKeyframeDeltaStreamed(whole.bytes);
    const keep = 1;
    const { bytes } = cutAfterChunk(whole.bytes, keep);
    const covered = Math.max(...sequence.chunks.slice(0, keep + 1).map((c) => c.t1));
    assert.ok(covered < whole.expected.durationSec, "the cut must actually shorten the timeline");

    const playable = await openScene(new BytesReadable(bytes));
    assert.equal(playable.duration, covered);
    assert.ok(
      playable.notes.some((note) => note.includes(`[0, ${covered})`)),
      `no note said where the chunks stop:\n${playable.notes.join("\n")}`,
    );
    await assert.rejects(
      () => playable.frameAt(whole.expected.durationSec - 1e-6),
      MalformedFile,
      "an instant past the last complete chunk must be refused, not answered with stale state",
    );
  });

  it("storage order is not time order: coverage comes from the largest t1", async () => {
    const whole = variant(source);
    const inOrder = await openScene(new BytesReadable(whole.bytes.slice()));
    const { bytes, chunkCount } = withStateChunksReversed(whole.bytes);
    assert.ok(chunkCount > 1);
    const reversed = await openScene(new BytesReadable(bytes));

    assert.equal(reversed.duration, inOrder.duration);
    assert.equal(reversed.duration, whole.expected.durationSec);
    assert.deepEqual(
      reversed.notes,
      inOrder.notes,
      "a file stored newest-first is not a truncated file",
    );
    for (const t of instantsFor(inOrder.duration)) {
      assert.deepEqual(
        digest(await reversed.frameAt(t)),
        digest(await inOrder.frameAt(t)),
        `t = ${t}: reordering storage must not change what the file means`,
      );
    }
  });

  it("a complete file whose chunks stop early is malformed, not truncated", async () => {
    const whole = variant(source);
    const duration = whole.expected.durationSec + 1;
    const bytes = withHeaderDuration(whole.bytes, duration);
    await assert.rejects(
      () => openScene(new BytesReadable(bytes)),
      (error) =>
        error instanceof MalformedFile &&
        error.message.includes(`duration_sec ${duration}`) &&
        error.message.includes("complete"),
    );
  });
});

describe("the temporal model is read from the Header, whatever size it is", () => {
  it("a keyframe-delta Header past 64 KiB still opens as keyframe-delta", async () => {
    const whole = variant("keyframe/KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics.4dgs");
    const { bytes, headerRecordBytes } = withPaddedHeader(whole.bytes, 128 * 1024);
    assert.ok(headerRecordBytes > 64 * 1024, "the padded Header must exceed a 64 KiB probe");

    const padded = await openScene(new BytesReadable(bytes));
    const plain = await openScene(new BytesReadable(whole.bytes.slice()));
    assert.equal(padded.readMode, "keyframe-delta");
    assert.equal(padded.duration, plain.duration);
    for (const t of instantsFor(plain.duration)) {
      assert.deepEqual(digest(await padded.frameAt(t)), digest(await plain.frameAt(t)), `t = ${t}`);
    }
  });

  it("refuses an oversized declared Header before a decoder requests its range", async () => {
    const declared = 64 * 1024 * 1024 + 1;
    const prefix = new Uint8Array(MAGIC.length + 9);
    prefix.set(MAGIC);
    prefix[MAGIC.length] = 0x01;
    new DataView(prefix.buffer).setBigUint64(MAGIC.length + 1, BigInt(declared), true);
    const source = {
      largestRead: 0,
      async size() {
        return BigInt(prefix.length + declared);
      },
      async read(offset, length) {
        const at = Number(offset);
        const count = Number(length);
        this.largestRead = Math.max(this.largestRead, count);
        const out = new Uint8Array(count);
        if (at < prefix.length) {
          out.set(prefix.subarray(at, Math.min(prefix.length, at + count)));
        }
        return out;
      },
    };

    await assert.rejects(
      () => openScene(source),
      (error) =>
        error instanceof ViewerLimitError &&
        error.message.includes(`declares ${declared} content bytes`),
    );
    assert.ok(source.largestRead <= 64 * 1024, `largest range read was ${source.largestRead}`);
  });
});

describe("indexed SH bands agree with the Header", () => {
  it("refuses a non-empty Chunk whose physical bands stop below Header.sh_degree", async () => {
    const whole = variant("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc.4dgs");
    const bytes = withHeaderShDegree(whole.bytes, 3);
    const playable = await openScene(new BytesReadable(bytes));
    assert.equal(playable.readMode, "indexed");
    await assert.rejects(
      () => playable.frameAt(0),
      (error) =>
        error instanceof MalformedFile &&
        error.message.includes("decodes SH degree 2") &&
        error.message.includes("Header declares SH degree 3"),
    );
  });
});
