#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Rate and distortion for spherical harmonic bit depths.

Sweeps per-band bit depths against stream codecs on a synthetic scene, and reports what
each combination costs and what it loses. Every number here is measured from a file this
package wrote and then decoded again — the sizes are the bytes on disk, and the error is
the difference between the coefficients that went in and the ones that came back out.

    python3 python/tools/rd_benchmark.py                 # the table, to stdout
    python3 python/tools/rd_benchmark.py --csv out.csv   # and the rows, as CSV

**The scene is synthetic and its spherical harmonics are the point of it.** The conformance
corpus fills coefficients with a counter, which deflate codes almost perfectly and coarser
quantization only disturbs — measuring rate on that would produce a table where quantizing
makes files *bigger*, which is true of the fixture and false of everything else. So this
tool draws coefficients from a low-frequency function of position plus noise, with the band
energy falling by degree, which is the property real fits have and the one both the codec
and the bit depths act on.

What the table does not claim: nothing here is a comparison with any other format, and the
ratios are against this format's own deflate baseline at eight bits.
"""

from __future__ import annotations

import argparse
import csv
import io
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fourdgs"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tests", "conformance", "generator"))

import fourdgs
import scenarios
from fourdgs.quantization import SH_LADDERS, SH_QUANT_HI, SH_QUANT_LO, sh_bound
from fourdgs.serialization import CODEC_DEFLATE, CODEC_ZSTD

#: Coefficient standard deviation by band, before the map onto bytes. Falling with degree
#: is the property that makes a bit-depth ladder worth having.
BAND_SIGMA = {1: 0.60, 2: 0.30, 3: 0.15}

#: Full-scale range, for PSNR. The signal is bounded by the interval spec §6.5 pins.
PEAK = SH_QUANT_HI - SH_QUANT_LO

CODECS = {"deflate": CODEC_DEFLATE, "zstd": CODEC_ZSTD}


def build_scene(name: str, degree: int, seed: int = 20260728):
    """A scenario's geometry, with spherical harmonics drawn to look like a fit's."""
    scenario = next(s for s in scenarios.SCENARIOS if s.name == name)
    raw = scenarios.build_gaussians(scenario, seed=seed)
    n = len(raw["positions"])
    positions = np.asarray(raw["positions"], dtype=np.float64).reshape(n, 3)
    coefficients = (degree + 1) ** 2 - 1

    rng = np.random.default_rng(seed)
    columns = []
    for band in range(1, degree + 1):
        width = 2 * band + 1
        for _ in range(width):
            # Low-frequency in space, so that Morton order leaves neighbouring gaussians
            # with similar coefficients — which is what a real fit looks like and what the
            # delta mode and the entropy coder both feed on.
            direction = rng.normal(size=3)
            phase = rng.uniform(0.0, 2.0 * math.pi)
            frequency = 1.5 + 2.0 * band
            smooth = np.sin(positions @ direction * frequency + phase)
            noise = rng.normal(size=n)
            columns.append(BAND_SIGMA[band] * (0.8 * smooth + 0.2 * noise))
    # Component-major: every coefficient of red, then green, then blue.
    per_component = np.stack(columns, axis=1)
    floats = np.concatenate([per_component * scale for scale in (1.0, 0.9, 1.1)], axis=1)
    assert floats.shape == (n, 3 * coefficients)

    span = SH_QUANT_HI - SH_QUANT_LO
    sh = np.clip(np.rint((floats - SH_QUANT_LO) / span * 255.0), 0, 255).astype(np.uint8)

    gaussians = fourdgs.GaussianSet(
        positions=positions.astype(np.float32),
        scales=np.asarray(raw["scales"], dtype=np.float32).reshape(n, 3),
        rotations=np.asarray(raw["rotations"], dtype=np.float32).reshape(n, 4),
        colors=np.asarray(raw["colors"], dtype=np.float32).reshape(n, 4),
        motions=np.asarray(raw["motions"], dtype=np.float32).reshape(n, 3),
        mu_t=np.asarray(raw["mu_t"], dtype=np.float32),
        sigma_t=np.asarray(raw["sigma_t"], dtype=np.float32),
        win_lo=np.asarray(raw["win_lo"], dtype=np.float32),
        win_hi=np.asarray(raw["win_hi"], dtype=np.float32),
        sh=sh,
        sh_degree=degree,
        source_index=np.arange(n, dtype=np.int64),
    )
    return gaussians, raw["duration_sec"]


def encode(gaussians, duration, depths, codec: int, level: int) -> bytes:
    options = fourdgs.WriteOptions(
        codec=codec,
        level=level,
        sh_bit_depths=depths,
        preserve_source_ids=True,
        min_chunk_gaussians=64,
        max_depth=4,
        library="4dgs rd benchmark",
    )
    buf = io.BytesIO()
    fourdgs.write(buf, gaussians, duration, options=options)
    return buf.getvalue()


def measure(data: bytes, original: np.ndarray, depths) -> dict:
    """Decode the file and compare, in the order the gaussians went in.

    The source index is what makes that possible: an encoder reorders gaussians freely, so
    without it the comparison would be against whichever gaussian happened to land in the
    same row — which produces a number that looks like error and is not.
    """
    scene = fourdgs.read(data)
    order = np.argsort(np.asarray(scene.gaussians.source_index, dtype=np.int64))
    decoded = np.asarray(scene.gaussians.sh, dtype=np.int64)[order]
    reference = original.astype(np.int64)

    coefficients = reference.shape[1] // 3
    deviation = np.abs(decoded - reference)
    span = SH_QUANT_HI - SH_QUANT_LO
    rmse = float(np.sqrt(np.mean(((decoded - reference) * (span / 255.0)) ** 2)))
    psnr = float("inf") if rmse == 0.0 else 20.0 * math.log10(PEAK / rmse)

    # The declared bound, band by band, checked against every coefficient of every
    # gaussian rather than against the encoder's own arithmetic.
    within = True
    for band, bits in (depths or {}).items():
        first, last = {1: (0, 3), 2: (3, 8), 3: (8, 15)}[band]
        columns = [c * coefficients + k for c in range(3) for k in range(first, min(last, coefficients))]
        if deviation[:, columns].max(initial=0) > sh_bound(bits):
            within = False

    sh_bytes = sum(length for entry in scene.chunk_index for _, _, length in entry.bands)
    return {
        "bytes": len(data),
        "sh_bytes": sh_bytes,
        "psnr_db": psnr,
        "max_code_units": int(deviation.max(initial=0)),
        "bounds_ok": within,
    }


def sweep(scene_name: str, degree: int, codecs: list[str]) -> list[dict]:
    gaussians, duration = build_scene(scene_name, degree)
    original = np.asarray(gaussians.sh)

    ladders: list[tuple[str, tuple[int, ...] | None]] = [("none (8 bits)", None)]
    ladders += [(f"uniform {bits}", (bits,) * 3) for bits in (8, 7, 6, 5, 4, 3)]
    ladders += [(name, depths) for name, depths in SH_LADDERS.items() if name != "flat"]

    rows: list[dict] = []
    for codec_name in codecs:
        for level in _levels(codec_name):
            for label, depths in ladders:
                data = encode(gaussians, duration, depths, CODECS[codec_name], level)
                per_band = None if depths is None else {b: depths[b - 1] for b in range(1, degree + 1)}
                row = {
                    "scene": scene_name,
                    "degree": degree,
                    "gaussians": gaussians.count,
                    "depths": label,
                    "codec": codec_name,
                    "level": level,
                }
                row.update(measure(data, original, per_band))
                rows.append(row)
    return _with_ratios(rows)


def _levels(codec_name: str) -> tuple[int, ...]:
    return (6,) if codec_name == "deflate" else (3, 19)


def _with_ratios(rows: list[dict]) -> list[dict]:
    """Every size as a fraction of the deflate, eight-bit file of the same scene.

    One baseline for the whole table rather than one per codec: the question a producer
    asks is what a setting costs against what they would otherwise have shipped, and what
    they would otherwise have shipped is the format's default.
    """
    baseline = {}
    for row in rows:
        if row["codec"] == "deflate" and row["depths"] == "none (8 bits)":
            baseline[(row["scene"], row["degree"])] = row
    for row in rows:
        base = baseline.get((row["scene"], row["degree"]))
        row["vs_baseline"] = row["bytes"] / base["bytes"] if base else float("nan")
        row["sh_vs_baseline"] = row["sh_bytes"] / base["sh_bytes"] if base and base["sh_bytes"] else float("nan")
    return rows


COLUMNS = (
    ("scene", "scene"),
    ("degree", "deg"),
    ("depths", "SH bits"),
    ("codec", "codec"),
    ("level", "lvl"),
    ("bytes", "file bytes"),
    ("sh_bytes", "SH bytes"),
    ("vs_baseline", "file vs base"),
    ("sh_vs_baseline", "SH vs base"),
    ("psnr_db", "SH PSNR dB"),
    ("max_code_units", "max err"),
    ("bounds_ok", "in bounds"),
)


def markdown(rows: list[dict]) -> str:
    header = [label for _, label in COLUMNS]
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(_cell(key, row[key]) for key, _ in COLUMNS) + " |")
    return "\n".join(lines)


def _cell(key: str, value) -> str:
    if key in ("vs_baseline", "sh_vs_baseline"):
        return f"{value:.3f}"
    if key == "psnr_db":
        return "lossless" if math.isinf(value) else f"{value:.1f}"
    if key == "bounds_ok":
        return "yes" if value else "**NO**"
    if key in ("bytes", "sh_bytes"):
        return f"{value:,}"
    return str(value)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="rate and distortion for SH bit depths")
    parser.add_argument("--scene", default="MixedLifetimes", help="scenario name from the conformance generator")
    parser.add_argument("--degree", type=int, default=3, choices=(1, 2, 3))
    parser.add_argument("--csv", help="also write the rows here")
    parser.add_argument("--codec", action="append", choices=sorted(CODECS), help="repeatable; default deflate + zstd")
    args = parser.parse_args(argv)

    codecs = args.codec or ["deflate", "zstd"]
    if "zstd" in codecs:
        try:
            import zstandard  # noqa: F401
        except ImportError:
            print("note: zstd rows skipped; install the 'zstd' extra to include them", file=sys.stderr)
            codecs = [c for c in codecs if c != "zstd"]

    rows = sweep(args.scene, args.degree, codecs)
    print(markdown(rows))

    if args.csv:
        with open(args.csv, "w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nwrote {args.csv}", file=sys.stderr)

    return 0 if all(row["bounds_ok"] for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
