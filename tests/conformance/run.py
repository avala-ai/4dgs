#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Run every implementation's runners over the corpus and diff against expectations.

    python3 tests/conformance/run.py                 # every registered runner
    python3 tests/conformance/run.py --runner python
    python3 tests/conformance/run.py --update        # rewrite expectations

    # a runner that does not live in this repository, scored identically
    python3 tests/conformance/run.py --runner-cmd 'go run ./cmd/decode_streamed'

A runner that declines a variant is SKIPPED, not failed. Partial implementations are a
supported state, and the feature matrix is where that shows up publicly.
"""

from __future__ import annotations

import argparse
import dataclasses
import difflib
import json
import os
import shlex
import subprocess
import sys
from collections.abc import Iterator
from typing import NamedTuple

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

#: Where a language's built runners live, when it has a build step. A family whose
#: entry point is missing is skipped with a note rather than reported as 67 failures:
#: a Python-only contributor running the whole suite has not broken anything.
TYPESCRIPT_DIST = os.path.join(ROOT, "typescript", "conformance", "dist")
CPP_BUILD = os.path.join(ROOT, "cpp", "build", "conformance")
#: Cargo puts workspace binaries in one place regardless of which crate declares them.
RUST_BIN = os.path.join(ROOT, "target", "release")
SWIFT_BIN = os.path.join(ROOT, "swift", ".build", "release")
#: Dart's runners could be `dart run <script>`, and are compiled instead. A script
#: always exists, so the "is it built?" test below would always pass and a machine
#: without a Dart SDK would report 67 failures rather than a skip.
DART_BIN = os.path.join(ROOT, "dart", "conformance", "build")

#: Windows puts a suffix on an executable. The harness finds a runner by testing its path
#: for existence, so without this every compiled family looks "not built" on Windows — and
#: because a family that never ran is a failure rather than a pass, `--runner rust` then
#: goes red for a reason that has nothing to do with the runner.
EXE = ".exe" if os.name == "nt" else ""

#: (family, name, argv-prefix). A new language adds one line.
RUNNERS = [
    (
        "python",
        "python/decode_streamed",
        [sys.executable, os.path.join(ROOT, "python", "conformance", "decode_streamed.py")],
    ),
    (
        "python",
        "python/decode_indexed",
        [sys.executable, os.path.join(ROOT, "python", "conformance", "decode_indexed.py")],
    ),
    ("typescript", "typescript/decode_streamed", ["node", os.path.join(TYPESCRIPT_DIST, "decode_streamed.js")]),
    ("typescript", "typescript/decode_indexed", ["node", os.path.join(TYPESCRIPT_DIST, "decode_indexed.js")]),
    ("cpp", "cpp/decode_streamed", [os.path.join(CPP_BUILD, "decode_streamed" + EXE)]),
    ("cpp", "cpp/decode_indexed", [os.path.join(CPP_BUILD, "decode_indexed" + EXE)]),
    ("rust", "rust/decode_streamed", [os.path.join(RUST_BIN, "decode_streamed" + EXE)]),
    ("rust", "rust/decode_indexed", [os.path.join(RUST_BIN, "decode_indexed" + EXE)]),
    ("swift", "swift/decode_streamed", [os.path.join(SWIFT_BIN, "decode_streamed" + EXE)]),
    ("swift", "swift/decode_indexed", [os.path.join(SWIFT_BIN, "decode_indexed" + EXE)]),
    ("dart", "dart/decode_streamed", [os.path.join(DART_BIN, "decode_streamed" + EXE)]),
    ("dart", "dart/decode_indexed", [os.path.join(DART_BIN, "decode_indexed" + EXE)]),
]


INVALID = os.path.join(DATA, "invalid")
#: keyframe-delta variants live in their own subdirectory, like the invalid corpus, so the
#: top-level-only globs of the fuzzer, the Kaitai grammar and the C++ named-list test never
#: see a temporal model they do not decode. This harness is the one consumer that dispatches
#: on the model, so it reaches into the subdirectory explicitly.
KEYFRAME = os.path.join(DATA, "keyframe")
KEYFRAME_PREFIX = "keyframe/"

#: Object-layer variants live in their own subdirectory too, gathered where this harness
#: reaches for them. An object record does not break a top-level consumer the way a
#: keyframe-delta record does — one WithObjects variant sits at the top level and the
#: fuzzer and Kaitai grammar read it — but the object decode/compose family belongs
#: together, and only this harness dispatches on the subdirectory.
OBJECT = os.path.join(DATA, "object")
OBJECT_PREFIX = "object/"

#: Invalid variants are named with this prefix, which is also their subdirectory. A
#: runner is handed the same thing either way — a path — and the harness compares the
#: same thing either way: parsed JSON against a committed expectation. What differs is
#: only what a correct answer looks like.
INVALID_PREFIX = "invalid/"


def variants() -> list[str]:
    valid = sorted(f[: -len(".json")] for f in os.listdir(DATA) if f.endswith(".json"))
    keyframe = []
    if os.path.isdir(KEYFRAME):
        keyframe = sorted(KEYFRAME_PREFIX + f[: -len(".json")] for f in os.listdir(KEYFRAME) if f.endswith(".json"))
    obj = []
    if os.path.isdir(OBJECT):
        obj = sorted(OBJECT_PREFIX + f[: -len(".json")] for f in os.listdir(OBJECT) if f.endswith(".json"))
    refusals = []
    if os.path.isdir(INVALID):
        refusals = sorted(INVALID_PREFIX + f[: -len(".json")] for f in os.listdir(INVALID) if f.endswith(".json"))
    return valid + keyframe + obj + refusals


#: Families whose runners answer a refusal expectation — printing `{"refused": "<id>"}`
#: for a file they refuse, rather than exiting non-zero. A family absent here SKIPS the
#: invalid corpus, exactly as it would skip any variant it declines, and the feature
#: matrix is where that shows up publicly. Adding a language is one entry here plus the
#: few lines in its runner that catch the refusal and print its identifier.
REFUSAL_FAMILIES = frozenset({"python", "rust"})


#: Record families a language has not implemented, by the variant-name flags that carry
#: them. A partial implementation is a supported state — the feature matrix is where it
#: shows up publicly — and declining a variant is how a runner says so.
#:
#: Every family now reports provenance (spec §5.15) and decodes keyframe-delta. Python, Rust,
#: TypeScript and Dart do both natively; C++ and Swift decode both through the Rust C ABI's
#: additive accessors (states-JSON for keyframe-delta, provenance-JSON for the four
#: provenance records). Declining is not the same as failing to read: an SDK that steps a
#: record over by length finishes the file correctly but omits a key the expectation carries,
#: and a diff cannot tell that apart from a decoder that got it wrong.

FAMILY_DECLINES: dict[str, tuple[str, ...]] = {
    # Every family now reports provenance (spec §5.15) and decodes the object layer.
    # TypeScript and Dart compose its tracks natively; C++ and Swift do it through the
    # Rust C ABI's additive objects/states accessors, so no binding restates the
    # base-then-track order or the slerp underneath it.
}


#: The out-of-tree runner protocol this harness speaks. A runner declares the version it
#: was written against, and a mismatch is an error naming both numbers rather than a
#: silent reinterpretation of a document whose meaning has changed since.
PROTOCOL_VERSION = 1

#: How the harness asks an out-of-tree runner what it supports: spawn it with this one
#: argument and no path, and read one JSON object from stdout.
#:
#: Three mechanisms were possible — probe once, probe per variant (`--supports <variant>`),
#: or a manifest file the runner ships. The one-shot probe wins on all three counts that
#: matter. It reuses the protocol a runner has already implemented (arguments in, one JSON
#: document on stdout), so it adds no second interface to get wrong. It costs one process
#: rather than 119 per runner, which matters when the command is `go run ./cmd/runner`.
#: And the declaration travels inside the program, so it cannot drift from it the way a
#: checked-in manifest — or this harness's own tables — can and did.
CAPABILITIES_ARG = "--capabilities"

#: Seconds one invocation may take. A hanging runner is the failure mode an unfamiliar
#: implementation produces most readily, and without a bound it hangs the whole suite
#: silently; with one it costs a single red variant that names the timeout. Generous
#: because a cold `go run` or JIT start is not a hang.
DEFAULT_TIMEOUT = 120.0


@dataclasses.dataclass(frozen=True)
class Capabilities:
    """What one runner answers for — declared by the harness, or by the runner itself.

    Both paths produce this same record and `supports()` reads nothing else, which is what
    makes an out-of-tree runner scored identically rather than specially.
    """

    #: The language family. Groups the two read paths; `--runner` selects on it.
    family: str
    #: `<family>/<read path>`, as it appears in every line the harness prints.
    name: str
    #: Whether this runner reads through the index, and so cannot answer a variant written
    #: without one.
    indexed: bool
    #: Whether this runner answers the invalid corpus with a refusal identifier. A runner
    #: that does not skips all seven, and the feature matrix is where that shows up.
    refusals: bool
    #: Name fragments this runner has not implemented; a variant containing one is skipped.
    declines: tuple[str, ...] = ()


def builtin_capabilities(family: str, runner_name: str) -> Capabilities:
    """What the harness declares on behalf of a runner in `RUNNERS`.

    The six families in this repository are described by the tables above rather than by a
    handshake, so that adding a language stays one line in `RUNNERS` and the tables remain
    the single place CI and the feature matrix read.
    """
    return Capabilities(
        family=family,
        name=runner_name,
        indexed=runner_name.endswith("decode_indexed"),
        refusals=family in REFUSAL_FAMILIES,
        declines=tuple(FAMILY_DECLINES.get(family, ())),
    )


def supports(caps: Capabilities, variant: str) -> bool:
    if any(flag in variant for flag in caps.declines):
        return False
    if variant.startswith(INVALID_PREFIX) and not caps.refusals:
        return False
    if not caps.indexed:
        return True
    # The invalid corpus is cut from a variant that carries an index, so both read paths
    # can be asked to refuse it. That matters: the two paths reach the Header by
    # different routes — one front to back, one through the Footer — and a check placed
    # on only one of them refuses half the files it should.
    if variant.startswith(INVALID_PREFIX):
        return True
    return "UseChunkIndex" in variant


class ProtocolError(Exception):
    """An out-of-tree runner did not answer the capabilities probe as the protocol asks."""


class Outcome(NamedTuple):
    """One invocation's result, with the two ways it can fail to be one at all."""

    returncode: int
    stdout: str
    stderr: str
    #: Set when the harness never got an exit status: the command could not be started, or
    #: it ran past the timeout. Both are the runner's failure, not the harness's, so they
    #: are reported like any other rather than raised.
    error: str | None = None


def invoke(command: list[str], args: list[str], timeout: float) -> Outcome:
    try:
        result = subprocess.run([*command, *args], capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return Outcome(-1, "", "", f"did not answer within {timeout:g}s")
    except OSError as exc:
        return Outcome(-1, "", "", f"could not be started: {exc}")
    return Outcome(result.returncode, result.stdout, result.stderr)


def _declared_str(doc: dict, key: str, default: str | None = None) -> str:
    value = doc.get(key, default)
    if not isinstance(value, str) or not value:
        raise ProtocolError(f"{CAPABILITIES_ARG} needs a non-empty string {key!r}, got {value!r}")
    return value


def declared_capabilities(command: list[str], timeout: float) -> Capabilities:
    """Ask a runner what it supports, and hold it to the protocol's answer.

    Every rejection here names the key and what was seen, because the author on the other
    end of it is writing a runner from a document and cannot read this file to find out.
    """
    outcome = invoke(command, [CAPABILITIES_ARG], timeout)
    if outcome.error:
        raise ProtocolError(f"{CAPABILITIES_ARG} {outcome.error}")
    if outcome.returncode != 0:
        detail = outcome.stderr.strip()[:2000] or outcome.stdout.strip()[:2000]
        raise ProtocolError(f"{CAPABILITIES_ARG} exited {outcome.returncode}: {detail}")
    try:
        doc = json.loads(outcome.stdout)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"{CAPABILITIES_ARG} did not print one JSON object: {exc}") from exc
    if not isinstance(doc, dict):
        raise ProtocolError(f"{CAPABILITIES_ARG} printed {type(doc).__name__}, not a JSON object")

    protocol = doc.get("protocol")
    if protocol != PROTOCOL_VERSION:
        raise ProtocolError(f"declares protocol {protocol!r}; this harness speaks {PROTOCOL_VERSION}")

    name = _declared_str(doc, "name")
    family = _declared_str(doc, "family", name.split("/", maxsplit=1)[0])
    read_path = _declared_str(doc, "readPath")
    if read_path not in ("streamed", "indexed"):
        raise ProtocolError(f"declares readPath {read_path!r}; expected 'streamed' or 'indexed'")

    # Absent means no, for both of these. A runner that says nothing about the invalid
    # corpus skips it, exactly as a family absent from REFUSAL_FAMILIES does — silence is
    # not a claim, and the suite may not credit one nobody made.
    refusals = doc.get("refusals", False)
    if not isinstance(refusals, bool):
        raise ProtocolError(f"declares refusals {refusals!r}; expected true or false")
    declines = doc.get("declines", [])
    if not isinstance(declines, list) or not all(isinstance(item, str) and item for item in declines):
        raise ProtocolError(f"declares declines {declines!r}; expected a list of name fragments")

    return Capabilities(
        family=family,
        name=name,
        indexed=read_path == "indexed",
        refusals=refusals,
        declines=tuple(declines),
    )


def builtin_jobs(family_filter: str | None) -> Iterator[tuple[Capabilities, list[str]]]:
    """Every built-in runner that is present on this machine.

    The "is it built?" test is `os.path.exists(command[-1])`, and that is a property of
    this table rather than of runners in general: every entry ends in a path — a script, a
    compiled binary — so the last argument existing is exactly the question. A command
    like `go run ./cmd/runner` or `dotnet run --project X` ends in neither, which is why
    an out-of-tree runner is not asked this question at all: the capabilities handshake is
    its liveness check, and a command that cannot be started fails it with the OS's own
    message.
    """
    for family, runner_name, command in RUNNERS:
        if family_filter and family != family_filter:
            continue
        if not os.path.exists(command[-1]):
            print(f"skipping {runner_name}: {command[-1]} is not built")
            continue
        yield builtin_capabilities(family, runner_name), command


def external_jobs(commands: list[str], timeout: float) -> list[tuple[Capabilities, list[str]]]:
    """Shake hands with every `--runner-cmd`, or explain which one refused to.

    A failed handshake is fatal rather than a skip. A built-in family that is not built is
    somebody who has not run `cargo build`; a runner named on the command line is one
    somebody is actively trying to score, and silently scoring nothing is the green-suite
    -that-proved-nothing failure this harness already refuses elsewhere.
    """
    jobs = []
    for text in commands:
        command = shlex.split(text)
        if not command:
            raise ProtocolError(f"--runner-cmd {text!r} is empty")
        try:
            caps = declared_capabilities(command, timeout)
        except ProtocolError as exc:
            raise ProtocolError(f"--runner-cmd {text!r}: {exc}") from exc
        declines = ", ".join(caps.declines) if caps.declines else "nothing"
        print(
            f"{caps.name}: protocol {PROTOCOL_VERSION}, {'indexed' if caps.indexed else 'streamed'} read path, "
            f"refusals {'answered' if caps.refusals else 'declined'}, declines {declines}"
        )
        jobs.append((caps, command))
    return jobs


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="run the 4dgs conformance suite")
    parser.add_argument("--runner", help="only this family (e.g. python)")
    parser.add_argument(
        "--runner-cmd",
        action="append",
        metavar="COMMAND",
        help="score a runner that does not live in this repository, e.g. 'go run ./cmd/decode_streamed'. "
        "Repeatable, once per read path. The command is asked what it supports with "
        f"{CAPABILITIES_ARG} and then driven exactly as a built-in runner is.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        metavar="SECONDS",
        help=f"seconds one invocation may take before it is failed (default {DEFAULT_TIMEOUT:g})",
    )
    parser.add_argument("--update", action="store_true", help="rewrite expectations from the runner output")
    args = parser.parse_args(argv)

    if args.runner_cmd and args.runner:
        parser.error("--runner selects a built-in family; --runner-cmd replaces the built-in table")
    if args.runner_cmd and args.update:
        # The expectations are the contract every implementation is scored against. A
        # runner this repository does not own may be compared to them and may not become
        # them, or the first out-of-tree run would quietly redefine what correct means.
        parser.error("--update rewrites the committed expectations; it is for built-in runners only")

    names = variants()
    if not names:
        print("no corpus; run tests/conformance/generate.py first", file=sys.stderr)
        return 1

    if args.runner_cmd:
        try:
            jobs: list[tuple[Capabilities, list[str]]] = external_jobs(args.runner_cmd, args.timeout)
        except ProtocolError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    else:
        jobs = list(builtin_jobs(args.runner))

    passed = skipped = failed = 0
    ran_families: set[str] = set()
    for caps, command in jobs:
        ran_families.add(caps.family)
        for variant in names:
            if not supports(caps, variant):
                skipped += 1
                continue
            # `variant` may carry the invalid corpus's `invalid/` prefix; split it so
            # the separator is the platform's rather than the name's.
            parts = variant.split("/")
            path = os.path.join(DATA, *parts[:-1], f"{parts[-1]}.4dgs")
            expectation_path = os.path.join(DATA, *parts[:-1], f"{parts[-1]}.json")
            # A runner that exits non-zero, hangs, or cannot be started is a reportable
            # failure of one variant, not an exception out of the harness.
            outcome = invoke(command, [path], args.timeout)
            if outcome.error:
                failed += 1
                print(f"FAIL {caps.name} {variant}: runner {outcome.error}")
                continue
            if outcome.returncode != 0:
                failed += 1
                print(f"FAIL {caps.name} {variant}: runner exited {outcome.returncode}")
                print(outcome.stderr.strip()[:2000])
                continue
            actual = outcome.stdout.strip()
            if args.update:
                with open(expectation_path, "w", encoding="utf-8") as fh:
                    fh.write(actual + "\n")
                passed += 1
                continue
            with open(expectation_path, encoding="utf-8") as fh:
                expected = fh.read().strip()
            # Stdout that does not parse is one variant's failure, and the offending text
            # is quoted. Unguarded, a single stray print in a runner ends the whole run
            # with a traceback about the harness rather than about the runner.
            try:
                actual_json = json.loads(actual)
            except json.JSONDecodeError as exc:
                failed += 1
                print(f"FAIL {caps.name} {variant}: stdout is not one JSON document ({exc})")
                print(f"  stdout: {actual[:200]!r}")
                continue
            if actual_json == json.loads(expected):
                passed += 1
            else:
                failed += 1
                print(f"FAIL {caps.name} {variant}")
                diff = difflib.unified_diff(
                    expected.splitlines(), actual.splitlines(), "expected", "actual", lineterm="", n=2
                )
                for line in list(diff)[:40]:
                    print("  " + line)

    print(f"\n{passed} passed, {skipped} skipped (variant not supported), {failed} failed")
    if failed:
        return 1
    # A runner family that was asked for and never ran is a failure, not a pass. The
    # alternative is a green suite that proved nothing, which is worse than a red one.
    if args.runner and args.runner not in ran_families:
        print(f"error: no runner for --runner {args.runner} was executed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
