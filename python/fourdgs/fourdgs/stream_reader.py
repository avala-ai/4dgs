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
from .exceptions import MalformedFile, TruncatedFile, UnsupportedCodec
from .model import AudioTrack, CameraTrajectory, GaussianSet
from .quantization import (
    DEFAULT_CUTOFF,
    Steps,
    dequantize,
    dequantize_rotation,
    life_class,
    motion_steps,
    mu_steps,
    rct_inverse,
    support_k,
)
from .serialization import (
    CODEC_DEFLATE,
    CODEC_ZSTD,
    MAGIC,
    Cursor,
    check_magic,
    crc32,
    decode_stream,
    decompress,
    iter_records,
)


@dataclass
class Scene:
    """A whole file, decoded."""

    header: rec.Header
    gaussians: GaussianSet
    duration_sec: float
    #: The grids and the error bounds the file declares. A consumer that wants to know
    #: how wrong a value may be has to be able to reach them, and the bounds are the
    #: producer's own statement about that.
    quantization: rec.Quantization | None = None
    #: `None` when the scene has no soundtrack, which is the common case and not an error.
    audio: AudioTrack | None = None
    camera: CameraTrajectory | None = None
    metadata: list[rec.Metadata] = field(default_factory=list)
    attachments: list[rec.Attachment] = field(default_factory=list)
    statistics: rec.Statistics | None = None
    chunk_index: list[rec.ChunkIndexEntry] = field(default_factory=list)
    summary_offsets: list[rec.SummaryOffset] = field(default_factory=list)
    #: Whether the Footer's summary CRC matched, or `None` when the file declares none.
    #: A front-to-back reader can check this too: it has seen the bytes the CRC covers.
    summary_crc_ok: bool | None = None
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


def decode_chunk_blob(
    chunk_record: bytes, steps: Steps, origin: np.ndarray, windows, cutoff: float = DEFAULT_CUTOFF
) -> dict:
    """Decode one Chunk record's worth of attribute streams into float arrays."""
    body = Cursor(chunk_record)
    body.take(1)  # opcode
    body.take(8)  # content length
    head, streams = rec.parse_chunk(body.buf[body.pos :])
    return decode_streams(chunk_stream_bytes(head, streams), head.count, steps, origin, windows, cutoff)


def decode_streams(
    streams, count: int, steps: Steps, origin: np.ndarray, windows, cutoff: float = DEFAULT_CUTOFF
) -> dict:
    """Decode a chunk's attribute streams.

    `windows` is required, not optional: a never-fading gaussian's velocity precision is
    derived from the length of its validity window, so a decoder that guesses a window
    length decodes different velocities than the encoder wrote. That is precisely the
    class of divergence the conformance suite exists to catch, so the signature makes it
    impossible to omit. `cutoff` is required for the same reason, one step further back:
    it sets the support constant the velocity class is derived from.
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
    table = window_table_or_default(windows)
    check_window_indices(window_index, len(table))
    win_len = table[window_index, 1] - table[window_index, 0]
    motion_step = motion_steps(
        life_class(sigma_bins, steps.sigma_log, never_fades, win_len, support_k(cutoff)), steps.motion
    )[:, None]
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


#: Coefficients per colour component that each SH band carries, as `[first, last)` within
#: a whole degree's coefficients. Band `b` carries `2b + 1` of them.
SH_BAND_RANGE = {1: (0, 3), 2: (3, 8), 3: (8, 15)}


def merge_chunk_bands(counts: list[int], chunk_bands: list[dict[int, np.ndarray]]):
    """Merge per-chunk SH band streams into one scene-wide `(n, 3 * coeffs)` array.

    Degrees are whole and scene-wide: bands 1..D give exactly a degree-D scene, and a
    reader never assembles a partial degree out of part of a band. Columns are
    component-major — every coefficient of red, then green, then blue — which is the
    layout the streams are written in.
    """
    present = sorted({band for bands in chunk_bands for band in bands})
    if not present or present != list(range(1, len(present) + 1)):
        if present:
            raise MalformedFile(f"SH bands {present} do not form whole degrees starting at band 1")
        return None
    coeffs = SH_BAND_RANGE[present[-1]][1]
    out = np.zeros((sum(counts), 3 * coeffs), dtype=np.uint8)
    at = 0
    for count, bands in zip(counts, chunk_bands, strict=False):
        for band in present:
            if band not in bands:
                raise MalformedFile(f"a chunk carries SH bands {sorted(bands)}, the file carries {present}")
            first, last = SH_BAND_RANGE[band]
            width = last - first
            values = np.asarray(bands[band], dtype=np.int64).reshape(count, 3 * width)
            if values.min(initial=0) < 0 or values.max(initial=0) > 255:
                raise MalformedFile("an SH coefficient is outside the 0..255 range this version stores")
            for c in range(3):
                out[at : at + count, c * coeffs + first : c * coeffs + last] = values[:, c * width : (c + 1) * width]
        at += count
    return out


def window_table_or_default(windows) -> np.ndarray:
    """The Window Table as an `(n, 2)` array, or the one-window default.

    A file with no Window Table, or one whose count is zero, reads as though it declared
    exactly one window `(0, 0)`: every gaussian references index 0 and nothing is visible
    at any time. Degenerate, well defined, and not an error (spec section 5.4).
    """
    table = np.asarray(windows, dtype=np.float64).reshape(-1, 2)
    return table if len(table) else np.zeros((1, 2), dtype=np.float64)


def check_window_indices(window_index: np.ndarray, count: int) -> None:
    """Refuse an index outside the table rather than clamping it.

    Clamping substitutes one gaussian's lifetime for another's, in a file that is already
    wrong in some way nobody has diagnosed — it turns a detectable fault into plausible
    wrong output. Refusing names the index and the table.
    """
    if window_index.size == 0:
        return
    lo = int(window_index.min())
    hi = int(window_index.max())
    if lo < 0 or hi >= count:
        raise MalformedFile(f"window index {lo if lo < 0 else hi} is outside the {count}-entry window table")


def chunk_stream_bytes(head: rec.ChunkHeader, streams) -> bytes:
    """A chunk's attribute streams, with any chunk-level compression undone.

    Compression is normally per stream and this field is empty, but the format allows a
    codec over the whole records block. Ignoring it decodes the compressed bytes as though
    they were attribute streams, which produces wrong gaussians instead of an error.
    """
    if head.compression == "":
        return streams
    codec = {"deflate": CODEC_DEFLATE, "zstd": CODEC_ZSTD}.get(head.compression)
    if codec is None:
        raise UnsupportedCodec(
            f"chunk at t0={head.t0} is compressed with {head.compression!r}, which this build does not know"
        )
    return decompress(bytes(streams), codec, head.uncompressed_size)


def read(path_or_bytes, *, recover_truncated: bool = True, max_sh_band: int = 3) -> Scene:
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
    chunk_bands: list[dict[int, np.ndarray]] = []
    scene = Scene(header=None, gaussians=None, duration_sec=0.0)  # type: ignore[arg-type]
    skipped: list[int] = []
    truncated = False

    pos = len(MAGIC)
    end = pos
    try:
        for record in iter_records(data, pos):
            end = record.offset + 9 + len(record.content)
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
                    decode_streams(
                        chunk_stream_bytes(head, streams),
                        head.count,
                        steps_from(quant),
                        np.asarray(quant.pos_origin),
                        windows,
                        header.cutoff if header else DEFAULT_CUTOFF,
                    )
                )
                chunk_bands.append({})
            elif record.opcode == op.SH_BAND_STREAM:
                # Bands belong to the chunk that precedes them. A front-to-back reader
                # cannot range-skip the ones it does not want — it has already been sent
                # them — but it can and does decode them.
                if chunk_bands and max_sh_band > 0:
                    band_cursor = Cursor(record.content)
                    band = band_cursor.u8()
                    if band <= max_sh_band:
                        _, values = decode_stream(band_cursor)
                        chunk_bands[-1][band] = values
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
            elif record.opcode == op.SUMMARY_OFFSET:
                scene.summary_offsets.append(rec.SummaryOffset.parse(record.content))
            elif record.opcode == op.FOOTER:
                footer = rec.Footer.parse(record.content)
                if footer.summary_start and footer.summary_crc:
                    summary = data[footer.summary_start : record.offset]
                    scene.summary_crc_ok = crc32(summary) == footer.summary_crc
            else:
                # Unknown or private: skipped by length, which is the whole point.
                skipped.append(record.opcode)
    except TruncatedFile:
        if not recover_truncated:
            raise
        truncated = True

    # A complete file ends with the magic and nothing after it. Anything else — an
    # incomplete record, a missing trailing magic — is a cut, and what was decoded before
    # it still stands.
    if not truncated and data[end:] != MAGIC:
        truncated = True
        if not recover_truncated:
            raise TruncatedFile(f"file ends after {end} bytes without its trailing magic")

    if header is None or quant is None:
        raise MalformedFile("file has no Header or no Quantization record")

    scene.header = header
    scene.quantization = quant
    scene.duration_sec = header.duration_sec
    scene.skipped_opcodes = skipped
    scene.truncated = truncated
    scene.gaussians = _assemble(chunks, windows, header, chunk_bands)
    return scene


def _assemble(chunks: list[dict], windows, header, chunk_bands=None) -> GaussianSet:
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
    table = window_table_or_default(windows)
    idx = np.concatenate([c["window_index"] for c in chunks])
    check_window_indices(idx, len(table))
    src = [c["source_index"] for c in chunks]
    sh = merge_chunk_bands([len(c["mu_t"]) for c in chunks], chunk_bands or [])
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
        sh=sh,
        sh_degree=header.sh_degree,
        source_index=np.concatenate(src) if all(s is not None for s in src) else None,
    )
