# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Aggregate decoded-state accounting shared by Python's collecting readers.

The wire's per-stream ceilings answer whether one record is bounded.  This module
answers the separate question in specification section 3.3: whether the decoded
results a collecting call retains, together with the next decode/composition working
set, fit under the caller's aggregate ceiling.
"""

from __future__ import annotations

from numbers import Integral

import numpy as np

from .exceptions import ExceedsReaderLimit

DEFAULT_MAX_DECODED_STATE_BYTES = 536_870_912


def validate_max_decoded_state_bytes(value: object) -> int:
    """Return a Python ``int`` for the public positive-integer option.

    ``bool`` is deliberately rejected even though it subclasses ``int``.  Resource
    configuration is a caller argument, so a bad value is ``ValueError`` rather than a
    decode error or a statement about the file.
    """
    if isinstance(value, bool) or not isinstance(value, Integral) or value <= 0:
        raise ValueError("max_decoded_state_bytes must be a positive integer")
    return int(value)


class DecodedStateBudget:
    """One collecting call's retained decoded-state bytes and peak checks."""

    __slots__ = ("limit", "retained")

    def __init__(self, limit: object) -> None:
        self.limit = validate_max_decoded_state_bytes(limit)
        self.retained = 0

    def check(self, additional: int, phase: str) -> int:
        """Require ``retained + additional`` without changing retained ownership."""
        if additional < 0:
            raise AssertionError("decoded-state accounting cannot subtract through check")
        # Python integers do not wrap.  Keeping the addition here, rather than narrowing
        # through a NumPy or platform integer, is the checked-arithmetic implementation.
        required = self.retained + int(additional)
        if required > self.limit:
            raise ExceedsReaderLimit(
                f"decoded-state resource limit during {phase}: at least {required} bytes are required; "
                f"configured limit is {self.limit} bytes"
            )
        return required

    def retain(self, added: int, phase: str) -> int:
        """Charge decoded output that remains owned by the collecting result."""
        required = self.check(added, phase)
        self.retained = required
        return required


def array_capacity_bytes(value: object) -> int:
    """Element capacity of the NumPy arrays nested in a decoded-state container."""
    if isinstance(value, np.ndarray):
        return int(value.size) * int(value.dtype.itemsize)
    if isinstance(value, dict):
        return sum(array_capacity_bytes(item) for item in value.values())
    if isinstance(value, (tuple, list)):
        return sum(array_capacity_bytes(item) for item in value)
    return 0


def state_capacity_bytes(state: object) -> int:
    """Element capacity of a keyframe-delta ``State`` without importing it here."""
    return array_capacity_bytes(state.ids) + array_capacity_bytes(state.bins)  # type: ignore[attr-defined]


def gaussian_birth_decode_working_bytes(count: int, uncompressed_size: int) -> int:
    """Conservative pre-allocation peak for one gaussian-birth Chunk.

    A row can carry every defined non-keyframe attribute as an ``int64`` decoded
    stream, the decoded float64/intermediate result, and vectorised arithmetic scratch.
    Five hundred and twelve bytes per row covers those simultaneously; the record block
    is added because chunk-level decompression may own it at the same time.  Counting the
    source-backed case too is a conservative implementation charge permitted by §3.3.
    """
    return int(count) * 512 + int(uncompressed_size)


def keyframe_decode_working_bytes(count: int, uncompressed_size: int) -> int:
    """Pre-allocation peak for decoded keyframe bins and reconstruction checks."""
    return int(count) * 400 + int(uncompressed_size)


def delta_decode_working_bytes(
    reference_count: int,
    update_count: int,
    birth_count: int,
    death_count: int,
    uncompressed_size: int,
) -> int:
    """Pre-allocation peak beside an already resident delta reference.

    A fully populated keyframe-delta row is 200 bytes (identity plus every defined bin
    lane at Python's actual ``int64`` width).  Composition can hold the new state and a
    same-sized assembly copy while all three decoded groups are still resident.
    """
    output_rows = int(reference_count) + int(birth_count)
    group_rows = int(update_count) + int(birth_count) + int(death_count)
    return output_rows * 400 + group_rows * 200 + int(uncompressed_size)


def gaussian_set_output_bytes(
    count: int,
    *,
    sh_coefficients: int,
    source_group: bool,
    source_index: bool,
    object_id: bool,
) -> int:
    """Element capacity of the ``GaussianSet`` that assembly is about to allocate."""
    # f32 position/scale/rotation/RGBA/motion/mu/sigma plus two f64 window endpoints.
    per_row = 92 + 3 * int(sh_coefficients)
    if source_group:
        per_row += 8  # decoded source groups retain their int64 stream width
    if source_index:
        per_row += 8  # decoded source indexes retain their int64 stream width
    if object_id:
        per_row += 4  # exact u32 membership
    return int(count) * per_row


def gaussian_assembly_working_bytes(count: int, output_bytes: int) -> int:
    """Final result plus the largest concatenation/index scratch used by assembly."""
    # The concatenated window index is int64 (8 bytes/row).  The widest f64
    # concatenation is rotation (4 lanes = 32 bytes/row) before its f32 narrowing.
    return int(output_bytes) + int(count) * 40
