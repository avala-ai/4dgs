// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The whole-file `keyframe-delta` decode: read a file two ways, agree.
///
/// A restatement of `python/fourdgs/tests/test_keyframe_delta_file.py`. The
/// load-bearing assertion is that the streamed and indexed read paths produce
/// the same canonical `states` — the reconstruction at an instant — because that
/// is the statement the other SDKs are diffed against.
///
/// The fixtures are `keyframe-delta` files written by the Python reference
/// (`keyframe_delta_file.write_sequence`) and embedded here as base64, so this
/// test needs no encoder — the Dart side is decode-only this milestone. The
/// exact-value cross-implementation parity against Python's `states_json` runs
/// in the conformance harness once the corpus carries a keyframe-delta variant;
/// what these unit tests own is agreement across the two Dart read paths, the
/// structural fields, and the depth-invariant error bound.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:test/test.dart';

Uint8List _bytes(String b64) => base64.decode(b64);

Map<String, Object?> _statesStreamed(String b64) =>
    keyframeDeltaStatesJson(decodeKeyframeDeltaStreamed(_bytes(b64)));

Map<String, Object?> _statesIndexed(String b64) =>
    keyframeDeltaStatesJson(decodeKeyframeDeltaIndexed(_bytes(b64)).sequence);

void main() {
  group('streamed and indexed agree', () {
    for (final entry
        in <String, String>{
          'chained': _movingChained,
          'keyframe': _movingKeyframe,
        }.entries) {
      test('delta_mode ${entry.key}', () {
        expect(
          jsonEncode(_statesStreamed(entry.value)),
          jsonEncode(_statesIndexed(entry.value)),
        );
      });
    }
  });

  test('the header declares the model and the distinct id count', () {
    final decoded = decodeKeyframeDeltaStreamed(_bytes(_movingChained));
    expect(decoded.header.temporalModel, 'keyframe-delta');
    // ids seen across the whole clip: 0, 1, 2, 3, 4.
    expect(decoded.header.gaussianCount, 5);
  });

  test('a wrong temporal model is refused on the keyframe-delta path', () {
    // A gaussian-birth file names a different model in its Header. The
    // keyframe-delta path must refuse it rather than mis-compose keyframe Chunks
    // as a whole population and silently skip the Delta Chunks it does not find.
    expect(
      () => decodeKeyframeDeltaStreamed(_bytes(_gaussianBirth)),
      throwsA(isA<FourdgsMalformedFile>()),
    );
  });

  test('a keyframe-only file is the frame-sequence shape', () {
    final summary = _statesStreamed(_keyframeOnly);
    final chunks = summary['chunks']! as List<Object?>;
    expect(
      chunks.every((Object? c) => (c! as Map)['kind'] == 'keyframe'),
      isTrue,
    );
    expect(
      chunks.every((Object? c) => (c! as Map)['deltaMode'] == null),
      isTrue,
    );
  });

  test('births and deaths move the population', () {
    final summary = _statesStreamed(_movingChained);
    final chunks = summary['chunks']! as List<Object?>;
    final live = <int>[
      for (final c in chunks) int.parse((c! as Map)['liveCount']! as String),
    ];
    // A birth of id 4 takes the population to 5; a death of id 2 drops it to 4.
    expect(live.reduce((a, b) => a > b ? a : b), 5);
    expect(live.reduce((a, b) => a < b ? a : b), 4);
  });

  test('a delta chunk reports its update, birth and death counts', () {
    final summary = _statesStreamed(_movingChained);
    final chunks = summary['chunks']! as List<Object?>;
    // Every delta row carries the split; every keyframe row carries null. A
    // field no row mentions is one an implementation can decline to decode.
    for (final c in chunks.cast<Map<Object?, Object?>>()) {
      if (c['kind'] == 'delta') {
        expect(c['updateCount'], isA<String>());
        expect(c['birthCount'], isA<String>());
        expect(c['deathCount'], isA<String>());
      } else {
        expect(c['updateCount'], isNull);
      }
    }
    // The sequence has both keyframes and deltas at keyframe_every=4.
    expect(chunks.any((Object? c) => (c! as Map)['kind'] == 'delta'), isTrue);
    expect(
      chunks.any((Object? c) => (c! as Map)['kind'] == 'keyframe'),
      isTrue,
    );
  });

  test('probe states are derived from the file', () {
    final summary = _statesStreamed(_movingChained);
    final chunks = summary['chunks']! as List<Object?>;
    final states = summary['states']! as List<Object?>;
    // Every chunk contributes its t0 and midpoint, plus one instant near the end.
    expect(states.length, greaterThanOrEqualTo(chunks.length));
    for (final s in states.cast<Map<Object?, Object?>>()) {
      final sample = s['sample']! as Map<Object?, Object?>;
      final positions = sample['positions']! as List<Object?>;
      expect(positions.isNotEmpty || s['liveCount'] == '0', isTrue);
    }
  });

  test('error does not grow with depth', () {
    // A long chain of small drifts reconstructs the last sample within the
    // declared bound: the composed bin at depth d IS the bin an absolute
    // statement would carry, so the error is the one-shot quantization error,
    // not d times it.
    final decoded = decodeKeyframeDeltaStreamed(_bytes(_deepChain));
    final deepest = decoded.chunks.last;
    expect(deepest.depth, decoded.chunks.length - 1); // a genuinely deep chain
    expect(deepest.kind, 1);

    final summary = keyframeDeltaStatesJson(decoded);
    final states =
        (summary['states']! as List<Object?>).cast<Map<Object?, Object?>>();
    // The probe nearest the end reconstructs against the deepest state.
    final last = states.last;
    final sample = last['sample']! as Map<Object?, Object?>;
    final firstPos =
        (sample['positions']! as List<Object?>).first as List<Object?>;
    final x = (firstPos.first as num).toDouble();
    final t = (last['t']! as num).toDouble();
    final steps = decoded.chunks.length;
    final trueX = 0.001 * (steps - 1);
    // Within one position pitch of the true value at the deepest frame — plus a
    // hair for the probe landing at duration-1e-6 rather than exactly t.
    final pitch = decoded.quantization.stepPos;
    expect((x - trueX).abs(), lessThanOrEqualTo(pitch + 1e-3));
    expect(t, greaterThan((steps - 2).toDouble()));
  });

  /// The byte offset of the last Chunk Index entry in [file], located by the
  /// interval it declares. The chunk states the same pair, so the later of the
  /// two occurrences is the index copy — the summary sits at the end of a file.
  int lastIndexEntry(Uint8List file, FourdgsChunkIndexEntry last) {
    final ByteData pair =
        ByteData(16)
          ..setFloat64(0, last.t0, Endian.little)
          ..setFloat64(8, last.t1, Endian.little);
    final Uint8List needle = pair.buffer.asUint8List();
    final List<int> hits = <int>[];
    for (int i = 0; i + needle.length <= file.length; i++) {
      bool same = true;
      for (int j = 0; j < needle.length; j++) {
        if (file[i + j] != needle[j]) {
          same = false;
          break;
        }
      }
      if (same) hits.add(i);
    }
    expect(hits, isNotEmpty);
    return hits.last;
  }

  test('the index and the chunks must agree about the population', () {
    // `live_count` is "gaussians live over [t0, t1), after composition" (§5.8),
    // stated in the index and again by the chunks it summarises. The spec calls
    // that duplication a cheap corruption check, and it is the only thing
    // between an entry declaring nothing and a payload composing to something —
    // the entry is not the file.
    final Uint8List original = _bytes(_movingChained);
    final result = decodeKeyframeDeltaIndexed(original);
    final last = result.index.last;
    expect(last.kind, 1, reason: 'the fixture ends on a delta');

    // liveCount is the last field of the appended block: t0, t1, chunkOffset,
    // chunkLength (8 each), gaussianCount, bandCount (4 each), kind, deltaMode
    // (1 each), referenceOffset, keyframeOffset (8 each), depth (2).
    final int at = lastIndexEntry(original, last);
    final int wrong = last.liveCount + 1;
    final Uint8List patched = Uint8List.fromList(original);
    ByteData.sublistView(patched).setUint64(at + 60, wrong, Endian.little);
    expect(
      FourdgsChunkIndexEntry.parse(
        Uint8List.sublistView(patched, at, at + 68),
      ).liveCount,
      wrong,
      reason: 'the patch landed on liveCount',
    );

    expect(
      () => decodeKeyframeDeltaIndexed(patched),
      throwsA(
        isA<FourdgsMalformedFile>()
            .having(
              (FourdgsMalformedFile e) => e.message,
              'message',
              contains('composes to ${last.liveCount}'),
            )
            .having(
              (FourdgsMalformedFile e) => e.message,
              'names what was declared',
              contains('declares $wrong live gaussians'),
            ),
      ),
    );
  });

  test('a keyframe states its live_count too, and it has to be true', () {
    // §5.8 defines `live_count` for every extended entry as the population after
    // composition, and the reference writers set it on keyframes as well as on
    // deltas. Checking only the field the population rule selects would let a
    // corrupt one through on exactly the entries where the other field agrees.
    final Uint8List original = _bytes(_keyframeOnly);
    final result = decodeKeyframeDeltaIndexed(original);
    final last = result.index.last;
    expect(last.kind, 0, reason: 'this fixture is keyframes only');
    expect(
      last.liveCount,
      result.sequence.chunks.last.state.count,
      reason: 'the writer states it for keyframes',
    );

    final int at = lastIndexEntry(original, last);
    final Uint8List patched = Uint8List.fromList(original);
    ByteData.sublistView(
      patched,
    ).setUint64(at + 60, last.liveCount + 1, Endian.little);
    expect(
      () => decodeKeyframeDeltaIndexed(patched),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.message,
          'message',
          contains('live_count ${last.liveCount + 1} for a keyframe'),
        ),
      ),
    );
  });

  test('an open-ended scene is probed only at instants that exist', () {
    // `durationSec - 1e-6` is still `+Infinity` for an open-ended scene. No
    // half-open interval contains that instant, so reconstruction found nothing
    // and the summary reported a nonempty scene as an empty state at a null
    // time — a wrong answer rather than a refusal, which is the worse kind.
    final Uint8List original = _bytes(_movingChained);
    final result = decodeKeyframeDeltaIndexed(original);

    final Uint8List patched = Uint8List.fromList(original);
    final ByteData view = ByteData.sublistView(patched);
    // The Header's duration_sec, checked against the parsed value before it is
    // overwritten so that a layout change fails here rather than patching some
    // unrelated byte into infinity.
    const int durationAt = 61;
    expect(
      view.getFloat64(durationAt, Endian.little),
      result.sequence.header.durationSec,
    );
    view.setFloat64(durationAt, double.infinity, Endian.little);
    // And the last chunk runs to that end. The index entry is what the probe
    // list is derived from, so it is the one that has to say `+Infinity`.
    view.setFloat64(
      lastIndexEntry(original, result.index.last) + 8,
      double.infinity,
      Endian.little,
    );

    final reopened = decodeKeyframeDeltaIndexed(patched);
    expect(reopened.sequence.header.durationSec, double.infinity);

    final Map<String, Object?> summary = keyframeDeltaStatesJson(
      reopened.sequence,
    );
    final List<Object?> states = summary['states']! as List<Object?>;
    expect(states, isNotEmpty);
    for (final Object? state in states) {
      final Map<Object?, Object?> row = state! as Map<Object?, Object?>;
      expect((row['t']! as num).toDouble().isFinite, isTrue);
    }
  });

  test('a chunk kind this build cannot place is refused', () {
    // Two kinds are defined: 0 keyframe, 1 delta. A third is not a
    // forward-compatible extension — it is a chunk that cannot be put in a
    // chain, and the population rule and the composer used to disagree about
    // which of the two it resembled.
    final Uint8List original = _bytes(_movingChained);
    final result = decodeKeyframeDeltaIndexed(original);
    final int at = lastIndexEntry(original, result.index.last);
    final Uint8List patched = Uint8List.fromList(original);
    patched[at + 40] = 2; // kind
    expect(
      () => decodeKeyframeDeltaIndexed(patched),
      throwsA(
        isA<FourdgsMalformedFile>().having(
          (FourdgsMalformedFile e) => e.message,
          'message',
          contains('chunk_kind 2'),
        ),
      ),
    );
  });

  test('an open-ended final state chunk composes on the indexed path', () {
    // `[t, +Infinity)` is a legal interval — the format puts no finiteness
    // requirement on a scene's end — and its midpoint is `+Infinity`, an instant
    // no half-open interval contains, its own included. Composing each chunk by
    // probing at its midpoint therefore failed to find the chunk it was already
    // holding, and the indexed path refused a file the streamed path reads. The
    // chain is built from the entry now; nothing here invents an instant.
    final Uint8List original = _bytes(_movingChained);
    final result = decodeKeyframeDeltaIndexed(original);
    final last = result.index.last;

    // Located by its interval rather than by a hardcoded offset: the pair is
    // the first sixteen bytes of the last Chunk Index entry, and asserting it
    // occurs exactly once is what makes the patch below unambiguous.
    final ByteData pair =
        ByteData(16)
          ..setFloat64(0, last.t0, Endian.little)
          ..setFloat64(8, last.t1, Endian.little);
    final Uint8List needle = pair.buffer.asUint8List();
    final List<int> hits = <int>[];
    for (int i = 0; i + needle.length <= original.length; i++) {
      bool same = true;
      for (int j = 0; j < needle.length; j++) {
        if (original[i + j] != needle[j]) {
          same = false;
          break;
        }
      }
      if (same) hits.add(i);
    }
    // Twice: a chunk states its own interval and the index restates it. A real
    // open-ended file has `+Infinity` in both, so both are patched — leaving one
    // finite would be testing a file no writer produces.
    expect(hits, hasLength(2), reason: 'the chunk and the index entry');

    final Uint8List patched = Uint8List.fromList(original);
    for (final int at in hits) {
      ByteData.sublistView(
        patched,
      ).setFloat64(at + 8, double.infinity, Endian.little);
    }

    final reopened = decodeKeyframeDeltaIndexed(patched);
    expect(reopened.index.last.t1, double.infinity);
    // Composed, not merely parsed: the same population the finite file reaches.
    expect(
      reopened.sequence.chunks.last.state.count,
      result.sequence.chunks.last.state.count,
    );

    // And the summary asks about instants that exist. Probe times are derived
    // from each chunk's interval, so an open-ended chunk contributed a midpoint
    // of `+Infinity` — a time no chunk covers, answered by falling back to the
    // last one. The interval is still probed at its `t0`.
    final Map<String, Object?> summary = keyframeDeltaStatesJson(
      reopened.sequence,
    );
    final List<Object?> states = summary['states']! as List<Object?>;
    for (final Object? state in states) {
      final double t =
          ((state! as Map<Object?, Object?>)['t']! as num).toDouble();
      expect(t.isFinite, isTrue, reason: 'probed at $t');
    }
  });

  test('the indexed path walks a chain to every chunk', () {
    final result = decodeKeyframeDeltaIndexed(_bytes(_movingChained));
    // The index tiles the timeline and every entry composed to a live
    // population; the deepest delta's chain length matches its declared depth,
    // which chainFor already asserts, so reaching here is the check.
    expect(result.index.length, result.sequence.chunks.length);
    expect(result.sequence.chunks.every((c) => c.state.count >= 4), isTrue);
  });
}

const String _movingChained =
    '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';

const String _movingKeyframe =
    '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';

const String _keyframeOnly =
    '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'
    'REdTMQ0K';

const String _deepChain =
    'iTRER1MxDQoBjAAAAAAAAAAHAAAAZGVmYXVsdB0AAAA0ZGdzIGtleWZyYW1lLWRlbHRhIHJlZmVy'
    'ZW5jZQAAAAAAACRAAQAAAAAAAACamZmZmZmpPw4AAABrZXlmcmFtZS1kZWx0YQAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAICXboI/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAANAAQAAAAAAAAoAAAB1'
    'bmlmb3JtLXYxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAzczMTOF6dD/xp3LSI0ekP/yp8dJNYnA/'
    'EBAQEBAQgD8QEBAQEBCAP83MzEzheoQ//Knx0k1icD/xp3LSI0ekPwHVAAAABQAAAGFscGhhEwAA'
    'ADAuMDAzOTIxNTY4NjI3NDUwOTgGAAAAbW90aW9uFAAAADAuMDA1MDAwMDAwMDc0NTA1ODA2AwAA'
    'AHBvcxQAAAAwLjAwMjUwMDAwMDAzNzI1MjkwMwMAAAByZ2ITAAAAMC4wMDM5MjE1Njg2Mjc0NTA5'
    'OAMAAAByb3QFAAAAMC4wMDIJAAAAc2NhbGVfcmVsBAAAADAuMDICAAAAc2gBAAAAMAkAAABzaWdt'
    'YV9yZWwEAAAAMC4wMgQAAAB0aW1lBQAAADAuMDAyBBQAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAA'
    'JEAFbgEAAAAAAAAAAAAAAAAAAAAAAAAAAPA/AAAAAAEAAAAAAAAAQgEAAAAAAABCAQAAAAAAAA0B'
    'AAABAQAAAAkAAAAAAAAAeJxjAAAAAQABAAEAAAMBAAAACwAAAAAAAAB4nGNgYAAAAAMAAQEBAAAD'
    'AQAAAAsAAAAAAAAAeJybPn06AAONAcYCAQAAAQEAAAAJAAAAAAAAAHicYwMAAAcABwMBAAADAQAA'
    'AAsAAAAAAAAAeJxjYGAAAAADAAEEAQAAAwEAAAALAAAAAAAAAHicSzMxBAABzgDMBQEAAAEBAAAA'
    'CQAAAAAAAAB4nHsGAADnAOcGAQAAAwEAAAALAAAAAAAAAHicY2BgAAAAAwABBwEAAAEBAAAACQAA'
    'AAAAAAB4nGMAAAABAAEIAQAAAQEAAAAJAAAAAAAAAHicewEAAOkA6QkBAAABAQAAAAkAAAAAAAAA'
    'eJxjAAAAAQABCgEAAAEBAAAACQAAAAAAAAB4nGMAAAABAAEQXwAAAAAAAAAAAAAAAADwPwAAAAAA'
    'AABAAAAAAAEDAgAAAAAAAAMCAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAYAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBfAAAAAAAAAAAAAAAAAABAAAAAAAAACEAAAAAAAXoD'
    'AAAAAAAAAwIAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAYAAAAAAAAABgAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAEFMBAAAAAAAAAAAAAAAACEAAAAAAAAAQQAAAAAAB4gMAAAAAAAADAgAA'
    'AAAAAAMAAQAAAAAAAAAAAAAAAAAAAAwBAAAAAAAADAEAAAAAAAD0AAAAAAAAAA0BAAABAQAAAAkA'
    'AAAAAAAAeJxjAAAAAQABAAEAAAMBAAAACwAAAAAAAAB4nGNiYAAAAAkAAwEBAAADAQAAAAsAAAAA'
    'AAAAeJxjYGAAAAADAAECAQAAAQEAAAAJAAAAAAAAAHicYwMAAAcABwMBAAADAQAAAAsAAAAAAAAA'
    'eJxjYGAAAAADAAEEAQAAAwEAAAALAAAAAAAAAHicY2BgAAAAAwABBQEAAAEBAAAACQAAAAAAAAB4'
    'nGMAAAABAAEGAQAAAwEAAAALAAAAAAAAAHicY2BgAAAAAwABBwEAAAEBAAAACQAAAAAAAAB4nGMA'
    'AAABAAEAAAAAAAAAAAAAAAAAAAAAEF8AAAAAAAAAAAAAAAAAEEAAAAAAAAAUQAAAAAABSgQAAAAA'
    'AAADAgAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAABgAAAAAAAAAGAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAQXwAAAAAAAAAAAAAAAAAUQAAAAAAAABhAAAAAAAGmBQAAAAAAAAMCAAAAAAAA'
    'BQAAAAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'ABBfAAAAAAAAAAAAAAAAABhAAAAAAAAAHEAAAAAAAQ4GAAAAAAAAAwIAAAAAAAAGAAAAAAAAAAAA'
    'AAAAAAAAAAAYAAAAAAAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEF8AAAAAAAAA'
    'AAAAAAAAHEAAAAAAAAAgQAAAAAABdgYAAAAAAAADAgAAAAAAAAcAAAAAAAAAAAAAAAAAAAAAABgA'
    'AAAAAAAAGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQUwEAAAAAAAAAAAAAAAAgQAAA'
    'AAAAACJAAAAAAAHeBgAAAAAAAAMCAAAAAAAACAABAAAAAAAAAAAAAAAAAAAADAEAAAAAAAAMAQAA'
    'AAAAAPQAAAAAAAAADQEAAAEBAAAACQAAAAAAAAB4nGMAAAABAAEAAQAAAwEAAAALAAAAAAAAAHic'
    'Y2JgAAAACQADAQEAAAMBAAAACwAAAAAAAAB4nGNgYAAAAAMAAQIBAAABAQAAAAkAAAAAAAAAeJxj'
    'AwAABwAHAwEAAAMBAAAACwAAAAAAAAB4nGNgYAAAAAMAAQQBAAADAQAAAAsAAAAAAAAAeJxjYGAA'
    'AAADAAEFAQAAAQEAAAAJAAAAAAAAAHicYwAAAAEAAQYBAAADAQAAAAsAAAAAAAAAeJxjYGAAAAAD'
    'AAEHAQAAAQEAAAAJAAAAAAAAAHicYwAAAAEAAQAAAAAAAAAAAAAAAAAAAAAQXwAAAAAAAAAAAAAA'
    'AAAiQAAAAAAAACRAAAAAAAFGBwAAAAAAAAMCAAAAAAAACQAAAAAAAAAAAAAAAAAAAAAAGAAAAAAA'
    'AAAYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAhEAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    '8D8DAgAAAAAAAHcBAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAwIAAAAAAAAAAAEAAAAAAAAACEQA'
    'AAAAAAAAAAAAAAAA8D8AAAAAAAAAQHoDAAAAAAAAaAAAAAAAAAAAAAAAAAAAAAEBAwIAAAAAAAAD'
    'AgAAAAAAAAEAAQAAAAAAAAAIRAAAAAAAAAAAAAAAAAAAQAAAAAAAAAhA4gMAAAAAAABoAAAAAAAA'
    'AAAAAAAAAAAAAQF6AwAAAAAAAAMCAAAAAAAAAgABAAAAAAAAAAhEAAAAAAAAAAAAAAAAAAhAAAAA'
    'AAAAEEBKBAAAAAAAAFwBAAAAAAAAAQAAAAAAAAABAeIDAAAAAAAAAwIAAAAAAAADAAEAAAAAAAAA'
    'CEQAAAAAAAAAAAAAAAAAEEAAAAAAAAAUQKYFAAAAAAAAaAAAAAAAAAAAAAAAAAAAAAEBSgQAAAAA'
    'AAADAgAAAAAAAAQAAQAAAAAAAAAIRAAAAAAAAAAAAAAAAAAUQAAAAAAAABhADgYAAAAAAABoAAAA'
    'AAAAAAAAAAAAAAAAAQGmBQAAAAAAAAMCAAAAAAAABQABAAAAAAAAAAhEAAAAAAAAAAAAAAAAABhA'
    'AAAAAAAAHEB2BgAAAAAAAGgAAAAAAAAAAAAAAAAAAAABAQ4GAAAAAAAAAwIAAAAAAAAGAAEAAAAA'
    'AAAACEQAAAAAAAAAAAAAAAAAHEAAAAAAAAAgQN4GAAAAAAAAaAAAAAAAAAAAAAAAAAAAAAEBdgYA'
    'AAAAAAADAgAAAAAAAAcAAQAAAAAAAAAIRAAAAAAAAAAAAAAAAAAgQAAAAAAAACJARgcAAAAAAABc'
    'AQAAAAAAAAEAAAAAAAAAAQHeBgAAAAAAAAMCAAAAAAAACAABAAAAAAAAAAhEAAAAAAAAAAAAAAAA'
    'ACJAAAAAAAAAJECiCAAAAAAAAGgAAAAAAAAAAAAAAAAAAAABAUYHAAAAAAAAAwIAAAAAAAAJAAEA'
    'AAAAAAAADEQAAAAAAAAAAQAAAAAAAAAKAAAAAAAAAAAAJEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAACAl26CPwAAAAAAAAAAAAAAAAAAAAACFAAAAAAAAAAKCQAAAAAAAAAAAAAAAAAAbsNY04k0'
    'REdTMQ0K';

/// A gaussian-birth file (corpus NoData), for the temporal-model gate.
const String _gaussianBirth =
    'iTRER1MxDQoBiQAAAAAAAAAHAAAAY2FwdHVyZRoAAAA0ZGdzIGNvbmZvcm1hbmNlIGdlbmVyYXRv'
    'cgAAAAAAAAAAAAAAAAAAAACamZmZmZmpPw4AAABnYXVzc2lhbi1iaXJ0aAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMjAQAAAAAAAAoAAAB1bmlm'
    'b3JtLXYxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALUMc6+I2Gj/xp3LSI0ekP/yp8dJNYnA/EBAQ'
    'EBAQgD8QEBAQEBCAPy1DHOviNio//Knx0k1icD/xp3LSI0ekPwG4AAAABQAAAGFscGhhEwAAADAu'
    'MDAzOTIxNTY4NjI3NDUwOTgGAAAAbW90aW9uBgAAADAuMDAwMQMAAABwb3MFAAAANWUtMDUDAAAA'
    'cmdiEwAAADAuMDAzOTIxNTY4NjI3NDUwOTgDAAAAcm90BQAAADAuMDAyCQAAAHNjYWxlX3JlbAQA'
    'AAAwLjAyAgAAAHNoAQAAADAJAAAAc2lnbWFfcmVsBAAAADAuMDIEAAAAdGltZQUAAAAwLjAwMgQU'
    'AAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAhQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACJ'
    'NERHUzENCg==';
