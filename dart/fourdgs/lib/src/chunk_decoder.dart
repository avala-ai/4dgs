// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Decoding one chunk's attribute streams into gaussian state.
///
/// Both read paths land here, which is the point: a streamed decode and an
/// indexed decode differ in how they find a chunk's bytes and in nothing else,
/// so they cannot disagree about what those bytes mean.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'exceptions.dart';
import 'opcode.dart';
import 'quantization.dart';
import 'records.dart';
import 'serialization.dart';

/// One chunk's gaussians, on the global scene clock.
class FourdgsDecodedChunk {
  const FourdgsDecodedChunk({
    required this.count,
    required this.positions,
    required this.scales,
    required this.rotations,
    required this.colors,
    required this.motions,
    required this.muT,
    required this.sigmaT,
    required this.winLo,
    required this.winHi,
    required this.windowIndex,
    this.sourceIndex,
    this.objectId,
    this.shBands = const <int, Uint8List>{},
  });

  final int count;
  final Float32List positions; // count * 3
  final Float32List scales; // count * 3, linear
  final Float32List rotations; // count * 4, xyzw
  final Float32List colors; // count * 4, rgba
  final Float32List motions; // count * 3
  final Float32List muT; // count
  final Float32List sigmaT; // count; infinity means "never fades"
  final Float32List winLo; // count
  final Float32List winHi; // count
  final Int32List windowIndex; // count
  final Int32List? sourceIndex;

  /// Object membership (spec section 6.6), or null when the chunk carries
  /// none. `0` is background: a gaussian that belongs to no object.
  final Int32List? objectId;

  /// Band index to that band's raw coefficient bytes, `count * channels` of
  /// them. Empty unless the caller asked for bands and the file had them.
  final Map<int, Uint8List> shBands;
}

/// Decodes a chunk's attribute streams.
///
/// [windows] and [cutoff] are required, not optional, and that is the whole
/// reason this signature looks the way it does. A gaussian's velocity precision
/// is derived from the length of its validity window and from the file's own
/// marginal threshold, so a decoder that guessed either would decode velocities
/// the encoder never wrote — on a minority of gaussians, silently. Making them
/// impossible to omit is the fix; remembering to pass them is not.
FourdgsDecodedChunk decodeChunkStreams(
  Uint8List streams,
  int count,
  FourdgsSteps steps,
  List<double> posOrigin,
  List<FourdgsWindow> windows, {
  required double cutoff,
  String compression = '',
  Map<int, Uint8List> shBandRecords = const <int, Uint8List>{},
}) {
  if (compression.isNotEmpty) {
    // The registry allows a chunk to compress its whole records block, and the
    // reference encoder never does — streams carry their own codec. Reading one
    // that did would interpret compressed bytes as stream headers and decode
    // convincing rubbish, so it is named and refused instead.
    throw FourdgsUnsupportedCodec(
      'chunk-level "$compression" compression is not supported by this decoder',
    );
  }

  // One ceiling for the whole chunk, in BYTES, not one per stream and not on
  // the count. Every stream must carry exactly `count` elements, so `count`
  // sizes all eleven of them, the ten arrays built from them, and every SH band
  // alongside — and a per-stream limit lets a chunk sit just under it eleven
  // times over and still ask for gigabytes.
  //
  // Counting bytes rather than gaussians is what makes the ceiling mean the
  // same thing at every SH degree: a degree-3 gaussian costs more than twice a
  // degree-0 one, so a single count cap is either too loose for the former or
  // too tight for the latter. See [maxChunkDecodedBytes].
  //
  // Checked here, before the stream loop, because this is the last point at
  // which nothing has been allocated: the streams are decompressed and expanded
  // as they are read, so a check afterwards has already paid the bill it was
  // meant to refuse.
  final perGaussian = chunkDecodedBytesPerGaussian(
    shBandRecords.isEmpty ? 0 : shBandRecords.keys.reduce(math.max),
  );
  // Expressed as a division so the multiplication that would overflow is never
  // performed — `count` is attacker-chosen and 64-bit.
  if (count < 0 || count > maxChunkDecodedBytes ~/ perGaussian) {
    throw FourdgsMalformedFile(
      'a chunk declares $count gaussians, which would decode to more than $maxChunkDecodedBytes bytes ($perGaussian per gaussian at this SH degree)',
    );
  }

  // Attribute streams sit in the chunk's records block back to back, each one
  // beginning at its own 17-byte stream header — NOT wrapped in the `opcode +
  // u64 length` record frame that top-level structures use.
  //
  // The specification gives Attribute Stream an opcode (`0x06`) and calls it a
  // record, which reads as though the frame is there; the reference encoder
  // does not write one, and every file in the conformance corpus is framed the
  // way this loop reads it. Where the spec text and the reference disagree the
  // corpus decides, and unwrapping a frame that is not there would fail on
  // every variant in it. Raised upstream.
  //
  // Each header is inspected before its payload is touched. A stream this
  // decoder does not consume is stepped over without being decompressed, and a
  // stream whose declared shape does not match the chunk is refused before
  // anything is allocated for it — validating after decoding would mean having
  // already paid for whatever the header asked for.
  final got = <int, FourdgsAttributeStream>{};
  final cursor = FourdgsCursor(streams);
  while (cursor.remaining > 0) {
    final header = readStreamHeader(cursor);
    final wanted = _channelsFor(header.attributeId);
    if (wanted == null || got.containsKey(header.attributeId)) {
      // Unknown, private, or a duplicate. The registry reserves ids 64-127 for
      // applications and requires readers to skip them; a duplicate is a file
      // that cannot decide what it means, and taking the first is as defensible
      // as taking the last without being silently order-dependent.
      skipStreamPayload(cursor, header);
      continue;
    }
    if (header.count != count) {
      throw FourdgsMalformedFile(
        'attribute ${header.attributeId} declares ${header.count} elements, the chunk declares $count',
      );
    }
    if (header.channels != wanted) {
      throw FourdgsMalformedFile(
        'attribute ${header.attributeId} declares ${header.channels} channels, the registry says $wanted',
      );
    }
    got[header.attributeId] = decodeAttributeStreamBody(cursor, header);
  }

  if (count == 0) {
    return FourdgsDecodedChunk(
      count: 0,
      positions: Float32List(0),
      scales: Float32List(0),
      rotations: Float32List(0),
      colors: Float32List(0),
      motions: Float32List(0),
      muT: Float32List(0),
      sigmaT: Float32List(0),
      winLo: Float32List(0),
      winHi: Float32List(0),
      windowIndex: Int32List(0),
    );
  }

  final missing =
      requiredAttributes.where((int a) => !got.containsKey(a)).toList();
  if (missing.isNotEmpty) {
    throw FourdgsMalformedFile('chunk is missing required attributes $missing');
  }

  // Shapes were checked as the streams were read, so by here every entry has
  // exactly the chunk's element count and its registry channel count.
  FourdgsAttributeStream need(int id) => got[id]!;

  final pos = need(attrPosition);
  final scale = need(attrScale);
  final rotIndex = need(attrRotationIndex);
  final rot = need(attrRotation);
  final color = need(attrColor);
  final opacity = need(attrOpacity);
  final motion = need(attrMotion);
  final mu = need(attrMuT);
  final sigma = need(attrSigmaT);
  final flags = need(attrFlags);
  final window = need(attrWindowIndex);

  final n = count;
  final positions = Float32List(n * 3);
  final scales = Float32List(n * 3);
  final rotations = Float32List(n * 4);
  final colors = Float32List(n * 4);
  final motions = Float32List(n * 3);
  final muT = Float32List(n);
  final sigmaT = Float32List(n);
  final winLo = Float32List(n);
  final winHi = Float32List(n);
  final windowIndex = Int32List(n);

  final ox = posOrigin[0];
  final oy = posOrigin[1];
  final oz = posOrigin[2];
  final rgbOut = List<int>.filled(3, 0);
  final lastWindow = windows.length - 1;
  // Derived once per chunk from the Header's own threshold. A file that declares
  // something other than the default was encoded against that number, so a
  // decoder that assumed 0.05 would put a minority of gaussians in the wrong
  // velocity precision class and halve or double their motion.
  final k = supportK(cutoff);

  for (int i = 0; i < n; i++) {
    final i3 = i * 3;
    final i4 = i * 4;

    positions[i3] = pos.values[i3] * steps.pos + ox;
    positions[i3 + 1] = pos.values[i3 + 1] * steps.pos + oy;
    positions[i3 + 2] = pos.values[i3 + 2] * steps.pos + oz;

    scales[i3] = math.exp(scale.values[i3] * steps.scaleLog);
    scales[i3 + 1] = math.exp(scale.values[i3 + 1] * steps.scaleLog);
    scales[i3 + 2] = math.exp(scale.values[i3 + 2] * steps.scaleLog);

    // Which quaternion component was dropped, and therefore which three the
    // stream carries. Unlike the window index below — advisory geometry, so a
    // bad one is clamped to the nearest window — this is structural: it says
    // how to read the other three values. Outside 0..3 no component is ever
    // restored from `big`, and dequantizeRotation reads the third residual
    // twice, producing a quaternion that normalizes cleanly and is simply
    // wrong. Silently wrong orientations are worse than a refused file.
    final largest = rotIndex.values[i];
    if (largest < 0 || largest > 3) {
      throw FourdgsMalformedFile(
        'gaussian $i names quaternion component $largest as its largest; only 0-3 exist',
      );
    }
    dequantizeRotation(
      largest,
      rot.values[i3],
      rot.values[i3 + 1],
      rot.values[i3 + 2],
      steps.rot,
      rotations,
      i4,
    );

    rctInverse(
      color.values[i3],
      color.values[i3 + 1],
      color.values[i3 + 2],
      rgbOut,
    );
    colors[i4] = (rgbOut[0] * steps.rgb).clamp(0.0, 1.0);
    colors[i4 + 1] = (rgbOut[1] * steps.rgb).clamp(0.0, 1.0);
    colors[i4 + 2] = (rgbOut[2] * steps.rgb).clamp(0.0, 1.0);
    colors[i4 + 3] = (opacity.values[i] * steps.alpha).clamp(0.0, 1.0);

    final neverFades = flags.values[i] & flagNeverFades != 0;
    final sigmaBin = sigma.values[i];
    sigmaT[i] =
        neverFades ? double.infinity : math.exp(sigmaBin * steps.sigmaLog);

    // A window index out of range is clamped rather than fatal, matching the
    // reference: the window table is advisory geometry, and refusing a whole
    // scene over one bad index would be a worse answer than the nearest window.
    final wi = window.values[i];
    windowIndex[i] = wi;
    final safe = lastWindow < 0 ? -1 : wi.clamp(0, lastWindow);
    final lo = safe < 0 ? 0.0 : windows[safe].lo;
    final hi = safe < 0 ? 0.0 : windows[safe].hi;
    winLo[i] = lo;
    winHi[i] = hi;

    // Velocity and birth-time pitches are per-gaussian and recomputed here from
    // the sigma bin just read plus this gaussian's own window length — the two
    // inputs the encoder used. There is no side channel.
    final mStep = motionStep(
      lifeClass(sigmaBin, steps.sigmaLog, neverFades, hi - lo, k: k),
      steps.motion,
    );
    motions[i3] = motion.values[i3] * mStep;
    motions[i3 + 1] = motion.values[i3 + 1] * mStep;
    motions[i3 + 2] = motion.values[i3 + 2] * mStep;

    muT[i] =
        mu.values[i] * muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
  }

  final source = got[attrSourceIndex];
  final objects = got[attrObjectId];
  final shBands = <int, Uint8List>{};
  shBandRecords.forEach((int band, Uint8List content) {
    final decoded = decodeShBandRecord(
      content,
      expectedBand: band,
      expectedCount: count,
    );
    if (decoded != null) shBands[band] = decoded;
  });

  return FourdgsDecodedChunk(
    count: n,
    positions: positions,
    scales: scales,
    rotations: rotations,
    colors: colors,
    motions: motions,
    muT: muT,
    sigmaT: sigmaT,
    winLo: winLo,
    winHi: winHi,
    windowIndex: windowIndex,
    sourceIndex: source == null ? null : Int32List.fromList(source.values),
    objectId: objects == null ? null : Int32List.fromList(objects.values),
    shBands: shBands,
  );
}

/// Channels a registry-defined attribute carries, or `null` for an id this
/// decoder does not consume.
int? _channelsFor(int attributeId) {
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
      return 1;
    default:
      return null;
  }
}

/// The most decoded bytes one chunk may cost, across every array this decoder
/// builds for it.
///
/// Not a format limit — the format has none — but a ceiling on what a single
/// chunk can make this decoder allocate before anything has been validated. It
/// is a byte budget rather than a gaussian count because the cost of a gaussian
/// is not fixed: see [chunkDecodedBytesPerGaussian].
///
/// **Where the number comes from.** The largest chunk in the largest scene
/// measured while this decoder was written — 3,429,566 gaussians over 107
/// chunks, the biggest of them 378,431 — decodes to about 69.6 MB at its SH
/// degree of 0. 512 MiB is ~7.7× that, so a legitimate encoder would have to
/// write a chunk nearly eight times larger than anything observed before this
/// refuses it, while a hostile file is stopped an order of magnitude below the
/// ~2 GB that exhausts a Wasm heap.
///
/// The failure this exists to prevent is cheap to write and expensive to read:
/// eleven constant-mode streams are a few dozen payload bytes each, so a
/// kilobyte-sized file can declare millions of gaussians per chunk and pass
/// every per-stream check on the way to allocating gigabytes.
const int maxChunkDecodedBytes = 512 * 1024 * 1024;

/// Decoded bytes one gaussian costs, for a chunk carrying SH up to [shDegree].
///
/// Counted from what [decodeChunkStreams] actually allocates, at its peak:
///
/// * the attribute-stream bins, `Int32List`s of `count * channels` — 21
///   channels across the eleven required attributes, plus 2 for the optional
///   source-group and source-index streams: 23 × 4 = 92 bytes;
/// * the arrays handed back — 21 `Float32List` lanes (position 3, scale 3,
///   rotation 4, colour 4, motion 3, and one each of mu_t, sigma_t, window lo
///   and window hi) plus two `Int32List` lanes (window index, source index):
///   23 × 4 = 92 bytes;
/// * each SH band twice over: its bins as an `Int32List` and its coefficients
///   as the `Uint8List` handed back, 5 bytes per coefficient. Bands are
///   cumulative — degree 1 is 9 coefficients per gaussian, degree 2 is 24,
///   degree 3 is 45.
///
/// Deliberately an over-estimate on files that carry no optional streams: this
/// is a ceiling, and a ceiling that under-counts is not one.
int chunkDecodedBytesPerGaussian(int shDegree) {
  int shCoefficients = 0;
  for (int band = 1; band <= shDegree; band++) {
    shCoefficients += shBandChannels[band] ?? 0;
  }
  return 92 + 92 + shCoefficients * 5;
}

/// Coefficients per gaussian in each spherical-harmonic band, three channels
/// included: band 1 carries three coefficients per channel, band 2 five, band 3
/// seven.
const Map<int, int> shBandChannels = <int, int>{1: 9, 2: 15, 3: 21};

/// Where each band's coefficients sit within one colour component's row, as
/// `[first, last)`. Band `b` carries `2b + 1` of them, so a whole degree `d`
/// occupies `[0, shBandRange[d]!.last)`.
const Map<int, ({int first, int last})> shBandRange =
    <int, ({int first, int last})>{
      1: (first: 0, last: 3),
      2: (first: 3, last: 8),
      3: (first: 8, last: 15),
    };

/// One scene's coefficients, out of the per-chunk bands each read path gathered.
///
/// Degrees are whole and scene-wide: bands 1..D give exactly a degree-D scene,
/// and a reader never assembles a partial degree out of part of a band. A file
/// carrying band 2 without band 1 is refused rather than padded, because the
/// alternative is rendering the missing band as zeros — wrong, and quietly so.
///
/// The result is component-major: every coefficient of red, then green, then
/// blue, which is how the bands arrive and how [FourdgsGaussianSet.sh] is
/// defined.
({Uint8List values, int coefficients})? mergeChunkBands(
  List<int> counts,
  List<Map<int, Uint8List>> chunkBands,
) {
  final present =
      <int>{for (final bands in chunkBands) ...bands.keys}.toList()..sort();
  if (present.isEmpty) return null;
  for (int i = 0; i < present.length; i++) {
    if (present[i] != i + 1) {
      throw FourdgsMalformedFile(
        'SH bands $present do not form whole degrees starting at band 1',
      );
    }
  }

  final coefficients = shBandRange[present.last]!.last;
  int total = 0;
  for (final count in counts) {
    total += count;
  }
  final out = Uint8List(total * 3 * coefficients);

  int at = 0;
  for (int c = 0; c < counts.length; c++) {
    final count = counts[c];
    final bands = chunkBands[c];
    for (final band in present) {
      final values = bands[band];
      if (values == null) {
        throw FourdgsMalformedFile(
          'a chunk carries SH bands ${bands.keys.toList()..sort()}, the file carries $present',
        );
      }
      final range = shBandRange[band]!;
      final width = range.last - range.first;
      if (values.length != count * 3 * width) {
        throw FourdgsMalformedFile(
          'SH band $band decoded ${values.length} values, expected ${count * 3 * width}',
        );
      }
      for (int i = 0; i < count; i++) {
        final row = (at + i) * 3 * coefficients;
        for (int component = 0; component < 3; component++) {
          final from = (i * 3 + component) * width;
          final to = row + component * coefficients + range.first;
          for (int k = 0; k < width; k++) {
            out[to + k] = values[from + k];
          }
        }
      }
    }
    at += count;
  }
  return (values: out, coefficients: coefficients);
}

/// Decodes one SH Band Stream record's content: a `u8 band` followed by an
/// ordinary attribute stream.
///
/// [expectedBand] and [expectedCount] are what the chunk index promised. Both
/// are checked, because the index is the only thing that said this byte range
/// held band N: point a band-1 range at a band-2 record and the opcode still
/// matches, the bytes still decode, and assembly then strides fifteen
/// coefficients as nine — mixing one gaussian's colour into the next with
/// nothing raised anywhere.
///
/// Coefficients are returned as the bytes the producer stored, undecoded. What
/// those bytes mean is a rendering decision and does not belong to a container.
Uint8List? decodeShBandRecord(
  Uint8List content, {
  required int expectedBand,
  required int expectedCount,
}) {
  final cursor = FourdgsCursor(content);
  final band = cursor.u8();
  if (band != expectedBand) {
    throw FourdgsMalformedFile(
      'the index points band $expectedBand at a record carrying band $band',
    );
  }
  if (cursor.remaining < streamHeaderBytes) {
    // A well-framed band record with no stream in it. Returning null here would
    // present it to the assembler as a band the file simply does not have, and
    // the coefficients would render as zeros — wrong, and quietly so.
    throw FourdgsTruncatedFile('band $band has a record but no stream in it');
  }

  final header = readStreamHeader(cursor);
  final channels = shBandChannels[band];
  if (channels == null) {
    throw FourdgsMalformedFile(
      'band $band is outside the 1-3 this version defines',
    );
  }
  if (header.count != expectedCount) {
    throw FourdgsMalformedFile(
      'band $band carries ${header.count} gaussians, the chunk holds $expectedCount',
    );
  }
  if (header.channels != channels) {
    throw FourdgsMalformedFile(
      'band $band declares ${header.channels} coefficients per gaussian, expected $channels',
    );
  }

  final stream = decodeAttributeStreamBody(cursor, header);
  final out = Uint8List(stream.count * stream.channels);
  for (int i = 0; i < out.length; i++) {
    out[i] = stream.values[i] & 0xFF;
  }
  return out;
}
