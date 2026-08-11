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

    test('Header and Statistics bound the positions the file reconstructs', () {
      final scene = flatScene(2);
      // With a 1e-3 median scale the default position pitch is 1e-4. This
      // authored maximum rounds outward to the 1e-4 bin, so an AABB taken from
      // the input would exclude the point the file actually reconstructs.
      scene.positions[3] = 0.000075;
      // The bin arithmetic is double but the decoder's lane is float32. Its
      // negative maximum rounds upward on that final narrowing, so the AABB has
      // to be measured after the same conversion rather than just from bins.
      scene.positions[1] = -227.37311;
      scene.positions[4] = -227.37305;
      final decoded = readFourdgsBytes(
        writeFourdgsBytes(
          scene,
          1.0,
          options: const FourdgsWriteOptions(writeStatistics: true),
        ),
      );
      final reconstructed = <double>[
        double.infinity,
        double.infinity,
        double.infinity,
        double.negativeInfinity,
        double.negativeInfinity,
        double.negativeInfinity,
      ];
      for (int i = 0; i < decoded.gaussians.count; i++) {
        for (int axis = 0; axis < 3; axis++) {
          final value = decoded.gaussians.positions[i * 3 + axis];
          reconstructed[axis] = math.min(reconstructed[axis], value);
          reconstructed[3 + axis] = math.max(reconstructed[3 + axis], value);
        }
      }
      for (int i = 0; i < 6; i++) {
        expect(decoded.header.aabb[i], closeTo(reconstructed[i], 1e-12));
        expect(decoded.statistics!.aabb[i], decoded.header.aabb[i]);
      }
      expect(decoded.header.aabb[3], greaterThan(scene.positions[3]));
    });

    test(
      'a finite authored position cannot reconstruct to float32 infinity',
      () {
        const f32Max = 3.4028234663852886e38;
        final scene = flatScene(2);
        scene.positions[3] = f32Max;
        scene.scales.fillRange(0, scene.scales.length, 0.95 * f32Max);
        expect(
          () => writeFourdgsBytes(scene, 1.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(
                contains('position'),
                contains('gaussian 1'),
                contains('float32'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'a finite authored velocity cannot reconstruct to float32 infinity',
      () {
        const f32Max = 3.4028234663852886e38;
        final scene = flatScene(2, winHi: 0.5);
        scene.scales.fillRange(0, scene.scales.length, 0.9 * f32Max);
        scene.sigmaT.fillRange(0, scene.sigmaT.length, double.infinity);
        scene.motions[3] = f32Max;
        expect(
          () => writeFourdgsBytes(scene, 0.5),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(
                contains('motion'),
                contains('gaussian 1'),
                contains('float32'),
              ),
            ),
          ),
        );
      },
    );

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

  group('the optional identity streams', () {
    // Neither is quantized and neither has a bound: they are labels. What has to
    // hold is that a decode-then-encode returns them, because §6.6 says a writer
    // has no business dropping them — "the Object Table, Object Tracks and
    // `object_id` stream are independently optional … None is a reason to invent
    // or discard another" — and because a producer's stable ids are the one
    // thing in a file that nothing else can reconstruct.
    FourdgsGaussianSet withIds(FourdgsGaussianSet g) => FourdgsGaussianSet(
      positions: g.positions,
      scales: g.scales,
      rotations: g.rotations,
      colors: g.colors,
      motions: g.motions,
      muT: g.muT,
      sigmaT: g.sigmaT,
      winLo: g.winLo,
      winHi: g.winHi,
      sourceGroup: Int32List.fromList(<int>[
        for (int i = 0; i < g.count; i++) (i * 13) - 71,
      ]),
      sourceIndex: Int32List.fromList(<int>[
        for (int i = 0; i < g.count; i++) 1000 - i,
      ]),
      // The full unsigned domain, including the two values that only survive a
      // same-bits signed view: `0x80000000` is `-2147483648` as a stream symbol
      // and `0xFFFFFFFF` is `-1`.
      objectId: Uint32List.fromList(<int>[
        for (int i = 0; i < g.count; i++)
          switch (i % 4) {
            0 => 0,
            1 => 7,
            2 => 0x80000000,
            _ => 0xFFFFFFFF,
          },
      ]),
    );

    test('source_group, source_index and object_id survive re-encoding', () {
      final scene = withIds(buildScene(count: 48));
      final once = readFourdgsBytes(writeFourdgsBytes(scene, 8.0));
      expect(once.gaussians.sourceGroup, isNotNull);
      expect(once.gaussians.sourceIndex, isNotNull);
      expect(once.gaussians.objectId, isNotNull);

      final pairing = _pairByPosition(scene, once.gaussians);
      for (int j = 0; j < pairing.length; j++) {
        final i = pairing[j];
        expect(once.gaussians.sourceGroup![j], scene.sourceGroup![i]);
        expect(once.gaussians.sourceIndex![j], scene.sourceIndex![i]);
        expect(once.gaussians.objectId![j], scene.objectId![i]);
      }

      // And through a second pass, which is the case the finding was about: a
      // tool that reads a file and writes it back must not be where the ids go
      // missing.
      final twice =
          readFourdgsBytes(writeFourdgsBytes(once.gaussians, 8.0)).gaussians;
      expect(twice.sourceGroup, isNotNull);
      expect(twice.sourceIndex, isNotNull);
      expect(
        <int>[...twice.objectId!]..sort(),
        <int>[...once.gaussians.objectId!]..sort(),
      );
    });

    test('a scene without them writes neither stream', () {
      final bytes = writeFourdgsBytes(buildScene(count: 16), 8.0);
      final decoded = readFourdgsBytes(bytes).gaussians;
      expect(decoded.sourceGroup, isNull);
      expect(decoded.sourceIndex, isNull);
      expect(decoded.objectId, isNull);
    });

    test('an id lane of the wrong length is named rather than truncated', () {
      final base = buildScene(count: 8);
      final wrong = FourdgsGaussianSet(
        positions: base.positions,
        scales: base.scales,
        rotations: base.rotations,
        colors: base.colors,
        motions: base.motions,
        muT: base.muT,
        sigmaT: base.sigmaT,
        winLo: base.winLo,
        winHi: base.winHi,
        objectId: Uint32List(7),
      );
      expect(
        () => writeFourdgsBytes(wrong, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('object_id'), contains('7')),
          ),
        ),
      );
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

    test('the Summary Offset frames the index and stops before Statistics', () {
      // A Summary Offset exists so a consumer can range-read one *class* of
      // summary record without the rest of the summary. The range it declares
      // therefore has to end where the Chunk Index ends: measured after the
      // Statistics record was appended, it advertises `opChunkIndex` over a run
      // whose tail is a Statistics record, and a reader that fetched exactly
      // that range and parsed it as index entries would find one.
      final bytes = writeFourdgsBytes(
        buildScene(),
        8.0,
        options: const FourdgsWriteOptions(
          writeStatistics: true,
          writeSummaryOffsets: true,
        ),
      );
      final decoded = readFourdgsBytes(bytes);
      final offset = decoded.summaryOffsets.single;
      expect(offset.groupOpcode, opChunkIndex);

      // Parse the advertised range on its own, the way a consumer that fetched
      // only those bytes would have to.
      final group =
          iterRecords(
            Uint8List.sublistView(
              bytes,
              offset.groupStart,
              offset.groupStart + offset.groupLength,
            ),
          ).toList();
      expect(
        <int>{for (final r in group) r.opcode},
        <int>{opChunkIndex},
        reason: 'the range must hold index records and nothing else',
      );
      expect(group.length, decoded.chunkIndex.length);
      // Whole records: the last one ends exactly where the range does.
      expect(
        group.last.offset + group.last.framedLength,
        offset.groupLength,
        reason: 'the range must end on a record boundary',
      );
      // And it must stop short of the Statistics record that follows it.
      final statistics = recordsOf(
        bytes,
      ).firstWhere((FourdgsRecord r) => r.opcode == opStatistics);
      expect(offset.groupStart + offset.groupLength, statistics.offset);
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

    test('the Header declares the highest band actually written', () {
      // `shBands` caps what is emitted. The Header's degree is a statement about
      // what the file carries, so it has to follow the cap: a degree-3 scene
      // written with `shBands: 1` carries band 1 alone, and declaring 3 there
      // would promise fifteen coefficients per component where three were
      // written. Bands are whole and a reader takes them whole (spec §6.5).
      final scene = buildScene(count: 32, shDegree: 3);
      for (final cap in <int>[1, 2, 3]) {
        final bytes = writeFourdgsBytes(
          scene,
          8.0,
          options: FourdgsWriteOptions(shBands: cap),
        );
        final decoded = readFourdgsBytes(bytes);
        expect(decoded.header.shDegree, cap, reason: 'shBands: $cap');
        final bands =
            recordsOf(
              bytes,
            ).where((FourdgsRecord r) => r.opcode == opShBandStream).length;
        expect(bands, cap, reason: 'shBands: $cap');
        // The two have to agree with each other, which is the whole point: a
        // reader sizes the coefficient row from the degree.
        expect(
          decoded.gaussians.shCoefficients,
          shBandRange[cap]!.last,
          reason: 'shBands: $cap',
        );
      }
    });

    test('the coarse profile puts coefficients on the pitch it declares', () {
      // `step_sh` is an encode-side value (spec §6.5): a decoder does nothing
      // with it, which is exactly why the encoder must. A file that declares a
      // pitch of 3 and writes every byte through has said something about
      // itself that is not true, and the profile's SH allowance buys nothing.
      final scene = buildScene(count: 64, shDegree: 2);
      final coarse = readFourdgsBytes(
        writeFourdgsBytes(
          scene,
          8.0,
          options: const FourdgsWriteOptions(profile: 'coarse'),
        ),
      );
      expect(coarse.quantization.stepSh, 3);
      expect(coarse.quantization.bounds['sh'], '1');
      final sh = coarse.gaussians.sh!;
      for (int i = 0; i < sh.length; i++) {
        // A bin centre, or the top of the byte range — the last bin's centre is
        // 256 at this pitch, and a coefficient that left the byte would arrive
        // at a reader as zero: the extreme positive coefficient read as the
        // extreme negative one.
        expect(
          sh[i] % 3 == 1 || sh[i] == 255,
          isTrue,
          reason: 'coefficient $i is ${sh[i]}, off the pitch of 3 declared',
        );
      }
      // Half the pitch is the promise, and it is kept against the input.
      final pairing = _pairByPosition(scene, coarse.gaussians);
      final row = 3 * scene.shCoefficients;
      int worst = 0;
      for (int j = 0; j < pairing.length; j++) {
        final i = pairing[j];
        for (int k = 0; k < row; k++) {
          final d = (sh[j * row + k] - scene.sh![i * row + k]).abs();
          if (d > worst) worst = d;
        }
      }
      expect(worst, lessThanOrEqualTo(1));

      // And the identity where the pitch is 1, which is what the other two
      // profiles declare — the byte is stored as it arrived.
      final fine = readFourdgsBytes(
        writeFourdgsBytes(
          scene,
          8.0,
          options: const FourdgsWriteOptions(profile: 'fine'),
        ),
      );
      expect(fine.quantization.stepSh, 1);
      final finePairing = _pairByPosition(scene, fine.gaussians);
      for (int j = 0; j < finePairing.length; j++) {
        final i = finePairing[j];
        for (int k = 0; k < row; k++) {
          expect(fine.gaussians.sh![j * row + k], scene.sh![i * row + k]);
        }
      }
    });

    test('a coefficient row that stops inside a band is refused', () {
      // Bands are whole and a reader takes them whole (spec §6.5).
      // `decodeShBandRecord` refuses a band record whose stream declares fewer
      // channels than the band defines, so a row of four coefficients — a whole
      // degree-1 band and two fifths of a degree-2 one — cannot be written as
      // band 2. Before this check the writer built that band out of its one
      // available column and declared three channels where fifteen were
      // required, and the file it returned could not be reopened by either of
      // this package's read paths.
      final base = buildScene(count: 8, shDegree: 2);
      final partial = FourdgsGaussianSet(
        positions: base.positions,
        scales: base.scales,
        rotations: base.rotations,
        colors: base.colors,
        motions: base.motions,
        muT: base.muT,
        sigmaT: base.sigmaT,
        winLo: base.winLo,
        winHi: base.winHi,
        shDegree: 2,
        shCoefficients: 4,
        sh: Uint8List(8 * 3 * 4),
      );
      expect(
        () => writeFourdgsBytes(partial, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sh_coefficients'), contains('4')),
          ),
        ),
      );

      // A buffer that does not hold `count * 3 * sh_coefficients` bytes is
      // refused by name too, rather than indexing off its end in the gather
      // loop.
      final short = FourdgsGaussianSet(
        positions: base.positions,
        scales: base.scales,
        rotations: base.rotations,
        colors: base.colors,
        motions: base.motions,
        muT: base.muT,
        sigmaT: base.sigmaT,
        winLo: base.winLo,
        winHi: base.winHi,
        shDegree: 2,
        shCoefficients: 8,
        sh: Uint8List(8 * 3 * 8 - 1),
      );
      expect(
        () => writeFourdgsBytes(short, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('sh'), contains('${8 * 3 * 8}')),
          ),
        ),
      );

      // Whole rows can still be too deep for the degree the caller declared.
      // Silently taking the degree-1 prefix of this degree-3 row would lose
      // twelve supplied coefficients per colour component.
      final deeperThanDeclared = FourdgsGaussianSet(
        positions: base.positions,
        scales: base.scales,
        rotations: base.rotations,
        colors: base.colors,
        motions: base.motions,
        muT: base.muT,
        sigmaT: base.sigmaT,
        winLo: base.winLo,
        winHi: base.winHi,
        shDegree: 1,
        shCoefficients: 15,
        sh: Uint8List(8 * 3 * 15),
      );
      expect(
        () => writeFourdgsBytes(deeperThanDeclared, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(
              contains('sh_coefficients is 15'),
              contains('sh_degree 1'),
              contains('discard'),
            ),
          ),
        ),
      );
    });

    test('a degree the bands do not reach is written as the bands that do', () {
      // This shape is not malformed input, it is what decoding a file whose
      // Header names degree 3 while its chunks carry bands 1 and 2 produces:
      // `shDegree` comes from the Header and `shCoefficients` from the bands
      // that were actually merged. Re-encoding it has to write the two whole
      // bands and declare degree 2, not refuse and not invent a third.
      final base = buildScene(count: 8, shDegree: 2);
      final overDeclared = FourdgsGaussianSet(
        positions: base.positions,
        scales: base.scales,
        rotations: base.rotations,
        colors: base.colors,
        motions: base.motions,
        muT: base.muT,
        sigmaT: base.sigmaT,
        winLo: base.winLo,
        winHi: base.winHi,
        shDegree: 3,
        shCoefficients: 8,
        sh: base.sh,
      );
      final bytes = writeFourdgsBytes(overDeclared, 8.0);
      final decoded = readFourdgsBytes(bytes);
      expect(decoded.header.shDegree, 2);
      expect(decoded.gaussians.shCoefficients, 8);
      expect(
        recordsOf(
          bytes,
        ).where((FourdgsRecord r) => r.opcode == opShBandStream).length,
        2,
      );
    });

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

    test('an inverted window is refused, an empty one is not', () {
      // Visibility is gated on `lo <= t < hi`, so a window whose lower bound is
      // above its upper covers no instant and the gaussian disappears from a
      // file that otherwise looks well-formed — and this package's own reader
      // refuses the Window Table record that carries it. Without this check the
      // encoder hands back a file neither of its read paths will reopen.
      final inverted = buildScene(count: 8);
      inverted.winLo[6] = 5.0;
      inverted.winHi[6] = 1.0;
      expect(
        () => writeFourdgsBytes(inverted, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('gaussian 6'), contains('5.0'), contains('1.0')),
          ),
        ),
      );
      // `lo == hi` stays legal: it is what a static asset's window says, and the
      // NoData fixture is exactly that.
      final empty = buildScene(count: 8);
      empty.winLo[2] = 3.0;
      empty.winHi[2] = 3.0;
      expect(() => writeFourdgsBytes(empty, 8.0), returnsNormally);
    });

    test('a mu_t of a different length is a differently sized scene', () {
      // `count` is `muT.length`, so `mu_t` is the ruler and not a lane that can
      // disagree with it: passing a shorter or longer one describes a smaller or
      // larger scene, and every other lane is then the wrong length. What has to
      // hold is that this is *diagnosed by name* rather than reaching the
      // quantizer and coming back as a RangeError about an index.
      final scene = buildScene(count: 8);
      for (final wrong in <int>[7, 9]) {
        final bad = FourdgsGaussianSet(
          positions: scene.positions,
          scales: scene.scales,
          rotations: scene.rotations,
          colors: scene.colors,
          motions: scene.motions,
          muT: Float32List(wrong),
          sigmaT: scene.sigmaT,
          winLo: scene.winLo,
          winHi: scene.winHi,
        );
        expect(bad.count, wrong);
        expect(
          () => writeFourdgsBytes(bad, 8.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('positions'), contains('${wrong * 3}')),
            ),
          ),
          reason:
              'mu_t of length $wrong against 8 gaussians of everything else',
        );
      }
    });

    test('promissory and reserved scene profiles are refused', () {
      // A profile is a promise about what the file contains. `objects` promises
      // an object_id stream in every non-empty chunk and one Object Table, and
      // this writer emits neither — so the Header would carry a promise the
      // bytes below it do not keep, and no reader today enforces it.
      expect(
        () => writeFourdgsBytes(
          buildScene(count: 8),
          8.0,
          options: const FourdgsWriteOptions(sceneProfile: 'objects'),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(
              contains('objects'),
              contains('Object Table'),
              isNot(contains('object_id')),
            ),
          ),
        ),
      );
      expect(
        () => writeFourdgsBytes(
          buildScene(count: 8),
          8.0,
          options: const FourdgsWriteOptions(sceneProfile: 'keyframed'),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('keyframed'), contains('keyframe-delta')),
          ),
        ),
      );
      expect(
        () => writeFourdgsBytes(
          buildScene(count: 8),
          8.0,
          options: const FourdgsWriteOptions(sceneProfile: 'relightable'),
        ),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('relightable'), contains('MUST NOT')),
          ),
        ),
      );
      // The profiles this writer can keep are unaffected.
      for (final profile in <String>['', 'capture', 'baked']) {
        expect(
          () => writeFourdgsBytes(
            buildScene(count: 8),
            8.0,
            options: FourdgsWriteOptions(sceneProfile: profile),
          ),
          returnsNormally,
          reason: profile,
        );
      }
    });

    test('NaN and cross-SDK-ambiguous infinite empty windows are refused', () {
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

      for (final endpoint in <double>[
        double.infinity,
        double.negativeInfinity,
      ]) {
        final empty = flatScene(4);
        empty.winLo[2] = endpoint;
        empty.winHi[2] = endpoint;
        expect(
          () => writeFourdgsBytes(empty, 2.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('gaussian 2'), contains('infinite empty')),
            ),
          ),
          reason: 'endpoint $endpoint',
        );
      }

      // The shared Dart decoder still treats the legal wire value as an empty
      // lifetime. The writer refuses it until the other SDKs share that rule.
      expect(lifeClass(0, 0.1, true, double.nan), lifeClass(0, 0.1, true, 0.0));
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

        // And a *finite* negative one, which the -inf check does not cover. It
        // reaches `log(max(sigma, 1e-30))` and is stored as a lifetime of
        // 1e-30 s: the file then declares a `sigma_rel` bound of 0.02 and the
        // scene it decodes to misses the authored value by thirty orders of
        // magnitude.
        final finite = buildScene(count: 8);
        finite.sigmaT[5] = -0.1;
        expect(
          () => writeFourdgsBytes(finite, 8.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('sigma_t'), contains('gaussian 5')),
            ),
          ),
        );

        // Zero stays legal. It is a gaussian whose support is a single instant,
        // which is a shape the chunk planner has to handle, and `1e-30` is as
        // near it as a logarithmic grid reaches.
        final instant = buildScene(count: 8);
        instant.sigmaT[1] = 0.0;
        expect(() => writeFourdgsBytes(instant, 8.0), returnsNormally);
      },
    );

    test('a colour outside [0, 1] is refused rather than clamped', () {
      // `decodeChunk` clamps reconstructed colours into [0, 1], so a channel of
      // 1.2 comes back as 1.0 while the file declares an `rgb` bound near
      // 0.004. Writing it would be the encoder changing the authored scene by
      // two hundred times its own stated tolerance, silently.
      for (final channel in <int>[0, 3]) {
        for (final value in <double>[-0.1, 1.2]) {
          final scene = buildScene(count: 8);
          scene.colors[4 * 4 + channel] = value;
          expect(
            () => writeFourdgsBytes(scene, 8.0),
            throwsA(
              isA<FourdgsInvalidInput>().having(
                (FourdgsInvalidInput e) => e.message,
                'message',
                allOf(
                  contains(channel == 3 ? 'opacity' : 'color'),
                  contains('gaussian 4'),
                ),
              ),
            ),
            reason: 'channel $channel = $value',
          );
        }
      }
      // The endpoints are inside the range and stay writable.
      final edges = buildScene(count: 8);
      edges.colors[0] = 0.0;
      edges.colors[1] = 1.0;
      expect(() => writeFourdgsBytes(edges, 8.0), returnsNormally);
    });

    test('a scale at or below zero is refused rather than floored', () {
      // Same defect as the colour clamp, one lane over: scales are quantized as
      // `log(max(scale, 1e-30))` against a *relative* bound, and zero has no
      // relative distance from anything.
      for (final value in <double>[0.0, -1e-3]) {
        final scene = buildScene(count: 8);
        scene.scales[3 * 3 + 2] = value;
        expect(
          () => writeFourdgsBytes(scene, 8.0),
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('scale'), contains('gaussian 3')),
            ),
          ),
          reason: 'scale = $value',
        );
      }
    });

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
      for (final duration in <double>[double.nan, -1.0]) {
        expect(
          () => writeFourdgsBytes(buildScene(), duration),
          throwsA(isA<FourdgsInvalidInput>()),
          reason: 'duration_sec = $duration',
        );
      }
    });

    test('+Infinity writes an open-ended scene', () {
      final scene = flatScene(8, winHi: double.infinity);
      final decoded = readFourdgsBytes(
        writeFourdgsBytes(scene, double.infinity),
      );
      expect(decoded.header.durationSec, double.infinity);
      expect(decoded.chunkIndex, isNotEmpty);
      expect(decoded.chunkIndex.last.t1, double.infinity);
    });

    test('a zero-length quaternion is refused by gaussian', () {
      final scene = buildScene(count: 8);
      for (int c = 0; c < 4; c++) {
        scene.rotations[5 * 4 + c] = 0.0;
      }
      expect(
        () => writeFourdgsBytes(scene, 8.0),
        throwsA(
          isA<FourdgsInvalidInput>().having(
            (FourdgsInvalidInput e) => e.message,
            'message',
            allOf(contains('rotation'), contains('gaussian 5')),
          ),
        ),
      );
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
          throwsA(
            isA<FourdgsInvalidInput>().having(
              (FourdgsInvalidInput e) => e.message,
              'message',
              allOf(contains('cutoff'), contains('(0, 1]')),
            ),
          ),
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
