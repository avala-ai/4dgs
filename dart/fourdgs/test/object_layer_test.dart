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

import 'dart:io';
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

  test('an id in the upper half of the u32 range still matches its track', () {
    // `object_id` is an exact label over the whole u32 range (spec section
    // 6.6), and a stream decodes into signed bins. Held in an Int32List this
    // id is -1, while the track parses its own id as 4294967295 — the two
    // never meet, the object silently stops moving, and the canonical summary
    // prints a negative label no other SDK emits. Membership is stored
    // unsigned so the comparison is the one the format defines.
    const big = 0xffffffff;
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack(big)),
      ],
    );
    expect(layer.tracks.single.objectId, big);

    // The bins a decoded lane would hold, reinterpreted the way the chunk
    // decoder does.
    final ids = Uint32List.fromList(<int>[-1]);
    expect(ids[0], big);

    final centers = Float64List.fromList(<double>[1, 0, 0]);
    final orientations = Float64List.fromList(<double>[0, 0, 0, 1]);
    layer.apply(centers, orientations, ids, 2);
    expect(centers[0], closeTo(5, 1e-9));
    expect(centers[1], closeTo(3, 1e-9));
  });

  test('a Quantization record that bounds object_id is refused', () {
    // An id is an exact label (section 6.6), so there is no meaningful error
    // bound between two of them; section 6.5 makes this a refusal rather than
    // something to ignore. Python and Rust refuse it, and an SDK that accepted
    // it would claim object-layer support while decoding a file the references
    // reject.
    final pairs =
        (_Bytes()
              ..str('object_id')
              ..str('0.5'))
            .done();
    final record = _Bytes()..str('grid-v1');
    for (int i = 0; i < 3; i++) {
      record.f64(0); // posOrigin
    }
    for (int i = 0; i < 8; i++) {
      record.f64(1); // the eight steps
    }
    record
      ..u8(0) // stepSh
      ..u32(pairs.length);
    final withBounds = Uint8List.fromList(<int>[...record.done(), ...pairs]);

    expect(
      () => FourdgsQuantization.parse(withBounds),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.toString(),
          'message',
          contains('object_id'),
        ),
      ),
    );
  });

  test('a delta stream that leaves the 32-bit range is refused', () {
    // An `object_id` code is a label, not a bin (section 6.6): a wrapped code is
    // a *different object*, silently. Rust accumulates deltas in i64 and then
    // requires the code to fit an i32, so it refuses this file; Dart accumulates
    // into an Int32List, where the wrap would happen before anything could see
    // it. The check has to live in the accumulation, which is where the 64-bit
    // sum is still visible.
    //
    // Two 4-byte symbols in delta mode: 2147483647 then +1 leaves the range.
    // Zigzag maps them to 4294967294 and 2.
    const symbols = <int>[4294967294, 2];
    const width = 4;
    // Byte-plane order: every symbol's byte 0, then every symbol's byte 1, ...
    final plain = Uint8List(symbols.length * width);
    for (int j = 0; j < width; j++) {
      for (int i = 0; i < symbols.length; i++) {
        plain[j * symbols.length + i] = (symbols[i] >> (8 * j)) & 0xff;
      }
    }
    final payload = Uint8List.fromList(ZLibCodec().encode(plain));

    final b =
        _Bytes()
          ..u8(attrObjectId)
          ..u8(width)
          ..u8(1) // mode: delta
          ..u8(codecDeflate)
          ..u8(1) // channels
          ..u32(symbols.length)
          ..u32(payload.length) // payload length, low half
          ..u32(0); // payload length, high half
    final bytes = Uint8List.fromList(<int>[...b.done(), ...payload]);

    expect(
      () => decodeAttributeStream(FourdgsCursor(bytes)),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.toString(),
          'message',
          contains('32-bit range'),
        ),
      ),
    );
  });

  test('an object label that is not UTF-8 is refused as a malformed file', () {
    // Labels are untrusted record bytes. A raw FormatException from the
    // standard library says nothing about which record failed; AGENTS.md §6
    // asks a decoder that refuses a file to name the problem, and the
    // TypeScript reader already did.
    final b =
        _Bytes()
          ..u32(1)
          ..u16(0)
          ..u32(7)
          ..u32(2); // a two-byte label...
    b
      ..u8(0xff)
      ..u8(0xfe); // ...that is not valid UTF-8
    b
      ..f32(0)
      ..f32(0)
      ..f32(0)
      ..u8(0);

    expect(
      () => FourdgsObjectTable.parse(b.done()),
      throwsA(isA<FourdgsMalformedFile>()),
    );
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
    expect(layer.isEmpty, isTrue);
  });

  test('a zero-sample object track is read as absent rather than refused', () {
    // The same sentence as section 5.15.4, in section 5.15.7, for the object
    // layer. An empty track is absent from layer identity as well as pose
    // sampling; duplicate empty records therefore cannot create two live
    // motions for one object.
    final body = Uint8List.fromList(<int>[7, 0, 0, 0, 7, 0, 0, 0, 0]);
    expect(FourdgsObjectTrack.parse(body).sampleCount, 0);
    expect(
      () =>
          FourdgsObjectTrack(
            objectId: 7,
            interpolation: 7,
            times: <double>[0.0],
            rotations: <List<double>>[
              <double>[0.0, 0.0, 0.0, 1.0],
            ],
            translations: <List<double>>[
              <double>[0.0, 0.0, 0.0],
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('an object track with mismatched sample arrays is refused', () {
    // The trajectory rules iterate each array independently, so a track with two
    // times and one rotation used to pass and fail later inside pose sampling.
    // Python and Rust refuse it at check time; this pins the same answer here.
    expect(
      () =>
          FourdgsObjectTrack(
            objectId: 7,
            interpolation: 0,
            times: <double>[0.0, 1.0],
            rotations: <List<double>>[
              <double>[0.0, 0.0, 0.0, 1.0],
            ],
            translations: <List<double>>[
              <double>[0.0, 0.0, 0.0],
              <double>[1.0, 1.0, 1.0],
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('an object track sample of the wrong width is refused', () {
    // A translation of two numbers passes the trajectory rules, which iterate
    // whatever coordinates are there, and then reads past the end during
    // composition. Python names this; Rust cannot express it.
    expect(
      () =>
          FourdgsObjectTrack(
            objectId: 7,
            interpolation: 0,
            times: <double>[0.0],
            rotations: <List<double>>[
              <double>[0.0, 0.0, 0.0, 1.0],
            ],
            translations: <List<double>>[
              <double>[1.0, 2.0],
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
    expect(
      () =>
          FourdgsObjectTrack(
            objectId: 7,
            interpolation: 0,
            times: <double>[0.0],
            rotations: <List<double>>[
              <double>[0.0, 0.0, 1.0],
            ],
            translations: <List<double>>[
              <double>[1.0, 2.0, 3.0],
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('an object table embedding must match the declared space', () {
    // embedding_dim is declared once for the whole file, so a vector of another
    // width — or any vector when no embedding space is declared — describes a
    // coordinate system nothing else in the file shares. Python refuses both.
    FourdgsObjectEntry entry(List<double>? embedding) => FourdgsObjectEntry(
      objectId: 1,
      label: '',
      anchor: <double>[0.0, 0.0, 0.0],
      dynamics: null,
      embedding: embedding,
    );
    expect(
      () =>
          FourdgsObjectTable(
            embeddingDim: 4,
            entries: <FourdgsObjectEntry>[
              entry(<double>[1.0, 2.0, 3.0]),
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
    expect(
      () =>
          FourdgsObjectTable(
            embeddingDim: 0,
            entries: <FourdgsObjectEntry>[
              entry(<double>[1.0, 2.0, 3.0]),
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('object ids and embedding_dim must fit the fields that carry them', () {
    // u32 and u16 on the wire, so the parser cannot produce anything else — but
    // a caller constructing a record can, and nothing downstream notices.
    for (final bad in <int>[-1, 0x100000000]) {
      expect(
        () =>
            FourdgsObjectTrack(
              objectId: bad,
              interpolation: 0,
              times: const <double>[],
              rotations: const <List<double>>[],
              translations: const <List<double>>[],
            ).check(),
        throwsA(isA<FourdgsMalformedFile>()),
        reason: 'object_id $bad should be refused',
      );
    }
    expect(
      () =>
          FourdgsObjectTable(
            embeddingDim: 0x10000,
            entries: const <FourdgsObjectEntry>[],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('the composed state path applies tracks the base path leaves alone', () {
    // `stateAt` is the base temporal state and is the right answer for a scene
    // with no layer. For one with tracks it returns the gaussians of a moving
    // object at their rest centres, which is why the composed entry point
    // exists — a caller should not have to remember `apply` to get the scene
    // the file describes.
    final gaussians = FourdgsGaussianSet(
      positions: Float32List.fromList(<double>[1, 0, 0]),
      scales: Float32List.fromList(<double>[1, 1, 1]),
      rotations: Float32List.fromList(<double>[0, 0, 0, 1]),
      colors: Float32List.fromList(<double>[1, 1, 1, 1]),
      motions: Float32List.fromList(<double>[0, 0, 0]),
      muT: Float32List.fromList(<double>[2]),
      sigmaT: Float32List.fromList(<double>[double.infinity]),
      winLo: Float32List.fromList(<double>[0]),
      winHi: Float32List.fromList(<double>[10]),
      objectId: Uint32List.fromList(<int>[7]),
    );
    final layer = FourdgsObjectLayer(
      tracks: <FourdgsObjectTrack>[
        FourdgsObjectTrack.parse(_quarterTurnTrack()),
      ],
    );

    final base = gaussians.stateAt(2);
    expect(base.centers[0], closeTo(1, 1e-9));

    final composed = fourdgsStateAtWithObjects(gaussians, layer, 2);
    expect(composed.centers[0], closeTo(5, 1e-9));
    expect(composed.centers[1], closeTo(3, 1e-9));

    // No layer, or an empty one, is the base state unchanged.
    final none = fourdgsStateAtWithObjects(gaussians, null, 2);
    expect(none.centers[0], closeTo(1, 1e-9));
    final empty = fourdgsStateAtWithObjects(gaussians, FourdgsObjectLayer(), 2);
    expect(empty.centers[0], closeTo(1, 1e-9));
  });

  test('an object table vector of the wrong width is refused', () {
    // The wire record carries f32[3] for the anchor and each dynamics vector,
    // so a shorter one is a shape no conforming file can hold.
    expect(
      () =>
          FourdgsObjectTable(
            embeddingDim: 0,
            entries: <FourdgsObjectEntry>[
              FourdgsObjectEntry(
                objectId: 1,
                label: '',
                anchor: <double>[1.0, 2.0],
                dynamics: null,
                embedding: null,
              ),
            ],
          ).check(),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('a table-only layer composes without scanning every gaussian', () {
    // Labels and anchors with nothing moving is a valid layer with no pose to
    // apply — but mismatched arrays are still wrong, track or no track.
    final layer = FourdgsObjectLayer();
    final centers = Float64List.fromList(<double>[1, 0, 0]);
    final orientations = Float64List.fromList(<double>[0, 0, 0, 1]);
    layer.apply(centers, orientations, Int32List.fromList(<int>[7]), 2);
    expect(centers, <double>[1, 0, 0]);
    expect(
      () => layer.apply(
        Float64List.fromList(<double>[1, 0]),
        orientations,
        Int32List.fromList(<int>[7]),
        2,
      ),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('an empty-track-only layer composes without scanning gaussian ids', () {
    final emptyTrack = FourdgsObjectTrack.parse(
      (_Bytes()
            ..u32(7)
            ..u8(0)
            ..u32(0))
          .done(),
    );
    final layer = FourdgsObjectLayer(tracks: <FourdgsObjectTrack>[emptyTrack]);
    final centers = Float64List.fromList(<double>[1, 0, 0]);
    final orientations = Float64List.fromList(<double>[0, 0, 0, 1]);
    layer.apply(centers, orientations, Int32List.fromList(<int>[7]), 2);
    expect(centers, <double>[1, 0, 0]);
  });

  test('a dynamics tuple of the wrong length is a malformed file', () {
    // Indexing first turns a short list into a RangeError, and lets a longer
    // one through with the extra vectors silently ignored.
    FourdgsObjectTable table(List<List<double>> dynamics) => FourdgsObjectTable(
      embeddingDim: 0,
      entries: <FourdgsObjectEntry>[
        FourdgsObjectEntry(
          objectId: 1,
          label: '',
          anchor: <double>[0.0, 0.0, 0.0],
          dynamics: dynamics,
          embedding: null,
        ),
      ],
    );
    final short = <List<double>>[
      <double>[0.0, 0.0, 0.0],
      <double>[0.0, 0.0, 0.0],
    ];
    expect(() => table(short).check(), throwsA(isA<FourdgsMalformedFile>()));
    final long = <List<double>>[
      <double>[0.0, 0.0, 0.0],
      <double>[0.0, 0.0, 0.0],
      <double>[0.0, 0.0, 0.0],
      <double>[0.0, 0.0, 0.0],
    ];
    expect(() => table(long).check(), throwsA(isA<FourdgsMalformedFile>()));
  });
}
