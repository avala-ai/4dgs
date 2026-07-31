// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The object layer's rules and arithmetic, against values chosen by hand.
///
/// The corpus proves that three whole files compose to the right states. These
/// prove the parts underneath: the refusals a malformed record is supposed to
/// produce, the clamp at the ends of a track, and — the load-bearing one —
/// that a track transforms the base state rather than replacing it. A decoder
/// that dropped per-gaussian motion, or applied the pose before it, would
/// still agree with a summary that only reported stored fields; it cannot
/// agree with these.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

/// Little-endian record bytes, written the way the reference encoder would.
class _Bytes {
  final BytesBuilder _parts = BytesBuilder();

  _Bytes u8(int value) {
    _parts.addByte(value & 0xff);
    return this;
  }

  _Bytes u16(int value) {
    final b = ByteData(2)..setUint16(0, value, Endian.little);
    _parts.add(b.buffer.asUint8List());
    return this;
  }

  _Bytes u32(int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    _parts.add(b.buffer.asUint8List());
    return this;
  }

  _Bytes str(String value) {
    final encoded = Uint8List.fromList(value.codeUnits);
    u32(encoded.length);
    _parts.add(encoded);
    return this;
  }

  _Bytes f32(double value) {
    final b = ByteData(4)..setFloat32(0, value, Endian.little);
    _parts.add(b.buffer.asUint8List());
    return this;
  }

  _Bytes f64(double value) {
    final b = ByteData(8)..setFloat64(0, value, Endian.little);
    _parts.add(b.buffer.asUint8List());
    return this;
  }

  Uint8List done() => _parts.toBytes();
}

/// A one-entry Object Table: id 7, an anchor, no dynamics, no embeddings.
Uint8List _simpleTable() =>
    (_Bytes()
          ..u32(1)
          ..u16(0)
          ..u32(7)
          ..str('vehicle')
          ..f32(1)
          ..f32(-2)
          ..f32(0.5)
          ..u8(0))
        .done();

/// A track for [id]: identity at t=0, a quarter turn about z plus a
/// translation at t=2.
Uint8List _quarterTurnTrack([int id = 7]) {
  final b =
      _Bytes()
        ..u32(id)
        ..u8(0)
        ..u32(2);
  b
    ..f64(0)
    ..f64(0)
    ..f64(0)
    ..f64(0)
    ..f64(1)
    ..f64(0)
    ..f64(0)
    ..f64(0);
  final halfRoot = 1.0 / math.sqrt2;
  b
    ..f64(2)
    ..f64(0)
    ..f64(0)
    ..f64(halfRoot)
    ..f64(halfRoot)
    ..f64(5)
    ..f64(2)
    ..f64(0);
  return b.done();
}

void main() {
  test('an Object Table round-trips its advisory fields', () {
    final table = FourdgsObjectTable.parse(_simpleTable());
    expect(table.embeddingDim, 0);
    expect(table.entries.length, 1);
    final entry = table.entries.single;
    expect(entry.objectId, 7);
    expect(entry.label, 'vehicle');
    expect(entry.anchor, <double>[1, -2, 0.5]);
    expect(entry.dynamics, isNull);
    expect(entry.embedding, isNull);
  });

  test('an Object Table carries dynamics and an embedding when present', () {
    final b =
        _Bytes()
          ..u32(1)
          ..u16(3)
          ..u32(4)
          ..str('')
          ..f32(0)
          ..f32(0)
          ..f32(0)
          ..u8(1);
    for (int v = 1; v <= 9; v++) {
      b.f32(v.toDouble());
    }
    b
      ..u8(1)
      ..f32(0.25)
      ..f32(0.5)
      ..f32(0.75);
    final entry = FourdgsObjectTable.parse(b.done()).entries.single;
    expect(entry.dynamics![0], <double>[1, 2, 3]);
    expect(entry.dynamics![1], <double>[4, 5, 6]);
    expect(entry.dynamics![2], <double>[7, 8, 9]);
    expect(entry.embedding, <double>[0.25, 0.5, 0.75]);
  });

  test('two entries for one id are refused, naming it', () {
    final b =
        _Bytes()
          ..u32(2)
          ..u16(0)
          ..u32(7)
          ..str('first')
          ..f32(0)
          ..f32(0)
          ..f32(0)
          ..u8(0)
          ..u32(7)
          ..str('second')
          ..f32(0)
          ..f32(0)
          ..f32(0)
          ..u8(0);
    expect(
      () => FourdgsObjectTable.parse(b.done()),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.toString(),
          'message',
          contains('object 7'),
        ),
      ),
    );
  });

  test('a count larger than the record is refused before allocation', () {
    final b =
        _Bytes()
          ..u32(1000000)
          ..u16(0);
    expect(
      () => FourdgsObjectTable.parse(b.done()),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('a track for object 0 is refused: 0 is background', () {
    expect(
      () => FourdgsObjectTrack.parse(_quarterTurnTrack(0)),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.toString(),
          'message',
          contains('background'),
        ),
      ),
    );
  });

  test('a track whose times do not strictly increase is refused', () {
    final b =
        _Bytes()
          ..u32(7)
          ..u8(0)
          ..u32(2);
    for (int sample = 0; sample < 2; sample++) {
      b
        ..f64(1)
        ..f64(0)
        ..f64(0)
        ..f64(0)
        ..f64(1)
        ..f64(0)
        ..f64(0)
        ..f64(0);
    }
    expect(
      () => FourdgsObjectTrack.parse(b.done()),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('two tracks for one object are refused; that rule spans records', () {
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );
    expect(
      layer.check,
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.toString(),
          'message',
          contains('object 7'),
        ),
      ),
    );
  });

  test('a query outside the sample range clamps rather than extrapolating', () {
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );
    expect(layer.poseAt(7, -100)!.translation, <double>[0, 0, 0]);
    // The last sample, not the last sample plus ninety-eight seconds of it.
    expect(layer.poseAt(7, 100)!.translation, <double>[5, 2, 0]);
  });

  test('an untracked object and the background keep their base state', () {
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );
    expect(layer.poseAt(0, 2), isNull);
    expect(layer.poseAt(9, 2), isNull);
  });

  test('a track transforms the base state; it does not replace it', () {
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );
    // Two gaussians one unit out along +x: one in object 7, one background.
    final centers = Float64List.fromList(<double>[1, 0, 0, 1, 0, 0]);
    final orientations = Float64List.fromList(<double>[0, 0, 0, 1, 0, 0, 0, 1]);
    layer.apply(centers, orientations, Int32List.fromList(<int>[7, 0]), 2);

    // At t=2 the pose is a quarter turn about z then a translation of
    // (5, 2, 0): R * (1,0,0) = (0,1,0), plus T = (5, 3, 0). The base centre
    // went through the rotation — a decoder that replaced it reports (5,2,0).
    expect(centers[0], closeTo(5, 1e-9));
    expect(centers[1], closeTo(3, 1e-9));
    expect(centers[2], closeTo(0, 1e-9));
    // The background gaussian is untouched, pose or no pose.
    expect(centers.sublist(3), <double>[1, 0, 0]);

    // The orientation composes as a quaternion product, base second.
    expect(orientations[2], closeTo(1.0 / math.sqrt2, 1e-9));
    expect(orientations[3], closeTo(1.0 / math.sqrt2, 1e-9));
    expect(orientations.sublist(4), <double>[0, 0, 0, 1]);
  });

  test('composition refuses arrays that do not match the count', () {
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );
    expect(
      () => layer.apply(
        Float64List(3),
        Float64List(4),
        Int32List.fromList(<int>[7, 0]),
        0,
      ),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('an empty layer is a value, not an error', () {
    final layer = FourdgsObjectLayer();
    expect(layer.isEmpty, isTrue);
    layer.check();
    expect(layer.track(7), isNull);
    final centers = Float64List.fromList(<double>[1, 2, 3]);
    layer.apply(
      centers,
      Float64List.fromList(<double>[0, 0, 0, 1]),
      Int32List.fromList(<int>[7]),
      0,
    );
    expect(centers, <double>[1, 2, 3]);
  });

  test('a zero-sample track has no pose and is read as absent', () {
    final empty = FourdgsObjectTrack.parse(
      (_Bytes()
            ..u32(7)
            ..u8(0)
            ..u32(0))
          .done(),
    );
    final layer = FourdgsObjectLayer(tracks: <FourdgsObjectTrack>[empty]);
    expect(layer.poseAt(7, 0), isNull);
  });
}
