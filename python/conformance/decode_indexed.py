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
from fourdgs.indexed_reader import (
    open_indexed,
    read_attachments,
    read_audio,
    read_camera,
    read_chunk,
    read_metadata,
)
from fourdgs.readable import FileReadable

UNSUPPORTED: frozenset[str] = frozenset()


def supports_variant(name: str) -> bool:
    # A file written without an index cannot be read this way. Declining is the correct
    # answer, not a failure — that is what supportsVariant is for.
    return "UseChunkIndex" in name


class _Counting:
    """A readable that records what it transferred, so a claim about byte ranges can be
    checked against the bytes that actually moved."""

    def __init__(self, inner):
        self._inner = inner
        self.bytes_read = 0

    def size(self) -> int:
        return self._inner.size()

    def read(self, offset: int, length: int) -> bytes:
        self.bytes_read += length
        return self._inner.read(offset, length)


def _check_band_skipping(source, scene) -> None:
    """A reader that has capped its SH degree never transfers the bands above it.

    Counted at the transport, because that is the claim: not that the coefficients are
    dropped after arriving, but that their bytes were never asked for.
    """
    for entry in scene.index:
        if not entry.bands:
            continue
        for cap in [0, *[band for band, _, _ in entry.bands]]:
            before = source.bytes_read
            read_chunk(source, scene, entry, max_sh_band=cap)
            moved = source.bytes_read - before
            wanted = entry.chunk_length + sum(length for band, _, length in entry.bands if band <= cap)
            if moved != wanted:
                raise AssertionError(
                    f"reading a chunk with max_sh_band={cap} transferred {moved} bytes, the index says {wanted}"
                )


def run(path: str) -> str:
    with FileReadable(path) as raw:
        source = _Counting(raw)
        scene = open_indexed(source)
        chunks = [read_chunk(source, scene, entry, max_sh_band=3) for entry in scene.index]
        audio_bytes = read_audio(source, scene)
        camera = read_camera(source, scene)
        metadata = read_metadata(source, scene)
        attachments = read_attachments(source, scene)
        _check_band_skipping(source, scene)

    table = np.asarray(scene.windows, dtype=np.float64).reshape(-1, 2) if scene.windows else np.zeros((1, 2))
    if chunks:
        idx = np.clip(np.concatenate([c["window_index"] for c in chunks]), 0, max(len(table) - 1, 0))
        sh = _merge_sh(chunks, scene.header.sh_degree)
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
            sh=sh,
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
    return canonical(
        summarize(
            scene.header,
            gaussians,
            audio,
            [(e.t0, e.t1) for e in scene.index],
            camera=camera,
            metadata=metadata,
            attachments=attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
        )
    )


def _merge_sh(chunks, degree: int):
    """Assemble the scene's coefficients from the bands each chunk read."""
    from fourdgs.stream_reader import merge_chunk_bands

    if degree == 0:
        return None
    return merge_chunk_bands([len(c["mu_t"]) for c in chunks], [c.get("sh", {}) for c in chunks])


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: decode_indexed.py <file.4dgs>", file=sys.stderr)
        return 2
    print(run(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
