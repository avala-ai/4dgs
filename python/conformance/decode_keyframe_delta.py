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

import fourdgs
from fourdgs import keyframe_delta_file as kdf


def run(path: str, *, max_decoded_state_bytes: int = fourdgs.DEFAULT_MAX_DECODED_STATE_BYTES) -> str:
    with open(path, "rb") as fh:
        data = fh.read()
    streamed = kdf.decode_streamed(data, max_decoded_state_bytes=max_decoded_state_bytes)
    indexed, _ = kdf.decode_indexed(data, max_decoded_state_bytes=max_decoded_state_bytes)
    a = kdf.states_json(streamed)
    b = kdf.states_json(indexed)
    if a != b:
        raise SystemExit(f"{path}: the streamed and indexed read paths disagree on the same file")
    return json.dumps(a)


def main() -> int:
    if len(sys.argv) == 2:
        path = sys.argv[1]
        max_decoded_state_bytes = fourdgs.DEFAULT_MAX_DECODED_STATE_BYTES
    elif len(sys.argv) == 4 and sys.argv[1] == "--max-decoded-state-bytes":
        path = sys.argv[3]
        try:
            max_decoded_state_bytes = int(sys.argv[2])
        except ValueError:
            print("--max-decoded-state-bytes must be a positive integer", file=sys.stderr)
            return 2
        if max_decoded_state_bytes <= 0:
            print("--max-decoded-state-bytes must be a positive integer", file=sys.stderr)
            return 2
    else:
        print(
            "usage: decode_keyframe_delta.py [--max-decoded-state-bytes N] <file.4dgs>",
            file=sys.stderr,
        )
        return 2
    try:
        print(run(path, max_decoded_state_bytes=max_decoded_state_bytes))
    except fourdgs.ExceedsReaderLimit:
        print('{"unsupported":"resource-limit"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
