// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Values that decode into plausible-looking output instead of an error.
///
/// Every case here is a field the decoder used to take at its word, and none of
/// them announces itself: a NaN bound is not a crash, it is a comparison that is
/// false at every instant, so the gaussians behind it silently never appear. An
/// out-of-registry enum is still a well-formed integer. A header total that
/// disagrees with the chunks is a scene that opens cleanly and is quietly short.
///
/// The Mission Control copy of this decoder grew these checks first, against its
/// own 1,663-line hostile-input suite. This file is the subset that pins them
/// here, in the published package — the one Mission Control is meant to switch
/// to, which cannot happen while switching would lose the hardening.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

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

Uint8List _headerContent({
  String temporalModel = 'gaussian-birth',
  int shDegree = 0,
  double durationSec = 1.0,
  double cutoff = 0.05,
}) {
  final body =
      BytesBuilder()
        ..add(_string('')) // profile
        ..add(_string('')) // library
        ..add(_f64(durationSec))
        ..add(_u64(0)) // gaussian count
        ..add(_f64(cutoff))
        ..add(_string(temporalModel));
  for (int i = 0; i < 6; i++) {
    body.add(_f64(0.0)); // aabb
  }
  body
    ..addByte(shDegree)
    ..addByte(0) // flags
    ..add(_u32(0)); // empty attribute map
  return body.toBytes();
}

Uint8List _windowTableContent({required double lo, required double hi}) {
  final body =
      BytesBuilder()
        ..add(_u32(1))
        ..add(_f64(lo))
        ..add(_f64(hi));
  return body.toBytes();
}

Uint8List _chunkIndexEntryContent({
  required double t0,
  required double t1,
  int gaussianCount = 1,
}) {
  final body =
      BytesBuilder()
        ..add(_f64(t0))
        ..add(_f64(t1))
        ..add(_u64(0)) // chunkOffset
        ..add(_u64(0)) // chunkLength
        ..add(_u32(gaussianCount))
        ..add(_u32(0)); // bandCount
  return body.toBytes();
}

void main() {
  group('the header refuses what nothing downstream re-checks', () {
    test('an SH degree outside the 0-3 registry is refused', () {
      // Out of range is not merely unknown. A decoded-byte budget prices an
      // unrecognised band at zero while the coefficient count keeps growing
      // with the degree, so a buffer sized from the first is not the scene the
      // second goes on to decode.
      expect(
        () => FourdgsHeader.parse(_headerContent(shDegree: 255)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsHeader.parse(_headerContent(shDegree: 4)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      for (final int ok in <int>[0, 1, 2, 3]) {
        expect(
          FourdgsHeader.parse(_headerContent(shDegree: ok)).shDegree,
          ok,
          reason: 'degree $ok must still parse',
        );
      }
    });

    test('a temporal model outside the registry is named, not assumed', () {
      expect(
        () => FourdgsHeader.parse(
          _headerContent(temporalModel: 'gaussian-birth-poly'),
        ),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
      expect(
        () => FourdgsHeader.parse(_headerContent(temporalModel: '')),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
    });

    test('both models this build implements still parse', () {
      // `keyframe-delta` is legal and is read by its own path. Refusing it here
      // would make that reader unreachable, which is a different bug from the
      // one the check above exists for.
      expect(
        FourdgsHeader.parse(_headerContent()).temporalModel,
        'gaussian-birth',
      );
      expect(
        FourdgsHeader.parse(
          _headerContent(temporalModel: 'keyframe-delta'),
        ).temporalModel,
        'keyframe-delta',
      );
    });

    test('a NaN, infinite, or negative duration is refused', () {
      for (final double bad in <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -1.0,
        -0.0001,
      ]) {
        expect(
          () => FourdgsHeader.parse(_headerContent(durationSec: bad)),
          throwsA(isA<FourdgsMalformedFile>()),
          reason: 'duration $bad',
        );
      }
    });

    test('a zero-duration scene is still legal', () {
      // The NoData conformance fixture is exactly this shape.
      expect(
        FourdgsHeader.parse(_headerContent(durationSec: 0.0)).durationSec,
        0.0,
      );
    });

    test('a cutoff outside (0, 1] is refused', () {
      for (final double bad in <double>[
        double.nan,
        0.0,
        -0.1,
        1.0001,
        double.infinity,
      ]) {
        expect(
          () => FourdgsHeader.parse(_headerContent(cutoff: bad)),
          throwsA(isA<FourdgsMalformedFile>()),
          reason: 'cutoff $bad',
        );
      }
      expect(FourdgsHeader.parse(_headerContent(cutoff: 1.0)).cutoff, 1.0);
    });
  });

  group('intervals that no instant can satisfy are refused', () {
    test('a NaN or inverted validity window is refused', () {
      expect(
        () => FourdgsWindowTable.parse(
          _windowTableContent(lo: double.nan, hi: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsWindowTable.parse(
          _windowTableContent(lo: 0.0, hi: double.nan),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsWindowTable.parse(_windowTableContent(lo: 5.0, hi: 1.0)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a degenerate zero-length window is still accepted', () {
      // `lo == hi` is a legitimate zero-duration scene, so it must not be swept
      // up alongside `lo > hi`.
      final FourdgsWindowTable table = FourdgsWindowTable.parse(
        _windowTableContent(lo: 2.0, hi: 2.0),
      );
      expect(table.windows.single.lo, table.windows.single.hi);
    });

    test('a NaN or inverted chunk-index interval is refused', () {
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: double.nan, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 5.0, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a nonempty chunk over a zero-width interval is refused', () {
      // The seek rule is half-open, so nothing can ever select this chunk — yet
      // its gaussians still count toward the file's total, which is how a scene
      // ends up permanently short of its own header.
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 1.0, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('an EMPTY chunk over a zero-width interval is still accepted', () {
      final FourdgsChunkIndexEntry entry = FourdgsChunkIndexEntry.parse(
        _chunkIndexEntryContent(t0: 1.0, t1: 1.0, gaussianCount: 0),
      );
      expect(entry.gaussianCount, 0);
    });
  });
}
