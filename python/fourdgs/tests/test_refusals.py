# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Refusal identifiers: that a reader refuses, and that it says which rule.

The conformance corpus checks these across languages. These tests check the two things
the corpus cannot: that the identifier is on the exception a caller catches, and that the
two read paths — front to back and through the index — refuse the same file for the same
reason. A check on only one path refuses half the files it should, and the half it misses
is whichever path the consumer happens to use.
"""

from __future__ import annotations

import io
import math
import os
import sys

import fourdgs
import numpy as np
import pytest
from fourdgs import indexed_reader
from fourdgs import opcode as op
from fourdgs import records as rec
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.readable import BytesReadable
from fourdgs.serialization import Cursor, put_string, put_u8, put_u32

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "tests", "conformance", "generator"))
import invalid

RNG = np.random.default_rng(20260729)


def _scene(n: int = 24, windows: int = 4) -> bytes:
    """A small valid file with more than one validity window."""
    span = 1.0
    gaussians = fourdgs.GaussianSet(
        positions=RNG.normal(size=(n, 3)).astype(np.float32),
        scales=np.full((n, 3), 0.01, dtype=np.float32),
        rotations=np.tile(np.asarray([0.0, 0.0, 0.0, 1.0], dtype=np.float32), (n, 1)),
        colors=RNG.uniform(0.1, 0.9, size=(n, 4)).astype(np.float32),
        motions=np.zeros((n, 3), dtype=np.float32),
        mu_t=np.asarray([(i % windows) * span + span / 2 for i in range(n)], dtype=np.float32),
        sigma_t=np.full(n, 0.1, dtype=np.float32),
        win_lo=np.asarray([(i % windows) * span for i in range(n)], dtype=np.float32),
        win_hi=np.asarray([(i % windows + 1) * span for i in range(n)], dtype=np.float32),
    )
    buf = io.BytesIO()
    fourdgs.write(buf, gaussians, windows * span, options=fourdgs.WriteOptions(write_index=True, write_crc=True))
    return buf.getvalue()


def _read_streamed(data: bytes):
    return fourdgs.read(data)


def _read_indexed(data: bytes):
    """The other read path: Footer, then index, then the chunks it needs.

    It reaches the Header by a different route than the streamed reader, which is why
    both are checked. A registry check placed on one path only refuses half the files it
    should, and which half depends on how the consumer opened the file.
    """
    source = BytesReadable(data)
    scene = open_indexed(source)
    for entry in scene.index:
        read_chunk(source, scene, entry)
    return scene


@pytest.mark.parametrize("refusal", invalid.REFUSALS, ids=lambda r: r.name)
def test_streamed_read_refuses_with_the_declared_code(refusal):
    """Every mutation the conformance corpus declares is refused, by its own identifier.

    Driven from `invalid.REFUSALS` rather than from a list copied here, so a refusal
    added to the corpus cannot silently go unimplemented in the reference reader.
    """
    broken = refusal.mutate(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(broken)
    assert caught.value.code == refusal.code, f"{refusal.name}: refused as {caught.value.code!r}"


@pytest.mark.parametrize("refusal", invalid.REFUSALS, ids=lambda r: r.name)
def test_indexed_read_refuses_with_the_same_code(refusal):
    broken = refusal.mutate(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_indexed(broken)
    assert caught.value.code == refusal.code, f"{refusal.name}: refused as {caught.value.code!r}"


def test_the_base_scene_is_valid():
    """The control. A mutation proves nothing if the file was already broken."""
    data = _scene()
    assert _read_streamed(data).gaussians.count == 24
    assert len(_read_indexed(data).index) >= 1


def test_an_unknown_temporal_model_is_refused_not_assumed():
    """The refusal the whole extension story rests on.

    A file naming a temporal model this reader does not implement carries gaussians whose
    every other field is well-formed, so a reader that skips the check decodes it as
    `gaussian-birth` and returns a plausible scene. Nothing downstream can tell that the
    motion it is drawing is not the motion the file describes.
    """
    broken = invalid._unknown_temporal_model(_scene())
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(broken)
    assert caught.value.code == "unknown-temporal-model"
    assert "frame-sequence" in str(caught.value), "the message must name the value it does not know"


def test_a_corrupt_first_byte_is_not_reported_as_a_version_problem():
    """`0x89` is a sentinel, not a version.

    Reported as an unsupported version, this sends its holder looking for a newer reader,
    which would refuse it too. The two failures have different fixes and must have
    different names.
    """
    with pytest.raises(fourdgs.FourdgsError) as caught:
        _read_streamed(invalid._bad_magic(_scene()))
    assert caught.value.code == "magic-mismatch"


def test_an_error_without_an_identifier_is_still_an_error():
    """An empty code is the normal state for the many faults the suite does not name.

    It must not become a reason to treat the file as readable, and it must not be
    mistaken for a code — which is why the conformance runner prints it as an empty
    identifier that matches no expectation rather than omitting the key.
    """
    err = fourdgs.MalformedFile("something specific went wrong")
    assert err.code == ""
    assert str(err) == "something specific went wrong"


def test_a_finite_quaternion_near_the_top_of_the_range_is_renormalized_not_refused():
    """Section 5.15.4 refuses "zero or non-finite norms" — a claim about the quaternion.

    `[1e308, 0, 0, 0]` has a finite norm and a perfectly good direction. Only the naive
    sum of squares overflows, so a reader that squares first refuses a file the format
    allows, and does it in one SDK before another.
    """
    huge = [1e308, 0.0, 0.0, 0.0]
    trajectory = rec.RigTrajectory(name="rig", times=[0.0], rotations=[huge], translations=[[0.0] * 3])
    trajectory.check()
    assert math.isclose(math.hypot(*trajectory.rotations[0]), 1e308)

    sensor = rec.SensorCalibration(name="cam", rig_name="rig", rotation=huge, translation=[0.0] * 3)
    sensor.check()
    assert math.isclose(math.hypot(*sensor.unit_rotation()), 1.0)


def test_a_zero_sample_trajectory_is_read_as_absent_rather_than_refused():
    """Section 5.15.4: a trajectory with no samples "MUST be read as though the record
    were absent" — so reading one refuses nothing, not even an interpolation byte that
    describes how to read samples the record does not carry.

    The writer is held to the opposite standard: `check()` still refuses it, because a
    producer that emits such a record has made a mistake worth naming.
    """
    body = put_string("rig") + put_u8(7) + put_u32(0)
    assert rec.RigTrajectory.parse(body).sample_count == 0

    with pytest.raises(fourdgs.MalformedFile):
        rec.RigTrajectory(name="rig", interpolation=7).check()


def test_a_zero_sample_object_track_is_read_as_absent_rather_than_refused():
    """The same sentence in section 5.15.7, for the object layer.

    Kept, one empty track would make a non-empty object layer and two empty tracks for
    one id would be a duplicate the layer refuses — so the readers drop them.
    """
    body = put_u32(7) + put_u8(7) + put_u32(0)
    assert rec.ObjectTrack.parse(body).sample_count == 0

    with pytest.raises(fourdgs.MalformedFile):
        rec.ObjectTrack(object_id=7, interpolation=7).check()


def test_a_cut_file_still_refuses_a_duplicate_name_it_already_carries():
    """Truncation defers the rules a later record could satisfy, and only those.

    A sensor naming a rig the file has not reached yet is a missing target, so that
    refusal waits. Two complete `SensorCalibration` records with one name is not
    missing anything — no byte after the cut makes that name unambiguous — so it is
    refused whether or not the file was cut.
    """
    prov = fourdgs.Provenance()
    prov.sensors.append(rec.SensorCalibration(name="cam", rotation=[0.0, 0.0, 0.0, 1.0], translation=[0.0] * 3))
    prov.sensors.append(rec.SensorCalibration(name="cam", rotation=[0.0, 0.0, 0.0, 1.0], translation=[0.0] * 3))
    with pytest.raises(fourdgs.MalformedFile) as caught:
        prov.check(truncated=True)
    assert "cam" in str(caught.value)

    # The deferred half: a rig reference a later record could still satisfy.
    deferred = fourdgs.Provenance()
    deferred.sensors.append(
        rec.SensorCalibration(
            name="cam",
            rig_name="rig",
            pose_reference=1,
            rotation=[0.0, 0.0, 0.0, 1.0],
            translation=[0.0] * 3,
        )
    )
    deferred.check(truncated=True)
    with pytest.raises(fourdgs.MalformedFile):
        deferred.check()


def test_an_absent_object_track_still_refuses_the_background_id():
    """§5.15.7 makes a zero-sample track's *pose* absent; the id rule is separate.

    "`object_id` MUST NOT be `0`" is stated for every track, so an empty one that
    names background is still malformed — dropping it as absent would let the file
    through without the refusal the section requires.
    """
    with pytest.raises(fourdgs.MalformedFile) as caught:
        rec.ObjectTrack.parse(put_u32(0) + put_u8(0) + put_u32(0))
    assert caught.value.code == "track-names-background"


def test_the_trajectory_sample_ceiling_is_the_same_number_in_every_sdk():
    """A ceiling only some implementations have is a conformance split.

    Rust and Python carried no ceiling while TypeScript and Dart refused past a
    million, so a trajectory of 1,020,000 samples — 65,280,018 bytes, comfortably
    inside the 64 MiB front-matter cap, and so a record an indexed read will hand
    over whole — decoded here and was refused there.
    """
    assert rec.MAX_TRAJECTORY_SAMPLES == 1_000_000

    body = put_string("rig") + put_u8(0) + put_u32(rec.MAX_TRAJECTORY_SAMPLES + 1)
    with pytest.raises(fourdgs.MalformedFile) as caught:
        rec.RigTrajectory.parse(body)
    assert "ceiling" in str(caught.value)

    track = put_u32(7) + put_u8(0) + put_u32(rec.MAX_TRAJECTORY_SAMPLES + 1)
    with pytest.raises(fourdgs.MalformedFile) as caught:
        rec.ObjectTrack.parse(track)
    assert "ceiling" in str(caught.value)


def test_the_front_matter_ceiling_is_the_same_number_in_every_sdk():
    """Rust, TypeScript and Dart refuse a front-matter range past 64 MiB; Python did not.

    An index entry is data, and a crafted one can name any length inside the file. The
    records this bounds are small by construction, so a range past it is a claim the
    format does not make — and a reader that honours it while three others refuse is a
    conformance split, whichever way the file is read.
    """
    assert indexed_reader.MAX_FRONT_MATTER_BYTES == 64 * 1024 * 1024

    class _Vast:
        """A file big enough that the range is inside it — so only the ceiling can refuse."""

        def size(self) -> int:
            return 1 << 40

        def read(self, offset: int, length: int) -> bytes:
            raise AssertionError("the ceiling must refuse before anything is transferred")

    huge = indexed_reader.MAX_FRONT_MATTER_BYTES + 1
    with pytest.raises(fourdgs.MalformedFile) as caught:
        indexed_reader._read_range(_Vast(), 0, huge, "a Metadata record", front_matter=True)
    assert "ceiling" in str(caught.value)

    # Chunks, SH bands and Attachments carry payloads the spec allows to be arbitrarily
    # large. The ceiling deliberately does not reach them, so it cannot refuse a valid
    # file: the same range without the flag gets as far as the transfer.
    with pytest.raises(AssertionError):
        indexed_reader._read_range(_Vast(), 0, huge, "an Attachment record")


def test_a_bad_utf8_string_names_the_byte_that_failed():
    """A reader that refuses a record says which byte is wrong (AGENTS.md §6).

    The offset has to be where the *bytes* start rather than where the length prefix
    does: the prefix decoded fine, so pointing at it sends whoever is holding the file
    four bytes upstream of the problem.
    """
    body = put_u32(4) + b"ab\xffd"
    with pytest.raises(fourdgs.MalformedFile) as caught:
        Cursor(body).string()
    message = str(caught.value)
    assert "offset 4" in message, message
    assert "byte 6" in message, message


def test_a_chunk_that_carries_one_attribute_twice_is_refused():
    """One stream per attribute — and the readers disagreed about a second.

    Python, Rust and TypeScript kept the last stream; Dart kept the first, so a
    malformed chunk decoded to two different sets of gaussians depending on which SDK
    read it. All four refuse it now, which is the duplicate-name failure section 5.15.2
    refuses for records, spelled with attribute ids.
    """
    from fourdgs.quantization import Steps
    from fourdgs.serialization import encode_stream
    from fourdgs.stream_reader import decode_streams

    positions = np.zeros((3, 3), dtype=np.int64)
    doubled = encode_stream(op.A_POSITION, positions, channels=3) + encode_stream(op.A_POSITION, positions, channels=3)
    with pytest.raises(fourdgs.MalformedFile) as caught:
        decode_streams(
            doubled,
            3,
            Steps(
                pos=1e-3,
                scale_log=1e-3,
                rot=1e-3,
                rgb=1e-3,
                alpha=1e-3,
                motion=1e-3,
                time=1e-3,
                sigma_log=1e-3,
                sh=1,
            ),
            np.zeros(3),
            [],
        )
    assert caught.value.code == "duplicate-attribute-stream"
