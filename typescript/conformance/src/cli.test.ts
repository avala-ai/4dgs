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
  Crc32,
  Cursor,
  FOOTER_TAIL_BYTES,
  MAGIC,
  Opcode,
  RECORD_HEADER_BYTES,
  iterateRecords,
  parseFooter,
  parseQuantization,
  shBound,
  shStep,
  type IReadable,
} from "@4dgs/core";
import { inspectFile } from "@4dgs/nodejs";
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

function splice(data: Uint8Array, at: number, insert: Uint8Array): Uint8Array {
  const out = new Uint8Array(data.length + insert.length);
  out.set(data.subarray(0, at));
  out.set(insert, at);
  out.set(data.subarray(at), at + insert.length);
  return out;
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
 * not `5` on purpose — the refusal is about the magic, and the magic starts at 0. The
 * identifiers are not written here at all; they are read out of the corpus.
 */
const REFUSED_AT: Readonly<Record<string, number>> = {
  BadMagic: 0,
  EmptyTemporalModel: 8,
  FutureMajorVersion: 0,
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
    decoded.out.some((line) => /SH band 1 does not decode: stream codec 9/.test(line)),
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
});

test("unit: inspect refuses a resource size that cannot be represented exactly", async () => {
  const size = BigInt(Number.MAX_SAFE_INTEGER) + 1n;
  const unreadable: IReadable = {
    size: () => Promise.resolve(size),
    read: () => Promise.reject(new Error("inspect must reject the size before reading")),
  };
  await assert.rejects(
    inspectFile(unreadable),
    new RegExp(`resource size ${size} exceeds the largest exactly addressable size`),
  );
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
  assert.deepEqual([...parseQuantization(content.slice(0, -1)).shBitDepths], []);
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
