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

    test(
      'extension-heavy files are counted without an arbitrary refusal',
      () async {
        final builder = BytesBuilder()..add(fourdgsMagic);
        final emptyPrivate = _record(0x80, Uint8List(0));
        for (int i = 0; i <= maxFramedRecords; i++) {
          builder.add(emptyPrivate);
        }
        builder.add(fourdgsMagic);

        final walk = await walkFourdgsFraming(FourdgsBytes(builder.toBytes()));
        expect(walk.recordCount, maxFramedRecords + 1);
        expect(walk.records, hasLength(maxFramedRecords));
        expect(walk.recordsOmitted, 1);
        expect(walk.trailingMagic, isTrue);
      },
    );
  });

  test('an uncompressed Chunk must declare its carried block size', () {
    final streams = _keyframeStreams(windowIndex: 0);
    final content =
        (BytesBuilder()
              ..add(_f64(0.0))
              ..add(_f64(1.0))
              ..add(_u32(0))
              ..add(_u32(1))
              ..add(_string(''))
              ..add(_u64(streams.length + 1))
              ..add(_u64(streams.length))
              ..add(streams))
            .toBytes();
    expect(
      () => parseChunk(content),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (error) => error.message,
          'message',
          allOf(contains('uncompressed Chunk'), contains('but carries')),
        ),
      ),
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
          _messages(report, FourdgsSeverity.error),
          contains(startsWith('the ShBandStream record for band 1 at byte')),
        );
      },
    );

    test('an unindexed gaussian-birth Chunk is still decoded', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_gaussianBirthWithMalformedUnindexedChunk()),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(
          allOf(
            startsWith('the Chunk record at byte'),
            contains('does not decode'),
          ),
        ),
      );
    });

    test('an absent Window Table supplies the default window', () async {
      final Uint8List streams = _keyframeStreams(
        windowIndex: 0,
        includeGaussianId: false,
      );
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _minimal(
            writeWindowTable: false,
            gaussianCount: 1,
            extra: _stateChunk(streams, 1),
          ),
        ),
      );
      expect(_messages(report, FourdgsSeverity.error), isEmpty);
    });

    test('an SH band before every Chunk is rejected', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _minimal(
            shDegree: 1,
            extra:
                (BytesBuilder()
                      ..add(_shBandRecord(0, 0))
                      ..add(_stateChunk(Uint8List(0), 0)))
                    .toBytes(),
          ),
        ),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(allOf(contains('ShBandStream'), contains('precedes every'))),
      );
    });

    test('duplicate gaussian-birth index entries are rejected', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_gaussianBirthWithDuplicateIndex()),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('both name the gaussian-birth Chunk')),
      );
    });

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
        '$_corpus/TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset.4dgs',
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

    test(
      'post-chunk auxiliary records are parsed from the complete walk',
      () async {
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(
            _keyframeDelta(afterChunk: _record(opObjectTable, Uint8List(3))),
          ),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error),
          contains(startsWith('the object layer does not decode:')),
        );
      },
    );

    test('post-chunk Camera records are parsed, not only framed', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDelta(afterChunk: _record(opCamera, Uint8List(3))),
        ),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('the Camera record at byte')),
      );
    });

    test('Camera loop is encoded as exactly zero or one', () async {
      final Uint8List camera =
          (BytesBuilder()
                ..add(_f64(45.0))
                ..add(_f64(0.0))
                ..add(_f64(0.0))
                ..add(_f64(0.0))
                ..add(_f64(0.0))
                ..add(_f64(0.0))
                ..add(_f64(1.0))
                ..add(_u32(0))
                ..add(_string('linear'))
                ..addByte(2))
              .toBytes();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(opCamera, camera))),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(allOf(contains('Camera record'), contains('expected 0 or 1'))),
      );
    });

    test('post-chunk Metadata records are parsed, not only framed', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDelta(afterChunk: _record(opMetadata, Uint8List(3))),
        ),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('the Metadata record at byte')),
      );
    });

    test(
      'post-chunk Attachment headers are parsed without their payload',
      () async {
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(
            _keyframeDelta(afterChunk: _record(opAttachment, Uint8List(3))),
          ),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error),
          contains(startsWith('the Attachment record at byte')),
        );
      },
    );

    test('the Footer cannot omit framed Chunk Index records', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(opChunkIndex, _entryAt(0)))),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('summary_start 0 (no index)')),
      );
    });

    test('the Footer points at the first Summary Offset record', () async {
      final Uint8List summaryOffset = _record(
        opSummaryOffset,
        (BytesBuilder()
              ..addByte(opChunkIndex)
              ..add(_u64(0))
              ..add(_u64(0)))
            .toBytes(),
      );
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _minimal(extra: summaryOffset, summaryOffsetStart: 123456),
        ),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('first Summary Offset')),
      );
    });

    test('an earlier Footer cannot hide behind the final Footer', () async {
      final Uint8List footer =
          (BytesBuilder()
                ..add(_u64(0))
                ..add(_u64(0))
                ..add(_u32(0)))
              .toBytes();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(opFooter, footer))),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('2 Footer records')),
      );
    });

    test('the summary range contains only summary record classes', () async {
      final Uint8List index = _record(opChunkIndex, _entryAt(0));
      final Uint8List unexpected = _record(0x81, Uint8List(1));
      final Uint8List summary =
          (BytesBuilder()
                ..add(index)
                ..add(unexpected))
              .toBytes();
      final int summaryStart =
          fourdgsMagic.length +
          _record(opHeader, _headerContent()).length +
          _record(opQuantization, _quantizationContent()).length +
          _record(opWindowTable, _windowTableContent()).length;
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _minimal(
            extra: summary,
            summaryStart: summaryStart,
            summaryCrc: fourdgsCrc32(summary),
          ),
        ),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('only Chunk Index, Statistics, and Summary Offset')),
      );
    });

    test('conflicting Coordinate Frame units are an error', () async {
      final Uint8List coordinateFrame =
          (BytesBuilder()
                ..add(_string('scene'))
                ..addByte(0) // handedness unspecified
                ..addByte(1) // +X up
                ..addByte(2) // +Y forward
                ..addByte(1) // metre
                ..add(_f64(0.01)))
              .toBytes();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _minimal(extra: _record(opCoordinateFrame, coordinateFrame)),
        ),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(
          allOf(contains('length_unit 1'), contains('metres_per_unit is 0.01')),
        ),
      );
    });

    test(
      'every legacy Audio record is parsed and duplicates are rejected',
      () async {
        final Uint8List audio = _record(
          opAudio,
          (BytesBuilder()
                ..add(_string('wav'))
                ..add(_f64(0.0))
                ..add(_u64(0)))
              .toBytes(),
        );
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(_keyframeDelta(beforeChunk: audio, afterChunk: audio)),
        );
        expect(
          _messages(report, FourdgsSeverity.error),
          contains('the file carries more than one legacy Audio record'),
        );
      },
    );

    test(
      'embedded and reserved opcodes are not legal top-level records',
      () async {
        for (final int opcode in const <int>[
          opAttributeStream,
          opAttachmentIndex,
        ]) {
          final FourdgsValidation report = await validateFourdgs(
            FourdgsBytes(_minimal(extra: _record(opcode, Uint8List(0)))),
          );
          expect(
            _messages(report, FourdgsSeverity.error),
            contains(contains('is not legal as a top-level record')),
          );
        }
      },
    );

    test('gaussian-birth refuses a Delta Chunk record', () async {
      final Uint8List interval =
          (BytesBuilder()
                ..add(_f64(0.0))
                ..add(_f64(1.0)))
              .toBytes();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: _record(opDeltaChunk, interval))),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(
          contains('only legal under the keyframe-delta temporal model'),
        ),
      );
    });

    test('the SH-depth append is checked against Header degree', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(shDegree: 2, shBitDepths: const <int>[8])),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('declares 1 SH bit depths')),
      );
    });

    test('a malformed SH-depth append remains visible to validation', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(shDegree: 1, shBitDepths: const <int>[9])),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('malformed SH bit-depth declaration')),
      );
    });

    test('reserved Header flag bits must be clear', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(headerFlags: 0x04)),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('reserved bits 0x4')),
      );
    });

    test('gaussian-birth Chunks cannot carry gaussian_id', () async {
      final Uint8List streams = _keyframeStreams(windowIndex: 0);
      final Uint8List chunk = _stateChunk(streams, 1);
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: chunk, gaussianCount: 1)),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('gaussian_id stream')),
      );
    });

    test(
      'the objects profile requires object_id in a non-empty Chunk',
      () async {
        final Uint8List objectTable = _record(
          opObjectTable,
          Uint8List.fromList(<int>[..._u32(0), ..._u16(0)]),
        );
        final Uint8List streams = _keyframeStreams(
          windowIndex: 0,
          includeGaussianId: false,
        );
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(
            _minimal(
              profile: 'objects',
              gaussianCount: 1,
              extra:
                  (BytesBuilder()
                        ..add(objectTable)
                        ..add(_stateChunk(streams, 1)))
                      .toBytes(),
            ),
          ),
        );
        expect(
          _messages(report, FourdgsSeverity.error),
          contains(contains('objects profile requires object_id')),
        );
      },
    );

    test('specified records beyond the inspection cap are validated', () async {
      final BytesBuilder extra = BytesBuilder();
      final Uint8List private = _record(0x80, Uint8List(0));
      // Header, Quantization, and Window Table consume the first three retained
      // frame slots. Put the malformed Camera immediately after the table cap.
      for (int i = 3; i < maxFramedRecords; i++) {
        extra.add(private);
      }
      extra.add(_record(opCamera, Uint8List(3)));
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimal(extra: extra.toBytes())),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(startsWith('the Camera record at byte')),
      );
    });

    test('a detached Chunk head still reports its file byte', () {
      final Uint8List head = Uint8List(chunkFixedHeadBytes);
      final ByteData view = ByteData.sublistView(head);
      view.setFloat64(0, 2.0, Endian.little);
      view.setFloat64(8, 1.0, Endian.little);
      expect(
        () => parseChunkInterval(head, fileOffset: 1234),
        throwsA(
          isA<FourdgsMalformedFile>().having(
            (FourdgsMalformedFile error) => error.message,
            'message',
            contains('Chunk at byte 1234'),
          ),
        ),
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

    test('a no-index file is composed one record at a time', () async {
      final Uint8List data = _keyframeDelta(
        writeIndex: false,
        afterChunk: _record(0x81, Uint8List(fourdgsHeadProbeBytes * 2)),
      );
      final _CountingReadable source = _CountingReadable(data);
      final FourdgsValidation report = await validateFourdgs(source);
      expect(report.ok, isTrue);
      expect(source.largestRead, lessThan(data.length));
    });

    test('an indexless timeline still covers both Header endpoints', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDelta(
            writeIndex: false,
            chunkT0: 0.25,
            chunkT1: 0.75,
            headerDuration: 1.0,
          ),
        ),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('timeline must start at 0')),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('Header duration_sec is 1.0')),
      );
    });

    test('a no-index file still validates its framed SH bands', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(writeIndex: false, bandElementCount: 7)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('band 1 carries 7 gaussians, the chunk holds 1')),
      );
    });

    test('an indexed band range outside the resource is a finding', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDelta(bandElementCount: 1, indexBandOffset: 1 << 30),
        ),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('outside the')),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('ShBandStream range for band 1')),
      );
    });

    test(
      'an indexed chunk range outside the resource does not crash',
      () async {
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(_keyframeDelta(indexChunkOffset: 1 << 30)),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error),
          contains('chunk index entry 0 points past the end of the file'),
        );
      },
    );

    test('an indexed Chunk length must match its framing', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(indexChunkLengthExtra: 1)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('its framing declares')),
      );
    });

    test('every keyframe mu_t names its interval start', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDelta(
            writeIndex: false,
            chunkT0: 1.0,
            chunkT1: 2.0,
            headerDuration: 2.0,
          ),
        ),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('its Chunk t0 1.0 requires bin 32')),
      );
    });

    test('SH bands cover the degree declared by the Header', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(headerShDegree: 1)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('Header declares degree 1 and requires [1]')),
      );
    });

    test('a complete state chunk omitted from the index is rejected', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(extraUnindexedKeyframe: true)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('state chunk the Chunk Index does not name')),
      );
    });

    test(
      'delta metadata duplicated in the index must match the chunk',
      () async {
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(
            _keyframeDeltaWithEmptyDelta(indexReferenceOffset: 123456),
          ),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error),
          contains(contains('disagrees with its Delta Chunk')),
        );
      },
    );

    test(
      'delta gaussian_count is the sum of its three operation groups',
      () async {
        final FourdgsValidation report = await validateFourdgs(
          FourdgsBytes(_keyframeDeltaWithEmptyDelta(indexGaussianCount: 7)),
        );
        expect(report.ok, isFalse);
        expect(
          _messages(report, FourdgsSeverity.error),
          contains(
            contains('chunk carries 0 update, birth, and death operations'),
          ),
        );
      },
    );

    test('the forward validator accepts a conforming chained delta', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDeltaWithEmptyDelta()),
      );
      expect(_messages(report, FourdgsSeverity.error), isEmpty);
    });

    test('each delta group must contain its declared population', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(
          _keyframeDeltaWithEmptyDelta(updateCount: 1, indexGaussianCount: 1),
        ),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('declares 1 update operations')),
      );
    });

    test('empty delta groups cannot carry nonempty attributes', () async {
      final Uint8List updates =
          (BytesBuilder()
                ..add(_constStream(attrGaussianId, 1, 0, 0))
                ..add(_constStream(attrPosition, 3, 1, 0)))
              .toBytes();
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDeltaWithEmptyDelta(updateGroup: updates)),
      );
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(
          allOf(
            contains('declares 0 update operations'),
            contains('attribute 0'),
            contains('decodes to 1 rows'),
          ),
        ),
      );
    });

    test('a delta must preserve its reference level', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDeltaWithEmptyDelta(deltaLevel: 1)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('a delta preserves its reference level')),
      );
    });

    test('Header gaussian_count is the number of distinct ids', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(headerGaussianCount: 2)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('Header declares 2 distinct gaussian ids')),
      );
    });

    test('registry attributes keep their declared channel count', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDelta(positionChannels: 2)),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('attribute 0 of the keyframe chunk at byte')),
      );
    });

    test('an indexed SH band must belong to the named Chunk', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframesWithSwappedBands()),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('does not belong to the Chunk at byte')),
      );
    });

    test('a gaussian id cannot be born again after it dies', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_keyframeDeltaWithRetiredIdReuse()),
      );
      expect(report.ok, isFalse);
      expect(
        _messages(report, FourdgsSeverity.error),
        contains(contains('births retired gaussian id 0')),
      );
    });
  });

  group('a checksum over a range is not a copy of the range', () {
    test('an appended Footer still ends the summary at its opcode', () async {
      final FourdgsValidation report = await validateFourdgs(
        FourdgsBytes(_minimalWithExtendedFooterCrc()),
      );
      final List<String> errors = _messages(report, FourdgsSeverity.error);
      expect(errors, isNot(contains(contains('summary CRC mismatch'))));
      expect(
        errors,
        isNot(contains(startsWith('a seeking reader cannot open this file:'))),
      );
    });

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

    test('inspect reads only the fixed prefix of an extended Footer', () async {
      final Uint8List data = _minimalWithHugeFooterAppend();
      final _CountingReadable source = _CountingReadable(data);
      final FourdgsInspection inspection = await inspectFourdgs(source);
      expect(inspection.coverageError, isNull);
      expect(source.largestRead, lessThan(fourdgsCrcBlockBytes));
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

    test('a mid-command I/O failure exits 3 and names the path', () async {
      final List<String> errors = <String>[];
      final int code = await tool.run(
        <String>['validate', 'disconnected.4dgs'],
        (_) {},
        errors.add,
        openReadable:
            (_) async => (source: _IoFailureReadable(), close: () async {}),
      );
      expect(code, tool.exitToolFailed);
      expect(errors.single, contains('disconnected.4dgs'));
      expect(errors.single, contains('read failed'));
    });

    test('a close failure exits 3 and names the path', () async {
      final List<String> errors = <String>[];
      final int code = await tool.run(
        <String>['validate', 'close-failure.4dgs'],
        (_) {},
        errors.add,
        openReadable:
            (_) async => (
              source: FourdgsBytes(_minimal()),
              close:
                  () async => throw const FileSystemException('close failed'),
            ),
      );
      expect(code, tool.exitToolFailed);
      expect(errors.single, contains('close-failure.4dgs'));
      expect(errors.single, contains('close failed'));
    });

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
  String profile = '',
  String scheme = 'uniform-v1',
  Uint8List? extra,
  Uint8List? secondHeader,
  int summaryStart = 0,
  int summaryCrc = 0,
  int summaryOffsetStart = 0,
  int footerContentBytes = 20,
  int shDegree = 0,
  int headerFlags = 0,
  int gaussianCount = 0,
  bool writeWindowTable = true,
  List<int> shBitDepths = const <int>[],
}) {
  final BytesBuilder out =
      BytesBuilder()
        ..add(fourdgsMagic)
        ..add(
          _record(
            opHeader,
            _headerContent(
              temporalModel: temporalModel,
              profile: profile,
              shDegree: shDegree,
              flags: headerFlags,
              gaussianCount: gaussianCount,
            ),
          ),
        );
  if (secondHeader != null) out.add(_record(opHeader, secondHeader));
  out.add(
    _record(
      opQuantization,
      _quantizationContent(scheme: scheme, shBitDepths: shBitDepths),
    ),
  );
  if (writeWindowTable) {
    out.add(_record(opWindowTable, _windowTableContent()));
  }
  if (extra != null) out.add(extra);
  final BytesBuilder footer =
      BytesBuilder()
        ..add(_u64(summaryStart))
        ..add(_u64(summaryOffsetStart))
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

/// A conforming Footer with forward-compatible appended fields and a checksum
/// over the bytes ending at the Footer opcode.
Uint8List _minimalWithExtendedFooterCrc() {
  final BytesBuilder prefix =
      BytesBuilder()
        ..add(fourdgsMagic)
        ..add(_record(opHeader, _headerContent()))
        ..add(_record(opQuantization, _quantizationContent()))
        ..add(_record(opWindowTable, _windowTableContent()))
        ..add(_record(0x81, Uint8List.fromList(<int>[1, 2, 3, 4])));
  final Uint8List beforeFooter = prefix.toBytes();
  final int summaryStart = fourdgsMagic.length;
  final int crc = fourdgsCrc32(
    Uint8List.sublistView(beforeFooter, summaryStart),
  );
  final Uint8List footer =
      (BytesBuilder()
            ..add(_u64(summaryStart))
            ..add(_u64(0))
            ..add(_u32(crc))
            // Future fields which the current parser is required to ignore.
            ..add(<int>[0xAA, 0xBB, 0xCC, 0xDD]))
          .toBytes();
  return (BytesBuilder()
        ..add(beforeFooter)
        ..add(_record(opFooter, footer))
        ..add(fourdgsMagic))
      .toBytes();
}

Uint8List _minimalWithHugeFooterAppend() {
  final Uint8List prefix =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(_record(opHeader, _headerContent()))
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  final Uint8List footer =
      (BytesBuilder()
            ..add(_u64(0))
            ..add(_u64(0))
            ..add(_u32(0))
            ..add(Uint8List(fourdgsCrcBlockBytes + 4096)))
          .toBytes();
  return (BytesBuilder()
        ..add(prefix)
        ..add(_record(opFooter, footer))
        ..add(fourdgsMagic))
      .toBytes();
}

/// One indexed gaussian-birth chunk followed by an omitted, malformed chunk.
/// The omitted chunk has zero declared gaussians so the Header and index totals
/// still agree; only a pass over every framed Chunk can find its broken body.
Uint8List _gaussianBirthWithMalformedUnindexedChunk() {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(_record(opHeader, _headerContent(gaussianCount: 1)))
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  Uint8List chunk(Uint8List streams, int count) => _record(
    opChunk,
    (BytesBuilder()
          ..add(_f64(0.0))
          ..add(_f64(1.0))
          ..add(_u32(0))
          ..add(_u32(count))
          ..add(_string(''))
          ..add(_u64(streams.length))
          ..add(_u64(streams.length))
          ..add(streams))
        .toBytes(),
  );

  final Uint8List indexed = chunk(_keyframeStreams(windowIndex: 0), 1);
  final Uint8List malformed = chunk(Uint8List.fromList(<int>[attrPosition]), 0);
  final int chunkOffset = head.length;
  final int indexOffset = chunkOffset + indexed.length + malformed.length;
  final Uint8List index = _record(
    opChunkIndex,
    (BytesBuilder()
          ..add(_f64(0.0))
          ..add(_f64(1.0))
          ..add(_u64(chunkOffset))
          ..add(_u64(indexed.length))
          ..add(_u32(1))
          ..add(_u32(0)))
        .toBytes(),
  );
  final Uint8List footer = _record(
    opFooter,
    (BytesBuilder()
          ..add(_u64(indexOffset))
          ..add(_u64(0))
          ..add(_u32(0)))
        .toBytes(),
  );
  return (BytesBuilder()
        ..add(head)
        ..add(indexed)
        ..add(malformed)
        ..add(index)
        ..add(footer)
        ..add(fourdgsMagic))
      .toBytes();
}

/// Two equal-sized bands whose index ranges have been exchanged. Both decode
/// in isolation, so only associating the framing sequence with its Chunk
/// detects that indexed and streamed reads would attach different coefficients.
Uint8List _keyframesWithSwappedBands() {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(
                  temporalModel: 'keyframe-delta',
                  durationSec: 2.0,
                  gaussianCount: 1,
                  shDegree: 1,
                ),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  Uint8List chunk(double t0, double t1, int muTBin) => _record(
    opChunk,
    (BytesBuilder()
          ..add(_f64(t0))
          ..add(_f64(t1))
          ..add(_u32(0))
          ..add(_u32(1))
          ..add(_string(''))
          ..add(_u64(_keyframeStreams(windowIndex: 0, muTBin: muTBin).length))
          ..add(_u64(_keyframeStreams(windowIndex: 0, muTBin: muTBin).length))
          ..add(_keyframeStreams(windowIndex: 0, muTBin: muTBin)))
        .toBytes(),
  );
  final Uint8List first = chunk(0.0, 1.0, 0);
  final Uint8List firstBand = _shBandRecord(1, 0);
  final Uint8List second = chunk(1.0, 2.0, 32);
  final Uint8List secondBand = _shBandRecord(1, 1);
  final int firstOffset = head.length;
  final int firstBandOffset = firstOffset + first.length;
  final int secondOffset = firstBandOffset + firstBand.length;
  final int secondBandOffset = secondOffset + second.length;
  final int indexOffset = secondBandOffset + secondBand.length;

  Uint8List entry({
    required double t0,
    required double t1,
    required int chunkOffset,
    required int chunkLength,
    required int keyframeOffset,
    required int bandOffset,
    required int bandLength,
  }) => _record(
    opChunkIndex,
    (BytesBuilder()
          ..add(_f64(t0))
          ..add(_f64(t1))
          ..add(_u64(chunkOffset))
          ..add(_u64(chunkLength))
          ..add(_u32(1))
          ..add(_u32(1))
          ..addByte(1)
          ..add(_u64(bandOffset))
          ..add(_u64(bandLength))
          ..addByte(0)
          ..addByte(deltaModeKeyframe)
          ..add(_u64(0))
          ..add(_u64(keyframeOffset))
          ..add(_u16(0))
          ..add(_u64(1)))
        .toBytes(),
  );
  final Uint8List footer = _record(
    opFooter,
    (BytesBuilder()
          ..add(_u64(indexOffset))
          ..add(_u64(0))
          ..add(_u32(0)))
        .toBytes(),
  );
  return (BytesBuilder()
        ..add(head)
        ..add(first)
        ..add(firstBand)
        ..add(second)
        ..add(secondBand)
        ..add(
          entry(
            t0: 0.0,
            t1: 1.0,
            chunkOffset: firstOffset,
            chunkLength: first.length,
            keyframeOffset: firstOffset,
            bandOffset: secondBandOffset,
            bandLength: secondBand.length,
          ),
        )
        ..add(
          entry(
            t0: 1.0,
            t1: 2.0,
            chunkOffset: secondOffset,
            chunkLength: second.length,
            keyframeOffset: secondOffset,
            bandOffset: firstBandOffset,
            bandLength: firstBand.length,
          ),
        )
        ..add(footer)
        ..add(fourdgsMagic))
      .toBytes();
}

Uint8List _shBandRecord(int count, int value) {
  final int channels = shBandChannels[1]!;
  final Uint8List payload = Uint8List.fromList(
    zlib.encode(List<int>.filled(count * channels, value)),
  );
  return _record(
    opShBandStream,
    (BytesBuilder()
          ..addByte(1)
          ..addByte(0)
          ..addByte(1)
          ..addByte(modeRaw)
          ..addByte(codecDeflate)
          ..addByte(channels)
          ..add(_u32(count))
          ..add(_u64(payload.length))
          ..add(payload))
        .toBytes(),
  );
}

/// Keyframe(id 0), death(id 0), birth(id 0): every individual state is valid,
/// but identity 0 is illegally reused in the third state.
Uint8List _keyframeDeltaWithRetiredIdReuse() {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(
                  temporalModel: 'keyframe-delta',
                  durationSec: 3.0,
                  gaussianCount: 1,
                ),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  final Uint8List streams = _keyframeStreams(windowIndex: 0);
  final Uint8List keyframe = _record(
    opChunk,
    (BytesBuilder()
          ..add(_f64(0.0))
          ..add(_f64(1.0))
          ..add(_u32(0))
          ..add(_u32(1))
          ..add(_string(''))
          ..add(_u64(streams.length))
          ..add(_u64(streams.length))
          ..add(streams))
        .toBytes(),
  );
  final int keyframeOffset = head.length;

  Uint8List delta({
    required double t0,
    required double t1,
    required int referenceOffset,
    required int depth,
    required Uint8List births,
    required Uint8List deaths,
  }) {
    final Uint8List groups =
        (BytesBuilder()
              ..add(_u64(0))
              ..add(_u64(births.length))
              ..add(births)
              ..add(_u64(deaths.length))
              ..add(deaths))
            .toBytes();
    return _record(
      opDeltaChunk,
      (BytesBuilder()
            ..add(_f64(t0))
            ..add(_f64(t1))
            ..add(_u32(0))
            ..addByte(deltaModeChained)
            ..add(_u64(referenceOffset))
            ..add(_u64(keyframeOffset))
            ..add(_u16(depth))
            ..add(_u32(0))
            ..add(_u32(births.isEmpty ? 0 : 1))
            ..add(_u32(deaths.isEmpty ? 0 : 1))
            ..add(_string(''))
            ..add(_u64(groups.length))
            ..add(_u64(groups.length))
            ..add(groups))
          .toBytes(),
    );
  }

  final Uint8List death = delta(
    t0: 1.0,
    t1: 2.0,
    referenceOffset: keyframeOffset,
    depth: 1,
    births: Uint8List(0),
    deaths: _constStream(attrGaussianId, 1, 1, 0),
  );
  final int deathOffset = keyframeOffset + keyframe.length;
  final Uint8List birth = delta(
    t0: 2.0,
    t1: 3.0,
    referenceOffset: deathOffset,
    depth: 2,
    births: streams,
    deaths: Uint8List(0),
  );
  final int birthOffset = deathOffset + death.length;
  final int indexOffset = birthOffset + birth.length;

  Uint8List entry({
    required double t0,
    required double t1,
    required int chunkOffset,
    required int chunkLength,
    required int kind,
    required int referenceOffset,
    required int depth,
    required int liveCount,
  }) => _record(
    opChunkIndex,
    (BytesBuilder()
          ..add(_f64(t0))
          ..add(_f64(t1))
          ..add(_u64(chunkOffset))
          ..add(_u64(chunkLength))
          ..add(_u32(1))
          ..add(_u32(0))
          ..addByte(kind)
          ..addByte(kind == 0 ? deltaModeKeyframe : deltaModeChained)
          ..add(_u64(referenceOffset))
          ..add(_u64(keyframeOffset))
          ..add(_u16(depth))
          ..add(_u64(liveCount)))
        .toBytes(),
  );
  final Uint8List footer = _record(
    opFooter,
    (BytesBuilder()
          ..add(_u64(indexOffset))
          ..add(_u64(0))
          ..add(_u32(0)))
        .toBytes(),
  );
  return (BytesBuilder()
        ..add(head)
        ..add(keyframe)
        ..add(death)
        ..add(birth)
        ..add(
          entry(
            t0: 0.0,
            t1: 1.0,
            chunkOffset: keyframeOffset,
            chunkLength: keyframe.length,
            kind: 0,
            referenceOffset: 0,
            depth: 0,
            liveCount: 1,
          ),
        )
        ..add(
          entry(
            t0: 1.0,
            t1: 2.0,
            chunkOffset: deathOffset,
            chunkLength: death.length,
            kind: 1,
            referenceOffset: keyframeOffset,
            depth: 1,
            liveCount: 0,
          ),
        )
        ..add(
          entry(
            t0: 2.0,
            t1: 3.0,
            chunkOffset: birthOffset,
            chunkLength: birth.length,
            kind: 1,
            referenceOffset: deathOffset,
            depth: 2,
            liveCount: 1,
          ),
        )
        ..add(footer)
        ..add(fourdgsMagic))
      .toBytes();
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
  bool writeIndex = true,
  int? indexBandOffset,
  int? indexChunkOffset,
  int indexChunkLengthExtra = 0,
  Uint8List? beforeChunk,
  Uint8List? afterChunk,
  bool extraUnindexedKeyframe = false,
  int headerGaussianCount = 1,
  int positionChannels = 3,
  double headerDuration = 1.0,
  double chunkT0 = 0.0,
  double chunkT1 = 1.0,
  int? headerShDegree,
}) {
  final BytesBuilder headBuilder =
      BytesBuilder()
        ..add(fourdgsMagic)
        ..add(
          _record(
            opHeader,
            _headerContent(
              temporalModel: 'keyframe-delta',
              durationSec: headerDuration,
              gaussianCount: headerGaussianCount,
              shDegree: headerShDegree ?? (bandElementCount == null ? 0 : 1),
            ),
          ),
        )
        ..add(_record(opQuantization, _quantizationContent()))
        ..add(_record(opWindowTable, _windowTableContent()));
  if (beforeChunk != null) headBuilder.add(beforeChunk);
  final Uint8List head = headBuilder.toBytes();

  final Uint8List streams = _keyframeStreams(
    windowIndex: windowIndex,
    positionChannels: positionChannels,
  );
  final BytesBuilder chunk =
      BytesBuilder()
        ..add(_f64(chunkT0))
        ..add(_f64(chunkT1))
        ..add(_u32(0)) // level
        ..add(_u32(1)) // count
        ..add(_string('')) // compression
        ..add(_u64(streams.length)) // uncompressed_size
        ..add(_u64(streams.length))
        ..add(streams);
  final Uint8List chunkRecord = _record(opChunk, chunk.toBytes());
  final int chunkOffset = head.length;

  Uint8List bandRecord = Uint8List(0);
  if (bandElementCount != null) {
    final int channels = shBandChannels[1]!;
    final Uint8List payload = Uint8List.fromList(
      zlib.encode(List<int>.filled(bandElementCount * channels, 0)),
    );
    final BytesBuilder band =
        BytesBuilder()
          ..addByte(1) // band
          ..addByte(0) // attribute id, which a band record does not key on
          ..addByte(1) // symbol width
          ..addByte(modeRaw)
          ..addByte(codecDeflate)
          ..addByte(channels)
          ..add(_u32(bandElementCount))
          ..add(_u64(payload.length))
          ..add(payload);
    bandRecord = _record(opShBandStream, band.toBytes());
  }
  final int bandOffset = chunkOffset + chunkRecord.length;

  final BytesBuilder between = BytesBuilder()..add(bandRecord);
  if (afterChunk != null) between.add(afterChunk);
  if (extraUnindexedKeyframe) between.add(chunkRecord);
  final Uint8List betweenRecords = between.toBytes();
  final int indexOffset =
      chunkOffset + chunkRecord.length + betweenRecords.length;
  final BytesBuilder entry =
      BytesBuilder()
        ..add(_f64(chunkT0))
        ..add(_f64(chunkT1))
        ..add(_u64(indexChunkOffset ?? chunkOffset))
        ..add(_u64(chunkRecord.length + indexChunkLengthExtra))
        ..add(_u32(1)) // gaussian_count
        ..add(_u32(bandElementCount == null ? 0 : 1));
  if (bandElementCount != null) {
    entry
      ..addByte(1)
      ..add(_u64(indexBandOffset ?? bandOffset))
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
        ..add(_u64(writeIndex ? indexOffset : 0))
        ..add(_u64(0))
        ..add(_u32(0));
  final BytesBuilder out =
      BytesBuilder()
        ..add(head)
        ..add(chunkRecord)
        ..add(betweenRecords);
  if (writeIndex) out.add(indexRecord);
  out.add(_record(opFooter, footer.toBytes()));
  // After the Footer, which the format does not allow: the Footer is last. The
  // magic still closes the file, so nothing but the tail read can see it.
  if (afterFooter != null) out.add(afterFooter);
  out.add(fourdgsMagic);
  return out.toBytes();
}

/// A keyframe followed by one chained, zero-operation delta.
Uint8List _keyframeDeltaWithEmptyDelta({
  int indexGaussianCount = 0,
  int? indexReferenceOffset,
  int updateCount = 0,
  int birthCount = 0,
  int deathCount = 0,
  int deltaLevel = 0,
  Uint8List? updateGroup,
}) {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(
                  temporalModel: 'keyframe-delta',
                  durationSec: 2.0,
                  gaussianCount: 1,
                ),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  final Uint8List streams = _keyframeStreams(windowIndex: 0);
  final Uint8List keyframe = _record(
    opChunk,
    (BytesBuilder()
          ..add(_f64(0.0))
          ..add(_f64(1.0))
          ..add(_u32(0))
          ..add(_u32(1))
          ..add(_string(''))
          ..add(_u64(streams.length))
          ..add(_u64(streams.length))
          ..add(streams))
        .toBytes(),
  );
  final int keyframeOffset = head.length;
  final Uint8List updates = updateGroup ?? Uint8List(0);
  final BytesBuilder groups =
      BytesBuilder()
        ..add(_u64(updates.length))
        ..add(updates)
        ..add(_u64(0))
        ..add(_u64(0));
  final Uint8List groupBytes = groups.toBytes();
  final Uint8List delta = _record(
    opDeltaChunk,
    (BytesBuilder()
          ..add(_f64(1.0))
          ..add(_f64(2.0))
          ..add(_u32(deltaLevel))
          ..addByte(deltaModeChained)
          ..add(_u64(keyframeOffset))
          ..add(_u64(keyframeOffset))
          ..add(_u16(1))
          ..add(_u32(updateCount))
          ..add(_u32(birthCount))
          ..add(_u32(deathCount))
          ..add(_string(''))
          ..add(_u64(groupBytes.length))
          ..add(_u64(groupBytes.length))
          ..add(groupBytes))
        .toBytes(),
  );
  final int deltaOffset = keyframeOffset + keyframe.length;

  Uint8List entry({
    required double t0,
    required double t1,
    required int chunkOffset,
    required int chunkLength,
    required int gaussianCount,
    required int kind,
    required int referenceOffset,
    required int depth,
  }) =>
      (BytesBuilder()
            ..add(_f64(t0))
            ..add(_f64(t1))
            ..add(_u64(chunkOffset))
            ..add(_u64(chunkLength))
            ..add(_u32(gaussianCount))
            ..add(_u32(0))
            ..addByte(kind)
            ..addByte(kind == 0 ? deltaModeKeyframe : deltaModeChained)
            ..add(_u64(referenceOffset))
            ..add(_u64(keyframeOffset))
            ..add(_u16(depth))
            ..add(_u64(1)))
          .toBytes();

  final Uint8List firstIndex = _record(
    opChunkIndex,
    entry(
      t0: 0.0,
      t1: 1.0,
      chunkOffset: keyframeOffset,
      chunkLength: keyframe.length,
      gaussianCount: 1,
      kind: 0,
      referenceOffset: 0,
      depth: 0,
    ),
  );
  final Uint8List secondIndex = _record(
    opChunkIndex,
    entry(
      t0: 1.0,
      t1: 2.0,
      chunkOffset: deltaOffset,
      chunkLength: delta.length,
      gaussianCount: indexGaussianCount,
      kind: 1,
      referenceOffset: indexReferenceOffset ?? keyframeOffset,
      depth: 1,
    ),
  );
  final int indexOffset = deltaOffset + delta.length;
  final Uint8List footer = _record(
    opFooter,
    (BytesBuilder()
          ..add(_u64(indexOffset))
          ..add(_u64(0))
          ..add(_u32(0)))
        .toBytes(),
  );
  return (BytesBuilder()
        ..add(head)
        ..add(keyframe)
        ..add(delta)
        ..add(firstIndex)
        ..add(secondIndex)
        ..add(footer)
        ..add(fourdgsMagic))
      .toBytes();
}

/// One empty gaussian-birth Chunk named twice by the summary.
Uint8List _gaussianBirthWithDuplicateIndex() {
  final Uint8List head =
      (BytesBuilder()
            ..add(fourdgsMagic)
            ..add(_record(opHeader, _headerContent()))
            ..add(_record(opQuantization, _quantizationContent()))
            ..add(_record(opWindowTable, _windowTableContent())))
          .toBytes();
  final Uint8List chunk = _stateChunk(Uint8List(0), 0);
  final int chunkOffset = head.length;
  final Uint8List entry =
      (BytesBuilder()
            ..add(_f64(0.0))
            ..add(_f64(1.0))
            ..add(_u64(chunkOffset))
            ..add(_u64(chunk.length))
            ..add(_u32(0))
            ..add(_u32(0)))
          .toBytes();
  final Uint8List first = _record(opChunkIndex, entry);
  final Uint8List second = _record(opChunkIndex, entry);
  final int indexOffset = chunkOffset + chunk.length;
  final Uint8List footer = _record(
    opFooter,
    (BytesBuilder()
          ..add(_u64(indexOffset))
          ..add(_u64(0))
          ..add(_u32(0)))
        .toBytes(),
  );
  return (BytesBuilder()
        ..add(head)
        ..add(chunk)
        ..add(first)
        ..add(second)
        ..add(footer)
        ..add(fourdgsMagic))
      .toBytes();
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
Uint8List _keyframeStreams({
  required int windowIndex,
  int positionChannels = 3,
  int muTBin = 0,
  bool includeGaussianId = true,
}) {
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
        id == attrPosition ? positionChannels : channels[id]!,
        1,
        id == attrWindowIndex
            ? windowIndex
            : id == attrMuT
            ? muTBin
            : 0,
      ),
    );
  }
  if (includeGaussianId) out.add(_constStream(attrGaussianId, 1, 1, 0));
  return out.toBytes();
}

Uint8List _stateChunk(Uint8List streams, int count) => _record(
  opChunk,
  (BytesBuilder()
        ..add(_f64(0.0))
        ..add(_f64(1.0))
        ..add(_u32(0))
        ..add(_u32(count))
        ..add(_string(''))
        ..add(_u64(streams.length))
        ..add(_u64(streams.length))
        ..add(streams))
      .toBytes(),
);

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

class _IoFailureReadable implements FourdgsReadable {
  @override
  Future<int> size() async => fourdgsMagic.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    throw const FileSystemException('read failed');
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

Uint8List _headerContent({
  String temporalModel = 'gaussian-birth',
  String profile = '',
  int shDegree = 0,
  int flags = 0,
  double durationSec = 1.0,
  int gaussianCount = 0,
}) {
  final BytesBuilder body =
      BytesBuilder()
        ..add(_string(profile))
        ..add(_string('')) // library
        ..add(_f64(durationSec)) // duration_sec
        ..add(_u64(gaussianCount))
        ..add(_f64(0.05)) // cutoff
        ..add(_string(temporalModel));
  for (int i = 0; i < 6; i++) {
    body.add(_f64(0.0)); // aabb
  }
  body
    ..addByte(shDegree) // sh_degree
    ..addByte(flags)
    ..add(_u32(0)); // empty attribute map
  return body.toBytes();
}

Uint8List _quantizationContent({
  String scheme = 'uniform-v1',
  List<int> shBitDepths = const <int>[],
}) {
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
  if (shBitDepths.isNotEmpty) {
    body
      ..addByte(shBitDepths.length)
      ..add(shBitDepths);
  }
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
