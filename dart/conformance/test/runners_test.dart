// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What the conformance runners claim when a file will not decode.
///
/// The harness reads two things from a runner: its exit status and its stdout.
/// Those carry two different claims, and the invalid corpus only means anything
/// while they stay apart. Exit 0 with `{"refused": "<identifier>"}` says "I
/// refused this file, and here is the rule it broke" — an answer, diffed against
/// the committed expectation. A non-zero exit says "I did not produce an answer
/// at all".
///
/// An error the refusal table does not name belongs to the second claim. Written
/// as `{"refused": ""}` with exit 0 it becomes the first: the empty string is not
/// an identifier the format defines, so the harness is handed a refusal it cannot
/// check, and `run.py --update` — which writes what a runner prints, before
/// parsing it — would commit that as the expectation every other SDK is scored
/// against.
///
/// Both entry points are driven as subprocesses, because stdout, stderr and the
/// exit status together are what the harness branches on and no in-process call
/// proves them. All three are asserted at once on purpose: the old handling
/// satisfied two of them, printing a well-formed JSON document and exiting
/// cleanly, and only the identifier inside it said anything was wrong.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/canonical.dart';
import 'package:test/test.dart';

/// The two entry points, run the way `tests/conformance/run.py` runs them.
const List<String> runners = <String>[
  'decode_streamed.dart',
  'decode_indexed.dart',
];

/// Too short to hold the magic: a truncated transport. That is a real decode
/// failure, and one the refusal table deliberately does not name. Both read
/// paths reach it — the streamed runner front to back, the indexed one through
/// its opener — so it asks both the same question.
final List<int> unnamed = <int>[0x34, 0x44, 0x47];

/// The magic is the one refusal a file this small can still carry a name for,
/// which makes it the control: the fix must not turn named refusals into
/// failures on its way to turning unnamed ones into failures.
final List<int> named = utf8.encode('NOT4DGS!\n');

ProcessResult decode(String runner, List<int> bytes) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'fourdgs-runner-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final File input = File('${directory.path}/input.4dgs')
    ..writeAsBytesSync(bytes);
  final String script = 'bin/$runner';
  expect(
    File(script).existsSync(),
    isTrue,
    reason: 'run this from the package root, where $script lives',
  );
  return Process.runSync(Platform.resolvedExecutable, <String>[
    'run',
    script,
    input.path,
  ]);
}

void main() {
  for (final String runner in runners) {
    test('$runner: an error the refusal table cannot name is a failure', () {
      final ProcessResult done = decode(runner, unnamed);
      expect(
        done.exitCode,
        isNot(0),
        reason: '$runner claimed an answer for an error it cannot name',
      );
      expect(
        done.stdout as String,
        isEmpty,
        reason: '$runner printed a document for a failed invocation',
      );
      expect(
        (done.stderr as String).trim(),
        isNotEmpty,
        reason: '$runner failed without saying why',
      );
    });

    test('$runner: a named refusal is still an answer', () {
      final ProcessResult done = decode(runner, named);
      expect(
        done.exitCode,
        0,
        reason:
            '$runner failed the invocation for a refusal it named: '
            '${done.stderr}',
      );
      expect(jsonDecode(done.stdout as String), <String, Object?>{
        'refused': 'magic-mismatch',
      });
      expect(done.stderr as String, isEmpty);
    });
  }

  test('only an error carrying an identifier is an answer', () {
    // The rule the two runners share, asked of the classifier directly: `null`
    // is "not one of the refusals the corpus compares", which the callers turn
    // into a failed invocation rather than into a refusal nobody can check.
    expect(refusalAnswer(const FourdgsMalformedFile('short file')), isNull);
    expect(
      jsonDecode(
        refusalAnswer(
          const FourdgsMalformedFile(
            'bad magic',
            refusalCode: refusalMagicMismatch,
          ),
        )!,
      ),
      <String, Object?>{'refused': 'magic-mismatch'},
    );
  });
}
