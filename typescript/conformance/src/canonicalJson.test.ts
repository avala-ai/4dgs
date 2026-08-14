// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";

import { comparableCanonicalJson } from "./canonicalJson.js";

test("lossless JSON comparison normalizes spelling without narrowing numbers", () => {
  const huge = "1".padEnd(310, "0");
  const reference = comparableCanonicalJson(
    `{ "aggregate": ${huge}.0, "ordinary": 1.0, "zero": -0.0 }`,
  );

  assert.equal(
    comparableCanonicalJson(`{"aggregate": 1e309, "ordinary": 1, "zero": 0}`),
    reference,
  );
  assert.notEqual(
    comparableCanonicalJson(`{"aggregate": ${huge.slice(0, -1)}1.0, "ordinary": 1, "zero": 0}`),
    reference,
  );
  assert.notEqual(
    comparableCanonicalJson(`{"aggregate": 1e309, "ordinary": 2, "zero": 0}`),
    reference,
  );
});
