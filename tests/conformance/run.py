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
]


def variants() -> list[str]:
    return sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))


def supports(runner_name: str, variant: str) -> bool:
    if runner_name.endswith("decode_indexed"):
        return "UseChunkIndex" in variant
    return True


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
    for family, runner_name, command in RUNNERS:
        if args.runner and family != args.runner:
            continue
        for variant in names:
            if not supports(runner_name, variant):
                skipped += 1
                continue
            path = os.path.join(DATA, f"{variant}.4dgs")
            expectation_path = os.path.join(DATA, f"{variant}.json")
            result = subprocess.run(command + [path], capture_output=True, text=True)
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
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
