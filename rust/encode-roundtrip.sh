#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the Rust encoder against another implementation.
#
# For every corpus variant: decode it, re-encode the gaussians with the Rust encoder, then
# decode the result with BOTH the Rust decoder and the Python reference decoder and require
# their canonical JSON to be identical.
#
# That last requirement is the whole point. An encoder checked only by its own decoder
# proves that two halves of one implementation share an opinion, which is exactly the
# failure mode a conformance suite exists to catch. Agreement with a decoder that was
# written in another language, against the same specification, is a real claim.
#
# The encoder's own bound verification runs inside every one of these encodes, so reaching
# the end also means the Quantization record's declared maxima were checked on every
# gaussian of every scene, not sampled.
#
# Usage: rust/encode-roundtrip.sh [output-dir]

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

encode="$root/target/release/encode_roundtrip$exe"
decode_rust="$root/target/release/decode_streamed$exe"
decode_python="$root/python/conformance/decode_streamed.py"

for binary in "$encode" "$decode_rust"; do
  [ -x "$binary" ] || {
    echo "::error::$binary is not built; run cargo build --release --workspace"
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
  "$decode_rust" "$out/$name.4dgs" >"$out/$name.rust.json"
  "$python" "$decode_python" "$out/$name.4dgs" >"$out/$name.python.json"
  "$python" - "$out/$name.rust.json" "$out/$name.python.json" "$name" <<'PY'
import json
import sys

rust, python, name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rust, encoding="utf-8") as fh:
    a = json.load(fh)
with open(python, encoding="utf-8") as fh:
    b = json.load(fh)
if a != b:
    print(f"::error::{name}: the two decoders disagree on a file the Rust encoder wrote")
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            print(f"  {key}\n    rust:   {json.dumps(a.get(key))[:300]}\n    python: {json.dumps(b.get(key))[:300]}")
    sys.exit(1)
PY
  agreed=$((agreed + 1))
  echo "  $name: $(cat "$out/$name.note")"
done

echo "$agreed variants re-encoded; both decoders agree on every one"
