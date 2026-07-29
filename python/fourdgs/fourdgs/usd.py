# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Interoperability with OpenUSD's ``UsdVolParticleField3DGaussianSplat`` schema.

That schema, added in OpenUSD **v26.03** through the AOUSD Emerging Geometry Interest
Group, describes a **static** set of gaussians as a first-class USD prim. This format
describes a temporal one whose reconstructed state at any single instant is exactly the
attribute set the schema carries. So, like the glTF bridge, this one runs in both
directions and is not symmetric — but USD is a richer target than glTF in two ways this
module exploits:

* USD carries **Z-up natively** (stage ``upAxis`` metadata), so a Z-up scene needs no
  geometry rotation and no Wigner-D rotation of its harmonics — unlike glTF, where the
  axis change rode on a node transform. Coordinate systems round-trip through the stage's
  own metadata.
* USD attributes can be **time-sampled**, so ``to_usd(..., animated=True)`` writes the
  whole scene as one file that plays — a per-frame flipbook of reconstructions — rather
  than the single snapshot glTF is limited to. What USD's *static* schema still cannot
  carry is the *continuous* temporal model (per-gaussian velocity, birth time, extent and
  validity window); those are resolved away into discrete frames, exactly as any renderer
  sampling the scene would see them.

The schema was verified against **openusd.org / PixarAnimationStudios/OpenUSD** at USD
**26.08**, and against the reference PLY->USD converter
``extras/imaging/examples/hdParticleField/py3dgsPlyToUsd.py``. The attributes and their
mappings, verbatim:

===========================  ===========  ====================================================
USD attribute                type         mapping to this format
===========================  ===========  ====================================================
``positions``                point3f[]    identical (stage frame; no axis flip)
``scales``                   float3[]     identical — per-axis, linear (USD stores the
                                          activated scale, not the log; ``exp`` already applied)
``orientations``             quatf[]      identical — the quatf's (real, i, j, k) reads as
                                          xyzw once numpy-converted, the same free choice this
                                          format made, so no component moves
``opacities``                float[]      identical — activated (post-sigmoid) 0..1, not a logit
``radiance:sphericalHarmonicsCoefficients``  float3[]  per-vertex flattened, DC first: the
                                          degree-0 term is coefficient 0 and resolves to colour
                                          (rgb = coef*k + 0.5); the rest map to this format's
                                          byte-quantized bands
``radiance:sphericalHarmonicsDegree``  int  the highest whole degree present
===========================  ===========  ====================================================

The USD stage carries ``upAxis`` (Y or Z) and ``metersPerUnit``; both round-trip through
the stage metadata rather than being baked into geometry. ``pxr`` (``usd-core``) is an
optional dependency — import it through :func:`_require_pxr`, which names the extra to
install rather than letting an ``ImportError`` escape raw.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .convert import SH_C0
from .exceptions import InvalidInput, MalformedFile
from .gltf import (
    _SH_BAND_START,
    _SH_BAND_WIDTH,
    _decompose,
    _join,
    _matrix_quaternion,
    _quaternion_multiply,
)
from .model import GaussianSet
from .quantization import SH_QUANT_HI, SH_QUANT_LO

#: The concrete prim type this bridge reads and writes.
PRIM_TYPE = "ParticleField3DGaussianSplat"

#: Coordinate systems this converter can place on a USD stage. USD is always right-handed,
#: so only the up axis varies, and it is the stage's ``upAxis`` metadata rather than a
#: transform on the geometry. Anything else is refused rather than guessed at — a silently
#: mis-oriented scene reads as a modelling mistake, not a conversion bug.
_COORD_TO_UP_AXIS = {
    "y-up-right-handed": "Y",
    "z-up-right-handed": "Z",
}
_UP_AXIS_TO_COORD = {"Y": "y-up-right-handed", "Z": "z-up-right-handed"}

#: What a USD 3DGS asset that carries no colour-space provenance is taken to mean. The
#: schema's radiance is spherical-harmonic coefficients defined in linear light and has no
#: colour-space token, so a plain USD asset is read as linear. A `.4dgs` exported to USD
#: records its own ``color_space`` in prim ``customData`` (below) so the round trip does
#: not lose it — USD has nowhere native to put it.
DEFAULT_COLOR_SPACE = "linear-rec709-display"

#: Where the round-trip metadata USD cannot express natively is stashed. ``coordinate_system``
#: and ``meters_per_unit`` are *not* here — they are the stage's own ``upAxis`` and
#: ``metersPerUnit``, read and written through the standard USD calls.
_CD_COLOR_SPACE = "fourdgs:colorSpace"
_CD_TIME_SEC = "fourdgs:timeSec"

#: Stride of the flattened per-vertex coefficient array, including the degree-0 term, for
#: each whole degree: (degree + 1) squared. The rest-coefficient count this format stores
#: is one less: ``_SH_BAND_START[d] + _SH_BAND_WIDTH[d]``.
_SH_STRIDE = {0: 1, 1: 4, 2: 9, 3: 16}


def _require_pxr():
    """Import ``pxr`` or explain, in one sentence, how to get it.

    ``usd-core`` is the reference USD runtime and the only honest way to read a binary
    ``.usdc``/``.usdz`` crate; it is heavy, so this format keeps it an optional extra. The
    import lives here rather than at module scope so ``import fourdgs`` costs nothing when
    the extra is not installed, and the CLI can catch this and print it cleanly.
    """
    try:
        from pxr import Gf, Usd, UsdGeom, UsdVol, Vt
    except ImportError as exc:  # pragma: no cover - exercised by the skip path, not asserted
        raise InvalidInput(
            "reading or writing USD needs the 'usd-core' package, which is an optional extra. "
            "Install it with: pip install 'fourdgs[usd]'"
        ) from exc
    return Gf, Usd, UsdGeom, UsdVol, Vt


@dataclass
class UsdImport:
    """A static USD gaussian-splat asset, read into this format's vocabulary.

    ``metadata`` is what belongs in the Header's attributes map: the coordinate system
    (from the stage ``upAxis``), the length unit (from ``metersPerUnit``), and the colour
    space recovered from the prim's ``customData`` or defaulted to linear.
    """

    gaussians: GaussianSet
    metadata: dict[str, str]


# --------------------------------------------------------------------------- import


def from_usd(path: str) -> UsdImport:
    """Read a static ``ParticleField3DGaussianSplat`` USD asset into a single-keyframe scene.

    The result is the degenerate temporal case this format already supports: every
    gaussian has zero velocity, an infinite sigma so it never fades, and a validity window
    of ``[0, inf)`` so it is present at every instant a caller asks for. Write it with
    ``duration_sec = 0`` — there is nothing to play. Reads ``.usd``, ``.usda``, ``.usdc``
    and ``.usdz``; the binary crate and the package need the ``pxr`` runtime, which is why
    this format does not hand-roll a reader for them.
    """
    # Import needs no Gf/Vt constructors — it only reads, so those two go unbound here.
    _gf, Usd, UsdGeom, UsdVol, _vt = _require_pxr()

    stage = Usd.Stage.Open(path)
    if stage is None:
        raise MalformedFile(f"USD: '{path}' did not open as a USD stage")

    up_axis = UsdGeom.GetStageUpAxis(stage)
    if up_axis not in _UP_AXIS_TO_COORD:
        raise MalformedFile(
            f"USD: stage declares upAxis '{up_axis}', which is neither 'Y' nor 'Z'; this converter "
            "will not guess a coordinate system for it"
        )
    meters_per_unit = float(UsdGeom.GetStageMetersPerUnit(stage))
    if not np.isfinite(meters_per_unit) or meters_per_unit <= 0:
        raise MalformedFile(f"USD: stage declares metersPerUnit {meters_per_unit}, which is not a positive length")

    parts: list[dict] = []
    color_spaces: set[str] = set()
    for prim in stage.Traverse():
        if prim.GetTypeName() != PRIM_TYPE:
            continue
        splat = UsdVol.ParticleField3DGaussianSplat(prim)
        where = f"prim {prim.GetPath()}"
        parts.append(_read_prim(Usd, UsdGeom, splat, prim, where))
        color_spaces.add(_color_space_of(prim))

    if not parts:
        raise MalformedFile(f"USD: no prim in this stage is a {PRIM_TYPE}, so it holds no gaussian splats")
    if len(color_spaces) > 1:
        raise MalformedFile(
            f"USD: the stage mixes colour spaces {sorted(color_spaces)}. This format declares one for the "
            "whole scene, and converting between them here would change the colours the asset ships."
        )

    return UsdImport(
        gaussians=_join(parts),
        metadata={
            "coordinate_system": _UP_AXIS_TO_COORD[up_axis],
            "meters_per_unit": _format_float(meters_per_unit),
            "color_space": next(iter(color_spaces)),
            "source": f"imported from {PRIM_TYPE} USD",
        },
    )


def _color_space_of(prim) -> str:
    """The colour space a `.4dgs`-exported prim recorded, or the schema's implied linear."""
    declared = prim.GetCustomDataByKey(_CD_COLOR_SPACE)
    return str(declared) if declared else DEFAULT_COLOR_SPACE


def _read_prim(Usd, UsdGeom, splat, prim, where: str) -> dict:
    """One splat prim's attributes, with the prim's world transform baked in.

    Mirrors the glTF bridge's node-transform handling exactly, because the problem is the
    same one: a transform on the prim participates in the covariance the schema defines, so
    an importer either carries it exactly or refuses it. Translation and uniform scale bake
    into position and scale; a rotation bakes into position and the gaussians' quaternions
    but only when there are no harmonics above degree 0 (rotating those needs Wigner-D,
    which this converter does not implement); non-uniform scale, shear, mirror and
    projective transforms are refused because they are not another gaussian's own shape.
    """
    positions = _read_vec3(splat.GetPositionsAttr(), splat.GetPositionshAttr(), where, "positions")
    n = positions.shape[0]
    if n == 0:
        raise MalformedFile(f"USD: {where} has an empty positions array")
    scales = _read_vec3(splat.GetScalesAttr(), splat.GetScaleshAttr(), where, "scales")
    orientations = _read_quat(splat.GetOrientationsAttr(), splat.GetOrientationshAttr(), where)
    opacity = _read_scalar(splat.GetOpacitiesAttr(), splat.GetOpacitieshAttr(), where, "opacities")

    for name, array in (("scales", scales), ("orientations", orientations), ("opacities", opacity)):
        if array.shape[0] != n:
            raise MalformedFile(f"USD: {where} has {n} positions but {array.shape[0]} {name}")

    if np.any(scales < 0):
        raise MalformedFile(f"USD: {where} has a negative scale, which is not a gaussian's extent")
    if np.any(opacity < -1e-6) or np.any(opacity > 1 + 1e-6):
        raise MalformedFile(
            f"USD: {where} has an opacity outside [0, 1]; this schema stores the activated value, not a logit"
        )
    norms = np.linalg.norm(orientations, axis=1, keepdims=True)
    if np.any(norms < 1e-6):
        raise MalformedFile(f"USD: {where} has a zero-length orientation quaternion")
    orientations = orientations / norms

    degree, sh, rgb = _read_sh(splat, prim, n, where)
    colors = np.concatenate([rgb, opacity[:, None]], axis=1)

    world = np.asarray(
        UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default()), dtype=np.float64
    ).T  # USD is row-vector/row-major; transpose gives the column-vector matrix _decompose expects.
    rotation, scale, translation = _decompose(world, where)
    identity_rotation = np.allclose(rotation, np.eye(3), atol=1e-6)
    if not identity_rotation and degree > 0:
        raise MalformedFile(
            f"USD: {where} carries degree-{degree} spherical harmonics under a rotating prim transform. "
            "Baking that rotation means rotating the harmonics too (Wigner-D), which this converter does not "
            "implement; bake the prim transform into the attributes, or author it without a rotation."
        )
    positions = positions * scale @ rotation.T + translation
    scales = scales * scale
    if not identity_rotation:
        orientations = _quaternion_multiply(np.broadcast_to(_matrix_quaternion(rotation), (n, 4)), orientations)

    return {
        "positions": positions,
        "scales": scales,
        "rotations": orientations,
        "colors": colors,
        "sh": sh,
        "sh_degree": degree,
    }


def _read_sh(splat, prim, n: int, where: str) -> tuple[int, np.ndarray | None, np.ndarray]:
    """Resolve the radiance: degree-0 term to colour, higher degrees to this format's bands.

    USD stores the coefficients as a flat per-vertex list of vec3s, ``stride`` of them per
    vertex with the degree-0 term first; ``stride`` is ``(degree + 1)**2``. The degree-0
    term resolves to colour the same way the PLY importer and glTF bridge resolve it
    (``rgb = coef*k + 0.5``); the rest quantize onto this format's byte bands.
    """
    coeffs = _read_sh_coefficients(splat, where)
    if coeffs is None:
        raise MalformedFile(
            f"USD: {where} has no radiance:sphericalHarmonicsCoefficients, which a gaussian-splat prim needs for "
            "its appearance"
        )
    if coeffs.shape[0] % n != 0:
        raise MalformedFile(
            f"USD: {where} has {n} positions but {coeffs.shape[0]} spherical-harmonic coefficients, which is not a "
            "whole number of per-vertex strides"
        )
    stride = coeffs.shape[0] // n
    degree = _stride_to_degree(stride, splat, where)
    per_vertex = coeffs.reshape(n, stride, 3)

    dc = per_vertex[:, 0, :]
    rgb = np.clip(dc * SH_C0 + 0.5, 0.0, 1.0)
    if degree == 0:
        return 0, None, rgb

    rest_count = _SH_BAND_START[degree] + _SH_BAND_WIDTH[degree]
    out = np.zeros((n, 3 * rest_count), dtype=np.uint8)
    span = SH_QUANT_HI - SH_QUANT_LO
    for flat in range(rest_count):
        values = per_vertex[:, flat + 1, :]
        quantized = np.clip(np.rint((values - SH_QUANT_LO) / span * 255.0), 0, 255).astype(np.uint8)
        for channel in range(3):
            out[:, channel * rest_count + flat] = quantized[:, channel]
    return degree, out, rgb


def _stride_to_degree(stride: int, splat, where: str) -> int:
    """The whole degree a per-vertex coefficient stride implies, cross-checked with the attribute."""
    degrees = {v: k for k, v in _SH_STRIDE.items()}
    if stride not in degrees:
        raise MalformedFile(
            f"USD: {where} stores {stride} spherical-harmonic coefficients per vertex, which is not (d+1)^2 for a "
            f"whole degree d; expected one of {sorted(_SH_STRIDE.values())}"
        )
    degree = degrees[stride]
    declared = splat.GetRadianceSphericalHarmonicsDegreeAttr().Get()
    if declared is not None and int(declared) != degree:
        raise MalformedFile(
            f"USD: {where} declares radiance:sphericalHarmonicsDegree {int(declared)} but stores {stride} "
            f"coefficients per vertex, which is degree {degree}"
        )
    return degree


def _read_sh_coefficients(splat, where: str) -> np.ndarray | None:
    for attr in (
        splat.GetRadianceSphericalHarmonicsCoefficientsAttr(),
        splat.GetRadianceSphericalHarmonicsCoefficientshAttr(),
    ):
        value = attr.Get()
        if value is not None:
            return _as_float(value, where, "radiance:sphericalHarmonicsCoefficients", 3)
    return None


# --------------------------------------------------------- attribute reading helpers


def _read_vec3(attr, half_attr, where: str, name: str) -> np.ndarray:
    value = attr.Get()
    if value is None and half_attr is not None:
        value = half_attr.Get()
    if value is None:
        raise MalformedFile(f"USD: {where} has no {name} attribute, which a gaussian-splat prim requires")
    return _as_float(value, where, name, 3)


def _read_scalar(attr, half_attr, where: str, name: str) -> np.ndarray:
    value = attr.Get()
    if value is None and half_attr is not None:
        value = half_attr.Get()
    if value is None:
        raise MalformedFile(f"USD: {where} has no {name} attribute, which a gaussian-splat prim requires")
    return np.asarray(value, dtype=np.float64).reshape(-1)


def _read_quat(attr, half_attr, where: str) -> np.ndarray:
    value = attr.Get()
    if value is None and half_attr is not None:
        value = half_attr.Get()
    if value is None:
        raise MalformedFile(f"USD: {where} has no orientations attribute, which a gaussian-splat prim requires")
    # A pxr quatf array converts to (n, 4) as (i, j, k, real) = xyzw, which is exactly the
    # order this format stores, so no component is shuffled — the same free choice on both sides.
    array = np.asarray(value, dtype=np.float64)
    if array.ndim != 2 or array.shape[1] != 4:
        raise MalformedFile(f"USD: {where} orientations did not read as (n, 4) quaternions")
    return array


def _as_float(value, where: str, name: str, width: int) -> np.ndarray:
    array = np.asarray(value, dtype=np.float64)
    if array.ndim != 2 or array.shape[1] != width:
        raise MalformedFile(f"USD: {where} attribute {name} did not read as (n, {width})")
    return array


# ---------------------------------------------------------------------------- export


def to_usd(
    path: str,
    gaussians: GaussianSet,
    time_sec: float,
    *,
    cutoff: float,
    coordinate_system: str,
    color_space: str | None = None,
    meters_per_unit: float = 1.0,
    max_sh_degree: int = 3,
    animated: bool = False,
    fps: float = 30.0,
    duration_sec: float = 0.0,
) -> int:
    """Write the scene to a ``ParticleField3DGaussianSplat`` USD asset.

    Two modes, and the difference is the whole point of USD as a target:

    * **snapshot** (``animated=False``, the default): the reconstructed state at
      ``time_sec`` as static attribute values. This is glTF's only option, and it behaves
      the same — velocity, birth time and validity windows end here.
    * **animated** (``animated=True``): the scene resolved at each frame over
      ``[0, duration_sec]`` at ``fps``, written as USD **time samples** — one file that
      plays. Each frame is an independent reconstruction, so per-frame gaussian counts vary
      (USD time samples permit that); a renderer holds each frame until the next rather than
      interpolating between differently-sized sets. This is a genuine temporal export, not a
      snapshot, and the advantage USD's time-sampled attributes give over glTF.

    ``cutoff`` is the file's own marginal threshold, from its Header; passing a different one
    selects a different set of visible gaussians than the file says. Writes ``.usd``,
    ``.usda`` or ``.usdc`` by extension. Returns the number of bytes written.
    """
    Gf, Usd, UsdGeom, UsdVol, Vt = _require_pxr()

    up_axis = _COORD_TO_UP_AXIS.get(coordinate_system)
    if up_axis is None:
        raise MalformedFile(
            f"the scene declares coordinate_system '{coordinate_system}', which this converter cannot place on a "
            f"USD stage. Known values are {sorted(_COORD_TO_UP_AXIS)} (USD is right-handed and carries the up axis "
            "as stage metadata); a file that declares none has to say which it means before it can be exported."
        )
    if meters_per_unit <= 0 or not np.isfinite(meters_per_unit):
        raise MalformedFile(f"meters_per_unit must be a positive length, not {meters_per_unit}")
    if color_space is None:
        color_space = DEFAULT_COLOR_SPACE
    lower = path.lower()
    if not lower.endswith((".usd", ".usda", ".usdc")):
        raise MalformedFile(
            f"USD export writes '.usd', '.usda' or '.usdc'; '{path}' is none of these. (Reading also accepts "
            "'.usdz', but packaging one on export is out of this bridge's scope.)"
        )

    stage = Usd.Stage.CreateInMemory()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y if up_axis == "Y" else UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, float(meters_per_unit))
    splat = UsdVol.ParticleField3DGaussianSplat.Define(stage, "/GaussianSplats")
    prim = splat.GetPrim()
    prim.SetCustomDataByKey(_CD_COLOR_SPACE, color_space)

    degree = min(gaussians.sh_degree, max_sh_degree) if gaussians.sh is not None else 0
    stored_coeffs = (gaussians.sh.shape[1] // 3) if gaussians.sh is not None else 0
    splat.CreateRadianceSphericalHarmonicsDegreeAttr(degree)

    if animated:
        _write_animated(
            Gf, Usd, Vt, splat, gaussians, degree, stored_coeffs, cutoff=cutoff, fps=fps, duration_sec=duration_sec
        )
    else:
        _write_snapshot(Gf, Usd, Vt, splat, prim, gaussians, degree, stored_coeffs, time_sec=time_sec, cutoff=cutoff)

    stage.GetRootLayer().Export(path)
    with open(path, "rb") as fh:
        return len(fh.read())


def _write_snapshot(Gf, Usd, Vt, splat, prim, gaussians, degree, stored_coeffs, *, time_sec: float, cutoff: float):
    state = gaussians.state_at(time_sec, cutoff)
    index = state["indices"]
    if index.size == 0:
        raise MalformedFile(
            f"no gaussian is visible at t={time_sec}s, so the snapshot would be empty. The scene runs over its "
            "own duration; pick an instant inside it."
        )
    prim.SetCustomDataByKey(_CD_TIME_SEC, float(time_sec))
    _set_frame(Gf, Vt, splat, gaussians, index, state["centers"], state["opacity"], degree, stored_coeffs)


def _write_animated(
    Gf, Usd, Vt, splat, gaussians, degree, stored_coeffs, *, cutoff: float, fps: float, duration_sec: float
):
    if fps <= 0 or not np.isfinite(fps):
        raise MalformedFile(f"animated export needs a positive fps, not {fps}")
    if duration_sec < 0 or not np.isfinite(duration_sec):
        raise MalformedFile(f"animated export needs a finite, non-negative duration, not {duration_sec}")
    stage = splat.GetPrim().GetStage()
    frames = round(duration_sec * fps)
    stage.SetTimeCodesPerSecond(float(fps))
    stage.SetStartTimeCode(0.0)
    stage.SetEndTimeCode(float(frames))

    wrote_any = False
    for frame in range(frames + 1):
        t = frame / fps
        state = gaussians.state_at(t, cutoff)
        index = state["indices"]
        time_code = Usd.TimeCode(float(frame))
        if index.size == 0:
            # A frame with nothing visible is a real state of the scene, written as empty
            # arrays so the flipbook does not silently hold the previous frame over a gap.
            _set_frame(
                Gf, Vt, splat, gaussians, index, state["centers"], state["opacity"], degree, stored_coeffs, time_code
            )
            continue
        wrote_any = True
        _set_frame(
            Gf, Vt, splat, gaussians, index, state["centers"], state["opacity"], degree, stored_coeffs, time_code
        )

    if not wrote_any:
        raise MalformedFile(
            f"no gaussian is visible at any frame over [0, {duration_sec}]s at {fps} fps, so the animation would "
            "be empty; check the duration and fps against the scene's own clock."
        )


def _set_frame(Gf, Vt, splat, gaussians, index, centers, opacity, degree, stored_coeffs, time_code=None):
    """Write one reconstructed state onto the prim, at the default value or a time sample."""
    n = int(index.size)
    centers = np.asarray(centers, dtype=np.float64).reshape(n, 3)
    scales = gaussians.scales[index].astype(np.float64)
    rotations = gaussians.rotations[index].astype(np.float64)
    opacity = np.clip(np.asarray(opacity, dtype=np.float64), 0.0, 1.0).reshape(n)
    rgb = gaussians.colors[index, :3].astype(np.float64)

    positions_vt = Vt.Vec3fArray([Gf.Vec3f(*(float(v) for v in row)) for row in centers])
    scales_vt = Vt.Vec3fArray([Gf.Vec3f(*(float(v) for v in row)) for row in scales])
    # xyzw back to the quatf's (real, i, j, k) argument order.
    orient_vt = Vt.QuatfArray(
        [Gf.Quatf(float(row[3]), float(row[0]), float(row[1]), float(row[2])) for row in rotations]
    )
    opacity_vt = Vt.FloatArray([float(v) for v in opacity])

    sh_vt = _sh_array(Gf, Vt, gaussians, index, rgb, degree, stored_coeffs)
    extent = _extent(Gf, Vt, centers)

    if time_code is None:
        splat.CreatePositionsAttr(positions_vt)
        splat.CreateScalesAttr(scales_vt)
        splat.CreateOrientationsAttr(orient_vt)
        splat.CreateOpacitiesAttr(opacity_vt)
        splat.CreateRadianceSphericalHarmonicsCoefficientsAttr(sh_vt)
        splat.CreateExtentAttr(extent)
    else:
        splat.CreatePositionsAttr().Set(positions_vt, time_code)
        splat.CreateScalesAttr().Set(scales_vt, time_code)
        splat.CreateOrientationsAttr().Set(orient_vt, time_code)
        splat.CreateOpacitiesAttr().Set(opacity_vt, time_code)
        splat.CreateRadianceSphericalHarmonicsCoefficientsAttr().Set(sh_vt, time_code)
        splat.CreateExtentAttr().Set(extent, time_code)


def _sh_array(Gf, Vt, gaussians, index, rgb, degree, stored_coeffs):
    """The flattened per-vertex coefficient list USD wants: DC first, then this format's bands."""
    n = int(index.size)
    stride = _SH_STRIDE[degree]
    per_vertex = np.zeros((n, stride, 3), dtype=np.float64)
    # The degree-0 coefficient, recovered from the colour this format resolved.
    per_vertex[:, 0, :] = (rgb - 0.5) / SH_C0
    if degree:
        span = SH_QUANT_HI - SH_QUANT_LO
        rest_count = _SH_BAND_START[degree] + _SH_BAND_WIDTH[degree]
        sh = gaussians.sh[index]
        for flat in range(rest_count):
            columns = [channel * stored_coeffs + flat for channel in range(3)]
            per_vertex[:, flat + 1, :] = sh[:, columns].astype(np.float64) / 255.0 * span + SH_QUANT_LO
    flat = per_vertex.reshape(n * stride, 3)
    return Vt.Vec3fArray([Gf.Vec3f(float(a), float(b), float(c)) for a, b, c in flat])


def _extent(Gf, Vt, centers: np.ndarray):
    """The prim's bounding extent, which Boundable requires and a viewer needs to frame it."""
    if centers.shape[0] == 0:
        return Vt.Vec3fArray([Gf.Vec3f(0.0, 0.0, 0.0), Gf.Vec3f(0.0, 0.0, 0.0)])
    lo = centers.min(axis=0)
    hi = centers.max(axis=0)
    return Vt.Vec3fArray([Gf.Vec3f(*(float(v) for v in lo)), Gf.Vec3f(*(float(v) for v in hi))])


def _format_float(value: float) -> str:
    """A round-trippable string for a metadata float, without a trailing ``.0`` on integers."""
    if value == int(value):
        return str(int(value))
    return repr(value)
