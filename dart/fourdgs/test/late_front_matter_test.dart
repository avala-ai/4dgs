// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';
import 'package:test/test.dart';

typedef _LateFixture =
    ({
      Uint8List bytes,
      int firstStateOpcode,
      int firstStateOffset,
      int lateOffset,
    });

const List<int> _frontMatterOpcodes = <int>[
  opHeader,
  opQuantization,
  opWindowTable,
  opAudio,
  opCamera,
  opMetadata,
  opAttachment,
  opAudioSource,
  opAudioData,
  opCoordinateFrame,
  opSensorCalibration,
  opRigTrajectory,
  opGeodeticAnchor,
  opObjectTable,
  opObjectTrack,
];

FourdgsGaussianSet _oneGaussian() => FourdgsGaussianSet(
  positions: Float32List.fromList(const <double>[0, 0, 0]),
  scales: Float32List.fromList(const <double>[1, 1, 1]),
  rotations: Float32List.fromList(const <double>[0, 0, 0, 1]),
  colors: Float32List.fromList(const <double>[0.5, 0.5, 0.5, 1]),
  motions: Float32List.fromList(const <double>[0, 0, 0]),
  muT: Float32List.fromList(const <double>[0.5]),
  sigmaT: Float32List.fromList(const <double>[0.5]),
  winLo: Float32List.fromList(const <double>[0]),
  winHi: Float32List.fromList(const <double>[1]),
);

Uint8List _gaussianBirthFile() => writeFourdgsBytes(
  _oneGaussian(),
  1.0,
  options: const FourdgsWriteOptions(
    writeIndex: false,
    writeCrc: false,
    shBands: 0,
    verify: false,
  ),
);

Uint8List _keyframeDeltaFile() => writeKeyframeDeltaBytes(
  <FourdgsSample>[
    FourdgsSample(t0: 0.0, ids: const <int>[7], gaussians: _oneGaussian()),
  ],
  1.0,
  options: const FourdgsKeyframeDeltaOptions(
    writeIndex: false,
    writeStatistics: false,
    writeCrc: false,
    verify: false,
  ),
);

Uint8List _record(int opcode, Uint8List content) {
  final header =
      ByteData(recordHeaderBytes)
        ..setUint8(0, opcode)
        ..setUint32(1, content.length, Endian.little)
        ..setUint32(5, 0, Endian.little);
  return Uint8List.fromList(<int>[...header.buffer.asUint8List(), ...content]);
}

_LateFixture _afterFirstState(
  Uint8List source,
  int opcode, {
  Uint8List? content,
}) {
  final state = iterRecords(
    source,
    fourdgsMagic.length,
  ).firstWhere((record) => isStateOpcode(record.opcode));
  final lateOffset = state.offset + recordHeaderBytes + state.content.length;
  final late = _record(opcode, content ?? Uint8List(0));
  return (
    bytes: Uint8List.fromList(<int>[
      ...source.sublist(0, lateOffset),
      ...late,
      ...source.sublist(lateOffset),
    ]),
    firstStateOpcode: state.opcode,
    firstStateOffset: state.offset,
    lateOffset: lateOffset,
  );
}

String _hex(int opcode) =>
    '0x${opcode.toRadixString(16).padLeft(2, '0').toUpperCase()}';

Matcher _diagnostic(_LateFixture fixture, int lateOpcode) => allOf(
  contains(
    '${opcodeName(lateOpcode)} record (opcode ${_hex(lateOpcode)}) '
    'at byte ${fixture.lateOffset}',
  ),
  contains(
    'first state record, ${opcodeName(fixture.firstStateOpcode)} '
    '(opcode ${_hex(fixture.firstStateOpcode)}) at byte '
    '${fixture.firstStateOffset}',
  ),
  contains('expected every defined front-matter record before'),
);

Matcher _lateRefusal(_LateFixture fixture, int lateOpcode) =>
    isA<FourdgsMalformedFile>()
        .having(
          (error) => error.refusalCode,
          'refusal code',
          refusalLateFrontMatterRecord,
        )
        .having(
          (error) => error.message,
          'physical record diagnosis',
          _diagnostic(fixture, lateOpcode),
        );

Future<void> _expectValidatorRefusal(
  _LateFixture fixture,
  int lateOpcode,
) async {
  final report = await validateFourdgs(FourdgsBytes(fixture.bytes));
  final refused = report.findings.where(
    (finding) => finding.refusal?.code == refusalLateFrontMatterRecord,
  );
  expect(refused, hasLength(1));
  final finding = refused.single;
  expect(finding.message, _diagnostic(fixture, lateOpcode));
  expect(finding.refusal!.site!.offset, fixture.lateOffset);
  expect(finding.refusal!.site!.what, 'the ${opcodeName(lateOpcode)} record');
}

void main() {
  group('late-front-matter-record', () {
    final gaussianBirth = _gaussianBirthFile();
    final keyframeDelta = _keyframeDeltaFile();

    for (final opcode in _frontMatterOpcodes) {
      test(
        '${opcodeName(opcode)} is refused before duplicate or body parsing',
        () async {
          // Empty bodies make every structured member hostile. Header,
          // Quantization, and WindowTable are also late duplicates. Reaching a
          // body parser or multiplicity check would therefore produce the wrong
          // refusal, so this one table pins both precedence requirements.
          final gaussianFixture = _afterFirstState(gaussianBirth, opcode);
          final deltaFixture = _afterFirstState(keyframeDelta, opcode);

          expect(
            () => readFourdgsBytes(
              gaussianFixture.bytes,
              recoverTruncated: false,
            ),
            throwsA(_lateRefusal(gaussianFixture, opcode)),
          );
          expect(
            () => decodeKeyframeDeltaStreamed(deltaFixture.bytes),
            throwsA(_lateRefusal(deltaFixture, opcode)),
          );
          await _expectValidatorRefusal(gaussianFixture, opcode);
        },
      );
    }

    test('the first state record may itself be a Delta Chunk', () async {
      final source = _gaussianBirthFile();
      final state = iterRecords(
        source,
        fourdgsMagic.length,
      ).firstWhere((record) => record.opcode == opChunk);
      final withDeltaOpcode = Uint8List.fromList(source)
        ..[state.offset] = opDeltaChunk;
      final fixture = _afterFirstState(withDeltaOpcode, opHeader);

      expect(
        () => readFourdgsBytes(fixture.bytes, recoverTruncated: false),
        throwsA(_lateRefusal(fixture, opHeader)),
      );
      await _expectValidatorRefusal(fixture, opHeader);
    });

    for (final opcode in <int>[0x7F, 0x80]) {
      test('${opcodeName(opcode)} remains position-independent', () async {
        expect(isFrontMatterOpcode(opcode), isFalse);
        final gaussianFixture = _afterFirstState(gaussianBirth, opcode);
        final deltaFixture = _afterFirstState(keyframeDelta, opcode);

        final scene = readFourdgsBytes(
          gaussianFixture.bytes,
          recoverTruncated: false,
        );
        expect(scene.gaussians.count, 1);
        expect(scene.skippedOpcodes, contains(opcode));
        expect(
          decodeKeyframeDeltaStreamed(deltaFixture.bytes).chunks,
          hasLength(1),
        );

        final report = await validateFourdgs(
          FourdgsBytes(gaussianFixture.bytes),
        );
        expect(report.ok, isTrue);
        expect(
          report.findings.where(
            (finding) => finding.refusal?.code == refusalLateFrontMatterRecord,
          ),
          isEmpty,
        );
      });
    }

    test('the placement classifier is the registry closed set', () {
      expect(<int>[
        for (int opcode = 0; opcode <= 0xFF; opcode++)
          if (isFrontMatterOpcode(opcode)) opcode,
      ], _frontMatterOpcodes);
      expect(isStateOpcode(opChunk), isTrue);
      expect(isStateOpcode(opDeltaChunk), isTrue);
      expect(isStateOpcode(0x26), isFalse, reason: 'reserved stays unassigned');
    });
  });
}
