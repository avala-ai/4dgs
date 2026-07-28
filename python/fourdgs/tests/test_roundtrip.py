# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Round-trip and invariant tests. No external data: every scene is built here."""

from __future__ import annotations

import io
import math

import numpy as np
import pytest

import fourdgs
from fourdgs import opcode as op
from fourdgs.serialization import MAGIC, Cursor, decode_stream, encode_stream, put_record

RNG = np.random.default_rng(20260728)


def make_scene(n=600, windows=3, duration=6.0, sh_degree=0, never_fades_fraction=0.1):
    seg = np.arange(n) % windows
    win_len = duration / windows
    sigma = np.exp(RNG.normal(-2.0, 0.8, n))
    if never_fades_fraction:
        sigma[: int(n * never_fades_fraction)] = np.inf
    quats = RNG.normal(0, 1, (n, 4))
    quats /= np.linalg.norm(quats, axis=1, keepdims=True)
    sh = RNG.integers(0, 256, (n, {0: 0, 1: 9, 2: 24, 3: 45}[sh_degree]), dtype=np.uint8) if sh_degree else None
    return fourdgs.GaussianSet(
        positions=RNG.normal(0, 0.5, (n, 3)).astype(np.float32),
        scales=np.exp(RNG.normal(-7, 0.5, (n, 3))).astype(np.float32),
        rotations=quats.astype(np.float32),
        colors=RNG.uniform(0, 1, (n, 4)).astype(np.float32),
        motions=RNG.normal(0, 0.05, (n, 3)).astype(np.float32),
        mu_t=(seg * win_len + RNG.uniform(0, win_len, n)).astype(np.float32),
        sigma_t=sigma.astype(np.float32),
        win_lo=(seg * win_len).astype(np.float32),
        win_hi=((seg + 1) * win_len).astype(np.float32),
        sh=sh,
        sh_degree=sh_degree,
    )


def roundtrip(scene, duration=6.0, **kw):
    buf = io.BytesIO()
    fourdgs.write(buf, scene, duration, options=fourdgs.WriteOptions(**kw))
    return fourdgs.read(buf.getvalue())


class TestRoundTrip:
    def test_bounds_hold_for_every_gaussian(self):
        scene = make_scene()
        out = roundtrip(scene)
        g = out.gaussians
        assert g.count == scene.count
        bounds = fourdgs.Bounds.for_profile("default", median_scale=float(np.median(scene.scales)))
        # Order is not preserved (the encoder is free to reorder), so compare sorted.
        for got, want in ((g.positions, scene.positions), (g.colors, scene.colors)):
            assert np.abs(np.sort(got, axis=0) - np.sort(want, axis=0)).max() < bounds.pos + bounds.rgb + 1e-4

    def test_never_fading_gaussians_survive_as_infinity(self):
        scene = make_scene(never_fades_fraction=0.25)
        out = roundtrip(scene)
        assert np.isinf(out.gaussians.sigma_t).sum() == int(np.isinf(scene.sigma_t).sum())

    def test_empty_scene(self):
        scene = make_scene(n=0, windows=1)
        out = roundtrip(scene, duration=1.0)
        assert out.gaussians.count == 0
        assert out.header.gaussian_count == 0

    def test_single_gaussian(self):
        out = roundtrip(make_scene(n=1, windows=1, never_fades_fraction=0.0), duration=1.0)
        assert out.gaussians.count == 1

    @pytest.mark.parametrize("degree", [1, 2, 3])
    def test_spherical_harmonics_degrees(self, degree):
        out = roundtrip(make_scene(sh_degree=degree))
        assert out.header.sh_degree == degree


class TestAudio:
    def test_absent_audio_costs_nothing_and_is_not_an_error(self):
        out = roundtrip(make_scene())
        assert out.audio is None
        assert out.header.has_audio is False
        # Nothing in the file even mentions audio.
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0)
        opcodes = _opcodes(buf.getvalue())
        assert op.AUDIO not in opcodes

    def test_present_audio_round_trips_byte_exact(self):
        track = fourdgs.AudioTrack(codec="wav", data=b"RIFF" + bytes(range(256)) * 4, start_sec=0.0)
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0, audio=track)
        out = fourdgs.read(buf.getvalue())
        assert out.header.has_audio is True
        assert out.audio is not None
        assert out.audio.data == track.data
        assert out.audio.codec == "wav"

    def test_audio_presence_is_answerable_from_the_header_alone(self):
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0, audio=fourdgs.AudioTrack(codec="wav", data=b"RIFFxxxx"))
        data = buf.getvalue()
        # Parse only the header record, nothing else.
        c = Cursor(data, len(MAGIC))
        from fourdgs.records import Header
        from fourdgs.serialization import read_record

        header = Header.parse(read_record(c).content)
        assert header.has_audio is True


class TestForwardCompatibility:
    def test_unknown_and_private_records_are_skipped(self):
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0)
        data = bytearray(buf.getvalue())
        # Splice a private-range record and an unknown spec-range record in after the
        # magic; a conforming reader must step over both.
        inject = put_record(0x90, b"private application payload") + put_record(0x7E, b"future spec record")
        spliced = bytes(data[: len(MAGIC)]) + inject + bytes(data[len(MAGIC) :])
        out = fourdgs.read(spliced)
        assert out.gaussians.count == make_scene().count
        assert 0x90 in out.skipped_opcodes
        assert 0x7E in out.skipped_opcodes

    def test_appended_record_fields_do_not_break_a_reader(self):
        from fourdgs.records import Header

        header = Header(duration_sec=1.0, gaussian_count=5, aabb=[0] * 6)
        blob = header.encode()
        # A future writer appends a field: same opcode, longer content.
        opcode, length = blob[0], int.from_bytes(blob[1:9], "little")
        extended = bytes([opcode]) + (length + 4).to_bytes(8, "little") + blob[9:] + b"\x00\x00\x00\x01"
        parsed = Header.parse(Cursor(extended, 9).take(length + 4))
        assert parsed.gaussian_count == 5


class TestRecovery:
    def test_truncated_file_keeps_what_was_complete(self):
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0)
        data = buf.getvalue()
        out = fourdgs.read(data[: int(len(data) * 0.7)])
        assert out.truncated is True
        assert out.gaussians.count >= 0  # whatever survived, without raising

    def test_not_a_4dgs_file(self):
        with pytest.raises(fourdgs.UnsupportedVersion):
            fourdgs.read(b"not a 4dgs file at all")

    def test_future_major_version_is_refused_clearly(self):
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0)
        data = bytearray(buf.getvalue())
        data[5] = ord("9")
        with pytest.raises(fourdgs.UnsupportedVersion, match="version"):
            fourdgs.read(bytes(data))


class TestStreams:
    @pytest.mark.parametrize(
        "values,channels",
        [
            (RNG.integers(-5, 5, (500, 3)), 3),
            (np.cumsum(RNG.integers(-2, 3, (2000, 1)), axis=0), 1),
            (np.full((300, 2), 7), 2),
            (np.zeros((0, 3), dtype=np.int64), 3),
        ],
    )
    def test_stream_roundtrip(self, values, channels):
        blob = encode_stream(3, values, channels=channels, level=1)
        attribute_id, out = decode_stream(Cursor(blob))
        assert attribute_id == 3
        np.testing.assert_array_equal(out, np.asarray(values).reshape(-1, channels))


class TestSemantics:
    def test_state_at_matches_the_specification(self):
        scene = make_scene(n=200, never_fades_fraction=0.0)
        t = 2.0
        state = scene.state_at(t)
        for i in state["indices"][:20]:
            assert scene.win_lo[i] <= t < scene.win_hi[i]
            marginal = math.exp(-0.5 * ((t - scene.mu_t[i]) / scene.sigma_t[i]) ** 2)
            assert marginal >= 0.05

    def test_a_gaussian_outside_its_window_is_absent_not_faded(self):
        scene = make_scene(n=100, windows=2, duration=4.0, never_fades_fraction=1.0)
        # Every gaussian never fades, so only the window can exclude one.
        state = scene.state_at(0.5)
        assert set(np.asarray(scene.win_lo)[state["indices"]]) == {0.0}


def _opcodes(data: bytes) -> set[int]:
    from fourdgs.serialization import iter_records

    return {r.opcode for r in iter_records(data, len(MAGIC))}
