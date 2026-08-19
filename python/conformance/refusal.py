# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Which decode errors are answers, and which are failed invocations.

The runner protocol has two outcomes for a file that would not decode, and they are
different claims. An error carrying one of the refusal identifiers the invalid corpus
registers is an **answer**: `{"refused": "<identifier>"}` on stdout and exit 0, diffed
against the committed expectation like any other. Anything else — a truncated transport,
an I/O error, a parse failure the vocabulary does not name — is a **failed invocation**:
a diagnosis on stderr and a non-zero exit.

Serializing a missing identifier as `""` collapses the two, which is what both entry
points used to do. The empty string is not an identifier the format defines, yet the
process exits 0 and so claims a valid answer; the harness then cannot tell "refused for a
reason nobody named" from "refused for the wrong reason", and `--update` — which writes
whatever a runner prints, without parsing it — would commit the empty identifier as the
contract every other implementation is scored against.

The vocabulary is `invalid.CODES`, the corpus's own registry, rather than a list restated
here. A new invalid-corpus refusal is registered there and every runner picks it up,
which is the same rule the Rust and C++ runners follow through their libraries' refusal
codes: an error the table does not name is a failure, because reporting it as a refusal
would let a decoder pass the invalid corpus by falling over in roughly the right place.

Shared by both read paths on purpose. The two runners reach a refusal by different routes
— front to back, and through the Footer — and a rule stated twice is a rule that can come
to differ between them, which is exactly the disagreement the suite exists to catch.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for _needed in (
    os.path.join(HERE, "..", "..", "tests", "conformance"),
    os.path.join(HERE, "..", "..", "tests", "conformance", "generator"),
):
    # Importable whichever runner imported this module, and whichever order they set up
    # their own paths in.
    if _needed not in sys.path:
        sys.path.insert(0, _needed)

import invalid
from canonical import canonical

#: Every refusal identifier the suite knows, from the corpus that declares them.
CODES = invalid.CODES


def refusal_answer(exc: BaseException) -> str | None:
    """The canonical refusal document for `exc`, or `None` when it is not one.

    `None` is not a failure of this function: it is the library saying "this is not one of
    the refusals the corpus compares". The caller turns that into a failed invocation —
    stderr and a non-zero exit — rather than into a refusal nobody can check.
    """
    code = getattr(exc, "code", "")
    if code not in CODES:
        return None
    return canonical({"refused": code})
