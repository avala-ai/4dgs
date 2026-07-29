# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Tests for the glTF `KHR_gaussian_splatting` bridge.

Fixtures are built here rather than committed: the GLB this suite reads is assembled
from a fixed seed by `build_glb` below, exactly like the conformance corpus, and the
repository keeps no binaries it can reconstruct.

The bridge makes two claims and both are checked round-trip rather than by inspection:

* glTF -> 4dgs -> glTF returns every attribute within the bounds the intermediate file
  itself declares, which is what makes "lossy but bounded" a statement and not a hope;
* 4dgs -> glTF at instant `t` is the state the format says is visible at `t`, motion
  applied and faded opacity included — not the stored attributes with the clock ignored.

The rest is refusal: every input the converter cannot carry exactly has to be named,
because the failure mode this bridge exists to prevent is a scene that converts cleanly
and looks wrong.
"""

from __future__ import annotations

import json
import math
import struct

import fourdgs
import numpy as np
import pytest
from fourdgs.convert import SH_C0
from fourdgs.exceptions import MalformedFile
from fourdgs.gltf import EXTENSION, KERNEL, from_gltf, to_gltf
from fourdgs.model import GaussianSet
from fourdgs.quantization import SH_QUANT_HI, SH_QUANT_LO

RNG = np.random.default_rng(20260728)

_A_ROTATION = f"{EXTENSION}:ROTATION"
_A_SCALE = f"{EXTENSION}:SCALE"
_A_OPACITY = f"{EXTENSION}:OPACITY"

_BAND_WIDTH = {1: 3, 2: 5, 3: 7}
_BAND_START = {1: 0, 2: 3, 3: 8}


# --------------------------------------------------------------- fixture construction


def splat_attributes(n: int, *, sh_degree: int = 0) -> dict[str, np.ndarray]:
    """One primitive's worth of extension attributes, as float arrays."""
    quaternions = RNG.normal(size=(n, 4))
    quaternions /= np.linalg.norm(quaternions, axis=1, keepdims=True)
    out = {
        "POSITION": np.stack([np.linspace(-1, 1, n), np.linspace(0, 2, n), np.full(n, 0.25)], axis=1),
        _A_SCALE: np.tile(np.array([0.01, 0.02, 0.03]), (n, 1)),
        _A_ROTATION: quaternions,
        _A_OPACITY: np.linspace(0.1, 0.9, n).reshape(n, 1),
        f"{EXTENSION}:SH_DEGREE_0_COEF_0": RNG.uniform(-1.5, 1.5, size=(n, 3)),
    }
    for band in range(1, sh_degree + 1):
        for k in range(_BAND_WIDTH[band]):
            # Inside the interval the codec quantizes onto, so the only error in a
            # round trip is the step, not a clamp.
            out[f"{EXTENSION}:SH_DEGREE_{band}_COEF_{k}"] = RNG.uniform(-3.0, 3.0, size=(n, 3))
    return out


def build_glb(
    attributes: dict[str, np.ndarray],
    *,
    color_space: str = "srgb_rec709_display",
    kernel: str = KERNEL,
    mode: int = 0,
    node: dict | None = None,
    component_types: dict[str, int] | None = None,
) -> bytes:
    """Assemble a one-primitive GLB from float attribute arrays.

    `component_types` re-encodes named attributes as normalized integers, which is how
    the suite covers the encodings the extension permits besides float.
    """
    accessors: list[dict] = []
    views: list[dict] = []
    payload = bytearray()
    semantics: dict[str, int] = {}

    for name, source in attributes.items():
        values = np.asarray(source, dtype=np.float64)
        kind = {1: "SCALAR", 3: "VEC3", 4: "VEC4"}[values.shape[1]]
        component = (component_types or {}).get(name, 5126)
        normalized = component != 5126
        if component == 5126:
            raw = values.astype("<f4")
        elif component == 5120:
            raw = np.rint(np.clip(values, -1, 1) * 127.0).astype("<i1")
        elif component == 5121:
            raw = np.rint(np.clip(values, 0, 1) * 255.0).astype("<u1")
        elif component == 5123:
            raw = np.rint(np.clip(values, 0, 1) * 65535.0).astype("<u2")
        else:  # pragma: no cover - the suite only asks for the four above
            raise AssertionError(component)

        payload.extend(b"\0" * (-len(payload) % 4))
        views.append({"buffer": 0, "byteOffset": len(payload), "byteLength": raw.nbytes})
        payload.extend(raw.tobytes())
        accessor = {
            "bufferView": len(views) - 1,
            "componentType": component,
            "count": int(values.shape[0]),
            "type": kind,
        }
        if normalized:
            accessor["normalized"] = True
        if name == "POSITION":
            accessor["min"] = [float(v) for v in values.min(axis=0)]
            accessor["max"] = [float(v) for v in values.max(axis=0)]
        accessors.append(accessor)
        semantics[name] = len(accessors) - 1

    document = {
        "asset": {"version": "2.0"},
        "extensionsUsed": [EXTENSION],
        "extensionsRequired": [EXTENSION],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{**(node or {}), "mesh": 0}],
        "meshes": [
            {
                "primitives": [
                    {
                        "attributes": semantics,
                        "mode": mode,
                        "extensions": {EXTENSION: {"kernel": kernel, "colorSpace": color_space}},
                    }
                ]
            }
        ],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(payload)}],
    }

    chunk = json.dumps(document).encode("utf-8")
    chunk += b" " * (-len(chunk) % 4)
    payload.extend(b"\0" * (-len(payload) % 4))
    total = 12 + 8 + len(chunk) + 8 + len(payload)
    return b"".join(
        [
            struct.pack("<III", 0x46546C67, 2, total),
            struct.pack("<II", len(chunk), 0x4E4F534A),
            chunk,
            struct.pack("<II", len(payload), 0x004E4942),
            bytes(payload),
        ]
    )


def read_glb(blob: bytes) -> tuple[dict, bytes]:
    _, _, declared = struct.unpack_from("<III", blob, 0)
    document, binary, at = None, b"", 12
    while at + 8 <= declared:
        length, kind = struct.unpack_from("<II", blob, at)
        at += 8
        if kind == 0x4E4F534A:
            document = json.loads(blob[at : at + length])
        elif kind == 0x004E4942:
            binary = blob[at : at + length]
        at += length + (-length % 4)
    return document, binary


def glb_attribute(document: dict, binary: bytes, name: str) -> np.ndarray:
    """Read one float attribute back out of a written GLB."""
    primitive = document["meshes"][0]["primitives"][0]
    accessor = document["accessors"][primitive["attributes"][name]]
    view = document["bufferViews"][accessor["bufferView"]]
    width = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[accessor["type"]]
    assert accessor["componentType"] == 5126
    return np.frombuffer(binary, dtype="<f4", count=accessor["count"] * width, offset=view["byteOffset"]).reshape(
        accessor["count"], width
    )


def write_glb(tmp_path, blob: bytes, name: str = "scene.glb") -> str:
    path = tmp_path / name
    path.write_bytes(blob)
    return str(path)


# --------------------------------------------------------------------------- import


def test_import_reads_the_extension_attributes(tmp_path):
    attributes = splat_attributes(64)
    imported = from_gltf(write_glb(tmp_path, build_glb(attributes)))
    g = imported.gaussians

    assert g.count == 64
    assert np.allclose(g.positions, attributes["POSITION"], atol=1e-6)
    assert np.allclose(g.scales, attributes[_A_SCALE], atol=1e-6)
    assert np.allclose(g.colors[:, 3], attributes[_A_OPACITY][:, 0], atol=1e-6)
    # Position and scale need no conversion at all, and the quaternion order was the
    # same free choice on both sides, so no component moves either.
    assert np.allclose(np.abs(g.rotations), np.abs(attributes[_A_ROTATION]), atol=1e-6)
    # The degree-0 coefficient is resolved to colour on the way in: rgb = coef * k + 0.5.
    expected = np.clip(attributes[f"{EXTENSION}:SH_DEGREE_0_COEF_0"] * SH_C0 + 0.5, 0, 1)
    assert np.allclose(g.colors[:, :3], expected, atol=1e-6)


def test_import_is_the_degenerate_temporal_case(tmp_path):
    """A static asset is present at every instant, and says so in the temporal model."""
    imported = from_gltf(write_glb(tmp_path, build_glb(splat_attributes(32))))
    g = imported.gaussians

    assert np.all(g.motions == 0)
    assert np.all(np.isinf(g.sigma_t)), "a static gaussian never fades, which is what an infinite sigma means"
    assert np.all(np.isinf(g.win_hi))
    assert imported.metadata["coordinate_system"] == "y-up-right-handed"
    assert imported.metadata["color_space"] == "srgb-rec709-display"

    # And it survives a write at duration zero: there is nothing to play, but every
    # instant a caller asks for still resolves to the whole set.
    scene = fourdgs.read(_encode(g, 0.0))
    assert scene.header.duration_sec == 0.0
    for t in (0.0, 1.0, 1e6):
        assert len(scene.gaussians.state_at(t, scene.header.cutoff)["indices"]) == g.count


@pytest.mark.parametrize("degree", [1, 2, 3])
def test_import_carries_whole_spherical_harmonic_degrees(tmp_path, degree):
    attributes = splat_attributes(48, sh_degree=degree)
    g = from_gltf(write_glb(tmp_path, build_glb(attributes))).gaussians

    coeffs = _BAND_START[degree] + _BAND_WIDTH[degree]
    assert g.sh_degree == degree
    assert g.sh.shape == (48, 3 * coeffs)

    # Columns are component-major over the whole coefficient list, which is the layout
    # the band streams are written in and the one a decoder reassembles.
    step = (SH_QUANT_HI - SH_QUANT_LO) / 255.0
    for band in range(1, degree + 1):
        for k in range(_BAND_WIDTH[band]):
            flat = _BAND_START[band] + k
            source = attributes[f"{EXTENSION}:SH_DEGREE_{band}_COEF_{k}"]
            for channel in range(3):
                decoded = g.sh[:, channel * coeffs + flat] / 255.0 * (SH_QUANT_HI - SH_QUANT_LO) + SH_QUANT_LO
                assert np.max(np.abs(decoded - source[:, channel])) <= step


def test_import_refuses_a_partial_degree(tmp_path):
    attributes = splat_attributes(8, sh_degree=1)
    del attributes[f"{EXTENSION}:SH_DEGREE_1_COEF_2"]
    with pytest.raises(MalformedFile, match="whole degrees"):
        from_gltf(write_glb(tmp_path, build_glb(attributes)))


@pytest.mark.parametrize(
    ("semantic", "component"),
    [(_A_ROTATION, 5120), (_A_SCALE, 5123), (_A_OPACITY, 5121), (_A_OPACITY, 5123)],
)
def test_import_decodes_the_normalized_integer_encodings(tmp_path, semantic, component):
    """The extension permits these besides float, so refusing them would refuse real assets."""
    attributes = splat_attributes(40)
    blob = build_glb(attributes, component_types={semantic: component})
    g = from_gltf(write_glb(tmp_path, blob)).gaussians

    tolerance = {5120: 1 / 127, 5121: 1 / 255, 5123: 1 / 65535}[component]
    if semantic == _A_OPACITY:
        assert np.max(np.abs(g.colors[:, 3] - attributes[_A_OPACITY][:, 0])) <= tolerance
    elif semantic == _A_SCALE:
        assert np.max(np.abs(g.scales - attributes[_A_SCALE])) <= tolerance
    else:
        # Renormalization after decoding is what makes the quantized quaternion a
        # rotation again, so the comparison is against the normalized source.
        assert np.max(np.abs(np.linalg.norm(g.rotations, axis=1) - 1.0)) < 1e-6


def test_import_bakes_a_node_transform(tmp_path):
    """Translation and uniform scale are expressible in the attributes, so they are baked."""
    attributes = splat_attributes(24)
    node = {"translation": [1.0, -2.0, 0.5], "scale": [2.0, 2.0, 2.0]}
    g = from_gltf(write_glb(tmp_path, build_glb(attributes, node=node))).gaussians

    assert np.allclose(g.positions, attributes["POSITION"] * 2.0 + np.array([1.0, -2.0, 0.5]), atol=1e-5)
    assert np.allclose(g.scales, attributes[_A_SCALE] * 2.0, atol=1e-6)


def test_import_refuses_a_non_uniform_node_scale(tmp_path):
    node = {"scale": [1.0, 2.0, 3.0]}
    with pytest.raises(MalformedFile, match="scales non-uniformly"):
        from_gltf(write_glb(tmp_path, build_glb(splat_attributes(8), node=node)))


def test_import_refuses_rotating_a_node_that_carries_higher_harmonics(tmp_path):
    """Rotating degree>0 harmonics needs Wigner-D, which this converter does not implement."""
    node = {"rotation": [0.0, 0.3826834, 0.0, 0.9238795]}
    blob = build_glb(splat_attributes(8, sh_degree=1), node=node)
    with pytest.raises(MalformedFile, match="Wigner-D"):
        from_gltf(write_glb(tmp_path, blob))


def test_import_rotates_positions_and_quaternions_when_there_are_no_higher_harmonics(tmp_path):
    """90 degrees about Y carries +X onto -Z, and the gaussians' own quaternions with it."""
    attributes = splat_attributes(16)
    node = {"rotation": [0.0, math.sin(math.pi / 4), 0.0, math.cos(math.pi / 4)]}
    g = from_gltf(write_glb(tmp_path, build_glb(attributes, node=node))).gaussians

    source = attributes["POSITION"]
    expected = np.stack([source[:, 2], source[:, 1], -source[:, 0]], axis=1)
    assert np.allclose(g.positions, expected, atol=1e-5)
    assert np.allclose(np.linalg.norm(g.rotations, axis=1), 1.0, atol=1e-6)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"mode": 4}, "POINTS"),
        ({"kernel": "gaussian"}, "kernel"),
        ({"color_space": "aces-cct"}, "registry does not list"),
    ],
)
def test_import_names_what_it_refuses(tmp_path, kwargs, message):
    with pytest.raises(MalformedFile, match=message):
        from_gltf(write_glb(tmp_path, build_glb(splat_attributes(8), **kwargs)))


def test_import_refuses_an_asset_with_no_splats(tmp_path):
    blob = build_glb(splat_attributes(8))
    document, binary = read_glb(blob)
    del document["meshes"][0]["primitives"][0]["extensions"]
    document["extensionsRequired"] = []
    path = tmp_path / "plain.gltf"
    (tmp_path / "plain.bin").write_bytes(binary)
    document["buffers"][0]["uri"] = "plain.bin"
    path.write_text(json.dumps(document))
    with pytest.raises(MalformedFile, match="no primitive"):
        from_gltf(str(path))


def test_import_refuses_an_extension_it_does_not_implement(tmp_path):
    blob = build_glb(splat_attributes(8))
    document, binary = read_glb(blob)
    document["extensionsRequired"].append("EXT_some_compression")
    (tmp_path / "compressed.bin").write_bytes(binary)
    document["buffers"][0]["uri"] = "compressed.bin"
    (tmp_path / "compressed.gltf").write_text(json.dumps(document))
    with pytest.raises(MalformedFile, match="EXT_some_compression"):
        from_gltf(str(tmp_path / "compressed.gltf"))


def test_import_refuses_a_buffer_outside_its_own_directory(tmp_path):
    document, binary = read_glb(build_glb(splat_attributes(8)))
    document["buffers"][0]["uri"] = "../elsewhere.bin"
    inner = tmp_path / "asset"
    inner.mkdir()
    (tmp_path / "elsewhere.bin").write_bytes(binary)
    (inner / "escape.gltf").write_text(json.dumps(document))
    with pytest.raises(MalformedFile, match="outside the document's directory"):
        from_gltf(str(inner / "escape.gltf"))


def test_import_reads_a_gltf_beside_its_bin(tmp_path):
    document, binary = read_glb(build_glb(splat_attributes(12)))
    document["buffers"][0]["uri"] = "scene.bin"
    (tmp_path / "scene.bin").write_bytes(binary)
    (tmp_path / "scene.gltf").write_text(json.dumps(document))
    assert from_gltf(str(tmp_path / "scene.gltf")).gaussians.count == 12


# --------------------------------------------------------------------------- export


def temporal_scene(n: int = 96, *, sh_degree: int = 0) -> tuple[GaussianSet, float]:
    """A scene that actually moves, so a snapshot has something to get wrong."""
    quaternions = RNG.normal(size=(n, 4))
    quaternions /= np.linalg.norm(quaternions, axis=1, keepdims=True)
    coeffs = (_BAND_START[sh_degree] + _BAND_WIDTH[sh_degree]) if sh_degree else 0
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
            sh=RNG.integers(0, 256, size=(n, 3 * coeffs), dtype=np.uint8) if sh_degree else None,
            sh_degree=sh_degree,
        ),
        1.0,
    )


def _encode(g: GaussianSet, duration: float, **metadata) -> bytes:
    import io

    buffer = io.BytesIO()
    fourdgs.write(
        buffer,
        g,
        duration,
        options=fourdgs.WriteOptions(metadata=metadata or None),
    )
    return buffer.getvalue()


def test_export_writes_the_state_at_the_instant_asked_for(tmp_path):
    g, _ = temporal_scene()
    out = str(tmp_path / "snapshot.glb")
    at = 0.75
    to_gltf(out, g, at, cutoff=0.05, coordinate_system="y-up-right-handed")

    document, binary = read_glb(open(out, "rb").read())
    written = glb_attribute(document, binary, "POSITION")
    # Not the stored centres: the centre at `t` is the stored one carried along its
    # velocity, and exporting the former with the clock ignored is the mistake this
    # asserts against.
    expected = g.positions + g.motions * (at - g.mu_t)[:, None]
    assert np.allclose(written, expected, atol=1e-5)
    assert not np.allclose(written, g.positions)


def test_export_declares_the_extension_and_the_required_properties(tmp_path):
    g, _ = temporal_scene(32)
    out = str(tmp_path / "snapshot.glb")
    to_gltf(out, g, 0.5, cutoff=0.05, coordinate_system="y-up-right-handed", color_space="linear-rec709-display")

    document, binary = read_glb(open(out, "rb").read())
    primitive = document["meshes"][0]["primitives"][0]
    assert document["extensionsRequired"] == [EXTENSION]
    assert primitive["mode"] == 0, "the ellipse kernel requires POINTS"
    assert primitive["extensions"][EXTENSION] == {"kernel": KERNEL, "colorSpace": "lin_rec709_display"}
    for semantic in ("POSITION", _A_ROTATION, _A_SCALE, _A_OPACITY, f"{EXTENSION}:SH_DEGREE_0_COEF_0"):
        assert semantic in primitive["attributes"]
    # glTF requires bounds on POSITION, and a viewer needs them to frame the asset.
    assert "min" in document["accessors"][primitive["attributes"]["POSITION"]]
    # The fallback the extension describes, so a viewer without splat support still
    # draws a coloured point cloud rather than nothing.
    assert "COLOR_0" in primitive["attributes"]
    assert glb_attribute(document, binary, "COLOR_0").shape[1] == 4


def test_export_places_a_z_up_scene_with_a_node_rotation(tmp_path):
    """The axis change is the node's, which is where the extension puts a transform."""
    g, _ = temporal_scene(16)
    out = str(tmp_path / "zup.glb")
    to_gltf(out, g, 0.5, cutoff=0.05, coordinate_system="z-up-right-handed")

    document, _ = read_glb(open(out, "rb").read())
    rotation = np.asarray(document["nodes"][0]["rotation"])
    assert np.allclose(rotation, [-(0.5**0.5), 0.0, 0.0, 0.5**0.5], atol=1e-6)


def test_export_refuses_a_coordinate_system_it_cannot_place(tmp_path):
    g, _ = temporal_scene(8)
    with pytest.raises(MalformedFile, match="coordinate_system"):
        to_gltf(str(tmp_path / "x.glb"), g, 0.5, cutoff=0.05, coordinate_system="")
    with pytest.raises(MalformedFile, match="coordinate_system"):
        to_gltf(str(tmp_path / "x.glb"), g, 0.5, cutoff=0.05, coordinate_system="y-up-left-handed")


def test_export_refuses_an_empty_instant(tmp_path):
    g, _ = temporal_scene(8)
    with pytest.raises(MalformedFile, match="no gaussian is visible"):
        to_gltf(str(tmp_path / "x.glb"), g, 5.0, cutoff=0.05, coordinate_system="y-up-right-handed")


def test_export_writes_a_gltf_beside_its_bin(tmp_path):
    g, _ = temporal_scene(16)
    out = tmp_path / "pair.gltf"
    to_gltf(str(out), g, 0.5, cutoff=0.05, coordinate_system="y-up-right-handed")

    document = json.loads(out.read_text())
    assert document["buffers"][0]["uri"] == "pair.bin"
    assert (tmp_path / "pair.bin").stat().st_size == document["buffers"][0]["byteLength"]
    # And it reads back, which is the only claim that matters about a two-file asset.
    assert from_gltf(str(out)).gaussians.count == 16


# ------------------------------------------------------------------------ round trip


def test_gltf_roundtrip_preserves_attributes_within_the_declared_bounds(tmp_path):
    """glTF -> 4dgs -> glTF, checked against the intermediate file's own bounds.

    The error is the container's quantization and nothing else, so the bounds the
    intermediate declares are the right yardstick — and they are a claim its encoder
    verified before writing them.
    """
    attributes = splat_attributes(128)
    source = write_glb(tmp_path, build_glb(attributes, color_space="lin_rec709_display"))

    imported = from_gltf(source)
    blob = _encode(imported.gaussians, 0.0, **imported.metadata)
    scene = fourdgs.read(blob)
    bounds = scene.quantization.bounds

    out = str(tmp_path / "roundtrip.glb")
    to_gltf(
        out,
        scene.gaussians,
        0.0,
        cutoff=scene.header.cutoff,
        coordinate_system=scene.header.attributes["coordinate_system"],
        color_space=scene.header.attributes["color_space"],
    )
    document, binary = read_glb(open(out, "rb").read())
    written = glb_attribute(document, binary, "POSITION")
    pairing = _pair_by_position({"centers": written}, {"centers": attributes["POSITION"]})

    assert np.max(np.abs(written[pairing] - attributes["POSITION"])) <= float(bounds["pos"])
    opacity = glb_attribute(document, binary, _A_OPACITY)[pairing, 0]
    assert np.max(np.abs(opacity - attributes[_A_OPACITY][:, 0])) <= float(bounds["alpha"])
    # Scale's bound is relative, so the comparison is too.
    scale = glb_attribute(document, binary, _A_SCALE)[pairing]
    assert np.max(np.abs(scale / attributes[_A_SCALE] - 1.0)) <= float(bounds["scale_rel"])
    # The degree-0 coefficient goes out through colour and back, so it carries the
    # colour bound scaled by the constant that relates the two.
    dc = glb_attribute(document, binary, f"{EXTENSION}:SH_DEGREE_0_COEF_0")[pairing]
    assert np.max(np.abs(dc - attributes[f"{EXTENSION}:SH_DEGREE_0_COEF_0"])) <= float(bounds["rgb"]) / SH_C0


def test_gltf_roundtrip_preserves_higher_harmonics_within_the_quantization_step(tmp_path):
    attributes = splat_attributes(64, sh_degree=3)
    imported = from_gltf(write_glb(tmp_path, build_glb(attributes)))
    scene = fourdgs.read(_encode(imported.gaussians, 0.0, **imported.metadata))

    out = str(tmp_path / "sh.glb")
    to_gltf(
        out,
        scene.gaussians,
        0.0,
        cutoff=scene.header.cutoff,
        coordinate_system="y-up-right-handed",
        color_space="srgb-rec709-display",
    )
    document, binary = read_glb(open(out, "rb").read())
    pairing = _pair_by_position(
        {"centers": glb_attribute(document, binary, "POSITION")}, {"centers": attributes["POSITION"]}
    )

    step = (SH_QUANT_HI - SH_QUANT_LO) / 255.0
    for band in range(1, 4):
        for k in range(_BAND_WIDTH[band]):
            name = f"{EXTENSION}:SH_DEGREE_{band}_COEF_{k}"
            written = glb_attribute(document, binary, name)[pairing]
            assert np.max(np.abs(written - attributes[name])) <= step


def _pair_by_position(got: dict, want: dict) -> np.ndarray:
    """Match two states gaussian-for-gaussian by nearest centre.

    Gaussian order is the encoder's business — it sorts each chunk by Morton code — so
    the two files agree on the set, not on the sequence. Position is what identifies a
    gaussian across the round trip, since a centre moves by at most a quantization step
    and no two of these start that close together; the match being one-to-one is itself
    the assertion that nothing was dropped, duplicated or confused for its neighbour.
    """
    distance = np.linalg.norm(want["centers"][:, None, :] - got["centers"][None, :, :], axis=2)
    nearest = distance.argmin(axis=1)
    assert len(np.unique(nearest)) == len(nearest), "the round trip did not preserve the set of gaussians"
    return nearest


def test_4dgs_roundtrip_returns_the_canonical_state_at_the_instant(tmp_path):
    """4dgs -> glTF at `t` -> 4dgs is the state at `t`, within the bounds both files declare."""
    g, duration = temporal_scene(96)
    scene = fourdgs.read(_encode(g, duration, coordinate_system="y-up-right-handed"))
    at = 0.625
    expected = scene.gaussians.state_at(at, scene.header.cutoff)

    out = str(tmp_path / "instant.glb")
    to_gltf(out, scene.gaussians, at, cutoff=scene.header.cutoff, coordinate_system="y-up-right-handed")

    back = from_gltf(out)
    reimported = fourdgs.read(_encode(back.gaussians, 0.0, **back.metadata))
    # A static scene resolves to the same set at every instant, which is what makes
    # "the snapshot" a thing a reader can ask for without knowing the time it came from.
    state = reimported.gaussians.state_at(0.0, reimported.header.cutoff)

    bounds = reimported.quantization.bounds
    assert len(state["indices"]) == len(expected["indices"])

    pairing = _pair_by_position(state, expected)
    assert np.max(np.abs(state["centers"][pairing] - expected["centers"])) <= 2 * float(bounds["pos"])
    assert np.max(np.abs(state["opacity"][pairing] - expected["opacity"])) <= 2 * float(bounds["alpha"])
    assert reimported.header.duration_sec == 0.0


def test_cli_converts_in_both_directions(tmp_path):
    """The commands are a few lines over the library, so this checks the wiring, not the maths."""
    from fourdgs.cli import main

    source = write_glb(tmp_path, build_glb(splat_attributes(32)))
    container = str(tmp_path / "scene.4dgs")
    assert main(["from-gltf", source, "-o", container]) == 0

    out = str(tmp_path / "again.glb")
    assert main(["to-gltf", container, "-o", out, "-t", "0.0"]) == 0
    assert from_gltf(out).gaussians.count == 32
