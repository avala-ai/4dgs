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

    test('no read is ever the whole file', () async {
      // The claim this validator's API makes: it takes a resource rather than a
      // byte array because it never has to hold one. A file it read whole would
      // still decode chunk by chunk and still cost a copy of a multi-gigabyte
      // scene before the first chunk was fetched (AGENTS.md §1).
      //
      // The fixture is deliberately larger than every bounded read this package
      // makes — the front-matter probe, a checksum block — so that a whole-file
      // read is the only thing that can make the largest read the file.
      final Uint8List data = _minimal(
        extra: _record(0x81, Uint8List(fourdgsCrcBlockBytes)),
      );
      final _CountingReadable source = _CountingReadable(data);
      final FourdgsValidation report = await validateFourdgs(source);
      expect(report.ok, isTrue);
      expect(source.reads, greaterThan(0));
      expect(source.largestRead, lessThan(data.length ~/ 4));
    });

    test('a real scene is still decoded chunk by chunk', () async {
      // The corpus file the band case uses, validated through a resource that
      // remembers the largest thing it was asked for: no read is bigger than the
      // biggest record in the file, which is what "one chunk resident at a time"
      // means when it is true.
      final File file = File(
        '$_corpus/MixedLifetimes-SHDegree2-UseChunkIndex-UseCrc.4dgs',
      );
      if (!file.existsSync()) {
        fail(
          'the corpus is missing: run `python3 tests/conformance/generate.py` '
          'from the repository root',
        );
      }
      final _CountingReadable source = _CountingReadable(
        await file.readAsBytes(),
      );
      final FourdgsValidation report = await validateFourdgs(source);
      expect(report.ok, isTrue);
      final FourdgsWalk walk = await walkFourdgsFraming(
        FourdgsBytes(source.bytes),
      );
      final int largestRecord = walk.records
          .map((FourdgsFrame f) => f.total)
          .reduce((int a, int b) => a > b ? a : b);
      // The front-matter probe is a fixed-size read the seeking opener makes on
      // any file, and on a scene this small it is the whole file — a bound on
      // what a reader asks for, not a copy of what it was given. Every read the
      // validator itself makes is a record or less.
      expect(
        source.largestRead,
        lessThanOrEqualTo(
          largestRecord > fourdgsHeadProbeBytes
              ? largestRecord
              : fourdgsHeadProbeBytes,
        ),
      );
    });

    test(
      'an index entry at the very end of the file is a finding, not a crash',
      () async {
        // `chunk_offset == size` with `chunk_length == 0` passes a "does the
        // range fit" test and points at no byte at all. Reading the opcode there
        // is an uncaught range error — a validator that falls over on exactly
        // the input it exists for, and a CLI that never prints its verdict.
        final int size =
            _minimal(extra: _record(opChunkIndex, _entryAt(0))).length;
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(_minimal(extra: _record(opChunkIndex, _entryAt(size)))),
        );
        expect(
          _messages(report, FourdgsSeverity.error),
          contains('chunk index entry 0 points past the end of the file'),
        );
      },
    );

    test('a malformed object-layer record is not silently accepted', () async {
      // `openFourdgsIndexed` frames the object layer and provenance and stops
      // there; their bodies are parsed only when a caller asks. A validator is
      // that caller, and without asking it reports a file valid that
      // `readFourdgsObjects` refuses — the tool and the API disagreeing about
      // the same bytes.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(opObjectTable, Uint8List(3)))),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('the object layer does not decode:')),
      );
    });
  });

  group('a keyframe-delta file is validated against its own model', () {
    test('the fixture itself is valid', () async {
      // Every case below is this file with one thing changed, so a case that
      // failed for a second reason would prove nothing.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta()),
      );
      expect(_messages(report, FourdgsSeverity.error), isEmpty);
      expect(report.ok, isTrue);
    });

    test('a window index the file does not carry is refused', () async {
      // Composition is arithmetic on bins and never looks a window up, so this
      // file composes perfectly well and is refused the moment anything
      // reconstructs it. A validator that only composed called it valid.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(windowIndex: 3)),
      );
      expect(report.ok, isFalse);
      expect(_refusals(report).single.code, refusalWindowIndexOutOfRange);
      expect(
        _messages(report, FourdgsSeverity.error).single,
        allOf(
          contains('gaussian 0'),
          contains('window index 3'),
          contains('1-entry window table'),
        ),
      );
    });

    test('an index that disagrees with its chunk is reported', () async {
      // §5.8: `live_count` is the population after composition. The indexed
      // reader refuses this file; the validator used to pass it, which is two
      // readers disagreeing about one file.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(liveCount: 2)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('declares live_count 2 for a keyframe whose chunk')),
      );
    });

    test('a chunk_kind the format does not define is refused', () async {
      // `checkIndexEntry` is what says so, and the keyframe-delta branch never
      // reached it: it composed chains straight from the framing without ever
      // opening the file the way a seeking reader does.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(kind: 7)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('declares chunk_kind 7')),
      );
    });

    test('a record after the Footer is refused', () async {
      // The Footer is last. Nothing in the framing walk says so — the record
      // frames cleanly and is stepped over — and only the tail read a seeking
      // reader performs can see it.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(afterFooter: _record(0x81, Uint8List(2)))),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('a seeking reader cannot open this file:')),
      );
    });

    test('a band that will not decode is refused here too', () async {
      // A band record is a whole record class the framing walk steps over, and
      // the keyframe-delta branch never opened one: a delta file with a corrupt
      // band was reported valid while the same fault in a gaussian-birth file
      // was caught.
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(bandElementCount: 7)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error).single,
        allOf(
          startsWith('the ShBandStream record for band 1 at byte'),
          contains('band 1 carries 7 gaussians, the chunk holds 1'),
        ),
      );
    });
  });

  group('a checksum over a range is not a copy of the range', () {
    test('block by block gives what the whole buffer gives', () async {
      // The Footer names a byte range and the range is whatever the Footer says
      // it is — `summary_start` just past the magic makes it almost the whole
      // file. A checksum computed by holding the range is a crafted Footer away
      // from exhausting memory to check a checksum.
      final Uint8List data = Uint8List(fourdgsCrcBlockBytes * 2 + 1234);
      for (int i = 0; i < data.length; i++) {
        data[i] = (i * 31 + 7) & 0xFF;
      }
      final _CountingReadable source = _CountingReadable(data);
      expect(
        await fourdgsCrc32Range(source, 0, data.length),
        fourdgsCrc32(data),
      );
      expect(source.largestRead, lessThanOrEqualTo(fourdgsCrcBlockBytes));
      expect(source.totalRead, data.length);
      // A region that is not the whole resource, and not a block multiple.
      expect(
        await fourdgsCrc32Range(source, 17, 1000),
        fourdgsCrc32(Uint8List.sublistView(data, 17, 1017)),
      );
    });

    test('inspect checks a huge summary region without holding it', () async {
      // `summary_start` at the magic, so the declared region is the file.
      final Uint8List data = _minimal(
        extra: _record(0x81, Uint8List(fourdgsCrcBlockBytes + 4096)),
        summaryStart: fourdgsMagic.length,
        summaryCrc: 1, // wrong on purpose: the point is that it was computed
      );
      final _CountingReadable source = _CountingReadable(data);
      final FourdgsInspection inspection = await inspectFourdgs(source);
      expect(inspection.coverage, isNotNull);
      expect(inspection.coverage!.ok, isFalse);
      expect(source.largestRead, lessThanOrEqualTo(fourdgsCrcBlockBytes));
    });
  });

  group('a chain walk uses the lookup it was given', () {
    test('the caller-supplied index is the one consulted', () {
      // Every chain walk needs a map from chunk offset to entry, and building it
      // inside the walk makes composing an index quadratic in the index — before
      // a single chunk is read. Passing a map that does *not* name the reference
      // is how a test tells "the map I passed" from "a map rebuilt from the
      // list": only the first refuses.
      final FourdgsChunkIndexEntry keyframe = FourdgsChunkIndexEntry(
        t0: 0.0,
        t1: 1.0,
        chunkOffset: 100,
        chunkLength: 10,
        gaussianCount: 1,
        bands: const <FourdgsBandRange>[],
        extended: true,
        liveCount: 1,
      );
      final FourdgsChunkIndexEntry delta = FourdgsChunkIndexEntry(
        t0: 1.0,
        t1: 2.0,
        chunkOffset: 200,
        chunkLength: 10,
        gaussianCount: 1,
        bands: const <FourdgsBandRange>[],
        extended: true,
        kind: 1,
        referenceOffset: 100,
        keyframeOffset: 100,
        depth: 1,
        liveCount: 1,
      );
      final List<FourdgsChunkIndexEntry> index = <FourdgsChunkIndexEntry>[
        keyframe,
        delta,
      ];
      expect(chainFrom(index, delta), <FourdgsChunkIndexEntry>[
        keyframe,
        delta,
      ]);
      expect(
        chainFrom(index, delta, byOffset: keyframeDeltaChainIndex(index)),
        <FourdgsChunkIndexEntry>[keyframe, delta],
      );
      // The same index, and a lookup that leaves the keyframe out.
      expect(
        () => chainFrom(
          index,
          delta,
          byOffset: <int, FourdgsChunkIndexEntry>{200: delta},
        ),
        throwsA(isA<FourdgsMalformedFile>()),
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

    test('a file cut at a record boundary still exits 1', () async {
      // Cut after the Footer, so the walk has nothing to stop on: zero bytes
      // remain, there is no cut, and the only evidence is the eight bytes of
      // magic that are not there. The table says so and the exit code must too,
      // or a script reading the code alone is told a truncated file inspected
      // cleanly — while `validate` calls the same file an error.
      final Uint8List whole = _minimal();
      final Uint8List cut = Uint8List.sublistView(whole, 0, whole.length - 8);
      final FourdgsWalk walk = await walkFourdgsFraming(FourdgsBytes(cut));
      expect(walk.cut, isNull, reason: 'the fixture must cut cleanly');
      expect(walk.trailingMagic, isFalse);

      final List<String> out = <String>[];
      final List<String> err = <String>[];
      final int code = await tool.run(
        <String>['inspect', await write('boundary.4dgs', cut)],
        out.add,
        err.add,
      );
      expect(code, tool.exitRefused);
      expect(out.join('\n'), contains('does not end with the magic'));
      expect(err.join('\n'), contains('does not end with the magic'));
    });

    test('a Footer that will not parse still prints the table', () async {
      // The command exists to say where a file stops making sense. Throwing on
      // the record that does not parse prints nothing at all — no table, no
      // offsets — for exactly the file its holder ran `inspect` for.
      final List<String> out = <String>[];
      final int code = await tool.run(
        <String>[
          'inspect',
          await write('shortfooter.4dgs', _minimal(footerContentBytes: 5)),
        ],
        out.add,
        (_) {},
      );
      expect(code, tool.exitOk);
      final String text = out.join('\n');
      expect(text, contains('Header'));
      expect(text, contains('Footer'));
      expect(text, contains('the Footer frames cleanly but does not parse'));
    });

    test('the seven invalid variants, end to end', () async {
      // The strongest check available to this tool: six validators read the
      // same seven files and must place the same seven refusals at the same
      // seven bytes. The identifier is read out of the corpus's own expectation
      // file rather than written here, so a test cannot drift away from what
      // the suite compares — and the offsets are the ones every other SDK's
      // tool prints for the same bytes.
      const Map<String, int> bytes = <String, int>{
        'BadMagic': 0,
        'EmptyTemporalModel': 8,
        'FutureMajorVersion': 0,
        'UnknownQuantizationScheme': 154,
        'UnknownStreamCodec': 659,
        'UnknownTemporalModel': 8,
        'WindowIndexOutOfRange': 2506,
      };
      for (final MapEntry<String, int> variant in bytes.entries) {
        final File file = File('$_corpus/invalid/${variant.key}.4dgs');
        final File expectation = File('$_corpus/invalid/${variant.key}.json');
        if (!file.existsSync() || !expectation.existsSync()) {
          fail(
            'the corpus is missing ${variant.key}: run '
            '`python3 tests/conformance/generate.py` from the repository root',
          );
        }
        final String refusal =
            (jsonDecode(await expectation.readAsString())
                    as Map<String, Object?>)['refused']!
                as String;
        final List<String> out = <String>[];
        final int code = await tool.run(
          <String>['validate', file.path],
          out.add,
          (_) {},
        );
        expect(code, tool.exitRefused, reason: '${variant.key} must exit 1');
        expect(
          out,
          contains(
            allOf(
              startsWith('  refusal $refusal at byte ${variant.value} ('),
              endsWith(')'),
            ),
          ),
          reason: '${variant.key} must name $refusal at byte ${variant.value}',
        );
      }
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
  int summaryStart = 0,
  int summaryCrc = 0,
  int footerContentBytes = 20,
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
        ..add(_u64(summaryStart))
        ..add(_u64(0))
        ..add(_u32(summaryCrc));
  out
    ..add(
      _record(
        opFooter,
        Uint8List.sublistView(footer.toBytes(), 0, footerContentBytes),
      ),
    )
    ..add(fourdgsMagic);
  return out.toBytes();
}

/// A whole one-chunk `keyframe-delta` file, with an index and a Footer.
///
/// Handmade for the same reason everything else here is: this package has no
/// encoder, and every fault below is one the reference encoder will not write —
/// a `window_index` past the table, a `live_count` that disagrees with the
/// chunk, a record after the Footer, a band declaring the wrong population.
///
/// The keyframe-delta branch of the validator is reached only by a file whose
/// Header names that model *and* whose index is non-empty, so a fixture that
/// stops short of the Chunk Index tests the other branch by accident.
Uint8List _keyframeDelta({
  int windowIndex = 0,
  int liveCount = 1,
  int kind = 0,
  Uint8List? afterFooter,
  int? bandElementCount,
}) {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(temporalModel: 'keyframe-delta'),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();

  final Uint8List streams = _keyframeStreams(windowIndex: windowIndex);
  final BytesBuilder chunk =
      BytesBuilder()
        ..add(_f64(0.0)) // t0
        ..add(_f64(1.0)) // t1
        ..add(_u32(0)) // level
        ..add(_u32(1)) // count
        ..add(_string('')) // compression
        ..add(_u64(0)) // uncompressed_size
        ..add(_u64(streams.length))
        ..add(streams);
  final Uint8List chunkRecord = _record(opChunk, chunk.toBytes());
  final int chunkOffset = head.length;

  Uint8List bandRecord = Uint8List(0);
  if (bandElementCount != null) {
    final BytesBuilder band =
        BytesBuilder()
          ..addByte(1) // band
          ..addByte(0) // attribute id, which a band record does not key on
          ..addByte(1) // symbol width
          ..addByte(modeRaw)
          ..addByte(codecDeflate)
          ..addByte(shBandChannels[1]!)
          ..add(_u32(bandElementCount))
          ..add(_u64(0));
    bandRecord = _record(opShBandStream, band.toBytes());
  }
  final int bandOffset = chunkOffset + chunkRecord.length;

  final int indexOffset = bandOffset + bandRecord.length;
  final BytesBuilder entry =
      BytesBuilder()
        ..add(_f64(0.0))
        ..add(_f64(1.0))
        ..add(_u64(chunkOffset))
        ..add(_u64(chunkRecord.length))
        ..add(_u32(1)) // gaussian_count
        ..add(_u32(bandElementCount == null ? 0 : 1));
  if (bandElementCount != null) {
    entry
      ..addByte(1)
      ..add(_u64(bandOffset))
      ..add(_u64(bandRecord.length));
  }
  entry
    ..addByte(kind)
    ..addByte(0) // delta_mode
    ..add(_u64(0)) // reference_offset
    ..add(_u64(chunkOffset)) // keyframe_offset
    ..add(_u16(0)) // depth
    ..add(_u64(liveCount));
  final Uint8List indexRecord = _record(opChunkIndex, entry.toBytes());

  final BytesBuilder footer =
      BytesBuilder()
        ..add(_u64(indexOffset))
        ..add(_u64(0))
        ..add(_u32(0));
  final BytesBuilder out =
      BytesBuilder()
        ..add(head)
        ..add(chunkRecord)
        ..add(bandRecord)
        ..add(indexRecord)
        ..add(_record(opFooter, footer.toBytes()));
  // After the Footer, which the format does not allow: the Footer is last. The
  // magic still closes the file, so nothing but the tail read can see it.
  if (afterFooter != null) out.add(afterFooter);
  out.add(fourdgsMagic);
  return out.toBytes();
}

/// One constant-mode stream carrying [value] in every channel.
Uint8List _constStream(int attributeId, int channels, int count, int value) {
  final int zigzag = value < 0 ? (-value * 2) - 1 : value * 2;
  final Uint8List payload = Uint8List.fromList(
    zlib.encode(List<int>.filled(channels, zigzag)),
  );
  final BytesBuilder out =
      BytesBuilder()
        ..addByte(attributeId)
        ..addByte(1) // symbol width
        ..addByte(modeConst)
        ..addByte(codecDeflate)
        ..addByte(channels)
        ..add(_u32(count))
        ..add(_u64(payload.length))
        ..add(payload);
  return out.toBytes();
}

/// A one-gaussian keyframe chunk's streams: the required set, plus the identity
/// a `keyframe-delta` chunk must carry (spec §11.2).
Uint8List _keyframeStreams({required int windowIndex}) {
  const Map<int, int> channels = <int, int>{
    attrPosition: 3,
    attrScale: 3,
    attrRotationIndex: 1,
    attrRotation: 3,
    attrColor: 3,
    attrOpacity: 1,
    attrMotion: 3,
    attrMuT: 1,
    attrSigmaT: 1,
    attrFlags: 1,
    attrWindowIndex: 1,
  };
  final BytesBuilder out = BytesBuilder();
  for (final int id in requiredAttributes) {
    out.add(
      _constStream(
        id,
        channels[id]!,
        1,
        id == attrWindowIndex ? windowIndex : 0,
      ),
    );
  }
  out.add(_constStream(attrGaussianId, 1, 1, 0));
  return out.toBytes();
}

/// A resource that remembers what was asked of it.
///
/// The point of the validator taking a [FourdgsReadable] rather than a byte
/// array is that it never has to hold the file; that is a claim about the size
/// of the reads it makes, and this is what makes the claim checkable.
class _CountingReadable implements FourdgsReadable {
  _CountingReadable(this.bytes);

  final Uint8List bytes;
  int largestRead = 0;
  int totalRead = 0;
  int reads = 0;

  @override
  Future<int> size() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw RangeError('outside the resource');
    }
    reads += 1;
    totalRead += length;
    if (length > largestRead) largestRead = length;
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

/// A Chunk Index entry naming a zero-length chunk at [offset].
Uint8List _entryAt(int offset) {
  final BytesBuilder out =
      BytesBuilder()
        ..add(_f64(0.0))
        ..add(_f64(1.0))
        ..add(_u64(offset))
        ..add(_u64(0))
        ..add(_u32(0)) // gaussian_count
        ..add(_u32(0)); // band count
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

List<int> _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

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
