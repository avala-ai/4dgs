// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The framing walk, the record table and the validator, against files built
/// byte by byte.
///
/// Handmade rather than encoder-written, and deliberately: this package has no
/// encoder, and a validator tested only on files its own encoder wrote is a
/// validator tested against nothing. Every fixture here states exactly one fault
/// and leaves the rest of the file correct, so a case cannot pass by being
/// caught for the wrong reason.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

import '../bin/fourdgs.dart' as tool;

/// The generated corpus, relative to this package. One case below decodes a real
/// file from it — a band record is something no handmade fixture in this file is
/// large enough to carry — and FAILS rather than skips when it is absent, because
/// a test that skips itself into a green run has proved nothing.
const String _corpus = '../../tests/conformance/data';

void main() {
  group('the framing walk', () {
    test('frames every record and ends on the magic', () async {
      final Uint8List data = _minimal();
      final FourdgsWalk walk = await walkFourdgsFraming(FourdgsBytes(data));
      expect(walk.trailingMagic, isTrue);
      expect(walk.cut, isNull);
      expect(walk.first(opHeader)!.offset, fourdgsMagic.length);
      expect(walk.first(opFooter), isNotNull);
      // Every record accounted for, back to back: the offsets have to tile the
      // file, or an offset this tool prints points at bytes nobody framed.
      int at = fourdgsMagic.length;
      for (final FourdgsFrame frame in walk.records) {
        expect(frame.offset, at);
        at += frame.total;
      }
      expect(at, walk.size - fourdgsMagic.length);
    });

    test('a cut file names the byte and keeps the intact prefix', () async {
      final Uint8List whole = _minimal();
      final Uint8List cut = Uint8List.sublistView(whole, 0, whole.length - 40);
      final FourdgsWalk walk = await walkFourdgsFraming(FourdgsBytes(cut));
      expect(walk.cut, isNotNull);
      expect(walk.trailingMagic, isFalse);
      expect(walk.records, isNotEmpty);
      // The record the file was cut inside is listed — hiding it would hide the
      // declared length that is the whole fault — and not counted as intact.
      expect(walk.intact, lessThan(walk.records.length));
    });

    test(
      'a file that is not ours is refused before any byte is an opcode',
      () async {
        await expectLater(
          walkFourdgsFraming(
            FourdgsBytes(
              Uint8List.fromList(utf8.encode('not a 4dgs file at all')),
            ),
          ),
          throwsA(isA<FourdgsUnsupportedVersion>()),
        );
      },
    );
  });

  group('placing a refusal', () {
    test('the magic is byte zero, with no walk to place it', () {
      final Object error = _caught(
        () => checkMagic(Uint8List.fromList(utf8.encode('not ours'))),
      );
      final FourdgsNamedRefusal named = describeFourdgsRefusal(error)!;
      expect(named.code, refusalMagicMismatch);
      expect(named.site!.offset, 0);
      expect(named.toString(), 'refusal magic-mismatch at byte 0 (the magic)');
    });

    test('an error the refusal table does not name gets no identifier', () {
      // A truncated transport is a real error and not a refusal. Inventing a
      // code for it would be inventing conformance.
      expect(describeFourdgsRefusal(const FourdgsTruncatedFile('cut')), isNull);
    });

    test('a refusal nothing placed still says which rule fired', () {
      expect(
        const FourdgsNamedRefusal(refusalUnknownStreamCodec, null).toString(),
        'refusal unknown-stream-codec',
      );
    });
  });

  group('inspect', () {
    test('lists every record and says what the checksum covers', () async {
      final FourdgsInspection report = await inspectFourdgs(
        FourdgsBytes(_minimal()),
      );
      final String text = formatFourdgsInspection(report);
      expect(text, contains('offset'));
      expect(text, contains('Header'));
      expect(text, contains('Quantization'));
      expect(text, contains('(magic)'));
      expect(text, contains('4 records'));
      // No summary CRC in this fixture, and saying so is the answer rather than
      // a silence a reader has to interpret.
      expect(report.coverage, isNull);
      expect(text, contains('declares no summary checksum'));
    });

    test('an unknown opcode is framed and named, not refused', () async {
      final Uint8List data = _minimal(extra: _record(0x7F, Uint8List(3)));
      final FourdgsInspection report = await inspectFourdgs(FourdgsBytes(data));
      expect(formatFourdgsInspection(report), contains('Unknown(0x7F)'));
      expect(opcodeName(0x81), 'Private(0x81)');
    });

    test('the JSON form carries the same offsets the table prints', () async {
      final FourdgsInspection report = await inspectFourdgs(
        FourdgsBytes(_minimal()),
      );
      final Object? parsed = jsonDecode(formatFourdgsInspectionJson(report));
      final Map<String, Object?> root = parsed! as Map<String, Object?>;
      expect(root['trailing_magic'], isTrue);
      expect(root['stopped'], isNull);
      final List<Object?> records = root['records']! as List<Object?>;
      expect(records, hasLength(4));
      expect(
        (records.first! as Map<String, Object?>)['offset'],
        fourdgsMagic.length,
      );
    });
  });

  group('validate', () {
    test('a minimal handmade file validates clean', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal()),
      );
      expect(_messages(report, FourdgsSeverity.error), isEmpty);
      expect(report.ok, isTrue);
    });

    test('a file that is not ours is refused, and named', () async {
      // "Both readers raised an error" is not agreement — one of them may have
      // refused for the wrong reason, which is the failure a negative test is
      // supposed to catch and cannot without the identifier.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(Uint8List.fromList(utf8.encode('not a 4dgs file'))),
      );
      expect(report.ok, isFalse);
      expect(report.findings, hasLength(1));
      expect(report.findings.single.refusal!.code, refusalMagicMismatch);
      expect(report.findings.single.refusal!.site!.offset, 0);
    });

    test(
      'a version this reader does not implement is a different refusal',
      () async {
        // The fix differs — a newer reader, or a different file — so the
        // identifiers do too, and a tool that collapsed them would send its reader
        // looking for the wrong one.
        final Uint8List data = _minimal();
        data[5] = 0x39; // '9'
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(data),
        );
        expect(
          report.findings.single.refusal!.code,
          refusalUnsupportedMajorVersion,
        );
      },
    );

    test(
      'a temporal model this build does not implement names the Header',
      () async {
        final Uint8List data = _minimal(temporalModel: 'frame-sequence');
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(data),
        );
        final FourdgsNamedRefusal named = _refusals(report).single;
        expect(named.code, refusalUnknownTemporalModel);
        expect(named.site!.offset, fourdgsMagic.length);
        expect(named.site!.what, 'the Header record');
      },
    );

    test(
      'a second Header is named at its own byte, not at the first one\'s',
      () async {
        // A refusal placed at the first record with the opcode would send whoever
        // is holding the file to a Header that is perfectly fine.
        final Uint8List data = _minimal(
          secondHeader: _headerContent(temporalModel: 'frame-sequence'),
        );
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(data),
        );
        final FourdgsNamedRefusal named = _refusals(report).single;
        expect(named.code, refusalUnknownTemporalModel);
        expect(named.site!.offset, greaterThan(fourdgsMagic.length));
      },
    );

    test(
      'an unknown quantization scheme names the Quantization record',
      () async {
        final Uint8List data = _minimal(scheme: 'uniform-v9');
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(data),
        );
        final FourdgsNamedRefusal named = _refusals(report).single;
        expect(named.code, refusalUnknownQuantizationScheme);
        expect(named.site!.what, 'the Quantization record');
      },
    );

    test('a truncated file says what survived and where it was cut', () async {
      final Uint8List whole = _minimal();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(Uint8List.sublistView(whole, 0, whole.length - 12)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('file does not end with the magic')),
      );
      // The recovery, which the errors above do not answer: records are
      // length-prefixed, so a streamed reader keeps everything complete.
      expect(
        _messages(report, FourdgsSeverity.note).single,
        contains('complete records before it are intact'),
      );
    });

    test(
      'a spherical-harmonic band that will not decode is named at its own byte',
      () async {
        // A whole record class the framing walk has nothing to say about: a band
        // record is stepped over by its declared length like any other, so a
        // validator that never opened one calls this file valid.
        const String name = 'MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc';
        final File file = File('$_corpus/$name.4dgs');
        if (!file.existsSync()) {
          fail(
            'the corpus is missing: run `python3 tests/conformance/generate.py` '
            'from the repository root',
          );
        }
        final Uint8List data = await file.readAsBytes();
        final FourdgsWalk walk = await walkFourdgsFraming(FourdgsBytes(data));
        final FourdgsFrame band = walk.first(opShBandStream)!;
        // Inside the deflate payload: one band byte, the stream header, then the
        // zlib frame. Flipping a byte there moves no offset and leaves the
        // summary checksum — which covers the index and not the chunks — intact,
        // so the file is wrong in exactly this one way.
        data[band.offset + recordHeaderBytes + 1 + streamHeaderBytes + 8] ^=
            0xFF;
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(data),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error).single,
          startsWith('the ShBandStream record for band 1 at byte'),
        );
      },
    );

    test('an unknown record is a note rather than a failure', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(0x7F, Uint8List(3)))),
      );
      expect(report.ok, isTrue);
      expect(
        _messages(report, FourdgsSeverity.note),
        contains('unknown record 0x7F — skipped, as required'),
      );
    });

    test('a private record is skipped and said to be skipped', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(0x81, Uint8List(2)))),
      );
      expect(report.ok, isTrue);
      expect(
        _messages(report, FourdgsSeverity.note).single,
        startsWith('private record 0x81 (2 bytes)'),
      );
    });
  });

  group('the tool', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('fourdgs'));
    tearDown(() async => dir.delete(recursive: true));

    Future<String> write(String name, List<int> bytes) async {
      final File file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      return file.path;
    }

    test('a conforming file with a warning exits 2, not 0', () async {
      // The one deliberate divergence from the Python tool. A warning a script
      // cannot see is a warning nobody acts on, so "valid, and here is something
      // you should know" gets a code of its own — this fixture carries no chunk
      // index, which is legal and worth saying.
      final List<String> out = <String>[];
      final int code = await tool.run(
        <String>['validate', await write('ok.4dgs', _minimal())],
        out.add,
        (_) {},
      );
      expect(code, tool.exitWarnings);
      expect(out.last, 'valid (with notes)');
      expect(
        out,
        contains(
          'warning: no chunk index: this file can only be '
          'read front to back, not seeked',
        ),
      );
    });

    test(
      'a refused file exits 1 and prints the identifier and the byte',
      () async {
        final List<String> out = <String>[];
        final int code = await tool.run(
          <String>[
            'validate',
            await write('bad.4dgs', _minimal(temporalModel: 'frame-sequence')),
          ],
          out.add,
          (_) {},
        );
        expect(code, tool.exitRefused);
        expect(
          out,
          contains(
            '  refusal unknown-temporal-model at byte 8 (the Header record)',
          ),
        );
      },
    );

    test(
      'a path that does not exist is the tool failing, not the file',
      () async {
        // A tool that exits 1 both for "I read the file and it is not conforming"
        // and for "I fell over" is indistinguishable from a broken one, and a
        // pipeline cannot tell those apart after the fact.
        final int code = await tool.run(
          <String>['validate', '${dir.path}/absent.4dgs'],
          (_) {},
          (_) {},
        );
        expect(code, tool.exitToolFailed);
      },
    );

    test('a usage error is the tool failing too', () async {
      expect(
        await tool.run(<String>['frobnicate', 'x'], (_) {}, (_) {}),
        tool.exitToolFailed,
      );
      expect(
        await tool.run(<String>['validate'], (_) {}, (_) {}),
        tool.exitToolFailed,
      );
      expect(
        await tool.run(<String>['validate', 'a', '--json'], (_) {}, (_) {}),
        tool.exitToolFailed,
      );
    });

    test('--help and --version are requests that were served', () async {
      final List<String> out = <String>[];
      expect(await tool.run(<String>['--help'], out.add, (_) {}), tool.exitOk);
      expect(
        await tool.run(<String>['--version'], out.add, (_) {}),
        tool.exitOk,
      );
      expect(out.last, fourdgsPackageVersion);
    });

    test('a cut file is inspected as far as it goes, and then exits 1', () async {
      final Uint8List whole = _minimal();
      final List<String> out = <String>[];
      final int code = await tool.run(
        <String>[
          'inspect',
          await write('cut.4dgs', Uint8List.sublistView(whole, 0, 200)),
        ],
        out.add,
        (_) {},
      );
      expect(code, tool.exitRefused);
      // The prefix was recovered and reported; the file is still not a whole
      // one, and a pipeline that goes on to read it should not be told otherwise.
      expect(out.join('\n'), contains('truncated at byte'));
      expect(out.join('\n'), contains('Header'));
    });
  });
}

List<String> _messages(FourdgsValidation report, FourdgsSeverity severity) =>
    <String>[
      for (final FourdgsFinding f in report.findings)
        if (f.severity == severity) f.message,
    ];

List<FourdgsNamedRefusal> _refusals(FourdgsValidation report) =>
    <FourdgsNamedRefusal>[
      for (final FourdgsFinding f in report.findings)
        if (f.refusal != null) f.refusal!,
    ];

Object _caught(void Function() body) {
  try {
    body();
  } catch (error) {
    return error;
  }
  throw StateError('expected a refusal');
}

/// The smallest thing that is meant to validate: header, grids, windows, footer.
Uint8List _minimal({
  String temporalModel = 'gaussian-birth',
  String scheme = 'uniform-v1',
  Uint8List? extra,
  Uint8List? secondHeader,
}) {
  final BytesBuilder out =
      BytesBuilder()
        ..add(fourdgsMagic)
        ..add(_record(opHeader, _headerContent(temporalModel: temporalModel)));
  if (secondHeader != null) out.add(_record(opHeader, secondHeader));
  out
    ..add(_record(opQuantization, _quantizationContent(scheme: scheme)))
    ..add(_record(opWindowTable, _windowTableContent()));
  if (extra != null) out.add(extra);
  final BytesBuilder footer =
      BytesBuilder()
        ..add(_u64(0))
        ..add(_u64(0))
        ..add(_u32(0));
  out
    ..add(_record(opFooter, footer.toBytes()))
    ..add(fourdgsMagic);
  return out.toBytes();
}

Uint8List _record(int opcode, Uint8List content) {
  final BytesBuilder out =
      BytesBuilder()
        ..addByte(opcode)
        ..add(_u64(content.length))
        ..add(content);
  return out.toBytes();
}

Uint8List _headerContent({String temporalModel = 'gaussian-birth'}) {
  final BytesBuilder body =
      BytesBuilder()
        ..add(_string('')) // profile
        ..add(_string('')) // library
        ..add(_f64(1.0)) // duration_sec
        ..add(_u64(0)) // gaussian_count
        ..add(_f64(0.05)) // cutoff
        ..add(_string(temporalModel));
  for (int i = 0; i < 6; i++) {
    body.add(_f64(0.0)); // aabb
  }
  body
    ..addByte(0) // sh_degree
    ..addByte(0) // flags
    ..add(_u32(0)); // empty attribute map
  return body.toBytes();
}

Uint8List _quantizationContent({String scheme = 'uniform-v1'}) {
  final BytesBuilder body = BytesBuilder()..add(_string(scheme));
  for (int i = 0; i < 3; i++) {
    body.add(_f64(0.0)); // pos_origin
  }
  for (int i = 0; i < 8; i++) {
    body.add(_f64(1.0)); // step_pos .. step_sigma_log
  }
  body
    ..addByte(1) // step_sh
    ..add(_u32(0)); // empty bounds map
  return body.toBytes();
}

Uint8List _windowTableContent() {
  final BytesBuilder body =
      BytesBuilder()
        ..add(_u32(1))
        ..add(_f64(0.0))
        ..add(_f64(1.0));
  return body.toBytes();
}

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

List<int> _u64(int v) {
  final ByteData b = ByteData(8);
  b.setUint32(0, v & 0xFFFFFFFF, Endian.little);
  b.setUint32(4, v >> 32, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _f64(double v) =>
    (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List();

List<int> _string(String s) {
  final List<int> raw = utf8.encode(s);
  return <int>[..._u32(raw.length), ...raw];
}
