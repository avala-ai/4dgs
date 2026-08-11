// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Structural validation: what is wrong with this file, and which byte.
///
/// This is what makes a third-party encoder possible — a way to find out *why* a
/// file is wrong that does not involve reading someone else's decoder. Every
/// finding names the record, the field and what was expected, and a finding that
/// came from a refusal carries the refusal's identifier and the byte it fired at.
///
/// The checks, their severities and their order are
/// `python/fourdgs/fourdgs/validate.py`'s, as the Rust, TypeScript and C++
/// validators' are. Two validators that disagree about whether a file conforms
/// are worse than one, so where they differ the Python module is the reference
/// and this is the bug. What this file deliberately does **less** of is written
/// down in `dart/fourdgs/README.md`: this decoder refuses several things at parse
/// that the Python one reports field by field, so the corresponding findings
/// arrive here as one "does not parse" error rather than as five. That is a
/// narrower report, not a contradictory one — every file either tool calls
/// invalid, the other calls invalid too.
///
/// Two things beyond the framing walk, because a validator that only walks the
/// framing answers a narrower question than the one its holder asked:
///
/// * **It decodes the chunks, and their spherical-harmonic bands.** Walking the
///   framing steps *over* a chunk by its declared length, which is exactly not
///   looking inside it — so an unimplemented stream codec and an out-of-range
///   window index are invisible to it, and both are in the invalid corpus. One
///   chunk, or one band, is resident at a time (AGENTS.md §1), so validating a
///   file larger than memory still works.
/// * **It knows `keyframe-delta`.** Every structural check below would otherwise
///   assume the `gaussian-birth` chunk shape, and a conforming keyframe-delta
///   file would be reported as broken for declaring a model this package
///   implements.
library;

import 'dart:typed_data';

import 'chunk_decoder.dart';
import 'exceptions.dart';
import 'indexed_reader.dart';
import 'keyframe_delta.dart';
import 'opcode.dart';
import 'quantization.dart';
import 'readable.dart';
import 'records.dart';
import 'refusal.dart';
import 'serialization.dart';

/// How much a finding matters. Ordered, so the worst one picks the exit code.
enum FourdgsSeverity {
  note,
  warning,
  error;

  /// The word the tool prints in front of the message.
  String get label => name;
}

/// One thing wrong with a file, and — when the decoder named it — which refusal.
class FourdgsFinding {
  const FourdgsFinding(this.severity, this.message, {this.refusal});

  final FourdgsSeverity severity;

  /// What the other validators print for the same bytes, as closely as one
  /// decoder's sentences can match another's.
  final String message;

  /// The refusal identifier and the byte it fired at, for the findings that have
  /// one. Most do not: "Header declares 640 gaussians; chunks contain 256" is a
  /// rule this validator checks itself, not a refusal a reader raised, and the
  /// refusal table does not name it.
  final FourdgsNamedRefusal? refusal;
}

/// Everything a validator has to say about one file.
class FourdgsValidation {
  FourdgsValidation(this.findings);

  final List<FourdgsFinding> findings;

  /// True when no finding is an error.
  bool get ok =>
      !findings.any((FourdgsFinding f) => f.severity == FourdgsSeverity.error);

  /// True when the file is valid and something was still worth saying out loud.
  bool get warned =>
      ok &&
      findings.any((FourdgsFinding f) => f.severity == FourdgsSeverity.warning);
}

class _Report {
  final List<FourdgsFinding> findings = <FourdgsFinding>[];

  void error(String message) =>
      findings.add(FourdgsFinding(FourdgsSeverity.error, message));

  void warn(String message) =>
      findings.add(FourdgsFinding(FourdgsSeverity.warning, message));

  void note(String message) =>
      findings.add(FourdgsFinding(FourdgsSeverity.note, message));

  /// An error a reader raised, carrying its identifier and the byte if it has
  /// one.
  ///
  /// [prefix] is what the message is introduced with, so the sentence stays the
  /// decoder's own; the identifier arrives on a line of its own beneath it and
  /// changes nothing about it, which is what lets a caller filtering on
  /// `error:` / `warning:` / `note:` see exactly what it saw before.
  void refused(
    String prefix,
    Object error, {
    FourdgsWalk? walk,
    FourdgsRefusalSite? site,
  }) => findings.add(
    FourdgsFinding(
      FourdgsSeverity.error,
      '$prefix${_say(error)}',
      refusal: describeFourdgsRefusal(error, walk: walk, site: site),
    ),
  );
}

/// A decoder's message without the `4dgs: ` prefix its `toString` adds — the
/// tool has already said which file it is talking about.
String _say(Object error) =>
    error is FourdgsException ? error.message : error.toString();

/// Every check, in the Python validator's order.
///
/// The file is read whole, as the Python, Rust, TypeScript and C++ validators
/// read it: the summary checksum covers a byte range, the index points into one,
/// and "is this file self-consistent" is a question about all of it at once. The
/// bounded-memory rule is about decode paths, and the decode this performs —
/// chunk by chunk, band by band, against [source] rather than against the copy
/// below — keeps one of each resident at a time.
Future<FourdgsValidation> validateFourdgs(FourdgsReadable source) async {
  final _Report report = _Report();
  // Framing first, and for two reasons: it refuses a file that is not ours
  // before anything reads a byte as an opcode, and it is what gives every later
  // refusal a byte to point at.
  final FourdgsWalk walk;
  try {
    walk = await walkFourdgsFraming(source);
  } on FourdgsException catch (error) {
    report.refused('', error);
    return FourdgsValidation(report.findings);
  }
  final Uint8List data = await source.read(0, walk.size);

  if (!walk.trailingMagic) {
    report.error(
      'file does not end with the magic; it is truncated or was written by a '
      'broken encoder',
    );
  }

  final Set<int> seen = <int>{};
  FourdgsHeader? header;
  FourdgsQuantization? quantization;
  List<FourdgsWindow> windows = const <FourdgsWindow>[];
  FourdgsFooter? footer;
  int firstOpcode = -1;
  int chunkCount = 0;
  int counted = 0;
  final List<FourdgsChunkIndexEntry> index = <FourdgsChunkIndexEntry>[];
  final Map<int, FourdgsAudioSourceRecord> audioSources =
      <int, FourdgsAudioSourceRecord>{};
  final Map<int, int> audioData = <int, int>{};
  bool firstChunkSeen = false;
  // A front-matter refusal makes the reader passes below pointless: the reader
  // would refuse the same record for the same reason at the same byte, and a
  // report that says it twice is a report a reader has to read twice.
  bool frontMatterRefused = false;

  try {
    for (final FourdgsRecord record in iterRecords(data, fourdgsMagic.length)) {
      if (firstOpcode < 0) firstOpcode = record.opcode;
      seen.add(record.opcode);
      // A record whose own body will not parse is a finding rather than an
      // abort: the point of a validator is to say everything that is wrong with
      // a file, not the first thing.
      switch (record.opcode) {
        case opHeader:
          try {
            header = FourdgsHeader.parse(record.content);
          } on FourdgsException catch (error) {
            // Named against *this* Header, not against the first record with
            // this opcode. Nothing in the framing forbids a second one, and a
            // refusal placed at the first would send its holder to a record
            // that is perfectly fine.
            frontMatterRefused |= _refuse(
              report,
              error,
              record.offset,
              'the Header record',
              'Header does not parse: ',
            );
          }
        case opQuantization:
          try {
            quantization = FourdgsQuantization.parse(
              record.content,
              fileOffset: record.offset + recordHeaderBytes,
            );
          } on FourdgsException catch (error) {
            frontMatterRefused |= _refuse(
              report,
              error,
              record.offset,
              'the Quantization record',
              'Quantization does not parse: ',
            );
          }
        case opWindowTable:
          // Read for the decode pass below, quietly: the Python validator does
          // not report this record, and a finding it does not have is a
          // disagreement about a file.
          try {
            windows = FourdgsWindowTable.parse(record.content).windows;
          } on FourdgsException catch (error) {
            report.error('Window Table does not parse: ${_say(error)}');
          }
        case opChunk:
        case opDeltaChunk:
          firstChunkSeen = true;
          chunkCount += 1;
          if (record.opcode == opChunk) {
            try {
              counted += parseChunk(record.content).header.count;
            } on FourdgsException catch (error) {
              report.error('chunk $chunkCount does not parse: ${_say(error)}');
            }
          }
        case opChunkIndex:
          try {
            index.add(
              FourdgsChunkIndexEntry.parse(
                record.content,
                fileOffset: record.offset + recordHeaderBytes,
              ),
            );
          } on FourdgsException catch (error) {
            report.error('a chunk index entry does not parse: ${_say(error)}');
          }
        case opFooter:
          try {
            footer = FourdgsFooter.parse(record.content);
          } on FourdgsException catch (error) {
            report.error('Footer does not parse: ${_say(error)}');
          }
        case opAudioSource:
          try {
            final FourdgsAudioSourceRecord parsed =
                FourdgsAudioSourceRecord.parse(record.content);
            if (firstChunkSeen) {
              report.error(
                'Audio Source id ${parsed.sourceId} appears after the first Chunk',
              );
            }
            if (audioSources.containsKey(parsed.sourceId)) {
              report.error(
                'Audio Source id ${parsed.sourceId} appears more than once',
              );
            }
            audioSources[parsed.sourceId] = parsed;
          } on FourdgsException catch (error) {
            report.error('Audio Source does not parse: ${_say(error)}');
          }
        case opAudioData:
          try {
            final FourdgsAudioData parsed = FourdgsAudioData.parse(
              record.content,
            );
            if (firstChunkSeen) {
              report.error(
                'Audio Data id ${parsed.sourceId} appears after the first Chunk',
              );
            }
            if (audioData.containsKey(parsed.sourceId)) {
              report.error(
                'Audio Data id ${parsed.sourceId} appears more than once',
              );
            }
            audioData[parsed.sourceId] = parsed.data.length;
          } on FourdgsException catch (error) {
            report.error('Audio Data does not parse: ${_say(error)}');
          }
        default:
          _noteUnread(report, record);
      }
    }
  } on FourdgsException catch (error) {
    report.error('stopped reading: ${_say(error)}');
  }

  if (seen.isEmpty) {
    report.error('no records at all');
    return FourdgsValidation(report.findings);
  }
  if (firstOpcode != opHeader) {
    report.error(
      'first record is ${opcodeName(firstOpcode)}; the Header must come first',
    );
  }
  // Against the opcodes the file frames rather than against what parsed: a
  // Header that is present but unreadable has already been reported as one, and
  // saying "no Header record" about a file that plainly has one sends its holder
  // looking for the wrong fault.
  if (!seen.contains(opHeader)) report.error('no Header record');
  if (!seen.contains(opQuantization)) report.error('no Quantization record');
  if (!seen.contains(opFooter)) report.error('no Footer record');

  // Which chunk shape the rest of this validator is entitled to assume. A
  // `keyframe-delta` file's Chunks are keyframes and its Delta Chunks are
  // differences against them, so several checks below are about the
  // `gaussian-birth` shape and about nothing else. Read from the Header rather
  // than guessed from the records, because a file that carries Delta Chunks and
  // does not say so is itself a fault.
  final bool keyframeDelta = header?.temporalModel == 'keyframe-delta';

  if (header != null) {
    // `gaussian_count` counts distinct gaussians over the whole sequence under
    // `keyframe-delta`, and every keyframe carries a full population — so the
    // sum across chunks is a larger number by design, not a disagreement.
    if (!keyframeDelta && counted != header.gaussianCount) {
      report.error(
        'Header declares ${header.gaussianCount} gaussians; chunks contain $counted',
      );
    }
    final bool hasAudioRecords =
        seen.contains(opAudio) ||
        audioSources.isNotEmpty ||
        audioData.isNotEmpty;
    if (header.hasAudio && !hasAudioRecords) {
      report.error(
        'Header says the file has audio, but there is no Audio Source or legacy '
        'Audio record',
      );
    }
    if (!header.hasAudio && hasAudioRecords) {
      report.error(
        'there is an Audio Source or legacy Audio record, but the Header\'s '
        'audio flag is clear',
      );
    }
    // The parser already refuses a keyframe list that is not finite and strictly
    // increasing; what it cannot know is the scene clock those times sit on.
    for (final FourdgsAudioSourceRecord audioSource in audioSources.values) {
      for (int i = 0; i < audioSource.keyframes.length; i++) {
        final double t = audioSource.keyframes[i].time;
        if (t < 0 || t > header.durationSec) {
          report.error(
            'Audio Source id ${audioSource.sourceId} keyframe $i time $t is '
            'outside [0, ${header.durationSec}]',
          );
        }
      }
    }
  }
  if (seen.contains(opAudio) && audioSources.isNotEmpty) {
    report.error('legacy Audio and Audio Source records must not be mixed');
  }
  for (final MapEntry<int, FourdgsAudioSourceRecord> entry
      in audioSources.entries) {
    final int? length = audioData[entry.key];
    if (length == null) {
      report.error(
        'Audio Source id ${entry.key} has no matching Audio Data record',
      );
    } else if (entry.value.dataLength != length) {
      report.error(
        'Audio Source id ${entry.key} declares ${entry.value.dataLength} bytes; '
        'Audio Data contains $length',
      );
    }
  }
  for (final int sourceId in audioData.keys) {
    if (!audioSources.containsKey(sourceId)) {
      report.error(
        'Audio Data id $sourceId has no matching Audio Source record',
      );
    }
  }

  for (int i = 0; i < index.length; i++) {
    final FourdgsChunkIndexEntry entry = index[i];
    if (entry.chunkOffset + entry.chunkLength > data.length) {
      report.error('chunk index entry $i points past the end of the file');
      continue;
    }
    // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a
    // Delta Chunk is a difference against one, and an index that could only name
    // the former could not seek the model at all.
    final int at = data[entry.chunkOffset];
    if (at != opChunk && !(keyframeDelta && at == opDeltaChunk)) {
      report.error('chunk index entry $i does not point at a Chunk record');
    }
  }

  if (footer != null && footer.summaryCrc != 0 && footer.summaryStart != 0) {
    // The Footer record itself is not covered: nine bytes of framing plus its
    // twenty bytes of content plus the trailing magic.
    final int tail =
        data.length - (recordHeaderBytes + 20 + fourdgsMagic.length);
    if (footer.summaryStart > tail) {
      report.error(
        "the Footer's summary starts at ${footer.summaryStart}, after the "
        'summary ends at $tail',
      );
    } else if (fourdgsCrc32(
          Uint8List.sublistView(data, footer.summaryStart, tail),
        ) !=
        footer.summaryCrc) {
      report.error(
        'summary CRC mismatch: the index is untrustworthy (a streamed read '
        'still works)',
      );
    }
  }

  if (header != null && index.isEmpty) {
    report.warn(
      'no chunk index: this file can only be read front to back, not seeked',
    );
  }

  // What survived the cut, which is the question the errors above do not answer.
  //
  // A cut file is invalid and every finding about it stands — but records are
  // length-prefixed, so everything complete before the cut is intact and the
  // streamed reader keeps it. Saying only that the file stopped reading leaves
  // its holder to guess whether anything is salvageable; this says how much.
  final FourdgsCut? cut = walk.cut;
  if (cut != null) {
    report.note(
      'the file is cut at byte ${fourdgsCommas(cut.at)}: ${cut.reason}. '
      'The ${walk.intact} complete records before it are intact, and a streamed '
      'reader recovers them',
    );
  }

  if (!frontMatterRefused) {
    if (keyframeDelta) {
      _checkKeyframeDelta(data, index, report);
    } else {
      await _checkGaussianBirth(
        source,
        walk,
        report,
        quantization: quantization,
        windows: windows,
        cutoff: header?.cutoff ?? fourdgsDefaultCutoff,
      );
    }
  }

  return FourdgsValidation(report.findings);
}

/// Reports a record that would not parse, and says whether it was a refusal.
///
/// A refusal keeps the decoder's own sentence and gains the identifier and the
/// byte; anything else is introduced by [prefix], because "the Header does not
/// parse" is what a reader needs to hear about a Header that is simply corrupt.
bool _refuse(
  _Report report,
  FourdgsException error,
  int offset,
  String what,
  String prefix,
) {
  if (error.refusalCode == null) {
    report.error('$prefix${_say(error)}');
    return false;
  }
  report.refused('', error, site: FourdgsRefusalSite(offset, what));
  return true;
}

/// A record this validator reads nothing out of, and what to say about it.
void _noteUnread(_Report report, FourdgsRecord record) {
  final String hex =
      '0x${record.opcode.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  if (isPrivateOpcode(record.opcode)) {
    report.note(
      'private record $hex (${record.content.length} bytes) — skipped, as required',
    );
  } else if (isSpecifiedOpcode(record.opcode)) {
    // A record this validator has nothing to say about — provenance, the object
    // layer, a camera. Framed, stepped over, not remarked on.
  } else if (isProvenanceOpcode(record.opcode)) {
    report.note(
      'reserved provenance record $hex — skipped, as required '
      '(0x26-0x2F, section 5.15.6)',
    );
  } else {
    report.note('unknown record $hex — skipped, as required');
  }
}

/// The checks only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals
/// fire. Decoding is where the rest do, and there is no substitute for it: the
/// framing walk steps over a chunk by its declared length, so an unimplemented
/// stream codec and an out-of-range window index are both invisible to
/// everything above — and so is a spherical-harmonic band that will not decode,
/// which is a whole record class a framing walk has nothing to say about.
Future<void> _checkGaussianBirth(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report, {
  required FourdgsQuantization? quantization,
  required List<FourdgsWindow> windows,
  required double cutoff,
}) async {
  final FourdgsIndexedScene scene;
  try {
    scene = await openFourdgsIndexed(source);
  } on FourdgsException catch (error) {
    report.refused(
      'a seeking reader cannot open this file: ',
      error,
      walk: walk,
    );
    // A file that will not open will not decode either, and the second error
    // would say the same thing about the same byte.
    return;
  }
  if (scene.index.isEmpty) {
    await _scanFramedChunks(
      source,
      walk,
      report,
      quantization: quantization,
      windows: windows,
      cutoff: cutoff,
    );
    return;
  }
  for (int i = 0; i < scene.index.length; i++) {
    final FourdgsChunkIndexEntry entry = scene.index[i];
    try {
      // One chunk resident at a time, and dropped before the next is fetched:
      // this is what keeps validating a file larger than memory possible.
      await readFourdgsChunk(source, scene, entry);
    } on FourdgsException catch (error) {
      report.refused(
        'a chunk does not decode: ',
        error,
        site: FourdgsRefusalSite(
          entry.chunkOffset,
          'the Chunk record at index entry $i',
        ),
      );
      return;
    }
    for (final FourdgsBandRange band in entry.bands) {
      try {
        decodeShBandRecord(
          _content(await source.read(band.offset, band.length), opShBandStream),
          expectedBand: band.band,
          expectedCount: entry.gaussianCount,
        );
      } on FourdgsException catch (error) {
        // The byte is in the sentence and not only on the refusal line beneath
        // it, because most of the ways a band record can fail are not refusals
        // the table names — a payload that will not inflate is a corrupt file,
        // not an unimplemented rule — and a finding that says only "a band does
        // not decode" leaves its holder to find which of a scene's bands it was.
        report.refused(
          'the ShBandStream record for band ${band.band} at byte '
          '${fourdgsCommas(band.offset)} does not decode: ',
          error,
          site: FourdgsRefusalSite(
            band.offset,
            'the ShBandStream record for band ${band.band} of index entry $i',
          ),
        );
        return;
      }
    }
  }
}

/// The same decode for a file with no index, driven by the framing walk.
///
/// A file without a Chunk Index has no per-chunk addressing to use, and the
/// package's front-to-back reader answers "what does this file decode to" by
/// keeping every chunk. The validator's question is "does this file decode", so
/// it fetches each Chunk record from the walk, decodes it, and drops it — which
/// is the same answer for a fraction of the memory, and it can name the byte
/// where a validator that handed the whole file to the streamed reader could
/// not.
Future<void> _scanFramedChunks(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report, {
  required FourdgsQuantization? quantization,
  required List<FourdgsWindow> windows,
  required double cutoff,
}) async {
  if (quantization == null) return; // already reported as missing
  int count = 0;
  for (final FourdgsFrame frame in walk.records) {
    if (frame.opcode != opChunk && frame.opcode != opShBandStream) continue;
    if (frame.offset + frame.total > walk.size) continue; // the cut record
    try {
      final Uint8List content = _content(
        await source.read(frame.offset, frame.total),
        frame.opcode,
      );
      if (frame.opcode == opChunk) {
        final FourdgsChunkBody body = parseChunk(content);
        count = body.header.count;
        decodeChunkStreams(
          body.streams,
          count,
          FourdgsSteps.of(quantization),
          quantization.posOrigin,
          windows,
          cutoff: cutoff,
          compression: body.header.compression,
          // The walk knows where this record is, and every refusal the decoder
          // raises below names it. Leaving it defaulted would report "the chunk
          // at byte 0" about the fifth chunk of the file.
          chunkOffset: frame.offset,
        );
      } else if (content.isNotEmpty) {
        // Bands belong to the chunk that precedes them; that adjacency is the
        // only thing that says which chunk's gaussians they colour.
        decodeShBandRecord(
          content,
          expectedBand: content[0],
          expectedCount: count,
        );
      }
    } on FourdgsException catch (error) {
      report.refused(
        'the ${opcodeName(frame.opcode)} record at byte '
        '${fourdgsCommas(frame.offset)} does not decode: ',
        error,
        site: FourdgsRefusalSite(
          frame.offset,
          'the ${opcodeName(frame.opcode)} record',
        ),
      );
      return;
    }
  }
}

/// The same, for the temporal model whose chunks are keyframes and differences.
///
/// Composition is the model's own reader, chain by chain:
/// [decodeKeyframeDeltaIndexed] answers "what does this file decode to" and so
/// holds every composed state at once, where the question here is only "does it
/// decode". So each chain is composed and dropped, which bounds the memory and —
/// because the loop is over index entries — names the entry that failed.
void _checkKeyframeDelta(
  Uint8List data,
  List<FourdgsChunkIndexEntry> index,
  _Report report,
) {
  if (index.isEmpty) {
    // No index means no chain to walk by byte range, so the model's front-to-back
    // reader is the only path there is.
    try {
      decodeKeyframeDeltaStreamed(data);
    } on FourdgsException catch (error) {
      report.refused('this file does not decode as keyframe-delta: ', error);
    }
    return;
  }
  try {
    checkTiling(index);
  } on FourdgsException catch (error) {
    report.error('the state chunks do not tile the timeline: ${_say(error)}');
    return;
  }
  for (int i = 0; i < index.length; i++) {
    try {
      composeKeyframeDeltaChain(data, index, index[i]);
    } on FourdgsException catch (error) {
      report.refused(
        'a chunk does not compose: ',
        error,
        site: FourdgsRefusalSite(
          index[i].chunkOffset,
          'the Chunk record at index entry $i',
        ),
      );
      return;
    }
  }
}

/// One framed record's content, checked against the opcode it was fetched as.
Uint8List _content(Uint8List blob, int opcode) {
  final FourdgsRecord record = readRecord(FourdgsCursor(blob));
  if (record.opcode != opcode) {
    throw FourdgsMalformedFile(
      'expected a ${opcodeName(opcode)} record here, found '
      '${opcodeName(record.opcode)}',
    );
  }
  return record.content;
}
