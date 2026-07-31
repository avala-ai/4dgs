// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The statement every implementation must agree on for a variant.
///
/// A restatement in Dart of `tests/conformance/canonical.py`. Where the two
/// could drift, the Python one is the definition and this one is wrong.
///
/// Representation is pinned so that a disagreement is always about the format
/// and never about how a language spells a number: integers are strings, floats
/// are rounded to six decimals, a never-fading gaussian's sigma is `null`, and
/// `audioSources` is empty when absent and contains every independent source.
///
/// **Nothing here may depend on decoded order.** Gaussians may be reordered
/// freely by an encoder and readers must not rely on their order, so a summary
/// that did would be asking two correct decoders to disagree. Everything
/// per-gaussian is taken in the content order defined by [_stableOrder], which
/// is derived from decoded values alone.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';

/// Decimals a float is rounded to before comparison.
const int floatDecimals = 6;

/// How many gaussians appear in full. The aggregates cover the rest, so a
/// decoder cannot pass by getting a prefix right.
const int sampleSize = 16;

/// How many camera keyframes appear in full, so a long trajectory cannot bloat a
/// summary.
const int cameraKeyframes = 4;
const int audioKeyframes = 4;

/// The same cap for a rig trajectory, which is unbounded for the same reason and
/// worse: a ten-minute capture at 100 Hz is sixty thousand samples.
const int rigSamples = 4;

/// Rounds for comparison; a non-finite value becomes `null`, which is the only
/// thing JSON can say about one.
double? num6(double? value) {
  if (value == null) return null;
  if (!value.isFinite) return null;
  return double.parse(value.toStringAsFixed(floatDecimals));
}

/// CRC-32 of a byte payload, as a string. Used where a summary needs to prove it
/// read the bytes and not merely their length.
String crcOf(List<int> data) =>
    fourdgsCrc32(Uint8List.fromList(data)).toString();

/// Serializes a summary with its keys sorted, at two-space indent.
String canonical(Map<String, Object?> summary) =>
    const JsonEncoder.withIndent('  ').convert(_sorted(summary));

Object? _sorted(Object? value) {
  if (value is Map<String, Object?>) {
    return SplayTreeMap<String, Object?>.from(
      value.map(
        (String k, Object? v) => MapEntry<String, Object?>(k, _sorted(v)),
      ),
    );
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

/// The summary for one variant, from whichever read path produced it.
Map<String, Object?> summarize({
  required FourdgsHeader header,
  required FourdgsGaussianSet gaussians,
  required List<FourdgsAudioSource> audioSources,
  required List<(double, double)> chunkIntervals,
  FourdgsCameraTrajectory? camera,
  List<FourdgsMetadata> metadata = const <FourdgsMetadata>[],
  List<FourdgsAttachment> attachments = const <FourdgsAttachment>[],
  FourdgsStatistics? statistics,
  List<FourdgsSummaryOffset> summaryOffsets = const <FourdgsSummaryOffset>[],
  bool? summaryCrcOk,
  FourdgsProvenance? provenance,
  FourdgsObjectLayer? objects,
}) {
  final order = _stableOrder(gaussians);
  final sample = order.take(sampleSize).toList();

  final positionSum = <double>[0, 0, 0];
  double opacitySum = 0;
  int neverFades = 0;
  int zeroMotion = 0;
  // Summed in content order, not index order: two decoders that visit gaussians
  // differently must reach the same total, and floating-point addition is not
  // associative enough to leave that to chance.
  for (final i in order) {
    for (int k = 0; k < 3; k++) {
      positionSum[k] += gaussians.positions[i * 3 + k];
    }
    opacitySum += gaussians.colors[i * 4 + 3];
    if (!gaussians.sigmaT[i].isFinite) neverFades++;
    final m = gaussians.motions;
    if (m[i * 3].abs() + m[i * 3 + 1].abs() + m[i * 3 + 2].abs() == 0.0)
      zeroMotion++;
  }

  List<Object?> rows(Float32List array, int width) => <Object?>[
    for (final i in sample)
      <Object?>[for (int k = 0; k < width; k++) num6(array[i * width + k])],
  ];
  List<Object?> column(Float32List array) => <Object?>[
    for (final i in sample) num6(array[i]),
  ];

  final out = <String, Object?>{
    'gaussianCount': gaussians.count.toString(),
    'durationSec': num6(header.durationSec),
    'cutoff': num6(header.cutoff),
    // The Header's first two fields. Readable in every SDK from the start and
    // asserted by none of them, which is a hiding place rather than an omission:
    // a binding that returned an empty string for both read successfully,
    // produced a summary identical to a correct one, and passed.
    'profile': header.profile,
    'library': header.library,
    'shDegree': header.shDegree,
    'temporalModel': header.temporalModel,
    'hasAudio': header.hasAudio,
    'audioSources': <Object?>[
      for (final source
          in (audioSources.toList()
            ..sort((a, b) => a.sourceId.compareTo(b.sourceId))))
        _audioSource(source, header.durationSec / 2.0),
    ],
    'chunkIntervals': <Object?>[
      for (final (double a, double b) in chunkIntervals)
        <Object?>[num6(a), num6(b)],
    ],
    'headerAttributes': Map<String, String>.from(header.attributes),
    'metadataRecords': <Object?>[
      for (final m in metadata)
        <String, Object?>{
          'name': m.name,
          'entries': Map<String, String>.from(m.entries),
        },
    ],
    'attachments': <Object?>[
      for (final a in attachments)
        <String, Object?>{
          'name': a.name,
          'mediaType': a.mediaType,
          'byteLength': a.data.length.toString(),
          'crc': crcOf(a.data),
        },
    ],
    'camera': camera == null ? null : _camera(camera),
    'statistics':
        statistics == null
            ? null
            : <String, Object?>{
              'gaussianCount': statistics.gaussianCount.toString(),
              'chunkCount': statistics.chunkCount.toString(),
              'durationSec': num6(statistics.durationSec),
              'aabb': <Object?>[for (final v in statistics.aabb) num6(v)],
            },
    'summaryOffsets': <Object?>[
      for (final s in summaryOffsets)
        <String, Object?>{
          'groupOpcode': s.groupOpcode.toString(),
          'groupStart': s.groupStart.toString(),
          'groupLength': s.groupLength.toString(),
        },
    ],
    'summaryCrcOk': summaryCrcOk,
    'sh': _sphericalHarmonics(gaussians, order),
    'sample': <String, Object?>{
      'positions': rows(gaussians.positions, 3),
      'scales': rows(gaussians.scales, 3),
      'rotations': rows(gaussians.rotations, 4),
      'colors': rows(gaussians.colors, 4),
      'motions': rows(gaussians.motions, 3),
      'muT': column(gaussians.muT),
      'sigmaT': column(gaussians.sigmaT),
      'winLo': column(gaussians.winLo),
      'winHi': column(gaussians.winHi),
      if (gaussians.objectId != null)
        'objectIds': <Object?>[
          for (final i in sample) gaussians.objectId![i].toString(),
        ],
    },
    'aggregate': <String, Object?>{
      'positionSum': <Object?>[for (final v in positionSum) num6(v)],
      'opacitySum': num6(opacitySum),
      'neverFadesCount': neverFades.toString(),
      'zeroMotionCount': zeroMotion.toString(),
    },
  };

  // Omitted entirely when the file carries no provenance, which is deliberate
  // and is NOT the `audioSources` convention above. Absence here is the section
  // not applying; variants without it are the assertion that a file without
  // provenance is unchanged by the family existing.
  if (provenance != null && !provenance.isEmpty) {
    out['provenance'] = _provenance(provenance);
  }
  // Same omission rule, and for the same reason: an object record is additive
  // to the gaussian-birth model, so a file without one must summarize exactly
  // as it did before the layer existed. Membership alone is enough to report —
  // a scene can carry ids and no table.
  if ((objects != null && !objects.isEmpty) || gaussians.objectId != null) {
    out.addAll(_objectsAndStates(header, gaussians, objects, order));
  }
  return out;
}

/// Object records plus post-track gaussian states at three scene-clock probes.
///
/// Stored fields alone do not prove reconstruction: two implementations can
/// agree on every entry in the table and every sample in a track and still
/// disagree about where a gaussian ends up, because the layer's one rule is an
/// order — base first, track second. The states make that order visible,
/// including orientation, and the canonical gaussian order keeps the result
/// independent of chunk and decoder order.
Map<String, Object?> _objectsAndStates(
  FourdgsHeader header,
  FourdgsGaussianSet gaussians,
  FourdgsObjectLayer? objects,
  List<int> order,
) {
  final layer = objects ?? FourdgsObjectLayer();

  final tracks = <Object?>[
    for (final track in layer.tracks)
      <String, Object?>{
        'objectId': track.objectId.toString(),
        'interpolation': track.interpolation,
        'sampleCount': track.sampleCount.toString(),
        'posesAt': <Object?>[
          for (final probe in _trackProbeTimes(track))
            _poseRow(probe, layer.poseAt(track.objectId, probe)),
        ],
      },
  ];

  final entries = <Object?>[];
  final table = layer.table;
  if (table != null) {
    for (final entry in table.entries) {
      final embedding = entry.embedding;
      String? embeddingCrc;
      if (embedding != null) {
        final bytes = Uint8List(embedding.length * 4);
        final view = ByteData.view(bytes.buffer);
        for (int i = 0; i < embedding.length; i++) {
          view.setFloat32(i * 4, embedding[i], Endian.little);
        }
        embeddingCrc = crcOf(bytes);
      }
      final dynamics = entry.dynamics;
      entries.add(<String, Object?>{
        'objectId': entry.objectId.toString(),
        'label': entry.label,
        'anchor': <Object?>[for (final v in entry.anchor) num6(v)],
        // The decoded dynamics values, not merely their presence: a summary
        // that said only whether the record was there would pass a decoder
        // that read the nine floats and exposed zeros. Null when absent.
        'dynamics':
            dynamics == null
                ? null
                : <String, Object?>{
                  'velocity': <Object?>[for (final v in dynamics[0]) num6(v)],
                  'angularVelocity': <Object?>[
                    for (final v in dynamics[1]) num6(v),
                  ],
                  'acceleration': <Object?>[
                    for (final v in dynamics[2]) num6(v),
                  ],
                },
        'hasEmbedding': embedding != null,
        'embeddingCrc': embeddingCrc,
      });
    }
  }

  final duration = math.max(0.0, header.durationSec);
  final states = <Object?>[];
  for (final t in <double>[
    0.0,
    0.5 * duration,
    math.max(0.0, duration - 1e-6),
  ]) {
    final base = gaussians.stateAt(t, cutoff: header.cutoff);
    final ids = base.objectId ?? Uint32List(base.count);
    layer.apply(base.centers, base.orientations, ids, t);

    final rowForIndex = <int, int>{};
    for (int row = 0; row < base.count; row++) {
      rowForIndex[base.indices[row]] = row;
    }
    final sampleRows = <int>[];
    for (final index in order) {
      final row = rowForIndex[index];
      if (row != null) sampleRows.add(row);
      if (sampleRows.length == sampleSize) break;
    }

    List<Object?> rows(Float64List values, int width) => <Object?>[
      for (final row in sampleRows)
        <Object?>[
          for (int axis = 0; axis < width; axis++)
            num6(values[row * width + axis]),
        ],
    ];

    // Accumulated in scalars rather than through a live-count-sized list per
    // axis: a large object scene would otherwise pay peak memory proportional to
    // the decoded state purely to report a sum. Summed in row order, which is
    // the canonical gaussian order these rows were built in.
    final totals = <double>[0.0, 0.0, 0.0];
    for (int row = 0; row < base.count; row++) {
      for (int axis = 0; axis < 3; axis++) {
        totals[axis] += base.centers[row * 3 + axis];
      }
    }
    final positionSum = <Object?>[for (final total in totals) num6(total)];
    double opacitySum = 0.0;
    for (final value in base.opacity) {
      opacitySum += value;
    }

    states.add(<String, Object?>{
      't': num6(t),
      'liveCount': base.count.toString(),
      'sample': <String, Object?>{
        'positions': rows(base.centers, 3),
        'orientations': rows(base.orientations, 4),
        'objectIds': <Object?>[
          for (final row in sampleRows) ids[row].toString(),
        ],
      },
      'aggregate': <String, Object?>{
        'positionSum': positionSum,
        'opacitySum': num6(opacitySum),
      },
    });
  }

  return <String, Object?>{
    'objects': <String, Object?>{
      'embeddingDim': table == null ? 0 : table.embeddingDim,
      'table': entries,
      'tracks': tracks,
    },
    'states': states,
  };
}

/// Times a summary evaluates an object track at, derived from the track
/// itself, the way a rig trajectory's probes are.
List<double> _trackProbeTimes(FourdgsObjectTrack track) {
  if (track.sampleCount == 0) return const <double>[];
  final first = track.times.first;
  final last = track.times.last;
  return <double>[first - 0.5, first, 0.5 * (first + last), last, last + 0.5];
}

Map<String, Object?> _audioSource(
  FourdgsAudioSource source,
  double sampleTime,
) {
  final state = source.stateAt(sampleTime);
  return <String, Object?>{
    'sourceId': source.sourceId.toString(),
    'name': source.name,
    'codec': source.codec,
    'channelLayout': source.channelLayout,
    'startSec': num6(source.startSec),
    'durationSec': num6(source.durationSec),
    'gain': num6(source.gain),
    'spatial': source.spatial,
    'loop': source.loop,
    'position': <Object?>[for (final v in source.position) num6(v)],
    'rotation': <Object?>[for (final v in source.rotation) num6(v)],
    'keyframeCount': source.keyframes.length.toString(),
    'keyframes': <Object?>[
      for (int i = 0; i < source.keyframes.length && i < audioKeyframes; i++)
        <String, Object?>{
          'time': num6(source.keyframes[i].time),
          'position': <Object?>[
            for (final v in source.keyframes[i].position) num6(v),
          ],
          'rotation': <Object?>[
            for (final v in source.keyframes[i].rotation) num6(v),
          ],
        },
    ],
    'interpolation': source.interpolation,
    'stateAtHalf': <String, Object?>{
      'active': state.active,
      'localTime': num6(state.localTime),
      'position': <Object?>[for (final v in state.position) num6(v)],
      'rotation': <Object?>[for (final v in state.rotation) num6(v)],
      'gain': num6(state.gain),
    },
    'byteLength': source.data.length.toString(),
    'crc': crcOf(source.data),
  };
}

Map<String, Object?> _camera(FourdgsCameraTrajectory camera) =>
    <String, Object?>{
      'fovYDeg': num6(camera.fovYDeg),
      'position': <Object?>[for (final v in camera.position) num6(v)],
      'target': <Object?>[for (final v in camera.target) num6(v)],
      'keyframeCount': camera.times.length.toString(),
      'keyframes': <Object?>[
        for (int i = 0; i < camera.times.length && i < cameraKeyframes; i++)
          <String, Object?>{
            'time': num6(camera.times[i]),
            'position': <Object?>[for (final v in camera.positions[i]) num6(v)],
            'target': <Object?>[for (final v in camera.targets[i]) num6(v)],
          },
      ],
      'interpolation': camera.interpolation,
      'loop': camera.loop,
    };

/// Every readable provenance field, plus the arithmetic the fields imply.
///
/// The fields alone would not be enough: two implementations can agree on every
/// stored quaternion and still disagree about the pose halfway between two of
/// them, because slerp has a sign convention and clamping has an edge. So the
/// summary carries the interpolated poses as well as the samples, at probe times
/// derived from the decoded data alone, including one before the first sample
/// and one after the last.
Map<String, Object?> _provenance(FourdgsProvenance prov) {
  final trajectories = <Object?>[];
  for (final t in prov.trajectories) {
    final probes = _probeTimes(t);
    trajectories.add(<String, Object?>{
      'name': t.name,
      'interpolation': t.interpolation,
      'sampleCount': t.sampleCount.toString(),
      'samples': <Object?>[
        for (int i = 0; i < t.sampleCount && i < rigSamples; i++)
          <String, Object?>{
            'time': num6(t.times[i]),
            'rotation': <Object?>[for (final v in t.rotations[i]) num6(v)],
            'translation': <Object?>[
              for (final v in t.translations[i]) num6(v),
            ],
          },
      ],
      'posesAt': <Object?>[
        for (final probe in probes) _poseRow(probe, fourdgsRigPoseAt(t, probe)),
      ],
    });
  }

  return <String, Object?>{
    'frames': <Object?>[
      for (final f in prov.frames)
        <String, Object?>{
          'name': f.name,
          'handedness': f.handedness,
          'upAxis': f.upAxis,
          'forwardAxis': f.forwardAxis,
          'lengthUnit': f.lengthUnit,
          'metresPerUnit': num6(f.metresPerUnit),
          // The resolution rule, per frame: a consumer handed a file whose two
          // unit fields disagree still has to produce one number, and this is it.
          'metresPerUnitResolved': num6(prov.metresPerUnit(f.name)),
        },
    ],
    'anchors': <Object?>[
      for (final a in prov.anchors)
        <String, Object?>{
          'frameName': a.frameName,
          'latitudeDeg': num6(a.latitudeDeg),
          'longitudeDeg': num6(a.longitudeDeg),
          'altitudeM': num6(a.altitudeM),
          'headingDeg': num6(a.headingDeg),
        },
    ],
    'sensors': <Object?>[
      for (final s in prov.sensors)
        <String, Object?>{
          'name': s.name,
          'modality': s.modality,
          'cameraModel': s.cameraModel,
          'widthPx': s.widthPx.toString(),
          'heightPx': s.heightPx.toString(),
          'fx': num6(s.fx),
          'fy': num6(s.fy),
          'cx': num6(s.cx),
          'cy': num6(s.cy),
          'distortion': <Object?>[for (final v in s.distortion) num6(v)],
          'rotation': <Object?>[for (final v in s.rotation) num6(v)],
          'translation': <Object?>[for (final v in s.translation) num6(v)],
          'poseReference': s.poseReference,
          'rigName': s.rigName,
        },
    ],
    'trajectories': trajectories,
    // The composition rule, which is the one thing here no single record states
    // and every consumer of a moving rig depends on.
    'sensorPosesAt': <Object?>[
      for (final s in prov.sensors) _sensorPoseRow(prov, s),
    ],
  };
}

Map<String, Object?> _sensorPoseRow(
  FourdgsProvenance prov,
  FourdgsSensorCalibration sensor,
) {
  final probe = _sensorProbeTime(prov, sensor);
  return _poseRow(
    probe,
    prov.sensorPoseAt(sensor.name, probe),
    sensor: sensor.name,
  );
}

/// Times a summary evaluates a trajectory at, derived from the trajectory itself.
///
/// Two of the five are outside the sample range on purpose: clamping is a rule,
/// and a rule no expectation exercises is a rule an implementation can decline
/// to have.
List<double> _probeTimes(FourdgsRigTrajectory trajectory) {
  if (trajectory.sampleCount == 0) return const <double>[];
  final first = trajectory.times.first;
  final last = trajectory.times.last;
  return <double>[
    first - 0.5,
    first,
    first + (last - first) * 0.5,
    last,
    last + 0.5,
  ];
}

/// When to evaluate a sensor's scene pose: the midpoint of the rig it rides.
double _sensorProbeTime(
  FourdgsProvenance prov,
  FourdgsSensorCalibration sensor,
) {
  if (sensor.rigName.isEmpty) return 0.0;
  final trajectory = prov.trajectory(sensor.rigName);
  if (trajectory == null || trajectory.sampleCount == 0) return 0.0;
  return trajectory.times.first +
      (trajectory.times.last - trajectory.times.first) * 0.5;
}

Map<String, Object?> _poseRow(double t, FourdgsPose? pose, {String? sensor}) {
  final row = <String, Object?>{'time': num6(t)};
  if (sensor != null) row['sensor'] = sensor;
  if (pose == null) {
    row['rotation'] = null;
    row['translation'] = null;
    return row;
  }
  row['rotation'] = <Object?>[for (final v in pose.rotation) num6(v)];
  row['translation'] = <Object?>[for (final v in pose.translation) num6(v)];
  return row;
}

/// Degree, width and a checksum of the coefficients in content order.
///
/// A digest rather than the coefficients themselves: degree 2 over 512 gaussians
/// is 12,288 bytes, which would swamp the expectation without proving anything
/// the checksum does not. Taken in content order so that two decoders which
/// visit gaussians differently still agree.
Map<String, Object?>? _sphericalHarmonics(
  FourdgsGaussianSet gaussians,
  List<int> order,
) {
  final sh = gaussians.sh;
  if (sh == null || gaussians.shDegree == 0) return null;
  final width = gaussians.shCoefficients * 3;
  final payload = Uint8List(order.length * width);
  int at = 0;
  for (final i in order) {
    payload.setRange(at, at + width, sh, i * width);
    at += width;
  }
  return <String, Object?>{
    'degree': gaussians.shDegree,
    'coefficients': gaussians.shCoefficients.toString(),
    'crc': crcOf(payload),
  };
}

/// Sorts gaussians into an order both implementations can reproduce.
///
/// Chunking and Morton ordering are encoder choices, so decoded order is not
/// part of the contract — but a comparison needs *some* order. The key is the
/// gaussian's whole decoded state, rounded exactly as the summary rounds it,
/// with its spherical harmonic coefficients last. Two gaussians that tie on all
/// of it are identical in every value this summary emits, so their relative
/// order cannot change the output.
List<int> _stableOrder(FourdgsGaussianSet g) {
  final sh = g.sh;
  final shWidth = sh == null ? 0 : g.shCoefficients * 3;
  final keys = <(List<double>, int)>[];
  for (int i = 0; i < g.count; i++) {
    final row = <double>[
      for (int k = 0; k < 3; k++) _sortable(g.positions[i * 3 + k]),
      for (int k = 0; k < 3; k++) _sortable(g.scales[i * 3 + k]),
      for (int k = 0; k < 4; k++) _sortable(g.rotations[i * 4 + k]),
      for (int k = 0; k < 4; k++) _sortable(g.colors[i * 4 + k]),
      for (int k = 0; k < 3; k++) _sortable(g.motions[i * 3 + k]),
      _sortable(g.muT[i]),
      _sortable(g.sigmaT[i]),
      _sortable(g.winLo[i]),
      _sortable(g.winHi[i]),
      if (sh != null)
        for (int k = 0; k < shWidth; k++) sh[i * shWidth + k].toDouble(),
      // Membership joins the key, after the harmonics and before the index
      // tie-break, exactly where the Python and Rust references put it. Two
      // gaussians can tie on every rounded field and still belong to different
      // objects — and then the `objectIds` sample, and the states composed from
      // it, would be ordered by decode order, which differs between two correct
      // readers that chunked the scene differently.
      if (g.objectId != null) g.objectId![i].toDouble(),
    ];
    keys.add((row, i));
  }
  // Ties broken by original index. Dart's sort is not stable and Python's is;
  // the tie-break makes the difference invisible rather than relying on it.
  keys.sort(((List<double>, int) a, (List<double>, int) b) {
    for (int k = 0; k < a.$1.length; k++) {
      final x = a.$1[k];
      final y = b.$1[k];
      if (x != y) return x < y ? -1 : 1;
    }
    return a.$2.compareTo(b.$2);
  });
  return <int>[for (final k in keys) k.$2];
}

/// A comparison key: rounded like the summary, with infinity kept as infinity so
/// two languages order never-fading gaussians identically.
double _sortable(double value) {
  if (value.isNaN) return double.infinity;
  if (value.isInfinite) return value;
  return double.parse(value.toStringAsFixed(floatDecimals));
}
