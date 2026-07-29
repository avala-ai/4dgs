// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Dequantization: uniform grids, and the two pitches that vary per gaussian.
///
/// Every attribute lands on a uniform grid whose pitch is exactly twice its
/// declared bound, so `|decoded - original| <= bound` holds by construction.
/// After decompression the pipeline is integer-only, which is what makes
/// decoders in different languages produce identical results.
///
/// Two attributes get a pitch that varies per gaussian, derived from a value
/// the decoder has already read, so there is no side channel. Both exist
/// because a fixed pitch spends its budget in the wrong place:
///
/// * **velocity** — an error only becomes visible as displacement over the span
///   a gaussian is on screen, so a short-lived gaussian tolerates a much
///   coarser velocity;
/// * **birth time** — the temporal term reads `(t - mu) / sigma`, never `mu`
///   alone, so precision has to be a fraction of the gaussian's own sigma. A
///   gaussian with a 1 ms sigma and a 2 ms birth-time error is not slightly
///   wrong, it is on when it should be off.
library;

import 'dart:math' as math;

import 'exceptions.dart';
import 'records.dart';

/// The Header's default marginal visibility threshold.
const double fourdgsDefaultCutoff = 0.05;

/// `marginal >= cutoff` <=> `|t - mu| <= K * sigma`, for the default cutoff.
final double kSupport = supportK(fourdgsDefaultCutoff);

/// Half-width of a gaussian's visible support, in sigmas, for a file's own
/// cutoff (spec §6.3).
///
/// Reading this from the Header rather than assuming the default is not
/// cosmetic: it feeds the velocity precision class, so a decoder that assumes
/// 0.05 decodes different velocities than the encoder wrote for any file that
/// declares something else — and nothing in the file tells it that it did. The
/// corpus's `CustomCutoff` variant is exactly that file, and the error it
/// catches is a factor of two on a minority of gaussians.
///
/// A threshold outside `(0, 1]` is not a threshold. It comes from a corrupt
/// header, and it is refused here rather than allowed to become a domain error
/// inside a logarithm.
double supportK(double cutoff) {
  if (cutoff.isNaN || !(cutoff > 0.0 && cutoff <= 1.0)) {
    throw FourdgsMalformedFile(
      "the Header's cutoff is $cutoff; a marginal threshold must be in (0, 1]",
    );
  }
  return math.sqrt(-2.0 * math.log(cutoff));
}

// Velocity precision classes.
const double _lifeRef = 0.5;
const int _lifeMinClass = -4;
const int _lifeMaxClass = 2;
const double _lifeHalfMin = 0.02;
const double _lifeHalfMax = 2.0;

// Birth-time precision classes.
const double _muRel = 0.05;
const int _muMinClass = -10;

/// Grid pitches, read verbatim from the Quantization record so a decoder never
/// re-derives a float and drifts from the encoder.
class FourdgsSteps {
  const FourdgsSteps({
    required this.pos,
    required this.scaleLog,
    required this.rot,
    required this.rgb,
    required this.alpha,
    required this.motion,
    required this.time,
    required this.sigmaLog,
    required this.sh,
  });

  factory FourdgsSteps.of(FourdgsQuantization q) => FourdgsSteps(
    pos: q.stepPos,
    scaleLog: q.stepScaleLog,
    rot: q.stepRot,
    rgb: q.stepRgb,
    alpha: q.stepAlpha,
    motion: q.stepMotion,
    time: q.stepTime,
    sigmaLog: q.stepSigmaLog,
    sh: q.stepSh,
  );

  final double pos;
  final double scaleLog;
  final double rot;
  final double rgb;
  final double alpha;
  final double motion;
  final double time;
  final double sigmaLog;
  final int sh;
}

double _log2(double x) => math.log(x) / math.ln2;

/// Velocity precision class, from the sigma bin a decoder has already read.
///
/// [windowLength] is the length of *this gaussian's own* validity window, and
/// it is a required argument on purpose. A never-fading gaussian's velocity
/// precision is derived from it, so a decoder that inferred a window length
/// instead of reading the table decodes velocities the encoder never wrote — on
/// a minority of gaussians, with nothing raised anywhere. Making it
/// unrepresentable to omit is cheaper than remembering.
///
/// [k] comes from the file's own cutoff via [supportK]; it defaults to the
/// default cutoff's value so a caller with no header still gets the common case
/// right.
///
/// `ceil`, not `round`: the class's nominal lifetime has to be an upper bound
/// on the real one, or the displacement guarantee fails by up to sqrt(2).
int lifeClass(
  int sigmaBin,
  double sigmaLogStep,
  bool neverFades,
  double windowLength, {
  double? k,
}) {
  final sigma = math.exp(sigmaBin * sigmaLogStep);
  double half = neverFades ? windowLength : (k ?? kSupport) * sigma;
  half = half.clamp(_lifeHalfMin, _lifeHalfMax);
  return _log2(half / _lifeRef).ceil().clamp(_lifeMinClass, _lifeMaxClass);
}

/// The velocity pitch a [lifeClass] implies.
double motionStep(int lifeClassValue, double stepRef) =>
    stepRef * math.pow(2.0, -lifeClassValue).toDouble();

/// Birth-time pitch: [stepRef], refined by powers of two until it is at most
/// 5 % of the gaussian's own sigma.
double muStep(
  int sigmaBin,
  double sigmaLogStep,
  bool neverFades,
  double stepRef,
) {
  final sigma = math.exp(sigmaBin * sigmaLogStep);
  final target = neverFades ? stepRef : math.min(stepRef, _muRel * sigma);
  final cls = _log2(target / stepRef).floor().clamp(_muMinClass, 0);
  return stepRef * math.pow(2.0, cls).toDouble();
}

/// Inverts the reversible colour transform, which stores `(g, r - g, b - g)`.
///
/// Exact in the integer domain, so it changes the compressed size and never the
/// error bound.
void rctInverse(int c0, int c1, int c2, List<int> out) {
  out[1] = c0;
  out[0] = c1 + c0;
  out[2] = c2 + c0;
}

/// Smallest-three quaternion reconstruction, writing xyzw into [dst] at [at].
///
/// The largest-magnitude component was omitted and its sign canonicalized
/// positive — `q` and `-q` are the same rotation — which is what lets it be
/// recovered as a square root. The three stored components sit in the remaining
/// slots in ascending index order.
///
/// The whole reconstruction runs in double precision and is narrowed once, on
/// the way out. Rounding the components into [dst] first and normalizing what
/// came back would divide by a norm computed from already-narrowed numbers, and
/// the reference implementation does not.
void dequantizeRotation(
  int largest,
  int b0,
  int b1,
  int b2,
  double step,
  List<double> dst,
  int at,
) {
  final r0 = (b0 * step).clamp(-1.0, 1.0);
  final r1 = (b1 * step).clamp(-1.0, 1.0);
  final r2 = (b2 * step).clamp(-1.0, 1.0);
  final big = math.sqrt(math.max(1.0 - (r0 * r0 + r1 * r1 + r2 * r2), 0.0));

  double q0 = 0, q1 = 0, q2 = 0, q3 = 0;
  int k = 0;
  for (int slot = 0; slot < 4; slot++) {
    final double v;
    if (slot == largest) {
      v = big;
    } else {
      v = k == 0 ? r0 : (k == 1 ? r1 : r2);
      k++;
    }
    switch (slot) {
      case 0:
        q0 = v;
      case 1:
        q1 = v;
      case 2:
        q2 = v;
      default:
        q3 = v;
    }
  }

  // A zero quaternion cannot be normalized; the reference leaves it as it is
  // rather than inventing an identity rotation, so this does too.
  final n = math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3);
  final norm = n > 0 ? n : 1.0;
  dst[at] = q0 / norm;
  dst[at + 1] = q1 / norm;
  dst[at + 2] = q2 / norm;
  dst[at + 3] = q3 / norm;
}
