#!/usr/bin/env bash
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0
#
# Prove the Dart encoder against another implementation.
#
# For every corpus variant: decode it, re-encode the gaussians with the Dart encoder, then
# decode the result with BOTH the Dart decoder and the Python reference decoder — on both
# read paths — and require all four canonical summaries to be identical.
#
# That last requirement is the whole point. An encoder checked only by its own decoder
# proves that two halves of one implementation share an opinion, which is exactly the
# failure mode a conformance suite exists to catch. Agreement with a decoder that was
# written in another language, against the same specification, is a real claim.
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

for binary in "$encode" "$decode_dart_streamed" "$decode_dart_indexed"; do
  [ -x "$binary" ] || {
    echo "::error::$binary is not built; run dart compile exe in dart/conformance"
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
  "$decode_dart_streamed" "$out/$name.4dgs" >"$out/$name.dart.streamed.json"
  "$decode_dart_indexed" "$out/$name.4dgs" >"$out/$name.dart.indexed.json"
  "$python" "$decode_python_streamed" "$out/$name.4dgs" >"$out/$name.python.streamed.json"
  "$python" "$decode_python_indexed" "$out/$name.4dgs" >"$out/$name.python.indexed.json"
  "$python" - "$out/$name" "$name" <<'PY'
import json
import sys

prefix, name = sys.argv[1], sys.argv[2]
readers = ("dart.streamed", "dart.indexed", "python.streamed", "python.indexed")
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

echo "$agreed variants re-encoded by Dart; both decoders agree on every one, both read paths"
