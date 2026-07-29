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
import 'quantization.dart';
import 'records.dart';
import 'serialization.dart';

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
    required this.skippedOpcodes,
    required this.truncated,
    this.audio,
    this.camera,
    this.statistics,
    this.summaryCrcOk,
  });

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

  /// Opcodes seen but not understood. Kept so a caller can report them and so a
  /// test can prove they were skipped rather than tripped over.
  final List<int> skippedOpcodes;

  /// True when the file ended mid-record and the decode stopped there.
  final bool truncated;

  /// `null` when the scene has no soundtrack, which is the common case and not
  /// an error.
  final FourdgsAudioTrack? audio;

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
  final chunkCounts = <int>[];
  final chunkBands = <Map<int, Uint8List>>[];
  final chunkIndex = <FourdgsChunkIndexEntry>[];
  final metadata = <FourdgsMetadata>[];
  final attachments = <FourdgsAttachment>[];
  final summaryOffsets = <FourdgsSummaryOffset>[];
  final skipped = <int>[];
  FourdgsAudioTrack? audio;
  FourdgsCameraTrajectory? camera;
  FourdgsStatistics? statistics;
  bool? summaryCrcOk;
  bool truncated = false;

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
          final a = FourdgsAudio.parse(record.content);
          audio = FourdgsAudioTrack(
            codec: a.codec,
            data: a.data,
            startSec: a.startSec,
          );
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
        case opStatistics:
          statistics = FourdgsStatistics.parse(record.content);
        case opChunkIndex:
          chunkIndex.add(FourdgsChunkIndexEntry.parse(record.content));
        case opSummaryOffset:
          summaryOffsets.add(FourdgsSummaryOffset.parse(record.content));
        case opFooter:
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
    truncated = true;
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
    skippedOpcodes: skipped,
    truncated: truncated,
    audio: audio,
    camera: camera,
    statistics: statistics,
    summaryCrcOk: summaryCrcOk,
  );
}

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
  );
}
