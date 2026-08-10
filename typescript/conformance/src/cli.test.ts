// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The `4dgs` command-line tool.
 *
 * Driven through `main` with an injected sink, so what the tests read is exactly what a
 * user reads — the same lines, in the same order, with the same exit code. A CLI checked by
 * calling the functions underneath it proves the library and nothing about the tool.
 *
 * The corpus files these need are generated rather than committed. When they are absent the
 * corpus tests skip and say so; CI generates first, so a skip there is a failure of the
 * workflow rather than of the code.
 */

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  EXIT_FAILED,
  EXIT_OK,
  EXIT_TOOL_FAILED,
  EXIT_WARNINGS,
  VERSION,
  main,
  type Sink,
} from "@4dgs/nodejs/cli";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));

function corpus(variant: string): string | null {
  const path = `${DATA}${variant}.4dgs`;
  return existsSync(path) ? path : null;
}

interface Run {
  readonly code: number;
  readonly out: string[];
  readonly err: string[];
}

async function run(...argv: string[]): Promise<Run> {
  const out: string[] = [];
  const err: string[] = [];
  const sink: Sink = { out: (line) => out.push(line), err: (line) => err.push(line) };
  return { code: await main(argv, sink), out, err };
}

/** A copy of `variant` cut to `bytes`, in a directory the test owns. */
function truncatedCopy(path: string, bytes: number): string {
  const directory = mkdtempSync(join(tmpdir(), "fourdgs-cli-"));
  const cut = join(directory, "Truncated.4dgs");
  writeFileSync(cut, readFileSync(path).subarray(0, bytes));
  return cut;
}

test("--help is a request that was served, not a failure", async () => {
  const help = await run("--help");
  assert.equal(help.code, EXIT_OK);
  assert.ok(help.out.join("\n").includes("4dgs inspect <file>"));
  assert.equal((await run("--version")).out.join(""), VERSION);
});

test("the declared version is the package's own", () => {
  // The tool prints a version it holds as a constant, because importing `package.json` from
  // a composite project drags the manifest into the build output. That is only safe while
  // something checks the two agree.
  const manifest = JSON.parse(
    readFileSync(fileURLToPath(new URL("../../nodejs/package.json", import.meta.url)), "utf8"),
  ) as { version: string };
  assert.equal(VERSION, manifest.version);
});

test("a tool failure and a refused file get different exit codes", async () => {
  // The whole point of the third code. A pipeline that sees 1 for both cannot tell "your
  // file is not conforming" from "the validator is broken", and those need opposite
  // reactions from whoever is holding the file.
  assert.equal((await run("frobnicate", "x")).code, EXIT_TOOL_FAILED);
  assert.equal((await run("validate")).code, EXIT_TOOL_FAILED);
  assert.equal((await run("inspect", "--decode", "x")).code, EXIT_TOOL_FAILED);
  const missing = await run("validate", join(tmpdir(), "no-such-file-4dgs-cli.4dgs"));
  assert.equal(missing.code, EXIT_TOOL_FAILED);
  assert.ok(missing.err.join("\n").includes("ENOENT"));
});

test("a file that is not ours is refused by name, at the byte it fired at", async () => {
  const directory = mkdtempSync(join(tmpdir(), "fourdgs-cli-"));
  const path = join(directory, "notours.bin");
  writeFileSync(path, "this is not a 4dgs file at all");
  const inspected = await run("inspect", path);
  assert.equal(inspected.code, EXIT_FAILED);
  assert.ok(
    inspected.err.some((line) => line.includes("refused: magic-mismatch at byte 0")),
    inspected.err.join("\n"),
  );
  const validated = await run("validate", path);
  assert.equal(validated.code, EXIT_FAILED);
  assert.ok(validated.out.some((line) => line.startsWith("refused: magic-mismatch at byte 0")));
});

test("the walk names every record, in order, covering the whole file", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");

  const inspected = await run("inspect", path);
  assert.equal(inspected.code, EXIT_OK);
  const { records, size, trailing_magic, stopped } = parseJson(
    await run("inspect", "--json", path),
  );
  assert.equal(stopped, null);
  assert.equal(trailing_magic, true);
  assert.equal(records[0]!.name, "Header");
  assert.equal(records.at(-1)!.name, "Footer");

  // Contiguous from the leading magic to the trailing one: a walk that skipped a byte, or
  // double-counted one, would still print a plausible-looking table.
  let at = 8;
  for (const record of records) {
    assert.equal(record.offset, at, `record at ${record.offset} does not follow the one before`);
    assert.equal(record.total_length, record.content_length + 9);
    at += record.total_length;
  }
  assert.equal(at, size - 8);

  // Every line of the text table is one of the records, plus the two magic lines.
  const rows = inspected.out.filter((line) => /^ +[\d,]+ {2}\S/.test(line));
  assert.equal(rows.length, records.length + 2);
});

test("the summary checksum is reported per record and as a verdict", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");

  const clean = parseJson(await run("inspect", "--json", path));
  assert.equal(clean.summary_crc!.ok, true);
  assert.equal(clean.summary_crc!.declared, clean.summary_crc!.actual);
  // Exactly the records inside the declared range, and nothing else.
  for (const record of clean.records) {
    const inside =
      record.offset >= clean.summary_crc!.start && record.offset < clean.summary_crc!.end;
    assert.equal(record.crc_covered, inside, `${record.name} at ${record.offset}`);
  }
  assert.ok(clean.records.some((record) => record.crc_covered));

  // One byte inside the first covered record. The framing still walks; only the checksum
  // can notice, which is what the column is for.
  const directory = mkdtempSync(join(tmpdir(), "fourdgs-cli-"));
  const corrupted = join(directory, "BadCrc.4dgs");
  const bytes = readFileSync(path);
  bytes[clean.summary_crc!.start + 9 + 4] ^= 0xff;
  writeFileSync(corrupted, bytes);

  const walked = await run("inspect", corrupted);
  assert.equal(walked.code, EXIT_FAILED);
  assert.ok(walked.out.some((line) => line.startsWith("summary crc    MISMATCH")));
  assert.ok(walked.out.some((line) => line.trimEnd().endsWith("MISMATCH")));

  const validated = await run("validate", corrupted);
  assert.equal(validated.code, EXIT_FAILED);
  assert.ok(
    validated.out.includes(
      "error: summary CRC mismatch: the index is untrustworthy (a streamed read still works)",
    ),
  );
});

/**
 * The corpus already knows the right answer for each of these, which is what makes it
 * evidence rather than a restatement of what the tool does.
 */
const REFUSALS: readonly (readonly [string, string])[] = [
  ["BadMagic", "magic-mismatch"],
  ["FutureMajorVersion", "unsupported-major-version"],
  ["EmptyTemporalModel", "unknown-temporal-model"],
  ["UnknownTemporalModel", "unknown-temporal-model"],
  ["UnknownQuantizationScheme", "unknown-quantization-scheme"],
  ["UnknownStreamCodec", "unknown-stream-codec"],
  ["WindowIndexOutOfRange", "window-index-out-of-range"],
];

test("every deliberately broken file is refused by its own identifier and byte", async (t) => {
  for (const [variant, code] of REFUSALS) {
    const path = corpus(`invalid/${variant}`);
    if (path === null) return t.skip("corpus not generated");

    const validated = await run("validate", "--decode", path);
    assert.equal(validated.code, EXIT_FAILED, variant);
    const refusal = validated.out.find((line) => line.startsWith("refused: "));
    assert.ok(refusal !== undefined, `${variant} named no refusal:\n${validated.out.join("\n")}`);
    const match = /^refused: (\S+) at byte (\d+) \((.+)\)$/.exec(refusal);
    assert.ok(match !== null, `${variant}: ${refusal}`);
    assert.equal(match[1], code, variant);
    // The byte is a real place in this file, not a placeholder.
    const size = readFileSync(path).length;
    assert.ok(Number(match[2]) >= 0 && Number(match[2]) < size, `${variant}: ${refusal}`);
    assert.equal(validated.err.at(-1), "INVALID", variant);
  }
});

test("the structural verdict is the Python validator's, and --decode is a superset", async (t) => {
  // Two refusals live inside a chunk's attribute streams, where no amount of framing
  // reaches them. The Python validator calls both of these files valid, because
  // structurally they are; the default answers the same so that two validators do not
  // disagree about one file, and `--decode` is what asks the harder question.
  for (const variant of ["UnknownStreamCodec", "WindowIndexOutOfRange"]) {
    const path = corpus(`invalid/${variant}`);
    if (path === null) return t.skip("corpus not generated");
    const structural = await run("validate", path);
    assert.equal(structural.code, EXIT_OK, variant);
    assert.equal(structural.out.at(-1), "valid", variant);
    assert.equal((await run("validate", "--decode", path)).code, EXIT_FAILED, variant);
  }
});

test("a truncated file reports what was decodable and that it was cut", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");

  const whole = parseJson(await run("inspect", "--json", path));
  const cut = truncatedCopy(path, 13194);
  const walked = await run("inspect", cut);
  const report = parseJson(await run("inspect", "--json", cut));

  // Recovery, not failure: every record that was complete before the cut is still named,
  // with the same offsets and lengths it has in the whole file.
  assert.ok(report.records.length > 0);
  assert.ok(report.records.length < whole.records.length);
  for (const [i, record] of report.records.slice(0, -1).entries()) {
    assert.deepEqual(record, whole.records[i]);
  }
  assert.equal(report.trailing_magic, false);
  assert.match(report.stopped!, /past the end of a 13194-byte file/);
  assert.equal(report.summary_crc, null);
  assert.equal(report.summary_crc_absent, "there is no Footer record at the tail");
  assert.ok(walked.out.some((line) => line.includes("(the last record is incomplete)")));
  assert.equal(walked.code, EXIT_FAILED);

  const validated = await run("validate", cut);
  assert.equal(validated.code, EXIT_FAILED);
  assert.ok(
    validated.out.includes(
      "error: file does not end with the magic; it is truncated or was written by a broken encoder",
    ),
  );
  assert.ok(validated.out.some((line) => line.startsWith("error: stopped reading: need ")));
  // A cut file is not a refusal: nothing in the refusal table names "the bytes ran out".
  assert.ok(!validated.out.some((line) => line.startsWith("refused: ")));
});

test("a conforming file validates clean, and a warning gets its own exit code", async (t) => {
  const clean = corpus("MixedLifetimes-Quantized-UseChunkIndex-UseCrc");
  const audio = corpus("OneWindow-UseChunkIndex-UseCrc-WithMultipleAudioSources");
  const delta = corpus("keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics");
  const unindexed = corpus("TenWindows-UseCrc");
  if (clean === null || audio === null || delta === null || unindexed === null) {
    return t.skip("corpus not generated");
  }

  for (const path of [clean, audio]) {
    const validated = await run("validate", "--decode", path);
    assert.equal(validated.code, EXIT_OK, path);
    assert.equal(validated.out.at(-1), "valid", path);
  }

  // A file with no chunk index still conforms; it just cannot be seeked. Exiting 0 would
  // put that warning somewhere no script can reach.
  const warned = await run("validate", unindexed);
  assert.equal(warned.code, EXIT_WARNINGS);
  assert.equal(warned.out.at(-1), "valid (with notes)");
  assert.ok(warned.out.some((line) => line.startsWith("warning: no chunk index")));

  // A `keyframe-delta` file walks like any other: its Delta Chunks are named, not skipped.
  const walked = parseJson(await run("inspect", "--json", delta));
  assert.ok(walked.records.some((record) => record.name === "DeltaChunk"));
  assert.equal(walked.stopped, null);
});

interface JsonRecord {
  readonly offset: number;
  readonly opcode: number;
  readonly name: string;
  readonly content_length: number;
  readonly total_length: number;
  readonly crc_covered: boolean;
}

interface JsonReport {
  readonly size: number;
  readonly trailing_magic: boolean;
  readonly stopped: string | null;
  readonly summary_crc_absent: string | null;
  readonly summary_crc: {
    readonly start: number;
    readonly end: number;
    readonly declared: number;
    readonly actual: number;
    readonly ok: boolean;
  } | null;
  readonly records: readonly JsonRecord[];
}

function parseJson(result: Run): JsonReport {
  return JSON.parse(result.out.join("\n")) as JsonReport;
}
