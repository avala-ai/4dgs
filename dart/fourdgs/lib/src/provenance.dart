// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What the provenance records mean once they have been read.
///
/// [records] knows the bytes; this library knows the arithmetic and the rules
/// that span more than one record — that names are unique, that a sensor posed
/// against a rig names a rig the file actually carries, that an anchor anchors
/// a frame the file actually defines, and how a pose is recovered between two
/// trajectory samples.
///
/// The interpolation rules here are the specification's, executable. Section
/// 5.15.4 states them in prose because a specification has to; a reference
/// implementation exists so that "shortest-arc slerp" and "clamped, never
/// extrapolated" have exactly one meaning rather than one per reader.
///
/// Nothing here is required to decode gaussians. A consumer that only wants
/// geometry never touches a [FourdgsProvenance], and a file that carries none
/// produces an empty one — which is a value, not an error.
library;

import 'dart:math' as math;

import 'exceptions.dart';
import 'records.dart';

/// Metres per unit for each registry length unit, or `null` for one this build
/// does not know. An unrecognized registry value is not a malformed one.
const Map<int, double> lengthUnitMetres = <int, double>{
  1: 1.0,
  2: 0.01,
  3: 0.001,
  4: 1000.0,
  5: 0.3048,
  6: 0.0254,
};

/// A rigid transform: rotate by a unit quaternion, then translate.
class FourdgsPose {
  const FourdgsPose({required this.rotation, required this.translation});

  /// Unit quaternion, `xyzw`.
  final List<double> rotation;
  final List<double> translation;

  /// `R(rotation) * point + translation`, the direction section 5.15.3 states.
  List<double> apply(List<double> point) {
    final x = rotation[0];
    final y = rotation[1];
    final z = rotation[2];
    final w = rotation[3];
    final px = point[0];
    final py = point[1];
    final pz = point[2];
    // q * (0, p) * q^-1, expanded. Two cross products rather than a 3x3 build:
    // fewer operations and no matrix whose storage order can be got wrong.
    final tx = 2.0 * (y * pz - z * py);
    final ty = 2.0 * (z * px - x * pz);
    final tz = 2.0 * (x * py - y * px);
    return <double>[
      px + w * tx + (y * tz - z * ty) + translation[0],
      py + w * ty + (z * tx - x * tz) + translation[1],
      pz + w * tz + (x * ty - y * tx) + translation[2],
    ];
  }

  /// `this ∘ inner`: apply [inner] first, then this.
  ///
  /// This is what turns a sensor posed against a rig into a sensor posed in the
  /// scene, once the rig's pose at the instant of interest is known.
  FourdgsPose compose(FourdgsPose inner) => FourdgsPose(
    rotation: quaternionMultiply(rotation, inner.rotation),
    translation: apply(inner.translation),
  );
}

/// Hamilton product of two `xyzw` quaternions.
List<double> quaternionMultiply(List<double> a, List<double> b) {
  final ax = a[0], ay = a[1], az = a[2], aw = a[3];
  final bx = b[0], by = b[1], bz = b[2], bw = b[3];
  return <double>[
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
    aw * bw - ax * bx - ay * by - az * bz,
  ];
}

List<double> normalizeQuaternion(List<double> q) {
  double normSq = 0.0;
  for (final v in q) {
    normSq += v * v;
  }
  final norm = math.sqrt(normSq);
  if (!norm.isFinite || norm == 0.0) {
    throw FourdgsMalformedFile('a quaternion with norm $norm has no direction');
  }
  return <double>[q[0] / norm, q[1] / norm, q[2] / norm, q[3] / norm];
}

/// Shortest-arc spherical interpolation between two unit quaternions.
///
/// The sign flip is a correctness rule, not an optimization: `q` and `−q` are
/// the same rotation, so without it a trajectory takes the long way round
/// between two poses a degree apart — for one interval, once per sign flip,
/// which is exactly the kind of defect that survives a demo and shows up in
/// someone's analysis.
List<double> fourdgsSlerp(List<double> aIn, List<double> bIn, double u) {
  final a = normalizeQuaternion(aIn);
  var b = normalizeQuaternion(bIn);
  var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  if (dot < 0.0) {
    b = <double>[-b[0], -b[1], -b[2], -b[3]];
    dot = -dot;
  }
  if (dot > 0.9995) {
    // Near-parallel: the great-circle formula divides by a sine approaching
    // zero, and a straight lerp is within float noise of it here.
    return normalizeQuaternion(<double>[
      a[0] + u * (b[0] - a[0]),
      a[1] + u * (b[1] - a[1]),
      a[2] + u * (b[2] - a[2]),
      a[3] + u * (b[3] - a[3]),
    ]);
  }
  final theta = math.acos(dot.clamp(-1.0, 1.0));
  final sinTheta = math.sin(theta);
  final wa = math.sin((1.0 - u) * theta) / sinTheta;
  final wb = math.sin(u * theta) / sinTheta;
  return <double>[
    wa * a[0] + wb * b[0],
    wa * a[1] + wb * b[1],
    wa * a[2] + wb * b[2],
    wa * a[3] + wb * b[3],
  ];
}

/// A record [fourdgsPoseAt] can sample: time-stamped rigid poses with an
/// interpolation mode.
///
/// Both [FourdgsRigTrajectory] (a capture platform) and a future object-layer
/// track would implement this, so the clamp-and-slerp is written once.
abstract class FourdgsPoseSampled {
  String get name;
  int get interpolation;
  int get sampleCount;
  double timeAt(int i);
  List<double> rotationAt(int i);
  List<double> translationAt(int i);
}

/// Adapter so [FourdgsRigTrajectory] satisfies [FourdgsPoseSampled].
class FourdgsRigTrajectoryView implements FourdgsPoseSampled {
  FourdgsRigTrajectoryView(this.trajectory);

  final FourdgsRigTrajectory trajectory;

  @override
  String get name => trajectory.name;

  @override
  int get interpolation => trajectory.interpolation;

  @override
  int get sampleCount => trajectory.sampleCount;

  @override
  double timeAt(int i) => trajectory.times[i];

  @override
  List<double> rotationAt(int i) => trajectory.rotations[i];

  @override
  List<double> translationAt(int i) => trajectory.translations[i];
}

/// The normalized position of [t] between finite, strictly increasing [a] and
/// [b]. Scaling is necessary when the mathematical span is finite but cannot be
/// represented as an `f64`, for example `-1e308..1e308`.
double interpolationFraction(double t, double a, double b) {
  final span = b - a;
  if (span.isFinite) return (t - a) / span;
  final scale = a.abs() > b.abs() ? a.abs() : b.abs();
  return ((t / scale) - (a / scale)) / ((b / scale) - (a / scale));
}

/// Interpolate two finite values without overflowing their difference across
/// zero.
double finiteLerp(double a, double b, double u) {
  if ((a < 0.0) == (b < 0.0)) {
    return a + u * (b - a);
  }
  return (1.0 - u) * a + u * b;
}

void checkSceneTime(double t) {
  if (!t.isFinite) {
    throw FourdgsMalformedFile(
      'scene query time is $t; expected a finite value',
    );
  }
}

FourdgsPose _sample(FourdgsPoseSampled track, int i) => FourdgsPose(
  rotation: normalizeQuaternion(track.rotationAt(i)),
  translation: List<double>.from(track.translationAt(i)),
);

/// The pose at scene time [t], or `null` when the record has no samples.
///
/// Outside the sample range the pose is **clamped**, never extrapolated: before
/// the first sample it is the first sample, at or after the last it is the
/// last. Extrapolating produces a platform that accelerates away from the scene
/// at the ends of the clip, which is never what the capture did.
FourdgsPose? fourdgsPoseAt(FourdgsPoseSampled track, double t) {
  checkSceneTime(t);
  final n = track.sampleCount;
  if (n == 0) return null;
  if (t <= track.timeAt(0)) return _sample(track, 0);
  if (t >= track.timeAt(n - 1)) return _sample(track, n - 1);

  // Times are strictly increasing (enforced at parse), so a bisection is exact.
  var lo = 0;
  var hi = n - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (track.timeAt(mid) <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }

  if (track.interpolation == trajectoryStep) {
    return _sample(track, lo);
  }
  if (track.interpolation != trajectoryLinear) {
    // Unknown-but-legal, not malformed — but there is no defensible way to
    // invent the rule, and picking linear would silently answer a question the
    // file asked differently. Naming it is the whole obligation.
    throw FourdgsMalformedFile(
      "trajectory '${track.name}' uses interpolation ${track.interpolation}, "
      'which this build does not implement',
    );
  }

  final u = interpolationFraction(t, track.timeAt(lo), track.timeAt(lo + 1));
  final a = _sample(track, lo);
  final b = _sample(track, lo + 1);
  return FourdgsPose(
    rotation: fourdgsSlerp(a.rotation, b.rotation, u),
    translation: <double>[
      finiteLerp(a.translation[0], b.translation[0], u),
      finiteLerp(a.translation[1], b.translation[1], u),
      finiteLerp(a.translation[2], b.translation[2], u),
    ],
  );
}

/// Convenience: sample a [FourdgsRigTrajectory] without wrapping it.
FourdgsPose? fourdgsRigPoseAt(FourdgsRigTrajectory trajectory, double t) =>
    fourdgsPoseAt(FourdgsRigTrajectoryView(trajectory), t);

/// Every provenance record a file carried, and the rules that span them.
///
/// An empty instance is what a scene with no provenance produces. That is a
/// value and never an error: absence costs nothing and means nothing is claimed.
class FourdgsProvenance {
  FourdgsProvenance({
    List<FourdgsCoordinateFrame>? frames,
    List<FourdgsSensorCalibration>? sensors,
    List<FourdgsRigTrajectory>? trajectories,
    List<FourdgsGeodeticAnchor>? anchors,
  }) : frames = frames ?? <FourdgsCoordinateFrame>[],
       sensors = sensors ?? <FourdgsSensorCalibration>[],
       trajectories = trajectories ?? <FourdgsRigTrajectory>[],
       anchors = anchors ?? <FourdgsGeodeticAnchor>[];

  final List<FourdgsCoordinateFrame> frames;
  final List<FourdgsSensorCalibration> sensors;
  final List<FourdgsRigTrajectory> trajectories;
  final List<FourdgsGeodeticAnchor> anchors;

  bool get isEmpty =>
      frames.isEmpty &&
      sensors.isEmpty &&
      trajectories.isEmpty &&
      anchors.isEmpty;

  /// The file's own scene frame — the one named `""` — or `null`.
  FourdgsCoordinateFrame? get frame => frameNamed('');

  FourdgsCoordinateFrame? frameNamed(String name) {
    for (final f in frames) {
      if (f.name == name) return f;
    }
    return null;
  }

  FourdgsSensorCalibration? sensor(String name) {
    for (final s in sensors) {
      if (s.name == name) return s;
    }
    return null;
  }

  FourdgsRigTrajectory? trajectory([String name = '']) {
    for (final t in trajectories) {
      if (t.name == name) return t;
    }
    return null;
  }

  FourdgsGeodeticAnchor? anchor([String frameName = '']) {
    for (final a in anchors) {
      if (a.frameName == frameName) return a;
    }
    return null;
  }

  /// One unit of a frame in metres, or `null` when the file does not say.
  ///
  /// `metresPerUnit` is the authority where it and `lengthUnit` disagree (spec
  /// section 5.15.2): the number is what a consumer computes with, the enum is
  /// what it prints.
  double? metresPerUnit([String frameName = '']) {
    final f = frameNamed(frameName);
    if (f == null) return null;
    if (f.metresPerUnit > 0.0) return f.metresPerUnit;
    return lengthUnitMetres[f.lengthUnit];
  }

  /// A sensor's pose in the scene frame at scene time [t].
  ///
  /// For a sensor posed against the scene this is its extrinsic and [t] is
  /// ignored. For one posed against a rig it is the rig's pose at [t] composed
  /// with the extrinsic.
  FourdgsPose? sensorPoseAt(String name, double t) {
    final s = sensor(name);
    if (s == null) return null;
    final extrinsic = FourdgsPose(
      rotation: normalizeQuaternion(s.rotation),
      translation: List<double>.from(s.translation),
    );
    if (s.poseReference != poseToRig) return extrinsic;
    final rig = trajectory(s.rigName);
    if (rig == null) {
      throw FourdgsMalformedFile(
        "sensor '${s.name}' is posed against rig '${s.rigName}', which this "
        'file does not carry',
      );
    }
    final rigPose = fourdgsRigPoseAt(rig, t);
    if (rigPose == null) return extrinsic;
    return rigPose.compose(extrinsic);
  }

  /// The rules no single record can enforce on its own.
  ///
  /// All refusals rather than repairs: a duplicate name makes every reference
  /// to that name a coin toss; a rig reference into a file that carries no such
  /// rig would put every sensor on that rig at the origin; an anchor naming a
  /// frame the file never defined would put a whole scene somewhere on Earth no
  /// producer ever claimed.
  void check() {
    final groups = <(String, List<String>, String)>[
      ('CoordinateFrame', <String>[for (final f in frames) f.name], '5.15.2'),
      (
        'SensorCalibration',
        <String>[for (final s in sensors) s.name],
        '5.15.3',
      ),
      (
        'RigTrajectory',
        <String>[for (final t in trajectories) t.name],
        '5.15.4',
      ),
      (
        'GeodeticAnchor',
        <String>[for (final a in anchors) a.frameName],
        '5.15.5',
      ),
    ];
    for (final group in groups) {
      final label = group.$1;
      final names = group.$2;
      final section = group.$3;
      final seen = <String>{};
      for (final name in names) {
        if (seen.contains(name)) {
          throw FourdgsMalformedFile(
            "two $label records are named '$name'; these records are referred "
            'to by name and nothing else (section $section)',
          );
        }
        seen.add(name);
      }
    }

    // A zero-sample trajectory is "read as though the record were absent"
    // (section 5.15.4), so a rig-relative sensor naming one names a rig this
    // file does not carry — the same refusal, one step later. Composing it as
    // identity would place every sensor on that rig at the rig origin:
    // plausible, wrong, and silent.
    final rigs = <String>{
      for (final t in trajectories)
        if (t.sampleCount > 0) t.name,
    };
    for (final s in sensors) {
      if (s.poseReference == poseToRig && !rigs.contains(s.rigName)) {
        throw FourdgsMalformedFile(
          "sensor '${s.name}' is posed against rig '${s.rigName}', which this "
          'file does not carry (section 5.15.3)',
        );
      }
    }

    final frameNames = <String>{for (final f in frames) f.name};
    for (final a in anchors) {
      if (!frameNames.contains(a.frameName)) {
        throw FourdgsMalformedFile(
          "a GeodeticAnchor anchors frame '${a.frameName}', which this file "
          'does not define; an anchor for a frame nobody declared is a latitude '
          'attached to nothing (section 5.15.5)',
        );
      }
    }
  }
}
