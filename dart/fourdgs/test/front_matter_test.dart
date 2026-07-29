// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The front-matter scan reaches the first Chunk, whatever the probe size.
///
/// This is the one behavioural claim the conformance corpus cannot make on its
/// own. The harness runs each runner once, at the default 64 KiB probe, on
/// scenes whose whole front matter fits inside it — so the multi-read path is
/// never taken and a scan that stopped early would still pass all 79 checks.
///
/// What could go wrong is specific. The specification fixes the Header first
/// and the Footer last and leaves the order of everything between them free, so
/// a Camera, a Metadata record or an Attachment may sit *after* the Window
/// Table — and behind an embedded audio track large enough to push it out of
/// the probe. A reader that stopped as soon as it had the records it strictly
/// needed would report those scenes as having no camera and no metadata, and
/// would do it silently. What a reader says about a file must not depend on
/// where its probe happened to stop, so that is what these tests assert:
/// shrinking the probe changes the number of round trips and nothing else.
///
/// These tests decode real corpus files, which are generated rather than
/// committed. They FAIL rather than skip when the corpus is absent: a test that
/// quietly tested nothing is worse than no test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';
import 'package:test/test.dart';

/// Corpus, relative to this package's root — where `dart test` runs.
const String corpus = '../../tests/conformance/data';

/// A scene carrying audio, a camera and metadata, so the records that sit
/// behind the audio track are the ones being looked for.
const String withEverything =
    'OneWindow-UseChunkIndex-UseCrc-WithCamera-WithMetadata-WithSpatialAudio';
const String withMultiple =
    'OneWindow-UseChunkIndex-UseCrc-WithMultipleAudioSources';
const String withLargeAudio = 'OneWindow-UseChunkIndex-UseCrc-WithLargeAudio';

/// Counts requests so a claim about round trips is measured, not asserted.
class _Counting implements FourdgsReadable {
  _Counting(this._inner);

  final FourdgsReadable _inner;
  int reads = 0;
  int bytesRead = 0;

  @override
  Future<int> size() => _inner.size();

  @override
  Future<Uint8List> read(int offset, int length) {
    reads++;
    bytesRead += length;
    return _inner.read(offset, length);
  }
}

void main() {
  final path = '$corpus/$withEverything.4dgs';

  setUpAll(() {
    if (!File(path).existsSync()) {
      throw StateError(
        'the corpus is missing: run `python3 tests/conformance/generate.py` '
        'from the repository root. These tests decode real files and must not '
        'skip themselves into a green run.',
      );
    }
  });

  test('truncation does not excuse audio when the Header flag is clear', () {
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    final header = iterRecords(
      bytes,
      fourdgsMagic.length,
    ).firstWhere((record) => record.opcode == opHeader);
    final payload = iterRecords(
      bytes,
      fourdgsMagic.length,
    ).firstWhere((record) => record.opcode == opAudioData);
    final descriptor = iterRecords(
      bytes,
      fourdgsMagic.length,
    ).firstWhere((record) => record.opcode == opAudioSource);
    final sourceId = FourdgsCursor(descriptor.content).u32();
    final cursor =
        FourdgsCursor(header.content)
          ..string()
          ..string()
          ..skip(8 + 8 + 8)
          ..string()
          ..skip(6 * 8)
          ..u8();
    header.content[cursor.pos] &= ~headerFlagHasAudio;

    expect(
      () => readFourdgsBytes(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (error) => error.toString(),
          'message',
          contains(
            'Audio Source record for source id $sourceId at byte '
            '${descriptor.offset}',
          ),
        ),
      ),
    );
    expect(
      () => readFourdgsBytes(Uint8List.sublistView(bytes, 0, payload.offset)),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (error) => error.toString(),
          'message',
          contains(
            'Audio Source record for source id $sourceId at byte '
            '${descriptor.offset}',
          ),
        ),
      ),
    );
  });

  group('the front-matter scan reaches the first Chunk', () {
    // 64 bytes cannot hold the magic plus the Header, so every record after the
    // first costs a round trip. If anything is going to be missed, it is missed
    // here.
    for (final probe in <int>[64 * 1024, 4096, 1024, 256, 64]) {
      test('a $probe byte probe finds every front-matter record', () async {
        final file = await FourdgsFileReadable.open(path);
        final source = _Counting(file);
        try {
          final scene = await openFourdgsIndexed(source, probeBytes: probe);

          expect(scene.header.hasAudio, isTrue);
          expect(scene.audioSourceCount, 1);
          expect(scene.audioRange, isNotNull);
          final descriptors = await readFourdgsAudioSourceDescriptors(
            source,
            scene,
          );
          expect(descriptors.single.codec, 'wav');
          expect(descriptors.single.spatial, isTrue);
          expect(
            scene.cameraRange,
            isNotNull,
            reason: 'the Camera sits behind the audio track',
          );
          expect(scene.metadataRanges, hasLength(1));
          expect(scene.windows, isNotEmpty);
          expect(scene.index, isNotEmpty);

          // And the records actually read back, not merely framed.
          expect(await readFourdgsAudio(source, scene), isNotNull);
          expect(await readFourdgsCamera(source, scene), isNotNull);
          expect(await readFourdgsMetadata(source, scene), hasLength(1));
        } finally {
          await file.close();
        }
      });
    }

    test(
      'a smaller probe costs more round trips and never a different answer',
      () async {
        Future<
          ({
            int reads,
            int headerBytes,
            int audioSources,
            bool camera,
            int metadata,
          })
        >
        open(int probe) async {
          final file = await FourdgsFileReadable.open(path);
          final source = _Counting(file);
          try {
            final scene = await openFourdgsIndexed(source, probeBytes: probe);
            return (
              reads: source.reads,
              headerBytes: scene.headerBytes,
              audioSources: scene.audioSourceCount,
              camera: scene.cameraRange != null,
              metadata: scene.metadataRanges.length,
            );
          } finally {
            await file.close();
          }
        }

        final wide = await open(64 * 1024);
        final narrow = await open(64);

        // The trade, stated as a test: more requests, fewer bytes, same answer.
        // Fewer bytes because a record this reader does not parse is stepped over
        // by arithmetic — a narrow probe never pulls the audio track it is
        // walking past, where a wide one may sweep it up incidentally.
        expect(narrow.reads, greaterThan(wide.reads));
        expect(narrow.headerBytes, lessThan(wide.headerBytes));
        expect(narrow.audioSources, wide.audioSources);
        expect(narrow.camera, wide.camera);
        expect(narrow.metadata, wide.metadata);
      },
    );

    test(
      'a probe too small to hold the magic and one record header is refused',
      () {
        // Refused up front rather than allowed to loop forever making no progress.
        expect(
          () => openFourdgsIndexed(FourdgsBytes(Uint8List(64)), probeBytes: 8),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'a front matter that never reaches the first Chunk within the read cap is refused',
      () {
        // The scan spends one round per record too big for the probe and gives up after a
        // bounded number of rounds. A file with more oversized front-matter records than the
        // cap — legal, since the format sets no count limit — must be refused, not opened on
        // the partial scan the cap left behind, which the Header flag would still agree with.
        // Built by splicing many records too big for a minimum probe before the first Chunk.
        final base = File(path).readAsBytesSync();
        int at = fourdgsMagic.length;
        while (at + recordHeaderBytes <= base.length) {
          final lo = ByteData.sublistView(
            base,
            at + 1,
            at + 5,
          ).getUint32(0, Endian.little);
          final hi = ByteData.sublistView(
            base,
            at + 5,
            at + 9,
          ).getUint32(0, Endian.little);
          if (base[at] == opChunk) break;
          at += recordHeaderBytes + lo + hi * 0x100000000;
        }
        final content = Uint8List(40);
        final filler = BytesBuilder();
        for (int i = 0; i < 300; i++) {
          filler.addByte(opMetadata);
          filler.add(
            (ByteData(8)
                  ..setUint32(0, content.length, Endian.little)
                  ..setUint32(4, 0, Endian.little))
                .buffer
                .asUint8List(),
          );
          filler.add(content);
        }
        final bytes =
            (BytesBuilder()
                  ..add(base.sublist(0, at))
                  ..add(filler.toBytes())
                  ..add(base.sublist(at)))
                .toBytes();

        expect(
          () => openFourdgsIndexed(
            FourdgsBytes(bytes),
            probeBytes: recordHeaderBytes + fourdgsMagic.length,
          ),
          throwsA(
            isA<FourdgsMalformedFile>().having(
              (FourdgsMalformedFile e) => e.toString(),
              'message',
              contains('more than 256 reads'),
            ),
          ),
        );
      },
    );

    test('a front-matter record that extends past EOF is refused', () {
      final bytes = Uint8List.fromList(File(path).readAsBytesSync());
      int at = fourdgsMagic.length;
      while (at + recordHeaderBytes <= bytes.length) {
        final length = ByteData.sublistView(
          bytes,
          at + 1,
          at + recordHeaderBytes,
        ).getUint64(0, Endian.little);
        if (bytes[at] == opAudioData) break;
        at += recordHeaderBytes + length;
      }
      expect(bytes[at], opAudioData);

      // Keep the Audio Data prefix and its declared payload valid, but make the outer
      // record framing swallow the footer and run beyond the resource. The indexed
      // reader must reject the framing rather than treating "past EOF" as "at EOF".
      ByteData.sublistView(
        bytes,
        at + 1,
        at + recordHeaderBytes,
      ).setUint64(0, bytes.length, Endian.little);

      expect(
        () => openFourdgsIndexed(FourdgsBytes(bytes), probeBytes: 64),
        throwsA(
          isA<FourdgsTruncatedFile>().having(
            (FourdgsTruncatedFile e) => e.toString(),
            'message',
            contains('runs past the end of the file'),
          ),
        ),
      );
    });
  });

  group('the streamed and indexed paths agree about the front matter', () {
    test('both find the same camera, metadata and audio', () async {
      final bytes = File(path).readAsBytesSync();
      final streamed = readFourdgsBytes(bytes);

      final file = await FourdgsFileReadable.open(path);
      try {
        final scene = await openFourdgsIndexed(file);
        final camera = await readFourdgsCamera(file, scene);
        final metadata = await readFourdgsMetadata(file, scene);
        final audio = await readFourdgsAudioSources(file, scene);

        expect(streamed.camera, isNotNull);
        expect(camera!.fovYDeg, streamed.camera!.fovYDeg);
        expect(
          metadata.map((FourdgsMetadata m) => m.name),
          streamed.metadata.map((FourdgsMetadata m) => m.name),
        );
        expect(audio.single.codec, streamed.audioSources.single.codec);
        expect(
          audio.single.data.length,
          streamed.audioSources.single.data.length,
        );
        expect(audio.single.position, streamed.audioSources.single.position);
      } finally {
        await file.close();
      }
    });
  });

  group('audio sources remain independently range-readable', () {
    test('a large payload is stepped over while opening', () async {
      final file = await FourdgsFileReadable.open(
        '$corpus/$withLargeAudio.4dgs',
      );
      final source = _Counting(file);
      try {
        final scene = await openFourdgsIndexed(source);
        final toOpen = source.bytesRead;
        final beforeDescriptor = source.bytesRead;
        final descriptor =
            (await readFourdgsAudioSourceDescriptors(source, scene)).single;

        expect(descriptor.dataLength, greaterThan(64 * 1024));
        expect(source.bytesRead - beforeDescriptor, lessThan(4096));
        expect(
          toOpen,
          lessThan(descriptor.dataLength),
          reason: 'opening must step over the encoded payload by length',
        );
      } finally {
        await file.close();
      }
    });

    test('descriptors and moving state do not require payload bytes', () async {
      final file = await FourdgsFileReadable.open('$corpus/$withMultiple.4dgs');
      final source = _Counting(file);
      try {
        final scene = await openFourdgsIndexed(source);
        expect(scene.audioSourceCount, 2);

        final before = source.reads;
        final descriptors = await readFourdgsAudioSourceDescriptors(
          source,
          scene,
        );
        expect(source.reads - before, descriptors.length);
        final moving = descriptors.singleWhere((item) => item.sourceId == 42);
        expect(moving.keyframes, hasLength(2));

        final state = await readFourdgsAudioSourceState(
          source,
          scene,
          moving.sourceId,
          scene.durationSec / 2,
        );
        expect(state.position, isNot(moving.position));

        final prefix = await readFourdgsAudioRange(
          source,
          scene,
          moving.sourceId,
          0,
          4,
        );
        expect(String.fromCharCodes(prefix), 'RIFF');
        await expectLater(
          readFourdgsAudioRange(
            source,
            scene,
            moving.sourceId,
            moving.dataLength - 2,
            4,
          ),
          throwsA(isA<FourdgsMalformedFile>()),
        );
      } finally {
        await file.close();
      }
    });

    test('range reads validate descriptor and payload lengths first', () async {
      final bytes = Uint8List.fromList(
        await File('$corpus/$withEverything.4dgs').readAsBytes(),
      );
      final descriptor = iterRecords(
        bytes,
        fourdgsMagic.length,
      ).firstWhere((record) => record.opcode == opAudioSource);
      final cursor = FourdgsCursor(descriptor.content);
      final sourceId = cursor.u32();
      cursor
        ..string()
        ..string()
        ..string();
      final view = ByteData.sublistView(descriptor.content);
      final declared = view.getUint64(cursor.pos, Endian.little);
      view.setUint64(cursor.pos, declared + 1, Endian.little);

      final source = FourdgsBytes(bytes);
      final scene = await openFourdgsIndexed(source);
      await expectLater(
        readFourdgsAudioRange(source, scene, sourceId, 0, 1),
        throwsA(
          isA<FourdgsMalformedFile>().having(
            (error) => error.toString(),
            'message',
            contains('Audio Data record declares'),
          ),
        ),
      );
    });
  });
}
