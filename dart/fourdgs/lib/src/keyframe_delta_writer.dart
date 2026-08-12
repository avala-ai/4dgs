// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Encoding a `keyframe-delta` file: a sequence of samples in, framed records
/// to a sink or a complete in-memory `.4dgs` byte buffer out.
///
/// The caller supplies a **sequence of samples**: a population, with identities,
/// stated at a sequence of instants. This encoder picks keyframes by cadence,
/// quantizes every sample on one set of grids, and writes each non-keyframe
/// sample as the *difference of bins* against the chunk it references.
///
/// Every sample is quantized on grids derived from the whole sequence, but only
/// when it is about to be written. A delta is then an integer subtraction
/// between two bins on the same grid, the composition telescopes, and the
/// reconstructed bin at any depth is exactly the bin an absolute statement of
/// that instant would have carried. Retaining only the current sample and its
/// reference keeps the encoder's working state bounded by one GOP rather than
/// by the duration of the capture.
///
/// What this encoder does not decide is *what* to update. Which gaussians moved
/// enough to be worth a byte, and how often to spend a keyframe, is rate control
/// — encoder policy, and the place encoders differentiate. This one updates a
/// gaussian when any of its bins changed, which is the simplest rule that is
/// also correct, and is what the Python and Rust references do.
part of 'writer.dart';

/// One population, at one instant, with identity.
///
/// [ids] is aligned with [gaussians] and is what a delta names them by. It is
/// required rather than derived: the whole model rests on correspondence between
/// samples, and a correspondence the encoder invented from row order is one the
/// caller never asserted.
class FourdgsSample {
  const FourdgsSample({
    required this.t0,
    required this.ids,
    required this.gaussians,
  });

  /// The instant this population is stated at. The sample covers `[t0, t0)` of
  /// the next sample, and the last one runs to the scene duration (spec §11.1).
  final double t0;

  final List<int> ids;
  final FourdgsGaussianSet gaussians;
}

/// Cadence, mode, and everything else a `keyframe-delta` file needs.
class FourdgsKeyframeDeltaOptions {
  const FourdgsKeyframeDeltaOptions({
    this.keyframeEvery = 8,
    this.deltaMode = deltaModeChained,
    this.keyframeAt = const <int>{},
    this.profile = 'default',
    this.cutoff = fourdgsDefaultCutoff,
    this.codec = codecDeflate,
    this.level = 6,
    this.library = '4dgs-dart keyframe-delta encoder',
    this.writeIndex = true,
    this.writeStatistics = true,
    this.writeCrc = true,
    this.verify = true,
  });

  /// Samples per group of pictures. `1` writes every sample as a keyframe, which
  /// is legal and is the shape the registry's `frame-sequence` reservation
  /// describes. `0` spends a keyframe only on sample 0 and on [keyframeAt].
  final int keyframeEvery;

  /// [deltaModeChained] references the previous chunk; [deltaModeKeyframe]
  /// references the group's keyframe. Chained is the default because it is
  /// smaller and its chain is contiguous in the file, so a range reader
  /// coalesces it into one request.
  final int deltaMode;

  /// Sample indices to force a keyframe at, beyond the cadence. A producer that
  /// knows where a cut is puts one here so that instant costs two records
  /// however deep into a group it would otherwise have fallen.
  final Set<int> keyframeAt;

  /// The quantization profile: `fine`, `default` or `coarse`. It selects the
  /// error bounds, and through them every grid pitch the file declares — and it
  /// is what the Header's `profile` field carries, which is what both reference
  /// encoders write there for a sequence.
  final String profile;

  final double cutoff;
  final int codec;
  final int level;
  final String library;
  final bool writeIndex;
  final bool writeStatistics;
  final bool writeCrc;

  /// Decode the finished file on both read paths and check every lane against
  /// the bounds it declares before handing it back.
  ///
  /// On by default, for the reason the band verification is: a bound nobody
  /// measured is worse than no bound, because consumers will trust it. What is
  /// checked is what came back out of the file through this package's own
  /// readers — not what the encoder believes it wrote.
  final bool verify;
}

/// Encode [samples] as a complete `keyframe-delta` file.
///
/// The samples must tile the timeline: sample `i` covers `[t_i, t_{i+1})`, the
/// first starts at 0, and the last ends at [durationSec] (spec §11.1). That is
/// the writer's job to satisfy rather than the reader's to tolerate, so a
/// sequence that does not is refused here and named.
Uint8List writeKeyframeDeltaBytes(
  List<FourdgsSample> samples,
  double durationSec, {
  FourdgsKeyframeDeltaOptions options = const FourdgsKeyframeDeltaOptions(),
}) {
  final collector = _ByteCollector();
  _writeKeyframeDeltaToSink(collector, samples, durationSec, options: options);
  final bytes = collector.finish();
  if (options.verify) {
    _kdVerify(bytes, samples, options);
  }
  return bytes;
}

/// Encode [samples] to [sink], one complete framed record at a time.
///
/// The sink is borrowed and is not closed. The writer retains the current
/// quantized sample, its reference, and the small Chunk Index, but releases
/// each framed record after [Sink.add] returns; memory does not grow with the
/// output file. Verification needs to read the completed file back, so this
/// one-way API requires `options.verify` to be false. Use
/// [writeKeyframeDeltaBytes] when read-back verification is wanted.
void writeKeyframeDeltaToSink(
  Sink<List<int>> sink,
  List<FourdgsSample> samples,
  double durationSec, {
  FourdgsKeyframeDeltaOptions options = const FourdgsKeyframeDeltaOptions(
    verify: false,
  ),
}) {
  if (options.verify) {
    throw const FourdgsInvalidInput(
      'writeKeyframeDeltaToSink cannot verify a one-way sink; pass '
      'FourdgsKeyframeDeltaOptions(verify: false), or use '
      'writeKeyframeDeltaBytes for read-back verification',
    );
  }
  _writeKeyframeDeltaToSink(sink, samples, durationSec, options: options);
}

void _writeKeyframeDeltaToSink(
  Sink<List<int>> sink,
  List<FourdgsSample> samples,
  double durationSec, {
  required FourdgsKeyframeDeltaOptions options,
}) {
  if (samples.isEmpty) {
    throw const FourdgsInvalidInput(
      'a keyframe-delta file needs at least one sample; a scene with no '
      'temporal statement is a gaussian-birth file, not an empty sequence',
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
  if (options.level < -1 || options.level > 9) {
    throw FourdgsInvalidInput(
      'deflate level is ${options.level}; the levels are -1 for the codec\'s '
      'own default and 0 to 9 from fastest to smallest',
    );
  }
  if (options.keyframeEvery < 0) {
    throw FourdgsInvalidInput(
      'keyframe_every is ${options.keyframeEvery}; use 0 for no periodic '
      'keyframes, or a positive sample cadence',
    );
  }
  for (final index in options.keyframeAt) {
    if (index < 0 || index >= samples.length) {
      throw FourdgsInvalidInput(
        'keyframe_at contains sample $index, outside this sequence\'s indices '
        '0 through ${samples.length - 1}',
      );
    }
  }
  if (options.deltaMode != deltaModeChained &&
      options.deltaMode != deltaModeKeyframe) {
    throw FourdgsInvalidInput(
      'delta_mode ${options.deltaMode} is not one of the two the format defines: '
      '$deltaModeKeyframe references the group keyframe, $deltaModeChained the '
      'previous chunk',
    );
  }
  if (options.cutoff.isNaN ||
      !options.cutoff.isFinite ||
      options.cutoff <= 0.0 ||
      options.cutoff > 1.0) {
    throw FourdgsInvalidInput(
      'cutoff is ${options.cutoff}; authoring input must be finite and in (0, 1]',
    );
  }
  // Reading the threshold back is what a decoder does, so refusing it here means
  // the encoder cannot write a file whose cutoff its own readers would reject.
  supportK(options.cutoff);
  if (options.writeIndex && samples.length > maxChunkIndexEntries) {
    throw FourdgsInvalidInput(
      'this sequence has ${samples.length} state chunks, past the '
      '$maxChunkIndexEntries entries an indexed reader will open; shorten or '
      'resample it, or use writeIndex: false for a streamed-only file',
    );
  }

  _kdCheckTimeline(samples, durationSec);
  for (int i = 0; i < samples.length; i++) {
    _kdCheckSample(i, samples[i], options.cutoff);
  }
  _kdCheckChainDepth(samples.length, options);
  final distinctIds = _kdCheckLifecycles(samples);

  final grids = _KdGrids.of(samples, durationSec, options.profile);
  final encodedAabb = _kdAabb(samples, grids, options.cutoff);
  _kdPreflightTransitions(samples, grids, options);

  final out = _SinkWriter(sink);
  out.bytes(fourdgsMagic);
  out.bytes(_kdHeader(durationSec, distinctIds, encodedAabb, options));
  out.bytes(_quantizationRecord(grids.grid, const <int, int>{}));
  out.bytes(_windowTableRecord(_WindowTable(grids.windowPairs)));

  final index = <_IndexEntry>[];
  int keyframeOffset = 0;
  int previousOffset = 0;
  int previousDepth = 0;
  _KdSample? previousSample;
  _KdSample? groupKeyframe;

  for (int i = 0; i < samples.length; i++) {
    // Quantized states are the large working set: eleven typed-array columns
    // per gaussian. Keep only the state this sample references (the previous
    // sample or its GOP keyframe), never one copy per sample in the capture.
    final t0 = samples[i].t0;
    final t1 = i + 1 < samples.length ? samples[i + 1].t0 : durationSec;
    final isKeyframe = _kdIsKeyframe(i, options);
    final sample = _kdQuantize(
      i,
      samples[i],
      grids,
      options.cutoff,
      statedAt: t0,
    );

    if (isKeyframe) {
      final blob = _chunkRecord(
        t0,
        t1,
        0,
        sample.ids.length,
        _kdKeyframeStreams(sample, options),
      );
      final at = out.length;
      out.bytes(blob);
      keyframeOffset = at;
      previousOffset = at;
      previousDepth = 0;
      if (options.writeIndex) {
        index.add(
          _IndexEntry(
            t0: t0,
            t1: t1,
            chunkOffset: at,
            chunkLength: blob.length,
            gaussianCount: sample.ids.length,
            bands: const <_IndexBand>[],
            extended: true,
            kind: 0,
            keyframeOffset: at,
            // Stated for a keyframe too: §5.8 defines `live_count` for every
            // extended entry, and this SDK's indexed reader cross-checks it
            // against the chunk. Left at zero it would refuse its own output.
            liveCount: sample.ids.length,
          ),
        );
      }
      groupKeyframe = sample;
      previousSample = sample;
      continue;
    }

    final _KdSample referenceSample;
    final int referenceOffset;
    final int depth;
    if (options.deltaMode == deltaModeKeyframe) {
      referenceSample = groupKeyframe!;
      referenceOffset = keyframeOffset;
      depth = 1;
    } else {
      referenceSample = previousSample!;
      referenceOffset = previousOffset;
      depth = previousDepth + 1;
    }
    // `depth` is a `u16` in both the Delta Chunk and the index entry. A chain
    // longer than that is not a file with a large number in it — it is a file
    // whose declared read cost has wrapped, and whose index then disagrees with
    // the chain a reader walks.
    if (depth > 0xFFFF) {
      throw FourdgsInvalidInput(
        'sample $i sits $depth delta chunks from its keyframe, past the 65535 '
        'a chunk can declare; shorten the group with keyframeEvery or keyframeAt',
      );
    }

    final groups = _kdSplit(referenceSample, sample, i);
    final blob = _kdDeltaChunkRecord(
      t0: t0,
      t1: t1,
      deltaMode: options.deltaMode,
      referenceOffset: referenceOffset,
      keyframeOffset: keyframeOffset,
      depth: depth,
      updates: _kdGroupStreams(groups.updateIds, groups.updateBins, options),
      births: _kdGroupStreams(groups.birthIds, groups.birthBins, options),
      deaths: _kdDeathStreams(groups.deathIds, options),
      updateCount: groups.updateIds.length,
      birthCount: groups.birthIds.length,
      deathCount: groups.deathIds.length,
    );
    final at = out.length;
    out.bytes(blob);
    previousOffset = at;
    previousDepth = depth;
    if (options.writeIndex) {
      index.add(
        _IndexEntry(
          t0: t0,
          t1: t1,
          chunkOffset: at,
          chunkLength: blob.length,
          // Operations, not population: a delta entry's `gaussian_count` is the
          // size of the delta and `live_count` is what it composes to (spec §5.8).
          gaussianCount:
              groups.updateIds.length +
              groups.birthIds.length +
              groups.deathIds.length,
          bands: const <_IndexBand>[],
          extended: true,
          kind: 1,
          deltaMode: options.deltaMode,
          referenceOffset: referenceOffset,
          keyframeOffset: keyframeOffset,
          depth: depth,
          liveCount: sample.ids.length,
        ),
      );
    }
    previousSample = sample;
  }

  // The summary (spec §4.5): the Chunk Index, then Statistics, contiguous and
  // immediately before the Footer, because the Footer's `summary_start` names
  // its first byte and the CRC covers precisely that range.
  int summaryStart = 0;
  int summaryLength = 0;
  int summaryCrc = 0;
  void emitSummary(Uint8List record) {
    out.bytes(record);
    if (options.writeCrc) {
      summaryCrc = fourdgsCrc32(record, summaryCrc);
    }
  }

  if (options.writeIndex) {
    summaryStart = out.length;
    for (final entry in index) {
      emitSummary(entry.encode());
    }
    if (options.writeStatistics) {
      emitSummary(
        _statisticsRecord(distinctIds, index.length, durationSec, encodedAabb),
      );
    }
    summaryLength = out.length - summaryStart;
  }
  final crc = options.writeCrc && summaryLength > 0 ? summaryCrc : 0;
  out.bytes(_footerRecord(summaryStart, 0, crc));
  out.bytes(fourdgsMagic);
}

// --------------------------------------------------------------------------
// The timeline
// --------------------------------------------------------------------------

/// Validate the half-open interval each sample covers without retaining a
/// second list proportional to the capture duration.
///
/// The references derive these the same way and check nothing; this SDK's own
/// readers check all of it — the tiling rule, the interval rule, and a
/// zero-width interval with a population behind it — so a writer that skipped
/// these would emit files it could not read back (spec §11.1, §5.8).
void _kdCheckTimeline(List<FourdgsSample> samples, double duration) {
  if (duration.isNaN || duration < 0.0) {
    throw FourdgsInvalidInput(
      'duration_sec is $duration; expected a value >= 0, or +Infinity for '
      'an open-ended final interval',
    );
  }
  for (int i = 0; i < samples.length; i++) {
    final t0 = samples[i].t0;
    if (t0.isNaN || !t0.isFinite) {
      throw FourdgsInvalidInput(
        'sample $i starts at $t0; a sample instant must be finite, because it '
        'is one end of the interval every seek compares against',
      );
    }
  }
  if (samples.first.t0 != 0.0) {
    throw FourdgsInvalidInput(
      'the first sample starts at ${samples.first.t0}; a keyframe-delta '
      'sequence tiles [0, duration_sec), so it starts at 0 (spec §11.1)',
    );
  }
  for (int i = 0; i < samples.length; i++) {
    final t0 = samples[i].t0;
    final t1 = i + 1 < samples.length ? samples[i + 1].t0 : duration;
    if (t1 < t0) {
      throw FourdgsInvalidInput(
        'sample $i covers [$t0, $t1); sample instants must increase and the '
        'last one must not run past duration_sec',
      );
    }
    if (t1 == t0 && samples[i].gaussians.count != 0) {
      throw FourdgsInvalidInput(
        'sample $i states ${samples[i].gaussians.count} gaussians over the '
        'zero-width interval [$t0, $t1); the half-open seek rule can never '
        'select one, so nothing could ever reach them',
      );
    }
  }
}

bool _kdIsKeyframe(int index, FourdgsKeyframeDeltaOptions options) =>
    index == 0 ||
    options.keyframeAt.contains(index) ||
    (options.keyframeEvery > 0 && index % options.keyframeEvery == 0);

/// Refuse an unrepresentable chained GOP before a caller-owned sink sees bytes.
void _kdCheckChainDepth(int sampleCount, FourdgsKeyframeDeltaOptions options) {
  if (options.deltaMode != deltaModeChained) return;
  var depth = 0;
  for (int i = 0; i < sampleCount; i++) {
    if (_kdIsKeyframe(i, options)) {
      depth = 0;
      continue;
    }
    depth++;
    if (depth > 0xFFFF) {
      throw FourdgsInvalidInput(
        'sample $i sits $depth delta chunks from its keyframe, past the 65535 '
        'a chunk can declare; shorten the group with keyframeEvery or keyframeAt',
      );
    }
  }
}

/// Check every non-keyframe transition before a caller-owned sink sees bytes.
///
/// Quantized samples are retained only as the current, previous, and GOP
/// keyframe populations, so this preflight is constant in sequence length. It
/// proves both the GOP invariants against adjacent states and every signed-i32
/// difference against the state the emitted delta will actually reference.
void _kdPreflightTransitions(
  List<FourdgsSample> samples,
  _KdGrids grids,
  FourdgsKeyframeDeltaOptions options,
) {
  _KdSample? previous;
  _KdSample? groupKeyframe;
  for (int i = 0; i < samples.length; i++) {
    final sample = _kdQuantize(
      i,
      samples[i],
      grids,
      options.cutoff,
      statedAt: samples[i].t0,
    );
    if (_kdIsKeyframe(i, options)) {
      groupKeyframe = sample;
    } else {
      // In keyframe-reference mode a gaussian born after the GOP keyframe is
      // encoded as a birth again, but its continuous lifetime still uses one
      // set of per-gaussian grids. Adjacent states are the authoritative check.
      _kdCheckGopInvariants(previous!, sample, i);
      final reference =
          options.deltaMode == deltaModeKeyframe ? groupKeyframe! : previous;
      // Splitting performs the same checked subtractions as emission. Discard
      // the groups here: this pass proves representability before any sink
      // output, while the emission pass owns the compressed records.
      _kdSplit(reference, sample, i);
    }
    previous = sample;
  }
}

/// Count identities while enforcing the lifetime rule from spec section 11.2.
///
/// A consumer may retain bookkeeping after a death, so a later birth cannot
/// recycle the same integer even across a keyframe. This pass is deliberately
/// over the caller's ids, before any output is framed.
int _kdCheckLifecycles(List<FourdgsSample> samples) {
  var previouslyLive = <int>{};
  var distinctIds = 0;
  for (int i = 0; i < samples.length; i++) {
    final live = samples[i].ids.toSet();
    final introductions = live.difference(previouslyLive);

    // Remember at most the current sample. An identity introduced now may have
    // appeared in any non-adjacent earlier sample, so check those samples again
    // instead of retaining an unbounded scene-wide set of retired identities.
    if (introductions.isNotEmpty) {
      for (int prior = 0; prior + 1 < i; prior++) {
        for (final id in samples[prior].ids) {
          if (introductions.contains(id)) {
            throw FourdgsInvalidInput(
              'sample $i reuses gaussian id $id after its death; section 11.2 '
              'requires an identity to remain retired because consumers may keep '
              'identity-based state after it disappears',
            );
          }
        }
      }
    }
    distinctIds += introductions.length;
    previouslyLive = live;
  }
  return distinctIds;
}

// --------------------------------------------------------------------------
// The shared grids
// --------------------------------------------------------------------------

/// The one set of grids the whole sequence is quantized on.
///
/// The position origin and the scalar pitches come from the sequence as a whole,
/// so a gaussian's bin for an attribute is the same wherever it appears and a
/// difference of bins is meaningful. The velocity and birth-time pitches are
/// per-gaussian and derived from `sigma_t`, `flags` and the validity window
/// (spec §6.3) — all three GOP-invariant (spec §11.5), so a gaussian keeps its
/// grid for its whole life and its motion delta telescopes.
class _KdGrids {
  _KdGrids(this.grid, this.windows)
    : _windowRows = <(double, double), int>{
        for (int i = 0; i < windows.length; i++)
          (windows[i].lo, windows[i].hi): i,
      };

  factory _KdGrids.of(
    List<FourdgsSample> samples,
    double durationSec,
    String profile,
  ) {
    final origin = Float64List(3)..fillRange(0, 3, double.infinity);
    bool any = false;
    for (final sample in samples) {
      final g = sample.gaussians;
      for (int i = 0; i < g.count; i++) {
        any = true;
        for (int axis = 0; axis < 3; axis++) {
          final v = g.positions[i * 3 + axis];
          if (v < origin[axis]) origin[axis] = v;
        }
      }
    }
    if (!any) origin.fillRange(0, 3, 0.0);
    return _KdGrids(
      _Grid.forProfile(profile, _kdMedianScale(samples), origin),
      _kdWindows(samples, durationSec),
    );
  }

  final _Grid grid;

  /// Every validity window the sequence declares, in **first-seen** order.
  ///
  /// `window_index` is written against this list, so a stable order is what
  /// makes the indices mean the same thing on both sides. First-seen rather than
  /// sorted is what both reference encoders do here — and unlike the
  /// `gaussian-birth` writer, which sorts, that order is observable: the table
  /// it produces is the table a reader indexes into.
  final List<FourdgsWindow> windows;
  final Map<(double, double), int> _windowRows;

  List<List<double>> get windowPairs => <List<double>>[
    for (final w in windows) <double>[w.lo, w.hi],
  ];

  /// The row a gaussian's own window occupies.
  ///
  /// Compared with `==`, which folds `-0.0` into `0.0` — the Python reference
  /// does the same through a dict key, where Rust compares bit patterns and
  /// would give the two their own rows. Nothing downstream can tell the
  /// difference: both spell the same instant.
  int indexOf(double lo, double hi) {
    final row = _windowRows[(lo, hi)];
    if (row != null) return row;
    // Unreachable: the table is built from these very pairs.
    throw FourdgsInvalidInput(
      'the validity window [$lo, $hi) is not in the window table',
    );
  }

  double lengthAt(int index) => windows[index].hi - windows[index].lo;
}

/// The exact median scale without retaining one extra value per gaussian.
///
/// Scales are positive finite float32 values after validation, so their native
/// unsigned bit patterns have the same order as their numeric values. Selecting
/// the middle pattern by counting in a 32-step binary search is constant-space;
/// the reference encoder accepts the extra passes to keep memory independent of
/// capture duration.
double _kdMedianScale(List<FourdgsSample> samples) {
  int count = 0;
  for (final sample in samples) {
    count += sample.gaussians.scales.length;
  }
  if (count == 0) return 1e-3;

  double select(int rank) {
    var low = 1; // smallest positive float32 bit pattern
    var high = 0x7F7FFFFF; // largest finite float32 bit pattern
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      int atOrBelow = 0;
      for (final sample in samples) {
        final scales = sample.gaussians.scales;
        final bits = Uint32List.view(
          scales.buffer,
          scales.offsetInBytes,
          scales.length,
        );
        for (final value in bits) {
          if (value <= middle) atOrBelow++;
        }
      }
      if (atOrBelow > rank) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    final bits = Uint32List(1)..[0] = low;
    return Float32List.view(bits.buffer)[0].toDouble();
  }

  final middle = count ~/ 2;
  if (count.isOdd) return select(middle);
  return 0.5 * (select(middle - 1) + select(middle));
}

List<FourdgsWindow> _kdWindows(List<FourdgsSample> samples, double duration) {
  final out = <FourdgsWindow>[];
  final seen = <(double, double)>{};
  for (final sample in samples) {
    final g = sample.gaussians;
    for (int i = 0; i < g.count; i++) {
      final lo = g.winLo[i].toDouble();
      final hi = g.winHi[i].toDouble();
      if (!seen.add((lo, hi))) continue;
      if (out.length == maxWindowsPerScene) {
        throw FourdgsInvalidInput(
          'the samples declare more than $maxWindowsPerScene distinct '
          'validity windows, past the Window Table ceiling this SDK reads',
        );
      }
      out.add(FourdgsWindow(lo, hi));
    }
  }
  if (out.isEmpty) out.add(FourdgsWindow(0.0, duration));
  return out;
}

// --------------------------------------------------------------------------
// Quantization
// --------------------------------------------------------------------------

/// One attribute's bins for a whole sample: [channels] per gaussian, packed
/// `values[row * channels + c]`.
class _KdColumn {
  const _KdColumn(this.channels, this.values);

  final int channels;
  final Int32List values;

  int get rows => channels == 0 ? 0 : values.length ~/ channels;
}

/// One sample, quantized: its identities and a bin column per attribute.
class _KdSample {
  const _KdSample(this.ids, this.bins);

  final Int32List ids;
  final Map<int, _KdColumn> bins;
}

void _kdCheckSample(int index, FourdgsSample sample, double cutoff) {
  final g = sample.gaussians;
  final n = g.count;
  try {
    _checkLength('ids', sample.ids.length, n);
    _checkLength('positions', g.positions.length, n * 3);
    _checkLength('scales', g.scales.length, n * 3);
    _checkLength('rotations', g.rotations.length, n * 4);
    _checkLength('colors', g.colors.length, n * 4);
    _checkLength('motions', g.motions.length, n * 3);
    _checkLength('sigma_t', g.sigmaT.length, n);
    _checkLength('win_lo', g.winLo.length, n);
    _checkLength('win_hi', g.winHi.length, n);
    if (g.sourceGroup != null || g.sourceIndex != null || g.objectId != null) {
      final lanes = <String>[
        if (g.sourceGroup != null) 'source_group',
        if (g.sourceIndex != null) 'source_index',
        if (g.objectId != null) 'object_id',
      ].join(' and ');
      throw FourdgsInvalidInput(
        '$lanes is present, but this keyframe-delta writer does not yet encode '
        'optional identity streams; refusing the sample instead of silently '
        'discarding exact labels',
      );
    }
    if (g.shDegree != 0 || g.shCoefficients != 0 || g.sh != null) {
      throw FourdgsInvalidInput(
        'spherical harmonics are present, but this keyframe-delta writer does '
        'not yet encode GOP-fixed SH band streams; refusing them instead of '
        'silently discarding view-dependent colour',
      );
    }
    if (n != 0) {
      _checkFinite('positions', g.positions, 3);
      _checkFinite('scales', g.scales, 3);
      _checkFinite('rotations', g.rotations, 4);
      _checkFinite('colors', g.colors, 4);
      _checkFinite('motions', g.motions, 3);
      _checkFinite('mu_t', g.muT, 1);
    }
    for (int i = 0; i < n; i++) {
      double largestRotation = 0.0;
      for (int c = 0; c < 4; c++) {
        largestRotation = math.max(
          largestRotation,
          g.rotations[i * 4 + c].abs(),
        );
        final color = g.colors[i * 4 + c];
        if (color < 0.0 || color > 1.0) {
          throw FourdgsInvalidInput(
            '${c == 3 ? "opacity" : "color"} is $color at gaussian $i; '
            'linear rgb and opacity are stored in [0, 1], so clamping it would '
            'change the authored sample beyond the file\'s declared bound',
          );
        }
      }
      if (largestRotation == 0.0) {
        throw FourdgsInvalidInput(
          'rotation has zero length at gaussian $i; a zero quaternion has no '
          'orientation to encode',
        );
      }
      for (int axis = 0; axis < 3; axis++) {
        final scale = g.scales[i * 3 + axis];
        if (scale <= 0.0) {
          throw FourdgsInvalidInput(
            'scale is $scale at gaussian $i; a gaussian extent is quantized '
            'in log space and must be greater than zero',
          );
        }
      }
      final sigma = g.sigmaT[i];
      if (sigma.isNaN || sigma == double.negativeInfinity) {
        throw FourdgsInvalidInput(
          'sigma_t is $sigma at gaussian $i; use +inf for a gaussian that never fades',
        );
      }
      if (sigma < 0.0) {
        throw FourdgsInvalidInput(
          'sigma_t is $sigma at gaussian $i; it is a temporal standard '
          'deviation, so a negative value has no lifetime to encode',
        );
      }
      if (g.winLo[i].isNaN || g.winHi[i].isNaN) {
        throw FourdgsInvalidInput(
          'a validity window bound is NaN at gaussian $i; a NaN window makes '
          'every visibility comparison false, so the gaussian silently never appears',
        );
      }
      if (g.winHi[i] < g.winLo[i]) {
        throw FourdgsInvalidInput(
          'gaussian $i has the validity window [${g.winLo[i]}, ${g.winHi[i]}), '
          'whose lower bound is above its upper; the half-open visibility '
          'interval would cover no instant',
        );
      }
      if (g.winHi[i] == g.winLo[i] && !g.winLo[i].isFinite) {
        throw FourdgsInvalidInput(
          'gaussian $i has the empty validity window '
          '[${g.winLo[i]}, ${g.winHi[i]}), whose infinite endpoints subtract '
          'to NaN; version-1 decoders do not share one motion grid for it',
        );
      }
    }
    // Identity is what a delta names a gaussian by, so a repeated id inside one
    // sample is not a duplicate row — it is two different gaussians claiming one
    // name, and every group built from the sample would be ambiguous.
    final seen = <int>{};
    for (int i = 0; i < n; i++) {
      final id = sample.ids[i];
      if (id < 0 || id > 0xFFFFFFFF) {
        throw FourdgsInvalidInput(
          'gaussian id $id at row $i is outside the unsigned 32-bit identity '
          'domain 0 through 4294967295',
        );
      }
      if (!seen.add(id)) {
        throw FourdgsInvalidInput(
          'gaussian id $id appears twice; ids are unique within a state, and a '
          'delta that named this one could not say which row it meant',
        );
      }
    }
  } on FourdgsInvalidInput catch (error) {
    throw FourdgsInvalidInput('sample $index: ${error.message}');
  }
  // Not inside the try: this one is about the file, not about the sample, and
  // prefixing it with a sample index would point at the wrong thing.
  supportK(cutoff);
}

_KdSample _kdQuantize(
  int index,
  FourdgsSample sample,
  _KdGrids grids,
  double cutoff, {
  required double statedAt,
}) {
  final g = sample.gaussians;
  final n = g.count;
  final grid = grids.grid;
  final k = supportK(cutoff);

  final ids = Int32List(n);
  for (int i = 0; i < n; i++) {
    ids[i] = _kdIdCode(sample.ids[i]);
  }
  final position = Int32List(n * 3);
  final scale = Int32List(n * 3);
  final rotationIndex = Int32List(n);
  final rotation = Int32List(n * 3);
  final color = Int32List(n * 3);
  final opacity = Int32List(n);
  final motion = Int32List(n * 3);
  final mu = Int32List(n);
  final sigma = Int32List(n);
  final flags = Int32List(n);
  final windowIndex = Int32List(n);

  try {
    for (int i = 0; i < n; i++) {
      for (int axis = 0; axis < 3; axis++) {
        scale[i * 3 + axis] = _bin(
          math.log(g.scales[i * 3 + axis]) / grid.stepScaleLog,
          'scale',
          i,
        );
      }

      _quantizeRotation(g, i, i, grid.stepRot, rotationIndex, rotation);

      // The colour transform stores `(g, r - g, b - g)`. Exact in the integer
      // domain, so it changes the compressed size and never the error bound.
      final r = _bin(g.colors[i * 4] / grid.stepRgb, 'color', i);
      final green = _bin(g.colors[i * 4 + 1] / grid.stepRgb, 'color', i);
      final b = _bin(g.colors[i * 4 + 2] / grid.stepRgb, 'color', i);
      color[i * 3] = green;
      color[i * 3 + 1] = r - green;
      color[i * 3 + 2] = b - green;
      opacity[i] = _bin(g.colors[i * 4 + 3] / grid.stepAlpha, 'opacity', i);

      final neverFades = !g.sigmaT[i].isFinite;
      final sigmaBin =
          neverFades
              ? 0
              : _bin(
                math.log(g.sigmaT[i] == 0.0 ? 1e-30 : g.sigmaT[i]) /
                    grid.stepSigmaLog,
                'sigma_t',
                i,
              );
      sigma[i] = sigmaBin;
      flags[i] = neverFades ? flagNeverFades : 0;

      final row = grids.indexOf(g.winLo[i].toDouble(), g.winHi[i].toDouble());
      windowIndex[i] = row;

      // The row's own window, matching the index written beside it: quantizing
      // against window 0 while recording a different index scales the velocity
      // by one grid and reconstructs it with another. Both pitches are derived
      // from the sigma bin about to be written rather than from the sigma the
      // caller passed, because that is what a decoder recomputes them from.
      final mStep = motionStep(
        lifeClass(
          sigmaBin,
          grid.stepSigmaLog,
          neverFades,
          grids.lengthAt(row),
          k: k,
        ),
        grid.stepMotion,
      );
      final motionBins = <int>[
        for (int axis = 0; axis < 3; axis++)
          _bin(g.motions[i * 3 + axis] / mStep, 'motion', i),
      ];
      final timeStep = muStep(
        sigmaBin,
        grid.stepSigmaLog,
        neverFades,
        grid.stepTime,
      );
      final muBin = _bin(statedAt / timeStep, 'mu_t', i);
      mu[i] = muBin;
      final decodedMu = muBin * timeStep;
      for (int axis = 0; axis < 3; axis++) {
        final motionBin = motionBins[axis];
        motion[i * 3 + axis] = motionBin;

        // The caller supplies the centre at `statedAt`, while the position
        // stream stores the rest centre at the serialized (quantized) mu_t.
        // Re-anchor with the motion a decoder will actually reconstruct so
        // evaluating the encoded row at `statedAt` returns the authored centre.
        final restPosition =
            g.positions[i * 3 + axis] -
            motionBin * mStep * (statedAt - decodedMu);
        position[i * 3 + axis] = _bin(
          (restPosition - grid.origin[axis]) / grid.stepPos,
          'position',
          i,
        );
      }
    }
  } on FourdgsInvalidInput catch (error) {
    throw FourdgsInvalidInput('sample $index: ${error.message}');
  }

  return _KdSample(ids, <int, _KdColumn>{
    attrPosition: _KdColumn(3, position),
    attrScale: _KdColumn(3, scale),
    attrRotationIndex: _KdColumn(1, rotationIndex),
    attrRotation: _KdColumn(3, rotation),
    attrColor: _KdColumn(3, color),
    attrOpacity: _KdColumn(1, opacity),
    attrMotion: _KdColumn(3, motion),
    attrMuT: _KdColumn(1, mu),
    attrSigmaT: _KdColumn(1, sigma),
    attrFlags: _KdColumn(1, flags),
    attrWindowIndex: _KdColumn(1, windowIndex),
  });
}

/// Attribute streams carry signed 32-bit symbols, while `gaussian_id` is u32.
/// The format uses the same bits on both sides of that type boundary.
int _kdIdCode(int id) => id <= 0x7FFFFFFF ? id : id - 0x100000000;

int _kdIdValue(int code) => code >= 0 ? code : code + 0x100000000;

// --------------------------------------------------------------------------
// Splitting a sample against its reference
// --------------------------------------------------------------------------

class _KdGroups {
  const _KdGroups({
    required this.updateIds,
    required this.updateBins,
    required this.birthIds,
    required this.birthBins,
    required this.deathIds,
  });

  final Int32List updateIds;
  final Map<int, _KdColumn> updateBins;
  final Int32List birthIds;
  final Map<int, _KdColumn> birthBins;
  final Int32List deathIds;
}

void _kdCheckGopInvariants(
  _KdSample previous,
  _KdSample sample,
  int sampleIndex,
) {
  final previousRowOf = <int, int>{
    for (int i = 0; i < previous.ids.length; i++) previous.ids[i]: i,
  };

  // `sigma_t`, `flags` and `window_index` derive the per-gaussian grids for
  // velocity and birth time. A continuous lifetime may not change them inside
  // a GOP, including when that gaussian was born after the GOP keyframe.
  for (final attribute in keyframeDeltaGopInvariant.toList()..sort()) {
    final before = previous.bins[attribute];
    final after = sample.bins[attribute];
    if (before == null || after == null) continue;
    final ch = after.channels;
    for (int row = 0; row < sample.ids.length; row++) {
      final previousRow = previousRowOf[sample.ids[row]];
      if (previousRow == null) continue;
      for (int c = 0; c < ch; c++) {
        if (before.values[previousRow * ch + c] != after.values[row * ch + c]) {
          throw FourdgsInvalidInput(
            'sample $sampleIndex: gaussian id ${_kdIdValue(sample.ids[row])} '
            'changes attribute $attribute, which is fixed for a gaussian\'s '
            'continuous lifetime within a group: the per-gaussian grids for '
            'velocity and birth time are derived from it. Emit a keyframe, or '
            'a death and a birth.',
          );
        }
      }
    }
  }
}

/// One sample against its reference, as updates, births and deaths.
_KdGroups _kdSplit(_KdSample reference, _KdSample sample, int sampleIndex) {
  final rowOf = <int, int>{
    for (int i = 0; i < reference.ids.length; i++) reference.ids[i]: i,
  };

  final commonRows = <int>[];
  final referenceRows = <int>[];
  final birthRows = <int>[];
  for (int i = 0; i < sample.ids.length; i++) {
    final row = rowOf[sample.ids[i]];
    if (row == null) {
      birthRows.add(i);
    } else {
      commonRows.add(i);
      referenceRows.add(row);
    }
  }
  final live = <int>{for (final id in sample.ids) id};
  // Ascending, which is what `np.setdiff1d` gives the Python reference; Rust
  // keeps reference order. A group is a set either way, so the two files decode
  // identically — sorted simply delta-codes better.
  final deaths = <int>[
    for (final id in reference.ids)
      if (!live.contains(id)) id,
  ]..sort();

  // A gaussian is updated when any of its bins moved. Untouched means no bytes,
  // which is the property the whole model exists to buy.
  final changed = List<bool>.filled(commonRows.length, false);
  final referenceMu = reference.bins[attrMuT]!;
  final sampleMu = sample.bins[attrMuT]!;
  final referenceMotion = reference.bins[attrMotion]!;
  for (int k = 0; k < commonRows.length; k++) {
    final referenceRow = referenceRows[k];
    final sampleRow = commonRows[k];
    if (referenceMu.values[referenceRow] == sampleMu.values[sampleRow]) {
      continue;
    }
    // Positions in a sample are stated at that sample's t0. If a serialized
    // reference has nonzero motion and an older anchor, inheriting it advances
    // the old position instead of preserving the position this sample states.
    // Restate the row even when its raw position and motion bins are identical.
    for (int axis = 0; axis < 3; axis++) {
      if (referenceMotion.values[referenceRow * 3 + axis] != 0) {
        changed[k] = true;
        break;
      }
    }
  }
  for (final entry in sample.bins.entries) {
    // mu_t is restated when another lane causes this gaussian to be stated by
    // the delta. Its timestamp alone must not turn an otherwise untouched
    // gaussian into an update.
    if (keyframeDeltaGopInvariant.contains(entry.key) || entry.key == attrMuT) {
      continue;
    }
    final before = reference.bins[entry.key];
    if (before == null) continue;
    final ch = entry.value.channels;
    for (int k = 0; k < commonRows.length; k++) {
      for (int c = 0; c < ch; c++) {
        if (entry.value.values[commonRows[k] * ch + c] !=
            before.values[referenceRows[k] * ch + c]) {
          changed[k] = true;
          break;
        }
      }
    }
  }
  final touched = <int>[
    for (int k = 0; k < commonRows.length; k++)
      if (changed[k]) k,
  ];

  final updateIds = Int32List(touched.length);
  for (int j = 0; j < touched.length; j++) {
    updateIds[j] = sample.ids[commonRows[touched[j]]];
  }
  final updateBins = <int, _KdColumn>{};
  for (final entry in sample.bins.entries) {
    if (keyframeDeltaGopInvariant.contains(entry.key)) continue;
    final before = reference.bins[entry.key];
    if (before == null) continue;
    final ch = entry.value.channels;
    final absolute = keyframeDeltaAbsoluteInUpdate.contains(entry.key);
    final values = Int32List(touched.length * ch);
    for (int j = 0; j < touched.length; j++) {
      final row = commonRows[touched[j]];
      for (int c = 0; c < ch; c++) {
        // Rotation is restated outright: the smallest-three basis changes
        // whenever the largest quaternion component does, so the three stored
        // bins mean different components either side of it and a difference
        // would be nonsense (spec §11.5).
        values[j * ch + c] =
            absolute
                ? entry.value.values[row * ch + c]
                : _kdDifference(
                  entry.value.values[row * ch + c],
                  before.values[referenceRows[touched[j]] * ch + c],
                  sampleIndex: sampleIndex,
                  gaussianId: _kdIdValue(sample.ids[row]),
                  attribute: entry.key,
                  component: c,
                );
      }
    }
    updateBins[entry.key] = _KdColumn(ch, values);
  }

  final birthIds = Int32List(birthRows.length);
  for (int j = 0; j < birthRows.length; j++) {
    birthIds[j] = sample.ids[birthRows[j]];
  }
  // A birth is absolute state, not a delta, so it carries every attribute —
  // including the three an update may never touch.
  final birthBins = <int, _KdColumn>{
    for (final entry in sample.bins.entries)
      entry.key: _kdGather(entry.value, birthRows),
  };

  return _KdGroups(
    updateIds: updateIds,
    updateBins: updateBins,
    birthIds: birthIds,
    birthBins: birthBins,
    deathIds: Int32List.fromList(deaths),
  );
}

const Map<int, String> _kdAttributeNames = <int, String>{
  attrPosition: 'position',
  attrScale: 'scale',
  attrRotationIndex: 'rotation_index',
  attrRotation: 'rotation',
  attrColor: 'color',
  attrOpacity: 'opacity',
  attrMotion: 'motion',
  attrMuT: 'mu_t',
  attrSigmaT: 'sigma_t',
  attrFlags: 'flags',
  attrWindowIndex: 'window_index',
};

/// Subtract two valid symbols before narrowing the result back to int32.
int _kdDifference(
  int after,
  int before, {
  required int sampleIndex,
  required int gaussianId,
  required int attribute,
  required int component,
}) {
  final difference = after - before;
  if (difference < keyframeDeltaBinMin || difference > keyframeDeltaBinMax) {
    final name = _kdAttributeNames[attribute] ?? 'attribute $attribute';
    throw FourdgsInvalidInput(
      'sample $sampleIndex: gaussian id $gaussianId $name component '
      '$component changes from bin $before to $after; delta $difference is '
      'outside the signed 32-bit symbols an attribute stream carries. Force '
      'this sample into keyframeAt instead of encoding the subtraction.',
    );
  }
  return difference;
}

_KdColumn _kdGather(_KdColumn column, List<int> rows) {
  final ch = column.channels;
  final out = Int32List(rows.length * ch);
  for (int j = 0; j < rows.length; j++) {
    for (int c = 0; c < ch; c++) {
      out[j * ch + c] = column.values[rows[j] * ch + c];
    }
  }
  return _KdColumn(ch, out);
}

// --------------------------------------------------------------------------
// Records
// --------------------------------------------------------------------------

/// A keyframe chunk's streams: the ids it names, then all eleven required
/// attributes, in registry order.
Uint8List _kdKeyframeStreams(
  _KdSample sample,
  FourdgsKeyframeDeltaOptions options,
) {
  final out = _ByteWriter(4096);
  out.bytes(
    _encodeStream(attrGaussianId, sample.ids, 1, options.codec, options.level),
  );
  for (final attribute in requiredAttributes) {
    final column = sample.bins[attribute]!;
    out.bytes(
      _encodeStream(
        attribute,
        column.values,
        column.channels,
        options.codec,
        options.level,
      ),
    );
  }
  return out.finish();
}

/// One group's streams: the ids it names, then the attributes it carries, by
/// ascending attribute id.
///
/// An empty group is zero bytes rather than a header with no rows: that is what
/// the references write, and it is what lets a reader tell "nothing was born
/// here" from "something was, with no attributes".
Uint8List _kdGroupStreams(
  Int32List ids,
  Map<int, _KdColumn> bins,
  FourdgsKeyframeDeltaOptions options,
) {
  if (ids.isEmpty) return Uint8List(0);
  final out = _ByteWriter(1024);
  out.bytes(
    _encodeStream(attrGaussianId, ids, 1, options.codec, options.level),
  );
  for (final attribute in bins.keys.toList()..sort()) {
    final column = bins[attribute]!;
    out.bytes(
      _encodeStream(
        attribute,
        column.values,
        column.channels,
        options.codec,
        options.level,
      ),
    );
  }
  return out.finish();
}

Uint8List _kdDeathStreams(Int32List ids, FourdgsKeyframeDeltaOptions options) {
  if (ids.isEmpty) return Uint8List(0);
  return _encodeStream(attrGaussianId, ids, 1, options.codec, options.level);
}

Uint8List _kdDeltaChunkRecord({
  required double t0,
  required double t1,
  required int deltaMode,
  required int referenceOffset,
  required int keyframeOffset,
  required int depth,
  required Uint8List updates,
  required Uint8List births,
  required Uint8List deaths,
  required int updateCount,
  required int birthCount,
  required int deathCount,
}) {
  // The three groups are framed by length inside one blob rather than tagged
  // with a group byte on every stream, so the death list — small, and often
  // wanted alone — is reachable by stepping over two lengths.
  final groups = _ByteWriter(
    updates.length + births.length + deaths.length + 32,
  );
  groups.blob(updates);
  groups.blob(births);
  groups.blob(deaths);
  final records = groups.finish();

  final w = _ByteWriter(records.length + 96);
  w.f64(t0);
  w.f64(t1);
  w.u32(0); // level: a sequence has no hierarchy
  w.u8(deltaMode);
  w.u64(referenceOffset);
  w.u64(keyframeOffset);
  w.u16(depth);
  w.u32(updateCount);
  w.u32(birthCount);
  w.u32(deathCount);
  w.string(''); // chunk-level compression: the streams carry their own
  w.u64(records.length);
  w.blob(records);
  return _record(opDeltaChunk, w.finish());
}

Uint8List _kdHeader(
  double durationSec,
  int distinctIds,
  List<double> encodedAabb,
  FourdgsKeyframeDeltaOptions options,
) {
  final w = _ByteWriter(256);
  // The quantization profile, which is what both reference encoders put here for
  // a sequence. A `gaussian-birth` file carries a scene profile in this field
  // instead; nothing in the format pins which vocabulary a producer uses.
  w.string(options.profile);
  w.string(options.library);
  w.f64(durationSec);
  // Distinct ids, not a sum over chunks. Under `gaussian-birth` a file's
  // gaussians are a set and every chunk holds a disjoint part of it; under
  // `keyframe-delta` the chunks restate the same gaussians, so summing them
  // would count one gaussian once per sample it appears in (spec §5.1).
  w.u64(distinctIds);
  w.f64(options.cutoff);
  w.string('keyframe-delta');
  for (final v in encodedAabb) {
    w.f64(v);
  }
  w.u8(0); // sh_degree: SH-bearing input is refused above
  w.u8(0); // flags: this writer emits no audio
  w.strMap(const <String, String>{});
  return _record(opHeader, w.finish());
}

List<double> _kdAabb(
  List<FourdgsSample> samples,
  _KdGrids grids,
  double cutoff,
) {
  final out = List<double>.filled(6, 0.0);
  final lo = Float64List(3)..fillRange(0, 3, double.infinity);
  final hi = Float64List(3)..fillRange(0, 3, double.negativeInfinity);
  bool any = false;
  for (int sampleIndex = 0; sampleIndex < samples.length; sampleIndex++) {
    final sample = samples[sampleIndex];
    // Quantize one sample at a time and derive the bounds from the exact bins
    // that will be serialized, including position re-anchoring at quantized
    // mu_t. The temporary state is released before the next sample.
    final quantized = _kdQuantize(
      sampleIndex,
      sample,
      grids,
      cutoff,
      statedAt: sample.t0,
    );
    final positions = quantized.bins[attrPosition]!.values;
    for (int i = 0; i < quantized.ids.length; i++) {
      any = true;
      for (int axis = 0; axis < 3; axis++) {
        // Keyframe-delta composition retains the grid arithmetic in f64, so
        // bound that reconstructed value rather than the unquantized source.
        final v =
            positions[i * 3 + axis] * grids.grid.stepPos +
            grids.grid.origin[axis];
        if (v < lo[axis]) lo[axis] = v;
        if (v > hi[axis]) hi[axis] = v;
      }
    }
  }
  if (!any) return out;
  for (int axis = 0; axis < 3; axis++) {
    out[axis] = lo[axis];
    out[3 + axis] = hi[axis];
  }
  return out;
}

// --------------------------------------------------------------------------
// Verification
// --------------------------------------------------------------------------

/// The bytes just written, read back on both paths and checked lane by lane.
///
/// Two encoders agreeing proves they share an opinion; it does not prove either
/// preserved the scene (issue #189). So this compares what came out of the file
/// against what went into it, attribute by attribute, against the bounds the
/// file itself declares — position against `pos`, scale against `scale_rel` in
/// the log domain, velocity against the per-gaussian pitch the decoder
/// recomputes, and so on. A fault anywhere between the caller's arrays and the
/// composed bins lands here rather than in a consumer's renderer.
void _kdVerify(
  Uint8List bytes,
  List<FourdgsSample> samples,
  FourdgsKeyframeDeltaOptions options,
) {
  final streamed = decodeKeyframeDeltaStreamed(bytes);
  if (streamed.chunks.length != samples.length) {
    throw FourdgsInvalidInput(
      'encoder verification failed: the file holds ${streamed.chunks.length} '
      'state chunks for ${samples.length} samples',
    );
  }
  final streamedByOffset = <int, KeyframeDeltaChunk>{
    for (final chunk in streamed.chunks) chunk.offset: chunk,
  };
  for (int i = 0; i < samples.length; i++) {
    _kdVerifySample(
      i,
      samples[i],
      streamed,
      streamed.chunks[i],
      streamedByOffset,
    );
  }

  // The indexed path, because the two fail differently: the streamed path never
  // reads the index, so a wrong offset, a wrong `live_count` or a broken chain
  // decodes perfectly there and only the seeking client notices.
  if (!options.writeIndex) return;
  final indexed = decodeKeyframeDeltaIndexed(bytes);
  if (indexed.sequence.chunks.length != samples.length) {
    throw FourdgsInvalidInput(
      'encoder verification failed: the index names '
      '${indexed.sequence.chunks.length} chunks for ${samples.length} samples',
    );
  }
  final indexedByOffset = <int, KeyframeDeltaChunk>{
    for (final chunk in indexed.sequence.chunks) chunk.offset: chunk,
  };
  for (int i = 0; i < samples.length; i++) {
    _kdVerifySample(
      i,
      samples[i],
      indexed.sequence,
      indexed.sequence.chunks[i],
      indexedByOffset,
    );
  }
}

void _kdVerifySample(
  int index,
  FourdgsSample sample,
  KeyframeDeltaSequence sequence,
  KeyframeDeltaChunk chunk,
  Map<int, KeyframeDeltaChunk> chunkByOffset,
) {
  final population = keyframeDeltaPopulation(sequence, chunk);
  KeyframeDeltaPopulation? referencePopulation;
  Map<int, int> referenceRowOf = const <int, int>{};
  if (chunk.kind == 1) {
    final reference = chunkByOffset[chunk.referenceOffset];
    if (reference == null) {
      throw FourdgsInvalidInput(
        'encoder verification failed: sample $index at byte ${chunk.offset} '
        'references missing chunk byte ${chunk.referenceOffset}',
      );
    }
    referencePopulation = keyframeDeltaPopulation(sequence, reference);
    referenceRowOf = <int, int>{
      for (int i = 0; i < referencePopulation.count; i++)
        referencePopulation.ids[i]: i,
    };
  }
  final g = sample.gaussians;
  if (population.count != g.count) {
    throw FourdgsInvalidInput(
      'encoder verification failed: sample $index composes to '
      '${population.count} gaussians, ${g.count} went in',
    );
  }
  final rowOf = <int, int>{
    for (int i = 0; i < population.count; i++) population.ids[i]: i,
  };

  final steps = FourdgsSteps.of(sequence.quantization);
  final bounds = sequence.quantization.bounds;
  final boundPos = _kdBound(bounds, 'pos', 0.5 * steps.pos);
  final boundRgb = _kdBound(bounds, 'rgb', 0.5 * steps.rgb);
  final boundAlpha = _kdBound(bounds, 'alpha', 0.5 * steps.alpha);
  final boundRot = _kdBound(bounds, 'rot', 0.5 * steps.rot);
  final boundScaleLog = 0.5 * steps.scaleLog;
  final boundSigmaLog = 0.5 * steps.sigmaLog;
  final k = supportK(sequence.header.cutoff);

  void near(String lane, int id, double got, double want, double bound) {
    // The slack absorbs the float arithmetic on both sides of the grid, not any
    // part of the bound: it is relative to the magnitudes involved and is twelve
    // orders below the coarsest profile's tightest bound.
    final slack = 1e-9 * math.max(1.0, math.max(got.abs(), want.abs()));
    if (!((got - want).abs() <= bound + slack)) {
      throw FourdgsInvalidInput(
        'encoder verification failed: sample $index, gaussian id $id, $lane '
        'came back $got for $want — off by ${(got - want).abs()}, and the file '
        'declares a bound of $bound',
      );
    }
  }

  for (int i = 0; i < g.count; i++) {
    final id = sample.ids[i];
    final row = rowOf[id];
    if (row == null) {
      throw FourdgsInvalidInput(
        'encoder verification failed: sample $index composes to a population '
        'without gaussian id $id',
      );
    }

    for (int axis = 0; axis < 3; axis++) {
      near(
        'position[$axis]',
        id,
        population.positions[row * 3 + axis] +
            population.motions[row * 3 + axis] *
                (sample.t0 - population.muT[row]),
        g.positions[i * 3 + axis].toDouble(),
        boundPos,
      );
      // Scale's bound is relative, so it is a bound in the log domain — which is
      // the domain the grid is in.
      near(
        'log scale[$axis]',
        id,
        math.log(population.scales[row * 3 + axis]),
        math.log(g.scales[i * 3 + axis]),
        boundScaleLog,
      );
    }

    // Velocity and birth time ride pitches the decoder recomputes per gaussian
    // from the sigma bin, so the bound to check against is that pitch's half,
    // not the reference-lifetime bound the Quantization record states.
    final sigma = population.sigmaT[row];
    final neverFades = !sigma.isFinite;
    final int sigmaBin =
        neverFades ? 0 : (math.log(sigma) / steps.sigmaLog).round();
    final mStep = motionStep(
      lifeClass(
        sigmaBin,
        steps.sigmaLog,
        neverFades,
        sequence.windows.isEmpty
            ? 0.0
            : sequence.windows[population.windowIndex[row]].length,
        k: k,
      ),
      steps.motion,
    );
    final tStep = muStep(sigmaBin, steps.sigmaLog, neverFades, steps.time);
    for (int axis = 0; axis < 3; axis++) {
      near(
        'motion[$axis]',
        id,
        population.motions[row * 3 + axis],
        g.motions[i * 3 + axis].toDouble(),
        0.5 * mStep,
      );
    }
    final referenceRow = referenceRowOf[id];
    if (referencePopulation == null || referenceRow == null) {
      // Every keyframe row and delta birth is stated at this sample's time.
      near('mu_t', id, population.muT[row], sample.t0, 0.5 * tStep);
    } else {
      // An update restates mu_t at this sample's time; an untouched gaussian
      // inherits its reference state. Accept exactly those two outcomes rather
      // than the caller's authored mu_t, which §11.3 does not preserve.
      final got = population.muT[row];
      final inherited = referencePopulation.muT[referenceRow];
      final slack = 1e-9 * math.max(1.0, got.abs());
      if ((got - sample.t0).abs() > 0.5 * tStep + slack && got != inherited) {
        throw FourdgsInvalidInput(
          'encoder verification failed: sample $index, gaussian id $id, mu_t '
          'came back $got; a delta row must state ${sample.t0}, or inherit '
          '$inherited when the gaussian is untouched',
        );
      }
    }

    if (neverFades != !g.sigmaT[i].isFinite) {
      throw FourdgsInvalidInput(
        'encoder verification failed: sample $index, gaussian id $id came back '
        'with sigma_t $sigma for ${g.sigmaT[i]}',
      );
    }
    if (!neverFades) {
      near(
        'log sigma_t',
        id,
        math.log(sigma),
        math.log(g.sigmaT[i] == 0.0 ? 1e-30 : g.sigmaT[i]),
        boundSigmaLog,
      );
    }

    for (int c = 0; c < 3; c++) {
      near(
        'color[$c]',
        id,
        population.colors[row * 4 + c],
        g.colors[i * 4 + c].toDouble(),
        boundRgb,
      );
    }
    near(
      'opacity',
      id,
      population.colors[row * 4 + 3],
      g.colors[i * 4 + 3].toDouble(),
      boundAlpha,
    );

    // The rotation bound is stated per stored component, and three of them are
    // folded back into a fourth by a square root. The largest component of a
    // unit quaternion is at least 1/2 and the other three are no larger, so a
    // per-component error of `b` moves the recovered one by at most `3b` and the
    // whole vector by at most `sqrt(12) b` — which puts the two unit
    // quaternions' dot product within `6 b^2` of one.
    double norm = 0.0;
    for (int c = 0; c < 4; c++) {
      norm += g.rotations[i * 4 + c] * g.rotations[i * 4 + c];
    }
    if (norm > 0.0) {
      norm = math.sqrt(norm);
      double dot = 0.0;
      for (int c = 0; c < 4; c++) {
        dot +=
            population.rotations[row * 4 + c] * g.rotations[i * 4 + c] / norm;
      }
      final apart = 1.0 - dot.abs();
      if (!(apart <= 6.0 * boundRot * boundRot + 1e-12)) {
        throw FourdgsInvalidInput(
          'encoder verification failed: sample $index, gaussian id $id came '
          'back with a rotation $apart from the one that went in, and the file '
          'declares a per-component bound of $boundRot',
        );
      }
    }

    final window = sequence.windows[population.windowIndex[row]];
    if (window.lo != g.winLo[i] || window.hi != g.winHi[i]) {
      throw FourdgsInvalidInput(
        'encoder verification failed: sample $index, gaussian id $id came back '
        'in the window [${window.lo}, ${window.hi}) for '
        '[${g.winLo[i]}, ${g.winHi[i]})',
      );
    }
  }
}

/// A bound the file declares, or the one its own grid pitch implies.
///
/// The Quantization record's bounds map is advisory — the Rust reference writes
/// none at all — so a file that states nothing is checked against half its
/// declared pitch, which is the same number by construction.
double _kdBound(Map<String, String> bounds, String key, double fallback) {
  final declared = bounds[key];
  if (declared == null) return fallback;
  return double.tryParse(declared) ?? fallback;
}
