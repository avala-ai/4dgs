# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The whole-file keyframe-delta reference: write a sequence, decode it two ways, agree.

These tests own the end-to-end path the composition and wire tests do not: a real file
with a Header, keyframe Chunks, Delta Chunks and an extended Chunk Index, decoded front to
back and by index. The load-bearing assertion is that the two read paths produce the same
canonical `states` — the reconstruction at an instant — because that is the statement the
other SDKs are diffed against.
"""

from __future__ import annotations

import fourdgs
import numpy as np
import pytest
from fourdgs import keyframe_delta_file as kdf
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.keyframe_delta_writer import KeyframeDeltaOptions, Sample


def _gaussians(positions, motions=None, colors=None, win_hi=8.0):
    n = len(positions)
    positions = np.asarray(positions, dtype=np.float32).reshape(n, 3)
    return fourdgs.GaussianSet(
        positions=positions,
        scales=np.full((n, 3), 0.05, dtype=np.float32),
        rotations=np.tile(np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=(
            np.asarray(colors, dtype=np.float32).reshape(n, 4)
            if colors is not None
            else np.tile(np.array([0.6, 0.4, 0.2, 0.9], dtype=np.float32), (n, 1))
        ),
        motions=(
            np.asarray(motions, dtype=np.float32).reshape(n, 3)
            if motions is not None
            else np.zeros((n, 3), dtype=np.float32)
        ),
        mu_t=np.zeros(n, dtype=np.float32),
        sigma_t=np.full(n, 100.0, dtype=np.float32),  # finite, effectively non-fading over the clip
        win_lo=np.zeros(n, dtype=np.float32),
        win_hi=np.full(n, win_hi, dtype=np.float32),
    )


def _moving_sequence(steps=8, duration=8.0):
    """A population that drifts, with one birth and one death partway through."""
    samples = []
    for i in range(steps):
        ids = [0, 1, 2, 3]
        base = [[float(i) * 0.1, 0.0, 0.0], [1.0, float(i) * 0.05, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]]
        if i >= 2:  # a birth
            ids = [*ids, 4]
            base = [*base, [2.0, 2.0, float(i) * 0.02]]
        if i >= 5 and 2 in ids:  # a death of id 2
            keep = [k for k in range(len(ids)) if ids[k] != 2]
            ids = [ids[k] for k in keep]
            base = [base[k] for k in keep]
        samples.append(Sample(t0=float(i) * (duration / steps), ids=np.array(ids), gaussians=_gaussians(base)))
    return samples, duration


@pytest.mark.parametrize("mode", [rec.DELTA_MODE_CHAINED, rec.DELTA_MODE_KEYFRAME])
def test_streamed_and_indexed_agree(mode):
    samples, duration = _moving_sequence()
    data = write_ok(samples, duration, mode)
    streamed = kdf.states_json(kdf.decode_streamed(data))
    decoded_indexed, _index = kdf.decode_indexed(data)
    indexed = kdf.states_json(decoded_indexed)
    assert streamed == indexed


def test_header_declares_the_model_and_distinct_id_count():
    samples, duration = _moving_sequence()
    decoded = kdf.decode_streamed(write_ok(samples, duration, rec.DELTA_MODE_CHAINED))
    assert decoded.header.temporal_model == "keyframe-delta"
    # ids seen across the whole clip: 0,1,2,3,4.
    assert decoded.header.gaussian_count == 5


def test_a_keyframe_only_file_is_the_frame_sequence_shape():
    samples, duration = _moving_sequence(steps=4)
    data = write_ok(samples, duration, rec.DELTA_MODE_CHAINED, keyframe_every=1)
    decoded = kdf.decode_streamed(data)
    assert all(c.kind == 0 for c in decoded.chunks)  # every chunk a keyframe, no deltas
    summary = kdf.states_json(decoded)
    assert all(row["kind"] == "keyframe" for row in summary["chunks"])


def test_each_keyframe_states_mu_t_at_its_chunk_start():
    samples, duration = _moving_sequence(steps=4)
    decoded = kdf.decode_streamed(write_ok(samples, duration, rec.DELTA_MODE_CHAINED, keyframe_every=2))
    keyframes = [chunk for chunk in decoded.chunks if chunk.kind == 0]
    assert [chunk.t0 for chunk in keyframes] == [0.0, 4.0]
    for chunk in keyframes:
        sigma = chunk.state.bins[op.A_SIGMA_T].reshape(-1)
        never_fades = (chunk.state.bins[op.A_FLAGS].reshape(-1) & op.FLAG_NEVER_FADES) != 0
        expected = np.rint(chunk.t0 / decoded.grids.mu_step(sigma, never_fades)).astype(np.int64)
        assert chunk.state.bins[op.A_MU_T].reshape(-1).tolist() == expected.tolist()


@pytest.mark.parametrize("mode", [rec.DELTA_MODE_CHAINED, rec.DELTA_MODE_KEYFRAME])
def test_a_delta_subtracts_from_the_serialized_keyframe_birth_time(mode):
    samples, duration = _moving_sequence(steps=4)
    for sample in samples:
        sample.gaussians.motions[:, 0] = 0.25

    decoded = kdf.decode_streamed(write_ok(samples, duration, mode, keyframe_every=2))
    later_keyframe = decoded.chunks[2]
    following_delta = decoded.chunks[3]
    assert later_keyframe.t0 == 4.0
    assert following_delta.reference_offset == later_keyframe.offset

    # The input authors mu_t=0 for every sample.  The keyframe correctly writes
    # t0=4, and the following delta must calculate against that serialized bin while
    # stating every updated gaussian at the delta's own t0=6.
    assert np.all(later_keyframe.state.bins[op.A_MU_T] != 0)
    sigma = following_delta.state.bins[op.A_SIGMA_T].reshape(-1)
    never_fades = (following_delta.state.bins[op.A_FLAGS].reshape(-1) & op.FLAG_NEVER_FADES) != 0
    expected = np.rint(following_delta.t0 / decoded.grids.mu_step(sigma, never_fades)).astype(np.int64)
    actual_by_id = dict(
        zip(
            following_delta.state.ids.tolist(),
            following_delta.state.bins[op.A_MU_T].reshape(-1).tolist(),
            strict=True,
        )
    )
    expected_by_id = dict(zip(following_delta.state.ids.tolist(), expected.tolist(), strict=True))
    assert all(actual_by_id[gaussian_id] == expected_by_id[gaussian_id] for gaussian_id in [0, 1, 4])
    keyframe_by_id = dict(
        zip(
            later_keyframe.state.ids.tolist(),
            later_keyframe.state.bins[op.A_MU_T].reshape(-1).tolist(),
            strict=True,
        )
    )
    assert all(actual_by_id[gaussian_id] == keyframe_by_id[gaussian_id] for gaussian_id in [2, 3])


@pytest.mark.parametrize("mode", [rec.DELTA_MODE_CHAINED, rec.DELTA_MODE_KEYFRAME])
def test_a_delta_reanchors_only_the_gaussians_it_updates(mode):
    samples, duration = _moving_sequence(steps=2, duration=2.0)
    samples[1].gaussians.positions[:] = samples[0].gaussians.positions
    samples[1].gaussians.positions[0, 0] += 0.25

    decoded = kdf.decode_streamed(write_ok(samples, duration, mode, keyframe_every=2))
    keyframe, delta = decoded.chunks
    assert delta.update_count == 1

    keyframe_mu = dict(
        zip(keyframe.state.ids.tolist(), keyframe.state.bins[op.A_MU_T].reshape(-1).tolist(), strict=True)
    )
    delta_mu = dict(zip(delta.state.ids.tolist(), delta.state.bins[op.A_MU_T].reshape(-1).tolist(), strict=True))
    assert delta_mu[0] != keyframe_mu[0]
    assert all(delta_mu[gaussian_id] == keyframe_mu[gaussian_id] for gaussian_id in [1, 2, 3])


def test_reanchoring_mu_t_preserves_a_later_keyframes_moving_centres():
    samples, duration = _moving_sequence(steps=2, duration=4.0)
    samples[1].gaussians.positions[:] = 0.0
    samples[1].gaussians.motions[:] = [1.0, 0.0, 0.0]
    samples[1].gaussians.mu_t[:] = 0.0

    decoded = kdf.decode_streamed(
        write_ok(samples, duration, rec.DELTA_MODE_CHAINED, keyframe_every=1)
    )
    later = decoded.chunks[1]
    state = kdf.reconstruct_at(later.state, decoded.grids, later.t0)
    np.testing.assert_allclose(state["centers"][:, 0], 2.0, atol=decoded.grids.steps.pos)


@pytest.mark.parametrize("mode", [rec.DELTA_MODE_CHAINED, rec.DELTA_MODE_KEYFRAME])
def test_delta_updates_and_births_reanchor_position_with_mu_t(mode):
    samples, duration = _moving_sequence(steps=3, duration=6.0)
    target = samples[2]
    target.gaussians.positions[:] = 10.0
    target.gaussians.motions[:] = [1.0, 0.0, 0.0]
    target.gaussians.mu_t[:] = 0.0

    # ID 4 is born in the third sample; the other rows are updates. Both groups
    # must preserve the centre authored by the old anchor when restated at t0=4.
    decoded = kdf.decode_streamed(
        write_ok(samples, duration, mode, keyframe_every=3)
    )
    delta = decoded.chunks[2]
    state = kdf.reconstruct_at(delta.state, decoded.grids, delta.t0)
    np.testing.assert_allclose(state["centers"][:, 0], 14.0, atol=decoded.grids.steps.pos)


def test_composition_reconstructs_each_source_sample():
    """At each sample's t0, the composed population equals the sample the encoder was given."""
    samples, duration = _moving_sequence()
    decoded = kdf.decode_streamed(write_ok(samples, duration, rec.DELTA_MODE_CHAINED))
    for sample, chunk in zip(samples, decoded.chunks, strict=True):
        assert set(int(v) for v in chunk.state.ids) == set(int(v) for v in np.asarray(sample.ids))


def test_births_and_deaths_move_the_population():
    samples, duration = _moving_sequence()
    summary = kdf.states_json(kdf.decode_streamed(write_ok(samples, duration, rec.DELTA_MODE_CHAINED)))
    live = [int(row["liveCount"]) for row in summary["chunks"]]
    assert max(live) == 5 and min(live) == 4  # birth of id 4, death of id 2


def test_probe_states_are_derived_from_the_file():
    samples, duration = _moving_sequence()
    summary = kdf.states_json(kdf.decode_streamed(write_ok(samples, duration, rec.DELTA_MODE_CHAINED)))
    # Every chunk contributes its t0 and midpoint, plus one instant near the end.
    assert len(summary["states"]) >= len(summary["chunks"])
    assert all(row["sample"]["positions"] or row["liveCount"] == "0" for row in summary["states"])


def test_error_does_not_grow_with_depth():
    """A long chain of small drifts reconstructs the last sample within the declared bound.

    The composed bin at depth d IS the bin an absolute statement of that instant would
    carry, so the reconstruction error is the one-shot quantization error, not d times it.
    """
    steps = 16
    duration = 16.0
    samples = []
    for i in range(steps):
        # A single gaussian creeping along x by one position-step's worth each frame.
        samples.append(
            Sample(
                t0=float(i),
                ids=np.array([0]),
                gaussians=_gaussians([[0.001 * i, 0.0, 0.0]], win_hi=duration),
            )
        )
    data = write_ok(samples, duration, rec.DELTA_MODE_CHAINED, keyframe_every=steps)  # one keyframe, then deltas
    decoded = kdf.decode_streamed(data)
    assert decoded.chunks[-1].depth == steps - 1  # a genuinely deep chain
    r = kdf.reconstruct_at(decoded.chunks[-1].state, decoded.grids, float(steps - 1))
    # The decoded x is within one grid pitch of the true value at the deepest frame — the
    # one-shot quantization error, independent of the chain's depth.
    true_x = 0.001 * (steps - 1)
    assert abs(float(r["centers"][0][0]) - true_x) <= decoded.quantization.step_pos


def write_ok(samples, duration, mode, keyframe_every=4):
    return kdf.write_sequence(
        samples, duration, kd=KeyframeDeltaOptions(keyframe_every=keyframe_every, delta_mode=mode)
    )


def _two_window_gaussians(positions, window_of):
    """A population whose gaussians sit in different validity windows."""
    n = len(positions)
    lo = np.asarray([window_of(i)[0] for i in range(n)], dtype=np.float32)
    hi = np.asarray([window_of(i)[1] for i in range(n)], dtype=np.float32)
    g = _gaussians(positions)
    return fourdgs.GaussianSet(
        positions=g.positions,
        scales=g.scales,
        rotations=g.rotations,
        colors=g.colors,
        motions=g.motions,
        mu_t=g.mu_t,
        sigma_t=g.sigma_t,
        win_lo=lo,
        win_hi=hi,
    )


def test_a_multi_window_sequence_round_trips_each_gaussians_own_window():
    """The writer emits every window the population declares, and the reader honours them.

    Before issue #87 neither half of this was true: the writer forced one full-duration
    window and wrote `window_index = 0` for everyone, so no producer here could even
    express the file the readers were supposed to handle — which is why the readers'
    collapse to `windows[0]` went unnoticed in three SDKs at once.
    """
    duration = 8.0

    # Two gaussians in a long window, two in a short one.
    def window_of(i):
        return (0.0, duration) if i < 2 else (0.0, 0.5)

    samples = [
        Sample(
            t0=float(i),
            ids=np.array([0, 1, 2, 3]),
            gaussians=_two_window_gaussians(
                [[float(i) * 0.1, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]],
                window_of,
            ),
        )
        for i in range(4)
    ]
    blob = write_ok(samples, duration, rec.DELTA_MODE_CHAINED, keyframe_every=2)

    seq = kdf.decode_streamed(blob)
    assert [(w[0], w[1]) for w in seq.windows] == [(0.0, duration), (0.0, 0.5)], (
        "both windows must survive the round trip, in table order"
    )

    # A gaussian is absent outside its own window: the short-window rows carry no
    # opacity once t passes 0.5s, while the full-duration rows still do. Before this,
    # a closed window bled its gaussians through at full opacity for the whole clip.
    late = kdf.render_at(seq, 2.0)
    # Absent, not merely transparent: the rows whose window closed at 0.5s are gone from
    # ids and centres too, which is how the gaussian-birth path reports them.
    assert sorted(int(i) for i in late["ids"]) == [0, 1], "only the full-duration rows exist at t=2"
    assert len(late["centers"]) == 2
    assert all(o > 0.0 for o in late["opacity"]), "and the ones that remain are visible"

    # The canonical summary has to agree with what reconstruction returned: reporting the
    # chunk's population here would claim gaussians are live that the same summary omits.
    summary = kdf.states_json(seq)
    at_two = next(st for st in summary["states"] if abs(float(st["t"]) - 2.0) < 1e-9)
    assert at_two["liveCount"] == "2", "liveCount counts the rows that exist at t, not the chunk's"

    # And the decoder must give the two populations different velocity grids.
    grids = seq.grids
    sigma_bins = np.zeros(2, dtype=np.int64)
    never_fades = np.ones(2, dtype=bool)
    steps = grids.motion_step(sigma_bins, never_fades, np.array([0, 1]))
    assert steps[0] != steps[1], "a full-duration window and a 0.5s window cannot share a grid"
