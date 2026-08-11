// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/checks.dart';
import 'package:test/test.dart';

void main() {
  FourdgsChunkIndexEntry entry({
    required double t0,
    required double t1,
    int gaussianCount = 1,
  }) => FourdgsChunkIndexEntry(
    t0: t0,
    t1: t1,
    chunkOffset: 0,
    chunkLength: 0,
    gaussianCount: gaussianCount,
    bands: const <FourdgsBandRange>[],
  );

  test('seek probes cover degenerate pitches and unbounded starts', () {
    expect(seekGuardSigmaBin(1.0, 0.0), 0);

    for (final interval in <FourdgsChunkIndexEntry>[
      entry(t0: double.negativeInfinity, t1: 4.0),
      entry(t0: double.negativeInfinity, t1: double.infinity),
    ]) {
      final probes = seekProbeInstants(interval, (_) => 0.0);
      expect(probes, isNotEmpty);
      expect(probes.every((t) => t.isFinite), isTrue);
      expect(probes.every(interval.covers), isTrue);
    }
  });

  test('seek entry cap is applied after unusable entries are removed', () {
    final populated = entry(t0: 100.0, t1: 101.0);
    final index = <FourdgsChunkIndexEntry>[
      for (int i = 0; i < 40; i++)
        if (i == 23)
          populated
        else
          entry(t0: i.toDouble(), t1: i.toDouble(), gaussianCount: 0),
    ];
    expect(
      boundedSeekProbeEntries(index, isKeyframeDelta: false),
      equals(<FourdgsChunkIndexEntry>[populated]),
    );
  });

  test('seek proof samples indexes made only of open-ended entries', () async {
    final rotations = Float32List(8);
    rotations[3] = 1.0;
    rotations[7] = 1.0;
    final scene = FourdgsGaussianSet(
      positions: Float32List(6),
      scales: Float32List(6)..fillRange(0, 6, 1e-3),
      rotations: rotations,
      colors: Float32List(8),
      motions: Float32List(6),
      muT: Float32List(2),
      sigmaT: Float32List(2)..fillRange(0, 2, double.infinity),
      winLo: Float32List.fromList(const <double>[0.0, 1.0]),
      winHi: Float32List(2)..fillRange(0, 2, double.infinity),
    );
    final bytes = writeFourdgsBytes(
      scene,
      double.infinity,
      options: const FourdgsWriteOptions(maxDepth: 0, minChunkGaussians: 1),
    );
    final source = CountingReadable(FourdgsBytes(bytes));
    final indexed = await openFourdgsIndexed(source);
    expect(indexed.index, hasLength(2));
    expect(indexed.index.every((entry) => entry.t1.isInfinite), isTrue);

    final whole = readFourdgsBytes(bytes).gaussians;
    expect(
      await checkSeekReadsOnlyWhatItNeeds(source, indexed, whole),
      greaterThan(0),
    );
  });

  test(
    'one broad gaussian does not suppress unrelated boundary probes',
    () async {
      const count = 9;
      final rotations = Float32List(count * 4);
      for (int i = 0; i < count; i++) rotations[i * 4 + 3] = 1.0;
      final scene = FourdgsGaussianSet(
        positions: Float32List(count * 3),
        scales: Float32List(count * 3)..fillRange(0, count * 3, 1e-3),
        rotations: rotations,
        colors: Float32List(count * 4),
        motions: Float32List(count * 3),
        muT: Float32List.fromList(<double>[
          4.0,
          0.5,
          1.5,
          2.5,
          3.5,
          4.5,
          5.5,
          6.5,
          7.5,
        ]),
        sigmaT: Float32List.fromList(<double>[
          1000.0,
          0.02,
          0.02,
          0.02,
          0.02,
          0.02,
          0.02,
          0.02,
          0.02,
        ]),
        winLo: Float32List(count),
        winHi: Float32List(count)..fillRange(0, count, 8.0),
      );
      final bytes = writeFourdgsBytes(
        scene,
        8.0,
        options: const FourdgsWriteOptions(maxDepth: 4, minChunkGaussians: 1),
      );
      final source = CountingReadable(FourdgsBytes(bytes));
      final indexed = await openFourdgsIndexed(source);
      expect(indexed.index.length, greaterThan(1));

      expect(
        await checkSeekReadsOnlyWhatItNeeds(
          source,
          indexed,
          readFourdgsBytes(bytes).gaussians,
        ),
        greaterThan(0),
      );
    },
  );
}
