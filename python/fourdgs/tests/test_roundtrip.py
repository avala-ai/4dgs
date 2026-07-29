# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Round-trip and invariant tests. No external data: every scene is built here."""

from __future__ import annotations

import io
import math

import fourdgs
import numpy as np
import pytest
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
        assert out.audio_sources == []
        assert out.header.has_audio is False
        # Nothing in the file even mentions audio.
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0)
        opcodes = _opcodes(buf.getvalue())
        assert op.AUDIO not in opcodes
        assert op.AUDIO_SOURCE not in opcodes
        assert op.AUDIO_DATA not in opcodes

    def test_present_audio_round_trips_byte_exact(self):
        track = fourdgs.AudioTrack(codec="wav", data=b"RIFF" + bytes(range(256)) * 4, start_sec=0.0)
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0, audio=track)
        out = fourdgs.read(buf.getvalue())
        assert out.header.has_audio is True
        assert len(out.audio_sources) == 1
        assert out.audio_sources[0].data == track.data
        assert out.audio_sources[0].codec == "wav"
        assert out.audio_sources[0].spatial is False

    def test_multiple_moving_sources_round_trip_and_reconstruct_pose(self):
        sources = [
            fourdgs.AudioSource(
                source_id=3,
                name="fixed",
                codec="wav",
                data=b"RIFF-fixed",
                duration_sec=1.0,
                position=(-1.0, 0.0, 0.0),
            ),
            fourdgs.AudioSource(
                source_id=9,
                name="moving",
                codec="wav",
                data=b"RIFF-moving",
                duration_sec=2.0,
                keyframes=[
                    fourdgs.AudioSourceKeyframe(0.0, (0.0, 0.0, 0.0)),
                    fourdgs.AudioSourceKeyframe(2.0, (2.0, 4.0, 6.0), (0.0, 1.0, 0.0, 0.0)),
                ],
            ),
        ]
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(), 6.0, audio_sources=sources)
        out = fourdgs.read(buf.getvalue())
        assert [source.source_id for source in out.audio_sources] == [3, 9]
        state = out.audio_sources[1].state_at(1.0)
        assert state.position == pytest.approx((1.0, 2.0, 3.0))
        assert state.rotation == pytest.approx((0.0, 2**-0.5, 0.0, 2**-0.5))

        from fourdgs.indexed_reader import (
            open_indexed,
            read_audio_source_descriptors,
            read_audio_source_state,
        )
        from fourdgs.readable import BytesReadable

        source = BytesReadable(buf.getvalue())
        indexed = open_indexed(source)
        descriptors = read_audio_source_descriptors(source, indexed)
        assert [descriptor.data for descriptor in descriptors] == [b"", b""]
        assert descriptors[1].data_size == len(sources[1].data)
        indexed_state = read_audio_source_state(source, indexed, 9, 1.0)
        assert indexed_state.position == pytest.approx((1.0, 2.0, 3.0))

    def test_step_audio_pose_uses_the_keyframe_at_an_exact_time(self):
        source = fourdgs.AudioSource(
            source_id=1,
            codec="wav",
            data=b"x",
            duration_sec=2.0,
            interpolation="step",
            keyframes=[
                fourdgs.AudioSourceKeyframe(0.0, (0.0, 0.0, 0.0)),
                fourdgs.AudioSourceKeyframe(1.0, (1.0, 2.0, 3.0), (0.0, 1.0, 0.0, 1.0)),
                fourdgs.AudioSourceKeyframe(2.0, (9.0, 9.0, 9.0)),
            ],
        )
        state = source.state_at(1.0)
        assert state.position == (1.0, 2.0, 3.0)
        assert state.rotation == pytest.approx((0.0, 2**-0.5, 0.0, 2**-0.5))

    def test_an_extreme_but_finite_orientation_normalizes_without_overflow(self):
        # Normalize the direction without ever constructing a magnitude that can overflow or
        # underflow. Both vectors are finite, non-zero orientations.
        source = fourdgs.AudioSource(
            source_id=1, codec="wav", data=b"x", duration_sec=2.0, rotation=(1e308, 1e308, 1e308, 1e308)
        )
        assert source.state_at(1.0).rotation == pytest.approx((0.5, 0.5, 0.5, 0.5))
        source.rotation = (math.ulp(0.0), 0.0, 0.0, 0.0)
        assert source.state_at(1.0).rotation == pytest.approx((1.0, 0.0, 0.0, 0.0))

    def test_looping_audio_time_does_not_overflow(self):
        source = fourdgs.AudioSource(
            source_id=1,
            codec="wav",
            data=b"x",
            start_sec=-1e308,
            duration_sec=1.0,
            loop=True,
        )
        state = source.state_at(1e308)
        assert state.active is True
        assert state.local_time == 0.0
        assert math.isfinite(state.local_time)

        short_at_large_time = fourdgs.AudioSource(
            source_id=2,
            codec="wav",
            data=b"x",
            start_sec=1e308,
            duration_sec=1.0,
        )
        assert short_at_large_time.state_at(1e308).active is True

    def test_extreme_audio_positions_interpolate_without_overflow(self):
        source = fourdgs.AudioSource(
            source_id=1,
            codec="wav",
            data=b"x",
            start_sec=-1e308,
            duration_sec=1.0,
            loop=True,
            keyframes=[
                fourdgs.AudioSourceKeyframe(-1e308, (-1e308, 0.0, 0.0)),
                fourdgs.AudioSourceKeyframe(1e308, (1e308, 0.0, 0.0)),
            ],
        )
        state = source.state_at(0.0)
        assert state.position == (0.0, 0.0, 0.0)
        assert all(math.isfinite(value) for value in state.position)

    def test_truncation_does_not_excuse_audio_when_the_header_flag_is_clear(self):
        buf = io.BytesIO()
        source = fourdgs.AudioSource(source_id=1, codec="wav", data=b"RIFF", duration_sec=6.0)
        fourdgs.write(buf, make_scene(), 6.0, audio_sources=[source])
        data = bytearray(buf.getvalue())
        from fourdgs.serialization import iter_records

        header = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.HEADER)
        cursor = Cursor(header.content)
        cursor.string()
        cursor.string()
        cursor.take(8 + 8 + 8)
        cursor.string()
        cursor.take(6 * 8)
        cursor.u8()
        data[header.offset + 9 + cursor.pos] &= ~1

        descriptor = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.AUDIO_SOURCE)
        payload = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.AUDIO_DATA)
        location = rf"Audio Source record for source id 1 at byte {descriptor.offset}"
        with pytest.raises(fourdgs.MalformedFile, match=location):
            fourdgs.read(bytes(data[:-1]), recover_truncated=True)
        with pytest.raises(fourdgs.MalformedFile, match=location):
            fourdgs.read(bytes(data[: payload.offset]), recover_truncated=True)

    def test_indexed_audio_range_validates_descriptor_and_payload_lengths_first(self):
        from fourdgs.indexed_reader import open_indexed, read_audio_range
        from fourdgs.readable import BytesReadable
        from fourdgs.serialization import iter_records

        buf = io.BytesIO()
        source = fourdgs.AudioSource(source_id=1, codec="wav", data=b"RIFF", duration_sec=6.0)
        fourdgs.write(buf, make_scene(), 6.0, audio_sources=[source])
        data = bytearray(buf.getvalue())
        descriptor = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.AUDIO_SOURCE)
        cursor = Cursor(descriptor.content)
        assert cursor.u32() == source.source_id
        cursor.string()
        cursor.string()
        cursor.string()
        data_length_at = descriptor.offset + 9 + cursor.pos
        declared = int.from_bytes(data[data_length_at : data_length_at + 8], "little")
        data[data_length_at : data_length_at + 8] = (declared + 1).to_bytes(8, "little")

        readable = BytesReadable(bytes(data))
        indexed = open_indexed(readable)
        with pytest.raises(fourdgs.MalformedFile, match="Audio Data record declares"):
            read_audio_range(readable, indexed, source.source_id, 0, 1)

    def test_indexed_open_rejects_audio_data_framed_past_eof(self):
        from fourdgs.indexed_reader import open_indexed
        from fourdgs.readable import BytesReadable
        from fourdgs.serialization import iter_records

        buf = io.BytesIO()
        source = fourdgs.AudioSource(source_id=1, codec="wav", data=b"RIFF", duration_sec=6.0)
        fourdgs.write(buf, make_scene(), 6.0, audio_sources=[source])
        data = bytearray(buf.getvalue())
        payload = next(record for record in iter_records(data, len(MAGIC)) if record.opcode == op.AUDIO_DATA)

        # Keep the inner source id, byte length, and payload valid, but make the outer
        # framing run nine bytes beyond the resource. The front-matter walker must reject
        # that declaration instead of clamping its prefix read and jumping past EOF.
        content_length = len(data) - payload.offset
        data[payload.offset + 1 : payload.offset + 9] = content_length.to_bytes(8, "little")

        location = rf"AudioData record at byte {payload.offset} spans .* outside the {len(data)}-byte file"
        with pytest.raises(fourdgs.MalformedFile, match=location):
            open_indexed(BytesReadable(bytes(data)))

    def test_the_writer_normalizes_an_extreme_audio_orientation_without_overflow(self):
        source = fourdgs.AudioSource(
            source_id=1, codec="wav", data=b"x", duration_sec=2.0, rotation=(1e308, 0.0, 0.0, 0.0)
        )
        buf = io.BytesIO()
        fourdgs.write(buf, make_scene(n=0), 2.0, audio_sources=[source])
        decoded = fourdgs.read(buf.getvalue())
        assert decoded.audio_sources[0].rotation == pytest.approx((1.0, 0.0, 0.0, 0.0))

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

    def test_an_audio_data_record_beside_a_legacy_audio_record_is_an_orphan(self):
        # A legacy Audio record carries its own payload and pairs with no separate Audio
        # Data record. A file that puts an Audio Data record next to a legacy Audio record
        # therefore leaves that data orphaned, and the streamed reader has always refused
        # it. The indexed reader took a legacy shortcut that never inspected the leftover
        # data ranges, so it accepted the same malformed file; both paths must agree.
        from fourdgs.indexed_reader import open_indexed
        from fourdgs.readable import BytesReadable
        from fourdgs.serialization import iter_records

        buf = io.BytesIO()
        source = fourdgs.AudioSource(source_id=3, name="solo", codec="wav", data=b"RIFF" + bytes(256), duration_sec=6.0)
        fourdgs.write(buf, make_scene(), 6.0, audio_sources=[source])
        data = bytearray(buf.getvalue())

        # Rewrite the Audio Source descriptor in place as an empty legacy Audio record
        # (codec "wav", start 0.0, no data). Its framed length is unchanged so every later
        # offset still lands, and its paired Audio Data record is left orphaned. The summary
        # CRC covers only the summary run, not front-matter audio, so the file is otherwise
        # well-formed.
        record = next(r for r in iter_records(data, len(MAGIC)) if r.opcode == op.AUDIO_SOURCE)
        content = record.offset + 9
        length = len(record.content)
        data[record.offset] = op.AUDIO
        data[content : content + length] = bytes(length)
        data[content : content + 4] = (3).to_bytes(4, "little")
        data[content + 4 : content + 7] = b"wav"
        # start_sec (f64 at content+7) and data_length (u64 at content+15) stay zero.

        with pytest.raises(fourdgs.MalformedFile, match="no matching Audio Source"):
            fourdgs.read(bytes(data))
        with pytest.raises(fourdgs.MalformedFile, match="no matching Audio Source"):
            open_indexed(BytesReadable(bytes(data)))

        # The recovery path refuses it too. A truncated tail can legitimize an unmatched new
        # descriptor, but never an Audio Data beside a legacy record — the representations
        # cannot be mixed, so no missing bytes could complete it. Drop the trailing magic to
        # mark the file truncated; recovery is on by default.
        cut = bytes(data[: -len(MAGIC)])
        with pytest.raises(fourdgs.MalformedFile, match="no matching Audio Source"):
            fourdgs.read(cut, recover_truncated=True)


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


class TestEncoderRefusals:
    """What the encoder must refuse, and — just as important — what it must not."""

    def test_a_non_finite_quantized_field_is_refused_by_name(self):
        # Spec §5.3. The position origin is the per-axis minimum of `positions` and the
        # steps come from the median scale, so a non-finite value there lands in the
        # Quantization record. Refused at the boundary, where the field can still be named:
        # the codec's own complaint is about a symbol width and names nothing useful.
        for field, index in (
            ("positions", (0, 0)),
            ("scales", (1, 2)),
            ("rotations", (2, 3)),
            ("colors", (3, 1)),
            ("motions", (4, 0)),
            ("mu_t", 5),
        ):
            for bad in (np.inf, -np.inf, np.nan):
                scene = make_scene(n=32, windows=2)
                getattr(scene, field)[index] = bad
                with pytest.raises(fourdgs.InvalidInput, match=field):
                    fourdgs.write(io.BytesIO(), scene, 6.0)

    def test_a_static_asset_encodes_with_infinite_sigma_and_window(self):
        # The degenerate temporal case: no time in the scene, present at every instant.
        # `sigma_t = +inf` and `win_hi = +inf` are how the format says that, and neither is
        # quantized — the window goes into the Window Table as f64 verbatim. An over-broad
        # finiteness check refuses a whole legitimate class of file, which is exactly what
        # the glTF import writes for a static asset.
        scene = make_scene(n=32, windows=1)
        scene.sigma_t[:] = np.inf
        scene.win_lo[:] = 0.0
        scene.win_hi[:] = np.inf
        buf = io.BytesIO()
        fourdgs.write(buf, scene, 1.0)
        decoded = fourdgs.read(buf.getvalue())
        assert np.isinf(decoded.gaussians.sigma_t).all(), "never-fades survives"
        assert np.isinf(decoded.gaussians.win_hi).all(), "the open window survives"

    def test_a_nan_window_or_sigma_is_still_refused(self):
        # NaN is meaningful in none of them. The decoder reads any non-finite sigma as
        # never-fading, so a NaN would pass for a deliberate value; a NaN window makes
        # every visibility comparison false, so the gaussian silently never appears.
        for field in ("sigma_t", "win_lo", "win_hi"):
            scene = make_scene(n=16, windows=1)
            getattr(scene, field)[0] = np.nan
            with pytest.raises(fourdgs.InvalidInput, match=field):
                fourdgs.write(io.BytesIO(), scene, 6.0)

    def test_a_negative_infinite_sigma_is_refused_but_a_positive_one_is_not(self):
        scene = make_scene(n=16, windows=1)
        scene.sigma_t[0] = -np.inf
        with pytest.raises(fourdgs.InvalidInput, match="sigma_t"):
            fourdgs.write(io.BytesIO(), scene, 6.0)

        scene = make_scene(n=16, windows=1)
        scene.sigma_t[0] = np.inf
        fourdgs.write(io.BytesIO(), scene, 6.0)
