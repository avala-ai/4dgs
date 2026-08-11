// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The identifier a refusal carries, which is the thing six SDKs are compared
/// on.
///
/// The exception *class* is far too coarse to compare on: [FourdgsUnsupportedCodec]
/// covers an unknown temporal model, an unknown quantization scheme and an
/// unknown stream codec alike, so "it threw [FourdgsUnsupportedCodec]" cannot
/// tell a decoder that refused for the right reason from one that refused for
/// the wrong one. These are the strings the invalid corpus diffs, and a typo in
/// one of them reads in CI like a decoder bug rather than like a typo.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

/// The refusal [body] produced, or the assertion that it produced none.
String? _refusalOf(void Function() body) {
  try {
    body();
  } on FourdgsException catch (error) {
    return error.refusalCode;
  }
  fail('expected a refusal');
}

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

List<int> _u64(int v) {
  final b = ByteData(8);
  b.setUint32(0, v & 0xFFFFFFFF, Endian.little);
  b.setUint32(4, v >> 32, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _f64(double v) =>
    (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List();

List<int> _string(String s) {
  final raw = utf8.encode(s);
  return <int>[..._u32(raw.length), ...raw];
}

/// The magic, with one byte replaced. Every case here is one byte away from a
/// file this reader accepts, so nothing but that byte can be what it is refused
/// for.
Uint8List _magicWith(int index, int value) {
  final head = Uint8List.fromList(fourdgsMagic);
  head[index] = value;
  return head;
}

/// A Header record's content, complete but for whatever the case overrides.
Uint8List _headerContent({String temporalModel = 'gaussian-birth'}) {
  final body =
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
    ..add(_u32(0)); // empty attributes map
  return body.toBytes();
}

/// A Quantization record's content, complete but for the scheme under test.
Uint8List _quantizationContent({String scheme = 'uniform-v1'}) {
  final body = BytesBuilder()..add(_string(scheme));
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

/// One constant-mode attribute stream carrying [value] in every channel.
///
/// Constant mode because it makes a whole chunk of eleven streams cheap to
/// write by hand: the payload holds `channels` symbols however many elements
/// the header declares.
Uint8List _constStream(int attributeId, int channels, int count, int value) {
  final zigzag = value < 0 ? (-value * 2) - 1 : value * 2;
  final payload = Uint8List.fromList(
    zlib.encode(List<int>.filled(channels, zigzag)),
  );
  final out =
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

/// Every required attribute stream for a one-gaussian chunk, with that
/// gaussian's window index set to [windowIndex] and everything else at zero.
Uint8List _oneGaussianStreams({required int windowIndex}) {
  const channels = <int, int>{
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
  final out = BytesBuilder();
  for (final id in requiredAttributes) {
    out.add(
      _constStream(
        id,
        channels[id]!,
        1,
        id == attrWindowIndex ? windowIndex : 0,
      ),
    );
  }
  return out.toBytes();
}

const FourdgsSteps _unitSteps = FourdgsSteps(
  pos: 1.0,
  scaleLog: 1.0,
  rot: 1.0,
  rgb: 1.0,
  alpha: 1.0,
  motion: 1.0,
  time: 1.0,
  sigmaLog: 1.0,
  sh: 1,
);

FourdgsDecodedChunk _decodeOneGaussian({
  required int windowIndex,
  required List<FourdgsWindow> windows,
  int chunkOffset = 0,
}) {
  return decodeChunkStreams(
    _oneGaussianStreams(windowIndex: windowIndex),
    1,
    _unitSteps,
    const <double>[0.0, 0.0, 0.0],
    windows,
    cutoff: 0.05,
    chunkOffset: chunkOffset,
  );
}

/// The message [body] refused with, or `null` when it refused with nothing.
String? _messageOf(void Function() body) {
  try {
    body();
  } on FourdgsException catch (e) {
    return e.message;
  }
  return null;
}

void main() {
  group('a named refusal carries the identifier every SDK is compared on', () {
    test('the magic tells "not our file" apart from "not our version"', () {
      expect(
        _refusalOf(() => checkMagic(_magicWith(5, 0x39))),
        refusalUnsupportedMajorVersion,
      );
      expect(_refusalOf(() => checkMagic(Uint8List(8))), refusalMagicMismatch);
    });

    test('an unknown temporal model and an empty one share an identifier', () {
      // A declaration of nothing is not a default, and it is refused under the
      // same name as a future model's: the difference between them is a
      // sentence for a human, not a rule a caller branches on.
      expect(
        _refusalOf(
          () => FourdgsHeader.parse(
            _headerContent(temporalModel: 'frame-sequence'),
          ),
        ),
        refusalUnknownTemporalModel,
      );
      expect(
        _refusalOf(
          () => FourdgsHeader.parse(_headerContent(temporalModel: '')),
        ),
        refusalUnknownTemporalModel,
      );
    });

    test('an unknown quantization scheme is named', () {
      expect(
        _refusalOf(
          () => FourdgsQuantization.parse(
            _quantizationContent(scheme: 'uniform-v9'),
          ),
        ),
        refusalUnknownQuantizationScheme,
      );
    });

    test('both routes to an unknown stream codec answer the same name', () {
      // A chunk names its codec; a stream numbers it. The invalid corpus only
      // takes the numbered route, so nothing outside this test holds the named
      // one down — and one broken rule should not be diagnosed by name or
      // anonymously depending on which of its two spellings the file used.
      expect(
        _refusalOf(
          () => decodeChunkStreams(
            Uint8List(0),
            0,
            _unitSteps,
            const <double>[0.0, 0.0, 0.0],
            const <FourdgsWindow>[FourdgsWindow(0.0, 1.0)],
            cutoff: 0.05,
            compression: 'zstd',
          ),
        ),
        refusalUnknownStreamCodec,
      );
      expect(
        _refusalOf(
          () => decodeChunkStreams(
            _constStreamWithCodec(9),
            1,
            _unitSteps,
            const <double>[0.0, 0.0, 0.0],
            const <FourdgsWindow>[FourdgsWindow(0.0, 1.0)],
            cutoff: 0.05,
          ),
        ),
        refusalUnknownStreamCodec,
      );
    });

    test('a window index outside the table is refused, not clamped', () {
      // Clamping substitutes one gaussian's lifetime for another's, in a file
      // that is already wrong in some way nobody has diagnosed: the scene
      // renders, and the fault is gone. This decoder used to clamp here, which
      // is why the invalid corpus's WindowIndexOutOfRange variant decoded
      // cleanly to a plausible scene.
      expect(
        _refusalOf(
          () => _decodeOneGaussian(
            windowIndex: 3,
            windows: const <FourdgsWindow>[FourdgsWindow(0.0, 1.0)],
          ),
        ),
        refusalWindowIndexOutOfRange,
      );
      expect(
        _refusalOf(
          () => _decodeOneGaussian(
            windowIndex: -1,
            windows: const <FourdgsWindow>[FourdgsWindow(0.0, 1.0)],
          ),
        ),
        refusalWindowIndexOutOfRange,
      );
      // An absent table is one default (0, 0) window, so index 0 resolves
      // against it and index 1 does not.
      expect(
        _decodeOneGaussian(
          windowIndex: 0,
          windows: const <FourdgsWindow>[],
        ).windowIndex.single,
        0,
      );
      expect(
        _refusalOf(
          () => _decodeOneGaussian(
            windowIndex: 1,
            windows: const <FourdgsWindow>[],
          ),
        ),
        refusalWindowIndexOutOfRange,
      );
    });

    test('the window-index refusal says which gaussian and which chunk', () {
      // The identifier says which rule broke; it cannot say where. A file has
      // many chunks and every one of them decodes through the same function, so
      // "window index 3 is outside the 1-entry window table" is a true sentence
      // that leaves its holder with a whole file to search (AGENTS.md §6).
      final message = _messageOf(
        () => _decodeOneGaussian(
          windowIndex: 3,
          windows: const <FourdgsWindow>[FourdgsWindow(0.0, 1.0)],
          chunkOffset: 4096,
        ),
      );
      expect(message, isNotNull);
      expect(
        message,
        allOf(
          contains('gaussian 0'),
          contains('byte 4096'),
          contains('window index 3'),
          contains('1-entry window table'),
        ),
      );
    });

    test('one refusal, one sentence, wherever it is reached from', () {
      // Three sites reach this refusal — the gaussian-birth chunk decoder and
      // both keyframe-delta grid lookups — and they build the sentence in one
      // place for that reason. Three separately written spellings is three
      // chances for one of them to leave the location out, which is exactly how
      // the chunk decoder's came to name only the value and the table size.
      final located = windowIndexOutOfRange(4, 1, gaussian: 'gaussian 77');
      expect(located.refusalCode, refusalWindowIndexOutOfRange);
      expect(
        located.message,
        allOf(
          contains('gaussian 77'),
          contains('window index 4'),
          contains('1-entry window table'),
        ),
      );
      // A caller with no record to blame drops the clause rather than printing
      // a dangling "gaussian -1".
      final bare = windowIndexOutOfRange(4, 1);
      expect(bare.refusalCode, refusalWindowIndexOutOfRange);
      expect(bare.message, isNot(contains('gaussian')));
      expect(bare.message, contains('window index 4'));
    });

    test('an error the refusal table does not name carries no identifier', () {
      // Null is "this is not one of the refusals the corpus compares", not "no
      // error": a cut file is a real failure, and a recoverable one.
      expect(_refusalOf(() => checkMagic(Uint8List(3))), isNull);
    });

    test('every identifier a raise site uses is one of the six', () {
      // The set is the vocabulary; a seventh string invented in one language is
      // a conformance failure everywhere else.
      expect(fourdgsRefusalCodes, hasLength(6));
      expect(<String>{
        refusalMagicMismatch,
        refusalUnsupportedMajorVersion,
        refusalUnknownTemporalModel,
        refusalUnknownQuantizationScheme,
        refusalUnknownStreamCodec,
        refusalWindowIndexOutOfRange,
      }, fourdgsRefusalCodes);
    });
  });

  group('the magic distinguishes a bad sentinel from a bad version', () {
    // The version byte must be the ONLY difference for this to be a version
    // problem. Testing only that bytes 1-4 read `4DGS` — as this reader did —
    // reported a file whose leading 0x89 had been flipped as "4dgs major
    // version 1 is not supported by this reader", which sends its holder
    // looking for a newer reader that would never have helped. Nothing inside
    // Dart could see it: both answers are a FourdgsUnsupportedVersion carrying
    // a plausible sentence.
    test('a corrupted 0x89 sentinel is not a version problem', () {
      expect(
        () => checkMagic(_magicWith(0, 0x88)),
        throwsA(
          isA<FourdgsUnsupportedVersion>().having(
            (FourdgsUnsupportedVersion e) => e.message,
            'message',
            contains('not a 4dgs file'),
          ),
        ),
      );
    });

    test('a mangled line ending is not a version problem either', () {
      // The CR LF is there to catch transports that rewrite line endings, which
      // is exactly the corruption that leaves `4DGS1` intact.
      expect(
        _refusalOf(() => checkMagic(_magicWith(6, 0x0A))),
        refusalMagicMismatch,
      );
      expect(
        _refusalOf(() => checkMagic(_magicWith(7, 0x0D))),
        refusalMagicMismatch,
      );
    });
  });
}

/// A one-gaussian chunk whose position stream declares codec [codec].
///
/// Only the first stream is reached: the codec is refused before the rest of
/// the block is read.
Uint8List _constStreamWithCodec(int codec) {
  final stream = _constStream(attrPosition, 3, 1, 0);
  stream[3] = codec;
  return stream;
}
