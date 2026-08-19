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
/// that did would be asking two correct decoders to disagree. Emitted rows use
/// the content order defined by [_stableOrder], which is derived from decoded
/// values alone. Aggregates round addends to canonical decimal units and add
/// those units exactly, so even their arithmetic is independent of order.
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
///
/// Rounding is half-to-even on the value's exact binary expansion, and a value
/// that rounds to zero comes back unsigned.
///
/// Neither is a detail. `toStringAsFixed` — the obvious spelling, and the one
/// this used — rounds a half *away from zero*, while Python's `round`, Rust's
/// and C++'s `%.6f`, Swift's `String(format:)` and this file's own [exactSum]
/// all round it to even. The two disagree on every odd multiple of 2^-7, and
/// every value a decoder produces is a float32, whose exact six-decimal ties are
/// precisely those numbers: `num6(0.0078125)` said `0.007813` where the
/// reference said `0.007812`, and [exactSum] over the same column said
/// `0.007812` in the same document. Sharing [_canonicalUnits] with [exactSum] is
/// what makes one value round one way here.
///
/// The sign of a zero is the canonical form's first rule — it records which side
/// of zero the arithmetic landed on, which is a property of the platform and not
/// of the scene. It is erased for free by going through [BigInt], which has no
/// signed zero, and it has to be erased somewhere: `jsonEncode(-0.0)` is
/// `-0.0`, and Dart's `compareTo` orders `-0.0` before `0.0` even though `==`
/// calls them equal, so a surviving sign both changed the emitted text and
/// reordered the rows it appeared in.
double? num6(double? value) {
  if (value == null) return null;
  if (!value.isFinite) return null;
  final units = _canonicalUnits(value, _roundingScratch);
  return double.parse(_unitsToken(units!));
}

/// One eight-byte view for every [num6] and [_sortable] call in the process.
///
/// [exactSum] keeps its own for the same reason it exists at all: rounding is
/// per decoded field per gaussian, so a view allocated per value would turn a
/// constant-space summary into millions of short-lived objects. Nothing here
/// runs on a second isolate, and the view is dead between calls — its contents
/// are written before they are read every time.
final ByteData _roundingScratch = ByteData(8);

/// A canonical JSON number token that must never pass through binary64 again.
///
/// Aggregates can exceed the finite `double` range even when every addend is
/// finite. Keeping the token distinct lets [canonical] emit it as a number,
/// rather than narrowing it or accidentally quoting it as a string.
final class ExactNumber {
  const ExactNumber(this.token);

  final String token;

  @override
  bool operator ==(Object other) =>
      other is ExactNumber && token == other.token;

  @override
  int get hashCode => token.hashCode;

  @override
  String toString() => token;
}

final BigInt _canonicalScale = BigInt.from(1000000);

/// Sums independently rounded 10^-6 units as signed arbitrary-precision
/// integers. A non-finite addend makes the aggregate `null`.
///
/// Conversion starts from the IEEE-754 bits. `toStringAsFixed` is not suitable
/// here: fixed formatting may switch representation for large magnitudes, and
/// no intermediate decimal or binary float may narrow the exact unit count.
ExactNumber? exactSum(Iterable<double> values) {
  // One scratch view per aggregate, not per addend. Large object scenes visit
  // every live gaussian at four aggregate columns and three state probes, so a
  // per-value ByteData allocation would turn a constant-space sum into millions
  // of short-lived objects and corresponding GC pressure.
  final bits = ByteData(8);
  var total = BigInt.zero;
  for (final value in values) {
    final units = _canonicalUnits(value, bits);
    if (units == null) return null;
    total += units;
  }
  return ExactNumber(_unitsToken(total));
}

/// The nearest integer count of 10^-6 units, ties to even.
BigInt? _canonicalUnits(double value, ByteData bits) {
  bits.setFloat64(0, value, Endian.big);
  final high = bits.getUint32(0, Endian.big);
  final low = bits.getUint32(4, Endian.big);
  final negative = high & 0x80000000 != 0;
  final exponentBits = (high >> 20) & 0x7ff;
  var significand = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);

  if (exponentBits == 0x7ff) return null;
  if (exponentBits == 0 && significand == BigInt.zero) {
    return BigInt.zero;
  }

  late final int exponent;
  if (exponentBits == 0) {
    // Subnormal: no implicit leading bit, value = significand * 2^-1074.
    exponent = -1074;
  } else {
    significand |= BigInt.one << 52;
    exponent = exponentBits - 1023 - 52;
  }

  var magnitude = significand * _canonicalScale;
  if (exponent >= 0) {
    magnitude <<= exponent;
  } else {
    final denominator = BigInt.one << -exponent;
    final quotient = magnitude ~/ denominator;
    final remainder = magnitude.remainder(denominator);
    final twiceRemainder = remainder << 1;
    magnitude = quotient;
    if (twiceRemainder > denominator ||
        (twiceRemainder == denominator && quotient.isOdd)) {
      magnitude += BigInt.one;
    }
  }
  return negative ? -magnitude : magnitude;
}

String _unitsToken(BigInt units) {
  final negative = units.isNegative;
  final magnitude = units.abs();
  final whole = magnitude ~/ _canonicalScale;
  var fraction = magnitude
      .remainder(_canonicalScale)
      .toString()
      .padLeft(floatDecimals, '0');
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  if (fraction.isEmpty) fraction = '0';
  return '${negative ? '-' : ''}$whole.$fraction';
}

/// One packed column without allocating a second population-sized list.
Iterable<double> _strided(List<double> values, int width, int column) sync* {
  for (int i = column; i < values.length; i += width) {
    yield values[i];
  }
}

/// CRC-32 of a byte payload, as a string. Used where a summary needs to prove it
/// read the bytes and not merely their length.
String crcOf(List<int> data) =>
    fourdgsCrc32(Uint8List.fromList(data)).toString();

/// Serializes a summary with its keys sorted, at two-space indent.
///
/// [ExactNumber] values take a collision-proof trip through marker strings so
/// `JsonEncoder` still owns escaping and layout, then become raw number tokens.
String canonical(Map<String, Object?> summary) {
  final sorted = _sorted(summary);
  final strings = <String>{};

  void collectStrings(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        strings.add(entry.key.toString());
        collectStrings(entry.value);
      }
    } else if (value is List) {
      for (final item in value) collectStrings(item);
    } else if (value is String) {
      strings.add(value);
    }
  }

  collectStrings(sorted);
  var markerPrefix = '\u0000fourdgs-exact-number\u0000';
  while (strings.any((value) => value.contains(markerPrefix))) {
    markerPrefix += '#';
  }

  final replacements = <String, String>{};
  Object? markExact(Object? value) {
    if (value is ExactNumber) {
      final marker = '$markerPrefix${replacements.length}';
      replacements[jsonEncode(marker)] = value.token;
      return marker;
    }
    if (value is Map<String, Object?>) {
      return value.map(
        (key, item) => MapEntry<String, Object?>(key, markExact(item)),
      );
    }
    if (value is List) return value.map(markExact).toList();
    return value;
  }

  var text = const JsonEncoder.withIndent('  ').convert(markExact(sorted));
  for (final replacement in replacements.entries) {
    text = text.replaceAll(replacement.key, replacement.value);
  }
  return text;
}

/// The canonical answer for a file this reader refused, or `null` when it is
/// not one.
///
/// A refusal is a result, not a crash: the runner prints this on stdout and
/// exits 0, and the harness diffs it against the expectation like any other
/// answer. Exiting non-zero instead would collapse "refused for the right
/// reason" and "fell over" into one outcome, and telling those two apart is the
/// whole point of the invalid corpus.
///
/// An error the refusal table does not name is not that result, and `null` says
/// so. The caller turns it into a failed invocation — a diagnosis on stderr, a
/// non-zero exit — which is the split the Rust and C++ runners already keep
/// through the same optional identifier. Printing the missing identifier as `''`
/// instead exits 0 and so claims a valid answer, even though the empty string is
/// not an identifier the format defines: the harness could no longer tell
/// "refused for a reason nobody named" from "refused for the wrong reason", and
/// `run.py --update` — which writes whatever a runner prints, without parsing it
/// — could commit the empty identifier as the expectation every other SDK is
/// then scored against.
String? refusalAnswer(FourdgsException error) {
  final String? code = error.refusalCode;
  if (code == null) return null;
  return canonical(<String, Object?>{'refused': code});
}

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
  final contentKeys = _stableKeys(gaussians);
  final order = _stableOrder(contentKeys);
  final sample = order.take(sampleSize).toList();

  int neverFades = 0;
  int zeroMotion = 0;
  for (final i in order) {
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
      // Round every addend to canonical units before exact integer addition.
      // The aggregate is therefore a function of the emitted multiset, not
      // resident order or non-associative binary floating-point addition.
      'positionSum': <Object?>[
        for (int axis = 0; axis < 3; axis++)
          exactSum(_strided(gaussians.positions, 3, axis)),
      ],
      'opacitySum': exactSum(_strided(gaussians.colors, 4, 3)),
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
    out.addAll(
      _objectsAndStates(header, gaussians, objects, order, contentKeys),
    );
  }
  return out;
}

/// Object records plus post-track gaussian states at three scene-clock probes.
///
/// Stored fields alone do not prove reconstruction: two implementations can
/// agree on every entry in the table and every sample in a track and still
/// disagree about where a gaussian ends up, because the layer's one rule is an
/// order — base first, track second. The states make that order visible,
/// including orientation, and the rounded emitted state row breaks rounded
/// stored-key ties so the result stays independent of chunk and decoder order.
Map<String, Object?> _objectsAndStates(
  FourdgsHeader header,
  FourdgsGaussianSet gaussians,
  FourdgsObjectLayer? objects,
  List<int> order,
  List<List<double>> contentKeys,
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
    final sampleRows = _stateSampleRows(
      base,
      ids,
      order,
      contentKeys,
      rowForIndex,
    );
    List<Object?> rows(Float64List values, int width) => <Object?>[
      for (final row in sampleRows)
        <Object?>[
          for (int axis = 0; axis < width; axis++)
            num6(values[row * width + axis]),
        ],
    ];

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
        // State ordering governs the sample. Aggregates need no order: each
        // emitted addend becomes an exact fixed-six unit count before summing,
        // directly from the decoded columns without a population-sized row list.
        'positionSum': <Object?>[
          for (int axis = 0; axis < 3; axis++)
            exactSum(_strided(base.centers, 3, axis)),
        ],
        'opacitySum': exactSum(base.opacity),
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

/// Selects the first canonical state rows with memory bounded by [sampleSize].
///
/// [order] is already sorted by rounded content key. Only rows tied on that key
/// need the emitted-state secondary order, so each consecutive tie group keeps
/// at most the number of sample slots still unfilled. A group may contain every
/// gaussian in the scene; the retained candidate list still never exceeds 16.
List<int> _stateSampleRows(
  FourdgsState state,
  Uint32List objectIds,
  List<int> order,
  List<List<double>> contentKeys,
  Map<int, int> rowForIndex,
) {
  final sampleRows = <int>[];
  int at = 0;
  while (at < order.length && sampleRows.length < sampleSize) {
    final groupKey = contentKeys[order[at]];
    final remaining = sampleSize - sampleRows.length;
    final groupRows = <int>[];

    while (at < order.length &&
        _compareRows(contentKeys[order[at]], groupKey) == 0) {
      final row = rowForIndex[order[at]];
      at++;
      if (row == null) continue;

      int lo = 0;
      int hi = groupRows.length;
      while (lo < hi) {
        final mid = lo + ((hi - lo) >> 1);
        if (_compareStateRows(state, objectIds, row, groupRows[mid]) < 0) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      if (lo < remaining) {
        groupRows.insert(lo, row);
        if (groupRows.length > remaining) groupRows.removeLast();
      }
    }
    sampleRows.addAll(groupRows);
  }
  return sampleRows;
}

/// Portable secondary order over exactly the rounded values a state emits.
int _compareStateRows(FourdgsState state, Uint32List objectIds, int a, int b) {
  for (final (values, width) in <(Float64List, int)>[
    (state.centers, 3),
    (state.orientations, 4),
  ]) {
    for (int axis = 0; axis < width; axis++) {
      final compared = _compareEmittedStateValues(
        values[a * width + axis],
        values[b * width + axis],
      );
      if (compared != 0) return compared;
    }
  }
  return objectIds[a].compareTo(objectIds[b]);
}

int _compareEmittedStateValues(double a, double b) {
  final x = num6(a);
  final y = num6(b);
  if (x == null) return y == null ? 0 : 1;
  if (y == null) return -1;
  return x.compareTo(y);
}

/// Times a summary evaluates an object track at, derived from the track
/// itself, the way a rig trajectory's probes are.
List<double> _trackProbeTimes(FourdgsObjectTrack track) =>
    _probesOver(track.times);

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
List<double> _probeTimes(FourdgsRigTrajectory trajectory) =>
    _probesOver(trajectory.times);

/// The probe times for a list of samples, shared by rigs and object tracks.
///
/// Halving each operand rather than halving their sum: two large same-signed
/// times overflow `0.5 * (first + last)` to infinity, and `poseAt` refuses a
/// non-finite query, so the summary fails on a track the format allows. The
/// object-track copy of this list is how that bug came back after the rig one
/// was fixed — hence one helper.
List<double> _probesOver(List<double> times) {
  if (times.isEmpty) return const <double>[];
  final first = times.first;
  final last = times.last;
  return <double>[first - 0.5, first, first / 2 + last / 2, last, last + 0.5];
}

/// When to evaluate a sensor's scene pose: the midpoint of the rig it rides.
double _sensorProbeTime(
  FourdgsProvenance prov,
  FourdgsSensorCalibration sensor,
) {
  // The empty string is a legal trajectory name — the default capture rig — and
  // `sensorPoseAt` resolves it, so skipping the lookup summarized a moving
  // unnamed rig at t=0 and never exercised its composed pose.
  final trajectory = prov.trajectory(sensor.rigName);
  if (trajectory == null || trajectory.sampleCount == 0) return 0.0;
  // Halved separately, like the trajectory probes: `first + (last - first) * 0.5`
  // overflows when the two times straddle zero, and `0.5 * (first + last)`
  // overflows when they are large and same-signed. Neither form survives both.
  return trajectory.times.first / 2 + trajectory.times.last / 2;
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
/// with spherical harmonic coefficients and object membership last. Exact
/// decoded values are deliberately not a tiebreaker: independently implemented
/// decoders may differ in their last bits.
List<List<double>> _stableKeys(FourdgsGaussianSet g) {
  final sh = g.sh;
  final shWidth = sh == null ? 0 : g.shCoefficients * 3;
  final keys = <List<double>>[];
  for (int i = 0; i < g.count; i++) {
    final row = <double>[];
    for (final (array, width) in <(Float32List, int)>[
      (g.positions, 3),
      (g.scales, 3),
      (g.rotations, 4),
      (g.colors, 4),
      (g.motions, 3),
    ]) {
      for (int k = 0; k < width; k++) {
        final value = array[i * width + k];
        row.add(_sortable(value));
      }
    }
    for (final value in <double>[
      g.muT[i],
      g.sigmaT[i],
      g.winLo[i],
      g.winHi[i],
    ]) {
      row.add(_sortable(value));
    }
    row.addAll(<double>[
      if (sh != null)
        for (int k = 0; k < shWidth; k++) sh[i * shWidth + k].toDouble(),
      // Membership joins the key, after the harmonics and before the index
      // tie-break, exactly where the Python and Rust references put it. Two
      // gaussians can tie on every rounded field and still belong to different
      // objects — and then the `objectIds` sample, and the states composed from
      // it, would be ordered by decode order, which differs between two correct
      // readers that chunked the scene differently.
      if (g.objectId != null) g.objectId![i].toDouble(),
    ]);
    keys.add(row);
  }
  return keys;
}

List<int> _stableOrder(List<List<double>> keys) {
  final order = <int>[for (int i = 0; i < keys.length; i++) i];
  // Ties broken by original index. Dart's sort is not stable and Python's is;
  // the tie-break makes the difference invisible rather than relying on it.
  order.sort((int a, int b) {
    final compared = _compareRows(keys[a], keys[b]);
    return compared != 0 ? compared : a.compareTo(b);
  });
  return order;
}

int _compareRows(List<double> a, List<double> b) {
  for (int k = 0; k < a.length; k++) {
    final x = a[k];
    final y = b[k];
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// A comparison key: rounded like the summary, with infinity kept as infinity so
/// two languages order never-fading gaussians identically.
///
/// "Rounded like the summary" is the whole contract, so this rounds through
/// [num6] rather than repeating a rule beside it. It used to repeat it and get
/// it wrong in the same two ways — see [num6].
double _sortable(double value) {
  if (value.isNaN) return double.infinity;
  if (value.isInfinite) return value;
  return num6(value)!;
}
