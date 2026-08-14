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
import json
import math
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from decimal import InvalidOperation
from typing import NamedTuple

from json_compare import diagnostic_differences
from json_compare import for_capabilities as comparison_document
from json_compare import loads as load_canonical_json

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
#: for an error their library names with a refusal identifier, rather than exiting
#: non-zero. A family absent here SKIPS the invalid corpus, exactly as it would skip any
#: variant it declines, and the feature matrix is where that shows up publicly. Adding a
#: language is one entry here plus the few lines in its runner that turn a *named* refusal
#: into that document and leave every other decode error on stderr with a non-zero exit —
#: an error the vocabulary does not name is a failed invocation, not an empty identifier.
REFUSAL_FAMILIES = frozenset({"python", "rust", "typescript", "cpp", "swift", "dart"})

# Exact canonical-unit aggregation is introduced as a stacked conformance change. The
# transition is field-level: families absent here still compare every variant and every
# field except positionSum/opacitySum. Each implementation layer adds only its own family.
# The transition itself claims no implementation. Each SDK layer adds only its own family
# after its focused tests and strict corpus pass prove the feature.
EXACT_AGGREGATE_FAMILIES = frozenset({"python"})
CANONICAL_STATE_ORDER_FAMILIES = frozenset({"python"})


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

FAMILY_DECLINES: dict[str, tuple[str, ...]] = {}


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

#: Bytes of one stream the harness will hold. An answer is one JSON document — the largest
#: expectation in the corpus is under 25 KB — so this is three orders of magnitude of room
#: for a runner behaving as documented, and a bound on one that is not. A runner that
#: streams without end costs one red variant naming the limit rather than the host's
#: memory, which is principle 1 applied to the harness itself: nothing here accumulates
#: without a ceiling it declared first.
MAX_CAPTURE_BYTES = 8 * 1024 * 1024

#: Read size while draining a runner's pipes. The pipes are drained continuously whatever
#: the bound, because a harness that stops reading blocks the writer instead of the writer
#: blocking on the harness — a deadlock that looks exactly like the hang the timeout exists
#: to catch, but reported against the wrong runner.
_READ_BLOCK = 65536


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
    #: Whether position/opacity aggregates use exact canonical decimal units.
    exact_aggregates: bool = False
    #: Whether composed state samples use portable emitted-value ordering.
    canonical_state_order: bool = False


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
        exact_aggregates=family in EXACT_AGGREGATE_FAMILIES,
        canonical_state_order=family in CANONICAL_STATE_ORDER_FAMILIES,
    )


def supports(caps: Capabilities, variant: str) -> bool:
    # The invalid corpus is decided by `refusals` alone, and all seven or none of it.
    # `declines` names features of the *valid* corpus, and letting a fragment reach across
    # here silently unmakes the claim the runner just made: a runner declining `Unknown`
    # because it has not implemented unknown record types would answer two refusals while
    # the handshake line said it answered the seven. That is the overstatement this suite
    # exists to prevent, and it is not the runner's fault — the collision is between a
    # feature name and a filename. Built-in families work the same way: `REFUSAL_FAMILIES`
    # is all-or-nothing, so an outside runner is held to neither more nor less.
    #
    # Both read paths are asked. The two reach the Header by different routes — one front
    # to back, one through the Footer — and a check placed on only one of them refuses
    # half the files it should, so the invalid corpus is cut from a variant that carries
    # an index and `UseChunkIndex` is not consulted here.
    if variant.startswith(INVALID_PREFIX):
        return caps.refusals
    if any(flag in variant for flag in caps.declines):
        return False
    if not caps.indexed:
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


class _Capture:
    """One pipe, drained to the end but kept only up to a bound.

    Kept and total are separate on purpose: the harness needs the prefix to report with,
    and needs to know it is a prefix so it can say so rather than diff a truncation.
    """

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._chunks: list[bytes] = []
        self._kept = 0
        self.total = 0

    def drain(self, stream, on_overflow: Callable[[], None]) -> None:
        try:
            while True:
                block = stream.read(_READ_BLOCK)
                if not block:
                    return
                self.total += len(block)
                if self._kept < self.limit:
                    keep = block[: self.limit - self._kept]
                    self._chunks.append(keep)
                    self._kept += len(keep)
                # Outside the branch above, not inside it: the block that fills the buffer
                # is usually the one that fits exactly, and a check that only runs while
                # there is still room to keep bytes never sees the stream go past it.
                if self.total > self.limit:
                    on_overflow()
        except (OSError, ValueError):
            # The pipe went away under us — the process was killed, which is a state the
            # caller already knows about and reports better than a traceback here can.
            return
        finally:
            try:
                stream.close()
            except OSError:
                pass

    @property
    def overflowed(self) -> bool:
        return self.total > self.limit

    def text(self) -> str:
        # A runner's answer is UTF-8 by protocol. Bytes that are not are the runner's
        # defect and must cost one variant: decoding strictly — which is what `text=True`
        # does with the platform's encoding — ends the whole run in a UnicodeDecodeError
        # raised from inside the harness, naming neither the runner nor the variant.
        return b"".join(self._chunks).decode("utf-8", errors="replace")


def _spawn_kwargs() -> dict:
    """Give the runner its own process group, so the whole tree can be ended at once."""
    if os.name == "nt":
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def _terminate_tree(proc: subprocess.Popen, process_group: int | None = None) -> None:
    """End the runner and everything it started.

    A wrapper command — `go run ./cmd/runner`, `dotnet run --project X`, a shell script —
    is not the decoder; it launches one. Killing only the direct child leaves that decoder
    running, and a corpus of 120 variants against a hanging implementation leaves 120 of
    them, each still holding whatever it had mapped. The process group from
    `_spawn_kwargs` is what makes one signal reach all of it.
    """
    if os.name == "nt":
        # Windows has no killpg; taskkill /T walks the child tree instead, and is present
        # on every supported version. If it is not, the direct process is still killed.
        subprocess.run(
            ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
            capture_output=True,
            check=False,
        )
    else:
        try:
            # Save the group id while the direct child is alive and pass it
            # here. A wrapper may exit after backgrounding its decoder; once
            # that leader has been reaped `getpgid(proc.pid)` no longer works,
            # even though descendants still occupy the group and hold our
            # output pipes open.
            os.killpg(process_group if process_group is not None else os.getpgid(proc.pid), signal.SIGKILL)
            return
        except (OSError, ProcessLookupError):
            pass
    try:
        proc.kill()
    except OSError:
        pass


def invoke(command: list[str], args: list[str], timeout: float) -> Outcome:
    try:
        proc = subprocess.Popen(
            [*command, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **_spawn_kwargs(),
        )
    except OSError as exc:
        return Outcome(-1, "", "", f"could not be started: {exc}")

    # `start_new_session=True` makes the child's pid its process-group id on
    # POSIX. Keep it now, before a short-lived wrapper can exit and make the id
    # impossible to recover through `getpgid`.
    process_group = proc.pid if os.name != "nt" else None
    out, err = _Capture(MAX_CAPTURE_BYTES), _Capture(MAX_CAPTURE_BYTES)
    killed = threading.Event()

    def kill_once() -> None:
        # A runner past the bound has already failed; ending it now costs the run seconds
        # rather than the whole timeout, and the drain threads see EOF and finish.
        if not killed.is_set():
            killed.set()
            _terminate_tree(proc, process_group)

    threads = [
        threading.Thread(target=out.drain, args=(proc.stdout, kill_once), daemon=True),
        threading.Thread(target=err.drain, args=(proc.stderr, kill_once), daemon=True),
    ]
    for thread in threads:
        thread.start()

    timed_out = False
    try:
        returncode = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        _terminate_tree(proc, process_group)
        try:
            returncode = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            returncode = -1
    # One shared bound, not one full wait per pipe: a wrapper that backgrounds a
    # child commonly leaves both drains open, and paying the bound twice would
    # add two delays to every variant. A clean process has already closed both
    # descriptors; one second is ample to consume the bounded tail.
    drain_deadline = time.monotonic() + 1
    for thread in threads:
        thread.join(timeout=max(0.0, drain_deadline - time.monotonic()))

    unfinished = [thread for thread in threads if thread.is_alive()]
    if unfinished:
        # A successful wrapper can background the real decoder and exit before
        # the invocation timeout. The descendant inherits stdout/stderr, so an
        # unfinished drain is positive evidence that the invocation tree is
        # still alive. End the saved group and give the drains one bounded
        # chance to observe EOF before returning a failure.
        _terminate_tree(proc, process_group)
        cleanup_deadline = time.monotonic() + 1
        for thread in unfinished:
            thread.join(timeout=max(0.0, cleanup_deadline - time.monotonic()))
        return Outcome(-1, out.text(), err.text(), "left descendants holding its output pipes open")

    if timed_out:
        return Outcome(-1, "", "", f"did not answer within {timeout:g}s")
    if out.overflowed or err.overflowed:
        stream = "stdout" if out.overflowed else "stderr"
        return Outcome(-1, out.text(), err.text(), f"printed more than {MAX_CAPTURE_BYTES} bytes on {stream}")
    return Outcome(returncode, out.text(), err.text())


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
    # `json.loads` also raises plain ValueError for implementation limits such as
    # Python's maximum integer-string length, and RecursionError when a syntactically
    # valid document nests beyond the parser's stack. Every unparseable handshake is a
    # protocol error, including those two inputs rather than a harness traceback.
    except (ValueError, RecursionError) as exc:
        raise ProtocolError(f"{CAPABILITIES_ARG} did not print one JSON object: {exc}") from exc
    if not isinstance(doc, dict):
        raise ProtocolError(f"{CAPABILITIES_ARG} printed {type(doc).__name__}, not a JSON object")

    # `isinstance(True, int)` is true in Python, so a runner that serialized its version as
    # a boolean — `"protocol": true` — would compare equal to 1 and be scored against a
    # declaration it never made. The type is checked before the value so that the error
    # names what arrived rather than reinterpreting it.
    protocol = doc.get("protocol")
    if isinstance(protocol, bool) or not isinstance(protocol, int):
        raise ProtocolError(f"declares protocol {protocol!r}; expected the integer {PROTOCOL_VERSION}")
    if protocol != PROTOCOL_VERSION:
        raise ProtocolError(f"declares protocol {protocol!r}; this harness speaks {PROTOCOL_VERSION}")

    name = _declared_str(doc, "name")
    family = _declared_str(doc, "family", name.split("/", maxsplit=1)[0])
    read_path = _declared_str(doc, "readPath")
    if read_path not in ("streamed", "indexed"):
        raise ProtocolError(f"declares readPath {read_path!r}; expected 'streamed' or 'indexed'")
    expected_name = f"{family}/decode_{read_path}"
    if name != expected_name:
        raise ProtocolError(
            f"declares name {name!r} for family {family!r} and readPath {read_path!r}; expected {expected_name!r}"
        )

    # Absent means no, for both of these. A runner that says nothing about the invalid
    # corpus skips it, exactly as a family absent from REFUSAL_FAMILIES does — silence is
    # not a claim, and the suite may not credit one nobody made.
    refusals = doc.get("refusals", False)
    if not isinstance(refusals, bool):
        raise ProtocolError(f"declares refusals {refusals!r}; expected true or false")
    declines = doc.get("declines", [])
    if not isinstance(declines, list) or not all(isinstance(item, str) and item for item in declines):
        raise ProtocolError(f"declares declines {declines!r}; expected a list of name fragments")
    exact_aggregates = doc.get("exactAggregates", False)
    if not isinstance(exact_aggregates, bool):
        raise ProtocolError(f"declares exactAggregates {exact_aggregates!r}; expected true or false")
    canonical_state_order = doc.get("canonicalStateOrder", False)
    if not isinstance(canonical_state_order, bool):
        raise ProtocolError(f"declares canonicalStateOrder {canonical_state_order!r}; expected true or false")

    return Capabilities(
        family=family,
        name=name,
        indexed=read_path == "indexed",
        refusals=refusals,
        declines=tuple(declines),
        exact_aggregates=exact_aggregates,
        canonical_state_order=canonical_state_order,
    )


def split_windows_command(text: str) -> list[str]:
    """Split a command line the way `CommandLineToArgvW` does.

    This is the rule every Windows program is started under, and the only one that agrees
    with what the user typed. `shlex` cannot stand in for it in either mode: POSIX mode
    treats a backslash as an escape, so `python C:\\work\\decode.py` arrives as
    `C:workdecode.py`; non-POSIX mode keeps the backslashes but only recognizes a quote
    that begins a token, so the everyday `runner.exe --label="two words"` splits into
    `--label="two` and `words"` instead of the single argument Windows would deliver.
    Python's own documentation says `shlex.split` is designed for Unix shells.

    The three rules, from the same table `subprocess.list2cmdline` writes for:

    - whitespace separates arguments unless it is inside a quoted run;
    - `2n` backslashes before a quote are `n` backslashes and the quote is a delimiter;
      `2n+1` are `n` backslashes and a literal quote. Backslashes not before a quote are
      literal, which is what makes a path a path;
    - a quote inside a quoted run, doubled, is one literal quote.
    """
    args: list[str] = []
    i, end = 0, len(text)
    while i < end:
        while i < end and text[i] in " \t":
            i += 1
        if i >= end:
            break
        token: list[str] = []
        quoted = False
        while i < end:
            char = text[i]
            if char == "\\":
                run = i
                while run < end and text[run] == "\\":
                    run += 1
                slashes = run - i
                if run < end and text[run] == '"':
                    token.append("\\" * (slashes // 2))
                    if slashes % 2:
                        token.append('"')
                        i = run + 1
                    else:
                        # Leave the quote to the branch below, which owns both the toggle
                        # and the doubled-quote case rather than restating either here.
                        i = run
                else:
                    token.append("\\" * slashes)
                    i = run
                continue
            if char == '"':
                if quoted and i + 1 < end and text[i + 1] == '"':
                    token.append('"')
                    i += 2
                else:
                    quoted = not quoted
                    i += 1
                continue
            if char in " \t" and not quoted:
                i += 1
                break
            token.append(char)
            i += 1
        args.append("".join(token))
    return args


def split_command(text: str) -> list[str]:
    """Split a `--runner-cmd` the way the platform it runs on would.

    A command line is not a portable notation, and the harness has no business asking an
    author to spell theirs in another platform's grammar to be scored.
    """
    if os.name == "nt":
        return split_windows_command(text)
    return shlex.split(text)


def positive_seconds(text: str) -> float:
    """A `--timeout` that actually bounds an invocation.

    `float("nan")` and `float("inf")` are both accepted by `float()`, and both defeat the
    bound rather than widening it: `Popen.wait(timeout=nan)` never expires — every
    comparison against NaN is false — so a single hanging runner hangs the whole suite,
    which is precisely what the timeout exists to prevent. Zero and negative values are
    refused here too; they are answerable, but they fail every runner on the first variant
    for a reason the output would blame on the runner.
    """
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a number of seconds") from None
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError(f"{text!r} does not bound an invocation; give a finite number above zero")
    return value


def compared_documents(actual_json, expected_json, caps: Capabilities):
    """Build the two documents scored by the harness without leaking parser depth errors."""
    try:
        return (
            comparison_document(
                actual_json,
                exact_aggregates=caps.exact_aggregates,
                canonical_state_order=caps.canonical_state_order,
            ),
            comparison_document(
                expected_json,
                exact_aggregates=caps.exact_aggregates,
                canonical_state_order=caps.canonical_state_order,
            ),
        ), None
    except RecursionError as exc:
        return None, exc


def runner_document(text: str):
    """Parse one untrusted runner response without letting it abort the whole suite."""
    try:
        return load_canonical_json(text), None
    except (ValueError, RecursionError, InvalidOperation) as exc:
        return None, exc


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
        try:
            command = split_command(text)
        except ValueError as exc:
            raise ProtocolError(f"--runner-cmd {text!r} cannot be parsed: {exc}") from exc
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
        type=positive_seconds,
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
    #: How many variants each job was actually compared on. A job is what was asked for —
    #: a built-in runner that exists, or a `--runner-cmd` somebody typed — and one that
    #: answers nothing has proved nothing, however green the totals look.
    #: Indexed by position rather than keyed by name, so two jobs that call themselves the
    #: same thing are still counted apart.
    executed = [0] * len(jobs)
    for job, (caps, command) in enumerate(jobs):
        ran_families.add(caps.family)
        for variant in names:
            if not supports(caps, variant):
                skipped += 1
                continue
            executed[job] += 1
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
            actual_json, parse_error = runner_document(actual)
            if parse_error is not None:
                failed += 1
                print(f"FAIL {caps.name} {variant}: stdout is not one JSON document ({parse_error})")
                print(f"  stdout: {actual[:200]!r}")
                continue
            assert actual_json is not None
            expected_json = load_canonical_json(expected)
            compared, comparison_error = compared_documents(actual_json, expected_json, caps)
            if comparison_error is not None:
                failed += 1
                print(
                    f"FAIL {caps.name} {variant}: stdout exceeds the canonical comparison nesting limit "
                    f"({comparison_error})"
                )
                print(f"  stdout: {actual[:200]!r}")
                continue
            assert compared is not None
            actual_comparable, expected_comparable = compared
            if actual_comparable == expected_comparable:
                passed += 1
            else:
                failed += 1
                print(f"FAIL {caps.name} {variant}")
                for line in diagnostic_differences(expected_comparable, actual_comparable):
                    print("  " + line)

    print(f"\n{passed} passed, {skipped} skipped (variant not supported), {failed} failed")
    if failed:
        return 1
    # A runner that was asked for and never ran is a failure, not a pass. The alternative
    # is a green suite that proved nothing, which is worse than a red one.
    #
    # Two shapes of that. A family named with `--runner` whose runners are all unbuilt
    # never becomes a job at all, so the check is against the families that did. And a job
    # that exists but declines every variant — `"refusals": false` plus a `declines` list
    # covering the valid corpus — would otherwise print `0 passed, 120 skipped, 0 failed`
    # and exit 0, which is a conformance claim made by answering nothing.
    idle = [caps.name for (caps, _), count in zip(jobs, executed, strict=True) if count == 0]
    if idle:
        for name in idle:
            print(f"error: {name} declined every variant, so nothing was compared", file=sys.stderr)
        return 1
    if args.runner and args.runner not in ran_families:
        print(f"error: no runner for --runner {args.runner} was executed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
