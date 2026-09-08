// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Canonical projections for the optional-identity conformance witnesses.
library;

import 'package:fourdgs/fourdgs.dart';

import 'canonical.dart';

const String _markerKey = 'conformance';
const String _markerValue = 'optional-identity-zero-defaults-v1';

/// Whether a Header selects the narrow optional-identity result.
bool isOptionalIdentityWitness(FourdgsHeader header) =>
    header.attributes[_markerKey] == _markerValue;

/// Logical identity rows from a gaussian-birth population, ordered by position.
Map<String, Object?> gaussianBirthIdentityJson(FourdgsGaussianSet gaussians) {
  final order = <int>[for (int row = 0; row < gaussians.count; row++) row]
    ..sort((int a, int b) {
      for (int component = 0; component < 3; component++) {
        final left = gaussians.positions[a * 3 + component];
        final right = gaussians.positions[b * 3 + component];
        if (left < right) return -1;
        if (left > right) return 1;
      }
      return 0;
    });
  return <String, Object?>{
    'temporalModel': 'gaussian-birth',
    'identityRows': <Object?>[
      for (final row in order)
        <String, Object?>{
          'sourceGroup': (gaussians.sourceGroup?[row] ?? 0).toString(),
          'sourceIndex': (gaussians.sourceIndex?[row] ?? 0).toString(),
          'objectId': (gaussians.objectId?[row] ?? 0).toString(),
          'position': <Object?>[
            for (int component = 0; component < 3; component++)
              num6(gaussians.positions[row * 3 + component]),
          ],
        },
    ],
  };
}

/// Logical identity columns after every keyframe or delta state record.
Map<String, Object?> keyframeDeltaIdentityJson(
  KeyframeDeltaSequence sequence,
) => <String, Object?>{
  'temporalModel': 'keyframe-delta',
  'identityStates': <Object?>[
    for (final chunk in sequence.chunks)
      <String, Object?>{
        't': num6(chunk.t0),
        'rows': <Object?>[
          for (final row in (<int>[
            for (int row = 0; row < chunk.state.count; row++) row,
          ]..sort(
            (int a, int b) => chunk.state.ids[a].compareTo(chunk.state.ids[b]),
          )))
            _keyframeDeltaIdentityRow(chunk.state, row),
        ],
      },
  ],
};

Map<String, Object?> _keyframeDeltaIdentityRow(
  KeyframeDeltaState state,
  int row,
) {
  final identity = state.identityAt(row);
  return <String, Object?>{
    'sourceGroup': identity.sourceGroup.toString(),
    'sourceIndex': identity.sourceIndex.toString(),
    'objectId': identity.objectId.toString(),
    'gaussianId': state.ids[row].toString(),
  };
}
