# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Whole-file `keyframe-delta`: write a sample sequence, decode it, summarize instants.

`keyframe_delta.py` holds the composition and the chain a seek walks; `records.py` holds
the wire records; `keyframe_delta_writer.py` splits one sample against its reference. Each
is exercised alone in its own tests. This module is the file *around* them — the Header, a
keyframe Chunk or a Delta Chunk per sample, the extended Chunk Index, the Footer — and the
two read paths a consumer takes:

* `decode_streamed` walks the file front to back, composing each chunk onto the last;
* `decode_indexed` reads the index and, for an instant, walks only that instant's chain.

They MUST agree. Agreeing across two very different read paths is most of what makes a
`keyframe-delta` implementation trustworthy, and `states_json` is the statement the other
SDKs are diffed against — the reconstruction at an instant that the whole model exists to
make cheap, and the one thing the per-file canonical summary could never carry.

Everything upstream of composition is bins, never values: the writer quantizes every
sample on one shared set of grids, so a delta is an integer subtraction between two bins on
the same grid and the composition telescopes exactly (spec §11.7). Dequantization happens
once, at the end, on the composed state, by the same arithmetic a `gaussian-birth` chunk
uses.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile
from .keyframe_delta import State, apply_delta, chain_for, check_tiling, keyframe_state
from .keyframe_delta_writer import (
    KeyframeDeltaOptions,
    Sample,
    death_streams,
    delta_groups,
    encode_delta_streams,
    is_keyframe,
)
from .quantization import (
    Bounds,
    Steps,
    dequantize,
    dequantize_rotation,
    life_class,
    motion_steps,
    mu_steps,
    quantize,
    quantize_rotation,
    rct_forward,
    rct_inverse,
    support_k,
)
from .serialization import (
    CODEC_DEFLATE,
    MAGIC,
    Cursor,
    check_magic,
    crc32,
    decode_stream,
    encode_stream,
    iter_records,
)
from .stream_reader import check_window_indices

#: Matches `tests/conformance/canonical.py`: integers are strings so a 64-bit value
#: survives a double-backed JSON parser, floats are rounded before comparison, a
#: non-finite value is `null` rather than a sentinel a decoder could produce by accident,
#: and a zero has no sign.
FLOAT_DECIMALS = 6
SAMPLE = 16

#: The eleven required attributes plus identity. A keyframe chunk carries all of them; a
#: birth group carries all of them absolutely; an update carries the subset that changed.
_REQUIRED = tuple(op.REQUIRED_ATTRIBUTES)


def _num(value):
    if value is None:
        return None
    v = float(value)
    if not math.isfinite(v):
        return None
    # `+ 0.0` is not a no-op: IEEE 754 makes `-0.0 + 0.0` equal `+0.0` and leaves every
    # other value untouched. Which sign a composed value at the noise floor picks up is a
    # property of the platform's arithmetic and not of the scene, and this summary is
    # committed to the corpus as text, so keeping it would make the corpus unregenerable
    # on another machine (issue #153). `canonical.canonical` normalizes on the way out as
    # well; this keeps `states_json` right for anyone who calls it directly.
    return round(v, FLOAT_DECIMALS) + 0.0


# --------------------------------------------------------------------------
# Shared grids
# --------------------------------------------------------------------------


@dataclass
class Grids:
    """The one set of grids the whole sequence is quantized on.

    Position origin and the scalar steps come from the sequence as a whole, so a gaussian's
    bin for an attribute is the same wherever it appears and a delta of bins is meaningful.
    The velocity and birth-time steps are per-gaussian and derived from `sigma_t`, `flags`
    and the validity window (spec §6.3) — all three GOP-invariant (spec §11.5), so a
    gaussian keeps its grid for its whole life and its motion delta telescopes.
    """

    steps: Steps
    bounds: Bounds
    origin: np.ndarray
    #: Every validity window the sequence declares, in Window Table order. A gaussian's
    #: own window is the one its `window_index` names — the velocity grid is derived from
    #: that window's length (spec section 6.3), so collapsing the table to its first entry
    #: gives every gaussian outside window 0 the wrong motion precision and its positions
    #: drift from the bins the encoder wrote.
    windows: list[tuple[float, float]]
    cutoff: float

    @property
    def window(self) -> tuple[float, float]:
        """The first window. Only the writer uses this: it emits a single-window table."""
        return self.windows[0] if self.windows else (0.0, 0.0)

    def window_lengths(self, window_index: np.ndarray) -> np.ndarray:
        """Per-gaussian window length, resolved the way the gaussian-birth path resolves it."""
        # An absent or empty Window Table is one default `(0, 0)` window, not an
        # unbounded fallback — the same defaulting the chunk decoder applies. Skipping
        # the check here would let `window_index = 7` reconstruct against a zero-length
        # window instead of being refused, and would answer differently from the regular
        # chunk path on the same bytes.
        windows = self.windows or [(0.0, 0.0)]
        table = np.asarray(windows, dtype=np.float64)
        idx = np.asarray(window_index, dtype=np.int64).reshape(-1)
        check_window_indices(idx, len(windows))
        return table[idx, 1] - table[idx, 0]

    def motion_step(self, sigma_bins: np.ndarray, never_fades: np.ndarray, window_index: np.ndarray) -> np.ndarray:
        win_len = self.window_lengths(window_index)
        classes = life_class(sigma_bins, self.steps.sigma_log, never_fades, win_len, support_k(self.cutoff))
        return motion_steps(classes, self.steps.motion)

    def mu_step(self, sigma_bins: np.ndarray, never_fades: np.ndarray) -> np.ndarray:
        return mu_steps(sigma_bins, self.steps.sigma_log, never_fades, self.steps.time)


def _windows_of(samples: list[Sample], duration_sec: float) -> list[tuple[float, float]]:
    """The distinct validity windows the population declares, in first-seen order.

    A `GaussianSet` carries `win_lo`/`win_hi` per gaussian and the format lets a sequence
    declare several windows, so the writer reads them rather than forcing one. It used to
    emit a single full-duration entry, which meant no producer here could write the
    multi-window file the readers are supposed to handle — and so nothing tested that they
    did (issue #87).

    Order is first-seen rather than sorted: `window_index` is written against this list, so
    a stable order is what makes the indices mean the same thing on both sides.
    """
    seen: dict[tuple[float, float], None] = {}
    for sample in samples:
        lo = np.asarray(sample.gaussians.win_lo, dtype=np.float64).reshape(-1)
        hi = np.asarray(sample.gaussians.win_hi, dtype=np.float64).reshape(-1)
        for a, b in zip(lo, hi, strict=True):
            seen.setdefault((float(a), float(b)), None)
    return list(seen) or [(0.0, float(duration_sec))]


def _window_indices(gaussians, windows: list[tuple[float, float]]) -> np.ndarray:
    """Each gaussian's row in the window table."""
    lookup = {w: i for i, w in enumerate(windows)}
    lo = np.asarray(gaussians.win_lo, dtype=np.float64).reshape(-1)
    hi = np.asarray(gaussians.win_hi, dtype=np.float64).reshape(-1)
    return np.asarray([lookup[(float(a), float(b))] for a, b in zip(lo, hi, strict=True)], dtype=np.int64)


def _grids_for(samples: list[Sample], duration_sec: float, profile: str, cutoff: float) -> Grids:
    positions = np.concatenate([np.asarray(s.gaussians.positions, dtype=np.float64) for s in samples])
    scales = np.concatenate([np.asarray(s.gaussians.scales, dtype=np.float64) for s in samples])
    median_scale = float(np.median(scales)) if scales.size else 1e-3
    bounds = Bounds.for_profile(profile, median_scale=median_scale)
    steps = Steps.of(bounds)
    origin = positions.min(axis=0) if positions.size else np.zeros(3)
    return Grids(
        steps=steps,
        bounds=bounds,
        origin=origin,
        windows=_windows_of(samples, duration_sec),
        cutoff=cutoff,
    )


def _quantize_sample(sample: Sample, grids: Grids) -> tuple[np.ndarray, dict[int, np.ndarray]]:
    """One sample as identities and a bin per attribute, on the shared grids.

    Every gaussian shares one validity window and a finite `sigma_t`. That keeps the
    per-gaussian velocity and birth-time grids uniform, which is all this reference needs
    to exercise the model — the writer that varies them is encoder policy, not format.
    """
    g = sample.gaussians
    n = g.count
    ids = np.asarray(sample.ids, dtype=np.int64).reshape(-1)
    if ids.shape[0] != n:
        raise ValueError(f"sample carries {n} gaussians but {ids.shape[0]} ids")
    if n and not np.all(np.isfinite(np.asarray(g.sigma_t, dtype=np.float64))):
        raise ValueError("this reference writer needs finite sigma_t on every gaussian")

    sigma = np.asarray(g.sigma_t, dtype=np.float64).reshape(-1)
    q_sigma = quantize(np.log(np.maximum(sigma, 1e-30)), grids.steps.sigma_log) if n else np.zeros(0, np.int64)
    never_fades = np.zeros(n, dtype=bool)
    flags = never_fades.astype(np.int64)
    window_index = _window_indices(g, grids.windows) if n else np.zeros(0, dtype=np.int64)

    rot_idx, q_rot = (
        quantize_rotation(g.rotations, grids.steps.rot) if n else (np.zeros(0, np.int64), np.zeros((0, 3), np.int64))
    )
    m_step = grids.motion_step(q_sigma, never_fades, window_index) if n else np.zeros(0)
    t_step = grids.mu_step(q_sigma, never_fades) if n else np.zeros(0)
    q_motion = (
        np.rint(g.motions.astype(np.float64) / m_step[:, None]).astype(np.int64) if n else np.zeros((0, 3), np.int64)
    )
    q_mu = np.rint(g.mu_t.astype(np.float64) / t_step).astype(np.int64) if n else np.zeros(0, np.int64)

    bins = {
        op.A_POSITION: quantize(g.positions, grids.steps.pos, grids.origin) if n else np.zeros((0, 3), np.int64),
        op.A_SCALE: quantize(np.log(np.maximum(g.scales.astype(np.float64), 1e-30)), grids.steps.scale_log)
        if n
        else np.zeros((0, 3), np.int64),
        op.A_ROTATION_INDEX: rot_idx.reshape(-1, 1),
        op.A_ROTATION: q_rot,
        op.A_COLOR: rct_forward(quantize(g.colors[:, :3], grids.steps.rgb)) if n else np.zeros((0, 3), np.int64),
        op.A_OPACITY: (quantize(g.colors[:, 3], grids.steps.alpha) if n else np.zeros(0, np.int64)).reshape(-1, 1),
        op.A_MOTION: q_motion,
        op.A_MU_T: q_mu.reshape(-1, 1),
        op.A_SIGMA_T: q_sigma.reshape(-1, 1),
        op.A_FLAGS: flags.reshape(-1, 1),
        op.A_WINDOW_INDEX: window_index.reshape(-1, 1),
    }
    return ids, bins


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------


def _keyframe_streams(ids: np.ndarray, bins: dict[int, np.ndarray], codec: int, level: int) -> bytes:
    out = [encode_stream(op.A_GAUSSIAN_ID, ids.reshape(-1, 1), codec=codec, level=level)]
    for attribute in _REQUIRED:
        values = bins[attribute]
        values = values.reshape(-1, 1) if values.ndim == 1 else values
        out.append(encode_stream(attribute, values, channels=values.shape[1], codec=codec, level=level))
    return b"".join(out)


def write_sequence(
    samples: list[Sample],
    duration_sec: float,
    *,
    kd: KeyframeDeltaOptions | None = None,
    profile: str = "default",
    cutoff: float = 0.05,
    library: str = "4dgs keyframe-delta reference",
    codec: int = CODEC_DEFLATE,
    level: int = 6,
    write_index: bool = True,
    write_statistics: bool = True,
    write_crc: bool = True,
) -> bytes:
    """Assemble a whole `keyframe-delta` file from a sequence of samples.

    The samples must tile the timeline: sample `i` covers `[t_i, t_{i+1})`, the first
    starts at 0 and the last ends at `duration_sec`. That is the tiling rule (spec §11.1),
    and it is the writer's job to satisfy it rather than the reader's to tolerate a file
    that does not.
    """
    kd = kd or KeyframeDeltaOptions()
    if not samples:
        raise ValueError("a keyframe-delta file needs at least one sample")

    grids = _grids_for(samples, duration_sec, profile, cutoff)
    quantized = [_quantize_sample(s, grids) for s in samples]
    t0s = [float(s.t0) for s in samples]
    t1s = [*t0s[1:], float(duration_sec)]

    distinct_ids: set[int] = set()
    for ids, _ in quantized:
        distinct_ids.update(int(v) for v in ids)

    parts: list[bytes] = [MAGIC]
    cursor = len(MAGIC)

    def emit(blob: bytes) -> int:
        nonlocal cursor
        at = cursor
        parts.append(blob)
        cursor += len(blob)
        return at

    aabb = _aabb(samples)
    emit(
        rec.Header(
            duration_sec=float(duration_sec),
            gaussian_count=len(distinct_ids),
            aabb=aabb,
            profile=profile,
            library=library,
            temporal_model="keyframe-delta",
            cutoff=cutoff,
        ).encode()
    )
    emit(
        rec.Quantization(
            scheme="uniform-v1",
            pos_origin=[float(v) for v in grids.origin],
            step_pos=grids.steps.pos,
            step_scale_log=grids.steps.scale_log,
            step_rot=grids.steps.rot,
            step_rgb=grids.steps.rgb,
            step_alpha=grids.steps.alpha,
            step_motion=grids.steps.motion,
            step_time=grids.steps.time,
            step_sigma_log=grids.steps.sigma_log,
            step_sh=grids.steps.sh,
            bounds=grids.bounds.as_strings(),
        ).encode()
    )
    emit(rec.WindowTable(windows=list(grids.windows)).encode())

    index: list[rec.ChunkIndexEntry] = []
    offsets: list[int] = []  # chunk record offset per sample
    kinds: list[int] = []
    depths: list[int] = []
    keyframe_offset = 0

    for i, (ids, bins) in enumerate(quantized):
        t0, t1 = t0s[i], t1s[i]
        if is_keyframe(i, kd):
            # A keyframe states every live gaussian afresh at its physical interval
            # start. Keep the shared sample bins unchanged for later delta arithmetic,
            # but serialize mu_t at Chunk.t0 as spec section 11.3 requires.
            keyframe_bins = dict(bins)
            sigma = bins[op.A_SIGMA_T].reshape(-1)
            never_fades = (bins[op.A_FLAGS].reshape(-1) & op.FLAG_NEVER_FADES) != 0
            step = grids.mu_step(sigma, never_fades)
            keyframe_bins[op.A_MU_T] = np.rint(t0 / step).astype(np.int64).reshape(-1, 1)
            # Deltas must subtract from the state that was actually serialized.  In
            # particular, a delta following a later keyframe has to undo this t0
            # anchor when its authored mu_t differs; subtracting from the unmodified
            # input bins would make the encoded difference telescope to the wrong
            # absolute value during composition.
            quantized[i] = (ids, keyframe_bins)
            blob = rec.encode_chunk(
                t0,
                t1,
                0,
                int(ids.shape[0]),
                _keyframe_streams(ids, keyframe_bins, codec, level),
            )
            at = emit(blob)
            offsets.append(at)
            kinds.append(0)
            depths.append(0)
            keyframe_offset = at
            index.append(
                rec.ChunkIndexEntry(
                    t0=t0,
                    t1=t1,
                    chunk_offset=at,
                    chunk_length=len(blob),
                    gaussian_count=int(ids.shape[0]),
                    extended=True,
                    kind=0,
                    keyframe_offset=at,
                    live_count=int(ids.shape[0]),
                )
            )
            continue

        # A delta: reference the keyframe (mode 0) or the previous chunk (mode 1).
        if kd.delta_mode == rec.DELTA_MODE_KEYFRAME:
            ref_sample = _keyframe_index(i, kd)
            depth = 1
        else:
            ref_sample = i - 1
            depth = depths[i - 1] + 1
        ref_ids, ref_bins = quantized[ref_sample]
        update_ids, update_bins, birth_ids, birth_bins, death_ids = delta_groups(ref_ids, ref_bins, ids, bins)
        updates = encode_delta_streams(update_ids, update_bins, codec=codec, level=level)
        births = encode_delta_streams(birth_ids, birth_bins, codec=codec, level=level)
        deaths = death_streams(death_ids, codec=codec, level=level)
        blob = rec.encode_delta_chunk(
            t0,
            t1,
            level=0,
            delta_mode=kd.delta_mode,
            reference_offset=offsets[ref_sample],
            keyframe_offset=keyframe_offset,
            depth=depth,
            updates=updates,
            births=births,
            deaths=deaths,
            counts=(int(update_ids.shape[0]), int(birth_ids.shape[0]), int(death_ids.shape[0])),
        )
        at = emit(blob)
        offsets.append(at)
        kinds.append(1)
        depths.append(depth)
        index.append(
            rec.ChunkIndexEntry(
                t0=t0,
                t1=t1,
                chunk_offset=at,
                chunk_length=len(blob),
                gaussian_count=int(update_ids.shape[0] + birth_ids.shape[0] + death_ids.shape[0]),
                extended=True,
                kind=1,
                delta_mode=kd.delta_mode,
                reference_offset=offsets[ref_sample],
                keyframe_offset=keyframe_offset,
                depth=depth,
                live_count=int(ids.shape[0]),
            )
        )

    summary_start = 0
    summary_bytes = b""
    if write_index:
        summary_start = cursor
        for entry in index:
            emit(entry.encode())
        if write_statistics:
            emit(
                rec.Statistics(
                    gaussian_count=len(distinct_ids),
                    chunk_count=len(index),
                    duration_sec=float(duration_sec),
                    aabb=aabb,
                ).encode()
            )
        summary_bytes = b"".join(parts)[summary_start:]

    emit(
        rec.Footer(
            summary_start=summary_start,
            summary_offset_start=0,
            summary_crc=crc32(summary_bytes) if (write_crc and summary_bytes) else 0,
        ).encode()
    )
    parts.append(MAGIC)
    return b"".join(parts)


def _keyframe_index(i: int, kd: KeyframeDeltaOptions) -> int:
    j = i
    while j > 0 and not is_keyframe(j, kd):
        j -= 1
    return j


def _aabb(samples: list[Sample]) -> list[float]:
    positions = np.concatenate(
        [np.asarray(s.gaussians.positions, dtype=np.float64) for s in samples if s.gaussians.count]
    )
    if not positions.size:
        return [0.0] * 6
    return [*positions.min(axis=0).tolist(), *positions.max(axis=0).tolist()]


# --------------------------------------------------------------------------
# Decoding
# --------------------------------------------------------------------------


@dataclass
class ChunkInfo:
    """One decoded state chunk and the composed population that follows from it."""

    t0: float
    t1: float
    kind: int
    delta_mode: int | None
    depth: int
    offset: int
    reference_offset: int
    update_count: int | None
    birth_count: int | None
    death_count: int | None
    state: State  # the composed population valid over [t0, t1)


@dataclass
class DecodedSequence:
    header: rec.Header
    quantization: rec.Quantization
    windows: list[tuple[float, float]]
    chunks: list[ChunkInfo] = field(default_factory=list)

    @property
    def grids(self) -> Grids:
        q = self.quantization
        steps = Steps(
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
        return Grids(
            steps=steps,
            bounds=None,
            origin=np.asarray(q.pos_origin, dtype=np.float64),
            windows=list(self.windows),
            cutoff=self.header.cutoff,
        )


def _decode_group(stream_bytes) -> tuple[np.ndarray, dict[int, np.ndarray]]:
    """One length-framed sub-block: its ids, and a bin array per other attribute."""
    cursor = Cursor(bytes(stream_bytes))
    got: dict[int, np.ndarray] = {}
    while cursor.remaining() > 0:
        attribute_id, values = decode_stream(cursor)
        # One stream per attribute here too. The regular chunk path refuses a second;
        # this path had its own loop and was still resolving it silently, so the same
        # malformed file was refused as a chunk and accepted as a delta group.
        if attribute_id in got:
            raise MalformedFile(
                f"a keyframe-delta group carries attribute {attribute_id} twice; the format "
                f"defines one stream per attribute",
                code="duplicate-attribute-stream",
            )
        got[attribute_id] = values
    if not len(stream_bytes):
        return np.zeros(0, np.int64), {}
    if op.A_GAUSSIAN_ID not in got:
        raise MalformedFile("a keyframe-delta group carries no gaussian_id stream", code="missing-gaussian-id")
    ids = got.pop(op.A_GAUSSIAN_ID)[:, 0].astype(np.int64)
    return ids, got


def _keyframe_from_chunk(content) -> tuple[np.ndarray, dict[int, np.ndarray]]:
    head, streams = rec.parse_chunk(content)
    cursor = Cursor(bytes(streams))
    got: dict[int, np.ndarray] = {}
    while cursor.remaining() > 0:
        attribute_id, values = decode_stream(cursor)
        # One stream per attribute here too. The regular chunk path refuses a second;
        # this path had its own loop and was still resolving it silently, so the same
        # malformed file was refused as a chunk and accepted as a delta group.
        if attribute_id in got:
            raise MalformedFile(
                f"a keyframe-delta group carries attribute {attribute_id} twice; the format "
                f"defines one stream per attribute",
                code="duplicate-attribute-stream",
            )
        got[attribute_id] = values
    if op.A_GAUSSIAN_ID not in got:
        raise MalformedFile("a keyframe-delta chunk carries no gaussian_id stream", code="missing-gaussian-id")
    ids = got.pop(op.A_GAUSSIAN_ID)[:, 0].astype(np.int64)
    missing = [a for a in _REQUIRED if a not in got]
    if missing and head.count:
        raise MalformedFile(f"keyframe chunk is missing required attributes {missing}")
    return ids, got


def _compose_delta(reference: State, content) -> tuple[State, rec.DeltaChunkHeader]:
    head, updates, births, deaths = rec.parse_delta_chunk(content)
    update_ids, update_bins = _decode_group(updates)
    birth_ids, birth_bins = _decode_group(births)
    death_ids, _ = _decode_group(deaths)
    state = apply_delta(
        reference,
        update_ids=update_ids,
        update_bins=update_bins,
        birth_ids=birth_ids,
        birth_bins=birth_bins,
        death_ids=death_ids,
    )
    return state, head


def decode_streamed(data: bytes) -> DecodedSequence:
    """Front to back: decode each chunk and compose it onto the state it references."""
    check_magic(data)
    header = quant = None
    windows: list[tuple[float, float]] = []
    chunks: list[ChunkInfo] = []
    by_offset: dict[int, State] = {}

    for record in iter_records(data, len(MAGIC)):
        if record.opcode == op.HEADER:
            header = rec.Header.parse(record.content)
            if header.temporal_model != "keyframe-delta":
                raise MalformedFile(
                    f"decode_streamed is the keyframe-delta path; this file is {header.temporal_model!r}",
                    code="wrong-temporal-model",
                )
        elif record.opcode == op.QUANTIZATION:
            quant = rec.Quantization.parse(record.content)
        elif record.opcode == op.WINDOW_TABLE:
            windows = rec.WindowTable.parse(record.content).windows
        elif record.opcode == op.CHUNK:
            ids, bins = _keyframe_from_chunk(record.content)
            state = keyframe_state(ids, bins)
            by_offset[record.offset] = state
            chunks.append(
                ChunkInfo(
                    _t0(record.content), _t1(record.content), 0, None, 0, record.offset, 0, None, None, None, state
                )
            )
        elif record.opcode == op.DELTA_CHUNK:
            head_peek = rec.parse_delta_chunk(record.content)[0]
            reference = by_offset.get(head_peek.reference_offset)
            if reference is None:
                raise MalformedFile(
                    f"delta chunk at {record.offset} references {head_peek.reference_offset}, "
                    f"which has not been decoded (references point backwards only)",
                    code="broken-reference",
                )
            if head_peek.reference_offset >= record.offset:
                raise MalformedFile(
                    f"delta chunk at {record.offset} references {head_peek.reference_offset}, which is not behind it",
                    code="forward-reference",
                )
            state, head = _compose_delta(reference, record.content)
            by_offset[record.offset] = state
            chunks.append(
                ChunkInfo(
                    head.t0,
                    head.t1,
                    1,
                    head.delta_mode,
                    head.depth,
                    record.offset,
                    head.reference_offset,
                    head.update_count,
                    head.birth_count,
                    head.death_count,
                    state,
                )
            )

    if header is None or quant is None:
        raise MalformedFile("keyframe-delta file has no Header or Quantization record")
    return DecodedSequence(header=header, quantization=quant, windows=windows, chunks=chunks)


def _t0(content) -> float:
    return Cursor(bytes(content)).f64()


def _t1(content) -> float:
    c = Cursor(bytes(content))
    c.f64()
    return c.f64()


def decode_indexed(data: bytes) -> tuple[DecodedSequence, list[rec.ChunkIndexEntry]]:
    """Read the Footer, then the index, then compose each chunk by byte range.

    The composed state per chunk is produced by walking that chunk's chain (spec §11.8),
    which is the seeking client's path and must reach the same population `decode_streamed`
    reaches front to back.
    """
    check_magic(data)
    header = quant = None
    windows: list[tuple[float, float]] = []
    for record in iter_records(data, len(MAGIC)):
        if record.opcode == op.HEADER:
            header = rec.Header.parse(record.content)
        elif record.opcode == op.QUANTIZATION:
            quant = rec.Quantization.parse(record.content)
        elif record.opcode == op.WINDOW_TABLE:
            windows = rec.WindowTable.parse(record.content).windows
        elif record.opcode == op.FOOTER:
            footer = rec.Footer.parse(record.content)
            break
    else:
        raise MalformedFile("file has no Footer")
    if header is None or quant is None:
        raise MalformedFile("keyframe-delta file has no Header or Quantization record")

    index: list[rec.ChunkIndexEntry] = []
    for record in iter_records(data, footer.summary_start):
        if record.opcode == op.CHUNK_INDEX:
            index.append(rec.ChunkIndexEntry.parse(record.content))
        else:
            break
    check_tiling(index)

    # Compose each entry by walking its chain, so both read paths are exercised.
    chunks: list[ChunkInfo] = []
    for entry in index:
        state = _compose_chain(data, index, entry)
        update_count = birth_count = death_count = None
        if entry.kind:
            # The counts are not in the index — there `gaussian_count` is their sum — so a
            # reader that wants the split reads the delta chunk's own header. The chain walk
            # already fetched this record; parsing its header again is cheap.
            head = rec.parse_delta_chunk(_record_at(data, entry.chunk_offset, entry.chunk_length))[0]
            update_count, birth_count, death_count = head.update_count, head.birth_count, head.death_count
        chunks.append(
            ChunkInfo(
                entry.t0,
                entry.t1,
                entry.kind,
                entry.delta_mode if entry.kind else None,
                entry.depth,
                entry.chunk_offset,
                entry.reference_offset,
                update_count,
                birth_count,
                death_count,
                state,
            )
        )
    return DecodedSequence(header=header, quantization=quant, windows=windows, chunks=chunks), index


def _record_at(data: bytes, offset: int, length: int):
    return rec_content(data[offset : offset + length])


def rec_content(record_bytes: bytes):
    c = Cursor(record_bytes)
    c.u8()
    return c.take(c.u64())


def _compose_chain(data: bytes, index: list[rec.ChunkIndexEntry], entry: rec.ChunkIndexEntry) -> State:
    chain = chain_for(index, (entry.t0 + entry.t1) / 2.0)
    state: State | None = None
    for link in chain:
        content = _record_at(data, link.chunk_offset, link.chunk_length)
        if link.kind == 0:
            ids, bins = _keyframe_from_chunk(content)
            state = keyframe_state(ids, bins)
        else:
            assert state is not None
            state, _ = _compose_delta(state, content)
    assert state is not None
    return state


# --------------------------------------------------------------------------
# Reconstruction and the canonical summary
# --------------------------------------------------------------------------


def _dequantize(state: State, grids: Grids):
    """The composed bins as float gaussian state, by the same arithmetic §5.6/§6 give a
    `gaussian-birth` chunk. Returns arrays aligned with `state.ids`."""
    n = state.count
    if n == 0:
        z3 = np.zeros((0, 3))
        return dict(
            positions=z3,
            scales=z3,
            rotations=np.zeros((0, 4)),
            colors=np.zeros((0, 4)),
            motions=z3,
            mu_t=np.zeros(0),
            sigma_t=np.zeros(0),
        )
    b = state.bins
    if op.A_WINDOW_INDEX not in b:
        # A zero-count keyframe can omit every stream, and `apply_delta` carries forward
        # only attributes the reference already had — so a later birth can compose a
        # non-empty state with no window_index. Reconstruction reads it below, so this is
        # a refusal rather than a KeyError from inside the renderer.
        raise MalformedFile(
            "a non-empty state carries no window_index column; it is a required keyframe attribute (section 11.5)",
            code="missing-window-index",
        )
    sigma_bins = b[op.A_SIGMA_T][:, 0]
    never_fades = b[op.A_FLAGS][:, 0] != 0
    sigma = np.where(never_fades, np.inf, np.exp(sigma_bins * grids.steps.sigma_log))
    m_step = grids.motion_step(sigma_bins, never_fades, b[op.A_WINDOW_INDEX][:, 0])[:, None]
    t_step = grids.mu_step(sigma_bins, never_fades)
    return dict(
        positions=dequantize(b[op.A_POSITION], grids.steps.pos, grids.origin),
        scales=np.exp(dequantize(b[op.A_SCALE], grids.steps.scale_log)),
        rotations=dequantize_rotation(b[op.A_ROTATION_INDEX][:, 0], b[op.A_ROTATION], grids.steps.rot),
        colors=np.concatenate(
            [
                np.clip(dequantize(rct_inverse(b[op.A_COLOR]), grids.steps.rgb), 0.0, 1.0),
                np.clip(dequantize(b[op.A_OPACITY][:, 0], grids.steps.alpha), 0.0, 1.0)[:, None],
            ],
            axis=1,
        ),
        motions=b[op.A_MOTION].astype(np.float64) * m_step,
        mu_t=b[op.A_MU_T][:, 0].astype(np.float64) * t_step,
        sigma_t=sigma,
        # Carried through so reconstruction can apply each row's own validity window.
        window_index=b[op.A_WINDOW_INDEX][:, 0].astype(np.int64),
    )


def reconstruct_at(state: State, grids: Grids, t: float) -> dict:
    """The composed population reconstructed at instant `t`, per spec §3, in id order.

    Everything downstream orders by `gaussian_id`, which is unique within a state (spec
    §11.2). That is decoded-value order — not stream order, which a reader may not rely on
    — so two implementations that compose the same population agree on every row.
    """
    values = _dequantize(state, grids)
    order = np.argsort(state.ids, kind="stable")
    ids = state.ids[order]
    n = ids.shape[0]
    if n == 0:
        return dict(
            ids=ids,
            centers=np.zeros((0, 3)),
            scales=np.zeros((0, 3)),
            rotations=np.zeros((0, 4)),
            rgb=np.zeros((0, 3)),
            opacity=np.zeros(0),
        )
    mu = values["mu_t"][order]
    sigma = values["sigma_t"][order]
    position = values["positions"][order]
    motion = values["motions"][order]
    color = values["colors"][order]
    with np.errstate(over="ignore"):
        marginal = np.where(np.isinf(sigma), 1.0, np.exp(-0.5 * ((t - mu) / sigma) ** 2))
    # A gaussian is absent outside its own validity window, exactly as the gaussian-birth
    # path decides it (`model.py`: `win_lo <= t < win_hi`). This was unobservable while
    # every keyframe-delta file carried one full-duration window — every row was always
    # in-window — and becomes reachable the moment a file declares more than one, which
    # is what the rest of this change enables. Without it a gaussian whose window closed
    # at 0.5s is still reported, at full opacity, at t = 4.
    table = np.asarray(grids.windows or [(0.0, 0.0)], dtype=np.float64)
    widx = np.asarray(values["window_index"], dtype=np.int64)[order]
    # Absent means absent: the gaussian-birth path drops these rows outright
    # (`model.py`: `idx = flatnonzero(visible)`), so id, centre, scale and liveCount all
    # exclude them. Zeroing only the opacity would still report a gaussian section 3 says
    # does not exist at this instant.
    keep = np.flatnonzero((table[widx, 0] <= t) & (t < table[widx, 1]))
    centers = position + motion * (t - mu)[:, None]
    return dict(
        ids=ids[keep],
        centers=centers[keep],
        scales=values["scales"][order][keep],
        rotations=values["rotations"][order][keep],
        rgb=color[keep, :3],
        opacity=color[keep, 3] * marginal[keep],
    )


def render_at(decoded: DecodedSequence, t: float) -> dict:
    """The full renderable composed population at instant `t`, in `gaussian_id` order.

    Finds the state chunk covering `t`, composes it (the chain the streamed decode already
    walked), reconstructs per spec §3, and returns positions, scales, rotations, linear RGB
    and marginal-folded opacity — everything a downstream renderer or an interchange export
    needs for one instant. This is the per-frame primitive the USD animated export drives.
    """
    return reconstruct_at(_state_covering(decoded.chunks, t).state, decoded.grids, t)


def probe_times(chunks: list[ChunkInfo], duration_sec: float) -> list[float]:
    """Every chunk's `t0` and interval midpoint, plus one instant just below the end.

    Derived from the file rather than hardcoded, so "seek to every chunk" is the
    expectation rather than a separate test (design §11.2).
    """
    times: set[float] = set()
    for c in chunks:
        times.add(round(float(c.t0), 9))
        times.add(round((float(c.t0) + float(c.t1)) / 2.0, 9))
    times.add(round(max(0.0, float(duration_sec) - 1e-6), 9))
    return sorted(times)


def _state_covering(chunks: list[ChunkInfo], t: float) -> ChunkInfo:
    for c in chunks:
        if c.t0 <= t < c.t1:
            return c
    return chunks[-1]


def states_json(decoded: DecodedSequence) -> dict:
    """The statement two implementations are diffed on for a keyframe-delta file.

    `chunks` proves a decoder read `depth`, `delta_mode` and `live_count` — a field no row
    mentions is one an implementation can decline to decode. `states` is the reconstruction
    at an instant, the thing the per-file summary could never carry: for each probe, the
    composed population's live count, a sample of centres and scales in id order, and the
    aggregate over the whole population.
    """
    grids = decoded.grids
    duration = float(decoded.header.duration_sec)
    chunk_rows = []
    for c in decoded.chunks:
        chunk_rows.append(
            {
                "t0": _num(c.t0),
                "t1": _num(c.t1),
                "kind": "keyframe" if c.kind == 0 else "delta",
                "deltaMode": None
                if c.kind == 0
                else ("chained" if c.delta_mode == rec.DELTA_MODE_CHAINED else "keyframe"),
                "depth": str(c.depth),
                "liveCount": str(c.state.count),
                "updateCount": None if c.update_count is None else str(c.update_count),
                "birthCount": None if c.birth_count is None else str(c.birth_count),
                "deathCount": None if c.death_count is None else str(c.death_count),
            }
        )

    states = []
    for t in probe_times(decoded.chunks, duration):
        info = _state_covering(decoded.chunks, t)
        r = reconstruct_at(info.state, grids, t)
        centers = r["centers"]
        sample_n = min(SAMPLE, centers.shape[0])
        states.append(
            {
                "t": _num(t),
                # The count at this instant, from the rows reconstruction actually
                # returned. `info.state.count` is the chunk's population, which now
                # differs once a validity window has closed — reporting it here would
                # claim gaussians are live that the same summary omits from `sample`.
                "liveCount": str(len(r["ids"])),
                "sample": {
                    "gaussianIds": [str(int(v)) for v in r["ids"][:sample_n]],
                    "positions": [[_num(v) for v in centers[i]] for i in range(sample_n)],
                    "scales": [[_num(v) for v in r["scales"][i]] for i in range(sample_n)] if centers.shape[0] else [],
                },
                "aggregate": {
                    "positionSum": [_num(sum(float(row[axis]) for row in centers)) for axis in range(3)],
                    "opacitySum": _num(sum(float(v) for v in r["opacity"])),
                },
            }
        )

    distinct = {int(v) for c in decoded.chunks if c.kind == 0 for v in c.state.ids}
    for c in decoded.chunks:
        distinct.update(int(v) for v in c.state.ids)
    return {
        "temporalModel": "keyframe-delta",
        "gaussianCount": str(decoded.header.gaussian_count),
        "durationSec": _num(duration),
        "cutoff": _num(decoded.header.cutoff),
        "chunks": chunk_rows,
        "states": states,
    }
