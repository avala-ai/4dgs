// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Indexed reading: the Footer, then the index, then only what an instant needs.
///
/// The seek rule is one line and it is the whole algorithm:
///
///     chunksForTime(t) == every index entry whose [t0, t1) contains t
///
/// Whether that is cheap depends on the content, not on this code. Gaussians
/// with finite lifetimes partition into many small chunks; content where
/// everything lives for the whole clip collapses to a single entry and an
/// instant costs the scene. Both are correct files.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'chunk_decoder.dart';
import 'exceptions.dart';
import 'model.dart';
import 'opcode.dart';
import 'objects.dart';
import 'provenance.dart';
import 'quantization.dart';
import 'readable.dart';
import 'records.dart';
import 'serialization.dart';

/// One read of this size from the front covers the header records of every
/// scene measured so far. A larger header costs one extra round trip, never a
/// wrong parse.
const int fourdgsHeadProbeBytes = 64 * 1024;

/// The independently readable ranges belonging to one audio source.
///
/// [descriptorRange] is `null` only for a legacy Audio record. [dataOffset] and
/// [dataLength] point directly at codec bytes, so a caller can fetch a slice
/// without transferring record framing or another source.
class FourdgsIndexedAudioSource {
  const FourdgsIndexedAudioSource({
    required this.sourceId,
    required this.descriptorRange,
    required this.dataOffset,
    required this.dataLength,
    this.legacyCodec,
    this.legacyStartSec,
  });

  final int sourceId;
  final ({int offset, int length})? descriptorRange;
  final int dataOffset;
  final int dataLength;
  final String? legacyCodec;
  final double? legacyStartSec;
}

/// A scene opened over byte ranges: everything needed to decide what to fetch,
/// and nothing that had to be fetched to decide it.
class FourdgsIndexedScene {
  const FourdgsIndexedScene({
    required this.header,
    required this.quantization,
    required this.windows,
    required this.index,
    required this.headerBytes,
    required this.resourceBytes,
    required this.audioSourceRanges,
    this.summaryCrcOk,
    this.cameraRange,
    this.metadataRanges = const <({int offset, int length})>[],
    this.attachmentRanges = const <({int offset, int length})>[],
    this.provenanceRanges = const <({int opcode, int offset, int length})>[],
    this.statistics,
    this.summaryOffsets = const <FourdgsSummaryOffset>[],
  });

  final FourdgsHeader header;
  final FourdgsQuantization quantization;
  final List<FourdgsWindow> windows;
  final List<FourdgsChunkIndexEntry> index;

  /// Bytes of the file that had to be read to open it — the header probe. Kept
  /// so a caller can report what opening actually cost.
  final int headerBytes;

  /// Total size of the resource. Kept because every byte range this reader
  /// later issues comes out of the index, and an index is just bytes in the
  /// file: without something true to check them against, a corrupt entry asks a
  /// server for a range that does not exist and a browser for the memory to
  /// hold it.
  final int resourceBytes;

  /// Descriptor and payload ranges for every independent source.
  final List<FourdgsIndexedAudioSource> audioSourceRanges;

  /// Compatibility view of the first encoded payload range.
  ({int offset, int length})? get audioRange =>
      audioSourceRanges.isEmpty
          ? null
          : (
            offset: audioSourceRanges.first.dataOffset,
            length: audioSourceRanges.first.dataLength,
          );

  /// Available without fetching a descriptor only for a legacy Audio record.
  String? get audioCodec =>
      audioSourceRanges.isEmpty ? null : audioSourceRanges.first.legacyCodec;

  double get audioStartSec =>
      audioSourceRanges.isEmpty
          ? 0.0
          : audioSourceRanges.first.legacyStartSec ?? 0.0;

  /// `true` / `false` when the Footer declared a CRC and it was checked,
  /// `null` when it declared none.
  final bool? summaryCrcOk;

  /// Byte range of the Camera record, or `null` when the scene has none.
  ///
  /// A range rather than the record, for the same reason audio is: opening a
  /// scene frames what is there and reads only what a reader must have. A camera
  /// nobody asked for costs nothing, and neither does an attachment the size of
  /// a thumbnail sheet.
  final ({int offset, int length})? cameraRange;

  final List<({int offset, int length})> metadataRanges;
  final List<({int offset, int length})> attachmentRanges;

  /// `(opcode, offset, length)` of every provenance-family record framed during
  /// the walk. Opening a file frames these and stops, so a scene with a long
  /// rig trajectory costs the same to open as one with none. Call
  /// [readFourdgsProvenance] when the records themselves are wanted.
  final List<({int opcode, int offset, int length})> provenanceRanges;

  /// Advisory totals from the summary block. A reader that needs certainty
  /// computes from the chunks instead.
  final FourdgsStatistics? statistics;

  /// Where each class of index record begins, so one group can be fetched
  /// without the others.
  final List<FourdgsSummaryOffset> summaryOffsets;

  /// Answered from the Header alone, per the format's audio-discovery rule.
  bool get hasAudio => header.hasAudio;

  /// Learned from record prefixes without transferring encoded audio bytes.
  int get audioSourceCount => audioSourceRanges.length;

  double get durationSec => header.durationSec;

  /// The normative seek rule.
  List<FourdgsChunkIndexEntry> chunksForTime(double t) => index
      .where((FourdgsChunkIndexEntry e) => e.covers(t))
      .toList(growable: false);

  /// Every chunk that can hold a gaussian visible anywhere in `[a, b)`.
  List<FourdgsChunkIndexEntry> chunksForRange(double a, double b) => index
      .where((FourdgsChunkIndexEntry e) => e.overlaps(a, b))
      .toList(growable: false);

  /// What a seek to [t] will transfer, so a caller can budget before asking.
  int bytesForTime(double t, {int maxShBand = 0}) =>
      _bytesFor(chunksForTime(t), maxShBand);

  /// What covering `[a, b)` will transfer.
  int bytesForRange(double a, double b, {int maxShBand = 0}) =>
      _bytesFor(chunksForRange(a, b), maxShBand);

  int _bytesFor(List<FourdgsChunkIndexEntry> entries, int maxShBand) {
    int total = 0;
    for (final entry in entries) {
      total += entry.chunkLength;
      for (final band in entry.bands) {
        if (band.band <= maxShBand) total += band.length;
      }
    }
    return total;
  }
}

/// Opens a scene: a bounded read from the front, then the index. Never the file.
///
/// [probeBytes] is how much of the front to read at once. The default covers
/// every scene measured so far in one request; a smaller value is correct and
/// simply costs more round trips, which is what makes it the honest way to test
/// the multi-read paths without fabricating a scene with a 64 KiB header.
Future<FourdgsIndexedScene> openFourdgsIndexed(
  FourdgsReadable source, {
  int probeBytes = fourdgsHeadProbeBytes,
}) async {
  final size = await source.size();
  if (size <= 0) throw const FourdgsTruncatedFile('resource is empty');
  if (probeBytes < recordHeaderBytes + fourdgsMagic.length) {
    throw ArgumentError(
      '4dgs: a probe of $probeBytes bytes cannot hold the magic and one record header',
    );
  }

  final front = await _readFrontMatter(source, size, probeBytes);
  if (front.header == null || front.quantization == null) {
    throw const FourdgsMalformedFile(
      'the file has no Header or no Quantization record before its first chunk',
    );
  }
  final audioSourceRanges = _pairIndexedAudioSources(front);
  if (front.header!.hasAudio != audioSourceRanges.isNotEmpty) {
    throw FourdgsMalformedFile(
      'the Header audio flag is ${front.header!.hasAudio ? 'set' : 'clear'}, '
      'but the file contains ${audioSourceRanges.length} audio sources',
    );
  }

  // Footer record (9 + 20 bytes) then the trailing magic.
  final footerBytes = recordHeaderBytes + 20 + fourdgsMagic.length;
  if (size < footerBytes) {
    throw const FourdgsTruncatedFile('file is too short to hold a footer');
  }
  final tail = await source.read(size - footerBytes, footerBytes);
  for (int i = 0; i < fourdgsMagic.length; i++) {
    if (tail[tail.length - fourdgsMagic.length + i] != fourdgsMagic[i]) {
      throw const FourdgsMalformedFile(
        'file does not end with the magic; it may be truncated',
      );
    }
  }
  final footerRecord = readRecord(FourdgsCursor(tail));
  if (footerRecord.opcode != opFooter) {
    throw FourdgsMalformedFile(
      'expected a Footer at the tail, found opcode 0x${footerRecord.opcode.toRadixString(16)}',
    );
  }
  final footer = FourdgsFooter.parse(footerRecord.content);

  final index = <FourdgsChunkIndexEntry>[];
  // Where each entry above came from. A refusal that can only say which interval
  // was wrong leaves the reader of a file with a thousand index records nothing
  // to open a hex editor at; the offset is known here and nowhere later.
  final indexRecordOffsets = <int>[];
  final summaryOffsets = <FourdgsSummaryOffset>[];
  FourdgsStatistics? statistics;
  bool? crcOk;
  if (footer.summaryStart != 0) {
    final summaryLength = size - footerBytes - footer.summaryStart;
    if (summaryLength < 0) {
      throw const FourdgsMalformedFile(
        'the footer points its summary past the end of the file',
      );
    }
    if (summaryLength > maxFrontMatterBytes) {
      throw FourdgsMalformedFile(
        'the footer points at a $summaryLength byte summary, past the $maxFrontMatterBytes ceiling',
      );
    }
    final summary = await source.read(footer.summaryStart, summaryLength);
    if (footer.summaryCrc != 0) {
      crcOk = fourdgsCrc32(summary) == footer.summaryCrc;
      if (!crcOk) {
        // The index is the one structure a seeking reader cannot sanity-check
        // by reading it — every offset in it looks equally plausible. When the
        // file itself says the bytes are wrong, believing them anyway means
        // seeking on corrupt offsets for the rest of the session.
        throw const FourdgsMalformedFile(
          'the chunk index does not match the CRC the footer declared for it',
        );
      }
    }
    for (final record in iterRecords(summary)) {
      switch (record.opcode) {
        case opChunkIndex:
          // Checked inside the loop, not after it. Unlike the window table there
          // is no declared count to disprove against the bytes — entries are
          // discovered by walking records — so the only bound available is a
          // ceiling, and it is worth nothing unless it stops the walk. A 64 MiB
          // summary holds well over a million minimal chunk-index records, each
          // materialized here as an object with its own band list.
          if (index.length == maxChunkIndexEntries) {
            throw FourdgsMalformedFile(
              'the chunk index holds more than $maxChunkIndexEntries entries',
            );
          }
          index.add(
            FourdgsChunkIndexEntry.parse(
              record.content,
              // Where the content starts, not the record: `iterRecords` is over a
              // detached summary buffer here, so the file origin is the summary's.
              fileOffset:
                  footer.summaryStart + record.offset + recordHeaderBytes,
            ),
          );
          // File-relative, not summary-relative. `iterRecords` walks the buffer
          // fetched at `footer.summaryStart`, so its offsets start from zero
          // there — storing one raw would send whoever reads the diagnostic to
          // the wrong byte, and to a different byte than the streamed reader
          // names for the same record.
          indexRecordOffsets.add(footer.summaryStart + record.offset);
        case opStatistics:
          statistics = FourdgsStatistics.parse(record.content);
        case opSummaryOffset:
          summaryOffsets.add(FourdgsSummaryOffset.parse(record.content));
        default:
          break;
      }
    }
  }

  // The same clock bound the streamed reader applies, so a container is not
  // accepted or refused according to which opener was used. An entry that
  // cannot overlap the scene clock names gaussians `chunksForTime` will never
  // select: the file opens cleanly, its CRC verifies, and part of the scene is
  // quietly unreachable.
  //
  // After the walk rather than inside it, because nothing orders a Chunk Index
  // after the Header — an index arriving first has no duration to compare
  // against yet.
  final double duration = front.header!.durationSec;
  // What makes `liveCount` mean anything. See [indexEntryPopulation].
  final bool isKeyframeDelta = front.header!.temporalModel == 'keyframe-delta';
  for (int i = 0; i < index.length; i++) {
    final entry = index[i];
    // A zero-duration scene is not a scene with no clock — a static asset is
    // written that way, with one nonempty entry just past zero — so the end of
    // the clock only bounds an entry when there IS an end. The start still
    // does: at duration zero the only instant a seek can ask for is 0, so an
    // entry beginning after it is unreachable.
    final String where =
        'the Chunk Index record at byte ${indexRecordOffsets[i]} (entry $i of ${index.length})';
    checkIndexEntry(entry, isKeyframeDelta: isKeyframeDelta, where: where);
    final int population = indexEntryPopulation(
      entry,
      isKeyframeDelta: isKeyframeDelta,
    );
    if (population > 0 &&
        (entry.t1 <= 0.0 ||
            (duration > 0.0 ? entry.t0 >= duration : entry.t0 > 0.0))) {
      throw FourdgsMalformedFile(
        'the Chunk Index record at byte ${indexRecordOffsets[i]} (entry $i of '
        '${index.length}) covers [${entry.t0}, ${entry.t1}), outside the scene '
        'clock [0, $duration); expected an interval that overlaps it, or an '
        'empty entry',
      );
    }
  }

  // The same total the streamed reader cross-checks, from the only evidence this
  // path has: the index itself. Without it an inflated header count is refused
  // by one opener and returned as fact by the other — every chunk readable, the
  // CRC verifying, and the scene claiming gaussians it does not have.
  //
  // `gaussian-birth` only. A keyframe-delta index describes operations composing
  // onto a keyframe, so its entries do not sum to the population and the header
  // total is not their sum. An empty index says nothing either way.
  if (index.isNotEmpty && front.header!.temporalModel == 'gaussian-birth') {
    final int declared = front.header!.gaussianCount;
    final int indexed = index.fold<int>(
      0,
      (int sum, e) => sum + e.gaussianCount,
    );
    if (indexed != declared) {
      throw FourdgsMalformedFile(
        'the Header declares $declared gaussians but the Chunk Index accounts '
        'for $indexed; expected the two to agree under gaussian-birth',
      );
    }
  }

  return FourdgsIndexedScene(
    header: front.header!,
    quantization: front.quantization!,
    windows: front.windows,
    index: index,
    headerBytes: front.bytesRead,
    resourceBytes: size,
    audioSourceRanges: audioSourceRanges,
    summaryCrcOk: crcOk,
    cameraRange: front.cameraRange,
    metadataRanges: front.metadataRanges,
    attachmentRanges: front.attachmentRanges,
    provenanceRanges: front.provenanceRanges,
    statistics: statistics,
    summaryOffsets: summaryOffsets,
  );
}

/// Fetches and decodes one chunk, plus only the SH bands asked for.
Future<FourdgsDecodedChunk> readFourdgsChunk(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  FourdgsChunkIndexEntry entry, {
  int maxShBand = 0,
}) async {
  _checkRange(scene, entry.chunkOffset, entry.chunkLength, 'chunk');
  final blob = await source.read(entry.chunkOffset, entry.chunkLength);
  final body = parseChunk(_recordContent(blob, opChunk, 'chunk'));
  if (body.header.t0 != entry.t0 || body.header.t1 != entry.t1) {
    // The index's interval is what selected this chunk. If the chunk disagrees
    // it is being played at the wrong time, which shows up as a cohort missing
    // from the moment it belongs to rather than as an error.
    throw FourdgsMalformedFile(
      'index says this chunk covers [${entry.t0}, ${entry.t1}), the chunk says [${body.header.t0}, ${body.header.t1})',
    );
  }
  if (body.header.count != entry.gaussianCount) {
    // The index is a summary of the chunks, so the two saying different things
    // means one of them is wrong and there is no way to tell which. Cheap to
    // check, and it catches an index built against a different revision of the
    // file — which otherwise shows up as a scene that is quietly missing part
    // of itself.
    throw FourdgsMalformedFile(
      'index says this chunk holds ${entry.gaussianCount} gaussians, the chunk says ${body.header.count}',
    );
  }

  final bandRecords = <int, Uint8List>{};
  for (final band in entry.bands) {
    if (band.band > maxShBand) continue;
    _checkRange(scene, band.offset, band.length, 'SH band ${band.band}');
    final bandBlob = await source.read(band.offset, band.length);
    bandRecords[band.band] = _recordContent(
      bandBlob,
      opShBandStream,
      'SH band ${band.band}',
    );
  }

  return decodeChunkStreams(
    body.streams,
    body.header.count,
    FourdgsSteps.of(scene.quantization),
    scene.quantization.posOrigin,
    scene.windows,
    cutoff: scene.header.cutoff,
    compression: body.header.compression,
    shBandRecords: bandRecords,
    chunkOffset: entry.chunkOffset,
    streamsOffset: entry.chunkOffset + recordHeaderBytes + body.streamsOffset,
  );
}

/// The embedded track's bytes, fetched independently of any gaussian data.
///
/// `null` when the scene has none — a normal value, not an error.
Future<FourdgsAudioTrack?> readFourdgsAudio(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  if (scene.audioSourceRanges.isEmpty) return null;
  final audio = await _readAudioSource(
    source,
    scene,
    scene.audioSourceRanges.first,
  );
  return FourdgsAudioTrack(
    codec: audio.codec,
    data: audio.data,
    startSec: audio.startSec,
  );
}

/// Fetches every source descriptor and encoded payload.
Future<List<FourdgsAudioSource>> readFourdgsAudioSources(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = <FourdgsAudioSource>[];
  for (final entry in scene.audioSourceRanges) {
    out.add(await _readAudioSource(source, scene, entry));
  }
  return out;
}

/// Fetches small source descriptors without transferring encoded payloads.
Future<List<FourdgsAudioSourceDescriptor>> readFourdgsAudioSourceDescriptors(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = <FourdgsAudioSourceDescriptor>[];
  for (final entry in scene.audioSourceRanges) {
    out.add(await _readAudioSourceDescriptor(source, scene, entry));
  }
  return out;
}

/// Reconstructs one source at scene time [t] without transferring its payload.
Future<FourdgsAudioSourceState> readFourdgsAudioSourceState(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  int sourceId,
  double t,
) async {
  final entry = _audioEntry(scene, sourceId);
  return (await _readAudioSourceDescriptor(source, scene, entry)).stateAt(t);
}

/// Validates the small descriptor, then reads one source-relative payload range.
Future<Uint8List> readFourdgsAudioRange(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  int sourceId,
  int offset,
  int length,
) async {
  final entry = _audioEntry(scene, sourceId);
  await _readAudioSourceDescriptor(source, scene, entry);
  if (offset < 0 || length < 0 || offset + length > entry.dataLength) {
    throw FourdgsMalformedFile(
      'audio source $sourceId range [$offset, ${offset + length}) is outside '
      'its ${entry.dataLength}-byte payload',
    );
  }
  _checkRange(
    scene,
    entry.dataOffset + offset,
    length,
    'audio source $sourceId payload',
  );
  return source.read(entry.dataOffset + offset, length);
}

FourdgsIndexedAudioSource _audioEntry(FourdgsIndexedScene scene, int sourceId) {
  for (final entry in scene.audioSourceRanges) {
    if (entry.sourceId == sourceId) return entry;
  }
  throw FourdgsMalformedFile('this scene has no audio source id $sourceId');
}

Future<FourdgsAudioSource> _readAudioSource(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  FourdgsIndexedAudioSource entry,
) async {
  final descriptor = await _readAudioSourceDescriptor(source, scene, entry);
  _checkRange(
    scene,
    entry.dataOffset,
    entry.dataLength,
    'audio source ${entry.sourceId} payload',
  );
  final data = await source.read(entry.dataOffset, entry.dataLength);
  return FourdgsAudioSource(
    sourceId: descriptor.sourceId,
    name: descriptor.name,
    codec: descriptor.codec,
    channelLayout: descriptor.channelLayout,
    dataLength: descriptor.dataLength,
    startSec: descriptor.startSec,
    durationSec: descriptor.durationSec,
    gain: descriptor.gain,
    spatial: descriptor.spatial,
    loop: descriptor.loop,
    position: descriptor.position,
    rotation: descriptor.rotation,
    keyframes: descriptor.keyframes,
    interpolation: descriptor.interpolation,
    data: data,
  );
}

Future<FourdgsAudioSourceDescriptor> _readAudioSourceDescriptor(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  FourdgsIndexedAudioSource entry,
) async {
  final range = entry.descriptorRange;
  if (range == null) {
    final startSec = entry.legacyStartSec ?? 0.0;
    return FourdgsAudioSourceDescriptor(
      sourceId: entry.sourceId,
      name: '',
      codec: entry.legacyCodec ?? '',
      channelLayout: '',
      dataLength: entry.dataLength,
      startSec: startSec,
      durationSec: math.max(0.0, scene.header.durationSec - startSec),
      gain: 1.0,
      spatial: false,
      loop: false,
      position: const <double>[0.0, 0.0, 0.0],
      rotation: const <double>[0.0, 0.0, 0.0, 1.0],
      keyframes: const <FourdgsAudioSourceKeyframe>[],
      interpolation: 'linear',
    );
  }

  _checkRange(
    scene,
    range.offset,
    range.length,
    'Audio Source descriptor',
    frontMatter: true,
  );
  final blob = await source.read(range.offset, range.length);
  final parsed = FourdgsAudioSourceRecord.parse(
    _recordContent(blob, opAudioSource, 'Audio Source descriptor'),
  );
  if (parsed.sourceId != entry.sourceId) {
    throw FourdgsMalformedFile(
      'Audio Source range for id ${entry.sourceId} contains id '
      '${parsed.sourceId}',
    );
  }
  if (parsed.dataLength != entry.dataLength) {
    throw FourdgsMalformedFile(
      'Audio Source id ${entry.sourceId} declares ${parsed.dataLength} bytes, '
      'its Audio Data record declares ${entry.dataLength}',
    );
  }
  _checkIndexedAudioKeyframeTimes(parsed, scene.header.durationSec);
  return FourdgsAudioSourceDescriptor(
    sourceId: parsed.sourceId,
    name: parsed.name,
    codec: parsed.codec,
    channelLayout: parsed.channelLayout,
    dataLength: parsed.dataLength,
    startSec: parsed.startSec,
    durationSec: parsed.durationSec,
    gain: parsed.gain,
    spatial: parsed.spatial,
    loop: parsed.loop,
    position: parsed.position,
    rotation: parsed.rotation,
    keyframes: <FourdgsAudioSourceKeyframe>[
      for (final keyframe in parsed.keyframes)
        FourdgsAudioSourceKeyframe(
          time: keyframe.time,
          position: keyframe.position,
          rotation: keyframe.rotation,
        ),
    ],
    interpolation: parsed.interpolation,
  );
}

void _checkIndexedAudioKeyframeTimes(
  FourdgsAudioSourceRecord source,
  double sceneDuration,
) {
  for (int i = 0; i < source.keyframes.length; i++) {
    final time = source.keyframes[i].time;
    if (time < 0.0 || time > sceneDuration) {
      throw FourdgsMalformedFile(
        'Audio Source id ${source.sourceId} keyframe $i time $time is outside '
        '[0, $sceneDuration]',
      );
    }
  }
}

/// The suggested camera trajectory, fetched only when a caller wants it.
///
/// `null` when the scene has none. Advisory in the format and advisory here:
/// nothing in decoding depends on it.
Future<FourdgsCameraTrajectory?> readFourdgsCamera(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final range = scene.cameraRange;
  if (range == null) return null;
  _checkRange(scene, range.offset, range.length, 'camera', frontMatter: true);
  final blob = await source.read(range.offset, range.length);
  final camera = FourdgsCamera.parse(
    _recordContent(blob, opCamera, 'camera'),
    fileOffset: range.offset + recordHeaderBytes,
  );
  return FourdgsCameraTrajectory(
    fovYDeg: camera.fovYDeg,
    position: camera.position,
    target: camera.target,
    times: camera.times,
    positions: camera.positions,
    targets: camera.targets,
    interpolation: camera.interpolation,
    loop: camera.loop,
  );
}

/// Every Metadata record, by range.
Future<List<FourdgsMetadata>> readFourdgsMetadata(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = <FourdgsMetadata>[];
  for (final range in scene.metadataRanges) {
    _checkRange(
      scene,
      range.offset,
      range.length,
      'metadata',
      frontMatter: true,
    );
    final blob = await source.read(range.offset, range.length);
    out.add(
      FourdgsMetadata.parse(_recordContent(blob, opMetadata, 'metadata')),
    );
  }
  return out;
}

/// Every Attachment record, by range. Each one costs exactly its own bytes, so
/// a caller that wants a thumbnail does not pay for a licence file beside it.
Future<List<FourdgsAttachment>> readFourdgsAttachments(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = <FourdgsAttachment>[];
  for (final range in scene.attachmentRanges) {
    // Exempt from the front-matter ceiling: section 5 says attachments "carry
    // payload, and payload of unbounded size — a thumbnail sheet, a provenance
    // blob". Capping them refuses on the indexed path a file the streamed path
    // reads, which is the same mistake as capping chunk data.
    _checkRange(scene, range.offset, range.length, 'attachment');
    final blob = await source.read(range.offset, range.length);
    out.add(
      FourdgsAttachment.parse(_recordContent(blob, opAttachment, 'attachment')),
    );
  }
  return out;
}

/// Every provenance record, by range, fetched only when a caller wants them.
///
/// Opening a file frames these and stops, so a scene with a long rig trajectory
/// costs the same to open as one with none. This is where a caller says it
/// wants them.
///
/// The object-layer records (`0x24`, `0x25`) are in the same opcode family and
/// are framed by the same walk, but they belong to the object layer rather than
/// provenance, so they are skipped here — [readFourdgsObjects] reads them from
/// the same ranges. A still-reserved opcode (`0x26`–`0x2F`) is framed and
/// skipped by both, which is the forward-compatibility rule doing its job
/// inside a family — and why the ranges carry their opcode.
Future<FourdgsProvenance> readFourdgsProvenance(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = FourdgsProvenance();
  for (final range in scene.provenanceRanges) {
    final opcode = range.opcode;
    if (opcode != opCoordinateFrame &&
        opcode != opSensorCalibration &&
        opcode != opRigTrajectory &&
        opcode != opGeodeticAnchor) {
      continue;
    }
    _checkRange(
      scene,
      range.offset,
      range.length,
      'provenance',
      frontMatter: true,
    );
    final blob = await source.read(range.offset, range.length);
    final content = _recordContent(blob, opcode, 'provenance');
    switch (opcode) {
      case opCoordinateFrame:
        out.frames.add(FourdgsCoordinateFrame.parse(content));
      case opSensorCalibration:
        out.sensors.add(FourdgsSensorCalibration.parse(content));
      case opRigTrajectory:
        // Section 5.15.4: a trajectory with no samples is read as though absent.
        final trajectory = FourdgsRigTrajectory.parse(content);
        if (trajectory.sampleCount > 0) out.trajectories.add(trajectory);
      case opGeodeticAnchor:
        out.anchors.add(FourdgsGeodeticAnchor.parse(content));
    }
  }
  out.check();
  return out;
}

/// Every object-layer record, from the same framed ranges as provenance.
///
/// Deferred for the same reason: a scene with a thousand-sample track costs
/// nothing to open, and a consumer that only wants geometry never pays for the
/// layer at all.
Future<FourdgsObjectLayer> readFourdgsObjects(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
) async {
  final out = FourdgsObjectLayer();
  for (final range in scene.provenanceRanges) {
    final opcode = range.opcode;
    if (opcode != opObjectTable && opcode != opObjectTrack) continue;
    // Refused before the read, not after: the opcode is already known from the
    // front-matter walk, so a second table need not be transferred and
    // materialized — up to the front-matter cap — only to be rejected below.
    if (opcode == opObjectTable && out.table != null) {
      throw const FourdgsMalformedFile(
        'the file carries a second Object Table; a scene has one '
        '(section 5.15.6)',
      );
    }
    _checkRange(
      scene,
      range.offset,
      range.length,
      'object layer',
      frontMatter: true,
    );
    final blob = await source.read(range.offset, range.length);
    final content = _recordContent(blob, opcode, 'object layer');
    if (opcode == opObjectTable) {
      if (out.table != null) {
        throw FourdgsMalformedFile(
          'the file carries a second Object Table; a scene has one '
          '(section 5.15.6)',
        );
      }
      out.table = FourdgsObjectTable.parse(content);
    } else {
      // Section 5.15.7: a zero-sample track "has no pose and is read as absent".
      final track = FourdgsObjectTrack.parse(content);
      if (track.sampleCount > 0) {
        out.tracks.add(track);
      }
    }
  }
  out.check();
  return out;
}

/// Refuses a byte range the index asked for but the file cannot contain.
///
/// Checked *before* the read, not after: `_recordContent` validates framing,
/// but by then the bytes have already been requested from a server and
/// materialized in memory. An index entry is attacker-controlled `u64`, so
/// without this a single corrupt field asks for the whole address space.
void _checkRange(
  FourdgsIndexedScene scene,
  int offset,
  int length,
  String what, {
  bool frontMatter = false,
}) {
  if (offset < 0 || length < 0 || offset + length > scene.resourceBytes) {
    throw FourdgsMalformedFile(
      'the $what range is [$offset, ${offset + length}) of a '
      '${scene.resourceBytes} byte file',
    );
  }
  // Front matter only. Chunk and SH band payloads are gaussian data, bounded by
  // the per-stream decoded-size caps rather than by this ceiling, and a
  // legitimate scene can carry a chunk far larger than it — capping them here
  // refuses on the indexed path a file the streamed path decodes happily.
  if (frontMatter && length > maxFrontMatterBytes) {
    throw FourdgsMalformedFile(
      'the $what range is $length bytes, past the $maxFrontMatterBytes ceiling',
    );
  }
}

/// Unwraps a record fetched by byte range, checking it is the record the index
/// said it would be.
///
/// The index could have been written with every offset shifted, and a decoder
/// that trusted it would produce plausible nonsense from the wrong bytes. One
/// opcode comparison turns that into an immediate, named failure.
Uint8List _recordContent(Uint8List blob, int expectedOpcode, String what) {
  if (blob.length < recordHeaderBytes) {
    throw FourdgsTruncatedFile('$what range is shorter than a record header');
  }
  final cursor = FourdgsCursor(blob);
  final opcode = cursor.u8();
  final length = cursor.u64();
  if (opcode != expectedOpcode) {
    throw FourdgsMalformedFile(
      '$what range starts with opcode 0x${opcode.toRadixString(16)}, expected 0x${expectedOpcode.toRadixString(16)}',
    );
  }
  if (recordHeaderBytes + length > blob.length) {
    throw FourdgsTruncatedFile(
      '$what record declares $length content bytes, range holds ${blob.length - recordHeaderBytes}',
    );
  }
  // And the range must not be LONGER than the record either. Trailing bytes
  // look harmless — they were simply ignored — but they are what lets a crafted
  // index name one chunk many times: pad each entry's length differently and
  // every `offset:length` pair is distinct, so the slice's duplicate-range
  // check waves them through while all of them decode the same record and
  // duplicate its splats and its allocation. An index entry describes exactly
  // one framed record; anything else is a disagreement worth refusing.
  if (recordHeaderBytes + length != blob.length) {
    throw FourdgsMalformedFile(
      '$what range holds ${blob.length} bytes for a ${recordHeaderBytes + length} byte record; the index must name the record exactly',
    );
  }
  return Uint8List.sublistView(
    blob,
    recordHeaderBytes,
    recordHeaderBytes + length,
  );
}

/// What the front of the file yielded.
class _FrontMatter {
  FourdgsHeader? header;
  FourdgsQuantization? quantization;
  List<FourdgsWindow> windows = const <FourdgsWindow>[];
  FourdgsIndexedAudioSource? legacyAudio;
  final Map<int, ({int offset, int length})> audioSourceRanges =
      <int, ({int offset, int length})>{};
  final Map<int, ({int offset, int length})> audioDataRanges =
      <int, ({int offset, int length})>{};
  ({int offset, int length})? cameraRange;
  final List<({int offset, int length})> metadataRanges =
      <({int offset, int length})>[];
  final List<({int offset, int length})> attachmentRanges =
      <({int offset, int length})>[];
  final List<({int opcode, int offset, int length})> provenanceRanges =
      <({int opcode, int offset, int length})>[];

  /// Bytes actually transferred to open the scene.
  int bytesRead = 0;
}

/// Round-trip cap for reading the front matter.
///
/// Not an expected count — one or two reads cover every real scene, and the loop
/// is guaranteed to advance because every record is at least its own 9-byte
/// header. This is a ceiling on what a pathological file can cost a reader
/// before it gives up and reports what it could not find. It is generous because
/// the scan now runs to the first Chunk: a file may legitimately carry several
/// records larger than the probe before it, and each costs a round.
const int _maxFrontMatterReads = 256;

/// Enough of a legacy Audio record to hold its descriptor without its payload.
const int _legacyAudioPrefixBytes = 512;

/// The most this reader will transfer in one go for a header record or for the
/// whole summary block.
///
/// Both lengths come out of the file itself, so without a ceiling a hostile —
/// or merely corrupt — file can name a multi-gigabyte Window Table and have a
/// reader ask a server for it before a single field has been parsed. Sixty-four
/// megabytes is four orders of magnitude above any real one, and still a
/// request that fails rather than a machine that swaps.
const int maxFrontMatterBytes = 64 * 1024 * 1024;

/// Reads the records before the first Chunk.
///
/// The scan runs to the first Chunk rather than stopping as soon as the records
/// it must have are in hand, and that is a deliberate trade. The specification
/// fixes the Header first and the Footer last and leaves the order of everything
/// between them free, so a Camera, a Metadata record or an Attachment may sit
/// after the Window Table — and a scan that stopped early would report a scene
/// without them. What a reader says about a file must not depend on where its
/// probe happened to stop.
///
/// It costs at most one extra round trip, and only on a scene whose front matter
/// is bigger than the probe — in practice one with an embedded audio track. It
/// does not cost the track: a record whose content this reader does not parse is
/// stepped over by arithmetic and remembered as a byte range, so opening a
/// 51 MiB scene with a 6 MiB soundtrack still transfers kilobytes.
///
/// A record larger than the probe whose content *is* wanted is fetched by its
/// own range rather than by re-probing, since its length is already known.
///
/// Nothing is ever parsed from bytes that were not read.
Future<_FrontMatter> _readFrontMatter(
  FourdgsReadable source,
  int size,
  int probeBytes,
) async {
  final out = _FrontMatter();
  int at = 0;
  Uint8List buf = await source.read(0, math.min(probeBytes, size));
  out.bytesRead += buf.length;
  checkMagic(buf);
  int start = fourdgsMagic.length;

  // The scan terminates properly only when it reaches the first Chunk or the end of the
  // file. If the round cap is hit first — a file with more oversized-payload records than
  // the cap allows, since the format sets no source-count limit — the front matter is
  // incomplete, and returning it would frame a partial scene the Header still agrees with.
  // The reader refuses at its stated limit rather than accept that. See `_maxFrontMatterReads`.
  bool complete = false;
  for (int round = 0; round < _maxFrontMatterReads; round++) {
    FourdgsRecordSpan? unread;
    bool sawChunk = false;
    // Where the scan got to, in file coordinates. Tracked rather than inferred
    // from the buffer's end: the scanner stops as soon as a record's own 9-byte
    // header no longer fits, so up to 8 bytes of a real record header can be
    // left in the buffer. Resuming at the buffer's end would swallow them and
    // start the next scan in the middle of a record.
    int scanned = start;

    for (final local in scanRecordSpans(buf, start - at)) {
      // File-relative view of a span the scanner reported buffer-relative.
      final span = FourdgsRecordSpan(
        opcode: local.opcode,
        offset: at + local.offset,
        contentOffset: at + local.contentOffset,
        contentLength: local.contentLength,
      );
      // The first chunk ends the front matter: everything a reader needs in
      // order to plan its fetches is written before it.
      if (span.opcode == opChunk) {
        sawChunk = true;
        break;
      }
      if (local.end > buf.length) {
        unread = span;
        break;
      }
      _applyFrontRecord(
        out,
        span,
        Uint8List.sublistView(buf, local.contentOffset, local.end),
      );
      scanned = span.end;
    }

    if (sawChunk) {
      complete = true;
      break;
    }
    if (unread == null) {
      // Every record in the buffer was parsed whole. If what remains is smaller than a
      // record header it is the trailing magic — the scan has reached the end of the front
      // matter of a scene with no Chunk (an empty scene has none), which is a proper
      // termination, not the round cap running out mid-file. Otherwise more records remain
      // than this probe held, so read on.
      if (size - scanned < recordHeaderBytes) {
        complete = true;
        break;
      }
      at = start = scanned;
      buf = await source.read(at, math.min(probeBytes, size - at));
      out.bytesRead += buf.length;
      continue;
    }

    if (_usesPrefix(unread.opcode)) {
      // Pairing audio records needs only their ids and declared lengths.
      // Fetch a bounded prefix even when the encoded payload is gigabytes.
      final want = math.min(_prefixBytes(unread.opcode), unread.framedLength);
      final prefix = await source.read(unread.offset, want);
      out.bytesRead += prefix.length;
      _applyFrontRecord(
        out,
        unread,
        Uint8List.sublistView(
          prefix,
          math.min(recordHeaderBytes, prefix.length),
        ),
      );
    } else if (!_wantsContent(unread.opcode)) {
      // Camera, Metadata, Attachment: the range is the whole answer here too, so
      // a record larger than the probe is framed and stepped over rather than
      // transferred. An empty view because none of the content arrived is
      // correct — nothing below reads it.
      _applyFrontRecord(out, unread, Uint8List(0));
    }

    if (_wantsContent(unread.opcode)) {
      if (unread.end > size) {
        throw const FourdgsTruncatedFile(
          'a header record runs past the end of the file',
        );
      }
      if (unread.framedLength > maxFrontMatterBytes) {
        throw FourdgsMalformedFile(
          'a header record declares ${unread.framedLength} bytes, past the $maxFrontMatterBytes ceiling',
        );
      }
      final blob = await source.read(unread.offset, unread.framedLength);
      out.bytesRead += blob.length;
      _applyFrontRecord(
        out,
        unread,
        Uint8List.sublistView(blob, recordHeaderBytes),
      );
    }

    if (unread.end > size) {
      throw const FourdgsTruncatedFile(
        'a header record runs past the end of the file',
      );
    }
    if (unread.end == size) {
      complete = true;
      break;
    }
    at = start = unread.end;
    buf = await source.read(at, math.min(probeBytes, size - at));
    out.bytesRead += buf.length;
  }
  if (!complete) {
    throw FourdgsMalformedFile(
      'the front matter needs more than $_maxFrontMatterReads reads to reach the first '
      'Chunk or the end of the file',
    );
  }
  return out;
}

/// The three records this reader parses out of the front matter. Everything
/// else there is framed and remembered as a byte range, never transferred.
bool _wantsContent(int opcode) =>
    opcode == opHeader || opcode == opQuantization || opcode == opWindowTable;

bool _usesPrefix(int opcode) =>
    opcode == opAudio || opcode == opAudioSource || opcode == opAudioData;

int _prefixBytes(int opcode) {
  switch (opcode) {
    case opAudio:
      return recordHeaderBytes + _legacyAudioPrefixBytes;
    case opAudioSource:
      return recordHeaderBytes + 4;
    case opAudioData:
      return recordHeaderBytes + 12;
    default:
      return recordHeaderBytes;
  }
}

/// Applies one front-matter record.
///
/// [content] is a prefix for audio records, whose pairing fields are at the
/// front and whose payload is deliberately not transferred here, and empty for
/// records this reader only records by range.
void _applyFrontRecord(
  _FrontMatter out,
  FourdgsRecordSpan span,
  Uint8List content,
) {
  switch (span.opcode) {
    case opHeader:
      out.header = FourdgsHeader.parse(content, fileOffset: span.contentOffset);
    case opQuantization:
      out.quantization = FourdgsQuantization.parse(
        content,
        fileOffset: span.contentOffset,
      );
    case opWindowTable:
      out.windows = FourdgsWindowTable.parse(content).windows;
    case opAudio:
      if (out.legacyAudio != null) {
        throw const FourdgsMalformedFile(
          'the file carries more than one legacy Audio record',
        );
      }
      final prefix = FourdgsCursor(content);
      final codec = prefix.string();
      final startSec = prefix.f64();
      final dataLength = prefix.u64();
      if (span.contentLength < prefix.pos + dataLength) {
        throw FourdgsMalformedFile(
          'the legacy Audio record declares $dataLength data bytes, but its '
          'content is only ${span.contentLength} bytes',
        );
      }
      out.legacyAudio = FourdgsIndexedAudioSource(
        sourceId: 0,
        descriptorRange: null,
        dataOffset: span.contentOffset + prefix.pos,
        dataLength: dataLength,
        legacyCodec: codec,
        legacyStartSec: startSec,
      );
    case opAudioSource:
      final sourceId = FourdgsCursor(content).u32();
      if (out.audioSourceRanges.containsKey(sourceId)) {
        throw FourdgsMalformedFile(
          'Audio Source id $sourceId appears more than once',
        );
      }
      out.audioSourceRanges[sourceId] = (
        offset: span.offset,
        length: span.framedLength,
      );
    case opAudioData:
      final prefix = FourdgsCursor(content);
      final sourceId = prefix.u32();
      final dataLength = prefix.u64();
      if (span.contentLength < prefix.pos + dataLength) {
        throw FourdgsMalformedFile(
          'Audio Data id $sourceId declares $dataLength bytes, but its record '
          'content is only ${span.contentLength} bytes',
        );
      }
      if (out.audioDataRanges.containsKey(sourceId)) {
        throw FourdgsMalformedFile(
          'Audio Data id $sourceId appears more than once',
        );
      }
      out.audioDataRanges[sourceId] = (
        offset: span.contentOffset + prefix.pos,
        length: dataLength,
      );
    case opCamera:
      out.cameraRange = (offset: span.offset, length: span.framedLength);
    case opMetadata:
      out.metadataRanges.add((offset: span.offset, length: span.framedLength));
    case opAttachment:
      out.attachmentRanges.add((
        offset: span.offset,
        length: span.framedLength,
      ));
    default:
      if (isProvenanceOpcode(span.opcode)) {
        out.provenanceRanges.add((
          opcode: span.opcode,
          offset: span.offset,
          length: span.framedLength,
        ));
      }
  }
}

List<FourdgsIndexedAudioSource> _pairIndexedAudioSources(_FrontMatter front) {
  if (front.legacyAudio != null && front.audioSourceRanges.isNotEmpty) {
    throw const FourdgsMalformedFile(
      'the file mixes a legacy Audio record with Audio Source records',
    );
  }
  if (front.legacyAudio != null) {
    if (front.audioDataRanges.isNotEmpty) {
      final sourceId = front.audioDataRanges.keys.reduce(
        (a, b) => a < b ? a : b,
      );
      throw FourdgsMalformedFile(
        'Audio Data id $sourceId has no matching Audio Source record',
      );
    }
    return <FourdgsIndexedAudioSource>[front.legacyAudio!];
  }

  final out = <FourdgsIndexedAudioSource>[];
  final ids = front.audioSourceRanges.keys.toList()..sort();
  for (final sourceId in ids) {
    final data = front.audioDataRanges.remove(sourceId);
    if (data == null) {
      throw FourdgsMalformedFile(
        'Audio Source id $sourceId has no matching Audio Data record',
      );
    }
    out.add(
      FourdgsIndexedAudioSource(
        sourceId: sourceId,
        descriptorRange: front.audioSourceRanges[sourceId],
        dataOffset: data.offset,
        dataLength: data.length,
      ),
    );
  }
  if (front.audioDataRanges.isNotEmpty) {
    final sourceId = front.audioDataRanges.keys.reduce((a, b) => a < b ? a : b);
    throw FourdgsMalformedFile(
      'Audio Data id $sourceId has no matching Audio Source record',
    );
  }
  return out;
}

/// The most chunk-index entries one scene may declare.
///
/// Not a format limit. Every entry becomes a Dart object with its own band
/// list, built while opening the file and before any per-chunk budget is
/// consulted — so the count is an allocation the file gets to choose, and a
/// 64 MiB summary has room for over a million minimal ones.
///
/// 262,144 is far past anything plausible and still cheap to hold. The largest
/// scene measured while this decoder was written indexes 3,429,566 gaussians in
/// 107 chunks (~32,000 each); at a thousand gaussians per chunk — far finer than
/// any encoder writes, since the chunk is the unit of range-fetching and smaller
/// chunks mean more round trips — this ceiling still admits a
/// quarter-billion-gaussian scene.
const int maxChunkIndexEntries = 262144;
