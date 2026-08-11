// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The things the canonical JSON cannot say.
///
/// Every other row in the feature matrix is proved by a summary matching an
/// expectation. These are not, and cannot be: a cut file is a *different* file,
/// so no expectation describes it; never transferring a band you will not
/// evaluate is a fact about the transport, not about any decoded value; and a
/// *selective* seek is a fact about which chunks were read, which a summary
/// assembled from all of them cannot distinguish from a wrong partition. So the
/// checks live in the runner, where a failure exits non-zero and the harness
/// reports it like a diff.
library;

import 'dart:math' as math;
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

/// Asserts that a seek reads the chunks an instant needs — and that they hold
/// every gaussian visible at it.
///
/// This is the check the canonical summary cannot make, and the reason is worth
/// stating plainly: both runners assemble the **whole** scene. The indexed one
/// walks every index entry and concatenates the result, so a gaussian filed in
/// the wrong chunk still appears in its summary, at the same values, and the two
/// read paths still agree. What such a file loses is the only thing an index is
/// for — a seek at an instant returns a scene missing gaussians that were
/// visible at it — and nothing in a whole-scene comparison can see that.
///
/// So this selects. For each probe instant it reads only the entries whose
/// half-open interval contains it, reconstructs state at that instant from those
/// chunks alone, and requires it to equal the state the whole scene gives. That
/// is the seek contract stated as an equality, rather than as a property of the
/// writer that has to be re-derived.
///
/// **Probes near a chunk boundary are skipped, and the guard is derived from the
/// file rather than chosen.** The partition is planned on the encoder's input
/// support while a reader sees the *reconstructed* support, so a gaussian may
/// sit a little outside its own chunk's interval — by at most half its own
/// `mu_t` pitch plus `k` times its `sigma_t` quantization error, both of which
/// this file declares. Within that distance of a boundary the answer is
/// genuinely ambiguous and the check would be asserting the writer's rounding
/// rather than its filing. Past it, nothing excuses a missing gaussian.
///
/// The number of probes that ran is returned so a caller can insist some did. A
/// guard that swallowed every instant would otherwise leave this reporting
/// success for a check that never executed, which is the failure mode every
/// self-skipping test has.
Future<int> checkSeekReadsOnlyWhatItNeeds(
  CountingReadable source,
  FourdgsIndexedScene scene,
  FourdgsGaussianSet whole,
) async {
  final index = scene.index;
  if (index.length < 2 || whole.count == 0) return 0;

  // How far from a boundary a gaussian may legitimately sit on the far side of
  // it. Per gaussian, out of the record's own pitches.
  final quantization = scene.quantization;
  final k = supportK(scene.header.cutoff);
  final sigmaLog = quantization.stepSigmaLog;
  final sigmaHalfRelative = math.exp(0.5 * sigmaLog) - 1.0;
  double guard = 0.0;
  for (int i = 0; i < whole.count; i++) {
    final sigma = whole.sigmaT[i];
    final neverFades = !sigma.isFinite;
    // A never-fading gaussian's support is its validity window, and the Window
    // Table stores that verbatim: nothing about it was rounded.
    final sigmaBin =
        neverFades ? 0 : (math.log(math.max(sigma, 1e-30)) / sigmaLog).round();
    final mu = muStep(sigmaBin, sigmaLog, neverFades, quantization.stepTime);
    final slack = 0.5 * mu + (neverFades ? 0.0 : k * sigma * sigmaHalfRelative);
    if (slack.isFinite && slack > guard) guard = slack;
  }

  final boundaries =
      <double>{
          for (final entry in index) ...<double>[entry.t0, entry.t1],
        }.toList()
        ..sort();

  int probed = 0;
  for (final entry in index) {
    final span = entry.t1 - entry.t0;
    if (!span.isFinite || span <= 0.0) continue;
    for (final fraction in const <double>[0.13, 0.37, 0.61, 0.89]) {
      final t = entry.t0 + fraction * span;
      if (!t.isFinite) continue;
      var tooClose = false;
      for (final boundary in boundaries) {
        if ((t - boundary).abs() <= guard) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      final selected = <FourdgsChunkIndexEntry>[
        for (final candidate in index)
          if (candidate.t0 <= t && t < candidate.t1) candidate,
      ];
      if (selected.isEmpty) {
        throw ConformanceFailure(
          'no chunk index entry covers t=$t, which lies inside '
          '[${entry.t0}, ${entry.t1})',
        );
      }
      final chunks = <FourdgsDecodedChunk>[
        for (final e in selected)
          await readFourdgsChunk(source, scene, e, maxShBand: 0),
      ];
      final fromSeek = _visibleKeys(
        assembleGaussians(chunks, 0),
        t,
        scene.header.cutoff,
      );
      final fromWhole = _visibleKeys(whole, t, scene.header.cutoff);
      if (fromSeek.length != fromWhole.length ||
          !_sameKeys(fromSeek, fromWhole)) {
        throw ConformanceFailure(
          'a seek at t=$t read ${selected.length} of ${index.length} chunks and '
          'found ${fromSeek.length} visible gaussians; the whole scene has '
          '${fromWhole.length} visible there',
        );
      }
      probed++;
    }
  }
  return probed;
}

/// Reconstructed state at [t] as sorted keys, so two orderings of one answer
/// compare equal — a chunk's members are Morton-ordered and a selection of
/// chunks concatenates in index order, and neither is part of the claim.
List<String> _visibleKeys(FourdgsGaussianSet g, double t, double cutoff) {
  final state = g.stateAt(t, cutoff: cutoff);
  final keys = <String>[
    for (int j = 0; j < state.count; j++)
      '${state.centers[j * 3]},${state.centers[j * 3 + 1]},'
          '${state.centers[j * 3 + 2]},${state.opacity[j]}',
  ];
  keys.sort();
  return keys;
}

bool _sameKeys(List<String> a, List<String> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
