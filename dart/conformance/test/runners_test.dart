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

ProcessResult invoke(String runner, List<String> arguments) {
  final String script = 'bin/$runner';
  expect(
    File(script).existsSync(),
    isTrue,
    reason: 'run this from the package root, where $script lives',
  );
  return Process.runSync(Platform.resolvedExecutable, <String>[
    'run',
    script,
    ...arguments,
  ]);
}

Map<String, Object?> _document(String text) =>
    (jsonDecode(text) as Map).cast<String, Object?>();

({int opcode, int offset}) _recordSite(
  Map<String, Object?> document,
  String key,
) {
  final site = (document[key]! as Map).cast<String, Object?>();
  return (
    opcode: site['opcode']! as int,
    offset: int.parse(site['at']! as String),
  );
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

    test('$runner: the caller-selected decoded-state limit is exact', () {
      final input = File(
        '../../tests/conformance/data/'
        'OneGaussian-UseChunkIndex-UseCrc.4dgs',
      );
      expect(
        input.existsSync(),
        isTrue,
        reason: 'generate the conformance corpus before running this suite',
      );
      final done = invoke(runner, <String>[
        '--max-decoded-state-bytes',
        '1',
        input.absolute.path,
      ]);
      expect(done.exitCode, 0, reason: done.stderr);
      expect(done.stdout as String, '{"unsupported":"resource-limit"}\n');
      expect(done.stderr as String, isEmpty);
    });

    test('$runner: invalid decoded-state limits are usage errors', () {
      for (final value in <String>['0', '-1', '1.5', 'inf']) {
        final done = invoke(runner, <String>[
          '--max-decoded-state-bytes',
          value,
          'unused.4dgs',
        ]);
        expect(done.exitCode, 2, reason: '$value: ${done.stderr}');
        expect(done.stdout as String, isEmpty);
        expect(done.stderr as String, isNotEmpty);
      }
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

  test(
    'all shared late-front witnesses prove runner and validator sites',
    () async {
      const unstructured = FourdgsMalformedFile(
        'placement without sites',
        refusalCode: refusalLateFrontMatterRecord,
      );
      expect(
        refusalAnswer(unstructured, structuredLateFrontMatter: true),
        isNull,
        reason: 'the runner must not parse message text',
      );
      final directory = Directory(
        '../../tests/conformance/data/invalid/late-front-matter',
      );
      final expectations = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList(growable: false)..sort((a, b) => a.path.compareTo(b.path));
      expect(
        expectations,
        hasLength(18),
        reason:
            'run `python3 tests/conformance/generate.py` from the repository root',
      );

      for (final expectation in expectations) {
        final expected = _document(expectation.readAsStringSync());
        final file = File(
          expectation.path.substring(0, expectation.path.length - 5) + '.4dgs',
        );
        expect(file.existsSync(), isTrue, reason: file.path);

        final done = decode('decode_streamed.dart', file.readAsBytesSync());
        expect(done.exitCode, 0, reason: '${file.path}: ${done.stderr}');
        expect(_document(done.stdout as String), expected, reason: file.path);
        expect(done.stderr as String, isEmpty, reason: file.path);

        final report = await validateFourdgs(
          FourdgsBytes(file.readAsBytesSync()),
        );
        final named =
            report.findings
                .where(
                  (finding) =>
                      finding.refusal?.code == refusalLateFrontMatterRecord,
                )
                .single
                .refusal!;
        final expectedLate = _recordSite(expected, 'lateRecord');
        final expectedFirst = _recordSite(expected, 'firstStateRecord');
        final placement = named.lateFrontMatter!;
        expect(
          (
            placement.lateRecord.opcode,
            placement.lateRecord.offset,
            placement.firstStateRecord.opcode,
            placement.firstStateRecord.offset,
          ),
          (
            expectedLate.opcode,
            expectedLate.offset,
            expectedFirst.opcode,
            expectedFirst.offset,
          ),
          reason: file.path,
        );
      }
    },
  );
}
