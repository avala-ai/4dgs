// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Fuzzing the decoder against bytes it did not write.
 *
 * The invariant, and the whole point: **for any input at all, the decoder either succeeds
 * or throws `FourdgsError`.** Never a `RangeError` from a transport, never an
 * out-of-memory, never a hang. A decoder parses untrusted bytes, so "it crashed" and "it
 * refused" are different outcomes for whoever is running it, and only one is acceptable.
 *
 * The mutations are the Python fuzzer's, seed for seed. `tests/fuzz/regressions.json`
 * lists the inputs that have found something; those run every time, forever.
 */

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  BytesReadable,
  decodeScene,
  FourdgsError,
  IndexedDecoder,
  MAX_SH_DEGREE,
} from "@4dgs/core";

import { mutate, OPERATORS, Rng, type Operator } from "./fuzz.js";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));
const FUZZ_DIR = fileURLToPath(new URL("../../../tests/fuzz/", import.meta.url));

/** Inputs per run. CI turns this up; the default keeps `yarn test` quick. */
const ITERATIONS = Number(process.env["FOURDGS_FUZZ_ITERATIONS"] ?? "400");

/** No single input may take longer than this. */
const PER_INPUT_MS = Number(process.env["FOURDGS_FUZZ_MS"] ?? "5000");

const SEED_BASE = 0x4d473500;

/**
 * The corpus, or a failure.
 *
 * A missing corpus is not a reason to skip. The fuzzer mutates real files, so without
 * them it tests nothing — and a fuzz run that quietly tested nothing is worse than no
 * fuzz run at all, because it reports the same green.
 */
function corpus(): Uint8Array[] {
  const names = existsSync(DATA)
    ? readdirSync(DATA)
        .filter((name) => name.endsWith(".4dgs"))
        .sort()
    : [];
  assert.ok(
    names.length > 0,
    `no corpus in ${DATA}; run tests/conformance/generate.py first. ` +
      "The fuzzer mutates real files, so an empty corpus is an empty run.",
  );
  return names.map((name) => new Uint8Array(readFileSync(DATA + name)));
}

/** The corpus file names, in the same order `corpus()` returns their bytes. */
function corpusNames(): string[] {
  return readdirSync(DATA)
    .filter((name) => name.endsWith(".4dgs"))
    .sort();
}

/** Everything a consumer would do with an untrusted file, on both read paths. */
async function decodeEveryWay(data: Uint8Array): Promise<void> {
  const scene = await decodeScene(data, { blockSize: 4096 });
  scene.gaussians.stateAt(0.5, scene.header.cutoff);

  const indexed = await IndexedDecoder.open(new BytesReadable(data));
  indexed.chunksForTime(0.5);
  indexed.bytesForTime(0.5, MAX_SH_DEGREE);
  for (const entry of indexed.index) {
    await indexed.readChunk(entry, { maxShBand: MAX_SH_DEGREE });
  }
  await indexed.readAudio();
  await indexed.readCamera();
  await indexed.readMetadata();
  await indexed.readAttachments();
}

/** The invariant: succeed, or throw this package's own error. Nothing else. */
async function check(data: Uint8Array, label: string): Promise<void> {
  const started = performance.now();
  try {
    await decodeEveryWay(data);
  } catch (error) {
    if (!(error instanceof FourdgsError)) {
      const shown = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      assert.fail(`${label}: ${shown}`);
    }
    // A diagnosis is a pass. That is the whole contract.
  }
  const elapsed = performance.now() - started;
  assert.ok(
    elapsed < PER_INPUT_MS,
    `${label}: took ${elapsed.toFixed(0)}ms, over the ${PER_INPUT_MS}ms ceiling`,
  );
}

interface RegressionCase {
  name: string;
  variant: string;
  operator: Operator;
  seed: number;
  found: string;
}

function regressions(): RegressionCase[] {
  const path = `${FUZZ_DIR}regressions.json`;
  if (!existsSync(path)) return [];
  return JSON.parse(readFileSync(path, "utf8")).cases as RegressionCase[];
}

test("the corpus itself decodes", async () => {
  for (const data of corpus()) await decodeEveryWay(data);
});

test("mutations are refused rather than crashing", async () => {
  const bases = corpus();
  for (let i = 0; i < ITERATIONS; i++) {
    const seed = SEED_BASE + i;
    const rng = new Rng(seed);
    const base = bases[rng.below(bases.length)]!;
    const operator = OPERATORS[rng.below(OPERATORS.length)]!;
    await check(mutate(base, operator, rng), `seed=0x${seed.toString(16)} op=${operator}`);
  }
});

test("pure noise is refused", async () => {
  for (let i = 0; i < 200; i++) {
    const seed = 0x0150e000 + i;
    const rng = new Rng(seed);
    await check(
      mutate(new Uint8Array(0), "random_bytes", rng),
      `noise seed=0x${seed.toString(16)}`,
    );
  }
});

test("a prefix of every length is refused", async () => {
  const bases = corpus();
  const data = bases[0]!;
  const step = Math.max(1, Math.floor(data.length / 200));
  for (let cut = 0; cut < data.length; cut += step) {
    await check(data.subarray(0, cut), `prefix=${cut}`);
  }
});

/**
 * A generator positioned exactly where the fuzz loop positions it.
 *
 * The loop draws twice before mutating — once for the base file, once for the operator —
 * so a recorded case has to draw twice too, or it reproduces different bytes. The two
 * values are discarded rather than used: the case records the variant and the operator by
 * name, which is what keeps it reproducing the same input after the corpus grows.
 */
function replay(seed: number, baseCount: number): Rng {
  const rng = new Rng(seed);
  rng.below(Math.max(baseCount, 1));
  rng.below(OPERATORS.length);
  return rng;
}

test("recorded regressions stay fixed", async () => {
  const bases = corpus();
  const names = corpusNames();
  const cases = regressions();
  assert.ok(
    cases.length > 0,
    "tests/fuzz/regressions.json is empty; every crash the fuzzer found belongs in it",
  );
  for (const one of cases) {
    const index = names.findIndex((n) => n.includes(one.variant));
    assert.ok(index >= 0, `regression names a variant that is not in the corpus: ${one.variant}`);
    await check(
      mutate(bases[index]!, one.operator, replay(one.seed, bases.length)),
      `regression ${one.name}`,
    );
  }
});
