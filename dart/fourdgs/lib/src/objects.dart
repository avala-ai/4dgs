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
import 'records.dart';

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
    if (found == null || found.sampleCount == 0) return null;
    return fourdgsPoseAt(FourdgsObjectTrackView(found), t);
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

    final referenced = <int>{};
    for (final id in objectIds) {
      if (id != backgroundObject) referenced.add(id);
    }
    final poses = <int, FourdgsPose>{};
    for (final track in tracks) {
      if (!referenced.contains(track.objectId)) continue;
      final pose = poseAt(track.objectId, t);
      if (pose != null) poses[track.objectId] = pose;
    }
    if (poses.isEmpty) return;

    for (int i = 0; i < count; i++) {
      final pose = poses[objectIds[i]];
      if (pose == null) continue;
      final moved = pose.apply(<double>[
        centers[i * 3],
        centers[i * 3 + 1],
        centers[i * 3 + 2],
      ]);
      for (int axis = 0; axis < 3; axis++) {
        centers[i * 3 + axis] = moved[axis];
      }
      final turned = quaternionMultiply(pose.rotation, <double>[
        orientations[i * 4],
        orientations[i * 4 + 1],
        orientations[i * 4 + 2],
        orientations[i * 4 + 3],
      ]);
      for (int axis = 0; axis < 4; axis++) {
        orientations[i * 4 + axis] = turned[axis];
      }
    }
  }
}
