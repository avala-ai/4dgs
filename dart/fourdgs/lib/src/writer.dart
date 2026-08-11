// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The encoder: gaussians in, framed `.4dgs` records out.
///
/// A second implementation rather than a binding. Dart authoring — a Flutter
/// tool, a converter, a test fixture — is the point, so the arithmetic here
/// mirrors the reference encoders rather than calling into one. Every attribute
/// lands on the grid the Quantization record declares, the records are framed
/// by length, the summary is written contiguously ahead of the Footer, and the
/// magic closes the file as it opened it.
///
/// What makes two independent encoders interchangeable is that a decoder cannot
/// tell their output apart once decoded. The bins computed here are the same
/// integers the Python and Rust encoders compute for the same input, so the
/// decoded values agree to the last bit. Byte layout below that — how well
/// `deflate` did, whether a stream came out smaller raw or delta-coded — is an
/// encoder's own business and is not part of what the file means.
///
/// Bounded like the decoders (AGENTS.md §1): nothing here is quadratic in the
/// gaussian count, no chunk's streams are held after its record is emitted, and
/// [writeFourdgsToSink] never retains the complete file. [writeFourdgsBytes] is
/// the explicit in-memory convenience for callers that already need one buffer.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

import 'chunk_decoder.dart' show shBandRange;
import 'exceptions.dart';
import 'model.dart';
import 'opcode.dart';
import 'quantization.dart';
import 'serialization.dart';

/// The caller handed the encoder something no conforming file can be written
/// from.
///
/// Distinct from [FourdgsMalformedFile], which is about bytes that arrived:
/// this one is about values that were passed in, and the fix is on the calling
/// side. The message names the field and the gaussian, because "a value is not
/// finite" without either is a diagnosis the caller cannot act on (AGENTS.md
/// §6).
class FourdgsInvalidInput extends FourdgsException {
  const FourdgsInvalidInput(super.message);
}

/// The reference lifetime the velocity grid is expressed against (spec §6.3).
const double _lifeRef = 0.5;

/// Maximum population whose encoded attribute streams share one Chunk record.
///
/// A Chunk is framed by its total byte length, so its streams must be encoded
/// before its header can be emitted. Keeping this fixed makes the record buffer
/// bounded even when the caller supplies a much larger validated scene.
const int _maxGaussiansPerChunk = 16384;

/// Quantization profiles, as `(k, scaleRel, rot, rgb255, time, sigmaRel, sh)`.
///
/// `k` scales the position tolerance by the scene's own median gaussian radius,
/// so a profile means the same thing on a tabletop capture and on a city block.
const Map<String, List<double>> _profiles = <String, List<double>>{
  'fine': <double>[0.02, 0.005, 0.0005, 0.5, 0.0005, 0.005, 0],
  'default': <double>[0.05, 0.02, 0.002, 1.0, 0.002, 0.02, 0],
  'coarse': <double>[0.20, 0.06, 0.006, 3.0, 0.008, 0.06, 1],
};

/// How a scene is written. The defaults are the reference encoders' own.
class FourdgsWriteOptions {
  const FourdgsWriteOptions({
    this.profile = 'default',
    this.cutoff = fourdgsDefaultCutoff,
    this.codec = codecDeflate,
    this.level = 6,
    this.writeIndex = true,
    this.writeStatistics = false,
    this.writeSummaryOffsets = false,
    this.writeCrc = true,
    this.shBands = 3,
    this.library = '4dgs-dart encoder',
    this.sceneProfile = '',
    this.attributes = const <String, String>{},
  });

  /// The quantization profile: `fine`, `default` or `coarse`. It selects the
  /// error bounds, and through them every grid pitch the file declares.
  final String profile;

  /// The Header's marginal visibility threshold. Not only metadata: it sets the
  /// support constant the per-gaussian velocity grid is derived from, so encoder
  /// and decoder must agree on it, and they do by reading it from the file.
  final double cutoff;

  /// The stream codec. Only [codecDeflate] is available to a pure-Dart build,
  /// which is why it is the default everywhere.
  final int codec;

  /// Deflate compression level, 0–9.
  final int level;

  final bool writeIndex;
  final bool writeStatistics;
  final bool writeSummaryOffsets;
  final bool writeCrc;

  /// Highest spherical-harmonic band to write, capped further by the scene's
  /// own degree.
  final int shBands;

  /// Free-form producer identification, written to the Header.
  final String library;

  /// The Header's `profile` field — a well-known scene profile name, which is a
  /// different thing from the quantization [profile] above.
  final String sceneProfile;

  /// The Header's free-form attribute map.
  final Map<String, String> attributes;
}

/// Encode [gaussians] as one in-memory `.4dgs` file.
///
/// [durationSec] is the scene length; playback covers `[0, durationSec)`. A
/// static asset is `0`, and the index it produces is the single half-open
/// interval `[0, 1e-9)` the reference encoders write for one — a seek at `t=0`
/// has to land somewhere, and an empty interval covers no instant at all.
Uint8List writeFourdgsBytes(
  FourdgsGaussianSet gaussians,
  double durationSec, {
  FourdgsWriteOptions options = const FourdgsWriteOptions(),
}) {
  final collector = _ByteCollector();
  writeFourdgsToSink(collector, gaussians, durationSec, options: options);
  return collector.finish();
}

/// Encode [gaussians] to [sink], one complete framed record at a time.
///
/// The sink is borrowed and is not closed. The writer retains the quantized
/// gaussian lanes and the small Chunk Index, but releases each Chunk and SH Band
/// record after [Sink.add] returns; memory does not grow with the output file.
/// A sink that performs I/O belongs in a transport package at the application
/// edge, while tests and browsers can supply any other `Sink<List<int>>`.
void writeFourdgsToSink(
  Sink<List<int>> sink,
  FourdgsGaussianSet gaussians,
  double durationSec, {
  FourdgsWriteOptions options = const FourdgsWriteOptions(),
}) {
  if (durationSec.isNaN || durationSec < 0.0) {
    throw FourdgsInvalidInput(
      'duration_sec is $durationSec; expected a value >= 0, or +Infinity for '
      'an open-ended scene (a static asset says so with 0)',
    );
  }
  if (!_profiles.containsKey(options.profile)) {
    throw FourdgsInvalidInput(
      'unknown quantization profile "${options.profile}"; '
      'the profiles are ${_profiles.keys.toList()..sort()}',
    );
  }
  if (options.codec != codecDeflate) {
    throw FourdgsUnsupportedCodec(
      'stream codec ${options.codec} is not available to a pure-Dart build; '
      'write deflate, which every reader implements',
    );
  }
  if (options.level < 0 || options.level > 9) {
    throw FourdgsInvalidInput(
      'deflate level is ${options.level}; expected an integer from 0 through 9',
    );
  }
  // A profile is a promise about what the file contains, made so a consumer can
  // reject an unsuitable file up front rather than discovering the absence
  // mid-decode. `objects` promises an `object_id` stream in every non-empty
  // chunk and one Object Table (registry, Profiles). This writer can emit the
  // stream when the gaussian set supplies it, but its API has no Object Table
  // input at all. Writing the string anyway would put a promise in the Header
  // that the bytes below it do not keep. Refusing names the unsupported record;
  // silently downgrading to "" would throw away what the caller asked for.
  if (options.sceneProfile == 'objects') {
    throw FourdgsInvalidInput(
      'the scene profile "objects" promises one Object Table, but this writer '
      'has no Object Table input; write the object layer first or leave the '
      'profile empty',
    );
  }
  if (options.sceneProfile == 'relightable') {
    throw FourdgsInvalidInput(
      'the scene profile "relightable" is reserved for a future relighting '
      'extension, and a version-1 writer MUST NOT emit it',
    );
  }
  if (options.sceneProfile == 'keyframed') {
    throw const FourdgsInvalidInput(
      'the scene profile "keyframed" promises a keyframe-delta temporal model '
      'with indexed state chunks and Statistics, while this writer emits the '
      'gaussian-birth model; use the sequence writer or leave the profile empty',
    );
  }
  _checkInput(gaussians, options.cutoff);

  final n = gaussians.count;
  final grid = _Grid.forScene(gaussians, options.profile);
  final windows = _WindowTable.of(gaussians);
  final encodedAabb = _encodedAabb(gaussians, grid);

  // Window boundaries are the top level of the temporal partition. Anything
  // strictly inside the clip is a split point; the ends are always present.
  final tops = _tops(windows.windows, durationSec);
  final plans = _planChunks(gaussians, tops, options);

  final bands = _bandColumns(gaussians, options.shBands);

  final out = _SinkWriter(sink);
  out.bytes(fourdgsMagic);
  // The degree the file actually carries, which is the highest band written and
  // not the degree the input happened to hold. `shBands` caps what is emitted,
  // so a degree-3 scene written with `shBands: 1` carries band 1 alone — three
  // coefficients per component — and declaring 3 there would promise fifteen.
  // Bands are whole and a reader takes them whole (spec §6.5): bands 1..D give
  // exactly a degree-D scene, so D is a count of what is present.
  out.bytes(
    _header(
      gaussians,
      durationSec,
      options,
      bands.isEmpty ? 0 : bands.last.band,
      encodedAabb,
    ),
  );
  out.bytes(_quantizationRecord(grid, windows));
  out.bytes(_windowTableRecord(windows));

  final index = <_IndexEntry>[];
  for (final plan in plans) {
    // Quantized columns are bounded by one Chunk. Keeping the whole scene's
    // eleven lanes here would make the sink API retain memory in proportion to
    // output size even though every framed record is released immediately.
    final quantized = _quantize(
      gaussians,
      plan.members,
      grid,
      windows,
      options.cutoff,
    );
    final streams = _ByteWriter(4096);
    for (final lane in quantized.lanes) {
      streams.bytes(
        _encodeStream(lane.attributeId, lane.values, lane.channels, options),
      );
    }
    final chunkOffset = out.length;
    final chunk = _chunkRecord(
      plan.t0,
      plan.t1,
      plan.level,
      plan.members.length,
      streams.finish(),
    );
    out.bytes(chunk);

    final entryBands = <_IndexBand>[];
    for (final band in bands) {
      final blob = _bandRecord(
        gaussians,
        band,
        plan.members,
        options,
        grid.stepSh,
      );
      final at = out.length;
      out.bytes(blob);
      entryBands.add(_IndexBand(band.band, at, blob.length));
    }

    index.add(
      _IndexEntry(
        t0: plan.t0,
        t1: plan.t1,
        chunkOffset: chunkOffset,
        chunkLength: chunk.length,
        gaussianCount: plan.members.length,
        bands: entryBands,
      ),
    );
  }

  // The summary (spec §4.5): the Chunk Index, then Statistics, then the Summary
  // Offset, contiguous and immediately before the Footer. Nothing else may sit
  // inside that run, because the Footer's `summary_start` names its first byte
  // and the CRC covers precisely that range — which is what lets a streamed
  // reader verify the checksum by retaining the trailing records rather than
  // the file.
  int summaryStart = 0;
  int summaryOffsetStart = 0;
  int summaryLength = 0;
  int summaryCrc = 0;
  void emitSummary(Uint8List record) {
    out.bytes(record);
    if (options.writeCrc) {
      summaryCrc = fourdgsCrc32(record, summaryCrc);
    }
  }

  if (options.writeIndex && index.isNotEmpty) {
    summaryStart = out.length;
    final groupStart = summaryStart;
    for (final entry in index) {
      emitSummary(entry.encode());
    }
    // Taken here, before anything else is appended. A Summary Offset frames one
    // *class* of summary record, so that a consumer can range-read the index
    // without the rest of the summary; measuring the group after Statistics has
    // been written declares a range whose tail is a different record class,
    // which is the one thing the record exists to prevent.
    final groupEnd = out.length;
    if (options.writeStatistics) {
      emitSummary(_statisticsRecord(n, index.length, durationSec, encodedAabb));
    }
    if (options.writeSummaryOffsets) {
      summaryOffsetStart = out.length;
      emitSummary(
        _summaryOffsetRecord(opChunkIndex, groupStart, groupEnd - groupStart),
      );
    }
    summaryLength = out.length - summaryStart;
  }

  final crc = options.writeCrc && summaryLength > 0 ? summaryCrc : 0;
  out.bytes(_footerRecord(summaryStart, summaryOffsetStart, crc));
  out.bytes(fourdgsMagic);
}

// --------------------------------------------------------------------------
// Input validation
// --------------------------------------------------------------------------

/// Per-gaussian lanes that land on a grid, so a non-finite value in one either
/// sets a non-finite grid parameter or rounds to a meaningless bin.
void _checkInput(FourdgsGaussianSet g, double cutoff) {
  // Reading the Header's own threshold back is what the decoder does; refusing
  // it here means the encoder cannot write a file whose cutoff its own decoder
  // would reject.
  if (cutoff.isNaN || !cutoff.isFinite || cutoff <= 0.0 || cutoff > 1.0) {
    throw FourdgsInvalidInput(
      'cutoff is $cutoff; authoring input must be finite and in (0, 1]',
    );
  }
  supportK(cutoff);

  final n = g.count;
  _checkLength('positions', g.positions.length, n * 3);
  _checkLength('scales', g.scales.length, n * 3);
  _checkLength('rotations', g.rotations.length, n * 4);
  _checkLength('colors', g.colors.length, n * 4);
  _checkLength('motions', g.motions.length, n * 3);
  // `mu_t` is deliberately absent from this list, and it is the one lane that
  // cannot be checked here: `FourdgsGaussianSet.count` *is* `muT.length`, so it
  // is the ruler the other eight are measured against rather than another lane
  // to measure. A caller who passes a short `mu_t` has described a smaller
  // scene, and every other lane is then too long — which is caught above, by
  // name, on the first one. There is no length it can hold that reaches the
  // quantizer unchecked.
  _checkLength('sigma_t', g.sigmaT.length, n);
  _checkLength('win_lo', g.winLo.length, n);
  _checkLength('win_hi', g.winHi.length, n);
  final sourceGroup = g.sourceGroup;
  if (sourceGroup != null) _checkLength('source_group', sourceGroup.length, n);
  final sourceIndex = g.sourceIndex;
  if (sourceIndex != null) _checkLength('source_index', sourceIndex.length, n);
  final objectId = g.objectId;
  if (objectId != null) _checkLength('object_id', objectId.length, n);
  _checkSh(g, n);
  if (n == 0) return;

  _checkFinite('positions', g.positions, 3);
  _checkFinite('scales', g.scales, 3);
  _checkFinite('rotations', g.rotations, 4);
  _checkFinite('colors', g.colors, 4);
  _checkFinite('motions', g.motions, 3);
  _checkFinite('mu_t', g.muT, 1);

  for (int i = 0; i < n; i++) {
    double largest = 0.0;
    for (int c = 0; c < 4; c++) {
      largest = math.max(largest, g.rotations[i * 4 + c].abs());
    }
    if (largest == 0.0) {
      throw FourdgsInvalidInput(
        'rotation has zero length at gaussian $i; a zero quaternion has no '
        'orientation to encode',
      );
    }
  }

  // These lanes have domains the quantizer cannot repair. Colour is read back
  // through `.clamp(0.0, 1.0)`, so an input of 1.2 returns as 1.0 while the file
  // declares an `rgb` bound near 0.004. Scale is quantized in the log domain,
  // which is defined for every positive Float32 value and for nothing at or
  // below zero. Refusing outside those domains names the lane and gaussian;
  // flooring would quietly store a value nobody authored (AGENTS.md §6).
  for (int i = 0; i < n; i++) {
    for (int c = 0; c < 4; c++) {
      final v = g.colors[i * 4 + c];
      if (v < 0.0 || v > 1.0) {
        throw FourdgsInvalidInput(
          '${c == 3 ? "opacity" : "color"} is $v at gaussian $i; linear rgb and '
          'opacity are stored in [0, 1] and a decoder clamps to it, so a value '
          'outside it comes back changed by far more than this file declares',
        );
      }
    }
    for (int axis = 0; axis < 3; axis++) {
      final scale = g.scales[i * 3 + axis];
      if (scale <= 0.0) {
        throw FourdgsInvalidInput(
          'scale is $scale at gaussian $i; a gaussian extent is quantized in the '
          'log domain against a relative bound, which a value at or below zero '
          'has no meaning in',
        );
      }
    }
  }

  // `sigma_t` is not on the finite list: `+inf` is its documented spelling for a
  // gaussian that never fades (spec §3), and it survives encode and decode as
  // infinity. NaN and `-inf` are refused, because a decoder reads every
  // non-finite sigma as never-fading and a NaN there becomes a
  // deliberate-looking value. A finite negative one is refused for the reason
  // above: it is a standard deviation and would be stored as a positive
  // lifetime nobody wrote.
  // Zero stays legal — it is a gaussian whose support is a single instant, which
  // is a shape the chunk planner has to handle. The encoder uses `1e-30` only
  // as zero's finite logarithmic spelling; every positive Float32 value has a
  // defined logarithm of its own and must retain the declared relative bound.
  for (int i = 0; i < n; i++) {
    final sigma = g.sigmaT[i];
    if (sigma.isNaN || sigma == double.negativeInfinity) {
      throw FourdgsInvalidInput(
        'sigma_t is $sigma at gaussian $i; use +inf for a gaussian that never fades',
      );
    }
    if (sigma < 0.0) {
      throw FourdgsInvalidInput(
        'sigma_t is $sigma at gaussian $i; it is a temporal standard deviation, '
        'so a negative one has no lifetime to encode and would be stored as a '
        'positive one nobody wrote',
      );
    }
  }

  // `win_lo` and `win_hi` are excluded from the finite check on purpose. The
  // validity window goes into the Window Table as `f64` verbatim (spec §5.4),
  // touching no grid at all, so `win_hi = +inf` is how a static asset says it is
  // present at every instant — which is exactly what a glTF import writes. Only
  // NaN is refused, and for a sharper reason than untidiness: a NaN window makes
  // every visibility comparison false, so the gaussian silently never appears.
  for (final name in const <String>['win_lo', 'win_hi']) {
    final values = name == 'win_lo' ? g.winLo : g.winHi;
    for (int i = 0; i < n; i++) {
      if (values[i].isNaN) {
        throw FourdgsInvalidInput(
          '$name is NaN at gaussian $i; a NaN window makes every visibility '
          'comparison false, so the gaussian silently never appears',
        );
      }
    }
  }

  // Ordering, which the NaN check above does not imply. Visibility is gated on
  // `lo <= t < hi`, so an inverted window covers no instant and the gaussian
  // disappears from a file that otherwise looks entirely well-formed. This
  // reader refuses such a window when it reads one back
  // (`FourdgsWindowTable.parse`), so without this check the encoder can hand
  // back a file neither of its own read paths will reopen — the one output a
  // writer must never produce. `lo == hi` stays legal: the empty window is how
  // a static asset's index spells "no extent", and the NoData fixture is
  // exactly that. Equal *infinite* endpoints are refused below: their
  // subtraction is NaN, and the other version-1 SDKs do not yet share Dart's
  // normalization of that empty span when deriving a motion grid.
  for (int i = 0; i < n; i++) {
    if (g.winHi[i] < g.winLo[i]) {
      throw FourdgsInvalidInput(
        'gaussian $i has the validity window [${g.winLo[i]}, ${g.winHi[i]}), '
        'whose lower bound is above its upper; visibility is gated on '
        'lo <= t < hi, so it would cover no instant and this reader refuses '
        'the Window Table record it would be written into',
      );
    }
    if (g.winHi[i] == g.winLo[i] && !g.winLo[i].isFinite) {
      throw FourdgsInvalidInput(
        'gaussian $i has the infinite empty validity window '
        '[${g.winLo[i]}, ${g.winHi[i]}); its length is NaN and the version-1 '
        'decoders do not share one motion-grid interpretation for it',
      );
    }
  }
}

/// The coefficient counts a whole degree has: 3 at degree 1, 8 at 2, 15 at 3.
const List<int> _wholeDegrees = <int>[3, 8, 15];

/// The spherical-harmonic row is whole degrees, and the buffer is the size that
/// row implies.
///
/// Bands are whole and a reader takes them whole (spec §6.5), which cuts both
/// ways: `decodeShBandRecord` refuses a band record that does not carry all of
/// its band's channels, so a row of four coefficients — a whole degree-1 band
/// and two fifths of a degree-2 one — cannot be written as one. Before this
/// check the writer built band 2 out of the single column it had and declared
/// three channels where the band defines fifteen, and the file it returned could
/// not be reopened by either of this package's read paths. A buffer of the wrong
/// size is refused here for the same reason `positions` is: the alternative is a
/// `RangeError` from the gather loop, which names neither the lane nor the
/// gaussian.
void _checkSh(FourdgsGaussianSet g, int n) {
  final sh = g.sh;
  if (sh == null) return;
  if (!_wholeDegrees.contains(g.shCoefficients)) {
    throw FourdgsInvalidInput(
      'sh_coefficients is ${g.shCoefficients}; a spherical-harmonic row is '
      'whole degrees, so it holds $_wholeDegrees coefficients per colour '
      'component and nothing between them',
    );
  }
  final declaredCoefficients = switch (g.shDegree) {
    0 => 0,
    1 => 3,
    2 => 8,
    3 => 15,
    _ => -1,
  };
  if (declaredCoefficients < 0) {
    throw FourdgsInvalidInput(
      'sh_degree is ${g.shDegree}; version 1 defines only degrees 0 through 3',
    );
  }
  if (g.shCoefficients > declaredCoefficients) {
    throw FourdgsInvalidInput(
      'sh_coefficients is ${g.shCoefficients}, deeper than sh_degree '
      '${g.shDegree} can declare ($declaredCoefficients); writing only the '
      'declared bands would silently discard supplied coefficients',
    );
  }
  _checkLength('sh', sh.length, n * 3 * g.shCoefficients);
}

void _checkLength(String name, int got, int want) {
  if (got != want) {
    throw FourdgsInvalidInput(
      '$name holds $got values, expected $want for this gaussian count',
    );
  }
}

void _checkFinite(String name, List<double> values, int width) {
  for (int i = 0; i < values.length; i++) {
    if (!values[i].isFinite) {
      throw FourdgsInvalidInput(
        '$name is ${values[i]} at gaussian ${i ~/ width}; it is quantized onto '
        'a grid, and a non-finite value there violates spec §5.3',
      );
    }
  }
}

// --------------------------------------------------------------------------
// The grid
// --------------------------------------------------------------------------

/// The error bounds a profile declares and the grid pitches they imply.
///
/// Each pitch is exactly twice its bound, in the appropriate domain, so
/// `|decoded - original| <= bound` holds by construction rather than by testing.
class _Grid {
  _Grid({
    required this.origin,
    required this.boundPos,
    required this.boundScaleRel,
    required this.boundRot,
    required this.boundRgb,
    required this.boundTime,
    required this.boundSigmaRel,
    required this.boundSh,
  });

  factory _Grid.forScene(FourdgsGaussianSet g, String profile) {
    final constants = _profiles[profile]!;
    final medianScale = g.count == 0 ? 1e-3 : _median(g.scales);
    final origin = Float64List(3);
    if (g.count > 0) {
      for (int axis = 0; axis < 3; axis++) {
        double lowest = double.infinity;
        for (int i = 0; i < g.count; i++) {
          final v = g.positions[i * 3 + axis];
          if (v < lowest) lowest = v;
        }
        origin[axis] = lowest;
      }
    }
    return _Grid(
      origin: origin,
      boundPos: constants[0] * medianScale,
      boundScaleRel: constants[1],
      boundRot: constants[2],
      boundRgb: constants[3] / 255.0,
      boundTime: constants[4],
      boundSigmaRel: constants[5],
      boundSh: constants[6].toInt(),
    );
  }

  final Float64List origin;
  final double boundPos;
  final double boundScaleRel;
  final double boundRot;
  final double boundRgb;
  final double boundTime;
  final double boundSigmaRel;
  final int boundSh;

  /// The promise on velocity is about displacement, not speed: this is the
  /// velocity bound for a gaussian of the reference lifetime.
  double get boundMotion => boundPos / _lifeRef;

  double get stepPos => 2.0 * boundPos;
  double get stepScaleLog => 2.0 * _log1p(boundScaleRel);
  double get stepRot => 2.0 * boundRot;
  double get stepRgb => 2.0 * boundRgb;
  double get stepAlpha => 2.0 * boundRgb;
  double get stepMotion => 2.0 * boundMotion;
  double get stepTime => 2.0 * boundTime;
  double get stepSigmaLog => 2.0 * _log1p(boundSigmaRel);
  int get stepSh => math.max(1, 2 * boundSh + 1);

  /// The bounds map the file declares, keyed as the specification names them.
  ///
  /// The values are decimal strings, and every reference writer spells them with
  /// its own language's shortest round-trip formatting — Python writes `5e-05`
  /// where Rust writes `5e-5` and Dart writes `0.00005`. Three spellings of one
  /// number: what a consumer reads is the number, and nothing in the format
  /// pins the notation.
  Map<String, String> declaredBounds() => <String, String>{
    'pos': _decimal(boundPos),
    'scale_rel': _decimal(boundScaleRel),
    'rot': _decimal(boundRot),
    'rgb': _decimal(boundRgb),
    'alpha': _decimal(boundRgb),
    'motion': _decimal(boundMotion),
    'time': _decimal(boundTime),
    'sigma_rel': _decimal(boundSigmaRel),
    'sh': '$boundSh',
  };
}

String _decimal(double v) => v.toString();

/// The median of a list, taken the way NumPy takes it: the mean of the two
/// middle values on an even count, in double precision.
double _median(List<double> values) {
  if (values.isEmpty) return 1e-3;
  final sorted = Float64List.fromList(values)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return 0.5 * (sorted[mid - 1] + sorted[mid]);
}

/// `log(1 + x)`, which `dart:math` does not carry.
///
/// The identity is Kahan's: `log(1 + x) = log(u) * x / (u - 1)` where
/// `u = 1 + x`, which cancels the rounding of the sum instead of letting it
/// dominate for small `x`. It reproduces libm's `log1p` bit for bit at the two
/// relative bounds the `fine` and `default` profiles use, and is within one unit
/// in the last place at `coarse`'s.
double _log1p(double x) {
  final u = 1.0 + x;
  if (u == 1.0) return x;
  return math.log(u) * x / (u - 1.0);
}

/// Round half to even, the rule every attribute grid but rotation uses.
double _rint(double v) {
  final nearest = v.roundToDouble();
  if ((v - v.truncateToDouble()).abs() == 0.5 &&
      nearest.remainder(2.0) != 0.0) {
    return nearest - v.sign;
  }
  return nearest;
}

/// [_rint], refused rather than truncated when the bin leaves the symbol domain.
///
/// An attribute stream carries signed 32-bit symbols, so a bin outside that
/// range is unwritable. Saying so here names the attribute and the gaussian; the
/// stream coder, which sees only a symbol width, cannot.
int _bin(double v, String attribute, int gaussian) {
  final rounded = _rint(v);
  if (!(rounded >= -2147483648.0 && rounded <= 2147483647.0)) {
    throw FourdgsInvalidInput(
      '$attribute quantizes to bin $rounded at gaussian $gaussian, outside the '
      'signed 32-bit symbols an attribute stream carries; the error bound is '
      'too tight for this data',
    );
  }
  return rounded.toInt();
}

// --------------------------------------------------------------------------
// The window table
// --------------------------------------------------------------------------

/// Distinct validity windows and a per-gaussian index into them.
///
/// Windows repeat heavily — one per span the scene was fitted over — so the
/// per-gaussian cost is an index rather than two floats.
class _WindowTable {
  _WindowTable(this.windows, this.index);

  factory _WindowTable.of(FourdgsGaussianSet g) {
    final pairs = <List<double>>[
      for (int i = 0; i < g.count; i++) <double>[g.winLo[i], g.winHi[i]],
    ];
    pairs.sort(
      (a, b) => a[0] != b[0] ? a[0].compareTo(b[0]) : a[1].compareTo(b[1]),
    );
    final distinct = <List<double>>[];
    for (final pair in pairs) {
      if (distinct.isEmpty ||
          distinct.last[0] != pair[0] ||
          distinct.last[1] != pair[1]) {
        distinct.add(pair);
      }
    }
    if (distinct.isEmpty) distinct.add(<double>[0.0, 0.0]);

    final index = Int32List(g.count);
    for (int i = 0; i < g.count; i++) {
      index[i] = _rank(distinct, g.winLo[i], g.winHi[i]);
    }
    return _WindowTable(distinct, index);
  }

  final List<List<double>> windows;
  final Int32List index;

  static int _rank(List<List<double>> windows, double lo, double hi) {
    int low = 0;
    int high = windows.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      final w = windows[mid];
      if (w[0] < lo || (w[0] == lo && w[1] < hi)) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

/// The split points the top level of the temporal partition uses.
List<double> _tops(List<List<double>> windows, double durationSec) {
  final seen = <double>{0.0, durationSec};
  for (final window in windows) {
    for (final v in window) {
      if (v > 0.0 && v < durationSec) seen.add(v);
    }
  }
  final tops = seen.toList()..sort();
  if (tops.length < 2) {
    // A zero-length scene still has a start, and a seek at `t = 0` has to land
    // somewhere: an interval of `[0, 0)` covers no instant, so the reference
    // encoders open it by the smallest amount that is still a number.
    return <double>[0.0, math.max(durationSec, 1e-9)];
  }
  return tops;
}

// --------------------------------------------------------------------------
// Quantization
// --------------------------------------------------------------------------

/// One attribute stream's worth of bins, ready to be gathered per chunk.
class _Lane {
  const _Lane(this.attributeId, this.channels, this.values);

  final int attributeId;
  final int channels;
  final Int32List values;
}

class _Quantized {
  const _Quantized(this.lanes);

  final List<_Lane> lanes;
}

/// The three quaternion components that survive when the one at `largest` is
/// dropped, in ascending index order.
const List<List<int>> _rest = <List<int>>[
  <int>[1, 2, 3],
  <int>[0, 2, 3],
  <int>[0, 1, 3],
  <int>[0, 1, 2],
];

_Quantized _quantize(
  FourdgsGaussianSet g,
  List<int> members,
  _Grid grid,
  _WindowTable table,
  double cutoff,
) {
  final n = members.length;
  final pos = Int32List(n * 3);
  final scale = Int32List(n * 3);
  final rotationIndex = Int32List(n);
  final rotation = Int32List(n * 3);
  final rgb = Int32List(n * 3);
  final alpha = Int32List(n);
  final motion = Int32List(n * 3);
  final mu = Int32List(n);
  final sigma = Int32List(n);
  final flags = Int32List(n);
  final windowIndex = Int32List(n);

  final k = supportK(cutoff);
  final stepScaleLog = grid.stepScaleLog;
  final stepSigmaLog = grid.stepSigmaLog;
  final narrowedMotion = Float32List(1);

  for (int row = 0; row < n; row++) {
    final i = members[row];
    for (int axis = 0; axis < 3; axis++) {
      pos[row * 3 + axis] = _bin(
        (g.positions[i * 3 + axis] - grid.origin[axis]) / grid.stepPos,
        'position',
        i,
      );
      // Input validation already proved this Float32 value is finite and
      // strictly positive. Preserve its actual logarithm: flooring a legal
      // sub-1e-30 scale would violate the Header's relative error promise.
      scale[row * 3 + axis] = _bin(
        math.log(g.scales[i * 3 + axis]) / stepScaleLog,
        'scale',
        i,
      );
    }

    _quantizeRotation(g, i, row, grid.stepRot, rotationIndex, rotation);

    // The colour transform stores `(g, r - g, b - g)`. Exact in the integer
    // domain, so it changes the compressed size and never the error bound.
    final r = _bin(g.colors[i * 4] / grid.stepRgb, 'color', i);
    final green = _bin(g.colors[i * 4 + 1] / grid.stepRgb, 'color', i);
    final b = _bin(g.colors[i * 4 + 2] / grid.stepRgb, 'color', i);
    rgb[row * 3] = green;
    rgb[row * 3 + 1] = r - green;
    rgb[row * 3 + 2] = b - green;
    alpha[row] = _bin(g.colors[i * 4 + 3] / grid.stepAlpha, 'opacity', i);

    final neverFades = !g.sigmaT[i].isFinite;
    final sigmaBin =
        neverFades
            ? 0
            : _bin(
              math.log(g.sigmaT[i] == 0.0 ? 1e-30 : g.sigmaT[i]) / stepSigmaLog,
              'sigma_t',
              i,
            );
    sigma[row] = sigmaBin;
    flags[row] = neverFades ? flagNeverFades : 0;

    final w = table.index[i];
    windowIndex[row] = w;
    final window = table.windows[w];

    // Both per-gaussian pitches are recomputed at decode from the sigma bin, so
    // the encoder derives them from the value it is about to write rather than
    // from the sigma it started with. Deriving them from the original is the
    // mistake that produces a file whose velocities nobody wrote.
    final mStep = motionStep(
      lifeClass(
        sigmaBin,
        stepSigmaLog,
        neverFades,
        window[1] - window[0],
        k: k,
      ),
      grid.stepMotion,
    );
    for (int axis = 0; axis < 3; axis++) {
      final bin = _bin(g.motions[i * 3 + axis] / mStep, 'motion', i);
      motion[row * 3 + axis] = bin;
      // `decodeChunk` writes the product into a Float32List. A finite authored
      // velocity can therefore quantize to a perfectly legal i32 bin and still
      // reconstruct as infinity; test the value in the representation the
      // public decoder actually returns.
      narrowedMotion[0] = bin * mStep;
      if (!narrowedMotion[0].isFinite) {
        throw FourdgsInvalidInput(
          'motion bin $bin at gaussian $i axis $axis reconstructs outside the '
          'finite float32 range; the decoded velocity would be '
          '${narrowedMotion[0]}',
        );
      }
    }
    mu[row] = _bin(
      g.muT[i] / muStep(sigmaBin, stepSigmaLog, neverFades, grid.stepTime),
      'mu_t',
      i,
    );
  }

  // The optional identity lanes, written when — and only when — the set
  // carries them. Neither is quantized: they are labels, and §6.6 says so in as
  // many words about `object_id` ("the id is exact and is never dequantized").
  //
  // They are here because dropping them is a decision, not a default. §6.6:
  // "The Object Table, Object Tracks and `object_id` stream are independently
  // optional. A file with ids and no table still groups gaussians … None is a
  // reason to invent or discard another." Before this, decoding a file that
  // carried producer-side stable ids and writing it straight back out returned a
  // file with none, and the identity those fields exist to preserve was gone
  // with nothing said anywhere.
  //
  // `object_id` owns the whole unsigned 32-bit domain while an attribute
  // stream's symbols are signed, so the bridge is the same-bits two's-complement
  // view §6.6 defines: `0xFFFF_FFFF` is written as `-1` and read back as
  // `0xFFFF_FFFF`. Bijective, and not a grid. Delta coding stays available
  // because `_deltaCandidate` computes in 64 bits and drops any candidate that
  // does not fit a 32-bit symbol, which is exactly the condition §6.6 attaches
  // to it; the Python reference disables delta here instead, because in NumPy
  // the same subtraction wraps silently.
  final lanes = <_Lane>[
    _Lane(attrPosition, 3, pos),
    _Lane(attrScale, 3, scale),
    _Lane(attrRotationIndex, 1, rotationIndex),
    _Lane(attrRotation, 3, rotation),
    _Lane(attrColor, 3, rgb),
    _Lane(attrOpacity, 1, alpha),
    _Lane(attrMotion, 3, motion),
    _Lane(attrMuT, 1, mu),
    _Lane(attrSigmaT, 1, sigma),
    _Lane(attrFlags, 1, flags),
    _Lane(attrWindowIndex, 1, windowIndex),
  ];
  final sourceGroup = g.sourceGroup;
  if (sourceGroup != null) {
    lanes.add(
      _Lane(
        attrSourceGroup,
        1,
        Int32List.fromList(<int>[for (final i in members) sourceGroup[i]]),
      ),
    );
  }
  final sourceIndex = g.sourceIndex;
  if (sourceIndex != null) {
    lanes.add(
      _Lane(
        attrSourceIndex,
        1,
        Int32List.fromList(<int>[for (final i in members) sourceIndex[i]]),
      ),
    );
  }
  final objectId = g.objectId;
  if (objectId != null) {
    final codes = Int32List(n);
    for (int row = 0; row < n; row++) {
      codes[row] = objectId[members[row]].toSigned(32);
    }
    lanes.add(_Lane(attrObjectId, 1, codes));
  }
  return _Quantized(lanes);
}

/// Smallest-three: drop the largest-magnitude component and canonicalize the
/// sign so it is positive, which is what lets a decoder recover it as a square
/// root.
///
/// The residuals round half away from zero rather than half to even. That is not
/// an oversight: it is what the reference encoders do here and nowhere else, and
/// a decoder cannot tell which rule produced a bin — but an encoder that used
/// the other one would land a hair off theirs on exact ties.
void _quantizeRotation(
  FourdgsGaussianSet g,
  int gaussian,
  int row,
  double step,
  Int32List largestOut,
  Int32List binsOut,
) {
  final q = <double>[
    g.rotations[gaussian * 4],
    g.rotations[gaussian * 4 + 1],
    g.rotations[gaussian * 4 + 2],
    g.rotations[gaussian * 4 + 3],
  ];
  double scale = 0.0;
  for (final v in q) {
    scale = math.max(scale, v.abs());
  }
  double scaledSquareSum = 0.0;
  for (final v in q) {
    final scaled = v / scale;
    scaledSquareSum += scaled * scaled;
  }
  final norm = scale * math.sqrt(scaledSquareSum);
  for (int c = 0; c < 4; c++) {
    q[c] = q[c] / norm;
  }
  int largest = 0;
  for (int c = 1; c < 4; c++) {
    if (q[c].abs() > q[largest].abs()) largest = c;
  }
  final sign = q[largest] < 0.0 ? -1.0 : 1.0;
  largestOut[row] = largest;
  final rest = _rest[largest];
  for (int c = 0; c < 3; c++) {
    binsOut[row * 3 + c] = _binRotation(q[rest[c]] * sign / step, gaussian);
  }
}

int _binRotation(double v, int gaussian) {
  final rounded = v.roundToDouble();
  if (!(rounded >= -2147483648.0 && rounded <= 2147483647.0)) {
    throw FourdgsInvalidInput(
      'rotation quantizes to bin $rounded at gaussian $gaussian, outside the '
      'signed 32-bit symbols an attribute stream carries',
    );
  }
  return rounded.toInt();
}

// --------------------------------------------------------------------------
// Chunk planning
// --------------------------------------------------------------------------

/// One chunk: its interval, its depth in the temporal tree, and its members.
class _Plan {
  _Plan(this.t0, this.t1, this.level, this.members);

  final double t0;
  final double t1;
  final int level;
  final List<int> members;
}

/// Bounded spatial chunks spanning the whole partitioned timeline.
///
/// Temporal splitting is issue #117, so a seek still reads every one of these
/// overlapping entries. The fixed population cap exists for the sink contract:
/// one record's streams and framing copy are bounded independently of scene
/// size, and each member list is released before the next one is made.
Iterable<_Plan> _planChunks(
  FourdgsGaussianSet g,
  List<double> tops,
  FourdgsWriteOptions options,
) sync* {
  for (int start = 0; start < g.count; start += _maxGaussiansPerChunk) {
    final end = math.min(start + _maxGaussiansPerChunk, g.count);
    final members = <int>[for (int i = start; i < end; i++) i];
    yield _Plan(tops.first, tops.last, 0, _mortonOrder(g, members));
  }
}

/// Reorder a chunk's members for spatial locality, by Morton code over their own
/// bounding box.
///
/// An encoder technique and nothing else: spatial locality is what makes the
/// position delta stream small, no decoder knows which ordering was used, and
/// none may assume one.
List<int> _mortonOrder(FourdgsGaussianSet g, List<int> members) {
  if (members.isEmpty) return members;
  final lo = Float64List(3)..fillRange(0, 3, double.infinity);
  final hi = Float64List(3)..fillRange(0, 3, double.negativeInfinity);
  for (final i in members) {
    for (int axis = 0; axis < 3; axis++) {
      final v = g.positions[i * 3 + axis];
      if (v < lo[axis]) lo[axis] = v;
      if (v > hi[axis]) hi[axis] = v;
    }
  }
  final span = Float64List(3);
  for (int axis = 0; axis < 3; axis++) {
    span[axis] = hi[axis] - lo[axis] <= 0.0 ? 1.0 : hi[axis] - lo[axis];
  }

  const scale = 2097151.0; // (1 << 21) - 1
  final codes = <int, int>{};
  for (final i in members) {
    int code = 0;
    for (int axis = 0; axis < 3; axis++) {
      final t = ((g.positions[i * 3 + axis] - lo[axis]) / span[axis]).clamp(
        0.0,
        1.0,
      );
      code |= _part1by2(_rint(t * scale).toInt()) << axis;
    }
    codes[i] = code;
  }
  final ordered = List<int>.from(members);
  // A stable sort keyed on the code alone, so two gaussians at one point keep
  // the order they arrived in and two runs of this encoder agree.
  ordered.sort(
    (a, b) =>
        codes[a]! != codes[b]!
            ? codes[a]!.compareTo(codes[b]!)
            : a.compareTo(b),
  );
  return ordered;
}

/// Spread the low 21 bits of [x] out to every third bit.
int _part1by2(int x) {
  int v = x & 0x1FFFFF;
  v = (v | (v << 32)) & 0x1F00000000FFFF;
  v = (v | (v << 16)) & 0x1F0000FF0000FF;
  v = (v | (v << 8)) & 0x100F00F00F00F00F;
  v = (v | (v << 4)) & 0x10C30C30C30C30C3;
  v = (v | (v << 2)) & 0x1249249249249249;
  return v;
}

// --------------------------------------------------------------------------
// Spherical harmonics
// --------------------------------------------------------------------------

/// One band's columns within a scene's coefficient row, component-major.
class _BandColumns {
  const _BandColumns(this.band, this.columns);

  final int band;
  final List<int> columns;
}

List<_BandColumns> _bandColumns(FourdgsGaussianSet g, int maxBands) {
  final sh = g.sh;
  if (sh == null || g.shDegree <= 0 || g.shCoefficients <= 0) {
    return const <_BandColumns>[];
  }
  final out = <_BandColumns>[];
  for (int band = 1; band <= math.min(g.shDegree, maxBands); band++) {
    final range = shBandRange[band];
    if (range == null) continue;
    // Whole bands only. A row that stops inside a band carries none of it: the
    // record would declare fewer channels than the band defines and every reader
    // here refuses that. A Header naming a degree its bands do not reach is a
    // legal thing to have decoded — the merge takes bands 1..k and reports the
    // coefficients they hold — so this stops rather than refuses, and the Header
    // below then declares the last band that fit.
    if (range.last > g.shCoefficients) break;
    out.add(
      _BandColumns(band, <int>[
        for (int component = 0; component < 3; component++)
          for (int k = range.first; k < range.last; k++)
            component * g.shCoefficients + k,
      ]),
    );
  }
  return out;
}

/// One SH Band Stream record: a `u8 band`, then the band's coefficients as one
/// attribute stream.
///
/// Each band is its own record so that a reader which has capped its degree
/// skips the higher ones by byte range and never transfers them.
Uint8List _bandRecord(
  FourdgsGaussianSet g,
  _BandColumns band,
  List<int> members,
  FourdgsWriteOptions options,
  int stepSh,
) {
  final sh = g.sh!;
  final row = g.shCoefficients * 3;
  final values = Int32List(members.length * band.columns.length);
  int at = 0;
  for (final i in members) {
    for (final column in band.columns) {
      values[at++] = _coarsenSh(sh[i * row + column], stepSh);
    }
  }
  final payload = _ByteWriter(values.length + 32);
  payload.u8(band.band);
  payload.bytes(
    _encodeStream(opShBandStream, values, band.columns.length, options),
  );
  return _record(opShBandStream, payload.finish());
}

/// One coefficient byte on the pitch the Quantization record declares.
///
/// `step_sh` is an encode-side value (spec §6.5): a decoder does nothing with
/// it, and the stored byte is the coefficient. That is exactly why it has to be
/// applied here — the record declares the pitch the encoder used, so an encoder
/// that declares 3 and writes every byte through has written a number about
/// itself that is not true, and the `coarse` profile's SH allowance buys
/// nothing. `fine` and `default` declare a bound of 0 and a pitch of 1, where
/// this is the identity.
///
/// Rounding is to the bin centre, which is what makes the bound half the pitch
/// rather than the whole of it, and it makes the operation idempotent: a
/// coefficient already on the grid is left where it is. The floor is taken
/// rather than a truncation so a negative code — which a version-1 file cannot
/// hold, since coefficients are `u8`, but a caller can pass — lands on the same
/// grid as a positive one.
///
/// The result is clamped back into a byte, and that is not defensive. The top
/// bin's centre is above the top of the range whenever the pitch does not
/// divide 256: at a pitch of 3, the coefficient 255 centres on 256, which
/// travels through the stream as a 32-bit symbol and arrives at a reader as
/// **zero** — the extreme positive coefficient read as the extreme negative
/// one, in a file that decodes without complaint. Clamping moves the value
/// towards the original, so the declared half-pitch bound is kept a fortiori.
int _coarsenSh(int value, int step) {
  if (step <= 1) return value;
  final floored = (value >= 0 ? value : value - step + 1) ~/ step;
  final centred = floored * step + step ~/ 2;
  return centred < 0 ? 0 : (centred > 255 ? 255 : centred);
}

// --------------------------------------------------------------------------
// Records
// --------------------------------------------------------------------------

Uint8List _header(
  FourdgsGaussianSet g,
  double durationSec,
  FourdgsWriteOptions options,
  int shDegree,
  List<double> aabb,
) {
  final w = _ByteWriter(256);
  w.string(options.sceneProfile);
  w.string(options.library);
  w.f64(durationSec);
  // "Total across all chunks" under `gaussian-birth`, where a file's gaussians
  // are a set and this is that set's size. Under `keyframe-delta` chunks restate
  // the same gaussians, and the field is the number of distinct ids instead
  // (spec §5.1) — which is why this counts the input rather than summing the
  // chunk populations.
  w.u64(g.count);
  w.f64(options.cutoff);
  w.string('gaussian-birth');
  for (final v in aabb) {
    w.f64(v);
  }
  w.u8(shDegree);
  w.u8(0); // flags: this writer emits no audio
  w.strMap(options.attributes);
  return _record(opHeader, w.finish());
}

Uint8List _quantizationRecord(_Grid grid, _WindowTable table) {
  final w = _ByteWriter(384);
  w.string('uniform-v1');
  for (final v in grid.origin) {
    w.f64(v);
  }
  w.f64(grid.stepPos);
  w.f64(grid.stepScaleLog);
  w.f64(grid.stepRot);
  w.f64(grid.stepRgb);
  w.f64(grid.stepAlpha);
  w.f64(grid.stepMotion);
  w.f64(grid.stepTime);
  w.f64(grid.stepSigmaLog);
  w.u8(grid.stepSh);
  w.strMap(grid.declaredBounds());
  return _record(opQuantization, w.finish());
}

Uint8List _windowTableRecord(_WindowTable table) {
  final w = _ByteWriter(16 + 16 * table.windows.length);
  w.u32(table.windows.length);
  for (final window in table.windows) {
    w.f64(window[0]);
    w.f64(window[1]);
  }
  return _record(opWindowTable, w.finish());
}

Uint8List _chunkRecord(
  double t0,
  double t1,
  int level,
  int count,
  Uint8List streams,
) {
  final w = _ByteWriter(streams.length + 64);
  w.f64(t0);
  w.f64(t1);
  w.u32(level);
  w.u32(count);
  w.string(''); // chunk-level compression: the streams carry their own
  w.u64(streams.length);
  w.blob(streams);
  return _record(opChunk, w.finish());
}

Uint8List _statisticsRecord(
  int gaussianCount,
  int chunkCount,
  double durationSec,
  List<double> aabb,
) {
  final w = _ByteWriter(64);
  w.u64(gaussianCount);
  w.u32(chunkCount);
  w.f64(durationSec);
  for (final v in aabb) {
    w.f64(v);
  }
  return _record(opStatistics, w.finish());
}

Uint8List _summaryOffsetRecord(
  int groupOpcode,
  int groupStart,
  int groupLength,
) {
  final w = _ByteWriter(32);
  w.u8(groupOpcode);
  w.u64(groupStart);
  w.u64(groupLength);
  return _record(opSummaryOffset, w.finish());
}

Uint8List _footerRecord(int summaryStart, int summaryOffsetStart, int crc) {
  final w = _ByteWriter(32);
  w.u64(summaryStart);
  w.u64(summaryOffsetStart);
  w.u32(crc);
  return _record(opFooter, w.finish());
}

class _IndexBand {
  const _IndexBand(this.band, this.offset, this.length);

  final int band;
  final int offset;
  final int length;
}

/// One Chunk Index entry.
///
/// Every offset and length written here frames a **whole record**, opcode byte
/// and content length included (spec §5.8), so a reader fetches
/// `[offset, offset + length)` and parses it exactly as it would parse that
/// record mid-stream. The offsets are taken before each record is appended and
/// the lengths are the framed blob's own, which is what makes that true by
/// construction rather than by arithmetic somebody has to keep right.
class _IndexEntry {
  const _IndexEntry({
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
  final List<_IndexBand> bands;

  Uint8List encode() {
    final w = _ByteWriter(48 + 17 * bands.length);
    w.f64(t0);
    w.f64(t1);
    w.u64(chunkOffset);
    w.u64(chunkLength);
    w.u32(gaussianCount);
    w.u32(bands.length);
    for (final band in bands) {
      w.u8(band.band);
      w.u64(band.offset);
      w.u64(band.length);
    }
    return _record(opChunkIndex, w.finish());
  }
}

List<double> _encodedAabb(FourdgsGaussianSet g, _Grid grid) {
  if (g.count == 0) return List<double>.filled(6, 0.0);
  final out = List<double>.filled(6, 0.0);
  final decoded = Float32List(1);
  for (int axis = 0; axis < 3; axis++) {
    double lo = double.infinity;
    double hi = double.negativeInfinity;
    for (int i = 0; i < g.count; i++) {
      // `decodeChunk` lands positions in a Float32List. The bin arithmetic is
      // double, and a negative maximum can round upward when narrowed; recording
      // its pre-narrowing value would then advertise a maximum below the value
      // the decoder actually returns.
      final bin = _bin(
        (g.positions[i * 3 + axis] - grid.origin[axis]) / grid.stepPos,
        'position',
        i,
      );
      decoded[0] = bin * grid.stepPos + grid.origin[axis];
      final v = decoded[0];
      if (!v.isFinite) {
        throw FourdgsInvalidInput(
          'position bin $bin at gaussian $i axis '
          '$axis reconstructs outside the finite float32 range; the decoded '
          'position would be $v',
        );
      }
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    out[axis] = lo;
    out[3 + axis] = hi;
  }
  return out;
}

Uint8List _record(int opcode, Uint8List content) {
  final w = _ByteWriter(content.length + recordHeaderBytes);
  w.u8(opcode);
  w.u64(content.length);
  w.bytes(content);
  return w.finish();
}

// --------------------------------------------------------------------------
// Attribute streams
// --------------------------------------------------------------------------

/// Serialize signed integer bins as one Attribute Stream.
///
/// Raw, delta and constant coding are all tried and the smallest kept, with the
/// choice recorded in the header — a decoder never has to infer which one was
/// used, and the values it reads back are the same whichever won.
Uint8List _encodeStream(
  int attributeId,
  Int32List values,
  int channels,
  FourdgsWriteOptions options,
) {
  final count = channels == 0 ? 0 : values.length ~/ channels;
  if (count == 0) {
    return _streamHeader(
      attributeId,
      1,
      modeRaw,
      options.codec,
      channels,
      0,
      0,
    );
  }

  if (count > 1 && _allRowsEqual(values, channels, count)) {
    final body = _codeSymbols(
      Int32List.sublistView(values, 0, channels),
      options,
      attributeId,
    );
    return _concat(
      _streamHeader(
        attributeId,
        body.width,
        modeConst,
        options.codec,
        channels,
        count,
        body.payload.length,
      ),
      body.payload,
    );
  }

  var best = _codeSymbols(values, options, attributeId);
  var bestMode = modeRaw;
  final deltas = count > 1 ? _deltaCandidate(values, channels) : null;
  if (deltas != null) {
    final candidate = _codeSymbols(deltas, options, attributeId);
    if (candidate.payload.length < best.payload.length) {
      best = candidate;
      bestMode = modeDelta;
    }
  }
  return _concat(
    _streamHeader(
      attributeId,
      best.width,
      bestMode,
      options.codec,
      channels,
      count,
      best.payload.length,
    ),
    best.payload,
  );
}

/// The delta-coded view of [values], or null when it cannot be represented.
///
/// A delta between two bins at opposite ends of the signed 32-bit range needs 33
/// bits, and an attribute stream's symbols are 32. Dart stores that silently
/// truncated, and truncated is the dangerous word: the stream then decodes to a
/// different number, and whether anything notices depends on where the running
/// sum lands. Returning null drops the candidate instead — raw mode is always
/// representable, so a stream that cannot be delta-coded is still written, and
/// written correctly.
Int32List? _deltaCandidate(Int32List values, int channels) {
  final deltas = Int32List(values.length);
  for (int c = 0; c < channels; c++) {
    deltas[c] = values[c];
  }
  for (int i = channels; i < values.length; i++) {
    final delta = values[i] - values[i - channels];
    if (delta < -2147483648 || delta > 2147483647) return null;
    deltas[i] = delta;
  }
  return deltas;
}

bool _allRowsEqual(Int32List values, int channels, int count) {
  for (int i = 1; i < count; i++) {
    for (int c = 0; c < channels; c++) {
      if (values[i * channels + c] != values[c]) return false;
    }
  }
  return true;
}

class _CodedSymbols {
  const _CodedSymbols(this.width, this.payload);

  final int width;
  final Uint8List payload;
}

/// Zigzag, narrow to the smallest symbol width that fits, byte-plane shuffle,
/// compress.
_CodedSymbols _codeSymbols(
  Int32List symbols,
  FourdgsWriteOptions options,
  int attributeId,
) {
  final zig = Float64List(symbols.length);
  double widest = 0;
  for (int i = 0; i < symbols.length; i++) {
    final v = symbols[i];
    final z = v >= 0 ? v * 2.0 : -v * 2.0 - 1.0;
    zig[i] = z;
    if (z > widest) widest = z;
  }
  final int width;
  if (widest <= 0xFF) {
    width = 1;
  } else if (widest <= 0xFFFF) {
    width = 2;
  } else if (widest <= 0xFFFFFFFF) {
    width = 4;
  } else {
    throw FourdgsInvalidInput(
      'attribute $attributeId needs a symbol of $widest, past the 32 bits an '
      'attribute stream carries; the error bound is too tight for this data',
    );
  }

  // Byte-plane shuffle: every symbol's least significant byte, then the next
  // plane, and so on. Grouping the near-constant high bytes together is most of
  // what makes a general-purpose codec effective on quantized attributes.
  final raw = Uint8List(zig.length * width);
  if (width == 1) {
    for (int i = 0; i < zig.length; i++) {
      raw[i] = zig[i].toInt();
    }
  } else {
    double divisor = 1.0;
    for (int plane = 0; plane < width; plane++) {
      final base = plane * zig.length;
      for (int i = 0; i < zig.length; i++) {
        raw[base + i] = ((zig[i] ~/ divisor) % 256).toInt();
      }
      divisor *= 256.0;
    }
  }
  return _CodedSymbols(width, _compress(raw, options));
}

Uint8List _compress(Uint8List raw, FourdgsWriteOptions options) {
  if (options.codec != codecDeflate) {
    throw FourdgsUnsupportedCodec(
      'stream codec ${options.codec} is not available to a pure-Dart build',
    );
  }
  // A zlib frame, not a bare deflate block: the format's deflate carries the
  // RFC 1950 wrapper, and the decoder checks its Adler-32.
  return Uint8List.fromList(
    archive.ZLibEncoder().encodeBytes(raw, level: options.level),
  );
}

Uint8List _streamHeader(
  int attributeId,
  int width,
  int mode,
  int codec,
  int channels,
  int count,
  int payloadLength,
) {
  final w = _ByteWriter(streamHeaderBytes);
  w.u8(attributeId);
  w.u8(width);
  w.u8(mode);
  w.u8(codec);
  w.u8(channels);
  w.u32(count);
  w.u64(payloadLength);
  return w.finish();
}

Uint8List _concat(Uint8List head, Uint8List tail) {
  final out = Uint8List(head.length + tail.length);
  out.setRange(0, head.length, head);
  out.setRange(head.length, out.length, tail);
  return out;
}

// --------------------------------------------------------------------------
// A little-endian byte sink
// --------------------------------------------------------------------------

/// Counts bytes while forwarding each completed record to the caller's sink.
class _SinkWriter {
  _SinkWriter(this._sink);

  final Sink<List<int>> _sink;
  int _length = 0;

  int get length => _length;

  void bytes(Uint8List bytes) {
    _sink.add(bytes);
    _length += bytes.length;
  }
}

/// The deliberately whole-file adapter behind [writeFourdgsBytes].
class _ByteCollector implements Sink<List<int>> {
  final _parts = <Uint8List>[];
  int _length = 0;

  @override
  void add(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _parts.add(bytes);
    _length += bytes.length;
  }

  @override
  void close() {}

  Uint8List finish() {
    final out = Uint8List(_length);
    int at = 0;
    for (final part in _parts) {
      out.setRange(at, at + part.length, part);
      at += part.length;
    }
    return out;
  }
}

class _ByteWriter {
  _ByteWriter([int capacity = 256]) : _buf = Uint8List(math.max(capacity, 16)) {
    _view = ByteData.sublistView(_buf);
  }

  Uint8List _buf;
  late ByteData _view;
  int _length = 0;

  int get length => _length;

  void _ensure(int extra) {
    if (_length + extra <= _buf.length) return;
    int next = _buf.length * 2;
    while (next < _length + extra) {
      next *= 2;
    }
    final grown = Uint8List(next);
    grown.setRange(0, _length, _buf);
    _buf = grown;
    _view = ByteData.sublistView(_buf);
  }

  void u8(int v) {
    _ensure(1);
    _buf[_length++] = v & 0xFF;
  }

  void u32(int v) {
    _ensure(4);
    _view.setUint32(_length, v, Endian.little);
    _length += 4;
  }

  /// A `u64`, written as two `u32`s for the same reason the reader reads it that
  /// way: `ByteData.setUint64` is unsupported when Dart compiles to JavaScript,
  /// so a writer that used it would work in tests and on Wasm and throw in a
  /// JS-compiled build.
  void u64(int v) {
    _ensure(8);
    _view.setUint32(_length, v % 0x100000000, Endian.little);
    _view.setUint32(_length + 4, v ~/ 0x100000000, Endian.little);
    _length += 8;
  }

  void f64(double v) {
    _ensure(8);
    _view.setFloat64(_length, v, Endian.little);
    _length += 8;
  }

  void bytes(Uint8List b) {
    _ensure(b.length);
    _buf.setRange(_length, _length + b.length, b);
    _length += b.length;
  }

  /// `u32` byte length then that many UTF-8 bytes. Not NUL-terminated.
  void string(String s) {
    final encoded = utf8.encode(s);
    u32(encoded.length);
    bytes(encoded);
  }

  /// `u64` byte length then that many bytes.
  void blob(Uint8List b) {
    u64(b.length);
    bytes(b);
  }

  /// `u32` byte length of the whole block, then `string` key / `string` value
  /// pairs filling exactly that block.
  ///
  /// Keys are sorted. A map has no order and a file does, so writing the pairs
  /// in whatever order the caller's map iterates makes two encodes of one scene
  /// differ — which is the difference between a deterministic encoder and one
  /// that merely looks deterministic on the machine it was written on.
  void strMap(Map<String, String> map) {
    final body = _ByteWriter(64);
    for (final key in map.keys.toList()..sort()) {
      body.string(key);
      body.string(map[key]!);
    }
    final bytes = body.finish();
    u32(bytes.length);
    this.bytes(bytes);
  }

  /// A view of everything written from [start] on. Valid until the next write.
  Uint8List viewFrom(int start) => Uint8List.sublistView(_buf, start, _length);

  Uint8List finish() => Uint8List.sublistView(_buf, 0, _length);
}
