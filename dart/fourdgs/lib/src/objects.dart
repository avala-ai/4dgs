// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The object layer: what the Object Table and the SE(3) tracks mean once read.
///
/// `records.dart` knows the bytes; this file knows the composition and the one
/// rule that spans more than one record — that at most one track moves any
/// object.
///
/// The layer changes a reconstructed instant in exactly one way, and it is the
/// load-bearing rule of the whole design (spec section 5.15.6):
///
/// > A track transforms the base state; it does not replace it.
///
/// For a gaussian belonging to object `k`, with the base centre `c0` that the
/// temporal model produced (spec section 3), and the track's pose `(R, T)` at
/// `t`:
///
/// ```text
/// center(t) = R * c0 + T
/// orientation(t) = R ⊗ orientation0
/// ```
///
/// The pose is relative to the object's stored (rest) configuration, so
/// ignoring the whole layer leaves every object at rest — a valid scene —
/// rather than a pile at the origin. The transform is rigid: it moves the
/// centre, composes the orientation, and touches neither opacity nor the
/// temporal fields, so section 3's visibility runs unchanged on the base. A
/// gaussian that carries per-gaussian motion AND belongs to a moving track is
/// neither forbidden nor track-wins: its motion moves it inside the object's
/// frame (folded into `c0`), and the track then transports the object. The two
/// compose, base first.
///
/// Nothing here is required to decode gaussians. A file with no object layer
/// produces an empty [FourdgsObjectLayer], which is a value and never an error.
library;

import 'exceptions.dart';
import 'provenance.dart';
import 'quantization.dart';
import 'records.dart';
import 'model.dart';

/// Adapter so [FourdgsObjectTrack] satisfies [FourdgsPoseSampled], and the
/// clamp-and-slerp of section 5.15.4 is reused rather than restated.
class FourdgsObjectTrackView implements FourdgsPoseSampled {
  FourdgsObjectTrackView(this.track);

  final FourdgsObjectTrack track;

  @override
  String get name => 'object ${track.objectId}';

  @override
  int get interpolation => track.interpolation;

  @override
  int get sampleCount => track.sampleCount;

  @override
  double timeAt(int i) => track.times[i];

  @override
  List<double> rotationAt(int i) => track.rotations[i];

  @override
  List<double> translationAt(int i) => track.translations[i];
}

/// The pose one track holds at [t], or null when it has no samples.
///
/// A track is a [FourdgsPoseSampled] in everything but name, so section
/// 5.15.4's clamp-and-slerp is reached rather than restated.
FourdgsPose? _poseOf(FourdgsObjectTrack track, double t) {
  if (track.sampleCount == 0) return null;
  return fourdgsPoseAt(FourdgsObjectTrackView(track), t);
}

/// Every object-layer record a file carried, and the rule that spans the
/// tracks.
///
/// [table] is the file's one Object Table, or null. [tracks] is the SE(3)
/// tracks, at most one per object. An empty instance is what a scene with no
/// objects produces.
class FourdgsObjectLayer {
  FourdgsObjectLayer({this.table, List<FourdgsObjectTrack>? tracks})
    : tracks = tracks ?? <FourdgsObjectTrack>[];

  FourdgsObjectTable? table;
  final List<FourdgsObjectTrack> tracks;

  bool get isEmpty => table == null && tracks.isEmpty;

  FourdgsObjectTrack? track(int objectId) {
    for (final track in tracks) {
      if (track.objectId == objectId) return track;
    }
    return null;
  }

  /// At most one track per object.
  ///
  /// Two tracks for one object would move its gaussians by two poses. Each
  /// track's own rules are enforced at parse; this is the one rule no single
  /// record can see.
  void check() {
    final seen = <int>{};
    for (final track in tracks) {
      if (!seen.add(track.objectId)) {
        throw FourdgsMalformedFile(
          'two ObjectTrack records move object ${track.objectId}; a gaussian '
          'has one object and cannot be transported by two poses '
          '(section 5.15.7)',
        );
      }
    }
  }

  /// The rigid pose that transforms object [objectId] at scene time [t].
  ///
  /// Null when the object has no track — background, or an untracked object —
  /// in which case its gaussians keep their base state. A query outside the
  /// sample range returns the nearest end sample rather than extrapolating.
  FourdgsPose? poseAt(int objectId, double t) {
    if (objectId == backgroundObject) return null;
    final found = track(objectId);
    return found == null ? null : _poseOf(found, t);
  }

  /// Compose tracks onto reconstructed centres and orientations, in place.
  ///
  /// [centers] is `n * 3` flat, [orientations] is `n * 4` xyzw, and
  /// [objectIds] is `n`. Each gaussian whose object has a track is transformed;
  /// the rest pass through unchanged. Poses are sampled once per track and
  /// looked up by id, so composition is O(gaussians + tracks), not
  /// O(gaussians * tracks).
  void apply(
    List<double> centers,
    List<double> orientations,
    List<int> objectIds,
    double t,
  ) {
    check();
    final count = objectIds.length;
    if (centers.length != count * 3) {
      throw FourdgsMalformedFile(
        'object-layer composition received ${centers.length} center values for '
        '$count gaussians; expected ${count * 3}',
      );
    }
    if (orientations.length != count * 4) {
      throw FourdgsMalformedFile(
        'object-layer composition received ${orientations.length} orientation '
        'values for $count gaussians; expected ${count * 4}',
      );
    }

    // A table-only layer is valid and common — labels and anchors with nothing
    // moving — and has no pose to apply, so the id scan below would build a set
    // the size of the scene for nothing. The shape checks above still run: a
    // caller passing mismatched arrays is wrong whether or not a track exists.
    if (tracks.isEmpty) return;

    final referenced = <int>{};
    for (final id in objectIds) {
      if (id != backgroundObject) referenced.add(id);
    }
    final poses = <int, FourdgsPose>{};
    for (final track in tracks) {
      if (!referenced.contains(track.objectId)) continue;
      // Sampled from the track in hand rather than through [poseAt], which
      // would look the same track up by id and rescan the list — that is what
      // turns the O(gaussians + tracks) this method promises into O(tracks^2).
      final pose = _poseOf(track, t);
      if (pose != null) poses[track.objectId] = pose;
    }
    if (poses.isEmpty) return;

    // Scalars and direct writes rather than a point list and a quaternion list
    // per gaussian: composing a tracked million-gaussian object would otherwise
    // allocate millions of short-lived objects on the per-instant path, and the
    // collector would cost more than the arithmetic. The maths is the same as
    // [FourdgsPose.apply] and [quaternionMultiply], inlined.
    for (int i = 0; i < count; i++) {
      final pose = poses[objectIds[i]];
      if (pose == null) continue;
      final qx = pose.rotation[0];
      final qy = pose.rotation[1];
      final qz = pose.rotation[2];
      final qw = pose.rotation[3];
      final px = centers[i * 3];
      final py = centers[i * 3 + 1];
      final pz = centers[i * 3 + 2];
      // q * (0, p) * q^-1, expanded as two cross products.
      final tx = 2.0 * (qy * pz - qz * py);
      final ty = 2.0 * (qz * px - qx * pz);
      final tz = 2.0 * (qx * py - qy * px);
      centers[i * 3] = px + qw * tx + (qy * tz - qz * ty) + pose.translation[0];
      centers[i * 3 + 1] =
          py + qw * ty + (qz * tx - qx * tz) + pose.translation[1];
      centers[i * 3 + 2] =
          pz + qw * tz + (qx * ty - qy * tx) + pose.translation[2];

      final rx = orientations[i * 4];
      final ry = orientations[i * 4 + 1];
      final rz = orientations[i * 4 + 2];
      final rw = orientations[i * 4 + 3];
      orientations[i * 4] = qw * rx + qx * rw + qy * rz - qz * ry;
      orientations[i * 4 + 1] = qw * ry - qx * rz + qy * rw + qz * rx;
      orientations[i * 4 + 2] = qw * rz + qx * ry - qy * rx + qz * rw;
      orientations[i * 4 + 3] = qw * rw - qx * rx - qy * ry - qz * rz;
    }
  }
}

/// Reconstructed gaussian state at [t] with the object layer composed onto it.
///
/// [FourdgsGaussianSet.stateAt] returns the base temporal state, which is the
/// right answer for a scene with no object layer and the wrong one for a scene
/// that has tracks: the gaussians of a moving object come back at their rest
/// centres and orientations. Composition is a separate step because the layer
/// is additive and a consumer that only wants geometry should not pay for it —
/// but the composed reading is the one most callers want, and leaving it to
/// each of them to remember `objects.apply(...)` makes the default answer the
/// wrong one.
///
/// A scene with no layer, or one whose gaussians carry no membership, returns
/// the base state unchanged.
FourdgsState fourdgsStateAtWithObjects(
  FourdgsGaussianSet gaussians,
  FourdgsObjectLayer? objects,
  double t, {
  double cutoff = fourdgsDefaultCutoff,
}) {
  final state = gaussians.stateAt(t, cutoff: cutoff);
  final ids = state.objectId;
  if (objects == null || objects.isEmpty || ids == null) return state;
  objects.apply(state.centers, state.orientations, ids, t);
  return state;
}
