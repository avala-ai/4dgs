// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The front-matter scan reaches the first Chunk, whatever the probe size.
///
/// This is the one behavioural claim the conformance corpus cannot make on its
/// own. The harness runs each runner once, at the default 64 KiB probe, on
/// scenes whose whole front matter fits inside it — so the multi-read path is
/// never taken and a scan that stopped early would still pass all 67 checks.
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
    'OneWindow-UseChunkIndex-UseCrc-WithAudio-WithCamera-WithMetadata';

/// Counts requests so a claim about round trips is measured, not asserted.
class _Counting implements FourdgsReadable {
  _Counting(this._inner);

  final FourdgsReadable _inner;
  int reads = 0;

  @override
  Future<int> size() => _inner.size();

  @override
  Future<Uint8List> read(int offset, int length) {
    reads++;
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
          expect(scene.audioRange, isNotNull);
          expect(
            scene.audioCodec,
            isNotEmpty,
            reason:
                'the codec name is in the record prefix and must survive a probe that stops before it',
          );
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
            String? codec,
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
              codec: scene.audioCodec,
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
        expect(narrow.codec, wide.codec);
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
        final audio = await readFourdgsAudio(file, scene);

        expect(streamed.camera, isNotNull);
        expect(camera!.fovYDeg, streamed.camera!.fovYDeg);
        expect(
          metadata.map((FourdgsMetadata m) => m.name),
          streamed.metadata.map((FourdgsMetadata m) => m.name),
        );
        expect(audio!.codec, streamed.audio!.codec);
        expect(audio.data.length, streamed.audio!.data.length);
      } finally {
        await file.close();
      }
    });
  });
}
