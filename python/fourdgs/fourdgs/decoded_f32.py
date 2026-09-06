# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The finite-binary32 boundary for reconstructed gaussian attributes.

Attribute streams carry integer bins and the Quantization record carries binary64 grids,
so reconstruction deliberately happens in binary64.  The decoded gaussian state is
binary32, however, and spec section 3.2 requires a refusal before a wider intermediate
would narrow to infinity.  This module owns that boundary and its diagnostic; the two
temporal-model readers supply the record and bin provenance they alone still know.
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np

from .exceptions import MalformedFile

F32_MAX = float(np.finfo(np.float32).max)


def check_decoded_f32(
    values,
    *,
    record: str,
    record_offset: int,
    row_kind: str,
    gaussian_ids: np.ndarray | None,
    attribute: str,
    components: tuple[str, ...],
    detail: Callable[[int, int], str],
    permitted_positive_infinity: np.ndarray | None = None,
) -> None:
    """Refuse the first reconstructed lane outside the finite binary32 range.

    ``detail`` is evaluated only on failure.  Keeping the raw/composed-bin wording at the
    call site avoids retaining provenance beside every composed gaussian merely so that a
    valid file can discard it later.
    """
    array = np.asarray(values, dtype=np.float64)
    if array.ndim == 1:
        array = array[:, None]
    if array.ndim != 2 or array.shape[1] != len(components):
        raise ValueError(f"{attribute} validation received shape {array.shape}, expected (*, {len(components)})")

    bad = ~np.isfinite(array) | (array < -F32_MAX) | (array > F32_MAX)
    if permitted_positive_infinity is not None:
        permitted = np.asarray(permitted_positive_infinity, dtype=bool).reshape(-1, 1)
        if permitted.shape[0] != array.shape[0]:
            raise ValueError(f"{attribute} infinity mask has {permitted.shape[0]} rows, expected {array.shape[0]}")
        bad &= ~(permitted & np.isposinf(array))
    if not bad.any():
        return

    # `argwhere` would allocate one pair for every bad lane.  A malformed chunk can make
    # all of them bad, while the diagnostic needs only the first in wire-row order.
    row, component = divmod(int(np.argmax(bad)), bad.shape[1])
    identity = ""
    if gaussian_ids is not None:
        ids = np.asarray(gaussian_ids).reshape(-1)
        identity = f" (gaussian_id {int(ids[row])})"
    value = float(array[row, component])
    raise MalformedFile(
        f"the {record} record opcode at byte {record_offset}, {row_kind} row {row}{identity}, "
        f"reconstructs attribute {attribute} component {components[component]} {detail(row, component)} "
        f"as {value!r}; expected a finite binary32 value in [-{F32_MAX!r}, {F32_MAX!r}]",
        code="decoded-f32-overflow",
    )
