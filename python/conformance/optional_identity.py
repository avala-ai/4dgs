# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Canonical projection for the optional-identity conformance witnesses."""

from __future__ import annotations

import numpy as np
from fourdgs import opcode as op

MARKER_KEY = "conformance"
MARKER_VALUE = "optional-identity-zero-defaults-v1"


def is_witness(header) -> bool:
    """Whether ``header`` opts into the narrow optional-identity projection."""
    return header.attributes.get(MARKER_KEY) == MARKER_VALUE


def _signed_column(values, count: int) -> np.ndarray:
    return np.zeros(count, dtype=np.int64) if values is None else np.asarray(values, dtype=np.int64).reshape(-1)


def gaussian_birth_rows(gaussians) -> dict:
    """Logical identity rows from a gaussian-birth population, ordered by position."""
    count = gaussians.count
    order = np.lexsort(
        (
            np.asarray(gaussians.positions[:, 2]),
            np.asarray(gaussians.positions[:, 1]),
            np.asarray(gaussians.positions[:, 0]),
        )
    )

    def unsigned(values) -> np.ndarray:
        return np.zeros(count, dtype=np.uint32) if values is None else np.asarray(values, dtype=np.uint32).reshape(-1)

    source_group = _signed_column(gaussians.source_group, count)
    source_index = _signed_column(gaussians.source_index, count)
    object_id = unsigned(gaussians.object_id)
    return {
        "temporalModel": "gaussian-birth",
        "identityRows": [
            {
                "sourceGroup": str(int(source_group[row])),
                "sourceIndex": str(int(source_index[row])),
                "objectId": str(int(object_id[row])),
                "position": [float(value) for value in gaussians.positions[row]],
            }
            for row in order
        ],
    }


def keyframe_delta_states(decoded) -> dict:
    """Logical identity columns at every state record, ordered by gaussian id."""
    states = []
    for chunk in decoded.chunks:
        state = chunk.state
        order = np.argsort(state.ids, kind="stable")

        object_codes = _signed_column(state.bins.get(op.A_OBJECT_ID), state.count)
        object_ids = object_codes.astype(np.int32).view(np.uint32)
        source_groups = _signed_column(state.bins.get(op.A_SOURCE_GROUP), state.count)
        source_indexes = _signed_column(state.bins.get(op.A_SOURCE_INDEX), state.count)
        states.append(
            {
                "t": float(chunk.t0),
                "rows": [
                    {
                        "sourceGroup": str(int(source_groups[row])),
                        "sourceIndex": str(int(source_indexes[row])),
                        "objectId": str(int(object_ids[row])),
                        "gaussianId": str(int(state.ids[row])),
                    }
                    for row in order
                ],
            }
        )
    return {"temporalModel": "keyframe-delta", "identityStates": states}
