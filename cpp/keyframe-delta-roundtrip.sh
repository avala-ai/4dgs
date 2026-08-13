#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the C++ `keyframe-delta` encoder (spec §11).
#
# `tests/conformance/encode_roundtrip.py --encoder cpp` is the gate for the gaussian-birth
# writer and it cannot serve this one: it re-encodes a corpus variant's decoded gaussians, and
# a keyframe-delta file yields no decoded sample sequence to hand back to a writer. So the
# runner synthesizes one, and this script makes four separate claims about every file it
# writes. None implies another, which is why all four are made.
#
# **Fidelity.** The written file, decoded by the *Python reference*, is compared lane by lane
# against the population that went in, inside the error bounds the written file itself
# declares. This is the claim no amount of decoder agreement can make: an encoder that
# displaced every position or doubled every velocity produces a file every decoder reads the
# same way, and it is wrong.
#
# **Agreement.** The C++ decoder and the Python reference each read the result, and their
# canonical `states` summaries must be identical. The C++ runner has already required its own
# two read paths to agree before writing anything, and the Python runner does the same, so
# four decodes stand behind each comparison.
#
# **The index.** Every count a chunk index entry declares, against the records it points at —
# `gaussian_count` counts a delta's operations and `live_count` counts the population after
# composition, and a writer that swapped them produces a file that reconstructs perfectly and
# lies about the cost of a seek. `encode_roundtrip.check_index_counts` already owns that check
# for every encoder in this repository, so it is called rather than restated.
#
# **Byte identity with the reference writer.** C++ is a binding over the Rust core rather than
# a second encoder, so the thing to prove is that the samples and options were wired through,
# not that two encoders agree about layout. Given the same samples and the same options the
# binding must produce exactly the file `rust/conformance/src/bin/encode_keyframe_delta.rs`
# produces — the two runners synthesize the same sequence from the same LCG, and the C++ one
# is compiled with floating-point contraction off so that the arithmetic is IEEE and the
# comparison is a statement about the binding rather than about a compiler.
#
# Usage: cpp/keyframe-delta-roundtrip.sh [output-dir]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

# Windows names an executable with a suffix, and the interpreter is `python` there rather than
# `python3` — a Windows Python installation ships no python3.exe.
exe=""
[ "${OS:-}" = "Windows_NT" ] && exe=".exe"
if command -v python3 >/dev/null 2>&1; then
  python=python3
else
  python=python
fi

encode="$root/cpp/build/conformance/encode_keyframe_delta$exe"
cpp_streamed="$root/cpp/build/conformance/decode_streamed$exe"
cpp_indexed="$root/cpp/build/conformance/decode_indexed$exe"
py_decode="$root/python/conformance/decode_keyframe_delta.py"
reference="$root/target/release/encode_keyframe_delta$exe"

for binary in "$encode" "$cpp_streamed" "$cpp_indexed"; do
  [ -x "$binary" ] || {
    echo "::error::$binary is not built; run cmake --build cpp/build"
    exit 1
  }
done
[ -x "$reference" ] || {
  echo "::error::$reference is not built; run cargo build -p fourdgs-conformance --release"
  exit 1
}

checked=0
# `cadence-one` is the §11.11 shape — every chunk a keyframe, no delta chunk anywhere — and it
# is here because a writer can reach it by cadence alone and nothing else in this repository
# proves the C++ binding does. The reference runner has no such mode, so it is the one shape
# with no byte-identity leg.
for shape in chained keyframe cadence-one; do
  "$encode" "$out" "$shape"
  file="$out/keyframe-delta-$shape.4dgs"

  if [ "$shape" != "cadence-one" ]; then
    "$reference" "$out/reference-$shape.4dgs" "$shape" >/dev/null
    cmp -s "$out/reference-$shape.4dgs" "$file" || {
      echo "::error::$shape: the binding and the Rust reference writer disagree byte for byte"
      exit 1
    }
  fi

  "$cpp_streamed" "$file" >"$out/$shape.cpp.streamed.json"
  "$cpp_indexed" "$file" >"$out/$shape.cpp.indexed.json"
  "$python" "$py_decode" "$file" >"$out/$shape.python.json"

  "$python" - "$out" "$shape" "$root" <<'PY'
import json
import os
import sys

import numpy as np

out, shape, root = sys.argv[1], sys.argv[2], sys.argv[3]
# Installed is the normal case; the path is for a checkout where it is not.
sys.path.insert(0, os.path.join(root, "python", "fourdgs"))
sys.path.insert(0, os.path.join(root, "tests", "conformance"))

from encode_roundtrip import check_index_counts
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op

encoded = os.path.join(out, f"keyframe-delta-{shape}.4dgs")


def fail(detail):
    print(f"::error::{shape}: {detail}")
    sys.exit(1)


# --- agreement ---------------------------------------------------------------
#
# Three summaries, two implementations. Each runner has already required its own two read
# paths to agree, so a disagreement here is between languages rather than between halves of
# one of them.
summaries = {}
for reader in ("cpp.streamed", "cpp.indexed", "python"):
    with open(os.path.join(out, f"{shape}.{reader}.json"), encoding="utf-8") as fh:
        summaries[reader] = json.load(fh)
for reader in ("cpp.indexed", "python"):
    if summaries[reader] != summaries["cpp.streamed"]:
        for key in sorted(set(summaries[reader]) | set(summaries["cpp.streamed"])):
            if summaries[reader].get(key) != summaries["cpp.streamed"].get(key):
                print(f"  {key}")
                print(f"    cpp.streamed: {json.dumps(summaries['cpp.streamed'].get(key))[:300]}")
                print(f"    {reader}: {json.dumps(summaries[reader].get(key))[:300]}")
        fail(f"{reader} disagrees with cpp.streamed on a file the C++ binding wrote")

# --- the index ---------------------------------------------------------------
check_index_counts(encoded)

# --- fidelity ----------------------------------------------------------------
with open(os.path.join(out, f"keyframe-delta-{shape}.samples.json"), encoding="utf-8") as fh:
    written_from = json.load(fh)
samples = written_from["samples"]

with open(encoded, "rb") as fh:
    data = fh.read()
decoded = kdf.decode_streamed(data)
grids = decoded.grids
if len(decoded.chunks) != len(samples):
    fail(f"the encoder wrote {len(decoded.chunks)} chunks for {len(samples)} samples")

# The shape the options asked for actually arrived. `cadence-one` is the one sequence with no
# byte-identity leg above — the reference runner has no such mode — so without this the
# cadence and the delta mode could be dropped on the way to the core and every other claim
# here would still hold: a file made entirely of keyframes reconstructs correctly, agrees with
# every decoder, and is not the file that was asked for.
kinds = [chunk.kind for chunk in decoded.chunks]
if shape == "cadence-one":
    if any(kind != 0 for kind in kinds):
        fail(f"cadence one must write every chunk as a keyframe (§11.11); kinds are {kinds}")
else:
    if not any(kind == 1 for kind in kinds):
        fail(f"{shape} asked for deltas at cadence 8 and the file carries none; kinds are {kinds}")
    modes = {chunk.delta_mode for chunk in decoded.chunks if chunk.kind == 1}
    expected_mode = {1} if shape == "chained" else {0}
    if modes != expected_mode:
        fail(f"the deltas declare mode {modes}, not the {expected_mode} the options asked for")

distinct = {int(i) for s in samples for i in s["ids"]}
if decoded.header.gaussian_count != len(distinct):
    fail(
        f"the Header declares gaussian_count {decoded.header.gaussian_count}; under "
        f"keyframe-delta that is the count of DISTINCT ids over the sequence, which is "
        f"{len(distinct)} — not a sum over chunks, which would be "
        f"{sum(len(s['ids']) for s in samples)}"
    )

# The tolerance is the file's own promise, not a number chosen here to make this pass. The
# reference keyframe-delta writer declares grid pitches and leaves the `bounds` map empty, so
# the promise is read from the pitches by §5.3's own definition — `ε = s/2` on a uniform grid
# — rather than from a map that is not there. `scale_rel` and `sigma_rel` are quantized in the
# log domain, so half of their pitch is already the bound on `|log(got/src)|` and needs no
# further transform. Float32 storage costs a relative 1e-7 on the way out, orders of magnitude
# below every one of these and not zero.
quantization = decoded.quantization
SLACK = 1e-6
limits = {
    "pos": quantization.step_pos / 2.0 + SLACK,
    "scale_rel": quantization.step_scale_log / 2.0 + SLACK,
    "rgb": quantization.step_rgb / 2.0 + SLACK,
    "alpha": quantization.step_alpha / 2.0 + SLACK,
    "sigma_rel": quantization.step_sigma_log / 2.0 + SLACK,
}
rotation_residual = quantization.step_rot / 2.0
if not all(limit > SLACK for limit in limits.values()) or rotation_residual <= 0.0:
    fail(f"the file declares a non-positive grid pitch, so there is nothing to hold it to: {limits}")
windows = np.asarray(grids.windows, dtype=np.float64)
mu_by_offset = {}

for i, sample in enumerate(samples):
    chunk = decoded.chunks[i]
    if abs(chunk.t0 - float(sample["t0"])) > 1e-12:
        fail(f"chunk {i} starts at {chunk.t0}, the sample it was written from at {sample['t0']}")
    n = int(sample["count"])
    if chunk.state.count != n:
        fail(f"chunk {i} composes to {chunk.state.count} gaussians, the sample carries {n}")

    # Both sides in ascending gaussian_id, which is the one order the format defines (§11.2).
    # Identity is what pairs a written gaussian with a source one — a keyframe-delta file
    # names every gaussian outright, so no nearest-neighbour matching is needed or wanted.
    got_order = np.argsort(chunk.state.ids, kind="stable")
    got_ids = np.asarray(chunk.state.ids)[got_order]
    src_ids = np.asarray(sample["ids"], dtype=np.int64)
    src_order = np.argsort(src_ids, kind="stable")
    if not np.array_equal(got_ids, src_ids[src_order]):
        fail(f"chunk {i} composes to ids {got_ids.tolist()}, the sample names {src_ids[src_order].tolist()}")
    if n == 0:
        mu_by_offset[chunk.offset] = {}
        continue

    values = kdf._dequantize(chunk.state, grids)

    def got(key, channels=1, order=got_order):
        v = np.asarray(values[key], dtype=np.float64)
        return v[order] if channels == 1 else v[order, :channels]

    def src(key, channels=1, order=src_order, rows=n):
        v = np.asarray(sample[key], dtype=np.float32).reshape(rows, channels).astype(np.float64)
        return v[order] if channels > 1 else v[order, 0]

    worst = {
        "pos": np.abs(got("positions", 3) - src("positions", 3)).max(),
        "scale_rel": np.abs(np.log(got("scales", 3) / src("scales", 3))).max(),
        "rgb": np.abs(got("colors", 4)[:, :3] - src("colors", 4)[:, :3]).max(),
        "alpha": np.abs(got("colors", 4)[:, 3] - src("colors", 4)[:, 3]).max(),
        "sigma_rel": np.abs(np.log(got("sigma_t") / src("sigmaT"))).max(),
    }
    for key, limit in limits.items():
        if not (worst[key] <= limit):
            fail(f"chunk {i}: {key} deviates by {worst[key]:g}, past the {limit:g} this file declares")

    # Velocity and birth time are the two lanes whose grid is per gaussian, not per file: a
    # short-lived gaussian is on screen briefly, so it tolerates a coarser velocity, and
    # `step_motion` in the record is the pitch for the reference lifetime rather than for any
    # particular gaussian (§6.3). So the pitch is derived here the way a decoder derives it —
    # from this file's own sigma bins, window lengths and cutoff — and each gaussian is held
    # to half of its own.
    bins = chunk.state.bins
    sigma_bins = bins[op.A_SIGMA_T][:, 0]
    never_fades = bins[op.A_FLAGS][:, 0] != 0
    m_step = grids.motion_step(sigma_bins, never_fades, bins[op.A_WINDOW_INDEX][:, 0])[got_order]
    t_step = grids.mu_step(sigma_bins, never_fades)[got_order]
    motion_excess = np.abs(got("motions", 3) - src("motions", 3)).max(axis=1) - (m_step / 2.0 + SLACK)
    if motion_excess.max() > 0:
        fail(
            f"chunk {i}: a velocity is {motion_excess.max():g} past half the per-gaussian pitch "
            f"this file's own grid gives it"
        )

    # §11.3 says a keyframe anchors every gaussian it states to its own t0 — one constant
    # stream, and what makes `center` read `position + motion * (t - t0)`. A delta restates the
    # anchor for every gaussian whose `mu_t` bin moved and leaves it alone for one whose did
    # not, and an untouched gaussian keeps the anchor of the chunk that last stated it and
    # keeps extrapolating from there, exactly and at no cost. Both outcomes are legal; an
    # anchor that is neither is a corrupted one, and this is what separates them.
    got_mu = got("mu_t")
    src_mu = src("muT")
    at_t0 = float(sample["t0"])
    reference_mu = {} if chunk.kind == 0 else mu_by_offset.get(chunk.reference_offset, {})
    for row, gid in enumerate(got_ids):
        half = t_step[row] / 2.0 + SLACK
        if chunk.kind == 0:
            if abs(got_mu[row] - at_t0) > half:
                fail(
                    f"chunk {i}: keyframe gaussian {gid} is anchored at {got_mu[row]:g}, not at "
                    f"the chunk's own t0 {at_t0:g} (§11.3)"
                )
            continue
        restated = abs(got_mu[row] - src_mu[row]) <= half
        # "Its bin did not move" means the source's anchor and the reference's share a bin, so
        # they are within one pitch of each other — not half of one.
        held = int(gid) in reference_mu and abs(got_mu[row] - reference_mu[int(gid)]) <= half and (
            abs(src_mu[row] - reference_mu[int(gid)]) <= t_step[row] + SLACK
        )
        if not restated and not held:
            fail(
                f"chunk {i}: gaussian {gid} composes to an anchor of {got_mu[row]:g}, which is "
                f"neither the {src_mu[row]:g} the sample stated nor the anchor its reference "
                f"chunk left it with"
            )
    mu_by_offset[chunk.offset] = {
        int(gid): float(mu) for gid, mu in zip(chunk.state.ids, np.asarray(values["mu_t"]))
    }

    # Rotation is smallest-three: three residuals on the declared pitch, and the omitted
    # component recovered as a square root, which spreads their error over the fourth. The
    # largest component is at least 1/2 by construction, so the amplification is bounded and
    # eight times the residual bound is a limit a real corruption cannot hide under. Under
    # §11.5 rotation is restated absolutely by every update, so this bound is the pitch's,
    # applied once, at every depth.
    q_got = got("rotations", 4)
    q_src = src("rotations", 4)
    q_src = q_src / np.maximum(np.linalg.norm(q_src, axis=1, keepdims=True), 1e-30)
    # `q` and `-q` are the same rotation, and the coding canonicalizes the sign.
    rot_worst = np.minimum(np.abs(q_got - q_src).max(axis=1), np.abs(q_got + q_src).max(axis=1)).max()
    if not (rot_worst <= 8.0 * rotation_residual + SLACK):
        fail(
            f"chunk {i}: a rotation moved {rot_worst:g}, past the {8.0 * rotation_residual:g} the "
            f"smallest-three coding on this file's pitch allows"
        )

    # The validity window is stored verbatim in the Window Table, so it is not a tolerance at
    # all: the row `window_index` names must be the window the gaussian went in with.
    rows = np.asarray(values["window_index"], dtype=np.int64)[got_order]
    if not np.array_equal(windows[rows, 0], src("winLo")) or not np.array_equal(
        windows[rows, 1], src("winHi")
    ):
        fail(f"chunk {i}: a validity window came back changed, and the Window Table stores them verbatim")
PY

  checked=$((checked + 1))
  echo "  keyframe-delta-$shape"
done

echo "$checked keyframe-delta sequences written by the C++ binding; every one inside the bounds it declares against its source, agreed on by the C++ and Python decoders, and byte for byte the reference writer's file"
