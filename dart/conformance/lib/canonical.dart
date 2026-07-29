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
/// `audio` is `null` when absent and an object when present so that both paths
/// are visible in every implementation's output.
///
/// **Nothing here may depend on decoded order.** Gaussians may be reordered
/// freely by an encoder and readers must not rely on their order, so a summary
/// that did would be asking two correct decoders to disagree. Everything
/// per-gaussian is taken in the content order defined by [_stableOrder], which
/// is derived from decoded values alone.
library;

import 'dart:collection';
import 'dart:convert';
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
  required FourdgsAudioTrack? audio,
  required List<(double, double)> chunkIntervals,
  FourdgsCameraTrajectory? camera,
  List<FourdgsMetadata> metadata = const <FourdgsMetadata>[],
  List<FourdgsAttachment> attachments = const <FourdgsAttachment>[],
  FourdgsStatistics? statistics,
  List<FourdgsSummaryOffset> summaryOffsets = const <FourdgsSummaryOffset>[],
  bool? summaryCrcOk,
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

  return <String, Object?>{
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
    // Absent audio is a value, not a missing key: both paths are
    // conformance-visible.
    'audio':
        audio == null
            ? null
            : <String, Object?>{
              'codec': audio.codec,
              'byteLength': audio.data.length.toString(),
              'crc': crcOf(audio.data),
            },
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
    },
    'aggregate': <String, Object?>{
      'positionSum': <Object?>[for (final v in positionSum) num6(v)],
      'opacitySum': num6(opacitySum),
      'neverFadesCount': neverFades.toString(),
      'zeroMotionCount': zeroMotion.toString(),
    },
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
