#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the Swift `keyframe-delta` encoder.
#
# `tests/conformance/encode_roundtrip.py` is the gate for the gaussian-birth writer, and it
# has a known blind spot (#189): it proves two encoders agree, not that either preserved the
# scene, so a fault present in both passes it. This model has no second encoder here at all,
# so the claims are made against an implementation that shares no code with the one under
# test — the Python reference.
#
# **Agreement.** Every file Swift writes is decoded by Swift on both read paths and by the
# Python reference, and all three canonical summaries must be identical. The read paths fail
# differently: the streamed one never looks at the index, so a wrong chunk offset or a wrong
# reference decodes cleanly there and only the indexed walk notices. An encoder checked by
# one path is half-checked, and one checked only by its own decoder proves that two halves of
# one implementation share an opinion.
#
# **Index counts.** Every count the chunk index declares, against the records it points at —
# `check_index_counts` from `tests/conformance/encode_roundtrip.py`, the same check the
# gaussian-birth gate makes. It is the one claim here that no reconstruction can make: Swift's
# indexed reader composes the chunks the index names without consulting either count, so an
# entry that swapped its operation count for its live population reads back identically on
# every path below while the file misstates what a seek costs.
#
# **The corpus statement.** Four of the sequences are the ones `tests/conformance/generate.py`
# builds — the encoder says which, and a variant that claims the corpus and has no expectation
# is a failure, not a quiet downgrade to agreement — so the reconstruction is additionally
# compared with the committed `tests/conformance/data/keyframe/<name>.json`, produced by the
# *Python* encoder from the same populations. Compared: which gaussians are live at each
# probe, and where they are.
# Excluded: the aggregate opacity and the per-chunk operation counts. Those are not slack in
# the claim, they are a real and legal difference — a keyframe restates every live gaussian's
# `mu_t` at its own `t0` (spec §11.3), the corpus generator anchors `mu_t` itself before
# writing, and a birth time that moves moves the temporal marginal. Geometry and population
# are what two encoders of the same sequence must agree on.
#
# Swift is a binding over the Rust core's writer, so what this grades is that the samples,
# the ids and the options crossed the C ABI correctly — not that a second encoder agrees.
#
# Usage: swift/keyframe-delta-roundtrip.sh [output-dir]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"

if command -v python3 >/dev/null 2>&1; then
  python=python3
else
  python=python
fi

encode="$root/swift/.build/release/encode_keyframe_delta"
swift_streamed="$root/swift/.build/release/decode_streamed"
swift_indexed="$root/swift/.build/release/decode_indexed"
py_decode="$root/python/conformance/decode_keyframe_delta.py"
corpus="$root/tests/conformance/data/keyframe"

for tool in "$encode" "$swift_streamed" "$swift_indexed"; do
  [ -x "$tool" ] || {
    echo "::error::$tool is not built; run swift build -c release --scratch-path swift/.build"
    exit 1
  }
done

"$encode" "$out" >"$out/written.txt"

checked=0
compared=0
while IFS=$'\t' read -r name in_corpus note; do
  [ -n "$name" ] || continue
  file="$out/$name.4dgs"

  # The counts the chunk index declares, against the records it points at (#195). First,
  # before anything decodes the file, because this is the claim about the file itself.
  #
  # Nothing compared further down can see these numbers. Every summary below takes the
  # population off the *composed* state, so a writer that swapped a delta entry's
  # `gaussian_count` (its operations) for its `live_count` (the population after
  # composition) writes a file that reconstructs identically on all three paths and still
  # misstates what a seek costs — and Swift's own indexed reader composes the chain the
  # index names without consulting either number, so it reads that file without complaint.
  #
  # What does catch it today is the Python reference's `decode_indexed`, which refuses an
  # index that disagrees with the record it points at. That is a claim the reference happens
  # to make on its way past rather than one this gate states: it arrives as a traceback out
  # of a decode step, it names no variant, and it would leave with any future reader swapped
  # in here. Stated here it is the gate's own claim, it names the entry, and it also reaches
  # what no decoder checks — that the index is one-to-one with the physical chunks and the
  # SH bands. Shared with `encode_roundtrip.py` rather than restated, because a rule written
  # out twice is a rule that can come to differ between its two copies.
  "$python" - "$file" "$name" "$root" <<'PY'
import os
import sys

path, name, root = sys.argv[1:4]
sys.path.insert(0, os.path.join(root, "tests", "conformance"))
from encode_roundtrip import check_index_counts  # noqa: E402

try:
    check_index_counts(path)
except AssertionError as error:
    print(f"::error::{name}: {error}")
    sys.exit(1)
PY

  "$swift_streamed" "$file" >"$out/$name.swift-streamed.json"
  "$swift_indexed" "$file" >"$out/$name.swift-indexed.json"
  "$python" "$py_decode" "$file" >"$out/$name.python.json"

  # The verdict is captured rather than streamed so that a failure's diagnosis — which the
  # script below writes to stdout, next to the verdict — is printed with the file it is
  # about, instead of ahead of the line naming it.
  if ! verdict="$("$python" - "$out" "$name" "$corpus" "$in_corpus" <<'PY'
import json
import os
import sys

out, name, corpus, in_corpus = sys.argv[1:5]


def load(suffix):
    with open(os.path.join(out, f"{name}.{suffix}.json"), encoding="utf-8") as fh:
        return json.load(fh)


readers = {
    "swift streamed": load("swift-streamed"),
    "swift indexed": load("swift-indexed"),
    "python": load("python"),
}

# Agreement: three decodes of one file, byte for byte on the canonical summary.
reference_name, reference = next(iter(readers.items()))
for other_name, other in list(readers.items())[1:]:
    if other == reference:
        continue
    print(f"::error::{name}: {reference_name} and {other_name} disagree on a file Swift wrote")
    for key in sorted(set(reference) | set(other)):
        if reference.get(key) != other.get(key):
            print(f"  {key}")
            print(f"    {reference_name}: {json.dumps(reference.get(key))[:300]}")
            print(f"    {other_name}: {json.dumps(other.get(key))[:300]}")
    sys.exit(1)

# The corpus statement, for the sequences the generator also builds. Which those are is what
# the encoder declared on this line, not what happens to be on disk: deciding it by testing
# for the expectation file makes a renamed variant — here or in the generator's cross-product
# — turn this comparison off and still report a pass, which is the one outcome a gate must
# never have.
committed = os.path.join(corpus, f"{name}.json")
if in_corpus != "corpus":
    if os.path.exists(committed):
        print(f"::error::{name}: written as a Swift-only variant, but the corpus has {committed}")
        sys.exit(1)
    print("agreement")
    sys.exit(0)
if not os.path.exists(committed):
    print(f"::error::{name}: declared a corpus variant, and there is no expectation at {committed}")
    sys.exit(1)
with open(committed, encoding="utf-8") as fh:
    expected = json.load(fh)

if reference["durationSec"] != expected["durationSec"]:
    print(f"::error::{name}: duration {reference['durationSec']} != {expected['durationSec']}")
    sys.exit(1)
if reference["gaussianCount"] != expected["gaussianCount"]:
    # Distinct ids across the sequence, not a sum over chunks (spec section 5.1 under 11).
    print(f"::error::{name}: gaussian_count {reference['gaussianCount']} != {expected['gaussianCount']}")
    sys.exit(1)

mine, theirs = reference["states"], expected["states"]
if len(mine) != len(theirs):
    print(f"::error::{name}: {len(mine)} probes against the corpus's {len(theirs)}")
    sys.exit(1)
for a, b in zip(mine, theirs):
    where = f"{name} at t={b['t']}"
    if abs(a["t"] - b["t"]) > 1e-9:
        print(f"::error::{where}: probe instant {a['t']}")
        sys.exit(1)
    if a["liveCount"] != b["liveCount"]:
        print(f"::error::{where}: live count {a['liveCount']} != {b['liveCount']}")
        sys.exit(1)
    if a["sample"]["gaussianIds"] != b["sample"]["gaussianIds"]:
        print(f"::error::{where}: ids {a['sample']['gaussianIds']} != {b['sample']['gaussianIds']}")
        sys.exit(1)
    for row, (p, q) in enumerate(zip(a["sample"]["positions"], b["sample"]["positions"])):
        for axis in range(3):
            # Well inside the default profile's declared position bound at this scale; the
            # two encoders quantize on grids derived the same way from the same population,
            # so this is a real agreement and not a tolerance doing the work.
            if abs(p[axis] - q[axis]) > 1e-3:
                print(f"::error::{where}: row {row} axis {axis}: {p[axis]} != {q[axis]}")
                sys.exit(1)
print("agreement + corpus")
PY
)"; then
    echo "$verdict"
    exit 1
  fi
  checked=$((checked + 1))
  case "$verdict" in *corpus*) compared=$((compared + 1)) ;; esac
  echo "  $name: $note — $verdict"
done <"$out/written.txt"

[ "$checked" -gt 0 ] || {
  echo "::error::no keyframe-delta files were written"
  exit 1
}

# The same assertion as the one above, about the other claim. `checked` counts files that
# agreed; `compared` counts the ones additionally held to a second encoder's committed
# reconstruction, and that is the claim worth the most here — so it is the one whose count
# has to be greater than zero rather than the one nobody would notice reaching it.
[ "$compared" -gt 0 ] || {
  echo "::error::no file was compared against the committed corpus; every variant declared itself Swift-only"
  exit 1
}

echo "$checked keyframe-delta files written by Swift; Swift and the Python reference agree on every one, both read paths"
echo "$compared of them match the committed corpus population and geometry"
