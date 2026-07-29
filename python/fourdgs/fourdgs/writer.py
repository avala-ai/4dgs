# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The reference encoder.

Optimized for being obviously correct, not for output size or speed. It quantizes onto
the declared grids, partitions gaussians by their temporal support, writes independent
chunks and an index, and — before it writes the bounds it is about to claim — decodes
what it produced and checks them.

That last step is the point. A bound nobody verified is worse than no bound, because
consumers will trust it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import BoundViolation, InvalidInput
from .model import AudioTrack, CameraTrajectory, GaussianSet, window_table
from .provenance import Provenance
from .quantization import (
    DEFAULT_CUTOFF,
    SH_LADDERS,
    SH_MAX_BITS,
    SH_MIN_BITS,
    Bounds,
    Steps,
    dequantize,
    dequantize_rotation,
    life_class,
    morton_order,
    motion_steps,
    mu_steps,
    quantize,
    quantize_rotation,
    quantize_sh,
    rct_forward,
    rct_inverse,
    sh_bound,
    sh_step,
    support_k,
)
from .serialization import CODEC_DEFLATE, MAGIC, crc32, encode_stream, put_record, put_u8

SH_BAND_COEFFS = {1: (0, 3), 2: (3, 8), 3: (8, 15)}


@dataclass
class WriteOptions:
    profile: str = "default"
    #: The Header's marginal visibility threshold. It is not only metadata: it sets the
    #: support constant the per-gaussian velocity grid is derived from, so encoder and
    #: decoder must agree on it, and they do by reading it from the file.
    cutoff: float = DEFAULT_CUTOFF
    codec: int = CODEC_DEFLATE
    level: int = 6
    #: Depth of the temporal partition below each window. 0 writes one chunk per window.
    max_depth: int = 6
    min_chunk_gaussians: int = 2048
    write_index: bool = True
    write_statistics: bool = False
    write_summary_offsets: bool = False
    write_crc: bool = True
    preserve_source_ids: bool = False
    sh_bands: int = 3
    #: Per-band spherical harmonic bit depths, band 1 first, or a ladder name from
    #: `SH_LADDERS`. `None` leaves the coefficients as the profile alone decides, which is
    #: what every file written before this option existed did — the appended field is not
    #: emitted at all, so those files are byte-identical.
    sh_bit_depths: tuple[int, ...] | list[int] | str | None = None
    verify: bool = True
    library: str = "4dgs-python reference encoder"
    scene_profile: str = ""
    metadata: dict[str, str] | None = None
    #: Provenance records to emit (spec section 5.15). `None` writes none, which is
    #: the default and costs nothing — no record, no placeholder, no Header flag. A
    #: scene with no sensors behind it is a complete file, not an under-specified one.
    provenance: Provenance | None = None
    #: Bytes appended to the content of the record with the given opcode, as a newer
    #: writer that added a field would produce. A reader that honours content_length steps
    #: over them; one that assumes a record ends where its own knowledge does does not.
    record_trailers: dict[int, bytes] = field(default_factory=dict)
    #: Pre-encoded records emitted verbatim after the window table. Used to place
    #: unknown-opcode and private-range records in a file whose offsets are still
    #: correct — splicing them in afterwards would shift every offset the index holds,
    #: which produces a corrupt file rather than a forward-compatibility test.
    extra_records: tuple[bytes, ...] = ()
    #: The Header's `temporal_model`. Version 1 defines exactly one, and this exists so a
    #: conformance fixture can declare something else — a reader that does not enforce the
    #: registry's refusal rule cannot be caught by a corpus that only ever writes the one
    #: legal value. Producers have no reason to set it.
    temporal_model: str = "gaussian-birth"


def _sh_depths(requested, bands: list[int]) -> dict[int, int]:
    """Resolve the option into `{band: bit depth}` for the bands actually written.

    A ladder shorter than the file's degree is an error rather than a default: the depth
    of the highest band is the one that decides most of the size, and silently filling it
    in with eight bits would hand back a file that quietly ignored what was asked for.
    """
    if requested is None or not bands:
        return {}
    if isinstance(requested, str):
        if requested not in SH_LADDERS:
            raise ValueError(f"unknown SH bit-depth ladder {requested!r}; known ladders are {sorted(SH_LADDERS)}")
        requested = SH_LADDERS[requested]
    depths = [int(d) for d in requested]
    if len(depths) < len(bands):
        raise ValueError(f"sh_bit_depths declares {len(depths)} bands; this scene writes {len(bands)}")
    for d in depths[: len(bands)]:
        if not (SH_MIN_BITS <= d <= SH_MAX_BITS):
            raise ValueError(f"an SH bit depth must be {SH_MIN_BITS}..{SH_MAX_BITS}, got {d}")
    return {band: depths[i] for i, band in enumerate(bands)}


def _plan_chunks(lo, hi, tops, max_depth, min_gaussians):
    """Assign gaussians to nodes of a temporal interval tree.

    A gaussian goes in the deepest node whose interval fully contains its support, so it
    is stored exactly once however long it lives. The top level is the window table, which
    matters: a power-of-two tree over the whole timeline pushes gaussians that fill one
    window up to the root because they straddle its boundaries.
    """
    lo = np.asarray(lo, dtype=np.float64)
    hi = np.asarray(hi, dtype=np.float64)
    assigned = np.full(len(lo), -1, dtype=np.int64)
    nodes: list[tuple[float, float, int]] = []

    def recurse(a, b, level, pool):
        if pool.size == 0 or level >= max_depth:
            return pool
        mid = 0.5 * (a + b)
        in_left = hi[pool] <= mid
        in_right = lo[pool] >= mid
        stay = pool[~(in_left | in_right)]
        for (ca, cb), cpool in (((a, mid), pool[in_left]), ((mid, b), pool[in_right & ~in_left])):
            if cpool.size < min_gaussians:
                stay = np.concatenate([stay, cpool])
                continue
            kept = recurse(ca, cb, level + 1, cpool)
            if kept.size:
                nodes.append((ca, cb, level + 1))
                assigned[kept] = len(nodes) - 1
        return np.sort(stay)

    for i in range(len(tops) - 1):
        a, b = tops[i], tops[i + 1]
        pool = np.flatnonzero((lo >= a - 1e-9) & (hi <= b + 1e-9) & (assigned < 0))
        kept = recurse(a, b, 0, pool)
        if kept.size:
            nodes.append((a, b, 0))
            assigned[kept] = len(nodes) - 1

    rest = np.flatnonzero(assigned < 0)
    if rest.size:
        nodes.append((tops[0], tops[-1], -1))
        assigned[rest] = len(nodes) - 1

    order = np.argsort(assigned, kind="stable")
    sorted_assigned = assigned[order]
    plans = []
    for k, (a, b, level) in enumerate(nodes):
        start = np.searchsorted(sorted_assigned, k, side="left")
        end = np.searchsorted(sorted_assigned, k, side="right")
        members = order[start:end]
        if members.size:
            plans.append((float(a), float(b), max(level, 0), members))
    plans.sort(key=lambda p: (p[2], p[0]))
    return plans


def write(
    path_or_file,
    gaussians: GaussianSet,
    duration_sec: float,
    *,
    options: WriteOptions | None = None,
    audio: AudioTrack | None = None,
    camera: CameraTrajectory | None = None,
) -> int:
    """Write a scene. Returns the number of bytes written."""
    opts = options or WriteOptions()
    out = _encode(gaussians, duration_sec, opts, audio, camera)
    if hasattr(path_or_file, "write"):
        path_or_file.write(out)
    else:
        with open(path_or_file, "wb") as fh:
            fh.write(out)
    return len(out)


#: Per-gaussian arrays that are quantized onto a grid, so a non-finite value in one either
#: sets a non-finite grid parameter or rounds to a meaningless bin. `sigma_t`, `win_lo` and
#: `win_hi` are deliberately absent — see `_check_finite_input`.
_FINITE_FIELDS = ("positions", "scales", "rotations", "colors", "motions", "mu_t")


def _check_finite_input(g: GaussianSet) -> None:
    """Refuse a scene the encoder cannot write a conforming file from (spec §5.3).

    The position origin is the per-axis minimum of `positions`, and the steps are derived
    from the median scale, so a single non-finite value there propagates straight into the
    Quantization record — and §5.3 requires every step and origin to be finite. Refusing
    here rather than at the codec is the whole point: the codec's complaint is about a
    symbol width and names neither the field nor the gaussian, so the one thing the caller
    needs to know is the one thing it cannot say.

    Three fields are deliberately not on that list, because they are not quantized and an
    infinity in them is meaningful rather than broken:

    * `sigma_t` — `+inf` is its documented spelling for a gaussian that never fades (§3).
    * `win_lo` and `win_hi` — the validity window goes into the Window Table as `f64`
      verbatim (§5.4), touching no grid at all. `win_hi = +inf` is how a static asset says
      it is present at every instant, which is exactly what the glTF import writes.

    NaN is refused in all three. It is never a meaningful value in any of them, and it is
    the quiet kind of wrong: the decoder reads every non-finite sigma as never-fading, so a
    NaN there becomes a deliberate-looking value, and a NaN window makes every comparison
    false so the gaussian silently never appears.
    """
    if not g.count:
        return
    for name in _FINITE_FIELDS:
        values = np.asarray(getattr(g, name))
        bad = np.flatnonzero(~np.isfinite(values).reshape(len(values), -1).all(axis=1))
        if bad.size:
            raise InvalidInput(
                f"{name} is not finite at gaussian {int(bad[0])} "
                f"({bad.size} of {len(values)} affected); it is quantized onto a grid, and a "
                f"non-finite value there violates spec §5.3"
            )

    sigma = np.asarray(g.sigma_t, dtype=np.float64)
    bad = np.flatnonzero(np.isnan(sigma) | (sigma == -np.inf))
    if bad.size:
        raise InvalidInput(
            f"sigma_t is NaN or -inf at gaussian {int(bad[0])} ({bad.size} affected); "
            f"use +inf for a gaussian that never fades"
        )

    for name in ("win_lo", "win_hi"):
        values = np.asarray(getattr(g, name), dtype=np.float64)
        bad = np.flatnonzero(np.isnan(values))
        if bad.size:
            raise InvalidInput(
                f"{name} is NaN at gaussian {int(bad[0])} ({bad.size} affected); a NaN window "
                f"makes every visibility comparison false, so the gaussian silently never appears"
            )


def _encode(g: GaussianSet, duration_sec, opts, audio, camera) -> bytes:
    _check_finite_input(g)
    n = g.count
    median_scale = float(np.median(g.scales)) if n else 1e-3
    bounds = Bounds.for_profile(opts.profile, median_scale=median_scale)
    steps = Steps.of(bounds)

    origin = g.positions.min(axis=0).astype(np.float64) if n else np.zeros(3)

    q_pos = quantize(g.positions, steps.pos, origin)
    q_scale = quantize(np.log(np.maximum(g.scales.astype(np.float64), 1e-30)), steps.scale_log)
    rot_idx, q_rot = (
        quantize_rotation(g.rotations, steps.rot) if n else (np.zeros(0, np.int64), np.zeros((0, 3), np.int64))
    )
    q_rgb = rct_forward(quantize(g.colors[:, :3], steps.rgb)) if n else np.zeros((0, 3), np.int64)
    q_alpha = quantize(g.colors[:, 3], steps.alpha) if n else np.zeros(0, np.int64)

    never_fades = ~np.isfinite(g.sigma_t)
    safe_sigma = np.where(never_fades, 1.0, g.sigma_t.astype(np.float64))
    q_sigma = quantize(np.log(np.maximum(safe_sigma, 1e-30)), steps.sigma_log)
    q_sigma[never_fades] = 0
    flags = never_fades.astype(np.int64)

    win_len = (g.win_hi - g.win_lo).astype(np.float64)
    k = support_k(opts.cutoff)
    m_step = motion_steps(life_class(q_sigma, steps.sigma_log, never_fades, win_len, k), steps.motion)
    q_motion = (
        np.rint(g.motions.astype(np.float64) / m_step[:, None]).astype(np.int64) if n else np.zeros((0, 3), np.int64)
    )
    t_step = mu_steps(q_sigma, steps.sigma_log, never_fades, steps.time)
    q_mu = np.rint(g.mu_t.astype(np.float64) / t_step).astype(np.int64) if n else np.zeros(0, np.int64)

    table, win_index = window_table(g.win_lo, g.win_hi) if n else (np.zeros((1, 2)), np.zeros(0, np.int64))

    tops = sorted({0.0, duration_sec} | {float(v) for w in table for v in w if 0.0 < v < duration_sec})
    if len(tops) < 2:
        tops = [0.0, max(duration_sec, 1e-9)]
    lo, hi = g.support() if n else (np.zeros(0), np.zeros(0))
    plans = _plan_chunks(lo, hi, tops, opts.max_depth, opts.min_chunk_gaussians) if n else []
    if n and not plans:
        plans = [(tops[0], tops[-1], 0, np.arange(n))]

    sh_cols = {}
    if g.sh is not None and g.sh_degree > 0:
        coeffs = g.sh.shape[1] // 3
        for band in range(1, min(g.sh_degree, opts.sh_bands) + 1):
            first, last = SH_BAND_COEFFS[band]
            cols = [c * coeffs + k for c in range(3) for k in range(first, min(last, coeffs))]
            if cols:
                sh_cols[band] = np.array(cols, dtype=np.int64)

    depths = _sh_depths(opts.sh_bit_depths, sorted(sh_cols))
    if depths:
        # One pitch has to go in `step_sh`, which is a single byte and predates per-band
        # depths. The coarsest band's is the only honest answer: a consumer that reads it
        # and not the appended field then holds an upper bound rather than a number that
        # is true of some bands and wrong for others. `bounds.sh` is worst-case for the
        # same reason, with the per-band truth beside it.
        steps.sh = max(sh_step(d) for d in depths.values())
        bounds.sh = max(sh_bound(d) for d in depths.values())

    parts: list[bytes] = [MAGIC]
    cursor = len(MAGIC)

    def emit(blob: bytes) -> int:
        nonlocal cursor
        at = cursor
        parts.append(blob)
        cursor += len(blob)
        return at

    header_flags = rec.FLAG_HAS_AUDIO if audio is not None else 0
    emit(
        rec.Header(
            duration_sec=float(duration_sec),
            gaussian_count=n,
            aabb=g.aabb(),
            profile=opts.scene_profile,
            library=opts.library,
            temporal_model=opts.temporal_model,
            cutoff=opts.cutoff,
            sh_degree=g.sh_degree if sh_cols else 0,
            flags=header_flags,
            attributes=opts.metadata or {},
        ).encode(trailer=opts.record_trailers.get(op.HEADER, b""))
    )
    emit(
        rec.Quantization(
            scheme="uniform-v1",
            pos_origin=[float(v) for v in origin],
            step_pos=steps.pos,
            step_scale_log=steps.scale_log,
            step_rot=steps.rot,
            step_rgb=steps.rgb,
            step_alpha=steps.alpha,
            step_motion=steps.motion,
            step_time=steps.time,
            step_sigma_log=steps.sigma_log,
            step_sh=steps.sh,
            bounds=bounds.as_strings() | {f"sh_band{b}": str(sh_bound(d)) for b, d in depths.items()},
            sh_bit_depths=[depths[b] for b in sorted(depths)],
        ).encode(trailer=opts.record_trailers.get(op.QUANTIZATION, b""))
    )
    emit(rec.WindowTable(windows=[(float(a), float(b)) for a, b in table]).encode())
    for blob in opts.extra_records:
        emit(blob)

    # Absence is the signal: no audio means no record at all, not an empty one.
    if audio is not None:
        emit(rec.Audio(codec=audio.codec, data=audio.data, start_sec=audio.start_sec).encode())
    # Provenance, in ascending opcode order: the frame that the poses are expressed in,
    # then the sensors, then the trajectories. Nothing requires that order of a reader —
    # records are dispatched by opcode, not position — but a file written this way reads
    # in the order a human would explain it.
    if opts.provenance is not None:
        opts.provenance.check()
        for frame in opts.provenance.frames:
            frame.check()
            emit(frame.encode(trailer=opts.record_trailers.get(op.COORDINATE_FRAME, b"")))
        for sensor in opts.provenance.sensors:
            sensor.check()
            emit(sensor.encode(trailer=opts.record_trailers.get(op.SENSOR_CALIBRATION, b"")))
        for trajectory in opts.provenance.trajectories:
            trajectory.check()
            emit(trajectory.encode(trailer=opts.record_trailers.get(op.RIG_TRAJECTORY, b"")))
        for anchor in opts.provenance.anchors:
            anchor.check()
            emit(anchor.encode(trailer=opts.record_trailers.get(op.GEODETIC_ANCHOR, b"")))

    if camera is not None:
        emit(
            rec.Camera(
                fov_y_deg=camera.fov_y_deg,
                position=list(camera.position),
                target=list(camera.target),
                times=list(camera.times),
                positions=[list(p) for p in camera.positions],
                targets=[list(t) for t in camera.targets],
                interpolation=camera.interpolation,
                loop=camera.loop,
            ).encode()
        )

    index: list[rec.ChunkIndexEntry] = []
    worst: dict[str, float] = {}

    for t0, t1, level, plan_members in plans:
        # Morton order within the chunk is what makes the position delta small.
        members = plan_members[morton_order(g.positions[plan_members])]
        streams = b"".join(
            [
                encode_stream(op.A_POSITION, q_pos[members], channels=3, codec=opts.codec, level=opts.level),
                encode_stream(op.A_SCALE, q_scale[members], channels=3, codec=opts.codec, level=opts.level),
                encode_stream(op.A_ROTATION_INDEX, rot_idx[members], codec=opts.codec, level=opts.level),
                encode_stream(op.A_ROTATION, q_rot[members], channels=3, codec=opts.codec, level=opts.level),
                encode_stream(op.A_COLOR, q_rgb[members], channels=3, codec=opts.codec, level=opts.level),
                encode_stream(op.A_OPACITY, q_alpha[members], codec=opts.codec, level=opts.level),
                encode_stream(op.A_MOTION, q_motion[members], channels=3, codec=opts.codec, level=opts.level),
                encode_stream(op.A_MU_T, q_mu[members], codec=opts.codec, level=opts.level),
                encode_stream(op.A_SIGMA_T, q_sigma[members], codec=opts.codec, level=opts.level),
                encode_stream(op.A_FLAGS, flags[members], codec=opts.codec, level=opts.level),
                encode_stream(op.A_WINDOW_INDEX, win_index[members], codec=opts.codec, level=opts.level),
            ]
            + (
                [
                    encode_stream(op.A_SOURCE_GROUP, _ids(g.source_group, members), codec=opts.codec, level=opts.level),
                    encode_stream(op.A_SOURCE_INDEX, _ids(g.source_index, members), codec=opts.codec, level=opts.level),
                ]
                if opts.preserve_source_ids
                else []
            )
        )
        chunk_blob = rec.encode_chunk(t0, t1, level, int(members.size), streams)
        chunk_at = emit(chunk_blob)

        bands: list[tuple[int, int, int]] = []
        for band, cols in sh_cols.items():
            original = g.sh[np.ix_(members, cols)].astype(np.int64)
            if band in depths:
                vals = quantize_sh(original, depths[band])
            elif steps.sh > 1:
                vals = (original // steps.sh) * steps.sh + steps.sh // 2
            else:
                vals = original
            # Each band is its own record, so a reader that has capped its SH degree
            # skips the higher ones by byte range and never transfers them.
            payload = put_u8(band) + encode_stream(
                op.SH_BAND_STREAM, vals, channels=len(cols), codec=opts.codec, level=opts.level
            )
            band_blob = put_record(op.SH_BAND_STREAM, payload)
            band_at = emit(band_blob)
            bands.append((band, band_at, len(band_blob)))
            if opts.verify and band in depths:
                _verify_band(band_blob, original, sh_bound(depths[band]), band, worst)

        index.append(
            rec.ChunkIndexEntry(
                t0=t0,
                t1=t1,
                chunk_offset=chunk_at,
                chunk_length=len(chunk_blob),
                gaussian_count=int(members.size),
                bands=bands,
            )
        )

        if opts.verify:
            _verify_chunk(g, members, chunk_blob, steps, bounds, worst, origin, table, opts.cutoff)

    if opts.verify and worst:
        _assert_bounds(worst, bounds, depths)

    summary_start = 0
    summary_offset_start = 0
    summary_bytes = b""
    if opts.write_index and index:
        summary_start = cursor
        group_start = cursor
        for entry in index:
            emit(entry.encode())
        if opts.write_statistics:
            emit(
                rec.Statistics(
                    gaussian_count=n, chunk_count=len(index), duration_sec=float(duration_sec), aabb=g.aabb()
                ).encode()
            )
        if opts.write_summary_offsets:
            summary_offset_start = cursor
            emit(rec.SummaryOffset(op.CHUNK_INDEX, group_start, summary_start and cursor - group_start).encode())
        summary_bytes = b"".join(parts)[summary_start:]

    footer = rec.Footer(
        summary_start=summary_start,
        summary_offset_start=summary_offset_start,
        summary_crc=crc32(summary_bytes) if (opts.write_crc and summary_bytes) else 0,
    )
    emit(footer.encode())
    parts.append(MAGIC)
    return b"".join(parts)


def _ids(arr, members) -> np.ndarray:
    if arr is None:
        return np.asarray(members, dtype=np.int64)
    return np.asarray(arr, dtype=np.int64)[members]


def _verify_chunk(g, members, chunk_blob, steps, bounds, worst, origin, windows, cutoff) -> None:
    """Decode what was just encoded and record the worst deviation seen."""
    from .stream_reader import decode_chunk_blob

    decoded = decode_chunk_blob(chunk_blob, steps, np.asarray(origin, dtype=np.float64), windows, cutoff)

    def upd(key, value):
        worst[key] = max(worst.get(key, 0.0), float(value))

    upd("pos", np.abs(decoded["positions"] - g.positions[members]).max(initial=0.0))
    ref_scale = np.maximum(g.scales[members].astype(np.float64), 1e-30)
    upd("scale_rel", np.abs(np.log(np.maximum(decoded["scales"], 1e-30) / ref_scale)).max(initial=0.0))
    upd("rgb", np.abs(decoded["colors"][:, :3] - g.colors[members][:, :3]).max(initial=0.0))
    upd("alpha", np.abs(decoded["colors"][:, 3] - g.colors[members][:, 3]).max(initial=0.0))
    a = decoded["rotations"]
    b = g.rotations[members].astype(np.float64)
    b = b / np.maximum(np.linalg.norm(b, axis=1, keepdims=True), 1e-30)
    if len(a):
        upd("rot", np.minimum(np.abs(a - b).max(axis=1), np.abs(a + b).max(axis=1)).max())


def _verify_band(band_blob: bytes, original: np.ndarray, bound: int, band: int, worst: dict[str, float]) -> None:
    """Decode the band record just written and record the worst coefficient deviation.

    Decoded rather than computed: the arithmetic that produced these bytes is three lines
    and would agree with itself if it were wrong. What the file will hand a consumer is
    what came back out of the record, so that is what the declared bound is measured
    against — every coefficient of every gaussian, not a sample.
    """
    from .serialization import Cursor, decode_stream

    cursor = Cursor(band_blob)
    cursor.take(1)  # opcode
    cursor.take(8)  # content length
    content = Cursor(cursor.buf[cursor.pos :])
    content.u8()  # band
    _, values = decode_stream(content)
    deviation = np.abs(values.reshape(original.shape).astype(np.int64) - original).max(initial=0)
    key = f"sh_band{band}"
    worst[key] = max(worst.get(key, 0.0), float(deviation))
    if deviation > bound:
        raise BoundViolation(
            f"encoder verification failed: SH band {band} deviated {int(deviation)} code units, bound is {bound}"
        )


def _assert_bounds(worst: dict[str, float], bounds: Bounds, depths: dict[int, int] | None = None) -> None:
    limits = {
        "pos": bounds.pos,
        "scale_rel": np.log1p(bounds.scale_rel),
        "rgb": bounds.rgb,
        "alpha": bounds.alpha,
    }
    for band, bits in (depths or {}).items():
        limits[f"sh_band{band}"] = float(sh_bound(bits))
    for key, limit in limits.items():
        measured = worst.get(key, 0.0)
        if measured > limit + 1e-9:
            raise BoundViolation(f"encoder verification failed: {key} deviated {measured:.6g}, bound is {limit:.6g}")


__all__ = ["WriteOptions", "dequantize", "dequantize_rotation", "rct_inverse", "write"]
