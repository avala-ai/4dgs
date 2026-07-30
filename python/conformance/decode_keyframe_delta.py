#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Conformance runner: keyframe-delta decode, canonical ``states`` JSON to stdout.

The interface is the same as every other runner: take a path, print the canonical JSON a
cross-implementation gate diffs on. Both read paths are exercised and required to agree
before the JSON is printed, exactly as the Rust runner does.
"""

from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fourdgs"))

from fourdgs import keyframe_delta_file as kdf


def run(path: str) -> str:
    with open(path, "rb") as fh:
        data = fh.read()
    streamed = kdf.decode_streamed(data)
    indexed, _ = kdf.decode_indexed(data)
    a = kdf.states_json(streamed)
    b = kdf.states_json(indexed)
    if a != b:
        raise SystemExit(f"{path}: the streamed and indexed read paths disagree on the same file")
    return json.dumps(a)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: decode_keyframe_delta.py <file.4dgs>", file=sys.stderr)
        return 2
    print(run(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
