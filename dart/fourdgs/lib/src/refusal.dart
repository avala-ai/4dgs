// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Which refusal, and which byte it fired at.
///
/// The decoder already names its refusals — every [FourdgsException] carries a
/// [FourdgsException.refusalCode], the stable identifier the conformance corpus
/// is written against — and its messages already say which value was found and
/// what was expected. What neither of them carries is the **offset**: an
/// exception is thrown where the value was parsed, not where its bytes sit, and
/// by then the record's position is several frames up the stack.
///
/// So the tool supplies it. The refusal vocabulary is six identifiers, each of
/// which is about exactly one kind of record, and a framing walk knows where
/// every record is. That is the whole mechanism: walk the framing, ask which
/// record this refusal is about, name the byte.
///
/// Front matter is located from framing alone. A refusal that lives inside a
/// chunk's attribute streams is located by decoding chunks one at a time until
/// one of them refuses — which is also the only way to *find* those refusals at
/// all, because the framing walk steps over a chunk by its declared length and
/// never looks inside it.
///
/// This file is `rust/cli/src/refusal.rs` and `python/fourdgs/fourdgs/refusal.py`
/// in Dart, deliberately: two tools that place the same refusal at two different
/// bytes are worse than one tool that places none, so the table below is the same
/// table.
library;

import 'dart:typed_data';

import 'exceptions.dart';
import 'opcode.dart';
import 'readable.dart';
import 'serialization.dart';

/// One record's framing: what it is, where it starts, how long its content is.
class FourdgsFrame {
  const FourdgsFrame({
    required this.opcode,
    required this.offset,
    required this.length,
  });

  final int opcode;

  /// Offset of the opcode byte.
  final int offset;

  /// Content length, as the record declares it.
  final int length;

  /// Framing plus content, which is what an offset has to advance by.
  int get total => length + recordHeaderBytes;
}

/// Where a framing walk stopped, when it did not reach the end.
class FourdgsCut {
  const FourdgsCut({
    required this.at,
    required this.reason,
    required this.insideARecord,
  });

  /// The first byte the walk could not account for.
  final int at;

  final String reason;

  /// True when the cut is inside a record whose framing was read — so the last
  /// record the walk reports is the incomplete one, and everything before it is
  /// intact.
  final bool insideARecord;
}

/// The result of walking a file's framing: every record, and the cut if there
/// was one.
class FourdgsWalk {
  FourdgsWalk({required this.size});

  final List<FourdgsFrame> records = <FourdgsFrame>[];
  FourdgsCut? cut;

  /// True when the last eight bytes are the magic, as a whole file's are.
  bool trailingMagic = false;

  final int size;

  /// The first record with this opcode, if the file carries one.
  FourdgsFrame? first(int opcode) {
    for (final FourdgsFrame frame in records) {
      if (frame.opcode == opcode) return frame;
    }
    return null;
  }

  /// How many of the reported records are whole.
  ///
  /// All of them, except when the file was cut inside one: that record is
  /// reported — hiding it would hide the declared length that is the whole fault
  /// — but it is not something a streamed reader keeps.
  int get intact {
    final int incomplete = cut != null && cut!.insideARecord ? 1 : 0;
    final int whole = records.length - incomplete;
    return whole < 0 ? 0 : whole;
  }
}

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap
/// on a file carrying an hour of audio as on one carrying none — and it is why
/// `inspect` never has to hold a scene to describe one. The magic is checked
/// first, because a walk over bytes that are not ours would report whatever the
/// first byte happened to mean as an opcode.
Future<FourdgsWalk> walkFourdgsFraming(FourdgsReadable source) async {
  final int size = await source.size();
  final int magic = fourdgsMagic.length;
  checkMagic(await source.read(0, size < magic ? size : magic));

  final FourdgsWalk out = FourdgsWalk(size: size);
  int at = magic;
  while (true) {
    final int remaining = size - at;
    if (remaining <= 0) break;
    // A whole file ends with the magic, so its last eight bytes are not a
    // record. Fewer than nine bytes left is the same case: nothing that short
    // can be a record header either.
    if (remaining <= magic) {
      out.trailingMagic = _sameBytes(await source.read(at, remaining));
      if (!out.trailingMagic) {
        out.cut = FourdgsCut(
          at: at,
          reason:
              '$remaining trailing bytes are neither a record nor the magic',
          insideARecord: false,
        );
      }
      break;
    }
    final Uint8List framing = await source.read(at, recordHeaderBytes);
    final ByteData view = ByteData.sublistView(framing);
    final int opcode = framing[0];
    // Two 32-bit halves rather than `getUint64`, which is unsupported when Dart
    // compiles to JavaScript. A length past 2^53 cannot be a real one, and it
    // arrives here as a number large enough to run off the end of any file —
    // which is exactly what the walk then reports.
    final int length =
        view.getUint32(5, Endian.little) * 0x100000000 +
        view.getUint32(1, Endian.little);
    final FourdgsFrame frame = FourdgsFrame(
      opcode: opcode,
      offset: at,
      length: length,
    );
    // A record is listed either way: a declared length that runs off the end is
    // a fact about that record, and hiding the record hides the field that
    // carries the fault.
    out.records.add(frame);
    final int end = at + frame.total;
    if (end > size) {
      out.cut = FourdgsCut(
        at: at,
        reason:
            'the ${opcodeName(opcode)} record declares ${fourdgsCommas(length)} '
            'bytes, past the end of a ${fourdgsCommas(size)}-byte file',
        insideARecord: true,
      );
      break;
    }
    at = end;
  }
  return out;
}

bool _sameBytes(Uint8List candidate) {
  if (candidate.length != fourdgsMagic.length) return false;
  for (int i = 0; i < candidate.length; i++) {
    if (candidate[i] != fourdgsMagic[i]) return false;
  }
  return true;
}

/// The byte a refusal fired at, and what sits there.
class FourdgsRefusalSite {
  const FourdgsRefusalSite(this.offset, this.what);

  final int offset;

  /// What the offset points at, in the vocabulary of `concepts.md` — "the
  /// Header record", not just a number.
  final String what;
}

/// A refusal with a name, and where it is if the tool could place it.
class FourdgsNamedRefusal {
  const FourdgsNamedRefusal(this.code, this.site);

  final String code;
  final FourdgsRefusalSite? site;

  @override
  String toString() {
    final FourdgsRefusalSite? where = site;
    if (where == null) return 'refusal $code';
    return 'refusal $code at byte ${where.offset} (${where.what})';
  }
}

/// Which record each named refusal is about.
///
/// A table rather than a guess, and a short one because the refusal vocabulary
/// is short. A code this build has not been taught is left unplaced rather than
/// placed wrongly: an offset that points at the wrong record is worse than no
/// offset, because the reader believes it.
const Map<String, (int, String)> _frontMatter = <String, (int, String)>{
  refusalUnknownTemporalModel: (opHeader, 'the Header record'),
  refusalUnknownQuantizationScheme: (opQuantization, 'the Quantization record'),
};

/// Refusals about the eight bytes of the magic itself, which is why neither
/// needs a walk to place: the walk that would find a record cannot start until
/// they pass, so the offset is known without one.
const Set<String> _atTheMagic = <String>{
  refusalMagicMismatch,
  refusalUnsupportedMajorVersion,
};

/// Everything the tool can say about one refusal: the identifier and the byte.
///
/// `null` for an error the refusal table does not name — a truncated transport,
/// a declared length past this build's ceiling. That is not a failure of this
/// function; it is the decoder saying "this is not one of the refusals the
/// corpus compares", and a tool that invented an identifier there would be
/// inventing conformance.
FourdgsNamedRefusal? describeFourdgsRefusal(
  Object error, {
  FourdgsWalk? walk,
  FourdgsRefusalSite? site,
}) {
  if (error is! FourdgsException) return null;
  final String? code = error.refusalCode;
  if (code == null) return null;
  return FourdgsNamedRefusal(code, site ?? _placeFrontMatter(walk, code));
}

FourdgsRefusalSite? _placeFrontMatter(FourdgsWalk? walk, String code) {
  if (_atTheMagic.contains(code)) {
    return const FourdgsRefusalSite(0, 'the magic');
  }
  final (int, String)? entry = _frontMatter[code];
  if (entry == null || walk == null) return null;
  final FourdgsFrame? frame = walk.first(entry.$1);
  return frame == null ? null : FourdgsRefusalSite(frame.offset, entry.$2);
}

/// A count with thousands separators, matching the Python tool's `{:,}`.
///
/// Written out rather than left to a locale-aware formatter: what a validator
/// prints should not depend on where it is run, because the four tools are
/// compared by diffing what they print.
String fourdgsCommas(int n) {
  final String digits = n.toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
