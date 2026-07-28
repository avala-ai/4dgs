#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Conformance runner: indexed decode.

Reads the Footer, then the index, then each chunk by byte range — the path a seeking
client takes — and produces the same canonical JSON the streamed runner does. Agreeing
with itself across two very different read paths is most of what makes an indexed
implementation trustworthy.
"""

from __future__ import annotations

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fourdgs"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "conformance"))

import fourdgs
from canonical import canonical, summarize
from fourdgs.indexed_reader import open_indexed, read_audio, read_chunk
from fourdgs.readable import FileReadable

UNSUPPORTED: frozenset[str] = frozenset()


def supports_variant(name: str) -> bool:
    # A file written without an index cannot be read this way. Declining is the correct
    # answer, not a failure — that is what supportsVariant is for.
    return "UseChunkIndex" in name


def run(path: str) -> str:
    with FileReadable(path) as source:
        scene = open_indexed(source)
        chunks = [read_chunk(source, scene, entry, max_sh_band=3) for entry in scene.index]
        audio_bytes = read_audio(source, scene)

    table = np.asarray(scene.windows, dtype=np.float64).reshape(-1, 2) if scene.windows else np.zeros((1, 2))
    if chunks:
        idx = np.clip(np.concatenate([c["window_index"] for c in chunks]), 0, max(len(table) - 1, 0))
        gaussians = fourdgs.GaussianSet(
            positions=np.concatenate([c["positions"] for c in chunks]).astype(np.float32),
            scales=np.concatenate([c["scales"] for c in chunks]).astype(np.float32),
            rotations=np.concatenate([c["rotations"] for c in chunks]).astype(np.float32),
            colors=np.concatenate([c["colors"] for c in chunks]).astype(np.float32),
            motions=np.concatenate([c["motions"] for c in chunks]).astype(np.float32),
            mu_t=np.concatenate([c["mu_t"] for c in chunks]).astype(np.float32),
            sigma_t=np.concatenate([c["sigma_t"] for c in chunks]).astype(np.float32),
            win_lo=table[idx, 0].astype(np.float32),
            win_hi=table[idx, 1].astype(np.float32),
            sh_degree=scene.header.sh_degree,
        )
    else:
        z3 = np.zeros((0, 3), dtype=np.float32)
        gaussians = fourdgs.GaussianSet(
            positions=z3,
            scales=z3,
            rotations=np.zeros((0, 4), dtype=np.float32),
            colors=np.zeros((0, 4), dtype=np.float32),
            motions=z3,
            mu_t=np.zeros(0, dtype=np.float32),
            sigma_t=np.zeros(0, dtype=np.float32),
            win_lo=np.zeros(0, dtype=np.float32),
            win_hi=np.zeros(0, dtype=np.float32),
            sh_degree=scene.header.sh_degree,
        )

    audio = None
    if audio_bytes is not None:
        audio = fourdgs.AudioTrack(codec=scene.audio_codec or "", data=audio_bytes)
    return canonical(summarize(scene.header, gaussians, audio, [(e.t0, e.t1) for e in scene.index]))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: decode_indexed.py <file.4dgs>", file=sys.stderr)
        return 2
    print(run(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
