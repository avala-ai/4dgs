#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The cross-language encode gate: prove an encoder against the scene it was given.

    python3 tests/conformance/encode_roundtrip.py --encoder python   # the reference itself
    python3 tests/conformance/encode_roundtrip.py --encoder rust
    python3 tests/conformance/encode_roundtrip.py --encoder cpp
    python3 tests/conformance/encode_roundtrip.py --encoder swift
    python3 tests/conformance/encode_roundtrip.py --encoder typescript
    python3 tests/conformance/encode_roundtrip.py --encoder dart
    python3 tests/conformance/encode_roundtrip.py --references        # the two references, diffed
    python3 tests/conformance/encode_roundtrip.py --self-test         # this gate's own tests

The corpus proves decoders against files the reference *encoder* wrote. This proves an
encoder, and it does it without a second corpus. Every encode family ships one small CLI —
`<encoder> <in.4dgs> <out.4dgs> [sh-bit-depths]` — that decodes a variant, re-encodes the
gaussians it yielded with a fixed option preset, and writes the result. The preset drops
every non-gaussian record, because these authoring surfaces write gaussians and cannot
reproduce audio, cameras, attachments or provenance a variant happens to carry.

Three separate claims are then made about that file. None implies another, which is why all
three are made.

**Fidelity — the file against the scene it came from.** Every lane is compared against the
source by the Python reference reader, inside the error bounds the written file *itself*
declares. The tolerance is read out of the file rather than chosen here: re-encoding
quantizes a second time, so exact equality is the wrong test, and a hardcoded epsilon either
passes everything or fails a legitimate ladder. Velocity and birth time have no per-file
pitch at all — theirs is per gaussian — so those are derived the way a decoder derives them,
from the sigma bins, the window length and the cutoff the file declares.

This is the claim the agreement check below cannot make. Until this existed (#189) the source
was never a term in the comparison beyond the gaussian count, so a fault present in *both*
encoders passed, and a faithful port of a buggy reference was indistinguishable from a
correct one. #190 is two writer bugs in the Python reference that the Dart writer reproduced
faithfully while this gate stayed green. PR #166 built this check for one encoder in
`dart/encode-roundtrip.sh`; it is here so that every encoder is held to it, the Python
reference included.

**Agreement — the candidate against the reference encoder.** Encode the same variant with
`encode_gaussians` (the Rust reference) and with the candidate, decode BOTH with the Python
reference decoder, and require identical canonical JSON. Because the preset is fixed and the
encoder is deterministic in its input and options, two correct encoders produce files that
decode to the same summary — chunk intervals, summary offsets and all. For C++ and Swift,
which reach the Rust encoder through the C ABI, this proves the binding wired the gaussians
and options through correctly; for TypeScript and Dart, genuine second encoders, it proves
agreement. It catches divergence, which fidelity cannot see: two encoders can each be inside
their declared bounds and still disagree about the chunk tree.

**Index counts — the file against its own index.** A chunk index states what a seek will
cost and how many gaussians it will yield, and nothing verified either (#195): a swapped
`gaussian_count` reconstructs correctly and lies about the population. Every count the index
declares is checked against the records it points at, and under `keyframe-delta` against the
composed state, where `gaussian_count` counts operations and `live_count` counts population.

A second pass repeats fidelity and agreement for the spherical-harmonic variants at per-band
bit depths, where the coefficients one encoder coarsened must come back out of the decoder as
the same bytes and the declared depths must read as the ones that were written.

`--references` runs the two reference encoders against each other over the corpus instead of
a candidate against one of them (#182). It is opt-in because four of the divergences it finds
are open specification questions rather than defects; see `KNOWN_REFERENCE_DIVERGENCES`.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import os
import struct
import subprocess
import sys
import tempfile
from collections import Counter

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

sys.path.insert(0, os.path.join(ROOT, "python", "fourdgs"))
sys.path.insert(0, HERE)

import fourdgs
from canonical import canonical, summarize
from fourdgs import opcode
from fourdgs import records as rec
from fourdgs.indexed_reader import MAX_FRONT_MATTER_BYTES, open_indexed, read_chunk
from fourdgs.opcode import CHUNK, CHUNK_INDEX, DELTA_CHUNK, HEADER, QUANTIZATION, SH_BAND_STREAM
from fourdgs.quantization import life_class, motion_steps, mu_steps, support_k
from fourdgs.readable import FileReadable
from fourdgs.serialization import MAGIC, iter_records
from fourdgs.stream_reader import window_table_or_default
from json_compare import compact as compact_json
from json_compare import diagnostic_differences
from json_compare import loads as load_canonical_json

EXE = ".exe" if os.name == "nt" else ""

RUST_BIN = os.path.join(ROOT, "target", "release")
CPP_BUILD = os.path.join(ROOT, "cpp", "build", "conformance")
SWIFT_BIN = os.path.join(ROOT, "swift", ".build", "release")
TYPESCRIPT_DIST = os.path.join(ROOT, "typescript", "conformance", "dist")
#: Dart's runners are compiled rather than run from source, for the same reason `run.py`
#: compiles them: a script always exists, so "is it built?" would always answer yes.
DART_BUILD = os.path.join(ROOT, "dart", "conformance", "build")

#: The flag that turns this file into the Python reference's encode CLI. The Python
#: reference is an encoder like any other and belongs in the gate, and giving it a CLI here
#: rather than under `python/conformance/` keeps the gate and the thing it drives in one
#: file — there is no build step to skip and nothing to keep in sync.
WRITE_FLAG = "--write"

#: The shared baseline every candidate is diffed against.
REFERENCE = [os.path.join(RUST_BIN, "encode_gaussians" + EXE)]

#: family -> the CLI that re-encodes one variant. A new encoder adds one line, the same way
#: the decode harness adds a runner.
ENCODERS = {
    "cpp": [os.path.join(CPP_BUILD, "encode_roundtrip" + EXE)],
    "dart": [os.path.join(DART_BUILD, "encode_roundtrip" + EXE)],
    "python": [sys.executable, os.path.abspath(__file__), WRITE_FLAG],
    "rust": [os.path.join(RUST_BIN, "encode_gaussians" + EXE)],
    "swift": [os.path.join(SWIFT_BIN, "encode_roundtrip" + EXE)],
    "typescript": ["node", os.path.join(TYPESCRIPT_DIST, "encode_roundtrip.js")],
}

#: The per-band depths the SH pass re-encodes at, band 1 first. Passed as a comma-separated
#: list rather than a ladder name so every encoder parses the same thing without carrying the
#: ladder registry. A writer takes as many as its degree needs and declares exactly those.
SH_LADDER_DEPTHS = [6, 4, 3]
SH_LADDER = ",".join(str(depth) for depth in SH_LADDER_DEPTHS)

#: Encoders that are genuine second implementations rather than bindings over the Rust core.
#: A binding produces byte-identical files to the reference, so the gate compares everything;
#: a second encoder makes its own byte-layout choices — how well deflate did, which order
#: gaussians sit in a chunk — that are legitimately its own and are not part of what the file
#: means. For those, the summary's byte offsets and the producer's `library` string are
#: dropped before the comparison, which then rests on decoded content: the gaussian values,
#: the chunk intervals, the statistics, the spherical-harmonic digest.
RECORD_HEADER = struct.Struct("<BQ")

SECOND_ENCODERS = frozenset({"dart", "python", "typescript"})
#: Encoders whose round-trip CLI accepts the optional per-band depth argument. The layer
#: below this one holds Dart out of the set: its first independent writer proves a fixed
#: quantization preset and its CLI takes no third argument, so asking for one would test
#: argv parsing rather than a feature it claims. This is the layer that adds graded SH
#: depths, so Dart comes back in here.
SH_LADDER_ENCODERS = frozenset(ENCODERS)
#: Gaussian-only Dart output deliberately clears the source's capture profile. Keep that
#: compatibility normalization local to Dart: TypeScript's profile is part of the state
#: its independent encoder must preserve.
CAPTURE_PROFILE_NORMALIZATION_ENCODERS = frozenset({"dart"})
#: Encoders whose feature claim includes their own temporal partition. Add a family only
#: in its language PR, once its writer proves reconstructed support is range-seekable.
CHUNK_GEOMETRY_ENCODERS = frozenset({"dart", "typescript"})
#: Encoders whose temporal partition may legitimately differ from the reference's, so
#: `chunkIntervals` and `statistics.chunkCount` leave the comparison and
#: `_check_chunk_geometry` stands in for them.
#:
#: This is a strictly weaker claim than agreeing with the reference, and it is deliberately
#: *not* implied by being in `CHUNK_GEOMETRY_ENCODERS`. The self-consistency check proves an
#: index is seekable; only the comparison proves two encoders partition a scene the same
#: way, which is what §8 of AGENTS.md means by four SDKs behaving as one format. TypeScript
#: reproduces the reference partition exactly, so it earns the geometry check without the
#: exemption; Dart's writer chooses its own chunking preset and cannot.
INDEPENDENT_CHUNK_LAYOUT_ENCODERS = frozenset({"dart"})
#: Encoders whose Header and Statistics bounds are derived from their independently
#: reconstructed positions. The geometry check proves those bounds contain exactly the
#: public f32 state; an exact comparison with Rust's independently quantized positions would
#: reject valid files while failing to prove the invariant readers rely on.
AABB_GEOMETRY_ENCODERS = frozenset({"dart"})
LAYOUT_DEPENDENT_KEYS = ("summaryOffsets", "library")

#: Float32 storage costs a relative 1e-7 on the way out, four orders of magnitude below
#: every bound here and not zero.
SLACK = 1e-6

#: The lanes whose tolerance is a single number for the whole file, and where that number
#: lives in the Quantization record's declared bounds map. `motion` and `time` are declared
#: there too and are deliberately absent: their grid is per gaussian, so the declared number
#: is the bound for one reference lifetime rather than for any particular gaussian, and
#: `check_fidelity` derives each gaussian's own pitch instead.
DECLARED_LANES = ("pos", "scale_rel", "rot", "rgb", "alpha", "sigma_rel")

#: The relative lanes, quantized in the log domain: `log(1 + bound)` is the promise there.
LOG_DOMAIN_LANES = frozenset({"scale_rel", "sigma_rel"})


# --------------------------------------------------------------------------
# The Python reference's encode CLI
# --------------------------------------------------------------------------


def write_with_python_reference(argv: list[str]) -> int:
    """`encode_roundtrip.py --write <in.4dgs> <out.4dgs> [sh-bit-depths]`.

    The same gaussians-only preset as `rust/conformance/src/bin/encode_gaussians.rs`, which
    is the contract every encoder in the gate reproduces: the duration and cutoff come from
    the file, the chunking is small so the corpus scenes exercise the tree, the whole summary
    is written, and the profile and attributes are carried through. The library string is
    left at the encoder's default, so each encoder names itself.
    """
    if len(argv) not in (2, 3):
        print("usage: encode_roundtrip.py --write <in.4dgs> <out.4dgs> [sh-bit-depths]", file=sys.stderr)
        return 2
    source, out = argv[0], argv[1]
    depths = [int(part) for part in argv[2].split(",")] if len(argv) == 3 else None

    from fourdgs.writer import WriteOptions

    scene = fourdgs.read(source)
    options = WriteOptions(
        cutoff=scene.header.cutoff,
        min_chunk_gaussians=8,
        max_depth=4,
        write_index=True,
        write_statistics=True,
        write_summary_offsets=True,
        write_crc=True,
        sh_bands=3,
        sh_bit_depths=depths,
        scene_profile=scene.header.profile,
        metadata=dict(scene.header.attributes),
    )
    with open(out, "wb") as fh:
        fourdgs.write(fh, scene.gaussians, scene.header.duration_sec, options=options)
    with open(out, "rb") as fh:
        first = fh.read()

    # Two encodes of one scene must be the same bytes. An encoder that iterates a map, or
    # sorts unstably, passes every value-based check and still produces a file that differs
    # between runs — a property nobody notices until a build is expected to reproduce.
    import io

    again = io.BytesIO()
    fourdgs.write(again, scene.gaussians, scene.header.duration_sec, options=options)
    if again.getvalue() != first:
        print(f"{source}: two encodes of one scene differ; the encoder is not deterministic", file=sys.stderr)
        return 1

    reread = fourdgs.read(out)
    if reread.gaussians.count != scene.gaussians.count:
        print(f"{source}: re-encoding turned {scene.gaussians.count} gaussians into {reread.gaussians.count}")
        return 1
    print(
        f"{reread.gaussians.count} gaussians, {len(reread.chunk_index)} chunks, "
        f"{len(first)} bytes, deterministic, sh bits {reread.quantization.sh_bit_depths}"
    )
    return 0


# --------------------------------------------------------------------------
# Fidelity: the written file against the scene it was written from
# --------------------------------------------------------------------------


def declared_limits(scene) -> dict[str, float]:
    """The per-lane tolerance this file promises about itself.

    Read out of the Quantization record rather than chosen here, which is the whole point:
    the same encoder writing the same scene at a coarser profile declares looser numbers and
    is held to those, and a file that declares a bound it does not meet fails on its own
    promise rather than on this harness's opinion.
    """
    bounds = scene.quantization.bounds
    missing = [lane for lane in DECLARED_LANES if lane not in bounds]
    if missing:
        raise AssertionError(
            f"the file declares no bound for {missing}; the tolerance for those lanes cannot be "
            f"derived from what it says about itself (declared: {sorted(bounds)})"
        )
    limits = {}
    for lane in DECLARED_LANES:
        value = float(bounds[lane])
        limits[lane] = (np.log1p(value) if lane in LOG_DOMAIN_LANES else value) + SLACK
    return limits


def _pair_with_source(enc, src) -> np.ndarray:
    """Recover which source gaussian each written gaussian came from.

    A chunk is ordered by Morton code, so the nth gaussian out is not the nth in, and the
    pairing has to be recovered before anything can be compared.

    Position alone is not enough to recover it: `RepeatedPositions` is a variant built out of
    gaussians that share coordinates and differ in everything else, so the cost below spans
    several lanes, each normalized by its own scale.

    Each lane is centred on its own median before it is compared, which makes the pairing
    invariant to a rigid offset. That is deliberate, and it is what lets the caller name what
    went wrong: an encoder that displaced every position by a metre has not made its
    gaussians unrecognizable, it has moved them, and it must be told "pos deviates by 1"
    rather than "these do not pair up". A fault that is not a rigid offset survives the
    centring, raises the cost of the true pair, and is then measured by the caller anyway —
    so nothing hides in the matching either way.
    """

    def centred(a):
        a = np.nan_to_num(np.asarray(a, dtype=np.float64), posinf=1e30, neginf=-1e30)
        return a - np.median(a, axis=0)

    def spread(a):
        lo, hi = float(np.min(a)), float(np.max(a))
        return max(hi - lo, 1e-6)

    lanes = [
        (enc.positions, src.positions),
        (np.log(enc.scales.astype(np.float64)), np.log(src.scales.astype(np.float64))),
        (enc.colors, src.colors),
        (enc.motions, src.motions),
        (enc.mu_t[:, None], src.mu_t[:, None]),
        (
            np.where(np.isfinite(enc.sigma_t), np.log(enc.sigma_t), np.inf)[:, None],
            np.where(np.isfinite(src.sigma_t), np.log(src.sigma_t), np.inf)[:, None],
        ),
        (enc.win_lo[:, None], src.win_lo[:, None]),
        (enc.win_hi[:, None], src.win_hi[:, None]),
    ]
    cost = np.zeros((enc.count, src.count), dtype=np.float64)
    for raw_a, raw_b in lanes:
        a, b = centred(raw_a), centred(raw_b)
        cost += np.abs(a[:, None, :] - b[None, :, :]).sum(axis=2) / spread(b)

    # q and -q are the same rotation. Normalize first, then use the cheaper sign for each
    # possible pair; a sign flip must cost zero while a genuinely different orientation
    # must break a tie between otherwise identical gaussians.
    a_rot = enc.rotations.astype(np.float64)
    b_rot = src.rotations.astype(np.float64)
    a_rot /= np.maximum(np.linalg.norm(a_rot, axis=1, keepdims=True), 1e-30)
    b_rot /= np.maximum(np.linalg.norm(b_rot, axis=1, keepdims=True), 1e-30)
    rot_minus = np.abs(a_rot[:, None, :] - b_rot[None, :, :]).sum(axis=2)
    rot_plus = np.abs(a_rot[:, None, :] + b_rot[None, :, :]).sum(axis=2)
    cost += np.minimum(rot_minus, rot_plus) / spread(b_rot)

    # SH and the two exact identity lanes are often the only distinction between rows
    # sharing every geometric value. Identity mismatches dominate a lossy metric: an
    # encoder may quantize a float, but it may never substitute another exact label.
    if enc.sh is not None and src.sh is not None and enc.sh.shape[1] == src.sh.shape[1]:
        cost += np.abs(enc.sh[:, None, :].astype(np.int16) - src.sh[None, :, :].astype(np.int16)).sum(axis=2) / 255.0
    for name in ("source_index", "object_id"):
        a_label = getattr(enc, name)
        b_label = getattr(src, name)
        if a_label is not None and b_label is not None:
            cost += (np.asarray(a_label)[:, None] != np.asarray(b_label)[None, :]) * 1e6

    # Greedy over the whole matrix, cheapest pair first. Two gaussians that really are
    # interchangeable cost nothing to swap, which is why an exact assignment is not needed
    # here — but every pair is still consumed exactly once, so a scene that lost a gaussian
    # into a duplicate cannot pass.
    order = np.dstack(np.unravel_index(np.argsort(cost, axis=None), cost.shape))[0]
    pair = np.full(enc.count, -1, dtype=np.int64)
    taken = np.zeros(src.count, dtype=bool)
    left = enc.count
    for i, j in order:
        if pair[i] == -1 and not taken[j]:
            pair[i] = j
            taken[j] = True
            left -= 1
            if left == 0:
                break
    if left or len(np.unique(pair)) != src.count:
        raise AssertionError("the written gaussians do not pair one-to-one with the source's")
    return pair


def check_fidelity(source: str, written: str, gaussians_only_profile: bool = False) -> None:
    """Hold a written file against the scene it was written from. Raises on any deviation.

    `gaussians_only_profile` is for an authoring surface whose preset writes gaussians and
    nothing else: clearing the source's `capture` or `objects` profile is then the honest
    thing to do, because the records that profile promises are not in the file. Clearing it
    to something *other* than empty is still a changed field and still refused.
    """
    source_scene = fourdgs.read(source)
    src = source_scene.gaussians
    scene = fourdgs.read(written)
    enc = scene.gaussians

    # These are authoring inputs to the fixed preset, not values the writer is free to
    # replace with defaults. Check them against the source even for an empty scene, where
    # there are no gaussian lanes below to expose a shared encoder mistake.
    header_fields = {
        "duration_sec": (source_scene.header.duration_sec, scene.header.duration_sec),
        "cutoff": (source_scene.header.cutoff, scene.header.cutoff),
        "profile": (source_scene.header.profile, scene.header.profile),
        "attributes": (dict(source_scene.header.attributes), dict(scene.header.attributes)),
    }
    changed_header = {name: values for name, values in header_fields.items() if values[0] != values[1]}
    if gaussians_only_profile and changed_header.get("profile", (None, None))[1] == "":
        changed_header.pop("profile")
    if changed_header:
        raise AssertionError(f"the encoder changed source Header fields: {changed_header}")
    if enc.count != src.count:
        raise AssertionError(f"the encoder wrote {enc.count} gaussians for {src.count}")
    if enc.count == 0:
        return

    limits = declared_limits(scene)
    pair = _pair_with_source(enc, src)

    worst = {}
    worst["pos"] = np.abs(enc.positions - src.positions[pair]).max()
    worst["scale_rel"] = np.abs(np.log(enc.scales.astype(np.float64) / src.scales[pair].astype(np.float64))).max()
    a_rot = enc.rotations.astype(np.float64)
    b_rot = src.rotations[pair].astype(np.float64)
    a_rot /= np.maximum(np.linalg.norm(a_rot, axis=1, keepdims=True), 1e-30)
    b_rot /= np.maximum(np.linalg.norm(b_rot, axis=1, keepdims=True), 1e-30)
    worst["rot"] = np.minimum(np.abs(a_rot - b_rot).max(axis=1), np.abs(a_rot + b_rot).max(axis=1)).max()
    worst["rgb"] = np.abs(enc.colors[:, :3] - src.colors[pair][:, :3]).max()
    worst["alpha"] = np.abs(enc.colors[:, 3] - src.colors[pair][:, 3]).max()
    finite = np.isfinite(src.sigma_t[pair]) & np.isfinite(enc.sigma_t)
    worst["sigma_rel"] = (
        np.abs(np.log(enc.sigma_t[finite].astype(np.float64) / src.sigma_t[pair][finite].astype(np.float64))).max()
        if finite.any()
        else 0.0
    )
    if np.any(np.isfinite(src.sigma_t[pair]) != np.isfinite(enc.sigma_t)):
        raise AssertionError("a gaussian changed between fading and never-fading, which is a flag and not a tolerance")

    # Checked before the per-gaussian lanes below, so that a scene displaced or discoloured
    # wholesale is diagnosed as that, rather than as the mismatched pairing it also produces.
    for lane, limit in limits.items():
        if not (worst[lane] <= limit):
            raise AssertionError(f"{lane} deviates by {worst[lane]:g}, past the {limit:g} this file declares")

    # Velocity and birth time are the two lanes whose grid is per gaussian, not per file: a
    # short-lived gaussian is on screen briefly, so it tolerates a coarser velocity than a
    # long-lived one, and `step_motion` in the record is the pitch for the reference lifetime
    # rather than for any particular gaussian (spec §6.3). The reference encoder's own
    # verification asserts neither, for exactly that reason. So the pitch is derived here the
    # way a decoder derives it — from the sigma bins, the window length and the cutoff this
    # file declares — and each gaussian is held to half of its own.
    sigma_log = float(scene.quantization.step_sigma_log)
    never_fades = ~np.isfinite(enc.sigma_t)
    sigma_bins = np.rint(
        np.where(never_fades, 0.0, np.log(np.where(never_fades, 1.0, enc.sigma_t.astype(np.float64))) / sigma_log)
    )
    win_len = (enc.win_hi - enc.win_lo).astype(np.float64)
    motion_step = motion_steps(
        life_class(sigma_bins, sigma_log, never_fades, win_len, support_k(float(scene.header.cutoff))),
        float(scene.quantization.step_motion),
    )
    mu_step = mu_steps(sigma_bins, sigma_log, never_fades, float(scene.quantization.step_time))
    motion_excess = np.abs(enc.motions.astype(np.float64) - src.motions[pair].astype(np.float64)) - (
        motion_step[:, None] / 2.0 + SLACK
    )
    if motion_excess.max() > 0:
        raise AssertionError(
            f"a velocity is {motion_excess.max():g} past half the per-gaussian pitch this file's own grid gives it"
        )
    bounds = scene.quantization.bounds
    for declared in ("pos", "time"):
        if declared not in bounds:
            raise AssertionError(f"the file declares no {declared} bound needed for temporal fidelity")
    # The grid calculation alone would bless an inflated `step_motion`. The actual promise
    # is displacement over the visible half-span (capped at two seconds), and it is bounded
    # by bounds.pos independently of whatever pitch the encoder wrote.
    sigma = enc.sigma_t.astype(np.float64)
    visible_half = np.where(never_fades, win_len, support_k(float(scene.header.cutoff)) * sigma)
    visible_half = np.minimum(np.maximum(visible_half, 0.0), 2.0)
    motion_error = np.abs(enc.motions.astype(np.float64) - src.motions[pair].astype(np.float64))
    displacement = motion_error * visible_half[:, None]
    if displacement.max() > float(bounds["pos"]) + SLACK:
        raise AssertionError(
            f"a velocity error displaces its gaussian by {displacement.max():g}, past the "
            f"{bounds['pos']} position bound this file declares"
        )
    mu_excess = np.abs(enc.mu_t.astype(np.float64) - src.mu_t[pair].astype(np.float64)) - (mu_step / 2.0 + SLACK)
    if mu_excess.max() > 0:
        raise AssertionError(
            f"a birth time is {mu_excess.max():g} past half the per-gaussian pitch this file's own grid gives it"
        )
    mu_deviation = np.abs(enc.mu_t.astype(np.float64) - src.mu_t[pair].astype(np.float64)).max()
    if mu_deviation > float(bounds["time"]) + SLACK:
        raise AssertionError(
            f"a birth time deviates by {mu_deviation:g}, past the {bounds['time']} temporal bound this file declares"
        )

    # The validity windows are written verbatim, so they are not a tolerance at all.
    if not np.array_equal(enc.win_lo, src.win_lo[pair]) or not np.array_equal(enc.win_hi, src.win_hi[pair]):
        raise AssertionError("a validity window came back changed, and the Window Table stores them verbatim")

    # No missing band can hide behind agreement between two writers. Presence, degree and
    # shape are exact; coefficient values are checked band by band against that band's own
    # declaration (falling back to the legal global bound on files without per-band depths).
    if (src.sh is None) != (enc.sh is None):
        raise AssertionError("spherical-harmonic data changed presence")
    if src.sh_degree != enc.sh_degree or int(scene.header.sh_degree) != src.sh_degree:
        raise AssertionError(f"spherical-harmonic degree changed from {src.sh_degree} to {scene.header.sh_degree}")
    if src.sh is not None:
        if enc.sh.shape != src.sh.shape:
            raise AssertionError(f"spherical-harmonic shape changed from {src.sh.shape} to {enc.sh.shape}")
        coeffs = src.sh.shape[1] // 3
        for band, (first, last) in {1: (0, 3), 2: (3, 8), 3: (8, 15)}.items():
            if band > src.sh_degree:
                break
            columns = [c * coeffs + k for c in range(3) for k in range(first, min(last, coeffs))]
            key = f"sh_band{band}"
            if key not in bounds and "sh" not in bounds:
                raise AssertionError(f"the file declares no bound for SH band {band}")
            limit = float(bounds.get(key, bounds.get("sh")))
            deviation = np.abs(enc.sh[:, columns].astype(np.int64) - src.sh[pair][:, columns].astype(np.int64)).max(
                initial=0
            )
            if deviation > limit + SLACK:
                raise AssertionError(f"SH band {band} moved {deviation} codes, past the {limit:g} this file declares")


# --------------------------------------------------------------------------
# Index counts: the file against its own index
# --------------------------------------------------------------------------


def check_index_counts(path: str) -> None:
    """Every count the chunk index declares, against the records it points at (#195).

    An index states what a seek will cost and what it will yield, and a reader that composes
    the chunks it names never has to consult either number — so a file can reconstruct
    perfectly and still lie about its seek cost and its population. Both readers and every
    canonical summary took the population off the composed state, which is why swapping the
    two numbers in an entry passed everything.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    header = None
    entries: list[rec.ChunkIndexEntry] = []
    chunk_counts: dict[int, int] = {}
    records = list(iter_records(data, len(MAGIC)))
    records_by_offset = {record.offset: record for record in records}
    for record in records:
        if record.opcode == HEADER:
            header = rec.Header.parse(record.content)
        elif record.opcode == CHUNK_INDEX:
            entries.append(rec.ChunkIndexEntry.parse(record.content))
        elif record.opcode == CHUNK and header is not None and header.temporal_model == "gaussian-birth":
            chunk_counts[record.offset] = rec.parse_chunk(record.content)[0].count
    if header is None:
        raise AssertionError("the written file has no Header")
    if not entries:
        return

    state_opcodes = {CHUNK} if header.temporal_model == "gaussian-birth" else {CHUNK, DELTA_CHUNK}
    physical_chunks = Counter(record.offset for record in records if record.opcode in state_opcodes)
    indexed_chunks = Counter(entry.chunk_offset for entry in entries)
    if indexed_chunks != physical_chunks:
        missing = list((physical_chunks - indexed_chunks).elements())
        duplicated = list((indexed_chunks - physical_chunks).elements())
        raise AssertionError(
            "the Chunk Index is not one-to-one with physical state chunks: "
            f"missing offsets {missing}, duplicated or unknown offsets {duplicated}"
        )

    physical_bands = Counter(record.offset for record in records if record.opcode == SH_BAND_STREAM)
    indexed_bands = Counter(offset for entry in entries for _, offset, _ in entry.bands)
    if indexed_bands != physical_bands:
        missing = list((physical_bands - indexed_bands).elements())
        duplicated = list((indexed_bands - physical_bands).elements())
        raise AssertionError(
            "the Chunk Index is not one-to-one with physical SH bands: "
            f"missing offsets {missing}, duplicated or unknown offsets {duplicated}"
        )

    for i, entry in enumerate(entries):
        # Two kinds are defined, 0 and 1. An entry that declares anything else describes a
        # record the format has no reading of, and it is the index — not the chunk — that
        # says so, so no decoder is obliged to notice.
        if entry.kind not in (0, 1):
            raise AssertionError(f"chunk index entry {i} declares kind {entry.kind}; the format defines 0 and 1")
        chunk_record = records_by_offset[entry.chunk_offset]
        actual_length = RECORD_HEADER_BYTES + len(chunk_record.content)
        if entry.chunk_length != actual_length:
            raise AssertionError(
                f"chunk index entry {i} declares chunk_length {entry.chunk_length} at {entry.chunk_offset}; "
                f"the physical record is {actual_length} bytes"
            )
        expected_opcode = CHUNK if entry.kind == 0 else DELTA_CHUNK
        if chunk_record.opcode != expected_opcode:
            raise AssertionError(
                f"chunk index entry {i} declares kind {entry.kind} at {entry.chunk_offset}, where opcode "
                f"0x{chunk_record.opcode:02x} appears"
            )
        for band, offset, length in entry.bands:
            band_record = records_by_offset[offset]
            actual_band_length = RECORD_HEADER_BYTES + len(band_record.content)
            if band_record.opcode != SH_BAND_STREAM:
                raise AssertionError(
                    f"chunk index entry {i} band {band} points at {offset}, where opcode "
                    f"0x{band_record.opcode:02x} appears"
                )
            physical_band = int(band_record.content[0]) if band_record.content else -1
            if physical_band != band:
                raise AssertionError(
                    f"chunk index entry {i} names SH band {band} at {offset}; the record names band {physical_band}"
                )
            if length != actual_band_length:
                raise AssertionError(
                    f"chunk index entry {i} band {band} declares length {length} at {offset}; "
                    f"the physical record is {actual_band_length} bytes"
                )

    if header.temporal_model == "keyframe-delta":
        _check_keyframe_delta_index(data, header, entries)
        return

    for i, entry in enumerate(entries):
        if entry.kind != 0:
            raise AssertionError(f"chunk index entry {i} declares kind {entry.kind} in a gaussian-birth file")
        if entry.chunk_offset not in chunk_counts:
            raise AssertionError(f"chunk index entry {i} points at {entry.chunk_offset}, where there is no Chunk")
        held = chunk_counts[entry.chunk_offset]
        if entry.gaussian_count != held:
            raise AssertionError(
                f"chunk index entry {i} declares {entry.gaussian_count} gaussians for the chunk at "
                f"{entry.chunk_offset}, which holds {held}"
            )
    total = sum(entry.gaussian_count for entry in entries)
    if total != header.gaussian_count:
        raise AssertionError(
            f"the index accounts for {total} gaussians and the Header declares {header.gaussian_count}; "
            "under gaussian-birth every gaussian is stored in exactly one chunk"
        )


def _check_keyframe_delta_index(data: bytes, header, entries: list[rec.ChunkIndexEntry]) -> None:
    """The two counts a delta entry states, against the composition they describe (§5.8).

    `gaussian_count` is the size of the delta — the operations it carries — and `live_count`
    is the population after it has been composed. They are different numbers with different
    uses, they are stated for keyframe entries too, and nothing checked either.
    """
    from fourdgs import keyframe_delta_file as kd

    decoded = kd.decode_streamed(data)
    by_offset = {chunk.offset: chunk for chunk in decoded.chunks}
    for i, entry in enumerate(entries):
        chunk = by_offset.get(entry.chunk_offset)
        if chunk is None:
            raise AssertionError(f"chunk index entry {i} points at {entry.chunk_offset}, where there is no chunk")
        if entry.kind != chunk.kind:
            raise AssertionError(f"chunk index entry {i} declares kind {entry.kind} for a chunk of kind {chunk.kind}")
        live = len(chunk.state.ids)
        if entry.live_count != live:
            raise AssertionError(
                f"chunk index entry {i} declares live_count {entry.live_count}; composing it yields {live} gaussians"
            )
        if chunk.kind == 0:
            operations = live
        else:
            operations = int(chunk.update_count or 0) + int(chunk.birth_count or 0) + int(chunk.death_count or 0)
        if entry.gaussian_count != operations:
            raise AssertionError(
                f"chunk index entry {i} declares gaussian_count {entry.gaussian_count}; the chunk carries "
                f"{operations} operations"
            )
    distinct = len({int(i) for chunk in decoded.chunks for i in chunk.state.ids})
    if header.gaussian_count != distinct:
        raise AssertionError(
            f"the Header declares {header.gaussian_count} gaussians and the sequence names {distinct} distinct ids; "
            "under keyframe-delta the Header counts ids, not operations"
        )


# --------------------------------------------------------------------------
# Agreement: the candidate against the reference encoder
# --------------------------------------------------------------------------


def variants() -> list[str]:
    return sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))


def decode_canonical(path: str) -> str:
    scene = fourdgs.read(path)
    return canonical(
        summarize(
            scene.header,
            scene.gaussians,
            scene.audio_sources,
            [(e.t0, e.t1) for e in scene.chunk_index],
            camera=scene.camera,
            metadata=scene.metadata,
            attachments=scene.attachments,
            statistics=scene.statistics,
            summary_offsets=scene.summary_offsets,
            summary_crc_ok=scene.summary_crc_ok,
            provenance=scene.provenance,
        )
    )


def encode(command: list[str], source: str, out: str, ladder: str | None) -> None:
    argv = [*command, source, out]
    if ladder is not None:
        argv.append(ladder)
    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} failed on {os.path.basename(source)}:\n{result.stderr.strip()}")


def _objects_profile_refusal(error: RuntimeError | None) -> str | None:
    """A normative invalid-input diagnostic, independent of a runner's stderr wrapper.

    The independent CLIs expose writer errors through ordinary language-specific shells.
    The human diagnostic after that wrapper is the cross-SDK vocabulary. A gaussian-only
    binding may first observe either missing promise: C++ and Swift cannot carry object_id
    into their GaussianSet, while the other runners retain that lane and then observe the
    missing Object Table. Both are normative refusals; a shared crash message is not.
    """
    if error is None:
        return None
    prefixes = (
        "fourdgs.exceptions.InvalidInput: ",
        "invalid input: ",
        "Error: ",
        "4dgs: ",
    )
    messages = {
        "the objects profile requires an object_id stream in every non-empty chunk, but the GaussianSet carries none",
        "the objects profile requires one ObjectTable record, but none was supplied",
    }
    for line in reversed(str(error).splitlines()):
        stripped = line.strip()
        for prefix in prefixes:
            if prefix not in stripped:
                continue
            message = stripped.split(prefix, 1)[1]
            if message in messages:
                return message
    return None


def _matching_objects_profile_refusal(
    reference_error: RuntimeError | None,
    candidate_error: RuntimeError | None,
    source_profile: str,
) -> str | None:
    """Return agreement only for an incomplete source that actually promises objects.

    Both callers run the gate's fixed gaussian-only authoring preset. The diagnostic is
    normative for that preset only when the input Header declared the ``objects`` profile;
    two implementations producing the same false-positive error on an ordinary source are
    still two broken encoders, not agreement.
    """
    if source_profile != "objects":
        return None
    reference = _objects_profile_refusal(reference_error)
    candidate = _objects_profile_refusal(candidate_error)
    return "objects profile is incomplete" if reference is not None and candidate is not None else None


def _source_profile(path: str) -> str:
    """Read only the first bounded Header record, not the scene it describes."""
    with open(path, "rb") as source:
        magic = source.read(len(MAGIC))
        if magic != MAGIC:
            raise AssertionError(f"{path} does not begin with the .4dgs magic")
        framing = source.read(RECORD_HEADER_BYTES)
        if len(framing) != RECORD_HEADER_BYTES:
            raise AssertionError(f"{path} ends before its first record header")
        code, length = struct.unpack("<BQ", framing)
        if code != HEADER:
            raise AssertionError(f"{path} begins with opcode {code:#04x}; expected Header {HEADER:#04x}")
        if length > MAX_FRONT_MATTER_BYTES:
            raise AssertionError(
                f"{path} declares a {length} byte Header, past the {MAX_FRONT_MATTER_BYTES} byte ceiling"
            )
        content = source.read(length)
        if len(content) != length:
            raise AssertionError(f"{path} ends inside its {length} byte Header")
    return rec.Header.parse(content).profile


def flatten(summary: dict) -> dict:
    """One level of nesting into dotted keys: `statistics.chunkCount`, not `statistics`.

    So that a divergence can be named — and, where an issue owns it, tolerated — at the
    granularity of the thing that actually differs. Allowing the whole `statistics` object
    to differ because its chunk count does would hide its bounding box and its gaussian
    count behind the same exemption.
    """
    flat = {}
    for key, value in summary.items():
        if isinstance(value, dict):
            for inner, nested in value.items():
                flat[f"{key}.{inner}"] = nested
        else:
            flat[key] = value
    return flat


def compare(
    reference: list[str],
    candidate: list[str],
    source: str,
    tmp: str,
    ladder: str | None,
    second_encoder: bool,
    allow_known_reference_divergences: bool,
    check_chunk_geometry: bool = False,
    check_aabb_geometry: bool = False,
    normalize_capture_profile: bool = False,
    allow_independent_chunk_layout: bool = False,
) -> list[str]:
    """Prove one variant. Returns the known divergences it tolerated; raises on the rest."""
    ref_out = os.path.join(tmp, "reference.4dgs")
    cand_out = os.path.join(tmp, "candidate.4dgs")
    variant = os.path.basename(source).removesuffix(".4dgs")
    reference_error = None
    candidate_error = None
    try:
        encode(reference, source, ref_out, ladder)
    except RuntimeError as exc:
        reference_error = exc
    try:
        encode(candidate, source, cand_out, ladder)
    except RuntimeError as exc:
        candidate_error = exc

    if (
        reference_error is not None
        and candidate_error is not None
        and _matching_objects_profile_refusal(reference_error, candidate_error, _source_profile(source)) is not None
    ):
        return []
    if reference_error is not None:
        raise reference_error
    if candidate_error is not None:
        raise candidate_error

    # Fidelity first, and on the candidate's own file: a candidate that displaced the scene
    # should be told that, not told that it disagrees with an encoder that did not.
    check_fidelity(source, cand_out, normalize_capture_profile)
    check_index_counts(cand_out)
    if check_chunk_geometry:
        _check_chunk_geometry(cand_out)
    if check_aabb_geometry:
        _check_aabb_geometry(cand_out)

    ref = flatten(load_canonical_json(decode_canonical(ref_out)))
    cand = flatten(load_canonical_json(decode_canonical(cand_out)))
    if second_encoder:
        for key in LAYOUT_DEPENDENT_KEYS:
            ref.pop(key, None)
            cand.pop(key, None)
        # Named against the flattened keys: `flatten` turns `statistics` into
        # `statistics.aabb` and `statistics.chunkCount`, so reaching for a nested dict
        # here finds nothing and drops nothing.
        if check_aabb_geometry:
            for summary in (ref, cand):
                summary.pop("statistics.aabb", None)
        if allow_independent_chunk_layout:
            for summary in (ref, cand):
                summary.pop("chunkIntervals", None)
                summary.pop("statistics.chunkCount", None)
        # Dart deliberately clears `capture`: this gaussian-only preset does not promise
        # the source's original Statistics/multi-chunk capture shape. Rust preserves the
        # string even though the layout comparison is already removed. Normalize the two
        # legal spellings before comparing reconstructed state.
        if normalize_capture_profile and {ref.get("profile"), cand.get("profile")} <= {"", "capture"}:
            ref.pop("profile", None)
            cand.pop("profile", None)
        # Gaussian-only authoring surfaces do not reproduce the Object Table. The Rust
        # reference currently drops object_id with it, while Dart preserves the optional
        # gaussian lane. Dart's fidelity gate proves that lane one-to-one against the
        # source; remove the object-derived canonical sections from this agreement check.
        if normalize_capture_profile and (ref.get("profile") == "objects" or cand.get("profile") == "objects"):
            for summary in (ref, cand):
                summary.pop("profile", None)
                summary.pop("sample.objectIds", None)
                for key in [k for k in summary if k in ("objects", "states") or k.startswith(("objects.", "states."))]:
                    summary.pop(key, None)
    differing = [key for key in sorted(set(ref) | set(cand)) if ref.get(key) != cand.get(key)]
    notes = {}
    for key in differing:
        note = (
            known_reference_divergence(variant, ladder, key, cand.get(key), ref.get(key))
            if allow_known_reference_divergences
            else None
        )
        notes[key] = note
    unaccounted = {key: (ref.get(key), cand.get(key)) for key in differing if not notes.get(key)}
    if unaccounted:
        raise AssertionError(_diff(unaccounted))
    if ladder is not None:
        _check_declared_depths(cand_out)
    return [f"{key}: {notes[key]}" for key in differing if notes.get(key)]


def _physical_geometry(
    source: FileReadable,
) -> tuple[dict[int, tuple[int, float, float]], dict[int, list[tuple[int, int, int]]]]:
    """Return physical Chunk and SH ranges from a bounded framing scan.

    Only the 16-byte Chunk interval and one-byte SH label are read from payloads. The
    encoded streams themselves remain untouched, however large the candidate file is.
    """
    payload_end = source.size() - len(MAGIC)
    if payload_end < len(MAGIC) or source.read(payload_end, len(MAGIC)) != MAGIC:
        raise AssertionError("candidate has no final magic")

    chunks: dict[int, tuple[int, float, float]] = {}
    bands: dict[int, list[tuple[int, int, int]]] = {}
    band_owner: int | None = None
    offset = len(MAGIC)
    while offset < payload_end:
        if offset + RECORD_HEADER.size > payload_end:
            raise AssertionError(f"record header at offset {offset} overlaps the final magic")
        record_opcode, length = RECORD_HEADER.unpack(source.read(offset, RECORD_HEADER.size))
        record_end = offset + RECORD_HEADER.size + length
        if record_end > payload_end:
            raise AssertionError(f"record at offset {offset} ends at {record_end}, beyond payload end {payload_end}")
        if record_opcode == opcode.CHUNK:
            if length < 16:
                raise AssertionError(f"Chunk at offset {offset} is {length} bytes, too short for its interval")
            t0, t1 = struct.unpack("<dd", source.read(offset + RECORD_HEADER.size, 16))
            chunks[offset] = (RECORD_HEADER.size + length, t0, t1)
            bands[offset] = []
            band_owner = offset
        elif record_opcode == opcode.SH_BAND_STREAM:
            if length < 1:
                raise AssertionError(f"SH band at offset {offset} has no band label")
            if band_owner is None:
                raise AssertionError(f"SH band at offset {offset} does not follow a Chunk")
            band = source.read(offset + RECORD_HEADER.size, 1)[0]
            bands[band_owner].append((band, offset, RECORD_HEADER.size + length))
        else:
            band_owner = None
        offset = record_end
    return chunks, bands


def _check_declared_aabb(record: str, bounds: list[float], actual: list[float]) -> None:
    if len(bounds) != 6:
        raise AssertionError(f"{record} AABB has {len(bounds)} values, expected 6")
    if not all(np.isfinite(bounds)):
        raise AssertionError(f"{record} AABB {bounds} contains a non-finite bound")
    for axis in range(3):
        if bounds[axis] > bounds[3 + axis]:
            raise AssertionError(f"{record} AABB {bounds} is inverted on axis {axis}")
        if bounds[axis] != actual[axis] or bounds[3 + axis] != actual[3 + axis]:
            raise AssertionError(
                f"{record} AABB {bounds} does not equal reconstructed axis {axis} "
                f"range [{actual[axis]}, {actual[3 + axis]}]"
            )


def _check_summary_offset_geometry(
    source: FileReadable,
    declared: list,
    *,
    require_chunk_index: bool = False,
) -> None:
    """Every candidate Summary Offset frames its own complete summary-record class."""
    footer_offset = source.size() - len(MAGIC) - RECORD_HEADER.size - 20
    footer_opcode, footer_length = RECORD_HEADER.unpack(source.read(footer_offset, RECORD_HEADER.size))
    if footer_opcode != opcode.FOOTER or footer_length < 20:
        raise AssertionError(f"candidate Footer at {footer_offset} is not a complete Footer record")
    summary_start, summary_offset_start = struct.unpack("<QQ", source.read(footer_offset + RECORD_HEADER.size, 16))
    if summary_start == 0:
        if declared:
            raise AssertionError("candidate declares Summary Offsets without a summary region")
        if summary_offset_start != 0:
            raise AssertionError("candidate Footer declares a summary_offset_start without a summary region")
        if require_chunk_index:
            raise AssertionError("candidate writes an index but declares no summary region")
        return
    summary_opcodes = {opcode.CHUNK_INDEX, opcode.STATISTICS, opcode.SUMMARY_OFFSET}
    physical: dict[int, list[tuple[int, int]]] = {}
    offset = summary_start
    while offset < footer_offset:
        if offset + RECORD_HEADER.size > footer_offset:
            raise AssertionError(f"summary record header at {offset} overlaps the Footer")
        record_opcode, length = RECORD_HEADER.unpack(source.read(offset, RECORD_HEADER.size))
        end = offset + RECORD_HEADER.size + length
        if end > footer_offset:
            raise AssertionError(f"summary record at {offset} extends into the Footer")
        if record_opcode not in summary_opcodes:
            raise AssertionError(
                f"summary record at {offset} has opcode {record_opcode:#04x}; expected only "
                "Chunk Index, Statistics, or Summary Offset records"
            )
        physical.setdefault(record_opcode, []).append((offset, end - offset))
        offset = end

    physical_offsets = physical.get(opcode.SUMMARY_OFFSET, [])
    expected_offset_start = physical_offsets[0][0] if physical_offsets else 0
    if summary_offset_start != expected_offset_start:
        raise AssertionError(f"Footer summary_offset_start is {summary_offset_start}, expected {expected_offset_start}")

    index_declarations = [item for item in declared if item.group_opcode == opcode.CHUNK_INDEX]
    if require_chunk_index and len(index_declarations) != 1:
        raise AssertionError(
            f"an indexed candidate must declare exactly one Chunk Index Summary Offset; found {len(index_declarations)}"
        )

    seen: set[int] = set()
    for number, summary_offset in enumerate(declared):
        group_opcode = summary_offset.group_opcode
        if group_opcode in seen:
            raise AssertionError(f"Summary Offset {number} repeats group opcode {group_opcode:#04x}")
        seen.add(group_opcode)
        start = summary_offset.group_start
        length = summary_offset.group_length
        end = start + length
        if length <= 0 or start < summary_start or end > footer_offset:
            raise AssertionError(
                f"Summary Offset {number} range [{start}, {end}) is not a nonempty range "
                f"inside summary [{summary_start}, {footer_offset})"
            )
        expected = physical.get(group_opcode, [])
        if not expected:
            raise AssertionError(
                f"Summary Offset {number} names opcode {group_opcode:#04x}, "
                "but the summary contains no record of that class"
            )
        if expected[0][0] != start or expected[-1][0] + expected[-1][1] != end:
            raise AssertionError(
                f"Summary Offset {number} range [{start}, {end}) does not frame all "
                f"opcode {group_opcode:#04x} records {expected}"
            )
        if any(at + record_length != next_at for (at, record_length), (next_at, _) in itertools.pairwise(expected)):
            raise AssertionError(f"Summary Offset {number} opcode {group_opcode:#04x} records are not contiguous")


def _check_chunk_geometry(path: str) -> None:
    """Every candidate Chunk is indexed once and its interval contains its support.

    A streamed canonical decode visits every Chunk, so equal reconstructed state alone
    cannot prove that an indexed seek can find that state. Layout may differ from the
    reference encoder; this invariant may not.
    """
    with FileReadable(path) as source:
        scene = open_indexed(source)
        chunks, physical_bands = _physical_geometry(source)
        indexed_chunks = [(entry.chunk_offset, entry.chunk_length) for entry in scene.index]
        physical_chunks = sorted((offset, length) for offset, (length, _, _) in chunks.items())
        if sorted(indexed_chunks) != physical_chunks:
            raise AssertionError(
                "the Chunk Index must name every complete Chunk range exactly once; "
                f"chunks are {physical_chunks}, index names {sorted(indexed_chunks)}"
            )

        indexed_bands = sorted(band_range for entry in scene.index for band_range in entry.bands)
        all_physical_bands = sorted(band for bands in physical_bands.values() for band in bands)
        if indexed_bands != all_physical_bands:
            raise AssertionError(
                "the Chunk Index must name every complete SH band range exactly once; "
                f"bands are {all_physical_bands}, index names {indexed_bands}"
            )

        if scene.statistics is not None and scene.statistics.chunk_count != len(chunks):
            raise AssertionError(
                f"Statistics declares {scene.statistics.chunk_count} chunks, the candidate contains {len(chunks)}"
            )
        _check_summary_offset_geometry(source, scene.summary_offsets, require_chunk_index=bool(scene.index))

        table = window_table_or_default(scene.windows)
        k = support_k(scene.header.cutoff)
        clock_end = max(scene.header.duration_sec, 1e-9)
        indexed_gaussians = 0
        for number, entry in enumerate(scene.index):
            if not (entry.t0 < entry.t1):
                raise AssertionError(f"chunk index entry {number} has invalid interval [{entry.t0}, {entry.t1})")
            _, physical_t0, physical_t1 = chunks[entry.chunk_offset]
            if entry.t0 != physical_t0 or entry.t1 != physical_t1:
                raise AssertionError(
                    f"chunk index entry {number} declares interval [{entry.t0}, {entry.t1}), "
                    f"its Chunk declares [{physical_t0}, {physical_t1})"
                )

            owned_bands = sorted(physical_bands.get(entry.chunk_offset, []))
            if sorted(entry.bands) != owned_bands:
                raise AssertionError(
                    f"chunk index entry {number} names SH ranges {sorted(entry.bands)}, "
                    f"but the Chunk at {entry.chunk_offset} owns {owned_bands}"
                )

            expected_bands = set(range(1, int(scene.header.sh_degree) + 1))
            entry_bands = [band for band, _, _ in entry.bands]
            if set(entry_bands) != expected_bands or len(entry_bands) != len(expected_bands):
                raise AssertionError(
                    f"chunk index entry {number} names SH bands {entry_bands}, "
                    f"Header degree {scene.header.sh_degree} requires {sorted(expected_bands)}"
                )
            chunk = read_chunk(source, scene, entry, max_sh_band=int(scene.header.sh_degree))
            if set(chunk["sh"]) != expected_bands:
                raise AssertionError(
                    f"indexed read of chunk {number} returned SH bands {sorted(chunk['sh'])}, "
                    f"expected {sorted(expected_bands)}"
                )
            count = len(chunk["mu_t"])
            if count != entry.gaussian_count:
                raise AssertionError(
                    f"chunk index entry {number} declares {entry.gaussian_count} gaussians, its Chunk has {count}"
                )
            indexed_gaussians += count

            # Canonical gaussian state is f32 even though read_chunk has f64
            # intermediates. Round first, then widen for the support arithmetic
            # and apply the same sigma floor as state_at.
            sigma = np.asarray(chunk["sigma_t"], dtype=np.float32).astype(np.float64)
            mu = np.asarray(chunk["mu_t"], dtype=np.float32).astype(np.float64)
            half = np.where(np.isfinite(sigma), k * np.maximum(sigma, 1e-30), np.inf)
            windows = table[chunk["window_index"]]
            window_lo = np.maximum(windows[:, 0], 0.0)
            window_hi = np.minimum(windows[:, 1], clock_end)
            lo = np.maximum(mu - half, window_lo)
            hi = np.minimum(mu + half, window_hi)
            # t1 is half-open. Equality is safe only when the gaussian's own
            # validity window also ends there, so it is not visible at t1.
            outside = (lo < entry.t0) | (hi > entry.t1) | ((hi == entry.t1) & (window_hi > entry.t1))
            if np.any(outside):
                gaussian = int(np.flatnonzero(outside)[0])
                raise AssertionError(
                    f"chunk index entry {number} [{entry.t0}, {entry.t1}) omits support "
                    f"[{lo[gaussian]}, {hi[gaussian]}] for gaussian {gaussian} in its Chunk"
                )

        if indexed_gaussians != scene.header.gaussian_count:
            raise AssertionError(
                f"the index reaches {indexed_gaussians} gaussians, Header declares {scene.header.gaussian_count}"
            )


def _check_aabb_geometry(path: str) -> None:
    """Header and Statistics bounds equal the candidate's public f32 extrema."""
    scene = fourdgs.read(path)
    actual = scene.gaussians.aabb()

    declared = [("Header", scene.header.aabb)]
    if scene.statistics is not None:
        declared.append(("Statistics", scene.statistics.aabb))
        if list(scene.statistics.aabb) != list(scene.header.aabb):
            raise AssertionError(
                f"Statistics AABB {scene.statistics.aabb} does not match Header AABB {scene.header.aabb}"
            )

    for record, bounds in declared:
        _check_declared_aabb(record, bounds, actual)


def _check_declared_depths(path: str) -> None:
    """The candidate declared the depths it actually used, and a bound per band.

    A file whose coefficients and whose declaration disagree passes the canonical diff on its
    data and fails here on its metadata, or the reverse — which is why both are checked.
    """
    quant = fourdgs.read(path).quantization
    degree = int(fourdgs.read(path).header.sh_degree)
    expected = SH_LADDER_DEPTHS[:degree]
    if quant.sh_bit_depths != expected:
        raise AssertionError(f"declares SH bit depths {quant.sh_bit_depths}, not {expected}")
    missing = [band for band in range(1, degree + 1) if f"sh_band{band}" not in quant.bounds]
    if missing:
        raise AssertionError(f"declares depths but no bound for bands {missing}")


def _diff(unaccounted: dict[str, tuple], left: str = "reference", right: str = "candidate") -> str:
    lines = [f"the {left} and the {right} decode differently:"]
    expected = {key: values[0] for key, values in unaccounted.items()}
    actual = {key: values[1] for key, values in unaccounted.items()}
    lines.extend(f"  {line}" for line in diagnostic_differences(expected, actual))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# The references against each other (#182)
# --------------------------------------------------------------------------

#: Divergences between the Python and Rust reference encoders that are known and not yet
#: decided. Each exemption names the exact variant, pass, field, and fingerprints of both
#: values. A second bug in a field that already has an issue therefore stays red.
#:
#: This is not a list of things that are fine. It is a list of things that have an issue
#: number, which is the difference between a known divergence and an unnoticed one.
KNOWN_REFERENCE_DIVERGENCES = {
    (
        "OneWindow-Quantized-UseChunkIndex-UseCrc",
        None,
        "chunkIntervals",
    ): (
        "7fc12f4cc38623ae25e9c694a5f2d83349f998ba911110961a92984d0b7c3e4c",
        "77e5ef9f232ecbc8502e3bea045fe1dcdc517b4cdecf0afb2155b94ae3c488a4",
        "#182(1): Rust still plans from source lifetimes; Python plans from reconstructed lifetimes",
    ),
    (
        "OneWindow-Quantized-UseChunkIndex-UseCrc",
        None,
        "statistics.chunkCount",
    ): (
        "d10a4bc9e0c1fa4e8f3d7ce2512b8756e47ca5fa451f373c39a1431bb88db49f",
        "92e9e7e5922d26e17e48f0869ab25cc99499fdab722c065de8e0965c96c68e86",
        "#182(1): the reconstructed-support mismatch counted — Python writes 5 chunks and Rust writes 6",
    ),
    (
        "OneWindow-Quantized-UseChunkIndex-UseCrc",
        None,
        "index.chunkCount",
    ): (
        "ef2d127de37b942baad06145e54b0c619a1f22327b2ebbcfbec78f5564afe39d",
        "e7f6c011776e8db7cd330b54174fd76f7d0216b612387a5ffcfb81e6f0919683",
        "#182(1): the reconstructed-support mismatch as the index counts 5 chunks against 6",
    ),
    **{
        (variant, None, "quantization.bounds"): (
            "0b070f1689d4859b268a8439ccc9440caa2b4e327cb822c29151541539994ba1",
            "d2bf7f31abb65bae4fe22d5db06dbe3d88735cd595687b0e2c03db358ba00bc3",
            "#182(2): Python spells pos as 5e-05 and Rust as 5e-5",
        )
        for variant in ("NoData-Quantized-UseChunkIndex-UseCrc", "NoData-UseChunkIndex-UseCrc")
    },
}

#: The keys two different reference encoders cannot agree on by construction, and should not:
#: each names itself in `library`, and byte offsets follow from each one's own layout.
REFERENCE_IDENTITY_KEYS = LAYOUT_DEPENDENT_KEYS


def _fingerprint(value) -> str:
    encoded = compact_json(value).encode()
    return hashlib.sha256(encoded).hexdigest()


def known_reference_divergence(variant: str, ladder: str | None, field: str, python, rust) -> str | None:
    expected = KNOWN_REFERENCE_DIVERGENCES.get((variant, ladder, field))
    if expected is None:
        return None
    python_hash, rust_hash, note = expected
    return note if (_fingerprint(python), _fingerprint(rust)) == (python_hash, rust_hash) else None


def _declared_shape(path: str) -> dict:
    """What the file says about itself, beyond what decoding it yields.

    The canonical summary is deliberately about decoded meaning, so it cannot see a bound
    spelled `5e-05` against `5e-5`, or a bounds map that is present against one that is
    empty. Those are exactly the writer-side divergences #182 is about, so they are compared
    here as the bytes spell them.
    """
    scene = fourdgs.read(path)
    q = scene.quantization
    return {
        "header.profile": scene.header.profile,
        "header.cutoff": scene.header.cutoff,
        "header.sh_degree": int(scene.header.sh_degree),
        "header.attributes": dict(scene.header.attributes),
        "header.temporal_model": scene.header.temporal_model,
        "quantization.scheme": q.scheme,
        "quantization.bounds": dict(q.bounds),
        "quantization.sh_bit_depths": list(q.sh_bit_depths),
        "quantization.step_sh": int(q.step_sh),
        "quantization.steps": [
            q.step_pos,
            q.step_scale_log,
            q.step_rot,
            q.step_rgb,
            q.step_alpha,
            q.step_motion,
            q.step_time,
            q.step_sigma_log,
        ],
        "quantization.pos_origin": list(q.pos_origin),
        "index.chunkCount": len(scene.chunk_index),
    }


def reference_divergences(source: str, tmp: str, ladder: str | None) -> list[tuple[str, object, object]]:
    """(field, python, rust) for every place the two references disagree on one variant."""
    py_out = os.path.join(tmp, "python.4dgs")
    rs_out = os.path.join(tmp, "rust.4dgs")
    refused = {}
    for name, command, out in (("python", ENCODERS["python"], py_out), ("rust", REFERENCE, rs_out)):
        try:
            encode(command, source, out, ladder)
        except RuntimeError as exc:
            refused[name] = str(exc).strip().splitlines()[-1]
    if refused:
        if (
            len(refused) == 2
            and _matching_objects_profile_refusal(
                RuntimeError(refused["rust"]), RuntimeError(refused["python"]), _source_profile(source)
            )
            is not None
        ):
            return []
        # One of them refused what the other wrote. That is the loudest divergence there is,
        # and there is nothing further to compare on this variant.
        return [("encode", refused.get("python", "wrote the file"), refused.get("rust", "wrote the file"))]

    found = []
    py_json = flatten(load_canonical_json(decode_canonical(py_out)))
    rs_json = flatten(load_canonical_json(decode_canonical(rs_out)))
    for key in REFERENCE_IDENTITY_KEYS:
        py_json.pop(key, None)
        rs_json.pop(key, None)
    for key in sorted(set(py_json) | set(rs_json)):
        if py_json.get(key) != rs_json.get(key):
            found.append((key, py_json.get(key), rs_json.get(key)))

    py_shape = _declared_shape(py_out)
    rs_shape = _declared_shape(rs_out)
    for key in sorted(py_shape):
        if py_shape[key] != rs_shape[key]:
            found.append((key, py_shape[key], rs_shape[key]))
    return found


def run_references() -> int:
    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1
    known = unknown = 0
    with tempfile.TemporaryDirectory() as tmp:
        for variant in names:
            source = os.path.join(DATA, f"{variant}.4dgs")
            passes = [None] + ([SH_LADDER] if "SHDegree" in variant else [])
            for ladder in passes:
                label = variant if ladder is None else f"{variant} @ {ladder}"
                for field, py, rs in reference_divergences(source, tmp, ladder):
                    note = None if field == "encode" else known_reference_divergence(variant, ladder, field, py, rs)
                    if note:
                        known += 1
                        print(f"KNOWN {label}\n  {field}: {note}\n{_diff({field: (py, rs)}, 'python', 'rust')}")
                    else:
                        unknown += 1
                        print(f"DIVERGES {label}\n{_diff({field: (py, rs)}, 'python', 'rust')}")
    print(f"\n{len(names)} variants; {known} known divergences (#182), {unknown} not accounted for")
    return 1 if unknown else 0


# --------------------------------------------------------------------------
# This gate's own tests
# --------------------------------------------------------------------------


def _self_test_source() -> str:
    """A corpus variant with velocities, lifetimes and several windows.

    A missing corpus is a failure here rather than a skip: a self-test that quietly passes
    when its fixture is absent is the exact shape of check this whole change exists to
    remove.
    """
    path = os.path.join(DATA, "MixedLifetimes-UseChunkIndex-UseCrc.4dgs")
    if not os.path.exists(path):
        raise AssertionError(f"{path} is missing; run tests/conformance/generate.py first")
    return path


def _write(scene, out: str, **overrides) -> None:
    from fourdgs.writer import WriteOptions

    settings = {
        "cutoff": scene.header.cutoff,
        "min_chunk_gaussians": 8,
        "max_depth": 4,
        "write_index": True,
        "write_statistics": True,
        "write_summary_offsets": True,
        "write_crc": True,
        "sh_bands": 3,
        "scene_profile": scene.header.profile,
        "metadata": dict(scene.header.attributes),
    }
    settings.update(overrides)
    options = WriteOptions(**settings)
    with open(out, "wb") as fh:
        fourdgs.write(fh, scene.gaussians, scene.header.duration_sec, options=options)


def _expect_failure(what: str, call, substring: str) -> str:
    try:
        call()
    except AssertionError as exc:
        if substring not in str(exc):
            raise AssertionError(f"{what}: expected a message containing {substring!r}, got:\n{exc}") from None
        return str(exc).splitlines()[0]
    raise AssertionError(f"{what}: the check passed, so it does not bite")


def _test_tolerance_is_read_from_the_file(tmp: str) -> list[str]:
    """The tolerance follows the file's declared bounds, and is not a number chosen here.

    Same scene, same encoder, two quantization profiles. The coarse file must declare looser
    bounds than the fine one, both must pass against their own, and — the part that makes
    this more than a tautology — the coarse file's real deviation must be past what the fine
    file declares. A hardcoded epsilon cannot do that: it either accepts both or rejects
    both.
    """
    source = _self_test_source()
    scene = fourdgs.read(source)
    fine = os.path.join(tmp, "fine.4dgs")
    coarse = os.path.join(tmp, "coarse.4dgs")
    _write(scene, fine, profile="fine")
    _write(scene, coarse, profile="coarse")

    fine_limits = declared_limits(fourdgs.read(fine))
    coarse_limits = declared_limits(fourdgs.read(coarse))
    looser = [lane for lane in DECLARED_LANES if coarse_limits[lane] > fine_limits[lane]]
    if len(looser) != len(DECLARED_LANES):
        raise AssertionError(f"the coarse file should declare a looser bound on every lane; it does so on {looser}")

    check_fidelity(source, fine)
    check_fidelity(source, coarse)

    # And the coarse encode really is outside the fine file's promise, which is what makes
    # the two limits do different work rather than both being comfortably large.
    src = fourdgs.read(source).gaussians
    enc = fourdgs.read(coarse).gaussians
    pair = _pair_with_source(enc, src)
    coarse_pos = float(np.abs(enc.positions - src.positions[pair]).max())
    if not (coarse_pos > fine_limits["pos"]):
        raise AssertionError(
            f"the coarse encode deviates by {coarse_pos:g}, inside the fine file's {fine_limits['pos']:g}; "
            "this fixture no longer separates the two ladders"
        )
    return [
        f"tolerance follows the file: fine pos {fine_limits['pos']:.3g}, coarse pos {coarse_limits['pos']:.3g}, "
        f"and the coarse encode's {coarse_pos:.3g} would fail against the fine declaration"
    ]


def _test_fidelity_catches_a_changed_scene(tmp: str) -> list[str]:
    """A file that faithfully encodes the wrong scene fails against the right one.

    The fault is injected into the input rather than into an SDK, which is the same thing
    from this check's point of view: what it sees is a written file whose lanes are not the
    source's. Every lane the gate names in its own failure messages is exercised here.
    """
    source = _self_test_source()
    said = []

    def change_alpha(g):
        g.colors = g.colors.copy()
        g.colors[:, 3] = np.float32(0.25)

    def change_rotation(g):
        g.rotations = np.tile(np.asarray([0.5, 0.5, 0.5, 0.5], dtype=np.float32), (g.count, 1))

    def change_sigma(g):
        g.sigma_t = g.sigma_t.copy()
        finite = np.isfinite(g.sigma_t)
        g.sigma_t[finite] *= np.float32(2.0)

    for lane, mutate, expected in (
        ("pos", lambda g: setattr(g, "positions", g.positions + np.float32(1.0)), "pos deviates by"),
        ("scale", lambda g: setattr(g, "scales", g.scales * np.float32(2.0)), "scale_rel deviates by"),
        ("rot", change_rotation, "rot deviates by"),
        ("rgb", lambda g: setattr(g, "colors", np.full_like(g.colors, 0.5)), "rgb deviates by"),
        ("alpha", change_alpha, "alpha deviates by"),
        ("motion", lambda g: setattr(g, "motions", g.motions * np.float32(2.0)), "past half the per-gaussian pitch"),
        ("mu_t", lambda g: setattr(g, "mu_t", g.mu_t + np.float32(0.25)), "birth time"),
        ("sigma_t", change_sigma, "sigma_rel deviates by"),
        ("win", lambda g: setattr(g, "win_lo", g.win_lo + np.float32(1e-3)), "validity window"),
    ):
        scene = fourdgs.read(source)
        mutate(scene.gaussians)
        out = os.path.join(tmp, f"changed-{lane}.4dgs")
        _write(scene, out)
        said.append(_expect_failure(f"fidelity/{lane}", lambda out=out: check_fidelity(source, out), expected))

    sh_source = os.path.join(DATA, "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs")
    if not os.path.exists(sh_source):
        raise AssertionError(f"{sh_source} is missing; run tests/conformance/generate.py first")
    sh_scene = fourdgs.read(sh_source)
    sh_scene.gaussians.sh = sh_scene.gaussians.sh.copy()
    sh_scene.gaussians.sh[0, 0] ^= np.uint8(0x80)
    sh_out = os.path.join(tmp, "changed-sh.4dgs")
    _write(sh_scene, sh_out)
    said.append(_expect_failure("fidelity/sh", lambda: check_fidelity(sh_source, sh_out), "SH band"))

    header_scene = fourdgs.read(source)
    header_scene.header.cutoff = header_scene.header.cutoff / 2.0
    header_out = os.path.join(tmp, "changed-header.4dgs")
    _write(header_scene, header_out)
    said.append(_expect_failure("fidelity/header", lambda: check_fidelity(source, header_out), "Header fields"))
    return said


def _test_agreement_still_catches_divergence(tmp: str) -> list[str]:
    """Two encoders inside their bounds can still disagree, and the diff must say so.

    The second file is written by the same encoder with a different chunk tree: every value
    survives, so fidelity passes on both, and only the encoder-vs-encoder comparison sees it.
    This is the check #189 kept — evidence that adding fidelity did not quietly replace it.
    """
    source = _self_test_source()
    scene = fourdgs.read(source)
    flat = os.path.join(tmp, "one-chunk-per-window.4dgs")
    deep = os.path.join(tmp, "four-levels.4dgs")
    _write(scene, flat, max_depth=0)
    _write(scene, deep, max_depth=4)
    check_fidelity(source, flat)
    check_fidelity(source, deep)
    a = flatten(load_canonical_json(decode_canonical(flat)))
    b = flatten(load_canonical_json(decode_canonical(deep)))
    for key in LAYOUT_DEPENDENT_KEYS:  # as `compare` drops them for a second encoder
        a.pop(key, None)
        b.pop(key, None)
    differing = {key: (a.get(key), b.get(key)) for key in set(a) | set(b) if a.get(key) != b.get(key)}
    if not differing:
        raise AssertionError("two different chunk trees decoded to the same summary; the diff proves nothing")
    message = _diff(differing)
    if "chunkIntervals" not in message:
        raise AssertionError(f"the diff should name chunkIntervals; it said:\n{message}")
    # A field name alone must not turn this deliberately different tree into a known #182
    # result. Its variant and exact values differ from the one documented exemption.
    variant = os.path.basename(source).removesuffix(".4dgs")
    accidentally_known = [
        key for key, (left, right) in differing.items() if known_reference_divergence(variant, None, key, left, right)
    ]
    if accidentally_known:
        raise AssertionError(f"the #182 allow-list swallowed unrelated differences in {accidentally_known}")
    return [f"agreement still bites: {len(a['chunkIntervals'])} intervals against {len(b['chunkIntervals'])}"]


#: An opcode and a u64 length precede every record's content.
RECORD_HEADER_BYTES = 9


def _rewrite_quantization(path: str, out: str, mutate) -> None:
    """Copy a file while changing fixed-width Quantization fields, not its bounds map."""
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    for record in iter_records(bytes(data), len(MAGIC)):
        if record.opcode != QUANTIZATION:
            continue
        quantization = rec.Quantization.parse(record.content)
        mutate(quantization)
        replacement = quantization.encode()
        span = slice(record.offset, record.offset + RECORD_HEADER_BYTES + len(record.content))
        if len(replacement) != span.stop - span.start:
            raise AssertionError("rewriting Quantization changed its length; the file's offsets would move")
        data[span] = replacement
        break
    else:
        raise AssertionError(f"{path} carries no Quantization record to rewrite")
    with open(out, "wb") as fh:
        fh.write(bytes(data))


def _test_declared_temporal_bounds_bite(tmp: str) -> list[str]:
    """Inflated grid pitches do not inflate the independent bounds declaration."""
    scene = fourdgs.read(_self_test_source())
    scene.gaussians.sigma_t = np.full_like(scene.gaussians.sigma_t, np.inf)
    scene.gaussians.win_lo = np.zeros_like(scene.gaussians.win_lo)
    scene.gaussians.win_hi = np.full_like(scene.gaussians.win_hi, scene.header.duration_sec)
    scene.gaussians.motions = np.zeros_like(scene.gaussians.motions)
    scene.gaussians.mu_t = np.zeros_like(scene.gaussians.mu_t)
    seed = os.path.join(tmp, "temporal-seed.4dgs")
    _write(scene, seed, write_crc=False)
    seeded = fourdgs.read(seed)
    # always-visible over an eight-second window is life class 2, so its own motion
    # pitch is one quarter of the record's base pitch. Put every value on bin one;
    # doubling the base pitch then moves it by exactly half the new pitch (legal by
    # the grid alone) but by twice bounds.pos over the two-second displacement cap.
    seeded.gaussians.motions[:, 0] = np.float32(seeded.quantization.step_motion / 4.0)
    seeded.gaussians.mu_t[:] = np.float32(seeded.quantization.step_time)
    source = os.path.join(tmp, "temporal-source.4dgs")
    _write(seeded, source, write_crc=False)

    scene = fourdgs.read(source)
    written = os.path.join(tmp, "temporal-bounds.4dgs")
    _write(scene, written, write_crc=False)

    motion = os.path.join(tmp, "inflated-motion-grid.4dgs")
    _rewrite_quantization(written, motion, lambda q: setattr(q, "step_motion", q.step_motion * 2.0))
    time = os.path.join(tmp, "inflated-time-grid.4dgs")
    _rewrite_quantization(written, time, lambda q: setattr(q, "step_time", q.step_time * 2.0))
    return [
        _expect_failure("bounds/motion", lambda: check_fidelity(source, motion), "displaces its gaussian"),
        _expect_failure("bounds/time", lambda: check_fidelity(source, time), "temporal bound"),
    ]


def _rewrite_index_entry(path: str, out: str, mutate, select=lambda entry: True) -> None:
    """Copy a file, changing the first chunk index entry `select` accepts.

    Every field an entry holds is fixed-width, so the record's length — and every offset in
    the file — is unchanged, which is what makes this a lie about the file rather than a
    corrupt file. That is the point: the mutated file still decodes.
    """
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    for record in iter_records(bytes(data), len(MAGIC)):
        if record.opcode != CHUNK_INDEX:
            continue
        entry = rec.ChunkIndexEntry.parse(record.content)
        if not select(entry):
            continue
        mutate(entry)
        replacement = entry.encode()
        span = slice(record.offset, record.offset + RECORD_HEADER_BYTES + len(record.content))
        if len(replacement) != span.stop - span.start:
            raise AssertionError("rewriting the entry changed its length; the file's offsets would move")
        data[span] = replacement
        break
    else:
        raise AssertionError(f"{path} carries no chunk index entry to rewrite")
    with open(out, "wb") as fh:
        fh.write(bytes(data))


def _test_index_counts_bite(tmp: str) -> list[str]:
    """The index's declared counts, on both temporal models.

    The gaussian-birth half runs over what the gate writes every day. The keyframe-delta half
    would otherwise never run at all — the encode corpus is gaussian-birth only — so it is
    exercised here against the keyframe fixtures, deliberately, rather than left as a branch
    that has never executed.
    """
    source = _self_test_source()
    scene = fourdgs.read(source)
    written = os.path.join(tmp, "indexed.4dgs")
    _write(scene, written, write_crc=False)
    check_index_counts(written)

    said = []
    lying = os.path.join(tmp, "index-lies.4dgs")
    _rewrite_index_entry(written, lying, lambda e: setattr(e, "gaussian_count", e.gaussian_count + 1))
    said.append(_expect_failure("index/gaussian-birth", lambda: check_index_counts(lying), "which holds"))

    bad_length = os.path.join(tmp, "index-chunk-length.4dgs")
    _rewrite_index_entry(written, bad_length, lambda e: setattr(e, "chunk_length", e.chunk_length + 1))
    said.append(_expect_failure("index/chunk-length", lambda: check_index_counts(bad_length), "chunk_length"))

    with open(written, "rb") as fh:
        indexed_data = fh.read()
    entries = [
        rec.ChunkIndexEntry.parse(record.content)
        for record in iter_records(indexed_data, len(MAGIC))
        if record.opcode == CHUNK_INDEX
    ]
    same_count = next(
        ((a, b) for i, a in enumerate(entries) for b in entries[i + 1 :] if a.gaussian_count == b.gaussian_count),
        None,
    )
    if same_count is None:
        raise AssertionError("the index fixture has no two equally sized chunks for the one-to-one mutation")
    omitted, duplicated = same_count
    duplicate = os.path.join(tmp, "index-duplicate.4dgs")

    def duplicate_offset(entry):
        entry.chunk_offset = duplicated.chunk_offset
        entry.chunk_length = duplicated.chunk_length

    _rewrite_index_entry(
        written,
        duplicate,
        duplicate_offset,
        select=lambda entry: entry.chunk_offset == omitted.chunk_offset,
    )
    said.append(_expect_failure("index/one-to-one", lambda: check_index_counts(duplicate), "not one-to-one"))

    sh_source = fourdgs.read(os.path.join(DATA, "MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc.4dgs"))
    sh_written = os.path.join(tmp, "indexed-sh.4dgs")
    _write(sh_source, sh_written, write_crc=False)
    bad_band_length = os.path.join(tmp, "index-band-length.4dgs")

    def lengthen_band(entry):
        band, offset, length = entry.bands[0]
        entry.bands[0] = (band, offset, length + 1)

    _rewrite_index_entry(sh_written, bad_band_length, lengthen_band, select=lambda entry: bool(entry.bands))
    said.append(_expect_failure("index/band-length", lambda: check_index_counts(bad_band_length), "physical record"))

    keyframe = os.path.join(DATA, "keyframe", "KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
    if not os.path.exists(keyframe):
        raise AssertionError(f"{keyframe} is missing; run tests/conformance/generate.py first")
    check_index_counts(keyframe)

    # The swap PR #194 found: `gaussian_count` counts operations and `live_count` counts the
    # population after composition, so exchanging them on a delta entry leaves a file that
    # reconstructs perfectly and misstates both the seek cost and the population.
    swapped = os.path.join(tmp, "keyframe-swapped.4dgs")

    def swap(entry):
        entry.gaussian_count, entry.live_count = entry.live_count, entry.gaussian_count

    _rewrite_index_entry(keyframe, swapped, swap, select=lambda e: e.kind == 1)
    said.append(_expect_failure("index/keyframe-delta", lambda: check_index_counts(swapped), "live_count"))

    bad_kind = os.path.join(tmp, "index-kind.4dgs")
    _rewrite_index_entry(keyframe, bad_kind, lambda e: setattr(e, "kind", 7))
    said.append(_expect_failure("index/kind", lambda: check_index_counts(bad_kind), "the format defines 0 and 1"))
    return said


def _test_objects_profile_refusal_agreement(_tmp: str) -> list[str]:
    """Either exact normative refusal agrees; writes and ordinary crashes do not."""
    message = "the objects profile requires one ObjectTable record, but none was supplied"
    python = RuntimeError(f"fourdgs.exceptions.InvalidInput: {message}")
    rust = RuntimeError(f"scene.4dgs: encoding failed: invalid input: {message}")
    typescript = RuntimeError(f"Error: {message}\n    at encodeScene (writer.js:1:1)")
    dart = RuntimeError(f"4dgs: {message}")
    for left, right in itertools.combinations((python, rust, typescript, dart), 2):
        if _matching_objects_profile_refusal(left, right, "objects") is None:
            raise AssertionError(f"runner wrappers hid an exact shared refusal:\n{left}\n{right}")

    if _matching_objects_profile_refusal(python, rust, "") is not None:
        raise AssertionError("matching profile diagnostics on a non-objects source were treated as agreement")

    missing_ids = RuntimeError(
        "Error: the objects profile requires an object_id stream in every non-empty chunk, "
        "but the GaussianSet carries none"
    )
    if _matching_objects_profile_refusal(python, missing_ids, "objects") is None:
        raise AssertionError("the two normative objects-profile promises did not agree as refusals")
    if _matching_objects_profile_refusal(python, None, "objects") is not None:
        raise AssertionError("one writer refusing while the other writes was treated as agreement")
    imprecise = RuntimeError("Error: the objects profile requires an object_id stream")
    if _matching_objects_profile_refusal(python, imprecise, "objects") is not None:
        raise AssertionError("an imprecise profile diagnostic was treated as normative")
    crash = RuntimeError("Error: encoder crashed while allocating a chunk")
    if _matching_objects_profile_refusal(crash, crash, "objects") is not None:
        raise AssertionError("a shared crash message was treated as a normative refusal")
    return ["all runner wrappers expose one of two exact objects-profile diagnostics"]


def run_self_test() -> int:
    tests = (
        _test_tolerance_is_read_from_the_file,
        _test_fidelity_catches_a_changed_scene,
        _test_declared_temporal_bounds_bite,
        _test_agreement_still_catches_divergence,
        _test_objects_profile_refusal_agreement,
        _test_index_counts_bite,
    )
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for test in tests:
            name = test.__name__.removeprefix("_test_")
            try:
                for line in test(tmp):
                    print(f"  {line}")
                print(f"ok   {name}")
            except AssertionError as exc:
                failed += 1
                print(f"FAIL {name}\n  {exc}")
    print(f"\n{len(tests)} self-tests, {failed} failed")
    return 1 if failed else 0


# --------------------------------------------------------------------------


def entry_point(command: list[str]) -> str:
    """The path whose existence decides whether a family is built.

    The last argument that is not a flag: the compiled binary, the script node runs, or —
    for the Python reference, which is this file — this file.
    """
    return next(argument for argument in reversed(command) if not argument.startswith("-"))


def run_encoder(encoder: str) -> int:
    command = ENCODERS[encoder]
    if not os.path.exists(entry_point(command)):
        print(f"skipping {encoder}: {entry_point(command)} is not built")
        return 0

    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1

    second_encoder = encoder in SECOND_ENCODERS
    # The Python reference is not a candidate like the others: measured against the Rust
    # reference it is one half of #182, and those divergences are open specification
    # questions rather than defects in an encoder. They are named on every run, and counted,
    # so tolerating them stays visible — but they do not turn the gate red while the
    # question is undecided. The list shrinks to nothing as #182 is answered.
    allow_known = encoder == "python"
    check_chunk_geometry = encoder in CHUNK_GEOMETRY_ENCODERS
    check_aabb_geometry = encoder in AABB_GEOMETRY_ENCODERS
    normalize_capture_profile = encoder in CAPTURE_PROFILE_NORMALIZATION_ENCODERS
    allow_independent_chunk_layout = encoder in INDEPENDENT_CHUNK_LAYOUT_ENCODERS

    agreed = graded = failed = tolerated = 0
    with tempfile.TemporaryDirectory() as tmp:
        for variant in names:
            source = os.path.join(DATA, f"{variant}.4dgs")
            graded_pass = "SHDegree" in variant and encoder in SH_LADDER_ENCODERS
            for ladder in [None] + ([SH_LADDER] if graded_pass else []):
                label = variant if ladder is None else f"{variant} @ {ladder}"
                try:
                    notes = compare(
                        REFERENCE,
                        command,
                        source,
                        tmp,
                        ladder,
                        second_encoder,
                        allow_known,
                        check_chunk_geometry,
                        check_aabb_geometry,
                        normalize_capture_profile,
                        allow_independent_chunk_layout,
                    )
                except (AssertionError, RuntimeError) as exc:
                    failed += 1
                    print(f"FAIL {encoder} {label}\n  {exc}")
                    break
                for note in notes:
                    tolerated += 1
                    print(f"KNOWN {label}\n  {note}")
                if ladder is None:
                    agreed += 1
                else:
                    graded += 1

    accounted = f", {tolerated} known divergences (#182)" if tolerated else ""
    print(
        f"\n{agreed} variants re-encoded, {graded} at per-band SH depths, {failed} failed{accounted}; "
        "each inside the bounds it declares against its source, and agreeing with the reference"
    )
    return 1 if failed else 0


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv and argv[0] == WRITE_FLAG:
        return write_with_python_reference(argv[1:])

    parser = argparse.ArgumentParser(description="the cross-language 4dgs encode gate")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--encoder", choices=sorted(ENCODERS), help="which encoder to prove")
    mode.add_argument(
        "--references",
        action="store_true",
        help="run the Python and Rust references against each other over the corpus (#182)",
    )
    mode.add_argument("--self-test", action="store_true", help="prove this gate's own checks bite")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if not os.path.exists(REFERENCE[-1]):
        print(
            f"error: the reference {REFERENCE[-1]} is not built; run cargo build --release --workspace", file=sys.stderr
        )
        return 1
    return run_references() if args.references else run_encoder(args.encoder)


if __name__ == "__main__":
    sys.exit(main())
