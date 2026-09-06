// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { validateCatalog } from "./validate-conformance-results.mjs";

const catalog = JSON.parse(
  readFileSync(new URL("../static/conformance/results.json", import.meta.url), "utf8"),
);

const SHA_A = "a".repeat(64);
const SHA_B = "b".repeat(64);

function runner(readPath, counts) {
  return {
    protocol: 1,
    name: `example/decode_${readPath}`,
    family: "example",
    readPath,
    refusals: true,
    declines: [],
    exactAggregates: true,
    canonicalStateOrder: true,
    aggregateDecodedBudget: true,
    lateFrontMatterRecords: true,
    command: `./decode_${readPath}`,
    ...counts,
  };
}

function result(id = "example-1.2.3") {
  return {
    id,
    implementation: {
      name: "Example 4DGS",
      version: "1.2.3",
      language: "ExampleLang",
      url: "https://example.com/source/tree/0123456789abcdef",
    },
    runnerArtifact: {
      url: "https://example.com/releases/runner-1.2.3.tar.gz",
      sha256: SHA_A,
    },
    corpusVersion: "0.1.0",
    run: {
      date: "2026-09-05",
      platform: "ExampleOS 1.0, example64",
      evidenceUrl: "https://example.com/results/1.2.3.txt",
      evidenceSha256: SHA_B,
      reproduceUrl: "https://example.com/source/blob/0123456789abcdef/CONFORMANCE.md",
    },
    runners: [
      runner("streamed", { passed: 74, skipped: 0, failed: 0 }),
      runner("indexed", { passed: 73, skipped: 1, failed: 0 }),
    ],
  };
}

function withResults(...results) {
  return { ...structuredClone(catalog), results };
}

test("the published empty catalog is valid", () => {
  assert.equal(validateCatalog(structuredClone(catalog)).results.length, 0);
});

test("a complete two-path result is valid", () => {
  assert.equal(validateCatalog(withResults(result())).results[0].runners.length, 2);
});

test("an honest partial, one-path result is valid", () => {
  const partial = result();
  partial.runners = [
    {
      ...runner("streamed", { passed: 51, skipped: 23, failed: 0 }),
      refusals: false,
      declines: ["WithObjects", "SHDegree3"],
      exactAggregates: false,
      canonicalStateOrder: false,
      aggregateDecodedBudget: false,
      lateFrontMatterRecords: false,
    },
  ];
  assert.equal(validateCatalog(withResults(partial)).results[0].runners[0].passed, 51);
});

const invalidCases = [
  ["unknown catalog keys", (value) => (value.extra = true), /catalog: unknown "extra"/],
  [
    "wrong corpus identity",
    (value) => (value.corpus.archiveSha256 = SHA_A),
    /catalog\.corpus\.archiveSha256: expected/,
  ],
  [
    "unknown result keys",
    (value) => (value.results[0].endorsement = true),
    /catalog\.results\[0\]: unknown "endorsement"/,
  ],
  [
    "duplicate ids",
    (value) => value.results.push(structuredClone(value.results[0])),
    /catalog\.results\[1\]\.id: duplicate id/,
  ],
  [
    "unsorted ids",
    (value) => {
      value.results.push(result("alpha-1.0.0"));
    },
    /catalog\.results\[1\]\.id: results must be sorted/,
  ],
  [
    "unknown corpus versions",
    (value) => (value.results[0].corpusVersion = "0.2.0"),
    /corpusVersion: expected "0\.1\.0"/,
  ],
  [
    "malformed evidence hashes",
    (value) => (value.results[0].run.evidenceSha256 = "not-a-hash"),
    /evidenceSha256: expected a lowercase 64-digit SHA-256/,
  ],
  [
    "non-HTTPS evidence URLs",
    (value) => (value.results[0].run.evidenceUrl = "http://example.com/result.txt"),
    /evidenceUrl: expected an absolute HTTPS URL without credentials/,
  ],
  [
    "impossible calendar dates",
    (value) => (value.results[0].run.date = "2026-02-30"),
    /run\.date: expected a real calendar date/,
  ],
  [
    "boolean protocol versions",
    (value) => (value.results[0].runners[0].protocol = true),
    /protocol: expected the integer 1/,
  ],
  [
    "non-boolean aggregate budget capabilities",
    (value) => (value.results[0].runners[0].aggregateDecodedBudget = 1),
    /aggregateDecodedBudget: expected true or false/,
  ],
  [
    "non-boolean late front matter capabilities",
    (value) => (value.results[0].runners[0].lateFrontMatterRecords = 1),
    /lateFrontMatterRecords: expected true or false/,
  ],
  [
    "late front matter without refusal diagnosis",
    (value) => (value.results[0].runners[0].refusals = false),
    /lateFrontMatterRecords: cannot be true when refusals is false/,
  ],
  [
    "runner identity mismatches",
    (value) => (value.results[0].runners[0].name = "other/decode_streamed"),
    /runners\[0\]\.name: expected "example\/decode_streamed"/,
  ],
  [
    "duplicate read paths",
    (value) => {
      value.results[0].runners[1] = runner("streamed", {
        passed: 74,
        skipped: 0,
        failed: 0,
      });
    },
    /runners\[1\]\.readPath: duplicate "streamed" result/,
  ],
  [
    "mixed runner families",
    (value) => {
      value.results[0].runners[1].family = "other";
      value.results[0].runners[1].name = "other/decode_indexed";
    },
    /all runners for an implementation must declare the same family/,
  ],
  [
    "unaccounted variants",
    (value) => (value.results[0].runners[0].skipped = 1),
    /passed \+ skipped \+ failed is 75; expected 74 harness variants/,
  ],
  [
    "published failures",
    (value) => {
      value.results[0].runners[0].passed = 73;
      value.results[0].runners[0].failed = 1;
    },
    /failed: published results must have no failed variants/,
  ],
  [
    "too many indexed passes",
    (value) => {
      value.results[0].runners[1].passed = 74;
      value.results[0].runners[1].skipped = 0;
    },
    /passed: cannot exceed the 73 indexed variants eligible/,
  ],
  [
    "refusal declarations inconsistent with skips",
    (value) => {
      value.results[0].runners = [
        {
          ...runner("streamed", { passed: 74, skipped: 0, failed: 0 }),
          refusals: false,
          lateFrontMatterRecords: false,
        },
      ];
    },
    /skipped: expected at least 11 skips for this read path and refusal declaration/,
  ],
  [
    "unexplained skips without declines",
    (value) => {
      value.results[0].runners = [runner("streamed", { passed: 73, skipped: 1, failed: 0 })];
    },
    /skipped: expected exactly 0 skips when no valid variant is declined/,
  ],
  [
    "duplicate decline fragments",
    (value) => (value.results[0].runners[0].declines = ["WithObjects", "WithObjects"]),
    /declines\[1\]: duplicate name fragment/,
  ],
  [
    "empty runner lists",
    (value) => (value.results[0].runners = []),
    /runners: expected one or two runner results/,
  ],
];

for (const [name, mutate, expected] of invalidCases) {
  test(`rejects ${name}`, () => {
    const value = withResults(result());
    mutate(value);
    assert.throws(() => validateCatalog(value), expected);
  });
}
