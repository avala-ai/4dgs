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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fourdgs"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "conformance"))

import fourdgs
from canonical import canonical, summarize
from fourdgs import keyframe_delta_file as kdf
from fourdgs.decoded_budget import (
    DecodedStateBudget,
    array_capacity_bytes,
    gaussian_birth_decode_working_bytes,
)
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
from optional_identity import gaussian_birth_rows, is_witness, keyframe_delta_states
from refusal import refusal_answer

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


def run(path: str, *, max_decoded_state_bytes: int = fourdgs.DEFAULT_MAX_DECODED_STATE_BYTES) -> str:
    with open(path, "rb") as fh:
        data = fh.read()

    if _temporal_model(data) == "keyframe-delta":
        # The indexed path composes each instant by walking its chain (spec §11.8); its
        # canonical states must match the streamed path's exactly. Its own runner asserts
        # that agreement — here we emit the indexed decode so the harness diffs it against
        # the same committed expectation the streamed runner is held to.
        decoded = kdf.decode_indexed(data, max_decoded_state_bytes=max_decoded_state_bytes)[0]
        return canonical(keyframe_delta_states(decoded) if is_witness(decoded.header) else kdf.states_json(decoded))

    budget = DecodedStateBudget(max_decoded_state_bytes)
    with FileReadable(path) as raw:
        source = _Counting(raw)
        scene = open_indexed(source)
        chunks = []
        for entry in scene.index:
            budget.check(
                gaussian_birth_decode_working_bytes(entry.gaussian_count, 0),
                f"indexed Chunk decode at byte {entry.chunk_offset}",
            )
            chunk = read_chunk(source, scene, entry, max_sh_band=3)
            budget.retain(
                array_capacity_bytes(chunk),
                f"indexed Chunk collection after byte {entry.chunk_offset}",
            )
            chunks.append(chunk)
        audio_sources = read_audio_sources(source, scene)
        camera = read_camera(source, scene)
        metadata = read_metadata(source, scene)
        attachments = read_attachments(source, scene)
        # Framed at open, fetched here — the same contract the camera and the
        # attachments have, and the reason no Header flag announces the family.
        provenance = read_provenance(source, scene)
        objects = read_objects(source, scene)
        _check_band_skipping(source, scene)

    # Use the SDK's assembly path so both maintained runners share the same accounting
    # for the final GaussianSet and its simultaneous concatenation working storage.
    from fourdgs.stream_reader import _assemble

    gaussians = _assemble(
        chunks,
        scene.windows,
        scene.header,
        [chunk.get("sh", {}) for chunk in chunks],
        budget=budget,
    )

    if is_witness(scene.header):
        return canonical(gaussian_birth_rows(gaussians))

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


def main(argv: list[str]) -> int:
    if len(argv) == 2:
        path = argv[1]
        max_decoded_state_bytes = fourdgs.DEFAULT_MAX_DECODED_STATE_BYTES
    elif len(argv) == 4 and argv[1] == "--max-decoded-state-bytes":
        path = argv[3]
        try:
            max_decoded_state_bytes = int(argv[2])
        except ValueError:
            print("--max-decoded-state-bytes must be a positive integer", file=sys.stderr)
            return 2
        if max_decoded_state_bytes <= 0:
            print("--max-decoded-state-bytes must be a positive integer", file=sys.stderr)
            return 2
    else:
        print(
            "usage: decode_indexed.py [--max-decoded-state-bytes N] <file.4dgs>",
            file=sys.stderr,
        )
        return 2
    try:
        print(run(path, max_decoded_state_bytes=max_decoded_state_bytes))
    except fourdgs.ExceedsReaderLimit:
        print('{"unsupported":"resource-limit"}')
    except fourdgs.FourdgsError as exc:
        # A refusal is a result, not a crash: it goes to stdout and the process exits 0,
        # so the harness diffs it against the expectation like any other answer. An error
        # the refusal vocabulary does not name is not that result. It goes to stderr with
        # a non-zero exit, because a runner that answered it with an unnamed refusal would
        # be claiming a valid answer for a failure nobody can check — see `refusal.py`.
        answer = refusal_answer(exc)
        if answer is None:
            print(f"{path}: {exc}", file=sys.stderr)
            return 1
        print(answer)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
