# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Import the chunk-compressed PLY that gaussian-splat tools exchange, including its
temporal extension.

`convert.py` imports a *directory of per-frame uncompressed PLYs*, which is the
interchange form most people have. This module imports the other one: the chunked,
quantized `.ply` that splat editors export by default, where per-chunk float bounds are
carried once for every 256 gaussians and each gaussian is a handful of packed `uint32`.

Two layouts exist, and this module reads both:

* **Static.** An 18-float chunk element (position, scale and colour bounds) and a
  4-uint vertex element (`packed_position`, `packed_rotation`, `packed_scale`,
  `packed_color`). Some writers omit the colour bounds, giving a 12-float chunk.
* **Temporal.** The same, extended with per-chunk motion, time-scale and time bounds
  (28 floats) and two more vertex words, `packed_motion` and `packed_time`. This is the
  layout worth having here: it carries per-gaussian velocity and a temporal centre and
  extent, which is exactly the state this format stores natively.

A temporal capture is also commonly *segmented* — split across several files that share
one timeline, each stored on a clock relative to its own start, with a sidecar naming
the parts and the seconds each covers. `import_scene` collapses such a set into one
continuous `GaussianSet`, which is the point: the sidecar and its parts become a single
seekable file.

Dequantization
--------------
Four vertex words share one 11-10-11 field split — position, scale, motion and time —
so they all go through `_hi11` / `_mid10` / `_lo11` rather than re-deriving the shifts
per call site. A divergent hand-rolled split is precisely how a decode bug hides here:
the low 11 bits of the time word are identically zero in real captures, so a wrong
16/16 reading still produces plausible-looking values, and the temporal *extent* stays
near-correct under it while the temporal *centre* is quietly destroyed. Validate this
field with the centre, never with the extent.

* position, motion: 11-10-11 unorm, lerped between the chunk's min/max.
* scale: the same, but in LOG space — exponentiate after the lerp.
* rotation: a 2-bit largest-component index and three 10-bit unorm magnitudes
  (`smallest three`), the largest recovered as `sqrt(1 - sum)`.
* colour: 8-8-8-8 unorm. RGB lerps between the chunk's bounds and is ALREADY linear
  RGB; alpha is already post-sigmoid. Applying the SH DC transform again is wrong.
* time: the hi 11 bits are the temporal extent in LOG space, the mid 10 the temporal
  centre. The low 11 are a cutoff that writers emit and decoders discard.
* spherical harmonics: one `uchar` per coefficient over [-4, 4], decoded as bucket
  midpoints with 0 and 255 kept as exact endpoints.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import numpy as np

from .exceptions import MalformedFile
from .model import GaussianSet

CHUNK_SIZE = 256
_QUAT_NORM = np.sqrt(0.5)

# One uchar per SH coefficient, spanning this range.
_SH_RANGE = 8.0
_SH_OFFSET = -4.0

# Only these three per-vertex field counts are canonical (bands 1, 1-2, 1-3, across
# three colour channels). Any other count is treated as "no usable SH" rather than
# guessing a channel stride.
_SH_DEGREE_BY_FIELDS = {9: 1, 24: 2, 45: 3}

_STATIC_CHUNK_FLOATS = (12, 18)
_TEMPORAL_CHUNK_FLOATS = 28
_STATIC_VERTEX_UINTS = 4
_TEMPORAL_VERTEX_UINTS = 6

# 4DV's temporal shader treats these as semantic sentinels, not ordinary
# negative timestamps. The container has explicit representations for both
# behaviours, so normalize them while importing:
#   mu <= -5  — fixed position (no advection), but still temporally faded
#   mu <= -10 — fixed position and always visible inside the segment window
_STATIC_MU_SENTINEL = -5.0
_ALWAYS_VISIBLE_MU_SENTINEL = -10.0

# A crafted header must not force a multi-GB allocation before it can be checked, which
# is why the header is read and validated from a bounded probe before the body is sized.
_MAX_GAUSSIANS = 50_000_000
_HEADER_PROBE_BYTES = 1 << 16
_MAX_HEADER_BYTES = 1 << 20


def _hi11(p: np.ndarray) -> np.ndarray:
    """Bits 31..21 as a unorm in [0, 1]."""
    return ((p >> 21) & 0x7FF).astype(np.float64) / 2047.0


def _mid10(p: np.ndarray) -> np.ndarray:
    """Bits 20..11 as a unorm in [0, 1]."""
    return ((p >> 11) & 0x3FF).astype(np.float64) / 1023.0


def _lo11(p: np.ndarray) -> np.ndarray:
    """Bits 10..0 as a unorm in [0, 1]."""
    return (p & 0x7FF).astype(np.float64) / 2047.0


@dataclass(frozen=True)
class _Header:
    data_start: int
    chunks: int
    vertices: int
    sh_fields: int
    chunk_floats: int
    vertex_uints: int

    @property
    def temporal(self) -> bool:
        return self.vertex_uints == _TEMPORAL_VERTEX_UINTS and self.chunk_floats == _TEMPORAL_CHUNK_FLOATS

    @property
    def has_color_bounds(self) -> bool:
        return self.chunk_floats >= 18


def is_compressed_ply(data: bytes) -> bool:
    """Whether `data` begins a compressed PLY, from the header alone.

    Reads at most the first 4 KiB, so this never scans a multi-hundred-megabyte body.
    """
    head = data[:4096]
    end = head.find(b"end_header")
    scope = head[:end] if end >= 0 else head
    return b"element chunk" in scope and b"packed_position" in scope


def _parse_header(data: bytes) -> _Header:
    marker = data.find(b"end_header")
    if marker < 0:
        raise MalformedFile("compressed PLY: missing end_header")
    data_start = data.index(b"\n", marker) + 1
    text = data[:marker].decode("ascii", errors="replace")

    chunks = vertices = sh_fields = 0
    chunk_floats = vertex_uints = 0
    element = ""
    for raw in text.split("\n"):
        line = raw.strip()
        if line.startswith("element "):
            # An untrusted header must not reach here as a bare ValueError or IndexError:
            # the caller needs the offending declaration, not a stack trace.
            parts = line.split()
            if len(parts) < 3:
                raise MalformedFile(
                    f"compressed PLY: malformed element declaration {line!r} (want 'element <name> <count>')"
                )
            element = parts[1]
            try:
                count = int(parts[2])
            except ValueError:
                raise MalformedFile(
                    f"compressed PLY: element {element!r} declares a non-integer count {parts[2]!r}"
                ) from None
            if count < 0:
                raise MalformedFile(f"compressed PLY: element {element!r} declares a negative count {count}")
            if element == "chunk":
                chunks = count
            elif element == "vertex":
                vertices = count
        elif line.startswith("property "):
            if element == "chunk":
                chunk_floats += 1
            elif element == "vertex":
                vertex_uints += 1
            elif element == "sh":
                sh_fields += 1

    if vertices <= 0:
        raise MalformedFile("compressed PLY: no vertices")
    if vertices > _MAX_GAUSSIANS:
        raise MalformedFile(f"compressed PLY: {vertices} gaussians exceeds the {_MAX_GAUSSIANS} cap")
    if chunk_floats not in (*_STATIC_CHUNK_FLOATS, _TEMPORAL_CHUNK_FLOATS):
        raise MalformedFile(f"compressed PLY: unexpected chunk stride {chunk_floats} (expected 12, 18 or 28)")
    if vertex_uints not in (_STATIC_VERTEX_UINTS, _TEMPORAL_VERTEX_UINTS):
        raise MalformedFile(f"compressed PLY: unexpected vertex stride {vertex_uints} (expected 4 or 6)")
    expected = (vertices + CHUNK_SIZE - 1) // CHUNK_SIZE
    if chunks != expected:
        raise MalformedFile(f"compressed PLY: {chunks} chunks declared, expected {expected} for {vertices} gaussians")

    return _Header(data_start, chunks, vertices, sh_fields, chunk_floats, vertex_uints)


def _decode_rotation(packed: np.ndarray, *, wxyz: bool) -> np.ndarray:
    """Smallest-three quaternion -> (n, 4) xyzw.

    `wxyz` selects what the 2-bit tag indexes. Writers that emit the temporal extension
    index the largest component in WXYZ order; the static layout indexes it in XYZW and
    fills the remaining slots in ascending order. The two disagree only in which
    component is reconstructed, but that is enough to tumble every gaussian.
    """
    largest = ((packed >> 30) & 0x3).astype(np.int64)
    v0 = (((packed >> 20) & 0x3FF).astype(np.float64) / 1023.0 - 0.5) / _QUAT_NORM
    v1 = (((packed >> 10) & 0x3FF).astype(np.float64) / 1023.0 - 0.5) / _QUAT_NORM
    v2 = ((packed & 0x3FF).astype(np.float64) / 1023.0 - 0.5) / _QUAT_NORM
    m = np.sqrt(np.maximum(1.0 - (v0 * v0 + v1 * v1 + v2 * v2), 0.0))

    q = np.empty((packed.shape[0], 4), dtype=np.float64)
    if wxyz:
        placements = {
            0: (v0, v1, v2, m),  # w largest
            1: (m, v1, v2, v0),  # x largest
            2: (v1, m, v2, v0),  # y largest
            3: (v1, v2, m, v0),  # z largest
        }
        for tag, cols in placements.items():
            sel = largest == tag
            if sel.any():
                q[sel] = np.stack([c[sel] for c in cols], axis=1)
    else:
        order = {0: (1, 2, 3), 1: (0, 2, 3), 2: (0, 1, 3), 3: (0, 1, 2)}
        for tag, idx in order.items():
            sel = largest == tag
            if not sel.any():
                continue
            q[np.ix_(sel, np.array(idx))] = np.stack([v0[sel], v1[sel], v2[sel]], axis=1)
            q[sel, tag] = m[sel]

    return q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-30)


def decode_sh_byte(b: np.ndarray) -> np.ndarray:
    """The coefficient a compressed PLY's SH byte denotes.

    Interior bytes are bucket *midpoints*, `(b + 0.5) / 256`, with 0 and 255 kept as
    exact endpoints. Section 6.5 of the specification instead pins a stored byte to
    `LO + b * (HI - LO) / 255`.

    The two therefore disagree — but only by at most half a bucket (0.0155 on a 0.0314
    grid), and re-quantizing this decode back onto the specification's grid returns the
    *same byte for all 256 inputs*. So the bytes are carried across verbatim rather than
    round-tripped through floats, and `test_compressed_ply.py` pins that identity so a
    future change to either convention fails loudly instead of shifting colour quietly.

    Exposed because it is the only statement of what those bytes mean on the way in.
    """
    norm = (b.astype(np.float64) + 0.5) / 256.0
    norm = np.where(b == 0, 0.0, norm)
    norm = np.where(b == 255, 1.0, norm)
    return norm * _SH_RANGE + _SH_OFFSET


def _body_bytes(h: _Header) -> int:
    return h.data_start + h.chunks * h.chunk_floats * 4 + h.vertices * h.vertex_uints * 4 + h.vertices * h.sh_fields


def _load(source: str | bytes) -> tuple[_Header, bytes]:
    """Read a compressed PLY's header, then exactly the body that header declares.

    The header is parsed from a bounded probe first, so the gaussian cap is enforced
    *before* anything sizes an allocation from it — "every allocation sized from a value
    the reader has already validated". Reading exactly `_body_bytes` also means trailing
    data past the declared body is never pulled into memory.

    Accepts bytes as well as a path so callers holding the file already — a cache, a
    pipe they have drained, a range transport — do not have to spill it to disk first.
    """
    if isinstance(source, (bytes, bytearray, memoryview)):
        raw = bytes(source)
        h = _parse_header(raw)
        if len(raw) < _body_bytes(h):
            raise MalformedFile(f"compressed PLY truncated: need {_body_bytes(h)} bytes and have {len(raw)}")
        return h, raw

    with open(source, "rb") as fh:
        probe = fh.read(_HEADER_PROBE_BYTES)
        while b"end_header" not in probe:
            more = fh.read(_HEADER_PROBE_BYTES)
            if not more:
                raise MalformedFile(f"{source}: not a PLY (no end_header)")
            probe += more
            if len(probe) > _MAX_HEADER_BYTES:
                raise MalformedFile(f"{source}: no end_header in the first {_MAX_HEADER_BYTES} bytes")
        h = _parse_header(probe)  # the cap is enforced here, before the body is sized
        needed = _body_bytes(h)
        fh.seek(0)
        raw = fh.read(needed)
    if len(raw) < needed:
        raise MalformedFile(f"{source}: truncated, need {needed} bytes and have {len(raw)}")
    return h, raw


def read_compressed_ply(source: str | bytes) -> dict:
    """Unpack one compressed PLY into raw arrays, on whatever clock the file carries.

    `source` is a path or the bytes themselves.

    Returned as a mapping rather than a `GaussianSet` because a segment is not yet a
    scene: it has no validity window until its place on the shared timeline is known.
    """
    h, raw = _load(source)
    n = h.vertices
    chunk_bytes = h.chunks * h.chunk_floats * 4
    vertex_bytes = n * h.vertex_uints * 4

    chunks = np.frombuffer(raw, dtype="<f4", count=h.chunks * h.chunk_floats, offset=h.data_start)
    chunks = chunks.reshape(h.chunks, h.chunk_floats).astype(np.float64)
    verts = np.frombuffer(raw, dtype="<u4", count=n * h.vertex_uints, offset=h.data_start + chunk_bytes)
    verts = verts.reshape(n, h.vertex_uints)

    # Per-gaussian chunk bounds, gathered once so every field below is a plain lerp.
    bounds = chunks[np.arange(n) // CHUNK_SIZE]

    def lerp(u: np.ndarray, lo: int, hi: int) -> np.ndarray:
        base = bounds[:, lo]
        return base + u * (bounds[:, hi] - base)

    p_pos, p_rot, p_scale, p_color = (verts[:, k] for k in range(4))

    positions = np.stack([lerp(_hi11(p_pos), 0, 3), lerp(_mid10(p_pos), 1, 4), lerp(_lo11(p_pos), 2, 5)], axis=1)
    scales = np.exp(
        np.stack([lerp(_hi11(p_scale), 6, 9), lerp(_mid10(p_scale), 7, 10), lerp(_lo11(p_scale), 8, 11)], axis=1)
    )
    rotations = _decode_rotation(p_rot, wxyz=h.temporal)

    channels = [((p_color >> shift) & 0xFF).astype(np.float64) / 255.0 for shift in (24, 16, 8)]
    alpha = (p_color & 0xFF).astype(np.float64) / 255.0
    if h.has_color_bounds:
        rgb = [np.clip(lerp(c, 12 + i, 15 + i), 0.0, 1.0) for i, c in enumerate(channels)]
    else:
        rgb = [np.clip(c, 0.0, 1.0) for c in channels]
    colors = np.stack([*rgb, alpha], axis=1)

    if h.temporal:
        p_motion, p_time = verts[:, 4], verts[:, 5]
        motions = np.stack(
            [lerp(_hi11(p_motion), 18, 21), lerp(_mid10(p_motion), 19, 22), lerp(_lo11(p_motion), 20, 23)], axis=1
        )
        mu_t = lerp(_mid10(p_time), 26, 27)
        sigma_t = np.exp(lerp(_hi11(p_time), 24, 25))
    else:
        motions = np.zeros_like(positions)
        mu_t = np.zeros(n)
        sigma_t = np.full(n, np.inf)  # a static asset never fades

    sh = None
    sh_degree = 0
    if h.sh_fields in _SH_DEGREE_BY_FIELDS:
        sh_degree = _SH_DEGREE_BY_FIELDS[h.sh_fields]
        offset = h.data_start + chunk_bytes + vertex_bytes
        # Carried across verbatim — see decode_sh_byte for why that is exact.
        sh = np.frombuffer(raw, dtype=np.uint8, count=n * h.sh_fields, offset=offset).reshape(n, h.sh_fields).copy()

    return {
        "positions": positions,
        "scales": scales,
        "rotations": rotations,
        "colors": colors,
        "motions": motions,
        "mu_t": mu_t,
        "sigma_t": sigma_t,
        "sh": sh,
        "sh_degree": sh_degree,
        "temporal": h.temporal,
    }


def import_scene(paths: list[str], *, segment_duration: float | None = None) -> tuple[GaussianSet, float]:
    """Collapse one or more compressed PLYs into a single continuous scene.

    A single file is imported as-is. Several are treated as segments of one timeline in
    the order given: segment `k` covers `[k * segment_duration, (k + 1) * segment_duration)`
    and is stored on a clock relative to its own start, so its scene time is
    `local + k * segment_duration`.

    Every gaussian from each segment is retained. A temporal gaussian can contribute
    inside the segment even when its centre lies outside it, because visibility depends
    on the gaussian's temporal extent rather than the centre alone. The segment's span
    becomes the validity window, which reproduces the source player's "only the active
    segment is loaded" rule without deleting temporal support or persistent background.
    """
    if not paths:
        raise ValueError("import_scene needs at least one file")
    segmented = len(paths) > 1
    if segmented:
        if segment_duration is None:
            raise ValueError("segment_duration is required to place multiple segments on a shared timeline")
        span_sec = float(segment_duration)
        if not np.isfinite(span_sec) or span_sec <= 0.0:
            raise ValueError("segment_duration must be finite and strictly positive")
    else:
        span_sec = 0.0

    parts: list[dict] = []
    sh_degrees: set[int] = set()

    for k, path in enumerate(paths):
        seg = read_compressed_ply(path)
        local_mu = seg["mu_t"]

        # These bands are shader semantics in the source format. Carrying their
        # negative centres through as ordinary timestamps would advect or fade
        # background splats that the source viewer keeps fixed.
        static = local_mu <= _STATIC_MU_SENTINEL
        always = local_mu <= _ALWAYS_VISIBLE_MU_SENTINEL
        if np.any(static):
            seg["motions"] = seg["motions"].copy()
            seg["motions"][static] = 0.0
        if np.any(always):
            seg["sigma_t"] = seg["sigma_t"].copy()
            seg["sigma_t"][always] = np.inf

        if not segmented:
            # One file: its own clock IS the timeline. A static file has no timeline at
            # all, and its gaussians simply never fade.
            mu = local_mu
            lo = 0.0
            hi = float(np.max(mu)) if seg["temporal"] and mu.size else 0.0
        else:
            lo = k * span_sec
            hi = lo + span_sec
            mu = local_mu + lo
            seg["mu_t"] = mu

        if seg["sh"] is not None:
            sh_degrees.add(seg["sh_degree"])
        seg["win_lo"] = np.full(mu.shape[0], lo)
        seg["win_hi"] = np.full(mu.shape[0], hi if hi > lo else np.inf)
        parts.append(seg)

    # SH survives only if every segment agrees on a degree; concatenating mixed degrees
    # would silently mis-stride every coefficient row after the first disagreement.
    sh = None
    sh_degree = 0
    if len(sh_degrees) == 1 and all(p["sh"] is not None for p in parts):
        sh_degree = sh_degrees.pop()
        sh = np.concatenate([p["sh"] for p in parts])

    def joined(key: str) -> np.ndarray:
        return np.concatenate([p[key] for p in parts]).astype(np.float32)

    duration = len(paths) * span_sec if segmented else float(np.max(joined("mu_t")))
    gaussians = GaussianSet(
        positions=joined("positions"),
        scales=joined("scales"),
        rotations=joined("rotations"),
        colors=joined("colors"),
        motions=joined("motions"),
        mu_t=joined("mu_t"),
        sigma_t=joined("sigma_t"),
        win_lo=joined("win_lo"),
        win_hi=joined("win_hi"),
        sh=sh,
        sh_degree=sh_degree,
    )
    return gaussians, duration


def sorted_segments(directory: str) -> list[str]:
    """Segment files in a directory, ordered by the number in their name."""
    names = [n for n in os.listdir(directory) if n.lower().endswith(".ply")]
    if not names:
        raise MalformedFile(f"{directory}: no .ply files")

    def key(name: str):
        digits = "".join(c for c in name if c.isdigit())
        return (int(digits) if digits else 0, name)

    return [os.path.join(directory, n) for n in sorted(names, key=key)]
