// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The `keyframe-delta` encoder, against this package's own two readers.
///
/// Every file written here is decoded back on both paths, because the paths fail
/// differently: the streamed one never looks at the index, so a wrong offset, a
/// wrong `live_count` or a broken chain decodes perfectly there and only the
/// seeking client notices. The cross-language claim — that a Dart-written
/// sequence reconstructs identically in Python and Rust — is made by
/// `dart/encode-roundtrip.sh`, which diffs against expectations a Python-written
/// file produced; these are the unit-level facts underneath it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';
import 'package:test/test.dart';

const double _duration = 8.0;

class _RecordingSink implements Sink<List<int>> {
  final parts = <Uint8List>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    parts.add(Uint8List.fromList(data));
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    for (final part in parts) {
      out.add(part);
    }
    return out.takeBytes();
  }
}

FourdgsGaussianSet _population(
  List<List<double>> positions, {
  double sigma = 100.0,
  List<double>? winLo,
  List<double>? winHi,
  List<List<double>>? motions,
  List<List<double>>? rotations_,
  List<double>? muT,
  int shDegree = 0,
  Uint8List? sh,
  int shCoefficients = 0,
  Int32List? sourceGroup,
  Int32List? sourceIndex,
  Uint32List? objectId,
}) {
  final n = positions.length;
  final pos = Float32List(n * 3);
  final scales = Float32List(n * 3);
  final rotations = Float32List(n * 4);
  final colors = Float32List(n * 4);
  final velocity = Float32List(n * 3);
  final lo = Float32List(n);
  final hi = Float32List(n);
  for (int i = 0; i < n; i++) {
    for (int axis = 0; axis < 3; axis++) {
      pos[i * 3 + axis] = positions[i][axis];
      scales[i * 3 + axis] = 0.05;
      velocity[i * 3 + axis] = motions == null ? 0.0 : motions[i][axis];
    }
    if (rotations_ == null) {
      rotations[i * 4 + 3] = 1.0;
    } else {
      for (int c = 0; c < 4; c++) {
        rotations[i * 4 + c] = rotations_[i][c];
      }
    }
    colors[i * 4] = 0.6;
    colors[i * 4 + 1] = 0.4;
    colors[i * 4 + 2] = 0.2;
    colors[i * 4 + 3] = 0.9;
    lo[i] = winLo == null ? 0.0 : winLo[i];
    hi[i] = winHi == null ? _duration : winHi[i];
  }
  return FourdgsGaussianSet(
    positions: pos,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: velocity,
    muT: Float32List.fromList(muT ?? List<double>.filled(n, 0.0)),
    sigmaT: Float32List(n)..fillRange(0, n, sigma),
    winLo: lo,
    winHi: hi,
    shDegree: shDegree,
    sh: sh,
    shCoefficients: shCoefficients,
    sourceGroup: sourceGroup,
    sourceIndex: sourceIndex,
    objectId: objectId,
  );
}

/// Four gaussians drifting over eight samples. No births, no deaths, so every
/// delta is a pure update.
List<FourdgsSample> _drift({int steps = 8}) => <FourdgsSample>[
  for (int i = 0; i < steps; i++)
    FourdgsSample(
      t0: i * (_duration / steps),
      ids: const <int>[0, 1, 2, 3],
      gaussians: _population(<List<double>>[
        <double>[i * 0.1, 0.0, 0.0],
        <double>[1.0, i * 0.05, 0.0],
        <double>[0.0, 1.0, i * 0.03],
        <double>[1.0, 1.0, 0.0],
      ]),
    ),
];

/// The same drift with one birth (id 4, from sample 2) and one death (id 2,
/// from sample 5).
List<FourdgsSample> _churn() {
  final samples = <FourdgsSample>[];
  for (int i = 0; i < 8; i++) {
    final ids = <int>[0, 1, 2, 3];
    final rows = <List<double>>[
      <double>[i * 0.1, 0.0, 0.0],
      <double>[1.0, i * 0.05, 0.0],
      <double>[0.0, 1.0, 0.0],
      <double>[1.0, 1.0, 0.0],
    ];
    if (i >= 2) {
      ids.add(4);
      rows.add(<double>[2.0, 2.0, i * 0.02]);
    }
    if (i >= 5) {
      final at = ids.indexOf(2);
      ids.removeAt(at);
      rows.removeAt(at);
    }
    samples.add(
      FourdgsSample(t0: i * 1.0, ids: ids, gaussians: _population(rows)),
    );
  }
  return samples;
}

List<FourdgsChunkIndexEntry> _index(Uint8List data) =>
    decodeKeyframeDeltaIndexed(data).index;

FourdgsDeltaChunkBody _deltaChunkAt(Uint8List data, int offset) {
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    if (record.offset == offset) return parseDeltaChunk(record.content);
  }
  throw StateError('no record at $offset');
}

Set<int> _attributesIn(Uint8List group) {
  final cursor = FourdgsCursor(group);
  final got = <int>{};
  while (cursor.remaining > 0) {
    final header = readStreamHeader(cursor);
    decodeAttributeStreamBody(cursor, header);
    got.add(header.attributeId);
  }
  return got;
}

void main() {
  group('the streaming output', () {
    test('matches the in-memory convenience without closing the sink', () {
      final sink = _RecordingSink();
      writeKeyframeDeltaToSink(sink, _churn(), _duration);

      expect(sink.parts.length, greaterThan(1));
      expect(sink.closed, isFalse);
      expect(
        sink.finish(),
        orderedEquals(writeKeyframeDeltaBytes(_churn(), _duration)),
      );
    });

    test('names read-back verification as unavailable on a one-way sink', () {
      expect(
        () => writeKeyframeDeltaToSink(
          _RecordingSink(),
          _churn(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(verify: true),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput error) => error.message,
            'message',
            allOf(
              contains('one-way sink'),
              contains('writeKeyframeDeltaBytes'),
            ),
          ),
        ),
      );
    });
  });

  group('the round trip', () {
    test('the two read paths reach the same populations', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final streamed = decodeKeyframeDeltaStreamed(data);
      final indexed = decodeKeyframeDeltaIndexed(data).sequence;
      expect(
        keyframeDeltaStatesJson(indexed),
        equals(keyframeDeltaStatesJson(streamed)),
      );
    });

    test('the composed population is the sample that went in', () {
      final samples = _drift();
      final data = writeKeyframeDeltaBytes(
        samples,
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      for (int i = 0; i < samples.length; i++) {
        final got = keyframeDeltaPopulation(sequence, sequence.chunks[i]);
        expect(got.count, samples[i].gaussians.count);
        expect(got.sourceGroup, isNull);
        expect(got.sourceIndex, isNull);
        expect(got.objectId, isNull);
        for (int row = 0; row < got.count; row++) {
          final source = samples[i].ids.indexOf(got.ids[row]);
          expect(source, isNonNegative);
          for (int axis = 0; axis < 3; axis++) {
            expect(
              got.positions[row * 3 + axis],
              closeTo(
                samples[i].gaussians.positions[source * 3 + axis],
                2.5e-3,
              ),
            );
          }
        }
      }
    });

    test('an off-grid sample anchor preserves its authored centre', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[10.0, 0.0, 0.0],
            ],
          ),
        ),
        FourdgsSample(
          // The default profile's reference mu_t pitch is 0.004 seconds.
          t0: 0.003,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[1.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[10.0, 0.0, 0.0],
            ],
          ),
        ),
      ];
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
        ),
      );
      final states =
          keyframeDeltaStatesJson(sequence)['states']! as List<Object?>;
      final atSample = states.cast<Map<String, Object?>>().firstWhere(
        (Map<String, Object?> row) => row['t'] == 0.003,
      );
      final state = atSample['sample']! as Map<String, Object?>;
      final positions = state['positions']! as List<Object?>;
      final first = positions.first! as List<Object?>;
      expect(first.first! as double, closeTo(1.0, 2.5e-3));
    });

    test('two encodes of one sequence are the same bytes', () {
      final a = writeKeyframeDeltaBytes(_churn(), _duration);
      final b = writeKeyframeDeltaBytes(_churn(), _duration);
      expect(b, equals(a));
    });

    test('the header names the model and the file closes with the magic', () {
      final data = writeKeyframeDeltaBytes(_drift(), _duration);
      final header = decodeKeyframeDeltaStreamed(data).header;
      expect(header.temporalModel, 'keyframe-delta');
      expect(header.durationSec, _duration);
      expect(
        Uint8List.sublistView(data, data.length - fourdgsMagic.length),
        equals(fourdgsMagic),
      );
    });

    test('the keyframe-delta reader refuses a gaussian-birth file by name', () {
      final birth = writeFourdgsBytes(
        _population(<List<double>>[
          <double>[0.0, 0.0, 0.0],
        ]),
        _duration,
      );
      expect(
        () => decodeKeyframeDeltaStreamed(birth),
        throwsA(
          isA<FourdgsMalformedFile>().having(
            (FourdgsMalformedFile e) => e.message,
            'message',
            contains('gaussian-birth'),
          ),
        ),
      );
    });
  });

  group('the counting rules', () {
    test('gaussian_count is distinct ids, not a sum over chunks', () {
      // Five ids ever live, over eight chunks whose populations sum to 35.
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(sequence.header.gaussianCount, 5);
      final summed = sequence.chunks.fold<int>(
        0,
        (int total, KeyframeDeltaChunk c) => total + c.state.count,
      );
      expect(summed, 35);
    });

    test('a delta entry counts operations and states its population apart', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final index = _index(data);
      final sequence = decodeKeyframeDeltaStreamed(data);
      for (int i = 0; i < index.length; i++) {
        final entry = index[i];
        expect(entry.extended, isTrue);
        expect(entry.liveCount, sequence.chunks[i].state.count);
        if (entry.kind == 0) {
          expect(entry.gaussianCount, entry.liveCount);
          continue;
        }
        final chunk = sequence.chunks[i];
        expect(
          entry.gaussianCount,
          chunk.updateCount! + chunk.birthCount! + chunk.deathCount!,
        );
      }
      // Sample 2 births id 4 and moves two of the four already live, so it is
      // three operations over a population of five — the two numbers a reader
      // that confused them would report interchangeably.
      final birthing = index[2];
      expect(birthing.kind, 1);
      expect(sequence.chunks[2].birthCount, 1);
      expect(sequence.chunks[2].updateCount, 2);
      expect(birthing.gaussianCount, 3);
      expect(birthing.liveCount, 5);
    });

    test('live_count is stated on keyframe entries too', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
      );
      for (final entry in _index(data)) {
        expect(entry.kind, 0);
        expect(entry.liveCount, greaterThan(0));
      }
      // And the indexed reader cross-checks it, so a zero here is not merely
      // untidy — it is a file this SDK refuses. Rewrite one entry's live_count
      // and watch it happen.
      final broken = Uint8List.fromList(data);
      final entry = _index(data).first;
      final at = _liveCountOffset(broken, entry);
      for (int i = 0; i < 8; i++) {
        broken[at + i] = 0;
      }
      expect(
        () => decodeKeyframeDeltaIndexed(broken),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('every chunk kind written is 0 or 1', () {
      for (final mode in <int>[deltaModeChained, deltaModeKeyframe]) {
        final data = writeKeyframeDeltaBytes(
          _churn(),
          _duration,
          options: FourdgsKeyframeDeltaOptions(
            keyframeEvery: 4,
            deltaMode: mode,
          ),
        );
        for (final entry in _index(data)) {
          expect(entry.kind, anyOf(0, 1));
        }
      }
    });
  });

  group('the timeline', () {
    test('state chunks tile it: no overlap, no gap', () {
      final data = writeKeyframeDeltaBytes(_drift(), _duration);
      final index = _index(data);
      expect(index.first.t0, 0.0);
      expect(index.last.t1, _duration);
      for (int i = 1; i < index.length; i++) {
        expect(index[i].t0, index[i - 1].t1);
      }
      // checkTiling is what the indexed reader applies; say so directly.
      checkTiling(index);
    });

    test('a sequence that does not start at 0 is refused', () {
      final samples = _drift();
      final shifted = <FourdgsSample>[
        FourdgsSample(
          t0: 0.5,
          ids: samples.first.ids,
          gaussians: samples.first.gaussians,
        ),
        ...samples.skip(1),
      ];
      expect(
        () => writeKeyframeDeltaBytes(shifted, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('tiles [0, duration_sec)'),
          ),
        ),
      );
    });

    test('sample instants that go backwards are refused', () {
      final samples = _drift();
      final scrambled = <FourdgsSample>[
        samples[0],
        FourdgsSample(
          t0: 4.0,
          ids: samples[1].ids,
          gaussians: samples[1].gaussians,
        ),
        FourdgsSample(
          t0: 2.0,
          ids: samples[2].ids,
          gaussians: samples[2].gaussians,
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(scrambled, _duration),
        throwsA(isA<FourdgsInvalidInput>()),
      );
    });

    test('a zero-width interval with a population behind it is refused', () {
      final samples = _drift();
      final doubled = <FourdgsSample>[
        samples[0],
        FourdgsSample(
          t0: 1.0,
          ids: samples[1].ids,
          gaussians: samples[1].gaussians,
        ),
        FourdgsSample(
          t0: 1.0,
          ids: samples[2].ids,
          gaussians: samples[2].gaussians,
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(doubled, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('zero-width interval'),
          ),
        ),
      );
    });
  });

  group('cadence and mode', () {
    test('a cadence of one writes every sample as a keyframe', () {
      final data = writeKeyframeDeltaBytes(
        _drift(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(
        sequence.chunks.every((KeyframeDeltaChunk c) => c.kind == 0),
        true,
      );
      expect(
        sequence.chunks.every((KeyframeDeltaChunk c) => c.depth == 0),
        true,
      );
    });

    test('chained deltas deepen; keyframe-referenced ones do not', () {
      final chained = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
        ),
      );
      expect(
        chained.chunks.map((KeyframeDeltaChunk c) => c.depth).toList(),
        <int>[0, 1, 2, 3, 0, 1, 2, 3],
      );

      final referenced = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(
            keyframeEvery: 4,
            deltaMode: deltaModeKeyframe,
          ),
        ),
      );
      expect(
        referenced.chunks.map((KeyframeDeltaChunk c) => c.depth).toList(),
        <int>[0, 1, 1, 1, 0, 1, 1, 1],
      );
    });

    test('keyframeAt forces one where the cadence would not', () {
      final data = writeKeyframeDeltaBytes(
        _drift(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(
          keyframeEvery: 0,
          keyframeAt: <int>{5},
        ),
      );
      final kinds =
          decodeKeyframeDeltaStreamed(
            data,
          ).chunks.map((KeyframeDeltaChunk c) => c.kind).toList();
      expect(kinds, <int>[0, 1, 1, 1, 1, 0, 1, 1]);
    });

    test(
      'an overflowing chained GOP is refused before the sink sees bytes',
      () {
        final empty = _population(const <List<double>>[]);
        final samples = <FourdgsSample>[
          for (int i = 0; i <= 0x10000; i++)
            FourdgsSample(
              t0: i.toDouble(),
              ids: const <int>[],
              gaussians: empty,
            ),
        ];
        final sink = _RecordingSink();
        expect(
          () => writeKeyframeDeltaToSink(
            sink,
            samples,
            samples.length.toDouble(),
            options: const FourdgsKeyframeDeltaOptions(
              keyframeEvery: 0,
              verify: false,
            ),
          ),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput error) => error.message,
              'message',
              allOf(contains('sample 65536'), contains('past the 65535')),
            ),
          ),
        );
        expect(sink.parts, isEmpty);
      },
    );

    test('a keyframe anchors every gaussian at its own sample time', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[1.0, 0.0, 0.0],
            ],
          ),
        ),
        FourdgsSample(
          t0: 4.0,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[10.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[1.0, 0.0, 0.0],
            ],
            // Deliberately contradictory authoring metadata: a keyframe states
            // its position at t0, so the writer must not preserve this older
            // origin and advect the sample away from the point it states.
            muT: const <double>[0.0],
          ),
        ),
      ];
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
        ),
      );
      final stated = keyframeDeltaPopulation(sequence, sequence.chunks[1]);
      expect(stated.muT.single, closeTo(4.0, 1e-6));
      expect(
        stated.positions[0] + stated.motions[0] * (4.0 - stated.muT[0]),
        closeTo(10.0, 2.5e-3),
      );
    });

    test('a delta anchors every stated gaussian at its sample time', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[1.0, 0.0, 0.0],
            ],
          ),
        ),
        FourdgsSample(
          t0: 4.0,
          ids: const <int>[7],
          gaussians: _population(
            const <List<double>>[
              <double>[10.0, 0.0, 0.0],
            ],
            motions: const <List<double>>[
              <double>[1.0, 0.0, 0.0],
            ],
            // Deliberately stale authoring metadata. The changed position
            // causes a delta update, whose state is stated at this sample's t0.
            muT: const <double>[0.0],
          ),
        ),
      ];
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 8),
        ),
      );
      final stated = keyframeDeltaPopulation(sequence, sequence.chunks[1]);
      expect(sequence.chunks[1].kind, 1);
      expect(stated.muT.single, closeTo(4.0, 1e-6));
      expect(
        stated.positions[0] + stated.motions[0] * (4.0 - stated.muT[0]),
        closeTo(10.0, 2.5e-3),
      );
    });

    test('moving rows update when an inherited anchor misses the sample', () {
      final samples = <FourdgsSample>[
        for (final t0 in const <double>[0.0, 4.0])
          FourdgsSample(
            t0: t0,
            ids: const <int>[7],
            gaussians: _population(
              const <List<double>>[
                <double>[0.0, 0.0, 0.0],
              ],
              motions: const <List<double>>[
                <double>[1.0, 0.0, 0.0],
              ],
            ),
          ),
      ];
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 8),
        ),
      );

      expect(sequence.chunks[1].updateCount, 1);
      final stated = keyframeDeltaPopulation(sequence, sequence.chunks[1]);
      expect(stated.muT.single, closeTo(4.0, 1e-6));
      expect(
        stated.positions[0] + stated.motions[0] * (4.0 - stated.muT[0]),
        closeTo(0.0, 2.5e-3),
      );
    });

    test('a delta_mode the format does not define is refused', () {
      expect(
        () => writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(deltaMode: 2),
        ),
        throwsA(isA<FourdgsInvalidInput>()),
      );
    });

    test('negative cadence and out-of-range forced samples are refused', () {
      expect(
        () => writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: -1),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('keyframe_every is -1'),
          ),
        ),
      );
      expect(
        () => writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeAt: <int>{8}),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('outside this sequence'),
          ),
        ),
      );
    });
  });

  group('the groups a delta carries', () {
    test('births and deaths land where they belong', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(sequence.chunks[2].birthCount, 1);
      expect(sequence.chunks[2].deathCount, 0);
      expect(sequence.chunks[5].deathCount, 1);
      expect(sequence.chunks[5].birthCount, 0);
      expect(sequence.chunks[1].birthCount, 0);
      expect(sequence.chunks[1].deathCount, 0);
    });

    test('an update carries no GOP-invariant attribute, and no more', () {
      final data = writeKeyframeDeltaBytes(
        _drift(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final index = _index(data);
      final body = _deltaChunkAt(data, index[1].chunkOffset);
      final carried = _attributesIn(body.updates);
      expect(carried, contains(attrGaussianId));
      for (final attribute in keyframeDeltaGopInvariant) {
        expect(carried, isNot(contains(attribute)));
      }
      // A birth is absolute state, so it carries all eleven plus identity.
      expect(body.births, isEmpty);
    });

    test('a birth group states every attribute absolutely', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final index = _index(data);
      final body = _deltaChunkAt(data, index[2].chunkOffset);
      final carried = _attributesIn(body.births);
      expect(carried, containsAll(requiredAttributes));
      expect(carried, contains(attrGaussianId));
    });

    test('a death group is identity and nothing else', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final index = _index(data);
      final body = _deltaChunkAt(data, index[5].chunkOffset);
      expect(_attributesIn(body.deaths), <int>{attrGaussianId});
    });

    test('an empty group is no bytes at all', () {
      final data = writeKeyframeDeltaBytes(
        _drift(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final index = _index(data);
      final body = _deltaChunkAt(data, index[1].chunkOffset);
      expect(body.births, isEmpty);
      expect(body.deaths, isEmpty);
    });

    test('a gaussian nothing touched costs no bytes in the update', () {
      // Only id 0 moves after the keyframe; the other three are byte-identical.
      final samples = <FourdgsSample>[
        for (int i = 0; i < 4; i++)
          FourdgsSample(
            t0: i * 2.0,
            ids: const <int>[0, 1, 2, 3],
            gaussians: _population(<List<double>>[
              <double>[i * 0.5, 0.0, 0.0],
              <double>[1.0, 0.0, 0.0],
              <double>[0.0, 1.0, 0.0],
              <double>[1.0, 1.0, 0.0],
            ]),
          ),
      ];
      final data = writeKeyframeDeltaBytes(
        samples,
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(sequence.chunks[1].updateCount, 1);
      expect(sequence.chunks[1].state.count, 4);
    });

    test('a turning gaussian is restated, not differenced', () {
      // 25 degrees about z per sample, in one group of eight, so the largest
      // quaternion component stops being `w` and becomes `z` between samples 3
      // and 4 — inside the group rather than at a keyframe. Either side of that
      // crossing the three stored bins mean different components, so a
      // difference of them is a number with no interpretation: composing it
      // produces an orientation nobody wrote. Restating is what makes the
      // crossing survivable, and this is the sequence that reaches it.
      List<List<double>> quaternion(int i) {
        final half = i * 25.0 * math.pi / 360.0;
        return <List<double>>[
          <double>[0.0, 0.0, math.sin(half), math.cos(half)],
        ];
      }

      final samples = <FourdgsSample>[
        for (int i = 0; i < 8; i++)
          FourdgsSample(
            t0: i * 1.0,
            ids: const <int>[0],
            gaussians: _population(<List<double>>[
              <double>[0.0, 0.0, 0.0],
            ], rotations_: quaternion(i)),
          ),
      ];
      final data = writeKeyframeDeltaBytes(
        samples,
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 8),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(
        sequence.chunks.where((KeyframeDeltaChunk c) => c.kind == 0),
        hasLength(1),
      );

      int crossings = 0;
      for (int i = 0; i < samples.length; i++) {
        final rows = keyframeDeltaPopulation(sequence, sequence.chunks[i]);
        final want = quaternion(i).single;
        double dot = 0.0;
        for (int c = 0; c < 4; c++) {
          dot += rows.rotations[c] * want[c];
        }
        expect(
          dot.abs(),
          closeTo(1.0, 1e-4),
          reason: 'sample $i came back turned to somewhere else',
        );
        // The basis really does change: `w` is largest early and `z` late.
        if (i > 0 && want[2].abs() > want[3].abs()) crossings++;
      }
      expect(crossings, greaterThan(0));
      // And the indexed path composes the same chain to the same orientation.
      final indexed = decodeKeyframeDeltaIndexed(data).sequence;
      expect(
        keyframeDeltaStatesJson(indexed),
        equals(keyframeDeltaStatesJson(sequence)),
      );
    });

    test('a per-gaussian grid that changes mid-group is refused', () {
      final samples = _drift(steps: 4).toList();
      // sigma_t derives the velocity and birth-time grids, so a change in it
      // between two samples of one group subtracts bins on different grids.
      samples[1] = FourdgsSample(
        t0: samples[1].t0,
        ids: samples[1].ids,
        gaussians: _population(<List<double>>[
          <double>[0.1, 0.0, 0.0],
          <double>[1.0, 0.05, 0.0],
          <double>[0.0, 1.0, 0.03],
          <double>[1.0, 1.0, 0.0],
        ], sigma: 2.0),
      );
      final sink = _RecordingSink();
      expect(
        () => writeKeyframeDeltaToSink(
          sink,
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(
            keyframeEvery: 4,
            verify: false,
          ),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('gaussian id 0'), contains('Emit a keyframe')),
          ),
        ),
      );
      expect(
        sink.parts,
        isEmpty,
        reason:
            'invalid GOPs must be refused before caller-owned output starts',
      );
    });

    test(
      'a post-keyframe birth keeps its invariant state for its lifetime',
      () {
        final samples = <FourdgsSample>[
          FourdgsSample(
            t0: 0.0,
            ids: const <int>[],
            gaussians: _population(const <List<double>>[]),
          ),
          FourdgsSample(
            t0: 2.0,
            ids: const <int>[7],
            gaussians: _population(<List<double>>[
              <double>[0.0, 0.0, 0.0],
            ], sigma: 2.0),
          ),
          FourdgsSample(
            t0: 4.0,
            ids: const <int>[7],
            gaussians: _population(<List<double>>[
              <double>[0.1, 0.0, 0.0],
            ], sigma: 3.0),
          ),
        ];
        expect(
          () => writeKeyframeDeltaBytes(
            samples,
            _duration,
            options: const FourdgsKeyframeDeltaOptions(
              keyframeEvery: 4,
              deltaMode: deltaModeKeyframe,
            ),
          ),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(
                contains('sample 2'),
                contains('gaussian id 7'),
                contains('continuous lifetime'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('what a sample may say', () {
    test('an id cannot reappear after its death, even at a keyframe', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[7],
          gaussians: _population(<List<double>>[
            <double>[0.0, 0.0, 0.0],
          ]),
        ),
        FourdgsSample(
          t0: 2.0,
          ids: const <int>[],
          gaussians: _population(const <List<double>>[]),
        ),
        FourdgsSample(
          t0: 4.0,
          ids: const <int>[7],
          gaussians: _population(<List<double>>[
            <double>[1.0, 0.0, 0.0],
          ]),
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(
          samples,
          _duration,
          options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 2),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sample 2'), contains('id 7'), contains('death')),
          ),
        ),
      );
    });

    test('a delta that does not fit int32 is refused before it wraps', () {
      FourdgsSample sample(double t0, double motion) => FourdgsSample(
        t0: t0,
        ids: const <int>[7],
        gaussians: _population(
          const <List<double>>[
            <double>[0.0, 0.0, 0.0],
          ],
          motions: <List<double>>[
            <double>[motion, 0.0, 0.0],
          ],
        ),
      );

      final samples = <FourdgsSample>[
        sample(0.0, -3000000.0),
        sample(4.0, 3000000.0),
      ];
      final matcher = throwsA(
        isA<FourdgsInvalidInput>().having(
          (FourdgsInvalidInput e) => e.message,
          'message',
          allOf(
            contains('gaussian id 7'),
            contains('motion component 0'),
            contains('signed 32-bit'),
            contains('keyframeAt'),
          ),
        ),
      );
      expect(() => writeKeyframeDeltaBytes(samples, _duration), matcher);

      final sink = _RecordingSink();
      expect(() => writeKeyframeDeltaToSink(sink, samples, _duration), matcher);
      expect(
        sink.parts,
        isEmpty,
        reason: 'a deterministic bad delta must be refused before magic bytes',
      );
    });

    test('the population API refuses unretained spherical harmonics', () {
      final decoded = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(_drift(steps: 2), _duration),
      );
      final header = FourdgsHeader(
        profile: decoded.header.profile,
        library: decoded.header.library,
        durationSec: decoded.header.durationSec,
        gaussianCount: decoded.header.gaussianCount,
        cutoff: decoded.header.cutoff,
        temporalModel: decoded.header.temporalModel,
        aabb: decoded.header.aabb,
        shDegree: 1,
        flags: decoded.header.flags,
        attributes: decoded.header.attributes,
      );
      final withSh = KeyframeDeltaSequence(
        header: header,
        quantization: decoded.quantization,
        windows: decoded.windows,
        chunks: decoded.chunks,
      );
      expect(
        () => keyframeDeltaPopulation(withSh, withSh.chunks.last),
        throwsA(
          isA<FourdgsUnsupportedFeature>().having(
            (FourdgsUnsupportedFeature e) => e.message,
            'message',
            allOf(
              contains('sh_degree 1'),
              contains('SH Band Stream'),
              contains('refusing'),
            ),
          ),
        ),
      );
    });

    test('object_id updates remain bin differences', () {
      expect(keyframeDeltaAbsoluteInUpdate, isNot(contains(attrObjectId)));
    });

    test('spherical harmonics are refused instead of discarded', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[1],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            shDegree: 1,
            shCoefficients: 3,
            sh: Uint8List(9),
          ),
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(samples, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sample 0'), contains('spherical harmonics')),
          ),
        ),
      );
    });

    test('optional identity lanes are refused instead of discarded', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[1],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            sourceGroup: Int32List.fromList(const <int>[11]),
            sourceIndex: Int32List.fromList(const <int>[17]),
            objectId: Uint32List.fromList(const <int>[23]),
          ),
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(samples, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(
              contains('source_group'),
              contains('source_index'),
              contains('object_id'),
              contains('discarding exact labels'),
            ),
          ),
        ),
      );
    });

    test('gaussian ids use the complete unsigned 32-bit domain', () {
      final samples = <FourdgsSample>[
        for (final t in const <double>[0.0, 4.0])
          FourdgsSample(
            t0: t,
            ids: const <int>[0xFFFFFFFF],
            gaussians: _population(const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ]),
          ),
      ];
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(samples, _duration),
      );
      // The public population exposes the format's unsigned identity domain;
      // signed same-bits symbols stay an internal stream representation.
      expect(
        keyframeDeltaPopulation(sequence, sequence.chunks.last).ids.single,
        0xFFFFFFFF,
      );
    });

    test('lossy clamps and malformed temporal bounds are refused', () {
      final badColor = _population(const <List<double>>[
        <double>[0.0, 0.0, 0.0],
      ]);
      badColor.colors[0] = 1.25;
      final negativeSigma = _population(const <List<double>>[
        <double>[0.0, 0.0, 0.0],
      ]);
      negativeSigma.sigmaT[0] = -0.5;
      final invertedWindow = _population(
        const <List<double>>[
          <double>[0.0, 0.0, 0.0],
        ],
        winLo: const <double>[5.0],
        winHi: const <double>[4.0],
      );

      void rejects(FourdgsGaussianSet gaussians, String fragment) {
        expect(
          () => writeKeyframeDeltaBytes(<FourdgsSample>[
            FourdgsSample(t0: 0.0, ids: const <int>[1], gaussians: gaussians),
          ], _duration),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              contains(fragment),
            ),
          ),
        );
      }

      rejects(badColor, 'stored in [0, 1]');
      rejects(negativeSigma, 'temporal standard deviation');
      rejects(invertedWindow, 'lower bound is above');
    });

    test('a repeated id in one sample is refused', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[1, 1],
          gaussians: _population(<List<double>>[
            <double>[0.0, 0.0, 0.0],
            <double>[1.0, 0.0, 0.0],
          ]),
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(samples, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('appears twice'),
          ),
        ),
      );
    });

    test('an id count that does not match the population is refused', () {
      final samples = <FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[1],
          gaussians: _population(<List<double>>[
            <double>[0.0, 0.0, 0.0],
            <double>[1.0, 0.0, 0.0],
          ]),
        ),
      ];
      expect(
        () => writeKeyframeDeltaBytes(samples, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sample 0'), contains('ids')),
          ),
        ),
      );
    });

    test('a non-finite position names the sample and the gaussian', () {
      final samples = _drift(steps: 2);
      samples[1].gaussians.positions[3] = double.nan;
      expect(
        () => writeKeyframeDeltaBytes(samples, _duration),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sample 1'), contains('gaussian 1')),
          ),
        ),
      );
    });

    test('a positive scale below 1e-30 keeps the relative bound', () {
      final sample = FourdgsSample(
        t0: 0.0,
        ids: const <int>[7],
        gaussians: _population(const <List<double>>[
          <double>[0.0, 0.0, 0.0],
        ]),
      );
      final source = Float32List.fromList(<double>[1e-35]).single;
      sample.gaussians.scales[1] = source;
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(<FourdgsSample>[sample], _duration),
      );
      final population = keyframeDeltaPopulation(
        sequence,
        sequence.chunks.single,
      );
      final bound = double.parse(sequence.quantization.bounds['scale_rel']!);
      expect(
        (population.scales[1] / source - 1.0).abs(),
        lessThanOrEqualTo(bound),
      );
    });

    test('a positive sigma below 1e-30 keeps the relative bound', () {
      final source = Float32List.fromList(<double>[1e-35]).single;
      final sample = FourdgsSample(
        t0: 0.0,
        ids: const <int>[7],
        gaussians: _population(const <List<double>>[
          <double>[0.0, 0.0, 0.0],
        ], sigma: source),
      );
      final sequence = decodeKeyframeDeltaStreamed(
        writeKeyframeDeltaBytes(<FourdgsSample>[sample], _duration),
      );
      final population = keyframeDeltaPopulation(
        sequence,
        sequence.chunks.single,
      );
      final bound = double.parse(sequence.quantization.bounds['sigma_rel']!);
      expect(
        (population.sigmaT.single / source - 1.0).abs(),
        lessThanOrEqualTo(bound),
      );
    });

    test('an empty sequence is refused rather than written', () {
      expect(
        () => writeKeyframeDeltaBytes(<FourdgsSample>[], _duration),
        throwsA(isA<FourdgsInvalidInput>()),
      );
    });

    test('an unknown profile lists the ones that exist', () {
      expect(
        () => writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(profile: 'blurry'),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            contains('coarse'),
          ),
        ),
      );
    });

    test('a codec this build cannot write is named rather than attempted', () {
      expect(
        () => writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(codec: codecZstd),
        ),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
    });

    test(
      'an invalid deflate level is authoring input, not a backend error',
      () {
        expect(
          () => writeKeyframeDeltaBytes(
            _drift(),
            _duration,
            options: const FourdgsKeyframeDeltaOptions(level: 10),
          ),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('deflate level is 10'), contains('0 to 9')),
            ),
          ),
        );
      },
    );
  });

  group('validity windows', () {
    test('several windows are written and indexed, not collapsed to one', () {
      final samples = <FourdgsSample>[
        for (int i = 0; i < 4; i++)
          FourdgsSample(
            t0: i * 2.0,
            ids: const <int>[0, 1, 2, 3],
            gaussians: _population(
              <List<double>>[
                <double>[i * 0.1, 0.0, 0.0],
                <double>[1.0, i * 0.05, 0.0],
                <double>[0.0, 1.0, i * 0.03],
                <double>[1.0, 1.0, 0.0],
              ],
              winLo: const <double>[0.0, 0.0, 4.0, 4.0],
              winHi: const <double>[4.0, 4.0, 8.0, 8.0],
            ),
          ),
      ];
      final data = writeKeyframeDeltaBytes(
        samples,
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      expect(sequence.windows.length, 2);
      final rows = keyframeDeltaPopulation(sequence, sequence.chunks.first);
      expect(rows.windowIndex.toList(), <int>[0, 0, 1, 1]);

      // A gaussian is absent outside its own window, so half the population is
      // gone at t = 6 — the fact the single-window corpus cannot state.
      final json = keyframeDeltaStatesJson(sequence);
      final states = json['states']! as List<Object?>;
      final late_ = states.firstWhere(
        (Object? row) => (row! as Map<String, Object?>)['t'] == 6.0,
      );
      expect((late_! as Map<String, Object?>)['liveCount'], '2');
    });

    test('a never-fading gaussian keeps its infinity through the sequence', () {
      final samples = <FourdgsSample>[
        for (int i = 0; i < 4; i++)
          FourdgsSample(
            t0: i * 2.0,
            ids: const <int>[0, 1],
            gaussians: _population(<List<double>>[
              <double>[i * 0.1, 0.0, 0.0],
              <double>[1.0, i * 0.05, 0.0],
            ], sigma: double.infinity),
          ),
      ];
      final data = writeKeyframeDeltaBytes(
        samples,
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final sequence = decodeKeyframeDeltaStreamed(data);
      final rows = keyframeDeltaPopulation(sequence, sequence.chunks.last);
      expect(rows.sigmaT.every((double v) => v.isInfinite), isTrue);
    });

    test('a NaN window is refused, an infinite one is not', () {
      FourdgsSample sample(double hi) => FourdgsSample(
        t0: 0.0,
        ids: const <int>[0],
        gaussians: _population(
          <List<double>>[
            <double>[0.0, 0.0, 0.0],
          ],
          winLo: const <double>[0.0],
          winHi: <double>[hi],
        ),
      );
      expect(
        () => writeKeyframeDeltaBytes(<FourdgsSample>[sample(double.nan)], 4.0),
        throwsA(isA<FourdgsInvalidInput>()),
      );
      expect(
        writeKeyframeDeltaBytes(<FourdgsSample>[sample(double.infinity)], 4.0),
        isA<Uint8List>(),
      );
    });

    test('an empty window cannot have equal infinite endpoints', () {
      for (final endpoint in const <double>[
        double.negativeInfinity,
        double.infinity,
      ]) {
        final sample = FourdgsSample(
          t0: 0.0,
          ids: const <int>[0],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            sigma: double.infinity,
            winLo: <double>[endpoint],
            winHi: <double>[endpoint],
          ),
        );
        expect(
          () => writeKeyframeDeltaBytes(<FourdgsSample>[sample], 4.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput error) => error.message,
              'message',
              allOf(contains('sample 0'), contains('infinite endpoints')),
            ),
          ),
        );
      }
    });

    test('the final state may cover an open-ended scene', () {
      final data = writeKeyframeDeltaBytes(<FourdgsSample>[
        FourdgsSample(
          t0: 0.0,
          ids: const <int>[0],
          gaussians: _population(
            const <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
            winHi: const <double>[double.infinity],
          ),
        ),
      ], double.infinity);
      final streamed = decodeKeyframeDeltaStreamed(data);
      final indexed = decodeKeyframeDeltaIndexed(data);
      expect(streamed.header.durationSec, double.infinity);
      expect(streamed.chunks.single.t1, double.infinity);
      expect(indexed.index.single.t1, double.infinity);
    });

    test('the Window Table ceiling is enforced before writing a record', () {
      final n = maxWindowsPerScene + 1;
      final positions = <List<double>>[
        for (int i = 0; i < n; i++) <double>[i.toDouble(), 0.0, 0.0],
      ];
      final winLo = <double>[for (int i = 0; i < n; i++) i.toDouble()];
      final winHi = <double>[for (int i = 0; i < n; i++) (i + 1).toDouble()];
      expect(
        () => writeKeyframeDeltaBytes(<FourdgsSample>[
          FourdgsSample(
            t0: 0.0,
            ids: <int>[for (int i = 0; i < n; i++) i],
            gaussians: _population(positions, winLo: winLo, winHi: winHi),
          ),
        ], n.toDouble()),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(
              contains('$maxWindowsPerScene'),
              contains('Window Table ceiling'),
            ),
          ),
        ),
      );
    });
  });

  group('the summary', () {
    test('an index cannot exceed the indexed reader ceiling', () {
      final empty = FourdgsSample(
        t0: 0.0,
        ids: const <int>[],
        gaussians: FourdgsGaussianSet.empty(),
      );
      expect(
        () => writeKeyframeDeltaBytes(
          List<FourdgsSample>.filled(maxChunkIndexEntries + 1, empty),
          0.0,
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(
              contains('${maxChunkIndexEntries + 1} state chunks'),
              contains('$maxChunkIndexEntries entries'),
            ),
          ),
        ),
      );
    });

    test('the Footer points at the first byte of the Chunk Index', () {
      final data = writeKeyframeDeltaBytes(_drift(), _duration);
      FourdgsFooter? footer;
      int? firstIndexRecord;
      for (final record in iterRecords(data, fourdgsMagic.length)) {
        if (record.opcode == opChunkIndex) {
          firstIndexRecord ??= record.offset;
        } else if (record.opcode == opFooter) {
          footer = FourdgsFooter.parse(record.content);
        }
      }
      expect(footer, isNotNull);
      expect(footer!.summaryStart, firstIndexRecord);
      expect(footer.summaryCrc, isNot(0));
    });

    test(
      'a file written without a CRC declares zero rather than a wrong one',
      () {
        final data = writeKeyframeDeltaBytes(
          _drift(),
          _duration,
          options: const FourdgsKeyframeDeltaOptions(writeCrc: false),
        );
        for (final record in iterRecords(data, fourdgsMagic.length)) {
          if (record.opcode == opFooter) {
            expect(FourdgsFooter.parse(record.content).summaryCrc, 0);
          }
        }
      },
    );

    test('Statistics counts distinct ids and chunks', () {
      final data = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      FourdgsStatistics? statistics;
      for (final record in iterRecords(data, fourdgsMagic.length)) {
        if (record.opcode == opStatistics) {
          statistics = FourdgsStatistics.parse(record.content);
        }
      }
      expect(statistics, isNotNull);
      expect(statistics!.gaussianCount, 5);
      expect(statistics.chunkCount, 8);
    });

    test('Header and Statistics bound the positions readers reconstruct', () {
      final data = writeKeyframeDeltaBytes(_churn(), _duration);
      final sequence = decodeKeyframeDeltaStreamed(data);
      final lo = List<double>.filled(3, double.infinity);
      final hi = List<double>.filled(3, double.negativeInfinity);
      for (final chunk in sequence.chunks) {
        final population = keyframeDeltaPopulation(sequence, chunk);
        for (int row = 0; row < population.count; row++) {
          for (int axis = 0; axis < 3; axis++) {
            final value = population.positions[row * 3 + axis];
            if (value < lo[axis]) lo[axis] = value;
            if (value > hi[axis]) hi[axis] = value;
          }
        }
      }
      final reconstructed = <double>[...lo, ...hi];
      expect(sequence.header.aabb, reconstructed);

      FourdgsStatistics? statistics;
      for (final record in iterRecords(data, fourdgsMagic.length)) {
        if (record.opcode == opStatistics) {
          statistics = FourdgsStatistics.parse(record.content);
        }
      }
      expect(statistics!.aabb, reconstructed);
    });

    test('a file written without an index is still a whole file', () {
      final data = writeKeyframeDeltaBytes(
        _drift(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(writeIndex: false),
      );
      expect(decodeKeyframeDeltaStreamed(data).chunks.length, 8);
      expect(
        () => decodeKeyframeDeltaIndexed(data),
        throwsA(isA<FourdgsException>()),
      );
    });
  });

  group('the grid', () {
    test('one set of pitches serves the whole sequence', () {
      final data = writeKeyframeDeltaBytes(_churn(), _duration);
      final quantization = decodeKeyframeDeltaStreamed(data).quantization;
      expect(quantization.scheme, 'uniform-v1');
      // Twice the position bound, which is 5 % of the sequence's median radius.
      expect(quantization.stepPos, closeTo(2 * 0.05 * 0.05, 1e-9));
      expect(quantization.bounds['pos'], isNotNull);
      // The origin is the sequence minimum over every sample, not the first
      // sample's — a later sample that reaches further back would otherwise bin
      // negative against a grid the file says starts at zero.
      expect(quantization.posOrigin, <double>[0.0, 0.0, 0.0]);
    });

    test('a coarser profile declares a coarser grid', () {
      double pitch(String profile) =>
          decodeKeyframeDeltaStreamed(
            writeKeyframeDeltaBytes(
              _drift(),
              _duration,
              options: FourdgsKeyframeDeltaOptions(profile: profile),
            ),
          ).quantization.stepPos;
      expect(pitch('fine'), lessThan(pitch('default')));
      expect(pitch('default'), lessThan(pitch('coarse')));
    });
  });
}

/// Where an index entry's `live_count` sits in the file.
///
/// The extended block is the last thing in the record, and `live_count` is the
/// last field in it.
int _liveCountOffset(Uint8List data, FourdgsChunkIndexEntry entry) {
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    if (record.opcode != opChunkIndex) continue;
    final parsed = FourdgsChunkIndexEntry.parse(record.content);
    if (parsed.chunkOffset != entry.chunkOffset) continue;
    return record.offset + recordHeaderBytes + record.content.length - 8;
  }
  throw StateError('no index entry for the chunk at ${entry.chunkOffset}');
}
