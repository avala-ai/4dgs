// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for the two decoded Chunk Index count claims (§5.8).
library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';
import 'package:test/test.dart';

const double _duration = 7.0;

final class _CountMutation {
  const _CountMutation(this.bytes, this.entry, this.observed);

  final Uint8List bytes;
  final FourdgsChunkIndexEntry entry;
  final int observed;
}

final class _RecordingReadable implements FourdgsReadable {
  _RecordingReadable(this.bytes);

  final Uint8List bytes;
  final List<({int offset, int length})> reads = <({int offset, int length})>[];

  @override
  Future<int> size() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset: offset, length: length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

List<FourdgsRecord> _records(Uint8List bytes) =>
    iterRecords(bytes, fourdgsMagic.length).toList();

List<FourdgsChunkIndexEntry> _index(Uint8List bytes) =>
    <FourdgsChunkIndexEntry>[
      for (final FourdgsRecord record in _records(bytes))
        if (record.opcode == opChunkIndex)
          FourdgsChunkIndexEntry.parse(
            record.content,
            fileOffset: record.offset + recordHeaderBytes,
          ),
    ];

FourdgsDeltaChunkHeader _deltaHeader(
  Uint8List bytes,
  FourdgsChunkIndexEntry entry,
) =>
    parseDeltaChunk(
      _records(bytes)
          .firstWhere(
            (FourdgsRecord record) => record.offset == entry.chunkOffset,
          )
          .content,
    ).header;

/// Change only one count and repair the Footer checksum covering the summary.
_CountMutation _withWrongIndexCount(
  Uint8List source,
  String field,
  bool Function(FourdgsChunkIndexEntry entry) choose,
) {
  final Uint8List bytes = Uint8List.fromList(source);
  final FourdgsRecord indexRecord = _records(bytes).firstWhere(
    (FourdgsRecord record) =>
        record.opcode == opChunkIndex &&
        choose(FourdgsChunkIndexEntry.parse(record.content)),
  );
  final FourdgsChunkIndexEntry original = FourdgsChunkIndexEntry.parse(
    indexRecord.content,
  );
  final ByteData view = ByteData.sublistView(bytes);
  final int contentAt = indexRecord.offset + recordHeaderBytes;
  late final int observed;
  if (field == 'gaussian_count') {
    observed = original.gaussianCount;
    view.setUint32(contentAt + 32, observed + 1, Endian.little);
  } else {
    observed = original.liveCount;
    final int bandCount = view.getUint32(contentAt + 36, Endian.little);
    final int extensionAt = contentAt + 40 + bandCount * bandRangeBytes;
    view.setUint64(extensionAt + 20, observed + 1, Endian.little);
  }

  final FourdgsRecord footerRecord = _records(
    bytes,
  ).lastWhere((FourdgsRecord record) => record.opcode == opFooter);
  final FourdgsFooter footer = FourdgsFooter.parse(footerRecord.content);
  view.setUint32(
    footerRecord.offset + recordHeaderBytes + 16,
    fourdgsCrc32(
      Uint8List.sublistView(bytes, footer.summaryStart, footerRecord.offset),
    ),
    Endian.little,
  );

  final FourdgsChunkIndexEntry entry = FourdgsChunkIndexEntry.parse(
    _records(bytes)
        .firstWhere(
          (FourdgsRecord record) => record.offset == indexRecord.offset,
        )
        .content,
  );
  return _CountMutation(bytes, entry, observed);
}

Matcher _diagnostic(_CountMutation mutation, String field, String observation) {
  return isA<FourdgsMalformedFile>()
      .having(
        (FourdgsMalformedFile error) => error.refusalCode,
        'refusal',
        refusalIndexRecordMismatch,
      )
      .having(
        (FourdgsMalformedFile error) => error.message,
        'diagnostic',
        _diagnosticText(mutation, field, observation),
      );
}

String _diagnosticText(
  _CountMutation mutation,
  String field,
  String observation,
) {
  final int declared =
      field == 'gaussian_count'
          ? mutation.entry.gaussianCount
          : mutation.entry.liveCount;
  return 'the chunk index entry at ${mutation.entry.chunkOffset} declares '
      '$field $declared; $observation is ${mutation.observed}';
}

FourdgsGaussianSet _population(List<int> ids, int step) {
  final int count = ids.length;
  final Float32List positions = Float32List(count * 3);
  final Float32List scales = Float32List(count * 3);
  final Float32List rotations = Float32List(count * 4);
  final Float32List colors = Float32List(count * 4);
  for (int row = 0; row < count; row++) {
    final int id = ids[row];
    positions[row * 3] = id == 0 ? step * 0.1 : id.toDouble();
    positions[row * 3 + 1] = id.toDouble();
    scales[row * 3] = 0.05;
    scales[row * 3 + 1] = 0.05;
    scales[row * 3 + 2] = 0.05;
    rotations[row * 4 + 3] = 1.0;
    colors[row * 4] = 0.6;
    colors[row * 4 + 1] = 0.4;
    colors[row * 4 + 2] = 0.2;
    colors[row * 4 + 3] = 0.9;
  }
  return FourdgsGaussianSet(
    positions: positions,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: Float32List(count * 3),
    muT: Float32List(count),
    sigmaT: Float32List(count)..fillRange(0, count, 100.0),
    winLo: Float32List(count),
    winHi: Float32List(count)..fillRange(0, count, _duration),
  );
}

List<FourdgsSample> _churn() => <FourdgsSample>[
  for (int step = 0; step < 7; step++)
    FourdgsSample(
      t0: step.toDouble(),
      ids: <int>[0, 1, if (step < 5) 2, 3, if (step >= 2) 4],
      gaussians: _population(<int>[
        0,
        1,
        if (step < 5) 2,
        3,
        if (step >= 2) 4,
      ], step),
    ),
];

void main() {
  test(
    'gaussian-birth verifies decoded rows on streamed and indexed reads',
    () async {
      final Uint8List original = writeFourdgsBytes(
        _population(<int>[0], 0),
        _duration,
      );
      final _CountMutation mutation = _withWrongIndexCount(
        original,
        'gaussian_count',
        (_) => true,
      );
      final Matcher expected = _diagnostic(
        mutation,
        'gaussian_count',
        "the decoded Chunk's validated gaussian row count",
      );

      expect(() => readFourdgsBytes(mutation.bytes), throwsA(expected));

      final FourdgsIndexedScene scene = await openFourdgsIndexed(
        FourdgsBytes(original),
      );
      await expectLater(
        readFourdgsChunk(FourdgsBytes(mutation.bytes), scene, mutation.entry),
        throwsA(expected),
      );
    },
  );

  test(
    'keyframe-delta verifies both staged witnesses on every decoded path',
    () async {
      final Uint8List original = writeKeyframeDeltaBytes(
        _churn(),
        _duration,
        options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
      );
      final List<FourdgsChunkIndexEntry> originalIndex = _index(original);
      final FourdgsChunkIndexEntry staged = originalIndex.firstWhere((entry) {
        if (entry.kind != 1) return false;
        final FourdgsDeltaChunkHeader head = _deltaHeader(original, entry);
        final int operations =
            head.updateCount + head.birthCount + head.deathCount;
        return operations != entry.liveCount &&
            originalIndex.any(
              (candidate) => candidate.referenceOffset == entry.chunkOffset,
            );
      });

      for (final String field in <String>['gaussian_count', 'live_count']) {
        final _CountMutation mutation = _withWrongIndexCount(
          original,
          field,
          (entry) => entry.chunkOffset == staged.chunkOffset,
        );
        final List<FourdgsChunkIndexEntry> index = _index(mutation.bytes);
        final FourdgsChunkIndexEntry selected = index.firstWhere(
          (entry) => entry.referenceOffset == mutation.entry.chunkOffset,
        );
        final String observation =
            field == 'gaussian_count'
                ? "the decoded Delta Chunk's validated operation count"
                : "the composed state's live population";
        final Matcher expected = _diagnostic(mutation, field, observation);

        expect(
          () => decodeKeyframeDeltaStreamed(mutation.bytes),
          throwsA(expected),
        );
        expect(
          () => decodeKeyframeDeltaIndexed(mutation.bytes),
          throwsA(expected),
        );
        expect(
          () => composeKeyframeDeltaChain(
            mutation.bytes,
            index,
            selected,
            byOffset: keyframeDeltaChainIndex(index),
          ),
          throwsA(expected),
        );

        final _RecordingReadable source = _RecordingReadable(mutation.bytes);
        await expectLater(
          readKeyframeDeltaChain(
            source,
            index,
            selected,
            byOffset: keyframeDeltaChainIndex(index),
          ),
          throwsA(expected),
        );

        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(mutation.bytes),
        );
        final List<FourdgsFinding> refusals =
            report.findings
                .where(
                  (finding) =>
                      finding.refusal?.code == refusalIndexRecordMismatch,
                )
                .toList();
        expect(refusals, isNotEmpty);
        expect(
          refusals.first.message,
          contains(_diagnosticText(mutation, field, observation)),
          reason: 'the validator must preserve the reader diagnosis',
        );

        final FourdgsChunkIndexEntry unrelated = index.firstWhere(
          (entry) =>
              entry.kind == 0 &&
              entry.chunkOffset != mutation.entry.keyframeOffset,
        );
        source.reads.clear();
        await readKeyframeDeltaChain(
          source,
          index,
          unrelated,
          byOffset: keyframeDeltaChainIndex(index),
        );
        final int wrongStart = mutation.entry.chunkOffset;
        final int wrongEnd = wrongStart + mutation.entry.chunkLength;
        expect(
          source.reads.every(
            (read) =>
                read.offset + read.length <= wrongStart ||
                read.offset >= wrongEnd,
          ),
          isTrue,
          reason: 'a seek into another GOP must not fetch the mismatched link',
        );
      }
    },
  );

  test('keyframe-delta verifies both count claims on keyframes', () async {
    final Uint8List original = writeKeyframeDeltaBytes(
      _churn(),
      _duration,
      options: const FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
    );
    for (final String field in <String>['gaussian_count', 'live_count']) {
      final _CountMutation mutation = _withWrongIndexCount(
        original,
        field,
        (entry) => entry.kind == 0,
      );
      final List<FourdgsChunkIndexEntry> index = _index(mutation.bytes);
      final FourdgsChunkIndexEntry keyframe = index.firstWhere(
        (entry) => entry.chunkOffset == mutation.entry.chunkOffset,
      );
      final String observation =
          field == 'gaussian_count'
              ? "the decoded keyframe's validated gaussian row count"
              : "the composed state's live population";
      final Matcher expected = _diagnostic(mutation, field, observation);
      expect(
        () => decodeKeyframeDeltaStreamed(mutation.bytes),
        throwsA(expected),
      );
      await expectLater(
        readKeyframeDeltaChain(
          FourdgsBytes(mutation.bytes),
          index,
          keyframe,
          byOffset: keyframeDeltaChainIndex(index),
        ),
        throwsA(expected),
      );
    }
  });
}
