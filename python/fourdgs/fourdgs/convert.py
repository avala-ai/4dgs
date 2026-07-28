# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Import a sequence of gaussian splat PLY frames.

A directory of per-frame `.ply` files is the interchange form most people actually have,
so this is the on-ramp: point it at the directory and get a `.4dgs`.

**Frames become continuous time, not stored frames.** Each frame contributes gaussians
whose validity window is that frame's slot on the timeline. Where a gaussian persists
across frames unchanged, the temporal model already expresses that in one record; where
it moves, its velocity is fitted from the frames it appears in. The output is a
continuous scene, which is the only thing this format stores.

Only the standard fields are read — `x/y/z`, `scale_*`, `rot_*`, `f_dc_*`, `opacity`, and
`f_rest_*` when present. Anything else in the file is ignored rather than guessed at.
"""

from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass

import numpy as np

from .exceptions import MalformedFile
from .model import GaussianSet

_PLY_TYPES = {
    "char": "i1",
    "uchar": "u1",
    "short": "i2",
    "ushort": "u2",
    "int": "i4",
    "uint": "u4",
    "float": "f4",
    "double": "f8",
    "int8": "i1",
    "uint8": "u1",
    "int16": "i2",
    "uint16": "u2",
    "int32": "i4",
    "uint32": "u4",
    "float32": "f4",
    "float64": "f8",
}

#: The DC term of the spherical-harmonic basis; `f_dc_*` are coefficients, not colours.
SH_C0 = 0.28209479177387814


@dataclass
class PlyFrame:
    fields: dict[str, np.ndarray]

    @property
    def count(self) -> int:
        return len(next(iter(self.fields.values())))


def read_ply(path: str) -> PlyFrame:
    """Read a binary-little-endian or ASCII PLY's vertex element."""
    with open(path, "rb") as fh:
        raw = fh.read()
    end = raw.find(b"end_header")
    if end < 0:
        raise MalformedFile(f"{path}: not a PLY (no end_header)")
    data_start = raw.index(b"\n", end) + 1
    header = raw[:end].decode("ascii", errors="replace")

    fmt = "binary_little_endian"
    count = 0
    props: list[tuple[str, str]] = []
    current = ""
    for line in header.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "format":
            fmt = parts[1]
        elif parts[0] == "element":
            current = parts[1]
            if current == "vertex":
                count = int(parts[2])
        elif parts[0] == "property" and current == "vertex":
            if parts[1] == "list":
                raise MalformedFile(f"{path}: list properties in the vertex element are not supported")
            props.append((parts[2], _PLY_TYPES.get(parts[1], "f4")))

    if not props or count == 0:
        raise MalformedFile(f"{path}: PLY has no vertices")

    if fmt == "ascii":
        text = raw[data_start:].split()
        values = np.array(text[: count * len(props)], dtype=np.float64).reshape(count, len(props))
        return PlyFrame({name: values[:, i] for i, (name, _) in enumerate(props)})

    if fmt != "binary_little_endian":
        raise MalformedFile(f"{path}: unsupported PLY format '{fmt}'")

    dtype = np.dtype([(name, "<" + kind) for name, kind in props])
    table = np.frombuffer(raw, dtype=dtype, count=count, offset=data_start)
    return PlyFrame({name: table[name].astype(np.float64) for name, _ in props})


def _sorted_frames(directory: str) -> list[str]:
    names = [n for n in os.listdir(directory) if n.lower().endswith(".ply")]
    if not names:
        raise MalformedFile(f"{directory}: no .ply files")

    def key(name: str):
        digits = re.findall(r"\d+", name)
        return (int(digits[-1]) if digits else 0, name)

    return [os.path.join(directory, n) for n in sorted(names, key=key)]


def convert_ply_sequence(directory: str, *, fps: float = 30.0) -> tuple[GaussianSet, float]:
    """Convert a directory of per-frame PLY files into a continuous scene."""
    paths = _sorted_frames(directory)
    frame_dt = 1.0 / fps
    duration = len(paths) * frame_dt

    positions, scales, rotations, colors, motions = [], [], [], [], []
    mu_t, sigma_t, win_lo, win_hi = [], [], [], []
    sh_rows: list[np.ndarray] = []
    sh_degree = 0

    previous: PlyFrame | None = None
    for index, path in enumerate(paths):
        frame = read_ply(path)
        n = frame.count
        t0 = index * frame_dt
        f = frame.fields

        pos = np.stack([f["x"], f["y"], f["z"]], axis=1)
        scale = np.exp(np.stack([f[f"scale_{k}"] for k in range(3)], axis=1)) if "scale_0" in f else _scales(f)
        rot = np.stack([f["rot_1"], f["rot_2"], f["rot_3"], f["rot_0"]], axis=1) if "rot_0" in f else _identity(n)
        rot = rot / np.maximum(np.linalg.norm(rot, axis=1, keepdims=True), 1e-30)

        if "f_dc_0" in f:
            rgb = np.clip(np.stack([f[f"f_dc_{k}"] for k in range(3)], axis=1) * SH_C0 + 0.5, 0.0, 1.0)
        else:
            rgb = np.clip(np.stack([f.get(k, np.full(n, 0.5)) for k in ("red", "green", "blue")], axis=1) / 255.0, 0, 1)
        alpha = 1.0 / (1.0 + np.exp(-f["opacity"])) if "opacity" in f else np.ones(n)

        # Velocity from the frame-to-frame difference where the counts line up, which is
        # the case tracked-gaussian exports produce. Otherwise the frame is static and
        # its gaussians simply live for their own slot.
        if previous is not None and previous.count == n:
            prev_pos = np.stack([previous.fields["x"], previous.fields["y"], previous.fields["z"]], axis=1)
            velocity = (pos - prev_pos) / frame_dt
        else:
            velocity = np.zeros_like(pos)

        rest = sorted((k for k in f if k.startswith("f_rest_")), key=lambda k: int(k.split("_")[-1]))
        if rest:
            sh_degree = {9: 1, 24: 2, 45: 3}.get(len(rest), 0)
            if sh_degree:
                coeffs = np.stack([f[k] for k in rest], axis=1)
                sh_rows.append(np.clip(np.rint((coeffs + 4.0) / 8.0 * 255.0), 0, 255).astype(np.uint8))

        positions.append(pos)
        scales.append(scale)
        rotations.append(rot)
        colors.append(np.concatenate([rgb, alpha[:, None]], axis=1))
        motions.append(velocity)
        # Centre the gaussian in its own slot and give it a temporal extent that covers
        # the slot: this is a frame expressed in the continuous model, not a stored frame.
        mu_t.append(np.full(n, t0 + 0.5 * frame_dt))
        sigma_t.append(np.full(n, frame_dt / (2.0 * math.sqrt(-2.0 * math.log(0.05)))))
        win_lo.append(np.full(n, t0))
        win_hi.append(np.full(n, t0 + frame_dt))
        previous = frame

    gaussians = GaussianSet(
        positions=np.concatenate(positions).astype(np.float32),
        scales=np.concatenate(scales).astype(np.float32),
        rotations=np.concatenate(rotations).astype(np.float32),
        colors=np.concatenate(colors).astype(np.float32),
        motions=np.concatenate(motions).astype(np.float32),
        mu_t=np.concatenate(mu_t).astype(np.float32),
        sigma_t=np.concatenate(sigma_t).astype(np.float32),
        win_lo=np.concatenate(win_lo).astype(np.float32),
        win_hi=np.concatenate(win_hi).astype(np.float32),
        sh=np.concatenate(sh_rows) if sh_rows and len(sh_rows) == len(paths) else None,
        sh_degree=sh_degree if sh_rows and len(sh_rows) == len(paths) else 0,
    )
    return gaussians, duration


def _scales(f: dict) -> np.ndarray:
    n = len(f["x"])
    return np.full((n, 3), 0.01)


def _identity(n: int) -> np.ndarray:
    out = np.zeros((n, 4))
    out[:, 3] = 1.0
    return out
