// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Values that decode into plausible-looking output instead of an error.
///
/// Every case here is a field the decoder used to take at its word, and none of
/// them announces itself: a NaN bound is not a crash, it is a comparison that is
/// false at every instant, so the gaussians behind it silently never appear. An
/// out-of-registry enum is still a well-formed integer. A header total that
/// disagrees with the chunks is a scene that opens cleanly and is quietly short.
///
/// A vendored copy of this decoder grew these checks first, against its
/// own 1,663-line hostile-input suite. This file is the subset that pins them
/// here, in the published package — the one a vendoring consumer is meant to
/// switch to, which is not worth doing while switching loses the hardening.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

List<int> _u64(int v) {
  final b = ByteData(8);
  b.setUint32(0, v & 0xFFFFFFFF, Endian.little);
  b.setUint32(4, v >> 32, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _f64(double v) =>
    (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List();

List<int> _string(String s) {
  final raw = utf8.encode(s);
  return <int>[..._u32(raw.length), ...raw];
}

Uint8List _headerContent({
  String temporalModel = 'gaussian-birth',
  int shDegree = 0,
  double durationSec = 1.0,
  double cutoff = 0.05,
  int gaussianCount = 0,
}) {
  final body =
      BytesBuilder()
        ..add(_string('')) // profile
        ..add(_string('')) // library
        ..add(_f64(durationSec))
        ..add(_u64(gaussianCount))
        ..add(_f64(cutoff))
        ..add(_string(temporalModel));
  for (int i = 0; i < 6; i++) {
    body.add(_f64(0.0)); // aabb
  }
  body
    ..addByte(shDegree)
    ..addByte(0) // flags
    ..add(_u32(0)); // empty attribute map
  return body.toBytes();
}

Uint8List _windowTableContent({required double lo, required double hi}) {
  final body =
      BytesBuilder()
        ..add(_u32(1))
        ..add(_f64(lo))
        ..add(_f64(hi));
  return body.toBytes();
}

Uint8List _chunkIndexEntryContent({
  required double t0,
  required double t1,
  int gaussianCount = 1,
}) {
  final body =
      BytesBuilder()
        ..add(_f64(t0))
        ..add(_f64(t1))
        ..add(_u64(0)) // chunkOffset
        ..add(_u64(0)) // chunkLength
        ..add(_u32(gaussianCount))
        ..add(_u32(0)); // bandCount
  return body.toBytes();
}

void main() {
  group('the header refuses what nothing downstream re-checks', () {
    test('an SH degree outside the 0-3 registry is refused', () {
      // Out of range is not merely unknown. A decoded-byte budget prices an
      // unrecognised band at zero while the coefficient count keeps growing
      // with the degree, so a buffer sized from the first is not the scene the
      // second goes on to decode.
      expect(
        () => FourdgsHeader.parse(_headerContent(shDegree: 255)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsHeader.parse(_headerContent(shDegree: 4)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      for (final int ok in <int>[0, 1, 2, 3]) {
        expect(
          FourdgsHeader.parse(_headerContent(shDegree: ok)).shDegree,
          ok,
          reason: 'degree $ok must still parse',
        );
      }
    });

    test('a temporal model outside the registry is named, not assumed', () {
      expect(
        () => FourdgsHeader.parse(
          _headerContent(temporalModel: 'gaussian-birth-poly'),
        ),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
      expect(
        () => FourdgsHeader.parse(_headerContent(temporalModel: '')),
        throwsA(isA<FourdgsUnsupportedCodec>()),
      );
    });

    test('both models this build implements still parse', () {
      // `keyframe-delta` is legal and is read by its own path. Refusing it here
      // would make that reader unreachable, which is a different bug from the
      // one the check above exists for.
      expect(
        FourdgsHeader.parse(_headerContent()).temporalModel,
        'gaussian-birth',
      );
      expect(
        FourdgsHeader.parse(
          _headerContent(temporalModel: 'keyframe-delta'),
        ).temporalModel,
        'keyframe-delta',
      );
    });

    test('an open-ended scene declares +Infinity, and that is legal', () {
      // The finiteness rule the spec writes is about an audio source's duration
      // (§5.11), not the scene's. Neither reference writer rejects an infinite
      // scene duration, `[0, +Infinity)` seeks like any other half-open
      // interval, and §5.8 makes the last index `t1` the Header's duration — an
      // endpoint this reader already accepts as infinite. Refusing it here would
      // buy no safety and cost interoperability: a file the other five SDKs read
      // would be undecodable in Dart alone.
      expect(
        FourdgsHeader.parse(
          _headerContent(durationSec: double.infinity),
        ).durationSec,
        double.infinity,
      );
    });

    test('a NaN or negative duration is refused', () {
      for (final double bad in <double>[
        double.nan,
        double.negativeInfinity,
        -1.0,
        -0.0001,
      ]) {
        expect(
          () => FourdgsHeader.parse(_headerContent(durationSec: bad)),
          throwsA(isA<FourdgsMalformedFile>()),
          reason: 'duration $bad',
        );
      }
    });

    test('a zero-duration scene is still legal', () {
      // The NoData conformance fixture is exactly this shape.
      expect(
        FourdgsHeader.parse(_headerContent(durationSec: 0.0)).durationSec,
        0.0,
      );
    });

    test('a cutoff outside (0, 1] is refused', () {
      for (final double bad in <double>[
        double.nan,
        0.0,
        -0.1,
        1.0001,
        double.infinity,
      ]) {
        expect(
          () => FourdgsHeader.parse(_headerContent(cutoff: bad)),
          throwsA(isA<FourdgsMalformedFile>()),
          reason: 'cutoff $bad',
        );
      }
      expect(FourdgsHeader.parse(_headerContent(cutoff: 1.0)).cutoff, 1.0);
    });
  });

  group('a refusal names the byte, the value and the expectation', () {
    // AGENTS.md section 6: "A decoder that refuses a file says which byte, which
    // record, which value, and what was expected." A bare type is not a
    // diagnosis, and neither is a message that only says a value is invalid —
    // whoever is holding the hostile file has to be able to find it.

    void expectDiagnostic(
      void Function() parse, {
      required List<String> mentions,
    }) {
      try {
        parse();
        fail('expected a refusal');
      } on FourdgsException catch (e) {
        for (final String fragment in mentions) {
          expect(
            e.message,
            contains(fragment),
            reason: 'the diagnosis must mention "$fragment": ${e.message}',
          );
        }
      }
    }

    test('the header names the record, the byte, the value and the range', () {
      expectDiagnostic(
        () => FourdgsHeader.parse(_headerContent(durationSec: double.nan)),
        mentions: <String>['Header', 'byte', 'duration_sec', 'expected'],
      );
      expectDiagnostic(
        () => FourdgsHeader.parse(_headerContent(cutoff: 0.0)),
        mentions: <String>['Header', 'byte', 'cutoff', '(0, 1]'],
      );
      expectDiagnostic(
        () => FourdgsHeader.parse(_headerContent(shDegree: 9)),
        mentions: <String>['Header', 'byte', 'sh_degree', '0 through 3'],
      );
      expectDiagnostic(
        () => FourdgsHeader.parse(_headerContent(temporalModel: 'nope')),
        mentions: <String>[
          'Header',
          'byte',
          'temporal_model',
          'expected one of',
        ],
      );
    });

    test('the window table names the entry, the byte and the rule', () {
      expectDiagnostic(
        () => FourdgsWindowTable.parse(_windowTableContent(lo: 5.0, hi: 1.0)),
        mentions: <String>['Window Table', 'byte', 'expected'],
      );
    });

    test('the chunk index names the byte and what was expected', () {
      expectDiagnostic(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: double.nan, t1: 1.0),
        ),
        mentions: <String>['Chunk Index', 'byte', 'expected'],
      );
      expectDiagnostic(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 1.0, t1: 1.0),
        ),
        mentions: <String>['Chunk Index', 'byte', 'zero-width', 'expected'],
      );
    });
  });

  group('intervals that no instant can satisfy are refused', () {
    test('a NaN or inverted validity window is refused', () {
      expect(
        () => FourdgsWindowTable.parse(
          _windowTableContent(lo: double.nan, hi: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsWindowTable.parse(
          _windowTableContent(lo: 0.0, hi: double.nan),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsWindowTable.parse(_windowTableContent(lo: 5.0, hi: 1.0)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a degenerate zero-length window is still accepted', () {
      // `lo == hi` is a legitimate zero-duration scene, so it must not be swept
      // up alongside `lo > hi`.
      final FourdgsWindowTable table = FourdgsWindowTable.parse(
        _windowTableContent(lo: 2.0, hi: 2.0),
      );
      expect(table.windows.single.lo, table.windows.single.hi);
    });

    test('a NaN or inverted chunk-index interval is refused', () {
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: double.nan, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 5.0, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('an open-ended index interval is accepted', () {
      // Infinity compares fine under `t0 <= t < t1`, and the format does not
      // require these bounds to be finite — the Python and Rust parsers accept
      // both of these, so refusing them would make an open-ended index readable
      // everywhere except Dart. Verified against the Python parser directly.
      expect(
        FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 0.0, t1: double.infinity),
        ).t1,
        double.infinity,
      );
      expect(
        FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: double.negativeInfinity, t1: 1.0),
        ).t0,
        double.negativeInfinity,
      );
    });

    test('a nonempty chunk over a zero-width interval is refused', () {
      // The seek rule is half-open, so nothing can ever select this chunk — yet
      // its gaussians still count toward the file's total, which is how a scene
      // ends up permanently short of its own header.
      expect(
        () => FourdgsChunkIndexEntry.parse(
          _chunkIndexEntryContent(t0: 1.0, t1: 1.0),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a gaussian-birth entry cannot pose as a delta to dodge the guard', () {
      // The delta block is recognised by length and a leading byte, both of
      // which a hostile gaussian-birth file can supply. If the guard trusted
      // `kind` it would then check `liveCount` — zero here — and wave through
      // four gaussians no seek can reach. Only a keyframe-delta Header gives
      // `liveCount` that meaning, and this parser cannot see the Header, so it
      // checks whichever count is nonzero.
      final BytesBuilder body =
          BytesBuilder()
            ..add(_f64(1.0)) // t0
            ..add(_f64(1.0)) // t1 — zero width
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(4)) // gaussianCount: real content
            ..add(_u32(0)) // bandCount
            ..addByte(1) // kind: claims delta
            ..addByte(0) // deltaMode
            ..add(_u64(0)) // referenceOffset
            ..add(_u64(0)) // keyframeOffset
            ..add(_u32(0).sublist(0, 2)) // depth (u16)
            ..add(_u64(0)); // liveCount: zero, the field it wants checked
      expect(
        () => FourdgsChunkIndexEntry.parse(body.toBytes()),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a zero-width extended KEYFRAME with gaussians is refused', () {
      // An extended index carries both kinds. A keyframe counts its gaussians
      // the ordinary way and may leave `liveCount` at zero, so a rule that reads
      // `liveCount` whenever the block is present waves this one through — a
      // zero-width entry holding real content that no seek can ever select.
      final BytesBuilder body =
          BytesBuilder()
            ..add(_f64(1.0)) // t0
            ..add(_f64(1.0)) // t1 — zero width
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(4)) // gaussianCount: real content
            ..add(_u32(0)) // bandCount
            ..addByte(0) // kind: keyframe
            ..addByte(0) // deltaMode
            ..add(_u64(0)) // referenceOffset
            ..add(_u64(0)) // keyframeOffset
            ..add(_u32(0).sublist(0, 2)) // depth (u16)
            ..add(_u64(0)); // liveCount: zero, which is not the population here
      expect(
        () => FourdgsChunkIndexEntry.parse(body.toBytes()),
        throwsA(isA<FourdgsMalformedFile>()),
      );
    });

    test('a zero-change DELTA over a zero-width interval is refused', () async {
      // A delta entry's `gaussianCount` counts operations — births, deaths,
      // updates — not the population they compose to. A delta that changes
      // nothing carries zero operations over a live scene, so a rule written
      // against `gaussianCount` waves through exactly the unreachable state
      // chunk it is supposed to refuse. `liveCount` is the population.
      //
      // Which is why this is a READER test and not a record test. `liveCount`
      // means "population" only under a keyframe-delta Header; the record parser
      // recognises the appended block by length alone and cannot tell a delta
      // entry from a future revision's extra fields, so reading the field there
      // would refuse forward-compatible files. Both readers have the Header.
      final BytesBuilder entry =
          BytesBuilder()
            ..add(_f64(1.0)) // t0
            ..add(_f64(1.0)) // t1 — zero width
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(0)) // gaussianCount: no operations
            ..add(_u32(0)) // bandCount
            ..addByte(1) // kind: delta
            ..addByte(0) // deltaMode
            ..add(_u64(0)) // referenceOffset
            ..add(_u64(0)) // keyframeOffset
            ..add(_u32(0).sublist(0, 2)) // depth (u16)
            ..add(_u64(7)); // liveCount: seven gaussians nothing can reach

      // The record parser accepts it, and that is the point above.
      expect(FourdgsChunkIndexEntry.parse(entry.toBytes()).liveCount, 7);

      final BytesBuilder out =
          BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(temporalModel: 'keyframe-delta'),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()));
      final int summaryStart = out.length;
      out.add(_record(opChunkIndex, entry.toBytes()));
      final BytesBuilder footer =
          BytesBuilder()
            ..add(_u64(summaryStart))
            ..add(_u64(0))
            ..add(_u32(0)); // summaryCrc 0: not checked
      out
        ..add(_record(opFooter, footer.toBytes()))
        ..add(fourdgsMagic);
      final Uint8List bytes = out.toBytes();

      final Matcher zeroWidth = throwsA(
        isA<FourdgsMalformedFile>()
            .having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('zero-width interval'),
            )
            .having(
              (FourdgsMalformedFile e) => e.message,
              'names the record',
              allOf(
                contains('Chunk Index record at byte'),
                contains('entry 0 of'),
              ),
            ),
      );
      expect(
        () => readFourdgsBytes(bytes, recoverTruncated: false),
        zeroWidth,
        reason: 'streamed reader',
      );
      await expectLater(openFourdgsIndexed(FourdgsBytes(bytes)), zeroWidth);
    });

    test('the dedicated keyframe-delta opener applies the rule too', () {
      // Three reader paths reach a Chunk Index, and this one — the seeking
      // client's path — had no population check at all. A zero-change delta over
      // a zero-width interval reached composition, where the entry itself is
      // unreachable but the chunk metadata around it is not, so a midpoint
      // lookup could return a neighbouring state under this entry's heading.
      final BytesBuilder entry =
          BytesBuilder()
            ..add(_f64(2.0)) // t0
            ..add(_f64(2.0)) // t1 — zero width
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(0)) // gaussianCount: no operations
            ..add(_u32(0)) // bandCount
            ..addByte(1) // kind: delta
            ..addByte(0) // deltaMode
            ..add(_u64(0)) // referenceOffset
            ..add(_u64(0)) // keyframeOffset
            ..add(_u32(0).sublist(0, 2)) // depth (u16)
            ..add(_u64(7)); // liveCount: seven gaussians nothing can reach

      final BytesBuilder out =
          BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(temporalModel: 'keyframe-delta'),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()));
      final int summaryStart = out.length;
      out.add(_record(opChunkIndex, entry.toBytes()));
      final BytesBuilder footer =
          BytesBuilder()
            ..add(_u64(summaryStart))
            ..add(_u64(0))
            ..add(_u32(0));
      out
        ..add(_record(opFooter, footer.toBytes()))
        ..add(fourdgsMagic);

      expect(
        () => decodeKeyframeDeltaIndexed(out.toBytes()),
        throwsA(
          isA<FourdgsMalformedFile>()
              .having(
                (FourdgsMalformedFile e) => e.message,
                'message',
                contains('zero-width interval'),
              )
              .having(
                (FourdgsMalformedFile e) => e.message,
                'names the record',
                contains('Chunk Index record at byte'),
              ),
        ),
      );
    });

    test('an open-ended state chunk is composable without an instant', () {
      // `[0, +Infinity)` is a legal interval, and its midpoint is `+Infinity` —
      // an instant no half-open interval contains, including its own. Composing
      // by probing at the midpoint therefore could not find the very entry it
      // was asked about, so the indexed path refused a file the streamed path
      // reads. The chain is now built from the entry, with no instant involved.
      final FourdgsChunkIndexEntry open = FourdgsChunkIndexEntry.parse(
        _chunkIndexEntryContent(t0: 0.0, t1: double.infinity),
      );
      final List<FourdgsChunkIndexEntry> index = <FourdgsChunkIndexEntry>[open];
      expect(chainFrom(index, open), <FourdgsChunkIndexEntry>[open]);
      expect(
        () => chainFor(index, (open.t0 + open.t1) / 2.0),
        throwsA(isA<FourdgsMalformedFile>()),
        reason: 'the midpoint of an open-ended interval is not in it',
      );
      expect(chainFor(index, 0.0), <FourdgsChunkIndexEntry>[open]);
    });

    test('appended fields a future revision adds do not make an entry hostile', () {
      // The mirror of the test above. This is an EMPTY `gaussian-birth` entry
      // over a zero-width interval — legal, and skipped by every reader — that
      // carries 28 bytes of fields this revision does not define. Their content
      // is arbitrary, including at the offset where a keyframe-delta entry would
      // put `liveCount`. A parser that read that field without knowing the
      // Header would refuse a file written to a later revision of this format.
      final BytesBuilder entry =
          BytesBuilder()
            ..add(_f64(1.0)) // t0
            ..add(_f64(1.0)) // t1 — zero width, and empty, so legal
            ..add(_u64(0)) // chunkOffset
            ..add(_u64(0)) // chunkLength
            ..add(_u32(0)) // gaussianCount: empty
            ..add(_u32(0)) // bandCount
            ..addByte(9) // not a `kind` this revision defines
            ..addByte(9)
            ..add(_u64(0xDEADBEEF))
            ..add(_u64(0xFEEDFACE))
            ..add(_u32(0).sublist(0, 2))
            ..add(_u64(12345)); // whatever a later revision keeps here
      expect(FourdgsChunkIndexEntry.parse(entry.toBytes()).gaussianCount, 0);
    });

    test('an EMPTY chunk over a zero-width interval is still accepted', () {
      final FourdgsChunkIndexEntry entry = FourdgsChunkIndexEntry.parse(
        _chunkIndexEntryContent(t0: 1.0, t1: 1.0, gaussianCount: 0),
      );
      expect(entry.gaussianCount, 0);
    });
  });

  group('the static-asset shape stays decodable', () {
    // A glTF or USD import has no timeline: every SDK writes it as
    // `duration_sec = 0` with `win_hi = +infinity`, and the reference writer
    // emits one chunk-index entry just past zero. Hardening that refuses NaN
    // and inverted intervals must not sweep this up with them — doing so makes
    // the reference writers' own output undecodable, and no corpus variant
    // covers it, so nothing else here would notice.

    test('an infinite win_hi is accepted', () {
      final FourdgsWindowTable table = FourdgsWindowTable.parse(
        _windowTableContent(lo: 0.0, hi: double.infinity),
      );
      expect(table.windows.single.hi, double.infinity);
    });

    test('a NaN or inverted window is still refused', () {
      expect(
        () => FourdgsWindowTable.parse(
          _windowTableContent(lo: 0.0, hi: double.nan),
        ),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      expect(
        () => FourdgsWindowTable.parse(_windowTableContent(lo: 5.0, hi: 1.0)),
        throwsA(isA<FourdgsMalformedFile>()),
      );
      // A -infinity START is legal, not the mirror of an inverted window. The
      // reference encoders exclude both bounds from their finite-input check on
      // purpose, so `[-inf, 1)` — a gaussian that has always existed — is
      // conforming output this decoder has to read.
      expect(
        FourdgsWindowTable.parse(
          _windowTableContent(lo: double.negativeInfinity, hi: 1.0),
        ).windows.single.lo,
        double.negativeInfinity,
      );
    });

    test('a nonempty index entry at duration zero opens', () async {
      // The exact shape `fourdgs.write(g, 0.0)` produces: t1 just past zero, a
      // nonempty entry, and no scene clock to bound its end.
      final BytesBuilder out =
          BytesBuilder()
            ..add(fourdgsMagic)
            // The header's total must agree with the index, or the cross-check
            // refuses the file before the clock rule is reached — which is correct,
            // and would make this test about the wrong thing.
            ..add(
              _record(
                opHeader,
                _headerContent(durationSec: 0.0, gaussianCount: 1),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()))
            // The static window itself: [0, +infinity). A file that
            // declares gaussians must carry a Window Table, and this is
            // the one such a scene has.
            ..add(
              _record(
                opWindowTable,
                _windowTableContent(lo: 0.0, hi: double.infinity),
              ),
            );
      final int summaryStart = out.length;
      out.add(
        _record(opChunkIndex, _chunkIndexEntryContent(t0: 0.0, t1: 1e-9)),
      );
      final BytesBuilder footer =
          BytesBuilder()
            ..add(_u64(summaryStart))
            ..add(_u64(0))
            ..add(_u32(0));
      out
        ..add(_record(opFooter, footer.toBytes()))
        ..add(fourdgsMagic);
      final Uint8List bytes = out.toBytes();

      // Indexed only: this file carries front matter and an index but no
      // Chunk record, which the indexed opener never needs and the streamed
      // reader rightly refuses. The streamed path's clock rule reads the same
      // entry fields, covered by the entry-level test below.
      final FourdgsIndexedScene indexed = await openFourdgsIndexed(
        FourdgsBytes(bytes),
      );
      expect(indexed.header.durationSec, 0.0);
      expect(indexed.index.single.t1, 1e-9);
    });
  });

  group('an entry just past zero is not out of clock', () {
    test('a nonempty entry at duration zero parses', () {
      // The shape `fourdgs.write(g, 0.0)` emits for a static asset; both
      // readers apply their clock rule to exactly these fields.
      final FourdgsChunkIndexEntry entry = FourdgsChunkIndexEntry.parse(
        _chunkIndexEntryContent(t0: 0.0, t1: 1e-9),
      );
      expect(entry.t1, 1e-9);
      expect(entry.gaussianCount, 1);
    });
  });

  group('both openers agree about the header total', () {
    test('a keyframe-delta file is not measured with gaussian-birth arithmetic', () {
      // Under `keyframe-delta` the Header's `gaussian_count` is the number of
      // distinct ids in the sequence, not a sum over chunks — and this reader
      // steps over delta chunks entirely. Applying the gaussian-birth tally to
      // one would refuse a valid sequence whose second keyframe restates ids it
      // has already seen, for adding up differently to a total that was never a
      // sum. The gate is the temporal model, so a file declaring it is exempt.
      final BytesBuilder out =
          BytesBuilder()
            ..add(fourdgsMagic)
            ..add(
              _record(
                opHeader,
                _headerContent(
                  temporalModel: 'keyframe-delta',
                  gaussianCount: 9,
                ),
              ),
            )
            ..add(_record(opQuantization, _quantizationContent()));
      final BytesBuilder footer =
          BytesBuilder()
            ..add(_u64(0))
            ..add(_u64(0))
            ..add(_u32(0));
      out
        ..add(_record(opFooter, footer.toBytes()))
        ..add(fourdgsMagic);

      // No chunks at all, so a gaussian-birth tally would make this 0 against 9.
      final FourdgsScene scene = readFourdgsBytes(
        out.toBytes(),
        recoverTruncated: false,
      );
      expect(scene.header.gaussianCount, 9);
      expect(scene.header.temporalModel, 'keyframe-delta');
    });

    test(
      'an inflated header count is refused by the indexed opener too',
      () async {
        // The streamed reader compares the header against the chunks it
        // assembled. The indexed opener never touches a chunk, so its only
        // evidence is the index — and without this it returned a scene whose
        // header count was simply false, with every chunk readable and the CRC
        // verifying. One opener refusing and the other agreeing is the divergence
        // this whole area exists to remove.
        final BytesBuilder out =
            BytesBuilder()
              ..add(fourdgsMagic)
              ..add(_record(opHeader, _headerContent(gaussianCount: 9)))
              ..add(_record(opQuantization, _quantizationContent()))
              ..add(
                _record(opWindowTable, _windowTableContent(lo: 0.0, hi: 1.0)),
              );
        final int summaryStart = out.length;
        out.add(
          _record(opChunkIndex, _chunkIndexEntryContent(t0: 0.0, t1: 1.0)),
        );
        final BytesBuilder footer =
            BytesBuilder()
              ..add(_u64(summaryStart))
              ..add(_u64(0))
              ..add(_u32(0));
        out
          ..add(_record(opFooter, footer.toBytes()))
          ..add(fourdgsMagic);

        await expectLater(
          openFourdgsIndexed(FourdgsBytes(out.toBytes())),
          throwsA(
            isA<FourdgsMalformedFile>().having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('accounts for'),
            ),
          ),
        );
      },
    );
  });

  group('a zero-duration scene still has a start', () {
    test(
      'a nonempty entry beginning after zero is refused at duration zero',
      () async {
        // The static exception exists for `[0, >0)`, the shape the writers emit.
        // It is not a licence for any interval at all: with no clock length the
        // only instant a seek can ask for is 0, so `[500, 501)` holds gaussians
        // nothing can ever reach — the same unreachable content the bound exists
        // to refuse, hiding behind the exception.
        final BytesBuilder out =
            BytesBuilder()
              ..add(fourdgsMagic)
              ..add(
                _record(
                  opHeader,
                  _headerContent(durationSec: 0.0, gaussianCount: 1),
                ),
              )
              ..add(_record(opQuantization, _quantizationContent()))
              ..add(
                _record(
                  opWindowTable,
                  _windowTableContent(lo: 0.0, hi: double.infinity),
                ),
              );
        final int summaryStart = out.length;
        out.add(
          _record(opChunkIndex, _chunkIndexEntryContent(t0: 500.0, t1: 501.0)),
        );
        final BytesBuilder footer =
            BytesBuilder()
              ..add(_u64(summaryStart))
              ..add(_u64(0))
              ..add(_u32(0));
        out
          ..add(_record(opFooter, footer.toBytes()))
          ..add(fourdgsMagic);

        await expectLater(
          openFourdgsIndexed(FourdgsBytes(out.toBytes())),
          throwsA(
            isA<FourdgsMalformedFile>().having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('scene clock'),
            ),
          ),
        );
      },
    );
  });

  group('both openers agree about what is out of clock', () {
    test('an out-of-clock index entry is refused by the indexed opener too', () async {
      // Built rather than patched. Editing a real file's index invalidates the
      // summary CRC, and the indexed opener refuses on that FIRST — so a patched
      // fixture never reaches the clock bound and the test proves nothing. This
      // file declares `summaryCrc = 0`, which turns that check off, leaving the
      // clock bound as the only thing that can refuse it.
      final Uint8List indexRecord = _record(
        opChunkIndex,
        _chunkIndexEntryContent(
          t0: 500.0,
          t1: 501.0,
        ), // the scene clock is [0, 1)
      );
      final BytesBuilder out =
          BytesBuilder()
            ..add(fourdgsMagic)
            ..add(_record(opHeader, _headerContent()))
            ..add(_record(opQuantization, _quantizationContent()));
      final int summaryStart = out.length;
      out.add(indexRecord);
      final BytesBuilder footer =
          BytesBuilder()
            ..add(_u64(summaryStart))
            ..add(_u64(0))
            ..add(_u32(0)); // summaryCrc 0: not checked
      out
        ..add(_record(opFooter, footer.toBytes()))
        ..add(fourdgsMagic);
      final Uint8List bytes = out.toBytes();

      // Matched on the message, not merely the type: several other refusals are
      // also `FourdgsMalformedFile`, and a type-only assertion would pass
      // whether or not the clock bound exists — which is how the first version
      // of this test failed to notice the indexed opener had none.
      // The refusal has to be locatable, not merely correct: in a file with a
      // thousand index records, "an entry covers [500, 501)" tells whoever is
      // holding it nothing about where to look. Both readers know the record's
      // byte offset while parsing and must carry it this far.
      final Matcher outOfClock = throwsA(
        isA<FourdgsMalformedFile>()
            .having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('scene clock'),
            )
            .having(
              (FourdgsMalformedFile e) => e.message,
              'names the record',
              allOf(
                contains('Chunk Index record at byte'),
                contains('entry 0 of'),
              ),
            ),
      );
      expect(
        () => readFourdgsBytes(bytes, recoverTruncated: false),
        outOfClock,
        reason: 'streamed reader',
      );
      await expectLater(
        openFourdgsIndexed(FourdgsBytes(bytes)),
        outOfClock,
        reason: 'indexed opener must agree',
      );
    });
  });

  group('a short scene cannot hide behind a missing closing magic', () {
    test(
      'dropping only the trailing magic does not excuse a header/chunk mismatch',
      () {
        // The records all parse; only the closing magic is gone. That marks the
        // file truncated, but no later chunk could explain a mismatch — every
        // chunk the file has was decoded. Gating the cross-check on `truncated`
        // would let nine missing bytes wave a quietly short scene through.
        final Uint8List real =
            File(
              '../../tests/conformance/data/TenWindows-UseChunkIndex-UseCrc.4dgs',
            ).readAsBytesSync();

        // Inflate the header's gaussian count by one, so the file now claims one
        // more gaussian than its chunks assemble to.
        final Uint8List bytes = Uint8List.fromList(real);
        final int countOffset = _headerGaussianCountOffset(bytes);
        final ByteData view = ByteData.sublistView(
          bytes,
          countOffset,
          countOffset + 8,
        );
        final int declared = view.getUint32(0, Endian.little);
        view.setUint32(0, declared + 1, Endian.little);

        // Whole file: refused, as the check intends.
        expect(
          () => readFourdgsBytes(bytes, recoverTruncated: true),
          throwsA(isA<FourdgsMalformedFile>()),
        );

        // Same file with the closing magic dropped: still refused.
        final Uint8List clipped = Uint8List.sublistView(
          bytes,
          0,
          bytes.length - fourdgsMagic.length,
        );
        expect(
          () => readFourdgsBytes(clipped, recoverTruncated: true),
          throwsA(isA<FourdgsMalformedFile>()),
        );
      },
    );

    test(
      'a prefix that stops before the Footer still recovers rather than being refused',
      () {
        // The other half of the same rule, and the reason the gate is the Footer
        // rather than a clean walk. A file cut exactly at a record boundary walks
        // to its end without throwing, so "the walk did not run out" is true of it
        // — but no Footer was read, so more chunks were coming, and holding fewer
        // gaussians than the header promises is exactly what recovery means.
        // Refusing here would break the streaming contract for every partial read.
        final Uint8List real =
            File(
              '../../tests/conformance/data/TenWindows-UseChunkIndex-UseCrc.4dgs',
            ).readAsBytesSync();

        // Cut at the record boundary immediately BEFORE the first Chunk, so the
        // prefix is a clean walk that is genuinely missing gaussians. Cutting
        // anywhere after the chunks would leave the count already satisfied and
        // the case untested — which is exactly what a first attempt at this test
        // did, and it passed against the wrong gate.
        int offset = fourdgsMagic.length;
        while (offset + 9 <= real.length && real[offset] != 0x04) {
          final int length = ByteData.sublistView(
            real,
            offset + 1,
            offset + 9,
          ).getUint32(0, Endian.little);
          offset += 9 + length;
        }
        expect(
          offset,
          lessThan(real.length),
          reason: 'the fixture must contain a Chunk record',
        );
        final Uint8List prefix = Uint8List.sublistView(real, 0, offset);

        final FourdgsScene scene = readFourdgsBytes(
          prefix,
          recoverTruncated: true,
        );
        expect(
          scene.truncated,
          isTrue,
          reason: 'a prefix must come back reported as truncated',
        );
        expect(
          scene.gaussians.count,
          lessThan(scene.header.gaussianCount),
          reason: 'the prefix must really be short, or this pins nothing',
        );
      },
    );
  });
}

/// `u8 opcode`, `u64 length`, content — the framing every record shares.
Uint8List _record(int opcode, Uint8List content) {
  final BytesBuilder out =
      BytesBuilder()
        ..addByte(opcode)
        ..add(_u64(content.length))
        ..add(content);
  return out.toBytes();
}

/// The smallest Quantization record the readers accept: the scheme they
/// implement, a finite origin, and unit steps.
Uint8List _quantizationContent() {
  final BytesBuilder body = BytesBuilder()..add(_string('uniform-v1'));
  for (int i = 0; i < 3; i++) {
    body.add(_f64(0.0)); // pos origin
  }
  for (int i = 0; i < 8; i++) {
    body.add(_f64(1.0)); // step_pos .. step_sigma_log
  }
  body
    ..addByte(1) // step_sh
    ..add(_u32(0)); // empty bounds map
  return body.toBytes();
}

/// Byte offset of the Header's `gaussian_count`, found by walking the record
/// framing rather than assuming a layout.
int _headerGaussianCountOffset(Uint8List bytes) {
  int offset = fourdgsMagic.length;
  while (offset + 9 <= bytes.length) {
    final int opcode = bytes[offset];
    final ByteData lengthView = ByteData.sublistView(
      bytes,
      offset + 1,
      offset + 9,
    );
    final int length = lengthView.getUint32(0, Endian.little);
    if (opcode == 0x01) {
      // profile, library: each a u32 length followed by its bytes.
      int at = offset + 9;
      for (int i = 0; i < 2; i++) {
        final int n = ByteData.sublistView(
          bytes,
          at,
          at + 4,
        ).getUint32(0, Endian.little);
        at += 4 + n;
      }
      return at + 8; // past durationSec
    }
    offset += 9 + length;
  }
  throw StateError('no Header record found');
}
