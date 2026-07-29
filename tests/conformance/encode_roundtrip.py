#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The cross-language encode gate: prove an encoder against a shared reference.

    python3 tests/conformance/encode_roundtrip.py --encoder cpp
    python3 tests/conformance/encode_roundtrip.py --encoder swift
    python3 tests/conformance/encode_roundtrip.py --encoder typescript
    python3 tests/conformance/encode_roundtrip.py --encoder rust    # self-check

The corpus proves decoders against files the reference *encoder* wrote. This proves an
encoder, and it does it without a second corpus. Every encode family ships one small CLI —
`<encoder> <in.4dgs> <out.4dgs> [sh-bit-depths]` — that decodes a variant, re-encodes the
gaussians it yielded with a fixed option preset, and writes the result. The preset drops
every non-gaussian record, because these authoring surfaces write gaussians and cannot
reproduce audio, cameras, attachments or provenance a variant happens to carry.

The gate: encode the same variant with `encode_gaussians` (the Rust reference) and with the
candidate, decode BOTH with the Python reference decoder, and require identical canonical
JSON. Because the preset is fixed and the encoder is deterministic in its input and options,
two correct encoders produce files that decode to the same summary — chunk intervals, summary
offsets and all. For C++ and Swift, which reach the Rust encoder through the C ABI, this
proves the binding wired the gaussians and options through correctly, not that a second
encoder agrees. For TypeScript, a genuine second encoder, it proves agreement.

A second pass repeats this for the spherical-harmonic variants at per-band bit depths, where
the coefficients one encoder coarsened must come back out of the decoder as the same bytes
and the declared depths must read as the ones that were written.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

sys.path.insert(0, os.path.join(ROOT, "python", "fourdgs"))
sys.path.insert(0, HERE)

import fourdgs  # noqa: E402
from canonical import canonical, summarize  # noqa: E402

EXE = ".exe" if os.name == "nt" else ""

RUST_BIN = os.path.join(ROOT, "target", "release")
CPP_BUILD = os.path.join(ROOT, "cpp", "build", "conformance")
SWIFT_BIN = os.path.join(ROOT, "swift", ".build", "release")
TYPESCRIPT_DIST = os.path.join(ROOT, "typescript", "conformance", "dist")

#: The shared baseline every candidate is diffed against.
REFERENCE = [os.path.join(RUST_BIN, "encode_gaussians" + EXE)]

#: family -> the CLI that re-encodes one variant. A new encoder adds one line, the same way
#: the decode harness adds a runner.
ENCODERS = {
    "rust": [os.path.join(RUST_BIN, "encode_gaussians" + EXE)],
    "cpp": [os.path.join(CPP_BUILD, "encode_roundtrip" + EXE)],
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
SECOND_ENCODERS = frozenset({"typescript"})
LAYOUT_DEPENDENT_KEYS = ("summaryOffsets", "library")


def variants() -> list[str]:
    return sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))


def decode_canonical(path: str) -> str:
    scene = fourdgs.read(path)
    return canonical(
        summarize(
            scene.header,
            scene.gaussians,
            scene.audio,
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


def compare(
    reference: list[str], candidate: list[str], source: str, tmp: str, ladder: str | None, second_encoder: bool
) -> None:
    ref_out = os.path.join(tmp, "reference.4dgs")
    cand_out = os.path.join(tmp, "candidate.4dgs")
    encode(reference, source, ref_out, ladder)
    encode(candidate, source, cand_out, ladder)
    ref = json.loads(decode_canonical(ref_out))
    cand = json.loads(decode_canonical(cand_out))
    if second_encoder:
        for key in LAYOUT_DEPENDENT_KEYS:
            ref.pop(key, None)
            cand.pop(key, None)
    if ref != cand:
        raise AssertionError(_diff(json.dumps(ref), json.dumps(cand)))
    if ladder is not None:
        _check_declared_depths(cand_out)


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


def _diff(reference: str, candidate: str) -> str:
    a = json.loads(reference)
    b = json.loads(candidate)
    lines = ["the reference and the candidate decode differently:"]
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            lines.append(f"  {key}")
            lines.append(f"    reference: {json.dumps(a.get(key))[:300]}")
            lines.append(f"    candidate: {json.dumps(b.get(key))[:300]}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="the cross-language 4dgs encode gate")
    parser.add_argument("--encoder", required=True, choices=sorted(ENCODERS), help="which encoder to prove")
    args = parser.parse_args(argv)

    if not os.path.exists(REFERENCE[-1]):
        print(f"error: the reference {REFERENCE[-1]} is not built; run cargo build --release --workspace", file=sys.stderr)
        return 1
    command = ENCODERS[args.encoder]
    if not os.path.exists(command[-1]):
        print(f"skipping {args.encoder}: {command[-1]} is not built")
        return 0

    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1

    second_encoder = args.encoder in SECOND_ENCODERS
    agreed = graded = failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for variant in names:
            source = os.path.join(DATA, f"{variant}.4dgs")
            try:
                compare(REFERENCE, command, source, tmp, None, second_encoder)
                agreed += 1
            except (AssertionError, RuntimeError) as exc:
                failed += 1
                print(f"FAIL {args.encoder} {variant}\n  {exc}")
                continue
            if "SHDegree" in variant:
                try:
                    compare(REFERENCE, command, source, tmp, SH_LADDER, second_encoder)
                    graded += 1
                except (AssertionError, RuntimeError) as exc:
                    failed += 1
                    print(f"FAIL {args.encoder} {variant} @ {SH_LADDER}\n  {exc}")

    print(f"\n{agreed} variants re-encoded, {graded} at per-band SH depths, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
