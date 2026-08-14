// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * The `4dgs` command-line tool.
 *
 * Two seams, and the difference matters. `run` drives `main` with an injected sink, so the
 * tests read exactly what a user reads — the same lines, in the same order, with the same
 * exit code — which is the right place to assert on a finding. `shell` spawns the built
 * executable and reads its stdout, its stderr and its exit status, because those three are
 * what a script branches on and no in-process call can prove them: the tool's own entry
 * point is code, and it has been wrong. Every verdict this file pins is pinned through
 * `shell`.
 *
 * The corpus files these need are generated rather than committed. When they are absent the
 * corpus tests skip and say so — but only outside CI, where `corpus` throws instead,
 * because a test that skips itself green over a missing fixture reports that it proved
 * something it did not.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  BytesReadable,
  Crc32,
  Cursor,
  FourdgsError,
  FOOTER_TAIL_BYTES,
  HEADER_FLAG_HAS_AUDIO,
  IndexedDecoder,
  MAGIC,
  MAX_FRONT_MATTER_BYTES,
  Opcode,
  RECORD_HEADER_BYTES,
  iterateRecords,
  parseChunkIndexEntry,
  parseFooter,
  parseQuantization,
  shBound,
  shStep,
  type IReadable,
} from "@4dgs/core";
import { inspectFile, validateFile } from "@4dgs/nodejs";
import {
  EXIT_FAILED,
  EXIT_OK,
  EXIT_TOOL_FAILED,
  EXIT_WARNINGS,
  VERSION,
  main,
  type Sink,
} from "@4dgs/nodejs/cli";
import { MOVING_CHAINED } from "./keyframeDeltaFixtures.js";

const DATA = fileURLToPath(new URL("../../../tests/conformance/data/", import.meta.url));

/**
 * A corpus file, or `null` when the corpus has not been generated.
 *
 * `null` is for a developer who has not run `tests/conformance/generate.py` yet. Under
 * `CI` it throws instead, because there the corpus is generated before this runs and a
 * test that skips itself green over a missing fixture is a test that proved nothing while
 * reporting that it did.
 */
function corpus(variant: string): string | null {
  const path = `${DATA}${variant}.4dgs`;
  if (existsSync(path)) return path;
  if (process.env.CI !== undefined && process.env.CI !== "") {
    throw new Error(`the corpus is missing ${variant}.4dgs; CI generates it before the tests`);
  }
  return null;
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

/** The built executable, as a user installs and runs it. */
const EXECUTABLE = fileURLToPath(new URL("../../nodejs/dist/cli.js", import.meta.url));

/**
 * Run the real `4dgs` in its own process, and read what a shell would read.
 *
 * `run` above drives `main` with an injected sink, which is the right seam for asserting
 * on a finding. It cannot prove the thing a command-line tool is: that the file on disk
 * runs, writes those lines to those two streams, and exits with that number.
 */
function shell(...argv: string[]): Run {
  const result = spawnSync(process.execPath, [EXECUTABLE, ...argv], { encoding: "utf8" });
  assert.equal(result.error, undefined, `could not run ${EXECUTABLE}`);
  const lines = (text: string): string[] =>
    text === "" ? [] : text.replace(/\n$/, "").split("\n");
  return { code: result.status ?? -1, out: lines(result.stdout), err: lines(result.stderr) };
}

/** A copy of `variant` cut to `bytes`, in a directory the test owns. */
function truncatedCopy(path: string, bytes: number): string {
  const directory = mkdtempSync(join(tmpdir(), "fourdgs-cli-"));
  const cut = join(directory, "Truncated.4dgs");
  writeFileSync(cut, readFileSync(path).subarray(0, bytes));
  return cut;
}

/** `bytes` on disk under `name`, in a directory the test owns. */
function file(name: string, bytes: Uint8Array): string {
  const path = join(mkdtempSync(join(tmpdir(), "fourdgs-cli-")), name);
  writeFileSync(path, bytes);
  return path;
}

/**
 * The deliberately broken files below are the corpus with one thing changed, because a
 * file built from nothing proves the check fires and nothing about the file it fires on.
 */
function bytesOf(variant: string): Uint8Array {
  return new Uint8Array(readFileSync(corpus(variant)!));
}

function recordsOf(data: Uint8Array): { opcode: number; offset: number; length: number }[] {
  return [...iterateRecords(data, MAGIC.length)].map((record) => ({
    opcode: record.opcode,
    offset: record.offset,
    length: record.raw.length,
  }));
}

/** A private record with `length` bytes of content: legal anywhere a record may go. */
function privateRecord(length: number): Uint8Array {
  const out = new Uint8Array(RECORD_HEADER_BYTES + length);
  out[0] = 0x80;
  new DataView(out.buffer).setBigUint64(1, BigInt(length), true);
  return out;
}

function framedRecord(opcode: number, content: Uint8Array): Uint8Array {
  const out = new Uint8Array(RECORD_HEADER_BYTES + content.length);
  out[0] = opcode;
  new DataView(out.buffer).setBigUint64(1, BigInt(content.length), true);
  out.set(content, RECORD_HEADER_BYTES);
  return out;
}

function splice(data: Uint8Array, at: number, insert: Uint8Array): Uint8Array {
  const out = new Uint8Array(data.length + insert.length);
  out.set(data.subarray(0, at));
  out.set(insert, at);
  out.set(data.subarray(at), at + insert.length);
  return out;
}

/**
 * The spellings section 5.3's grammar accepts, against the bound each one declares.
 *
 * The identical table is checked by the Python, Rust and Dart validators. A row that moves
 * here without moving there is the disagreement the grammar exists to end, so keep the four
 * in step.
 */
const EQUIVALENT_BOUND_SPELLINGS: ReadonlyArray<readonly [string, number]> = [
  ["16", 16],
  ["16.", 16],
  ["16.0", 16],
  ["+016.000", 16],
  ["1.6e1", 16],
  ["160e-1", 16],
  ["0.16E2", 16],
  ["8", 8],
  ["0.8e1", 8],
  ["80e-1", 8],
  [".4e1", 4],
  [`0.${"0".repeat(1000)}4e1001`, 4],
  ["0", 0],
  ["0.0", 0],
  ["-0", 0],
  ["+0.000", 0],
  ["0e999999999999999999999999", 0],
  ["0.0e-999999999999999999999999", 0],
];

/**
 * The spellings section 5.3's grammar refuses, against the bound the record declares.
 *
 * Several are accepted by one runtime's number parser or another: underscores and other
 * scripts' digits by Python's `Decimal`, U+FEFF by JavaScript's own whitespace class. That
 * is exactly why the grammar is matched here rather than delegated to a runtime.
 */
const REJECTED_BOUND_SPELLINGS: ReadonlyArray<readonly [string, number]> = [
  ["1_6", 16],
  ["8_0e-1", 8],
  ["_16", 16],
  ["16_", 16],
  ["\u0661\u0666", 16], // Arabic-Indic one six
  ["\u0668", 8], // Arabic-Indic eight
  ["\u0668\u0660e-\u06f1", 8],
  ["\uff11\uff16", 16], // fullwidth one six
  ["\u2078", 8], // superscript eight, a digit in no grammar
  ["\ufeff16", 16], // a byte-order mark is data, not padding
  ["\ufeff4", 4],
  ["16\ufeff", 16],
  ["\u001c8", 8], // Python's `Decimal` trims U+001C; the grammar does not
  ["\u001f16", 16],
  [" 16 ", 16],
  ["\t16", 16],
  ["16\n", 16],
  ["\u200916", 16], // thin space
  ["16.0000000000000001", 16],
  ["15.9999999999999999", 16],
  ["1.6", 16],
  ["16e", 16],
  ["16e+", 16],
  ["16e-", 16],
  ["16eNaN", 16],
  ["", 16],
  [".", 16],
  ["+", 16],
  ["_", 0],
  ["NaN", 0],
  ["nan", 0],
  ["Infinity", 16],
  ["inf", 16],
  ["-16", 16],
  ["0e", 0],
  ["0_0", 0],
  ["\u0660", 0], // Arabic-Indic zero
  ["\ufeff0", 0],
  ["\u001c0", 0],
  ["1", 0],
];

/** The SH bit depth whose section 6.5 bound is each expected value. */
const DEPTH_FOR_BOUND: ReadonlyMap<number, number> = new Map([
  [16, 3],
  [8, 4],
  [4, 5],
  [0, 8],
]);

/**
 * Rewrite one Quantization bound and discard the now-stale byte index and summary.
 *
 * `bandOneDepth` also rewrites the first appended SH bit depth, which is what decides the
 * bound `sh_band1` is checked against: 3 bits expects 16, 4 expects 8, 5 expects 4 and 8
 * expects 0. Without it a corpus variant can only exercise the one bound it was written
 * with, and a table of spellings covering every expected value would have nowhere to run.
 */
function replaceQuantizationBound(
  data: Uint8Array,
  wanted: string,
  replacement: string,
  bandOneDepth?: number,
): Uint8Array {
  const records = [...iterateRecords(data, MAGIC.length)];
  const quantization = records.find((entry) => entry.opcode === Opcode.Quantization)!;
  const content = quantization.raw.subarray(RECORD_HEADER_BYTES);
  const view = new DataView(content.buffer, content.byteOffset, content.byteLength);
  let at = 0;
  const schemeBytes = view.getUint32(at, true);
  at += 4 + schemeBytes + 3 * 8 + 8 * 8 + 1;
  const mapLengthAt = at;
  const mapBytes = view.getUint32(at, true);
  at += 4;
  const mapEnd = at + mapBytes;
  const decoder = new TextDecoder();
  const encoded = new TextEncoder().encode(replacement);
  let rewritten: Uint8Array | null = null;

  while (at < mapEnd) {
    const keyBytes = view.getUint32(at, true);
    at += 4;
    const key = decoder.decode(content.subarray(at, at + keyBytes));
    at += keyBytes;
    const valueLengthAt = at;
    const valueBytes = view.getUint32(at, true);
    at += 4;
    if (key === wanted) {
      const delta = encoded.length - valueBytes;
      rewritten = new Uint8Array(content.length + delta);
      rewritten.set(content.subarray(0, valueLengthAt));
      new DataView(rewritten.buffer).setUint32(valueLengthAt, encoded.length, true);
      rewritten.set(encoded, valueLengthAt + 4);
      rewritten.set(content.subarray(at + valueBytes), valueLengthAt + 4 + encoded.length);
      new DataView(rewritten.buffer).setUint32(mapLengthAt, mapBytes + delta, true);
      break;
    }
    at += valueBytes;
  }
  assert.notEqual(rewritten, null, `missing Quantization bound ${wanted}`);
  if (bandOneDepth !== undefined) {
    // The count byte follows the map, and band 1's depth follows the count.
    const countAt = mapEnd + (rewritten!.length - content.length);
    assert.ok(countAt + 1 < rewritten!.length, "the record declares no SH bit depths");
    rewritten![countAt + 1] = bandOneDepth;
  }

  const state = records
    .filter(
      (entry) =>
        entry.opcode !== Opcode.ChunkIndex &&
        entry.opcode !== Opcode.Statistics &&
        entry.opcode !== Opcode.SummaryOffset &&
        entry.opcode !== Opcode.Footer,
    )
    .map((entry) =>
      entry.opcode === Opcode.Quantization
        ? framedRecord(Opcode.Quantization, rewritten!)
        : entry.raw.slice(),
    );
  return indexlessFile(state);
}

/**
 * Move the Footer's `summary_start` by `shift` and recompute `summary_crc`.
 *
 * Without this an edit before the summary would be caught by the checksum, and every one
 * of these files would be refused for the wrong reason.
 */
function resealSummary(data: Uint8Array, shift = 0): Uint8Array {
  const footerContent = data.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const start = parseFooter(data.subarray(footerContent)).summaryStart + shift;
  view.setBigUint64(footerContent, BigInt(start), true);
  const crc = new Crc32().update(data.subarray(start, data.length - FOOTER_TAIL_BYTES)).digest();
  view.setUint32(footerContent + 16, crc, true);
  return data;
}

/** Frame a summary-free, indexless file from already-framed top-level records. */
function indexlessFile(records: readonly Uint8Array[]): Uint8Array {
  const parts = [MAGIC, ...records, framedRecord(Opcode.Footer, new Uint8Array(20)), MAGIC];
  const out = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/**
 * `4dgs validate <file>` in its own process: the lines it printed and the code it exited
 * with, which are the two things the next person to break one of these will see.
 */
function validated(path: string, ...options: string[]): Run {
  return shell("validate", ...options, path);
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
 * The byte each deliberately broken file is refused at.
 *
 * Not this tool's opinion: the Rust (#168), Python (#178), C++ (#183), Swift (#188) and
 * Dart (#191) validators answer these same seven numbers, which is what makes the byte
 * part of the refusal rather than a per-language detail. `FutureMajorVersion` is `0` and
 * version byte is named at byte 5; the fixed sentinel as a whole is named at byte 0. The
 * identifiers are not written here at all; they are read out of the corpus.
 */
const REFUSED_AT: Readonly<Record<string, number>> = {
  BadMagic: 0,
  EmptyTemporalModel: 8,
  FutureMajorVersion: 5,
  UnknownQuantizationScheme: 154,
  UnknownStreamCodec: 659,
  UnknownTemporalModel: 8,
  WindowIndexOutOfRange: 2506,
};

test("end to end: every deliberately broken file is refused by identifier and byte", (t) => {
  // Through the executable, because the refusal line and the exit code together are what
  // a pipeline reads, and neither is proved by calling `validateFile` in process.
  if (!existsSync(EXECUTABLE)) return t.skip("not built");
  for (const [variant, at] of Object.entries(REFUSED_AT)) {
    const path = corpus(`invalid/${variant}`);
    if (path === null) return t.skip("corpus not generated");
    // The corpus states the answer; restating it here is how a test drifts from it.
    const expected = (
      JSON.parse(readFileSync(`${DATA}invalid/${variant}.json`, "utf8")) as {
        refused: string;
      }
    ).refused;

    const validated = shell("validate", "--decode", path);
    assert.equal(validated.code, EXIT_FAILED, variant);
    assert.equal(validated.err.at(-1), "INVALID", variant);
    const refusal = validated.out.find((line) => line.startsWith("refused: "));
    assert.ok(refusal !== undefined, `${variant} named no refusal:\n${validated.out.join("\n")}`);
    const match = /^refused: (\S+) at byte (\d+) \((.+)\)$/.exec(refusal);
    assert.ok(match !== null, `${variant}: ${refusal}`);
    assert.equal(match[1], expected, variant);
    assert.equal(Number(match[2]), at, `${variant}: ${refusal}`);
    // The byte is a real place in this file, not a placeholder.
    assert.ok(at < readFileSync(path).length, variant);
  }
});

test("regression: inspect --json preflights magic before writing stdout", async () => {
  const badMagic = MAGIC.slice();
  badMagic[0] ^= 0xff;
  const futureMajor = MAGIC.slice();
  futureMajor[5] += 1;

  for (const [name, bytes] of [
    ["BadMagic.4dgs", badMagic],
    ["FutureMajor.4dgs", futureMajor],
  ] as const) {
    const inspected = await run("inspect", file(name, bytes), "--json");
    assert.equal(inspected.code, EXIT_FAILED);
    assert.deepEqual(inspected.out, [], `${name} emitted partial JSON`);
    assert.ok(inspected.err.some((line) => line.startsWith("4dgs: ")));
  }
});

test("end to end: a conforming file, a warned file and a broken one, from a shell", (t) => {
  // The three exit codes a script branches on, from the executable itself. `run` cannot
  // prove any of them: it returns what `main` computed, not what the process reported.
  if (!existsSync(EXECUTABLE)) return t.skip("not built");
  const clean = corpus("MixedLifetimes-Quantized-UseChunkIndex-UseCrc");
  const unindexed = corpus("TenWindows-UseCrc");
  if (clean === null || unindexed === null) return t.skip("corpus not generated");

  const valid = shell("validate", "--decode", clean);
  assert.deepEqual(valid.out, ["valid"]);
  assert.deepEqual(valid.err, []);
  assert.equal(valid.code, EXIT_OK);

  const warned = shell("validate", unindexed);
  assert.deepEqual(warned.out, [
    "warning: no chunk index: this file can only be read front to back, not seeked",
    "valid (with notes)",
  ]);
  assert.equal(warned.code, EXIT_WARNINGS);

  // The walk's table, from the same process: a header row, both magic lines, and one row
  // per record with the offsets the JSON form reports.
  const walked = shell("inspect", clean);
  assert.equal(walked.code, EXIT_OK);
  assert.match(walked.out[0]!, /^ +offset {2}record {2,}content {2,}total {2}crc$/);
  assert.equal(walked.out[1]!.trim(), "0  (magic)                                         8");
  const records = JSON.parse(shell("inspect", "--json", clean).out.join("\n")) as JsonReport;
  assert.equal(walked.out.filter((line) => /^ +[\d,]+ {2}\S/.test(line)).length, records.records.length + 2); // prettier-ignore
  assert.ok(walked.out.some((line) => line.startsWith("summary crc    ok  (covers bytes ")));

  const missing = shell("validate", join(tmpdir(), "no-such-file-4dgs-cli.4dgs"));
  assert.equal(missing.code, EXIT_TOOL_FAILED);
  assert.equal(missing.out.length, 0);
  assert.ok(missing.err.join("\n").includes("ENOENT"));
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
  assert.ok(validated.out.some((line) => line.startsWith("error: stopped reading: ")));
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

  for (const path of [clean, audio, delta]) {
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

test("the tool runs when it is invoked through the bin symlink npm installs", (t) => {
  // `bin` is a symlink in `node_modules/.bin`, and Node reports the link path in
  // `process.argv[1]` while resolving `import.meta.url` through it. A tool that compares
  // those two directly never runs its own entry point: the advertised executable exits 0
  // having printed nothing, which is indistinguishable from success.
  const cli = fileURLToPath(new URL("../../nodejs/dist/cli.js", import.meta.url));
  if (!existsSync(cli)) return t.skip("not built");
  const link = join(mkdtempSync(join(tmpdir(), "fourdgs-bin-")), "4dgs");
  symlinkSync(cli, link);
  const linked = spawnSync(process.execPath, [link, "--version"], { encoding: "utf8" });
  assert.equal(linked.stdout.trim(), VERSION);
  assert.equal(linked.status, EXIT_OK);
});

test("regression: a file cut inside its own closing magic is not a clean walk", async (t) => {
  // The records all frame, so nothing else notices; the tail is short by three bytes. The
  // validator calls this "does not end with the magic" and refuses it, and a walk that
  // printed a note and exited 0 let a pipeline accept what the validator rejects.
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const whole = new Uint8Array(readFileSync(path));
  const cut = file("CutMagic.4dgs", whole.subarray(0, whole.length - 3));

  const walked = shell("inspect", cut);
  assert.equal(walked.code, EXIT_FAILED);
  assert.ok(
    walked.err.some((line) => /^4dgs: stopped: .*are not the closing magic/.test(line)),
    walked.err.join("\n"),
  );
  assert.match(
    parseJson(await run("inspect", "--json", cut)).stopped!,
    /are not the closing magic/,
  );
  assert.equal(shell("validate", cut).code, EXIT_FAILED);

  // And with the whole magic gone the walk ends on a record boundary, so nothing stopped
  // early — the file simply does not end the way a 4dgs file ends, which is the same
  // verdict by a different route.
  const bare = file("NoMagic.4dgs", whole.subarray(0, whole.length - MAGIC.length));
  const report = parseJson(await run("inspect", "--json", bare));
  assert.equal(report.stopped, null);
  assert.equal(report.trailing_magic, false);
  const bareWalk = shell("inspect", bare);
  assert.equal(bareWalk.code, EXIT_FAILED);
  assert.ok(bareWalk.out.includes("note: the file does not end with the magic"));
});

test("regression: --decode reaches inside SH band streams, not only chunk streams", (t) => {
  // Two refusals live in a stream's framing, and a band's stream is a stream. The streamed
  // decoder decodes these records, so a `--decode` pass that stepped over them reported a
  // file valid that this same package refuses to read.
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const data = bytesOf("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  const band = recordsOf(data).find((record) => record.opcode === Opcode.ShBandStream)!;
  // The codec byte: one band byte, then the stream's attribute, symbol width and mode.
  data[band.offset + RECORD_HEADER_BYTES + 4] = 9;
  const broken = file("BadShCodec.4dgs", data);

  const structural = validated(broken);
  assert.equal(structural.code, EXIT_OK, "structurally it is fine");
  const decoded = validated(broken, "--decode");
  assert.equal(decoded.code, EXIT_FAILED);
  assert.ok(
    decoded.out.some(
      (line) =>
        line.includes(`SH Band Stream at byte ${band.offset}`) &&
        /SH band 1 does not decode: stream codec 9/.test(line),
    ),
    decoded.out.join("\n"),
  );
  assert.ok(
    decoded.out.includes(`refused: unknown-stream-codec at byte ${band.offset} (the SH Band Stream record)`), // prettier-ignore
    decoded.out.join("\n"),
  );
  assert.equal(decoded.err.at(-1), "INVALID");
});

test("regression: --decode assembles SH bands before accepting them", (t) => {
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const data = bytesOf("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  const firstBand = recordsOf(data).find((record) => record.opcode === Opcode.ShBandStream)!;
  const firstIndex = recordsOf(data).find((record) => record.opcode === Opcode.ChunkIndex)!;
  // Make the first chunk carry bands 2 and 3 rather than 1 and 2. Both streams remain
  // individually decodable, and the index agrees with the record, so only semantic
  // assembly can notice that these do not form a whole degree starting at band 1.
  data[firstBand.offset + RECORD_HEADER_BYTES] = 3;
  data[firstIndex.offset + RECORD_HEADER_BYTES + 40] = 3;
  const report = validated(file("MissingLowerShBand.4dgs", resealSummary(data)), "--decode");
  assert.equal(report.code, EXIT_FAILED);
  assert.ok(
    report.out.some((line) =>
      line.includes("chunk 1 SH bands do not assemble: SH bands 2, 3 do not form whole degrees"),
    ),
    report.out.join("\n"),
  );
});

test("regression: a state Chunk cannot repeat an SH band", async (t) => {
  const variant = "MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const band = recordsOf(original).find((record) => record.opcode === Opcode.ShBandStream)!;
  const copy = original.slice(band.offset, band.offset + band.length);
  const duplicated = resealSummary(splice(original, band.offset + band.length, copy), copy.length);

  const report = await validateFile(duplicated, { decode: true });
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes(`SH Band Stream at byte ${band.offset + band.length}`) &&
        finding.message.includes("repeats band 1"),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: an SH band immediately after a Delta Chunk belongs to that state", async (t) => {
  const variant = "MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const bandSource = bytesOf(variant);
  const band = recordsOf(bandSource).find((record) => record.opcode === Opcode.ShBandStream)!;
  const bandRecord = bandSource.slice(band.offset, band.offset + band.length);
  const deltaFile = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const delta = recordsOf(deltaFile).find((record) => record.opcode === Opcode.DeltaChunk)!;
  const report = await validateFile(splice(deltaFile, delta.offset + delta.length, bandRecord));
  assert.ok(
    report.findings.some((finding) =>
      finding.message.includes(`from its Chunk at ${delta.offset}`),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
  assert.ok(
    report.findings.every((finding) => !finding.message.includes("does not immediately follow")),
    report.findings.map((finding) => finding.message).join("\n"),
  );

  const assembled = await validateFile(splice(deltaFile, delta.offset + delta.length, bandRecord), {
    decode: true,
  });
  assert.ok(
    assembled.findings.some((finding) =>
      finding.message.includes("chunk 2 SH bands do not assemble"),
    ),
    assembled.findings.map((finding) => finding.message).join("\n"),
  );

  const badCodec = bandRecord.slice();
  badCodec[RECORD_HEADER_BYTES + 1 + 3] = 9;
  const badCodecAt = delta.offset + delta.length;
  const decoded = await validateFile(splice(deltaFile, badCodecAt, badCodec), { decode: true });
  assert.equal(decoded.refused?.code, "unknown-stream-codec");
  assert.equal(decoded.refused?.at, badCodecAt);

  const badAttribute = bandRecord.slice();
  badAttribute[RECORD_HEADER_BYTES + 1] = 0;
  const nested = await validateFile(splice(deltaFile, badCodecAt, badAttribute), { decode: true });
  assert.ok(
    nested.findings.some((finding) => finding.message.includes("declares nested attribute_id 0")),
    nested.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: --decode revisits Chunks that precede Quantization", async (t) => {
  const variant = "invalid/UnknownStreamCodec";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const records = recordsOf(original);
  const quantization = records.find((record) => record.opcode === Opcode.Quantization)!;
  const firstChunk = records.find((record) => record.opcode === Opcode.Chunk)!;
  const quantizationRecord = original.slice(
    quantization.offset,
    quantization.offset + quantization.length,
  );
  const withoutQuantization = new Uint8Array(original.length - quantization.length);
  withoutQuantization.set(original.subarray(0, quantization.offset));
  withoutQuantization.set(
    original.subarray(quantization.offset + quantization.length),
    quantization.offset,
  );
  const shiftedChunkOffset = firstChunk.offset - quantization.length;
  const late = splice(
    withoutQuantization,
    shiftedChunkOffset + firstChunk.length,
    quantizationRecord,
  );

  const report = await validateFile(late, { decode: true });
  assert.equal(report.refused?.code, "unknown-stream-codec");
  assert.equal(report.refused?.at, shiftedChunkOffset);
});

test("regression: --decode waits for a Window Table that follows the Chunks", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const records = [...iterateRecords(original, MAGIC.length)];
  const window = records.find((record) => record.opcode === Opcode.WindowTable)!.raw.slice();
  const body = records
    .filter(
      (record) =>
        record.opcode !== Opcode.WindowTable &&
        record.opcode !== Opcode.ChunkIndex &&
        record.opcode !== Opcode.Statistics &&
        record.opcode !== Opcode.SummaryOffset &&
        record.opcode !== Opcode.Footer,
    )
    .map((record) => record.raw.slice());
  const report = await validateFile(indexlessFile([...body, window]), { decode: true });
  assert.equal(report.refused, null);
  assert.equal(report.ok, true, report.findings.map((finding) => finding.message).join("\n"));
});

test("regression: an oversized compression name is a validator resource limit", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const chunk = recordsOf(original).find((record) => record.opcode === Opcode.Chunk)!;
  const nameLengthAt = chunk.offset + RECORD_HEADER_BYTES + 24;
  const oldView = new DataView(original.buffer, original.byteOffset, original.byteLength);
  const oldLength = oldView.getUint32(nameLengthAt, true);
  const limitCrossingLength = 4097;
  const added = limitCrossingLength - oldLength;
  assert.ok(added > 0);
  const changed = splice(original, nameLengthAt + 4 + oldLength, new Uint8Array(added));
  const view = new DataView(changed.buffer, changed.byteOffset, changed.byteLength);
  view.setUint32(nameLengthAt, limitCrossingLength, true);
  view.setBigUint64(
    chunk.offset + 1,
    view.getBigUint64(chunk.offset + 1, true) + BigInt(added),
    true,
  );
  await assert.rejects(
    () => validateFile(changed),
    (error: unknown) =>
      error instanceof RangeError &&
      error.message.includes("bounded-memory string limit") &&
      error.message.includes("not a malformed-file verdict"),
  );
});

test("regression: keyframe-delta index metadata is checked without and with decoding", async () => {
  const original = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const records = [...iterateRecords(original, MAGIC.length)];
  const keyframeRecord = records.find(
    (record) =>
      record.opcode === Opcode.ChunkIndex && parseChunkIndexEntry(record.content).kind === 0,
  )!;
  const entry = parseChunkIndexEntry(keyframeRecord.content);
  const bandCount = entry.bands.length;
  const extensionAt = keyframeRecord.offset + RECORD_HEADER_BYTES + 40 + bandCount * (1 + 8 + 8);

  const constants = original.slice();
  constants[extensionAt + 1] = 1;
  new DataView(constants.buffer, constants.byteOffset, constants.byteLength).setBigUint64(
    extensionAt + 2,
    1n,
    true,
  );
  const constantsReport = await validateFile(resealSummary(constants));
  assert.ok(constantsReport.findings.some((finding) => finding.message.includes("delta_mode 1")));
  assert.ok(
    constantsReport.findings.some((finding) => finding.message.includes("reference_offset 1")),
  );

  const live = original.slice();
  const liveAt = extensionAt + 20;
  const liveView = new DataView(live.buffer, live.byteOffset, live.byteLength);
  liveView.setBigUint64(liveAt, liveView.getBigUint64(liveAt, true) + 1n, true);
  const liveReport = await validateFile(resealSummary(live), { decode: true });
  assert.ok(
    liveReport.findings.some(
      (finding) =>
        finding.message.includes(`declares live_count ${entry.liveCount + 1}`) &&
        finding.message.includes("composing the state"),
    ),
    liveReport.findings.map((finding) => finding.message).join("\n"),
  );

  const timeline = original.slice();
  new DataView(timeline.buffer, timeline.byteOffset, timeline.byteLength).setFloat64(
    keyframeRecord.offset + RECORD_HEADER_BYTES,
    0.25,
    true,
  );
  const timelineReport = await validateFile(resealSummary(timeline));
  assert.ok(
    timelineReport.findings.some((finding) =>
      finding.message.includes("keyframe-delta timeline does not tile the scene clock"),
    ),
    timelineReport.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: indexless delta references are checked without decoding", async () => {
  const original = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const body = [...iterateRecords(original, MAGIC.length)]
    .filter(
      (record) =>
        record.opcode !== Opcode.ChunkIndex &&
        record.opcode !== Opcode.Statistics &&
        record.opcode !== Opcode.SummaryOffset &&
        record.opcode !== Opcode.Footer,
    )
    .map((record) => record.raw.slice());
  const indexless = indexlessFile(body);
  const delta = recordsOf(indexless).find((record) => record.opcode === Opcode.DeltaChunk)!;
  new DataView(indexless.buffer, indexless.byteOffset, indexless.byteLength).setBigUint64(
    delta.offset + RECORD_HEADER_BYTES + 21,
    BigInt(delta.offset + delta.length),
    true,
  );
  const report = await validateFile(indexless);
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes(`Delta Chunk at ${delta.offset} references`) &&
        finding.message.includes("not an earlier physical state chunk"),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: Header cutoff and keyframe population are structural checks", async () => {
  const original = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const headerRecord = [...iterateRecords(original, MAGIC.length)].find(
    (record) => record.opcode === Opcode.Header,
  )!;
  const headerCursor = new Cursor(headerRecord.content);
  headerCursor.string();
  headerCursor.string();
  headerCursor.f64();
  headerCursor.u64();
  const cutoffAt = headerRecord.offset + RECORD_HEADER_BYTES + headerCursor.pos;
  const badCutoff = original.slice();
  new DataView(badCutoff.buffer, badCutoff.byteOffset, badCutoff.byteLength).setFloat64(
    cutoffAt,
    2,
    true,
  );
  const cutoffReport = await validateFile(badCutoff);
  assert.ok(
    cutoffReport.findings.some((finding) =>
      finding.message.includes("Header cutoff is 2; expected a finite value in (0, 1]"),
    ),
  );

  const oversizedKeyframe = original.slice();
  const keyframe = recordsOf(oversizedKeyframe).find((record) => record.opcode === Opcode.Chunk)!;
  new DataView(
    oversizedKeyframe.buffer,
    oversizedKeyframe.byteOffset,
    oversizedKeyframe.byteLength,
  ).setUint32(keyframe.offset + RECORD_HEADER_BYTES + 20, 0xffff_ffff, true);
  const countReport = await validateFile(oversizedKeyframe);
  assert.ok(
    countReport.findings.some(
      (finding) =>
        finding.message.includes(`keyframe Chunk at byte ${keyframe.offset} declares 4294967295`) &&
        finding.message.includes("the Header declares only"),
    ),
    countReport.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: gaussian-birth rejects a physical Delta Chunk", async () => {
  const data = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const model = new TextEncoder().encode("keyframe-delta");
  const replacement = new TextEncoder().encode("gaussian-birth");
  let at = -1;
  outer: for (let i = 0; i <= data.length - model.length; i++) {
    for (let j = 0; j < model.length; j++) {
      if (data[i + j] !== model[j]) continue outer;
    }
    at = i;
  }
  assert.notEqual(at, -1);
  data.set(replacement, at);
  const report = await validateFile(data);
  assert.ok(
    report.findings.some((finding) =>
      finding.message.includes('is not legal under temporal_model "gaussian-birth"'),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: indexed depth is derived even when the record repeats the same lie", async () => {
  const data = new Uint8Array(Buffer.from(MOVING_CHAINED, "base64"));
  const records = [...iterateRecords(data, MAGIC.length)];
  const delta = records.find((record) => record.opcode === Opcode.DeltaChunk)!;
  const entryRecord = records.find(
    (record) =>
      record.opcode === Opcode.ChunkIndex &&
      parseChunkIndexEntry(record.content).chunkOffset === delta.offset,
  )!;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const wrongDepth = view.getUint16(delta.offset + RECORD_HEADER_BYTES + 37, true) + 4;
  view.setUint16(delta.offset + RECORD_HEADER_BYTES + 37, wrongDepth, true);
  const bandCount = view.getUint32(entryRecord.offset + RECORD_HEADER_BYTES + 36, true);
  const indexedDepthAt = entryRecord.offset + RECORD_HEADER_BYTES + 58 + bandCount * (1 + 8 + 8);
  view.setUint16(indexedDepthAt, wrongDepth, true);
  const report = await validateFile(resealSummary(data));
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes(`the delta index entry at ${delta.offset} declares depth`) &&
        finding.message.includes("reference chain walks"),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
  assert.ok(
    report.findings.every(
      (finding) =>
        !finding.message.includes("the Delta Chunk") || !finding.message.includes("depth"),
    ),
    "the duplicate-field comparison should pass when both copies carry the same wrong depth",
  );
});

test("regression: the object layer's cross-record rules are checked, not stepped over", (t) => {
  // `scene.ts` refuses two tracks for one object, and so does the Python validator. A
  // structural pass that skipped the record declared a file valid that neither can read.
  if (corpus("LongLived-UseChunkIndex-UseCrc-WithObjects") === null || !existsSync(EXECUTABLE)) {
    return t.skip("corpus not generated");
  }
  const data = bytesOf("LongLived-UseChunkIndex-UseCrc-WithObjects");
  const track = recordsOf(data).find((record) => record.opcode === Opcode.ObjectTrack)!;
  const copy = data.subarray(track.offset, track.offset + track.length);
  const summary = parseFooter(
    data.subarray(data.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;
  // After the chunks, so every index entry still frames what it framed before.
  const doubled = resealSummary(splice(data, summary, copy), copy.length);

  const report = validated(file("TwoTracks.4dgs", doubled));
  assert.equal(report.code, EXIT_FAILED);
  assert.ok(
    report.out.some((line) => /two ObjectTrack records move object \d+/.test(line)),
    report.out.join("\n"),
  );
});

test("regression: zero-sample Object Tracks are absent during cross-record checks", (t) => {
  if (corpus("LongLived-UseChunkIndex-UseCrc-WithObjects") === null || !existsSync(EXECUTABLE)) {
    return t.skip("corpus not generated");
  }
  const data = bytesOf("LongLived-UseChunkIndex-UseCrc-WithObjects");
  const summary = parseFooter(
    data.subarray(data.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;
  const content = new Uint8Array(9);
  const view = new DataView(content.buffer);
  view.setUint32(0, 7, true);
  content[4] = 0;
  view.setUint32(5, 0, true);
  const empty = framedRecord(Opcode.ObjectTrack, content);
  const withTwoEmpty = splice(splice(data, summary, empty), summary + empty.length, empty);
  const report = validated(
    file("TwoAbsentTracks.4dgs", resealSummary(withTwoEmpty, 2 * empty.length)),
  );
  assert.equal(report.code, EXIT_OK, report.out.join("\n"));
});

test("regression: zero-sample Rig Trajectories are absent during duplicate checks", (t) => {
  if (corpus("LongLived-UseChunkIndex-UseCrc-WithObjects") === null || !existsSync(EXECUTABLE)) {
    return t.skip("corpus not generated");
  }
  const data = bytesOf("LongLived-UseChunkIndex-UseCrc-WithObjects");
  const summary = parseFooter(
    data.subarray(data.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;
  const content = new Uint8Array(10);
  const view = new DataView(content.buffer);
  view.setUint32(0, 1, true);
  content[4] = "x".charCodeAt(0);
  content[5] = 0;
  view.setUint32(6, 0, true);
  const empty = framedRecord(Opcode.RigTrajectory, content);
  const withTwoEmpty = splice(splice(data, summary, empty), summary + empty.length, empty);
  const report = validated(
    file("TwoAbsentTrajectories.4dgs", resealSummary(withTwoEmpty, 2 * empty.length)),
  );
  assert.equal(report.code, EXIT_WARNINGS, report.out.join("\n"));
  assert.ok(
    report.out.filter((line) => line.includes("carries no samples; it is read as though absent"))
      .length === 2,
    report.out.join("\n"),
  );
  assert.ok(!report.out.some((line) => line.includes("two RigTrajectory records")));
});

test("regression: Header SH degree is restricted to the attribute registry", (t) => {
  if (corpus("TenWindows-UseChunkIndex-UseCrc") === null || !existsSync(EXECUTABLE)) {
    return t.skip("corpus not generated");
  }
  const data = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const header = recordsOf(data)[0]!;
  const cursor = new Cursor(data.subarray(header.offset + RECORD_HEADER_BYTES));
  cursor.string();
  cursor.string();
  cursor.f64();
  cursor.u64();
  cursor.f64();
  cursor.string();
  cursor.f64s(6);
  data[header.offset + RECORD_HEADER_BYTES + cursor.pos] = 4;
  const report = validated(file("ShDegree4.4dgs", data));
  assert.equal(report.code, EXIT_FAILED);
  assert.ok(report.out.some((line) => line.includes("Header sh_degree is 4")));
});

test("regression: decoded SH degree must equal the Header declaration", (t) => {
  if (corpus("MixedLifetimes-SHDegree1-UseChunkIndex-UseCrc") === null || !existsSync(EXECUTABLE)) {
    return t.skip("corpus not generated");
  }
  const data = bytesOf("MixedLifetimes-SHDegree1-UseChunkIndex-UseCrc");
  const header = recordsOf(data)[0]!;
  const cursor = new Cursor(data.subarray(header.offset + RECORD_HEADER_BYTES));
  cursor.string();
  cursor.string();
  cursor.f64();
  cursor.u64();
  cursor.f64();
  cursor.string();
  cursor.f64s(6);
  data[header.offset + RECORD_HEADER_BYTES + cursor.pos] = 2;

  const report = validated(file("WrongShDegree.4dgs", data), "--decode");
  assert.equal(report.code, EXIT_FAILED);
  assert.ok(
    report.out.some((line) => line.includes("chunks assemble SH degree 1")),
    report.out.join("\n"),
  );
});

test("regression: decoded validation reports late malformed windows and every early Footer", (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const original = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const summary = parseFooter(
    original.subarray(original.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;

  const malformedWindow = framedRecord(Opcode.WindowTable, Uint8Array.of(1));
  const withWindow = splice(original.slice(), summary, malformedWindow);
  const windowReport = validated(
    file("LateMalformedWindow.4dgs", resealSummary(withWindow, malformedWindow.length)),
    "--decode",
  );
  assert.equal(windowReport.code, EXIT_FAILED);
  assert.ok(
    windowReport.out.some((line) => line.includes("Window Table does not parse")),
    windowReport.out.join("\n"),
  );

  const footerRecord = recordsOf(original).find((record) => record.opcode === Opcode.Footer)!;
  const duplicate = original.slice(footerRecord.offset, footerRecord.offset + footerRecord.length);
  const twoFooters = splice(original.slice(), footerRecord.offset, duplicate);
  const finalFooterContent = twoFooters.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  new DataView(twoFooters.buffer, twoFooters.byteOffset, twoFooters.byteLength).setUint32(
    finalFooterContent + 16,
    0,
    true,
  );
  const footerReport = validated(file("TwoFooters.4dgs", twoFooters));
  assert.equal(footerReport.code, EXIT_FAILED);
  assert.ok(
    footerReport.out.some((line) => line.includes("every Footer must be the last record")),
    footerReport.out.join("\n"),
  );
});

test("regression: decoded validation rejects unordered and NaN Window Table rows", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const summary = parseFooter(
    original.subarray(original.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;

  for (const [name, lo, hi] of [
    ["Unordered", 2, 1],
    ["NanLower", Number.NaN, 1],
    ["NanUpper", 0, Number.NaN],
  ] as const) {
    const content = new Uint8Array(20);
    const view = new DataView(content.buffer);
    view.setUint32(0, 1, true);
    view.setFloat64(4, lo, true);
    view.setFloat64(12, hi, true);
    const record = framedRecord(Opcode.WindowTable, content);
    const changed = resealSummary(splice(original, summary, record), record.length);
    const report = await validateFile(changed, { decode: true });
    assert.ok(
      report.findings.some(
        (finding) =>
          finding.message.includes("Window Table row 0") &&
          finding.message.includes("expected non-NaN ordered bounds"),
      ),
      `${name}: ${report.findings.map((finding) => finding.message).join("\n")}`,
    );
  }
});

test("regression: gaussian-birth Chunk intervals reject NaN and unreachable populations", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");

  for (const kind of ["nan", "zero-width"] as const) {
    const data = bytesOf(variant);
    const records = recordsOf(data);
    const chunk = records.find((record) => record.opcode === Opcode.Chunk)!;
    const index = records.find((record) => record.opcode === Opcode.ChunkIndex)!;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const t0 = view.getFloat64(chunk.offset + RECORD_HEADER_BYTES, true);
    const t1 = kind === "nan" ? Number.NaN : t0;
    view.setFloat64(chunk.offset + RECORD_HEADER_BYTES + 8, t1, true);
    view.setFloat64(index.offset + RECORD_HEADER_BYTES + 8, t1, true);

    const report = await validateFile(resealSummary(data), { decode: true });
    assert.ok(
      report.findings.some((finding) =>
        kind === "nan"
          ? finding.message.includes("has a NaN interval endpoint")
          : finding.message.includes("gaussians in zero-width interval"),
      ),
      `${kind}: ${report.findings.map((finding) => finding.message).join("\n")}`,
    );
  }
});

test("regression: a record after the Footer, a reserved Header flag, a foreign summary record", (t) => {
  // Three normative MUSTs the structural pass could not see: §4 (the Footer is the last
  // record), §4.2 (Header flag bits 2-7 are zero) and §4.5 (the summary is exactly the
  // Chunk Index, Statistics and Summary Offset records).
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const original = bytesOf("TenWindows-UseChunkIndex-UseCrc");

  const appended = splice(original.slice(), original.length - MAGIC.length, privateRecord(20));
  const after = validated(file("AfterFooter.4dgs", appended));
  assert.equal(after.code, EXIT_FAILED);
  assert.ok(
    after.out.some((line) => line.includes("the Footer must be the last record")),
    after.out.join("\n"),
  );

  const flagged = original.slice();
  const header = recordsOf(flagged)[0]!;
  const cursor = new Cursor(flagged.subarray(header.offset + RECORD_HEADER_BYTES));
  cursor.string();
  cursor.string();
  cursor.f64();
  cursor.u64();
  cursor.f64();
  cursor.string();
  cursor.f64s(6);
  cursor.u8();
  flagged[header.offset + RECORD_HEADER_BYTES + cursor.pos] |= 0x04;
  const reserved = validated(file("ReservedFlag.4dgs", flagged));
  assert.equal(reserved.code, EXIT_FAILED);
  assert.ok(
    reserved.out.includes(
      "error: Header flags is 0x04; bits 2-7 are reserved and MUST be 0 (§4.2)",
    ),
    reserved.out.join("\n"),
  );

  const start = parseFooter(
    original.subarray(original.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;

  const firstIndex = recordsOf(original).find((record) => record.opcode === Opcode.ChunkIndex)!;
  const shortened = resealSummary(original.slice(), firstIndex.length);
  const lateStart = validated(file("LateSummaryStart.4dgs", shortened));
  assert.equal(lateStart.code, EXIT_FAILED);
  assert.ok(
    lateStart.out.some((line) => line.includes("the first Chunk Index record starts at")),
    lateStart.out.join("\n"),
  );

  // Inside the summary, with the checksum recomputed over it — which is exactly why the
  // CRC cannot answer this question and something else has to.
  const inside = resealSummary(splice(original.slice(), start, privateRecord(16)));
  const smuggled = validated(file("SummaryPayload.4dgs", inside));
  assert.equal(smuggled.code, EXIT_FAILED);
  assert.ok(
    smuggled.out.some((line) => /the summary carries a \S+ record at \d+/.test(line)),
    smuggled.out.join("\n"),
  );
  assert.ok(
    !smuggled.out.some((line) => line.includes("summary CRC mismatch")),
    "the checksum passes; that is the point",
  );

  // A zero CRC legally means "not computed"; summary_start still defines the range and
  // its composition remains normative.
  const unchecked = inside.slice();
  const footerContent = unchecked.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  new DataView(unchecked.buffer, unchecked.byteOffset, unchecked.byteLength).setUint32(
    footerContent + 16,
    0,
    true,
  );
  const withoutCrc = validated(file("SummaryPayloadNoCrc.4dgs", unchecked));
  assert.equal(withoutCrc.code, EXIT_FAILED);
  assert.ok(
    withoutCrc.out.some((line) => /the summary carries a \S+ record at \d+/.test(line)),
    withoutCrc.out.join("\n"),
  );
});

test("regression: an index entry whose length does not frame its record is refused", (t) => {
  // §5.8: every offset and length here frames a whole record. `readChunk` range-reads the
  // declared length before parsing it, so an entry that points at a real Chunk with the
  // wrong length makes the seek path unusable on a file the walk calls conforming.
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const data = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const entry = recordsOf(data).find((record) => record.opcode === Opcode.ChunkIndex)!;
  // f64 t0, f64 t1, u64 chunk_offset, then the length this file lies about.
  const at = entry.offset + RECORD_HEADER_BYTES + 24;
  new DataView(data.buffer, data.byteOffset, data.byteLength).setBigUint64(at, 1n, true);
  const report = validated(file("ShortEntry.4dgs", resealSummary(data)));
  assert.equal(report.code, EXIT_FAILED);
  assert.ok(
    report.out.some((line) => /chunk index entry 0 declares 1 bytes at \d+/.test(line)),
    report.out.join("\n"),
  );
});

test("regression: indexed counts and SH ranges duplicate their referenced records exactly", (t) => {
  const path = corpus("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");

  const wrongCount = bytesOf("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  const countIndex = recordsOf(wrongCount).find((record) => record.opcode === Opcode.ChunkIndex)!;
  const countAt = countIndex.offset + RECORD_HEADER_BYTES + 32;
  const countView = new DataView(wrongCount.buffer, wrongCount.byteOffset, wrongCount.byteLength);
  countView.setUint32(countAt, countView.getUint32(countAt, true) + 1, true);
  const countReport = validated(file("WrongIndexedCount.4dgs", resealSummary(wrongCount)));
  assert.equal(countReport.code, EXIT_FAILED);
  assert.ok(
    countReport.out.some((line) =>
      /chunk index entry 0 declares \d+ gaussians; the Chunk at \d+ contains \d+/.test(line),
    ),
    countReport.out.join("\n"),
  );

  const shortBand = bytesOf("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  const bandIndex = recordsOf(shortBand).find((record) => record.opcode === Opcode.ChunkIndex)!;
  // f64 t0, f64 t1, u64 chunk offset/length, u32 count/band count, u8 band, u64 offset,
  // then the first indexed SH range's length.
  const lengthAt = bandIndex.offset + RECORD_HEADER_BYTES + 49;
  new DataView(shortBand.buffer, shortBand.byteOffset, shortBand.byteLength).setBigUint64(
    lengthAt,
    1n,
    true,
  );
  const bandReport = validated(file("ShortIndexedBand.4dgs", resealSummary(shortBand)));
  assert.equal(bandReport.code, EXIT_FAILED);
  assert.ok(
    bandReport.out.some((line) =>
      /chunk index entry 0 SH band range 0 declares 1 bytes/.test(line),
    ),
    bandReport.out.join("\n"),
  );

  const wrongInterval = bytesOf("MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc");
  const intervalIndex = recordsOf(wrongInterval).find(
    (record) => record.opcode === Opcode.ChunkIndex,
  )!;
  const intervalAt = intervalIndex.offset + RECORD_HEADER_BYTES;
  const intervalView = new DataView(
    wrongInterval.buffer,
    wrongInterval.byteOffset,
    wrongInterval.byteLength,
  );
  intervalView.setFloat64(intervalAt, intervalView.getFloat64(intervalAt, true) + 0.125, true);
  const intervalReport = validated(file("WrongIndexedInterval.4dgs", resealSummary(wrongInterval)));
  assert.equal(intervalReport.code, EXIT_FAILED);
  assert.ok(
    intervalReport.out.some((line) => line.includes("declares interval")),
    intervalReport.out.join("\n"),
  );
});

test("regression: indexed targets are physical records and a summary starts with its index", (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");

  const original = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const records = recordsOf(original);
  const chunk = records.find((record) => record.opcode === Opcode.Chunk)!;
  const summary = parseFooter(
    original.subarray(original.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;
  const embedded = framedRecord(0x80, original.slice(chunk.offset, chunk.offset + chunk.length));
  const insidePrivate = splice(original, summary, embedded);
  const shiftedIndex = recordsOf(insidePrivate).find(
    (record) => record.opcode === Opcode.ChunkIndex,
  )!;
  new DataView(
    insidePrivate.buffer,
    insidePrivate.byteOffset,
    insidePrivate.byteLength,
  ).setBigUint64(
    shiftedIndex.offset + RECORD_HEADER_BYTES + 16,
    BigInt(summary + RECORD_HEADER_BYTES),
    true,
  );
  const embeddedReport = validated(
    file("EmbeddedChunk.4dgs", resealSummary(insidePrivate, embedded.length)),
  );
  assert.equal(embeddedReport.code, EXIT_FAILED);
  assert.ok(
    embeddedReport.out.some((line) => line.includes("not the start of a top-level record")),
    embeddedReport.out.join("\n"),
  );

  const noIndex = original.slice();
  for (const record of recordsOf(noIndex)) {
    if (record.opcode === Opcode.ChunkIndex) noIndex[record.offset] = Opcode.Statistics;
  }
  const noIndexReport = validated(file("SummaryWithoutIndex.4dgs", resealSummary(noIndex)));
  assert.equal(noIndexReport.code, EXIT_FAILED);
  assert.ok(
    noIndexReport.out.some((line) => line.includes("names no Chunk Index record")),
    noIndexReport.out.join("\n"),
  );
});

test("regression: the index is an exact map of physical chunks and their SH bands", (t) => {
  const variant = "MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc";
  const path = corpus(variant);
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");

  const missingEntry = bytesOf(variant);
  const missingIndexes = recordsOf(missingEntry).filter(
    (record) => record.opcode === Opcode.ChunkIndex,
  );
  missingEntry[missingIndexes[1]!.offset] = Opcode.Statistics;
  const missingReport = validated(file("MissingChunkIndexEntry.4dgs", resealSummary(missingEntry)));
  assert.equal(missingReport.code, EXIT_FAILED);
  assert.ok(
    missingReport.out.some((line) => /the Chunk at byte \d+ has no Chunk Index entry/.test(line)),
    missingReport.out.join("\n"),
  );

  // Both substituted ranges still point at complete SH Band Stream records, and both
  // records still declare band 1. Only the owning-Chunk relationship exposes the lie.
  const swappedBands = bytesOf(variant);
  const swappedIndexes = recordsOf(swappedBands).filter(
    (record) => record.opcode === Opcode.ChunkIndex,
  );
  const firstRange = swappedIndexes[0]!.offset + RECORD_HEADER_BYTES + 41;
  const secondRange = swappedIndexes[1]!.offset + RECORD_HEADER_BYTES + 41;
  const firstBytes = swappedBands.slice(firstRange, firstRange + 16);
  swappedBands.copyWithin(firstRange, secondRange, secondRange + 16);
  swappedBands.set(firstBytes, secondRange);
  const swappedReport = validated(file("SwappedIndexedBands.4dgs", resealSummary(swappedBands)));
  assert.equal(swappedReport.code, EXIT_FAILED);
  assert.ok(
    swappedReport.out.some((line) => line.includes("does not belong to its Chunk")),
    swappedReport.out.join("\n"),
  );
});

test("regression: physical indexes, SH registries and provenance semantics are validated", (t) => {
  const indexedVariant = "MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc";
  const indexedPath = corpus(indexedVariant);
  if (indexedPath === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");

  const zeroSummary = bytesOf(indexedVariant);
  const footerContent = zeroSummary.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  const zeroSummaryView = new DataView(
    zeroSummary.buffer,
    zeroSummary.byteOffset,
    zeroSummary.byteLength,
  );
  zeroSummaryView.setBigUint64(footerContent, 0n, true);
  zeroSummaryView.setUint32(footerContent + 16, 0, true);
  const zeroSummaryReport = validated(file("IndexWithZeroSummaryStart.4dgs", zeroSummary));
  assert.equal(zeroSummaryReport.code, EXIT_FAILED);
  assert.ok(
    zeroSummaryReport.out.some((line) => line.includes("Footer's summary_start is 0")),
    zeroSummaryReport.out.join("\n"),
  );

  const illegalBand = bytesOf(indexedVariant);
  const records = recordsOf(illegalBand);
  const band = records.find((record) => record.opcode === Opcode.ShBandStream)!;
  const entry = records.find((record) => record.opcode === Opcode.ChunkIndex)!;
  illegalBand[band.offset + RECORD_HEADER_BYTES] = 4;
  illegalBand[entry.offset + RECORD_HEADER_BYTES + 40] = 4;
  const illegalBandReport = validated(file("IllegalShBand.4dgs", resealSummary(illegalBand)));
  assert.equal(illegalBandReport.code, EXIT_FAILED);
  assert.ok(
    illegalBandReport.out.some((line) => line.includes("the registry defines bands 1-3")),
    illegalBandReport.out.join("\n"),
  );

  // Empty name, right-handed, +Y up, +Z forward, registry unit 1 (metres), but a
  // contradictory numerical declaration of two metres per unit.
  const wrongUnit = bytesOf(indexedVariant);
  const wrongUnitRecords = recordsOf(wrongUnit);
  const summary = parseFooter(
    wrongUnit.subarray(wrongUnit.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;
  const frame = new Uint8Array(16);
  const frameView = new DataView(frame.buffer);
  frameView.setUint32(0, 0, true);
  frame.set([1, 1, 2, 1], 4);
  frameView.setFloat64(8, 2, true);
  assert.ok(wrongUnitRecords.some((record) => record.offset === summary));
  const withWrongUnit = splice(wrongUnit, summary, framedRecord(Opcode.CoordinateFrame, frame));
  const wrongUnitReport = validated(
    file("ConflictingFrameUnits.4dgs", resealSummary(withWrongUnit, RECORD_HEADER_BYTES + 16)),
  );
  assert.equal(wrongUnitReport.code, EXIT_FAILED);
  assert.ok(
    wrongUnitReport.out.some((line) => line.includes("a writer must make them agree")),
    wrongUnitReport.out.join("\n"),
  );
});

test("unit: inspect refuses a resource size that cannot be represented exactly", async () => {
  const size = BigInt(Number.MAX_SAFE_INTEGER) + 1n;
  const unreadable: IReadable = {
    size: () => Promise.resolve(size),
    read: () => Promise.reject(new Error("inspect must reject the size before reading")),
  };
  await assert.rejects(inspectFile(unreadable), (error: unknown) => {
    assert.ok(error instanceof RangeError);
    assert.ok(!(error instanceof FourdgsError));
    assert.match(
      error.message,
      new RegExp(`resource size ${size} exceeds the largest exactly addressable size`),
    );
    return true;
  });
});

test("unit: inspect and validate range-read instead of retaining the resource", async (t) => {
  const path = corpus("OneWindow-UseChunkIndex-UseCrc-WithLargeAudio");
  if (path === null) return t.skip("corpus not generated");
  const data = new Uint8Array(readFileSync(path));
  let largestRead = 0;
  const reads: { readonly offset: number; readonly length: number }[] = [];
  const source: IReadable = {
    size: () => Promise.resolve(BigInt(data.length)),
    read: (offset, length) => {
      largestRead = Math.max(largestRead, Number(length));
      const at = Number(offset);
      reads.push({ offset: at, length: Number(length) });
      return Promise.resolve(data.subarray(at, at + Number(length)));
    },
  };
  let rows = 0;
  const inspected = await inspectFile(source, () => {
    rows += 1;
  });
  assert.equal(rows, inspected.recordCount);
  reads.length = 0;
  const validated = await validateFile(source);
  assert.equal(validated.ok, true);
  assert.ok(largestRead < data.length, `one range read buffered all ${data.length} bytes`);
  const footer = parseFooter(data.subarray(data.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES));
  const footerAt = data.length - FOOTER_TAIL_BYTES;
  const wholeSummaryReads = reads.filter(
    (read) => read.offset === footer.summaryStart && read.length === footerAt - footer.summaryStart,
  );
  assert.equal(
    wholeSummaryReads.length,
    1,
    `validation read the whole summary [${footer.summaryStart}, ${footerAt}) more than once; ` +
      "the single bounded read verifies its CRC",
  );
});

test("unit: a parser resource ceiling is a tool failure, not an invalid verdict", async () => {
  const contentLength = MAX_FRONT_MATTER_BYTES + 1;
  const metadataAt = MAGIC.length;
  const tailAt = metadataAt + RECORD_HEADER_BYTES + contentLength;
  const size = tailAt + MAGIC.length;
  const prefix = new Uint8Array(MAGIC.length + RECORD_HEADER_BYTES);
  prefix.set(MAGIC);
  prefix[metadataAt] = Opcode.Metadata;
  new DataView(prefix.buffer).setBigUint64(metadataAt + 1, BigInt(contentLength), true);
  let largestRead = 0;
  const source: IReadable = {
    size: () => Promise.resolve(BigInt(size)),
    read: (offset, length) => {
      const at = Number(offset);
      const count = Number(length);
      largestRead = Math.max(largestRead, count);
      const out = new Uint8Array(count);
      for (let i = 0; i < count; i++) {
        const absolute = at + i;
        if (absolute < prefix.length) out[i] = prefix[absolute]!;
        else if (absolute >= tailAt && absolute < size) out[i] = MAGIC[absolute - tailAt]!;
      }
      return Promise.resolve(out);
    },
  };

  await assert.rejects(
    () => validateFile(source),
    (error: unknown) =>
      error instanceof RangeError &&
      error.message.includes(`Metadata record at byte ${metadataAt}`) &&
      error.message.includes("resource limit for a single parsed record"),
  );
  assert.ok(largestRead <= 64 * 1024, `validation requested ${largestRead} bytes at once`);
});

test("regression: illegal top-level structures and malformed known records are refused", (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const original = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const summary = parseFooter(
    original.subarray(original.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES),
  ).summaryStart;

  for (const [name, record, expected] of [
    [
      "TopLevelAttributeStream",
      framedRecord(Opcode.AttributeStream, new Uint8Array(0)),
      "not a legal top-level record",
    ],
    ["ReservedZeroOpcode", framedRecord(0, new Uint8Array(0)), "not a legal top-level record"],
    ["MalformedCamera", framedRecord(Opcode.Camera, new Uint8Array(0)), "Camera record at byte"],
  ] as const) {
    const changed = splice(original.slice(), summary, record);
    const verdict = validated(file(`${name}.4dgs`, resealSummary(changed, record.length)));
    assert.equal(verdict.code, EXIT_FAILED);
    assert.ok(
      verdict.out.some((line) => line.includes(expected)),
      verdict.out.join("\n"),
    );
  }

  const header = recordsOf(original)[0]!;
  const duplicateHeader = original.slice(header.offset, header.offset + header.length);
  const doubled = splice(original.slice(), header.offset + header.length, duplicateHeader);
  const duplicateVerdict = validated(
    file("DuplicateHeader.4dgs", resealSummary(doubled, duplicateHeader.length)),
  );
  assert.equal(duplicateVerdict.code, EXIT_FAILED);
  assert.ok(
    duplicateVerdict.out.some((line) => line.includes("the first and only Header")),
    duplicateVerdict.out.join("\n"),
  );

  const badSummaryOffset = original.slice();
  const footerContent = badSummaryOffset.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  new DataView(
    badSummaryOffset.buffer,
    badSummaryOffset.byteOffset,
    badSummaryOffset.byteLength,
  ).setBigUint64(footerContent + 8, 1n, true);
  const footerVerdict = validated(file("BadSummaryOffsetStart.4dgs", badSummaryOffset));
  assert.equal(footerVerdict.code, EXIT_FAILED);
  assert.ok(
    footerVerdict.out.some((line) => line.includes("summary_offset_start is 1")),
    footerVerdict.out.join("\n"),
  );
});

test("regression: indexed opening discovers legal legacy Audio after a Chunk", async (t) => {
  const path = corpus("TenWindows-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const original = bytesOf("TenWindows-UseChunkIndex-UseCrc");
  const kept: Uint8Array[] = [];
  for (const record of iterateRecords(original, MAGIC.length)) {
    if (
      record.opcode === Opcode.ChunkIndex ||
      record.opcode === Opcode.Statistics ||
      record.opcode === Opcode.SummaryOffset ||
      record.opcode === Opcode.Footer
    ) {
      continue;
    }
    const raw = record.raw.slice();
    if (record.opcode === Opcode.Header) {
      const cursor = new Cursor(record.content);
      cursor.string();
      cursor.string();
      cursor.f64();
      cursor.u64();
      cursor.f64();
      cursor.string();
      cursor.f64s(6);
      cursor.u8();
      raw[RECORD_HEADER_BYTES + cursor.pos] |= HEADER_FLAG_HAS_AUDIO;
    }
    kept.push(raw);
  }
  const audio = new Uint8Array(23);
  const audioView = new DataView(audio.buffer);
  audioView.setUint32(0, 3, true);
  audio.set(new TextEncoder().encode("wav"), 4);
  audioView.setFloat64(7, 0, true);
  audioView.setBigUint64(15, 0n, true);
  const firstChunk = recordsOf(original).find((record) => record.opcode === Opcode.Chunk)!;
  const earlyAudioWithClearFlag = splice(
    original.slice(),
    firstChunk.offset,
    framedRecord(Opcode.Audio, audio),
  );
  await assert.rejects(
    () => IndexedDecoder.open(new BytesReadable(earlyAudioWithClearFlag), { headProbeBytes: 64 }),
    /Header audio flag is clear.*Audio record/,
  );
  const records = [
    MAGIC,
    ...kept,
    framedRecord(Opcode.Audio, audio),
    framedRecord(Opcode.Footer, new Uint8Array(20)),
    MAGIC,
  ];
  const total = records.reduce((sum, record) => sum + record.length, 0);
  const indexless = new Uint8Array(total);
  let at = 0;
  for (const record of records) {
    indexless.set(record, at);
    at += record.length;
  }

  const report = await validateFile(indexless);
  assert.equal(report.ok, true, report.findings.map((finding) => finding.message).join("\n"));
  assert.ok(
    report.findings.every((finding) => !finding.message.includes("a seeking reader cannot open")),
  );

  const lateAudio = [...iterateRecords(indexless, MAGIC.length)].find(
    (record) => record.opcode === Opcode.Audio,
  )!;
  const duplicateAudio = splice(
    indexless,
    lateAudio.offset + lateAudio.raw.length,
    framedRecord(Opcode.Audio, audio),
  );
  const duplicateReport = await validateFile(duplicateAudio);
  assert.ok(
    duplicateReport.findings.some(
      (finding) =>
        finding.message.includes("legacy Audio record 2") &&
        finding.message.includes(`byte ${lateAudio.offset + lateAudio.raw.length}`),
    ),
    duplicateReport.findings.map((finding) => finding.message).join("\n"),
  );

  const metadata = framedRecord(Opcode.Metadata, new Uint8Array(8));
  const lateMetadata = new Uint8Array(metadata.length * 3);
  lateMetadata.set(metadata, 0);
  lateMetadata.set(metadata, metadata.length);
  lateMetadata.set(metadata, metadata.length * 2);
  const footerAt = [...iterateRecords(indexless, MAGIC.length)].find(
    (record) => record.opcode === Opcode.Footer,
  )!.offset;
  const rangeFlood = splice(indexless, footerAt, lateMetadata);
  const bounded = await IndexedDecoder.open(new BytesReadable(rangeFlood), {
    headProbeBytes: 64,
    maxDeferredRecords: 2,
  });
  await assert.rejects(
    () => bounded.readMetadata(),
    /optional-record discovery stopped after 2 retained records.*bounded-memory limit/,
  );

  const reads: { offset: number; length: number }[] = [];
  const source: IReadable = {
    size: () => Promise.resolve(BigInt(indexless.length)),
    read: (offset, length) => {
      const at = Number(offset);
      const count = Number(length);
      reads.push({ offset: at, length: count });
      return Promise.resolve(indexless.subarray(at, at + count));
    },
  };
  const opened = await IndexedDecoder.open(source, { headProbeBytes: 64 });
  assert.ok(
    reads.every((read) => read.offset !== lateAudio.offset),
    "opening range-read the late Audio record before an audio accessor asked for it",
  );
  assert.equal((await opened.readAudio())?.codec, "wav");
  assert.ok(
    reads.some((read) => read.offset === lateAudio.offset),
    "the audio accessor did not discover the late Audio record",
  );
});

test("regression: deferred indexed discovery rejects modern audio after state", async (t) => {
  const variant = "OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const records = [...iterateRecords(original, MAGIC.length)];
  const audio = records
    .filter((record) => record.opcode === Opcode.AudioSource || record.opcode === Opcode.AudioData)
    .map((record) => record.raw.slice());
  const state = records
    .filter(
      (record) =>
        record.opcode !== Opcode.AudioSource &&
        record.opcode !== Opcode.AudioData &&
        record.opcode !== Opcode.ChunkIndex &&
        record.opcode !== Opcode.Statistics &&
        record.opcode !== Opcode.SummaryOffset &&
        record.opcode !== Opcode.Footer,
    )
    .map((record) => record.raw.slice());
  const late = indexlessFile([...state, ...audio]);
  const opened = await IndexedDecoder.open(new BytesReadable(late), { headProbeBytes: 64 });
  await assert.rejects(
    () => opened.readAudioSources(),
    /Audio Source id \d+ appears after the first Chunk/,
  );
});

test("unit: inspect reports an inexact record length at that record's byte", async () => {
  const bytes = new Uint8Array(MAGIC.length + RECORD_HEADER_BYTES);
  bytes.set(MAGIC);
  bytes[MAGIC.length] = Opcode.Chunk;
  new DataView(bytes.buffer).setBigUint64(MAGIC.length + 1, 1n << 60n, true);
  const report = await inspectFile({
    size: () => Promise.resolve(BigInt(bytes.length)),
    read: (offset, length) => {
      const at = Number(offset);
      return Promise.resolve(bytes.subarray(at, at + Number(length)));
    },
  });
  assert.match(report.stopped!, /offset 9 exceeds 2\^53/);
});

test("unit: the appended SH bit depths are parsed, tolerantly", (t) => {
  // The smallest seam: the record parser itself. The corpus states what these files
  // declare, and the encoder wrote the depths — TypeScript was simply the only reader that
  // could not read them back, which is why it was the only validator not checking them.
  const path = corpus("MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null) return t.skip("corpus not generated");
  const data = bytesOf("MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc");
  const record = recordsOf(data)[1]!;
  const content = data.subarray(record.offset + RECORD_HEADER_BYTES, record.offset + record.length);
  const quantization = parseQuantization(content);
  assert.deepEqual([...quantization.shBitDepths], [5, 4]);
  assert.equal(quantization.shBitDepthsMalformed, false);
  // Five bits is a pitch of 8 and a bound of 4, which is what the record's own bounds map
  // declares — the relationship the validator's check is about.
  assert.equal(shStep(5), 8);
  assert.equal(shBound(5), 4);
  assert.equal(quantization.bounds.get("sh_band1"), "4");
  assert.equal(quantization.stepSh, Math.max(shStep(5), shStep(4)));

  // Tolerant: a depth outside 3..8 is "this file declares none", not a corrupt file,
  // because anything a newer writer appended lands in exactly this position.
  const outOfRange = content.slice();
  outOfRange[outOfRange.length - 1] = 9;
  assert.deepEqual([...parseQuantization(outOfRange).shBitDepths], []);
  assert.equal(parseQuantization(outOfRange).shBitDepthsMalformed, true);
  const truncated = parseQuantization(content.slice(0, -1));
  assert.deepEqual([...truncated.shBitDepths], []);
  assert.equal(truncated.shBitDepthsMalformed, true);
});

test("regression: the SH bit depths are checked against the Header's degree", (t) => {
  const path = corpus("MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc");
  if (path === null || !existsSync(EXECUTABLE)) return t.skip("corpus not generated");
  const data = bytesOf("MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc");
  const quantization = recordsOf(data)[1]!;
  // The depths are the appended tail of the record: a count, then one byte per band. Six
  // bits gives a bound of 2, and the record still declares 4.
  data[quantization.offset + quantization.length - 2] = 6;
  const report = validated(file("WrongDepth.4dgs", data));
  assert.equal(report.code, EXIT_WARNINGS, report.out.join("\n"));
  assert.ok(
    report.out.includes(
      "warning: Quantization declares `sh_band1` as 4; 6 bits gives a bound of 2 (§6.5)",
    ),
    report.out.join("\n"),
  );
  assert.equal(report.out.at(-1), "valid (with notes)");

  const malformed = bytesOf("MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc");
  const malformedQuantization = recordsOf(malformed)[1]!;
  malformed[malformedQuantization.offset + malformedQuantization.length - 1] = 2;
  const malformedReport = validated(file("MalformedDepth.4dgs", malformed));
  assert.equal(malformedReport.code, EXIT_FAILED, malformedReport.out.join("\n"));
  assert.ok(
    malformedReport.out.some((line) => line.includes("malformed SH bit-depth declaration")),
    malformedReport.out.join("\n"),
  );
});

test("regression: per-band SH bounds compare as exact decimals", async (t) => {
  const variant = "MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);

  for (const spelling of ["4.0", `0.${"0".repeat(1000)}4e1001`]) {
    const equivalent = await validateFile(replaceQuantizationBound(original, "sh_band1", spelling));
    assert.ok(
      equivalent.findings.every((finding) => !finding.message.includes("`sh_band1` as")),
      equivalent.findings.map((finding) => finding.message).join("\n"),
    );
  }

  const different = await validateFile(
    replaceQuantizationBound(original, "sh_band1", "4.0000000000000001"),
  );
  assert.ok(
    different.findings.some((finding) => finding.message.includes("`sh_band1` as")),
    different.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: a bound is read by the grammar the specification writes down", async (t) => {
  const variant = "MixedLifetimes-SHBitsLow-SHDegree2-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);

  for (const [spelling, expected] of EQUIVALENT_BOUND_SPELLINGS) {
    const report = await validateFile(
      replaceQuantizationBound(original, "sh_band1", spelling, DEPTH_FOR_BOUND.get(expected)),
    );
    assert.ok(
      report.findings.every((finding) => !finding.message.includes("`sh_band1` as")),
      `${JSON.stringify(spelling)} should be ${expected}: ` +
        report.findings.map((finding) => finding.message).join("\n"),
    );
  }

  for (const [spelling, expected] of REJECTED_BOUND_SPELLINGS) {
    const report = await validateFile(
      replaceQuantizationBound(original, "sh_band1", spelling, DEPTH_FOR_BOUND.get(expected)),
    );
    assert.ok(
      report.findings.some((finding) => finding.message.includes("`sh_band1` as")),
      `${JSON.stringify(spelling)} should not be ${expected}: ` +
        report.findings.map((finding) => finding.message).join("\n"),
    );
  }
});

test("regression: sh_degree zero ignores an appended SH bit-depth suffix", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const quantization = recordsOf(original).find((record) => record.opcode === Opcode.Quantization)!;
  const extended = splice(original, quantization.offset + quantization.length, Uint8Array.of(9));
  new DataView(extended.buffer, extended.byteOffset, extended.byteLength).setBigUint64(
    quantization.offset + 1,
    BigInt(quantization.length - RECORD_HEADER_BYTES + 1),
    true,
  );
  const report = await validateFile(resealSummary(extended, 1));
  assert.ok(
    report.findings.every((finding) => !finding.message.includes("malformed SH bit-depth")),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: Summary Offset records belong to the declared summary", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const summaryOffset = recordsOf(original).find(
    (record) => record.opcode === Opcode.SummaryOffset,
  )!;
  const copy = original.slice(summaryOffset.offset, summaryOffset.offset + summaryOffset.length);
  const firstChunk = recordsOf(original).find((record) => record.opcode === Opcode.Chunk)!;
  const moved = resealSummary(splice(original, firstChunk.offset, copy), copy.length);
  const footerContent = moved.length - FOOTER_TAIL_BYTES + RECORD_HEADER_BYTES;
  new DataView(moved.buffer, moved.byteOffset, moved.byteLength).setBigUint64(
    footerContent + 8,
    BigInt(firstChunk.offset),
    true,
  );

  const report = await validateFile(moved);
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes(`Summary Offset record at byte ${firstChunk.offset}`) &&
        finding.message.includes("outside the declared summary"),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: every Statistics record belongs to the declared summary", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const statistics = recordsOf(original).find((record) => record.opcode === Opcode.Statistics)!;
  const copy = original.slice(statistics.offset, statistics.offset + statistics.length);
  const firstChunk = recordsOf(original).find((record) => record.opcode === Opcode.Chunk)!;
  const moved = resealSummary(splice(original, firstChunk.offset, copy), copy.length);

  const report = await validateFile(moved);
  assert.ok(
    report.findings.some(
      (finding) =>
        finding.message.includes(`Statistics record at byte ${firstChunk.offset}`) &&
        finding.message.includes("outside the declared summary"),
    ),
    report.findings.map((finding) => finding.message).join("\n"),
  );
});

test("regression: Statistics values describe the Header, chunks, and index", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset";
  if (corpus(variant) === null) return t.skip("corpus not generated");

  for (const [name, patch, expected] of [
    [
      "gaussian_count",
      (view: DataView, at: number) => view.setBigUint64(at, 999n, true),
      "declares gaussian_count 999",
    ],
    [
      "chunk_count",
      (view: DataView, at: number) => view.setUint32(at + 8, 999, true),
      "declares chunk_count 999",
    ],
    [
      "duration_sec",
      (view: DataView, at: number) => view.setFloat64(at + 12, 999, true),
      "declares duration_sec 999",
    ],
  ] as const) {
    const bytes = bytesOf(variant);
    const statistics = recordsOf(bytes).find((record) => record.opcode === Opcode.Statistics)!;
    patch(
      new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
      statistics.offset + RECORD_HEADER_BYTES,
    );
    const report = await validateFile(resealSummary(bytes));
    assert.ok(
      report.findings.some((finding) => finding.message.includes(expected)),
      `${name}: ${report.findings.map((finding) => finding.message).join("\n")}`,
    );
  }
});

test("regression: every Summary Offset names a nonempty in-summary range", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset";
  if (corpus(variant) === null) return t.skip("corpus not generated");

  for (const [name, patch, expected] of [
    [
      "zero",
      (view: DataView, at: number) => view.setBigUint64(at + 9, 0n, true),
      "zero-length group",
    ],
    [
      "past-footer",
      (view: DataView, at: number) => view.setBigUint64(at + 9, 1n << 48n, true),
      "outside the summary",
    ],
  ] as const) {
    const bytes = bytesOf(variant);
    const summaryOffset = recordsOf(bytes).find(
      (record) => record.opcode === Opcode.SummaryOffset,
    )!;
    patch(
      new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
      summaryOffset.offset + RECORD_HEADER_BYTES,
    );
    const report = await validateFile(resealSummary(bytes));
    assert.ok(
      report.findings.some((finding) => finding.message.includes(expected)),
      `${name}: ${report.findings.map((finding) => finding.message).join("\n")}`,
    );
  }
});

test("regression: gaussian-birth skips a future Chunk Index suffix", async (t) => {
  const variant = "TenWindows-UseChunkIndex-UseCrc";
  if (corpus(variant) === null) return t.skip("corpus not generated");
  const original = bytesOf(variant);
  const entry = recordsOf(original).find((record) => record.opcode === Opcode.ChunkIndex)!;
  const suffix = new Uint8Array(28);
  suffix[0] = 1; // Would be chunk_kind=delta if this were keyframe-delta.
  suffix[1] = 1;
  const extended = splice(original, entry.offset + entry.length, suffix);
  new DataView(extended.buffer, extended.byteOffset, extended.byteLength).setBigUint64(
    entry.offset + 1,
    BigInt(entry.length - RECORD_HEADER_BYTES + suffix.length),
    true,
  );
  const report = await validateFile(resealSummary(extended));
  assert.equal(report.ok, true, report.findings.map((finding) => finding.message).join("\n"));
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
