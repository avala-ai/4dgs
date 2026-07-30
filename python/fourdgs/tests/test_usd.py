# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Tests for the OpenUSD ``ParticleField3DGaussianSplat`` bridge.

Fixtures are built here rather than committed: the USD stages this suite reads are
assembled in-process by ``build_stage`` below, exactly like the glTF suite builds its GLBs,
and the repository keeps no binaries it can reconstruct.

The bridge makes the same two claims the glTF one does, and both are checked round-trip:

* USD -> 4dgs -> USD returns every attribute within the bounds the intermediate file itself
  declares, which is what makes "lossy but bounded" a statement and not a hope;
* 4dgs -> USD at instant ``t`` is the state the format says is visible at ``t`` — motion
  applied and faded opacity included — not the stored attributes with the clock ignored.

Plus one USD earns over glTF: a Z-up scene needs no geometry rotation, and the whole scene
can be written as time samples that play. The rest is refusal — every input the converter
cannot carry exactly has to be named.

The whole module skips cleanly when ``usd-core`` is not installed; in CI the ``usd`` extra
is installed so it runs.
"""

from __future__ import annotations

import io

import fourdgs
import numpy as np
import pytest
from fourdgs.convert import SH_C0
from fourdgs.exceptions import MalformedFile
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample
from fourdgs.model import GaussianSet
from fourdgs.quantization import SH_QUANT_HI, SH_QUANT_LO
from fourdgs.usd import PRIM_TYPE, from_usd, to_usd, to_usd_keyframe_delta

pytest.importorskip("pxr", reason="the USD bridge needs the optional 'usd-core' extra")

from pxr import Gf, Usd, UsdGeom, UsdVol, Vt

RNG = np.random.default_rng(20260729)

_BAND_WIDTH = {1: 3, 2: 5, 3: 7}
_BAND_START = {1: 0, 2: 3, 3: 8}
_SH_STRIDE = {0: 1, 1: 4, 2: 9, 3: 16}


# --------------------------------------------------------------- fixture construction


def splat_arrays(n: int, *, sh_degree: int = 0) -> dict[str, np.ndarray]:
    """One prim's worth of USD attributes, as float arrays in the schema's own conventions."""
    quaternions = RNG.normal(size=(n, 4))
    quaternions /= np.linalg.norm(quaternions, axis=1, keepdims=True)
    stride = _SH_STRIDE[sh_degree]
    sh = np.zeros((n, stride, 3))
    sh[:, 0, :] = RNG.uniform(-1.5, 1.5, size=(n, 3))  # degree-0 term, inside the colour range
    for coeff in range(1, stride):
        # Inside the interval the codec quantizes onto, so the only round-trip error is the step.
        sh[:, coeff, :] = RNG.uniform(-3.0, 3.0, size=(n, 3))
    return {
        "positions": np.stack([np.linspace(-1, 1, n), np.linspace(0, 2, n), np.full(n, 0.25)], axis=1),
        "scales": np.tile(np.array([0.01, 0.02, 0.03]), (n, 1)),
        "orientations": quaternions,  # xyzw
        "opacities": np.linspace(0.1, 0.9, n),
        "sh": sh,
        "sh_degree": sh_degree,
    }


def build_stage(
    arrays: dict[str, np.ndarray],
    *,
    up_axis: str = "Y",
    meters_per_unit: float = 1.0,
    color_space: str | None = None,
    xform: dict | None = None,
    prim_type: str = PRIM_TYPE,
) -> Usd.Stage:
    """Assemble a one-prim stage from float attribute arrays."""
    stage = Usd.Stage.CreateInMemory()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y if up_axis == "Y" else UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, meters_per_unit)

    if prim_type == PRIM_TYPE:
        splat = UsdVol.ParticleField3DGaussianSplat.Define(stage, "/GaussianSplats")
        prim = splat.GetPrim()
    else:
        prim = stage.DefinePrim("/GaussianSplats", prim_type)
        splat = UsdVol.ParticleField3DGaussianSplat(prim)

    splat.CreatePositionsAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, r)) for r in arrays["positions"]]))
    splat.CreateScalesAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, r)) for r in arrays["scales"]]))
    splat.CreateOrientationsAttr(
        Vt.QuatfArray([Gf.Quatf(float(r[3]), float(r[0]), float(r[1]), float(r[2])) for r in arrays["orientations"]])
    )
    splat.CreateOpacitiesAttr(Vt.FloatArray([float(v) for v in arrays["opacities"]]))
    sh = arrays["sh"].reshape(-1, 3)
    splat.CreateRadianceSphericalHarmonicsCoefficientsAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, r)) for r in sh]))
    splat.CreateRadianceSphericalHarmonicsDegreeAttr(int(arrays["sh_degree"]))
    if color_space is not None:
        prim.SetCustomDataByKey("fourdgs:colorSpace", color_space)

    if xform:
        xformable = UsdGeom.Xformable(prim)
        if "translation" in xform:
            xformable.AddTranslateOp().Set(Gf.Vec3d(*xform["translation"]))
        if "scale" in xform:
            xformable.AddScaleOp().Set(Gf.Vec3f(*xform["scale"]))
        if "rotationZ" in xform:
            xformable.AddRotateZOp().Set(float(xform["rotationZ"]))
    return stage


def open_usd(tmp_path, stage: Usd.Stage, name: str = "scene.usda") -> str:
    path = str(tmp_path / name)
    stage.GetRootLayer().Export(path)
    return path


def read_prim(path: str):
    """The single splat prim of a written stage, plus its stage."""
    stage = Usd.Stage.Open(path)
    for prim in stage.Traverse():
        if prim.GetTypeName() == PRIM_TYPE:
            return stage, UsdVol.ParticleField3DGaussianSplat(prim)
    raise AssertionError("no splat prim in the written stage")


def attr_np(splat, getter: str) -> np.ndarray:
    return np.asarray(getattr(splat, getter)().Get(), dtype=np.float64)


def _encode(g: GaussianSet, duration: float, **metadata) -> bytes:
    buffer = io.BytesIO()
    fourdgs.write(buffer, g, duration, options=fourdgs.WriteOptions(metadata=metadata or None))
    return buffer.getvalue()


# --------------------------------------------------------------------------- import


def test_import_reads_the_schema_attributes(tmp_path):
    arrays = splat_arrays(64)
    g = from_usd(open_usd(tmp_path, build_stage(arrays))).gaussians

    assert g.count == 64
    assert np.allclose(g.positions, arrays["positions"], atol=1e-6)
    assert np.allclose(g.scales, arrays["scales"], atol=1e-6)
    assert np.allclose(g.colors[:, 3], arrays["opacities"], atol=1e-6)
    # Quaternion order is the same free choice on both sides, so nothing is shuffled.
    assert np.allclose(np.abs(g.rotations), np.abs(arrays["orientations"]), atol=1e-6)
    # The degree-0 coefficient resolves to colour on the way in: rgb = coef * k + 0.5.
    expected = np.clip(arrays["sh"][:, 0, :] * SH_C0 + 0.5, 0, 1)
    assert np.allclose(g.colors[:, :3], expected, atol=1e-6)


def test_import_is_the_degenerate_temporal_case(tmp_path):
    """A static asset is present at every instant, and says so in the temporal model."""
    imported = from_usd(open_usd(tmp_path, build_stage(splat_arrays(32))))
    g = imported.gaussians

    assert np.all(g.motions == 0)
    assert np.all(np.isinf(g.sigma_t)), "a static gaussian never fades, which is what an infinite sigma means"
    assert np.all(np.isinf(g.win_hi))
    assert imported.metadata["coordinate_system"] == "y-up-right-handed"
    assert imported.metadata["meters_per_unit"] == "1"
    assert imported.metadata["color_space"] == "linear-rec709-display"

    scene = fourdgs.read(_encode(g, 0.0))
    assert scene.header.duration_sec == 0.0
    for t in (0.0, 1.0, 1e6):
        assert len(scene.gaussians.state_at(t, scene.header.cutoff)["indices"]) == g.count


@pytest.mark.parametrize("degree", [1, 2, 3])
def test_import_carries_whole_spherical_harmonic_degrees(tmp_path, degree):
    arrays = splat_arrays(48, sh_degree=degree)
    g = from_usd(open_usd(tmp_path, build_stage(arrays))).gaussians

    rest = _BAND_START[degree] + _BAND_WIDTH[degree]
    assert g.sh_degree == degree
    assert g.sh.shape == (48, 3 * rest)

    step = (SH_QUANT_HI - SH_QUANT_LO) / 255.0
    for flat in range(rest):
        source = arrays["sh"][:, flat + 1, :]
        for channel in range(3):
            decoded = g.sh[:, channel * rest + flat] / 255.0 * (SH_QUANT_HI - SH_QUANT_LO) + SH_QUANT_LO
            assert np.max(np.abs(decoded - source[:, channel])) <= step


def test_import_reads_a_z_up_scene_without_rotating_geometry(tmp_path):
    """USD carries Z-up natively, so the geometry is untouched and the frame is metadata."""
    arrays = splat_arrays(20)
    imported = from_usd(open_usd(tmp_path, build_stage(arrays, up_axis="Z")))
    assert imported.metadata["coordinate_system"] == "z-up-right-handed"
    # Positions are verbatim: no axis flip, unlike the glTF bridge which had to rotate.
    assert np.allclose(imported.gaussians.positions, arrays["positions"], atol=1e-6)


def test_import_records_meters_per_unit(tmp_path):
    imported = from_usd(open_usd(tmp_path, build_stage(splat_arrays(8), meters_per_unit=0.01)))
    assert imported.metadata["meters_per_unit"] == "0.01"


def test_import_recovers_a_recorded_color_space(tmp_path):
    imported = from_usd(open_usd(tmp_path, build_stage(splat_arrays(8), color_space="srgb-rec709-display")))
    assert imported.metadata["color_space"] == "srgb-rec709-display"


def test_import_bakes_a_prim_transform(tmp_path):
    """Translation and uniform scale are expressible in the attributes, so they are baked."""
    arrays = splat_arrays(24)
    xform = {"translation": [1.0, -2.0, 0.5], "scale": [2.0, 2.0, 2.0]}
    g = from_usd(open_usd(tmp_path, build_stage(arrays, xform=xform))).gaussians

    assert np.allclose(g.positions, arrays["positions"] * 2.0 + np.array([1.0, -2.0, 0.5]), atol=1e-5)
    assert np.allclose(g.scales, arrays["scales"] * 2.0, atol=1e-6)


def test_import_refuses_a_non_uniform_prim_scale(tmp_path):
    stage = build_stage(splat_arrays(8), xform={"scale": [1.0, 2.0, 3.0]})
    with pytest.raises(MalformedFile, match="scales non-uniformly"):
        from_usd(open_usd(stage_dir(tmp_path), stage))


def test_import_refuses_rotating_a_prim_that_carries_higher_harmonics(tmp_path):
    stage = build_stage(splat_arrays(8, sh_degree=1), xform={"rotationZ": 30.0})
    with pytest.raises(MalformedFile, match="Wigner-D"):
        from_usd(open_usd(stage_dir(tmp_path), stage))


def test_import_refuses_a_stage_with_no_splats(tmp_path):
    stage = Usd.Stage.CreateInMemory()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    stage.DefinePrim("/cube", "Cube")
    with pytest.raises(MalformedFile, match="no prim"):
        from_usd(open_usd(tmp_path, stage))


def test_import_refuses_a_partial_degree(tmp_path):
    """A coefficient count that is not (d+1)^2 is not a whole degree."""
    arrays = splat_arrays(8, sh_degree=2)
    # Drop the last coefficient of every vertex, leaving 8 of the 9 a degree-2 prim needs.
    arrays["sh"] = arrays["sh"][:, :8, :]
    stage = build_stage(arrays)
    # The degree attribute still says 2 but the stride is now 8 -> refused as not (d+1)^2.
    with pytest.raises(MalformedFile, match="whole degree"):
        from_usd(open_usd(stage_dir(tmp_path), stage))


def stage_dir(tmp_path):
    """A fresh subdir so refusal tests that each write ``scene.usda`` do not collide."""
    d = tmp_path / f"case{np.random.default_rng().integers(1 << 30)}"
    d.mkdir()
    return d


# --------------------------------------------------------------------------- export


def temporal_scene(n: int = 96, *, sh_degree: int = 0) -> tuple[GaussianSet, float]:
    """A scene that actually moves, so a snapshot has something to get wrong."""
    quaternions = RNG.normal(size=(n, 4))
    quaternions /= np.linalg.norm(quaternions, axis=1, keepdims=True)
    rest = (_BAND_START[sh_degree] + _BAND_WIDTH[sh_degree]) if sh_degree else 0
    return (
        GaussianSet(
            positions=RNG.uniform(-1, 1, size=(n, 3)).astype(np.float32),
            scales=RNG.uniform(0.005, 0.05, size=(n, 3)).astype(np.float32),
            rotations=quaternions.astype(np.float32),
            colors=np.concatenate(
                [RNG.uniform(0.05, 0.95, size=(n, 3)), RNG.uniform(0.2, 1.0, size=(n, 1))], axis=1
            ).astype(np.float32),
            motions=RNG.uniform(-0.5, 0.5, size=(n, 3)).astype(np.float32),
            mu_t=np.full(n, 0.5, dtype=np.float32),
            sigma_t=np.full(n, np.inf, dtype=np.float32),
            win_lo=np.zeros(n, dtype=np.float32),
            win_hi=np.full(n, 1.0, dtype=np.float32),
            sh=RNG.integers(0, 256, size=(n, 3 * rest), dtype=np.uint8) if sh_degree else None,
            sh_degree=sh_degree,
        ),
        1.0,
    )


def test_export_writes_the_state_at_the_instant_asked_for(tmp_path):
    g, _ = temporal_scene()
    out = str(tmp_path / "snapshot.usda")
    at = 0.75
    to_usd(out, g, at, cutoff=0.05, coordinate_system="y-up-right-handed")

    _, splat = read_prim(out)
    written = attr_np(splat, "GetPositionsAttr")
    # Not the stored centres: the centre at `t` is the stored one carried along its velocity.
    visible = g.state_at(at, 0.05)
    assert written.shape[0] == visible["indices"].size
    expected = (
        g.positions[visible["indices"]] + g.motions[visible["indices"]] * (at - g.mu_t[visible["indices"]])[:, None]
    )
    pairing = _pair_by_position(written, expected)
    assert np.allclose(written[pairing], expected, atol=1e-5)


def test_export_declares_the_schema_and_stage_metadata(tmp_path):
    g, _ = temporal_scene(32)
    out = str(tmp_path / "snapshot.usda")
    to_usd(
        out,
        g,
        0.5,
        cutoff=0.05,
        coordinate_system="z-up-right-handed",
        color_space="linear-rec709-display",
        meters_per_unit=0.5,
    )

    stage, splat = read_prim(out)
    assert splat.GetPrim().GetTypeName() == PRIM_TYPE
    assert UsdGeom.GetStageUpAxis(stage) == "Z"
    assert UsdGeom.GetStageMetersPerUnit(stage) == 0.5
    for getter in (
        "GetPositionsAttr",
        "GetScalesAttr",
        "GetOrientationsAttr",
        "GetOpacitiesAttr",
        "GetRadianceSphericalHarmonicsCoefficientsAttr",
    ):
        assert getattr(splat, getter)().Get() is not None
    # The extent Boundable requires, so a viewer can frame the asset.
    assert splat.GetExtentAttr().Get() is not None
    assert splat.GetPrim().GetCustomDataByKey("fourdgs:colorSpace") == "linear-rec709-display"


def test_export_refuses_a_coordinate_system_it_cannot_place(tmp_path):
    g, _ = temporal_scene(8)
    with pytest.raises(MalformedFile, match="coordinate_system"):
        to_usd(str(tmp_path / "x.usda"), g, 0.5, cutoff=0.05, coordinate_system="")
    with pytest.raises(MalformedFile, match="coordinate_system"):
        to_usd(str(tmp_path / "x.usda"), g, 0.5, cutoff=0.05, coordinate_system="y-up-left-handed")


def test_export_refuses_an_empty_instant(tmp_path):
    g, _ = temporal_scene(8)
    with pytest.raises(MalformedFile, match="no gaussian is visible"):
        to_usd(str(tmp_path / "x.usda"), g, 5.0, cutoff=0.05, coordinate_system="y-up-right-handed")


def test_export_refuses_an_unpackageable_extension(tmp_path):
    g, _ = temporal_scene(8)
    with pytest.raises(MalformedFile, match="usdz"):
        to_usd(str(tmp_path / "x.usdz"), g, 0.5, cutoff=0.05, coordinate_system="y-up-right-handed")


# ------------------------------------------------------------------------- animated


def test_animated_export_writes_time_samples(tmp_path):
    """USD's advantage over glTF: the whole scene in one file that plays."""
    g, duration = temporal_scene(64)
    out = str(tmp_path / "anim.usda")
    to_usd(
        out, g, 0.0, cutoff=0.05, coordinate_system="y-up-right-handed", animated=True, fps=10.0, duration_sec=duration
    )

    stage, splat = read_prim(out)
    assert stage.GetStartTimeCode() == 0.0
    assert stage.GetEndTimeCode() == 10.0  # duration 1.0s * 10 fps
    assert stage.GetTimeCodesPerSecond() == 10.0
    samples = splat.GetPositionsAttr().GetNumTimeSamples()
    assert samples == 11, "one sample per frame over [0, 10]"

    # The count at a frame matches what the scene says is visible at that instant.
    for frame in (0, 5, 10):
        t = frame / 10.0
        visible = g.state_at(t, 0.05)["indices"].size
        got = len(splat.GetPositionsAttr().Get(Usd.TimeCode(frame)))
        assert got == visible


# ------------------------------------------------------------------------ round trip


def test_usd_roundtrip_preserves_attributes_within_the_declared_bounds(tmp_path):
    """USD -> 4dgs -> USD, checked against the intermediate file's own bounds."""
    arrays = splat_arrays(128)
    source = open_usd(tmp_path, build_stage(arrays, color_space="linear-rec709-display"))

    imported = from_usd(source)
    scene = fourdgs.read(_encode(imported.gaussians, 0.0, **imported.metadata))
    bounds = scene.quantization.bounds

    out = str(tmp_path / "roundtrip.usda")
    to_usd(
        out,
        scene.gaussians,
        0.0,
        cutoff=scene.header.cutoff,
        coordinate_system=scene.header.attributes["coordinate_system"],
        color_space=scene.header.attributes["color_space"],
        meters_per_unit=float(scene.header.attributes["meters_per_unit"]),
    )
    _, splat = read_prim(out)
    written = attr_np(splat, "GetPositionsAttr")
    pairing = _pair_by_position(written, arrays["positions"])

    assert np.max(np.abs(written[pairing] - arrays["positions"])) <= float(bounds["pos"])
    opacity = attr_np(splat, "GetOpacitiesAttr")[pairing]
    assert np.max(np.abs(opacity - arrays["opacities"])) <= float(bounds["alpha"])
    scale = attr_np(splat, "GetScalesAttr")[pairing]
    assert np.max(np.abs(scale / arrays["scales"] - 1.0)) <= float(bounds["scale_rel"])
    # The degree-0 coefficient goes out through colour and back.
    sh = attr_np(splat, "GetRadianceSphericalHarmonicsCoefficientsAttr").reshape(-1, _SH_STRIDE[0], 3)
    dc = sh[pairing, 0, :]
    assert np.max(np.abs(dc - arrays["sh"][:, 0, :])) <= float(bounds["rgb"]) / SH_C0


def test_usd_roundtrip_preserves_higher_harmonics_within_the_quantization_step(tmp_path):
    arrays = splat_arrays(64, sh_degree=3)
    imported = from_usd(open_usd(tmp_path, build_stage(arrays)))
    scene = fourdgs.read(_encode(imported.gaussians, 0.0, **imported.metadata))

    out = str(tmp_path / "sh.usda")
    to_usd(out, scene.gaussians, 0.0, cutoff=scene.header.cutoff, coordinate_system="y-up-right-handed")
    _, splat = read_prim(out)
    written = attr_np(splat, "GetPositionsAttr")
    pairing = _pair_by_position(written, arrays["positions"])
    sh = attr_np(splat, "GetRadianceSphericalHarmonicsCoefficientsAttr").reshape(-1, _SH_STRIDE[3], 3)[pairing]

    step = (SH_QUANT_HI - SH_QUANT_LO) / 255.0
    for coeff in range(1, _SH_STRIDE[3]):
        assert np.max(np.abs(sh[:, coeff, :] - arrays["sh"][:, coeff, :])) <= step


def test_4dgs_roundtrip_returns_the_canonical_state_at_the_instant(tmp_path):
    """4dgs -> USD at `t` -> 4dgs is the state at `t`, within the bounds both files declare."""
    g, duration = temporal_scene(96)
    scene = fourdgs.read(_encode(g, duration, coordinate_system="y-up-right-handed"))
    at = 0.625
    expected = scene.gaussians.state_at(at, scene.header.cutoff)

    out = str(tmp_path / "instant.usda")
    to_usd(out, scene.gaussians, at, cutoff=scene.header.cutoff, coordinate_system="y-up-right-handed")

    back = from_usd(out)
    reimported = fourdgs.read(_encode(back.gaussians, 0.0, **back.metadata))
    state = reimported.gaussians.state_at(0.0, reimported.header.cutoff)

    bounds = reimported.quantization.bounds
    assert len(state["indices"]) == len(expected["indices"])
    pairing = _pair_by_position(state["centers"], expected["centers"])
    assert np.max(np.abs(state["centers"][pairing] - expected["centers"])) <= 2 * float(bounds["pos"])
    assert np.max(np.abs(state["opacity"][pairing] - expected["opacity"])) <= 2 * float(bounds["alpha"])
    assert reimported.header.duration_sec == 0.0


def _pair_by_position(got: np.ndarray, want: np.ndarray) -> np.ndarray:
    """Match two states gaussian-for-gaussian by nearest centre.

    Gaussian order is the encoder's business — it sorts each chunk by Morton code — so the
    two files agree on the set, not on the sequence. Position identifies a gaussian across
    the round trip; the match being one-to-one is itself the assertion that nothing was
    dropped, duplicated or confused for its neighbour.
    """
    distance = np.linalg.norm(want[:, None, :] - got[None, :, :], axis=2)
    nearest = distance.argmin(axis=1)
    assert len(np.unique(nearest)) == len(nearest), "the round trip did not preserve the set of gaussians"
    return nearest


def test_cli_converts_in_both_directions(tmp_path):
    """The commands are a few lines over the library, so this checks the wiring, not the maths."""
    from fourdgs.cli import main

    source = open_usd(tmp_path, build_stage(splat_arrays(32)))
    container = str(tmp_path / "scene.4dgs")
    assert main(["from-usd", source, "-o", container]) == 0

    out = str(tmp_path / "again.usda")
    assert main(["to-usd", container, "-o", out, "-t", "0.0"]) == 0
    assert from_usd(out).gaussians.count == 32


# ---------------------------------------------------- keyframe-delta animated export


def _kd_gaussians(positions):
    n = len(positions)
    return GaussianSet(
        positions=np.asarray(positions, dtype=np.float32).reshape(n, 3),
        scales=np.full((n, 3), 0.05, dtype=np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=np.tile(np.array([0.6, 0.4, 0.2, 0.9], dtype=np.float32), (n, 1)),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.zeros(n, dtype=np.float32),
        sigma_t=np.full(n, 100.0, dtype=np.float32),
        win_lo=np.zeros(n, dtype=np.float32),
        win_hi=np.full(n, 8.0, dtype=np.float32),
    )


def _kd_churn_bytes():
    """A keyframe-delta file whose population drifts, gains id 4, then loses id 2."""
    from fourdgs import keyframe_delta_file as kdf

    samples = []
    for i in range(8):
        ids = [0, 1, 2, 3]
        base = [[i * 0.1, 0.0, 0.0], [1.0, i * 0.05, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]]
        if i >= 2:
            ids = [*ids, 4]
            base = [*base, [2.0, 2.0, i * 0.02]]
        if i >= 5 and 2 in ids:
            keep = [k for k in range(len(ids)) if ids[k] != 2]
            ids = [ids[k] for k in keep]
            base = [base[k] for k in keep]
        samples.append(Sample(t0=float(i), ids=np.array(ids), gaussians=_kd_gaussians(base)))
    return kdf.write_sequence(samples, 8.0, kd=KeyframeDeltaOptions(keyframe_every=4))


def _sample_at(splat, getter, frame):
    return np.asarray(getattr(splat, getter)().Get(Usd.TimeCode(float(frame))), dtype=np.float64)


def test_keyframe_delta_animated_export_matches_the_reconstruction_each_frame(tmp_path):
    """Every USD time sample is exactly the composed population reconstructed at that frame.

    A keyframe-delta scene has no closed-form state_at to snapshot; the export composes the
    chain per frame (keyframe_delta_file.render_at) and writes it. The only loss is float32,
    so the written sample equals the float64 reconstruction to within it — which is what
    makes the animated export a faithful flipbook rather than an approximation.
    """
    from fourdgs import keyframe_delta_file as kdf

    data = _kd_churn_bytes()
    fps = 2.0
    out = str(tmp_path / "kd.usda")
    to_usd_keyframe_delta(out, data, coordinate_system="y-up-right-handed", fps=fps)

    _, splat = read_prim(out)
    decoded = kdf.decode_streamed(data)
    for frame in range(round(8.0 * fps) + 1):
        expected = kdf.render_at(decoded, frame / fps)
        positions = _sample_at(splat, "GetPositionsAttr", frame)
        assert positions.shape[0] == expected["centers"].shape[0]
        if positions.shape[0]:
            assert np.max(np.abs(positions - expected["centers"])) <= 1e-5
            assert np.max(np.abs(_sample_at(splat, "GetScalesAttr", frame) - expected["scales"])) <= 1e-5
            assert np.max(np.abs(_sample_at(splat, "GetOpacitiesAttr", frame) - expected["opacity"])) <= 1e-5


def test_keyframe_delta_export_represents_births_and_deaths_as_varying_counts(tmp_path):
    """USD time samples permit a different length per frame, so the birth of id 4 and the
    death of id 2 show up as the sample count moving 4 -> 5 -> 4."""
    out = str(tmp_path / "churn.usda")
    to_usd_keyframe_delta(out, _kd_churn_bytes(), coordinate_system="y-up-right-handed", fps=2.0)
    _, splat = read_prim(out)
    counts = {_sample_at(splat, "GetPositionsAttr", frame).shape[0] for frame in range(17)}
    assert max(counts) == 5 and min(counts) == 4


def test_keyframe_delta_export_reads_duration_and_up_axis_from_the_scene(tmp_path):
    out = str(tmp_path / "zup.usda")
    to_usd_keyframe_delta(out, _kd_churn_bytes(), coordinate_system="z-up-right-handed", fps=1.0)
    stage, _ = read_prim(out)
    assert UsdGeom.GetStageUpAxis(stage) == UsdGeom.Tokens.z
    # The file's own 8s clock at 1 fps is nine time codes, 0..8.
    assert stage.GetEndTimeCode() == 8.0


def test_keyframe_delta_export_refuses_a_bad_fps(tmp_path):
    with pytest.raises(MalformedFile, match="positive fps"):
        to_usd_keyframe_delta(
            str(tmp_path / "x.usda"), _kd_churn_bytes(), coordinate_system="y-up-right-handed", fps=0.0
        )


def test_keyframe_delta_export_refuses_an_unwritable_extension(tmp_path):
    with pytest.raises(MalformedFile, match="usda"):
        to_usd_keyframe_delta(str(tmp_path / "x.gltf"), _kd_churn_bytes(), coordinate_system="y-up-right-handed")


def test_cli_to_usd_routes_a_keyframe_delta_file_to_the_animated_path(tmp_path):
    """`fourdgs to-usd` on a keyframe-delta file exports animated time samples.

    The ordinary reader refuses a keyframe-delta file, so the command peeks the Header's
    temporal model and routes to the animated exporter rather than the static snapshot.
    """
    import types

    from fourdgs import cli

    source = tmp_path / "kd.4dgs"
    source.write_bytes(_kd_churn_bytes())
    out = tmp_path / "kd.usda"
    args = types.SimpleNamespace(
        file=str(source),
        out=str(out),
        time=0.0,
        coordinate_system="y-up-right-handed",
        color_space=None,
        meters_per_unit=None,
        sh_degree=3,
        animated=False,  # ignored for keyframe-delta: it has no static snapshot
        fps=2.0,
    )
    assert cli.cmd_to_usd(args) == 0
    stage, _ = read_prim(str(out))
    # 8s at 2 fps is time codes 0..16, so the export is genuinely animated.
    assert stage.GetEndTimeCode() == 16.0


def test_cli_to_usd_still_snapshots_a_gaussian_birth_file(tmp_path):
    """The dispatch does not disturb the gaussian-birth path: it still writes a snapshot."""
    import types

    from fourdgs import cli

    g, duration = temporal_scene(48)
    source = tmp_path / "gb.4dgs"
    source.write_bytes(_encode(g, duration, coordinate_system="y-up-right-handed"))
    out = tmp_path / "gb.usda"
    args = types.SimpleNamespace(
        file=str(source),
        out=str(out),
        time=0.5,
        coordinate_system=None,
        color_space=None,
        meters_per_unit=None,
        sh_degree=3,
        animated=False,
        fps=30.0,
    )
    assert cli.cmd_to_usd(args) == 0
    stage, _ = read_prim(str(out))
    # A snapshot writes default values, not a time-sampled range.
    assert stage.GetEndTimeCode() == 0.0
