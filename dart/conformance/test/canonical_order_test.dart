// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/canonical.dart';
import 'package:test/test.dart';

const double _duration = 4000000.0;

FourdgsGaussianSet _gaussians(
  List<List<double>> positions,
  List<List<double>> motions,
) {
  final count = positions.length;
  final rotations = Float32List(count * 4);
  final colors = Float32List(count * 4);
  for (int i = 0; i < count; i++) {
    rotations[i * 4 + 3] = 1.0;
    colors[i * 4 + 3] = 1.0;
  }
  return FourdgsGaussianSet(
    positions: Float32List.fromList(positions.expand((row) => row).toList()),
    scales: Float32List(count * 3)..fillRange(0, count * 3, 1.0),
    rotations: rotations,
    colors: colors,
    motions: Float32List.fromList(motions.expand((row) => row).toList()),
    muT: Float32List(count),
    sigmaT: Float32List(count)..fillRange(0, count, double.infinity),
    winLo: Float32List(count),
    winHi: Float32List(count)..fillRange(0, count, _duration),
    objectId: Uint32List(count),
  );
}

FourdgsGaussianSet _permuted(FourdgsGaussianSet gaussians, List<int> order) {
  Float32List rows(Float32List values, int width) =>
      Float32List.fromList(<double>[
        for (final index in order)
          ...values.sublist(index * width, (index + 1) * width),
      ]);
  Float32List column(Float32List values) =>
      Float32List.fromList(<double>[for (final index in order) values[index]]);

  return FourdgsGaussianSet(
    positions: rows(gaussians.positions, 3),
    scales: rows(gaussians.scales, 3),
    rotations: rows(gaussians.rotations, 4),
    colors: rows(gaussians.colors, 4),
    motions: rows(gaussians.motions, 3),
    muT: column(gaussians.muT),
    sigmaT: column(gaussians.sigmaT),
    winLo: column(gaussians.winLo),
    winHi: column(gaussians.winHi),
    objectId: Uint32List.fromList(<int>[
      for (final index in order) gaussians.objectId![index],
    ]),
  );
}

Map<String, Object?> _summary(FourdgsGaussianSet gaussians) => summarize(
  header: FourdgsHeader(
    profile: 'default',
    library: 'canonical-order-test',
    durationSec: _duration,
    gaussianCount: gaussians.count,
    cutoff: 0.05,
    temporalModel: 'gaussian-birth',
    aabb: const <double>[0, 0, 0, 0, 0, 0],
    shDegree: 0,
    flags: 0,
    attributes: const <String, String>{},
  ),
  gaussians: gaussians,
  audioSources: const <FourdgsAudioSource>[],
  chunkIntervals: const <(double, double)>[],
);

List<Map<Object?, Object?>> _states(Map<String, Object?> summary) =>
    (summary['states']! as List<Object?>).cast<Map<Object?, Object?>>();

void main() {
  test('rounded stored-key ties do not order composed state samples', () {
    final gaussians = _gaussians(
      const <List<double>>[
        <double>[0, 0, 0],
        <double>[0, 0, 0],
      ],
      const <List<double>>[
        <double>[1e-7, 0, 0],
        <double>[4e-7, 0, 0],
      ],
    );

    final forward = _summary(gaussians);
    final reversed = _summary(_permuted(gaussians, const <int>[1, 0]));

    expect(forward, reversed);
    final stateAtHalf = _states(forward)[1];
    final sample = stateAtHalf['sample']! as Map<Object?, Object?>;
    expect(sample['positions'], <Object?>[
      <Object?>[0.2, 0.0, 0.0],
      <Object?>[0.8, 0.0, 0.0],
    ]);
  });

  test('state aggregates sum in content order', () {
    final gaussians = _gaussians(
      const <List<double>>[
        <double>[1577422159872, 0, 0],
        <double>[1e-4, 0, 0],
        <double>[1e-4, 0, 0],
      ],
      const <List<double>>[
        <double>[0, 0, 0],
        <double>[0, 0, 0],
        <double>[0, 0, 0],
      ],
    );

    final cancellationFirst = _summary(gaussians);
    final cancellationLast = _summary(
      _permuted(gaussians, const <int>[1, 2, 0]),
    );

    expect(cancellationFirst, cancellationLast);
    final aggregate =
        _states(cancellationFirst).first['aggregate']! as Map<Object?, Object?>;
    expect(aggregate['positionSum'], <Object?>[1577422159872.0002, 0.0, 0.0]);
  });
}
