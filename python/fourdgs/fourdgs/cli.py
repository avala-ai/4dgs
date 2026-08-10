# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Command line: inspect, validate, convert, decode.

Thin by design — every command is a few lines over the library, so anything the CLI can
do is something a caller can do.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

from . import __version__, read
from . import opcode as op
from .compressed_ply import import_scene as import_compressed_ply
from .compressed_ply import sorted_segments
from .convert import convert_ply_sequence
from .exceptions import InvalidInput, MalformedFile
from .gltf import from_gltf, to_gltf
from .indexed_reader import open_indexed, read_provenance
from .provenance import (
    AXIS_NAMES,
    CAMERA_MODEL_NAMES,
    HANDEDNESS_NAMES,
    LENGTH_UNIT_NAMES,
    TRAJECTORY_INTERPOLATION_NAMES,
    name_of,
)
from .readable import FileReadable
from .records import Header
from .serialization import MAGIC, check_magic, iter_records
from .usd import from_usd, to_usd, to_usd_keyframe_delta
from .validate import validate
from .writer import WriteOptions, write


def cmd_info(args) -> int:
    with FileReadable(args.file) as src:
        scene = open_indexed(src)
        size = src.size()
        # Framed at open, fetched here. A file with none produces an empty Provenance
        # and this whole section prints nothing, which is the point: absence is not a
        # missing feature to report on.
        provenance = read_provenance(src, scene)
    h = scene.header
    print(f"file           {args.file}  ({size / 2**20:.2f} MiB)")
    print(f"gaussians      {h.gaussian_count:,}")
    print(f"duration       {h.duration_sec:.3f} s")
    print(f"profile        {h.profile or '(none)'}   temporal model: {h.temporal_model}")
    print(f"library        {h.library or '(unstated)'}")
    print(f"spherical harm degree {h.sh_degree}")
    print(f"audio sources  {len(scene.audio_sources) if scene.has_audio else 'none'}")
    print(f"chunks         {len(scene.index)}")
    print(f"windows        {len(scene.windows)}")
    print(f"aabb           {[round(v, 4) for v in h.aabb]}")
    if scene.summary_crc_ok is not None:
        print(f"summary crc    {'ok' if scene.summary_crc_ok else 'MISMATCH'}")
    if h.attributes:
        print("attributes")
        for k, v in sorted(h.attributes.items()):
            print(f"  {k} = {v}")
    if provenance:
        print("\nprovenance")
        for frame in provenance.frames:
            metres = provenance.metres_per_unit(frame.name)
            label = frame.name or "(scene frame)"
            print(
                f"  frame        {label}  {name_of(HANDEDNESS_NAMES, frame.handedness)}-handed, "
                f"up {name_of(AXIS_NAMES, frame.up_axis)}, forward {name_of(AXIS_NAMES, frame.forward_axis)}"
            )
            print(
                f"  units        {name_of(LENGTH_UNIT_NAMES, frame.length_unit)}"
                + (f"  ({metres:g} m per unit)" if metres else "")
            )
        for anchor in provenance.anchors:
            print(
                f"  georeference {anchor.latitude_deg:.6f}, {anchor.longitude_deg:.6f} at "
                f"{anchor.altitude_m:.2f} m, heading {anchor.heading_deg:.1f} deg"
                + (f"  [frame {anchor.frame_name}]" if anchor.frame_name else "")
            )
        for sensor in provenance.sensors:
            posed = "scene frame" if sensor.pose_reference == 0 else f"rig {sensor.rig_name!r}"
            detail = f"{sensor.modality or 'unstated'}, {name_of(CAMERA_MODEL_NAMES, sensor.camera_model)}"
            if sensor.is_camera:
                detail += f", {sensor.width_px}x{sensor.height_px}, f=({sensor.fx:g}, {sensor.fy:g})"
            print(f"  sensor       {sensor.name}  [{detail}]  posed against {posed}")
        for trajectory in provenance.trajectories:
            span = f"{trajectory.times[0]:.3f}..{trajectory.times[-1]:.3f} s" if trajectory.sample_count else "empty"
            print(
                f"  rig          {trajectory.name or '(capture rig)'}  {trajectory.sample_count} samples, "
                f"{span}, {name_of(TRAJECTORY_INTERPOLATION_NAMES, trajectory.interpolation)}"
            )

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
        # Indented, and with a prefix of its own, so that a caller filtering the findings
        # on `error:`/`warning:`/`note:` — which is how this tool and the Rust one are
        # compared — sees exactly what it saw before. Naming which rule fired is a
        # validator's whole job, and the vocabulary was already on the exception.
        if finding.refusal is not None:
            print(f"  {finding.refusal}")
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


def cmd_from_compressed_ply(args) -> int:
    paths = sorted_segments(args.source) if os.path.isdir(args.source) else list(args.source_files or [args.source])
    gaussians, duration = import_compressed_ply(paths, segment_duration=args.segment_duration)
    written = write(
        args.out,
        gaussians,
        duration,
        options=WriteOptions(profile=args.profile, scene_profile="capture"),
    )
    parts = f"{len(paths)} segments" if len(paths) > 1 else "1 file"
    print(f"{gaussians.count:,} gaussians over {duration:.3f} s from {parts} -> {args.out} ({written / 2**20:.2f} MiB)")
    return 0


def cmd_from_gltf(args) -> int:
    imported = from_gltf(args.source)
    written = write(
        args.out,
        imported.gaussians,
        # A static asset has nothing to play. Its gaussians carry an infinite validity
        # window, so they are present at whatever instant a reader asks for.
        0.0,
        options=WriteOptions(profile=args.profile, scene_profile="baked", metadata=imported.metadata),
    )
    print(f"{imported.gaussians.count:,} gaussians (static) -> {args.out} ({written / 2**20:.2f} MiB)")
    return 0


def cmd_to_gltf(args) -> int:
    scene = read(args.file)
    attributes = scene.header.attributes
    written = to_gltf(
        args.out,
        scene.gaussians,
        args.time,
        cutoff=scene.header.cutoff,
        coordinate_system=args.coordinate_system or attributes.get("coordinate_system", ""),
        color_space=args.color_space or attributes.get("color_space"),
        max_sh_degree=args.sh_degree,
    )
    print(f"state at t={args.time:.3f}s -> {args.out} ({written / 2**20:.2f} MiB)")
    return 0


def cmd_from_usd(args) -> int:
    try:
        imported = from_usd(args.source)
    except InvalidInput as exc:
        # The `usd-core` extra is not installed. One sentence and a non-zero exit, rather
        # than a traceback for a dependency the user simply has not asked for yet.
        print(exc, file=sys.stderr)
        return 1
    written = write(
        args.out,
        imported.gaussians,
        # A static asset has nothing to play. Its gaussians carry an infinite validity
        # window, so they are present at whatever instant a reader asks for.
        0.0,
        options=WriteOptions(profile=args.profile, scene_profile="baked", metadata=imported.metadata),
    )
    print(f"{imported.gaussians.count:,} gaussians (static) -> {args.out} ({written / 2**20:.2f} MiB)")
    return 0


def _peek_header(data: bytes) -> Header:
    """The Header without decoding the gaussians — enough to route on `temporal_model`.

    A `keyframe-delta` file is refused by the ordinary reader (its chunks are not the
    gaussian-birth shape), so the export command cannot `read()` first and then dispatch;
    it has to know the model before it picks a path."""
    check_magic(data)
    for record in iter_records(data, len(MAGIC)):
        if record.opcode == op.HEADER:
            return Header.parse(record.content)
    raise MalformedFile("file has no Header record")


def cmd_to_usd(args) -> int:
    with open(args.file, "rb") as fh:
        data = fh.read()
    header = _peek_header(data)
    attributes = dict(header.attributes)
    meters_per_unit = args.meters_per_unit
    if meters_per_unit is None:
        meters_per_unit = float(attributes.get("meters_per_unit", 1.0))
    coordinate_system = args.coordinate_system or attributes.get("coordinate_system", "")
    color_space = args.color_space or attributes.get("color_space")

    if header.temporal_model == "keyframe-delta":
        # The temporal model has no closed-form snapshot; USD time samples are its natural
        # target, so this file always exports animated regardless of --animated/--time.
        try:
            written = to_usd_keyframe_delta(
                args.out,
                data,
                coordinate_system=coordinate_system,
                color_space=color_space,
                meters_per_unit=meters_per_unit,
                fps=args.fps,
            )
        except (InvalidInput, MalformedFile) as exc:
            print(exc, file=sys.stderr)
            return 1
        mib = written / 2**20
        print(
            f"keyframe-delta, animated over {header.duration_sec:.3f}s at {args.fps:g} fps "
            f"-> {args.out} ({mib:.2f} MiB)"
        )
        return 0

    scene = read(args.file)
    try:
        written = to_usd(
            args.out,
            scene.gaussians,
            args.time,
            cutoff=scene.header.cutoff,
            coordinate_system=args.coordinate_system or attributes.get("coordinate_system", ""),
            color_space=args.color_space or attributes.get("color_space"),
            meters_per_unit=meters_per_unit,
            max_sh_degree=args.sh_degree,
            animated=args.animated,
            fps=args.fps,
            duration_sec=scene.header.duration_sec,
        )
    except InvalidInput as exc:
        print(exc, file=sys.stderr)
        return 1
    if args.animated:
        mib = written / 2**20
        print(f"animated over {scene.header.duration_sec:.3f}s at {args.fps:g} fps -> {args.out} ({mib:.2f} MiB)")
    else:
        print(f"state at t={args.time:.3f}s -> {args.out} ({written / 2**20:.2f} MiB)")
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

    fc = sub.add_parser("from-compressed-ply", help="a chunk-compressed PLY (or a segmented set) -> .4dgs")
    fc.add_argument("source", help="a .ply, or a directory of segment .ply files in timeline order")
    fc.add_argument("source_files", nargs="*", help="further segments, if listing them explicitly")
    fc.add_argument("-o", "--out", required=True)
    fc.add_argument(
        "--segment-duration",
        type=float,
        help="seconds each segment covers; required for a segmented set, ignored for a single file",
    )
    fc.add_argument("--profile", default="default", choices=("fine", "default", "coarse"))
    fc.set_defaults(func=cmd_from_compressed_ply)

    fg = sub.add_parser("from-gltf", help="a static KHR_gaussian_splatting glTF/GLB -> .4dgs")
    fg.add_argument("source", help="a .gltf or .glb carrying the KHR_gaussian_splatting extension")
    fg.add_argument("-o", "--out", required=True)
    fg.add_argument("--profile", default="default", choices=("fine", "default", "coarse"))
    fg.set_defaults(func=cmd_from_gltf)

    tg = sub.add_parser("to-gltf", help="the state at one instant -> a static KHR_gaussian_splatting glTF/GLB")
    tg.add_argument("file")
    tg.add_argument("-o", "--out", required=True, help="a .glb, or a .gltf written beside its .bin")
    tg.add_argument("-t", "--time", type=float, default=0.0)
    tg.add_argument(
        "--coordinate-system",
        help="override the scene's own; required when it declares none, since glTF's frame is not a guess",
    )
    tg.add_argument("--color-space", help="override the scene's own")
    tg.add_argument("--sh-degree", type=int, default=3, choices=(0, 1, 2, 3), help="cap the exported degree")
    tg.set_defaults(func=cmd_to_gltf)

    fu = sub.add_parser("from-usd", help="a static ParticleField3DGaussianSplat USD -> .4dgs")
    fu.add_argument("source", help="a .usd/.usda/.usdc/.usdz carrying a ParticleField3DGaussianSplat prim")
    fu.add_argument("-o", "--out", required=True)
    fu.add_argument("--profile", default="default", choices=("fine", "default", "coarse"))
    fu.set_defaults(func=cmd_from_usd)

    tu = sub.add_parser(
        "to-usd", help="the state at one instant, or the whole animation, -> a ParticleField3DGaussianSplat USD"
    )
    tu.add_argument("file")
    tu.add_argument("-o", "--out", required=True, help="a .usd, .usda or .usdc")
    tu.add_argument("-t", "--time", type=float, default=0.0, help="the instant to snapshot (ignored with --animated)")
    tu.add_argument(
        "--animated",
        action="store_true",
        help="write the whole scene as USD time samples (a per-frame flipbook) instead of one snapshot",
    )
    tu.add_argument("--fps", type=float, default=30.0, help="sampling rate for --animated")
    tu.add_argument(
        "--coordinate-system",
        help="override the scene's own; required when it declares none, since USD's up axis is not a guess",
    )
    tu.add_argument("--color-space", help="override the scene's own")
    tu.add_argument(
        "--meters-per-unit",
        type=float,
        default=None,
        help="override the scene's own length unit; sets the stage's metersPerUnit",
    )
    tu.add_argument("--sh-degree", type=int, default=3, choices=(0, 1, 2, 3), help="cap the exported degree")
    tu.set_defaults(func=cmd_to_usd)

    d = sub.add_parser("decode", help="report the gaussians visible at an instant")
    d.add_argument("file")
    d.add_argument("-t", "--time", type=float, default=0.0)
    d.set_defaults(func=cmd_decode)
    return p


def main(argv: list[str] | None = None) -> int:
    # The tool's output is UTF-8 wherever it goes. Unpiped, Python already does
    # this; piped on Windows it falls back to the locale encoding, so the same
    # findings arrive as different bytes from this tool and the Rust one. What
    # a validator says should not depend on what its stdout was plugged into.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
