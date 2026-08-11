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
from fourdgs import keyframe_delta_file as kdf
from fourdgs.indexed_reader import (
    open_indexed,
    read_attachments,
    read_audio_sources,
    read_camera,
    read_chunk,
    read_metadata,
    read_objects,
    read_provenance,
)
from fourdgs.opcode import HEADER
from fourdgs.readable import FileReadable
from fourdgs.records import Header
from fourdgs.serialization import MAGIC, iter_records

UNSUPPORTED: frozenset[str] = frozenset()


def supports_variant(name: str) -> bool:
    # A file written without an index cannot be read this way. Declining is the correct
    # answer, not a failure — that is what supportsVariant is for.
    return "UseChunkIndex" in name


def _temporal_model(data: bytes) -> str | None:
    """The Header's temporal model, read only to choose the indexed decoder.

    This is dispatch, not validation. In particular it must not check the magic: the
    selected indexed decoder owns that rule, so the invalid corpus can prove that the
    indexed path enforces it independently of the streamed path.
    """
    # Only a known version-1 file is safe to parse with the version-1 record and Header
    # layouts. Every other prefix goes straight to the indexed opener, which diagnoses a
    # foreign magic separately from a future major version before it touches any record.
    if data[: len(MAGIC)] != MAGIC:
        return None
    for record in iter_records(data, len(MAGIC)):
        if record.opcode == HEADER:
            return Header.parse(record.content).temporal_model
    return None


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
    with open(path, "rb") as fh:
        data = fh.read()

    if _temporal_model(data) == "keyframe-delta":
        # The indexed path composes each instant by walking its chain (spec §11.8); its
        # canonical states must match the streamed path's exactly. Its own runner asserts
        # that agreement — here we emit the indexed decode so the harness diffs it against
        # the same committed expectation the streamed runner is held to.
        return canonical(kdf.states_json(kdf.decode_indexed(data)[0]))

    with FileReadable(path) as raw:
        source = _Counting(raw)
        scene = open_indexed(source)
        chunks = [read_chunk(source, scene, entry, max_sh_band=3) for entry in scene.index]
        audio_sources = read_audio_sources(source, scene)
        camera = read_camera(source, scene)
        metadata = read_metadata(source, scene)
        attachments = read_attachments(source, scene)
        # Framed at open, fetched here — the same contract the camera and the
        # attachments have, and the reason no Header flag announces the family.
        provenance = read_provenance(source, scene)
        objects = read_objects(source, scene)
        _check_band_skipping(source, scene)

    table = np.asarray(scene.windows, dtype=np.float64).reshape(-1, 2) if scene.windows else np.zeros((1, 2))
    if chunks:
        idx = np.clip(np.concatenate([c["window_index"] for c in chunks]), 0, max(len(table) - 1, 0))
        sh = _merge_sh(chunks, scene.header.sh_degree)
        object_chunks = [chunk.get("object_id") for chunk in chunks]
        object_id = (
            np.concatenate(
                [
                    np.zeros(len(chunk["mu_t"]), dtype=np.uint32) if ids is None else ids
                    for chunk, ids in zip(chunks, object_chunks, strict=True)
                ]
            )
            if any(ids is not None for ids in object_chunks)
            else None
        )
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
            object_id=object_id,
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

    return canonical(
        summarize(
            scene.header,
            gaussians,
            audio_sources,
            [(e.t0, e.t1) for e in scene.index],
            camera=camera,
            metadata=metadata,
            attachments=attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
            provenance=provenance,
            objects=objects,
        )
    )


def _merge_sh(chunks, degree: int):
    """Assemble the scene's coefficients from the bands each chunk read."""
    from fourdgs.stream_reader import merge_chunk_bands

    if degree == 0:
        return None
    return merge_chunk_bands([len(c["mu_t"]) for c in chunks], [c.get("sh", {}) for c in chunks])


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
        print("usage: decode_indexed.py <file.4dgs>", file=sys.stderr)
        return 2
    try:
        print(run(argv[1]))
    except fourdgs.FourdgsError as exc:
        print(_refusal(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
