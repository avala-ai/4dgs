# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Command line: inspect, validate, convert, decode.

Thin by design — every command is a few lines over the library, so anything the CLI can
do is something a caller can do.
"""

from __future__ import annotations

import argparse
import json
import sys

import numpy as np

from . import __version__, read
from .convert import convert_ply_sequence
from .indexed_reader import open_indexed
from .readable import FileReadable
from .validate import validate
from .writer import WriteOptions, write


def cmd_info(args) -> int:
    with FileReadable(args.file) as src:
        scene = open_indexed(src)
        size = src.size()
    h = scene.header
    print(f"file           {args.file}  ({size / 2**20:.2f} MiB)")
    print(f"gaussians      {h.gaussian_count:,}")
    print(f"duration       {h.duration_sec:.3f} s")
    print(f"profile        {h.profile or '(none)'}   temporal model: {h.temporal_model}")
    print(f"library        {h.library or '(unstated)'}")
    print(f"spherical harm degree {h.sh_degree}")
    print(f"audio          {scene.audio_codec if scene.has_audio else 'none'}")
    print(f"chunks         {len(scene.index)}")
    print(f"windows        {len(scene.windows)}")
    print(f"aabb           {[round(v, 4) for v in h.aabb]}")
    if scene.summary_crc_ok is not None:
        print(f"summary crc    {'ok' if scene.summary_crc_ok else 'MISMATCH'}")
    if h.attributes:
        print("attributes")
        for k, v in sorted(h.attributes.items()):
            print(f"  {k} = {v}")
    if scene.index:
        print("\nseek cost (bytes to render an instant):")
        for t in np.linspace(0, h.duration_sec, 6)[:-1]:
            entries = scene.chunks_for_time(float(t))
            b = scene.bytes_for_time(float(t))
            print(
                f"  t={t:7.3f}s  {len(entries):3d} ranges  {b / 2**20:8.3f} MiB  "
                f"({sum(e.gaussian_count for e in entries):,} gaussians)"
            )
    return 0


def cmd_validate(args) -> int:
    with open(args.file, "rb") as fh:
        report = validate(fh.read())
    for finding in report.findings:
        print(finding)
    if report.ok:
        print("valid" if not report.findings else "valid (with notes)")
        return 0
    print("INVALID", file=sys.stderr)
    return 1


def cmd_convert(args) -> int:
    gaussians, duration = convert_ply_sequence(args.source, fps=args.fps)
    written = write(
        args.out,
        gaussians,
        duration,
        options=WriteOptions(profile=args.profile, scene_profile="capture"),
    )
    print(f"{gaussians.count:,} gaussians over {duration:.3f} s -> {args.out} ({written / 2**20:.2f} MiB)")
    return 0


def cmd_decode(args) -> int:
    scene = read(args.file)
    # The file's own threshold, from its Header. Letting this default meant a file that
    # declared a cutoff was decoded against a different one, and the answer was wrong by
    # however far the two differed.
    state = scene.gaussians.state_at(args.time, scene.header.cutoff)
    out = {
        "time": args.time,
        "visible": len(state["indices"]),
        "total": scene.gaussians.count,
    }
    print(json.dumps(out, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="4dgs", description="Read, inspect and produce .4dgs files")
    p.add_argument("--version", action="version", version=__version__)
    sub = p.add_subparsers(dest="command", required=True)

    i = sub.add_parser("info", help="summarize a file and what seeking it costs")
    i.add_argument("file")
    i.set_defaults(func=cmd_info)

    v = sub.add_parser("validate", help="check a file against the specification")
    v.add_argument("file")
    v.set_defaults(func=cmd_validate)

    c = sub.add_parser("convert", help="a directory of gaussian splat PLY frames -> .4dgs")
    c.add_argument("source", help="directory of per-frame .ply files, in name order")
    c.add_argument("-o", "--out", required=True)
    c.add_argument("--fps", type=float, default=30.0)
    c.add_argument("--profile", default="default", choices=("fine", "default", "coarse"))
    c.set_defaults(func=cmd_convert)

    d = sub.add_parser("decode", help="report the gaussians visible at an instant")
    d.add_argument("file")
    d.add_argument("-t", "--time", type=float, default=0.0)
    d.set_defaults(func=cmd_decode)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
