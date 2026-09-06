// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// End-to-end checks for the shared optional-identity witnesses.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fourdgs_conformance/canonical.dart';
import 'package:test/test.dart';

const Map<String, String> _witnesses = <String, String>{
  'gaussian-birth':
      'identity/gaussian-birth/'
      'OptionalIdentityGaussianBirth-UseChunkIndex-UseCrc',
  'keyframe-delta':
      'identity/keyframe-delta/'
      'OptionalIdentityKeyframeDelta-UseChunkIndex-UseCrc-UseStatistics',
};

void main() {
  for (final runner in <String>[
    'decode_streamed.dart',
    'decode_indexed.dart',
  ]) {
    for (final witness in _witnesses.entries) {
      test('$runner reconstructs ${witness.key} optional identities', () {
        final stem = '../../tests/conformance/data/${witness.value}';
        final input = File('$stem.4dgs');
        final expectation = File('$stem.json');
        expect(input.existsSync(), isTrue, reason: 'generate the corpus first');
        expect(
          expectation.existsSync(),
          isTrue,
          reason: 'the witness needs its committed expectation',
        );

        final done = Process.runSync(Platform.resolvedExecutable, <String>[
          'run',
          'bin/$runner',
          input.path,
        ]);
        expect(done.exitCode, 0, reason: done.stderr as String);
        expect(
          canonical(jsonDecode(done.stdout as String)),
          canonical(jsonDecode(expectation.readAsStringSync())),
        );
      });
    }
  }
}
