// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Streamed reading: front to back, no seeking.
///
/// Works on a file with no index and on a file that was truncated mid-write —
/// records are length-prefixed, so everything complete before the cut is
/// recoverable. That makes this the right mode for validation, conversion and
/// archival scans, and the wrong one for scrubbing a timeline.
library;

import 'dart:typed_data';

import 'chunk_decoder.dart';
import 'exceptions.dart';
import 'model.dart';
import 'opcode.dart';
import 'objects.dart';
import 'provenance.dart';
import 'quantization.dart';
import 'records.dart';
import 'serialization.dart';

class _ObservedAudioRecord {
  const _ObservedAudioRecord(this.name, this.offset, [this.sourceId]);

  final String name;
  final int offset;
  final int? sourceId;
}

/// A whole file, decoded.
class FourdgsScene {
  FourdgsScene({
    required this.header,
    required this.quantization,
    required this.windows,
    required this.gaussians,
    required this.chunkIndex,
    required this.metadata,
    required this.attachments,
    required this.summaryOffsets,
    required this.audioSources,
    required this.skippedOpcodes,
    required this.truncated,
    this.camera,
    this.statistics,
    this.summaryCrcOk,
    FourdgsProvenance? provenance,
    FourdgsObjectLayer? objects,
  }) : provenance = provenance ?? FourdgsProvenance(),
       objects = objects ?? FourdgsObjectLayer();

  final FourdgsHeader header;
  final FourdgsQuantization quantization;
  final List<FourdgsWindow> windows;
  final FourdgsGaussianSet gaussians;
  final List<FourdgsChunkIndexEntry> chunkIndex;
  final List<FourdgsMetadata> metadata;
  final List<FourdgsAttachment> attachments;

  /// Where each class of index record begins, so a seeking reader can fetch one
  /// group without the others. Read here too, because a record no expectation
  /// mentions is a record an implementation can decline to decode.
  final List<FourdgsSummaryOffset> summaryOffsets;

  /// Every independently timed source, ordered by source id.
  final List<FourdgsAudioSource> audioSources;

  /// Opcodes seen but not understood. Kept so a caller can report them and so a
  /// test can prove they were skipped rather than tripped over.
  final List<int> skippedOpcodes;

  /// True when the file ended mid-record and the decode stopped there.
  final bool truncated;

  /// Every provenance record the file carried (spec section 5.15). Empty when
  /// it carried none, which is the common case and not an error: absence costs
  /// nothing and no Header flag announces the family, so this is filled by the
  /// walk itself.
  final FourdgsProvenance provenance;

  /// Every object-layer record the file carried (spec sections 5.15.6-5.15.7).
  /// Empty when it carried none, which is a value and not an error.
  final FourdgsObjectLayer objects;

  /// Compatibility view of the first source as a legacy track.
  ///
  /// New code should use [audioSources], which preserves source identity,
  /// spatial pose, motion and independent timing.
  FourdgsAudioTrack? get audio {
    if (audioSources.isEmpty) return null;
    final source = audioSources.first;
    return FourdgsAudioTrack(
      codec: source.codec,
      data: source.data,
      startSec: source.startSec,
    );
  }

  final FourdgsCameraTrajectory? camera;
  final FourdgsStatistics? statistics;

  /// `true` / `false` when the Footer declared a CRC over the summary block and
  /// it was checked, `null` when it declared none.
  ///
  /// Reported rather than enforced on this path: a front-to-back reader has
  /// already decoded every chunk by the time it reaches the Footer, so a bad
  /// index cannot mislead it the way it misleads a seeking one.
  final bool? summaryCrcOk;

  double get durationSec => header.durationSec;
}

/// Decodes a whole file already in memory.
///
/// [recoverTruncated] keeps whatever was complete before a cut instead of
/// throwing, which is what makes this reader useful on a partial download.
///
/// [maxShBand] caps the spherical-harmonic bands decoded. A front-to-back
/// reader cannot range-skip the bands it does not want — it has already been
/// sent them — so this saves the decode and not the transfer, which is the
/// opposite of what the same cap buys an indexed reader.
FourdgsScene readFourdgsBytes(
  Uint8List data, {
  bool recoverTruncated = true,
  int maxShBand = 3,
}) {
  checkMagic(data);

  FourdgsHeader? header;
  FourdgsQuantization? quantization;
  List<FourdgsWindow> windows = const <FourdgsWindow>[];
  final chunks = <FourdgsDecodedChunk>[];
  // True only when the record walk itself hit the end of the buffer. Distinct
  // from `truncated`, which is also set for a file whose records are all intact
  // but whose closing magic is missing.
  bool recordsRanOut = false;
  final chunkCounts = <int>[];
  final chunkBands = <Map<int, Uint8List>>[];
  final chunkIndex = <FourdgsChunkIndexEntry>[];
  final metadata = <FourdgsMetadata>[];
  final attachments = <FourdgsAttachment>[];
  final summaryOffsets = <FourdgsSummaryOffset>[];
  final skipped = <int>[];
  FourdgsAudioTrack? legacyAudio;
  final audioDescriptors = <int, FourdgsAudioSourceRecord>{};
  final audioPayloads = <int, Uint8List>{};
  _ObservedAudioRecord? firstAudioRecord;
  FourdgsCameraTrajectory? camera;
  FourdgsStatistics? statistics;
  bool? summaryCrcOk;
  bool truncated = false;
  bool sawFooter = false;
  final provenance = FourdgsProvenance();
  final objects = FourdgsObjectLayer();

  try {
    for (final record in iterRecords(data, fourdgsMagic.length)) {
      switch (record.opcode) {
        case opHeader:
          header = FourdgsHeader.parse(record.content);
        case opQuantization:
          quantization = FourdgsQuantization.parse(record.content);
        case opWindowTable:
          windows = FourdgsWindowTable.parse(record.content).windows;
        case opChunk:
          if (quantization == null) {
            throw const FourdgsMalformedFile(
              'a Chunk arrived before the Quantization record',
            );
          }
          final body = parseChunk(record.content);
          chunks.add(
            decodeChunkStreams(
              body.streams,
              body.header.count,
              FourdgsSteps.of(quantization),
              quantization.posOrigin,
              windows,
              cutoff: header?.cutoff ?? fourdgsDefaultCutoff,
              compression: body.header.compression,
            ),
          );
          chunkCounts.add(body.header.count);
          chunkBands.add(<int, Uint8List>{});
        case opShBandStream:
          // Bands belong to the chunk that precedes them — that adjacency is the
          // only thing that says which chunk's gaussians they colour, since a
          // band record carries no chunk identifier of its own. A band record
          // before any chunk has nothing to belong to and is dropped.
          if (chunkBands.isNotEmpty &&
              maxShBand > 0 &&
              record.content.isNotEmpty) {
            final band = record.content[0];
            if (band <= maxShBand) {
              final decoded = decodeShBandRecord(
                record.content,
                expectedBand: band,
                expectedCount: chunkCounts.last,
              );
              if (decoded != null) chunkBands.last[band] = decoded;
            }
          }
        case opAudio:
          firstAudioRecord ??= _ObservedAudioRecord('Audio', record.offset);
          if (legacyAudio != null) {
            throw const FourdgsMalformedFile(
              'the file carries more than one legacy Audio record',
            );
          }
          final a = FourdgsAudio.parse(record.content);
          legacyAudio = FourdgsAudioTrack(
            codec: a.codec,
            data: a.data,
            startSec: a.startSec,
          );
        case opAudioSource:
          if (chunks.isNotEmpty) {
            throw const FourdgsMalformedFile(
              'an Audio Source record appears after the first Chunk',
            );
          }
          final source = FourdgsAudioSourceRecord.parse(record.content);
          firstAudioRecord ??= _ObservedAudioRecord(
            'Audio Source',
            record.offset,
            source.sourceId,
          );
          if (audioDescriptors.containsKey(source.sourceId)) {
            throw FourdgsMalformedFile(
              'Audio Source id ${source.sourceId} appears more than once',
            );
          }
          audioDescriptors[source.sourceId] = source;
        case opAudioData:
          if (chunks.isNotEmpty) {
            throw const FourdgsMalformedFile(
              'an Audio Data record appears after the first Chunk',
            );
          }
          final payload = FourdgsAudioData.parse(record.content);
          firstAudioRecord ??= _ObservedAudioRecord(
            'Audio Data',
            record.offset,
            payload.sourceId,
          );
          if (audioPayloads.containsKey(payload.sourceId)) {
            throw FourdgsMalformedFile(
              'Audio Data id ${payload.sourceId} appears more than once',
            );
          }
          audioPayloads[payload.sourceId] = payload.data;
        case opCamera:
          final c = FourdgsCamera.parse(record.content);
          camera = FourdgsCameraTrajectory(
            fovYDeg: c.fovYDeg,
            position: c.position,
            target: c.target,
            times: c.times,
            positions: c.positions,
            targets: c.targets,
            interpolation: c.interpolation,
            loop: c.loop,
          );
        case opMetadata:
          metadata.add(FourdgsMetadata.parse(record.content));
        case opAttachment:
          attachments.add(FourdgsAttachment.parse(record.content));
        case opCoordinateFrame:
          provenance.frames.add(FourdgsCoordinateFrame.parse(record.content));
        case opSensorCalibration:
          provenance.sensors.add(
            FourdgsSensorCalibration.parse(record.content),
          );
        case opRigTrajectory:
          // Section 5.15.4: a trajectory with no samples "MUST be read as though
          // the record were absent". Reporting it would put a rig in the summary
          // that carries no pose and that no sensor may reference.
          final trajectory = FourdgsRigTrajectory.parse(record.content);
          if (trajectory.sampleCount > 0) {
            provenance.trajectories.add(trajectory);
          }
        case opObjectTable:
          // Read wherever it appears. Section 5.15 is explicit that these
          // records are "skipped and dispatched by opcode, not by position", so
          // a table or track after a Chunk is a legal file — and dropping one
          // loses the post-track state its gaussians require. The indexed
          // opener's front-matter walk stops at the first Chunk and so cannot
          // see them; that asymmetry is a gap in the indexed reader, not a
          // licence for this path to discard data the format allows.
          if (objects.table != null) {
            throw FourdgsMalformedFile(
              'the file carries a second Object Table; a scene has one '
              '(section 5.15.6)',
            );
          }
          objects.table = FourdgsObjectTable.parse(record.content);
          break;
        case opObjectTrack:
          // Section 5.15.7: a zero-sample track "has no pose and is read as
          // absent". Kept, one empty track would make a non-empty object layer,
          // and two empty tracks for an id a duplicate the layer refuses.
          final track = FourdgsObjectTrack.parse(record.content);
          if (track.sampleCount > 0) {
            objects.tracks.add(track);
          }
          break;
        case opGeodeticAnchor:
          provenance.anchors.add(FourdgsGeodeticAnchor.parse(record.content));
        case opStatistics:
          statistics = FourdgsStatistics.parse(record.content);
        case opChunkIndex:
          chunkIndex.add(FourdgsChunkIndexEntry.parse(record.content));
        case opSummaryOffset:
          summaryOffsets.add(FourdgsSummaryOffset.parse(record.content));
        case opFooter:
          sawFooter = true;
          // The Footer's CRC covers `[summaryStart, footerStart)`, and this scan
          // is standing on `footerStart` — so the range is checkable here and
          // nowhere earlier, which is why the check lives in the switch rather
          // than after the loop.
          final footer = FourdgsFooter.parse(record.content);
          if (footer.summaryStart != 0 &&
              footer.summaryCrc != 0 &&
              footer.summaryStart <= record.offset) {
            final summary = Uint8List.sublistView(
              data,
              footer.summaryStart,
              record.offset,
            );
            summaryCrcOk = fourdgsCrc32(summary) == footer.summaryCrc;
          }
        case opAttachmentIndex:
          break;
        default:
          // Unknown or private-range: skipped by length, which is the whole
          // point of the framing.
          skipped.add(record.opcode);
      }
    }
  } on FourdgsTruncatedFile {
    if (!recoverTruncated) rethrow;
    // Recovery is for a file that stopped early, and the closing magic says
    // whether it did. With that magic present every byte is here and the walk
    // still ran off the end, which means a record's own length field lied —
    // internal corruption, not a short download. Recovering would silently
    // discard the real records that follow the corrupt one, a far larger loss
    // than the tail-end truncation this exists to tolerate. The two arrive as
    // the same exception because, from inside the framing scan, they look
    // identical.
    if (_endsWithMagic(data)) rethrow;
    truncated = true;
    recordsRanOut = true;
  }

  // The magic is written at both ends so that a file can be recognized from its
  // tail — and so that a reader can tell a complete file from one that stopped
  // early. Records alone cannot: a download cut exactly at a record boundary
  // walks perfectly and simply ends, which is indistinguishable from success
  // until the closing magic is missing.
  if (!truncated && !_endsWithMagic(data)) {
    if (!recoverTruncated) {
      throw const FourdgsTruncatedFile(
        'the file does not end with the magic; it stopped early',
      );
    }
    truncated = true;
  }

  if (header == null || quantization == null) {
    throw const FourdgsMalformedFile(
      'file has no Header or no Quantization record',
    );
  }

  // The same clock bound `openFourdgsIndexed` applies, so a container is not
  // accepted or refused according to which public decoder opened it. An entry
  // that cannot overlap the scene clock names gaussians no seek will ever
  // select: the file opens cleanly, its CRC verifies, and part of the scene is
  // simply unreachable.
  //
  // Deferred to here rather than checked as each entry is parsed, because
  // nothing orders a Chunk Index after the Header — an index arriving first has
  // no duration to compare against yet, and an early check would let exactly
  // that file through.
  for (final entry in chunkIndex) {
    // `durationSec <= 0` is tested first and unconditionally: `t1 <= 0 ||
    // t0 >= duration` is the complement of an overlap test that only holds for
    // a non-degenerate window, and at duration 0 an entry straddling zero,
    // `[-1, 1)`, satisfies neither half.
    if (entry.gaussianCount > 0 &&
        (header.durationSec <= 0.0 ||
            entry.t1 <= 0.0 ||
            entry.t0 >= header.durationSec)) {
      throw FourdgsMalformedFile(
        'a chunk index entry covers [${entry.t0}, ${entry.t1}), outside the '
        'scene clock [0, ${header.durationSec})',
      );
    }
  }

  final audioSources = _assembleAudioSources(
    header,
    audioDescriptors,
    audioPayloads,
    legacyAudio,
    firstAudioRecord,
    truncated,
  );

  // Placed after the record-level diagnostics above on purpose. This is a tally
  // over the whole file, so it can only say "something is missing"; a record
  // that names its own fault says more, and a reader should hear that first.
  // A complete file whose chunks do not add up to the total its own Header
  // declares.
  //
  // Gated on the RECORD WALK completing, not on `truncated`. Those differ in
  // exactly the case worth catching: a file whose records all parsed but whose
  // closing magic was dropped is marked truncated, yet no later chunk can
  // explain a mismatch — every chunk the file has was decoded. Skipping the
  // check for it would let nine missing bytes wave a quietly short scene
  // through. A walk that really ran out is a different matter: fewer gaussians
  // than the header promises is the expected outcome there, and `truncated` is
  // what reports it.
  if (!recordsRanOut) {
    final assembled = chunkCounts.fold<int>(0, (int sum, int n) => sum + n);
    if (assembled != header.gaussianCount) {
      throw FourdgsMalformedFile(
        'the header declares ${header.gaussianCount} gaussians but the chunks '
        'assemble to $assembled',
      );
    }
  }

  // The cross-record rules — unique sensor names, a rig reference that
  // resolves — can only run once the whole front matter has gone past. A
  // truncated file may legitimately be missing the trajectory a sensor names,
  // so those reference rules are deferred there — but the recovery contract is
  // that everything complete before the cut still stands, and a duplicate name
  // among complete records is exactly that: no later byte can repair it, so it
  // is refused whether or not the file was cut.
  // A cut file defers only what a later record could still have supplied. If a
  // Footer went past, the record stream is complete — the Footer is the last
  // record a file carries — so a missing rig or frame is missing for good and
  // refusing it is right, even though the trailing magic never arrived.
  provenance.check(truncated: truncated && !sawFooter);
  objects.check();

  return FourdgsScene(
    header: header,
    quantization: quantization,
    windows: windows,
    gaussians: assembleGaussians(
      chunks,
      header.shDegree,
      sh:
          header.shDegree == 0
              ? null
              : mergeChunkBands(chunkCounts, chunkBands),
    ),
    chunkIndex: chunkIndex,
    metadata: metadata,
    attachments: attachments,
    summaryOffsets: summaryOffsets,
    audioSources: audioSources,
    skippedOpcodes: skipped,
    truncated: truncated,
    camera: camera,
    statistics: statistics,
    summaryCrcOk: summaryCrcOk,
    provenance: provenance,
    objects: objects,
  );
}

List<FourdgsAudioSource> _assembleAudioSources(
  FourdgsHeader header,
  Map<int, FourdgsAudioSourceRecord> descriptors,
  Map<int, Uint8List> payloads,
  FourdgsAudioTrack? legacy,
  _ObservedAudioRecord? firstAudioRecord,
  bool truncated,
) {
  if (!header.hasAudio &&
      (descriptors.isNotEmpty || payloads.isNotEmpty || legacy != null)) {
    final record = firstAudioRecord!;
    final source =
        record.sourceId == null ? '' : ' for source id ${record.sourceId}';
    throw FourdgsMalformedFile(
      'the Header audio flag is clear, but an ${record.name} record$source '
      'at byte ${record.offset} is present; expected no audio records',
    );
  }
  if (descriptors.isNotEmpty && legacy != null) {
    throw const FourdgsMalformedFile(
      'the file mixes a legacy Audio record with Audio Source records',
    );
  }
  // A legacy Audio record can never coexist with new-format audio. Unlike an unmatched new
  // descriptor — which a lost Audio Source could still have matched in a truncated file — a
  // payload beside a legacy record is an orphan no later bytes can legitimize, so it is
  // refused even in recovery, matching the indexed reader.
  if (legacy != null && payloads.isNotEmpty) {
    final sourceId = payloads.keys.reduce(mathMin);
    throw FourdgsMalformedFile(
      'Audio Data id $sourceId has no matching Audio Source record',
    );
  }

  final sources = <FourdgsAudioSource>[];
  final sourceIds = descriptors.keys.toList()..sort();
  for (final sourceId in sourceIds) {
    final descriptor = descriptors[sourceId]!;
    final data = payloads.remove(sourceId);
    if (data == null) {
      if (truncated) continue;
      throw FourdgsMalformedFile(
        'Audio Source id $sourceId has no matching Audio Data record',
      );
    }
    if (data.length != descriptor.dataLength) {
      throw FourdgsMalformedFile(
        'Audio Source id $sourceId declares ${descriptor.dataLength} data '
        'bytes, its Audio Data record contains ${data.length}',
      );
    }
    _checkAudioKeyframeTimes(descriptor, header.durationSec);
    sources.add(_audioSource(descriptor, data));
  }

  if (payloads.isNotEmpty && !truncated) {
    final sourceId = payloads.keys.reduce(mathMin);
    throw FourdgsMalformedFile(
      'Audio Data id $sourceId has no matching Audio Source record',
    );
  }
  if (legacy != null) {
    sources.add(
      FourdgsAudioSource(
        sourceId: 0,
        name: '',
        codec: legacy.codec,
        channelLayout: '',
        dataLength: legacy.data.length,
        startSec: legacy.startSec,
        durationSec: mathMax(0.0, header.durationSec - legacy.startSec),
        gain: 1.0,
        spatial: false,
        loop: false,
        position: const <double>[0.0, 0.0, 0.0],
        rotation: const <double>[0.0, 0.0, 0.0, 1.0],
        keyframes: const <FourdgsAudioSourceKeyframe>[],
        interpolation: 'linear',
        data: legacy.data,
      ),
    );
  }
  if ((!header.hasAudio && sources.isNotEmpty) ||
      (header.hasAudio && sources.isEmpty && !truncated)) {
    throw FourdgsMalformedFile(
      'the Header audio flag is ${header.hasAudio ? 'set' : 'clear'}, but '
      'the file contains ${sources.length} complete audio sources',
    );
  }
  return sources;
}

int mathMin(int a, int b) => a < b ? a : b;

double mathMax(double a, double b) => a > b ? a : b;

void _checkAudioKeyframeTimes(
  FourdgsAudioSourceRecord source,
  double sceneDuration,
) {
  for (int i = 0; i < source.keyframes.length; i++) {
    final time = source.keyframes[i].time;
    if (time < 0.0 || time > sceneDuration) {
      throw FourdgsMalformedFile(
        'Audio Source id ${source.sourceId} keyframe $i time $time is '
        'outside [0, $sceneDuration]',
      );
    }
  }
}

FourdgsAudioSource _audioSource(
  FourdgsAudioSourceRecord source,
  Uint8List data,
) => FourdgsAudioSource(
  sourceId: source.sourceId,
  name: source.name,
  codec: source.codec,
  channelLayout: source.channelLayout,
  dataLength: source.dataLength,
  startSec: source.startSec,
  durationSec: source.durationSec,
  gain: source.gain,
  spatial: source.spatial,
  loop: source.loop,
  position: source.position,
  rotation: source.rotation,
  keyframes: <FourdgsAudioSourceKeyframe>[
    for (final keyframe in source.keyframes)
      FourdgsAudioSourceKeyframe(
        time: keyframe.time,
        position: keyframe.position,
        rotation: keyframe.rotation,
      ),
  ],
  interpolation: source.interpolation,
  data: data,
);

bool _endsWithMagic(Uint8List data) {
  if (data.length < fourdgsMagic.length) return false;
  final at = data.length - fourdgsMagic.length;
  for (int i = 0; i < fourdgsMagic.length; i++) {
    if (data[at + i] != fourdgsMagic[i]) return false;
  }
  return true;
}

/// Concatenates decoded chunks into one gaussian set.
///
/// Chunks are independently decodable and carry no cross-references, so this is
/// genuinely just concatenation — and gaussian order is an encoder choice that
/// no reader may depend on.
FourdgsGaussianSet assembleGaussians(
  List<FourdgsDecodedChunk> chunks,
  int shDegree, {
  ({Uint8List values, int coefficients})? sh,
}) {
  int total = 0;
  for (final chunk in chunks) {
    total += chunk.count;
  }
  if (total == 0) return FourdgsGaussianSet.empty(shDegree: shDegree);

  final positions = Float32List(total * 3);
  final scales = Float32List(total * 3);
  final rotations = Float32List(total * 4);
  final colors = Float32List(total * 4);
  final motions = Float32List(total * 3);
  final muT = Float32List(total);
  final sigmaT = Float32List(total);
  final winLo = Float32List(total);
  final winHi = Float32List(total);
  final haveSource = chunks.every(
    (FourdgsDecodedChunk c) => c.sourceIndex != null,
  );
  final sourceIndex = haveSource ? Int32List(total) : null;
  // Membership is per chunk and optional, so a file may carry it on some
  // chunks and not others. A chunk without the stream contributes background
  // rather than a hole: the merged array exists when ANY chunk had one, which
  // is what makes null mean "this scene has no object membership" rather than
  // "the last chunk did not".
  final haveObjects = chunks.any((FourdgsDecodedChunk c) => c.objectId != null);
  final objectId = haveObjects ? Uint32List(total) : null;

  int at = 0;
  for (final chunk in chunks) {
    positions.setRange(at * 3, (at + chunk.count) * 3, chunk.positions);
    scales.setRange(at * 3, (at + chunk.count) * 3, chunk.scales);
    rotations.setRange(at * 4, (at + chunk.count) * 4, chunk.rotations);
    colors.setRange(at * 4, (at + chunk.count) * 4, chunk.colors);
    motions.setRange(at * 3, (at + chunk.count) * 3, chunk.motions);
    muT.setRange(at, at + chunk.count, chunk.muT);
    sigmaT.setRange(at, at + chunk.count, chunk.sigmaT);
    winLo.setRange(at, at + chunk.count, chunk.winLo);
    winHi.setRange(at, at + chunk.count, chunk.winHi);
    if (sourceIndex != null) {
      sourceIndex.setRange(at, at + chunk.count, chunk.sourceIndex!);
    }
    if (objectId != null && chunk.objectId != null) {
      objectId.setRange(at, at + chunk.count, chunk.objectId!);
    }
    at += chunk.count;
  }

  return FourdgsGaussianSet(
    positions: positions,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: motions,
    muT: muT,
    sigmaT: sigmaT,
    winLo: winLo,
    winHi: winHi,
    shDegree: shDegree,
    sh: sh?.values,
    shCoefficients: sh?.coefficients ?? 0,
    sourceIndex: sourceIndex,
    objectId: objectId,
  );
}
