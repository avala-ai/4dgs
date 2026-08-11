#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the Dart encoder against another implementation.
#
# For every corpus variant: decode it, re-encode the gaussians with the Dart encoder, then
# make two separate claims about the result.
#
# **Fidelity.** The written scene is compared against the scene it was written from, by the
# Python reference reader, attribute by attribute, against the error bounds the written file
# itself declares. This is the claim the agreement check below cannot make: four decoders
# reading one file identically say nothing about whether that file is the scene that went
# in. An encoder that displaced every position, greyed every colour or dropped every
# velocity produces a file all four read the same way, and it is wrong.
#
# **Agreement.** The result is decoded by three independent implementations — Dart's own, the
# Python reference and the Rust reference — on both read paths each, and all six canonical
# summaries must be identical. An encoder checked only by its own decoder proves that two
# halves of one implementation share an opinion, which is exactly the failure mode a
# conformance suite exists to catch; two implementations can still share a misreading of one
# sentence of the specification. Three, written independently, is a real claim.
#
# Neither claim implies the other, which is why both are made.
#
# Both read paths on both sides, because they fail differently: the streamed path never
# looks at the index, so a file with a wrong summary offset or a wrong chunk range still
# decodes there and only the indexed path notices.
#
# Usage: dart/encode-roundtrip.sh [output-dir]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

# Windows names an executable with a suffix, and the interpreter is `python` there rather
# than `python3` — a Windows Python installation ships no `python3.exe`. Both are resolved
# once here so the rest of the script reads the same on every platform.
exe=""
[ "${OS:-}" = "Windows_NT" ] && exe=".exe"
if command -v python3 >/dev/null 2>&1; then
  python=python3
else
  python=python
fi

encode="$root/dart/conformance/build/encode_roundtrip$exe"
decode_dart_streamed="$root/dart/conformance/build/decode_streamed$exe"
decode_dart_indexed="$root/dart/conformance/build/decode_indexed$exe"
decode_python_streamed="$root/python/conformance/decode_streamed.py"
decode_python_indexed="$root/python/conformance/decode_indexed.py"
decode_rust_streamed="$root/target/release/decode_streamed$exe"
decode_rust_indexed="$root/target/release/decode_indexed$exe"

# Every reader is required, and a missing one is an error rather than a reader quietly
# dropped from the comparison. A gate that skips itself when a binary is absent reports
# green for a run that proved less than it says it did, and the shape of this script — a
# count printed at the end — is exactly the shape that hides it.
for binary in \
  "$encode" "$decode_dart_streamed" "$decode_dart_indexed" \
  "$decode_rust_streamed" "$decode_rust_indexed"; do
  [ -x "$binary" ] || {
    echo "::error::$binary is not built; run dart compile exe in dart/conformance and" \
      "cargo build -p fourdgs-conformance --release"
    exit 1
  }
done
for script in "$decode_python_streamed" "$decode_python_indexed"; do
  [ -f "$script" ] || {
    echo "::error::$script is missing"
    exit 1
  }
done

shopt -s nullglob
variants=("$root"/tests/conformance/data/*.4dgs)
if [ ${#variants[@]} -eq 0 ]; then
  echo "::error::no corpus; run tests/conformance/generate.py first"
  exit 1
fi

agreed=0
for source in "${variants[@]}"; do
  name="$(basename "$source" .4dgs)"
  "$encode" "$source" "$out/$name.4dgs" >"$out/$name.note"
  # Fidelity: the encoded scene against the scene it was encoded from, before any
  # of the agreement checks below. Four decoders agreeing about one file say
  # nothing about whether that file is the scene that went in — an encoder that
  # displaced every position by a metre, or coarsened every colour to grey, is
  # read identically by all four. This is the check that fails on that, and it is
  # made by the Python reference reader against bounds the Dart-written file
  # declares about itself.
  "$python" - "$source" "$out/$name.4dgs" "$name" "$root" <<'PY'
import os
import sys

import numpy as np

source, encoded, name, root = sys.argv[1:5]
# Installed is the normal case; the path is for a checkout where it is not.
sys.path.insert(0, os.path.join(root, "python", "fourdgs"))
import fourdgs


def fail(detail):
    print(f"::error::{name}: {detail}")
    sys.exit(1)


source_scene = fourdgs.read(source)
src = source_scene.gaussians
scene = fourdgs.read(encoded)
enc = scene.gaussians
expected_profile = "" if source_scene.header.profile == "objects" else source_scene.header.profile
if scene.header.duration_sec != source_scene.header.duration_sec:
    fail(
        f"duration_sec changed from {source_scene.header.duration_sec} "
        f"to {scene.header.duration_sec}"
    )
if scene.header.cutoff != source_scene.header.cutoff:
    fail(f"cutoff changed from {source_scene.header.cutoff} to {scene.header.cutoff}")
if dict(scene.header.attributes) != dict(source_scene.header.attributes):
    fail(
        f"Header attributes changed from {dict(source_scene.header.attributes)} "
        f"to {dict(scene.header.attributes)}"
    )
if scene.header.profile != expected_profile:
    fail(
        f"scene profile is {scene.header.profile!r}, expected {expected_profile!r} "
        "after the gaussian-only preset's documented downgrade"
    )
if enc.count != src.count:
    fail(f"the encoder wrote {enc.count} gaussians for {src.count}")
if enc.count == 0:
    sys.exit(0)

# The bounds the written file declares about itself, so the tolerance is the
# encoder's own promise rather than a number chosen here to make this pass.
declared = {k: float(v) for k, v in scene.quantization.bounds.items() if not k.startswith("sh_band")}

# A chunk is ordered by Morton code, so the nth gaussian out is not the nth in,
# and the pairing has to be recovered before anything can be compared.
#
# Position alone is not enough to recover it: `RepeatedPositions` is a variant
# built out of gaussians that share coordinates and differ in everything else, so
# the cost below spans several lanes, each normalized by its own scale. Every
# lane it uses is one the encoder is not free to change, which is what makes a
# wrong pairing impossible rather than merely unlikely: an encoder that really
# did corrupt a lane cannot hide in the matching, because the corruption raises
# the cost of the true pair and the mismatch it produces is then measured below.
def spread(a):
    lo, hi = float(np.min(a)), float(np.max(a))
    return max(hi - lo, 1e-6)


lanes = [
    (enc.positions.astype(np.float64), src.positions.astype(np.float64)),
    (enc.colors.astype(np.float64), src.colors.astype(np.float64)),
    (enc.mu_t.astype(np.float64)[:, None], src.mu_t.astype(np.float64)[:, None]),
    (np.nan_to_num(enc.win_lo.astype(np.float64), posinf=1e30, neginf=-1e30)[:, None],
     np.nan_to_num(src.win_lo.astype(np.float64), posinf=1e30, neginf=-1e30)[:, None]),
    (np.nan_to_num(enc.win_hi.astype(np.float64), posinf=1e30, neginf=-1e30)[:, None],
     np.nan_to_num(src.win_hi.astype(np.float64), posinf=1e30, neginf=-1e30)[:, None]),
]
cost = np.zeros((enc.count, src.count), dtype=np.float64)
for a, b in lanes:
    cost += np.abs(a[:, None, :] - b[None, :, :]).sum(axis=2) / spread(b)

# Greedy over the whole matrix, cheapest pair first. Two gaussians that really
# are interchangeable cost nothing to swap, which is why an exact assignment is
# not needed here — but every pair is still consumed exactly once, so a scene
# that lost a gaussian into a duplicate cannot pass.
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
    fail("the written gaussians do not pair one-to-one with the source's")

# Float32 storage costs a relative 1e-7 on the way out, four orders of magnitude
# below every bound here and not zero.
SLACK = 1e-6
worst = {}
worst["pos"] = np.abs(enc.positions - src.positions[pair]).max()
worst["scale_rel"] = np.abs(np.log(enc.scales.astype(np.float64) / src.scales[pair].astype(np.float64))).max()
worst["rgb"] = np.abs(enc.colors[:, :3] - src.colors[pair][:, :3]).max()
worst["alpha"] = np.abs(enc.colors[:, 3] - src.colors[pair][:, 3]).max()
finite = np.isfinite(src.sigma_t[pair]) & np.isfinite(enc.sigma_t)
worst["sigma_rel"] = (
    np.abs(np.log(enc.sigma_t[finite].astype(np.float64) / src.sigma_t[pair][finite].astype(np.float64))).max()
    if finite.any()
    else 0.0
)
if np.any(np.isfinite(src.sigma_t[pair]) != np.isfinite(enc.sigma_t)):
    fail("a gaussian changed between fading and never-fading, which is a flag and not a tolerance")

# `log(1 + bound)` is the promise in the log domain the two relative lanes are
# quantized in; the rest are absolute. Checked before the per-gaussian lanes
# below, so that a scene displaced or discoloured wholesale is diagnosed as
# that, rather than as the mismatched pairing it also produces.
limits = {
    "pos": declared["pos"] + SLACK,
    "scale_rel": np.log1p(declared["scale_rel"]) + SLACK,
    "rgb": declared["rgb"] + SLACK,
    "alpha": declared["alpha"] + SLACK,
    "sigma_rel": np.log1p(declared["sigma_rel"]) + SLACK,
}
for key, limit in limits.items():
    if not (worst[key] <= limit):
        fail(f"{key} deviates by {worst[key]:g}, past the {limit:g} this file declares")

# Quaternion sign is not an orientation: q and -q are the same rotation. The
# stored three residuals each carry the declared `rot` bound, while restoring
# and renormalizing the omitted component can amplify their error by a small
# factor (the writer's unit test covers the same worst-case envelope).
enc_q = enc.rotations.astype(np.float64)
src_q = src.rotations[pair].astype(np.float64)
enc_norm = np.linalg.norm(enc_q, axis=1)
src_norm = np.linalg.norm(src_q, axis=1)
if np.any(enc_norm == 0.0) or np.any(src_norm == 0.0):
    fail("a rotation has zero quaternion length")
enc_q /= enc_norm[:, None]
src_q /= src_norm[:, None]
same = np.max(np.abs(enc_q - src_q), axis=1)
flipped = np.max(np.abs(enc_q + src_q), axis=1)
rotation_error = np.minimum(same, flipped).max()
rotation_limit = 8.0 * declared["rot"] + SLACK
if rotation_error > rotation_limit:
    fail(f"a rotation deviates by {rotation_error:g}, past the {rotation_limit:g} reconstructed-quaternion envelope")

# Velocity and birth time are the two lanes whose grid is per gaussian, not per
# file: a short-lived gaussian is on screen briefly, so it tolerates a coarser
# velocity than a long-lived one, and `step_motion` in the record is the pitch
# for the reference lifetime rather than for any particular gaussian (spec §6.3).
# The reference encoder's own verification asserts neither for exactly that
# reason. So the pitch is derived here the way a decoder derives it — from the
# sigma bins, the window length and the cutoff this file declares — and each
# gaussian is held to half of its own.
from fourdgs.quantization import life_class, motion_steps, mu_steps, support_k

sigma_log = float(scene.quantization.step_sigma_log)
never_fades = ~np.isfinite(enc.sigma_t)
sigma_bins = np.where(never_fades, 0.0, np.log(np.where(never_fades, 1.0, enc.sigma_t.astype(np.float64))) / sigma_log)
sigma_bins = np.rint(sigma_bins)
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
    fail(f"a velocity is {motion_excess.max():g} past half the per-gaussian pitch this file's own grid gives it")
mu_excess = np.abs(enc.mu_t.astype(np.float64) - src.mu_t[pair].astype(np.float64)) - (mu_step / 2.0 + SLACK)
if mu_excess.max() > 0:
    fail(f"a birth time is {mu_excess.max():g} past half the per-gaussian pitch this file's own grid gives it")

# The validity windows are written verbatim, so they are not a tolerance at all.
if not np.array_equal(enc.win_lo, src.win_lo[pair]) or not np.array_equal(enc.win_hi, src.win_hi[pair]):
    fail("a validity window came back changed, and the Window Table stores them verbatim")

# Object membership is also verbatim and exact. Absence is distinct from a
# present all-zero stream: the latter explicitly assigns every gaussian to the
# background object and must survive a decode-then-encode round trip as a lane.
if (src.object_id is None) != (enc.object_id is None):
    fail("the object_id stream changed between present and absent")
if src.object_id is not None and not np.array_equal(enc.object_id, src.object_id[pair]):
    fail("an object_id changed, and object membership is an exact label")

# Spherical harmonics. Presence, degree and shape are checked BEFORE any
# coefficient is compared, and they are checked because the comparison cannot
# make them: an encoder that emitted no SH at all leaves `enc.sh` at None and
# skips a conditional, and one that emitted only a lower-degree prefix survives a
# comparison taken over the columns that happen to be in both. Either loses
# view-dependent appearance outright, and every decoder reads the degraded file
# the same way, so the agreement checks below cannot see it. This runner asks for
# every band (`shBands: 3`), so what went in is what must come out.
if (src.sh is None) != (enc.sh is None):
    fail(
        "the source carries spherical harmonics and the encoded file does not"
        if enc.sh is None
        else "the encoded file carries spherical harmonics the source does not"
    )
if src.sh is not None:
    if int(scene.header.sh_degree) != int(source_scene.header.sh_degree):
        fail(
            f"the encoded file declares SH degree {int(scene.header.sh_degree)}, "
            f"the source {int(source_scene.header.sh_degree)}"
        )
    if enc.sh.shape != src.sh.shape:
        fail(f"the SH block is {enc.sh.shape}, the source's {src.sh.shape}")
    # Bytes on a declared pitch: `step_sh` is what the encoder did, so the
    # deviation it allows is half of it — and the identity when the pitch is 1,
    # where a coefficient must survive byte for byte.
    step = max(1, int(scene.quantization.step_sh))
    deviation = np.abs(enc.sh.astype(np.int64) - src.sh[pair].astype(np.int64)).max()
    if deviation > step // 2:
        fail(f"an SH coefficient moved {deviation} codes, past the {step // 2} a pitch of {step} allows")
PY
  "$decode_dart_streamed" "$out/$name.4dgs" >"$out/$name.dart.streamed.json"
  "$decode_dart_indexed" "$out/$name.4dgs" >"$out/$name.dart.indexed.json"
  "$python" "$decode_python_streamed" "$out/$name.4dgs" >"$out/$name.python.streamed.json"
  "$python" "$decode_python_indexed" "$out/$name.4dgs" >"$out/$name.python.indexed.json"
  "$decode_rust_streamed" "$out/$name.4dgs" >"$out/$name.rust.streamed.json"
  "$decode_rust_indexed" "$out/$name.4dgs" >"$out/$name.rust.indexed.json"
  "$python" - "$out/$name" "$name" <<'PY'
import json
import sys

prefix, name = sys.argv[1], sys.argv[2]
readers = (
    "dart.streamed",
    "dart.indexed",
    "python.streamed",
    "python.indexed",
    "rust.streamed",
    "rust.indexed",
)
summaries = {}
for reader in readers:
    with open(f"{prefix}.{reader}.json", encoding="utf-8") as fh:
        summaries[reader] = json.load(fh)

reference = summaries["python.streamed"]
disagreed = [r for r in readers if summaries[r] != reference]
if disagreed:
    print(f"::error::{name}: {disagreed} disagree with python.streamed on a file the Dart encoder wrote")
    for reader in disagreed:
        for key in sorted(set(reference) | set(summaries[reader])):
            if reference.get(key) != summaries[reader].get(key):
                print(f"  {key}\n    python: {json.dumps(reference.get(key))[:300]}")
                print(f"    {reader}: {json.dumps(summaries[reader].get(key))[:300]}")
    sys.exit(1)
PY
  agreed=$((agreed + 1))
  echo "  $name: $(cat "$out/$name.note")"
done

echo "$agreed variants re-encoded by Dart; every one inside the bounds it declares against its source, and the Dart, Python and Rust decoders agree on it, both read paths each"
