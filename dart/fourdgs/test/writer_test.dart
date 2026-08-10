// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The writer, checked against the two things a file has to be: readable, and
/// what it claims.
///
/// Readable is the cheap half and it is checked first — the decoder in this same
/// package reads back what the encoder wrote, on both read paths. The expensive
/// half is the claims: a file declares a maximum deviation per attribute, a
/// summary at a byte offset, a CRC over a range, and index entries that frame
/// whole records. Each of those is something a consumer will trust without
/// re-deriving it, so each is measured here rather than assumed.
///
/// The cross-language half of the proof is not here and cannot be: it is the
/// conformance encode gate, where the same gaussians go through this encoder and
/// through the Rust reference and the Python decoder has to read both files as
/// the same scene.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

/// A deterministic scene with enough variety to exercise every lane: several
/// validity windows, gaussians that fade and gaussians that do not, motion in
/// every direction, and colours across the range.
FourdgsGaussianSet buildScene({
  int count = 96,
  int windows = 4,
  double duration = 8.0,
  int shDegree = 0,
  int seed = 20260810,
}) {
  final random = math.Random(seed);
  final positions = Float32List(count * 3);
  final scales = Float32List(count * 3);
  final rotations = Float32List(count * 4);
  final colors = Float32List(count * 4);
  final motions = Float32List(count * 3);
  final muT = Float32List(count);
  final sigmaT = Float32List(count);
  final winLo = Float32List(count);
  final winHi = Float32List(count);
  final span = duration / windows;

  for (int i = 0; i < count; i++) {
    for (int axis = 0; axis < 3; axis++) {
      positions[i * 3 + axis] = (random.nextDouble() * 2.0 - 1.0);
      scales[i * 3 + axis] = 1e-3 + random.nextDouble() * 5e-3;
      motions[i * 3 + axis] = (random.nextDouble() * 2.0 - 1.0) * 0.2;
    }
    // A quaternion in a random direction, normalized: the smallest-three
    // transform has to pick a different omitted component for different
    // gaussians or three quarters of it is never exercised.
    double norm = 0.0;
    for (int c = 0; c < 4; c++) {
      final v = random.nextDouble() * 2.0 - 1.0;
      rotations[i * 4 + c] = v;
      norm += v * v;
    }
    norm = math.sqrt(norm);
    for (int c = 0; c < 4; c++) {
      rotations[i * 4 + c] = rotations[i * 4 + c] / norm;
    }
    for (int c = 0; c < 4; c++) {
      colors[i * 4 + c] = random.nextDouble();
    }

    final window = i % windows;
    winLo[i] = window * span;
    winHi[i] = (window + 1) * span;
    muT[i] = winLo[i] + random.nextDouble() * span;
    // Every eighth gaussian never fades. `+inf` is a value here, not a
    // sentinel: it has to survive the round trip as infinity.
    sigmaT[i] =
        i % 8 == 0 ? double.infinity : (0.02 + random.nextDouble() * 0.2);
  }

  Uint8List? sh;
  int coefficients = 0;
  if (shDegree > 0) {
    coefficients = <int, int>{1: 3, 2: 8, 3: 15}[shDegree]!;
    sh = Uint8List(count * 3 * coefficients);
    for (int i = 0; i < sh.length; i++) {
      sh[i] = random.nextInt(256);
    }
  }

  return FourdgsGaussianSet(
    positions: positions,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: motions,
    muT: muT,
    sigmaT: sigmaT,
    winLo: winLo,
    winHi: winHi,
    shDegree: shDegree,
    sh: sh,
    shCoefficients: coefficients,
  );
}

/// A scene of `count` gaussians all alike, for the cases where the point is the
/// envelope rather than the content.
FourdgsGaussianSet flatScene(int count, {double winHi = 1.0}) {
  return FourdgsGaussianSet(
      positions: Float32List(count * 3),
      scales: Float32List(count * 3)..fillRange(0, count * 3, 1e-3),
      rotations: Float32List(count * 4),
      colors: Float32List(count * 4),
      motions: Float32List(count * 3),
      muT: Float32List(count),
      sigmaT: Float32List(count)..fillRange(0, count, 0.5),
      winLo: Float32List(count),
      winHi: Float32List(count)..fillRange(0, count, winHi),
    )
    ..rotations.setAll(0, <double>[
      for (int i = 0; i < count; i++) ...<double>[0.0, 0.0, 0.0, 1.0],
    ]);
}

/// The declared bound for [key], read back out of the file rather than assumed.
double declared(FourdgsQuantization quantization, String key) =>
    double.parse(quantization.bounds[key]!);

/// Every record in a written file, in order.
List<FourdgsRecord> recordsOf(Uint8List bytes) =>
    iterRecords(bytes, fourdgsMagic.length).toList();

void main() {
  group('the envelope', () {
    test('opens and closes with the magic, and frames every record', () {
      final bytes = writeFourdgsBytes(buildScene(), 8.0);

      expect(
        bytes.sublist(0, fourdgsMagic.length),
        orderedEquals(fourdgsMagic),
        reason: 'the file must open with the magic',
      );
      expect(
        bytes.sublist(bytes.length - fourdgsMagic.length),
        orderedEquals(fourdgsMagic),
        reason: 'the file must close with the same magic it opened with',
      );

      // iterRecords refuses trailing bytes that are neither a record nor the
      // closing magic, so walking to the end is itself the framing assertion.
      final opcodes = <int>[for (final r in recordsOf(bytes)) r.opcode];
      expect(opcodes.first, opHeader);
      expect(opcodes[1], opQuantization);
      expect(opcodes[2], opWindowTable);
      expect(opcodes.last, opFooter);
      expect(opcodes, contains(opChunk));
    });

    test('the Header states the scene, not a chunk', () {
      final scene = buildScene(count: 96);
      final bytes = writeFourdgsBytes(
        scene,
        8.0,
        options: const FourdgsWriteOptions(
          sceneProfile: 'capture',
          library: 'a test',
          attributes: <String, String>{'zebra': '1', 'alpha': '2'},
        ),
      );
      final decoded = readFourdgsBytes(bytes);

      // The count of DISTINCT gaussians, which under `gaussian-birth` is the
      // input's own size. Summing the chunk populations happens to give the same
      // answer here and is the wrong rule: `keyframe-delta` restates gaussians
      // chunk by chunk, and a writer that summed would count each of them many
      // times.
      expect(decoded.header.gaussianCount, scene.count);
      expect(decoded.header.durationSec, 8.0);
      expect(decoded.header.temporalModel, 'gaussian-birth');
      expect(decoded.header.profile, 'capture');
      expect(decoded.header.library, 'a test');
      expect(decoded.header.cutoff, fourdgsDefaultCutoff);
      expect(decoded.header.attributes, <String, String>{
        'alpha': '2',
        'zebra': '1',
      });
      expect(decoded.header.hasAudio, isFalse);
      expect(decoded.header.shDegree, 0);
      expect(decoded.header.aabb.length, 6);
      for (int axis = 0; axis < 3; axis++) {
        expect(
          decoded.header.aabb[axis],
          lessThanOrEqualTo(decoded.header.aabb[3 + axis]),
        );
      }
    });

    test('two encodes of one scene are the same bytes', () {
      final scene = buildScene();
      // The attribute maps hold the same pairs in different insertion orders. A
      // writer that emitted them in iteration order would pass every value-based
      // check and still produce two different files.
      final first = writeFourdgsBytes(
        scene,
        8.0,
        options: const FourdgsWriteOptions(
          attributes: <String, String>{'b': '2', 'a': '1', 'c': '3'},
        ),
      );
      final second = writeFourdgsBytes(
        scene,
        8.0,
        options: const FourdgsWriteOptions(
          attributes: <String, String>{'c': '3', 'a': '1', 'b': '2'},
        ),
      );
      expect(first, orderedEquals(second));
    });
  });

  group('the round trip', () {
    test('every attribute comes back inside the bound the file declares', () {
      final scene = buildScene(count: 128);
      final bytes = writeFourdgsBytes(scene, 8.0);
      final decoded = readFourdgsBytes(bytes);
      expect(decoded.gaussians.count, scene.count);

      final q = decoded.quantization;
      final boundPos = declared(q, 'pos');
      final boundScale = declared(q, 'scale_rel');
      final boundRgb = declared(q, 'rgb');
      final boundAlpha = declared(q, 'alpha');
      final boundRot = declared(q, 'rot');
      final boundTime = declared(q, 'time');
      final boundSigma = declared(q, 'sigma_rel');

      // Decoded order is not part of the contract, so the comparison is made
      // against the gaussian the decoder gives back at each index — matched by
      // its own window and birth time, which the encoder did not reorder within
      // a chunk in any way this test can be blind to. Positions are the anchor:
      // the writer orders a chunk by Morton code, so pairing is by nearest
      // position and then every other lane is checked on that pairing.
      final pairing = _pairByPosition(scene, decoded.gaussians);
      double worstPos = 0;
      double worstScale = 0;
      double worstRgb = 0;
      double worstAlpha = 0;
      double worstRot = 0;
      double worstMu = 0;
      double worstSigma = 0;
      for (int j = 0; j < pairing.length; j++) {
        final i = pairing[j];
        for (int axis = 0; axis < 3; axis++) {
          worstPos = math.max(
            worstPos,
            (decoded.gaussians.positions[j * 3 + axis] -
                    scene.positions[i * 3 + axis])
                .abs(),
          );
          worstScale = math.max(
            worstScale,
            (math.log(
              decoded.gaussians.scales[j * 3 + axis] /
                  scene.scales[i * 3 + axis],
            )).abs(),
          );
          worstRgb = math.max(
            worstRgb,
            (decoded.gaussians.colors[j * 4 + axis] -
                    scene.colors[i * 4 + axis])
                .abs(),
          );
        }
        worstAlpha = math.max(
          worstAlpha,
          (decoded.gaussians.colors[j * 4 + 3] - scene.colors[i * 4 + 3]).abs(),
        );
        // `q` and `-q` are the same rotation, so the deviation is the smaller of
        // the two comparisons — the encoder canonicalizes the sign and a decoder
        // may hand back either representative.
        double same = 0;
        double flipped = 0;
        for (int c = 0; c < 4; c++) {
          final a = decoded.gaussians.rotations[j * 4 + c];
          final b = scene.rotations[i * 4 + c];
          same = math.max(same, (a - b).abs());
          flipped = math.max(flipped, (a + b).abs());
        }
        worstRot = math.max(worstRot, math.min(same, flipped));
        double norm = 0;
        for (int c = 0; c < 4; c++) {
          final v = decoded.gaussians.rotations[j * 4 + c];
          norm += v * v;
        }
        expect(math.sqrt(norm), closeTo(1.0, 1e-6));
        worstMu = math.max(
          worstMu,
          (decoded.gaussians.muT[j] - scene.muT[i]).abs(),
        );
        if (scene.sigmaT[i].isFinite) {
          worstSigma = math.max(
            worstSigma,
            (math.log(decoded.gaussians.sigmaT[j] / scene.sigmaT[i])).abs(),
          );
        }
        expect(decoded.gaussians.winLo[j], scene.winLo[i]);
        expect(decoded.gaussians.winHi[j], scene.winHi[i]);
      }

      // Float32 storage costs a relative 1e-7 on the way out, which is below
      // every bound here by four orders of magnitude but is not zero.
      const slack = 1e-6;
      expect(worstPos, lessThanOrEqualTo(boundPos + slack));
      expect(worstScale, lessThanOrEqualTo(math.log(1 + boundScale) + slack));
      expect(worstRgb, lessThanOrEqualTo(boundRgb + slack));
      expect(worstAlpha, lessThanOrEqualTo(boundAlpha + slack));
      // `rot` bounds the three *stored* residuals, not the reconstructed
      // quaternion. The omitted component comes back as a square root and the
      // result is renormalized, both of which amplify a residual error by a
      // small factor that depends on how close the largest component is to the
      // other three — which is why the reference encoders measure this deviation
      // and deliberately do not assert `bounds.rot` on it. What is asserted here
      // is that the amplification stays small and that the result is still a
      // unit quaternion, checked above.
      expect(worstRot, lessThanOrEqualTo(8 * boundRot));
      expect(worstMu, lessThanOrEqualTo(boundTime + slack));
      expect(worstSigma, lessThanOrEqualTo(math.log(1 + boundSigma) + slack));
    });

    test('an infinite sigma survives as infinity, not as a large number', () {
      final scene = buildScene(count: 64);
      final expected = <int>[
        for (int i = 0; i < scene.count; i++)
          if (!scene.sigmaT[i].isFinite) i,
      ];
      expect(expected, isNotEmpty, reason: 'the fixture must carry some');

      final decoded = readFourdgsBytes(writeFourdgsBytes(scene, 8.0));
      int neverFades = 0;
      for (int i = 0; i < decoded.gaussians.count; i++) {
        if (!decoded.gaussians.sigmaT[i].isFinite) neverFades++;
      }
      expect(neverFades, expected.length);
    });

    test('an infinite validity window is written, not repaired', () {
      // `win_hi = +inf` is how a static asset says a gaussian is present at
      // every instant, and the reference writers exclude the window from their
      // finite check for exactly that reason.
      final scene = flatScene(4, winHi: double.infinity);
      final decoded = readFourdgsBytes(writeFourdgsBytes(scene, 2.0));
      expect(decoded.windows.single.hi, double.infinity);
      for (int i = 0; i < decoded.gaussians.count; i++) {
        expect(decoded.gaussians.winHi[i], double.infinity);
      }
    });

    test('the indexed path reads back what the streamed path does', () async {
      final scene = buildScene(count: 96);
      final bytes = writeFourdgsBytes(
        scene,
        8.0,
        options: const FourdgsWriteOptions(
          writeStatistics: true,
          writeSummaryOffsets: true,
        ),
      );
      final streamed = readFourdgsBytes(bytes);
      final indexed = await openFourdgsIndexed(FourdgsBytes(bytes));

      expect(indexed.header.gaussianCount, streamed.header.gaussianCount);
      expect(indexed.index.length, streamed.chunkIndex.length);
      expect(indexed.summaryCrcOk, isTrue);

      int total = 0;
      for (final entry in indexed.index) {
        final chunk = await readFourdgsChunk(
          FourdgsBytes(bytes),
          indexed,
          entry,
        );
        expect(chunk.count, entry.gaussianCount);
        total += chunk.count;
      }
      expect(total, scene.count);
    });

    test('an empty scene is a complete file with no chunks and no index', () {
      final decoded = readFourdgsBytes(
        writeFourdgsBytes(FourdgsGaussianSet.empty(), 3.0),
      );
      expect(decoded.gaussians.count, 0);
      expect(decoded.chunkIndex, isEmpty);
      expect(decoded.header.gaussianCount, 0);
      expect(decoded.header.durationSec, 3.0);
    });
  });

  group('the summary', () {
    test('is exactly Chunk Index, Statistics and Summary Offset, contiguous', () {
      final bytes = writeFourdgsBytes(
        buildScene(),
        8.0,
        options: const FourdgsWriteOptions(
          writeStatistics: true,
          writeSummaryOffsets: true,
        ),
      );
      final records = recordsOf(bytes);
      final footer = records.last;
      expect(footer.opcode, opFooter);

      final summary = records.sublist(
        records.indexWhere((FourdgsRecord r) => r.opcode == opChunkIndex),
        records.length - 1,
      );
      expect(
        <int>[for (final r in summary) r.opcode],
        <int>[
          for (final r in summary)
            if (r.opcode == opChunkIndex) opChunkIndex,
          opStatistics,
          opSummaryOffset,
        ],
        reason:
            'spec §4.5: the summary is these three record types and nothing else',
      );

      // Contiguity is what lets a streamed reader verify the CRC by retaining
      // the trailing run rather than the file, so it is asserted on the bytes:
      // the run must reach the Footer with no gap.
      final start = summary.first.offset;
      expect(
        summary.last.offset + summary.last.framedLength,
        footer.offset,
        reason: 'nothing may sit between the summary and the Footer',
      );

      final decoded = readFourdgsBytes(bytes);
      expect(decoded.summaryCrcOk, isTrue);
      expect(decoded.statistics, isNotNull);
      expect(decoded.statistics!.chunkCount, decoded.chunkIndex.length);
      expect(decoded.statistics!.gaussianCount, decoded.header.gaussianCount);
      expect(decoded.summaryOffsets.single.groupOpcode, opChunkIndex);
      expect(decoded.summaryOffsets.single.groupStart, start);
    });

    test('the Footer points at the first byte of the summary', () {
      final bytes = writeFourdgsBytes(
        buildScene(),
        8.0,
        options: const FourdgsWriteOptions(
          writeStatistics: true,
          writeSummaryOffsets: true,
        ),
      );
      final records = recordsOf(bytes);
      final footer = FourdgsFooter.parse(records.last.content);
      final firstIndex = records.firstWhere(
        (FourdgsRecord r) => r.opcode == opChunkIndex,
      );
      final summaryOffset = records.firstWhere(
        (FourdgsRecord r) => r.opcode == opSummaryOffset,
      );
      expect(footer.summaryStart, firstIndex.offset);
      expect(footer.summaryOffsetStart, summaryOffset.offset);
      expect(bytes[footer.summaryStart], opChunkIndex);
      expect(bytes[footer.summaryOffsetStart], opSummaryOffset);

      // The CRC covers precisely the summary run: from `summary_start` to the
      // Footer's own first byte, and nothing else.
      expect(
        fourdgsCrc32(
          Uint8List.sublistView(
            bytes,
            footer.summaryStart,
            records.last.offset,
          ),
        ),
        footer.summaryCrc,
      );
    });

    test(
      'a file written without a CRC declares zero rather than a wrong one',
      () {
        final bytes = writeFourdgsBytes(
          buildScene(),
          8.0,
          options: const FourdgsWriteOptions(writeCrc: false),
        );
        final footer = FourdgsFooter.parse(recordsOf(bytes).last.content);
        expect(footer.summaryCrc, 0);
        expect(readFourdgsBytes(bytes).summaryCrcOk, isNull);
      },
    );
  });

  group('the chunk index', () {
    test('every offset and length frames a whole record', () {
      final bytes = writeFourdgsBytes(
        buildScene(count: 96, shDegree: 3),
        8.0,
        options: const FourdgsWriteOptions(writeStatistics: true),
      );
      final decoded = readFourdgsBytes(bytes);
      expect(decoded.chunkIndex, isNotEmpty);

      for (final entry in decoded.chunkIndex) {
        // Spec §5.8: a reader fetches [offset, offset + length) and parses it
        // exactly as it would parse that record mid-stream, so the range has to
        // start on the opcode byte and end on the record's last byte.
        expect(bytes[entry.chunkOffset], opChunk);
        expect(
          entry.chunkLength,
          recordHeaderBytes + _contentLength(bytes, entry.chunkOffset),
          reason: 'chunk_length must frame the whole Chunk record',
        );
        expect(entry.bands, isNotEmpty);
        for (final band in entry.bands) {
          expect(bytes[band.offset], opShBandStream);
          expect(
            band.length,
            recordHeaderBytes + _contentLength(bytes, band.offset),
            reason: 'a band range must frame the whole SH Band Stream record',
          );
          expect(bytes[band.offset + recordHeaderBytes], band.band);
        }
      }
    });

    test(
      'the intervals are half-open and the last one ends at the duration',
      () {
        final decoded = readFourdgsBytes(
          writeFourdgsBytes(buildScene(windows: 4, duration: 8.0), 8.0),
        );
        for (final entry in decoded.chunkIndex) {
          expect(entry.t0, lessThan(entry.t1));
          expect(entry.t1, lessThanOrEqualTo(8.0));
        }
        expect(
          decoded.chunkIndex
              .map((FourdgsChunkIndexEntry e) => e.t1)
              .reduce(math.max),
          8.0,
          reason:
              'the seek rule is t0 <= t < t1, so the last t1 is the duration',
        );
      },
    );

    test('a static asset is duration 0 with one entry over [0, 1e-09)', () {
      final decoded = readFourdgsBytes(writeFourdgsBytes(flatScene(8), 0.0));
      expect(decoded.header.durationSec, 0.0);
      expect(decoded.chunkIndex.length, 1);
      expect(decoded.chunkIndex.single.t0, 0.0);
      expect(decoded.chunkIndex.single.t1, 1e-9);
    });
  });

  group('spherical harmonics', () {
    for (final degree in <int>[1, 2, 3]) {
      test('degree $degree coefficients come back byte for byte', () {
        final scene = buildScene(count: 64, shDegree: degree);
        final bytes = writeFourdgsBytes(scene, 8.0);
        final decoded = readFourdgsBytes(bytes);

        expect(decoded.header.shDegree, degree);
        expect(decoded.gaussians.shCoefficients, scene.shCoefficients);
        expect(decoded.gaussians.sh, isNotNull);

        // At full depth the coefficients are stored as they arrived, so the
        // multiset of rows must survive exactly — order within a chunk is the
        // encoder's own business.
        final pairing = _pairByPosition(scene, decoded.gaussians);
        final row = 3 * scene.shCoefficients;
        for (int j = 0; j < pairing.length; j++) {
          final i = pairing[j];
          for (int k = 0; k < row; k++) {
            expect(
              decoded.gaussians.sh![j * row + k],
              scene.sh![i * row + k],
              reason: 'coefficient $k of gaussian $i',
            );
          }
        }
      });
    }

    test('a scene with no harmonics declares degree 0 and writes no bands', () {
      final bytes = writeFourdgsBytes(buildScene(), 8.0);
      expect(readFourdgsBytes(bytes).header.shDegree, 0);
      expect(
        recordsOf(bytes).where((FourdgsRecord r) => r.opcode == opShBandStream),
        isEmpty,
      );
      for (final entry in readFourdgsBytes(bytes).chunkIndex) {
        expect(entry.bands, isEmpty);
      }
    });
  });

  group('the grid', () {
    test('declares pitches that are exactly twice the bounds it declares', () {
      final q =
          readFourdgsBytes(writeFourdgsBytes(buildScene(), 8.0)).quantization;
      expect(q.scheme, 'uniform-v1');
      expect(q.stepPos, closeTo(2 * declared(q, 'pos'), 1e-18));
      expect(q.stepRot, closeTo(2 * declared(q, 'rot'), 1e-18));
      expect(q.stepRgb, closeTo(2 * declared(q, 'rgb'), 1e-18));
      expect(q.stepAlpha, closeTo(2 * declared(q, 'alpha'), 1e-18));
      expect(q.stepMotion, closeTo(2 * declared(q, 'motion'), 1e-18));
      expect(q.stepTime, closeTo(2 * declared(q, 'time'), 1e-18));
      expect(q.stepSh, 1);
    });

    test('the logarithmic pitches match the reference to the last bit', () {
      // `dart:math` has no `log1p`, so this writer computes it from an identity.
      // These two constants are what the Python and Rust reference encoders put
      // in the record for the default profile; the whole point of the identity
      // is that it reproduces them exactly, and a drift of one unit in the last
      // place is a different grid.
      final q =
          readFourdgsBytes(writeFourdgsBytes(buildScene(), 8.0)).quantization;
      expect(q.stepScaleLog, 0.039605254592359425);
      expect(q.stepSigmaLog, 0.039605254592359425);

      final fine =
          readFourdgsBytes(
            writeFourdgsBytes(
              buildScene(),
              8.0,
              options: const FourdgsWriteOptions(profile: 'fine'),
            ),
          ).quantization;
      expect(fine.stepScaleLog, 0.009975083022078148);
    });

    test('the position origin is the scene minimum, so bins start at zero', () {
      final scene = buildScene();
      final q = readFourdgsBytes(writeFourdgsBytes(scene, 8.0)).quantization;
      for (int axis = 0; axis < 3; axis++) {
        double lowest = double.infinity;
        for (int i = 0; i < scene.count; i++) {
          lowest = math.min(lowest, scene.positions[i * 3 + axis]);
        }
        expect(q.posOrigin[axis], lowest);
      }
    });

    test('a coarser profile declares a coarser grid', () {
      final scene = buildScene();
      final fine =
          readFourdgsBytes(
            writeFourdgsBytes(
              scene,
              8.0,
              options: const FourdgsWriteOptions(profile: 'fine'),
            ),
          ).quantization;
      final coarse =
          readFourdgsBytes(
            writeFourdgsBytes(
              scene,
              8.0,
              options: const FourdgsWriteOptions(profile: 'coarse'),
            ),
          ).quantization;
      expect(coarse.stepPos, greaterThan(fine.stepPos));
      expect(coarse.stepRot, greaterThan(fine.stepRot));
      expect(coarse.stepSh, greaterThan(fine.stepSh));
    });
  });

  group('refusals name the problem', () {
    test('a non-finite position says which field and which gaussian', () {
      final scene = buildScene(count: 8);
      scene.positions[5 * 3 + 1] = double.nan;
      expect(
        () => writeFourdgsBytes(scene, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('positions'), contains('gaussian 5')),
          ),
        ),
      );
    });

    test('a NaN window is refused, an infinite one is not', () {
      final withNan = buildScene(count: 8);
      withNan.winHi[3] = double.nan;
      expect(
        () => writeFourdgsBytes(withNan, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('win_hi'), contains('gaussian 3')),
          ),
        ),
      );
      expect(
        () => writeFourdgsBytes(flatScene(4, winHi: double.infinity), 2.0),
        returnsNormally,
      );
    });

    test(
      'a negative sigma is refused and +inf is the way to say never-fades',
      () {
        final scene = buildScene(count: 8);
        scene.sigmaT[2] = double.negativeInfinity;
        expect(
          () => writeFourdgsBytes(scene, 8.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('sigma_t'), contains('never fades')),
            ),
          ),
        );
      },
    );

    test('an unknown profile lists the ones that exist', () {
      expect(
        () => writeFourdgsBytes(
          buildScene(),
          8.0,
          options: const FourdgsWriteOptions(profile: 'lossless'),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('lossless'), contains('default')),
          ),
        ),
      );
    });

    test('a duration that is not a scene length is refused', () {
      for (final duration in <double>[double.nan, double.infinity, -1.0]) {
        expect(
          () => writeFourdgsBytes(buildScene(), duration),
          throwsA(isA<FourdgsInvalidInput>()),
          reason: 'duration_sec = $duration',
        );
      }
    });

    test(
      'a cutoff outside (0, 1] is refused before it reaches a logarithm',
      () {
        expect(
          () => writeFourdgsBytes(
            buildScene(),
            8.0,
            options: const FourdgsWriteOptions(cutoff: 0.0),
          ),
          throwsA(isA<FourdgsMalformedFile>()),
        );
      },
    );

    test('a bin at the edge of the symbol domain never becomes a wrong one', () {
      // A delta between two bins at opposite ends of the signed 32-bit range
      // needs 33 bits, and an attribute stream's symbols are 32. The interesting
      // failure is not the refusal — it is the silent one: truncating that delta
      // produces a stream that decodes to a different number.
      //
      // Velocity is where it is reachable, because its bins are signed and its
      // pitch is the finest in the format. The shape matters as much as the
      // magnitude: a scene whose velocities sit near one extreme and then jump to
      // the other delta-codes to a run of near-zeros and a single 33-bit step,
      // which is exactly the input that makes delta the smaller of the two
      // candidates and therefore the one written.
      //
      // The sweep is deliberately blind about where the boundary falls. Whatever
      // the encoder does with a magnitude, the result must be a file this decoder
      // reads back to the velocities that went in, or a refusal naming the
      // attribute and the gaussian. Never a third thing.
      for (final magnitude in <double>[1e3, 1e4, 1e5, 1e6, 1e9]) {
        const count = 64;
        final scene = flatScene(count);
        for (int i = 0; i < count; i++) {
          final sign = i < count ~/ 2 ? 1.0 : -1.0;
          scene.motions[i * 3] = sign * (magnitude - i);
        }
        Uint8List bytes;
        try {
          bytes = writeFourdgsBytes(scene, 2.0);
        } on FourdgsInvalidInput catch (error) {
          expect(error.message, contains('motion'));
          continue;
        }
        final decoded = readFourdgsBytes(bytes);
        expect(decoded.gaussians.count, count, reason: 'magnitude $magnitude');
        for (int i = 0; i < count; i++) {
          expect(
            decoded.gaussians.motions[i * 3].abs(),
            closeTo(magnitude - i, magnitude * 1e-3),
            reason: 'magnitude $magnitude, gaussian $i',
          );
        }
      }
    });

    test('a codec this build cannot write is named rather than attempted', () {
      expect(
        () => writeFourdgsBytes(
          buildScene(),
          8.0,
          options: const FourdgsWriteOptions(codec: codecZstd),
        ),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
    });
  });
}

/// The `u64 content_length` of the record whose opcode byte is at [at].
int _contentLength(Uint8List bytes, int at) {
  final cursor = FourdgsCursor(bytes, at + 1);
  return cursor.u64();
}

/// Pair each decoded gaussian with the input it came from, by exact window and
/// nearest position.
///
/// The encoder reorders a chunk's members and is entitled to: nothing in the
/// format fixes gaussian order and no decoder may assume one. The pairing is
/// unambiguous here because the fixture's positions are distinct and the
/// position bound is four orders of magnitude below their spacing.
List<int> _pairByPosition(
  FourdgsGaussianSet input,
  FourdgsGaussianSet decoded,
) {
  final taken = List<bool>.filled(input.count, false);
  final pairing = List<int>.filled(decoded.count, -1);
  for (int j = 0; j < decoded.count; j++) {
    double best = double.infinity;
    int at = -1;
    for (int i = 0; i < input.count; i++) {
      if (taken[i]) continue;
      double d = 0;
      for (int axis = 0; axis < 3; axis++) {
        final delta =
            decoded.positions[j * 3 + axis] - input.positions[i * 3 + axis];
        d += delta * delta;
      }
      if (d < best) {
        best = d;
        at = i;
      }
    }
    taken[at] = true;
    pairing[j] = at;
  }
  return pairing;
}
