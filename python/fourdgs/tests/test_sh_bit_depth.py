# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Per-band spherical harmonic bit depths (spec §5.3, §6.5).

The property under test is not "the encoder writes the field". It is that the field is a
*declaration about bytes that are already quantized*: a decoder that ignores it decodes the
same scene, a file that declares nothing is the file it was before the field existed, and
the bound the file claims per band is one the coefficients actually satisfy.
"""

from __future__ import annotations

import io

import fourdgs
import numpy as np
import pytest
from fourdgs.exceptions import BoundViolation
from fourdgs.quantization import SH_QUANT_HI, SH_QUANT_LO, quantize_sh, sh_bound, sh_coefficient, sh_step
from fourdgs.records import Quantization
from fourdgs.validate import validate
from test_roundtrip import make_scene

DEPTHS = (8, 7, 6, 5, 4, 3)


def write(scene, duration=6.0, **kw) -> bytes:
    buf = io.BytesIO()
    fourdgs.write(buf, scene, duration, options=fourdgs.WriteOptions(**kw))
    return buf.getvalue()


class TestGrid:
    @pytest.mark.parametrize("bits", DEPTHS)
    def test_bound_is_half_the_pitch_and_holds_for_every_byte(self, bits):
        every = np.arange(256, dtype=np.int64)
        got = quantize_sh(every, bits)
        assert got.min() >= 0 and got.max() <= 255
        assert np.abs(got - every).max() <= sh_bound(bits)
        assert sh_bound(bits) == sh_step(bits) // 2

    @pytest.mark.parametrize("bits", DEPTHS)
    def test_quantizing_twice_changes_nothing(self, bits):
        once = quantize_sh(np.arange(256, dtype=np.int64), bits)
        assert np.array_equal(quantize_sh(once, bits), once)

    def test_eight_bits_is_the_identity(self):
        every = np.arange(256, dtype=np.int64)
        assert np.array_equal(quantize_sh(every, 8), every)
        assert sh_bound(8) == 0

    @pytest.mark.parametrize("bits", (0, 2, 9, 255))
    def test_a_depth_outside_the_range_is_refused(self, bits):
        with pytest.raises(ValueError, match=r"3\.\.8"):
            sh_step(bits)

    def test_the_byte_to_coefficient_map_is_the_one_the_spec_pins(self):
        assert sh_coefficient(0) == SH_QUANT_LO
        assert sh_coefficient(255) == SH_QUANT_HI
        assert sh_coefficient(np.array([128]))[0] == pytest.approx(-4.0 + 128 * 8 / 255)


class TestDeclaration:
    def test_a_file_that_declares_nothing_is_byte_identical(self):
        scene = make_scene(sh_degree=3)
        assert write(scene) == write(scene, sh_bit_depths=None)

    def test_declaring_eight_bits_changes_the_declaration_and_not_the_coefficients(self):
        scene = make_scene(sh_degree=3)
        plain = fourdgs.read(write(scene))
        flat = fourdgs.read(write(scene, sh_bit_depths="flat"))
        assert flat.quantization.sh_bit_depths == [8, 8, 8]
        assert plain.quantization.sh_bit_depths == []
        assert np.array_equal(np.sort(plain.gaussians.sh, axis=0), np.sort(flat.gaussians.sh, axis=0))

    def test_the_declared_bound_holds_for_every_coefficient(self):
        scene = make_scene(sh_degree=3)
        out = fourdgs.read(write(scene, sh_bit_depths=(6, 4, 3), preserve_source_ids=True))
        order = np.argsort(np.asarray(out.gaussians.source_index))
        decoded = np.asarray(out.gaussians.sh, dtype=np.int64)[order]
        reference = np.asarray(scene.sh, dtype=np.int64)
        coefficients = reference.shape[1] // 3
        for band, (first, last) in {1: (0, 3), 2: (3, 8), 3: (8, 15)}.items():
            columns = [c * coefficients + k for c in range(3) for k in range(first, last)]
            deviation = np.abs(decoded[:, columns] - reference[:, columns]).max()
            declared = int(out.quantization.bounds[f"sh_band{band}"])
            assert deviation <= declared
            assert declared == sh_bound((6, 4, 3)[band - 1])

    def test_step_sh_and_the_scalar_bound_are_the_coarsest_band(self):
        scene = make_scene(sh_degree=3)
        quant = fourdgs.read(write(scene, sh_bit_depths=(8, 6, 5))).quantization
        assert quant.step_sh == sh_step(5)
        assert quant.bounds["sh"] == str(sh_bound(5))
        assert quant.scheme == "uniform-v1"

    def test_a_ladder_shorter_than_the_scene_is_refused(self):
        scene = make_scene(sh_degree=3)
        with pytest.raises(ValueError, match="declares 2 bands"):
            write(scene, sh_bit_depths=(8, 6))

    def test_an_unknown_ladder_names_the_ones_that_exist(self):
        with pytest.raises(ValueError, match="aggressive"):
            write(make_scene(sh_degree=2), sh_bit_depths="reckless")

    def test_depths_win_over_the_profile_wide_step(self):
        """The `coarse` profile sets `step_sh` too; the per-band depths are what apply."""
        scene = make_scene(sh_degree=2)
        out = fourdgs.read(write(scene, profile="coarse", sh_bit_depths=(8, 8)))
        assert out.quantization.sh_bit_depths == [8, 8]
        assert out.quantization.step_sh == 1
        assert np.array_equal(np.sort(out.gaussians.sh, axis=0), np.sort(scene.sh, axis=0))


class TestTolerantParse:
    """Appended fields are positional, so this field shares its offset with anything a
    different writer appended. A declaration nobody can trust is read as absent."""

    def grids(self, **kw) -> Quantization:
        base = dict(
            scheme="uniform-v1",
            pos_origin=[0.0, 0.0, 0.0],
            step_pos=1e-4,
            step_scale_log=0.04,
            step_rot=0.004,
            step_rgb=0.008,
            step_alpha=0.008,
            step_motion=2e-4,
            step_time=0.004,
            step_sigma_log=0.04,
            step_sh=1,
        )
        return Quantization(**(base | kw))

    def parse(self, trailer: bytes) -> list[int]:
        encoded = self.grids().encode(trailer=trailer)
        return Quantization.parse(encoded[9:]).sh_bit_depths

    def test_a_foreign_trailer_is_not_read_as_depths(self):
        assert self.parse(b"\x02\x00\x00\x00appended-quantization-field") == []

    def test_a_count_the_record_is_too_short_for_is_not_read(self):
        assert self.parse(b"\x04\x08\x06") == []

    def test_depths_survive_a_round_trip(self):
        assert self.parse(b"") == []
        encoded = self.grids(sh_bit_depths=[8, 6, 5]).encode()
        assert Quantization.parse(encoded[9:]).sh_bit_depths == [8, 6, 5]


class TestValidate:
    def test_a_conforming_file_is_clean(self):
        report = validate(write(make_scene(sh_degree=3), sh_bit_depths="balanced"))
        assert report.ok and not report.findings

    def test_a_count_that_disagrees_with_the_degree_is_an_error(self):
        data = bytearray(write(make_scene(sh_degree=2), sh_bit_depths=(8, 6)))
        # Patch the count byte alone, so the record's length still holds and this is a
        # file that is wrong about itself rather than one that is structurally broken.
        at = data.index(bytes([2, 8, 6]))
        data[at] = 1
        report = validate(bytes(data))
        assert not report.ok
        assert [f.message for f in report.findings if "SH bit depths" in f.message]


class TestVerification:
    def test_the_encoder_refuses_a_bound_it_cannot_meet(self, monkeypatch):
        """The gate is the encoder decoding its own output, so break the output."""
        from fourdgs import writer

        original = writer.quantize_sh
        monkeypatch.setattr(writer, "quantize_sh", lambda values, bits: original(values, min(bits, 3)))
        with pytest.raises(BoundViolation, match="SH band"):
            write(make_scene(sh_degree=2), sh_bit_depths=(8, 8))
