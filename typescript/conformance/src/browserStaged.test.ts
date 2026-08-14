// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import test from "node:test";

import { stagedBrowserSummary } from "./browserStaged.js";

const summary = () => ({
  aggregate: { opacitySum: 1.25, neverFadesCount: "1" },
  gaussianCount: "2",
  states: [
    {
      t: 1.5,
      aggregate: { opacitySum: 0.75, contributingCount: "2" },
      liveCount: "2",
      sample: { positions: [[1]] },
    },
  ],
});

test("the staged browser comparison omits only transitional canonical fields", () => {
  const reference = stagedBrowserSummary(JSON.stringify(summary()));
  const transitional = summary();
  transitional.aggregate.opacitySum = 9.5;
  transitional.states[0].aggregate.opacitySum = 0.5;
  transitional.states[0].sample = { positions: [[9]] };

  assert.deepEqual(stagedBrowserSummary(JSON.stringify(transitional)), reference);
});

test("the staged browser comparison keeps counters and other state fields strict", () => {
  const reference = stagedBrowserSummary(JSON.stringify(summary()));
  for (const mutate of [
    (value: ReturnType<typeof summary>) => (value.gaussianCount = "3"),
    (value: ReturnType<typeof summary>) => (value.aggregate.neverFadesCount = "0"),
    (value: ReturnType<typeof summary>) => (value.states[0].t = 2.5),
    (value: ReturnType<typeof summary>) => (value.states[0].liveCount = "3"),
    (value: ReturnType<typeof summary>) => (value.states[0].aggregate.contributingCount = "3"),
  ]) {
    const changed = summary();
    mutate(changed);
    assert.notDeepEqual(stagedBrowserSummary(JSON.stringify(changed)), reference);
  }
});
