// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/checks.dart';
import 'package:test/test.dart';

void main() {
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
}
