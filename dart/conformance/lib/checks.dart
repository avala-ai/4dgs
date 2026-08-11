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

import 'dart:collection';
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

/// The stable inverse representative for a reconstructed sigma grid.
///
/// A zero pitch is legal and maps every finite bin to sigma 1. There is no
/// unique inverse in that case, so bin zero is the representative used by the
/// seek-rounding guard.
int seekGuardSigmaBin(double sigma, double sigmaLogStep) =>
    sigmaLogStep == 0.0
        ? 0
        : (math.log(math.max(sigma, 1e-30)) / sigmaLogStep).round();

/// Every populated, non-empty entry that must exercise a selective seek.
///
/// Correctness is per interval: success elsewhere cannot prove that this
/// chunk's resident content was filed where a seek can reach it.
List<FourdgsChunkIndexEntry> seekProbeEntries(
  List<FourdgsChunkIndexEntry> index, {
  required bool isKeyframeDelta,
}) {
  return <FourdgsChunkIndexEntry>[
    for (final entry in index)
      if (entry.t1 > entry.t0 &&
          indexEntryPopulation(entry, isKeyframeDelta: isKeyframeDelta) > 0)
        entry,
  ];
}

/// Finite instants strictly inside an index entry, including unbounded ones.
List<double> seekProbeInstants(
  FourdgsChunkIndexEntry entry,
  double Function(double boundary) guardAt,
) {
  List<double> inside(Iterable<double> candidates) => candidates
      .where((t) => t.isFinite && entry.covers(t))
      .toList(growable: false);
  final span = entry.t1 - entry.t0;
  if (span.isFinite) {
    return inside(<double>[
      for (final fraction in const <double>[0.13, 0.37, 0.61, 0.89])
        entry.t0 + fraction * span,
    ]);
  }
  if (entry.t0.isFinite) {
    final step = math.max(
      1.0,
      math.max(4.0 * guardAt(entry.t0), entry.t0.abs() * 1e-6),
    );
    return inside(<double>[
      for (final factor in const <double>[0.5, 1.5, 3.5, 7.5])
        entry.t0 + factor * step,
    ]);
  }
  if (entry.t1.isFinite) {
    final step = math.max(
      1.0,
      math.max(4.0 * guardAt(entry.t1), entry.t1.abs() * 1e-6),
    );
    return inside(<double>[
      for (final factor in const <double>[0.5, 1.5, 3.5, 7.5])
        entry.t1 - factor * step,
    ]);
  }
  return inside(const <double>[-3.5, -0.5, 0.5, 3.5]);
}

/// Up to [limit] instants drawn from actual reconstructed supports in [entry].
///
/// Fractional entry probes can all miss a point-supported or very narrow
/// gaussian. These candidates start at each gaussian's marginal peak and fall
/// back to the interior of its support/window intersection, so an empty/empty
/// comparison is never the only evidence collected for a populated entry.
/// Every row is considered before the cap is applied. Rows physically resident
/// in this entry take priority, then narrower intersections, so broad ancestor
/// content at the start of the assembled scene cannot crowd out a later point
/// gaussian owned by the entry. The retained set is always at most [limit].
List<double> seekVisibleProbeInstants(
  FourdgsChunkIndexEntry entry,
  FourdgsGaussianSet gaussians,
  double cutoff, {
  int limit = 4,
  int residentStart = 0,
  int residentCount = 0,
}) {
  if (limit <= 0) return const <double>[];
  final rows = _seekVisibleProbeRows(
    entry,
    gaussians,
    cutoff,
    residentStart: residentStart,
    residentCount: residentCount,
  );
  final times = <double>{};
  for (final row in rows) {
    times.add(row.time);
    if (times.length == limit) break;
  }
  return times.toList(growable: false);
}

/// Candidate instants together with the resident row each one proves.
///
/// The public helper caps distinct instants for callers that need only a
/// representative sample. The conformance proof consumes every row here, so
/// success for four equal-width residents cannot silently stand in for a fifth
/// resident that has no support inside its owning entry.
List<({double time, int row})> _seekVisibleProbeRows(
  FourdgsChunkIndexEntry entry,
  FourdgsGaussianSet gaussians,
  double cutoff, {
  required int residentStart,
  required int residentCount,
}) {
  final selected = <({double time, bool resident, double width, int row})>[];
  final k = supportK(cutoff);
  final residentEnd = residentStart + residentCount;

  int compare(
    ({double time, bool resident, double width, int row}) a,
    ({double time, bool resident, double width, int row}) b,
  ) {
    if (a.resident != b.resident) return a.resident ? -1 : 1;
    final byWidth = a.width.compareTo(b.width);
    return byWidth != 0 ? byWidth : a.row.compareTo(b.row);
  }

  final first = residentCount > 0 ? residentStart : 0;
  final end = residentCount > 0 ? residentEnd : gaussians.count;
  for (int i = first; i < end; i++) {
    final sigma = gaussians.sigmaT[i];
    final effectiveSigma = sigma.isFinite ? math.max(sigma, 1e-30) : sigma;
    final mu = gaussians.muT[i];
    final half = effectiveSigma.isFinite ? k * effectiveSigma : double.infinity;
    final lo = math.max(entry.t0, math.max(gaussians.winLo[i], mu - half));
    final hi = math.min(entry.t1, math.min(gaussians.winHi[i], mu + half));
    if (lo > hi) continue;

    double? candidate;
    if (mu.isFinite && lo <= mu && mu <= hi && entry.covers(mu)) {
      candidate = mu;
    } else if (lo.isFinite && hi.isFinite && lo < hi) {
      candidate = lo + (hi - lo) * 0.5;
    } else if (lo.isFinite) {
      candidate = lo + math.max(1.0, lo.abs() * 1e-6);
    } else if (hi.isFinite) {
      candidate = hi - math.max(1.0, hi.abs() * 1e-6);
    } else {
      candidate = 0.0;
    }

    final t = candidate;
    if (!t.isFinite || !entry.covers(t)) continue;
    if (!(gaussians.winLo[i] <= t && t < gaussians.winHi[i])) continue;
    final marginal =
        effectiveSigma.isFinite
            ? math.exp(-0.5 * math.pow((t - mu) / effectiveSigma, 2))
            : 1.0;
    if (marginal < cutoff) continue;
    final row = (
      time: t,
      resident: residentStart <= i && i < residentEnd,
      width: hi - lo,
      row: i,
    );
    selected.add(row);
  }
  selected.sort(compare);
  return <({double time, int row})>[
    for (final row in selected) (time: row.time, row: row.row),
  ];
}

/// Whether the reconstructed population is visible at any scene-clock instant.
///
/// Empty validity windows carry stored gaussians but no state. This is an
/// `O(count)` existence check with no allocation proportional to the scene.
bool hasAnyVisibleSupport(FourdgsGaussianSet gaussians, double cutoff) {
  final k = supportK(cutoff);
  for (int i = 0; i < gaussians.count; i++) {
    final windowLo = gaussians.winLo[i];
    final windowHi = gaussians.winHi[i];
    if (!(windowLo < windowHi)) continue;
    final storedSigma = gaussians.sigmaT[i];
    if (!storedSigma.isFinite) return true;
    final sigma = math.max(storedSigma, 1e-30);
    final mu = gaussians.muT[i];
    final supportLo = mu - k * sigma;
    final supportHi = mu + k * sigma;
    final lo = math.max(windowLo, supportLo);
    final hi = math.min(windowHi, supportHi);
    // Marginal support is closed; the validity window is [lo, hi). A point at
    // the window's lower edge is visible, while one at its upper edge is not.
    if (lo <= hi && lo < windowHi) return true;
  }
  return false;
}

/// Largest relative sigma movement caused by half a log-space quantization bin.
double seekGuardSigmaHalfRelative(double pitch) =>
    math.exp(0.5 * pitch.abs()) - 1.0;

/// Largest birth-time movement caused by half one reconstructed `mu_t` bin.
///
/// Malformed quantization is diagnosed by the decoder separately. This proof
/// still treats a negative finite pitch by magnitude so its boundary guard
/// cannot disappear before that diagnosis runs.
double seekGuardMuHalfWidth(
  int sigmaBin,
  double sigmaLogPitch,
  bool neverFades,
  double timePitch,
) => 0.5 * muStep(sigmaBin, sigmaLogPitch, neverFades, timePitch).abs();

/// Whether one decoded resident's complete visible support belongs to [entry].
///
/// [guard] is that row's own worst-case movement from `mu_t` and `sigma_t`
/// quantization, not a scene-wide tolerance. Proving containment directly is
/// both stronger and cheaper than hoping a finite set of probe instants lands
/// in every protruding sliver.
bool residentSupportWithinEntry(
  FourdgsChunkIndexEntry entry,
  double supportLo,
  double supportHi,
  double guard,
) => supportLo >= entry.t0 - guard && supportHi <= entry.t1 + guard;

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
Future<({int probes, int guardedVisibleCandidates})>
checkSeekReadsOnlyWhatItNeeds(
  CountingReadable source,
  FourdgsIndexedScene scene,
  FourdgsGaussianSet whole, {
  List<FourdgsDecodedChunk>? decodedChunks,
}) async {
  final index = scene.index;
  if (index.length < 2 || whole.count == 0) {
    return (probes: 0, guardedVisibleCandidates: 0);
  }
  final chunks =
      decodedChunks ??
      <FourdgsDecodedChunk>[
        for (final entry in index)
          await readFourdgsChunk(source, scene, entry, maxShBand: 0),
      ];
  if (chunks.length != index.length) {
    throw ConformanceFailure(
      'the seek proof received ${chunks.length} decoded chunks for '
      '${index.length} index entries',
    );
  }

  // How far from a boundary a gaussian whose support ends there may legitimately
  // sit on the far side of it. Per gaussian, out of the record's own pitches.
  //
  // This must be scoped to the boundary: a broad gaussian stored in an ancestor
  // chunk can have a large finite sigma while its support spans a child boundary
  // exactly. Its sigma error cannot move either support endpoint across that child
  // boundary, so using its slack globally would suppress every unrelated probe.
  final quantization = scene.quantization;
  final k = supportK(scene.header.cutoff);
  final sigmaLog = quantization.stepSigmaLog;
  final sigmaHalfRelative = seekGuardSigmaHalfRelative(sigmaLog);
  final guardEdges = <({double at, double guard})>[];
  final residentGuards = Float64List(whole.count);
  for (int i = 0; i < whole.count; i++) {
    final storedSigma = whole.sigmaT[i];
    if (!storedSigma.isFinite) continue;
    final sigma = math.max(storedSigma, 1e-30);
    final sigmaBin = seekGuardSigmaBin(sigma, sigmaLog);
    final muHalfWidth = seekGuardMuHalfWidth(
      sigmaBin,
      sigmaLog,
      false,
      quantization.stepTime,
    );
    final slack = muHalfWidth + k * sigma * sigmaHalfRelative;
    if (!slack.isFinite) continue;
    residentGuards[i] = slack;

    final rawLo = whole.muT[i] - k * sigma;
    final rawHi = whole.muT[i] + k * sigma;
    final lo = math.max(rawLo, whole.winLo[i]);
    final hi = math.min(rawHi, whole.winHi[i]);
    if (slack > 0.0) {
      if (rawLo > whole.winLo[i]) {
        guardEdges.add((at: lo, guard: slack));
      } else if (whole.winLo[i].isFinite && whole.winLo[i] - rawLo <= slack) {
        // The authored marginal edge may have been just inside the window before
        // quantization moved it across. Guard the clipped edge conservatively.
        guardEdges.add((at: whole.winLo[i], guard: slack));
      }
      if (rawHi < whole.winHi[i]) {
        guardEdges.add((at: hi, guard: slack));
      } else if (whole.winHi[i].isFinite && rawHi - whole.winHi[i] <= slack) {
        guardEdges.add((at: whole.winHi[i], guard: slack));
      }
    }
  }
  final boundaries =
      <double>{
          for (final entry in index) ...<double>[entry.t0, entry.t1],
        }.toList()
        ..sort();
  final boundaryGuards = _seekBoundaryGuards(boundaries, guardEdges);
  final guardZones = _seekGuardZones(boundaries, guardEdges);
  double guardAt(double boundary) => boundaryGuards[boundary] ?? 0.0;

  final probeEntries = seekProbeEntries(
    index,
    isKeyframeDelta: scene.header.temporalModel == 'keyframe-delta',
  );
  final rowStartByChunkOffset = <int, int>{};
  int rowStart = 0;
  for (final entry in index) {
    rowStartByChunkOffset[entry.chunkOffset] = rowStart;
    rowStart += entry.gaussianCount;
  }

  // Prove every resident's complete decoded support against its owning entry.
  // Candidate probes then remain a fixed small set per distinct interval;
  // broad populations with distinct peaks cannot turn this into a quadratic
  // sequence of full-scene reconstructions.
  final support = whole.support(cutoff: scene.header.cutoff);
  final candidates = <double>{};
  for (final entry in probeEntries) {
    final residentCount = entry.gaussianCount;
    final residentStart = rowStartByChunkOffset[entry.chunkOffset]!;
    final residentEnd = residentStart + residentCount;
    for (int row = residentStart; row < residentEnd; row++) {
      if (support.lo[row] <= support.hi[row] &&
          support.lo[row] < whole.winHi[row]) {
        final guard = residentGuards[row];
        if (!residentSupportWithinEntry(
          entry,
          support.lo[row],
          support.hi[row],
          guard,
        )) {
          throw ConformanceFailure(
            'resident gaussian row $row in the chunk at ${entry.chunkOffset} '
            'has decoded support [${support.lo[row]}, ${support.hi[row]}], '
            'outside [${entry.t0}, ${entry.t1}] beyond its $guard quantization guard',
          );
        }
      }
    }
    candidates.addAll(seekProbeInstants(entry, guardAt));
  }
  final orderedCandidates =
      candidates.where((t) => t.isFinite).toList()..sort();

  final entryStarts = <({double at, int index})>[
    for (int i = 0; i < index.length; i++) (at: index[i].t0, index: i),
  ]..sort((a, b) => a.at.compareTo(b.at));
  final entryEnds = <({double at, int index})>[
    for (int i = 0; i < index.length; i++) (at: index[i].t1, index: i),
  ]..sort((a, b) => a.at.compareTo(b.at));
  final activeEntries = <int>{};
  int nextEntryStart = 0;
  int nextEntryEnd = 0;

  final rowStarts = <({double at, int row})>[];
  final rowEnds = <({double at, bool inclusive, int row})>[];
  for (int row = 0; row < whole.count; row++) {
    final lo = support.lo[row];
    final hi = support.hi[row];
    if (lo > hi || !(lo < whole.winHi[row])) continue;
    rowStarts.add((at: lo, row: row));
    rowEnds.add((at: hi, inclusive: hi < whole.winHi[row], row: row));
  }
  rowStarts.sort((a, b) => a.at.compareTo(b.at));
  rowEnds.sort((a, b) => a.at.compareTo(b.at));
  final activeRows = <int>{};
  int nextRowStart = 0;
  int nextRowEnd = 0;

  int probed = 0;
  int guardedVisibleCandidates = 0;
  for (final t in orderedCandidates) {
    while (nextEntryStart < entryStarts.length &&
        entryStarts[nextEntryStart].at <= t) {
      activeEntries.add(entryStarts[nextEntryStart++].index);
    }
    while (nextEntryEnd < entryEnds.length && entryEnds[nextEntryEnd].at <= t) {
      activeEntries.remove(entryEnds[nextEntryEnd++].index);
    }
    while (nextRowStart < rowStarts.length && rowStarts[nextRowStart].at <= t) {
      activeRows.add(rowStarts[nextRowStart++].row);
    }
    while (nextRowEnd < rowEnds.length &&
        (rowEnds[nextRowEnd].at < t ||
            (rowEnds[nextRowEnd].at == t && !rowEnds[nextRowEnd].inclusive))) {
      activeRows.remove(rowEnds[nextRowEnd++].row);
    }

    final fromWhole = _visibleKeysForRows(
      whole,
      activeRows,
      t,
      scene.header.cutoff,
    );
    if (_probeInGuardZones(t, guardZones)) {
      if (fromWhole.isNotEmpty) {
        guardedVisibleCandidates++;
      }
      continue;
    }

    final selectedIndices = activeEntries;
    if (selectedIndices.isEmpty) {
      throw ConformanceFailure('no chunk index entry covers probe t=$t');
    }
    final selectedChunks = <FourdgsDecodedChunk>[
      for (final i in selectedIndices) chunks[i],
    ];
    final fromSeek = _visibleKeys(
      assembleGaussians(selectedChunks, 0),
      t,
      scene.header.cutoff,
    );
    // Empty on both sides proves only that this instant missed the content,
    // not that the index filed that content in the right interval.
    if (fromWhole.isEmpty && fromSeek.isEmpty) continue;
    if (fromSeek.length != fromWhole.length ||
        !_sameKeys(fromSeek, fromWhole)) {
      throw ConformanceFailure(
        'a seek at t=$t read ${selectedIndices.length} of ${index.length} chunks and '
        'found ${fromSeek.length} visible gaussians; the whole scene has '
        '${fromWhole.length} visible there',
      );
    }
    probed++;
  }
  return (probes: probed, guardedVisibleCandidates: guardedVisibleCandidates);
}

Map<double, double> _seekBoundaryGuards(
  List<double> sortedBoundaries,
  List<({double at, double guard})> guardEdges,
) {
  final starts = <({double at, double guard})>[
    for (final edge in guardEdges)
      if (edge.at.isFinite && edge.guard.isFinite && edge.guard >= 0.0)
        (at: edge.at - edge.guard, guard: edge.guard),
  ]..sort((a, b) => a.at.compareTo(b.at));
  final ends = <({double at, double guard})>[
    for (final edge in guardEdges)
      if (edge.at.isFinite && edge.guard.isFinite && edge.guard >= 0.0)
        (at: edge.at + edge.guard, guard: edge.guard),
  ]..sort((a, b) => a.at.compareTo(b.at));
  final active = SplayTreeMap<double, int>();
  final result = <double, double>{};
  int nextStart = 0;
  int nextEnd = 0;
  for (final boundary in sortedBoundaries) {
    while (nextStart < starts.length && starts[nextStart].at <= boundary) {
      final guard = starts[nextStart++].guard;
      active[guard] = (active[guard] ?? 0) + 1;
    }
    while (nextEnd < ends.length && ends[nextEnd].at < boundary) {
      final guard = ends[nextEnd++].guard;
      final count = active[guard]!;
      if (count == 1) {
        active.remove(guard);
      } else {
        active[guard] = count - 1;
      }
    }
    result[boundary] = active.lastKey() ?? 0.0;
  }
  return result;
}

List<({double lo, double hi})> _seekGuardZones(
  List<double> sortedBoundaries,
  List<({double at, double guard})> guardEdges,
) {
  final zones = <({double lo, double hi})>[];
  for (final edge in guardEdges) {
    if (!edge.at.isFinite || !edge.guard.isFinite || edge.guard < 0.0) continue;
    final wantedLo = edge.at - edge.guard;
    final wantedHi = edge.at + edge.guard;
    int low = 0;
    int high = sortedBoundaries.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (sortedBoundaries[middle] < wantedLo) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final first = low;
    low = first;
    high = sortedBoundaries.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (sortedBoundaries[middle] <= wantedHi) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final last = low - 1;
    if (first <= last && first < sortedBoundaries.length) {
      zones.add((
        lo: sortedBoundaries[first] - edge.guard,
        hi: sortedBoundaries[last] + edge.guard,
      ));
    }
  }
  zones.sort((a, b) => a.lo.compareTo(b.lo));
  final merged = <({double lo, double hi})>[];
  for (final zone in zones) {
    if (merged.isEmpty || zone.lo > merged.last.hi) {
      merged.add(zone);
    } else if (zone.hi > merged.last.hi) {
      merged[merged.length - 1] = (lo: merged.last.lo, hi: zone.hi);
    }
  }
  return merged;
}

({double lo, double hi})? _guardZoneContaining(
  double t,
  List<({double lo, double hi})> zones,
) {
  int low = 0;
  int high = zones.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (zones[middle].lo <= t) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (low == 0) return null;
  final zone = zones[low - 1];
  return t <= zone.hi ? zone : null;
}

bool _probeInGuardZones(double t, List<({double lo, double hi})> zones) =>
    _guardZoneContaining(t, zones) != null;

/// Whether [t] lies inside any quantization guard around any chunk boundary.
///
/// A wide guard attached to an earlier boundary can reach past several narrow
/// boundaries, so checking only [t]'s immediate neighbours is not sufficient.
/// For each reconstructed support edge, this asks by binary search whether a
/// boundary lies within both the edge's guard and [t]'s guard from that same
/// boundary. Work is bounded by the decoded gaussian population and the small,
/// fixed probe count rather than by every boundary/gaussian pair.
bool seekProbeNearAnyBoundary(
  double t,
  List<double> sortedBoundaries,
  List<({double at, double guard})> guardEdges,
) {
  for (final edge in guardEdges) {
    final double lo = math.max(edge.at, t) - edge.guard;
    final double hi = math.min(edge.at, t) + edge.guard;
    if (lo > hi) continue;
    int low = 0;
    int high = sortedBoundaries.length;
    while (low < high) {
      final int middle = low + ((high - low) >> 1);
      if (sortedBoundaries[middle] < lo) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low < sortedBoundaries.length && sortedBoundaries[low] <= hi) {
      return true;
    }
  }
  return false;
}

List<String> _visibleKeysForRows(
  FourdgsGaussianSet g,
  Iterable<int> rows,
  double t,
  double cutoff,
) {
  final keys = <String>[];
  for (final i in rows) {
    if (!(g.winLo[i] <= t && t < g.winHi[i])) continue;
    final sigma = g.sigmaT[i];
    final marginal =
        sigma.isFinite
            ? math.exp(
              -0.5 * math.pow((t - g.muT[i]) / math.max(sigma, 1e-30), 2),
            )
            : 1.0;
    if (marginal < cutoff) continue;
    final dt = t - g.muT[i];
    keys.add(
      '${g.positions[i * 3] + g.motions[i * 3] * dt},'
      '${g.positions[i * 3 + 1] + g.motions[i * 3 + 1] * dt},'
      '${g.positions[i * 3 + 2] + g.motions[i * 3 + 2] * dt},'
      '${g.colors[i * 4 + 3] * marginal}',
    );
  }
  keys.sort();
  return keys;
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
