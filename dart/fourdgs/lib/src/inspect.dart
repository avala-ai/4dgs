// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Walk the records: opcode by name, byte offset, length, CRC status.
///
/// Framing only, plus the summary region the Footer names. A record's content is
/// never read, so this costs the same on a file with an embedded audio payload as
/// on one without — and an opcode nobody here has heard of is stepped over by its
/// own declared length, which is the whole forward-compatibility story, exercised
/// rather than described.
///
/// A file that was cut is walked as far as it goes and then says so. That is what
/// the decoder does with one — records are length-prefixed, so everything
/// complete before the cut is intact and the streamed reader keeps it — and a
/// tool whose job is to say where a file stops being a 4dgs file should not
/// answer that question by printing one line and throwing the rest away.
library;

import 'dart:typed_data';

import 'opcode.dart';
import 'readable.dart';
import 'records.dart';
import 'refusal.dart';
import 'serialization.dart';

/// The only checksum the format defines: `summary_crc` over the bytes from
/// `summary_start` to where the Footer begins.
///
/// So a record's "CRC status" is a fact about the region it sits in rather than a
/// field of its own — covered and agreeing, covered and not, or covered by
/// nothing at all — and saying so per record is what tells a reader whether the
/// checksum has anything to say about the record they are looking at.
class FourdgsSummaryCoverage {
  const FourdgsSummaryCoverage({
    required this.start,
    required this.end,
    required this.ok,
  });

  final int start;

  /// One past the last covered byte: where the Footer record's opcode sits.
  final int end;

  final bool ok;

  /// The cell for a record, in the vocabulary `validate` already uses.
  String cell(int at, int total) {
    if (at < start || at + total > end) return '-';
    return ok ? 'ok' : 'MISMATCH';
  }
}

/// Every record a file frames, and what the summary checksum covers.
class FourdgsInspection {
  const FourdgsInspection({required this.walk, required this.coverage});

  final FourdgsWalk walk;

  /// `null` when the file declares no summary checksum, which is a property of
  /// the file rather than a failure: writing one is an encoder option, and a file
  /// written without it has nothing here to verify.
  final FourdgsSummaryCoverage? coverage;
}

/// Frames every record, then checks the summary region the Footer declares.
Future<FourdgsInspection> inspectFourdgs(FourdgsReadable source) async {
  final FourdgsWalk walk = await walkFourdgsFraming(source);
  return FourdgsInspection(walk: walk, coverage: await _coverage(source, walk));
}

Future<FourdgsSummaryCoverage?> _coverage(
  FourdgsReadable source,
  FourdgsWalk walk,
) async {
  final FourdgsFrame? frame = walk.first(opFooter);
  if (frame == null || frame.offset + frame.total > walk.size) return null;
  final FourdgsFooter footer = FourdgsFooter.parse(
    await source.read(frame.offset + recordHeaderBytes, frame.length),
  );
  if (footer.summaryCrc == 0 ||
      footer.summaryStart == 0 ||
      footer.summaryStart > frame.offset) {
    return null;
  }
  // The summary ends where the Footer begins — taken from the walk rather than
  // computed from a Footer's expected size, so a Footer that a later revision
  // extends does not move the region out from under the check.
  final Uint8List summary = await source.read(
    footer.summaryStart,
    frame.offset - footer.summaryStart,
  );
  return FourdgsSummaryCoverage(
    start: footer.summaryStart,
    end: frame.offset,
    ok: fourdgsCrc32(summary) == footer.summaryCrc,
  );
}

/// The record table, in the column widths the Rust and TypeScript tools print.
///
/// Same columns in the same order, because the point of six tools that read one
/// format is that their output can be diffed rather than interpreted.
String formatFourdgsInspection(FourdgsInspection inspection) {
  final FourdgsWalk walk = inspection.walk;
  final FourdgsSummaryCoverage? coverage = inspection.coverage;
  final StringBuffer out = StringBuffer();
  void row(String a, String b, String c, String d, String e) => out.writeln(
    '${a.padLeft(12)}  ${b.padRight(18)} ${c.padLeft(14)}  ${d.padLeft(14)}  $e',
  );

  row('offset', 'record', 'content', 'total', 'crc');
  row('0', '(magic)', '', '8', '-');
  for (final FourdgsFrame frame in walk.records) {
    row(
      fourdgsCommas(frame.offset),
      opcodeName(frame.opcode),
      fourdgsCommas(frame.length),
      fourdgsCommas(frame.total),
      coverage?.cell(frame.offset, frame.total) ?? '-',
    );
  }
  if (walk.trailingMagic) {
    row(fourdgsCommas(walk.size - 8), '(magic)', '', '8', '-');
  }

  out.writeln();
  out.writeln(
    '${walk.records.length} records, ${fourdgsCommas(walk.size)} bytes',
  );
  final FourdgsCut? cut = walk.cut;
  if (cut != null) {
    out.writeln('truncated at byte ${fourdgsCommas(cut.at)}: ${cut.reason}');
    final String last =
        cut.insideARecord
            ? '; the last row is the record the file was cut inside'
            : '';
    out.writeln(
      'the ${walk.intact} complete records above are the intact prefix, which '
      'is what a streamed reader keeps$last',
    );
  } else if (!walk.trailingMagic) {
    out.writeln('note: the file does not end with the magic');
  }
  if (coverage == null) {
    out.writeln(
      'crc: this file declares no summary checksum, so nothing here is covered',
    );
  } else {
    out.writeln(
      "crc: the Footer's summary checksum covers bytes "
      '${fourdgsCommas(coverage.start)}..${fourdgsCommas(coverage.end)}; '
      '`-` is a record it does not cover',
    );
  }
  return out.toString();
}

/// The same walk, for a caller that is a program rather than a person.
///
/// Written by hand rather than through `dart:convert` so that the field names and
/// their order are the Rust tool's, key for key: a script that reads one tool's
/// `--json` reads the other's.
String formatFourdgsInspectionJson(FourdgsInspection inspection) {
  final FourdgsWalk walk = inspection.walk;
  final FourdgsSummaryCoverage? coverage = inspection.coverage;
  final FourdgsCut? cut = walk.cut;
  final StringBuffer out = StringBuffer();
  out.writeln('{');
  out.writeln('  "size": ${walk.size},');
  out.writeln('  "trailing_magic": ${walk.trailingMagic},');
  if (cut == null) {
    out.writeln('  "stopped": null,');
    out.writeln('  "truncated_at": null,');
  } else {
    out.writeln('  "stopped": ${_jsonString(cut.reason)},');
    out.writeln('  "truncated_at": ${cut.at},');
  }
  if (coverage == null) {
    out.writeln('  "summary_crc": null,');
  } else {
    out.writeln(
      '  "summary_crc": {"start": ${coverage.start}, '
      '"end": ${coverage.end}, "ok": ${coverage.ok}},',
    );
  }
  out.writeln('  "records": [');
  for (int i = 0; i < walk.records.length; i++) {
    final FourdgsFrame frame = walk.records[i];
    final String cell = coverage?.cell(frame.offset, frame.total) ?? '-';
    final String crc = cell == '-' ? 'null' : _jsonString(cell.toLowerCase());
    final String comma = i + 1 == walk.records.length ? '' : ',';
    out.writeln(
      '    {"offset": ${frame.offset}, "opcode": ${frame.opcode}, '
      '"name": ${_jsonString(opcodeName(frame.opcode))}, '
      '"content_length": ${frame.length}, "total_length": ${frame.total}, '
      '"crc": $crc}$comma',
    );
  }
  out.writeln('  ]');
  out.writeln('}');
  return out.toString();
}

/// A string as a JSON string. The only escapes a record's fields can need are
/// these: opcode names are ASCII and a cut's reason is this file's own prose.
String _jsonString(String s) {
  final StringBuffer out = StringBuffer('"');
  for (final int unit in s.runes) {
    if (unit == 0x22) {
      out.write(r'\"');
    } else if (unit == 0x5C) {
      out.write(r'\\');
    } else if (unit == 0x0A) {
      out.write(r'\n');
    } else if (unit < 0x20) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  out.write('"');
  return out.toString();
}
