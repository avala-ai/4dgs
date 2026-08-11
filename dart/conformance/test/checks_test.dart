// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

library;

import 'dart:math' as math;
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

  test('rounded finite probes never escape their half-open entry', () {
    final bits = ByteData(8)..setFloat64(0, 1.0, Endian.host);
    final oneBits = bits.getUint64(0, Endian.host);
    bits.setUint64(0, oneBits + 1, Endian.host);
    final adjacent = entry(t0: 1.0, t1: bits.getFloat64(0, Endian.host));
    final probes = seekProbeInstants(adjacent, (_) => 0.0);
    expect(probes.every(adjacent.covers), isTrue);
  });

  test('a narrow support protrusion needs its own quantization guard', () {
    final interval = entry(t0: 0.0, t1: 1.0);
    expect(
      residentSupportWithinEntry(interval, 0.25, 1.000001, 0.0),
      isFalse,
      reason: 'a successful peak probe at 0.5 cannot prove the exposed edge',
    );
    expect(
      residentSupportWithinEntry(interval, 0.25, 1.000001, 0.000002),
      isTrue,
      reason: 'the row-specific quantization guard excuses only its own slack',
    );
  });

  test('visible probes hit point support that fixed fractions miss', () {
    final rotations = Float32List(4)..[3] = 1.0;
    final gaussian = FourdgsGaussianSet(
      positions: Float32List(3),
      scales: Float32List(3)..fillRange(0, 3, 1e-3),
      rotations: rotations,
      colors: Float32List(4),
      motions: Float32List(3),
      muT: Float32List.fromList(const <double>[0.5]),
      sigmaT: Float32List(1),
      winLo: Float32List(1),
      winHi: Float32List.fromList(const <double>[1.0]),
    );
    final interval = entry(t0: 0.0, t1: 1.0);

    expect(seekProbeInstants(interval, (_) => 0.0), isNot(contains(0.5)));
    expect(
      seekVisibleProbeInstants(interval, gaussian, 0.05),
      equals(const <double>[0.5]),
    );
    expect(gaussian.stateAt(0.5).count, 1);
  });

  test('resident point support is selected past four broad rows', () {
    const count = 5;
    final rotations = Float32List(count * 4);
    for (int i = 0; i < count; i++) rotations[i * 4 + 3] = 1.0;
    final gaussians = FourdgsGaussianSet(
      positions: Float32List(count * 3),
      scales: Float32List(count * 3)..fillRange(0, count * 3, 1e-3),
      rotations: rotations,
      colors: Float32List(count * 4),
      motions: Float32List(count * 3),
      muT: Float32List.fromList(const <double>[0.1, 0.2, 0.3, 0.4, 0.75]),
      sigmaT: Float32List.fromList(const <double>[
        double.infinity,
        double.infinity,
        double.infinity,
        double.infinity,
        0.0,
      ]),
      winLo: Float32List(count),
      winHi: Float32List(count)..fillRange(0, count, 1.0),
    );

    expect(
      seekVisibleProbeInstants(
        entry(t0: 0.0, t1: 1.0, gaussianCount: 1),
        gaussians,
        0.05,
        residentStart: 4,
        residentCount: 1,
      ),
      contains(0.75),
    );
  });

  test('stored gaussians in empty windows have no visible support', () {
    final rotations = Float32List(8);
    rotations[3] = 1.0;
    rotations[7] = 1.0;
    final gaussians = FourdgsGaussianSet(
      positions: Float32List(6),
      scales: Float32List(6)..fillRange(0, 6, 1e-3),
      rotations: rotations,
      colors: Float32List(8),
      motions: Float32List(6),
      muT: Float32List.fromList(const <double>[0.0, 1.0]),
      sigmaT: Float32List.fromList(const <double>[1.0, double.infinity]),
      winLo: Float32List.fromList(const <double>[0.0, 2.0]),
      winHi: Float32List.fromList(const <double>[0.0, 2.0]),
    );

    expect(hasAnyVisibleSupport(gaussians, 0.05, 4.0), isFalse);
  });

  test('visible support is clipped to the Header scene clock', () {
    final rotations = Float32List(4)..[3] = 1.0;
    final gaussians = FourdgsGaussianSet(
      positions: Float32List(3),
      scales: Float32List(3)..fillRange(0, 3, 1e-3),
      rotations: rotations,
      colors: Float32List(4),
      motions: Float32List(3),
      muT: Float32List.fromList(const <double>[2.5]),
      sigmaT: Float32List.fromList(const <double>[double.infinity]),
      winLo: Float32List.fromList(const <double>[2.0]),
      winHi: Float32List.fromList(const <double>[3.0]),
    );

    expect(hasAnyVisibleSupport(gaussians, 0.05, 1.0), isFalse);
    expect(hasAnyVisibleSupport(gaussians, 0.05, 4.0), isTrue);
  });

  test('exclusive support ends sort before inclusive ties', () {
    final ends = <({double at, bool inclusive, int row})>[
      (at: 0.5, inclusive: true, row: 0),
      (at: 0.5, inclusive: false, row: 1),
      (at: 0.25, inclusive: true, row: 2),
    ]..sort(compareSeekRowEnds);

    expect(ends.map((event) => event.row), <int>[2, 1, 0]);
  });

  test('sigma-log guard distance uses pitch magnitude', () {
    final positive = seekGuardSigmaHalfRelative(0.1);
    expect(positive, greaterThan(0));
    expect(seekGuardSigmaHalfRelative(-0.1), closeTo(positive, 1e-15));
    expect(positive, closeTo(math.exp(0.05) - 1.0, 1e-15));
  });

  test('birth-time guard distance uses pitch magnitude', () {
    expect(seekGuardMuHalfWidth(0, 0.0, false, 0.25), greaterThan(0.0));
    expect(seekGuardMuHalfWidth(0, 0.0, false, -0.25), 0.125);
  });

  test('seek probes retain every populated entry', () {
    final populated = <FourdgsChunkIndexEntry>[
      for (int i = 0; i < 24; i++) entry(t0: 100.0 + i, t1: 101.0 + i),
    ];
    final index = <FourdgsChunkIndexEntry>[
      for (int i = 0; i < populated.length; i++) ...<FourdgsChunkIndexEntry>[
        entry(t0: i.toDouble(), t1: i.toDouble(), gaussianCount: 0),
        populated[i],
      ],
    ];
    expect(seekProbeEntries(index, isKeyframeDelta: false), equals(populated));
  });

  test('a wide earlier guard reaches across narrower boundaries', () {
    expect(
      seekProbeNearAnyBoundary(
        2.9,
        const <double>[0.0, 2.0, 3.0],
        const <({double at, double guard})>[
          (at: 0.0, guard: 3.0),
          (at: 2.0, guard: 0.0),
          (at: 3.0, guard: 0.0),
        ],
      ),
      isTrue,
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
    final chunks = <FourdgsDecodedChunk>[
      for (final entry in indexed.index)
        await readFourdgsChunk(source, indexed, entry, maxShBand: 0),
    ];
    final beforeSeekProof = source.bytesRead;
    expect(
      (await checkSeekReadsOnlyWhatItNeeds(
        source,
        indexed,
        whole,
        decodedChunks: chunks,
      )).probes,
      greaterThan(0),
    );
    expect(
      source.bytesRead,
      beforeSeekProof,
      reason: 'seek probes reuse the chunks the indexed runner already decoded',
    );
  });

  test('point support inside its guarded entry needs no probe', () async {
    final rotations = Float32List(8);
    rotations[3] = 1.0;
    rotations[7] = 1.0;
    final scene = FourdgsGaussianSet(
      positions: Float32List(6),
      scales: Float32List(6)..fillRange(0, 6, 1e-3),
      rotations: rotations,
      colors: Float32List(8),
      motions: Float32List(6),
      muT: Float32List.fromList(const <double>[0.0, 0.5]),
      sigmaT: Float32List(2),
      winLo: Float32List(2),
      winHi: Float32List(2)..fillRange(0, 2, 1.0),
    );
    final bytes = writeFourdgsBytes(
      scene,
      1.0,
      options: const FourdgsWriteOptions(maxDepth: 1, minChunkGaussians: 1),
    );
    final source = CountingReadable(FourdgsBytes(bytes));
    final indexed = await openFourdgsIndexed(source);
    expect(indexed.index, hasLength(2));

    final result = await checkSeekReadsOnlyWhatItNeeds(
      source,
      indexed,
      readFourdgsBytes(bytes).gaussians,
    );
    expect(result.probes, 0);
    expect(
      result.guardedVisibleCandidates,
      0,
      reason: 'complete support containment replaces a peak candidate',
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
        (await checkSeekReadsOnlyWhatItNeeds(
          source,
          indexed,
          readFourdgsBytes(bytes).gaussians,
        )).probes,
        greaterThan(0),
      );
    },
  );

  test('resident containment clips support to the scene clock', () async {
    final rotations = Float32List(8);
    rotations[3] = 1.0;
    rotations[7] = 1.0;
    final authored = FourdgsGaussianSet(
      positions: Float32List(6),
      scales: Float32List(6)..fillRange(0, 6, 1e-3),
      rotations: rotations,
      colors: Float32List(8),
      motions: Float32List(6),
      muT: Float32List.fromList(const <double>[0.0, 0.75]),
      sigmaT: Float32List.fromList(const <double>[double.infinity, 0.0]),
      winLo: Float32List.fromList(const <double>[-1.0, 0.0]),
      winHi: Float32List.fromList(const <double>[0.25, 1.0]),
    );
    final bytes = writeFourdgsBytes(
      authored,
      1.0,
      options: const FourdgsWriteOptions(maxDepth: 2, minChunkGaussians: 1),
    );
    final source = CountingReadable(FourdgsBytes(bytes));
    final scene = await openFourdgsIndexed(source);
    expect(scene.index.length, greaterThan(1));
    final chunks = <FourdgsDecodedChunk>[
      for (final entry in scene.index)
        await readFourdgsChunk(source, scene, entry, maxShBand: 0),
    ];

    await expectLater(
      checkSeekReadsOnlyWhatItNeeds(
        source,
        scene,
        assembleGaussians(chunks, 0),
        decodedChunks: chunks,
      ),
      completes,
    );
  });
}
