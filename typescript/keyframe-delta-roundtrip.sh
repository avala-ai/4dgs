#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the TypeScript `keyframe-delta` encoder.
#
# `tests/conformance/encode_roundtrip.py` is the gate for the gaussian-birth writer, and it
# has a known blind spot (#189): it proves two encoders agree, not that either preserved the
# scene, so a fault present in both passes. A keyframe-delta file has no second encoder here
# at all, so this script makes three separate claims about every sequence it writes.
#
# **Fidelity.** The written file, decoded by the *Python* reference, is compared lane by lane
# against the population that went in, against the error bounds the written file itself
# declares. This is the claim no amount of decoder agreement can make: an encoder that
# displaced every position or doubled every velocity produces a file every decoder reads the
# same way, and it is wrong.
#
# **Agreement.** Python and TypeScript each decode the result on both read paths, and all
# four canonical summaries must be identical. The two read paths fail differently — the
# streamed one never looks at the index, so a wrong offset or a wrong chunk range decodes
# there and only the indexed path notices — and an encoder checked only by its own decoder
# proves that two halves of one implementation share an opinion.
#
# **The corpus statement.** For the four sequences the corpus generator also builds, the
# summary is additionally compared with `tests/conformance/data/keyframe/<name>.json`, which
# was produced by the *Python* encoder from the same populations. The Python writer still
# preserves source `mu_t` on nonzero keyframes instead of applying §11.3's timestamp anchor,
# so that comparison excludes only the resulting opacity aggregate at affected instants.
#
# Usage: typescript/keyframe-delta-roundtrip.sh [output-dir]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

# Windows names the interpreter `python`; a Windows Python installation ships no python3.exe.
if command -v python3 >/dev/null 2>&1; then
  python=python3
else
  python=python
fi

encode="$root/typescript/conformance/dist/encode_keyframe_delta.js"
ts_streamed="$root/typescript/conformance/dist/decode_streamed.js"
ts_indexed="$root/typescript/conformance/dist/decode_indexed.js"
py_streamed="$root/python/conformance/decode_streamed.py"
py_indexed="$root/python/conformance/decode_indexed.py"

[ -f "$encode" ] || {
  echo "::error::$encode is not built; run yarn build"
  exit 1
}

node "$encode" "$out" >"$out/written.txt"

checked=0
while read -r name _bytes; do
  [ -n "$name" ] || continue
  "$python" - "$out/$name.4dgs" "$out/$name.samples.json" "$name" "$root" <<'PY'
import json
import os
import sys

import numpy as np

encoded, source, name, root = sys.argv[1:5]
# Installed is the normal case; the path is for a checkout where it is not.
sys.path.insert(0, os.path.join(root, "python", "fourdgs"))

from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.serialization import MAGIC, iter_records


def fail(detail):
    print(f"::error::{name}: {detail}")
    sys.exit(1)


with open(source, encoding="utf-8") as fh:
    written_from = json.load(fh)

data = open(encoded, "rb").read()
decoded = kdf.decode_streamed(data)
grids = decoded.grids
samples = written_from["samples"]
if len(decoded.chunks) != len(samples):
    fail(f"the encoder wrote {len(decoded.chunks)} chunks for {len(samples)} samples")

# --- the counting rules -----------------------------------------------------
#
# These are checked HERE, and nowhere else, because nothing else looks at them. The
# canonical `liveCount` every SDK is diffed on is read off the *composed state*, and the
# only index/header cross-check either reader makes is `check_index_agrees_with_header`,
# which covers t0, t1, delta_mode, reference_offset, keyframe_offset and depth — not the
# counts. So a writer that swapped a delta entry's `gaussian_count` (operations) for its
# `live_count` (population) would produce a file that every decoder here reads without
# complaint and that reconstructs correctly, while the index lies about the cost of the
# seek and about the population. That swap was injected to check this block catches it.
_, index = kdf.decode_indexed(data)
if len(index) != len(decoded.chunks):
    fail(f"the index names {len(index)} chunks, the file carries {len(decoded.chunks)}")

distinct = {int(i) for s in samples for i in s["ids"]}
if decoded.header.gaussian_count != len(distinct):
    fail(
        f"the Header declares gaussian_count {decoded.header.gaussian_count}; under keyframe-delta "
        f"that is the count of DISTINCT ids over the sequence, which is {len(distinct)} — not a sum "
        f"over chunks, which would be {sum(len(s['ids']) for s in samples)}"
    )

statistics = None
for r in iter_records(data, len(MAGIC)):
    if r.opcode == op.STATISTICS:
        statistics = rec.Statistics.parse(r.content)
if statistics is None:
    fail("the file carries no Statistics record, and this encoder writes one by default")
if statistics.gaussian_count != len(distinct):
    fail(f"Statistics declares gaussian_count {statistics.gaussian_count}, not the {len(distinct)} distinct ids")
if statistics.chunk_count != len(index):
    fail(f"Statistics declares chunk_count {statistics.chunk_count}, the index names {len(index)}")

for i, (entry, chunk) in enumerate(zip(index, decoded.chunks)):
    if entry.kind != chunk.kind:
        fail(f"index entry {i} says kind={entry.kind}, the record it points at is kind={chunk.kind}")
    # `live_count` is the population after composition, and §5.8 defines it for EVERY
    # extended entry — keyframe entries included, not only deltas.
    if entry.live_count != chunk.state.count:
        fail(
            f"index entry {i} declares live_count {entry.live_count}, but the chunk it points at "
            f"composes to {chunk.state.count} gaussians"
        )
    if entry.kind == 0:
        if entry.gaussian_count != chunk.state.count:
            fail(
                f"index entry {i} is a keyframe declaring gaussian_count {entry.gaussian_count}, "
                f"but its chunk carries {chunk.state.count} gaussians"
            )
        if entry.keyframe_offset != entry.chunk_offset:
            fail(f"index entry {i} is a keyframe whose keyframe_offset is not its own offset")
    else:
        operations = chunk.update_count + chunk.birth_count + chunk.death_count
        if entry.gaussian_count != operations:
            fail(
                f"index entry {i} is a delta declaring gaussian_count {entry.gaussian_count}; for a "
                f"delta that field counts OPERATIONS, and its chunk carries "
                f"{chunk.update_count} updates + {chunk.birth_count} births + {chunk.death_count} "
                f"deaths = {operations}"
            )

# The bounds the written file declares about itself, so the tolerance is the encoder's own
# promise rather than a number chosen here to make this pass. Float32 storage costs a
# relative 1e-7 on the way out, orders of magnitude below every bound and not zero.
declared = {k: float(v) for k, v in decoded.quantization.bounds.items()}
if not declared:
    fail("the file declares no bounds, so there is nothing to hold it to")
SLACK = 1e-6
windows = np.asarray(grids.windows, dtype=np.float64)
mu_by_offset = {}

for i, sample in enumerate(samples):
    chunk = decoded.chunks[i]
    if abs(chunk.t0 - float(sample["t0"])) > 1e-12:
        fail(f"chunk {i} starts at {chunk.t0}, the sample it was written from at {sample['t0']}")
    g = sample["gaussians"]
    n = int(g["count"])
    if chunk.state.count != n:
        fail(f"chunk {i} composes to {chunk.state.count} gaussians, the sample carries {n}")

    # Both sides in ascending gaussian_id, which is the one order the format defines
    # (spec §11.2). Identity is what pairs a written gaussian with a source one here — no
    # nearest-neighbour matching is needed or wanted, because a keyframe-delta file names
    # every gaussian outright and an encoder that mixed two up would be a different bug.
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

    def got(key, channels=1):
        v = np.asarray(values[key], dtype=np.float64)
        return v[got_order] if channels == 1 else v[got_order, :channels]

    def src(key, channels=1):
        v = np.asarray(g[key], dtype=np.float32).reshape(n, channels).astype(np.float64)
        return v[src_order] if channels > 1 else v[src_order, 0]

    worst = {
        "pos": np.abs(got("positions", 3) - src("positions", 3)).max(),
        "scale_rel": np.abs(np.log(got("scales", 3) / src("scales", 3))).max(),
        "rgb": np.abs(got("colors", 4)[:, :3] - src("colors", 4)[:, :3]).max(),
        "alpha": np.abs(got("colors", 4)[:, 3] - src("colors", 4)[:, 3]).max(),
        "sigma_rel": np.abs(np.log(got("sigma_t") / src("sigmaT"))).max(),
    }
    # `log(1 + bound)` is the promise in the log domain the two relative lanes are quantized
    # in; the rest are absolute.
    limits = {
        "pos": declared["pos"] + SLACK,
        "scale_rel": np.log1p(declared["scale_rel"]) + SLACK,
        "rgb": declared["rgb"] + SLACK,
        "alpha": declared["alpha"] + SLACK,
        "sigma_rel": np.log1p(declared["sigma_rel"]) + SLACK,
    }
    for key, limit in limits.items():
        if not (worst[key] <= limit):
            fail(f"chunk {i}: {key} deviates by {worst[key]:g}, past the {limit:g} this file declares")

    # Velocity and birth time are the two lanes whose grid is per gaussian, not per file: a
    # short-lived gaussian is on screen briefly, so it tolerates a coarser velocity, and
    # `step_motion` in the record is the pitch for the reference lifetime rather than for any
    # particular gaussian (spec §6.3). So the pitch is derived here the way a decoder derives
    # it — from this file's own sigma bins, window lengths and cutoff — and each gaussian is
    # held to half of its own.
    bins = chunk.state.bins
    sigma_bins = bins[op.A_SIGMA_T][:, 0]
    never_fades = bins[op.A_FLAGS][:, 0] != 0
    m_step = grids.motion_step(sigma_bins, never_fades, bins[op.A_WINDOW_INDEX][:, 0])[got_order]
    t_step = grids.mu_step(sigma_bins, never_fades)[got_order]
    motion_excess = np.abs(got("motions", 3) - src("motions", 3)).max(axis=1) - (m_step / 2.0 + SLACK)
    if motion_excess.max() > 0:
        fail(f"chunk {i}: a velocity is {motion_excess.max():g} past half the per-gaussian pitch this file's own grid gives it")
    # §11.3 anchors every gaussian stated by this chunk to its timestamp; an untouched row
    # retains the anchor of the chunk it references. Source muT is deliberately not a
    # target: accepting it is the Python-writer divergence isolated below.
    got_mu = got("mu_t")
    reference_mu = {} if chunk.kind == 0 else mu_by_offset[chunk.reference_offset]
    expected_mu = []
    for row, gaussian_id in enumerate(got_ids):
        at_t0 = float(sample["t0"])
        if chunk.kind == 0 or int(gaussian_id) not in reference_mu:
            expected_mu.append(at_t0)
        elif abs(got_mu[row] - at_t0) <= t_step[row] / 2.0 + SLACK:
            expected_mu.append(at_t0)
        else:
            expected_mu.append(reference_mu[int(gaussian_id)])
    expected_mu = np.asarray(expected_mu, dtype=np.float64)
    mu_excess = np.abs(got_mu - expected_mu) - (t_step / 2.0 + SLACK)
    if mu_excess.max() > 0:
        fail(f"chunk {i}: a birth time is {mu_excess.max():g} past half the per-gaussian pitch this file's own grid gives it")
    mu_by_offset[chunk.offset] = {
        int(gaussian_id): float(mu)
        for gaussian_id, mu in zip(chunk.state.ids, np.asarray(values["mu_t"]))
    }

    # Rotation is smallest-three: three residuals on the declared pitch, and the omitted
    # component recovered as a square root, which spreads their error over the fourth. The
    # largest component is at least 1/2 by construction, so the amplification is bounded and
    # eight times the residual bound is a limit a real corruption cannot hide under.
    q_got = got("rotations", 4)
    q_src = src("rotations", 4)
    q_src = q_src / np.maximum(np.linalg.norm(q_src, axis=1, keepdims=True), 1e-30)
    # `q` and `-q` are the same rotation, and the coding canonicalizes the sign.
    rot_worst = np.minimum(np.abs(q_got - q_src).max(axis=1), np.abs(q_got + q_src).max(axis=1)).max()
    if not (rot_worst <= 8.0 * declared["rot"] + SLACK):
        fail(f"chunk {i}: a rotation moved {rot_worst:g}, past the {8.0 * declared['rot']:g} smallest-three coding on this file's pitch allows")

    # The validity window is stored verbatim in the Window Table, so it is not a tolerance at
    # all: the row `window_index` names must be the window the gaussian went in with.
    rows = np.asarray(values["window_index"], dtype=np.int64)[got_order]
    if not np.allclose(windows[rows, 0], src("winLo"), rtol=0, atol=0) or not np.allclose(
        windows[rows, 1], src("winHi"), rtol=0, atol=0
    ):
        fail(f"chunk {i}: a validity window came back changed, and the Window Table stores them verbatim")
PY

  node "$ts_streamed" "$out/$name.4dgs" >"$out/$name.ts.streamed.json"
  node "$ts_indexed" "$out/$name.4dgs" >"$out/$name.ts.indexed.json"
  "$python" "$py_streamed" "$out/$name.4dgs" >"$out/$name.python.streamed.json"
  "$python" "$py_indexed" "$out/$name.4dgs" >"$out/$name.python.indexed.json"
  "$python" - "$out/$name" "$name" "$root" <<'PY'
import json
import os
import sys

prefix, name, root = sys.argv[1], sys.argv[2], sys.argv[3]
summaries = {}
for reader in ("ts.streamed", "ts.indexed", "python.streamed", "python.indexed"):
    with open(f"{prefix}.{reader}.json", encoding="utf-8") as fh:
        summaries[reader] = json.load(fh)

with open(f"{prefix}.samples.json", encoding="utf-8") as fh:
    written_from = json.load(fh)

# Always: each language's two read paths. The streamed path never looks at the index, so a
# wrong summary offset or a wrong chunk range decodes there and only the indexed path
# notices — this is the claim about the index and the offsets the encoder wrote.
readers = ["ts.indexed"]
reference_name = "ts.streamed"
if written_from["crossLanguage"]:
    # And, where the two decoders agree about §3 (see `crossLanguage` in
    # keyframeDeltaSequences.ts, and issue #185), the cross-language claim: Python's two read
    # paths on the same file, plus the corpus statement — the same populations put through
    # the PYTHON encoder. Two writers, one meaning, which is the whole claim of this ticket.
    readers += ["python.streamed", "python.indexed"]
    if written_from["inCorpus"]:
        expectation = os.path.join(root, "tests", "conformance", "data", "keyframe", f"{name}.json")
        with open(expectation, encoding="utf-8") as fh:
            summaries["corpus.python-encoder"] = json.load(fh)
        readers.append("corpus.python-encoder")
else:
    summaries["python.indexed-vs-streamed"] = summaries["python.indexed"]
    if summaries["python.indexed"] != summaries["python.streamed"]:
        print(f"::error::{name}: Python's two read paths disagree on a file the TypeScript encoder wrote")
        sys.exit(1)
    # The chunk rows are everything the writer decides — kind, delta mode, depth, live count,
    # the three operation counts — so they are compared across languages even here.
    if summaries["python.streamed"]["chunks"] != summaries["ts.streamed"]["chunks"]:
        print(f"::error::{name}: Python and TypeScript disagree about the chunk rows")
        sys.exit(1)

reference = summaries[reference_name]


def without_python_mu_anchor_opacity(summary):
    """Remove only the known §11.3 writer divergence from a comparison copy."""
    copy = json.loads(json.dumps(summary))
    first_nonzero = next((float(c["t0"]) for c in copy["chunks"] if float(c["t0"]) > 0), None)
    if first_nonzero is not None:
        for state in copy["states"]:
            if float(state["t"]) >= first_nonzero:
                state["aggregate"].pop("opacitySum", None)
    return copy


def comparison(reader):
    candidate = summaries[reader]
    baseline = reference
    if reader == "corpus.python-encoder":
        candidate = without_python_mu_anchor_opacity(candidate)
        baseline = without_python_mu_anchor_opacity(baseline)
    return baseline, candidate


disagreed = [r for r in readers if comparison(r)[1] != comparison(r)[0]]
if disagreed:
    print(f"::error::{name}: {disagreed} disagree with {reference_name} on a file the TypeScript encoder wrote")
    for reader in disagreed:
        baseline, candidate = comparison(reader)
        for key in sorted(set(baseline) | set(candidate)):
            if baseline.get(key) != candidate.get(key):
                print(f"  {key}\n    {reference_name}: {json.dumps(baseline.get(key))[:300]}")
                print(f"    {reader}: {json.dumps(candidate.get(key))[:300]}")
    sys.exit(1)
PY
  checked=$((checked + 1))
  echo "  $name"
done <"$out/written.txt"

echo "$checked sequences written by TypeScript; every one inside the bounds it declares against its source, and both decoders agree on it, both read paths"
