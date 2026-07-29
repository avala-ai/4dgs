// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The two things the canonical JSON cannot say.
///
/// Every other row in the feature matrix is proved by a summary matching an
/// expectation. These two are not, and cannot be: a cut file is a *different*
/// file, so no expectation describes it; and never transferring a band you will
/// not evaluate is a fact about the transport, not about any decoded value. So
/// the checks live in the runner, where a failure exits non-zero and the harness
/// reports it like a diff.
library;

import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';

/// A check that failed. Distinct from [FourdgsException] on purpose: this is the
/// suite disagreeing with the decoder, not the decoder disagreeing with a file.
class ConformanceFailure implements Exception {
  ConformanceFailure(this.message);

  final String message;

  @override
  String toString() => 'conformance: $message';
}

/// A [FourdgsReadable] that records what it transferred, so a claim about byte
/// ranges can be checked against the bytes that actually moved.
class CountingReadable implements FourdgsReadable {
  CountingReadable(this._inner);

  final FourdgsReadable _inner;

  /// Bytes asked for since this wrapper was made.
  int bytesRead = 0;

  @override
  Future<int> size() => _inner.size();

  @override
  Future<Uint8List> read(int offset, int length) {
    bytesRead += length;
    return _inner.read(offset, length);
  }
}

/// Decodes the same file cut short, twice, and insists on what survives.
///
/// Nothing in the corpus is truncated, so this makes two files that are. The
/// rule in both cases is the same: what preceded the cut must decode, and the
/// reader must **say** it was cut rather than pass a short scene off as a
/// complete one. Silence is the failure mode that matters — a decoder that
/// returns fewer gaussians without comment is one a consumer cannot distinguish
/// from a small file.
void checkTruncationRecovery(Uint8List data, FourdgsScene whole) {
  // Cut before the trailing magic. Everything the file said is still in it, so
  // nothing may be lost: a reader that needs the trailing magic to finish is a
  // reader that cannot read a file that is still being written.
  final tail = readFourdgsBytes(
    Uint8List.sublistView(data, 0, data.length - 1),
  );
  if (!tail.truncated) {
    throw ConformanceFailure(
      'a file cut before its trailing magic was not reported truncated',
    );
  }
  if (tail.gaussians.count != whole.gaussians.count) {
    throw ConformanceFailure(
      'cutting the trailing magic lost gaussians: ${tail.gaussians.count} of ${whole.gaussians.count}',
    );
  }

  // Cut inside the last chunk's record header. What survives is exactly the
  // chunks that preceded it, so the count is known rather than merely bounded.
  if (whole.chunkIndex.length >= 2) {
    final last = whole.chunkIndex.last;
    final mid = readFourdgsBytes(
      Uint8List.sublistView(data, 0, last.chunkOffset + 5),
    );
    if (!mid.truncated) {
      throw ConformanceFailure(
        'a file cut inside a chunk record was not reported truncated',
      );
    }
    final expected = whole.gaussians.count - last.gaussianCount;
    if (mid.gaussians.count != expected) {
      throw ConformanceFailure(
        'cutting the last chunk left ${mid.gaussians.count} gaussians, expected $expected',
      );
    }
  }
}

/// Asserts that capping spherical-harmonic bands actually moves fewer bytes.
///
/// Measured at the transport, because that is the whole feature: bands each have
/// their own byte range in the chunk index, and a reader that has decided to
/// evaluate fewer of them should never fetch the rest. A decoder can evaluate
/// the right bands and still transfer all of them, and no decoded value would
/// ever show it.
///
/// The assertion is on the byte **count**, against what the index declares. A
/// cache that answers a narrow cap from a wider entry returns the wider byte
/// count while looking perfectly healthy, which is exactly the shape of bug this
/// is here to catch.
Future<void> checkBandRangeSkipping(
  CountingReadable source,
  FourdgsIndexedScene scene,
) async {
  for (final entry in scene.index) {
    if (entry.bands.isEmpty) continue;
    for (final cap in <int>[
      0,
      ...entry.bands.map((FourdgsBandRange b) => b.band),
    ]) {
      final before = source.bytesRead;
      await readFourdgsChunk(source, scene, entry, maxShBand: cap);
      final moved = source.bytesRead - before;
      int wanted = entry.chunkLength;
      for (final band in entry.bands) {
        if (band.band <= cap) wanted += band.length;
      }
      if (moved != wanted) {
        throw ConformanceFailure(
          'reading a chunk with maxShBand=$cap transferred $moved bytes, the index says $wanted',
        );
      }
    }
  }
}
