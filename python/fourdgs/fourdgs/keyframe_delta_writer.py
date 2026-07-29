# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Encoding a `keyframe-delta` file.

The caller supplies a **sequence of samples**: a population, with identities, stated at a
sequence of times. The encoder picks keyframes by cadence, quantizes every sample on one
set of grids, and writes each non-keyframe sample as the *difference of bins* against the
chunk it references.

Quantizing every sample up front, on grids derived from the whole sequence, is the part
that makes the model's error claim true. A delta is then an integer subtraction between
two bins on the same grid, the composition telescopes, and the reconstructed bin at any
depth is exactly the bin an absolute statement of that instant would have carried. An
encoder that instead quantized `x_j - x_{j-1}` would produce a file whose declared bounds
mean nothing after the second delta.

What this encoder does not do is decide *what* to update. Which gaussians moved enough to
be worth a byte, and how often to spend a keyframe, is rate control — encoder policy, and
the place encoders differentiate. This one updates a gaussian when any of its bins
changed, which is the simplest rule that is also correct.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import opcode as op
from . import records as rec
from .exceptions import InvalidInput
from .keyframe_delta import ABSOLUTE_IN_UPDATE, GOP_INVARIANT
from .model import GaussianSet
from .serialization import encode_stream


@dataclass
class Sample:
    """One population, at one instant, with identity.

    `ids` is aligned with the gaussians and is what a delta names them by. It is required
    rather than derived: the whole model rests on correspondence between samples, and a
    correspondence the encoder invented from row order is one the caller never asserted.
    """

    t0: float
    ids: np.ndarray
    gaussians: GaussianSet


@dataclass
class KeyframeDeltaOptions:
    """Cadence and mode. Everything else comes from the ordinary `WriteOptions`."""

    #: Samples per group of pictures. 1 writes every sample as a keyframe, which is legal
    #: and is the shape the registry's `frame-sequence` reservation describes.
    keyframe_every: int = 8
    #: `DELTA_MODE_CHAINED` references the previous chunk; `DELTA_MODE_KEYFRAME`
    #: references the group's keyframe. Chained is the default because it is smaller and
    #: its chain is contiguous in the file, so a range reader coalesces it into one
    #: request — see the design's section on why the choice is about cost and not error.
    delta_mode: int = rec.DELTA_MODE_CHAINED
    #: Sample indices to force a keyframe at, beyond the cadence. A producer that knows
    #: where a cut is puts one here so that instant costs two records however deep into a
    #: group it would otherwise have fallen.
    keyframe_at: tuple[int, ...] = field(default_factory=tuple)


def check_invariants(previous: dict[int, np.ndarray], current: dict[int, np.ndarray], rows, ids) -> None:
    """Refuse a sequence that changes a per-gaussian grid mid-group.

    `sigma_t`, `flags` and `window_index` derive the grids for velocity and birth time, so
    a bin difference across a change in any of them subtracts bins that live on different
    grids. The result is not an approximation, it is a number with no meaning — and it
    decodes silently into a wrong velocity rather than into an error, which is why this is
    the encoder's job to catch rather than the decoder's to survive.

    The fix is always available to the caller: a death and a birth, or a keyframe.
    """
    for attribute in sorted(GOP_INVARIANT):
        if attribute not in previous or attribute not in current:
            continue
        before = previous[attribute][rows]
        after = current[attribute]
        if not np.array_equal(before, after):
            row = int(np.argmax((before != after).any(axis=1) if before.ndim > 1 else (before != after)))
            raise InvalidInput(
                f"gaussian id {int(ids[row])} changes attribute {attribute} between samples, which is fixed "
                f"for a gaussian's lifetime within a group: the per-gaussian grids for velocity and birth "
                f"time are derived from it. Emit a keyframe, or a death and a birth.",
                code="invariant-changed-in-update",
            )


def delta_groups(
    reference_ids: np.ndarray,
    reference_bins: dict[int, np.ndarray],
    ids: np.ndarray,
    bins: dict[int, np.ndarray],
) -> tuple[np.ndarray, dict[int, np.ndarray], np.ndarray, dict[int, np.ndarray], np.ndarray]:
    """Split one sample against its reference into updates, births and deaths."""
    live = np.isin(ids, reference_ids)
    death_ids = np.setdiff1d(reference_ids, ids)
    birth_ids = ids[~live]
    birth_bins = {a: v[~live] for a, v in bins.items()}

    common_ids = ids[live]
    order = np.argsort(reference_ids, kind="stable")
    rows = order[np.searchsorted(reference_ids[order], common_ids)]

    common = {a: v[live] for a, v in bins.items()}
    check_invariants(reference_bins, common, rows, common_ids)

    # A gaussian is updated when any of its bins moved. Untouched means no bytes, which is
    # the property the whole model exists to buy.
    changed = np.zeros(common_ids.shape[0], dtype=bool)
    for attribute, values in common.items():
        if attribute in GOP_INVARIANT:
            continue
        before = reference_bins[attribute][rows]
        differs = values != before
        changed |= differs.any(axis=1) if differs.ndim > 1 else differs

    update_ids = common_ids[changed]
    update_rows = rows[changed]
    update_bins: dict[int, np.ndarray] = {}
    for attribute, values in common.items():
        if attribute in GOP_INVARIANT:
            continue
        touched = values[changed]
        if attribute in ABSOLUTE_IN_UPDATE:
            # Restated outright: the smallest-three basis changes whenever the largest
            # quaternion component does, so the three stored bins mean different
            # components either side of it and a difference would be nonsense.
            update_bins[attribute] = touched
        else:
            update_bins[attribute] = touched - reference_bins[attribute][update_rows]

    return update_ids, update_bins, birth_ids, birth_bins, death_ids


def encode_delta_streams(ids: np.ndarray, bins: dict[int, np.ndarray], *, codec: int, level: int) -> bytes:
    """One group's streams: the ids it names, then the attributes it carries."""
    if ids.size == 0:
        return b""
    out = [encode_stream(op.A_GAUSSIAN_ID, ids.reshape(-1, 1), codec=codec, level=level)]
    for attribute in sorted(bins):
        values = bins[attribute]
        values = values.reshape(-1, 1) if values.ndim == 1 else values
        out.append(encode_stream(attribute, values, channels=values.shape[1], codec=codec, level=level))
    return b"".join(out)


def death_streams(ids: np.ndarray, *, codec: int, level: int) -> bytes:
    if ids.size == 0:
        return b""
    return encode_stream(op.A_GAUSSIAN_ID, ids.reshape(-1, 1), codec=codec, level=level)


def is_keyframe(index: int, kd: KeyframeDeltaOptions) -> bool:
    return index == 0 or index in kd.keyframe_at or (kd.keyframe_every > 0 and index % kd.keyframe_every == 0)
