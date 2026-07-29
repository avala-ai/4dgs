// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Record bodies: one class per record type, each able to read itself.
///
/// Every `parse` here reads the fields it knows and stops. It never asserts
/// that the record ended where its knowledge did, because a newer writer may
/// have appended fields — that is the compatibility rule, and honouring it is
/// one line per record rather than a policy nobody remembers.
library;

import 'dart:typed_data';

import 'exceptions.dart';
import 'opcode.dart';
import 'serialization.dart';

/// Opcode `0x01`. Everything a reader needs before deciding what to fetch.
class FourdgsHeader {
  const FourdgsHeader({
    required this.profile,
    required this.library,
    required this.durationSec,
    required this.gaussianCount,
    required this.cutoff,
    required this.temporalModel,
    required this.aabb,
    required this.shDegree,
    required this.flags,
    required this.attributes,
  });

  /// Well-known profile name, or `''` for the base format with no additional
  /// promises.
  final String profile;

  /// Free-form producer identification.
  final String library;

  final double durationSec;
  final int gaussianCount;

  /// Marginal visibility threshold; `0.05` unless a producer says otherwise.
  final double cutoff;

  final String temporalModel;

  /// Min xyz then max xyz over all rest positions.
  ///
  /// Read as six `f64`, not the six `f32` the specification's field table
  /// lists. The reference implementation writes `f64` here, so every file that
  /// exists carries 48 bytes and a reader that took the table literally would
  /// mis-align `sh_degree`, `flags` and the attributes map that follow it. The
  /// conformance corpus decides, and the corpus says `f64`. Raised upstream —
  /// the spec text and the reference disagree, and one of them has to move.
  final List<double> aabb;

  final int shDegree;
  final int flags;
  final Map<String, String> attributes;

  /// Answered from the header alone — no probing, no speculative range request.
  ///
  /// This is the whole audio-discovery rule, and it is why a scene without a
  /// soundtrack costs nothing: the bit is clear and there is no record.
  bool get hasAudio => flags & headerFlagHasAudio != 0;

  static FourdgsHeader parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsHeader(
      profile: c.string(),
      library: c.string(),
      durationSec: c.f64(),
      gaussianCount: c.u64(),
      cutoff: c.f64(),
      temporalModel: c.string(),
      aabb: c.f64s(6),
      shDegree: c.u8(),
      flags: c.u8(),
      attributes: c.strMap(),
    );
  }
}

/// Opcode `0x02`. The tail pointer that makes the file seekable.
class FourdgsFooter {
  const FourdgsFooter({
    required this.summaryStart,
    required this.summaryOffsetStart,
    required this.summaryCrc,
  });

  /// Byte offset of the first Chunk Index record, or 0 when the file has no
  /// index and MUST be read sequentially.
  final int summaryStart;

  final int summaryOffsetStart;

  /// CRC-32 (IEEE) over `[summaryStart, footerStart)`, or 0.
  final int summaryCrc;

  static FourdgsFooter parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsFooter(
      summaryStart: c.u64(),
      summaryOffsetStart: c.u64(),
      summaryCrc: c.u32(),
    );
  }
}

/// Opcode `0x03`. The dequantization grids and the error bounds they guarantee.
class FourdgsQuantization {
  const FourdgsQuantization({
    required this.scheme,
    required this.posOrigin,
    required this.stepPos,
    required this.stepScaleLog,
    required this.stepRot,
    required this.stepRgb,
    required this.stepAlpha,
    required this.stepMotion,
    required this.stepTime,
    required this.stepSigmaLog,
    required this.stepSh,
    required this.bounds,
  });

  final String scheme;
  final List<double> posOrigin;
  final double stepPos;
  final double stepScaleLog;
  final double stepRot;
  final double stepRgb;
  final double stepAlpha;

  /// Reference velocity pitch. The pitch actually applied is per-gaussian and
  /// derived from the gaussian's own sigma bin — see `quantization.dart`.
  final double stepMotion;

  /// Reference birth-time pitch, refined per gaussian for the same reason.
  final double stepTime;

  final double stepSigmaLog;
  final int stepSh;

  /// Declared maximum deviation per attribute, as decimal strings.
  final Map<String, String> bounds;

  static FourdgsQuantization parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final scheme = c.string();
    final origin = c.f64s(3);
    final steps = c.f64s(8);
    return FourdgsQuantization(
      scheme: scheme,
      posOrigin: origin,
      stepPos: steps[0],
      stepScaleLog: steps[1],
      stepRot: steps[2],
      stepRgb: steps[3],
      stepAlpha: steps[4],
      stepMotion: steps[5],
      stepTime: steps[6],
      stepSigmaLog: steps[7],
      stepSh: c.u8(),
      bounds: c.strMap(),
    );
  }
}

/// One validity window: the span outside which a gaussian does not exist.
class FourdgsWindow {
  const FourdgsWindow(this.lo, this.hi);

  final double lo;
  final double hi;

  double get length => hi - lo;
}

/// Opcode `0x04`. Gaussians reference windows by index, so the per-gaussian
/// cost of a validity window is an index rather than two floats.
class FourdgsWindowTable {
  const FourdgsWindowTable(this.windows);

  final List<FourdgsWindow> windows;

  static FourdgsWindowTable parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final n = c.u32();
    // Two bounds, and the cheap one first. The record physically holds one
    // window per 16 bytes, so a count past that is a lie the bytes themselves
    // disprove — and checking it costs nothing, where letting the loop find out
    // means having already built most of the list.
    if (n > c.remaining ~/ windowBytes) {
      throw FourdgsMalformedFile(
        'the window table declares $n windows but holds room for ${c.remaining ~/ windowBytes}',
      );
    }
    // The second bound is for a file that really does carry them. 64 MiB of
    // front matter is room for ~4.2 million windows, and each one becomes a
    // Dart object here — hundreds of MiB from an input that is itself
    // unremarkable. See [maxWindowsPerScene].
    if (n > maxWindowsPerScene) {
      throw FourdgsMalformedFile(
        'the window table declares $n windows, past the $maxWindowsPerScene ceiling',
      );
    }
    final out = <FourdgsWindow>[];
    for (int i = 0; i < n; i++) {
      out.add(FourdgsWindow(c.f64(), c.f64()));
    }
    return FourdgsWindowTable(out);
  }
}

/// Opcode `0x05` — a chunk's own fields. Its attribute streams follow in the
/// `records` blob, which [parseChunk] returns alongside.
class FourdgsChunkHeader {
  const FourdgsChunkHeader({
    required this.t0,
    required this.t1,
    required this.level,
    required this.count,
    required this.compression,
    required this.uncompressedSize,
  });

  final double t0;
  final double t1;

  /// The producer's hierarchy level; informational only.
  final int level;

  final int count;

  /// Codec applied to the records below, or `''` for uncompressed. Streams
  /// carry their own codec, so writers leave this empty in practice.
  final String compression;

  final int uncompressedSize;
}

/// A chunk's header and the raw bytes of its concatenated attribute streams.
class FourdgsChunkBody {
  const FourdgsChunkBody(this.header, this.streams);

  final FourdgsChunkHeader header;
  final Uint8List streams;
}

FourdgsChunkBody parseChunk(Uint8List content) {
  final c = FourdgsCursor(content);
  final head = FourdgsChunkHeader(
    t0: c.f64(),
    t1: c.f64(),
    level: c.u32(),
    count: c.u32(),
    compression: c.string(),
    uncompressedSize: c.u64(),
  );
  return FourdgsChunkBody(head, c.take(c.u64()));
}

/// A spherical-harmonic band's own byte range within the file.
class FourdgsBandRange {
  const FourdgsBandRange({
    required this.band,
    required this.offset,
    required this.length,
  });

  final int band;
  final int offset;
  final int length;
}

/// Opcode `0x08`. One entry per chunk; together they are the seek index.
class FourdgsChunkIndexEntry {
  const FourdgsChunkIndexEntry({
    required this.t0,
    required this.t1,
    required this.chunkOffset,
    required this.chunkLength,
    required this.gaussianCount,
    required this.bands,
  });

  final double t0;
  final double t1;
  final int chunkOffset;
  final int chunkLength;
  final int gaussianCount;

  /// Each band is its own byte range, so a reader that has decided to evaluate
  /// fewer bands never transfers the ones it will not use.
  final List<FourdgsBandRange> bands;

  /// The normative seek rule, per entry.
  bool covers(double t) => t0 <= t && t < t1;

  /// True when this chunk can hold a gaussian visible anywhere in `[a, b)`.
  bool overlaps(double a, double b) => t0 < b && a < t1;

  static FourdgsChunkIndexEntry parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final t0 = c.f64();
    final t1 = c.f64();
    final chunkOffset = c.u64();
    final chunkLength = c.u64();
    final gaussianCount = c.u32();
    final bandCount = c.u32();
    if (bandCount > c.remaining ~/ bandRangeBytes) {
      throw FourdgsMalformedFile(
        'a chunk index entry declares $bandCount SH bands but holds room for ${c.remaining ~/ bandRangeBytes}',
      );
    }
    if (bandCount > maxBandsPerChunk) {
      throw FourdgsMalformedFile(
        'a chunk index entry declares $bandCount SH bands, past the $maxBandsPerChunk ceiling',
      );
    }
    final bands = <FourdgsBandRange>[];
    final seen = <int>{};
    for (int i = 0; i < bandCount; i++) {
      final range = FourdgsBandRange(
        band: c.u8(),
        offset: c.u64(),
        length: c.u64(),
      );
      // One band, one range. A repeated descriptor is not merely redundant:
      // readFourdgsChunk fetches every supported one and then overwrites the
      // same map entry, so N copies of a valid band-1 range are N transfers
      // that leave one record behind — bytes and time spent for nothing.
      if (!seen.add(range.band)) {
        throw FourdgsMalformedFile(
          'a chunk index entry lists SH band ${range.band} more than once',
        );
      }
      bands.add(range);
    }
    return FourdgsChunkIndexEntry(
      t0: t0,
      t1: t1,
      chunkOffset: chunkOffset,
      chunkLength: chunkLength,
      gaussianCount: gaussianCount,
      bands: bands,
    );
  }
}

/// Opcode `0x09`. Present only when the scene has audio; its absence is the
/// signal, not a placeholder.
class FourdgsAudio {
  const FourdgsAudio({
    required this.codec,
    required this.startSec,
    required this.data,
  });

  /// Well-known audio codec name — `wav` or `opus` in this version.
  final String codec;

  /// Scene time at which the track's first sample plays.
  final double startSec;

  /// The encoded track, verbatim.
  final Uint8List data;

  static FourdgsAudio parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsAudio(codec: c.string(), startSec: c.f64(), data: c.blob());
  }
}

/// Opcode `0x0A`. A default viewpoint and an optional suggested path. Purely
/// advisory: a reader MAY ignore it entirely.
class FourdgsCamera {
  const FourdgsCamera({
    required this.fovYDeg,
    required this.position,
    required this.target,
    required this.times,
    required this.positions,
    required this.targets,
    required this.interpolation,
    required this.loop,
  });

  final double fovYDeg;
  final List<double> position;
  final List<double> target;
  final List<double> times;
  final List<List<double>> positions;
  final List<List<double>> targets;
  final String interpolation;
  final bool loop;

  static FourdgsCamera parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final fov = c.f64();
    final position = c.f64s(3);
    final target = c.f64s(3);
    final n = c.u32();
    final times = <double>[];
    final positions = <List<double>>[];
    final targets = <List<double>>[];
    for (int i = 0; i < n; i++) {
      times.add(c.f64());
      positions.add(c.f64s(3));
      targets.add(c.f64s(3));
    }
    return FourdgsCamera(
      fovYDeg: fov,
      position: position,
      target: target,
      times: times,
      positions: positions,
      targets: targets,
      interpolation: c.string(),
      loop: c.u8() != 0,
    );
  }
}

/// Opcode `0x0B`.
class FourdgsMetadata {
  const FourdgsMetadata({required this.name, required this.entries});

  final String name;
  final Map<String, String> entries;

  static FourdgsMetadata parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsMetadata(name: c.string(), entries: c.strMap());
  }
}

/// Opcode `0x0C`. Advisory: a reader that needs certainty computes from the
/// chunks instead.
class FourdgsStatistics {
  const FourdgsStatistics({
    required this.gaussianCount,
    required this.chunkCount,
    required this.durationSec,
    required this.aabb,
  });

  final int gaussianCount;
  final int chunkCount;
  final double durationSec;
  final List<double> aabb;

  static FourdgsStatistics parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsStatistics(
      gaussianCount: c.u64(),
      chunkCount: c.u32(),
      durationSec: c.f64(),
      aabb: c.f64s(6),
    );
  }
}

/// Opcode `0x0D`. Arbitrary payloads — thumbnails, provenance, licences.
/// Attachments are NOT the mechanism for audio; audio has its own record
/// because it is a first-class part of the scene.
class FourdgsAttachment {
  const FourdgsAttachment({
    required this.name,
    required this.mediaType,
    required this.data,
  });

  final String name;
  final String mediaType;
  final Uint8List data;

  static FourdgsAttachment parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsAttachment(
      name: c.string(),
      mediaType: c.string(),
      data: c.blob(),
    );
  }
}

/// Opcode `0x0F`. Lets a reader range-read one class of index record without
/// reading the others.
class FourdgsSummaryOffset {
  const FourdgsSummaryOffset({
    required this.groupOpcode,
    required this.groupStart,
    required this.groupLength,
  });

  final int groupOpcode;
  final int groupStart;
  final int groupLength;

  static FourdgsSummaryOffset parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsSummaryOffset(
      groupOpcode: c.u8(),
      groupStart: c.u64(),
      groupLength: c.u64(),
    );
  }
}

/// Encoded size of one window table entry: two `f64` bounds.
const int windowBytes = 16;

/// Encoded size of one SH band descriptor: `u8 band`, `u64 offset`, `u64 length`.
const int bandRangeBytes = 17;

/// The most validity windows one scene may declare.
///
/// Not a format limit. A window becomes a Dart object here, and a consumer that
/// derives slice boundaries from the table allocates more per window and then
/// sorts them — so the count is an allocation the file gets to choose.
///
/// 65,536 is far past anything a real encoder emits and still cheap: the
/// conformance corpus tops out at 10, and even a pathological
/// one-window-per-frame encoder would need a 10-minute scene at 60 fps (36,000)
/// to approach it.
const int maxWindowsPerScene = 65536;

/// The most SH band descriptors one chunk index entry may declare.
///
/// This version defines bands 1-3, but a reader must skip bands it does not
/// know rather than refuse the file, so the ceiling leaves room for a later
/// version's bands instead of pinning it at three.
const int maxBandsPerChunk = 16;
