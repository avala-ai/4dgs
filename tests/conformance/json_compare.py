# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Lossless JSON comparison and narrowly scoped conformance transitions."""

from __future__ import annotations

import copy
import json
from decimal import Decimal


def loads(text: str):
    """Parse number tokens without narrowing their decimal spelling through binary64."""
    return json.loads(text, parse_float=Decimal, parse_int=int)


class SignedZero:
    """A negative zero, kept apart from `0.0` so a comparison can see the difference.

    The canonical form's first rule is that a zero is `0.0` and never `-0.0`: the sign is a
    property of the arithmetic path that produced the value, not of the scene, so two
    correct decoders on two platforms would otherwise be required to disagree. `canonical.py`
    states it, `generate.py --verify` enforces it on the committed expectations by comparing
    text, and until this class existed nothing enforced it on a *runner*.

    That gap is the same one the rule was written for, one level up. `run.py` compares
    parsed values, and `-0.0 == 0.0` is true of Python's `float`, of `Decimal`, and of every
    language the suite compares in — so `-0.000000` in a runner's stdout scored equal to
    `0.0` in the expectation and the variant passed. Three of the six SDKs were emitting one
    on the committed corpus when this was written.

    A distinct object rather than a raise: a runner is not malformed for emitting one, it is
    *different from the expectation*, and the harness already has a diagnostic that names a
    differing field by path. Equal only to another `SignedZero`, so an unsigned zero on
    either side is a mismatch and two signed zeros still agree.
    """

    __slots__ = ()

    def __repr__(self) -> str:
        return "-0.0"

    def __eq__(self, other) -> bool:
        return isinstance(other, SignedZero)

    def __hash__(self) -> int:
        return hash("-0.0")


#: The one instance; `SignedZero` carries no state and equality does not depend on identity.
SIGNED_ZERO = SignedZero()


def _is_signed_zero(value: Decimal) -> bool:
    """True for a finite zero whose token carried a minus sign.

    `is_signed` alone is not enough — it is true of every negative number — and `== 0` alone
    is not enough either. `is_finite` guards `-0e-999999999`-style tokens, which `Decimal`
    keeps as zeros, and NaN, whose sign says nothing.
    """
    return value.is_finite() and value.is_zero() and value.is_signed()


def without_exact_aggregates(summary):
    """Return a copy without the two exact-unit aggregate fields under transition.

    The root population counters, every other root field, and every non-aggregate state
    field remain in the comparison. This compatibility seam is removed one SDK at a
    time when that SDK declares exact canonical aggregate support.
    """
    comparable = copy.deepcopy(summary)

    def omit(block) -> None:
        if isinstance(block, dict):
            block.pop("positionSum", None)
            block.pop("opacitySum", None)

    if isinstance(comparable, dict):
        omit(comparable.get("aggregate"))
        states = comparable.get("states", [])
        if isinstance(states, list):
            for state in states:
                if isinstance(state, dict):
                    omit(state.get("aggregate"))
    return comparable


def for_capabilities(summary, *, exact_aggregates: bool, canonical_state_order: bool):
    """Select the strict or narrowly transitional document for one runner."""
    # Lossless parsing is required for exact aggregate tokens beyond binary64. Ordinary
    # canonical numbers retain the suite's established JSON-number semantics: e.g. a
    # shortest max-f64 token and a fixed exact-decimal spelling of that same f64 agree.
    # Normalize those ordinary Decimal tokens first, then restore only exact totals.
    comparable = _ordinary_numbers(summary)
    if exact_aggregates:
        _restore_exact_aggregates(summary, comparable)
    if not exact_aggregates:
        comparable = without_exact_aggregates(comparable)
    if not canonical_state_order and isinstance(comparable, dict):
        states = comparable.get("states", [])
        if isinstance(states, list):
            for state in states:
                if isinstance(state, dict):
                    state.pop("sample", None)
    return comparable


def _ordinary_numbers(value):
    if isinstance(value, Decimal):
        # `float(Decimal("-0.000000"))` is `-0.0`, which then compares equal to every
        # unsigned zero. Substituting the marker is what makes the sign survive into the
        # comparison; see `SignedZero`.
        return SIGNED_ZERO if _is_signed_zero(value) else float(value)
    if isinstance(value, dict):
        return {key: _ordinary_numbers(nested) for key, nested in value.items()}
    if isinstance(value, (list, tuple)):
        return [_ordinary_numbers(nested) for nested in value]
    return copy.deepcopy(value)


def _exact_units(value):
    """An exact aggregate kept at full decimal precision, minus the sign of a zero.

    `Decimal` is retained here precisely because narrowing loses information — but it does
    not distinguish `Decimal("-0.0")` from `Decimal("0.0")` under `==` any more than `float`
    does, so the exact totals needed the same marker as the ordinary numbers around them.
    """
    if isinstance(value, Decimal):
        return SIGNED_ZERO if _is_signed_zero(value) else value
    if isinstance(value, dict):
        return {key: _exact_units(nested) for key, nested in value.items()}
    if isinstance(value, (list, tuple)):
        return [_exact_units(nested) for nested in value]
    return copy.deepcopy(value)


def _restore_exact_aggregates(source, target) -> None:
    def restore(source_block, target_block) -> None:
        if not isinstance(source_block, dict) or not isinstance(target_block, dict):
            return
        for key in ("positionSum", "opacitySum"):
            if key in source_block:
                target_block[key] = _exact_units(source_block[key])

    if not isinstance(source, dict) or not isinstance(target, dict):
        return
    restore(source.get("aggregate"), target.get("aggregate"))
    source_states = source.get("states", [])
    target_states = target.get("states", [])
    if isinstance(source_states, list) and isinstance(target_states, list):
        for source_state, target_state in zip(source_states, target_states, strict=False):
            if isinstance(source_state, dict) and isinstance(target_state, dict):
                restore(source_state.get("aggregate"), target_state.get("aggregate"))


def compact(value) -> str:
    """Stable compact JSON with Decimal values retained as number tokens."""
    strings: set[str] = set()

    def collect(item):
        if isinstance(item, dict):
            for key, nested in item.items():
                strings.add(str(key))
                collect(nested)
        elif isinstance(item, (list, tuple)):
            for nested in item:
                collect(nested)
        elif isinstance(item, str):
            strings.add(item)

    collect(value)
    prefix = "\0fourdgs-decimal\0"
    while any(prefix in item for item in strings):
        prefix += "#"
    replacements: dict[str, str] = {}

    def mark(item):
        if isinstance(item, Decimal):
            marker = f"{prefix}{len(replacements)}"
            replacements[json.dumps(marker)] = str(item)
            return marker
        if isinstance(item, dict):
            return {key: mark(nested) for key, nested in item.items()}
        if isinstance(item, (list, tuple)):
            return [mark(nested) for nested in item]
        return item

    text = json.dumps(mark(value), sort_keys=True, separators=(",", ":"))
    for marker, token in replacements.items():
        text = text.replace(marker, token)
    return text


def diagnostic_differences(expected, actual, *, max_lines: int = 40, max_chars: int = 8000) -> tuple[str, ...]:
    """Return a bounded, typed description of differences between two documents.

    The runner's stdout is already size-capped. Diagnostics must not multiply that bound by
    pretty-printing every value at every nesting level, so this walks in place, stops after a
    fixed number of differences/characters, and never constructs a complete rendered document.
    """
    lines: list[str] = []
    chars = 0
    max_depth = 64
    missing = object()

    def add(line: str) -> None:
        nonlocal chars
        if len(lines) >= max_lines or chars >= max_chars:
            return
        remaining = max_chars - chars
        if len(line) > remaining:
            line = line[: max(0, remaining - 1)] + "…"
        lines.append(line)
        chars += len(line)

    def full() -> bool:
        return len(lines) >= max_lines or chars >= max_chars

    def child_path(path: str, key) -> str:
        if isinstance(key, int):
            suffix = f"[{key}]"
        else:
            key_text = str(key)
            if len(key_text) > 80:
                key_text = key_text[:79] + "…"
            suffix = f"[{json.dumps(key_text)}]"
        joined = path + suffix
        return joined if len(joined) <= 320 else "…" + joined[-319:]

    def scalar(value) -> str:  # noqa: PLR0911 - bounded type dispatcher
        if value is missing:
            return "<missing>"
        if isinstance(value, SignedZero):
            # Spelled out rather than typed like the others: the whole difference is the
            # one character, and "expected <json-number 0.0>; actual <SignedZero>" is a
            # report a reader has to decode before it says anything.
            return "<json-number -0.0>"
        if isinstance(value, Decimal):
            if not value.is_finite():
                return f"<json-number {value.number_class()}>"
            # Never stringify an attacker-sized coefficient. Decimal's numeric hash and
            # adjusted exponent are bounded-size and preserve the JSON number type.
            return f"<json-number adjusted={value.adjusted()} hash={hash(value)}>"
        if isinstance(value, str):
            if len(value) > 160:
                return f"<json-string length={len(value)} prefix={json.dumps(value[:160])}>"
            return f"<json-string {json.dumps(value)}>"
        if isinstance(value, (dict, list, tuple)):
            return f"<{type(value).__name__} length={len(value)}>"
        try:
            return f"<{type(value).__name__} {json.dumps(value, allow_nan=False)}>"
        except (TypeError, ValueError):
            return f"<{type(value).__name__}>"

    def visit(expected_value, actual_value, path: str, depth: int) -> None:  # noqa: PLR0911 - bounded walk
        if full():
            return
        if depth >= max_depth:
            try:
                if expected_value == actual_value:
                    return
            except RecursionError:
                pass
            add(f"{path}: values differ below diagnostic depth {max_depth}")
            return
        if isinstance(expected_value, dict) and isinstance(actual_value, dict):
            for key, expected_child in expected_value.items():
                if full():
                    return
                visit(expected_child, actual_value.get(key, missing), child_path(path, key), depth + 1)
            for key, actual_child in actual_value.items():
                if full():
                    return
                if key not in expected_value:
                    visit(missing, actual_child, child_path(path, key), depth + 1)
            return
        if isinstance(expected_value, (list, tuple)) and isinstance(actual_value, (list, tuple)):
            common = min(len(expected_value), len(actual_value))
            for index in range(common):
                if full():
                    return
                visit(expected_value[index], actual_value[index], child_path(path, index), depth + 1)
            for index in range(common, len(expected_value)):
                if full():
                    return
                visit(expected_value[index], missing, child_path(path, index), depth + 1)
            for index in range(common, len(actual_value)):
                if full():
                    return
                visit(missing, actual_value[index], child_path(path, index), depth + 1)
            return
        if expected_value == actual_value:
            return
        add(f"{path}: expected {scalar(expected_value)}; actual {scalar(actual_value)}")

    visit(expected, actual, "$", 0)
    return tuple(lines)
