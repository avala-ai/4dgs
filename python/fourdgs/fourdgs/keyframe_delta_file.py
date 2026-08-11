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
from collections.abc import Callable
from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import MalformedFile, UnsupportedCodec
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
    CODEC_ZSTD,
    MAGIC,
    Cursor,
    check_magic,
    crc32,
    decode_stream,
    decompress,
    encode_stream,
    iter_records,
)
from .stream_reader import check_window_indices, chunk_stream_bytes

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


def _reanchor_bins(bins: dict[int, np.ndarray], grids: Grids, t0: float) -> dict[int, np.ndarray]:
    """Restate quantized trajectories at ``t0`` without moving their centres.

    Position and ``mu_t`` are one coupled trajectory anchor.  Changing only the
    latter changes the reconstructed centre, so keyframes, updates, and births
    all pass through this operation before they are serialized.
    """
    if not bins[op.A_MU_T].size:
        return dict(bins)

    sigma = bins[op.A_SIGMA_T].reshape(-1)
    flags = bins[op.A_FLAGS].reshape(-1)
    never_fades = (flags & op.FLAG_NEVER_FADES) != 0
    window_index = bins[op.A_WINDOW_INDEX].reshape(-1)
    motion_step = grids.motion_step(sigma, never_fades, window_index)
    time_step = grids.mu_step(sigma, never_fades)

    position = dequantize(bins[op.A_POSITION], grids.steps.pos, grids.origin)
    motion = bins[op.A_MOTION].astype(np.float64) * motion_step[:, None]
    authored_mu = bins[op.A_MU_T].reshape(-1).astype(np.float64) * time_step
    anchor_bins = np.rint(float(t0) / time_step).astype(np.int64)
    serialized_mu = anchor_bins.astype(np.float64) * time_step
    centre = position + motion * (serialized_mu - authored_mu)[:, None]

    anchored = dict(bins)
    anchored[op.A_POSITION] = quantize(centre, grids.steps.pos, grids.origin)
    anchored[op.A_MU_T] = anchor_bins.reshape(-1, 1)
    return anchored


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
    quantized = [
        (ids, _reanchor_bins(bins, grids, sample.t0))
        for sample in samples
        for ids, bins in [_quantize_sample(sample, grids)]
    ]
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

    # Header and Statistics describe the rest positions the file actually
    # serializes. Reanchoring can move those far from the source samples'
    # original position arrays, especially for a fast trajectory whose authored
    # mu_t differs from the interval start.
    aabb = _aabb(quantized, grids)
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
            # The sample was already restated at this physical interval start.  Position
            # and mu_t were rebased together, so serializing the new anchor preserves the
            # trajectory's centre rather than moving it to the old position at a new time.
            keyframe_bins = bins
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

        # Compare both populations at this delta's t0. Position and mu_t are a coupled
        # anchor: reanchoring the reference makes an inherited moving trajectory compare
        # equal when it already reaches the sample's centre at t0. Births and the target
        # population were normalized to t0 before this loop.
        live = np.isin(ids, ref_ids)
        order = np.argsort(ref_ids, kind="stable")
        ref_rows = order[np.searchsorted(ref_ids[order], ids[live])]
        comparison_ref_bins = _reanchor_bins(ref_bins, grids, t0)

        update_ids, update_bins, birth_ids, birth_bins, death_ids = delta_groups(
            ref_ids, comparison_ref_bins, ids, bins
        )

        # delta_groups subtracted from the comparison-only t0 anchor. The wire delta must
        # instead subtract position and mu_t from the state actually serialized by its
        # reference so composition telescopes to the normalized target exactly.
        updated = np.isin(ids, update_ids)
        if update_ids.size:
            update_ref_rows = order[np.searchsorted(ref_ids[order], update_ids)]
            update_bins[op.A_POSITION] = bins[op.A_POSITION][updated] - ref_bins[op.A_POSITION][update_ref_rows]
            update_bins[op.A_MU_T] = bins[op.A_MU_T][updated] - ref_bins[op.A_MU_T][update_ref_rows]

        # Retain the composed anchors the decoder will see for later chained deltas.
        # Untouched common rows keep their earlier position/mu_t pair; updated rows and
        # births use this delta's normalized pair.
        composed_bins = dict(bins)
        composed_position = bins[op.A_POSITION].copy()
        composed_position[live] = ref_bins[op.A_POSITION][ref_rows]
        composed_position[updated] = bins[op.A_POSITION][updated]
        composed_bins[op.A_POSITION] = composed_position
        composed_mu = bins[op.A_MU_T].copy()
        composed_mu[live] = ref_bins[op.A_MU_T][ref_rows]
        composed_mu[updated] = bins[op.A_MU_T][updated]
        composed_bins[op.A_MU_T] = composed_mu
        quantized[i] = (ids, composed_bins)
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


def _aabb(quantized: list[tuple[np.ndarray, dict[int, np.ndarray]]], grids: Grids) -> list[float]:
    populations = [
        dequantize(bins[op.A_POSITION], grids.steps.pos, grids.origin) for ids, bins in quantized if ids.size
    ]
    if not populations:
        return [0.0] * 6
    positions = np.concatenate(populations)
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
    _check_channel_counts(got)
    if not len(stream_bytes):
        return np.zeros(0, np.int64), {}
    if op.A_GAUSSIAN_ID not in got:
        raise MalformedFile("a keyframe-delta group carries no gaussian_id stream", code="missing-gaussian-id")
    ids = got.pop(op.A_GAUSSIAN_ID)[:, 0].astype(np.int64)
    return ids, got


def _keyframe_from_chunk(content) -> tuple[np.ndarray, dict[int, np.ndarray]]:
    head, streams = rec.parse_chunk(content)
    cursor = Cursor(chunk_stream_bytes(head, streams))
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
    # Against the count the record declares, exactly as `decode_streams` does for a
    # gaussian-birth chunk. A keyframe chunk is a Chunk record and `count` is the same
    # field there — but this path never looked at it, so a chunk whose streams carry a
    # different number of elements than its header declares was refused as a
    # gaussian-birth chunk and composed as a keyframe.
    _check_element_counts(got, int(head.count), "the keyframe chunk")
    ids = got.pop(op.A_GAUSSIAN_ID)[:, 0].astype(np.int64)
    missing = [a for a in _REQUIRED if a not in got]
    if missing and head.count:
        raise MalformedFile(f"keyframe chunk is missing required attributes {missing}")
    return ids, got


def _check_element_counts(bins: dict[int, np.ndarray], count: int, what: str) -> None:
    """Every stream in a group carries exactly the elements its header declares.

    §5.18: "a stream whose `element_count` disagrees with its group's count is a refusal
    rather than an allocation". The counts are in the record header so a streamed reader
    can size its working set before it decompresses anything; a reader that instead takes
    the size from whatever arrived has given the header no meaning, and the alignment
    between a group's id stream and its value streams — which is what a delta *is* — rests
    on a number nobody checked.
    """
    _check_channel_counts(bins)
    for attribute, values in sorted(bins.items()):
        if values.shape[0] != count:
            raise MalformedFile(
                f"attribute {attribute} carries {values.shape[0]} elements; {what} declares {count}",
                code="stream-element-count-mismatch",
            )


def _check_channel_counts(bins: dict[int, np.ndarray]) -> None:
    """Known attributes have the one interleaving width fixed by the registry."""
    for attribute, values in sorted(bins.items()):
        channels = op.ATTRIBUTE_CHANNELS.get(attribute)
        if channels is not None and values.shape[1] != channels:
            raise MalformedFile(
                f"attribute {attribute} declares {values.shape[1]} channels; the registry says {channels}",
                code="stream-channel-count-mismatch",
            )


def _compose_delta(reference: State, content) -> tuple[State, rec.DeltaChunkHeader]:
    head, updates, births, deaths = _delta_chunk_groups(content)
    update_ids, update_bins = _decode_group(updates)
    birth_ids, birth_bins = _decode_group(births)
    death_ids, death_bins = _decode_group(deaths)
    missing_birth = [attribute for attribute in _REQUIRED if attribute not in birth_bins]
    if missing_birth and head.birth_count:
        raise MalformedFile(
            f"the delta chunk's births group is missing required attributes {missing_birth}; "
            "a birth carries complete absolute state",
            code="incomplete-birth",
        )
    if death_bins:
        raise MalformedFile(
            f"the delta chunk's deaths group carries attributes {sorted(death_bins)}; "
            "deaths contain exactly one gaussian_id stream",
            code="unexpected-death-attribute",
        )
    # The three declared sizes, against the three groups that arrived. `apply_delta` sizes
    # everything from the decoded id arrays, so without this the declared counts were
    # parsed and then never used for anything — and a Delta Chunk that says it updates
    # nine hundred gaussians and carries three composed silently.
    for ids, bins, declared, group in (
        (update_ids, update_bins, int(head.update_count), "updates"),
        (birth_ids, birth_bins, int(head.birth_count), "births"),
        (death_ids, death_bins, int(head.death_count), "deaths"),
    ):
        if int(ids.shape[0]) != declared:
            raise MalformedFile(
                f"the delta chunk's {group} group carries {int(ids.shape[0])} gaussians; "
                f"its header declares {declared}",
                code="stream-element-count-mismatch",
            )
        _check_element_counts(bins, declared, f"the delta chunk's {group} group")
    state = apply_delta(
        reference,
        update_ids=update_ids,
        update_bins=update_bins,
        birth_ids=birth_ids,
        birth_bins=birth_bins,
        death_ids=death_ids,
    )
    return state, head


def _delta_chunk_groups(content) -> tuple[rec.DeltaChunkHeader, memoryview, memoryview, memoryview]:
    """Parse a Delta Chunk and honour compression on its three-group records block."""
    head, stored = rec.parse_delta_chunk_block(content)
    if head.compression == "":
        records = bytes(stored)
        if len(records) != head.uncompressed_size:
            raise MalformedFile(
                f"delta chunk at t0={head.t0} declares uncompressed_size "
                f"{head.uncompressed_size}; its records block contains {len(records)} bytes",
                code="decompressed-size-mismatch",
            )
    else:
        codec = {"deflate": CODEC_DEFLATE, "zstd": CODEC_ZSTD}.get(head.compression)
        if codec is None:
            raise UnsupportedCodec(
                f"delta chunk at t0={head.t0} is compressed with {head.compression!r}, which this build does not know",
                code="unknown-stream-codec",
            )
        records = decompress(bytes(stored), codec, head.uncompressed_size)
    groups = Cursor(records)
    updates = groups.take(groups.u64())
    births = groups.take(groups.u64())
    deaths = groups.take(groups.u64())
    if groups.remaining():
        raise MalformedFile(
            f"delta chunk at t0={head.t0} has {groups.remaining()} bytes after its deaths group",
            code="delta-group-framing-mismatch",
        )
    return head, updates, births, deaths


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
            head_peek = rec.parse_delta_chunk_block(record.content)[0]
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


@dataclass
class IndexedSequence:
    """A file's front matter and its index, with nothing composed.

    What `decode_indexed` reads before it decodes anything, split out because two callers
    want only this much: one that means to compose a single instant, and one — the
    validator — that means to check each chunk in turn and keep none of them.
    """

    header: rec.Header
    quantization: rec.Quantization
    windows: list[tuple[float, float]]
    index: list[rec.ChunkIndexEntry]


def open_indexed(data: bytes) -> IndexedSequence:
    """Read the Footer and the index, and check that the index tiles the timeline."""
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
    # A Footer whose `summary_start` is 0 is a file with no summary at all (§5.2), which is
    # the indexless file the streamed path exists for — not an index that happens to begin
    # at byte 0. Reading records from there parses the magic as framing and reports
    # whatever the eight magic bytes happen to mean as a record length, which is a
    # diagnosis about nothing.
    if not footer.summary_start:
        raise MalformedFile(
            "this file carries no chunk index, so it cannot be read by seeking; "
            "a streamed reader decodes it front to back",
            code="no-chunk-index",
        )

    index: list[rec.ChunkIndexEntry] = []
    for record in iter_records(data, footer.summary_start):
        if record.opcode == op.CHUNK_INDEX:
            index.append(rec.ChunkIndexEntry.parse(record.content))
        else:
            break
    check_tiling(index, header.duration_sec)
    return IndexedSequence(header=header, quantization=quant, windows=windows, index=index)


def decode_indexed(data: bytes) -> tuple[DecodedSequence, list[rec.ChunkIndexEntry]]:
    """Read the Footer, then the index, then compose each chunk by byte range.

    The composed state per chunk is produced by walking that chunk's chain (spec §11.8),
    which is the seeking client's path and must reach the same population `decode_streamed`
    reaches front to back.

    This returns every state at once, which is what a caller that wants the states wants
    and what a caller that wants a verdict must not ask for — `compose_chain` is that
    caller's entry point.
    """
    opened = open_indexed(data)
    index = opened.index

    # Compose each entry by walking its chain, so both read paths are exercised.
    chunks: list[ChunkInfo] = []
    for entry in index:
        state = compose_chain(data, index, entry, opened.windows)
        update_count = birth_count = death_count = None
        if entry.kind:
            # The counts are not in the index — there `gaussian_count` is their sum — so a
            # reader that wants the split reads the delta chunk's own header. The chain walk
            # already fetched this record; parsing its header again is cheap.
            head = rec.parse_delta_chunk_block(_record_at(data, entry.chunk_offset, entry.chunk_length))[0]
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
    return DecodedSequence(
        header=opened.header, quantization=opened.quantization, windows=opened.windows, chunks=chunks
    ), index


def _record_at(data: bytes, offset: int, length: int):
    if offset < 0 or length < 9 or offset + length > len(data):
        raise MalformedFile(
            f"indexed state range [{offset}, {offset + length}) is outside the {len(data)}-byte file",
            code="index-record-mismatch",
        )
    framed = Cursor(data[offset : offset + length])
    framed.u8()
    content_length = framed.u64()
    if content_length + 9 != length:
        raise MalformedFile(
            f"the chunk index range at {offset} declares {length} bytes; the record there "
            f"frames exactly {content_length + 9}",
            code="index-record-mismatch",
        )
    return framed.take(content_length)


def rec_content(record_bytes: bytes):
    c = Cursor(record_bytes)
    c.u8()
    return c.take(c.u64())


def check_window_indices_of(state: State, windows: list[tuple[float, float]]) -> None:
    """Refuse a `window_index` the table cannot answer, on either read path.

    The table defaults to a single `(0, 0)` entry when a file declares none, so index 0
    stays legal for a file with no Window Table — validating against the raw count would
    refuse those files on one path while the other decoded them.

    Composition produces bins and stops there, so nothing on this path used to look at
    `window_index` at all: the bound was proved during reconstruction, several calls
    later, on the one instant somebody asked for. A file whose keyframe carries an index
    outside its table therefore composed cleanly and refused when it was rendered — the
    same fault the gaussian-birth path refuses at decode.
    """
    table = len(windows) or 1
    values = state.bins.get(op.A_WINDOW_INDEX)
    if values is None:
        # A zero-count keyframe may omit every stream, and `apply_delta` carries forward
        # only the attributes the reference already had — so a later birth can compose a
        # non-empty state with no window_index column at all. Reconstruction indexes it,
        # so this is a refusal here rather than an IndexError there.
        if state.count:
            raise MalformedFile(
                "a composed state carries no window_index column; it is a required keyframe attribute (section 11.5)",
                code="missing-window-index",
            )
        return
    check_window_indices(np.asarray(values, dtype=np.int64).reshape(-1), table)


def _check_entry_against_record(entry: rec.ChunkIndexEntry, head: rec.DeltaChunkHeader) -> None:
    """The four fields the index and the Delta Chunk both state (spec §5.8).

    "A reader MUST refuse a file where the index and the record disagree, naming the
    field" — the duplication is deliberate and it is only a corruption check if somebody
    performs it. Nothing did: the chain is built from the index and the record was parsed
    for its group counts, so a file whose index and records describe two different
    sequences was read as whichever one the reader happened to consult.
    """
    for field_name, in_index, in_record in (
        ("delta_mode", entry.delta_mode, head.delta_mode),
        ("reference_offset", entry.reference_offset, head.reference_offset),
        ("keyframe_offset", entry.keyframe_offset, head.keyframe_offset),
        ("depth", entry.depth, head.depth),
        ("t0", entry.t0, head.t0),
        ("t1", entry.t1, head.t1),
    ):
        if in_index != in_record:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares {field_name} {in_index}; "
                f"the Delta Chunk record there declares {in_record}",
                code="index-record-mismatch",
            )
    declared = int(head.update_count) + int(head.birth_count) + int(head.death_count)
    if entry.gaussian_count != declared:
        raise MalformedFile(
            f"the chunk index entry at {entry.chunk_offset} declares gaussian_count {entry.gaussian_count}; "
            f"the Delta Chunk record there declares {declared} gaussians across its three groups",
            code="index-record-mismatch",
        )


def compose_chain(
    data: bytes,
    index: list[rec.ChunkIndexEntry],
    entry: rec.ChunkIndexEntry,
    windows: list[tuple[float, float]] | None = None,
) -> State:
    """Compose the chain ending at `entry`, and check the state it produces.

    Public because composing one entry is the whole of what a validator needs: it asks
    whether each chunk decodes, not what any of them decoded to, and holding every state
    to answer that costs many times the file. A caller that wants the states wants
    `decode_indexed`; a caller that wants the verdict calls this per entry and drops what
    it returns.
    """
    for indexed in index:
        if not indexed.extended:
            raise MalformedFile(
                f"the keyframe-delta chunk index entry at {indexed.chunk_offset} omits "
                "chunk_kind, delta reference, depth and live_count fields",
                code="index-record-mismatch",
            )
        if indexed.kind not in (0, 1):
            raise MalformedFile(
                f"the chunk index entry at {indexed.chunk_offset} declares unknown chunk_kind "
                f"{indexed.kind}; expected 0 (keyframe) or 1 (delta)",
                code="unknown-chunk-kind",
            )
    chain = chain_for(index, (entry.t0 + entry.t1) / 2.0)
    keyframe_at = chain[0].chunk_offset
    for link in chain:
        if link.extended and link.keyframe_offset != keyframe_at:
            raise MalformedFile(
                f"the chunk index entry at {link.chunk_offset} declares keyframe_offset "
                f"{link.keyframe_offset}; its chain reaches the keyframe at {keyframe_at}",
                code="index-record-mismatch",
            )
    state: State | None = None
    for link in chain:
        if link.kind not in (0, 1):
            raise MalformedFile(
                f"the chunk index entry at {link.chunk_offset} declares unknown chunk_kind "
                f"{link.kind}; expected 0 (keyframe) or 1 (delta)",
                code="unknown-chunk-kind",
            )
        content = _record_at(data, link.chunk_offset, link.chunk_length)
        opcode = data[link.chunk_offset] if link.chunk_offset < len(data) else None
        want = op.CHUNK if link.kind == 0 else op.DELTA_CHUNK
        if opcode != want:
            raise MalformedFile(
                f"the chunk index entry at {link.chunk_offset} declares chunk_kind {link.kind}, but the "
                f"record there is {op.name(opcode) if opcode is not None else 'past the end of the file'} "
                f"rather than {op.name(want)}",
                code="index-record-mismatch",
            )
        if link.kind == 0:
            head = rec.parse_chunk(content)[0]
            ids, bins = _keyframe_from_chunk(content)
            state = keyframe_state(ids, bins)
            if link.t0 != head.t0 or link.t1 != head.t1:
                raise MalformedFile(
                    f"the chunk index entry at {link.chunk_offset} declares interval "
                    f"[{link.t0}, {link.t1}); the keyframe Chunk record there declares "
                    f"[{head.t0}, {head.t1})",
                    code="index-record-mismatch",
                )
            if link.extended and link.gaussian_count != state.count:
                raise MalformedFile(
                    f"the chunk index entry at {link.chunk_offset} declares gaussian_count "
                    f"{link.gaussian_count}; the keyframe chunk there carries {state.count}",
                    code="index-record-mismatch",
                )
        else:
            if state is None:
                raise MalformedFile("a chain begins with a delta chunk", code="chain-without-keyframe")
            state, head = _compose_delta(state, content)
            if link.extended:
                _check_entry_against_record(link, head)
    if state is None:
        raise MalformedFile("a chain with no chunks in it", code="chain-without-keyframe")
    # `live_count` is the population after composition — the number a seeking consumer
    # budgets against — and it is the one index field only a decode can check.
    if entry.extended and entry.live_count != state.count:
        raise MalformedFile(
            f"the chunk index entry at {entry.chunk_offset} declares live_count {entry.live_count}; "
            f"composing its chain produces {state.count} gaussians",
            code="index-record-mismatch",
        )
    check_window_indices_of(state, windows if windows is not None else [])
    _decode_index_bands(data, entry)
    return state


def _decode_index_bands(
    data: bytes,
    entry: rec.ChunkIndexEntry,
    on_band: Callable[[int, int], None] | None = None,
) -> None:
    """Decode and discard every SH band the entry declares."""
    state_content = _record_at(data, entry.chunk_offset, entry.chunk_length)
    expected_rows = (
        int(rec.parse_chunk(state_content)[0].count)
        if entry.kind == 0
        else int(rec.parse_delta_chunk_block(state_content)[0].birth_count)
    )
    for declared_band, offset, length in entry.bands:
        if offset < 0 or length < 9 or offset + length > len(data):
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} points SH band "
                f"{declared_band} outside the file at [{offset}, {offset + length})",
                code="index-record-mismatch",
            )
        framed = Cursor(data[offset : offset + length])
        opcode = framed.u8()
        content_length = framed.u64()
        if opcode != op.SH_BAND_STREAM or content_length + 9 != length:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} points SH band "
                f"{declared_band} at {offset}, which is not one complete SH Band Stream record",
                code="index-record-mismatch",
            )
        band_content = Cursor(framed.take(content_length))
        record_band = band_content.u8()
        if record_band != declared_band:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares SH band "
                f"{declared_band}; the record at {offset} declares band {record_band}",
                code="index-record-mismatch",
            )
        if on_band is not None:
            on_band(declared_band, offset)
        attribute, values = decode_stream(band_content)
        if attribute != op.SH_BAND_STREAM:
            raise MalformedFile(
                f"the SH Band Stream at {offset} declares inner attribute_id {attribute}; "
                f"version 1 fixes it at {op.SH_BAND_STREAM}",
                code="index-record-mismatch",
            )
        expected_channels = 3 * (2 * declared_band + 1)
        if values.shape != (expected_rows, expected_channels):
            raise MalformedFile(
                f"the SH Band Stream at {offset} for band {declared_band} decodes to "
                f"shape {values.shape}; its owning state record requires "
                f"({expected_rows}, {expected_channels})",
                code="stream-element-count-mismatch",
            )


def check_index_bands(data: bytes, index: list[rec.ChunkIndexEntry], sh_degree: int) -> None:
    """Require the index to name exactly the physical bands following every state chunk.

    A validator cannot discover an omitted band by following the index: the omission is
    precisely what keeps it from reading that record. Walk the top-level framing once,
    associate the consecutive SH Band Streams with the Chunk or Delta Chunk immediately
    before them, and compare the resulting byte ranges with the summary. The walk retains
    only offsets and lengths; no band payload is accumulated.
    """
    by_offset: dict[int, rec.ChunkIndexEntry] = {}
    for entry in index:
        if entry.chunk_offset in by_offset:
            raise MalformedFile(
                f"two chunk index entries name the state chunk at {entry.chunk_offset}",
                code="index-record-mismatch",
            )
        by_offset[entry.chunk_offset] = entry

    wanted = list(range(1, sh_degree + 1))
    seen: set[int] = set()
    owner: int | None = None
    indexed: rec.ChunkIndexEntry | None = None
    following: list[tuple[int, int, int]] = []

    def finish_owner() -> None:
        nonlocal owner, indexed, following
        if owner is None:
            return
        if indexed is None:
            raise MalformedFile(
                f"the state chunk at {owner} is not named by the Chunk Index",
                code="index-record-mismatch",
            )
        if indexed.bands != following:
            raise MalformedFile(
                f"the chunk index entry at {owner} declares SH band ranges "
                f"{indexed.bands}; the physical records following that chunk are {following}",
                code="index-record-mismatch",
            )
        bands = [band for band, _offset, _length in following]
        if bands != wanted:
            raise MalformedFile(
                f"the state chunk at {owner} is followed by SH bands {bands}; "
                f"the Header declares degree {sh_degree}, requiring bands {wanted}",
                code="index-record-mismatch",
            )
        seen.add(owner)
        owner = None
        indexed = None
        following = []

    for record in iter_records(data, len(MAGIC)):
        if record.opcode in (op.CHUNK, op.DELTA_CHUNK):
            finish_owner()
            owner = record.offset
            indexed = by_offset.get(owner)
            following = []
            continue
        if record.opcode == op.SH_BAND_STREAM:
            if owner is None:
                raise MalformedFile(
                    f"SH Band Stream at byte {record.offset} does not immediately follow a state chunk",
                    code="index-record-mismatch",
                )
            band = Cursor(record.content).u8()
            following.append((band, record.offset, 9 + len(record.content)))
            continue
        finish_owner()

    finish_owner()
    for entry in index:
        if entry.chunk_offset not in seen:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} does not name a physical state chunk",
                code="index-record-mismatch",
            )


def scan_indexed(
    data: bytes,
    index: list[rec.ChunkIndexEntry],
    windows: list[tuple[float, float]],
    on_entry: Callable[[int, rec.ChunkIndexEntry], None] | None = None,
    on_band: Callable[[int, int], None] | None = None,
):
    """Compose an indexed timeline once, retaining only current and GOP-keyframe state.

    This is the validator path.  A seeking client legitimately calls `compose_chain` for
    one selected entry; calling it for every entry repeats both the index scan and every
    chained prefix.  Timeline order lets the validator prove the same references in one
    front-to-back pass.
    """
    for entry in index:
        if not entry.extended:
            raise MalformedFile(
                f"the keyframe-delta chunk index entry at {entry.chunk_offset} omits "
                "chunk_kind, delta reference, depth and live_count fields",
                code="index-record-mismatch",
            )
        if entry.kind not in (0, 1):
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares unknown chunk_kind "
                f"{entry.kind}; expected 0 (keyframe) or 1 (delta)",
                code="unknown-chunk-kind",
            )

    current: tuple[int, int, int, State] | None = None
    keyframe: tuple[int, int, State] | None = None
    for ordinal, entry in enumerate(sorted(index, key=lambda item: item.t0)):
        if on_entry is not None:
            on_entry(ordinal, entry)
        content = _record_at(data, entry.chunk_offset, entry.chunk_length)
        opcode = data[entry.chunk_offset] if entry.chunk_offset < len(data) else None
        expected_opcode = op.CHUNK if entry.kind == 0 else op.DELTA_CHUNK
        if opcode != expected_opcode:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares chunk_kind {entry.kind}, "
                f"but the record there is {op.name(opcode) if opcode is not None else 'past the end of the file'}",
                code="index-record-mismatch",
            )

        if entry.kind == 0:
            head = rec.parse_chunk(content)[0]
            ids, bins = _keyframe_from_chunk(content)
            state = keyframe_state(ids, bins)
            if entry.t0 != head.t0 or entry.t1 != head.t1:
                raise MalformedFile(
                    f"the chunk index entry at {entry.chunk_offset} declares interval "
                    f"[{entry.t0}, {entry.t1}); the keyframe Chunk record there declares "
                    f"[{head.t0}, {head.t1})",
                    code="index-record-mismatch",
                )
            if entry.gaussian_count != state.count:
                raise MalformedFile(
                    f"the chunk index entry at {entry.chunk_offset} declares gaussian_count "
                    f"{entry.gaussian_count}; the keyframe chunk there carries {state.count}",
                    code="index-record-mismatch",
                )
            if entry.extended and (
                entry.keyframe_offset != entry.chunk_offset
                or entry.depth != 0
                or entry.delta_mode != 0
                or entry.reference_offset != 0
            ):
                raise MalformedFile(
                    f"the keyframe index entry at {entry.chunk_offset} carries non-keyframe delta fields",
                    code="index-record-mismatch",
                )
            level = int(head.level)
            keyframe = (entry.chunk_offset, level, state)
            current = (entry.chunk_offset, 0, level, state)
        else:
            head = rec.parse_delta_chunk_block(content)[0]
            if entry.reference_offset >= entry.chunk_offset:
                raise MalformedFile(
                    f"delta index entry at {entry.chunk_offset} references "
                    f"{entry.reference_offset}, which is not behind it",
                    code="forward-reference",
                )
            if entry.delta_mode == rec.DELTA_MODE_KEYFRAME:
                if keyframe is None or entry.reference_offset != keyframe[0]:
                    expected = None if keyframe is None else keyframe[0]
                    raise MalformedFile(
                        f"keyframe-mode delta at {entry.chunk_offset} references {entry.reference_offset}; "
                        f"its GOP keyframe is at {expected}",
                        code="broken-reference",
                    )
                reference_at, reference_depth, reference_level, reference = (
                    keyframe[0],
                    0,
                    keyframe[1],
                    keyframe[2],
                )
            elif entry.delta_mode == rec.DELTA_MODE_CHAINED:
                if current is None or entry.reference_offset != current[0]:
                    expected = None if current is None else current[0]
                    raise MalformedFile(
                        f"chained delta at {entry.chunk_offset} references {entry.reference_offset}; "
                        f"the previous state is at {expected}",
                        code="broken-reference",
                    )
                reference_at, reference_depth, reference_level, reference = current
            else:
                raise MalformedFile(
                    f"delta index entry at {entry.chunk_offset} declares delta_mode "
                    f"{entry.delta_mode}; expected 0 or 1",
                    code="index-record-mismatch",
                )
            keyframe_at = keyframe[0] if keyframe is not None else 0
            if entry.keyframe_offset != keyframe_at:
                raise MalformedFile(
                    f"the chunk index entry at {entry.chunk_offset} declares keyframe_offset "
                    f"{entry.keyframe_offset}; its chain reaches the keyframe at {keyframe_at}",
                    code="index-record-mismatch",
                )
            expected_depth = reference_depth + 1
            if entry.depth != expected_depth:
                raise MalformedFile(
                    f"delta index entry at {entry.chunk_offset} declares depth {entry.depth}; "
                    f"its reference at {reference_at} requires depth {expected_depth}",
                    code="depth-mismatch",
                )
            state, head = _compose_delta(reference, content)
            _check_entry_against_record(entry, head)
            if int(head.level) != reference_level:
                raise MalformedFile(
                    f"delta at {entry.chunk_offset} declares level {head.level}; "
                    f"its reference at {reference_at} declares level {reference_level}",
                    code="index-record-mismatch",
                )
            level = int(head.level)
            current = (entry.chunk_offset, int(head.depth), level, state)

        if entry.extended and entry.live_count != state.count:
            raise MalformedFile(
                f"the chunk index entry at {entry.chunk_offset} declares live_count {entry.live_count}; "
                f"composition produces {state.count} gaussians",
                code="index-record-mismatch",
            )
        check_window_indices_of(state, windows)
        _decode_index_bands(data, entry, on_band)
        yield entry, state


def scan_streamed(
    data: bytes,
    on_record: Callable[[int, int], None] | None = None,
    on_state: Callable[[int, float, float], None] | None = None,
    *,
    sh_degree: int | None = None,
):
    """Every state a front-to-back reader composes, one at a time, keeping none.

    `decode_streamed` keeps a state per chunk and a map of every offset a delta could
    reference, which is right for a caller that wants the states and wrong for one that
    only wants to know whether the file decodes: on a sequence with a thousand chunks it
    holds a thousand populations. This yields each composed state and retains exactly two
    — the head of the current group of pictures, which a keyframe-referenced delta points
    at, and the previous chunk, which a chained delta points at. Those are the only two
    references §5.18 defines, so a reference to anything else is a fault named here rather
    than a third state kept in case.

    Yields `(offset, kind, state)`. The caller is expected to drop each state before
    asking for the next; nothing here holds on to it.
    """
    check_magic(data)
    keyframe_at: int | None = None
    keyframe_state_: State | None = None
    previous_at: int | None = None
    previous_state: State | None = None
    previous_depth: int | None = None
    declared_degree = sh_degree
    band_owner: int | None = None
    band_rows = 0
    bands: list[int] = []

    def finish_bands() -> None:
        nonlocal band_owner, band_rows, bands
        if band_owner is None:
            return
        if declared_degree is not None:
            wanted = list(range(1, declared_degree + 1))
            if bands != wanted:
                raise MalformedFile(
                    f"the state chunk at {band_owner} is followed by SH bands {bands}; "
                    f"the Header declares degree {declared_degree}, requiring bands {wanted}",
                    code="index-record-mismatch",
                )
        band_owner = None
        band_rows = 0
        bands = []

    for record in iter_records(data, len(MAGIC)):
        if record.opcode != op.SH_BAND_STREAM:
            finish_bands()
        if record.opcode == op.HEADER and sh_degree is None:
            declared_degree = rec.Header.parse(record.content).sh_degree
            continue
        if record.opcode == op.CHUNK:
            if on_record is not None:
                on_record(record.offset, record.opcode)
            head = rec.parse_chunk(record.content)[0]
            ids, bins = _keyframe_from_chunk(record.content)
            state = keyframe_state(ids, bins)
            keyframe_at, keyframe_state_ = record.offset, state
            depth = 0
            t0, t1 = head.t0, head.t1
            band_owner = record.offset
            band_rows = int(head.count)
        elif record.opcode == op.DELTA_CHUNK:
            if on_record is not None:
                on_record(record.offset, record.opcode)
            head_peek = rec.parse_delta_chunk_block(record.content)[0]
            if head_peek.reference_offset >= record.offset:
                raise MalformedFile(
                    f"delta chunk at {record.offset} references {head_peek.reference_offset}, which is not behind it",
                    code="forward-reference",
                )
            if head_peek.delta_mode == rec.DELTA_MODE_KEYFRAME:
                reference = keyframe_state_ if head_peek.reference_offset == keyframe_at else None
                reference_depth = 0 if reference is not None else None
            elif head_peek.delta_mode == rec.DELTA_MODE_CHAINED:
                reference = previous_state if head_peek.reference_offset == previous_at else None
                reference_depth = previous_depth if reference is not None else None
            else:
                raise MalformedFile(
                    f"delta chunk at {record.offset} declares delta_mode {head_peek.delta_mode}; "
                    "expected 0 (keyframe) or 1 (chained)",
                    code="index-record-mismatch",
                )
            if reference is None or reference_depth is None:
                expected = keyframe_at if head_peek.delta_mode == rec.DELTA_MODE_KEYFRAME else previous_at
                raise MalformedFile(
                    f"delta chunk at {record.offset} uses mode {head_peek.delta_mode} and references "
                    f"{head_peek.reference_offset}; that mode requires {expected}",
                    code="broken-reference",
                )
            expected_depth = reference_depth + 1
            if head_peek.depth != expected_depth:
                raise MalformedFile(
                    f"delta chunk at {record.offset} declares depth {head_peek.depth}; "
                    f"its selected reference requires depth {expected_depth}",
                    code="depth-mismatch",
                )
            state, head = _compose_delta(reference, record.content)
            depth = int(head.depth)
            t0, t1 = head.t0, head.t1
            band_owner = record.offset
            band_rows = int(head.birth_count)
            # Dropped here rather than left bound in this frame: a generator is suspended
            # at its yield for as long as the caller holds what it yielded, so a name
            # still bound is a population still resident — and this one is the state
            # before last, which nothing else needs once the composition is done.
            reference = None
        elif record.opcode == op.SH_BAND_STREAM:
            if on_record is not None:
                on_record(record.offset, record.opcode)
            if band_owner is None:
                raise MalformedFile(
                    f"SH Band Stream at byte {record.offset} does not immediately follow a state chunk",
                    code="index-record-mismatch",
                )
            band = Cursor(record.content)
            band_number = band.u8()
            attribute, values = decode_stream(band)
            if attribute != op.SH_BAND_STREAM:
                raise MalformedFile(
                    f"the SH Band Stream at {record.offset} declares inner attribute_id "
                    f"{attribute}; version 1 fixes it at {op.SH_BAND_STREAM}",
                    code="index-record-mismatch",
                )
            expected_shape = (band_rows, 3 * (2 * band_number + 1))
            if values.shape != expected_shape:
                raise MalformedFile(
                    f"the SH Band Stream at {record.offset} for band {band_number} decodes to "
                    f"shape {values.shape}; its owning state record requires {expected_shape}",
                    code="stream-element-count-mismatch",
                )
            bands.append(band_number)
            continue
        else:
            continue
        previous_at, previous_state, previous_depth = record.offset, state, depth
        if on_state is not None:
            on_state(record.offset, t0, t1)
        yield record.offset, (0 if record.opcode == op.CHUNK else 1), state

    finish_bands()


class _IdentityPartitionFull(Exception):
    """Internal signal to split one fixed-capacity identity pass."""


class BoundedIdentityAudit:
    """One-pass identity audit until a fixed history partition reaches capacity."""

    def __init__(self, capacity: int = 65_536) -> None:
        if capacity < 1:
            raise ValueError("identity partition capacity must be positive")
        self.capacity = capacity
        self._seen: set[int] = set()
        self._previous_live: set[int] = set()
        self.overflowed = False

    @property
    def distinct(self) -> int:
        if self.overflowed:
            raise RuntimeError("an overflowed identity audit has no exact distinct count")
        return len(self._seen)

    def observe(self, offset: int, state: State) -> None:
        """Consume one timeline state; retain no decoded arrays from it."""
        if self.overflowed:
            return
        current_live: set[int] = set()
        for raw in state.ids:
            identity = int(raw)
            if identity < 0 or identity > 0xFFFF_FFFF:
                raise MalformedFile(
                    f"state chunk at {offset} carries gaussian_id {identity}; ids are u32 values",
                    code="gaussian-id-out-of-range",
                )
            current_live.add(identity)
            if identity in self._previous_live:
                continue
            if identity in self._seen:
                raise MalformedFile(
                    f"state chunk at {offset} reintroduces gaussian id {identity} after it died; "
                    "gaussian_id values are never reused",
                    code="gaussian-id-reused",
                )
            if len(self._seen) >= self.capacity:
                self.overflowed = True
                self._seen.clear()
                self._previous_live.clear()
                return
            self._seen.add(identity)
        self._previous_live = current_live


def count_distinct_ids_bounded(
    data: bytes,
    *,
    capacity: int = 65_536,
    on_record: Callable[[int, int], None] | None = None,
) -> int:
    """Count identities and reject reuse without retaining whole-history identity state.

    A single set of every id ever observed grows with cumulative births, even though the
    decoder itself needs only the current state. This audits a fixed-size numeric
    partition at a time. If a partition contains more than ``capacity`` distinct ids it
    is split by the next high bit and the file is streamed again for each half. The only
    retained keys are one partition's bounded history and the previous live population;
    the result is an integer sum, never a scene-wide identity map.
    """
    if capacity < 1:
        raise ValueError("identity partition capacity must be positive")

    def audit(prefix: int, bits: int) -> int:
        seen: set[int] = set()
        previous_live: set[int] = set()
        shift = 32 - bits

        def belongs(value: int) -> bool:
            return bits == 0 or value >> shift == prefix

        for offset, _kind, state in scan_streamed(data, on_record=on_record):
            current_live: set[int] = set()
            for raw in state.ids:
                identity = int(raw)
                if identity < 0 or identity > 0xFFFF_FFFF:
                    raise MalformedFile(
                        f"state chunk at {offset} carries gaussian_id {identity}; ids are u32 values",
                        code="gaussian-id-out-of-range",
                    )
                if not belongs(identity):
                    continue
                current_live.add(identity)
                if identity in previous_live:
                    continue
                if identity in seen:
                    raise MalformedFile(
                        f"state chunk at {offset} reintroduces gaussian id {identity} after it died; "
                        "gaussian_id values are never reused",
                        code="gaussian-id-reused",
                    )
                if len(seen) >= capacity:
                    raise _IdentityPartitionFull
                seen.add(identity)
            previous_live = current_live
            del state
        return len(seen)

    def split(prefix: int, bits: int) -> int:
        try:
            return audit(prefix, bits)
        except _IdentityPartitionFull:
            if bits == 32:
                raise AssertionError("one u32 identity exceeded a positive partition capacity") from None
            return split(prefix << 1, bits + 1) + split((prefix << 1) | 1, bits + 1)

    return split(0, 0)


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
