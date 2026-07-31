# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""The canonical JSON two implementations are diffed on.

Representation is pinned so that a disagreement is always about the format and never
about how a language spells a number:

* integers are strings, so a 64-bit value survives a JSON parser backed by doubles;
* floats are rounded to a fixed number of decimals before comparison;
* a never-fading gaussian's sigma is `null`, never a sentinel a decoder could produce by
  accident;
* `audioSources` is an array, empty when absent, so multiplicity and absence are both
  visible in every implementation's output;
* keys are sorted.

**Nothing here may depend on decoded order.** Gaussians may be reordered freely by an
encoder and readers must not rely on their order, so a summary that did would be asking
two correct decoders to disagree. Everything per-gaussian — the sample, the aggregates,
the spherical harmonic digest — is taken in the content order defined by `_stable_order`,
which is derived from decoded values alone.

The summary covers what the file says, not only its gaussians. A record that changes
nothing here is a record an implementation could ignore entirely and still pass, which is
how a feature matrix ends up claiming things the suite never checked.

The same applies field by field, not only record by record. `profile` and `library` are
the Header's first two fields; every SDK could read them and none asserted them, so an
implementation returning an empty string for both was indistinguishable here from one that
decoded them properly. That is the worst shape a gap can take — not a failure, but a
success that proves less than it appears to.
"""

from __future__ import annotations

import json
import math
import struct
import zlib

FLOAT_DECIMALS = 6
#: How many gaussians appear in full. The aggregates cover the rest, so a decoder cannot
#: pass by getting a prefix right.
SAMPLE = 16
#: How many camera keyframes appear in full, so a long trajectory cannot bloat a summary.
CAMERA_KEYFRAMES = 4
#: The same cap for a rig trajectory, which is unbounded for the same reason and worse:
#: a ten-minute capture at 100 Hz is sixty thousand samples.
RIG_SAMPLES = 4
AUDIO_KEYFRAMES = 4


def num(value) -> float | None:
    """Round for comparison; a non-finite value becomes `null`.

    The `float()` first is load-bearing: a numpy scalar is not a Python float, so an
    `isinstance` check would let infinity through into JSON, which has no way to spell it.
    """
    if value is None:
        return None
    v = float(value)
    if not math.isfinite(v):
        return None
    return round(v, FLOAT_DECIMALS)


def crc(data) -> str:
    """CRC-32 of a byte payload, as a string. Used where a summary needs to prove it read
    the bytes and not merely their length."""
    return str(zlib.crc32(bytes(data)) & 0xFFFFFFFF)


def canonical(scene_summary: dict) -> str:
    return json.dumps(scene_summary, sort_keys=True, indent=2, allow_nan=False)


def summarize(
    header,
    gaussians,
    audio_sources,
    chunk_intervals,
    *,
    camera=None,
    metadata=(),
    attachments=(),
    statistics=None,
    summary_offsets=(),
    summary_crc_ok=None,
    provenance=None,
    objects=None,
) -> dict:
    """The statement every implementation must agree on for a variant."""
    n = gaussians.count
    order = _stable_order(gaussians)
    sample = order[:SAMPLE]

    def rows(arr, width):
        return [[num(v) for v in arr[i][:width]] for i in sample]

    total_pos = [0.0, 0.0, 0.0]
    alpha_sum = 0.0
    never_fades = 0
    still = 0
    for i in order:
        for k in range(3):
            total_pos[k] += float(gaussians.positions[i][k])
        alpha_sum += float(gaussians.colors[i][3])
        if not math.isfinite(float(gaussians.sigma_t[i])):
            never_fades += 1
        if (
            abs(float(gaussians.motions[i][0]))
            + abs(float(gaussians.motions[i][1]))
            + abs(float(gaussians.motions[i][2]))
            == 0.0
        ):
            still += 1

    return {
        "gaussianCount": str(n),
        "durationSec": num(header.duration_sec),
        "cutoff": num(header.cutoff),
        # The Header's first two fields. Readable in every SDK from the start and asserted
        # by none of them, which is a hiding place rather than an omission: a binding that
        # returned an empty string for both — because it never wired them through — read
        # successfully, produced a summary identical to a correct one, and passed. The C++
        # binding did exactly that once. A field that no expectation mentions is a field an
        # implementation can decline to decode.
        "profile": header.profile,
        "library": header.library,
        "shDegree": int(header.sh_degree),
        "temporalModel": header.temporal_model,
        "hasAudio": bool(header.has_audio),
        "audioSources": [
            _audio_source(source, header.duration_sec / 2)
            for source in sorted(audio_sources, key=lambda s: s.source_id)
        ],
        "chunkIntervals": [[num(a), num(b)] for a, b in chunk_intervals],
        "headerAttributes": {k: v for k, v in sorted(dict(header.attributes).items())},
        "metadataRecords": [
            {"name": m.name, "entries": {k: v for k, v in sorted(dict(m.entries).items())}} for m in metadata
        ],
        "attachments": [
            {
                "name": a.name,
                "mediaType": a.media_type,
                "byteLength": str(len(a.data)),
                "crc": crc(a.data),
            }
            for a in attachments
        ],
        "camera": None if camera is None else _camera(camera),
        "statistics": None
        if statistics is None
        else {
            "gaussianCount": str(statistics.gaussian_count),
            "chunkCount": str(statistics.chunk_count),
            "durationSec": num(statistics.duration_sec),
            "aabb": [num(v) for v in statistics.aabb],
        },
        "summaryOffsets": [
            {
                "groupOpcode": str(s.group_opcode),
                "groupStart": str(s.group_start),
                "groupLength": str(s.group_length),
            }
            for s in summary_offsets
        ],
        "summaryCrcOk": summary_crc_ok,
        # Omitted entirely when the file carries no provenance, which is deliberate and
        # is NOT the `audioSources` convention above.
        #
        # `audioSources` is empty when absent because audio presence is a property of
        # every file — the Header declares it either way — so both paths have to be
        # visible in every variant or one of them is never checked. Provenance has no such
        # flag and no such duty: a file that carries none is a file the record family does
        # not apply to. Emitting `"provenance": null` on all thirty-four pre-existing variants
        # would have changed every committed expectation and broken three SDKs that
        # correctly skip the records by length — which is to say it would have reported
        # the forward-compatibility mechanism working as a conformance failure. Absence
        # here is the section not applying; the thirty-four variants without it are the
        # assertion that a file without provenance is unchanged by the family existing.
        **({} if not provenance else {"provenance": _provenance(provenance)}),
        **(
            {}
            if not objects and getattr(gaussians, "object_id", None) is None
            else _objects_and_states(header, gaussians, objects, order)
        ),
        "sh": _spherical_harmonics(gaussians, order),
        "sample": {
            "positions": rows(gaussians.positions, 3),
            "scales": rows(gaussians.scales, 3),
            "rotations": rows(gaussians.rotations, 4),
            "colors": rows(gaussians.colors, 4),
            "motions": rows(gaussians.motions, 3),
            "muT": [num(gaussians.mu_t[i]) for i in sample],
            "sigmaT": [num(gaussians.sigma_t[i]) for i in sample],
            "winLo": [num(gaussians.win_lo[i]) for i in sample],
            "winHi": [num(gaussians.win_hi[i]) for i in sample],
            **(
                {}
                if getattr(gaussians, "object_id", None) is None
                else {"objectIds": [str(int(gaussians.object_id[i])) for i in sample]}
            ),
        },
        "aggregate": {
            "positionSum": [num(v) for v in total_pos],
            "opacitySum": num(alpha_sum),
            "neverFadesCount": str(never_fades),
            "zeroMotionCount": str(still),
        },
    }


def _objects_and_states(header, gaussians, objects, order) -> dict:
    """Object records plus post-track gaussian states at three scene-clock probes.

    Stored fields alone do not prove reconstruction. The states make the normative
    base-then-track order visible, including orientation, while the canonical gaussian
    order keeps the result independent of chunk and decoder order.
    """
    from fourdgs.object_layer import ObjectLayer
    from fourdgs.provenance import pose_at

    layer = objects if objects is not None else ObjectLayer()
    table = layer.table
    tracks = []
    for track in layer.tracks:
        probes = _probe_times(track)
        tracks.append(
            {
                "objectId": str(track.object_id),
                "interpolation": int(track.interpolation),
                "sampleCount": str(track.sample_count),
                "posesAt": [_pose_row(probe, pose_at(track, probe)) for probe in probes],
            }
        )

    duration = max(0.0, float(header.duration_sec))
    probe_times = [0.0, 0.5 * duration, max(0.0, duration - 1e-6)]
    states = []
    for t in probe_times:
        base = gaussians.state_at(t, header.cutoff)
        centers, orientations = layer.apply(
            centers=base["centers"],
            orientations=base["orientations"],
            object_ids=base["object_id"],
            t=t,
        )
        row_for_index = {int(index): row for row, index in enumerate(base["indices"])}
        sample_indices = [index for index in order if index in row_for_index][:SAMPLE]
        sample_rows = [row_for_index[index] for index in sample_indices]
        states.append(
            {
                "t": num(t),
                "liveCount": str(len(base["indices"])),
                "sample": {
                    "positions": [[num(value) for value in centers[row]] for row in sample_rows],
                    "orientations": [[num(value) for value in orientations[row]] for row in sample_rows],
                    "objectIds": [str(int(base["object_id"][row])) for row in sample_rows],
                },
                "aggregate": {
                    "positionSum": [num(sum(float(row[axis]) for row in centers)) for axis in range(3)],
                    "opacitySum": num(sum(float(value) for value in base["opacity"])),
                },
            }
        )

    entries = []
    if table is not None:
        for entry in table.entries:
            embedding = entry.embedding
            embedding_bytes = b"" if embedding is None else struct.pack(f"<{len(embedding)}f", *embedding)
            entries.append(
                {
                    "objectId": str(entry.object_id),
                    "label": entry.label,
                    "anchor": [num(value) for value in entry.anchor],
                    # The decoded dynamics values, not merely their presence: a summary that
                    # said only whether the record was there would pass a decoder that read
                    # the nine floats and exposed zeros. `None` when the entry carries none.
                    "dynamics": None
                    if entry.dynamics is None
                    else {
                        "velocity": [num(v) for v in entry.dynamics[0]],
                        "angularVelocity": [num(v) for v in entry.dynamics[1]],
                        "acceleration": [num(v) for v in entry.dynamics[2]],
                    },
                    "hasEmbedding": embedding is not None,
                    "embeddingCrc": None if embedding is None else crc(embedding_bytes),
                }
            )

    return {
        "objects": {
            "embeddingDim": 0 if table is None else int(table.embedding_dim),
            "table": entries,
            "tracks": tracks,
        },
        "states": states,
    }


def _provenance(prov) -> dict:
    """Every readable provenance field, plus the arithmetic the fields imply.

    The fields alone would not be enough. `Header.profile` was readable in every SDK
    and asserted by none, so a binding that returned an empty string passed — and the
    same hiding place exists one level up here: two implementations can agree on every
    stored quaternion and still disagree about the pose halfway between two of them,
    because slerp has a sign convention and clamping has an edge. So the summary
    carries the interpolated poses as well as the samples, at probe times derived from
    the decoded data alone, including one before the first sample and one after the
    last.
    """
    from fourdgs.provenance import pose_at

    trajectories = []
    for t in prov.trajectories:
        probes = _probe_times(t)
        trajectories.append(
            {
                "name": t.name,
                "interpolation": int(t.interpolation),
                "sampleCount": str(t.sample_count),
                "samples": [
                    {
                        "time": num(t.times[i]),
                        "rotation": [num(v) for v in t.rotations[i]],
                        "translation": [num(v) for v in t.translations[i]],
                    }
                    for i in range(min(t.sample_count, RIG_SAMPLES))
                ],
                "posesAt": [_pose_row(probe, pose_at(t, probe)) for probe in probes],
            }
        )

    return {
        "frames": [
            {
                "name": f.name,
                "handedness": int(f.handedness),
                "upAxis": int(f.up_axis),
                "forwardAxis": int(f.forward_axis),
                "lengthUnit": int(f.length_unit),
                "metresPerUnit": num(f.metres_per_unit),
                # The resolution rule, per frame: a consumer handed a file whose two unit
                # fields disagree still has to produce one number, and this is it.
                "metresPerUnitResolved": num(prov.metres_per_unit(f.name)),
            }
            for f in prov.frames
        ],
        "anchors": [
            {
                "frameName": a.frame_name,
                "latitudeDeg": num(a.latitude_deg),
                "longitudeDeg": num(a.longitude_deg),
                "altitudeM": num(a.altitude_m),
                "headingDeg": num(a.heading_deg),
            }
            for a in prov.anchors
        ],
        "sensors": [
            {
                "name": s.name,
                "modality": s.modality,
                "cameraModel": int(s.camera_model),
                "widthPx": str(s.width_px),
                "heightPx": str(s.height_px),
                "fx": num(s.fx),
                "fy": num(s.fy),
                "cx": num(s.cx),
                "cy": num(s.cy),
                "distortion": [num(v) for v in s.distortion],
                "rotation": [num(v) for v in s.rotation],
                "translation": [num(v) for v in s.translation],
                "poseReference": int(s.pose_reference),
                "rigName": s.rig_name,
            }
            for s in prov.sensors
        ],
        "trajectories": trajectories,
        # The composition rule, which is the one thing here no single record states and
        # every consumer of a moving rig depends on.
        "sensorPosesAt": [
            _pose_row(probe, prov.sensor_pose_at(s.name, probe), sensor=s.name)
            for s in prov.sensors
            for probe in (_sensor_probe_time(prov, s),)
        ],
    }


def _probe_times(trajectory) -> list[float]:
    """Times a summary evaluates a trajectory at, derived from the trajectory itself.

    Two of the five are outside the sample range on purpose: clamping is a rule, and a
    rule no expectation exercises is a rule an implementation can decline to have.
    """
    if trajectory.sample_count == 0:
        return []
    first, last = trajectory.times[0], trajectory.times[-1]
    return [first - 0.5, first, first + (last - first) * 0.5, last, last + 0.5]


def _sensor_probe_time(prov, sensor) -> float:
    """When to evaluate a sensor's scene pose: the midpoint of the rig it rides."""
    trajectory = prov.trajectory(sensor.rig_name) if sensor.rig_name else None
    if trajectory is None or trajectory.sample_count == 0:
        return 0.0
    return trajectory.times[0] + (trajectory.times[-1] - trajectory.times[0]) * 0.5


def _pose_row(t: float, pose, sensor: str | None = None) -> dict:
    row = {"time": num(t)}
    if sensor is not None:
        row["sensor"] = sensor
    if pose is None:
        row["rotation"] = None
        row["translation"] = None
        return row
    row["rotation"] = [num(v) for v in pose.rotation]
    row["translation"] = [num(v) for v in pose.translation]
    return row


def _camera(camera) -> dict:
    return {
        "fovYDeg": num(camera.fov_y_deg),
        "position": [num(v) for v in camera.position],
        "target": [num(v) for v in camera.target],
        "keyframeCount": str(len(camera.times)),
        "keyframes": [
            {
                "time": num(camera.times[i]),
                "position": [num(v) for v in camera.positions[i]],
                "target": [num(v) for v in camera.targets[i]],
            }
            for i in range(min(len(camera.times), CAMERA_KEYFRAMES))
        ],
        "interpolation": camera.interpolation,
        "loop": bool(camera.loop),
    }


def _audio_source(source, sample_time: float) -> dict:
    state = source.state_at(sample_time)
    return {
        "sourceId": str(source.source_id),
        "name": source.name,
        "codec": source.codec,
        "channelLayout": source.channel_layout,
        "startSec": num(source.start_sec),
        "durationSec": num(source.duration_sec),
        "gain": num(source.gain),
        "spatial": bool(source.spatial),
        "loop": bool(source.loop),
        "position": [num(v) for v in source.position],
        "rotation": [num(v) for v in source.rotation],
        "keyframeCount": str(len(source.keyframes)),
        "keyframes": [
            {
                "time": num(keyframe.time),
                "position": [num(v) for v in keyframe.position],
                "rotation": [num(v) for v in keyframe.rotation],
            }
            for keyframe in source.keyframes[:AUDIO_KEYFRAMES]
        ],
        "interpolation": source.interpolation,
        "stateAtHalf": {
            "active": bool(state.active),
            "localTime": num(state.local_time),
            "position": [num(v) for v in state.position],
            "rotation": [num(v) for v in state.rotation],
            "gain": num(state.gain),
        },
        "byteLength": str(len(source.data)),
        "crc": crc(source.data),
    }


def _spherical_harmonics(gaussians, order) -> dict | None:
    """Degree, width and a checksum of the coefficients in content order.

    A digest rather than the coefficients themselves: degree 2 over 512 gaussians is
    12,288 bytes, which would swamp the expectation without proving anything the checksum
    does not. Taken in content order so that two decoders which visit gaussians
    differently still agree.
    """
    sh = getattr(gaussians, "sh", None)
    if sh is None or gaussians.sh_degree == 0:
        return None
    coefficients = sh.shape[1] // 3
    payload = bytearray()
    for i in order:
        payload += bytes(bytearray(int(v) for v in sh[i]))
    return {
        "degree": int(gaussians.sh_degree),
        "coefficients": str(coefficients),
        "crc": crc(payload),
    }


def _stable_order(gaussians) -> list[int]:
    """Sort gaussians into an order both implementations can reproduce.

    Chunking and Morton ordering are encoder choices, so decoded order is not part of the
    contract — but a comparison needs *some* order. The key is the gaussian's whole
    decoded state, rounded exactly as the summary rounds it, with its spherical harmonic
    coefficients last. Two gaussians that tie on all of it are identical in every value
    this summary emits, so their relative order cannot change the output.
    """
    sh = getattr(gaussians, "sh", None)
    keys = []
    for i in range(gaussians.count):
        row = []
        for arr, width in (
            (gaussians.positions, 3),
            (gaussians.scales, 3),
            (gaussians.rotations, 4),
            (gaussians.colors, 4),
            (gaussians.motions, 3),
        ):
            row += [_sortable(arr[i][k]) for k in range(width)]
        row += [
            _sortable(gaussians.mu_t[i]),
            _sortable(gaussians.sigma_t[i]),
            _sortable(gaussians.win_lo[i]),
            _sortable(gaussians.win_hi[i]),
        ]
        if sh is not None:
            row += [int(v) for v in sh[i]]
        object_id = getattr(gaussians, "object_id", None)
        if object_id is not None:
            row.append(int(object_id[i]))
        keys.append((row, i))
    keys.sort(key=lambda k: k[0])
    return [k[1] for k in keys]


def _sortable(value) -> float:
    """A comparison key: rounded like the summary, with infinity kept as infinity so the
    two languages order never-fading gaussians identically."""
    v = float(value)
    if math.isnan(v):
        return math.inf
    if math.isinf(v):
        return v
    return round(v, FLOAT_DECIMALS)
