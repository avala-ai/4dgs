// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// `fourdgs`: inspect and check `.4dgs` files from a shell.
///
/// Thin by design — every command is a few lines over the library, so anything
/// this tool can do is something a caller can do. That rule is the Python tool's,
/// and it is repeated here because it is what keeps a command-line tool from
/// becoming a second, undocumented implementation of the format.
///
/// The tools are expected to agree. Where a command exists in more than one of
/// them it reads the same records, reports the same offsets, and exits the same
/// way; a difference between two of them on one file is a bug in one of them,
/// not a matter of taste. What every one of them adds to the finding lines is the
/// **refusal identifier** and the byte it fired at, because the sentence a
/// decoder raises is the language's and the identifier is the format's.
///
/// It lives in `bin/` and not in the decoder, because it opens files and I/O
/// lives at the edges (AGENTS.md §3): `package:fourdgs/fourdgs.dart` stays a
/// decoder over a byte-range abstraction with no `dart:io` in it, and this
/// reaches for `package:fourdgs/io.dart` — the transport — as any application
/// would.
library;

import 'dart:io';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';

/// Exit codes, which are the only part of a CLI another program reads.
///
/// A validator that answered 0 for "some warnings" and 0 for "nothing to say"
/// would put the warnings out of a script's reach, so they get their own code.
const int exitOk = 0;
const int exitRefused = 1;
const int exitWarnings = 2;

/// The tool could not do its job: no such file, no permission, an argument it
/// does not understand.
///
/// Separate from [exitRefused] because the two mean opposite things to whatever
/// is reading them. `1` is an answer about the file — it was read, and it is bad.
/// `3` is the absence of an answer, and a pipeline that treats them alike cannot
/// tell a corrupt asset from a typo in a path. A tool that exits 1 for both is
/// indistinguishable from a broken one.
const int exitToolFailed = 3;

const String usage = '''
fourdgs — inspect and validate .4dgs files

usage:
  fourdgs inspect <file> [--json]     walk the records: offset, opcode, length, crc
  fourdgs validate <file>             check a file against the specification
  fourdgs --version
  fourdgs --help

options:
  --json      machine-readable output (inspect)

exit codes:
  0  fine
  1  refused, or invalid
  2  valid, with warnings
  3  the tool itself failed: a usage error, an unreadable path, a bug
''';

Future<void> main(List<String> argv) async {
  exitCode = await run(argv, stdout.writeln, stderr.writeln);
}

/// One invocation, and the code it exits with.
///
/// The two sinks are arguments so that a test reads exactly what a user would
/// read, rather than asserting against a process it had to spawn.
Future<int> run(
  List<String> argv,
  void Function(String) out,
  void Function(String) err,
) async {
  if (argv.isEmpty || argv.first == '--help' || argv.first == '-h') {
    out(usage.trimRight());
    return exitOk;
  }
  if (argv.first == '--version') {
    out(fourdgsPackageVersion);
    return exitOk;
  }
  final String command = argv.first;
  if (command != 'inspect' && command != 'validate') {
    return _usageError(err, 'unknown command "$command"');
  }
  String? path;
  bool json = false;
  for (final String argument in argv.skip(1)) {
    if (argument == '--json') {
      json = true;
    } else if (argument.startsWith('-')) {
      return _usageError(err, 'unknown option $argument');
    } else if (path != null) {
      return _usageError(err, 'more than one file given');
    } else {
      path = argument;
    }
  }
  if (path == null) return _usageError(err, '$command needs a file');
  if (json && command != 'inspect') {
    return _usageError(err, '--json applies to inspect');
  }

  final FourdgsFileReadable source;
  try {
    source = await FourdgsFileReadable.open(path);
  } on FileSystemException catch (error) {
    // Not the file's fault as a 4dgs file, and not a refusal: nothing was read.
    err('fourdgs: $path: ${error.osError?.message ?? error.message}');
    return exitToolFailed;
  }
  try {
    return command == 'inspect'
        ? await _inspect(source, path, json, out, err)
        : await _validate(source, out, err);
  } on FourdgsException catch (error) {
    // A refusal that reached here is a verdict about the file: the magic check
    // is the one refusal that leaves nothing to walk.
    err('fourdgs: $path: ${error.message}');
    final FourdgsNamedRefusal? named = describeFourdgsRefusal(error);
    if (named != null) err('fourdgs: $named');
    return exitRefused;
  } finally {
    await source.close();
  }
}

int _usageError(void Function(String) err, String message) {
  err('fourdgs: $message');
  err('\n${usage.trimRight()}');
  return exitToolFailed;
}

Future<int> _inspect(
  FourdgsFileReadable source,
  String path,
  bool json,
  void Function(String) out,
  void Function(String) err,
) async {
  final FourdgsInspection inspection = await inspectFourdgs(source);
  out(
    (json
            ? formatFourdgsInspectionJson(inspection)
            : formatFourdgsInspection(inspection))
        .trimRight(),
  );
  final FourdgsCut? cut = inspection.walk.cut;
  if (cut != null) {
    // The prefix was recovered and reported; the file is still not a whole one,
    // and a pipeline that goes on to read it should not be told otherwise.
    err('fourdgs: $path: truncated at byte ${cut.at}');
    return exitRefused;
  }
  // A file cut exactly at a record boundary — after its Footer, say — leaves the
  // walk nothing to stop on: there are no bytes left, so there is no cut, and
  // the only evidence is the eight bytes of magic that are not there. The table
  // says so, and the exit code must too, or a script reading the code alone is
  // told a truncated file inspected cleanly. `validate` calls the same file an
  // error; one tool giving two verdicts on whether a file is whole is worse than
  // either verdict.
  if (!inspection.walk.trailingMagic) {
    err('fourdgs: $path: the file does not end with the magic');
    return exitRefused;
  }
  return exitOk;
}

Future<int> _validate(
  FourdgsFileReadable source,
  void Function(String) out,
  void Function(String) err,
) async {
  final FourdgsValidation report = await validateFourdgs(source);
  for (final FourdgsFinding finding in report.findings) {
    out('${finding.severity.label}: ${finding.message}');
    // Indented, and with a prefix of its own, so that a caller filtering the
    // findings on `error:` / `warning:` / `note:` — which is how the validators
    // are compared — sees exactly what it saw before.
    if (finding.refusal != null) out('  ${finding.refusal}');
  }
  if (!report.ok) {
    err('INVALID');
    return exitRefused;
  }
  out(report.findings.isEmpty ? 'valid' : 'valid (with notes)');
  // The one deliberate divergence from the Python tool, which exits 0 here. A
  // warning a script cannot see is a warning nobody acts on, so it gets its own
  // code — as the Rust and TypeScript tools' does.
  return report.warned ? exitWarnings : exitOk;
}
