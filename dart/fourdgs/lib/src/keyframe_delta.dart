// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The `keyframe-delta` temporal model: composition, the two read paths, and the
/// reconstruction-at-an-instant the whole model exists to make cheap.
///
/// State at time `t` is the nearest previous keyframe with the deltas between it
/// and `t` composed onto it. Everything up to composition is **quantization
/// bins**, never values, and that is the single load-bearing decision:
///
///     A delta is a difference of bins, never a quantization of a difference.
///
/// The keyframe stores `b0 = q(x0)`; delta `j` stores the integer
/// `q(xj) - q(x_{j-1})`; the composition telescopes over integers, so the
/// composed bin *is* `q(x_d)` — the bin an absolute statement of that instant
/// would carry. The declared error bound therefore holds at any depth, and
/// dequantization is the same arithmetic a keyframe uses (spec §11.7).
///
/// Two read paths are provided because agreeing across them is most of what makes
/// an implementation trustworthy:
///
/// * [decodeKeyframeDeltaStreamed] walks the file front to back, composing each
///   chunk onto the last;
/// * [decodeKeyframeDeltaIndexed] reads the index and, for an instant, walks only
///   that instant's chain.
///
/// [keyframeDeltaStatesJson] is the statement other SDKs are diffed against: the
/// composed population reconstructed at an instant, in `gaussian_id` order, with
/// integers as strings so a 64-bit value survives a double-backed JSON parser.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'exceptions.dart';
import 'opcode.dart';
import 'quantization.dart';
import 'readable.dart';
import 'records.dart';
import 'serialization.dart';

/// Composed bins are signed 32-bit. Not a limit anyone meets — at a millimetre
/// grid it spans about 2,000 km — but stated so two decoders in two languages
/// agree on where the boundary is rather than one finding it on a 64-bit
/// accumulator and the other on a 32-bit one. Overflow is refused, never
/// wrapped: a wrapped position bin is a gaussian at a plausible-looking wrong
/// place, which is the failure the bounds contract exists to make impossible.
const int keyframeDeltaBinMin = -2147483648;
const int keyframeDeltaBinMax = 2147483647;

/// Attributes a delta's update group MUST NOT carry. The per-gaussian grids for
/// velocity and birth time are derived from these three, so a bin difference
/// across a change in any of them is a difference between bins on two different
/// grids — a number with no interpretation (spec §11.5).
const Set<int> keyframeDeltaGopInvariant = <int>{
  attrSigmaT,
  attrFlags,
  attrWindowIndex,
};

/// Attributes an update restates outright rather than differencing. The
/// smallest-three rotation coding omits the largest-magnitude component, so the
/// three stored bins mean different components either side of a change; a
/// rotating object crosses that boundary constantly, so rotation is restated.
const Set<int> keyframeDeltaAbsoluteInUpdate = <int>{
  attrRotationIndex,
  attrRotation,
};

/// One attribute's bins for a whole population: [channels] per gaussian, packed
/// `values[i * channels + c]`.
class _Column {
  _Column(this.channels, this.values);

  final int channels;
  final Int32List values;

  int get rows => channels == 0 ? 0 : values.length ~/ channels;
}

/// A composed population: identities, and one bin column per attribute.
///
/// [ids] and every column are aligned, and the order is an implementation detail
/// — nothing in the format depends on it and no reader may rely on it. The bins
/// stay private: a consumer reads reconstructed gaussians through
/// [keyframeDeltaStatesJson], not raw composed bins.
class KeyframeDeltaState {
  KeyframeDeltaState._(this.ids, this._bins);

  final Int32List ids;
  final Map<int, _Column> _bins;

  int get count => ids.length;

  /// Whether this composed population carries [attribute].
  ///
  /// Validators use this to enforce profile promises without exposing the
  /// private bin storage or reconstructing the population to floating point.
  bool hasAttribute(int attribute) => _bins.containsKey(attribute);

  /// Every `window_index` this state names, against the file's Window Table.
  ///
  /// Composition is arithmetic on bins and never looks a window up, so a state
  /// that names a window the file does not carry composes perfectly well; the
  /// range check happens later, when reconstruction asks the grid for the
  /// window. A caller that composes without reconstructing — a validator, which
  /// only wants to know whether the file decodes — would therefore call a file
  /// valid that reconstruction refuses. This is that check, on its own, so it
  /// can be made without dequantizing a population.
  ///
  /// The refusal is the shared one, so the identifier and the sentence are what
  /// reconstruction would have produced for the same file.
  void checkWindows(List<FourdgsWindow> windows) {
    if (count == 0) return;
    final column = _bins[attrWindowIndex];
    if (column == null) {
      throw const FourdgsMalformedFile(
        'a non-empty state carries no window_index column; it is a required '
        'keyframe attribute (section 11.5)',
      );
    }
    // An absent or empty table is one default (0, 0) window, exactly as
    // reconstruction reads it — so index 0 resolves against it and nothing else
    // does.
    final int length = windows.isEmpty ? 1 : windows.length;
    for (int i = 0; i < count; i++) {
      final int index = column.values[i];
      if (index < 0 || index >= length) {
        // The same builder the grid lookups use, so one refusal has one
        // spelling however it was reached.
        throw windowIndexOutOfRange(
          index,
          length,
          gaussian: _Grids._named(ids[i]),
        );
      }
    }
  }
}

/// The state a keyframe chunk states outright, with its identities checked.
KeyframeDeltaState _keyframeState(Int32List ids, Map<int, _Column> bins) {
  _checkUnique(ids, 'a keyframe');
  bins.forEach((int attribute, _Column column) {
    if (column.rows != ids.length) {
      throw FourdgsMalformedFile(
        'attribute $attribute carries ${column.rows} rows, the keyframe declares ${ids.length} gaussians',
      );
    }
  });
  return KeyframeDeltaState._(ids, bins);
}

/// Composes one delta onto the state it references.
///
/// Deaths, then updates, then births. The order is normative because a chunk
/// that both kills and creates would otherwise be ambiguous — and an id may
/// appear in only one of the three groups, so the order decides nothing a file
/// is allowed to depend on. It is fixed anyway, because "nothing depends on it"
/// is a claim a reader should not have to take on trust from a file it did not
/// write (spec §11.4).
KeyframeDeltaState _applyDelta(
  KeyframeDeltaState state, {
  required Int32List updateIds,
  required Map<int, _Column> updateBins,
  required Int32List birthIds,
  required Map<int, _Column> birthBins,
  required Int32List deathIds,
}) {
  _checkGroupsDisjoint(updateIds, birthIds, deathIds);
  _checkUnique(updateIds, 'an update group');
  _checkUnique(birthIds, 'a birth group');
  _checkUnique(deathIds, 'a death group');

  for (final attribute in updateBins.keys) {
    if (keyframeDeltaGopInvariant.contains(attribute)) {
      throw FourdgsMalformedFile(
        'an update carries attribute $attribute, which is fixed for a gaussian\'s '
        'lifetime within a group: the per-gaussian grids for velocity and birth '
        'time are derived from it, so a bin difference across a change in it has '
        'no defined meaning',
      );
    }
  }

  // --- deaths -----------------------------------------------------------
  Int32List ids = state.ids;
  Map<int, _Column> bins = state._bins;
  if (deathIds.isNotEmpty) {
    final live = <int>{for (final id in ids) id};
    for (final id in deathIds) {
      if (!live.contains(id)) {
        throw FourdgsMalformedFile(
          'a delta kills gaussian id $id, which is not live at its reference',
        );
      }
    }
    final dying = <int>{for (final id in deathIds) id};
    final keep = <int>[
      for (int i = 0; i < ids.length; i++)
        if (!dying.contains(ids[i])) i,
    ];
    ids = Int32List.fromList(<int>[for (final i in keep) ids[i]]);
    bins = <int, _Column>{
      for (final entry in bins.entries)
        entry.key: _selectRows(entry.value, keep),
    };
  } else {
    // Copied because updates mutate columns in place, and the reference must not
    // change under a sibling chunk that also composes onto it.
    bins = <int, _Column>{
      for (final entry in bins.entries)
        entry.key: _Column(
          entry.value.channels,
          Int32List.fromList(entry.value.values),
        ),
    };
  }

  // --- updates ----------------------------------------------------------
  if (updateIds.isNotEmpty) {
    final rowOf = <int, int>{for (int i = 0; i < ids.length; i++) ids[i]: i};
    final rows = <int>[];
    for (final id in updateIds) {
      final row = rowOf[id];
      if (row == null) {
        throw FourdgsMalformedFile(
          'a delta updates gaussian id $id, which is not live at its reference',
        );
      }
      rows.add(row);
    }
    updateBins.forEach((int attribute, _Column delta) {
      if (delta.rows != updateIds.length) {
        throw FourdgsMalformedFile(
          'attribute $attribute carries ${delta.rows} rows, the update group declares ${updateIds.length}',
        );
      }
      final target = bins[attribute];
      if (target == null) {
        throw FourdgsMalformedFile(
          'an update touches attribute $attribute, which the referenced state does not carry',
        );
      }
      if (target.channels != delta.channels) {
        throw FourdgsMalformedFile(
          'an update carries ${delta.channels} channels for attribute '
          '$attribute, but its referenced column carries ${target.channels}',
        );
      }
      final ch = target.channels;
      final absolute = keyframeDeltaAbsoluteInUpdate.contains(attribute);
      for (int r = 0; r < rows.length; r++) {
        final dst = rows[r] * ch;
        final src = r * ch;
        for (int c = 0; c < ch; c++) {
          if (absolute) {
            target.values[dst + c] = delta.values[src + c];
          } else {
            final composed = target.values[dst + c] + delta.values[src + c];
            if (composed < keyframeDeltaBinMin ||
                composed > keyframeDeltaBinMax) {
              throw FourdgsMalformedFile(
                'composing attribute $attribute for gaussian id ${updateIds[r]} '
                'leaves the signed 32-bit range a composed bin must stay inside',
              );
            }
            target.values[dst + c] = composed;
          }
        }
      }
    });
  }

  // --- births -----------------------------------------------------------
  if (birthIds.isNotEmpty) {
    final live = <int>{for (final id in ids) id};
    for (final id in birthIds) {
      if (live.contains(id)) {
        throw FourdgsMalformedFile(
          'a delta creates gaussian id $id, which is already live; ids are unique '
          'within a state and are not reused after a death',
        );
      }
    }
    // Every attribute the referenced state carries, not only the required ones.
    // A birth is absolute state: if the state it joins has an `object_id` — or
    // a `source_group`, or a `source_index` — then a birth that omits it is not
    // saying "background", it is failing to say anything, and zero-filling it
    // invents a membership the file never declared. Python, Rust and TypeScript
    // all refuse this as `incomplete-birth`; narrowing it to the required list
    // made the same bytes decode here and refuse there.
    final absent = <int>[
      for (final attribute in bins.keys)
        if (!birthBins.containsKey(attribute)) attribute,
    ]..sort();
    if (absent.isNotEmpty) {
      throw FourdgsMalformedFile(
        'a birth group carries no value for attributes $absent; a birth is '
        'absolute state, not a delta',
      );
    }
    birthBins.forEach((int attribute, _Column column) {
      if (column.rows != birthIds.length) {
        throw FourdgsMalformedFile(
          'attribute $attribute carries ${column.rows} rows, the birth group declares ${birthIds.length}',
        );
      }
    });

    final attributes = <int>{...bins.keys, ...birthBins.keys};
    final grownIds =
        Int32List(ids.length + birthIds.length)
          ..setRange(0, ids.length, ids)
          ..setRange(ids.length, ids.length + birthIds.length, birthIds);
    final grown = <int, _Column>{};
    for (final attribute in attributes) {
      final existing = bins[attribute];
      final added = birthBins[attribute];
      if (existing != null &&
          added != null &&
          existing.channels != added.channels) {
        throw FourdgsMalformedFile(
          'a birth carries ${added.channels} channels for attribute $attribute, '
          'but the live population carries ${existing.channels}',
        );
      }
      final ch = existing?.channels ?? added!.channels;
      // Optional attributes omitted by one side carry their registry default
      // (zero). Keep every column aligned whether it first appears in this
      // birth or disappears from it; required attributes were checked above.
      final before = existing?.values ?? Int32List(ids.length * ch);
      final after = added?.values ?? Int32List(birthIds.length * ch);
      final merged =
          Int32List(before.length + after.length)
            ..setRange(0, before.length, before)
            ..setRange(before.length, before.length + after.length, after);
      grown[attribute] = _Column(ch, merged);
    }
    ids = grownIds;
    bins = grown;
  }

  return KeyframeDeltaState._(ids, bins);
}

_Column _selectRows(_Column column, List<int> rows) {
  final ch = column.channels;
  final out = Int32List(rows.length * ch);
  for (int r = 0; r < rows.length; r++) {
    final src = rows[r] * ch;
    final dst = r * ch;
    for (int c = 0; c < ch; c++) {
      out[dst + c] = column.values[src + c];
    }
  }
  return _Column(ch, out);
}

void _checkUnique(Int32List ids, String what) {
  final seen = <int>{};
  for (final id in ids) {
    if (!seen.add(id)) {
      throw FourdgsMalformedFile('$what names gaussian id $id more than once');
    }
  }
}

void _checkGroupsDisjoint(Int32List a, Int32List b, Int32List d) {
  void pair(Int32List x, Int32List y, String names) {
    final set = <int>{for (final id in x) id};
    for (final id in y) {
      if (set.contains(id)) {
        throw FourdgsMalformedFile(
          'gaussian id $id is $names by the same delta; the outcome would depend '
          'on the order the groups are applied in',
        );
      }
    }
  }

  pair(a, b, 'updated and born');
  pair(a, d, 'updated and killed');
  pair(b, d, 'born and killed');
}

// --------------------------------------------------------------------------
// Group and chunk decoding — bins, never values
// --------------------------------------------------------------------------

/// One length-framed group: its ids and a bin column per other attribute.
///
/// Deliberately generic — it keeps every stream, including [attrGaussianId],
/// rather than gating on the `gaussian-birth` registry the chunk decoder uses:
/// an update group carries a subset of the required attributes, a death group
/// carries only the identity, and both must decode.
({Int32List ids, Map<int, _Column> bins}) _decodeGroup(
  Uint8List blob,
  int at,
  String what,
) {
  if (blob.isEmpty) {
    return (ids: Int32List(0), bins: <int, _Column>{});
  }
  final streams = _decodeStreams(FourdgsCursor(blob), at, what);
  final gaussianId = streams.remove(attrGaussianId);
  if (gaussianId == null) {
    throw const FourdgsMalformedFile(
      'a keyframe-delta group carries no gaussian_id stream',
    );
  }
  return (ids: _idsOf(gaussianId), bins: streams);
}

/// A keyframe Chunk's ids and its full set of required bins.
({Int32List ids, Map<int, _Column> bins}) _keyframeFromChunk(
  Uint8List content, {
  required int at,
}) {
  final body = parseChunk(content);
  if (body.header.compression.isNotEmpty) {
    throw FourdgsUnsupportedCodec(
      'the keyframe Chunk at byte $at declares chunk-level '
      '"${body.header.compression}" compression; expected an empty '
      'chunk-level compression name and per-attribute stream codecs',
      refusalCode: refusalUnknownStreamCodec,
    );
  }
  final streams = _decodeStreams(
    FourdgsCursor(body.streams),
    at + recordHeaderBytes + body.streamsOffset,
    'the keyframe chunk at byte $at',
  );
  final gaussianId = streams.remove(attrGaussianId);
  if (gaussianId == null) {
    if (body.header.count == 0) {
      return (ids: Int32List(0), bins: streams);
    }
    throw const FourdgsMalformedFile(
      'a keyframe-delta chunk carries no gaussian_id stream',
    );
  }
  if (body.header.count != 0) {
    final missing = <int>[
      for (final a in requiredAttributes)
        if (!streams.containsKey(a)) a,
    ];
    if (missing.isNotEmpty) {
      throw FourdgsMalformedFile(
        'keyframe chunk is missing required attributes $missing',
      );
    }
  }
  final Int32List ids = _idsOf(gaussianId);
  if (ids.length != body.header.count) {
    throw FourdgsMalformedFile(
      'the keyframe Chunk at byte $at declares ${body.header.count} gaussians, '
      'but its gaussian_id stream carries ${ids.length}',
    );
  }
  return (ids: ids, bins: streams);
}

/// Frames every stream in a group and only then decodes it.
///
/// The framing pass proves every declared payload is present before the first
/// decoded allocation. Per-stream decoded-size limits remain the cross-SDK
/// contract; this SDK must not add a differently scoped aggregate refusal.
Map<int, _Column> _decodeStreams(FourdgsCursor cursor, int at, String what) {
  final framed =
      <({FourdgsStreamHeader header, Uint8List payload, int offset})>[];
  final seen = <int>{};
  while (cursor.remaining > 0) {
    final offset = at + cursor.pos;
    final header = readStreamHeader(cursor);
    // Bounds-check the payload before classifying a duplicate. A repeated
    // complete stream is malformed; a repeated header whose payload runs past
    // the group is truncated, and taking this view allocates no decoded bins.
    final payload = cursor.take(header.payloadLength);
    // One stream per attribute here too: the regular chunk path refuses a
    // second, and this path had its own loop that was still resolving it
    // silently.
    if (!seen.add(header.attributeId)) {
      throw FourdgsMalformedFile(
        'a keyframe-delta group carries attribute ${header.attributeId} twice; '
        'the second header is at byte $offset and the format defines one stream '
        'per attribute',
      );
    }
    final int? expectedChannels = _keyframeDeltaChannels(header.attributeId);
    if (expectedChannels != null && header.channels != expectedChannels) {
      throw FourdgsMalformedFile(
        'attribute ${header.attributeId} of $what declares ${header.channels} '
        'channels, the registry says $expectedChannels; its stream header is '
        'at byte $offset',
      );
    }
    framed.add((header: header, payload: payload, offset: offset));
  }

  final got = <int, _Column>{};
  for (final entry in framed) {
    final stream = decodeAttributeStreamBody(
      FourdgsCursor(entry.payload),
      entry.header,
      streamOffset: entry.offset,
    );
    got[stream.attributeId] = _Column(stream.channels, stream.values);
  }
  return got;
}

/// Channels for every registry-defined attribute the keyframe-delta path reads.
int? _keyframeDeltaChannels(int attributeId) {
  switch (attributeId) {
    case attrPosition:
    case attrScale:
    case attrRotation:
    case attrColor:
    case attrMotion:
      return 3;
    case attrRotationIndex:
    case attrOpacity:
    case attrMuT:
    case attrSigmaT:
    case attrFlags:
    case attrWindowIndex:
    case attrSourceGroup:
    case attrSourceIndex:
    case attrObjectId:
    case attrGaussianId:
      return 1;
    default:
      return null;
  }
}

Int32List _idsOf(_Column gaussianId) {
  final n = gaussianId.rows;
  final out = Int32List(n);
  final ch = gaussianId.channels;
  for (int i = 0; i < n; i++) {
    out[i] = gaussianId.values[i * ch];
  }
  return out;
}

// --------------------------------------------------------------------------
// The decoded sequence
// --------------------------------------------------------------------------

/// One decoded chunk and the composed population valid over `[t0, t1)`.
class KeyframeDeltaChunk {
  KeyframeDeltaChunk({
    required this.t0,
    required this.t1,
    required this.kind,
    required this.deltaMode,
    required this.depth,
    required this.offset,
    required this.referenceOffset,
    required this.updateCount,
    required this.birthCount,
    required this.deathCount,
    required this.state,
  });

  final double t0;
  final double t1;

  /// `0` keyframe, `1` delta.
  final int kind;

  /// `null` for a keyframe; the chunk's `delta_mode` otherwise.
  final int? deltaMode;
  final int depth;
  final int offset;
  final int referenceOffset;
  final int? updateCount;
  final int? birthCount;
  final int? deathCount;
  final KeyframeDeltaState state;
}

/// A whole `keyframe-delta` file, decoded by either read path.
class KeyframeDeltaSequence {
  KeyframeDeltaSequence({
    required this.header,
    required this.quantization,
    required this.windows,
    required this.chunks,
  });

  final FourdgsHeader header;
  final FourdgsQuantization quantization;
  final List<FourdgsWindow> windows;
  final List<KeyframeDeltaChunk> chunks;
}

/// Front to back: decode each chunk and compose it onto the state it references.
KeyframeDeltaSequence decodeKeyframeDeltaStreamed(Uint8List data) {
  checkMagic(data);
  FourdgsHeader? header;
  FourdgsQuantization? quantization;
  List<FourdgsWindow> windows = const <FourdgsWindow>[];
  final chunks = <KeyframeDeltaChunk>[];
  final byOffset = <int, KeyframeDeltaState>{};

  for (final record in iterRecords(data, fourdgsMagic.length)) {
    switch (record.opcode) {
      case opHeader:
        header = FourdgsHeader.parse(
          record.content,
          fileOffset: record.offset + recordHeaderBytes,
        );
        if (header.temporalModel != 'keyframe-delta') {
          throw FourdgsMalformedFile(
            'decodeKeyframeDeltaStreamed is the keyframe-delta path; this file is '
            '"${header.temporalModel}"',
          );
        }
      case opQuantization:
        quantization = FourdgsQuantization.parse(
          record.content,
          fileOffset: record.offset + recordHeaderBytes,
        );
      case opWindowTable:
        windows = FourdgsWindowTable.parse(record.content).windows;
      case opChunk:
        final chunk = parseChunk(record.content);
        final decoded = _keyframeFromChunk(record.content, at: record.offset);
        final state = _keyframeState(decoded.ids, decoded.bins);
        byOffset[record.offset] = state;
        chunks.add(
          KeyframeDeltaChunk(
            t0: chunk.header.t0,
            t1: chunk.header.t1,
            kind: 0,
            deltaMode: null,
            depth: 0,
            offset: record.offset,
            referenceOffset: 0,
            updateCount: null,
            birthCount: null,
            deathCount: null,
            state: state,
          ),
        );
      case opDeltaChunk:
        final body = parseDeltaChunk(record.content);
        final reference = byOffset[body.header.referenceOffset];
        if (reference == null) {
          throw FourdgsMalformedFile(
            'delta chunk at ${record.offset} references '
            '${body.header.referenceOffset}, which has not been decoded '
            '(references point backwards only)',
          );
        }
        if (body.header.referenceOffset >= record.offset) {
          throw FourdgsMalformedFile(
            'delta chunk at ${record.offset} references '
            '${body.header.referenceOffset}, which is not behind it',
          );
        }
        final state = _composeDelta(reference, body, at: record.offset);
        byOffset[record.offset] = state;
        chunks.add(
          KeyframeDeltaChunk(
            t0: body.header.t0,
            t1: body.header.t1,
            kind: 1,
            deltaMode: body.header.deltaMode,
            depth: body.header.depth,
            offset: record.offset,
            referenceOffset: body.header.referenceOffset,
            updateCount: body.header.updateCount,
            birthCount: body.header.birthCount,
            deathCount: body.header.deathCount,
            state: state,
          ),
        );
    }
  }

  if (header == null || quantization == null) {
    throw const FourdgsMalformedFile(
      'keyframe-delta file has no Header or Quantization record',
    );
  }
  return KeyframeDeltaSequence(
    header: header,
    quantization: quantization,
    windows: windows,
    chunks: chunks,
  );
}

KeyframeDeltaState _composeDelta(
  KeyframeDeltaState reference,
  FourdgsDeltaChunkBody body, {
  required int at,
}) {
  final content = at + recordHeaderBytes;
  final what = 'the delta chunk at byte $at';
  final updates = _decodeGroup(
    body.updates,
    content + body.updatesOffset,
    what,
  );
  final births = _decodeGroup(body.births, content + body.birthsOffset, what);
  final deaths = _decodeGroup(body.deaths, content + body.deathsOffset, what);
  void checkCount(String group, int actual, int declared) {
    if (actual != declared) {
      throw FourdgsMalformedFile(
        '$what declares $declared $group operations, but its $group group '
        'decodes to $actual gaussian ids',
      );
    }
  }

  checkCount('update', updates.ids.length, body.header.updateCount);
  checkCount('birth', births.ids.length, body.header.birthCount);
  checkCount('death', deaths.ids.length, body.header.deathCount);
  void checkColumnCounts(
    String group,
    Map<int, _Column> columns,
    int declared,
  ) {
    for (final MapEntry<int, _Column> column in columns.entries) {
      if (column.value.rows != declared) {
        throw FourdgsMalformedFile(
          '$what declares $declared $group operations, but attribute '
          '${column.key} in its $group group decodes to '
          '${column.value.rows} rows',
        );
      }
    }
  }

  // The composer has no ids to iterate when a group declares zero operations.
  // Check every lane explicitly so a non-empty attribute stream cannot hide in
  // an otherwise empty group and be silently discarded.
  checkColumnCounts('update', updates.bins, body.header.updateCount);
  checkColumnCounts('birth', births.bins, body.header.birthCount);
  checkColumnCounts('death', deaths.bins, body.header.deathCount);
  final hasRotationIndex = updates.bins.containsKey(attrRotationIndex);
  final hasRotationBins = updates.bins.containsKey(attrRotation);
  if (hasRotationIndex != hasRotationBins) {
    throw FourdgsMalformedFile(
      '$what must restate rotation_index and rotation together in an update; '
      'one is present and the other is absent',
    );
  }
  if (deaths.bins.isNotEmpty) {
    final attributes = deaths.bins.keys.toList()..sort();
    throw FourdgsMalformedFile(
      '$what death group carries non-identity attributes $attributes; a death '
      'group contains exactly one gaussian_id stream',
    );
  }
  return _applyDelta(
    reference,
    updateIds: updates.ids,
    updateBins: updates.bins,
    birthIds: births.ids,
    birthBins: births.bins,
    deathIds: deaths.ids,
  );
}

/// Decode one keyframe Chunk into composed keyframe-delta state.
///
/// Kept as a one-record operation so validators and streaming transports can
/// hold one chunk rather than materializing a complete file.
KeyframeDeltaState keyframeDeltaStateFromChunk(
  Uint8List content, {
  required int chunkOffset,
}) {
  final decoded = _keyframeFromChunk(content, at: chunkOffset);
  return _keyframeState(decoded.ids, decoded.bins);
}

/// Require every keyframe gaussian's encoded birth-time bin to name its t0.
void checkKeyframeDeltaMuT(
  KeyframeDeltaState state,
  double t0,
  FourdgsQuantization quantization,
) {
  if (state.count == 0) return;
  final _Column? mu = state._bins[attrMuT];
  final _Column? sigma = state._bins[attrSigmaT];
  final _Column? flags = state._bins[attrFlags];
  if (mu == null || sigma == null || flags == null) {
    throw const FourdgsMalformedFile(
      'a nonempty keyframe is missing mu_t, sigma_t, or flags',
    );
  }
  final FourdgsSteps steps = FourdgsSteps.of(quantization);
  for (int row = 0; row < state.count; row++) {
    final bool neverFades = flags.values[row] & flagNeverFades != 0;
    final double step = muStep(
      sigma.values[row],
      steps.sigmaLog,
      neverFades,
      steps.time,
    );
    final int expected = (t0 / step).round();
    if (mu.values[row] != expected) {
      throw FourdgsMalformedFile(
        'keyframe gaussian_id ${state.ids[row]} has mu_t bin '
        '${mu.values[row]}; its Chunk t0 $t0 requires bin $expected',
      );
    }
  }
}

/// Compose one already-parsed Delta Chunk onto its selected reference state.
///
/// The caller chooses the reference from the chunk's declared mode and offset;
/// this operation owns decoding and applying its three bounded groups.
KeyframeDeltaState applyKeyframeDeltaBody(
  KeyframeDeltaState reference,
  FourdgsDeltaChunkBody body, {
  required int chunkOffset,
}) => _composeDelta(reference, body, at: chunkOffset);

/// Read the Footer, then the index, then compose each chunk by byte range.
///
/// The composed state per chunk is produced by walking that chunk's chain (spec
/// §11.8) — the seeking client's path — and must reach the same population the
/// streamed path reaches front to back.
({KeyframeDeltaSequence sequence, List<FourdgsChunkIndexEntry> index})
decodeKeyframeDeltaIndexed(Uint8List data) {
  checkMagic(data);
  FourdgsHeader? header;
  FourdgsQuantization? quantization;
  List<FourdgsWindow> windows = const <FourdgsWindow>[];
  FourdgsFooter? footer;
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    if (record.opcode == opHeader) {
      header = FourdgsHeader.parse(
        record.content,
        fileOffset: record.offset + recordHeaderBytes,
      );
    } else if (record.opcode == opQuantization) {
      quantization = FourdgsQuantization.parse(
        record.content,
        fileOffset: record.offset + recordHeaderBytes,
      );
    } else if (record.opcode == opWindowTable) {
      windows = FourdgsWindowTable.parse(record.content).windows;
    } else if (record.opcode == opFooter) {
      footer = FourdgsFooter.parse(record.content);
      break;
    }
  }
  if (footer == null) {
    throw const FourdgsMalformedFile('file has no Footer');
  }
  if (header == null || quantization == null) {
    throw const FourdgsMalformedFile(
      'keyframe-delta file has no Header or Quantization record',
    );
  }

  final index = <FourdgsChunkIndexEntry>[];
  // Already file-relative: `iterRecords(data, footer.summaryStart)` walks the
  // whole file from that position, so the offsets it yields count from the start
  // of the file. The indexed opener adds `summaryStart` because it iterates a
  // detached summary buffer; doing the same here would name a byte at twice the
  // offset, which is worse than naming none.
  final indexRecordOffsets = <int>[];
  for (final record in iterRecords(data, footer.summaryStart)) {
    if (record.opcode == opChunkIndex) {
      index.add(
        FourdgsChunkIndexEntry.parse(
          record.content,
          fileOffset: record.offset + recordHeaderBytes,
        ),
      );
      indexRecordOffsets.add(record.offset);
    } else {
      break;
    }
  }
  // This function IS the keyframe-delta path, so `liveCount` means what it says
  // — and this is the third reader that has to apply the rule, which is why the
  // rule lives in one place now. Without it a zero-change delta over `[t, t)`
  // reaches composition, where the entry it describes is unreachable but the
  // chunk metadata around it is not.
  for (int i = 0; i < index.length; i++) {
    checkIndexEntry(
      index[i],
      isKeyframeDelta: true,
      where:
          'the Chunk Index record at byte ${indexRecordOffsets[i]} (entry $i of '
          '${index.length})',
    );
  }
  checkTiling(index);

  final chunks = <KeyframeDeltaChunk>[];
  // Built once for the whole loop: every chain walk needs it, and rebuilding it
  // per entry is what makes composing an index quadratic.
  final byOffset = keyframeDeltaChainIndex(index);
  for (int i = 0; i < index.length; i++) {
    final entry = index[i];
    final state = composeKeyframeDeltaChain(
      data,
      index,
      entry,
      byOffset: byOffset,
    );
    // The index says how many gaussians are live over this interval and the
    // chunks say what they are, and §5.8 calls that duplication a cheap
    // corruption check. It is also the only thing standing between a zero-width
    // entry declaring nothing and a payload composing to something: the index
    // rule above reads the entry, and the entry is not the file.
    // Both counts, for a keyframe. §5.8 defines `live_count` for every extended
    // entry as the population after composition, and the reference writers set
    // it on keyframes as well — so checking only the field the population rule
    // happens to select would let a corrupt `liveCount` through on exactly the
    // entries where the other field agrees.
    if (entry.kind == 0 && entry.liveCount != state.count) {
      throw FourdgsMalformedFile(
        'the Chunk Index record at byte ${indexRecordOffsets[i]} (entry $i of '
        '${index.length}) declares live_count ${entry.liveCount} for a keyframe '
        'whose chunk holds ${state.count} gaussians; expected the two to agree',
      );
    }
    final int declared = indexEntryPopulation(entry, isKeyframeDelta: true);
    if (state.count != declared) {
      throw FourdgsMalformedFile(
        'the Chunk Index record at byte ${indexRecordOffsets[i]} (entry $i of '
        '${index.length}) declares $declared live gaussians over '
        '[${entry.t0}, ${entry.t1}), but its chain composes to ${state.count}; '
        'expected the index and the chunks to agree',
      );
    }
    int? updateCount;
    int? birthCount;
    int? deathCount;
    if (entry.kind != 0) {
      // The counts are not in the index — there `gaussianCount` is their sum —
      // so a reader that wants the split reads the delta chunk's own header. The
      // chain walk already fetched this record; parsing its header again is
      // cheap.
      final head =
          parseDeltaChunk(
            _recordContent(
              data,
              entry.chunkOffset,
              entry.chunkLength,
              expectedOpcode: opDeltaChunk,
            ),
          ).header;
      updateCount = head.updateCount;
      birthCount = head.birthCount;
      deathCount = head.deathCount;
    }
    chunks.add(
      KeyframeDeltaChunk(
        t0: entry.t0,
        t1: entry.t1,
        kind: entry.kind,
        deltaMode: entry.kind != 0 ? entry.deltaMode : null,
        depth: entry.depth,
        offset: entry.chunkOffset,
        referenceOffset: entry.referenceOffset,
        updateCount: updateCount,
        birthCount: birthCount,
        deathCount: deathCount,
        state: state,
      ),
    );
  }

  return (
    sequence: KeyframeDeltaSequence(
      header: header,
      quantization: quantization,
      windows: windows,
      chunks: chunks,
    ),
    index: index,
  );
}

Uint8List _recordContent(
  Uint8List data,
  int offset,
  int length, {
  required int expectedOpcode,
  int? fileOffset,
}) {
  if (offset < 0 ||
      length < recordHeaderBytes ||
      offset + length > data.length) {
    throw FourdgsMalformedFile(
      'the indexed state record at byte ${fileOffset ?? offset} declares a '
      '$length-byte '
      'range outside the ${data.length}-byte buffer',
    );
  }
  final int contentLength = _checkStateRecordHeader(
    Uint8List.sublistView(data, offset, offset + recordHeaderBytes),
    fileOffset: fileOffset ?? offset,
    rangeLength: length,
    expectedOpcode: expectedOpcode,
  );
  return Uint8List.sublistView(
    data,
    offset + recordHeaderBytes,
    offset + recordHeaderBytes + contentLength,
  );
}

int _checkStateRecordHeader(
  Uint8List header, {
  required int fileOffset,
  required int rangeLength,
  required int expectedOpcode,
}) {
  final c = FourdgsCursor(header);
  final int opcode = c.u8();
  final int contentLength = c.u64();
  if (opcode != expectedOpcode) {
    throw FourdgsMalformedFile(
      'the indexed state record at byte $fileOffset is ${opcodeName(opcode)}; '
      'expected ${opcodeName(expectedOpcode)}',
    );
  }
  if (recordHeaderBytes + contentLength != rangeLength) {
    throw FourdgsMalformedFile(
      'the indexed state range at byte $fileOffset declares $rangeLength '
      'bytes, but '
      'its ${opcodeName(opcode)} framing declares '
      '${recordHeaderBytes + contentLength}; the index must name exactly one '
      'record',
    );
  }
  return contentLength;
}

int _stateOpcode(FourdgsChunkIndexEntry entry) {
  if (entry.kind == 0) return opChunk;
  if (entry.kind == 1) return opDeltaChunk;
  throw FourdgsMalformedFile(
    'the index entry at byte ${entry.chunkOffset} declares chunk_kind '
    '${entry.kind}; expected 0 (keyframe) or 1 (delta)',
  );
}

/// The composed state of one index entry: its chain, walked and telescoped.
///
/// Public because a caller does not always want the whole sequence.
/// [decodeKeyframeDeltaIndexed] answers "what does this file decode to" and so
/// keeps every composed state, while a seeking client wants one instant. The
/// latter needs one state resident at a time, which is what this operation
/// provides (AGENTS.md §1).
/// [byOffset] is [keyframeDeltaChainIndex] of the same index, for a caller in a
/// loop. See that function for why it is worth passing.
KeyframeDeltaState composeKeyframeDeltaChain(
  Uint8List data,
  List<FourdgsChunkIndexEntry> index,
  FourdgsChunkIndexEntry entry, {
  Map<int, FourdgsChunkIndexEntry>? byOffset,
}) {
  final chain = chainFrom(index, entry, byOffset: byOffset);
  KeyframeDeltaState? state;
  int? referenceLevel;
  for (final link in chain) {
    final int expectedOpcode = _stateOpcode(link);
    final composed = _composeLink(
      state,
      _recordContent(
        data,
        link.chunkOffset,
        link.chunkLength,
        expectedOpcode: expectedOpcode,
      ),
      link,
      referenceLevel: referenceLevel,
    );
    state = composed.state;
    referenceLevel = composed.level;
  }
  return _composed(state);
}

/// The same chain, fetched by byte range instead of from a resident file.
///
/// For the caller that has a [FourdgsReadable] and no reason to hold the file:
/// a chain is a handful of records, and reading each one as the walk reaches it
/// keeps a chunk resident rather than a scene (AGENTS.md §1). The states this
/// composes are identical to [composeKeyframeDeltaChain]'s — same records, same
/// order, same refusals — so the two are interchangeable and a caller picks by
/// what it already holds.
Future<KeyframeDeltaState> readKeyframeDeltaChain(
  FourdgsReadable source,
  List<FourdgsChunkIndexEntry> index,
  FourdgsChunkIndexEntry entry, {
  Map<int, FourdgsChunkIndexEntry>? byOffset,
}) async {
  final chain = chainFrom(index, entry, byOffset: byOffset);
  final int size = await source.size();
  KeyframeDeltaState? state;
  int? referenceLevel;
  for (final link in chain) {
    final int expectedOpcode = _stateOpcode(link);
    if (link.chunkOffset < 0 ||
        link.chunkLength < recordHeaderBytes ||
        link.chunkOffset + link.chunkLength > size) {
      throw FourdgsMalformedFile(
        'the chunk at ${link.chunkOffset} declares a ${link.chunkLength}-byte '
        'range outside the $size-byte resource',
      );
    }
    final Uint8List header;
    try {
      header = await source.read(link.chunkOffset, recordHeaderBytes);
    } on RangeError catch (error) {
      throw FourdgsMalformedFile(
        'the state record at ${link.chunkOffset} could not be read as a '
        '$recordHeaderBytes-byte framing header: $error',
      );
    }
    // Price the indexed range only after its fixed-size framing proves it is
    // exactly one state record. Otherwise a forged chunk_length can make this
    // public range API allocate nearly the whole file before noticing that the
    // first record in it was small.
    _checkStateRecordHeader(
      header,
      fileOffset: link.chunkOffset,
      rangeLength: link.chunkLength,
      expectedOpcode: expectedOpcode,
    );
    final Uint8List blob;
    try {
      blob = await source.read(link.chunkOffset, link.chunkLength);
    } on RangeError catch (error) {
      throw FourdgsMalformedFile(
        'the chunk at ${link.chunkOffset} could not be read as its declared '
        '${link.chunkLength}-byte range: $error',
      );
    }
    final composed = _composeLink(
      state,
      _recordContent(
        blob,
        0,
        link.chunkLength,
        expectedOpcode: expectedOpcode,
        fileOffset: link.chunkOffset,
      ),
      link,
      referenceLevel: referenceLevel,
    );
    state = composed.state;
    referenceLevel = composed.level;
  }
  return _composed(state);
}

/// One link of a chain composed onto what came before it, plus the level the
/// next delta must preserve.
({KeyframeDeltaState state, int level}) _composeLink(
  KeyframeDeltaState? state,
  Uint8List content,
  FourdgsChunkIndexEntry link, {
  required int? referenceLevel,
}) {
  if (link.kind == 0) {
    final FourdgsChunkBody body = parseChunk(content);
    _checkKeyframeIndexAgreement(link, body.header);
    final decoded = _keyframeFromChunk(content, at: link.chunkOffset);
    return (
      state: _keyframeState(decoded.ids, decoded.bins),
      level: body.header.level,
    );
  }
  if (state == null || referenceLevel == null) {
    throw const FourdgsMalformedFile(
      'a keyframe-delta chain begins with a delta chunk',
    );
  }
  final FourdgsDeltaChunkBody body = parseDeltaChunk(content);
  _checkDeltaIndexAgreement(link, body.header);
  if (body.header.level != referenceLevel) {
    throw FourdgsMalformedFile(
      'the delta chunk at byte ${link.chunkOffset} declares level '
      '${body.header.level}, but its selected reference has level '
      '$referenceLevel; a delta preserves its reference level',
    );
  }
  return (
    state: _composeDelta(state, body, at: link.chunkOffset),
    level: body.header.level,
  );
}

void _checkKeyframeIndexAgreement(
  FourdgsChunkIndexEntry entry,
  FourdgsChunkHeader chunk,
) {
  if (entry.t0 != chunk.t0 ||
      entry.t1 != chunk.t1 ||
      entry.gaussianCount != chunk.count) {
    throw FourdgsMalformedFile(
      'the index entry for the keyframe at ${entry.chunkOffset} declares '
      '[${entry.t0}, ${entry.t1}) and ${entry.gaussianCount} gaussians, but '
      'the Chunk declares [${chunk.t0}, ${chunk.t1}) and ${chunk.count}; '
      'duplicated fields must agree',
    );
  }
}

void _checkDeltaIndexAgreement(
  FourdgsChunkIndexEntry entry,
  FourdgsDeltaChunkHeader chunk,
) {
  if (chunk.deltaMode != deltaModeKeyframe &&
      chunk.deltaMode != deltaModeChained) {
    throw FourdgsMalformedFile(
      'the delta chunk at byte ${entry.chunkOffset} declares delta_mode '
      '${chunk.deltaMode}; expected $deltaModeKeyframe (keyframe) or '
      '$deltaModeChained (chained)',
    );
  }
  final int operations =
      chunk.updateCount + chunk.birthCount + chunk.deathCount;
  if (entry.t0 != chunk.t0 ||
      entry.t1 != chunk.t1 ||
      entry.deltaMode != chunk.deltaMode ||
      entry.referenceOffset != chunk.referenceOffset ||
      entry.keyframeOffset != chunk.keyframeOffset ||
      entry.depth != chunk.depth ||
      entry.gaussianCount != operations) {
    throw FourdgsMalformedFile(
      'the index entry for the delta at ${entry.chunkOffset} disagrees with '
      'its Delta Chunk: expected interval [${chunk.t0}, ${chunk.t1}), '
      'delta_mode ${chunk.deltaMode}, reference_offset '
      '${chunk.referenceOffset}, keyframe_offset ${chunk.keyframeOffset}, '
      'depth ${chunk.depth}, and gaussian_count $operations; duplicated fields '
      'must agree',
    );
  }
}

KeyframeDeltaState _composed(KeyframeDeltaState? state) {
  if (state == null) {
    throw const FourdgsMalformedFile('an empty keyframe-delta chain');
  }
  return state;
}

/// Index entries by the byte their chunk starts at, which is what a delta
/// references (spec §11.8).
///
/// Built once and passed to [chainFrom] by a caller that walks more than one
/// chain. Building it inside the walk is correct and is what a single lookup
/// does; doing it once per entry of an index makes composing every chain cost
/// `O(entries²)` map insertions before a single chunk is read, which a
/// ten-thousand-entry index turns into hundreds of millions of them.
Map<int, FourdgsChunkIndexEntry> keyframeDeltaChainIndex(
  List<FourdgsChunkIndexEntry> index,
) => <int, FourdgsChunkIndexEntry>{
  for (final entry in index) entry.chunkOffset: entry,
};

/// State chunks tile the timeline: no overlap, no gap (spec §11.1). This is what
/// makes the seek predicate a lookup rather than a search.
void checkTiling(List<FourdgsChunkIndexEntry> index, {double? durationSec}) {
  final ordered = index.toList()..sort((a, b) => a.t0.compareTo(b.t0));
  if (ordered.isEmpty) {
    throw const FourdgsMalformedFile(
      'a keyframe-delta file contains no indexed state chunks',
    );
  }
  if (ordered.first.t0 != 0.0) {
    throw FourdgsMalformedFile(
      'state chunks start at ${ordered.first.t0}; expected the first interval '
      'to start at 0',
    );
  }
  for (int i = 1; i < ordered.length; i++) {
    final previous = ordered[i - 1];
    final entry = ordered[i];
    if (previous.t1 != entry.t0) {
      final what = entry.t0 < previous.t1 ? 'overlap' : 'leave a gap';
      throw FourdgsMalformedFile(
        'state chunks $what: [${previous.t0}, ${previous.t1}) is followed by '
        '[${entry.t0}, ${entry.t1})',
      );
    }
  }
  if (durationSec != null && ordered.last.t1 != durationSec) {
    throw FourdgsMalformedFile(
      'state chunks end at ${ordered.last.t1}; the Header duration_sec is '
      '$durationSec',
    );
  }
}

/// The keyframe and deltas a reader must read to reconstruct instant `t`.
///
/// Answered from the index alone — no chunk is fetched to learn what another
/// references — and returned oldest first, the order [applyDelta] composes in
/// (spec §11.8).
List<FourdgsChunkIndexEntry> chainFor(
  List<FourdgsChunkIndexEntry> index,
  double t,
) {
  for (final entry in index) {
    if (entry.t0 <= t && t < entry.t1) {
      return chainFrom(index, entry);
    }
  }
  throw FourdgsMalformedFile('no state chunk covers t=$t');
}

/// The keyframe and deltas that reconstruct [current] itself.
///
/// Split from [chainFor] because a caller that already holds the entry has no
/// instant to offer and should not have to invent one. Composing every chunk in
/// turn used to probe each at its own midpoint, which is a fine instant for a
/// finite interval and no instant at all for `[0, +Infinity)`: the midpoint is
/// `+Infinity`, `t < t1` is false there, and a file the streamed path decodes
/// became one the indexed path could not find its way into.
/// [byOffset] is the lookup [keyframeDeltaChainIndex] builds. Optional, and
/// worth passing from a loop: without it every call rebuilds the map, which
/// turns "walk each entry's chain" from linear into quadratic (AGENTS.md §4).
List<FourdgsChunkIndexEntry> chainFrom(
  List<FourdgsChunkIndexEntry> index,
  FourdgsChunkIndexEntry current, {
  Map<int, FourdgsChunkIndexEntry>? byOffset,
}) {
  final lookup = byOffset ?? keyframeDeltaChainIndex(index);
  final chain = <FourdgsChunkIndexEntry>[current];
  while (chain.first.kind != 0) {
    final head = chain.first;
    if (head.kind != 1) {
      throw FourdgsMalformedFile(
        'the index entry at byte ${head.chunkOffset} declares chunk_kind '
        '${head.kind}; expected 0 (keyframe) or 1 (delta)',
      );
    }
    if (head.deltaMode != deltaModeKeyframe &&
        head.deltaMode != deltaModeChained) {
      throw FourdgsMalformedFile(
        'the delta index entry at byte ${head.chunkOffset} declares '
        'delta_mode ${head.deltaMode}; expected $deltaModeKeyframe '
        '(keyframe) or $deltaModeChained (chained)',
      );
    }
    if (head.referenceOffset >= head.chunkOffset) {
      throw FourdgsMalformedFile(
        'the chunk at ${head.chunkOffset} references ${head.referenceOffset}, '
        'which is not behind it; references point backwards only',
      );
    }
    final reference = lookup[head.referenceOffset];
    if (reference == null) {
      throw FourdgsMalformedFile(
        'the chunk at ${head.chunkOffset} references ${head.referenceOffset}, '
        'which the index does not name',
      );
    }
    if (head.deltaMode == deltaModeKeyframe && reference.kind != 0) {
      throw FourdgsMalformedFile(
        'the keyframe-mode delta at byte ${head.chunkOffset} references the '
        'delta at byte ${reference.chunkOffset}; expected its GOP keyframe',
      );
    }
    final int expectedKeyframeOffset =
        reference.kind == 0 ? reference.chunkOffset : reference.keyframeOffset;
    final int expectedDepth =
        head.deltaMode == deltaModeKeyframe ? 1 : reference.depth + 1;
    if (head.keyframeOffset != expectedKeyframeOffset ||
        head.depth != expectedDepth) {
      throw FourdgsMalformedFile(
        'the delta at byte ${head.chunkOffset} declares keyframe_offset '
        '${head.keyframeOffset} and depth ${head.depth}; its selected '
        'reference requires $expectedKeyframeOffset and $expectedDepth',
      );
    }
    chain.insert(0, reference);
    if (chain.length > index.length) {
      throw const FourdgsMalformedFile('the chain does not reach a keyframe');
    }
  }

  final FourdgsChunkIndexEntry keyframe = chain.first;
  if (keyframe.depth != 0 ||
      keyframe.referenceOffset != 0 ||
      keyframe.keyframeOffset != keyframe.chunkOffset) {
    throw FourdgsMalformedFile(
      'the keyframe index entry at byte ${keyframe.chunkOffset} declares '
      'reference_offset ${keyframe.referenceOffset}, keyframe_offset '
      '${keyframe.keyframeOffset}, and depth ${keyframe.depth}; expected 0, '
      '${keyframe.chunkOffset}, and 0',
    );
  }

  if (chain.length - 1 != current.depth) {
    throw FourdgsMalformedFile(
      'the chunk at ${current.chunkOffset} declares depth ${current.depth}, but '
      'its chain walks ${chain.length - 1} delta chunks; the index and the file '
      'disagree about the cost of this seek',
    );
  }
  return chain;
}

// --------------------------------------------------------------------------
// Reconstruction and the canonical summary
// --------------------------------------------------------------------------

/// The grids composition dequantizes against, drawn from the Quantization record
/// and the single shared validity window.
class _Grids {
  _Grids(this.steps, this.origin, this.windows, this.cutoff);

  final FourdgsSteps steps;
  final List<double> origin;

  /// Every validity window the sequence declares, in Window Table order. A
  /// gaussian's own window is the one its `window_index` names — the velocity
  /// grid comes from that window's length (section 6.3), so collapsing the
  /// table to its first entry gives every gaussian outside window 0 the wrong
  /// motion precision and its positions drift from the bins the encoder wrote.
  final List<FourdgsWindow> windows;
  final double cutoff;

  /// The window [index] names, refusing one the table cannot answer rather than
  /// clamping: clamping substitutes one gaussian's lifetime for another's in a
  /// file that is already wrong.
  ///
  /// [gaussian] is the stable id of the gaussian that named the index, so the
  /// refusal says which one. A keyframe-delta state restates many gaussians and
  /// this is reached once per row, so "window index 7 is outside the table" on
  /// its own is a fact about the file with no way to find it again. The id
  /// rather than the row, because rows are an artefact of composition order and
  /// the id is what the file carries (spec §11.5). Null, not a negative number,
  /// for a caller that has no gaussian to blame — see [_named].
  FourdgsWindow windowAt(int index, {int? gaussian}) {
    // An absent or empty table is one default (0, 0) window, matching the chunk
    // decoder. Clamping instead would substitute one gaussian's lifetime for
    // another's in a file that is already wrong.
    final table =
        windows.isEmpty
            ? const <FourdgsWindow>[FourdgsWindow(0.0, 0.0)]
            : windows;
    if (index < 0 || index >= table.length) {
      throw windowIndexOutOfRange(
        index,
        table.length,
        gaussian: _named(gaussian),
      );
    }
    return table[index];
  }

  double windowLengthAt(int index, {int? gaussian}) {
    // An absent or empty Window Table is one default (0, 0) window, not an
    // unbounded fallback — the same defaulting the chunk decoder applies. A
    // bare `return 0.0` for an empty table would let any index decode against
    // it, so `window_index = 7` would reconstruct instead of being refused.
    final table =
        windows.isEmpty
            ? const <FourdgsWindow>[FourdgsWindow(0.0, 0.0)]
            : windows;
    if (index < 0 || index >= table.length) {
      throw windowIndexOutOfRange(
        index,
        table.length,
        gaussian: _named(gaussian),
      );
    }
    return table[index].hi - table[index].lo;
  }

  /// `"gaussian 12"`, or nothing when the caller had no id to give.
  ///
  /// The absent case is `null` rather than a negative number because a negative
  /// number is a legal id here. `gaussian_id` is a `u32` (spec §11.2) and bins
  /// are decoded as signed 32-bit in every SDK, so an id at or above `2^31`
  /// arrives as a negative value — `0xFFFFFFFF` reads as `-1`. A `-1` sentinel
  /// would therefore silently drop the location from the one refusal that named
  /// the highest legal id, which is the opposite of what §6 asks for.
  static String _named(int? gaussian) =>
      gaussian == null ? '' : 'gaussian $gaussian';
}

_Grids _gridsFor(KeyframeDeltaSequence sequence) {
  return _Grids(
    FourdgsSteps.of(sequence.quantization),
    sequence.quantization.posOrigin,
    sequence.windows,
    sequence.header.cutoff,
  );
}

/// The composed population reconstructed at instant `t`, in `gaussian_id` order.
///
/// Everything downstream orders by `gaussian_id`, which is unique within a state
/// (spec §11.2). That is decoded-value order — not stream order, which a reader
/// may not rely on — so two implementations that compose the same population
/// agree on every row.
class _Reconstruction {
  _Reconstruction(this.ids, this.centers, this.scales, this.opacity);

  final Int32List ids; // sorted ascending
  final Float64List centers; // count * 3
  final Float64List scales; // count * 3
  final Float64List opacity; // count
  int get count => ids.length;
}

_Reconstruction _reconstructAt(
  KeyframeDeltaState state,
  _Grids grids,
  double t,
) {
  final n = state.count;
  final order = List<int>.generate(n, (int i) => i)
    ..sort((a, b) => state.ids[a].compareTo(state.ids[b]));

  if (n == 0) {
    return _Reconstruction(
      Int32List(0),
      Float64List(0),
      Float64List(0),
      Float64List(0),
    );
  }

  final position = state._bins[attrPosition]!.values;
  final scaleBins = state._bins[attrScale]!.values;
  final motion = state._bins[attrMotion]!.values;
  final muBins = state._bins[attrMuT]!.values;
  final sigmaBinsCol = state._bins[attrSigmaT]!.values;
  final flags = state._bins[attrFlags]!.values;
  final opacityBins = state._bins[attrOpacity]!.values;

  final steps = grids.steps;
  final k = supportK(grids.cutoff);
  // A zero-count keyframe can omit every stream, and `_applyDelta` carries forward
  // only attributes the reference already had — so a later birth can compose a
  // non-empty state with no window_index. Reconstruction reads it below, so this is
  // a refusal rather than a null-assertion failure inside the renderer.
  final windowColumn = state._bins[attrWindowIndex];
  if (windowColumn == null) {
    throw const FourdgsMalformedFile(
      'a non-empty state carries no window_index column; it is a required '
      'keyframe attribute (section 11.5)',
    );
  }
  final windowIndex = windowColumn.values;

  // A gaussian is absent outside its own validity window, exactly as the
  // gaussian-birth path decides it (`winLo <= t < winHi`) — dropped, not merely
  // made transparent, so id, centre, scale and the live count all exclude it.
  // Unobservable while every keyframe-delta file carried one full-duration
  // window; reachable the moment a file declares more than one.
  final kept = <int>[];
  for (final i in order) {
    // Validated, not clamped: a row dropped for being outside a window it never
    // named would make a malformed file look like a valid, emptier one.
    final w = grids.windowAt(windowIndex[i], gaussian: state.ids[i]);
    if (w.lo <= t && t < w.hi) kept.add(i);
  }

  final ids = Int32List(kept.length);
  final centers = Float64List(kept.length * 3);
  final scales = Float64List(kept.length * 3);
  final opacity = Float64List(kept.length);

  for (int outRow = 0; outRow < kept.length; outRow++) {
    final i = kept[outRow];
    ids[outRow] = state.ids[i];

    final sigmaBin = sigmaBinsCol[i];
    final neverFades = flags[i] & flagNeverFades != 0;
    final sigma =
        neverFades ? double.infinity : math.exp(sigmaBin * steps.sigmaLog);
    final mStep = motionStep(
      lifeClass(
        sigmaBin,
        steps.sigmaLog,
        neverFades,
        grids.windowLengthAt(windowIndex[i], gaussian: state.ids[i]),
        k: k,
      ),
      steps.motion,
    );
    final tStep = muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    final mu = muBins[i] * tStep;
    final dt = t - mu;

    final o3 = outRow * 3;
    final i3 = i * 3;
    for (int c = 0; c < 3; c++) {
      final pos = position[i3 + c] * steps.pos + grids.origin[c];
      centers[o3 + c] = pos + motion[i3 + c] * mStep * dt;
      scales[o3 + c] = math.exp(scaleBins[i3 + c] * steps.scaleLog);
    }

    final alpha = (opacityBins[i] * steps.alpha).clamp(0.0, 1.0);
    final marginal =
        sigma.isInfinite ? 1.0 : math.exp(-0.5 * (dt / sigma) * (dt / sigma));
    // A gaussian is absent outside its own validity window, exactly as the
    // gaussian-birth path decides it (`winLo <= t < winHi`). Unobservable while
    // every keyframe-delta file carried one full-duration window; reachable the
    // moment a file declares more than one.
    opacity[outRow] = alpha * marginal;
  }
  return _Reconstruction(ids, centers, scales, opacity);
}

/// Decimals a float is rounded to before comparison, matching
/// `tests/conformance/canonical.py`.
const int _floatDecimals = 6;

/// How many gaussians appear in full in a probe's sample.
const int _sample = 16;

/// Rounds for comparison; a non-finite value becomes `null`, which is the only
/// thing JSON can say about one.
double? _num(double? value) {
  if (value == null || !value.isFinite) return null;
  return double.parse(value.toStringAsFixed(_floatDecimals));
}

/// Every chunk's `t0` and interval midpoint, plus one instant just below the
/// end. Derived from the file rather than hardcoded, so "seek to every chunk" is
/// the expectation rather than a separate test (design §11.2).
List<double> _probeTimes(List<KeyframeDeltaChunk> chunks, double durationSec) {
  final times = <double>{};
  double round9(double v) => double.parse(v.toStringAsFixed(9));
  for (final c in chunks) {
    times.add(round9(c.t0));
    // An open-ended chunk has no midpoint: `(t0 + Infinity) / 2` is `Infinity`,
    // which is not an instant inside `[t0, Infinity)` or inside anything else.
    // Its `t0` is already in the list, so the interval is still probed.
    final double mid = (c.t0 + c.t1) / 2.0;
    if (mid.isFinite) times.add(round9(mid));
  }
  // The instant just below the end, when there is an end. `durationSec - 1e-6`
  // is still `+Infinity` for an open-ended scene — an instant no half-open
  // interval contains, which reconstructs to an empty state at a null time and
  // reports a nonempty scene as holding nothing.
  if (durationSec.isFinite) {
    times.add(round9(math.max(0.0, durationSec - 1e-6)));
  }
  final sorted = times.toList()..sort();
  return sorted;
}

KeyframeDeltaChunk _stateCovering(List<KeyframeDeltaChunk> chunks, double t) {
  for (final c in chunks) {
    if (c.t0 <= t && t < c.t1) return c;
  }
  return chunks.last;
}

/// The statement two implementations are diffed on for a `keyframe-delta` file.
///
/// `chunks` proves a decoder read `depth`, `deltaMode` and `liveCount` — a field
/// no row mentions is one an implementation can decline to decode. `states` is
/// the reconstruction at an instant: for each probe, the composed population's
/// live count, a sample of centres and scales in id order, and the aggregate
/// over the whole population. Integers are strings so a 64-bit value survives a
/// double-backed JSON parser.
Map<String, Object?> keyframeDeltaStatesJson(KeyframeDeltaSequence sequence) {
  final grids = _gridsFor(sequence);
  final duration = sequence.header.durationSec;

  final chunkRows = <Object?>[
    for (final c in sequence.chunks)
      <String, Object?>{
        't0': _num(c.t0),
        't1': _num(c.t1),
        'kind': c.kind == 0 ? 'keyframe' : 'delta',
        'deltaMode':
            c.kind == 0
                ? null
                : (c.deltaMode == deltaModeChained ? 'chained' : 'keyframe'),
        'depth': c.depth.toString(),
        'liveCount': c.state.count.toString(),
        'updateCount': c.updateCount?.toString(),
        'birthCount': c.birthCount?.toString(),
        'deathCount': c.deathCount?.toString(),
      },
  ];

  final states = <Object?>[
    for (final t in _probeTimes(sequence.chunks, duration))
      _stateRow(_stateCovering(sequence.chunks, t), grids, t),
  ];

  return <String, Object?>{
    'temporalModel': 'keyframe-delta',
    'gaussianCount': sequence.header.gaussianCount.toString(),
    'durationSec': _num(duration),
    'cutoff': _num(sequence.header.cutoff),
    'chunks': chunkRows,
    'states': states,
  };
}

Map<String, Object?> _stateRow(
  KeyframeDeltaChunk info,
  _Grids grids,
  double t,
) {
  final r = _reconstructAt(info.state, grids, t);
  final sampleN = math.min(_sample, r.count);
  final positionSum = <double>[0, 0, 0];
  double opacitySum = 0;
  for (int i = 0; i < r.count; i++) {
    for (int c = 0; c < 3; c++) {
      positionSum[c] += r.centers[i * 3 + c];
    }
    opacitySum += r.opacity[i];
  }
  return <String, Object?>{
    't': _num(t),
    // The count at this instant, from the rows reconstruction returned:
    // `info.state.count` is the chunk's population, which differs once a
    // validity window has closed.
    'liveCount': r.ids.length.toString(),
    'sample': <String, Object?>{
      'gaussianIds': <Object?>[
        for (int i = 0; i < sampleN; i++) r.ids[i].toString(),
      ],
      'positions': <Object?>[
        for (int i = 0; i < sampleN; i++)
          <Object?>[for (int c = 0; c < 3; c++) _num(r.centers[i * 3 + c])],
      ],
      'scales':
          r.count == 0
              ? <Object?>[]
              : <Object?>[
                for (int i = 0; i < sampleN; i++)
                  <Object?>[
                    for (int c = 0; c < 3; c++) _num(r.scales[i * 3 + c]),
                  ],
              ],
    },
    'aggregate': <String, Object?>{
      'positionSum': <Object?>[for (final v in positionSum) _num(v)],
      'opacitySum': _num(opacitySum),
    },
  };
}
