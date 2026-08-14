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
  test('emitted composed rows break rounded stored-key ties', () {
    final gaussians = _gaussians(
      const <List<double>>[
        <double>[1e-7, 0, 0],
        <double>[4e-7, 0, 0],
      ],
      const <List<double>>[
        <double>[4e-7, 0, 0],
        <double>[1e-7, 0, 0],
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

  test('a tie group larger than the sample keeps its lowest emitted rows', () {
    const count = 64;
    final gaussians = _gaussians(
      List<List<double>>.generate(count, (_) => const <double>[0, 0, 0]),
      List<List<double>>.generate(
        count,
        (index) => <double>[(count - index) * 5e-9, 0, 0],
      ),
    );

    final forward = _summary(gaussians);
    final reversed = _summary(
      _permuted(gaussians, <int>[for (int i = count - 1; i >= 0; i--) i]),
    );

    expect(forward, reversed);
    final stateAtHalf = _states(forward)[1];
    final sample = stateAtHalf['sample']! as Map<Object?, Object?>;
    final positions = sample['positions']! as List<Object?>;
    expect(positions, hasLength(sampleSize));
    expect(positions.first, <Object?>[0.01, 0.0, 0.0]);
    expect(positions.last, <Object?>[0.16, 0.0, 0.0]);
  });

  test('state aggregates sum exact canonical units', () {
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
    expect(aggregate['positionSum'], const <Object?>[
      ExactNumber('1577422159872.0002'),
      ExactNumber('0.0'),
      ExactNumber('0.0'),
    ]);
  });

  test('root aggregates cancel in exact canonical units in every order', () {
    final gaussians = _gaussians(
      const <List<double>>[
        <double>[1e20, 0, 0],
        <double>[-1e20, 0, 0],
        <double>[3.25, 0, 0],
      ],
      const <List<double>>[
        <double>[0, 0, 0],
        <double>[0, 0, 0],
        <double>[0, 0, 0],
      ],
    );

    final forward = _summary(gaussians);
    final reversed = _summary(_permuted(gaussians, const <int>[2, 1, 0]));
    expect(forward, reversed);

    final aggregate = forward['aggregate']! as Map<Object?, Object?>;
    expect(aggregate['positionSum'], const <Object?>[
      ExactNumber('3.25'),
      ExactNumber('0.0'),
      ExactNumber('0.0'),
    ]);
    expect(aggregate['opacitySum'], const ExactNumber('3.0'));
  });

  test('exact sums normalize zero and round binary ties to even', () {
    expect(exactSum(<double>[-0.0]), const ExactNumber('0.0'));
    // Both are exactly representable dyadic values whose scaled magnitudes end
    // in .5: the first lower unit is even, the second lower unit is odd.
    expect(exactSum(<double>[0.5078125]), const ExactNumber('0.507812'));
    expect(exactSum(<double>[0.5234375]), const ExactNumber('0.523438'));
    expect(exactSum(<double>[-0.5078125]), const ExactNumber('-0.507812'));
    expect(exactSum(<double>[-0.5234375]), const ExactNumber('-0.523438'));
  });

  test('a non-finite exact-sum addend produces null', () {
    expect(exactSum(<double>[1.0, double.infinity]), isNull);
    expect(exactSum(<double>[1.0, double.nan]), isNull);
  });

  test('num6 rounds halves to even, the way every other emitter does', () {
    // `toStringAsFixed` rounds a half away from zero; Python's `round`, Rust's
    // and C++'s `%.6f`, Swift's `String(format:)` and this file's own
    // `exactSum` all round it to even. Every value a decoder produces is a
    // float32, and an odd multiple of 2^-7 is exactly a six-decimal tie — so
    // the disagreement is not a corner case, it is the whole float32 grid.
    expect(num6(0.0078125), 0.007812);
    expect(num6(0.5078125), 0.507812);
    expect(num6(0.5234375), 0.523438);
    expect(num6(-0.0078125), -0.007812);
    expect(num6(-0.5234375), -0.523438);
    // Not a tie: nothing to decide, and both rules already agreed.
    expect(num6(1.015625), 1.015625);
    expect(num6(1.0 / 3.0), 0.333333);
  });

  test('num6 and exactSum round one value one way', () {
    // The bug this pins: a sample row said 0.007813 while the aggregate over
    // the same column said 0.007812, in one document, and the reference said
    // 0.007812 for both.
    for (final value in <double>[
      0.0078125,
      0.5078125,
      0.5234375,
      -0.0078125,
      -0.5234375,
    ]) {
      // Rounding an already-rounded value is a no-op, so the right-hand side is
      // exactly `num6`'s answer spelled as a token.
      expect(
        exactSum(<double>[value])!.token,
        exactSum(<double>[num6(value)!])!.token,
        reason: 'num6 and exactSum disagree at $value',
      );
    }
  });

  test('a rounded zero is never signed, in the key or in the output', () {
    expect(num6(-1e-9), 0.0);
    expect(num6(-1e-9)!.isNegative, isFalse);
    expect(num6(-0.0)!.isNegative, isFalse);
    // `-0.0 == 0.0` is true, so the assertions above need `isNegative` to say
    // anything. This one is what the harness actually compares.
    expect(
      canonical(<String, Object?>{'v': num6(-1e-9)}),
      contains('"v": 0.0'),
    );
    expect(
      canonical(<String, Object?>{'v': num6(-0.0)}),
      isNot(contains('-0')),
    );
  });

  test('signed zero cannot order a state sample', () {
    // Two gaussians alike but for where the sign of a zero sits. They tie in
    // every emitted value, so the two decode orders must produce one document
    // — which they do not while `compareTo` puts `-0.0` before `0.0`.
    final gaussians = _gaussians(
      const <List<double>>[
        <double>[-0.0, 0.0, 0.0],
        <double>[0.0, -0.0, 0.0],
      ],
      const <List<double>>[
        <double>[0, 0, 0],
        <double>[0, 0, 0],
      ],
    );

    final forward = _summary(gaussians);
    final reversed = _summary(_permuted(gaussians, const <int>[1, 0]));

    expect(canonical(forward), canonical(reversed));
    expect(canonical(forward), isNot(contains('-0.0')));
  });

  test('huge exact totals remain raw non-exponent JSON number tokens', () {
    final sum = exactSum(List<double>.filled(10, 1e308))!;
    final whole = sum.token.split('.').first;
    expect(whole.length, greaterThan(309));
    expect(sum.token, isNot(contains(RegExp('[eE]'))));
    expect(sum.token, endsWith('.0'));

    final rendered = canonical(<String, Object?>{'sum': sum});
    expect(rendered, contains('"sum": ${sum.token}'));
    expect(rendered, isNot(contains('"${sum.token}"')));
  });
}
