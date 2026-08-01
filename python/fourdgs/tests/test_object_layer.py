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
from fourdgs.exceptions import InvalidInput, MalformedFile
from fourdgs.indexed_reader import open_indexed, read_chunk, read_objects, read_provenance
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


def _parse_object_table_with_presence_flag(*, embedding_dim: int, offset: int, value: int):
    encoded = rec.ObjectTable(
        embedding_dim=embedding_dim,
        entries=[rec.ObjectTableEntry(object_id=7)],
    ).encode()
    content = bytearray(encoded[9:])
    content[offset] = value
    return rec.ObjectTable.parse(content)


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
            lambda: rec.ObjectTable(entries=[rec.ObjectTableEntry(object_id=-1)]).check(),
            "invalid-object-id",
        ),
        (
            lambda: rec.ObjectTable(entries=[rec.ObjectTableEntry(object_id=2**32)]).check(),
            "invalid-object-id",
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
            lambda: rec.ObjectTrack(object_id=-1).check(),
            "invalid-object-id",
        ),
        (
            lambda: rec.ObjectTrack(object_id=2**32).check(),
            "invalid-object-id",
        ),
        (
            lambda: rec.ObjectTrack(object_id=7, interpolation=2).check(),
            "unsupported-trajectory-interpolation",
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
        (
            lambda: _parse_object_table_with_presence_flag(embedding_dim=0, offset=26, value=2),
            "invalid-object-presence-flag",
        ),
        (
            lambda: _parse_object_table_with_presence_flag(embedding_dim=1, offset=27, value=2),
            "invalid-object-presence-flag",
        ),
    ],
)
def test_refusals(build, code):
    with pytest.raises(MalformedFile) as caught:
        build()
    assert caught.value.code == code, f"expected {code!r}, refused as {caught.value.code!r}"


@pytest.mark.parametrize(
    ("table", "field", "code"),
    [
        (rec.ObjectTable(embedding_dim=-1), "embedding_dim", "invalid-object-embedding-dim"),
        (rec.ObjectTable(embedding_dim=65536), "embedding_dim", "invalid-object-embedding-dim"),
        (rec.ObjectTable(embedding_dim=1.5), "embedding_dim", "invalid-object-embedding-dim"),
        (
            rec.ObjectTable(entries=[rec.ObjectTableEntry(object_id=7, anchor=(1e100, 0.0, 0.0))]),
            "anchor[0]",
            "object-value-out-of-f32-range",
        ),
        (
            rec.ObjectTable(
                entries=[
                    rec.ObjectTableEntry(
                        object_id=7,
                        dynamics=([1e100, 0.0, 0.0], [0.0] * 3, [0.0] * 3),
                    )
                ]
            ),
            "velocity[0]",
            "object-value-out-of-f32-range",
        ),
        (
            rec.ObjectTable(
                embedding_dim=1,
                entries=[rec.ObjectTableEntry(object_id=7, embedding=[1e100])],
            ),
            "embedding[0]",
            "object-value-out-of-f32-range",
        ),
    ],
)
def test_object_table_writer_names_values_that_do_not_fit_the_wire(table, field, code):
    with pytest.raises(MalformedFile) as caught:
        table.encode()
    assert field in str(caught.value)
    assert caught.value.code == code


@pytest.mark.parametrize(
    ("track", "code"),
    [
        (rec.ObjectTrack(object_id=-1), "invalid-object-id"),
        (rec.ObjectTrack(object_id=7, interpolation=2), "unsupported-trajectory-interpolation"),
        (
            rec.ObjectTrack(
                object_id=7,
                times=[0.0],
                rotations=[],
                translations=[[0.0, 0.0, 0.0]],
            ),
            "invalid-object-track-shape",
        ),
    ],
)
def test_object_track_encoder_runs_structural_validation(track, code):
    with pytest.raises(MalformedFile) as caught:
        track.encode()
    assert caught.value.code == code


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


def test_objects_profile_enforces_its_membership_and_table_promises():
    scene = _scene_with_objects()
    with pytest.raises(InvalidInput, match="ObjectTable"):
        fourdgs.write(io.BytesIO(), scene, 6.0, options=fourdgs.WriteOptions(scene_profile="objects"))

    scene.object_id = None
    with pytest.raises(InvalidInput, match="object_id"):
        fourdgs.write(
            io.BytesIO(),
            scene,
            6.0,
            options=fourdgs.WriteOptions(scene_profile="objects", objects=_layer()),
        )


def test_object_id_round_trips_the_complete_u32_domain():
    scene = _scene_with_objects(4)
    scene.object_id = np.array([0, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF], dtype=np.uint32)
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0, options=fourdgs.WriteOptions(write_index=True))
    expected = sorted(int(v) for v in scene.object_id)

    streamed = fourdgs.read(buf.getvalue()).gaussians.object_id
    assert streamed is not None
    assert sorted(int(v) for v in streamed) == expected

    source = BytesReadable(buf.getvalue())
    indexed = open_indexed(source)
    chunks = [read_chunk(source, indexed, entry) for entry in indexed.index]
    decoded = np.concatenate([chunk["object_id"] for chunk in chunks])
    assert sorted(int(v) for v in decoded) == expected


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

    state = out.state_at(3.0)
    rows = state["indices"]
    tracked = g.object_id[rows] == 7
    assert np.allclose(state["centers"][tracked, 0], base[rows][tracked, 0] + 100.0, atol=1e-3)
    assert np.allclose(state["centers"][~tracked], base[rows][~tracked], atol=1e-3)
    assert state["orientations"].shape == (rows.size, 4)
    assert np.array_equal(state["object_id"], g.object_id[rows])


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


def test_reading_provenance_does_not_fetch_object_ranges():
    class CountingBytesReadable(BytesReadable):
        def __init__(self, data):
            super().__init__(data)
            self.ranges = []

        def read(self, offset, length):
            self.ranges.append((offset, length))
            return super().read(offset, length)

    scene = _scene_with_objects()
    buf = io.BytesIO()
    fourdgs.write(buf, scene, 6.0, options=fourdgs.WriteOptions(objects=_layer(), write_index=True))
    source = CountingBytesReadable(buf.getvalue())
    indexed = open_indexed(source)
    source.ranges.clear()

    provenance = read_provenance(source, indexed)
    assert not provenance
    assert source.ranges == []


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


def test_the_composed_state_path_applies_tracks_the_base_path_leaves_alone():
    """`state_at` is the base temporal state; a scene with tracks needs composition.

    The base path is the right answer for a scene with no layer and the wrong one for
    a scene with tracks — the gaussians of a moving object come back at their rest
    centres — which is why the composed entry point exists rather than leaving every
    caller to remember `ObjectLayer.apply`.
    """
    track = rec.ObjectTrack(
        object_id=7,
        times=[0.0, 4.0],
        rotations=[[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]],
        translations=[[0.0, 0.0, 0.0], [4.0, 0.0, 0.0]],
    )
    layer = fourdgs.ObjectLayer(tracks=[track])

    class _Gaussians:
        def state_at(self, t, cutoff=0.05):
            return {
                "centers": np.array([[1.0, 0.0, 0.0]]),
                "orientations": np.array([[0.0, 0.0, 0.0, 1.0]]),
                "object_id": np.array([7]),
            }

    gaussians = _Gaussians()
    assert gaussians.state_at(2.0)["centers"][0][0] == 1.0

    composed = fourdgs.state_at_with_objects(gaussians, layer, 2.0)
    assert composed["centers"][0][0] == pytest.approx(3.0)

    # No layer, or an empty one, is the base state unchanged.
    assert fourdgs.state_at_with_objects(gaussians, None, 2.0)["centers"][0][0] == 1.0
    assert fourdgs.state_at_with_objects(gaussians, fourdgs.ObjectLayer(), 2.0)["centers"][0][0] == 1.0
