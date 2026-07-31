// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The in-memory scene: gaussians on one clock, plus what travels with them.
///
/// There are no frames here and none anywhere else in this decoder. Each
/// gaussian carries its own temporal description, so the number alive at any
/// instant follows from the data rather than from a frame count someone had to
/// choose.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A legacy, non-spatial track.
///
/// Kept as an API compatibility view for version-1 files written before native
/// spatial sources were introduced. New code uses [FourdgsAudioSource].
class FourdgsAudioTrack {
  const FourdgsAudioTrack({
    required this.codec,
    required this.data,
    this.startSec = 0.0,
  });

  final String codec;
  final Uint8List data;

  /// Scene time at which the track's first sample plays.
  final double startSec;

  /// The media type a consumer should hand a player, for the codecs this
  /// version's registry defines.
  String get mediaType {
    switch (codec) {
      case 'wav':
        return 'audio/wav';
      case 'opus':
        return 'audio/ogg';
      default:
        return 'application/octet-stream';
    }
  }
}

/// One source pose on the scene clock.
class FourdgsAudioSourceKeyframe {
  const FourdgsAudioSourceKeyframe({
    required this.time,
    required this.position,
    this.rotation = const <double>[0.0, 0.0, 0.0, 1.0],
  });

  final double time;
  final List<double> position;

  /// Unit quaternion, xyzw.
  final List<double> rotation;
}

/// The source-local timing and pose reconstructed at one scene instant.
///
/// This is where audio decoding ends. Panning, HRTF, attenuation, occlusion and
/// mixing combine this state with a player-owned listener pose and therefore
/// belong to the player.
class FourdgsAudioSourceState {
  const FourdgsAudioSourceState({
    required this.active,
    required this.localTime,
    required this.position,
    required this.rotation,
    required this.gain,
  });

  final bool active;
  final double localTime;
  final List<double> position;
  final List<double> rotation;
  final double gain;
}

/// A small source descriptor, independent of its encoded payload.
///
/// Indexed readers return these without transferring audio bytes. Pose
/// keyframes use the scene clock, while [startSec] and [durationSec] determine
/// playback on the source-local clock.
class FourdgsAudioSourceDescriptor {
  const FourdgsAudioSourceDescriptor({
    required this.sourceId,
    required this.name,
    required this.codec,
    required this.channelLayout,
    required this.dataLength,
    required this.startSec,
    required this.durationSec,
    required this.gain,
    required this.spatial,
    required this.loop,
    required this.position,
    required this.rotation,
    required this.keyframes,
    required this.interpolation,
  });

  final int sourceId;
  final String name;
  final String codec;
  final String channelLayout;
  final int dataLength;
  final double startSec;
  final double durationSec;
  final double gain;

  /// False for a global/non-spatial source. Spatial point sources are mono.
  final bool spatial;

  final bool loop;
  final List<double> position;

  /// Unit quaternion, xyzw.
  final List<double> rotation;

  final List<FourdgsAudioSourceKeyframe> keyframes;

  /// `linear` or `step`.
  final String interpolation;

  /// Reconstruct source timing and pose at scene time [t].
  FourdgsAudioSourceState stateAt(double t) {
    final active = t >= startSec && (loop || t - startSec < durationSec);
    final localTime =
        loop && durationSec > 0.0
            ? _loopingLocalTime(t, startSec, durationSec)
            : math.min(math.max(0.0, t - startSec), math.max(0.0, durationSec));
    final pose = _audioPoseAt(this, t);
    return FourdgsAudioSourceState(
      active: active,
      localTime: localTime,
      position: pose.$1,
      rotation: pose.$2,
      gain: gain,
    );
  }
}

double _loopingLocalTime(double t, double startSec, double durationSec) {
  if (t <= startSec) return 0.0;
  var timeRemainder = t.remainder(durationSec);
  if (timeRemainder < 0.0) timeRemainder += durationSec;
  var startRemainder = startSec.remainder(durationSec);
  if (startRemainder < 0.0) startRemainder += durationSec;
  final difference = timeRemainder - startRemainder;
  return difference < 0.0 ? difference + durationSec : difference;
}

/// One independently timed, optionally spatial audio source.
class FourdgsAudioSource extends FourdgsAudioSourceDescriptor {
  FourdgsAudioSource({
    required super.sourceId,
    required super.name,
    required super.codec,
    required super.channelLayout,
    required super.dataLength,
    required super.startSec,
    required super.durationSec,
    required super.gain,
    required super.spatial,
    required super.loop,
    required super.position,
    required super.rotation,
    required super.keyframes,
    required super.interpolation,
    required this.data,
  });

  /// The encoded codec payload, verbatim.
  final Uint8List data;

  /// The media type a consumer should hand a codec implementation.
  String get mediaType {
    switch (codec) {
      case 'wav':
        return 'audio/wav';
      case 'opus':
        return 'audio/ogg';
      default:
        return 'application/octet-stream';
    }
  }
}

(List<double>, List<double>) _audioPoseAt(
  FourdgsAudioSourceDescriptor source,
  double t,
) {
  final frames = source.keyframes;
  if (frames.isEmpty) {
    return (source.position, _normalizedQuaternion(source.rotation));
  }
  if (t <= frames.first.time) {
    return (
      frames.first.position,
      _normalizedQuaternion(frames.first.rotation),
    );
  }
  if (t >= frames.last.time) {
    return (frames.last.position, _normalizedQuaternion(frames.last.rotation));
  }

  int high = 1;
  while (frames[high].time <= t) {
    high++;
  }
  final a = frames[high - 1];
  final b = frames[high];
  if (source.interpolation == 'step') {
    return (a.position, _normalizedQuaternion(a.rotation));
  }
  final u = _interpolationFraction(t, a.time, b.time);
  return (
    <double>[
      for (int i = 0; i < 3; i++) _finiteLerp(a.position[i], b.position[i], u),
    ],
    _slerp(a.rotation, b.rotation, u),
  );
}

double _interpolationFraction(double t, double a, double b) {
  final span = b - a;
  if (span.isFinite) return (t - a) / span;
  final scale = math.max(a.abs(), b.abs());
  return (t / scale - a / scale) / (b / scale - a / scale);
}

double _finiteLerp(double a, double b, double u) {
  if ((a <= 0.0 && b >= 0.0) || (a >= 0.0 && b <= 0.0)) {
    return a * (1.0 - u) + b * u;
  }
  return a + (b - a) * u;
}

List<double> _normalizedQuaternion(List<double> value) {
  // Divide out the largest component before squaring so a finite but very large component
  // cannot overflow to `inf` — which would make the norm `inf`, trip the guard below, and
  // collapse a valid extreme orientation to the identity instead of the unit quaternion in
  // its own direction. `dart:math` has no `hypot`, so this scales by hand.
  final scale = value.fold<double>(0.0, (m, c) => math.max(m, c.abs()));
  if (!scale.isFinite || scale == 0.0) {
    return <double>[0.0, 0.0, 0.0, 1.0];
  }
  final scaled = <double>[for (final component in value) component / scale];
  final length = math.sqrt(
    scaled.fold<double>(0.0, (sum, component) => sum + component * component),
  );
  if (!length.isFinite || length == 0.0) {
    return <double>[0.0, 0.0, 0.0, 1.0];
  }
  return <double>[for (final component in scaled) component / length];
}

List<double> _slerp(List<double> a, List<double> b, double u) {
  final qa = _normalizedQuaternion(a);
  var qb = _normalizedQuaternion(b);
  var dot = 0.0;
  for (int i = 0; i < 4; i++) {
    dot += qa[i] * qb[i];
  }
  if (dot < 0.0) {
    qb = <double>[for (final component in qb) -component];
    dot = -dot;
  }
  dot = dot.clamp(-1.0, 1.0).toDouble();
  if (dot > 0.9995) {
    return _normalizedQuaternion(<double>[
      for (int i = 0; i < 4; i++) qa[i] + (qb[i] - qa[i]) * u,
    ]);
  }
  final theta = math.acos(dot);
  final sinTheta = math.sin(theta);
  final wa = math.sin((1.0 - u) * theta) / sinTheta;
  final wb = math.sin(u * theta) / sinTheta;
  return _normalizedQuaternion(<double>[
    for (int i = 0; i < 4; i++) wa * qa[i] + wb * qb[i],
  ]);
}

/// A default viewpoint and an optional suggested path. Advisory in the format
/// and advisory here: nothing in decoding depends on it.
class FourdgsCameraTrajectory {
  const FourdgsCameraTrajectory({
    required this.fovYDeg,
    required this.position,
    required this.target,
    this.times = const <double>[],
    this.positions = const <List<double>>[],
    this.targets = const <List<double>>[],
    this.interpolation = 'spline',
    this.loop = true,
  });

  final double fovYDeg;
  final List<double> position;
  final List<double> target;
  final List<double> times;
  final List<List<double>> positions;
  final List<List<double>> targets;
  final String interpolation;
  final bool loop;
}

/// Reconstructed state at one instant: which gaussians are visible, where their
/// centres are, and what their opacity is.
///
/// This is where decoding ends. What happens to these numbers afterwards is not
/// this decoder's concern.
class FourdgsState {
  const FourdgsState({
    required this.indices,
    required this.centers,
    required this.orientations,
    required this.opacity,
    this.objectId,
  });

  /// Indices into the [FourdgsGaussianSet] the state was computed from.
  final Uint32List indices;

  /// `indices.length * 3` centres, advected to the requested time.
  final Float64List centers;

  /// `indices.length * 4` xyzw orientations. The rest orientation until an
  /// object track composes onto it: the temporal model does not turn a
  /// gaussian, only the object layer does.
  final Float64List orientations;

  /// `indices.length` opacities, the stored alpha scaled by the marginal.
  final Float64List opacity;

  /// `indices.length` object ids, or null when the scene carries no
  /// membership.
  final Int32List? objectId;

  int get count => indices.length;
}

/// Every gaussian in a scene, structure-of-arrays.
///
/// [sigmaT] may contain infinity, meaning the gaussian never fades inside its
/// window. That is a value, not a sentinel to be pattern-matched: it survives
/// encode and decode as infinity, and this reader exposes it as such.
class FourdgsGaussianSet {
  const FourdgsGaussianSet({
    required this.positions,
    required this.scales,
    required this.rotations,
    required this.colors,
    required this.motions,
    required this.muT,
    required this.sigmaT,
    required this.winLo,
    required this.winHi,
    this.shDegree = 0,
    this.sh,
    this.shCoefficients = 0,
    this.sourceIndex,
    this.objectId,
  });

  /// An empty set, for a file that legitimately carries no gaussians.
  factory FourdgsGaussianSet.empty({int shDegree = 0}) => FourdgsGaussianSet(
    positions: Float32List(0),
    scales: Float32List(0),
    rotations: Float32List(0),
    colors: Float32List(0),
    motions: Float32List(0),
    muT: Float32List(0),
    sigmaT: Float32List(0),
    winLo: Float32List(0),
    winHi: Float32List(0),
    shDegree: shDegree,
  );

  final Float32List positions; // n * 3, rest position
  final Float32List scales; // n * 3, linear
  final Float32List rotations; // n * 4, unit quaternion xyzw
  final Float32List colors; // n * 4, linear rgb and opacity in [0, 1]
  final Float32List motions; // n * 3, units per second
  final Float32List muT; // n, seconds
  final Float32List sigmaT; // n, seconds; infinity means "never fades"
  final Float32List winLo; // n, seconds
  final Float32List winHi; // n, seconds
  final int shDegree;

  /// View-dependent colour, `n * 3 * [shCoefficients]` bytes, or `null` when the
  /// scene carries none.
  ///
  /// Component-major within a gaussian's row: every coefficient of red, then of
  /// green, then of blue — the layout the band streams are written in. Handed
  /// back as the bytes the producer stored, undecoded: what they mean is a
  /// rendering decision and does not belong to a container.
  final Uint8List? sh;

  /// Coefficients per colour component: 3 at degree 1, 8 at degree 2, 15 at
  /// degree 3. Zero when the scene carries no harmonics.
  final int shCoefficients;

  /// Optional producer-side stable ids, when the file carried them.
  final Int32List? sourceIndex;

  /// Object membership (spec section 6.6), or null when no chunk carried the
  /// stream. `0` is background: a gaussian that belongs to no object and no
  /// track may transform.
  final Int32List? objectId;

  int get count => muT.length;

  /// Reconstructed state at scene time [t], exactly as the specification
  /// defines it:
  ///
  /// ```
  /// visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
  /// marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
  /// center   =  position + motion * (t - mu_t)
  /// opacity  =  color.a * marginal
  /// ```
  ///
  /// The window test is not optional and is not the same test as the marginal:
  /// it is what allows one file to hold gaussians fitted independently over
  /// different spans of the timeline without them bleeding into each other's
  /// intervals.
  FourdgsState stateAt(double t, {double cutoff = 0.05}) {
    final n = count;
    final keep = Uint32List(n);
    int k = 0;
    for (int i = 0; i < n; i++) {
      if (!(winLo[i] <= t && t < winHi[i])) continue;
      if (_marginal(i, t) < cutoff) continue;
      keep[k++] = i;
    }

    final indices = Uint32List.sublistView(keep, 0, k);
    final centers = Float64List(k * 3);
    final orientations = Float64List(k * 4);
    final opacity = Float64List(k);
    final ids = objectId;
    final stateIds = ids == null ? null : Int32List(k);
    for (int j = 0; j < k; j++) {
      final i = indices[j];
      final dt = t - muT[i];
      centers[j * 3] = positions[i * 3] + motions[i * 3] * dt;
      centers[j * 3 + 1] = positions[i * 3 + 1] + motions[i * 3 + 1] * dt;
      centers[j * 3 + 2] = positions[i * 3 + 2] + motions[i * 3 + 2] * dt;
      for (int axis = 0; axis < 4; axis++) {
        orientations[j * 4 + axis] = rotations[i * 4 + axis];
      }
      if (stateIds != null) stateIds[j] = ids![i];
      opacity[j] = colors[i * 4 + 3] * _marginal(i, t);
    }
    return FourdgsState(
      indices: indices,
      centers: centers,
      orientations: orientations,
      opacity: opacity,
      objectId: stateIds,
    );
  }

  /// The temporal marginal of gaussian [i] at [t]: 1 for a never-fading
  /// gaussian, the usual bell otherwise.
  double _marginal(int i, double t) {
    final sigma = sigmaT[i];
    if (!sigma.isFinite) return 1.0;
    final z = (t - muT[i]) / math.max(sigma, 1e-30);
    return math.exp(-0.5 * z * z);
  }

  /// Per-gaussian visible interval, clipped to the validity window.
  ///
  /// This is what a chunker partitions on, and it is why content whose
  /// gaussians all live for the whole clip cannot be partitioned: every
  /// interval is the whole timeline, so every gaussian lands at the root.
  ({Float64List lo, Float64List hi}) support({double cutoff = 0.05}) {
    final k = math.sqrt(-2.0 * math.log(cutoff));
    final lo = Float64List(count);
    final hi = Float64List(count);
    for (int i = 0; i < count; i++) {
      final sigma = sigmaT[i];
      final half = sigma.isFinite ? k * sigma : double.infinity;
      lo[i] = math.max(muT[i] - half, winLo[i]);
      hi[i] = math.min(muT[i] + half, winHi[i]);
    }
    return (lo: lo, hi: hi);
  }
}
