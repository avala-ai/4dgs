# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Tests for the PLY frame-sequence importer.

Fixtures are written into a temporary directory rather than committed: they are
generated from a fixed seed, exactly like the conformance corpus, and the repository
keeps no binaries it can reconstruct.

What matters here is the claim the format makes about this import — that a sequence of
independent frames enters the continuous temporal model "always, and always correctly":
one validity window per step, velocity only where the source actually asserts
correspondence. So the tests check the timeline the frames become, not merely that the
call returns.
"""

from __future__ import annotations

import io
import itertools
import math
import struct

import fourdgs
import numpy as np
import pytest
from fourdgs.convert import SH_C0, convert_ply_sequence, read_ply
from fourdgs.exceptions import MalformedFile

RNG = np.random.default_rng(20260728)

STANDARD_FIELDS = [
    "x",
    "y",
    "z",
    "scale_0",
    "scale_1",
    "scale_2",
    "rot_0",
    "rot_1",
    "rot_2",
    "rot_3",
    "f_dc_0",
    "f_dc_1",
    "f_dc_2",
    "opacity",
]


def frame_fields(n: int, *, offset: float = 0.0, sh_rest: int = 0) -> dict[str, np.ndarray]:
    """One frame's worth of standard gaussian-splat PLY fields."""
    fields = {
        "x": np.linspace(-1, 1, n) + offset,
        "y": np.linspace(0, 1, n),
        "z": np.full(n, 0.25),
        "scale_0": np.full(n, math.log(0.01)),
        "scale_1": np.full(n, math.log(0.02)),
        "scale_2": np.full(n, math.log(0.03)),
        # PLY stores the quaternion scalar first: rot_0 is w.
        "rot_0": np.full(n, 1.0),
        "rot_1": np.zeros(n),
        "rot_2": np.zeros(n),
        "rot_3": np.zeros(n),
        "f_dc_0": np.full(n, 0.5),
        "f_dc_1": np.zeros(n),
        "f_dc_2": np.full(n, -0.5),
        "opacity": np.zeros(n),  # sigmoid(0) = 0.5
    }
    for k in range(sh_rest):
        fields[f"f_rest_{k}"] = np.full(n, (k % 7) - 3.0)
    return fields


def write_ply(path, fields: dict[str, np.ndarray], *, ascii_format: bool = False) -> None:
    names = list(fields)
    n = len(fields[names[0]])
    lines = ["ply", f"format {'ascii' if ascii_format else 'binary_little_endian'} 1.0", f"element vertex {n}"]
    lines += [f"property float {name}" for name in names]
    lines.append("end_header")
    header = ("\n".join(lines) + "\n").encode("ascii")
    if ascii_format:
        rows = "\n".join(" ".join(repr(float(fields[name][i])) for name in names) for i in range(n))
        path.write_bytes(header + rows.encode("ascii") + b"\n")
        return
    body = b"".join(struct.pack(f"<{len(names)}f", *[float(fields[name][i]) for name in names]) for i in range(n))
    path.write_bytes(header + body)


def sequence(tmp_path, frames: int, n: int = 8, *, moving: bool = False, sh_rest: int = 0, names=None):
    for i in range(frames):
        name = names[i] if names else f"frame_{i:04d}.ply"
        write_ply(tmp_path / name, frame_fields(n, offset=0.5 * i if moving else 0.0, sh_rest=sh_rest))
    return str(tmp_path)


class TestReadPly:
    def test_binary_and_ascii_agree(self, tmp_path):
        fields = frame_fields(6)
        write_ply(tmp_path / "b.ply", fields)
        write_ply(tmp_path / "a.ply", fields, ascii_format=True)
        binary = read_ply(str(tmp_path / "b.ply"))
        text = read_ply(str(tmp_path / "a.ply"))
        assert binary.count == text.count == 6
        for name in fields:
            assert np.allclose(binary.fields[name], text.fields[name], atol=1e-6), name

    def test_values_survive_the_round_trip(self, tmp_path):
        fields = frame_fields(4)
        write_ply(tmp_path / "f.ply", fields)
        frame = read_ply(str(tmp_path / "f.ply"))
        assert np.allclose(frame.fields["x"], fields["x"], atol=1e-6)
        assert set(STANDARD_FIELDS) <= set(frame.fields)

    def test_a_file_that_is_not_a_ply(self, tmp_path):
        (tmp_path / "no.ply").write_bytes(b"\x894DGS1\r\n" + b"\x00" * 32)
        with pytest.raises(MalformedFile, match="not a PLY"):
            read_ply(str(tmp_path / "no.ply"))

    def test_a_ply_with_no_vertices(self, tmp_path):
        (tmp_path / "empty.ply").write_bytes(b"ply\nformat ascii 1.0\nelement vertex 0\nend_header\n")
        with pytest.raises(MalformedFile, match="no vertices"):
            read_ply(str(tmp_path / "empty.ply"))

    def test_list_properties_are_refused_rather_than_guessed_at(self, tmp_path):
        header = (
            "ply\nformat binary_little_endian 1.0\nelement vertex 1\n"
            "property float x\nproperty list uchar int weights\nend_header\n"
        )
        (tmp_path / "list.ply").write_bytes(header.encode() + b"\x00" * 32)
        with pytest.raises(MalformedFile, match="list properties"):
            read_ply(str(tmp_path / "list.ply"))


class TestFrameOrdering:
    def test_frames_are_ordered_numerically_not_lexically(self, tmp_path):
        # The bug this guards: "frame_10" sorts before "frame_2" as text, which silently
        # reorders the timeline of any sequence longer than nine frames.
        names = [f"frame_{i}.ply" for i in (1, 2, 10, 11)]
        for i, name in enumerate(names):
            write_ply(tmp_path / name, frame_fields(3, offset=float(i)))
        gaussians, _ = convert_ply_sequence(str(tmp_path), fps=10.0)
        # Frame i was written with x offset i, so ascending windows must see ascending x.
        first_x = [gaussians.positions[i * 3, 0] for i in range(4)]
        assert first_x == sorted(first_x), first_x

    def test_a_directory_with_no_ply_files(self, tmp_path):
        (tmp_path / "readme.txt").write_text("nothing to import")
        with pytest.raises(MalformedFile, match=r"no \.ply files"):
            convert_ply_sequence(str(tmp_path))


class TestTimeline:
    def test_each_frame_becomes_one_validity_window(self, tmp_path):
        frames, n, fps = 5, 8, 20.0
        gaussians, duration = convert_ply_sequence(sequence(tmp_path, frames, n), fps=fps)
        assert gaussians.count == frames * n
        assert duration == pytest.approx(frames / fps)

        dt = 1.0 / fps
        for i in range(frames):
            lo = gaussians.win_lo[i * n : (i + 1) * n]
            hi = gaussians.win_hi[i * n : (i + 1) * n]
            assert np.allclose(lo, i * dt, atol=1e-6)
            assert np.allclose(hi, (i + 1) * dt, atol=1e-6)
            # Centred in its own slot, with an extent that covers it.
            assert np.allclose(gaussians.mu_t[i * n : (i + 1) * n], (i + 0.5) * dt, atol=1e-6)

    def test_the_windows_tile_the_timeline_without_gaps_or_overlap(self, tmp_path):
        gaussians, duration = convert_ply_sequence(sequence(tmp_path, 4, 5), fps=25.0)
        edges = sorted(
            {
                (round(float(lo), 6), round(float(hi), 6))
                for lo, hi in zip(gaussians.win_lo, gaussians.win_hi, strict=True)
            }
        )
        assert edges[0][0] == 0.0
        assert edges[-1][1] == pytest.approx(duration)
        for (_, hi), (lo, _) in itertools.pairwise(edges):
            assert hi == pytest.approx(lo), "a frame's window must start where the previous one ended"

    def test_every_gaussian_is_visible_inside_its_own_slot(self, tmp_path):
        frames, n, fps = 3, 6, 10.0
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, frames, n), fps=fps)
        dt = 1.0 / fps
        for i in range(frames):
            state = gaussians.state_at((i + 0.5) * dt)
            assert len(state["indices"]) == n, f"frame {i} should be alone on screen at its centre"
            assert set(state["indices"].tolist()) == set(range(i * n, (i + 1) * n))


class TestAttributes:
    def test_a_static_sequence_has_no_velocity(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 3, 4), fps=30.0)
        assert np.all(gaussians.motions == 0.0), "frames that do not move must not invent motion"

    def test_a_moving_sequence_fits_velocity_from_the_frames(self, tmp_path):
        fps = 4.0
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 3, 4, moving=True), fps=fps)
        # Frame 0 has no predecessor, so it is still; the rest move by 0.5 per frame.
        assert np.all(gaussians.motions[:4] == 0.0)
        assert np.allclose(gaussians.motions[4:, 0], 0.5 * fps, atol=1e-3)
        assert np.allclose(gaussians.motions[4:, 1:], 0.0, atol=1e-6)

    def test_frames_with_different_counts_do_not_get_a_fitted_velocity(self, tmp_path):
        write_ply(tmp_path / "f_0.ply", frame_fields(4))
        write_ply(tmp_path / "f_1.ply", frame_fields(7, offset=1.0))
        gaussians, _ = convert_ply_sequence(str(tmp_path), fps=10.0)
        assert gaussians.count == 11
        # No correspondence is asserted by the source, so none is invented.
        assert np.all(gaussians.motions == 0.0)

    def test_colour_comes_through_the_spherical_harmonic_dc_term(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 1, 3), fps=10.0)
        assert np.allclose(gaussians.colors[:, 0], 0.5 * SH_C0 + 0.5, atol=1e-6)
        assert np.allclose(gaussians.colors[:, 1], 0.5, atol=1e-6)
        assert np.allclose(gaussians.colors[:, 2], -0.5 * SH_C0 + 0.5, atol=1e-6)
        # opacity is stored as a logit.
        assert np.allclose(gaussians.colors[:, 3], 0.5, atol=1e-6)

    def test_scales_come_out_of_the_log_domain(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 1, 3), fps=10.0)
        assert np.allclose(gaussians.scales[:, 0], 0.01, atol=1e-6)
        assert np.allclose(gaussians.scales[:, 1], 0.02, atol=1e-6)
        assert np.allclose(gaussians.scales[:, 2], 0.03, atol=1e-6)

    def test_rotations_are_reordered_from_wxyz_to_xyzw(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 1, 3), fps=10.0)
        # The fixture's quaternion is w=1, so the identity is (0, 0, 0, 1) in xyzw.
        assert np.allclose(gaussians.rotations, np.array([0.0, 0.0, 0.0, 1.0]), atol=1e-6)

    def test_spherical_harmonics_are_imported_when_every_frame_has_them(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 2, 4, sh_rest=9), fps=10.0)
        assert gaussians.sh_degree == 1
        assert gaussians.sh is not None
        assert gaussians.sh.shape == (8, 9)

    def test_a_sequence_without_harmonics_has_none(self, tmp_path):
        gaussians, _ = convert_ply_sequence(sequence(tmp_path, 2, 4), fps=10.0)
        assert gaussians.sh_degree == 0
        assert gaussians.sh is None


class TestEndToEnd:
    def test_an_imported_sequence_writes_and_reads_back(self, tmp_path):
        frames, n, fps = 4, 16, 12.0
        gaussians, duration = convert_ply_sequence(sequence(tmp_path, frames, n, moving=True), fps=fps)

        buf = io.BytesIO()
        fourdgs.write(buf, gaussians, duration)
        scene = fourdgs.read(buf.getvalue())

        assert scene.gaussians.count == frames * n
        assert scene.header.duration_sec == pytest.approx(duration)
        assert scene.header.temporal_model == "gaussian-birth"

        # The import is lossy only where the file says it is: positions must come back
        # inside the bound the file itself declares.
        bound = float(scene.quantization.bounds["pos"])
        decoded = np.sort(scene.gaussians.positions[:, 0])
        original = np.sort(gaussians.positions[:, 0])
        assert np.max(np.abs(decoded - original)) <= bound + 1e-9

    def test_the_imported_scene_validates(self, tmp_path):
        from fourdgs.validate import validate

        gaussians, duration = convert_ply_sequence(sequence(tmp_path, 3, 8), fps=15.0)
        buf = io.BytesIO()
        fourdgs.write(buf, gaussians, duration)
        report = validate(buf.getvalue())
        assert report.ok, [f.message for f in report.findings if f.severity == "error"]
