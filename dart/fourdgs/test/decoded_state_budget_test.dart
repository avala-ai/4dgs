// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';
import 'package:test/test.dart';

FourdgsGaussianSet _oneGaussian() => FourdgsGaussianSet(
  positions: Float32List.fromList(<double>[0, 0, 0]),
  scales: Float32List.fromList(<double>[1, 1, 1]),
  rotations: Float32List.fromList(<double>[0, 0, 0, 1]),
  colors: Float32List.fromList(<double>[1, 1, 1, 1]),
  motions: Float32List.fromList(<double>[0, 0, 0]),
  muT: Float32List.fromList(<double>[0]),
  sigmaT: Float32List.fromList(<double>[double.infinity]),
  winLo: Float32List.fromList(<double>[0]),
  winHi: Float32List.fromList(<double>[1]),
);

Matcher _resourceLimit(String phase, {int limit = 1}) =>
    isA<FourdgsReaderLimit>()
        .having((error) => error.refusalCode, 'refusal', isNull)
        .having((error) => error.message, 'resource', contains('decoded-state'))
        .having((error) => error.message, 'limit', contains('$limit bytes'))
        .having((error) => error.message, 'phase', contains(phase))
        .having((error) => error.message, 'required', contains('required'));

void main() {
  late Uint8List bytes;

  setUpAll(() {
    bytes = writeFourdgsBytes(_oneGaussian(), 1.0);
  });

  test('the shared default is 512 MiB', () {
    expect(defaultMaxDecodedStateBytes, 536870912);
  });

  test('streamed collection checks before decode allocation', () {
    expect(
      () => readFourdgsBytes(bytes, maxDecodedStateBytes: 1),
      throwsA(_resourceLimit('streamed Chunk decode')),
    );
  });

  test(
    'indexed collection shares the caller budget with chunk decode',
    () async {
      final source = FourdgsBytes(bytes);
      final scene = await openFourdgsIndexed(source);
      final budget = FourdgsDecodedStateBudget(1);

      await expectLater(
        readFourdgsChunk(
          source,
          scene,
          scene.index.single,
          decodedStateBudget: budget,
        ),
        throwsA(_resourceLimit('indexed Chunk decode')),
      );
      expect(budget.retainedBytes, 0);
    },
  );

  test('public assembly checks before allocation', () async {
    final source = FourdgsBytes(bytes);
    final scene = await openFourdgsIndexed(source);
    final chunk = await readFourdgsChunk(source, scene, scene.index.single);

    expect(
      () => assembleGaussians(
        <FourdgsDecodedChunk>[chunk],
        scene.header.shDegree,
        maxDecodedStateBytes: 1,
      ),
      throwsA(_resourceLimit('final scene assembly')),
    );
    expect(
      assembleGaussians(
        <FourdgsDecodedChunk>[chunk],
        scene.header.shDegree,
        maxDecodedStateBytes: gaussianSetAssemblyBytes(<FourdgsDecodedChunk>[
          chunk,
        ]),
      ).count,
      1,
    );
  });

  test('checked row arithmetic cannot wrap around a tiny budget', () {
    final budget = FourdgsDecodedStateBudget(8);
    expect(
      () => budget.checkRows(0x7FFFFFFFFFFFFFFF, 104, 'hostile row count'),
      throwsA(_resourceLimit('hostile row count', limit: 8)),
    );
  });

  test('limits are strict positive integers', () {
    for (final value in <int>[0, -1]) {
      expect(
        () => readFourdgsBytes(bytes, maxDecodedStateBytes: value),
        throwsArgumentError,
      );
      expect(
        () => assembleGaussians(
          const <FourdgsDecodedChunk>[],
          0,
          maxDecodedStateBytes: value,
        ),
        throwsArgumentError,
      );
    }

    expect(
      () => assembleGaussians(
        const <FourdgsDecodedChunk>[],
        0,
        maxDecodedStateBytes: 1,
        decodedStateBudget: FourdgsDecodedStateBudget(2),
      ),
      throwsArgumentError,
      reason: 'two competing limits must not silently ignore either one',
    );

    final dynamic streamed = readFourdgsBytes;
    final dynamic assembled = assembleGaussians;
    for (final value in <Object>[true, 1.5, double.infinity]) {
      expect(
        // ignore: avoid_dynamic_calls
        () => streamed(bytes, maxDecodedStateBytes: value),
        throwsA(isA<TypeError>()),
      );
      expect(
        // ignore: avoid_dynamic_calls
        () => assembled(
          const <FourdgsDecodedChunk>[],
          0,
          maxDecodedStateBytes: value,
        ),
        throwsA(isA<TypeError>()),
      );
    }
  });
}
