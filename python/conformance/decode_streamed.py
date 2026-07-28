#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Conformance runner: streamed decode, canonical JSON to stdout.

The whole interface between an implementation and the harness is this: take a path,
print the canonical JSON. A new language needs one of these and one line in the harness.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fourdgs"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "conformance"))

from canonical import canonical, summarize  # noqa: E402

import fourdgs  # noqa: E402

#: Variants this runner declines. Empty: the reference implementation supports the whole
#: matrix, which is the only reason it is allowed to be the reference.
UNSUPPORTED: frozenset[str] = frozenset()


def supports_variant(name: str) -> bool:
    return name not in UNSUPPORTED


def run(path: str) -> str:
    scene = fourdgs.read(path)
    return canonical(summarize(scene.header, scene.gaussians, scene.audio, [(e.t0, e.t1) for e in scene.chunk_index]))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: decode_streamed.py <file.4dgs>", file=sys.stderr)
        return 2
    if "--supports" in argv:
        return 0
    print(run(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
