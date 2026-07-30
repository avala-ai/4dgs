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
      final added = birthBins[attribute]!;
      final ch = added.channels;
      final before = existing?.values ?? Int32List(0);
      final merged =
          Int32List(before.length + added.values.length)
            ..setRange(0, before.length, before)
            ..setRange(
              before.length,
              before.length + added.values.length,
              added.values,
            );
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
({Int32List ids, Map<int, _Column> bins}) _decodeGroup(Uint8List blob) {
  if (blob.isEmpty) {
    return (ids: Int32List(0), bins: <int, _Column>{});
  }
  final streams = _decodeStreams(FourdgsCursor(blob));
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
  Uint8List content,
) {
  final body = parseChunk(content);
  if (body.header.compression.isNotEmpty) {
    throw FourdgsUnsupportedCodec(
      'chunk-level "${body.header.compression}" compression is not supported',
    );
  }
  final streams = _decodeStreams(FourdgsCursor(body.streams));
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
  return (ids: _idsOf(gaussianId), bins: streams);
}

Map<int, _Column> _decodeStreams(FourdgsCursor cursor) {
  final got = <int, _Column>{};
  while (cursor.remaining > 0) {
    final header = readStreamHeader(cursor);
    final stream = decodeAttributeStreamBody(cursor, header);
    got[stream.attributeId] = _Column(stream.channels, stream.values);
  }
  return got;
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
        header = FourdgsHeader.parse(record.content);
        if (header.temporalModel != 'keyframe-delta') {
          throw FourdgsMalformedFile(
            'decodeKeyframeDeltaStreamed is the keyframe-delta path; this file is '
            '"${header.temporalModel}"',
          );
        }
      case opQuantization:
        quantization = FourdgsQuantization.parse(record.content);
      case opWindowTable:
        windows = FourdgsWindowTable.parse(record.content).windows;
      case opChunk:
        final chunk = parseChunk(record.content);
        final decoded = _keyframeFromChunk(record.content);
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
        final state = _composeDelta(reference, body);
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
  FourdgsDeltaChunkBody body,
) {
  final updates = _decodeGroup(body.updates);
  final births = _decodeGroup(body.births);
  final deaths = _decodeGroup(body.deaths);
  return _applyDelta(
    reference,
    updateIds: updates.ids,
    updateBins: updates.bins,
    birthIds: births.ids,
    birthBins: births.bins,
    deathIds: deaths.ids,
  );
}

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
      header = FourdgsHeader.parse(record.content);
    } else if (record.opcode == opQuantization) {
      quantization = FourdgsQuantization.parse(record.content);
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
  for (final record in iterRecords(data, footer.summaryStart)) {
    if (record.opcode == opChunkIndex) {
      index.add(FourdgsChunkIndexEntry.parse(record.content));
    } else {
      break;
    }
  }
  checkTiling(index);

  final chunks = <KeyframeDeltaChunk>[];
  for (final entry in index) {
    final state = _composeChain(data, index, entry);
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
            _recordContent(data, entry.chunkOffset, entry.chunkLength),
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

Uint8List _recordContent(Uint8List data, int offset, int length) {
  final c = FourdgsCursor(Uint8List.sublistView(data, offset, offset + length));
  c.u8();
  return c.take(c.u64());
}

KeyframeDeltaState _composeChain(
  Uint8List data,
  List<FourdgsChunkIndexEntry> index,
  FourdgsChunkIndexEntry entry,
) {
  final chain = chainFor(index, (entry.t0 + entry.t1) / 2.0);
  KeyframeDeltaState? state;
  for (final link in chain) {
    final content = _recordContent(data, link.chunkOffset, link.chunkLength);
    if (link.kind == 0) {
      final decoded = _keyframeFromChunk(content);
      state = _keyframeState(decoded.ids, decoded.bins);
    } else {
      if (state == null) {
        throw const FourdgsMalformedFile(
          'a keyframe-delta chain begins with a delta chunk',
        );
      }
      state = _composeDelta(state, parseDeltaChunk(content));
    }
  }
  if (state == null) {
    throw const FourdgsMalformedFile('an empty keyframe-delta chain');
  }
  return state;
}

/// State chunks tile the timeline: no overlap, no gap (spec §11.1). This is what
/// makes the seek predicate a lookup rather than a search.
void checkTiling(List<FourdgsChunkIndexEntry> index) {
  final ordered = index.toList()..sort((a, b) => a.t0.compareTo(b.t0));
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
  final byOffset = <int, FourdgsChunkIndexEntry>{
    for (final entry in index) entry.chunkOffset: entry,
  };
  FourdgsChunkIndexEntry? current;
  for (final entry in index) {
    if (entry.t0 <= t && t < entry.t1) {
      current = entry;
      break;
    }
  }
  if (current == null) {
    throw FourdgsMalformedFile('no state chunk covers t=$t');
  }

  final chain = <FourdgsChunkIndexEntry>[current];
  while (chain.first.kind != 0) {
    final head = chain.first;
    if (head.referenceOffset >= head.chunkOffset) {
      throw FourdgsMalformedFile(
        'the chunk at ${head.chunkOffset} references ${head.referenceOffset}, '
        'which is not behind it; references point backwards only',
      );
    }
    final reference = byOffset[head.referenceOffset];
    if (reference == null) {
      throw FourdgsMalformedFile(
        'the chunk at ${head.chunkOffset} references ${head.referenceOffset}, '
        'which the index does not name',
      );
    }
    chain.insert(0, reference);
    if (chain.length > index.length) {
      throw const FourdgsMalformedFile('the chain does not reach a keyframe');
    }
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
  _Grids(this.steps, this.origin, this.winLo, this.winHi, this.cutoff);

  final FourdgsSteps steps;
  final List<double> origin;
  final double winLo;
  final double winHi;
  final double cutoff;

  double get windowLength => winHi - winLo;
}

_Grids _gridsFor(KeyframeDeltaSequence sequence) {
  final window =
      sequence.windows.isNotEmpty
          ? sequence.windows.first
          : const FourdgsWindow(0.0, 0.0);
  return _Grids(
    FourdgsSteps.of(sequence.quantization),
    sequence.quantization.posOrigin,
    window.lo,
    window.hi,
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

  final ids = Int32List(n);
  final centers = Float64List(n * 3);
  final scales = Float64List(n * 3);
  final opacity = Float64List(n);
  if (n == 0) {
    return _Reconstruction(ids, centers, scales, opacity);
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
  final winLen = grids.windowLength;

  for (int outRow = 0; outRow < n; outRow++) {
    final i = order[outRow];
    ids[outRow] = state.ids[i];

    final sigmaBin = sigmaBinsCol[i];
    final neverFades = flags[i] & flagNeverFades != 0;
    final sigma =
        neverFades ? double.infinity : math.exp(sigmaBin * steps.sigmaLog);
    final mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, winLen, k: k),
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
    times.add(round9((c.t0 + c.t1) / 2.0));
  }
  times.add(round9(math.max(0.0, durationSec - 1e-6)));
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
    'liveCount': info.state.count.toString(),
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
