# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The object layer: the two records round-trip, and a track composes onto base state.

The test that earns its keep is `test_track_composes_onto_base_center`. Everything else
checks that a rule is enforced or a record survives a round trip; that one checks the claim
the layer rests on — that a track transforms the base state rather than replacing it, so a
gaussian's own motion and the object's rigid motion compose.
"""

from __future__ import annotations

import io
import math

import fourdgs
import numpy as np
import pytest
from fourdgs import records as rec
from fourdgs.exceptions import MalformedFile
from fourdgs.indexed_reader import open_indexed, read_objects
from fourdgs.object_layer import ObjectLayer
from fourdgs.readable import BytesReadable

RNG = np.random.default_rng(20260729)

# xyzw quaternion for a +90 degree rotation about z: (x,y) -> (y,-x)... using R*p with the
# standard active rotation, (1,0,0) -> (0,1,0).
Q_Z90 = [0.0, 0.0, math.sin(math.pi / 4), math.cos(math.pi / 4)]
Q_IDENTITY = [0.0, 0.0, 0.0, 1.0]


# --------------------------------------------------------------------------
# The wire
# --------------------------------------------------------------------------


def test_object_table_round_trips_with_and_without_optional_fields():
    table = rec.ObjectTable(
        embedding_dim=4,
        entries=[
            rec.ObjectTableEntry(
                object_id=7,
                label="vehicle",
                anchor=(1.5, 0.0, -3.25),
                dynamics=([1.0, 0.0, 0.0], [0.0, 0.0, 0.5], [0.0, 0.0, 0.0]),
                embedding=[0.1, 0.2, 0.3, 0.4],
            ),
            rec.ObjectTableEntry(object_id=8, label="", anchor=(0.0, 0.0, 0.0)),
        ],
    )
    parsed = rec.ObjectTable.parse(_content(table.encode()))
    assert parsed.embedding_dim == 4
    assert [e.object_id for e in parsed.entries] == [7, 8]
    assert parsed.entries[0].label == "vehicle"
    assert parsed.entries[0].anchor == pytest.approx((1.5, 0.0, -3.25))
    assert parsed.entries[0].dynamics is not None
    assert parsed.entries[0].embedding == pytest.approx([0.1, 0.2, 0.3, 0.4])
    # Object 8 carried neither dynamics nor an embedding, and reads back that way.
    assert parsed.entries[1].dynamics is None
    assert parsed.entries[1].embedding is None


def test_object_table_no_embedding_space_omits_the_flag():
    table = rec.ObjectTable(embedding_dim=0, entries=[rec.ObjectTableEntry(object_id=3, label="x")])
    parsed = rec.ObjectTable.parse(_content(table.encode()))
    assert parsed.embedding_dim == 0
    assert parsed.entries[0].embedding is None


def test_object_track_round_trips():
    track = rec.ObjectTrack(
        object_id=7,
        interpolation=rec.TRAJECTORY_LINEAR,
        times=[0.0, 1.0, 2.0],
        rotations=[Q_IDENTITY, Q_IDENTITY, Q_Z90],
        translations=[[0.0, 0.0, 0.0], [5.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
    )
    parsed = rec.ObjectTrack.parse(_content(track.encode()))
    assert parsed.object_id == 7
    assert parsed.sample_count == 3
    assert parsed.translations[1] == pytest.approx([5.0, 0.0, 0.0])


# --------------------------------------------------------------------------
# Composition — the load-bearing rule
# --------------------------------------------------------------------------


def test_track_composes_onto_base_center():
    """`center(t) = R*c0 + T`, applied to the base center a gaussian already reached.

    The base center here is not the stored position but position + motion*(t - mu_t): the
    per-gaussian motion has already moved the gaussian inside the object's frame, and the
    track then transports it. That is the compose, base first, that the design turns on.
    """
    # A tracked object (id 7) of two gaussians, and one background gaussian (id 0).
    base_centers = np.array([[1.0, 0.0, 0.0], [2.0, 0.0, 0.0], [-5.0, -5.0, -5.0]])
    base_orient = np.array([Q_IDENTITY, Q_IDENTITY, Q_IDENTITY])
    object_ids = np.array([7, 7, 0])

    # Rotate object 7 by +90 about z and translate by (10, 0, 0) at every instant.
    layer = ObjectLayer(
        tracks=[
            rec.ObjectTrack(
                object_id=7,
                times=[0.0, 1.0],
                rotations=[Q_Z90, Q_Z90],
                translations=[[10.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
            )
        ]
    )
    centers, orient = layer.apply(centers=base_centers, orientations=base_orient, object_ids=object_ids, t=0.5)

    # (1,0,0) rotated +90 about z is (0,1,0), then +T -> (10,1,0); likewise (2,0,0)->(10,2,0).
    assert centers[0] == pytest.approx([10.0, 1.0, 0.0])
    assert centers[1] == pytest.approx([10.0, 2.0, 0.0])
    # Background is never touched.
    assert centers[2] == pytest.approx([-5.0, -5.0, -5.0])
    assert orient[2] == pytest.approx(Q_IDENTITY)
    # The tracked gaussians' orientation is the track rotation composed onto identity.
    assert orient[0] == pytest.approx(Q_Z90)


def test_no_track_is_identity():
    centers = np.array([[1.0, 2.0, 3.0]])
    orient = np.array([Q_Z90])
    out_c, out_r = ObjectLayer().apply(centers=centers, orientations=orient, object_ids=np.array([7]), t=0.0)
    assert out_c == pytest.approx(centers)
    assert out_r == pytest.approx(orient)


def test_track_clamps_outside_sample_range():
    layer = ObjectLayer(
        tracks=[
            rec.ObjectTrack(
                object_id=7,
                times=[1.0, 2.0],
                rotations=[Q_IDENTITY, Q_IDENTITY],
                translations=[[3.0, 0.0, 0.0], [9.0, 0.0, 0.0]],
            )
        ]
    )
    # Before the first sample the pose is clamped to the first, never extrapolated.
    centers, _ = layer.apply(
        centers=np.array([[0.0, 0.0, 0.0]]), orientations=np.array([Q_IDENTITY]), object_ids=np.array([7]), t=0.0
    )
    assert centers[0] == pytest.approx([3.0, 0.0, 0.0])


def test_interleaved_objects_are_grouped_without_losing_row_order():
    object_ids = np.tile(np.arange(1, 65, dtype=np.int64), 16)
    centers = np.zeros((object_ids.size, 3), dtype=np.float64)
    orientations = np.tile(Q_IDENTITY, (object_ids.size, 1))
    layer = ObjectLayer(
        tracks=[
            rec.ObjectTrack(
                object_id=object_id,
                times=[0.0],
                rotations=[Q_IDENTITY],
                translations=[[float(object_id), 0.0, 0.0]],
            )
            for object_id in range(1, 65)
        ]
    )

    moved, rotated = layer.apply(
        centers=centers,
        orientations=orientations,
        object_ids=object_ids,
        t=0.0,
    )
    assert moved[:, 0] == pytest.approx(object_ids)
    assert rotated == pytest.approx(orientations)


# --------------------------------------------------------------------------
# Refusals — each names its code, for the conformance harness
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("build", "code"),
    [
        (
            lambda: rec.ObjectTable(
                entries=[rec.ObjectTableEntry(object_id=7), rec.ObjectTableEntry(object_id=7)]
            ).check(),
            "duplicate-object-id",
        ),
        (
            lambda: rec.ObjectTable(
                embedding_dim=2, entries=[rec.ObjectTableEntry(object_id=7, embedding=[math.nan, 0.0])]
            ).check(),
            "non-finite-object-value",
        ),
        (
            lambda: rec.ObjectTable(
                embedding_dim=4, entries=[rec.ObjectTableEntry(object_id=7, embedding=[0.0, 1.0, 2.0])]
            ).check(),
            "invalid-object-embedding-shape",
        ),
        (
            lambda: rec.ObjectTrack(
                object_id=0, times=[0.0], rotations=[Q_IDENTITY], translations=[[0.0, 0.0, 0.0]]
            ).check(),
            "track-names-background",
        ),
        (
            lambda: rec.ObjectTrack(
                object_id=7,
                times=[1.0, 1.0],
                rotations=[Q_IDENTITY, Q_IDENTITY],
                translations=[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
            ).check(),
            "non-increasing-track-time",
        ),
        (
            lambda: rec.ObjectTrack(
                object_id=7, times=[0.0], rotations=[[0.0, 0.0, 0.0, 0.0]], translations=[[0.0, 0.0, 0.0]]
            ).check(),
            "non-unit-track-quaternion",
        ),
        (
            lambda: rec.ObjectTrack(
                object_id=7,
                times=[0.0, 1.0],
                rotations=[Q_IDENTITY],
                translations=[[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]],
            ).check(),
            "invalid-object-track-shape",
        ),
        (
            lambda: rec.ObjectTrack(
                object_id=7,
                times=[0.0],
                rotations=[[0.0, 0.0, 1.0]],
                translations=[[0.0, 0.0, 0.0, 1.0]],
            ).check(),
            "invalid-object-track-shape",
        ),
        (
            lambda: ObjectLayer(
                tracks=[
                    rec.ObjectTrack(object_id=7, times=[0.0], rotations=[Q_IDENTITY], translations=[[0.0, 0.0, 0.0]]),
                    rec.ObjectTrack(object_id=7, times=[0.0], rotations=[Q_IDENTITY], translations=[[1.0, 0.0, 0.0]]),
                ]
            ).check(),
            "duplicate-object-track",
        ),
    ],
)
def test_refusals(build, code):
    with pytest.raises(MalformedFile) as caught:
        build()
    assert caught.value.code == code, f"expected {code!r}, refused as {caught.value.code!r}"


# --------------------------------------------------------------------------
# Full-file integration: writer -> reader, both streamed and indexed
# --------------------------------------------------------------------------


def _scene_with_objects(n=400):
    """A GaussianSet whose gaussians are split between background (0) and one object (7)."""
    seg = np.arange(n) % 3
    object_id = np.where(np.arange(n) % 2 == 0, 7, 0).astype(np.int64)
    return fourdgs.GaussianSet(
        positions=RNG.normal(0, 0.5, (n, 3)).astype(np.float32),
        scales=np.exp(RNG.normal(-7, 0.5, (n, 3))).astype(np.float32),
        rotations=np.tile(Q_IDENTITY, (n, 1)).astype(np.float32),
        colors=RNG.uniform(0, 1, (n, 4)).astype(np.float32),
        motions=RNG.normal(0, 0.02, (n, 3)).astype(np.float32),
        mu_t=(seg * 2.0).astype(np.float32),
        sigma_t=np.exp(RNG.normal(-2.0, 0.5, n)).astype(np.float32),
        win_lo=(seg * 2.0).astype(np.float32),
        win_hi=((seg + 1) * 2.0).astype(np.float32),
        object_id=object_id,
    )


def _layer():
    return ObjectLayer(
        table=rec.ObjectTable(
            embedding_dim=3,
            entries=[
                rec.ObjectTableEntry(object_id=7, label="vehicle", anchor=(0.0, 0.0, 0.0), embedding=[0.1, 0.2, 0.3])
            ],
        ),
        tracks=[
            rec.ObjectTrack(
                object_id=7,
                times=[0.0, 6.0],
                rotations=[Q_IDENTITY, Q_IDENTITY],
                translations=[[100.0, 0.0, 0.0], [100.0, 0.0, 0.0]],
            )
        ],
    )


def test_object_id_and_records_round_trip_through_a_file():
    scene = _scene_with_objects()
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0, options=fourdgs.WriteOptions(objects=_layer()))
    out = fourdgs.read(buf.getvalue())

    # The object_id stream survived, aligned with the gaussians (order may differ from
    # input — the encoder reorders within a chunk — so compare as a multiset per position).
    assert out.gaussians.object_id is not None
    assert set(np.unique(out.gaussians.object_id)) == {0, 7}
    assert int((out.gaussians.object_id == 7).sum()) == int((scene.object_id == 7).sum())

    # The front-matter records survived.
    assert out.objects.table is not None
    assert out.objects.table.entries[0].label == "vehicle"
    assert out.objects.table.entries[0].embedding == pytest.approx([0.1, 0.2, 0.3])
    assert out.objects.track(7) is not None


def test_composition_moves_the_tracked_object_in_a_real_file():
    scene = _scene_with_objects()
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0, options=fourdgs.WriteOptions(objects=_layer()))
    out = fourdgs.read(buf.getvalue())

    g = out.gaussians
    base = g.positions + g.motions * (3.0 - g.mu_t[:, None])  # §3 center at t=3
    moved, _ = out.objects.apply(centers=base, orientations=g.rotations, object_ids=g.object_id, t=3.0)

    is_object = g.object_id == 7
    # The tracked gaussians are displaced by +100 in x; the background is untouched.
    assert np.allclose(moved[is_object, 0], base[is_object, 0] + 100.0, atol=1e-3)
    assert np.allclose(moved[~is_object], base[~is_object])


def test_indexed_reader_reads_the_object_layer():
    scene = _scene_with_objects()
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0, options=fourdgs.WriteOptions(objects=_layer(), write_index=True))
    data = buf.getvalue()

    source = BytesReadable(data)
    indexed = open_indexed(source)
    layer = read_objects(source, indexed)
    assert layer.table is not None
    assert layer.table.entries[0].object_id == 7
    assert layer.track(7) is not None


def test_a_file_with_no_objects_is_unchanged():
    scene = _scene_with_objects()
    scene.object_id = None
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0)
    out = fourdgs.read(buf.getvalue())
    assert out.gaussians.object_id is None
    assert not out.objects  # empty layer is falsy


def _content(encoded: bytes) -> memoryview:
    """Strip the 1-byte opcode and 8-byte length framing, returning the record content."""
    return memoryview(encoded)[9:]
