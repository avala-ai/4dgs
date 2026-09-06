// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const CATALOG_URL = new URL("../static/conformance/results.json", import.meta.url);
const INVALID_VARIANT_COUNT = 11;

const EXPECTED_CORPUS = Object.freeze({
  version: "0.1.0",
  tag: "releases/corpus/v0.1.0",
  tagCommit: "d9a76528560496b06f4d9baa25d53c3d944537d8",
  manifestSchema: 1,
  archiveUrl:
    "https://github.com/avala-ai/4dgs/releases/download/releases%2Fcorpus%2Fv0.1.0/4dgs-conformance-corpus-0.1.0.tar.gz",
  archiveSha256: "a147df71cb13eebb42997a5b3e6433b1e27e572a891bd1b28d9db7572b63ac3c",
  variantCount: 74,
  indexedVariantCount: 73,
});

const ROOT_KEYS = ["schemaVersion", "corpus", "results"];
const CORPUS_KEYS = Object.keys(EXPECTED_CORPUS);
const RESULT_KEYS = ["id", "implementation", "runnerArtifact", "corpusVersion", "run", "runners"];
const IMPLEMENTATION_KEYS = ["name", "version", "language", "url"];
const ARTIFACT_KEYS = ["url", "sha256"];
const RUN_KEYS = ["date", "platform", "evidenceUrl", "evidenceSha256", "reproduceUrl"];
const RUNNER_KEYS = [
  "protocol",
  "name",
  "family",
  "readPath",
  "refusals",
  "declines",
  "exactAggregates",
  "canonicalStateOrder",
  "aggregateDecodedBudget",
  "lateFrontMatterRecords",
  "optionalIdentityDefaults",
  "command",
  "passed",
  "skipped",
  "failed",
];

export class CatalogValidationError extends Error {
  constructor(path, message) {
    super(`${path}: ${message}`);
    this.name = "CatalogValidationError";
  }
}

function fail(path, message) {
  throw new CatalogValidationError(path, message);
}

function assertObject(value, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail(path, "expected an object");
  }
}

function assertExactKeys(value, expected, path) {
  assertObject(value, path);
  const expectedSet = new Set(expected);
  const missing = expected.filter((key) => !Object.hasOwn(value, key));
  const extra = Object.keys(value).filter((key) => !expectedSet.has(key));
  if (missing.length > 0) {
    fail(path, `missing ${missing.map((key) => JSON.stringify(key)).join(", ")}`);
  }
  if (extra.length > 0) {
    fail(path, `unknown ${extra.map((key) => JSON.stringify(key)).join(", ")}`);
  }
}

function assertString(value, path) {
  if (typeof value !== "string" || value.trim() === "") {
    fail(path, "expected a non-empty string");
  }
}

function assertBoolean(value, path) {
  if (typeof value !== "boolean") {
    fail(path, "expected true or false");
  }
}

function assertInteger(value, path) {
  if (!Number.isInteger(value) || value < 0) {
    fail(path, "expected a non-negative integer");
  }
}

function assertSha256(value, path) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    fail(path, "expected a lowercase 64-digit SHA-256");
  }
}

function assertHttpsUrl(value, path) {
  assertString(value, path);
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(path, "expected an absolute HTTPS URL");
  }
  if (parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "") {
    fail(path, "expected an absolute HTTPS URL without credentials");
  }
}

function assertDate(value, path) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    fail(path, "expected a calendar date in YYYY-MM-DD form");
  }
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  if (
    parsed.getUTCFullYear() !== year ||
    parsed.getUTCMonth() !== month - 1 ||
    parsed.getUTCDate() !== day
  ) {
    fail(path, "expected a real calendar date in YYYY-MM-DD form");
  }
}

function validateCorpus(corpus) {
  assertExactKeys(corpus, CORPUS_KEYS, "catalog.corpus");
  for (const [key, expected] of Object.entries(EXPECTED_CORPUS)) {
    if (corpus[key] !== expected) {
      fail(`catalog.corpus.${key}`, `expected ${JSON.stringify(expected)}`);
    }
  }
}

function validateImplementation(implementation, path) {
  assertExactKeys(implementation, IMPLEMENTATION_KEYS, path);
  assertString(implementation.name, `${path}.name`);
  assertString(implementation.version, `${path}.version`);
  assertString(implementation.language, `${path}.language`);
  assertHttpsUrl(implementation.url, `${path}.url`);
}

function validateArtifact(artifact, path) {
  assertExactKeys(artifact, ARTIFACT_KEYS, path);
  assertHttpsUrl(artifact.url, `${path}.url`);
  assertSha256(artifact.sha256, `${path}.sha256`);
}

function validateRun(run, path) {
  assertExactKeys(run, RUN_KEYS, path);
  assertDate(run.date, `${path}.date`);
  assertString(run.platform, `${path}.platform`);
  assertHttpsUrl(run.evidenceUrl, `${path}.evidenceUrl`);
  assertSha256(run.evidenceSha256, `${path}.evidenceSha256`);
  assertHttpsUrl(run.reproduceUrl, `${path}.reproduceUrl`);
}

function validateRunner(runner, path, corpus) {
  assertExactKeys(runner, RUNNER_KEYS, path);
  if (runner.protocol !== 1 || typeof runner.protocol !== "number") {
    fail(`${path}.protocol`, "expected the integer 1");
  }
  assertString(runner.family, `${path}.family`);
  if (runner.readPath !== "streamed" && runner.readPath !== "indexed") {
    fail(`${path}.readPath`, 'expected "streamed" or "indexed"');
  }
  const expectedName = `${runner.family}/decode_${runner.readPath}`;
  if (runner.name !== expectedName) {
    fail(`${path}.name`, `expected ${JSON.stringify(expectedName)}`);
  }
  assertBoolean(runner.refusals, `${path}.refusals`);
  if (!Array.isArray(runner.declines)) {
    fail(`${path}.declines`, "expected an array of name fragments");
  }
  const declines = new Set();
  runner.declines.forEach((decline, index) => {
    assertString(decline, `${path}.declines[${index}]`);
    if (declines.has(decline)) {
      fail(`${path}.declines[${index}]`, `duplicate name fragment ${JSON.stringify(decline)}`);
    }
    declines.add(decline);
  });
  assertBoolean(runner.exactAggregates, `${path}.exactAggregates`);
  assertBoolean(runner.canonicalStateOrder, `${path}.canonicalStateOrder`);
  assertBoolean(runner.aggregateDecodedBudget, `${path}.aggregateDecodedBudget`);
  assertBoolean(runner.lateFrontMatterRecords, `${path}.lateFrontMatterRecords`);
  assertBoolean(runner.optionalIdentityDefaults, `${path}.optionalIdentityDefaults`);
  if (runner.lateFrontMatterRecords && !runner.refusals) {
    fail(`${path}.lateFrontMatterRecords`, "cannot be true when refusals is false");
  }
  assertString(runner.command, `${path}.command`);
  assertInteger(runner.passed, `${path}.passed`);
  assertInteger(runner.skipped, `${path}.skipped`);
  assertInteger(runner.failed, `${path}.failed`);

  const accounted = runner.passed + runner.skipped + runner.failed;
  if (accounted !== corpus.variantCount) {
    fail(
      path,
      `passed + skipped + failed is ${accounted}; expected ${corpus.variantCount} harness variants`,
    );
  }
  if (runner.failed !== 0) {
    fail(`${path}.failed`, "published results must have no failed variants");
  }
  const eligible = runner.readPath === "indexed" ? corpus.indexedVariantCount : corpus.variantCount;
  if (runner.passed > eligible) {
    fail(`${path}.passed`, `cannot exceed the ${eligible} ${runner.readPath} variants eligible`);
  }
  const ineligibleForPath = runner.readPath === "indexed" ? corpus.variantCount - eligible : 0;
  const requiredSkips = ineligibleForPath + (runner.refusals ? 0 : INVALID_VARIANT_COUNT);
  if (runner.skipped < requiredSkips) {
    fail(
      `${path}.skipped`,
      `expected at least ${requiredSkips} skips for this read path and refusal declaration`,
    );
  }
  if (runner.declines.length === 0 && runner.skipped !== requiredSkips) {
    fail(
      `${path}.skipped`,
      `expected exactly ${requiredSkips} skips when no valid variant is declined`,
    );
  }
}

function validateResult(result, index, corpus) {
  const path = `catalog.results[${index}]`;
  assertExactKeys(result, RESULT_KEYS, path);
  if (
    typeof result.id !== "string" ||
    !/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(result.id) ||
    result.id.length > 120
  ) {
    fail(
      `${path}.id`,
      "expected a lowercase stable id of at most 120 letters, digits, dots, dashes or underscores",
    );
  }
  validateImplementation(result.implementation, `${path}.implementation`);
  validateArtifact(result.runnerArtifact, `${path}.runnerArtifact`);
  if (result.corpusVersion !== corpus.version) {
    fail(`${path}.corpusVersion`, `expected ${JSON.stringify(corpus.version)}`);
  }
  validateRun(result.run, `${path}.run`);
  if (!Array.isArray(result.runners) || result.runners.length < 1 || result.runners.length > 2) {
    fail(`${path}.runners`, "expected one or two runner results");
  }
  const readPaths = new Set();
  const families = new Set();
  result.runners.forEach((runner, runnerIndex) => {
    const runnerPath = `${path}.runners[${runnerIndex}]`;
    validateRunner(runner, runnerPath, corpus);
    if (readPaths.has(runner.readPath)) {
      fail(`${runnerPath}.readPath`, `duplicate ${JSON.stringify(runner.readPath)} result`);
    }
    readPaths.add(runner.readPath);
    families.add(runner.family);
  });
  if (families.size !== 1) {
    fail(`${path}.runners`, "all runners for an implementation must declare the same family");
  }
}

export function validateCatalog(catalog) {
  assertExactKeys(catalog, ROOT_KEYS, "catalog");
  if (catalog.schemaVersion !== 1 || typeof catalog.schemaVersion !== "number") {
    fail("catalog.schemaVersion", "expected the integer 1");
  }
  validateCorpus(catalog.corpus);
  if (!Array.isArray(catalog.results)) {
    fail("catalog.results", "expected an array");
  }
  const ids = new Set();
  let previousId = "";
  catalog.results.forEach((result, index) => {
    validateResult(result, index, catalog.corpus);
    if (ids.has(result.id)) {
      fail(`catalog.results[${index}].id`, `duplicate id ${JSON.stringify(result.id)}`);
    }
    if (result.id < previousId) {
      fail(`catalog.results[${index}].id`, "results must be sorted by id");
    }
    ids.add(result.id);
    previousId = result.id;
  });
  return catalog;
}

export function readAndValidateCatalog(url = CATALOG_URL) {
  let catalog;
  try {
    catalog = JSON.parse(readFileSync(url, "utf8"));
  } catch (error) {
    throw new CatalogValidationError("catalog", `could not read JSON: ${error.message}`);
  }
  return validateCatalog(catalog);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const catalog = readAndValidateCatalog();
    console.log(
      `validated ${catalog.results.length} independent conformance result(s) for corpus ${catalog.corpus.version}`,
    );
  } catch (error) {
    console.error(`conformance results validation failed: ${error.message}`);
    process.exitCode = 1;
  }
}
