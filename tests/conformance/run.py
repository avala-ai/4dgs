#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Run every implementation's runners over the corpus and diff against expectations.

    python3 tests/conformance/run.py                 # every registered runner
    python3 tests/conformance/run.py --runner python
    python3 tests/conformance/run.py --update        # rewrite expectations

A runner that declines a variant is SKIPPED, not failed. Partial implementations are a
supported state, and the feature matrix is where that shows up publicly.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

#: Where a language's built runners live, when it has a build step. A family whose
#: entry point is missing is skipped with a note rather than reported as 67 failures:
#: a Python-only contributor running the whole suite has not broken anything.
TYPESCRIPT_DIST = os.path.join(ROOT, "typescript", "conformance", "dist")
CPP_BUILD = os.path.join(ROOT, "cpp", "build", "conformance")
#: Cargo puts workspace binaries in one place regardless of which crate declares them.
RUST_BIN = os.path.join(ROOT, "target", "release")
SWIFT_BIN = os.path.join(ROOT, "swift", ".build", "release")
#: Dart's runners could be `dart run <script>`, and are compiled instead. A script
#: always exists, so the "is it built?" test below would always pass and a machine
#: without a Dart SDK would report 67 failures rather than a skip.
DART_BIN = os.path.join(ROOT, "dart", "conformance", "build")

#: Windows puts a suffix on an executable. The harness finds a runner by testing its path
#: for existence, so without this every compiled family looks "not built" on Windows — and
#: because a family that never ran is a failure rather than a pass, `--runner rust` then
#: goes red for a reason that has nothing to do with the runner.
EXE = ".exe" if os.name == "nt" else ""

#: (family, name, argv-prefix). A new language adds one line.
RUNNERS = [
    (
        "python",
        "python/decode_streamed",
        [sys.executable, os.path.join(ROOT, "python", "conformance", "decode_streamed.py")],
    ),
    (
        "python",
        "python/decode_indexed",
        [sys.executable, os.path.join(ROOT, "python", "conformance", "decode_indexed.py")],
    ),
    ("typescript", "typescript/decode_streamed", ["node", os.path.join(TYPESCRIPT_DIST, "decode_streamed.js")]),
    ("typescript", "typescript/decode_indexed", ["node", os.path.join(TYPESCRIPT_DIST, "decode_indexed.js")]),
    ("cpp", "cpp/decode_streamed", [os.path.join(CPP_BUILD, "decode_streamed" + EXE)]),
    ("cpp", "cpp/decode_indexed", [os.path.join(CPP_BUILD, "decode_indexed" + EXE)]),
    ("rust", "rust/decode_streamed", [os.path.join(RUST_BIN, "decode_streamed" + EXE)]),
    ("rust", "rust/decode_indexed", [os.path.join(RUST_BIN, "decode_indexed" + EXE)]),
    ("swift", "swift/decode_streamed", [os.path.join(SWIFT_BIN, "decode_streamed" + EXE)]),
    ("swift", "swift/decode_indexed", [os.path.join(SWIFT_BIN, "decode_indexed" + EXE)]),
    ("dart", "dart/decode_streamed", [os.path.join(DART_BIN, "decode_streamed" + EXE)]),
    ("dart", "dart/decode_indexed", [os.path.join(DART_BIN, "decode_indexed" + EXE)]),
]


INVALID = os.path.join(DATA, "invalid")

#: Invalid variants are named with this prefix, which is also their subdirectory. A
#: runner is handed the same thing either way — a path — and the harness compares the
#: same thing either way: parsed JSON against a committed expectation. What differs is
#: only what a correct answer looks like.
INVALID_PREFIX = "invalid/"


def variants() -> list[str]:
    valid = sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))
    refusals = []
    if os.path.isdir(INVALID):
        refusals = sorted(INVALID_PREFIX + f[: -len(".json")] for f in os.listdir(INVALID) if f.endswith(".json"))
    return valid + refusals


#: Families whose runners answer a refusal expectation — printing `{"refused": "<id>"}`
#: for a file they refuse, rather than exiting non-zero. A family absent here SKIPS the
#: invalid corpus, exactly as it would skip any variant it declines, and the feature
#: matrix is where that shows up publicly. Adding a language is one entry here plus the
#: few lines in its runner that catch the refusal and print its identifier.
REFUSAL_FAMILIES = frozenset({"python"})


#: Record families a language has not implemented, by the variant-name flags that carry
#: them. A partial implementation is a supported state — the feature matrix is where it
#: shows up publicly — and declining a variant is how a runner says so.
#:
#: The provenance family (spec section 5.15) is optional and flagged, so declining it
#: costs these families nothing anywhere else: every variant that does not carry a
#: provenance record is byte-identical to what it was before the family existed, and they
#: pass all of them with no change at all. That is the forward-compatibility mechanism
#: working, and it would be reported as thirty-four failures if the summary announced the
#: family on files that do not use it.
#:
#: Declining is not the same as failing to read. Each of these decoders steps over a
#: provenance record by its length and finishes the file correctly — that is what the
#: `AddExtraDataToRecords` variants prove. What they do not do is *report* the family, so
#: their summaries would omit a key the expectation carries, and a diff cannot tell that
#: apart from a decoder that got it wrong.
FAMILY_DECLINES: dict[str, tuple[str, ...]] = {
    "typescript": ("WithFrame", "WithGeodetic", "WithSensors", "WithRig", "WithObjects"),
    "cpp": ("WithFrame", "WithGeodetic", "WithSensors", "WithRig", "WithObjects"),
    "rust": ("WithObjects",),
    "swift": ("WithFrame", "WithGeodetic", "WithSensors", "WithRig", "WithObjects"),
    "dart": ("WithFrame", "WithGeodetic", "WithSensors", "WithRig", "WithObjects"),
}


def supports(runner_name: str, variant: str) -> bool:
    family = runner_name.split("/", maxsplit=1)[0]
    if any(flag in variant for flag in FAMILY_DECLINES.get(family, ())):
        return False
    if variant.startswith(INVALID_PREFIX) and family not in REFUSAL_FAMILIES:
        return False
    if not runner_name.endswith("decode_indexed"):
        return True
    # The invalid corpus is cut from a variant that carries an index, so both read paths
    # can be asked to refuse it. That matters: the two paths reach the Header by
    # different routes — one front to back, one through the Footer — and a check placed
    # on only one of them refuses half the files it should.
    if variant.startswith(INVALID_PREFIX):
        return True
    return "UseChunkIndex" in variant


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="run the 4dgs conformance suite")
    parser.add_argument("--runner", help="only this family (e.g. python)")
    parser.add_argument("--update", action="store_true", help="rewrite expectations from the runner output")
    args = parser.parse_args(argv)

    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1

    passed = skipped = failed = 0
    ran_families: set[str] = set()
    for family, runner_name, command in RUNNERS:
        if args.runner and family != args.runner:
            continue
        if not os.path.exists(command[-1]):
            print(f"skipping {runner_name}: {command[-1]} is not built")
            continue
        ran_families.add(family)
        for variant in names:
            if not supports(runner_name, variant):
                skipped += 1
                continue
            # `variant` may carry the invalid corpus's `invalid/` prefix; split it so
            # the separator is the platform's rather than the name's.
            parts = variant.split("/")
            path = os.path.join(DATA, *parts[:-1], f"{parts[-1]}.4dgs")
            expectation_path = os.path.join(DATA, *parts[:-1], f"{parts[-1]}.json")
            # check=False: a runner exiting non-zero is a reportable failure, not an
            # exception — the harness prints it alongside the others.
            result = subprocess.run([*command, path], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                failed += 1
                print(f"FAIL {runner_name} {variant}: runner exited {result.returncode}")
                print(result.stderr.strip()[:2000])
                continue
            actual = result.stdout.strip()
            if args.update:
                with open(expectation_path, "w", encoding="utf-8") as fh:
                    fh.write(actual + "\n")
                passed += 1
                continue
            with open(expectation_path, encoding="utf-8") as fh:
                expected = fh.read().strip()
            if json.loads(actual) == json.loads(expected):
                passed += 1
            else:
                failed += 1
                print(f"FAIL {runner_name} {variant}")
                diff = difflib.unified_diff(
                    expected.splitlines(), actual.splitlines(), "expected", "actual", lineterm="", n=2
                )
                for line in list(diff)[:40]:
                    print("  " + line)

    print(f"\n{passed} passed, {skipped} skipped (variant not supported), {failed} failed")
    if failed:
        return 1
    # A runner family that was asked for and never ran is a failure, not a pass. The
    # alternative is a green suite that proved nothing, which is worse than a red one.
    if args.runner and args.runner not in ran_families:
        print(f"error: no runner for --runner {args.runner} was executed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
