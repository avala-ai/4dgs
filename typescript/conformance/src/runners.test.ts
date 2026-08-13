// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * What the conformance runners claim when a file will not decode.
 *
 * The harness reads two things from a runner: its exit status and its stdout. Those carry
 * two different claims, and the invalid corpus only means anything while they stay apart.
 * Exit 0 with `{"refused": "<identifier>"}` says "I refused this file, and here is the rule
 * it broke" — an answer, diffed against the committed expectation. A non-zero exit says "I
 * did not produce an answer at all".
 *
 * An error the refusal table does not name belongs to the second claim. Written as
 * `{"refused": ""}` with exit 0 it becomes the first: the empty string is not an identifier
 * the format defines, so the harness is handed a refusal it cannot check, and `--update` —
 * which writes what a runner prints, before parsing it — would commit that as the
 * expectation every other SDK is scored against.
 *
 * Both entry points are driven as subprocesses, because the three things this pins —
 * stdout, stderr and exit status — are what the harness branches on, and no in-process call
 * proves them. All three are asserted together on purpose: the old handling satisfied two
 * of them, printing a well-formed JSON document and exiting cleanly, and only the
 * identifier inside it said anything was wrong.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

/** The built runners, spawned the way `tests/conformance/run.py` spawns them. */
const RUNNERS = ["decode_streamed.js", "decode_indexed.js"] as const;

/**
 * Too short to hold the magic: a truncated transport. That is a real decode failure, and
 * one the refusal table deliberately does not name — `checkMagic` on fewer than eight
 * bytes raises without a `refusalCode`. Both read paths reach it, the streamed runner
 * front to back and the indexed one through its opener, so it asks both the same question.
 */
const UNNAMED = new Uint8Array([0x34, 0x44, 0x47]);

/**
 * The magic is the one refusal a file this small can still carry a name for, which makes
 * it the control: the fix must not turn named refusals into failures on its way to turning
 * unnamed ones into failures.
 */
const NAMED = new TextEncoder().encode("NOT4DGS!\n");

interface Run {
  readonly code: number;
  readonly out: string;
  readonly err: string;
}

function runner(name: string): string {
  return fileURLToPath(new URL(`./${name}`, import.meta.url));
}

/** `data` on disk in a directory the test owns, decoded by `name` in its own process. */
function decode(name: string, data: Uint8Array): Run {
  const path = join(mkdtempSync(join(tmpdir(), "fourdgs-runner-")), "input.4dgs");
  writeFileSync(path, data);
  const result = spawnSync(process.execPath, [runner(name), path], { encoding: "utf8" });
  assert.equal(result.error, undefined, `could not run ${name}`);
  return { code: result.status ?? -1, out: result.stdout, err: result.stderr };
}

for (const name of RUNNERS) {
  test(`${name}: an error the refusal table cannot name is a failed invocation`, () => {
    const done = decode(name, UNNAMED);
    assert.notEqual(done.code, 0, `${name} claimed an answer for an error it cannot name`);
    assert.equal(done.out, "", `${name} printed a document for a failed invocation`);
    assert.ok(!done.out.includes("refused"), `${name} printed a refusal: ${done.out}`);
    assert.ok(done.err.trim() !== "", `${name} failed without saying why`);
  });

  test(`${name}: a named refusal is still an answer`, () => {
    const done = decode(name, NAMED);
    assert.equal(done.code, 0, `${name} failed the invocation for a refusal it named: ${done.err}`);
    assert.deepEqual(JSON.parse(done.out), { refused: "magic-mismatch" });
    assert.equal(done.err, "");
  });
}
