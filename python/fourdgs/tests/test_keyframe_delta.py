# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The `keyframe-delta` wire layer and composition.

The test that earns its keep is `test_error_does_not_grow_with_depth`. Everything else
here checks that a rule is enforced; that one checks the claim the whole model rests on,
and it is the claim that would be false under the obvious alternative design.
"""

from __future__ import annotations

import numpy as np
import pytest
from fourdgs import keyframe_delta as kd
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.exceptions import MalformedFile

RNG = np.random.default_rng(20260729)


# --------------------------------------------------------------------------
# The wire
# --------------------------------------------------------------------------


def test_delta_chunk_round_trips():
    encoded = rec.encode_delta_chunk(
        1.0,
        2.0,
        level=0,
        delta_mode=rec.DELTA_MODE_CHAINED,
        reference_offset=64,
        keyframe_offset=16,
        depth=3,
        updates=b"UU",
        births=b"BBB",
        deaths=b"D",
        counts=(7, 2, 1),
    )
    head, updates, births, deaths = rec.parse_delta_chunk(encoded[9:])
    assert (head.t0, head.t1) == (1.0, 2.0)
    assert (head.reference_offset, head.keyframe_offset, head.depth) == (64, 16, 3)
    assert (head.update_count, head.birth_count, head.death_count) == (7, 2, 1)
    assert (bytes(updates), bytes(births), bytes(deaths)) == (b"UU", b"BBB", b"D")


def test_a_gaussian_birth_index_entry_is_byte_identical():
    """The appended block is written only by a `keyframe-delta` writer.

    Every committed checksum in the corpus depends on this: an entry that grew by 28
    bytes for files that do not use the model would move all 34 of them, and the change
    would look like a corpus regeneration rather than what it is.
    """
    plain = rec.ChunkIndexEntry(0.0, 1.0, chunk_offset=10, chunk_length=20, gaussian_count=5)
    assert len(plain.encode()) == 9 + 8 + 8 + 8 + 8 + 4 + 4
    assert rec.ChunkIndexEntry.parse(plain.encode()[9:]) == plain
    assert not rec.ChunkIndexEntry.parse(plain.encode()[9:]).extended


def test_an_extended_index_entry_round_trips_with_its_bands():
    entry = rec.ChunkIndexEntry(
        0.0,
        1.0,
        chunk_offset=100,
        chunk_length=20,
        gaussian_count=5,
        bands=[(1, 200, 30), (2, 230, 40)],
        extended=True,
        kind=1,
        delta_mode=1,
        reference_offset=40,
        keyframe_offset=8,
        depth=2,
        live_count=512,
    )
    assert rec.ChunkIndexEntry.parse(entry.encode()[9:]) == entry


# --------------------------------------------------------------------------
# Composition
# --------------------------------------------------------------------------


def _state(ids, positions):
    return kd.keyframe_state(np.asarray(ids), {op.A_POSITION: np.asarray(positions, dtype=np.int64)})


def _empty(n):
    return np.zeros(n, dtype=np.int64)


def _apply(state, *, updates=(None, None), births=(None, None), deaths=None):
    update_ids, update_bins = updates
    birth_ids, birth_bins = births
    return kd.apply_delta(
        state,
        update_ids=_empty(0) if update_ids is None else np.asarray(update_ids),
        update_bins=update_bins or {},
        birth_ids=_empty(0) if birth_ids is None else np.asarray(birth_ids),
        birth_bins=birth_bins or {},
        death_ids=_empty(0) if deaths is None else np.asarray(deaths),
    )


def test_an_update_moves_only_the_gaussians_it_names():
    state = _state([10, 11, 12], [[0, 0, 0], [5, 5, 5], [9, 9, 9]])
    out = _apply(state, updates=([12, 10], {op.A_POSITION: np.asarray([[1, 0, 0], [-2, 0, 0]])}))
    assert dict(zip(out.ids.tolist(), out.bins[op.A_POSITION].tolist(), strict=True)) == {
        10: [-2, 0, 0],
        11: [5, 5, 5],
        12: [10, 9, 9],
    }


def test_an_update_finds_its_gaussians_by_id_not_by_row():
    """An encoder may order a chunk however it likes, so a delta that found its gaussians
    by position would be correct only for the ordering its own encoder chose."""
    delta = ([2], {op.A_POSITION: np.asarray([[7, 0, 0]])})

    def composed(state):
        out = _apply(state, updates=delta)
        return dict(zip(out.ids.tolist(), out.bins[op.A_POSITION][:, 0].tolist(), strict=True))

    forward = _state([1, 2, 3], [[0, 0, 0], [10, 0, 0], [20, 0, 0]])
    backward = _state([3, 2, 1], [[20, 0, 0], [10, 0, 0], [0, 0, 0]])
    assert composed(forward) == composed(backward) == {1: 0, 2: 17, 3: 20}


def test_a_death_removes_the_gaussian_and_a_birth_adds_one():
    state = _state([1, 2], [[0, 0, 0], [1, 1, 1]])
    out = _apply(state, deaths=[1], births=([9], {op.A_POSITION: np.asarray([[4, 4, 4]])}))
    assert out.ids.tolist() == [2, 9]
    assert out.bins[op.A_POSITION].tolist() == [[1, 1, 1], [4, 4, 4]]


def test_error_does_not_grow_with_depth():
    """The claim the model rests on, checked against the design it rules out.

    A gaussian moves along a continuous path. The encoder quantizes the true value at
    each step and stores the DIFFERENCE OF BINS; composing them telescopes over integers,
    so the composed bin is exactly the bin an absolute statement of that instant would
    have carried, and the declared bound holds at any depth.

    The alternative — storing the quantization of the difference — is computed alongside,
    and its error grows with depth. Without that comparison this test would pass against
    a design where the bound is meaningless after composition.
    """
    step = 0.25
    bound = step / 2
    truth = np.cumsum(RNG.uniform(-0.4, 0.4, size=64)) + 3.0

    def q(x):
        return np.rint(x / step).astype(np.int64)

    state = kd.keyframe_state(np.asarray([1]), {op.A_POSITION: np.asarray([[q(truth[0]), 0, 0]])})
    naive_bin = q(truth[0])
    worst_composed = 0.0
    worst_naive = 0.0

    for depth in range(1, len(truth)):
        state = _apply(
            state,
            updates=([1], {op.A_POSITION: np.asarray([[q(truth[depth]) - q(truth[depth - 1]), 0, 0]])}),
        )
        worst_composed = max(worst_composed, abs(state.bins[op.A_POSITION][0, 0] * step - truth[depth]))

        # The design this rules out: quantize the difference, then accumulate.
        naive_bin += q(truth[depth] - truth[depth - 1])
        worst_naive = max(worst_naive, abs(naive_bin * step - truth[depth]))

    assert worst_composed <= bound + 1e-12, worst_composed
    assert worst_naive > bound * 2, "the alternative design must actually drift, or this proves nothing"


def test_a_composed_bin_outside_the_range_is_refused_not_wrapped():
    state = kd.keyframe_state(np.asarray([1]), {op.A_POSITION: np.asarray([[kd.BIN_MAX - 1, 0, 0]])})
    with pytest.raises(Exception) as caught:
        _apply(state, updates=([1], {op.A_POSITION: np.asarray([[100, 0, 0]])}))
    assert caught.value.code == "bin-overflow"
    assert "gaussian id 1" in str(caught.value)


@pytest.mark.parametrize("attribute", sorted(kd.GOP_INVARIANT))
def test_an_update_may_not_change_a_grid_deriving_attribute(attribute):
    state = _state([1], [[0, 0, 0]])
    with pytest.raises(Exception) as caught:
        _apply(state, updates=([1], {attribute: np.asarray([[1]])}))
    assert caught.value.code == "invariant-changed-in-update"


def test_rotation_in_an_update_is_absolute_not_a_difference():
    """The smallest-three basis changes when the largest component does, so the three
    stored bins mean different components either side of it. Restating outright is what
    makes the rotation bound the section-6.4 bound with no composition term at all."""
    state = kd.keyframe_state(np.asarray([1]), {op.A_ROTATION: np.asarray([[100, 200, 300]])})
    out = _apply(state, updates=([1], {op.A_ROTATION: np.asarray([[7, 8, 9]])}))
    assert out.bins[op.A_ROTATION].tolist() == [[7, 8, 9]]


@pytest.mark.parametrize(
    ("kwargs", "code"),
    [
        ({"updates": ([99], {op.A_POSITION: np.asarray([[1, 0, 0]])})}, "unknown-gaussian-id"),
        ({"deaths": [99]}, "unknown-gaussian-id"),
        ({"births": ([1], {op.A_POSITION: np.asarray([[1, 0, 0]])})}, "duplicate-gaussian-id"),
        ({"deaths": [1, 1]}, "duplicate-gaussian-id"),
        (
            {"deaths": [1], "updates": ([1], {op.A_POSITION: np.asarray([[1, 0, 0]])})},
            "id-in-two-groups",
        ),
    ],
)
def test_the_refusals_a_reader_owes(kwargs, code):
    state = _state([1, 2], [[0, 0, 0], [1, 1, 1]])
    with pytest.raises(Exception) as caught:
        _apply(state, **kwargs)
    assert caught.value.code == code


def test_a_birth_must_carry_every_attribute_the_state_has():
    state = kd.keyframe_state(
        np.asarray([1]),
        {op.A_POSITION: np.asarray([[0, 0, 0]]), op.A_OPACITY: np.asarray([[5]])},
    )
    with pytest.raises(Exception) as caught:
        _apply(state, births=([2], {op.A_POSITION: np.asarray([[1, 1, 1]])}))
    assert caught.value.code == "incomplete-birth"


# --------------------------------------------------------------------------
# Seeking
# --------------------------------------------------------------------------


def _entry(t0, t1, offset, *, kind=0, reference=0, keyframe=None, depth=0):
    return rec.ChunkIndexEntry(
        t0,
        t1,
        chunk_offset=offset,
        chunk_length=10,
        gaussian_count=1,
        extended=True,
        kind=kind,
        reference_offset=reference,
        keyframe_offset=offset if keyframe is None else keyframe,
        depth=depth,
    )


def _group():
    """A keyframe and three chained deltas."""
    return [
        _entry(0.0, 1.0, 100),
        _entry(1.0, 2.0, 200, kind=1, reference=100, keyframe=100, depth=1),
        _entry(2.0, 3.0, 300, kind=1, reference=200, keyframe=100, depth=2),
        _entry(3.0, 4.0, 400, kind=1, reference=300, keyframe=100, depth=3),
    ]


@pytest.mark.parametrize(("t", "expected"), [(0.5, [100]), (1.5, [100, 200]), (3.9, [100, 200, 300, 400])])
def test_the_chain_is_answered_from_the_index_alone(t, expected):
    assert [e.chunk_offset for e in kd.chain_for(_group(), t)] == expected


def test_a_keyframe_referenced_delta_costs_two_records_however_deep_it_sits():
    """The per-chunk mode, and the reason it is per chunk: an encoder can make one
    instant cheap to reach without spending a whole keyframe on it."""
    index = _group()
    index[3] = _entry(3.0, 4.0, 400, kind=1, reference=100, keyframe=100, depth=1)
    assert [e.chunk_offset for e in kd.chain_for(index, 3.5)] == [100, 400]


def test_a_gap_or_an_overlap_in_the_tiling_is_refused():
    for index in ([_entry(0.0, 1.0, 100), _entry(1.5, 2.0, 200)], [_entry(0.0, 1.6, 100), _entry(1.5, 2.0, 200)]):
        with pytest.raises(Exception) as caught:
            kd.check_tiling(index)
        assert caught.value.code == "non-tiling-chunks"


def test_a_forward_reference_is_refused():
    index = [_entry(0.0, 1.0, 100), _entry(1.0, 2.0, 200, kind=1, reference=300, keyframe=100, depth=1)]
    with pytest.raises(Exception) as caught:
        kd.chain_for(index, 1.5)
    assert caught.value.code == "forward-reference"


def test_a_depth_that_disagrees_with_the_chain_is_refused():
    index = _group()
    index[2] = _entry(2.0, 3.0, 300, kind=1, reference=200, keyframe=100, depth=9)
    with pytest.raises(Exception) as caught:
        kd.chain_for(index, 2.5)
    assert caught.value.code == "depth-mismatch"
    assert "cost of this seek" in str(caught.value)


def test_each_gaussian_gets_the_window_its_index_names():
    """The velocity grid comes from the gaussian's own window, not the table's first entry.

    `window_index` is a required keyframe attribute and GOP-invariant (spec §11.5), so a
    keyframe-delta sequence may legitimately carry several windows. Deriving every
    gaussian's motion precision from `windows[0]` gave everyone outside window 0 the
    wrong grid, and their reconstructed positions drifted from the bins the encoder
    wrote — silently, in three SDKs at once.
    """
    from fourdgs.keyframe_delta_file import Grids
    from fourdgs.quantization import Bounds, Steps

    steps = Steps.of(Bounds.for_profile("default", median_scale=1e-2))
    grids = Grids(
        steps=steps,
        bounds=None,
        origin=np.zeros(3),
        windows=[(0.0, 10.0), (0.0, 0.5)],
        cutoff=0.05,
    )

    # Two never-fading gaussians: for those, window length alone sets the velocity class.
    sigma_bins = np.zeros(2, dtype=np.int64)
    never_fades = np.ones(2, dtype=bool)

    both_in_window_0 = grids.motion_step(sigma_bins, never_fades, np.array([0, 0]))
    assert both_in_window_0[0] == both_in_window_0[1]

    one_each = grids.motion_step(sigma_bins, never_fades, np.array([0, 1]))
    assert one_each[0] != one_each[1], "a 10s window and a 0.5s window cannot share a grid"
    assert one_each[0] == both_in_window_0[0], "window 0 is unchanged"

    # An index the table cannot answer is a malformed file, not a silent clamp.
    with pytest.raises(MalformedFile):
        grids.motion_step(sigma_bins, never_fades, np.array([0, 7]))

    # And an absent table is one default (0, 0) window, not an unbounded fallback:
    # index 0 is legal there, anything else is not.
    empty = Grids(steps=steps, bounds=None, origin=np.zeros(3), windows=[], cutoff=0.05)
    empty.motion_step(sigma_bins, never_fades, np.zeros(2, dtype=np.int64))
    with pytest.raises(MalformedFile):
        empty.motion_step(sigma_bins, never_fades, np.array([0, 7]))


def test_a_state_without_window_index_is_refused_not_a_keyerror():
    """`window_index` is a required keyframe attribute (§11.5), so a state missing it is
    a malformed file — not a KeyError raised from inside the renderer.

    It is reachable: a zero-count keyframe may omit every stream, and `apply_delta`
    carries forward only attributes the reference already had, so a later birth can
    compose a non-empty state with no window_index column at all.
    """
    from fourdgs.keyframe_delta_file import Grids, _dequantize
    from fourdgs.quantization import Bounds, Steps

    grids = Grids(
        steps=Steps.of(Bounds.for_profile("default", median_scale=1e-2)),
        bounds=None,
        origin=np.zeros(3),
        windows=[(0.0, 8.0)],
        cutoff=0.05,
    )

    class _State:
        def __init__(self):
            self.ids = np.array([0])
            self.bins = {
                op.A_POSITION: np.zeros((1, 3), dtype=np.int64),
                op.A_SIGMA_T: np.zeros((1, 1), dtype=np.int64),
                op.A_FLAGS: np.zeros((1, 1), dtype=np.int64),
            }

        def count(self):
            return 1

    with pytest.raises(MalformedFile) as caught:
        _dequantize(_State(), grids)
    assert caught.value.code == "missing-window-index"
