// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: encode `keyframe-delta`.
///
/// Writes one file per variant with the Dart sequence encoder. Four of them are
/// the corpus's own sequences, rebuilt here from the same numbers
/// `tests/conformance/generate.py` builds them from, so the gate around this
/// (`dart/encode-roundtrip.sh`) can diff the states JSON of a Dart-written file
/// against the expectation a *Python*-written file produced. Two encoders that
/// quantize onto the same grids and split the same samples the same way reach
/// the same reconstruction at every instant, and that expectation is on disk
/// already — no second corpus, no self-agreement.
///
/// The remaining variants exercise what the corpus does not: a sequence with
/// more than one validity window, and a population that never fades.
///
/// Usage: encode_keyframe_delta <out-dir>
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/writer.dart';

/// Seconds and sample count of the synthetic sequences, matching the generator.
const int kdSteps = 8;
const double kdDuration = 8.0;

/// A population at one instant: finite sigma, one shared full-duration window.
///
/// Mirrors `_kd_gaussians` in the corpus generator exactly — identity is carried
/// by the sample, sigma is finite so the per-gaussian velocity and birth-time
/// grids stay uniform, and the validity window is the whole clip.
FourdgsGaussianSet population(
  List<List<double>> positions, {
  double sigma = 100.0,
  double winLo = 0.0,
  double winHi = kdDuration,
  List<double>? winLoPer,
  List<double>? winHiPer,
  List<List<double>>? motions,
  List<double>? muT,
  List<List<double>>? rotationsPer,
}) {
  final n = positions.length;
  final pos = Float32List(n * 3);
  final scales = Float32List(n * 3);
  final rotations = Float32List(n * 4);
  final colors = Float32List(n * 4);
  final velocity = Float32List(n * 3);
  final lo = Float32List(n);
  final hi = Float32List(n);
  for (int i = 0; i < n; i++) {
    for (int axis = 0; axis < 3; axis++) {
      pos[i * 3 + axis] = positions[i][axis];
      scales[i * 3 + axis] = 0.05;
      velocity[i * 3 + axis] = motions == null ? 0.0 : motions[i][axis];
    }
    if (rotationsPer == null) {
      rotations[i * 4 + 3] = 1.0;
    } else {
      for (int c = 0; c < 4; c++) {
        rotations[i * 4 + c] = rotationsPer[i][c];
      }
    }
    colors[i * 4] = 0.6;
    colors[i * 4 + 1] = 0.4;
    colors[i * 4 + 2] = 0.2;
    colors[i * 4 + 3] = 0.9;
    lo[i] = winLoPer == null ? winLo : winLoPer[i];
    hi[i] = winHiPer == null ? winHi : winHiPer[i];
  }
  final mu = Float32List(n);
  if (muT != null) {
    for (int i = 0; i < n; i++) {
      mu[i] = muT[i];
    }
  }
  return FourdgsGaussianSet(
    positions: pos,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: velocity,
    muT: mu,
    sigmaT: Float32List(n)..fillRange(0, n, sigma),
    winLo: lo,
    winHi: hi,
  );
}

double sampleTime(int i) => i * (kdDuration / kdSteps);

/// A fixed population of four gaussians that drifts. No births or deaths, so
/// every delta is a pure update — the plain keyframe-delta shape.
List<FourdgsSample> drift() => <FourdgsSample>[
  for (int i = 0; i < kdSteps; i++)
    FourdgsSample(
      t0: sampleTime(i),
      ids: const <int>[0, 1, 2, 3],
      gaussians: population(<List<double>>[
        <double>[i * 0.1, 0.0, 0.0],
        <double>[1.0, i * 0.05, 0.0],
        <double>[0.0, 1.0, i * 0.03],
        <double>[1.0, 1.0, 0.0],
      ]),
    ),
];

/// A drifting population with one birth (id 4) and one death (id 2), so deltas
/// carry birth and death groups and not only updates.
List<FourdgsSample> churn() {
  final samples = <FourdgsSample>[];
  for (int i = 0; i < kdSteps; i++) {
    final ids = <int>[0, 1, 2, 3];
    final base = <List<double>>[
      <double>[i * 0.1, 0.0, 0.0],
      <double>[1.0, i * 0.05, 0.0],
      <double>[0.0, 1.0, 0.0],
      <double>[1.0, 1.0, 0.0],
    ];
    if (i >= 2) {
      ids.add(4);
      base.add(<double>[2.0, 2.0, i * 0.02]);
    }
    if (i >= 5 && ids.contains(2)) {
      final keep = <int>[
        for (int k = 0; k < ids.length; k++)
          if (ids[k] != 2) k,
      ];
      final keptIds = <int>[for (final k in keep) ids[k]];
      final keptBase = <List<double>>[for (final k in keep) base[k]];
      ids
        ..clear()
        ..addAll(keptIds);
      base
        ..clear()
        ..addAll(keptBase);
    }
    samples.add(
      FourdgsSample(t0: sampleTime(i), ids: ids, gaussians: population(base)),
    );
  }
  return samples;
}

/// Two validity windows, one closing halfway through the clip.
///
/// The corpus has nothing like it: every keyframe-delta variant there carries a
/// single full-duration window, so no reader's validity-window handling is
/// exercised on this path. Here half the population goes absent at t = 4.
List<FourdgsSample> twoWindows() => <FourdgsSample>[
  for (int i = 0; i < kdSteps; i++)
    FourdgsSample(
      t0: sampleTime(i),
      ids: const <int>[0, 1, 2, 3],
      gaussians: population(
        <List<double>>[
          <double>[i * 0.1, 0.0, 0.0],
          <double>[1.0, i * 0.05, 0.0],
          <double>[0.0, 1.0, i * 0.03],
          <double>[1.0, 1.0, 0.0],
        ],
        winLoPer: const <double>[0.0, 0.0, 4.0, 4.0],
        winHiPer: const <double>[4.0, 4.0, 8.0, 8.0],
      ),
    ),
];

/// A population that never fades: `sigma_t` is `+inf`, so `flags` carries the
/// never-fades bit and the velocity grid comes from the window length instead of
/// the sigma. Both reference sequence writers refuse this input outright; both
/// reference *readers* handle it, because the `gaussian-birth` path has always
/// produced it.
List<FourdgsSample> neverFades() => <FourdgsSample>[
  for (int i = 0; i < kdSteps; i++)
    FourdgsSample(
      t0: sampleTime(i),
      ids: const <int>[0, 1, 2],
      gaussians: population(<List<double>>[
        <double>[i * 0.1, 0.0, 0.0],
        <double>[1.0, i * 0.05, 0.0],
        <double>[0.0, 1.0, i * 0.03],
      ], sigma: double.infinity),
    ),
];

/// A population that moves, fades on its own clock, and turns as it goes.
///
/// The corpus sequences leave `motions`, `mu_t` and the quaternion at their
/// defaults — zero velocity, zero birth time, identity rotation — so three of
/// the eleven attributes are never actually exercised on the sequence path, and
/// two of them are the ones that ride pitches a decoder recomputes per gaussian
/// (spec §6.3). Everything here is nonzero, and the turn is 25 degrees a sample
/// so the largest quaternion component stops being `w` partway through: either
/// side of that crossing the three stored bins mean different components, which
/// is the whole reason an update restates a rotation instead of differencing it
/// (spec §11.5). Nothing in the corpus reaches that.
List<FourdgsSample> moving() => <FourdgsSample>[
  for (int i = 0; i < kdSteps; i++)
    FourdgsSample(
      t0: sampleTime(i),
      ids: const <int>[7, 8, 9],
      gaussians: population(
        <List<double>>[
          <double>[i * 0.1, 0.0, 0.0],
          <double>[1.0, i * 0.05, 0.25],
          <double>[0.0, 1.0, i * 0.03],
        ],
        sigma: 1.5,
        motions: <List<double>>[
          <double>[0.35, -0.2, 0.05],
          <double>[-0.4, 0.1, 0.0],
          <double>[0.0, 0.0, 0.6 + i * 0.01],
        ],
        muT: <double>[1.0, 3.5, 6.25],
        rotationsPer: <List<double>>[
          _turn(i * 25.0, 2),
          _turn(i * 25.0, 1),
          _turn(180.0 - i * 25.0, 0),
        ],
      ),
    ),
];

/// A unit quaternion turning [degrees] about one axis.
List<double> _turn(double degrees, int axis) {
  final half = degrees * math.pi / 360.0;
  final q = <double>[0.0, 0.0, 0.0, math.cos(half)];
  q[axis] = math.sin(half);
  return q;
}

class Variant {
  const Variant(this.name, this.samples, this.options);

  final String name;
  final List<FourdgsSample> Function() samples;
  final FourdgsKeyframeDeltaOptions options;
}

/// The four corpus sequences under their corpus names, then the two the corpus
/// does not carry. A name that matches a corpus variant is a promise the gate
/// checks: the states JSON must equal the expectation beside it.
const List<Variant> variants = <Variant>[
  Variant(
    'KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics',
    churn,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 1),
  ),
  Variant(
    'KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics',
    drift,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
  ),
  Variant(
    'KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics',
    churn,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
  ),
  Variant(
    'KeyframeDeltaModesMixed-UseChunkIndex-UseCrc-UseStatistics',
    churn,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4, deltaMode: deltaModeKeyframe),
  ),
  Variant(
    'DartTwoWindows-UseChunkIndex-UseCrc-UseStatistics',
    twoWindows,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
  ),
  Variant(
    'DartNeverFades-UseChunkIndex-UseCrc-UseStatistics',
    neverFades,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
  ),
  Variant(
    'DartMoving-UseChunkIndex-UseCrc-UseStatistics',
    moving,
    FourdgsKeyframeDeltaOptions(keyframeEvery: 4),
  ),
];

String write(Variant variant, String directory) {
  final samples = variant.samples();
  final bytes = writeKeyframeDeltaBytes(
    samples,
    kdDuration,
    options: variant.options,
  );

  // Two encodes of one sequence must be the same bytes. An encoder that iterates
  // a map, or sorts unstably, passes every value-based check and still produces
  // a file that differs between runs.
  final again = writeKeyframeDeltaBytes(
    variant.samples(),
    kdDuration,
    options: variant.options,
  );
  if (bytes.length != again.length) {
    throw StateError('two encodes of ${variant.name} differ in length');
  }
  for (int i = 0; i < bytes.length; i++) {
    if (bytes[i] != again[i]) {
      throw StateError('two encodes of ${variant.name} differ at byte $i');
    }
  }

  File('$directory/${variant.name}.4dgs').writeAsBytesSync(bytes);
  final sequence = decodeKeyframeDeltaStreamed(bytes);
  final keyframes = sequence.chunks.where((c) => c.kind == 0).length;
  return '${samples.length} samples, $keyframes keyframes, '
      '${sequence.chunks.length - keyframes} deltas, ${bytes.length} bytes, '
      'deterministic, verified';
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: encode_keyframe_delta <out-dir>');
    exit(2);
  }
  try {
    Directory(args.single).createSync(recursive: true);
    for (final variant in variants) {
      stdout.writeln('${variant.name}\t${write(variant, args.single)}');
    }
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
