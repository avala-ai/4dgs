# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Tests for the chunk-compressed PLY importer.

Fixtures are built here rather than committed: `build_ply` below packs known values
with the same bit layout the reader unpacks, so the repository keeps no binaries it can
reconstruct.

Packing the fixture with the reader's own helpers would make these tests tautological,
so the packing here is written out longhand from the layout — 11-10-11 unorm fields,
log-space scale, smallest-three rotation — and the assertions are on the *values that
went in*. That is the only way this suite can catch the failure this importer exists to
avoid: a field split that decodes to plausible numbers rather than correct ones.
"""

from __future__ import annotations

import math
import struct

import fourdgs
import numpy as np
import pytest
from fourdgs.compressed_ply import CHUNK_SIZE, import_scene, is_compressed_ply, read_compressed_ply
from fourdgs.quantization import SH_QUANT_HI, SH_QUANT_LO

_STATIC_PROPS = ["packed_position", "packed_rotation", "packed_scale", "packed_color"]
_TEMPORAL_PROPS = _STATIC_PROPS + ["packed_motion", "packed_time"]

_CHUNK_FIELDS_18 = [
    "min_x", "min_y", "min_z", "max_x", "max_y", "max_z",
    "min_scale_x", "min_scale_y", "min_scale_z", "max_scale_x", "max_scale_y", "max_scale_z",
    "min_r", "min_g", "min_b", "max_r", "max_g", "max_b",
]  # fmt: skip
_CHUNK_FIELDS_28 = _CHUNK_FIELDS_18 + [
    "min_motion_x", "min_motion_y", "min_motion_z", "max_motion_x", "max_motion_y", "max_motion_z",
    "min_time_scale", "max_time_scale", "min_time", "max_time",
]  # fmt: skip


def pack_11_10_11(a: float, b: float, c: float) -> int:
    """The field split shared by position, scale, motion and time. Inputs are unorms."""
    return (round(a * 2047) << 21) | (round(b * 1023) << 11) | round(c * 2047)


def build_ply(
    *,
    temporal: bool,
    count: int = 3,
    bounds: dict | None = None,
    vertices: list[dict] | None = None,
    sh_fields: int = 0,
) -> bytes:
    """Assemble one chunk's worth of a compressed PLY from explicit unorm fields."""
    b = bounds or {}
    chunk_fields = _CHUNK_FIELDS_28 if temporal else _CHUNK_FIELDS_18
    defaults = {f: (0.0 if f.startswith("min") else 1.0) for f in chunk_fields}
    defaults.update(b)

    props = _TEMPORAL_PROPS if temporal else _STATIC_PROPS
    header = "ply\nformat binary_little_endian 1.0\n"
    header += "element chunk 1\n" + "".join(f"property float {f}\n" for f in chunk_fields)
    header += f"element vertex {count}\n" + "".join(f"property uint {p}\n" for p in props)
    if sh_fields:
        header += f"element sh {count}\n" + "".join(f"property uchar f_rest_{i}\n" for i in range(sh_fields))
    header += "end_header\n"

    body = b"".join(struct.pack("<f", float(defaults[f])) for f in chunk_fields)
    for i in range(count):
        v = (vertices or [{}] * count)[i]
        for p in props:
            body += struct.pack("<I", int(v.get(p, 0)))
    if sh_fields:
        body += bytes((i * 7 + j) % 256 for i in range(count) for j in range(sh_fields))
    return header.encode("ascii") + body


def test_sniffs_compressed_ply():
    assert is_compressed_ply(build_ply(temporal=False))
    assert not is_compressed_ply(b"ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\n")


def test_position_and_scale_dequantize(tmp_path):
    # Position lerps between the chunk bounds; scale does the same in LOG space.
    bounds = {
        "min_x": -1.0, "max_x": 1.0, "min_y": -2.0, "max_y": 2.0, "min_z": 0.0, "max_z": 4.0,
        "min_scale_x": math.log(0.1), "max_scale_x": math.log(10.0),
        "min_scale_y": math.log(0.1), "max_scale_y": math.log(10.0),
        "min_scale_z": math.log(0.1), "max_scale_z": math.log(10.0),
    }  # fmt: skip
    verts = [
        {"packed_position": pack_11_10_11(0.0, 0.0, 0.0), "packed_scale": pack_11_10_11(0.0, 0.5, 1.0)},
        {"packed_position": pack_11_10_11(1.0, 1.0, 1.0), "packed_scale": pack_11_10_11(1.0, 0.5, 0.0)},
        {"packed_position": pack_11_10_11(0.5, 0.5, 0.5), "packed_scale": pack_11_10_11(0.5, 0.5, 0.5)},
    ]
    p = tmp_path / "s.ply"
    p.write_bytes(build_ply(temporal=False, count=3, bounds=bounds, vertices=verts))
    got = read_compressed_ply(str(p))

    np.testing.assert_allclose(got["positions"][0], [-1.0, -2.0, 0.0], atol=1e-4)
    np.testing.assert_allclose(got["positions"][1], [1.0, 2.0, 4.0], atol=1e-4)
    np.testing.assert_allclose(got["positions"][2], [0.0, 0.0, 2.0], atol=2e-3)
    # Log-space: the midpoint of log(0.1)..log(10) is exp(0) == 1, NOT 5.05.
    np.testing.assert_allclose(got["scales"][2], [1.0, 1.0, 1.0], atol=2e-2)
    np.testing.assert_allclose(got["scales"][0][0], 0.1, atol=1e-4)
    np.testing.assert_allclose(got["scales"][1][0], 10.0, atol=1e-3)


def test_color_is_already_linear_rgb(tmp_path):
    # RGB lerps between the chunk's bounds and is already linear RGB; alpha is already
    # post-sigmoid. Re-applying the SH DC transform here is the classic error.
    bounds = {"min_r": 0.0, "max_r": 1.0, "min_g": 0.0, "max_g": 0.5, "min_b": 0.25, "max_b": 0.25}
    verts = [{"packed_color": (255 << 24) | (255 << 16) | (128 << 8) | 64}]
    p = tmp_path / "c.ply"
    p.write_bytes(build_ply(temporal=False, count=1, bounds=bounds, vertices=verts))
    got = read_compressed_ply(str(p))
    np.testing.assert_allclose(got["colors"][0][0], 1.0, atol=1e-3)
    np.testing.assert_allclose(got["colors"][0][1], 0.5, atol=1e-3)
    np.testing.assert_allclose(got["colors"][0][2], 0.25, atol=1e-3)
    np.testing.assert_allclose(got["colors"][0][3], 64 / 255, atol=1e-3)


def test_rotation_is_unit(tmp_path):
    verts = [{"packed_rotation": (tag << 30) | (300 << 20) | (700 << 10) | 512} for tag in range(3)]
    p = tmp_path / "r.ply"
    p.write_bytes(build_ply(temporal=True, count=3, vertices=verts))
    got = read_compressed_ply(str(p))
    np.testing.assert_allclose(np.linalg.norm(got["rotations"], axis=1), 1.0, atol=1e-5)


def test_time_word_uses_the_shared_field_split(tmp_path):
    """The temporal centre must come from the MIDDLE 10 bits.

    This is the regression that matters. The low 11 bits are a cutoff writers zero, so a
    wrong 16/16 reading aliases the centre onto a handful of levels while leaving the
    extent near-correct — plausible numbers, destroyed timing. Asserting on the centre
    is the only reading that separates the two layouts.
    """
    bounds = {
        "min_time": 0.0, "max_time": 10.0,
        "min_time_scale": math.log(0.5), "max_time_scale": math.log(2.0),
    }  # fmt: skip
    verts = [
        {"packed_time": pack_11_10_11(0.0, 0.25, 0.0)},
        {"packed_time": pack_11_10_11(1.0, 0.50, 0.0)},
        {"packed_time": pack_11_10_11(0.5, 1.00, 0.0)},
    ]
    p = tmp_path / "t.ply"
    p.write_bytes(build_ply(temporal=True, count=3, bounds=bounds, vertices=verts))
    got = read_compressed_ply(str(p))

    np.testing.assert_allclose(got["mu_t"], [2.5, 5.0, 10.0], atol=1e-2)
    np.testing.assert_allclose(got["sigma_t"], [0.5, 2.0, 1.0], atol=1e-2)


def test_time_cutoff_bits_are_ignored(tmp_path):
    """Whatever writers put in the low 11 bits must not move the centre or the extent."""
    bounds = {"min_time": 0.0, "max_time": 10.0, "min_time_scale": 0.0, "max_time_scale": 0.0}
    base = pack_11_10_11(0.5, 0.5, 0.0)
    noisy = pack_11_10_11(0.5, 0.5, 1.0)
    p = tmp_path / "cut.ply"
    p.write_bytes(build_ply(temporal=True, count=2, bounds=bounds, vertices=[{"packed_time": base}, {"packed_time": noisy}]))
    got = read_compressed_ply(str(p))
    assert got["mu_t"][0] == pytest.approx(got["mu_t"][1])
    assert got["sigma_t"][0] == pytest.approx(got["sigma_t"][1])


def test_static_file_never_fades(tmp_path):
    p = tmp_path / "static.ply"
    p.write_bytes(build_ply(temporal=False, count=2))
    gaussians, duration = import_scene([str(p)])
    assert duration == 0.0
    assert np.all(np.isinf(gaussians.sigma_t))
    assert np.all(np.isinf(gaussians.win_hi))
    np.testing.assert_array_equal(gaussians.motions, 0.0)


def test_segments_are_placed_on_a_shared_timeline(tmp_path):
    """Segment k is stored on its OWN clock, so its scene time is local + k * duration.

    Each segment also carries a tail of gaussians centred outside its own span, which a
    player never shows; those must be dropped rather than smeared across the timeline.
    """
    bounds = {"min_time": 0.0, "max_time": 10.0, "min_time_scale": 0.0, "max_time_scale": 0.0}
    # Local centres at 2.5 s (inside a 5 s segment) and 7.5 s (the tail, outside it).
    verts = [{"packed_time": pack_11_10_11(0.0, 0.25, 0.0)}, {"packed_time": pack_11_10_11(0.0, 0.75, 0.0)}]
    paths = []
    for k in range(3):
        q = tmp_path / f"{k:02d}.ply"
        q.write_bytes(build_ply(temporal=True, count=2, bounds=bounds, vertices=verts))
        paths.append(str(q))

    gaussians, duration = import_scene(paths, segment_duration=5.0)

    assert duration == 15.0
    # One survivor per segment — the 7.5 s tail is outside every segment's own window.
    assert gaussians.count == 3
    np.testing.assert_allclose(sorted(gaussians.mu_t), [2.5, 7.5, 12.5], atol=1e-2)
    # Its own span became its validity window, which is what replaces the sidecar.
    np.testing.assert_allclose(sorted(gaussians.win_lo), [0.0, 5.0, 10.0], atol=1e-6)
    np.testing.assert_allclose(sorted(gaussians.win_hi), [5.0, 10.0, 15.0], atol=1e-6)


def test_segmented_import_requires_a_duration(tmp_path):
    paths = []
    for k in range(2):
        q = tmp_path / f"{k}.ply"
        q.write_bytes(build_ply(temporal=True, count=1))
        paths.append(str(q))
    with pytest.raises(ValueError, match="segment_duration"):
        import_scene(paths)


def test_sh_conventions_collapse_to_the_same_byte():
    """Carrying SH bytes across verbatim is exact, and this is why.

    The compressed PLY reads an interior byte as a bucket midpoint, `(b + 0.5) / 256`;
    section 6.5 pins the stored byte to `LO + b * (HI - LO) / 255`. Those disagree by up
    to half a bucket in coefficient space, which is what makes a passthrough look unsafe
    — but re-quantizing the decode back onto the specification's grid returns the same
    byte for every one of the 256 inputs, so the passthrough is identity rather than
    merely close.

    Pinned as a test because it is the assumption the importer relies on. If either
    convention ever moves, this fails instead of shifting colour quietly.
    """
    b = np.arange(256, dtype=np.uint8)
    coeff = fourdgs.compressed_ply.decode_sh_byte(b)

    span = SH_QUANT_HI - SH_QUANT_LO
    requantized = np.clip(np.rint((coeff - SH_QUANT_LO) / span * 255.0), 0, 255).astype(np.uint8)
    np.testing.assert_array_equal(requantized, b)

    # The disagreement is real but strictly sub-bucket, which is why it cannot survive
    # re-quantization. (It peaks at b = 1 and b = 254, not at the ends: 0 and 255 are
    # exact sentinels under both conventions.)
    passthrough = b / 255.0 * span + SH_QUANT_LO
    assert np.abs(passthrough - coeff).max() < 0.5 * span / 255.0


def test_sh_survives_import(tmp_path):
    p = tmp_path / "sh.ply"
    p.write_bytes(build_ply(temporal=True, count=4, sh_fields=9))
    got = read_compressed_ply(str(p))
    assert got["sh_degree"] == 1
    assert got["sh"].shape == (4, 9)
    stored = np.array([(i * 7 + j) % 256 for i in range(4) for j in range(9)], dtype=np.uint8).reshape(4, 9)
    np.testing.assert_array_equal(got["sh"], stored)


def test_noncanonical_sh_field_count_is_dropped(tmp_path):
    """Only 9/24/45 fields are canonical; anything else has no known channel stride."""
    p = tmp_path / "odd.ply"
    p.write_bytes(build_ply(temporal=True, count=2, sh_fields=7))
    got = read_compressed_ply(str(p))
    assert got["sh"] is None
    assert got["sh_degree"] == 0


def test_rejects_a_declared_chunk_count_that_disagrees(tmp_path):
    raw = bytearray(build_ply(temporal=False, count=CHUNK_SIZE + 1))
    p = tmp_path / "bad.ply"
    p.write_bytes(bytes(raw))
    # One chunk was written but CHUNK_SIZE + 1 gaussians need two.
    with pytest.raises(fourdgs.MalformedFile, match="chunks declared"):
        read_compressed_ply(str(p))


def test_rejects_a_truncated_body(tmp_path):
    raw = build_ply(temporal=True, count=8)
    p = tmp_path / "short.ply"
    p.write_bytes(raw[: len(raw) - 16])
    with pytest.raises(fourdgs.MalformedFile, match="truncated"):
        read_compressed_ply(str(p))
