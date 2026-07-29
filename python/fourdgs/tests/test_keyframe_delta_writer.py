# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Splitting a sample against its reference, and composing it back.

These tests run the encoder's group-splitting against the decoder's composition and
require the round trip to be exact in the bin domain. That pairing is the point: either
half alone can be self-consistently wrong, and the corpus cannot see it until a file
exists.
"""

from __future__ import annotations

import numpy as np
import pytest
from fourdgs import keyframe_delta as kd
from fourdgs import keyframe_delta_writer as kdw
from fourdgs import opcode as op

RNG = np.random.default_rng(20260729)


def _bins(n, *, seed_offset=0, sigma=3, window=1):
    """A population's bins, with the grid-deriving attributes held constant."""
    rng = np.random.default_rng(20260729 + seed_offset)
    return {
        op.A_POSITION: rng.integers(-500, 500, size=(n, 3)),
        op.A_OPACITY: rng.integers(0, 255, size=(n, 1)),
        op.A_ROTATION: rng.integers(-100, 100, size=(n, 3)),
        op.A_ROTATION_INDEX: rng.integers(0, 4, size=(n, 1)),
        op.A_SIGMA_T: np.full((n, 1), sigma),
        op.A_FLAGS: np.zeros((n, 1), dtype=np.int64),
        op.A_WINDOW_INDEX: np.full((n, 1), window),
    }


def _compose(reference_ids, reference_bins, groups):
    update_ids, update_bins, birth_ids, birth_bins, death_ids = groups
    state = kd.keyframe_state(reference_ids, reference_bins)
    return kd.apply_delta(
        state,
        update_ids=update_ids,
        update_bins=update_bins,
        birth_ids=birth_ids,
        birth_bins=birth_bins,
        death_ids=death_ids,
    )


def _as_map(state):
    return {int(i): {a: v[r].tolist() for a, v in state.bins.items()} for r, i in enumerate(state.ids.tolist())}


def test_a_split_composes_back_to_the_sample_it_came_from():
    """The round trip, on a sample that moves, gains and loses gaussians at once."""
    ids_a = np.arange(40)
    bins_a = _bins(40)

    ids_b = np.concatenate([np.arange(5, 40), np.arange(100, 106)])  # 0-4 die, 100-105 born
    bins_b = _bins(len(ids_b), seed_offset=1)
    # Carry the invariants across for the survivors, as a real encoder's input would.
    keep = np.isin(ids_a, ids_b)
    for attribute in sorted(kd.GOP_INVARIANT):
        bins_b[attribute][: keep.sum()] = bins_a[attribute][keep]

    groups = kdw.delta_groups(ids_a, bins_a, ids_b, bins_b)
    composed = _compose(ids_a, bins_a, groups)

    expected = {int(i): {a: v[r].tolist() for a, v in bins_b.items()} for r, i in enumerate(ids_b.tolist())}
    assert _as_map(composed) == expected


def test_an_unchanged_gaussian_costs_nothing():
    """Untouched means no bytes — the property the model exists to buy."""
    ids = np.arange(10)
    bins = _bins(10)
    moved = {a: v.copy() for a, v in bins.items()}
    moved[op.A_POSITION][3] += [1, 0, 0]

    update_ids, update_bins, birth_ids, _birth_bins, death_ids = kdw.delta_groups(ids, bins, ids, moved)
    assert update_ids.tolist() == [3]
    assert birth_ids.size == 0 and death_ids.size == 0
    assert update_bins[op.A_POSITION].tolist() == [[1, 0, 0]]


def test_an_identical_sample_produces_an_empty_delta():
    ids = np.arange(10)
    bins = _bins(10)
    update_ids, _, birth_ids, _, death_ids = kdw.delta_groups(ids, bins, ids, {a: v.copy() for a, v in bins.items()})
    assert update_ids.size == 0 and birth_ids.size == 0 and death_ids.size == 0


def test_rotation_is_carried_absolutely_not_differenced():
    ids = np.arange(4)
    bins = _bins(4)
    turned = {a: v.copy() for a, v in bins.items()}
    turned[op.A_ROTATION][1] = [7, 8, 9]
    turned[op.A_ROTATION_INDEX][1] = [(int(bins[op.A_ROTATION_INDEX][1][0]) + 1) % 4]

    update_ids, update_bins, *_ = kdw.delta_groups(ids, bins, ids, turned)
    assert update_ids.tolist() == [1]
    assert update_bins[op.A_ROTATION].tolist() == [[7, 8, 9]], "a rotation update restates, it does not add"


def test_changing_a_grid_deriving_attribute_is_refused_by_the_encoder():
    """The encoder catches it, because the decoder cannot.

    A velocity bin differenced across a sigma change subtracts bins on two different
    grids. That is not an approximation — it decodes into a wrong velocity with nothing
    anywhere to notice, which is why this has to fail at encode time.
    """
    ids = np.arange(4)
    bins = _bins(4)
    widened = {a: v.copy() for a, v in bins.items()}
    widened[op.A_SIGMA_T][2] = [9]

    with pytest.raises(Exception) as caught:
        kdw.delta_groups(ids, bins, ids, widened)
    assert caught.value.code == "invariant-changed-in-update"
    assert "gaussian id 2" in str(caught.value)
    assert "keyframe" in str(caught.value), "the message must say what the caller can do instead"


def test_a_chain_of_samples_composes_without_drift():
    """Twelve samples deep, composing each delta onto the last.

    This is the encoder's half of the claim the decoder's own tests make: the composed
    bins at depth 11 equal the bins the encoder would have written for that sample
    outright. Exactly — these are integers, and that is the whole argument.
    """
    ids = np.arange(30)
    samples = []
    bins = _bins(30)
    for step in range(12):
        moved = {a: v.copy() for a, v in bins.items()}
        moved[op.A_POSITION] = bins[op.A_POSITION] + RNG.integers(-3, 4, size=(30, 3)) * (step > 0)
        samples.append(moved)
        bins = moved

    # The running state a decoder holds. Each delta is computed by the encoder against the
    # previous SAMPLE and applied by the decoder to the ACCUMULATED state — if those two
    # ever diverged, this is where it would show.
    state = kd.keyframe_state(ids, samples[0])
    for depth in range(1, len(samples)):
        update_ids, update_bins, birth_ids, birth_bins, death_ids = kdw.delta_groups(
            ids, samples[depth - 1], ids, samples[depth]
        )
        state = kd.apply_delta(
            state,
            update_ids=update_ids,
            update_bins=update_bins,
            birth_ids=birth_ids,
            birth_bins=birth_bins,
            death_ids=death_ids,
        )
        assert state.bins[op.A_POSITION].tolist() == samples[depth][op.A_POSITION].tolist(), (
            f"composed state diverged from the sample at depth {depth}"
        )


@pytest.mark.parametrize(
    ("index", "every", "at", "expected"),
    [(0, 8, (), True), (4, 8, (), False), (8, 8, (), True), (5, 8, (5,), True), (3, 1, (), True)],
)
def test_cadence_picks_the_keyframes(index, every, at, expected):
    options = kdw.KeyframeDeltaOptions(keyframe_every=every, keyframe_at=at)
    assert kdw.is_keyframe(index, options) is expected
