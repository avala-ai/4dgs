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
import 'dart:io';
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

    test('a zero-change DELTA over a zero-width interval is refused', () {
      // A delta entry's `gaussianCount` counts operations — births, deaths,
      // updates — not the population they compose to. A delta that changes
      // nothing carries zero operations over a live scene, so a rule written
      // against `gaussianCount` waves through exactly the unreachable state
      // chunk it is supposed to refuse. `liveCount` is the population.
      final BytesBuilder body =
          BytesBuilder()
            ..add(_f64(1.0)) // t0
            ..add(_f64(1.0)) // t1 — zero width
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(0)) // gaussianCount: no operations
            ..add(_u32(0)) // bandCount
            // keyframe-delta block
            ..addByte(1) // kind: delta
            ..addByte(0) // deltaMode
            ..add(_u64(0)) // referenceOffset
            ..add(_u64(0)) // keyframeOffset
            ..add(_u32(0).sublist(0, 2)) // depth (u16)
            ..add(_u64(7)); // liveCount: seven gaussians nothing can reach
      expect(
        () => FourdgsChunkIndexEntry.parse(body.toBytes()),
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

  group('a short scene cannot hide behind a missing closing magic', () {
    test(
      'dropping only the trailing magic does not excuse a header/chunk mismatch',
      () {
        // The records all parse; only the closing magic is gone. That marks the
        // file truncated, but no later chunk could explain a mismatch — every
        // chunk the file has was decoded. Gating the cross-check on `truncated`
        // would let nine missing bytes wave a quietly short scene through.
        final Uint8List real =
            File(
              '../../tests/conformance/data/TenWindows-UseChunkIndex-UseCrc.4dgs',
            ).readAsBytesSync();

        // Inflate the header's gaussian count by one, so the file now claims one
        // more gaussian than its chunks assemble to.
        final Uint8List bytes = Uint8List.fromList(real);
        final int countOffset = _headerGaussianCountOffset(bytes);
        final ByteData view = ByteData.sublistView(
          bytes,
          countOffset,
          countOffset + 8,
        );
        final int declared = view.getUint32(0, Endian.little);
        view.setUint32(0, declared + 1, Endian.little);

        // Whole file: refused, as the check intends.
        expect(
          () => readFourdgsBytes(bytes, recoverTruncated: true),
          throwsA(isA<FourdgsMalformedFile>()),
        );

        // Same file with the closing magic dropped: still refused.
        final Uint8List clipped = Uint8List.sublistView(
          bytes,
          0,
          bytes.length - fourdgsMagic.length,
        );
        expect(
          () => readFourdgsBytes(clipped, recoverTruncated: true),
          throwsA(isA<FourdgsMalformedFile>()),
        );
      },
    );
  });
}

/// Byte offset of the Header's `gaussian_count`, found by walking the record
/// framing rather than assuming a layout.
int _headerGaussianCountOffset(Uint8List bytes) {
  int offset = fourdgsMagic.length;
  while (offset + 9 <= bytes.length) {
    final int opcode = bytes[offset];
    final ByteData lengthView = ByteData.sublistView(
      bytes,
      offset + 1,
      offset + 9,
    );
    final int length = lengthView.getUint32(0, Endian.little);
    if (opcode == 0x01) {
      // profile, library: each a u32 length followed by its bytes.
      int at = offset + 9;
      for (int i = 0; i < 2; i++) {
        final int n = ByteData.sublistView(
          bytes,
          at,
          at + 4,
        ).getUint32(0, Endian.little);
        at += 4 + n;
      }
      return at + 8; // past durationSec
    }
    offset += 9 + length;
  }
  throw StateError('no Header record found');
}
