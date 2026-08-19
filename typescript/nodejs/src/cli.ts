#!/usr/bin/env node
// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * `4dgs`: inspect and check `.4dgs` files from a shell.
 *
 * Thin by design — every command is a few lines over the library, so anything the CLI can
 * do is something a caller can do. That rule is the Python tool's, and it is repeated here
 * because it is what keeps a command-line tool from becoming a second, undocumented
 * implementation of the format.
 *
 * The tools are expected to agree. Where a command exists in more than one of them, it
 * reads the same records, prints the same values in the same order, and exits the same way;
 * a difference between two of them on one file is a bug in one of them, not a matter of
 * taste. What this one adds is the **refusal identifier** and the byte it fired at, because
 * the sentence a library raises is the language's and the identifier is the format's.
 *
 * It lives in `@4dgs/nodejs` rather than in `@4dgs/core` because it opens files, and I/O
 * lives at the edges (AGENTS.md §3). `@4dgs/core` stays a decoder over a byte-range
 * abstraction with no filesystem in it.
 */

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { FourdgsError, MAGIC, checkMagic } from "@4dgs/core";
import { FileHandleReadable } from "./index.js";
import { inspectFile, type InspectedRecord, type InspectReport } from "./inspect.js";
import { validateFile, type Report } from "./validate.js";

/**
 * Exit codes, which are the only part of a CLI another program reads.
 *
 * A validator that answered 0 for "some warnings" and 0 for "nothing to say" would make the
 * warnings unreachable from a script, so they get their own code — that much is the Rust
 * tool's. `TOOL_FAILED` is this tool's own: exiting 1 both for "I read the file and it is
 * not conforming" and for "I fell over" makes a verdict about a file indistinguishable from
 * a broken tool, and a pipeline cannot tell those apart after the fact.
 */
export const EXIT_OK = 0;
export const EXIT_FAILED = 1;
export const EXIT_WARNINGS = 2;
export const EXIT_TOOL_FAILED = 3;

const USAGE = `4dgs — inspect and validate .4dgs files

usage:
  4dgs inspect <file> [--json]       walk the records: offset, opcode, length, crc
  4dgs validate <file> [--decode]    check a file against the specification
  4dgs --version
  4dgs --help

options:
  --json      machine-readable output (inspect)
  --decode    decode every chunk as well, so a refusal that only a decoder can
              reach — an unimplemented stream codec, a window index with no row —
              is named too (validate)

exit codes:
  0  fine
  1  refused, or invalid
  2  valid, with warnings
  3  the tool itself failed: a usage error, an unreadable path, a bug
`;

/** Where output goes. Injected so the tests read what a user would read. */
export interface Sink {
  out(line: string): void;
  err(line: string): void;
}

const CONSOLE: Sink = {
  out: (line) => process.stdout.write(`${line}\n`),
  err: (line) => process.stderr.write(`${line}\n`),
};

interface Args {
  readonly command: "inspect" | "validate";
  readonly file: string;
  readonly json: boolean;
  readonly decode: boolean;
}

function parseArgs(argv: readonly string[]): Args {
  if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h") {
    throw new Served(USAGE.trimEnd());
  }
  if (argv[0] === "--version") throw new Served(VERSION);
  const command = argv[0];
  if (command !== "inspect" && command !== "validate") {
    throw new UsageError(`unknown command ${JSON.stringify(command)}`);
  }
  let file: string | null = null;
  let json = false;
  let decode = false;
  for (const argument of argv.slice(1)) {
    if (argument === "--json") json = true;
    else if (argument === "--decode") decode = true;
    else if (argument.startsWith("-")) throw new UsageError(`unknown option ${argument}`);
    else if (file !== null) throw new UsageError("more than one file given");
    else file = argument;
  }
  if (file === null) throw new UsageError(`${command} needs a file`);
  if (json && command !== "inspect") throw new UsageError("--json applies to inspect");
  if (decode && command !== "validate") throw new UsageError("--decode applies to validate");
  return { command, file, json, decode };
}

/**
 * The published version.
 *
 * Written here as well as in `package.json` because importing JSON from a `composite`
 * TypeScript project drags the manifest into the build output. A test asserts the two agree,
 * which is what keeps the duplication from becoming a lie.
 */
export const VERSION = "0.6.0";

class UsageError extends Error {}
/** A request that was answered by printing, rather than one that failed. */
class Served extends Error {}

/** Run one invocation and return the exit code. Never throws for a file's sake. */
export async function main(argv: readonly string[], sink: Sink = CONSOLE): Promise<number> {
  let args: Args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    if (error instanceof Served) {
      sink.out(error.message);
      return EXIT_OK;
    }
    sink.err(`4dgs: ${(error as Error).message}`);
    sink.err(`\n${USAGE.trimEnd()}`);
    return EXIT_TOOL_FAILED;
  }

  try {
    return args.command === "inspect" ? await inspect(args, sink) : await validate(args, sink);
  } catch (error) {
    // A `FourdgsError` here is a verdict about the file: the magic check is the one refusal
    // that leaves nothing to walk. Anything else — a missing path, a permission, a bug in
    // this tool — is the tool failing, and says so with its own code rather than borrowing
    // the file's.
    if (error instanceof FourdgsError) {
      sink.err(`4dgs: ${args.file}: ${error.message}`);
      if (error.refusalCode !== undefined) {
        const at = error.refusalCode === "unsupported-major-version" ? 5 : 0;
        const where = at === 5 ? "the major-version byte" : "the file magic";
        sink.err(`4dgs: refused: ${error.refusalCode} at byte ${at} (${where})`);
      }
      return EXIT_FAILED;
    }
    sink.err(`4dgs: ${args.file}: ${(error as Error).message}`);
    return EXIT_TOOL_FAILED;
  }
}

async function inspect(args: Args, sink: Sink): Promise<number> {
  const source = await FileHandleReadable.open(args.file);
  let report: InspectReport;
  try {
    report = args.json ? await inspectJson(source, sink) : await inspectText(source, sink);
  } finally {
    await source.close();
  }
  if (report.stopped !== null) {
    sink.err(`4dgs: stopped: ${report.stopped}`);
    return EXIT_FAILED;
  }
  // A file that does not end with the magic is truncated or was written by a broken
  // encoder — `validate` calls that an error, and a walk that printed the same observation
  // as a note and exited 0 would let a pipeline accept what the validator refuses.
  if (!report.trailingMagic) return EXIT_FAILED;
  return report.summaryCrc !== null && !report.summaryCrc.ok ? EXIT_FAILED : EXIT_OK;
}

async function validate(args: Args, sink: Sink): Promise<number> {
  const source = await FileHandleReadable.open(args.file);
  let report: Report;
  try {
    report = await validateFile(source, { decode: args.decode });
  } finally {
    await source.close();
  }
  print(report, sink);
  if (!report.ok) {
    sink.err("INVALID");
    return EXIT_FAILED;
  }
  sink.out(report.findings.length === 0 ? "valid" : "valid (with notes)");
  // The one deliberate divergence from the Python tool, which exits 0 here. A warning a
  // script cannot see is a warning nobody acts on, so it gets its own code — as the Rust
  // tool's does.
  return report.warned ? EXIT_WARNINGS : EXIT_OK;
}

function print(report: Report, sink: Sink): void {
  for (const finding of report.findings) sink.out(`${finding.severity}: ${finding.message}`);
  if (report.refused !== null) {
    const { code, at, where } = report.refused;
    sink.out(`refused: ${code} at byte ${at} (${where})`);
  }
}

/**
 * A count with thousands separators, matching the Python tool's `{:,}`.
 *
 * Written out rather than left to `toLocaleString`, which answers differently on a runtime
 * built without the full locale data — and what a validator prints should not depend on how
 * somebody's Node was compiled.
 */
function commas(n: number): string {
  const digits = String(n);
  let out = "";
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ",";
    out += digits[i];
  }
  return out;
}

function pad(text: string, width: number, right = true): string {
  return right ? text.padStart(width) : text.padEnd(width);
}

/**
 * The Rust tool's four columns, in its widths, plus one.
 *
 * The `crc` column is this tool's addition, because the walk is supposed to answer "and is
 * this record under the file's checksum" and framing alone cannot. It is appended rather
 * than inserted, so a script reading the first four columns reads the same four.
 */
async function inspectText(source: FileHandleReadable, sink: Sink): Promise<InspectReport> {
  const crcOf = (record: InspectedRecord): string =>
    !record.covered ? "" : record.summaryOk === true ? "ok" : "MISMATCH";
  const line = (a: string, b: string, c: string, d: string, e: string): void =>
    sink.out(`${pad(a, 12)}  ${pad(b, 18, false)} ${pad(c, 14)}  ${pad(d, 14)}  ${e}`.trimEnd());

  line("offset", "record", "content", "total", "crc");
  line("0", "(magic)", "", "8", "");
  const report = await inspectFile(source, (record) => {
    // `covered` was computed from the checksum report before the record walk, so the row
    // can be emitted and forgotten immediately. This keeps one short record from becoming
    // one retained object for the lifetime of an arbitrarily large file.
    line(
      commas(record.offset),
      record.name,
      commas(record.contentLength),
      commas(record.totalLength),
      crcOf(record),
    );
  });
  const summary = report.summaryCrc;
  if (report.trailingMagic) line(commas(report.size - 8), "(magic)", "", "8", "");

  const cut = report.stopped !== null ? " (the last record is incomplete)" : "";
  sink.out(`\n${report.recordCount} records, ${commas(report.size)} bytes${cut}`);
  if (summary === null) {
    sink.out(`summary crc    none — ${report.summaryCrcAbsent ?? "unavailable"}`);
  } else {
    const verdict = summary.ok ? "ok" : "MISMATCH";
    sink.out(
      `summary crc    ${verdict}  (covers bytes ${commas(summary.start)}..${commas(summary.end)})`,
    );
  }
  if (!report.trailingMagic && report.stopped === null) {
    sink.out("note: the file does not end with the magic");
  }
  return report;
}

async function inspectJson(source: FileHandleReadable, sink: Sink): Promise<InspectReport> {
  // `inspectFile` throws on bad magic because there are no 4DGS records to walk. Perform
  // that preflight before opening the JSON document so a normal file refusal cannot leave
  // an unterminated fragment on stdout. The size guard mirrors inspectFile's only other
  // pre-record failure and keeps the same guarantee for an unaddressable resource.
  const size = await source.size();
  if (size > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError(
      `resource size ${size} exceeds the largest exactly addressable size ` +
        `${Number.MAX_SAFE_INTEGER} in this implementation`,
    );
  }
  checkMagic(await source.read(0n, BigInt(Math.min(MAGIC.length, Number(size)))));
  sink.out('{"records":[');
  let first = true;
  const report = await inspectFile(source, (record) => {
    sink.out(`${first ? "" : ","}${JSON.stringify(jsonRecord(record))}`);
    first = false;
  });
  const summary = report.summaryCrc;
  sink.out(
    `],"size":${report.size},"trailing_magic":${report.trailingMagic},` +
      `"stopped":${JSON.stringify(report.stopped)},` +
      `"summary_crc_absent":${JSON.stringify(report.summaryCrcAbsent)},` +
      `"summary_crc":${JSON.stringify(
        summary === null
          ? null
          : {
              start: summary.start,
              end: summary.end,
              declared: summary.declared,
              actual: summary.actual,
              ok: summary.ok,
            },
      )}}`,
  );
  return report;
}

function jsonRecord(record: InspectedRecord): Record<string, unknown> {
  return {
    offset: record.offset,
    opcode: record.opcode,
    name: record.name,
    content_length: record.contentLength,
    total_length: record.totalLength,
    crc_covered: record.covered,
  };
}

/**
 * True when this module is what was invoked, rather than imported.
 *
 * Compared after `realpath`, because the installed `4dgs` is a **symlink**: npm links
 * `node_modules/.bin/4dgs` at this file, and Node resolves the entry point it reports in
 * `import.meta.url` through that link while leaving `process.argv[1]` as the path the
 * shell used. Comparing the two directly is false for every installed invocation, so the
 * advertised executable would exit 0 having printed nothing — the one failure mode a
 * command-line tool must not have. Resolving both ends makes the comparison about the
 * file rather than about the route taken to it.
 */
function invokedDirectly(argv1: string | undefined): boolean {
  if (argv1 === undefined) return false;
  const here = fileURLToPath(import.meta.url);
  try {
    return realpathSync(argv1) === realpathSync(here);
  } catch {
    // An `argv[1]` that no longer resolves is not this file; a `realpath` that fails on
    // this file itself means the module was loaded from something the filesystem cannot
    // name, and neither is a reason to fall over before parsing an argument.
    return argv1 === here;
  }
}

// Run only when this module is what was invoked, so the tests can import `main` and drive
// it without the process exiting underneath them.
if (invokedDirectly(process.argv[1])) {
  process.exitCode = await main(process.argv.slice(2));
}
