// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';
import 'package:test/test.dart';

const int _positionStep = 0;
const int _scaleStep = 1;
const int _motionStep = 5;
const int _timeStep = 6;
const int _sigmaStep = 7;

FourdgsGaussianSet _gaussians(
  List<double> scales,
  double duration, {
  double sigma = 1.0,
  double motionX = 0.0,
}) {
  final n = scales.length;
  final rotations = Float32List(n * 4);
  final colors = Float32List(n * 4);
  final motions = Float32List(n * 3);
  for (int row = 0; row < n; row++) {
    rotations[row * 4 + 3] = 1.0;
    colors[row * 4] = 0.5;
    colors[row * 4 + 1] = 0.5;
    colors[row * 4 + 2] = 0.5;
    colors[row * 4 + 3] = 1.0;
    motions[row * 3] = motionX;
  }
  return FourdgsGaussianSet(
    positions: Float32List(n * 3),
    scales: Float32List.fromList(<double>[
      for (final scale in scales) ...<double>[scale, 1.0, 1.0],
    ]),
    rotations: rotations,
    colors: colors,
    motions: motions,
    muT: Float32List(n),
    sigmaT: Float32List(n)..fillRange(0, n, sigma),
    winLo: Float32List(n),
    winHi: Float32List(n)..fillRange(0, n, duration),
  );
}

({int quantization, List<int> chunks, List<int> deltas}) _recordOffsets(
  Uint8List data,
) {
  int quantization = -1;
  final chunks = <int>[];
  final deltas = <int>[];
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    switch (record.opcode) {
      case opQuantization:
        quantization = record.offset;
      case opChunk:
        chunks.add(record.offset);
      case opDeltaChunk:
        deltas.add(record.offset);
    }
  }
  if (quantization < 0) {
    throw StateError('test file has no Quantization record');
  }
  return (quantization: quantization, chunks: chunks, deltas: deltas);
}

Uint8List _withStep(Uint8List original, int index, double value) {
  final data = Uint8List.fromList(original);
  final offsets = _recordOffsets(data);
  final content = offsets.quantization + recordHeaderBytes;
  final view = ByteData.sublistView(data);
  final schemeLength = view.getUint32(content, Endian.little);
  final steps = content + 4 + schemeLength + 3 * 8;
  view.setFloat64(steps + index * 8, value, Endian.little);
  return data;
}

Matcher _overflow(int offset, String rowKind, Iterable<String> details) =>
    isA<FourdgsMalformedFile>()
        .having(
          (error) => error.refusalCode,
          'refusal code',
          refusalDecodedF32Overflow,
        )
        .having(
          (error) => error.message,
          'diagnostic',
          allOf(<Matcher>[
            contains('opcode at byte $offset'),
            contains('$rowKind row 0'),
            contains('attribute scale component x'),
            contains('step_scale_log 1.0'),
            contains('expected a finite binary32 value'),
            ...details.map(contains),
          ]),
        );

void _expectKeyframeDeltaOverflow(Uint8List data, Matcher matcher) {
  expect(() => decodeKeyframeDeltaStreamed(data), throwsA(matcher));
  expect(() => decodeKeyframeDeltaIndexed(data), throwsA(matcher));
}

Future<FourdgsDecodedChunk> _indexedGaussianBirth(Uint8List data) async {
  final source = FourdgsBytes(data);
  final scene = await openFourdgsIndexed(source);
  return readFourdgsChunk(source, scene, scene.index.single);
}

void main() {
  group('decoded-f32-overflow', () {
    test(
      'gaussian-birth refuses the same physical Chunk on both paths',
      () async {
        final data = _withStep(
          writeFourdgsBytes(
            _gaussians(<double>[math.exp(4.0)], 1.0),
            1.0,
            options: const FourdgsWriteOptions(shBands: 0),
          ),
          _scaleStep,
          1.0,
        );
        final chunk = _recordOffsets(data).chunks.single;
        final matcher = _overflow(chunk, 'gaussian-birth', <String>[
          'stored log bin',
        ]);

        expect(() => readFourdgsBytes(data), throwsA(matcher));
        await expectLater(_indexedGaussianBirth(data), throwsA(matcher));
      },
    );

    test('keyframe rows are checked before their bins become public state', () {
      final data = _withStep(
        writeKeyframeDeltaBytes(<FourdgsSample>[
          FourdgsSample(
            t0: 0.0,
            ids: const <int>[7],
            gaussians: _gaussians(<double>[math.exp(4.0)], 1.0),
          ),
        ], 1.0),
        _scaleStep,
        1.0,
      );
      final chunk = _recordOffsets(data).chunks.single;

      _expectKeyframeDeltaOverflow(
        data,
        _overflow(chunk, 'keyframe', <String>[
          'gaussian_id 7',
          'stored/composed absolute bin',
        ]),
      );
    });

    test('update rows name stored deltas and composed bins', () {
      final ordinaryStep = 2.0 * math.log(1.02);
      final data = _withStep(
        writeKeyframeDeltaBytes(
          <FourdgsSample>[
            FourdgsSample(
              t0: 0.0,
              ids: const <int>[7],
              gaussians: _gaussians(<double>[
                math.exp(88.0 * ordinaryStep),
              ], 2.0),
            ),
            FourdgsSample(
              t0: 1.0,
              ids: const <int>[7],
              gaussians: _gaussians(<double>[
                math.exp(89.0 * ordinaryStep),
              ], 2.0),
            ),
          ],
          2.0,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 0),
        ),
        _scaleStep,
        1.0,
      );
      final delta = _recordOffsets(data).deltas.single;

      _expectKeyframeDeltaOverflow(
        data,
        _overflow(delta, 'update', <String>[
          'gaussian_id 7',
          'stored delta bin 1 and composed bin 89',
        ]),
      );
    });

    test('birth rows are attributed to the Delta Chunk', () {
      final data = _withStep(
        writeKeyframeDeltaBytes(
          <FourdgsSample>[
            FourdgsSample(
              t0: 0.0,
              ids: const <int>[7],
              gaussians: _gaussians(const <double>[1.0], 2.0),
            ),
            FourdgsSample(
              t0: 1.0,
              ids: const <int>[7, 8],
              gaussians: _gaussians(<double>[1.0, math.exp(4.0)], 2.0),
            ),
          ],
          2.0,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 0),
        ),
        _scaleStep,
        1.0,
      );
      final delta = _recordOffsets(data).deltas.single;

      _expectKeyframeDeltaOverflow(
        data,
        _overflow(delta, 'birth', <String>[
          'gaussian_id 8',
          'stored/composed absolute bin',
        ]),
      );
    });

    test(
      'the validator maps the refusal to the physical state record',
      () async {
        final data = _withStep(
          writeFourdgsBytes(
            _gaussians(<double>[math.exp(4.0)], 1.0),
            1.0,
            options: const FourdgsWriteOptions(shBands: 0),
          ),
          _scaleStep,
          1.0,
        );
        final chunk = _recordOffsets(data).chunks.single;

        final report = await validateFourdgs(FourdgsBytes(data));
        final finding = report.findings.singleWhere(
          (finding) => finding.refusal?.code == refusalDecodedF32Overflow,
        );
        expect(finding.refusal!.site!.offset, chunk);
        expect(finding.refusal!.site!.what, 'the Chunk record');
      },
    );
  });

  group('legal binary32 boundaries', () {
    test(
      'max-f64 derived steps preserve zero bins on both read paths',
      () async {
        var data = writeFourdgsBytes(
          _gaussians(const <double>[1.0], 0.0),
          0.0,
          options: const FourdgsWriteOptions(shBands: 0),
        );
        for (final step in <int>[
          _positionStep,
          _scaleStep,
          _motionStep,
          _timeStep,
          _sigmaStep,
        ]) {
          data = _withStep(data, step, double.maxFinite);
        }

        final streamed = readFourdgsBytes(data).gaussians;
        final indexed = await _indexedGaussianBirth(data);
        expect(streamed.positions, everyElement(0.0));
        expect(streamed.scales, everyElement(1.0));
        expect(streamed.motions, everyElement(0.0));
        expect(streamed.muT, everyElement(0.0));
        expect(streamed.sigmaT, everyElement(1.0));
        expect(indexed.positions, everyElement(0.0));
        expect(indexed.motions, everyElement(0.0));
        expect(indexed.muT, everyElement(0.0));
        expect(indexed.sigmaT, everyElement(1.0));
      },
    );

    test(
      'keyframe-delta keeps zero bins valid when a derived step is infinite',
      () {
        const duration = 1e-9;
        var data = writeKeyframeDeltaBytes(<FourdgsSample>[
          FourdgsSample(
            t0: 0.0,
            ids: const <int>[7],
            gaussians: _gaussians(
              const <double>[1.0],
              duration,
              sigma: double.infinity,
            ),
          ),
        ], duration);
        for (final step in <int>[
          _positionStep,
          _scaleStep,
          _motionStep,
          _timeStep,
          _sigmaStep,
        ]) {
          data = _withStep(data, step, double.maxFinite);
        }

        final streamed = decodeKeyframeDeltaStreamed(data);
        final indexed = decodeKeyframeDeltaIndexed(data).sequence;
        final streamedPopulation = keyframeDeltaPopulation(
          streamed,
          streamed.chunks.single,
        );
        final indexedPopulation = keyframeDeltaPopulation(
          indexed,
          indexed.chunks.single,
        );
        expect(streamedPopulation.positions, everyElement(0.0));
        expect(streamedPopulation.scales, everyElement(1.0));
        expect(streamedPopulation.motions, everyElement(0.0));
        expect(streamedPopulation.muT, everyElement(0.0));
        expect(streamedPopulation.sigmaT, everyElement(double.infinity));
        expect(indexedPopulation.positions, everyElement(0.0));
        expect(indexedPopulation.scales, everyElement(1.0));
        expect(indexedPopulation.motions, everyElement(0.0));
        expect(indexedPopulation.muT, everyElement(0.0));
        expect(indexedPopulation.sigmaT, everyElement(double.infinity));
      },
    );

    test(
      'never_fades +Infinity and ordinary underflow remain values',
      () async {
        final neverFades = writeFourdgsBytes(
          _gaussians(const <double>[1.0], 1.0, sigma: double.infinity),
          1.0,
          options: const FourdgsWriteOptions(shBands: 0),
        );
        expect(
          readFourdgsBytes(neverFades).gaussians.sigmaT.single,
          double.infinity,
        );
        expect(
          (await _indexedGaussianBirth(neverFades)).sigmaT.single,
          double.infinity,
        );

        final underflow = _withStep(
          writeFourdgsBytes(
            _gaussians(const <double>[1.0], 1.0, sigma: 1e-35),
            1.0,
            options: const FourdgsWriteOptions(shBands: 0),
          ),
          _sigmaStep,
          1.0,
        );
        expect(readFourdgsBytes(underflow).gaussians.sigmaT.single, 0.0);
        expect((await _indexedGaussianBirth(underflow)).sigmaT.single, 0.0);

        final signedZero = _withStep(
          writeFourdgsBytes(
            _gaussians(const <double>[1.0], 1.0, motionX: -0.25),
            1.0,
            options: const FourdgsWriteOptions(shBands: 0),
          ),
          _motionStep,
          double.minPositive,
        );
        final streamedMotion =
            readFourdgsBytes(signedZero).gaussians.motions[0];
        final indexedMotion =
            (await _indexedGaussianBirth(signedZero)).motions[0];
        expect(streamedMotion, 0.0);
        expect(streamedMotion.isNegative, isTrue);
        expect(indexedMotion, 0.0);
        expect(indexedMotion.isNegative, isTrue);
      },
    );
  });
}
