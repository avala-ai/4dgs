# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Well-known values, and the refusal a reader owes an unknown one.

The registry's standing rule is that a value it does not list is legal but unrecognized,
and that a reader which does not know a value **must fail cleanly with a message naming
it** rather than guess. That rule is what makes every future extension safe: a new
temporal model, a new quantization scheme, a new codec can all be added without a version
bump precisely because an old reader stops instead of misreading.

Until this module existed the rule was not enforced for two of those fields. A file
declaring a temporal model this reader has never heard of decoded as though it were
`gaussian-birth` — silently, and into geometry that looks plausible, because the Header's
other fields are all still valid. That is the exact failure the rule exists to prevent,
and it was invisible because nothing in the corpus declared an unknown value.
"""

from __future__ import annotations

from .exceptions import UnsupportedCodec

#: Temporal models this reader implements. The registry names others as reserved; a
#: reserved name is one this reader must refuse, not one it may treat as the default.
KNOWN_TEMPORAL_MODELS = frozenset({"gaussian-birth"})

#: Quantization schemes this reader implements.
KNOWN_QUANTIZATION_SCHEMES = frozenset({"uniform-v1"})


def check_temporal_model(model: str) -> None:
    if model not in KNOWN_TEMPORAL_MODELS:
        raise UnsupportedCodec(
            f"the Header declares temporal model {model!r}, which this reader does not implement "
            f"(it implements {', '.join(sorted(KNOWN_TEMPORAL_MODELS))})",
            code="unknown-temporal-model",
        )


def check_quantization_scheme(scheme: str) -> None:
    if scheme not in KNOWN_QUANTIZATION_SCHEMES:
        raise UnsupportedCodec(
            f"the Quantization record declares scheme {scheme!r}, which this reader does not implement "
            f"(it implements {', '.join(sorted(KNOWN_QUANTIZATION_SCHEMES))})",
            code="unknown-quantization-scheme",
        )
