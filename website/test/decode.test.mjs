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
  MalformedFile,
  decodeKeyframeDeltaStreamed,
  keyframeDeltaStatesJson,
  stepsFrom,
  supportK,
  lifeClass,
  motionStep,
  muStep,
} from "@4dgs/core";

import { openScene } from "../src/components/Viewer/openScene.js";
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
      // Rounded on both sides, because `expected` is the canonical statement and the
      // canonical statement rounds to six decimals — `corpus.mjs`'s own `round`. Some
      // corpus files declare a duration that is not exactly representable
      // (`ObjectOpacityOrder` declares 4.000000021908035, which the expectation states as
      // 4.0), so comparing the raw header against the rounded statement asserts that the
      // generator wrote a round number rather than that this page read the file
      // correctly.
      assert.equal(
        Math.round(indexed.duration * 1e6) / 1e6,
        Math.round(expected.durationSec * 1e6) / 1e6,
      );
      // Rounded for the same reason as the duration above, and this one shows why it
      // matters: `ObjectOpacityOrder` declares a cutoff of 1e-20, which is legal — §5.1
      // requires (0, 1] — and which the canonical statement rounds to 0. Comparing raw
      // against rounded would demand this page report a cutoff the format forbids.
      assert.equal(
        Math.round(indexed.header.cutoff * 1e6) / 1e6,
        Math.round(expected.cutoff * 1e6) / 1e6,
      );
      // The rounding above can hide a genuinely wrong cutoff, so the legality of what was
      // actually read is asserted directly rather than through the statement.
      assert.ok(
        indexed.header.cutoff > 0 && indexed.header.cutoff <= 1,
        `cutoff ${indexed.header.cutoff} is outside the (0, 1] §5.1 requires`,
      );
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
        // The sanity assertions below say "a conforming file decodes to drawable
        // numbers". The corpus has since grown variants for which that is deliberately
        // false — `ObjectTiedNonFiniteRows` carries non-finite rows on purpose, to pin
        // what a reader does with them — so asserting finiteness across every variant
        // would be asserting that the corpus does not contain the cases it was extended
        // to contain.
        //
        // Scoped by name rather than by catching the failure, so a variant that starts
        // decoding to infinities WITHOUT saying so in its name still fails here.
        //
        // The both-paths-agree check below is NOT scoped, and that is the one that
        // matters most for this page: whatever a hostile file decodes to, the indexed
        // and streamed paths must decode it the same way, non-finite rows included.
        if (!name.includes("NonFinite")) {
          assert.ok(a.finite, `t = ${t}: every centre is finite`);
          assert.ok(a.positiveScales, `t = ${t}: every scale is positive`);
          assert.ok(a.opacityInRange, `t = ${t}: every opacity is within [0, 1]`);
          assert.ok(
            a.worstQuaternion < 1e-3,
            `t = ${t}: quaternions are unit (${a.worstQuaternion})`,
          );
        }
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
      const bytes = new Uint8Array(await (await import("node:fs/promises")).readFile(file));
      const sequence = await decodeKeyframeDeltaStreamed(bytes);
      const canonical = keyframeDeltaStatesJson(sequence);
      const playable = await openScene(new FileReadable(file));
      assert.equal(playable.readMode, "keyframe-delta");
      assert.equal(playable.header.temporalModel, expected.temporalModel);
      assert.equal(playable.duration, expected.durationSec);
      assert.ok(canonical.states.length > 0, "the canonical statement probes at least one instant");

      for (const row of canonical.states) {
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
        // Compared with a tolerance rather than exactly, because the two sides are not
        // the same precision and are not supposed to be. The canonical statement is
        // computed in float64; this page's frame is float32, because that is what it
        // hands a GPU. Summing `count` float32 values and demanding the total match a
        // float64 sum to six decimals is asserting a property neither format nor
        // renderer offers — it held only while the numbers happened to be small.
        //
        // The bound scales with the population: each term carries up to a float32 ulp of
        // error, and they accumulate. Anything larger than that is a real disagreement
        // about what is in the frame, which is what this test is for.
        const tolerance = Math.max(1e-6, frame.count * 1e-6);
        for (const [axis, got, want] of [
          ["x", px, row.aggregate.positionSum[0]],
          ["y", py, row.aggregate.positionSum[1]],
          ["z", pz, row.aggregate.positionSum[2]],
        ]) {
          assert.ok(
            Math.abs(got - want) <= tolerance * Math.max(1, Math.abs(want)),
            `positionSum.${axis} at t = ${row.t}: ${got} vs ${want}`,
          );
        }
        assert.ok(
          Math.abs(opacity - Number(row.aggregate.opacitySum)) <= tolerance,
          `opacitySum at t = ${row.t}: ${opacity} vs ${row.aggregate.opacitySum}`,
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
});

// §3's keyframe-delta window and cutoff gating used to be checked here, by composing a
// chunk and reading its raw bin columns through `state.column()` to compute the expected
// marginals independently.
//
// `@4dgs/core` has since made composed bins private — deliberately, and it says why at
// `binsOf`: "Composed bins are not public API. A consumer reads reconstructed values
// through reconstructKeyframeDelta, and this file is the only holder of this reader. The
// class used to publish a `column()` method marked `@internal`, which is a comment where
// a language feature will do."
//
// Both properties are now core's own, and core tests them on its own terms:
// `typescript/conformance/src/keyframeDeltaHardening.test.ts` has "a gaussian whose
// validity window has closed is absent, not transparent" and "a gaussian below the
// temporal marginal cutoff is absent inside its window".
//
// Reaching around a privacy boundary to re-test someone else's invariant is how a suite
// ends up pinned to another module's internals, so these are dropped rather than ported.
// What belongs here is what the VIEWER does with a reconstructed frame, which the
// surrounding blocks cover.

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
    // Not compared note for note. `withStateChunksReversed` moves the chunk bytes without
    // rewriting the Chunk Index offsets that point at them, so the reversed file has a
    // stale index and is read front to back, while the untouched file is read by range.
    // Both are correct and they say so differently.
    //
    // What this test is actually about is that storing newest-first does not look like
    // truncation, so that is what is asserted — on both files, since the claim is about
    // neither of them being cut.
    for (const [label, playable] of [
      ["reversed", reversed],
      ["in order", inOrder],
    ]) {
      assert.ok(
        !playable.notes.some((line) => line.includes("cut")),
        `${label}: a file stored newest-first is not a truncated file:\n${playable.notes.join("\n")}`,
      );
    }
    for (const t of instantsFor(inOrder.duration)) {
      assert.deepEqual(
        digest(await reversed.frameAt(t)),
        digest(await inOrder.frameAt(t)),
        `t = ${t}: reordering storage must not change what the file means`,
      );
    }
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
});
