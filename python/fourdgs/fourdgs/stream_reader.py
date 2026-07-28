# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Streamed reading: front to back, no seeking.

Works on a pipe, on a file with no index, and on a file that was truncated mid-write —
records are length-prefixed, so everything complete before the cut is recoverable. That
makes this the right mode for validation, conversion and archival scans, and the wrong
one for scrubbing.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile, TruncatedFile
from .model import AudioTrack, CameraTrajectory, GaussianSet
from .quantization import Steps, dequantize, dequantize_rotation, life_class, motion_steps, mu_steps, rct_inverse
from .serialization import MAGIC, Cursor, check_magic, decode_stream, iter_records


@dataclass
class Scene:
    """A whole file, decoded."""

    header: rec.Header
    gaussians: GaussianSet
    duration_sec: float
    #: `None` when the scene has no soundtrack, which is the common case and not an error.
    audio: AudioTrack | None = None
    camera: CameraTrajectory | None = None
    metadata: list[rec.Metadata] = field(default_factory=list)
    attachments: list[rec.Attachment] = field(default_factory=list)
    statistics: rec.Statistics | None = None
    chunk_index: list[rec.ChunkIndexEntry] = field(default_factory=list)
    #: Opcodes seen but not understood. Present so `validate` can report them and so a
    #: test can prove they were skipped rather than tripped over.
    skipped_opcodes: list[int] = field(default_factory=list)
    truncated: bool = False


def steps_from(q: rec.Quantization) -> Steps:
    return Steps(
        pos=q.step_pos,
        scale_log=q.step_scale_log,
        rot=q.step_rot,
        rgb=q.step_rgb,
        alpha=q.step_alpha,
        motion=q.step_motion,
        time=q.step_time,
        sigma_log=q.step_sigma_log,
        sh=q.step_sh,
    )


def decode_chunk_blob(chunk_record: bytes, steps: Steps, origin: np.ndarray, windows) -> dict:
    """Decode one Chunk record's worth of attribute streams into float arrays."""
    body = Cursor(chunk_record)
    body.take(1)  # opcode
    body.take(8)  # content length
    head, streams = rec.parse_chunk(body.buf[body.pos :])
    return decode_streams(streams, head.count, steps, origin, windows)


def decode_streams(streams, count: int, steps: Steps, origin: np.ndarray, windows) -> dict:
    """Decode a chunk's attribute streams.

    `windows` is required, not optional: a never-fading gaussian's velocity precision is
    derived from the length of its validity window, so a decoder that guesses a window
    length decodes different velocities than the encoder wrote. That is precisely the
    class of divergence the conformance suite exists to catch, so the signature makes it
    impossible to omit.
    """
    cursor = Cursor(streams)
    got: dict[int, np.ndarray] = {}
    while cursor.remaining() > 0:
        attribute_id, values = decode_stream(cursor)
        got[attribute_id] = values

    missing = [a for a in op.REQUIRED_ATTRIBUTES if a not in got]
    if missing and count:
        raise MalformedFile(f"chunk is missing required attributes {missing}")
    if not count:
        empty = np.zeros((0, 3), dtype=np.float64)
        return {
            "positions": empty,
            "scales": empty,
            "rotations": np.zeros((0, 4)),
            "colors": np.zeros((0, 4)),
            "motions": empty,
            "mu_t": np.zeros(0),
            "sigma_t": np.zeros(0),
            "window_index": np.zeros(0, dtype=np.int64),
            "source_index": None,
        }

    never_fades = got[op.A_FLAGS][:, 0] != 0
    sigma_bins = got[op.A_SIGMA_T][:, 0]
    sigma = np.where(never_fades, np.inf, np.exp(sigma_bins * steps.sigma_log))

    window_index = got[op.A_WINDOW_INDEX][:, 0]
    table = np.asarray(windows, dtype=np.float64).reshape(-1, 2)
    safe_index = np.clip(window_index, 0, max(len(table) - 1, 0))
    win_len = table[safe_index, 1] - table[safe_index, 0]
    motion_step = motion_steps(life_class(sigma_bins, steps.sigma_log, never_fades, win_len), steps.motion)[:, None]
    return {
        "positions": dequantize(got[op.A_POSITION], steps.pos, origin),
        "scales": np.exp(dequantize(got[op.A_SCALE], steps.scale_log)),
        "rotations": dequantize_rotation(got[op.A_ROTATION_INDEX][:, 0], got[op.A_ROTATION], steps.rot),
        "colors": np.concatenate(
            [
                np.clip(dequantize(rct_inverse(got[op.A_COLOR]), steps.rgb), 0.0, 1.0),
                np.clip(dequantize(got[op.A_OPACITY][:, 0], steps.alpha), 0.0, 1.0)[:, None],
            ],
            axis=1,
        ),
        "motions": got[op.A_MOTION].astype(np.float64) * motion_step,
        "mu_t": got[op.A_MU_T][:, 0].astype(np.float64)
        * mu_steps(sigma_bins, steps.sigma_log, never_fades, steps.time),
        "sigma_t": sigma,
        "window_index": window_index,
        "source_index": got[op.A_SOURCE_INDEX][:, 0] if op.A_SOURCE_INDEX in got else None,
    }


def read(path_or_bytes, *, recover_truncated: bool = True) -> Scene:
    """Decode a whole file from bytes or a path."""
    if isinstance(path_or_bytes, (bytes, bytearray, memoryview)):
        data = bytes(path_or_bytes)
    else:
        with open(path_or_bytes, "rb") as fh:
            data = fh.read()

    check_magic(data)
    header: rec.Header | None = None
    quant: rec.Quantization | None = None
    windows: list[tuple[float, float]] = []
    chunks: list[dict] = []
    scene = Scene(header=None, gaussians=None, duration_sec=0.0)  # type: ignore[arg-type]
    skipped: list[int] = []
    truncated = False

    pos = len(MAGIC)
    try:
        for record in iter_records(data, pos):
            if record.opcode == op.HEADER:
                header = rec.Header.parse(record.content)
            elif record.opcode == op.QUANTIZATION:
                quant = rec.Quantization.parse(record.content)
            elif record.opcode == op.WINDOW_TABLE:
                windows = rec.WindowTable.parse(record.content).windows
            elif record.opcode == op.CHUNK:
                if quant is None:
                    raise MalformedFile("a Chunk arrived before the Quantization record")
                head, streams = rec.parse_chunk(record.content)
                chunks.append(
                    decode_streams(streams, head.count, steps_from(quant), np.asarray(quant.pos_origin), windows)
                )
            elif record.opcode == op.SH_BAND_STREAM:
                pass  # bands are decoded by the indexed reader, which knows what it wants
            elif record.opcode == op.AUDIO:
                a = rec.Audio.parse(record.content)
                scene.audio = AudioTrack(codec=a.codec, data=a.data, start_sec=a.start_sec)
            elif record.opcode == op.CAMERA:
                c = rec.Camera.parse(record.content)
                scene.camera = CameraTrajectory(
                    fov_y_deg=c.fov_y_deg,
                    position=tuple(c.position),
                    target=tuple(c.target),
                    times=c.times,
                    positions=[tuple(p) for p in c.positions],
                    targets=[tuple(t) for t in c.targets],
                    interpolation=c.interpolation,
                    loop=c.loop,
                )
            elif record.opcode == op.METADATA:
                scene.metadata.append(rec.Metadata.parse(record.content))
            elif record.opcode == op.ATTACHMENT:
                scene.attachments.append(rec.Attachment.parse(record.content))
            elif record.opcode == op.STATISTICS:
                scene.statistics = rec.Statistics.parse(record.content)
            elif record.opcode == op.CHUNK_INDEX:
                scene.chunk_index.append(rec.ChunkIndexEntry.parse(record.content))
            elif record.opcode == op.FOOTER:
                pass
            else:
                # Unknown or private: skipped by length, which is the whole point.
                skipped.append(record.opcode)
    except TruncatedFile:
        if not recover_truncated:
            raise
        truncated = True

    if header is None or quant is None:
        raise MalformedFile("file has no Header or no Quantization record")

    scene.header = header
    scene.duration_sec = header.duration_sec
    scene.skipped_opcodes = skipped
    scene.truncated = truncated
    scene.gaussians = _assemble(chunks, windows, header)
    return scene


def _assemble(chunks: list[dict], windows, header) -> GaussianSet:
    if not chunks:
        z3 = np.zeros((0, 3), dtype=np.float32)
        return GaussianSet(
            positions=z3,
            scales=z3,
            rotations=np.zeros((0, 4), dtype=np.float32),
            colors=np.zeros((0, 4), dtype=np.float32),
            motions=z3,
            mu_t=np.zeros(0, dtype=np.float32),
            sigma_t=np.zeros(0, dtype=np.float32),
            win_lo=np.zeros(0, dtype=np.float32),
            win_hi=np.zeros(0, dtype=np.float32),
            sh_degree=header.sh_degree,
        )
    table = np.asarray(windows, dtype=np.float64) if windows else np.zeros((1, 2))
    idx = np.concatenate([c["window_index"] for c in chunks])
    idx = np.clip(idx, 0, max(len(table) - 1, 0))
    src = [c["source_index"] for c in chunks]
    return GaussianSet(
        positions=np.concatenate([c["positions"] for c in chunks]).astype(np.float32),
        scales=np.concatenate([c["scales"] for c in chunks]).astype(np.float32),
        rotations=np.concatenate([c["rotations"] for c in chunks]).astype(np.float32),
        colors=np.concatenate([c["colors"] for c in chunks]).astype(np.float32),
        motions=np.concatenate([c["motions"] for c in chunks]).astype(np.float32),
        mu_t=np.concatenate([c["mu_t"] for c in chunks]).astype(np.float32),
        sigma_t=np.concatenate([c["sigma_t"] for c in chunks]).astype(np.float32),
        win_lo=table[idx, 0].astype(np.float32),
        win_hi=table[idx, 1].astype(np.float32),
        sh_degree=header.sh_degree,
        source_index=np.concatenate(src) if all(s is not None for s in src) else None,
    )
