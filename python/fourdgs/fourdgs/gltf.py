# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Interoperability with `KHR_gaussian_splatting`, the glTF gaussian-splatting extension.

That extension describes a **static** set of gaussians; this format describes a temporal
one whose reconstructed state at any single instant is exactly the attribute set the
extension carries. So the bridge runs in both directions but is not symmetric, and the
asymmetry is the format's, not the converter's:

* **Import** (`from_gltf`) is total. A static asset is the degenerate temporal case — one
  set of gaussians that never moves and never fades — and this format already expresses
  it, so nothing is lost.
* **Export** (`to_gltf`) is a **snapshot**. It reconstructs the scene at one instant and
  writes that. Motion, birth times, validity windows and audio have no representation in
  the extension today, so they are dropped rather than approximated. A caller that wants
  the whole scene wants a sequence of snapshots, and should know that is what it is
  getting. `interop-gltf.md` states this in the documentation the same way.

Written against the extension at Release Candidate status, `KhronosGroup/glTF`
commit `77b44be7bef26e01fb0b140e3d5bb1716421c5e9` (2026-07-17). Re-read the extension
rather than this module if the two ever disagree.

GLB parsing and writing are done here rather than through a dependency: the container is
a 12-byte header and length-prefixed chunks, and the accessor rules are a lookup table.
That is the same call the repository made for CRC-32 and for the JSON writer in `cpp/`.
"""

from __future__ import annotations

import base64
import json
import os
import struct
import urllib.parse
from dataclasses import dataclass

import numpy as np

from .convert import SH_C0
from .exceptions import MalformedFile
from .model import GaussianSet
from .quantization import SH_QUANT_HI, SH_QUANT_LO

EXTENSION = "KHR_gaussian_splatting"

#: The extension's own attribute semantics, which are namespaced; `POSITION` and
#: `COLOR_0` come from the base glTF specification and are not.
_A_ROTATION = f"{EXTENSION}:ROTATION"
_A_SCALE = f"{EXTENSION}:SCALE"
_A_OPACITY = f"{EXTENSION}:OPACITY"


def _sh_attr(degree: int, coef: int) -> str:
    return f"{EXTENSION}:SH_DEGREE_{degree}_COEF_{coef}"


#: The extension defines exactly one kernel today, and this format defines exactly one
#: gaussian kernel and offers no choice, so a converter emits this unconditionally.
KERNEL = "ellipse"

#: `color_space` metadata values (spec registry) against the extension's `colorSpace`.
#: The two sets are the same two colour spaces spelled with different separators.
_COLOR_SPACE_TO_GLTF = {
    "srgb-rec709-display": "srgb_rec709_display",
    "linear-rec709-display": "lin_rec709_display",
}
_COLOR_SPACE_FROM_GLTF = {v: k for k, v in _COLOR_SPACE_TO_GLTF.items()}

#: What a file that declares no colour space is taken to mean. The registry says this in
#: words — "in practice display-referred sRGB" — and an exporter has to pick something to
#: satisfy the extension's required `colorSpace`, so it picks the documented reading.
DEFAULT_COLOR_SPACE = "srgb-rec709-display"

#: Coordinate systems this converter can place in glTF's frame, which is right-handed
#: with +Y up. The value is the rotation, as a quaternion in `x, y, z, w`, that carries
#: the file's frame onto glTF's. Anything not in here is refused rather than guessed at:
#: a silently mis-oriented scene looks like a modelling mistake, not a conversion bug.
_AXIS_ROTATION = {
    "y-up-right-handed": (0.0, 0.0, 0.0, 1.0),
    # -90 degrees about X carries +Z onto +Y.
    "z-up-right-handed": (-(0.5**0.5), 0.0, 0.0, 0.5**0.5),
}

#: Flat coefficient index at which each whole degree starts, within the `(n, 3*coeffs)`
#: array: degree 1 contributes 3 coefficients, degree 2 five, degree 3 seven.
_SH_BAND_START = {1: 0, 2: 3, 3: 8}
_SH_BAND_WIDTH = {1: 3, 2: 5, 3: 7}

_GLB_MAGIC = 0x46546C67
_GLB_JSON = 0x4E4F534A
_GLB_BIN = 0x004E4942

_COMPONENT_DTYPE = {
    5120: np.dtype("<i1"),
    5121: np.dtype("<u1"),
    5122: np.dtype("<i2"),
    5123: np.dtype("<u2"),
    5125: np.dtype("<u4"),
    5126: np.dtype("<f4"),
}
#: Divisor glTF defines for decoding a normalized accessor of each integer type.
_NORMALIZE_DIVISOR = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}
_TYPE_COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

_MODE_POINTS = 0


@dataclass
class GltfImport:
    """A static glTF asset, read into this format's vocabulary.

    `metadata` is what belongs in the Header's attributes map: the colour space the
    extension declared and the coordinate system, which for a glTF import is never in
    doubt.
    """

    gaussians: GaussianSet
    metadata: dict[str, str]


# --------------------------------------------------------------------------- reading


def _read_glb(blob: bytes) -> tuple[dict, bytes]:
    """Split a GLB into its JSON and binary chunks."""
    if len(blob) < 12:
        raise MalformedFile(f"glTF: {len(blob)} bytes is too short to be a GLB (12-byte header)")
    magic, version, declared = struct.unpack_from("<III", blob, 0)
    if magic != _GLB_MAGIC:
        raise MalformedFile(f"glTF: bad GLB magic 0x{magic:08x} at byte 0, expected 0x{_GLB_MAGIC:08x} ('glTF')")
    if version != 2:
        raise MalformedFile(f"glTF: GLB container version {version}, this converter reads version 2")
    if declared > len(blob):
        raise MalformedFile(f"glTF: GLB header declares {declared} bytes, the file holds {len(blob)}")

    document: dict | None = None
    binary = b""
    at = 12
    while at + 8 <= declared:
        length, kind = struct.unpack_from("<II", blob, at)
        at += 8
        if at + length > declared:
            raise MalformedFile(f"glTF: GLB chunk at byte {at - 8} declares {length} bytes, past the end of the file")
        payload = blob[at : at + length]
        if kind == _GLB_JSON and document is None:
            document = _parse_json(payload)
        elif kind == _GLB_BIN and not binary:
            binary = payload
        # Unknown chunk types are skipped by design: the GLB specification reserves them
        # for future use and requires a reader to step over what it does not recognize.
        at += length + (-length % 4)

    if document is None:
        raise MalformedFile("glTF: the GLB holds no JSON chunk")
    return document, binary


def _parse_json(payload: bytes) -> dict:
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MalformedFile(f"glTF: the JSON chunk does not parse: {exc}") from exc
    if not isinstance(document, dict):
        raise MalformedFile("glTF: the JSON chunk is not an object")
    return document


def _load_document(path: str) -> tuple[dict, bytes, str]:
    """Read a `.glb` or `.gltf` and return its document, its GLB buffer, and its base directory."""
    with open(path, "rb") as fh:
        blob = fh.read()
    base = os.path.dirname(os.path.abspath(path))
    if blob[:4] == struct.pack("<I", _GLB_MAGIC):
        document, binary = _read_glb(blob)
        return document, binary, base
    return _parse_json(blob), b"", base


def _buffer_bytes(document: dict, base: str, glb_buffer: bytes) -> list[bytes]:
    """Resolve every buffer the document declares, in index order."""
    out: list[bytes] = []
    for index, buffer in enumerate(document.get("buffers", [])):
        uri = buffer.get("uri")
        if uri is None:
            if not glb_buffer:
                raise MalformedFile(f"glTF: buffer {index} has no uri and the file carries no GLB binary chunk")
            out.append(glb_buffer)
            continue
        if uri.startswith("data:"):
            head, _, payload = uri.partition(",")
            if not head.endswith(";base64"):
                raise MalformedFile(
                    f"glTF: buffer {index} uses a non-base64 data uri, which this converter cannot read"
                )
            out.append(base64.b64decode(payload))
            continue
        if "://" in uri:
            raise MalformedFile(f"glTF: buffer {index} points at '{uri}'; this converter reads no network locations")
        resolved = os.path.normpath(os.path.join(base, urllib.parse.unquote(uri)))
        # A relative uri that climbs out of the document's own directory is how a
        # malicious asset reads a file it was never handed. glTF gives no reason to
        # allow it, so it is refused by name rather than followed.
        if os.path.commonpath([base, resolved]) != base:
            raise MalformedFile(f"glTF: buffer {index} points at '{uri}', outside the document's directory")
        with open(resolved, "rb") as fh:
            out.append(fh.read())
    return out


def _accessor(document: dict, buffers: list[bytes], index: int, semantic: str) -> np.ndarray:
    """Decode one accessor to `(count, components)` float64, applying glTF normalization."""
    accessors = document.get("accessors", [])
    if not 0 <= index < len(accessors):
        raise MalformedFile(f"glTF: attribute {semantic} names accessor {index}, which the document does not define")
    acc = accessors[index]
    if "sparse" in acc:
        raise MalformedFile(f"glTF: attribute {semantic} uses a sparse accessor, which this converter does not read")

    component_type = acc.get("componentType")
    if component_type not in _COMPONENT_DTYPE:
        raise MalformedFile(
            f"glTF: attribute {semantic} has component type {component_type}, which glTF does not define"
        )
    kind = acc.get("type")
    if kind not in _TYPE_COMPONENTS:
        raise MalformedFile(f"glTF: attribute {semantic} has type '{kind}', which glTF does not define")

    dtype = _COMPONENT_DTYPE[component_type]
    width = _TYPE_COMPONENTS[kind]
    count = int(acc.get("count", 0))
    element = dtype.itemsize * width

    view_index = acc.get("bufferView")
    if view_index is None:
        # A bufferView-less accessor without sparse data is all zeros per glTF; that is
        # legal but never what a splat attribute means, so it is refused here.
        raise MalformedFile(f"glTF: attribute {semantic} has neither a bufferView nor sparse data")
    views = document.get("bufferViews", [])
    if not 0 <= view_index < len(views):
        raise MalformedFile(
            f"glTF: attribute {semantic} names bufferView {view_index}, which the document does not define"
        )
    view = views[view_index]

    buffer_index = view.get("buffer", 0)
    if not 0 <= buffer_index < len(buffers):
        raise MalformedFile(
            f"glTF: bufferView {view_index} names buffer {buffer_index}, which the document does not define"
        )
    data = buffers[buffer_index]

    stride = int(view.get("byteStride") or element)
    start = int(view.get("byteOffset", 0)) + int(acc.get("byteOffset", 0))
    need = start + (count - 1) * stride + element if count else start
    if need > len(data) or need > int(view.get("byteOffset", 0)) + int(view.get("byteLength", len(data))):
        raise MalformedFile(
            f"glTF: attribute {semantic} needs bytes up to {need} of buffer {buffer_index}, "
            f"which holds {len(data)} and whose bufferView declares {view.get('byteLength')}"
        )

    if stride == element:
        raw = np.frombuffer(data, dtype=dtype, count=count * width, offset=start).reshape(count, width)
    else:
        rows = np.lib.stride_tricks.as_strided(
            np.frombuffer(data, dtype=np.uint8, count=need - start, offset=start),
            shape=(count, element),
            strides=(stride, 1),
        )
        raw = np.ascontiguousarray(rows).view(dtype).reshape(count, width)

    values = raw.astype(np.float64)
    if acc.get("normalized"):
        divisor = _NORMALIZE_DIVISOR.get(component_type)
        if divisor is None:
            raise MalformedFile(f"glTF: attribute {semantic} marks a float accessor normalized, which glTF forbids")
        # glTF clamps the signed forms at -1: the most negative code and the one above it
        # both decode to -1.0.
        values = np.maximum(values / divisor, -1.0) if component_type in (5120, 5122) else values / divisor
    return values


# ------------------------------------------------------------------- node transforms


def _node_matrix(node: dict) -> np.ndarray:
    """A node's local transform as a 4x4, from either `matrix` or its TRS components."""
    if "matrix" in node:
        # glTF stores matrices column-major; numpy reads the 16 floats row-major, so the
        # reshape gives the transpose and the transpose of that is the matrix.
        return np.asarray(node["matrix"], dtype=np.float64).reshape(4, 4).T
    out = np.eye(4)
    if "rotation" in node:
        x, y, z, w = (float(v) for v in node["rotation"])
        out[:3, :3] = _quaternion_matrix(np.array([[x, y, z, w]]))[0]
    if "scale" in node:
        out[:3, :3] = out[:3, :3] @ np.diag([float(v) for v in node["scale"]])
    if "translation" in node:
        out[:3, 3] = [float(v) for v in node["translation"]]
    return out


def _quaternion_matrix(q: np.ndarray) -> np.ndarray:
    """Rotation matrices for `(n, 4)` unit quaternions in `x, y, z, w` order."""
    x, y, z, w = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    return np.stack(
        [
            np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], axis=1),
            np.stack([2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], axis=1),
            np.stack([2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)], axis=1),
        ],
        axis=1,
    )


def _matrix_quaternion(m: np.ndarray) -> np.ndarray:
    """The unit quaternion, in `x, y, z, w`, of an orthonormal 3x3 rotation matrix."""
    trace = m[0, 0] + m[1, 1] + m[2, 2]
    if trace > 0:
        s = 0.5 / np.sqrt(trace + 1.0)
        q = np.array([(m[2, 1] - m[1, 2]) * s, (m[0, 2] - m[2, 0]) * s, (m[1, 0] - m[0, 1]) * s, 0.25 / s])
    else:
        i = int(np.argmax([m[0, 0], m[1, 1], m[2, 2]]))
        j, k = (i + 1) % 3, (i + 2) % 3
        s = 2.0 * np.sqrt(1.0 + m[i, i] - m[j, j] - m[k, k])
        q = np.zeros(4)
        q[3] = (m[k, j] - m[j, k]) / s
        q[i] = 0.25 * s
        q[j] = (m[j, i] + m[i, j]) / s
        q[k] = (m[k, i] + m[i, k]) / s
    return q / np.linalg.norm(q)


def _quaternion_multiply(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Hamilton product `a * b` for `x, y, z, w` quaternions, broadcasting over rows."""
    ax, ay, az, aw = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    bx, by, bz, bw = b[..., 0], b[..., 1], b[..., 2], b[..., 3]
    return np.stack(
        [
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        ],
        axis=-1,
    )


def _decompose(matrix: np.ndarray, where: str) -> tuple[np.ndarray, float, np.ndarray]:
    """Split a node's world matrix into rotation, uniform scale and translation.

    Refuses what it cannot carry exactly. A non-uniform or sheared upper-left 3x3 changes
    a gaussian's covariance in a way that is not another gaussian's scale-and-rotation, so
    baking it would silently produce a different scene; the extension keeps such a matrix
    on the node precisely because it is not expressible in the attributes.
    """
    if not np.allclose(matrix[3, :], [0.0, 0.0, 0.0, 1.0], atol=1e-6):
        raise MalformedFile(f"glTF: {where} has a projective transform; its last row must be (0, 0, 0, 1)")
    upper = matrix[:3, :3]
    lengths = np.linalg.norm(upper, axis=0)
    if not np.all(np.isfinite(lengths)) or np.any(lengths <= 0):
        raise MalformedFile(f"glTF: {where} has a degenerate transform; its column lengths are {list(lengths)}")
    if not np.allclose(lengths, lengths[0], rtol=1e-4):
        raise MalformedFile(
            f"glTF: {where} scales non-uniformly by {list(np.round(lengths, 6))}. A non-uniform scale is not "
            "expressible as a gaussian's own scale and rotation, so this converter refuses it rather than "
            "producing a differently-shaped scene; bake the transform into the splat attributes first."
        )
    rotation = upper / lengths
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-4):
        raise MalformedFile(
            f"glTF: {where} has a sheared transform, which a gaussian's scale and rotation cannot carry"
        )
    if np.linalg.det(rotation) < 0:
        raise MalformedFile(f"glTF: {where} has a mirroring transform, which a unit quaternion cannot carry")
    return rotation, float(lengths[0]), matrix[:3, 3]


def _splat_nodes(document: dict) -> list[tuple[int, np.ndarray, str]]:
    """Every `(mesh index, world matrix, path)` reachable from the document's scenes.

    A mesh instanced by several nodes yields several entries and therefore several copies
    of its gaussians, which is what instancing means once the hierarchy is flattened into
    one set.
    """
    nodes = document.get("nodes", [])
    scenes = document.get("scenes", [])
    roots: list[int] = []
    if "scene" in document and 0 <= document["scene"] < len(scenes):
        roots = list(scenes[document["scene"]].get("nodes", []))
    else:
        for scene in scenes:
            roots.extend(scene.get("nodes", []))
    if not roots and not scenes:
        roots = list(range(len(nodes)))

    found: list[tuple[int, np.ndarray, str]] = []
    seen: set[int] = set()

    def walk(index: int, parent: np.ndarray, path: str) -> None:
        if not 0 <= index < len(nodes):
            raise MalformedFile(f"glTF: {path} names node {index}, which the document does not define")
        if index in seen:
            raise MalformedFile(f"glTF: node {index} is reachable twice; the node hierarchy must be a tree")
        seen.add(index)
        node = nodes[index]
        here = f"{path}/node {index}"
        world = parent @ _node_matrix(node)
        if "mesh" in node:
            found.append((int(node["mesh"]), world, here))
        for child in node.get("children", []):
            walk(int(child), world, here)

    for root in roots:
        walk(int(root), np.eye(4), "scene")
    return found


# ---------------------------------------------------------------------------- import


def from_gltf(path: str) -> GltfImport:
    """Read a static `KHR_gaussian_splatting` asset into a single-keyframe scene.

    The result is the degenerate temporal case this format already supports: every
    gaussian has zero velocity, an infinite sigma so it never fades, and a validity
    window of `[0, inf)` so it is present at every instant a caller asks for. Write it
    with `duration_sec = 0` — there is nothing to play.
    """
    document, glb_buffer, base = _load_document(path)
    buffers = _buffer_bytes(document, base, glb_buffer)
    meshes = document.get("meshes", [])

    required = document.get("extensionsRequired", [])
    unknown = [name for name in required if name not in (EXTENSION,)]
    if unknown:
        raise MalformedFile(
            f"glTF: the asset requires extensions {unknown}, which this converter does not implement. "
            "Decoding it without them would produce a different scene."
        )

    parts: list[dict] = []
    color_spaces: set[str] = set()
    for mesh_index, world, path_note in _splat_nodes(document):
        if not 0 <= mesh_index < len(meshes):
            raise MalformedFile(f"glTF: {path_note} names mesh {mesh_index}, which the document does not define")
        for prim_index, primitive in enumerate(meshes[mesh_index].get("primitives", [])):
            extension = primitive.get("extensions", {}).get(EXTENSION)
            if extension is None:
                continue
            where = f"{path_note} mesh {mesh_index} primitive {prim_index}"
            parts.append(_read_primitive(document, buffers, primitive, extension, world, where))
            color_spaces.add(_color_space_of(extension, where))

    if not parts:
        raise MalformedFile(
            f"glTF: no primitive in this asset carries the {EXTENSION} extension, so it holds no gaussian splats"
        )
    if len(color_spaces) > 1:
        raise MalformedFile(
            f"glTF: the asset mixes colour spaces {sorted(color_spaces)}. This format declares one for the whole "
            "scene, and converting between them here would change the colours the asset ships."
        )

    return GltfImport(
        gaussians=_join(parts),
        metadata={
            "coordinate_system": "y-up-right-handed",
            "color_space": next(iter(color_spaces)),
            "source": f"imported from {EXTENSION} glTF",
        },
    )


def _color_space_of(extension: dict, where: str) -> str:
    declared = extension.get("colorSpace")
    if declared is None:
        raise MalformedFile(f"glTF: {where} declares no colorSpace, which the {EXTENSION} extension requires")
    if declared not in _COLOR_SPACE_FROM_GLTF:
        raise MalformedFile(
            f"glTF: {where} declares colorSpace '{declared}', which this format's registry does not list. "
            f"Known values are {sorted(_COLOR_SPACE_FROM_GLTF)}."
        )
    return _COLOR_SPACE_FROM_GLTF[declared]


def _read_primitive(document, buffers, primitive: dict, extension: dict, world, where: str) -> dict:
    """One splat primitive's attributes, with the node's transform baked in."""
    kernel = extension.get("kernel")
    if kernel is None:
        raise MalformedFile(f"glTF: {where} declares no kernel, which the {EXTENSION} extension requires")
    if kernel != KERNEL:
        raise MalformedFile(
            f"glTF: {where} uses the '{kernel}' kernel; this format defines only the '{KERNEL}' gaussian kernel"
        )
    if primitive.get("mode", 4) != _MODE_POINTS:
        raise MalformedFile(
            f"glTF: {where} has mode {primitive.get('mode')}; the {EXTENSION} ellipse kernel requires POINTS (0)"
        )

    attributes = primitive.get("attributes", {})
    for semantic in ("POSITION", _A_ROTATION, _A_SCALE, _A_OPACITY, _sh_attr(0, 0)):
        if semantic not in attributes:
            raise MalformedFile(f"glTF: {where} has no {semantic} attribute, which the {EXTENSION} extension requires")

    positions = _accessor(document, buffers, attributes["POSITION"], "POSITION")[:, :3]
    n = positions.shape[0]
    rotations = _accessor(document, buffers, attributes[_A_ROTATION], _A_ROTATION)[:, :4]
    scales = _accessor(document, buffers, attributes[_A_SCALE], _A_SCALE)[:, :3]
    opacity = _accessor(document, buffers, attributes[_A_OPACITY], _A_OPACITY)[:, 0]
    for name, array in ((_A_ROTATION, rotations), (_A_SCALE, scales), (_A_OPACITY, opacity)):
        if array.shape[0] != n:
            raise MalformedFile(f"glTF: {where} has {n} positions but {array.shape[0]} {name} values")

    if np.any(scales < 0):
        raise MalformedFile(f"glTF: {where} has a negative {_A_SCALE} value, which the extension forbids")
    if np.any(opacity < -1e-6) or np.any(opacity > 1 + 1e-6):
        raise MalformedFile(f"glTF: {where} has an {_A_OPACITY} value outside [0, 1], which the extension forbids")

    norms = np.linalg.norm(rotations, axis=1, keepdims=True)
    if np.any(norms < 1e-6):
        raise MalformedFile(f"glTF: {where} has a zero-length {_A_ROTATION} quaternion")
    rotations = rotations / norms

    degree, sh = _read_sh(document, buffers, attributes, n, where)
    dc = _accessor(document, buffers, attributes[_sh_attr(0, 0)], _sh_attr(0, 0))[:, :3]
    if dc.shape[0] != n:
        raise MalformedFile(f"glTF: {where} has {n} positions but {dc.shape[0]} degree-0 coefficients")
    rgb = np.clip(dc * SH_C0 + 0.5, 0.0, 1.0)

    rotation, scale, translation = _decompose(np.asarray(world, dtype=np.float64), where)
    identity_rotation = np.allclose(rotation, np.eye(3), atol=1e-6)
    if not identity_rotation and degree > 0:
        raise MalformedFile(
            f"glTF: {where} carries degree-{degree} spherical harmonics under a rotating node transform. "
            "Baking that rotation means rotating the harmonics too (Wigner-D), which this converter does not "
            "implement; bake the node transform into the attributes, or export the asset with an unrotated node."
        )
    positions = positions * scale @ rotation.T + translation
    scales = scales * scale
    if not identity_rotation:
        rotations = _quaternion_multiply(np.broadcast_to(_matrix_quaternion(rotation), (n, 4)), rotations)

    return {
        "positions": positions,
        "scales": scales,
        "rotations": rotations,
        "colors": np.concatenate([rgb, opacity[:, None]], axis=1),
        "sh": sh,
        "sh_degree": degree,
    }


def _read_sh(document, buffers, attributes: dict, n: int, where: str) -> tuple[int, np.ndarray | None]:
    """The highest whole degree present, and its coefficients in this format's layout."""
    degree = 0
    for candidate in (1, 2, 3):
        names = [_sh_attr(candidate, k) for k in range(_SH_BAND_WIDTH[candidate])]
        present = [name for name in names if name in attributes]
        if not present:
            break
        if len(present) != len(names):
            raise MalformedFile(
                f"glTF: {where} defines {len(present)} of the {len(names)} degree-{candidate} spherical-harmonic "
                f"coefficients. The extension requires whole degrees; missing are "
                f"{[name for name in names if name not in attributes]}."
            )
        degree = candidate
    if degree == 0:
        return 0, None

    coeffs = _SH_BAND_START[degree] + _SH_BAND_WIDTH[degree]
    out = np.zeros((n, 3 * coeffs), dtype=np.uint8)
    span = SH_QUANT_HI - SH_QUANT_LO
    for band in range(1, degree + 1):
        for k in range(_SH_BAND_WIDTH[band]):
            name = _sh_attr(band, k)
            values = _accessor(document, buffers, attributes[name], name)[:, :3]
            if values.shape[0] != n:
                raise MalformedFile(f"glTF: {where} has {n} positions but {values.shape[0]} {name} values")
            flat = _SH_BAND_START[band] + k
            quantized = np.clip(np.rint((values - SH_QUANT_LO) / span * 255.0), 0, 255).astype(np.uint8)
            for channel in range(3):
                out[:, channel * coeffs + flat] = quantized[:, channel]
    return degree, out


def _join(parts: list[dict]) -> GaussianSet:
    """Concatenate primitives into one set, at the lowest whole degree they all carry."""
    degree = min(part["sh_degree"] for part in parts)
    coeffs = (_SH_BAND_START[degree] + _SH_BAND_WIDTH[degree]) if degree else 0
    n = sum(part["positions"].shape[0] for part in parts)

    sh = None
    if degree:
        sh = np.zeros((n, 3 * coeffs), dtype=np.uint8)
        at = 0
        for part in parts:
            rows = part["positions"].shape[0]
            wide = part["sh"].shape[1] // 3
            for channel in range(3):
                sh[at : at + rows, channel * coeffs : (channel + 1) * coeffs] = part["sh"][
                    :, channel * wide : channel * wide + coeffs
                ]
            at += rows

    zeros = np.zeros(n, dtype=np.float32)
    return GaussianSet(
        positions=np.concatenate([p["positions"] for p in parts]).astype(np.float32),
        scales=np.concatenate([p["scales"] for p in parts]).astype(np.float32),
        rotations=np.concatenate([p["rotations"] for p in parts]).astype(np.float32),
        colors=np.concatenate([p["colors"] for p in parts]).astype(np.float32),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=zeros,
        # Never fades and never leaves: a static asset is present at whatever instant a
        # caller asks for, and `inf` is how this format says that (see `GaussianSet`).
        sigma_t=np.full(n, np.inf, dtype=np.float32),
        win_lo=zeros,
        win_hi=np.full(n, np.inf, dtype=np.float32),
        sh=sh,
        sh_degree=degree,
    )


# ---------------------------------------------------------------------------- export


def to_gltf(
    path: str,
    gaussians: GaussianSet,
    time_sec: float,
    *,
    cutoff: float,
    coordinate_system: str,
    color_space: str | None = None,
    max_sh_degree: int = 3,
) -> int:
    """Write the scene's reconstructed state at `time_sec` as a static glTF asset.

    This is a snapshot and nothing more: what the extension can hold is one instant, so
    velocity, birth time and validity windows end here. `cutoff` is the file's own
    marginal threshold, from its Header — passing a different one selects a different set
    of gaussians than the file says are visible.

    Writes GLB for a `.glb` path and JSON plus a sibling `.bin` for a `.gltf` one.
    Returns the number of bytes written to `path`.
    """
    node_rotation = _AXIS_ROTATION.get(coordinate_system)
    if node_rotation is None:
        raise MalformedFile(
            f"the scene declares coordinate_system '{coordinate_system}', which this converter cannot place in "
            f"glTF's right-handed +Y-up frame. Known values are {sorted(_AXIS_ROTATION)}; a file that declares "
            "none has to say which it means before it can be exported."
        )
    if color_space is None:
        color_space = DEFAULT_COLOR_SPACE
    if color_space not in _COLOR_SPACE_TO_GLTF:
        raise MalformedFile(
            f"the scene declares color_space '{color_space}', which this format's registry does not list. "
            f"Known values are {sorted(_COLOR_SPACE_TO_GLTF)}."
        )

    state = gaussians.state_at(time_sec, cutoff)
    index = state["indices"]
    if index.size == 0:
        raise MalformedFile(
            f"no gaussian is visible at t={time_sec}s, so the snapshot would be empty. The scene runs over "
            "its own duration; pick an instant inside it."
        )

    degree = min(gaussians.sh_degree, max_sh_degree) if gaussians.sh is not None else 0
    document, binary = _build_document(
        centers=state["centers"],
        opacity=np.clip(state["opacity"], 0.0, 1.0),
        rgb=gaussians.colors[index, :3].astype(np.float64),
        scales=gaussians.scales[index].astype(np.float64),
        rotations=gaussians.rotations[index].astype(np.float64),
        sh=gaussians.sh[index] if degree else None,
        sh_degree=degree,
        stored_coeffs=(gaussians.sh.shape[1] // 3) if gaussians.sh is not None else 0,
        color_space=color_space,
        node_rotation=node_rotation,
        time_sec=time_sec,
    )

    if path.lower().endswith(".gltf"):
        name = os.path.basename(path)
        stem = name[: -len(".gltf")]
        document["buffers"][0]["uri"] = urllib.parse.quote(f"{stem}.bin")
        with open(os.path.join(os.path.dirname(os.path.abspath(path)), f"{stem}.bin"), "wb") as fh:
            fh.write(binary)
        blob = json.dumps(document, indent=2).encode("utf-8")
    else:
        blob = _write_glb(document, binary)

    with open(path, "wb") as fh:
        fh.write(blob)
    return len(blob)


class _BufferBuilder:
    """Accumulates accessor payloads into one buffer, four-byte aligned throughout."""

    def __init__(self) -> None:
        self.blobs: list[bytes] = []
        self.views: list[dict] = []
        self.accessors: list[dict] = []
        self.length = 0

    def add(self, values: np.ndarray, kind: str, *, minmax: bool = False) -> int:
        payload = np.ascontiguousarray(values, dtype="<f4").tobytes()
        pad = -self.length % 4
        if pad:
            self.blobs.append(b"\0" * pad)
            self.length += pad
        self.views.append({"buffer": 0, "byteOffset": self.length, "byteLength": len(payload)})
        self.blobs.append(payload)
        self.length += len(payload)
        accessor = {
            "bufferView": len(self.views) - 1,
            "componentType": 5126,
            "count": int(values.shape[0]),
            "type": kind,
        }
        if minmax:
            # glTF requires min and max on POSITION, and they are what lets a viewer
            # frame the asset without decoding every accessor.
            accessor["min"] = [float(v) for v in np.asarray(values, dtype=np.float32).min(axis=0)]
            accessor["max"] = [float(v) for v in np.asarray(values, dtype=np.float32).max(axis=0)]
        self.accessors.append(accessor)
        return len(self.accessors) - 1

    def bytes(self) -> bytes:
        return b"".join(self.blobs)


def _build_document(
    *,
    centers,
    opacity,
    rgb,
    scales,
    rotations,
    sh,
    sh_degree: int,
    stored_coeffs: int,
    color_space: str,
    node_rotation,
    time_sec: float,
) -> tuple[dict, bytes]:
    builder = _BufferBuilder()
    attributes = {
        "POSITION": builder.add(centers.reshape(-1, 3), "VEC3", minmax=True),
        _A_SCALE: builder.add(scales.reshape(-1, 3), "VEC3"),
        _A_ROTATION: builder.add(rotations.reshape(-1, 4), "VEC4"),
        _A_OPACITY: builder.add(opacity.reshape(-1, 1), "SCALAR"),
        # The degree-0 coefficient, recovered from the colour this format resolved.
        _sh_attr(0, 0): builder.add((rgb - 0.5) / SH_C0, "VEC3"),
    }

    if sh_degree:
        span = SH_QUANT_HI - SH_QUANT_LO
        for band in range(1, sh_degree + 1):
            for k in range(_SH_BAND_WIDTH[band]):
                flat = _SH_BAND_START[band] + k
                columns = [channel * stored_coeffs + flat for channel in range(3)]
                values = sh[:, columns].astype(np.float64) / 255.0 * span + SH_QUANT_LO
                attributes[_sh_attr(band, k)] = builder.add(values, "VEC3")

    # The fallback the extension describes, so a viewer without splat support still draws
    # a coloured point cloud. COLOR_0 is linear per the base glTF specification, so an
    # sRGB-declared scene has its values decoded here rather than shipped mislabelled.
    fallback = _srgb_to_linear(rgb) if color_space == "srgb-rec709-display" else rgb
    attributes["COLOR_0"] = builder.add(
        np.concatenate([np.clip(fallback, 0.0, 1.0), opacity.reshape(-1, 1)], axis=1), "VEC4"
    )

    node: dict = {"mesh": 0, "name": "gaussian splats"}
    if not np.allclose(node_rotation, (0.0, 0.0, 0.0, 1.0)):
        node["rotation"] = [float(v) for v in node_rotation]

    document = {
        "asset": {
            "version": "2.0",
            "generator": "4dgs-python reference converter",
            # The instant this snapshot came from, so an asset that outlives its
            # provenance still says which frame of which scene it is.
            "extras": {"4dgs": {"time_sec": float(time_sec), "note": "static snapshot of a 4dgs scene"}},
        },
        "extensionsUsed": [EXTENSION],
        "extensionsRequired": [EXTENSION],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [node],
        "meshes": [
            {
                "primitives": [
                    {
                        "attributes": attributes,
                        "mode": _MODE_POINTS,
                        "extensions": {EXTENSION: {"kernel": KERNEL, "colorSpace": _COLOR_SPACE_TO_GLTF[color_space]}},
                    }
                ]
            }
        ],
        "accessors": builder.accessors,
        "bufferViews": builder.views,
        "buffers": [{"byteLength": builder.length}],
    }
    return document, builder.bytes()


def _srgb_to_linear(values: np.ndarray) -> np.ndarray:
    """The sRGB electro-optical transfer function, as the glTF specification defines it."""
    low = values / 12.92
    high = ((np.clip(values, 0.0, None) + 0.055) / 1.055) ** 2.4
    return np.where(values <= 0.04045, low, high)


def _write_glb(document: dict, binary: bytes) -> bytes:
    json_chunk = json.dumps(document, separators=(",", ":")).encode("utf-8")
    # Chunks are four-byte aligned; the GLB specification names the padding byte for each
    # kind — trailing spaces for JSON so it still parses, zeros for the binary chunk.
    json_chunk += b" " * (-len(json_chunk) % 4)
    binary = binary + b"\0" * (-len(binary) % 4)
    total = 12 + 8 + len(json_chunk) + (8 + len(binary) if binary else 0)
    out = [struct.pack("<III", _GLB_MAGIC, 2, total)]
    out.append(struct.pack("<II", len(json_chunk), _GLB_JSON))
    out.append(json_chunk)
    if binary:
        out.append(struct.pack("<II", len(binary), _GLB_BIN))
        out.append(binary)
    return b"".join(out)
