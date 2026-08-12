// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Record bodies: one class per record type, each able to read itself.
///
/// Every `parse` here reads the fields it knows and stops. It never asserts
/// that the record ended where its knowledge did, because a newer writer may
/// have appended fields — that is the compatibility rule, and honouring it is
/// one line per record rather than a policy nobody remembers.
library;

import 'dart:math' as math;
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

  /// [fileOffset] is where [content] begins in the file. It defaults to zero
  /// for callers parsing a detached record body, while both file readers pass
  /// the framed record's content offset so every diagnostic names a seekable
  /// byte in the original resource.
  static FourdgsHeader parse(Uint8List content, {int fileOffset = 0}) {
    final c = FourdgsCursor(content);
    final profile = c.string();
    final library = c.string();
    final durationAt = fileOffset + c.pos;
    final durationSec = c.f64();
    // Every check here is on a value that decodes into plausible-looking output
    // when it is trusted, rather than into an obvious error. A NaN duration
    // reaches timeline arithmetic and breaks playback; a negative one is not a
    // duration. Zero stays legal — the NoData conformance fixture is exactly a
    // zero-duration scene.
    //
    // `+Infinity` stays legal too, and this is deliberate. The spec requires
    // finiteness of an *audio source's* duration (§5.11) and says nothing of the
    // kind about the scene's; neither reference writer rejects it; `[0, +oo)` has
    // a well-defined seek; and §5.8 makes the last index `t1` the Header's
    // duration, an endpoint this file already accepts as infinite. Refusing it
    // here would not make anything safer — it would make a file the other five
    // SDKs read undecodable in Dart alone, which is the one outcome a format
    // cannot afford.
    if (durationSec.isNaN || durationSec < 0) {
      throw FourdgsMalformedFile(
        'the Header at byte $durationAt declares duration_sec = $durationSec; '
        'expected a value >= 0, or +Infinity for an open-ended scene',
      );
    }
    final gaussianCount = c.u64();
    final cutoffAt = fileOffset + c.pos;
    final cutoff = c.f64();
    // Otherwise only validated where a chunk's motion is decoded against it,
    // which a zero-gaussian file or a metadata-only indexed open never reaches
    // — the bad value would sit in the returned header indefinitely.
    if (cutoff.isNaN || !(cutoff > 0.0 && cutoff <= 1.0)) {
      throw FourdgsMalformedFile(
        'the Header at byte $cutoffAt declares cutoff = $cutoff; expected a '
        'marginal threshold in (0, 1]',
      );
    }
    final temporalModelAt = fileOffset + c.pos;
    final temporalModel = c.string();
    final aabb = c.f64s(6);
    final shDegreeAt = fileOffset + c.pos;
    final shDegree = c.u8();
    // 0-3 is the whole registry. Out of range is not merely unknown: a decoded
    // byte budget prices an unknown band at zero while the coefficient count
    // keeps growing with the degree, so a buffer sized from the first is not
    // the scene the second decodes.
    if (shDegree > 3) {
      throw FourdgsMalformedFile(
        'the Header at byte $shDegreeAt declares sh_degree = $shDegree; the '
        'registry defines 0 through 3',
      );
    }
    final flags = c.u8();
    final attributes = c.strMap();
    // Last, and after every mandatory field has been read. "A model this build
    // does not implement" is a statement about a whole Header, and a Header that
    // ends after the model string is not one — it is truncated, and saying the
    // model is unsupported would send the reader off to add codec support for a
    // file that is simply missing its second half. Named, not assumed: an
    // unknown model is a conforming file this build cannot read, which is a
    // different answer from "corrupt". Both known models are accepted;
    // `keyframe-delta` files are legal and read by their own path, which
    // refusing here would make unreachable. The empty name arrives here too and
    // is refused under the same identifier: a declaration of nothing is not a
    // default, and the difference between it and a future model's name is a
    // sentence for a human, not a rule a caller branches on.
    if (!_knownTemporalModels.contains(temporalModel)) {
      throw FourdgsUnsupportedCodec(
        'the Header at byte $temporalModelAt declares temporal_model '
        '"$temporalModel", which this build does not implement; expected one of '
        '${_knownTemporalModels.join(", ")}',
        refusalCode: refusalUnknownTemporalModel,
      );
    }
    return FourdgsHeader(
      profile: profile,
      library: library,
      durationSec: durationSec,
      gaussianCount: gaussianCount,
      cutoff: cutoff,
      temporalModel: temporalModel,
      aabb: aabb,
      shDegree: shDegree,
      flags: flags,
      attributes: attributes,
    );
  }
}

/// Temporal models this build implements.
///
/// Accepting a name is a promise to read the file, so a name the specification
/// reserves belongs here only once this decoder can decode it.
const Set<String> _knownTemporalModels = <String>{
  'gaussian-birth',
  'keyframe-delta',
};

/// Opcode `0x02`. The tail pointer that makes the file seekable.
const int footerFixedBytes = 20;

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
    this.shBitDepths = const <int>[],
    this.shBitDepthsMalformed = false,
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

  /// Per-band spherical-harmonic bit depths, band 1 first.
  ///
  /// This optional append follows the record's original fields. An empty list
  /// therefore also represents a record written before the append existed.
  final List<int> shBitDepths;

  /// True when trailing bytes looked like an SH-depth append but were invalid.
  /// Decoders keep the legacy empty-depth fallback; validators report it.
  final bool shBitDepthsMalformed;

  /// Declared maximum deviation per attribute, as decimal strings.
  final Map<String, String> bounds;

  /// [fileOffset] is where `content` begins in the file, for the same reason
  /// [FourdgsChunkIndexEntry.parse] takes one: a refusal that names byte 0
  /// names the start of a record's content, which is not a byte anybody can
  /// seek to. Defaulted rather than required, because a caller holding a bare
  /// record has no file to be relative to.
  static FourdgsQuantization parse(Uint8List content, {int fileOffset = 0}) {
    final c = FourdgsCursor(content);
    final schemeAt = fileOffset + c.pos;
    final scheme = c.string();
    final originAt = fileOffset + c.pos;
    final origin = c.f64s(3);
    final stepsAt = fileOffset + c.pos;
    final steps = c.f64s(8);
    final stepSh = c.u8();
    final bounds = c.strMap();
    final shDepths = _readShBitDepths(c);
    // `object_id` is an exact label (section 6.6), not a metric value, so there
    // is no meaningful error bound between two different labels — section 6.5
    // makes a bound for it a refusal rather than something to ignore.
    if (bounds.containsKey('object_id')) {
      throw FourdgsMalformedFile(
        "Quantization.bounds contains object_id='${bounds['object_id']}'; "
        'object_id is an exact label and MUST NOT carry a bound',
      );
    }
    _checkQuantizationMagnitudes(origin, originAt, steps, stepsAt);
    // Last, after every mandatory field has been read, for the reason the
    // Header checks its temporal model last: "a scheme this build does not
    // implement" is a statement about a whole record, and a record that ends
    // inside its bounds map is not one — it is truncated, and answering
    // "unsupported" would send its holder off to add a codec for a file that
    // needs none.
    if (!_knownQuantizationSchemes.contains(scheme)) {
      throw FourdgsUnsupportedCodec(
        'the Quantization record at byte $schemeAt declares scheme "$scheme", '
        'which this build does not implement; expected one of '
        '${_knownQuantizationSchemes.join(", ")}',
        refusalCode: refusalUnknownQuantizationScheme,
      );
    }
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
      stepSh: stepSh,
      bounds: bounds,
      shBitDepths: shDepths.depths,
      shBitDepthsMalformed: shDepths.malformed,
    );
  }
}

/// Read the optional SH-depth append without claiming future trailing fields.
///
/// The declaration does not affect decoding. A short count or a value outside
/// the registry's 3..8 range can therefore be bytes belonging to a later
/// append, and is treated as absent rather than making an older reader reject a
/// forward-compatible Quantization record.
({List<int> depths, bool malformed}) _readShBitDepths(FourdgsCursor c) {
  if (c.remaining < 1) return (depths: const <int>[], malformed: false);
  final int at = c.pos;
  final int count = c.u8();
  if (count == 0) {
    c.pos = at;
    return (depths: const <int>[], malformed: false);
  }
  if (c.remaining < count) {
    c.pos = at;
    return (depths: const <int>[], malformed: true);
  }
  final List<int> depths = <int>[for (int i = 0; i < count; i++) c.u8()];
  if (depths.any((int depth) => depth < 3 || depth > 8)) {
    c.pos = at;
    return (depths: const <int>[], malformed: true);
  }
  return (depths: depths, malformed: false);
}

/// Quantization schemes this build implements.
///
/// `KNOWN_QUANTIZATION_SCHEMES` in Python and TypeScript, with the same single
/// member. The registry's standing rule is that a value it does not list is
/// legal but unrecognized and that a reader which does not know one must fail
/// cleanly naming it, rather than decode through a grid it was not given: the
/// steps below are the *only* description of what the bins mean, so reading
/// `uniform-v9` bins through `uniform-v1` arithmetic produces a scene that is
/// wrong everywhere and complains nowhere.
const Set<String> _knownQuantizationSchemes = <String>{'uniform-v1'};

/// Every step and origin component must be finite (spec section 5.3).
///
/// This is the ceiling on a quantization parameter's magnitude, and the
/// specification puts it exactly at the end of the finite range: "Neither an
/// infinity nor a NaN is a legal value for any of them."  Python's and Rust's
/// validators report the same fault, field by field, in the same words.
///
/// This decoder acts on it rather than reporting it, and the reason is
/// specific to Dart. The per-gaussian pitches in `quantization.dart` are
/// derived with `log2(...)` and rounded with `floor`, and `double.floor()` on a
/// NaN or an infinity throws `UnsupportedError: Infinity or NaN toInt` — an
/// exception that names no byte, no record and no field, raised from inside
/// arithmetic three call levels below the reader. Section 6 of AGENTS.md asks
/// for a diagnosis, and this is the last point at which the file still has one
/// to give.
///
/// Reported per field, because "the Quantization record is broken" is what the
/// caller already knows.
void _checkQuantizationMagnitudes(
  List<double> origin,
  int originAt,
  List<double> steps,
  int stepsAt,
) {
  for (int i = 0; i < origin.length; i++) {
    if (!origin[i].isFinite) {
      throw FourdgsMalformedFile(
        'the Quantization record at byte ${originAt + i * 8} declares '
        'pos_origin[$i] = ${origin[i]}; expected a finite value, since a '
        'non-finite origin is not a coarser grid but no grid at all '
        '(section 5.3)',
      );
    }
  }
  for (int i = 0; i < steps.length; i++) {
    if (!steps[i].isFinite) {
      throw FourdgsMalformedFile(
        'the Quantization record at byte ${stepsAt + i * 8} declares '
        '${_stepNames[i]} = ${steps[i]}; expected a finite value, since a '
        'non-finite step is not a coarser grid but no grid at all '
        '(section 5.3)',
      );
    }
  }
}

/// The eight steps in the order the record writes them, so a refusal names the
/// field a producer has to fix rather than an index into a tuple.
const List<String> _stepNames = <String>[
  'step_pos',
  'step_scale_log',
  'step_rot',
  'step_rgb',
  'step_alpha',
  'step_motion',
  'step_time',
  'step_sigma_log',
];

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
      final windowAt = c.pos;
      final lo = c.f64();
      final hi = c.f64();
      // Visibility is gated on `lo <= t < hi`, so a NaN bound is false at every
      // instant and those gaussians silently never appear; an inverted window
      // reads as one covering nothing. Both decode to a scene quietly missing
      // content, which is worse than a refusal.
      //
      // An INFINITY is not one of those, at either end. The reference encoders
      // exclude `win_lo` and `win_hi` from their finite-input check on purpose —
      // "an infinity in them is meaningful rather than broken" — so `[0, +inf)`
      // is how a static glTF or USD import says a gaussian never expires, and
      // `[-inf, t)` is a gaussian that has always existed. Requiring either
      // bound to be finite makes conforming output from the other SDKs
      // undecodable here. `lo == hi` stays legal too: the NoData fixture is
      // exactly that.
      if (lo.isNaN || hi.isNaN || hi < lo) {
        throw FourdgsMalformedFile(
          'window $i of the Window Table, at byte $windowAt, spans [$lo, $hi); '
          'expected lo <= hi and neither bound NaN (an infinity is legal)',
        );
      }
      out.add(FourdgsWindow(lo, hi));
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
  const FourdgsChunkBody(this.header, this.streams, {this.streamsOffset = 0});

  final FourdgsChunkHeader header;
  final Uint8List streams;

  /// Where [streams] begins within the record's content, so a refusal raised
  /// while walking the block can name a byte in the file rather than an offset
  /// into a buffer only the parser can see.
  final int streamsOffset;
}

/// The interval rule, applied wherever a record states one.
///
/// A NaN bound is false against every instant, so content behind it is
/// unreachable while still counting toward the file; an inverted one describes
/// nothing at all. The Chunk Index is checked at parse, and so are the chunks it
/// summarises — otherwise the streamed path, which never reads the index,
/// accepts a file the indexed path refuses.
void refuseUnusableInterval(double t0, double t1, int at, String what) {
  if (t0.isNaN || t1.isNaN || t1 < t0) {
    throw FourdgsMalformedFile(
      'the $what at byte $at spans [$t0, $t1); expected an interval with '
      't1 >= t0 and neither bound NaN',
    );
  }
}

/// How many bytes of a Chunk's content [parseChunkInterval] needs.
///
/// `t0`, `t1`, `level` and `count`, in that order and at fixed offsets, ahead of
/// the first variable-length field.
const int chunkFixedHeadBytes = 24;

/// A Chunk's interval and count, from the first [chunkFixedHeadBytes] bytes.
///
/// For the caller that wants what a chunk *declares* without wanting what it
/// holds — a validator counting gaussians across a scene, which then decodes
/// each chunk separately and one at a time. [parseChunk] needs the whole record,
/// and a chunk is where a file keeps its weight, so asking for the whole record
/// to read four fields is how a validator comes to hold a scene it never decodes
/// (AGENTS.md §1).
({double t0, double t1, int level, int count}) parseChunkInterval(
  Uint8List head, {
  int fileOffset = 0,
}) {
  final c = FourdgsCursor(head);
  final intervalAt = fileOffset + c.pos;
  final t0 = c.f64();
  final t1 = c.f64();
  refuseUnusableInterval(t0, t1, intervalAt, 'Chunk');
  return (t0: t0, t1: t1, level: c.u32(), count: c.u32());
}

FourdgsChunkBody parseChunk(Uint8List content) {
  final c = FourdgsCursor(content);
  final intervalAt = c.pos;
  final t0 = c.f64();
  final t1 = c.f64();
  refuseUnusableInterval(t0, t1, intervalAt, 'Chunk');
  final head = FourdgsChunkHeader(
    t0: t0,
    t1: t1,
    level: c.u32(),
    count: c.u32(),
    compression: c.string(),
    uncompressedSize: c.u64(),
  );
  final length = c.u64();
  final records = c.take(length);
  if (head.compression.isEmpty && head.uncompressedSize != records.length) {
    throw FourdgsMalformedFile(
      'the uncompressed Chunk declares ${head.uncompressedSize} record bytes '
      'but carries ${records.length}',
    );
  }
  return FourdgsChunkBody(head, records, streamsOffset: c.pos - length);
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
    this.extended = false,
    this.kind = 0,
    this.deltaMode = 0,
    this.referenceOffset = 0,
    this.keyframeOffset = 0,
    this.depth = 0,
    this.liveCount = 0,
  });

  final double t0;
  final double t1;
  final int chunkOffset;
  final int chunkLength;
  final int gaussianCount;

  /// Each band is its own byte range, so a reader that has decided to evaluate
  /// fewer bands never transfers the ones it will not use.
  final List<FourdgsBandRange> bands;

  /// True when this entry carries the `keyframe-delta` block below. False for
  /// every `gaussian-birth` file, whose entries stay byte-identical: the block
  /// is appended after the band array, so an entry with at least
  /// [indexDeltaBlockBytes] left after the bands carries it and one without
  /// simply does not.
  final bool extended;

  /// `0` keyframe (a Chunk record), `1` delta (a Delta Chunk record).
  final int kind;

  /// `0` reference-to-keyframe, `1` reference-to-previous. Meaningful only when
  /// [kind] is `1`.
  final int deltaMode;

  /// The chunk this delta applies to. Strictly less than [chunkOffset]:
  /// references point backwards only, so the chain walk terminates, cycles are
  /// unrepresentable, and any complete prefix of a truncated file is a complete
  /// set of chains.
  final int referenceOffset;

  /// The keyframe at the head of this group. Equals [chunkOffset] for a
  /// keyframe.
  final int keyframeOffset;

  /// Delta chunks that must be composed to reach this one — the exact read cost,
  /// known from the index before anything is fetched.
  final int depth;

  /// Gaussians live over `[t0, t1)` after composition. [gaussianCount] cannot
  /// answer this for a delta entry — there it is the size of the delta, not of
  /// the population.
  final int liveCount;

  /// The normative seek rule, per entry.
  bool covers(double t) => t0 <= t && t < t1;

  /// True when this chunk can hold a gaussian visible anywhere in `[a, b)`.
  bool overlaps(double a, double b) => t0 < b && a < t1;

  /// [fileOffset] is where `content` begins in the file, so that a refusal can
  /// name a byte someone can seek to. Defaulted rather than required because a
  /// caller holding a bare record — a test, a fuzzer — has no file to be
  /// relative to, and 0 is then the truth rather than a placeholder.
  static FourdgsChunkIndexEntry parse(Uint8List content, {int fileOffset = 0}) {
    final c = FourdgsCursor(content);
    final intervalAt = fileOffset + c.pos;
    final t0 = c.f64();
    final t1 = c.f64();
    final chunkOffset = c.u64();
    final chunkLength = c.u64();
    final gaussianCount = c.u32();
    // The interval is what every seek compares against, so a bound that cannot
    // be compared is worse than a wrong one: NaN makes `t0 <= t < t1` false at
    // every instant and the chunk never resolves for any seek.
    //
    // An infinity compares perfectly well, though, and the format does not
    // require these bounds to be finite — the Python and Rust parsers accept
    // `[0, +inf)` and `[-inf, t)`, so refusing them here would make an
    // open-ended index unreadable in Dart alone. Same rule the Window Table
    // uses: NaN and inversion, nothing more.
    if (t0.isNaN || t1.isNaN || t1 < t0) {
      throw FourdgsMalformedFile(
        'the Chunk Index entry at byte $intervalAt spans [$t0, $t1); expected '
        't0 <= t1 and neither bound NaN (an infinity is legal)',
      );
    }
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
    // The `keyframe-delta` block sits after the band array. A reader takes the
    // record's length from its header, so an entry with at least this many bytes
    // left carries the block and a `gaussian-birth` entry — which has none —
    // reads to the same values it always did.
    // Zero width is legal only when the entry is empty, and which field says
    // "empty" depends on the entry. The seek rule is half-open, so nothing can
    // ever select a nonempty chunk over `t0 == t1` — its gaussians are
    // unreachable while still counting toward the file.
    void refuseNonemptyZeroWidth(int population, String what) {
      if (t0 == t1 && population != 0) {
        throw FourdgsMalformedFile(
          'the Chunk Index entry at byte $intervalAt declares $population $what '
          'over the zero-width interval [$t0, $t1); expected 0 there, because '
          'the half-open seek rule can never select a zero-width interval',
        );
      }
    }

    if (c.remaining >= indexDeltaBlockBytes) {
      final kind = c.u8();
      final deltaMode = c.u8();
      final referenceOffset = c.u64();
      final keyframeOffset = c.u64();
      final depth = c.u16();
      final liveCount = c.u64();
      // No zero-width check here at all, on either count. An appended block
      // means neither field is unambiguously a population: under a
      // `keyframe-delta` Header a delta entry's `gaussianCount` counts
      // operations, so a chunk that only kills gaussians declares three of them
      // and a `liveCount` of zero — empty, and refused by a rule reading
      // `gaussianCount`. And `liveCount` is only a population under that same
      // Header, which this parser cannot see: it recognises the block by length
      // and cannot tell a delta entry from fields a later revision adds.
      //
      // So the rule moves to whoever knows the temporal model. Both openers and
      // the keyframe-delta reader compute the population with
      // [indexEntryPopulation] and apply [refuseZeroWidthPopulation] to it,
      // which catches everything this would have caught and nothing it should
      // not have.
      return FourdgsChunkIndexEntry(
        t0: t0,
        t1: t1,
        chunkOffset: chunkOffset,
        chunkLength: chunkLength,
        gaussianCount: gaussianCount,
        bands: bands,
        extended: true,
        kind: kind,
        deltaMode: deltaMode,
        referenceOffset: referenceOffset,
        keyframeOffset: keyframeOffset,
        depth: depth,
        liveCount: liveCount,
      );
    }
    // No extended block: `gaussianCount` IS the population.
    refuseNonemptyZeroWidth(gaussianCount, 'gaussians');
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

/// The number of gaussians an index entry says are *there*, which is not always
/// the number it stores in `gaussianCount`.
///
/// A delta entry's `gaussianCount` counts operations — births, deaths, updates
/// — and its `liveCount` counts the population those operations compose to. A
/// keyframe entry counts the ordinary way and leaves `liveCount` zero. And
/// `liveCount` means any of this only under a `keyframe-delta` Header: the
/// record parser recognises the appended block by length alone and cannot tell
/// a delta entry from fields a later revision adds, so the caller has to say.
int indexEntryPopulation(
  FourdgsChunkIndexEntry entry, {
  required bool isKeyframeDelta,
}) =>
    // `kind != 0`, not `kind == 1`, because that is what the keyframe-delta
    // reader does when it composes: every nonzero kind is a delta there. Reading
    // `kind == 1` here made an entry declaring kind 2 a keyframe to this rule and
    // a delta to the decoder, and a file only has to disagree with itself once.
    // Unknown kinds are refused outright by [checkIndexEntry]; this stays
    // consistent with the decoder for the window where both are reachable.
    (isKeyframeDelta && entry.extended && entry.kind != 0)
        ? entry.liveCount
        : entry.gaussianCount;

/// Everything an index entry can be refused for that needs the Header to see it.
///
/// Three read paths reach a Chunk Index and all three need these, which is why
/// they are one call. [where] locates the record — "the Chunk Index record at
/// byte N (entry i of n)".
void checkIndexEntry(
  FourdgsChunkIndexEntry entry, {
  required bool isKeyframeDelta,
  required String where,
}) {
  // Two kinds are defined (spec §5.8): 0 keyframe, 1 delta. A third is not a
  // forward-compatible extension — it is a chunk this build cannot place in a
  // chain, and guessing which of the two it resembles is how one reader
  // composes a scene the next one refuses.
  if (isKeyframeDelta && entry.extended && entry.kind > 1) {
    throw FourdgsMalformedFile(
      '$where declares chunk_kind ${entry.kind}; expected 0 for a keyframe or '
      '1 for a delta',
    );
  }
  refuseZeroWidthPopulation(
    entry,
    indexEntryPopulation(entry, isKeyframeDelta: isKeyframeDelta),
    where,
  );
}

/// Refuses gaussians nothing can ever reach, over an interval of no width.
///
/// The seek rule is half-open, so `t0 == t1` selects nothing at any instant,
/// while the gaussians behind it still count toward the file's total. The
/// record parser applies this to `gaussianCount`, which it can read without
/// context; every path that knows the temporal model applies it to the
/// population, and calls this so that all of them say it the same way.
///
/// [where] locates the record — "the Chunk Index record at byte N (entry i of
/// n)". A refusal that cannot be seeked to is a refusal nobody can act on.
void refuseZeroWidthPopulation(
  FourdgsChunkIndexEntry entry,
  int population,
  String where,
) {
  if (population > 0 && entry.t0 == entry.t1) {
    throw FourdgsMalformedFile(
      '$where declares $population live gaussians over the zero-width interval '
      '[${entry.t0}, ${entry.t1}); expected 0 there, because the half-open '
      'seek rule can never select a zero-width interval',
    );
  }
}

/// Bytes the `keyframe-delta` block appends to a Chunk Index entry:
/// `u8 kind`, `u8 delta_mode`, `u64 reference_offset`, `u64 keyframe_offset`,
/// `u16 depth`, `u64 live_count`.
const int indexDeltaBlockBytes = 1 + 1 + 8 + 8 + 2 + 8;

/// Opcode `0x10` — a Delta Chunk's own fields. Its three length-framed groups
/// (updates, births, deaths) follow in the `records` blob, which
/// [parseDeltaChunk] returns alongside.
class FourdgsDeltaChunkHeader {
  const FourdgsDeltaChunkHeader({
    required this.t0,
    required this.t1,
    required this.level,
    required this.deltaMode,
    required this.referenceOffset,
    required this.keyframeOffset,
    required this.depth,
    required this.updateCount,
    required this.birthCount,
    required this.deathCount,
    required this.compression,
    required this.uncompressedSize,
  });

  final double t0;
  final double t1;
  final int level;
  final int deltaMode;
  final int referenceOffset;
  final int keyframeOffset;
  final int depth;
  final int updateCount;
  final int birthCount;
  final int deathCount;
  final String compression;
  final int uncompressedSize;
}

/// A Delta Chunk's header and the raw bytes of its three groups.
class FourdgsDeltaChunkBody {
  const FourdgsDeltaChunkBody(
    this.header,
    this.updates,
    this.births,
    this.deaths, {
    this.updatesOffset = 0,
    this.birthsOffset = 0,
    this.deathsOffset = 0,
  });

  final FourdgsDeltaChunkHeader header;

  /// Attribute streams for gaussians whose bins changed, differenced against the
  /// reference.
  final Uint8List updates;

  /// Attribute streams for gaussians born in this delta, stated absolutely.
  final Uint8List births;

  /// A single `gaussian_id` stream naming gaussians that die here.
  final Uint8List deaths;

  /// Where each group begins within the record's content, for the reason
  /// [FourdgsChunkBody.streamsOffset] carries one.
  final int updatesOffset;
  final int birthsOffset;
  final int deathsOffset;
}

/// `delta_mode` values (spec §5.18). Per chunk, not per file.
const int deltaModeKeyframe = 0;
const int deltaModeChained = 1;

FourdgsDeltaChunkBody parseDeltaChunk(Uint8List content) {
  final c = FourdgsCursor(content);
  final intervalAt = c.pos;
  final t0 = c.f64();
  final t1 = c.f64();
  refuseUnusableInterval(t0, t1, intervalAt, 'Delta Chunk');
  final head = FourdgsDeltaChunkHeader(
    t0: t0,
    t1: t1,
    level: c.u32(),
    deltaMode: c.u8(),
    referenceOffset: c.u64(),
    keyframeOffset: c.u64(),
    depth: c.u16(),
    updateCount: c.u32(),
    birthCount: c.u32(),
    deathCount: c.u32(),
    compression: c.string(),
    uncompressedSize: c.u64(),
  );
  // The three groups are framed by length inside one blob rather than tagged
  // with a group byte on every stream, so the death list — small and often
  // wanted alone — is reachable by stepping over two lengths.
  final blockLength = c.u64();
  final blockAt = c.pos;
  final Uint8List block = c.take(blockLength);
  if (head.compression.isNotEmpty) {
    // Match ordinary Chunk handling: whole-block compression is a registry
    // feature this pure-Dart decoder does not implement, so never reinterpret
    // compressed bytes as raw group framing merely because they happen to fit.
    throw FourdgsUnsupportedCodec(
      'the Delta Chunk uses chunk-level "${head.compression}" compression, '
      'which is not supported by this decoder',
      refusalCode: refusalUnknownStreamCodec,
    );
  }
  if (head.uncompressedSize != blockLength) {
    throw FourdgsMalformedFile(
      'the uncompressed Delta Chunk declares ${head.uncompressedSize} record '
      'bytes but carries $blockLength',
    );
  }
  final records = FourdgsCursor(block);
  final updates = records.take(records.u64());
  final updatesAt = records.pos - updates.length;
  final births = records.take(records.u64());
  final birthsAt = records.pos - births.length;
  final deaths = records.take(records.u64());
  final deathsAt = records.pos - deaths.length;
  if (records.remaining != 0) {
    throw FourdgsMalformedFile(
      'the Delta Chunk records block has ${records.remaining} trailing bytes '
      'after its update, birth, and death groups; expected exactly those '
      'three length-framed groups',
    );
  }
  return FourdgsDeltaChunkBody(
    head,
    updates,
    births,
    deaths,
    updatesOffset: blockAt + updatesAt,
    birthsOffset: blockAt + birthsAt,
    deathsOffset: blockAt + deathsAt,
  );
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

/// Opcode `0x11`. A small source descriptor paired with [FourdgsAudioData].
class FourdgsAudioSourceRecord {
  const FourdgsAudioSourceRecord({
    required this.sourceId,
    required this.name,
    required this.codec,
    required this.channelLayout,
    required this.dataLength,
    required this.startSec,
    required this.durationSec,
    required this.gain,
    required this.flags,
    required this.position,
    required this.rotation,
    required this.keyframes,
    required this.interpolation,
  });

  final int sourceId;
  final String name;
  final String codec;
  final String channelLayout;
  final int dataLength;
  final double startSec;
  final double durationSec;
  final double gain;
  final int flags;
  final List<double> position;
  final List<double> rotation;
  final List<FourdgsAudioSourceKeyframeRecord> keyframes;
  final String interpolation;

  bool get spatial => flags & audioSourceFlagSpatial != 0;
  bool get loop => flags & audioSourceFlagLoop != 0;

  static FourdgsAudioSourceRecord parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final sourceId = c.u32();
    final name = c.string();
    final codec = c.string();
    final channelLayout = c.string();
    final dataLength = c.u64();
    final startSec = c.f64();
    final durationSec = c.f64();
    final gain = c.f64();
    final flags = c.u8();
    final position = c.f64s(3);
    final rotation = c.f64s(4);
    final count = c.u32();
    if (count > c.remaining ~/ audioSourceKeyframeBytes) {
      throw FourdgsTruncatedFile(
        'Audio Source $sourceId declares $count keyframes needing '
        '${count * audioSourceKeyframeBytes} bytes, ${c.remaining} remain',
      );
    }
    final keyframes = <FourdgsAudioSourceKeyframeRecord>[];
    double lastTime = double.negativeInfinity;
    for (int i = 0; i < count; i++) {
      final keyframe = FourdgsAudioSourceKeyframeRecord(
        time: c.f64(),
        position: c.f64s(3),
        rotation: c.f64s(4),
      );
      if (!keyframe.time.isFinite || keyframe.time <= lastTime) {
        throw FourdgsMalformedFile(
          'Audio Source $sourceId keyframe $i time must be finite and strictly increasing',
        );
      }
      lastTime = keyframe.time;
      keyframes.add(keyframe);
    }
    final interpolation = c.string();
    final source = FourdgsAudioSourceRecord(
      sourceId: sourceId,
      name: name,
      codec: codec,
      channelLayout: channelLayout,
      dataLength: dataLength,
      startSec: startSec,
      durationSec: durationSec,
      gain: gain,
      flags: flags,
      position: position,
      rotation: rotation,
      keyframes: keyframes,
      interpolation: interpolation,
    );
    _validateAudioSource(source);
    return source;
  }
}

class FourdgsAudioSourceKeyframeRecord {
  const FourdgsAudioSourceKeyframeRecord({
    required this.time,
    required this.position,
    required this.rotation,
  });

  final double time;
  final List<double> position;
  final List<double> rotation;
}

/// Opcode `0x12`. One source's encoded codec payload.
class FourdgsAudioData {
  const FourdgsAudioData({required this.sourceId, required this.data});

  final int sourceId;
  final Uint8List data;

  static FourdgsAudioData parse(Uint8List content) {
    final c = FourdgsCursor(content);
    return FourdgsAudioData(sourceId: c.u32(), data: c.blob());
  }
}

void _validateAudioSource(FourdgsAudioSourceRecord source) {
  const allowedFlags = audioSourceFlagSpatial | audioSourceFlagLoop;
  if (source.flags & ~allowedFlags != 0) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} has reserved flag bits set',
    );
  }
  if (source.codec.isEmpty) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} has an empty codec',
    );
  }
  if (!source.startSec.isFinite) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} start_sec is not finite',
    );
  }
  if (!source.durationSec.isFinite || source.durationSec <= 0.0) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} duration_sec must be finite and positive',
    );
  }
  if (!source.gain.isFinite || source.gain < 0.0) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} gain must be finite and non-negative',
    );
  }
  if (source.spatial && source.channelLayout != 'mono') {
    throw FourdgsMalformedFile(
      'spatial Audio Source ${source.sourceId} must use channel layout "mono"',
    );
  }
  if (!source.position.every((value) => value.isFinite)) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} position must contain three finite values',
    );
  }
  if (!source.rotation.every((value) => value.isFinite) ||
      source.rotation.every((value) => value == 0.0)) {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} rotation must be a finite non-zero quaternion',
    );
  }
  for (int i = 0; i < source.keyframes.length; i++) {
    final keyframe = source.keyframes[i];
    if (!keyframe.position.every((value) => value.isFinite)) {
      throw FourdgsMalformedFile(
        'Audio Source ${source.sourceId} keyframe $i position must contain three finite values',
      );
    }
    if (!keyframe.rotation.every((value) => value.isFinite) ||
        keyframe.rotation.every((value) => value == 0.0)) {
      throw FourdgsMalformedFile(
        'Audio Source ${source.sourceId} keyframe $i rotation must be a finite non-zero quaternion',
      );
    }
  }
  if (source.interpolation != 'linear' && source.interpolation != 'step') {
    throw FourdgsMalformedFile(
      'Audio Source ${source.sourceId} uses unknown interpolation '
      '"${source.interpolation}"',
    );
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

  /// [fileOffset] is where `content` begins in the file, so a refusal names a
  /// byte someone can seek to rather than an offset into a record.
  static FourdgsCamera parse(Uint8List content, {int fileOffset = 0}) {
    final c = FourdgsCursor(content);
    final fov = c.f64();
    final position = c.f64s(3);
    final target = c.f64s(3);
    final countAt = fileOffset + c.pos;
    final n = c.u32();
    // Prove the declared samples physically fit before building any of the
    // three growable lists. Camera has no cross-SDK sample-count ceiling, so
    // the bounded record bytes are the limit; applying the trajectory ceiling
    // here would make Dart reject a Camera the other SDKs accept.
    const int keyframeBytes = 8 + 3 * 8 + 3 * 8;
    final capacity = c.remaining ~/ keyframeBytes;
    if (n > capacity) {
      throw FourdgsMalformedFile(
        'the Camera record at byte $countAt declares $n keyframes but holds '
        'room for $capacity complete $keyframeBytes-byte keyframes',
      );
    }
    final times = <double>[];
    final positions = <List<double>>[];
    final targets = <List<double>>[];
    for (int i = 0; i < n; i++) {
      times.add(c.f64());
      positions.add(c.f64s(3));
      targets.add(c.f64s(3));
    }
    final interpolation = c.string();
    final loopAt = fileOffset + c.pos;
    final loop = c.u8();
    if (loop > 1) {
      throw FourdgsMalformedFile(
        'the Camera record at byte $fileOffset carries loop value $loop at '
        'byte $loopAt; expected 0 or 1',
      );
    }
    return FourdgsCamera(
      fovYDeg: fov,
      position: position,
      target: target,
      times: times,
      positions: positions,
      targets: targets,
      interpolation: interpolation,
      loop: loop == 1,
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

// ---------------------------------------------------------------------------
// Provenance records (spec §5.15).
//
// What `parse` refuses here is narrower than what a validator reports. A parse
// refuses only the structurally impossible — a basis that is not a basis, a
// quaternion with no direction, timestamps that make an interval ambiguous —
// because those are values no consumer can do anything sensible with. A value
// that is merely unrecognized (a modality this build has not heard of, a
// camera model it cannot project with) survives parsing and reaches the caller
// raw, which is the distinction between "malformed" and "from a newer registry"
// that a caller needs in order to react differently to the two.
// ---------------------------------------------------------------------------

/// Wire constant: sensor extrinsic maps into the scene frame.
const int poseToScene = 0;

/// Wire constant: sensor extrinsic maps into a named rig.
const int poseToRig = 1;

/// Wire constant: linear (slerp + lerp) trajectory interpolation.
const int trajectoryLinear = 0;

/// Wire constant: hold-until-next sample trajectory interpolation.
const int trajectoryStep = 1;

/// Coefficient counts each camera model defines, keyed by its registry id.
/// A model absent from here is one this build does not know — not the same as
/// wrong: `null` means "ask the caller", not "refuse".
const Map<int, List<int>> cameraModelCoefficients = <int, List<int>>{
  0: <int>[0], // none — the sensor is not a camera
  1: <int>[0], // pinhole
  2: <int>[5, 8], // brown-conrady, plain or rational
  3: <int>[4], // kannala-brandt
};

/// The frame a file's own coordinates are expressed in. Opcode `0x20`.
///
/// A fixed shape: every field is always present, so a reader that knows these
/// six knows exactly where an appended seventh would begin. The georeference is
/// a separate record ([FourdgsGeodeticAnchor], `0x23`) for that reason.
class FourdgsCoordinateFrame {
  const FourdgsCoordinateFrame({
    required this.name,
    required this.handedness,
    required this.upAxis,
    required this.forwardAxis,
    required this.lengthUnit,
    required this.metresPerUnit,
  });

  final String name;
  final int handedness;
  final int upAxis;
  final int forwardAxis;
  final int lengthUnit;
  final double metresPerUnit;

  static FourdgsCoordinateFrame parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final frame = FourdgsCoordinateFrame(
      name: c.string(),
      handedness: c.u8(),
      upAxis: c.u8(),
      forwardAxis: c.u8(),
      lengthUnit: c.u8(),
      metresPerUnit: c.f64(),
    );
    frame.check();
    return frame;
  }

  /// Refuse a frame that is not one, rather than repair it.
  void check() {
    for (final entry in <(String, int)>[
      ('up_axis', upAxis),
      ('forward_axis', forwardAxis),
    ]) {
      if (entry.$2 > 5) {
        throw FourdgsMalformedFile(
          'CoordinateFrame ${entry.$1} is ${entry.$2}; the registry defines '
          '0..5 (section 5.15.2)',
        );
      }
    }
    if (upAxis % 3 == forwardAxis % 3) {
      throw FourdgsMalformedFile(
        'CoordinateFrame up_axis $upAxis and forward_axis $forwardAxis name '
        'the same axis; a frame needs two different ones (section 5.15.2)',
      );
    }
    if (!metresPerUnit.isFinite || metresPerUnit < 0.0) {
      throw FourdgsMalformedFile(
        'CoordinateFrame metres_per_unit is $metresPerUnit; it must be finite '
        'and not negative (section 5.15.2)',
      );
    }
  }
}

/// Where a frame's origin sits on the WGS-84 ellipsoid, and which way it faces.
/// Opcode `0x23`.
class FourdgsGeodeticAnchor {
  const FourdgsGeodeticAnchor({
    required this.frameName,
    required this.latitudeDeg,
    required this.longitudeDeg,
    required this.altitudeM,
    required this.headingDeg,
  });

  final String frameName;
  final double latitudeDeg;
  final double longitudeDeg;
  final double altitudeM;
  final double headingDeg;

  static FourdgsGeodeticAnchor parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final frameName = c.string();
    final values = c.f64s(4);
    final anchor = FourdgsGeodeticAnchor(
      frameName: frameName,
      latitudeDeg: values[0],
      longitudeDeg: values[1],
      altitudeM: values[2],
      headingDeg: values[3],
    );
    anchor.check();
    return anchor;
  }

  /// Refuse an out-of-range angle rather than wrap it.
  void check() {
    for (final entry in <(String, double, double, double)>[
      ('latitude_deg', latitudeDeg, -90.0, 90.0),
      ('longitude_deg', longitudeDeg, -180.0, 180.0),
      ('altitude_m', altitudeM, double.negativeInfinity, double.infinity),
      ('heading_deg', headingDeg, 0.0, 360.0),
    ]) {
      final label = entry.$1;
      final value = entry.$2;
      final lo = entry.$3;
      final hi = entry.$4;
      if (!value.isFinite) {
        throw FourdgsMalformedFile(
          'GeodeticAnchor $label is $value; every field must be finite',
        );
      }
      final pastEnd = label == 'heading_deg' && value == 360.0;
      if (value < lo || value > hi || pastEnd) {
        throw FourdgsMalformedFile(
          'GeodeticAnchor $label is $value, outside its legal range '
          '(section 5.15.5)',
        );
      }
    }
  }
}

/// One sensor's intrinsics and extrinsics. Opcode `0x21`, one record per sensor.
///
/// The extrinsic maps sensor coordinates into the frame [poseReference] names,
/// in that direction: `p_target = R(rotation) * p_sensor + translation`.
class FourdgsSensorCalibration {
  const FourdgsSensorCalibration({
    required this.name,
    required this.modality,
    required this.cameraModel,
    required this.widthPx,
    required this.heightPx,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.distortion,
    required this.rotation,
    required this.translation,
    required this.poseReference,
    required this.rigName,
  });

  final String name;
  final String modality;
  final int cameraModel;
  final int widthPx;
  final int heightPx;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final List<double> distortion;

  /// Unit quaternion, `xyzw` — the same order as spec §3 and §6.4.
  final List<double> rotation;
  final List<double> translation;
  final int poseReference;
  final String rigName;

  bool get isCamera => cameraModel != 0;

  static FourdgsSensorCalibration parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final name = c.string();
    final modality = c.string();
    final cameraModel = c.u8();
    final widthPx = c.u32();
    final heightPx = c.u32();
    final intr = c.f64s(4);
    final count = c.u8();
    final distortion = c.f64s(count);
    final rotation = c.f64s(4);
    final translation = c.f64s(3);
    final sensor = FourdgsSensorCalibration(
      name: name,
      modality: modality,
      cameraModel: cameraModel,
      widthPx: widthPx,
      heightPx: heightPx,
      fx: intr[0],
      fy: intr[1],
      cx: intr[2],
      cy: intr[3],
      distortion: distortion,
      rotation: rotation,
      translation: translation,
      poseReference: c.u8(),
      rigName: c.string(),
    );
    sensor.check();
    return sensor;
  }

  void check() {
    void finite(String label, double value) {
      if (!value.isFinite) {
        throw FourdgsMalformedFile(
          "sensor '$name': $label is $value; every value must be finite",
        );
      }
    }

    finite('fx', fx);
    finite('fy', fy);
    finite('cx', cx);
    finite('cy', cy);
    for (int i = 0; i < distortion.length; i++) {
      finite('distortion[$i]', distortion[i]);
    }
    for (int i = 0; i < rotation.length; i++) {
      finite('rotation[$i]', rotation[i]);
    }
    for (int i = 0; i < translation.length; i++) {
      finite('translation[$i]', translation[i]);
    }

    final norm = quaternionNorm(rotation);
    if (!norm.isFinite || norm == 0.0) {
      throw FourdgsMalformedFile(
        "sensor '$name': rotation quaternion has no direction (norm $norm)",
      );
    }

    final legal = cameraModelCoefficients[cameraModel];
    if (legal != null && !legal.contains(distortion.length)) {
      throw FourdgsMalformedFile(
        "sensor '$name': camera model $cameraModel defines "
        '${legal.join(' or ')} distortion coefficients, the record carries '
        '${distortion.length}',
      );
    }

    if (!isCamera) {
      for (final entry in <(String, bool)>[
        ('width_px', widthPx != 0),
        ('height_px', heightPx != 0),
        ('fx', fx != 0.0),
        ('fy', fy != 0.0),
        ('cx', cx != 0.0),
        ('cy', cy != 0.0),
      ]) {
        if (entry.$2) {
          throw FourdgsMalformedFile(
            "sensor '$name' declares camera_model 0 but a non-zero ${entry.$1}",
          );
        }
      }
    } else if (fx == 0.0 || fy == 0.0 || widthPx == 0 || heightPx == 0) {
      throw FourdgsMalformedFile(
        "sensor '$name' declares camera model $cameraModel but has a zero "
        'focal length or image size',
      );
    }
  }
}

/// Encoded size of one rig trajectory sample: time + rotation + translation.
const int rigTrajectorySampleBytes = 8 + 32 + 24;

/// The measured pose of the capture platform over the scene clock. Opcode `0x22`.
///
/// Not the [FourdgsCamera] record, which is a viewing suggestion a reader may
/// ignore. This is where the sensors were.
/// The Euclidean norm of a quaternion, computed without squaring the components first.
///
/// A component near the top of the double range squares to infinity, so the naive
/// sum reports an infinite norm for a rotation whose norm is finite and whose
/// direction is perfectly good. Section 5.15.4 refuses "zero or non-finite norms" —
/// a statement about the quaternion, not about the arithmetic used to measure it.
/// Dividing by the largest magnitude first makes the sum safe.
double quaternionNorm(List<double> q) {
  double scale = 0.0;
  for (final v in q) {
    final m = v.abs();
    if (m > scale) scale = m;
  }
  // Left for the caller to refuse, with the message it words for its own record.
  if (!scale.isFinite || scale == 0.0) return scale;
  double sum = 0.0;
  for (final v in q) {
    final u = v / scale;
    sum += u * u;
  }
  return scale * math.sqrt(sum);
}

class FourdgsRigTrajectory {
  FourdgsRigTrajectory({
    required this.name,
    required this.interpolation,
    required this.times,
    required this.rotations,
    required this.translations,
  });

  final String name;
  final int interpolation;
  final List<double> times;
  final List<List<double>> rotations;
  final List<List<double>> translations;

  int get sampleCount => times.length;

  static FourdgsRigTrajectory parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final name = c.string();
    final interpolation = c.u8();
    final count = c.u32();
    // Bounded like the other count-prefixed records: a crafted count must not
    // size an allocation before the bytes behind it have been shown to exist.
    if (count > c.remaining ~/ rigTrajectorySampleBytes) {
      throw FourdgsMalformedFile(
        "trajectory '$name' declares $count samples but holds room for "
        '${c.remaining ~/ rigTrajectorySampleBytes}',
      );
    }
    if (count > maxTrajectorySamples) {
      throw FourdgsMalformedFile(
        "trajectory '$name' declares $count samples, past the "
        '$maxTrajectorySamples ceiling',
      );
    }
    final times = <double>[];
    final rotations = <List<double>>[];
    final translations = <List<double>>[];
    for (int i = 0; i < count; i++) {
      times.add(c.f64());
      rotations.add(c.f64s(4));
      translations.add(c.f64s(3));
    }
    final trajectory = FourdgsRigTrajectory(
      name: name,
      interpolation: interpolation,
      times: times,
      rotations: rotations,
      translations: translations,
    );
    // Section 5.15.4: a trajectory with no samples "MUST be read as though the
    // record were absent", so reading one refuses nothing — not even an
    // interpolation byte outside the registry, which describes how to read
    // samples it does not carry. `check` stays strict for the writer.
    if (trajectory.times.isNotEmpty) trajectory._checkSamples();
    return trajectory;
  }

  /// Refuse times that are not strictly increasing, naming the sample.
  void check() {
    if (interpolation != trajectoryLinear && interpolation != trajectoryStep) {
      throw FourdgsMalformedFile(
        "trajectory '$name' uses interpolation $interpolation; this reader "
        'supports trajectory interpolation registry values 0 (linear) and 1 '
        '(step)',
      );
    }
    _checkSamples();
  }

  void _checkSamples() {
    for (int i = 0; i < times.length; i++) {
      final t = times[i];
      if (!t.isFinite) {
        throw FourdgsMalformedFile(
          "trajectory '$name': sample $i has a non-finite time ($t)",
        );
      }
      if (i > 0 && t <= times[i - 1]) {
        throw FourdgsMalformedFile(
          "trajectory '$name': sample $i is at t=$t, not after sample ${i - 1} "
          'at t=${times[i - 1]}; times must strictly increase (section 5.15.4)',
        );
      }
    }
    for (int i = 0; i < rotations.length; i++) {
      final q = rotations[i];
      final norm = quaternionNorm(q);
      if (!norm.isFinite || norm == 0.0) {
        throw FourdgsMalformedFile(
          "trajectory '$name': sample $i rotation has no direction "
          '(norm $norm)',
        );
      }
    }
    for (int i = 0; i < translations.length; i++) {
      final tr = translations[i];
      for (int k = 0; k < tr.length; k++) {
        if (!tr[k].isFinite) {
          throw FourdgsMalformedFile(
            "trajectory '$name': sample $i translation[$k] is ${tr[k]}",
          );
        }
      }
    }
  }
}

/// Background / unassigned. A gaussian carrying this id belongs to no object.
const int backgroundObject = 0;

/// One object's advisory description. Nothing here transforms a gaussian.
/// Refuse a value the record's field cannot hold.
///
/// These ids and dimensions are `u32` and `u16` on the wire, so the parser can
/// only ever produce values inside them. A caller constructing a record can
/// produce a negative or out-of-range id, and nothing downstream would notice:
/// membership is compared as an unsigned integer, so a track keyed outside the
/// range matches no gaussian while still looking valid. Rust gets this from its
/// types and Python checks it by hand; Dart carries `int`, so it checks too.
void _checkUnsignedField(int value, int max, String message) {
  if (value < 0 || value > max) {
    throw FourdgsMalformedFile(message);
  }
}

/// The largest finite f32, the range every object-table lane is stored in.
const double _f32Max = 3.4028234663852886e38;

class FourdgsObjectEntry {
  FourdgsObjectEntry({
    required this.objectId,
    required this.label,
    required this.anchor,
    required this.dynamics,
    required this.embedding,
  });

  final int objectId;
  final String label;
  final List<double> anchor;

  /// `[velocity, angularVelocity, acceleration]`, or null when absent. Never a
  /// substitute for a track: reconstruction reads none of these.
  final List<List<double>>? dynamics;
  final List<double>? embedding;
}

/// The scene's one Object Table. Opcode `0x24`.
///
/// Everything in it is advisory: membership comes from the `object_id`
/// attribute (section 6.6) and geometry changes only through an Object Track
/// (section 5.15.7). A reader that skips this record still decodes every
/// gaussian correctly; what it loses is the names.
class FourdgsObjectTable {
  FourdgsObjectTable({required this.embeddingDim, required this.entries});

  final int embeddingDim;
  final List<FourdgsObjectEntry> entries;

  static FourdgsObjectTable parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final objectCount = c.u32();
    final embeddingDim = c.u16();
    // The smallest an entry can be: id, an empty label, the anchor and the
    // dynamics flag, plus the embedding flag once a space is declared. Bounded
    // before anything is sized from it, like every other count-prefixed record.
    final minimumEntryBytes = 4 + 4 + 12 + 1 + (embeddingDim > 0 ? 1 : 0);
    if (objectCount > c.remaining ~/ minimumEntryBytes) {
      throw FourdgsMalformedFile(
        'ObjectTable declares $objectCount objects but holds room for '
        '${c.remaining ~/ minimumEntryBytes}',
      );
    }
    final entries = <FourdgsObjectEntry>[];
    for (int i = 0; i < objectCount; i++) {
      final objectId = c.u32();
      final label = c.string();
      final anchor = c.f32s(3);
      final dynamicsPresent = c.u8();
      if (dynamicsPresent > 1) {
        throw FourdgsMalformedFile(
          'ObjectTable entry $i has dynamics_present $dynamicsPresent; it must '
          'be 0 or 1 (section 5.15.6)',
        );
      }
      final dynamics =
          dynamicsPresent == 1
              ? <List<double>>[c.f32s(3), c.f32s(3), c.f32s(3)]
              : null;
      List<double>? embedding;
      if (embeddingDim > 0) {
        final hasEmbedding = c.u8();
        if (hasEmbedding > 1) {
          throw FourdgsMalformedFile(
            'ObjectTable entry $i has has_embedding $hasEmbedding; it must be '
            '0 or 1 (section 5.15.6)',
          );
        }
        if (hasEmbedding == 1) {
          if (embeddingDim * 4 > c.remaining) {
            throw FourdgsMalformedFile(
              'ObjectTable entry $i declares a $embeddingDim-dimensional '
              'embedding (${embeddingDim * 4} bytes), ${c.remaining} remain',
            );
          }
          embedding = c.f32s(embeddingDim);
        }
      }
      entries.add(
        FourdgsObjectEntry(
          objectId: objectId,
          label: label,
          anchor: anchor,
          dynamics: dynamics,
          embedding: embedding,
        ),
      );
    }
    final table = FourdgsObjectTable(
      embeddingDim: embeddingDim,
      entries: entries,
    );
    table.check();
    return table;
  }

  /// Refuse a table that cannot be indexed by id, and values that are not
  /// numbers. Two entries for one id make every lookup a coin toss, which is
  /// the duplicate-name failure section 5.15.2 refuses for frames and sensors,
  /// spelled with integers.
  void check() {
    _checkUnsignedField(
      embeddingDim,
      0xFFFF,
      'ObjectTable embedding_dim is $embeddingDim; expected an integer in '
      '[0, 65535]',
    );
    final seen = <int>{};
    for (final entry in entries) {
      _checkUnsignedField(
        entry.objectId,
        0xFFFFFFFF,
        'ObjectTable entry has object_id ${entry.objectId}; expected an '
        'integer in [0, 4294967295]',
      );
      if (!seen.add(entry.objectId)) {
        throw FourdgsMalformedFile(
          'two ObjectTable entries describe object ${entry.objectId}; entries '
          'are referred to by id and nothing else (section 5.15.6)',
        );
      }
      // These lanes are stored as f32, so the range is the field's rather than
      // the double's: a finite 1e100 fits no conforming record — written as f32
      // it rounds to infinity — and Python refuses it as
      // `object-value-out-of-f32-range`.
      void finite(String label, List<double> values) {
        for (int k = 0; k < values.length; k++) {
          if (values[k].isFinite && values[k].abs() > _f32Max) {
            throw FourdgsMalformedFile(
              'ObjectTable entry ${entry.objectId}: $label[$k] is '
              '${values[k]}, outside the finite f32 range',
            );
          }
          if (!values[k].isFinite) {
            throw FourdgsMalformedFile(
              'ObjectTable entry ${entry.objectId}: $label[$k] is '
              '${values[k]}; every stored value must be finite '
              '(section 5.15.6)',
            );
          }
        }
      }

      // The wire record carries f32[3] for each of these, so a shorter vector
      // is a shape no conforming file can hold — Rust cannot express it, its
      // fields are [f32; 3]. The parser always builds three; a caller
      // constructing a table can hand over two, and every value in it would be
      // checked and accepted.
      void width(String label, List<double> values) {
        if (values.length != 3) {
          throw FourdgsMalformedFile(
            'ObjectTable entry ${entry.objectId}: $label has '
            '${values.length} values, expected 3',
          );
        }
      }

      width('anchor', entry.anchor);
      finite('anchor', entry.anchor);
      final dynamics = entry.dynamics;
      if (dynamics != null) {
        // Three vectors when the dynamics flag is set. Indexing first turns a
        // short list into a RangeError — a library's error rather than this
        // library naming the object and the field — and lets a longer one
        // through with the extra vectors silently ignored.
        if (dynamics.length != 3) {
          throw FourdgsMalformedFile(
            'ObjectTable entry ${entry.objectId}: dynamics has '
            '${dynamics.length} vectors, expected 3 (velocity, '
            'angular_velocity, acceleration)',
          );
        }
        width('velocity', dynamics[0]);
        width('angular_velocity', dynamics[1]);
        width('acceleration', dynamics[2]);
        finite('velocity', dynamics[0]);
        finite('angular_velocity', dynamics[1]);
        finite('acceleration', dynamics[2]);
      }
      // An embedding has to match the space the table declares. `embedding_dim`
      // is declared once for the whole file, so a vector of a different width —
      // or any vector at all when the table declares no embedding space —
      // describes a coordinate system nothing else in the file shares. Python
      // refuses both; the parser cannot build either shape, but a caller
      // constructing a table can.
      final embedding = entry.embedding;
      if (embedding != null) {
        if (embeddingDim == 0) {
          throw FourdgsMalformedFile(
            'object ${entry.objectId}: an embedding is present but '
            'embedding_dim is 0',
          );
        }
        if (embedding.length != embeddingDim) {
          throw FourdgsMalformedFile(
            'object ${entry.objectId}: embedding has ${embedding.length} '
            'values, embedding_dim declares $embeddingDim',
          );
        }
        finite('embedding', embedding);
      }
    }
  }
}

/// One object's rigid pose over the scene clock. Opcode `0x25`, one per object.
///
/// Structurally a [FourdgsRigTrajectory] keyed by object id rather than by
/// name, and deliberately so: it satisfies [FourdgsPoseSampled] through
/// [FourdgsObjectTrackView], so section 5.15.4's clamp-and-slerp is the same
/// code for both and cannot drift between them.
class FourdgsObjectTrack {
  FourdgsObjectTrack({
    required this.objectId,
    required this.interpolation,
    required this.times,
    required this.rotations,
    required this.translations,
  });

  final int objectId;
  final int interpolation;
  final List<double> times;
  final List<List<double>> rotations;
  final List<List<double>> translations;

  int get sampleCount => times.length;

  static FourdgsObjectTrack parse(Uint8List content) {
    final c = FourdgsCursor(content);
    final objectId = c.u32();
    final interpolation = c.u8();
    final count = c.u32();
    // Each sample is 8 + 32 + 24 bytes, as for a rig trajectory.
    if (count > c.remaining ~/ rigTrajectorySampleBytes) {
      throw FourdgsMalformedFile(
        'ObjectTrack for object $objectId declares $count samples but holds '
        'room for ${c.remaining ~/ rigTrajectorySampleBytes}',
      );
    }
    if (count > maxTrajectorySamples) {
      throw FourdgsMalformedFile(
        'ObjectTrack for object $objectId declares $count samples, past the '
        '$maxTrajectorySamples ceiling',
      );
    }
    final times = <double>[];
    final rotations = <List<double>>[];
    final translations = <List<double>>[];
    for (int i = 0; i < count; i++) {
      times.add(c.f64());
      rotations.add(c.f64s(4));
      translations.add(c.f64s(3));
    }
    final track = FourdgsObjectTrack(
      objectId: objectId,
      interpolation: interpolation,
      times: times,
      rotations: rotations,
      translations: translations,
    );
    // Section 5.15.7: a zero-sample track "has no pose and is read as absent",
    // so reading one refuses nothing about its pose. The id is not part of the
    // pose — the same section requires every track to refuse object 0 — so that
    // rule holds for an absent track too, and the rest waits for the writer.
    if (track.times.isNotEmpty) {
      track.check();
    } else if (track.objectId == backgroundObject) {
      throw FourdgsMalformedFile(
        'an ObjectTrack names object 0, which means background / unassigned; a '
        'track must move an object that exists (section 5.15.7)',
      );
    }
    return track;
  }

  /// A track's own rules: it moves a real object, and its samples are a
  /// function of time. The pose rules are the trajectory's, so they are
  /// checked by the trajectory's checker rather than restated — the two
  /// records interpolate identically and a second copy is a second thing to
  /// get wrong.
  void check() {
    _checkUnsignedField(
      objectId,
      0xFFFFFFFF,
      'ObjectTrack has object_id $objectId; expected an integer in '
      '[0, 4294967295]',
    );
    if (objectId == backgroundObject) {
      throw FourdgsMalformedFile(
        'an ObjectTrack names object 0, which means background / unassigned; a '
        'track must move an object that exists (section 5.15.7)',
      );
    }
    // The trajectory rules iterate each array on its own, so they cannot see a
    // track whose arrays disagree in length — a shape the parser cannot produce
    // but a caller building a record can. Left to them, pose sampling reads past
    // the short array and the file comes back as a range error rather than a
    // malformed-file error. Python and Rust check this before delegating.
    if (rotations.length != times.length ||
        translations.length != times.length) {
      throw FourdgsMalformedFile(
        'track for object $objectId: ${times.length} times, '
        '${rotations.length} rotations, and ${translations.length} '
        'translations; every sample needs all three',
      );
    }
    // And each sample has to be the right width. The trajectory rules iterate
    // whatever coordinates are present, so a translation of two numbers passes
    // them and then reads past the end during composition rather than being
    // refused. Rust cannot express this — its samples are [f64; 4] and
    // [f64; 3] — and Python names it; here it has to be checked.
    for (int i = 0; i < times.length; i++) {
      if (rotations[i].length != 4) {
        throw FourdgsMalformedFile(
          'track for object $objectId: sample $i rotation has '
          '${rotations[i].length} values, expected 4',
        );
      }
      if (translations[i].length != 3) {
        throw FourdgsMalformedFile(
          'track for object $objectId: sample $i translation has '
          '${translations[i].length} values, expected 3',
        );
      }
    }
    FourdgsRigTrajectory(
      name: 'object $objectId',
      interpolation: interpolation,
      times: times,
      rotations: rotations,
      translations: translations,
    ).check();
  }
}

/// Encoded size of one window table entry: two `f64` bounds.
const int windowBytes = 16;

/// Encoded size of one SH band descriptor: `u8 band`, `u64 offset`, `u64 length`.
const int bandRangeBytes = 17;

/// `f64 time`, three `f64` position values and four `f64` quaternion values.
const int audioSourceKeyframeBytes = 64;

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

/// The most samples one count-prefixed trajectory may declare — a Rig
/// Trajectory, an Object Track, or the Camera record's suggested path.
///
/// `MAX_TRAJECTORY_SAMPLES` in Python, Rust and TypeScript, and 1,000,000 here
/// because it is 1,000,000 there. A ceiling only one implementation has means a
/// file that decodes in three SDKs and is refused in the fourth, which is a
/// conformance split rather than hardening; the number is shared by value for
/// that reason, and not because a Dart list costs what a Rust `Vec` does.
///
/// A ten-minute capture at 100 Hz is sixty thousand samples; this ceiling is an
/// order of magnitude above that and still a refusal rather than an allocation
/// a hostile file chooses.
///
/// Sized to stay under [maxFrontMatterBytes], the 64 MiB range cap the indexed
/// path enforces: at 64 bytes a sample this is 64 MB of samples, leaving room
/// for the name, the count and the record framing. `1 << 20` would have been 64
/// MiB of samples *exactly*, so a trajectory at the ceiling parsed on the
/// streamed path and was refused on the indexed one — the same file, two
/// answers from one SDK.
const int maxTrajectorySamples = 1000000;

/// The former public name for [maxTrajectorySamples].
///
/// Kept because `records.dart` is exported from the package entry point and removing a
/// top-level constant would make existing consumers fail to compile on upgrade.
@Deprecated('Use maxTrajectorySamples')
const int maxRigTrajectorySamples = maxTrajectorySamples;
