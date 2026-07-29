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

import fourdgs
from canonical import canonical, summarize

#: Variants this runner declines. Empty: the reference implementation supports the whole
#: matrix, which is the only reason it is allowed to be the reference.
UNSUPPORTED: frozenset[str] = frozenset()


def supports_variant(name: str) -> bool:
    return name not in UNSUPPORTED


def run(path: str) -> str:
    scene = fourdgs.read(path)
    _check_truncation_recovery(path, scene)
    return canonical(
        summarize(
            scene.header,
            scene.gaussians,
            scene.audio,
            [(e.t0, e.t1) for e in scene.chunk_index],
            camera=scene.camera,
            metadata=scene.metadata,
            attachments=scene.attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
        )
    )


def _check_truncation_recovery(path: str, full) -> None:
    """Decode the same file cut short, and insist on what survives.

    Nothing in the corpus is truncated, so this makes one. The canonical JSON cannot
    express truncation recovery — a cut file is a different file — so the check lives
    here, where a failure exits non-zero and the harness reports it like any other.
    """
    with open(path, "rb") as fh:
        data = fh.read()

    cut = fourdgs.read(data[:-1])
    if not cut.truncated:
        raise AssertionError("a file cut before its trailing magic was not reported truncated")
    if cut.gaussians.count != full.gaussians.count:
        raise AssertionError(
            f"cutting the trailing magic lost gaussians: {cut.gaussians.count} of {full.gaussians.count}"
        )

    if len(full.chunk_index) >= 2:
        last = full.chunk_index[-1]
        mid = fourdgs.read(data[: last.chunk_offset + 5])
        if not mid.truncated:
            raise AssertionError("a file cut inside a chunk record was not reported truncated")
        expected = full.gaussians.count - last.gaussian_count
        if mid.gaussians.count != expected:
            raise AssertionError(f"cutting the last chunk left {mid.gaussians.count} gaussians, expected {expected}")


def _refusal(exc) -> str:
    """The canonical answer for a file this reader refused.

    A refusal is a result, not a crash: the runner prints it on stdout and exits 0, and
    the harness diffs it against the expectation like any other answer. Exiting non-zero
    instead would collapse "refused correctly" and "fell over" into one outcome, and the
    whole point of the invalid corpus is that those are different.

    An exception carrying no identifier prints an empty one, which matches no expectation
    and fails with a readable diff. That is deliberate: a refusal the library cannot name
    is a refusal the suite cannot check, and it should look like a gap rather than a pass.
    """
    return canonical({"refused": getattr(exc, "code", "")})


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: decode_streamed.py <file.4dgs>", file=sys.stderr)
        return 2
    if "--supports" in argv:
        return 0
    try:
        print(run(argv[1]))
    except fourdgs.FourdgsError as exc:
        print(_refusal(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
