// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for the pieces the conformance corpus cannot reach.
///
/// The corpus proves this decoder agrees with five others about files the
/// reference encoder wrote. What it cannot prove is how the decoder behaves on
/// files nobody would write on purpose — a length that runs off the end, a
/// quaternion naming a component that does not exist, a stream that lies about
/// how far it inflates. Those are the tests here.
library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

/// A record's bytes, framed the way the file frames them.
Uint8List record(int opcode, List<int> content) {
  final out =
      BytesBuilder()
        ..addByte(opcode)
        ..add(_u64(content.length))
        ..add(content);
  return out.toBytes();
}

List<int> _u32(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.little);
  return bytes.buffer.asUint8List();
}

List<int> _f64(double value) {
  final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
  return bytes.buffer.asUint8List();
}

List<int> _u64(int value) {
  final bytes =
      ByteData(8)
        ..setUint32(0, value & 0xFFFFFFFF, Endian.little)
        ..setUint32(4, value ~/ 0x100000000, Endian.little);
  return bytes.buffer.asUint8List();
}

void main() {
  group('the magic gates the file', () {
    test('a file that is not 4dgs is refused by name', () {
      expect(
        () => checkMagic(Uint8List.fromList(List<int>.filled(16, 0x00))),
        throwsA(isA<FourdgsUnsupportedVersion>()),
      );
    });

    test('a future major version is refused rather than guessed at', () {
      // The version byte gates the whole file, so pressing on would mean reading
      // unknown bytes as known ones.
      final head = Uint8List.fromList(<int>[
        0x89,
        0x34,
        0x44,
        0x47,
        0x53,
        0x39,
        0x0D,
        0x0A,
      ]);
      expect(
        () => checkMagic(head),
        throwsA(
          isA<FourdgsUnsupportedVersion>().having(
            (FourdgsUnsupportedVersion e) => e.message,
            'message',
            contains('9'),
          ),
        ),
      );
    });

    test('a file shorter than the magic is truncated, not unsupported', () {
      expect(
        () => checkMagic(Uint8List(3)),
        throwsA(isA<FourdgsTruncatedFile>()),
      );
    });
  });

  group('record framing', () {
    test('an unknown opcode is skipped by length, not guessed at', () {
      // The whole forward-compatibility story: a reader that cannot interpret a
      // record still knows exactly how long it is.
      final buf = Uint8List.fromList(<int>[
        ...record(0x80, <int>[1, 2, 3, 4]),
        ...record(opMetadata, <int>[]),
      ]);
      final opcodes = <int>[for (final r in iterRecords(buf)) r.opcode];
      expect(opcodes, <int>[0x80, opMetadata]);
    });

    test(
      'trailing bytes that are neither a record nor the magic are a cut',
      () {
        // A download cut at a record boundary walks perfectly and simply ends,
        // which is indistinguishable from success until this fires.
        final buf = Uint8List.fromList(<int>[
          ...record(opMetadata, <int>[]),
          1,
          2,
          3,
        ]);
        expect(
          () => iterRecords(buf).toList(),
          throwsA(isA<FourdgsTruncatedFile>()),
        );
      },
    );

    test('a length past the end of the buffer is refused', () {
      final buf = Uint8List.fromList(<int>[opChunk, ..._u64(1 << 20)]);
      expect(
        () => iterRecords(buf).toList(),
        throwsA(isA<FourdgsTruncatedFile>()),
      );
    });

    test('a 64-bit length above 2^53 cannot be a real length', () {
      // Not representable exactly on every Dart backend, and no honest length in
      // this format approaches it.
      final cursor = FourdgsCursor(
        Uint8List.fromList(<int>[0, 0, 0, 0, 0, 0, 0xFF, 0xFF]),
      );
      expect(() => cursor.u64(), throwsA(isA<FourdgsMalformedFile>()));
    });

    test('spans are walked without their content being present', () {
      // What lets an indexed reader step over a chunk it has not fetched.
      final buf = Uint8List.fromList(<int>[opChunk, ..._u64(1 << 20), 1, 2, 3]);
      final spans = scanRecordSpans(buf).toList();
      expect(spans, hasLength(1));
      expect(spans.single.opcode, opChunk);
      expect(spans.single.contentLength, 1 << 20);
    });
  });

  group('attribute streams', () {
    test(
      'a stream declaring more than the cap is refused before it inflates',
      () {
        // The cheap half of a decompression bomb: a handful of payload bytes can
        // name a four-billion-element array.
        final header = <int>[
          attrPosition, 4, modeConst, codecDeflate, 3, //
          0xFF, 0xFF, 0xFF, 0xFF, // element_count
          ..._u64(8),
        ];
        final cursor = FourdgsCursor(
          Uint8List.fromList(<int>[...header, 0, 0, 0, 0, 0, 0, 0, 0]),
        );
        expect(
          () => decodeAttributeStream(cursor),
          throwsA(isA<FourdgsMalformedFile>()),
        );
      },
    );

    test('a payload that is not a well-formed zlib frame is refused', () {
      final header = <int>[
        attrOpacity, 1, modeRaw, codecDeflate, 1, //
        1, 0, 0, 0,
        ..._u64(4),
      ];
      final cursor = FourdgsCursor(
        Uint8List.fromList(<int>[...header, 0xDE, 0xAD, 0xBE, 0xEF]),
      );
      expect(
        () => decodeAttributeStream(cursor),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('zstd is named as unsupported rather than reported as corrupt', () {
      // Legal per the specification; writers default to deflate precisely so
      // that no platform needs a zstd binding.
      final header = <int>[
        attrOpacity, 1, modeRaw, codecZstd, 1, //
        1, 0, 0, 0,
        ..._u64(1),
      ];
      final cursor = FourdgsCursor(Uint8List.fromList(<int>[...header, 0x00]));
      expect(
        () => decodeAttributeStream(cursor),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
    });

    test(
      'a zero-count stream decodes to nothing without touching its payload',
      () {
        final header = <int>[
          attrOpacity, 1, modeRaw, codecDeflate, 1, //
          0, 0, 0, 0,
          ..._u64(2),
        ];
        final cursor = FourdgsCursor(
          Uint8List.fromList(<int>[...header, 0xFF, 0xFF]),
        );
        expect(decodeAttributeStream(cursor).count, 0);
      },
    );
  });

  group('spherical harmonics', () {
    test('bands that do not form whole degrees are refused', () {
      // Band 2 without band 1 would otherwise render as zeros for the missing
      // band — wrong, and quietly so.
      expect(
        () => mergeChunkBands(
          <int>[1],
          <Map<int, Uint8List>>[
            <int, Uint8List>{2: Uint8List(15)},
          ],
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a chunk missing a band the file carries is refused', () {
      expect(
        () => mergeChunkBands(
          <int>[1, 1],
          <Map<int, Uint8List>>[
            <int, Uint8List>{1: Uint8List(9)},
            <int, Uint8List>{},
          ],
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('no bands at all is an absence, not an error', () {
      expect(
        mergeChunkBands(<int>[2], <Map<int, Uint8List>>[<int, Uint8List>{}]),
        isNull,
      );
    });

    test('band 1 lands component-major in a degree-1 row', () {
      // One gaussian, three coefficients per component. The stream stores red's
      // three, then green's, then blue's, and the merged row keeps that order.
      final band = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9]);
      final merged =
          mergeChunkBands(
            <int>[1],
            <Map<int, Uint8List>>[
              <int, Uint8List>{1: band},
            ],
          )!;
      expect(merged.coefficients, 3);
      expect(merged.values, band);
    });

    test('band 2 is interleaved after band 1 within each component', () {
      // Degree 2 is eight coefficients per component: band 1's three then band
      // 2's five. Getting this wrong strides one gaussian's colour into the next.
      final one = Uint8List.fromList(<int>[1, 2, 3, 11, 12, 13, 21, 22, 23]);
      final two = Uint8List.fromList(<int>[
        4, 5, 6, 7, 8, //
        14, 15, 16, 17, 18,
        24, 25, 26, 27, 28,
      ]);
      final merged =
          mergeChunkBands(
            <int>[1],
            <Map<int, Uint8List>>[
              <int, Uint8List>{1: one, 2: two},
            ],
          )!;
      expect(merged.coefficients, 8);
      expect(merged.values, <int>[
        1, 2, 3, 4, 5, 6, 7, 8, //
        11, 12, 13, 14, 15, 16, 17, 18,
        21, 22, 23, 24, 25, 26, 27, 28,
      ]);
    });

    test('a band record whose band byte disagrees with the index is refused', () {
      // Point a band-1 range at a band-2 record and the opcode still matches and
      // the bytes still decode; only this comparison catches it.
      expect(
        () => decodeShBandRecord(
          Uint8List.fromList(<int>[2]),
          expectedBand: 1,
          expectedCount: 1,
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a band record with no stream in it is a cut, not an absent band', () {
      expect(
        () => decodeShBandRecord(
          Uint8List.fromList(<int>[1]),
          expectedBand: 1,
          expectedCount: 1,
        ),
        throwsA(isA<FourdgsTruncatedFile>()),
      );
    });
  });

  group('allocation ceilings', () {
    // Every count below is a number the file chooses and the reader allocates
    // against, so each is bounded twice: once against the bytes actually
    // present, which the record itself disproves, and once against a ceiling,
    // for a file that really does carry them.
    test(
      'a window count the record cannot hold is refused by its own bytes',
      () {
        // Declares 1000 windows in a record with room for one.
        final content = Uint8List.fromList(<int>[
          0xE8, 0x03, 0, 0, //
          ...List<int>.filled(16, 0),
        ]);
        expect(
          () => FourdgsWindowTable.parse(content),
          throwsA(
            isA<FourdgsMalformedFile>().having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('holds room for 1'),
            ),
          ),
        );
      },
    );

    test(
      'a window count past the ceiling is refused even when the bytes are there',
      () {
        final n = maxWindowsPerScene + 1;
        final content = Uint8List(4 + n * windowBytes);
        ByteData.sublistView(content).setUint32(0, n, Endian.little);
        expect(
          () => FourdgsWindowTable.parse(content),
          throwsA(
            isA<FourdgsMalformedFile>().having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('ceiling'),
            ),
          ),
        );
      },
    );

    test('a chunk index entry cannot list the same SH band twice', () {
      // Two band descriptors, both band 1. Each is a separate transfer that
      // leaves one record behind, so the duplicate is bytes spent for nothing.
      final out =
          BytesBuilder()
            ..add(_f64(0))
            ..add(_f64(1))
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(0)) // gaussianCount
            ..add(_u32(2)); // bandCount
      for (int i = 0; i < 2; i++) {
        out
          ..addByte(1)
          ..add(_u64(0))
          ..add(_u64(0));
      }
      expect(
        () => FourdgsChunkIndexEntry.parse(out.toBytes()),
        throwsA(
          isA<FourdgsMalformedFile>().having(
            (FourdgsMalformedFile e) => e.message,
            'message',
            contains('more than once'),
          ),
        ),
      );
    });

    test('a band count the entry cannot hold is refused by its own bytes', () {
      final out =
          BytesBuilder()
            ..add(_f64(0))
            ..add(_f64(1))
            ..add(_u64(0))
            ..add(_u64(0))
            ..add(_u32(0))
            ..add(_u32(1000));
      expect(
        () => FourdgsChunkIndexEntry.parse(out.toBytes()),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('the ceilings are documented as far past anything real', () {
      // The corpus tops out at 10 windows; the point of the numbers is that a
      // real encoder never approaches them.
      expect(maxWindowsPerScene, greaterThan(36000));
      expect(maxBandsPerChunk, greaterThanOrEqualTo(3));
      expect(maxChunkIndexEntries, greaterThan(100000));
    });
  });

  group('the cutoff feeds velocity precision', () {
    test('a cutoff outside (0, 1] is refused rather than logged', () {
      for (final bad in <double>[0.0, -0.5, 1.5, double.nan]) {
        expect(
          () => supportK(bad),
          throwsA(isA<FourdgsMalformedFile>()),
          reason: 'cutoff $bad',
        );
      }
    });

    test(
      'the default cutoff is the constant every other implementation uses',
      () {
        expect(supportK(fourdgsDefaultCutoff), closeTo(2.4477, 1e-4));
      },
    );

    test('a wider cutoff shortens the support and can coarsen the class', () {
      // The whole reason the Header's cutoff has to be read: it changes which
      // precision class a gaussian lands in, and so the pitch its velocity bins
      // were written on.
      // sigma = exp(-1 * ln 2) = 0.5, which is where the two cutoffs straddle a
      // class boundary.
      const sigmaBin = -1;
      const sigmaLogStep = 0.6931471805599453;
      final tight = lifeClass(
        sigmaBin,
        sigmaLogStep,
        false,
        1.0,
        k: supportK(0.05),
      );
      final wide = lifeClass(
        sigmaBin,
        sigmaLogStep,
        false,
        1.0,
        k: supportK(0.5),
      );
      expect(wide, lessThan(tight));
      expect(motionStep(wide, 1.0), greaterThan(motionStep(tight, 1.0)));
    });
  });

  group('reconstruction at an instant', () {
    FourdgsGaussianSet oneGaussian({
      required double sigma,
      double winLo = 0,
      double winHi = 10,
    }) {
      return FourdgsGaussianSet(
        positions: Float32List.fromList(<double>[0, 0, 0]),
        scales: Float32List.fromList(<double>[1, 1, 1]),
        rotations: Float32List.fromList(<double>[0, 0, 0, 1]),
        colors: Float32List.fromList(<double>[1, 1, 1, 1]),
        motions: Float32List.fromList(<double>[2, 0, 0]),
        muT: Float32List.fromList(<double>[5]),
        sigmaT: Float32List.fromList(<double>[sigma]),
        winLo: Float32List.fromList(<double>[winLo]),
        winHi: Float32List.fromList(<double>[winHi]),
      );
    }

    test('the window test is not the same test as the marginal', () {
      // A never-fading gaussian has marginal 1 everywhere; only its window ends
      // it. This is what lets one file hold gaussians fitted over different
      // spans without them bleeding into each other's intervals.
      final g = oneGaussian(sigma: double.infinity, winLo: 2, winHi: 4);
      expect(g.stateAt(3.0).count, 1);
      expect(g.stateAt(1.0).count, 0);
      expect(g.stateAt(4.0).count, 0, reason: 'the window is half-open');
    });

    test('a gaussian below the cutoff is culled even inside its window', () {
      final g = oneGaussian(sigma: 0.1);
      expect(g.stateAt(5.0).count, 1);
      expect(g.stateAt(9.0).count, 0);
    });

    test('centres are advected by motion over the time since birth', () {
      final state = oneGaussian(sigma: double.infinity).stateAt(7.0);
      expect(state.count, 1);
      expect(state.centers[0], closeTo(4.0, 1e-9)); // 2 units/s * (7 - 5)
      expect(state.opacity[0], closeTo(1.0, 1e-9));
    });

    test('an empty set reconstructs to nothing rather than throwing', () {
      expect(FourdgsGaussianSet.empty().stateAt(0.0).count, 0);
    });
  });

  group('the in-memory transport', () {
    test('a range outside the buffer is refused rather than clamped', () async {
      final bytes = FourdgsBytes(Uint8List(10));
      expect(await bytes.size(), 10);
      expect(() => bytes.read(8, 4), throwsA(isA<RangeError>()));
      expect(() => bytes.read(-1, 2), throwsA(isA<RangeError>()));
    });
  });

  group('the package version is the one the release asserts', () {
    test('it is a plain semantic version', () {
      expect(fourdgsPackageVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });
  });
}
